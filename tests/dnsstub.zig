//! A stub DNS server for the [linux-dns] cases (design/linux-dns.md), on
//! 127.0.0.1, over UDP and TCP on one port, with a few names it answers
//! and counts of the queries it saw; and a TCP service that writes
//! "hello\n" to each connection and counts them. POSIX hosts and Windows,
//! over `sock`, the few socket calls that differ between them.

const std = @import("std");
const builtin = @import("builtin");

pub const supported = builtin.os.tag != .wasi;

const windows = builtin.os.tag == .windows;

/// A socket: a descriptor, or on Windows a Winsock SOCKET.
const Fd = if (windows) usize else std.c.fd_t;
const none: Fd = if (windows) ~@as(usize, 0) else -1;

/// A name the stub answers: an A record, an AAAA record, or both, or a
/// CNAME to another name.
pub const Record = struct { name: []const u8, a: ?[4]u8 = null, aaaa: ?[16]u8 = null, cname: ?[]const u8 = null };

pub const Stub = struct {
    records: []const Record,
    /// Names whose UDP answers are truncated, with no records, so the
    /// client asks again over TCP.
    truncate: []const []const u8 = &.{},
    udp: Fd = none,
    tcp: Fd = none,
    port: u16 = 0,
    udp_queries: std.atomic.Value(u32) = .init(0),
    tcp_queries: std.atomic.Value(u32) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    ns_buf: [32]u8 = undefined,

    pub fn start(s: *Stub) !void {
        if (comptime !supported) return error.SkipZigTest;
        var tries: u32 = 0;
        while (true) : (tries += 1) {
            s.udp = try bindLoopback(.udp, 0);
            s.port = try portOf(s.udp);
            s.tcp = bindLoopback(.tcp, s.port) catch {
                sock.close(s.udp);
                if (tries > 20) return error.NoPort;
                continue;
            };
            break;
        }
        if (sock.listen(s.tcp) != 0) return error.Listen;
        s.thread = try std.Thread.spawn(.{}, loop, .{s});
    }

    pub fn stop(s: *Stub) void {
        s.stopping.store(true, .release);
        if (s.thread) |t| t.join();
        if (s.udp != none) sock.close(s.udp);
        if (s.tcp != none) sock.close(s.tcp);
    }

    /// `127.0.0.1!PORT`, as Machine.Options.nameservers and
    /// H9_TEST_NAMESERVERS take it.
    pub fn nameserver(s: *Stub) []const u8 {
        return std.fmt.bufPrint(&s.ns_buf, "127.0.0.1!{d}", .{s.port}) catch unreachable;
    }

    pub fn queries(s: *Stub) u32 {
        return s.udp_queries.load(.acquire) + s.tcp_queries.load(.acquire);
    }

    fn loop(s: *Stub) void {
        var q: [1024]u8 = undefined;
        var out: [2048]u8 = undefined;
        while (!s.stopping.load(.acquire)) {
            var ready: [2]bool = undefined;
            if (!sock.readable(&.{ s.udp, s.tcp }, 50, &ready)) continue;
            if (ready[0]) {
                var from: sock.Addr = undefined;
                const n = sock.recvFrom(s.udp, &q, &from);
                if (n > 0) {
                    _ = s.udp_queries.fetchAdd(1, .acq_rel);
                    const a = s.reply(q[0..@intCast(n)], true, &out);
                    sock.sendTo(s.udp, a, &from);
                }
            }
            if (ready[1]) {
                if (sock.accept(s.tcp)) |fd| {
                    s.serveTcp(fd, &q, &out);
                    sock.close(fd);
                }
            }
        }
    }

    fn serveTcp(s: *Stub, fd: Fd, q: []u8, out: []u8) void {
        while (true) {
            var lb: [2]u8 = undefined;
            if (!readFull(fd, &lb)) return;
            const n = std.mem.readInt(u16, &lb, .big);
            if (n > q.len or !readFull(fd, q[0..n])) return;
            _ = s.tcp_queries.fetchAdd(1, .acq_rel);
            const a = s.reply(q[0..n], false, out[2..]);
            std.mem.writeInt(u16, out[0..2], @intCast(a.len), .big);
            sock.send(fd, out[0 .. a.len + 2]);
        }
    }

    fn find(s: *Stub, name: []const u8) ?Record {
        for (s.records) |r| if (std.ascii.eqlIgnoreCase(r.name, name)) return r;
        return null;
    }

    /// The answer to query `q`: the name's CNAMEs, and its A record for an
    /// A query or its AAAA record for an AAAA query, nothing for another
    /// type, and NXDOMAIN for a name it doesn't know.
    fn reply(s: *Stub, q: []const u8, udp: bool, out: []u8) []const u8 {
        if (q.len < 17) return out[0..0];
        var i: usize = 12;
        while (i < q.len and q[i] != 0) i += 1 + q[i];
        const qend = i + 5;
        if (qend > q.len) return out[0..0];
        var nb: [256]u8 = undefined;
        const name = dotted(q[12 .. i + 1], &nb);
        const qtype = std.mem.readInt(u16, q[i + 1 ..][0..2], .big);
        @memcpy(out[0..qend], q[0..qend]);
        out[2] = 0x81;
        out[3] = 0x80;
        @memset(out[6..12], 0);
        var n = qend;
        if (udp) for (s.truncate) |t| if (std.ascii.eqlIgnoreCase(t, name)) {
            out[2] |= 0x02;
            return out[0..n];
        };
        var cur = name;
        var an: u16 = 0;
        var hops: u32 = 0;
        while (hops < 8) : (hops += 1) {
            const r = s.find(cur) orelse {
                if (an == 0) out[3] = 0x83;
                break;
            };
            if (r.cname) |target| {
                var tb: [256]u8 = undefined;
                n = rr(out, n, cur, 5, wire(target, &tb));
                an += 1;
                cur = target;
                continue;
            }
            if (qtype == 1) if (r.a) |a| {
                n = rr(out, n, cur, 1, &a);
                an += 1;
            };
            if (qtype == 28) if (r.aaaa) |a| {
                n = rr(out, n, cur, 28, &a);
                an += 1;
            };
            break;
        }
        std.mem.writeInt(u16, out[6..8], an, .big);
        return out[0..n];
    }
};

fn rr(out: []u8, off: usize, owner: []const u8, rtype: u16, data: []const u8) usize {
    var wb: [256]u8 = undefined;
    const w = wire(owner, &wb);
    var n = off;
    @memcpy(out[n..][0..w.len], w);
    n += w.len;
    std.mem.writeInt(u16, out[n..][0..2], rtype, .big);
    std.mem.writeInt(u16, out[n + 2 ..][0..2], 1, .big);
    std.mem.writeInt(u32, out[n + 4 ..][0..4], 60, .big);
    std.mem.writeInt(u16, out[n + 8 ..][0..2], @intCast(data.len), .big);
    n += 10;
    @memcpy(out[n..][0..data.len], data);
    return n + data.len;
}

fn wire(name: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |l| {
        buf[n] = @intCast(l.len);
        @memcpy(buf[n + 1 ..][0..l.len], l);
        n += 1 + l.len;
    }
    buf[n] = 0;
    return buf[0 .. n + 1];
}

fn dotted(w: []const u8, buf: []u8) []const u8 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < w.len and w[i] != 0) {
        const l = w[i];
        if (n > 0) {
            buf[n] = '.';
            n += 1;
        }
        @memcpy(buf[n..][0..l], w[i + 1 ..][0..l]);
        n += l;
        i += 1 + l;
    }
    return buf[0..n];
}

fn readFull(fd: Fd, buf: []u8) bool {
    var got: usize = 0;
    while (got < buf.len) {
        var ready: [1]bool = undefined;
        if (!sock.readable(&.{fd}, 5000, &ready)) return false;
        const n = sock.recv(fd, buf[got..]);
        if (n <= 0) return false;
        got += @intCast(n);
    }
    return true;
}

fn bindLoopback(kind: enum { udp, tcp }, port: u16) !Fd {
    const fd = sock.socket(if (kind == .udp) sock.SOCK.DGRAM else sock.SOCK.STREAM) orelse return error.Socket;
    errdefer sock.close(fd);
    const sa: sock.Addr = .{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (sock.bind(fd, &sa) != 0) return error.Bind;
    return fd;
}

fn portOf(fd: Fd) !u16 {
    var sa: sock.Addr = undefined;
    if (sock.getsockname(fd, &sa) != 0) return error.Sockname;
    return std.mem.bigToNative(u16, sa.port);
}

/// Whether the host has a route to IPv6 address `addr`: a UDP connect to
/// it works, as getaddrinfo's ranking probe asks. False without IPv6.
pub fn routes6(addr: [16]u8) bool {
    if (comptime !supported) return false;
    return sock.routes6(addr);
}

/// A TCP service on 127.0.0.1 that writes "hello\n" to each connection.
pub const Service = struct {
    fd: Fd = none,
    port: u16 = 0,
    conns: std.atomic.Value(u32) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    pub fn start(s: *Service) !void {
        if (comptime !supported) return error.SkipZigTest;
        s.fd = try bindLoopback(.tcp, 0);
        s.port = try portOf(s.fd);
        if (sock.listen(s.fd) != 0) return error.Listen;
        s.thread = try std.Thread.spawn(.{}, loop, .{s});
    }

    pub fn stop(s: *Service) void {
        s.stopping.store(true, .release);
        if (s.thread) |t| t.join();
        if (s.fd != none) sock.close(s.fd);
    }

    fn loop(s: *Service) void {
        while (!s.stopping.load(.acquire)) {
            var ready: [1]bool = undefined;
            if (!sock.readable(&.{s.fd}, 50, &ready)) continue;
            const fd = sock.accept(s.fd) orelse continue;
            _ = s.conns.fetchAdd(1, .acq_rel);
            sock.send(fd, "hello\n");
            sock.close(fd);
        }
    }
};

/// The stub's socket calls on this host, IPv4 but for routes6. They
/// differ in the socket type, and in how sockets are waited for: poll
/// here, select on Windows.
const sock = if (windows) winsock else posix;

const posix = struct {
    const c = std.c;
    const SOCK = c.SOCK;
    const Addr = c.sockaddr.in;

    fn socket(kind: c_uint) ?Fd {
        const fd = c.socket(c.AF.INET, kind, 0);
        return if (fd < 0) null else fd;
    }
    fn bind(fd: Fd, sa: *const Addr) c_int {
        return c.bind(fd, @ptrCast(sa), @sizeOf(Addr));
    }
    fn getsockname(fd: Fd, sa: *Addr) c_int {
        var sl: c.socklen_t = @sizeOf(Addr);
        return c.getsockname(fd, @ptrCast(sa), &sl);
    }
    fn listen(fd: Fd) c_int {
        return c.listen(fd, 16);
    }
    fn accept(fd: Fd) ?Fd {
        const nfd = c.accept(fd, null, null);
        return if (nfd < 0) null else nfd;
    }
    fn recvFrom(fd: Fd, buf: []u8, from: *Addr) isize {
        var sl: c.socklen_t = @sizeOf(Addr);
        return c.recvfrom(fd, buf.ptr, buf.len, 0, @ptrCast(from), &sl);
    }
    fn sendTo(fd: Fd, buf: []const u8, to: *const Addr) void {
        _ = c.sendto(fd, buf.ptr, buf.len, 0, @ptrCast(to), @sizeOf(Addr));
    }
    fn recv(fd: Fd, buf: []u8) isize {
        return c.recv(fd, buf.ptr, buf.len, 0);
    }
    fn send(fd: Fd, buf: []const u8) void {
        _ = c.send(fd, buf.ptr, buf.len, c.MSG.NOSIGNAL);
    }
    fn readable(fds: []const Fd, ms: c_int, ready: []bool) bool {
        var p: [2]c.pollfd = undefined;
        for (fds, p[0..fds.len]) |fd, *q| q.* = .{ .fd = fd, .events = c.POLL.IN, .revents = 0 };
        if (c.poll(&p, @intCast(fds.len), ms) <= 0) return false;
        for (ready[0..fds.len], p[0..fds.len]) |*r, q| r.* = q.revents != 0;
        return true;
    }
    fn close(fd: Fd) void {
        _ = c.close(fd);
    }
    fn routes6(addr: [16]u8) bool {
        const fd = c.socket(c.AF.INET6, c.SOCK.DGRAM, 0);
        if (fd < 0) return false;
        defer _ = c.close(fd);
        const sa: c.sockaddr.in6 = .{ .port = std.mem.nativeToBig(u16, 9), .flowinfo = 0, .addr = addr, .scope_id = 0 };
        return c.connect(fd, @ptrCast(&sa), @sizeOf(c.sockaddr.in6)) == 0;
    }
};

const winsock = struct {
    const ws2 = std.os.windows.ws2_32;
    const SOCK = ws2.SOCK;
    const Addr = ws2.sockaddr.in;
    const fd_set = extern struct { count: c_uint, array: [64]usize };
    const timeval = extern struct { sec: c_long, usec: c_long };

    const api = struct {
        extern "ws2_32" fn WSAStartup(version: u16, data: *anyopaque) callconv(.winapi) c_int;
        extern "ws2_32" fn WSASocketW(af: c_int, kind: c_int, proto: c_int, info: ?*anyopaque, g: u32, flags: u32) callconv(.winapi) usize;
        extern "ws2_32" fn closesocket(s: usize) callconv(.winapi) c_int;
        extern "ws2_32" fn bind(s: usize, sa: *const anyopaque, len: c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn listen(s: usize, backlog: c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn connect(s: usize, sa: *const anyopaque, len: c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn getsockname(s: usize, sa: *anyopaque, len: *c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn accept(s: usize, sa: ?*anyopaque, len: ?*c_int) callconv(.winapi) usize;
        extern "ws2_32" fn recvfrom(s: usize, buf: [*]u8, len: c_int, flags: c_int, sa: *anyopaque, salen: *c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn sendto(s: usize, buf: [*]const u8, len: c_int, flags: c_int, sa: *const anyopaque, salen: c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn recv(s: usize, buf: [*]u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn send(s: usize, buf: [*]const u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
        extern "ws2_32" fn select(n: c_int, r: ?*fd_set, w: ?*fd_set, e: ?*fd_set, tv: *const timeval) callconv(.winapi) c_int;
        extern "kernel32" fn SetHandleInformation(h: std.os.windows.HANDLE, mask: u32, flags: u32) callconv(.winapi) std.os.windows.BOOL;
    };

    var started: std.atomic.Value(bool) = .init(false);

    fn start() void {
        if (!started.load(.acquire)) {
            var data: [400]u8 align(8) = undefined;
            if (api.WSAStartup(0x0202, &data) == 0) started.store(true, .release);
        }
    }

    fn socket(kind: c_int) ?Fd {
        start();
        // Overlapped, as socket() makes them, and not inherited by the h9
        // the case runs, which would hold a connection open past close.
        const fd = api.WSASocketW(ws2.AF.INET, kind, 0, null, 0, 0x01 | 0x80);
        return if (fd == none) null else fd;
    }
    fn bind(fd: Fd, sa: *const Addr) c_int {
        return api.bind(fd, sa, @sizeOf(Addr));
    }
    fn getsockname(fd: Fd, sa: *Addr) c_int {
        var sl: c_int = @sizeOf(Addr);
        return api.getsockname(fd, sa, &sl);
    }
    fn listen(fd: Fd) c_int {
        return api.listen(fd, 16);
    }
    fn accept(fd: Fd) ?Fd {
        const nfd = api.accept(fd, null, null);
        if (nfd == none) return null;
        _ = api.SetHandleInformation(@ptrFromInt(nfd), 1, 0);
        return nfd;
    }
    fn recvFrom(fd: Fd, buf: []u8, from: *Addr) isize {
        var sl: c_int = @sizeOf(Addr);
        return api.recvfrom(fd, buf.ptr, @intCast(buf.len), 0, from, &sl);
    }
    fn sendTo(fd: Fd, buf: []const u8, to: *const Addr) void {
        _ = api.sendto(fd, buf.ptr, @intCast(buf.len), 0, to, @sizeOf(Addr));
    }
    fn recv(fd: Fd, buf: []u8) isize {
        return api.recv(fd, buf.ptr, @intCast(buf.len), 0);
    }
    fn send(fd: Fd, buf: []const u8) void {
        _ = api.send(fd, buf.ptr, @intCast(buf.len), 0);
    }
    fn readable(fds: []const Fd, ms: c_int, ready: []bool) bool {
        var set: fd_set = .{ .count = @intCast(fds.len), .array = undefined };
        @memcpy(set.array[0..fds.len], fds);
        const tv: timeval = .{ .sec = @divTrunc(ms, 1000), .usec = @rem(ms, 1000) * 1000 };
        if (api.select(0, &set, null, null, &tv) <= 0) return false;
        for (fds, ready[0..fds.len]) |fd, *r| {
            r.* = false;
            for (set.array[0..set.count]) |x| if (x == fd) {
                r.* = true;
            };
        }
        return true;
    }
    fn close(fd: Fd) void {
        _ = api.closesocket(fd);
    }
    fn routes6(addr: [16]u8) bool {
        start();
        const fd = api.WSASocketW(ws2.AF.INET6, SOCK.DGRAM, 0, null, 0, 0x01 | 0x80);
        if (fd == none) return false;
        defer close(fd);
        const sa: ws2.sockaddr.in6 = .{ .port = std.mem.nativeToBig(u16, 9), .flowinfo = 0, .addr = addr, .scope_id = 0 };
        return api.connect(fd, &sa, @sizeOf(ws2.sockaddr.in6)) == 0;
    }
};
