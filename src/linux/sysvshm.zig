//! System V shared memory (design/0018-linux-personality.md, "Memory"):
//! shmget, shmat, shmdt and shmctl, as PostgreSQL uses them for the small
//! segment that tells a new postmaster an old one's backends still run.
//! A segment is a set of chunk pages (mm.Pages), one per 1 MiB of it,
//! held by this table and by every address space that attaches it; fork
//! shares them as any MAP_SHARED mapping's. Its attach count is the
//! pages' references less the table's. A removed segment goes once no
//! process has it attached. Segments are per backend, so per machine
//! when machines have backends of their own; keys don't reach the host.

const std = @import("std");
const vmm = @import("../vmm.zig");
const mm = @import("mm.zig");

const chunk = mm.chunk_size;

pub const Seg = struct {
    id: i32,
    key: i32,
    size: u64,
    backend: vmm.Backend,
    pages: []*mm.Pages,
    /// IPC_RMID: no new attaches, and it goes with the last detach.
    removed: bool = false,
    mode: u32,
    uid: u32,
    gid: u32,
    cuid: u32,
    cgid: u32,
    cpid: i32,
    lpid: i32 = 0,
    atime: i64 = 0,
    dtime: i64 = 0,
    ctime: i64,

    pub fn nattch(s: *const Seg) u64 {
        return s.pages[0].refs.load(.acquire) -| 1;
    }
};

const gpa = @import("../web.zig").gpa;
var mutex: std.atomic.Mutex = .unlocked;
var table: std.AutoHashMapUnmanaged(i32, *Seg) = .empty;
var next_id: i32 = 0;

pub fn lock() void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

pub fn unlock() void {
    mutex.unlock();
}

fn backendId(b: vmm.Backend) usize {
    return switch (b) {
        inline else => |p| @intFromPtr(p),
    };
}

pub const IPC_PRIVATE: i32 = 0;
pub const IPC_CREAT: u32 = 0o1000;
pub const IPC_EXCL: u32 = 0o2000;

pub const GetError = error{ NotFound, Exists, Invalid, NoSpace, OutOfMemory };

pub const Who = struct { uid: u32, gid: u32, pid: i32, now: i64 };

/// shmget: the id of the segment with `key`, made if IPC_CREAT says so.
pub fn get(backend: vmm.Backend, key: i32, size: u64, flags: u32, who: Who) GetError!i32 {
    lock();
    defer unlock();
    if (key != IPC_PRIVATE) {
        var it = table.valueIterator();
        while (it.next()) |sp| {
            const s = sp.*;
            if (s.key != key or s.removed or backendId(s.backend) != backendId(backend)) continue;
            if (flags & IPC_CREAT != 0 and flags & IPC_EXCL != 0) return error.Exists;
            if (size > s.size) return error.Invalid;
            return s.id;
        }
        if (flags & IPC_CREAT == 0) return error.NotFound;
    }
    if (size == 0 or size > 1 << 40) return error.Invalid;
    const n: usize = @intCast(std.math.divCeil(u64, size, chunk) catch unreachable);
    const pages = try gpa.alloc(*mm.Pages, n);
    var made: usize = 0;
    errdefer {
        for (pages[0..made]) |p| {
            backend.freePages(p.mem);
            gpa.destroy(p);
        }
        gpa.free(pages);
    }
    const s = try gpa.create(Seg);
    errdefer gpa.destroy(s);
    while (made < n) : (made += 1) {
        const mem = backend.allocPages(mm.pages_per_chunk) catch return error.NoSpace;
        @memset(mem, 0);
        const p = gpa.create(mm.Pages) catch {
            backend.freePages(mem);
            return error.OutOfMemory;
        };
        p.* = .{ .mem = mem, .refs = .init(1), .file = s, .release = released };
        pages[made] = p;
    }
    next_id +%= 1;
    if (next_id < 0) next_id = 1;
    s.* = .{
        .id = next_id,
        .key = key,
        .size = size,
        .backend = backend,
        .pages = pages,
        .mode = flags & 0o777,
        .uid = who.uid,
        .gid = who.gid,
        .cuid = who.uid,
        .cgid = who.gid,
        .cpid = who.pid,
        .ctime = who.now,
    };
    try table.put(gpa, s.id, s);
    return s.id;
}

/// The segment with `id`, under the table's lock (the caller unlocks).
pub fn find(backend: vmm.Backend, id: i32) ?*Seg {
    const s = table.get(id) orelse return null;
    if (backendId(s.backend) != backendId(backend)) return null;
    return s;
}

/// IPC_RMID: marks it removed, and frees it if nothing has it attached.
/// Called with the lock held; returns with it released.
pub fn remove(s: *Seg) void {
    s.removed = true;
    if (s.nattch() == 0) {
        _ = table.remove(s.id);
        unlock();
        free(s);
        return;
    }
    unlock();
}

fn free(s: *Seg) void {
    for (s.pages) |p| {
        s.backend.freePages(p.mem);
        gpa.destroy(p);
    }
    gpa.free(s.pages);
    gpa.destroy(s);
}

/// Pages.release: no address space attaches one of the segment's chunks.
fn released(p: *mm.Pages) void {
    const s: *Seg = @ptrCast(@alignCast(p.file.?));
    lock();
    if (!s.removed) {
        unlock();
        return;
    }
    for (s.pages) |q| if (q.refs.load(.acquire) != 1) {
        unlock();
        return;
    };
    _ = table.remove(s.id);
    unlock();
    free(s);
}

/// shmid64_ds, as arm64 and amd64 lay it out.
pub fn stat(s: *const Seg, out: *[112]u8) void {
    out.* = @splat(0);
    const w = struct {
        fn u32_(b: *[112]u8, o: usize, v: u32) void {
            std.mem.writeInt(u32, b[o..][0..4], v, .little);
        }
        fn u64_(b: *[112]u8, o: usize, v: u64) void {
            std.mem.writeInt(u64, b[o..][0..8], v, .little);
        }
    };
    w.u32_(out, 0, @bitCast(s.key));
    w.u32_(out, 4, s.uid);
    w.u32_(out, 8, s.gid);
    w.u32_(out, 12, s.cuid);
    w.u32_(out, 16, s.cgid);
    w.u32_(out, 20, s.mode | if (s.removed) @as(u32, 0o1000) else 0); // SHM_DEST
    w.u64_(out, 48, s.size);
    w.u64_(out, 56, @bitCast(s.atime));
    w.u64_(out, 64, @bitCast(s.dtime));
    w.u64_(out, 72, @bitCast(s.ctime));
    w.u32_(out, 80, @bitCast(s.cpid));
    w.u32_(out, 84, @bitCast(s.lpid));
    w.u64_(out, 88, s.nattch());
}
