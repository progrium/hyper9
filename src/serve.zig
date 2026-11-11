//! Serving the namespace over 9P (design/serve.md): the host side.
//! `--serve` listeners on unix sockets, TCP and WebSocket, each with a
//! thread that accepts connections and hands them to src/hstream.zig as
//! accepted streams. Once a stream's first 9P message has passed the
//! dialect slot it's queued here, and the machine's server Proc takes it
//! from the queue (`next`) and runs an exportfs on it (src/machine.zig).
//!
//! The listeners are bound before the program starts, so a listen that
//! fails ends the run before anything runs, and they're closed when it
//! ends, removing the unix sockets and lock files they made.
//!
//! The Server is shared with the accepted streams' threads, which can
//! outlive the run by a little, so it's reference-counted: the machine
//! holds one reference and each accepted stream another.

const std = @import("std");
const builtin = @import("builtin");
const hstream = @import("hstream.zig");
const kern = @import("kern.zig");
const ws = @import("ws.zig");
const web = @import("web.zig");

const Io = std.Io;
const net = std.Io.net;
const posix = builtin.os.tag != .windows and !web.enabled;

/// Connections a machine serves at once, across its listeners.
pub const max_conns = 32;
/// Live processes one connection's exportfs and its children may have.
pub const conn_procs = 8;

/// A `--serve` address (`Machine.Options.serve`).
pub const Listen = union(enum) {
    /// A host path for a unix socket.
    unix: []const u8,
    /// `host!port`, from `tcp!host!port`.
    tcp: []const u8,
    /// `host:port` and path, from a ws:// URL: `host:port/path`.
    ws: []const u8,

    pub const ParseError = error{BadAddress};

    /// Reads `unix!PATH`, `tcp!HOST!PORT`, or `ws://HOST:PORT[/PATH]`.
    /// Port 0 asks for a free port. `wss://` isn't served (a proxy
    /// terminates TLS in front of a ws:// listener).
    pub fn parse(addr: []const u8) ParseError!Listen {
        if (std.mem.startsWith(u8, addr, "unix!")) {
            const p = addr["unix!".len..];
            if (p.len == 0) return error.BadAddress;
            return .{ .unix = p };
        }
        if (std.mem.startsWith(u8, addr, "tcp!")) {
            const rest = addr["tcp!".len..];
            const bang = std.mem.lastIndexOfScalar(u8, rest, '!') orelse return error.BadAddress;
            _ = try hostPort(rest[0..bang], rest[bang + 1 ..]);
            return .{ .tcp = rest };
        }
        if (std.mem.startsWith(u8, addr, "ws://")) {
            const rest = addr["ws://".len..];
            _ = try wsParts(rest);
            return .{ .ws = rest };
        }
        return error.BadAddress;
    }

    /// The address as `--serve` takes it.
    pub fn format(l: Listen, w: *Io.Writer) Io.Writer.Error!void {
        switch (l) {
            .unix => |p| try w.print("unix!{s}", .{p}),
            .tcp => |a| try w.print("tcp!{s}", .{a}),
            .ws => |a| {
                const p = wsParts(a) catch return w.print("ws://{s}", .{a});
                try w.print("ws://{s}:{d}{s}", .{ p.host_text, p.port, p.path });
            },
        }
    }

    /// The host part of a TCP or WebSocket address, as given.
    pub fn host(l: Listen) []const u8 {
        return switch (l) {
            .unix => "",
            .tcp => |a| a[0..std.mem.lastIndexOfScalar(u8, a, '!').?],
            .ws => |a| (wsParts(a) catch unreachable).host,
        };
    }

    /// A WebSocket address's path.
    pub fn path(l: Listen) []const u8 {
        return switch (l) {
            .ws => |a| (wsParts(a) catch unreachable).path,
            else => "",
        };
    }

    /// The port asked for (0 for any), or null for a unix socket.
    pub fn port(l: Listen) ?u16 {
        return switch (l) {
            .unix => null,
            .tcp => |a| hostPort(a[0..std.mem.lastIndexOfScalar(u8, a, '!').?], a[std.mem.lastIndexOfScalar(u8, a, '!').? + 1 ..]) catch unreachable,
            .ws => |a| (wsParts(a) catch unreachable).port,
        };
    }
};

fn hostPort(h: []const u8, p: []const u8) Listen.ParseError!u16 {
    if (h.len == 0 or p.len == 0) return error.BadAddress;
    if (std.mem.indexOfAny(u8, h, "!/ \t") != null) return error.BadAddress;
    return std.fmt.parseInt(u16, p, 10) catch error.BadAddress;
}

const WsParts = struct { host: []const u8, host_text: []const u8, port: u16, path: []const u8 };

/// `host:port[/path]`, with `[v6]` hosts.
fn wsParts(a: []const u8) Listen.ParseError!WsParts {
    const slash = std.mem.indexOfScalar(u8, a, '/') orelse a.len;
    const authority = a[0..slash];
    const path = if (slash == a.len) "/" else a[slash..];
    if (std.mem.indexOfAny(u8, path, "?# \t") != null) return error.BadAddress;
    var h: []const u8 = undefined;
    var text: []const u8 = undefined;
    var rest: []const u8 = undefined;
    if (authority.len > 0 and authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return error.BadAddress;
        h = authority[1..close];
        text = authority[0 .. close + 1];
        rest = authority[close + 1 ..];
    } else {
        const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse return error.BadAddress;
        h = authority[0..colon];
        text = h;
        rest = authority[colon..];
    }
    if (rest.len < 2 or rest[0] != ':') return error.BadAddress;
    if (std.mem.indexOfScalar(u8, h, '@') != null) return error.BadAddress;
    const p = try hostPort(h, rest[1..]);
    return .{ .host = h, .host_text = text, .port = p, .path = path };
}

/// What the listeners need from the machine.
pub const Config = struct {
    listens: []const Listen,
    /// Required on WebSocket listeners when set.
    token: ?[]const u8 = null,
    /// Origins WebSocket listeners accept; "*" for any.
    origins: []const []const u8 = &.{},
    /// `--trace`'s writer and its lock, for the connection lines.
    trace: ?*Io.Writer = null,
    trace_lock: ?*std.atomic.Mutex = null,
};

pub const OpenError = error{ ServeFailed, OutOfMemory };

const Listener = struct {
    srv: *Server,
    kind: std.meta.Tag(Listen),
    server: net.Server = undefined,
    open: bool = false,
    /// The bound address, port 0 resolved, as `--serve` takes it.
    bound: []const u8 = "",
    /// A unix socket's path and its lock file's, to remove at the end.
    sock_path: ?[:0]u8 = null,
    lock_path: ?[:0]u8 = null,
    lock_fd: c_int = -1,
    thread: ?std.Thread = null,
    served: hstream.Served = undefined,
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    io: Io,
    cfg: Config,
    refs: std.atomic.Value(u32) = .init(1),
    listeners: []Listener = &.{},
    /// Bound addresses, in the order given.
    addrs: [][]const u8 = &.{},
    /// Connections: accepted, and not yet ended (`connEnded`, or a stream
    /// that ended before it was handed over).
    active: std.atomic.Value(u32) = .init(0),
    /// Streams ready for an exportfs, oldest first.
    lock: std.atomic.Mutex = .unlocked,
    ready: std.ArrayList(u32) = .empty,
    /// Bumped when `ready` grows or the server stops, for `next`.
    seq: std.atomic.Value(u32) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),
    /// The machine accepted streams belong to, once `start` has it.
    owner: usize = 0,
    pages: ?*const kern.Pages = null,
    /// 503 answers in progress, each on its own thread.
    refusing: std.atomic.Value(u32) = .init(0),

    fn lockSpin(s: *Server) void {
        while (!s.lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn ref(s: *Server) void {
        _ = s.refs.fetchAdd(1, .acq_rel);
    }

    fn unref(s: *Server) void {
        if (s.refs.fetchSub(1, .acq_rel) != 1) return;
        const gpa = s.gpa;
        s.ready.deinit(gpa);
        for (s.listeners) |*l| {
            gpa.free(l.bound);
            if (l.sock_path) |p| gpa.free(p);
            if (l.lock_path) |p| gpa.free(p);
        }
        gpa.free(s.listeners);
        gpa.free(s.addrs);
        gpa.destroy(s);
    }

    /// The listeners' bound addresses, in the order given.
    pub fn serving(s: *const Server) []const []const u8 {
        return s.addrs;
    }

    /// Starts accepting, for the machine `owner`, whose pages hold the
    /// streams' queues. Called from the server Proc.
    pub fn start(s: *Server, owner: usize, pages: ?*const kern.Pages) void {
        s.owner = owner;
        s.pages = pages;
        hstream.setIo(s.io);
        for (s.listeners) |*l| {
            l.thread = std.Thread.spawn(.{}, acceptLoop, .{l}) catch null;
        }
    }

    /// The next stream ready for an exportfs, with its maker's reference
    /// (hstream.release drops it), or null once the server is stopping.
    /// Waits on the host, in short steps, so `stop` ends it.
    pub fn next(s: *Server) ?u32 {
        while (true) {
            const seq = s.seq.load(.acquire);
            s.lockSpin();
            const id: ?u32 = if (s.ready.items.len > 0) s.ready.orderedRemove(0) else null;
            s.lock.unlock();
            if (id) |i| return i;
            if (s.stopping.load(.acquire)) return null;
            s.io.futexWaitTimeout(u32, &s.seq.raw, seq, .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } }) catch {};
        }
    }

    /// A connection's processes have all exited, or it never got one.
    pub fn connEnded(s: *Server) void {
        _ = s.active.fetchSub(1, .acq_rel);
    }

    /// Stops accepting and ends `next`. Safe from any thread.
    pub fn stop(s: *Server) void {
        s.stopping.store(true, .release);
        _ = s.seq.fetchAdd(1, .release);
        s.io.futexWake(u32, &s.seq.raw, std.math.maxInt(u32));
    }

    /// Stops, closes the listeners, removes the unix sockets and lock
    /// files, and drops the machine's reference. Streams still queued are
    /// hung up.
    pub fn close(s: *Server) void {
        s.stop();
        for (s.listeners) |*l| if (l.thread) |th| {
            th.join();
            l.thread = null;
        };
        for (s.listeners) |*l| {
            if (l.open) l.server.deinit(s.io);
            l.open = false;
            if (posix) {
                if (l.sock_path) |p| _ = std.c.unlink(p);
                if (l.lock_path) |p| _ = std.c.unlink(p);
                if (l.lock_fd >= 0) _ = std.c.close(l.lock_fd);
                l.lock_fd = -1;
            }
        }
        while (true) {
            s.lockSpin();
            const id: ?u32 = if (s.ready.items.len > 0) s.ready.orderedRemove(0) else null;
            s.lock.unlock();
            hstream.release(id orelse break);
        }
        s.unref();
    }

    fn traceLine(s: *Server, comptime fmt: []const u8, args: anytype) void {
        const w = s.cfg.trace orelse return;
        if (s.cfg.trace_lock) |l| while (!l.tryLock()) std.atomic.spinLoopHint();
        defer if (s.cfg.trace_lock) |l| l.unlock();
        w.print("serve: " ++ fmt ++ "\n", args) catch {};
        w.flush() catch {};
    }
};

/// Binds every listener in `cfg`, or none: on failure `msg` says why, as
/// `serve ADDR: cause`, and the ones already bound are closed.
pub fn open(gpa: std.mem.Allocator, io: Io, cfg: Config, msg: []u8, msg_len: *usize) OpenError!*Server {
    const s = try gpa.create(Server);
    s.* = .{ .gpa = gpa, .io = io, .cfg = cfg };
    errdefer s.close();
    s.listeners = try gpa.alloc(Listener, cfg.listens.len);
    for (s.listeners, cfg.listens) |*l, a| l.* = .{ .srv = s, .kind = a };
    s.addrs = try gpa.alloc([]const u8, cfg.listens.len);
    @memset(s.addrs, "");
    for (s.listeners, cfg.listens, 0..) |*l, a, i| {
        bindOne(s, l, a) catch |e| {
            const why: []const u8 = switch (e) {
                error.AddressInUse => "address in use",
                error.NotSocket => "not a socket",
                error.Unsupported => "not supported on this host",
                error.UnknownHost => "unknown host",
                error.OutOfMemory => "out of memory",
                error.NameTooLong => "name too long",
                error.AccessDenied => "permission denied",
                error.AddressUnavailable => "address not available here",
                else => @errorName(e),
            };
            const m = std.fmt.bufPrint(msg, "serve {f}: {s}", .{ a, why }) catch msg;
            msg_len.* = m.len;
            return error.ServeFailed;
        };
        s.addrs[i] = l.bound;
        l.served = .{
            .ws = if (a == .ws) .{ .path = a.path(), .token = cfg.token, .origins = cfg.origins } else null,
            .ctx = l,
            .ready = Callbacks.ready,
            .done = Callbacks.done,
        };
    }
    return s;
}

const BindError = error{ AddressInUse, NotSocket, Unsupported, UnknownHost, OutOfMemory, NameTooLong, AccessDenied, AddressUnavailable, Failed };

fn bindOne(s: *Server, l: *Listener, a: Listen) BindError!void {
    if (web.enabled) return error.Unsupported;
    switch (a) {
        .unix => |p| {
            if (!posix) return error.Unsupported;
            try bindUnix(s, l, p);
            l.bound = try std.fmt.allocPrint(s.gpa, "unix!{s}", .{p});
        },
        .tcp, .ws => {
            const addr = try resolve(s.io, a.host(), a.port().?);
            l.server = try listenIp(s.io, addr);
            l.open = true;
            const got = l.server.socket.address.getPort();
            l.bound = switch (a) {
                .tcp => try std.fmt.allocPrint(s.gpa, "tcp!{s}!{d}", .{ a.host(), got }),
                else => try std.fmt.allocPrint(s.gpa, "ws://{s}:{d}{s}", .{ (wsParts(a.ws) catch unreachable).host_text, got, a.path() }),
            };
        },
    }
}

fn resolve(io: Io, h: []const u8, p: u16) BindError!net.IpAddress {
    if (net.IpAddress.parse(h, p)) |addr| return addr else |_| {}
    const hn = net.HostName.init(h) catch return error.UnknownHost;
    var qbuf: [16]net.HostName.LookupResult = undefined;
    var q: Io.Queue(net.HostName.LookupResult) = .init(&qbuf);
    hn.lookup(io, &q, .{ .port = p }) catch return error.UnknownHost;
    var first: ?net.IpAddress = null;
    while (q.getOneUncancelable(io)) |res| switch (res) {
        .address => |addr| {
            // IPv4 first, as a name like localhost usually means it.
            if (first == null or (first.? == .ip6 and addr == .ip4)) first = addr;
        },
        .canonical_name => {},
    } else |_| {}
    return first orelse error.UnknownHost;
}

/// A TCP listener with SO_REUSEADDR only, so a port is taken again at
/// once after a run ends, but two runs can't share it (std's
/// reuse_address also sets SO_REUSEPORT).
fn listenIp(io: Io, addr: net.IpAddress) BindError!net.Server {
    if (!posix) {
        return addr.listen(io, .{}) catch |e| switch (e) {
            error.AddressInUse => error.AddressInUse,
            error.AddressUnavailable => error.AddressUnavailable,
            else => error.Failed,
        };
    }
    const c = std.c;
    var sa: extern union { any: c.sockaddr, in: c.sockaddr.in, in6: c.sockaddr.in6 } = undefined;
    var len: c.socklen_t = undefined;
    switch (addr) {
        .ip4 => |v| {
            sa = .{ .in = .{ .port = std.mem.nativeToBig(u16, v.port), .addr = @bitCast(v.bytes) } };
            len = @sizeOf(c.sockaddr.in);
        },
        .ip6 => |v| {
            sa = .{ .in6 = .{ .port = std.mem.nativeToBig(u16, v.port), .flowinfo = v.flow, .addr = v.bytes, .scope_id = v.interface.index } };
            len = @sizeOf(c.sockaddr.in6);
        },
    }
    const family: c_uint = if (addr == .ip4) c.AF.INET else c.AF.INET6;
    const fd = c.socket(family, c.SOCK.STREAM, 0);
    if (fd < 0) return error.Failed;
    errdefer _ = c.close(fd);
    _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
    const one: c_int = 1;
    _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, &one, @sizeOf(c_int));
    if (c.bind(fd, &sa.any, len) != 0) return switch (std.posix.errno(-1)) {
        .ADDRINUSE => error.AddressInUse,
        .ADDRNOTAVAIL => error.AddressUnavailable,
        .ACCES, .PERM => error.AccessDenied,
        else => error.Failed,
    };
    if (c.listen(fd, 128) != 0) return error.Failed;
    var out: extern union { any: c.sockaddr, in: c.sockaddr.in, in6: c.sockaddr.in6 } = undefined;
    var olen: c.socklen_t = @sizeOf(@TypeOf(out));
    if (c.getsockname(fd, &out.any, &olen) != 0) return error.Failed;
    var bound = addr;
    bound.setPort(std.mem.bigToNative(u16, if (addr == .ip4) out.in.port else out.in6.port));
    return .{ .socket = .{ .handle = fd, .address = bound }, .options = {} };
}

/// A unix socket listener, made mode 0600, after taking `PATH.lock` and
/// clearing a stale socket left by an earlier run.
fn bindUnix(s: *Server, l: *Listener, p: []const u8) BindError!void {
    if (!posix) return error.Unsupported;
    const c = std.c;
    const gpa = s.gpa;
    const pz = try gpa.dupeZ(u8, p);
    errdefer gpa.free(pz);
    const lz = try std.fmt.allocPrintSentinel(gpa, "{s}.lock", .{p}, 0);
    const lfd = c.open(lz, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
    if (lfd < 0) {
        gpa.free(lz);
        return switch (std.posix.errno(-1)) {
            .ACCES, .PERM => error.AccessDenied,
            .NAMETOOLONG => error.NameTooLong,
            else => error.Failed,
        };
    }
    if (c.flock(lfd, std.posix.LOCK.EX | std.posix.LOCK.NB) != 0) {
        _ = c.close(lfd);
        gpa.free(lz);
        return error.AddressInUse;
    }
    // From here the lock file is ours, and `close` removes it, even if
    // listening fails.
    l.lock_fd = lfd;
    l.lock_path = lz;
    if (std.Io.Dir.cwd().statFile(s.io, p, .{ .follow_symlinks = false })) |st| {
        if (st.kind != .unix_domain_socket) return error.NotSocket;
        if (unixAnswers(p)) return error.AddressInUse;
        _ = c.unlink(pz);
    } else |_| {}
    const ua = net.UnixAddress.init(p) catch return error.NameTooLong;
    const old = c.umask(0o177);
    const srv = ua.listen(s.io, .{});
    _ = c.umask(old);
    l.server = srv catch |e| return switch (e) {
        error.AddressInUse => error.AddressInUse,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        else => error.Failed,
    };
    l.open = true;
    _ = c.chmod(pz, 0o600);
    l.sock_path = pz;
}

/// Whether something accepts a connection on the unix socket at `p`.
/// Through libc, since std treats a refusal as unexpected.
fn unixAnswers(p: []const u8) bool {
    if (!posix) return false;
    const c = std.c;
    var sa: c.sockaddr.un = .{ .path = undefined };
    @memset(&sa.path, 0);
    if (p.len >= sa.path.len) return false;
    @memcpy(sa.path[0..p.len], p);
    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    return c.connect(fd, @ptrCast(&sa), @sizeOf(c.sockaddr.un)) == 0;
}

fn acceptLoop(l: *Listener) void {
    const s = l.srv;
    const io = s.io;
    while (!s.stopping.load(.acquire)) {
        if (posix) {
            var fds = [_]std.c.pollfd{.{ .fd = l.server.socket.handle, .events = std.c.POLL.IN, .revents = 0 }};
            const n = std.c.poll(&fds, 1, 100);
            if (n <= 0) continue;
        }
        const st = l.server.accept(io) catch |e| switch (e) {
            error.SocketNotListening => return,
            else => {
                io.sleep(.fromMilliseconds(10), .awake) catch {};
                continue;
            },
        };
        if (s.stopping.load(.acquire)) {
            st.close(io);
            return;
        }
        var peer_buf: [128]u8 = undefined;
        const peer = describePeer(&peer_buf, l.kind, st);
        if (s.active.fetchAdd(1, .acq_rel) >= max_conns) {
            _ = s.active.fetchSub(1, .acq_rel);
            s.traceLine("{s}: refused {s}: {d} connections", .{ l.bound, peer, max_conns });
            refuse(s, l, st);
            continue;
        }
        s.traceLine("{s}: accept {s}", .{ l.bound, peer });
        s.ref();
        hstream.openAccepted(s.owner, s.pages, st, peer, &l.served) catch {
            s.connEnded();
            s.unref();
        };
    }
}

/// Closes a connection past the cap: a WebSocket one is answered 503
/// first, on a thread of its own, since the request has to be read.
fn refuse(s: *Server, l: *Listener, st: net.Stream) void {
    const io = s.io;
    if (l.kind != .ws or s.refusing.fetchAdd(1, .acq_rel) >= 4) {
        if (l.kind == .ws) _ = s.refusing.fetchSub(1, .acq_rel);
        st.close(io);
        return;
    }
    s.ref();
    const th = std.Thread.spawn(.{}, answer503, .{ s, st }) catch {
        _ = s.refusing.fetchSub(1, .acq_rel);
        st.close(io);
        s.unref();
        return;
    };
    th.detach();
}

fn answer503(s: *Server, st: net.Stream) void {
    const io = s.io;
    defer {
        st.close(io);
        _ = s.refusing.fetchSub(1, .acq_rel);
        s.unref();
    }
    var ib: [4096]u8 = undefined;
    var ob: [256]u8 = undefined;
    var sr = st.reader(io, &ib);
    var sw = st.writer(io, &ob);
    if (posix) {
        var fds = [_]std.c.pollfd{.{ .fd = st.socket.handle, .events = std.c.POLL.IN, .revents = 0 }};
        if (std.c.poll(&fds, 1, 5000) <= 0) return;
    }
    var q: ws.Request = .{};
    ws.readRequest(&sr.interface, &q) catch return;
    ws.writeStatus(&sw.interface, 503, ws.reasonPhrase(503)) catch {};
}

/// The peer, for `--trace` and the stream's `remote`: an address for TCP
/// and WebSocket, the uid and pid for a unix socket.
fn describePeer(buf: []u8, kind: std.meta.Tag(Listen), st: net.Stream) []const u8 {
    if (kind == .unix) {
        const cr = peerCred(st.socket.handle) orelse return "unix!?";
        return std.fmt.bufPrint(buf, "uid {d} pid {d}", .{ cr.uid, cr.pid }) catch "unix!?";
    }
    const a = st.socket.address;
    return switch (a) {
        .ip4 => |v| std.fmt.bufPrint(buf, "{s}{d}.{d}.{d}.{d}!{d}", .{ if (kind == .tcp) "tcp!" else "", v.bytes[0], v.bytes[1], v.bytes[2], v.bytes[3], v.port }),
        .ip6 => std.fmt.bufPrint(buf, "{s}{f}", .{ if (kind == .tcp) "tcp!" else "", a }),
    } catch "?";
}

const Cred = struct { uid: u32, pid: i32 };

/// A unix socket peer's credentials: SO_PEERCRED on Linux,
/// LOCAL_PEERCRED and LOCAL_PEERPID on macOS.
fn peerCred(fd: net.Socket.Handle) ?Cred {
    if (!posix) return null;
    const c = std.c;
    switch (builtin.os.tag) {
        .linux => {
            const Ucred = extern struct { pid: i32, uid: u32, gid: u32 };
            var u: Ucred = undefined;
            var len: c.socklen_t = @sizeOf(Ucred);
            if (c.getsockopt(fd, c.SOL.SOCKET, c.SO.PEERCRED, &u, &len) != 0) return null;
            return .{ .uid = u.uid, .pid = u.pid };
        },
        .macos => {
            const sol_local = 0;
            const local_peercred = 1;
            const local_peerpid = 2;
            const Xucred = extern struct { version: u32, uid: u32, ngroups: i16, groups: [16]u32 };
            var x: Xucred = undefined;
            var len: c.socklen_t = @sizeOf(Xucred);
            if (c.getsockopt(fd, sol_local, local_peercred, &x, &len) != 0) return null;
            var pid: i32 = -1;
            var plen: c.socklen_t = @sizeOf(i32);
            _ = c.getsockopt(fd, sol_local, local_peerpid, &pid, &plen);
            return .{ .uid = x.uid, .pid = pid };
        },
        else => return null,
    }
}

const Callbacks = struct {
    fn ready(ctx: *anyopaque, id: u32) void {
        const l: *Listener = @ptrCast(@alignCast(ctx));
        const s = l.srv;
        s.lockSpin();
        const ok = if (s.stopping.load(.acquire)) false else blk: {
            s.ready.append(s.gpa, id) catch break :blk false;
            break :blk true;
        };
        s.lock.unlock();
        if (!ok) {
            // Nobody will take it: it ends here, and its connection with it.
            hstream.release(id);
            s.connEnded();
            return;
        }
        _ = s.seq.fetchAdd(1, .release);
        s.io.futexWake(u32, &s.seq.raw, 1);
    }

    fn done(ctx: *anyopaque, handed: bool) void {
        const l: *Listener = @ptrCast(@alignCast(ctx));
        const s = l.srv;
        if (!handed) s.connEnded();
        s.unref();
    }
};

const t = std.testing;

test "--serve addresses" {
    const u = try Listen.parse("unix!/tmp/h9.sock");
    try t.expectEqualStrings("/tmp/h9.sock", u.unix);
    const tc = try Listen.parse("tcp!127.0.0.1!0");
    try t.expectEqualStrings("127.0.0.1", tc.host());
    try t.expectEqual(@as(?u16, 0), tc.port());
    const w = try Listen.parse("ws://127.0.0.1:8080/9p");
    try t.expectEqualStrings("127.0.0.1", w.host());
    try t.expectEqual(@as(?u16, 8080), w.port());
    try t.expectEqualStrings("/9p", w.path());
    try t.expectEqualStrings("/", (try Listen.parse("ws://localhost:0")).path());
    try t.expectEqualStrings("::1", (try Listen.parse("ws://[::1]:9/x")).host());
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("ws://[::1]:9/x", try std.fmt.bufPrint(&buf, "{f}", .{try Listen.parse("ws://[::1]:9/x")}));
    try t.expectEqualStrings("tcp!h!1", try std.fmt.bufPrint(&buf, "{f}", .{try Listen.parse("tcp!h!1")}));
    for ([_][]const u8{ "unix!", "tcp!", "tcp!h", "tcp!!1", "tcp!h!x", "tcp!h!70000", "ws://", "ws://:80/", "ws://h/", "ws://h:x/", "wss://h:1/", "ws://h:1/p?q", "ws://u@h:1/", "/tmp/sock", "h:1" }) |bad| {
        try t.expectError(error.BadAddress, Listen.parse(bad));
    }
}
