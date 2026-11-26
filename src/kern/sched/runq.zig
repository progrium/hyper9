//! A run queue (design/scheduler.md): continuations an unpark made
//! runnable, in the order they were made so, for an executor to resume.
//! It's intrusive (`Cont.next`), so queueing never allocates, and a
//! `ready` hook, which runs on whatever thread unparked, can always
//! queue. Any thread may push and pop.

const std = @import("std");
const Cont = @import("cont.zig").Cont;

pub const RunQueue = struct {
    lock: std.atomic.Mutex = .unlocked,
    head: ?*Cont = null,
    tail: ?*Cont = null,
    len: std.atomic.Value(usize) = .init(0),

    fn acquire(q: *RunQueue) void {
        while (!q.lock.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn push(q: *RunQueue, k: *Cont) void {
        k.next = null;
        q.acquire();
        if (q.tail) |t| t.next = k else q.head = k;
        q.tail = k;
        _ = q.len.fetchAdd(1, .release);
        q.lock.unlock();
    }

    pub fn pop(q: *RunQueue) ?*Cont {
        if (q.len.load(.acquire) == 0) return null;
        q.acquire();
        defer q.lock.unlock();
        const k = q.head orelse return null;
        q.head = k.next;
        if (q.head == null) q.tail = null;
        k.next = null;
        _ = q.len.fetchSub(1, .release);
        return k;
    }

    pub fn isEmpty(q: *const RunQueue) bool {
        return q.len.load(.acquire) == 0;
    }
};

test "a run queue gives back what was pushed, in order [scheduler]" {
    const noop = struct {
        fn f(_: *Cont) void {}
    }.f;
    var ks: [3]Cont = .{ .{ .ready = noop }, .{ .ready = noop }, .{ .ready = noop } };
    var q: RunQueue = .{};
    try std.testing.expect(q.pop() == null);
    for (&ks) |*k| q.push(k);
    try std.testing.expect(q.pop() == &ks[0]);
    q.push(&ks[0]);
    try std.testing.expect(q.pop() == &ks[1]);
    try std.testing.expect(q.pop() == &ks[2]);
    try std.testing.expect(q.pop() == &ks[0]);
    try std.testing.expect(q.isEmpty());
}
