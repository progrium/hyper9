//! An example of embedding h9 as a Zig library (docs/embedding.md): runs one
//! 9front program in several machines at once, each on its own thread with
//! its own environment, captures each machine's output in memory, and
//! prints the results in order.
//!
//!     embed [-j N] [--root DIR] PROGRAM [ARG...]
//!
//! PROGRAM is read on the host when it starts with `./` or `../`, as with
//! the CLI, or is any path and there's no root tree; it's a 9front a.out.
//! Otherwise it's a guest path or name (`rc`, `/bin/ls`) in the root tree. Each machine sees its
//! index in `$machine`, so `embed -j 3 --root R rc -c 'echo $machine'`
//! prints 0, 1 and 2. `zig build embed` builds it, and `zig build test`
//! runs it on the hello fixture.

const std = @import("std");
const builtin = @import("builtin");
const h9 = @import("h9");

const usage = "usage: embed [-j N] [--root DIR] PROGRAM [ARG...]\n";

/// One machine's run, filled in on its thread.
const Job = struct {
    index: usize,
    opts: h9.Machine.Options,
    prog: h9.Program,
    argv: []const []const u8,
    /// Receives fd 1 and fd 2: the console serializes writes, so one
    /// writer can take both.
    out: std.Io.Writer.Allocating,
    env: [1]h9.EnvVar = undefined,
    index_buf: [20]u8 = undefined,
    /// What happened, copied out of the machine before it's freed.
    result: []const u8 = "",
    backend: []const u8 = "none",

    fn run(j: *Job, gpa: std.mem.Allocator, io: std.Io) void {
        j.env = .{.{ .name = "machine", .value = std.fmt.bufPrint(&j.index_buf, "{d}", .{j.index}) catch unreachable }};
        var opts = j.opts;
        opts.env = &j.env;
        opts.stdio = .{ .out = &j.out.writer, .err = &j.out.writer };

        var m = h9.Machine.init(gpa, io, opts) catch |e| {
            j.result = std.fmt.allocPrint(gpa, "cannot create machine: {t}", .{e}) catch "";
            return;
        };
        defer m.deinit();
        j.backend = @tagName(m.backend.kind());

        const status = m.run(j.prog, j.argv) catch |e| {
            // err_msg says why for NotFound, NotExecutable and NamespaceFailed.
            const why = if (m.err_msg.len > 0) m.err_msg else @errorName(e);
            j.result = std.fmt.allocPrint(gpa, "failed: {s}", .{why}) catch "";
            return;
        };
        // The status's string lives in the machine, so it's copied before
        // the deferred deinit.
        j.result = switch (status) {
            .exited => |s| std.fmt.allocPrint(gpa, "exited \"{s}\"", .{s}),
            .killed => |s| std.fmt.allocPrint(gpa, "killed \"{s}\"", .{s}),
        } catch "";
    }
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var jobs_n: usize = 1;
    var root_arg: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len and args[i].len > 1 and args[i][0] == '-') : (i += 2) {
        if (i + 1 >= args.len) break;
        if (std.mem.eql(u8, args[i], "-j")) {
            jobs_n = std.fmt.parseInt(usize, args[i + 1], 10) catch 0;
        } else if (std.mem.eql(u8, args[i], "--root")) {
            root_arg = args[i + 1];
        } else break;
    }
    if (i >= args.len or jobs_n == 0) {
        std.debug.print(usage, .{});
        return 2;
    }
    const argv = args[i..];

    // A program with a `/`, `./` or `../` prefix is read on the host, as the
    // CLI does; anything else is looked up in the guest. The a.out's
    // header picks the architecture; a guest program runs the host's. On
    // Windows a host path may use `\` instead.
    var arch: ?h9.vmm.Arch = null;
    const seps = if (builtin.os.tag == .windows) "/\\" else "/";
    const prog: h9.Program = if (std.mem.startsWith(u8, argv[0], "./") or std.mem.startsWith(u8, argv[0], "../") or
        (builtin.os.tag == .windows and (std.mem.startsWith(u8, argv[0], ".\\") or std.mem.startsWith(u8, argv[0], "..\\"))) or
        (root_arg == null and std.mem.indexOfAny(u8, argv[0], seps) != null))
    blk: {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, argv[0], arena, .limited(1 << 30));
        arch = (try h9.aout.parse(bytes)).arch;
        break :blk .{ .bytes = bytes };
    } else .{ .guest = argv[0] };

    // Host paths in Options (root, cwd and the policy's) must be absolute
    // with symlinks resolved.
    const root: ?h9.Root = if (root_arg) |r|
        .{ .dir = try std.Io.Dir.cwd().realPathFileAlloc(io, r, arena) }
    else
        null;

    const base: h9.Machine.Options = .{
        .arch = arch,
        .root = root,
        .policy = .{
            .net = .disable,
            .memory = 256 << 20,
            .timeout_ns = 30 * std.time.ns_per_s,
        },
        .stdio = undefined, // set per job
    };

    const jobs = try arena.alloc(Job, jobs_n);
    const threads = try arena.alloc(std.Thread, jobs_n);
    for (jobs, threads, 0..) |*j, *t, n| {
        var opts = base;
        // HVF allows one VM per host process, so machines after the first
        // use the emulator; it fails with BackendNotBuilt in a build
        // without -Demu=unicorn.
        if (n > 0) opts.backend = .emu;
        j.* = .{ .index = n, .opts = opts, .prog = prog, .argv = argv, .out = .init(gpa) };
        t.* = try std.Thread.spawn(.{}, Job.run, .{ j, gpa, io });
    }
    for (threads) |t| t.join();

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    const w = &stdout.interface;
    var failed = false;
    for (jobs) |*j| {
        defer j.out.deinit();
        try w.print("machine {d} ({s}): {s}\n", .{ j.index, j.backend, j.result });
        const out = std.mem.trimEnd(u8, j.out.written(), "\n");
        var lines = std.mem.splitScalar(u8, out, '\n');
        if (out.len > 0) while (lines.next()) |line| try w.print("  {s}\n", .{line});
        if (!std.mem.eql(u8, j.result, "exited \"\"")) failed = true;
        if (j.result.len > 0) gpa.free(j.result);
    }
    try w.flush();
    return if (failed) 1 else 0;
}
