//! Static dotfs trees (design/mounts.md, "Static trees"): dotfs's index
//! profile served as plain files over HTTP, `URL/.fs/index` for the
//! metadata and `URL/PATH` for each file's contents. h9 serves one to the
//! kernel as a read-only 9P2000 server on the host, on a unix socket in a
//! private directory, which the kernel dials through a `#ℓ` conversation
//! as it dials any unix-socket server.
//!
//! - Walks, stats, and directory reads are answered from the index. A
//!   directory flagged `i` has its own `URL/DIR/.fs/index`, fetched the
//!   first time something walks into or lists it.
//! - A file up to `whole_max` is fetched whole on its first read and kept
//!   for the rest of the run; a larger one is read by Range requests. A
//!   whole file whose index line has a `b3:` hash is checked against it,
//!   and a mismatch fails the read with "content changed". Checked
//!   contents are kept on the host by hash, so trees that share files
//!   share them. Files flagged `p` are fetched when the tree is loaded.
//! - Symbolic links are resolved here, inside the tree, as a contained
//!   tree's are (design/epoch-0/symlinks-in-root.md).
//! - Every write, create, remove, and wstat fails: a static tree has no
//!   `events`, `ctl`, or `stage`.

const std = @import("std");
const builtin = @import("builtin");
const wire = @import("dotl/wire.zig");
const attr = @import("dotl/attr.zig");
const hstream = @import("hstream.zig");
const cred = @import("cred.zig");
const ws = @import("ws.zig");
const ri = @import("rootindex.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const p9 = wire.p9;
const Blake3 = std.crypto.hash.Blake3;

/// Files up to this size are fetched whole, and hash-checked.
pub const whole_max: u64 = 64 << 10;
/// The largest message the server takes.
const max_msize: u32 = 64 << 10;
/// Symbolic links followed in one walk.
const max_links = 16;

pub const Options = struct {
    /// `Name: value` lines sent with every request, already checked.
    headers: []const []const u8 = &.{},
    ca_file: ?[]const u8 = null,
    proxy: ws.ProxyConfig = .{},
    /// Credential helpers: the best match for the URL runs once, and its
    /// headers go with every request after `headers`.
    cred: []const cred.Helper = &.{},
    /// Where checked contents are kept by hash, or null for memory only.
    blob_dir: ?[]const u8 = null,
};

const Kind = enum { dir, file, link };

const Node = struct {
    name: []const u8,
    parent: u32,
    kind: Kind,
    perm: u32,
    length: u64,
    mtime: u32,
    version: u64,
    hash: ?[32]u8,
    /// Its children are in its own index, not fetched yet.
    nested: bool,
    prefetch: bool,
    /// A link's target.
    target: []const u8,
    uid: []const u8,
    gid: []const u8,
    children: std.ArrayList(u32) = .empty,
};

pub const LoadError = error{ OutOfMemory, BadIndex, Fetch };

/// A static tree: its index, loaded so far, and its contents.
pub const Tree = struct {
    gpa: Allocator,
    arena_state: std.heap.ArenaAllocator,
    io: Io,
    /// The tree's URL, without a trailing `/`.
    base: []const u8,
    opts: Options,
    /// The credential helper's headers, once it has run.
    cred_out: cred.Output = .{},
    mu: Io.Mutex = .init,
    nodes: std.ArrayList(Node) = .empty,
    /// Whole contents, by node.
    whole: std.AutoHashMapUnmanaged(u32, []u8) = .empty,
    /// Requests made, by kind, for the tests.
    gets: std.atomic.Value(u32) = .init(0),
    ranges: std.atomic.Value(u32) = .init(0),
    /// Why the last fetch failed.
    why_buf: [160]u8 = undefined,
    why_len: usize = 0,

    fn arena(t: *Tree) Allocator {
        return t.arena_state.allocator();
    }

    pub fn why(t: *const Tree) []const u8 {
        return t.why_buf[0..t.why_len];
    }

    fn setWhy(t: *Tree, comptime fmt: []const u8, args: anytype) void {
        t.why_len = if (std.fmt.bufPrint(&t.why_buf, fmt, args)) |x| x.len else |_| 0;
    }

    /// A tree at `url` (`http://` or `https://`), with `index` its
    /// `.fs/index` text, already fetched. The caller frees it with
    /// `destroy`.
    pub fn create(gpa: Allocator, io: Io, url: []const u8, index: []const u8, opts: Options) LoadError!*Tree {
        const t = try gpa.create(Tree);
        t.* = .{ .gpa = gpa, .arena_state = .init(gpa), .io = io, .base = "", .opts = .{} };
        errdefer t.destroy();
        const a = t.arena();
        t.base = try a.dupe(u8, std.mem.trimEnd(u8, url, "/"));
        t.opts = .{
            .headers = try dupeList(a, opts.headers),
            .ca_file = if (opts.ca_file) |f| try a.dupe(u8, f) else null,
            .proxy = .{
                .http = if (opts.proxy.http) |p| try a.dupe(u8, p) else null,
                .https = if (opts.proxy.https) |p| try a.dupe(u8, p) else null,
                .no_proxy = try a.dupe(u8, opts.proxy.no_proxy),
            },
            .cred = opts.cred,
            .blob_dir = if (opts.blob_dir) |d| try a.dupe(u8, d) else null,
        };
        try t.nodes.append(gpa, .{ .name = "/", .parent = 0, .kind = .dir, .perm = 0o555, .length = 0, .mtime = 0, .version = 0, .hash = null, .nested = false, .prefetch = false, .target = "", .uid = "none", .gid = "none" });
        try t.load(0, index);
        // Flagged p: fetched now.
        var i: u32 = 0;
        while (i < t.nodes.items.len) : (i += 1) {
            if (t.nodes.items[i].prefetch and t.nodes.items[i].kind == .file) _ = t.wholeOf(i) catch {};
        }
        return t;
    }

    pub fn destroy(t: *Tree) void {
        var it = t.whole.valueIterator();
        while (it.next()) |v| t.gpa.free(v.*);
        t.whole.deinit(t.gpa);
        for (t.nodes.items) |*n| n.children.deinit(t.gpa);
        t.nodes.deinit(t.gpa);
        t.cred_out.deinit(t.gpa);
        t.arena_state.deinit();
        t.gpa.destroy(t);
    }

    /// Adds an index's lines under directory `at`: its `/` line is `at`
    /// itself, and its other paths are below it.
    fn load(t: *Tree, at: u32, text: []const u8) LoadError!void {
        const a = t.arena();
        var lines = std.mem.splitScalar(u8, text, '\n');
        const first = lines.next() orelse "";
        var hf = std.mem.splitScalar(u8, first, ' ');
        if (!std.mem.eql(u8, hf.next() orelse "", "fsindex") or !std.mem.eql(u8, hf.next() orelse "", "1")) {
            t.setWhy("not an fsindex 1", .{});
            return error.BadIndex;
        }
        var by_path: std.StringHashMapUnmanaged(u32) = .empty;
        defer by_path.deinit(t.gpa);
        try by_path.put(t.gpa, "/", at);
        var line_no: usize = 1;
        while (lines.next()) |line| {
            line_no += 1;
            if (line.len == 0) continue;
            var f: [8][]const u8 = undefined;
            var it = std.mem.splitScalar(u8, line, ' ');
            for (&f) |*x| x.* = it.next() orelse return t.bad(line_no, "too few fields");
            const path = ri.unescape(a, f[0]) catch return t.bad(line_no, "bad escape in path");
            if (!ri.validPath(path)) return t.bad(line_no, "bad path");
            if (f[1].len != 1) return t.bad(line_no, "bad type");
            const kind: Kind = switch (f[1][0]) {
                'd' => .dir,
                'f' => .file,
                'l' => .link,
                else => return t.bad(line_no, "bad type"),
            };
            const perm = std.fmt.parseInt(u32, f[2], 8) catch return t.bad(line_no, "bad mode");
            const length = std.fmt.parseInt(u64, f[3], 10) catch return t.bad(line_no, "bad length");
            const mtime = std.fmt.parseInt(u32, f[4], 10) catch return t.bad(line_no, "bad mtime");
            const version = std.fmt.parseInt(u64, f[5], 10) catch return t.bad(line_no, "bad version");
            var hash: ?[32]u8 = null;
            if (std.mem.startsWith(u8, f[6], "b3:")) {
                const hex = f[6][3..];
                if (hex.len != 64) return t.bad(line_no, "bad hash");
                var h: [32]u8 = undefined;
                _ = std.fmt.hexToBytes(&h, hex) catch return t.bad(line_no, "bad hash");
                hash = h;
            }
            const flags = if (std.mem.eql(u8, f[7], "-")) "" else f[7];
            const target: []const u8 = if (kind == .link)
                ri.unescape(a, it.next() orelse return t.bad(line_no, "symlink without a target")) catch return t.bad(line_no, "bad escape in target")
            else
                "";
            var uid: []const u8 = "none";
            var gid: []const u8 = "none";
            while (it.next()) |kv| {
                if (std.mem.startsWith(u8, kv, "9p.uid=")) uid = ri.unescape(a, kv[7..]) catch uid;
                if (std.mem.startsWith(u8, kv, "9p.gid=")) gid = ri.unescape(a, kv[7..]) catch gid;
            }
            const nested = std.mem.indexOfScalar(u8, flags, 'i') != null and kind == .dir;
            if (std.mem.eql(u8, path, "/")) {
                // The directory itself.
                const n = &t.nodes.items[at];
                if (kind != .dir) return t.bad(line_no, "the top isn't a directory");
                n.perm = perm;
                n.mtime = mtime;
                n.version = version;
                n.uid = uid;
                n.gid = gid;
                continue;
            }
            const slash = std.mem.lastIndexOfScalar(u8, path, '/').?;
            const parent_path = if (slash == 0) "/" else path[0..slash];
            const parent = by_path.get(parent_path) orelse return t.bad(line_no, "no parent before it");
            if (t.nodes.items[parent].kind != .dir) return t.bad(line_no, "parent isn't a directory");
            const id: u32 = @intCast(t.nodes.items.len);
            try t.nodes.append(t.gpa, .{
                .name = path[slash + 1 ..],
                .parent = parent,
                .kind = kind,
                .perm = perm,
                .length = if (kind == .link) target.len else length,
                .mtime = mtime,
                .version = version,
                .hash = hash,
                .nested = nested,
                .prefetch = std.mem.indexOfScalar(u8, flags, 'p') != null,
                .target = target,
                .uid = uid,
                .gid = gid,
            });
            try t.nodes.items[parent].children.append(t.gpa, id);
            try by_path.put(t.gpa, path, id);
        }
    }

    fn bad(t: *Tree, line: usize, msg: []const u8) LoadError {
        t.setWhy("index line {d}: {s}", .{ line, msg });
        return error.BadIndex;
    }

    /// The path of node `i` from the top, `/a/b`, in `buf`.
    fn pathOf(t: *const Tree, i: u32, buf: []u8) []const u8 {
        var names: [ri.max_depth][]const u8 = undefined;
        var n: usize = 0;
        var at = i;
        while (at != 0 and n < names.len) : (at = t.nodes.items[at].parent) {
            names[n] = t.nodes.items[at].name;
            n += 1;
        }
        var w: std.Io.Writer = .fixed(buf);
        if (n == 0) w.writeAll("/") catch {};
        while (n > 0) {
            n -= 1;
            w.writeByte('/') catch {};
            w.writeAll(names[n]) catch {};
        }
        return w.buffered();
    }

    /// A URL for the path of node `i` (with `suffix`, such as
    /// `/.fs/index`), each name percent-escaped.
    fn urlOf(t: *Tree, i: u32, suffix: []const u8, buf: []u8) ![]const u8 {
        var pb: [4096]u8 = undefined;
        const path = t.pathOf(i, &pb);
        var w: std.Io.Writer = .fixed(buf);
        try w.writeAll(t.base);
        if (!std.mem.eql(u8, path, "/")) for (path) |c| {
            if (std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "/-._~!$&'()*+,;=:@", c) != null) try w.writeByte(c) else try w.print("%{X:0>2}", .{c});
        };
        try w.writeAll(suffix);
        return w.buffered();
    }

    /// The headers for every request: `headers=`, then the helper's.
    fn requestHeaders(t: *Tree, list: *std.ArrayList([]const u8)) !void {
        if (t.cred_out.buf.len == 0 and t.opts.cred.len > 0) {
            var ub: [4096]u8 = undefined;
            const as_ws = wsForm(t.base, &ub) orelse return;
            const u = ws.Url.parse(as_ws) catch return;
            if (cred.pick(t.opts.cred, u)) |h| {
                var why_: cred.Why = .{};
                t.cred_out = cred.run(t.gpa, t.io, h, t.base, "", &why_) catch {
                    t.setWhy("credential helper: {s}", .{why_.text()});
                    return error.Fetch;
                };
            }
        }
        try cred.merge(t.gpa, t.opts.headers, t.cred_out.headers, list);
    }

    /// GETs `url`, with a Range if given.
    fn get(t: *Tree, url: []const u8, range: ?[2]u64, limit: usize) !hstream.Response {
        var hs: std.ArrayList([]const u8) = .empty;
        defer hs.deinit(t.gpa);
        try t.requestHeaders(&hs);
        var msg: [128]u8 = undefined;
        @memset(&msg, 0);
        if (range != null) _ = t.ranges.fetchAdd(1, .monotonic) else _ = t.gets.fetchAdd(1, .monotonic);
        return hstream.fetch(t.gpa, t.io, url, .{ .ca_file = t.opts.ca_file, .proxy = t.opts.proxy }, .{
            .headers = hs.items,
            .range = if (range) |r| .{ .first = r[0], .last = r[1] } else null,
            .zstd = true,
            .limit = limit,
        }, &msg) catch |e| {
            t.setWhy("{f}: {s}", .{ ws.Url.elide(url), hstream.fetchError(e, &msg) });
            return error.Fetch;
        };
    }

    /// A body, decoded if it came as zstd.
    fn decoded(t: *Tree, r: *hstream.Response, limit: usize) ![]u8 {
        if (!r.zstd) {
            const b = r.body;
            r.body = &.{};
            return b;
        }
        var in: std.Io.Reader = .fixed(r.body);
        const window = try t.gpa.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max);
        defer t.gpa.free(window);
        var z: std.compress.zstd.Decompress = .init(&in, window, .{});
        var out: std.Io.Writer.Allocating = .init(t.gpa);
        errdefer out.deinit();
        _ = z.reader.streamRemaining(&out.writer) catch return error.Fetch;
        if (out.written().len > limit) return error.Fetch;
        return out.toOwnedSlice();
    }

    /// Loads directory `d`'s own index, if it has one not loaded yet.
    /// Under `mu`.
    fn expand(t: *Tree, d: u32) !void {
        if (!t.nodes.items[d].nested) return;
        var ub: [8192]u8 = undefined;
        const url = try t.urlOf(d, "/" ++ ri.fs_dir ++ "/" ++ ri.index_name, &ub);
        var r = try t.get(url, null, ri.max_text);
        defer r.deinit(t.gpa);
        if (r.status != 200) {
            t.setWhy("{f}: {d} {s}", .{ ws.Url.elide(url), r.status, r.reason() });
            return error.Fetch;
        }
        const text = try t.decoded(&r, ri.max_text);
        defer t.gpa.free(text);
        t.nodes.items[d].nested = false;
        try t.load(d, text);
    }

    /// Node `i`'s whole contents, fetched and checked the first time.
    /// Under `mu`.
    fn wholeOf(t: *Tree, i: u32) ![]const u8 {
        if (t.whole.get(i)) |b| return b;
        const n = t.nodes.items[i];
        if (n.hash) |h| if (t.blobLookup(h)) |b| {
            try t.whole.put(t.gpa, i, b);
            return b;
        };
        var ub: [8192]u8 = undefined;
        const url = try t.urlOf(i, "", &ub);
        var r = try t.get(url, null, @intCast(@max(n.length, 1) + (1 << 20)));
        defer r.deinit(t.gpa);
        if (r.status != 200) {
            t.setWhy("{f}: {d} {s}", .{ ws.Url.elide(url), r.status, r.reason() });
            return error.Fetch;
        }
        const body = try t.decoded(&r, @intCast(n.length + (1 << 20)));
        errdefer t.gpa.free(body);
        if (n.hash) |h| {
            var got: [32]u8 = undefined;
            Blake3.hash(body, &got, .{});
            if (!std.mem.eql(u8, &got, &h)) {
                t.setWhy("content changed", .{});
                return error.ContentChanged;
            }
            t.blobStore(h, body);
        }
        try t.whole.put(t.gpa, i, body);
        return body;
    }

    fn blobName(h: [32]u8, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "b3-{x}", .{&h}) catch unreachable;
    }

    /// A blob from the host's cache, checked again: the caller's.
    fn blobLookup(t: *Tree, h: [32]u8) ?[]u8 {
        const dir = t.opts.blob_dir orelse return null;
        var nb: [80]u8 = undefined;
        var pb: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "{s}/{s}", .{ dir, blobName(h, &nb) }) catch return null;
        const b = std.Io.Dir.cwd().readFileAlloc(t.io, path, t.gpa, .limited(1 << 30)) catch return null;
        var got: [32]u8 = undefined;
        Blake3.hash(b, &got, .{});
        if (!std.mem.eql(u8, &got, &h)) {
            t.gpa.free(b);
            return null;
        }
        return b;
    }

    fn blobStore(t: *Tree, h: [32]u8, data: []const u8) void {
        const dir = t.opts.blob_dir orelse return;
        std.Io.Dir.cwd().createDirPath(t.io, dir) catch return;
        var nb: [80]u8 = undefined;
        var pb: [std.fs.max_path_bytes]u8 = undefined;
        var tb: [std.fs.max_path_bytes]u8 = undefined;
        const name = blobName(h, &nb);
        const path = std.fmt.bufPrint(&pb, "{s}/{s}", .{ dir, name }) catch return;
        var rnd: [8]u8 = undefined;
        t.io.random(&rnd);
        const tmp = std.fmt.bufPrint(&tb, "{s}/.{s}.{x}", .{ dir, name, &rnd }) catch return;
        std.Io.Dir.cwd().writeFile(t.io, .{ .sub_path = tmp, .data = data }) catch return;
        std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, t.io) catch {
            std.Io.Dir.cwd().deleteFile(t.io, tmp) catch {};
        };
    }

    /// Reads `count` bytes of node `i` at `off` into `out`. Under `mu`.
    fn readFile(t: *Tree, i: u32, off: u64, out: []u8) ![]const u8 {
        const n = t.nodes.items[i];
        if (off >= n.length) return out[0..0];
        const want: u64 = @min(out.len, n.length - off);
        if (n.length <= whole_max or t.whole.contains(i) or (n.hash != null and t.blobCached(i))) {
            const b = try t.wholeOf(i);
            if (off >= b.len) return out[0..0];
            const k: usize = @intCast(@min(want, b.len - off));
            @memcpy(out[0..k], b[@intCast(off)..][0..k]);
            return out[0..k];
        }
        var ub: [8192]u8 = undefined;
        const url = try t.urlOf(i, "", &ub);
        var r = try t.get(url, .{ off, off + want - 1 }, @intCast(@max(want, n.length) + (1 << 20)));
        defer r.deinit(t.gpa);
        switch (r.status) {
            206 => {
                const k: usize = @intCast(@min(want, r.body.len));
                @memcpy(out[0..k], r.body[0..k]);
                return out[0..k];
            },
            200 => {
                // The server ignored the Range: it's the whole file.
                const body = try t.decoded(&r, @intCast(n.length + (1 << 20)));
                errdefer t.gpa.free(body);
                if (n.hash) |h| {
                    var got: [32]u8 = undefined;
                    Blake3.hash(body, &got, .{});
                    if (!std.mem.eql(u8, &got, &h)) {
                        t.setWhy("content changed", .{});
                        return error.ContentChanged;
                    }
                    t.blobStore(h, body);
                }
                try t.whole.put(t.gpa, i, body);
                if (off >= body.len) return out[0..0];
                const k: usize = @intCast(@min(want, body.len - off));
                @memcpy(out[0..k], body[@intCast(off)..][0..k]);
                return out[0..k];
            },
            else => {
                t.setWhy("{f}: {d} {s}", .{ ws.Url.elide(url), r.status, r.reason() });
                return error.Fetch;
            },
        }
    }

    fn blobCached(t: *Tree, i: u32) bool {
        const h = t.nodes.items[i].hash orelse return false;
        const b = t.blobLookup(h) orelse return false;
        t.whole.put(t.gpa, i, b) catch {
            t.gpa.free(b);
            return false;
        };
        return true;
    }

    /// The child of directory `d` named `name`. Under `mu`.
    fn lookup(t: *Tree, d: u32, name: []const u8) !?u32 {
        if (std.mem.eql(u8, name, "..")) return t.nodes.items[d].parent;
        if (std.mem.eql(u8, name, ".")) return d;
        try t.expand(d);
        for (t.nodes.items[d].children.items) |c| if (std.mem.eql(u8, t.nodes.items[c].name, name)) return c;
        return null;
    }

    /// What node `i` is once its links are followed, inside the tree; null
    /// for a link that leads nowhere. Under `mu`.
    fn resolve(t: *Tree, i: u32, depth: usize) !?u32 {
        const n = t.nodes.items[i];
        if (n.kind != .link) return i;
        if (depth >= max_links) return null;
        var at: u32 = if (n.target.len > 0 and n.target[0] == '/') 0 else n.parent;
        var it = std.mem.tokenizeScalar(u8, n.target, '/');
        while (it.next()) |name| {
            at = (try t.resolve(at, depth + 1)) orelse return null;
            if (t.nodes.items[at].kind != .dir) return null;
            at = (try t.lookup(at, name)) orelse return null;
        }
        return t.resolve(at, depth + 1);
    }

    fn qidOf(t: *const Tree, i: u32) wire.Qid {
        const n = t.nodes.items[i];
        return .{ .type = if (n.kind == .dir) wire.QTDIR else wire.QTFILE, .vers = @truncate(n.version), .path = i + 1 };
    }

    /// Node `i`'s stat, named `name`.
    fn dirOf(t: *const Tree, i: u32, name: []const u8) attr.Dir {
        const n = t.nodes.items[i];
        const q = t.qidOf(i);
        return .{
            .type = 0,
            .dev = 0,
            .qid_type = q.type,
            .qid_vers = q.vers,
            .qid_path = q.path,
            .mode = (n.perm & 0o777) | (if (n.kind == .dir) wire.DMDIR else 0),
            .atime = n.mtime,
            .mtime = n.mtime,
            .length = if (n.kind == .dir) 0 else n.length,
            .name = name,
            .uid = n.uid,
            .gid = n.gid,
        };
    }
};

fn dupeList(a: Allocator, l: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, l.len);
    for (l, out) |s, *o| o.* = try a.dupe(u8, s);
    return out;
}

/// `http://` as `ws://`, `https://` as `wss://`, for ws.Url.
fn wsForm(url: []const u8, buf: []u8) ?[]const u8 {
    if (std.mem.startsWith(u8, url, "https://")) return std.fmt.bufPrint(buf, "wss://{s}", .{url[8..]}) catch null;
    if (std.mem.startsWith(u8, url, "http://")) return std.fmt.bufPrint(buf, "ws://{s}", .{url[7..]}) catch null;
    return null;
}

/// Fetches `URL/.fs/index`: its text (the caller's) on a 200, or null
/// with `why` set to what the server said.
pub fn fetchIndex(gpa: Allocator, io: Io, url: []const u8, opts: Options, why_buf: []u8, why_len: *usize) !?[]u8 {
    var t: Tree = .{ .gpa = gpa, .arena_state = .init(gpa), .io = io, .base = std.mem.trimEnd(u8, url, "/"), .opts = opts };
    defer {
        t.cred_out.deinit(gpa);
        t.arena_state.deinit();
    }
    var ub: [8192]u8 = undefined;
    const iurl = std.fmt.bufPrint(&ub, "{s}/" ++ ri.fs_dir ++ "/" ++ ri.index_name, .{t.base}) catch return error.Fetch;
    var r = t.get(iurl, null, ri.max_text) catch {
        why_len.* = if (std.fmt.bufPrint(why_buf, "{s}", .{t.why()})) |x| x.len else |_| 0;
        return null;
    };
    defer r.deinit(gpa);
    if (r.status != 200) {
        why_len.* = if (std.fmt.bufPrint(why_buf, "{d} {s}", .{ r.status, r.reason() })) |x| x.len else |_| 0;
        return null;
    }
    return try t.decoded(&r, ri.max_text);
}

/// A fid's state.
const Fid = struct {
    node: u32,
    open: bool = false,
    /// A directory read: the next child, and the offset devmnt is at.
    cursor: usize = 0,
    offset: u64 = 0,
};

/// One connection's 9P2000 session over a tree: frames in, frames out.
pub const Session = struct {
    t: *Tree,
    msize: u32 = 8192,
    fids: std.AutoHashMapUnmanaged(u32, Fid) = .empty,

    pub fn deinit(s: *Session) void {
        s.fids.deinit(s.t.gpa);
    }

    fn err(out: []u8, tag: u16, msg: []const u8) []u8 {
        return wire.encode(out, tag, p9.Rerror{ .ename = msg }, null) catch out[0..0];
    }

    /// Answers one T-message in `frame`, writing the reply to `out`.
    pub fn handle(s: *Session, frame: []const u8, out: []u8) []u8 {
        const f = wire.decode(p9.T, frame, max_msize, false) catch {
            const tag = if (frame.len >= 7) std.mem.readInt(u16, frame[5..7], .little) else wire.notag;
            return err(out, tag, "bad message");
        };
        const t = s.t;
        t.mu.lockUncancelable(t.io);
        defer t.mu.unlock(t.io);
        return s.answer(f.tag, f.msg, out) catch |e| err(out, f.tag, switch (e) {
            error.ContentChanged => "content changed",
            error.Fetch => if (t.why_len > 0) t.why() else "fetch failed",
            error.OutOfMemory => "out of memory",
            else => @errorName(e),
        });
    }

    fn answer(s: *Session, tag: u16, msg: p9.T, out: []u8) ![]u8 {
        const t = s.t;
        const gpa = t.gpa;
        switch (msg) {
            .Tversion => |m| {
                s.msize = @min(m.msize, max_msize);
                const v = if (std.mem.startsWith(u8, m.version, "9P2000")) "9P2000" else "unknown";
                var it = s.fids.iterator();
                _ = &it;
                s.fids.clearRetainingCapacity();
                return wire.encode(out, tag, p9.Rversion{ .msize = s.msize, .version = v }, null);
            },
            .Tauth => return err(out, tag, "no authentication required"),
            .Tattach => |m| {
                if (s.fids.contains(m.fid)) return err(out, tag, "fid in use");
                try s.fids.put(gpa, m.fid, .{ .node = 0 });
                return wire.encode(out, tag, p9.Rattach{ .qid = t.qidOf(0) }, null);
            },
            .Tflush => return wire.encode(out, tag, p9.Rflush{}, null),
            .Twalk => |m| {
                const from = s.fids.get(m.fid) orelse return err(out, tag, "unknown fid");
                if (from.open) return err(out, tag, "fid is open");
                if (m.newfid != m.fid and s.fids.contains(m.newfid)) return err(out, tag, "fid in use");
                var qids: [wire.max_welem]wire.Qid = undefined;
                var at = from.node;
                var n: usize = 0;
                for (m.wnames.slice()) |name| {
                    const d = (try t.resolve(at, 0)) orelse break;
                    if (t.nodes.items[d].kind != .dir) break;
                    const c = (try t.lookup(d, name)) orelse break;
                    const real = (try t.resolve(c, 0)) orelse break;
                    at = c;
                    qids[n] = t.qidOf(real);
                    n += 1;
                }
                if (n == 0 and m.wnames.n > 0) return err(out, tag, ri.layer.enonexist);
                if (n == m.wnames.n) try s.fids.put(gpa, m.newfid, .{ .node = (try t.resolve(at, 0)) orelse at });
                return wire.encode(out, tag, p9.Rwalk{ .wqids = wire.Qids.init(qids[0..n]) }, null);
            },
            .Topen => |m| {
                const fp = s.fids.getPtr(m.fid) orelse return err(out, tag, "unknown fid");
                const mode = m.mode & 3;
                if (mode == wire.OWRITE or mode == wire.ORDWR or m.mode & (wire.OTRUNC | wire.ORCLOSE) != 0)
                    return err(out, tag, "read-only file system");
                fp.open = true;
                fp.cursor = 0;
                fp.offset = 0;
                return wire.encode(out, tag, p9.Ropen{ .qid = t.qidOf(fp.node), .iounit = 0 }, null);
            },
            .Tcreate => return err(out, tag, "read-only file system"),
            .Twrite => return err(out, tag, "read-only file system"),
            .Tremove => |m| {
                _ = s.fids.remove(m.fid);
                return err(out, tag, "read-only file system");
            },
            .Twstat => return err(out, tag, "read-only file system"),
            .Tclunk => |m| {
                _ = s.fids.remove(m.fid);
                return wire.encode(out, tag, p9.Rclunk{}, null);
            },
            .Tstat => |m| {
                const fp = s.fids.get(m.fid) orelse return err(out, tag, "unknown fid");
                var buf: [1024]u8 = undefined;
                const d = t.dirOf(fp.node, t.nodes.items[fp.node].name);
                return wire.encode(out, tag, p9.Rstat{ .stat = .{ .bytes = try d.pack(&buf) } }, null);
            },
            .Tread => |m| {
                const fp = s.fids.getPtr(m.fid) orelse return err(out, tag, "unknown fid");
                if (!fp.open) return err(out, tag, "fid not open");
                const count = @min(m.count, s.msize - wire.io_header);
                const body = out[11..][0..@min(count, out.len - 11)];
                const node = t.nodes.items[fp.node];
                var got: []const u8 = undefined;
                if (node.kind == .dir) {
                    try t.expand(fp.node);
                    if (m.offset == 0) {
                        fp.cursor = 0;
                        fp.offset = 0;
                    }
                    var k: usize = 0;
                    const kids = t.nodes.items[fp.node].children.items;
                    while (fp.cursor < kids.len) {
                        const c = kids[fp.cursor];
                        const real = (try t.resolve(c, 0)) orelse c;
                        var d = t.dirOf(real, t.nodes.items[c].name);
                        if (t.nodes.items[real].kind == .link) d.length = 0;
                        const b = d.pack(body[k..]) catch break;
                        k += b.len;
                        fp.cursor += 1;
                    }
                    fp.offset += k;
                    got = body[0..k];
                } else {
                    got = try t.readFile(fp.node, m.offset, body);
                }
                // The data is already in place after the header.
                const size: u32 = @intCast(11 + got.len);
                std.mem.writeInt(u32, out[0..4], size, .little);
                out[4] = 117; // Rread
                std.mem.writeInt(u16, out[5..7], tag, .little);
                std.mem.writeInt(u32, out[7..11], @intCast(got.len), .little);
                return out[0..size];
            },
        }
    }
};

/// A tree served on a unix socket in a private directory, until `stop`.
pub const Server = struct {
    gpa: Allocator,
    io: Io,
    tree: *Tree,
    dir: []u8,
    /// `unix!PATH`, for `#ℓ`'s dial.
    dial: []u8,
    listener: std.Io.net.Server,
    thread: std.Thread,
    stopping: std.atomic.Value(bool) = .init(false),
    conns: std.atomic.Value(u32) = .init(0),
    /// The connections being served, which `stop` shuts down.
    live_mu: Io.Mutex = .init,
    live: std.ArrayList(std.Io.net.Stream) = .empty,

    /// Serves `tree`, which the server then owns, on a socket under
    /// `tmp` (a host directory).
    pub fn start(gpa: Allocator, io: Io, tree: *Tree, tmp: []const u8) !*Server {
        const s = try gpa.create(Server);
        errdefer gpa.destroy(s);
        var rnd: [6]u8 = undefined;
        io.random(&rnd);
        const dir = try std.fmt.allocPrint(gpa, "{s}/h9-static-{x}", .{ std.mem.trimEnd(u8, tmp, "/\\"), &rnd });
        errdefer gpa.free(dir);
        try std.Io.Dir.cwd().createDir(io, dir, .fromMode(0o700));
        errdefer std.Io.Dir.cwd().deleteDir(io, dir) catch {};
        const path = try std.fmt.allocPrint(gpa, "{s}/s", .{dir});
        defer gpa.free(path);
        const ua = try std.Io.net.UnixAddress.init(path);
        const listener = try ua.listen(io, .{});
        const dial = try std.fmt.allocPrint(gpa, "unix!{s}", .{path});
        s.* = .{ .gpa = gpa, .io = io, .tree = tree, .dir = dir, .dial = dial, .listener = listener, .thread = undefined };
        s.thread = std.Thread.spawn(.{}, acceptLoop, .{s}) catch |e| {
            s.listener.deinit(io);
            gpa.free(dial);
            return e;
        };
        return s;
    }

    /// Stops serving: the socket goes, and the tree once its sessions end.
    pub fn stop(s: *Server) void {
        s.stopping.store(true, .release);
        var pb: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "{s}/s", .{s.dir}) catch "";
        // Wake the accept.
        if (std.Io.net.UnixAddress.init(path)) |ua| {
            if (ua.connect(s.io)) |c| c.close(s.io) else |_| {}
        } else |_| {}
        s.thread.join();
        s.listener.deinit(s.io);
        std.Io.Dir.cwd().deleteFile(s.io, path) catch {};
        std.Io.Dir.cwd().deleteDir(s.io, s.dir) catch {};
        // A connection the kernel still holds ends here.
        {
            s.live_mu.lockUncancelable(s.io);
            defer s.live_mu.unlock(s.io);
            for (s.live.items) |c| c.shutdown(s.io, .both) catch {};
        }
        var spins: usize = 0;
        while (s.conns.load(.acquire) > 0 and spins < 2000) : (spins += 1) s.io.sleep(.fromMilliseconds(1), .awake) catch {};
        // A session that didn't end still uses the tree and the server,
        // so they're leaked rather than freed under it.
        if (s.conns.load(.acquire) > 0) return;
        s.live.deinit(s.gpa);
        s.tree.destroy();
        s.gpa.free(s.dial);
        s.gpa.free(s.dir);
        s.gpa.destroy(s);
    }

    fn acceptLoop(s: *Server) void {
        while (!s.stopping.load(.acquire)) {
            const conn = s.listener.accept(s.io) catch return;
            if (s.stopping.load(.acquire)) {
                conn.close(s.io);
                return;
            }
            _ = s.conns.fetchAdd(1, .acq_rel);
            {
                s.live_mu.lockUncancelable(s.io);
                defer s.live_mu.unlock(s.io);
                s.live.append(s.gpa, conn) catch {
                    _ = s.conns.fetchSub(1, .acq_rel);
                    conn.close(s.io);
                    continue;
                };
            }
            const t = std.Thread.spawn(.{}, serveConn, .{ s, conn }) catch {
                s.forget(conn);
                _ = s.conns.fetchSub(1, .acq_rel);
                conn.close(s.io);
                continue;
            };
            t.detach();
        }
    }

    fn forget(s: *Server, conn: std.Io.net.Stream) void {
        s.live_mu.lockUncancelable(s.io);
        defer s.live_mu.unlock(s.io);
        for (s.live.items, 0..) |c, i| if (c.socket.handle == conn.socket.handle) {
            _ = s.live.swapRemove(i);
            break;
        };
    }
};

fn serveConn(sv: *Server, conn: std.Io.net.Stream) void {
    const io = sv.io;
    const tree = sv.tree;
    defer _ = sv.conns.fetchSub(1, .acq_rel);
    defer conn.close(io);
    defer sv.forget(conn);
    const gpa = tree.gpa;
    const in = gpa.alloc(u8, max_msize) catch return;
    defer gpa.free(in);
    const out = gpa.alloc(u8, max_msize) catch return;
    defer gpa.free(out);
    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var r = conn.reader(io, &rbuf);
    var w = conn.writer(io, &wbuf);
    var s: Session = .{ .t = tree };
    defer s.deinit();
    while (true) {
        r.interface.readSliceAll(in[0..4]) catch return;
        const size = std.mem.readInt(u32, in[0..4], .little);
        if (size < wire.header_size or size > max_msize) return;
        r.interface.readSliceAll(in[4..size]) catch return;
        const reply = s.handle(in[0..size], out);
        if (reply.len == 0) return;
        w.interface.writeAll(reply) catch return;
        w.interface.flush() catch return;
    }
}

const t_ = std.testing;

fn testTree(index: []const u8) !*Tree {
    return Tree.create(t_.allocator, t_.io, "http://127.0.0.1:1/t", index, .{});
}

test "a static tree's index answers walks, stats, and directory reads" {
    const tr = try testTree("fsindex 1 seq 3\n/ d 755 0 10 1 - -\n/bin d 755 0 10 1 - -\n/bin/ls f 755 5 10 1 - -\n/lib d 755 0 10 1 - i\n/ls l 777 0 10 1 - - bin/ls\n");
    defer tr.destroy();
    var s: Session = .{ .t = tr };
    defer s.deinit();
    var out: [8192]u8 = undefined;
    var in: [512]u8 = undefined;
    _ = s.handle(try wire.encode(&in, 1, p9.Tversion{ .msize = 8192, .version = "9P2000" }, null), &out);
    _ = s.handle(try wire.encode(&in, 1, p9.Tattach{ .fid = 1, .afid = wire.nofid, .uname = "u", .aname = "" }, null), &out);
    const names = [_][]const u8{ "bin", "ls" };
    const r = s.handle(try wire.encode(&in, 2, p9.Twalk{ .fid = 1, .newfid = 2, .wnames = wire.Names.init(&names) }, null), &out);
    const f = try wire.decode(p9.R, r, 8192, false);
    try t_.expectEqual(@as(u16, 2), f.msg.Rwalk.wqids.n);
    // A link resolves inside the tree.
    const link = [_][]const u8{"ls"};
    const lr = s.handle(try wire.encode(&in, 3, p9.Twalk{ .fid = 1, .newfid = 3, .wnames = wire.Names.init(&link) }, null), &out);
    const lf = try wire.decode(p9.R, lr, 8192, false);
    try t_.expectEqual(f.msg.Rwalk.wqids.qids[1].path, lf.msg.Rwalk.wqids.qids[0].path);
    // A missing name.
    const none = [_][]const u8{"nope"};
    const nr = s.handle(try wire.encode(&in, 4, p9.Twalk{ .fid = 1, .newfid = 4, .wnames = wire.Names.init(&none) }, null), &out);
    try t_.expectEqualStrings(ri.layer.enonexist, (try wire.decode(p9.R, nr, 8192, false)).msg.Rerror.ename);
    // Writes fail.
    const wr = s.handle(try wire.encode(&in, 5, p9.Topen{ .fid = 2, .mode = wire.OWRITE }, null), &out);
    try t_.expectEqualStrings("read-only file system", (try wire.decode(p9.R, wr, 8192, false)).msg.Rerror.ename);
    // The top lists bin, lib, and ls.
    _ = s.handle(try wire.encode(&in, 6, p9.Topen{ .fid = 1, .mode = wire.OREAD }, null), &out);
    const rr = s.handle(try wire.encode(&in, 7, p9.Tread{ .fid = 1, .offset = 0, .count = 4096 }, null), &out);
    var data = (try wire.decode(p9.R, rr, 8192, false)).msg.Rread.data.bytes;
    var got: [3][]const u8 = undefined;
    var n: usize = 0;
    while (attr.Dir.parse(data)) |p| : (n += 1) {
        got[n] = p[0].name;
        data = data[p[1]..];
    }
    try t_.expectEqual(@as(usize, 3), n);
    try t_.expectEqualStrings("bin", got[0]);
    try t_.expectEqualStrings("ls", got[2]);
}

test "a bad index line is refused with its line number" {
    try t_.expectError(error.BadIndex, testTree("fsindex 1 seq 0\n/ d 755 0 0 0 - -\n/a/b f 644 0 0 0 - -\n"));
}
