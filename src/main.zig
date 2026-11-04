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
            const root = if (root_arg) |r| if (std.Io.Dir.cwd().realPathFileAlloc(io, r, arena)) |p| kernPath(arena, p) else |_| null else null;
            var buf: [1024]u8 = undefined;
            var w = std.Io.File.stdout().writerStreaming(io, &buf);
            const code = tools.check(init.gpa, io, &w.interface, .{
                .backend = cfg.backend,
                .memory = cfg.memory,
                .root_arg = root_arg,
                .root = root,
            }) catch exit_failed;
            w.interface.flush() catch {};
            return code;
        },
    }
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
    var arch: ?h9.vmm.Arch = null;
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
            arch = hdr.arch;
            break :blk .{ .bytes = bytes };
        },
        .guest => .{ .guest = prog_arg },
    };

    // #U takes absolute host paths, with symlinks resolved.
    const root_arg = cfg.root orelse init.environ_map.get("H9ROOT") orelse defaultRoot(arena, io);
    const root = if (root_arg) |r| kernPath(arena, std.Io.Dir.cwd().realPathFileAlloc(io, r, arena) catch {
        std.debug.print("h9: root {s}: not found\n", .{r});
        return exit_failed;
    }) else null;
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
        .memory = cfg.memory,
        .timeout_ns = cfg.timeout_ns,
        .pids = cfg.pids,
        .cpus = cfg.cpus,
        .cwd_writable = if (cfg.sandbox != null) true else null,
        .host_fs = cfg.host_fs,
        .host_cmd = cfg.host_cmd,
        .tmp = hostTmp(arena, io, init.environ_map),
    };
    const base: h9.Machine.Options = .{
        .backend = cfg.backend,
        .arch = arch,
        .root = root,
        .cwd = cwd,
        .policy = pol,
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
        const a: h9.vmm.Arch = arch orelse h9.vmm.host_arch orelse .arm64;
        std.debug.print("h9: cannot create {t} machine for {t}: {s}\n", .{ cfg.backend, a, tools.explain(cfg.backend, err) });
        return exit_failed;
    };
    defer machine.deinit();
    if (cfg.backend == .auto and machine.backend.kind() == .emu) {
        std.debug.print("h9: warning: no usable hypervisor; using the emulator\n", .{});
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
    switch (status) {
        .exited => |msg| {
            if (msg.len == 0) return 0;
            std.debug.print("{s}\n", .{msg});
            return 1;
        },
        .killed => |msg| {
            std.debug.print("h9: {s}: {s}\n", .{ prog_arg, msg });
            // The timed-out process is stuck in a host call; don't wait
            // for it or free what it's using.
            if (machine.stuck) {
                host.deinit();
                std.process.exit(1);
            }
            return 1;
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

/// The host temp dir, bound at /tmp.
fn hostTmp(arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ?[]const u8 {
    const t = env.get("TMPDIR") orelse env.get("TEMP") orelse "/tmp";
    return kernPath(arena, std.Io.Dir.cwd().realPathFileAlloc(io, t, arena) catch return null);
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
