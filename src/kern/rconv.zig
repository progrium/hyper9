//! The remote conversations of src/kern/linuxnet.c in Zig
//! (design/kernel-port.md): a Linux socket on a /net mounted from another
//! machine, such as a host h9's served with --serve-net. Its data file
//! is devmnt's, which can't say whether a read would block, so a kproc
//! reads ahead into a ring the socket calls and readiness answer from,
//! and a non-blocking connect runs in a kproc of its own. The Linux layer
//! attaches each conversation it opens (h9_linux_rattach) and detaches
//! it when the description's last fd closes (h9_linux_rclose).
//!
//! A file of its own, so it's one small place to take out when
//! file-interface replaces the read-ahead. linuxnet.zig asks it through
//! rget, rgetfd, rready, rrecv, rsend, rnread, rsoerror, and rsockctl.
//! A close translation, with error unions for the C's error labels; the
//! kprocs wait in sync.zig's tsleep.

const std = @import("std");
const port = @import("port.zig");
const sync = @import("sync.zig");
const dev = @import("dev.zig");
const chan = @import("chan.zig");
const sysfile = @import("sysfile.zig");
const linuxnet = @import("linuxnet.zig");
const c = port.c;
const up = port.up;
const Error = port.Error;

const Chan = c.Chan;

const LPOLLIN = linuxnet.LPOLLIN;
const LPOLLOUT = linuxnet.LPOLLOUT;
const LPOLLERR = linuxnet.LPOLLERR;
const LPOLLHUP = linuxnet.LPOLLHUP;
const LPOLLRDHUP = linuxnet.LPOLLRDHUP;

extern fn h9_kprocdetach() void; // proc.c

const Rbufsz = 64 * 1024;

const RCidle = 0; // not connected or announced yet
const RCconnecting = 1; // a connect kproc runs
const RCopen = 2; // connected (or a bound UDP socket): the reader runs
const RClisten = 3; // announced: accept opens listen
const RCclosed = 4;

pub const Rconv = struct {
    lk: c.Lock = std.mem.zeroes(c.Lock),
    next: ?*Rconv = null,
    data: *Chan, // the fds' channel, the key; a reference of ours
    ctl: ?*Chan, // the conversation's ctl; a reference of ours
    id: c_int, // the Linux layer's: 1<<30 | proto<<12 | conversation
    udp: bool,
    state: c_int = RCidle,
    err: c_int = 0, // SO_ERROR: a Linux errno, until read
    rerr: c_int = 0, // the reader's error: a Linux errno
    eof: bool = false,
    refs: c_int, // the table's, and each kproc's
    nk: c_int = 0, // kprocs running: close waits for them
    rk: ?*c.Proc = null, // the reader, to interrupt at close
    lk2: ?*c.Proc = null, // the listener, to interrupt at close
    dir: ?*Chan = null, // the conversation's directory, for listen
    call: ?*Chan = null, // a call the listener took, for accept
    lgone: bool = false, // the listener has exited
    room: c.Rendez = std.mem.zeroes(c.Rendez),
    buf: [*]u8, // the ring: UDP keeps each message as 2 bytes of length and its bytes
    rp: c_int = 0,
    n: c_int = 0,
    cmsg: [128]u8 = std.mem.zeroes([128]u8), // the connect message for the connect kproc
};

var rclk: c.Lock = std.mem.zeroes(c.Lock);
var rconvs: ?*Rconv = null;

/// A Linux errno for a kernel error string from a remote conversation.
fn rerrno(e_: [*c]const u8) c_int {
    const e = std.mem.span(e_);
    const has = struct {
        fn f(s: []const u8, w: []const u8) bool {
            return std.mem.indexOf(u8, s, w) != null;
        }
    }.f;
    if (has(e, "refused"))
        return 111; // ECONNREFUSED
    if (has(e, "reset") or has(e, "hungup") or has(e, "hangup"))
        return 104; // ECONNRESET
    if (has(e, "timed out") or has(e, "timeout"))
        return 110; // ETIMEDOUT
    if (has(e, "permission") or has(e, "denied"))
        return 13; // EACCES
    if (has(e, "network") and has(e, "unreachable"))
        return 101; // ENETUNREACH
    if (has(e, "unreachable") or has(e, "no route"))
        return 113; // EHOSTUNREACH
    if (has(e, "in use"))
        return 98; // EADDRINUSE
    if (has(e, "interrupted"))
        return 4; // EINTR
    return 5; // EIO
}

/// The Rconv for channel ch, with a reference; null if there's none.
pub fn rget(ch: *Chan) ?*Rconv {
    c.lock(&rclk);
    var r = rconvs;
    while (r) |x| : (r = x.next) {
        if (x.data == ch) {
            c.lock(&x.lk);
            x.refs += 1;
            c.unlock(&x.lk);
            break;
        }
    }
    c.unlock(&rclk);
    return r;
}

pub fn rgetfd(fd: c_int) ?*Rconv {
    const ch = sysfile.fdtochan(fd, -1, false, true) catch return null;
    var r: ?*Rconv = null;
    if (dev.of(ch).dc == 'M')
        r = rget(ch);
    chan.cclose(ch);
    return r;
}

fn rfree(r: *Rconv) void {
    if (r.ctl) |x|
        chan.cclose(x);
    if (r.dir) |x|
        chan.cclose(x);
    if (r.call) |x|
        chan.cclose(x);
    chan.cclose(r.data);
    c.free(r.buf);
    c.free(r);
}

pub fn rput(r: *Rconv) void {
    c.lock(&r.lk);
    r.refs -= 1;
    const last = r.refs == 0;
    c.unlock(&r.lk);
    if (last)
        rfree(r);
}

/// A kproc's end: drops its reference in the same lock that says it's
/// gone, so h9_linux_rclose, waiting for nk to reach 0, makes the last
/// close itself, while the machine whose chans r holds is still there.
fn rkdone(r: *Rconv) void {
    c.lock(&r.lk);
    r.nk -= 1;
    r.refs -= 1;
    const last = r.refs == 0;
    c.unlock(&r.lk);
    if (last)
        rfree(r);
}

fn udpextra(r: *Rconv) c_int {
    return if (r.udp) 2 else 0;
}

fn hasroom(a: ?*anyopaque) callconv(.c) c_int {
    const r: *Rconv = @ptrCast(@alignCast(a.?));
    return @intFromBool(r.state == RCclosed or r.n + udpextra(r) < Rbufsz);
}

fn kpexit() noreturn {
    c.pexit(@constCast(""), 0);
    unreachable;
}

/// The kproc: reads the conversation's data into the ring until it ends.
fn rreader(a: ?*anyopaque) callconv(.c) void {
    const r: *Rconv = @ptrCast(@alignCast(a.?));
    h9_kprocdetach();
    const tmp: [*]u8 = @ptrCast(c.smalloc(Rbufsz));
    var err: c_int = 0;
    while (true) {
        var room: c_int = Rbufsz - udpextra(r);
        c.lock(&r.lk);
        if (!r.udp and Rbufsz - r.n < room)
            room = Rbufsz - r.n;
        c.unlock(&r.lk);
        if (room <= 0)
            room = 1;
        const n = dev.read(dev.of(r.data), r.data, tmp, room, 0) catch {
            if (r.state != RCclosed)
                err = rerrno(up().errstr);
            break;
        };
        if (n <= 0)
            break;
        // Waits until the whole read fits.
        while (hasroom(r) == 0 or r.n + n + udpextra(r) > Rbufsz) {
            if (r.state == RCclosed)
                break;
            sync.tsleep(&r.room, hasroom, r, 100) catch break;
        }
        if (r.state == RCclosed)
            break;
        c.lock(&r.lk);
        const ur: usize = @intCast(r.rp);
        if (r.udp) {
            const un: usize = @intCast(r.n);
            r.buf[(ur + un) % Rbufsz] = @truncate(@as(c_uint, @intCast(n)) >> 8);
            r.buf[(ur + un + 1) % Rbufsz] = @truncate(@as(c_uint, @intCast(n)));
            r.n += 2;
        }
        const un: usize = @intCast(r.n);
        for (tmp[0..@intCast(n)], 0..) |b, i|
            r.buf[(ur + un + i) % Rbufsz] = b;
        r.n += n;
        c.unlock(&r.lk);
        linuxnet.h9_pollwake();
    }
    c.free(tmp);
    c.lock(&r.lk);
    if (err != 0)
        r.rerr = err;
    r.eof = true;
    r.rk = null;
    c.unlock(&r.lk);
    linuxnet.h9_pollwake();
    rkdone(r);
    kpexit();
}

fn kproc(name: [*:0]const u8, f: *const fn (?*anyopaque) callconv(.c) void, r: *Rconv) ?*c.Proc {
    return @ptrCast(@alignCast(c.kproc(@constCast(name), f, r)));
}

fn rstartreader(r: *Rconv) void {
    c.lock(&r.lk);
    r.state = RCopen;
    r.refs += 1;
    r.nk += 1;
    c.unlock(&r.lk);
    const kp = kproc("rconv", &rreader, r);
    c.lock(&r.lk);
    if (!r.eof)
        r.rk = kp;
    if (r.state == RCclosed) if (r.rk) |p|
        sync.procinterrupt(p);
    c.unlock(&r.lk);
}

/// Writes msg to the conversation's ctl.
fn rctl(r: *Rconv, msg: [*:0]const u8) Error!void {
    const ctl = r.ctl orelse return port.kerror("no ctl for a remote conversation");
    _ = try dev.write(dev.of(ctl), ctl, msg, @intCast(std.mem.len(msg)), 0);
}

/// The conversation's directory, walked in the 9front view's /net as the
/// Linux layer opened it, for its listen file.
fn rconvdir(r: *Rconv) Error!*Chan {
    var num: [16]u8 = undefined;
    const names = [3][*:0]const u8{
        "net",
        if (r.udp) "udp" else "tcp",
        (std.mem.printSentinel(&num, "{d}", .{r.id & 0xfff}, 0) catch unreachable).ptr,
    };
    var ch = try chan.namec("#/", c.Atodir, 0, 0);
    errdefer chan.cclose(ch);
    if (try chan.walk(&ch, &names, 3, false, null) < 0)
        return port.kerror(&port.Enonexist);
    return ch;
}

fn nocall(a: ?*anyopaque) callconv(.c) c_int {
    const r: *Rconv = @ptrCast(@alignCast(a.?));
    return @intFromBool(r.state == RCclosed or r.call == null);
}

/// Opens the conversation's listen file, which waits in the server
/// until a call comes.
fn rlisten(r: *Rconv) Error!*Chan {
    const names = [1][*:0]const u8{"listen"};
    var ch = try chan.cclone(r.dir.?);
    errdefer chan.cclose(ch);
    if (try chan.walk(&ch, &names, 1, true, null) < 0)
        return port.kerror(&port.Enonexist);
    ch = try dev.open(dev.of(ch), ch, c.ORDWR);
    return ch;
}

/// The kproc for a listening socket: opens listen, and keeps the call
/// for accept, one at a time, so readiness can say one is waiting.
fn rlistener(a: ?*anyopaque) callconv(.c) void {
    const r: *Rconv = @ptrCast(@alignCast(a.?));
    h9_kprocdetach();
    while (true) {
        while (nocall(r) == 0) {
            sync.tsleep(&r.room, nocall, r, 100) catch break;
        }
        if (r.state == RCclosed)
            break;
        const ch = rlisten(r) catch {
            if (r.state != RCclosed) {
                c.lock(&r.lk);
                r.err = rerrno(up().errstr);
                c.unlock(&r.lk);
                linuxnet.h9_pollwake();
            }
            break;
        };
        c.lock(&r.lk);
        if (r.state == RCclosed) {
            c.unlock(&r.lk);
            chan.cclose(ch);
            break;
        }
        r.call = ch;
        c.unlock(&r.lk);
        linuxnet.h9_pollwake();
    }
    c.lock(&r.lk);
    r.lk2 = null;
    r.lgone = true;
    c.unlock(&r.lk);
    rkdone(r);
    kpexit();
}

/// accept on a listening remote conversation: a new fd for the waiting
/// call's ctl, -EAGAIN if none waits yet, or -errno.
fn h9_linux_raccept(fd: c_int, cloexec: c_int) callconv(.c) c_int {
    const r = rgetfd(fd) orelse return -9; // EBADF
    c.lock(&r.lk);
    const ch = r.call orelse {
        const e: c_int = if (r.state == RClisten) -11 else -22; // EAGAIN, EINVAL
        c.unlock(&r.lk);
        rput(r);
        return e;
    };
    r.call = null;
    c.unlock(&r.lk);
    _ = sync.wakeup(&r.room);
    var nfd = sysfile.newfd(ch, if (cloexec != 0) c.OCEXEC else 0);
    if (nfd < 0) {
        chan.cclose(ch);
        nfd = -24; // EMFILE
    }
    rput(r);
    return nfd;
}

/// The kproc for a non-blocking connect.
fn rconnector(a: ?*anyopaque) callconv(.c) void {
    const r: *Rconv = @ptrCast(@alignCast(a.?));
    h9_kprocdetach();
    if (rctl(r, @ptrCast(&r.cmsg))) |_| {
        if (r.state == RCconnecting)
            rstartreader(r);
    } else |_| {
        c.lock(&r.lk);
        r.err = rerrno(up().errstr);
        if (r.state == RCconnecting)
            r.state = RCidle;
        c.unlock(&r.lk);
    }
    linuxnet.h9_pollwake();
    rkdone(r);
    kpexit();
}

fn rattach(datafd: c_int, ctlfd: c_int, id: c_int, udp: c_int, open: c_int) Error!void {
    const d = try sysfile.fdtochan(datafd, -1, false, true);
    if (rget(d)) |r| {
        rput(r);
        chan.cclose(d);
        return;
    }
    var ctl: ?*Chan = null;
    if (ctlfd >= 0)
        ctl = sysfile.fdtochan(ctlfd, -1, false, true) catch null;
    const buf: ?[*]u8 = @ptrCast(c.mallocz(Rbufsz, 0));
    const m: ?*Rconv = if (buf != null) @ptrCast(@alignCast(port.malloc(@sizeOf(Rconv)))) else null;
    const r = m orelse {
        if (buf) |b|
            c.free(b);
        chan.cclose(d);
        if (ctl) |x|
            chan.cclose(x);
        return port.kerror(&port.Enomem);
    };
    r.* = .{ .data = d, .ctl = ctl, .id = id, .udp = udp != 0, .refs = 1, .buf = buf.? };
    c.lock(&rclk);
    r.next = rconvs;
    rconvs = r;
    c.unlock(&rclk);
    if (open != 0)
        rstartreader(r);
}

/// Attaches the conversation open on datafd (and ctlfd, -1 if none) to a
/// Rconv. open: it's connected already, as an accepted call is.
fn h9_linux_rattach(datafd: c_int, ctlfd: c_int, id: c_int, udp: c_int, open: c_int) callconv(.c) c_int {
    rattach(datafd, ctlfd, id, udp, open) catch return linuxnet.syserr();
    return 0;
}

/// The Linux layer's id for fd's remote conversation, or -1.
fn h9_linux_rconvid(fd: c_int) callconv(.c) c_int {
    const r = rgetfd(fd) orelse return -1;
    const id = r.id;
    rput(r);
    return id;
}

fn return0(_: ?*anyopaque) callconv(.c) c_int {
    return 0;
}

/// fd is closing: if it's the last of its description, hangs up its
/// remote conversation and lets it go.
fn h9_linux_rclose(fd: c_int) callconv(.c) void {
    const ch = sysfile.fdtochan(fd, -1, false, true) catch return;
    var r_: ?*Rconv = null;
    if (dev.of(ch).dc == 'M')
        r_ = rget(ch);
    // the fd's, ours, fdtochan's, and rget's doesn't count
    if (r_ == null or ch.ref.ref > 3) {
        if (r_) |r|
            rput(r);
        chan.cclose(ch);
        return;
    }
    const r = r_.?;
    chan.cclose(ch);
    c.lock(&rclk);
    var l: *?*Rconv = &rconvs;
    while (l.*) |x| : (l = &x.next) {
        if (x == r) {
            l.* = r.next;
            break;
        }
    }
    c.unlock(&rclk);
    c.lock(&r.lk);
    r.state = RCclosed;
    c.unlock(&r.lk);
    // devip on an h9 takes shutdown, and 9front's takes hangup
    rctl(r, "shutdown rdwr") catch {
        rctl(r, "hangup") catch {};
    };
    c.lock(&r.lk);
    if (r.rk) |p|
        sync.procinterrupt(p);
    if (r.lk2) |p|
        sync.procinterrupt(p);
    c.unlock(&r.lk);
    _ = sync.wakeup(&r.room);
    // The kprocs go before r does: one that made the last close after
    // the machine ended would close chans in its freed memory. A connect
    // kproc ends when its connect does, at most the dial's timeout.
    var i: c_int = 0;
    while (i < 1000) : (i += 1) {
        c.lock(&r.lk);
        const n = r.nk;
        if (n > 0) {
            if (r.rk) |p|
                sync.procinterrupt(p);
            if (r.lk2) |p|
                sync.procinterrupt(p);
        }
        c.unlock(&r.lk);
        if (n == 0)
            break;
        sync.tsleep(&up().ksleep, return0, null, 10) catch break; // lib.h names the field ksleep
    }
    rput(r); // rget's
    rput(r); // the table's
}

/// The poll bits ready on remote conversation r.
pub fn rready(r: *Rconv, ev: c_int) c_int {
    var b: c_int = undefined;
    c.lock(&r.lk);
    switch (r.state) {
        RCidle => b = if (r.err != 0) LPOLLERR | LPOLLOUT else @as(c_int, LPOLLOUT),
        RCconnecting => b = 0,
        RClisten => {
            b = if (r.call != null) LPOLLIN else 0;
            if (r.err != 0)
                b |= LPOLLERR;
        },
        else => {
            b = LPOLLOUT;
            if (r.n > 0)
                b |= LPOLLIN;
            if (r.eof and r.n == 0)
                b |= LPOLLIN | LPOLLRDHUP | @as(c_int, if (r.rerr != 0) LPOLLERR else LPOLLHUP);
        },
    }
    c.unlock(&r.lk);
    return b & ev;
}

/// The length of the UDP message at the ring's head.
fn msglen(r: *Rconv) c_int {
    const rp: usize = @intCast(r.rp);
    return @as(c_int, r.buf[rp]) << 8 | r.buf[(rp + 1) % Rbufsz];
}

/// recv on remote conversation r: never waits; the Linux layer polls first.
pub fn rrecv(r: *Rconv, buf: [*]u8, n: c_int, peek: bool) c_int {
    c.lock(&r.lk);
    if (r.n == 0) {
        c.unlock(&r.lk);
        if (r.state == RCopen and r.eof)
            return if (r.rerr != 0) -r.rerr else 0;
        if (r.state == RCidle and !r.udp)
            return -107; // ENOTCONN
        return -11; // EAGAIN
    }
    const rp: usize = @intCast(r.rp);
    if (r.udp) {
        const m = msglen(r);
        const got: usize = @intCast(@min(m, n));
        for (buf[0..got], 0..) |*b, i|
            b.* = r.buf[(rp + 2 + i) % Rbufsz];
        if (!peek) {
            r.rp = @intCast((rp + 2 + @as(usize, @intCast(m))) % Rbufsz);
            r.n -= 2 + m;
        }
        c.unlock(&r.lk);
        if (!peek)
            _ = sync.wakeup(&r.room);
        return m; // the whole message's length, for MSG_TRUNC
    }
    const got: c_int = @min(r.n, n);
    for (buf[0..@intCast(got)], 0..) |*b, i|
        b.* = r.buf[(rp + i) % Rbufsz];
    if (!peek) {
        r.rp = @intCast((rp + @as(usize, @intCast(got))) % Rbufsz);
        r.n -= got;
    }
    c.unlock(&r.lk);
    if (!peek)
        _ = sync.wakeup(&r.room);
    return got;
}

/// send on remote conversation r: waits for the server.
pub fn rsend(r: *Rconv, buf: [*]const u8, n: c_int) c_int {
    if (r.state == RCconnecting)
        return -11; // EAGAIN
    if (r.state != RCopen)
        return if (r.udp) -89 else -32; // EDESTADDRREQ, EPIPE
    return dev.write(dev.of(r.data), r.data, buf, n, 0) catch {
        const w = rerrno(up().errstr);
        return if (w == 104) -32 else -w; // a reset write: EPIPE
    };
}

/// FIONREAD on remote conversation r: what's in the ring, or the next
/// datagram's length.
pub fn rnread(r: *Rconv) c_int {
    c.lock(&r.lk);
    var m = r.n;
    if (r.udp and m > 0)
        m = msglen(r);
    c.unlock(&r.lk);
    return m;
}

/// SO_ERROR on remote conversation r, which reading clears.
pub fn rsoerror(r: *Rconv) c_int {
    c.lock(&r.lk);
    const s = r.err;
    r.err = 0;
    c.unlock(&r.lk);
    return s;
}

/// A control message for remote conversation r, as devip's ctl takes it.
pub fn rsockctl(r: *Rconv, msg: [*:0]const u8) Error!void {
    const m = std.mem.span(msg);
    if (std.mem.startsWith(u8, m, "nbconnect ")) {
        c.lock(&r.lk);
        if (r.state != RCidle) {
            c.unlock(&r.lk);
            return port.kerror("already connected");
        }
        // snprint's "connect %s", cut to fit as snprint cuts it
        const pre = "connect ";
        const rest = m[10..];
        const k = @min(rest.len, r.cmsg.len - 1 - pre.len);
        @memcpy(r.cmsg[0..pre.len], pre);
        @memcpy(r.cmsg[pre.len..][0..k], rest[0..k]);
        r.cmsg[pre.len + k] = 0;
        r.state = RCconnecting;
        r.err = 0;
        r.refs += 1;
        r.nk += 1;
        c.unlock(&r.lk);
        _ = kproc("rconnect", &rconnector, r);
        return;
    }
    try rctl(r, msg);
    if (std.mem.startsWith(u8, m, "connect ")) {
        if (r.state == RCidle)
            rstartreader(r);
    } else if (std.mem.startsWith(u8, m, "announce ")) {
        if (r.udp) {
            if (r.state == RCidle)
                rstartreader(r);
        } else if (r.state == RCidle) {
            r.dir = try rconvdir(r);
            c.lock(&r.lk);
            r.state = RClisten;
            r.refs += 1;
            r.nk += 1;
            c.unlock(&r.lk);
            const kp = kproc("rlisten", &rlistener, r);
            c.lock(&r.lk);
            if (!r.lgone)
                r.lk2 = kp;
            c.unlock(&r.lk);
        }
    }
}

pub fn exportC() void {
    @export(&h9_linux_raccept, .{ .name = "h9_linux_raccept" });
    @export(&h9_linux_rattach, .{ .name = "h9_linux_rattach" });
    @export(&h9_linux_rconvid, .{ .name = "h9_linux_rconvid" });
    @export(&h9_linux_rclose, .{ .name = "h9_linux_rclose" });
}

// Cases (zig build kern-test): the error mapping, which needs no server.

const testing = std.testing;

test "a remote conversation's errors map to Linux's errnos [kernel-port]" {
    try testing.expectEqual(@as(c_int, 111), rerrno("connection refused"));
    try testing.expectEqual(@as(c_int, 104), rerrno("i/o on hungup channel"));
    try testing.expectEqual(@as(c_int, 110), rerrno("connection timed out"));
    try testing.expectEqual(@as(c_int, 101), rerrno("network is unreachable"));
    try testing.expectEqual(@as(c_int, 113), rerrno("host unreachable"));
    try testing.expectEqual(@as(c_int, 98), rerrno("address in use"));
    try testing.expectEqual(@as(c_int, 4), rerrno("interrupted"));
    try testing.expectEqual(@as(c_int, 5), rerrno("something else"));
}
