//! drawterm's qlock.c, rwlock.c, and sleep.c (design/kernel-port.md):
//! queueing locks, reader and writer locks, and sleep and wakeup, over
//! the host's primitives as before (a Lock is drawterm's, a host mutex
//! with PTHREAD, and a process waits in posix.c's procsleep). A close
//! translation: the same functions in the same order, with sleep's
//! error(Eintr) an error union.
//!
//! Every place a process waits is `park`, and every place one is let go
//! is `unpark`. A process the scheduler runs (design/scheduler.md) has a
//! kernel continuation (`Proc.cont`), and runs its kernel calls on it:
//! `park` saves the continuation and returns the host thread to its
//! executor, and `unpark` makes it runnable, for any executor to resume.
//! A process with no continuation (a kproc, or one on a host thread of
//! its own) waits in posix.c's procsleep as before. Which a process is
//! is fixed for its life, so a wakeup never takes the wrong path.

const std = @import("std");
const builtin = @import("builtin");
const port = @import("port.zig");
pub const sched = @import("sched/sched.zig");
const c = port.c;
const up = port.up;
const Error = port.Error;

/// A sleep condition, as C's int (*)(void*).
pub const Cond = *const fn (?*anyopaque) callconv(.c) c_int;

/// Whether processes can park on continuations on this host. Not yet on
/// the web host, whose continuations need Asyncify run on h9.wasm
/// (design/scheduler.md, step 6); there every process waits in os-wasm.c.
pub const can_park = !builtin.cpu.arch.isWasm();

/// p's kernel continuation, if the scheduler runs it.
pub fn contOf(p: *c.Proc) ?*sched.Cont {
    if (!can_park) return null;
    return @ptrCast(@alignCast(p.cont));
}

/// The process waits until another unparks it. Callers have taken
/// themselves off whatever lock they queued on.
pub fn park() void {
    if (can_park) {
        const p = up();
        if (contOf(p)) |k| {
            if (sched.cont.self() != k) port.kpanic("park: not on its continuation", .{});
            sched.park();
            // It may go on on another executor's host thread, whose `up`
            // is that executor's: it's this process again from here.
            c._setproc(p);
            return;
        }
    }
    c.procsleep();
}

/// Lets a parked process (or one about to park) go on.
pub fn unpark(p: *c.Proc) void {
    if (can_park) if (contOf(p)) |k| return sched.unpark(k);
    c.procwakeup(p);
}

/// Runs processes' kernel calls on continuations, on the calling host
/// thread (design/scheduler.md): `call` starts one, `resumeProc` goes on
/// with one an unpark made runnable (its continuation's `ready` hook).
/// Each sets `up` to the process for as long as its call runs, and back
/// to `home` (the host thread's own process, or none) when it returns or
/// parks.
pub const Kexec = struct {
    ex: sched.Executor,
    home: ?*c.Proc,

    pub fn init(pool: *sched.Pool, home: ?*c.Proc) Kexec {
        return .{ .ex = .init(pool), .home = home };
    }

    pub fn deinit(e: *Kexec) void {
        e.ex.deinit();
    }

    /// Runs f(arg) as p's kernel call, until it returns or parks. p must
    /// have a continuation, with no call in progress.
    pub fn call(e: *Kexec, p: *c.Proc, f: *const fn (?*anyopaque) void, arg: ?*anyopaque) sched.stack.Error!sched.Outcome {
        const k = contOf(p).?;
        c._setproc(p);
        defer c._setproc(e.home);
        return e.ex.call(k, f, arg);
    }

    /// Goes on with p's parked call, once an unpark made it runnable.
    pub fn resumeProc(e: *Kexec, p: *c.Proc) sched.Outcome {
        const k = contOf(p).?;
        c._setproc(p);
        defer c._setproc(e.home);
        return e.ex.@"resume"(k);
    }
};

// qlock.c

fn queue(first: *[*c]c.Proc, last: *[*c]c.Proc) void {
    const t = last.*;
    if (t == null)
        first.* = up()
    else
        t.*.qnext = up();
    last.* = up();
    up().qnext = null;
}

fn dequeue(first: *[*c]c.Proc, last: *[*c]c.Proc) ?*c.Proc {
    const t = first.*;
    if (t == null)
        return null;
    first.* = t.*.qnext;
    if (first.* == null)
        last.* = null;
    return t;
}

pub fn qlock(q: *c.QLock) void {
    c.lock(&q.lk);

    if (q.hold == null) {
        q.hold = up();
        c.unlock(&q.lk);
        return;
    }

    // Can't assert q.hold != up because of RWLock.

    queue(&q.first, &q.last);
    c.unlock(&q.lk);
    park();
}

pub fn canqlock(q: *c.QLock) bool {
    c.lock(&q.lk);
    if (q.hold == null) {
        q.hold = up();
        c.unlock(&q.lk);
        return true;
    }
    c.unlock(&q.lk);
    return false;
}

pub fn qunlock(q: *c.QLock) void {
    c.lock(&q.lk);
    // Can't assert q.hold == up because of RWLock.
    if (dequeue(&q.first, &q.last)) |p| {
        q.hold = p;
        c.unlock(&q.lk);
        unpark(p);
    } else {
        q.hold = null;
        c.unlock(&q.lk);
    }
}

pub fn holdqlock(q: *c.QLock) bool {
    return q.hold == up();
}

// rwlock.c

pub fn rlock(l: *c.RWLock) void {
    qlock(&l.x); // wait here for writers and exclusion
    c.lock(&l.lk);
    l.readers += 1;
    _ = canqlock(&l.k); // block writers if we are the first reader
    c.unlock(&l.lk);
    qunlock(&l.x);
}

pub fn runlock(l: *c.RWLock) void {
    c.lock(&l.lk);
    l.readers -= 1;
    if (l.readers == 0) // last reader out allows writers
        qunlock(&l.k);
    c.unlock(&l.lk);
}

pub fn wlock(l: *c.RWLock) void {
    qlock(&l.x); // wait here for writers and exclusion
    qlock(&l.k); // wait here for last reader
}

pub fn wunlock(l: *c.RWLock) void {
    qunlock(&l.k);
    qunlock(&l.x);
}

// sleep.c

/// Sleeps on r until f(arg) is true, or a note interrupts it, which is
/// error.Interrupted with Eintr as the process's error string.
pub fn sleep(r: *c.Rendez, f: Cond, arg: ?*anyopaque) Error!void {
    const s = c.splhi();

    c.lock(&r.lk);
    c.lock(&up().rlock);
    if (r.p != null) {
        port.print("double sleep %lud %lud\n", .{ r.p.*.pid, up().pid });
    }

    // Wakeup only knows there may be something to do by testing r.p in
    // order to get something to lock on. Flush that information out to
    // memory in case the sleep is committed.
    r.p = up();

    if (f(arg) != 0 or up().notepending != 0) {
        // If the condition happened or a note is pending, never mind.
        r.p = null;
        c.unlock(&up().rlock);
        c.unlock(&r.lk);
    } else {
        // Now we are committed to change state and call the scheduler.
        up().state = c.Wakeme;
        up().r = r;

        c.unlock(&up().rlock);
        c.unlock(&r.lk);

        park();
    }

    if (up().notepending != 0) {
        up().notepending = 0;
        c.splx(s);
        return port.interrupted();
    }

    c.splx(s);
}

pub fn wakeup(r: *c.Rendez) ?*c.Proc {
    const s = c.splhi();

    c.lock(&r.lk);
    const p: ?*c.Proc = r.p;

    if (p) |pp| {
        c.lock(&pp.rlock);
        if (pp.state != c.Wakeme or pp.r != r)
            port.kpanic("wakeup: state", .{});
        pp.state = c.Running;
        r.p = null;
        pp.r = null;
        c.unlock(&pp.rlock);
        c.unlock(&r.lk);
        unpark(pp);
    } else c.unlock(&r.lk);
    c.splx(s);

    return p;
}

/// If waking a sleeping process, this routine must hold both p.rlock
/// and r.lk. However, it can't know them in the same order as wakeup,
/// causing a possible lock ordering deadlock. We break the deadlock by
/// giving up p.rlock if we can't get r.lk, and retrying.
pub fn procinterrupt(p: *c.Proc) void {
    p.notepending = 1;

    // This loop is to avoid lock ordering problems.
    var s: c_int = undefined;
    while (true) {
        s = c.splhi();
        c.lock(&p.rlock);
        const r = p.r;

        // Waiting for a wakeup?
        if (r == null)
            break; // no

        // Try for the second lock.
        if (c.canlock(&r.*.lk) != 0) {
            if (p.state != c.Wakeme or r.*.p != p)
                port.kpanic("procinterrupt: state %d %d %d", .{ @as(c_int, @intFromBool(r.*.p != p)), @as(c_int, @intFromBool(p.r != r)), p.state });
            p.r = null;
            r.*.p = null;
            c.unlock(&p.rlock);
            c.unlock(&r.*.lk);
            // Hands off r.
            unpark(p);
            c.splx(s);
            return;
        }

        // Give the other process time to get out of the critical
        // section, and try again.
        c.unlock(&p.rlock);
        c.splx(s);

        c.osyield();
    }
    c.unlock(&p.rlock);
    c.splx(s);

    switch (p.state) {
        c.Rendezvous => {
            // Try and pull out of a rendezvous.
            c.lock(&p.rgrp.*.ref.lk);
            if (p.state == c.Rendezvous) {
                var l: *[*c]c.Proc = &p.rgrp.*.rendhash[@intFromPtr(p.rendtag) & (c.RENDHASH - 1)];
                var d = l.*;
                while (d != null) : (d = d.*.rendhash) {
                    if (d == p) {
                        l.* = p.rendhash;
                        p.rendval = @ptrFromInt(~@as(usize, 0));
                        c.unlock(&p.rgrp.*.ref.lk);
                        // Hands off p.rgrp.
                        unpark(p);
                        return;
                    }
                    l = &d.*.rendhash;
                }
            }
            c.unlock(&p.rgrp.*.ref.lk);
        },
        else => {},
    }
}

pub fn postnote(p: *c.Proc, x: c_int, msg: ?[*:0]const u8, flag: c_int) c_int {
    _ = x;
    _ = msg;
    _ = flag;
    procinterrupt(p);
    return 0;
}

/// h9's tsleep (src/kern/tsleep.zig): sleep on r until f(arg) is true
/// or ms milliseconds have passed, or a note interrupts it.
pub const tsleep = @import("tsleep.zig").tsleep;

// The C kernel's names, with its semantics: sleep raises Eintr.

fn c_qlock(q: *c.QLock) callconv(.c) void {
    qlock(q);
}
fn c_canqlock(q: *c.QLock) callconv(.c) c_int {
    return @intFromBool(canqlock(q));
}
fn c_qunlock(q: *c.QLock) callconv(.c) void {
    qunlock(q);
}
fn c_holdqlock(q: *c.QLock) callconv(.c) c_int {
    return @intFromBool(holdqlock(q));
}
fn c_rlock(l: *c.RWLock) callconv(.c) void {
    rlock(l);
}
fn c_runlock(l: *c.RWLock) callconv(.c) void {
    runlock(l);
}
fn c_wlock(l: *c.RWLock) callconv(.c) void {
    wlock(l);
}
fn c_wunlock(l: *c.RWLock) callconv(.c) void {
    wunlock(l);
}
fn c_sleep(r: *c.Rendez, f: Cond, arg: ?*anyopaque) callconv(.c) void {
    sleep(r, f, arg) catch |e| port.raise(e);
}
fn c_wakeup(r: *c.Rendez) callconv(.c) ?*c.Proc {
    return wakeup(r);
}
fn c_procinterrupt(p: *c.Proc) callconv(.c) void {
    procinterrupt(p);
}
fn c_postnote(p: *c.Proc, x: c_int, msg: ?[*:0]const u8, flag: c_int) callconv(.c) c_int {
    return postnote(p, x, msg, flag);
}

pub fn exportC() void {
    @export(&c_qlock, .{ .name = "qlock" });
    @export(&c_canqlock, .{ .name = "canqlock" });
    @export(&c_qunlock, .{ .name = "qunlock" });
    @export(&c_holdqlock, .{ .name = "holdqlock" });
    @export(&c_rlock, .{ .name = "rlock" });
    @export(&c_runlock, .{ .name = "runlock" });
    @export(&c_wlock, .{ .name = "wlock" });
    @export(&c_wunlock, .{ .name = "wunlock" });
    // lib.h renames sleep and wakeup, which a host libc has.
    @export(&c_sleep, .{ .name = "ksleep" });
    @export(&c_wakeup, .{ .name = "kwakeup" });
    @export(&c_procinterrupt, .{ .name = "procinterrupt" });
    @export(&c_postnote, .{ .name = "postnote" });
}

// Cases (zig build kern-test).

const testing = std.testing;
const kt = port.testing;

/// Waits (up to a few seconds) for f(arg) to hold.
fn waitFor(comptime f: anytype, arg: anytype) !void {
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        if (f(arg)) return;
        c.osmsleep(1);
    }
    return error.Timeout;
}

fn waiters(q: *c.QLock) usize {
    c.lock(&q.lk);
    defer c.unlock(&q.lk);
    var n: usize = 0;
    var p = q.first;
    while (p != null) : (p = p.*.qnext) n += 1;
    return n;
}

fn hasWaiter(q: *c.QLock) bool {
    return waiters(q) > 0;
}

const LockOrder = struct {
    q: c.QLock = std.mem.zeroes(c.QLock),
    order: [3]u8 = undefined,
    n: std.atomic.Value(usize) = .init(0),

    fn take(l: *LockOrder, id: u8) void {
        qlock(&l.q);
        l.order[l.n.fetchAdd(1, .acq_rel)] = id;
        qunlock(&l.q);
    }
};

test "qlock queues processes in order, and canqlock fails while it's held [kernel-port]" {
    _ = try kt.begin();
    var l: LockOrder = .{};
    qlock(&l.q);
    try testing.expect(holdqlock(&l.q));
    var a: kt.Kproc = undefined;
    try a.start(LockOrder.take, .{ &l, 'a' });
    try waitFor(hasWaiter, &l.q);
    var b: kt.Kproc = undefined;
    try b.start(LockOrder.take, .{ &l, 'b' });
    // b queues behind a.
    try waitFor(struct {
        fn f(q: *c.QLock) bool {
            return waiters(q) == 2;
        }
    }.f, &l.q);
    try testing.expectEqual(0, l.n.load(.acquire));
    try testing.expect(!canqlock(&l.q));
    l.order[l.n.fetchAdd(1, .acq_rel)] = 'm';
    qunlock(&l.q);
    a.join();
    b.join();
    try testing.expectEqualStrings("mab", &l.order);
    try testing.expect(!holdqlock(&l.q));
    try testing.expect(canqlock(&l.q));
    try testing.expect(holdqlock(&l.q));
    qunlock(&l.q);
}

const Rw = struct {
    l: c.RWLock = std.mem.zeroes(c.RWLock),
    wrote: std.atomic.Value(bool) = .init(false),

    fn reader(rw: *Rw, held: *std.atomic.Value(usize), release: *std.atomic.Value(bool)) void {
        rlock(&rw.l);
        _ = held.fetchAdd(1, .acq_rel);
        while (!release.load(.acquire)) c.osmsleep(1);
        runlock(&rw.l);
    }

    fn writer(rw: *Rw) void {
        wlock(&rw.l);
        rw.wrote.store(true, .release);
        wunlock(&rw.l);
    }
};

test "rlock lets readers share, and wlock waits for the last of them [kernel-port]" {
    _ = try kt.begin();
    var rw: Rw = .{};
    var held: std.atomic.Value(usize) = .init(0);
    var release: std.atomic.Value(bool) = .init(false);
    var r1: kt.Kproc = undefined;
    var r2: kt.Kproc = undefined;
    try r1.start(Rw.reader, .{ &rw, &held, &release });
    try r2.start(Rw.reader, .{ &rw, &held, &release });
    try waitFor(struct {
        fn f(h: *std.atomic.Value(usize)) bool {
            return h.load(.acquire) == 2;
        }
    }.f, &held);
    var w: kt.Kproc = undefined;
    try w.start(Rw.writer, .{&rw});
    try waitFor(hasWaiter, &rw.l.k);
    try testing.expect(!rw.wrote.load(.acquire));
    release.store(true, .release);
    r1.join();
    r2.join();
    w.join();
    try testing.expect(rw.wrote.load(.acquire));
    try testing.expectEqual(0, rw.l.readers);
}

const Flag = struct {
    r: c.Rendez = std.mem.zeroes(c.Rendez),
    set: std.atomic.Value(c_int) = .init(0),
    result: ?Error = null,
    errstr: [port.ERRMAX]u8 = undefined,

    fn isset(a: ?*anyopaque) callconv(.c) c_int {
        const f: *Flag = @ptrCast(@alignCast(a));
        return f.set.load(.acquire);
    }

    fn sleeper(f: *Flag) void {
        f.result = null;
        sleep(&f.r, isset, f) catch |e| {
            f.result = e;
            @memcpy(&f.errstr, up().errstr[0..port.ERRMAX]);
        };
    }

    fn tsleeper(f: *Flag) void {
        f.result = null;
        tsleep(&f.r, isset, f, 20) catch |e| {
            f.result = e;
        };
    }
};

test "sleep returns once its condition holds, and wakeup ends it [kernel-port]" {
    _ = try kt.begin();
    var f: Flag = .{};
    // Already true: no sleep.
    f.set.store(1, .release);
    try sleep(&f.r, Flag.isset, &f);
    try testing.expect(wakeup(&f.r) == null);
    f.set.store(0, .release);
    var k: kt.Kproc = undefined;
    try k.start(Flag.sleeper, .{&f});
    try kt.waitAsleep(k.proc());
    try testing.expect(f.r.p == k.proc());
    f.set.store(1, .release);
    try testing.expect(wakeup(&f.r) == k.proc());
    k.join();
    try testing.expectEqual(null, f.result);
    try testing.expect(f.r.p == null);
}

test "a note interrupts a sleep, and a pending one stops it before it starts [kernel-port]" {
    const me = try kt.begin();
    var f: Flag = .{};
    var k: kt.Kproc = undefined;
    try k.start(Flag.sleeper, .{&f});
    try kt.waitAsleep(k.proc());
    try testing.expectEqual(0, postnote(k.proc(), 0, null, 0));
    k.join();
    try testing.expectEqual(error.Interrupted, f.result.?);
    try testing.expectEqualStrings("interrupted", std.mem.sliceTo(&f.errstr, 0));
    try testing.expect(f.r.p == null);
    try testing.expectEqual(0, k.proc().notepending);

    // Our own note, posted before we sleep.
    me.notepending = 1;
    try testing.expectError(error.Interrupted, sleep(&f.r, Flag.isset, &f));
    try testing.expectEqualStrings("interrupted", kt.errstr());
    try testing.expectEqual(0, me.notepending);
}

extern fn h9_tflag_new() ?*anyopaque;
extern fn h9_tflag_free(f: ?*anyopaque) void;
extern fn h9_tflag_sleep(f: ?*anyopaque, ms: c_uint) c_int;

test "tsleep times out, and an interrupted one is -1 to C [kernel-port]" {
    _ = try kt.begin();
    var f: Flag = .{};
    var k: kt.Kproc = undefined;
    try k.start(Flag.tsleeper, .{&f});
    k.join();
    try testing.expectEqual(null, f.result);
    try testing.expectEqual(0, f.set.load(.acquire));

    // src/kern/tsleep.zig's test flag for C: an interrupt comes back as
    // its -1.
    const tflag = h9_tflag_new() orelse return error.OutOfMemory;
    defer h9_tflag_free(tflag);
    const T = struct {
        fn run(fl: ?*anyopaque, out: *c_int) void {
            out.* = h9_tflag_sleep(fl, 10000);
        }
    };
    var rv: c_int = 7;
    var t: kt.Kproc = undefined;
    try t.start(T.run, .{ tflag, &rv });
    try kt.waitAsleep(t.proc());
    procinterrupt(t.proc());
    t.join();
    try testing.expectEqual(-1, rv);
}

/// For the cases here and in qio.zig and devmnt.zig: processes the
/// scheduler runs, on continuations, with a run queue that their `ready`
/// hooks fill and an executor that drains it.
pub const ktest = struct {
    pub const Sproc = struct {
        k: sched.Cont = .{ .ready = ready },
        p: *c.Proc,
        rq: *sched.RunQueue,
        /// What its call left, for the case to check.
        err: ?anyerror = null,
        done: std.atomic.Value(bool) = .init(false),

        fn ready(k: *sched.Cont) void {
            const s: *Sproc = @fieldParentPtr("k", k);
            s.rq.push(k);
        }

        /// A new process, with no groups, whose calls run on its
        /// continuation.
        pub fn init(s: *Sproc, rq: *sched.RunQueue) void {
            s.* = .{ .p = c.newproc(), .rq = rq };
            s.p.cont = &s.k;
        }

        /// Starts f(args) as its call on e, and reports whether it
        /// parked; a failing f's error is kept in err.
        pub fn call(s: *Sproc, e: *Kexec, comptime f: anytype, args: anytype) !sched.Outcome {
            const Frame = struct {
                s: *Sproc,
                args: @TypeOf(args),
                fn run(v: ?*anyopaque) void {
                    const fr: *@This() = @ptrCast(@alignCast(v.?));
                    const sp = fr.s;
                    const r = @call(.auto, f, fr.args);
                    std.heap.page_allocator.destroy(fr);
                    if (@typeInfo(@TypeOf(r)) == .error_union) {
                        _ = r catch |err| {
                            sp.err = err;
                        };
                    }
                    sp.done.store(true, .release);
                }
            };
            // On the heap: it must outlive this call if f parks.
            const fr = try std.heap.page_allocator.create(Frame);
            fr.* = .{ .s = s, .args = args };
            s.done.store(false, .release);
            s.err = null;
            return e.call(s.p, Frame.run, fr);
        }

        pub fn isDone(s: *Sproc) bool {
            return s.done.load(.acquire);
        }
    };

    /// Resumes what's runnable on e until done(arg) holds, waiting up to
    /// a few seconds for unparks from other threads.
    pub fn runUntil(e: *Kexec, rq: *sched.RunQueue, comptime done: anytype, arg: anytype) !void {
        var idle: usize = 0;
        while (!done(arg)) {
            if (rq.pop()) |k| {
                const s: *Sproc = @fieldParentPtr("k", k);
                _ = e.resumeProc(s.p);
                idle = 0;
            } else {
                idle += 1;
                if (idle > 5000) return error.Timeout;
                c.osmsleep(1);
            }
        }
    }
};

const Queued = struct {
    q: c.QLock = std.mem.zeroes(c.QLock),
    order: [100]u16 = undefined,
    n: usize = 0,
    rs: [100]c.Rendez = std.mem.zeroes([100]c.Rendez),

    fn never(_: ?*anyopaque) callconv(.c) c_int {
        return 0;
    }

    fn body(l: *Queued, id: u16) Error!void {
        qlock(&l.q);
        l.order[l.n] = id;
        l.n += 1;
        qunlock(&l.q);
        // The timer kproc, on its own host thread, ends it.
        try tsleep(&l.rs[id], never, null, 2);
    }

    fn allDone(ps: []ktest.Sproc) bool {
        for (ps) |*s| if (!s.isDone()) return false;
        return true;
    }
};

test "a hundred processes wait in qlock and tsleep on one host thread [scheduler]" {
    const me = try kt.begin();
    var pool: sched.Pool = .{ .size = 64 * 1024 };
    defer pool.deinit();
    var rq: sched.RunQueue = .{};
    var e: Kexec = .init(&pool, me);
    defer e.deinit();
    var l: Queued = .{};
    var ps: [100]ktest.Sproc = undefined;
    for (&ps) |*s| s.init(&rq);

    qlock(&l.q);
    for (&ps, 0..) |*s, i| {
        try testing.expectEqual(sched.Outcome.parked, try s.call(&e, Queued.body, .{ &l, @as(u16, @intCast(i)) }));
        try testing.expect(up() == me);
    }
    // Each holds a stack, and this thread went on: none has run past qlock.
    try testing.expectEqual(@as(usize, 100), pool.mapped);
    try testing.expectEqual(@as(usize, 100), waiters(&l.q));
    try testing.expectEqual(@as(usize, 0), l.n);
    qunlock(&l.q);
    try ktest.runUntil(&e, &rq, Queued.allDone, @as([]ktest.Sproc, &ps));
    try testing.expectEqual(@as(usize, 100), l.n);
    for (l.order, 0..) |id, i| try testing.expectEqual(@as(u16, @intCast(i)), id);
    for (&ps) |*s| try testing.expectEqual(null, s.err);
    try testing.expect(up() == me);
}

test "a note or a wakeup ends a sleep parked on a continuation, and it runs as its own process [scheduler]" {
    const me = try kt.begin();
    var pool: sched.Pool = .{ .size = 64 * 1024 };
    defer pool.deinit();
    var rq: sched.RunQueue = .{};
    var e: Kexec = .init(&pool, me);
    defer e.deinit();
    var s: ktest.Sproc = undefined;
    s.init(&rq);
    var f: Flag = .{};

    try testing.expectEqual(sched.Outcome.parked, try s.call(&e, Flag.sleeper, .{&f}));
    try testing.expect(f.r.p == s.p);
    try testing.expect(s.k.isParked());
    try testing.expectEqual(0, postnote(s.p, 0, null, 0));
    try ktest.runUntil(&e, &rq, ktest.Sproc.isDone, &s);
    try testing.expectEqual(error.Interrupted, f.result.?);
    // The error string was the parked process's, not this thread's.
    try testing.expectEqualStrings("interrupted", std.mem.sliceTo(&f.errstr, 0));
    try testing.expectEqualStrings("interrupted", std.mem.sliceTo(s.p.errstr, 0));
    try testing.expect(up() == me);

    try testing.expectEqual(sched.Outcome.parked, try s.call(&e, Flag.sleeper, .{&f}));
    f.set.store(1, .release);
    try testing.expect(wakeup(&f.r) == s.p);
    try ktest.runUntil(&e, &rq, ktest.Sproc.isDone, &s);
    try testing.expectEqual(null, f.result);
    // With nothing to wait for, a call doesn't park, and its stack stays
    // with the executor.
    try testing.expectEqual(sched.Outcome.returned, try s.call(&e, Flag.sleeper, .{&f}));
    try testing.expect(e.ex.spare != null);
}
