//! `#ε`, from src/kern/linuxnet.c (design/kernel-port.md): eventfd and
//! epoll instances for the Linux ABI (design/epoch-0/linux-net.md). An
//! eventfd is a counter, readable when it's not zero; an epoll fd is an
//! identity for the interest list, which the Linux layer keeps
//! (src/abi/linux/sys.zig). A close translation, with error unions for the
//! C's error labels. A native device (dev.zig's `Native`).
//!
//! A timerfd is an instance whose count is the expirations of its timer
//! since the last read, from the host monotonic clock: a write of three
//! u64s (ns from now to the first, 0 to disarm; ns between the rest;
//! the Linux clock it was made on, which it only keeps) sets it, and a
//! read at `timer_state` gives the same three for what's left. A tsleep.zig Alarm notifies its watchers at each expiration.
//!
//! Its readiness is the device's `ready` and `watch`
//! (design/file-interface.md): an eventfd has watchers, which every
//! change notifies, and a read or write that can't go on waits on them.

const std = @import("std");
const port = @import("../port.zig");
const dev = @import("../dev.zig");
const sysfile = @import("../sysfile.zig");
const c = port.c;
const Error = port.Error;
const tsleep = port.tsleep;

const Chan = c.Chan;
const Dirtab = c.Dirtab;
const Walkqid = c.Walkqid;

pub const Epsilon = 0x3B5;

const Qedir = 0;
const Qeventfd = 1;
const Qeventsem = 2;
const Qepoll = 3;
const Qtimerfd = 5;
const Qinst = 4; // an open instance

/// The offset a timerfd's read gives its timer at, rather than its
/// expirations: three u64s, the ns left to the next (0: disarmed), the
/// interval, and the clock. A Linux read of a timerfd is never at it.
pub const timer_state: i64 = 1 << 62;

const Evfd = struct {
    lk: c.Lock = std.mem.zeroes(c.Lock),
    count: u64 = 0,
    sem: bool = false,
    epoll: bool = false,
    timer: bool = false,
    /// A timerfd's next expiration, in tsleep's clock (0: disarmed), and
    /// the ns between expirations (0: one only). Under lk.
    due: u64 = 0,
    interval: u64 = 0,
    clock: u64 = 0,
    alarm: tsleep.Alarm = .{ .f = ring },
    watch: dev.rd.Watchers = .{},
};

/// A timerfd's expirations by `now`, under e.lk.
fn expirations(e: *Evfd, now: u64) u64 {
    if (e.due == 0 or now < e.due)
        return 0;
    if (e.interval == 0)
        return 1;
    return 1 + (now - e.due) / e.interval;
}

/// The Alarm went off: whoever waits on the timerfd looks again. Called
/// by the timer kproc under the host lock, so it takes only the
/// watchers' lock (tsleep.zig's Alarm).
fn ring(a: *tsleep.Alarm) void {
    const e: *Evfd = @fieldParentPtr("alarm", a);
    dev.rd.notify(&e.watch);
}

var evdir = [_]Dirtab{
    dev.dirtab(".", .{ .path = Qedir, .vers = 0, .type = c.QTDIR }, 0, dev.dmdir | 0o555),
    dev.dirtab("eventfd", .{ .path = Qeventfd, .vers = 0, .type = 0 }, 0, 0o666),
    dev.dirtab("eventsem", .{ .path = Qeventsem, .vers = 0, .type = 0 }, 0, 0o666),
    dev.dirtab("epoll", .{ .path = Qepoll, .vers = 0, .type = 0 }, 0, 0o666),
    dev.dirtab("timerfd", .{ .path = Qtimerfd, .vers = 0, .type = 0 }, 0, 0o666),
};

var evid = std.atomic.Value(c_uint).init(0);

fn evof(ch: *Chan) ?*Evfd {
    return @ptrCast(@alignCast(dev.aux(ch).*));
}

/// The poll bits of ev ready on ch.
pub fn evready(ch: *Chan, ev: c_int) c_int {
    const e = evof(ch) orelse return 0;
    if (e.epoll)
        return 0;
    var r: c_int = 0;
    c.lock(&e.lk);
    if (e.timer) {
        if (expirations(e, tsleep.clock()) > 0)
            r |= dev.rd.In;
    } else {
        if (e.count > 0)
            r |= dev.rd.In;
        if (e.count < ~@as(u64, 0) - 1)
            r |= dev.rd.Out;
    }
    c.unlock(&e.lk);
    return r & ev;
}

fn evwatchers(ch: *Chan) ?*dev.rd.Watchers {
    const e = evof(ch) orelse return null;
    return if (e.epoll) null else &e.watch;
}

fn evwatch(ch: *Chan, ev: c_int, w: *dev.rd.Watch, wk: *dev.rd.Waker) void {
    _ = ev;
    const e = evof(ch) orelse return;
    if (e.epoll) return;
    dev.rd.add(&e.watch, w, wk);
}

/// Waits for e to change, after asking again: true from ok means stop
/// waiting.
fn evwait(e: *Evfd, ok: *const fn (*Evfd) bool) Error!void {
    var s: dev.rd.Sleeper = .{};
    var w: dev.rd.Watch = .{};
    dev.rd.add(&e.watch, &w, &s.waker);
    defer dev.rd.unwatch(&w);
    while (true) {
        s.arm();
        c.lock(&e.lk);
        const go = ok(e);
        c.unlock(&e.lk);
        if (go) return;
        _ = try s.wait(0);
    }
}

fn hascount(e: *Evfd) bool {
    return e.count > 0;
}

fn hasexpired(e: *Evfd) bool {
    return expirations(e, tsleep.clock()) > 0;
}

fn hasroom(e: *Evfd) bool {
    return e.count < ~@as(u64, 0) - 1;
}

fn evattach(spec: [*:0]const u8) Error!*Chan {
    return dev.devattach(Epsilon, spec);
}

fn evwalk(ch: *Chan, nc: ?*Chan, name: [*]const [*:0]const u8, nname: c_int) Error!?*Walkqid {
    return dev.devwalk(ch, nc, name, nname, &evdir, evdir.len, dev.devgenC());
}

fn evstat(ch: *Chan, db: [*]u8, n: c_int) Error!c_int {
    return dev.devstat(ch, db, n, &evdir, evdir.len, dev.devgenC());
}

fn evopen(ch: *Chan, omode: c_int) Error!*Chan {
    const t = ch.qid.path;
    if (t == Qedir)
        return dev.devopen(ch, omode, &evdir, evdir.len, dev.devgenC());
    if (t != Qeventfd and t != Qeventsem and t != Qepoll and t != Qtimerfd)
        return port.kerror(&port.Eperm);
    // Checked first, so a bad mode leaves no instance made.
    const mode = try sysfile.openmode(@bitCast(omode));
    const e: *Evfd = @ptrCast(@alignCast(port.malloc(@sizeOf(Evfd)) orelse return port.kerror(&port.Enomem)));
    e.* = .{ .sem = t == Qeventsem, .epoll = t == Qepoll, .timer = t == Qtimerfd };
    dev.aux(ch).* = e;
    ch.qid.path = Qinst | (@as(u64, evid.fetchAdd(1, .seq_cst) +% 1) << 4);
    ch.mode = @intCast(mode);
    ch.flag |= c.COPEN;
    ch.offset = 0;
    return ch;
}

fn evclose(ch: *Chan) Error!void {
    if ((ch.flag & c.COPEN) != 0) {
        if (evof(ch)) |e| {
            if (e.timer)
                e.alarm.clear();
            c.free(e);
            dev.aux(ch).* = null;
        }
    }
}

fn evread(ch: *Chan, va: ?*anyopaque, n: c_int, off: i64) Error!c_int {
    if (ch.qid.type & c.QTDIR != 0)
        return dev.devdirread(ch, @ptrCast(va.?), n, &evdir, evdir.len, dev.devgenC());
    const e = evof(ch) orelse return port.kerror(&port.Eperm);
    if (e.epoll)
        return port.kerror(&port.Eperm);
    if (e.timer)
        return timerread(e, va, n, off);
    if (n < 8)
        return port.kerror(&port.Ebadarg);
    var v: u64 = undefined;
    while (true) {
        c.lock(&e.lk);
        if (e.count > 0) {
            if (e.sem) {
                v = 1;
                e.count -= 1;
            } else {
                v = e.count;
                e.count = 0;
            }
            c.unlock(&e.lk);
            break;
        }
        c.unlock(&e.lk);
        try evwait(e, hascount);
    }
    dev.rd.notify(&e.watch); // a writer waiting for room
    const p: *[8]u8 = @ptrCast(va.?);
    std.mem.writeInt(u64, p, v, .little);
    return 8;
}

/// A timerfd's read: its expirations since the last, waiting for one, or
/// at timer_state, its timer.
fn timerread(e: *Evfd, va: ?*anyopaque, n: c_int, off: i64) Error!c_int {
    if (off == timer_state) {
        if (n < 24)
            return port.kerror(&port.Ebadarg);
        const now = tsleep.clock();
        c.lock(&e.lk);
        var left: u64 = 0;
        if (e.due != 0) {
            const k = expirations(e, now);
            if (k > 0 and e.interval == 0) {
                left = 0; // fired, not yet read: disarmed, as Linux says
            } else {
                const next = e.due + k * e.interval;
                left = @max(next -| now, 1);
            }
        }
        const iv = e.interval;
        const clock = e.clock;
        c.unlock(&e.lk);
        const p: *[24]u8 = @ptrCast(va.?);
        std.mem.writeInt(u64, p[0..8], left, .little);
        std.mem.writeInt(u64, p[8..16], iv, .little);
        std.mem.writeInt(u64, p[16..24], clock, .little);
        return 24;
    }
    if (n < 8)
        return port.kerror(&port.Ebadarg);
    var v: u64 = 0;
    while (true) {
        c.lock(&e.lk);
        v = expirations(e, tsleep.clock());
        if (v > 0) {
            if (e.interval == 0) e.due = 0 else e.due += v * e.interval;
            c.unlock(&e.lk);
            break;
        }
        c.unlock(&e.lk);
        try evwait(e, hasexpired);
    }
    const p: *[8]u8 = @ptrCast(va.?);
    std.mem.writeInt(u64, p, v, .little);
    return 8;
}

/// A timerfd's write: three u64s, the ns to its first expiration (0:
/// disarm), the ns between the rest, and the clock. Its count starts
/// again.
fn timerwrite(e: *Evfd, va: ?*const anyopaque, n: c_int) Error!c_int {
    if (n != 24)
        return port.kerror(&port.Ebadarg);
    const b: *const [24]u8 = @ptrCast(va.?);
    const first = std.mem.readInt(u64, b[0..8], .little);
    const iv = std.mem.readInt(u64, b[8..16], .little);
    const clock = std.mem.readInt(u64, b[16..24], .little);
    // The alarm first, so no expiration of the old timer rings after
    // the new one is set; then the timer, which ready and read go by.
    e.alarm.clear();
    c.lock(&e.lk);
    e.due = if (first == 0) 0 else tsleep.clock() + first;
    e.interval = if (first == 0) 0 else iv;
    e.clock = clock;
    c.unlock(&e.lk);
    if (first != 0)
        e.alarm.set(first, iv);
    dev.rd.notify(&e.watch);
    return 24;
}

fn evwrite(ch: *Chan, va: ?*const anyopaque, n: c_int, off: i64) Error!c_int {
    _ = off;
    const e = evof(ch) orelse return port.kerror(&port.Eperm);
    if (e.epoll)
        return port.kerror(&port.Eperm);
    if (e.timer)
        return timerwrite(e, va, n);
    if (n < 8)
        return port.kerror(&port.Ebadarg);
    const v = std.mem.readInt(u64, @as(*const [8]u8, @ptrCast(va.?)), .little);
    if (v == ~@as(u64, 0))
        return port.kerror(&port.Ebadarg);
    while (true) {
        c.lock(&e.lk);
        const sum = e.count +% v;
        if (sum >= e.count and sum < ~@as(u64, 0)) {
            e.count = sum;
            c.unlock(&e.lk);
            break;
        }
        c.unlock(&e.lk);
        try evwait(e, hasroom);
    }
    dev.rd.notify(&e.watch);
    return 8;
}

pub const Device = dev.Native(Epsilon, "eventfd", .{
    .attach = evattach,
    .walk = evwalk,
    .stat = evstat,
    .open = evopen,
    .create = dev.devcreate,
    .close = evclose,
    .read = evread,
    .write = evwrite,
    .remove = dev.devremove,
    .wstat = dev.devwstat,
    .ready = evready,
    .watch = evwatch,
    .watchers = evwatchers,
});

pub fn exportC() void {
    @export(&Device.dev, .{ .name = "evdevtab" });
}

// Cases (zig build kern-test): instances made on a bare channel, since
// the namespace kernel the cases run on has no #ε in its table.

const testing = std.testing;
const chan = @import("../chan.zig");
const sync = @import("../sync.zig");

fn instance(q: i64) !*Chan {
    const ch = chan.newchan();
    ch.qid = .{ .path = @intCast(q), .vers = 0, .type = 0 };
    return evopen(ch, c.ORDWR);
}

fn drop(ch: *Chan) void {
    evclose(ch) catch {};
    ch.flag &= ~@as(@TypeOf(ch.flag), c.COPEN);
    chan.cclose(ch); // type 0: devroot's close, a nop
}

fn put(ch: *Chan, v: u64) !void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, v, .little);
    try testing.expectEqual(@as(c_int, 8), try evwrite(ch, &b, 8, 0));
}

fn take(ch: *Chan) !u64 {
    var b: [8]u8 = undefined;
    try testing.expectEqual(@as(c_int, 8), try evread(ch, &b, 8, 0));
    return std.mem.readInt(u64, &b, .little);
}

test "an eventfd sums its writes and a read takes them all [kernel-port]" {
    _ = try port.testing.begin();
    const ch = try instance(Qeventfd);
    defer drop(ch);
    try testing.expectEqual(@as(c_int, dev.rd.Out), evready(ch, dev.rd.In | dev.rd.Out));
    try put(ch, 2);
    try put(ch, 3);
    try testing.expectEqual(@as(c_int, dev.rd.In), evready(ch, dev.rd.In));
    try testing.expectEqual(@as(u64, 5), try take(ch));
    try testing.expectEqual(@as(c_int, 0), evready(ch, dev.rd.In));
    try testing.expectEqual(Qinst, ch.qid.path & 0xf);
}

test "an eventsem's read takes one at a time [kernel-port]" {
    _ = try port.testing.begin();
    const ch = try instance(Qeventsem);
    defer drop(ch);
    try put(ch, 2);
    try testing.expectEqual(@as(u64, 1), try take(ch));
    try testing.expectEqual(@as(u64, 1), try take(ch));
    try testing.expectEqual(@as(c_int, 0), evready(ch, dev.rd.In));
}

test "an eventfd refuses short buffers and the all-ones value [kernel-port]" {
    _ = try port.testing.begin();
    const ch = try instance(Qeventfd);
    defer drop(ch);
    var b: [8]u8 = @splat(0xff);
    try testing.expectError(error.Kernel, evwrite(ch, &b, 8, 0));
    try testing.expectError(error.Kernel, evwrite(ch, &b, 4, 0));
    try testing.expectError(error.Kernel, evread(ch, &b, 4, 0));
}

test "an epoll instance can't be read or written [kernel-port]" {
    _ = try port.testing.begin();
    const ch = try instance(Qepoll);
    defer drop(ch);
    var b: [8]u8 = @splat(0);
    try testing.expectError(error.Kernel, evread(ch, &b, 8, 0));
    try testing.expectError(error.Kernel, evwrite(ch, &b, 8, 0));
    try testing.expectEqual(@as(c_int, 0), evready(ch, dev.rd.In | dev.rd.Out));
}

fn arm(ch: *Chan, first: u64, interval: u64) !void {
    var b: [24]u8 = @splat(0);
    std.mem.writeInt(u64, b[0..8], first, .little);
    std.mem.writeInt(u64, b[8..16], interval, .little);
    try testing.expectEqual(@as(c_int, 24), try evwrite(ch, &b, 24, 0));
}

test "a timerfd's read waits for its expiration, and an interval's counts each [linux-net]" {
    _ = try port.testing.begin();
    const ch = try instance(Qtimerfd);
    defer drop(ch);
    try testing.expectEqual(@as(c_int, 0), evready(ch, dev.rd.In | dev.rd.Out));
    const t0 = tsleep.clock();
    try arm(ch, 20 * std.time.ns_per_ms, 0);
    try testing.expectEqual(@as(u64, 1), try take(ch));
    try testing.expect(tsleep.clock() - t0 >= 20 * std.time.ns_per_ms);
    try testing.expectEqual(@as(c_int, 0), evready(ch, dev.rd.In));
    try arm(ch, 5 * std.time.ns_per_ms, 5 * std.time.ns_per_ms);
    var s: dev.rd.Sleeper = .{};
    var w: dev.rd.Watch = .{};
    evwatch(ch, dev.rd.In, &w, &s.waker);
    defer dev.rd.unwatch(&w);
    try testing.expect(try s.wait(2000)); // the alarm notified
    var r: c.Rendez = std.mem.zeroes(c.Rendez);
    sync.tsleep(&r, struct {
        fn f(_: ?*anyopaque) callconv(.c) c_int {
            return 0;
        }
    }.f, null, 30) catch {};
    try testing.expect(try take(ch) >= 3);
    var st: [24]u8 = undefined;
    try testing.expectEqual(@as(c_int, 24), try evread(ch, &st, 24, timer_state));
    try testing.expectEqual(@as(u64, 5 * std.time.ns_per_ms), std.mem.readInt(u64, st[8..16], .little));
    try arm(ch, 0, 0);
    try testing.expectEqual(@as(c_int, 24), try evread(ch, &st, 24, timer_state));
    try testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, st[0..8], .little));
    try testing.expectEqual(@as(c_int, 0), evready(ch, dev.rd.In));
}

test "a bad open mode makes no instance [kernel-port]" {
    _ = try port.testing.begin();
    const ch = chan.newchan();
    ch.qid = .{ .path = Qeventfd, .vers = 0, .type = 0 };
    try testing.expectError(error.Kernel, evopen(ch, 7));
    try testing.expect(evof(ch) == null);
    chan.cclose(ch);
}
