//! The machine's resolver (design/linux-dns.md): under an allowlist with
//! a name pattern, every guest query to port 53 is redirected here, on
//! the host's loopback. A name no pattern covers gets REFUSED and goes
//! nowhere; the rest are forwarded to the machine's nameservers, and the
//! A and AAAA records answering the question are recorded in the
//! machine's resolved-name table before the guest sees them, so a later
//! connect to one of those addresses is allowed as it is after `cs`.
//!
//! One per machine, like the resolved-name table: `start` opens its
//! sockets and a thread that answers them, `stop` closes them. The host
//! sockets it uses are made in `HostNet` alone, so they can move onto
//! another way of reaching the host without touching the rest.
//!
//! devip tells the resolver the host port of each conversation it
//! redirects (`register`), with the address the guest dialled; answers
//! are recorded only for those ports, so another host process that finds
//! the loopback sockets can't add entries to the table.

const std = @import("std");
const builtin = @import("builtin");
const policy = @import("policy.zig");
const web = @import("web.zig");

/// Whether this host has the resolver. Elsewhere (Windows, the web host)
/// a machine that would resolve for the guest refuses port 53 instead.
pub const supported = builtin.os.tag != .windows and !web.enabled and builtin.os.tag != .wasi;

pub const Transport = enum { udp, tcp };

/// A host socket.
const Fd = if (supported) std.c.fd_t else c_int;

/// How long a forwarded query waits for the nameservers, all told.
pub const forward_timeout_ms = 5000;
/// How long the resolver keeps an idle TCP connection from the guest.
const tcp_idle_ms = 10_000;
/// Redirected conversations remembered at once; the oldest goes first.
const max_regs = 256;
/// Queries answered at once; more wait in the socket.
const max_workers = 64;

/// A nameserver: devip's 16-byte address and a port.
pub const Server = struct { addr: [16]u8, port: u16 = 53 };

/// Parses a nameserver, `ADDR` or `ADDR!PORT` (Machine.Options.nameservers).
pub fn parseServer(s: []const u8) ?Server {
    var host = s;
    var port: u16 = 53;
    if (std.mem.lastIndexOfScalar(u8, s, '!')) |bang| {
        host = s[0..bang];
        port = std.fmt.parseInt(u16, s[bang + 1 ..], 10) catch return null;
        if (port == 0) return null;
    }
    const a = policy.parseIp(host) orelse return null;
    return .{ .addr = a, .port = port };
}

/// The address part of a nameserver, for resolv.conf.
pub fn serverHost(s: []const u8) []const u8 {
    const bang = std.mem.lastIndexOfScalar(u8, s, '!') orelse return s;
    return s[0..bang];
}

/// 127.0.0.1, as devip keeps it.
pub const loopback: [16]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 127, 0, 0, 1 };

pub const Resolver = struct {
    gpa: std.mem.Allocator,
    /// The patterns that decide which names may be asked, and the table
    /// answers are recorded in: the machine's plan's.
    patterns: []const policy.NetPattern,
    names: *policy.NameTable,
    servers: []const Server,
    udp: HostNet.Listener = .{},
    tcp: HostNet.Listener = .{},
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    /// Query and connection threads still running.
    workers: std.atomic.Value(u32) = .init(0),
    lock: std.atomic.Mutex = .unlocked,
    regs: [max_regs]Reg = undefined,
    nregs: usize = 0,

    const Reg = struct { kind: Transport, lport: u16, orig: [16]u8, oport: u16 };

    /// Opens the resolver's sockets and starts answering them. `r` stays
    /// where it is until `stop` returns.
    pub fn start(r: *Resolver) !void {
        if (comptime !supported) return error.Unsupported;
        r.udp = try HostNet.listenLoopback(.udp);
        errdefer HostNet.close(r.udp.fd);
        r.tcp = try HostNet.listenLoopback(.tcp);
        errdefer HostNet.close(r.tcp.fd);
        r.thread = try std.Thread.spawn(.{}, loop, .{r});
    }

    /// Closes the sockets, and waits for the queries in flight (at most
    /// the forwarding timeout).
    pub fn stop(r: *Resolver) void {
        if (comptime !supported) return;
        r.stopping.store(true, .release);
        if (r.thread) |th| th.join();
        r.thread = null;
        HostNet.close(r.udp.fd);
        HostNet.close(r.tcp.fd);
        var waited: u32 = 0;
        while (r.workers.load(.acquire) > 0 and waited < forward_timeout_ms + tcp_idle_ms) : (waited += 10) sleepMs(10);
    }

    /// The loopback port that takes queries over `kind`.
    pub fn port(r: *const Resolver, kind: Transport) u16 {
        return if (kind == .udp) r.udp.port else r.tcp.port;
    }

    /// Records that the conversation on host port `lport` was redirected
    /// here from `orig!oport`, the address the guest dialled.
    pub fn register(r: *Resolver, kind: Transport, lport: u16, orig: *const [16]u8, oport: u16) void {
        r.acquire();
        defer r.lock.unlock();
        const n = @min(r.nregs, max_regs);
        for (r.regs[0..n]) |*g| if (g.kind == kind and g.lport == lport) {
            g.orig = orig.*;
            g.oport = oport;
            return;
        };
        r.regs[r.nregs % max_regs] = .{ .kind = kind, .lport = lport, .orig = orig.*, .oport = oport };
        r.nregs += 1;
    }

    /// The address the guest dialled from host port `lport`, if devip
    /// redirected it here.
    pub fn original(r: *Resolver, kind: Transport, lport: u16) ?Server {
        r.acquire();
        defer r.lock.unlock();
        const n = @min(r.nregs, max_regs);
        for (r.regs[0..n]) |*g| if (g.kind == kind and g.lport == lport) return .{ .addr = g.orig, .port = g.oport };
        return null;
    }

    /// Whether addr!p is one of the resolver's own sockets.
    pub fn isSelf(r: *const Resolver, kind: Transport, addr: *const [16]u8, p: u16) bool {
        return p != 0 and p == r.port(kind) and std.mem.eql(u8, addr, &loopback);
    }

    fn acquire(r: *Resolver) void {
        while (!r.lock.tryLock()) std.atomic.spinLoopHint();
    }

    /// Whether a pattern lets the guest ask for `name`: `h9_net_lookup`'s
    /// rule, for any protocol and port.
    pub fn allowsName(r: *const Resolver, name: []const u8) bool {
        for (r.patterns) |pat| {
            var p = pat;
            p.proto = null;
            p.port_lo = 0;
            p.port_hi = 65535;
            if (p.matchName(.tcp, name, 0)) return true;
        }
        return false;
    }

    /// Answers one query from host port `lport` into `out`, forwarding
    /// it over `kind` if its name is allowed; null drops it.
    pub fn answer(r: *Resolver, kind: Transport, query: []const u8, lport: u16, out: []u8) ?[]const u8 {
        var q: Question = undefined;
        parseQuery(query, &q) catch |e| return switch (e) {
            error.Short => null,
            error.Format => errorReply(query, null, rcode_formerr, out),
        };
        if (!r.allowsName(q.name())) return errorReply(query, &q, rcode_refused, out);
        const reply = r.forward(kind, query, out) orelse return errorReply(query, &q, rcode_servfail, out);
        if (r.original(kind, lport) != null) recordAnswer(reply, q.name(), r.names);
        return reply;
    }

    /// Sends `query` to the nameservers in order, each given its share
    /// of the time left; the first answer with the query's id wins.
    fn forward(r: *Resolver, kind: Transport, query: []const u8, out: []u8) ?[]const u8 {
        const deadline = monoMs() + forward_timeout_ms;
        for (r.servers, 0..) |srv, i| {
            const now = monoMs();
            if (now >= deadline) break;
            const share = @divTrunc(deadline - now, @as(i64, @intCast(r.servers.len - i)));
            const until = now + @max(share, 1);
            const got = switch (kind) {
                .udp => forwardUdp(srv, query, out, until),
                .tcp => forwardTcp(srv, query, out, until),
            };
            if (got) |a| return a;
        }
        return null;
    }

    fn loop(r: *Resolver) void {
        var buf: [65536]u8 = undefined;
        while (!r.stopping.load(.acquire)) {
            var fds = [_]std.c.pollfd{
                .{ .fd = r.udp.fd, .events = std.c.POLL.IN, .revents = 0 },
                .{ .fd = r.tcp.fd, .events = std.c.POLL.IN, .revents = 0 },
            };
            if (std.c.poll(&fds, fds.len, 100) <= 0) continue;
            if (fds[0].revents & std.c.POLL.IN != 0) {
                var from: HostNet.Peer = undefined;
                if (HostNet.recvFrom(r.udp.fd, &buf, &from)) |n| r.spawn(.udp, buf[0..n], from, -1);
            }
            if (fds[1].revents & std.c.POLL.IN != 0) {
                var from: HostNet.Peer = undefined;
                if (HostNet.accept(r.tcp.fd, &from)) |fd| r.spawn(.tcp, &.{}, from, fd);
            }
        }
    }

    const Work = struct {
        r: *Resolver,
        kind: Transport,
        from: HostNet.Peer,
        fd: Fd,
        len: usize,
        msg: [512]u8,
    };

    fn spawn(r: *Resolver, kind: Transport, msg: []const u8, from: HostNet.Peer, fd: Fd) void {
        if (msg.len > 512 or r.workers.load(.acquire) >= max_workers) {
            if (fd >= 0) HostNet.close(fd);
            return;
        }
        const w = r.gpa.create(Work) catch {
            if (fd >= 0) HostNet.close(fd);
            return;
        };
        w.* = .{ .r = r, .kind = kind, .from = from, .fd = fd, .len = msg.len, .msg = undefined };
        @memcpy(w.msg[0..msg.len], msg);
        _ = r.workers.fetchAdd(1, .acq_rel);
        const th = std.Thread.spawn(.{}, work, .{w}) catch {
            _ = r.workers.fetchSub(1, .acq_rel);
            if (fd >= 0) HostNet.close(fd);
            r.gpa.destroy(w);
            return;
        };
        th.detach();
    }

    fn work(w: *Work) void {
        const r = w.r;
        defer {
            r.gpa.destroy(w);
            _ = r.workers.fetchSub(1, .acq_rel);
        }
        var out: [65536]u8 = undefined;
        switch (w.kind) {
            .udp => if (r.answer(.udp, w.msg[0..w.len], w.from.port, &out)) |a| HostNet.sendTo(r.udp.fd, a, w.from),
            .tcp => r.serveTcp(w.fd, w.from.port, &out),
        }
    }

    /// Answers a TCP connection's queries, each with its two-byte length,
    /// until it closes or goes idle.
    fn serveTcp(r: *Resolver, fd: Fd, lport: u16, out: []u8) void {
        defer HostNet.close(fd);
        var q: [65535]u8 = undefined;
        while (true) {
            var lb: [2]u8 = undefined;
            if (!r.readAll(fd, &lb, tcp_idle_ms)) return;
            const n = std.mem.readInt(u16, &lb, .big);
            if (!r.readAll(fd, q[0..n], forward_timeout_ms)) return;
            const a = r.answer(.tcp, q[0..n], lport, out[2..]) orelse return;
            std.mem.writeInt(u16, out[0..2], @intCast(a.len), .big);
            if (a.ptr != out[2..].ptr) std.mem.copyForwards(u8, out[2..][0..a.len], a);
            if (!HostNet.writeAll(fd, out[0 .. 2 + a.len], monoMs() + forward_timeout_ms)) return;
        }
    }

    fn readAll(r: *Resolver, fd: Fd, buf: []u8, ms: i64) bool {
        const deadline = monoMs() + ms;
        var got: usize = 0;
        while (got < buf.len) {
            if (r.stopping.load(.acquire)) return false;
            const left = deadline - monoMs();
            if (left <= 0) return false;
            if (!HostNet.wait(fd, std.c.POLL.IN, @min(left, 100))) continue;
            const n = HostNet.read(fd, buf[got..]) orelse return false;
            if (n == 0) return false;
            got += n;
        }
        return true;
    }
};

fn forwardUdp(srv: Server, query: []const u8, out: []u8, until: i64) ?[]const u8 {
    const fd = HostNet.dial(.udp, srv, until) orelse return null;
    defer HostNet.close(fd);
    if (!HostNet.writeAll(fd, query, until)) return null;
    while (true) {
        const left = until - monoMs();
        if (left <= 0) return null;
        if (!HostNet.wait(fd, std.c.POLL.IN, left)) continue;
        const n = HostNet.read(fd, out) orelse return null;
        if (n >= 12 and std.mem.eql(u8, out[0..2], query[0..2])) return out[0..n];
    }
}

fn forwardTcp(srv: Server, query: []const u8, out: []u8, until: i64) ?[]const u8 {
    const fd = HostNet.dial(.tcp, srv, until) orelse return null;
    defer HostNet.close(fd);
    var lb: [2]u8 = undefined;
    std.mem.writeInt(u16, &lb, @intCast(query.len), .big);
    if (!HostNet.writeAll(fd, &lb, until) or !HostNet.writeAll(fd, query, until)) return null;
    if (!readUntil(fd, &lb, until)) return null;
    const n = std.mem.readInt(u16, &lb, .big);
    if (n > out.len or !readUntil(fd, out[0..n], until)) return null;
    return out[0..n];
}

fn readUntil(fd: Fd, buf: []u8, until: i64) bool {
    var got: usize = 0;
    while (got < buf.len) {
        const left = until - monoMs();
        if (left <= 0) return false;
        if (!HostNet.wait(fd, std.c.POLL.IN, left)) continue;
        const n = HostNet.read(fd, buf[got..]) orelse return false;
        if (n == 0) return false;
        got += n;
    }
    return true;
}

fn monoMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

fn sleepMs(ms: u32) void {
    var ts: std.c.timespec = .{ .sec = 0, .nsec = @as(c_long, ms) * 1_000_000 };
    _ = std.c.nanosleep(&ts, null);
}

/// Every host socket the resolver uses: the two it listens on, on the
/// host's loopback, and the ones it dials the nameservers with. They're
/// here alone so they can move onto other host handles without changing
/// how queries are answered.
pub const HostNet = struct {
    pub const Listener = struct { fd: Fd = -1, port: u16 = 0 };
    /// A peer's address, as devip keeps it, and port.
    pub const Peer = struct { addr: [16]u8, port: u16, sa: Sockaddr, len: std.c.socklen_t };

    const c = std.c;
    const Sockaddr = extern union { any: c.sockaddr, in: c.sockaddr.in, in6: c.sockaddr.in6 };

    /// Opens a socket on 127.0.0.1, on a port the host picks: bound for
    /// UDP, listening for TCP. Close-on-exec, so a host program h9 runs
    /// doesn't inherit it.
    pub fn listenLoopback(kind: Transport) !Listener {
        const st: c_uint = if (kind == .udp) c.SOCK.DGRAM else c.SOCK.STREAM;
        const fd = c.socket(c.AF.INET, st, 0);
        if (fd < 0) return error.Failed;
        errdefer close(fd);
        _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
        var sa: Sockaddr = .{ .in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) } };
        if (c.bind(fd, &sa.any, @sizeOf(c.sockaddr.in)) != 0) return error.Failed;
        if (kind == .tcp and c.listen(fd, 64) != 0) return error.Failed;
        var len: c.socklen_t = @sizeOf(Sockaddr);
        if (c.getsockname(fd, &sa.any, &len) != 0) return error.Failed;
        return .{ .fd = fd, .port = std.mem.bigToNative(u16, sa.in.port) };
    }

    /// Dials a nameserver for one query, by `until` (monotonic ms).
    pub fn dial(kind: Transport, srv: Server, until: i64) ?Fd {
        var sa: Sockaddr = undefined;
        const len = toSockaddr(&srv.addr, srv.port, &sa);
        const fam: c_uint = if (len == @sizeOf(c.sockaddr.in)) c.AF.INET else c.AF.INET6;
        const st: c_uint = if (kind == .udp) c.SOCK.DGRAM else c.SOCK.STREAM;
        const fd = c.socket(fam, st | c.SOCK.NONBLOCK | c.SOCK.CLOEXEC, 0);
        if (fd < 0) return null;
        if (c.connect(fd, &sa.any, len) == 0) return fd;
        if (std.posix.errno(-1) != .INPROGRESS or !wait(fd, c.POLL.OUT, until - monoMs())) {
            close(fd);
            return null;
        }
        var err: c_int = 0;
        var el: c.socklen_t = @sizeOf(c_int);
        if (c.getsockopt(fd, c.SOL.SOCKET, c.SO.ERROR, @ptrCast(&err), &el) != 0 or err != 0) {
            close(fd);
            return null;
        }
        return fd;
    }

    pub fn recvFrom(fd: Fd, buf: []u8, from: *Peer) ?usize {
        from.len = @sizeOf(Sockaddr);
        const n = c.recvfrom(fd, buf.ptr, buf.len, 0, &from.sa.any, &from.len);
        if (n < 0) return null;
        fromSockaddr(from);
        return @intCast(n);
    }

    pub fn sendTo(fd: Fd, buf: []const u8, to: Peer) void {
        _ = c.sendto(fd, buf.ptr, buf.len, 0, &to.sa.any, to.len);
    }

    pub fn accept(fd: Fd, from: *Peer) ?Fd {
        from.len = @sizeOf(Sockaddr);
        const nfd = c.accept(fd, &from.sa.any, &from.len);
        if (nfd < 0) return null;
        _ = c.fcntl(nfd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
        fromSockaddr(from);
        return nfd;
    }

    pub fn read(fd: Fd, buf: []u8) ?usize {
        const n = c.read(fd, buf.ptr, buf.len);
        return if (n < 0) null else @intCast(n);
    }

    pub fn writeAll(fd: Fd, buf: []const u8, until: i64) bool {
        var off: usize = 0;
        while (off < buf.len) {
            const n = c.send(fd, buf[off..].ptr, buf.len - off, c.MSG.NOSIGNAL);
            if (n < 0) {
                if (std.posix.errno(-1) != .AGAIN or !wait(fd, c.POLL.OUT, until - monoMs())) return false;
                continue;
            }
            off += @intCast(n);
        }
        return true;
    }

    /// Whether fd is ready for `events` within `ms`.
    pub fn wait(fd: Fd, events: i16, ms: i64) bool {
        if (ms <= 0) return false;
        var fds = [_]c.pollfd{.{ .fd = fd, .events = events, .revents = 0 }};
        return c.poll(&fds, 1, @intCast(@min(ms, 60_000))) > 0;
    }

    pub fn close(fd: Fd) void {
        if (fd >= 0) _ = c.close(fd);
    }

    fn toSockaddr(addr: *const [16]u8, p: u16, sa: *Sockaddr) c.socklen_t {
        if (policy.isV4(addr)) {
            sa.* = .{ .in = .{ .port = std.mem.nativeToBig(u16, p), .addr = @bitCast(addr[12..16].*) } };
            return @sizeOf(c.sockaddr.in);
        }
        sa.* = .{ .in6 = .{ .port = std.mem.nativeToBig(u16, p), .flowinfo = 0, .addr = addr.*, .scope_id = 0 } };
        return @sizeOf(c.sockaddr.in6);
    }

    fn fromSockaddr(p: *Peer) void {
        p.addr = @splat(0);
        if (p.sa.any.family == c.AF.INET) {
            p.addr[10] = 0xff;
            p.addr[11] = 0xff;
            p.addr[12..16].* = @bitCast(p.sa.in.addr);
            p.port = std.mem.bigToNative(u16, p.sa.in.port);
        } else {
            p.addr = p.sa.in6.addr;
            p.port = std.mem.bigToNative(u16, p.sa.in6.port);
        }
    }
};

// DNS messages (RFC 1035). Every offset is checked against the message,
// and a name's compression pointers are followed a bounded number of times.

pub const rcode_formerr = 1;
pub const rcode_servfail = 2;
pub const rcode_refused = 5;

const type_a = 1;
const type_cname = 5;
const type_aaaa = 28;

/// A query's question: its name, lowercased and without a trailing dot.
pub const Question = struct {
    buf: [255]u8,
    len: usize,
    /// Where the question (name, type and class) ends in the message.
    end: usize,

    pub fn name(q: *const Question) []const u8 {
        return q.buf[0..q.len];
    }
};

/// Parses a query with exactly one question. `Short` is a message too
/// short to answer (no header); `Format` gets FORMERR.
pub fn parseQuery(msg: []const u8, q: *Question) error{ Short, Format }!void {
    if (msg.len < 12) return error.Short;
    const flags = std.mem.readInt(u16, msg[2..4], .big);
    // A response, or an opcode other than QUERY.
    if (flags & 0x8000 != 0 or (flags >> 11) & 0xf != 0) return error.Format;
    if (std.mem.readInt(u16, msg[4..6], .big) != 1) return error.Format;
    const end = readName(msg, 12, &q.buf, &q.len, false) orelse return error.Format;
    if (end + 4 > msg.len) return error.Format;
    q.end = end + 4;
}

/// Reads the name at `off` into `buf`, lowercased and dotted, and
/// returns the offset just past it where it appears (not where a pointer
/// led). Compression pointers are followed only with `compressed`.
fn readName(msg: []const u8, off_in: usize, buf: *[255]u8, len: *usize, compressed: bool) ?usize {
    var off = off_in;
    var end: ?usize = null;
    var n: usize = 0;
    var jumps: u32 = 0;
    while (true) {
        if (off >= msg.len) return null;
        const l = msg[off];
        if (l == 0) {
            off += 1;
            break;
        }
        if (l & 0xc0 == 0xc0) {
            if (!compressed or off + 1 >= msg.len) return null;
            jumps += 1;
            if (jumps > 32) return null;
            if (end == null) end = off + 2;
            off = (@as(usize, l & 0x3f) << 8) | msg[off + 1];
            continue;
        }
        if (l & 0xc0 != 0) return null;
        if (off + 1 + l > msg.len) return null;
        if (n + @intFromBool(n > 0) + l > buf.len) return null;
        if (n > 0) {
            buf[n] = '.';
            n += 1;
        }
        for (msg[off + 1 ..][0..l], 0..) |ch, i| buf[n + i] = std.ascii.toLower(ch);
        n += l;
        off += 1 + l;
    }
    len.* = n;
    return end orelse off;
}

/// An error reply to `query`: its id, opcode and RD, with QR, RA and
/// `rcode`, and its question if it had one.
pub fn errorReply(query: []const u8, q: ?*const Question, rcode: u4, out: []u8) []const u8 {
    const qlen = if (q) |qq| qq.end - 12 else 0;
    const n = 12 + qlen;
    if (query.len < 12 or out.len < n) return out[0..0];
    @memset(out[0..12], 0);
    out[0] = query[0];
    out[1] = query[1];
    // QR, the query's opcode and RD; RA; the rcode.
    out[2] = 0x80 | (query[2] & 0x79);
    out[3] = 0x80 | @as(u8, rcode);
    if (q != null) {
        out[5] = 1;
        @memcpy(out[12..n], query[12..n]);
    }
    return out[0..n];
}

/// Records each A and AAAA record in an answer's answer section whose
/// owner is `qname`, or a name its CNAME records lead to from it, in
/// `names` under `qname`, with no protocol or port. A message it can't
/// parse records what it read before the fault.
pub fn recordAnswer(msg: []const u8, qname: []const u8, names: *policy.NameTable) void {
    if (msg.len < 12) return;
    const qd = std.mem.readInt(u16, msg[4..6], .big);
    const an = std.mem.readInt(u16, msg[6..8], .big);
    var off: usize = 12;
    var scratch: [255]u8 = undefined;
    var sl: usize = 0;
    var i: usize = 0;
    while (i < qd) : (i += 1) {
        off = readName(msg, off, &scratch, &sl, true) orelse return;
        off += 4;
    }
    const max_rr = 64;
    var owners: [max_rr][255]u8 = undefined;
    var owner_len: [max_rr]usize = undefined;
    var types: [max_rr]u16 = undefined;
    var rd: [max_rr]usize = undefined;
    var rdlen: [max_rr]usize = undefined;
    var nrr: usize = 0;
    i = 0;
    while (i < an and nrr < max_rr) : (i += 1) {
        off = readName(msg, off, &owners[nrr], &owner_len[nrr], true) orelse break;
        if (off + 10 > msg.len) break;
        types[nrr] = std.mem.readInt(u16, msg[off..][0..2], .big);
        const l = std.mem.readInt(u16, msg[off + 8 ..][0..2], .big);
        off += 10;
        if (off + l > msg.len) break;
        rd[nrr] = off;
        rdlen[nrr] = l;
        off += l;
        nrr += 1;
    }
    // The names the question leads to through CNAMEs, at most 16.
    var chain: [16][255]u8 = undefined;
    var chain_len: [16]usize = undefined;
    @memcpy(chain[0][0..qname.len], qname);
    chain_len[0] = @min(qname.len, 255);
    var nchain: usize = 1;
    var grew = true;
    while (grew and nchain < chain.len) {
        grew = false;
        for (0..nrr) |k| {
            if (types[k] != type_cname) continue;
            if (!inChain(chain[0..nchain], chain_len[0..nchain], owners[k][0..owner_len[k]])) continue;
            var tl: usize = 0;
            _ = readName(msg, rd[k], &scratch, &tl, true) orelse continue;
            if (inChain(chain[0..nchain], chain_len[0..nchain], scratch[0..tl])) continue;
            @memcpy(chain[nchain][0..tl], scratch[0..tl]);
            chain_len[nchain] = tl;
            nchain += 1;
            grew = true;
            if (nchain == chain.len) break;
        }
    }
    for (0..nrr) |k| {
        if (!inChain(chain[0..nchain], chain_len[0..nchain], owners[k][0..owner_len[k]])) continue;
        var a: [16]u8 = @splat(0);
        if (types[k] == type_a and rdlen[k] == 4) {
            a[10] = 0xff;
            a[11] = 0xff;
            @memcpy(a[12..16], msg[rd[k]..][0..4]);
        } else if (types[k] == type_aaaa and rdlen[k] == 16) {
            @memcpy(&a, msg[rd[k]..][0..16]);
        } else continue;
        names.record(null, &a, null, qname);
    }
}

fn inChain(chain: []const [255]u8, lens: []const usize, name: []const u8) bool {
    for (chain, lens) |*c, l| if (std.mem.eql(u8, c[0..l], name)) return true;
    return false;
}

// Tests, against canned messages.

const t = std.testing;

/// A query for `name` (dotted), type `qtype`, with id 0x1234 and RD.
pub fn buildQuery(buf: []u8, name: []const u8, qtype: u16) []const u8 {
    @memset(buf[0..12], 0);
    buf[0] = 0x12;
    buf[1] = 0x34;
    buf[2] = 0x01;
    buf[5] = 1;
    var n: usize = 12;
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |label| {
        buf[n] = @intCast(label.len);
        @memcpy(buf[n + 1 ..][0..label.len], label);
        n += 1 + label.len;
    }
    buf[n] = 0;
    std.mem.writeInt(u16, buf[n + 1 ..][0..2], qtype, .big);
    std.mem.writeInt(u16, buf[n + 3 ..][0..2], 1, .big);
    return buf[0 .. n + 5];
}

fn tip(s: []const u8) [16]u8 {
    return policy.parseIp(s).?;
}

test "a query's question is parsed lowercased, and anything else is FORMERR [linux-dns]" {
    var b: [512]u8 = undefined;
    var q: Question = undefined;
    try parseQuery(buildQuery(&b, "Api.Example.COM", type_a), &q);
    try t.expectEqualStrings("api.example.com", q.name());
    // Two questions, a response, and a short message.
    var two = b;
    two[5] = 2;
    try t.expectError(error.Format, parseQuery(two[0..33], &q));
    var resp = b;
    resp[2] |= 0x80;
    try t.expectError(error.Format, parseQuery(resp[0..33], &q));
    try t.expectError(error.Short, parseQuery(b[0..5], &q));
    // A compression pointer has no place in a query's question.
    var ptr = b;
    ptr[12] = 0xc0;
    try t.expectError(error.Format, parseQuery(ptr[0..33], &q));
    // A label running past the end.
    var long = b;
    long[12] = 60;
    try t.expectError(error.Format, parseQuery(long[0..33], &q));
}

test "an error reply keeps the id and the question [linux-dns]" {
    var b: [512]u8 = undefined;
    var o: [512]u8 = undefined;
    const query = buildQuery(&b, "no.example.org", type_a);
    var q: Question = undefined;
    try parseQuery(query, &q);
    const r = errorReply(query, &q, rcode_refused, &o);
    try t.expectEqual(query.len, r.len);
    try t.expectEqualSlices(u8, query[0..2], r[0..2]);
    try t.expectEqual(@as(u8, 0x81), r[2]);
    try t.expectEqual(@as(u8, 0x85), r[3]);
    try t.expectEqualSlices(u8, query[12..], r[12..]);
    const f = errorReply(query, null, rcode_formerr, &o);
    try t.expectEqual(@as(usize, 12), f.len);
    try t.expectEqual(@as(u8, 0), f[5]);
}

/// A reply to `query` with the given answer records, each `owner`
/// (dotted, or `@` for a pointer to the question's name), type and
/// rdata.
const Rr = struct { owner: []const u8, type: u16, data: []const u8 };

fn buildReply(buf: []u8, query: []const u8, rrs: []const Rr) []const u8 {
    @memcpy(buf[0..query.len], query);
    buf[2] = 0x81;
    buf[3] = 0x80;
    std.mem.writeInt(u16, buf[6..8], @intCast(rrs.len), .big);
    var n = query.len;
    for (rrs) |rr| {
        if (std.mem.eql(u8, rr.owner, "@")) {
            buf[n] = 0xc0;
            buf[n + 1] = 12;
            n += 2;
        } else {
            var it = std.mem.splitScalar(u8, rr.owner, '.');
            while (it.next()) |label| {
                buf[n] = @intCast(label.len);
                @memcpy(buf[n + 1 ..][0..label.len], label);
                n += 1 + label.len;
            }
            buf[n] = 0;
            n += 1;
        }
        std.mem.writeInt(u16, buf[n..][0..2], rr.type, .big);
        std.mem.writeInt(u16, buf[n + 2 ..][0..2], 1, .big);
        std.mem.writeInt(u32, buf[n + 4 ..][0..4], 60, .big);
        std.mem.writeInt(u16, buf[n + 8 ..][0..2], @intCast(rr.data.len), .big);
        n += 10;
        @memcpy(buf[n..][0..rr.data.len], rr.data);
        n += rr.data.len;
    }
    return buf[0..n];
}

/// A name in wire form, for a CNAME's rdata.
fn wireName(buf: []u8, name: []const u8) []const u8 {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |label| {
        buf[n] = @intCast(label.len);
        @memcpy(buf[n + 1 ..][0..label.len], label);
        n += 1 + label.len;
    }
    buf[n] = 0;
    return buf[0 .. n + 1];
}

test "an answer's addresses are recorded under the question's name, through CNAMEs [linux-dns]" {
    const nt = try t.allocator.create(policy.NameTable);
    defer t.allocator.destroy(nt);
    nt.* = .{};
    var qb: [512]u8 = undefined;
    var rb: [1024]u8 = undefined;
    var wb: [64]u8 = undefined;
    const query = buildQuery(&qb, "api.example.com", type_a);
    const reply = buildReply(&rb, query, &.{
        .{ .owner = "@", .type = type_cname, .data = wireName(&wb, "edge.cdn.net") },
        .{ .owner = "edge.cdn.net", .type = type_a, .data = &.{ 10, 0, 0, 7 } },
        .{ .owner = "edge.cdn.net", .type = type_aaaa, .data = &tip("fd00::7") },
        // Not on the chain: passed on, never recorded.
        .{ .owner = "other.org", .type = type_a, .data = &.{ 10, 0, 0, 8 } },
    });
    recordAnswer(reply, "api.example.com", nt);
    var pb: [64]u8 = undefined;
    var why: []const u8 = "";
    const pats = [_]policy.NetPattern{try policy.parseNetPattern(try std.fmt.bufPrint(&pb, "tcp!api.example.com!443", .{}), &why)};
    try t.expect(nt.allows(&pats, .tcp, &tip("10.0.0.7"), 443));
    try t.expect(nt.allows(&pats, .tcp, &tip("fd00::7"), 443));
    try t.expect(!nt.allows(&pats, .tcp, &tip("10.0.0.7"), 80));
    try t.expect(!nt.allows(&pats, .tcp, &tip("10.0.0.8"), 443));
}

test "a reply that runs off its end records what came before, and a pointer loop stops [linux-dns]" {
    const nt = try t.allocator.create(policy.NameTable);
    defer t.allocator.destroy(nt);
    nt.* = .{};
    var qb: [512]u8 = undefined;
    var rb: [1024]u8 = undefined;
    const query = buildQuery(&qb, "a.example.com", type_a);
    const reply = buildReply(&rb, query, &.{
        .{ .owner = "@", .type = type_a, .data = &.{ 10, 0, 0, 1 } },
        .{ .owner = "@", .type = type_a, .data = &.{ 10, 0, 0, 2 } },
    });
    recordAnswer(reply[0 .. reply.len - 3], "a.example.com", nt);
    try t.expectEqual(@as(usize, 1), nt.count);
    // A pointer to itself.
    var loop_msg = rb;
    loop_msg[query.len] = 0xc0;
    loop_msg[query.len + 1] = @intCast(query.len);
    recordAnswer(loop_msg[0..reply.len], "a.example.com", nt);
    try t.expectEqual(@as(usize, 1), nt.count);
    recordAnswer(rb[0..7], "a.example.com", nt);
}

test "a nameserver may give a port [linux-dns]" {
    try t.expectEqual(@as(u16, 53), parseServer("10.0.0.2").?.port);
    try t.expectEqual(@as(u16, 5353), parseServer("127.0.0.1!5353").?.port);
    try t.expectEqualSlices(u8, &tip("127.0.0.1"), &parseServer("127.0.0.1!5353").?.addr);
    try t.expect(parseServer("127.0.0.1!0") == null);
    try t.expect(parseServer("nonsense!53") == null);
    try t.expectEqualStrings("::1", serverHost("::1!53"));
    try t.expectEqualStrings("::1", serverHost("::1"));
}

test "the resolver refuses a name no pattern covers, forwards the rest, and records for redirected ports only [linux-dns]" {
    if (comptime !supported) return error.SkipZigTest;
    // A nameserver that answers every query with 10.0.0.9.
    const ns = try HostNet.listenLoopback(.udp);
    defer HostNet.close(ns.fd);
    const Stub = struct {
        fn run(fd: Fd, seen: *std.atomic.Value(u32)) void {
            var buf: [512]u8 = undefined;
            var out: [1024]u8 = undefined;
            if (!HostNet.wait(fd, std.c.POLL.IN, 5000)) return;
            var from: HostNet.Peer = undefined;
            const n = HostNet.recvFrom(fd, &buf, &from) orelse return;
            _ = seen.fetchAdd(1, .acq_rel);
            HostNet.sendTo(fd, buildReply(&out, buf[0..n], &.{.{ .owner = "@", .type = type_a, .data = &.{ 10, 0, 0, 9 } }}), from);
        }
    };
    var seen: std.atomic.Value(u32) = .init(0);
    const nt = try t.allocator.create(policy.NameTable);
    defer t.allocator.destroy(nt);
    nt.* = .{};
    var why: []const u8 = "";
    const pats = [_]policy.NetPattern{try policy.parseNetPattern("tcp!*.example.com!443", &why)};
    var r: Resolver = .{ .gpa = t.allocator, .patterns = &pats, .names = nt, .servers = &.{.{ .addr = loopback, .port = ns.port }} };
    var qb: [512]u8 = undefined;
    var ob: [1024]u8 = undefined;
    // Refused, and never sent.
    const refused = r.answer(.udp, buildQuery(&qb, "other.org", type_a), 4000, &ob).?;
    try t.expectEqual(@as(u8, 0x85), refused[3]);
    try t.expectEqual(@as(u32, 0), seen.load(.acquire));
    // Forwarded from a port devip didn't redirect: answered, not recorded.
    var th = try std.Thread.spawn(.{}, Stub.run, .{ ns.fd, &seen });
    const a = r.answer(.udp, buildQuery(&qb, "api.example.com", type_a), 4000, &ob).?;
    th.join();
    try t.expectEqual(@as(u8, 0x80), a[3]);
    try t.expectEqual(@as(usize, 0), nt.count);
    // Forwarded from a redirected port: recorded.
    r.register(.udp, 4000, &tip("8.8.8.8"), 53);
    th = try std.Thread.spawn(.{}, Stub.run, .{ ns.fd, &seen });
    _ = r.answer(.udp, buildQuery(&qb, "api.example.com", type_a), 4000, &ob).?;
    th.join();
    try t.expect(nt.allows(&pats, .tcp, &tip("10.0.0.9"), 443));
    try t.expectEqual(@as(u32, 2), seen.load(.acquire));
    try t.expectEqualSlices(u8, &tip("8.8.8.8"), &r.original(.udp, 4000).?.addr);
}
