//! A page cache for private file mappings (design/epoch-0/cow-fork.md, "A shared
//! page cache for executables"): the pages of one chunk of a file,
//! shared by every process whose private mapping of the file covers that
//! chunk whole, at the address the chunk's offset puts it at (offset and
//! address agree modulo `mm.chunk_size`). Each process maps them
//! copy-on-write (`mm.Chunk.cow`), so a write copies the chunk first and
//! never reaches these pages or the file, and they count once against
//! `--memory` however many processes map them. It's what lets every
//! `zig` that `zig build` starts share one copy of the 150 MB of text and
//! read-only data it touches, where each loaded its own.
//!
//! A chunk is read whole from the file the first time a process touches
//! it, and goes when no process maps it any more (`released`). Entries
//! are keyed by the file's identity and a stamp of its version, length,
//! and modification time, taken when the mapping was made, so a file
//! that changed since gets new pages rather than a mix of old and new
//! chunks; a write or truncate through the Linux layer drops the file's
//! entries (`changed`) for the mappings made after it. Mappings made
//! earlier keep the pages they share, as each process kept the chunks it
//! had read before.

const std = @import("std");
const engine = @import("../../engine.zig");
const mm = @import("mm.zig");
const locks = @import("locks.zig");

const chunk = mm.chunk_size;

/// What the cache knows a file by.
pub const Id = struct {
    file: locks.Key,
    /// The qid version, modification time, and length when the mapping
    /// was made.
    vers: u32,
    mtime: u32,
    length: u64,
};

const Key = struct {
    /// The engine whose pages these are: an address space can map only
    /// its own engine's.
    engine: usize,
    id: Id,
    /// The chunk's index in the file: its offset / chunk.
    index: u64,
};

const Entry = struct {
    key: Key,
    engine: engine.Engine,
    pages: *mm.Pages,
    /// The file bytes read into the pages, short of a chunk at the file's
    /// end; the rest is zero.
    n: u64,
    /// Out of the table, by `changed`: freed by the last mapping going.
    gone: bool = false,
};

const gpa = @import("../../web.zig").gpa;
var mutex: std.atomic.Mutex = .unlocked;
var table: std.AutoHashMapUnmanaged(Key, *Entry) = .empty;
/// Entries, so `changed` can skip the table when it's empty.
var live: std.atomic.Value(usize) = .init(0);

fn lock() void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

fn engineId(b: engine.Engine) usize {
    return switch (b) {
        inline else => |p| @intFromPtr(p),
    };
}

/// A chunk's shared pages, with a reference for the caller, and how many
/// of their bytes came from the file.
pub const Shared = struct { pages: *mm.Pages, n: u64 };

/// The pages of chunk `index` of file `id`, read with `fill(ctx, dst,
/// off)` (which returns the bytes it read, zeroing the rest) if no
/// process maps them yet, with a reference for the caller. The read is
/// made outside the table's lock; if another process read the chunk
/// meanwhile, its pages are used and these freed. Null if there's no
/// memory for them.
pub fn get(eng: engine.Engine, id: Id, index: u64, ctx: anytype, comptime fill: fn (@TypeOf(ctx), []u8, u64) usize) ?Shared {
    const key: Key = .{ .engine = engineId(eng), .id = id, .index = index };
    if (take(key)) |s| return s;
    const mem = eng.allocPages(mm.pages_per_chunk) catch return null;
    const n = fill(ctx, mem, index * chunk);
    const e = gpa.create(Entry) catch {
        eng.freePages(mem);
        return null;
    };
    const p = gpa.create(mm.Pages) catch {
        gpa.destroy(e);
        eng.freePages(mem);
        return null;
    };
    // The table's reference and the caller's.
    p.* = .{ .mem = mem, .refs = .init(2), .file = e, .release = released };
    e.* = .{ .key = key, .engine = eng, .pages = p, .n = n };
    lock();
    if (table.get(key)) |o| {
        _ = o.pages.refs.fetchAdd(1, .acq_rel);
        const s: Shared = .{ .pages = o.pages, .n = o.n };
        mutex.unlock();
        eng.freePages(mem);
        gpa.destroy(p);
        gpa.destroy(e);
        return s;
    }
    table.put(gpa, key, e) catch {
        mutex.unlock();
        eng.freePages(mem);
        gpa.destroy(p);
        gpa.destroy(e);
        return null;
    };
    _ = live.fetchAdd(1, .monotonic);
    mutex.unlock();
    return .{ .pages = p, .n = n };
}

fn take(key: Key) ?Shared {
    lock();
    defer mutex.unlock();
    const e = table.get(key) orelse return null;
    _ = e.pages.refs.fetchAdd(1, .acq_rel);
    return .{ .pages = e.pages, .n = e.n };
}

/// Pages.release: no Mm maps `p`, so it goes, unless a process took it
/// meanwhile.
fn released(p: *mm.Pages) void {
    const e: *Entry = @ptrCast(@alignCast(p.file.?));
    lock();
    // Another Mm still owes a call (mm.Pages.pending), so the last one
    // frees them; or a mapping took them meanwhile.
    const owed = p.pending.fetchSub(1, .acq_rel) != 1;
    if (owed or p.refs.load(.acquire) != 1) {
        mutex.unlock();
        return;
    }
    if (!e.gone) {
        _ = table.remove(e.key);
        _ = live.fetchSub(1, .monotonic);
    }
    mutex.unlock();
    e.engine.freePages(p.mem);
    gpa.destroy(p);
    gpa.destroy(e);
}

/// After a write or truncate of `file` through the Linux layer: mappings
/// made from now on read it again.
pub fn changed(file: locks.Key) void {
    if (live.load(.monotonic) == 0) return;
    lock();
    defer mutex.unlock();
    // Removing invalidates the iterator, so each pass removes one.
    while (true) {
        var it = table.valueIterator();
        const e = while (it.next()) |ep| {
            if (std.meta.eql(ep.*.key.id.file, file)) break ep.*;
        } else break;
        _ = table.remove(e.key);
        _ = live.fetchSub(1, .monotonic);
        e.gone = true;
    }
}

/// Entries in the table, for tests.
pub fn count() usize {
    return live.load(.monotonic);
}
