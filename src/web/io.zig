//! The web host's `std.Io` (design/browser-host.md): std's
//! single-threaded implementation over WASI, with blocking that parks the
//! calling coroutine (src/web/coro.c) instead of a thread. A futex wait
//! parks until a wake for the same address; a sleep parks on a timer.
//! Everything else, files and clocks included, is std's WASI code, which
//! the JS host serves.

const std = @import("std");
const coro = @import("coro.zig");

const Threaded = std.Io.Threaded;

/// A coroutine waiting on a futex address. Waiters live on their own
/// stacks while they wait.
const Waiter = struct {
    addr: usize,
    coro: *coro.Coro,
    next: ?*Waiter = null,
    woken: bool = false,
};

var waiters: ?*Waiter = null;

fn unlink(w: *Waiter) void {
    var l = &waiters;
    while (l.*) |x| : (l = &x.next) if (x == w) {
        l.* = w.next;
        return;
    };
}

/// Parks on `ptr` while it holds `expected`, for at most `ms` (or for good
/// when negative). Returns early on a wake, or spuriously.
fn wait(ptr: *const u32, expected: u32, ms: i64) void {
    if (@atomicLoad(u32, ptr, .acquire) != expected) return;
    var w: Waiter = .{ .addr = @intFromPtr(ptr), .coro = coro.self(), .next = waiters };
    waiters = &w;
    while (!w.woken) {
        if (!coro.park(ms)) break; // timed out
        // An unrelated unpark (procwakeup, say) is a spurious wakeup.
        break;
    }
    if (!w.woken) unlink(&w);
}

fn timeoutMs(t: std.Io.Timeout) i64 {
    return switch (t) {
        .none => -1,
        .duration => |d| @intCast(@min(@divTrunc(d.raw.nanoseconds + 999_999, 1_000_000), std.math.maxInt(i32))),
        .deadline => |d| blk: {
            const now = std.Io.Timestamp.now(io(), d.clock);
            const ns: i96 = now.durationTo(d.raw).nanoseconds;
            break :blk @intCast(std.math.clamp(@divTrunc(ns + 999_999, 1_000_000), 0, std.math.maxInt(i32)));
        },
    };
}

fn futexWait(_: ?*anyopaque, ptr: *const u32, expected: u32, timeout: std.Io.Timeout) std.Io.Cancelable!void {
    wait(ptr, expected, timeoutMs(timeout));
}

fn futexWaitUncancelable(_: ?*anyopaque, ptr: *const u32, expected: u32) void {
    wait(ptr, expected, -1);
}

fn futexWake(_: ?*anyopaque, ptr: *const u32, max_waiters: u32) void {
    var n: u32 = 0;
    var l = &waiters;
    while (l.*) |w| {
        if (n >= max_waiters) break;
        if (w.addr != @intFromPtr(ptr)) {
            l = &w.next;
            continue;
        }
        l.* = w.next;
        w.woken = true;
        coro.unpark(w.coro);
        n += 1;
    }
}

fn sleep(_: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
    const ms = timeoutMs(timeout);
    if (ms < 0) {
        // Forever: nothing will wake it.
        while (true) coro.sleep(1 << 30);
    }
    coro.sleep(ms);
}

const vtable: std.Io.VTable = blk: {
    var v = Threaded.global_single_threaded.io().vtable.*;
    v.futexWait = futexWait;
    v.futexWaitUncancelable = futexWaitUncancelable;
    v.futexWake = futexWake;
    v.sleep = sleep;
    break :blk v;
};

/// The web host's Io.
pub fn io() std.Io {
    return .{ .userdata = Threaded.global_single_threaded, .vtable = &vtable };
}
