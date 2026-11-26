//! Readiness (design/file-interface.md, Part 1): the device switch's
//! optional `ready` and `watch`, and what they're built from. `ready`
//! says which of some events a channel has now (a read or a write that
//! wouldn't block, an error, or a hangup), and `watch` hangs a `Waker`
//! on the channel, for a call when that may have changed.
//!
//! The events are Linux's poll bits, the vocabulary every caller (the
//! Linux ABI's poll, select, and epoll, and kserve's Tready) uses.
//!
//! An object that can change (a queue, an eventfd, a remote file) has a
//! `Watchers` list; `watch` puts the caller's `Watch` on it, and
//! `notify` calls each one's waker. A waker only says "look again": it's
//! called with the list's lock held, so it must not block or take a
//! queue's lock, and wakes its owner with sync.zig's wakeup (`unpark`).
//! A poller registers its watches, asks `ready` again, and only then
//! sleeps, so a change between the first answer and the watch isn't
//! missed.
//!
//! Every notify also moves one generation number, which edge-triggered
//! epoll uses to tell a new event from one it has reported.

const std = @import("std");
const port = @import("port.zig");
const sync = @import("sync.zig");
const c = port.c;

pub const In = 0x1;
pub const Pri = 0x2;
pub const Out = 0x4;
pub const Err = 0x8;
pub const Hup = 0x10;
pub const Rdhup = 0x2000;
/// In a watch's events: the caller has reported the channel ready and
/// wants the next change, not readiness again, so a device whose watch
/// fires on a level (a host socket's) mustn't fire for what's already
/// there (edge-triggered epoll).
pub const Edge = 0x8000;
/// In ready's events: the caller is about to read or write without
/// waiting, so a device that answers from what a watch is waiting for
/// (devmnt's, with a Tready out) asks afresh.
pub const Now = 0x4000;

/// What a watch calls. The owner embeds it and finds itself with
/// @fieldParentPtr.
pub const Waker = extern struct {
    wake: *const fn (*Waker) callconv(.c) void,
};

/// One waker on one object. A device's watch puts it on its object's
/// Watchers (`add`), and sets `unhook` if it registered it anywhere else
/// as well; `unwatch` undoes both.
pub const Watch = extern struct {
    waker: ?*Waker = null,
    list: ?*Watchers = null,
    next: ?*Watch = null,
    unhook: ?*const fn (*Watch) callconv(.c) void = null,
    /// The device's, for its unhook.
    arg: ?*anyopaque = null,
};

/// The watches on one object.
pub const Watchers = extern struct {
    lk: c.Lock = std.mem.zeroes(c.Lock),
    head: ?*Watch = null,
    /// Moved by every notify: the object's own generation, which
    /// edge-triggered epoll goes by (`changes`).
    gen: u32 = 0,
};

/// ws's generation, which every notify of it moves.
pub fn changes(ws: *Watchers) u32 {
    return @atomicLoad(u32, &ws.gen, .seq_cst);
}

var generation = std.atomic.Value(c_uint).init(0);

/// The number every notify moves.
pub fn gen() c_uint {
    return generation.load(.seq_cst);
}

/// Moves the generation, for a change no list carries.
pub fn bump() void {
    _ = generation.fetchAdd(1, .seq_cst);
}

/// Called after an fd is closed (sysfile.zig's fdclose). A poll holds
/// the channels of the fds it watches, so without a word it would keep
/// a closed fd's channel open, and the file with it (a conversation that
/// doesn't hang up, a pipe whose reader never sees the end), until
/// something else woke it: linuxnet.zig sets it to wake every poll to
/// look its fds up again.
pub var closed: ?*const fn () void = null;

/// Puts w, with waker wk, on ws.
pub fn add(ws: *Watchers, w: *Watch, wk: *Waker) void {
    w.waker = wk;
    c.lock(&ws.lk);
    w.list = ws;
    w.next = ws.head;
    ws.head = w;
    c.unlock(&ws.lk);
}

/// Takes w off wherever its watch put it. A watch never made, or
/// already undone, is nothing to undo.
pub fn unwatch(w: *Watch) void {
    if (w.unhook) |f| {
        w.unhook = null;
        f(w);
    }
    const ws = w.list orelse return;
    c.lock(&ws.lk);
    var l: *?*Watch = &ws.head;
    while (l.*) |x| : (l = &x.next) {
        if (x == w) {
            l.* = w.next;
            break;
        }
    }
    w.list = null;
    w.next = null;
    c.unlock(&ws.lk);
}

/// ws's object may have changed: wakes each watch on it.
pub fn notify(ws: *Watchers) void {
    _ = @atomicRmw(u32, &ws.gen, .Add, 1, .seq_cst);
    bump();
    if (@as(*volatile ?*Watch, &ws.head).* == null)
        return;
    c.lock(&ws.lk);
    var w = ws.head;
    while (w) |x| : (w = x.next) {
        if (x.waker) |wk| wk.wake(wk);
    }
    c.unlock(&ws.lk);
}

/// Whether anyone watches ws.
pub fn watched(ws: *Watchers) bool {
    return @as(*volatile ?*Watch, &ws.head).* != null;
}

/// A waker that a process sleeps on: `wait` returns once something it
/// watches has fired since `arm`, or the time passes.
pub const Sleeper = struct {
    waker: Waker = .{ .wake = wake },
    r: c.Rendez = std.mem.zeroes(c.Rendez),
    fired: std.atomic.Value(u32) = .init(0),

    fn wake(wk: *Waker) callconv(.c) void {
        const s: *Sleeper = @fieldParentPtr("waker", wk);
        s.fired.store(1, .seq_cst);
        _ = sync.wakeup(&s.r);
    }

    /// Forgets what fired before: call it before asking ready again.
    pub fn arm(s: *Sleeper) void {
        s.fired.store(0, .seq_cst);
    }

    pub fn kick(s: *Sleeper) void {
        wake(&s.waker);
    }

    fn hasfired(a: ?*anyopaque) callconv(.c) c_int {
        const s: *Sleeper = @ptrCast(@alignCast(a.?));
        return @intFromBool(s.fired.load(.seq_cst) != 0);
    }

    /// Sleeps until a waker fires, or ms passes (0: no limit), or a note
    /// (an error). True if it fired.
    pub fn wait(s: *Sleeper, ms: c_uint) port.Error!bool {
        if (ms == 0)
            try sync.sleep(&s.r, hasfired, s)
        else
            try sync.tsleep(&s.r, hasfired, s, ms);
        return s.fired.load(.seq_cst) != 0;
    }
};

// Cases (zig build kern-test).

const testing = std.testing;

test "a notify fires each watch on the list, and an unwatched one no more [file-interface]" {
    _ = try port.testing.begin();
    var ws: Watchers = .{};
    var a: Sleeper = .{};
    var b: Sleeper = .{};
    var wa: Watch = .{};
    var wb: Watch = .{};
    add(&ws, &wa, &a.waker);
    add(&ws, &wb, &b.waker);
    const g = gen();
    notify(&ws);
    try testing.expect(gen() != g);
    try testing.expect(try a.wait(10) and try b.wait(10));
    a.arm();
    b.arm();
    unwatch(&wa);
    notify(&ws);
    try testing.expect(!try a.wait(5));
    try testing.expect(try b.wait(10));
    unwatch(&wb);
    unwatch(&wb);
    try testing.expect(!watched(&ws));
}

test "a waker fired from another process ends a wait [file-interface]" {
    _ = try port.testing.begin();
    var ws: Watchers = .{};
    var s: Sleeper = .{};
    var w: Watch = .{};
    add(&ws, &w, &s.waker);
    defer unwatch(&w);
    var k: port.testing.Kproc = undefined;
    try k.start(struct {
        fn run(l: *Watchers) void {
            notify(l);
        }
    }.run, .{&ws});
    try testing.expect(try s.wait(10000));
    k.join();
}
