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
const wsrelay = @import("wsrelay.zig");
const deadline = @import("deadline.zig");
const design = @import("design");

const gpa = std.testing.allocator;

const Env = struct {
    h9: []const u8,
    root: []const u8,
    backends: []const u8,
    /// H9_TEST_ARCH (-Darch), passed to h9 as --arch; null for the host's.
    arch: ?[]const u8,
};

var env_buf: [7][std.Io.Dir.max_path_bytes]u8 = undefined;

/// An environment variable, on every host (getPosix doesn't build on
/// Windows). Values live in one of seven slots, chosen by the caller.
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
    const backends = getenv(2, "H9_TEST_BACKENDS") orelse "auto";
    return .{ .h9 = h9, .root = root, .backends = backends, .arch = arch };
}

/// Cases the web host can't run (design/0012-browser-host.md), skipped
/// when H9_TEST_WEB is set (-Dweb): by name, those that need a host TTY,
/// POSIX signals, or what a page's WebSocket can't do; by tag, the
/// network's and 9P roots' proposals, since the web host has only
/// WebSockets.
const web_skips = [_][]const u8{
    "the discarded-changes notice is printed on a terminal and not otherwise",
    "--timeout stops a console read on a terminal at once",
    "Ctrl-C interrupts the foreground command and rc carries on",
    "a second Ctrl-C within a second tears the machine down",
    "rawon puts the host terminal in raw mode until exit",
    "closing the terminal posts hangup",
    "SIGTERM posts hangup",
    // A copy of h9-node alone has no h9.wasm beside it.
    "no root tree gives 125 for a guest program",
    // A 9P root over TCP.
    "a write to a 9P root under the default profile doesn't reach the server",
    // A page's WebSocket can't set headers or a CA, use a proxy, or ping;
    // the browser does those (design/0021-websocket-9p.md).
    "--root-header is sent, and @FILE reads headers from a file",
    "header in ctl is sent with the handshake",
    "wsmount mounts a ws:// URL with flags and headers",
    "--print elides a ws:// root's query and header values",
    "--root-ca with a ws:// root is a usage error",
    "a ws:// root goes through HTTP_PROXY with CONNECT, and NO_PROXY skips it",
    "a proxy answering 407 exits 125 with the status",
    "an idle ws:// root pings, and a server that stops answering fails it",
    // self-host's debugger cases that write to text or read acid's frames:
    // v86 hasn't the private text pages and breakpoint trap they need yet.
    "/proc/n/mem reads a variable and a write to text doesn't reach a sibling",
    "/proc/n/mem writes to text are fetched by the next run, including a rewrite of the same address",
    "a BRK posts sys: breakpoint",
    "acid attaches and prints registers and a stack trace",
    // Browsers and Node fail a handshake that offered subprotocols and got none.
    "a ws:// root works with a server that selects no subprotocol",
};
const web_skip_tags = [_][]const u8{ "5", "13" };

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
    return runInFor(e, args, stdin, 30_000);
}

/// Like `runIn`, with a harness timeout of `ms` instead of 30 s.
fn runInFor(e: Env, args: []const []const u8, stdin: ?[]const u8, ms: u32) !Result {
    var first: ?Result = null;
    errdefer if (first) |f| f.deinit();
    var it = std.mem.tokenizeScalar(u8, e.backends, ',');
    while (it.next()) |backend| {
        const r = try runOnFor(e, backend, args, stdin, ms);
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
    return runOnFor(e, backend, args, stdin, 30_000);
}

fn runOnFor(e: Env, backend: []const u8, args: []const []const u8, stdin: ?[]const u8, ms: u32) !Result {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ e.h9, "--backend", backend, "--root", e.root });
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
    // Without --builtin=off, the built-in root is used instead
    // (design/0087-builtin-root.md).
    for ([_][]const []const u8{ &.{ h9, "--builtin=off", "echo", "x" }, &.{ h9, "--builtin=off", "--rc", "echo x" } }) |argv| {
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

test "default profile: the cwd is writable and the root tree isn't written [baseline]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const r = try run(e, &.{ "--cwd", s.path, "touch", "f" });
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(s.exists("f"));
    // The write succeeds in the root's overlay (design/0011-overlay.md);
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
    try std.testing.expect(std.mem.indexOf(u8, r.out, "devmask:  #C #I #ℏ #U #b #i #m\n") != null);
}

test "--strict refuses what this build can't enforce [baseline]" {
    const e = try env(@src());
    // This build enforces every capability it knows, since
    // design/0011-overlay.md made --write=overlay enforceable, so there's
    // nothing left to refuse.
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
    // 124, as coreutils timeout (design/0033-exit-status.md).
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
    // (design/0032-guest-tools.md); the guest counts it.
    const h = try run(e, &.{ "--rc", "ls '#H/bin' | wc -l" });
    defer h.deinit();
    const in_h = try std.fmt.parseInt(usize, std.mem.trim(u8, h.out, " \n"), 10);
    const want = try countDir(e, bin) + try countDir(e, "rc/bin") + in_h;
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

/// The KVM vCPU limit `h9 --backend kvm --check` reports, or null when
/// KVM can't be used here.
fn kvmLimit(e: Env) !?u32 {
    const r = runOn(e, "kvm", &.{"--check"}, null) catch return null;
    defer r.deinit();
    const at = std.mem.indexOf(u8, r.out, "backend kvm: ok, ") orelse return null;
    var it = std.mem.tokenizeScalar(u8, r.out[at + "backend kvm: ok, ".len ..], ' ');
    return try std.fmt.parseInt(u32, it.next() orelse return null, 10);
}

test "--check reports kvm and its vCPU limit [16]" {
    const e = try env(@src());
    const n = try kvmLimit(e) orelse return error.SkipZigTest;
    try std.testing.expect(n > 8);
    const r = try runOn(e, "kvm", &.{"--check"}, null);
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "/bin/echo runs") != null);
}

test "auto uses kvm when /dev/kvm is usable [16]" {
    const e = try env(@src());
    _ = try kvmLimit(e) orelse return error.SkipZigTest;
    const r = try runOn(e, "auto", &.{"--check"}, null);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.out, "backend auto: ok (uses kvm)") != null);
    const w = try runOn(e, "auto", &.{ "/bin/echo", "hi" }, null);
    defer w.deinit();
    try std.testing.expectEqualStrings("hi\n", w.out);
    try std.testing.expectEqualStrings("", w.err);
}

test "without access to /dev/kvm, auto falls back to the emulator with a warning [16]" {
    const e = try env(@src());
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // Runs where this user can't open /dev/kvm (not in the kvm group).
    if (try kvmLimit(e) != null) return error.SkipZigTest;
    std.Io.Dir.accessAbsolute(std.testing.io, "/dev/kvm", .{}) catch return error.SkipZigTest;
    const k = try runOn(e, "kvm", &.{ "/bin/echo", "hi" }, null);
    defer k.deinit();
    try std.testing.expectEqual(125, k.code);
    try std.testing.expect(std.mem.indexOf(u8, k.err, "no access to /dev/kvm (is your user in the kvm group?)") != null);
    const r = try runOn(e, "auto", &.{ "/bin/echo", "hi" }, null);
    defer r.deinit();
    // Without the emulator built in, auto fails with the same reason.
    if (r.code == 125) return error.SkipZigTest;
    try std.testing.expectEqualStrings("hi\n", r.out);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "warning: no access to /dev/kvm (is your user in the kvm group?); using the emulator") != null);
}

test "more live processes than KVM's owned vCPUs run on the pool [16]" {
    const e = try env(@src());
    _ = try kvmLimit(e) orelse return error.SkipZigTest;
    // KVM's limit is capped by the file descriptors left: with 330 of
    // them, 74, so processes own 66 and the 80 alive at once in this
    // pipeline need the pool.
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "/bin/sh", "-c", "ulimit -n 330 && exec \"$@\"", "sh", e.h9, "--backend", "kvm", "--root", e.root });
    if (e.arch) |a| try argv.appendSlice(gpa, &.{ "--arch", a });
    try argv.appendSlice(gpa, &.{ "--rc", "c='echo deep'; for(i in `{seq 79}) c=$c^' | cat'; eval $c" });
    const r = try runProcess(argv.items, null);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    errdefer std.debug.print("{s}", .{r.stderr});
    try std.testing.expectEqualStrings("deep\n", r.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, r.term);
}

test "more processes over a machine's life than KVM's vCPU limit [16]" {
    const e = try env(@src());
    const n = try kvmLimit(e) orelse return error.SkipZigTest;
    var buf: [128]u8 = undefined;
    const script = try std.fmt.bufPrint(&buf, "for(i in `{{seq {d}}}) /bin/true; echo done", .{n + 16});
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ e.h9, "--backend", "kvm", "--root", e.root });
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
    if (std.mem.indexOf(u8, r.out, "backend whp: ok") == null) return error.SkipZigTest;
}

test "--check reports whp and its vCPU limit [17]" {
    const e = try env(@src());
    try requireWhp(e);
    const r = try runOn(e, "auto", &.{"--check"}, null);
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "backend whp: ok, 64 vCPUs") != null);
}

test "auto uses whp when the feature is enabled [17]" {
    const e = try env(@src());
    try requireWhp(e);
    const r = try runOn(e, "auto", &.{"--check"}, null);
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.out, "backend auto: ok (uses whp)") != null);
}

test "more live processes than WHP's owned vCPUs run on the pool [17]" {
    const e = try env(@src());
    try requireWhp(e);
    // 80 processes alive at once, past the 56 that own a vCPU.
    const r = try runOn(e, "whp", &.{ "--rc", "c='echo deep'; for(i in `{seq 79}) c=$c^' | cat'; eval $c" }, null);
    defer r.deinit();
    try std.testing.expectEqualStrings("deep\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "h9.exe starts and falls back to the emulator without the WHP feature [17]" {
    if (builtin.os.tag != .windows or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    const e = try env(@src());
    const r = try runOn(e, "auto", &.{"--check"}, null);
    defer r.deinit();
    // For a machine without the feature; with it, the cases above apply.
    if (std.mem.indexOf(u8, r.out, "backend whp: ok") != null) return error.SkipZigTest;
    try std.testing.expect(std.mem.indexOf(u8, r.out, "backend whp: no usable hypervisor (enable the Windows Hypervisor Platform feature") != null);
    if (std.mem.indexOf(u8, r.out, "backend emu: ok") != null) {
        try std.testing.expect(std.mem.indexOf(u8, r.out, "backend auto: ok (uses emu)") != null);
    }
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

// A root's default command (design/0081-default-command.md). The stock tree
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

test "--rc alone runs the root's rcmain.local, then stdin [81]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try defaultCommand(&s, "echo hello from the root\n");
    defer s.deinit();
    const r = try runIn(e, &.{ "--cwd", s.path, "--ns", "ns", "--rc" }, "echo from stdin $service\n");
    defer r.deinit();
    try std.testing.expectEqualStrings("hello from the root\nfrom stdin terminal\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "an exec in rcmain.local sets the exit status [81]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try defaultCommand(&s, "exec test -e /no/such/file\n");
    defer s.deinit();
    // The exec replaces the login rc, so stdin is never read.
    const r = try runIn(e, &.{ "--cwd", s.path, "--ns", "ns", "--rc" }, "echo not reached\n");
    defer r.deinit();
    try std.testing.expectEqualStrings("", r.out);
    try std.testing.expectEqual(1, r.code);
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/rcmain.local", .data = "exec echo hello from the root\n" });
    const ok = try runIn(e, &.{ "--cwd", s.path, "--ns", "ns", "--rc" }, "echo not reached\n");
    defer ok.deinit();
    try std.testing.expectEqualStrings("hello from the root\n", ok.out);
    try std.testing.expectEqual(0, ok.code);
}

test "--rc alone without rcmain.local is a plain rc [81]" {
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

test "--rc alone on a terminal is an interactive login rc [81]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try defaultCommand(&s, "echo hello from the root\n");
    defer s.deinit();
    var it = backendList(e);
    while (it.next()) |backend| {
        errdefer std.debug.print("backend {s}\n", .{backend});
        var t = try spawnTerm(e, backend, &.{ "--timeout", "60s", "--cwd", s.path, "--ns", "ns", "--rc" });
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

test "--rc 'cmd' doesn't read rcmain.local [81]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try defaultCommand(&s, "echo hello from the root\n");
    defer s.deinit();
    const r = try run(e, &.{ "--cwd", s.path, "--ns", "ns", "--rc", "echo cmd" });
    defer r.deinit();
    try std.testing.expectEqualStrings("cmd\n", r.out);
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

// The root's overlay (design/0011-overlay.md).

/// Fails if the root tree on the host has `rel`.
fn expectRootLacks(e: Env, rel: []const u8) !void {
    std.Io.Dir.cwd().access(std.testing.io, try hostPath(e.root, rel), .{}) catch return;
    std.debug.print("root tree has {s}\n", .{rel});
    return error.RootWasWritten;
}

test "a write to the root under the default profile succeeds and leaves the root tree unchanged [11]" {
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

test "a file written in /lib reads back and isn't in the root tree (demo) [11]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--rc", "echo hi > /lib/x && cat /lib/x" });
    defer r.deinit();
    try std.testing.expectEqualStrings("hi\n", r.out);
    try std.testing.expectEqual(0, r.code);
    try expectRootLacks(e, "lib/x");
}

test "mk install into the root works and leaves the root tree unchanged (demo) [11]" {
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

test "removing a root file hides it in the guest only [11]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--rc", "rm /lib/namespace && ls /lib/namespace; ls /lib | grep -c '^namespace$'" });
    defer r.deinit();
    try std.testing.expectEqualStrings("0\n", r.out);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "/lib/namespace") != null);
    try std.Io.Dir.cwd().access(std.testing.io, try hostPath(e.root, "lib/namespace"), .{});
}

test "$home exists and is writable when the root has no /usr/$user [11]" {
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

test "the cwd still writes the host under --write=overlay [11]" {
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

test "--write=scope keeps the root read-only [11]" {
    const e = try env(@src());
    for ([_][]const u8{ "--profile=default", "--profile=tight" }) |prof| {
        const r = try run(e, &.{ prof, "--write=scope", "--rc", "echo x > /lib/h9-overlay-scope" });
        defer r.deinit();
        try std.testing.expectEqual(1, r.code);
        try std.testing.expect(std.mem.indexOf(u8, r.err, "permission denied") != null);
    }
    try expectRootLacks(e, "lib/h9-overlay-scope");
}

test "--writable on the root writes the host, with no overlay [11]" {
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

test "--write=ephemeral overlays the root as well [11]" {
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

test "--strict --write=overlay is accepted [11]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--strict", "--write=overlay", "echo", "ok" });
    defer r.deinit();
    try std.testing.expectEqualStrings("ok\n", r.out);
    try std.testing.expectEqual(0, r.code);
    const p = try run(e, &.{ "--strict", "--print", "echo" });
    defer p.deinit();
    try std.testing.expectEqual(0, p.code);
    try std.testing.expect(std.mem.indexOf(u8, p.out, "fs.write.overlay") != null);
    try std.testing.expect(std.mem.indexOf(u8, p.out, "unenforced") == null);
}

test "--print output with the root overlay replays with --ns [11]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const p = try run(e, &.{ "--cwd", s.path, "--print", "echo" });
    defer p.deinit();
    try std.testing.expect(std.mem.indexOf(u8, p.out, "  bind -c '#O' / ") != null);
    try std.testing.expect(std.mem.indexOf(u8, p.out, "writes to the root are kept in memory") != null);
    const start = (std.mem.indexOf(u8, p.out, "namespace:\n") orelse return error.NoNamespace) + "namespace:\n".len;
    const end = std.mem.indexOfPos(u8, p.out, start, "access:\n") orelse p.out.len;
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ns", .data = p.out[start..end] });
    // Under --write=scope the root is read-only until the replay's overlay.
    const r = try run(e, &.{ "--cwd", s.path, "--write=scope", "--ns", "ns", "--rc", "echo x > /lib/h9-overlay-ns && cat /lib/h9-overlay-ns" });
    defer r.deinit();
    try std.testing.expectEqualStrings("x\n", r.out);
    try std.testing.expectEqual(0, r.code);
    try expectRootLacks(e, "lib/h9-overlay-ns");
}

test "the tight profile's root is an overlay [11]" {
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

test "a write to the root fails with file system full when memory runs out [11]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--memory", "32m", "--rc", "dd -if /dev/zero -of /lib/big -bs 4194304 -count 16; rm /lib/big; echo small > /lib/s && cat /lib/s" });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.err, "file system full") != null);
    try std.testing.expectEqualStrings("small\n", r.out);
    try expectRootLacks(e, "lib/big");
}

const notice = "h9: changes to the root under ";

test "the discarded-changes notice is printed on a terminal and not otherwise [11]" {
    const e = try env(@src());
    const script = "echo x > /lib/h9-notice; mkdir /sys/h9-notice; echo done";
    const r = try run(e, &.{ "--rc", script });
    defer r.deinit();
    try std.testing.expectEqualStrings("done\n", r.out);
    try std.testing.expect(std.mem.indexOf(u8, r.err, notice) == null);
    var it = backendList(e);
    while (it.next()) |backend| {
        errdefer std.debug.print("backend {s}\n", .{backend});
        var t = try spawnTerm(e, backend, &.{ "--rc", script });
        defer t.deinit();
        try t.expect(notice ++ "/lib, /sys were discarded (rerun with --writable \"$H9ROOT\" to keep them)", slow(20_000));
        try std.testing.expectEqual(0, try t.wait(slow(10_000)));
    }
}

test "changes only under $home, or only by the namespace builder, print no notice [11]" {
    const e = try env(@src());
    var it = backendList(e);
    while (it.next()) |backend| {
        errdefer std.debug.print("backend {s}\n", .{backend});
        // The builder may make $home; the guest writes only there.
        var t = try spawnTerm(e, backend, &.{ "--rc", "echo x > $home/h9-notice; echo done" });
        defer t.deinit();
        try t.expect("done", slow(20_000));
        try std.testing.expectEqual(0, try t.wait(slow(10_000)));
        t.drain(200) catch {};
        try std.testing.expect(std.mem.indexOf(u8, t.out.items, notice) == null);
    }
}

// Self-hosting (design/0010-self-host.md): the root's compilers and mk
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

test "7c and 7l build ls in the cwd, and it runs [10]" {
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

test "mk builds ls and cat with the stock cmd/mkfile, byte-identical to the root's [10]" {
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

test "mk builds a library into the cwd against the read-only root [10]" {
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

test "mk install into a read-only root fails with permission denied [10]" {
    const e = try env(@src());
    const src = try selfSrc(e);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    // --write=scope keeps the root read-only; the default profile's
    // overlay would take the install in memory (design/0011-overlay.md).
    const r = try runSelf(e, &s, src, &.{"--write=scope"}, "bind -bc /mnt/term/cwd /sys/src/cmd && cd /sys/src/cmd && mk cat.install >/dev/null", null);
    defer r.deinit();
    errdefer std.debug.print("stderr:\n{s}\n", .{r.err});
    try std.testing.expectEqual(1, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "permission denied") != null);
}

test "NPROC defaults to the vCPU limit, and --env overrides it [10]" {
    const e = try env(@src());
    const two = try run(e, &.{ "--cpus", "2", "--rc", "echo $NPROC" });
    defer two.deinit();
    try expectOk(two, "2\n");
    const set = try run(e, &.{ "--cpus", "2", "--env", "NPROC=5", "--rc", "echo $NPROC" });
    defer set.deinit();
    try expectOk(set, "5\n");
    // Without --cpus, the host's CPU count, capped by the backend's limit.
    const def = try run(e, &.{ "--rc", "echo $NPROC" });
    defer def.deinit();
    const n = try std.fmt.parseInt(u32, std.mem.trim(u8, def.out, "\n"), 10);
    try std.testing.expect(n >= 1 and n <= @max(1, try std.Thread.getCpuCount()));
}

test "parallel mk builds 7c repeatedly without hanging [10]" {
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

test "/proc/n/segment lists Stack first [10]" {
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
/// the pid.
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

test "/proc/n/regs and fpregs read a stopped process's registers [10]" {
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

test "/proc/n/mem reads a variable and a write to text doesn't reach a sibling [10]" {
    const e = try env(@src());
    // The parent and child share text until the write, which gives the
    // parent its own copy.
    const r = try runDebug(e,
        \\n=`{echo 16 i `{addr three} `{addr two} - p | dc}
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

test "/proc/n/mem writes to text are fetched by the next run, including a rewrite of the same address [10]" {
    const e = try env(@src());
    // target isn't sharing its text, so the writes go to the same pages
    // each time, and only the code-cache invalidation makes them seen.
    const r = try runDebug(e,
        \\n=`{echo 16 i `{addr three} `{addr two} - p | dc}
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

test "ctl hang stops a process at exec, and start runs it [10]" {
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

test "ctl stop stops a process spinning in guest code [10]" {
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

test "a BRK posts sys: breakpoint [10]" {
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

test "acid attaches and prints registers and a stack trace [10]" {
    const e = try env(@src());
    var tb: [16]u8 = undefined;
    const r = try runIn(e, &.{ "--timeout", slowTimeout(&tb, 60_000), "--rc", "sleep 5 & sleep 1; acid $apid; echo kill >/proc/$apid/ctl" }, "regs()\nstk()\n");
    defer r.deinit();
    errdefer std.debug.print("stdout:\n{s}\nstderr:\n{s}\n", .{ r.out, r.err });
    // acid prints its registers by name: R0 on arm64, AX on x86.
    const a = selfArch(e);
    const reg = if (std.mem.eql(u8, a.name, "arm64")) "R0\t0x" else "AX\t0x";
    try std.testing.expect(std.mem.indexOf(u8, r.out, reg) != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "sleep()+") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "main(argv=") != null);
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
        try std.testing.expectEqual(124, try t.wait(slow(1_500)));
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
        // 128 + SIGINT (design/0033-exit-status.md).
        try std.testing.expectEqual(130, try t.wait(slow(5_000)));
    }
}

test "a program killed by interrupt exits 130, with nothing printed [33]" {
    const e = try env(@src());
    var it = backendList(e);
    while (it.next()) |backend| {
        errdefer std.debug.print("backend {s}\n", .{backend});
        // rc execs sleep in place, so sleep is the first process.
        var t = try spawnTerm(e, backend, &.{ "--timeout", "60s", "--rc", "echo ready; sleep 1000" });
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

test "a program killed by hangup exits 129 and prints the note [33]" {
    const e = try env(@src());
    var buf: [512]u8 = undefined;
    const r = try run(e, &.{ "--timeout", "30s", "--rc", try noteToSleep(&buf, "hangup") });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(129, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "rc: hangup") != null);
}

test "a fault exits 139 and prints the note [33]" {
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

test "--timeout exits 124 [33]" {
    const e = try env(@src());
    // rc catches the hangup --timeout posts, so the machine is torn down
    // after the grace period: still a timeout, not "machine stopped".
    const r = try run(e, &.{ "--timeout", "200ms", "--rc", "fn sighup {}; while() sleep 1" });
    defer r.deinit();
    try std.testing.expectEqual(124, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "rc: h9: timeout") != null);
}

test "a note that isn't a signal exits 1 and prints it [33]" {
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
    var it = backendList(e);
    while (it.next()) |backend| {
        errdefer std.debug.print("backend {s}\n", .{backend});
        var t = try spawnTerm(e, backend, &.{ "--timeout", "60s", "--rc", ">[3]/dev/consctl { echo rawon >[1=3]; echo ready; read >/dev/null }" });
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

test "a run torn down after SIGTERM exits 143 [33]" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const e = try env(@src());
    var it = backendList(e);
    while (it.next()) |backend| {
        errdefer std.debug.print("backend {s}\n", .{backend});
        // rc ignores the hangup, so the machine is stopped after the grace
        // period, and the exit code names the host signal that started it.
        var t = try spawnTerm(e, backend, &.{ "--timeout", "60s", "--rc", "fn sighup {}; echo ready; while() sleep 1" });
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
// with the architecture's compiler and loader (7c and 7l on arm64) into
// a scratch directory given with --sandbox.

/// Builds sema.c into `s` as `sema`, on each backend.
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
    try std.testing.expectEqual(124, r.code);
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
        try deadline.waitReadable(c.socket.handle, deadline.limit_ms);
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

// devsrv, /srv, and mount (design/0008-devsrv.md). Mount points are made
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
        return s.startTree(e, null);
    }

    /// Serves the host tree `tree` instead, from a machine that still runs
    /// from the test root.
    fn startTree(s: *RootServer, e: Env, tree: ?[]const u8) !void {
        const io = std.testing.io;
        var probe = try listenLocal();
        s.port = probe.socket.address.getPort();
        probe.deinit(io);
        var listen_buf: [64]u8 = undefined;
        const listen = try std.fmt.bufPrint(&listen_buf, "tcp!127.0.0.1!{d}", .{s.port});
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        // The web host can't listen, so on it a native h9 serves
        // (H9_TEST_SERVER, from -Dweb -Demu=unicorn), or the case skips.
        if (onWeb()) {
            const server = getenv(6, "H9_TEST_SERVER") orelse return error.SkipZigTest;
            try argv.appendSlice(gpa, &.{ server, "--backend", "auto", "--root", e.root, "--net=enable" });
        } else try argv.appendSlice(gpa, &.{ e.h9, "--backend", firstBackend(e), "--root", e.root, "--net=enable" });
        if (e.arch) |a| try argv.appendSlice(gpa, &.{ "--arch", a });
        // The tree is the server's cwd, so it's /mnt/term/cwd wherever
        // it is on the host.
        var served: []const u8 = "/";
        if (tree) |t| {
            try argv.appendSlice(gpa, &.{ "--cwd", t });
            served = "/mnt/term/cwd";
        }
        try argv.appendSlice(gpa, &.{ "aux/listen1", "-t", listen, "/bin/exportfs", "-R", "-r", served });
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
    return expectSameAsHostWith(e, root, &.{}, args);
}

/// expectSameAsHost, with `root_args` (flags that need the 9P root, such
/// as --root-header) added to the run over the root only.
fn expectSameAsHostWith(e: Env, root: []const u8, root_args: []const []const u8, args: []const []const u8) !void {
    const host = try run(e, args);
    defer host.deinit();
    var with_root: std.ArrayList([]const u8) = .empty;
    defer with_root.deinit(gpa);
    try with_root.appendSlice(gpa, &.{ "--root", root });
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
    // Under the root's overlay (design/0011-overlay.md) nothing reaches
    // the server; under --write=scope its server decides.
    try std.testing.expect(std.mem.indexOf(u8, p.out, "writes to the 9P root go to its server") == null);
    const sp = try run(e, &.{ "--root", srv.dial(), "--write=scope", "--print", "ls" });
    defer sp.deinit();
    try std.testing.expect(std.mem.indexOf(u8, sp.out, "writes to the 9P root go to its server") != null);
    // The namespace section, replayed after the plan's own.
    const start = (std.mem.indexOf(u8, p.out, "namespace:\n") orelse return error.NoNamespace) + "namespace:\n".len;
    const end = std.mem.indexOfPos(u8, p.out, start, "\naccess:") orelse std.mem.indexOfPos(u8, p.out, start, "\ncaveats:") orelse return error.NoNamespace;
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ns", .data = p.out[start .. end + 1] });
    try expectSameAsHost(e, srv.dial(), &.{ "--cwd", s.path, "--ns", "ns", "/bin/ls", "/", "/bin/ls" });
}

test "a write to a 9P root under the default profile doesn't reach the server [11]" {
    const e = try env(@src());
    var srv: RootServer = undefined;
    try srv.start(e);
    defer srv.stop();
    // The server is a machine of its own, whose namespace outlives each
    // connection: a write that reached it would show in the next one.
    const r = try run(e, &.{ "--root", srv.dial(), "--rc", "echo hi > /lib/h9-overlay-9p && cat /lib/h9-overlay-9p" });
    defer r.deinit();
    try std.testing.expectEqualStrings("hi\n", r.out);
    try std.testing.expectEqual(0, r.code);
    const after = try run(e, &.{ "--root", srv.dial(), "--write=scope", "--rc", "test -e /lib/h9-overlay-9p && echo reached" });
    defer after.deinit();
    try std.testing.expectEqualStrings("", after.out);
    // Under --write=scope the write goes to the server, whose export is
    // read-only (exportfs -R).
    const sc = try run(e, &.{ "--root", srv.dial(), "--write=scope", "--rc", "echo x > /lib/h9-overlay-9p" });
    defer sc.deinit();
    try std.testing.expectEqual(1, sc.code);
    try std.testing.expect(std.mem.indexOf(u8, sc.err, "read only") != null);
    try expectRootLacks(e, "lib/h9-overlay-9p");
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
    // The web host also masks #I, having no sockets.
    const want = if (getenv(3, "H9_TEST_WEB") != null) "devmask:  #C #I #H #U #b #i #m\n" else "devmask:  #C #H #U #b #i #m\n";
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

// Host commands: #C, unmasked by --host-cmd, and hcmd, h9's command that
// drives it. They're built in only with -Dhost-cmd, which sets
// H9_TEST_HOST_CMD; the cases skip otherwise. The host side is sh, so
// they skip on Windows too.

fn needHostCmd() !void {
    if (getenv(3, "H9_TEST_HOST_CMD") == null) return error.SkipZigTest;
}

test "without -Dhost-cmd, --host-cmd is refused and #C and hcmd are absent [baseline]" {
    if (getenv(3, "H9_TEST_HOST_CMD") != null) return error.SkipZigTest;
    const e = try env(@src());
    const r = try run(e, &.{ "--host-cmd", "--print", "ls" });
    defer r.deinit();
    try std.testing.expectEqual(2, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "-Dhost-cmd") != null);
    const c = try run(e, &.{ "ls", "#C" });
    defer c.deinit();
    try std.testing.expectEqual(1, c.code);
    const h = try run(e, &.{ "--rc", "test -e /bin/hcmd || echo absent" });
    defer h.deinit();
    try std.testing.expectEqualStrings("absent\n", h.out);
}

test "--host-cmd unmasks #C and says so in the plan [baseline]" {
    try needHostCmd();
    const e = try env(@src());
    const m = try run(e, &.{ "ls", "#C" });
    defer m.deinit();
    try std.testing.expectEqual(1, m.code);
    try std.testing.expect(std.mem.indexOf(u8, m.err, "mount/attach disallowed") != null);
    const p = try run(e, &.{ "--host-cmd", "--print", "ls" });
    defer p.deinit();
    try std.testing.expect(std.mem.indexOf(u8, p.out, "devmask:  #U\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, p.out, "#C runs host commands with the host user's rights") != null);
}

test "#C runs a host command and reports its exit status [baseline]" {
    try needHostCmd();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const e = try env(@src());
    // The wait file is opened before exec: devcmd keeps the status only
    // for an open one. It's one message with no newline, so dd reads it.
    const r = try run(e, &.{
        "--host-cmd", "--rc",
        \\<>[3]'#C/cmd/clone' {
        \\    n=`{read <[0=3]}
        \\    d='#C/cmd/'$n
        \\    <[4]$d/wait {
        \\        echo 'exec sh -c ''echo out; echo err >&2; exit 3''' >[1=3]
        \\        cat $d/data $d/stderr
        \\        dd -bs 512 -count 1 -quiet 1 <[0=4]
        \\    }
        \\}
    });
    defer r.deinit();
    errdefer std.debug.print("out: {s}\nerr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(std.mem.startsWith(u8, r.out, "out\nerr\n"));
    try std.testing.expect(std.mem.endsWith(u8, r.out, " 0 0 0 'exit: 3'"));
}

test "hcmd passes stdin, output, errors, arguments and the exit status [baseline, 32]" {
    try needHostCmd();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const e = try env(@src());
    const r = try run(e, &.{ "--host-cmd", "hcmd", "sh", "-c", "echo out; echo err >&2; exit 3" });
    defer r.deinit();
    try std.testing.expectEqual(3, r.code);
    try std.testing.expectEqualStrings("out\n", r.out);
    try std.testing.expectEqualStrings("err\n", r.err);
    const in = try runIn(e, &.{ "--host-cmd", "hcmd", "tr", "a-z", "A-Z" }, "from the guest\n");
    defer in.deinit();
    try std.testing.expectEqual(0, in.code);
    try std.testing.expectEqualStrings("FROM THE GUEST\n", in.out);
    const a = try run(e, &.{ "--host-cmd", "hcmd", "printf", "[%s]", "a  b", "it's", "" });
    defer a.deinit();
    try std.testing.expectEqualStrings("[a  b][it's][]", a.out);
    const n = try runIn(e, &.{ "--host-cmd", "hcmd", "-n", "cat" }, "not read\n");
    defer n.deinit();
    try std.testing.expectEqual(0, n.code);
    try std.testing.expectEqualStrings("", n.out);
}

test "hcmd runs in the host directory the guest's comes from [baseline, 32]" {
    try needHostCmd();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.createDirPath(std.testing.io, "sub");
    var want: [std.Io.Dir.max_path_bytes + 8]u8 = undefined;
    const sub = try std.fmt.bufPrint(&want, "{s}/sub", .{s.path});
    const r = try run(e, &.{ "--host-cmd", "--cwd", s.path, "--rc", "cd sub && hcmd pwd -P" });
    defer r.deinit();
    errdefer std.debug.print("err: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings(sub, std.mem.trimEnd(u8, r.out, "\n"));
    const d = try run(e, &.{ "--host-cmd", "hcmd", "-d", sub, "pwd", "-P" });
    defer d.deinit();
    try std.testing.expectEqualStrings(sub, std.mem.trimEnd(u8, d.out, "\n"));
}

test "hcmd without --host-cmd says how to turn host commands on [32]" {
    try needHostCmd();
    const e = try env(@src());
    const r = try run(e, &.{ "hcmd", "true" });
    defer r.deinit();
    try std.testing.expectEqual(1, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "--host-cmd") != null);
}

test "a hangup kills hcmd's host command [baseline, 32]" {
    try needHostCmd();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var t: [16]u8 = undefined;
    const r = try run(e, &.{ "--host-cmd", "--cwd", s.path, "--timeout", slowTimeout(&t, 300), "hcmd", "sh", "-c", "sleep 2; touch late" });
    defer r.deinit();
    try std.testing.expectEqual(124, r.code);
    try std.testing.io.sleep(.fromMilliseconds(3000), .awake);
    try std.testing.expect(!s.exists("late"));
}

test "a machine's host commands die with it [baseline]" {
    try needHostCmd();
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    // Started in the background and left running when rc exits.
    const bg = try run(e, &.{ "--host-cmd", "--cwd", s.path, "--rc", "hcmd sh -c 'sleep 1; touch bg' & sleep 0" });
    defer bg.deinit();
    try std.testing.expectEqual(0, bg.code);
    // Read with no handler to kill it: the reader waits in a host read
    // that the timeout's hangup can't interrupt.
    var t: [16]u8 = undefined;
    const raw = try run(e, &.{
        "--host-cmd", "--cwd", s.path, "--timeout", slowTimeout(&t, 300), "--rc",
        \\<>[3]'#C/cmd/clone' {
        \\    echo 'exec sh -c ''sleep 3; touch raw''' >[1=3]
        \\    cat '#C/cmd/'`{read <[0=3]}^/data
        \\}
    });
    defer raw.deinit();
    try std.testing.expectEqual(1, raw.code);
    try std.testing.io.sleep(.fromMilliseconds(2000), .awake);
    try std.testing.expect(!s.exists("bg"));
    try std.testing.expect(!s.exists("raw"));
}

// 9P over WebSocket (design/0021-websocket-9p.md). The server is 9p-roots'
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

/// Runs `h9 args...` on `backend` with `vars` (pairs of name and value)
/// added to the environment, and a timeout of `ms`.
fn runEnv(e: Env, backend: []const u8, args: []const []const u8, vars: []const [2][]const u8, ms: u32) !Result {
    var map = try std.testing.environ.createMap(gpa);
    defer map.deinit();
    for (vars) |v| try map.put(v[0], v[1]);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ e.h9, "--backend", backend, "--root", e.root });
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

test "a ws:// root runs /bin/ls [21]" {
    const e = try env(@src());
    var w: WsRoot = undefined;
    try w.start(e, .{});
    defer w.stop();
    try expectSameAsHost(e, w.url(), &.{ "/bin/ls", "/", "/bin/ls" });
    try std.testing.expectEqualStrings("/9p", w.relay.target());
}

test "rc pipelines and exec run from a ws:// root [21]" {
    const e = try env(@src());
    var w: WsRoot = undefined;
    try w.start(e, .{});
    defer w.stop();
    try expectSameAsHost(e, w.url(), &.{ "--rc", "ls /bin | grep -c '/cat$'; echo a b c | wc -w; exec /bin/echo done" });
}

test "a ws:// root works when the server splits and coalesces 9P messages [21]" {
    const e = try env(@src());
    for ([_]wsrelay.Options{ .{ .split = true }, .{ .coalesce = true }, .{ .split = true, .coalesce = true } }) |o| {
        var w: WsRoot = undefined;
        try w.start(e, o);
        defer w.stop();
        try expectSameAsHost(e, w.url(), &.{ "--rc", "ls / /bin/ls; cat /lib/namespace | wc -l" });
    }
}

test "a ws:// root works with a server that selects no subprotocol [21]" {
    const e = try env(@src());
    var w: WsRoot = undefined;
    try w.start(e, .{ .subprotocol = false });
    defer w.stop();
    try expectSameAsHost(e, w.url(), &.{ "/bin/ls", "/" });
}

test "--root-header is sent, and @FILE reads headers from a file [21]" {
    const e = try env(@src());
    var w: WsRoot = undefined;
    try w.start(e, .{ .require_header = "Authorization: Bearer s3cret" });
    defer w.stop();
    try expectSameAsHostWith(e, w.url(), &.{ "--root-header", "Authorization: Bearer s3cret" }, &.{ "/bin/ls", "/" });
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "headers", .data = "Authorization: Bearer s3cret\n\nX-Other: two\n" });
    const file = try std.fmt.allocPrint(gpa, "@{s}/headers", .{s.path});
    defer gpa.free(file);
    try expectSameAsHostWith(e, w.url(), &.{ "--root-header", file }, &.{ "/bin/ls", "/" });
    try std.testing.expectEqualStrings("two", w.relay.header("X-Other") orelse "");
    // Without it, the server refuses the handshake.
    const r = try run(e, &.{ "--root", w.url(), "/bin/echo" });
    defer r.deinit();
    try std.testing.expectEqual(125, r.code);
    try expectIn(r.err, "server answered 401 Unauthorized");
}

test "a handshake answered with 401 exits 125 with the status [21]" {
    const e = try env(@src());
    var rl: wsrelay.Relay = undefined;
    try startEcho(&rl, .{ .status = 401 });
    defer rl.stop();
    const r = try run(e, &.{ "--root", rl.url(), "/bin/echo" });
    defer r.deinit();
    try std.testing.expectEqual(125, r.code);
    var want: [128]u8 = undefined;
    // A browser doesn't say why a WebSocket failed.
    const why = if (onWeb()) "connection failed" else "server answered 401 Unauthorized";
    try expectIn(r.err, try std.fmt.bufPrint(&want, "root {s}: {s}", .{ rl.url(), why }));
}

test "an unreachable ws:// root exits 125 [21]" {
    const e = try env(@src());
    var probe = try listenLocal();
    const port = probe.socket.address.getPort();
    probe.deinit(std.testing.io);
    var buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&buf, "ws://127.0.0.1:{d}/9p", .{port});
    const r = try run(e, &.{ "--root", url, "/bin/echo" });
    defer r.deinit();
    try std.testing.expectEqual(125, r.code);
    var want: [128]u8 = undefined;
    const why = if (onWeb()) "connection failed" else "connection refused";
    try expectIn(r.err, try std.fmt.bufPrint(&want, "root {s}: {s}", .{ url, why }));
}

test "a server close makes guest file operations fail [21]" {
    const e = try env(@src());
    var it = backendList(e);
    while (it.next()) |backend| {
        errdefer std.debug.print("backend {s}\n", .{backend});
        var w: WsRoot = undefined;
        try w.start(e, .{});
        defer w.stop();
        var t = try spawnTerm(e, backend, &.{ "--root", w.url(), "--timeout", "60s", "--rc", "echo ready; sleep 2; /bin/echo after" });
        defer t.deinit();
        try t.expect("ready", slow(10_000));
        w.relay.hangupAll();
        try std.testing.expect(try t.wait(slow(20_000)) != 0);
    }
}

test "an idle ws:// root pings, and a server that stops answering fails it [21]" {
    const e = try env(@src());
    // The keepalive pings after 30 s without a frame and fails the
    // connection 30 s after that, so this case takes over a minute.
    {
        var w: WsRoot = undefined;
        try w.start(e, .{});
        defer w.stop();
        const r = try runEnv(e, firstBackend(e), &.{ "--root", w.url(), "--rc", "sleep 40; /bin/echo still" }, &.{}, 90_000);
        defer r.deinit();
        errdefer std.debug.print("stderr: {s}\n", .{r.err});
        try std.testing.expectEqual(0, r.code);
        try std.testing.expectEqualStrings("still\n", r.out);
        try std.testing.expect(w.relay.pings.load(.acquire) >= 1);
    }
    {
        var w: WsRoot = undefined;
        try w.start(e, .{ .no_pong = true });
        defer w.stop();
        const r = try runEnv(e, firstBackend(e), &.{ "--root", w.url(), "--rc", "sleep 70; /bin/echo still" }, &.{}, 120_000);
        defer r.deinit();
        try std.testing.expect(r.code != 0);
        try std.testing.expect(std.mem.indexOf(u8, r.out, "still") == null);
        try std.testing.expect(w.relay.pings.load(.acquire) >= 1);
    }
}

test "a ws:// root goes through HTTP_PROXY with CONNECT, and NO_PROXY skips it [21]" {
    const e = try env(@src());
    var w: WsRoot = undefined;
    try w.start(e, .{});
    defer w.stop();
    var p: wsrelay.Proxy = undefined;
    try p.start(std.testing.io, null);
    const via = try runEnv(e, firstBackend(e), &.{ "--root", w.url(), "/bin/ls", "/bin/ls" }, &.{.{ "HTTP_PROXY", p.url() }}, 30_000);
    defer via.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{via.err});
    try std.testing.expectEqual(0, via.code);
    try std.testing.expectEqualStrings("/bin/ls\n", via.out);
    try std.testing.expectEqual(1, p.connects.load(.acquire));
    const direct = try runEnv(e, firstBackend(e), &.{ "--root", w.url(), "/bin/ls", "/bin/ls" }, &.{ .{ "http_proxy", p.url() }, .{ "NO_PROXY", "localhost,127.0.0.1" } }, 30_000);
    defer direct.deinit();
    try std.testing.expectEqual(0, direct.code);
    try std.testing.expectEqual(1, p.connects.load(.acquire));
}

test "a proxy answering 407 exits 125 with the status [21]" {
    const e = try env(@src());
    var p: wsrelay.Proxy = undefined;
    try p.start(std.testing.io, 407);
    const r = try runEnv(e, firstBackend(e), &.{ "--root", "ws://127.0.0.1:1/9p", "/bin/echo" }, &.{.{ "HTTP_PROXY", p.url() }}, 30_000);
    defer r.deinit();
    try std.testing.expectEqual(125, r.code);
    try expectIn(r.err, "root ws://127.0.0.1:1/9p: proxy answered 407 Proxy Authentication Required");
}

test "a /net/ws connect ignores HTTP_PROXY [21]" {
    const e = try env(@src());
    var rl: wsrelay.Relay = undefined;
    try startEcho(&rl, .{});
    defer rl.stop();
    var p: wsrelay.Proxy = undefined;
    try p.start(std.testing.io, null);
    var cmd: [512]u8 = undefined;
    const r = try runEnv(e, firstBackend(e), &.{ "--rc", try rcWs(&cmd, rl.url(), "", "echo hi >/net/ws/$n/data && read </net/ws/$n/data") }, &.{.{ "HTTP_PROXY", p.url() }}, 30_000);
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("hi\n", r.out);
    try std.testing.expectEqual(0, p.connects.load(.acquire));
}

test "--root-ca with a ws:// root is a usage error [21]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ca.pem", .data = "" });
    const ca = try std.fs.path.join(gpa, &.{ s.path, "ca.pem" });
    defer gpa.free(ca);
    const r = try run(e, &.{ "--root", "ws://127.0.0.1:1/9p", "--root-ca", ca, "/bin/echo" });
    defer r.deinit();
    try std.testing.expectEqual(2, r.code);
    try expectIn(r.err, "--root-ca needs a wss:// root");
}

test "a note interrupts a read waiting on a ws:// root [21]" {
    const e = try env(@src());
    var it = backendList(e);
    while (it.next()) |backend| {
        errdefer std.debug.print("backend {s}\n", .{backend});
        var w: WsRoot = undefined;
        try w.start(e, .{});
        defer w.stop();
        var t = try spawnTerm(e, backend, &.{ "--root", w.url(), "--timeout", "60s", "rc", "-i" });
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

test "a namespace file mounts a ws:// URL [21]" {
    const e = try env(@src());
    var w: WsRoot = undefined;
    try w.start(e, .{});
    defer w.stop();
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var ns: [128]u8 = undefined;
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ns", .data = try std.fmt.bufPrint(&ns, "mount -c '{s}?k=v' /n\n", .{w.url()}) });
    const r = try run(e, &.{ "--cwd", s.path, "--ns", "ns", "/bin/ls", "/n/rc/bin/lc" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("/n/rc/bin/lc\n", r.out);
    try std.testing.expectEqualStrings("/9p?k=v", w.relay.target());
    // Under --write=none, the mount can't be kept read-only.
    const none = try run(e, &.{ "--cwd", s.path, "--ns", "ns", "--write=none", "/bin/echo" });
    defer none.deinit();
    try std.testing.expectEqual(125, none.code);
    try expectIn(none.err, "--write=none can't be enforced on a WebSocket mount");
}

test "a host-made stream isn't reachable through /net/ws or an attach spec [21]" {
    const e = try env(@src());
    var w: WsRoot = undefined;
    try w.start(e, .{});
    defer w.stop();
    const r = try run(e, &.{ "--root", w.url(), "--rc", "ls /net/ws; for(i in 0 1 2 256 257) ls '#ℏ'$i >[2]/dev/null && echo reached $i; echo done" });
    defer r.deinit();
    try std.testing.expectEqualStrings("/net/ws/clone\ndone\n", r.out);
}

test "the guest connects /net/ws and mounts its data [21]" {
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

test "wsmount mounts a ws:// URL with flags and headers [21, 32]" {
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

test "a /net/ws conversation reports its URL and status [21]" {
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

test "a guest WebSocket mount can be posted to /srv and mounted again [21]" {
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

test "header in ctl is sent with the handshake [21]" {
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

test "text writes are sent as text messages and text reads return one message each [21]" {
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

test "a text read with a short buffer fails and leaves the message queued [21]" {
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

test "a text write that isn't valid utf-8 fails and sends nothing [21]" {
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

test "text from the server doesn't appear on data, nor binary on text [21]" {
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

test "a ws:// root fails on a text message from the server [21]" {
    const e = try env(@src());
    var w: WsRoot = undefined;
    try w.start(e, .{ .send_text = "hello" });
    defer w.stop();
    const r = try run(e, &.{ "--root", w.url(), "/bin/echo" });
    defer r.deinit();
    try std.testing.expectEqual(125, r.code);
    var want: [128]u8 = undefined;
    try expectIn(r.err, try std.fmt.bufPrint(&want, "root {s}: ", .{w.url()}));
}

test "--net=disable leaves /net/ws unbound and #ℏ masked [21]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--net=disable", "--rc", "ls /net/ws >[2]/dev/null || echo unbound; ls '#ℏ' >[2]/dev/null || echo masked" });
    defer r.deinit();
    try std.testing.expectEqualStrings("unbound\nmasked\n", r.out);
}

test "--net-allow refuses a /net/ws connect to a host it doesn't cover [21]" {
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

test "--net-allow refuses a name before it's resolved [21]" {
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

test "a /net/ws connect to a link-local address is refused without patterns [21]" {
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

test "a note interrupts a /net/ws connect [21]" {
    const e = try env(@src());
    // It takes the TCP connection but never answers the handshake.
    var srv = try listenLocal();
    defer srv.deinit(std.testing.io);
    var url: [64]u8 = undefined;
    var cmd: [512]u8 = undefined;
    const c = try rcWs(&cmd, try std.fmt.bufPrint(&url, "ws://127.0.0.1:{d}/", .{srv.socket.address.getPort()}), "", "echo connected");
    var it = backendList(e);
    while (it.next()) |backend| {
        errdefer std.debug.print("backend {s}\n", .{backend});
        var t = try spawnTerm(e, backend, &.{ "--timeout", "60s", "rc", "-i" });
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

test "a machine can't open more than 32 conversations [21]" {
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

test "--print elides a ws:// root's query and header values [21]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--root", "ws://127.0.0.1:1/9p?token=s3cret", "--root-header", "Authorization: Bearer s3cret", "--print", "ls" });
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try expectIn(r.out, "# ws://127.0.0.1:1/9p?…  (Authorization: …)");
    try expectIn(r.out, "bind -a '#ℏ' /net");
    try std.testing.expect(std.mem.indexOf(u8, r.out, "s3cret") == null);
}

test "--write=none with a ws:// root is a usage error [21]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--root", "ws://127.0.0.1:1/9p", "--write=none", "/bin/echo" });
    defer r.deinit();
    try std.testing.expectEqual(2, r.code);
    try expectIn(r.err, "--write=none can't be enforced on a WebSocket root");
}

// schemeless-roots: a --root or $H9ROOT without a scheme.

/// Runs `h9 args...` on the first backend without the case's --root, in
/// `cwd` (if not null), with `vars` added to the environment.
fn runBare(e: Env, cwd: ?[]const u8, args: []const []const u8, vars: []const [2][]const u8) !Result {
    var map = try std.testing.environ.createMap(gpa);
    defer map.deinit();
    for (vars) |v| try map.put(v[0], v[1]);
    var h9_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.cwd().realPathFile(std.testing.io, e.h9, &h9_buf);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ h9_buf[0..n], "--backend", firstBackend(e) });
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

test "a schemeless --root prints as its wss:// URL [76]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--root", "fs.example.com/9p?token=s3cret", "--print", "ls" });
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try expectIn(r.out, "# wss://fs.example.com/9p?…");
    const b = try run(e, &.{ "--root", "fs.example.com", "--print", "ls" });
    defer b.deinit();
    try std.testing.expectEqual(0, b.code);
    try expectIn(b.out, "# wss://fs.example.com/");
}

test "a schemeless loopback root is ws:// and runs /bin/ls [76]" {
    const e = try env(@src());
    var w: WsRoot = undefined;
    try w.start(e, .{});
    defer w.stop();
    const url = w.url();
    try std.testing.expect(std.mem.startsWith(u8, url, "ws://127.0.0.1:"));
    try expectSameAsHost(e, url["ws://".len..], &.{ "/bin/ls", "/" });
}

test "an existing directory with a dotted name is a host root, not a URL [76]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try std.Io.Dir.cwd().realPathFile(std.testing.io, e.root, &root_buf);
    try s.tmp.dir.symLink(std.testing.io, root_buf[0..n], "fs.example.com", .{ .is_directory = true });
    const r = try runBare(e, s.path, &.{ "--root", "fs.example.com", "--print", "ls" }, &.{});
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "wss://") == null);
    const echo = try runBare(e, s.path, &.{ "--root", "fs.example.com", "/bin/echo", "hi" }, &.{});
    defer echo.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{echo.err});
    try std.testing.expectEqual(0, echo.code);
    try std.testing.expectEqualStrings("hi\n", echo.out);
}

test "an unreachable schemeless root exits 125 naming both readings [76]" {
    const e = try env(@src());
    var probe = try listenLocal();
    const port = probe.socket.address.getPort();
    probe.deinit(std.testing.io);
    var buf: [64]u8 = undefined;
    const arg = try std.fmt.bufPrint(&buf, "127.0.0.1:{d}/9p", .{port});
    const r = try run(e, &.{ "--root", arg, "/bin/echo" });
    defer r.deinit();
    try std.testing.expectEqual(125, r.code);
    var want: [160]u8 = undefined;
    const why = if (onWeb()) "connection failed" else "connection refused";
    try expectIn(r.err, try std.fmt.bufPrint(&want, "root ws://{s}: {s}", .{ arg, why }));
    try expectIn(r.err, try std.fmt.bufPrint(&want, "root {s}: no such path, so h9 read it as ws://{s}", .{ arg, arg }));
}

test "$H9ROOT is read as a schemeless root [76]" {
    const e = try env(@src());
    const r = try runBare(e, null, &.{ "--print", "ls" }, &.{.{ "H9ROOT", "fs.example.com/9p" }});
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try expectIn(r.out, "# wss://fs.example.com/9p");
}

test "--root-ca is accepted with a schemeless root [76]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ca.pem", .data = "" });
    const ca = try std.fs.path.join(gpa, &.{ s.path, "ca.pem" });
    defer gpa.free(ca);
    const r = try run(e, &.{ "--root", "fs.example.com/9p", "--root-ca", ca, "--print", "ls" });
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try expectIn(r.out, "wss://fs.example.com/9p");
    // A loopback root is ws://, which takes no CA.
    const l = try run(e, &.{ "--root", "localhost:8080/9p", "--root-ca", ca, "--print", "ls" });
    defer l.deinit();
    try std.testing.expectEqual(2, l.code);
    try expectIn(l.err, "--root-ca needs a wss:// root");
}

test "a missing path without a dotted host is still not found [76]" {
    const e = try env(@src());
    for ([_][]const u8{ "no-such-root", "./9front.img", "dist/root" }) |arg| {
        const r = try run(e, &.{ "--root", arg, "/bin/echo" });
        defer r.deinit();
        try std.testing.expectEqual(125, r.code);
        var want: [96]u8 = undefined;
        try expectIn(r.err, try std.fmt.bufPrint(&want, "root {s}: not found", .{arg}));
        try std.testing.expect(std.mem.indexOf(u8, r.err, "read it as") == null);
    }
}

/// H9_TEST_WSS_URL, a wss:// 9P server the host can reach, or a skip.
fn wssUrl(buf: []u8) ![]const u8 {
    const v = getenv(3, "H9_TEST_WSS_URL") orelse return error.SkipZigTest;
    if (v.len > buf.len) return error.SkipZigTest;
    @memcpy(buf[0..v.len], v);
    return buf[0..v.len];
}

// websocket-9p on the browser host: the cases above run there too, under
// -Dweb with -Demu=unicorn for their servers; these check what's
// particular to it.

test "a ws:// root runs /bin/ls on the web host [21, 12]" {
    const e = try env(@src());
    if (!onWeb()) return error.SkipZigTest;
    var w: WsRoot = undefined;
    try w.start(e, .{});
    defer w.stop();
    try expectSameAsHost(e, w.url(), &.{ "/bin/ls", "/", "/bin/ls" });
}

test "root_headers is an error on the web host [21, 12]" {
    const e = try env(@src());
    if (!onWeb()) return error.SkipZigTest;
    const r = try run(e, &.{ "--root", "ws://127.0.0.1:1/9p", "--root-header", "Authorization: Bearer x", "/bin/echo" });
    defer r.deinit();
    try std.testing.expectEqual(2, r.code);
    try expectIn(r.err, "--root-header isn't available on the web host");
}

test "the guest mounts a /net/ws conversation on the web host [21, 12]" {
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

test "text messages round-trip through /net/ws on the web host [21, 12]" {
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

test "--net=outbound binds only /net/ws on the web host [21, 12]" {
    const e = try env(@src());
    if (!onWeb()) return error.SkipZigTest;
    const r = try run(e, &.{ "--net=outbound", "--rc", "ls /net; ls '#I' >[2]/dev/null || echo no ip" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("/net/ws\nno ip\n", r.out);
    const p = try run(e, &.{ "--net=outbound", "--print", "/bin/echo" });
    defer p.deinit();
    try expectIn(p.out, "bind '#ℏ' /net");
    try std.testing.expect(std.mem.indexOf(u8, p.out, "unenforced") == null);
}

test "a wss:// root runs /bin/ls [21]" {
    const e = try env(@src());
    var buf: [1024]u8 = undefined;
    const url = try wssUrl(&buf);
    if (getenv(3, "H9_TEST_WSS_CA") != null) return error.SkipZigTest; // the next case's
    const r = try run(e, &.{ "--root", url, "/bin/ls", "/bin/ls" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqual(0, r.code);
    try std.testing.expectEqualStrings("/bin/ls\n", r.out);
}

test "--root-ca trusts a private CA, and the host bundle doesn't [21]" {
    const e = try env(@src());
    var buf: [1024]u8 = undefined;
    const url = try wssUrl(&buf);
    var ca_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const v = getenv(3, "H9_TEST_WSS_CA") orelse return error.SkipZigTest;
    @memcpy(ca_buf[0..v.len], v);
    const ca = ca_buf[0..v.len];
    const ok = try run(e, &.{ "--root", url, "--root-ca", ca, "/bin/ls", "/bin/ls" });
    defer ok.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{ok.err});
    try std.testing.expectEqual(0, ok.code);
    const refused = try run(e, &.{ "--root", url, "/bin/echo" });
    defer refused.deinit();
    try std.testing.expectEqual(125, refused.code);
    try expectIn(refused.err, "certificate: unknown authority");
}

// 9box, the multi-call binary (design/0064-multicall.md). The tree comes from
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

/// Runs `args` with the root `root`.
fn runRoot(e: Env, root: []const u8, args: []const []const u8) !Result {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "--root", root });
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

test "9box runs a command through a hard link [64]" {
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

test "9box runs a command through a #! stub [64]" {
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

test "an rc script runs when /bin/rc is a stub [64]" {
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

test "9box CMD ARGS and an unknown command [64]" {
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

test "ramfs runs from the box [64]" {
    const e = try env(@src());
    const slim = try slimTree(e);
    const r = try runRoot(e, slim, &.{ "--rc", "ramfs -m /n && echo inram >/n/f && ls /n && cat /n/f" });
    defer r.deinit();
    try std.testing.expectEqualStrings("/n/f\ninram\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "argv0 is the command's own name [64]" {
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

test "each boxed command matches its stock binary on the corpus [64]" {
    const e = try env(@src());
    try expectCorpus(e, try slimTree(e));
}

test "a 9P root serving 9box under every name [64]" {
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

test "without --gfx, #i, #m and #b are masked [15]" {
    const e = try env(@src());
    for ([_][]const u8{ "#i", "#m", "#b" }) |dev| {
        const r = try run(e, &.{ "ls", dev });
        defer r.deinit();
        errdefer std.debug.print("ls {s}: {s}", .{ dev, r.err });
        try std.testing.expectEqual(1, r.code);
        try std.testing.expect(std.mem.indexOf(u8, r.err, "mount/attach disallowed") != null);
    }
}

test "--gfx on a build without graphics exits 125 [15]" {
    const e = try env(@src());
    const v = try runProcess(&.{ e.h9, "--version" }, null);
    defer gpa.free(v.stdout);
    defer gpa.free(v.stderr);
    if (std.mem.indexOf(u8, v.stdout, "gfx: none\n") == null) return error.SkipZigTest;
    const r = try run(e, &.{ "--gfx", "echo", "hi" });
    defer r.deinit();
    try std.testing.expectEqual(125, r.code);
    try std.testing.expectEqualStrings("", r.out);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "graphics aren't built into this h9") != null);
}

// Contained trees (design/0034-symlinks-in-root.md). The root for these is
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
    try d.symLink(io, "/lib/hello", "tree/etc/hello", .{});
    try d.symLink(io, "../../../../../../lib/hello", "tree/etc/up", .{});
    try d.symLink(io, "loop", "tree/etc/loop", .{});
    try d.symLink(io, "/deny/secret", "tree/etc/pub", .{});
    var t: [64]u8 = undefined;
    try d.symLink(io, try std.fmt.bufPrint(&t, "/{s}/bin/cat", .{arch}), try std.fmt.bufPrint(&b, "tree/{s}/bin/kitty", .{arch}), .{});
    return std.fmt.bufPrint(out, "{s}/tree", .{s.path});
}

test "absolute symlink in a contained tree resolves inside it [34]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var tb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tree = try linkTree(e, &s, &tb);
    const r = try runRoot(e, tree, &.{ "--cwd", s.path, "--root-contained", "cat", "/etc/hello" });
    defer r.deinit();
    try std.testing.expectEqualStrings("tree hello\n", r.out);
    try std.testing.expectEqual(0, r.code);
    // A command reached through a link runs, and lists as its target.
    const k = try runRoot(e, tree, &.{ "--cwd", s.path, "--root-contained", "kitty", "/lib/hello" });
    defer k.deinit();
    try std.testing.expectEqualStrings("tree hello\n", k.out);
    try std.testing.expectEqual(0, k.code);
}

test "symlink with .. stops at the top of a contained tree [34]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var tb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tree = try linkTree(e, &s, &tb);
    const r = try runRoot(e, tree, &.{ "--cwd", s.path, "--root-contained", "cat", "/etc/up" });
    defer r.deinit();
    try std.testing.expectEqualStrings("tree hello\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "symlink loop is too many symbolic links [34]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var tb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tree = try linkTree(e, &s, &tb);
    const r = try runRoot(e, tree, &.{ "--cwd", s.path, "--root-contained", "cat", "/etc/loop" });
    defer r.deinit();
    try std.testing.expectEqual(1, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "too many symbolic links") != null);
}

test "contained tree still honours --read-deny [34]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var tb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tree = try linkTree(e, &s, &tb);
    var db: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const deny = try std.fmt.bufPrint(&db, "{s}/deny", .{tree});
    const r = try runRoot(e, tree, &.{ "--cwd", s.path, "--root-contained", "--read-deny", deny, "cat", "/etc/pub" });
    defer r.deinit();
    try std.testing.expectEqual(1, r.code);
    try std.testing.expectEqualStrings("", r.out);
    const l = try runRoot(e, tree, &.{ "--cwd", s.path, "--root-contained", "--read-deny", deny, "ls", "/", "/etc" });
    defer l.deinit();
    try std.testing.expect(std.mem.indexOf(u8, l.out, "deny") == null);
    try std.testing.expect(std.mem.indexOf(u8, l.out, "/etc/pub") == null);
    try std.testing.expect(std.mem.indexOf(u8, l.out, "/etc/hello") != null);
}

test "uncontained bind follows host symlinks as before [34]" {
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
    try s.tmp.dir.symLink(std.testing.io, try std.fmt.bufPrint(&lp, "{s}/f", .{other.path}), "tree/lib/host", .{});
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
    const c = try runRoot(e, tree, &.{ "--cwd", s.path, "--readable", other.path, "--root-contained", "cat", "/lib/host" });
    defer c.deinit();
    try std.testing.expectEqual(1, c.code);
    try std.testing.expectEqualStrings("", c.out);
}

test "--print's #U!c bind replays with --ns [34]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var tb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tree = try linkTree(e, &s, &tb);
    const p = try runRoot(e, tree, &.{ "--cwd", s.path, "--root-contained", "--print", "cat" });
    defer p.deinit();
    var want: [std.Io.Dir.max_path_bytes + 16]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, p.out, try std.fmt.bufPrint(&want, "  bind '#U!c{s}' /", .{tree})) != null);
    const start = (std.mem.indexOf(u8, p.out, "namespace:\n") orelse return error.NoNamespace) + "namespace:\n".len;
    const end = std.mem.indexOfPos(u8, p.out, start, "access:\n") orelse p.out.len;
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ns", .data = p.out[start..end] });
    // Replayed over an uncontained root, the #U!c bind makes it contained
    // (--host-fs leaves #U unmasked, so the replay can attach it).
    const r = try runRoot(e, tree, &.{ "--cwd", s.path, "--host-fs", "--write=scope", "--ns", "ns", "cat", "/etc/hello" });
    defer r.deinit();
    try std.testing.expectEqualStrings("tree hello\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "ls -l /bin in a contained tree with links (demo) [34]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    var tb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tree = try linkTree(e, &s, &tb);
    const r = try runRoot(e, tree, &.{ "--cwd", s.path, "--root-contained", "ls", "-l", "/bin" });
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "/bin/kitty") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "/bin/cat") != null);
}

// The Linux personality (design/0018-linux-personality.md): static Linux
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
    backends: []const u8,
    buf: [2][std.Io.Dir.max_path_bytes]u8 = undefined,
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
    le.* = .{ .h9 = h9, .root = undefined, .fixtures = undefined, .nine = null, .arch = arch, .backends = "auto" };
    le.root = try std.fmt.bufPrint(&le.buf[0], "{s}/alpine-{s}", .{ lr, arch });
    le.fixtures = try std.fmt.bufPrint(&le.buf[1], "{s}/{s}", .{ fx, arch });
    const io = std.testing.io;
    std.Io.Dir.cwd().access(io, try hostPath(le.root, "etc/os-release"), .{}) catch return error.SkipZigTest;
    std.Io.Dir.cwd().access(io, try hostPath(le.fixtures, "hello"), .{}) catch return error.SkipZigTest;
    // The backends and the 9front root go in slots 2 and 1, read last.
    le.backends = getenv(2, "H9_TEST_BACKENDS") orelse "auto";
    // The 9front root counts only if it has this architecture's programs.
    if (getenv(1, "H9_TEST_ROOT")) |n| {
        var cat_buf: [32]u8 = undefined;
        const cat = try std.fmt.bufPrint(&cat_buf, "{s}/bin/cat", .{arch});
        if (std.Io.Dir.cwd().access(io, try hostPath(n, cat), .{})) |_| le.nine = n else |_| {}
    }
}

/// Runs `h9 --root <alpine> [--root <9front>] --cwd <fixtures> args...` on
/// each backend, checking they agree, as `run` does.
fn runLinux(le: *const LinuxEnv, with_nine: bool, args: []const []const u8) !Result {
    if (with_nine and le.nine == null) return error.SkipZigTest;
    var first: ?Result = null;
    errdefer if (first) |f| f.deinit();
    var it = std.mem.tokenizeScalar(u8, le.backends, ',');
    while (it.next()) |backend| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ le.h9, "--backend", backend, "--arch", le.arch, "--root", le.root });
        if (with_nine) try argv.appendSlice(gpa, &.{ "--root", le.nine.? });
        try argv.appendSlice(gpa, &.{ "--cwd", le.fixtures });
        try argv.appendSlice(gpa, args);
        const p = try runProcessWith(argv.items, null, null, 120_000);
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
            errdefer std.debug.print("backend {s} differs for h9 {s}\n", .{ backend, args[0] });
            try std.testing.expectEqualStrings(f.out, r.out);
            try std.testing.expectEqual(f.code, r.code);
        } else first = r;
    }
    return first orelse error.SkipZigTest;
}

test "a static Linux program runs and exits with its status (demo) [18]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    const r = try runLinux(&le, false, &.{ "/mnt/term/cwd/hello", "x", "y" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("hello from linux, argc=3\narg x\narg y\n", r.out);
    try std.testing.expectEqual(3, r.code);
}

test "files, fork, vfork, exec, pipes, signals and mmap work for a Linux program [18]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    const r = try runLinux(&le, false, &.{"/mnt/term/cwd/probe"});
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expect(!std.mem.startsWith(u8, r.out, "FAIL ") and std.mem.indexOf(u8, r.out, "\nFAIL ") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "exec child status 5\n") != null);
    try std.testing.expectEqual(0, r.code);
}

test "a Linux program killed by a signal exits 128+N, and a handler can catch a fault [18]" {
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

test "rt_sigreturn can't raise a Linux program's privilege [18]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    const r = try runLinux(&le, false, &.{"/mnt/term/cwd/sigreturn"});
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("handled 1, selectors kept\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "busybox sh runs a pipeline from the Linux root, and /proc describes it (demo) [18]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    const r = try runLinux(&le, false, &.{ "sh", "-c", "echo a b c | wc -w; cat /proc/self/comm; grep -c ^processor /proc/cpuinfo >/dev/null && echo cpuinfo; ./hello | head -1; exit 7" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("3\ncat\ncpuinfo\nhello from linux, argc=1\n", r.out);
    try std.testing.expectEqual(7, r.code);
}

test "/proc/self/stat and status describe a Linux process [18]" {
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

test "ln -s makes links a Linux program follows, renames and removes, and sh waits on a background job [18]" {
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

test "/proc/self/exe is the file a Linux program runs, its links followed [18]" {
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

test "a Linux root without resolv.conf gets the host's DNS servers, and a UDP client may bind port 0 [50]" {
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

// 32-bit x86 Linux programs (design/linux-i386.md): Alpine's x86 root
// and the 386 fixtures on the emulator, whatever the host. With
// -Darch=386 the cases above run them too.
test "an Alpine x86 shell runs on the emulator, with TLS, signals, pipes, and fork (demo) [linux-i386]" {
    try skipPending(@src().fn_name);
    const h9 = getenv(0, "H9_TEST_BIN") orelse return error.SkipZigTest;
    const lr = getenv(3, "H9_TEST_LINUX_ROOT") orelse return error.SkipZigTest;
    const fx = getenv(2, "H9_TEST_LINUX") orelse return error.SkipZigTest;
    var rb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var fb: [std.Io.Dir.max_path_bytes]u8 = undefined;
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
    const p = try runProcessWith(&.{ h9, "--backend", "emu", "--arch", "386", "--root", root, "--cwd", fixtures, "/bin/sh", "-c", script }, null, null, 120_000);
    defer gpa.free(p.stdout);
    defer gpa.free(p.stderr);
    if (std.mem.indexOf(u8, p.stderr, "emulator isn't built") != null) return error.SkipZigTest;
    errdefer std.debug.print("stderr: {s}\n", .{p.stderr});
    try std.testing.expectEqualStrings("i686\nusr1\n2\nok timed_tls\nok fork_thread\n", p.stdout);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, p.term);
}

test "9front and Linux programs share pipelines both ways (demo) [18]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    // Linux sh runs 9front programs under /9 ...
    const lx = try runLinux(&le, true, &.{ "sh", "-c", "echo x y | /9/bin/wc -w | tr -d ' '; /9/bin/rc -c 'exit oops'; echo $?" });
    defer lx.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{lx.err});
    try std.testing.expectEqualStrings("2\n1\n", lx.out);
    try std.testing.expectEqual(0, lx.code);
    // ... and rc runs Linux programs through #λ.
    const nine = try runLinux(&le, true, &.{ "--rc", "echo hi | '#λ/usr/bin/wc' -c; '#λ/bin/sh' -c 'kill -TERM $$'; echo $status" });
    defer nine.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{nine.err});
    try std.testing.expect(std.mem.startsWith(u8, nine.out, "3\n"));
    try std.testing.expect(std.mem.indexOf(u8, nine.out, "linux: signal 15") != null);
}

// What databases need of files (design/0018-linux-personality.md),
// through tests/fixtures/linux/files.c, which prints "ok NAME" per case.

test "fcntl record locks conflict across processes, wait, and go when the owner closes an fd or exits [18]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "posix_locks" }, "ok posix_locks\n");
}

test "OFD locks belong to the open file, and flock shares, excludes and follows dup [18]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "ofd_flock" }, "ok ofd_flock\n");
}

test "exec closing a child's last close-on-exec fd of a file releases its flock [18]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "flock_exec" }, "ok flock_exec\n");
}

test "processes mapping a file MAP_SHARED see each other's stores, read and write agree, and the file keeps them [18]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "shared_map" }, "ok shared_map\n");
}

test "fsync works, and wait4 and getrusage report CPU time [18]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "fsync_rusage" }, "ok fsync_rusage\n");
}

test "page-by-page preads read ahead, and see writes and truncates at once [18]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "read_cache" }, "ok read_cache\n");
}

test "fallocate grows a file, KEEP_SIZE doesn't, and holes are EOPNOTSUPP [18]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "falloc" }, "ok falloc\n");
}

test "rename across directories moves in an overlay, and is the host's rename in a host tree [18]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "rename_across" }, "ok rename_across\n");
    // In a writable host directory, as Redis's AOF dir is.
    var sc: Scratch = undefined;
    try sc.init();
    defer sc.deinit();
    var fb: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try std.Io.Dir.copyFile(std.Io.Dir.cwd(), try std.fmt.bufPrint(&fb, "{s}/files", .{le.fixtures}), sc.tmp.dir, "files", std.testing.io, .{});
    var bit = std.mem.tokenizeScalar(u8, le.backends, ',');
    const p = try runProcessWith(&.{ le.h9, "--backend", bit.next() orelse "auto", "--arch", le.arch, "--root", le.root, "--cwd", sc.path, "--writable", sc.path, "--env", "DIR=.", "sh", "-c", "./files rename_across" }, null, null, 120_000);
    defer gpa.free(p.stdout);
    defer gpa.free(p.stderr);
    errdefer std.debug.print("stderr: {s}\n", .{p.stderr});
    try std.testing.expectEqualStrings("ok rename_across\n", p.stdout);
}

test "an arm64 Linux program can read the ID registers, as HWCAP_CPUID says [18]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "id_regs" }, "ok id_regs\n");
}

test "madvise MADV_FREE is EINVAL, and MADV_DONTNEED zeroes [18]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "madv_free" }, "ok madv_free\n");
}

test "System V shared memory: a keyed segment, shared across fork, its attach count, and removal [18]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "sysv_shm" }, "ok sysv_shm\n");
}

test "a process that exits with a file mapped shared writes it back on the way out [18]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "map_exit" }, "ok map_exit\n");
}

test "process-shared semaphores in MAP_SHARED memory work across fork, on pages touched only after it [18]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "shared_sem" }, "ok shared_sem\n");
}

test "signalfd turns blocked signals into reads, and wakes epoll from itself and another process [18]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "signal_fd" }, "ok signal_fd\n");
}

test "setitimer and alarm deliver SIGALRM, once or repeating [18]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "itimer" }, "ok itimer\n");
}

test "root can become another user and its groups, and can't come back [18]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/files", "creds" }, "ok creds\n");
}

// Readiness and sockets (design/0050-linux-net.md), through
// tests/fixtures/linux/net.c, which prints "ok NAME" per case.

fn netCase(le: *const LinuxEnv, args: []const []const u8, want: []const u8) !void {
    const r = try runLinux(le, false, args);
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqualStrings(want, r.out);
    try std.testing.expectEqual(0, r.code);
}

test "poll on a pipe wakes when the writer writes [50]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/net", "poll_pipe" }, "ok poll_pipe\n");
}

test "O_NONBLOCK read on an empty pipe is EAGAIN, and select agrees [50]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/net", "nonblock_pipe" }, "ok nonblock_pipe\n");
}

test "readv from a pipe returns what's there once a buffer fills [50]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/net", "readv_pipe" }, "ok readv_pipe\n");
}

test "epoll edge-triggered on a pipe [50]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/net", "epoll_et" }, "ok epoll_et\n");
}

test "eventfd counts and wakes epoll [50]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/net", "eventfd" }, "ok eventfd\n");
}

test "named and abstract Unix sockets: bind, listen, epoll, accept, connect, and refused once closed [50]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/net", "unix_sock" }, "ok unix_sock\nok unix_abstract\n");
}

test "socket under --net=disable is EACCES [50]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "--net=disable", "/mnt/term/cwd/net", "disabled" }, "ok disabled\n");
}

test "TCP echo between a Linux client and server, with getpeername [50]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "--net=enable", "/mnt/term/cwd/net", "tcp_echo" }, "ok tcp_echo\n");
}

test "non-blocking connect is EINPROGRESS, then writable, then SO_ERROR 0 [50]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "--net=enable", "/mnt/term/cwd/net", "nb_connect" }, "ok nb_connect\n");
}

test "shutdown(SHUT_WR) shows the peer EOF and EPOLLRDHUP [50]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "--net=enable", "/mnt/term/cwd/net", "half_close" }, "ok half_close\n");
}

test "a Linux process that exits holding a TCP connection closes it [50]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "--net=enable", "/mnt/term/cwd/net", "exit_eof" }, "ok exit_eof\n");
}

test "IPv4 and IPV6_V6ONLY IPv6 wildcard listeners share a port, or IPv6 is EAFNOSUPPORT without it [50]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "--net=enable", "/mnt/term/cwd/net", "dual_bind" }, "ok dual_bind\n");
}

test "netlink lists loopback for getifaddrs, and a listener on 127.0.0.1 reports it [50]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "--net=enable", "/mnt/term/cwd/net", "ifaddrs" }, "ok ifaddrs\n");
}

test "UDP sendto and recvfrom on an unconnected socket [50]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "--net=enable", "/mnt/term/cwd/net", "udp" }, "ok udp\n");
}

test "two sendtos to one peer from a socket bound to port 0, under --net outbound, as musl's resolver does [50]" {
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
    const first = try sock.receiveTimeout(std.testing.io, &buf, timeout);
    try std.testing.expectEqualStrings("A", first.data);
    const second = try sock.receiveTimeout(std.testing.io, &buf, timeout);
    try std.testing.expectEqualStrings("B", second.data);
}

test "more than 30 TCP connections at once [50]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "--net=enable", "/mnt/term/cwd/net", "many" }, "ok many\n");
}

test "TCP echo between a Linux client and a 9front server [50]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    // aux/listen1 runs cat (a 9front path: listen1 is a 9front program)
    // for one connection; busybox nc talks to it.
    const r = try runLinux(&le, true, &.{ "--net=enable", "sh", "-c", "/9/bin/aux/listen1 -1 -t tcp!127.0.0.1!17007 /bin/cat & sleep 1; echo ping | nc -w 2 127.0.0.1 17007" });
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expectEqualStrings("ping\n", r.out);
}

test "Go net/http server and client in one Linux program [50]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try goLinux(&le);
    try netCase(&le, &.{ "--net=enable", "/mnt/term/cwd/go/nethttp" }, "ok nethttp\n");
}

// Threads (design/0049-linux-threads.md), through
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

test "pthreads program with 8 threads and a mutex [49]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try threadCase(&le, "mutex");
    try threadCase(&le, "condvar");
}

test "thread-local storage, timed waits and fork from a thread [49]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try threadCase(&le, "timed_tls");
    try threadCase(&le, "fork_thread");
}

test "a Linux program's termios reaches the host terminal: echo off keeps lines, ICANON off is raw and keeps echo [18]" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // no termios to check
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    var it = std.mem.tokenizeScalar(u8, le.backends, ',');
    while (it.next()) |backend| {
        errdefer std.debug.print("backend {s}\n", .{backend});
        var t = try Term.spawn(gpa, &.{ le.h9, "--backend", backend, "--arch", le.arch, "--root", le.root, "--timeout", "120s", "/bin/sh", "-c", "stty -echo; echo ready1; read x; echo got=$x; stty echo raw; echo ready2; dd bs=1 count=1 2>/dev/null; stty sane; echo; echo done" });
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

test "a Linux program in raw mode gets Enter as CR without ICRNL, polls with VMIN 0, and sees the terminal's size [18]" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // no termios to check
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    var it = std.mem.tokenizeScalar(u8, le.backends, ',');
    while (it.next()) |backend| {
        errdefer std.debug.print("backend {s}\n", .{backend});
        // fzf tells Enter (CR) from Ctrl-J, and btop reads with VMIN 0
        // until a read returns nothing.
        var t = try Term.spawn(gpa, &.{ le.h9, "--backend", backend, "--arch", le.arch, "--root", le.root, "--timeout", "120s", "/bin/sh", "-c", "echo size=$(stty size); stty raw -echo; echo ready; dd bs=1 count=2 2>/dev/null | od -An -c; stty min 0 time 0; echo poll=$(dd bs=1 count=1 2>/dev/null | wc -c); stty sane; echo done" });
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

test "Go linux binary starts goroutines and sleeps [49]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try goLinux(&le);
    const r = try runLinux(&le, false, &.{"/mnt/term/cwd/go/goroutines"});
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\nstderr: {s}\n", .{ r.out, r.err });
    try std.testing.expect(std.mem.startsWith(u8, r.out, "ok goroutines "));
    try std.testing.expectEqual(0, r.code);
}

test "/proc lists a thread group once, with its threads under task, and statm reads, as htop needs [49]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try threadCase(&le, "proc_threads");
}

test "Go os/exec waits for a child from another thread, and RemoveAll empties a /tmp directory [49]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try goLinux(&le);
    try netCase(&le, &.{"/mnt/term/cwd/go/goexec"}, "ok goexec\n");
}

test "munmap while another thread reads: no stale access after return [49]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try threadCase(&le, "munmap");
}

test "a store or read(2) racing another thread's mprotect in the same chunk neither faults nor EFAULTs [49]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try threadCase(&le, "remap_race");
}

test "exit_group kills every thread [49]" {
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

test "execve from a non-leader thread [49]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try netCase(&le, &.{ "/mnt/term/cwd/threads", "exec_thread" }, "ok exec_thread\n");
}

test "tgkill interrupts a thread in a busy loop [49]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try threadCase(&le, "tgkill_busy");
    try threadCase(&le, "tgkill_wait");
}

test "CLONE_CHILD_CLEARTID wakes pthread_join [49]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    // Each join waits on the thread's clear-tid word; the leader's own
    // exit waits for the last thread.
    try threadCase(&le, "timed_tls");
    try netCase(&le, &.{ "/mnt/term/cwd/threads", "leader_exit" }, "ok leader_exit\n");
}

test "a thread spinning without syscalls doesn't starve the others on the emulator [49]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try threadCase(&le, "spin");
}

test "Go GC with a goroutine in a call-free loop, at 1 ms slices [49]" {
    var le: LinuxEnv = undefined;
    try linuxEnv(@src(), &le);
    try goLinux(&le);
    try netCase(&le, &.{"/mnt/term/cwd/go/gcloop"}, "ok gcloop 20\n");
}

// The browser host's cases (design/0012-browser-host.md). They run on
// every backend; what they guard is the web host's: coroutines that park
// for the event loop, a JIT over recycled pages, and stacks without
// guard pages.

test "a spinning process doesn't starve a pipeline [12]" {
    const e = try env(@src());
    // The spinner makes no system calls, so only preemption lets the
    // pipeline run.
    const r = try run(e, &.{ "--timeout", "60s", "--rc", "{while(){}} & spin=$apid; echo hello | tr h H | wc -c; echo kill >/proc/$spin/note" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("      6\n", r.out);
    try std.testing.expectEqual(0, r.code);
}

test "a console read parks and resumes on input [12]" {
    const e = try env(@src());
    var it = backendList(e);
    while (it.next()) |backend| {
        errdefer std.debug.print("backend {s}\n", .{backend});
        // While read waits for a line, the background process still runs.
        var t = try spawnTerm(e, backend, &.{ "--timeout", "60s", "--rc", "{sleep 1; echo ti^ck} & echo rea^dy; x=`{read}; echo got $x" });
        defer t.deinit();
        try t.expect("ready", slow(10_000));
        try t.expect("tick", slow(10_000));
        try t.send("line" ++ enter);
        try t.expect("got line", slow(10_000));
        try std.testing.expectEqual(0, try t.wait(slow(10_000)));
    }
}

test "a note interrupts a parked console read [12]" {
    const e = try env(@src());
    var it = backendList(e);
    while (it.next()) |backend| {
        errdefer std.debug.print("backend {s}\n", .{backend});
        // Nothing is typed, so read stays parked until the note.
        var t = try spawnTerm(e, backend, &.{ "--timeout", "60s", "--rc", "read </dev/cons & r=$apid; sleep 1; echo interrupt >/proc/$r/note; wait; echo af^ter" });
        defer t.deinit();
        try t.expect("after", slow(10_000));
        try std.testing.expectEqual(0, try t.wait(slow(10_000)));
    }
}

test "errno survives a park [12]" {
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

test "exec into recycled pages doesn't run stale JIT code [12]" {
    const e = try env(@src());
    // Each program's pages are freed when it exits and handed to the
    // next, so echo's compiled text would run in basename's place.
    const r = try run(e, &.{ "--timeout", "120s", "--rc", "for(i in `{seq 1 40}){ /bin/echo a; /bin/basename /x/b }" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("a\nb\n" ** 40, r.out);
    try std.testing.expectEqual(0, r.code);
}

test "RFMEM processes see each other's writes [12]" {
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

test "a coroutine stack overflow panics instead of corrupting [12]" {
    const e = try env(@src());
    // Coroutines are the web host's; native kernel processes are threads
    // with guard pages.
    if (getenv(3, "H9_TEST_WEB") == null) return error.SkipZigTest;
    var it = backendList(e);
    while (it.next()) |backend| {
        // Every coroutine gets an 8 KiB stack, which running a command overflows.
        const r = try runEnv(e, backend, &.{ "--rc", "ls /bin >/dev/null" }, &.{.{ "H9_TEST_KSTACK", "8192" }}, slow(30_000));
        defer r.deinit();
        errdefer std.debug.print("stderr: {s}\n", .{r.err});
        try expectIn(r.err, "kernel stack overflow in ");
        try std.testing.expect(r.code != 0);
    }
}

// The built-in root (design/0087-builtin-root.md): `#Hroot`, multicall's tree
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

/// Runs `h9 args...` on the first backend, with no --root and no H9ROOT,
/// in `cwd` if given.
fn runNoRoot(e: Env, h9: []const u8, args: []const []const u8) !Result {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ h9, "--backend", firstBackend(e) });
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

test "with no root found, --rc runs from the built-in root [87]" {
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

test "--builtin=only ignores H9ROOT [87]" {
    const e = try env(@src());
    try needBuiltin(e);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ e.h9, "--backend", firstBackend(e), "--builtin=only" });
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

test "--builtin=only with --root is a usage error [87]" {
    const e = try env(@src());
    const r = try runProcess(&.{ e.h9, "--builtin=only", "--root", e.root, "--rc", "echo x" }, null);
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 2 }, r.term);
}

test "--builtin=off without a root is exit 125 as before [87]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const h9 = try h9Copy(e, &s);
    defer gpa.free(h9);
    const r = try runNoRoot(e, h9, &.{ "--builtin=off", "--rc", "echo x" });
    defer r.deinit();
    try std.testing.expectEqual(125, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "no root tree found") != null);
}

test "--builtin=before runs the box's ls and the root's other commands [87]" {
    const e = try env(@src());
    try needBuiltin(e);
    const r = try run(e, &.{ "--builtin=before", "--rc", "cmp -s /bin/ls /bin/9box && echo boxed; test -x /bin/mk && echo mk" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("boxed\nmk\n", r.out);
}

test "--builtin=after leaves the root's ls and fills a missing command [87]" {
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
    const r = try runNoRoot(e, e.h9, &.{ "--root", root, "--builtin=after", "--rc", "cmp -s /bin/ls /bin/9box || echo own; echo filled | wc -l" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("own\n      1\n", r.out);
}

test "a host a.out without a root sees /dev, /env, /proc, /tmp and its cwd [87]" {
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

test "the built-in root refuses writes and /tmp is writable in memory [87]" {
    const e = try env(@src());
    try needBuiltin(e);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const r = try runNoRoot(e, e.h9, &.{ "--builtin=only", "--cwd", s.path, "--write=scope", "--rc", "touch /usr/f >[2]/dev/null || echo refused; echo y >/tmp/f && cat /tmp/f" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("refused\ny\n", r.out);
}

test "--print shows the #Hroot bind as builtin [87]" {
    const e = try env(@src());
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const r = try runNoRoot(e, e.h9, &.{ "--builtin=only", "--cwd", s.path, "--print", "--rc", "echo" });
    defer r.deinit();
    try std.testing.expectEqual(0, r.code);
    const at = std.mem.indexOf(u8, r.out, "  bind '#Hroot' / ") orelse return error.NoBind;
    const line = r.out[at..std.mem.indexOfScalarPos(u8, r.out, at, '\n').?];
    try std.testing.expect(std.mem.indexOf(u8, line, " builtin  # h9 ") != null);
    const b = try run(e, &.{ "--builtin=before", "--print", "--rc", "echo" });
    defer b.deinit();
    var want: [64]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, b.out, try std.fmt.bufPrint(&want, "  bind '#Hroot/{s}/bin' /bin ", .{testArch(e)})) != null);
}

test "--ns replays a plan printed over the built-in root [87]" {
    const e = try env(@src());
    try needBuiltin(e);
    var s: Scratch = undefined;
    try s.init();
    defer s.deinit();
    const p = try runNoRoot(e, e.h9, &.{ "--builtin=only", "--cwd", s.path, "--print", "--rc", "echo" });
    defer p.deinit();
    const start = (std.mem.indexOf(u8, p.out, "namespace:\n") orelse return error.NoNamespace) + "namespace:\n".len;
    const end = std.mem.indexOfPos(u8, p.out, start, "access:\n") orelse p.out.len;
    try s.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "ns", .data = p.out[start..end] });
    // Replayed over the full tree, the plan makes the built-in root `/`.
    const r = try run(e, &.{ "--cwd", s.path, "--ns", "ns", "--rc", "test -d /sys || echo builtin" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("builtin\n", r.out);
}

test "--check passes with only the built-in root [87]" {
    const e = try env(@src());
    // --check runs the host's architecture.
    if (e.arch != null) return error.SkipZigTest;
    try needBuiltin(e);
    const r = try runNoRoot(e, e.h9, &.{ "--builtin=only", "--check" });
    defer r.deinit();
    errdefer std.debug.print("stdout: {s}\n", .{r.out});
    try std.testing.expectEqual(0, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "root: built-in (") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.out, "ok, /bin/echo runs") != null);
}

test "a Linux root alone gets the built-in root as its /9, and --builtin=off leaves it out [87]" {
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
    const r = try runNoRoot(e, e.h9, &.{ "--root", lin, "--cwd", s.path, "--rc", "test -x '#\u{3bb}/9/bin/ls' && echo boxed" });
    defer r.deinit();
    errdefer std.debug.print("stderr: {s}\n", .{r.err});
    try std.testing.expectEqualStrings("boxed\n", r.out);
    const off = try runNoRoot(e, e.h9, &.{ "--root", lin, "--cwd", s.path, "--builtin=off", "--print", "--rc", "echo" });
    defer off.deinit();
    try std.testing.expect(std.mem.indexOf(u8, off.out, "#Hroot") == null);
}

test "a missing command names the built-in root in its error [87]" {
    const e = try env(@src());
    try needBuiltin(e);
    const r = try runNoRoot(e, e.h9, &.{ "--builtin=only", "mk" });
    defer r.deinit();
    try std.testing.expectEqual(127, r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "not in the built-in root; pass --root or set H9ROOT") != null);
}
