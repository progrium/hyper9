//! Time limits for the tests' listeners and reads, so a peer that never
//! connects or never answers fails the test instead of hanging the suite.
//!
//! It waits with poll rather than Io cancellation: in Zig 0.16 cancelling
//! an Io.Threaded group can walk a worker thread that has already exited and
//! crash. On Windows a socket is an AFD handle that WSAPoll can't take, so
//! there's no limit there.

const std = @import("std");
const builtin = @import("builtin");
const net = std.Io.net;
const Io = std.Io;

/// How long a test waits for a connection or for data.
pub const limit_ms = 30_000;

/// Accepts the next connection, or fails with error.Timeout when none
/// arrives within `limit_ms`.
pub fn accept(srv: *net.Server, io: Io) !net.Stream {
    try waitReadable(srv.socket.handle, limit_ms);
    return srv.accept(io);
}

/// Waits up to `ms` milliseconds for `handle` to be readable (a queued
/// connection, data or EOF), else fails with error.Timeout. Returns right
/// away on Windows.
pub fn waitReadable(handle: net.Socket.Handle, ms: i32) !void {
    if (builtin.os.tag == .windows) return;
    var fds = [_]std.posix.pollfd{.{ .fd = handle, .events = std.posix.POLL.IN, .revents = 0 }};
    if (try std.posix.poll(&fds, ms) == 0) return error.Timeout;
    // Closed under us, as a relay's `stop` does while its thread waits:
    // accepting on it would be a use after close.
    if (fds[0].revents & std.posix.POLL.NVAL != 0) return error.Closed;
}

fn listen(io: Io) !net.Server {
    const addr = try net.IpAddress.parse("127.0.0.1", 0);
    return addr.listen(io, .{ .reuse_address = true });
}

test "a listener nobody connects to times out" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var srv = try listen(io);
    defer srv.deinit(io);
    try std.testing.expectError(error.Timeout, waitReadable(srv.socket.handle, 100));
}

test "accept takes a queued connection" {
    const io = std.testing.io;
    var srv = try listen(io);
    defer srv.deinit(io);
    const c = try srv.socket.address.connect(io, .{ .mode = .stream });
    defer c.close(io);
    const s = try accept(&srv, io);
    s.close(io);
}

test "a read times out without data and goes on after the peer writes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var srv = try listen(io);
    defer srv.deinit(io);
    const c = try srv.socket.address.connect(io, .{ .mode = .stream });
    defer c.close(io);
    const s = try accept(&srv, io);
    defer s.close(io);
    try std.testing.expectError(error.Timeout, waitReadable(s.socket.handle, 100));
    var wbuf: [8]u8 = undefined;
    var w = c.writer(io, &wbuf);
    try w.interface.writeAll("x");
    try w.interface.flush();
    try waitReadable(s.socket.handle, limit_ms);
}
