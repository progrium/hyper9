//! Metadata indexes for 9P roots and mounts (design/mount-index.md): the
//! text format `mkindex` writes, and the compiled form h9 keeps in its
//! cache and answers walks, stats, and directory reads from.
//!
//! The text is one entry per line after an `h9index 1` line:
//!
//!     path qid.path qid.vers type mode length mtime uid gid
//!
//! with qid.path in hex, mode in octal with Plan 9's DM bits, type `d`,
//! `a`, `l`, or `-`, and `!unindexed /dir` lines for directories h9 must
//! never answer for. Every path's parent is an earlier directory.
//!
//! The compiled form is one buffer, laid out for mapping into memory:
//!
//!     header        64 bytes: magic, version, counts
//!     entries        64 bytes each, breadth first from the root, with each
//!             directory's children contiguous and sorted by name
//!     users        (offset, length) pairs into the strings
//!     strings        names and users
//!     trailer        SHA-256 of everything before it
//!
//! `Index.init` checks every offset and count against the buffer before
//! anything is read through it, so a corrupted cache file or a hostile
//! index is refused rather than trusted.
//!
//! The index layer that serves from it, `#ι`'s state machine, is in
//! `rootindex/layer.zig`; the host cache in `rootindex/cache.zig`.

const std = @import("std");
const attr = @import("dotl/attr.zig");
const wire = @import("dotl/wire.zig");

pub const layer = @import("rootindex/layer.zig");
pub const cache = @import("rootindex/cache.zig");

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// The text format's first line.
pub const magic_line = "h9index 1";
/// An index larger than this is ignored.
pub const max_text: usize = 256 << 20;
/// The file an index is at the top of a tree.
pub const file_name = ".h9index";

/// The compiled form's version: a cache file of another is rebuilt.
pub const compiled_version: u32 = 1;
const compiled_magic = "h9index\x00";
const header_size = 64;
const entry_size = 64;
const trailer_size = Sha256.digest_length;

const DMDIR: u32 = 0x80000000;
const DMAPPEND: u32 = 0x40000000;
const DMEXCL: u32 = 0x20000000;
const QTDIR: u8 = 0x80;
const QTAPPEND: u8 = 0x40;
const QTEXCL: u8 = 0x20;

/// The root's parent, which is itself.
pub const root: u32 = 0;

const flag_unindexed: u8 = 1;

/// Why an index's text was refused, and on which line.
pub const Diag = struct {
    line: usize = 0,
    msg: []const u8 = "",
};

pub const CompileError = error{ OutOfMemory, BadIndex, UnknownVersion, TooBig };

/// One parsed line, before layout.
const Raw = struct {
    path: []const u8,
    name: []const u8,
    qid: wire.Qid,
    mode: u32,
    length: u64,
    mtime: u32,
    uid: []const u8,
    gid: []const u8,
    parent: u32 = 0,
    unindexed: bool = false,
    children: std.ArrayList(u32) = .empty,
    /// Its place in the compiled entries.
    slot: u32 = 0,
};

/// Compiles index text into the compiled form, which the caller owns.
/// A line that doesn't parse, a format version h9 doesn't know, or text
/// over `max_text` fails it, with `diag` saying why.
pub fn compile(gpa: Allocator, text: []const u8, diag: *Diag) CompileError![]u8 {
    if (text.len > max_text) {
        diag.* = .{ .msg = "larger than 256 MB" };
        return error.TooBig;
    }
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var lines = std.mem.splitScalar(u8, text, '\n');
    const first = lines.next() orelse "";
    if (!std.mem.eql(u8, first, magic_line)) {
        diag.* = .{ .line = 1, .msg = "not an h9index" };
        if (std.mem.startsWith(u8, first, "h9index ")) return error.UnknownVersion;
        return error.BadIndex;
    }
    var raws: std.ArrayList(Raw) = .empty;
    var by_path: std.StringHashMapUnmanaged(u32) = .empty;
    var line_no: usize = 1;
    while (lines.next()) |line| {
        line_no += 1;
        // The text ends with a newline, which leaves one empty field.
        if (line.len == 0 and lines.peek() == null) break;
        const bad = struct {
            fn f(d: *Diag, n: usize, msg: []const u8) CompileError {
                d.* = .{ .line = n, .msg = msg };
                return error.BadIndex;
            }
        }.f;
        if (std.mem.startsWith(u8, line, "!")) {
            const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return bad(diag, line_no, "bad directive");
            if (!std.mem.eql(u8, line[0..sp], "!unindexed")) return bad(diag, line_no, "unknown directive");
            const i = by_path.get(line[sp + 1 ..]) orelse return bad(diag, line_no, "!unindexed names no earlier directory");
            if (raws.items[i].qid.type & QTDIR == 0) return bad(diag, line_no, "!unindexed names a file");
            raws.items[i].unindexed = true;
            continue;
        }
        var f: [9][]const u8 = undefined;
        var it = std.mem.splitScalar(u8, line, ' ');
        for (&f) |*x| x.* = it.next() orelse return bad(diag, line_no, "too few fields");
        if (it.next() != null) return bad(diag, line_no, "too many fields");
        const path = f[0];
        if (!validPath(path)) return bad(diag, line_no, "bad path");
        const qpath = std.fmt.parseInt(u64, f[1], 16) catch return bad(diag, line_no, "bad qid.path");
        const vers = std.fmt.parseInt(u32, f[2], 10) catch return bad(diag, line_no, "bad qid.vers");
        if (f[3].len != 1) return bad(diag, line_no, "bad qid.type");
        const mode = std.fmt.parseInt(u32, f[4], 8) catch return bad(diag, line_no, "bad mode");
        const length = std.fmt.parseInt(u64, f[5], 10) catch return bad(diag, line_no, "bad length");
        const mtime = std.fmt.parseInt(u32, f[6], 10) catch return bad(diag, line_no, "bad mtime");
        if (f[7].len == 0 or f[8].len == 0) return bad(diag, line_no, "empty user");
        if (!std.unicode.utf8ValidateSlice(f[7]) or !std.unicode.utf8ValidateSlice(f[8])) return bad(diag, line_no, "bad user");
        // The type letter and the mode's DM bits agree.
        const ok = switch (f[3][0]) {
            'd' => mode & DMDIR != 0,
            'a' => mode & (DMDIR | DMAPPEND) == DMAPPEND,
            'l' => mode & (DMDIR | DMEXCL) == DMEXCL,
            '-' => mode & (DMDIR | DMAPPEND | DMEXCL) == 0,
            else => return bad(diag, line_no, "bad qid.type"),
        };
        if (!ok) return bad(diag, line_no, "qid.type doesn't match mode");
        const is_root = std.mem.eql(u8, path, "/");
        if (raws.items.len == 0 and (!is_root or mode & DMDIR == 0)) return bad(diag, line_no, "the first entry isn't the root directory");
        if (raws.items.len > 0 and is_root) return bad(diag, line_no, "duplicate path");
        if (by_path.contains(path)) return bad(diag, line_no, "duplicate path");
        if (raws.items.len >= std.math.maxInt(u32) - 1) return bad(diag, line_no, "too many entries");
        const idx: u32 = @intCast(raws.items.len);
        var parent: u32 = 0;
        var name: []const u8 = "/";
        if (!is_root) {
            const slash = std.mem.lastIndexOfScalar(u8, path, '/').?;
            const ppath = if (slash == 0) "/" else path[0..slash];
            parent = by_path.get(ppath) orelse return bad(diag, line_no, "parent isn't an earlier directory");
            if (raws.items[parent].qid.type & QTDIR == 0) return bad(diag, line_no, "parent isn't an earlier directory");
            name = path[slash + 1 ..];
        }
        try raws.append(arena, .{
            .path = path,
            .name = name,
            // qid.type is the mode's top byte, as 9P has it.
            .qid = .{ .path = qpath, .vers = vers, .type = @truncate(mode >> 24) },
            .mode = mode,
            .length = length,
            .mtime = mtime,
            .uid = f[7],
            .gid = f[8],
            .parent = parent,
        });
        try by_path.put(arena, path, idx);
        if (!is_root) try raws.items[parent].children.append(arena, idx);
    }
    if (raws.items.len == 0) {
        diag.* = .{ .line = line_no, .msg = "no root entry" };
        return error.BadIndex;
    }
    return layout(gpa, arena, raws.items);
}

/// A path as the format has it: absolute, no empty, `.`, or `..`
/// elements, no trailing slash but the root's, and valid UTF-8.
fn validPath(p: []const u8) bool {
    if (p.len == 0 or p[0] != '/') return false;
    if (!std.unicode.utf8ValidateSlice(p)) return false;
    if (p.len == 1) return true;
    var it = std.mem.splitScalar(u8, p[1..], '/');
    while (it.next()) |e| {
        if (e.len == 0 or std.mem.eql(u8, e, ".") or std.mem.eql(u8, e, "..")) return false;
        for (e) |c| if (c < 0x20 or c == 0x7f) return false;
    }
    return true;
}

fn nameLess(raws: []const Raw, a: u32, b: u32) bool {
    return std.mem.order(u8, raws[a].name, raws[b].name) == .lt;
}

fn layout(gpa: Allocator, arena: Allocator, raws: []Raw) CompileError![]u8 {
    // Breadth first, so each directory's children are contiguous.
    var order: std.ArrayList(u32) = try .initCapacity(arena, raws.len);
    order.appendAssumeCapacity(0);
    var at: usize = 0;
    while (at < order.items.len) : (at += 1) {
        const r = &raws[order.items[at]];
        std.mem.sortUnstable(u32, r.children.items, @as([]const Raw, raws), nameLess);
        try order.appendSlice(arena, r.children.items);
    }
    for (order.items, 0..) |ri, slot| raws[ri].slot = @intCast(slot);

    var users: std.StringArrayHashMapUnmanaged(void) = .empty;
    var names_len: usize = 0;
    for (raws) |*r| {
        try users.put(arena, r.uid, {});
        try users.put(arena, r.gid, {});
        names_len += r.name.len;
    }
    var users_len: usize = 0;
    for (users.keys()) |u| users_len += u.len;
    const strings_len = names_len + users_len;
    const n = raws.len;
    const nusers = users.count();
    const total = header_size + n * entry_size + nusers * 8 + strings_len + trailer_size;
    if (strings_len > std.math.maxInt(u32) or total > std.math.maxInt(u32)) return error.TooBig;
    const out = try gpa.alloc(u8, total);
    errdefer gpa.free(out);
    @memset(out, 0);
    const ent_at = header_size;
    const users_at = ent_at + n * entry_size;
    const strings_at = users_at + nusers * 8;

    var ndirs: u32 = 0;
    var soff: u32 = 0;
    // Users first, then names in entry order.
    for (users.keys(), 0..) |u, i| {
        put32(out, users_at + i * 8, soff);
        put32(out, users_at + i * 8 + 4, @intCast(u.len));
        @memcpy(out[strings_at + soff ..][0..u.len], u);
        soff += @intCast(u.len);
    }
    for (order.items, 0..) |ri, slot| {
        const r = &raws[ri];
        const e = ent_at + slot * entry_size;
        put64(out, e + 0, r.qid.path);
        put32(out, e + 8, r.qid.vers);
        out[e + 12] = r.qid.type;
        out[e + 13] = if (r.unindexed) flag_unindexed else 0;
        put32(out, e + 16, r.mode);
        put32(out, e + 20, r.mtime);
        put64(out, e + 24, r.length);
        put32(out, e + 32, @intCast(users.getIndex(r.uid).?));
        put32(out, e + 36, @intCast(users.getIndex(r.gid).?));
        put32(out, e + 40, soff);
        put32(out, e + 44, @intCast(r.name.len));
        @memcpy(out[strings_at + soff ..][0..r.name.len], r.name);
        soff += @intCast(r.name.len);
        put32(out, e + 48, raws[r.parent].slot);
        if (r.children.items.len > 0) {
            put32(out, e + 52, raws[r.children.items[0]].slot);
            put32(out, e + 56, @intCast(r.children.items.len));
        }
        if (r.qid.type & QTDIR != 0) ndirs += 1;
    }
    @memcpy(out[0..8], compiled_magic);
    put32(out, 8, compiled_version);
    put32(out, 12, @intCast(n));
    put32(out, 16, @intCast(nusers));
    put32(out, 20, @intCast(strings_len));
    put32(out, 24, ndirs);
    Sha256.hash(out[0 .. total - trailer_size], out[total - trailer_size ..][0..trailer_size], .{});
    return out;
}

fn put32(b: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, b[at..][0..4], v, .little);
}

fn put64(b: []u8, at: usize, v: u64) void {
    std.mem.writeInt(u64, b[at..][0..8], v, .little);
}

fn get32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

fn get64(b: []const u8, at: usize) u64 {
    return std.mem.readInt(u64, b[at..][0..8], .little);
}

pub const LoadError = error{ BadCompiled, OutOfMemory };

/// A compiled index, checked. It reads through `bytes`, which the caller
/// keeps alive (and `deinit` frees, when `owned`).
pub const Index = struct {
    bytes: []const u8,
    n: u32,
    nusers: u32,
    ndirs: u32,
    users_at: usize,
    strings_at: usize,
    strings_len: usize,
    owned: bool = false,

    /// Checks a compiled index: its trailer, then every count and offset
    /// against the buffer, and the tree's shape, so nothing read through
    /// it afterwards can go out of bounds or loop.
    pub fn init(bytes: []const u8) LoadError!Index {
        if (bytes.len < header_size + entry_size + trailer_size) return error.BadCompiled;
        if (!std.mem.eql(u8, bytes[0..8], compiled_magic) or get32(bytes, 8) != compiled_version) return error.BadCompiled;
        var sum: [trailer_size]u8 = undefined;
        Sha256.hash(bytes[0 .. bytes.len - trailer_size], &sum, .{});
        if (!std.mem.eql(u8, &sum, bytes[bytes.len - trailer_size ..])) return error.BadCompiled;
        const n = get32(bytes, 12);
        const nusers = get32(bytes, 16);
        const strings_len = get32(bytes, 20);
        const want = @as(u64, header_size) + @as(u64, n) * entry_size + @as(u64, nusers) * 8 + strings_len + trailer_size;
        if (n == 0 or want != bytes.len) return error.BadCompiled;
        var ix: Index = .{
            .bytes = bytes,
            .n = n,
            .nusers = nusers,
            .ndirs = 0,
            .users_at = header_size + @as(usize, n) * entry_size,
            .strings_at = header_size + @as(usize, n) * entry_size + @as(usize, nusers) * 8,
            .strings_len = strings_len,
        };
        for (0..nusers) |u| {
            const off = get32(bytes, ix.users_at + u * 8);
            const len = get32(bytes, ix.users_at + u * 8 + 4);
            if (@as(u64, off) + len > strings_len) return error.BadCompiled;
        }
        var ndirs: u32 = 0;
        // Children come after their parent, so following them ends.
        for (0..n) |i| {
            const e = ix.entryAt(@intCast(i));
            if (@as(u64, get32(bytes, e + 40)) + get32(bytes, e + 44) > strings_len) return error.BadCompiled;
            if (get32(bytes, e + 32) >= nusers or get32(bytes, e + 36) >= nusers) return error.BadCompiled;
            const par = get32(bytes, e + 48);
            if (par >= n or (i != 0 and par >= i) or (i == 0 and par != 0)) return error.BadCompiled;
            const first = get32(bytes, e + 52);
            const count = get32(bytes, e + 56);
            const is_dir = bytes[e + 12] & QTDIR != 0;
            if (i == 0 and !is_dir) return error.BadCompiled;
            if (is_dir) ndirs += 1;
            if (count == 0) continue;
            if (!is_dir or first <= i or @as(u64, first) + count > n) return error.BadCompiled;
            var prev: ?[]const u8 = null;
            for (first..first + count) |c| {
                if (get32(bytes, ix.entryAt(@intCast(c)) + 48) != i) return error.BadCompiled;
                const nm = ix.name(@intCast(c));
                if (nm.len == 0) return error.BadCompiled;
                if (prev) |p| if (std.mem.order(u8, p, nm) != .lt) return error.BadCompiled;
                prev = nm;
            }
        }
        // Every entry but the root is some directory's child exactly once:
        // children ranges are disjoint and each child names its parent, so
        // counting them is enough.
        var nchildren: u64 = 0;
        for (0..n) |i| nchildren += get32(bytes, ix.entryAt(@intCast(i)) + 56);
        if (nchildren != n - 1) return error.BadCompiled;
        if (ndirs != get32(bytes, 24)) return error.BadCompiled;
        ix.ndirs = ndirs;
        return ix;
    }

    pub fn deinit(ix: *Index, gpa: Allocator) void {
        if (ix.owned) gpa.free(ix.bytes);
        ix.* = undefined;
    }

    fn entryAt(_: *const Index, i: u32) usize {
        return header_size + @as(usize, i) * entry_size;
    }

    fn str(ix: *const Index, off: u32, len: u32) []const u8 {
        return ix.bytes[ix.strings_at + off ..][0..len];
    }

    pub fn name(ix: *const Index, i: u32) []const u8 {
        const e = ix.entryAt(i);
        return ix.str(get32(ix.bytes, e + 40), get32(ix.bytes, e + 44));
    }

    fn user(ix: *const Index, u: u32) []const u8 {
        return ix.str(get32(ix.bytes, ix.users_at + u * 8), get32(ix.bytes, ix.users_at + u * 8 + 4));
    }

    pub fn qid(ix: *const Index, i: u32) wire.Qid {
        const e = ix.entryAt(i);
        return .{ .path = get64(ix.bytes, e), .vers = get32(ix.bytes, e + 8), .type = ix.bytes[e + 12] };
    }

    pub fn mtime(ix: *const Index, i: u32) u32 {
        return get32(ix.bytes, ix.entryAt(i) + 20);
    }

    pub fn isDir(ix: *const Index, i: u32) bool {
        return ix.bytes[ix.entryAt(i) + 12] & QTDIR != 0;
    }

    /// A directory `mkindex` couldn't list whole: never answered for.
    pub fn unindexed(ix: *const Index, i: u32) bool {
        return ix.bytes[ix.entryAt(i) + 13] & flag_unindexed != 0;
    }

    pub fn parent(ix: *const Index, i: u32) u32 {
        return get32(ix.bytes, ix.entryAt(i) + 48);
    }

    /// The first child and how many, for a directory.
    pub fn children(ix: *const Index, i: u32) struct { first: u32, count: u32 } {
        const e = ix.entryAt(i);
        return .{ .first = get32(ix.bytes, e + 52), .count = get32(ix.bytes, e + 56) };
    }

    /// The child of directory `dir` called `nm`, by binary search.
    pub fn lookup(ix: *const Index, d: u32, nm: []const u8) ?u32 {
        const c = ix.children(d);
        var lo: u32 = c.first;
        var hi: u32 = c.first + c.count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, ix.name(mid), nm)) {
                .eq => return mid,
                .lt => lo = mid + 1,
                .gt => hi = mid,
            }
        }
        return null;
    }

    /// Entry `i` as a stat(5) Dir; its strings point into the index.
    pub fn dir(ix: *const Index, i: u32) attr.Dir {
        const e = ix.entryAt(i);
        const q = ix.qid(i);
        const mt = get32(ix.bytes, e + 20);
        const uid = ix.user(get32(ix.bytes, e + 32));
        return .{
            .type = 0,
            .dev = 0,
            .qid_type = q.type,
            .qid_vers = q.vers,
            .qid_path = q.path,
            .mode = get32(ix.bytes, e + 16),
            .atime = mt,
            .mtime = mt,
            .length = if (q.type & QTDIR != 0) 0 else get64(ix.bytes, e + 24),
            .name = ix.name(i),
            .uid = uid,
            .gid = ix.user(get32(ix.bytes, e + 36)),
            .muid = uid,
        };
    }

    /// The names from the root to entry `i`, into `out`, root first;
    /// null if they don't fit.
    pub fn pathNames(ix: *const Index, i: u32, out: [][]const u8) ?[][]const u8 {
        const n = ix.depth(i);
        if (n > out.len) return null;
        var at = i;
        var k = n;
        while (at != root) : (at = ix.parent(at)) {
            k -= 1;
            out[k] = ix.name(at);
        }
        return out[0..n];
    }

    pub fn depth(ix: *const Index, i: u32) usize {
        var d: usize = 0;
        var at = i;
        while (at != root) : (at = ix.parent(at)) d += 1;
        return d;
    }
};

/// The deepest tree the layer handles: a path's names must fit here.
pub const max_depth = 256;

const t = std.testing;

const sample =
    \\h9index 1
    \\/ 0000000000000001 7 d 020000000775 0 1730851200 sys sys
    \\/bin 0000000000000002 3 d 020000000775 0 1730851200 sys sys
    \\/bin/ls 0000000000002a1f 3 - 0775 81920 1730851200 glenda sys
    \\/bin/cat 0000000000002a20 1 - 0775 4096 1730851201 glenda sys
    \\/lib 0000000000000003 0 d 020000000775 0 1730851200 sys sys
    \\/lib/log 0000000000000004 0 a 010000000664 12 1730851200 sys sys
    \\!unindexed /lib
    \\
;

test "compile and look up the sample [mount-index]" {
    var d: Diag = .{};
    const b = try compile(t.allocator, sample, &d);
    defer t.allocator.free(b);
    var ix = try Index.init(b);
    try t.expectEqual(@as(u32, 6), ix.n);
    try t.expectEqual(@as(u32, 3), ix.ndirs);
    const bin = ix.lookup(root, "bin").?;
    try t.expect(ix.isDir(bin));
    try t.expect(!ix.unindexed(bin));
    try t.expect(ix.unindexed(ix.lookup(root, "lib").?));
    try t.expectEqual(@as(?u32, null), ix.lookup(root, "usr"));
    const ls = ix.lookup(bin, "ls").?;
    const dls = ix.dir(ls);
    try t.expectEqualStrings("ls", dls.name);
    try t.expectEqualStrings("glenda", dls.uid);
    try t.expectEqualStrings("sys", dls.gid);
    try t.expectEqual(@as(u64, 0x2a1f), dls.qid_path);
    try t.expectEqual(@as(u32, 3), dls.qid_vers);
    try t.expectEqual(@as(u64, 81920), dls.length);
    try t.expectEqual(@as(u32, 0o775), dls.mode);
    // Children are sorted: cat before ls.
    const c = ix.children(bin);
    try t.expectEqualStrings("cat", ix.name(c.first));
    var buf: [8][]const u8 = undefined;
    const p = ix.pathNames(ls, &buf).?;
    try t.expectEqual(@as(usize, 2), p.len);
    try t.expectEqualStrings("bin", p[0]);
    const log = ix.lookup(ix.lookup(root, "lib").?, "log").?;
    try t.expectEqual(QTAPPEND, ix.qid(log).type);
    const rd = ix.dir(root);
    try t.expectEqualStrings("/", rd.name);
    try t.expectEqual(DMDIR | 0o775, rd.mode);
}

test "a malformed index is refused with its line [mount-index]" {
    const cases = [_]struct { text: []const u8, line: usize }{
        .{ .text = "h9index 1\n/bin 1 0 d 020000000775 0 0 a b\n", .line = 2 },
        .{ .text = "h9index 1\n/ 1 0 d 020000000775 0 0 a b\n/x/y 2 0 - 0644 0 0 a b\n", .line = 3 },
        .{ .text = "h9index 1\n/ 1 0 d 020000000775 0 0 a b\n/f 2 0 d 0644 0 0 a b\n", .line = 3 },
        .{ .text = "h9index 1\n/ 1 0 d 020000000775 0 0 a b\n/f 2 0 - 0644 0 0 a\n", .line = 3 },
        .{ .text = "h9index 1\n/ 1 0 d 020000000775 0 0 a b\n/f 2 0 - 0644 0 0 a b c\n", .line = 3 },
        .{ .text = "h9index 1\n/ 1 0 d 020000000775 0 0 a b\n/f  2 0 - 0644 0 0 a b\n", .line = 3 },
        .{ .text = "h9index 1\n/ 1 0 d 020000000775 0 0 a b\n/f zz 0 - 0644 0 0 a b\n", .line = 3 },
        .{ .text = "h9index 1\n/ 1 0 d 020000000775 0 0 a b\n/f 2 0 - 0644 0 0 a b\n/f 3 0 - 0644 0 0 a b\n", .line = 4 },
        .{ .text = "h9index 1\n/ 1 0 d 020000000775 0 0 a b\n/f 2 0 - 0644 0 0 a b\n!unindexed /f\n", .line = 4 },
        .{ .text = "h9index 1\n/ 1 0 d 020000000775 0 0 a b\n/a/../b 2 0 - 0644 0 0 a b\n", .line = 3 },
        .{ .text = "h9index 1\n/ 1 0 d 020000000775 0 0 a b\n\n/f 2 0 - 0644 0 0 a b\n", .line = 3 },
        .{ .text = "h9index 1\n/ 1 0 d 020000000775 0 0 a b\n/\xff 2 0 - 0644 0 0 a b\n", .line = 3 },
        .{ .text = "not an index\n", .line = 1 },
        .{ .text = "h9index 1\n", .line = 2 },
    };
    for (cases) |c| {
        var d: Diag = .{};
        try t.expectError(error.BadIndex, compile(t.allocator, c.text, &d));
        try t.expectEqual(c.line, d.line);
    }
    var d: Diag = .{};
    try t.expectError(error.UnknownVersion, compile(t.allocator, "h9index 2\n/ 1 0 d 020000000775 0 0 a b\n", &d));
}

test "a corrupted compiled index is refused [mount-index]" {
    var d: Diag = .{};
    const b = try compile(t.allocator, sample, &d);
    defer t.allocator.free(b);
    // Any flipped byte fails the trailer.
    for ([_]usize{ 0, 9, 13, header_size + 3, b.len - 1, b.len / 2 }) |at| {
        b[at] ^= 0x40;
        try t.expectError(error.BadCompiled, Index.init(b));
        b[at] ^= 0x40;
    }
    try t.expectError(error.BadCompiled, Index.init(b[0 .. b.len - 1]));
    // A forged entry with a good trailer is still refused: a child range
    // past the end.
    const e = header_size + entry_size;
    put32(b, e + 56, 1000);
    Sha256.hash(b[0 .. b.len - trailer_size], b[b.len - trailer_size ..][0..trailer_size], .{});
    try t.expectError(error.BadCompiled, Index.init(b));
}

test {
    _ = layer;
    _ = cache;
}
