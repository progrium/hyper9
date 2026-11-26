//! A stub DNS server for the [linux-dns] cases (design/linux-dns.md), on
//! 127.0.0.1, over UDP and TCP on one port, with a few names it answers
//! and counts of the queries it saw; and a TCP service that writes
//! "hello\n" to each connection and counts them. POSIX hosts only.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

pub const supported = builtin.os.tag != .windows;

/// A socket. Windows has no stub (start skips there), but the cases that
/// use one still compile, so the type can't be std.c.fd_t, which is a
/// HANDLE on Windows.
const Fd = if (supported) c.fd_t else i32;

fn closeFd(fd: Fd) void {
    if (supported) _ = c.close(fd);
}

/// A name the stub answers: an A record, or a CNAME to another name.
pub const Record = struct { name: []const u8, a: ?[4]u8 = null, cname: ?[]const u8 = null };

pub const Stub = struct {
    records: []const Record,
    /// Names whose UDP answers are truncated, with no records, so the
    /// client asks again over TCP.
    truncate: []const []const u8 = &.{},
    udp: Fd = -1,
    tcp: Fd = -1,
    port: u16 = 0,
    udp_queries: std.atomic.Value(u32) = .init(0),
    tcp_queries: std.atomic.Value(u32) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    ns_buf: [32]u8 = undefined,

    pub fn start(s: *Stub) !void {
        if (comptime !supported) return error.SkipZigTest else return s.startPosix();
    }

    fn startPosix(s: *Stub) !void {
        var tries: u32 = 0;
        while (true) : (tries += 1) {
            s.udp = try bindLoopback(c.SOCK.DGRAM, 0);
            s.port = try portOf(s.udp);
            s.tcp = bindLoopback(c.SOCK.STREAM, s.port) catch {
                _ = c.close(s.udp);
                if (tries > 20) return error.NoPort;
                continue;
            };
            break;
        }
        if (c.listen(s.tcp, 16) != 0) return error.Listen;
        s.thread = try std.Thread.spawn(.{}, loop, .{s});
    }

    pub fn stop(s: *Stub) void {
        s.stopping.store(true, .release);
        if (s.thread) |t| t.join();
        closeFd(s.udp);
        closeFd(s.tcp);
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
            var fds = [_]c.pollfd{
                .{ .fd = s.udp, .events = c.POLL.IN, .revents = 0 },
                .{ .fd = s.tcp, .events = c.POLL.IN, .revents = 0 },
            };
            if (c.poll(&fds, 2, 50) <= 0) continue;
            if (fds[0].revents & c.POLL.IN != 0) {
                var sa: c.sockaddr.in = undefined;
                var sl: c.socklen_t = @sizeOf(c.sockaddr.in);
                const n = c.recvfrom(s.udp, &q, q.len, 0, @ptrCast(&sa), &sl);
                if (n > 0) {
                    _ = s.udp_queries.fetchAdd(1, .acq_rel);
                    const a = s.reply(q[0..@intCast(n)], true, &out);
                    _ = c.sendto(s.udp, a.ptr, a.len, 0, @ptrCast(&sa), sl);
                }
            }
            if (fds[1].revents & c.POLL.IN != 0) {
                const fd = c.accept(s.tcp, null, null);
                if (fd >= 0) {
                    s.serveTcp(fd, &q, &out);
                    _ = c.close(fd);
                }
            }
        }
    }

    fn serveTcp(s: *Stub, fd: c.fd_t, q: []u8, out: []u8) void {
        while (true) {
            var lb: [2]u8 = undefined;
            if (!readFull(fd, &lb)) return;
            const n = std.mem.readInt(u16, &lb, .big);
            if (n > q.len or !readFull(fd, q[0..n])) return;
            _ = s.tcp_queries.fetchAdd(1, .acq_rel);
            const a = s.reply(q[0..n], false, out[2..]);
            std.mem.writeInt(u16, out[0..2], @intCast(a.len), .big);
            _ = c.write(fd, out.ptr, a.len + 2);
        }
    }

    fn find(s: *Stub, name: []const u8) ?Record {
        for (s.records) |r| if (std.ascii.eqlIgnoreCase(r.name, name)) return r;
        return null;
    }

    /// The answer to query `q`: the name's CNAMEs and A record for an A
    /// query, nothing for another type, and NXDOMAIN for a name it
    /// doesn't know.
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

fn readFull(fd: c.fd_t, buf: []u8) bool {
    var got: usize = 0;
    while (got < buf.len) {
        var fds = [_]c.pollfd{.{ .fd = fd, .events = c.POLL.IN, .revents = 0 }};
        if (c.poll(&fds, 1, 5000) <= 0) return false;
        const n = c.read(fd, buf[got..].ptr, buf.len - got);
        if (n <= 0) return false;
        got += @intCast(n);
    }
    return true;
}

fn bindLoopback(kind: c_uint, port: u16) !c.fd_t {
    const fd = c.socket(c.AF.INET, kind, 0);
    if (fd < 0) return error.Socket;
    errdefer _ = c.close(fd);
    var sa: c.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (c.bind(fd, @ptrCast(&sa), @sizeOf(c.sockaddr.in)) != 0) return error.Bind;
    return fd;
}

fn portOf(fd: c.fd_t) !u16 {
    var sa: c.sockaddr.in = undefined;
    var sl: c.socklen_t = @sizeOf(c.sockaddr.in);
    if (c.getsockname(fd, @ptrCast(&sa), &sl) != 0) return error.Sockname;
    return std.mem.bigToNative(u16, sa.port);
}

/// A TCP service on 127.0.0.1 that writes "hello\n" to each connection.
pub const Service = struct {
    fd: Fd = -1,
    port: u16 = 0,
    conns: std.atomic.Value(u32) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    pub fn start(s: *Service) !void {
        if (comptime !supported) return error.SkipZigTest else return s.startPosix();
    }

    fn startPosix(s: *Service) !void {
        s.fd = try bindLoopback(c.SOCK.STREAM, 0);
        s.port = try portOf(s.fd);
        if (c.listen(s.fd, 16) != 0) return error.Listen;
        s.thread = try std.Thread.spawn(.{}, loop, .{s});
    }

    pub fn stop(s: *Service) void {
        s.stopping.store(true, .release);
        if (s.thread) |t| t.join();
        closeFd(s.fd);
    }

    fn loop(s: *Service) void {
        while (!s.stopping.load(.acquire)) {
            var fds = [_]c.pollfd{.{ .fd = s.fd, .events = c.POLL.IN, .revents = 0 }};
            if (c.poll(&fds, 1, 50) <= 0) continue;
            const fd = c.accept(s.fd, null, null);
            if (fd < 0) continue;
            _ = s.conns.fetchAdd(1, .acq_rel);
            _ = c.write(fd, "hello\n", 6);
            _ = c.close(fd);
        }
    }
};
