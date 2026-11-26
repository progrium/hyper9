//! The host's stdin as a `std.Io.Reader`, for the guest's console, with a
//! `cancel` that makes a blocked read return (`h9.consin.Cancel`), so a
//! run can end while the console's reader thread is in a read. `initFd`
//! reads another descriptor (or HANDLE) the same way, for libh9
//! (src/capi.zig).
//!
//! On POSIX the reader polls stdin together with a wake pipe, and `cancel`
//! writes to the pipe. Where poll can't wait on stdin (macOS reports
//! POLLNVAL for devices such as /dev/null) it reads without polling.
//!
//! On Windows, std reads with NtReadFile and treats STATUS_PENDING as
//! unreachable, which a console handle under a pseudoconsole (Windows
//! Terminal, OpenSSH, ConPTY) can return, so the reader calls ReadFile,
//! which waits for the read, and `cancel` ends it with CancelSynchronousIo.
//! A console in line mode ends each line with \r\n; the reader turns that
//! into \n, as a POSIX terminal does, so rc doesn't see a stray \r.

const std = @import("std");
const builtin = @import("builtin");

pub const Stdin = if (builtin.os.tag == .windows) WindowsStdin else PosixStdin;

const PosixStdin = struct {
    const posix = std.posix;

    /// The wake pipe, or -1s if it couldn't be made (reads then can't be
    /// cancelled).
    wake: [2]posix.fd_t = .{ -1, -1 },
    fd: posix.fd_t = posix.STDIN_FILENO,
    interface: std.Io.Reader,

    pub fn init(s: *PosixStdin, io: std.Io, buf: []u8) void {
        s.initFd(io, buf, posix.STDIN_FILENO);
    }

    /// Reads `fd` instead of stdin. The caller keeps it open, and closes
    /// it; `deinit` closes only the wake pipe.
    pub fn initFd(s: *PosixStdin, _: std.Io, buf: []u8, src: posix.fd_t) void {
        s.* = .{ .fd = src, .interface = .{
            .vtable = &.{ .stream = stream },
            .buffer = buf,
            .seek = 0,
            .end = 0,
        } };
        var fds: [2]posix.fd_t = undefined;
        if (std.c.pipe(&fds) != 0) return;
        for (fds) |fd| _ = std.c.fcntl(fd, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC));
        const fl = std.c.fcntl(fds[0], posix.F.GETFL);
        _ = std.c.fcntl(fds[0], posix.F.SETFL, fl | @as(c_int, @bitCast(posix.O{ .NONBLOCK = true })));
        s.wake = fds;
    }

    pub fn deinit(s: *PosixStdin) void {
        for (s.wake) |fd| if (fd >= 0) {
            _ = std.c.close(fd);
        };
        s.wake = .{ -1, -1 };
    }

    pub fn reader(s: *PosixStdin) *std.Io.Reader {
        return &s.interface;
    }

    /// For `h9.consin.Cancel`: `ctx` is the PosixStdin.
    pub fn cancel(ctx: *anyopaque, _: std.Thread) void {
        const s: *PosixStdin = @ptrCast(@alignCast(ctx));
        if (s.wake[1] >= 0) _ = std.c.write(s.wake[1], "x", 1);
    }

    /// For `h9.consin.Cancel`.
    pub fn reset(ctx: *anyopaque) void {
        const s: *PosixStdin = @ptrCast(@alignCast(ctx));
        if (s.wake[0] >= 0) s.drainWake();
    }

    fn drainWake(s: *PosixStdin) void {
        var b: [64]u8 = undefined;
        while (std.c.read(s.wake[0], &b, b.len) > 0) {}
    }

    fn stream(r: *std.Io.Reader, wr: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const s: *PosixStdin = @alignCast(@fieldParentPtr("interface", r));
        const dest = limit.slice(try wr.writableSliceGreedy(1));
        if (s.wake[0] >= 0) while (true) {
            var fds = [2]posix.pollfd{
                .{ .fd = s.fd, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = s.wake[0], .events = posix.POLL.IN, .revents = 0 },
            };
            _ = posix.poll(&fds, -1) catch break;
            if (fds[1].revents != 0) {
                s.drainWake();
                return error.ReadFailed;
            }
            if (fds[0].revents != 0) break;
        };
        while (true) {
            const n = posix.read(s.fd, dest) catch |err| switch (err) {
                // A non-blocking stdin with nothing to read yet.
                error.WouldBlock => {
                    std.Thread.yield() catch {};
                    continue;
                },
                else => return error.ReadFailed,
            };
            if (n == 0) return error.EndOfStream;
            wr.advance(n);
            return n;
        }
    }
};

const WindowsStdin = struct {
    const w = std.os.windows;
    extern "kernel32" fn ReadFile(h: w.HANDLE, buf: [*]u8, n: w.DWORD, read: ?*w.DWORD, ov: ?*anyopaque) callconv(.winapi) w.BOOL;
    extern "kernel32" fn GetConsoleMode(h: w.HANDLE, mode: *w.DWORD) callconv(.winapi) w.BOOL;
    extern "kernel32" fn CancelSynchronousIo(thread: w.HANDLE) callconv(.winapi) w.BOOL;
    const ERROR_BROKEN_PIPE: w.DWORD = 109;
    const ERROR_HANDLE_EOF: w.DWORD = 38;
    const ERROR_OPERATION_ABORTED: w.DWORD = 995;

    handle: ?w.HANDLE,
    console: bool,
    cancelled: std.atomic.Value(bool) = .init(false),
    interface: std.Io.Reader,

    pub fn init(s: *WindowsStdin, io: std.Io, buf: []u8) void {
        s.initFd(io, buf, w.peb().ProcessParameters.hStdInput);
    }

    /// Reads `handle` instead of stdin. The caller keeps it open.
    pub fn initFd(s: *WindowsStdin, _: std.Io, buf: []u8, handle: ?w.HANDLE) void {
        s.cancelled = .init(false);
        s.handle = handle;
        var mode: w.DWORD = 0;
        s.console = if (s.handle) |h| GetConsoleMode(h, &mode).toBool() else false;
        s.interface = .{
            .vtable = &.{ .stream = stream },
            .buffer = buf,
            .seek = 0,
            .end = 0,
        };
    }

    pub fn deinit(_: *WindowsStdin) void {}

    pub fn reader(s: *WindowsStdin) *std.Io.Reader {
        return &s.interface;
    }

    /// For `h9.consin.Cancel`: `ctx` is the WindowsStdin, and `thread` is
    /// the one reading.
    pub fn cancel(ctx: *anyopaque, thread: std.Thread) void {
        const s: *WindowsStdin = @ptrCast(@alignCast(ctx));
        s.cancelled.store(true, .release);
        _ = CancelSynchronousIo(thread.getHandle());
    }

    /// For `h9.consin.Cancel`.
    pub fn reset(ctx: *anyopaque) void {
        const s: *WindowsStdin = @ptrCast(@alignCast(ctx));
        s.cancelled.store(false, .release);
    }

    fn stream(r: *std.Io.Reader, wr: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const s: *WindowsStdin = @alignCast(@fieldParentPtr("interface", r));
        const h = s.handle orelse return error.EndOfStream;
        const dest = limit.slice(try wr.writableSliceGreedy(1));
        var n: w.DWORD = 0;
        while (true) {
            if (s.cancelled.swap(false, .acq_rel)) return error.ReadFailed;
            if (!ReadFile(h, dest.ptr, std.math.lossyCast(w.DWORD, dest.len), &n, null).toBool()) {
                if (s.cancelled.swap(false, .acq_rel)) return error.ReadFailed;
                return switch (@intFromEnum(w.GetLastError())) {
                    ERROR_BROKEN_PIPE, ERROR_HANDLE_EOF => error.EndOfStream,
                    else => error.ReadFailed,
                };
            }
            // Ctrl-C in a console with processed input ends a pending read
            // with no bytes and ERROR_OPERATION_ABORTED; that isn't EOF.
            if (n == 0 and s.console and @intFromEnum(w.GetLastError()) == ERROR_OPERATION_ABORTED) continue;
            break;
        }
        if (n == 0) return error.EndOfStream;
        var got: usize = n;
        if (s.console) got = crlfToLf(dest[0..n]);
        wr.advance(got);
        return got;
    }

    /// Replaces each \r\n in `b` with \n, in place; returns the new length.
    fn crlfToLf(b: []u8) usize {
        var o: usize = 0;
        for (b, 0..) |c, i| {
            if (c == '\r' and i + 1 < b.len and b[i + 1] == '\n') continue;
            b[o] = c;
            o += 1;
        }
        return o;
    }
};
