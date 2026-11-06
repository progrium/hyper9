//! A WebSocket server for the websocket-9p cases (design/0021-websocket-9p.md),
//! built from src/ws.zig's server side. It accepts WebSocket connections on
//! a loopback port and relays each one's binary messages to a TCP server,
//! normally a second h9 running exportfs. Options make it misbehave in the
//! ways the cases need. `Proxy` is a small HTTP CONNECT proxy.
//!
//! As a program, for the demo: `wsrelay LISTEN_PORT TARGET_PORT` relays
//! ws://127.0.0.1:LISTEN_PORT/ to 127.0.0.1:TARGET_PORT until killed.

const std = @import("std");
const ws = @import("ws");
const net = std.Io.net;
const Io = std.Io;

const gpa = std.heap.smp_allocator;

pub const Options = struct {
    /// The TCP server each connection is relayed to; ignored by `echo`.
    target_port: u16 = 0,
    /// Send what the target answers as several small messages, some of
    /// them fragmented, so 9P messages span WebSocket messages.
    split: bool = false,
    /// Wait a little before sending what the target answers, so one
    /// WebSocket message can carry several 9P messages.
    coalesce: bool = false,
    /// Select the 9p subprotocol when it's offered.
    subprotocol: bool = true,
    /// A header line, `Name: value`, the handshake must carry, or it's
    /// answered 401.
    require_header: ?[]const u8 = null,
    /// Answer every handshake with this status instead of 101.
    status: ?u16 = null,
    /// Don't answer pings.
    no_pong: bool = false,
    /// Send this text message right after the handshake.
    send_text: ?[]const u8 = null,
    /// Echo each message back with its type instead of relaying.
    echo: bool = false,
};

pub const Relay = struct {
    io: Io,
    opts: Options,
    server: net.Server,
    port: u16,
    url_buf: [64]u8 = undefined,
    lock: std.atomic.Mutex = .unlocked,
    /// Handshakes accepted.
    accepted: std.atomic.Value(u32) = .init(0),
    /// Pings received.
    pings: std.atomic.Value(u32) = .init(0),
    /// While set, what the target answers is held back.
    paused: std.atomic.Value(bool) = .init(false),
    /// The last handshake's header lines (`Name: value\n`) and target.
    last_headers: [2048]u8 = undefined,
    last_headers_len: usize = 0,
    last_target: [256]u8 = undefined,
    last_target_len: usize = 0,
    /// Open connections, so `hangupAll` can close them.
    conns: [16]?net.Stream = @splat(null),

    pub fn start(rl: *Relay, io: Io, port: u16, opts: Options) !void {
        const addr: net.IpAddress = .{ .ip4 = .loopback(port) };
        rl.* = .{ .io = io, .opts = opts, .server = try addr.listen(io, .{ .reuse_address = true }), .port = 0 };
        rl.port = rl.server.socket.address.getPort();
        const t = try std.Thread.spawn(.{}, serve, .{rl});
        t.detach();
    }

    /// `ws://127.0.0.1:PORT/9p`.
    pub fn url(rl: *Relay) []const u8 {
        return std.fmt.bufPrint(&rl.url_buf, "ws://127.0.0.1:{d}/9p", .{rl.port}) catch unreachable;
    }

    /// The last handshake's value of header `name`, or null.
    pub fn header(rl: *Relay, name: []const u8) ?[]const u8 {
        var q: ws.Request = .{};
        rl.locked();
        defer rl.lock.unlock();
        q.headers = rl.last_headers[0..rl.last_headers_len];
        return q.header(name);
    }

    pub fn target(rl: *Relay) []const u8 {
        return rl.last_target[0..rl.last_target_len];
    }

    /// Sends a close (1001) on every open connection and shuts it down.
    pub fn hangupAll(rl: *Relay) void {
        rl.locked();
        defer rl.lock.unlock();
        for (&rl.conns) |*slot| if (slot.*) |st| {
            var b: [125]u8 = undefined;
            var w = st.writer(rl.io, &.{});
            ws.writeFrame(&w.interface, .close, ws.closePayload(&b, 1001, "going away"), null) catch {};
            st.shutdown(rl.io, .both) catch {};
            slot.* = null;
        };
    }

    /// Stops accepting. Open connections run on until their peers end.
    pub fn stop(rl: *Relay) void {
        rl.server.socket.close(rl.io);
    }

    fn locked(rl: *Relay) void {
        while (!rl.lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn serve(rl: *Relay) void {
        while (true) {
            const st = rl.server.accept(rl.io) catch return;
            const t = std.Thread.spawn(.{}, conn, .{ rl, st }) catch {
                st.close(rl.io);
                continue;
            };
            t.detach();
        }
    }

    fn track(rl: *Relay, st: net.Stream, add: bool) void {
        rl.locked();
        defer rl.lock.unlock();
        for (&rl.conns) |*slot| {
            if (add and slot.* == null) {
                slot.* = st;
                return;
            }
            if (!add and slot.* != null and slot.*.?.socket.handle == st.socket.handle) {
                slot.* = null;
                return;
            }
        }
    }

    fn conn(rl: *Relay, st: net.Stream) void {
        const io = rl.io;
        defer st.close(io);
        var ib: [16384]u8 = undefined;
        var ob: [16384]u8 = undefined;
        var sr = st.reader(io, &ib);
        var sw = st.writer(io, &ob);
        const r = &sr.interface;
        var q: ws.Request = .{};
        ws.readRequest(r, &q) catch return;
        {
            rl.locked();
            defer rl.lock.unlock();
            rl.last_headers_len = @min(q.headers.len, rl.last_headers.len);
            @memcpy(rl.last_headers[0..rl.last_headers_len], q.headers[0..rl.last_headers_len]);
            rl.last_target_len = @min(q.target.len, rl.last_target.len);
            @memcpy(rl.last_target[0..rl.last_target_len], q.target[0..rl.last_target_len]);
        }
        if (rl.opts.status) |s| {
            ws.writeStatus(&sw.interface, s, reasonFor(s)) catch {};
            return;
        }
        if (rl.opts.require_header) |want| {
            const colon = std.mem.indexOfScalar(u8, want, ':') orelse return;
            const got = q.header(want[0..colon]) orelse "";
            if (!std.mem.eql(u8, got, std.mem.trim(u8, want[colon + 1 ..], " "))) {
                ws.writeStatus(&sw.interface, 401, "Unauthorized") catch {};
                return;
            }
        }
        const backend: ?net.Stream = if (rl.opts.echo) null else blk: {
            const ip: net.IpAddress = .{ .ip4 = .loopback(rl.opts.target_port) };
            break :blk ip.connect(io, .{ .mode = .stream }) catch {
                ws.writeStatus(&sw.interface, 502, "Bad Gateway") catch {};
                return;
            };
        };
        defer if (backend) |b| b.close(io);
        var c: Conn = .{ .rl = rl, .w = &sw.interface };
        ws.writeAccept(c.w, q.key, if (rl.opts.subprotocol and q.offers(ws.subprotocol)) ws.subprotocol else null) catch return;
        _ = rl.accepted.fetchAdd(1, .acq_rel);
        rl.track(st, true);
        defer rl.track(st, false);
        if (rl.opts.send_text) |t| c.send(.text, t) catch return;
        var down: ?std.Thread = null;
        if (backend) |b| down = std.Thread.spawn(.{}, Conn.fromTarget, .{ &c, b }) catch return;
        defer if (down) |t| {
            if (backend) |b| b.shutdown(io, .both) catch {};
            t.join();
        };
        var bw_buf: [16384]u8 = undefined;
        var bw: net.Stream.Writer = undefined;
        if (backend) |b| bw = b.writer(io, &bw_buf);
        var rc: ws.Receiver = .{ .side = .server };
        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(gpa);
        var op: ws.Opcode = .binary;
        while (true) {
            const f = rc.next(r) catch return;
            if (f.first and !f.opcode.isControl()) {
                msg.clearRetainingCapacity();
                op = f.opcode;
            }
            const at = msg.items.len;
            msg.resize(gpa, at + @as(usize, @intCast(f.len))) catch return;
            ws.readPayload(r, f, 0, msg.items[at..]) catch return;
            switch (f.opcode) {
                .ping => {
                    _ = rl.pings.fetchAdd(1, .acq_rel);
                    if (!rl.opts.no_pong) c.send(.pong, msg.items[at..]) catch return;
                    msg.shrinkRetainingCapacity(at);
                },
                .close => {
                    c.send(.close, msg.items[at..]) catch {};
                    return;
                },
                .pong => msg.shrinkRetainingCapacity(at),
                else => {
                    if (backend != null) {
                        // A relay passes binary payload bytes as they come.
                        bw.interface.writeAll(msg.items[at..]) catch return;
                        bw.interface.flush() catch return;
                        msg.shrinkRetainingCapacity(at);
                    } else if (f.fin) c.send(op, msg.items) catch return;
                },
            }
        }
    }
};

/// One connection's sending side, shared by its two threads.
const Conn = struct {
    rl: *Relay,
    w: *Io.Writer,
    lock: std.atomic.Mutex = .unlocked,

    fn send(c: *Conn, op: ws.Opcode, payload: []const u8) !void {
        while (!c.lock.tryLock()) std.atomic.spinLoopHint();
        defer c.lock.unlock();
        try ws.writeFrame(c.w, op, payload, null);
    }

    /// One message in two frames: `a` and a continuation with `b`.
    fn sendFragmented(c: *Conn, a: []const u8, b: []const u8) !void {
        while (!c.lock.tryLock()) std.atomic.spinLoopHint();
        defer c.lock.unlock();
        try ws.writeHeader(c.w, .{ .fin = false, .opcode = .binary, .len = a.len });
        try c.w.writeAll(a);
        // A ping between the fragments, as a server may send.
        try ws.writeFrame(c.w, .ping, "", null);
        try ws.writeHeader(c.w, .{ .fin = true, .opcode = .continuation, .len = b.len });
        try c.w.writeAll(b);
        try c.w.flush();
    }

    /// Sends what the target writes as binary messages, until it ends.
    fn fromTarget(c: *Conn, b: net.Stream) void {
        const io = c.rl.io;
        var rbuf: [16384]u8 = undefined;
        var r = b.reader(io, &rbuf);
        var pend: Pending = .{};
        defer pend.buf.deinit(gpa);
        const flusher = if (c.rl.opts.coalesce) std.Thread.spawn(.{}, Pending.flushLoop, .{ &pend, c }) catch return else null;
        while (true) {
            const data = r.interface.peekGreedy(1) catch break;
            while (c.rl.paused.load(.acquire)) io.sleep(.fromMilliseconds(10), .awake) catch {};
            if (flusher != null) {
                // Held for the flusher, which sends what's come in every
                // 20 ms as one message.
                while (!pend.lock.tryLock()) std.atomic.spinLoopHint();
                pend.buf.appendSlice(gpa, data) catch {};
                pend.lock.unlock();
            } else c.sendData(data) catch break;
            r.interface.toss(data.len);
        }
        if (flusher) |t| {
            pend.done.store(true, .release);
            t.join();
        }
        var buf: [125]u8 = undefined;
        c.send(.close, ws.closePayload(&buf, 1000, "")) catch {};
    }

    /// Sends `data` as one binary message, or, with `split`, as several
    /// small ones, some of them fragmented.
    fn sendData(c: *Conn, data: []const u8) !void {
        if (!c.rl.opts.split) return c.send(.binary, data);
        var rest = data;
        var i: usize = 0;
        while (rest.len > 0) : (i += 1) {
            const n = @min(rest.len, 5);
            if (i % 2 == 1 and n > 1) {
                try c.sendFragmented(rest[0 .. n / 2], rest[n / 2 .. n]);
            } else try c.send(.binary, rest[0..n]);
            rest = rest[n..];
        }
    }
};

/// What the target has written and `coalesce` hasn't sent yet.
const Pending = struct {
    lock: std.atomic.Mutex = .unlocked,
    buf: std.ArrayList(u8) = .empty,
    done: std.atomic.Value(bool) = .init(false),

    fn flushLoop(p: *Pending, c: *Conn) void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        while (true) {
            c.rl.io.sleep(.fromMilliseconds(20), .awake) catch {};
            const done = p.done.load(.acquire);
            while (!p.lock.tryLock()) std.atomic.spinLoopHint();
            out.clearRetainingCapacity();
            out.appendSlice(gpa, p.buf.items) catch {};
            p.buf.clearRetainingCapacity();
            p.lock.unlock();
            if (out.items.len > 0) c.sendData(out.items) catch return;
            if (done) return;
        }
    }
};

fn reasonFor(status: u16) []const u8 {
    return switch (status) {
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        407 => "Proxy Authentication Required",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        else => "Error",
    };
}

/// An HTTP CONNECT proxy on a loopback port. It counts the tunnels it
/// opens, or answers each CONNECT with `status` if set.
pub const Proxy = struct {
    io: Io,
    server: net.Server,
    port: u16,
    status: ?u16,
    connects: std.atomic.Value(u32) = .init(0),
    url_buf: [64]u8 = undefined,

    pub fn start(p: *Proxy, io: Io, status: ?u16) !void {
        const addr: net.IpAddress = .{ .ip4 = .loopback(0) };
        p.* = .{ .io = io, .server = try addr.listen(io, .{ .reuse_address = true }), .port = 0, .status = status };
        p.port = p.server.socket.address.getPort();
        const t = try std.Thread.spawn(.{}, serve, .{p});
        t.detach();
    }

    /// `http://127.0.0.1:PORT`.
    pub fn url(p: *Proxy) []const u8 {
        return std.fmt.bufPrint(&p.url_buf, "http://127.0.0.1:{d}", .{p.port}) catch unreachable;
    }

    fn serve(p: *Proxy) void {
        while (true) {
            const st = p.server.accept(p.io) catch return;
            const t = std.Thread.spawn(.{}, conn, .{ p, st }) catch {
                st.close(p.io);
                continue;
            };
            t.detach();
        }
    }

    fn conn(p: *Proxy, st: net.Stream) void {
        const io = p.io;
        defer st.close(io);
        var ib: [8192]u8 = undefined;
        var sr = st.reader(io, &ib);
        var sw = st.writer(io, &.{});
        const r = &sr.interface;
        // CONNECT host:port HTTP/1.1, then headers to a blank line.
        const first = r.takeDelimiterInclusive('\n') catch return;
        var parts = std.mem.tokenizeScalar(u8, first, ' ');
        if (!std.mem.eql(u8, parts.next() orelse "", "CONNECT")) return;
        const hostport = parts.next() orelse return;
        const colon = std.mem.lastIndexOfScalar(u8, hostport, ':') orelse return;
        const port = std.fmt.parseInt(u16, hostport[colon + 1 ..], 10) catch return;
        var host_buf: [256]u8 = undefined;
        const host = std.mem.trim(u8, hostport[0..colon], "[]");
        if (host.len > host_buf.len) return;
        @memcpy(host_buf[0..host.len], host);
        while (true) {
            const l = r.takeDelimiterInclusive('\n') catch return;
            if (std.mem.trim(u8, l, "\r\n").len == 0) break;
        }
        if (p.status) |s| {
            sw.interface.print("HTTP/1.1 {d} {s}\r\nContent-Length: 0\r\n\r\n", .{ s, reasonFor(s) }) catch {};
            return;
        }
        const ip = net.IpAddress.parse(host_buf[0..host.len], port) catch {
            sw.interface.writeAll("HTTP/1.1 502 Bad Gateway\r\n\r\n") catch {};
            return;
        };
        const up = ip.connect(io, .{ .mode = .stream }) catch {
            sw.interface.writeAll("HTTP/1.1 502 Bad Gateway\r\n\r\n") catch {};
            return;
        };
        defer up.close(io);
        _ = p.connects.fetchAdd(1, .acq_rel);
        sw.interface.writeAll("HTTP/1.1 200 Connection established\r\n\r\n") catch return;
        // Anything the client sent after the request is in `r`'s buffer.
        const t = std.Thread.spawn(.{}, copy, .{ io, up, st, @as(?*Io.Reader, null) }) catch return;
        copy(io, st, up, r);
        t.join();
    }

    /// Copies `from` (or `pre`, a reader on it holding buffered bytes)
    /// to `to` until EOF, then shuts both down.
    fn copy(io: Io, from: net.Stream, to: net.Stream, pre: ?*Io.Reader) void {
        var rbuf: [8192]u8 = undefined;
        var fr = from.reader(io, &rbuf);
        const r = pre orelse &fr.interface;
        var w = to.writer(io, &.{});
        while (true) {
            const data = r.peekGreedy(1) catch break;
            w.interface.writeAll(data) catch break;
            r.toss(data.len);
        }
        to.shutdown(io, .both) catch {};
        from.shutdown(io, .both) catch {};
    }
};

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) {
        std.debug.print("usage: wsrelay LISTEN_PORT TARGET_PORT\n", .{});
        return 2;
    }
    const listen = std.fmt.parseInt(u16, args[1], 10) catch return 2;
    const to = std.fmt.parseInt(u16, args[2], 10) catch return 2;
    var rl: Relay = undefined;
    try rl.start(init.io, listen, .{ .target_port = to });
    std.debug.print("relaying {s} to 127.0.0.1:{d}\n", .{ rl.url(), to });
    while (true) try init.io.sleep(.fromSeconds(3600), .awake);
}
