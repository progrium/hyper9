//! src/kern/linuxnet.c in Zig (design/kernel-port.md): readiness for
//! Linux processes (design/epoch-0/linux-net.md). h9_poll asks each fd's
//! channel whether a read or write would block, and sleeps until one
//! wouldn't or the timeout passes. Pipes and other qio queues wake
//! pollers from qio's own wakeups (h9_qwake, a hook in qio.zig), the
//! console from its reader thread, and host sockets from the watcher in
//! hostsock-*.c. Every wake bumps one generation number and wakes every
//! poller, which then asks its channels again; edge-triggered epoll uses
//! the generation to tell a new event from an old one.
//!
//! Also the Linux socket calls devip's files can't express. A close
//! translation: the same functions in the same order, with error unions
//! for the C's error labels, and the exported functions keep the C's
//! contracts. The C's other two parts are files of their own: #ε, eventfd
//! and epoll instances, is dev/eventfd.zig, and the read-ahead for remote
//! conversations is rconv.zig, kept apart since file-interface replaces
//! it (design/kernel-port.md).
//!
//! In the full kernel only: the namespace kernel has no Linux ABI, and
//! src/kern/nstab.c stands in for h9_qwake.

const std = @import("std");
const port = @import("port.zig");
const sync = @import("sync.zig");
const dev = @import("dev.zig");
const chan = @import("chan.zig");
const qio = @import("qio.zig");
const sysfile = @import("sysfile.zig");
const netcheck = @import("netcheck.zig");
const rconv = @import("rconv.zig");
const devpipe = @import("dev/pipe.zig");
const devpty = @import("dev/pty.zig");
const eventfd = @import("dev/eventfd.zig");
const c = port.c;
const up = port.up;
const Error = port.Error;

const Chan = c.Chan;
const Queue = c.Queue;

const IPaddrlen = 16;

// devip.h's protocols, and netcheck.h's connect.
const S_TCP = 0;
const S_UDP = 1;
const H9_NETCONNECT = 0;

extern fn h9_ip_sfd(ch: *Chan, udp: ?*c_int) c_int; // kern/devip.c
extern fn h9_cons_poll(id: c_ulong) c_int; // src/kern.zig
extern fn h9_net_check(op: c_int, proto: c_int, addr: *const [IPaddrlen]u8, port: c_int) c_int; // src/kern.zig

// src/kern/hostsock.h: the host's sockets.
extern fn h9so_ready(fd: c_int, events: c_int) c_int;
extern fn h9so_soerror(fd: c_int) c_int;
extern fn h9so_nread(fd: c_int) c_int;
extern fn h9so_recvfrom(fd: c_int, buf: ?*anyopaque, n: c_int, peek: c_int, dontwait: c_int, raddr: ?*[IPaddrlen]u8, rport: ?*u16) c_int;
extern fn h9so_sendto(fd: c_int, buf: ?*const anyopaque, n: c_int, dontwait: c_int, raddr: ?*const [IPaddrlen]u8, rport: u16) c_int;
extern fn h9so_watchinit() void;
extern fn h9so_watch(fd: c_int, events: c_int, owner: ?*anyopaque) void;
extern fn h9so_unwatch(owner: ?*anyopaque) void;

// devip's h9_ip_ctl, which raises, so it's called through dev.zig's
// `raising`.
extern fn h9_ip_ctl(ch: [*c]Chan, msg: [*c]u8) c_int;

/// A call that failed: its error string becomes the process's
/// syserrstr, as errstr(2) reads it, and -1, as proc.c's syserr does.
pub fn syserr() c_int {
    const p = up();
    const s = p.syserrstr;
    p.syserrstr = p.errstr;
    p.errstr = s;
    return -1;
}

pub const LPOLLIN = 1;
pub const LPOLLPRI = 2;
pub const LPOLLOUT = 4;
pub const LPOLLERR = 8;
pub const LPOLLHUP = 0x10;
pub const LPOLLNVAL = 0x20;
pub const LPOLLRDNORM = 0x40;
pub const LPOLLWRNORM = 0x100;
pub const LPOLLRDHUP = 0x2000;

const Epsilon = eventfd.Epsilon; // #ε
const Tau = devpty.Tau; // #τ, ptys

const Poller = struct {
    r: c.Rendez = std.mem.zeroes(c.Rendez),
    gen: c_uint,
    next: ?*Poller = null,
};

var pollgen = std.atomic.Value(c_uint).init(0);
var npollers = std.atomic.Value(c_int).init(0);
var plk: c.Lock = std.mem.zeroes(c.Lock);
var pollers: ?*Poller = null;

pub fn h9_pollgen() callconv(.c) c_uint {
    return pollgen.load(.seq_cst);
}

/// Something may have become ready: wake every poller.
pub fn h9_pollwake() callconv(.c) void {
    _ = pollgen.fetchAdd(1, .seq_cst);
    if (npollers.load(.seq_cst) == 0)
        return;
    c.lock(&plk);
    var p = pollers;
    while (p) |w| : (p = w.next)
        _ = sync.wakeup(&w.r);
    c.unlock(&plk);
}

/// A recv or send on a host socket that finds it not ready (EAGAIN). An
/// edge-triggered epoll entry that was reported ready and is still ready
/// isn't waited on (linux/sys.zig's epollWait), and nothing watches the
/// host socket then, so when its reader drains it and the next data
/// arrives, no wake comes: the wait sleeps on until something else wakes
/// it. Wake the pollers here, so the entry is looked at again, found not
/// ready, and waited on, as Linux reports the next arrival after a reader
/// drains the socket.
fn again(r: c_int) c_int {
    if (r == -11) // EAGAIN
        h9_pollwake();
    return r;
}

/// h9: called by qio after a queue changes (qio.zig).
fn h9_qwake(q: ?*Queue) callconv(.c) void {
    _ = q;
    h9_pollwake();
}

fn genchanged(a: ?*anyopaque) callconv(.c) c_int {
    const w: *Poller = @ptrCast(@alignCast(a.?));
    return @intFromBool(h9_pollgen() != w.gen);
}

/// Sleeps until the generation moves past gen, ms passes (0: forever) or
/// a note arrives (an error, as for any sleep). Returns whether it was
/// the timeout.
pub fn pollwait(gen: c_uint, ms: c_uint) Error!bool {
    var w: Poller = .{ .gen = gen };
    c.lock(&plk);
    w.next = pollers;
    pollers = &w;
    _ = npollers.fetchAdd(1, .seq_cst);
    c.unlock(&plk);
    defer {
        c.lock(&plk);
        var l: *?*Poller = &pollers;
        while (l.*) |p| : (l = &p.next) {
            if (p == &w) {
                l.* = w.next;
                break;
            }
        }
        _ = npollers.fetchSub(1, .seq_cst);
        c.unlock(&plk);
    }
    const start = c.h9_tnow();
    if (ms == 0)
        try sync.sleep(&w.r, genchanged, &w)
    else
        try sync.tsleep(&w.r, genchanged, &w, ms);
    return ms != 0 and genchanged(&w) == 0 and c.h9_tnow() - start >= @as(u64, ms) * 1000000;
}

/// The poll bits ready on ch now, of those in ev (plus errors and
/// hangups, which are always reported). sfd.* is set to a host socket to
/// watch when none is.
fn chanready(ch: *Chan, ev_: c_int, sfd: *c_int) c_int {
    sfd.* = -1;
    const dc = dev.of(ch).dc;
    const ev = ev_ | LPOLLERR | LPOLLHUP;
    switch (dc) {
        '|', Tau => {
            const rq = if ((ch.qid.type & c.QTDIR) != 0)
                null
            else if (dc == Tau)
                devpty.h9_ptyq(ch, 0)
            else
                devpipe.h9_pipeq(ch, 0);
            const q = rq orelse return (LPOLLIN | LPOLLOUT) & ev;
            const wq = (if (dc == Tau) devpty.h9_ptyq(ch, 1) else devpipe.h9_pipeq(ch, 1)).?;
            var r: c_int = 0;
            if (qio.qcanread(q))
                r |= LPOLLIN
            else if (qio.qisclosed(q) != 0)
                r |= LPOLLIN | LPOLLHUP | LPOLLRDHUP;
            if (qio.qisclosed(wq) != 0)
                r |= LPOLLERR
            else if (qio.qfull(wq) == 0)
                r |= LPOLLOUT;
            return r & ev;
        },
        'y' => {
            var r: c_int = LPOLLOUT;
            // Asking starts a host read, as a read would; its input wakes us.
            if (ch.qid.path != 1 // Qcons
            or (ev & LPOLLIN) == 0 or h9_cons_poll(ch.dev) != 0)
                r |= LPOLLIN;
            return r & ev;
        },
        'I' => {
            var udp: c_int = 0;
            const s = h9_ip_sfd(ch, &udp);
            if (s < 0)
                return (LPOLLIN | LPOLLOUT) & ev; // not a conversation, or no socket yet
            const r = h9so_ready(s, ev);
            if (r == 0)
                sfd.* = s;
            return r;
        },
        Epsilon => return eventfd.evready(ch, ev),
        'M' => {
            if (rconv.rget(ch)) |rc| {
                const r = rconv.rready(rc, ev);
                rconv.rput(rc);
                return r;
            }
        },
        else => {},
    }
    // Files, devmnt and the rest: ready, so a read blocks as it would.
    return (LPOLLIN | LPOLLOUT) & ev;
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
/// generation the caller's own answer was for, so a wake that came after
/// that answer ends the wait at once rather than being missed. -1 with
/// the error string set when a note interrupts it.
fn h9_poll(fds: [*]Lpollfd, n: c_int, ms: c_int, gen: ?*c_uint, once: c_int) callconv(.c) c_int {
    var owner: u8 = 0;
    const ready = poll(fds, n, ms, gen, once != 0, &owner) catch {
        h9so_unwatch(&owner);
        return syserr();
    };
    return ready;
}

fn poll(fds: [*]Lpollfd, n: c_int, ms: c_int, gen: ?*c_uint, once: bool, owner: *u8) Error!c_int {
    const deadline: u64 = if (ms > 0) c.h9_tnow() + @as(u64, @intCast(ms)) * 1000000 else 0;
    var g: c_uint = undefined;
    var ready: c_int = undefined;
    while (true) {
        // epollWait leaves out of fds the edge-triggered entries it
        // already reported (an eventfd that stays readable, as tokio's
        // waker does), so only the generation tells their next event:
        // starting from a fresh one here would miss a wake that came
        // between the caller's answer and this call, and sleep until
        // something else woke it, forever if nothing did (#276).
        g = if (once and gen != null) gen.?.* else h9_pollgen();
        ready = 0;
        for (fds[0..@intCast(@max(n, 0))]) |*f| {
            f.revents = 0;
            if (f.fd < 0)
                continue;
            const ch = sysfile.fdtochan(f.fd, -1, false, true) catch {
                f.revents = LPOLLNVAL;
                ready += 1;
                continue;
            };
            const events: c_int = @as(u16, @bitCast(f.events));
            var sfd: c_int = undefined;
            var rev = chanready(ch, events, &sfd);
            if ((rev & LPOLLIN) != 0)
                rev |= events & LPOLLRDNORM;
            if ((rev & LPOLLOUT) != 0)
                rev |= events & LPOLLWRNORM;
            f.revents = @bitCast(@as(u16, @truncate(@as(c_uint, @bitCast(rev)))));
            if (f.revents == 0 and sfd >= 0 and ms != 0) {
                h9so_watchinit();
                h9so_watch(sfd, f.events, owner);
            }
            chan.cclose(ch);
            if (f.revents != 0)
                ready += 1;
        }
        if (ready > 0 or ms == 0)
            break;
        if (ms > 0) {
            const now = c.h9_tnow();
            if (now >= deadline)
                break;
            if (try pollwait(g, @intCast((deadline - now + 999999) / 1000000)))
                break;
        } else _ = try pollwait(g, 0);
        h9so_unwatch(owner);
        if (once) {
            ready = 0;
            break;
        }
    }
    h9so_unwatch(owner);
    if (gen) |p|
        p.* = g;
    return ready;
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

// Linux socket calls that devip's files can't express: recv and send
// with flags, SO_ERROR, and control messages on the conversation behind
// fd. They return -errno (Linux's) or set the error string and return
// -1 as the other leaves do.

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

/// recvfrom on a socket fd's host socket: the count or -errno. raddr
/// (16 bytes) and rport get the source if raddr isn't null.
fn h9_linux_sockrecv(fd: c_int, buf: ?*anyopaque, n: c_int, peek: c_int, dontwait: c_int, raddr: ?*[IPaddrlen]u8, rport: ?*u16) callconv(.c) c_int {
    if (rconv.rgetfd(fd)) |r| {
        const m = rconv.rrecv(r, @ptrCast(buf.?), n, peek != 0);
        rconv.rput(r);
        return m;
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

/// sendto on a socket fd's host socket, to raddr!rport if raddr isn't
/// null, after the policy's check, as devip's connect does.
fn h9_linux_socksend(fd: c_int, buf: ?*const anyopaque, n: c_int, dontwait: c_int, raddr_: ?*const [IPaddrlen]u8, rport_: u16) callconv(.c) c_int {
    var raddr = raddr_;
    var rport = rport_;
    var to: [IPaddrlen]u8 = undefined;
    if (rconv.rgetfd(fd)) |r| {
        const m = if (raddr != null) -106 else rconv.rsend(r, @ptrCast(buf.?), n); // EISCONN: one peer
        rconv.rput(r);
        return m;
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

/// FIONREAD on a socket fd: what a recv would take now, a datagram
/// socket's next message's length. glibc's resolver sizes the buffer for
/// its second answer by it, and with 0 it receives into none, and fails
/// the lookup.
fn h9_linux_socknread(fd: c_int) callconv(.c) c_int {
    if (rconv.rgetfd(fd)) |r| {
        const m = rconv.rnread(r);
        rconv.rput(r);
        return m;
    }
    const s = sockof(fd, null) catch return -9; // EBADF
    if (s < 0)
        return 0;
    return h9so_nread(s);
}

fn h9_linux_soerror(fd: c_int) callconv(.c) c_int {
    if (rconv.rgetfd(fd)) |r| {
        const s = rconv.rsoerror(r);
        rconv.rput(r);
        return s;
    }
    const s = sockof(fd, null) catch return 9;
    return h9so_soerror(s);
}

fn sockctl(fd: c_int, msg: [*:0]const u8) Error!void {
    const ch = try sysfile.fdtochan(fd, -1, false, true);
    defer chan.cclose(ch);
    if (dev.of(ch).dc == 'M') {
        if (rconv.rget(ch)) |r| {
            defer rconv.rput(r);
            return rconv.rsockctl(r, msg);
        }
    }
    if (dev.of(ch).dc != 'I')
        return port.kerror("not a socket");
    _ = try dev.raising(&h9_ip_ctl, .{ ch, @constCast(msg) });
}

fn h9_linux_sockctl(fd: c_int, msg: [*:0]const u8) callconv(.c) c_int {
    sockctl(fd, msg) catch return syserr();
    return 0;
}

pub fn exportC() void {
    @export(&h9_pollgen, .{ .name = "h9_pollgen" });
    @export(&h9_pollwake, .{ .name = "h9_pollwake" });
    @export(&h9_qwake, .{ .name = "h9_qwake" });
    @export(&h9_poll, .{ .name = "h9_poll" });
    @export(&h9_fdready, .{ .name = "h9_fdready" });
    @export(&h9_linux_sockrecv, .{ .name = "h9_linux_sockrecv" });
    @export(&h9_linux_socksend, .{ .name = "h9_linux_socksend" });
    @export(&h9_linux_pipequeued, .{ .name = "h9_linux_pipequeued" });
    @export(&h9_linux_pipetryread, .{ .name = "h9_linux_pipetryread" });
    @export(&h9_linux_socknread, .{ .name = "h9_linux_socknread" });
    @export(&h9_linux_soerror, .{ .name = "h9_linux_soerror" });
    @export(&h9_linux_sockctl, .{ .name = "h9_linux_sockctl" });
    eventfd.exportC();
    rconv.exportC();
}

// Cases (zig build kern-test): the wait, which needs no Linux ABI. The
// namespace kernel's machine runs them, so pollwait sleeps as a process.

const testing = std.testing;

test "pollwait times out when no wake comes [kernel-port]" {
    _ = try port.testing.begin();
    const g = h9_pollgen();
    try testing.expect(try pollwait(g, 20));
}

test "pollwait returns at once for a generation already past [kernel-port]" {
    _ = try port.testing.begin();
    const g = h9_pollgen();
    h9_pollwake();
    try testing.expect(!try pollwait(g, 5000));
    try testing.expect(pollers == null);
    try testing.expectEqual(@as(c_int, 0), npollers.load(.seq_cst));
}

test "a wake from another process ends a pollwait [kernel-port]" {
    _ = try port.testing.begin();
    var k: port.testing.Kproc = undefined;
    const g = h9_pollgen();
    try k.start(struct {
        fn run(gen: c_uint) void {
            while (h9_pollgen() == gen and npollers.load(.seq_cst) == 0)
                std.Thread.yield() catch {};
            h9_pollwake();
        }
    }.run, .{g});
    try testing.expect(!try pollwait(g, 10000));
    k.join();
}
