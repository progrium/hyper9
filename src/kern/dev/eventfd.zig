//! `#ε`, from src/kern/linuxnet.c (design/kernel-port.md): eventfd and
//! epoll instances for the Linux ABI (design/epoch-0/linux-net.md). An
//! eventfd is a counter, readable when it's not zero; an epoll fd is an
//! identity for the interest list, which the Linux layer keeps
//! (src/abi/linux/sys.zig). A close translation, with error unions for the
//! C's error labels. A native device (dev.zig's `Native`).
//!
//! A read or write that can't go on waits in linuxnet.zig's pollwait,
//! for the next readiness wake.

const std = @import("std");
const port = @import("../port.zig");
const dev = @import("../dev.zig");
const sysfile = @import("../sysfile.zig");
const linuxnet = @import("../linuxnet.zig");
const c = port.c;
const Error = port.Error;

const Chan = c.Chan;
const Dirtab = c.Dirtab;
const Walkqid = c.Walkqid;

pub const Epsilon = 0x3B5;

const Qedir = 0;
const Qeventfd = 1;
const Qeventsem = 2;
const Qepoll = 3;
const Qinst = 4; // an open instance

const Evfd = struct {
    lk: c.Lock = std.mem.zeroes(c.Lock),
    count: u64 = 0,
    sem: bool = false,
    epoll: bool = false,
};

var evdir = [_]Dirtab{
    dev.dirtab(".", .{ .path = Qedir, .vers = 0, .type = c.QTDIR }, 0, dev.dmdir | 0o555),
    dev.dirtab("eventfd", .{ .path = Qeventfd, .vers = 0, .type = 0 }, 0, 0o666),
    dev.dirtab("eventsem", .{ .path = Qeventsem, .vers = 0, .type = 0 }, 0, 0o666),
    dev.dirtab("epoll", .{ .path = Qepoll, .vers = 0, .type = 0 }, 0, 0o666),
};

var evid = std.atomic.Value(u64).init(0);

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
    if (e.count > 0)
        r |= linuxnet.LPOLLIN;
    if (e.count < ~@as(u64, 0) - 1)
        r |= linuxnet.LPOLLOUT;
    c.unlock(&e.lk);
    return r & ev;
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
    if (t != Qeventfd and t != Qeventsem and t != Qepoll)
        return port.kerror(&port.Eperm);
    // Checked first, so a bad mode leaves no instance made.
    const mode = try sysfile.openmode(@bitCast(omode));
    const e: *Evfd = @ptrCast(@alignCast(port.malloc(@sizeOf(Evfd)) orelse return port.kerror(&port.Enomem)));
    e.* = .{ .sem = t == Qeventsem, .epoll = t == Qepoll };
    dev.aux(ch).* = e;
    ch.qid.path = Qinst | ((evid.fetchAdd(1, .seq_cst) + 1) << 4);
    ch.mode = @intCast(mode);
    ch.flag |= c.COPEN;
    ch.offset = 0;
    return ch;
}

fn evclose(ch: *Chan) Error!void {
    if ((ch.flag & c.COPEN) != 0) {
        if (evof(ch)) |e| {
            c.free(e);
            dev.aux(ch).* = null;
        }
    }
}

fn evread(ch: *Chan, va: ?*anyopaque, n: c_int, off: i64) Error!c_int {
    _ = off;
    if (ch.qid.type & c.QTDIR != 0)
        return dev.devdirread(ch, @ptrCast(va.?), n, &evdir, evdir.len, dev.devgenC());
    const e = evof(ch) orelse return port.kerror(&port.Eperm);
    if (e.epoll)
        return port.kerror(&port.Eperm);
    if (n < 8)
        return port.kerror(&port.Ebadarg);
    var v: u64 = undefined;
    while (true) {
        const g = linuxnet.h9_pollgen();
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
        _ = try linuxnet.pollwait(g, 0);
    }
    linuxnet.h9_pollwake(); // a writer waiting for room
    const p: *[8]u8 = @ptrCast(va.?);
    std.mem.writeInt(u64, p, v, .little);
    return 8;
}

fn evwrite(ch: *Chan, va: ?*const anyopaque, n: c_int, off: i64) Error!c_int {
    _ = off;
    const e = evof(ch) orelse return port.kerror(&port.Eperm);
    if (e.epoll)
        return port.kerror(&port.Eperm);
    if (n < 8)
        return port.kerror(&port.Ebadarg);
    const v = std.mem.readInt(u64, @as(*const [8]u8, @ptrCast(va.?)), .little);
    if (v == ~@as(u64, 0))
        return port.kerror(&port.Ebadarg);
    while (true) {
        const g = linuxnet.h9_pollgen();
        c.lock(&e.lk);
        const sum = e.count +% v;
        if (sum >= e.count and sum < ~@as(u64, 0)) {
            e.count = sum;
            c.unlock(&e.lk);
            break;
        }
        c.unlock(&e.lk);
        _ = try linuxnet.pollwait(g, 0);
    }
    linuxnet.h9_pollwake();
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
});

pub fn exportC() void {
    @export(&Device.dev, .{ .name = "evdevtab" });
}

// Cases (zig build kern-test): instances made on a bare channel, since
// the namespace kernel the cases run on has no #ε in its table.

const testing = std.testing;
const chan = @import("../chan.zig");

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
    try testing.expectEqual(@as(c_int, linuxnet.LPOLLOUT), evready(ch, linuxnet.LPOLLIN | linuxnet.LPOLLOUT));
    try put(ch, 2);
    try put(ch, 3);
    try testing.expectEqual(@as(c_int, linuxnet.LPOLLIN), evready(ch, linuxnet.LPOLLIN));
    try testing.expectEqual(@as(u64, 5), try take(ch));
    try testing.expectEqual(@as(c_int, 0), evready(ch, linuxnet.LPOLLIN));
    try testing.expectEqual(Qinst, ch.qid.path & 0xf);
}

test "an eventsem's read takes one at a time [kernel-port]" {
    _ = try port.testing.begin();
    const ch = try instance(Qeventsem);
    defer drop(ch);
    try put(ch, 2);
    try testing.expectEqual(@as(u64, 1), try take(ch));
    try testing.expectEqual(@as(u64, 1), try take(ch));
    try testing.expectEqual(@as(c_int, 0), evready(ch, linuxnet.LPOLLIN));
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
    try testing.expectEqual(@as(c_int, 0), evready(ch, linuxnet.LPOLLIN | linuxnet.LPOLLOUT));
}

test "a bad open mode makes no instance [kernel-port]" {
    _ = try port.testing.begin();
    const ch = chan.newchan();
    ch.qid = .{ .path = Qeventfd, .vers = 0, .type = 0 };
    try testing.expectError(error.Kernel, evopen(ch, 7));
    try testing.expect(evof(ch) == null);
    chan.cclose(ch);
}
