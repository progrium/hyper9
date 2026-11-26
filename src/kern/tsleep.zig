//! h9's tsleep (src/kern/tsleep.c, design/kernel-port.md): sleep with a
//! timeout, with 9front's contract (port/proc.c), built only on the
//! kernel's sleep and wakeup. drawterm has no timers and no tsleep. See
//! design/epoch-0/semaphores.md. A close translation of the C: the same
//! functions in the same order, with the interrupt an error union.
//!
//! One timer kproc per kernel, started from h9_proc_boot, keeps a list of
//! deadlines sorted by host monotonic time, and waits on a host condition
//! variable (glue.c, glue-win32.c) until the earliest one or until an
//! earlier one is added. tsleep puts a timer on its own stack into the
//! list and sleeps until the timer has fired or its condition is true. At
//! the deadline the timer kproc marks the timer fired and calls wakeup on
//! its Rendez, as 9front's twakeup does.
//!
//! The list is guarded by the host lock (h9_tlock), which the timer kproc
//! holds while it calls wakeup. tsleep always takes the timer out under
//! that lock before it returns, including when a note interrupts it, so
//! no timer is touched after its stack frame is gone. Lock order: the
//! host lock, then a Rendez's lock; nothing takes them the other way
//! round.
//!
//! It waits only in sync.zig's sleep.

const std = @import("std");
const port = @import("port.zig");
const sync = @import("sync.zig");
const c = port.c;
const up = port.up;
const Error = port.Error;
const Cond = sync.Cond;

const Timer = struct {
    next: ?*Timer = null,
    when: u64 = 0, // host monotonic ns
    r: *c.Rendez,
    @"fn": Cond,
    arg: ?*anyopaque,
    fired: std.atomic.Value(c_int) = .init(0), // set by the timer kproc, under the host lock
    queued: bool = false, // in the list; under the host lock
};

var timers: ?*Timer = null; // sorted by when; under the host lock
var ntimers: c_int = 0; // for the unit test

/// sleep's condition: the timer has fired, or the caller's is true.
fn tfn(v: ?*anyopaque) callconv(.c) c_int {
    const t: *Timer = @ptrCast(@alignCast(v));
    return @intFromBool(t.fired.load(.seq_cst) != 0 or t.@"fn"(t.arg) != 0);
}

fn tadd(t: *Timer) void {
    c.h9_tlock();
    var l: *?*Timer = &timers;
    while (l.*) |n| : (l = &n.next) {
        if (n.when > t.when) break;
    }
    t.next = l.*;
    l.* = t;
    t.queued = true;
    ntimers += 1;
    // A new earliest deadline: the kproc waits for a later one.
    if (timers == t)
        c.h9_tsignal();
    c.h9_tunlock();
}

fn tdel(t: *Timer) void {
    c.h9_tlock();
    if (t.queued) {
        var l: *?*Timer = &timers;
        while (l.*) |n| : (l = &n.next) {
            if (n == t) {
                l.* = t.next;
                break;
            }
        }
        t.queued = false;
        ntimers -= 1;
    }
    c.h9_tunlock();
}

/// The timer kproc.
fn timerproc(v: ?*anyopaque) callconv(.c) void {
    _ = v;
    c.h9_tlock();
    while (true) {
        const now = c.h9_tnow();
        while (timers) |t| {
            if (t.when > now) break;
            timers = t.next;
            t.queued = false;
            ntimers -= 1;
            t.fired.store(1, .seq_cst);
            _ = sync.wakeup(t.r);
        }
        c.h9_twait(if (timers) |t| t.when else 0);
    }
}

pub fn tsleepinit() void {
    c.h9_tinit();
    _ = c.kproc(@constCast("timer"), &timerproc, null);
}

/// Sleeps on r until f(arg) is true or ms milliseconds have passed, as
/// 9front's tsleep; or, if a note arrives, returns error.Interrupted
/// with "interrupted" as the error string.
pub fn tsleep(r: *c.Rendez, f: Cond, arg: ?*anyopaque, ms: c_uint) Error!void {
    var t: Timer = .{ .r = r, .@"fn" = f, .arg = arg };
    t.when = c.h9_tnow() + @as(u64, ms) * 1000000;
    tadd(&t);
    defer tdel(&t);
    try sync.sleep(r, tfn, &t);
}

// The C kernel's names.

fn c_h9_tsleepinit() callconv(.c) void {
    tsleepinit();
}

/// tsleep for C: like sleep, it raises "interrupted" if a note arrives.
fn c_tsleep(r: *c.Rendez, f: Cond, arg: ?*anyopaque, ms: c_uint) callconv(.c) void {
    tsleep(r, f, arg, ms) catch |e| port.raise(e);
}

// For the unit tests in src/kern.zig and sync.zig: a flag to sleep on,
// the number of timers in the list, and the host monotonic clock.

const Tflag = struct {
    r: c.Rendez = std.mem.zeroes(c.Rendez),
    set: std.atomic.Value(c_int) = .init(0),
};

fn isset(v: ?*anyopaque) callconv(.c) c_int {
    const f: *Tflag = @ptrCast(@alignCast(v));
    return f.set.load(.seq_cst);
}

fn h9_tflag_new() callconv(.c) ?*anyopaque {
    const f: *Tflag = @ptrCast(@alignCast(port.malloc(@sizeOf(Tflag)) orelse return null));
    f.* = .{};
    return f;
}

fn h9_tflag_free(f: ?*anyopaque) callconv(.c) void {
    c.free(f);
}

fn h9_tflag_set(v: ?*anyopaque) callconv(.c) void {
    const f: *Tflag = @ptrCast(@alignCast(v));
    f.set.store(1, .seq_cst);
    _ = sync.wakeup(&f.r);
}

/// tsleep on the flag: 1 if it was set, 0 if not (a timeout), -1 if
/// interrupted, with the error in syserrstr, as a system call leaves it.
fn h9_tflag_sleep(v: ?*anyopaque, ms: c_uint) callconv(.c) c_int {
    const f: *Tflag = @ptrCast(@alignCast(v));
    tsleep(&f.r, isset, f, ms) catch {
        const p = up().syserrstr;
        up().syserrstr = up().errstr;
        up().errstr = p;
        return -1;
    };
    return isset(f);
}

fn h9_ntimers() callconv(.c) c_int {
    c.h9_tlock();
    const n = ntimers;
    c.h9_tunlock();
    return n;
}

fn h9_kern_nanomono() callconv(.c) u64 {
    return c.h9_tnow();
}

pub fn exportC() void {
    @export(&c_h9_tsleepinit, .{ .name = "h9_tsleepinit" });
    @export(&c_tsleep, .{ .name = "tsleep" });
    @export(&h9_tflag_new, .{ .name = "h9_tflag_new" });
    @export(&h9_tflag_free, .{ .name = "h9_tflag_free" });
    @export(&h9_tflag_set, .{ .name = "h9_tflag_set" });
    @export(&h9_tflag_sleep, .{ .name = "h9_tflag_sleep" });
    @export(&h9_ntimers, .{ .name = "h9_ntimers" });
    @export(&h9_kern_nanomono, .{ .name = "h9_kern_nanomono" });
}

// Cases (zig build kern-test).

const testing = std.testing;
const kt = port.testing;

test "tsleep wakes at its deadline or its condition, and leaves no timer [kernel-port]" {
    _ = try kt.begin();
    const f: *Tflag = @ptrCast(@alignCast(h9_tflag_new().?));
    defer h9_tflag_free(f);
    const t0 = c.h9_tnow();
    try tsleep(&f.r, isset, f, 30);
    try testing.expect(c.h9_tnow() - t0 >= 30 * std.time.ns_per_ms);
    try testing.expectEqual(0, h9_ntimers());

    // Already true: no wait.
    h9_tflag_set(f);
    try tsleep(&f.r, isset, f, 10000);
    try testing.expectEqual(1, h9_tflag_sleep(f, 10000));
    try testing.expectEqual(0, h9_ntimers());
}

test "a note interrupts tsleep, and its timer is taken out [kernel-port]" {
    _ = try kt.begin();
    const f: *Tflag = @ptrCast(@alignCast(h9_tflag_new().?));
    defer h9_tflag_free(f);
    const T = struct {
        fn run(fl: *Tflag, out: *?Error) void {
            out.* = null;
            tsleep(&fl.r, isset, fl, 10000) catch |e| {
                out.* = e;
            };
        }
    };
    var rv: ?Error = null;
    var k: kt.Kproc = undefined;
    try k.start(T.run, .{ f, &rv });
    try kt.waitAsleep(k.proc());
    try testing.expectEqual(1, h9_ntimers());
    sync.procinterrupt(k.proc());
    k.join();
    try testing.expectEqual(error.Interrupted, rv.?);
    try testing.expectEqual(0, h9_ntimers());
}
