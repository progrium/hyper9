//! ITIMER_REAL for Linux programs (design/0018-linux-personality.md,
//! "Signals"): setitimer and alarm. One kernel process serves every
//! process's timer, waking at least every `tick` while any is set, and
//! posts SIGALRM's note to a process whose timer is due, through a
//! reference to its record, so it reaches the process however it's
//! blocked. It ends two seconds after the last timer is cleared, since
//! some programs set and clear one around every request.

const std = @import("std");
const kern = @import("../kern.zig");
const lsig = @import("signal.zig");

const tick_ms = 5;

const Timer = struct {
    owner: usize,
    ref: *anyopaque,
    due: i64,
    interval: i64,
};

const gpa = @import("../web.zig").gpa;
var mutex: std.atomic.Mutex = .unlocked;
var timers: std.ArrayList(Timer) = .empty;
var running = false;

fn lock() void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

pub const Value = struct { left_ns: i64 = 0, interval_ns: i64 = 0 };

/// The timer of `owner`, as getitimer reports it.
pub fn get(owner: usize) Value {
    lock();
    defer mutex.unlock();
    for (timers.items) |t| if (t.owner == owner) return .{ .left_ns = @max(t.due - kern.monoNs(), 1), .interval_ns = t.interval };
    return .{};
}

/// Sets (or with a zero value, clears) the calling process's timer;
/// returns the old value.
pub fn set(owner: usize, v: Value) error{OutOfMemory}!Value {
    lock();
    var old: Value = .{};
    var dropped: ?*anyopaque = null;
    for (timers.items, 0..) |t, i| if (t.owner == owner) {
        old = .{ .left_ns = @max(t.due - kern.monoNs(), 1), .interval_ns = t.interval };
        dropped = t.ref;
        _ = timers.swapRemove(i);
        break;
    };
    var start = false;
    if (v.left_ns > 0) add: {
        const ref = dropped orelse kern.selfRef() orelse break :add;
        dropped = null;
        timers.append(gpa, .{ .owner = owner, .ref = ref, .due = kern.monoNs() + v.left_ns, .interval = v.interval_ns }) catch {
            mutex.unlock();
            kern.unref(ref);
            return error.OutOfMemory;
        };
        start = !running;
        running = true;
    }
    mutex.unlock();
    if (dropped) |r| kern.unref(r);
    if (start) kern.spawn("itimer", u8, run, &dummy) catch {
        lock();
        running = false;
        mutex.unlock();
    };
    return old;
}

/// The process is ending: its timer goes.
pub fn cancel(owner: usize) void {
    _ = set(owner, .{}) catch {};
}

var dummy: u8 = 0;

/// How long the kernel process waits with no timer set before it ends:
/// programs that set and clear a timer around every request
/// (PostgreSQL's) keep one process, not one per timer.
const idle_ms = 2000;

fn run(_: *u8) void {
    var buf: [32]u8 = undefined;
    const note = lsig.signalNote(lsig.SIGALRM, &buf);
    var idle: i64 = 0;
    while (true) {
        var wait: i64 = tick_ms;
        lock();
        if (timers.items.len == 0) {
            if (idle >= idle_ms) {
                running = false;
                mutex.unlock();
                return;
            }
            idle += tick_ms;
        } else idle = 0;
        const now = kern.monoNs();
        var i: usize = 0;
        // Notes are posted under the lock, so `set` can't release a
        // reference while it's in use here.
        while (i < timers.items.len) {
            const t = &timers.items[i];
            if (t.due <= now) {
                _ = kern.postNoteRef(t.ref, note, .user);
                if (t.interval > 0) {
                    t.due = now + t.interval;
                } else {
                    kern.unref(t.ref);
                    _ = timers.swapRemove(i);
                    continue;
                }
            }
            wait = @min(wait, @divTrunc(t.due - now + std.time.ns_per_ms - 1, std.time.ns_per_ms));
            i += 1;
        }
        mutex.unlock();
        kern.sleep(@max(wait, 1)) catch {};
    }
}
