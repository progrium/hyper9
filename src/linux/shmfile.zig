//! Shared file mappings (design/0018-linux-personality.md, "Memory"): the
//! pages of MAP_SHARED mappings of one file, one set per 1 MiB chunk of
//! it, shared by every process that maps that part of the file, so their
//! stores reach each other at once, as SQLite's WAL index (the -shm
//! file) needs.
//!
//! h9 has no page cache, so this table stands in for one, only for files
//! that are mapped shared. A chunk's pages are read from the file when
//! the first process maps it. While they're mapped, the Linux layer's
//! read and write calls on the file go through them as well as to the
//! file (`read`, `wrote`), so a program that mixes the two sees one file.
//! When the last mapping goes, pages that any mapping could write are
//! written back to the file, through the file itself, posted in #s when
//! a mapping that could write them came, so a file removed while mapped
//! (shm_open then unlink, memfd_create) keeps them for the processes
//! that still have it open; msync doesn't wait for that, since other
//! processes see the pages already. Writes from outside the Linux
//! layer (9front programs, the host) don't reach mapped pages, and the
//! pages beyond the file's end are kept, not SIGBUS.
//!
//! A MAP_PRIVATE mapping of a file that's mapped shared maps these pages
//! too, copy-on-write, so it sees other processes' stores until it writes
//! a page, as Linux's page cache gives it (mm.zig, "overlays").

const std = @import("std");
const kern = @import("../kern.zig");
const vmm = @import("../vmm.zig");
const mm = @import("mm.zig");
const locks = @import("locks.zig");

const chunk = mm.chunk_size;

const Key = struct {
    /// The backend whose pages these are: an address space can map only
    /// its own backend's.
    backend: usize,
    file: locks.Key,
    /// The chunk's index in the file: its offset / chunk.
    index: u64,
};

const Entry = struct {
    key: Key,
    backend: vmm.Backend,
    pages: *mm.Pages,
    /// Some mapping could write them, so they're written back.
    writable: bool,
    path: [:0]u8,
    /// The #s post holding the file open for the write-back, once a
    /// mapping could write the pages, or empty (then the path is used).
    post: [24]u8 = undefined,
    post_len: u8 = 0,
};

var post_seq: std.atomic.Value(u32) = .init(0);

/// Posts the file open as `fd` for e's write-back, if it isn't yet.
fn postFile(e: *Entry, fd: u31) void {
    if (e.post_len != 0) return;
    const name = std.fmt.bufPrintZ(&e.post, "#s/lxm.{d}", .{post_seq.fetchAdd(1, .monotonic)}) catch return;
    const sfd = kern.create(name, kern.OWRITE, 0o600) catch return;
    defer kern.close(sfd) catch {};
    var nb: [16]u8 = undefined;
    const t = std.fmt.bufPrint(&nb, "{d}", .{fd}) catch return;
    _ = kern.pwrite(sfd, t, -1) catch {
        kern.remove(name) catch {};
        return;
    };
    e.post_len = @intCast(name.len);
}

const gpa = @import("../web.zig").gpa;
var mutex: std.atomic.Mutex = .unlocked;
var table: std.AutoHashMapUnmanaged(Key, *Entry) = .empty;
/// Entries, so the read and write paths can skip the table when empty.
var live: std.atomic.Value(usize) = .init(0);

fn lock() void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

fn backendId(b: vmm.Backend) usize {
    return switch (b) {
        inline else => |p| @intFromPtr(p),
    };
}

pub const Error = error{ OutOfMemory, NoSpace, Io };

/// The pages of chunk `index` of the file open as `fd`, read from it if
/// no process maps them yet. The Mm's addChunk takes its own reference.
pub fn pagesFor(backend: vmm.Backend, file: locks.Key, index: u64, fd: u31, path: []const u8, writable: bool) Error!*mm.Pages {
    const key: Key = .{ .backend = backendId(backend), .file = file, .index = index };
    lock();
    defer mutex.unlock();
    if (table.get(key)) |e| {
        e.writable = e.writable or writable;
        if (writable) postFile(e, fd);
        return e.pages;
    }
    const mem = backend.allocPages(mm.pages_per_chunk) catch return error.NoSpace;
    errdefer backend.freePages(mem);
    var done: usize = 0;
    while (done < mem.len) {
        const n = kern.pread(fd, mem[done..], @intCast(index * chunk + done)) catch return error.Io;
        if (n == 0) break;
        done += n;
    }
    const e = try gpa.create(Entry);
    errdefer gpa.destroy(e);
    const p = try gpa.create(mm.Pages);
    errdefer gpa.destroy(p);
    const pz = try gpa.dupeZ(u8, path);
    errdefer gpa.free(pz);
    p.* = .{ .mem = mem, .refs = .init(1), .file = e, .release = released };
    e.* = .{ .key = key, .backend = backend, .pages = p, .writable = writable, .path = pz };
    try table.put(gpa, key, e);
    if (writable) postFile(e, fd);
    _ = live.fetchAdd(1, .monotonic);
    return p;
}

/// Pages.release: no Mm maps `p`, so it goes (written back if it could
/// have been written), unless another mapping took it meanwhile.
fn released(p: *mm.Pages) void {
    const e: *Entry = @ptrCast(@alignCast(p.file.?));
    lock();
    if (p.refs.load(.acquire) != 1) {
        mutex.unlock();
        return;
    }
    _ = table.remove(e.key);
    _ = live.fetchSub(1, .monotonic);
    mutex.unlock();
    if (e.writable) writeBack(e);
    if (e.post_len != 0) kern.remove(e.post[0..e.post_len :0]) catch {};
    e.backend.freePages(p.mem);
    gpa.destroy(p);
    gpa.free(e.path);
    gpa.destroy(e);
}

/// Writes the pages within the file's current length back to it.
fn writeBack(e: *Entry) void {
    const name: [:0]const u8 = if (e.post_len != 0) e.post[0..e.post_len :0] else e.path;
    const fd = kern.open(name, kern.OWRITE) catch kern.open(e.path, kern.ORDWR) catch return;
    defer kern.close(fd) catch {};
    var st: [512]u8 = undefined;
    _ = kern.fstat(fd, &st) catch return;
    const flen = std.mem.readInt(u64, st[33..41], .little);
    const base = e.key.index * chunk;
    if (flen <= base) return;
    const n: usize = @intCast(@min(chunk, flen - base));
    _ = kern.pwrite(fd, e.pages.mem[0..n], @intCast(base)) catch {};
}

/// Applies `f` to each mapped chunk overlapping [off, off+len) of the
/// file, with the piece of the pages and of the caller's buffer.
fn each(file: locks.Key, off: u64, buf: []u8, comptime f: fn (pages: []u8, data: []u8) void) void {
    if (live.load(.monotonic) == 0 or buf.len == 0) return;
    lock();
    defer mutex.unlock();
    var it = table.valueIterator();
    while (it.next()) |ep| {
        const e = ep.*;
        if (!std.meta.eql(e.key.file, file)) continue;
        const base = e.key.index * chunk;
        const lo = @max(base, off);
        const hi = @min(base + chunk, off + buf.len);
        if (lo >= hi) continue;
        f(e.pages.mem[@intCast(lo - base)..@intCast(hi - base)], buf[@intCast(lo - off)..@intCast(hi - off)]);
    }
}

/// Whether any of the file is mapped shared.
pub fn mapped(file: locks.Key) bool {
    if (live.load(.monotonic) == 0) return false;
    lock();
    defer mutex.unlock();
    var it = table.keyIterator();
    while (it.next()) |k| if (std.meta.eql(k.file, file)) return true;
    return false;
}

/// After a read of [off, off+data.len): what's mapped is newer.
pub fn read(file: locks.Key, off: u64, data: []u8) void {
    each(file, off, data, struct {
        fn f(pages: []u8, d: []u8) void {
            @memcpy(d, pages);
        }
    }.f);
}

/// After a write of `data` at off: the mappings see it.
pub fn wrote(file: locks.Key, off: u64, data: []u8) void {
    each(file, off, data, struct {
        fn f(pages: []u8, d: []u8) void {
            @memcpy(pages, d);
        }
    }.f);
}

/// After a truncate to `len`: mapped pages past it read as zero.
pub fn truncated(file: locks.Key, len: u64) void {
    if (live.load(.monotonic) == 0) return;
    lock();
    defer mutex.unlock();
    var it = table.valueIterator();
    while (it.next()) |ep| {
        const e = ep.*;
        if (!std.meta.eql(e.key.file, file)) continue;
        const base = e.key.index * chunk;
        if (len >= base + chunk) continue;
        @memset(e.pages.mem[@intCast(@max(len, base) - base)..], 0);
    }
}
