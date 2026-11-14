//! The host's cache of compiled indexes (design/mount-index.md,
//! "Fetching and caching"): one file per index, under `--index-cache`, by
//! default `$XDG_CACHE_HOME/h9/index`, `~/Library/Caches/h9/index` on
//! macOS, and `%LOCALAPPDATA%\h9\index` on Windows.
//!
//! A file is named for its key and version: a server index's key is its
//! address and attach name, and its version the index file's qid, mtime,
//! and length; a `--root-index` file or URL's key is `text` and its
//! version the SHA-256 of its text. Storing an entry replaces the key's
//! others. A hit touches the file, and entries not used for 30 days are
//! removed when the cache is next written. The directory is made 0700
//! and its files 0600; a cache that can't be written just isn't.
//!
//! Each file is the compiled form, whose trailer `Index.init` checks, so
//! a damaged file is rebuilt rather than trusted.

const std = @import("std");
const builtin = @import("builtin");
const ri = @import("../rootindex.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// Unused entries are removed after this long.
pub const max_age_s: i64 = 30 * 24 * 60 * 60;
const suffix = ".h9ic";

pub const Cache = struct {
    gpa: Allocator,
    io: Io,
    /// The cache directory, made on first write.
    dir: []const u8,

    /// The default directory, from the environment; or null.
    pub fn defaultDir(gpa: Allocator, env: *const std.process.Environ.Map) ?[]u8 {
        if (builtin.os.tag == .windows) {
            const base = env.get("LOCALAPPDATA") orelse return null;
            return std.fs.path.join(gpa, &.{ base, "h9", "index" }) catch null;
        }
        if (builtin.os.tag.isDarwin()) {
            const home = env.get("HOME") orelse return null;
            return std.fs.path.join(gpa, &.{ home, "Library", "Caches", "h9", "index" }) catch null;
        }
        if (env.get("XDG_CACHE_HOME")) |x| if (x.len > 0) return std.fs.path.join(gpa, &.{ x, "h9", "index" }) catch null;
        const home = env.get("HOME") orelse return null;
        return std.fs.path.join(gpa, &.{ home, ".cache", "h9", "index" }) catch null;
    }

    fn name(buf: *[64]u8, key: []const u8, version: []const u8) []const u8 {
        var k: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(key, &k, .{});
        var v: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(version, &v, .{});
        return std.fmt.bufPrint(buf, "{x}-{x}" ++ suffix, .{ k[0..12], v[0..8] }) catch unreachable;
    }

    fn keyPrefix(buf: *[32]u8, key: []const u8) []const u8 {
        var k: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(key, &k, .{});
        return std.fmt.bufPrint(buf, "{x}-", .{k[0..12]}) catch unreachable;
    }

    /// The compiled index under `key` at `version`, checked, which the
    /// caller owns; or null.
    pub fn lookup(c: *const Cache, key: []const u8, version: []const u8) ?[]u8 {
        var nb: [64]u8 = undefined;
        const n = name(&nb, key, version);
        var d = Io.Dir.cwd().openDir(c.io, c.dir, .{}) catch return null;
        defer d.close(c.io);
        const bytes = d.readFileAlloc(c.io, n, c.gpa, .limited(ri.max_text * 2)) catch return null;
        _ = ri.Index.init(bytes) catch {
            c.gpa.free(bytes);
            d.deleteFile(c.io, n) catch {};
            return null;
        };
        // Dir.setTimestampsNow doesn't build in Zig 0.16.0.
        d.setTimestamps(c.io, n, .{ .modify_timestamp = .now, .access_timestamp = .now }) catch {};
        return bytes;
    }

    /// Keeps `compiled` under `key` at `version`, replacing the key's
    /// other entries, and removes entries unused for 30 days. Failures
    /// are ignored: the index is still used, for this run only.
    pub fn store(c: *const Cache, key: []const u8, version: []const u8, compiled: []const u8) void {
        c.storeAt(key, version, compiled, nowSeconds(c.io)) catch {};
    }

    fn storeAt(c: *const Cache, key: []const u8, version: []const u8, compiled: []const u8, now: i64) !void {
        _ = try Io.Dir.cwd().createDirPathStatus(c.io, c.dir, if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700));
        var d = try Io.Dir.cwd().openDir(c.io, c.dir, .{ .iterate = true });
        defer d.close(c.io);
        var nb: [64]u8 = undefined;
        const n = name(&nb, key, version);
        var pb: [32]u8 = undefined;
        const prefix = keyPrefix(&pb, key);
        // Older versions of this key, and anything unused for 30 days.
        var stale: std.ArrayList([]u8) = .empty;
        defer {
            for (stale.items) |s| c.gpa.free(s);
            stale.deinit(c.gpa);
        }
        var it = d.iterate();
        while (it.next(c.io) catch null) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.name, suffix) and !std.mem.endsWith(u8, e.name, ".tmp") and !std.mem.endsWith(u8, e.name, etag_suffix)) continue;
            const old = std.mem.startsWith(u8, e.name, prefix) and !std.mem.eql(u8, e.name, n);
            const st = d.statFile(c.io, e.name, .{}) catch continue;
            const age = now - @as(i64, @intCast(@divFloor(st.mtime.nanoseconds, std.time.ns_per_s)));
            if (old or age > max_age_s) try stale.append(c.gpa, try c.gpa.dupe(u8, e.name));
        }
        for (stale.items) |s| d.deleteFile(c.io, s) catch {};
        var tb: [80]u8 = undefined;
        var rnd: [4]u8 = undefined;
        c.io.random(&rnd);
        const tmp = std.fmt.bufPrint(&tb, "{s}.{x}.tmp", .{ n, rnd }) catch unreachable;
        {
            var f = try d.createFile(c.io, tmp, .{ .permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600) });
            defer f.close(c.io);
            var buf: [4096]u8 = undefined;
            var w = f.writerStreaming(c.io, &buf);
            w.interface.writeAll(compiled) catch {
                d.deleteFile(c.io, tmp) catch {};
                return error.WriteFailed;
            };
            w.interface.flush() catch {
                d.deleteFile(c.io, tmp) catch {};
                return error.WriteFailed;
            };
        }
        d.rename(tmp, d, n, c.io) catch |e| {
            d.deleteFile(c.io, tmp) catch {};
            return e;
        };
    }

    fn etagName(buf: *[64]u8, url: []const u8) []const u8 {
        var k: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(url, &k, .{});
        return std.fmt.bufPrint(buf, "u-{x}" ++ etag_suffix, .{k[0..12]}) catch unreachable;
    }

    /// The ETag a URL index last came with, and its text's version; or
    /// null.
    pub fn lookupEtag(c: *const Cache, url: []const u8, buf: *[512]u8) ?struct { etag: []const u8, version: []const u8 } {
        var nb: [64]u8 = undefined;
        var d = Io.Dir.cwd().openDir(c.io, c.dir, .{}) catch return null;
        defer d.close(c.io);
        const got = d.readFile(c.io, etagName(&nb, url), buf) catch return null;
        const nl = std.mem.indexOfScalar(u8, got, '\n') orelse return null;
        if (nl == 0 or nl + 1 >= got.len) return null;
        d.setTimestamps(c.io, etagName(&nb, url), .{ .modify_timestamp = .now, .access_timestamp = .now }) catch {};
        return .{ .version = got[0..nl], .etag = got[nl + 1 ..] };
    }

    /// Keeps the ETag a URL index came with, beside its compiled form.
    pub fn storeEtag(c: *const Cache, url: []const u8, etag: []const u8, version: []const u8) void {
        if (etag.len + version.len + 1 > 512 or std.mem.indexOfAny(u8, etag, "\r\n") != null) return;
        var d = Io.Dir.cwd().openDir(c.io, c.dir, .{}) catch return;
        defer d.close(c.io);
        var nb: [64]u8 = undefined;
        var buf: [512]u8 = undefined;
        const data = std.fmt.bufPrint(&buf, "{s}\n{s}", .{ version, etag }) catch return;
        var f = d.createFile(c.io, etagName(&nb, url), .{ .permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600) }) catch return;
        defer f.close(c.io);
        f.writeStreamingAll(c.io, data) catch {};
    }
};

const etag_suffix = ".etag";

fn nowSeconds(io: Io) i64 {
    return @intCast(@divFloor(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
}

/// The key and version a `--root-index` text is cached under.
pub const text_key = "text";

pub fn textVersion(text: []const u8, buf: *[64]u8) []const u8 {
    var h: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(text, &h, .{});
    return std.fmt.bufPrint(buf, "{x}", .{&h}) catch unreachable;
}

const t = std.testing;

test "the cache keeps one version per key, checked [mount-index]" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const io = t.io;
    const path = try tmp.dir.realPathFileAlloc(io, ".", t.allocator);
    defer t.allocator.free(path);
    const dir = try std.fs.path.join(t.allocator, &.{ path, "h9", "index" });
    defer t.allocator.free(dir);
    const c: Cache = .{ .gpa = t.allocator, .io = io, .dir = dir };
    try t.expectEqual(@as(?[]u8, null), c.lookup("tcp!fs!564", "1.0.0.0"));
    var diag: ri.Diag = .{};
    const a = try ri.compile(t.allocator, "h9index 1\n/ 1 0 d 020000000775 0 0 a b\n", &diag);
    defer t.allocator.free(a);
    c.store("tcp!fs!564", "1.0.0.0", a);
    const got = c.lookup("tcp!fs!564", "1.0.0.0").?;
    t.allocator.free(got);
    try t.expectEqual(@as(?[]u8, null), c.lookup("tcp!fs!564", "2.0.0.0"));
    try t.expectEqual(@as(?[]u8, null), c.lookup("tcp!other!564", "1.0.0.0"));
    // A new version replaces the old.
    c.store("tcp!fs!564", "2.0.0.0", a);
    try t.expectEqual(@as(?[]u8, null), c.lookup("tcp!fs!564", "1.0.0.0"));
    const got2 = c.lookup("tcp!fs!564", "2.0.0.0").?;
    t.allocator.free(got2);
    // A damaged file is dropped.
    var nb: [64]u8 = undefined;
    const n = Cache.name(&nb, "tcp!fs!564", "2.0.0.0");
    var d = try Io.Dir.cwd().openDir(io, dir, .{});
    defer d.close(io);
    try d.writeFile(io, .{ .sub_path = n, .data = "junk" });
    try t.expectEqual(@as(?[]u8, null), c.lookup("tcp!fs!564", "2.0.0.0"));
    // An entry unused for 30 days goes when the cache is next written.
    try c.storeAt("tcp!fs!564", "3.0.0.0", a, nowSeconds(io));
    try c.storeAt("tcp!b!564", "1", a, nowSeconds(io) + max_age_s + 60);
    try t.expectEqual(@as(?[]u8, null), c.lookup("tcp!fs!564", "3.0.0.0"));
    if (builtin.os.tag != .windows) {
        const st = try Io.Dir.cwd().statFile(io, dir, .{});
        try t.expectEqual(@as(std.posix.mode_t, 0o700), st.permissions.toMode() & 0o777);
    }
}
