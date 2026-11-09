//! The CLI's host terminal and signals (SPEC.md, "Signals and TTY"):
//! Ctrl-C, hangup and raw mode for one running machine.
//!
//! Handlers only record the event and wake a watcher thread, which calls
//! `Machine.Signals`; `Machine.run` posts the notes. On POSIX the handlers
//! write a byte to a self-pipe (the one thing a signal handler may safely
//! do); on Windows the console control handler runs on its own thread and
//! calls the watcher's code directly.
//!
//! - Ctrl-C (SIGINT, CTRL_C_EVENT, CTRL_BREAK_EVENT) posts `interrupt` to
//!   the foreground note group. A second one within a second tears the
//!   machine down.
//! - SIGHUP, SIGTERM (CTRL_CLOSE_EVENT, CTRL_LOGOFF_EVENT,
//!   CTRL_SHUTDOWN_EVENT) post `hangup` to every process; the machine is
//!   torn down after its grace period.
//! - Raw mode: termios without ICANON, ECHO and ISIG, or a console without
//!   line input, echo and processed input. The original mode is restored
//!   when the guest turns raw off, when the run ends, and on a panic.

const std = @import("std");
const builtin = @import("builtin");
const h9 = @import("h9");
const Signal = @import("cli.zig").Signal;

const is_windows = builtin.os.tag == .windows;

/// The one instance, for the signal handlers and the panic handler.
var current: ?*Host = null;

pub const Host = struct {
    io: std.Io,
    signals: h9.Machine.Signals = .{},
    /// When the last Ctrl-C came, for the "second within a second" rule;
    /// in ms on the awake clock, 0 for none.
    last_interrupt_ms: i64 = 0,
    /// The host signal that started a teardown, for the exit code of a
    /// run that ends `h9: machine stopped` (design/0033-exit-status.md): INT for
    /// a second Ctrl-C, HUP or TERM for a hangup. 0 until one does; the
    /// first one wins.
    stop_signal: std.atomic.Value(u8) = .init(0),
    sys: Sys = .{},

    /// Installs the handlers and starts the watcher. Call `deinit` before
    /// the Host goes away.
    pub fn init(h: *Host, io: std.Io) void {
        h.* = .{ .io = io };
        current = h;
        h.sys.init(h);
    }

    /// Restores the terminal and the default signal handling.
    pub fn deinit(h: *Host) void {
        h.sys.deinit();
        current = null;
    }

    /// For `Machine.Stdio.raw`.
    pub fn raw(h: *Host) h9.Machine.Raw {
        return .{ .ctx = h, .set = setRaw, .echo = setEcho, .crnl = setCrnl, .size = size };
    }

    fn setCrnl(ctx: *anyopaque, on: bool) void {
        const h: *Host = @ptrCast(@alignCast(ctx));
        h.sys.setCrnl(on);
    }

    fn size(ctx: *anyopaque) ?[2]u16 {
        const h: *Host = @ptrCast(@alignCast(ctx));
        return h.sys.size();
    }

    fn setRaw(ctx: *anyopaque, on: bool) void {
        const h: *Host = @ptrCast(@alignCast(ctx));
        h.sys.setRaw(on);
    }

    fn setEcho(ctx: *anyopaque, on: bool) void {
        const h: *Host = @ptrCast(@alignCast(ctx));
        h.sys.setEcho(on);
    }

    /// The host signal that started the machine's teardown, if any.
    pub fn stoppedBy(h: *const Host) ?Signal {
        return std.enums.fromInt(Signal, h.stop_signal.load(.acquire));
    }

    fn recordStop(h: *Host, sig: Signal) void {
        _ = h.stop_signal.cmpxchgStrong(0, @intFromEnum(sig), .acq_rel, .acquire);
    }

    fn interrupt(h: *Host) void {
        const now = std.Io.Timestamp.now(h.io, .awake).toMilliseconds();
        if (h.last_interrupt_ms != 0 and now - h.last_interrupt_ms < std.time.ms_per_s) {
            h.recordStop(.INT);
            h.signals.stop(h.io);
        } else {
            h.signals.interrupt(h.io);
        }
        h.last_interrupt_ms = now;
    }

    /// `sig` is HUP or TERM.
    fn hangup(h: *Host, sig: Signal) void {
        h.recordStop(sig);
        h.signals.hangup(h.io);
    }
};

/// Restores the terminal if raw mode or echo off is on. Called from the panic handler,
/// so a crash never leaves the user's terminal raw.
pub fn restoreTerminal() void {
    if (current) |h| {
        h.sys.setRaw(false);
        h.sys.setEcho(true);
    }
}

const Sys = if (is_windows) Windows else Posix;

const Posix = struct {
    const c = std.c;
    const posix = std.posix;

    pipe: [2]posix.fd_t = .{ -1, -1 },
    thread: ?std.Thread = null,
    /// The terminal's mode before raw mode or echo off, while either is on.
    saved: ?c.termios = null,
    raw: bool = false,
    no_echo: bool = false,
    /// Raw mode without ICRNL: Enter reaches the guest as CR.
    no_crnl: bool = false,
    lock: std.atomic.Mutex = .unlocked,
    old: [3]posix.Sigaction = undefined,

    const sigs = [_]posix.SIG{ .INT, .HUP, .TERM };
    const ev_interrupt = 'i';
    const ev_hangup = 'h';
    const ev_term = 't';
    const ev_quit = 'q';

    var wake_fd: posix.fd_t = -1;

    fn init(s: *Posix, h: *Host) void {
        var fds: [2]posix.fd_t = undefined;
        if (c.pipe(&fds) != 0) return;
        for (fds) |fd| _ = c.fcntl(fd, posix.F.SETFD, @as(c_int, posix.FD_CLOEXEC));
        // The handler must never block on a full pipe.
        const fl = c.fcntl(fds[1], posix.F.GETFL);
        _ = c.fcntl(fds[1], posix.F.SETFL, fl | @as(c_int, @bitCast(posix.O{ .NONBLOCK = true })));
        s.pipe = fds;
        wake_fd = fds[1];
        s.thread = std.Thread.spawn(.{}, watch, .{ s, h }) catch {
            _ = c.close(fds[0]);
            _ = c.close(fds[1]);
            s.pipe = .{ -1, -1 };
            wake_fd = -1;
            return;
        };
        const act: posix.Sigaction = .{
            .handler = .{ .handler = handler },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.RESTART,
        };
        for (sigs, &s.old) |sig, *o| posix.sigaction(sig, &act, o);
        // A blocked mask is inherited across exec (test runners and some
        // shells block signals), so unblock the ones handled here.
        var set = posix.sigemptyset();
        for (sigs) |sig| posix.sigaddset(&set, sig);
        posix.sigprocmask(posix.SIG.UNBLOCK, &set, null);
    }

    fn deinit(s: *Posix) void {
        s.setRaw(false);
        s.setEcho(true);
        if (s.thread) |t| {
            for (sigs, &s.old) |sig, *o| posix.sigaction(sig, o, null);
            _ = c.write(s.pipe[1], &[_]u8{ev_quit}, 1);
            t.join();
            wake_fd = -1;
            _ = c.close(s.pipe[0]);
            _ = c.close(s.pipe[1]);
        }
    }

    fn handler(sig: posix.SIG) callconv(.c) void {
        const ev: u8 = switch (sig) {
            .INT => ev_interrupt,
            .TERM => ev_term,
            else => ev_hangup,
        };
        const fd = wake_fd;
        if (fd >= 0) {
            const e = c._errno().*;
            _ = c.write(fd, &[_]u8{ev}, 1);
            c._errno().* = e;
        }
    }

    fn watch(s: *Posix, h: *Host) void {
        var buf: [64]u8 = undefined;
        while (true) {
            const n = c.read(s.pipe[0], &buf, buf.len);
            if (n < 0) {
                if (c._errno().* == @intFromEnum(posix.E.INTR)) continue;
                return;
            }
            if (n == 0) return;
            for (buf[0..@intCast(n)]) |ev| switch (ev) {
                ev_interrupt => h.interrupt(),
                ev_hangup => h.hangup(.HUP),
                ev_term => h.hangup(.TERM),
                ev_quit => return,
                else => {},
            };
        }
    }

    fn lockSpin(s: *Posix) void {
        while (!s.lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn setRaw(s: *Posix, on: bool) void {
        s.lockSpin();
        defer s.lock.unlock();
        s.raw = on;
        s.apply(.FLUSH);
    }

    /// Echo off with the line discipline kept, as `stty -echo` and
    /// password prompts ask for.
    fn setEcho(s: *Posix, on: bool) void {
        s.lockSpin();
        defer s.lock.unlock();
        s.no_echo = !on;
        s.apply(.NOW);
    }

    /// CR to NL mapping in raw mode, as the guest's ICRNL asks.
    fn setCrnl(s: *Posix, on: bool) void {
        s.lockSpin();
        defer s.lock.unlock();
        s.no_crnl = !on;
        if (s.raw) s.apply(.NOW);
    }

    /// The terminal's rows and columns, from stdout or else stdin.
    fn size(_: *Posix) ?[2]u16 {
        for ([_]posix.fd_t{ posix.STDOUT_FILENO, posix.STDIN_FILENO }) |fd| {
            var ws: posix.winsize = undefined;
            if (c.ioctl(fd, c.T.IOCGWINSZ, &ws) == 0 and ws.row != 0 and ws.col != 0) return .{ ws.row, ws.col };
        }
        return null;
    }

    /// Sets the terminal from the mode it had before h9 changed it.
    fn apply(s: *Posix, when: c.TCSA) void {
        const fd = posix.STDIN_FILENO;
        if (!s.raw and !s.no_echo) {
            if (s.saved) |t| {
                var tt = t;
                _ = c.tcsetattr(fd, when, &tt);
                s.saved = null;
            }
            return;
        }
        if (s.saved == null) {
            var t: c.termios = undefined;
            if (c.tcgetattr(fd, &t) != 0) return;
            s.saved = t;
        }
        var t = s.saved.?;
        // Raw mode keeps echo unless it's off too: 9front's rawon turns
        // both off (src/kern.zig), a Linux program can ask for either.
        t.lflag.ECHO = !s.no_echo;
        if (s.raw) {
            t.lflag.ICANON = false;
            t.lflag.ISIG = false;
            if (s.no_crnl) t.iflag.ICRNL = false;
            t.cc[@intFromEnum(c.V.MIN)] = 1;
            t.cc[@intFromEnum(c.V.TIME)] = 0;
        }
        _ = c.tcsetattr(fd, when, &t);
    }
};

const Windows = struct {
    const w = std.os.windows;
    const DWORD = w.DWORD;
    const BOOL = w.BOOL;

    extern "kernel32" fn SetConsoleCtrlHandler(handler: ?*const fn (DWORD) callconv(.winapi) BOOL, add: BOOL) callconv(.winapi) BOOL;
    extern "kernel32" fn GetConsoleMode(h: w.HANDLE, mode: *DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn SetConsoleMode(h: w.HANDLE, mode: DWORD) callconv(.winapi) BOOL;

    const CTRL_C_EVENT = 0;
    const CTRL_BREAK_EVENT = 1;
    const CTRL_CLOSE_EVENT = 2;
    const CTRL_LOGOFF_EVENT = 5;
    const CTRL_SHUTDOWN_EVENT = 6;

    const ENABLE_PROCESSED_INPUT: DWORD = 0x0001;
    const ENABLE_LINE_INPUT: DWORD = 0x0002;
    const ENABLE_ECHO_INPUT: DWORD = 0x0004;
    const ENABLE_VIRTUAL_TERMINAL_INPUT: DWORD = 0x0200;

    installed: bool = false,
    saved: ?DWORD = null,
    raw: bool = false,
    no_echo: bool = false,
    lock: std.atomic.Mutex = .unlocked,

    fn init(s: *Windows, _: *Host) void {
        // A process inherits "ignore Ctrl-C" from its parent (OpenSSH sets
        // it, for one), as POSIX inherits a blocked signal mask.
        _ = SetConsoleCtrlHandler(null, .FALSE);
        s.installed = SetConsoleCtrlHandler(handler, .TRUE).toBool();
    }

    fn deinit(s: *Windows) void {
        s.setRaw(false);
        s.setEcho(true);
        if (s.installed) _ = SetConsoleCtrlHandler(handler, .FALSE);
    }

    /// Runs on a thread Windows creates for each event.
    fn handler(ev: DWORD) callconv(.winapi) BOOL {
        const h = current orelse return .FALSE;
        switch (ev) {
            CTRL_C_EVENT, CTRL_BREAK_EVENT => h.interrupt(),
            CTRL_CLOSE_EVENT, CTRL_LOGOFF_EVENT, CTRL_SHUTDOWN_EVENT => {
                // Closing the console is a terminal hangup; logoff and
                // shutdown are what SIGTERM is for on POSIX.
                h.hangup(if (ev == CTRL_CLOSE_EVENT) .HUP else .TERM);
                // Returning lets Windows end the process at once, so wait
                // here for the grace period, while the machine handles the
                // hangup; Windows allows about 5 s.
                var i: u32 = 0;
                while (i < 45 and current != null) : (i += 1) std.Io.sleep(h.io, .fromMilliseconds(100), .awake) catch {};
            },
            else => return .FALSE,
        }
        return .TRUE;
    }

    /// The console's input mode isn't changed for ICRNL; Windows passes
    /// Enter as CR in raw mode already.
    fn setCrnl(_: *Windows, _: bool) void {}

    /// Not known here yet: TIOCGWINSZ answers 80x24.
    fn size(_: *Windows) ?[2]u16 {
        return null;
    }

    fn lockSpin(s: *Windows) void {
        while (!s.lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn setRaw(s: *Windows, on: bool) void {
        s.lockSpin();
        defer s.lock.unlock();
        s.raw = on;
        s.apply();
    }

    fn setEcho(s: *Windows, on: bool) void {
        s.lockSpin();
        defer s.lock.unlock();
        s.no_echo = !on;
        s.apply();
    }

    fn apply(s: *Windows) void {
        const in = w.peb().ProcessParameters.hStdInput;
        if (!s.raw and !s.no_echo) {
            if (s.saved) |mode| {
                _ = SetConsoleMode(in, mode);
                s.saved = null;
            }
            return;
        }
        if (s.saved == null) {
            var mode: DWORD = 0;
            if (!GetConsoleMode(in, &mode).toBool()) return;
            s.saved = mode;
        }
        const mode = s.saved.?;
        const m = if (s.raw)
            (mode & ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT)) | ENABLE_VIRTUAL_TERMINAL_INPUT
        else
            mode & ~ENABLE_ECHO_INPUT;
        _ = SetConsoleMode(in, m);
    }
};
