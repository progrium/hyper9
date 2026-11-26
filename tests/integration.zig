//! Runs real 9front binaries from the root tree through the h9 CLI and
//! checks their output and exit status. Each case is a separate h9 process,
//! so it covers the CLI, root resolution and exit codes end to end.
//!
//! The build passes the root tree (-Droot, default .local/9front/root) and
//! the engines to test (H9_TEST_ENGINES, the ones built in) through the
//! environment, and the h9 binary and fixtures as build options, which the
//! environment overrides (getenv). Every case runs on each engine
//! that can run arm64 here. Without a root tree, the tests are skipped.
//! `zig build install-tests` builds this file for another target, and
//! `scripts/lima/vm test` runs it in a test VM with the same variables.
//!
//! Each case is tagged with the proposal it proves, by slug, at the
//! end of its name: `test "ls /bin | wc -l (demo) [baseline]"`. A case
//! whose proposal isn't implemented skips unless H9_TEST_PENDING is set;
//! the build passes those proposals' tags in (`design.pending_tags`, from
//! design/), so a case stops skipping in the commit that marks its
//! proposal implemented. `zig build proposal -Dp=<slug>` runs one
//! proposal's cases, and `zig build design -- check` checks the tags.
//!
//! Interactive cases run h9 on a terminal from tests/term.zig. Their
//! timeouts, and the --timeout of cases that depend on how fast the guest
//! runs, are multiplied by H9_TEST_SLOW (default 1), for emulated VMs.

const std = @import("std");
const builtin = @import("builtin");
const Term = @import("term.zig").Term;
const wsrelay = @import("wsrelay.zig");
const deadline = @import("deadline.zig");
const dnsstub = @import("dnsstub.zig");
const design = @import("design");
const test_paths = @import("test_paths");
const DotlServer = @import("dotlserver.zig").DotlServer;

const gpa = std.testing.allocator;

const Env = struct {
    h9: []const u8,
    root: []const u8,
    engines: []const u8,
    /// H9_TEST_ARCH (-Darch), passed to h9 as --arch; null for the host's.
    arch: ?[]const u8,
};

var env_buf: [7][std.Io.Dir.max_path_bytes]u8 = undefined;

/// An environment variable, on every host (getPosix doesn't build on
/// Windows). Values live in one of seven slots, chosen by the caller.
fn getenv(comptime slot: usize, key: []const u8) ?[]const u8 {
    var map = std.testing.environ.createMap(gpa) catch return null;
    defer map.deinit();
    if (map.get(key)) |v| {
        if (v.len > env_buf[slot].len) return null;
        @memcpy(env_buf[slot][0..v.len], v);
        return env_buf[slot][0..v.len];
    }
    // The cases run h9 in other directories, so the build's paths are made
    // absolute.
    const p = buildPath(key) orelse return null;
    if (std.fs.path.isAbsolute(p)) return p;
    const buf = &env_buf[slot];
    const n = std.process.currentPath(std.testing.io, buf) catch return null;
    if (n + 1 + p.len > buf.len) return null;
    buf[n] = std.fs.path.sep;
    @memcpy(buf[n + 1 ..][0..p.len], p);
    return buf[0 .. n + 1 + p.len];
}

/// The path zig build gives for `key` (H9_TEST_BIN, H9_TEST_LINUX,
/// H9_TEST_GO, or H9_TEST_SERVER) when the environment doesn't set it:
/// build options, since the install prefix isn't known until the build
/// runs. A relative one is relative to where zig build ran, which is this
/// process's directory.
fn buildPath(key: []const u8) ?[]const u8 {
    inline for (comptime std.meta.declarations(test_paths)) |name| {
        if (std.mem.eql(u8, key, name)) return @field(test_paths, name);
    }
    return null;
}

/// The case's environment. `src` is the case's @src(), whose tags decide
/// whether it's pending.
fn env(comptime src: std.builtin.SourceLocation) !Env {
    try skipPending(src.fn_name);
    try skipWeb(src.fn_name);
    const h9 = getenv(0, "H9_TEST_BIN") orelse return error.SkipZigTest;
    const root = getenv(1, "H9_TEST_ROOT") orelse return error.SkipZigTest;
    // The tree from zig build mkroot is arm64, plus the host's architecture
    // or the ones its --arch names. Without H9_TEST_ARCH, h9 runs the host's architecture,
    // so x86_64 hosts (linux-amd64) skip these.
    const arch = getenv(4, "H9_TEST_ARCH");
    if (arch == null and builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    var cat_buf: [32]u8 = undefined;
    const cat = try std.fmt.bufPrint(&cat_buf, "{s}/bin/cat", .{arch orelse "arm64"});
    std.Io.Dir.cwd().access(std.testing.io, try hostPath(root, cat), .{}) catch return error.SkipZigTest;
    const engines = getenv(2, "H9_TEST_ENGINES") orelse "auto";
    return .{ .h9 = h9, .root = root, .engines = engines, .arch = arch };
}

/// Cases the web host can't run (design/epoch-0/browser-host.md), skipped
/// when H9_TEST_WEB is set (-Dweb): by name, those that need a host TTY,
/// POSIX signals, or what a page's WebSocket can't do; by tag, the
/// network's, 9P roots', and serving's proposals, since the web host has
/// only WebSockets and can't listen.
const web_skips = [_][]const u8{
    "the discarded-changes notice is printed on a terminal and not otherwise",
    "--timeout stops a console read on a terminal at once",
    "Ctrl-C interrupts the foreground command and rc carries on",
    "a second Ctrl-C within a second tears the machine down",
    "rawon puts the host terminal in raw mode until exit",
    "closing the terminal posts hangup",
    "SIGTERM posts hangup",
    // A 9P root over TCP.
    "a write to a 9P root under the default profile doesn't reach the server",
    // A page's WebSocket can't set headers or a CA, use a proxy, or ping;
    // the browser does those (design/epoch-0/websocket-9p.md).
    "header= is sent, and header=@FILE reads headers from a file",
    "header in ctl is sent with the handshake",
    "wsmount mounts a ws:// URL with flags and headers",
    "--print elides a ws:// root's query and header values",
    "ca= with a ws:// root is a usage error",
    "a ws:// root goes through HTTP_PROXY with CONNECT, and NO_PROXY skips it",
    "a proxy answering 407 exits 125 with the status",
    "an idle ws:// root pings, and a server that stops answering fails it",
    // self-host's debugger cases that write to text or read acid's frames:
    // the web host hasn't the private text pages and breakpoint trap they need yet.
    "/proc/n/mem reads a variable and a write to text doesn't reach a sibling",
    "/proc/n/mem writes to text are fetched by the next run, including a rewrite of the same address",
    "a BRK posts sys: breakpoint",
    "acid attaches and prints registers and a stack trace",
    // Browsers and Node fail a handshake that offered subprotocols and got none.
    "a ws:// root works with a server that selects no subprotocol",
    // credential-helpers: the web host has no header=, and a page's
    // WebSocket shows no response headers, so no 9P-Uid or 9P-User.
    "header= wins over a helper's header of the same name",
    "9P-Uid and 9P-User name files without --user-map",
    "--user-map wins over 9P-Uid",
};
const web_skip_tags = [_][]const u8{ "5", "13", "22", "35" };

/// Whether the cases run on the web host (-Dweb).
fn onWeb() bool {
    return getenv(3, "H9_TEST_WEB") != null;
}

fn skipWeb(name: []const u8) !void {
    if (!onWeb()) return;
    const test_name = if (std.mem.indexOf(u8, name, "test.")) |i| name[i + 5 ..] else name;
    for (web_skips) |n| if (std.mem.startsWith(u8, test_name, n)) return error.SkipZigTest;
    if (name.len == 0 or name[name.len - 1] != ']') return;
    const open = std.mem.lastIndexOfScalar(u8, name, '[') orelse return;
    var tags = std.mem.splitScalar(u8, name[open + 1 .. name.len - 1], ',');
    while (tags.next()) |raw| for (web_skip_tags) |t| {
        if (std.mem.eql(u8, std.mem.trim(u8, raw, " "), t)) return error.SkipZigTest;
    };
}

/// Skips a case outside this run's shard. H9_TEST_SHARD is `I/N`, from
/// zig build integration's -Dshards: the build runs the binary N times at
/// once, and run I takes the cases whose names hash to I, so the N runs
/// cover each case once between them. Unset, every case runs. Tests that
/// don't come through here, such as tests/deadline.zig's, run in every
/// shard.
fn skipShard(name: []const u8) !void {
    const v = getenv(3, "H9_TEST_SHARD") orelse return;
    const slash = std.mem.indexOfScalar(u8, v, '/') orelse return;
    const i = std.fmt.parseInt(u64, v[0..slash], 10) catch return;
    const n = std.fmt.parseInt(u64, v[slash + 1 ..], 10) catch return;
    if (n < 2) return;
    if (std.hash.Wyhash.hash(0, name) % n != i) return error.SkipZigTest;
}

/// Skips a case tagged with a proposal that isn't implemented, unless
/// H9_TEST_PENDING is set, and a case outside this run's shard
/// (skipShard). Every case calls it first, directly or through env.
/// `name` is the test's name as @src() gives it.
fn skipPending(name: []const u8) !void {
    try skipShard(name);
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

/// Runs `h9 --dir <root> args...` on each engine and returns the first
/// result, after checking that every engine gave the same one.
fn run(e: Env, args: []const []const u8) !Result {
    return runIn(e, args, null);
}

/// Like `run`, with `stdin` (if not null) on the guest's console.
fn runIn(e: Env, args: []const []const u8, stdin: ?[]const u8) !Result {
    return runInFor(e, args, stdin, 30_000);
}

/// Like `runIn`, with a harness timeout of `ms` instead of 30 s.
fn runInFor(e: Env, args: []const []const u8, stdin: ?[]const u8, ms: u32) !Result {
    var first: ?Result = null;
    errdefer if (first) |f| f.deinit();
    var it = std.mem.tokenizeScalar(u8, e.engines, ',');
    while (it.next()) |engine| {
        const r = try runOnFor(e, engine, args, stdin, ms);
        if (first) |f| {
            defer r.deinit();
            errdefer std.debug.print("engine {s} differs from {s} for h9 {s}\n", .{ engine, firstEngine(e), args[0] });
            // --print's plan names the engine it was run on
            // (design/plan-format.md).
            try std.testing.expectEqualStrings(try withoutEngine(f.out), try withoutEngine(r.out));
            try std.testing.expectEqual(f.code, r.code);
        } else first = r;
    }
    return first orelse error.SkipZigTest;
}

/// `out` without a plan's `engine` line, which is the one line of
/// `--print` that differs from engine to engine; in the test allocator's
/// arena of leaks, as the results are.
fn withoutEngine(out: []const u8) ![]const u8 {
    var b: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, out, '\n');
    var first = true;
    while (it.next()) |l| {
        if (std.mem.startsWith(u8, l, "engine ")) continue;
        if (!first) try b.append(std.heap.page_allocator, '\n');
        first = false;
        try b.appendSlice(std.heap.page_allocator, l);
    }
    return b.items;
}

fn firstEngine(e: Env) []const u8 {
    var it = std.mem.tokenizeScalar(u8, e.engines, ',');
    return it.next() orelse "auto";
}

fn runOn(e: Env, engine: []const u8, args: []const []const u8, stdin: ?[]const u8) !Result {
    return runOnFor(e, engine, args, stdin, 30_000);
}

fn runOnFor(e: Env, engine: []const u8, args: []const []const u8, stdin: ?[]const u8, ms: u32) !Result {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ e.h9, "--engine", engine });
    if (!givesRoot(args)) try argv.appendSlice(gpa, &.{ "--dir", e.root });
    if (e.arch) |a| try argv.appendSlice(gpa, &.{ "--arch", a });
    try argv.appendSlice(gpa, args);
    const r = try runProcessWith(argv.items, stdin, null, ms);
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
    return runProcessWith(argv, stdin, null, 30_000);
}

/// runProcess, with the environment `environ` (if not null) and a
/// timeout of `ms`, scaled by H9_TEST_SLOW.
fn runProcessWith(argv: []const []const u8, stdin: ?[]const u8, environ: ?*const std.process.Environ.Map, ms: u32) !std.process.RunResult {
    const io = std.testing.io;
    const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(slow(ms)), .clock = .awake } };
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = if (stdin != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .environ_map = environ,
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
    var it = std.mem.tokenizeScalar(u8, e.engines, ',');
    while (it.next()) |engine| {
        errdefer std.debug.print("engine {s}\n", .{engine});
        const r = try runOn(e, engine, &.{"--check"}, null);
        defer r.deinit();
        try std.testing.expectEqual(0, r.code);
        try std.testing.expect(std.mem.indexOf(u8, r.out, "/bin/echo runs") != null);
    }
    const missing = try runProcess(&.{ e.h9, "--dir", "/nonexistent-h9-root", "--check" }, null);
    defer gpa.free(missing.stdout);
    defer gpa.free(missing.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 125 }, missing.term);
    try std.testing.expect(std.mem.indexOf(u8, missing.stdout, "not found") != null);

    const v = try runProcess(&.{ e.h9, "--version" }, null);
    defer gpa.free(v.stdout);
    defer gpa.free(v.stderr);
    try std.testing.expect(std.mem.startsWith(u8, v.stdout, "h9 "));
    try std.testing.expect(std.mem.indexOf(u8, v.stdout, "\nengines: ") != null);
    const h = try runProcess(&.{ e.h9, "-h" }, null);
    defer gpa.free(h.stdout);
    defer gpa.free(h.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, h.term);
    try std.testing.expect(std.mem.startsWith(u8, h.stdout, "usage: h9"));
}

test "a root that isn't there gives 125 for a guest program [mounts]" {
    const e = try env(@src());
    const io = std.testing.io;
    var environ = try std.testing.environ.createMap(gpa);
    defer environ.deinit();
    _ = environ.swapRemove("H9ROOT");
    for ([_][]const []const u8{ &.{ e.h9, "--dir", "/nonexistent-h9-root", "echo", "x" }, &.{ e.h9, "--dir", "/nonexistent-h9-root", "--rc", "echo x" } }) |argv| {
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

test "a host #! script runs by its guest path [host-scripts]" {
    const e = try env(@src());
    const io = std.testing.io;
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.writeFile(io, .{ .sub_path = "greet", .data = "#!/bin/rc\necho $0 $*\n" });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "nointerp", .data = "#!/no/such/rc\n" });
    try s.tmp.dir.createDirPath(io, "sub/in");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "sub/in/greet", .data = "#!/bin/rc\necho $0 $*\n" });
    var other: Scratch = undefined;
    try other.init();
    defer other.deinit();
    try other.tmp.dir.writeFile(io, .{ .sub_path = "away", .data = "#!/bin/rc\necho $0 $*\n" });
    // Scratch paths are resolved, as h9 resolves the cwd, and siblings.
    const cwd = s.path;
    const other_real = other.path;

    // In the cwd, and below it: $0 is the guest path, as exec gives it.
    const r = try runBare(e, cwd, &.{ "--dir", e.root, "./greet", "hello", "world" }, &.{});
    defer r.deinit();
    try std.testing.expectEqualStrings("", r.err);
    try std.testing.expectEqualStrings("/mnt/term/cwd/greet hello world\n", r.out);
    try std.testing.expectEqual(0, r.code);
    const sub = try runBare(e, cwd, &.{ "--dir", e.root, "./sub/in/greet" }, &.{});
    defer sub.deinit();
    try std.testing.expectEqualStrings("/mnt/term/cwd/sub/in/greet\n", sub.out);
    try std.testing.expectEqual(0, sub.code);
    // Outside every bound path: an error naming the fix, before the
    // machine starts.
    var away_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const away = try std.fmt.bufPrint(&away_buf, "../{s}/away", .{std.fs.path.basename(other_real)});
    const out = try runBare(e, cwd, &.{ "--dir", e.root, away }, &.{});
    defer out.deinit();
    try std.testing.expectEqual(126, out.code);
    try std.testing.expect(std.mem.indexOf(u8, out.err, "--readable") != null);
    // With the directory shared, it runs from /mnt/term at its host path.
    var want_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const want = try std.fmt.bufPrint(&want_buf, "/mnt/term{s}/away\n", .{other_real});
    const shared = try runBare(e, cwd, &.{ "--dir", e.root, "--readable", other_real, away }, &.{});
    defer shared.deinit();
    try std.testing.expectEqualStrings(want, shared.out);
    try std.testing.expectEqual(0, shared.code);
    // --read-deny hides it like any other file.
    var deny_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const deny = try std.fmt.bufPrint(&deny_buf, "{s}/greet", .{cwd});
    const denied = try runBare(e, cwd, &.{ "--dir", e.root, "--read-deny", deny, "./greet" }, &.{});
    defer denied.deinit();
    try std.testing.expectEqual(126, denied.code);

    // The interpreter is resolved in the guest.
    const ni = try runBare(e, cwd, &.{ "--dir", e.root, "./nointerp" }, &.{});
    defer ni.deinit();
    try std.testing.expectEqual(127, ni.code);
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

/// The namespace `--print` compiled, which its plan shows as comments
/// (design/plan-format.md), as namespace lines `--ns` replays.
fn printedNamespace(out: []const u8) ![]const u8 {
    const start = (std.mem.indexOf(u8, out, "\n# namespace:\n") orelse return error.NoNamespace) + "\n# namespace:\n".len;
    var b: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, out[start..], '\n');
    while (it.next()) |l| {
        if (!std.mem.startsWith(u8, l, "#   ")) break;
        try b.appendSlice(std.heap.page_allocator, l["#".len..]);
        try b.append(std.heap.page_allocator, '\n');
    }
    return b.items;
}

/// A scratch host directory, resolved, for cwd and policy tests.
const Scratch = struct {
    tmp: std.testing.TmpDir,
    path: []const u8,
    buf: [std.Io.Dir.max_path_bytes]u8 = undefined,
    ns_buf: [std.Io.Dir.max_path_bytes + 8]u8 = undefined,

    /// `@<scratch>/ns`: --ns's value for the namespace file `ns` the case
    /// wrote, read on the host (design/epoch-0/mounts.md).
    fn ns(s: *Scratch) []const u8 {
        return std.fmt.bufPrint(&s.ns_buf, "@{s}/ns", .{s.path}) catch unreachable;
    }

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

test "default profile: the cwd is writable and the root tree isn't written [baseline]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const r = try run(e, &.{ "--cwd", s.path, "touch", "f" });
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(s.exists("f"));
    // The write succeeds in the root's overlay (design/epoch-0/overlay.md);
    // --write=scope makes it fail.
    const ro = try run(e, &.{ "--cwd", s.path, "touch", "/lib/h9-test" });
    defer ro.deinit();
    try std.testing.expectEqual(0, ro.code);
    const sc = try run(e, &.{ "--cwd", s.path, "--write=scope", "touch", "/lib/h9-test" });
    defer sc.deinit();
    try std.testing.expectEqual(1, sc.code);
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
    try symLinkOrSkip(s.tmp.dir, std.testing.io, try std.fmt.bufPrint(&lp, "{s}/secret", .{other.path}), "link", .{});
    const l = try run(e, &.{ "--cwd", s.path, "cat", "link" });
    defer l.deinit();
    try std.testing.expectEqual(1, l.code);
    try std.testing.expectEqualStrings("", l.out);
}

test "devfs checks the file it opened, not the path it was given [baseline]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.orig", .data = "one\n" });

    // Reading (OREAD), overwriting with truncation (OWRITE|OTRUNC, through
    // the deferred ftruncate), and listing the directory (the fdopendir
    // path) all go through the refactored fsopen and still work on an
    // in-policy file. Each engine starts from its own copy of f, as the
    // one before it overwrote it.
    const r = try run(e, &.{ "--cwd", s.path, "--rc", "cp f.orig f && cat f && echo two >f && cat f && ls ." });
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "one\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "two\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "f") != null);

    // Writing through a symlink whose target is outside every bound tree is
    // denied by the opened fd's own path, and leaves the target untouched:
    // the open resolves the link but the check sees where it landed, and the
    // truncation waits until after the check, so a denied file keeps its
    // contents.
    var other: Scratch = undefined;
    try other.init();
    defer other.deinit();
    try other.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "secret", .data = "secret\n" });
    var lp: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try symLinkOrSkip(s.tmp.dir, std.testing.io, try std.fmt.bufPrint(&lp, "{s}/secret", .{other.path}), "link", .{});
    const w = try run(e, &.{ "--cwd", s.path, "--rc", "echo pwned >link" });
    defer w.deinit();
    try std.testing.expectEqual(1, w.code);
    const data = try other.tmp.dir.readFileAlloc(std.testing.io, "secret", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqualStrings("secret\n", data);
}

test "a link through a directory, a .. in a link, or a chain of links can't reach outside the bound trees [baseline]" {
    // devfs follows host links for a 9front program, so the check must
    // resolve every element of the path, not only the last: each of these
    // names a file outside every bound tree through a link earlier in it.
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var other: Scratch = undefined;
    try other.init();
    defer other.deinit();
    const io = std.testing.io;
    try other.tmp.dir.createDirPath(io, "d");
    try other.tmp.dir.writeFile(io, .{ .sub_path = "d/secret", .data = "secret\n" });
    try s.tmp.dir.createDirPath(io, "sub");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "sub/f", .data = "inside\n" });
    var lp: [std.Io.Dir.max_path_bytes]u8 = undefined;
    // dl: an absolute link to the outside directory. up: a relative one
    // that climbs out of the cwd with .., to the same place. c1: a chain
    // of links ending in dl. in: a link that stays inside, which works.
    try symLinkOrSkip(s.tmp.dir, io, try std.fmt.bufPrint(&lp, "{s}/d", .{other.path}), "dl", .{ .is_directory = true });
    try symLinkOrSkip(s.tmp.dir, io, try std.fmt.bufPrint(&lp, "../{s}/d", .{std.fs.path.basename(other.path)}), "up", .{ .is_directory = true });
    try symLinkOrSkip(s.tmp.dir, io, "dl", "c2", .{ .is_directory = true });
    try symLinkOrSkip(s.tmp.dir, io, "c2", "c1", .{ .is_directory = true });
    try symLinkOrSkip(s.tmp.dir, io, "sub", "in", .{ .is_directory = true });
    const script =
        \\for(f in dl/secret up/secret c1/secret sub/../dl/secret){
        \\    ls $f >[2]/dev/null || echo no stat $f
        \\    cat $f >[2]/dev/null || echo no read $f
        \\}
        \\@{echo x >dl/new} >[2]/dev/null || echo no create
        \\cat in/f
    ;
    const r = try run(e, &.{ "--cwd", s.path, "--rc", script });
    defer r.deinit();
    try std.testing.expectEqualStrings("no stat dl/secret\nno read dl/secret\nno stat up/secret\nno read up/secret\nno stat c1/secret\nno read c1/secret\nno stat sub/../dl/secret\nno read sub/../dl/secret\nno create\ninside\n", r.out);
    try std.testing.expect(!other.exists("d/new"));

    // dl itself is walked to as the link, not its target: its stat is
    // the link's own, so the outside directory's length doesn't show.
    // Give that directory entries enough to tell the two apart. On
    // Windows, devfs-win32 hides a link whose target is outside every
    // bound tree altogether, so there's no stat to show.
    if (builtin.os.tag == .windows) return;
    for (0..200) |i| {
        var nb: [64]u8 = undefined;
        try other.tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&nb, "d/padding-name-to-grow-the-directory-{d}", .{i}), .data = "" });
    }
    const l = try run(e, &.{ "--cwd", s.path, "--rc", "ls -l dl" });
    defer l.deinit();
    var fields = std.mem.tokenizeAny(u8, l.out, " \n");
    var length: []const u8 = "";
    for (0..6) |_| length = fields.next() orelse "";
    var want_buf: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&lp, "{s}/d", .{other.path});
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&want_buf, "{d}", .{target.len}), length);
}

test "--read-deny holds for a path reached through links and .. [baseline]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const io = std.testing.io;
    try s.tmp.dir.createDirPath(io, "priv");
    try s.tmp.dir.createDirPath(io, "sub");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "priv/.env", .data = "secret\n" });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "ok", .data = "ok\n" });
    // Links inside the cwd, which is allowed, to the denied directory and
    // the file in it, and one to the cwd itself in a subdirectory.
    try symLinkOrSkip(s.tmp.dir, io, "priv", "pl", .{ .is_directory = true });
    try symLinkOrSkip(s.tmp.dir, io, "priv/.env", "el", .{});
    try symLinkOrSkip(s.tmp.dir, io, "..", "sub/top", .{ .is_directory = true });
    var p: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const deny = try std.fmt.bufPrint(&p, "{s}/priv", .{s.path});
    const script =
        \\for(f in priv/.env pl/.env sub/top/priv/.env sub/../priv/.env){
        \\    ls $f >[2]/dev/null || echo no stat $f
        \\    cat $f >[2]/dev/null || echo no read $f
        \\}
        \\cat el >[2]/dev/null || echo no read el
        \\@{echo x >pl/new} >[2]/dev/null || echo no create
        \\cat sub/top/ok
    ;
    const r = try run(e, &.{ "--cwd", s.path, "--read-deny", deny, "--rc", script });
    defer r.deinit();
    try std.testing.expectEqualStrings("no stat priv/.env\nno read priv/.env\nno stat pl/.env\nno read pl/.env\nno stat sub/top/priv/.env\nno read sub/top/priv/.env\nno stat sub/../priv/.env\nno read sub/../priv/.env\nno read el\nno create\nok\n", r.out);
    try std.testing.expect(!s.exists("priv/new"));
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
    try std.testing.expect(std.mem.indexOf(u8, r.out, "devmask:  #C #I #ℏ #U #ι #b #i #m\n") != null);
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
    // 124, as coreutils timeout (design/epoch-0/exit-status.md).
    try std.testing.expectEqual(124, r.code);
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
    // #H/bin, h9's own commands, is in the union too
    // (design/epoch-0/guest-tools.md); the guest counts it.
    const h = try run(e, &.{ "--rc", "ls '#H/bin' | wc -l" });
    defer h.deinit();
    const in_h = try std.fmt.parseInt(usize, std.mem.trim(u8, h.out, " \n"), 10);
    // So is #H/over, h9's bind with -r, before the root's (design/epoch-0/mounts.md).
    const o = try run(e, &.{ "--rc", "ls '#H/over' | wc -l" });
    defer o.deinit();
    const in_over = try std.fmt.parseInt(usize, std.mem.trim(u8, o.out, " \n"), 10);
    const want = try countDir(e, bin) + try countDir(e, "rc/bin") + in_h + in_over;
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

/// The KVM vCPU limit `h9 --engine kvm --check` reports, or null when
/// KVM can't be used here.
fn kvmLimit(e: Env) !?u32 {
    const r = runOn(e, "kvm", &.{"--check"}, null) catch return null;
    defer r.deinit();
    const at = std.mem.indexOf(u8, r.out, "engine kvm: ok, ") orelse return null;
    var it = std.mem.tokenizeScalar(u8, r.out[at + "engine kvm: ok, ".len ..], ' ');
    return try std.fmt.parseInt(u32, it.next() orelse return null, 10);
}

test "--check reports kvm and its vCPU limit [kvm]" {
    const e = try env(@src());
    const n = try kvmLimit(e) orelse return error.SkipZigTest;
    try std.testing.expect(n > 8);
    const r = try runOn(e, "kvm", &.{"--check"}, null);
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "/bin/echo runs") != null);
}

test "auto uses kvm when /dev/kvm is usable [kvm]" {
    const e = try env(@src());
    _ = try kvmLimit(e) orelse return error.SkipZigTest;
    const r = try runOn(e, "auto", &.{"--check"}, null);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.out, "engine auto: ok (uses kvm)") != null);
    const w = try runOn(e, "auto", &.{ "/bin/echo", "hi" }, null);
    defer w.deinit();
    try std.testing.expectEqualStrings("hi\n", w.out);
    try std.testing.expectEqualStrings("", w.err);
}

test "without access to /dev/kvm, auto falls back to the emulator with a warning [kvm]" {
    const e = try env(@src());
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // Runs where this user can't open /dev/kvm (not in the kvm group).
    if (try kvmLimit(e) != null) return error.SkipZigTest;
    std.Io.Dir.accessAbsolute(std.testing.io, "/dev/kvm", .{}) catch return error.SkipZigTest;
    // KVM runs the host's architecture only; another's gets a different
    // reason (-Darch=arm64 or 386 on an x86-64 host).
    const host_arch: []const u8 = switch (builtin.cpu.arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        else => return error.SkipZigTest,
    };
    if (e.arch) |a| if (!std.mem.eql(u8, a, host_arch)) return error.SkipZigTest;
    const k = try runOn(e, "kvm", &.{ "/bin/echo", "hi" }, null);
    defer k.deinit();
    try std.testing.expectEqual(125, k.code);
    try std.testing.expect(std.mem.indexOf(u8, k.err, "no access to /dev/kvm (is your user in the kvm group?)") != null);
    const r = try runOn(e, "auto", &.{ "/bin/echo", "hi" }, null);
    defer r.deinit();
    // auto falls back only to the emulator; native is never chosen
    // automatically, since it isn't a security boundary (design/0095,
    // Security; security audit 2026-11-09). Without the emulator built in,
    // auto fails with the same reason instead of silently using native.
    if (r.code == 125) return error.SkipZigTest;
    try std.testing.expectEqualStrings("hi\n", r.out);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "warning: no access to /dev/kvm (is your user in the kvm group?); using the emulator") != null);
}

test "more live processes than KVM's owned vCPUs run on the pool [kvm]" {
    const e = try env(@src());
    _ = try kvmLimit(e) orelse return error.SkipZigTest;
    // KVM's limit is capped by the file descriptors left: with 330 of
    // them, 74, so processes own 66 and the 80 alive at once in this
    // pipeline need the pool.
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "/bin/sh", "-c", "ulimit -n 330 && exec \"$@\"", "sh", e.h9, "--engine", "kvm", "--dir", e.root });
    if (e.arch) |a| try argv.appendSlice(gpa, &.{ "--arch", a });
    try argv.appendSlice(gpa, &.{ "--rc", "c='echo deep'; for(i in `{seq 79}) c=$c^' | cat'; eval $c" });
    const r = try runProcess(argv.items, null);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    errdefer std.debug.print("{s}", .{r.stderr});
    try std.testing.expectEqualStrings("deep\n", r.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
}

test "more processes over a machine's life than KVM's vCPU limit [kvm]" {
    const e = try env(@src());
    const n = try kvmLimit(e) orelse return error.SkipZigTest;
    var buf: [128]u8 = undefined;
    const script = try std.fmt.bufPrint(&buf, "for(i in `{{seq {d}}}) /bin/true; echo done", .{n + 16});
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ e.h9, "--engine", "kvm", "--dir", e.root });
    if (e.arch) |a| try argv.appendSlice(gpa, &.{ "--arch", a });
    try argv.appendSlice(gpa, &.{ "--rc", script });
    const r = try runProcessWith(argv.items, null, null, 120_000);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expectEqualStrings("done\n", r.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
}

/// Skips unless WHP is built into this h9 and usable here (Windows x86_64
/// with the Windows Hypervisor Platform feature enabled).
fn requireWhp(e: Env) !void {
    if (builtin.os.tag != .windows or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    const r = try runOn(e, "whp", &.{"--check"}, null);
    defer r.deinit();
    if (std.mem.indexOf(u8, r.out, "engine whp: ok") == null) return error.SkipZigTest;
}

test "--check reports whp and its vCPU limit [whp]" {
    const e = try env(@src());
    try requireWhp(e);
    const r = try runOn(e, "auto", &.{"--check"}, null);
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "engine whp: ok, 64 vCPUs") != null);
}

test "auto uses whp when the feature is enabled [whp]" {
    const e = try env(@src());
    try requireWhp(e);
    const r = try runOn(e, "auto", &.{"--check"}, null);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.out, "engine auto: ok (uses whp)") != null);
}

test "more live processes than WHP's owned vCPUs run on the pool [whp]" {
    const e = try env(@src());
    try requireWhp(e);
    // 80 processes alive at once, past the 56 that own a vCPU.
    const r = try runOn(e, "whp", &.{ "--rc", "c='echo deep'; for(i in `{seq 79}) c=$c^' | cat'; eval $c" }, null);
    defer r.deinit();
    try std.testing.expectEqualStrings("deep\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "h9.exe starts and falls back to the emulator without the WHP feature [whp]" {
    if (builtin.os.tag != .windows or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    const e = try env(@src());
    const r = try runOn(e, "auto", &.{"--check"}, null);
    defer r.deinit();
    errdefer std.debug.print("--check said:\n{s}\n", .{r.out});
    // For a machine without the feature; with it, the cases above apply.
    if (std.mem.indexOf(u8, r.out, "engine whp: ok") != null) return error.SkipZigTest;
    // WHP runs amd64 only: with another root, it says so before it looks
    // for a hypervisor.
    if (std.mem.indexOf(u8, r.out, "engine whp: can't run this architecture") != null) return error.SkipZigTest;
    try std.testing.expect(std.mem.indexOf(u8, r.out, "engine whp: no usable hypervisor (enable the Windows Hypervisor Platform feature") != null);
    if (std.mem.indexOf(u8, r.out, "engine hcpu: ok") != null) {
        try std.testing.expect(std.mem.indexOf(u8, r.out, "engine auto: ok (uses hcpu)") != null);
    }
}

/// Skips unless the sud engine runs here (design/epoch-0/native-backend.md):
/// Linux x86_64 with Syscall User Dispatch and seccomp, and amd64 binaries.
fn requireSud(e: Env) !void {
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    if (e.arch == null or !std.mem.eql(u8, e.arch.?, "amd64")) return error.SkipZigTest;
    const r = try runOn(e, "sud", &.{"--check"}, null);
    defer r.deinit();
    if (std.mem.indexOf(u8, r.out, "engine sud: ok") == null) return error.SkipZigTest;
}

test "--check reports sud and runs its trap probe [native-backend]" {
    const e = try env(@src());
    try requireSud(e);
    // The engine runs its probe (a guest syscall with each of a list of
    // values in AX must trap) before it says it's usable.
    const r = try runOn(e, "sud", &.{"--check"}, null);
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try expectIn(r.out, "engine sud: ok, hello in ");
    try expectIn(r.out, "/bin/echo runs (amd64)");
}

test "auto never selects sud; it stays an explicit opt-in [native-backend]" {
    // The sud engine shares h9's address space and is not a security
    // boundary, so `auto` must not pick it silently (design/epoch-0/native-backend.md,
    // Security; security audit 2026-11-09). On a host with a hypervisor or
    // hcpu, auto uses one of those; sud runs only when asked for.
    const e = try env(@src());
    try requireSud(e);
    if (try kvmLimit(e) != null) return error.SkipZigTest;
    const r = try runOn(e, "auto", &.{"--check"}, null);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.out, "engine auto: ok (uses sud)") == null);
    // Explicit native still works. Its not-a-security-boundary warning is
    // printed only on a terminal, so stderr is clean here (not a tty).
    const w = try runOn(e, "sud", &.{ "/bin/echo", "hi" }, null);
    defer w.deinit();
    try std.testing.expectEqualStrings("hi\n", w.out);
    try std.testing.expectEqualStrings("", w.err);
}

test "auto never selects sud, by either name [renames]" {
    // `native` is an alias of `sud` for one release (design/epoch-0/renames.md), and
    // the rule that `auto` never picks it holds under both names: --check
    // says what auto uses, and only an explicit --engine runs on it.
    const e = try env(@src());
    try requireSud(e);
    if (try kvmLimit(e) != null) return error.SkipZigTest;
    const r = try runOn(e, "auto", &.{"--check"}, null);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.out, "engine auto: ok (uses sud)") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "(uses native)") == null);
    for ([_][]const u8{ "sud", "native" }) |name| {
        const w = try runOn(e, name, &.{ "/bin/echo", "hi" }, null);
        defer w.deinit();
        try std.testing.expectEqualStrings("hi\n", w.out);
        try std.testing.expectEqualStrings("", w.err);
    }
}

test "rfork with RFMEM shares data and bss but not the stack [native-backend]" {
    const e = try env(@src());
    try requireSud(e);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try buildC(e, &s, "rfstack", @embedFile("fixtures/rfmem/rfstack.c"));
    const r = try runOn(e, "sud", &.{ "--sandbox", s.path, "--rc", "./rfstack" }, null);
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("2 3 1\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "an RFMEM process can use pages another just grew, without a syscall [native-backend]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try buildC(e, &s, "rfgrow", @embedFile("fixtures/rfmem/rfgrow.c"));
    // Two CPUs at least, so the child spins while the parent grows the
    // break. Before native carried out queued mappings on a fault, the
    // child's first write to the new pages was "sys: trap: fault write"
    // (rio's procs malloc'ing from one heap, in 9/UX's GUI tests).
    const r = try run(e, &.{ "--sandbox", s.path, "--timeout", "60s", "--cpus", "4", "--rc", "./rfgrow 32" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("32 rounds\n", r.out);
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
    const r = try run(e, &.{ "--cwd", s.path, "--ns", s.ns(), "ls", "-d", "/lib/acid" });
    defer r.deinit();
    try std.testing.expectEqualStrings("/lib/acid\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

// A root's default command (design/epoch-0/default-command.md). The stock tree
// has no /rc/lib/rcmain.local, so these union one from a scratch dir onto
// /rc/lib with --ns; rcmain and /bin/test come from the root.

/// A scratch dir holding lib/rcmain.local with `script`, and an `ns` file
/// that binds lib after /rc/lib.
fn defaultCommand(s: *Scratch, script: []const u8) !void {
    try s.init();
    errdefer s.deinit();
    try s.tmp.dir.createDirPath(std.testing.io, "lib");
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/rcmain.local", .data = script });
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ns", .data = "bind -a /mnt/term/cwd/lib /rc/lib\n" });
}

test "--rc alone runs the root's rcmain.local, then stdin [default-command]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try defaultCommand(&s, "echo hello from the root\n");
    defer s.deinit();
    const r = try runIn(e, &.{ "--cwd", s.path, "--ns", s.ns(), "--rc" }, "echo from stdin $service\n");
    defer r.deinit();
    try std.testing.expectEqualStrings("hello from the root\nfrom stdin terminal\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "an exec in rcmain.local sets the exit status [default-command]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try defaultCommand(&s, "exec test -e /no/such/file\n");
    defer s.deinit();
    // The exec replaces the login rc, so stdin is never read.
    const r = try runIn(e, &.{ "--cwd", s.path, "--ns", s.ns(), "--rc" }, "echo not reached\n");
    defer r.deinit();
    try std.testing.expectEqualStrings("", r.out);
    try std.testing.expectEqual(1, r.code);
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/rcmain.local", .data = "exec echo hello from the root\n" });
    const ok = try runIn(e, &.{ "--cwd", s.path, "--ns", s.ns(), "--rc" }, "echo not reached\n");
    defer ok.deinit();
    try std.testing.expectEqualStrings("hello from the root\n", ok.out);
    try std.testing.expectEqual(0, ok.code);
}

test "--rc alone without rcmain.local is a plain rc [default-command]" {
    const e = try env(@src());
    const r = try runIn(e, &.{"--rc"}, "echo plain; test -e /no/such/file\n");
    defer r.deinit();
    try std.testing.expectEqualStrings("plain\n", r.out);
    try std.testing.expectEqual(1, r.code);
    const none = try run(e, &.{"--rc"});
    defer none.deinit();
    try std.testing.expectEqualStrings("", none.out);
    try std.testing.expectEqual(0, none.code);
}

test "--rc alone on a terminal is an interactive login rc [default-command]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try defaultCommand(&s, "echo hello from the root\n");
    defer s.deinit();
    var it = engineList(e);
    while (it.next()) |engine| {
        errdefer std.debug.print("engine {s}\n", .{engine});
        var t = try spawnTerm(e, engine, &.{ "--timeout", "60s", "--cwd", s.path, "--ns", s.ns(), "--rc" });
        defer t.deinit();
        try t.expect("hello from the root", slow(10_000));
        try t.expect(prompt, slow(10_000));
        // The output, xy, isn't in the echoed input, echo x^y.
        try t.send("echo x^y" ++ enter);
        try t.expect("xy", slow(10_000));
        try t.expect(prompt, slow(10_000));
        try t.send("exit" ++ enter);
        try std.testing.expectEqual(0, try t.wait(slow(10_000)));
    }
}

test "--rc 'cmd' doesn't read rcmain.local [default-command]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try defaultCommand(&s, "echo hello from the root\n");
    defer s.deinit();
    const r = try run(e, &.{ "--cwd", s.path, "--ns", s.ns(), "--rc", "echo cmd" });
    defer r.deinit();
    try std.testing.expectEqualStrings("cmd\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

// Ephemeral writes and a private /tmp (design/epoch-0/ephemeral-writes.md).

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

test "a new file in an ephemeral cwd is readable and absent on the host afterwards [ephemeral-writes]" {
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

test "an exclusive-use file in the overlay opens once at a time [ephemeral-writes]" {
    const e = try env(@src());
    // DMEXCL (chmod +l), as 9front's file servers keep it: a second open
    // while one is open fails, and succeeds once that one is closed.
    const r = try run(e, &.{ "--rc", "touch /tmp/f && chmod +l /tmp/f && { cat /tmp/f >[2=1] } </tmp/f; cat /tmp/f && echo again" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try expectIn(r.out, "file is locked");
    try expectIn(r.out, "again\n");
}

test "writing an existing host file changes it in the guest only [ephemeral-writes]" {
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

test "removing a host file hides it in the guest only [ephemeral-writes]" {
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

test "rm then recreate, as mk clean && mk does, works [ephemeral-writes]" {
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

test "a file rename moves it in the guest only [ephemeral-writes]" {
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

test "renaming a host directory is refused [ephemeral-writes]" {
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

test "ls of an overlaid directory lists each name once [ephemeral-writes]" {
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

test "a --writable path inside a read-only cwd is ephemeral [ephemeral-writes]" {
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

test "--read-deny still hides a path inside an ephemeral tree [ephemeral-writes]" {
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

test "the tight profile's cwd is ephemeral under --write=ephemeral [ephemeral-writes]" {
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

test "/tmp is private and writable in both profiles [ephemeral-writes]" {
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

test "/tmp is read-only under --write=none [ephemeral-writes]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--write=none", "--rc", "echo x > /tmp/f" });
    defer r.deinit();
    try std.testing.expectEqual(1, r.code);
}

test "filling an overlay fails with file system full and the machine carries on [ephemeral-writes]" {
    const e = try env(@src());
    // A failed write keeps nothing, so up to one 4 MiB block is free again
    // for rm to run.
    const r = try run(e, &.{ "--memory", "32m", "--rc", "dd -if /dev/zero -of /tmp/big -bs 4194304 -count 16; rm /tmp/big; echo small > /tmp/s && cat /tmp/s" });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.err, "file system full") != null);
    try std.testing.expectEqualStrings("small\n", r.out);
}

test "creating empty files until memory runs out fails with file system full [ephemeral-writes]" {
    const e = try env(@src());
    // rc makes the files itself, without forking: no memory is left for
    // another process. A redirection with no command doesn't set $status
    // when it works, so there's nothing to test in the loop; when one
    // fails, rc prints the error and leaves the script. About 30,000 files
    // fit; on WHP, whose exits are slower, making them takes about 45s.
    const r = try runInFor(e, &.{ "--memory", "32m", "--rc", "for(i in `{seq 150000}) >/tmp/e$i; exit never" }, null, 120_000);
    defer r.deinit();
    try std.testing.expectEqual(1, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "file system full") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "never") == null);
}

test "renaming a directory marker is refused [ephemeral-writes]" {
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

test "--write=ephemeral runs, and --print shows the overlays [ephemeral-writes]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const r = try runEph(e, &s, &.{ "--print", "echo" });
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "fs.write.ephemeral") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "  bind -c '#O' /mnt/term/cwd ") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "  bind -c '#O' /tmp ") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "  eph  ") != null);
    const ok = try runEph(e, &s, &.{ "echo", "ok" });
    defer ok.deinit();
    try std.testing.expectEqual(0, ok.code);
}

test "--print output with overlays replays with --ns [ephemeral-writes]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const p = try runEph(e, &s, &.{ "--print", "echo" });
    defer p.deinit();
    // The namespace section, as a file the guest reads from its cwd.
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ns", .data = try printedNamespace(p.out) });
    // Under --write=none the replay's overlays make the cwd and /tmp writable.
    const r = try run(e, &.{ "--cwd", s.path, "--write=none", "--ns", s.ns(), "--rc", "echo x > f && echo y > /tmp/g && cat f /tmp/g" });
    defer r.deinit();
    try std.testing.expectEqualStrings("x\ny\n", r.out);
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(!s.exists("f"));
}

test "removing every .c file in a source tree leaves the host unchanged (demo) [ephemeral-writes]" {
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

// The root's overlay (design/epoch-0/overlay.md).

/// Fails if the root tree on the host has `rel`.
fn expectRootLacks(e: Env, rel: []const u8) !void {
    std.Io.Dir.cwd().access(std.testing.io, try hostPath(e.root, rel), .{}) catch return;
    std.debug.print("root tree has {s}\n", .{rel});
    return error.RootWasWritten;
}

test "a write to the root under the default profile succeeds and leaves the root tree unchanged [overlay]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const r = try run(e, &.{ "--cwd", s.path, "--rc", "echo hi > /lib/h9-overlay && cat /lib/h9-overlay" });
    defer r.deinit();
    try std.testing.expectEqualStrings("hi\n", r.out);
    try std.testing.expectEqual(0, r.code);
    try expectRootLacks(e, "lib/h9-overlay");
}

test "a file written in /lib reads back and isn't in the root tree (demo) [overlay]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--rc", "echo hi > /lib/x && cat /lib/x" });
    defer r.deinit();
    try std.testing.expectEqualStrings("hi\n", r.out);
    try std.testing.expectEqual(0, r.code);
    try expectRootLacks(e, "lib/x");
}

test "mk install into the root works and leaves the root tree unchanged (demo) [overlay]" {
    const e = try env(@src());
    // Needs /sys/src (zig build mkroot -- --src).
    std.Io.Dir.cwd().access(std.testing.io, try hostPath(e.root, "sys/src/cmd/cat.c"), .{}) catch return error.SkipZigTest;
    var bin_buf: [64]u8 = undefined;
    const bin = try std.fmt.bufPrint(&bin_buf, "{s}/bin/cat", .{e.arch orelse "arm64"});
    const host_before = try std.Io.Dir.cwd().statFile(std.testing.io, try hostPath(e.root, bin), .{});
    // A cat that exits with a status of its own, so the run shows which
    // binary /bin/cat is.
    const r = try run(e, &.{ "--timeout", "300s", "--rc", "cd /sys/src/cmd && sed 's/exits\\(0\\)/exits(\"newcat\")/' cat.c > /tmp/c && cp /tmp/c cat.c && mk cat.install >/dev/null && echo x | /bin/cat; echo $status" });
    defer r.deinit();
    errdefer std.debug.print("{s}", .{r.err});
    try std.testing.expect(std.mem.startsWith(u8, r.out, "x\ncat "));
    try std.testing.expect(std.mem.endsWith(u8, r.out, ": newcat\n"));
    // The root tree's cat and source are as they were.
    const host_after = try std.Io.Dir.cwd().statFile(std.testing.io, try hostPath(e.root, bin), .{});
    try std.testing.expectEqual(host_before.size, host_after.size);
    try std.testing.expectEqual(host_before.mtime, host_after.mtime);
    var src: [4096]u8 = undefined;
    const text = try std.Io.Dir.cwd().readFile(std.testing.io, try hostPath(e.root, "sys/src/cmd/cat.c"), &src);
    try std.testing.expect(std.mem.indexOf(u8, text, "newcat") == null);
    try expectRootLacks(e, "sys/src/cmd/cat.7");
}

test "removing a root file hides it in the guest only [overlay]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--rc", "rm /lib/namespace && ls /lib/namespace; ls /lib | grep -c '^namespace$'" });
    defer r.deinit();
    try std.testing.expectEqualStrings("0\n", r.out);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "/lib/namespace") != null);
    try std.Io.Dir.cwd().access(std.testing.io, try hostPath(e.root, "lib/namespace"), .{});
}

test "$home exists and is writable when the root has no /usr/$user [overlay]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--rc", "echo $user; test -d $home && echo x > $home/f && cat $home/f" });
    defer r.deinit();
    var lines = std.mem.splitScalar(u8, r.out, '\n');
    const user = lines.next().?;
    var rel: [128]u8 = undefined;
    const home = try std.fmt.bufPrint(&rel, "usr/{s}", .{user});
    // The root tree has /usr/glenda; any other user's home is made.
    if (std.Io.Dir.cwd().access(std.testing.io, try hostPath(e.root, home), .{})) |_| return error.SkipZigTest else |_| {}
    try std.testing.expectEqualStrings("x", lines.next().?);
    try std.testing.expectEqual(0, r.code);
    try expectRootLacks(e, home);
}

test "the cwd still writes the host under --write=overlay [overlay]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const r = try run(e, &.{ "--cwd", s.path, "--write=overlay", "--rc", "echo x > f && echo y > /lib/h9-overlay-cwd" });
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(s.exists("f"));
    try expectRootLacks(e, "lib/h9-overlay-cwd");
}

test "--write=scope keeps the root read-only [overlay]" {
    const e = try env(@src());
    for ([_][]const u8{ "--profile=default", "--profile=tight" }) |prof| {
        const r = try run(e, &.{ prof, "--write=scope", "--rc", "echo x > /lib/h9-overlay-scope" });
        defer r.deinit();
        try std.testing.expectEqual(1, r.code);
        // A stack with no member taking creates (design/epoch-0/mounts.md).
        try std.testing.expect(std.mem.indexOf(u8, r.err, "mounted directory forbids creation") != null);
    }
    try expectRootLacks(e, "lib/h9-overlay-scope");
}

test "--writable on the root writes the host, with no overlay [overlay]" {
    const e = try env(@src());
    const name = "lib/h9-overlay-writable";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, hostPath(e.root, name) catch unreachable) catch {};
    const p = try run(e, &.{ "--writable", e.root, "--print", "echo" });
    defer p.deinit();
    try std.testing.expect(std.mem.indexOf(u8, p.out, "'#O' / ") == null);
    try std.testing.expect(std.mem.indexOf(u8, p.out, "fs.write.overlay") != null);
    const r = try run(e, &.{ "--writable", e.root, "--rc", "echo kept > /" ++ name });
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("kept\n", try std.Io.Dir.cwd().readFile(std.testing.io, try hostPath(e.root, name), &buf));
}

test "--write=ephemeral overlays the root as well [overlay]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const r = try runEph(e, &s, &.{ "--rc", "echo hi > /lib/h9-overlay-eph && echo x > f && cat /lib/h9-overlay-eph f" });
    defer r.deinit();
    try std.testing.expectEqualStrings("hi\nx\n", r.out);
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(!s.exists("f"));
    try expectRootLacks(e, "lib/h9-overlay-eph");
}

test "--write=overlay runs, and --print shows it enforced [overlay]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--write=overlay", "echo", "ok" });
    defer r.deinit();
    try std.testing.expectEqualStrings("ok\n", r.out);
    try std.testing.expectEqual(0, r.code);
    const p = try run(e, &.{ "--print", "echo" });
    defer p.deinit();
    try std.testing.expectEqual(0, p.code);
    try std.testing.expect(std.mem.indexOf(u8, p.out, "fs.write.overlay") != null);
}

test "--print output with the root overlay replays with --ns [overlay]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const p = try run(e, &.{ "--cwd", s.path, "--print", "echo" });
    defer p.deinit();
    try std.testing.expect(std.mem.indexOf(u8, p.out, "  bind -c '#O' '#Oroot' ") != null);
    try std.testing.expect(std.mem.indexOf(u8, p.out, "writes to the root are kept in memory") != null);
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ns", .data = try printedNamespace(p.out) });
    // Under --write=scope the root is read-only until the replay's overlay.
    const r = try run(e, &.{ "--cwd", s.path, "--write=scope", "--ns", s.ns(), "--rc", "echo x > /lib/h9-overlay-ns && cat /lib/h9-overlay-ns" });
    defer r.deinit();
    try std.testing.expectEqualStrings("x\n", r.out);
    try std.testing.expectEqual(0, r.code);
    try expectRootLacks(e, "lib/h9-overlay-ns");
}

test "the tight profile's root is an overlay [overlay]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const r = try run(e, &.{ "--cwd", s.path, "--profile=tight", "--rc", "echo hi > /lib/h9-overlay-tight && cat /lib/h9-overlay-tight; echo x > f" });
    defer r.deinit();
    try std.testing.expectEqualStrings("hi\n", r.out);
    // The cwd stays read-only.
    try std.testing.expectEqual(1, r.code);
    try std.testing.expect(!s.exists("f"));
    try expectRootLacks(e, "lib/h9-overlay-tight");
}

test "a write to the root fails with file system full when memory runs out [overlay]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--memory", "32m", "--rc", "dd -if /dev/zero -of /lib/big -bs 4194304 -count 16; rm /lib/big; echo small > /lib/s && cat /lib/s" });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.err, "file system full") != null);
    try std.testing.expectEqualStrings("small\n", r.out);
    try expectRootLacks(e, "lib/big");
}

const notice = "h9: changes to the root under ";

test "the discarded-changes notice is printed on a terminal and not otherwise [overlay]" {
    const e = try env(@src());
    const script = "echo x > /lib/h9-notice; mkdir /sys/h9-notice; echo done";
    const r = try run(e, &.{ "--rc", script });
    defer r.deinit();
    try std.testing.expectEqualStrings("done\n", r.out);
    try std.testing.expect(std.mem.indexOf(u8, r.err, notice) == null);
    var it = engineList(e);
    while (it.next()) |engine| {
        errdefer std.debug.print("engine {s}\n", .{engine});
        var t = try spawnTerm(e, engine, &.{ "--rc", script });
        defer t.deinit();
        try t.expect(notice ++ "/lib, /sys were discarded (--dir DIR:/:up keeps them in DIR)", slow(20_000));
        try std.testing.expectEqual(0, try t.wait(slow(10_000)));
    }
}

test "changes only under $home, or only by the namespace builder, print no notice [overlay]" {
    const e = try env(@src());
    var it = engineList(e);
    while (it.next()) |engine| {
        errdefer std.debug.print("engine {s}\n", .{engine});
        // The builder may make $home; the guest writes only there.
        var t = try spawnTerm(e, engine, &.{ "--rc", "echo x > $home/h9-notice; echo done" });
        defer t.deinit();
        try t.expect("done", slow(20_000));
        try std.testing.expectEqual(0, try t.wait(slow(10_000)));
        t.drain(200) catch {};
        try std.testing.expect(std.mem.indexOf(u8, t.out.items, notice) == null);
    }
}

// Self-hosting (design/epoch-0/self-host.md): the root's compilers and mk
// build 9front's own source, and acid debugs live processes. The builds
// use the root's /sys/src (zig build mkroot -- --src), or else H9_TEST_SRC,
// a checkout's sys directory, bound over /sys; they skip without either.
// They write into a scratch cwd, never into the root.

/// How a case reaches /sys/src: extra h9 flags, and an rc prefix that
/// binds it.
const Src = struct {
    flags: []const []const u8,
    bind: []const u8,
};

var src_flags: [2][]const u8 = undefined;
var src_bind_buf: [std.Io.Dir.max_path_bytes + 64]u8 = undefined;

fn selfSrc(e: Env) !Src {
    if (std.Io.Dir.cwd().access(std.testing.io, try hostPath(e.root, "sys/src/cmd/ls.c"), .{})) |_| {
        return .{ .flags = &.{}, .bind = "" };
    } else |_| {}
    const dir = getenv(6, "H9_TEST_SRC") orelse return error.SkipZigTest;
    var path_tmp: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const ls = std.fmt.bufPrint(&path_tmp, "{s}/src/cmd/ls.c", .{dir}) catch return error.SkipZigTest;
    std.Io.Dir.cwd().access(std.testing.io, ls, .{}) catch return error.SkipZigTest;
    src_flags = .{ "--readable", dir };
    return .{ .flags = &src_flags, .bind = try std.fmt.bufPrint(&src_bind_buf, "bind -a /mnt/term{s} /sys && ", .{dir}) };
}

/// The architecture the case's binaries are for, and its compiler's letter.
fn selfArch(e: Env) struct { name: []const u8, o: []const u8 } {
    const a = e.arch orelse "arm64";
    const o: []const u8 = if (std.mem.eql(u8, a, "amd64")) "6" else if (std.mem.eql(u8, a, "386")) "8" else "7";
    return .{ .name = a, .o = o };
}

/// Runs rc `script` with the scratch dir `s` as the cwd and `/sys/src`
/// from `src` bound first, under `flags` and a 600 s timeout.
fn runSelf(e: Env, s: *Scratch, src: Src, flags: []const []const u8, script: []const u8, stdin: ?[]const u8) !Result {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    var tb: [16]u8 = undefined;
    try argv.appendSlice(gpa, &.{ "--cwd", s.path, "--timeout", slowTimeout(&tb, 600_000) });
    try argv.appendSlice(gpa, src.flags);
    try argv.appendSlice(gpa, flags);
    const cmd = try std.mem.concat(gpa, u8, &.{ src.bind, script });
    defer gpa.free(cmd);
    try argv.appendSlice(gpa, &.{ "--rc", cmd });
    return runInFor(e, argv.items, stdin, 660_000);
}

fn expectOk(r: Result, want: []const u8) !void {
    errdefer std.debug.print("stdout:\n{s}\nstderr:\n{s}\n", .{ r.out, r.err });
    try std.testing.expectEqualStrings(want, r.out);
    try std.testing.expectEqual(0, r.code);
}

test "7c and 7l build ls in the cwd, and it runs [self-host]" {
    const e = try env(@src());
    const src = try selfSrc(e);
    const a = selfArch(e);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var buf: [256]u8 = undefined;
    const r = try runSelf(e, &s, src, &.{}, try std.fmt.bufPrint(&buf, "cp /sys/src/cmd/ls.c . && {0s}c ls.c && {0s}l -o {0s}.ls ls.{0s} && ./{0s}.ls -d /", .{a.o}), null);
    defer r.deinit();
    try expectOk(r, "/\n");
    try std.testing.expect(s.exists(try std.fmt.bufPrint(&buf, "{s}.ls", .{a.o})));
}

test "mk builds ls and cat with the stock cmd/mkfile, byte-identical to the root's [self-host]" {
    const e = try env(@src());
    const src = try selfSrc(e);
    const a = selfArch(e);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    // The scratch dir goes before /sys/src/cmd in a union, so mk reads the
    // stock mkfile and source and creates its files in the scratch dir,
    // and the symbols name /sys/src/cmd as the shipped binaries' do.
    var buf: [512]u8 = undefined;
    const r = try runSelf(e, &s, src, &.{}, try std.fmt.bufPrint(&buf,
        \\bind -bc /mnt/term/cwd /sys/src/cmd && cd /sys/src/cmd &&
        \\mk ls.{0s} cat.{0s} >/dev/null && mk {0s}.ls {0s}.cat >/dev/null &&
        \\cmp {0s}.ls /{1s}/bin/ls && cmp {0s}.cat /{1s}/bin/cat && echo identical
    , .{ a.o, a.name }), null);
    defer r.deinit();
    try expectOk(r, "identical\n");
    try std.testing.expect(s.exists(try std.fmt.bufPrint(&buf, "{s}.ls", .{a.o})));
    try expectRootLacks(e, try std.fmt.bufPrint(&buf, "sys/src/cmd/{s}.ls", .{a.o}));
}

test "mk builds a library into the cwd against the read-only root [self-host]" {
    const e = try env(@src());
    const src = try selfSrc(e);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const r = try runSelf(e, &s, src, &.{"--write=scope"},
        \\bind -bc /mnt/term/cwd /sys/src/libbio && cd /sys/src/libbio &&
        \\mk 'LIB=/mnt/term/cwd/libbio.a' >/dev/null && ar t /mnt/term/cwd/libbio.a | grep -c '^bprint\.'
    , null);
    defer r.deinit();
    try expectOk(r, "1\n");
    try std.testing.expect(s.exists("libbio.a"));
}

test "mk install into a read-only root fails with permission denied [self-host]" {
    const e = try env(@src());
    const src = try selfSrc(e);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    // --write=scope keeps the root read-only; the default profile's
    // overlay would take the install in memory (design/epoch-0/overlay.md).
    const r = try runSelf(e, &s, src, &.{"--write=scope"}, "bind -bc /mnt/term/cwd /sys/src/cmd && cd /sys/src/cmd && mk cat.install >/dev/null", null);
    defer r.deinit();
    errdefer std.debug.print("stderr:\n{s}\n", .{r.err});
    try std.testing.expectEqual(1, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "permission denied") != null);
}

test "NPROC defaults to the vCPU limit, and --env overrides it [self-host]" {
    const e = try env(@src());
    const two = try run(e, &.{ "--cpus", "2", "--rc", "echo $NPROC" });
    defer two.deinit();
    try expectOk(two, "2\n");
    const set = try run(e, &.{ "--cpus", "2", "--env", "NPROC=5", "--rc", "echo $NPROC" });
    defer set.deinit();
    try expectOk(set, "5\n");
    // Without --cpus, the host's CPU count, capped by the engine's limit.
    const def = try run(e, &.{ "--rc", "echo $NPROC" });
    defer def.deinit();
    const n = try std.fmt.parseInt(u32, std.mem.trim(u8, def.out, "\n"), 10);
    try std.testing.expect(n >= 1 and n <= @max(1, try std.Thread.getCpuCount()));
}

test "parallel mk builds 7c repeatedly without hanging [self-host]" {
    const e = try env(@src());
    const src = try selfSrc(e);
    const a = selfArch(e);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    // Before kern's locks were ordered (-DPTHREAD), mk with NPROC > 1
    // hung in about 1 run in 8.
    var buf: [512]u8 = undefined;
    const r = try runSelf(e, &s, src, &.{}, try std.fmt.bufPrint(&buf,
        \\bind -bc /mnt/term/cwd /sys/src/cmd/7c && cd /sys/src/cmd/7c &&
        \\for(i in 1 2 3){{
        \\    rm -f *.{0s}
        \\    NPROC=4 mk cgen.{0s} enam.{0s} list.{0s} machcap.{0s} mul.{0s} peep.{0s} pgen.{0s} pswt.{0s} reg.{0s} sgen.{0s} swt.{0s} txt.{0s} >/dev/null || echo failed
        \\}}
        \\ls *.{0s} | wc -l
    , .{a.o}), null);
    defer r.deinit();
    try expectOk(r, "     12\n");
}

test "/proc/n/segment lists Stack first [self-host]" {
    const e = try env(@src());
    // libmach's stacktop reads the first line.
    const r = try run(e, &.{ "--rc", "sed 1q /proc/$pid/segment | awk '{print $1}'" });
    defer r.deinit();
    try expectOk(r, "Stack\n");
}

/// Builds tests/fixtures/selfhost's target and dbg into the scratch dir.
fn buildDebug(e: Env, s: *Scratch) !void {
    const a = selfArch(e);
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "target.c", .data = @embedFile("fixtures/selfhost/target.c") });
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "dbg.c", .data = @embedFile("fixtures/selfhost/dbg.c") });
    var buf: [256]u8 = undefined;
    const r = try run(e, &.{ "--cwd", s.path, "--rc", try std.fmt.bufPrint(&buf, "for(f in target dbg) {0s}c -FTVw $f.c && {0s}l -o $f $f.{0s} || exit build", .{a.o}) });
    defer r.deinit();
    errdefer std.debug.print("build: {s}{s}", .{ r.out, r.err });
    try std.testing.expectEqual(0, r.code);
}

/// rc functions for the debugging cases: `addr sym` is a symbol's address
/// in target, and `run mode` starts `./target mode` in the background,
/// sets $p to its pid, and prints its exit status when it ends, without
/// the pid. nm prints addresses in lower-case hex, and dc reads only
/// upper case, so arithmetic on them goes through tr.
const debug_rc =
    \\fn addr { nm target | awk '$3 == "'$1'" { print $1 }' }
    \\fn run { rm -f pid child; { ./target $*; echo status $status | sed 's/^status target [0-9]+:/status target:/' } & while(! test -s pid) sleep 0.05; p=`{cat pid} }
    \\
;

/// Builds the debugging fixtures and runs rc `script` after `debug_rc`.
fn runDebug(e: Env, script: []const u8, stdin: ?[]const u8) !Result {
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try buildDebug(e, &s);
    const cmd = try std.mem.concat(gpa, u8, &.{ debug_rc, script });
    defer gpa.free(cmd);
    var tb: [16]u8 = undefined;
    return runInFor(e, &.{ "--cwd", s.path, "--timeout", slowTimeout(&tb, 60_000), "--rc", cmd }, stdin, 90_000);
}

test "/proc/n/regs and fpregs read a stopped process's registers [self-host]" {
    const e = try env(@src());
    const r = try runDebug(e,
        \\run thrice
        \\echo waitstop >/proc/$p/ctl
        \\awk '{print $3}' /proc/$p/status
        \\./dbg regs $p
        \\echo kill >/proc/$p/ctl
        \\wait
    , null);
    defer r.deinit();
    // arm64's FPsave (libmach's FPREGSIZE), else the FXSAVE area.
    const fp: usize = if (std.mem.eql(u8, selfArch(e).name, "arm64")) 520 else 512;
    var buf: [128]u8 = undefined;
    try expectOk(r, try std.fmt.bufPrint(&buf, "1\nStopped\nregs: a Ureg\npc in text 1\nfpregs {d}\nstatus target: Killed\n", .{fp}));
}

test "/proc/n/mem reads a variable and a write to text doesn't reach a sibling [self-host]" {
    const e = try env(@src());
    // The parent and child share text until the write, which gives the
    // parent its own copy.
    const r = try runDebug(e,
        \\n=`{echo 16 i `{addr three} `{addr two} - p | tr a-f A-F | dc}
        \\run pair >out
        \\echo waitstop >/proc/$p/ctl
        \\c=`{cat child}
        \\echo waitstop >/proc/$c/ctl
        \\./dbg peek $p `{addr magic}
        \\./dbg copy $p `{addr two} `{addr answer} $n
        \\awk '$1 == "Text" {print $5}' /proc/$p/segment /proc/$c/segment
        \\echo start >/proc/$c/ctl
        \\echo start >/proc/$p/ctl
        \\wait
        \\sort out
    , null);
    defer r.deinit();
    try expectOk(r, "0x5eedf00d\n1\n1\nchild 1\nparent 2\nstatus \n");
}

test "/proc/n/mem writes to text are fetched by the next run, including a rewrite of the same address [self-host]" {
    const e = try env(@src());
    // target isn't sharing its text, so the writes go to the same pages
    // each time, and only the code-cache invalidation makes them seen.
    const r = try runDebug(e,
        \\n=`{echo 16 i `{addr three} `{addr two} - p | tr a-f A-F | dc}
        \\run thrice
        \\echo waitstop >/proc/$p/ctl
        \\./dbg copy $p `{addr two} `{addr answer} $n
        \\echo start >/proc/$p/ctl
        \\echo waitstop >/proc/$p/ctl
        \\./dbg copy $p `{addr three} `{addr answer} $n
        \\echo start >/proc/$p/ctl
        \\echo waitstop >/proc/$p/ctl
        \\echo start >/proc/$p/ctl
        \\wait
    , null);
    defer r.deinit();
    try expectOk(r, "1\n2\n3\nstatus \n");
}

test "ctl hang stops a process at exec, and start runs it [self-host]" {
    const e = try env(@src());
    const r = try runDebug(e,
        \\run hang
        \\echo waitstop >/proc/$p/ctl
        \\awk '{print $1, $3}' /proc/$p/status
        \\echo start >/proc/$p/ctl
        \\wait
    , null);
    defer r.deinit();
    try expectOk(r, "echo Stopped\nhang\nstatus \n");
}

test "ctl stop stops a process spinning in guest code [self-host]" {
    const e = try env(@src());
    // The emulator passes the CPU on only at an exit, so target spin makes
    // a syscall every few milliseconds; on a hypervisor, stop kicks the
    // vCPU out of the loop.
    const r = try runDebug(e,
        \\run spin
        \\echo stop >/proc/$p/ctl
        \\awk '{print $3}' /proc/$p/status
        \\echo start >/proc/$p/ctl
        \\awk '{print $3}' /proc/$p/status | grep -c Stopped
        \\echo kill >/proc/$p/ctl
        \\wait
    , null);
    defer r.deinit();
    try expectOk(r, "Stopped\n0\nstatus target: Killed\n");
}

test "a BRK posts sys: breakpoint [self-host]" {
    const e = try env(@src());
    const r = try runDebug(e,
        \\run thrice
        \\echo waitstop >/proc/$p/ctl
        \\./dbg brk $p `{addr answer}
        \\echo start >/proc/$p/ctl
        \\wait
        \\echo answer `{addr answer}
    , null);
    defer r.deinit();
    errdefer std.debug.print("stdout:\n{s}\nstderr:\n{s}\n", .{ r.out, r.err });
    // The PC is the BRK's on arm64 and past the INT3 on x86.
    const nl = std.mem.lastIndexOfScalar(u8, r.out[0 .. r.out.len - 1], '\n').?;
    const answer = try std.fmt.parseInt(u64, std.mem.trim(u8, r.out[nl + 1 + "answer ".len ..], "\n"), 16);
    const a = selfArch(e);
    var buf: [128]u8 = undefined;
    const pc = if (std.mem.eql(u8, a.name, "arm64")) answer else answer + 1;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "1\nstatus target: sys: breakpoint pc=0x{x}\n", .{pc}), r.out[0 .. nl + 1]);
}

test "acid attaches and prints registers and a stack trace [self-host]" {
    const e = try env(@src());
    var tb: [16]u8 = undefined;
    // The sleep has to outlast acid's start, which H9_TEST_SLOW slows too.
    var sb: [96]u8 = undefined;
    const script = try std.fmt.bufPrint(&sb, "sleep {d} & sleep 1; acid $apid; echo kill >/proc/$apid/ctl", .{slow(5)});
    const r = try runIn(e, &.{ "--timeout", slowTimeout(&tb, 60_000), "--rc", script }, "regs()\nstk()\n");
    defer r.deinit();
    errdefer std.debug.print("stdout:\n{s}\nstderr:\n{s}\n", .{ r.out, r.err });
    // acid prints its registers by name: R0 on arm64, AX on x86, after a
    // tab, except amd64's, which pads with spaces.
    const a = selfArch(e);
    const reg = if (std.mem.eql(u8, a.name, "arm64")) "R0\t0x" else if (std.mem.eql(u8, a.name, "amd64")) "AX    0x" else "AX\t0x";
    try std.testing.expect(std.mem.indexOf(u8, r.out, reg) != null);
    // amd64's frame shows sleep's argument, sleep(a0=0x1388)+0xe.
    try std.testing.expect(std.mem.indexOf(u8, r.out, "\nsleep(") != null or std.mem.indexOf(u8, r.out, " sleep(") != null);
    // arm64's frame passes argc in a register, so acid shows main(argv=);
    // 386's has both on the stack, main(argc=0x2,argv=...).
    try std.testing.expect(std.mem.indexOf(u8, r.out, "main(argv=") != null or std.mem.indexOf(u8, r.out, "main(argc=") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "/sys/src/cmd/sleep.c:") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "warning") == null);
}

// The terminal. These run h9 on a pty or pseudoconsole from tests/term.zig.

/// Enter, as a terminal sends it: cooked mode turns it into a newline on
/// every host.
const enter = "\r";

/// rc's prompt. ConPTY redraws the screen rather than passing output
/// through, and draws the trailing space of "% " as a cursor movement.
const prompt = "%";

/// Runs `h9 --engine <engine> --dir <root> args...` on a new terminal.
fn spawnTerm(e: Env, engine: []const u8, args: []const []const u8) !Term {
    return spawnTermEnv(e, engine, args, &.{});
}

/// `spawnTerm`, with `extra` (NAME=value strings) in h9's environment.
fn spawnTermEnv(e: Env, engine: []const u8, args: []const []const u8, extra: []const []const u8) !Term {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ e.h9, "--engine", engine });
    if (!givesRoot(args)) try argv.appendSlice(gpa, &.{ "--dir", e.root });
    if (e.arch) |a| try argv.appendSlice(gpa, &.{ "--arch", a });
    try argv.appendSlice(gpa, args);
    return Term.spawnEnv(gpa, argv.items, extra);
}

fn engineList(e: Env) std.mem.TokenIterator(u8, .scalar) {
    return std.mem.tokenizeScalar(u8, e.engines, ',');
}

test "an interactive rc reads typed lines [baseline]" {
    const e = try env(@src());
    var it = engineList(e);
    while (it.next()) |engine| {
        errdefer std.debug.print("engine {s}\n", .{engine});
        var t = try spawnTerm(e, engine, &.{ "rc", "-i" });
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
    var it = engineList(e);
    while (it.next()) |engine| {
        errdefer std.debug.print("engine {s}\n", .{engine});
        var tb: [16]u8 = undefined;
        // Long enough for rc to start and print ready first, under
        // -Djit-check too (about 3 s there).
        var t = try spawnTerm(e, engine, &.{ "--timeout", slowTimeout(&tb, 1_500), "--rc", "echo ready; read" });
        defer t.deinit();
        try t.expect("ready", slow(10_000));
        // Before the reader thread, the read held the machine until a
        // 500 ms grace period ran out, and h9 exited without freeing it.
        try std.testing.expectEqual(124, try t.wait(slow(2_500)));
        try t.expect("h9: timeout", slow(1_000));
    }
}

test "kill and ps work in an interactive rc (demo) [baseline]" {
    const e = try env(@src());
    var it = engineList(e);
    while (it.next()) |engine| {
        errdefer std.debug.print("engine {s}\n", .{engine});
        var t = try spawnTerm(e, engine, &.{ "--timeout", "60s", "rc", "-i" });
        defer t.deinit();
        try t.expect(prompt, slow(10_000));
        try t.send("sleep 1000 &" ++ enter);
        try t.expect(prompt, slow(10_000));
        // ps names each process by its program, so only sleep's line
        // matches. rc prompts again as soon as it has forked, before the
        // child has exec'd sleep, so wait for that first.
        try t.send("while(! ps | grep -s sle^ep) sleep 0.1; ps | grep -c sle^ep" ++ enter);
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
    var it = engineList(e);
    while (it.next()) |engine| {
        errdefer std.debug.print("engine {s}\n", .{engine});
        var t = try spawnTerm(e, engine, &.{ "--timeout", "60s", "rc", "-i" });
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
    var it = engineList(e);
    while (it.next()) |engine| {
        errdefer std.debug.print("engine {s}\n", .{engine});
        // rc traps interrupt and loops, so only the second Ctrl-C stops it.
        var t = try spawnTerm(e, engine, &.{ "--timeout", "60s", "--rc", "fn sigint {}; echo ready; while() sleep 1" });
        defer t.deinit();
        try t.expect("ready", slow(10_000));
        try t.send("\x03");
        try t.drain(100);
        try t.send("\x03");
        // 128 + SIGINT (design/epoch-0/exit-status.md).
        try std.testing.expectEqual(130, try t.wait(slow(5_000)));
    }
}

test "a program killed by interrupt exits 130, with nothing printed [exit-status]" {
    const e = try env(@src());
    var it = engineList(e);
    while (it.next()) |engine| {
        errdefer std.debug.print("engine {s}\n", .{engine});
        // rc execs sleep in place, so sleep is the first process.
        var t = try spawnTerm(e, engine, &.{ "--timeout", "60s", "--rc", "echo ready; sleep 1000" });
        defer t.deinit();
        try t.expect("ready", slow(10_000));
        try t.drain(slow(500));
        try t.send("\x03");
        try std.testing.expectEqual(130, try t.wait(slow(5_000)));
        try std.testing.expect(std.mem.indexOf(u8, t.out.items[t.mark..], "interrupt") == null);
        try std.testing.expect(std.mem.indexOf(u8, t.out.items[t.mark..], "h9:") == null);
    }
}

/// Posts NOTE to the first process once it's become sleep: rc execs sleep in
/// its place, keeping its pid, and a background block waits for that before
/// writing the note, since rc itself would catch it.
fn noteToSleep(buf: []u8, note: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf,
        \\p=$pid
        \\{{ while(! ~ `{{awk '{{print $1; exit}}' /proc/$p/status}} sleep) sleep 0; echo -n '{s}' >/proc/$p/note }} &
        \\exec sleep 1000
    , .{note});
}

test "a program killed by hangup exits 129 and prints the note [exit-status]" {
    const e = try env(@src());
    var buf: [512]u8 = undefined;
    const r = try run(e, &.{ "--timeout", "30s", "--rc", try noteToSleep(&buf, "hangup") });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(129, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "rc: hangup") != null);
}

test "a fault exits 139 and prints the note [exit-status]" {
    const e = try env(@src());
    // A program that writes through a nil pointer, built in the guest.
    const script =
        \\switch($objtype){
        \\case arm64; O=7
        \\case amd64; O=6
        \\case 386; O=8
        \\}
        \\cd /tmp
        \\echo '#include <u.h>' >f.c
        \\echo '#include <libc.h>' >>f.c
        \\echo 'void main(void){ *(int*)0 = 1; exits(nil); }' >>f.c
        \\$O^c f.c && $O^l -o f f.$O && exec ./f
    ;
    const r = try run(e, &.{ "--timeout", "60s", "--rc", script });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(139, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "rc: sys: trap: fault") != null);
}

test "--timeout exits 124 [exit-status]" {
    const e = try env(@src());
    // rc catches the hangup --timeout posts, so the machine is torn down
    // after the grace period: still a timeout, not "machine stopped".
    const r = try run(e, &.{ "--timeout", "200ms", "--rc", "fn sighup {}; while() sleep 1" });
    defer r.deinit();
    try std.testing.expectEqual(124, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "rc: h9: timeout") != null);
}

test "a note that isn't a signal exits 1 and prints it [exit-status]" {
    const e = try env(@src());
    var buf: [512]u8 = undefined;
    const r = try run(e, &.{ "--timeout", "30s", "--rc", try noteToSleep(&buf, "goodbye") });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(1, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "rc: goodbye") != null);
}

test "rawon puts the host terminal in raw mode until exit [baseline]" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // no termios to check
    const e = try env(@src());
    var it = engineList(e);
    while (it.next()) |engine| {
        errdefer std.debug.print("engine {s}\n", .{engine});
        var t = try spawnTerm(e, engine, &.{ "--timeout", "60s", "--rc", ">[3]/dev/consctl { echo rawon >[1=3]; echo ready; read >/dev/null }" });
        defer t.deinit();
        // consctl is on fd 3: rc execs read in place, and closing the last
        // consctl (as >/dev/null over it would) turns raw off.
        try t.expect("ready", slow(10_000));
        try std.testing.expect(t.raw() and !t.echo());
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
    var it = engineList(e);
    while (it.next()) |engine| {
        errdefer std.debug.print("engine {s}\n", .{engine});
        // The terminal is gone, so the handler leaves its mark in a file.
        var s: Scratch = undefined;
        try s.init();
        defer s.deinit();
        var t = try spawnTerm(e, engine, &.{ "--timeout", "60s", "--cwd", s.path, "--rc", "fn sighup { echo >hup }; " ++ hangup_wait });
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
    var it = engineList(e);
    while (it.next()) |engine| {
        errdefer std.debug.print("engine {s}\n", .{engine});
        var t = try spawnTerm(e, engine, &.{ "--timeout", "60s", "--rc", "fn sighup { echo got hangup }; " ++ hangup_wait });
        defer t.deinit();
        try t.expect("ready", slow(10_000));
        try t.drain(slow(500));
        t.signal(.TERM);
        try t.expect("got hangup", slow(5_000));
        _ = try t.wait(slow(5_000));
    }
}

test "a run torn down after SIGTERM exits 143 [exit-status]" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const e = try env(@src());
    var it = engineList(e);
    while (it.next()) |engine| {
        errdefer std.debug.print("engine {s}\n", .{engine});
        // rc ignores the hangup, so the machine is stopped after the grace
        // period, and the exit code names the host signal that started it.
        var t = try spawnTerm(e, engine, &.{ "--timeout", "60s", "--rc", "fn sighup {}; echo ready; while() sleep 1" });
        defer t.deinit();
        try t.expect("ready", slow(10_000));
        try t.drain(slow(500));
        t.signal(.TERM);
        try std.testing.expectEqual(143, try t.wait(slow(10_000)));
        try t.expect("h9: machine stopped", slow(1_000));
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
    // the child is still rc, which would catch it. The status names sleep's
    // pid, which differs between engines, so sed drops it.
    const script =
        \\rc -c 'sleep 1000 & wait $apid; echo $status | sed ''s/^sleep [0-9]+: /sleep: /''' &
        \\w=$apid
        \\p=()
        \\while(~ $#p 0) p=`{awk 'FNR==1 && $1=="sleep" {split(FILENAME, a, "/"); print a[3]}' /proc/*/status >[2]/dev/null}
        \\echo die >/proc/$p/note
        \\wait $w
    ;
    var tb: [16]u8 = undefined;
    const r = try run(e, &.{ "--timeout", slowTimeout(&tb, 20_000), "--rc", script });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.out, "die") != null);
    try std.testing.expectEqual(0, r.code);
}

test "--timeout posts hangup before tearing down [baseline]" {
    const e = try env(@src());
    // rc must define sighup before the timeout, which takes a few guest
    // process starts on a slow host (or under -Djit-check), and the
    // timeout must come before sleep's 10 s. Both scale with H9_TEST_SLOW,
    // so the sleep still outlasts the timeout.
    var tb: [16]u8 = undefined;
    var sb: [80]u8 = undefined;
    const script = std.fmt.bufPrint(&sb, "fn sighup {{ echo got hangup }}; sleep {d}; echo after", .{slow(10_000) / 1000}) catch unreachable;
    const r = try run(e, &.{ "--timeout", slowTimeout(&tb, 2_000), "--rc", script });
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
    // rc runs each & job in a note group of its own (rfork RFNOTEG), so the
    // background block isn't in rc's group and survives the hangup it posts
    // there, while the foreground sleep 1000 is in rc's group and dies of
    // it. The block waits for sleep to have exec'd first, since exec drops
    // notes queued before it. If the hangup didn't reach sleep, --timeout
    // would end the run, and the exit code says so.
    const r = try run(e, &.{ "--timeout", "20s", "--rc", "p=$pid; { while(! grep -s '^sleep 1000$' /proc/*/args) sleep 0; echo hangup >/proc/$p/notepg; sleep 1; echo survived } & fn sighup {}; sleep 1000; wait; echo done" });
    defer r.deinit();
    try std.testing.expectEqualStrings("survived\ndone\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "/proc/n has status, fd, ns and args [baseline]" {
    const e = try env(@src());
    // The times differ between runs, so only name, user and state; and
    // with awk last, cat isn't exec'd in place of rc. rc forks awk after
    // cat, so where processes run in parallel (KVM) cat can read rc's
    // status while rc is still running or in another call (Close,
    // Rfork) on the way to await: the block waits for Await first, and
    // --timeout ends the run if rc never gets there.
    const st = try run(e, &.{ "--timeout", "20s", "--rc", "p=$pid; { while(! ~ `{awk '{print $3}' /proc/$p/status} Await) sleep 0; cat /proc/$p/status } | awk '{print $1, ($2 == ENVIRON[\"user\"]), $3}'" });
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

test "seg attaches a shared segment and reads zero [segattach]" {
    const e = try env(@src());
    const r = try run(e, &.{ "seg", "-r", "shared", "0x1000", "0" });
    defer r.deinit();
    try std.testing.expectEqualStrings("0x0\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "seg attaches a memory segment and writes a word [segattach]" {
    const e = try env(@src());
    const r = try run(e, &.{ "seg", "-L", "-w", "memory", "0x1000", "8", "0x12345678" });
    defer r.deinit();
    try std.testing.expectEqualStrings("", r.err);
    try std.testing.expectEqual(0, r.code);
}

test "an unknown class is a bad arg [segattach]" {
    const e = try env(@src());
    const r = try run(e, &.{ "seg", "-r", "tmu", "0x1000", "0" });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.err, "segattach: bad arg in system call") != null);
    try std.testing.expectEqual(1, r.code);
}

test "--memory caps segattach [segattach]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--memory", "8m", "seg", "-r", "memory", "0x2000000", "0" });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.err, "virtual memory allocation failed") != null);
    try std.testing.expectEqual(1, r.code);
}

// rendezvous and semaphores (design/epoch-0/semaphores.md). The programs are
// tests/fixtures/sema/sema.c, one per argument, built inside the guest
// with the architecture's compiler and loader (7c and 7l on arm64) into
// a scratch directory given with --sandbox.

/// Builds sema.c into `s` as `sema`, on each engine.
fn buildSema(e: Env, s: *Scratch) !void {
    try buildC(e, s, "sema", @embedFile("fixtures/sema/sema.c"));
}

/// Writes `src` into `s` as `name`.c and builds it there as `name`, with
/// the compiler for the case's architecture.
fn buildC(e: Env, s: *Scratch, comptime name: []const u8, src: []const u8) !void {
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = name ++ ".c", .data = src });
    const c: u8 = if (e.arch) |a| (if (std.mem.eql(u8, a, "386")) '8' else if (std.mem.eql(u8, a, "amd64")) '6' else '7') else '7';
    var buf: [128]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&buf, "{c}c {s}.c && {c}l -o {s} {s}.{c}", .{ c, name, c, name, name, c });
    const r = try run(e, &.{ "--sandbox", s.path, "--rc", cmd });
    defer r.deinit();
    errdefer std.debug.print("{s}: {s}{s}", .{ cmd, r.out, r.err });
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

test "rendezvous swaps values between two processes [semaphores]" {
    const e = try env(@src());
    try expectSema(e, &.{}, "./sema swap", "child got 11\nparent got 22\n");
}

test "contended qlock parks and wakes through rendezvous [semaphores]" {
    const e = try env(@src());
    try expectSema(e, &.{}, "./sema qlock", "2000\n");
}

test "semacquire waits for semrelease across RFMEM processes [semaphores]" {
    const e = try env(@src());
    try expectSema(e, &.{}, "./sema wait", "semacquire 1 waited\n");
}

test "semaphores keep a shared counter exact under contention [semaphores]" {
    const e = try env(@src());
    try expectSema(e, &.{}, "./sema count", "2000 1\n");
    try expectSema(e, &.{ "--cpus", "1" }, "./sema count", "2000 1\n");
}

test "semacquire without block and tsemacquire with 0 ms don't wait [semaphores]" {
    const e = try env(@src());
    try expectSema(e, &.{}, "./sema nowait", "0 0 1 1 0 at once\n");
}

test "tsemacquire times out, or returns early on semrelease [semaphores]" {
    const e = try env(@src());
    try expectSema(e, &.{}, "./sema timeout", "timeout 0 in time\nrelease 1 early\n");
}

test "a note interrupts rendezvous and semacquire, and the handler runs [semaphores]" {
    const e = try env(@src());
    try expectSema(e, &.{}, "./sema interrupt", "rendezvous ~0, handled 1\nsemacquire -1 'interrupted', handled 2\n");
}

test "bad semaphore addresses and values fail as on 9front [semaphores]" {
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

test "ps shows processes blocked in Rendezvous and Semacquire [semaphores]" {
    const e = try env(@src());
    // ps cuts the state to 8 characters. The parent waits for both.
    try expectSema(e, &.{},
        \\./sema block & sleep 1; ps | awk '$7 == "sema" { print $6 }' | sort; kill sema | rc; wait
    , "Await\nRendezvo\nSemacqui\n");
}

test "--timeout stops processes blocked in rendezvous and semacquire [semaphores]" {
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
    try std.testing.expectEqual(124, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "h9: timeout") != null);
    // Hangup or the teardown 2 s later; one run per engine.
    try std.testing.expect(took < 10_000 * @as(i64, @intCast(std.mem.count(u8, e.engines, ",") + 1)));
}

// The network policy (design/epoch-0/net-policy.md). The cases listen on
// 127.0.0.1 themselves, and the guest writes /net ctl files from rc, so
// they need no client program the root tree doesn't have.

/// A TCP listener on an ephemeral port of 127.0.0.1.
/// Makes a symbolic link, or skips the case on a Windows host that refuses
/// to: only an administrator, or Developer Mode, may make one there.
fn symLinkOrSkip(dir: std.Io.Dir, io: std.Io, target: []const u8, name: []const u8, flags: std.Io.Dir.SymLinkFlags) !void {
    dir.symLink(io, target, name, flags) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return if (builtin.os.tag == .windows) error.SkipZigTest else err,
        else => return err,
    };
}

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
    const s = try deadline.accept(srv, io);
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

test "the default profile refuses announce [net-policy]" {
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

test "--net=enable allows a server [net-policy]" {
    const e = try env(@src());
    const io = std.testing.io;
    var probe = try listenLocal();
    const port = probe.socket.address.getPort();
    probe.deinit(io);
    var addr_buf: [64]u8 = undefined;
    const addr = try std.fmt.bufPrint(&addr_buf, "tcp!127.0.0.1!{d}", .{port});
    var it = std.mem.tokenizeScalar(u8, e.engines, ',');
    while (it.next()) |engine| {
        // The root's binaries are for -Darch's architecture, if any.
        const argv: []const []const u8 = if (e.arch) |a|
            &.{ e.h9, "--engine", engine, "--arch", a, "--dir", e.root, "--net=enable", "--timeout", "20s", "aux/listen1", "-1", "-t", addr, "/bin/cat" }
        else
            &.{ e.h9, "--engine", engine, "--dir", e.root, "--net=enable", "--timeout", "20s", "aux/listen1", "-1", "-t", addr, "/bin/cat" };
        var child = try std.process.spawn(io, .{
            .argv = argv,
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
        try deadline.waitReadable(c.socket.handle, deadline.limit_ms);
        var rbuf: [64]u8 = undefined;
        var r = c.reader(io, &rbuf);
        var got: [64]u8 = undefined;
        const n = try r.interface.readSliceShort(got[0..5]);
        try std.testing.expectEqualStrings("ping\n", got[0..n]);
    }
}

test "outbound allows connect [net-policy]" {
    const e = try env(@src());
    var srv = try listenLocal();
    defer srv.deinit(std.testing.io);
    var addr_buf: [64]u8 = undefined;
    var cmd_buf: [256]u8 = undefined;
    const addr = try std.fmt.bufPrint(&addr_buf, "127.0.0.1!{d}", .{srv.socket.address.getPort()});
    var it = std.mem.tokenizeScalar(u8, e.engines, ',');
    while (it.next()) |engine| {
        const r = try runOn(e, engine, &.{ "--rc", try rcDial(&cmd_buf, addr, "hello") }, null);
        defer r.deinit();
        try std.testing.expectEqualStrings("", r.err);
        try std.testing.expectEqual(0, r.code);
        var buf: [64]u8 = undefined;
        try std.testing.expectEqualStrings("hello", try acceptLine(&srv, &buf));
    }
}

test "outbound refuses link-local without patterns [net-policy]" {
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

test "a pattern allows link-local [net-policy]" {
    const e = try env(@src());
    var cmd_buf: [256]u8 = undefined;
    // The policy refuses the connect at once, so a short --timeout is
    // enough to tell. Past the policy, nothing usually answers there and
    // the host's connect waits until --timeout ends the run (on a cloud VM,
    // the metadata service may answer instead).
    var to_buf: [16]u8 = undefined;
    const r = try run(e, &.{ "--net-allow", "tcp!169.254.0.0/16!*", "--timeout", slowTimeout(&to_buf, 2000), "--rc", try rcDial(&cmd_buf, "169.254.169.254!80", "x") });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.err, "permission denied") == null);
}

test "--net-allow refuses a connect outside it, and the host sees nothing [net-policy]" {
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

test "--net-allow allows a matching CIDR and port [net-policy]" {
    const e = try env(@src());
    var srv = try listenLocal();
    defer srv.deinit(std.testing.io);
    const port = srv.socket.address.getPort();
    var addr_buf: [64]u8 = undefined;
    var pat_buf: [64]u8 = undefined;
    var cmd_buf: [256]u8 = undefined;
    const addr = try std.fmt.bufPrint(&addr_buf, "127.0.0.1!{d}", .{port});
    const pat = try std.fmt.bufPrint(&pat_buf, "tcp!127.0.0.0/8!{d}-{d}", .{ port, port });
    var it = std.mem.tokenizeScalar(u8, e.engines, ',');
    while (it.next()) |engine| {
        const r = try runOn(e, engine, &.{ "--net-allow", pat, "--rc", try rcDial(&cmd_buf, addr, "cidr") }, null);
        defer r.deinit();
        try std.testing.expectEqualStrings("", r.err);
        var buf: [64]u8 = undefined;
        try std.testing.expectEqualStrings("cidr", try acceptLine(&srv, &buf));
    }
}

test "a name pattern allows a connect through cs [net-policy]" {
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
    var it = std.mem.tokenizeScalar(u8, e.engines, ',');
    while (it.next()) |engine| {
        const r = try runOn(e, engine, &.{ "--net-allow", pat, "--rc", cmd }, null);
        defer r.deinit();
        try std.testing.expectEqualStrings("", r.err);
        var buf: [64]u8 = undefined;
        try std.testing.expectEqualStrings("named", try acceptLine(&srv, &buf));
    }
}

test "a name outside --net-allow isn't resolved [net-policy]" {
    const e = try env(@src());
    // localhost resolves on every host, so the refusal comes before the
    // host's resolver.
    const r = try run(e, &.{ "--net-allow", "tcp!127.0.0.1!80", "ndb/csquery", "/net/cs", "tcp!localhost!80" });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.err, "translating tcp!localhost!80: no translation for host found") != null);
}

test "a UDP announce is refused under outbound [net-policy]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--rc", "<>[3] /net/udp/clone { echo 'announce 127.0.0.1!39517' >[1=3] }" });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.err, "write error: permission denied") != null);
    try std.testing.expect(r.code != 0);
}

test "--net-allow with --net=disable is a usage error [net-policy]" {
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

test "--print shows net-allow patterns and caveats [net-policy]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--print", "--net-allow", "tcp!*.example.com!443", "--net-allow", "udp!10.0.0.53!53", "echo" });
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "net.allow net.outbound") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "net=outbound") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "# net-allow:\n#   tcp!*.example.com!443\n#   udp!10.0.0.53!53\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "\nnetallow tcp!*.example.com!443\nnetallow udp!10.0.0.53!53\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "name patterns trust the host's resolver") != null);
    const d = try run(e, &.{ "--print", "echo" });
    defer d.deinit();
    try std.testing.expect(std.mem.indexOf(u8, d.out, "except link-local") != null);
}

test "--net=outbound runs [net-policy]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--net=outbound", "echo", "ok" });
    defer r.deinit();
    try std.testing.expectEqualStrings("ok\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

// devsrv, /srv, and mount (design/epoch-0/devsrv.md). Mount points are made
// in the machine's private /tmp, since the root tree's /n and /mnt are
// mostly mntgen's on 9front and may lack the names a case wants.

test "ramfs posts to /srv and another process mounts it [devsrv]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--timeout", "20s", "--rc", "ramfs -S r && mkdir /tmp/r && mount -c /srv/r /tmp/r && echo hi >/tmp/r/x && cat /tmp/r/x" });
    defer r.deinit();
    try std.testing.expectEqualStrings("hi\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "ramfs -S tmp, mount and ls (demo) [devsrv]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--timeout", "20s", "--rc", "ramfs -S tmp && mkdir /tmp/n && mount -c /srv/tmp /tmp/n && touch /tmp/n/a && ls /tmp/n" });
    defer r.deinit();
    try std.testing.expectEqualStrings("/tmp/n/a\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "a posted pipe is a named pipe [devsrv]" {
    const e = try env(@src());
    // srv(3)'s example in rc: the right side posts its fd 0, the read end
    // of the pipe, and exits; the data waits in the pipe until it's read
    // through /srv.
    const r = try run(e, &.{ "--timeout", "20s", "--rc", "echo hello | { echo 0 >/srv/namedpipe }; cat /srv/namedpipe" });
    defer r.deinit();
    try std.testing.expectEqualStrings("hello\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "mount without auth works through fauth [devsrv]" {
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

test "unmount takes a mount out of the namespace [devsrv]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--timeout", "20s", "--rc", "ramfs -S r && mkdir /tmp/r && mount -c /srv/r /tmp/r && touch /tmp/r/x && ls /tmp/r && unmount /tmp/r && ls /tmp/r && echo done" });
    defer r.deinit();
    try std.testing.expectEqualStrings("/tmp/r/x\ndone\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "srvfs reexports a directory through /srv [devsrv]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--timeout", "20s", "--rc", "mkdir /tmp/d /tmp/m && echo exported >/tmp/d/f && srvfs sfs /tmp/d && mount -c /srv/sfs /tmp/m && cat /tmp/m/f" });
    defer r.deinit();
    try std.testing.expectEqualStrings("exported\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "exportfs -S serves a posted channel [devsrv]" {
    const e = try env(@src());
    // exportfs reads and writes 9P on fds 0 and 1, one end of a pipe; the
    // other end is posted as /srv/e, and exportfs passes it to /srv/r.
    // Each attach mounts /srv/r on /mnt/exportfs/<n>, mntexport's on
    // 9front, so /mnt/exportfs/0 is made in /tmp if the root lacks it.
    // /srv/e exists once echo creates it, before its write posts the fd,
    // and an open in between fails, so the mount is retried.
    const script =
        \\mkdir -p /tmp/m/exportfs/0 && bind -a /tmp/m /mnt && bind -a /tmp/m/exportfs /mnt/exportfs || exit mtpt
        \\ramfs -S r && mkdir /tmp/a /tmp/b && mount -c /srv/r /tmp/a && echo through >/tmp/a/x || exit setup
        \\exportfs -S /srv/r <[0=1] | { echo 0 >/srv/e } &
        \\n=0
        \\while(! mount -c /srv/e /tmp/b >[2]/dev/null && test $n -lt 100){ sleep 0.1; n=`{echo $n+1 | hoc} }
        \\cat /tmp/b/x
    ;
    const r = try run(e, &.{ "--timeout", "20s", "--rc", script });
    defer r.deinit();
    try std.testing.expectEqualStrings("through\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "/proc/n/ns prints a mount of /srv/x as /srv/x [devsrv]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--timeout", "20s", "--rc", "ramfs -S x && mkdir /tmp/x && mount -c /srv/x /tmp/x && grep /tmp/x /proc/$pid/ns" });
    defer r.deinit();
    try std.testing.expectEqualStrings("mount -c /srv/x /tmp/x\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "a server's /srv entry goes when it exits [devsrv]" {
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

test "a second create of a /srv name fails [devsrv]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--timeout", "20s", "--rc", "ramfs -S r && ! ramfs -S r && echo refused" });
    defer r.deinit();
    try std.testing.expectEqualStrings("refused\n", r.out);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "exists") != null);
    try std.testing.expectEqual(0, r.code);
}

test "clone makes a private board, and closing it clears it [devsrv]" {
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

test "factotum starts and serves /mnt/factotum [devsrv]" {
    const e = try env(@src());
    // -n skips secstore. The mount point comes from /tmp if the root
    // tree's /mnt lacks it, as without 9front's mntgen.
    const r = try run(e, &.{ "--timeout", "20s", "--rc", "mkdir -p /tmp/m/factotum && bind -a /tmp/m /mnt && auth/factotum -n >[2]/dev/null && ls /mnt/factotum" });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.out, "/mnt/factotum/ctl\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "/mnt/factotum/rpc\n") != null);
    try std.testing.expectEqual(0, r.code);
}

test "plumber starts and serves /mnt/plumb [devsrv]" {
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

// Go compatibility (design/epoch-0/go-compat.md). The Go cases run the
// plan9/amd64 programs from tests/fixtures/go, which `zig build
// go-fixtures` builds into H9_TEST_GO, on the sud engine where the
// build runs the cases on it (H9_TEST_GO_ENGINE), else on the emulator.
// They don't need the root tree: each gets a scratch root holding only
// the directories the namespace binds onto, and the fixtures at
// /mnt/term/cwd. Without Go, or either engine, H9_TEST_GO is unset and
// they skip.

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

/// The engine the Go cases run on: the sud engine when the build
/// says it's in the list (Linux x86_64, design/epoch-0/native-backend.md), else
/// the emulator.
fn goEngine() []const u8 {
    const v = getenv(3, "H9_TEST_GO_ENGINE") orelse return "hcpu";
    return if (std.mem.eql(u8, v, "sud")) "sud" else "hcpu";
}

/// The argv for running fixture `prog` with h9 flags `flags` and arguments `args`.
fn goArgv(g: *const GoEnv, argv: *std.ArrayList([]const u8), flags: []const []const u8, prog: []const u8, args: []const []const u8) !void {
    try argv.appendSlice(gpa, &.{ g.h9, "--engine", goEngine(), "--arch", "amd64", "--dir", g.root.path, "--cwd", g.dir, "--timeout", "60s" });
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

test "a Go hello world prints and exits 0 [go-compat]" {
    var g: GoEnv = undefined;
    try goEnv(@src(), &g);
    defer g.deinit();
    const r = try runGo(&g, &.{}, "hello", &.{});
    defer r.deinit();
    try std.testing.expectEqualStrings("hello from go\n", r.out);
    try std.testing.expectEqualStrings("", r.err);
    try expectGoOk(r);
}

test "goroutines sleep 100 ms and the elapsed time is right [go-compat]" {
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

test "time.Now has sub-second resolution and matches the host [go-compat]" {
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

test "runtime.NumCPU follows --cpus [go-compat]" {
    var g: GoEnv = undefined;
    try goEnv(@src(), &g);
    defer g.deinit();
    const r = try runGo(&g, &.{ "--cpus", "2" }, "numcpu", &.{});
    defer r.deinit();
    try expectGoOk(r);
    try std.testing.expectEqualStrings("2 2\n", r.out);
}

test "os.Getpid and os.Getppid match /proc [go-compat]" {
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

test "CPU-bound goroutines run on several processes [go-compat]" {
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

test "os/exec runs a child and gets its exit status [go-compat]" {
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

test "a nil dereference becomes a panic that recover catches [go-compat]" {
    var g: GoEnv = undefined;
    try goEnv(@src(), &g);
    defer g.deinit();
    const r = try runGo(&g, &.{}, "nilpanic", &.{});
    defer r.deinit();
    try expectGoOk(r);
    try std.testing.expectEqualStrings("recovered: runtime error: invalid memory address or nil pointer dereference\n", r.out);
}

test "os/signal receives interrupt on Ctrl-C [go-compat]" {
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

test "os.Exit(3) exits with status 3 [go-compat]" {
    var g: GoEnv = undefined;
    try goEnv(@src(), &g);
    defer g.deinit();
    const r = try runGo(&g, &.{}, "exit", &.{"3"});
    defer r.deinit();
    try std.testing.expectEqualStrings("exiting 3\n", r.out);
    try std.testing.expectEqualStrings("", r.err);
    try std.testing.expectEqual(3, r.code);
}

test "a numeric exits string becomes the exit code [go-compat]" {
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

test "net/http fetches from a listener the test opens [go-compat]" {
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
            const c = deadline.accept(s, io) catch return;
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

test "syscall.Gettimeofday has microsecond resolution [go-compat]" {
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

test "/dev/bintime has four words and a monotonic clock [go-compat]" {
    const e = try env(@src());
    // The clock differs from run to run, so each engine is checked on its
    // own rather than compared with the others.
    var it = engineList(e);
    while (it.next()) |engine| {
        errdefer std.debug.print("engine {s}\n", .{engine});
        try checkBintime(e, engine);
    }
}

fn checkBintime(e: Env, engine: []const u8) !void {
    const r = try runOn(e, engine, &.{ "--rc", "dd -if /dev/bintime -bs 32 -count 1 >[2]/dev/null | xd -1x; sleep 1; dd -if /dev/bintime -bs 32 -count 1 >[2]/dev/null | xd -1x" }, null);
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

// 9P roots (design/epoch-0/ninep-roots.md). The server is a second h9 serving
// the test root tree read-only with exportfs behind aux/listen1 -t, so no
// host 9P server is needed. Cases compare a run over the 9P root with the
// same run over the host tree, whose namespace is otherwise the same.

/// A second h9 serving the root tree on a loopback port, on the first
/// engine, for the life of a case.
const RootServer = struct {
    child: std.process.Child,
    port: u16,
    dial_buf: [64]u8 = undefined,
    url_buf: [64]u8 = undefined,

    fn start(s: *RootServer, e: Env) !void {
        return s.startTree(e, null);
    }

    /// Serves the host tree `tree` instead, from a machine that still runs
    /// from the test root.
    fn startTree(s: *RootServer, e: Env, tree: ?[]const u8) !void {
        return s.startServing(e, tree, false);
    }

    /// startTree, with the export writable when `writable`.
    fn startServing(s: *RootServer, e: Env, tree: ?[]const u8, writable: bool) !void {
        const io = std.testing.io;
        var probe = try listenLocal();
        s.port = probe.socket.address.getPort();
        probe.deinit(io);
        var listen_buf: [64]u8 = undefined;
        const listen = try std.fmt.bufPrint(&listen_buf, "tcp!127.0.0.1!{d}", .{s.port});
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        // The web host can't listen, so on it a native h9 serves
        // (H9_TEST_SERVER, from -Dweb), or the case skips.
        if (onWeb()) {
            const server = getenv(6, "H9_TEST_SERVER") orelse return error.SkipZigTest;
            try argv.appendSlice(gpa, &.{ server, "--engine", "auto", "--dir", e.root, "--net=enable" });
        } else try argv.appendSlice(gpa, &.{ e.h9, "--engine", firstEngine(e), "--dir", e.root, "--net=enable" });
        if (e.arch) |a| try argv.appendSlice(gpa, &.{ "--arch", a });
        // The tree is the server's cwd, so it's /mnt/term/cwd wherever
        // it is on the host.
        var served: []const u8 = "/";
        if (tree) |t| {
            try argv.appendSlice(gpa, &.{ "--cwd", t });
            served = "/mnt/term/cwd";
        }
        try argv.appendSlice(gpa, &.{ "aux/listen1", "-t", listen, "/bin/exportfs" });
        if (!writable) try argv.append(gpa, "-R");
        try argv.appendSlice(gpa, &.{ "-r", served });
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

    /// The server as a --url (design/epoch-0/mounts.md).
    fn url(s: *RootServer) []const u8 {
        return std.fmt.bufPrint(&s.url_buf, "tcp://127.0.0.1:{d}", .{s.port}) catch unreachable;
    }

    /// Kills the server outright. Child.kill's SIGTERM is a hangup to h9,
    /// which listen1 doesn't end on, so h9 would wait out its 2.5 s grace
    /// period on every case that serves a root.
    fn stop(s: *RootServer) void {
        if (builtin.os.tag != .windows) if (s.child.id) |pid| std.posix.kill(pid, .KILL) catch {};
        s.child.kill(std.testing.io);
    }
};

/// `url` with `:/:OPTS`: a --url on `/` with options.
fn urlOpts(buf: []u8, url: []const u8, opts: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}:/:{s}", .{ url, opts }) catch unreachable;
}

/// The flag that mounts `root` on `/` (design/epoch-0/mounts.md): `--dir` for
/// a host path (starting with `/` or `.`), and `--url` for anything else.
fn rootFlag(root: []const u8) [2][]const u8 {
    const u = dialUrl(&root_url_buf, root);
    const path = u.len > 0 and (u[0] == '/' or u[0] == '.' or (builtin.os.tag == .windows and u.len > 1 and u[1] == ':'));
    return .{ if (path) "--dir" else "--url", u };
}

var root_url_buf: [std.Io.Dir.max_path_bytes + 16]u8 = undefined;

/// A dial string (`tcp!host!port`, `unix!path`) as the URL --url takes,
/// and anything else as it is.
fn dialUrl(buf: []u8, addr: []const u8) []const u8 {
    if (std.mem.startsWith(u8, addr, "tcp!")) {
        var it = std.mem.splitScalar(u8, addr[4..], '!');
        const host = it.next().?;
        const port = it.next() orelse "564";
        return std.fmt.bufPrint(buf, "tcp://{s}:{s}", .{ host, port }) catch unreachable;
    }
    if (std.mem.startsWith(u8, addr, "unix!")) return std.fmt.bufPrint(buf, "unix://{s}", .{addr[5..]}) catch unreachable;
    return addr;
}

/// Whether `args` mounts something on `/` itself, so the harness leaves
/// out its own `--dir` root.
fn givesRoot(args: []const []const u8) bool {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        // A plan has its own mounts (design/plan-format.md), and a --dir
        // the plan doesn't have would widen it.
        if (std.mem.eql(u8, a, "--builtin") or std.mem.eql(u8, a, "--plan") or std.mem.startsWith(u8, a, "--plan=")) {
            return true;
        } else if (std.mem.startsWith(u8, a, "--builtin=")) {
            if (onRoot(a["--builtin=".len..], false)) return true;
        } else inline for (.{ "--dir", "--url", "--archive" }) |f| {
            if (std.mem.eql(u8, a, f) and i + 1 < args.len) {
                i += 1;
                if (onRoot(args[i], true)) return true;
            } else if (std.mem.startsWith(u8, a, f ++ "=")) {
                if (onRoot(a[f.len + 1 ..], true)) return true;
            }
        }
    }
    return false;
}

/// Whether a mount flag's value has `/` as its DST.
fn onRoot(v: []const u8, has_src: bool) bool {
    if (std.mem.indexOf(u8, v, "dst=")) |d| {
        const rest = v[d + 4 ..];
        const end = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
        return std.mem.eql(u8, rest[0..end], "/");
    }
    var part = v;
    if (has_src) {
        const skip = std.mem.indexOf(u8, v, "://");
        var i = v.len;
        part = "";
        while (i > 0) {
            i -= 1;
            if (v[i] != ':' or i + 1 >= v.len or (v[i + 1] != '/' and v[i + 1] != '#')) continue;
            if (skip != null and i == skip.?) continue;
            if (i == 1 and std.ascii.isAlphabetic(v[0])) continue;
            part = v[i + 1 ..];
            break;
        }
    }
    const dst = part[0 .. std.mem.indexOfScalar(u8, part, ':') orelse part.len];
    return dst.len == 0 or std.mem.eql(u8, dst, "/");
}

/// Runs `args` over the 9P root `root` and over the host tree, and checks
/// that both succeed with the same output.
fn expectSameAsHost(e: Env, root: []const u8, args: []const []const u8) !void {
    return expectSameAsHostWith(e, root, "", args);
}

/// expectSameAsHost, with `opts` (the root's options, such as header=)
/// on the 9P root's --url.
fn expectSameAsHostWith(e: Env, root: []const u8, opts: []const u8, args: []const []const u8) !void {
    return expectSameAsHostFlags(e, root, opts, &.{}, args);
}

/// expectSameAsHostWith, with `root_args` (flags such as --cred) on the
/// run over the 9P root.
fn expectSameAsHostFlags(e: Env, root: []const u8, opts: []const u8, root_args: []const []const u8, args: []const []const u8) !void {
    const host = try run(e, args);
    defer host.deinit();
    var with_root: std.ArrayList([]const u8) = .empty;
    defer with_root.deinit(gpa);
    var ub: [512]u8 = undefined;
    try with_root.appendSlice(gpa, &rootFlag(if (opts.len > 0) urlOpts(&ub, root, opts) else root));
    try with_root.appendSlice(gpa, root_args);
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
    url_buf: [64]u8 = undefined,

    fn start(f: *FakeAttach, refusal: []const u8) !void {
        f.* = .{ .srv = try listenLocal(), .refusal = refusal };
        f.thread = try std.Thread.spawn(.{}, serve, .{f});
    }

    fn dial(f: *FakeAttach) []const u8 {
        return std.fmt.bufPrint(&f.dial_buf, "tcp!127.0.0.1!{d}", .{f.srv.socket.address.getPort()}) catch unreachable;
    }

    /// The server as a --url (design/epoch-0/mounts.md).
    fn url(f: *FakeAttach) []const u8 {
        return std.fmt.bufPrint(&f.url_buf, "tcp://127.0.0.1:{d}", .{f.srv.socket.address.getPort()}) catch unreachable;
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
        const s = deadline.accept(&f.srv, io) catch return;
        defer s.close(io);
        var rbuf: [8192]u8 = undefined;
        var wbuf: [256]u8 = undefined;
        var r = s.reader(io, &rbuf);
        var w = s.writer(io, &wbuf);
        while (true) {
            if (r.interface.bufferedLen() == 0)
                deadline.waitReadable(s.socket.handle, deadline.limit_ms) catch return;
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

test "a TCP 9P root runs /bin/ls [ninep-roots]" {
    const e = try env(@src());
    var srv: RootServer = undefined;
    try srv.start(e);
    defer srv.stop();
    try expectSameAsHost(e, srv.url(), &.{ "/bin/ls", "/", "/bin/ls" });
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
            const c = deadline.accept(&u.srv, io) catch return;
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

test "a unix socket 9P root runs /bin/ls [ninep-roots]" {
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
    const url = try std.fmt.allocPrint(gpa, "unix://{s}", .{sock});
    defer gpa.free(url);
    try expectSameAsHost(e, url, &.{ "/bin/ls", "/", "/bin/ls" });
}

test "rc pipelines and exec run from a 9P root [ninep-roots]" {
    const e = try env(@src());
    var srv: RootServer = undefined;
    try srv.start(e);
    defer srv.stop();
    try expectSameAsHost(e, srv.url(), &.{ "--rc", "ls /bin | grep -c '/cat$'; echo a b c | wc -w; exec /bin/echo done" });
}

test "the host cwd is bound over a 9P root [ninep-roots]" {
    const e = try env(@src());
    var srv: RootServer = undefined;
    try srv.start(e);
    defer srv.stop();
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f", .data = "from the host\n" });
    const r = try run(e, &.{ "--url", srv.url(), "--cwd", s.path, "--rc", "cat f; pwd; echo new > g" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("from the host\n/mnt/term/cwd\n", r.out);
    try std.testing.expect(s.exists("g"));
}

test "a 9P root works under --net=disable [ninep-roots]" {
    const e = try env(@src());
    var srv: RootServer = undefined;
    try srv.start(e);
    defer srv.stop();
    try expectSameAsHost(e, srv.url(), &.{ "--net=disable", "/bin/ls", "/bin/cat" });
    // #I is still masked from the guest.
    const r = try run(e, &.{ "--url", srv.url(), "--net=disable", "--rc", "ls '#I'" });
    defer r.deinit();
    try std.testing.expect(r.code != 0);
}

test "spec= is sent as the attach name [mounts]" {
    const e = try env(@src());
    var f: FakeAttach = undefined;
    try f.start("no such tree");
    var ub: [128]u8 = undefined;
    // One engine: the server takes one connection.
    const r = runOn(e, firstEngine(e), &.{ "--url", urlOpts(&ub, f.url(), "spec=other"), "/bin/echo" }, null) catch |err| {
        f.finish();
        return err;
    };
    defer r.deinit();
    f.finish();
    try std.testing.expect(f.attached);
    try std.testing.expectEqualStrings("other", f.aname_());
    try std.testing.expectEqual(125, r.code);
}

test "--url tcp:// and unix:// mount 9P, with spec from the path or spec= [mounts]" {
    const e = try env(@src());
    var srv: RootServer = undefined;
    try srv.start(e);
    defer srv.stop();
    var tb: [128]u8 = undefined;
    const t = try run(e, &.{ "--url", try std.fmt.bufPrint(&tb, "{s}:/n/fs", .{srv.url()}), "--rc", "test -e /n/fs/lib/namespace && echo tcp" });
    defer t.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{t.err});
    try std.testing.expectEqualStrings("tcp\n", t.out);
    if (std.Io.net.has_unix_sockets and builtin.os.tag != .windows) {
        var s: Scratch = undefined;
        try s.init();
        defer s.deinit();
        const sock = try std.fs.path.join(gpa, &.{ s.path, "fs.sock" });
        defer gpa.free(sock);
        var relay: UnixRelay = undefined;
        try relay.start(sock, srv.port);
        const u = try std.fmt.allocPrint(gpa, "unix://{s}:/n/fs", .{sock});
        defer gpa.free(u);
        const r = try runOn(e, firstEngine(e), &.{ "--url", u, "--rc", "test -e /n/fs/lib/namespace && echo unix" }, null);
        defer r.deinit();
        errdefer std.debug.print("stderr: {s}\n", .{r.err});
        try std.testing.expectEqualStrings("unix\n", r.out);
    }
    // A tcp:// URL's path is the attach name, and spec= wins over it.
    for ([_][2][]const u8{ .{ "/main:/", "main" }, .{ "/main:/:spec=other", "other" } }) |c| {
        var f: FakeAttach = undefined;
        try f.start("no such tree");
        var ub: [128]u8 = undefined;
        const r = runOn(e, firstEngine(e), &.{ "--url", try std.fmt.bufPrint(&ub, "{s}{s}", .{ f.url(), c[0] }), "/bin/echo" }, null) catch |err| {
            f.finish();
            return err;
        };
        defer r.deinit();
        f.finish();
        try std.testing.expect(f.attached);
        try std.testing.expectEqualStrings(c[1], f.aname_());
    }
}

// Static dotfs trees (design/epoch-0/mounts.md, "Static trees"): StaticHttp serves
// a host directory over plain HTTP, answering a WebSocket upgrade with 404,
// as a static file host does, and logs each request.

/// A plain HTTP server over a host directory, for static-tree cases. It
/// serves `/t/PATH` from `dir/PATH`, honours one-part Range requests, and
/// refuses WebSocket upgrades with a 404.
const StaticHttp = struct {
    srv: std.Io.net.Server,
    port: u16,
    dir: []const u8,
    thread: std.Thread,
    stopping: std.atomic.Value(bool) = .init(false),
    mu: std.Io.Mutex = .init,
    /// One line per request: `GET PATH`, `RANGE PATH`, or `UPGRADE PATH`.
    log: std.ArrayList(u8) = .empty,
    url_buf: [64]u8 = undefined,

    fn start(h: *StaticHttp, dir: []const u8) !void {
        h.* = .{ .srv = try listenLocal(), .port = 0, .dir = dir, .thread = undefined };
        h.port = h.srv.socket.address.getPort();
        h.thread = try std.Thread.spawn(.{}, loop, .{h});
    }

    fn url(h: *StaticHttp) []const u8 {
        return std.fmt.bufPrint(&h.url_buf, "http://127.0.0.1:{d}/t", .{h.port}) catch unreachable;
    }

    fn stop(h: *StaticHttp) void {
        const io = std.testing.io;
        h.stopping.store(true, .release);
        if (std.Io.net.IpAddress.parse("127.0.0.1", h.port)) |ip| {
            if (ip.connect(io, .{ .mode = .stream })) |c| c.close(io) else |_| {}
        } else |_| {}
        h.thread.join();
        h.srv.deinit(io);
        h.log.deinit(gpa);
    }

    /// How many log lines are exactly `line`.
    fn count(h: *StaticHttp, line: []const u8) usize {
        const io = std.testing.io;
        h.mu.lockUncancelable(io);
        defer h.mu.unlock(io);
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, h.log.items, '\n');
        while (it.next()) |l| if (std.mem.eql(u8, l, line)) {
            n += 1;
        };
        return n;
    }

    fn reset(h: *StaticHttp) void {
        const io = std.testing.io;
        h.mu.lockUncancelable(io);
        defer h.mu.unlock(io);
        h.log.clearRetainingCapacity();
    }

    fn note(h: *StaticHttp, kind: []const u8, path: []const u8) void {
        const io = std.testing.io;
        h.mu.lockUncancelable(io);
        defer h.mu.unlock(io);
        h.log.print(gpa, "{s} {s}\n", .{ kind, path }) catch {};
    }

    fn loop(h: *StaticHttp) void {
        const io = std.testing.io;
        while (true) {
            const c = deadline.accept(&h.srv, io) catch return;
            if (h.stopping.load(.acquire)) {
                c.close(io);
                return;
            }
            h.serve(c);
        }
    }

    fn serve(h: *StaticHttp, c: std.Io.net.Stream) void {
        const io = std.testing.io;
        defer c.close(io);
        var rbuf: [4096]u8 = undefined;
        var r = c.reader(io, &rbuf);
        var wbuf: [4096]u8 = undefined;
        var w = c.writer(io, &wbuf);
        var target_buf: [512]u8 = undefined;
        var target: []const u8 = "";
        var range: ?[2]u64 = null;
        var upgrade = false;
        var first = true;
        while (r.interface.takeDelimiterExclusive('\n')) |raw| {
            r.interface.toss(1);
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0) break;
            if (first) {
                first = false;
                var it = std.mem.splitScalar(u8, line, ' ');
                _ = it.next();
                const t = it.next() orelse return;
                target = std.fmt.bufPrint(&target_buf, "{s}", .{t}) catch return;
                continue;
            }
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = line[0..colon];
            const value = std.mem.trim(u8, line[colon + 1 ..], " ");
            if (std.ascii.eqlIgnoreCase(name, "upgrade")) upgrade = true;
            if (std.ascii.eqlIgnoreCase(name, "range") and std.mem.startsWith(u8, value, "bytes=")) {
                const dash = std.mem.indexOfScalar(u8, value, '-') orelse continue;
                const a = std.fmt.parseInt(u64, value[6..dash], 10) catch continue;
                const b = std.fmt.parseInt(u64, value[dash + 1 ..], 10) catch continue;
                range = .{ a, b };
            }
        } else |_| return;
        if (!std.mem.startsWith(u8, target, "/t")) return h.status(&w, "404 Not Found");
        const path = if (target.len == 2) "/" else target[2..];
        if (upgrade) {
            h.note("UPGRADE", path);
            return h.status(&w, "404 Not Found");
        }
        h.note(if (range != null) "RANGE" else "GET", path);
        var pb: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const host = std.fmt.bufPrint(&pb, "{s}{s}", .{ h.dir, path }) catch return;
        const data = std.Io.Dir.cwd().readFileAlloc(io, host, gpa, .limited(16 << 20)) catch return h.status(&w, "404 Not Found");
        defer gpa.free(data);
        if (range) |rg| {
            if (rg[0] >= data.len) return h.status(&w, "416 Range Not Satisfiable");
            const last = @min(rg[1], data.len - 1);
            const part = data[@intCast(rg[0])..@intCast(last + 1)];
            w.interface.print("HTTP/1.1 206 Partial Content\r\nContent-Length: {d}\r\nContent-Range: bytes {d}-{d}/{d}\r\nConnection: close\r\n\r\n", .{ part.len, rg[0], last, data.len }) catch return;
            w.interface.writeAll(part) catch return;
        } else {
            w.interface.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{data.len}) catch return;
            w.interface.writeAll(data) catch return;
        }
        w.interface.flush() catch {};
    }

    fn status(_: *StaticHttp, w: *std.Io.net.Stream.Writer, s: []const u8) void {
        w.interface.print("HTTP/1.1 {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{s}) catch return;
        w.interface.flush() catch {};
    }
};

/// A static tree in a scratch directory, served by a StaticHttp, with
/// the run's cache in the scratch directory too: `/a`
/// (`apple`), `/big` (100000 bytes, read by Range), `/bad` (whose index
/// hash is wrong), `/l` (a link to a), and `/sub`, whose own index lists
/// `/sub/b` (`banana`).
const StaticRig = struct {
    s: Scratch,
    http: StaticHttp,
    tree_buf: [std.Io.Dir.max_path_bytes]u8 = undefined,

    fn start(x: *StaticRig) !void {
        try x.s.init();
        errdefer x.s.deinit();
        const io = std.testing.io;
        const d = x.s.tmp.dir;
        try d.createDirPath(io, "t/.fs");
        try d.createDirPath(io, "t/sub/.fs");
        const big = try gpa.alloc(u8, 100000);
        defer gpa.free(big);
        for (big, 0..) |*b, i| b.* = 'a' + @as(u8, @intCast(i % 26));
        try d.writeFile(io, .{ .sub_path = "t/a", .data = "apple\n" });
        try d.writeFile(io, .{ .sub_path = "t/big", .data = big });
        try d.writeFile(io, .{ .sub_path = "t/bad", .data = "not what the index says\n" });
        try d.writeFile(io, .{ .sub_path = "t/sub/b", .data = "banana\n" });
        var ha: [64]u8 = undefined;
        var hbig: [64]u8 = undefined;
        var hb: [64]u8 = undefined;
        var top: std.Io.Writer.Allocating = .init(gpa);
        defer top.deinit();
        try top.writer.print(
            \\fsindex 1 seq 1
            \\/ d 755 0 10 1 - -
            \\/a f 644 6 10 1 b3:{s} -
            \\/bad f 644 24 10 1 b3:{s} -
            \\/big f 644 100000 10 1 b3:{s} -
            \\/l l 777 1 10 1 - - a
            \\/sub d 755 0 10 1 - i
            \\
        , .{ b3hex("apple\n", &ha), b3hex("something else\n", &hb), b3hex(big, &hbig) });
        try d.writeFile(io, .{ .sub_path = "t/.fs/index", .data = top.written() });
        var hs: [64]u8 = undefined;
        var sub_buf: [256]u8 = undefined;
        try d.writeFile(io, .{ .sub_path = "t/sub/.fs/index", .data = try std.fmt.bufPrint(&sub_buf, "fsindex 1 seq 1\n/ d 755 0 10 1 - -\n/b f 644 7 10 1 b3:{s} -\n", .{b3hex("banana\n", &hs)}) });
        const tree = try std.fmt.bufPrint(&x.tree_buf, "{s}/t", .{x.s.path});
        try x.http.start(tree);
    }

    fn stop(x: *StaticRig) void {
        x.http.stop();
        x.s.deinit();
    }

    /// `--url URL:/n/t` and `args` after it.
    fn run_(x: *StaticRig, e: Env, args: []const []const u8) !Result {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        var ub: [128]u8 = undefined;
        var cb: [std.Io.Dir.max_path_bytes]u8 = undefined;
        try argv.appendSlice(gpa, &.{ "--url", try std.fmt.bufPrint(&ub, "{s}:/n/t", .{x.http.url()}), "--index-cache", try std.fmt.bufPrint(&cb, "{s}/cache", .{x.s.path}) });
        try argv.appendSlice(gpa, args);
        x.http.reset();
        return runOn(e, firstEngine(e), argv.items, null);
    }
};

fn b3hex(data: []const u8, buf: *[64]u8) []const u8 {
    var h: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(data, &h, .{});
    return std.fmt.bufPrint(buf, "{x}", .{&h}) catch unreachable;
}

test "--url http:// upgrades to a WebSocket when the server answers 101 [mounts]" {
    const e = try env(@src());
    var w: WsRoot = undefined;
    try w.start(e, .{});
    defer w.stop();
    var ub: [160]u8 = undefined;
    const u = try std.fmt.bufPrint(&ub, "http://{s}:/n/fs", .{w.url()["ws://".len..]});
    const r = try runOn(e, firstEngine(e), &.{ "--url", u, "--rc", "test -e /n/fs/lib/namespace && echo ws" }, null);
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("ws\n", r.out);
    try std.testing.expectEqualStrings("/9p", w.relay.target());
}

test "--url http:// falls back to a static dotfs tree [mounts]" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const e = try env(@src());
    var x: StaticRig = undefined;
    try x.start();
    defer x.stop();
    {
        const r = try x.run_(e, &.{ "--rc", "ls /n/t; cat /n/t/a /n/t/l; cp /n/t/sub/b /n/t/a || echo read-only" });
        defer r.deinit();
        errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
        try std.testing.expectEqual(0, r.code);
        try std.testing.expectEqualStrings("/n/t/a\n/n/t/bad\n/n/t/big\n/n/t/l\n/n/t/sub\napple\napple\nread-only\n", r.out);
        try expectIn(r.err, "read-only file system");
        // One probe, then the index.
        try std.testing.expectEqual(1, x.http.count("UPGRADE /"));
        try std.testing.expectEqual(1, x.http.count("GET /.fs/index"));
        // a is fetched once, for both reads.
        try std.testing.expectEqual(1, x.http.count("GET /a"));
    }
    {
        // The next run finds a in the host's cache, by its hash.
        const r = try x.run_(e, &.{ "--rc", "cat /n/t/a" });
        defer r.deinit();
        try std.testing.expectEqualStrings("apple\n", r.out);
        try std.testing.expectEqual(0, x.http.count("GET /a"));
    }
    // With no index either, the message names both attempts.
    try x.s.tmp.dir.deleteFile(std.testing.io, "t/.fs/index");
    const r = try x.run_(e, &.{"/bin/echo"});
    defer r.deinit();
    try std.testing.expectEqual(125, r.code);
    try expectIn(r.err, "server answered 404");
    try expectIn(r.err, "no static tree (/.fs/index: 404");
}

test "a static tree reads by Range and fails a read on a hash mismatch [mounts]" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const e = try env(@src());
    var x: StaticRig = undefined;
    try x.start();
    defer x.stop();
    const r = try x.run_(e, &.{ "--rc", "wc -c </n/t/big; dd -if /n/t/big -bs 1 -iseek 99997 -count 3 >[2]/dev/null; echo; cat /n/t/bad || echo failed" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("100000\nbcd\nfailed\n", std.mem.trimStart(u8, r.out, " \t"));
    try expectIn(r.err, "content changed");
    try std.testing.expectEqual(0, x.http.count("GET /big"));
    try std.testing.expect(x.http.count("RANGE /big") > 0);
}

test "a static tree loads a nested index on first use [mounts]" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const e = try env(@src());
    var x: StaticRig = undefined;
    try x.start();
    defer x.stop();
    {
        const r = try x.run_(e, &.{ "--rc", "cat /n/t/a" });
        defer r.deinit();
        try std.testing.expectEqualStrings("apple\n", r.out);
        try std.testing.expectEqual(0, x.http.count("GET /sub/.fs/index"));
    }
    const r = try x.run_(e, &.{ "--rc", "ls /n/t/sub; cat /n/t/sub/b" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("/n/t/sub/b\nbanana\n", r.out);
    try std.testing.expectEqual(1, x.http.count("GET /sub/.fs/index"));
}

test "index= on a mount off / names its index [mounts]" {
    const e = try env(@src());
    var x: IndexRig = undefined;
    try x.start(e, false);
    defer x.stop();
    const text = try x.mkindex(e);
    defer gpa.free(text);
    try x.write("given", text);
    var ub: [std.Io.Dir.max_path_bytes + 128]u8 = undefined;
    var db: [64]u8 = undefined;
    x.relay.reset();
    const r = try run(e, &.{ "--url", try std.fmt.bufPrint(&ub, "{s}:/n/fs:index={s}/given", .{ dialUrl(&db, x.relay.dial()), x.s.path }), "--index-cache", x.cache, "-v", "--rc", "ls /n/fs/lib/x; test -e /n/fs/lib/zznope || echo absent" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("/n/fs/lib/x/a\n/n/fs/lib/x/b\n/n/fs/lib/x/sub\nabsent\n", r.out);
    try std.testing.expect(!x.relay.walked("zznope"));
    // The server has no .fs/index of its own.
    try std.testing.expect(!x.s.exists("tree/.fs/index"));
}

test "a 9P server's .fs/index answers walks without the server [mounts]" {
    const e = try env(@src());
    var x: IndexRig = undefined;
    try x.start(e, false);
    defer x.stop();
    try x.index(e);
    var ub: [128]u8 = undefined;
    var db: [64]u8 = undefined;
    x.relay.reset();
    const r = try run(e, &.{ "--url", try std.fmt.bufPrint(&ub, "{s}:/n/fs", .{dialUrl(&db, x.relay.dial())}), "--index-cache", x.cache, "-v", "--rc", "ls /n/fs/lib/x; test -e /n/fs/lib/zznope || echo absent" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("/n/fs/lib/x/a\n/n/fs/lib/x/b\n/n/fs/lib/x/sub\nabsent\n", r.out);
    try std.testing.expect(!x.relay.walked("zznope"));
}

test "--print output with a Linux tree and 9P settings replays with --ns [mounts]" {
    const e = try env(@src());
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    // A Linux tree from a 9P server, and the 9front root at /n/fs.
    var lin: RootServer = undefined;
    try lin.startTree(e, le.root);
    defer lin.stop();
    var nine: RootServer = undefined;
    try nine.start(e);
    defer nine.stop();
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var lb: [96]u8 = undefined;
    var nb: [96]u8 = undefined;
    const p = try run(e, &.{ "--url", try std.fmt.bufPrint(&lb, "{s}:#L:user=glenda", .{lin.url()}), "--url", try std.fmt.bufPrint(&nb, "{s}:/n/fs", .{nine.url()}), "--print", "--rc", "echo" });
    defer p.deinit();
    try expectIn(p.out, "  mount -r 'tcp://");
    try expectIn(p.out, "'#Olinux' '' 'user=glenda' 9p");
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ns", .data = try printedNamespace(p.out) });
    // Replayed without the flags, it mounts both, making /n/fs.
    const r = try run(e, &.{ "--net=enable", "--ns", s.ns(), "--rc", "cat '#L/etc/alpine-release' >/dev/null && echo linux; test -e /n/fs/lib/namespace && echo 9p" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("linux\n9p\n", r.out);
}

test "user= is sent as the attach uname [mounts]" {
    const e = try env(@src());
    for ([_]?[]const u8{ "glenda", null }) |user| {
        var f: FakeAttach = undefined;
        try f.start("no");
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(gpa);
        var ub: [128]u8 = undefined;
        var ob: [64]u8 = undefined;
        try args.appendSlice(gpa, &.{ "--url", if (user) |u| urlOpts(&ub, f.url(), try std.fmt.bufPrint(&ob, "user={s}", .{u})) else f.url() });
        try args.append(gpa, "/bin/echo");
        // One engine: the server takes one connection.
        const r = runOn(e, firstEngine(e), args.items, null) catch |err| {
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

test "--url to /srv/NAME posts without mounting [mounts]" {
    const e = try env(@src());
    var srv: RootServer = undefined;
    try srv.start(e);
    defer srv.stop();
    var ub: [128]u8 = undefined;
    const r = try run(e, &.{ "--url", try std.fmt.bufPrint(&ub, "{s}:/srv/fs", .{srv.url()}), "--rc", "ls /srv/fs && mkdir /tmp/r && mount /srv/fs /tmp/r && ls /tmp/r/rc/bin/lc" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("/srv/fs\n/tmp/r/rc/bin/lc\n", r.out);
}

test "an unreachable 9P root exits 125 [ninep-roots]" {
    const e = try env(@src());
    var probe = try listenLocal();
    const port = probe.socket.address.getPort();
    probe.deinit(std.testing.io);
    var buf: [64]u8 = undefined;
    const dial = try std.fmt.bufPrint(&buf, "tcp://127.0.0.1:{d}", .{port});
    const r = try run(e, &.{ "--url", dial, "/bin/echo" });
    defer r.deinit();
    try std.testing.expectEqual(125, r.code);
    var want: [96]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, r.err, try std.fmt.bufPrint(&want, "root tcp!127.0.0.1!{d}: ", .{port})) != null);
}

test "a 9P root that wants authentication exits 125 [ninep-roots]" {
    const e = try env(@src());
    var f: FakeAttach = undefined;
    try f.start("authentication required");
    const r = runOn(e, firstEngine(e), &.{ "--url", f.url(), "/bin/echo" }, null) catch |err| {
        f.finish();
        return err;
    };
    defer r.deinit();
    f.finish();
    try std.testing.expectEqual(125, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, ": authentication required") != null);
}

test "--write=none with a 9P root is a usage error [ninep-roots]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--url", "tcp://127.0.0.1:1", "--write=none", "/bin/echo" });
    defer r.deinit();
    try std.testing.expectEqual(2, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "--write=none can't be enforced on a 9P root") != null);
}

test "a unix socket root on Windows exits 125 [ninep-roots]" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const e = try env(@src());
    const r = try run(e, &.{ "--url", "unix:///C:/fs.sock", "/bin/echo" });
    defer r.deinit();
    try std.testing.expectEqual(125, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "unix socket roots need a POSIX host") != null);
}

test "--print shows a 9P root, and its output replays with --ns [ninep-roots]" {
    const e = try env(@src());
    var srv: RootServer = undefined;
    try srv.start(e);
    defer srv.stop();
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const p = try run(e, &.{ "--url", srv.url(), "--cwd", s.path, "--print", "ls" });
    defer p.deinit();
    try std.testing.expectEqual(0, p.code);
    var want: [96]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, p.out, try std.fmt.bufPrint(&want, "  mount -r '{s}' '#Oroot' ''", .{srv.url()})) != null);
    try std.testing.expect(std.mem.indexOf(u8, p.out, try std.fmt.bufPrint(&want, "9p  # {s}  index=/.fs/index\n", .{srv.dial()})) != null);
    // Under the root's overlay (design/epoch-0/overlay.md) nothing reaches
    // the server; under --write=scope its server decides.
    try std.testing.expect(std.mem.indexOf(u8, p.out, "writes to the 9P root go to its server") == null);
    const sp = try run(e, &.{ "--url", srv.url(), "--write=scope", "--print", "ls" });
    defer sp.deinit();
    try std.testing.expect(std.mem.indexOf(u8, sp.out, "writes to the 9P root go to its server") != null);
    // The namespace section, replayed after the plan's own.
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ns", .data = try printedNamespace(p.out) });
    try expectSameAsHost(e, srv.url(), &.{ "--cwd", s.path, "--ns", s.ns(), "/bin/ls", "/", "/bin/ls" });
}

test "a write to a 9P root under the default profile doesn't reach the server [overlay]" {
    const e = try env(@src());
    var srv: RootServer = undefined;
    try srv.start(e);
    defer srv.stop();
    // The server is a machine of its own, whose namespace outlives each
    // connection: a write that reached it would show in the next one.
    const r = try run(e, &.{ "--url", srv.url(), "--rc", "echo hi > /lib/h9-overlay-9p && cat /lib/h9-overlay-9p" });
    defer r.deinit();
    try std.testing.expectEqualStrings("hi\n", r.out);
    try std.testing.expectEqual(0, r.code);
    const after = try run(e, &.{ "--url", srv.url(), "--write=scope", "--rc", "test -e /lib/h9-overlay-9p && echo reached" });
    defer after.deinit();
    try std.testing.expectEqualStrings("", after.out);
    // Under --write=scope the write goes to the server, whose export is
    // read-only (exportfs -R).
    const sc = try run(e, &.{ "--url", srv.url(), "--write=scope", "--rc", "echo x > /lib/h9-overlay-9p" });
    defer sc.deinit();
    try std.testing.expectEqual(1, sc.code);
    try std.testing.expect(std.mem.indexOf(u8, sc.err, "read only") != null);
    try expectRootLacks(e, "lib/h9-overlay-9p");
}

test "--check runs /bin/echo from a 9P root [ninep-roots]" {
    const e = try env(@src());
    var srv: RootServer = undefined;
    try srv.start(e);
    defer srv.stop();
    const r = try run(e, &.{ "--url", srv.url(), "--check" });
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\n", .{r.out});
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "ok, /bin/echo runs") != null);
}

// Metadata indexes (design/epoch-0/mount-index.md). The server is a second h9
// serving a small tree copied from the test root (a few commands,
// rcmain, the mount points, and /lib/x) with exportfs, behind a relay
// that counts the T-messages and keeps the names walked. Each case
// keeps its compiled indexes in a cache of its own.

/// A TCP relay to a RootServer that counts the T-messages it passes,
/// the opens of a fid walked to .fs/index, and the names walked.
const CountingRelay = struct {
    srv: std.Io.net.Server,
    port: u16,
    thread: std.Thread = undefined,
    tmsgs: std.atomic.Value(u32) = .init(0),
    index_opens: std.atomic.Value(u32) = .init(0),
    lock: std.atomic.Mutex = .unlocked,
    /// Each name walked, after a newline.
    names: [1 << 16]u8 = undefined,
    names_len: usize = 0,
    dial_buf: [64]u8 = undefined,

    fn start(c: *CountingRelay, port: u16) !void {
        c.* = .{ .srv = try listenLocal(), .port = port };
        c.reset();
        c.thread = try std.Thread.spawn(.{}, accept, .{c});
        c.thread.detach();
    }

    fn dial(c: *CountingRelay) []const u8 {
        return std.fmt.bufPrint(&c.dial_buf, "tcp!127.0.0.1!{d}", .{c.srv.socket.address.getPort()}) catch unreachable;
    }

    fn acquire(c: *CountingRelay) void {
        while (!c.lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn reset(c: *CountingRelay) void {
        c.tmsgs.store(0, .release);
        c.index_opens.store(0, .release);
        c.acquire();
        defer c.lock.unlock();
        c.names[0] = '\n';
        c.names_len = 1;
    }

    /// Whether a Twalk named `name` since the last reset.
    fn walked(c: *CountingRelay, name: []const u8) bool {
        c.acquire();
        defer c.lock.unlock();
        var buf: [256]u8 = undefined;
        const want = std.fmt.bufPrint(&buf, "\n{s}\n", .{name}) catch return false;
        return std.mem.indexOf(u8, c.names[0..c.names_len], want) != null;
    }

    fn accept(c: *CountingRelay) void {
        const io = std.testing.io;
        while (true) {
            const conn = deadline.accept(&c.srv, io) catch return;
            const ip = std.Io.net.IpAddress.parse("127.0.0.1", c.port) catch unreachable;
            const s = ip.connect(io, .{ .mode = .stream }) catch {
                conn.close(io);
                continue;
            };
            const t = std.Thread.spawn(.{}, UnixRelay.copy, .{ s, conn }) catch return;
            t.detach();
            const t2 = std.Thread.spawn(.{}, count, .{ c, conn, s }) catch return;
            t2.detach();
        }
    }

    /// Copies 9P messages from `from` to `to`, counting them.
    fn count(c: *CountingRelay, from: std.Io.net.Stream, to: std.Io.net.Stream) void {
        const io = std.testing.io;
        var rbuf: [1 << 17]u8 = undefined;
        var r = from.reader(io, &rbuf);
        var w = to.writer(io, &.{});
        // Not the testing allocator: the relay's threads are detached and
        // can outlive the case, whose end checks for leaks.
        var index_fids: std.ArrayList(u32) = .empty;
        defer index_fids.deinit(std.heap.page_allocator);
        while (true) {
            const hdr = r.interface.peek(4) catch break;
            const size = std.mem.readInt(u32, hdr[0..4], .little);
            if (size < 7 or size > rbuf.len) break;
            const m = r.interface.take(size) catch break;
            c.saw(m, &index_fids) catch break;
            w.interface.writeAll(m) catch break;
        }
        to.shutdown(io, .both) catch {};
        from.shutdown(io, .both) catch {};
    }

    fn saw(c: *CountingRelay, m: []const u8, index_fids: *std.ArrayList(u32)) !void {
        _ = c.tmsgs.fetchAdd(1, .acq_rel);
        const fid = if (m.len >= 11) std.mem.readInt(u32, m[7..11], .little) else return;
        switch (m[4]) {
            110 => { // Twalk: fid[4] newfid[4] nwname[2] wname[s]...
                if (m.len < 17) return;
                const newfid = std.mem.readInt(u32, m[11..15], .little);
                const n = std.mem.readInt(u16, m[15..17], .little);
                var o: usize = 17;
                var last: []const u8 = "";
                c.acquire();
                defer c.lock.unlock();
                for (0..n) |_| {
                    const name = FakeAttach.str(m, &o) orelse return;
                    if (c.names_len + name.len + 1 <= c.names.len) {
                        @memcpy(c.names[c.names_len..][0..name.len], name);
                        c.names[c.names_len + name.len] = '\n';
                        c.names_len += name.len + 1;
                    }
                    last = name;
                }
                if (std.mem.eql(u8, last, "index")) try index_fids.append(std.heap.page_allocator, newfid);
            },
            112 => if (std.mem.indexOfScalar(u32, index_fids.items, fid) != null) {
                _ = c.index_opens.fetchAdd(1, .acq_rel);
            },
            120 => if (std.mem.indexOfScalar(u32, index_fids.items, fid)) |i| {
                _ = index_fids.swapRemove(i);
            },
            else => {},
        }
    }
};

/// The index cases' tree and server: the tree at `tree`, served behind
/// `relay`, and a cache at `cache`.
const IndexRig = struct {
    s: Scratch,
    srv: RootServer,
    relay: CountingRelay,
    tree_buf: [std.Io.Dir.max_path_bytes]u8 = undefined,
    cache_buf: [std.Io.Dir.max_path_bytes]u8 = undefined,
    tree: []const u8 = "",
    cache: []const u8 = "",

    fn start(x: *IndexRig, e: Env, writable: bool) !void {
        const io = std.testing.io;
        try x.s.init();
        errdefer x.s.deinit();
        const d = x.s.tmp.dir;
        const arch = testArch(e);
        var b: [96]u8 = undefined;
        for ([_][]const u8{ "bin", "dev", "env", "fd", "mnt/term/cwd", "n", "net", "proc", "srv", "tmp", "rc/bin", "rc/lib", "lib/x/sub" }) |p|
            try d.createDirPath(io, try std.fmt.bufPrint(&b, "tree/{s}", .{p}));
        try d.createDirPath(io, try std.fmt.bufPrint(&b, "tree/{s}/bin", .{arch}));
        for ([_][]const u8{ "rc", "echo", "ls", "cat", "test", "walk", "awk", "sort", "mount" }) |cmd| {
            var src: [64]u8 = undefined;
            const rel = try std.fmt.bufPrint(&src, "{s}/bin/{s}", .{ arch, cmd });
            try std.Io.Dir.copyFile(std.Io.Dir.cwd(), try hostPath(e.root, rel), d, try std.fmt.bufPrint(&b, "tree/{s}", .{rel}), io, .{});
        }
        try std.Io.Dir.copyFile(std.Io.Dir.cwd(), try hostPath(e.root, "rc/lib/rcmain"), d, "tree/rc/lib/rcmain", io, .{});
        try d.writeFile(io, .{ .sub_path = "tree/lib/x/a", .data = "apple\n" });
        // 0644 whatever the umask (Ubuntu's is 002), for mkindex's case.
        if (builtin.os.tag != .windows) try d.setFilePermissions(io, "tree/lib/x/a", .fromMode(0o644), .{});
        try d.writeFile(io, .{ .sub_path = "tree/lib/x/b", .data = "banana\n" });
        try d.writeFile(io, .{ .sub_path = "tree/lib/x/sub/c", .data = "cherry\n" });
        x.tree = try std.fmt.bufPrint(&x.tree_buf, "{s}/tree", .{x.s.path});
        x.cache = try std.fmt.bufPrint(&x.cache_buf, "{s}/cache", .{x.s.path});
        try x.srv.startServing(e, x.tree, writable);
        errdefer x.srv.stop();
        try x.relay.start(x.srv.port);
    }

    fn stop(x: *IndexRig) void {
        x.srv.stop();
        x.s.deinit();
    }

    /// mkindex's index of the served tree, which the caller frees.
    fn mkindex(x: *IndexRig, e: Env) ![]u8 {
        const r = try run(e, &.{ "--url", x.srv.url(), "--index", "none", "--rc", "mkindex /" });
        defer gpa.free(r.err);
        errdefer gpa.free(r.out);
        errdefer std.debug.print("mkindex: {s}\n", .{r.err});
        try std.testing.expectEqual(0, r.code);
        try std.testing.expect(std.mem.startsWith(u8, r.out, "fsindex 1 seq 0\n"));
        return r.out;
    }

    /// Writes the served tree's .fs/index, indexed now.
    fn index(x: *IndexRig, e: Env) !void {
        const text = try x.mkindex(e);
        defer gpa.free(text);
        try x.write("tree/.fs/index", text);
    }

    fn write(x: *IndexRig, rel: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(rel)) |d| try x.s.tmp.dir.createDirPath(std.testing.io, d);
        try x.s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = rel, .data = data });
    }

    /// Runs `args` over the relay, with -v and the case's cache, after
    /// resetting the relay's counts. A leading `index=FILE` in `args` is
    /// the relay's --url option.
    fn run_(x: *IndexRig, e: Env, args_in: []const []const u8) !Result {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        var args = args_in;
        var ub: [std.Io.Dir.max_path_bytes + 64]u8 = undefined;
        var db: [64]u8 = undefined;
        const url = dialUrl(&db, x.relay.dial());
        const u = if (args.len > 0 and std.mem.startsWith(u8, args[0], "index=")) blk: {
            defer args = args[1..];
            break :blk try std.fmt.bufPrint(&ub, "{s}:/:{s}", .{ url, args[0] });
        } else url;
        try argv.appendSlice(gpa, &.{ "--url", u, "--index-cache", x.cache, "-v" });
        try argv.appendSlice(gpa, args);
        x.relay.reset();
        return run(e, argv.items);
    }

    /// Waits out the second #U's mtimes are in, so a change after
    /// indexing shows in a directory's qid.
    fn tick() !void {
        try std.testing.io.sleep(.fromMilliseconds(1100), .awake);
    }
};

const x_listing = "/lib/x/a\n/lib/x/b\n/lib/x/sub\n";

/// Adds every path under `dir`, as `prefix/name`, to `out`.
fn hostNames(dir: std.Io.Dir, prefix: []const u8, out: *std.StringHashMapUnmanaged(void), arena: std.mem.Allocator) !void {
    const io = std.testing.io;
    var it = dir.iterate();
    while (try it.next(io)) |ent| {
        if (std.mem.eql(u8, ent.name, ".fs")) continue;
        const p = try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, ent.name });
        try out.put(arena, p, {});
        if (ent.kind == .directory) {
            var sub = try dir.openDir(io, ent.name, .{ .iterate = true });
            defer sub.close(io);
            try hostNames(sub, p, out, arena);
        }
    }
}

/// The paths of an index's entries, in order.
fn indexPaths(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    _ = lines.next();
    while (lines.next()) |l| {
        if (l.len == 0) continue;
        const esc = l[0 .. std.mem.indexOfScalar(u8, l, ' ') orelse l.len];
        var p: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < esc.len) : (i += 1) {
            if (esc[i] == '%' and i + 2 < esc.len) {
                try p.append(arena, try std.fmt.parseInt(u8, esc[i + 1 .. i + 3], 16));
                i += 2;
            } else try p.append(arena, esc[i]);
        }
        try out.append(arena, p.items);
    }
    return out.items;
}

test "mkindex lists every name in the test root with the server's qids [mount-index]" {
    const e = try env(@src());
    var x: IndexRig = undefined;
    try x.start(e, false);
    defer x.stop();
    const text = try x.mkindex(e);
    defer gpa.free(text);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    errdefer std.debug.print("index:\n{s}", .{text});
    // Every name in the tree, sorted, and nothing else.
    var want: std.StringHashMapUnmanaged(void) = .empty;
    try want.put(arena, "/", {});
    var tree = try std.Io.Dir.cwd().openDir(std.testing.io, x.tree, .{ .iterate = true });
    defer tree.close(std.testing.io);
    try hostNames(tree, "", &want, arena);
    const got = try indexPaths(arena, text);
    try std.testing.expectEqual(want.count(), got.len);
    for (got, 0..) |p, i| {
        try std.testing.expect(want.contains(p));
        if (i > 0) try std.testing.expect(std.mem.order(u8, got[i - 1], p) == .lt);
    }
    try std.testing.expect(std.mem.indexOf(u8, text, "9p.incomplete") == null);
    // The qid is the server's, as the guest sees it through /srv/root.
    const q = try run(e, &.{ "--url", x.srv.url(), "--index", "none", "--rc", "mount /srv/root /n && walk -e q /n/lib/x/a" });
    defer q.deinit();
    const dot = std.mem.indexOfScalar(u8, q.out, '.') orelse return error.NoQid;
    const at = std.mem.indexOf(u8, text, "\n/lib/x/a ") orelse return error.NoEntry;
    const line = std.mem.sliceTo(text[at + 1 ..], '\n');
    var f = std.mem.splitScalar(u8, line, ' ');
    _ = f.next();
    try std.testing.expectEqualStrings("f", f.next().?);
    // Windows has no Unix modes for the server to report.
    const mode = f.next().?;
    if (builtin.os.tag != .windows) try std.testing.expectEqualStrings("0644", mode);
    try std.testing.expectEqualStrings("6", f.next().?);
    const k = (std.mem.indexOf(u8, line, " 9p.qid=") orelse return error.NoQid) + " 9p.qid=".len;
    const kdot = std.mem.indexOfScalarPos(u8, line, k, '.') orelse return error.NoQid;
    try std.testing.expectEqual(try std.fmt.parseInt(u64, q.out[0..dot], 16), try std.fmt.parseInt(u64, line[k..kdot], 16));
    try std.testing.expect(std.mem.indexOf(u8, line, " 9p.uid=") != null);
}

test "mkindex escapes names with spaces and marks a directory it can't read incomplete [mount-index]" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const e = try env(@src());
    var x: IndexRig = undefined;
    try x.start(e, false);
    defer x.stop();
    // devmnt fails a directory read with a newline in a name, so walk
    // can't list /lib/x/sub; a space and a rune that isn't ASCII are
    // escaped.
    try x.write("tree/lib/x/sub/new\nline", "x\n");
    try x.write("tree/lib/x/with space", "x\n");
    try x.write("tree/lib/x/caf\xc3\xa9", "x\n");
    const text = try x.mkindex(e);
    defer gpa.free(text);
    errdefer std.debug.print("index:\n{s}", .{text});
    try std.testing.expect(std.mem.indexOf(u8, text, "\n/lib/x/with%20space f ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\n/lib/x/caf%C3%A9 f ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\n/lib/x/sub/") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\n/lib/x/a ") != null);
    const sub = std.mem.indexOf(u8, text, "\n/lib/x/sub d ") orelse return error.NoEntry;
    try std.testing.expect(std.mem.endsWith(u8, std.mem.sliceTo(text[sub + 1 ..], '\n'), " 9p.incomplete=1"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, text, "9p.incomplete"));
    // The index compiles, h9 answers for /lib/x from it, and not for
    // /lib/x/sub.
    try x.write("tree/.fs/index", text);
    const r = try x.run_(e, &.{ "--rc", "ls /lib/x; cat /lib/x/sub/c" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("/lib/x/a\n/lib/x/b\n/lib/x/caf\xc3\xa9\n/lib/x/sub\n'/lib/x/with space'\ncherry\n", r.out);
    try expectIn(r.err, "index: /.fs/index: ");
}

test "a root with .fs/index runs /bin/ls [mount-index]" {
    const e = try env(@src());
    var x: IndexRig = undefined;
    try x.start(e, false);
    defer x.stop();
    try x.index(e);
    const r = try x.run_(e, &.{ "/bin/ls", "/lib/x" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings(x_listing, r.out);
    try expectIn(r.err, "index: /.fs/index: ");
    try expectIn(r.err, " 0 demoted");
}

test "an indexed root sends no Twalk for a missing name in a validated directory [mount-index]" {
    const e = try env(@src());
    var x: IndexRig = undefined;
    try x.start(e, false);
    defer x.stop();
    try x.index(e);
    const args: []const []const u8 = &.{ "--rc", "test -e /lib/x/zznope || echo absent; cat /lib/x/zznope2" };
    const r = try x.run_(e, args);
    defer r.deinit();
    try std.testing.expectEqualStrings("absent\n", r.out);
    try expectIn(r.err, "zznope2");
    try std.testing.expect(!x.relay.walked("zznope"));
    try std.testing.expect(!x.relay.walked("zznope2"));
    // Without the index, they go to the server.
    var none: std.ArrayList([]const u8) = .empty;
    defer none.deinit(gpa);
    try none.appendSlice(gpa, &.{ "--index", "none" });
    try none.appendSlice(gpa, args);
    const n = try x.run_(e, none.items);
    defer n.deinit();
    try std.testing.expectEqualStrings("absent\n", n.out);
    try std.testing.expect(x.relay.walked("zznope"));
}

test "an indexed root sends fewer T-messages than an unindexed one for rc -c echo [mount-index]" {
    const e = try env(@src());
    var x: IndexRig = undefined;
    try x.start(e, false);
    defer x.stop();
    try x.index(e);
    // The second run of each, so the indexed one is cached.
    var counts: [2]u32 = undefined;
    for ([_][]const u8{ "auto", "none" }, &counts) |mode, *c| {
        for (0..2) |_| {
            const r = try x.run_(e, &.{ "--index", mode, "--rc", "echo hi" });
            defer r.deinit();
            try std.testing.expectEqualStrings("hi\n", r.out);
        }
        c.* = x.relay.tmsgs.load(.acquire);
    }
    errdefer std.debug.print("indexed {d}, unindexed {d}\n", .{ counts[0], counts[1] });
    try std.testing.expect(counts[0] < counts[1]);
}

test "index=FILE is used over a root without .fs/index [mount-index]" {
    const e = try env(@src());
    var x: IndexRig = undefined;
    try x.start(e, false);
    defer x.stop();
    const text = try x.mkindex(e);
    defer gpa.free(text);
    try x.write("x.h9index", text);
    const file = try std.fs.path.join(gpa, &.{ x.s.path, "x.h9index" });
    defer gpa.free(file);
    var ib: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    const r = try x.run_(e, &.{ try std.fmt.bufPrint(&ib, "index={s}", .{file}), "--rc", "ls /lib/x; test -e /lib/zznope || echo absent" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings(x_listing ++ "absent\n", r.out);
    var buf: [std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    try expectIn(r.err, try std.fmt.bufPrint(&buf, "index: {s}: ", .{file}));
    try std.testing.expect(!x.relay.walked("zznope"));
    try std.testing.expect(!x.relay.walked("index"));
}

test "a second run uses the cache and doesn't read .fs/index [mount-index]" {
    const e = try env(@src());
    var x: IndexRig = undefined;
    try x.start(e, false);
    defer x.stop();
    try x.index(e);
    const first = try x.run_(e, &.{ "/bin/ls", "/lib/x" });
    defer first.deinit();
    try std.testing.expectEqualStrings(x_listing, first.out);
    try std.testing.expect(x.relay.index_opens.load(.acquire) > 0);
    try std.testing.expect(std.mem.indexOf(u8, first.err, "(cached)") == null);
    const second = try x.run_(e, &.{ "/bin/ls", "/lib/x" });
    defer second.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{second.err});
    try std.testing.expectEqualStrings(x_listing, second.out);
    try std.testing.expectEqual(0, x.relay.index_opens.load(.acquire));
    try expectIn(second.err, "(cached)");
}

test "a file added after indexing is found, by demoting its directory [mount-index]" {
    const e = try env(@src());
    var x: IndexRig = undefined;
    try x.start(e, false);
    defer x.stop();
    try x.index(e);
    try IndexRig.tick();
    try x.write("tree/lib/x/added", "added\n");
    const r = try x.run_(e, &.{ "--rc", "cat /lib/x/added; ls /lib/x" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("added\n/lib/x/a\n/lib/x/added\n/lib/x/b\n/lib/x/sub\n", r.out);
    try expectIn(r.err, " 1 demoted");
}

test "a file removed after indexing is not found [mount-index]" {
    const e = try env(@src());
    var x: IndexRig = undefined;
    try x.start(e, false);
    defer x.stop();
    try x.index(e);
    try IndexRig.tick();
    try x.s.tmp.dir.deleteFile(std.testing.io, "tree/lib/x/b");
    const r = try x.run_(e, &.{ "--rc", "test -e /lib/x/b || echo gone; ls /lib/x" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("gone\n/lib/x/a\n/lib/x/sub\n", r.out);
}

test "a file changed in place reads the server's contents [mount-index]" {
    const e = try env(@src());
    var x: IndexRig = undefined;
    try x.start(e, false);
    defer x.stop();
    try x.index(e);
    try IndexRig.tick();
    try x.write("tree/lib/x/a", "a longer apple\n");
    const r = try x.run_(e, &.{ "--rc", "cat /lib/x/a" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("a longer apple\n", r.out);
}

test "a malformed index is ignored and the root still mounts [mount-index]" {
    const e = try env(@src());
    var x: IndexRig = undefined;
    try x.start(e, false);
    defer x.stop();
    try x.write("tree/.fs/index", "fsindex 1 seq 0\n/ not an entry\n");
    const r = try x.run_(e, &.{ "/bin/ls", "/lib/x" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings(x_listing, r.out);
    try expectIn(r.err, "index: /.fs/index: line 2: ");
    try expectIn(r.err, "; ignored");
    // So is one of a format version h9 doesn't know.
    try x.write("tree/.fs/index", "fsindex 99 seq 0\n");
    const v = try x.run_(e, &.{ "/bin/ls", "/lib/x" });
    defer v.deinit();
    try std.testing.expectEqualStrings(x_listing, v.out);
    try expectIn(v.err, "unknown format version; ignored");
}

test "an unreadable index= exits 125 [mount-index]" {
    const e = try env(@src());
    var x: IndexRig = undefined;
    try x.start(e, false);
    defer x.stop();
    const file = try std.fs.path.join(gpa, &.{ x.s.path, "missing.h9index" });
    defer gpa.free(file);
    var ib: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    const r = try x.run_(e, &.{ try std.fmt.bufPrint(&ib, "index={s}", .{file}), "/bin/ls", "/lib/x" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(125, r.code);
    try expectIn(r.err, "index=");
    try expectIn(r.err, "not found");
}

test "--index none ignores .fs/index [mount-index]" {
    const e = try env(@src());
    var x: IndexRig = undefined;
    try x.start(e, false);
    defer x.stop();
    try x.index(e);
    const r = try x.run_(e, &.{ "--index", "none", "--rc", "ls /lib/x; test -e /lib/zznope || echo absent" });
    defer r.deinit();
    try std.testing.expectEqualStrings(x_listing ++ "absent\n", r.out);
    try std.testing.expect(!x.relay.walked("index"));
    try std.testing.expect(x.relay.walked("zznope"));
    try std.testing.expect(std.mem.indexOf(u8, r.err, "index: /.fs/index") == null);
}

test "a namespace-file mount of a server with .fs/index uses it [mount-index]" {
    const e = try env(@src());
    var x: IndexRig = undefined;
    try x.start(e, false);
    defer x.stop();
    try x.index(e);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var ns: [128]u8 = undefined;
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ns", .data = try std.fmt.bufPrint(&ns, "mount -c {s} /n\n", .{x.relay.dial()}) });
    x.relay.reset();
    // The test root's own, with the server at /n.
    const r = try run(e, &.{ "--cwd", s.path, "--ns", s.ns(), "--index-cache", x.cache, "-v", "--rc", "ls /n/lib/x; test -e /n/lib/zznope || echo absent" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("/n/lib/x/a\n/n/lib/x/b\n/n/lib/x/sub\nabsent\n", r.out);
    try expectIn(r.err, "index: /.fs/index: ");
    try std.testing.expect(!x.relay.walked("zznope"));
}

test "a file created through a writable indexed mount is found by the next walk [mount-index]" {
    const e = try env(@src());
    var x: IndexRig = undefined;
    try x.start(e, true);
    defer x.stop();
    try x.index(e);
    // --write=scope: writes to the 9P root go to its server.
    const r = try x.run_(e, &.{ "--write=scope", "--rc", "echo made >/lib/x/made && cat /lib/x/made && ls /lib/x" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("made\n/lib/x/a\n/lib/x/b\n/lib/x/made\n/lib/x/sub\n", r.out);
    try std.testing.expect(x.s.exists("tree/lib/x/made"));
}

test "a rewritten .fs/index is fetched on the next mount [mount-index]" {
    const e = try env(@src());
    var x: IndexRig = undefined;
    try x.start(e, false);
    defer x.stop();
    try x.index(e);
    const first = try x.run_(e, &.{ "/bin/ls", "/lib/x" });
    defer first.deinit();
    try IndexRig.tick();
    try x.write("tree/lib/x/later", "later\n");
    try x.index(e);
    const second = try x.run_(e, &.{ "/bin/ls", "/lib/x" });
    defer second.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{second.err});
    try std.testing.expectEqualStrings("/lib/x/a\n/lib/x/b\n/lib/x/later\n/lib/x/sub\n", second.out);
    try std.testing.expect(x.relay.index_opens.load(.acquire) > 0);
    try std.testing.expect(std.mem.indexOf(u8, second.err, "(cached)") == null);
    try expectIn(second.err, " 0 demoted");
}

test "--print shows the index source and entry count [mount-index]" {
    const e = try env(@src());
    var x: IndexRig = undefined;
    try x.start(e, false);
    defer x.stop();
    const text = try x.mkindex(e);
    defer gpa.free(text);
    try x.write("x.h9index", text);
    const file = try std.fs.path.join(gpa, &.{ x.s.path, "x.h9index" });
    defer gpa.free(file);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const n = (try indexPaths(arena_state.allocator(), text)).len;
    var dirs: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        var f = std.mem.splitScalar(u8, l, ' ');
        _ = f.next();
        if (std.mem.eql(u8, f.next() orelse "", "d")) dirs += 1;
    }
    var ub: [std.Io.Dir.max_path_bytes + 64]u8 = undefined;
    const p = try run(e, &.{ "--url", try std.fmt.bufPrint(&ub, "{s}:/:index={s}", .{ x.srv.url(), file }), "--print", "true" });
    defer p.deinit();
    errdefer std.debug.print("stdout: {s}\n", .{p.out});
    var buf: [std.Io.Dir.max_path_bytes + 64]u8 = undefined;
    try expectIn(p.out, try std.fmt.bufPrint(&buf, "  index={s} {d} entries {d} dirs\n", .{ file, n, dirs }));
    const auto = try run(e, &.{ "--url", x.srv.url(), "--print", "true" });
    defer auto.deinit();
    try expectIn(auto.out, "  index=/.fs/index\n");
    const none = try run(e, &.{ "--url", x.srv.url(), "--index", "none", "--print", "true" });
    defer none.deinit();
    try expectIn(none.out, "  index=none\n");
}

// h9's own commands in #H (design/epoch-0/guest-tools.md). Debug builds serve
// tests/fixtures/guest in #H too: `h9-guest-test` and an `echo` that the
// root's must beat. The build sets H9_TEST_GUEST_TOOLS when it served them.

/// Skips a case that needs the test-only scripts when h9 was built without
/// them (-Dguest-test=false, the default for release builds).
fn needGuestTest() !void {
    if (getenv(3, "H9_TEST_GUEST_TOOLS") == null) return error.SkipZigTest;
}

test "#H/bin is bound after /bin and its scripts run [guest-tools]" {
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

test "a root command of the same name wins over #H's [guest-tools]" {
    const e = try env(@src());
    try needGuestTest();
    const r = try run(e, &.{ "--rc", "echo hi; grep -s 'echo from' '#H/bin/echo' && echo shadowed" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("hi\nshadowed\n", r.out);
}

test "#H refuses writes [guest-tools]" {
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

test "--no-guest-tools leaves out the bind and masks #H [guest-tools]" {
    const e = try env(@src());
    const p = try run(e, &.{ "--no-guest-tools", "--print", "ls" });
    defer p.deinit();
    try std.testing.expect(std.mem.indexOf(u8, p.out, "#H/bin") == null);
    // The web host also masks #I, having no sockets.
    const want = if (getenv(3, "H9_TEST_WEB") != null) "devmask:  #C #I #H #U #ι #b #i #m\n" else "devmask:  #C #H #U #ι #b #i #m\n";
    try std.testing.expect(std.mem.indexOf(u8, p.out, want) != null);
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

test "--print shows the #H bind [guest-tools]" {
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

// Host commands (#C, --host-cmd, and hcmd) live on the host-cmd branch
// while design/host-cmd.md rethinks them.
test "--host-cmd is a usage error and #C and hcmd are absent [baseline]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--host-cmd", "ls" });
    defer r.deinit();
    try std.testing.expectEqual(2, r.code);
    const c = try run(e, &.{ "ls", "#C" });
    defer c.deinit();
    try std.testing.expectEqual(1, c.code);
    const h = try run(e, &.{ "--rc", "test -e /bin/hcmd || echo absent" });
    defer h.deinit();
    try std.testing.expectEqualStrings("absent\n", h.out);
}

// 9P over WebSocket (design/epoch-0/websocket-9p.md). The server is ninep-roots'
// RootServer with tests/wsrelay.zig in front of it, relaying WebSocket
// messages to its TCP port. /net/ws cases use the relay in echo mode.

/// A RootServer behind a WebSocket relay, for the life of a case.
const WsRoot = struct {
    srv: RootServer,
    relay: wsrelay.Relay,

    fn start(w: *WsRoot, e: Env, opts: wsrelay.Options) !void {
        try w.srv.start(e);
        errdefer w.srv.stop();
        var o = opts;
        o.target_port = w.srv.port;
        try w.relay.start(std.testing.io, 0, o);
    }

    fn url(w: *WsRoot) []const u8 {
        return w.relay.url();
    }

    fn stop(w: *WsRoot) void {
        w.relay.stop();
        w.srv.stop();
    }
};

/// An echo relay, for /net/ws cases.
fn startEcho(rl: *wsrelay.Relay, opts: wsrelay.Options) !void {
    var o = opts;
    o.echo = true;
    try rl.start(std.testing.io, 0, o);
}

/// An rc command that opens a /net/ws conversation, connects it to `url`
/// (with `extra` after the URL, such as a subprotocol), and runs `body`
/// with the conversation's number in $n.
fn rcWs(buf: []u8, url: []const u8, extra: []const u8, body: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{{ n=`{{read}}; echo connect {s}{s} >/net/ws/$n/ctl && {s} }} <>/net/ws/clone", .{ url, extra, body });
}

/// Runs `h9 args...` on `engine` with `vars` (pairs of name and value)
/// added to the environment, and a timeout of `ms`.
fn runEnv(e: Env, engine: []const u8, args: []const []const u8, vars: []const [2][]const u8, ms: u32) !Result {
    var map = try std.testing.environ.createMap(gpa);
    defer map.deinit();
    for (vars) |v| try map.put(v[0], v[1]);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ e.h9, "--engine", engine });
    if (!givesRoot(args)) try argv.appendSlice(gpa, &.{ "--dir", e.root });
    if (e.arch) |a| try argv.appendSlice(gpa, &.{ "--arch", a });
    try argv.appendSlice(gpa, args);
    const r = try runProcessWith(argv.items, null, &map, ms);
    const code = switch (r.term) {
        .exited => |c| c,
        else => {
            gpa.free(r.stdout);
            gpa.free(r.stderr);
            return error.Crashed;
        },
    };
    return .{ .code = code, .out = r.stdout, .err = r.stderr };
}

fn expectIn(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected {s} in:\n{s}\n", .{ needle, haystack });
        return error.TestExpectedEqual;
    }
}

test "a ws:// root runs /bin/ls [websocket-9p]" {
    const e = try env(@src());
    var w: WsRoot = undefined;
    try w.start(e, .{});
    defer w.stop();
    try expectSameAsHost(e, w.url(), &.{ "/bin/ls", "/", "/bin/ls" });
    try std.testing.expectEqualStrings("/9p", w.relay.target());
}

test "rc pipelines and exec run from a ws:// root [websocket-9p]" {
    const e = try env(@src());
    var w: WsRoot = undefined;
    try w.start(e, .{});
    defer w.stop();
    try expectSameAsHost(e, w.url(), &.{ "--rc", "ls /bin | grep -c '/cat$'; echo a b c | wc -w; exec /bin/echo done" });
}

test "a ws:// root works when the server splits and coalesces 9P messages [websocket-9p]" {
    const e = try env(@src());
    for ([_]wsrelay.Options{ .{ .split = true }, .{ .coalesce = true }, .{ .split = true, .coalesce = true } }) |o| {
        var w: WsRoot = undefined;
        try w.start(e, o);
        defer w.stop();
        try expectSameAsHost(e, w.url(), &.{ "--rc", "ls / /bin/ls; cat /lib/namespace | wc -l" });
    }
}

test "a ws:// root works with a server that selects no subprotocol [websocket-9p]" {
    const e = try env(@src());
    var w: WsRoot = undefined;
    try w.start(e, .{ .subprotocol = false });
    defer w.stop();
    try expectSameAsHost(e, w.url(), &.{ "/bin/ls", "/" });
}

test "header= is sent, and header=@FILE reads headers from a file [mounts]" {
    const e = try env(@src());
    var w: WsRoot = undefined;
    try w.start(e, .{ .require_header = "Authorization: Bearer s3cret" });
    defer w.stop();
    try expectSameAsHostWith(e, w.url(), "header=Authorization: Bearer s3cret", &.{ "/bin/ls", "/" });
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "headers", .data = "Authorization: Bearer s3cret\n\nX-Other: two\n" });
    const file = try std.fmt.allocPrint(gpa, "header=@{s}/headers", .{s.path});
    defer gpa.free(file);
    try expectSameAsHostWith(e, w.url(), file, &.{ "/bin/ls", "/" });
    try std.testing.expectEqualStrings("two", w.relay.header("X-Other") orelse "");
    // Without it, the server refuses the handshake.
    const r = try run(e, &.{ "--url", w.url(), "/bin/echo" });
    defer r.deinit();
    try std.testing.expectEqual(125, r.code);
    try expectIn(r.err, "server answered 401 Unauthorized");
}

test "a handshake answered with 401 exits 125 with the status [websocket-9p]" {
    const e = try env(@src());
    var rl: wsrelay.Relay = undefined;
    try startEcho(&rl, .{ .status = 401 });
    defer rl.stop();
    const r = try run(e, &.{ "--url", rl.url(), "/bin/echo" });
    defer r.deinit();
    try std.testing.expectEqual(125, r.code);
    var want: [128]u8 = undefined;
    // A browser doesn't say why a WebSocket failed.
    const why = if (onWeb()) "connection failed" else "server answered 401 Unauthorized";
    try expectIn(r.err, try std.fmt.bufPrint(&want, "root {s}: {s}", .{ rl.url(), why }));
}

test "an unreachable ws:// root exits 125 [websocket-9p]" {
    const e = try env(@src());
    var probe = try listenLocal();
    const port = probe.socket.address.getPort();
    probe.deinit(std.testing.io);
    var buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&buf, "ws://127.0.0.1:{d}/9p", .{port});
    const r = try run(e, &.{ "--url", url, "/bin/echo" });
    defer r.deinit();
    try std.testing.expectEqual(125, r.code);
    var want: [128]u8 = undefined;
    const why = if (onWeb()) "connection failed" else "connection refused";
    try expectIn(r.err, try std.fmt.bufPrint(&want, "root {s}: {s}", .{ url, why }));
}

test "a server close makes guest file operations fail [websocket-9p]" {
    const e = try env(@src());
    var it = engineList(e);
    while (it.next()) |engine| {
        errdefer std.debug.print("engine {s}\n", .{engine});
        var w: WsRoot = undefined;
        try w.start(e, .{});
        defer w.stop();
        var t = try spawnTerm(e, engine, &.{ "--url", w.url(), "--timeout", "60s", "--rc", "echo ready; sleep 2; /bin/echo after" });
        defer t.deinit();
        try t.expect("ready", slow(10_000));
        w.relay.hangupAll();
        try std.testing.expect(try t.wait(slow(20_000)) != 0);
    }
}

test "an idle ws:// root pings, and a server that stops answering fails it [websocket-9p]" {
    const e = try env(@src());
    // H9_TEST_KEEPALIVE shortens the keepalive's 30 s idle time to 1 s:
    // h9 pings after 1 s without a frame and fails the connection 1 s
    // after an unanswered ping. The sleeps are a few idle periods long.
    var ka_buf: [16]u8 = undefined;
    const ka = try std.fmt.bufPrint(&ka_buf, "{d}", .{slow(1000)});
    var cmd_buf: [64]u8 = undefined;
    {
        var w: WsRoot = undefined;
        try w.start(e, .{});
        defer w.stop();
        const cmd = try std.fmt.bufPrint(&cmd_buf, "sleep {d}; /bin/echo still", .{slow(1000) * 4 / 1000});
        const r = try runEnv(e, firstEngine(e), &.{ "--url", w.url(), "--rc", cmd }, &.{.{ "H9_TEST_KEEPALIVE", ka }}, slow(30_000));
        defer r.deinit();
        errdefer std.debug.print("stderr: {s}\n", .{r.err});
        try std.testing.expectEqual(0, r.code);
        try std.testing.expectEqualStrings("still\n", r.out);
        try std.testing.expect(w.relay.pings.load(.acquire) >= 2);
    }
    {
        var w: WsRoot = undefined;
        try w.start(e, .{ .no_pong = true });
        defer w.stop();
        const cmd = try std.fmt.bufPrint(&cmd_buf, "sleep {d}; /bin/echo still", .{slow(1000) * 6 / 1000});
        const r = try runEnv(e, firstEngine(e), &.{ "--url", w.url(), "--rc", cmd }, &.{.{ "H9_TEST_KEEPALIVE", ka }}, slow(30_000));
        defer r.deinit();
        errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
        try std.testing.expect(r.code != 0);
        try std.testing.expect(std.mem.indexOf(u8, r.out, "still") == null);
        try std.testing.expect(w.relay.pings.load(.acquire) >= 1);
    }
}

test "a ws:// root goes through HTTP_PROXY with CONNECT, and NO_PROXY skips it [websocket-9p]" {
    const e = try env(@src());
    var w: WsRoot = undefined;
    try w.start(e, .{});
    defer w.stop();
    var p: wsrelay.Proxy = undefined;
    try p.start(std.testing.io, null);
    const via = try runEnv(e, firstEngine(e), &.{ "--url", w.url(), "/bin/ls", "/bin/ls" }, &.{.{ "HTTP_PROXY", p.url() }}, 30_000);
    defer via.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{via.err});
    try std.testing.expectEqual(0, via.code);
    try std.testing.expectEqualStrings("/bin/ls\n", via.out);
    try std.testing.expectEqual(1, p.connects.load(.acquire));
    const direct = try runEnv(e, firstEngine(e), &.{ "--url", w.url(), "/bin/ls", "/bin/ls" }, &.{ .{ "http_proxy", p.url() }, .{ "NO_PROXY", "localhost,127.0.0.1" } }, 30_000);
    defer direct.deinit();
    try std.testing.expectEqual(0, direct.code);
    try std.testing.expectEqual(1, p.connects.load(.acquire));
}

test "a proxy answering 407 exits 125 with the status [websocket-9p]" {
    const e = try env(@src());
    var p: wsrelay.Proxy = undefined;
    try p.start(std.testing.io, 407);
    const r = try runEnv(e, firstEngine(e), &.{ "--url", "ws://127.0.0.1:1/9p", "/bin/echo" }, &.{.{ "HTTP_PROXY", p.url() }}, 30_000);
    defer r.deinit();
    try std.testing.expectEqual(125, r.code);
    try expectIn(r.err, "root ws://127.0.0.1:1/9p: proxy answered 407 Proxy Authentication Required");
}

test "a /net/ws connect ignores HTTP_PROXY [websocket-9p]" {
    const e = try env(@src());
    var rl: wsrelay.Relay = undefined;
    try startEcho(&rl, .{});
    defer rl.stop();
    var p: wsrelay.Proxy = undefined;
    try p.start(std.testing.io, null);
    var cmd: [512]u8 = undefined;
    const r = try runEnv(e, firstEngine(e), &.{ "--rc", try rcWs(&cmd, rl.url(), "", "echo hi >/net/ws/$n/data && read </net/ws/$n/data") }, &.{.{ "HTTP_PROXY", p.url() }}, 30_000);
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("hi\n", r.out);
    try std.testing.expectEqual(0, p.connects.load(.acquire));
}

test "ca= with a ws:// root is a usage error [mounts]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ca.pem", .data = "" });
    const ca = try std.fs.path.join(gpa, &.{ s.path, "ca.pem" });
    defer gpa.free(ca);
    var ub: [512]u8 = undefined;
    var ob: [512]u8 = undefined;
    const r = try run(e, &.{ "--url", urlOpts(&ub, "ws://127.0.0.1:1/9p", try std.fmt.bufPrint(&ob, "ca={s}", .{ca})), "/bin/echo" });
    defer r.deinit();
    try std.testing.expectEqual(2, r.code);
    try expectIn(r.err, "ca= is for wss and https URLs");
}

test "a note interrupts a read waiting on a ws:// root [websocket-9p]" {
    const e = try env(@src());
    var it = engineList(e);
    while (it.next()) |engine| {
        errdefer std.debug.print("engine {s}\n", .{engine});
        var w: WsRoot = undefined;
        try w.start(e, .{});
        defer w.stop();
        var t = try spawnTerm(e, engine, &.{ "--url", w.url(), "--timeout", "60s", "rc", "-i" });
        defer t.deinit();
        try t.expect(prompt, slow(10_000));
        // The server stops answering, so the exec's reads wait.
        w.relay.paused.store(true, .release);
        try t.send("cat /lib/namespace" ++ enter);
        try t.drain(slow(500));
        try t.send("\x03");
        try t.drain(slow(500));
        w.relay.paused.store(false, .release);
        try t.expect(prompt, slow(10_000));
        try t.send("echo x^y" ++ enter);
        try t.expect("xy", slow(10_000));
        try t.send("exit" ++ enter);
        _ = try t.wait(slow(10_000));
    }
}

test "a namespace file mounts a ws:// URL [websocket-9p]" {
    const e = try env(@src());
    var w: WsRoot = undefined;
    try w.start(e, .{});
    defer w.stop();
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var ns: [128]u8 = undefined;
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ns", .data = try std.fmt.bufPrint(&ns, "mount -c '{s}?k=v' /n\n", .{w.url()}) });
    const r = try run(e, &.{ "--cwd", s.path, "--ns", s.ns(), "/bin/ls", "/n/rc/bin/lc" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("/n/rc/bin/lc\n", r.out);
    try std.testing.expectEqualStrings("/9p?k=v", w.relay.target());
    // Under --write=none, the mount can't be kept read-only.
    const none = try run(e, &.{ "--cwd", s.path, "--ns", s.ns(), "--write=none", "/bin/echo" });
    defer none.deinit();
    try std.testing.expectEqual(125, none.code);
    try expectIn(none.err, "--write=none can't be enforced on a WebSocket mount");
}

test "a host-made stream isn't reachable through /net/ws or an attach spec [websocket-9p]" {
    const e = try env(@src());
    var w: WsRoot = undefined;
    try w.start(e, .{});
    defer w.stop();
    const r = try run(e, &.{ "--url", w.url(), "--rc", "ls /net/ws; for(i in 0 1 2 256 257) ls '#ℏ'$i >[2]/dev/null && echo reached $i; echo done" });
    defer r.deinit();
    try std.testing.expectEqualStrings("/net/ws/clone\ndone\n", r.out);
}

test "the guest connects /net/ws and mounts its data [websocket-9p]" {
    const e = try env(@src());
    var w: WsRoot = undefined;
    try w.start(e, .{});
    defer w.stop();
    var cmd: [512]u8 = undefined;
    const snippet = try std.fmt.bufPrint(&cmd, "mkdir /tmp/fs && {{ n=`{{read}}; echo connect {s} 9p >/net/ws/$n/ctl; mount -c /net/ws/$n/data /tmp/fs }} <>/net/ws/clone && ls /tmp/fs/rc/bin/lc", .{w.url()});
    const r = try run(e, &.{ "--rc", snippet });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("/tmp/fs/rc/bin/lc\n", r.out);
}

test "wsmount mounts a ws:// URL with flags and headers [websocket-9p, guest-tools]" {
    const e = try env(@src());
    var w: WsRoot = undefined;
    try w.start(e, .{ .require_header = "X-Token: t0k" });
    defer w.stop();
    var cmd: [256]u8 = undefined;
    const r = try run(e, &.{ "--rc", try std.fmt.bufPrint(&cmd, "mkdir /tmp/fs && wsmount -c -h 'X-Token: t0k' {s} /tmp/fs && ls /tmp/fs/rc/bin/lc", .{w.url()}) });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("/tmp/fs/rc/bin/lc\n", r.out);
}

test "a /net/ws conversation reports its URL and status [websocket-9p]" {
    const e = try env(@src());
    var rl: wsrelay.Relay = undefined;
    try startEcho(&rl, .{});
    defer rl.stop();
    var cmd: [512]u8 = undefined;
    const r = try run(e, &.{ "--rc", try rcWs(&cmd, rl.url(), " 9p", "cat /net/ws/$n/remote /net/ws/$n/status; echo hangup >/net/ws/$n/ctl; cat /net/ws/$n/status") });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    var want: [256]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&want, "{s}\nEstablished 9p\nClosed 1000 \n", .{rl.url()}), r.out);
}

test "a guest WebSocket mount can be posted to /srv and mounted again [websocket-9p]" {
    const e = try env(@src());
    var w: WsRoot = undefined;
    try w.start(e, .{});
    defer w.stop();
    var post: [256]u8 = undefined;
    var cmd: [512]u8 = undefined;
    const body = "{ echo 5 >/srv/wsfs } <>[5] /net/ws/$n/data";
    const r = try run(e, &.{ "--rc", try std.fmt.bufPrint(&cmd, "{s} && mkdir /tmp/a /tmp/b && mount -c /srv/wsfs /tmp/a && mount -c /srv/wsfs /tmp/b && ls /tmp/a/rc/bin/lc /tmp/b/rc/bin/lc", .{try rcWs(&post, w.url(), " 9p", body)}) });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("/tmp/a/rc/bin/lc\n/tmp/b/rc/bin/lc\n", r.out);
}

test "header in ctl is sent with the handshake [websocket-9p]" {
    const e = try env(@src());
    var rl: wsrelay.Relay = undefined;
    try startEcho(&rl, .{ .require_header = "X-Token: t0k" });
    defer rl.stop();
    var cmd: [512]u8 = undefined;
    const r = try run(e, &.{ "--rc", try std.fmt.bufPrint(&cmd, "{{ n=`{{read}}; echo header X-Token: t0k >/net/ws/$n/ctl; echo connect {s} >/net/ws/$n/ctl && echo ok }} <>/net/ws/clone", .{rl.url()}) });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("ok\n", r.out);
    try std.testing.expectEqualStrings("t0k", rl.header("X-Token") orelse "");
    // A header that changes the handshake is refused.
    const bad = try run(e, &.{ "--rc", "{ n=`{read}; echo header Upgrade: no >/net/ws/$n/ctl } <>/net/ws/clone" });
    defer bad.deinit();
    try std.testing.expect(bad.code != 0);
}

/// Reads one text message from conversation $n, as rc runs it.
const read_text = "dd -bs 8192 -count 1 </net/ws/$n/text >[2]/dev/null; echo";

test "text writes are sent as text messages and text reads return one message each [websocket-9p]" {
    const e = try env(@src());
    var rl: wsrelay.Relay = undefined;
    try startEcho(&rl, .{});
    defer rl.stop();
    var cmd: [512]u8 = undefined;
    const r = try run(e, &.{ "--rc", try rcWs(&cmd, rl.url(), "", "echo -n hello >/net/ws/$n/text; echo -n 'two words' >/net/ws/$n/text; " ++ read_text ++ "; " ++ read_text) });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("hello\ntwo words\n", r.out);
}

test "a text read with a short buffer fails and leaves the message queued [websocket-9p]" {
    const e = try env(@src());
    var rl: wsrelay.Relay = undefined;
    try startEcho(&rl, .{});
    defer rl.stop();
    var cmd: [512]u8 = undefined;
    const r = try run(e, &.{ "--rc", try rcWs(&cmd, rl.url(), "", "echo -n hello >/net/ws/$n/text; dd -bs 2 -count 1 </net/ws/$n/text; " ++ read_text) });
    defer r.deinit();
    try expectIn(r.err, "message too long");
    try std.testing.expect(std.mem.endsWith(u8, r.out, "hello\n"));
}

test "a text write that isn't valid utf-8 fails and sends nothing [websocket-9p]" {
    const e = try env(@src());
    var rl: wsrelay.Relay = undefined;
    try startEcho(&rl, .{});
    defer rl.stop();
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bad", .data = "a\xff\xfeb" });
    var cmd: [512]u8 = undefined;
    const r = try run(e, &.{ "--cwd", s.path, "--rc", try rcWs(&cmd, rl.url(), "", "cat bad >/net/ws/$n/text; echo -n ok >/net/ws/$n/text; " ++ read_text) });
    defer r.deinit();
    try expectIn(r.err, "invalid utf-8");
    try std.testing.expectEqualStrings("ok\n", r.out);
}

test "text from the server doesn't appear on data, nor binary on text [websocket-9p]" {
    const e = try env(@src());
    var rl: wsrelay.Relay = undefined;
    try startEcho(&rl, .{ .send_text = "greeting" });
    defer rl.stop();
    var cmd: [512]u8 = undefined;
    const r = try run(e, &.{ "--rc", try rcWs(&cmd, rl.url(), "", "echo bin >/net/ws/$n/data; read </net/ws/$n/data; " ++ read_text) });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("bin\ngreeting\n", r.out);
}

test "a ws:// root fails on a text message from the server [websocket-9p]" {
    const e = try env(@src());
    var w: WsRoot = undefined;
    try w.start(e, .{ .send_text = "hello" });
    defer w.stop();
    const r = try run(e, &.{ "--url", w.url(), "/bin/echo" });
    defer r.deinit();
    try std.testing.expectEqual(125, r.code);
    var want: [128]u8 = undefined;
    try expectIn(r.err, try std.fmt.bufPrint(&want, "root {s}: ", .{w.url()}));
}

test "--net=disable leaves /net/ws unbound and #ℏ masked [websocket-9p]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--net=disable", "--rc", "ls /net/ws >[2]/dev/null || echo unbound; ls '#ℏ' >[2]/dev/null || echo masked" });
    defer r.deinit();
    try std.testing.expectEqualStrings("unbound\nmasked\n", r.out);
}

test "--net-allow refuses a /net/ws connect to a host it doesn't cover [websocket-9p]" {
    const e = try env(@src());
    var rl: wsrelay.Relay = undefined;
    try startEcho(&rl, .{});
    defer rl.stop();
    var cmd: [512]u8 = undefined;
    const r = try run(e, &.{ "--net-allow", "tcp!10.0.0.0/8!*", "--rc", try rcWs(&cmd, rl.url(), "", "echo connected") });
    defer r.deinit();
    try expectIn(r.err, "permission denied");
    try std.testing.expectEqualStrings("", r.out);
    try std.testing.expectEqual(0, rl.accepted.load(.acquire));
}

test "--net-allow refuses a name before it's resolved [websocket-9p]" {
    const e = try env(@src());
    var rl: wsrelay.Relay = undefined;
    try startEcho(&rl, .{});
    defer rl.stop();
    var url: [64]u8 = undefined;
    var cmd: [512]u8 = undefined;
    // The pattern names an address, not localhost, so the name isn't
    // looked up at all.
    const r = try run(e, &.{ "--net-allow", "tcp!127.0.0.1!80", "--rc", try rcWs(&cmd, try std.fmt.bufPrint(&url, "ws://localhost:{d}/", .{rl.port}), "", "echo connected") });
    defer r.deinit();
    try expectIn(r.err, "permission denied");
    try std.testing.expectEqual(0, rl.accepted.load(.acquire));
}

test "a /net/ws connect to a link-local address is refused without patterns [websocket-9p]" {
    const e = try env(@src());
    var cmd: [512]u8 = undefined;
    const c = try rcWs(&cmd, "ws://169.254.169.254/", "", "echo connected");
    for ([_][]const u8{ "--net=outbound", "--net=enable" }) |mode| {
        const r = try run(e, &.{ mode, "--rc", c });
        defer r.deinit();
        try expectIn(r.err, "permission denied");
        try std.testing.expect(r.code != 0);
    }
}

test "a note interrupts a /net/ws connect [websocket-9p]" {
    const e = try env(@src());
    // It takes the TCP connection but never answers the handshake.
    var srv = try listenLocal();
    defer srv.deinit(std.testing.io);
    var url: [64]u8 = undefined;
    var cmd: [512]u8 = undefined;
    const c = try rcWs(&cmd, try std.fmt.bufPrint(&url, "ws://127.0.0.1:{d}/", .{srv.socket.address.getPort()}), "", "echo connected");
    var it = engineList(e);
    while (it.next()) |engine| {
        errdefer std.debug.print("engine {s}\n", .{engine});
        var t = try spawnTerm(e, engine, &.{ "--timeout", "60s", "rc", "-i" });
        defer t.deinit();
        try t.expect(prompt, slow(10_000));
        try t.send(c);
        try t.send(enter);
        try t.drain(slow(1000));
        try t.send("\x03");
        try t.expect(prompt, slow(10_000));
        try t.send("echo x^y" ++ enter);
        try t.expect("xy", slow(10_000));
        try t.send("exit" ++ enter);
        _ = try t.wait(slow(10_000));
    }
}

test "a machine can't open more than 32 conversations [websocket-9p]" {
    const e = try env(@src());
    for ([_]u32{ 32, 33 }) |count| {
        var cmd: std.ArrayList(u8) = .empty;
        defer cmd.deinit(gpa);
        try cmd.appendSlice(gpa, "{ ls /net/ws | wc -l }");
        for (0..count) |i| try cmd.print(gpa, " <>[{d}] /net/ws/clone", .{i + 3});
        const r = try run(e, &.{ "--rc", cmd.items });
        defer r.deinit();
        if (count == 32) {
            try std.testing.expectEqual(0, r.code);
            try std.testing.expectEqualStrings("33", std.mem.trim(u8, r.out, " \t\n"));
        } else {
            try std.testing.expect(r.code != 0);
            try expectIn(r.err, "no free devices");
        }
    }
}

test "--print elides a ws:// root's query and header values [websocket-9p]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--url", "ws://127.0.0.1:1/9p?token=s3cret:/:header=Authorization: Bearer s3cret", "--print", "ls" });
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try expectIn(r.out, "# ws://127.0.0.1:1/9p?…  (Authorization: …)");
    try expectIn(r.out, "bind -a '#ℏ' /net");
    try std.testing.expect(std.mem.indexOf(u8, r.out, "s3cret") == null);
}

test "--write=none with a ws:// root is a usage error [websocket-9p]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--url", "ws://127.0.0.1:1/9p", "--write=none", "/bin/echo" });
    defer r.deinit();
    try std.testing.expectEqual(2, r.code);
    try expectIn(r.err, "--write=none can't be enforced on a WebSocket root");
}

// schemeless-roots: a --url or $H9ROOT without a scheme.

/// Runs `h9 args...` on the first engine without the case's root, in
/// `cwd` (if not null), with `vars` added to the environment.
fn runBare(e: Env, cwd: ?[]const u8, args: []const []const u8, vars: []const [2][]const u8) !Result {
    var map = try std.testing.environ.createMap(gpa);
    defer map.deinit();
    for (vars) |v| try map.put(v[0], v[1]);
    var h9_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.cwd().realPathFile(std.testing.io, e.h9, &h9_buf);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ h9_buf[0..n], "--engine", firstEngine(e) });
    if (e.arch) |a| try argv.appendSlice(gpa, &.{ "--arch", a });
    try argv.appendSlice(gpa, args);
    const io = std.testing.io;
    const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(slow(30_000)), .clock = .awake } };
    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .environ_map = &map,
        .cwd = if (cwd) |c| .{ .path = c } else .inherit,
        .create_no_window = true,
    });
    defer child.kill(io);
    var mr_buf: std.Io.File.MultiReader.Buffer(2) = undefined;
    var mr: std.Io.File.MultiReader = undefined;
    mr.init(gpa, io, mr_buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();
    while (mr.fill(64, timeout)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => |x| return x,
    }
    try mr.checkAnyError();
    const term = try child.wait(io);
    const out = try mr.toOwnedSlice(0);
    errdefer gpa.free(out);
    const err_out = try mr.toOwnedSlice(1);
    const code = switch (term) {
        .exited => |c| c,
        else => {
            gpa.free(out);
            gpa.free(err_out);
            return error.Crashed;
        },
    };
    return .{ .code = code, .out = out, .err = err_out };
}

test "a --url without a scheme prints as its wss:// URL [mounts]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--url", "fs.example.com/9p?token=s3cret", "--print", "ls" });
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try expectIn(r.out, "# wss://fs.example.com/9p?…");
    const b = try run(e, &.{ "--url", "fs.example.com", "--print", "ls" });
    defer b.deinit();
    try std.testing.expectEqual(0, b.code);
    try expectIn(b.out, "# wss://fs.example.com/");
}

test "a schemeless loopback root is ws:// and runs /bin/ls [schemeless-roots]" {
    const e = try env(@src());
    var w: WsRoot = undefined;
    try w.start(e, .{});
    defer w.stop();
    const url = w.url();
    try std.testing.expect(std.mem.startsWith(u8, url, "ws://127.0.0.1:"));
    try expectSameAsHost(e, url["ws://".len..], &.{ "/bin/ls", "/" });
}

test "a --dir with a dotted name is a host directory, not a URL [mounts]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.cwd().realPathFile(std.testing.io, e.root, &root_buf);
    try symLinkOrSkip(s.tmp.dir, std.testing.io, root_buf[0..n], "fs.example.com", .{ .is_directory = true });
    const r = try runBare(e, s.path, &.{ "--dir", "fs.example.com", "--print", "ls" }, &.{});
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "wss://") == null);
    const echo = try runBare(e, s.path, &.{ "--dir", "fs.example.com", "/bin/echo", "hi" }, &.{});
    defer echo.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{echo.err});
    try std.testing.expectEqual(0, echo.code);
    try std.testing.expectEqualStrings("hi\n", echo.out);
}

test "an unreachable --url without a scheme exits 125 naming its ws:// URL [mounts]" {
    const e = try env(@src());
    var probe = try listenLocal();
    const port = probe.socket.address.getPort();
    probe.deinit(std.testing.io);
    var buf: [64]u8 = undefined;
    const arg = try std.fmt.bufPrint(&buf, "127.0.0.1:{d}/9p", .{port});
    const r = try run(e, &.{ "--url", arg, "/bin/echo" });
    defer r.deinit();
    try std.testing.expectEqual(125, r.code);
    var want: [160]u8 = undefined;
    const why = if (onWeb()) "connection failed" else "connection refused";
    try expectIn(r.err, try std.fmt.bufPrint(&want, "root ws://{s}: {s}", .{ arg, why }));
}

test "$H9ROOT with :// is read as a --url, and otherwise as a --dir [mounts]" {
    const e = try env(@src());
    const r = try runBare(e, null, &.{ "--print", "ls" }, &.{.{ "H9ROOT", "wss://fs.example.com/9p" }});
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try expectIn(r.out, "# wss://fs.example.com/9p");
    const d = try runBare(e, null, &.{ "--print", "ls" }, &.{.{ "H9ROOT", "fs.example.com/9p" }});
    defer d.deinit();
    try std.testing.expectEqual(125, d.code);
    try expectIn(d.err, "--dir fs.example.com/9p: not found");
}

test "ca= is accepted on a --url without a scheme [mounts]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ca.pem", .data = "" });
    const ca = try std.fs.path.join(gpa, &.{ s.path, "ca.pem" });
    defer gpa.free(ca);
    var ub: [512]u8 = undefined;
    var ob: [512]u8 = undefined;
    const r = try run(e, &.{ "--url", urlOpts(&ub, "fs.example.com/9p", try std.fmt.bufPrint(&ob, "ca={s}", .{ca})), "--print", "ls" });
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try expectIn(r.out, "wss://fs.example.com/9p");
}

test "a missing --dir is not found [mounts]" {
    const e = try env(@src());
    for ([_][]const u8{ "no-such-root", "./9front.img", "fs.example.com/9p" }) |arg| {
        const r = try run(e, &.{ "--dir", arg, "/bin/echo" });
        defer r.deinit();
        try std.testing.expectEqual(125, r.code);
        var want: [96]u8 = undefined;
        try expectIn(r.err, try std.fmt.bufPrint(&want, "--dir {s}: not found", .{arg}));
    }
}

/// H9_TEST_WSS_URL, a wss:// 9P server the host can reach, or a skip.
fn wssUrl(buf: []u8) ![]const u8 {
    const v = getenv(3, "H9_TEST_WSS_URL") orelse return error.SkipZigTest;
    if (v.len > buf.len) return error.SkipZigTest;
    @memcpy(buf[0..v.len], v);
    return buf[0..v.len];
}

// websocket-9p on the web host: the cases above run there too, under
// -Dweb with a native h9 for their servers; these check what's
// particular to it.

test "a ws:// root runs /bin/ls on the web host [websocket-9p, browser-host]" {
    const e = try env(@src());
    if (!onWeb()) return error.SkipZigTest;
    var w: WsRoot = undefined;
    try w.start(e, .{});
    defer w.stop();
    try expectSameAsHost(e, w.url(), &.{ "/bin/ls", "/", "/bin/ls" });
}

test "header= is an error on the web host [mounts, browser-host]" {
    const e = try env(@src());
    if (!onWeb()) return error.SkipZigTest;
    const r = try run(e, &.{ "--url", "ws://127.0.0.1:1/9p:/:header=Authorization: Bearer x", "/bin/echo" });
    defer r.deinit();
    try std.testing.expectEqual(2, r.code);
    try expectIn(r.err, "header= isn't available on the web host");
}

test "the guest mounts a /net/ws conversation on the web host [websocket-9p, browser-host]" {
    const e = try env(@src());
    if (!onWeb()) return error.SkipZigTest;
    var w: WsRoot = undefined;
    try w.start(e, .{});
    defer w.stop();
    var cmd: [512]u8 = undefined;
    const r = try run(e, &.{ "--rc", try rcWs(&cmd, w.url(), " 9p", "mkdir /tmp/fs && mount -c /net/ws/$n/data /tmp/fs && cat /tmp/fs/lib/namespace | wc -l") });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    const host = try run(e, &.{ "--rc", "cat /lib/namespace | wc -l" });
    defer host.deinit();
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings(host.out, r.out);
}

test "text messages round-trip through /net/ws on the web host [websocket-9p, browser-host]" {
    const e = try env(@src());
    if (!onWeb()) return error.SkipZigTest;
    var rl: wsrelay.Relay = undefined;
    try startEcho(&rl, .{});
    defer rl.stop();
    var cmd: [512]u8 = undefined;
    const r = try run(e, &.{ "--rc", try rcWs(&cmd, rl.url(), "", "echo -n héllo >/net/ws/$n/text; " ++ read_text) });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("héllo\n", r.out);
}

// Ports (design/epoch-0/port-streams.md). On the web host under Node, h9-node
// loads tests/web/ports.mjs (H9_NODE_PORTS), whose worker_threads relay
// each port named in H9_TEST_PORTS to a 9P server, one 9P message per
// message, or listen for connections and hand the machine a port for
// each to serve.

/// The ports module, written to a scratch directory for h9-node.
const PortsMod = struct {
    s: Scratch,
    path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined,
    path: []const u8 = "",

    fn init(p: *PortsMod) !void {
        try p.s.init();
        try p.s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ports.mjs", .data = @embedFile("web/ports.mjs") });
        p.path = try std.fmt.bufPrint(&p.path_buf, "{s}/ports.mjs", .{p.s.path});
    }

    fn deinit(p: *PortsMod) void {
        p.s.deinit();
    }
};

/// Runs `h9 args...` on the web host with the ports `spec`
/// (H9_TEST_PORTS), or skips off it.
fn runPorts(e: Env, spec: []const u8, args: []const []const u8) !Result {
    if (!onWeb()) return error.SkipZigTest;
    var pm: PortsMod = undefined;
    try pm.init();
    defer pm.deinit();
    return runEnv(e, firstEngine(e), args, &.{ .{ "H9_NODE_PORTS", pm.path }, .{ "H9_TEST_PORTS", spec } }, slow(60_000));
}

/// `NAME=tcp!127.0.0.1!PORT` and `extra`: a port relayed to `dial`.
fn portSpec(buf: []u8, name: []const u8, dial: []const u8, extra: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}={s}{s}", .{ name, dial, extra }) catch unreachable;
}

test "a port root serves the program [port-streams]" {
    const e = try env(@src());
    if (!onWeb()) return error.SkipZigTest;
    var srv: RootServer = undefined;
    try srv.start(e);
    defer srv.stop();
    var sb: [128]u8 = undefined;
    const host = try run(e, &.{ "/bin/ls", "/", "/bin/ls" });
    defer host.deinit();
    const r = try runPorts(e, portSpec(&sb, "root", srv.dial(), ""), &.{ "--url", "port://root", "/bin/ls", "/", "/bin/ls" });
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings(host.out, r.out);
}

test "a port mounts away from the root, with spec as the attach name [port-streams]" {
    const e = try env(@src());
    if (!onWeb()) return error.SkipZigTest;
    var srv: RootServer = undefined;
    try srv.start(e);
    defer srv.stop();
    var sb: [128]u8 = undefined;
    // exportfs -r / serves the tree whatever the attach name, so the
    // spec shows in the plan and the mount works with it.
    const r = try runPorts(e, portSpec(&sb, "home", srv.dial(), ""), &.{ "--url", "port://home:/n/home:spec=work", "--rc", "cat /n/home/lib/namespace | wc -l" });
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    const want = try run(e, &.{ "--rc", "cat /lib/namespace | wc -l" });
    defer want.deinit();
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings(want.out, r.out);
    const p = try runPorts(e, portSpec(&sb, "home", srv.dial(), ""), &.{ "--url", "port://home:/n/home:spec=work", "--print", "/bin/echo" });
    defer p.deinit();
    try expectIn(p.out, "mount 'port!home' /n/home 'work'");
}

test "a namespace file mounts a port, and --print shows a port mount [port-streams]" {
    const e = try env(@src());
    if (!onWeb()) return error.SkipZigTest;
    var srv: RootServer = undefined;
    try srv.start(e);
    defer srv.stop();
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ns", .data = "mount -c port!home /usr/me\n" });
    var sb: [128]u8 = undefined;
    const r = try runPorts(e, portSpec(&sb, "home", srv.dial(), ""), &.{ "--ns", s.ns(), "--rc", "ls /usr/me/bin/ls" });
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("/usr/me/bin/ls\n", r.out);
    // --print shows a port mount as its dial string, and the line
    // replays in a namespace file.
    const p = try runPorts(e, portSpec(&sb, "home", srv.dial(), ""), &.{ "--url", "port://home:/usr/me", "--print", "/bin/echo" });
    defer p.deinit();
    const at = std.mem.indexOf(u8, p.out, "mount 'port!home' /usr/me ''") orelse {
        std.debug.print("--print:\n{s}\n", .{p.out});
        return error.TestExpectedEqual;
    };
    const end = std.mem.indexOfScalarPos(u8, p.out, at, '\n') orelse p.out.len;
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ns", .data = p.out[at..end] });
    const re = try runPorts(e, portSpec(&sb, "home", srv.dial(), ""), &.{ "--ns", s.ns(), "--rc", "ls /usr/me/bin/ls" });
    defer re.deinit();
    errdefer std.debug.print("replay: stdout: {s}\nstderr: {s}\n", .{ re.out, re.err });
    try std.testing.expectEqualStrings("/usr/me/bin/ls\n", re.out);
}

test "a second mount of the same port is refused [port-streams]" {
    const e = try env(@src());
    if (!onWeb()) return error.SkipZigTest;
    var srv: RootServer = undefined;
    try srv.start(e);
    defer srv.stop();
    var sb: [128]u8 = undefined;
    const r = try runPorts(e, portSpec(&sb, "home", srv.dial(), ""), &.{ "--url", "port://home:/n/a", "--url", "port://home:/n/b", "/bin/echo", "ran" });
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expect(r.code != 0);
    try expectIn(r.err, "port in use");
    try std.testing.expectEqualStrings("", r.out);
}

test "a message that isn't binary closes the stream [port-streams]" {
    const e = try env(@src());
    if (!onWeb()) return error.SkipZigTest;
    var srv: RootServer = undefined;
    try srv.start(e);
    defer srv.stop();
    var sb: [128]u8 = undefined;
    const r = try runPorts(e, portSpec(&sb, "home", srv.dial(), "!text"), &.{ "--url", "port://home:/n/home", "/bin/echo", "ran" });
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expect(r.code != 0);
    try std.testing.expectEqualStrings("", r.out);
}

test "the far end closing hangs up the mount [port-streams]" {
    const e = try env(@src());
    if (!onWeb()) return error.SkipZigTest;
    var srv: RootServer = undefined;
    try srv.start(e);
    defer srv.stop();
    var sb: [128]u8 = undefined;
    // The relay closes its end a second after the server's first answer.
    const r = try runPorts(e, portSpec(&sb, "home", srv.dial(), "!close=1000"), &.{ "--url", "port://home:/n/home", "--rc", "ls /n/home/bin/ls; sleep 3; ls /n/home/bin/ls >[2]/dev/null || echo hungup" });
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqualStrings("/n/home/bin/ls\nhungup\n", r.out);
}

test "the guest mounts a port through /net/port [port-streams]" {
    const e = try env(@src());
    if (!onWeb()) return error.SkipZigTest;
    var srv: RootServer = undefined;
    try srv.start(e);
    defer srv.stop();
    var sb: [128]u8 = undefined;
    const r = try runPorts(e, portSpec(&sb, "home", srv.dial(), ""), &.{ "--rc", "{ n=`{read}; echo open home >/net/port/$n/ctl && cat /net/port/$n/remote /net/port/$n/status && ls /net/port/$n && mkdir -p /tmp/p && mount -c /net/port/$n/data /tmp/p && ls /tmp/p/bin/ls } <>/net/port/clone; echo open nosuch >/net/port/clone || echo refused" });
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqualStrings("port!home\nEstablished\n/net/port/0/ctl\n/net/port/0/data\n/net/port/0/remote\n/net/port/0/status\n/tmp/p/bin/ls\nrefused\n", r.out);
}

test "a 9P2000.L server over a port is translated [port-streams, dotl]" {
    const e = try env(@src());
    if (!onWeb()) return error.SkipZigTest;
    var d: Diod = undefined;
    try d.start(diod_tree);
    defer d.stop();
    var sb: [128]u8 = undefined;
    var ub: [std.Io.Dir.max_path_bytes + 64]u8 = undefined;
    const r = try runPorts(e, portSpec(&sb, "l", d.dial(), ""), &.{ "--url", try std.fmt.bufPrint(&ub, "port://l:/n/l:spec={s}", .{d.s.path}), "--rc", "cat /n/l/etc/motd" });
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("hello from .L\n", r.out);
}

test "a port up layer takes the guest's writes [port-streams, upper-layers]" {
    const e = try env(@src());
    if (!onWeb()) return error.SkipZigTest;
    var d: Diod = undefined;
    try d.start("true");
    defer d.stop();
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try writeTree(&s, &.{ .{ "n/f", "n\n" }, .{ "n/sub/g", "g\n" } });
    var sb: [128]u8 = undefined;
    var pn: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    var pu: [std.Io.Dir.max_path_bytes + 64]u8 = undefined;
    const r = try runPorts(e, portSpec(&sb, "layer", d.dial(), ""), &.{
        "--dir", try std.fmt.bufPrint(&pn, "{s}/n:/n/x", .{s.path}),
        "--url", try std.fmt.bufPrint(&pu, "port://layer:/n/x:up,spec={s}", .{d.s.path}),
        "--rc",  "echo w >>/n/x/f; rm /n/x/sub/g; cat /n/x/f; ls /n/x/sub | wc -l",
    });
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqualStrings("n\nw\n      0\n", r.out);
    try std.testing.expect(d.s.exists("f"));
    try std.testing.expect(d.s.exists("sub/.wh.g"));
    try expectFile(&s, "n/f", "n\n");
}

/// Starts h9 on the web host served on ports, with a relay listening on
/// a loopback port for clients (`serve=` in H9_TEST_PORTS), running a
/// program that waits; returns the port.
fn startServedPorts(e: Env, pm: *PortsMod, t: *Term, extra: []const u8) !u16 {
    if (!onWeb()) return error.SkipZigTest;
    var probe = try listenLocal();
    const port = probe.socket.address.getPort();
    probe.deinit(std.testing.io);
    try pm.init();
    errdefer pm.deinit();
    var nb: [std.Io.Dir.max_path_bytes + 32]u8 = undefined;
    var sb: [128]u8 = undefined;
    t.* = try spawnTermEnv(e, firstEngine(e), &.{ "--rc", "echo ready; sleep 60" }, &.{
        try std.fmt.bufPrint(&nb, "H9_NODE_PORTS={s}", .{pm.path}),
        try std.fmt.bufPrint(&sb, "H9_TEST_PORTS=serve=tcp!127.0.0.1!{d}{s}", .{ port, extra }),
    });
    errdefer t.deinit();
    try t.expect("ready", slow(30_000));
    return port;
}

/// Runs the native h9 (H9_TEST_SERVER) with the web machine served on
/// `port` mounted at /n/web, and rc `cmd`.
fn runServedClient(e: Env, port: u16, cmd: []const u8) !Result {
    const native = getenv(6, "H9_TEST_SERVER") orelse return error.SkipZigTest;
    var ub: [64]u8 = undefined;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ native, "--engine", "auto", "--dir", e.root });
    if (e.arch) |a| try argv.appendSlice(gpa, &.{ "--arch", a });
    try argv.appendSlice(gpa, &.{ "--url", try std.fmt.bufPrint(&ub, "tcp://127.0.0.1:{d}:/n/web", .{port}), "--rc", cmd });
    const r = try runProcessWith(argv.items, null, null, slow(60_000));
    const code = switch (r.term) {
        .exited => |c| c,
        else => {
            gpa.free(r.stdout);
            gpa.free(r.stderr);
            return error.Crashed;
        },
    };
    return .{ .code = code, .out = r.stdout, .err = r.stderr };
}

test "a served port leaves out /net [port-streams]" {
    const e = try env(@src());
    var pm: PortsMod = undefined;
    var t: Term = undefined;
    const port = try startServedPorts(e, &pm, &t, "");
    defer pm.deinit();
    defer t.deinit();
    const r = try runServedClient(e, port, "ls /n/web/bin/ls; test -d /n/web/net/port || echo no net");
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("/n/web/bin/ls\nno net\n", r.out);
}

test "a served port exports /net with serveNet [port-streams]" {
    const e = try env(@src());
    var pm: PortsMod = undefined;
    var t: Term = undefined;
    const port = try startServedPorts(e, &pm, &t, "!net");
    defer pm.deinit();
    defer t.deinit();
    const r = try runServedClient(e, port, "test -d /n/web/net/port && echo net");
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqualStrings("net\n", r.out);
}

test "port!x and port://x are refused on a native host [port-streams]" {
    const e = try env(@src());
    if (onWeb()) return error.SkipZigTest;
    const u = try run(e, &.{ "--url", "port://x:/n/x", "/bin/echo", "ran" });
    defer u.deinit();
    try std.testing.expectEqual(2, u.code);
    try expectIn(u.err, "ports are only on the web host");
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ns", .data = "mount port!x /n/x\n" });
    const n = try run(e, &.{ "--ns", s.ns(), "/bin/echo", "ran" });
    defer n.deinit();
    try std.testing.expect(n.code != 0);
    try expectIn(n.err, "unknown network port");
    const g = try run(e, &.{ "--rc", "ls /net/port >[2]/dev/null || echo none" });
    defer g.deinit();
    try std.testing.expectEqualStrings("none\n", g.out);
}

test "--net=outbound binds only /net/ws on the web host [websocket-9p, browser-host]" {
    const e = try env(@src());
    if (!onWeb()) return error.SkipZigTest;
    const r = try run(e, &.{ "--net=outbound", "--rc", "ls /net; ls '#I' >[2]/dev/null || echo no ip" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("/net/dotl\n/net/port\n/net/ws\nno ip\n", r.out);
    const p = try run(e, &.{ "--net=outbound", "--print", "/bin/echo" });
    defer p.deinit();
    try expectIn(p.out, "bind '#ℏ' /net");
}

test "a wss:// root runs /bin/ls [websocket-9p]" {
    const e = try env(@src());
    var buf: [1024]u8 = undefined;
    const url = try wssUrl(&buf);
    if (getenv(3, "H9_TEST_WSS_CA") != null) return error.SkipZigTest; // the next case's
    const r = try run(e, &.{ "--url", url, "/bin/ls", "/bin/ls" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("/bin/ls\n", r.out);
}

test "ca= trusts a private CA, and the host bundle doesn't [mounts]" {
    const e = try env(@src());
    var buf: [1024]u8 = undefined;
    const url = try wssUrl(&buf);
    var ca_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const v = getenv(3, "H9_TEST_WSS_CA") orelse return error.SkipZigTest;
    @memcpy(ca_buf[0..v.len], v);
    const ca = ca_buf[0..v.len];
    var ub: [2048]u8 = undefined;
    var ob: [1024]u8 = undefined;
    const ok = try run(e, &.{ "--url", urlOpts(&ub, url, try std.fmt.bufPrint(&ob, "ca={s}", .{ca})), "/bin/ls", "/bin/ls" });
    defer ok.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{ok.err});
    try std.testing.expectEqual(0, ok.code);
    const refused = try run(e, &.{ "--url", url, "/bin/echo" });
    defer refused.deinit();
    try std.testing.expectEqual(125, refused.code);
    try expectIn(refused.err, "certificate: unknown authority");
}

// 9box, the multi-call binary (design/epoch-0/multicall.md). The tree comes from
// `zig build slim`, in .local/9front/slim-*, whose path the build passes as
// H9_TEST_SLIM_ROOT; the cases skip without it. They run with `--root`
// after the test root's.

/// The slim tree from H9_TEST_SLIM_ROOT, or a skip if it hasn't been built.
fn slimTree(e: Env) ![]const u8 {
    const t = getenv(5, "H9_TEST_SLIM_ROOT") orelse return error.SkipZigTest;
    var buf: [64]u8 = undefined;
    const box = try std.fmt.bufPrint(&buf, "{s}/bin/9box", .{e.arch orelse "arm64"});
    var pbuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const p = try std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ t, box });
    std.Io.Dir.cwd().access(std.testing.io, p, .{}) catch return error.SkipZigTest;
    return t;
}

/// Runs `args` with the host tree `tree` on `/`, its symlinks
/// resolving inside it.
fn runContained(e: Env, tree: []const u8, args: []const []const u8) !Result {
    var buf: [std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    return runRoot(e, try std.fmt.bufPrint(&buf, "{s}:/:contained", .{tree}), args);
}

/// Host path `p` as #U names it: as is, or on Windows "/C:/x" for "C:\x".
fn kernPath(out: []u8, p: []const u8) []const u8 {
    if (builtin.os.tag != .windows) {
        @memcpy(out[0..p.len], p);
        return out[0..p.len];
    }
    out[0] = '/';
    for (p, out[1 .. p.len + 1]) |c, *o| o.* = if (c == '\\') '/' else c;
    if (p.len >= 2 and p[1] == ':') out[1] = std.ascii.toUpper(out[1]);
    return out[0 .. p.len + 1];
}

/// Runs `args` with the root `root`.
fn runRoot(e: Env, root: []const u8, args: []const []const u8) !Result {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &rootFlag(root));
    try argv.appendSlice(gpa, args);
    return run(e, argv.items);
}

/// Runs `args` in the tree `root` and in the stock tree, and checks that
/// both give the same output, errors and exit code.
fn expectSameAsStock(e: Env, root: []const u8, args: []const []const u8) !void {
    const stock = try run(e, args);
    defer stock.deinit();
    const r = try runRoot(e, root, args);
    defer r.deinit();
    errdefer std.debug.print("in {s}: {s}\nstdout: {s}\nstderr: {s}\nstock stdout: {s}\nstock stderr: {s}\n", .{ root, args[args.len - 1], r.out, r.err, stock.out, stock.err });
    try std.testing.expectEqualStrings(stock.out, r.out);
    try std.testing.expectEqualStrings(stock.err, r.err);
    try std.testing.expectEqual(stock.code, r.code);
}

test "9box runs a command through a hard link [multicall]" {
    const e = try env(@src());
    const slim = try slimTree(e);
    // The tree's commands are hard links to 9box, unless it was built with
    // -Dslim-links=stub.
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const ls = try std.fmt.bufPrint(&buf, "{s}/{s}/bin/ls", .{ slim, e.arch orelse "arm64" });
    const st = try std.Io.Dir.cwd().statFile(std.testing.io, ls, .{});
    if (st.nlink <= 2) return error.SkipZigTest;
    try expectSameAsStock(e, slim, &.{ "/bin/ls", "-d", "/rc/lib", "/adm" });
    try expectSameAsStock(e, slim, &.{ "--rc", "echo hello world | wc; echo a b | sed 's/a/x/'" });
}

test "9box runs a command through a #! stub [multicall]" {
    const e = try env(@src());
    const slim = try slimTree(e);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const x: std.Io.Dir.CreateFileOptions = .{ .permissions = .executable_file };
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ls", .data = "#!/bin/9box -!\n", .flags = x });
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "nope", .data = "#!/bin/9box -!\n", .flags = x });
    const r = try runRoot(e, slim, &.{ "--cwd", s.path, "/mnt/term/cwd/ls", "-d", "/rc/lib", "/adm" });
    defer r.deinit();
    try std.testing.expectEqualStrings("/adm\n/rc/lib\n", r.out);
    try std.testing.expectEqual(0, r.code);
    // By hard link, a first argument of -! that isn't followed by a stub is
    // the command's own: echo prints it.
    const echo = try runRoot(e, slim, &.{ "--cwd", s.path, "/bin/echo", "-!", "/mnt/term/cwd", "x" });
    defer echo.deinit();
    try std.testing.expectEqualStrings("-! /mnt/term/cwd x\n", echo.out);
    // A stub for a command the box doesn't have.
    const no = try runRoot(e, slim, &.{ "--cwd", s.path, "/mnt/term/cwd/nope" });
    defer no.deinit();
    try std.testing.expectEqual(1, no.code);
    try expectIn(no.err, "9box: no command nope");
}

test "an rc script runs when /bin/rc is a stub [multicall]" {
    const e = try env(@src());
    const slim = try slimTree(e);
    const io = std.testing.io;
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    // A /bin of its own, bound before the tree's: a copy of 9box and an rc
    // stub. Not a bind over the tree's /bin/rc, which is a hard link to
    // 9box: hard links share a qid, so that bind would cover every
    // command, 9box included.
    const x: std.Io.Dir.CreateFileOptions = .{ .permissions = .executable_file };
    try s.tmp.dir.createDirPath(io, "bin");
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const box = try std.fmt.bufPrint(&buf, "{s}/{s}/bin/9box", .{ slim, e.arch orelse "arm64" });
    try std.Io.Dir.cwd().copyFile(box, s.tmp.dir, "bin/9box", io, .{});
    try s.tmp.dir.writeFile(io, .{ .sub_path = "bin/rc", .data = "#!/bin/9box -!\n", .flags = x });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "greet", .data = "#!/bin/rc\necho $0 $*\n", .flags = x });
    // The script's #! runs the stub, which runs 9box with
    // greet -! /bin/rc /mnt/term/cwd/greet a b, and rc gets what it would
    // as the interpreter itself.
    const script = "bind -b /mnt/term/cwd/bin /bin && /mnt/term/cwd/greet a b";
    const r = try runRoot(e, slim, &.{ "--cwd", s.path, "--rc", script });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("/mnt/term/cwd/greet a b\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "an rc script runs when /bin/rc is a hard link [multicall]" {
    const e = try env(@src());
    const slim = try slimTree(e);
    const io = std.testing.io;
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const x: std.Io.Dir.CreateFileOptions = .{ .permissions = .executable_file };
    try s.tmp.dir.writeFile(io, .{ .sub_path = "greet", .data = "#!/bin/rc\necho $0 $*\n", .flags = x });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "strict", .data = "#!/bin/rc -e\necho strict $*\n", .flags = x });
    // exec of greet runs 9box as greet /mnt/term/cwd/greet a b, a name
    // that isn't a command, so 9box runs the #! line's rc.
    const r = try runRoot(e, slim, &.{ "--cwd", s.path, "--rc", "/mnt/term/cwd/greet a b; /mnt/term/cwd/strict c" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("/mnt/term/cwd/greet a b\nstrict c\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "lc columnates a directory in the slim tree [multicall]" {
    const e = try env(@src());
    const slim = try slimTree(e);
    const r = try runRoot(e, slim, &.{ "--rc", "lc /rc" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("bin/ lib/\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "9box CMD ARGS and an unknown command [multicall]" {
    const e = try env(@src());
    const slim = try slimTree(e);
    const r = try runRoot(e, slim, &.{ "/bin/9box", "echo", "a", "b" });
    defer r.deinit();
    try std.testing.expectEqualStrings("a b\n", r.out);
    const list = try runRoot(e, slim, &.{"/bin/9box"});
    defer list.deinit();
    try std.testing.expectEqual(0, list.code);
    try expectIn(list.out, "\nls\n");
    try expectIn(list.out, "\nramfs\n");
    const no = try runRoot(e, slim, &.{ "/bin/9box", "nope", "x" });
    defer no.deinit();
    try std.testing.expectEqual(1, no.code);
    try expectIn(no.err, "9box: no command nope");
    try expectIn(no.err, "no command nope");
}

test "ramfs runs from the box [multicall]" {
    const e = try env(@src());
    const slim = try slimTree(e);
    const r = try runRoot(e, slim, &.{ "--rc", "ramfs -m /n && echo inram >/n/f && ls /n && cat /n/f" });
    defer r.deinit();
    try std.testing.expectEqualStrings("/n/f\ninram\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "argv0 is the command's own name [multicall]" {
    const e = try env(@src());
    const slim = try slimTree(e);
    // Usage lines print argv0, which ARGBEGIN sets from the command's argv;
    // rc initialises argv0, which mustn't leak into the others.
    for ([_][]const u8{ "ls", "cat", "tee", "sort", "srvfs", "ramfs", "grep", "rc" }) |c| {
        var buf: [64]u8 = undefined;
        try expectSameAsStock(e, slim, &.{ "--rc", try std.fmt.bufPrint(&buf, "{s} -Z </dev/null >[2=1] | sed 1q", .{c}) });
    }
}

/// The corpus, run in `tree` and in the stock tree over the commands the
/// tree's 9box has, compared.
fn expectCorpus(e: Env, tree: []const u8) !void {
    const list = try runRoot(e, tree, &.{"/bin/9box"});
    defer list.deinit();
    try std.testing.expectEqual(0, list.code);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "corpus.rc", .data = @embedFile("fixtures/multicall/corpus.rc") });
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(gpa);
    try args.appendSlice(gpa, &.{ "--cwd", s.path, "rc", "/mnt/term/cwd/corpus.rc" });
    var it = std.mem.tokenizeScalar(u8, list.out, '\n');
    while (it.next()) |c| try args.append(gpa, c);
    try expectSameAsStock(e, tree, args.items);
}

test "each boxed command matches its stock binary on the corpus [multicall]" {
    const e = try env(@src());
    try expectCorpus(e, try slimTree(e));
}

test "a 9P root serving 9box under every name [multicall]" {
    const e = try env(@src());
    const slim = try slimTree(e);
    // exportfs serves the slim tree's hard links as they are: 9box's bytes
    // under every name.
    var srv: RootServer = undefined;
    try srv.startTree(e, slim);
    defer srv.stop();
    const args: []const []const u8 = &.{ "--rc", "ls /bin/9box /bin/sed; echo a b | sed s/a/x/; 9box echo boxed" };
    const host = try runRoot(e, slim, args);
    defer host.deinit();
    const r = try runRoot(e, srv.dial(), args);
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings(host.out, r.out);
    try std.testing.expectEqualStrings("/bin/9box\n/bin/sed\nx b\nboxed\n", r.out);
}

test "without --gfx, #i, #m and #b are masked [gfx]" {
    const e = try env(@src());
    for ([_][]const u8{ "#i", "#m", "#b" }) |dev| {
        const r = try run(e, &.{ "ls", dev });
        defer r.deinit();
        errdefer std.debug.print("ls {s}: {s}", .{ dev, r.err });
        try std.testing.expectEqual(1, r.code);
        try std.testing.expect(std.mem.indexOf(u8, r.err, "mount/attach disallowed") != null);
    }
}

test "--gfx on a build without graphics exits 125 [gfx]" {
    const e = try env(@src());
    const v = try runProcess(&.{ e.h9, "--version" }, null);
    defer gpa.free(v.stdout);
    defer gpa.free(v.stderr);
    if (std.mem.indexOf(u8, v.stdout, "gfx: none\n") == null) return error.SkipZigTest;
    try expectGfxNotBuilt(e);
}

test "h9-node has no canvas, so --gfx exits 125 as a build without graphics does [browser-gfx]" {
    const e = try env(@src());
    if (!onWeb()) return error.SkipZigTest;
    try expectGfxNotBuilt(e);
}

fn expectGfxNotBuilt(e: Env) !void {
    const r = try run(e, &.{ "--gfx", "echo", "hi" });
    defer r.deinit();
    try std.testing.expectEqual(125, r.code);
    try std.testing.expectEqualStrings("", r.out);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "graphics aren't built into this h9") != null);
}

// The headless screen (design/epoch-0/headless-screen.md): --gfx=headless gives a
// screen in memory, and /dev/screen, /dev/mousein and /dev/kbdin read it
// and type and click into it, from rc.

test "--gfx=headless binds /dev/draw, /dev/mouse, /dev/kbd and /dev/screen [headless-screen]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--gfx=headless", "--rc", "ls /dev/draw/new /dev/mouse /dev/mousein /dev/cursor /dev/kbd /dev/kbdin /dev/screen" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    // ls lists the files, then what it found in the directories.
    try std.testing.expectEqualStrings("/dev/cursor\n/dev/kbd\n/dev/kbdin\n/dev/mouse\n/dev/mousein\n/dev/screen\n/dev/draw/new\n", r.out);
}

test "/dev/screen is an image(6) file of the headless screen's size [headless-screen]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--gfx=headless", "--gfx-size", "640x480", "--rc", "read -c 60 </dev/screen; ls -l /dev/screen | awk '{print $1}'" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("   x8r8g8b8           0           0         640         480 --r--r--r--\n", r.out);
}

/// Draw messages (draw(3)) that fill (10,10)-(30,30) of the screen, image
/// 0, with red, as tests/fixtures/gfx/draw.S does: 'b' allocates image 1,
/// a replicated opaque red pixel, 'd' draws
/// it through itself as the mask, and 'v' flushes.
fn redSquare(buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    const put = struct {
        fn i(wr: *std.Io.Writer, v: u32) void {
            wr.writeInt(u32, v, .little) catch unreachable;
        }
        fn rect(wr: *std.Io.Writer, a: u32, b: u32, c: u32, d: u32) void {
            i(wr, a);
            i(wr, b);
            i(wr, c);
            i(wr, d);
        }
    };
    w.writeByte('b') catch unreachable;
    put.i(&w, 1); // id
    put.i(&w, 0); // screenid
    w.writeByte(0) catch unreachable; // refresh
    put.i(&w, 0x08182848); // RGBA32: its alpha makes it an opaque mask too
    w.writeByte(1) catch unreachable; // repl
    put.rect(&w, 0, 0, 1, 1);
    put.rect(&w, @bitCast(@as(i32, -0x3FFFFFFF)), @bitCast(@as(i32, -0x3FFFFFFF)), 0x3FFFFFFF, 0x3FFFFFFF); // clipr: everywhere
    put.i(&w, 0xFF0000FF); // red, opaque
    w.writeByte('d') catch unreachable;
    put.i(&w, 0); // dst: the screen
    put.i(&w, 1); // src
    put.i(&w, 1); // mask
    put.rect(&w, 10, 10, 30, 30);
    put.rect(&w, 0, 0, 0, 0); // srcp, maskp
    w.writeByte('v') catch unreachable;
    return w.buffered();
}

test "a draw client's image shows up in /dev/screen [headless-screen]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var mb: [128]u8 = undefined;
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "draw.bin", .data = redSquare(&mb) });
    // The client's ctl, from /dev/draw/new, stays open on fd 3 while the
    // messages go to its data file; its first field is the client's number.
    const r = try run(e, &.{ "--cwd", s.path, "--gfx=headless", "--gfx-size", "64x48", "--rc",
        \\<[3]/dev/draw/new {
        \\    ctl=`{read -c 144 <[0=3]}
        \\    cat draw.bin >/dev/draw/$ctl(1)^/data
        \\    cat /dev/screen >shot
        \\}
    });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    var buf: [60 + 64 * 48 * 4 + 1]u8 = undefined;
    const shot = hostFile(&s, "shot", &buf) orelse return error.NoShot;
    try std.testing.expectEqual(60 + 64 * 48 * 4, shot.len);
    try std.testing.expectEqualStrings("   x8r8g8b8           0           0          64          48 ", shot[0..60]);
    const px = shot[60..];
    const at = struct {
        fn f(p: []const u8, x: usize, y: usize) u32 {
            return std.mem.readInt(u32, p[(y * 64 + x) * 4 ..][0..4], .little) & 0xFFFFFF;
        }
    }.f;
    try std.testing.expectEqual(0xFF0000, at(px, 10, 10));
    try std.testing.expectEqual(0xFF0000, at(px, 29, 29));
    try std.testing.expect(at(px, 5, 5) != 0xFF0000);
    try std.testing.expect(at(px, 30, 30) != 0xFF0000);
}

test "a line written to /dev/mousein reaches /dev/mouse [headless-screen]" {
    const e = try env(@src());
    // 'A' is the pointer at x, y; 'm' moves it by x, y, as on 9front.
    const r = try run(e, &.{ "--gfx=headless", "--rc",
        \\</dev/mouse {
        \\    echo A 100 200 1 0 >/dev/mousein
        \\    read -c 49
        \\    echo
        \\    echo m 5 -10 0 0 >/dev/mousein
        \\    read -c 49
        \\    echo
        \\}
    });
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqual(0, r.code);
    var lines = std.mem.tokenizeScalar(u8, r.out, '\n');
    for ([_][3][]const u8{ .{ "100", "200", "1" }, .{ "105", "190", "0" } }) |want| {
        var f = std.mem.tokenizeScalar(u8, lines.next() orelse return error.Short, ' ');
        try std.testing.expectEqualStrings("m", f.next().?);
        for (want) |w| try std.testing.expectEqualStrings(w, f.next().?);
    }
}

test "text written to /dev/kbdin reaches /dev/kbd as typed keys [headless-screen]" {
    const e = try env(@src());
    // kbdfs's format: 'k' and the keys held for a press, 'c' and the
    // character typed, 'K' and the keys still held for a release; a write
    // ending in a NUL is messages, 'r' and 'R' a key pressed and released.
    const r = try run(e, &.{ "--gfx=headless", "--rc",
        \\</dev/kbd {
        \\    echo -n a >/dev/kbdin
        \\    read -c 8 | tr '\0' '.'
        \\    echo
        \\}
    });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("ka.ca.K.\n", r.out);
}

test "--gfx=headless keeps /dev/snarf away from the host clipboard [headless-screen]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--gfx=headless", "--rc", "echo -n guest >/dev/snarf; cat /dev/snarf" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("guest", r.out);
    // The plan says so: a screen in memory, with no clipboard caveat.
    const p = try run(e, &.{ "--gfx=headless", "--print", "echo" });
    defer p.deinit();
    try std.testing.expect(std.mem.indexOf(u8, p.out, "gfx:      headless 1024x768\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, p.out, "clipboard") == null);
}

test "rio starts on the headless screen, and kbdin types a command into its window [headless-screen]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    // Keys typed before rio reads /dev/kbd are dropped, so the line is
    // typed again until /dev/snarf, which rio writes through, has it.
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "test.rc", .data = 
        \\window -r 0 0 600 400 rc
        \\for(i in `{seq 1 60}){
        \\    sleep 1
        \\    if(~ `{cat /dev/snarf} hi){
        \\        echo hi >/mnt/term/cwd/out
        \\        kill rio | rc
        \\        exit
        \\    }
        \\    echo 'echo hi >/dev/snarf' >/dev/kbdin
        \\}
        \\
    });
    var tb: [16]u8 = undefined;
    const r = try runInFor(e, &.{ "--cwd", s.path, "--timeout", slowTimeout(&tb, 90_000), "--gfx=headless", "rio", "-i", "rc /mnt/term/cwd/test.rc" }, null, slow(120_000));
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("hi\n", hostFile(&s, "out", &buf) orelse "");
}

test "--gfx-size without --gfx=headless is a usage error [headless-screen]" {
    const e = try env(@src());
    for ([_][]const []const u8{
        &.{ "--gfx-size", "640x480", "echo" },
        &.{ "--gfx", "--gfx-size", "640x480", "echo" },
        &.{ "--gfx=headless", "--gfx-scale", "2", "echo" },
        &.{ "--gfx=headless", "--gfx=noclip", "echo" },
    }) |args| {
        const r = try run(e, args);
        defer r.deinit();
        try std.testing.expectEqual(2, r.code);
        try std.testing.expectEqualStrings("", r.out);
    }
}

test "--gfx=headless in a -Dgfx=none build exits 125 [headless-screen]" {
    const e = try env(@src());
    const v = try runProcess(&.{ e.h9, "--version" }, null);
    defer gpa.free(v.stdout);
    defer gpa.free(v.stderr);
    if (std.mem.indexOf(u8, v.stdout, "gfx: none\n") == null) return error.SkipZigTest;
    const r = try run(e, &.{ "--gfx=headless", "echo", "hi" });
    defer r.deinit();
    try std.testing.expectEqual(125, r.code);
    try std.testing.expectEqualStrings("", r.out);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "graphics aren't built into this h9") != null);
}

// Contained trees (design/epoch-0/symlinks-in-root.md). The root for these is
// a small tree in a scratch directory: a few of the root's commands,
// copied, the mount points the namespace builder binds onto, and links.

/// Makes a root tree with links in `s`, at `s.path/tree`, and returns
/// that path in `out`.
fn linkTree(e: Env, s: *Scratch, out: []u8) ![]const u8 {
    const io = std.testing.io;
    const d = s.tmp.dir;
    const arch = e.arch orelse "arm64";
    var b: [64]u8 = undefined;
    for ([_][]const u8{ "dev", "env", "proc", "fd", "srv", "tmp", "net", "bin", "mnt/term/cwd", "usr", "rc/bin", "lib", "etc", "deny" }) |p|
        try d.createDirPath(io, try std.fmt.bufPrint(&b, "tree/{s}", .{p}));
    try d.createDirPath(io, try std.fmt.bufPrint(&b, "tree/{s}/bin", .{arch}));
    for ([_][]const u8{ "cat", "ls" }) |cmd| {
        var src: [64]u8 = undefined;
        const rel = try std.fmt.bufPrint(&src, "{s}/bin/{s}", .{ arch, cmd });
        try std.Io.Dir.copyFile(std.Io.Dir.cwd(), try hostPath(e.root, rel), d, try std.fmt.bufPrint(&b, "tree/{s}", .{rel}), io, .{});
    }
    try d.writeFile(io, .{ .sub_path = "tree/lib/hello", .data = "tree hello\n" });
    try d.writeFile(io, .{ .sub_path = "tree/deny/secret", .data = "secret\n" });
    // Absolute, climbing past the top, a loop, a link to a denied file,
    // and a link to the cat binary.
    try symLinkOrSkip(d, io, "/lib/hello", "tree/etc/hello", .{});
    try symLinkOrSkip(d, io, "../../../../../../lib/hello", "tree/etc/up", .{});
    try symLinkOrSkip(d, io, "loop", "tree/etc/loop", .{});
    try symLinkOrSkip(d, io, "/deny/secret", "tree/etc/pub", .{});
    var t: [64]u8 = undefined;
    try symLinkOrSkip(d, io, try std.fmt.bufPrint(&t, "/{s}/bin/cat", .{arch}), try std.fmt.bufPrint(&b, "tree/{s}/bin/kitty", .{arch}), .{});
    return std.fmt.bufPrint(out, "{s}/tree", .{s.path});
}

test "absolute symlink in a contained tree resolves inside it [symlinks-in-root]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var tb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tree = try linkTree(e, &s, &tb);
    const r = try runContained(e, tree, &.{ "--cwd", s.path, "cat", "/etc/hello" });
    defer r.deinit();
    try std.testing.expectEqualStrings("tree hello\n", r.out);
    try std.testing.expectEqual(0, r.code);
    // A command reached through a link runs, and lists as its target.
    const k = try runContained(e, tree, &.{ "--cwd", s.path, "kitty", "/lib/hello" });
    defer k.deinit();
    try std.testing.expectEqualStrings("tree hello\n", k.out);
    try std.testing.expectEqual(0, k.code);
}

test "symlink with .. stops at the top of a contained tree [symlinks-in-root]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var tb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tree = try linkTree(e, &s, &tb);
    const r = try runContained(e, tree, &.{ "--cwd", s.path, "cat", "/etc/up" });
    defer r.deinit();
    try std.testing.expectEqualStrings("tree hello\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "symlink loop is too many symbolic links [symlinks-in-root]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var tb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tree = try linkTree(e, &s, &tb);
    const r = try runContained(e, tree, &.{ "--cwd", s.path, "cat", "/etc/loop" });
    defer r.deinit();
    try std.testing.expectEqual(1, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "too many symbolic links") != null);
}

test "contained tree still honours --read-deny [symlinks-in-root]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var tb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tree = try linkTree(e, &s, &tb);
    var db: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const deny = try std.fmt.bufPrint(&db, "{s}/deny", .{tree});
    const r = try runContained(e, tree, &.{ "--cwd", s.path, "--read-deny", deny, "cat", "/etc/pub" });
    defer r.deinit();
    try std.testing.expectEqual(1, r.code);
    try std.testing.expectEqualStrings("", r.out);
    const l = try runContained(e, tree, &.{ "--cwd", s.path, "--read-deny", deny, "ls", "/", "/etc" });
    defer l.deinit();
    try std.testing.expect(std.mem.indexOf(u8, l.out, "deny") == null);
    try std.testing.expect(std.mem.indexOf(u8, l.out, "/etc/pub") == null);
    try std.testing.expect(std.mem.indexOf(u8, l.out, "/etc/hello") != null);
}

test "uncontained bind follows host symlinks as before [symlinks-in-root]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var tb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tree = try linkTree(e, &s, &tb);
    // A link to a host file in a readable directory outside the tree.
    var other: Scratch = undefined;
    try other.init();
    defer other.deinit();
    try other.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f", .data = "host\n" });
    var lp: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try symLinkOrSkip(s.tmp.dir, std.testing.io, try std.fmt.bufPrint(&lp, "{s}/f", .{other.path}), "tree/lib/host", .{});
    const u = try runRoot(e, tree, &.{ "--cwd", s.path, "--readable", other.path, "cat", "/lib/host" });
    defer u.deinit();
    try std.testing.expectEqualStrings("host\n", u.out);
    try std.testing.expectEqual(0, u.code);
    // Without containment, /lib/hello's absolute link goes to the host.
    const h = try runRoot(e, tree, &.{ "--cwd", s.path, "cat", "/etc/hello" });
    defer h.deinit();
    try std.testing.expectEqual(1, h.code);
    // Contained, the same link is read inside the tree, where that host
    // path doesn't exist.
    const c = try runContained(e, tree, &.{ "--cwd", s.path, "--readable", other.path, "cat", "/lib/host" });
    defer c.deinit();
    try std.testing.expectEqual(1, c.code);
    try std.testing.expectEqualStrings("", c.out);
}

test "a Linux program sees a .L mount's links and follows them from its own root [linux-symlinks]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    if (le.nine == null) return error.SkipZigTest;
    var d: Diod = undefined;
    try d.start(
        \\mkdir -p usr/glenda
        \\printf 'one\ntwo\n' >usr/glenda/notes
        \\ln -s usr/glenda lib
        \\ln -s /etc/alpine-release usr/abs
        \\ln -s loop usr/loop
        \\ln -s nowhere usr/dangling
    );
    defer d.stop();
    // dotlfs mounts it in the 9front namespace, which a Linux program
    // sees at /9. The absolute link names Alpine's file, not the export's.
    var cmd: std.ArrayList(u8) = .empty;
    defer cmd.deinit(gpa);
    try cmd.print(gpa,
        \\mkdir -p /n/l; dotlfs {s} /n/l '{s}' || exit mount
        \\'#L/bin/busybox' sh -c 'cd /9/n/l/usr; ls; for f in abs dangling; do [ -L $f ] && readlink $f; done; cat ../lib/notes; cmp abs /etc/alpine-release && echo same; cat loop 2>&1 | grep -c "link loop"'
    , .{ d.dial(), d.s.path });
    const r = try runLinux(&le, true, &.{ "--net-allow", d.allow(), "--rc", cmd.items });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("abs\ndangling\nglenda\nloop\n/etc/alpine-release\nnowhere\none\ntwo\nsame\n1\n", r.out);
}

test "a 9front program's walk through a contained tree is unchanged [linux-symlinks]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var tb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tree = try linkTree(e, &s, &tb);
    // Links resolve inside the tree, and a listing shows their targets.
    const r = try runContained(e, tree, &.{ "--cwd", s.path, "cat", "/etc/hello", "/etc/up" });
    defer r.deinit();
    try std.testing.expectEqualStrings("tree hello\ntree hello\n", r.out);
    try std.testing.expectEqual(0, r.code);
    const l = try runContained(e, tree, &.{ "--cwd", s.path, "ls", "-l", "/etc/hello" });
    defer l.deinit();
    try std.testing.expect(std.mem.indexOf(u8, l.out, "--rw") != null);
    try std.testing.expectEqual(0, l.code);
}

test "--print's #U!c bind replays with --ns [symlinks-in-root]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var tb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tree = try linkTree(e, &s, &tb);
    const p = try runContained(e, tree, &.{ "--cwd", s.path, "--print", "cat" });
    defer p.deinit();
    var want: [std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    var kb: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, p.out, try std.fmt.bufPrint(&want, "  bind -r '#U!c{s}' '#Oroot'", .{kernPath(&kb, tree)})) != null);
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ns", .data = try printedNamespace(p.out) });
    // Replayed over an uncontained root, the #U!c bind makes it contained
    // (--host-fs leaves #U unmasked, so the replay can attach it).
    const r = try runRoot(e, tree, &.{ "--cwd", s.path, "--host-fs", "--write=scope", "--ns", s.ns(), "cat", "/etc/hello" });
    defer r.deinit();
    try std.testing.expectEqualStrings("tree hello\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "ls -l /bin in a contained tree with links (demo) [symlinks-in-root]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var tb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tree = try linkTree(e, &s, &tb);
    const r = try runContained(e, tree, &.{ "--cwd", s.path, "ls", "-l", "/bin" });
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "/bin/kitty") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "/bin/cat") != null);
}

// The Linux ABI (design/epoch-0/linux-personality.md): static Linux
// programs from tests/fixtures/linux (H9_TEST_LINUX) and an Alpine root
// from scripts/fetch.sh (H9_TEST_LINUX_ROOT/alpine-<arch>).

const LinuxEnv = struct {
    h9: []const u8,
    /// The Alpine root for `arch`.
    root: []const u8,
    /// The fixtures built for `arch`, the guest's cwd.
    fixtures: []const u8,
    /// The 9front root, for the cases that mix the two; null if there's none.
    nine: ?[]const u8,
    arch: []const u8,
    engines: []const u8,
    /// `root:#L`, the --dir that mounts it (design/epoch-0/mounts.md).
    lmount: []const u8 = "",
    buf: [2][std.Io.Dir.max_path_bytes]u8 = undefined,
    lbuf: [std.Io.Dir.max_path_bytes + 3]u8 = undefined,
};

fn linuxEnv(comptime src: std.builtin.SourceLocation, le: *LinuxEnv) !void {
    try skipPending(src.fn_name);
    const h9 = getenv(0, "H9_TEST_BIN") orelse return error.SkipZigTest;
    const arch = getenv(4, "H9_TEST_ARCH") orelse switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "amd64",
        else => return error.SkipZigTest,
    };
    const fx = getenv(2, "H9_TEST_LINUX") orelse return error.SkipZigTest;
    const lr = getenv(3, "H9_TEST_LINUX_ROOT") orelse return error.SkipZigTest;
    le.* = .{ .h9 = h9, .root = undefined, .fixtures = undefined, .nine = null, .arch = arch, .engines = "auto" };
    le.root = try std.fmt.bufPrint(&le.buf[0], "{s}/alpine-{s}", .{ lr, arch });
    le.lmount = try std.fmt.bufPrint(&le.lbuf, "{s}:#L", .{le.root});
    le.fixtures = try std.fmt.bufPrint(&le.buf[1], "{s}/{s}", .{ fx, arch });
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, try hostPath(le.root, "etc/os-release"), .{}) catch return error.SkipZigTest;
    std.Io.Dir.cwd().access(io, try hostPath(le.fixtures, "hello"), .{}) catch return error.SkipZigTest;
    // The engines and the 9front root go in slots 2 and 1, read last.
    le.engines = getenv(2, "H9_TEST_ENGINES") orelse "auto";
    // The 9front root counts only if it has this architecture's programs.
    if (getenv(1, "H9_TEST_ROOT")) |n| {
        var cat_buf: [32]u8 = undefined;
        const cat = try std.fmt.bufPrint(&cat_buf, "{s}/bin/cat", .{arch});
        if (std.Io.Dir.cwd().access(io, try hostPath(n, cat), .{})) |_| le.nine = n else |_| {}
    }
}

/// Runs `h9 --dir <alpine>:#L [--dir <9front>] --cwd <fixtures> args...` on
/// each engine, checking they agree, as `run` does.
fn runLinux(le: *const LinuxEnv, with_nine: bool, args: []const []const u8) !Result {
    return runLinuxEnv(le, with_nine, args, null);
}

/// runLinux, with the environment `environ` if it isn't null.
fn runLinuxEnv(le: *const LinuxEnv, with_nine: bool, args: []const []const u8, environ: ?*const std.process.Environ.Map) !Result {
    if (with_nine and le.nine == null) return error.SkipZigTest;
    var first: ?Result = null;
    errdefer if (first) |f| f.deinit();
    var it = std.mem.tokenizeScalar(u8, le.engines, ',');
    while (it.next()) |engine| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ le.h9, "--engine", engine, "--arch", le.arch, "--dir", le.lmount });
        if (with_nine) try argv.appendSlice(gpa, &.{ "--dir", le.nine.? });
        try argv.appendSlice(gpa, &.{ "--cwd", le.fixtures });
        try argv.appendSlice(gpa, args);
        const p = try runProcessWith(argv.items, null, environ, 120_000);
        const code = switch (p.term) {
            .exited => |c| c,
            else => {
                std.debug.print("h9 {s}: {any}\n{s}", .{ args[0], p.term, p.stderr });
                gpa.free(p.stdout);
                gpa.free(p.stderr);
                return error.Crashed;
            },
        };
        const r: Result = .{ .code = code, .out = p.stdout, .err = p.stderr };
        if (first) |f| {
            defer r.deinit();
            errdefer std.debug.print("engine {s} differs for h9 {s}\n", .{ engine, args[0] });
            // --print's plan names the engine it was run on
            // (design/plan-format.md).
            try std.testing.expectEqualStrings(try withoutEngine(f.out), try withoutEngine(r.out));
            try std.testing.expectEqual(f.code, r.code);
        } else first = r;
    }
    return first orelse error.SkipZigTest;
}

test "a static Linux program runs and exits with its status (demo) [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    const r = try runLinux(&le, false, &.{ "/mnt/term/cwd/hello", "x", "y" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("hello from linux, argc=3\narg x\narg y\n", r.out);
    try std.testing.expectEqual(3, r.code);
}

test "--dir on #L makes a Linux tree, and /dev stays devlinux's [mounts]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    // Alpine's /dev is empty on the host.
    const r = try runLinux(&le, false, &.{ "/bin/sh", "-c", "cat /etc/alpine-release >/dev/null && echo alpine; test -c /dev/null && echo null" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("alpine\nnull\n", r.out);
}

test "--dir on #L/etc adds a member under the Linux tree's /etc [mounts]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try writeTree(&s, &.{ .{ "etc/resolv.conf", "nameserver 192.0.2.1\n" }, .{ "etc/extra", "hi\n" } });
    var p: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    const r = try runLinux(&le, false, &.{ "--dir", try std.fmt.bufPrint(&p, "{s}/etc:#L/etc", .{s.path}), "/bin/sh", "-c", "cat /etc/resolv.conf /etc/extra; test -e /etc/passwd && echo passwd" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("nameserver 192.0.2.1\nhi\npasswd\n", r.out);
}

test "#λ is an alias for #L in namespace files [mounts]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    const r = try runLinux(&le, true, &.{ "--ns", "bind '#λ/etc' /lib", "--rc", "cat /lib/alpine-release >/dev/null && echo alpine" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("alpine\n", r.out);
}

test "an executable's untouched segments aren't loaded: a 170 MB static binary runs in 64 MB [cow-fork]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    std.Io.Dir.cwd().access(std.testing.io, try hostPath(le.fixtures, "bigexe"), .{}) catch return error.SkipZigTest;
    const r = try runLinux(&le, false, &.{ "--memory", "64m", "/mnt/term/cwd/bigexe" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("size 178257920 first A mid Z last B data 7 bss 0\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "three processes running one 170 MB static binary and reading all of it share its pages: they fit in --memory 320m [cow-fork]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    std.Io.Dir.cwd().access(std.testing.io, try hostPath(le.fixtures, "bigexe"), .{}) catch return error.SkipZigTest;
    const r = try runLinux(&le, false, &.{ "--memory", "320m", "/mnt/term/cwd/bigexe", "share", "3" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("ok share 3\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "a write to a private file mapping whose pages are shared stays in it: not in another mapping, a child's, or the file [cow-fork]" {
    try cowFork(@src(), &.{ "/mnt/term/cwd/cowfork", "privwrite" }, "ok privwrite\n");
}

test "a fork of a process with 600 MB of written heap runs under --memory 1g, and parent and child see their own writes [cow-fork]" {
    try cowFork(@src(), &.{ "--memory", "1g", "/mnt/term/cwd/cowfork", "big" }, "ok big\n");
}

test "after fork, a read() into a buffer, a write from another thread, and a futex word change stay in the process that made them [cow-fork]" {
    try cowFork(@src(), &.{ "/mnt/term/cwd/cowfork", "isolate" }, "ok isolate\n");
}

test "a write after fork that finds no memory gets SIGKILL, and the machine and the other process go on [cow-fork]" {
    try cowFork(@src(), &.{ "--memory", "256m", "/mnt/term/cwd/cowfork", "oom" }, "ok oom\n");
}

test "MADV_DONTNEED after fork zeroes the range in one process only [cow-fork]" {
    try cowFork(@src(), &.{ "/mnt/term/cwd/cowfork", "dontneed" }, "ok dontneed\n");
}

test "a private mapping of a 200 MB file costs only the chunks touched, as VmRSS shows [cow-fork]" {
    try cowFork(@src(), &.{ "/mnt/term/cwd/cowfork", "filemap" }, "ok filemap\n");
}

test "a running program's file is busy: opening it for writing or truncating it is ETXTBSY until it exits [cow-fork]" {
    try cowFork(@src(), &.{ "/mnt/term/cwd/cowfork", "txtbsy" }, "ok txtbsy\n");
}

test "a private mapping's pages past the end of its file are SIGBUS to touch and EFAULT to a syscall [cow-fork]" {
    try cowFork(@src(), &.{ "/mnt/term/cwd/cowfork", "sigbus" }, "ok sigbus\n");
}

test "pages a program unmaps don't stay allocated beside the ones it keeps: 64 MB unmapped but for a page a MiB, then 64 MB more, fit in 96 MB [cow-fork]" {
    try cowFork(@src(), &.{ "--memory", "96m", "/mnt/term/cwd/cowfork", "holes" }, "ok holes\n");
}

test "/proc/self/maps shows a program's segments, read from its file as they're touched, one line each [cow-fork]" {
    try cowFork(@src(), &.{ "/mnt/term/cwd/cowfork", "maps" }, "ok maps\n");
}

test "a dynamic program and its interpreter run from their files' pages, each mapping one line in /proc/self/maps [cow-fork]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    const r = try runLinux(&le, false, &.{ "/bin/cat", "/proc/self/maps" });
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqual(0, r.code);
    // Alpine's cat is busybox, linked against musl, whose loader is the
    // interpreter: both are mapped, and no file mapping is in pieces.
    try std.testing.expect(std.mem.indexOf(u8, r.out, " /bin/cat\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, " /lib/ld-musl-") != null);
    var prev: struct { end: u64 = 0, off: u64 = 0, perms: []const u8 = "", name: []const u8 = "" } = .{};
    var lines = std.mem.tokenizeScalar(u8, r.out, '\n');
    while (lines.next()) |line| {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        const range = f.next() orelse continue;
        const perms = f.next() orelse continue;
        const off = std.fmt.parseInt(u64, f.next() orelse continue, 16) catch continue;
        _ = f.next();
        _ = f.next();
        const name = f.rest();
        const dash = std.mem.indexOfScalar(u8, range, '-') orelse continue;
        const start = try std.fmt.parseInt(u64, range[0..dash], 16);
        const end = try std.fmt.parseInt(u64, range[dash + 1 ..], 16);
        if (name.len > 0 and name[0] != '[' and std.mem.eql(u8, name, prev.name) and std.mem.eql(u8, perms, prev.perms) and start == prev.end and off == prev.off) {
            std.debug.print("{s} in pieces at {x}\n", .{ name, start });
            return error.TestUnexpectedResult;
        }
        prev = .{ .end = end, .off = off + (end - start), .perms = perms, .name = name };
    }
}

/// Runs tests/fixtures/linux/cowfork.c with `args`, its case last, and
/// checks it prints `want` and exits 0, for the test at `src`.
fn cowFork(comptime src: std.builtin.SourceLocation, args: []const []const u8, want: []const u8) !void {
    var le: LinuxEnv = undefined;
    try linuxEnv(src, &le);
    std.Io.Dir.cwd().access(std.testing.io, try hostPath(le.fixtures, "cowfork"), .{}) catch return error.SkipZigTest;
    const r = try runLinux(&le, false, args);
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqualStrings(want, r.out);
    try std.testing.expectEqual(0, r.code);
}

test "files, fork, vfork, exec, pipes, signals and mmap work for a Linux program [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    const r = try runLinux(&le, false, &.{"/mnt/term/cwd/probe"});
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expect(!std.mem.startsWith(u8, r.out, "FAIL ") and std.mem.indexOf(u8, r.out, "\nFAIL ") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "exec child status 5\n") != null);
    try std.testing.expectEqual(0, r.code);
}

test "a Linux program killed by a signal exits 128+N, and a handler can catch a fault [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    const term = try runLinux(&le, false, &.{ "/mnt/term/cwd/die", "term" });
    defer term.deinit();
    try std.testing.expectEqual(143, term.code);
    try std.testing.expect(std.mem.indexOf(u8, term.err, "linux: signal 15") != null);
    const segv = try runLinux(&le, false, &.{ "/mnt/term/cwd/die", "segv" });
    defer segv.deinit();
    try std.testing.expectEqual(139, segv.code);
    const caught = try runLinux(&le, false, &.{ "/mnt/term/cwd/die", "handled" });
    defer caught.deinit();
    try std.testing.expectEqualStrings("caught SIGSEGV at 0x20\n", caught.out);
    try std.testing.expectEqual(4, caught.code);
}

test "an instruction the CPU doesn't have is SIGILL for a Linux program, not SIGSEGV [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    const arm64 = std.mem.eql(u8, le.arch, "arm64");
    const ill = try runLinux(&le, false, &.{ "/mnt/term/cwd/die", "ill" });
    defer ill.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ ill.out, ill.err });
    try std.testing.expectEqual(132, ill.code);
    const caught = try runLinux(&le, false, &.{ "/mnt/term/cwd/die", "illhandled" });
    defer caught.deinit();
    // ILL_ILLOPN, as Linux's do_error_trap gives #UD; ILL_ILLOPC on
    // arm64, as its do_undefinstr does.
    try std.testing.expectEqualStrings(if (arm64) "caught SIGILL code 1\n" else "caught SIGILL code 2\n", caught.out);
    try std.testing.expectEqual(5, caught.code);
    if (!arm64) return;
    // An SVE instruction, which h9 doesn't enable, as OpenSSL probes for it.
    const sve = try runLinux(&le, false, &.{ "/mnt/term/cwd/die", "sve" });
    defer sve.deinit();
    try std.testing.expectEqualStrings("caught SIGILL code 1\n", sve.out);
    try std.testing.expectEqual(5, sve.code);
}

test "rt_sigreturn can't raise a Linux program's privilege [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    const r = try runLinux(&le, false, &.{"/mnt/term/cwd/sigreturn"});
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("handled 1, selectors kept\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "busybox sh runs a pipeline from the Linux root, and /proc describes it (demo) [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    const r = try runLinux(&le, false, &.{ "sh", "-c", "echo a b c | wc -w; cat /proc/self/comm; grep -c ^processor /proc/cpuinfo >/dev/null && echo cpuinfo; ./hello | head -1; exit 7" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("3\ncat\ncpuinfo\nhello from linux, argc=1\n", r.out);
    try std.testing.expectEqual(7, r.code);
}

test "/proc/self/stat and status describe a Linux process [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    // Redis reads /proc/self/stat every second; reading it overran the
    // kernel's stack (a 32-bit ulong written as 64).
    const r = try runLinux(&le, false, &.{ "sh", "-c", "cut -d' ' -f2-3 /proc/self/stat; grep -E '^(Name|Threads):' /proc/self/status" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("(cut) R\nName:\tgrep\nThreads:\t1\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "ln -s makes links a Linux program follows, renames and removes, and sh waits on a background job [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    // /usr/lib is in the root's overlay; a relative link resolves from its
    // directory, an absolute one from the root, and a dangling one is still
    // a link to lstat, readlink, rename and remove.
    const script =
        \\set -e
        \\cd /usr/lib; echo hi > f; ln -s f l; cat l; readlink l
        \\ln -s /etc/alpine-release abs; cat abs >/dev/null; echo abs
        \\mkdir d; echo x > d/in; ln -s d dl; cat dl/in
        \\ln -s nowhere dang; [ -L dang ]; ! cat dang 2>/dev/null; mv dang dang2; readlink dang2
        \\rm l dang2; cat f; ! ln -s f abs 2>/dev/null
        \\sleep 0.1 & wait $!; echo waited
    ;
    const r = try runLinux(&le, false, &.{ "sh", "-c", script });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("hi\nf\nabs\nx\nnowhere\nhi\nwaited\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "/proc/self/exe is the file a Linux program runs, its links followed [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    // Zig finds its lib directory beside /proc/self/exe, so a link to it
    // (/usr/bin/zig -> /opt/zig/zig) must name the target, as Linux does.
    // readlink is a link to busybox, and so is the relative one made here.
    const r = try runLinux(&le, false, &.{ "sh", "-c", "readlink /proc/self/exe; mkdir -p /root/d; cd /root/d; ln -s ../../bin/busybox readlink; ./readlink /proc/self/exe" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("/bin/busybox\n/bin/busybox\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

// Linux symlinks (design/epoch-0/linux-symlinks.md). Each case runs sh in the
// Alpine root with a scratch directory as its cwd, an uncontained host
// tree, and its own trees mounted or bound into the Linux view: /srv is
// a directory in the Alpine root to bind over.

/// Runs `script` under sh in the Linux view with `s` as the cwd and
/// `extra` flags after the Alpine root's, on each engine; checks it
/// prints `want` and exits 0.
fn linkCase(le: *const LinuxEnv, s: *const Scratch, extra: []const []const u8, script: []const u8, want: []const u8) !void {
    var ran = false;
    var it = std.mem.tokenizeScalar(u8, le.engines, ',');
    while (it.next()) |engine| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ le.h9, "--engine", engine, "--arch", le.arch, "--dir", le.lmount });
        try argv.appendSlice(gpa, extra);
        try argv.appendSlice(gpa, &.{ "--cwd", s.path, "sh", "-c", script });
        const p = try runProcessWith(argv.items, null, null, 120_000);
        defer gpa.free(p.stdout);
        defer gpa.free(p.stderr);
        errdefer std.debug.print("engine {s}\nstdout: {s}\nstderr: {s}\n", .{ engine, p.stdout, p.stderr });
        try std.testing.expectEqualStrings(want, p.stdout);
        try std.testing.expect(p.term == .exited and p.term.exited == 0);
        ran = true;
    }
    if (!ran) return error.SkipZigTest;
}

/// `--dir <s>/name:dst` and `--bind /mnt/term/cwd/name:dst`, in buffers
/// the case keeps.
fn dirArg(buf: []u8, s: *const Scratch, name: []const u8, dst: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}:{s}", .{ s.path, name, dst });
}

fn bindArg(buf: []u8, name: []const u8, dst: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "/mnt/term/cwd/{s}:{s}", .{ name, dst });
}

/// The scratch trees most cases use: opt/y, a file, and app, with links
/// to it: x (absolute), rel (relative, out of app), and mid (a directory
/// link in the middle of a path).
fn appTree(s: *Scratch) !void {
    const io = std.testing.io;
    const d = s.tmp.dir;
    try d.createDirPath(io, "opt");
    try d.createDirPath(io, "app");
    try d.writeFile(io, .{ .sub_path = "opt/y", .data = "y\n" });
    try symLinkOrSkip(d, io, "/opt/y", "app/x", .{});
    try symLinkOrSkip(d, io, "../opt/y", "app/rel", .{});
    try symLinkOrSkip(d, io, "/opt", "app/mid", .{});
}

test "an absolute link in a bound host tree resolves from the Linux root [linux-symlinks]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try appTree(&s);
    var ob: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var ab: [std.Io.Dir.max_path_bytes]u8 = undefined;
    // The host has no /opt/y: the link names the guest's, another --dir.
    try linkCase(&le, &s, &.{ "--dir", try dirArg(&ob, &s, "opt", "#L/opt"), "--bind", try bindArg(&ab, "app", "#L/srv") }, "cat /srv/x; readlink /srv/x", "y\n/opt/y\n");
}

test "an absolute link in one #L layer resolves into another [linux-symlinks]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const io = std.testing.io;
    const d = s.tmp.dir;
    // A runtime layer and a deps layer whose venv links into it, as
    // h9build stacks an image's layers.
    try d.createDirPath(io, "runtime/opt/rt/bin");
    try d.createDirPath(io, "deps/app/venv/bin");
    try d.writeFile(io, .{ .sub_path = "runtime/opt/rt/bin/python3", .data = "python\n" });
    try symLinkOrSkip(d, io, "/opt/rt/bin/python3", "deps/app/venv/bin/python", .{});
    var rb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var db: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try linkCase(&le, &s, &.{ "--dir", try dirArg(&rb, &s, "runtime", "#L"), "--dir", try dirArg(&db, &s, "deps", "#L") }, "cat /app/venv/bin/python; [ -L /app/venv/bin/python ] && echo link", "python\nlink\n");
}

test "a relative link resolves from its own directory across a bind [linux-symlinks]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try appTree(&s);
    var ob: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var ab: [std.Io.Dir.max_path_bytes]u8 = undefined;
    // ../opt/y from /srv is the guest's /opt/y, not the host's sibling.
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "opt/y", .data = "host sibling\n" });
    var gb: Scratch = undefined;
    try gb.init();
    defer gb.deinit();
    try gb.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "y", .data = "guest\n" });
    var gob: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    _ = &ob;
    const gopt = try std.fmt.bufPrint(&gob, "{s}:#L/opt", .{gb.path});
    try linkCase(&le, &s, &.{ "--dir", gopt, "--bind", try bindArg(&ab, "app", "#L/srv") }, "cat /srv/rel; cd /srv; cat rel", "guest\nguest\n");
}

test "a dangling link lists and removes [linux-symlinks]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const io = std.testing.io;
    const script =
        \\set -e
        \\ls pkg; rm -r pkg; [ ! -e pkg ]; echo host
        \\cd /usr/lib; mkdir pkg; ln -s gone pkg/a; ls pkg; rm -r pkg; [ ! -e pkg ]; echo overlay
    ;
    // The script removes the links, so each engine gets them anew.
    var it = std.mem.tokenizeScalar(u8, le.engines, ',');
    while (it.next()) |engine| {
        // Made on the host: one to nothing, one to a path only the guest has.
        try s.tmp.dir.createDirPath(io, "pkg");
        try symLinkOrSkip(s.tmp.dir, io, "gone", "pkg/a", .{});
        try symLinkOrSkip(s.tmp.dir, io, "/etc/alpine-release", "pkg/b", .{});
        var one = le;
        one.engines = engine;
        try linkCase(&one, &s, &.{}, script, "a\nb\nhost\na\noverlay\n");
    }
}

/// Runs the symlink fixture's case `name` in the machine's /tmp, in the
/// root's overlay, and in a `--writable` host directory. A case that
/// makes links (`makes_links`) skips the host directory on Windows,
/// where devfs-win32 makes none (h9_fs_symlink is EPERM there).
fn symlinkFixture(le: *const LinuxEnv, name: []const u8, makes_links: bool) !void {
    var want_buf: [64]u8 = undefined;
    const want = try std.fmt.bufPrint(&want_buf, "ok {s}\n", .{name});
    try netCase(le, &.{ "/mnt/term/cwd/symlink", name }, want);
    try netCase(le, &.{ "env", "DIR=/usr/lib", "/mnt/term/cwd/symlink", name }, want);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    if (builtin.os.tag == .windows and makes_links) return;
    // The host directory as the guest names it under /mnt/term: on
    // Windows, /mnt/term/C:/... with / for each \.
    var dir_buf: [std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    const dir = if (builtin.os.tag == .windows) blk: {
        const d = try std.fmt.bufPrint(&dir_buf, "DIR=/mnt/term/{s}", .{s.path});
        std.mem.replaceScalar(u8, d, '\\', '/');
        break :blk d;
    } else try std.fmt.bufPrint(&dir_buf, "DIR=/mnt/term{s}", .{s.path});
    try netCase(le, &.{ "--writable", s.path, "env", dir, "/mnt/term/cwd/symlink", name }, want);
}

test "lstat, readlink, and O_NOFOLLOW act on the link [linux-symlinks]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try symlinkFixture(&le, "nofollow", true);
}

test "a loop of links is ELOOP [linux-symlinks]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try symlinkFixture(&le, "loop", true);
}

test "exec of a link and a #! interpreter reached through a link run [linux-symlinks]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const io = std.testing.io;
    // In the host tree: a link to busybox by an absolute guest path, and a
    // script whose interpreter is a link in the overlay.
    try symLinkOrSkip(s.tmp.dir, io, "/bin/busybox", "echo", .{});
    try s.tmp.dir.writeFile(io, .{ .sub_path = "script", .data = "#!/root/b/sh\necho script ran\n", .flags = .{ .permissions = .executable_file } });
    try symLinkOrSkip(s.tmp.dir, io, "script", "run", .{});
    const script =
        \\set -e
        \\./echo linked echo
        \\mkdir -p /root/b; ln -s /bin/busybox /root/b/sh
        \\./run
    ;
    try linkCase(&le, &s, &.{}, script, "linked echo\nscript ran\n");
}

test "an absolute link in a host tree to a host path the guest doesn't see fails [linux-symlinks]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const io = std.testing.io;
    try s.tmp.dir.writeFile(io, .{ .sub_path = "secret", .data = "host\n" });
    var tb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    // The host follows it today; the guest has no such path.
    try symLinkOrSkip(s.tmp.dir, io, try std.fmt.bufPrint(&tb, "{s}/secret", .{s.path}), "h", .{});
    try linkCase(&le, &s, &.{}, "[ -L h ] && echo link; cat h 2>&1 | grep -c 'No such file'; cat secret", "link\n1\nhost\n");
}

test "getcwd and .. after a link name the target [linux-symlinks]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const io = std.testing.io;
    try s.tmp.dir.createDirPath(io, "a/b");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "a/in-a", .data = "" });
    try symLinkOrSkip(s.tmp.dir, io, "a/b", "bl", .{});
    // sh's own cd is by name; the kernel's .. and getcwd are by the target.
    const script =
        \\cd bl; /bin/pwd; readlink /proc/self/cwd; ls ..; cd -P ..; /bin/pwd
        \\cd /usr/lib; mkdir -p t/u; ln -s t/u tl; cd tl; /bin/pwd; ls ..
    ;
    try linkCase(&le, &s, &.{}, script, "/mnt/term/cwd/a/b\n/mnt/term/cwd/a/b\nb\nin-a\n/mnt/term/cwd/a\n/usr/lib/t/u\nu\n");
}

test "a link in the middle of a path in a host tree resolves from the Linux root [linux-symlinks]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try appTree(&s);
    var ob: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var ab: [std.Io.Dir.max_path_bytes]u8 = undefined;
    // mid -> /opt, which only the guest has as a directory with y in it.
    try linkCase(&le, &s, &.{ "--dir", try dirArg(&ob, &s, "opt", "#L/opt"), "--bind", try bindArg(&ab, "app", "#L/srv") }, "cat /srv/mid/y; cat app/mid/y", "y\ny\n");
}

test "--read-deny holds for a Linux program through links and .. [linux-symlinks]" {
    // A Linux program's walk checks each name by its own path, which
    // holds no links: those it meets are followed in the guest. A link,
    // or a .., that lands in the denied directory is still denied there.
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const io = std.testing.io;
    try s.tmp.dir.createDirPath(io, "priv");
    try s.tmp.dir.createDirPath(io, "sub");
    try s.tmp.dir.writeFile(io, .{ .sub_path = "priv/.env", .data = "secret\n" });
    try s.tmp.dir.writeFile(io, .{ .sub_path = "ok", .data = "ok\n" });
    try symLinkOrSkip(s.tmp.dir, io, "priv", "pl", .{ .is_directory = true });
    try symLinkOrSkip(s.tmp.dir, io, "../priv/.env", "sub/el", .{});
    var p: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const deny = try std.fmt.bufPrint(&p, "{s}/priv", .{s.path});
    const script =
        \\ln -s priv gl
        \\for f in priv/.env pl/.env sub/el sub/../priv/.env /mnt/term/cwd/./sub/../priv/.env gl/.env; do
        \\    stat -L $f >/dev/null 2>&1 || echo no stat $f
        \\    cat $f 2>/dev/null || echo no read $f
        \\done
        \\echo x >pl/new 2>/dev/null || echo no create
        \\ls | grep -c priv; cat sub/../ok
    ;
    try linkCase(&le, &s, &.{ "--read-deny", deny }, script, "no stat priv/.env\nno read priv/.env\nno stat pl/.env\nno read pl/.env\nno stat sub/el\nno read sub/el\nno stat sub/../priv/.env\nno read sub/../priv/.env\nno stat /mnt/term/cwd/./sub/../priv/.env\nno read /mnt/term/cwd/./sub/../priv/.env\nno stat gl/.env\nno read gl/.env\nno create\n0\nok\n");
    try std.testing.expect(!s.exists("priv/new"));
}

test "/proc/self/fd/N of a deleted file still opens [linux-symlinks]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try symlinkFixture(&le, "deleted", false);
}

// chroot (design/epoch-0/linux-chroot.md), with tests/fixtures/linux/chroot.c,
// which runs each case in a child that chroots and prints "ok NAME".

/// Runs the chroot fixture's case `name` with its trees in the machine's
/// /tmp, and then in the root's overlay.
fn chrootCase(le: *const LinuxEnv, name: []const u8) !void {
    var want_buf: [64]u8 = undefined;
    const want = try std.fmt.bufPrint(&want_buf, "ok {s}\n", .{name});
    try netCase(le, &.{ "/mnt/term/cwd/chroot", name }, want);
    try netCase(le, &.{ "env", "DIR=/usr/lib", "/mnt/term/cwd/chroot", name }, want);
}

test "chroot narrows absolute paths to the new root [linux-chroot]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try chrootCase(&le, "narrow");
}

test ".. at a chroot's root stays there [linux-chroot]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try chrootCase(&le, "dotdot");
}

test "an absolute link in a chroot resolves from its root [linux-chroot]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try chrootCase(&le, "link");
}

test "the working directory keeps working across a chroot, named from the new root under it [linux-chroot]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try chrootCase(&le, "cwd");
    try chrootCase(&le, "outside");
}

test "fork and exec keep the chroot [linux-chroot]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try chrootCase(&le, "fork");
    try chrootCase(&le, "exec");
}

test "an fd from before a chroot leads back out to the Linux view's top [linux-chroot]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try chrootCase(&le, "escape");
}

test "chroot to the Linux view's top changes nothing [linux-chroot]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try chrootCase(&le, "top");
}

test "chroot of a file or a missing path fails as on Linux [linux-chroot]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try chrootCase(&le, "errors");
}

test "mount, umount2, pivot_root, and unshare stay refused [linux-chroot]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try chrootCase(&le, "refused");
}

test "a socket leaves a chroot as it was [linux-chroot]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try chrootCase(&le, "socket");
}

test "busybox chroot runs a dynamic program in a staging tree [linux-chroot]" {
    // busybox and ld-musl copied into a host directory: exec finds the
    // interpreter, and sh its applets, in the chroot. Links in a host
    // tree are EPERM on Windows hosts.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const script =
        \\mkdir -p r/bin r/lib r/etc; cp /bin/busybox r/bin/; cp /lib/ld-musl-* r/lib/
        \\for a in sh ls cat pwd; do ln -s busybox r/bin/$a; done; echo staged > r/etc/motd
        \\chroot r /bin/sh -c 'ls /; cat /etc/motd; cd ../..; pwd; cat /etc/os-release 2>/dev/null || echo none'
    ;
    try linkCase(&le, &s, &.{}, script, "bin\netc\nlib\nstaged\n/\nnone\n");
}

// Named pipes (design/epoch-0/linux-fifo.md), with tests/fixtures/linux/fifo.c.

/// Runs the fifo fixture's case `name` in the machine's /tmp, and then in
/// a `--writable` host directory, where its FIFOs are host FIFOs.
fn fifoCase(le: *const LinuxEnv, name: []const u8) !void {
    var want_buf: [64]u8 = undefined;
    const want = try std.fmt.bufPrint(&want_buf, "ok {s}\n", .{name});
    try netCase(le, &.{ "/mnt/term/cwd/fifo", name }, want);
    // Windows has no host FIFOs: mkfifo in a host tree fails there.
    if (builtin.os.tag == .windows) return;
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "DIR=/mnt/term{s}", .{s.path});
    try netCase(le, &.{ "--writable", s.path, "env", dir, "/mnt/term/cwd/fifo", name }, want);
}

test "mkfifo makes a FIFO that stat reports [linux-fifo]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try fifoCase(&le, "make");
    if (builtin.os.tag == .windows) return;
    // The host sees a host FIFO, which stays after the machine ends.
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var sb: [std.Io.Dir.max_path_bytes + 64]u8 = undefined;
    const script = try std.fmt.bufPrint(&sb, "mkfifo /mnt/term{s}/f && stat -c %F /mnt/term{s}/f && ls -l /mnt/term{s} | cut -c1", .{ s.path, s.path, s.path });
    const r = try runLinux(&le, false, &.{ "--writable", s.path, "sh", "-c", script });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("fifo\nt\np\n", r.out);
    const st = try s.tmp.dir.statFile(std.testing.io, "f", .{});
    try std.testing.expectEqual(std.Io.File.Kind.named_pipe, st.kind);
}

test "a writer and a reader meet through a FIFO [linux-fifo]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    const r = try runLinux(&le, false, &.{ "sh", "-c", "mkfifo /tmp/f; echo hi > /tmp/f & cat /tmp/f; wait; cat /tmp/f & echo again > /tmp/f; wait" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("hi\nagain\n", r.out);
    try std.testing.expectEqual(0, r.code);
    try fifoCase(&le, "meet");
}

test "a nonblocking write open with no reader fails with ENXIO [linux-fifo]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try fifoCase(&le, "nonblock");
    try fifoCase(&le, "epipe");
}

test "O_RDWR opens a FIFO without waiting [linux-fifo]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try fifoCase(&le, "rdwr");
    // The job token pool that stdenv's fixupPhase and GNU make keep.
    try fifoCase(&le, "tokens");
}

test "a FIFO open is interrupted by a signal [linux-fifo]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try fifoCase(&le, "intr");
}

test "a Linux root without resolv.conf gets the host's DNS servers, and a UDP client may bind port 0 [linux-net]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    // Alpine's minirootfs has no /etc/resolv.conf: devlinux's is unioned
    // after the root's /etc, which keeps the rest. busybox nslookup binds
    // its UDP socket to port 0 before connecting, which --net outbound
    // can't announce; it goes on to query (nothing answers on 127.0.0.1).
    // resolv.conf's stat length is its text's: c-ares (curl) sizes it
    // first, and took a 0-length one as empty.
    const script =
        \\grep -q '^nameserver ' /etc/resolv.conf && echo dns
        \\[ "$(stat -c %s /etc/resolv.conf)" -eq "$(wc -c < /etc/resolv.conf)" ] && echo size
        \\[ -f /etc/alpine-release ] && echo etc
        \\ls /etc | grep -c '^resolv.conf$'
        \\echo made > /etc/h9-new && cat /etc/h9-new && rm /etc/h9-new
        \\nslookup -timeout=1 -retry=0 h9.invalid 127.0.0.1 2>&1 | grep -c 'bind:'
    ;
    const r = try runLinux(&le, false, &.{ "--net", "outbound", "sh", "-c", script });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("dns\nsize\netc\n1\nmade\n0\n", r.out);
}

// The machine's resolver (design/linux-dns.md): busybox's nc and nslookup
// on the Alpine root, with the stub DNS server (tests/dnsstub.zig) in the
// place of the host's, through H9_TEST_NAMESERVERS, and a service on the
// host's loopback for nc to reach.

const DnsCase = struct {
    le: LinuxEnv,
    stub: dnsstub.Stub,
    svc: dnsstub.Service = .{},
    pat_buf: [64]u8 = undefined,
    cmd_buf: [512]u8 = undefined,

    fn init(d: *DnsCase, comptime src: std.builtin.SourceLocation, records: []const dnsstub.Record, truncate: []const []const u8) !void {
        if (!dnsstub.supported) return error.SkipZigTest;
        try linuxEnv(src, &d.le);
        d.stub = .{ .records = records, .truncate = truncate };
        d.svc = .{};
        try d.stub.start();
        errdefer d.stub.stop();
        try d.svc.start();
    }

    fn deinit(d: *DnsCase) void {
        d.svc.stop();
        d.stub.stop();
    }

    /// `tcp!NAME!PORT`, for the service's port.
    fn allow(d: *DnsCase, name: []const u8) ![]const u8 {
        return std.fmt.bufPrint(&d.pat_buf, "tcp!{s}!{d}", .{ name, d.svc.port });
    }

    /// A script with {port} in place of the service's port, through sh.
    fn script(d: *DnsCase, comptime fmt: []const u8) ![]const u8 {
        return std.fmt.bufPrint(&d.cmd_buf, fmt, .{ .port = d.svc.port });
    }

    fn run(d: *DnsCase, args: []const []const u8) !Result {
        var environ = try std.testing.environ.createMap(gpa);
        defer environ.deinit();
        try environ.put("H9_TEST_NAMESERVERS", d.stub.nameserver());
        return runLinuxEnv(&d.le, false, args, &environ);
    }

    fn expect(d: *DnsCase, args: []const []const u8, want: []const u8) !void {
        const r = try d.run(args);
        defer r.deinit();
        errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
        try std.testing.expectEqualStrings(want, r.out);
    }
};

const svc_records = [_]dnsstub.Record{.{ .name = "svc.test", .a = .{ 127, 0, 0, 1 } }};

test "a Linux program's lookup of an allowed name connects [linux-dns]" {
    var d: DnsCase = undefined;
    try d.init(@src(), &svc_records, &.{});
    defer d.deinit();
    try d.expect(&.{ "--net-allow", try d.allow("svc.test"), "sh", "-c", try d.script("nc svc.test {[port]d}") }, "hello\n");
    try std.testing.expect(d.svc.conns.load(.acquire) > 0);
    try std.testing.expect(d.stub.queries() > 0);
}

test "a name outside --net-allow gets REFUSED, and isn't forwarded [linux-dns]" {
    var d: DnsCase = undefined;
    try d.init(@src(), &svc_records, &.{});
    defer d.deinit();
    try d.expect(&.{ "--net-allow", try d.allow("svc.test"), "sh", "-c", "nslookup other.test > /tmp/o 2>&1; grep -q REFUSED /tmp/o && echo refused; nc other.test 80 2>/dev/null || echo failed" }, "refused\nfailed\n");
    try std.testing.expectEqual(0, d.stub.queries());
}

test "a connect by address without a lookup is refused [linux-dns]" {
    var d: DnsCase = undefined;
    try d.init(@src(), &svc_records, &.{});
    defer d.deinit();
    try d.expect(&.{ "--net-allow", try d.allow("svc.test"), "sh", "-c", try d.script("nc 127.0.0.1 {[port]d} 2>/dev/null || echo refused") }, "refused\n");
    try std.testing.expectEqual(0, d.svc.conns.load(.acquire));
}

test "a CNAME's addresses are recorded under the question's name [linux-dns]" {
    var d: DnsCase = undefined;
    try d.init(@src(), &.{
        .{ .name = "alias.test", .cname = "edge.cdn.test" },
        .{ .name = "edge.cdn.test", .a = .{ 127, 0, 0, 1 } },
    }, &.{});
    defer d.deinit();
    // Only the question's name has a pattern; the CDN's name has none.
    try d.expect(&.{ "--net-allow", try d.allow("alias.test"), "sh", "-c", try d.script("nc alias.test {[port]d}") }, "hello\n");
}

test "a truncated answer retries over TCP through the resolver [linux-dns]" {
    var d: DnsCase = undefined;
    try d.init(@src(), &.{.{ .name = "big.test", .a = .{ 127, 0, 0, 1 } }}, &.{"big.test"});
    defer d.deinit();
    try d.expect(&.{ "--net-allow", try d.allow("big.test"), "sh", "-c", try d.script("nc big.test {[port]d}") }, "hello\n");
    try std.testing.expect(d.stub.tcp_queries.load(.acquire) > 0);
}

test "a root's own resolv.conf server is redirected too [linux-dns]" {
    var d: DnsCase = undefined;
    try d.init(@src(), &svc_records, &.{});
    defer d.deinit();
    // 192.0.2.53 is a documentation address nothing answers at. The root
    // gets it through a member on /etc, not by writing /etc/resolv.conf:
    // Alpine's minirootfs has none, so the one there is #Letc's, which
    // can't be written, and a failed write would leave the host's
    // servers to answer.
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try writeTree(&s, &.{.{ "etc/resolv.conf", "nameserver 192.0.2.53\n" }});
    var p: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    try d.expect(&.{ "--dir", try std.fmt.bufPrint(&p, "{s}/etc:#L/etc", .{s.path}), "--net-allow", try d.allow("svc.test"), "sh", "-c", try d.script("grep -qx 'nameserver 192.0.2.53' /etc/resolv.conf && nc svc.test {[port]d}") }, "hello\n");
    try std.testing.expect(d.stub.queries() > 0);
}

test "without name patterns, port 53 isn't redirected [linux-dns]" {
    var d: DnsCase = undefined;
    try d.init(@src(), &svc_records, &.{});
    defer d.deinit();
    var pat_buf: [64]u8 = undefined;
    const by_addr = try std.fmt.bufPrint(&pat_buf, "tcp!127.0.0.1!{d}", .{d.svc.port});
    // The query goes to port 53 on 127.0.0.1 itself, not to the stub.
    for ([_][]const []const u8{ &.{ "--net-allow", "udp!127.0.0.1!53", "--net-allow", by_addr }, &.{} }) |pats| {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(gpa);
        try args.appendSlice(gpa, pats);
        try args.appendSlice(gpa, &.{ "sh", "-c", "nslookup -timeout=1 -retry=0 svc.test 127.0.0.1 > /tmp/o 2>&1; grep -q 'Address: 127.0.0.1$' /tmp/o || echo direct" });
        try d.expect(args.items, "direct\n");
    }
    try std.testing.expectEqual(0, d.stub.queries());
}

test "--print shows the resolver caveat [linux-dns]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    const caveat = "DNS queries to port 53 go to h9's resolver, which forwards names the allowlist covers to the host's DNS servers";
    const r = try runLinux(&le, false, &.{ "--print", "--net-allow", "tcp!registry.npmjs.org!443", "sh" });
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\n", .{r.out});
    try std.testing.expect(std.mem.indexOf(u8, r.out, caveat) != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "link-local DNS server") == null);
    const a = try runLinux(&le, false, &.{ "--print", "--net-allow", "tcp!10.0.0.0/8!443", "sh" });
    defer a.deinit();
    try std.testing.expect(std.mem.indexOf(u8, a.out, caveat) == null);
}

// 32-bit x86 Linux programs (design/epoch-0/linux-i386.md): Alpine's x86 root
// and the 386 fixtures on the emulator, whatever the host. With
// -Darch=386 the cases above run them too.
// 32-bit Wine takes a second TLS entry for %fs, beside libc's %gs, and
// returns from its syscalls with IRET (tests/fixtures/linux/tls386.c).
test "set_thread_area gives TLS entries 6 to 8, %fs keeps its own base, and IRET returns at ring 3 [linux-i386]" {
    try skipPending(@src().fn_name);
    const h9 = getenv(0, "H9_TEST_BIN") orelse return error.SkipZigTest;
    const fx = getenv(2, "H9_TEST_LINUX") orelse return error.SkipZigTest;
    var fb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const fixtures = try std.fmt.bufPrint(&fb, "{s}/386", .{fx});
    std.Io.Dir.cwd().access(std.testing.io, try hostPath(fixtures, "tls386"), .{}) catch return error.SkipZigTest;
    const p = try runProcessWith(&.{ h9, "--engine", "hcpu", "--arch", "386", "--cwd", fixtures, "/mnt/term/cwd/tls386" }, null, null, 60_000);
    defer gpa.free(p.stdout);
    defer gpa.free(p.stderr);
    if (std.mem.indexOf(u8, p.stderr, "emulator isn't built") != null) return error.SkipZigTest;
    errdefer std.debug.print("stderr: {s}\n", .{p.stderr});
    try std.testing.expectEqualStrings("ok tls386\n", p.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, p.term);
}

test "an Alpine x86 shell runs on the emulator, with TLS, signals, pipes, and fork (demo) [linux-i386]" {
    try skipPending(@src().fn_name);
    const h9 = getenv(0, "H9_TEST_BIN") orelse return error.SkipZigTest;
    const lr = getenv(3, "H9_TEST_LINUX_ROOT") orelse return error.SkipZigTest;
    const fx = getenv(2, "H9_TEST_LINUX") orelse return error.SkipZigTest;
    var rb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var fb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var lb: [std.Io.Dir.max_path_bytes + 3]u8 = undefined;
    const root = try std.fmt.bufPrint(&rb, "{s}/alpine-386", .{lr});
    const fixtures = try std.fmt.bufPrint(&fb, "{s}/386", .{fx});
    std.Io.Dir.cwd().access(std.testing.io, try hostPath(root, "etc/os-release"), .{}) catch return error.SkipZigTest;
    std.Io.Dir.cwd().access(std.testing.io, try hostPath(fixtures, "threads"), .{}) catch return error.SkipZigTest;
    // busybox is a dynamic PIE, so the loader's TLS is set up through
    // set_thread_area; the trap runs a handler and returns through
    // sigreturn; the pipeline and $(...) fork; threads gives each thread
    // its own TLS base, and forks from one.
    const script =
        \\uname -m
        \\trap 'echo usr1' USR1; kill -USR1 $$
        \\echo $(ls /etc | grep -c release)
        \\/mnt/term/cwd/threads timed_tls fork_thread
    ;
    const p = try runProcessWith(&.{ h9, "--engine", "hcpu", "--arch", "386", "--dir", try std.fmt.bufPrint(&lb, "{s}:#L", .{root}), "--cwd", fixtures, "/bin/sh", "-c", script }, null, null, 120_000);
    defer gpa.free(p.stdout);
    defer gpa.free(p.stderr);
    if (std.mem.indexOf(u8, p.stderr, "emulator isn't built") != null) return error.SkipZigTest;
    errdefer std.debug.print("stderr: {s}\n", .{p.stderr});
    try std.testing.expectEqualStrings("i686\nusr1\n2\nok timed_tls\nok fork_thread\n", p.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, p.term);
}

test "a mode set by mkdir, creat, or chmod reads back, as databases check of their data directories [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    // PostgreSQL won't start unless its data directory is 0700 or 0750.
    // The web host's WASI has no permission bits, so devfs keeps them.
    const script =
        \\umask 077; mkdir /tmp/d; touch /tmp/d/f
        \\stat -c %a /tmp/d /tmp/d/f
        \\chmod 750 /tmp/d; chmod 640 /tmp/d/f
        \\stat -c %a /tmp/d /tmp/d/f
    ;
    const r = try runLinux(&le, false, &.{ "sh", "-c", script });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("700\n600\n750\n640\n", r.out);
}

test "mkdir of anything already there is EEXIST and leaves it alone, and makes deep and slashed paths in the root's overlay [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    // A create without OEXCL opened an existing file with truncation (and
    // mkdir returned 0), and an existing directory with EISDIR, which
    // Node's recursive mkdir takes as done before it has made the rest of
    // the path. The deep directories make the overlay re-walk a path
    // longer than the smallest malloc chunk, which unreroot used to read
    // after freeing it.
    const script =
        \\cd /root
        \\mkdir -p a-long-directory-name/another-long-directory-name && mkdir a-long-directory-name/another-long-directory-name/leaf && echo made
        \\echo data > f; mkdir f 2>/dev/null; echo $?; cat f
        \\ln -s /nonexistent dangling; mkdir dangling 2>/dev/null; echo $?
        \\mkdir d/ && mkdir d// 2>/dev/null; echo $?
        \\for i in 1 2 3 4 5 6 7 8; do (mkdir -p race/a/b/c || echo fail) & done; wait; ls race/a/b
    ;
    const r = try runLinux(&le, false, &.{ "sh", "-c", script });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("made\n1\ndata\n1\n1\nc\n", r.out);
}

test "a Linux process that touches a page past --memory is killed, as by the OOM killer, and h9 says why [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    // Each 1 MiB written takes a new chunk; 64m runs out well before 128.
    const r = try runLinux(&le, false, &.{ "--memory", "64m", "sh", "-c", "head -c 134217728 /dev/zero | tr '\\000' x | (v=$(cat); echo ${#v}); echo status $?" });
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expect(std.mem.indexOf(u8, r.out, "status 137") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "ran out of guest memory") != null);
}

test "9front and Linux programs share pipelines both ways (demo) [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    // Linux sh runs 9front programs under /9 ...
    const lx = try runLinux(&le, true, &.{ "sh", "-c", "echo x y | /9/bin/wc -w | tr -d ' '; /9/bin/rc -c 'exit oops'; echo $?" });
    defer lx.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{lx.err});
    try std.testing.expectEqualStrings("2\n1\n", lx.out);
    try std.testing.expectEqual(0, lx.code);
    // ... and rc runs Linux programs through #L.
    const nine = try runLinux(&le, true, &.{ "--rc", "echo hi | '#L/usr/bin/wc' -c; '#L/bin/sh' -c 'kill -TERM $$'; echo $status" });
    defer nine.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{nine.err});
    try std.testing.expect(std.mem.startsWith(u8, nine.out, "3\n"));
    try std.testing.expect(std.mem.indexOf(u8, nine.out, "linux: signal 15") != null);
}

test "a Linux program runs a #!/bin/rc script with 9front's rc [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    // The Linux root has no /bin/rc, so it's 9front's; a script under /9,
    // such as h9's wsmount, is opened by rc at its 9front path.
    const r = try runLinux(&le, true, &.{ "sh", "-c", "printf '#!/bin/rc\\necho rc $*\\n' >/tmp/s && chmod +x /tmp/s && /tmp/s a b; /9/bin/wsmount; echo $?" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("rc a b\n1\n", r.out);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "usage: wsmount") != null);
}

// What databases need of files (design/epoch-0/linux-personality.md),
// through tests/fixtures/linux/files.c, which prints "ok NAME" per case.

test "fcntl record locks conflict across processes, wait, and go when the owner closes an fd or exits [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "posix_locks" }, "ok posix_locks\n");
}

test "OFD locks belong to the open file, and flock shares, excludes and follows dup [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "ofd_flock" }, "ok ofd_flock\n");
}

test "exec closing a child's last close-on-exec fd of a file releases its flock [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "flock_exec" }, "ok flock_exec\n");
}

test "processes mapping a file MAP_SHARED see each other's stores, read and write agree, and the file keeps them [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "shared_map" }, "ok shared_map\n");
}

test "fsync works, and wait4 and getrusage report CPU time [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "fsync_rusage" }, "ok fsync_rusage\n");
}

test "fsync on a directory, syncfs and sync reach the host [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "dir_sync" }, "ok dir_sync\n");
    // A durable rename needs the host to sync the directory: on a Linux
    // host with a working strace, check that the host calls happen, on a
    // host directory (the guest's /tmp is in memory), and never on fd 0,
    // which a directory's devfs channel used to have as its file's fd.
    if (!haveStrace()) return;
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "DIR=/mnt/term{s}", .{s.path});
    var trace_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const trace = try std.fmt.bufPrint(&trace_buf, "{s}/trace", .{s.path});
    var it = std.mem.tokenizeScalar(u8, le.engines, ',');
    const p = try runProcessWith(&.{
        "strace", "-f",     "-y",    "-qq",                 "-e",                    "trace=fsync,fdatasync,syncfs,sync",
        "-o",     trace,    le.h9,   "--engine",           it.next() orelse "auto", "--arch",
        le.arch,  "--dir", le.lmount, "--cwd",               le.fixtures,             "--writable",
        s.path,   "env",    dir,     "/mnt/term/cwd/files", "dir_sync",
    }, null, null, 120_000);
    defer gpa.free(p.stdout);
    defer gpa.free(p.stderr);
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ p.stdout, p.stderr });
    try std.testing.expectEqualStrings("ok dir_sync\n", p.stdout);
    const st = try s.tmp.dir.readFileAlloc(std.testing.io, "trace", gpa, .limited(1 << 20));
    defer gpa.free(st);
    errdefer std.debug.print("strace: {s}\n", .{st});
    var dir_fsyncs: usize = 0;
    var syncfs = false;
    var sync = false;
    var lines = std.mem.tokenizeScalar(u8, st, '\n');
    while (lines.next()) |l| {
        try std.testing.expect(std.mem.indexOf(u8, l, "sync(0") == null);
        var tail_buf: [std.Io.Dir.max_path_bytes + 2]u8 = undefined;
        const on_dir = std.mem.indexOf(u8, l, try std.fmt.bufPrint(&tail_buf, "<{s}>)", .{s.path})) != null;
        if (on_dir and std.mem.indexOf(u8, l, " fsync(") != null) dir_fsyncs += 1;
        if (on_dir and std.mem.indexOf(u8, l, " syncfs(") != null) syncfs = true;
        if (std.mem.indexOf(u8, l, " sync()") != null) sync = true;
    }
    // fsync and fdatasync on the directory.
    try std.testing.expect(dir_fsyncs >= 2);
    try std.testing.expect(syncfs and sync);
}

/// A Linux host with a working strace, for tests that check which host
/// calls h9 makes.
fn haveStrace() bool {
    if (builtin.os.tag != .linux) return false;
    const p = runProcessWith(&.{ "strace", "-o", "/dev/null", "true" }, null, null, 10_000) catch return false;
    defer gpa.free(p.stdout);
    defer gpa.free(p.stderr);
    return p.term == .exited and p.term.exited == 0;
}

test "writes through an fd opened O_DSYNC or O_SYNC sync the host file [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "sync_open" }, "ok sync_open\n");
    // The program never calls fsync: each write through an O_DSYNC or
    // O_SYNC fd must make h9 fsync the host file, and a plain fd's must not.
    if (!haveStrace()) return;
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "DIR=/mnt/term{s}", .{s.path});
    var trace_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const trace = try std.fmt.bufPrint(&trace_buf, "{s}/trace", .{s.path});
    var it = std.mem.tokenizeScalar(u8, le.engines, ',');
    const p = try runProcessWith(&.{
        "strace", "-f",     "-y",    "-qq",                 "-e",                    "trace=fsync,fdatasync",
        "-o",     trace,    le.h9,   "--engine",           it.next() orelse "auto", "--arch",
        le.arch,  "--dir",  le.lmount, "--cwd",               le.fixtures,             "--writable",
        s.path,   "env",    dir,     "/mnt/term/cwd/files", "sync_open",
    }, null, null, 120_000);
    defer gpa.free(p.stdout);
    defer gpa.free(p.stderr);
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ p.stdout, p.stderr });
    try std.testing.expectEqualStrings("ok sync_open\n", p.stdout);
    const st = try s.tmp.dir.readFileAlloc(std.testing.io, "trace", gpa, .limited(1 << 20));
    defer gpa.free(st);
    errdefer std.debug.print("strace: {s}\n", .{st});
    var counts = [_]usize{ 0, 0, 0 };
    const names = [_][]const u8{ "odsync", "osync", "plain" };
    var lines = std.mem.tokenizeScalar(u8, st, '\n');
    while (lines.next()) |l| for (names, 0..) |n, i| {
        var tail_buf: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
        if (std.mem.indexOf(u8, l, try std.fmt.bufPrint(&tail_buf, "{s}/{s}>)", .{ s.path, n })) != null) counts[i] += 1;
    };
    // write, writev, and pwrite through the O_DSYNC fd; one write through O_SYNC.
    try std.testing.expect(counts[0] >= 3);
    try std.testing.expect(counts[1] >= 1);
    try std.testing.expectEqual(@as(usize, 0), counts[2]);
}

test "page-by-page preads read ahead, and see writes and truncates at once [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "read_cache" }, "ok read_cache\n");
}

test "fallocate grows a file, KEEP_SIZE doesn't, and holes are EOPNOTSUPP [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "falloc" }, "ok falloc\n");
}

test "rename across directories moves in an overlay, and is the host's rename in a host tree [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "rename_across" }, "ok rename_across\n");
    // On Windows a host tree's rename across directories is EXDEV, for
    // the sandbox's sake (devfs-win32.c's h9_fs_rename).
    if (builtin.os.tag == .windows) return;
    // In a writable host directory, as Redis's AOF dir is.
    var sc: Scratch = undefined;
    try sc.init();
    defer sc.deinit();
    var fb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try std.Io.Dir.copyFile(std.Io.Dir.cwd(), try std.fmt.bufPrint(&fb, "{s}/files", .{le.fixtures}), sc.tmp.dir, "files", std.testing.io, .{});
    var bit = std.mem.tokenizeScalar(u8, le.engines, ',');
    const p = try runProcessWith(&.{ le.h9, "--engine", bit.next() orelse "auto", "--arch", le.arch, "--dir", le.lmount, "--cwd", sc.path, "--writable", sc.path, "--env", "DIR=.", "sh", "-c", "./files rename_across" }, null, null, 120_000);
    defer gpa.free(p.stdout);
    defer gpa.free(p.stderr);
    errdefer std.debug.print("stderr: {s}\n", .{p.stderr});
    try std.testing.expectEqualStrings("ok rename_across\n", p.stdout);
}

test "a mode-0000 file in a host tree can have its times and mode set and be renamed, as apk's etc/shadow is [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    // devfs-win32's host files have no Unix permission bits.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    // In a writable host directory, where h9 changes the host file. Run
    // as root, the host lets h9 open the file anyway; as anyone else,
    // h9 mustn't need to open it.
    var sc: Scratch = undefined;
    try sc.init();
    defer sc.deinit();
    var fb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try std.Io.Dir.copyFile(std.Io.Dir.cwd(), try std.fmt.bufPrint(&fb, "{s}/files", .{le.fixtures}), sc.tmp.dir, "files", std.testing.io, .{});
    var bit = std.mem.tokenizeScalar(u8, le.engines, ',');
    const p = try runProcessWith(&.{ le.h9, "--engine", bit.next() orelse "auto", "--arch", le.arch, "--dir", le.lmount, "--cwd", sc.path, "--writable", sc.path, "--env", "DIR=.", "sh", "-c", "./files mode_zero" }, null, null, 120_000);
    defer gpa.free(p.stdout);
    defer gpa.free(p.stderr);
    errdefer std.debug.print("stderr: {s}\n", .{p.stderr});
    try std.testing.expectEqualStrings("ok mode_zero\n", p.stdout);
}

test "CPUID shows no AVX feature in any leaf where it hides AVX, as Zig reads it [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "cpuid_avx" }, "ok cpuid_avx\n");
}

test "an arm64 Linux program can read the ID registers, as HWCAP_CPUID says [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "id_regs" }, "ok id_regs\n");
}

test "madvise MADV_FREE is EINVAL, and MADV_DONTNEED zeroes [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "madv_free" }, "ok madv_free\n");
}

test "MADV_DONTNEED over whole chunks frees them, and they read zero after [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "madv_release" }, "ok madv_release\n");
}

test "MADV_DONTNEED on the program's own data segment leaves the file's bytes [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "image_dontneed" }, "ok image_dontneed\n");
}

test "a path through /proc/self/fd/N walks on from the directory the fd names [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "proc_fd_dir" }, "ok proc_fd_dir\n");
}

test "/proc/self/exe opens and stats as the program's file, as rustup-init.sh reads it [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "proc_exe" }, "ok proc_exe\n");
}

test "lseek to the end of a file with a long name, as rustup resumes a download [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "seek_long_name" }, "ok seek_long_name\n");
}

test "mremap over two adjacent anonymous mappings sees one, and a blocked grow in place is ENOMEM [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "mremap_span" }, "ok mremap_span\n");
}

test "System V shared memory: a keyed segment, shared across fork, its attach count, and removal [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "sysv_shm" }, "ok sysv_shm\n");
}

test "a process that exits with a file mapped shared writes it back on the way out [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "map_exit" }, "ok map_exit\n");
}

test "prctl PR_SET_NAME keeps the first 15 bytes of a longer name [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "prctl_name" }, "ok prctl_name\n");
}

test "a fixed MAP_SHARED file mapping can sit at any page beside private ones, even across a MiB, and fork, munmap, and remap keep it right [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "fixed_shared" }, "ok fixed_shared\n");
}

test "a MAP_PRIVATE file mapping sees the file's changes until it writes a page, and its writes stay its own [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "private_sees" }, "ok private_sees\n");
}

test "on amd64, arch_prctl ARCH_SET_GS sets the GS base a %gs load reads, and fork keeps it [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "gs_base" }, "ok gs_base\n");
}

test "process-shared semaphores in MAP_SHARED memory work across fork, on pages touched only after it [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "shared_sem" }, "ok shared_sem\n");
}

test "signalfd turns blocked signals into reads, and wakes epoll from itself and another process [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "signal_fd" }, "ok signal_fd\n");
}

test "setitimer and alarm deliver SIGALRM, once or repeating [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "itimer" }, "ok itimer\n");
}

test "root can become another user and its groups, and can't come back [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "creds" }, "ok creds\n");
}

test "600 files open at once in a host tree, past macOS's soft fd limit [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "host_fds" }, "ok host_fds\n");
}

test "a process past 100 fds gets no Plan 9 warning on its stderr [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "many_fds" }, "ok many_fds\n");
}

test "an open file survives unlink for ftruncate, fstat, and mmap, and memfd_create makes one [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "unlinked" }, "ok unlinked\n");
}

test "a memfd passed with SCM_RIGHTS keeps its data after the sender unmaps and closes it [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "shm_pass" }, "ok shm_pass\n");
}

test "a private file mapping reads each page from its file offset on first touch, after close, fork, mremap, and MADV_DONTNEED [linux-personality]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "lazy_map" }, "ok lazy_map\n");
}

// Pseudoterminals (design/epoch-0/linux-pty.md), through
// tests/fixtures/linux/pty.c, which prints "ok NAME" per case.

test "posix_openpt, grantpt, unlockpt, and ptsname give an open slave [linux-pty]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/pty", "openpt" }, "ok openpt\n");
}

test "the master reads EOF once the slave closes [linux-pty]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/pty", "eof" }, "ok eof\n");
}

test "a raw pty passes bytes unchanged [linux-pty]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/pty", "raw" }, "ok raw\n");
}

test "a locked slave doesn't open, and TIOCGPTPEER opens it from the master [linux-pty]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/pty", "locked" }, "ok locked\n");
}

test "poll and O_NONBLOCK see a pty's queues [linux-pty]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/pty", "nonblock" }, "ok nonblock\n");
}

test "TIOCSWINSZ sends SIGWINCH to the foreground group [linux-pty]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/pty", "winch" }, "ok winch\n");
}

test "closing the master sends SIGHUP to the foreground group and hangs up the slave [linux-pty]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/pty", "hangup" }, "ok hangup\n");
}

test "a canonical pty edits lines and echoes [linux-pty]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/pty", "canon" }, "ok canon\n");
}

test "Ctrl-C written to the master interrupts the foreground group [linux-pty]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/pty", "intr" }, "ok intr\n");
}

test "Python's pty.spawn runs a command in a pty [linux-pty]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    // The workloads' root (scripts/fetch.sh workloads) has Python.
    if (!std.mem.eql(u8, le.arch, "amd64")) return error.SkipZigTest;
    const lr = getenv(3, "H9_TEST_LINUX_ROOT") orelse return error.SkipZigTest;
    var rb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    le.root = try std.fmt.bufPrint(&rb, "{s}/workloads-amd64", .{lr});
    le.lmount = try std.fmt.bufPrint(&le.lbuf, "{s}:#L", .{le.root});
    std.Io.Dir.cwd().access(std.testing.io, try hostPath(le.root, "usr/bin/python3"), .{}) catch return error.SkipZigTest;
    const r = try runLinux(&le, false, &.{ "python3", "-c", "import pty; pty.spawn([\"tty\"])" });
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    // ONLCR makes the newline CR LF.
    try std.testing.expectEqualStrings("/dev/pts/0\r\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

// Readiness and sockets (design/epoch-0/linux-net.md), through
// tests/fixtures/linux/net.c, which prints "ok NAME" per case.

fn netCase(le: *const LinuxEnv, args: []const []const u8, want: []const u8) !void {
    const r = try runLinux(le, false, args);
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqualStrings(want, r.out);
    try std.testing.expectEqual(0, r.code);
}

test "poll on a pipe wakes when the writer writes [linux-net]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/net", "poll_pipe" }, "ok poll_pipe\n");
}

test "O_NONBLOCK read on an empty pipe is EAGAIN, and select agrees [linux-net]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/net", "nonblock_pipe" }, "ok nonblock_pipe\n");
}

test "readv from a pipe returns what's there once a buffer fills [linux-net]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/net", "readv_pipe" }, "ok readv_pipe\n");
}

test "epoll edge-triggered on a pipe [linux-net]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/net", "epoll_et" }, "ok epoll_et\n");
}

test "eventfd counts and wakes epoll [linux-net]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/net", "eventfd" }, "ok eventfd\n");
}

test "an edge-triggered eventfd that stays readable wakes epoll_wait in another thread on every write [linux-net]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/net", "eventfd_waker" }, "ok eventfd_waker\n");
}

test "F_DUPFD in several threads takes a free fd without replacing one another thread just opened [linux-net]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/net", "dupfd_threads" }, "ok dupfd_threads\n");
}

test "threads draining dups of one nonblocking pipe get EAGAIN, not a read that waits [linux-net]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/net", "pipe_drain" }, "ok pipe_drain\n");
}

test "named and abstract Unix sockets: bind, listen, epoll, accept, connect, and refused once closed [linux-net]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/net", "unix_sock" }, "ok unix_sock\nok unix_abstract\n");
}

test "SCM_RIGHTS passes fds over a Unix socket, one batch per message, with MSG_CMSG_CLOEXEC [linux-net]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/net", "scm_rights" }, "ok scm_rights\n");
}

test "SEQPACKET socket pairs keep message bounds, pass SCM_CREDENTIALS, and stay sockets through SCM_RIGHTS [linux-net]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/net", "seqpacket" }, "ok seqpacket\n");
}

test "socket under --net=disable is EACCES [linux-net]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "--net=disable", "/mnt/term/cwd/net", "disabled" }, "ok disabled\n");
}

test "TCP echo between a Linux client and server, with getpeername [linux-net]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "--net=enable", "/mnt/term/cwd/net", "tcp_echo" }, "ok tcp_echo\n");
}

test "edge-triggered epoll in another thread reports a TCP socket's next data after a reader drains it [linux-net]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    // The peer is on the host, as .NET's HTTPS proxy was: a peer in the
    // guest wakes h9's pollers when it writes, which hides the bug.
    const io = std.testing.io;
    var srv = try listenLocal();
    defer srv.deinit(io);
    // One connection for each engine netCase runs, in turn.
    const Echo = struct {
        fn serve(sv: *std.Io.net.Server, n: usize) void {
            for (0..n) |_| {
                const c = deadline.accept(sv, io) catch return;
                defer c.close(io);
                var rbuf: [16]u8 = undefined;
                var r = c.reader(io, &rbuf);
                var wbuf: [16]u8 = undefined;
                var w = c.writer(io, &wbuf);
                while (r.interface.takeByte()) |b| {
                    io.sleep(.fromMilliseconds(150), .awake) catch return;
                    w.interface.writeByte(b) catch return;
                    w.interface.flush() catch return;
                } else |_| {}
            }
        }
    };
    var engines = std.mem.tokenizeScalar(u8, le.engines, ',');
    var n: usize = 0;
    while (engines.next()) |_| n += 1;
    const t = try std.Thread.spawn(.{}, Echo.serve, .{ &srv, n });
    defer t.join();
    var port_buf: [64]u8 = undefined;
    const port_env = try std.fmt.bufPrint(&port_buf, "ETD_PORT={d}", .{srv.socket.address.getPort()});
    try netCase(&le, &.{ "--net=enable", "--env", port_env, "/mnt/term/cwd/net", "tcp_et_drain" }, "ok tcp_et_drain\n");
}

test "getsockname on an IPv4 TCP socket between bind and listen gives AF_INET and the bound port [linux-net]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "--net=enable", "/mnt/term/cwd/net", "bound_name" }, "ok bound_name\n");
}

test "non-blocking connect is EINPROGRESS, then writable, then SO_ERROR 0 [linux-net]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "--net=enable", "/mnt/term/cwd/net", "nb_connect" }, "ok nb_connect\n");
}

test "shutdown(SHUT_WR) shows the peer EOF and EPOLLRDHUP [linux-net]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "--net=enable", "/mnt/term/cwd/net", "half_close" }, "ok half_close\n");
}

test "a Linux process that exits holding a TCP connection closes it [linux-net]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "--net=enable", "/mnt/term/cwd/net", "exit_eof" }, "ok exit_eof\n");
}

test "IPv4 and IPV6_V6ONLY IPv6 wildcard listeners share a port, or IPv6 is EAFNOSUPPORT without it [linux-net]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "--net=enable", "/mnt/term/cwd/net", "dual_bind" }, "ok dual_bind\n");
}

test "netlink lists loopback for getifaddrs, and a listener on 127.0.0.1 reports it [linux-net]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "--net=enable", "/mnt/term/cwd/net", "ifaddrs" }, "ok ifaddrs\n");
}

test "a netlink MSG_PEEK|MSG_TRUNC read sizes the next message and leaves it queued [linux-net]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "--net=enable", "/mnt/term/cwd/net", "netlink_peek" }, "ok netlink_peek\n");
}

test "UDP sendto and recvfrom on an unconnected socket [linux-net]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "--net=enable", "/mnt/term/cwd/net", "udp" }, "ok udp\n");
}

test "sendmmsg and recvmmsg batch datagrams, and UDP_SEGMENT and UDP_GRO are refused, as QUIC stacks need [linux-net]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "--net=enable", "/mnt/term/cwd/net", "udp_mmsg" }, "ok udp_mmsg\n");
}

test "FIONREAD on a UDP socket is the next datagram's length, as glibc's resolver sizes its second answer by [linux-net]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "--net=enable", "/mnt/term/cwd/net", "udp_fionread" }, "ok udp_fionread\n");
}

test "two sendtos to one peer from a socket bound to port 0, under --net outbound, as musl's resolver does [linux-net]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    const sock = try addr.bind(std.testing.io, .{ .mode = .dgram });
    defer sock.close(std.testing.io);
    var port_buf: [8]u8 = undefined;
    const port = try std.fmt.bufPrint(&port_buf, "{d}", .{sock.address.getPort()});
    try netCase(&le, &.{ "--net=outbound", "/mnt/term/cwd/net", "udp_twice", port }, "ok udp_twice\n");
    var buf: [16]u8 = undefined;
    const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(slow(5000)), .clock = .awake } };
    // Windows' Io has no receive timeout; both datagrams are queued by
    // the time the run ends, so a plain receive doesn't wait there.
    const recv = struct {
        fn f(s: *const std.Io.net.Socket, b: []u8, t: std.Io.Timeout) ![]const u8 {
            const m = s.receiveTimeout(std.testing.io, b, t) catch |e| switch (e) {
                error.ConcurrencyUnavailable => try s.receive(std.testing.io, b),
                else => return e,
            };
            return m.data;
        }
    }.f;
    try std.testing.expectEqualStrings("A", try recv(&sock, &buf, timeout));
    try std.testing.expectEqualStrings("B", try recv(&sock, &buf, timeout));
}

test "more than 30 TCP connections at once [linux-net]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "--net=enable", "/mnt/term/cwd/net", "many" }, "ok many\n");
}

test "TCP echo between a Linux client and a 9front server [linux-net]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    // aux/listen1 runs cat (a 9front path: listen1 is a 9front program)
    // for one connection; busybox nc talks to it.
    const r = try runLinux(&le, true, &.{ "--net=enable", "sh", "-c", "/9/bin/aux/listen1 -1 -t tcp!127.0.0.1!17007 /bin/cat & sleep 1; echo ping | nc -w 2 127.0.0.1 17007" });
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqualStrings("ping\n", r.out);
}

/// Runs net.c's `case` in a Linux program whose /net is another h9's,
/// served with --serve-net and mounted before its own, under a policy
/// that lets the client reach only the server: every socket is the
/// serving machine's.
fn servedNetCase(comptime src: std.builtin.SourceLocation, case: []const u8) !void {
    var le: LinuxEnv = undefined;
    try linuxEnv(src, &le);
    const e = try serveEnv(src);
    var t = try startServer(e, &.{ "--net=enable", "--serve", "tcp!127.0.0.1!0", "--serve-root", "/net", "--serve-net" });
    defer t.deinit();
    var ab: [128]u8 = undefined;
    const addr = try servedAddr(&t, &ab);
    var cb: [256]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cb, "/9/bin/srv -b '{s}' hostnet /net >/dev/null && /mnt/term/cwd/net {s}", .{ addr, case });
    const r = try runLinux(&le, true, &.{ "--net-allow", addr, "sh", "-c", cmd });
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    var wb: [64]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&wb, "ok {s}\n", .{case}), r.out);
    try std.testing.expectEqual(0, r.code);
}

test "TCP echo through another h9's /net, mounted, with listen and accept [linux-net, serve]" {
    try servedNetCase(@src(), "tcp_echo");
}

test "non-blocking connect and accept through a mounted /net [linux-net, serve]" {
    try servedNetCase(@src(), "nb_connect");
}

test "shutdown(SHUT_WR) and EPOLLRDHUP through a mounted /net [linux-net, serve]" {
    try servedNetCase(@src(), "half_close");
}

test "a Linux process that exits holding a mounted /net's connection closes it [linux-net, serve]" {
    try servedNetCase(@src(), "exit_eof");
}

test "Go net/http server and client in one Linux program [linux-net]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try goLinux(&le);
    try netCase(&le, &.{ "--net=enable", "/mnt/term/cwd/go/nethttp" }, "ok nethttp\n");
}

// Threads (design/epoch-0/linux-threads.md), through
// tests/fixtures/linux/threads.c, which prints "ok NAME" per case, and the
// Go programs in tests/fixtures/linux/go (built when go is on PATH).

/// Skips unless the Linux Go fixtures were built.
fn goLinux(le: *const LinuxEnv) !void {
    std.Io.Dir.cwd().access(std.testing.io, try hostPath(le.fixtures, "go/goroutines"), .{}) catch return error.SkipZigTest;
}

fn threadCase(le: *const LinuxEnv, name: []const u8) !void {
    var want_buf: [64]u8 = undefined;
    try netCase(le, &.{ "/mnt/term/cwd/threads", name }, try std.fmt.bufPrint(&want_buf, "ok {s}\n", .{name}));
}

test "pthreads program with 8 threads and a mutex [linux-threads]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try threadCase(&le, "mutex");
    try threadCase(&le, "condvar");
}

test "getdents64 from many threads, on their own fds and on one shared fd [linux-threads]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try threadCase(&le, "getdents_threads");
}

test "a signal breaks the read of a second thread blocked on the same pipe [linux-threads]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try threadCase(&le, "pipe_intr");
}

test "a thread's scheduling parameters read back as SCHED_OTHER at priority 0 [linux-threads]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try threadCase(&le, "sched_params");
}

test "thread-local storage, timed waits and fork from a thread [linux-threads]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try threadCase(&le, "timed_tls");
    try threadCase(&le, "fork_thread");
}

test "a Linux program's termios reaches the host terminal: echo off keeps lines, ICANON off is raw and keeps echo [linux-personality]" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // no termios to check
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    var it = std.mem.tokenizeScalar(u8, le.engines, ',');
    while (it.next()) |engine| {
        errdefer std.debug.print("engine {s}\n", .{engine});
        var t = try Term.spawn(gpa, &.{ le.h9, "--engine", engine, "--arch", le.arch, "--dir", le.lmount, "--timeout", "120s", "/bin/sh", "-c", "stty -echo; echo ready1; read x; echo got=$x; stty echo raw; echo ready2; dd bs=1 count=1 2>/dev/null; stty sane; echo; echo done" });
        defer t.deinit();
        try t.expect("ready1", slow(30_000));
        try std.testing.expect(t.noEcho());
        // A password isn't echoed, and the line is still edited.
        try t.send("pw\x7fW\n");
        try t.expect("got=pW", slow(10_000));
        try std.testing.expect(std.mem.indexOf(u8, t.out.items, "pw") == null);
        try t.expect("ready2", slow(10_000));
        // Raw with ECHO on, as `read -n1` asks for: the key shows.
        try std.testing.expect(t.raw() and t.echo());
        // Raw: one key, no newline.
        try t.send("k");
        try t.expect("done", slow(10_000));
        try std.testing.expectEqual(0, try t.wait(slow(10_000)));
        try std.testing.expect(t.cooked());
    }
}

test "a Linux program in raw mode gets Enter as CR without ICRNL, polls with VMIN 0, and sees the terminal's size [linux-personality]" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // no termios to check
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    var it = std.mem.tokenizeScalar(u8, le.engines, ',');
    while (it.next()) |engine| {
        errdefer std.debug.print("engine {s}\n", .{engine});
        // fzf tells Enter (CR) from Ctrl-J, and btop reads with VMIN 0
        // until a read returns nothing.
        var t = try Term.spawn(gpa, &.{ le.h9, "--engine", engine, "--arch", le.arch, "--dir", le.lmount, "--timeout", "120s", "/bin/sh", "-c", "echo size=$(stty size); stty raw -echo; echo ready; dd bs=1 count=2 2>/dev/null | od -An -c; stty min 0 time 0; echo poll=$(dd bs=1 count=1 2>/dev/null | wc -c); stty sane; echo done" });
        defer t.deinit();
        try t.expect("size=25 80", slow(30_000));
        try t.expect("ready", slow(10_000));
        try t.send("\r\n");
        try t.expect("\\r  \\n", slow(10_000));
        try t.expect("poll=0", slow(10_000));
        try t.expect("done", slow(10_000));
        try std.testing.expectEqual(0, try t.wait(slow(10_000)));
        try std.testing.expect(t.cooked());
    }
}

test "Go linux binary starts goroutines and sleeps [linux-threads]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try goLinux(&le);
    const r = try runLinux(&le, false, &.{"/mnt/term/cwd/go/goroutines"});
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expect(std.mem.startsWith(u8, r.out, "ok goroutines "));
    try std.testing.expectEqual(0, r.code);
}

test "/proc lists a thread group once, with its threads under task, and statm reads, as htop needs [linux-threads]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try threadCase(&le, "proc_threads");
}

test "/proc/meminfo counts a process's memory once however many threads it has [linux-threads]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try threadCase(&le, "meminfo_threads");
}

test "Go os/exec waits for a child from another thread, and RemoveAll empties a /tmp directory [linux-threads]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try goLinux(&le);
    try netCase(&le, &.{"/mnt/term/cwd/go/goexec"}, "ok goexec\n");
}

test "munmap while another thread reads: no stale access after return [linux-threads]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try threadCase(&le, "munmap");
}

test "a store or read(2) racing another thread's mprotect in the same chunk neither faults nor EFAULTs [linux-threads]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try threadCase(&le, "remap_race");
}

test "threads faulting pages in while others munmap don't fault twice on a mapped page [native-backend]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try threadCase(&le, "fault_race");
}

test "exit_group kills every thread [linux-threads]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    // From the main thread, with threads blocked and spinning ...
    const main_exit = try runLinux(&le, false, &.{ "/mnt/term/cwd/threads", "exit_main" });
    defer main_exit.deinit();
    try std.testing.expectEqualStrings("exiting\n", main_exit.out);
    try std.testing.expectEqual(5, main_exit.code);
    // ... and from another thread, while main waits to join it.
    const thread_exit = try runLinux(&le, false, &.{ "/mnt/term/cwd/threads", "exit_thread" });
    defer thread_exit.deinit();
    try std.testing.expectEqualStrings("", thread_exit.out);
    try std.testing.expectEqual(7, thread_exit.code);
}

test "execve from a non-leader thread [linux-threads]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/threads", "exec_thread" }, "ok exec_thread\n");
}

test "tgkill interrupts a thread in a busy loop [linux-threads]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try threadCase(&le, "tgkill_busy");
    try threadCase(&le, "tgkill_wait");
}

test "CLONE_CHILD_CLEARTID wakes pthread_join [linux-threads]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    // Each join waits on the thread's clear-tid word; the leader's own
    // exit waits for the last thread.
    try threadCase(&le, "timed_tls");
    try netCase(&le, &.{ "/mnt/term/cwd/threads", "leader_exit" }, "ok leader_exit\n");
}

test "a thread spinning without syscalls doesn't starve the others on the emulator [linux-threads]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try threadCase(&le, "spin");
}

test "Go GC with a goroutine in a call-free loop, at 1 ms slices [linux-threads]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try goLinux(&le);
    try netCase(&le, &.{"/mnt/term/cwd/go/gcloop"}, "ok gcloop 20\n");
}

// The web host's cases (design/epoch-0/browser-host.md). They run on
// every engine; what they guard is the web host's: coroutines that park
// for the event loop, a JIT over recycled pages, and stacks without
// guard pages.

test "a spinning process doesn't starve a pipeline [browser-host]" {
    const e = try env(@src());
    // The spinner makes no system calls, so only preemption lets the
    // pipeline run.
    const r = try run(e, &.{ "--timeout", "60s", "--rc", "{while(){}} & spin=$apid; echo hello | tr h H | wc -c; echo kill >/proc/$spin/note" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("      6\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "a console read parks and resumes on input [browser-host]" {
    const e = try env(@src());
    var it = engineList(e);
    while (it.next()) |engine| {
        errdefer std.debug.print("engine {s}\n", .{engine});
        // While read waits for a line, the background process still runs.
        var t = try spawnTerm(e, engine, &.{ "--timeout", "60s", "--rc", "{sleep 1; echo ti^ck} & echo rea^dy; x=`{read}; echo got $x" });
        defer t.deinit();
        try t.expect("ready", slow(10_000));
        try t.expect("tick", slow(10_000));
        try t.send("line" ++ enter);
        try t.expect("got line", slow(10_000));
        try std.testing.expectEqual(0, try t.wait(slow(10_000)));
    }
}

test "a note interrupts a parked console read [browser-host]" {
    const e = try env(@src());
    var it = engineList(e);
    while (it.next()) |engine| {
        errdefer std.debug.print("engine {s}\n", .{engine});
        // Nothing is typed, so read stays parked until the note.
        var t = try spawnTerm(e, engine, &.{ "--timeout", "60s", "--rc", "read </dev/cons & r=$apid; sleep 1; echo interrupt >/proc/$r/note; wait; echo af^ter" });
        defer t.deinit();
        try t.expect("after", slow(10_000));
        try std.testing.expectEqual(0, try t.wait(slow(10_000)));
    }
}

test "errno survives a park [browser-host]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    // Each rm fails in the host's rmdir with ENOTEMPTY, which devfs reads
    // from errno, while other processes fail other host calls with ENOENT
    // and park in between.
    var cmd: std.ArrayList(u8) = .empty;
    defer cmd.deinit(gpa);
    for (0..8) |i| {
        var buf: [16]u8 = undefined;
        const d = try std.fmt.bufPrint(&buf, "d{d}", .{i});
        try s.tmp.dir.createDirPath(std.testing.io, d);
        const f = try std.fmt.bufPrint(&buf, "d{d}/f", .{i});
        try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = f, .data = "" });
    }
    try cmd.appendSlice(gpa, "for(i in 0 1 2 3 4 5 6 7){ rm d$i >[2=1] & ls nosuch$i >[2]/dev/null & }; wait");
    const r = try run(e, &.{ "--sandbox", s.path, "--timeout", "60s", "--rc", cmd.items });
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqual(8, std.mem.count(u8, r.out, "not empty"));
    try std.testing.expectEqual(8, std.mem.count(u8, r.out, "\n"));
}

test "exec into recycled pages doesn't run stale JIT code [browser-host]" {
    const e = try env(@src());
    // Each program's pages are freed when it exits and handed to the
    // next, so echo's compiled text would run in basename's place.
    const r = try run(e, &.{ "--timeout", "120s", "--rc", "for(i in `{seq 1 40}){ /bin/echo a; /bin/basename /x/b }" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings(rep("a\nb\n", 40), r.out);
    try std.testing.expectEqual(0, r.code);
}

test "RFMEM processes see each other's writes [browser-host]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try buildC(e, &s, "rfmem", @embedFile("fixtures/rfmem/rfmem.c"));
    // Two CPUs at least: with one, the first to spin keeps it.
    for ([_][]const u8{ "2", "4" }) |cpus| {
        const r = try run(e, &.{ "--sandbox", s.path, "--timeout", "60s", "--cpus", cpus, "--rc", "./rfmem" });
        defer r.deinit();
        errdefer std.debug.print("--cpus {s}: {s}\n", .{ cpus, r.err });
        try std.testing.expectEqualStrings("100 100\n", r.out);
        try std.testing.expectEqual(0, r.code);
    }
}

test "a coroutine stack overflow panics instead of corrupting [browser-host]" {
    const e = try env(@src());
    // Coroutines are the web host's; native kernel processes are threads
    // with guard pages.
    if (getenv(3, "H9_TEST_WEB") == null) return error.SkipZigTest;
    var it = engineList(e);
    while (it.next()) |engine| {
        // Every coroutine gets an 8 KiB stack, which running a command overflows.
        const r = try runEnv(e, engine, &.{ "--rc", "ls /bin >/dev/null" }, &.{.{ "H9_TEST_KSTACK", "8192" }}, slow(30_000));
        defer r.deinit();
        errdefer std.debug.print("stderr: {s}\n", .{r.err});
        try expectIn(r.err, "kernel stack overflow in ");
        try std.testing.expect(r.code != 0);
    }
}

// The built-in root (design/epoch-0/builtin-root.md): `#Hroot`, multicall's tree
// of 9front's commands built into h9. Cases that run its commands skip
// when the build embedded none for the architecture under test (a
// development build without `zig build slim`'s tree).

/// The architecture under test, by its 9front name.
fn testArch(e: Env) []const u8 {
    return e.arch orelse "arm64";
}

/// Skips a case that needs the built-in root's commands for the
/// architecture under test, when `h9 --version` says it has none.
fn needBuiltin(e: Env) !void {
    const v = try runProcess(&.{ e.h9, "--version" }, null);
    defer gpa.free(v.stdout);
    defer gpa.free(v.stderr);
    const at = std.mem.indexOf(u8, v.stdout, "built-in root: ") orelse return error.SkipZigTest;
    const line = v.stdout[at..(std.mem.indexOfScalarPos(u8, v.stdout, at, '\n') orelse v.stdout.len)];
    var it = std.mem.tokenizeAny(u8, line, " ,()");
    while (it.next()) |w| if (std.mem.eql(u8, w, testArch(e))) return;
    return error.SkipZigTest;
}

/// The environment without H9ROOT.
fn noRootEnv() !std.process.Environ.Map {
    var environ = try std.testing.environ.createMap(gpa);
    _ = environ.swapRemove("H9ROOT");
    return environ;
}

/// Runs `h9 args...` on the first engine, with no root and no H9ROOT,
/// in `cwd` if given.
fn runNoRoot(e: Env, h9: []const u8, args: []const []const u8) !Result {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ h9, "--engine", firstEngine(e) });
    if (e.arch) |a| try argv.appendSlice(gpa, &.{ "--arch", a });
    try argv.appendSlice(gpa, args);
    var environ = try noRootEnv();
    defer environ.deinit();
    const r = try runProcessWith(argv.items, null, &environ, 30_000);
    const code = switch (r.term) {
        .exited => |c| c,
        else => {
            gpa.free(r.stdout);
            gpa.free(r.stderr);
            return error.Crashed;
        },
    };
    return .{ .code = code, .out = r.stdout, .err = r.stderr };
}

/// A copy of h9 in `s`, which has no .local/9front/root two levels up to
/// default to.
fn h9Copy(e: Env, s: *Scratch) ![]const u8 {
    const name = std.fs.path.basename(e.h9);
    try std.Io.Dir.copyFile(std.Io.Dir.cwd(), e.h9, s.tmp.dir, name, std.testing.io, .{});
    return std.fs.path.join(gpa, &.{ s.path, name });
}

test "with no root found, --rc runs from the built-in root [builtin-root]" {
    const e = try env(@src());
    try needBuiltin(e);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const h9 = try h9Copy(e, &s);
    defer gpa.free(h9);
    const r = try runNoRoot(e, h9, &.{ "--cwd", s.path, "--rc", "ls /bin/ls >/dev/null && echo $cputype; pwd" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    var want: [64]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&want, "{s}\n/mnt/term/cwd\n", .{testArch(e)}), r.out);
}

test "--builtin alone ignores H9ROOT [mounts]" {
    const e = try env(@src());
    try needBuiltin(e);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ e.h9, "--engine", firstEngine(e), "--builtin" });
    if (e.arch) |a| try argv.appendSlice(gpa, &.{ "--arch", a });
    // The full tree has /sys/src; the built-in root doesn't.
    try argv.appendSlice(gpa, &.{ "--rc", "test -d /sys || echo builtin" });
    var environ = try std.testing.environ.createMap(gpa);
    defer environ.deinit();
    try environ.put("H9ROOT", e.root);
    const r = try runProcessWith(argv.items, null, &environ, 30_000);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    errdefer std.debug.print("stderr: {s}\n", .{r.stderr});
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
    try std.testing.expectEqualStrings("builtin\n", r.stdout);
}

test "lc runs from the built-in root [builtin-root]" {
    const e = try env(@src());
    try needBuiltin(e);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const h9 = try h9Copy(e, &s);
    defer gpa.free(h9);
    const r = try runNoRoot(e, h9, &.{ "--rc", "lc /rc; lc /rc/bin" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("bin/ lib/\nlc*\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "--root and --root-spec fail with exit 2 naming the replacement [mounts]" {
    const e = try env(@src());
    for ([_][]const []const u8{
        &.{ e.h9, "--builtin=only", "--rc", "echo x" },
        &.{ e.h9, "--root", e.root, "--rc", "echo x" },
        &.{ e.h9, "--root-spec", "x", "--rc", "echo x" },
    }) |argv| {
        const r = try runProcess(argv, null);
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 2 }, r.term);
        try expectIn(r.stderr, " was removed: use ");
    }
}

test "--builtin on top of the root stack runs the box's ls and the root's other commands [mounts]" {
    const e = try env(@src());
    try needBuiltin(e);
    const r = try run(e, &.{ "--dir", e.root, "--builtin=/:b", "--rc", "cmp -s /bin/ls /bin/9box && echo boxed; test -x /bin/mk && echo mk" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("boxed\nmk\n", r.out);
}

test "--builtin at the bottom leaves the root's ls and fills a missing command [mounts]" {
    const e = try env(@src());
    try needBuiltin(e);
    const io = std.testing.io;
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    // A slim root of its own: rc, ls and rcmain from the full tree, and
    // nothing else.
    var bin: [64]u8 = undefined;
    const arch_bin = try std.fmt.bufPrint(&bin, "root/{s}/bin", .{testArch(e)});
    for ([_][]const u8{ arch_bin, "root/rc/lib", "root/dev", "root/env", "root/fd", "root/proc", "root/srv", "root/tmp", "root/bin", "root/net", "root/mnt/term/cwd" }) |d| try s.tmp.dir.createDirPath(io, d);
    var from: [64]u8 = undefined;
    var to: [96]u8 = undefined;
    for ([_][]const u8{ "rc", "ls" }) |cmd| {
        const src = try hostPath(e.root, try std.fmt.bufPrint(&from, "{s}/bin/{s}", .{ testArch(e), cmd }));
        try std.Io.Dir.copyFile(std.Io.Dir.cwd(), src, s.tmp.dir, try std.fmt.bufPrint(&to, "{s}/{s}", .{ arch_bin, cmd }), io, .{});
    }
    const rcmain = try hostPath(e.root, "rc/lib/rcmain");
    try std.Io.Dir.copyFile(std.Io.Dir.cwd(), rcmain, s.tmp.dir, "root/rc/lib/rcmain", io, .{});
    const root = try std.fs.path.join(gpa, &.{ s.path, "root" });
    defer gpa.free(root);
    const r = try runNoRoot(e, e.h9, &.{ "--dir", root, "--builtin", "--rc", "cmp -s /bin/ls /bin/9box || echo own; echo filled | wc -l" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("own\n      1\n", r.out);
}

/// Writes `files`, each a path under the scratch directory and its
/// contents, making their directories; a path ending in `*` is made
/// executable, without the `*`.
fn writeTree(s: *Scratch, files: []const [2][]const u8) !void {
    const io = std.testing.io;
    for (files) |f| {
        const exec = std.mem.endsWith(u8, f[0], "*");
        const p = if (exec) f[0][0 .. f[0].len - 1] else f[0];
        if (std.fs.path.dirname(p)) |d| try s.tmp.dir.createDirPath(io, d);
        try s.tmp.dir.writeFile(io, .{ .sub_path = p, .data = f[1], .flags = .{ .permissions = if (exec) .executable_file else .default_file } });
    }
}

/// `<scratch>/rel`, in `buf`.
fn under(s: *const Scratch, buf: []u8, rel: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ s.path, rel });
}

test "--dir on / binds a host tree behind #/ [mounts]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--dir", e.root, "--rc", "test -e /dev/cons && echo cons; ls /root/rc/bin | sed 3q | wc -l" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("cons\n      3\n", r.out);
}

test "/root is the root stack without the namespace's binds [mounts]" {
    const e = try env(@src());
    // The tree's /dev is an empty directory; the machine's is devcons's.
    const r = try run(e, &.{ "--rc", "test -e /dev/cons && echo cons; test -e /root/dev/cons || echo tree; test -d /root/rc/bin && echo bin" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("cons\ntree\nbin\n", r.out);
}

test "a bare tree without mount points runs rc [mounts]" {
    const e = try env(@src());
    const io = std.testing.io;
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    // rc, echo, and rcmain, and no dev, env, fd, mnt, proc, srv, or tmp.
    var bin: [64]u8 = undefined;
    const arch_bin = try std.fmt.bufPrint(&bin, "bare/{s}/bin", .{testArch(e)});
    try s.tmp.dir.createDirPath(io, arch_bin);
    try s.tmp.dir.createDirPath(io, "bare/rc/lib");
    var from: [64]u8 = undefined;
    var to: [96]u8 = undefined;
    for ([_][]const u8{ "rc", "echo" }) |cmd|
        try std.Io.Dir.copyFile(std.Io.Dir.cwd(), try hostPath(e.root, try std.fmt.bufPrint(&from, "{s}/bin/{s}", .{ testArch(e), cmd })), s.tmp.dir, try std.fmt.bufPrint(&to, "{s}/{s}", .{ arch_bin, cmd }), io, .{});
    try std.Io.Dir.copyFile(std.Io.Dir.cwd(), try hostPath(e.root, "rc/lib/rcmain"), s.tmp.dir, "bare/rc/lib/rcmain", io, .{});
    var p: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const r = try run(e, &.{ "--dir", try under(&s, &p, "bare"), "--rc", "echo hi; cd /dev && echo dev; cd /mnt/term/cwd && echo cwd; echo t >/tmp/t && echo tmp" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("hi\ndev\ncwd\ntmp\n", r.out);
}

test "sources on / stack, later on top, and merge at every depth [mounts]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try writeTree(&s, &.{
        .{ "a/lib/x", "A\n" }, .{ "a/lib/deep/a", "A\n" },
        .{ "b/lib/x", "B\n" }, .{ "b/lib/deep/b", "B\n" },
    });
    var pa: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var pb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const r = try run(e, &.{ "--dir", e.root, "--dir", try under(&s, &pa, "a"), "--dir", try under(&s, &pb, "b"), "--rc", "cat /lib/x /lib/deep/a /lib/deep/b; test -e /lib/namespace && echo root" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("B\nA\nB\nroot\n", r.out);
}

test "b and a place a member on top of or at the bottom of a stack [mounts]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try writeTree(&s, &.{ .{ "a/lib/x", "A\n" }, .{ "b/lib/x", "B\n" } });
    var pa: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var pb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var ab: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    const a = try under(&s, &pa, "a");
    const b = try under(&s, &pb, "b");
    // b after a, but at the bottom: a wins.
    const after = try run(e, &.{ "--dir", e.root, "--dir", a, "--dir", try std.fmt.bufPrint(&ab, "{s}:/:a", .{b}), "--rc", "cat /lib/x" });
    defer after.deinit();
    try std.testing.expectEqualStrings("A\n", after.out);
    // The root at the bottom, so a member before it in argv still sits on it.
    var rb: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    const before = try run(e, &.{ "--dir", a, "--dir", try std.fmt.bufPrint(&rb, "{s}:/:a", .{e.root}), "--dir", try std.fmt.bufPrint(&ab, "{s}:/:b", .{b}), "--rc", "cat /lib/x; test -e /lib/namespace && echo root" });
    defer before.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{before.err});
    try std.testing.expectEqualStrings("B\nroot\n", before.out);
}

test "--dir on another path replaces it, and r merges [mounts]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try writeTree(&s, &.{.{ "lib/x", "A\n" }});
    var p: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const lib = try under(&s, &buf, "lib");
    const r = try run(e, &.{ "--dir", try std.fmt.bufPrint(&p, "{s}:/lib", .{lib}), "--rc", "test -e /lib/namespace || echo replaced; cat /lib/x" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("replaced\nA\n", r.out);
    const m = try run(e, &.{ "--dir", try std.fmt.bufPrint(&p, "{s}:/lib:r", .{lib}), "--rc", "test -e /lib/namespace && echo merged; cat /lib/x" });
    defer m.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{m.err});
    try std.testing.expectEqualStrings("merged\nA\n", m.out);
}

test "a missing DST is made in the root's overlay [mounts]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try writeTree(&s, &.{.{ "d/x", "A\n" }});
    var p: [std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const r = try run(e, &.{ "--dir", try std.fmt.bufPrint(&p, "{s}:/app/data", .{try under(&s, &buf, "d")}), "--rc", "cat /app/data/x" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("A\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "a missing DST under a read-only root is exit 125 [mounts]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try writeTree(&s, &.{.{ "d/x", "A\n" }});
    var p: [std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const r = try run(e, &.{ "--write=scope", "--dir", try std.fmt.bufPrint(&p, "{s}:/app/data", .{try under(&s, &buf, "d")}), "--rc", "cat /app/data/x" });
    defer r.deinit();
    try std.testing.expectEqual(125, r.code);
    try expectIn(r.err, "/app/data does not exist (the root is read-only)");
}

/// A tar of `files`, each a path and its contents, written to `name` in
/// the scratch directory.
fn writeTar(s: *Scratch, name: []const u8, files: []const [2][]const u8) !void {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var t: std.tar.Writer = .{ .underlying_writer = &out.writer };
    for (files) |f| try t.writeFileBytes(f[0], f[1], .{ .mode = 0o644 });
    try t.finishPedantically();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = out.written() });
}

test "--archive unpacks into memory, counted against --memory [mounts]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try writeTar(&s, "fix.tar", &.{ .{ "lib/app.conf", "conf\n" }, .{ "lib/sub/d", "deep\n" } });
    var ab: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const arc = try under(&s, &ab, "fix.tar");
    // On /, over the root, and writable in memory.
    const r = try run(e, &.{ "--dir", e.root, "--archive", arc, "--rc", "cat /lib/app.conf /lib/sub/d; test -e /lib/namespace && echo root; echo w >/lib/sub/w && cat /lib/sub/w" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("conf\ndeep\nroot\nw\n", r.out);
    // Elsewhere, its own tree.
    var nb: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    const n = try run(e, &.{ "--archive", try std.fmt.bufPrint(&nb, "{s}:/n/a", .{arc}), "--rc", "cat /n/a/lib/app.conf" });
    defer n.deinit();
    try std.testing.expectEqualStrings("conf\n", n.out);
    // A file bigger than --memory doesn't fit.
    const big = try gpa.alloc(u8, 4 << 20);
    defer gpa.free(big);
    @memset(big, 'x');
    try writeTar(&s, "big.tar", &.{.{ "big", big }});
    const b = try run(e, &.{ "--memory", "2m", "--archive", try std.fmt.bufPrint(&nb, "{s}/big.tar:/n/a", .{s.path}), "--rc", "echo ran" });
    defer b.deinit();
    try std.testing.expectEqual(125, b.code);
    try expectIn(b.err, "--archive ");
    try expectIn(b.err, "file system full");
}

test "--tmp makes an empty writable tree [mounts]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--tmp", "/scratch", "--rc", "ls /scratch | wc -l; echo y >/scratch/f && cat /scratch/f" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("      0\ny\n", r.out);
}

// design/epoch-0/upper-layers.md: an up member takes a stack's changes as an OCI
// layer on the host, and every member reads whiteouts.

/// A scratch tree with `a`, a stack member, and an empty `up`, for a layer.
fn layerTree(s: *Scratch) !void {
    try writeTree(s, &.{
        .{ "a/lib/x", "A\n" },    .{ "a/lib/deep/x", "A\n" },
        .{ "a/lib/d/y", "A\n" }, .{ "a/lib/keep", "A\n" },
    });
    try s.tmp.dir.createDirPath(std.testing.io, "up");
}

/// Runs `script` in rc over the root, `a`, and `up` as the root stack's layer.
fn runLayer(e: Env, s: *Scratch, script: []const u8) !Result {
    var pa: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var pu: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    var ub: [std.Io.Dir.max_path_bytes]u8 = undefined;
    return run(e, &.{ "--dir", e.root, "--dir", try under(s, &pa, "a"), "--dir", try std.fmt.bufPrint(&pu, "{s}:/:up", .{try under(s, &ub, "up")}), "--rc", script });
}

fn expectFile(s: *Scratch, name: []const u8, want: []const u8) !void {
    const got = try s.tmp.dir.readFileAlloc(std.testing.io, name, gpa, .limited(4096));
    defer gpa.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "a new file lands in the up layer and nowhere else [upper-layers]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try layerTree(&s);
    const r = try runLayer(e, &s, "echo n >/lib/new && cat /lib/new");
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("n\n", r.out);
    try expectFile(&s, "up/lib/new", "n\n");
    try std.testing.expect(!s.exists("a/lib/new"));
}

test "writing a file from below copies it up with its parents [upper-layers]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try layerTree(&s);
    const r = try runLayer(e, &s, "echo more >>/lib/deep/x && cat /lib/deep/x");
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("A\nmore\n", r.out);
    try expectFile(&s, "up/lib/deep/x", "A\nmore\n");
    try expectFile(&s, "a/lib/deep/x", "A\n");
    // Only what changed: the parents, not their other files.
    try std.testing.expect(!s.exists("up/lib/keep"));
}

test "removing a name from below leaves a .wh. file [upper-layers]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try layerTree(&s);
    const r = try runLayer(e, &s, "rm /lib/x; test -e /lib/x || echo gone; ls /lib | grep -c wh");
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("gone\n0\n", r.out);
    try std.testing.expect(s.exists("up/lib/.wh.x"));
    try std.testing.expect(s.exists("a/lib/x"));
}

test "a directory removed and made again is opaque [upper-layers]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try layerTree(&s);
    const r = try runLayer(e, &s, "rm /lib/d/y /lib/d; mkdir /lib/d; ls /lib/d | wc -l");
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("      0\n", r.out);
    try std.testing.expect(s.exists("up/lib/d/.wh..wh..opq"));
    try std.testing.expect(!s.exists("up/lib/.wh.d"));
    // Mounted again, the layer still hides what was below.
    var pa: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var pu: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const again = try run(e, &.{ "--dir", e.root, "--dir", try under(&s, &pa, "a"), "--dir", try under(&s, &pu, "up"), "--rc", "ls /lib/d | wc -l" });
    defer again.deinit();
    try std.testing.expectEqualStrings("      0\n", again.out);
}

test "renaming a directory from below is EXDEV [upper-layers]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try layerTree(&s);
    // rc's mv renames with a wstat, which a directory from below refuses.
    const r = try runLayer(e, &s, "mv /lib/d /lib/d2; test -e /lib/d/y && echo kept");
    defer r.deinit();
    try std.testing.expectEqualStrings("kept\n", r.out);
    try expectIn(r.err, "cross-device link");
}

test "a .wh. name can't be made in an up layer [upper-layers]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try layerTree(&s);
    const r = try runLayer(e, &s, "touch /lib/.wh.keep || echo refused; cat /lib/keep");
    defer r.deinit();
    try std.testing.expectEqualStrings("refused\nA\n", r.out);
    try expectIn(r.err, "permission denied");
    try std.testing.expect(!s.exists("up/lib/.wh.keep"));
}

test "an up member goes on top of its stack whatever its order [upper-layers]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try layerTree(&s);
    var pa: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var pu: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    var ub: [std.Io.Dir.max_path_bytes]u8 = undefined;
    // The layer first in argv, a after it: a is still beneath the layer.
    const r = try run(e, &.{ "--dir", e.root, "--dir", try std.fmt.bufPrint(&pu, "{s}:/:up", .{try under(&s, &ub, "up")}), "--dir", try under(&s, &pa, "a"), "--rc", "cat /lib/x; echo U >/lib/x; cat /lib/x" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("A\nU\n", r.out);
    try expectFile(&s, "up/lib/x", "U\n");
    try expectFile(&s, "a/lib/x", "A\n");
}

test "up off a stack layers over what's at DST [upper-layers]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try writeTree(&s, &.{ .{ "n/f", "n\n" }, .{ "n/sub/g", "g\n" } });
    try s.tmp.dir.createDirPath(std.testing.io, "l");
    var pn: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    var pl: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    var b1: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var b2: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const r = try run(e, &.{
        "--dir",  try std.fmt.bufPrint(&pn, "{s}:/n/x", .{try under(&s, &b1, "n")}),
        "--dir",  try std.fmt.bufPrint(&pl, "{s}:/n/x:up", .{try under(&s, &b2, "l")}),
        "--rc",   "echo w >>/n/x/f; cat /n/x/f /n/x/sub/g; rm /n/x/sub/g; ls /n/x/sub | wc -l",
    });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("n\nw\ng\n      0\n", r.out);
    try expectFile(&s, "l/f", "n\nw\n");
    try std.testing.expect(s.exists("l/sub/.wh.g"));
    try expectFile(&s, "n/f", "n\n");
}

test "up conflicts, two up members, and up on a read-only source are usage errors [upper-layers]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try layerTree(&s);
    try writeTar(&s, "t.tar", &.{.{ "f", "f\n" }});
    var b1: [std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    var b2: [std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    var b3: [std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    var b4: [std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    var b5: [std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    const cases = [_][]const []const u8{
        &.{ "--dir", try std.fmt.bufPrint(&b1, "{s}/up:/:up,ro", .{s.path}) },
        &.{ "--dir", try std.fmt.bufPrint(&b2, "{s}/up:/:up", .{s.path}), "--dir", try std.fmt.bufPrint(&b3, "{s}/a:/:up", .{s.path}) },
        &.{ "--archive", try std.fmt.bufPrint(&b4, "{s}/t.tar:/:up", .{s.path}) },
        &.{ "--builtin=/:up" },
        &.{ "--write=none", "--dir", try std.fmt.bufPrint(&b5, "{s}/up:/n/x:up", .{s.path}) },
    };
    for (cases) |c| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, c);
        try argv.appendSlice(gpa, &.{ "--rc", "echo ran" });
        const r = try run(e, argv.items);
        defer r.deinit();
        errdefer std.debug.print("{s}: {s}\n", .{ c[c.len - 1], r.err });
        try std.testing.expectEqual(2, r.code);
        try std.testing.expectEqualStrings("", r.out);
    }
}

test "a stack member's .wh. file hides the name in the members below [upper-layers]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try writeTree(&s, &.{ .{ "a/lib/x", "A\n" }, .{ "a/lib/y", "A\n" }, .{ "b/lib/.wh.x", "" }, .{ "b/lib/x2", "B\n" } });
    var pa: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var pb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const r = try run(e, &.{ "--dir", e.root, "--dir", try under(&s, &pa, "a"), "--dir", try under(&s, &pb, "b"), "--rc", "test -e /lib/x || echo hidden; cat /lib/y /lib/x2; ls /lib | grep -c 'wh|/lib/x$'" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("hidden\nA\nB\n0\n", r.out);
}

test "a stack member's opaque directory hides the directory below [upper-layers]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try writeTree(&s, &.{ .{ "a/lib/d/y", "A\n" }, .{ "b/lib/d/.wh..wh..opq", "" }, .{ "b/lib/d/z", "B\n" } });
    var pa: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var pb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const r = try run(e, &.{ "--dir", e.root, "--dir", try under(&s, &pa, "a"), "--dir", try under(&s, &pb, "b"), "--rc", "ls /lib/d; test -e /lib/d/y || echo hidden" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("/lib/d/z\nhidden\n", r.out);
}

test "--archive on a stack reads whiteouts, and off a stack keeps them as files [upper-layers]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try writeTree(&s, &.{.{ "a/lib/x", "A\n" }});
    try writeTar(&s, "l.tar", &.{ .{ "lib/.wh.x", "" }, .{ "lib/n", "N\n" } });
    var pa: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var ab: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    const on = try run(e, &.{ "--dir", e.root, "--dir", try under(&s, &pa, "a"), "--archive", try under(&s, &ab, "l.tar"), "--rc", "test -e /lib/x || echo hidden; cat /lib/n" });
    defer on.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{on.err});
    try std.testing.expectEqualStrings("hidden\nN\n", on.out);
    const off = try run(e, &.{ "--archive", try std.fmt.bufPrint(&ab, "{s}/l.tar:/n/a", .{s.path}), "--rc", "ls /n/a/lib" });
    defer off.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{off.err});
    try std.testing.expectEqualStrings("/n/a/lib/.wh.x\n/n/a/lib/n\n", off.out);
}

test "--print writes bind -u, and it replays with --ns [upper-layers]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try layerTree(&s);
    var pu: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    var ub: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const p = try run(e, &.{ "--dir", e.root, "--dir", try std.fmt.bufPrint(&pu, "{s}:/:up", .{try under(&s, &ub, "up")}), "--tmp", "/n/t:up", "--print", "--rc", "echo" });
    defer p.deinit();
    try expectIn(p.out, "  bind -u '#U");
    try expectIn(p.out, "' '#Oroot'");
    try expectIn(p.out, "  bind -u '#O' /n/t");
    // The tmp layer replays: host trees need their flags, as any #U line does.
    const start = (std.mem.indexOf(u8, p.out, "  bind -u '#O' /n/t") orelse return error.NoLine);
    const end = std.mem.indexOfScalarPos(u8, p.out, start, '\n') orelse p.out.len;
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ns", .data = p.out[start..end] });
    var nb: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    const r = try run(e, &.{ "--ns", try std.fmt.bufPrint(&nb, "@{s}/ns", .{s.path}), "--rc", "echo t >/n/t/f && cat /n/t/f" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("t\n", r.out);
}

test "ns prints an up instance as bind -u [upper-layers]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try layerTree(&s);
    var pn: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    var pl: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    const r = try run(e, &.{
        "--dir", try std.fmt.bufPrint(&pn, "{s}/a:/n/x", .{s.path}),
        "--dir", try std.fmt.bufPrint(&pl, "{s}/up:/n/x:up", .{s.path}),
        "--rc",  "ns | grep 'bind -u'",
    });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    // The host path as ns writes it, which on Windows has / for each \
    // and a leading / (#U/C:/...).
    var hp: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    const host = if (builtin.os.tag == .windows) blk: {
        hp[0] = '/';
        @memcpy(hp[1..][0..s.path.len], s.path);
        std.mem.replaceScalar(u8, hp[1..][0..s.path.len], '\\', '/');
        break :blk hp[0 .. s.path.len + 1];
    } else s.path;
    var want: [std.Io.Dir.max_path_bytes + 32]u8 = undefined;
    try expectIn(r.out, try std.fmt.bufPrint(&want, "bind -u '#U{s}/up' /n/x", .{host}));
}

test "links and FIFOs are made in the layer [upper-layers]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.createDirPath(std.testing.io, "up");
    var p: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    const r = try runLinux(&le, false, &.{ "--dir", try std.fmt.bufPrint(&p, "{s}/up:#L:up", .{s.path}), "/bin/sh", "-c", "ln -s /etc/alpine-release /root/lnk && mkfifo /root/ff && cat /root/lnk >/dev/null && test -p /root/ff && echo ok" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("ok\n", r.out);
    var lb: [64]u8 = undefined;
    const n = try s.tmp.dir.readLink(std.testing.io, "up/root/lnk", &lb);
    try std.testing.expectEqualStrings("/etc/alpine-release", lb[0..n]);
    const st = try s.tmp.dir.statFile(std.testing.io, "up/root/ff", .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.named_pipe, st.kind);
}

test "a rename across directories copies up and renames in the layer [upper-layers]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.createDirPath(std.testing.io, "up");
    var p: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    // A staging rename, as package managers make, and one of a file from below.
    const r = try runLinux(&le, false, &.{ "--dir", try std.fmt.bufPrint(&p, "{s}/up:#L:up", .{s.path}), "/bin/sh", "-c", "mkdir -p /app/tmp && echo hi >/app/tmp/x && mv /app/tmp/x /app/x && mv /etc/alpine-release /root/rel && cat /app/x && test ! -e /etc/alpine-release && cat /root/rel >/dev/null && echo moved" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("hi\nmoved\n", r.out);
    try expectFile(&s, "up/app/x", "hi\n");
    try std.testing.expect(!s.exists("up/app/tmp/x"));
    try std.testing.expect(s.exists("up/root/rel"));
    try std.testing.expect(s.exists("up/etc/.wh.alpine-release"));
}

test "a working directory from below sees what's changed in the layer since [upper-layers]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.createDirPath(std.testing.io, "up");
    var p: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    // /etc is only below when the shell cds there, as /app is when a build
    // step's commands run in it: names relative to it are the layer's once
    // the layer has the directory.
    const r = try runLinux(&le, false, &.{ "--dir", try std.fmt.bufPrint(&p, "{s}/up:#L:up", .{s.path}), "/bin/sh", "-c", "cd /etc && echo new >motd && cat motd && rm alpine-release && ls | grep -c alpine-release; set -C && echo again >alpine-release && cat alpine-release" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("new\n0\nagain\n", r.out);
    try expectFile(&s, "up/etc/motd", "new\n");
    try expectFile(&s, "up/etc/alpine-release", "again\n");
    try std.testing.expect(!s.exists("up/etc/.wh.alpine-release"));
}

test "a working directory from below sees a directory made again over it as opaque [upper-layers]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.createDirPath(std.testing.io, "up");
    var p: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    // /etc/apk is only below when the shell cds there. Made again in the
    // layer, it's opaque, so names from the old working directory are only
    // what's new there, in a read or a walk.
    const r = try runLinux(&le, false, &.{ "--dir", try std.fmt.bufPrint(&p, "{s}/up:#L:up", .{s.path}), "/bin/sh", "-c", "cd /etc/apk && rm -rf /etc/apk && mkdir /etc/apk && echo x >/etc/apk/new && ls && cat new && test ! -e arch && echo gone" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("new\nx\ngone\n", r.out);
    try std.testing.expect(s.exists("up/etc/apk/.wh..wh..opq"));
    try expectFile(&s, "up/etc/apk/new", "x\n");
}

test "a directory fd from below still names the directory once the layer has it [upper-layers]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.createDirPath(std.testing.io, "up");
    var p: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    // apk update opens /var/cache/apk, then creates and renames its
    // indexes through that fd: the first create makes the directory in
    // the layer, and the fd has to go on naming it.
    try netCase(&le, &.{ "--dir", try std.fmt.bufPrint(&p, "{s}/up:#L:up", .{s.path}), "/mnt/term/cwd/files", "dirfd_copyup" }, "ok dirfd_copyup\n");
    try std.testing.expect(s.exists("up/etc/apk"));
    try std.testing.expect(!s.exists("up/etc/apk/x"));
}

test "names looked up again after a change in the layer see the change [upper-layers]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.createDirPath(std.testing.io, "up");
    var p: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    // A stack with a layer keeps what its walks found (the walk cache in
    // devoverlay.c): each name is looked up before and after it changes,
    // within the second an entry is kept, from the root and from a
    // working directory, with a directory's names removed and renamed.
    const r = try runLinux(&le, false, &.{ "--dir", try std.fmt.bufPrint(&p, "{s}/up:#L:up", .{s.path}), "/bin/sh", "-c",
        "cd /usr/share && test ! -e new/a/b && mkdir -p new/a/b && test -d new/a/b && echo made && " ++
        "rm -rf new && test ! -e new/a && test ! -e /usr/share/new/a/b && echo gone && " ++
        "mkdir -p new/a && test ! -e new/a/b && echo again && " ++
        "test -e /etc/alpine-release && rm /etc/alpine-release && test ! -e /etc/alpine-release && echo whited && " ++
        "echo x >/etc/alpine-release && test -s /etc/alpine-release && echo back && " ++
        "mkdir /app && echo f >/app/f1 && mkdir /app/d && echo g >/app/d/f && mv /app/d /app/e && " ++
        "test ! -e /app/d/f && cat /app/e/f && mv /app/f1 /app/f2 && test ! -e /app/f1 && cat /app/f2" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("made\ngone\nagain\nwhited\nback\ng\nf\n", r.out);
    try std.testing.expect(s.exists("up/usr/share/new/a"));
    try std.testing.expect(!s.exists("up/usr/share/new/a/b"));
    try expectFile(&s, "up/app/e/f", "g\n");
}

test "Alpine builds in layers that stack again as directories and archives (demo) [upper-layers]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.createDirPath(std.testing.io, "deps");
    try s.tmp.dir.createDirPath(std.testing.io, "app");
    var b1: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    var b2: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    // Step 1 changes the base; apk needs the network, so a file stands in for python3.
    const one = try runLinux(&le, false, &.{ "--dir", try std.fmt.bufPrint(&b1, "{s}/deps:#L:up", .{s.path}), "/bin/sh", "-c", "echo 3 >/usr/bin/python3-v && rm /etc/motd" });
    defer one.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{one.err});
    try std.testing.expectEqual(0, one.code);
    const two = try runLinux(&le, false, &.{ "--dir", try std.fmt.bufPrint(&b1, "{s}/deps:#L", .{s.path}), "--dir", try std.fmt.bufPrint(&b2, "{s}/app:#L:up", .{s.path}), "/bin/sh", "-c", "mkdir -p /app/tmp && echo hi > /app/tmp/x && mv /app/tmp/x /app/x" });
    defer two.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{two.err});
    try std.testing.expectEqual(0, two.code);
    const three = try runLinux(&le, false, &.{ "--dir", try std.fmt.bufPrint(&b1, "{s}/deps:#L", .{s.path}), "--dir", try std.fmt.bufPrint(&b2, "{s}/app:#L", .{s.path}), "/bin/sh", "-c", "cat /usr/bin/python3-v /app/x; test ! -e /etc/motd && echo nomotd" });
    defer three.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{three.err});
    try std.testing.expectEqualStrings("3\nhi\nnomotd\n", three.out);
    try std.testing.expect(s.exists("deps/etc/.wh.motd"));
    // The layers as archives, by the host's tar.
    var cmd: [2 * std.Io.Dir.max_path_bytes + 64]u8 = undefined;
    const tr = try runProcessWith(&.{ "sh", "-c", try std.fmt.bufPrint(&cmd, "cd '{s}' && tar -C deps -cf deps.tar . && tar -C app -cf app.tar .", .{s.path}) }, null, null, 30_000);
    gpa.free(tr.stdout);
    gpa.free(tr.stderr);
    const four = try runLinux(&le, false, &.{ "--archive", try std.fmt.bufPrint(&b1, "{s}/deps.tar:#L", .{s.path}), "--archive", try std.fmt.bufPrint(&b2, "{s}/app.tar:#L", .{s.path}), "/bin/sh", "-c", "cat /app/x; test ! -e /etc/motd && echo nomotd" });
    defer four.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{four.err});
    try std.testing.expectEqualStrings("hi\nnomotd\n", four.out);
}

test "up on a 9P2000.L mount keeps the layer on the server [upper-layers]" {
    const e = try env(@src());
    // The web host has no TCP; "a port up layer takes the guest's
    // writes" is this case there.
    if (onWeb()) return error.SkipZigTest;
    var d: Diod = undefined;
    try d.start("true");
    defer d.stop();
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try writeTree(&s, &.{ .{ "n/f", "n\n" }, .{ "n/sub/g", "g\n" } });
    var pn: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    var pu: [std.Io.Dir.max_path_bytes + 64]u8 = undefined;
    const r = try run(e, &.{
        "--dir", try std.fmt.bufPrint(&pn, "{s}/n:/n/x", .{s.path}),
        "--url", try std.fmt.bufPrint(&pu, "{s}:/n/x:up,spec={s}", .{ d.url(), d.s.path }),
        "--rc",  "echo w >>/n/x/f; rm /n/x/sub/g; cat /n/x/f; ls /n/x/sub | wc -l",
    });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("n\nw\n      0\n", r.out);
    try std.testing.expect(d.s.exists("f"));
    try std.testing.expect(d.s.exists("sub/.wh.g"));
    try expectFile(&s, "n/f", "n\n");
}

test "links are made in a 9P2000.L layer, and on a .L mount, by Tsymlink [upper-layers]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    var d: Diod = undefined;
    try d.start("true");
    defer d.stop();
    var pu: [std.Io.Dir.max_path_bytes + 64]u8 = undefined;
    // A new link, and one from below copied up by a rename.
    const r = try runLinux(&le, false, &.{
        "--url",   try std.fmt.bufPrint(&pu, "{s}:#L:up,spec={s}", .{ d.url(), d.s.path }),
        "/bin/sh", "-c",
        "mkdir -p /root && ln -s /etc/alpine-release /root/lnk && readlink /root/lnk && cmp /root/lnk /etc/alpine-release && mv /bin/ls /root/ls && readlink /root/ls && test ! -e /bin/ls && echo ok",
    });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("/etc/alpine-release\n/bin/busybox\nok\n", r.out);
    var lb: [64]u8 = undefined;
    const n = try d.s.tmp.dir.readLink(std.testing.io, "root/lnk", &lb);
    try std.testing.expectEqualStrings("/etc/alpine-release", lb[0..n]);
    try std.testing.expect(d.s.exists("bin/.wh.ls"));
    // A 9P2000.L mount that isn't a layer takes links the same way.
    const m = try runLinux(&le, false, &.{
        "--url",   try std.fmt.bufPrint(&pu, "{s}:/n/l:rw,spec={s}", .{ d.url(), d.s.path }),
        "/bin/sh", "-c",
        "ln -s lnk /9/n/l/two && readlink /9/n/l/two",
    });
    defer m.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{m.err});
    try std.testing.expectEqualStrings("lnk\n", m.out);
    const k = try d.s.tmp.dir.readLink(std.testing.io, "two", &lb);
    try std.testing.expectEqualStrings("lnk", lb[0..k]);
}

test "--bind runs after every mount, in order [mounts]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try writeTree(&s, &.{
        .{ "app/bin/tool*", "#!/bin/rc\necho mine\n" },
        .{ "app/b1/t*", "#!/bin/rc\necho b1\n" },
        .{ "app/b2/t*", "#!/bin/rc\necho b2\n" },
    });
    var p: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const app = try std.fmt.bufPrint(&p, "{s}:/app", .{try under(&s, &buf, "app")});
    // The bind comes first on the command line, and still sees /app.
    const r = try run(e, &.{ "--bind", "/app/bin:/bin:b", "--dir", app, "--rc", "tool" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("mine\n", r.out);
    // Two binds before /bin: the later one is on top.
    const o = try run(e, &.{ "--dir", app, "--bind", "/app/b1:/bin:b", "--bind", "/app/b2:/bin:b", "--rc", "t" });
    defer o.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{o.err});
    try std.testing.expectEqualStrings("b2\n", o.out);
}

test "--write=none rejects rw, eph, and 9P mounts [mounts]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try writeTree(&s, &.{.{ "d/x", "A\n" }});
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const d = try under(&s, &buf, "d");
    var p1: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    var p2: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    for ([_][2][]const u8{
        .{ "--dir", try std.fmt.bufPrint(&p1, "{s}:/x:rw", .{d}) },
        .{ "--dir", try std.fmt.bufPrint(&p2, "{s}:/x:eph", .{d}) },
        .{ "--url", "tcp://127.0.0.1:1:/x" },
    }) |m| {
        const r = try run(e, &.{ "--write=none", m[0], m[1], "--rc", "echo" });
        defer r.deinit();
        try std.testing.expectEqual(2, r.code);
        try expectIn(r.err, "--write=none ");
    }
}

test "--dir rw writes through to the host, and ro denies [mounts]" {
    const e = try env(@src());
    const io = std.testing.io;
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try writeTree(&s, &.{.{ "d/x", "A\n" }});
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const d = try under(&s, &buf, "d");
    var p: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    const w = try run(e, &.{ "--dir", try std.fmt.bufPrint(&p, "{s}:/x:rw", .{d}), "--rc", "echo w >/x/new" });
    defer w.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{w.err});
    try std.testing.expectEqual(0, w.code);
    const got = try s.tmp.dir.readFileAlloc(io, "d/new", gpa, .limited(64));
    defer gpa.free(got);
    try std.testing.expectEqualStrings("w\n", got);
    const ro = try run(e, &.{ "--dir", try std.fmt.bufPrint(&p, "{s}:/x:ro", .{d}), "--rc", "touch /x/new2 >[2]/dev/null || echo denied" });
    defer ro.deinit();
    try std.testing.expectEqualStrings("denied\n", ro.out);
    try std.testing.expectError(error.FileNotFound, s.tmp.dir.access(io, "d/new2", .{}));
}

test "--builtin is a member of the / stack [mounts]" {
    const e = try env(@src());
    try needBuiltin(e);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    // A tree with one file, and no programs: rc and ls come from the
    // built-in root under it.
    try writeTree(&s, &.{.{ "a/lib/x", "A\n" }});
    var p: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const r = try runNoRoot(e, e.h9, &.{ "--dir", try under(&s, &p, "a"), "--builtin", "--rc", "cat /lib/x; cmp -s /bin/ls /bin/9box && echo boxed" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("A\nboxed\n", r.out);
}

test "a development build without $H9ROOT runs from the built-in root [mounts]" {
    const e = try env(@src());
    try needBuiltin(e);
    // The test h9 is in the checkout's zig-out, where .local/9front/root
    // used to be the default.
    const r = try runNoRoot(e, e.h9, &.{ "--rc", "test -d /sys || echo builtin" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("builtin\n", r.out);
}

test "a host a.out without a root sees /dev, /env, /proc, /tmp and its cwd [builtin-root]" {
    const e = try env(@src());
    const io = std.testing.io;
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var from: [64]u8 = undefined;
    const ls = try hostPath(e.root, try std.fmt.bufPrint(&from, "{s}/bin/ls", .{testArch(e)}));
    try std.Io.Dir.copyFile(std.Io.Dir.cwd(), ls, s.tmp.dir, "ls", io, .{});
    const h9 = try h9Copy(e, &s);
    defer gpa.free(h9);
    // A host program's path is relative to the host's cwd, and the
    // scratch directory is under it.
    var prog: [128]u8 = undefined;
    const r = try runNoRoot(e, h9, &.{ "--cwd", s.path, try std.fmt.bufPrint(&prog, "./.zig-cache/tmp/{s}/ls", .{&s.tmp.sub_path}), "-d", "/dev/cons", "/env", "/proc", "/tmp", "/mnt/term/cwd/ls" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    for ([_][]const u8{ "/dev/cons\n", "/env\n", "/mnt/term/cwd/ls\n", "/proc\n", "/tmp\n" }) |want|
        try std.testing.expect(std.mem.indexOf(u8, r.out, want) != null);
}

test "the built-in root refuses writes and /tmp is writable in memory [builtin-root]" {
    const e = try env(@src());
    try needBuiltin(e);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const r = try runNoRoot(e, e.h9, &.{ "--builtin", "--cwd", s.path, "--write=scope", "--rc", "touch /usr/f >[2]/dev/null || echo refused; echo y >/tmp/f && cat /tmp/f" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("refused\ny\n", r.out);
}

test "--print shows the #Hroot member as builtin [mounts]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const r = try runNoRoot(e, e.h9, &.{ "--builtin", "--cwd", s.path, "--print", "--rc", "echo" });
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    const at = std.mem.indexOf(u8, r.out, "  bind -ra '#Hroot' '#Oroot' ") orelse return error.NoBind;
    const line = r.out[at..std.mem.indexOfScalarPos(u8, r.out, at, '\n').?];
    try std.testing.expect(std.mem.indexOf(u8, line, " builtin  # h9 ") != null);
    const b = try run(e, &.{ "--dir", e.root, "--builtin=/:b", "--print", "--rc", "echo" });
    defer b.deinit();
    try std.testing.expect(std.mem.indexOf(u8, b.out, "  bind -rb '#Hroot' '#Oroot' ") != null);
}

test "--ns replays a plan printed over the built-in root [builtin-root]" {
    const e = try env(@src());
    try needBuiltin(e);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const p = try runNoRoot(e, e.h9, &.{ "--builtin", "--cwd", s.path, "--print", "--rc", "echo" });
    defer p.deinit();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ns", .data = try printedNamespace(p.out) });
    // Replayed over the full tree, the plan adds the built-in root to the
    // stack, under the tree: the tree's ls, and the box's 9box.
    const r = try run(e, &.{ "--cwd", s.path, "--ns", s.ns(), "--rc", "test -d /sys && echo tree; cmp -s /bin/ls /bin/9box || echo own; test -x /bin/9box && echo builtin" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("tree\nown\nbuiltin\n", r.out);
}

test "--check passes with only the built-in root [builtin-root]" {
    const e = try env(@src());
    // --check runs the host's architecture.
    if (e.arch != null) return error.SkipZigTest;
    try needBuiltin(e);
    const r = try runNoRoot(e, e.h9, &.{ "--builtin", "--check" });
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\n", .{r.out});
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "root: built-in (") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "ok, /bin/echo runs") != null);
}

test "a Linux root alone gets the built-in root as its /9, and a --dir on / replaces it [mounts]" {
    const e = try env(@src());
    try needBuiltin(e);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    // The smallest tree h9 takes for a Linux root.
    try s.tmp.dir.createDirPath(std.testing.io, "lin/etc");
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lin/etc/os-release", .data = "ID=test\n" });
    const lin = try std.fs.path.join(gpa, &.{ s.path, "lin" });
    defer gpa.free(lin);
    var lb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const lm = try std.fmt.bufPrint(&lb, "{s}:#L", .{lin});
    const r = try runNoRoot(e, e.h9, &.{ "--dir", lm, "--cwd", s.path, "--rc", "test -x '#L/9/bin/ls' && echo boxed" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("boxed\n", r.out);
    const off = try runNoRoot(e, e.h9, &.{ "--dir", lm, "--dir", e.root, "--cwd", s.path, "--print", "--rc", "echo" });
    defer off.deinit();
    try std.testing.expect(std.mem.indexOf(u8, off.out, "#Hroot") == null);
}

test "a missing command names the built-in root in its error [builtin-root]" {
    const e = try env(@src());
    try needBuiltin(e);
    const r = try runNoRoot(e, e.h9, &.{ "--builtin", "mk" });
    defer r.deinit();
    try std.testing.expectEqual(127, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "not in the built-in root; pass --dir or --url, or set H9ROOT") != null);
}

// Serving the namespace (design/epoch-0/serve.md). A server is h9 on a
// terminal from tests/term.zig, so the cases can signal it and read its
// "serve: ADDR" lines; a client is a second h9 with the listener as its
// 9P root, which mounts the connection's /srv/root at /mnt/temp to look
// at the served tree beside its own. The HTTP and 9P-level cases speak to
// the listener over a socket of their own.

/// The case's environment, skipped on Windows: the cases signal the server.
fn serveEnv(comptime src: std.builtin.SourceLocation) !Env {
    const e = try env(src);
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    return e;
}

/// A scratch directory with `marker` in it, the server's --cwd.
fn serveScratch(s: *Scratch) !void {
    try s.init();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "marker", .data = "served\n" });
}

/// `name` in `s`, in `buf`.
fn scratchPath(s: *Scratch, buf: []u8, name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ s.path, name });
}

/// Starts `h9 args...` on a terminal on the first engine.
fn startServer(e: Env, args: []const []const u8) !Term {
    return spawnTerm(e, firstEngine(e), args);
}

/// `startServer`, with `extra` (NAME=value strings) in h9's environment.
fn startServerEnv(e: Env, args: []const []const u8, extra: []const []const u8) !Term {
    return spawnTermEnv(e, firstEngine(e), args, extra);
}

/// Waits for the server's next "serve: ADDR" line and returns ADDR,
/// copied into `buf`.
fn servedAddr(t: *Term, buf: []u8) ![]const u8 {
    try t.expect("serve: ", slow(10_000));
    const start = t.mark;
    try t.expect("\n", slow(10_000));
    const line = std.mem.trimEnd(u8, t.out.items[start .. t.mark - 1], "\r");
    @memcpy(buf[0..line.len], line);
    return buf[0..line.len];
}

/// The port at the end of `tcp!127.0.0.1!PORT` or in `ws://127.0.0.1:PORT/path`.
fn addrPort(addr: []const u8) !u16 {
    if (std.mem.startsWith(u8, addr, "tcp!")) {
        const bang = std.mem.lastIndexOfScalar(u8, addr, '!').?;
        return std.fmt.parseInt(u16, addr[bang + 1 ..], 10);
    }
    const rest = addr["ws://".len..];
    const colon = std.mem.indexOfScalar(u8, rest, ':').?;
    const slash = std.mem.indexOfScalarPos(u8, rest, colon, '/') orelse rest.len;
    return std.fmt.parseInt(u16, rest[colon + 1 .. slash], 10);
}

/// Waits up to 10 s for `path` to exist, as a serve-only run's socket.
fn waitPath(path: []const u8) !void {
    var i: usize = 0;
    while (i < slow(200)) : (i += 1) {
        std.Io.Dir.cwd().access(std.testing.io, path, .{}) catch {
            try std.Io.sleep(std.testing.io, .fromMilliseconds(50), .awake);
            continue;
        };
        return;
    }
    return error.Timeout;
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(std.testing.io, path, .{}) catch return false;
    return true;
}

/// Runs a client, `h9 --dir ROOT args...`, on the first engine, without
/// the proxy variables, so a ws:// root on 127.0.0.1 is dialed directly.
fn runClient(e: Env, root: []const u8, args: []const []const u8) !Result {
    var map = try std.testing.environ.createMap(gpa);
    defer map.deinit();
    for ([_][]const u8{ "HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "ALL_PROXY", "all_proxy" }) |k| _ = map.swapRemove(k);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ e.h9, "--engine", firstEngine(e) });
    try argv.appendSlice(gpa, &rootFlag(root));
    if (e.arch) |a| try argv.appendSlice(gpa, &.{ "--arch", a });
    try argv.appendSlice(gpa, args);
    const r = try runProcessWith(argv.items, null, &map, 60_000);
    const code = switch (r.term) {
        .exited => |c| c,
        else => {
            gpa.free(r.stdout);
            gpa.free(r.stderr);
            return error.Crashed;
        },
    };
    return .{ .code = code, .out = r.stdout, .err = r.stderr };
}

/// A client on `addr` running `cmd` with the served tree at /mnt/temp.
fn runServed(e: Env, addr: []const u8, cmd: []const u8) !Result {
    var buf: [1024]u8 = undefined;
    var ub: [std.Io.Dir.max_path_bytes + 32]u8 = undefined;
    var db: [std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    const srv = try std.fmt.bufPrint(&ub, "{s}:/srv/served", .{dialUrl(&db, addr)});
    return runClient(e, e.root, &.{ "--url", srv, "--rc", try std.fmt.bufPrint(&buf, "mount /srv/served /mnt/temp && {{ {s} }}", .{cmd}) });
}

/// Checks that a client on `addr` reads the server's marker at `path`.
fn expectServed(e: Env, addr: []const u8, path: []const u8) !void {
    var buf: [256]u8 = undefined;
    const r = try runServed(e, addr, try std.fmt.bufPrint(&buf, "cat {s}", .{path}));
    defer r.deinit();
    errdefer std.debug.print("client stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("served\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

/// A TCP connection of the case's own to 127.0.0.1:`port`. On Windows,
/// where a socket isn't a C file descriptor, reads and writes go through
/// Io.
const Sock = struct {
    s: std.Io.net.Stream,

    fn dial(port: u16) !Sock {
        const a = try std.Io.net.IpAddress.parse("127.0.0.1", port);
        const s = a.connect(std.testing.io, .{ .mode = .stream }) catch |err| {
            // Zig 0.16 reports a refused connect on Windows as unexpected.
            if (builtin.os.tag == .windows and err == error.Unexpected) return error.ConnectionRefused;
            return err;
        };
        return .{ .s = s };
    }

    fn close(k: Sock) void {
        k.s.close(std.testing.io);
    }

    fn write(k: Sock, bytes: []const u8) !void {
        if (builtin.os.tag == .windows) {
            var w = k.s.writer(std.testing.io, &.{});
            w.interface.writeAll(bytes) catch return error.WriteFailed;
            return;
        }
        var off: usize = 0;
        while (off < bytes.len) {
            const n = std.c.write(k.s.socket.handle, bytes[off..].ptr, bytes.len - off);
            if (n <= 0) return error.WriteFailed;
            off += @intCast(n);
        }
    }

    /// Reads what's there within `ms`; 0 at EOF or a reset.
    fn read(k: Sock, buf: []u8, ms: u32) !usize {
        try deadline.waitReadable(k.s.socket.handle, @intCast(slow(ms)));
        if (builtin.os.tag == .windows) {
            var r = k.s.reader(std.testing.io, &.{});
            var bufs = [_][]u8{buf};
            return r.interface.readVec(&bufs) catch 0;
        }
        const n = std.c.read(k.s.socket.handle, buf.ptr, buf.len);
        return if (n <= 0) 0 else @intCast(n);
    }

    /// Reads exactly `buf.len` bytes, or fails with error.Closed.
    fn readFull(k: Sock, buf: []u8, ms: u32) !void {
        var off: usize = 0;
        while (off < buf.len) {
            const n = try k.read(buf[off..], ms);
            if (n == 0) return error.Closed;
            off += n;
        }
    }

    /// Sends a Tversion and checks for the Rversion: the connection has
    /// a server behind it.
    fn version(k: Sock) !void {
        try k.write("\x13\x00\x00\x00\x64\xff\xff\x00\x20\x00\x00\x06\x009P2000");
        var hdr: [7]u8 = undefined;
        try k.readFull(&hdr, 10_000);
        if (hdr[4] != 101) return error.NotRversion;
        const size = std.mem.readInt(u32, hdr[0..4], .little);
        var rest: [64]u8 = undefined;
        if (size < 7 or size - 7 > rest.len) return error.NotRversion;
        try k.readFull(rest[0 .. size - 7], 10_000);
    }

    /// Waits up to `ms` for the server to close the connection.
    fn expectClosed(k: Sock, ms: u32) !void {
        var buf: [256]u8 = undefined;
        while (true) if (try k.read(&buf, ms) == 0) return;
    }

    /// Sends a WebSocket upgrade for `target` with `extra` header lines and
    /// returns the status code of the answer.
    fn upgrade(k: Sock, target: []const u8, extra: []const u8) !u16 {
        var req: [1024]u8 = undefined;
        try k.write(try std.fmt.bufPrint(&req, "GET {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: 9p\r\n{s}\r\n", .{ target, extra }));
        // Reads to the end of the head, a byte at a time, so a frame after
        // it stays unread.
        var head: [2048]u8 = undefined;
        var n: usize = 0;
        while (n < head.len) {
            try k.readFull(head[n .. n + 1], 10_000);
            n += 1;
            if (std.mem.endsWith(u8, head[0..n], "\r\n\r\n")) break;
        }
        if (!std.mem.startsWith(u8, head[0..n], "HTTP/1.1 ")) return error.NotHttp;
        return std.fmt.parseInt(u16, head[9..12], 10);
    }
};

test "an h9 root over --serve unix! lists the served tree [serve]" {
    const e = try serveEnv(@src());
    var s: Scratch = undefined;
    try serveScratch(&s);
    defer s.deinit();
    var pb: [512]u8 = undefined;
    var ab: [600]u8 = undefined;
    const addr = try std.fmt.bufPrint(&ab, "unix!{s}", .{try scratchPath(&s, &pb, "fs.sock")});
    var t = try startServer(e, &.{ "--cwd", s.path, "--serve", addr, "--rc", "echo ready; sleep 60" });
    defer t.deinit();
    try t.expect("ready", slow(10_000));
    try expectServed(e, addr, "/mnt/temp/mnt/term/cwd/marker");
}

test "an h9 root over --serve tcp! lists the served tree [serve]" {
    const e = try serveEnv(@src());
    var s: Scratch = undefined;
    try serveScratch(&s);
    defer s.deinit();
    var t = try startServer(e, &.{ "--cwd", s.path, "--serve", "tcp!127.0.0.1!0", "--rc", "echo ready; sleep 60" });
    defer t.deinit();
    var ab: [128]u8 = undefined;
    const addr = try servedAddr(&t, &ab);
    try t.expect("ready", slow(10_000));
    try expectServed(e, addr, "/mnt/temp/mnt/term/cwd/marker");
}

test "an h9 ws:// root over --serve ws:// lists the served tree [serve]" {
    const e = try serveEnv(@src());
    var s: Scratch = undefined;
    try serveScratch(&s);
    defer s.deinit();
    var t = try startServer(e, &.{ "--cwd", s.path, "--serve", "ws://127.0.0.1:0/9p", "--rc", "echo ready; sleep 60" });
    defer t.deinit();
    var ab: [128]u8 = undefined;
    const addr = try servedAddr(&t, &ab);
    try std.testing.expect(std.mem.startsWith(u8, addr, "ws://127.0.0.1:"));
    try t.expect("ready", slow(10_000));
    try expectServed(e, addr, "/mnt/temp/mnt/term/cwd/marker");
}

test "a guest mounts a --serve ws:// listener through /net/ws [serve]" {
    const e = try serveEnv(@src());
    var s: Scratch = undefined;
    try serveScratch(&s);
    defer s.deinit();
    var t = try startServer(e, &.{ "--cwd", s.path, "--serve", "ws://127.0.0.1:0/9p", "--rc", "echo ready; sleep 60" });
    defer t.deinit();
    var ab: [128]u8 = undefined;
    const addr = try servedAddr(&t, &ab);
    try t.expect("ready", slow(10_000));
    var cmd: [256]u8 = undefined;
    const r = try runClient(e, e.root, &.{ "--rc", try std.fmt.bufPrint(&cmd, "mkdir /tmp/fs && wsmount {s} /tmp/fs && cat /tmp/fs/mnt/term/cwd/marker", .{addr}) });
    defer r.deinit();
    errdefer std.debug.print("client stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("served\n", r.out);
}

test "--serve-root exports only that subtree [serve]" {
    const e = try serveEnv(@src());
    var s: Scratch = undefined;
    try serveScratch(&s);
    defer s.deinit();
    var t = try startServer(e, &.{ "--cwd", s.path, "--serve", "ws://127.0.0.1:0/9p", "--serve-root", "/mnt/term/cwd", "--rc", "echo ready; sleep 60" });
    defer t.deinit();
    var ab: [128]u8 = undefined;
    const addr = try servedAddr(&t, &ab);
    try t.expect("ready", slow(10_000));
    // The subtree has no rc to boot a client from, so the client mounts
    // it beside its own root.
    var cmd: [256]u8 = undefined;
    const r = try runClient(e, e.root, &.{ "--rc", try std.fmt.bufPrint(&cmd, "mkdir /tmp/fs && wsmount {s} /tmp/fs && cat /tmp/fs/marker && {{ test -e /tmp/fs/rc && echo whole || echo subtree }}", .{addr}) });
    defer r.deinit();
    errdefer std.debug.print("client stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("served\nsubtree\n", r.out);
}

test "--serve under --write=none refuses writes [serve]" {
    const e = try serveEnv(@src());
    var t = try startServer(e, &.{ "--write=none", "--serve", "tcp!127.0.0.1!0", "--rc", "echo ready; sleep 60" });
    defer t.deinit();
    var ab: [128]u8 = undefined;
    const addr = try servedAddr(&t, &ab);
    try t.expect("ready", slow(10_000));
    const r = try runServed(e, addr, "touch /mnt/temp/tmp/f >[2]/dev/null && echo wrote || echo refused");
    defer r.deinit();
    errdefer std.debug.print("client stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("refused\n", r.out);
}

test "--read-deny paths aren't visible through --serve [serve]" {
    const e = try serveEnv(@src());
    var s: Scratch = undefined;
    try serveScratch(&s);
    defer s.deinit();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "secret", .data = "hidden\n" });
    var db: [512]u8 = undefined;
    var t = try startServer(e, &.{ "--cwd", s.path, "--read-deny", try scratchPath(&s, &db, "secret"), "--serve", "tcp!127.0.0.1!0", "--rc", "echo ready; sleep 60" });
    defer t.deinit();
    var ab: [128]u8 = undefined;
    const addr = try servedAddr(&t, &ab);
    try t.expect("ready", slow(10_000));
    const r = try runServed(e, addr, "cat /mnt/temp/mnt/term/cwd/marker; if(test -e /mnt/temp/mnt/term/cwd/secret) echo seen; if not echo hidden");
    defer r.deinit();
    try std.testing.expectEqualStrings("served\nhidden\n", r.out);
}

test "clients see the plan's namespace, not the program's later binds [serve]" {
    const e = try serveEnv(@src());
    var s: Scratch = undefined;
    try serveScratch(&s);
    defer s.deinit();
    var t = try startServer(e, &.{ "--cwd", s.path, "--serve", "tcp!127.0.0.1!0", "--rc", "bind /mnt/term/cwd /tmp && cat /tmp/marker && echo ready; sleep 60" });
    defer t.deinit();
    var ab: [128]u8 = undefined;
    const addr = try servedAddr(&t, &ab);
    try t.expect("ready", slow(10_000));
    const r = try runServed(e, addr, "if(test -e /mnt/temp/tmp/marker) echo bound; if not echo plan");
    defer r.deinit();
    try std.testing.expectEqualStrings("plan\n", r.out);
}

test "listeners close and clients see hangups when the program exits [serve]" {
    const e = try serveEnv(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var pb: [512]u8 = undefined;
    var ub: [600]u8 = undefined;
    const sock = try scratchPath(&s, &pb, "fs.sock");
    const unix = try std.fmt.bufPrint(&ub, "unix!{s}", .{sock});
    var t = try startServer(e, &.{ "--serve", "tcp!127.0.0.1!0", "--serve", unix, "--rc", "echo ready; read >/dev/null; exit gone" });
    defer t.deinit();
    var ab: [128]u8 = undefined;
    const addr = try servedAddr(&t, &ab);
    try t.expect("ready", slow(10_000));
    const k = try Sock.dial(try addrPort(addr));
    defer k.close();
    try k.version();
    try t.send("x" ++ enter);
    try k.expectClosed(10_000);
    try std.testing.expectEqual(1, try t.wait(slow(10_000)));
    try std.testing.expect(!pathExists(sock));
    try std.testing.expectError(error.ConnectionRefused, Sock.dial(try addrPort(addr)));
}

test "a ws:// listener refuses an unlisted Origin with 403 [serve]" {
    const e = try serveEnv(@src());
    var t = try startServer(e, &.{ "--serve", "ws://127.0.0.1:0/9p", "--serve-origin", "http://ok.example", "--rc", "echo ready; sleep 60" });
    defer t.deinit();
    var ab: [128]u8 = undefined;
    const port = try addrPort(try servedAddr(&t, &ab));
    try t.expect("ready", slow(10_000));
    {
        const k = try Sock.dial(port);
        defer k.close();
        try std.testing.expectEqual(403, try k.upgrade("/9p", "Origin: http://evil.example\r\n"));
    }
    {
        const k = try Sock.dial(port);
        defer k.close();
        try std.testing.expectEqual(101, try k.upgrade("/9p", "Origin: http://ok.example\r\n"));
    }
}

test "a ws:// listener with --serve-token refuses a request without it [serve]" {
    const e = try serveEnv(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "token", .data = "s3cret\n" });
    var tb: [512]u8 = undefined;
    var fb: [600]u8 = undefined;
    const tok = try std.fmt.bufPrint(&fb, "@{s}", .{try scratchPath(&s, &tb, "token")});
    var t = try startServer(e, &.{ "--serve", "ws://127.0.0.1:0/9p", "--serve-token", tok, "--rc", "echo ready; sleep 60" });
    defer t.deinit();
    var ab: [128]u8 = undefined;
    const port = try addrPort(try servedAddr(&t, &ab));
    try t.expect("ready", slow(10_000));
    {
        const k = try Sock.dial(port);
        defer k.close();
        try std.testing.expectEqual(401, try k.upgrade("/9p", ""));
    }
    {
        const k = try Sock.dial(port);
        defer k.close();
        try std.testing.expectEqual(401, try k.upgrade("/9p", "Authorization: Bearer wrong\r\n"));
    }
    {
        const k = try Sock.dial(port);
        defer k.close();
        try std.testing.expectEqual(101, try k.upgrade("/9p", "Authorization: Bearer s3cret\r\n"));
    }
}

test "a ws:// listener accepts the token in the query [serve]" {
    const e = try serveEnv(@src());
    var s: Scratch = undefined;
    try serveScratch(&s);
    defer s.deinit();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "token", .data = "ab+c/=\n" });
    var tb: [512]u8 = undefined;
    var fb: [600]u8 = undefined;
    const tok = try std.fmt.bufPrint(&fb, "@{s}", .{try scratchPath(&s, &tb, "token")});
    var t = try startServer(e, &.{ "--cwd", s.path, "--serve", "ws://127.0.0.1:0/9p", "--serve-token", tok, "--rc", "echo ready; sleep 60" });
    defer t.deinit();
    var ab: [128]u8 = undefined;
    const addr = try servedAddr(&t, &ab);
    try t.expect("ready", slow(10_000));
    {
        const k = try Sock.dial(try addrPort(addr));
        defer k.close();
        try std.testing.expectEqual(101, try k.upgrade("/9p?token=ab%2Bc%2F%3D", ""));
    }
    var ub: [256]u8 = undefined;
    try expectServed(e, try std.fmt.bufPrint(&ub, "{s}?token=ab%2bc/%3d", .{addr}), "/mnt/temp/mnt/term/cwd/marker");
}

test "the 33rd connection is refused [serve]" {
    const e = try serveEnv(@src());
    var t = try startServer(e, &.{ "--serve", "tcp!127.0.0.1!0" });
    defer t.deinit();
    var ab: [128]u8 = undefined;
    const port = try addrPort(try servedAddr(&t, &ab));
    var conns: [32]Sock = undefined;
    var open: usize = 0;
    defer for (conns[0..open]) |k| k.close();
    while (open < conns.len) : (open += 1) {
        conns[open] = try Sock.dial(port);
        errdefer conns[open].close();
        try conns[open].version();
    }
    {
        const k = try Sock.dial(port);
        defer k.close();
        try std.testing.expectError(error.Closed, k.version());
    }
    // Closing one frees its slot.
    open -= 1;
    conns[open].close();
    var i: usize = 0;
    while (true) : (i += 1) {
        const k = try Sock.dial(port);
        defer k.close();
        k.version() catch |err| {
            if (i >= 50) return err;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(100), .awake);
            continue;
        };
        break;
    }
}

test "--serve with no program serves until a hangup and exits 0 [serve]" {
    // It ends the server with SIGHUP, which Windows has no way to send.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const e = try serveEnv(@src());
    var s: Scratch = undefined;
    try serveScratch(&s);
    defer s.deinit();
    var pb: [512]u8 = undefined;
    var ab: [600]u8 = undefined;
    const sock = try scratchPath(&s, &pb, "fs.sock");
    const addr = try std.fmt.bufPrint(&ab, "unix!{s}", .{sock});
    var t = try startServer(e, &.{ "--cwd", s.path, "--serve", addr });
    defer t.deinit();
    try waitPath(sock);
    try expectServed(e, addr, "/mnt/temp/mnt/term/cwd/marker");
    t.signal(.HUP);
    try std.testing.expectEqual(0, try t.wait(slow(10_000)));
    try std.testing.expect(!pathExists(sock));
}

test "--serve tcp!127.0.0.1!0 prints the bound address [serve]" {
    const e = try serveEnv(@src());
    var t = try startServer(e, &.{ "--serve", "tcp!127.0.0.1!0" });
    defer t.deinit();
    var ab: [128]u8 = undefined;
    const addr = try servedAddr(&t, &ab);
    try std.testing.expect(std.mem.startsWith(u8, addr, "tcp!127.0.0.1!"));
    const port = try addrPort(addr);
    try std.testing.expect(port != 0);
    const k = try Sock.dial(port);
    defer k.close();
    try k.version();
}

/// Leaves a unix socket at `path` that nothing answers, as a crashed
/// server would.
fn staleSocket(path: []const u8) !void {
    const ua = try std.Io.net.UnixAddress.init(path);
    var srv = try ua.listen(std.testing.io, .{});
    srv.deinit(std.testing.io);
    try std.testing.expect(pathExists(path));
}

test "a stale unix socket is replaced and removed at exit [serve]" {
    const e = try serveEnv(@src());
    var s: Scratch = undefined;
    try serveScratch(&s);
    defer s.deinit();
    var pb: [512]u8 = undefined;
    var ab: [600]u8 = undefined;
    const sock = try scratchPath(&s, &pb, "fs.sock");
    try staleSocket(sock);
    const addr = try std.fmt.bufPrint(&ab, "unix!{s}", .{sock});
    var t = try startServer(e, &.{ "--cwd", s.path, "--serve", addr, "--rc", "echo ready; read >/dev/null" });
    defer t.deinit();
    try t.expect("ready", slow(10_000));
    try expectServed(e, addr, "/mnt/temp/mnt/term/cwd/marker");
    try t.send("x" ++ enter);
    try std.testing.expectEqual(0, try t.wait(slow(10_000)));
    try std.testing.expect(!pathExists(sock));
    try std.testing.expect(!s.exists("fs.sock.lock"));
}

test "a unix socket path that isn't a socket exits 125 [serve]" {
    const e = try serveEnv(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fs.sock", .data = "keep\n" });
    var pb: [512]u8 = undefined;
    var ab: [600]u8 = undefined;
    const addr = try std.fmt.bufPrint(&ab, "unix!{s}", .{try scratchPath(&s, &pb, "fs.sock")});
    const r = try runOn(e, firstEngine(e), &.{ "--serve", addr, "--rc", "echo ran" }, null);
    defer r.deinit();
    try std.testing.expectEqual(125, r.code);
    try std.testing.expectEqualStrings("", r.out);
    try expectIn(r.err, "not a socket");
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("keep\n", try s.tmp.dir.readFile(std.testing.io, "fs.sock", &buf));
}

test "a ws:// listener pings an idle client and closes one that stops answering [serve]" {
    const e = try serveEnv(@src());
    // H9_TEST_KEEPALIVE shortens the keepalive's 30 s idle time to 1 s:
    // the listener pings after 1 s idle and fails the connection 1 s
    // after that; this client never answers.
    var ka_buf: [32]u8 = undefined;
    const ka = try std.fmt.bufPrint(&ka_buf, "H9_TEST_KEEPALIVE={d}", .{slow(1000)});
    var t = try startServerEnv(e, &.{ "--serve", "ws://127.0.0.1:0/9p" }, &.{ka});
    defer t.deinit();
    var ab: [128]u8 = undefined;
    const port = try addrPort(try servedAddr(&t, &ab));
    const k = try Sock.dial(port);
    defer k.close();
    try std.testing.expectEqual(101, try k.upgrade("/9p", ""));
    var hdr: [2]u8 = undefined;
    try k.readFull(&hdr, slow(10_000));
    try std.testing.expectEqual(0x89, hdr[0]);
    try k.expectClosed(slow(10_000));
}

test "an address in use exits 125 [serve]" {
    const e = try serveEnv(@src());
    var srv = try listenLocal();
    defer srv.deinit(std.testing.io);
    var ab: [64]u8 = undefined;
    const addr = try std.fmt.bufPrint(&ab, "tcp!127.0.0.1!{d}", .{srv.socket.address.getPort()});
    const r = try runOn(e, firstEngine(e), &.{ "--serve", addr, "--rc", "echo ran" }, null);
    defer r.deinit();
    try std.testing.expectEqual(125, r.code);
    try std.testing.expectEqualStrings("", r.out);
    try expectIn(r.err, "address in use");
}

test "a client doesn't see /net without --serve-net [serve]" {
    const e = try serveEnv(@src());
    var t = try startServer(e, &.{ "--serve", "tcp!127.0.0.1!0", "--rc", "test -e /net/tcp/clone && echo ready; sleep 60" });
    defer t.deinit();
    var ab: [128]u8 = undefined;
    const addr = try servedAddr(&t, &ab);
    try t.expect("ready", slow(10_000));
    const r = try runServed(e, addr, "if(test -e /mnt/temp/net/tcp/clone) echo net; if not echo nonet");
    defer r.deinit();
    try std.testing.expectEqualStrings("nonet\n", r.out);
}

test "--serve-net exports /net and the plan shows a caveat [serve]" {
    const e = try serveEnv(@src());
    var t = try startServer(e, &.{ "--serve", "tcp!127.0.0.1!0", "--serve-net", "--rc", "echo ready; sleep 60" });
    defer t.deinit();
    var ab: [128]u8 = undefined;
    const addr = try servedAddr(&t, &ab);
    try t.expect("ready", slow(10_000));
    const r = try runServed(e, addr, "if(test -e /mnt/temp/net/tcp/clone) echo net; if not echo nonet");
    defer r.deinit();
    try std.testing.expectEqualStrings("net\n", r.out);
    const p = try run(e, &.{ "--print", "--serve", "tcp!127.0.0.1!5640", "--serve-net", "--rc", "echo" });
    defer p.deinit();
    try expectIn(p.out, "/net served on tcp!127.0.0.1!5640: clients can dial out from the host's address");
}

test "--serve-origin '*' without --serve-token exits 2 [serve]" {
    const e = try serveEnv(@src());
    const r = try run(e, &.{ "--serve", "ws://127.0.0.1:0/9p", "--serve-origin", "*", "--rc", "echo ran" });
    defer r.deinit();
    try std.testing.expectEqual(2, r.code);
    try std.testing.expectEqualStrings("", r.out);
}

/// A raw 9P2000 client on a `--serve` TCP connection, for the
/// [kernel-serve] cases that need to see the protocol itself.
const P9 = struct {
    k: Sock,
    out: [512]u8 = undefined,
    n: usize = 0,
    in: [8192 + 24]u8 = undefined,

    const Reply = struct { typ: u8, tag: u16, body: []const u8 };

    const Tversion = 100;
    const Tattach = 104;
    const Rerror = 107;
    const Tflush = 108;
    const Rflush = 109;
    const Twalk = 110;
    const Rwalk = 111;
    const Topen = 112;
    const Tcreate = 114;
    const Tread = 116;
    const Rread = 117;
    const Tclunk = 120;
    const Tremove = 122;
    const Tstat = 124;
    const Twstat = 126;
    const nofid = 0xffff_ffff;

    /// Dials `port`, negotiates 9P2000, and attaches fid 0.
    fn dial(port: u16) !P9 {
        var p: P9 = .{ .k = try Sock.dial(port) };
        errdefer p.k.close();
        p.begin(Tversion, 0xffff);
        p.int(u32, 8192 + 24);
        p.str("9P2000");
        _ = try p.expect(Tversion + 1);
        p.begin(Tattach, 1);
        p.int(u32, 0);
        p.int(u32, nofid);
        p.str("none");
        p.str("");
        _ = try p.expect(Tattach + 1);
        return p;
    }

    fn close(p: *P9) void {
        p.k.close();
    }

    fn begin(p: *P9, typ: u8, tag: u16) void {
        p.out[4] = typ;
        std.mem.writeInt(u16, p.out[5..7], tag, .little);
        p.n = 7;
    }

    fn int(p: *P9, comptime T: type, v: T) void {
        std.mem.writeInt(T, p.out[p.n..][0..@sizeOf(T)], v, .little);
        p.n += @sizeOf(T);
    }

    fn str(p: *P9, s: []const u8) void {
        p.int(u16, @intCast(s.len));
        @memcpy(p.out[p.n..][0..s.len], s);
        p.n += s.len;
    }

    fn send(p: *P9) !void {
        std.mem.writeInt(u32, p.out[0..4], @intCast(p.n), .little);
        try p.k.write(p.out[0..p.n]);
    }

    fn recv(p: *P9) !Reply {
        var h: [4]u8 = undefined;
        try p.k.readFull(&h, slow(10_000));
        const size = std.mem.readInt(u32, &h, .little);
        if (size < 7 or size - 4 > p.in.len) return error.BadReply;
        try p.k.readFull(p.in[0 .. size - 4], slow(10_000));
        return .{ .typ = p.in[0], .tag = std.mem.readInt(u16, p.in[1..3], .little), .body = p.in[3 .. size - 4] };
    }

    /// Sends what's built and reads the reply, which must be `want`.
    fn expect(p: *P9, want: u8) ![]const u8 {
        try p.send();
        const r = try p.recv();
        if (r.typ != want) {
            std.debug.print("9P: got {d} ({s}), want {d}\n", .{ r.typ, errText(r), want });
            return error.UnexpectedReply;
        }
        return r.body;
    }

    /// Sends what's built and returns the Rerror's text.
    fn expectError(p: *P9) ![]const u8 {
        try p.send();
        const r = try p.recv();
        if (r.typ != Rerror) return error.UnexpectedReply;
        return errText(r);
    }

    fn errText(r: Reply) []const u8 {
        if (r.typ != Rerror or r.body.len < 2) return "";
        const n = std.mem.readInt(u16, r.body[0..2], .little);
        return r.body[2..][0..@min(n, r.body.len - 2)];
    }

    /// Builds a Twalk of `names` from `fid` to `newfid`.
    fn walk(p: *P9, fid: u32, newfid: u32, names: []const []const u8) void {
        p.begin(Twalk, 2);
        p.int(u32, fid);
        p.int(u32, newfid);
        p.int(u16, @intCast(names.len));
        for (names) |s| p.str(s);
    }

    /// Walks all of `names` and returns the last qid's path.
    fn walkPath(p: *P9, fid: u32, newfid: u32, names: []const []const u8) !u64 {
        p.walk(fid, newfid, names);
        const b = try p.expect(Rwalk);
        const n = std.mem.readInt(u16, b[0..2], .little);
        if (n != names.len) return error.ShortWalk;
        if (n == 0) return 0;
        return std.mem.readInt(u64, b[2 + 13 * (n - 1) + 5 ..][0..8], .little);
    }

    /// Walks `names` and returns how many the server walked: fewer than
    /// all is a partial walk, which 9P answers with Rwalk, not Rerror.
    fn walkCount(p: *P9, fid: u32, newfid: u32, names: []const []const u8) !u16 {
        p.walk(fid, newfid, names);
        const b = try p.expect(Rwalk);
        return std.mem.readInt(u16, b[0..2], .little);
    }

    fn open(p: *P9, fid: u32, mode: u8) void {
        p.begin(Topen, 3);
        p.int(u32, fid);
        p.int(u8, mode);
    }

    fn read(p: *P9, tag: u16, fid: u32, off: u64, count: u32) void {
        p.begin(Tread, tag);
        p.int(u32, fid);
        p.int(u64, off);
        p.int(u32, count);
    }

    /// Reads a file's whole contents, up to the buffer.
    fn readAll(p: *P9, fid: u32, buf: []u8) ![]u8 {
        var off: usize = 0;
        while (off < buf.len) {
            p.read(4, fid, off, @intCast(@min(buf.len - off, 8192)));
            const b = try p.expect(Rread);
            const n = std.mem.readInt(u32, b[0..4], .little);
            if (n == 0) break;
            @memcpy(buf[off..][0..n], b[4..][0..n]);
            off += n;
        }
        return buf[0..off];
    }

    fn clunk(p: *P9, fid: u32) !void {
        p.begin(Tclunk, 5);
        p.int(u32, fid);
        _ = try p.expect(Tclunk + 1);
    }

    /// A Twstat that renames `fid` and changes nothing else.
    fn rename(p: *P9, fid: u32, name: []const u8) void {
        p.begin(Twstat, 6);
        p.int(u32, fid);
        const fixed = 2 + 4 + 13 + 4 + 4 + 4 + 8;
        const n = fixed + 2 + name.len + 2 * 3;
        p.int(u16, @intCast(n + 2));
        p.int(u16, @intCast(n));
        p.int(u16, 0xffff);
        p.int(u32, 0xffff_ffff);
        p.int(u8, 0xff);
        p.int(u32, 0xffff_ffff);
        p.int(u64, 0xffff_ffff_ffff_ffff);
        p.int(u32, 0xffff_ffff);
        p.int(u32, 0xffff_ffff);
        p.int(u32, 0xffff_ffff);
        p.int(u64, 0xffff_ffff_ffff_ffff);
        p.str(name);
        p.str("");
        p.str("");
        p.str("");
    }
};

/// Starts a server on a TCP port with `rc` as its program, which must
/// print "ready", and returns the port.
fn startRawServer(e: Env, t: *Term, extra: []const []const u8, rc: []const u8) !u16 {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(gpa);
    try args.appendSlice(gpa, extra);
    try args.appendSlice(gpa, &.{ "--serve", "tcp!127.0.0.1!0", "--rc", rc });
    // The program's end closes the listener, so it outlasts the case.
    t.* = try startServer(e, args.items);
    errdefer t.deinit();
    var ab: [128]u8 = undefined;
    const port = try addrPort(try servedAddr(t, &ab));
    try t.expect("ready", slow(10_000));
    return port;
}

test "serving runs no guest process [kernel-serve]" {
    const e = try serveEnv(@src());
    var t = try startServer(e, &.{ "--serve", "tcp!127.0.0.1!0", "--rc", "echo ready; sleep 60" });
    defer t.deinit();
    var ab: [128]u8 = undefined;
    const addr = try servedAddr(&t, &ab);
    try t.expect("ready", slow(10_000));
    // The client's own root comes through the server too, so its
    // processes are being served while it looks.
    const r = try runServed(e, addr, "cat /mnt/temp/proc/*/status | awk '{print $1}' | sort -u");
    defer r.deinit();
    errdefer std.debug.print("client stderr: {s}\n", .{r.err});
    try std.testing.expect(std.mem.indexOf(u8, r.out, "exportfs") == null);
    try expectIn(r.out, "serve\n");
    try expectIn(r.out, "sleep\n");
}

test "a blocking read doesn't hold up the connection [kernel-serve]" {
    const e = try serveEnv(@src());
    var s: Scratch = undefined;
    try serveScratch(&s);
    defer s.deinit();
    // /srv/blk is a pipe nobody writes, so each read through it blocks.
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "srv.rc", .data = "{ echo 3 >/srv/blk; echo ready; sleep 60 } <>[3] '#|/data'\n" });
    var t = try startServer(e, &.{ "--cwd", s.path, "--serve", "ws://127.0.0.1:0/9p", "--rc", ". /mnt/term/cwd/srv.rc" });
    defer t.deinit();
    var ab: [128]u8 = undefined;
    const addr = try servedAddr(&t, &ab);
    try t.expect("ready", slow(10_000));
    // Twelve blocked reads, more than exportfs's 8 processes, then a
    // read of the marker on the same connection: it waits for none of
    // them, and none of them fails.
    var cmd: [512]u8 = undefined;
    const r = try runClient(e, e.root, &.{ "--rc", try std.fmt.bufPrint(&cmd,
        \\mkdir /tmp/a && wsmount {s} /tmp/a || exit
        \\for(i in 1 2 3 4 5 6 7 8 9 10 11 12) {{ cat /tmp/a/srv/blk >[2]/tmp/err.$i & }}
        \\sleep 2
        \\cat /tmp/a/mnt/term/cwd/marker
        \\cat /tmp/err.* | wc -c
    , .{addr}) });
    defer r.deinit();
    errdefer std.debug.print("client out: {s}\nclient stderr: {s}\n", .{ r.out, r.err });
    var lines = std.mem.splitScalar(u8, r.out, '\n');
    try std.testing.expectEqualStrings("served", lines.next().?);
    try std.testing.expectEqualStrings("0", std.mem.trim(u8, lines.next().?, " "));
}

test "Tflush interrupts a blocked read and answers after its reply [kernel-serve]" {
    const e = try serveEnv(@src());
    var t: Term = undefined;
    const port = try startRawServer(e, &t, &.{}, "{ echo 3 >/srv/blk; echo ready; sleep 600 } <>[3] '#|/data'");
    defer t.deinit();
    var p = try P9.dial(port);
    defer p.close();
    _ = try p.walkPath(0, 1, &.{ "srv", "blk" });
    p.open(1, 0);
    _ = try p.expect(P9.Topen + 1);
    p.read(7, 1, 0, 100);
    try p.send();
    try std.Io.sleep(std.testing.io, .fromMilliseconds(300), .awake);
    p.begin(P9.Tflush, 8);
    p.int(u16, 7);
    try p.send();
    // The read's reply comes first, failed as a note fails a system
    // call, then the Rflush.
    const r1 = try p.recv();
    try std.testing.expectEqual(7, r1.tag);
    try std.testing.expectEqual(P9.Rerror, r1.typ);
    try expectIn(P9.errText(r1), "interrupted");
    const r2 = try p.recv();
    try std.testing.expectEqual(8, r2.tag);
    try std.testing.expectEqual(P9.Rflush, r2.typ);
    // The connection carries on.
    _ = try p.walkPath(0, 2, &.{"tmp"});
}

test "an open fid survives a rename by another client [kernel-serve]" {
    const e = try serveEnv(@src());
    var t: Term = undefined;
    const port = try startRawServer(e, &t, &.{}, "echo before >/tmp/f && echo ready; sleep 600");
    defer t.deinit();
    var a = try P9.dial(port);
    defer a.close();
    var b = try P9.dial(port);
    defer b.close();
    _ = try a.walkPath(0, 1, &.{ "tmp", "f" });
    a.open(1, 0);
    _ = try a.expect(P9.Topen + 1);
    _ = try b.walkPath(0, 1, &.{ "tmp", "f" });
    b.rename(1, "g");
    _ = try b.expect(P9.Twstat + 1);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("before\n", try a.readAll(1, &buf));
    // The old name is gone and the new one is the same file.
    try std.testing.expectEqual(1, try a.walkCount(0, 2, &.{ "tmp", "f" }));
    _ = try a.walkPath(0, 2, &.{ "tmp", "g" });
}

test "create in a union lands in the MCREATE member [kernel-serve]" {
    const e = try serveEnv(@src());
    var t = try startServer(e, &.{ "--serve", "tcp!127.0.0.1!0", "--rc", "echo ready; sleep 60" });
    defer t.deinit();
    var ab: [128]u8 = undefined;
    const addr = try servedAddr(&t, &ab);
    try t.expect("ready", slow(10_000));
    // / is #/ with the root's overlay bound after it with -c: the file
    // goes in the overlay, which is also /root.
    var ub: [std.Io.Dir.max_path_bytes + 32]u8 = undefined;
    var db: [std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    const srv = try std.fmt.bufPrint(&ub, "{s}:/srv/served", .{dialUrl(&db, addr)});
    const r = try runClient(e, e.root, &.{ "--url", srv, "--rc", "mount -c /srv/served /mnt/temp && echo made >/mnt/temp/kserve-new && cat /mnt/temp/root/kserve-new" });
    defer r.deinit();
    errdefer std.debug.print("client stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("made\n", r.out);
}

test "walking .. back across a mount matches namec [kernel-serve]" {
    const e = try serveEnv(@src());
    var s: Scratch = undefined;
    try serveScratch(&s);
    defer s.deinit();
    var t: Term = undefined;
    const port = try startRawServer(e, &t, &.{ "--cwd", s.path }, "echo ready; sleep 600");
    defer t.deinit();
    var p = try P9.dial(port);
    defer p.close();
    // /mnt/term/cwd is a host tree bound over /mnt/term's cwd: .. from
    // it is /mnt/term, as cd .. in the guest finds.
    const term = try p.walkPath(0, 1, &.{ "mnt", "term" });
    const back = try p.walkPath(0, 2, &.{ "mnt", "term", "cwd", ".." });
    try std.testing.expectEqual(term, back);
    const up = try p.walkPath(0, 3, &.{ "mnt", "term", "cwd", "..", "..", "term", "cwd", "marker" });
    _ = up;
}

test "a walk past the fid cap fails without hurting other fids [kernel-serve]" {
    const e = try serveEnv(@src());
    var t: Term = undefined;
    const port = try startRawServer(e, &t, &.{}, "echo ready; sleep 600");
    defer t.deinit();
    var p = try P9.dial(port);
    defer p.close();
    // Fid 0 is the attach's; 4095 more reach the cap of 4096.
    var fid: u32 = 1;
    while (fid < 4096) : (fid += 1) _ = try p.walkPath(0, fid, &.{});
    p.walk(0, fid, &.{});
    try std.testing.expectEqualStrings("too many fids", try p.expectError());
    // The others still work, and a clunk makes room.
    _ = try p.walkPath(17, 17, &.{"tmp"});
    try p.clunk(5);
    _ = try p.walkPath(0, fid, &.{"tmp"});
}

test "--write=none refuses writes in the server [kernel-serve]" {
    const e = try serveEnv(@src());
    var t: Term = undefined;
    const port = try startRawServer(e, &t, &.{"--write=none"}, "echo ready; sleep 600");
    defer t.deinit();
    var p = try P9.dial(port);
    defer p.close();
    // exportfs -R's error, before the device sees the request.
    _ = try p.walkPath(0, 1, &.{"tmp"});
    p.begin(P9.Tcreate, 3);
    p.int(u32, 1);
    p.str("f");
    p.int(u32, 0o644);
    p.int(u8, 1);
    try std.testing.expectEqualStrings("file system read only", try p.expectError());
    _ = try p.walkPath(0, 2, &.{ "lib", "namespace" });
    p.open(2, 1);
    try std.testing.expectEqualStrings("file system read only", try p.expectError());
    p.rename(2, "x");
    try std.testing.expectEqualStrings("file system read only", try p.expectError());
    p.begin(P9.Tremove, 3);
    p.int(u32, 2);
    try std.testing.expectEqualStrings("file system read only", try p.expectError());
    // Reading is fine.
    _ = try p.walkPath(0, 2, &.{ "lib", "namespace" });
    p.open(2, 0);
    _ = try p.expect(P9.Topen + 1);
}

test "--serve-root stops .. at the attach root [kernel-serve]" {
    const e = try serveEnv(@src());
    var s: Scratch = undefined;
    try serveScratch(&s);
    defer s.deinit();
    var t: Term = undefined;
    const port = try startRawServer(e, &t, &.{ "--cwd", s.path, "--serve-root", "/mnt/term/cwd" }, "echo ready; sleep 600");
    defer t.deinit();
    var p = try P9.dial(port);
    defer p.close();
    // .. from the root, alone or in the middle of a walk, stays there.
    const marker = try p.walkPath(0, 1, &.{"marker"});
    try std.testing.expectEqual(marker, try p.walkPath(0, 2, &.{ "..", "..", "marker" }));
    try std.testing.expectEqual(1, try p.walkCount(0, 3, &.{ "..", "lib" }));
    var buf: [64]u8 = undefined;
    p.open(2, 0);
    _ = try p.expect(P9.Topen + 1);
    try std.testing.expectEqualStrings("served\n", try p.readAll(2, &buf));
}

test "a union directory reads the same as through exportfs [kernel-serve]" {
    const e = try serveEnv(@src());
    var t = try startServer(e, &.{ "--serve", "tcp!127.0.0.1!0", "--rc", "echo sum `{cd /bin && ls | sort | md5sum}; echo ready; sleep 60" });
    defer t.deinit();
    var ab: [128]u8 = undefined;
    const addr = try servedAddr(&t, &ab);
    // The program's own listing of the union, through read(2).
    try t.expect("sum ", slow(10_000));
    const start = t.mark;
    try t.expect("\n", slow(10_000));
    var lb: [64]u8 = undefined;
    const line = std.mem.trim(u8, t.out.items[start..t.mark], " \r\n");
    @memcpy(lb[0..line.len], line);
    const local = lb[0..line.len];
    try t.expect("ready", slow(10_000));
    const r = try runServed(e, addr, "cd /mnt/temp/bin && ls | sort | md5sum");
    defer r.deinit();
    errdefer std.debug.print("client stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings(local, std.mem.trim(u8, r.out, " \r\n"));
}

test "a fuzzed 9P stream fails the connection, not the machine [kernel-serve]" {
    const e = try serveEnv(@src());
    var t: Term = undefined;
    const port = try startRawServer(e, &t, &.{}, "echo ready; read >/dev/null; echo still; exit");
    defer t.deinit();
    var prng: std.Random.DefaultPrng = .init(0x9f);
    const rand = prng.random();
    var i: usize = 0;
    while (i < 24) : (i += 1) {
        var p = try P9.dial(port);
        defer p.close();
        // A message the right size with a random type and body, or a
        // random size: either way the connection ends or answers
        // Rerror, and the machine carries on.
        var msg: [96]u8 = undefined;
        rand.bytes(&msg);
        const n: u32 = if (i % 3 == 0) rand.int(u32) else @intCast(7 + rand.uintLessThan(usize, msg.len - 7));
        std.mem.writeInt(u32, msg[0..4], n, .little);
        if (i % 2 == 0) msg[4] = @intCast(100 + rand.uintLessThan(u8, 28));
        p.k.write(msg[0..@min(n, msg.len)]) catch {};
        var buf: [256]u8 = undefined;
        _ = p.k.read(&buf, 500) catch {};
    }
    var p = try P9.dial(port);
    defer p.close();
    _ = try p.walkPath(0, 1, &.{"tmp"});
    try t.send("x" ++ enter);
    try t.expect("still", slow(10_000));
    try std.testing.expectEqual(0, try t.wait(slow(10_000)));
}

test "--pids no longer counts serving [kernel-serve]" {
    const e = try serveEnv(@src());
    var t = try startServer(e, &.{ "--pids", "8", "--serve", "tcp!127.0.0.1!0", "--rc", "echo ready; read >/dev/null; echo a | cat; echo forked" });
    defer t.deinit();
    var ab: [128]u8 = undefined;
    const port = try addrPort(try servedAddr(&t, &ab));
    try t.expect("ready", slow(10_000));
    // More connections than --pids, each answered, and the program
    // still forks.
    var conns: [12]Sock = undefined;
    var open: usize = 0;
    defer for (conns[0..open]) |k| k.close();
    while (open < conns.len) : (open += 1) {
        conns[open] = try Sock.dial(port);
        try conns[open].version();
    }
    try t.send("x" ++ enter);
    try t.expect("a", slow(10_000));
    try t.expect("forked", slow(10_000));
    try std.testing.expectEqual(0, try t.wait(slow(10_000)));
}

test "--serve works over a root without /bin/exportfs [serve]" {
    const e = try serveEnv(@src());
    try needBuiltin(e);
    var s: Scratch = undefined;
    try serveScratch(&s);
    defer s.deinit();
    // --read-deny hides the root's exportfs, which serving doesn't need
    // (design/epoch-0/kernel-serve.md).
    var db: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const deny = try std.fmt.bufPrint(&db, "{s}/{s}/bin/exportfs", .{ e.root, testArch(e) });
    var t = try startServer(e, &.{ "--cwd", s.path, "--read-deny", deny, "--serve", "tcp!127.0.0.1!0", "--rc", "test -e /bin/exportfs || echo ready; sleep 60" });
    defer t.deinit();
    var ab: [128]u8 = undefined;
    const addr = try servedAddr(&t, &ab);
    try t.expect("ready", slow(10_000));
    try expectServed(e, addr, "/mnt/temp/mnt/term/cwd/marker");
}

test "$serve lists the bound addresses [serve]" {
    const e = try serveEnv(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var pb: [512]u8 = undefined;
    var ab: [600]u8 = undefined;
    const unix = try std.fmt.bufPrint(&ab, "unix!{s}", .{try scratchPath(&s, &pb, "fs.sock")});
    // One engine: the output depends on a port h9 picks,
    // which a second engine's run wouldn't repeat.
    const r = try runOn(e, firstEngine(e), &.{ "--serve", unix, "--serve", "tcp!127.0.0.1!0", "--rc", "echo $#serve; echo $serve(1); echo $serve(2)" }, null);
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    var lines = std.mem.splitScalar(u8, r.out, '\n');
    try std.testing.expectEqualStrings("2", lines.next().?);
    try std.testing.expectEqualStrings(unix, lines.next().?);
    const tcp = lines.next().?;
    try std.testing.expect(std.mem.startsWith(u8, tcp, "tcp!127.0.0.1!"));
    try std.testing.expect(try addrPort(tcp) != 0);
    // The bound address is the one printed on stderr.
    try expectIn(r.err, tcp);
}

test "an interrupt to the program leaves clients connected [serve]" {
    const e = try serveEnv(@src());
    var t = try startServer(e, &.{ "--serve", "tcp!127.0.0.1!0", "rc", "-i" });
    defer t.deinit();
    var ab: [128]u8 = undefined;
    const port = try addrPort(try servedAddr(&t, &ab));
    try t.expect(prompt, slow(10_000));
    const k = try Sock.dial(port);
    defer k.close();
    try k.version();
    try t.send("sleep 60" ++ enter);
    try t.drain(500);
    try t.send("\x03");
    try t.expect(prompt, slow(10_000));
    try k.version();
    try t.send("exit" ++ enter);
    _ = try t.wait(slow(10_000));
}

test "two runs on one stale unix socket: one listens, one exits 125 [serve]" {
    // It stops the winner with SIGTERM, which Windows has no way to send.
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const e = try serveEnv(@src());
    var s: Scratch = undefined;
    try serveScratch(&s);
    defer s.deinit();
    var pb: [512]u8 = undefined;
    var ab: [600]u8 = undefined;
    const sock = try scratchPath(&s, &pb, "fs.sock");
    try staleSocket(sock);
    const addr = try std.fmt.bufPrint(&ab, "unix!{s}", .{sock});
    var a = try startServer(e, &.{ "--cwd", s.path, "--serve", addr });
    defer a.deinit();
    var b = try startServer(e, &.{ "--cwd", s.path, "--serve", addr });
    defer b.deinit();
    // One of the two fails; the other is still serving.
    var i: usize = 0;
    while (a.code == null and b.code == null) : (i += 1) {
        if (i > slow(200)) return error.Timeout;
        try a.drain(25);
        try b.drain(25);
    }
    const lost, const won = if (a.code != null) .{ &a, &b } else .{ &b, &a };
    try std.testing.expectEqual(125, lost.code.?);
    try std.testing.expect(std.mem.indexOf(u8, lost.out.items, "address in use") != null);
    try expectServed(e, addr, "/mnt/temp/mnt/term/cwd/marker");
    won.signal(.TERM);
    try std.testing.expectEqual(0, try won.wait(slow(10_000)));
    try std.testing.expect(!pathExists(sock));
}

test "--print lists listeners and elides the token [serve]" {
    const e = try serveEnv(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "token", .data = "s3cret\n" });
    var tb: [512]u8 = undefined;
    var fb: [600]u8 = undefined;
    const tok = try std.fmt.bufPrint(&fb, "@{s}", .{try scratchPath(&s, &tb, "token")});
    var pb: [512]u8 = undefined;
    var ub: [600]u8 = undefined;
    const sock = try scratchPath(&s, &pb, "fs.sock");
    const unix = try std.fmt.bufPrint(&ub, "unix!{s}", .{sock});
    const r = try run(e, &.{ "--print", "--serve", "ws://127.0.0.1:8080/9p", "--serve-token", tok, "--serve-origin", "http://a.example", "--serve", unix, "--write=none", "--rc", "echo" });
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try expectIn(r.out, "\n# serve:");
    try expectIn(r.out, "ws://127.0.0.1:8080/9p");
    try expectIn(r.out, "kernel -R -r /   (token, origins: http://a.example)");
    try expectIn(r.out, unix);
    try expectIn(r.out, "served without authentication on " ++ "unix!");
    try std.testing.expect(std.mem.indexOf(u8, r.out, "s3cret") == null);
    // --print binds nothing.
    try std.testing.expect(!pathExists(sock));
}

// 9P2000.L (design/epoch-0/dotl.md). Most cases use tests/dotlserver.zig's
// server, a tree in memory behind a loopback port, made fresh per
// connection, which can also drop connections and speak 9P2000.L.Z. The
// rest use diod, a real .L server, below.

fn dotlTree(s: *@import("dotlserver.zig").Server) !void {
    _ = try s.add("etc/motd", .file, "hello from .L\n");
    _ = try s.add("etc/passwd", .file, "root:x:0:0\n");
    _ = try s.add("usr/glenda/notes", .file, "one\ntwo\n");
    _ = try s.add("usr/glenda/full/f", .file, "");
    _ = try s.add("lib", .link, "usr/glenda");
    _ = try s.add("usr/abs", .link, "/etc/passwd");
    _ = try s.add("usr/escape", .link, "../../../../etc/passwd");
    _ = try s.add("usr/loop", .link, "loop");
    _ = try s.add("usr/dangling", .link, "nowhere");
}

/// Runs `script` in rc with the server mounted at /n/l by dotlfs.
fn dotlRun(e: Env, d: *DotlServer, script: []const u8) !Result {
    var allow_buf: [64]u8 = undefined;
    var cmd_buf: [1024]u8 = undefined;
    const allow = try std.fmt.bufPrint(&allow_buf, "tcp!127.0.0.1!{d}", .{d.port()});
    const cmd = try std.fmt.bufPrint(&cmd_buf, "mkdir -p /n/l; dotlfs {s} /n/l || exit mount; {s}", .{ d.dial(), script });
    // One engine: the server's state (its files, and a drop it's set to
    // make) carries over from one run to the next, so a second engine's
    // run can't match the first.
    return runOn(e, firstEngine(e), &.{ "--net-allow", allow, "--rc", cmd }, null);
}

test "a 9P root is never walked for dev, env, fd, proc, srv, or net [mounts]" {
    const e = try env(@src());
    var d: DotlServer = undefined;
    try d.startShared(std.testing.io, dotlTree, "9P2000.L");
    defer d.finish(std.testing.io);
    var ub: [96]u8 = undefined;
    // The served tree on top of the stack, so every walk into / that
    // reaches the stack asks it first.
    const r = try run(e, &.{ "--dir", e.root, "--url", try std.fmt.bufPrint(&ub, "{s}:/", .{d.url()}), "--rc", "cat /etc/motd; ls /dev/cons /env /fd /proc /srv /net >/dev/null && echo kernel" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("hello from .L\nkernel\n", r.out);
    const s = d.lock();
    defer d.unlock();
    var it = std.mem.tokenizeScalar(u8, s.walked.items, '\n');
    var etc = false;
    while (it.next()) |name| {
        if (std.mem.eql(u8, name, "etc")) etc = true;
        for ([_][]const u8{ "dev", "env", "fd", "proc", "srv", "net" }) |k|
            if (std.mem.eql(u8, name, k)) {
                std.debug.print("walked {s}\n", .{k});
                return error.TestUnexpectedResult;
            };
    }
    try std.testing.expect(etc);
}

test "the guest mounts the in-memory .L server with dotlfs, under the network policy [dotl]" {
    const e = try env(@src());
    var d: DotlServer = undefined;
    try d.start(std.testing.io, dotlTree);
    defer d.finish(std.testing.io);
    const r = try dotlRun(e, &d, "cat /n/l/etc/motd; ls /n/l/usr/glenda; cat /net/dotl/*/status");
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("hello from .L\n/n/l/usr/glenda/full\n/n/l/usr/glenda/notes\n9P2000.L\n", r.out);
    // When --net-allow doesn't cover the server the dial is refused, and
    // nothing is mounted.
    var cmd_buf: [256]u8 = undefined;
    const no = try run(e, &.{ "--net-allow", "tcp!127.0.0.1!1", "--rc", try std.fmt.bufPrint(&cmd_buf, "mkdir -p /n/l; dotlfs {s} /n/l && echo mounted", .{d.dial()}) });
    defer no.deinit();
    try std.testing.expect(no.code != 0);
    try std.testing.expect(std.mem.indexOf(u8, no.out, "mounted") == null);
}

test "a .L mount lists, reads, writes and removes [dotl]" {
    const e = try env(@src());
    var d: DotlServer = undefined;
    try d.start(std.testing.io, dotlTree);
    defer d.finish(std.testing.io);
    const r = try dotlRun(e, &d,
        \\cd /n/l/usr/glenda
        \\echo new >made && cat made
        \\echo more >>made && awk 'END{print NR}' made
        \\mkdir dir && touch dir/x && ls dir
        \\mv made renamed && ls
        \\rm renamed dir/x dir && ls
        \\ls -l notes | awk '{print $1, $6}'
    );
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("new\n2\ndir/x\ndir\nfull\nnotes\nrenamed\nfull\nnotes\n--rw-r--r-- 8\n", r.out);
}

test "a .L.Z mount lists, reads, writes and removes, with compound requests [dotl]" {
    const e = try env(@src());
    var d: DotlServer = undefined;
    try d.start(std.testing.io, dotlTree);
    d.version = "9P2000.L.Z";
    defer d.finish(std.testing.io);
    const r = try dotlRun(e, &d,
        \\cd /n/l/usr/glenda
        \\echo new >made && cat made
        \\echo more >>made && awk 'END{print NR}' made
        \\mkdir dir && touch dir/x && ls dir
        \\mv made renamed && ls
        \\rm renamed dir/x dir && ls
        \\ls -l notes /n/l/lib | awk '{print $1, $6, $NF}'
        \\cat /n/l/lib/notes
        \\cat /net/dotl/*/status
    );
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("new\n2\ndir/x\ndir\nfull\nnotes\nrenamed\nfull\nnotes\n--rw-r--r-- 8 notes\nd-rwxr-xr-x 0 /n/l/lib/full\n--rw-r--r-- 8 /n/l/lib/notes\none\ntwo\n9P2000.L.Z\n", r.out);
}

test "a symlink in the in-memory .L server is followed and can't leave the mount [dotl]" {
    const e = try env(@src());
    var d: DotlServer = undefined;
    try d.start(std.testing.io, dotlTree);
    defer d.finish(std.testing.io);
    const r = try dotlRun(e, &d,
        \\cat /n/l/usr/abs /n/l/usr/escape /n/l/lib/notes
        \\ls /n/l/usr
        \\# A walk's error reaches the guest only from its first name.
        \\cd /n/l/usr && cat loop
    );
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    // A link that resolves to nothing, dangling or a loop, isn't listed.
    try std.testing.expectEqualStrings("root:x:0:0\nroot:x:0:0\none\ntwo\n/n/l/usr/abs\n/n/l/usr/escape\n/n/l/usr/glenda\n", r.out[0..@min(r.out.len, 200)]);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "too many symbolic links") != null);
}

test "Rlerror errnos from the in-memory .L server become 9front error strings [dotl]" {
    const e = try env(@src());
    var d: DotlServer = undefined;
    try d.start(std.testing.io, dotlTree);
    defer d.finish(std.testing.io);
    const r = try dotlRun(e, &d,
        \\cat /n/l/etc/nope
        \\rm /n/l/usr/glenda/full
        \\mkdir /n/l/etc
    );
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expect(std.mem.indexOf(u8, r.err, "file does not exist: '/n/l/etc/nope'") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "directory not empty") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "already exists") != null);
}

test "a .L mount attaches as the host uid, not 0, without --user-map [dotl]" {
    const e = try env(@src());
    var d: DotlServer = undefined;
    try d.start(std.testing.io, dotlTree);
    defer d.finish(std.testing.io);
    const r = try dotlRun(e, &d, "ls /n/l >/dev/null");
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(d.attached.load(.acquire));
    const uid: u32 = if (builtin.os.tag == .windows) 1000 else std.c.getuid();
    try std.testing.expectEqual(if (uid == 0) @as(u32, 65534) else uid, d.n_uname);
}

/// The root tree and arch a .L root's fill copies programs from; set by
/// the case before the server starts.
var dotl_root_from: struct { root: []const u8 = "", arch: []const u8 = "" } = .{};

/// A small 9front root in memory: dotlTree, the mount points, rc and a
/// few programs from the test's root tree.
fn dotlRootTree(s: *@import("dotlserver.zig").Server) !void {
    try dotlTree(s);
    for ([_][]const u8{ "dev", "env", "fd", "proc", "srv", "net", "n", "tmp", "mnt/term/cwd", "bin" }) |d| _ = try s.add(d, .dir, "");
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, dotl_root_from.root, .{});
    defer dir.close(std.testing.io);
    var prog_buf: [64]u8 = undefined;
    for ([_][]const u8{ "rc", "echo", "ls", "cat", "rm" }) |prog| {
        const host = try std.fmt.bufPrint(&prog_buf, "{s}/bin/{s}", .{ dotl_root_from.arch, prog });
        const bytes = try dir.readFileAlloc(std.testing.io, host, s.arena.allocator(), .limited(16 << 20));
        (try s.add(host, .file, bytes)).mode = 0o755;
    }
    _ = try s.add("rc/lib/rcmain", .file, try dir.readFileAlloc(std.testing.io, "rc/lib/rcmain", s.arena.allocator(), .limited(1 << 20)));
}

test "a 9P2000.L root from the in-memory server lists, reads, writes and removes [dotl]" {
    const e = try env(@src());
    dotl_root_from = .{ .root = e.root, .arch = e.arch orelse switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86 => "386",
        else => "amd64",
    } };
    var d: DotlServer = undefined;
    try d.start(std.testing.io, dotlRootTree);
    defer d.finish(std.testing.io);
    const r = try run(e, &.{
        "--url", d.url(), "--write=scope", "--rc",
        \\cat /etc/motd /usr/glenda/notes
        \\echo new >/usr/glenda/made && cat /usr/glenda/made
        \\rm /usr/glenda/notes && ls /usr/glenda
        \\cat /net/dotl/*/status
    });
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("hello from .L\none\ntwo\nnew\n/usr/glenda/full\n/usr/glenda/made\n9P2000.L\n", r.out);
}

test "a 9P2000 root goes through the translator unchanged [dotl]" {
    const e = try env(@src());
    var srv: RootServer = undefined;
    try srv.start(e);
    defer srv.stop();
    const r = try run(e, &.{ "--url", srv.url(), "--rc", "cat /net/dotl/*/status; ls /bin/ls" });
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("9P2000\n/bin/ls\n", r.out);
}

test "a 9P2000.L.Z mount resumes a write the server dropped, applied once [dotl]" {
    const e = try env(@src());
    var d: DotlServer = undefined;
    try d.startShared(std.testing.io, dotlTree, "9P2000.L.Z");
    defer d.finish(std.testing.io);
    // The server applies the second write and goes before answering it,
    // as a crash would. The file was made by create, with OTRUNC.
    d.lock().drop_after_write = 1;
    d.unlock();
    const r = try dotlRun(e, &d,
        \\{ echo one; echo two; echo three } >/n/l/usr/glenda/log
        \\cat /n/l/usr/glenda/log
        \\cat /net/dotl/*/status
    );
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqual(0, r.code);
    // Reopened without OTRUNC, and the resent write answered from what
    // the server remembers rather than applied again.
    try std.testing.expectEqualStrings("one\ntwo\nthree\n9P2000.L.Z reconnects 1\n", r.out);
    const s = d.lock();
    defer d.unlock();
    try std.testing.expectEqual(1, s.replayed);
    try std.testing.expectEqual(2, d.connections.load(.acquire));
}

test "the in-memory .L.Z server's reconnect doesn't truncate a file opened with OTRUNC [dotl]" {
    const e = try env(@src());
    var d: DotlServer = undefined;
    try d.startShared(std.testing.io, dotlTree, "9P2000.L.Z");
    defer d.finish(std.testing.io);
    // The first write to an existing file opened with OTRUNC is dropped.
    d.lock().drop_after_write = 0;
    d.unlock();
    const r = try dotlRun(e, &d,
        \\{ echo x; echo y } >/n/l/usr/glenda/notes
        \\cat /n/l/usr/glenda/notes
    );
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("x\ny\n", r.out);
}

test "a .L.Z root from the in-memory server survives it dropping the connection mid-write [dotl]" {
    const e = try env(@src());
    dotl_root_from = .{ .root = e.root, .arch = e.arch orelse switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86 => "386",
        else => "amd64",
    } };
    var d: DotlServer = undefined;
    try d.startShared(std.testing.io, dotlRootTree, "9P2000.L.Z");
    defer d.finish(std.testing.io);
    d.lock().drop_after_write = 0;
    d.unlock();
    // One engine: the output depends on the server's state,
    // which a second engine's run wouldn't repeat.
    const r = try runOn(e, firstEngine(e), &.{
        "--url", d.url(), "--write=scope", "--rc",
        \\echo new >/usr/glenda/made && cat /usr/glenda/made
        \\cat /net/dotl/*/status
    }, null);
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("new\n9P2000.L.Z reconnects 1\n", r.out);
}

test "a 9P2000.L.Z mount moves to the next address when the server isn't the leader [dotl]" {
    const e = try env(@src());
    var d: DotlServer = undefined;
    try d.startShared(std.testing.io, dotlTree, "9P2000.L.Z");
    defer d.finish(std.testing.io);
    d.lock().not_leader = 1;
    d.unlock();
    // The first address refuses, so both dials and the redial go round
    // the list to the second.
    var allow_buf: [64]u8 = undefined;
    var cmd_buf: [512]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf,
        \\mkdir -p /n/l; dotlfs tcp!127.0.0.1!1,{s} /n/l || exit mount
        \\echo led >/n/l/usr/glenda/log && cat /n/l/usr/glenda/log
        \\cat /net/dotl/*/status
    , .{d.dial()});
    // One engine: the output depends on the server's state,
    // which a second engine's run wouldn't repeat.
    const r = try runOn(e, firstEngine(e), &.{ "--net-allow", "tcp!127.0.0.1!1", "--net-allow", try std.fmt.bufPrint(&allow_buf, "tcp!127.0.0.1!{d}", .{d.port()}), "--rc", cmd }, null);
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("led\n9P2000.L.Z reconnects 1\n", r.out);
    try std.testing.expectEqual(2, d.connections.load(.acquire));
}

test "a .L.Z unix socket root survives the server restarting mid-write [dotl]" {
    if (!std.Io.net.has_unix_sockets or builtin.os.tag == .windows) return error.SkipZigTest;
    const e = try env(@src());
    dotl_root_from = .{ .root = e.root, .arch = e.arch orelse switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86 => "386",
        else => "amd64",
    } };
    var d: DotlServer = undefined;
    try d.startShared(std.testing.io, dotlRootTree, "9P2000.L.Z");
    defer d.finish(std.testing.io);
    d.lock().drop_after_write = 0;
    d.unlock();
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var pb: [512]u8 = undefined;
    var ab: [600]u8 = undefined;
    var relay: UnixRelay = undefined;
    const sock = try scratchPath(&s, &pb, "fs.sock");
    try relay.start(sock, d.port());
    // One engine: the output depends on the server's state,
    // which a second engine's run wouldn't repeat.
    const r = try runOn(e, firstEngine(e), &.{
        "--url", try std.fmt.bufPrint(&ab, "unix://{s}", .{sock}), "--write=scope", "--rc",
        \\echo new >/usr/glenda/made && cat /usr/glenda/made
        \\cat /net/dotl/*/status
    }, null);
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("new\n9P2000.L.Z reconnects 1\n", r.out);
}

test "a namespace file mounts a .L server by its dial string, under the network policy [dotl]" {
    const e = try env(@src());
    var d: DotlServer = undefined;
    try d.start(std.testing.io, dotlTree);
    defer d.finish(std.testing.io);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var ns_buf: [128]u8 = undefined;
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ns", .data = try std.fmt.bufPrint(&ns_buf, "mount -c {s} /mnt/temp\n", .{d.dial()}) });
    var allow_buf: [64]u8 = undefined;
    const allow = try std.fmt.bufPrint(&allow_buf, "tcp!127.0.0.1!{d}", .{d.port()});
    const r = try run(e, &.{ "--cwd", s.path, "--ns", s.ns(), "--net-allow", allow, "--rc", "cat /mnt/temp/etc/motd; cat /net/dotl/*/status" });
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("hello from .L\n9P2000.L\n", r.out);
    // Not allowed, it isn't mounted, and the run goes on, as newns
    // skips a mount that fails.
    const no = try run(e, &.{ "--cwd", s.path, "--ns", s.ns(), "--net-allow", "tcp!127.0.0.1!1", "--rc", "test -e /mnt/temp/etc/motd || echo skipped" });
    defer no.deinit();
    try std.testing.expectEqualStrings("skipped\n", no.out);
}

test "the guest can't dial a host unix socket through #ℓ [dotl]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--rc", "{ n=`{cat}; echo dial unix!/tmp/x.sock >/net/dotl/$n/ctl } <>/net/dotl/clone" });
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expect(r.code != 0);
    try expectIn(r.err, "unix sockets are for roots");
}

// The same against diod (`scripts/fetch.sh diod`, x86_64 Linux only),
// serving a scratch directory: a .L server h9 didn't write.

const Diod = struct {
    child: std.process.Child,
    port: u16,
    s: Scratch,
    dial_buf: [64]u8 = undefined,
    url_buf: [64]u8 = undefined,
    allow_buf: [64]u8 = undefined,

    /// Runs `setup`, an sh script, in a new scratch directory, and
    /// serves the directory. diod running as root acts as whichever uid
    /// attaches, so the tree is made writable by anyone; diod running as
    /// anyone else is told to take only the host uid, which is what h9
    /// should send.
    fn start(d: *Diod, setup: []const u8) !void {
        const io = std.testing.io;
        const bin = getenv(5, "H9_TEST_DIOD") orelse return error.SkipZigTest;
        std.Io.Dir.cwd().access(io, bin, .{}) catch return error.SkipZigTest;
        try d.s.init();
        errdefer d.s.deinit();
        var script: std.ArrayList(u8) = .empty;
        defer script.deinit(gpa);
        try script.print(gpa, "set -e; cd '{s}'\n{s}\nchmod -R a+rwX .\n", .{ d.s.path, setup });
        const r = try runProcessWith(&.{ "sh", "-c", script.items }, null, null, 30_000);
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        if (r.term != .exited or r.term.exited != 0) {
            std.debug.print("diod tree: {s}\n", .{r.stderr});
            return error.DiodSetup;
        }
        var probe = try listenLocal();
        d.port = probe.socket.address.getPort();
        probe.deinit(io);
        var listen_buf: [32]u8 = undefined;
        var uid_buf: [16]u8 = undefined;
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ bin, "-f", "-n", "-N", "-L", "stderr", "-l", try std.fmt.bufPrint(&listen_buf, "127.0.0.1:{d}", .{d.port}), "-e", d.s.path });
        // diod runs only on Linux; this compiles for Windows too.
        const uid: u32 = if (builtin.os.tag == .windows) 0 else std.c.getuid();
        if (uid != 0) try argv.appendSlice(gpa, &.{ "-u", try std.fmt.bufPrint(&uid_buf, "{d}", .{uid}) });
        d.child = try std.process.spawn(io, .{ .argv = argv.items, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
        errdefer d.child.kill(io);
        const ip = try std.Io.net.IpAddress.parse("127.0.0.1", d.port);
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

    fn dial(d: *Diod) []const u8 {
        return std.fmt.bufPrint(&d.dial_buf, "tcp!127.0.0.1!{d}", .{d.port}) catch unreachable;
    }

    /// The server as a --url (design/epoch-0/mounts.md).
    fn url(d: *Diod) []const u8 {
        return std.fmt.bufPrint(&d.url_buf, "tcp://127.0.0.1:{d}", .{d.port}) catch unreachable;
    }

    fn allow(d: *Diod) []const u8 {
        return std.fmt.bufPrint(&d.allow_buf, "tcp!127.0.0.1!{d}", .{d.port}) catch unreachable;
    }

    fn stop(d: *Diod) void {
        d.child.kill(std.testing.io);
        d.s.deinit();
    }

    /// Runs `script` in rc with the export mounted at /n/l by dotlfs.
    fn rc(d: *Diod, e: Env, script: []const u8) !Result {
        var cmd: std.ArrayList(u8) = .empty;
        defer cmd.deinit(gpa);
        try cmd.print(gpa, "mkdir -p /n/l; dotlfs {s} /n/l '{s}' || exit mount; {s}", .{ d.dial(), d.s.path, script });
        return run(e, &.{ "--net-allow", d.allow(), "--rc", cmd.items });
    }
};

/// dotlTree's files and links, for diod.
const diod_tree =
    \\mkdir -p etc usr/glenda/full
    \\printf 'hello from .L\n' >etc/motd
    \\printf 'root:x:0:0\n' >etc/passwd
    \\printf 'one\ntwo\n' >usr/glenda/notes
    \\: >usr/glenda/full/f
    \\ln -s usr/glenda lib
    \\ln -s /etc/passwd usr/abs
    \\ln -s ../../../../etc/passwd usr/escape
    \\ln -s loop usr/loop
    \\ln -s nowhere usr/dangling
;

test "the guest mounts a .L server with dotlfs, under the network policy [dotl]" {
    const e = try env(@src());
    var d: Diod = undefined;
    try d.start(diod_tree);
    defer d.stop();
    const r = try d.rc(e, "cat /n/l/etc/motd; ls /n/l/usr/glenda; cat /net/dotl/*/status");
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqual(0, r.code);
    // diod refuses 9P2000.L.Z with an error, and is offered .L.
    try std.testing.expectEqualStrings("hello from .L\n/n/l/usr/glenda/full\n/n/l/usr/glenda/notes\n9P2000.L\n", r.out);
    var cmd_buf: [512]u8 = undefined;
    const no = try run(e, &.{ "--net-allow", "tcp!127.0.0.1!1", "--rc", try std.fmt.bufPrint(&cmd_buf, "mkdir -p /n/l; dotlfs {s} /n/l && echo mounted", .{d.dial()}) });
    defer no.deinit();
    try std.testing.expect(no.code != 0);
    try std.testing.expect(std.mem.indexOf(u8, no.out, "mounted") == null);
}

test "a .L mount of diod lists, reads, writes and removes [dotl]" {
    const e = try env(@src());
    var d: Diod = undefined;
    try d.start(diod_tree);
    defer d.stop();
    // diod 1.0 has no Tunlinkat or Trenameat, so rm and mv take Tremove
    // and Trename, and its directories are 0777 here, so so are the
    // modes of what's made in them, by create(5).
    const r = try d.rc(e,
        \\cd /n/l/usr/glenda
        \\echo new >made && cat made
        \\echo more >>made && awk 'END{print NR}' made
        \\mkdir dir && touch dir/x && ls dir
        \\mv made renamed && ls
        \\ls -l renamed | awk '{print $1, $6}'
        \\rm renamed dir/x dir && ls
    );
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("new\n2\ndir/x\ndir\nfull\nnotes\nrenamed\n--rw-rw-rw- 9\nfull\nnotes\n", r.out);
    try std.testing.expect(!d.s.exists("usr/glenda/renamed"));
}

test "a symlink in a .L mount is followed and can't leave the mount [dotl]" {
    const e = try env(@src());
    var d: Diod = undefined;
    try d.start(diod_tree);
    defer d.stop();
    const r = try d.rc(e,
        \\cat /n/l/usr/abs /n/l/usr/escape /n/l/lib/notes
        \\ls /n/l/usr
        \\cd /n/l/usr && cat loop
    );
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    // The links resolve inside the export, not to the host's /etc/passwd.
    try std.testing.expectEqualStrings("root:x:0:0\nroot:x:0:0\none\ntwo\n/n/l/usr/abs\n/n/l/usr/escape\n/n/l/usr/glenda\n", r.out);
    try expectIn(r.err, "too many symbolic links");
}

test "Rlerror errnos become 9front error strings [dotl]" {
    const e = try env(@src());
    var d: Diod = undefined;
    try d.start(diod_tree);
    defer d.stop();
    const r = try d.rc(e,
        \\cat /n/l/etc/nope
        \\rm /n/l/usr/glenda/full
        \\mkdir /n/l/etc
    );
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try expectIn(r.err, "file does not exist: '/n/l/etc/nope'");
    try expectIn(r.err, "directory not empty");
    try expectIn(r.err, "already exists");
}

/// dotlRootTree's root, for diod: the mount points, rc, and a few
/// programs from the test's root tree.
fn diodRootTree(buf: []u8, e: Env) ![]const u8 {
    const arch = e.arch orelse switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86 => "386",
        else => "amd64",
    };
    return std.fmt.bufPrint(buf, diod_tree ++
        \\
        \\mkdir -p dev env fd proc srv net n tmp mnt/term/cwd bin {1s}/bin rc/lib
        \\for p in rc echo ls cat rm; do cp '{0s}/{1s}/bin/'$p {1s}/bin/; done
        \\cp '{0s}/rc/lib/rcmain' rc/lib/
    , .{ e.root, arch });
}

test "a 9P2000.L root lists, reads, writes and removes [dotl]" {
    const e = try env(@src());
    var d: Diod = undefined;
    var tree_buf: [2048]u8 = undefined;
    try d.start(try diodRootTree(&tree_buf, e));
    defer d.stop();
    var ub: [std.Io.Dir.max_path_bytes + 64]u8 = undefined;
    var ob: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    const r = try run(e, &.{
        "--url", urlOpts(&ub, d.url(), try std.fmt.bufPrint(&ob, "spec={s}", .{d.s.path})), "--write=scope", "--rc",
        \\cat /etc/motd /usr/glenda/notes
        \\echo new >/usr/glenda/made && cat /usr/glenda/made
        \\rm /usr/glenda/notes && ls /usr/glenda
        \\cat /net/dotl/*/status
    });
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("hello from .L\none\ntwo\nnew\n/usr/glenda/full\n/usr/glenda/made\n9P2000.L\n", r.out);
}

test "a .L root attaches as the host uid, not 0, without --user-map [dotl]" {
    const e = try env(@src());
    var d: Diod = undefined;
    var tree_buf: [2048]u8 = undefined;
    try d.start(try diodRootTree(&tree_buf, e));
    defer d.stop();
    // diod as root creates files as the uid that attached; as anyone
    // else, it takes only the host uid.
    var ub: [std.Io.Dir.max_path_bytes + 64]u8 = undefined;
    var ob: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    const r = try run(e, &.{ "--url", urlOpts(&ub, d.url(), try std.fmt.bufPrint(&ob, "spec={s}", .{d.s.path})), "--write=scope", "--rc", "echo x >/usr/glenda/f" });
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqual(0, r.code);
    var pb: [600]u8 = undefined;
    const st = try runProcessWith(&.{ "stat", "-c", "%u", try scratchPath(&d.s, &pb, "usr/glenda/f") }, null, null, 10_000);
    defer gpa.free(st.stdout);
    defer gpa.free(st.stderr);
    const uid: u32 = if (builtin.os.tag == .windows) 0 else std.c.getuid();
    var want_buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&want_buf, "{d}\n", .{if (uid == 0) @as(u32, 65534) else uid}), st.stdout);
}

test "an h9 root over --serve speaks 9P2000.L through both translators [dotl]" {
    const e = try serveEnv(@src());
    var s: Scratch = undefined;
    try serveScratch(&s);
    defer s.deinit();
    var t = try startServer(e, &.{ "--cwd", s.path, "--serve", "tcp!127.0.0.1!0", "--rc", "echo ready; sleep 60" });
    defer t.deinit();
    var ab: [128]u8 = undefined;
    const addr = try servedAddr(&t, &ab);
    try t.expect("ready", slow(10_000));
    // The client offers 9P2000.L.Z and the server answers 9P2000.L.
    const r = try runServed(e, addr,
        \\cat /net/dotl/*/status
        \\cd /mnt/temp/tmp && echo hi >f && cat f && mkdir d && mv f g && ls -F && rm g && rm d && ls
        \\cat /mnt/temp/mnt/term/cwd/marker
    );
    defer r.deinit();
    errdefer std.debug.print("client stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("9P2000.L\nhi\nd/\ng\nserved\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

// The .L.Z cases against ZeroFS (`scripts/fetch.sh zerofs`), with its
// in-memory store. ZeroFS has no local-file store, and the in-memory one
// is gone when the server stops, so "the server restarting" is the
// connection dropping under h9 instead: CutRelay closes it right after
// passing on a Twrite, before the reply, as a crash or failover would.

const ZeroFs = struct {
    child: std.process.Child,
    port: u16,
    s: Scratch,
    relay: CutRelay = undefined,
    dial_buf: [64]u8 = undefined,
    url_buf: [64]u8 = undefined,
    allow_buf: [64]u8 = undefined,

    fn start(z: *ZeroFs) !void {
        const io = std.testing.io;
        const bin = getenv(5, "H9_TEST_ZEROFS") orelse return error.SkipZigTest;
        std.Io.Dir.cwd().access(io, bin, .{}) catch return error.SkipZigTest;
        try z.s.init();
        errdefer z.s.deinit();
        var probe = try listenLocal();
        z.port = probe.socket.address.getPort();
        probe.deinit(io);
        var conf: std.ArrayList(u8) = .empty;
        defer conf.deinit(gpa);
        try conf.print(gpa,
            \\[cache]
            \\dir = "{s}/cache"
            \\disk_size_gb = 1.0
            \\memory_size_gb = 0.1
            \\[storage]
            \\url = "memory:///"
            \\encryption_password = "h9-test-password"
            \\[servers.ninep]
            \\addresses = ["127.0.0.1:{d}"]
            \\
        , .{ z.s.path, z.port });
        try z.s.tmp.dir.writeFile(io, .{ .sub_path = "zerofs.toml", .data = conf.items });
        var pb: [600]u8 = undefined;
        z.child = try std.process.spawn(io, .{ .argv = &.{ bin, "run", "--config", try scratchPath(&z.s, &pb, "zerofs.toml") }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
        errdefer z.child.kill(io);
        const ip = try std.Io.net.IpAddress.parse("127.0.0.1", z.port);
        var tries: u32 = 0;
        while (true) : (tries += 1) {
            const c = ip.connect(io, .{ .mode = .stream }) catch |err| {
                if (tries >= slow(300)) return err;
                try io.sleep(.fromMilliseconds(100), .awake);
                continue;
            };
            c.close(io);
            break;
        }
        try z.relay.start(z.port);
    }

    /// The relay's address, which h9 dials.
    fn dial(z: *ZeroFs) []const u8 {
        return std.fmt.bufPrint(&z.dial_buf, "tcp!127.0.0.1!{d}", .{z.relay.listen_port}) catch unreachable;
    }

    /// The server as a --url (design/epoch-0/mounts.md).
    fn url(z: *ZeroFs) []const u8 {
        return std.fmt.bufPrint(&z.url_buf, "tcp://127.0.0.1:{d}", .{z.relay.listen_port}) catch unreachable;
    }

    fn allow(z: *ZeroFs) []const u8 {
        return std.fmt.bufPrint(&z.allow_buf, "tcp!127.0.0.1!{d}", .{z.relay.listen_port}) catch unreachable;
    }

    fn stop(z: *ZeroFs) void {
        z.child.kill(std.testing.io);
        z.s.deinit();
    }

    /// Runs `script` in rc with ZeroFS mounted at /n/z by dotlfs.
    fn rc(z: *ZeroFs, e: Env, script: []const u8) !Result {
        var cmd: std.ArrayList(u8) = .empty;
        defer cmd.deinit(gpa);
        try cmd.print(gpa, "mkdir -p /n/z; dotlfs -c {s} /n/z || exit mount; {s}", .{ z.dial(), script });
        return run(e, &.{ "--net-allow", z.allow(), "--rc", cmd.items });
    }
};

/// A TCP relay to a 9P server on loopback that, once armed, closes the
/// connection right after passing on a Twrite, before its reply comes.
/// Connections after that pass through.
const CutRelay = struct {
    srv: std.Io.net.Server,
    to: u16,
    listen_port: u16,
    /// Twrites to pass before cutting; negative, none.
    cut_after: std.atomic.Value(i32) = .init(-1),
    cuts: std.atomic.Value(u32) = .init(0),
    connections: std.atomic.Value(u32) = .init(0),

    fn start(r: *CutRelay, to: u16) !void {
        const srv = try listenLocal();
        r.* = .{ .srv = srv, .to = to, .listen_port = srv.socket.address.getPort() };
        const t = try std.Thread.spawn(.{}, accept, .{r});
        t.detach();
    }

    fn arm(r: *CutRelay, writes: i32) void {
        r.cut_after.store(writes, .release);
    }

    fn accept(r: *CutRelay) void {
        const io = std.testing.io;
        while (true) {
            const c = deadline.accept(&r.srv, io) catch return;
            const ip = std.Io.net.IpAddress.parse("127.0.0.1", r.to) catch unreachable;
            const s = ip.connect(io, .{ .mode = .stream }) catch {
                c.close(io);
                continue;
            };
            _ = r.connections.fetchAdd(1, .acq_rel);
            const t = std.Thread.spawn(.{}, UnixRelay.copy, .{ s, c }) catch return;
            t.detach();
            const t2 = std.Thread.spawn(.{}, up, .{ r, c, s }) catch return;
            t2.detach();
        }
    }

    /// Passes the client's messages on whole, cutting after the armed
    /// Twrite.
    fn up(r: *CutRelay, from: std.Io.net.Stream, to: std.Io.net.Stream) void {
        const io = std.testing.io;
        const buf = std.heap.page_allocator.alloc(u8, 16 << 20) catch return;
        defer std.heap.page_allocator.free(buf);
        var rd = from.reader(io, buf);
        var w = to.writer(io, &.{});
        while (true) {
            const hdr = rd.interface.peek(5) catch break;
            const size = std.mem.readInt(u32, hdr[0..4], .little);
            if (size < 7 or size > buf.len) break;
            const frame = rd.interface.take(size) catch break;
            w.interface.writeAll(frame) catch break;
            if (frame[4] == 118 and r.cut_after.fetchSub(1, .acq_rel) == 0) {
                _ = r.cuts.fetchAdd(1, .acq_rel);
                break;
            }
        }
        to.shutdown(io, .both) catch {};
        from.shutdown(io, .both) catch {};
    }
};

test "a .L.Z mount of ZeroFS lists, reads, writes and removes [dotl]" {
    const e = try env(@src());
    var z: ZeroFs = undefined;
    try z.start();
    defer z.stop();
    const r = try z.rc(e,
        \\cat /net/dotl/*/status
        \\cd /n/z
        \\echo new >made && cat made
        \\echo more >>made && awk 'END{print NR}' made
        \\mkdir dir && touch dir/x && ls dir
        \\mv made renamed && ls
        \\ls -l renamed | awk '{print $1, $6}'
        \\rm renamed dir/x dir && ls
        \\rm nope
    );
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    // rc creates with 0666, and ZeroFS's root is 0777, so create(5)
    // leaves the file 0666.
    try std.testing.expectEqualStrings("9P2000.L.Z\nnew\n2\ndir/x\ndir\nrenamed\n--rw-rw-rw- 9\n", r.out);
    try expectIn(r.err, "file does not exist");
}

test "a .L.Z reconnect doesn't truncate a file opened with OTRUNC [dotl]" {
    const e = try env(@src());
    var z: ZeroFs = undefined;
    try z.start();
    defer z.stop();
    const made = try z.rc(e, "echo old >/n/z/notes");
    made.deinit();
    // The first write to the file, opened with OTRUNC by >, is cut off.
    // The open is replayed without O_TRUNC, and the write resent once.
    z.relay.arm(0);
    const r = try z.rc(e,
        \\{ echo x; echo y } >/n/z/notes
        \\cat /n/z/notes
        \\cat /net/dotl/*/status
    );
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("x\ny\n9P2000.L.Z reconnects 1\n", r.out);
    try std.testing.expectEqual(1, z.relay.cuts.load(.acquire));
}

test "a .L.Z root survives the server restarting mid-write [dotl]" {
    const e = try env(@src());
    var z: ZeroFs = undefined;
    try z.start();
    defer z.stop();
    // A small 9front root in ZeroFS, put there through a mount.
    const arch = e.arch orelse switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86 => "386",
        else => "amd64",
    };
    var fill_buf: [1024]u8 = undefined;
    const fill = try z.rc(e, try std.fmt.bufPrint(&fill_buf,
        \\cd /n/z && mkdir -p dev env fd proc srv net n tmp mnt/term/cwd bin usr/glenda {0s}/bin rc/lib
        \\for(p in rc echo cat) cp /{0s}/bin/$p {0s}/bin/
        \\cp /rc/lib/rcmain rc/lib/
    , .{arch}));
    defer fill.deinit();
    if (fill.code != 0) std.debug.print("fill: {s}\n", .{fill.err});
    try std.testing.expectEqual(0, fill.code);
    z.relay.arm(1);
    const r = try run(e, &.{
        "--url", z.url(), "--write=scope", "--rc",
        \\{ echo one; echo two; echo three } >/usr/glenda/log
        \\cat /usr/glenda/log
        \\cat /net/dotl/*/status
    });
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqual(0, r.code);
    // Each line once: the cut write was applied once, resent or not.
    try std.testing.expectEqualStrings("one\ntwo\nthree\n9P2000.L.Z reconnects 1\n", r.out);
    try std.testing.expectEqual(1, z.relay.cuts.load(.acquire));
}

/// How to run a command as root to mount 9P over a unix socket, on Linux
/// with 9p and its unix transport in the kernel (after a modprobe, if
/// allowed): "" as root, "sudo -n " where sudo needs no password (the
/// Lima VMs and CI's runners), or null if neither.
fn v9fsAsRoot() ?[]const u8 {
    if (builtin.os.tag != .linux) return null;
    const pre: []const u8 = if (builtin.os.tag == .windows or std.c.getuid() == 0) "" else "sudo -n ";
    var cmd_buf: [96]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "{s}modprobe -q 9p; {s}modprobe -q 9pnet_fd; {s}true", .{ pre, pre, pre }) catch return null;
    const r = runProcessWith(&.{ "sh", "-c", cmd }, null, null, 10_000) catch return null;
    gpa.free(r.stdout);
    gpa.free(r.stderr);
    if (r.term != .exited or r.term.exited != 0) return null;
    var buf: [8192]u8 = undefined;
    const fs = std.Io.Dir.cwd().readFile(std.testing.io, "/proc/filesystems", &buf) catch return null;
    if (std.mem.indexOf(u8, fs, "\t9p\n") == null) return null;
    // And its unix transport, which a kernel can leave out, keeping only
    // virtio's, as exe.dev's VMs do.
    const ks = runProcessWith(&.{ "sh", "-c", "grep -qw p9_fd_create_unix /proc/kallsyms" }, null, null, 10_000) catch return null;
    gpa.free(ks.stdout);
    gpa.free(ks.stderr);
    if (ks.term != .exited or ks.term.exited != 0) return null;
    return pre;
}

test "Linux v9fs mounts --serve over a unix socket [dotl]" {
    const e = try serveEnv(@src());
    // Linux's own 9P client, as root: in the linux-kvm VM, for one.
    const sudo = v9fsAsRoot() orelse return error.SkipZigTest;
    var s: Scratch = undefined;
    try serveScratch(&s);
    defer s.deinit();
    var pb: [512]u8 = undefined;
    var ab: [600]u8 = undefined;
    var mb: [512]u8 = undefined;
    const sock = try scratchPath(&s, &pb, "h9.sock");
    const addr = try std.fmt.bufPrint(&ab, "unix!{s}", .{sock});
    const mnt = try scratchPath(&s, &mb, "mnt");
    try s.tmp.dir.createDir(std.testing.io, "mnt", .default_dir);
    var t = try startServer(e, &.{ "--cwd", s.path, "--serve", addr, "--rc", "echo ready; sleep 60" });
    defer t.deinit();
    try t.expect("ready", slow(10_000));
    var script: std.ArrayList(u8) = .empty;
    defer script.deinit(gpa);
    try script.print(gpa,
        \\set -e
        \\{2s}mount -t 9p -o trans=unix,version=9p2000.L '{0s}' '{1s}'
        \\trap "{2s}umount -l '{1s}'" EXIT
        \\ls '{1s}/bin' | grep -x rc
        \\cat '{1s}/mnt/term/cwd/marker'
        \\{2s}sh -c "echo hi >'{1s}/tmp/v9fs'" && cat '{1s}/tmp/v9fs' && {2s}rm '{1s}/tmp/v9fs'
    , .{ sock, mnt, sudo });
    const r = try runProcessWith(&.{ "sh", "-c", script.items }, null, null, 30_000);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.stdout, r.stderr });
    try std.testing.expect(r.term == .exited and r.term.exited == 0);
    try std.testing.expectEqualStrings("rc\nserved\nhi\n", r.stdout);
}

test "a .L client of --serve under --write=none gets EROFS [dotl]" {
    const e = try serveEnv(@src());
    var t = try startServer(e, &.{ "--write=none", "--serve", "tcp!127.0.0.1!0", "--rc", "echo ready; sleep 60" });
    defer t.deinit();
    var ab: [128]u8 = undefined;
    const addr = try servedAddr(&t, &ab);
    try t.expect("ready", slow(10_000));
    const r = try runServed(e, addr, "cat /net/dotl/*/status; touch /mnt/temp/tmp/f");
    defer r.deinit();
    errdefer std.debug.print("client stdout: {s}\nclient stderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqualStrings("9P2000.L\n", r.out);
    try expectIn(r.err, "read-only file system");
}

// credential-helpers: --cred helpers for host-made WebSocket handshakes.

/// A credential helper in `s`'s directory, `name`, running `body` with
/// /bin/sh. h9 runs it as `name get URL`; `$d` is its directory, and
/// every run appends `get URL | <stdin's first line, or "-">` to
/// `$d/name.log`.
fn credHelper(s: *Scratch, name: []const u8, body: []const u8) ![]const u8 {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var buf: [1024]u8 = undefined;
    const script = try std.fmt.bufPrint(&buf,
        \\#!/bin/sh
        \\d=${{0%/*}}
        \\in=$(cat)
        \\first=$(printf '%s\n' "$in" | head -n 1 | tr -d '\r')
        \\echo "$1 $2 | ${{first:--}}" >>"$d/{s}.log"
        \\{s}
        \\
    , .{ name, body });
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = script, .flags = .{ .permissions = .executable_file } });
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ s.path, name });
}

/// The helper `name`'s log, or "" if it never ran.
fn credLog(s: *Scratch, name: []const u8, buf: []u8) []const u8 {
    var nb: [64]u8 = undefined;
    const f = std.fmt.bufPrint(&nb, "{s}.log", .{name}) catch return "";
    return s.tmp.dir.readFile(std.testing.io, f, buf) catch "";
}

/// `--cred PATTERN=PATH`, in `buf`.
fn credArg(buf: []u8, pattern: []const u8, path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}={s}", .{ pattern, path });
}

test "a --cred helper's headers are sent with the root's handshake [credential-helpers]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const tok = try credHelper(&s, "tok", "echo 'Authorization: Bearer t1'; echo 'X-Extra: two'");
    defer gpa.free(tok);
    var w: WsRoot = undefined;
    try w.start(e, .{ .require_header = "Authorization: Bearer t1" });
    defer w.stop();
    var cb: [256]u8 = undefined;
    try expectSameAsHostFlags(e, w.url(), "", &.{ "--cred", try credArg(&cb, "127.0.0.1", tok) }, &.{ "/bin/ls", "/" });
    try std.testing.expectEqualStrings("two", w.relay.header("X-Extra") orelse "");
    var lb: [1024]u8 = undefined;
    var want: [128]u8 = undefined;
    try expectIn(credLog(&s, "tok", &lb), try std.fmt.bufPrint(&want, "get {s} | -\n", .{w.url()}));
}

test "only the longest matching pattern's helper runs [credential-helpers]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const broad = try credHelper(&s, "broad", "echo 'Authorization: Bearer wrong'");
    defer gpa.free(broad);
    const narrow = try credHelper(&s, "narrow", "echo 'Authorization: Bearer right'");
    defer gpa.free(narrow);
    var w: WsRoot = undefined;
    try w.start(e, .{ .require_header = "Authorization: Bearer right" });
    defer w.stop();
    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    try expectSameAsHostFlags(e, w.url(), "", &.{ "--cred", try credArg(&b1, "127.0.0.1", broad), "--cred", try credArg(&b2, "127.0.0.1/9p", narrow) }, &.{ "/bin/ls", "/" });
    var lb: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("", credLog(&s, "broad", &lb));
}

test "a namespace-file ws:// mount runs the helper during replay [credential-helpers]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const tok = try credHelper(&s, "tok", "echo 'Authorization: Bearer t1'");
    defer gpa.free(tok);
    var w: WsRoot = undefined;
    try w.start(e, .{ .require_header = "Authorization: Bearer t1" });
    defer w.stop();
    var ns: [128]u8 = undefined;
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ns", .data = try std.fmt.bufPrint(&ns, "mount -c '{s}' /n\n", .{w.url()}) });
    var cb: [256]u8 = undefined;
    const r = try run(e, &.{ "--cwd", s.path, "--ns", s.ns(), "--cred", try credArg(&cb, "127.0.0.1", tok), "/bin/ls", "/n/rc/bin/lc" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("/n/rc/bin/lc\n", r.out);
    // A ws:// match warns that the credential isn't encrypted.
    try expectIn(r.err, "cross the network in plaintext");
    // Without the helper, the mount's handshake is refused.
    const no = try run(e, &.{ "--cwd", s.path, "--ns", s.ns(), "/bin/echo" });
    defer no.deinit();
    try std.testing.expectEqual(125, no.code);
    // A page's WebSocket reports no status.
    try expectIn(no.err, if (onWeb()) "connection failed" else "server answered 401 Unauthorized");
}

test "a 401 reruns the helper once with the response on stdin [credential-helpers]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    // A cached token first; a fresh one once told the last was refused.
    const tok = try credHelper(&s, "tok",
        \\if [ -n "$in" ]; then echo 'Authorization: Bearer fresh'; else echo 'Authorization: Bearer stale'; fi
    );
    defer gpa.free(tok);
    var w: WsRoot = undefined;
    try w.start(e, .{ .require_header = "Authorization: Bearer fresh" });
    defer w.stop();
    var cb: [256]u8 = undefined;
    const cred = try credArg(&cb, "127.0.0.1", tok);
    try expectSameAsHostFlags(e, w.url(), "", &.{ "--cred", cred }, &.{ "/bin/ls", "/" });
    var lb: [2048]u8 = undefined;
    var want: [256]u8 = undefined;
    // On the web host the failed response is only why the open failed.
    const refused = if (onWeb()) "connection failed" else "HTTP/1.1 401";
    try expectIn(credLog(&s, "tok", &lb), try std.fmt.bufPrint(&want, "get {0s} | -\nget {0s} | {1s}", .{ w.url(), refused }));

    // A server that refuses the fresh one too: one retry, then 125.
    w.relay.opts.require_header = "Authorization: Bearer never";
    try s.tmp.dir.deleteFile(std.testing.io, "tok.log");
    const r = try run(e, &.{ "--url", w.url(), "--cred", cred, "/bin/echo" });
    defer r.deinit();
    try std.testing.expectEqual(125, r.code);
    var want2: [256]u8 = undefined;
    try expectIn(r.err, try std.fmt.bufPrint(&want2, "root {s}: {s} (after credential helper retry)", .{ w.url(), if (onWeb()) "connection failed" else "server answered 401 Unauthorized" }));
    const log = credLog(&s, "tok", &lb);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, log, "\n") % 2);
    try std.testing.expectEqual(std.mem.count(u8, log, "| -\n"), std.mem.count(u8, log, refused));
}

test "a helper failure before start exits 125 with its stderr [credential-helpers]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const tok = try credHelper(&s, "tok", "echo 'tok: not logged in; run tok login' >&2; exit 1");
    defer gpa.free(tok);
    var w: WsRoot = undefined;
    try w.start(e, .{});
    defer w.stop();
    var cb: [256]u8 = undefined;
    const r = try run(e, &.{ "--url", w.url(), "--cred", try credArg(&cb, "127.0.0.1", tok), "/bin/echo" });
    defer r.deinit();
    try std.testing.expectEqual(125, r.code);
    var want: [256]u8 = undefined;
    try expectIn(r.err, try std.fmt.bufPrint(&want, "root {s}: credential helper tok: tok: not logged in; run tok login", .{w.url()}));
    // No handshake was made.
    try std.testing.expectEqual(@as(u32, 0), w.relay.accepted.load(.acquire));
}

test "a helper may not set reserved handshake headers [credential-helpers]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const tok = try credHelper(&s, "tok", "echo 'Authorization: Bearer s3cret'; echo 'Sec-WebSocket-Protocol: other'");
    defer gpa.free(tok);
    var w: WsRoot = undefined;
    try w.start(e, .{});
    defer w.stop();
    var cb: [256]u8 = undefined;
    const r = try run(e, &.{ "--url", w.url(), "--cred", try credArg(&cb, "127.0.0.1", tok), "/bin/echo" });
    defer r.deinit();
    try std.testing.expectEqual(125, r.code);
    try expectIn(r.err, "credential helper tok: Sec-WebSocket-Protocol changes the handshake");
    try std.testing.expect(std.mem.indexOf(u8, r.err, "s3cret") == null);
}

test "header= wins over a helper's header of the same name [credential-helpers]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const tok = try credHelper(&s, "tok", "echo 'Authorization: Bearer helper'; echo 'X-Extra: two'");
    defer gpa.free(tok);
    var w: WsRoot = undefined;
    try w.start(e, .{ .require_header = "Authorization: Bearer mine" });
    defer w.stop();
    var cb: [256]u8 = undefined;
    try expectSameAsHostFlags(e, w.url(), "header=authorization: Bearer mine", &.{ "--cred", try credArg(&cb, "127.0.0.1", tok) }, &.{ "/bin/ls", "/" });
    try std.testing.expectEqualStrings("two", w.relay.header("X-Extra") orelse "");
}

test "guest /net/ws conversations never run a helper [credential-helpers]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const tok = try credHelper(&s, "tok", "echo 'X-Token: t0k'");
    defer gpa.free(tok);
    var rl: wsrelay.Relay = undefined;
    try startEcho(&rl, .{ .require_header = "X-Token: t0k" });
    defer rl.stop();
    var cb: [256]u8 = undefined;
    var cmd: [512]u8 = undefined;
    const r = try run(e, &.{ "--cred", try credArg(&cb, "127.0.0.1", tok), "--rc", try rcWs(&cmd, rl.url(), "", "echo ok") });
    defer r.deinit();
    try std.testing.expect(r.code != 0);
    try expectIn(r.err, if (onWeb()) "connection failed" else "401");
    var lb: [256]u8 = undefined;
    try std.testing.expectEqualStrings("", credLog(&s, "tok", &lb));
}

test "--print shows the pattern and command, not headers [credential-helpers]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const tok = try credHelper(&s, "tok", "echo 'Authorization: Bearer s3cret'");
    defer gpa.free(tok);
    var cb: [256]u8 = undefined;
    var want: [256]u8 = undefined;
    const r = try run(e, &.{ "--url", "ws://127.0.0.1:1/9p", "--cred", try credArg(&cb, "127.0.0.1", tok), "--cred", "other.example=never", "--print", "ls" });
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try expectIn(r.out, try std.fmt.bufPrint(&want, "# ws://127.0.0.1:1/9p  cred 127.0.0.1={s}", .{tok}));
    try std.testing.expect(std.mem.indexOf(u8, r.out, "s3cret") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "other.example") == null);
    // The plan is made without running it.
    var lb: [256]u8 = undefined;
    try std.testing.expectEqualStrings("", credLog(&s, "tok", &lb));
}

test "a bad --cred or $H9CRED is a usage error [credential-helpers]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--cred", "*=cat", "/bin/echo" });
    defer r.deinit();
    try std.testing.expectEqual(2, r.code);
    const v = try runEnv(e, firstEngine(e), &.{"/bin/echo"}, &.{.{ "H9CRED", "wanix.io" }}, 30_000);
    defer v.deinit();
    try std.testing.expectEqual(2, v.code);
    try expectIn(v.err, "$H9CRED: each entry is PATTERN=COMMAND");
}

test "a .L.Z reconnect runs the helper again and sends the new token [credential-helpers]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    // A new token on every call, and the server takes only the newest.
    const tok = try credHelper(&s, "tok",
        \\n=$(( $(cat "$d/count" 2>/dev/null || echo 0) + 1 ))
        \\echo $n >"$d/count"
        \\echo "Authorization: Bearer t$n" >"$d/want"
        \\echo "Authorization: Bearer t$n"
    );
    defer gpa.free(tok);
    var d: DotlServer = undefined;
    try d.startShared(std.testing.io, dotlTree, "9P2000.L.Z");
    defer d.finish(std.testing.io);
    // The server applies the second write and goes before answering it.
    d.lock().drop_after_write = 1;
    d.unlock();
    const want = try std.fmt.allocPrint(gpa, "{s}/want", .{s.path});
    defer gpa.free(want);
    var rl: wsrelay.Relay = undefined;
    try rl.start(std.testing.io, 0, .{ .target_port = d.port(), .require_header_file = want });
    defer rl.stop();
    var ns: [128]u8 = undefined;
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ns", .data = try std.fmt.bufPrint(&ns, "mount -c '{s}' /n\n", .{rl.url()}) });
    var cb: [256]u8 = undefined;
    const script =
        \\{ echo one; echo two; echo three } >/n/usr/glenda/log
        \\cat /n/usr/glenda/log
        \\grep -h reconnects /net/dotl/*/status
    ;
    // One engine: the output depends on the server's state,
    // which a second engine's run wouldn't repeat.
    const r = try runOn(e, firstEngine(e), &.{ "--cwd", s.path, "--ns", s.ns(), "--cred", try credArg(&cb, "127.0.0.1", tok), "--rc", script }, null);
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("one\ntwo\nthree\n9P2000.L.Z reconnects 1\n", r.out);
    // The reconnect's handshake carried the token the helper made for it.
    var nb: [16]u8 = undefined;
    const n = std.mem.trim(u8, try s.tmp.dir.readFile(std.testing.io, "count", &nb), "\n");
    try std.testing.expect((try std.fmt.parseInt(u32, n, 10)) >= 2);
    var hb: [32]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&hb, "Bearer t{s}", .{n}), rl.header("Authorization") orelse "");
}

/// dotlTree, with /etc/motd owned by uid 4242.
fn identTree(s: *@import("dotlserver.zig").Server) !void {
    try dotlTree(s);
    (try s.add("etc/owned", .file, "x\n")).uid = 4242;
}

test "9P-Uid and 9P-User name files without --user-map [credential-helpers]" {
    const e = try env(@src());
    var d: DotlServer = undefined;
    try d.start(std.testing.io, identTree);
    defer d.finish(std.testing.io);
    var rl: wsrelay.Relay = undefined;
    try rl.start(std.testing.io, 0, .{ .target_port = d.port(), .accept_headers = "9P-Uid: 4242\r\n9P-User: progrium\r\n" });
    defer rl.stop();
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var ns: [128]u8 = undefined;
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ns", .data = try std.fmt.bufPrint(&ns, "mount -c '{s}' /n\n", .{rl.url()}) });
    const r = try run(e, &.{ "--cwd", s.path, "--ns", s.ns(), "--rc", "ls -l /n/etc/owned /n/etc/motd" });
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqual(0, r.code);
    // The server's uid for us is our name, and our attach sends it.
    try expectIn(r.out, " progrium 1000 ");
    try expectIn(r.out, " 1000     1000 ");
    try std.testing.expectEqual(@as(u32, 4242), d.n_uname);
}

test "--user-map wins over 9P-Uid [credential-helpers]" {
    const e = try env(@src());
    var d: DotlServer = undefined;
    try d.start(std.testing.io, identTree);
    defer d.finish(std.testing.io);
    var rl: wsrelay.Relay = undefined;
    try rl.start(std.testing.io, 0, .{ .target_port = d.port(), .accept_headers = "9P-Uid: 4242\r\n9P-User: progrium\r\n" });
    defer rl.stop();
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var ns: [128]u8 = undefined;
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ns", .data = try std.fmt.bufPrint(&ns, "mount -c '{s}' /n\n", .{rl.url()}) });
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "passwd", .data = "alice:x:4242:4242::/:/bin/sh\n" });
    const map = try std.fmt.allocPrint(gpa, "{s}/passwd", .{s.path});
    defer gpa.free(map);
    const r = try run(e, &.{ "--cwd", s.path, "--ns", s.ns(), "--user-map", map, "--rc", "ls -l /n/etc/owned" });
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqual(0, r.code);
    // Only the owner: the group, 1000, shows as the machine's user where
    // the host's uid is 1000 too, as for Ubuntu's first user.
    try expectIn(r.out, " alice ");
    try std.testing.expectEqualStrings("", r.err);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "progrium") == null);
}

// Mounts, binds, and a Plan 9 root (design/epoch-0/mounts.md).

test "--ns splits inline lines on ; outside quotes [mounts]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--ns", "bind /sys/lib /lib; bind '/sys/lib;x' /n;bind /rc/bin /n", "--rc", "ls -d /lib/acid /n/lc" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("/lib/acid\n/n/lc\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "--ns comments end at ; [mounts]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--ns", "# a comment; bind /sys/lib /lib # another; bind /rc/bin /n", "--rc", "ls -d /lib/acid /n/lc" });
    defer r.deinit();
    try std.testing.expectEqualStrings("/lib/acid\n/n/lc\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "--ns @FILE reads a host file, and repeated --ns replay in order [mounts]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ns", .data = "bind /sys/lib /n\n" });
    // The guest's cwd isn't the scratch directory, so only the host reads it.
    const r = try run(e, &.{ "--ns", s.ns(), "--ns", "bind /rc/bin /n", "--rc", "ls -d /n/lc; test -e /n/acid || echo replaced" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("/n/lc\nreplaced\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "--ns with a bare file name is exit 125 with a hint to use @ [mounts]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--ns", "ns", "/bin/echo" });
    defer r.deinit();
    try std.testing.expectEqual(125, r.code);
    try expectIn(r.err, "--ns: unknown command 'ns' (for a file, use --ns @ns)");
}

/// Two trees in the cwd for the union cases: `a` over `b`, each with a
/// file `f` and a directory `d`, and names only one has.
fn unionTrees(s: *Scratch) !void {
    try s.init();
    errdefer s.deinit();
    const d = s.tmp.dir;
    const io = std.testing.io;
    try d.createDirPath(io, "a/d");
    try d.createDirPath(io, "b/d/e");
    try d.writeFile(io, .{ .sub_path = "a/f", .data = "A\n" });
    try d.writeFile(io, .{ .sub_path = "b/f", .data = "B\n" });
    try d.writeFile(io, .{ .sub_path = "a/d/h", .data = "ah\n" });
    try d.writeFile(io, .{ .sub_path = "b/d/g", .data = "bg\n" });
    try d.writeFile(io, .{ .sub_path = "b/d/e/x", .data = "bx\n" });
}

const union_ns = "bind -r /mnt/term/cwd/b /n; bind -r -b /mnt/term/cwd/a /n";
const union_ns_c = "bind -r /mnt/term/cwd/b /n; bind -r -bc /mnt/term/cwd/a /n";

test "bind -r merges directories below the bind point [mounts]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try unionTrees(&s);
    defer s.deinit();
    const r = try run(e, &.{ "--cwd", s.path, "--ns", union_ns, "--rc", "cat /n/f /n/d/h /n/d/g /n/d/e/x; ls /n/d; cd /n/d/e && cat ../h" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("A\nah\nbg\nbx\n/n/d/e\n/n/d/g\n/n/d/h\nah\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "bind -r: creates go to the first -c member with the parent [mounts]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try unionTrees(&s);
    defer s.deinit();
    const r = try run(e, &.{ "--cwd", s.path, "--ns", union_ns_c, "--rc", "echo top > /n/new; echo deep > /n/d/new; mkdir /n/d/e/sub >[2]/dev/null || echo refused; echo more >> /n/d/g" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("refused\n", r.out);
    try std.testing.expect(s.exists("a/new"));
    try std.testing.expect(s.exists("a/d/new"));
    // b's directory e has no counterpart in a, and b doesn't take
    // creates, so a create under it is refused.
    try std.testing.expect(!s.exists("b/d/e/sub"));
    // A write goes to the member that holds the file.
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("bg\nmore\n", try s.tmp.dir.readFile(std.testing.io, "b/d/g", &buf));
    // Without a -c member, a create fails.
    const no = try run(e, &.{ "--cwd", s.path, "--ns", union_ns, "--rc", "echo x > /n/other" });
    defer no.deinit();
    try std.testing.expect(no.code != 0);
    try expectIn(no.err, "mounted directory forbids creation");
}

test "ns prints unions as bind -r lines that replay [mounts]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try unionTrees(&s);
    defer s.deinit();
    // A union from a namespace file, and one a guest makes with h9's bind.
    const r = try run(e, &.{ "--cwd", s.path, "--ns", union_ns, "--rc", "mkdir /tmp/x && bind -r /mnt/term/cwd/b /tmp/x && bind -rb /mnt/term/cwd/a /tmp/x && grep ' /(n|tmp/x)$' /proc/$pid/ns > /mnt/term/cwd/ns" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "bind -rb /mnt/term/cwd/b /n\nbind -rb /mnt/term/cwd/a /n\nbind -rb /mnt/term/cwd/b /tmp/x\nbind -rb /mnt/term/cwd/a /tmp/x\n",
        try s.tmp.dir.readFile(std.testing.io, "ns", &buf),
    );
    var nb: [std.fs.max_path_bytes + 1]u8 = undefined;
    const again = try run(e, &.{ "--cwd", s.path, "--ns", try std.fmt.bufPrint(&nb, "@{s}/ns", .{s.path}), "--rc", "cat /n/f /n/d/g /tmp/x/f /tmp/x/d/g" });
    defer again.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{again.err});
    try std.testing.expectEqualStrings("A\nbg\nA\nbg\n", again.out);
    try std.testing.expectEqual(0, again.code);
}

test "bind -r: removing an upper file uncovers the lower one [mounts]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try unionTrees(&s);
    defer s.deinit();
    const r = try run(e, &.{ "--cwd", s.path, "--ns", union_ns, "--rc", "rm /n/f && cat /n/f" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("B\n", r.out);
    try std.testing.expect(!s.exists("a/f"));
}

test "bind -c '#O' over a union copies up and whites out [mounts]" {
    const e = try env(@src());
    // The union merges with the root tree's /n, whose mount points
    // (/n/a, /n/dump, ...) depend on the tree, so only the names the
    // trees here make are checked.
    var s: Scratch = undefined;
    try unionTrees(&s);
    defer s.deinit();
    const r = try run(e, &.{ "--cwd", s.path, "--ns", union_ns ++ "; bind -c '#O' /n", "--rc", "echo more >> /n/d/g; cat /n/d/g; rm /n/f; test -e /n/f || echo gone; mkdir /n/z; ls /n | grep '^/n/[dfz]$'" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("bg\nmore\ngone\n/n/d\n/n/z\n", r.out);
    try std.testing.expectEqual(0, r.code);
    // Nothing reached the host.
    try std.testing.expect(s.exists("a/f"));
    try std.testing.expect(s.exists("b/f"));
    try std.testing.expect(!s.exists("a/z"));
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("bg\n", try s.tmp.dir.readFile(std.testing.io, "b/d/g", &buf));
}

/// `s` repeated `n` times, at compile time.
inline fn rep(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    comptime {
        var out: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
        const final = out;
        return &final;
    }
}

// The plan as a file (design/plan-format.md).

/// Writes `text` to the scratch file `name` and returns its host path.
fn scratchFile(s: *Scratch, buf: []u8, name: []const u8, text: []const u8) ![]const u8 {
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = text });
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ s.path, name });
}

test "h9 --plan <(h9 --rc 'ls /bin | wc -l' --print) prints what h9 --rc 'ls /bin | wc -l' prints (demo) [plan-format]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const direct = try run(e, &.{ "--rc", "ls /bin | wc -l" });
    defer direct.deinit();
    try std.testing.expectEqual(0, direct.code);
    var it = std.mem.tokenizeScalar(u8, e.engines, ',');
    while (it.next()) |engine| {
        const p = try runOn(e, engine, &.{ "--rc", "ls /bin | wc -l", "--print" }, null);
        defer p.deinit();
        try std.testing.expectEqual(0, p.code);
        // From a file, and from a pipe, as `<(...)` and `--plan -` give it.
        var pb: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const r = try runOn(e, engine, &.{ "--plan", try scratchFile(&s, &pb, "plan", p.out) }, null);
        defer r.deinit();
        try std.testing.expectEqualStrings(direct.out, r.out);
        try std.testing.expectEqual(0, r.code);
        const piped = try runOn(e, engine, &.{ "--plan", "-" }, p.out);
        defer piped.deinit();
        try std.testing.expectEqualStrings(direct.out, piped.out);
    }
}

test "--print output round-trips through --plan for every policy case [plan-format]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.createDirPath(std.testing.io, "out");
    try s.tmp.dir.createDirPath(std.testing.io, "data/secret");
    var ob: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var db: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var xb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const out = try std.fmt.bufPrint(&ob, "{s}/out", .{s.path});
    const data = try std.fmt.bufPrint(&db, "{s}/data", .{s.path});
    const secret = try std.fmt.bufPrint(&xb, "{s}/data/secret", .{s.path});
    const cases = [_][]const []const u8{
        &.{},
        &.{"--profile=tight"},
        &.{"--write=none"},
        &.{ "--write=scope", "--writable", out },
        &.{ "--write=ephemeral", "--writable", out },
        &.{"--net=disable"},
        &.{ "--net=enable", "--net-allow", "tcp!*.example.com!443", "--net-allow", "udp!10.0.0.53!53" },
        &.{ "--readable", data, "--read-deny", secret },
        &.{ "--memory", "512m", "--pids", "32", "--cpus", "2", "--timeout", "90s" },
        &.{ "--host-fs", "--no-guest-tools" },
        &.{ "--sandbox", s.path },
        &.{ "--gfx=headless", "--gfx-size", "640x480" },
        &.{ "--serve", "tcp!127.0.0.1!0", "--serve-net" },
        &.{ "--tmp", "/n/t", "--bind", "/n/t:/mnt/x:b", "--env", "A=two words", "--ns", "bind -a /mnt/x /n/t; mount -c '#s/none' /n/none" },
    };
    var it = std.mem.tokenizeScalar(u8, e.engines, ',');
    while (it.next()) |engine| for (cases) |flags| {
        var args: std.ArrayList([]const u8) = .empty;
        defer args.deinit(gpa);
        if (flags.len == 0 or !std.mem.eql(u8, flags[0], "--sandbox")) try args.appendSlice(gpa, &.{ "--cwd", s.path });
        try args.appendSlice(gpa, flags);
        try args.appendSlice(gpa, &.{ "--print", "echo" });
        const p = try runOn(e, engine, args.items, null);
        defer p.deinit();
        errdefer std.debug.print("{s}\n{s}\n", .{ p.out, p.err });
        try std.testing.expectEqual(0, p.code);
        var pb: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const r = try runOn(e, engine, &.{ "--plan", try scratchFile(&s, &pb, "plan", p.out), "--print" }, null);
        defer r.deinit();
        errdefer std.debug.print("{s}\n", .{r.err});
        // The plan, and what it compiles to, are the same.
        try std.testing.expectEqualStrings(p.out, r.out);
        try std.testing.expectEqual(0, r.code);
    };
}

test "a flag after --plan narrows, and a widening flag is exit 2 [plan-format]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.createDirPath(std.testing.io, "out");
    var other: Scratch = undefined;
    try other.init();
    defer other.deinit();
    var tb: [4096]u8 = undefined;
    const text = try std.fmt.bufPrint(&tb,
        \\dir {s}
        \\cwd {s} rw
        \\allow write {s}/out
        \\memory 256M
        \\net outbound
        \\run /bin/rc -c 'echo x >/mnt/term/cwd/out/f && cat /mnt/term/cwd/out/f'
        \\
    , .{ e.root, s.path, s.path });
    var pb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const plan = try scratchFile(&s, &pb, "plan", text);
    var ob: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const out = try std.fmt.bufPrint(&ob, "{s}/out", .{s.path});

    const ok = try run(e, &.{ "--plan", plan });
    defer ok.deinit();
    try std.testing.expectEqualStrings("x\n", ok.out);
    try s.tmp.dir.deleteFile(std.testing.io, "out/f");

    // Memory: lower, and not higher.
    const low = try run(e, &.{ "--plan", plan, "--memory", "64m", "--print" });
    defer low.deinit();
    try std.testing.expectEqual(0, low.code);
    try std.testing.expect(std.mem.indexOf(u8, low.out, "\nmemory 64M\n") != null);
    const high = try run(e, &.{ "--plan", plan, "--memory", "1g", "--print" });
    defer high.deinit();
    try std.testing.expectEqual(2, high.code);
    try std.testing.expect(std.mem.indexOf(u8, high.err, "memory 1G widens the plan's line 4: memory 256M") != null);

    // A writable path: made read-only, and not a new one.
    const ro = try run(e, &.{ "--plan", plan, "--readable", out });
    defer ro.deinit();
    try std.testing.expect(ro.code != 0);
    try std.testing.expect(!s.exists("out/f"));
    const wide = try run(e, &.{ "--plan", plan, "--writable", other.path, "--print" });
    defer wide.deinit();
    try std.testing.expectEqual(2, wide.code);
    try std.testing.expect(std.mem.indexOf(u8, wide.err, "widens the plan") != null);

    // The network: disabled, and not enabled.
    const off = try run(e, &.{ "--plan", plan, "--net", "disable", "--rc", "test -e /net/tcp || echo no net" });
    defer off.deinit();
    try std.testing.expectEqualStrings("no net\n", off.out);
    const on = try run(e, &.{ "--plan", plan, "--net", "enable", "--print" });
    defer on.deinit();
    try std.testing.expectEqual(2, on.code);
    try std.testing.expect(std.mem.indexOf(u8, on.err, "net enable widens the plan's line 5: net outbound") != null);
}

test "--plan names the line it can't read, and exits 2 [plan-format]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var tb: [4096]u8 = undefined;
    const text = try std.fmt.bufPrint(&tb, "dir {s}\n# a comment; with a semicolon\nfrobnicate 3\n", .{e.root});
    var pb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const r = try run(e, &.{ "--plan", try scratchFile(&s, &pb, "plan", text), "echo" });
    defer r.deinit();
    try std.testing.expectEqual(2, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "line 3: unknown line 'frobnicate'") != null);
}

test "a pinned root with a different index is refused [plan-format]" {
    // design/plan-format.md, "Pinned roots": b3= is the BLAKE3 hash of the
    // root's index. The index it pins runs, and an index with another
    // hash, or a server's own .fs/index, which h9 can't check before the
    // tree is used, is refused with exit 125.
    const e = try env(@src());
    var x: IndexRig = undefined;
    try x.start(e, false);
    defer x.stop();
    try x.index(e);
    const text = try x.mkindex(e);
    defer gpa.free(text);
    try x.write("x.h9index", text);
    const file = try std.fs.path.join(gpa, &.{ x.s.path, "x.h9index" });
    defer gpa.free(file);
    var h: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(text, &h, .{});
    const right = std.fmt.bytesToHex(h, .lower);
    var wrong = right;
    wrong[0] = if (wrong[0] == '0') '1' else '0';
    var ib: [std.Io.Dir.max_path_bytes + 160]u8 = undefined;

    const ok = try x.run_(e, &.{ try std.fmt.bufPrint(&ib, "index={s},b3={s}", .{ file, &right }), "--rc", "ls /lib/x" });
    defer ok.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{ok.err});
    try std.testing.expectEqual(0, ok.code);
    try std.testing.expectEqualStrings(x_listing, ok.out);

    const bad = try x.run_(e, &.{ try std.fmt.bufPrint(&ib, "index={s},b3={s}", .{ file, &wrong }), "--rc", "ls /lib/x" });
    defer bad.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{bad.err});
    try std.testing.expectEqual(125, bad.code);
    try std.testing.expectEqualStrings("", bad.out);
    var wb: [200]u8 = undefined;
    try expectIn(bad.err, try std.fmt.bufPrint(&wb, "b3=: its index has hash {s}…, not the pinned {s}…", .{ right[0..16], wrong[0..16] }));

    // The server's .fs/index is the same text, but h9 reads it only once
    // the tree is in use.
    var ub: [std.Io.Dir.max_path_bytes + 200]u8 = undefined;
    var db: [64]u8 = undefined;
    const srv = try run(e, &.{ "--url", try std.fmt.bufPrint(&ub, "{s}:/:b3={s}", .{ dialUrl(&db, x.relay.dial()), &right }), "--rc", "ls /lib/x" });
    defer srv.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{srv.err});
    try std.testing.expectEqual(125, srv.code);
    try std.testing.expectEqualStrings("", srv.out);
    try expectIn(srv.err, "b3=: pinned, but h9 checks only");

    // And from a plan, as --print writes it, on the engine it names.
    const pin = try std.fmt.bufPrint(&ub, "{s}:/:index={s},b3={s}", .{ dialUrl(&db, x.relay.dial()), file, &wrong });
    var it = std.mem.tokenizeScalar(u8, e.engines, ',');
    while (it.next()) |engine| {
        const p = try runOn(e, engine, &.{ "--url", pin, "--print", "true" }, null);
        defer p.deinit();
        try std.testing.expectEqual(0, p.code);
        try expectIn(p.out, "pinned b3=");
        var pb: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const from_plan = try runOn(e, engine, &.{ "--plan", try scratchFile(&x.s, &pb, "plan", p.out) }, null);
        defer from_plan.deinit();
        errdefer std.debug.print("plan:\n{s}\nstderr: {s}\n", .{ p.out, from_plan.err });
        try std.testing.expectEqual(125, from_plan.code);
        try expectIn(from_plan.err, "not the pinned");
    }
}
