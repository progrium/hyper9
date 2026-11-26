//! libh9: h9.Machine behind a C ABI (src/capi/h9.h), built as a shared
//! library by `zig build libh9`, for hosts in other languages, such as
//! Go's github.com/progrium/go-h9. A machine is configured with the h9
//! command's flags, parsed by src/cli.zig, so the ABI stays small while
//! the options grow. What the command does with its environment (H9ROOT,
//! TMPDIR, proxies, the host cwd) the library leaves out, as
//! docs/embedding.md's rules ask.

const std = @import("std");
const builtin = @import("builtin");
const h9 = @import("h9");
const cli = @import("cli.zig");
const Stdin = @import("stdin.zig").Stdin;

const gpa = std.heap.c_allocator;

/// h9.h's H9_ABI_VERSION.
const abi_version = 1;

var threaded: std.Io.Threaded = undefined;
var io_state: std.atomic.Value(u8) = .init(0); // 0 none, 1 initing, 2 ready

fn io() std.Io {
    while (true) switch (io_state.load(.acquire)) {
        2 => return threaded.io(),
        1 => std.atomic.spinLoopHint(),
        else => if (io_state.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
            threaded = .init(gpa, .{});
            io_state.store(2, .release);
        },
    };
}

/// h9 installs a few signal handlers of its own (std.Io.Threaded's SIGIO
/// and SIGPIPE, and KVM's kick signal) without SA_ONSTACK. A Go host
/// requires it on every handler, since a signal can land on a goroutine's
/// small stack, so after each machine is made they're put back with it.
fn onStack() void {
    if (builtin.os.tag == .windows) return;
    const posix = std.posix;
    var sigs: [3]c_int = .{ @intFromEnum(posix.SIG.IO), @intFromEnum(posix.SIG.PIPE), 0 };
    var n: usize = 2;
    if (builtin.os.tag == .linux) {
        sigs[2] = @as(c_int, std.c.sigrtmin()) + 1;
        n = 3;
    }
    for (sigs[0..n]) |sig| {
        var act: std.c.Sigaction = undefined;
        if (std.c.sigaction(@fromBackingInt(@intCast(sig)), null, &act) != 0) continue;
        const h = act.handler.handler;
        if (h == std.c.SIG.DFL or h == std.c.SIG.IGN) continue;
        if (act.flags & std.c.SA.ONSTACK != 0) continue;
        act.flags |= std.c.SA.ONSTACK;
        _ = std.c.sigaction(@fromBackingInt(@intCast(sig)), &act, null);
    }
}

/// cli.parse keeps its mistake in a global.
var parse_lock: std.Io.Mutex = .init;

/// An h9_machine: the machine, and everything its options point at.
const Box = struct {
    arena: std.heap.ArenaAllocator,
    m: h9.Machine,
    signals: h9.Machine.Signals = .{},
    in: Stdin,
    in_buf: [4096]u8,
    out: std.Io.File.Writer,
    err: std.Io.File.Writer,
    discard: std.Io.Writer.Discarding,
    discard_buf: [256]u8,
    running: std.atomic.Value(bool) = .init(false),
};

export fn h9_abi_version() c_int {
    return abi_version;
}

export fn h9_version() [*:0]const u8 {
    return h9.build_info.version ++ "";
}

export fn h9_machine_new(flags: ?[*]const ?[*:0]const u8, nflags: usize, errbuf: ?[*]u8, errcap: usize) ?*Box {
    const eb: []u8 = if (errbuf) |p| p[0..errcap] else &.{};
    const box = gpa.create(Box) catch {
        fail(eb, "out of memory");
        return null;
    };
    box.arena = .init(gpa);
    newMachine(box, if (flags) |f| f[0..nflags] else &.{}, eb) catch {
        box.arena.deinit();
        gpa.destroy(box);
        return null;
    };
    return box;
}

fn newMachine(box: *Box, flags: []const ?[*:0]const u8, eb: []u8) error{Failed}!void {
    const arena = box.arena.allocator();
    const oom = struct {
        fn f(e: []u8) error{Failed} {
            fail(e, "out of memory");
            return error.Failed;
        }
    }.f;
    var opts = options(arena, flags, eb) catch |e| return if (e == error.OutOfMemory) oom(eb) else error.Failed;

    // Each run sets its own (h9_machine_run).
    box.discard = .init(&box.discard_buf);
    opts.stdio = .{ .out = &box.discard.writer, .err = &box.discard.writer };
    box.signals = .{};
    opts.signals = &box.signals;
    box.running = .init(false);

    var conflict: []const u8 = "";
    box.m = h9.Machine.initExplained(gpa, io(), opts, &conflict) catch |e| {
        if (conflict.len > 0) fail(eb, conflict) else fail(eb, @errorName(e));
        return error.Failed;
    };
    onStack();
}

fn writer(w: *std.Io.File.Writer, fd: isize) ?*std.Io.Writer {
    if (fd == -1) return null;
    const file: std.Io.File = .{ .handle = fdOf(fd), .flags = .{ .nonblocking = false } };
    w.* = file.writerStreaming(io(), &.{});
    return &w.interface;
}

fn fdOf(fd: isize) std.Io.File.Handle {
    return if (builtin.os.tag == .windows) @ptrFromInt(@as(usize, @bitCast(fd))) else @intCast(fd);
}

const OptionsError = error{ Usage, OutOfMemory };

/// The machine's options from h9's flags, resolved as src/main.zig
/// resolves the command's, without its environment.
fn options(arena: std.mem.Allocator, flags: []const ?[*:0]const u8, eb: []u8) OptionsError!h9.Machine.Options {
    // cli.parse wants a program; "--" and a placeholder end the flags, and
    // a stray argument among them shows up in argv.
    const args = try arena.alloc([]const u8, flags.len + 3);
    args[0] = "h9";
    for (flags, args[1 .. flags.len + 1]) |f, *a| a.* = std.mem.span(f orelse {
        fail(eb, "a flag is NULL");
        return error.Usage;
    });
    args[flags.len + 1] = "--";
    args[flags.len + 2] = "_";
    const c = blk: {
        parse_lock.lockUncancelable(io());
        defer parse_lock.unlock(io());
        break :blk cli.parse(arena, args) catch |e| {
            if (e == error.Usage) {
                if (cli.why.len > 0) failf(eb, "{s}", .{cli.why}) else failf(eb, "bad flags: {s}; MANUAL.md has h9's flags", .{
                    std.mem.join(arena, " ", args[1 .. flags.len + 1]) catch "",
                });
            }
            return e;
        };
    };
    if (c.argv.len != 1) return usage(eb, "{s} isn't a flag", .{c.argv[0]});
    if (c.mode != .run) return usage(eb, "--check, --version, and --help are the command's", .{});
    if (c.rc != null or c.rc_login) return usage(eb, "--rc is the command's: run rc with -c", .{});
    if (c.print) return usage(eb, "--print is the command's", .{});
    if (c.gfx != null) return usage(eb, "--gfx isn't in libh9 yet", .{});
    if (c.serve.len > 0) return usage(eb, "--serve isn't in libh9 yet", .{});
    if (c.trace != null) return usage(eb, "--trace isn't in libh9 yet", .{});
    if (c.cred.len > 0) return usage(eb, "--cred isn't in libh9 yet", .{});

    var mounts: std.ArrayList(h9.Machine.Mount) = .empty;
    var on_root = false;
    for (c.mounts) |m| {
        if (m.stack()) |st| if (st[0] == .root) {
            on_root = true;
        };
        try mounts.append(arena, try resolveMount(arena, m, eb));
    }
    // The command's $H9ROOT is the caller's to pass as a flag.
    if (!on_root) try mounts.insert(arena, 0, .{ .kind = .builtin, .order = .after });

    var env: std.ArrayList(h9.EnvVar) = .empty;
    for (c.env) |e| {
        const eq = std.mem.indexOfScalar(u8, e, '=').?;
        try env.append(arena, .{ .name = e[0..eq], .value = e[eq + 1 ..] });
    }
    const cwd: ?[]const u8 = if (c.sandbox orelse c.cwd) |p| try resolve(arena, p, false, eb) else null;

    var ns: std.ArrayList([]const u8) = .empty;
    for (c.ns) |v| {
        if (v[0] != '@') {
            try ns.append(arena, v);
            continue;
        }
        try ns.append(arena, try readFile(arena, v[1..], "--ns", eb));
    }

    var opts: h9.Machine.Options = .{
        .engine = c.engine,
        .arch = c.arch,
        .mounts = mounts.items,
        .binds = c.binds,
        .index = switch (c.index) {
            .auto => .auto,
            .none => .none,
        },
        .root_index = rootIndex(mounts.items),
        .index_cache = c.index_cache,
        .verbose = c.verbose,
        .cwd = cwd,
        .env = env.items,
        .ns = ns.items,
        .console_tty = false,
        .user_map = if (c.user_map) |p| try readFile(arena, p, "--user-map", eb) else null,
        .policy = .{
            .profile = c.profile,
            .readable = try resolveAll(arena, c.readable, false, eb),
            .writable = try resolveAll(arena, c.writable, false, eb),
            .read_deny = try resolveAll(arena, c.read_deny, true, eb),
            .write = c.write,
            .net = c.net,
            .net_allow = c.net_allow,
            .memory = c.memory,
            .timeout_ns = c.timeout_ns,
            .pids = c.pids,
            .cpus = c.cpus,
            .cwd_writable = if (c.sandbox != null) true else null,
            .host_fs = c.host_fs,
        },
        .guest_tools = c.guest_tools,
        .stdio = undefined,
    };
    if (h9.Machine.hasLinux(opts)) opts.nameservers = try nameservers(arena);
    return opts;
}

fn resolveMount(arena: std.mem.Allocator, given: h9.Machine.Mount, eb: []u8) OptionsError!h9.Machine.Mount {
    var m = given;
    switch (m.kind) {
        // An archive is read from the host as is; a tree is bound through
        // #U, which takes Windows paths as /C:/a/b.
        .dir => m.src = try resolve(arena, m.src, false, eb),
        .archive => m.src = realPath(arena, m.src) catch return usage(eb, "--archive {s}: not found", .{m.src}),
        .url => {
            if (std.mem.startsWith(u8, m.src, "port://")) return usage(eb, "--url {s}: ports are only on the web host", .{m.src});
            var headers: std.ArrayList([]const u8) = .empty;
            for (m.headers) |h| {
                if (h[0] != '@') {
                    try headers.append(arena, try header(m.src, h, eb));
                    continue;
                }
                var lines = std.mem.splitScalar(u8, try readFile(arena, h[1..], "header=", eb), '\n');
                while (lines.next()) |l| {
                    if (std.mem.trim(u8, l, " \t\r").len == 0) continue;
                    try headers.append(arena, try header(m.src, l, eb));
                }
            }
            m.headers = headers.items;
            if (m.ca) |ca| m.ca = realPath(arena, ca) catch return usage(eb, "--url {s}: ca={s}: not found", .{ m.src, ca });
        },
        .builtin, .tmp, .fd => {},
    }
    return m;
}

/// A header line, `Name: value`, trimmed.
fn header(src: []const u8, line: []const u8, eb: []u8) OptionsError![]const u8 {
    const l = std.mem.trim(u8, line, " \t\r");
    const colon = std.mem.indexOfScalar(u8, l, ':') orelse return usage(eb, "--url {s}: a header is Name: value", .{src});
    if (colon == 0 or std.mem.indexOfAny(u8, l, "\r\n") != null) return usage(eb, "--url {s}: a header is Name: value", .{src});
    return l;
}

/// The `index=` of the first 9P member of `/`, as src/main.zig reads it.
fn rootIndex(mounts: []const h9.Machine.Mount) ?h9.Machine.RootIndex {
    const a = for (mounts) |m| {
        if (m.kind == .url or m.kind == .fd) if (m.stack()) |st| if (st[0] == .root) break m.index;
    } else null;
    const v = a orelse return null;
    if (std.mem.startsWith(u8, v, "https://") or std.mem.startsWith(u8, v, "http://")) return .{ .url = v };
    return .{ .path = v };
}

fn resolveAll(arena: std.mem.Allocator, paths: []const []const u8, may_miss: bool, eb: []u8) OptionsError![]const []const u8 {
    const out = try arena.alloc([]const u8, paths.len);
    for (paths, out) |p, *o| o.* = try resolve(arena, p, may_miss, eb);
    return out;
}

/// A host path as the kernel takes it: absolute, symlinks resolved, and
/// /C:/a/b on Windows. With `may_miss`, one that isn't there yet is
/// resolved through its parent.
fn resolve(arena: std.mem.Allocator, p: []const u8, may_miss: bool, eb: []u8) OptionsError![]const u8 {
    const real = realPath(arena, p) catch blk: {
        if (may_miss) if (realPath(arena, std.fs.path.dirname(p) orelse ".")) |parent| {
            break :blk try std.fs.path.join(arena, &.{ parent, std.fs.path.basename(p) });
        } else |_| {};
        return usage(eb, "{s}: not found", .{p});
    };
    return kernPath(arena, real);
}

fn realPath(arena: std.mem.Allocator, p: []const u8) ![]u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(io(), p, arena);
}

fn kernPath(arena: std.mem.Allocator, p: []const u8) OptionsError![]const u8 {
    if (builtin.os.tag != .windows) return p;
    const out = try arena.alloc(u8, p.len + 1);
    out[0] = '/';
    for (p, out[1..]) |ch, *o| o.* = if (ch == '\\') '/' else ch;
    if (out.len >= 3 and out[2] == ':') out[1] = std.ascii.toUpper(out[1]);
    return if (out.len == 4 and out[3] == '/') out[0..3] else out;
}

fn readFile(arena: std.mem.Allocator, p: []const u8, what: []const u8, eb: []u8) OptionsError![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io(), p, arena, .limited(1 << 20)) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => usage(eb, "{s} {s}: can't read it", .{ what, p }),
    };
}

/// The host's DNS servers for a Linux root, as src/main.zig finds them.
fn nameservers(arena: std.mem.Allocator) error{OutOfMemory}![]const []const u8 {
    const fallback: []const []const u8 = &.{ "8.8.8.8", "8.8.4.4" };
    const text = std.Io.Dir.cwd().readFileAlloc(io(), "/etc/resolv.conf", arena, .limited(64 << 10)) catch return fallback;
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        var f = std.mem.tokenizeAny(u8, l, " \t\r");
        const key = f.next() orelse continue;
        if (!std.mem.eql(u8, key, "nameserver")) continue;
        const a = f.next() orelse continue;
        if (std.mem.indexOfScalar(u8, a, '%') != null) continue;
        if (h9.policy.parseIp(a) == null) continue;
        try out.append(arena, a);
    }
    return if (out.items.len > 0) out.items else fallback;
}

export fn h9_machine_free(box: ?*Box) void {
    const b = box orelse return;
    // A stuck run's process may still touch the streams, the arguments,
    // and the box, so a stuck machine is left as it is.
    if (b.m.stuck) return;
    b.m.deinit();
    b.arena.deinit();
    gpa.destroy(b);
}

export fn h9_machine_engine(box: *Box) [*:0]const u8 {
    return switch (box.m.engine.kind()) {
        inline else => |k| @tagName(k),
    };
}

export fn h9_machine_arch(box: *Box) [*:0]const u8 {
    return switch (box.m.arch) {
        .arm64 => "arm64",
        .amd64 => "amd64",
        .i386 => "386",
    };
}

export fn h9_machine_run(box: *Box, argv: ?[*]const ?[*:0]const u8, argc: usize, aout: ?[*]const u8, aoutlen: usize, in: isize, out: isize, err: isize, status: ?[*]u8, statuscap: usize) c_int {
    const st: []u8 = if (status) |p| p[0..statuscap] else &.{};
    if (argc == 0 or argv == null) return failRun(st, "no argv[0]");
    if (box.running.swap(true, .acq_rel)) return failRun(st, "the machine is already running a program");
    defer box.running.store(false, .release);

    var stack: [64][]const u8 = undefined;
    const args: [][]const u8 = if (argc <= stack.len) stack[0..argc] else gpa.alloc([]const u8, argc) catch return failRun(st, "out of memory");
    defer if (argc > stack.len) gpa.free(args);
    for (argv.?[0..argc], args) |a, *o| o.* = std.mem.span(a orelse return failRun(st, "an argument is NULL"));

    const prog: h9.Program = if (aout) |p| blk: {
        const bytes = p[0..aoutlen];
        const arch = h9.linux_elf.machineArch(bytes) orelse
            (h9.aout.parse(bytes) catch return failRun(st, "not an a.out or ELF")).arch;
        if (arch != box.m.arch) {
            var buf: [128]u8 = undefined;
            return failRun(st, std.fmt.bufPrint(&buf, "the program is {s}, and the machine runs {s}; pass --arch {s}", .{ arch.name(), box.m.arch.name(), arch.name() }) catch "wrong architecture");
        }
        break :blk .{ .bytes = bytes };
    } else .{ .guest = args[0] };

    // The console's host side, for this run. The machine reads
    // `opts.stdio` as a run starts.
    box.m.opts.stdio = .{
        .out = writer(&box.out, out) orelse &box.discard.writer,
        .err = writer(&box.err, err) orelse &box.discard.writer,
    };
    if (in != -1) {
        box.in.initFd(io(), &box.in_buf, fdOf(in));
        box.m.opts.stdio.in = box.in.reader();
        box.m.opts.stdio.in_cancel = .{ .ctx = &box.in, .func = Stdin.cancel, .reset = Stdin.reset };
    }
    // A stuck run's process may still read `in`, so its wake pipe stays.
    defer if (in != -1 and !box.m.stuck) box.in.deinit();

    const s = box.m.run(prog, args) catch |e|
        return failRun(st, if (box.m.err_msg.len > 0) box.m.err_msg else @errorName(e));
    return switch (s) {
        .exited => |msg| blk: {
            fail(st, msg);
            break :blk 0;
        },
        .killed => |msg| blk: {
            fail(st, msg);
            break :blk 1;
        },
    };
}

export fn h9_machine_signal(box: *Box, sig: c_int) void {
    switch (sig) {
        0 => box.signals.interrupt(io()),
        1 => box.signals.hangup(io()),
        2 => box.signals.stop(io()),
        else => {},
    }
}

/// Copies `msg` into `buf`, NUL-terminated and cut to fit.
fn fail(buf: []u8, msg: []const u8) void {
    if (buf.len == 0) return;
    const n = @min(msg.len, buf.len - 1);
    @memcpy(buf[0..n], msg[0..n]);
    buf[n] = 0;
}

fn failf(buf: []u8, comptime fmt: []const u8, args: anytype) void {
    var tmp: [512]u8 = undefined;
    fail(buf, std.fmt.bufPrint(&tmp, fmt, args) catch &tmp);
}

fn usage(buf: []u8, comptime fmt: []const u8, args: anytype) error{Usage} {
    failf(buf, fmt, args);
    return error.Usage;
}

fn failRun(buf: []u8, msg: []const u8) c_int {
    fail(buf, msg);
    return -1;
}
