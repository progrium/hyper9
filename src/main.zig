const std = @import("std");
const builtin = @import("builtin");
const h9 = @import("h9");
const cli = @import("cli.zig");
const Stdin = @import("stdin.zig").Stdin;
const tools = @import("tools.zig");
const hostsig = @import("hostsig.zig");

/// Restores the host terminal before the default panic output, so a crash
/// in raw mode doesn't leave the user's terminal raw.
pub const panic = std.debug.FullPanic(struct {
    fn f(msg: []const u8, ret_addr: ?usize) noreturn {
        hostsig.restoreTerminal();
        std.debug.defaultPanic(msg, ret_addr);
    }
}.f);

/// Exit codes for h9's own failures (DESIGN.md, "Exit codes").
const exit_failed = 125;
const exit_not_executable = 126;
const exit_not_found = 127;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    const cfg = cli.parse(arena, args) catch {
        std.debug.print(cli.usage, .{});
        return 2;
    };
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
            const root_arg = cfg.root orelse init.environ_map.get("H9ROOT") orelse defaultRoot(arena, io);
            var root_err: []const u8 = "";
            const root = if (root_arg) |r| resolveRoot(arena, io, r) catch |e| blk: {
                root_err = rootError(e);
                break :blk null;
            } else null;
            const wo = wsOptions(arena, io, cfg, root, init.environ_map) catch |e| return wsExit(e);
            var buf: [1024]u8 = undefined;
            var w = std.Io.File.stdout().writerStreaming(io, &buf);
            const code = tools.check(init.gpa, io, &w.interface, .{
                .backend = cfg.backend,
                .memory = cfg.memory,
                .root_arg = root_arg,
                .root = root,
                .root_err = root_err,
                .root_spec = cfg.root_spec,
                .root_user = cfg.root_user,
                .root_headers = wo.headers,
                .root_ca = wo.ca,
                .proxy = wo.proxy,
            }) catch exit_failed;
            w.interface.flush() catch {};
            return code;
        },
    }
    // --gfx: on macOS AppKit needs the main thread, so the run goes on
    // another (design/0015-gfx.md). Elsewhere this runs it directly.
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
    const io = init.io;
    // --rc runs /bin/rc -c; the remaining arguments become $*.
    const argv: []const []const u8 = if (cfg.rc) |cmd| blk: {
        const v = try arena.alloc([]const u8, 3 + cfg.argv.len);
        v[0] = "rc";
        v[1] = "-c";
        v[2] = cmd;
        @memcpy(v[3..], cfg.argv);
        break :blk v;
    } else cfg.argv;
    const prog_arg = if (cfg.rc != null) "/bin/rc" else argv[0];

    // A host program is read here; a guest one is resolved in the machine.
    // --arch picks the architecture; without it, a host program's header
    // does, and a guest one runs the host's.
    var arch: ?h9.vmm.Arch = cfg.arch;
    const prog: h9.Program = switch (cli.programKind(prog_arg)) {
        .host => blk: {
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, prog_arg, arena, .limited(1 << 30)) catch |err| {
                std.debug.print("h9: {s}: {t}\n", .{ prog_arg, err });
                return if (err == error.FileNotFound) exit_not_found else exit_failed;
            };
            const hdr = h9.aout.parse(bytes) catch |err| {
                std.debug.print("h9: {s}: not a 9front executable: {t}\n", .{ prog_arg, err });
                return exit_not_executable;
            };
            if (arch == null) arch = hdr.arch;
            break :blk .{ .bytes = bytes };
        },
        .guest => .{ .guest = prog_arg },
    };

    const root_arg = cfg.root orelse init.environ_map.get("H9ROOT") orelse defaultRoot(arena, io);
    const root = if (root_arg) |r| resolveRoot(arena, io, r) catch |e| {
        std.debug.print("h9: root {s}: {s}\n", .{ r, rootError(e) });
        return exit_failed;
    } else null;
    // Without a root tree only a host a.out can run; anything resolved in
    // the guest namespace would fail later as a misleading "not found".
    if (root == null and (prog == .guest or cfg.ns != null)) {
        std.debug.print("h9: no root tree found; pass --root or set H9ROOT\n", .{});
        return exit_failed;
    }
    const wo = wsOptions(arena, io, cfg, root, init.environ_map) catch |e| return wsExit(e);
    const cwd_arg = cfg.sandbox orelse cfg.cwd orelse ".";
    const cwd = kernPath(arena, std.Io.Dir.cwd().realPathFileAlloc(io, cwd_arg, arena) catch {
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
        .host_cmd = cfg.host_cmd,
    };
    const base: h9.Machine.Options = .{
        .backend = cfg.backend,
        .arch = arch,
        .root = root,
        .root_spec = cfg.root_spec,
        .root_user = cfg.root_user,
        .root_headers = wo.headers,
        .root_ca = wo.ca,
        .root_contained = cfg.root_contained,
        .proxy = wo.proxy,
        .cwd = cwd,
        .policy = pol,
        .guest_tools = cfg.guest_tools,
        .gfx = cfg.gfx,
        .stdio = undefined,
    };

    var conflict: []const u8 = "";
    const plan = h9.Machine.compilePlan(arena, base, &conflict) catch |err| switch (err) {
        error.Conflict => {
            std.debug.print("h9: {s}\n", .{conflict});
            return 2;
        },
        else => return err,
    };
    if (cfg.print) {
        var buf: [4096]u8 = undefined;
        var w = std.Io.File.stdout().writerStreaming(io, &buf);
        plan.print(&w.interface) catch {};
        w.interface.flush() catch {};
    }
    if (cfg.strict and plan.unenforced.count() > 0) {
        std.debug.print("h9: --strict: this build can't enforce:", .{});
        var it = plan.unenforced.iterator();
        while (it.next()) |c| std.debug.print(" {t}", .{c});
        std.debug.print("\n", .{});
        return 2;
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
    opts.dump_on_fault = cfg.dump_on_fault;
    opts.ns = cfg.ns;
    opts.stdio = .{
        .in = in.reader(),
        .in_cancel = .{ .ctx = &in, .func = Stdin.cancel, .reset = Stdin.reset },
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
        return exit_failed;
    };
    defer machine.deinit();
    if (cfg.backend == .auto and machine.backend.kind() == .emu) {
        const why = h9.vmm.whyUnavailable(.auto) orelse "no usable hypervisor";
        std.debug.print("h9: warning: {s}; using the emulator\n", .{why});
    }

    const status = machine.run(prog, argv) catch |err| {
        if (machine.stuck) {
            host.deinit();
            std.process.exit(exit_failed);
        }
        const why = if (machine.err_msg.len > 0) machine.err_msg else @errorName(err);
        std.debug.print("h9: {s}: {s}\n", .{ prog_arg, why });
        return switch (err) {
            error.NotFound => exit_not_found,
            error.NotExecutable => exit_not_executable,
            else => exit_failed,
        };
    };
    // Only on a terminal: scripts rarely have one (design/0011-overlay.md).
    if (machine.root_changes.changed and (std.Io.File.stderr().isTty(io) catch false)) {
        var nb: [512]u8 = undefined;
        std.debug.print("{s}\n", .{cli.discardNotice(&nb, &machine.root_changes, root != null and root.? != .dir)});
    }
    switch (status) {
        .exited => |msg| {
            const s = cli.exitStatus(msg);
            if (s.print) std.debug.print("{s}\n", .{msg});
            return s.code;
        },
        .killed => |msg| {
            // 128+N for a signal, 124 for --timeout, 125 for h9's own
            // failures (design/0033-exit-status.md).
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

/// The default root: .local/9front/root beside the h9 binary's source tree
/// in development builds (zig-out/bin/h9 -> ../../.local/9front/root).
fn defaultRoot(arena: std.mem.Allocator, io: std.Io) ?[]const u8 {
    const exe = std.process.executablePathAlloc(io, arena) catch return null;
    const dir = std.fs.path.dirname(exe) orelse return null;
    const root = std.fs.path.join(arena, &.{ dir, "..", "..", ".local", "9front", "root" }) catch return null;
    std.Io.Dir.cwd().access(io, root, .{}) catch return null;
    return root;
}

const RootError = error{ NotFound, NotDirOrSocket, BadDial, OutOfMemory };

/// Reads a --root or $H9ROOT value (design/0013-9p-roots.md): a dial
/// string, or a host path that's a directory (served through #U, which
/// takes absolute paths with symlinks resolved) or a unix socket.
fn resolveRoot(arena: std.mem.Allocator, io: std.Io, arg: []const u8) RootError!h9.Root {
    switch (try cli.rootArg(arena, arg)) {
        .tcp => |a| return .{ .tcp = a },
        .unix => |p| return .{ .unix = p },
        .ws => |u| return .{ .ws = u },
        .path => |p| {
            const real = std.Io.Dir.cwd().realPathFileAlloc(io, p, arena) catch return error.NotFound;
            const st = std.Io.Dir.cwd().statFile(io, real, .{}) catch return error.NotFound;
            return switch (st.kind) {
                .directory => .{ .dir = kernPath(arena, real) },
                .unix_domain_socket => .{ .unix = real },
                else => error.NotDirOrSocket,
            };
        },
    }
}

fn rootError(err: RootError) []const u8 {
    return switch (err) {
        error.NotFound => "not found",
        error.NotDirOrSocket => "not a directory or socket",
        error.BadDial => "bad dial string or URL",
        error.OutOfMemory => "out of memory",
    };
}

const WsOptions = struct {
    headers: []const []const u8 = &.{},
    ca: ?[]const u8 = null,
    proxy: h9.Machine.Proxy = .{},
};

const WsError = error{ Usage, NotFound, OutOfMemory };

/// Reads the WebSocket root's flags (design/0021-websocket-9p.md):
/// --root-header lines, from @FILE where given, checked; --root-ca,
/// resolved; and the proxy environment, as curl reads it.
fn wsOptions(arena: std.mem.Allocator, io: std.Io, cfg: cli.Config, root: ?h9.Root, env: *const std.process.Environ.Map) WsError!WsOptions {
    const url: ?h9.ws.Url = if (root) |r| switch (r) {
        .ws => |u| h9.ws.Url.parse(u) catch null,
        else => null,
    } else null;
    if (cfg.root_headers.len > 0 and url == null) {
        std.debug.print("h9: --root-header needs a ws:// or wss:// root\n", .{});
        return error.Usage;
    }
    if (cfg.root_ca != null and (url == null or !url.?.tls)) {
        std.debug.print("h9: --root-ca needs a wss:// root\n", .{});
        return error.Usage;
    }
    var o: WsOptions = .{};
    var headers: std.ArrayList([]const u8) = .empty;
    for (cfg.root_headers) |h| {
        if (h[0] == '@') {
            const text = std.Io.Dir.cwd().readFileAlloc(io, h[1..], arena, .limited(1 << 20)) catch {
                std.debug.print("h9: --root-header {s}: not found\n", .{h});
                return error.NotFound;
            };
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |l| {
                if (std.mem.trim(u8, l, " \t\r").len == 0) continue;
                try headers.append(arena, try checkHeader(l, h));
            }
        } else try headers.append(arena, try checkHeader(h, h));
    }
    o.headers = headers.items;
    if (cfg.root_ca) |ca| {
        o.ca = std.Io.Dir.cwd().realPathFileAlloc(io, ca, arena) catch {
            std.debug.print("h9: --root-ca {s}: not found\n", .{ca});
            return error.NotFound;
        };
    }
    o.proxy = .{
        .http = env.get("HTTP_PROXY") orelse env.get("http_proxy"),
        .https = env.get("HTTPS_PROXY") orelse env.get("https_proxy"),
        .no_proxy = env.get("NO_PROXY") orelse env.get("no_proxy") orelse "",
    };
    return o;
}

fn checkHeader(line: []const u8, given: []const u8) WsError![]const u8 {
    return h9.ws.checkHeader(line) catch |e| {
        const name = h9.ws.headerName(line);
        switch (e) {
            error.ReservedHeader => std.debug.print("h9: --root-header{s}{s}: {s} changes the handshake\n", .{ if (given[0] == '@') " " else "", if (given[0] == '@') given else "", name }),
            error.BadHeader => std.debug.print("h9: --root-header{s}{s}: '{s}' isn't a 'Name: value' header\n", .{ if (given[0] == '@') " " else "", if (given[0] == '@') given else "", line }),
        }
        return error.Usage;
    };
}

fn wsExit(e: WsError) u8 {
    return switch (e) {
        error.Usage => 2,
        error.NotFound, error.OutOfMemory => exit_failed,
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
        const resolved = std.Io.Dir.cwd().realPathFileAlloc(io, p, arena) catch blk: {
            if (may_miss) {
                const dir = std.fs.path.dirname(p) orelse ".";
                if (std.Io.Dir.cwd().realPathFileAlloc(io, dir, arena)) |parent| {
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
