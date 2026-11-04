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
//! timeouts are multiplied by H9_TEST_SLOW (default 1), for emulated VMs.

const std = @import("std");
const builtin = @import("builtin");
const Term = @import("term.zig").Term;
const design = @import("design");

const gpa = std.testing.allocator;

const Env = struct {
    h9: []const u8,
    root: []const u8,
    backends: []const u8,
};

var env_buf: [4][std.Io.Dir.max_path_bytes]u8 = undefined;

/// An environment variable, on every host (getPosix doesn't build on
/// Windows). Values live in one of four slots, chosen by the caller.
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
    // The tree from scripts/mkroot.py is arm64 only, and h9 runs the
    // host's architecture, so x86_64 hosts (linux-amd64) skip these.
    if (builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    std.Io.Dir.cwd().access(std.testing.io, try hostPath(root, "arm64/bin/cat"), .{}) catch return error.SkipZigTest;
    const backends = getenv(2, "H9_TEST_BACKENDS") orelse "auto";
    return .{ .h9 = h9, .root = root, .backends = backends };
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
    const want = try countDir(e, "arm64/bin") + try countDir(e, "rc/bin");
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
    const r = try run(e, &.{ "--timeout", "20s", "--rc", "sleep 1000 & echo die >/proc/$apid/note; wait $apid; echo $status" });
    defer r.deinit();
    try std.testing.expect(std.mem.indexOf(u8, r.out, "die") != null);
    try std.testing.expectEqual(0, r.code);
}

test "--timeout posts hangup before tearing down [baseline]" {
    const e = try env(@src());
    const r = try run(e, &.{ "--timeout", "300ms", "--rc", "fn sighup { echo got hangup }; sleep 10; echo after" });
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
