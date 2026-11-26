//! h9's #ℏ, host streams (src/kern/devhstream.c,
//! design/epoch-0/websocket-9p.md, design/kernel-port.md). A WebSocket
//! that h9 connects on the host becomes a channel devmnt can mount, and
//! the guest can open WebSockets of its own through /net/ws. A close
//! translation of the C: the same functions in the same order, with
//! error unions in place of C's error labels. A native device (dev.zig's
//! `Native`).
//!
//! It's #y's design (dev/hcons.zig) applied to a connection: reads and
//! writes are calls into src/hstream.zig, a host thread per stream reads
//! frames and queues their payloads, and a guest read sleeps here until
//! the queue has bytes, so a note or a teardown interrupts it with Eintr.
//! The calls never fail with kernel errors: they return -1 with the error
//! in an ERRMAX buffer, and this file makes it one.
//!
//! Host-made streams (a ws:// root, a namespace file's mount) aren't in
//! any tree: the namespace builder gets a channel for one from
//! h9_hstream_fd, never through an attach spec, so no path names it.
//!
//! Attached with no spec, the device serves the calling machine's
//! conversations, laid out like devip's protocol directories, which the
//! namespace builder binds after #I on /net:
//!
//!     ws/clone        opening it makes a conversation and opens its ctl
//!     ws/N/ctl        header, connect and hangup; reads give N
//!     ws/N/data       binary messages out, payload bytes in, as a stream
//!     ws/N/text       text messages, one per write and per read
//!     ws/N/remote     the URL
//!     ws/N/status     Idle, Connecting, Established [proto], Closed code reason
//!
//! On the web host it also serves the page's ports
//! (design/epoch-0/port-streams.md), by name, the same way, sharing the
//! conversation numbers:
//!
//!     port/clone      as ws/clone
//!     port/N/ctl      open NAME, and hangup; reads give N
//!     port/N/data     9P messages out, bytes in, as a stream
//!     port/N/remote   port!NAME
//!     port/N/status   as ws/N/status
//!
//! Closing the last fd on a conversation's ctl, data and text hangs it up.

const std = @import("std");
const port = @import("../port.zig");
const sync = @import("../sync.zig");
const dev = @import("../dev.zig");
const chan = @import("../chan.zig");
const sysfile = @import("../sysfile.zig");
const c = port.c;
const up = port.up;
const hup = port.hup;
const Error = port.Error;

const Chan = c.Chan;
const Dir = c.Dir;
const Dirtab = c.Dirtab;
const Walkqid = c.Walkqid;
const Qid = c.Qid;

// Implemented in Zig (src/hstream.zig), with its own types: the C
// declared the counts and ids with drawterm's long and ulong, which are
// C's int and unsigned int, where hstream.zig takes c_long and c_ulong.
extern fn h9_hstream_clone(mach: ?*anyopaque, port: c_int, err: [*]u8) c_long;
extern fn h9_hstream_conv(mach: ?*anyopaque, n: c_int) c_long;
extern fn h9_hstream_convs(mach: ?*anyopaque, port: c_int, out: [*]c_int, max: c_int) c_int;
extern fn h9_hstream_convno(id: c_ulong) c_int;
extern fn h9_hstream_isport(id: c_ulong) c_int;
extern fn h9_hstream_incref(id: c_ulong) void;
extern fn h9_hstream_decref(id: c_ulong) void;
extern fn h9_hstream_ctl(id: c_ulong, buf: [*]const u8, n: c_long, err: [*]u8) c_long;
extern fn h9_hstream_connecting(id: c_ulong) c_int;
extern fn h9_hstream_result(id: c_ulong, err: [*]u8) c_int;
extern fn h9_hstream_hangup(id: c_ulong) void;
extern fn h9_hstream_read(id: c_ulong, kind: c_int, buf: [*]u8, n: c_long, err: [*]u8) c_long;
extern fn h9_hstream_ready(id: c_ulong, kind: c_int) c_int;
extern fn h9_hstream_write(id: c_ulong, kind: c_int, buf: [*]const u8, n: c_long, err: [*]u8) c_long;
extern fn h9_hstream_info(id: c_ulong, what: c_int, buf: [*]u8, n: c_int) c_int;
extern fn h9_hstream_redial(mach: ?*anyopaque, url: [*]const u8, n: c_long, err: [*]u8) c_long;
extern fn h9_hstream_release(id: c_ulong) void;

const Hsdc = 0x210F; // ℏ
const Maxstream = 256; // src/hstream.zig's max_streams
const Maxconv = 32; // and max_convs
const Wouldblock = -2;
const Kdata = 0;
const Ktext = 1;

const Qtopdir = 1;
const Qwsdir = 2;
const Qclone = 3;
const Qconvdir = 4;
const Qctl = 5;
const Qdata = 6;
const Qtext = 7;
const Qremote = 8;
const Qstatus = 9;
const Qhost = 10; // a host-made stream's channel
const Qportdir = 11; // port/, on the web host
const Qpclone = 12;

const Haveports = @hasDecl(c, "H9_WEB");

fn TYPE(q: Qid) c_uint {
    return @as(c_uint, @truncate(q.path)) & 0x1f;
}
fn CONV(q: Qid) c_int {
    return @as(c_int, @bitCast((@as(c_uint, @truncate(q.path)) >> 5))) - 1;
}
fn QID(n: c_int, t: c_uint) i64 {
    return @as(c_uint, @bitCast(n + 1)) << 5 | t;
}
fn STREAM(ch: *Chan) c_ulong {
    return @intCast(@intFromPtr(dev.aux(ch).*));
}

const Hs = struct {
    lk: c.Lock = std.mem.zeroes(c.Lock),
    busy: [2]bool = .{ false, false }, // a reader of data or text has its turn
    r: [2]c.Rendez = std.mem.zeroes([2]c.Rendez), // that reader, waiting for bytes
    cr: c.Rendez = std.mem.zeroes(c.Rendez), // a connect, waiting for the handshake
};

var hs: [Maxstream]Hs = @splat(.{});

fn slot(id: c_ulong) *Hs {
    return &hs[id % Maxstream];
}

/// Called by a stream's thread (not a Proc) when it queues or ends.
fn h9_hstream_wake(id: c_ulong) callconv(.c) void {
    const h = slot(id);
    _ = sync.wakeup(&h.r[Kdata]);
    _ = sync.wakeup(&h.r[Ktext]);
    _ = sync.wakeup(&h.cr);
}

const Want = struct {
    id: c_ulong,
    kind: c_int,
};

fn readable(a: ?*anyopaque) callconv(.c) c_int {
    const w: *Want = @ptrCast(@alignCast(a));
    return h9_hstream_ready(w.id, w.kind);
}

fn connected(a: ?*anyopaque) callconv(.c) c_int {
    return @intFromBool(h9_hstream_connecting(@intCast(@intFromPtr(a))) == 0);
}

/// As #y's: a Rendez holds one sleeper, so readers take turns.
fn taketurn(h: *Hs, kind: usize) Error!void {
    while (true) {
        c.lock(&h.lk);
        if (!h.busy[kind]) {
            h.busy[kind] = true;
            c.unlock(&h.lk);
            return;
        }
        c.unlock(&h.lk);
        if (up().notepending != 0) {
            up().notepending = 0;
            return port.interrupted();
        }
        sync.msleep(5);
    }
}

fn giveturn(h: *Hs, kind: usize) void {
    c.lock(&h.lk);
    h.busy[kind] = false;
    c.unlock(&h.lk);
}

fn streamread(id: c_ulong, kind: usize, va: ?*anyopaque, n: c_int) Error!c_int {
    var err: [port.ERRMAX:0]u8 = undefined;
    const h = slot(id);
    try taketurn(h, kind);
    const r = blk: {
        defer giveturn(h, kind);
        var w: Want = .{ .id = id, .kind = @intCast(kind) };
        while (true) {
            const r = h9_hstream_read(id, @intCast(kind), @ptrCast(va.?), n, &err);
            if (r != Wouldblock) break :blk r;
            try sync.sleep(&h.r[kind], readable, &w);
        }
    };
    if (r < 0)
        return port.kerror(&err);
    return @intCast(r);
}

fn streamwrite(id: c_ulong, kind: c_int, va: ?*const anyopaque, n: c_int) Error!c_int {
    var err: [port.ERRMAX:0]u8 = undefined;
    const r = h9_hstream_write(id, kind, @ptrCast(va.?), n, &err);
    if (r < 0)
        return port.kerror(&err);
    return @intCast(r);
}

/// Waits for stream id's connect: a note interrupts it and hangs the
/// stream up. Then fails with the connect's error, if it failed.
fn waitconnect(id: c_ulong) Error!void {
    var err: [port.ERRMAX:0]u8 = undefined;
    sync.sleep(&slot(id).cr, connected, @ptrFromInt(id)) catch |e| {
        h9_hstream_hangup(id);
        return e;
    };
    if (h9_hstream_result(id, &err) < 0)
        return port.kerror(&err);
}

/// An open channel holding host-made stream id.
fn hostchan(id: c_ulong) *Chan {
    const ch = dev.devattach(Hsdc, "");
    ch.qid.path = Qhost;
    ch.qid.type = c.QTFILE;
    dev.aux(ch).* = @ptrFromInt(id);
    ch.mode = c.ORDWR;
    ch.flag |= c.COPEN;
    h9_hstream_incref(id);
    return ch;
}

/// For devdotl's redial (design/epoch-0/credential-helpers.md): connects
/// a host-made stream to url for machine mach, with the handshake
/// options the machine registered (src/hstream.zig), so its credential
/// helper runs again, waits for it, and returns its channel.
pub fn dial(mach: ?*anyopaque, url: [*:0]const u8) Error!*Chan {
    var err: [port.ERRMAX:0]u8 = undefined;
    const id_ = h9_hstream_redial(mach, url, @intCast(std.mem.len(url)), &err);
    if (id_ < 0)
        return port.kerror(&err);
    const id: c_ulong = @intCast(id_);
    defer h9_hstream_release(id);
    try waitconnect(id);
    return hostchan(id);
}

/// Makes a channel for host-made stream id and returns a new fd on it.
/// The channel holds the stream.
pub fn hostfd(id: c_ulong) Error!c_int {
    const ch = hostchan(id);
    const fd = sysfile.newfd(ch, 0);
    if (fd < 0) {
        chan.cclose(ch);
        return port.kerror(&port.Enofd);
    }
    return fd;
}

/// The caller's machine, as proc.c's uphproc finds it.
fn upmach() Error!?*anyopaque {
    const m = hup().mach orelse return port.kerror("not an h9 process");
    return m;
}

fn convdir(ch: *Chan, n: c_int, dp: *Dir) void {
    const name = std.fmt.bufPrintSentinel(&up().genbuf, "{d}", .{n}, 0) catch unreachable;
    var q: Qid = undefined;
    dev.mkqid(&q, QID(n, Qconvdir), 0, c.QTDIR);
    dev.devdir(ch, q, name.ptr, 0, c.eve, dev.dmdir | 0o555, dp);
}

fn convfile(ch: *Chan, n: c_int, t: c_uint, dp: *Dir) c_int {
    const names = [_][*:0]const u8{ "ctl", "data", "text", "remote", "status" };
    if (t < Qctl or t > Qstatus)
        return -1;
    var q: Qid = undefined;
    dev.mkqid(&q, QID(n, t), 0, c.QTFILE);
    dev.devdir(ch, q, @constCast(names[t - Qctl]), 0, c.eve, if (t >= Qremote) 0o444 else 0o666, dp);
    return 1;
}

fn topdir(ch: *Chan, dp: *Dir) void {
    var q: Qid = undefined;
    dev.mkqid(&q, Qtopdir, 0, c.QTDIR);
    dev.devdir(ch, q, @constCast("#\xe2\x84\x8f"), 0, c.eve, dev.dmdir | 0o555, dp);
}

fn wsdir(ch: *Chan, dp: *Dir) void {
    var q: Qid = undefined;
    dev.mkqid(&q, Qwsdir, 0, c.QTDIR);
    dev.devdir(ch, q, @constCast("ws"), 0, c.eve, dev.dmdir | 0o555, dp);
}

fn portdir(ch: *Chan, dp: *Dir) void {
    var q: Qid = undefined;
    dev.mkqid(&q, Qportdir, 0, c.QTDIR);
    dev.devdir(ch, q, @constCast("port"), 0, c.eve, dev.dmdir | 0o555, dp);
}

/// Whether conversation n of the caller's machine is a port's.
fn isportconv(n: c_int) bool {
    const id = h9_hstream_conv(hup().mach, n);
    return id >= 0 and h9_hstream_isport(@intCast(id)) != 0;
}

/// A protocol directory's entries: clone, then its conversations.
fn protogen(ch: *Chan, isport: bool, s_: c_int, dp: *Dir) c_int {
    if (s_ == c.DEVDOTDOT) {
        topdir(ch, dp);
        return 1;
    }
    if (s_ == 0) {
        var q: Qid = undefined;
        dev.mkqid(&q, if (isport) Qpclone else Qclone, 0, c.QTFILE);
        dev.devdir(ch, q, @constCast("clone"), 0, c.eve, 0o666, dp);
        return 1;
    }
    const s = s_ - 1;
    var convs: [Maxconv]c_int = undefined;
    const nc = h9_hstream_convs(hup().mach, @intFromBool(isport), &convs, Maxconv);
    if (s < nc) {
        convdir(ch, convs[@intCast(s)], dp);
        return 1;
    }
    return -1;
}

/// A Devgen doesn't raise, so the functions that call devwalk, devstat,
/// and devdirread check the caller's machine first, and hsgen reads it
/// from up.
fn hsgen(ch_: [*c]Chan, name: [*c]u8, tab: [*c]Dirtab, ntab: c_int, s_: c_int, dp_: [*c]Dir) callconv(.c) c_int {
    _ = name;
    _ = tab;
    _ = ntab;
    const ch: *Chan = ch_;
    const dp: *Dir = dp_;
    var s = s_;
    switch (TYPE(ch.qid)) {
        Qtopdir => {
            if (s == c.DEVDOTDOT) {
                topdir(ch, dp);
                return 1;
            }
            if (s == 0) {
                wsdir(ch, dp);
                return 1;
            }
            if (s == 1 and Haveports) {
                portdir(ch, dp);
                return 1;
            }
            return -1;
        },
        Qwsdir => return protogen(ch, false, s, dp),
        Qportdir => return protogen(ch, true, s, dp),
        Qclone, Qpclone => {
            var q: Qid = undefined;
            dev.mkqid(&q, TYPE(ch.qid), 0, c.QTFILE);
            dev.devdir(ch, q, @constCast("clone"), 0, c.eve, 0o666, dp);
            return 1;
        },
        Qconvdir => {
            if (isportconv(CONV(ch.qid))) {
                if (s == c.DEVDOTDOT) {
                    portdir(ch, dp);
                    return 1;
                }
                // A port has no text messages.
                if (Qctl + s >= Qtext)
                    s += 1;
                return convfile(ch, CONV(ch.qid), @intCast(Qctl + s), dp);
            }
            if (s == c.DEVDOTDOT) {
                wsdir(ch, dp);
                return 1;
            }
            return convfile(ch, CONV(ch.qid), @intCast(Qctl + s), dp);
        },
        Qhost => {
            var q: Qid = undefined;
            dev.mkqid(&q, Qhost, 0, c.QTFILE);
            dev.devdir(ch, q, @constCast("hstream"), 0, c.eve, 0o660, dp);
            return 1;
        },
        else => return convfile(ch, CONV(ch.qid), TYPE(ch.qid), dp),
    }
}

fn hsattach(spec: [*:0]const u8) Error!*Chan {
    // Host-made streams are never reached by a spec.
    if (spec[0] != 0)
        return port.kerror(&port.Ebadspec);
    const ch = dev.devattach(Hsdc, spec);
    dev.mkqid(&ch.qid, Qtopdir, 0, c.QTDIR);
    return ch;
}

/// Whether hsgen reads the caller's machine for ch's entries.
fn gensmach(ch: *Chan) bool {
    return switch (TYPE(ch.qid)) {
        Qwsdir, Qportdir, Qconvdir => true,
        else => false,
    };
}

fn hswalk(ch: *Chan, nc: ?*Chan, name: [*]const [*:0]const u8, nname: c_int) Error!?*Walkqid {
    // A walk past the top reaches a protocol directory's entries.
    if (nname > 0 and gensmach(ch) or nname > 1 and TYPE(ch.qid) == Qtopdir)
        _ = try upmach();
    return dev.devwalk(ch, nc, name, nname, null, 0, &hsgen);
}

fn hsstat(ch: *Chan, db: [*]u8, n: c_int) Error!c_int {
    if (gensmach(ch))
        _ = try upmach();
    return dev.devstat(ch, db, n, null, 0, &hsgen);
}

/// The conversation a chan names, in the caller's machine.
fn convid(ch: *Chan) Error!c_ulong {
    const id = h9_hstream_conv(try upmach(), CONV(ch.qid));
    if (id < 0)
        return port.kerror(&port.Ehungup);
    return @intCast(id);
}

fn hsopen(ch: *Chan, omode: c_int) Error!*Chan {
    var err: [port.ERRMAX:0]u8 = undefined;
    switch (TYPE(ch.qid)) {
        Qtopdir, Qwsdir, Qportdir, Qconvdir, Qremote, Qstatus => {
            if ((omode & 3) != c.OREAD)
                return port.kerror(&port.Eperm);
        },
        Qclone, Qpclone => {
            const id = h9_hstream_clone(try upmach(), @intFromBool(TYPE(ch.qid) == Qpclone), &err);
            if (id < 0)
                return port.kerror(&err);
            const n = h9_hstream_convno(@intCast(id));
            ch.qid.path = @bitCast(QID(n, Qctl));
            dev.aux(ch).* = @ptrFromInt(@as(usize, @intCast(id)));
        },
        Qctl, Qdata, Qtext => {
            const id = try convid(ch);
            h9_hstream_incref(id);
            dev.aux(ch).* = @ptrFromInt(id);
        },
        Qhost => return port.kerror(&port.Eperm),
        else => {},
    }
    ch.mode = @intCast(try sysfile.openmode(@bitCast(omode)));
    ch.flag |= c.COPEN;
    ch.offset = 0;
    return ch;
}

fn hsclose(ch: *Chan) Error!void {
    if ((ch.flag & c.COPEN) == 0)
        return;
    switch (TYPE(ch.qid)) {
        Qctl, Qdata, Qtext, Qhost => h9_hstream_decref(STREAM(ch)),
        else => {},
    }
}

/// devcons.c's readstr.
fn readstr(off: i64, buf: ?*anyopaque, n_: c_int, str: []const u8) c_int {
    if (off < 0 or off >= str.len)
        return 0;
    const o: usize = @intCast(off);
    const n = @min(@as(usize, @intCast(@max(n_, 0))), str.len - o);
    @memcpy(@as([*]u8, @ptrCast(buf.?))[0..n], str[o..][0..n]);
    return @intCast(n);
}

fn hsread(ch: *Chan, va: ?*anyopaque, n: c_int, off: i64) Error!c_int {
    var buf: [256]u8 = undefined;
    switch (TYPE(ch.qid)) {
        Qtopdir, Qwsdir, Qportdir, Qconvdir => {
            if (gensmach(ch))
                _ = try upmach();
            return dev.devdirread(ch, @ptrCast(va.?), n, null, 0, &hsgen);
        },
        Qctl => return readstr(off, va, n, std.fmt.bufPrint(&buf, "{d}", .{CONV(ch.qid)}) catch unreachable),
        Qremote, Qstatus => {
            const id = try convid(ch);
            const k = h9_hstream_info(id, if (TYPE(ch.qid) == Qremote) 0 else 1, &buf, buf.len - 1);
            return readstr(off, va, n, buf[0..@intCast(k)]);
        },
        Qdata, Qhost => return streamread(STREAM(ch), Kdata, va, n),
        Qtext => return streamread(STREAM(ch), Ktext, va, n),
        else => {},
    }
    return port.kerror(&port.Egreg);
}

fn hswrite(ch: *Chan, va: ?*const anyopaque, n: c_int, off: i64) Error!c_int {
    _ = off;
    var err: [port.ERRMAX:0]u8 = undefined;
    switch (TYPE(ch.qid)) {
        Qctl => {
            const id = STREAM(ch);
            const r = h9_hstream_ctl(id, @ptrCast(va.?), n, &err);
            if (r < 0)
                return port.kerror(&err);
            if (r == 1)
                try waitconnect(id);
            return n;
        },
        Qdata, Qhost => return streamwrite(STREAM(ch), Kdata, va, n),
        Qtext => return streamwrite(STREAM(ch), Ktext, va, n),
        else => {},
    }
    return port.kerror(&port.Eperm);
}

pub const Device = dev.Native(Hsdc, "hstream", .{
    .attach = hsattach,
    .walk = hswalk,
    .stat = hsstat,
    .open = hsopen,
    .create = dev.devcreate,
    .close = hsclose,
    .read = hsread,
    .write = hswrite,
    .remove = dev.devremove,
    .wstat = dev.devwstat,
    .gens = &.{&hsgen},
});

// The C names: h9_hstream_wait and h9_hstream_fd, for src/kern.zig and src/machine.zig, return -1 with
// the error in syserrstr.

fn syserr() c_int {
    const p = up().syserrstr;
    up().syserrstr = up().errstr;
    up().errstr = p;
    return -1;
}

/// For the namespace builder (src/machine.zig): waits for a host-made
/// stream to connect.
fn h9_hstream_wait(id: c_ulong) callconv(.c) c_int {
    waitconnect(id) catch return syserr();
    return 0;
}

fn h9_hstream_fd(id: c_ulong) callconv(.c) c_int {
    return hostfd(id) catch return syserr();
}

pub fn exportC() void {
    @export(&Device.dev, .{ .name = "hstreamdevtab" });
    @export(&h9_hstream_wake, .{ .name = "h9_hstream_wake" });
    @export(&h9_hstream_wait, .{ .name = "h9_hstream_wait" });
    @export(&h9_hstream_fd, .{ .name = "h9_hstream_fd" });
}

// Cases (zig build kern-test). The namespace kernel's table has #ℏ, but
// its processes here aren't a machine's, so they reach what needs no
// conversation.

const testing = std.testing;
const kt = port.testing;

test "#ℏ lists ws, takes no spec, and needs a machine for its conversations [kernel-port]" {
    _ = try kt.namespace();
    try testing.expectError(error.Kernel, hsattach("root"));
    try testing.expectEqualStrings("bad attach specifier", kt.errstr());

    const top = try hsattach("");
    defer chan.cclose(top);
    var db: [256]u8 = undefined;
    const n = try hsread(top, &db, db.len, 0);
    var d: Dir = undefined;
    var strs: [256]u8 = undefined;
    const k = c.convM2D(&db, @intCast(n), &d, &strs);
    try testing.expect(k > 0);
    try testing.expectEqualStrings("ws", std.mem.span(d.name));
    if (!Haveports) try testing.expectEqual(@as(c_int, @intCast(k)), n);
    try testing.expectError(error.Kernel, hsopen(top, c.OWRITE));

    // A process with no machine has no conversations.
    const names = [_][*:0]const u8{ "ws", "clone" };
    try testing.expectError(error.Kernel, hswalk(top, null, &names, 2));
    try testing.expectEqualStrings("not an h9 process", kt.errstr());
}

test "a #ℏ reader waiting for its turn sees a note [kernel-port]" {
    const me = try kt.begin();
    const h = slot(7);
    h.busy[Kdata] = true;
    defer h.busy[Kdata] = false;
    me.notepending = 1;
    var b: [4]u8 = undefined;
    try testing.expectError(error.Interrupted, streamread(7, Kdata, &b, b.len));
    try testing.expectEqual(0, me.notepending);
}
