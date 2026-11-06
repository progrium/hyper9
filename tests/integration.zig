//! Runs real 9front binaries from the root tree through the h9 CLI and
//! checks their output and exit status. Each case is a separate h9 process,
//! so it covers the CLI, root resolution and exit codes end to end.
//!
//! The build passes the h9 binary, the root tree (-Droot, default
//! .local/9front/root) and the backends to test (H9_TEST_BACKENDS, the
//! ones built in) through the environment. Every case runs on each backend
//! that can run arm64 here. Without a root tree, the tests are skipped.
//! `zig build install-tests` builds this file for another target, and
//! `scripts/lima/vm test` runs it in a test VM with the same variables.
//!
//! Each case is tagged with the proposal it proves, by slug or id, at the
//! end of its name: `test "ls /bin | wc -l (demo) [baseline]"`. A case
//! whose proposal isn't implemented skips unless H9_TEST_PENDING is set;
//! the build passes those proposals' tags in (`design.pending_tags`, from
//! design/), so a case stops skipping in the commit that marks its
//! proposal implemented. `zig build proposal -Dp=<id or slug>` runs one
//! proposal's cases, and `zig build design -- check` checks the tags.
//!
//! Interactive cases run h9 on a terminal from tests/term.zig. Their
//! timeouts, and the --timeout of cases that depend on how fast the guest
//! runs, are multiplied by H9_TEST_SLOW (default 1), for emulated VMs.

const std = @import("std");
const builtin = @import("builtin");
const Term = @import("term.zig").Term;
const design = @import("design");

const gpa = std.testing.allocator;

const Env = struct {
    h9: []const u8,
    root: []const u8,
    backends: []const u8,
    /// H9_TEST_ARCH (-Darch), passed to h9 as --arch; null for the host's.
    arch: ?[]const u8,
};

var env_buf: [5][std.Io.Dir.max_path_bytes]u8 = undefined;

/// An environment variable, on every host (getPosix doesn't build on
/// Windows). Values live in one of five slots, chosen by the caller.
fn getenv(comptime slot: usize, key: []const u8) ?[]const u8 {
    var map = std.testing.environ.createMap(gpa) catch return null;
    defer map.deinit();
    const v = map.get(key) orelse return null;
    if (v.len > env_buf[slot].len) return null;
    @memcpy(env_buf[slot][0..v.len], v);
    return env_buf[slot][0..v.len];
}

/// The case's environment. `src` is the case's @src(), whose tags decide
/// whether it's pending.
fn env(comptime src: std.builtin.SourceLocation) !Env {
    try skipPending(src.fn_name);
    const h9 = getenv(0, "H9_TEST_BIN") orelse return error.SkipZigTest;
    const root = getenv(1, "H9_TEST_ROOT") orelse return error.SkipZigTest;
    // The tree from scripts/mkroot.py is arm64, plus the architectures its
    // --arch adds. Without H9_TEST_ARCH, h9 runs the host's architecture,
    // so x86_64 hosts (linux-amd64) skip these.
    const arch = getenv(4, "H9_TEST_ARCH");
    if (arch == null and builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    var cat_buf: [32]u8 = undefined;
    const cat = try std.fmt.bufPrint(&cat_buf, "{s}/bin/cat", .{arch orelse "arm64"});
    std.Io.Dir.cwd().access(std.testing.io, try hostPath(root, cat), .{}) catch return error.SkipZigTest;
    const backends = getenv(2, "H9_TEST_BACKENDS") orelse "auto";
    return .{ .h9 = h9, .root = root, .backends = backends, .arch = arch };
}

/// Skips a case tagged with a proposal that isn't implemented, unless
/// H9_TEST_PENDING is set. `name` is the test's name as @src() gives it.
fn skipPending(name: []const u8) !void {
    if (name.len == 0 or name[name.len - 1] != ']') return;
    const open = std.mem.lastIndexOfScalar(u8, name, '[') orelse return;
    var tags = std.mem.splitScalar(u8, name[open + 1 .. name.len - 1], ',');
    while (tags.next()) |raw| {
        const tag = std.mem.trim(u8, raw, " ");
        var pending = std.mem.tokenizeScalar(u8, design.pending_tags, ' ');
        while (pending.next()) |p| if (std.mem.eql(u8, p, tag)) {
            if (getenv(3, "H9_TEST_PENDING") == null) return error.SkipZigTest;
            return;
        };
    }
}

/// `ms` scaled by H9_TEST_SLOW.
fn slow(ms: u32) u32 {
    const f = std.fmt.parseInt(u32, getenv(3, "H9_TEST_SLOW") orelse "1", 10) catch 1;
    return ms *| @max(f, 1);
}

/// A --timeout value of `ms` scaled by H9_TEST_SLOW, formatted into `buf`.
fn slowTimeout(buf: []u8, ms: u32) []const u8 {
    return std.fmt.bufPrint(buf, "{d}ms", .{slow(ms)}) catch unreachable;
}

var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

fn hostPath(root: []const u8, rel: []const u8) ![]const u8 {
    return std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ root, rel });
}

const Result = struct {
    code: u8,
    out: []u8,
    err: []u8,

    fn deinit(r: Result) void {
        gpa.free(r.out);
        gpa.free(r.err);
    }
};

/// Runs `h9 --root <root> args...` on each backend and returns the first
/// result, after checking that every backend gave the same one.
fn run(e: Env, args: []const []const u8) !Result {
    return runIn(e, args, null);
}

/// Like `run`, with `stdin` (if not null) on the guest's console.
fn runIn(e: Env, args: []const []const u8, stdin: ?[]const u8) !Result {
    var first: ?Result = null;
    errdefer if (first) |f| f.deinit();
    var it = std.mem.tokenizeScalar(u8, e.backends, ',');
    while (it.next()) |backend| {
        const r = try runOn(e, backend, args, stdin);
        if (first) |f| {
            defer r.deinit();
            errdefer std.debug.print("backend {s} differs from {s} for h9 {s}\n", .{ backend, firstBackend(e), args[0] });
            try std.testing.expectEqualStrings(f.out, r.out);
            try std.testing.expectEqual(f.code, r.code);
        } else first = r;
    }
    return first orelse error.SkipZigTest;
}

fn firstBackend(e: Env) []const u8 {
    var it = std.mem.tokenizeScalar(u8, e.backends, ',');
    return it.next() orelse "auto";
}

fn runOn(e: Env, backend: []const u8, args: []const []const u8, stdin: ?[]const u8) !Result {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ e.h9, "--backend", backend, "--root", e.root });
    if (e.arch) |a| try argv.appendSlice(gpa, &.{ "--arch", a });
    try argv.appendSlice(gpa, args);
    const r = try runProcess(argv.items, stdin);
    const code = switch (r.term) {
        .exited => |c| c,
        else => {
            std.debug.print("h9 {s}: {any}\n{s}", .{ args[0], r.term, r.stderr });
            gpa.free(r.stdout);
            gpa.free(r.stderr);
            return error.Crashed;
        },
    };
    return .{ .code = code, .out = r.stdout, .err = r.stderr };
}

/// std.process.run, with `stdin` written to a pipe (closed at the end) or,
/// if null, the null device.
fn runProcess(argv: []const []const u8, stdin: ?[]const u8) !std.process.RunResult {
    const io = std.testing.io;
    const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(slow(30_000)), .clock = .awake } };
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = if (stdin != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
    });
    defer child.kill(io);
    if (stdin) |data| {
        // Small inputs fit in the pipe, so this doesn't wait on the reader.
        child.stdin.?.writeStreamingAll(io, data) catch {};
        child.stdin.?.close(io);
        child.stdin = null;
    }
    var mr_buf: std.Io.File.MultiReader.Buffer(2) = undefined;
    var mr: std.Io.File.MultiReader = undefined;
    mr.init(gpa, io, mr_buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();
    while (mr.fill(64, timeout)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try mr.checkAnyError();
    const term = try child.wait(io);
    const out = try mr.toOwnedSlice(0);
    errdefer gpa.free(out);
    return .{ .term = term, .stdout = out, .stderr = try mr.toOwnedSlice(1) };
}

test "cat /lib/namespace (demo) [baseline]" {
    const e = try env(@src());
    const want = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try hostPath(e.root, "lib/namespace"), gpa, .unlimited);
    defer gpa.free(want);
    const r = try run(e, &.{ "/bin/cat", "/lib/namespace" });
    defer r.deinit();
    try std.testing.expectEqualStrings("", r.err);
    try std.testing.expectEqualStrings(want, r.out);
    try std.testing.expectEqual(0, r.code);
}

test "echo [baseline]" {
    const e = try env(@src());
    const r = try run(e, &.{ "echo", "hello,", "world" });
    defer r.deinit();
    try std.testing.expectEqualStrings("hello, world\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "--check passes with the root tree, and --version and -h print to stdout [baseline]" {
    const e = try env(@src());
    var it = std.mem.tokenizeScalar(u8, e.backends, ',');
    while (it.next()) |backend| {
        errdefer std.debug.print("backend {s}\n", .{backend});
        const r = try runOn(e, backend, &.{"--check"}, null);
        defer r.deinit();
        try std.testing.expectEqual(0, r.code);
        try std.testing.expect(std.mem.indexOf(u8, r.out, "/bin/echo runs") != null);
    }
    const missing = try runProcess(&.{ e.h9, "--root", "/nonexistent-h9-root", "--check" }, null);
    defer gpa.free(missing.stdout);
    defer gpa.free(missing.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 125 }, missing.term);
    try std.testing.expect(std.mem.indexOf(u8, missing.stdout, "not found") != null);

    const v = try runProcess(&.{ e.h9, "--version" }, null);
    defer gpa.free(v.stdout);
    defer gpa.free(v.stderr);
    try std.testing.expect(std.mem.startsWith(u8, v.stdout, "h9 "));
    try std.testing.expect(std.mem.indexOf(u8, v.stdout, "\nbackends: ") != null);
    const h = try runProcess(&.{ e.h9, "-h" }, null);
    defer gpa.free(h.stdout);
    defer gpa.free(h.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, h.term);
    try std.testing.expect(std.mem.startsWith(u8, h.stdout, "usage: h9"));
}

test "no root tree gives 125 for a guest program [baseline]" {
    const e = try env(@src());
    const io = std.testing.io;
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    // A copy of h9 has no .local/9front/root two levels up to default to.
    const name = std.fs.path.basename(e.h9);
    try std.Io.Dir.copyFile(std.Io.Dir.cwd(), e.h9, s.tmp.dir, name, io, .{});
    const h9 = try std.fs.path.join(gpa, &.{ s.path, name });
    defer gpa.free(h9);
    var environ = try std.testing.environ.createMap(gpa);
    defer environ.deinit();
    _ = environ.swapRemove("H9ROOT");
    for ([_][]const []const u8{ &.{ h9, "echo", "x" }, &.{ h9, "--rc", "echo x" } }) |argv| {
        var child = try std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore, .environ_map = &environ, .create_no_window = true });
        defer child.kill(io);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 125 }, try child.wait(io));
    }
}

test "exits string gives status 1 and is printed [baseline]" {
    const e = try env(@src());
    const r = try run(e, &.{ "/bin/cat", "/does/not/exist" });
    defer r.deinit();
    try std.testing.expectEqual(1, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "/does/not/exist") != null);
}

test "missing program gives 127 [baseline]" {
    const e = try env(@src());
    const r = try run(e, &.{"no-such-program"});
    defer r.deinit();
    try std.testing.expectEqual(127, r.code);
}

test "non-a.out program gives 126 [baseline]" {
    const e = try env(@src());
    const r = try run(e, &.{"/lib/namespace"});
    defer r.deinit();
    try std.testing.expectEqual(126, r.code);
}

test "a guest #! script runs as the first program [baseline]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "greet", .data = "#!/bin/rc\necho $0 $*\n" });
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "nointerp", .data = "#!/no/such/rc\n" });
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "empty", .data = "#!\n" });

    // By $path: /rc/bin is bound on /bin, and lc is an rc script.
    const lc = try run(e, &.{ "lc", "-d", "/rc" });
    defer lc.deinit();
    try std.testing.expectEqual(0, lc.code);
    try std.testing.expectEqualStrings("rc/\n", lc.out);

    // By guest path; argv is built as exec builds it.
    const r = try run(e, &.{ "--cwd", s.path, "/mnt/term/cwd/greet", "a", "b" });
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("/mnt/term/cwd/greet a b\n", r.out);

    const ni = try run(e, &.{ "--cwd", s.path, "/mnt/term/cwd/nointerp" });
    defer ni.deinit();
    try std.testing.expectEqual(127, ni.code);
    const em = try run(e, &.{ "--cwd", s.path, "/mnt/term/cwd/empty" });
    defer em.deinit();
    try std.testing.expectEqual(126, em.code);
}

test "stdin reaches the guest's console [baseline]" {
    const e = try env(@src());
    const r = try runIn(e, &.{"wc"}, "a b\nc\n");
    defer r.deinit();
    try std.testing.expectEqualStrings("      2       3       6\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "directory reads return every entry [baseline]" {
    const e = try env(@src());
    // More entries than one host readdir buffer holds, so a read split
    // across guest pages, or across kernel calls, would end the listing early.
    const r = try run(e, &.{ "ls", "/arm64/bin" });
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqual(try countDir(e, "arm64/bin"), std.mem.count(u8, r.out, "\n"));
}

/// The number of entries in a directory of the root tree.
fn countDir(e: Env, rel: []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, try hostPath(e.root, rel), .{ .iterate = true });
    defer dir.close(std.testing.io);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(std.testing.io)) |_| n += 1;
    return n;
}

test "the host environment isn't imported [baseline]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--env", "h9test=yes", "ls", "/env" });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.out, "/env/h9test\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "/env/user\n") != null);
    // HOME is set in every host environment that runs these tests.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "/env/HOME") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "/env/PATH") == null);
}

test "the host cwd is the guest's cwd [baseline]" {
    const e = try env(@src());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "note", .data = "from the host cwd\n" });
    var p: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &p);
    const r = try run(e, &.{ "--cwd", p[0..n], "cat", "note" });
    defer r.deinit();
    try std.testing.expectEqualStrings("from the host cwd\n", r.out);
    const pwd = try run(e, &.{ "--cwd", p[0..n], "pwd" });
    defer pwd.deinit();
    try std.testing.expectEqualStrings("/mnt/term/cwd\n", pwd.out);
}

/// A scratch host directory, resolved, for cwd and policy tests.
const Scratch = struct {
    tmp: std.testing.TmpDir,
    path: []const u8,
    buf: [std.Io.Dir.max_path_bytes]u8 = undefined,

    fn init(s: *Scratch) !void {
        s.tmp = std.testing.tmpDir(.{});
        const n = try s.tmp.dir.realPath(std.testing.io, &s.buf);
        s.path = s.buf[0..n];
    }
    fn deinit(s: *Scratch) void {
        s.tmp.cleanup();
    }
    fn exists(s: *Scratch, name: []const u8) bool {
        s.tmp.dir.access(std.testing.io, name, .{}) catch return false;
        return true;
    }
};

test "tight profile: writing to the cwd fails (demo) [baseline]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const r = try run(e, &.{ "--cwd", s.path, "--profile=tight", "--rc", "echo x > /mnt/term/cwd/f" });
    defer r.deinit();
    try std.testing.expectEqual(1, r.code);
    try std.testing.expect(!s.exists("f"));
}

test "default profile: the cwd is writable and the root isn't [baseline]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const r = try run(e, &.{ "--cwd", s.path, "touch", "f" });
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(s.exists("f"));
    const ro = try run(e, &.{ "--cwd", s.path, "touch", "/lib/h9-test" });
    defer ro.deinit();
    try std.testing.expectEqual(1, ro.code);
    std.Io.Dir.cwd().access(std.testing.io, try hostPath(e.root, "lib/h9-test"), .{}) catch return;
    return error.RootWasWritten;
}

test "--sandbox DIR is writable [baseline]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const r = try run(e, &.{ "--sandbox", s.path, "touch", "f" });
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(s.exists("f"));
}

test "--writable under a read-only cwd [baseline]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.createDirPath(std.testing.io, "out");
    var p: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const out = try std.fmt.bufPrint(&p, "{s}/out", .{s.path});
    const r = try run(e, &.{ "--cwd", s.path, "--profile=tight", "--writable", out, "touch", "out/f" });
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(s.exists("out/f"));
    const g = try run(e, &.{ "--cwd", s.path, "--profile=tight", "--writable", out, "touch", "g" });
    defer g.deinit();
    try std.testing.expectEqual(1, g.code);
    try std.testing.expect(!s.exists("g"));
}

test "--read-deny hides a path, and symlinks can't escape [baseline]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".env", .data = "secret\n" });
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ok", .data = "ok\n" });
    var p: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const deny = try std.fmt.bufPrint(&p, "{s}/.env", .{s.path});
    const r = try run(e, &.{ "--cwd", s.path, "--read-deny", deny, "ls" });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.out, "ok\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, ".env") == null);

    // A symlink out of the cwd, to a file in no bound tree.
    var other: Scratch = undefined;
    try other.init();
    defer other.deinit();
    try other.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "secret", .data = "secret\n" });
    var lp: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try s.tmp.dir.symLink(std.testing.io, try std.fmt.bufPrint(&lp, "{s}/secret", .{other.path}), "link", .{});
    const l = try run(e, &.{ "--cwd", s.path, "cat", "link" });
    defer l.deinit();
    try std.testing.expectEqual(1, l.code);
    try std.testing.expectEqualStrings("", l.out);
}

test "masked devices can't be attached [baseline]" {
    const e = try env(@src());
    const r = try run(e, &.{ "ls", "#U/" });
    defer r.deinit();
    try std.testing.expectEqual(1, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "mount/attach disallowed") != null);
    const n = try run(e, &.{ "--profile=tight", "ls", "#I" });
    defer n.deinit();
    try std.testing.expect(std.mem.indexOf(u8, n.err, "mount/attach disallowed") != null);
}

test "--print shows the plan and doesn't run [baseline]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--print", "--profile=tight", "--memory", "512m", "--timeout", "1m", "no-such-program" });
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "profile:  tight\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "net.disable") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "memory=512M timeout=1m") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "devmask:  #C #I #U\n") != null);
}

test "--strict refuses what this build can't enforce [baseline]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--strict", "--write=overlay", "echo" });
    defer r.deinit();
    try std.testing.expectEqual(2, r.code);
    const ok = try run(e, &.{ "--strict", "--profile=tight", "echo", "ok" });
    defer ok.deinit();
    try std.testing.expectEqual(0, ok.code);
}

test "--memory caps guest memory [baseline]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--memory", "64k", "echo", "x" });
    defer r.deinit();
    try std.testing.expectEqual(125, r.code);
    // The stack grows on demand, so 8 MiB is plenty for echo.
    const ok = try run(e, &.{ "--memory", "8m", "echo", "x" });
    defer ok.deinit();
    try std.testing.expectEqual(0, ok.code);
}

test "--timeout stops the program [baseline]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--timeout", "200ms", "sleep", "10" });
    defer r.deinit();
    try std.testing.expectEqual(1, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "h9: timeout") != null);
}

test "renames and case can't get around the rules [baseline]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.createDirPath(std.testing.io, "sub");
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sub/secret", .data = "secret\n" });
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".env", .data = "secret\n" });
    var p1: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var p2: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const deny1 = try std.fmt.bufPrint(&p1, "{s}/sub/secret", .{s.path});
    const deny2 = try std.fmt.bufPrint(&p2, "{s}/.env", .{s.path});
    const mv = try run(e, &.{ "--cwd", s.path, "--read-deny", deny1, "mv", "sub", "sub2" });
    defer mv.deinit();
    try std.testing.expectEqual(1, mv.code);
    try std.testing.expect(s.exists("sub/secret"));
    // On case-insensitive hosts .ENV is .env; creating it mustn't truncate it.
    const tc = try run(e, &.{ "--cwd", s.path, "--read-deny", deny2, "touch", ".ENV" });
    defer tc.deinit();
    const data = try s.tmp.dir.readFileAlloc(std.testing.io, ".env", gpa, .limited(64));
    defer gpa.free(data);
    try std.testing.expectEqualStrings("secret\n", data);
}

// Process trees.

test "ls /bin | wc -l (demo) [baseline]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--rc", "ls /bin | wc -l" });
    defer r.deinit();
    try std.testing.expectEqualStrings("", r.err);
    var bin_buf: [32]u8 = undefined;
    const bin = try std.fmt.bufPrint(&bin_buf, "{s}/bin", .{e.arch orelse "arm64"});
    const want = try countDir(e, bin) + try countDir(e, "rc/bin");
    const got = try std.fmt.parseInt(usize, std.mem.trim(u8, r.out, " \n"), 10);
    try std.testing.expectEqual(want, got);
    try std.testing.expectEqual(0, r.code);
}

test "a pipeline reads the guest's stdin [baseline]" {
    const e = try env(@src());
    const r = try runIn(e, &.{ "--rc", "sed s/h/j/ | wc -c" }, "hello\n");
    defer r.deinit();
    try std.testing.expectEqualStrings("6\n", std.mem.trimStart(u8, r.out, " "));
    try std.testing.expectEqual(0, r.code);
}

test "exit status comes back through await [baseline]" {
    const e = try env(@src());
    const ok = try run(e, &.{ "--rc", "test -e /lib/namespace" });
    defer ok.deinit();
    try std.testing.expectEqual(0, ok.code);
    const bad = try run(e, &.{ "--rc", "test -e /no/such/file" });
    defer bad.deinit();
    try std.testing.expectEqual(1, bad.code);
    const st = try run(e, &.{ "--rc", "cat /no/such/file >[2]/dev/null; echo $status" });
    defer st.deinit();
    try std.testing.expect(std.mem.indexOf(u8, st.out, "cat ") != null);
    try std.testing.expectEqual(0, st.code);
}

test "exec replaces the process [baseline]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--rc", "exec echo replaced; echo not reached" });
    defer r.deinit();
    try std.testing.expectEqualStrings("replaced\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "/fd is devdup [baseline]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--rc", "echo through fd | cat /fd/0" });
    defer r.deinit();
    try std.testing.expectEqualStrings("through fd\n", r.out);
}

test "many processes, one after another [baseline]" {
    const e = try env(@src());
    // More than HVF's 64 vCPUs in total, so each exit has to free its vCPU.
    const r = try run(e, &.{ "--rc", "for(i in `{seq 100}) echo $i | wc -l >/dev/null; echo done" });
    defer r.deinit();
    try std.testing.expectEqualStrings("done\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "more live processes than HVF has vCPUs [baseline]" {
    const e = try env(@src());
    // 80 processes alive at once, all but the first blocked reading a pipe.
    // rc builds the pipeline: Windows Defender blocks a host command line
    // of 79 "| cat"s as Trojan:Win32/Commando.A!ml.
    const r = try run(e, &.{ "--rc", "c='echo deep'; for(i in `{seq 79}) c=$c^' | cat'; eval $c" });
    defer r.deinit();
    try std.testing.expectEqualStrings("deep\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "concurrent processes contending for one environment don't hang" {
    const e = try env(@src());
    // 8 processes sharing /env, each creating 150 variables, then running
    // rc. Before kern locks were pthread mutexes, an unordered unlock
    // corrupted QLock queues on arm64 and most runs hung.
    const script =
        \\for(j in `{seq 8}){
        \\    @{
        \\        for(k in `{seq 150}) { v$k=$k }
        \\        /bin/rc -c 'echo -n'
        \\    } &
        \\}
        \\wait
        \\echo done
    ;
    var tb: [16]u8 = undefined;
    for (0..3) |_| {
        const r = try run(e, &.{ "--timeout", slowTimeout(&tb, 15_000), "--rc", script });
        defer r.deinit();
        try std.testing.expectEqualStrings("done\n", r.out);
        try std.testing.expectEqual(0, r.code);
    }
}

test "--pids caps the process count [baseline]" {
    const e = try env(@src());
    // rc plus ls and wc is three processes.
    const capped = try run(e, &.{ "--pids", "2", "--rc", "ls /bin | wc -l" });
    defer capped.deinit();
    try std.testing.expect(capped.code != 0);
    const ok = try run(e, &.{ "--pids", "3", "--rc", "ls /bin | wc -l" });
    defer ok.deinit();
    try std.testing.expectEqual(0, ok.code);
}

test "--cpus 1 still runs a pipeline [baseline]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--cpus", "1", "--rc", "echo one | cat | cat" });
    defer r.deinit();
    try std.testing.expectEqualStrings("one\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "--ns replays a namespace file [baseline]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ns", .data = "bind /sys/lib /lib\n" });
    const r = try run(e, &.{ "--cwd", s.path, "--ns", "ns", "ls", "-d", "/lib/acid" });
    defer r.deinit();
    try std.testing.expectEqualStrings("/lib/acid\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

// Ephemeral writes and a private /tmp (design/0006-ephemeral-writes.md).

/// `h9 --cwd <s> --write=ephemeral args...`.
fn runEph(e: Env, s: *Scratch, args: []const []const u8) !Result {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "--cwd", s.path, "--write=ephemeral" });
    try argv.appendSlice(gpa, args);
    return run(e, argv.items);
}

/// The contents of `name` in the scratch dir, or null if it's not there.
fn hostFile(s: *Scratch, name: []const u8, buf: []u8) ?[]u8 {
    return s.tmp.dir.readFile(std.testing.io, name, buf) catch null;
}

test "a new file in an ephemeral cwd is readable and absent on the host afterwards [6]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const r = try runEph(e, &s, &.{ "--rc", "echo hi > f && cat f" });
    defer r.deinit();
    try std.testing.expectEqualStrings("hi\n", r.out);
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(!s.exists("f"));
}

test "writing an existing host file changes it in the guest only [6]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f", .data = "host\n" });
    const r = try runEph(e, &s, &.{ "--rc", "echo guest > f && echo more >> f && cat f" });
    defer r.deinit();
    try std.testing.expectEqualStrings("guest\nmore\n", r.out);
    var b: [16]u8 = undefined;
    try std.testing.expectEqualStrings("host\n", hostFile(&s, "f", &b).?);
}

test "removing a host file hides it in the guest only [6]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f", .data = "host\n" });
    const r = try runEph(e, &s, &.{ "--rc", "rm f; if(test -e f) echo there; if not echo gone; ls" });
    defer r.deinit();
    try std.testing.expectEqualStrings("gone\n", r.out);
    try std.testing.expect(s.exists("f"));
}

test "rm then recreate, as mk clean && mk does, works [6]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "x.o", .data = "old\n" });
    const r = try runEph(e, &s, &.{ "--rc", "rm -f *.o && echo new > x.o && cat x.o" });
    defer r.deinit();
    try std.testing.expectEqualStrings("new\n", r.out);
    try std.testing.expectEqual(0, r.code);
    var b: [16]u8 = undefined;
    try std.testing.expectEqualStrings("old\n", hostFile(&s, "x.o", &b).?);
}

test "a file rename moves it in the guest only [6]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = "a\n" });
    const r = try runEph(e, &s, &.{ "--rc", "mv a b && cat b && ls" });
    defer r.deinit();
    try std.testing.expectEqualStrings("a\nb\n", r.out);
    try std.testing.expect(s.exists("a"));
    try std.testing.expect(!s.exists("b"));
}

test "renaming a host directory is refused [6]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.createDirPath(std.testing.io, "d");
    const r = try runEph(e, &s, &.{ "--rc", "mv d e" });
    defer r.deinit();
    try std.testing.expectEqual(1, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "permission denied") != null);
    try std.testing.expect(s.exists("d"));
    try std.testing.expect(!s.exists("e"));
}

test "ls of an overlaid directory lists each name once [6]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a", .data = "a\n" });
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b", .data = "b\n" });
    const r = try runEph(e, &s, &.{ "--rc", "echo x > a; echo y > c; rm b; echo z > b; ls" });
    defer r.deinit();
    try std.testing.expectEqualStrings("a\nb\nc\n", r.out);
}

test "a --writable path inside a read-only cwd is ephemeral [6]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.createDirPath(std.testing.io, "out");
    var p: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const out = try std.fmt.bufPrint(&p, "{s}/out", .{s.path});
    const plan = try run(e, &.{ "--cwd", s.path, "--profile=tight", "--write=ephemeral", "--writable", out, "--print", "echo" });
    defer plan.deinit();
    try std.testing.expect(std.mem.indexOf(u8, plan.out, "bind -c '#O' /mnt/term/cwd/out") != null);
    const r = try run(e, &.{ "--cwd", s.path, "--profile=tight", "--write=ephemeral", "--writable", out, "--rc", "touch out/f && ls out" });
    defer r.deinit();
    try std.testing.expectEqualStrings("out/f\n", r.out);
    try std.testing.expect(!s.exists("out/f"));
}

test "--read-deny still hides a path inside an ephemeral tree [6]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".env", .data = "secret\n" });
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ok", .data = "ok\n" });
    var p: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const deny = try std.fmt.bufPrint(&p, "{s}/.env", .{s.path});
    const r = try runEph(e, &s, &.{ "--read-deny", deny, "--rc", "echo new > n; ls; cat .env" });
    defer r.deinit();
    try std.testing.expectEqualStrings("n\nok\n", r.out);
    try std.testing.expectEqual(1, r.code);
}

test "the tight profile's cwd is ephemeral under --write=ephemeral [6]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const r = try runEph(e, &s, &.{ "--profile=tight", "--rc", "echo x > f && cat f" });
    defer r.deinit();
    try std.testing.expectEqualStrings("x\n", r.out);
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(!s.exists("f"));
}

test "/tmp is private and writable in both profiles [6]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    for ([_][]const u8{ "--profile=default", "--profile=tight" }) |prof| {
        const r = try run(e, &.{ "--cwd", s.path, prof, "--rc", "echo hi > /tmp/h9-ephemeral-test && cat /tmp/h9-ephemeral-test" });
        defer r.deinit();
        try std.testing.expectEqualStrings("hi\n", r.out);
        try std.testing.expectEqual(0, r.code);
    }
    // Not in the host's temp dir.
    for ([_][]const u8{ "/tmp/h9-ephemeral-test", "/private/tmp/h9-ephemeral-test" }) |h| {
        if (std.Io.Dir.cwd().access(std.testing.io, h, .{})) |_| return error.HostTmpWritten else |_| {}
    }
    if (getenv(3, "TMPDIR")) |td| {
        var p: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const h = try std.fmt.bufPrint(&p, "{s}/h9-ephemeral-test", .{std.mem.trimEnd(u8, td, "/")});
        if (std.Io.Dir.cwd().access(std.testing.io, h, .{})) |_| return error.HostTmpWritten else |_| {}
    }
}

test "/tmp is read-only under --write=none [6]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--write=none", "--rc", "echo x > /tmp/f" });
    defer r.deinit();
    try std.testing.expectEqual(1, r.code);
}

test "filling an overlay fails with file system full and the machine carries on [6]" {
    const e = try env(@src());
    // A failed write keeps nothing, so up to one 4 MiB block is free again
    // for rm to run.
    const r = try run(e, &.{ "--memory", "32m", "--rc", "dd -if /dev/zero -of /tmp/big -bs 4194304 -count 16; rm /tmp/big; echo small > /tmp/s && cat /tmp/s" });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.err, "file system full") != null);
    try std.testing.expectEqualStrings("small\n", r.out);
}

test "creating empty files until memory runs out fails with file system full [6]" {
    const e = try env(@src());
    // rc makes the files itself, without forking: no memory is left for
    // another process. A redirection with no command doesn't set $status
    // when it works, so there's nothing to test in the loop; when one
    // fails, rc prints the error and leaves the script.
    const r = try run(e, &.{ "--memory", "32m", "--rc", "for(i in `{seq 150000}) >/tmp/e$i; exit never" });
    defer r.deinit();
    try std.testing.expectEqual(1, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "file system full") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "never") == null);
}

test "renaming a directory marker is refused [6]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.createDirPath(std.testing.io, "d");
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "d/x", .data = "x\n" });
    const r = try runEph(e, &s, &.{ "--rc", "echo y > d/x && mv d e" });
    defer r.deinit();
    try std.testing.expectEqual(1, r.code);
    try std.testing.expect(s.exists("d/x"));
    try std.testing.expect(!s.exists("e"));
}

test "--strict accepts --write=ephemeral, and --print shows the overlays [6]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const r = try runEph(e, &s, &.{ "--strict", "--print", "echo" });
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "fs.write.ephemeral") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "unenforced") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "  bind -c '#O' /mnt/term/cwd ") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "  bind -c '#O' /tmp ") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "  eph  ") != null);
    const ok = try runEph(e, &s, &.{ "--strict", "echo", "ok" });
    defer ok.deinit();
    try std.testing.expectEqual(0, ok.code);
}

test "--print output with overlays replays with --ns [6]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const p = try runEph(e, &s, &.{ "--print", "echo" });
    defer p.deinit();
    // The namespace section, as a file the guest reads from its cwd.
    const start = (std.mem.indexOf(u8, p.out, "namespace:\n") orelse return error.NoNamespace) + "namespace:\n".len;
    const end = std.mem.indexOfPos(u8, p.out, start, "access:\n") orelse p.out.len;
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ns", .data = p.out[start..end] });
    // Under --write=none the replay's overlays make the cwd and /tmp writable.
    const r = try run(e, &.{ "--cwd", s.path, "--write=none", "--ns", "ns", "--rc", "echo x > f && echo y > /tmp/g && cat f /tmp/g" });
    defer r.deinit();
    try std.testing.expectEqualStrings("x\ny\n", r.out);
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(!s.exists("f"));
}

test "removing every .c file in a source tree leaves the host unchanged (demo) [6]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    for ([_][]const u8{ "cat.c", "ls.c", "mkfile" }) |name| try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = name });
    const r = try runEph(e, &s, &.{ "--rc", "rm -f *.c && echo gone > x && ls" });
    defer r.deinit();
    try std.testing.expectEqualStrings("mkfile\nx\n", r.out);
    try std.testing.expect(s.exists("cat.c") and s.exists("ls.c") and !s.exists("x"));
}

// The terminal. These run h9 on a pty or pseudoconsole from tests/term.zig.

/// Enter, as a terminal sends it: cooked mode turns it into a newline on
/// every host.
const enter = "\r";

/// rc's prompt. ConPTY redraws the screen rather than passing output
/// through, and draws the trailing space of "% " as a cursor movement.
const prompt = "%";

/// Runs `h9 --backend <backend> --root <root> args...` on a new terminal.
fn spawnTerm(e: Env, backend: []const u8, args: []const []const u8) !Term {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ e.h9, "--backend", backend, "--root", e.root });
    if (e.arch) |a| try argv.appendSlice(gpa, &.{ "--arch", a });
    try argv.appendSlice(gpa, args);
    return Term.spawn(gpa, argv.items);
}

fn backendList(e: Env) std.mem.TokenIterator(u8, .scalar) {
    return std.mem.tokenizeScalar(u8, e.backends, ',');
}

test "an interactive rc reads typed lines [baseline]" {
    const e = try env(@src());
    var it = backendList(e);
    while (it.next()) |backend| {
        errdefer std.debug.print("backend {s}\n", .{backend});
        var t = try spawnTerm(e, backend, &.{ "rc", "-i" });
        defer t.deinit();
        try t.expect(prompt, slow(10_000));
        // The output, xy, isn't in the echoed input, echo x^y.
        try t.send("echo x^y" ++ enter);
        try t.expect("xy", slow(10_000));
        try t.expect(prompt, slow(10_000));
        try t.send("exit" ++ enter);
        try std.testing.expectEqual(0, try t.wait(slow(10_000)));
    }
}

// Notes and /proc.

test "a write to a closed pipe kills the writer with the note and its pc [baseline]" {
    const e = try env(@src());
    // whatis is an rc builtin, so the writer is rc itself; before notes
    // were delivered it ignored the failed write and looped forever.
    const r = try run(e, &.{ "--timeout", "20s", "--rc", "{ while() whatis path } | sed 1q; echo $status" });
    defer r.deinit();
    var lines = std.mem.splitScalar(u8, r.out, '\n');
    try std.testing.expectEqualStrings("path=(. /bin)", lines.next().?);
    try std.testing.expect(std.mem.indexOf(u8, lines.next().?, ": sys: write on closed pipe pc=0x") != null);
    try std.testing.expectEqual(0, r.code);
}

test "--timeout stops a console read on a terminal at once [baseline]" {
    const e = try env(@src());
    var it = backendList(e);
    while (it.next()) |backend| {
        errdefer std.debug.print("backend {s}\n", .{backend});
        var t = try spawnTerm(e, backend, &.{ "--timeout", "500ms", "--rc", "echo ready; read" });
        defer t.deinit();
        try t.expect("ready", slow(10_000));
        // Before the reader thread, the read held the machine until a
        // 500 ms grace period ran out, and h9 exited without freeing it.
        try std.testing.expectEqual(1, try t.wait(slow(1_500)));
        try t.expect("h9: timeout", slow(1_000));
    }
}

test "kill and ps work in an interactive rc (demo) [baseline]" {
    const e = try env(@src());
    var it = backendList(e);
    while (it.next()) |backend| {
        errdefer std.debug.print("backend {s}\n", .{backend});
        var t = try spawnTerm(e, backend, &.{ "--timeout", "60s", "rc", "-i" });
        defer t.deinit();
        try t.expect(prompt, slow(10_000));
        try t.send("sleep 1000 &" ++ enter);
        try t.expect(prompt, slow(10_000));
        // ps names each process by its program, so only sleep's line matches.
        try t.send("ps | grep -c sle^ep" ++ enter);
        try t.expect("\n1", slow(10_000));
        try t.expect(prompt, slow(10_000));
        try t.send("kill sleep | rc" ++ enter);
        try t.expect(prompt, slow(10_000));
        try t.send("wait; ps | grep -c sle^ep" ++ enter);
        try t.expect("\n0", slow(10_000));
        try t.expect(prompt, slow(10_000));
        try t.send("exit" ++ enter);
        _ = try t.wait(slow(10_000));
    }
}

test "Ctrl-C interrupts the foreground command and rc carries on [baseline]" {
    const e = try env(@src());
    var it = backendList(e);
    while (it.next()) |backend| {
        errdefer std.debug.print("backend {s}\n", .{backend});
        var t = try spawnTerm(e, backend, &.{ "--timeout", "60s", "rc", "-i" });
        defer t.deinit();
        try t.expect(prompt, slow(10_000));
        try t.send("sleep 1000" ++ enter);
        try t.drain(slow(500));
        try t.send("\x03");
        try t.expect(prompt, slow(10_000));
        try t.send("echo x^y" ++ enter);
        try t.expect("xy", slow(10_000));
        try t.send("exit" ++ enter);
        _ = try t.wait(slow(10_000));
    }
}

test "a second Ctrl-C within a second tears the machine down [baseline]" {
    const e = try env(@src());
    var it = backendList(e);
    while (it.next()) |backend| {
        errdefer std.debug.print("backend {s}\n", .{backend});
        // rc traps interrupt and loops, so only the second Ctrl-C stops it.
        var t = try spawnTerm(e, backend, &.{ "--timeout", "60s", "--rc", "fn sigint {}; echo ready; while() sleep 1" });
        defer t.deinit();
        try t.expect("ready", slow(10_000));
        try t.send("\x03");
        try t.drain(100);
        try t.send("\x03");
        try std.testing.expect(try t.wait(slow(5_000)) != 0);
    }
}

test "rawon puts the host terminal in raw mode until exit [baseline]" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // no termios to check
    const e = try env(@src());
    var it = backendList(e);
    while (it.next()) |backend| {
        errdefer std.debug.print("backend {s}\n", .{backend});
        var t = try spawnTerm(e, backend, &.{ "--timeout", "60s", "--rc", ">[3]/dev/consctl { echo rawon >[1=3]; echo ready; read >/dev/null }" });
        defer t.deinit();
        // consctl is on fd 3: rc execs read in place, and closing the last
        // consctl (as >/dev/null over it would) turns raw off.
        try t.expect("ready", slow(10_000));
        try std.testing.expect(!t.cooked());
        // Raw mode doesn't turn \r into \n, so read needs a newline.
        try t.send("x\n");
        try std.testing.expectEqual(0, try t.wait(slow(10_000)));
        try std.testing.expect(t.cooked());
    }
}

/// Prints ready and waits for a hangup. rc execs a last simple command in
/// place, dropping its handler, so sleep isn't last. A note that reaches rc
/// as it sets up sleep is only acted on once sleep ends, so the tests wait
/// for sleep to start before hanging up.
const hangup_wait = "echo ready; sleep 1000; echo after";

test "closing the terminal posts hangup [baseline]" {
    const e = try env(@src());
    var it = backendList(e);
    while (it.next()) |backend| {
        errdefer std.debug.print("backend {s}\n", .{backend});
        // The terminal is gone, so the handler leaves its mark in a file.
        var s: Scratch = undefined;
        try s.init();
        defer s.deinit();
        var t = try spawnTerm(e, backend, &.{ "--timeout", "60s", "--cwd", s.path, "--rc", "fn sighup { echo >hup }; " ++ hangup_wait });
        defer t.deinit();
        try t.expect("ready", slow(10_000));
        try t.drain(slow(500));
        t.hangup();
        _ = try t.wait(slow(5_000));
        try std.testing.expect(s.exists("hup"));
    }
}

test "SIGTERM posts hangup [baseline]" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const e = try env(@src());
    var it = backendList(e);
    while (it.next()) |backend| {
        errdefer std.debug.print("backend {s}\n", .{backend});
        var t = try spawnTerm(e, backend, &.{ "--timeout", "60s", "--rc", "fn sighup { echo got hangup }; " ++ hangup_wait });
        defer t.deinit();
        try t.expect("ready", slow(10_000));
        try t.drain(slow(500));
        t.signal(.TERM);
        try t.expect("got hangup", slow(5_000));
        _ = try t.wait(slow(5_000));
    }
}

test "a note handler catches a note and the process continues [baseline]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--timeout", "20s", "--rc", "fn sighup { echo caught }; echo hangup >/proc/$pid/note; echo after" });
    defer r.deinit();
    try std.testing.expectEqualStrings("caught\nafter\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "an unhandled note kills the process with the note as its status [baseline]" {
    const e = try env(@src());
    // An inner rc waits for sleep and nothing else: rc drops the wait record
    // of a background child that exits while it waits for a foreground one
    // (echo, here). The note goes out once sleep has exec'd, as before that
    // the child is still rc, which would catch it.
    const script =
        \\rc -c 'sleep 1000 & wait $apid; echo $status' &
        \\w=$apid
        \\p=()
        \\while(~ $#p 0) p=`{awk 'FNR==1 && $1=="sleep" {split(FILENAME, a, "/"); print a[3]}' /proc/*/status >[2]/dev/null}
        \\echo die >/proc/$p/note
        \\wait $w
    ;
    const r = try run(e, &.{ "--timeout", "20s", "--rc", script });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.out, "die") != null);
    try std.testing.expectEqual(0, r.code);
}

test "--timeout posts hangup before tearing down [baseline]" {
    const e = try env(@src());
    // rc must define sighup before the timeout, which takes a few guest
    // process starts on a slow host.
    var tb: [16]u8 = undefined;
    const r = try run(e, &.{ "--timeout", slowTimeout(&tb, 300), "--rc", "fn sighup { echo got hangup }; sleep 10; echo after" });
    defer r.deinit();
    // rc execs a last simple command in place, dropping its handler, so
    // sleep isn't last here.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "got hangup") != null);
}

test "/proc/n/ctl kill stops a process [baseline]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--timeout", "20s", "--rc", "sleep 1000 & echo kill >/proc/$apid/ctl; wait; echo done" });
    defer r.deinit();
    try std.testing.expectEqualStrings("done\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "notepg reaches the note group and not a new one [baseline]" {
    const e = try env(@src());
    // The block in braces makes its own note group (rfork s), so the
    // hangup posted to rc's group doesn't reach it; sleep 1000 is in rc's.
    const r = try run(e, &.{ "--timeout", "20s", "--rc", "fn sighup {}; { rfork s; sleep 1; echo survived } & sleep 1000 & echo hangup >/proc/$pid/notepg; wait; echo done" });
    defer r.deinit();
    try std.testing.expectEqualStrings("survived\ndone\n", r.out);
}

test "/proc/n has status, fd, ns and args [baseline]" {
    const e = try env(@src());
    // The times differ between runs, so only name, user and state; and
    // with awk last, cat isn't exec'd in place of rc.
    const st = try run(e, &.{ "--rc", "cat /proc/$pid/status | awk '{print $1, ($2 == ENVIRON[\"user\"]), $3}'" });
    defer st.deinit();
    try std.testing.expectEqualStrings("rc 1 Await\n", st.out);
    const fd = try run(e, &.{ "--rc", "cat /proc/$pid/fd" });
    defer fd.deinit();
    try std.testing.expect(std.mem.startsWith(u8, fd.out, "/mnt/term/cwd\n"));
    const ns = try run(e, &.{ "--rc", "cat /proc/$pid/ns" });
    defer ns.deinit();
    try std.testing.expect(std.mem.indexOf(u8, ns.out, "bind ") != null);
    const ls = try run(e, &.{ "--rc", "ls /proc | wc -l" });
    defer ls.deinit();
    try std.testing.expect(try std.fmt.parseInt(usize, std.mem.trim(u8, ls.out, " \n"), 10) >= 2);
}

test "seg attaches a shared segment and reads zero [4]" {
    const e = try env(@src());
    const r = try run(e, &.{ "seg", "-r", "shared", "0x1000", "0" });
    defer r.deinit();
    try std.testing.expectEqualStrings("0x0\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "seg attaches a memory segment and writes a word [4]" {
    const e = try env(@src());
    const r = try run(e, &.{ "seg", "-L", "-w", "memory", "0x1000", "8", "0x12345678" });
    defer r.deinit();
    try std.testing.expectEqualStrings("", r.err);
    try std.testing.expectEqual(0, r.code);
}

test "an unknown class is a bad arg [4]" {
    const e = try env(@src());
    const r = try run(e, &.{ "seg", "-r", "tmu", "0x1000", "0" });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.err, "segattach: bad arg in system call") != null);
    try std.testing.expectEqual(1, r.code);
}

test "--memory caps segattach [4]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--memory", "8m", "seg", "-r", "memory", "0x2000000", "0" });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.err, "virtual memory allocation failed") != null);
    try std.testing.expectEqual(1, r.code);
}

// rendezvous and semaphores (design/0003-semaphores.md). The programs are
// tests/fixtures/sema/sema.c, one per argument, built inside the guest
// with 7c and 7l into a scratch directory given with --sandbox.

/// Builds sema.c into `s` as `sema`, on each backend.
fn buildSema(e: Env, s: *Scratch) !void {
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sema.c", .data = @embedFile("fixtures/sema/sema.c") });
    const r = try run(e, &.{ "--sandbox", s.path, "--rc", "7c sema.c && 7l -o sema sema.7" });
    defer r.deinit();
    errdefer std.debug.print("7c and 7l: {s}{s}", .{ r.out, r.err });
    try std.testing.expectEqual(0, r.code);
}

/// Runs `./sema test` in `s`, with h9 flags `flags` first.
fn runSema(e: Env, s: *Scratch, flags: []const []const u8, cmd: []const u8) !Result {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "--sandbox", s.path, "--timeout", "60s" });
    try argv.appendSlice(gpa, flags);
    try argv.appendSlice(gpa, &.{ "--rc", cmd });
    return run(e, argv.items);
}

/// Builds sema.c and runs `./sema test`, expecting `want` and status 0.
fn expectSema(e: Env, flags: []const []const u8, cmd: []const u8, want: []const u8) !void {
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try buildSema(e, &s);
    const r = try runSema(e, &s, flags, cmd);
    defer r.deinit();
    errdefer std.debug.print("{s}: {s}", .{ cmd, r.err });
    try std.testing.expectEqualStrings(want, r.out);
    try std.testing.expectEqual(0, r.code);
}

test "rendezvous swaps values between two processes [3]" {
    const e = try env(@src());
    try expectSema(e, &.{}, "./sema swap", "child got 11\nparent got 22\n");
}

test "contended qlock parks and wakes through rendezvous [3]" {
    const e = try env(@src());
    try expectSema(e, &.{}, "./sema qlock", "2000\n");
}

test "semacquire waits for semrelease across RFMEM processes [3]" {
    const e = try env(@src());
    try expectSema(e, &.{}, "./sema wait", "semacquire 1 waited\n");
}

test "semaphores keep a shared counter exact under contention [3]" {
    const e = try env(@src());
    try expectSema(e, &.{}, "./sema count", "2000 1\n");
    try expectSema(e, &.{ "--cpus", "1" }, "./sema count", "2000 1\n");
}

test "semacquire without block and tsemacquire with 0 ms don't wait [3]" {
    const e = try env(@src());
    try expectSema(e, &.{}, "./sema nowait", "0 0 1 1 0 at once\n");
}

test "tsemacquire times out, or returns early on semrelease [3]" {
    const e = try env(@src());
    try expectSema(e, &.{}, "./sema timeout", "timeout 0 in time\nrelease 1 early\n");
}

test "a note interrupts rendezvous and semacquire, and the handler runs [3]" {
    const e = try env(@src());
    try expectSema(e, &.{}, "./sema interrupt", "rendezvous ~0, handled 1\nsemacquire -1 'interrupted', handled 2\n");
}

test "bad semaphore addresses and values fail as on 9front [3]" {
    const e = try env(@src());
    try expectSema(e, &.{}, "./sema badaddr",
        \\odd -1 'bad arg in system call'
        \\text -1 'bad arg in system call'
        \\negative -1 'bad arg in system call'
        \\negative -1 'bad arg in system call'
        \\negative -1 'bad arg in system call'
        \\count -1 'bad arg in system call'
        \\unmapped -1 'bad arg in system call'
        \\notes sys: odd address;sys: bad address in syscall;
        \\
    );
}

test "ps shows processes blocked in Rendezvous and Semacquire [3]" {
    const e = try env(@src());
    // ps cuts the state to 8 characters. The parent waits for both.
    try expectSema(e, &.{},
        \\./sema block & sleep 1; ps | awk '$7 == "sema" { print $6 }' | sort; kill sema | rc; wait
    , "Await\nRendezvo\nSemacqui\n");
}

test "--timeout stops processes blocked in rendezvous and semacquire [3]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try buildSema(e, &s);
    const io = std.testing.io;
    const t0 = std.Io.Timestamp.now(io, .awake);
    const r = try runSema(e, &s, &.{ "--timeout", "500ms" }, "./sema block");
    defer r.deinit();
    const took = t0.untilNow(io, .awake).toMilliseconds();
    errdefer std.debug.print("took {d} ms: {s}", .{ took, r.err });
    try std.testing.expectEqual(1, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "h9: timeout") != null);
    // Hangup or the teardown 2 s later; one run per backend.
    try std.testing.expect(took < 10_000 * @as(i64, @intCast(std.mem.count(u8, e.backends, ",") + 1)));
}

// The network policy (design/0005-net-policy.md). The cases listen on
// 127.0.0.1 themselves, and the guest writes /net ctl files from rc, so
// they need no client program the root tree doesn't have.

/// A TCP listener on an ephemeral port of 127.0.0.1.
fn listenLocal() !std.Io.net.Server {
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    return addr.listen(std.testing.io, .{ .reuse_address = true });
}

/// An rc command that dials `addr` (`a.b.c.d!port`) through
/// /net/tcp/clone and writes `line` to the connection.
fn rcDial(buf: []u8, addr: []const u8, line: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "<>[3] /net/tcp/clone {{ n=`{{read <[0=3]}}; echo 'connect {s}' >[1=3] && echo {s} >/net/tcp/$n/data }}", .{ addr, line });
}

/// Accepts the next queued connection and reads from it to EOF, at most
/// `buf.len` bytes, so the peer must have closed it.
fn acceptLine(srv: *std.Io.net.Server, buf: []u8) ![]const u8 {
    const io = std.testing.io;
    const s = try srv.accept(io);
    defer s.close(io);
    var rbuf: [256]u8 = undefined;
    var r = s.reader(io, &rbuf);
    const n = r.interface.readSliceShort(buf) catch 0;
    return std.mem.trimEnd(u8, buf[0..n], "\n");
}

/// Checks that nothing reached `srv` before this call: the first
/// connection accepted is one the test makes itself.
fn expectNoConnection(srv: *std.Io.net.Server) !void {
    const io = std.testing.io;
    {
        const c = try srv.socket.address.connect(io, .{ .mode = .stream });
        // Closed before the accept, which reads to EOF.
        defer c.close(io);
        var wbuf: [64]u8 = undefined;
        var w = c.writer(io, &wbuf);
        try w.interface.writeAll("marker\n");
        try w.interface.flush();
    }
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("marker", try acceptLine(srv, &buf));
}

test "the default profile refuses announce [5]" {
    const e = try env(@src());
    const r = try run(e, &.{ "aux/listen1", "-t", "tcp!127.0.0.1!39517", "/bin/cat" });
    defer r.deinit();
    // libc's announce adds where the write failed: "announce writing
    // /net/tcp/clone: permission denied".
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expect(std.mem.indexOf(u8, r.err, "announce tcp!127.0.0.1!39517: ") != null);
    try std.testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, r.err, "\n"), "permission denied"));
    try std.testing.expect(r.code != 0);
}

test "--net=enable allows a server [5]" {
    const e = try env(@src());
    const io = std.testing.io;
    var probe = try listenLocal();
    const port = probe.socket.address.getPort();
    probe.deinit(io);
    var addr_buf: [64]u8 = undefined;
    const addr = try std.fmt.bufPrint(&addr_buf, "tcp!127.0.0.1!{d}", .{port});
    var it = std.mem.tokenizeScalar(u8, e.backends, ',');
    while (it.next()) |backend| {
        var child = try std.process.spawn(io, .{
            .argv = &.{ e.h9, "--backend", backend, "--root", e.root, "--net=enable", "--timeout", "20s", "aux/listen1", "-1", "-t", addr, "/bin/cat" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .create_no_window = true,
        });
        defer child.kill(io);
        const ip = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        var tries: u32 = 0;
        const c = while (true) : (tries += 1) {
            break ip.connect(io, .{ .mode = .stream }) catch |err| {
                if (tries >= slow(100)) return err;
                try io.sleep(.fromMilliseconds(100), .awake);
                continue;
            };
        };
        defer c.close(io);
        var wbuf: [64]u8 = undefined;
        var w = c.writer(io, &wbuf);
        try w.interface.writeAll("ping\n");
        try w.interface.flush();
        var rbuf: [64]u8 = undefined;
        var r = c.reader(io, &rbuf);
        var got: [64]u8 = undefined;
        const n = try r.interface.readSliceShort(got[0..5]);
        try std.testing.expectEqualStrings("ping\n", got[0..n]);
    }
}

test "outbound allows connect [5]" {
    const e = try env(@src());
    var srv = try listenLocal();
    defer srv.deinit(std.testing.io);
    var addr_buf: [64]u8 = undefined;
    var cmd_buf: [256]u8 = undefined;
    const addr = try std.fmt.bufPrint(&addr_buf, "127.0.0.1!{d}", .{srv.socket.address.getPort()});
    var it = std.mem.tokenizeScalar(u8, e.backends, ',');
    while (it.next()) |backend| {
        const r = try runOn(e, backend, &.{ "--rc", try rcDial(&cmd_buf, addr, "hello") }, null);
        defer r.deinit();
        try std.testing.expectEqualStrings("", r.err);
        try std.testing.expectEqual(0, r.code);
        var buf: [64]u8 = undefined;
        try std.testing.expectEqualStrings("hello", try acceptLine(&srv, &buf));
    }
}

test "outbound refuses link-local without patterns [5]" {
    const e = try env(@src());
    var cmd_buf: [256]u8 = undefined;
    const cmd = try rcDial(&cmd_buf, "169.254.169.254!80", "x");
    for ([_][]const u8{ "--net=outbound", "--net=enable" }) |mode| {
        const r = try run(e, &.{ mode, "--rc", cmd });
        defer r.deinit();
        try std.testing.expect(std.mem.indexOf(u8, r.err, "write error: permission denied") != null);
        try std.testing.expect(r.code != 0);
    }
}

test "a pattern allows link-local [5]" {
    const e = try env(@src());
    var cmd_buf: [256]u8 = undefined;
    // Nothing listens there, so the connect fails, but not by the policy.
    const r = try run(e, &.{ "--net-allow", "tcp!169.254.0.0/16!*", "--timeout", "20s", "--rc", try rcDial(&cmd_buf, "169.254.169.254!80", "x") });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.err, "permission denied") == null);
}

test "--net-allow refuses a connect outside it, and the host sees nothing [5]" {
    const e = try env(@src());
    var srv = try listenLocal();
    defer srv.deinit(std.testing.io);
    var addr_buf: [64]u8 = undefined;
    var cmd_buf: [256]u8 = undefined;
    const addr = try std.fmt.bufPrint(&addr_buf, "127.0.0.1!{d}", .{srv.socket.address.getPort()});
    const r = try run(e, &.{ "--net-allow", "tcp!10.0.0.0/8!*", "--rc", try rcDial(&cmd_buf, addr, "leak") });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.err, "write error: permission denied") != null);
    try expectNoConnection(&srv);
}

test "--net-allow allows a matching CIDR and port [5]" {
    const e = try env(@src());
    var srv = try listenLocal();
    defer srv.deinit(std.testing.io);
    const port = srv.socket.address.getPort();
    var addr_buf: [64]u8 = undefined;
    var pat_buf: [64]u8 = undefined;
    var cmd_buf: [256]u8 = undefined;
    const addr = try std.fmt.bufPrint(&addr_buf, "127.0.0.1!{d}", .{port});
    const pat = try std.fmt.bufPrint(&pat_buf, "tcp!127.0.0.0/8!{d}-{d}", .{ port, port });
    var it = std.mem.tokenizeScalar(u8, e.backends, ',');
    while (it.next()) |backend| {
        const r = try runOn(e, backend, &.{ "--net-allow", pat, "--rc", try rcDial(&cmd_buf, addr, "cidr") }, null);
        defer r.deinit();
        try std.testing.expectEqualStrings("", r.err);
        var buf: [64]u8 = undefined;
        try std.testing.expectEqualStrings("cidr", try acceptLine(&srv, &buf));
    }
}

test "a name pattern allows a connect through cs [5]" {
    const e = try env(@src());
    var srv = try listenLocal();
    defer srv.deinit(std.testing.io);
    const port = srv.socket.address.getPort();
    var pat_buf: [64]u8 = undefined;
    var addr_buf: [64]u8 = undefined;
    var dial_buf: [256]u8 = undefined;
    var cmd_buf: [384]u8 = undefined;
    const pat = try std.fmt.bufPrint(&pat_buf, "tcp!localhost!{d}", .{port});
    const addr = try std.fmt.bufPrint(&addr_buf, "127.0.0.1!{d}", .{port});
    // Without the lookup, the address isn't in the resolved-name table.
    const refused = try run(e, &.{ "--net-allow", pat, "--rc", try rcDial(&dial_buf, addr, "early") });
    defer refused.deinit();
    try std.testing.expect(std.mem.indexOf(u8, refused.err, "write error: permission denied") != null);
    const cmd = try std.fmt.bufPrint(&cmd_buf, "ndb/csquery /net/cs '{s}' >/dev/null && {s}", .{ pat, try rcDial(&dial_buf, addr, "named") });
    var it = std.mem.tokenizeScalar(u8, e.backends, ',');
    while (it.next()) |backend| {
        const r = try runOn(e, backend, &.{ "--net-allow", pat, "--rc", cmd }, null);
        defer r.deinit();
        try std.testing.expectEqualStrings("", r.err);
        var buf: [64]u8 = undefined;
        try std.testing.expectEqualStrings("named", try acceptLine(&srv, &buf));
    }
}

test "a name outside --net-allow isn't resolved [5]" {
    const e = try env(@src());
    // localhost resolves on every host, so the refusal comes before the
    // host's resolver.
    const r = try run(e, &.{ "--net-allow", "tcp!127.0.0.1!80", "ndb/csquery", "/net/cs", "tcp!localhost!80" });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.err, "translating tcp!localhost!80: no translation for host found") != null);
}

test "a UDP announce is refused under outbound [5]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--rc", "<>[3] /net/udp/clone { echo 'announce 127.0.0.1!39517' >[1=3] }" });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.err, "write error: permission denied") != null);
    try std.testing.expect(r.code != 0);
}

test "--net-allow with --net=disable is a usage error [5]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--net=disable", "--net-allow", "tcp!*!*", "echo" });
    defer r.deinit();
    try std.testing.expectEqual(2, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "--net-allow conflicts with --net=disable") != null);
    const bad = try run(e, &.{ "--net-allow", "tcp!10.0.0.0/33!*", "echo" });
    defer bad.deinit();
    try std.testing.expectEqual(2, bad.code);
    try std.testing.expect(std.mem.indexOf(u8, bad.err, "tcp!10.0.0.0/33!*") != null);
}

test "--print shows net-allow patterns and caveats [5]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--print", "--net-allow", "tcp!*.example.com!443", "--net-allow", "udp!10.0.0.53!53", "echo" });
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "net.allow net.outbound") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "net=outbound") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "net-allow:\n  tcp!*.example.com!443\n  udp!10.0.0.53!53\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "name patterns trust the host's resolver") != null);
    const d = try run(e, &.{ "--print", "echo" });
    defer d.deinit();
    try std.testing.expect(std.mem.indexOf(u8, d.out, "except link-local") != null);
}

test "--strict accepts --net=outbound [5]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--strict", "--net=outbound", "echo", "ok" });
    defer r.deinit();
    try std.testing.expectEqualStrings("ok\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

// devsrv, /srv and mount (design/0008-devsrv.md). Mount points are made
// in the machine's private /tmp, since the root tree's /n and /mnt are
// mostly mntgen's on 9front and may lack the names a case wants.

test "ramfs posts to /srv and another process mounts it [8]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--timeout", "20s", "--rc", "ramfs -S r && mkdir /tmp/r && mount -c /srv/r /tmp/r && echo hi >/tmp/r/x && cat /tmp/r/x" });
    defer r.deinit();
    try std.testing.expectEqualStrings("hi\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "ramfs -S tmp, mount and ls (demo) [8]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--timeout", "20s", "--rc", "ramfs -S tmp && mkdir /tmp/n && mount -c /srv/tmp /tmp/n && touch /tmp/n/a && ls /tmp/n" });
    defer r.deinit();
    try std.testing.expectEqualStrings("/tmp/n/a\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "a posted pipe is a named pipe [8]" {
    const e = try env(@src());
    // srv(3)'s example in rc: the right side posts its fd 0, the read end
    // of the pipe, and exits; the data waits in the pipe until it's read
    // through /srv.
    const r = try run(e, &.{ "--timeout", "20s", "--rc", "echo hello | { echo 0 >/srv/namedpipe }; cat /srv/namedpipe" });
    defer r.deinit();
    try std.testing.expectEqualStrings("hello\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "mount without auth works through fauth [8]" {
    const e = try env(@src());
    // Not mount -n: amount calls fauth, the server answers that it needs
    // no authentication, and mount goes on without an auth fd. (-c only
    // allows the create.)
    const r = try run(e, &.{ "--trace", "--timeout", "20s", "--rc", "ramfs -S r && mkdir /tmp/r && mount -c /srv/r /tmp/r && echo ok >/tmp/r/f && cat /tmp/r/f" });
    defer r.deinit();
    try std.testing.expectEqualStrings("ok\n", r.out);
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, " fauth ") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "authentication not required") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, " mount ") != null);
}

test "unmount takes a mount out of the namespace [8]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--timeout", "20s", "--rc", "ramfs -S r && mkdir /tmp/r && mount -c /srv/r /tmp/r && touch /tmp/r/x && ls /tmp/r && unmount /tmp/r && ls /tmp/r && echo done" });
    defer r.deinit();
    try std.testing.expectEqualStrings("/tmp/r/x\ndone\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "srvfs reexports a directory through /srv [8]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--timeout", "20s", "--rc", "mkdir /tmp/d /tmp/m && echo exported >/tmp/d/f && srvfs sfs /tmp/d && mount -c /srv/sfs /tmp/m && cat /tmp/m/f" });
    defer r.deinit();
    try std.testing.expectEqualStrings("exported\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "exportfs -S serves a posted channel [8]" {
    const e = try env(@src());
    // exportfs reads and writes 9P on fds 0 and 1, one end of a pipe; the
    // other end is posted as /srv/e, and exportfs passes it to /srv/r.
    // Each attach mounts /srv/r on /mnt/exportfs/<n>, mntexport's on
    // 9front, so /mnt/exportfs/0 is made in /tmp if the root lacks it.
    const script =
        \\mkdir -p /tmp/m/exportfs/0 && bind -a /tmp/m /mnt && bind -a /tmp/m/exportfs /mnt/exportfs || exit mtpt
        \\ramfs -S r && mkdir /tmp/a /tmp/b && mount -c /srv/r /tmp/a && echo through >/tmp/a/x || exit setup
        \\exportfs -S /srv/r <[0=1] | { echo 0 >/srv/e } &
        \\n=0
        \\while(! test -e /srv/e && test $n -lt 100){ sleep 0.1; n=`{echo $n+1 | hoc} }
        \\mount -c /srv/e /tmp/b && cat /tmp/b/x
    ;
    const r = try run(e, &.{ "--timeout", "20s", "--rc", script });
    defer r.deinit();
    try std.testing.expectEqualStrings("through\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "/proc/n/ns prints a mount of /srv/x as /srv/x [8]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--timeout", "20s", "--rc", "ramfs -S x && mkdir /tmp/x && mount -c /srv/x /tmp/x && grep /tmp/x /proc/$pid/ns" });
    defer r.deinit();
    try std.testing.expectEqualStrings("mount -c /srv/x /tmp/x\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "a server's /srv entry goes when it exits [8]" {
    const e = try env(@src());
    // ramfs posts /srv/r with ORCLOSE, and its server process holds that
    // fd; killing the server closes it, which removes the entry.
    const script =
        \\ramfs -S r && test -e /srv/r && echo posted || exit setup
        \\for(p in `{awk 'FNR==1 && $1=="ramfs" {split(FILENAME, a, "/"); print a[3]}' /proc/*/status >[2]/dev/null}) echo kill >/proc/$p/ctl
        \\n=0
        \\while(test -e /srv/r && test $n -lt 100){ sleep 0.1; n=`{echo $n+1 | hoc} }
        \\test -e /srv/r || echo gone
    ;
    const r = try run(e, &.{ "--timeout", "20s", "--rc", script });
    defer r.deinit();
    // (ls /srv would list clone too, as on 9front.)
    try std.testing.expectEqualStrings("posted\ngone\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "a second create of a /srv name fails [8]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--timeout", "20s", "--rc", "ramfs -S r && ! ramfs -S r && echo refused" });
    defer r.deinit();
    try std.testing.expectEqualStrings("refused\n", r.out);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "exists") != null);
    try std.testing.expectEqual(0, r.code);
}

test "clone makes a private board, and closing it clears it [8]" {
    const e = try env(@src());
    // The board lives while fd 3, its lease, is open; a pipe end posted on
    // it is reachable as /srv/<board>/p, and goes with the board.
    const script =
        \\<[3]/srv/clone {
        \\    b=`{cat /fd/3}
        \\    echo hello | { echo 0 >/srv/$b/p }
        \\    cat /srv/$b/p
        \\    echo $b >/tmp/board
        \\}
        \\b=`{cat /tmp/board}
        \\test -e /srv/$b || echo cleared
    ;
    const r = try run(e, &.{ "--timeout", "20s", "--rc", script });
    defer r.deinit();
    try std.testing.expectEqualStrings("hello\ncleared\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "factotum starts and serves /mnt/factotum [8]" {
    const e = try env(@src());
    // -n skips secstore. The mount point comes from /tmp if the root
    // tree's /mnt lacks it, as without 9front's mntgen.
    const r = try run(e, &.{ "--timeout", "20s", "--rc", "mkdir -p /tmp/m/factotum && bind -a /tmp/m /mnt && auth/factotum -n >[2]/dev/null && ls /mnt/factotum" });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.out, "/mnt/factotum/ctl\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "/mnt/factotum/rpc\n") != null);
    try std.testing.expectEqual(0, r.code);
}

test "plumber starts and serves /mnt/plumb [8]" {
    const e = try env(@src());
    const script =
        \\mkdir -p /tmp/m/plumb /tmp/m/temp && bind -a /tmp/m /mnt || exit setup
        \\echo 'editor = acme' >/tmp/rules
        \\home=/tmp plumber -p /tmp/rules
        \\ls /mnt/plumb
    ;
    const r = try run(e, &.{ "--timeout", "20s", "--rc", script });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.out, "/mnt/plumb/rules\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "/mnt/plumb/send\n") != null);
    try std.testing.expectEqual(0, r.code);
}

// Go compatibility (design/0007-go-compat.md). The Go cases run the
// plan9/amd64 programs from tests/fixtures/go, which `zig build
// go-fixtures` builds into H9_TEST_GO, on the emulator. They don't need
// the root tree: each gets a scratch root holding only the directories
// the namespace binds onto, and the fixtures at /mnt/term/cwd. Without Go
// or the emulator, H9_TEST_GO is unset and they skip.

const GoEnv = struct {
    h9: []const u8,
    dir: []const u8,
    root: Scratch,

    fn deinit(g: *GoEnv) void {
        g.root.deinit();
    }
};

/// The mount points the namespace binds onto, as 9front's root has them.
const go_root_dirs = [_][]const u8{ "bin", "dev", "env", "fd", "mnt/term/cwd", "net", "net.alt", "proc", "root", "srv", "tmp" };

fn goEnv(comptime src: std.builtin.SourceLocation, g: *GoEnv) !void {
    try skipPending(src.fn_name);
    const h9 = getenv(0, "H9_TEST_BIN") orelse return error.SkipZigTest;
    const dir = getenv(1, "H9_TEST_GO") orelse return error.SkipZigTest;
    std.Io.Dir.cwd().access(std.testing.io, try hostPath(dir, "hello"), .{}) catch return error.SkipZigTest;
    g.h9 = h9;
    g.dir = dir;
    try g.root.init();
    for (go_root_dirs) |d| try g.root.tmp.dir.createDirPath(std.testing.io, d);
}

/// The argv for running fixture `prog` with h9 flags `flags` and arguments `args`.
fn goArgv(g: *const GoEnv, argv: *std.ArrayList([]const u8), flags: []const []const u8, prog: []const u8, args: []const []const u8) !void {
    try argv.appendSlice(gpa, &.{ g.h9, "--backend", "emu", "--arch", "amd64", "--root", g.root.path, "--cwd", g.dir, "--timeout", "60s" });
    try argv.appendSlice(gpa, flags);
    try argv.append(gpa, try std.fmt.allocPrint(gpa, "/mnt/term/cwd/{s}", .{prog}));
    try argv.appendSlice(gpa, args);
}

fn runGo(g: *const GoEnv, flags: []const []const u8, prog: []const u8, args: []const []const u8) !Result {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try goArgv(g, &argv, flags, prog, args);
    defer gpa.free(argv.items[argv.items.len - args.len - 1]);
    const r = try runProcess(argv.items, null);
    const code = switch (r.term) {
        .exited => |c| c,
        else => {
            std.debug.print("h9 {s}: {any}\n{s}", .{ prog, r.term, r.stderr });
            gpa.free(r.stdout);
            gpa.free(r.stderr);
            return error.Crashed;
        },
    };
    return .{ .code = code, .out = r.stdout, .err = r.stderr };
}

/// The integer at the start of line `i` of `out`.
fn lineInt(comptime T: type, out: []const u8, i: usize) !T {
    var lines = std.mem.splitScalar(u8, out, '\n');
    var n: usize = 0;
    while (lines.next()) |line| : (n += 1) if (n == i) {
        var toks = std.mem.tokenizeScalar(u8, line, ' ');
        return std.fmt.parseInt(T, toks.next() orelse return error.NoNumber, 10);
    };
    return error.NoNumber;
}

fn expectGoOk(r: Result) !void {
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqual(0, r.code);
}

test "a Go hello world prints and exits 0 [7]" {
    var g: GoEnv = undefined;
    try goEnv(@src(), &g);
    defer g.deinit();
    const r = try runGo(&g, &.{}, "hello", &.{});
    defer r.deinit();
    try std.testing.expectEqualStrings("hello from go\n", r.out);
    try std.testing.expectEqualStrings("", r.err);
    try expectGoOk(r);
}

test "goroutines sleep 100 ms and the elapsed time is right [7]" {
    var g: GoEnv = undefined;
    try goEnv(@src(), &g);
    defer g.deinit();
    const r = try runGo(&g, &.{}, "sleep", &.{});
    defer r.deinit();
    try expectGoOk(r);
    const ms = try lineInt(u32, r.out, 0);
    errdefer std.debug.print("elapsed {d} ms\n", .{ms});
    try std.testing.expect(ms >= 100 and ms < slow(200));
}

test "time.Now has sub-second resolution and matches the host [7]" {
    var g: GoEnv = undefined;
    try goEnv(@src(), &g);
    defer g.deinit();
    const before = std.Io.Timestamp.now(std.testing.io, .real).nanoseconds;
    const r = try runGo(&g, &.{}, "clock", &.{});
    defer r.deinit();
    const after = std.Io.Timestamp.now(std.testing.io, .real).nanoseconds;
    try expectGoOk(r);
    errdefer std.debug.print("stdout: {s}\n", .{r.out});
    const now = try lineInt(i96, r.out, 0);
    // The guest's reading is between the host's, give or take a second.
    try std.testing.expect(now > before - std.time.ns_per_s and now < after + std.time.ns_per_s);
    try std.testing.expect(try lineInt(i64, r.out, 1) >= 10 * std.time.ns_per_ms);
}

test "runtime.NumCPU follows --cpus [7]" {
    var g: GoEnv = undefined;
    try goEnv(@src(), &g);
    defer g.deinit();
    const r = try runGo(&g, &.{ "--cpus", "2" }, "numcpu", &.{});
    defer r.deinit();
    try expectGoOk(r);
    try std.testing.expectEqualStrings("2 2\n", r.out);
}

test "os.Getpid and os.Getppid match /proc [7]" {
    var g: GoEnv = undefined;
    try goEnv(@src(), &g);
    defer g.deinit();
    const r = try runGo(&g, &.{}, "pid", &.{});
    defer r.deinit();
    try expectGoOk(r);
    // Line 1 is Getpid and Getppid; line 2 is the name in
    // /proc/<Getpid>/status, which is this program's only if the pid is
    // right, and /proc/<Getpid>/ppid.
    var lines = std.mem.splitScalar(u8, r.out, '\n');
    var ids = std.mem.tokenizeScalar(u8, lines.next().?, ' ');
    _ = ids.next().?;
    const ppid = ids.next().?;
    var proc = std.mem.tokenizeScalar(u8, lines.next().?, ' ');
    try std.testing.expectEqualStrings("pid", proc.next().?);
    try std.testing.expectEqualStrings(ppid, proc.next().?);
}

test "CPU-bound goroutines run on several processes [7]" {
    var g: GoEnv = undefined;
    try goEnv(@src(), &g);
    defer g.deinit();
    {
        const r = try runGo(&g, &.{ "--cpus", "4", "--env", "GOMAXPROCS=4" }, "spin", &.{});
        defer r.deinit();
        try expectGoOk(r);
        errdefer std.debug.print("processes: {s}\n", .{r.out});
        try std.testing.expect(try lineInt(u32, r.out, 0) >= 4);
    }
    const r = try runGo(&g, &.{ "--cpus", "1", "--env", "GOMAXPROCS=4" }, "spin", &.{});
    defer r.deinit();
    try expectGoOk(r);
}

test "os/exec runs a child and gets its exit status [7]" {
    var g: GoEnv = undefined;
    try goEnv(@src(), &g);
    defer g.deinit();
    // rfork copies the parent's memory, and Go reserves several hundred
    // MB of brk at start, so two of them need more than the default 1 GB.
    const r = try runGo(&g, &.{ "--memory", "4G" }, "exec", &.{"/mnt/term/cwd/exec"});
    defer r.deinit();
    try expectGoOk(r);
    errdefer std.debug.print("stdout: {s}\n", .{r.out});
    try std.testing.expect(std.mem.startsWith(u8, r.out, "child ok\nstatus 1 'exec "));
    try std.testing.expect(std.mem.endsWith(u8, r.out, ": 7'\n"));
}

test "a nil dereference becomes a panic that recover catches [7]" {
    var g: GoEnv = undefined;
    try goEnv(@src(), &g);
    defer g.deinit();
    const r = try runGo(&g, &.{}, "nilpanic", &.{});
    defer r.deinit();
    try expectGoOk(r);
    try std.testing.expectEqualStrings("recovered: runtime error: invalid memory address or nil pointer dereference\n", r.out);
}

test "os/signal receives interrupt on Ctrl-C [7]" {
    var g: GoEnv = undefined;
    try goEnv(@src(), &g);
    defer g.deinit();
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try goArgv(&g, &argv, &.{}, "signal", &.{});
    defer gpa.free(argv.items[argv.items.len - 1]);
    var t = try Term.spawn(gpa, argv.items);
    defer t.deinit();
    try t.expect("ready", slow(10_000));
    try t.send("\x03");
    try t.expect("got interrupt", slow(10_000));
    try std.testing.expectEqual(0, try t.wait(slow(10_000)));
}

test "os.Exit(3) exits with status 3 [7]" {
    var g: GoEnv = undefined;
    try goEnv(@src(), &g);
    defer g.deinit();
    const r = try runGo(&g, &.{}, "exit", &.{"3"});
    defer r.deinit();
    try std.testing.expectEqualStrings("exiting 3\n", r.out);
    try std.testing.expectEqualStrings("", r.err);
    try std.testing.expectEqual(3, r.code);
}

test "a numeric exits string becomes the exit code [7]" {
    const e = try env(@src());
    {
        const r = try run(e, &.{ "--rc", "exit 3" });
        defer r.deinit();
        try std.testing.expectEqualStrings("", r.err);
        try std.testing.expectEqual(3, r.code);
    }
    {
        // rc counts "0" as a true status and exits with "" for it, so this
        // is 0 before the CLI sees it. cli.zig's tests cover exits("0").
        const r = try run(e, &.{ "--rc", "exit 0" });
        defer r.deinit();
        try std.testing.expectEqualStrings("", r.err);
        try std.testing.expectEqual(0, r.code);
    }
    for ([_][]const u8{ "256", "03" }) |s| {
        var buf: [16]u8 = undefined;
        const r = try run(e, &.{ "--rc", try std.fmt.bufPrint(&buf, "exit {s}", .{s}) });
        defer r.deinit();
        errdefer std.debug.print("exit {s}: stderr {s}\n", .{ s, r.err });
        try std.testing.expectEqual(1, r.code);
        try std.testing.expect(std.mem.indexOf(u8, r.err, s) != null);
    }
}

test "net/http fetches from a listener the test opens [7]" {
    var g: GoEnv = undefined;
    try goEnv(@src(), &g);
    defer g.deinit();
    const io = std.testing.io;
    var srv = try listenLocal();
    defer srv.deinit(io);
    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/x", .{srv.socket.address.getPort()});
    const Server = struct {
        fn serve(s: *std.Io.net.Server) void {
            const c = s.accept(io) catch return;
            defer c.close(io);
            var rbuf: [1024]u8 = undefined;
            var r = c.reader(io, &rbuf);
            // The request ends with an empty line.
            while (r.interface.takeDelimiterExclusive('\n')) |line| {
                r.interface.toss(1);
                if (std.mem.trimEnd(u8, line, "\r").len == 0) break;
            } else |_| return;
            var wbuf: [256]u8 = undefined;
            var w = c.writer(io, &wbuf);
            w.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 13\r\nConnection: close\r\n\r\nhi from host\n") catch return;
            w.interface.flush() catch {};
        }
    };
    const t = try std.Thread.spawn(.{}, Server.serve, .{&srv});
    defer t.join();
    const r = try runGo(&g, &.{}, "http", &.{url});
    defer r.deinit();
    try expectGoOk(r);
    try std.testing.expectEqualStrings("200\nhi from host\n", r.out);
}

test "syscall.Gettimeofday has microsecond resolution [7]" {
    var g: GoEnv = undefined;
    try goEnv(@src(), &g);
    defer g.deinit();
    const r = try runGo(&g, &.{}, "gettimeofday", &.{});
    defer r.deinit();
    try expectGoOk(r);
    errdefer std.debug.print("stdout: {s}\n", .{r.out});
    // Five readings 1 ms apart: whole seconds would give one distinct value.
    try std.testing.expect(try lineInt(u32, r.out, 0) >= 4);
}

test "/dev/bintime has four words and a monotonic clock [7]" {
    const e = try env(@src());
    // The clock differs from run to run, so each backend is checked on its
    // own rather than compared with the others.
    var it = backendList(e);
    while (it.next()) |backend| {
        errdefer std.debug.print("backend {s}\n", .{backend});
        try checkBintime(e, backend);
    }
}

fn checkBintime(e: Env, backend: []const u8) !void {
    const r = try runOn(e, backend, &.{ "--rc", "dd -if /dev/bintime -bs 32 -count 1 >[2]/dev/null | xd -1x; sleep 1; dd -if /dev/bintime -bs 32 -count 1 >[2]/dev/null | xd -1x" }, null);
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqual(0, r.code);
    // xd prints an offset and up to 16 bytes a line, then the final
    // offset alone: two reads of 32 bytes each.
    var bytes: [64]u8 = undefined;
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, r.out, '\n');
    while (lines.next()) |line| {
        var toks = std.mem.tokenizeAny(u8, line, " \t");
        _ = toks.next() orelse continue; // the offset
        while (toks.next()) |tok| {
            if (n == bytes.len) return error.TooManyBytes;
            bytes[n] = try std.fmt.parseInt(u8, tok, 16);
            n += 1;
        }
    }
    try std.testing.expectEqual(64, n);
    const word = struct {
        fn at(b: []const u8, i: usize) u64 {
            return std.mem.readInt(u64, b[i * 8 ..][0..8], .big);
        }
    }.at;
    const a = bytes[0..32];
    const b = bytes[32..64];
    try std.testing.expectEqual(1_000_000_000, word(a, 2));
    // The monotonic clock moved by at least the second slept.
    try std.testing.expect(word(b, 3) - word(a, 3) >= std.time.ns_per_s);
    try std.testing.expect(word(b, 0) > word(a, 0));
}

// 9P roots (design/0013-9p-roots.md). The server is a second h9 serving
// the test root tree read-only with exportfs behind aux/listen1 -t, so no
// host 9P server is needed. Cases compare a run over the 9P root with the
// same run over the host tree, whose namespace is otherwise the same.

/// A second h9 serving the root tree on a loopback port, on the first
/// backend, for the life of a case.
const RootServer = struct {
    child: std.process.Child,
    port: u16,
    dial_buf: [64]u8 = undefined,

    fn start(s: *RootServer, e: Env) !void {
        const io = std.testing.io;
        var probe = try listenLocal();
        s.port = probe.socket.address.getPort();
        probe.deinit(io);
        var listen_buf: [64]u8 = undefined;
        const listen = try std.fmt.bufPrint(&listen_buf, "tcp!127.0.0.1!{d}", .{s.port});
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ e.h9, "--backend", firstBackend(e), "--root", e.root, "--net=enable" });
        if (e.arch) |a| try argv.appendSlice(gpa, &.{ "--arch", a });
        try argv.appendSlice(gpa, &.{ "aux/listen1", "-t", listen, "/bin/exportfs", "-R", "-r", "/" });
        s.child = try std.process.spawn(io, .{ .argv = argv.items, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore, .create_no_window = true });
        errdefer s.child.kill(io);
        // Ready when it accepts; listen1 runs an exportfs for the probe,
        // which ends at EOF.
        const ip = try std.Io.net.IpAddress.parse("127.0.0.1", s.port);
        var tries: u32 = 0;
        while (true) : (tries += 1) {
            const c = ip.connect(io, .{ .mode = .stream }) catch |err| {
                if (tries >= slow(100)) return err;
                try io.sleep(.fromMilliseconds(100), .awake);
                continue;
            };
            c.close(io);
            break;
        }
    }

    fn dial(s: *RootServer) []const u8 {
        return std.fmt.bufPrint(&s.dial_buf, "tcp!127.0.0.1!{d}", .{s.port}) catch unreachable;
    }

    fn stop(s: *RootServer) void {
        s.child.kill(std.testing.io);
    }
};

/// Runs `args` over the 9P root `root` and over the host tree, and checks
/// that both succeed with the same output.
fn expectSameAsHost(e: Env, root: []const u8, args: []const []const u8) !void {
    const host = try run(e, args);
    defer host.deinit();
    var with_root: std.ArrayList([]const u8) = .empty;
    defer with_root.deinit(gpa);
    try with_root.appendSlice(gpa, &.{ "--root", root });
    try with_root.appendSlice(gpa, args);
    const r = try run(e, with_root.items);
    defer r.deinit();
    errdefer std.debug.print("over {s}: stdout: {s}\nstderr: {s}\n", .{ root, r.out, r.err });
    try std.testing.expectEqual(0, host.code);
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings(host.out, r.out);
}

/// A 9P server on a loopback port that answers Tversion, records the
/// first Tattach's uname and aname, and refuses it with `refusal`.
const FakeAttach = struct {
    srv: std.Io.net.Server,
    refusal: []const u8,
    thread: std.Thread = undefined,
    uname: [64]u8 = undefined,
    uname_len: usize = 0,
    aname: [64]u8 = undefined,
    aname_len: usize = 0,
    attached: bool = false,
    dial_buf: [64]u8 = undefined,

    fn start(f: *FakeAttach, refusal: []const u8) !void {
        f.* = .{ .srv = try listenLocal(), .refusal = refusal };
        f.thread = try std.Thread.spawn(.{}, serve, .{f});
    }

    fn dial(f: *FakeAttach) []const u8 {
        return std.fmt.bufPrint(&f.dial_buf, "tcp!127.0.0.1!{d}", .{f.srv.socket.address.getPort()}) catch unreachable;
    }

    /// Waits for the server's one connection to end.
    fn finish(f: *FakeAttach) void {
        f.thread.join();
        f.srv.deinit(std.testing.io);
    }

    fn uname_(f: *const FakeAttach) []const u8 {
        return f.uname[0..f.uname_len];
    }

    fn aname_(f: *const FakeAttach) []const u8 {
        return f.aname[0..f.aname_len];
    }

    fn serve(f: *FakeAttach) void {
        const io = std.testing.io;
        const s = f.srv.accept(io) catch return;
        defer s.close(io);
        var rbuf: [8192]u8 = undefined;
        var wbuf: [256]u8 = undefined;
        var r = s.reader(io, &rbuf);
        var w = s.writer(io, &wbuf);
        while (true) {
            const size = r.interface.takeInt(u32, .little) catch return;
            if (size < 7 or size > rbuf.len) return;
            const m = r.interface.take(size - 4) catch return;
            const typ = m[0];
            const tag = m[1..3];
            switch (typ) {
                100 => { // Tversion: msize[4] version[s]
                    const msize = std.mem.readInt(u32, m[3..7], .little);
                    reply(&w.interface, 101, tag, &.{ std.mem.asBytes(&std.mem.nativeToLittle(u32, @min(msize, 8192))), "\x06\x009P2000" }) catch return;
                },
                104 => { // Tattach: fid[4] afid[4] uname[s] aname[s]
                    var o: usize = 11;
                    const un = str(m, &o) orelse return;
                    const an = str(m, &o) orelse return;
                    f.uname_len = @min(un.len, f.uname.len);
                    @memcpy(f.uname[0..f.uname_len], un[0..f.uname_len]);
                    f.aname_len = @min(an.len, f.aname.len);
                    @memcpy(f.aname[0..f.aname_len], an[0..f.aname_len]);
                    f.attached = true;
                    const len = std.mem.nativeToLittle(u16, @intCast(f.refusal.len));
                    reply(&w.interface, 107, tag, &.{ std.mem.asBytes(&len), f.refusal }) catch return;
                    return;
                },
                else => return,
            }
        }
    }

    fn str(m: []const u8, o: *usize) ?[]const u8 {
        if (o.* + 2 > m.len) return null;
        const n = std.mem.readInt(u16, m[o.*..][0..2], .little);
        if (o.* + 2 + n > m.len) return null;
        defer o.* += 2 + n;
        return m[o.* + 2 ..][0..n];
    }

    fn reply(w: *std.Io.Writer, typ: u8, tag: []const u8, parts: []const []const u8) !void {
        var size: u32 = 7;
        for (parts) |p| size += @intCast(p.len);
        try w.writeInt(u32, size, .little);
        try w.writeByte(typ);
        try w.writeAll(tag);
        for (parts) |p| try w.writeAll(p);
        try w.flush();
    }
};

test "a TCP 9P root runs /bin/ls [13]" {
    const e = try env(@src());
    var srv: RootServer = undefined;
    try srv.start(e);
    defer srv.stop();
    try expectSameAsHost(e, srv.dial(), &.{ "/bin/ls", "/", "/bin/ls" });
    // A name: localhost is ::1 before 127.0.0.1 on macOS, and the server
    // is only on 127.0.0.1, so every address cs returns is tried.
    var buf: [64]u8 = undefined;
    try expectSameAsHost(e, try std.fmt.bufPrint(&buf, "tcp!localhost!{d}", .{srv.port}), &.{ "/bin/ls", "/" });
}

/// Relays connections to a unix socket at `path` to the TCP port `port`.
const UnixRelay = struct {
    srv: std.Io.net.Server,
    port: u16,
    thread: std.Thread = undefined,

    fn start(u: *UnixRelay, path: []const u8, port: u16) !void {
        const ua = try std.Io.net.UnixAddress.init(path);
        u.* = .{ .srv = try ua.listen(std.testing.io, .{}), .port = port };
        u.thread = try std.Thread.spawn(.{}, accept, .{u});
        u.thread.detach();
    }

    fn accept(u: *UnixRelay) void {
        const io = std.testing.io;
        while (true) {
            const c = u.srv.accept(io) catch return;
            const ip = std.Io.net.IpAddress.parse("127.0.0.1", u.port) catch unreachable;
            const s = ip.connect(io, .{ .mode = .stream }) catch {
                c.close(io);
                continue;
            };
            const t = std.Thread.spawn(.{}, copy, .{ s, c }) catch return;
            t.detach();
            const t2 = std.Thread.spawn(.{}, copy, .{ c, s }) catch return;
            t2.detach();
        }
    }

    /// Copies `from` to `to` until EOF, then shuts both down.
    fn copy(from: std.Io.net.Stream, to: std.Io.net.Stream) void {
        const io = std.testing.io;
        var rbuf: [8192]u8 = undefined;
        var r = from.reader(io, &rbuf);
        var w = to.writer(io, &.{});
        while (true) {
            const data = r.interface.peekGreedy(1) catch break;
            w.interface.writeAll(data) catch break;
            r.interface.toss(data.len);
        }
        to.shutdown(io, .both) catch {};
        from.shutdown(io, .both) catch {};
    }
};

test "a unix socket 9P root runs /bin/ls [13]" {
    if (!std.Io.net.has_unix_sockets or builtin.os.tag == .windows) return error.SkipZigTest;
    const e = try env(@src());
    var srv: RootServer = undefined;
    try srv.start(e);
    defer srv.stop();
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const sock = try std.fs.path.join(gpa, &.{ s.path, "fs.sock" });
    defer gpa.free(sock);
    var relay: UnixRelay = undefined;
    try relay.start(sock, srv.port);
    // Both spellings: unix!path, and the socket's path.
    const dial = try std.fmt.allocPrint(gpa, "unix!{s}", .{sock});
    defer gpa.free(dial);
    try expectSameAsHost(e, dial, &.{ "/bin/ls", "/", "/bin/ls" });
    try expectSameAsHost(e, sock, &.{ "/bin/ls", "/" });
}

test "rc pipelines and exec run from a 9P root [13]" {
    const e = try env(@src());
    var srv: RootServer = undefined;
    try srv.start(e);
    defer srv.stop();
    try expectSameAsHost(e, srv.dial(), &.{ "--rc", "ls /bin | grep -c '/cat$'; echo a b c | wc -w; exec /bin/echo done" });
}

test "the host cwd is bound over a 9P root [13]" {
    const e = try env(@src());
    var srv: RootServer = undefined;
    try srv.start(e);
    defer srv.stop();
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f", .data = "from the host\n" });
    const r = try run(e, &.{ "--root", srv.dial(), "--cwd", s.path, "--rc", "cat f; pwd; echo new > g" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("from the host\n/mnt/term/cwd\n", r.out);
    try std.testing.expect(s.exists("g"));
}

test "a 9P root works under --net=disable [13]" {
    const e = try env(@src());
    var srv: RootServer = undefined;
    try srv.start(e);
    defer srv.stop();
    try expectSameAsHost(e, srv.dial(), &.{ "--net=disable", "/bin/ls", "/bin/cat" });
    // #I is still masked from the guest.
    const r = try run(e, &.{ "--root", srv.dial(), "--net=disable", "--rc", "ls '#I'" });
    defer r.deinit();
    try std.testing.expect(r.code != 0);
}

test "--root-spec is sent as the attach name [13]" {
    const e = try env(@src());
    var f: FakeAttach = undefined;
    try f.start("no such tree");
    // One backend: the server takes one connection.
    const r = runOn(e, firstBackend(e), &.{ "--root", f.dial(), "--root-spec", "other", "/bin/echo" }, null) catch |err| {
        f.finish();
        return err;
    };
    defer r.deinit();
    f.finish();
    try std.testing.expect(f.attached);
    try std.testing.expectEqualStrings("other", f.aname_());
    try std.testing.expectEqual(125, r.code);
}

test "--root-user is sent as the attach uname [13]" {
    const e = try env(@src());
    for ([_]?[]const u8{ "glenda", null }) |user| {
        var f: FakeAttach = undefined;
        try f.start("no");
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(gpa);
        try args.appendSlice(gpa, &.{ "--root", f.dial() });
        if (user) |u| try args.appendSlice(gpa, &.{ "--root-user", u });
        try args.append(gpa, "/bin/echo");
        // One backend: the server takes one connection.
        const r = runOn(e, firstBackend(e), args.items, null) catch |err| {
            f.finish();
            return err;
        };
        defer r.deinit();
        f.finish();
        try std.testing.expect(f.attached);
        if (user) |u| {
            try std.testing.expectEqualStrings(u, f.uname_());
        } else {
            // The machine's user, the host user's name.
            try std.testing.expect(f.uname_().len > 0);
            try std.testing.expect(!std.mem.eql(u8, f.uname_(), "glenda"));
        }
    }
}

test "the guest mounts /srv/root at a second path [13]" {
    const e = try env(@src());
    var srv: RootServer = undefined;
    try srv.start(e);
    defer srv.stop();
    const r = try run(e, &.{ "--root", srv.dial(), "--rc", "ls /srv/root && mkdir /tmp/r && mount /srv/root /tmp/r && ls /tmp/r/rc/bin/lc" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("/srv/root\n/tmp/r/rc/bin/lc\n", r.out);
}

test "an unreachable 9P root exits 125 [13]" {
    const e = try env(@src());
    var probe = try listenLocal();
    const port = probe.socket.address.getPort();
    probe.deinit(std.testing.io);
    var buf: [64]u8 = undefined;
    const dial = try std.fmt.bufPrint(&buf, "tcp!127.0.0.1!{d}", .{port});
    const r = try run(e, &.{ "--root", dial, "/bin/echo" });
    defer r.deinit();
    try std.testing.expectEqual(125, r.code);
    var want: [96]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, r.err, try std.fmt.bufPrint(&want, "root {s}: ", .{dial})) != null);
}

test "a 9P root that wants authentication exits 125 [13]" {
    const e = try env(@src());
    var f: FakeAttach = undefined;
    try f.start("authentication required");
    const r = runOn(e, firstBackend(e), &.{ "--root", f.dial(), "/bin/echo" }, null) catch |err| {
        f.finish();
        return err;
    };
    defer r.deinit();
    f.finish();
    try std.testing.expectEqual(125, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, ": authentication required") != null);
}

test "--write=none with a 9P root is a usage error [13]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--root", "tcp!127.0.0.1!1", "--write=none", "/bin/echo" });
    defer r.deinit();
    try std.testing.expectEqual(2, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "--write=none can't be enforced on a 9P root") != null);
}

test "a unix socket root on Windows exits 125 [13]" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const e = try env(@src());
    const r = try run(e, &.{ "--root", "unix!C:/fs.sock", "/bin/echo" });
    defer r.deinit();
    try std.testing.expectEqual(125, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "unix socket roots need a POSIX host") != null);
}

test "--print shows a 9P root, and its output replays with --ns [13]" {
    const e = try env(@src());
    var srv: RootServer = undefined;
    try srv.start(e);
    defer srv.stop();
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const p = try run(e, &.{ "--root", srv.dial(), "--cwd", s.path, "--print", "ls" });
    defer p.deinit();
    try std.testing.expectEqual(0, p.code);
    var want: [96]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, p.out, "  mount '#s/root' / ''") != null);
    try std.testing.expect(std.mem.indexOf(u8, p.out, try std.fmt.bufPrint(&want, "9p  # {s}\n", .{srv.dial()})) != null);
    try std.testing.expect(std.mem.indexOf(u8, p.out, "writes to the 9P root go to its server") != null);
    // The namespace section, replayed after the plan's own.
    const start = (std.mem.indexOf(u8, p.out, "namespace:\n") orelse return error.NoNamespace) + "namespace:\n".len;
    const end = std.mem.indexOfPos(u8, p.out, start, "\naccess:") orelse std.mem.indexOfPos(u8, p.out, start, "\ncaveats:") orelse return error.NoNamespace;
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ns", .data = p.out[start .. end + 1] });
    try expectSameAsHost(e, srv.dial(), &.{ "--cwd", s.path, "--ns", "ns", "/bin/ls", "/", "/bin/ls" });
}

test "--check runs /bin/echo from a 9P root [13]" {
    const e = try env(@src());
    var srv: RootServer = undefined;
    try srv.start(e);
    defer srv.stop();
    const r = try run(e, &.{ "--root", srv.dial(), "--check" });
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\n", .{r.out});
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "ok, /bin/echo runs") != null);
}

// h9's own commands in #H (design/0032-guest-tools.md). Debug builds serve
// tests/fixtures/guest in #H too: `h9-guest-test` and an `echo` that the
// root's must beat. The build sets H9_TEST_GUEST_TOOLS when it served them.

/// Skips a case that needs the test-only scripts when h9 was built without
/// them (-Dguest-test=false, the default for release builds).
fn needGuestTest() !void {
    if (getenv(3, "H9_TEST_GUEST_TOOLS") == null) return error.SkipZigTest;
}

test "#H/bin is bound after /bin and its scripts run [32]" {
    const e = try env(@src());
    try needGuestTest();
    const r = try run(e, &.{ "--rc", "h9-guest-test a b" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("h9 guest tools a b\n", r.out);
    // The guest's own view of its namespace: #H/bin comes after /rc/bin.
    const ns = try run(e, &.{ "--rc", "cat /proc/$pid/ns" });
    defer ns.deinit();
    errdefer std.debug.print("ns: {s}\n", .{ns.out});
    const rc_at = std.mem.indexOf(u8, ns.out, "rc/bin") orelse return error.NoRcBin;
    const h_at = std.mem.indexOf(u8, ns.out, "#H/bin") orelse return error.NoHBin;
    try std.testing.expect(h_at > rc_at);
}

test "a root command of the same name wins over #H's [32]" {
    const e = try env(@src());
    try needGuestTest();
    const r = try run(e, &.{ "--rc", "echo hi; grep -s 'echo from' '#H/bin/echo' && echo shadowed" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("hi\nshadowed\n", r.out);
}

test "#H refuses writes [32]" {
    const e = try env(@src());
    try needGuestTest();
    // rc gives up on a whole -c script when a redirection fails, so the
    // writes run in subshells. chmod exits 0 after a failed wstat, so its
    // error is what shows the refusal.
    const r = try run(e, &.{
        "--rc",
        \\f='#H/bin/h9-guest-test'
        \\@{echo x >$f} || echo write
        \\@{echo x >>$f} || echo append
        \\touch '#H/bin/new' || echo create
        \\rm $f || echo remove
        \\chmod 777 $f >[2=1] | grep -s 'permission denied' && echo wstat
        \\sed 1q $f
    });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("write\nappend\ncreate\nremove\nwstat\n#!/bin/rc\n", r.out);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "permission denied") != null);
}

test "--no-guest-tools leaves out the bind and masks #H [32]" {
    const e = try env(@src());
    const p = try run(e, &.{ "--no-guest-tools", "--print", "ls" });
    defer p.deinit();
    try std.testing.expect(std.mem.indexOf(u8, p.out, "#H/bin") == null);
    try std.testing.expect(std.mem.indexOf(u8, p.out, "devmask:  #C #H #U\n") != null);
    const r = try run(e, &.{ "--no-guest-tools", "ls", "#H" });
    defer r.deinit();
    try std.testing.expectEqual(1, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "mount/attach disallowed") != null);
    if (getenv(3, "H9_TEST_GUEST_TOOLS") != null) {
        const t = try run(e, &.{ "--no-guest-tools", "--rc", "h9-guest-test" });
        defer t.deinit();
        try std.testing.expect(t.code != 0);
        try std.testing.expectEqualStrings("", t.out);
    }
}

test "--print shows the #H bind [32]" {
    const e = try env(@src());
    for ([_][]const u8{ "--profile=default", "--profile=tight" }) |prof| {
        const p = try run(e, &.{ prof, "--print", "ls" });
        defer p.deinit();
        errdefer std.debug.print("{s}\n", .{p.out});
        try std.testing.expectEqual(0, p.code);
        const rc_at = std.mem.indexOf(u8, p.out, "  bind -a '/rc/bin' /bin\n") orelse return error.NoRcBin;
        const h_at = std.mem.indexOf(u8, p.out, "  bind -a '#H/bin' /bin  # h9's commands\n") orelse return error.NoHBin;
        try std.testing.expect(h_at > rc_at);
    }
}
