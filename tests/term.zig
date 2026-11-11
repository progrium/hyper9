//! Runs a program on a terminal the test controls: a pty on Linux and
//! macOS, a pseudoconsole (ConPTY) on Windows. Tests type into it, wait for
//! output and hang it up, the way a user at a terminal would, so raw mode,
//! Ctrl-C and hangups can be checked without a human or an ssh -t session.
//!
//! The program is a session leader with the terminal as its controlling
//! terminal, so a 0x03 typed in cooked mode reaches it as SIGINT (or
//! CTRL_C_EVENT on Windows), and closing the terminal sends SIGHUP (or
//! CTRL_CLOSE_EVENT).

const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

pub const Error = error{ TermFailed, Timeout, Exited } || std.mem.Allocator.Error;

pub const Term = struct {
    gpa: std.mem.Allocator,
    /// Everything the program has written, with \r\n left as is.
    out: std.ArrayList(u8) = .empty,
    /// Where the next `expect` starts looking.
    mark: usize = 0,
    /// Exit code once the program has exited.
    code: ?u8 = null,
    sys: Sys,

    /// Starts `argv` (argv[0] a path) on a new 80x25 terminal.
    pub fn spawn(gpa: std.mem.Allocator, argv: []const []const u8) !Term {
        return spawnEnv(gpa, argv, &.{});
    }

    /// `spawn`, with `extra` (NAME=value strings) added to the program's
    /// environment. Windows takes none yet.
    pub fn spawnEnv(gpa: std.mem.Allocator, argv: []const []const u8, extra: []const []const u8) !Term {
        return .{ .gpa = gpa, .sys = try Sys.spawn(gpa, argv, extra) };
    }

    /// Kills the program if it's still running and frees everything.
    pub fn deinit(t: *Term) void {
        t.sys.deinit(t.code == null);
        t.out.deinit(t.gpa);
    }

    /// Types `bytes`. "\x03" is Ctrl-C.
    pub fn send(t: *Term, bytes: []const u8) !void {
        try t.sys.write(bytes);
    }

    /// Waits until `needle` appears in the output after the last match,
    /// and moves past it.
    pub fn expect(t: *Term, needle: []const u8, timeout_ms: u32) !void {
        const deadline = now() + timeout_ms;
        while (true) {
            if (std.mem.indexOfPos(u8, t.out.items, t.mark, needle)) |i| {
                t.mark = i + needle.len;
                return;
            }
            if (t.code != null) {
                dump(t, needle);
                return error.Exited;
            }
            const left = deadline -| now();
            if (left == 0) {
                dump(t, needle);
                return error.Timeout;
            }
            try t.pump(@min(left, 50));
        }
    }

    /// Reads output for `ms` milliseconds.
    pub fn drain(t: *Term, ms: u32) !void {
        const deadline = now() + ms;
        while (now() < deadline) try t.pump(@min(deadline -| now(), 50));
    }

    /// Waits for the program to exit, reading its output meanwhile.
    pub fn wait(t: *Term, timeout_ms: u32) !u8 {
        const deadline = now() + timeout_ms;
        while (t.code == null) {
            const left = deadline -| now();
            if (left == 0) {
                dump(t, "(exit)");
                return error.Timeout;
            }
            try t.pump(@min(left, 50));
        }
        return t.code.?;
    }

    /// Closes the terminal, as when its window is closed: SIGHUP on POSIX,
    /// CTRL_CLOSE_EVENT on Windows. Output can't be read after this.
    pub fn hangup(t: *Term) void {
        t.sys.hangup();
    }

    /// Sends a signal to the program (POSIX only).
    pub fn signal(t: *Term, sig: std.posix.SIG) void {
        if (is_windows) @compileError("no signals on Windows");
        _ = std.c.kill(t.sys.pid, sig);
    }

    /// Whether the terminal is in cooked mode with echo (POSIX only;
    /// always true on Windows, which keeps no such state on our side).
    pub fn cooked(t: *Term) bool {
        return t.sys.cooked();
    }

    /// Whether the terminal keeps its lines with echo off, as a password
    /// prompt sets it (POSIX only; always true on Windows).
    pub fn noEcho(t: *Term) bool {
        return t.sys.noEcho();
    }

    /// Whether the terminal is in raw mode, with or without echo (POSIX
    /// only; always true on Windows).
    pub fn raw(t: *Term) bool {
        return t.sys.raw();
    }

    /// Whether the terminal echoes (POSIX only; always true on Windows).
    pub fn echo(t: *Term) bool {
        return t.sys.echo();
    }

    fn pump(t: *Term, ms: u32) !void {
        var buf: [4096]u8 = undefined;
        const n = try t.sys.read(&buf, ms);
        try t.out.appendSlice(t.gpa, buf[0..n]);
        if (t.code == null) t.code = t.sys.poll();
    }

    fn dump(t: *Term, needle: []const u8) void {
        std.debug.print("term: waiting for \"{f}\"; output so far:\n{f}\n", .{
            std.ascii.hexEscape(needle, .lower), std.ascii.hexEscape(t.out.items, .lower),
        });
    }
};

extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

fn now() u64 {
    if (is_windows) return GetTickCount64();
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

const Sys = if (is_windows) Windows else Posix;

const Posix = struct {
    const c = std.c;
    extern "c" fn posix_openpt(flags: c_int) c_int;
    extern "c" fn grantpt(fd: c_int) c_int;
    extern "c" fn unlockpt(fd: c_int) c_int;
    extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;
    // std.c declares ioctl's request as c_int, which can't hold Darwin's
    // TIOCSWINSZ (its top bit of 32 is set); Darwin's libc takes an
    // unsigned long.
    extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

    /// TIOCSWINSZ: _IOW('t', 103, struct winsize) on macOS and the BSDs.
    const TIOCSWINSZ: c_ulong = switch (builtin.os.tag) {
        .linux => 0x5414,
        else => 0x80087467,
    };

    const TIOCSCTTY: c_int = switch (builtin.os.tag) {
        .linux => 0x540E,
        else => 0x20007461, // _IO('t', 97) on macOS and the BSDs
    };

    master: c_int,
    pid: c.pid_t,

    fn spawn(gpa: std.mem.Allocator, argv: []const []const u8, extra: []const []const u8) !Posix {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        // Everything the child needs is prepared before fork, since only
        // async-signal-safe calls are allowed after it.
        const args = try arena.allocSentinel(?[*:0]const u8, argv.len, null);
        for (argv, 0..) |a, i| args[i] = try arena.dupeZ(u8, a);
        // The inherited environment, less the names `extra` sets, then
        // `extra`.
        var envs: std.ArrayList(?[*:0]const u8) = .empty;
        var i: usize = 0;
        inherited: while (c.environ[i]) |v| : (i += 1) {
            const kv = std.mem.span(v);
            for (extra) |x| {
                const name = x[0 .. (std.mem.indexOfScalar(u8, x, '=') orelse x.len) + 1];
                if (std.mem.startsWith(u8, kv, name)) continue :inherited;
            }
            try envs.append(arena, v);
        }
        for (extra) |x| try envs.append(arena, try arena.dupeZ(u8, x));
        const envp = try envs.toOwnedSliceSentinel(arena, null);

        const o: c.O = .{ .ACCMODE = .RDWR, .NOCTTY = true };
        const master = posix_openpt(@bitCast(o));
        if (master < 0) return error.TermFailed;
        errdefer _ = c.close(master);
        if (grantpt(master) != 0 or unlockpt(master) != 0) return error.TermFailed;
        const name = try arena.dupeZ(u8, std.mem.span(ptsname(master) orelse return error.TermFailed));
        _ = c.fcntl(master, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
        // 80x25, as the Windows pseudoconsole is. It's set on the slave
        // once the child has opened it: macOS resets a pty's size at the
        // slave's first open, so a size set on the master before that is
        // lost.
        var ws: std.posix.winsize = .{ .row = 25, .col = 80, .xpixel = 0, .ypixel = 0 };

        const pid = c.fork();
        if (pid < 0) return error.TermFailed;
        if (pid == 0) {
            _ = c.setsid();
            const slave = c.open(name, .{ .ACCMODE = .RDWR });
            if (slave < 0) c._exit(126);
            _ = ioctl(slave, TIOCSWINSZ, &ws);
            _ = c.ioctl(slave, TIOCSCTTY, @as(c_int, 0));
            for (0..3) |fd| _ = c.dup2(slave, @intCast(fd));
            if (slave > 2) _ = c.close(slave);
            _ = c.execve(args[0].?, args.ptr, @ptrCast(envp.ptr));
            c._exit(127);
        }
        return .{ .master = master, .pid = pid };
    }

    fn deinit(p: *Posix, kill: bool) void {
        if (kill) {
            _ = c.kill(p.pid, .KILL);
            var st: c_int = 0;
            _ = c.waitpid(p.pid, &st, 0);
        }
        if (p.master >= 0) _ = c.close(p.master);
    }

    fn write(p: *Posix, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = c.write(p.master, bytes[off..].ptr, bytes.len - off);
            if (n <= 0) return error.TermFailed;
            off += @intCast(n);
        }
    }

    /// Reads what's there within `ms`; 0 bytes on timeout or once the
    /// program has closed the terminal (Linux reports that as EIO).
    fn read(p: *Posix, buf: []u8, ms: u32) !usize {
        if (p.master < 0) {
            sleepMs(ms);
            return 0;
        }
        var fds = [1]c.pollfd{.{ .fd = p.master, .events = c.POLL.IN, .revents = 0 }};
        if (c.poll(&fds, 1, @intCast(ms)) <= 0) return 0;
        const n = c.read(p.master, buf.ptr, buf.len);
        if (n <= 0) {
            // Nothing more will come; don't spin on a closed terminal.
            sleepMs(ms);
            return 0;
        }
        return @intCast(n);
    }

    fn poll(p: *Posix) ?u8 {
        var st: c_int = 0;
        const r = c.waitpid(p.pid, &st, c.W.NOHANG);
        if (r != p.pid) return null;
        const s: u32 = @bitCast(st);
        if (c.W.IFEXITED(s)) return c.W.EXITSTATUS(s);
        return 128 +| @as(u8, @truncate(@intFromEnum(c.W.TERMSIG(s))));
    }

    fn hangup(p: *Posix) void {
        if (p.master >= 0) _ = c.close(p.master);
        p.master = -1;
    }

    fn cooked(p: *Posix) bool {
        var t: c.termios = undefined;
        if (c.tcgetattr(p.master, &t) != 0) return false;
        return t.lflag.ICANON and t.lflag.ECHO;
    }

    fn noEcho(p: *Posix) bool {
        var t: c.termios = undefined;
        if (c.tcgetattr(p.master, &t) != 0) return false;
        return t.lflag.ICANON and !t.lflag.ECHO;
    }

    fn raw(p: *Posix) bool {
        var t: c.termios = undefined;
        if (c.tcgetattr(p.master, &t) != 0) return false;
        return !t.lflag.ICANON;
    }

    fn echo(p: *Posix) bool {
        var t: c.termios = undefined;
        if (c.tcgetattr(p.master, &t) != 0) return false;
        return t.lflag.ECHO;
    }

    fn sleepMs(ms: u32) void {
        const ts: c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast(@as(u64, ms % 1000) * std.time.ns_per_ms) };
        _ = c.nanosleep(&ts, null);
    }
};

const Windows = struct {
    const w = std.os.windows;
    const HANDLE = w.HANDLE;
    const BOOL = w.BOOL;
    const DWORD = w.DWORD;
    const HPCON = *anyopaque;

    const STARTUPINFOEXW = extern struct {
        StartupInfo: w.STARTUPINFOW,
        lpAttributeList: ?*anyopaque,
    };
    const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
    const STILL_ACTIVE: DWORD = 259;

    extern "kernel32" fn CreatePipe(r: *HANDLE, wr: *HANDLE, sa: ?*w.SECURITY_ATTRIBUTES, size: DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn CreatePseudoConsole(size: w.COORD, in: HANDLE, out: HANDLE, flags: DWORD, pc: *HPCON) callconv(.winapi) i32;
    extern "kernel32" fn ClosePseudoConsole(pc: HPCON) callconv(.winapi) void;
    extern "kernel32" fn InitializeProcThreadAttributeList(list: ?*anyopaque, count: DWORD, flags: DWORD, size: *usize) callconv(.winapi) BOOL;
    extern "kernel32" fn UpdateProcThreadAttribute(list: *anyopaque, flags: DWORD, attr: usize, value: ?*const anyopaque, size: usize, prev: ?*anyopaque, ret: ?*usize) callconv(.winapi) BOOL;
    extern "kernel32" fn DeleteProcThreadAttributeList(list: *anyopaque) callconv(.winapi) void;
    extern "kernel32" fn PeekNamedPipe(h: HANDLE, buf: ?*anyopaque, size: DWORD, read: ?*DWORD, avail: ?*DWORD, left: ?*DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, n: DWORD, read: ?*DWORD, ov: ?*anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, n: DWORD, written: ?*DWORD, ov: ?*anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn GetExitCodeProcess(h: HANDLE, code: *DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn TerminateProcess(h: HANDLE, code: u32) callconv(.winapi) BOOL;
    extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: DWORD) callconv(.winapi) DWORD;
    extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;

    pc: ?HPCON,
    in: HANDLE,
    out: ?HANDLE,
    process: HANDLE,

    fn spawn(gpa: std.mem.Allocator, argv: []const []const u8, extra: []const []const u8) !Windows {
        if (extra.len != 0) return error.Unsupported;
        var in_r: HANDLE = undefined;
        var in_w: HANDLE = undefined;
        var out_r: HANDLE = undefined;
        var out_w: HANDLE = undefined;
        if (!CreatePipe(&in_r, &in_w, null, 0).toBool()) return error.TermFailed;
        if (!CreatePipe(&out_r, &out_w, null, 0).toBool()) return error.TermFailed;
        var pc: HPCON = undefined;
        const hr = CreatePseudoConsole(.{ .X = 80, .Y = 25 }, in_r, out_w, 0, &pc);
        // The pseudoconsole holds its own handles to these ends.
        _ = CloseHandle(in_r);
        _ = CloseHandle(out_w);
        if (hr != 0) return error.TermFailed;
        errdefer ClosePseudoConsole(pc);

        var size: usize = 0;
        _ = InitializeProcThreadAttributeList(null, 1, 0, &size);
        const list = try gpa.alignedAlloc(u8, .of(usize), size);
        defer gpa.free(list);
        if (!InitializeProcThreadAttributeList(list.ptr, 1, 0, &size).toBool()) return error.TermFailed;
        defer DeleteProcThreadAttributeList(list.ptr);
        if (!UpdateProcThreadAttribute(list.ptr, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, pc, @sizeOf(HPCON), null, null).toBool())
            return error.TermFailed;

        var si: STARTUPINFOEXW = std.mem.zeroes(STARTUPINFOEXW);
        si.StartupInfo.cb = @sizeOf(STARTUPINFOEXW);
        // Without this, a child of a process whose stdio is redirected (the
        // test runner under ssh) inherits those handles instead of the
        // pseudoconsole's. Null handles make it use the pseudoconsole.
        si.StartupInfo.dwFlags = w.STARTF_USESTDHANDLES;
        si.lpAttributeList = list.ptr;
        var pi: w.PROCESS.INFORMATION = undefined;
        const cmd = try commandLine(gpa, argv);
        defer gpa.free(cmd);
        if (!w.kernel32.CreateProcessW(null, cmd.ptr, null, null, .FALSE, .{ .extended_startupinfo_present = true, .create_unicode_environment = false }, null, null, &si.StartupInfo, &pi).toBool())
            return error.TermFailed;
        _ = CloseHandle(pi.hThread);
        return .{ .pc = pc, .in = in_w, .out = out_r, .process = pi.hProcess };
    }

    /// Quotes argv for CommandLineToArgvW and the C runtime.
    fn commandLine(gpa: std.mem.Allocator, argv: []const []const u8) ![:0]u16 {
        var s: std.ArrayList(u8) = .empty;
        defer s.deinit(gpa);
        for (argv, 0..) |a, i| {
            if (i > 0) try s.append(gpa, ' ');
            const plain = a.len > 0 and std.mem.indexOfAny(u8, a, " \t\"") == null;
            if (plain) {
                try s.appendSlice(gpa, a);
                continue;
            }
            try s.append(gpa, '"');
            var slashes: usize = 0;
            for (a) |ch| {
                if (ch == '\\') {
                    slashes += 1;
                    continue;
                }
                const n = if (ch == '"') slashes * 2 + 1 else slashes;
                try s.appendNTimes(gpa, '\\', n);
                slashes = 0;
                try s.append(gpa, ch);
            }
            try s.appendNTimes(gpa, '\\', slashes * 2);
            try s.append(gpa, '"');
        }
        return std.unicode.wtf8ToWtf16LeAllocZ(gpa, s.items);
    }

    fn deinit(p: *Windows, kill: bool) void {
        if (kill) {
            _ = TerminateProcess(p.process, 1);
            _ = WaitForSingleObject(p.process, 5000);
        }
        p.closeConsole();
        _ = CloseHandle(p.in);
        _ = CloseHandle(p.process);
    }

    /// ClosePseudoConsole waits for conhost, which may block writing
    /// output nobody reads, so the output is drained meanwhile.
    fn closeConsole(p: *Windows) void {
        const pc = p.pc orelse return;
        p.pc = null;
        const out = p.out;
        p.out = null;
        const Drain = struct {
            fn run(h: HANDLE) void {
                var buf: [4096]u8 = undefined;
                var n: DWORD = 0;
                while (ReadFile(h, &buf, buf.len, &n, null).toBool() and n > 0) {}
            }
        };
        const t = if (out) |h| std.Thread.spawn(.{}, Drain.run, .{h}) catch null else null;
        ClosePseudoConsole(pc);
        if (t) |th| th.join();
        if (out) |h| _ = CloseHandle(h);
    }

    fn write(p: *Windows, bytes: []const u8) !void {
        var n: DWORD = 0;
        if (!WriteFile(p.in, bytes.ptr, @intCast(bytes.len), &n, null).toBool() or n != bytes.len) return error.TermFailed;
    }

    fn read(p: *Windows, buf: []u8, ms: u32) !usize {
        const h = p.out orelse {
            Sleep(ms);
            return 0;
        };
        var waited: u32 = 0;
        while (true) {
            var avail: DWORD = 0;
            if (!PeekNamedPipe(h, null, 0, null, &avail, null).toBool()) {
                Sleep(ms -| waited);
                return 0;
            }
            if (avail > 0) {
                var n: DWORD = 0;
                if (!ReadFile(h, buf.ptr, @min(avail, @as(DWORD, @intCast(buf.len))), &n, null).toBool()) return 0;
                return n;
            }
            if (waited >= ms) return 0;
            Sleep(10);
            waited += 10;
        }
    }

    fn poll(p: *Windows) ?u8 {
        var code: DWORD = 0;
        if (!GetExitCodeProcess(p.process, &code).toBool() or code == STILL_ACTIVE) return null;
        return @truncate(code);
    }

    fn hangup(p: *Windows) void {
        p.closeConsole();
    }

    fn cooked(_: *Windows) bool {
        return true;
    }

    fn noEcho(_: *Windows) bool {
        return true;
    }

    fn raw(_: *Windows) bool {
        return true;
    }

    fn echo(_: *Windows) bool {
        return true;
    }
};
