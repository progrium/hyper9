//! The host's sockets (design/host-handles.md, "Network"): what the
//! dialer and the listener a plan describes make (src/host/planned.zig),
//! for connections h9 makes itself, such as the machine's resolver's
//! (src/resolver.zig, design/linux-dns.md). Each call is written once,
//! over `sys`, the socket calls of this host: POSIX sockets, or Winsock.
//! The guest's own sockets are devip's, which asks the same dialer and
//! listener whether each may be made.

const std = @import("std");
const builtin = @import("builtin");
const policy = @import("../policy.zig");
const web = @import("../web.zig");

/// Whether this host has sockets of its own: POSIX hosts and Windows,
/// not the web host, whose network is WebSockets.
pub const supported = !web.enabled and builtin.os.tag != .wasi;

const windows = builtin.os.tag == .windows;

pub const Transport = enum { udp, tcp };

/// A host socket: a descriptor, or on Windows a Winsock SOCKET.
pub const Fd = if (!supported) c_int else if (windows) usize else std.c.fd_t;

/// No socket.
pub const none: Fd = sys.invalid;
pub const Listener = struct { fd: Fd = none, port: u16 = 0 };
/// A peer's address, as devip keeps it, and port.
pub const Peer = struct { addr: [16]u8, port: u16, sa: Sockaddr, len: sys.socklen_t };
/// What `wait` waits for: data to read, or room to write (which is
/// also how a non-blocking connect ends).
pub const in: i16 = 1;
pub const out: i16 = 2;

const Sockaddr = extern union { any: sys.sockaddr, in: sys.sockaddr.in, in6: sys.sockaddr.in6 };

pub const loopback: [16]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 127, 0, 0, 1 };

/// Opens a socket on `addr!port`, devip's 16 bytes, on a port the host
/// picks for port 0: bound for UDP, listening for TCP. Close-on-exec (on
/// Windows, not inheritable), so a host program h9 runs doesn't inherit
/// it, and on Windows exclusive, so no other process can bind its port.
pub fn listen(kind: Transport, addr: *const [16]u8, port: u16) ?Listener {
    var sa: Sockaddr = undefined;
    const sl = toSockaddr(addr, port, &sa);
    const fam: c_int = if (sl == @sizeOf(sys.sockaddr.in)) sys.AF.INET else sys.AF.INET6;
    const fd = sys.socket(fam, if (kind == .udp) sys.SOCK.DGRAM else sys.SOCK.STREAM) orelse return null;
    sys.exclusive(fd);
    if (sys.bind(fd, &sa.any, sl) != 0 or (kind == .tcp and sys.listen(fd, 64) != 0)) {
        close(fd);
        return null;
    }
    if (kind == .udp) sys.noUdpReset(fd);
    var p: Peer = .{ .addr = undefined, .port = 0, .sa = undefined, .len = @sizeOf(Sockaddr) };
    if (sys.getsockname(fd, &p.sa.any, &p.len) != 0) {
        close(fd);
        return null;
    }
    fromSockaddr(&p);
    return .{ .fd = fd, .port = p.port };
}

/// Dials `addr!port` by `until` (monotonic ms).
pub fn dial(kind: Transport, addr: *const [16]u8, port: u16, until: i64) ?Fd {
    var sa: Sockaddr = undefined;
    const len = toSockaddr(addr, port, &sa);
    const fam: c_int = if (len == @sizeOf(sys.sockaddr.in)) sys.AF.INET else sys.AF.INET6;
    const fd = sys.socket(fam, if (kind == .udp) sys.SOCK.DGRAM else sys.SOCK.STREAM) orelse return null;
    sys.nonblock(fd);
    if (sys.connect(fd, &sa.any, len) == 0) return fd;
    if (!sys.inProgress() or !wait(fd, out, until - monoMs()) or sys.soError(fd) != 0) {
        close(fd);
        return null;
    }
    return fd;
}

pub fn recvFrom(fd: Fd, buf: []u8, from: *Peer) ?usize {
    from.len = @sizeOf(Sockaddr);
    const n = sys.recvfrom(fd, buf, &from.sa.any, &from.len);
    if (n < 0) return null;
    fromSockaddr(from);
    return @intCast(n);
}

pub fn sendTo(fd: Fd, buf: []const u8, to: Peer) void {
    _ = sys.sendto(fd, buf, &to.sa.any, to.len);
}

pub fn accept(fd: Fd, from: *Peer) ?Fd {
    from.len = @sizeOf(Sockaddr);
    const nfd = sys.accept(fd, &from.sa.any, &from.len) orelse return null;
    fromSockaddr(from);
    return nfd;
}

pub fn read(fd: Fd, buf: []u8) ?usize {
    const n = sys.recv(fd, buf);
    return if (n < 0) null else @intCast(n);
}

pub fn writeAll(fd: Fd, buf: []const u8, until: i64) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const n = sys.send(fd, buf[off..]);
        if (n < 0) {
            if (!sys.wouldBlock() or !wait(fd, out, until - monoMs())) return false;
            continue;
        }
        off += @intCast(n);
    }
    return true;
}

/// Whether fd is ready for `events` (`in` or `out`) within `ms`.
pub fn wait(fd: Fd, events: i16, ms: i64) bool {
    if (ms <= 0) return false;
    var ready: [1]bool = undefined;
    return sys.wait(&.{fd}, events, @intCast(@min(ms, 60_000)), &ready);
}

/// Whether any of `fds` (at most 8) has data to read within `ms`;
/// `ready` says which.
pub fn readable(fds: []const Fd, ms: i64, ready: []bool) bool {
    return sys.wait(fds, in, @intCast(@min(@max(ms, 0), 60_000)), ready);
}

pub fn close(fd: Fd) void {
    if (fd != none) sys.close(fd);
}

fn toSockaddr(addr: *const [16]u8, p: u16, sa: *Sockaddr) sys.socklen_t {
    if (policy.isV4(addr)) {
        sa.* = .{ .in = .{ .port = std.mem.nativeToBig(u16, p), .addr = @bitCast(addr[12..16].*) } };
        return @sizeOf(sys.sockaddr.in);
    }
    sa.* = .{ .in6 = .{ .port = std.mem.nativeToBig(u16, p), .flowinfo = 0, .addr = addr.*, .scope_id = 0 } };
    return @sizeOf(sys.sockaddr.in6);
}

fn fromSockaddr(p: *Peer) void {
    p.addr = @splat(0);
    if (p.sa.any.family == sys.AF.INET) {
        p.addr[10] = 0xff;
        p.addr[11] = 0xff;
        p.addr[12..16].* = @bitCast(p.sa.in.addr);
        p.port = std.mem.bigToNative(u16, p.sa.in.port);
    } else {
        p.addr = p.sa.in6.addr;
        p.port = std.mem.bigToNative(u16, p.sa.in6.port);
    }
}

pub fn monoMs() i64 {
    if (windows) return @intCast(winsock.api.GetTickCount64());
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

pub fn sleepMs(ms: u32) void {
    if (windows) return winsock.api.Sleep(ms);
    var ts: std.c.timespec = .{ .sec = 0, .nsec = @as(c_long, ms) * 1_000_000 };
    _ = std.c.nanosleep(&ts, null);
}

/// The socket calls this file makes, on this host. The two differ only
/// where the hosts do: how a socket is kept from child processes and
/// made non-blocking (after socket(), not in its type, which Darwin's
/// doesn't take), the error that means "not yet", and how a socket is
/// waited for.
const sys = if (windows) winsock else posix;

const posix = struct {
    const c = std.c;
    const AF = c.AF;
    const SOCK = c.SOCK;
    const sockaddr = c.sockaddr;
    const socklen_t = c.socklen_t;
    const invalid: Fd = -1;

    fn socket(fam: c_int, st: c_int) ?Fd {
        const fd = c.socket(@intCast(fam), @intCast(st), 0);
        if (fd < 0) return null;
        _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
        return fd;
    }
    fn nonblock(fd: Fd) void {
        _ = c.fcntl(fd, c.F.SETFL, c.fcntl(fd, c.F.GETFL) | @as(c_int, @bitCast(c.O{ .NONBLOCK = true })));
    }
    fn exclusive(_: Fd) void {}
    fn noUdpReset(_: Fd) void {}
    fn bind(fd: Fd, sa: *const sockaddr, len: socklen_t) c_int {
        return c.bind(fd, sa, len);
    }
    fn listen(fd: Fd, backlog: c_int) c_int {
        return c.listen(fd, @intCast(backlog));
    }
    fn getsockname(fd: Fd, sa: *sockaddr, len: *socklen_t) c_int {
        return c.getsockname(fd, sa, len);
    }
    fn connect(fd: Fd, sa: *const sockaddr, len: socklen_t) c_int {
        return c.connect(fd, sa, len);
    }
    fn inProgress() bool {
        return std.posix.errno(-1) == .INPROGRESS;
    }
    fn wouldBlock() bool {
        return std.posix.errno(-1) == .AGAIN;
    }
    fn soError(fd: Fd) c_int {
        var err: c_int = 0;
        var el: socklen_t = @sizeOf(c_int);
        if (c.getsockopt(fd, c.SOL.SOCKET, c.SO.ERROR, @ptrCast(&err), &el) != 0) return -1;
        return err;
    }
    fn accept(fd: Fd, sa: *sockaddr, len: *socklen_t) ?Fd {
        const nfd = c.accept(fd, sa, len);
        if (nfd < 0) return null;
        _ = c.fcntl(nfd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
        return nfd;
    }
    fn recvfrom(fd: Fd, buf: []u8, sa: *sockaddr, len: *socklen_t) isize {
        return c.recvfrom(fd, buf.ptr, buf.len, 0, sa, len);
    }
    fn sendto(fd: Fd, buf: []const u8, sa: *const sockaddr, len: socklen_t) isize {
        return c.sendto(fd, buf.ptr, buf.len, 0, sa, len);
    }
    fn recv(fd: Fd, buf: []u8) isize {
        return c.recv(fd, buf.ptr, buf.len, 0);
    }
    fn send(fd: Fd, buf: []const u8) isize {
        return c.send(fd, buf.ptr, buf.len, c.MSG.NOSIGNAL);
    }
    fn wait(fds: []const Fd, events: i16, ms: c_int, ready: []bool) bool {
        var p: [8]c.pollfd = undefined;
        const ev: i16 = if (events == in) c.POLL.IN else c.POLL.OUT;
        for (fds, p[0..fds.len]) |fd, *q| q.* = .{ .fd = fd, .events = ev, .revents = 0 };
        if (c.poll(&p, @intCast(fds.len), ms) <= 0) return false;
        for (ready[0..fds.len], p[0..fds.len]) |*r, q| r.* = q.revents != 0;
        return true;
    }
    fn close(fd: Fd) void {
        _ = c.close(fd);
    }
};

/// Winsock. A SOCKET is made with WSA_FLAG_NO_HANDLE_INHERIT, Windows's
/// close-on-exec, and waited for with select, which, unlike WSAPoll
/// before Windows 10 2004, reports a non-blocking connect that failed.
const winsock = struct {
    const ws2 = std.os.windows.ws2_32;
    const AF = ws2.AF;
    const SOCK = ws2.SOCK;
    const sockaddr = ws2.sockaddr;
    const socklen_t = c_int;
    const invalid: Fd = ~@as(usize, 0);

    const WSA_FLAG_OVERLAPPED = 0x01;
    const WSA_FLAG_NO_HANDLE_INHERIT = 0x80;
    const FIONBIO: c_int = @bitCast(@as(u32, 0x8004667e));
    const SIO_UDP_CONNRESET: u32 = 0x9800000c;
    const SOL_SOCKET: c_int = 0xffff;
    const SO_ERROR: c_int = 0x1007;
    /// ~SO_REUSEADDR.
    const SO_EXCLUSIVEADDRUSE: c_int = ~@as(c_int, 4);
    const WSAEWOULDBLOCK = 10035;
    const WSAEINPROGRESS = 10036;
    const HANDLE_FLAG_INHERIT = 1;

    const fd_set = extern struct { count: c_uint, array: [64]usize };
    const timeval = extern struct { sec: c_long, usec: c_long };

    const api = struct {
        const w = std.os.windows;
        extern "ws2_32" fn WSAStartup(version: u16, data: *anyopaque) callconv(.winapi) c_int;
        extern "ws2_32" fn WSASocketW(af: c_int, kind: c_int, proto: c_int, info: ?*anyopaque, g: u32, flags: u32) callconv(.winapi) usize;
        extern "ws2_32" fn closesocket(s: usize) callconv(.winapi) c_int;
        extern "ws2_32" fn ioctlsocket(s: usize, cmd: c_int, arg: *u32) callconv(.winapi) c_int;
        extern "ws2_32" fn WSAIoctl(s: usize, code: u32, in: ?*const anyopaque, inlen: u32, out: ?*anyopaque, outlen: u32, got: *u32, ov: ?*anyopaque, done: ?*anyopaque) callconv(.winapi) c_int;
        extern "ws2_32" fn setsockopt(s: usize, level: c_int, name: c_int, val: [*]const u8, len: c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn getsockopt(s: usize, level: c_int, name: c_int, val: [*]u8, len: *c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn bind(s: usize, sa: *const sockaddr, len: c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn listen(s: usize, backlog: c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn getsockname(s: usize, sa: *sockaddr, len: *c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn connect(s: usize, sa: *const sockaddr, len: c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn accept(s: usize, sa: *sockaddr, len: *c_int) callconv(.winapi) usize;
        extern "ws2_32" fn recvfrom(s: usize, buf: [*]u8, len: c_int, flags: c_int, sa: *sockaddr, salen: *c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn sendto(s: usize, buf: [*]const u8, len: c_int, flags: c_int, sa: *const sockaddr, salen: c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn recv(s: usize, buf: [*]u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn send(s: usize, buf: [*]const u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn select(n: c_int, r: ?*fd_set, wr: ?*fd_set, e: ?*fd_set, tv: *const timeval) callconv(.winapi) c_int;
        extern "ws2_32" fn WSAGetLastError() callconv(.winapi) c_int;
        extern "kernel32" fn SetHandleInformation(h: w.HANDLE, mask: u32, flags: u32) callconv(.winapi) w.BOOL;
        extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
        extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
    };

    var started: std.atomic.Value(bool) = .init(false);

    /// Starts Winsock for the process, once, before its first socket:
    /// the resolver may start before devip has.
    fn startup() void {
        if (started.load(.acquire)) return;
        var data: [400]u8 align(8) = undefined;
        if (api.WSAStartup(0x0202, &data) == 0) started.store(true, .release);
    }

    fn socket(fam: c_int, st: c_int) ?Fd {
        startup();
        const fd = api.WSASocketW(fam, st, 0, null, 0, WSA_FLAG_OVERLAPPED | WSA_FLAG_NO_HANDLE_INHERIT);
        return if (fd == none) null else fd;
    }
    fn nonblock(fd: Fd) void {
        var on: u32 = 1;
        _ = api.ioctlsocket(fd, FIONBIO, &on);
    }
    /// So no other process can bind the listener's port with
    /// SO_REUSEADDR and take the guest's queries.
    fn exclusive(fd: Fd) void {
        const on: c_int = 1;
        _ = api.setsockopt(fd, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, @ptrCast(&on), @sizeOf(c_int));
    }
    /// Without this, a reply to a guest port that has since closed makes
    /// the listener's next recvfrom fail with WSAECONNRESET.
    fn noUdpReset(fd: Fd) void {
        var off: u32 = 0;
        var got: u32 = 0;
        _ = api.WSAIoctl(fd, SIO_UDP_CONNRESET, &off, @sizeOf(u32), null, 0, &got, null, null);
    }
    fn bind(fd: Fd, sa: *const sockaddr, len: c_int) c_int {
        return api.bind(fd, sa, len);
    }
    fn listen(fd: Fd, backlog: c_int) c_int {
        return api.listen(fd, backlog);
    }
    fn getsockname(fd: Fd, sa: *sockaddr, len: *c_int) c_int {
        return api.getsockname(fd, sa, len);
    }
    fn connect(fd: Fd, sa: *const sockaddr, len: c_int) c_int {
        return api.connect(fd, sa, len);
    }
    fn inProgress() bool {
        const e = api.WSAGetLastError();
        return e == WSAEWOULDBLOCK or e == WSAEINPROGRESS;
    }
    fn wouldBlock() bool {
        return api.WSAGetLastError() == WSAEWOULDBLOCK;
    }
    fn soError(fd: Fd) c_int {
        var err: c_int = 0;
        var el: c_int = @sizeOf(c_int);
        if (api.getsockopt(fd, SOL_SOCKET, SO_ERROR, @ptrCast(&err), &el) != 0) return -1;
        return err;
    }
    fn accept(fd: Fd, sa: *sockaddr, len: *c_int) ?Fd {
        const nfd = api.accept(fd, sa, len);
        if (nfd == none) return null;
        _ = api.SetHandleInformation(@ptrFromInt(nfd), HANDLE_FLAG_INHERIT, 0);
        return nfd;
    }
    fn recvfrom(fd: Fd, buf: []u8, sa: *sockaddr, len: *c_int) isize {
        return api.recvfrom(fd, buf.ptr, clampLen(buf.len), 0, sa, len);
    }
    fn sendto(fd: Fd, buf: []const u8, sa: *const sockaddr, len: c_int) isize {
        return api.sendto(fd, buf.ptr, clampLen(buf.len), 0, sa, len);
    }
    fn recv(fd: Fd, buf: []u8) isize {
        return api.recv(fd, buf.ptr, clampLen(buf.len), 0);
    }
    fn send(fd: Fd, buf: []const u8) isize {
        return api.send(fd, buf.ptr, clampLen(buf.len), 0);
    }
    fn clampLen(n: usize) c_int {
        return @intCast(@min(n, std.math.maxInt(c_int)));
    }
    /// For `out`, a connect that failed is in select's exception set,
    /// and counts as ready, for SO_ERROR to say how it failed.
    fn wait(fds: []const Fd, events: i16, ms: c_int, ready: []bool) bool {
        var set: fd_set = .{ .count = @intCast(fds.len), .array = undefined };
        @memcpy(set.array[0..fds.len], fds);
        var ex = set;
        const tv: timeval = .{ .sec = @divTrunc(ms, 1000), .usec = @rem(ms, 1000) * 1000 };
        const n = if (events == in) api.select(0, &set, null, null, &tv) else api.select(0, null, &set, &ex, &tv);
        if (n <= 0) return false;
        for (fds, ready[0..fds.len]) |fd, *r| r.* = isSet(&set, fd) or (events == out and isSet(&ex, fd));
        return true;
    }
    fn isSet(set: *const fd_set, fd: Fd) bool {
        for (set.array[0..set.count]) |s| if (s == fd) return true;
        return false;
    }
    fn close(fd: Fd) void {
        _ = api.closesocket(fd);
    }
};
