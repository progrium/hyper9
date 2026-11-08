//! File locks for Linux programs (design/0018-linux-personality.md,
//! "Files"): fcntl's POSIX record locks and open file description (OFD)
//! locks, which conflict with each other, and flock's whole-file locks,
//! which are separate, as on Linux. One table serves every machine in
//! the h9 process, keyed by the file's identity in the kernel (device,
//! instance, qid path), so programs in different machines on the same
//! host file see each other's locks; programs outside h9 don't.
//!
//! A POSIX lock belongs to a process (its machine and tgid): it's
//! released when the process closes any fd of the file, or ends. An OFD
//! or flock lock belongs to an open file description (the kernel's Chan,
//! which dup and fork share): it's released when the last fd for it
//! closes. A blocking request polls, as the kernel has no wait queue for
//! it here, and a signal interrupts it.

const std = @import("std");

pub const Key = struct { dc: u32, dev: u64, qpath: u64 };

pub const Type = enum(u2) { read = 0, write = 1, unlock = 2 };

/// An owner: a process's (POSIX) or an open file description's.
pub const Owner = struct {
    id: u64,
    posix: bool,
    /// For F_GETLK's l_pid: the tgid, or -1 for an OFD lock.
    pid: i32,

    fn eql(a: Owner, b: Owner) bool {
        return a.id == b.id and a.posix == b.posix;
    }
};

const Range = struct {
    owner: Owner,
    type: Type,
    start: u64,
    /// Exclusive; maxInt for "to the end, however far".
    end: u64,
};

const Flock = struct { owner: u64, exclusive: bool };

const File = struct {
    ranges: std.ArrayList(Range) = .empty,
    flocks: std.ArrayList(Flock) = .empty,

    fn empty(f: *const File) bool {
        return f.ranges.items.len == 0 and f.flocks.items.len == 0;
    }
};

const gpa = @import("../web.zig").gpa;
var mutex: std.atomic.Mutex = .unlocked;
var files: std.AutoHashMapUnmanaged(Key, *File) = .empty;
/// Bumped by every change, so a poller can tell nothing moved.
var generation: @import("../web.zig").Atomic(u64) = .init(0);

fn lock() void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

fn unlock() void {
    mutex.unlock();
}

fn conflicts(a: Range, b: Range) bool {
    if (a.owner.eql(b.owner)) return false;
    if (a.start >= b.end or b.start >= a.end) return false;
    return a.type == .write or b.type == .write;
}

/// The first lock of another owner that `want` conflicts with, if any.
pub fn conflicting(key: Key, want: Range) ?Range {
    lock();
    defer unlock();
    const f = files.get(key) orelse return null;
    for (f.ranges.items) |r| if (conflicts(r, want)) return r;
    return null;
}

pub const SetError = error{ WouldBlock, OutOfMemory };

/// F_SETLK: sets (or with .unlock, clears) [start, end) for `owner`,
/// replacing what it held there. WouldBlock if another owner's lock
/// conflicts.
pub fn set(key: Key, owner: Owner, t: Type, start: u64, end: u64) SetError!void {
    if (start >= end) return;
    lock();
    defer unlock();
    const want: Range = .{ .owner = owner, .type = t, .start = start, .end = end };
    const f = files.get(key) orelse blk: {
        if (t == .unlock) return;
        const nf = try gpa.create(File);
        nf.* = .{};
        files.put(gpa, key, nf) catch {
            gpa.destroy(nf);
            return error.OutOfMemory;
        };
        break :blk nf;
    };
    if (t != .unlock) for (f.ranges.items) |r| if (conflicts(r, want)) return error.WouldBlock;
    // Room for a split and the new range, so nothing below fails halfway.
    try f.ranges.ensureUnusedCapacity(gpa, 2);
    // Cut the owner's ranges out of [start, end).
    var i: usize = 0;
    while (i < f.ranges.items.len) {
        const r = f.ranges.items[i];
        if (!r.owner.eql(owner) or r.start >= end or start >= r.end) {
            i += 1;
            continue;
        }
        if (r.start < start and r.end > end) {
            f.ranges.items[i].end = start;
            f.ranges.insertAssumeCapacity(i + 1, .{ .owner = owner, .type = r.type, .start = end, .end = r.end });
            break;
        }
        if (r.start < start) {
            f.ranges.items[i].end = start;
            i += 1;
        } else if (r.end > end) {
            f.ranges.items[i].start = end;
            i += 1;
        } else {
            _ = f.ranges.orderedRemove(i);
        }
    }
    if (t != .unlock) {
        f.ranges.appendAssumeCapacity(want);
        coalesce(f, owner);
    }
    _ = generation.fetchAdd(1, .monotonic);
    drop(key, f);
}

/// Joins the owner's touching ranges of one type.
fn coalesce(f: *File, owner: Owner) void {
    var i: usize = 0;
    while (i < f.ranges.items.len) : (i += 1) {
        var j: usize = i + 1;
        while (j < f.ranges.items.len) {
            const a = f.ranges.items[i];
            const b = f.ranges.items[j];
            if (a.owner.eql(owner) and b.owner.eql(owner) and a.type == b.type and a.start <= b.end and b.start <= a.end) {
                f.ranges.items[i].start = @min(a.start, b.start);
                f.ranges.items[i].end = @max(a.end, b.end);
                _ = f.ranges.orderedRemove(j);
                j = i + 1;
            } else j += 1;
        }
    }
}

fn drop(key: Key, f: *File) void {
    if (!f.empty()) return;
    _ = files.remove(key);
    f.ranges.deinit(gpa);
    f.flocks.deinit(gpa);
    gpa.destroy(f);
}

/// flock: LOCK_SH, LOCK_EX or LOCK_UN for open file description `owner`.
/// A held lock converts. WouldBlock if another holder conflicts.
pub fn flock(key: Key, owner: u64, t: Type) SetError!void {
    lock();
    defer unlock();
    const f = files.get(key) orelse blk: {
        if (t == .unlock) return;
        const nf = try gpa.create(File);
        nf.* = .{};
        files.put(gpa, key, nf) catch {
            gpa.destroy(nf);
            return error.OutOfMemory;
        };
        break :blk nf;
    };
    var mine: ?usize = null;
    for (f.flocks.items, 0..) |l, i| {
        if (l.owner == owner) {
            mine = i;
            continue;
        }
        if (t != .unlock and (t == .write or l.exclusive)) {
            drop(key, f);
            return error.WouldBlock;
        }
    }
    if (t == .unlock) {
        if (mine) |i| _ = f.flocks.swapRemove(i);
    } else if (mine) |i| {
        f.flocks.items[i].exclusive = t == .write;
    } else {
        f.flocks.append(gpa, .{ .owner = owner, .exclusive = t == .write }) catch {
            drop(key, f);
            return error.OutOfMemory;
        };
    }
    _ = generation.fetchAdd(1, .monotonic);
    drop(key, f);
}

/// Releases a process's POSIX locks on one file (it closed an fd of it).
pub fn closedPosix(key: Key, owner_id: u64) void {
    lock();
    defer unlock();
    const f = files.get(key) orelse return;
    removeOwned(f, owner_id, true);
    drop(key, f);
}

/// Releases an open file description's OFD and flock locks (its last fd
/// closed).
pub fn closedOfd(key: Key, ofd: u64) void {
    lock();
    defer unlock();
    const f = files.get(key) orelse return;
    removeOwned(f, ofd, false);
    var i: usize = 0;
    while (i < f.flocks.items.len) {
        if (f.flocks.items[i].owner == ofd) _ = f.flocks.swapRemove(i) else i += 1;
    }
    _ = generation.fetchAdd(1, .monotonic);
    drop(key, f);
}

/// Releases every POSIX lock of a process that's ending.
pub fn endedPosix(owner_id: u64) void {
    lock();
    defer unlock();
    var dead: std.ArrayList(Key) = .empty;
    defer dead.deinit(gpa);
    var it = files.iterator();
    while (it.next()) |e| {
        removeOwned(e.value_ptr.*, owner_id, true);
        if (e.value_ptr.*.empty()) dead.append(gpa, e.key_ptr.*) catch {};
    }
    for (dead.items) |k| if (files.get(k)) |f| drop(k, f);
    _ = generation.fetchAdd(1, .monotonic);
}

fn removeOwned(f: *File, id: u64, posix: bool) void {
    var i: usize = 0;
    while (i < f.ranges.items.len) {
        const o = f.ranges.items[i].owner;
        if (o.id == id and o.posix == posix) _ = f.ranges.orderedRemove(i) else i += 1;
    }
}

/// The table's generation, bumped by every change.
pub fn gen() u64 {
    return generation.load(.monotonic);
}

const t_key: Key = .{ .dc = 'U', .dev = 1, .qpath = 42 };
const t_a: Owner = .{ .id = 1, .posix = true, .pid = 10 };
const t_b: Owner = .{ .id = 2, .posix = true, .pid = 11 };
const inf = std.math.maxInt(u64);

test "read locks share, a write lock conflicts, and unlock splits" {
    try set(t_key, t_a, .read, 0, 100);
    try set(t_key, t_b, .read, 50, 150);
    try std.testing.expectError(error.WouldBlock, set(t_key, t_b, .write, 0, 10));
    // A unlocks the middle of its range; B can now write there.
    try set(t_key, t_a, .unlock, 20, 40);
    try set(t_key, t_b, .write, 20, 40);
    try std.testing.expect(conflicting(t_key, .{ .owner = t_a, .type = .read, .start = 25, .end = 26 }) != null);
    try std.testing.expect(conflicting(t_key, .{ .owner = t_a, .type = .write, .start = 0, .end = 20 }) == null);
    // Upgrading in place doesn't conflict with oneself.
    try set(t_key, t_a, .write, 0, 20);
    endedPosix(t_a.id);
    endedPosix(t_b.id);
    try std.testing.expect(files.get(t_key) == null);
}

test "a lock to infinity, and closing releases POSIX locks only" {
    const ofd: Owner = .{ .id = 0xabc, .posix = false, .pid = -1 };
    try set(t_key, t_a, .write, 100, inf);
    try std.testing.expectError(error.WouldBlock, set(t_key, ofd, .read, 1 << 40, (1 << 40) + 1));
    closedPosix(t_key, t_a.id);
    try set(t_key, ofd, .read, 1 << 40, (1 << 40) + 1);
    try std.testing.expectError(error.WouldBlock, set(t_key, t_a, .write, 0, inf));
    closedOfd(t_key, ofd.id);
    try std.testing.expect(files.get(t_key) == null);
}

test "flock shares, excludes, converts and is separate from fcntl's" {
    try flock(t_key, 1, .read);
    try flock(t_key, 2, .read);
    try std.testing.expectError(error.WouldBlock, flock(t_key, 1, .write));
    try flock(t_key, 2, .unlock);
    try flock(t_key, 1, .write);
    try set(t_key, t_a, .write, 0, inf);
    try std.testing.expectError(error.WouldBlock, flock(t_key, 3, .read));
    closedOfd(t_key, 1);
    endedPosix(t_a.id);
    try std.testing.expect(files.get(t_key) == null);
}
