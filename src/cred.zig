//! Credential helpers (design/credential-helpers.md): host commands h9
//! runs before a WebSocket handshake it makes, chosen by matching the URL
//! against `--cred PATTERN=COMMAND` patterns, whose output is headers to
//! send with the handshake.
//!
//! `pick` chooses the helper for a URL: the longest matching pattern,
//! with no fallthrough. `run` runs it as `argv… get URL`, with the failed
//! handshake's status line and headers on stdin when it's a retry after
//! a 401 or 403, and returns the `Name: value` lines it printed, checked
//! with ws.checkHeader. The output is zeroed when it's freed: a helper's
//! headers live in h9's memory for one handshake, and never reach the
//! plan, a trace, or an error message.
//!
//! Helpers run on the host, as the host user, outside the sandbox, from
//! the stream's own thread (src/hstream.zig), never for a guest's
//! `/net/ws` conversation.

const std = @import("std");
const builtin = @import("builtin");
const ws = @import("ws.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

/// One `--cred` entry.
pub const Helper = struct {
    /// Scheme-less URL prefix; a leading `*.` matches host labels.
    pattern: []const u8,
    /// Command and arguments, run as `argv… get URL`.
    argv: []const []const u8,
};

/// How long a helper may take before the handshake fails.
pub const timeout_s = 30;
/// The most a helper may print on stdout, or on stderr.
pub const max_output = 64 * 1024;
/// Whether a helper's stderr is copied to h9's. Unit tests turn it off.
pub var echo_stderr = true;

pub const ParseError = error{ BadPattern, NoCommand, OutOfMemory };

/// Parses `PATTERN=COMMAND`, splitting COMMAND on spaces and tabs. The
/// result's slices point into `spec`; only the argv list is allocated.
pub fn parse(gpa: Allocator, spec: []const u8) ParseError!Helper {
    const eq = std.mem.indexOfScalar(u8, spec, '=') orelse return error.NoCommand;
    const pattern = std.mem.trim(u8, spec[0..eq], " \t");
    try checkPattern(pattern);
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(gpa);
    var it = std.mem.tokenizeAny(u8, spec[eq + 1 ..], " \t");
    while (it.next()) |w| try argv.append(gpa, w);
    if (argv.items.len == 0) return error.NoCommand;
    return .{ .pattern = pattern, .argv = try argv.toOwnedSlice(gpa) };
}

/// Parses `$H9CRED`: `PATTERN=COMMAND` entries separated by `;`, as
/// GOAUTH separates its commands. Empty entries are skipped.
pub fn parseList(gpa: Allocator, list: []const u8, out: *std.ArrayList(Helper)) ParseError!void {
    var it = std.mem.splitScalar(u8, list, ';');
    while (it.next()) |e| {
        if (std.mem.trim(u8, e, " \t").len == 0) continue;
        try out.append(gpa, try parse(gpa, e));
    }
}

/// Checks a pattern: a host, optionally `*.` before a domain, a port, and
/// a path; no scheme, no other `*`, and no `*` or `*.` alone.
pub fn checkPattern(p: []const u8) error{BadPattern}!void {
    if (p.len == 0 or std.mem.indexOf(u8, p, "://") != null) return error.BadPattern;
    for (p) |ch| if (ch <= ' ' or ch == 0x7f) return error.BadPattern;
    const slash = std.mem.indexOfScalar(u8, p, '/') orelse p.len;
    var host = p[0..slash];
    if (std.mem.startsWith(u8, host, "*")) {
        if (!std.mem.startsWith(u8, host, "*.")) return error.BadPattern;
        host = host[2..];
        // A domain after `*.`, so a pattern never matches every host.
        if (host.len == 0 or host[0] == '.' or host[0] == ':') return error.BadPattern;
    }
    if (host.len == 0) return error.BadPattern;
    if (std.mem.indexOfScalar(u8, p[if (p[0] == '*') 1 else 0..], '*') != null) return error.BadPattern;
}

/// Whether `pattern` (already checked) matches `url`. Without a port,
/// the pattern's host matches the URL's host on any port; with one, the
/// authority. Without a path it matches every path on its host; with one,
/// paths under it, at a `/` or `?` boundary.
pub fn matches(pattern: []const u8, url: ws.Url) bool {
    const slash = std.mem.indexOfScalar(u8, pattern, '/') orelse pattern.len;
    const ph = pattern[0..slash];
    const pp = pattern[slash..];
    const have = if (std.mem.indexOfScalar(u8, if (ph.len > 0 and ph[0] == '[') ph[std.mem.indexOfScalar(u8, ph, ']') orelse 0 ..] else ph, ':') != null) url.authority else url.host;
    if (std.mem.startsWith(u8, ph, "*.")) {
        const suffix = ph[1..]; // ".wanix.io": one or more labels before it
        if (have.len <= suffix.len or !std.ascii.endsWithIgnoreCase(have, suffix)) return false;
    } else if (!std.ascii.eqlIgnoreCase(have, ph)) return false;
    if (pp.len == 0 or std.mem.eql(u8, pp, "/")) return true;
    const tg = url.target;
    if (!std.mem.startsWith(u8, tg, pp)) return false;
    return tg.len == pp.len or pp[pp.len - 1] == '/' or tg[pp.len] == '/' or tg[pp.len] == '?';
}

/// The helper for `url`: the longest matching pattern's, or the first
/// given of equally long ones. Only it runs.
pub fn pick(helpers: []const Helper, url: ws.Url) ?*const Helper {
    var best: ?*const Helper = null;
    for (helpers) |*h| {
        if (!matches(h.pattern, url)) continue;
        if (best == null or h.pattern.len > best.?.pattern.len) best = h;
    }
    return best;
}

/// What a helper printed, as checked header lines. `deinit` zeroes it.
pub const Output = struct {
    buf: []u8 = &.{},
    /// `Name: value` lines, trimmed, in `buf`.
    headers: []const []const u8 = &.{},

    pub fn deinit(o: *Output, gpa: Allocator) void {
        std.crypto.secureZero(u8, o.buf);
        gpa.free(o.buf);
        gpa.free(o.headers);
        o.* = .{};
    }
};

/// Why a helper failed, for the stream's error. Never holds its stdout.
pub const Why = struct {
    buf: [96]u8 = undefined,
    len: usize = 0,

    pub fn text(w: *const Why) []const u8 {
        return w.buf[0..w.len];
    }

    fn set(w: *Why, comptime fmt: []const u8, args: anytype) void {
        w.len = (std.fmt.bufPrint(&w.buf, fmt, args) catch blk: {
            // Too long: keep what fits, ending in an ellipsis.
            var fw = std.Io.Writer.fixed(w.buf[0 .. w.buf.len - 3]);
            fw.print(fmt, args) catch {};
            const n = fw.end;
            @memcpy(w.buf[n..][0..3], "…");
            break :blk w.buf[0 .. n + 3];
        }).len;
    }
};

pub const RunError = error{ Failed, OutOfMemory };

/// Runs `h` as `argv… get URL`, with `prev` (the failed handshake's
/// response, or empty) on stdin, for up to `timeout_s`. Its stderr is
/// copied to h9's. On failure, `why` says why.
pub fn run(gpa: Allocator, io: Io, h: *const Helper, url: []const u8, prev: []const u8, why: *Why) RunError!Output {
    const name = std.fs.path.basename(h.argv[0]);
    if (std.mem.startsWith(u8, url, "ws://"))
        std.debug.print("h9: warning: credential helper {s} for {f}: its headers cross the network in plaintext\n", .{ name, ws.Url.elide(url) });
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, h.argv);
    try argv.appendSlice(gpa, &.{ "get", url });

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |e| {
        switch (e) {
            error.FileNotFound => why.set("credential helper {s}: not found", .{name}),
            error.AccessDenied, error.PermissionDenied => why.set("credential helper {s}: permission denied", .{name}),
            else => why.set("credential helper {s}: {t}", .{ name, e }),
        }
        return error.Failed;
    };
    defer child.kill(io);
    // A short write: a helper that doesn't read its stdin can't stall it
    // past the pipe's buffer, which a status line and headers fit in.
    if (prev.len > 0) child.stdin.?.writeStreamingAll(io, prev) catch {};
    child.stdin.?.close(io);
    child.stdin = null;

    var mr_buf: Io.File.MultiReader.Buffer(2) = undefined;
    var mr: Io.File.MultiReader = undefined;
    mr.init(gpa, io, mr_buf.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();
    const out_r = mr.reader(0);
    const err_r = mr.reader(1);
    const limit: Io.Timeout = (Io.Timeout{ .duration = .{ .raw = .fromSeconds(timeout_s), .clock = .awake } }).toDeadline(io);
    while (mr.fill(256, limit)) |_| {
        if (out_r.buffered().len > max_output or err_r.buffered().len > max_output) {
            std.crypto.secureZero(u8, out_r.buffered());
            why.set("credential helper {s}: too much output", .{name});
            return error.Failed;
        }
    } else |e| switch (e) {
        error.EndOfStream => {},
        error.Timeout => {
            std.crypto.secureZero(u8, out_r.buffered());
            why.set("credential helper {s}: no answer in {d} seconds", .{ name, timeout_s });
            return error.Failed;
        },
        else => {
            why.set("credential helper {s}: {t}", .{ name, e });
            return error.Failed;
        },
    }
    const term = child.wait(io) catch |e| {
        why.set("credential helper {s}: {t}", .{ name, e });
        return error.Failed;
    };
    const errs = err_r.buffered();
    if (echo_stderr and errs.len > 0) std.debug.print("{s}{s}", .{ errs, if (errs[errs.len - 1] == '\n') "" else "\n" });
    const ok = switch (term) {
        .exited => |c| c == 0,
        else => false,
    };
    if (!ok) {
        std.crypto.secureZero(u8, out_r.buffered());
        const first = firstLine(errs);
        switch (term) {
            .exited => |c| if (first.len > 0)
                why.set("credential helper {s}: {s}", .{ name, first })
            else
                why.set("credential helper {s}: exit status {d}", .{ name, c }),
            .signal => |sig| why.set("credential helper {s}: killed by signal {d}", .{ name, @intFromEnum(sig) }),
            else => why.set("credential helper {s}: failed", .{name}),
        }
        return error.Failed;
    }
    const buf = mr.toOwnedSlice(0) catch return error.OutOfMemory;
    var o: Output = .{ .buf = buf };
    errdefer o.deinit(gpa);
    o.headers = try parseOutput(gpa, buf, why, name);
    return o;
}

/// The `Name: value` lines of a helper's output, up to a blank line or
/// the end, checked. An error names the header, never its value.
fn parseOutput(gpa: Allocator, buf: []const u8, why: *Why, name: []const u8) RunError![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    var lines = std.mem.splitScalar(u8, buf, '\n');
    var n: usize = 0;
    while (lines.next()) |l| {
        n += 1;
        if (std.mem.trim(u8, l, " \t\r").len == 0) break;
        const line = ws.checkHeader(l) catch |e| {
            switch (e) {
                error.ReservedHeader => why.set("credential helper {s}: {s} changes the handshake", .{ name, ws.headerName(l) }),
                error.BadHeader => why.set("credential helper {s}: line {d} isn't a 'Name: value' header", .{ name, n }),
            }
            return error.Failed;
        };
        try list.append(gpa, line);
    }
    return list.toOwnedSlice(gpa);
}

fn firstLine(s: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |l| {
        const line = std.mem.trim(u8, l, " \t\r");
        if (line.len > 0) return line;
    }
    return "";
}

/// Appends `static` (`--root-header`'s), then the helper's headers whose
/// names `static` doesn't have: a `--root-header` wins over a helper's
/// header of the same name.
pub fn merge(gpa: Allocator, static: []const []const u8, got: []const []const u8, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    try out.appendSlice(gpa, static);
    outer: for (got) |g| {
        for (static) |s| if (std.ascii.eqlIgnoreCase(ws.headerName(s), ws.headerName(g))) continue :outer;
        try out.append(gpa, g);
    }
}

/// `pattern=argv…`, for the plan.
pub fn describe(h: Helper) Describe {
    return .{ .h = h };
}

pub const Describe = struct {
    h: Helper,
    pub fn format(d: Describe, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s}=", .{d.h.pattern});
        for (d.h.argv, 0..) |a, i| try w.print("{s}{s}", .{ if (i > 0) " " else "", a });
    }
};

const t = std.testing;

fn parseUrl(s: []const u8) ws.Url {
    return ws.Url.parse(s) catch unreachable;
}

test "patterns [credential-helpers]" {
    try checkPattern("progrium.wanix.io");
    try checkPattern("progrium.wanix.io/data/projects");
    try checkPattern("*.wanix.io");
    try checkPattern("localhost:8080/9p");
    for ([_][]const u8{ "", "*", "*.", "*./x", "**.wanix.io", "*wanix.io", "a.*.io", "wss://a.io", "/path", "a b" }) |p|
        try t.expectError(error.BadPattern, checkPattern(p));

    try t.expect(matches("progrium.wanix.io", parseUrl("wss://progrium.wanix.io/data?x=1")));
    try t.expect(matches("Progrium.Wanix.io", parseUrl("wss://progrium.wanix.io:8443/")));
    try t.expect(!matches("wanix.io", parseUrl("wss://progrium.wanix.io/data")));
    try t.expect(matches("*.wanix.io", parseUrl("wss://progrium.wanix.io/data")));
    try t.expect(matches("*.wanix.io", parseUrl("wss://a.b.wanix.io/")));
    try t.expect(!matches("*.wanix.io", parseUrl("wss://wanix.io/")));
    try t.expect(!matches("*.wanix.io", parseUrl("wss://evilwanix.io/")));
    try t.expect(matches("progrium.wanix.io/data", parseUrl("wss://progrium.wanix.io/data")));
    try t.expect(matches("progrium.wanix.io/data", parseUrl("wss://progrium.wanix.io/data/projects")));
    try t.expect(matches("progrium.wanix.io/data", parseUrl("wss://progrium.wanix.io/data?t=1")));
    try t.expect(!matches("progrium.wanix.io/data", parseUrl("wss://progrium.wanix.io/database")));
    try t.expect(matches("127.0.0.1:8080", parseUrl("ws://127.0.0.1:8080/9p")));
    try t.expect(!matches("127.0.0.1:8080", parseUrl("ws://127.0.0.1:8081/9p")));
}

test "only the longest matching pattern's helper is picked [credential-helpers]" {
    const hs = [_]Helper{
        .{ .pattern = "*.wanix.io", .argv = &.{"broad"} },
        .{ .pattern = "progrium.wanix.io/data/projects", .argv = &.{"narrow"} },
        .{ .pattern = "progrium.wanix.io", .argv = &.{"host"} },
    };
    try t.expectEqualStrings("narrow", pick(&hs, parseUrl("wss://progrium.wanix.io/data/projects/h9")).?.argv[0]);
    try t.expectEqualStrings("host", pick(&hs, parseUrl("wss://progrium.wanix.io/data")).?.argv[0]);
    try t.expectEqualStrings("broad", pick(&hs, parseUrl("wss://other.wanix.io/")).?.argv[0]);
    try t.expect(pick(&hs, parseUrl("wss://example.com/")) == null);
}

test "parse and describe --cred [credential-helpers]" {
    const h = try parse(t.allocator, "*.wanix.io=wanix  token --quiet");
    defer t.allocator.free(h.argv);
    try t.expectEqualStrings("*.wanix.io", h.pattern);
    try t.expectEqual(@as(usize, 3), h.argv.len);
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("*.wanix.io=wanix token --quiet", try std.fmt.bufPrint(&buf, "{f}", .{describe(h)}));
    try t.expectError(error.NoCommand, parse(t.allocator, "*.wanix.io"));
    try t.expectError(error.NoCommand, parse(t.allocator, "*.wanix.io= "));
    try t.expectError(error.BadPattern, parse(t.allocator, "*=cat"));

    var list: std.ArrayList(Helper) = .empty;
    defer {
        for (list.items) |x| t.allocator.free(x.argv);
        list.deinit(t.allocator);
    }
    try parseList(t.allocator, "a.io=one;; b.io=two x;", &list);
    try t.expectEqual(@as(usize, 2), list.items.len);
    try t.expectEqualStrings("b.io", list.items[1].pattern);
}

test "a helper's output is checked header lines, and --root-header wins on a name [credential-helpers]" {
    var why: Why = .{};
    const hs = try parseOutput(t.allocator, "Authorization: Bearer t1\r\nX-A: b\n\nignored: after blank\n", &why, "h");
    defer t.allocator.free(hs);
    try t.expectEqual(@as(usize, 2), hs.len);
    try t.expectEqualStrings("Authorization: Bearer t1", hs[0]);
    try t.expectError(error.Failed, parseOutput(t.allocator, "Host: evil\n", &why, "h"));
    try t.expectEqualStrings("credential helper h: Host changes the handshake", why.text());
    try t.expectError(error.Failed, parseOutput(t.allocator, "X: ok\nsecret-token\n", &why, "h"));
    try t.expect(std.mem.indexOf(u8, why.text(), "secret") == null);

    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(t.allocator);
    try merge(t.allocator, &.{"authorization: Bearer mine"}, hs, &out);
    try t.expectEqual(@as(usize, 2), out.items.len);
    try t.expectEqualStrings("authorization: Bearer mine", out.items[0]);
    try t.expectEqualStrings("X-A: b", out.items[1]);
}

test "run: headers from a helper, its stdin on a retry, and its failures [credential-helpers]" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const io = t.io;
    echo_stderr = false;
    defer echo_stderr = true;
    var why: Why = .{};
    // `sh -c SCRIPT get URL`: $0 is get, $1 the URL.
    const ok: Helper = .{ .pattern = "x", .argv = &.{ "/bin/sh", "-c", "read -r l || l=none; echo \"Authorization: Bearer $1\"; echo \"X-Prev: $l\"" } };
    var o = try run(t.allocator, io, &ok, "wss://a.io/p", "", &why);
    try t.expectEqualStrings("Authorization: Bearer wss://a.io/p", o.headers[0]);
    try t.expectEqualStrings("X-Prev: none", o.headers[1]);
    o.deinit(t.allocator);
    o = try run(t.allocator, io, &ok, "wss://a.io/p", "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Bearer\r\n\r\n", &why);
    try t.expectEqualStrings("X-Prev: HTTP/1.1 401 Unauthorized", o.headers[1]);
    o.deinit(t.allocator);

    const fails: Helper = .{ .pattern = "x", .argv = &.{ "/bin/sh", "-c", "echo 'Authorization: x'; echo 'not logged in' >&2; exit 3" } };
    try t.expectError(error.Failed, run(t.allocator, io, &fails, "wss://a.io/", "", &why));
    try t.expectEqualStrings("credential helper sh: not logged in", why.text());
    const quiet: Helper = .{ .pattern = "x", .argv = &.{ "/bin/sh", "-c", "exit 4" } };
    try t.expectError(error.Failed, run(t.allocator, io, &quiet, "wss://a.io/", "", &why));
    try t.expectEqualStrings("credential helper sh: exit status 4", why.text());
    const missing: Helper = .{ .pattern = "x", .argv = &.{"/nonexistent/h9-cred-helper"} };
    try t.expectError(error.Failed, run(t.allocator, io, &missing, "wss://a.io/", "", &why));
    try t.expectEqualStrings("credential helper h9-cred-helper: not found", why.text());
    const none: Helper = .{ .pattern = "x", .argv = &.{"/bin/true"} };
    o = try run(t.allocator, io, &none, "wss://a.io/", "", &why);
    try t.expectEqual(@as(usize, 0), o.headers.len);
    o.deinit(t.allocator);
}
