//! h9's rendezvous and semaphores (src/kern/sema.c, design/kernel-port.md).
//! See design/epoch-0/semaphores.md. A close translation of the C: the
//! same functions in the same order, with error unions in place of
//! waserror.
//!
//! The semaphore code is 9front's (port/sysproc.c at the pinned release),
//! ported closely, races and comments included, since it was checked with
//! spin. It differs in two ways:
//!
//! - The wait lists live in a kernel-wide table of hashed buckets, each
//!   with its own lock, rather than in the segment, keyed by the host
//!   address of the semaphore word. Every address space sharing a segment
//!   maps the same host pages, and a segment's pages never move
//!   (src/segment.zig), so the host address names the same semaphore in
//!   every sharer, as 9front's (segment, address) pair does. Machines
//!   never share guest pages, so one table serves them all.
//! - The value is a 32-bit word (Plan 9's long, drawterm's int) in host
//!   memory that backs guest memory, changed with host atomics. That
//!   memory is what the guest's own loads, stores and exclusives see.
//!
//! The callers (src/abi/plan9/syscall.zig) have checked the address: it's
//! aligned, mapped and writable, and stays valid while the caller is
//! blocked.
//!
//! rendezvous is 9front's sysrendezvous on drawterm's Rgrp and Proc
//! fields, so procinterrupt pulls a process out of it as before. Unlike
//! drawterm's _sysrendezvous it checks for a pending note before it
//! sleeps: a note that arrives after the call starts but before the
//! process is on the hash list would otherwise not wake it.
//!
//! It waits only in sync.zig: sleep, tsleep, and park.

const std = @import("std");
const port = @import("port.zig");
const sync = @import("sync.zig");
const tsleepz = @import("tsleep.zig");
const c = port.c;
const up = port.up;
const Error = port.Error;

// The C's coherence() is __atomic_thread_fence(__ATOMIC_SEQ_CST), which
// Zig doesn't have. The words it orders (the semaphore value,
// Sema.waiting, and in rendezvous the process's state and notepending)
// are all read and written here as sequentially consistent atomics,
// which are ordered among themselves, so the calls are kept as comments.

/// A word the guest also changes: only ever accessed atomically.
fn cmpswap(addr: *c_int, old: c_int, new: c_int) bool {
    return @cmpxchgStrong(c_int, addr, old, new, .seq_cst, .seq_cst) == null;
}

fn semvalue(addr: *c_int) c_int {
    return @atomicLoad(c_int, addr, .seq_cst);
}

const Sema = struct {
    r: c.Rendez = std.mem.zeroes(c.Rendez),
    addr: ?*c_int = null,
    waiting: c_int = 0,
    next: *Sema = undefined,
    prev: *Sema = undefined,
};

/// A bucket: a circular list of waiters, with head as its sentinel.
const Semq = struct {
    lk: c.Lock = std.mem.zeroes(c.Lock),
    head: Sema = .{},
};

const NSEMQ = 64;

var semtab: [NSEMQ]Semq = @splat(.{});

/// Called once at boot, from h9_proc_boot (proc.c).
pub fn semainit() void {
    for (&semtab) |*q| {
        q.head.next = &q.head;
        q.head.prev = &q.head;
    }
}

fn semq(a: *c_int) *Semq {
    var h: usize = @intFromPtr(a) >> 2;
    h ^= h >> 6;
    return &semtab[h % NSEMQ];
}

fn waiting(p: *Sema) bool {
    return @atomicLoad(c_int, &p.waiting, .seq_cst) != 0;
}

fn setwaiting(p: *Sema, v: c_int) void {
    @atomicStore(c_int, &p.waiting, v, .seq_cst);
}

// The implementation of semaphores is complicated by needing
// to avoid rescheduling in syssemrelease, so that it is safe
// to call from real-time processes.  This means syssemrelease
// cannot acquire any qlocks, only spin locks.
//
// Semacquire and semrelease must both manipulate the semaphore
// wait list.  Lock-free linked lists only exist in theory, not
// in practice, so the wait list is protected by a spin lock.
//
// The semaphore value *addr is stored in user memory, so it
// cannot be read or written while holding spin locks.
//
// Thus, we can access the list only when holding the lock, and
// we can access the semaphore only when not holding the lock.
// This makes things interesting.  Note that sleep's condition function
// is called while holding two locks - r and up->rlock - so it cannot
// access the semaphore value either.
//
// An acquirer announces its intention to try for the semaphore
// by putting a Sema structure onto the wait list and then
// setting Sema.waiting.  After one last check of semaphore,
// the acquirer sleeps until Sema.waiting==0.  A releaser of n
// must wake up n acquirers who have Sema.waiting set.  It does
// this by clearing Sema.waiting and then calling wakeup.
//
// There are three interesting races here.
//
// The first is that in this particular sleep/wakeup usage, a single
// wakeup can rouse a process from two consecutive sleeps!
// The ordering is:
//
//     (a) set Sema.waiting = 1
//     (a) call sleep
//     (b) set Sema.waiting = 0
//     (a) check Sema.waiting inside sleep, return w/o sleeping
//     (a) try for semaphore, fail
//     (a) set Sema.waiting = 1
//     (a) call sleep
//     (b) call wakeup(a)
//     (a) wake up again
//
// This is okay - semacquire will just go around the loop
// again.  It does mean that at the top of the for(;;) loop in
// semacquire, phore.waiting might already be set to 1.
//
// The second is that a releaser might wake an acquirer who is
// interrupted before he can acquire the lock.  Since
// release(n) issues only n wakeup calls -- only n can be used
// anyway -- if the interrupted process is not going to use his
// wakeup call he must pass it on to another acquirer.
//
// The third race is similar to the second but more subtle.  An
// acquirer sets waiting=1 and then does a final canacquire()
// before going to sleep.  The opposite order would result in
// missing wakeups that happen between canacquire and
// waiting=1.  (In fact, the whole point of Sema.waiting is to
// avoid missing wakeups between canacquire() and sleep().) But
// there can be spurious wakeups between a successful
// canacquire() and the following semdequeue().  This wakeup is
// not useful to the acquirer, since he has already acquired
// the semaphore.  Like in the previous case, though, the
// acquirer must pass the wakeup call along.
//
// This is all rather subtle.  The code below has been verified
// with the spin model /sys/src/9/port/semaphore.p.  The
// original code anticipated the second race but not the first
// or third, which were caught only with spin.  The first race
// is mentioned in /sys/doc/sleep.ps, but I'd forgotten about it.
// It was lucky that my abstract model of sleep/wakeup still managed
// to preserve that behavior.
//
// I remain slightly concerned about memory coherence
// outside of locks.  The spin model does not take
// queued processor writes into account so we have to
// think hard.  The only variables accessed outside locks
// are the semaphore value itself and the boolean flag
// Sema.waiting.  The value is only accessed with cmpswap,
// whose job description includes doing the right thing as
// far as memory coherence across processors.  That leaves
// Sema.waiting.  To handle it, we call coherence() before each
// read and after each write.        - rsc

/// Add semaphore p with addr a to its bucket's list.
fn semqueue(a: *c_int, p: *Sema) void {
    p.* = .{};
    p.addr = a;
    const q = semq(a);
    c.lock(&q.lk);
    p.next = &q.head;
    p.prev = q.head.prev;
    p.next.prev = p;
    p.prev.next = p;
    c.unlock(&q.lk);
}

/// Remove semaphore p from its bucket's list.
fn semdequeue(p: *Sema) void {
    const q = semq(p.addr.?);
    c.lock(&q.lk);
    p.next.prev = p.prev;
    p.prev.next = p.next;
    c.unlock(&q.lk);
}

/// Wake up n waiters with addr a.
fn semwakeup(a: *c_int, n_: c_int) void {
    var n = n_;
    const q = semq(a);
    c.lock(&q.lk);
    var p = q.head.next;
    while (p != &q.head and n > 0) : (p = p.next) {
        if (p.addr == a and waiting(p)) {
            setwaiting(p, 0);
            // coherence();
            _ = sync.wakeup(&p.r);
            n -= 1;
        }
    }
    c.unlock(&q.lk);
}

/// Add delta to semaphore and wake up waiters as appropriate.
fn semrelease(addr: *c_int, delta: c_int) c_int {
    // Wraps as 9front's does.
    var value: c_int = undefined;
    while (true) {
        value = semvalue(addr);
        if (cmpswap(addr, value, value +% delta)) break;
    }
    semwakeup(addr, delta);
    return value +% delta;
}

/// Try to acquire semaphore using compare-and-swap
fn canacquire(addr: *c_int) bool {
    while (true) {
        const value = semvalue(addr);
        if (value <= 0) return false;
        if (cmpswap(addr, value, value - 1))
            return true;
    }
}

/// Should we wake up?
fn semawoke(p: ?*anyopaque) callconv(.c) c_int {
    // coherence();
    return @intFromBool(!waiting(@ptrCast(@alignCast(p))));
}

/// Acquire semaphore (subtract 1).
fn semacquire(addr: *c_int, block: bool) Error!bool {
    if (canacquire(addr))
        return true;
    if (!block)
        return false;
    var phore: Sema = undefined;
    semqueue(addr, &phore);
    var err: ?Error = null;
    while (true) {
        setwaiting(&phore, 1);
        // coherence();
        if (canacquire(addr))
            break;
        sync.sleep(&phore.r, semawoke, &phore) catch |e| {
            err = e;
            break;
        };
    }
    semdequeue(&phore);
    // coherence();    // not strictly necessary due to lock in semdequeue
    if (!waiting(&phore))
        semwakeup(addr, 1);
    if (err) |e|
        return e;
    return true;
}

/// Acquire semaphore or time-out. The deadline is taken from the
/// monotonic clock once, so spurious wakeups don't stretch the timeout.
fn tsemacquire(addr: *c_int, ms_: c_uint) Error!bool {
    var ms = ms_;
    if (canacquire(addr))
        return true;
    if (ms == 0)
        return false;
    var timedout = false;
    const deadline = c.h9_tnow() + @as(u64, ms) * 1000000;
    var phore: Sema = undefined;
    semqueue(addr, &phore);
    var err: ?Error = null;
    while (true) {
        setwaiting(&phore, 1);
        // coherence();
        if (canacquire(addr))
            break;
        tsleepz.tsleep(&phore.r, semawoke, &phore, ms) catch |e| {
            err = e;
            break;
        };
        const now = c.h9_tnow();
        if (now >= deadline) {
            timedout = true;
            break;
        }
        ms = @intCast((deadline - now + 999999) / 1000000);
    }
    semdequeue(&phore);
    // coherence();    // not strictly necessary due to lock in semdequeue
    if (!waiting(&phore))
        semwakeup(addr, 1);
    if (err) |e|
        return e;
    return !timedout;
}

/// 9front's syssemacquire. After a successful call the note that
/// interrupts calls is cleared, as drawterm's sys* wrappers do; the note
/// itself is still queued for delivery (proc.c).
pub fn syssemacquire(addr: *c_int, block: bool) Error!bool {
    if (semvalue(addr) < 0)
        return port.kerror(&port.Ebadarg);
    const r = try semacquire(addr, block);
    up().notepending = 0;
    return r;
}

/// 9front's systsemacquire, with syssemacquire's notepending.
pub fn systsemacquire(addr: *c_int, ms: c_uint) Error!bool {
    if (semvalue(addr) < 0)
        return port.kerror(&port.Ebadarg);
    const r = try tsemacquire(addr, ms);
    up().notepending = 0;
    return r;
}

/// 9front's syssemrelease: the new value.
pub fn syssemrelease(addr: *c_int, count: c_int) Error!c_int {
    // count == 0 is a no-op, not a release
    if (count < 0 or semvalue(addr) < 0)
        return port.kerror(&port.Ebadarg);
    return semrelease(addr, count);
}

fn REND(p: *c.Proc, tag: usize) *[*c]c.Proc {
    return &p.rgrp.*.rendhash[tag & (c.RENDHASH - 1)];
}

/// 9front's sysrendezvous. Returns the other process's value, or ~0 if a
/// note interrupted the wait.
pub fn rendezvous(tag: usize, new: usize) usize {
    const me = up();
    var l = REND(me, tag);

    c.lock(&me.rgrp.*.ref.lk);
    var p_: ?*c.Proc = l.*;
    while (p_) |p| : (p_ = p.rendhash) {
        if (@intFromPtr(p.rendtag) == tag) {
            l.* = p.rendhash;
            const val = @intFromPtr(p.rendval);
            p.rendval = @ptrFromInt(new);
            c.unlock(&me.rgrp.*.ref.lk);

            sync.unpark(p);

            return val;
        }
        l = &p.rendhash;
    }

    // Going to sleep here
    me.rendtag = @ptrFromInt(tag);
    me.rendval = @ptrFromInt(new);
    me.rendhash = l.*;
    l.* = me;
    // procinterrupt sets notepending and then reads state; this sets
    // state and then reads notepending. With each a sequentially
    // consistent atomic (the C's coherence() between them), one of them
    // sees the other's write: either procinterrupt finds this process
    // on the list, or this sees the note.
    @atomicStore(c_uint, &me.state, c.Rendezvous, .seq_cst);
    if (@atomicLoad(c_int, &me.notepending, .seq_cst) != 0) {
        l = REND(me, tag);
        while (l.* != null) : (l = &l.*.*.rendhash) {
            if (l.* == me) {
                // Still waiting: give up, without sleeping.
                l.* = me.rendhash;
                me.rendval = @ptrFromInt(~@as(usize, 0));
                me.state = c.Running;
                c.unlock(&me.rgrp.*.ref.lk);
                me.notepending = 0;
                return ~@as(usize, 0);
            }
        }
        // Already taken off by a partner or by procinterrupt, under
        // this lock; either calls procwakeup, so sleep for it.
    }
    c.unlock(&me.rgrp.*.ref.lk);

    sync.park();

    me.state = c.Running;
    // As drawterm's sys* wrappers do after every call that returns.
    me.notepending = 0;
    return @intFromPtr(me.rendval);
}

// The C names, which src/kern.zig and proc.c call: each returns -1 with
// the error in syserrstr, as drawterm's sys* wrappers leave it.

fn syserr() c_int {
    const p = up().syserrstr;
    up().syserrstr = up().errstr;
    up().errstr = p;
    return -1;
}

fn h9_semainit() callconv(.c) void {
    semainit();
}

fn h9_semacquire(addr: *c_int, block: c_int) callconv(.c) c_int {
    return @intFromBool(syssemacquire(addr, block != 0) catch return syserr());
}

fn h9_tsemacquire(addr: *c_int, ms: c_uint) callconv(.c) c_int {
    return @intFromBool(systsemacquire(addr, ms) catch return syserr());
}

/// Returns 0 with the new value in value, or -1 with the error string
/// set.
fn h9_semrelease(addr: *c_int, count: c_int, value: *c_int) callconv(.c) c_int {
    value.* = syssemrelease(addr, count) catch return syserr();
    return 0;
}

fn h9_rendezvous(tag: usize, new: usize) callconv(.c) usize {
    return rendezvous(tag, new);
}

pub fn exportC() void {
    @export(&h9_semainit, .{ .name = "h9_semainit" });
    @export(&h9_semacquire, .{ .name = "h9_semacquire" });
    @export(&h9_tsemacquire, .{ .name = "h9_tsemacquire" });
    @export(&h9_semrelease, .{ .name = "h9_semrelease" });
    @export(&h9_rendezvous, .{ .name = "h9_rendezvous" });
}

// Cases (zig build kern-test).

const testing = std.testing;
const kt = port.testing;

test "semacquire takes a count, and waits for semrelease [kernel-port]" {
    _ = try kt.begin();
    var word: c_int = 1;
    try testing.expect(try syssemacquire(&word, true));
    try testing.expectEqual(0, word);
    try testing.expect(!try syssemacquire(&word, false));
    try testing.expect(!try systsemacquire(&word, 0));

    const T = struct {
        fn run(w: *c_int, got: *?bool) void {
            got.* = syssemacquire(w, true) catch null;
        }
    };
    var got: ?bool = null;
    var k: kt.Kproc = undefined;
    try k.start(T.run, .{ &word, &got });
    try kt.waitAsleep(k.proc());
    try testing.expectEqual(1, try syssemrelease(&word, 1));
    k.join();
    try testing.expectEqual(true, got);
    try testing.expectEqual(0, word);
}

test "tsemacquire times out, and bad values fail with Ebadarg [kernel-port]" {
    _ = try kt.begin();
    var word: c_int = 0;
    const t0 = c.h9_tnow();
    try testing.expect(!try systsemacquire(&word, 30));
    try testing.expect(c.h9_tnow() - t0 >= 30 * std.time.ns_per_ms);
    try testing.expectError(error.Kernel, syssemrelease(&word, -1));
    try testing.expectEqualStrings("bad arg in system call", kt.errstr());
    word = -1;
    try testing.expectError(error.Kernel, syssemacquire(&word, true));
    // The C names leave the error in syserrstr.
    var v: c_int = 0;
    try testing.expectEqual(-1, h9_semrelease(&word, 1, &v));
    try testing.expectEqualStrings("bad arg in system call", std.mem.sliceTo(up().syserrstr, 0));
}

test "a note interrupts semacquire, and passes on a release it was woken for [kernel-port]" {
    _ = try kt.begin();
    var word: c_int = 0;
    const T = struct {
        fn run(w: *c_int, got: *?Error) void {
            got.* = null;
            _ = syssemacquire(w, true) catch |e| {
                got.* = e;
            };
        }
    };
    var got: ?Error = null;
    var k: kt.Kproc = undefined;
    try k.start(T.run, .{ &word, &got });
    try kt.waitAsleep(k.proc());
    sync.procinterrupt(k.proc());
    k.join();
    try testing.expectEqual(error.Interrupted, got.?);
    try testing.expectEqual(0, word);
}

test "rendezvous swaps values, and a pending note stops it before it waits [kernel-port]" {
    const me = try kt.namespace();
    const T = struct {
        fn run(rg: *c.Rgrp, out: *usize) void {
            up().rgrp = rg;
            out.* = rendezvous(7, 100);
        }
    };
    var out: usize = 0;
    var k: kt.Kproc = undefined;
    try k.start(T.run, .{ me.rgrp, &out });
    // Until the other process is on the list.
    var i: usize = 0;
    while (@as(*volatile c_uint, &k.proc().state).* != c.Rendezvous and i < 5000) : (i += 1) c.osmsleep(1);
    try testing.expectEqual(100, rendezvous(7, 200));
    k.join();
    try testing.expectEqual(200, out);

    me.notepending = 1;
    try testing.expectEqual(~@as(usize, 0), rendezvous(8, 1));
    try testing.expectEqual(0, me.notepending);
    try testing.expect(me.rgrp.*.rendhash[8 & (c.RENDHASH - 1)] == null);
}
