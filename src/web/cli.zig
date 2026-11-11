//! The CLI's host side on the web host (design/browser-host.md): its
//! stdin, Ctrl-C and raw mode come from the JS host (h9-web.js), which
//! has them from Node's process or from the page's terminal. Each blocking
//! call is a Suspending import, so it parks only the coroutine making it.

const std = @import("std");
const h9 = @import("h9");
const web = h9.web;
const Signal = @import("../cli.zig").Signal;

const js = struct {
    /// Reads up to `n` bytes of input: the count, 0 at its end, -1 on an
    /// error, or -2 when `cancel_stdin` cut the read short.
    extern "h9" fn read_stdin(p: [*]u8, n: u32) i32;
    extern "h9" fn cancel_stdin() void;
    /// Waits for the next host signal: 1 for interrupt (Ctrl-C or the
    /// page's interrupt key), 2 for hangup, 0 once `stop_signals` is called.
    extern "h9" fn wait_signal() i32;
    extern "h9" fn stop_signals() void;
    extern "h9" fn set_raw(on: u32) void;
};

pub const Stdin = struct {
    interface: std.Io.Reader,

    pub fn init(s: *Stdin, _: std.Io, buf: []u8) void {
        s.* = .{ .interface = .{
            .vtable = &.{ .stream = stream },
            .buffer = buf,
            .seek = 0,
            .end = 0,
        } };
    }

    pub fn reader(s: *Stdin) *std.Io.Reader {
        return &s.interface;
    }

    /// For `h9.consin.Cancel`.
    pub fn cancel(_: *anyopaque, _: web.Thread) void {
        js.cancel_stdin();
    }

    /// For `h9.consin.Cancel`.
    pub fn reset(_: *anyopaque) void {}

    fn stream(_: *std.Io.Reader, wr: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const dest = limit.slice(try wr.writableSliceGreedy(1));
        const n = web.coro.blocking(js.read_stdin, .{ dest.ptr, @as(u32, @intCast(@min(dest.len, std.math.maxInt(u32)))) });
        if (n == 0) return error.EndOfStream;
        if (n < 0) return error.ReadFailed;
        wr.advance(@intCast(n));
        return @intCast(n);
    }
};

/// hostsig.Host's counterpart: a coroutine waits for the JS host's
/// signals and passes them to `Machine.Signals`.
pub const Host = struct {
    io: std.Io,
    signals: h9.Machine.Signals = .{},
    last_interrupt_ms: i64 = 0,
    thread: ?web.Thread = null,
    /// The signal that started the machine's teardown, as hostsig.Host
    /// keeps it, for the exit status.
    stop_signal: ?Signal = null,

    pub fn init(h: *Host, io: std.Io) void {
        h.* = .{ .io = io };
        h.thread = web.Thread.spawn(.{}, watch, .{h}) catch null;
    }

    pub fn deinit(h: *Host) void {
        set(false);
        const t = h.thread orelse return;
        h.thread = null;
        js.stop_signals();
        t.join();
    }

    pub fn raw(h: *Host) h9.Machine.Raw {
        return .{ .ctx = h, .set = setRaw };
    }

    fn setRaw(_: *anyopaque, on: bool) void {
        set(on);
    }

    fn set(on: bool) void {
        js.set_raw(@intFromBool(on));
    }

    /// The host signal that started the machine's teardown, if any.
    pub fn stoppedBy(h: *const Host) ?Signal {
        return h.stop_signal;
    }

    fn recordStop(h: *Host, sig: Signal) void {
        if (h.stop_signal == null) h.stop_signal = sig;
    }

    fn watch(h: *Host) void {
        while (true) switch (web.coro.blocking(js.wait_signal, .{})) {
            1 => {
                // A second interrupt within a second tears the machine down,
                // as a second Ctrl-C does natively.
                const now = std.Io.Timestamp.now(h.io, .awake).toMilliseconds();
                if (h.last_interrupt_ms != 0 and now - h.last_interrupt_ms < std.time.ms_per_s) {
                    h.recordStop(.INT);
                    h.signals.stop(h.io);
                } else h.signals.interrupt(h.io);
                h.last_interrupt_ms = now;
            },
            // Hangup, from SIGHUP (2) or SIGTERM (3) under Node, or the page.
            2, 3 => |n| {
                h.recordStop(if (n == 2) .HUP else .TERM);
                h.signals.hangup(h.io);
            },
            else => return,
        };
    }
};

pub fn restoreTerminal() void {
    Host.set(false);
}
