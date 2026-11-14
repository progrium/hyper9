//! The kernel leaves the Linux personality uses beyond src/kern.zig's:
//! src/kern/linux.c. Stubs stand in where kern isn't built.

const std = @import("std");
const kern = @import("../kern.zig");

const c = if (kern.available) real else stub;

const real = struct {
    extern fn h9_linux_setslash(linux: c_int) c_int;
    extern fn h9_linux_inview() c_int;
    extern fn h9_linux_dotfd(fd: c_int) ?*anyopaque;
    extern fn h9_linux_dotrestore(old: ?*anyopaque) void;
    extern fn h9_linux_fdinfo(fd: c_int, dc: *c_int, dev: *c_uint, qpath: *u64, qtype: *c_int, mode: *c_int, cexec: *c_int) c_int;
    extern fn h9_linux_setcputime(user: c_ulong, sys: c_ulong) void;
    extern fn h9_linux_fdchan(fd: c_int, refs: *c_int) usize;
    extern fn h9_linux_changet(fd: c_int) ?*anyopaque;
    extern fn h9_linux_chanpread(ch: *anyopaque, buf: [*]u8, n: c_long, off: i64) c_long;
    extern fn h9_linux_chanput(ch: *anyopaque) void;
    extern fn h9_linux_setcexec(fd: c_int, on: c_int) c_int;
    extern fn h9_linux_maxfd() c_int;
    extern fn h9_linux_fds(fds: [*]c_int, n: c_int) c_int;
    extern fn h9_linux_await(buf: [*]u8, n: c_int, block: c_int, want: c_long, peek: c_int) c_int;
    extern fn h9_linux_ppid() c_ulong;
    extern fn h9_linux_getcwd(buf: [*]u8, n: c_int) c_int;
    extern fn h9_linux_fchdir(fd: c_int) c_int;
    extern fn h9_linux_setgen(f: Gen) void;
    extern fn h9_poll(fds: [*]PollFd, n: c_int, ms: c_int, gen: ?*c_uint, once: c_int) c_int;
    extern fn h9_fdready(fd: c_int, events: c_int) c_int;
    extern fn h9_pollgen() c_uint;
    extern fn h9_pollwake() void;
    extern fn h9_futex_wait(key: *const anyopaque, addr: u64, word: *u32, val: u32, bitset: u32, ms: c_int) c_int;
    extern fn h9_futex_wake(key: *const anyopaque, addr: u64, n: c_int, bitset: u32, addr2: u64, nreq: c_int, word: ?*u32, val: u32) c_int;
    extern fn h9_linux_sockrecv(fd: c_int, buf: [*]u8, n: c_int, peek: c_int, dontwait: c_int, raddr: ?*[16]u8, rport: ?*u16) c_int;
    extern fn h9_linux_socksend(fd: c_int, buf: [*]const u8, n: c_int, dontwait: c_int, raddr: ?*const [16]u8, rport: u16) c_int;
    extern fn h9_linux_soerror(fd: c_int) c_int;
    extern fn h9_linux_pipequeued(fd: c_int) c_long;
    extern fn h9so_hasv6() c_int;
    extern fn h9so_ifaddrs(a: [*]IfAddr, max: c_int) c_int;
    extern fn h9_linux_sockctl(fd: c_int, msg: [*:0]const u8) c_int;
    extern fn h9_linux_rattach(datafd: c_int, ctlfd: c_int, id: c_int, udp: c_int, open: c_int) c_int;
    extern fn h9_linux_rconvid(fd: c_int) c_int;
    extern fn h9_linux_rclose(fd: c_int) void;
    extern fn h9_linux_raccept(fd: c_int, cloexec: c_int) c_int;
    extern fn h9_linux_syncfs(fd: c_int) c_int;
    extern fn h9_linux_sync() c_int;
    extern fn h9_pty_get(fd: c_int, s: *PtyState) c_int;
    extern fn h9_pty_set(fd: c_int, s: *const PtyState, what: c_int, excl: c_int) c_int;
    extern fn h9_pty_bysid(sid: c_ulong) c_int;
    extern fn h9_pty_queued(fd: c_int, wr: c_int, flush: c_int) c_long;
    extern fn h9_pty_sethup(f: PtyHup) void;
};

/// devlinux's hook for its text files (src/kern/devlinux.c): the file's
/// name, the process's `aux` for /proc/n files (null for the machine's
/// own), into buf; returns the length or -1.
pub const Gen = *const fn (aux: ?*anyopaque, name: [*:0]const u8, pid: c_ulong, buf: [*]u8, n: c_int) callconv(.c) c_int;

const stub = struct {
    fn h9so_hasv6() c_int {
        return 1;
    }
    fn h9so_ifaddrs(_: [*]IfAddr, _: c_int) c_int {
        return 0;
    }
    fn h9_linux_setslash(_: c_int) c_int {
        return -1;
    }
    fn h9_linux_inview() c_int {
        return 0;
    }
    fn h9_linux_dotfd(_: c_int) ?*anyopaque {
        return null;
    }
    fn h9_linux_dotrestore(_: ?*anyopaque) void {}
    fn h9_linux_setcputime(_: c_ulong, _: c_ulong) void {}
    fn h9_linux_fdchan(_: c_int, _: *c_int) usize {
        return 0;
    }
    fn h9_linux_changet(_: c_int) ?*anyopaque {
        return null;
    }
    fn h9_linux_chanpread(_: *anyopaque, _: [*]u8, _: c_long, _: i64) c_long {
        return -1;
    }
    fn h9_linux_chanput(_: *anyopaque) void {}
    fn h9_linux_fdinfo(_: c_int, _: *c_int, _: *c_uint, _: *u64, _: *c_int, _: *c_int, _: *c_int) c_int {
        return -1;
    }
    fn h9_linux_setcexec(_: c_int, _: c_int) c_int {
        return -1;
    }
    fn h9_linux_maxfd() c_int {
        return -1;
    }
    fn h9_linux_fds(_: [*]c_int, _: c_int) c_int {
        return 0;
    }
    fn h9_linux_await(_: [*]u8, _: c_int, _: c_int, _: c_long, _: c_int) c_int {
        return -1;
    }
    fn h9_linux_ppid() c_ulong {
        return 1;
    }
    fn h9_linux_getcwd(_: [*]u8, _: c_int) c_int {
        return -1;
    }
    fn h9_linux_fchdir(_: c_int) c_int {
        return -1;
    }
    fn h9_linux_setgen(_: Gen) void {}
    fn h9_poll(_: [*]PollFd, _: c_int, _: c_int, _: ?*c_uint, _: c_int) c_int {
        return -1;
    }
    fn h9_fdready(_: c_int, _: c_int) c_int {
        return -1;
    }
    fn h9_pollgen() c_uint {
        return 0;
    }
    fn h9_pollwake() void {}
    fn h9_futex_wait(_: *const anyopaque, _: u64, _: *u32, _: u32, _: u32, _: c_int) c_int {
        return 1;
    }
    fn h9_futex_wake(_: *const anyopaque, _: u64, _: c_int, _: u32, _: u64, _: c_int, _: ?*u32, _: u32) c_int {
        return 0;
    }
    fn h9_linux_sockrecv(_: c_int, _: [*]u8, _: c_int, _: c_int, _: c_int, _: ?*[16]u8, _: ?*u16) c_int {
        return -9;
    }
    fn h9_linux_socksend(_: c_int, _: [*]const u8, _: c_int, _: c_int, _: ?*const [16]u8, _: u16) c_int {
        return -9;
    }
    fn h9_linux_soerror(_: c_int) c_int {
        return 9;
    }
    fn h9_linux_pipequeued(_: c_int) c_long {
        return -1;
    }
    fn h9_linux_sockctl(_: c_int, _: [*:0]const u8) c_int {
        return -1;
    }
    fn h9_linux_rattach(_: c_int, _: c_int, _: c_int, _: c_int, _: c_int) c_int {
        return -1;
    }
    fn h9_linux_rconvid(_: c_int) c_int {
        return -1;
    }
    fn h9_linux_rclose(_: c_int) void {}
    fn h9_linux_raccept(_: c_int, _: c_int) c_int {
        return -9;
    }
    fn h9_linux_syncfs(_: c_int) c_int {
        return -1;
    }
    fn h9_linux_sync() c_int {
        return -1;
    }
    fn h9_pty_get(_: c_int, _: *PtyState) c_int {
        return -1;
    }
    fn h9_pty_set(_: c_int, _: *const PtyState, _: c_int, _: c_int) c_int {
        return -1;
    }
    fn h9_pty_bysid(_: c_ulong) c_int {
        return -1;
    }
    fn h9_pty_queued(_: c_int, _: c_int, _: c_int) c_long {
        return -1;
    }
    fn h9_pty_sethup(_: PtyHup) void {}
};

/// A pty pair's state (src/kern/devpty.c's Ptystate): the termios as
/// the personality keeps it, the window size (rows, cols, xpixel,
/// ypixel), the foreground group and session (0 for none), the lock,
/// and, read only, the pair's number, whether the fd is its master, and
/// whether the slave is open.
pub const PtyState = extern struct {
    termios: [60]u8 = @splat(0),
    winsz: [4]u16 = @splat(0),
    fg: u32 = 0,
    sid: u32 = 0,
    locked: c_int = 0,
    n: c_int = 0,
    master: c_int = 0,
    slaveopen: c_int = 0,

    pub const termios_bit = 1 << 0;
    pub const winsz_bit = 1 << 1;
    pub const fg_bit = 1 << 2;
    pub const sid_bit = 1 << 3;
    pub const lock_bit = 1 << 4;
};

/// devpty's hangup hook: posts SIGHUP to group `fg` of the caller's
/// machine once a master's last close hangs its pair up.
pub const PtyHup = *const fn (fg: c_ulong, sid: c_ulong) callconv(.c) void;

/// The state of the pty pair fd is a side of, or null if it isn't one.
pub fn ptyGet(fd: i32) ?PtyState {
    var s: PtyState = .{};
    if (c.h9_pty_get(fd, &s) < 0) return null;
    return s;
}

pub const PtySet = enum { set, if_free };

/// Sets the fields `what` names (PtyState's bits) of fd's pair. With
/// `.if_free`, only if the pair is no session's terminal: false when it
/// was. error.Kern if fd isn't a pty.
pub fn ptySet(fd: i32, s: *const PtyState, what: c_int, mode: PtySet) Error!bool {
    const r = c.h9_pty_set(fd, s, what, @intFromBool(mode == .if_free));
    if (r < 0) return error.Kern;
    return r == 0;
}

/// The number of the caller's machine's pty that's session sid's
/// controlling terminal, or null.
pub fn ptyBySid(sid: u32) ?u32 {
    const r = c.h9_pty_bysid(sid);
    return if (r < 0) null else @intCast(r);
}

/// Bytes queued to read on pty fd (`.read`), or written and not read
/// yet (`.write`); null if fd isn't a pty. `ptyFlush` drops them.
pub fn ptyQueued(fd: i32, dir: enum { read, write }) ?u32 {
    const r = c.h9_pty_queued(fd, @intFromBool(dir == .write), 0);
    return if (r < 0) null else @intCast(r);
}

pub fn ptyFlush(fd: i32, dir: enum { read, write }) void {
    _ = c.h9_pty_queued(fd, @intFromBool(dir == .write), 1);
}

pub fn setPtyHup(f: PtyHup) void {
    c.h9_pty_sethup(f);
}

/// Linux's struct pollfd, which h9_poll fills in (src/kern/linuxnet.c).
pub const PollFd = extern struct { fd: i32, events: i16, revents: i16 };

pub const POLLIN = 1;
pub const POLLPRI = 2;
pub const POLLOUT = 4;
pub const POLLERR = 8;
pub const POLLHUP = 0x10;
pub const POLLNVAL = 0x20;
pub const POLLRDHUP = 0x2000;

/// Fills in each revents and returns how many fds are ready, sleeping up
/// to `ms` (-1 forever, 0 not at all) until one is. `gen` gets the wake
/// generation the answer is for (for edge-triggered epoll). error.Kern
/// when a note interrupts it.
pub fn poll(pfds: []PollFd, ms: i64, gen: ?*u64) Error!usize {
    var g: c_uint = 0;
    const r = c.h9_poll(pfds.ptr, @intCast(pfds.len), @intCast(@max(-1, @min(ms, std.math.maxInt(c_int)))), &g, 0);
    if (gen) |p| p.* = g;
    return try check(r);
}

/// Like poll, but returns 0 after the first wake (anything that may have
/// changed readiness) instead of asking again.
pub fn pollOnce(pfds: []PollFd, ms: i64) Error!usize {
    return try check(c.h9_poll(pfds.ptr, @intCast(pfds.len), @intCast(@max(-1, @min(ms, std.math.maxInt(c_int)))), null, 1));
}

/// The poll bits ready on fd now, or null if it isn't open.
pub fn fdReady(fd: i32, events: u32) ?u32 {
    const r = c.h9_fdready(fd, @intCast(events));
    if (r < 0) return null;
    return @intCast(r);
}

pub const FutexWait = enum { woken, again, timed_out };

/// Waits on futex `addr` in the address space `key` while `word.*` is
/// `val`, for up to `ms` (-1: no limit). Interrupted by notes.
pub fn futexWait(key: *const anyopaque, addr: u64, word: *u32, val: u32, bitset: u32, ms: i64) Error!FutexWait {
    const lim: c_int = if (ms < 0) -1 else @intCast(@min(ms, std.math.maxInt(c_int)));
    return switch (c.h9_futex_wait(key, addr, word, val, bitset, lim)) {
        0 => .woken,
        1 => .again,
        2 => .timed_out,
        else => error.Kern,
    };
}

/// Wakes up to `n` waiters on `addr`, and requeues up to `nreq` more onto
/// `addr2`. With `cmp`, only if `cmp.word.*` is `cmp.val`, else null.
pub fn futexWake(key: *const anyopaque, addr: u64, n: u32, bitset: u32, addr2: u64, nreq: u32, cmp: ?struct { word: *u32, val: u32 }) ?u32 {
    const r = c.h9_futex_wake(key, addr, @intCast(@min(n, std.math.maxInt(c_int))), bitset, addr2, @intCast(@min(nreq, std.math.maxInt(c_int))), if (cmp) |x| x.word else null, if (cmp) |x| x.val else 0);
    return if (r < 0) null else @intCast(r);
}

/// Wakes every poll, select and epoll_wait, to look again.
pub fn pollWake() void {
    c.h9_pollwake();
}

pub fn pollGen() u64 {
    return c.h9_pollgen();
}

/// A devip address (16 bytes, v4 mapped) and port.
pub const NetAddr = struct { ip: [16]u8 = @splat(0), port: u16 = 0 };

/// recvfrom on a socket fd's host socket, with Linux's MSG_PEEK and
/// MSG_DONTWAIT: the count or -errno. `from` gets the source.
pub fn sockRecv(fd: i32, buf: []u8, peek: bool, dontwait: bool, from: ?*NetAddr) i64 {
    const n: c_int = @intCast(@min(buf.len, 1 << 30));
    if (from) |f| return c.h9_linux_sockrecv(fd, buf.ptr, n, @intFromBool(peek), @intFromBool(dontwait), &f.ip, &f.port);
    return c.h9_linux_sockrecv(fd, buf.ptr, n, @intFromBool(peek), @intFromBool(dontwait), null, null);
}

/// sendto on a socket fd's host socket (to `to`, checked by the policy,
/// or to its peer): the count or -errno.
pub fn sockSend(fd: i32, buf: []const u8, dontwait: bool, to: ?*const NetAddr) i64 {
    const n: c_int = @intCast(@min(buf.len, 1 << 30));
    if (to) |t| return c.h9_linux_socksend(fd, buf.ptr, n, @intFromBool(dontwait), &t.ip, t.port);
    return c.h9_linux_socksend(fd, buf.ptr, n, @intFromBool(dontwait), null, 0);
}

/// SO_ERROR, as a Linux errno.
/// Bytes queued in the pipe that a write on pipe end `fd` goes into, or
/// -1 if fd isn't a pipe end.
pub fn pipeQueued(fd: i32) i64 {
    return c.h9_linux_pipequeued(fd);
}

pub fn soError(fd: i32) u32 {
    return @intCast(c.h9_linux_soerror(fd));
}

/// Attaches a conversation from a mounted /net (not devip's), open on
/// `data` and `ctl`, to the kernel's read-ahead (src/kern/linuxnet.c),
/// under the Linux layer's `id`. `open`: it's connected already.
pub fn rattach(data: i32, ctl: i32, id: u32, udp: bool, open: bool) Error!void {
    _ = try check(c.h9_linux_rattach(data, ctl, @intCast(id), @intFromBool(udp), @intFromBool(open)));
}

/// The id fd's mounted conversation was attached under, or null.
pub fn rconvId(fd: i32) ?u32 {
    const r = c.h9_linux_rconvid(fd);
    return if (r < 0) null else @intCast(r);
}

/// accept on a listening mounted conversation: a new fd for the waiting
/// call's ctl, or -errno (-EAGAIN when none waits yet).
pub fn raccept(fd: i32, cloexec: bool) i64 {
    return c.h9_linux_raccept(fd, @intFromBool(cloexec));
}

/// fd is closing: a mounted conversation goes with its description's
/// last fd.
pub fn rclose(fd: i32) void {
    c.h9_linux_rclose(fd);
}

/// Writes a control message to the conversation behind socket fd.
pub fn sockCtl(fd: i32, msg: [*:0]const u8) Error!void {
    _ = try check(c.h9_linux_sockctl(fd, msg));
}

pub fn setGen(f: Gen) void {
    c.h9_linux_setgen(f);
}

pub const Error = kern.Error;

fn check(r: c_int) Error!u31 {
    if (r < 0) return error.Kern;
    return @intCast(r);
}

/// Sets the calling process's root to the Linux view or the 9front one.
pub fn setSlash(linux: bool) Error!void {
    _ = try check(c.h9_linux_setslash(@intFromBool(linux)));
}

pub fn inView() bool {
    return c.h9_linux_inview() != 0;
}

/// Runs `f(args)` with fd's directory as dot, for a walk relative to it.
pub fn atDir(fd: i32, comptime T: type, f: anytype, args: anytype) Error!T {
    const old = c.h9_linux_dotfd(fd) orelse return error.Kern;
    defer c.h9_linux_dotrestore(old);
    return @call(.auto, f, args);
}

pub const FdInfo = struct {
    /// The device's character: 'M' for a 9P mount, '|' for a pipe, 'y'
    /// for the console, 'λ' for devlinux.
    dc: u21,
    /// The channel's device instance (a mount's, for 'M').
    dev: u64,
    qpath: u64,
    dir: bool,
    /// Plan 9 open mode: OREAD, OWRITE, ORDWR or OEXEC.
    mode: u2,
    cexec: bool,
};

pub fn fdInfo(fd: i32) Error!FdInfo {
    var dc: c_int = 0;
    var dev: c_uint = 0;
    var qp: u64 = 0;
    var qt: c_int = 0;
    var mode: c_int = 0;
    var ce: c_int = 0;
    _ = try check(c.h9_linux_fdinfo(fd, &dc, &dev, &qp, &qt, &mode, &ce));
    return .{ .dc = @intCast(@as(u32, @bitCast(dc)) & 0x1fffff), .dev = dev, .qpath = qp, .dir = qt & 0x80 != 0, .mode = @intCast(mode & 3), .cexec = ce != 0 };
}

/// syncfs(2): syncs the host file system behind fd's channel, if it's on
/// one (src/kern/linux.c).
pub fn syncfs(fd: i32) Error!void {
    _ = try check(c.h9_linux_syncfs(fd));
}

/// sync(2): syncs every host file system.
pub fn sync() Error!void {
    _ = try check(c.h9_linux_sync());
}

/// fd's open file description: an identity dup and fork share, and how
/// many other references it has. Null if fd isn't open.
pub fn fdChan(fd: i32) ?struct { id: usize, refs: u32 } {
    var refs: c_int = 0;
    const id = c.h9_linux_fdchan(fd, &refs);
    if (id == 0) return null;
    return .{ .id = id, .refs = @intCast(@max(refs, 0)) };
}

/// A reference to fd's channel that outlives the fd, for reading a file
/// after the guest closes it (`chanPread`); `chanPut` releases it. Null
/// if fd isn't open for reading.
pub fn chanGet(fd: i32) ?*anyopaque {
    return c.h9_linux_changet(fd);
}

/// Reads up to buf.len bytes at off from a `chanGet` channel: the count,
/// 0 at the end.
pub fn chanPread(ch: *anyopaque, buf: []u8, off: u64) Error!usize {
    const r = c.h9_linux_chanpread(ch, buf.ptr, @intCast(@min(buf.len, 1 << 30)), @intCast(off));
    if (r < 0) return error.Kern;
    return @intCast(r);
}

pub fn chanPut(ch: *anyopaque) void {
    c.h9_linux_chanput(ch);
}

/// One of the host's interface addresses (src/kern/hostsock.h's
/// H9ifaddr): `addr` is devip's 16 bytes, IPv4 mapped.
pub const IfAddr = extern struct {
    name: [16]u8,
    index: c_int,
    isup: c_int,
    loopback: c_int,
    mtu: c_int,
    addr: [16]u8,
    prefix: c_int,
};

/// The host's interface addresses, loopback included, into `buf`; none
/// where the host can't list them (Windows, the browser).
pub fn hostIfAddrs(buf: []IfAddr) []IfAddr {
    const n = c.h9so_ifaddrs(buf.ptr, @intCast(buf.len));
    return buf[0..@intCast(@max(n, 0))];
}

/// Whether the host can make IPv6 sockets (src/kern/hostsock.h).
pub fn hostHasV6() bool {
    return c.h9so_hasv6() != 0;
}

/// The calling process's CPU time for its wait record (wait4's rusage).
pub fn setCputime(user_ms: u64, sys_ms: u64) void {
    c.h9_linux_setcputime(@truncate(user_ms), @truncate(sys_ms));
}

pub fn setCloexec(fd: i32, on: bool) Error!void {
    _ = try check(c.h9_linux_setcexec(fd, @intFromBool(on)));
}

pub fn maxFd() i32 {
    return c.h9_linux_maxfd();
}

/// The open fds, into `buf`; returns how many there are.
pub fn fds(buf: []c_int) usize {
    return @intCast(c.h9_linux_fds(buf.ptr, @intCast(buf.len)));
}

/// await for child `want`, or any child when `want` <= 0; with `block`
/// false, 0 when no such child has exited yet. With `peek` the record
/// stays to be waited for again (WNOWAIT). A thread waits on its group
/// leader's children.
pub fn await(buf: []u8, block: bool, want: i32, peek: bool) Error!usize {
    return try check(c.h9_linux_await(buf.ptr, @intCast(buf.len), @intFromBool(block), want, @intFromBool(peek)));
}

pub fn ppid() u32 {
    return @intCast(c.h9_linux_ppid());
}

pub fn getcwd(buf: []u8) Error![]u8 {
    const n = try check(c.h9_linux_getcwd(buf.ptr, @intCast(buf.len)));
    return buf[0..n];
}

pub fn fchdir(fd: i32) Error!void {
    _ = try check(c.h9_linux_fchdir(fd));
}
