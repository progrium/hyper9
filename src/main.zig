const std = @import("std");
const builtin = @import("builtin");
const h9 = @import("h9");
const cli = @import("cli.zig");
const tools = @import("tools.zig");
/// The web host (design/epoch-0/browser-host.md) has its stdin, signals and
/// terminal from the JS host.
const web = h9.web.enabled;
const web_cli = @import("web/cli.zig");
const Stdin = if (web) web_cli.Stdin else @import("stdin.zig").Stdin;
const hostsig = if (web) web_cli else @import("hostsig.zig");

/// Restores the host terminal before the default panic output, so a crash
/// in raw mode doesn't leave the user's terminal raw.
pub const panic = std.debug.FullPanic(struct {
    fn f(msg: []const u8, ret_addr: ?usize) noreturn {
        hostsig.restoreTerminal();
        std.debug.defaultPanic(msg, ret_addr);
    }
}.f);

/// On the web host, std.heap.page_allocator is h9's (web/heap.zig), whose
/// memory comes in big steps.
pub const os = if (web) struct {
    pub const heap = struct {
        pub const page_allocator = h9.web.heap.allocator;
    };
} else struct {};

/// Exit codes for h9's own failures (SPEC.md, "Exit codes").
const exit_failed = 125;
const exit_not_executable = 126;
const exit_not_found = 127;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = if (web) h9.web.io() else init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (web) web_pwd = init.environ_map.get("PWD") orelse "/";

    const cfg = cli.parse(arena, args) catch {
        if (cli.why.len > 0) std.debug.print("h9: {s}\n", .{cli.why});
        std.debug.print(cli.usage, .{});
        return 2;
    };
    // The browser host can't listen (design/epoch-0/serve.md).
    if (web and cfg.serve.len > 0) {
        std.debug.print("h9: --serve isn't available on the web host\n", .{});
        return 2;
    }
    switch (cfg.mode) {
        .run => {},
        .help, .version => {
            var buf: [1024]u8 = undefined;
            var w = std.Io.File.stdout().writerStreaming(io, &buf);
            if (cfg.mode == .help) w.interface.writeAll(cli.usage) catch {} else tools.version(&w.interface) catch {};
            w.interface.flush() catch {};
            return 0;
        },
        .check => {
            var root_err: ?[]const u8 = null;
            const ms = resolveMounts(arena, io, cfg, init.environ_map) catch |e| switch (e) {
                error.Usage => return 2,
                error.NotFound => blk: {
                    root_err = "not found";
                    break :blk &.{};
                },
                error.OutOfMemory => return exit_failed,
            };
            var buf: [1024]u8 = undefined;
            var w = std.Io.File.stdout().writerStreaming(io, &buf);
            const code = tools.check(init.gpa, io, &w.interface, .{
                .backend = cfg.backend,
                .arch = cfg.arch,
                .memory = cfg.memory,
                .mounts = ms,
                .root_arg = rootShown(cfg, ms, init.environ_map),
                .root_err = root_err,
                .proxy = proxyFrom(init.environ_map),
                .cred_helpers = credHelpers(arena, cfg, init.environ_map) catch |e| return if (e == error.Usage) 2 else exit_failed,
                .index = switch (cfg.index) {
                    .auto => .auto,
                    .none => .none,
                },
                .root_index = rootIndexArg(rootIndexOf(ms)),
                .index_cache = cfg.index_cache orelse h9.rootindex.cache.Cache.defaultDir(arena, init.environ_map),
            }) catch exit_failed;
            w.interface.flush() catch {};
            return code;
        },
    }
    // --gfx: on macOS AppKit needs the main thread, so the run goes on
    // another (design/epoch-0/gfx.md). Elsewhere this runs it directly.
    if (cfg.gfx != null) {
        var ctx: GfxRun = .{ .init = init, .cfg = cfg };
        h9.gfx.main(GfxRun.work, &ctx);
    }
    return run(init, cfg);
}

const GfxRun = struct {
    init: std.process.Init,
    cfg: cli.Config,

    fn work(p: ?*anyopaque) u8 {
        const g: *GfxRun = @ptrCast(@alignCast(p.?));
        return run(g.init, g.cfg) catch |err| {
            std.debug.print("h9: {t}\n", .{err});
            return 1;
        };
    }
};

/// Runs the program, and returns h9's exit code.
fn run(init: std.process.Init, cfg: cli.Config) !u8 {
    const arena = init.arena.allocator();
    const io = if (web) h9.web.io() else init.io;
    // --rc runs /bin/rc -c; the remaining arguments become $*.
    const argv: []const []const u8 = if (cfg.rc) |cmd| blk: {
        const v = try arena.alloc([]const u8, 3 + cfg.argv.len);
        v[0] = "rc";
        v[1] = "-c";
        v[2] = cmd;
        @memcpy(v[3..], cfg.argv);
        break :blk v;
    } else if (cfg.rc_login)
        // --rc alone is a login rc, which sources /rc/lib/rcmain.local, the
        // root's default command, and then $home/lib/profile
        // (design/epoch-0/default-command.md). rcmain reads them only with -i or
        // -c, and rc can't tell the guest's stdin is a terminal, so h9 asks
        // the host: -i on one, and otherwise -c reading stdin as a script.
        if (std.Io.File.stdin().isTty(io) catch false)
            &.{ "rc", "-l", "-i" }
        else
            &.{ "rc", "-l", "-c", ". /fd/0" }
    else
        cfg.argv;
    // --serve with no program only serves (design/epoch-0/serve.md).
    const serve_only = cfg.serve.len > 0 and argv.len == 0;
    const prog_arg = if (cfg.rc != null or cfg.rc_login) "/bin/rc" else if (serve_only) "serve" else argv[0];

    // A host program is read here; a guest one is resolved in the machine.
    // --arch picks the architecture; without it, a host program's header
    // does, and a guest one runs the host's.
    var arch: ?h9.vmm.Arch = cfg.arch;
    const prog: h9.Program = if (serve_only) .{ .guest = "" } else switch (cli.programKind(prog_arg)) {
        .host => blk: {
            const path = if (web) std.fs.path.resolvePosix(arena, &.{ web_pwd, prog_arg }) catch prog_arg else prog_arg;
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 30)) catch |err| {
                std.debug.print("h9: {s}: {t}\n", .{ prog_arg, err });
                return if (err == error.FileNotFound) exit_not_found else exit_failed;
            };
            if (h9.linux_elf.machineArch(bytes)) |a| {
                if (arch == null) arch = a;
                break :blk .{ .bytes = bytes };
            }
            const hdr = h9.aout.parse(bytes) catch |err| {
                std.debug.print("h9: {s}: not a 9front executable: {t}\n", .{ prog_arg, err });
                return exit_not_executable;
            };
            if (arch == null) arch = hdr.arch;
            break :blk .{ .bytes = bytes };
        },
        .guest => .{ .guest = prog_arg },
    };

    const mounts = resolveMounts(arena, io, cfg, init.environ_map) catch |e| return switch (e) {
        error.Usage => 2,
        error.NotFound, error.OutOfMemory => exit_failed,
    };
    // Only the built-in root on `/`: a missing command's fix is the full
    // tree (design/epoch-0/builtin-root.md).
    const builtin_only = blk: {
        var saw = false;
        for (mounts) |m| if (m.stack()) |st| if (st[0] == .root) {
            if (m.kind != .builtin) break :blk false;
            saw = true;
        };
        break :blk saw;
    };
    // A 9P server on `/` keeps writes under --write=scope.
    const ninep_root = for (mounts) |m| {
        if (m.stack()) |st| if (st[0] == .root and (m.kind == .url or m.kind == .fd)) break true;
    } else false;
    const so = serveOptions(arena, io, cfg) catch |e| return switch (e) {
        error.Usage => 2,
        error.NotFound, error.OutOfMemory => exit_failed,
    };
    // H9_TEST_KEEPALIVE (milliseconds) shortens the WebSocket keepalive's
    // 30 s idle time, so the integration case that waits out a ping and a
    // missed pong takes seconds rather than two minutes. Tests only.
    if (init.environ_map.get("H9_TEST_KEEPALIVE")) |v| {
        if (std.fmt.parseInt(u32, v, 10)) |ms| {
            if (ms > 0) h9.hstream.keepalive_idle_ns = @as(u64, ms) * std.time.ns_per_ms;
        } else |_| {}
    }
    const user_map = if (cfg.user_map) |path| std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch {
        std.debug.print("h9: --user-map {s}: can't read it\n", .{path});
        return exit_failed;
    } else null;
    const cwd_arg = cfg.sandbox orelse cfg.cwd orelse ".";
    const cwd = kernPath(arena, realPath(io, arena, cwd_arg) catch {
        std.debug.print("h9: cwd {s}: not found\n", .{cwd_arg});
        return exit_failed;
    });
    var env: std.ArrayList(h9.EnvVar) = .empty;
    for (cfg.env) |e| {
        const eq = std.mem.indexOfScalar(u8, e, '=').?;
        try env.append(arena, .{ .name = e[0..eq], .value = e[eq + 1 ..] });
    }

    const pol: h9.Policy = .{
        .profile = cfg.profile,
        .readable = resolveAll(arena, io, cfg.readable, false) catch |e| return pathError(e),
        .writable = resolveAll(arena, io, cfg.writable, false) catch |e| return pathError(e),
        .read_deny = resolveAll(arena, io, cfg.read_deny, true) catch |e| return pathError(e),
        .write = cfg.write,
        .net = cfg.net,
        .net_allow = cfg.net_allow,
        .memory = cfg.memory,
        .timeout_ns = cfg.timeout_ns,
        .pids = cfg.pids,
        .cpus = cfg.cpus,
        .cwd_writable = if (cfg.sandbox != null) true else null,
        .host_fs = cfg.host_fs,
    };
    var base: h9.Machine.Options = .{
        .backend = cfg.backend,
        .arch = arch,
        .mounts = mounts,
        .binds = cfg.binds,
        .cred_helpers = credHelpers(arena, cfg, init.environ_map) catch |e| return if (e == error.Usage) 2 else exit_failed,
        .index = switch (cfg.index) {
            .auto => .auto,
            .none => .none,
        },
        .root_index = rootIndexArg(rootIndexOf(mounts)),
        .index_cache = cfg.index_cache orelse h9.rootindex.cache.Cache.defaultDir(arena, init.environ_map),
        .tmp_dir = tmpDir(init.environ_map),
        .root_index_counts = if (cfg.print) rootIndexCounts(arena, io, rootIndexOf(mounts)) else null,
        .verbose = cfg.verbose,
        .nine_prog = cfg.rc != null,
        .proxy = if (web) null else proxyFrom(init.environ_map),
        .cwd = cwd,
        .policy = pol,
        .guest_tools = cfg.guest_tools,
        .gfx = cfg.gfx,
        .serve = so.listens,
        .serve_root = cfg.serve_root orelse "/",
        .serve_token = so.token,
        .serve_origins = cfg.serve_origins,
        .serve_net = cfg.serve_net,
        .user_map = user_map,
        .stdio = undefined,
    };

    if (h9.Machine.hasLinux(base)) base.nameservers = try hostNameservers(arena, io);
    var conflict: []const u8 = "";
    var plan = h9.Machine.compilePlan(arena, base, &conflict) catch |err| switch (err) {
        error.Conflict => {
            std.debug.print("h9: {s}\n", .{conflict});
            return 2;
        },
        else => return err,
    };
    if (plan.serve) |*sv| sv.only = serve_only;
    if (cfg.print) {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stdout().writerStreaming(io, &buf);
        plan.print(&w.interface) catch {};
        w.interface.flush() catch {};
    }
    if (cfg.print) return 0;

    var trace_file: ?std.Io.File = null;
    defer if (trace_file) |f| f.close(io);
    var trace_buf: [4096]u8 = undefined;
    var trace_w: std.Io.File.Writer = undefined;
    if (cfg.trace) |t| if (t.len > 0) {
        trace_file = std.Io.Dir.cwd().createFile(io, t, .{}) catch |err| {
            std.debug.print("h9: trace {s}: {t}\n", .{ t, err });
            return exit_failed;
        };
        trace_w = trace_file.?.writerStreaming(io, &trace_buf);
    };

    var in_buf: [4096]u8 = undefined;
    var in: Stdin = undefined;
    in.init(io, &in_buf);
    var out = std.Io.File.stdout().writerStreaming(io, &.{});
    var err_w = std.Io.File.stderr().writerStreaming(io, &.{});
    var host: hostsig.Host = undefined;
    host.init(io);
    defer host.deinit();
    var opts = base;
    opts.env = env.items;
    opts.signals = &host.signals;
    opts.trace = if (cfg.trace) |t| (if (t.len > 0) &trace_w.interface else &err_w.interface) else null;
    // --ns @FILE is read on the host, with h9's own permissions, before
    // the machine starts; inline lines are taken as they are
    // (design/mounts.md, "Namespace files").
    var ns_texts: std.ArrayList([]const u8) = .empty;
    for (cfg.ns) |v| {
        if (v[0] != '@') {
            try ns_texts.append(arena, v);
            continue;
        }
        const text = std.Io.Dir.cwd().readFileAlloc(io, v[1..], arena, .limited(1 << 20)) catch |e| {
            std.debug.print("h9: --ns {s}: {s}\n", .{ v, if (e == error.FileNotFound) "not found" else @errorName(e) });
            return exit_failed;
        };
        try ns_texts.append(arena, text);
    }
    opts.ns = ns_texts.items;
    opts.console_tty = (std.Io.File.stdin().isTty(io) catch false) and (std.Io.File.stdout().isTty(io) catch false);
    // A run that only serves doesn't read the console, so it can run in
    // the background without stopping on terminal input.
    opts.stdio = .{
        .in = if (serve_only) null else in.reader(),
        .in_cancel = if (serve_only) null else .{ .ctx = &in, .func = Stdin.cancel, .reset = Stdin.reset },
        .out = &out.interface,
        .err = &err_w.interface,
        .raw = host.raw(),
    };
    var machine = h9.Machine.init(init.gpa, io, opts) catch |err| {
        switch (err) {
            error.GfxNotBuilt => {
                std.debug.print("h9: graphics aren't built into this h9\n", .{});
                return exit_failed;
            },
            error.GfxInUse => {
                std.debug.print("h9: --gfx: another machine in this process has the screen\n", .{});
                return exit_failed;
            },
            error.GfxUnavailable => {
                std.debug.print("h9: --gfx: no display: {s}\n", .{h9.gfx.unavailable() orelse "the window didn't open"});
                return exit_failed;
            },
            else => {},
        }
        const a: h9.vmm.Arch = arch orelse h9.vmm.host_arch orelse .arm64;
        std.debug.print("h9: cannot create {t} machine for {s}: {s}\n", .{ cfg.backend, a.name(), tools.explain(cfg.backend, err) });
        // `auto` no longer falls back to native (it isn't a security
        // boundary); point at the explicit opt-in when it's the only
        // backend that could run here.
        if (cfg.backend == .auto and err == error.HypervisorUnavailable and h9.vmm.Kind.built(.native)) {
            std.debug.print("h9: the native backend can run here, but it shares h9's process and is not a security boundary; pass --backend native to use it for a trusted guest\n", .{});
        }
        return exit_failed;
    };
    defer machine.deinit();
    if (cfg.backend == .auto and machine.backend.kind() == .emu) {
        const why = h9.vmm.whyUnavailable(.auto) orelse "no usable hypervisor";
        std.debug.print("h9: warning: {s}; using the emulator\n", .{why});
    }
    // The native backend is a trusted-guest performance path, not a
    // sandbox: guest code shares h9's address space (design/0095, Security;
    // audit 2026-11-09). Warn when it's chosen explicitly, but only on a
    // terminal, so scripts that opt into it aren't spammed on every run
    // (as the root-changes notice does below).
    if (cfg.backend == .native and (std.Io.File.stderr().isTty(io) catch false)) {
        std.debug.print("h9: warning: the native backend runs guest code in h9's own process and is not a security boundary; use a hypervisor backend to contain an untrusted guest\n", .{});
    }

    const status = machine.run(prog, argv) catch |err| {
        if (machine.stuck) {
            host.deinit();
            std.process.exit(exit_failed);
        }
        const why = if (machine.err_msg.len > 0) machine.err_msg else @errorName(err);
        // A listener's failure names its address itself.
        if (err == error.ServeFailed) {
            std.debug.print("h9: {s}\n", .{why});
            return exit_failed;
        }
        // Over the built-in root alone, the fix for a missing command is
        // the full tree (design/epoch-0/builtin-root.md).
        const hint = if (err == error.NotFound and prog == .guest and builtin_only)
            " (not in the built-in root; pass --dir or --url, or set H9ROOT, for the full 9front tree)"
        else
            "";
        std.debug.print("h9: {s}: {s}{s}\n", .{ prog_arg, why, hint });
        return switch (err) {
            error.NotFound => exit_not_found,
            error.NotExecutable => exit_not_executable,
            else => exit_failed,
        };
    };
    // A serve-only run that a note ended exits 0, as a server its
    // operator stops does; the timeout still exits 124.
    if (serve_only and status == .killed and !std.mem.eql(u8, status.killed, "h9: timeout")) return 0;
    // Always, since the guest's own error doesn't say: Linux's OOM killer
    // leaves its note in the kernel log, which a guest has no way to read.
    if (machine.out_of_memory) {
        std.debug.print("h9: a process ran out of guest memory and was killed (SIGKILL); raise --memory\n", .{});
    }
    // Only on a terminal: scripts rarely have one (design/epoch-0/overlay.md).
    if (machine.root_changes.changed and (std.Io.File.stderr().isTty(io) catch false)) {
        var nb: [512]u8 = undefined;
        std.debug.print("{s}\n", .{cli.discardNotice(&nb, &machine.root_changes, ninep_root)});
    }
    switch (status) {
        .exited => |msg| {
            const s = cli.exitStatus(msg);
            if (s.print) std.debug.print("{s}\n", .{msg});
            return s.code;
        },
        .killed => |msg| {
            // 128+N for a signal, 124 for --timeout, 125 for h9's own
            // failures (design/epoch-0/exit-status.md).
            const s = cli.killedStatus(msg, host.stoppedBy());
            if (s.print) std.debug.print("h9: {s}: {s}\n", .{ prog_arg, msg });
            // The timed-out process is stuck in a host call; don't wait
            // for it or free what it's using.
            if (machine.stuck) {
                host.deinit();
                std.process.exit(s.code);
            }
            return s.code;
        },
    }
}

/// The host's working directory on the web host, where WASI has none of
/// its own: the JS host passes it as $PWD.
var web_pwd: []const u8 = "/";

/// An absolute host path for `p`, with symlinks resolved. WASI has no
/// realpath, so the web host resolves one component at a time with
/// readlink.
fn realPath(io: std.Io, arena: std.mem.Allocator, p: []const u8) ![]u8 {
    if (!web) return std.Io.Dir.cwd().realPathFileAlloc(io, p, arena);
    var path = try std.fs.path.resolvePosix(arena, &.{ web_pwd, p });
    var links: usize = 0;
    var i: usize = 1;
    // path[0..i] is resolved; each turn takes the next component.
    while (i < path.len) {
        const end = std.mem.indexOfScalarPos(u8, path, i, '/') orelse path.len;
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const n = std.Io.Dir.cwd().readLink(io, path[0..end], &buf) catch |err| switch (err) {
            error.NotLink => {
                i = end + 1;
                continue;
            },
            else => |e| return e,
        };
        links += 1;
        if (links > 40) return error.SymLinkLoop;
        const dir = path[0 .. std.mem.lastIndexOfScalar(u8, path[0..end], '/').? + 1];
        const rest = if (end < path.len) path[end + 1 ..] else "";
        path = try std.fs.path.resolvePosix(arena, &.{ dir, buf[0..n], rest });
        i = 1;
    }
    try std.Io.Dir.cwd().access(io, path, .{});
    return path;
}

const MountError = error{ Usage, NotFound, OutOfMemory };

/// The mount flags, resolved for the machine (design/mounts.md): a
/// --dir's or --archive's host path made absolute, with symlinks
/// resolved; a URL's `header=@FILE` read and every header checked; and
/// `ca=` resolved. With nothing on `/`, `$H9ROOT` (a --url if it has
/// `://`, and a --dir otherwise) and then the built-in root go there.
fn resolveMounts(arena: std.mem.Allocator, io: std.Io, cfg: cli.Config, env: *const std.process.Environ.Map) MountError![]const h9.Machine.Mount {
    var out: std.ArrayList(h9.Machine.Mount) = .empty;
    var on_root = false;
    for (cfg.mounts) |m| {
        if (m.stack()) |st| if (st[0] == .root) {
            on_root = true;
        };
        try out.append(arena, try resolveMount(arena, io, m));
    }
    if (!on_root) {
        const m: h9.Machine.Mount = if (env.get("H9ROOT")) |r| blk: {
            const kind: h9.policy.mount.Kind = if (std.mem.indexOf(u8, r, "://") != null) .url else .dir;
            var w: []const u8 = "";
            var m = h9.Machine.Mount.parse(arena, kind, r, &w) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Usage => {
                    std.debug.print("h9: H9ROOT={s}: {s}\n", .{ r, w });
                    return error.Usage;
                },
            };
            // $H9ROOT names the root, so it's on `/` whatever it holds.
            m.dst = "/";
            break :blk try resolveMount(arena, io, m);
        } else .{ .kind = .builtin, .order = .after };
        try out.insert(arena, 0, m);
    }
    return out.items;
}

fn resolveMount(arena: std.mem.Allocator, io: std.Io, given: h9.Machine.Mount) MountError!h9.Machine.Mount {
    var m = given;
    switch (m.kind) {
        .dir, .archive => {
            const real = realPath(io, arena, m.src) catch {
                std.debug.print("h9: {s} {s}: not found\n", .{ m.kind.flag(), m.src });
                return error.NotFound;
            };
            // An archive is read from the host, as is; a tree is bound
            // through #U, which takes Windows paths as /C:/a/b.
            m.src = if (m.kind == .archive) real else kernPath(arena, real);
        },
        .url => {
            // The page's (or Node's) WebSocket does the handshake and TLS,
            // with its own trust and proxy, and can't set headers.
            if (web and (m.headers.len > 0 or m.ca != null)) {
                std.debug.print("h9: --url {s}: {s} isn't available on the web host\n", .{ m.src, if (m.ca != null) "ca=" else "header=" });
                return error.Usage;
            }
            var headers: std.ArrayList([]const u8) = .empty;
            for (m.headers) |h| {
                if (h[0] == '@') {
                    const text = std.Io.Dir.cwd().readFileAlloc(io, h[1..], arena, .limited(1 << 20)) catch {
                        std.debug.print("h9: --url {s}: header={s}: not found\n", .{ m.src, h });
                        return error.NotFound;
                    };
                    var lines = std.mem.splitScalar(u8, text, '\n');
                    while (lines.next()) |l| {
                        if (std.mem.trim(u8, l, " \t\r").len == 0) continue;
                        try headers.append(arena, try checkHeader(m.src, l, h));
                    }
                } else try headers.append(arena, try checkHeader(m.src, h, h));
            }
            m.headers = headers.items;
            if (m.ca) |ca| m.ca = realPath(io, arena, ca) catch {
                std.debug.print("h9: --url {s}: ca={s}: not found\n", .{ m.src, ca });
                return error.NotFound;
            };
        },
        .builtin, .tmp, .fd => {},
    }
    return m;
}

/// The root as --check names it: the source of the bottom mount on `/`,
/// or null for the built-in root alone.
fn rootShown(cfg: cli.Config, resolved: []const h9.Machine.Mount, env: *const std.process.Environ.Map) ?[]const u8 {
    for (resolved) |m| if (m.stack()) |st| if (st[0] == .root and m.kind != .builtin) return m.src;
    if (resolved.len == 0) {
        for (cfg.mounts) |m| if (m.stack()) |st| if (st[0] == .root) return m.src;
        return env.get("H9ROOT");
    }
    return null;
}

/// The proxy environment, as curl reads it.
/// Where static trees' sockets go: `$TMPDIR`, or `%TEMP%` on Windows.
fn tmpDir(env: *const std.process.Environ.Map) []const u8 {
    return env.get("TMPDIR") orelse env.get("TEMP") orelse h9.Machine.default_tmp_dir;
}

fn proxyFrom(env: *const std.process.Environ.Map) h9.Machine.Proxy {
    return .{
        .http = env.get("HTTP_PROXY") orelse env.get("http_proxy"),
        .https = env.get("HTTPS_PROXY") orelse env.get("https_proxy"),
        .no_proxy = env.get("NO_PROXY") orelse env.get("no_proxy") orelse "",
    };
}

/// The host's DNS servers, from its /etc/resolv.conf, for a Linux root
/// (design/epoch-0/linux-net.md). A host without one (Windows) or naming
/// none gets Google's public servers, as Docker does.
fn hostNameservers(arena: std.mem.Allocator, io: std.Io) error{OutOfMemory}![]const []const u8 {
    const fallback: []const []const u8 = &.{ "8.8.8.8", "8.8.4.4" };
    const text = std.Io.Dir.cwd().readFileAlloc(io, "/etc/resolv.conf", arena, .limited(64 << 10)) catch return fallback;
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        var f = std.mem.tokenizeAny(u8, l, " \t\r");
        const key = f.next() orelse continue;
        if (!std.mem.eql(u8, key, "nameserver")) continue;
        const a = f.next() orelse continue;
        // A scoped IPv6 address (fe80::1%eth0) means nothing in the guest.
        if (std.mem.indexOfScalar(u8, a, '%') != null) continue;
        if (h9.policy.parseIp(a) == null) continue;
        try out.append(arena, a);
    }
    return if (out.items.len > 0) out.items else fallback;
}

/// The `index=` of the first 9P member of `/`, which is the root's
/// index (design/mount-index.md).
fn rootIndexOf(mounts: []const h9.Machine.Mount) ?[]const u8 {
    for (mounts) |m| if (m.kind == .url or m.kind == .fd) if (m.stack()) |st| if (st[0] == .root) return m.index;
    return null;
}

/// An `index=` value: a URL by its scheme, and otherwise a host file.
fn rootIndexArg(arg: ?[]const u8) ?h9.Machine.RootIndex {
    const a = arg orelse return null;
    if (std.mem.startsWith(u8, a, "https://") or std.mem.startsWith(u8, a, "http://")) return .{ .url = a };
    return .{ .path = a };
}

/// For --print: an `index=` file's entry and directory counts, or
/// null for a URL, which --print doesn't fetch, or a file that doesn't
/// compile.
fn rootIndexCounts(arena: std.mem.Allocator, io: std.Io, arg: ?[]const u8) @FieldType(h9.Machine.Options, "root_index_counts") {
    const path = switch (rootIndexArg(arg) orelse return null) {
        .path => |p| p,
        .url => return null,
    };
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(h9.rootindex.max_text)) catch return null;
    var diag: h9.rootindex.Diag = .{};
    const compiled = h9.rootindex.compile(arena, text, &diag) catch return null;
    const ix = h9.rootindex.Index.init(compiled) catch return null;
    return .{ .entries = ix.n, .dirs = ix.ndirs };
}

const WsError = error{ Usage, NotFound, OutOfMemory };


/// --cred entries, then $H9CRED's (design/credential-helpers.md).
/// cli.parse checked --cred's; a bad $H9CRED entry is a usage error.
fn credHelpers(arena: std.mem.Allocator, cfg: cli.Config, env: *const std.process.Environ.Map) WsError![]const h9.Machine.CredHelper {
    var list: std.ArrayList(h9.Machine.CredHelper) = .empty;
    for (cfg.cred) |c| try list.append(arena, h9.cred.parse(arena, c) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    });
    if (env.get("H9CRED")) |v| h9.cred.parseList(arena, v, &list) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadPattern, error.NoCommand => {
            std.debug.print("h9: $H9CRED: {s}\n", .{if (e == error.BadPattern) "a pattern is a host, *.DOMAIN, or either with a path" else "each entry is PATTERN=COMMAND"});
            return error.Usage;
        },
    };
    // On the web host the embedder's credentials callback gets the
    // matching helper's command to run, or not (design/credential-helpers.md,
    // "Browser host").
    return list.items;
}

const ServeOptions = struct {
    listens: []const h9.Machine.Listen = &.{},
    token: ?[]const u8 = null,
};

/// Reads the --serve flags (design/epoch-0/serve.md): the addresses, which
/// cli.parse checked, and the token from its @FILE, trimmed.
fn serveOptions(arena: std.mem.Allocator, io: std.Io, cfg: cli.Config) WsError!ServeOptions {
    var o: ServeOptions = .{};
    const ls = try arena.alloc(h9.Machine.Listen, cfg.serve.len);
    for (ls, cfg.serve) |*l, a| l.* = h9.Machine.Listen.parse(a) catch return error.Usage;
    o.listens = ls;
    if (cfg.serve_token) |f| {
        const text = std.Io.Dir.cwd().readFileAlloc(io, f[1..], arena, .limited(4096)) catch {
            std.debug.print("h9: --serve-token {s}: not found\n", .{f});
            return error.NotFound;
        };
        const tok = std.mem.trim(u8, text, " \t\r\n");
        if (tok.len == 0 or std.mem.indexOfAny(u8, tok, " \t\r\n") != null) {
            std.debug.print("h9: --serve-token {s}: the file must hold one token\n", .{f});
            return error.Usage;
        }
        o.token = tok;
    }
    return o;
}

fn checkHeader(src: []const u8, line: []const u8, given: []const u8) WsError![]const u8 {
    return h9.ws.checkHeader(line) catch |e| {
        const name = h9.ws.headerName(line);
        switch (e) {
            error.ReservedHeader => std.debug.print("h9: --url {s}: header={s}: {s} changes the handshake\n", .{ src, given, name }),
            error.BadHeader => std.debug.print("h9: --url {s}: header={s}: '{s}' isn't a 'Name: value' header\n", .{ src, given, line }),
        }
        return error.Usage;
    };
}

const PathError = error{ NotFound, OutOfMemory };

fn pathError(err: PathError) u8 {
    return switch (err) {
        error.NotFound => exit_failed,
        error.OutOfMemory => exit_failed,
    };
}

/// Resolves host paths for the policy: absolute, with symlinks resolved.
/// With `may_miss`, a path that doesn't exist is resolved through its
/// parent, so a read-deny rule can name a file that isn't there yet.
fn resolveAll(arena: std.mem.Allocator, io: std.Io, paths: []const []const u8, may_miss: bool) PathError![]const []const u8 {
    const out = try arena.alloc([]const u8, paths.len);
    for (paths, out) |p, *o| {
        const resolved = realPath(io, arena, p) catch blk: {
            if (may_miss) {
                const dir = std.fs.path.dirname(p) orelse ".";
                if (realPath(io, arena, dir)) |parent| {
                    break :blk try std.fs.path.join(arena, &.{ parent, std.fs.path.basename(p) });
                } else |_| {}
            }
            std.debug.print("h9: {s}: not found\n", .{p});
            return error.NotFound;
        };
        o.* = kernPath(arena, resolved);
    }
    return out;
}

/// A resolved host path in the form `#U` takes: unchanged on Unix, and
/// `/C:/a/b` for `C:\a\b` on Windows (devfs-win32's guest view).
fn kernPath(arena: std.mem.Allocator, p: []const u8) []const u8 {
    if (builtin.os.tag != .windows) return p;
    const out = arena.alloc(u8, p.len + 1) catch return p;
    out[0] = '/';
    for (p, out[1..]) |c, *o| o.* = if (c == '\\') '/' else c;
    if (out.len >= 3 and out[2] == ':') out[1] = std.ascii.toUpper(out[1]);
    // "C:/" -> "/C:"
    return if (out.len == 4 and out[3] == '/') out[0..3] else out;
}

test {
    _ = cli;
    _ = tools;
}
