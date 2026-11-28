//! src/kern/linuxnet.c in Zig (design/kernel-port.md): readiness for
//! Linux processes (design/epoch-0/linux-net.md), on the device switch's
//! `ready` and `watch` (design/file-interface.md, Part 1). h9_poll asks
//! each fd's channel which events it has, and when none has any, hangs a
//! watch on each, asks again, and sleeps until a watch fires or the
//! timeout passes. Pipes and ptys are watched on their queues, eventfds
//! on their counters, the console and devip's host sockets on the host
//! watchers here (which the console's reader and the watcher in
//! hostsock-*.c notify), and a file of a mount whose server answers
//! Tready on its own (devmnt.zig), so a poller sleeps until something it
//! polls changes.
//!
//! Every notify moves ready.zig's generation, which edge-triggered epoll
//! uses to tell a new event from an old one.
//!
//! Also the Linux socket calls devip's files can't express. A socket on
//! a /net mounted from another machine is devmnt's file, read and
//! written as it is, after its server's readiness says it won't block;
//! only what MSG_PEEK and FIONREAD look at is kept here, until it's read.
//!
//! In the full kernel only: the namespace kernel has no Linux ABI.

const std = @import("std");
const port = @import("port.zig");
const sync = @import("sync.zig");
const dev = @import("dev.zig");
const chan = @import("chan.zig");
const qio = @import("qio.zig");
const sysfile = @import("sysfile.zig");
const netcheck = @import("netcheck.zig");
const devpipe = @import("dev/pipe.zig");
const eventfd = @import("dev/eventfd.zig");
const rd = dev.rd;
const c = port.c;
const up = port.up;
const Error = port.Error;

const Chan = c.Chan;

const IPaddrlen = 16;

// devip.h's protocols, and netcheck.h's connect.
const S_TCP = 0;
const S_UDP = 1;
const H9_NETCONNECT = 0;

// devip's (src/host/devip.zig).
const ip = @import("host_dev").ip;
const h9_ip_sfd = ip.sfd;
extern fn h9_net_check(op: c_int, proto: c_int, addr: *const [IPaddrlen]u8, port: c_int) c_int; // src/kern.zig

// src/host/hostsock.h: the host's sockets.
extern fn h9so_ready(fd: c_int, events: c_int) c_int;
extern fn h9so_soerror(fd: c_int) c_int;
extern fn h9so_nread(fd: c_int) c_int;
extern fn h9so_recvfrom(fd: c_int, buf: ?*anyopaque, n: c_int, peek: c_int, dontwait: c_int, raddr: ?*[IPaddrlen]u8, rport: ?*u16) c_int;
extern fn h9so_sendto(fd: c_int, buf: ?*const anyopaque, n: c_int, dontwait: c_int, raddr: ?*const [IPaddrlen]u8, rport: u16) c_int;
extern fn h9so_watchinit() void;
extern fn h9so_watch(fd: c_int, events: c_int, owner: ?*anyopaque) void;
extern fn h9so_unwatch(owner: ?*anyopaque) void;


/// A call that failed: its error string becomes the process's
/// syserrstr, as errstr(2) reads it, and -1, as proc.c's syserr does.
pub fn syserr() c_int {
    const p = up();
    const s = p.syserrstr;
    p.syserrstr = p.errstr;
    p.errstr = s;
    return -1;
}

pub const LPOLLIN = rd.In;
pub const LPOLLPRI = rd.Pri;
pub const LPOLLOUT = rd.Out;
pub const LPOLLERR = rd.Err;
pub const LPOLLHUP = rd.Hup;
pub const LPOLLNVAL = 0x20;
pub const LPOLLRDNORM = 0x40;
pub const LPOLLWRNORM = 0x100;
pub const LPOLLRDHUP = rd.Rdhup;

/// In a pollfd's events from epollWait: an edge-triggered entry it has
/// reported, which is watched for its next change and not asked
/// (src/abi/linux/sys.zig).
const Pedge: c_int = rd.Edge;

// The host's sources: the console and devip's sockets.

/// The watches on host sockets and the console, which the host's own
/// threads notify (h9_pollwake).
var hostwatch: rd.Watchers = .{};

/// A host socket or the console may have changed: tells their watchers.
/// The watcher in hostsock-*.c calls it.
pub fn h9_pollwake() callconv(.c) void {
    rd.notify(&hostwatch);
}

pub fn h9_pollgen() callconv(.c) c_uint {
    return rd.gen();
}

/// The generation of what fd's readiness comes from, which moves with
/// each change to it (ready.changes): a host socket's is every host
/// socket's, and a device that doesn't say has the global one.
fn h9_fdgen(fd: c_int) callconv(.c) c_uint {
    const ch = sysfile.fdtochan(fd, -1, false, true) catch return rd.gen();
    defer chan.cclose(ch);
    if (dev.of(ch).dc == 'I')
        return rd.changes(&hostwatch);
    return dev.changes(ch) orelse rd.gen();
}

/// Every poller, for h9_pollkick.
var plk: c.Lock = std.mem.zeroes(c.Lock);
var pollers: ?*Poller = null;

const Poller = struct {
    s: rd.Sleeper = .{},
    next: ?*Poller = null,
};

/// Wakes every poll, select, and epoll_wait, to ask again: an epoll's
/// interest list changed under a waiting thread (src/abi/linux/sys.zig).
pub fn h9_pollkick() callconv(.c) void {
    rd.bump();
    c.lock(&plk);
    var p = pollers;
    while (p) |w| : (p = w.next)
        w.s.kick();
    c.unlock(&plk);
}

// Linux file locks (design/file-interface.md, Part 3): the table is the
// ABI's (src/abi/linux/locks.zig), and a blocked lock waits here for a
// change to it, on Part 1's wakers.

var lockwatch: rd.Watchers = .{};
var lockgen = std.atomic.Value(c_uint).init(0);
/// Locks waiting, so a change with none waiting moves no poller's
/// generation (every close comes to h9_lockwake).
var lockwaiters = std.atomic.Value(c_uint).init(0);

/// The lock table's changes, for h9_lockwait.
fn h9_lockgen() callconv(.c) c_uint {
    return lockgen.load(.seq_cst);
}

/// The lock table changed: wakes each blocked lock to try again.
fn h9_lockwake() callconv(.c) void {
    _ = lockgen.fetchAdd(1, .seq_cst);
    // A waiter counts itself before it looks at lockgen.
    if (lockwaiters.load(.seq_cst) != 0)
        rd.notify(&lockwatch);
}

/// Waits until the table has changed since h9_lockgen said seen, or a
/// note (-1, interrupted).
fn h9_lockwait(seen: c_uint) callconv(.c) c_int {
    lockwait(seen) catch return syserr();
    return 0;
}

fn lockwait(seen: c_uint) Error!void {
    var s: rd.Sleeper = .{};
    var w: rd.Watch = .{};
    rd.add(&lockwatch, &w, &s.waker);
    defer rd.unwatch(&w);
    _ = lockwaiters.fetchAdd(1, .seq_cst);
    defer _ = lockwaiters.fetchSub(1, .seq_cst);
    while (lockgen.load(.seq_cst) == seen) {
        s.arm();
        if (lockgen.load(.seq_cst) != seen)
            break;
        _ = try s.wait(0);
    }
}

/// An fd was closed (ready.closed): every waiting poll looks again, and
/// an epoll_wait, which polls once, returns and lets its channels go, as
/// Linux's epoll holds no reference to a file in its set.
fn pollclosed() void {
    if (@as(*volatile ?*Poller, &pollers).* == null)
        return;
    c.lock(&plk);
    var p = pollers;
    while (p) |w| : (p = w.next)
        w.s.kick();
    c.unlock(&plk);
}

/// A recv or send on a host socket that finds it not ready (EAGAIN). An
/// edge-triggered epoll entry that was reported ready and is still ready
/// is watched with Pedge, which doesn't watch the host socket itself (it
/// would fire at once for what's already there), so when its reader
/// drains it and the next data arrives, no wake comes. Tell the host
/// watchers here, so the entry is looked at again, found not ready, and
/// watched, as Linux reports the next arrival after a reader drains the
/// socket.
fn again(r: c_int) c_int {
    if (r == -11) // EAGAIN
        h9_pollwake();
    return r;
}

/// devip's readiness (src/host/devip.zig's ready): a conversation's host
/// socket's, and always for the rest.
pub fn ipready(ch: *Chan, ev: c_int) c_int {
    const s = h9_ip_sfd(ch, null);
    if (s < 0)
        return dev.readydefault(ev); // not a conversation, or no socket yet
    return h9so_ready(s, ev | rd.Err | rd.Hup);
}

fn ipunhook(w: *rd.Watch) callconv(.c) void {
    h9so_unwatch(w);
}

pub fn ipwatch(ch: *Chan, ev: c_int, w: *rd.Watch, wk: *rd.Waker) void {
    const s = h9_ip_sfd(ch, null);
    rd.add(&hostwatch, w, wk);
    if (s < 0 or ev & Pedge != 0)
        return;
    h9so_watchinit();
    w.unhook = ipunhook;
    h9so_watch(s, ev, w);
}

/// Linux's struct pollfd.
const Lpollfd = extern struct {
    fd: c_int,
    events: i16,
    revents: i16,
};

/// Fills in revents for each of fds and returns how many are ready,
/// sleeping until one is when none is, for up to ms (-1: forever, 0:
/// don't sleep). gen.* (if not null) gets the generation the answer is
/// for. With once, it returns 0 after the first wake instead of asking
/// again, for epoll's edge-triggered fds, and gen.* (if not null) is the
/// generation the caller's own answer was for, so a change that came
/// after that answer ends the wait at once rather than being missed. -1
/// with the error string set when a note interrupts it.
fn h9_poll(fds: [*]Lpollfd, n: c_int, ms: c_int, gen: ?*c_uint, once: c_int) callconv(.c) c_int {
    return poll(fds[0..@intCast(@max(n, 0))], ms, gen, once != 0) catch syserr();
}

/// One fd of a poll: its channel, held for the poll, and its watch.
const Pfd = struct {
    ch: ?*Chan = null,
    w: rd.Watch = .{},
};

fn poll(fds: []Lpollfd, ms: c_int, gen: ?*c_uint, once: bool) Error!c_int {
    const deadline: u64 = if (ms > 0) c.h9_tnow() + @as(u64, @intCast(ms)) * 1000000 else 0;
    var small: [16]Pfd = undefined;
    const pf: []Pfd = if (fds.len <= small.len) small[0..fds.len] else blk: {
        const m: [*]Pfd = @ptrCast(@alignCast(port.malloc(@intCast(fds.len * @sizeOf(Pfd))) orelse return port.kerror(&port.Enomem)));
        break :blk m[0..fds.len];
    };
    defer if (pf.ptr != &small) c.free(pf.ptr);
    var pl: Poller = .{};
    var listed = false;
    // Listed and armed before the fds are looked up, so a close after
    // the lookup (which this holds the channel through) kicks the wait.
    if (ms != 0) {
        rd.closed = &pollclosed;
        c.lock(&plk);
        pl.next = pollers;
        pollers = &pl;
        c.unlock(&plk);
        listed = true;
    }
    pl.s.arm();
    for (pf, fds) |*p, f| {
        p.* = .{};
        if (f.fd >= 0)
            p.ch = sysfile.fdtochan(f.fd, -1, false, true) catch null;
    }
    defer for (pf) |*p| if (p.ch) |ch| chan.cclose(ch);
    var first = true;
    defer if (listed) {
        c.lock(&plk);
        var l: *?*Poller = &pollers;
        while (l.*) |x| : (l = &x.next) {
            if (x == &pl) {
                l.* = pl.next;
                break;
            }
        }
        c.unlock(&plk);
    };
    var g: c_uint = undefined;
    var ready: c_int = undefined;
    while (true) {
        // epollWait marks with Pedge the edge-triggered entries it
        // already reported (an eventfd that stays readable, as tokio's
        // waker does), so only the generation tells their next event:
        // starting from a fresh one here would miss a change that came
        // between the caller's answer and this call, and sleep until
        // something else woke it, forever if nothing did (#276).
        g = if (once and gen != null) gen.?.* else rd.gen();
        if (!first)
            pl.s.arm();
        first = false;
        ready = scan(fds, pf);
        if (ready > 0 or ms == 0)
            break;
        for (pf, fds) |*p, f| if (p.ch) |ch|
            dev.watch(ch, @as(u16, @bitCast(f.events)), &p.w, &pl.s.waker);
        // Asked again with the watches on: a change since the first
        // answer has fired one, or shows here.
        ready = scan(fds, pf);
        if (ready == 0 and once and gen != null and rd.gen() != g) {
            unwatchall(pf);
            break;
        }
        var timedout = false;
        if (ready == 0) {
            if (ms > 0) {
                const now = c.h9_tnow();
                if (now >= deadline)
                    timedout = true
                else
                    timedout = !(pl.s.wait(@intCast((deadline - now + 999999) / 1000000)) catch |e| {
                        unwatchall(pf);
                        return e;
                    });
            } else _ = pl.s.wait(0) catch |e| {
                unwatchall(pf);
                return e;
            };
        }
        // A host socket's watch is dropped once it fires, so each wait
        // watches afresh.
        unwatchall(pf);
        if (ready > 0 or timedout)
            break;
        if (once) {
            ready = 0;
            break;
        }
    }
    if (gen) |p|
        p.* = g;
    return ready;
}

fn unwatchall(pf: []Pfd) void {
    for (pf) |*p| rd.unwatch(&p.w);
}

/// Fills in each revents from its channel's readiness: how many have
/// some.
fn scan(fds: []Lpollfd, pf: []Pfd) c_int {
    var ready: c_int = 0;
    for (fds, pf) |*f, p| {
        f.revents = 0;
        if (f.fd < 0)
            continue;
        const ch = p.ch orelse {
            f.revents = LPOLLNVAL;
            ready += 1;
            continue;
        };
        const events: c_int = @as(u16, @bitCast(f.events));
        if (events & Pedge != 0)
            continue;
        var rev = chanready(ch, events);
        if ((rev & LPOLLIN) != 0)
            rev |= events & LPOLLRDNORM;
        if ((rev & LPOLLOUT) != 0)
            rev |= events & LPOLLWRNORM;
        f.revents = @bitCast(@as(u16, @truncate(@as(c_uint, @bitCast(rev)))));
        if (f.revents != 0)
            ready += 1;
    }
    return ready;
}

/// The poll bits ready on ch now, of those in ev, plus errors and
/// hangups: the device's, and for a socket on a mounted /net what's
/// waiting here for a peek.
fn chanready(ch: *Chan, ev: c_int) c_int {
    const e = ev | LPOLLERR | LPOLLHUP;
    if (dev.of(ch).dc == 'M') if (pkget(ch)) |pk| {
        defer pkput(pk);
        if (pk.n > 0)
            return (dev.ready(ch, ev & ~@as(c_int, LPOLLIN)) | LPOLLIN) & e;
    };
    return dev.ready(ch, ev) & e;
}

/// The poll bits ready on fd now, without sleeping; -1 if it's not open.
fn h9_fdready(fd: c_int, events: c_int) callconv(.c) c_int {
    var p: Lpollfd = .{ .fd = fd, .events = @truncate(events), .revents = 0 };
    if (h9_poll(@ptrCast(&p), 1, 0, null, 0) < 0)
        return -1;
    if ((p.revents & LPOLLNVAL) != 0)
        return -1;
    return p.revents;
}

// Sockets on a mounted /net (design/file-interface.md): devmnt's data
// file of a conversation, which the Linux layer opened at
// /net/{tcp,udp}/N/data in the 9front view. What a MSG_PEEK or FIONREAD
// read is kept, by channel, until a recv takes it or the socket closes.

const Pkbufsz = 64 * 1024;

const Peek = struct {
    next: ?*Peek = null,
    ch: *Chan, // a reference of ours, the key
    refs: c_int, // the table's, and each caller's; under pklk
    lk: c.QLock = std.mem.zeroes(c.QLock),
    udp: bool,
    buf: [*]u8,
    n: c_int = 0, // bytes held: a UDP socket's one message
};

var pklk: c.Lock = std.mem.zeroes(c.Lock);
var peeks: ?*Peek = null;

fn pkget(ch: *Chan) ?*Peek {
    c.lock(&pklk);
    defer c.unlock(&pklk);
    var p = peeks;
    while (p) |x| : (p = x.next) {
        if (x.ch == ch) {
            x.refs += 1;
            return x;
        }
    }
    return null;
}

fn pkput(pk: *Peek) void {
    c.lock(&pklk);
    pk.refs -= 1;
    const last = pk.refs == 0;
    c.unlock(&pklk);
    if (last) {
        chan.cclose(pk.ch);
        c.free(pk.buf);
        c.free(pk);
    }
}

/// ch's Peek, made if it has none.
fn pkmake(ch: *Chan, udp: bool) Error!*Peek {
    if (pkget(ch)) |pk| return pk;
    const buf: [*]u8 = @ptrCast(c.mallocz(Pkbufsz, 0) orelse return port.kerror(&port.Enomem));
    const pk: *Peek = @ptrCast(@alignCast(port.malloc(@sizeOf(Peek)) orelse {
        c.free(buf);
        return port.kerror(&port.Enomem);
    }));
    pk.* = .{ .ch = ch, .refs = 2, .udp = udp, .buf = buf };
    _ = chan.incref(&ch.ref);
    c.lock(&pklk);
    pk.next = peeks;
    peeks = pk;
    c.unlock(&pklk);
    return pk;
}

/// The conversation fd is a mounted /net's, as the Linux layer names it:
/// 1<<30 | proto<<12 | N, its proto src/abi/linux/sys.zig's (0 udp, 1
/// tcp); or -1. From the channel's name, .../tcp/N/data, which holds on
/// any server, whatever its qids.
fn rconvid(ch: *Chan) c_int {
    if (dev.of(ch).dc != 'M' or ch.qid.type & c.QTDIR != 0)
        return -1;
    const path = std.mem.span(chan.chanpath(ch));
    var it = std.mem.splitBackwardsScalar(u8, path, '/');
    if (!std.mem.eql(u8, it.next() orelse return -1, "data"))
        return -1;
    const num = std.fmt.parseInt(u12, it.next() orelse return -1, 10) catch return -1;
    const proto = it.next() orelse return -1;
    const pr: c_int = if (std.mem.eql(u8, proto, "tcp")) 1 else if (std.mem.eql(u8, proto, "udp")) 0 else return -1;
    return 1 << 30 | pr << 12 | num;
}

fn h9_linux_rconvid(fd: c_int) callconv(.c) c_int {
    const ch = sysfile.fdtochan(fd, -1, false, true) catch return -1;
    defer chan.cclose(ch);
    return rconvid(ch);
}

/// fd's channel if it's a mounted /net's conversation, referenced.
fn rchan(fd: c_int, udp: *bool) ?*Chan {
    const ch = sysfile.fdtochan(fd, -1, false, true) catch return null;
    const id = rconvid(ch);
    if (id < 0) {
        chan.cclose(ch);
        return null;
    }
    udp.* = (id >> 12) & 0xff == 0;
    return ch;
}

/// fd is closing: if it's the last of its description, what's kept for
/// its peeks goes.
fn h9_linux_rclose(fd: c_int) callconv(.c) void {
    const ch = sysfile.fdtochan(fd, -1, false, true) catch return;
    defer chan.cclose(ch);
    const pk = pkget(ch) orelse return;
    // the fd's, fdtochan's, and the Peek's
    if (ch.ref.ref > 3) {
        pkput(pk);
        return;
    }
    c.lock(&pklk);
    var l: *?*Peek = &peeks;
    while (l.*) |x| : (l = &x.next) {
        if (x == pk) {
            l.* = pk.next;
            pk.refs -= 1; // the table's
            break;
        }
    }
    c.unlock(&pklk);
    pkput(pk);
}

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

/// Fills pk from its channel if it's empty and the server says a read
/// won't wait: what it holds, 0 at end of file, -EAGAIN, or -errno.
/// Under pk.lk.
fn pkfill(pk: *Peek) c_int {
    if (pk.n > 0)
        return pk.n;
    if (dev.ready(pk.ch, LPOLLIN | rd.Now) & (LPOLLIN | LPOLLHUP | LPOLLERR) == 0)
        return -11; // EAGAIN
    const m = dev.read(dev.of(pk.ch), pk.ch, pk.buf, Pkbufsz, 0) catch return -rerrno(up().errstr);
    pk.n = m;
    return m;
}

/// recv on a mounted /net's conversation: never waits (the Linux layer
/// waits first): the bytes, a datagram's whole length, 0 at end of
/// file, or -errno.
fn rrecv(ch: *Chan, udp: bool, buf: [*]u8, n: c_int, peek: bool) c_int {
    const pk = (if (peek) pkmake(ch, udp) catch return -12 else pkget(ch)) orelse return rread(ch, buf, n); // ENOMEM
    defer pkput(pk);
    sync.qlock(&pk.lk);
    defer sync.qunlock(&pk.lk);
    if (pk.n == 0 and !peek)
        return rread(ch, buf, n);
    const m = pkfill(pk);
    if (m <= 0)
        return m;
    const got: c_int = @min(m, n);
    @memcpy(buf[0..@intCast(got)], pk.buf[0..@intCast(got)]);
    if (!peek) {
        if (udp or got == m) {
            pk.n = 0;
        } else {
            const k: usize = @intCast(got);
            std.mem.copyForwards(u8, pk.buf[0..@intCast(m - got)], pk.buf[k..@intCast(m)]);
            pk.n = m - got;
        }
    }
    return if (udp) m else got;
}

/// A read straight into the caller's buffer, once the server says it
/// won't wait.
fn rread(ch: *Chan, buf: [*]u8, n: c_int) c_int {
    if (dev.ready(ch, LPOLLIN | rd.Now) & (LPOLLIN | LPOLLHUP | LPOLLERR) == 0)
        return -11; // EAGAIN
    return dev.read(dev.of(ch), ch, buf, n, 0) catch -rerrno(up().errstr);
}

/// recvfrom on a socket fd's host socket: the count or -errno. raddr
/// (16 bytes) and rport get the source if raddr isn't null.
fn h9_linux_sockrecv(fd: c_int, buf: ?*anyopaque, n: c_int, peek: c_int, dontwait: c_int, raddr: ?*[IPaddrlen]u8, rport: ?*u16) callconv(.c) c_int {
    var rudp = false;
    if (rchan(fd, &rudp)) |ch| {
        defer chan.cclose(ch);
        return rrecv(ch, rudp, @ptrCast(buf.?), n, peek != 0);
    }
    var udp: c_int = 0;
    const s = sockof(fd, &udp) catch return -9; // EBADF
    if (s < 0)
        return -107; // ENOTCONN
    const m = again(h9so_recvfrom(s, buf, n, peek, dontwait, raddr, rport));
    // A reply from the machine's resolver comes from the address the guest asked (design/linux-dns.md).
    if (m >= 0) if (raddr) |a|
        netcheck.h9_net_unredirect(if (udp != 0) S_UDP else S_TCP, s, a, rport.?);
    return m;
}

fn sockof(fd: c_int, udp: ?*c_int) Error!c_int {
    const ch = try sysfile.fdtochan(fd, -1, false, true);
    if (dev.of(ch).dc != 'I') {
        chan.cclose(ch);
        return port.kerror("not a socket");
    }
    const s = h9_ip_sfd(ch, udp);
    chan.cclose(ch);
    return s;
}

/// sendto on a socket fd's host socket, to raddr!rport if raddr isn't
/// null, after the policy's check, as devip's connect does.
fn h9_linux_socksend(fd: c_int, buf: ?*const anyopaque, n: c_int, dontwait: c_int, raddr_: ?*const [IPaddrlen]u8, rport_: u16) callconv(.c) c_int {
    var raddr = raddr_;
    var rport = rport_;
    var to: [IPaddrlen]u8 = undefined;
    var rudp = false;
    if (rchan(fd, &rudp)) |ch| {
        defer chan.cclose(ch);
        if (raddr != null)
            return -106; // EISCONN: one peer
        if (dontwait != 0 and dev.ready(ch, LPOLLOUT | rd.Now) & (LPOLLOUT | LPOLLERR | LPOLLHUP) == 0)
            return -11;
        return dev.write(dev.of(ch), ch, buf, n, 0) catch {
            const w = rerrno(up().errstr);
            return if (w == 104) -32 else -w; // a reset write: EPIPE
        };
    }
    var udp: c_int = 0;
    const s = sockof(fd, &udp) catch return -9;
    if (s < 0)
        return if (raddr != null) -89 else -107; // EDESTADDRREQ, ENOTCONN
    // A probe-only conversation sends nothing, even to an address it
    // names, since a host may send a connected socket's datagrams to its
    // peer whatever the address. A sendto's address must be allowed
    // outright, not as a probe (design/linux-dns.md).
    if (netcheck.h9_net_send(s) < 0)
        return -13; // EACCES
    if (raddr) |a| if (h9_net_check(H9_NETCONNECT, if (udp != 0) S_UDP else S_TCP, a, rport) != 0)
        return -13;
    // Port 53 may go to the machine's resolver, as devip's connect does (design/linux-dns.md).
    if (raddr) |a| {
        to = a.*;
        var p: c_int = rport;
        if (netcheck.h9_net_redirectto(if (udp != 0) S_UDP else S_TCP, s, &to, &p) < 0)
            return -13;
        raddr = &to;
        rport = @truncate(@as(c_uint, @bitCast(p)));
    }
    return again(h9so_sendto(s, buf, n, dontwait, raddr, rport));
}

/// Bytes queued in the pipe that a write on pipe end fd goes into, for
/// SCM_RIGHTS (src/abi/linux/sys.zig); -1 if fd isn't a pipe's data file.
fn h9_linux_pipequeued(fd: c_int) callconv(.c) c_int {
    const ch = sysfile.fdtochan(fd, -1, false, true) catch return -1;
    var n: c_int = -1;
    if (dev.of(ch).dc == '|' and (ch.qid.type & c.QTDIR) == 0) {
        if (devpipe.h9_pipeq(ch, 1)) |q|
            n = qio.qlen(q);
    }
    chan.cclose(ch);
    return n;
}

/// Takes what's queued on pipe end fd's read side now, without waiting,
/// for O_NONBLOCK reads and for gathering more after a read
/// (src/abi/linux/sys.zig): the bytes read, 0 at end of file, -2 when
/// nothing is queued and a writer is still open, -3 if fd isn't a pipe's
/// data file, or -1 with the error string set. Asking whether the pipe
/// is readable and then reading isn't enough: another thread reading the
/// same pipe (tokio's runtimes each drain a dup of one signal pipe) can
/// take the bytes in between, and the read then waits for more that may
/// never come (#276).
fn h9_linux_pipetryread(fd: c_int, va: [*]u8, n: c_int) callconv(.c) c_int {
    const ch = sysfile.fdtochan(fd, c.OREAD, false, true) catch return syserr();
    defer chan.cclose(ch);
    if (dev.of(ch).dc != '|' or (ch.qid.type & c.QTDIR) != 0)
        return -3;
    const q = devpipe.h9_pipeq(ch, 0) orelse return -3;
    var r = qio.qconsume(q, va, n);
    // A writer that closed after writing left its bytes to read first.
    if (r < 0 and qio.qisclosed(q) != 0) {
        r = qio.qconsume(q, va, n);
        if (r < 0)
            r = 0;
    } else if (r < 0)
        r = -2;
    return r;
}

/// The bytes a write on pipe end fd could add now without waiting, for
/// splice and sendfile (src/abi/linux/sys.zig); -1 if fd isn't a pipe's
/// data file.
fn h9_linux_piperoom(fd: c_int) callconv(.c) c_int {
    const ch = sysfile.fdtochan(fd, -1, false, true) catch return -1;
    defer chan.cclose(ch);
    if (dev.of(ch).dc != '|' or (ch.qid.type & c.QTDIR) != 0)
        return -1;
    const q = devpipe.h9_pipeq(ch, 1) orelse return -1;
    return qio.qroom(q);
}

/// F_GETPIPE_SZ and F_SETPIPE_SZ (src/abi/linux/sys.zig): with n < 0,
/// the limit of the queue a write on pipe end fd goes into; otherwise
/// sets both of the pipe's queues to n and gives n. -1 if fd isn't a
/// pipe's data file.
fn h9_linux_pipesize(fd: c_int, n: c_int) callconv(.c) c_int {
    const ch = sysfile.fdtochan(fd, -1, false, true) catch return -1;
    defer chan.cclose(ch);
    if (dev.of(ch).dc != '|' or (ch.qid.type & c.QTDIR) != 0)
        return -1;
    const wq = devpipe.h9_pipeq(ch, 1) orelse return -1;
    if (n < 0) return wq.limit;
    qio.qsetlimit(wq, n);
    const rq = devpipe.h9_pipeq(ch, 0) orelse return n;
    qio.qsetlimit(rq, n);
    return n;
}

/// An O_NONBLOCK write to pipe end fd (src/abi/linux/sys.zig): queues
/// what fits now, as qtrywrite does, and never waits for the reader.
/// The bytes written, -2 when none fit, or -3 if fd isn't a pipe's data
/// file or its read end is closed, for the caller's ordinary write to
/// fail as it does there (EPIPE, and SIGPIPE). A write blocked behind a
/// full pipe can't be woken by another thread's close of the fd, which
/// Go's poller counts on (TestClosedPipeRaceWrite).
fn h9_linux_pipetrywrite(fd: c_int, va: [*]const u8, n: c_int) callconv(.c) c_int {
    const ch = sysfile.fdtochan(fd, c.OWRITE, false, true) catch return syserr();
    defer chan.cclose(ch);
    if (dev.of(ch).dc != '|' or (ch.qid.type & c.QTDIR) != 0)
        return -3;
    const q = devpipe.h9_pipeq(ch, 1) orelse return -3;
    // PIPE_BUF: a write of at most this much goes in whole or not at all.
    const r = qio.qtrywrite(q, va, n, 4096);
    return if (r < 0) -3 else if (r == 0 and n > 0) -2 else r;
}

/// FIONREAD on a socket fd: what a recv would take now, a datagram
/// socket's next message's length. glibc's resolver sizes the buffer for
/// its second answer by it, and with 0 it receives into none, and fails
/// the lookup.
fn h9_linux_socknread(fd: c_int) callconv(.c) c_int {
    var rudp = false;
    if (rchan(fd, &rudp)) |ch| {
        defer chan.cclose(ch);
        const pk = pkmake(ch, rudp) catch return 0;
        defer pkput(pk);
        sync.qlock(&pk.lk);
        defer sync.qunlock(&pk.lk);
        return @max(pkfill(pk), 0);
    }
    const s = sockof(fd, null) catch return -9; // EBADF
    if (s < 0)
        return 0;
    return h9so_nread(s);
}

/// SO_ERROR. A mounted /net's conversation says only that it failed, by
/// its readiness, so a failed connect there is ECONNREFUSED.
fn h9_linux_soerror(fd: c_int) callconv(.c) c_int {
    var rudp = false;
    if (rchan(fd, &rudp)) |ch| {
        defer chan.cclose(ch);
        return if (dev.ready(ch, LPOLLOUT | rd.Now) & LPOLLERR != 0) 111 else 0;
    }
    const s = sockof(fd, null) catch return 9;
    return h9so_soerror(s);
}

/// Writes msg to the ctl of a mounted /net's conversation id, found in
/// the 9front view's /net, as the Linux layer opened it.
fn rctl(id: c_int, msg: [*:0]const u8) Error!void {
    var num: [16]u8 = undefined;
    const names = [4][*:0]const u8{
        "net",
        if ((id >> 12) & 0xff == 0) "udp" else "tcp",
        (std.mem.printSentinel(&num, "{d}", .{id & 0xfff}, 0) catch unreachable).ptr,
        "ctl",
    };
    var ch = try chan.namec("#/", c.Atodir, 0, 0);
    defer chan.cclose(ch);
    if (try chan.walk(&ch, &names, names.len, false, null) < 0)
        return port.kerror(&port.Enonexist);
    const ctl = try dev.open(dev.of(ch), try chan.cclone(ch), c.OWRITE);
    defer chan.cclose(ctl);
    _ = try dev.write(dev.of(ctl), ctl, msg, @intCast(std.mem.len(msg)), 0);
}

fn sockctl(fd: c_int, msg: [*:0]const u8) Error!void {
    const ch = try sysfile.fdtochan(fd, -1, false, true);
    defer chan.cclose(ch);
    const id = rconvid(ch);
    if (id >= 0)
        return rctl(id, msg);
    if (dev.of(ch).dc != 'I')
        return port.kerror("not a socket");
    _ = try ip.ctl(ch, msg);
}

fn h9_linux_sockctl(fd: c_int, msg: [*:0]const u8) callconv(.c) c_int {
    sockctl(fd, msg) catch return syserr();
    return 0;
}

pub fn exportC() void {
    @export(&h9_pollgen, .{ .name = "h9_pollgen" });
    @export(&h9_fdgen, .{ .name = "h9_fdgen" });
    @export(&h9_pollwake, .{ .name = "h9_pollwake" });
    @export(&h9_pollkick, .{ .name = "h9_pollkick" });
    @export(&h9_lockgen, .{ .name = "h9_lockgen" });
    @export(&h9_lockwake, .{ .name = "h9_lockwake" });
    @export(&h9_lockwait, .{ .name = "h9_lockwait" });
    @export(&h9_poll, .{ .name = "h9_poll" });
    @export(&h9_fdready, .{ .name = "h9_fdready" });
    @export(&h9_linux_sockrecv, .{ .name = "h9_linux_sockrecv" });
    @export(&h9_linux_socksend, .{ .name = "h9_linux_socksend" });
    @export(&h9_linux_pipequeued, .{ .name = "h9_linux_pipequeued" });
    @export(&h9_linux_pipetryread, .{ .name = "h9_linux_pipetryread" });
    @export(&h9_linux_pipetrywrite, .{ .name = "h9_linux_pipetrywrite" });
    @export(&h9_linux_piperoom, .{ .name = "h9_linux_piperoom" });
    @export(&h9_linux_pipesize, .{ .name = "h9_linux_pipesize" });
    @export(&h9_linux_socknread, .{ .name = "h9_linux_socknread" });
    @export(&h9_linux_soerror, .{ .name = "h9_linux_soerror" });
    @export(&h9_linux_sockctl, .{ .name = "h9_linux_sockctl" });
    @export(&h9_linux_rconvid, .{ .name = "h9_linux_rconvid" });
    @export(&h9_linux_rclose, .{ .name = "h9_linux_rclose" });
    eventfd.exportC();
}

// Cases (zig build kern-test): the poll over channels, which needs no
// Linux ABI. The namespace kernel's machine runs them, so the poll
// sleeps as a process.

const testing = std.testing;

fn closefds(fds: []const c_int) void {
    for (fds) |fd| _ = sysfile.close(fd) catch {};
}

test "a poll on a pipe times out empty, and a write from another process ends it [file-interface]" {
    _ = try port.testing.namespace();
    var fds: [2]c_int = undefined;
    _ = try sysfile.pipe(&fds);
    defer closefds(&fds);
    var pf = [1]Lpollfd{.{ .fd = fds[0], .events = LPOLLIN, .revents = 0 }};
    try testing.expectEqual(@as(c_int, 0), try poll(&pf, 20, null, false));
    pf[0].events = LPOLLOUT;
    try testing.expectEqual(@as(c_int, 1), try poll(&pf, 0, null, false));
    try testing.expectEqual(@as(i16, LPOLLOUT), pf[0].revents);
    const wr = try sysfile.fdtochan(fds[1], -1, false, true);
    defer chan.cclose(wr);
    var k: port.testing.Kproc = undefined;
    try k.start(struct {
        fn run(ch: *Chan) void {
            c.osmsleep(20);
            _ = dev.write(dev.of(ch), ch, "x", 1, 0) catch {};
        }
    }.run, .{wr});
    pf[0].events = LPOLLIN;
    try testing.expectEqual(@as(c_int, 1), try poll(&pf, 10000, null, false));
    try testing.expectEqual(@as(i16, LPOLLIN), pf[0].revents);
    k.join();
    try testing.expect(pollers == null);
}

test "a closed fd polls as invalid, and a hung-up pipe as readable and hung up [file-interface]" {
    _ = try port.testing.namespace();
    var fds: [2]c_int = undefined;
    _ = try sysfile.pipe(&fds);
    defer closefds(fds[0..1]);
    closefds(fds[1..]);
    var pf = [2]Lpollfd{
        .{ .fd = fds[0], .events = LPOLLIN, .revents = 0 },
        .{ .fd = fds[1], .events = LPOLLIN, .revents = 0 },
    };
    try testing.expectEqual(@as(c_int, 2), try poll(&pf, -1, null, false));
    try testing.expect(pf[0].revents & LPOLLHUP != 0);
    try testing.expectEqual(@as(i16, LPOLLNVAL), pf[1].revents);
}

test "an edge-triggered poll waits for the next change, and ends at once for one it missed [file-interface]" {
    _ = try port.testing.namespace();
    var fds: [2]c_int = undefined;
    _ = try sysfile.pipe(&fds);
    defer closefds(&fds);
    _ = try sysfile.pwrite(fds[1], "x", 1, -1);
    // Reported, and still readable: the poll waits for a change.
    var pf = [1]Lpollfd{.{ .fd = fds[0], .events = @bitCast(@as(u16, LPOLLIN | Pedge)), .revents = 0 }};
    var g = rd.gen();
    var t0 = c.h9_tnow();
    try testing.expectEqual(@as(c_int, 0), try poll(&pf, 30, &g, true));
    try testing.expect(c.h9_tnow() - t0 >= 25 * 1000000);
    // A write after that answer ends the next wait at once.
    _ = try sysfile.pwrite(fds[1], "y", 1, -1);
    t0 = c.h9_tnow();
    try testing.expectEqual(@as(c_int, 0), try poll(&pf, 10000, &g, true));
    try testing.expect(c.h9_tnow() - t0 < 5000 * 1000000);
}

test "a blocked lock waits for a change to the lock table, and no clock ends it [file-interface]" {
    _ = try port.testing.begin();
    var done = std.atomic.Value(bool).init(false);
    var k: port.testing.Kproc = undefined;
    try k.start(struct {
        fn run(seen: c_uint, d: *std.atomic.Value(bool)) void {
            lockwait(seen) catch {};
            d.store(true, .seq_cst);
        }
    }.run, .{ h9_lockgen(), &done });
    // A poll would have looked many times by now.
    c.osmsleep(100);
    try testing.expect(!done.load(.seq_cst));
    h9_lockwake();
    var i: usize = 0;
    while (!done.load(.seq_cst) and i < 10000) : (i += 1)
        c.osmsleep(1);
    try testing.expect(done.load(.seq_cst));
    k.join();
}

test "closing an fd ends a once poll waiting on it, which lets the channel go [file-interface]" {
    _ = try port.testing.namespace();
    var fds: [2]c_int = undefined;
    _ = try sysfile.pipe(&fds);
    defer _ = sysfile.close(fds[1]) catch {};
    const rd0 = try sysfile.fdtochan(fds[0], -1, false, true);
    defer chan.cclose(rd0);
    const refs = rd0.ref.ref;
    var k: port.testing.Kproc = undefined;
    try k.start(struct {
        // In the poller's fd group, as another thread of its program.
        fn run(fd: c_int, fg: *c.Fgrp) void {
            const own = port.up().fgrp;
            port.up().fgrp = fg;
            defer port.up().fgrp = own;
            c.osmsleep(50);
            _ = sysfile.close(fd) catch {};
        }
    }.run, .{ fds[0], port.up().fgrp });
    var g: c_uint = rd.gen();
    var pf = [1]Lpollfd{.{ .fd = fds[0], .events = LPOLLIN, .revents = 0 }};
    const t0 = c.h9_tnow();
    _ = try poll(&pf, 10000, &g, true);
    try testing.expect(c.h9_tnow() - t0 < 5000 * 1000000);
    k.join();
    // The fd's and this case's references were all; the poll's is gone.
    try testing.expect(rd0.ref.ref <= refs);
}
