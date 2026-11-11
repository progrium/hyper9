//! A 9P2000.L server on a loopback port for the `[dotl]` cases
//! (design/dotl.md): src/dotl/testserver.zig's tree in memory, made
//! fresh for each connection by `fill`. No host 9P2000.L server (diod,
//! zerofs) is needed.

const std = @import("std");
const dotl = @import("dotltest");
const deadline = @import("deadline.zig");

pub const Server = dotl.Server;
pub const Fill = *const fn (s: *Server) anyerror!void;

/// Reads what the connection has, 0 at its end. Through Io, which reads a
/// socket on Windows too, where std.posix.read can't.
fn readSome(io: std.Io, conn: std.Io.net.Stream, buf: []u8) !usize {
    var r = conn.reader(io, &.{});
    var bufs = [_][]u8{buf};
    return r.interface.readVec(&bufs) catch |e| switch (e) {
        error.EndOfStream => 0,
        else => e,
    };
}

pub const DotlServer = struct {
    srv: std.Io.net.Server,
    fill: Fill,
    version: []const u8 = "9P2000.L",
    thread: std.Thread = undefined,
    stop: std.atomic.Value(bool) = .init(false),
    /// The uname and n_uname of the last attach, for the user-map cases.
    uname: [64]u8 = undefined,
    uname_len: usize = 0,
    n_uname: u32 = 0,
    attached: std.atomic.Value(bool) = .init(false),
    dial_buf: [64]u8 = undefined,
    /// One tree for every connection, made by `startShared`: a new
    /// connection is the server restarting with its files kept, as for
    /// the 9P2000.L.Z cases. Used under `mu`.
    shared: ?*Server = null,
    mu: std.atomic.Mutex = .unlocked,
    connections: std.atomic.Value(u32) = .init(0),

    pub fn start(d: *DotlServer, io: std.Io, fill: Fill) !void {
        const ip = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        d.* = .{ .srv = try ip.listen(io, .{ .reuse_address = true }), .fill = fill };
        d.thread = try std.Thread.spawn(.{}, serve, .{ d, io });
    }

    /// Like `start`, with one tree made by `fill` for every connection,
    /// speaking `version`.
    pub fn startShared(d: *DotlServer, io: std.Io, fill: Fill, version: []const u8) !void {
        const ip = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        d.* = .{ .srv = try ip.listen(io, .{ .reuse_address = true }), .fill = fill };
        const s = try Server.init(std.heap.smp_allocator);
        s.version = version;
        try fill(s);
        d.shared = s;
        d.thread = try std.Thread.spawn(.{}, serve, .{ d, io });
    }

    /// The shared tree, locked until `unlock`.
    pub fn lock(d: *DotlServer) *Server {
        while (!d.mu.tryLock()) std.atomic.spinLoopHint();
        return d.shared.?;
    }

    pub fn unlock(d: *DotlServer) void {
        d.mu.unlock();
    }

    pub fn port(d: *const DotlServer) u16 {
        return d.srv.socket.address.getPort();
    }

    pub fn dial(d: *DotlServer) []const u8 {
        return std.fmt.bufPrint(&d.dial_buf, "tcp!127.0.0.1!{d}", .{d.port()}) catch unreachable;
    }

    pub fn finish(d: *DotlServer, io: std.Io) void {
        d.stop.store(true, .release);
        // Wake the accept.
        if (std.Io.net.IpAddress.parse("127.0.0.1", d.port())) |ip| {
            if (ip.connect(io, .{ .mode = .stream })) |c| c.close(io) else |_| {}
        } else |_| {}
        d.thread.join();
        d.srv.deinit(io);
        if (d.shared) |s| {
            _ = d.lock();
            s.deinit();
            d.shared = null;
            d.unlock();
        }
    }

    pub fn unameSeen(d: *const DotlServer) []const u8 {
        return d.uname[0..d.uname_len];
    }

    fn serve(d: *DotlServer, io: std.Io) void {
        while (!d.stop.load(.acquire)) {
            const conn = d.srv.accept(io) catch return;
            if (d.stop.load(.acquire)) {
                conn.close(io);
                return;
            }
            // One thread per connection: a root's stays open for the run.
            const t = std.Thread.spawn(.{}, oneThenClose, .{ d, io, conn }) catch {
                conn.close(io);
                continue;
            };
            t.detach();
        }
    }

    fn oneThenClose(d: *DotlServer, io: std.Io, conn: std.Io.net.Stream) void {
        d.one(io, conn) catch {};
        conn.close(io);
    }

    fn one(d: *DotlServer, io: std.Io, conn: std.Io.net.Stream) !void {
        _ = d.connections.fetchAdd(1, .acq_rel);
        if (d.shared != null) return d.oneShared(io, conn);
        const gpa = std.heap.smp_allocator;
        const s = try Server.init(gpa);
        defer s.deinit();
        s.version = d.version;
        try d.fill(s);
        var rbuf: [1 << 16]u8 = undefined;
        var wbuf: [1 << 16]u8 = undefined;
        var w = conn.writer(io, &wbuf);
        while (true) {
            deadline.waitReadable(conn.socket.handle, deadline.limit_ms) catch return;
            const n = readSome(io, conn, &rbuf) catch return;
            if (n == 0) return;
            try s.feed(rbuf[0..n]);
            if (s.attached_as) |a| {
                d.uname_len = @min(a[0].len, d.uname.len);
                @memcpy(d.uname[0..d.uname_len], a[0][0..d.uname_len]);
                d.n_uname = a[1];
                d.attached.store(true, .release);
            }
            if (s.out.items.len != 0) {
                try w.interface.writeAll(s.out.items);
                try w.interface.flush();
                s.out.items.len = 0;
            }
        }
    }

    fn oneShared(d: *DotlServer, io: std.Io, conn: std.Io.net.Stream) !void {
        {
            const s = d.lock();
            defer d.unlock();
            s.reset();
        }
        var rbuf: [1 << 16]u8 = undefined;
        var wbuf: [1 << 16]u8 = undefined;
        var w = conn.writer(io, &wbuf);
        while (true) {
            deadline.waitReadable(conn.socket.handle, deadline.limit_ms) catch return;
            const n = readSome(io, conn, &rbuf) catch return;
            if (n == 0) return;
            const s = d.lock();
            defer d.unlock();
            try s.feed(rbuf[0..n]);
            if (s.out.items.len != 0) {
                try w.interface.writeAll(s.out.items);
                try w.interface.flush();
                s.out.items.len = 0;
            }
            // A crash: the connection goes without the last answer.
            if (s.dropped) return;
        }
    }
};
