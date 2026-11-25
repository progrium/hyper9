//! The mount flags (design/epoch-0/mounts.md): `--dir`, `--url`, `--archive`,
//! `--builtin`, and `--tmp` bring a tree in from outside the machine, and
//! `--bind` rearranges what's already inside. Each is `SRC[:DST[:OPTS]]`,
//! or the long form `src=…,dst=…,…`, and each becomes lines of the plan.
//! Parsing is pure; the CLI resolves host paths, and the policy compiles
//! mounts into the plan.

const std = @import("std");

pub const Kind = enum {
    /// A host directory or file, through `#U`.
    dir,
    /// A 9P server (`tcp://`, `unix://`, `ws://`, `wss://`), or a URL
    /// that probes for one (`http://`, `https://`, or no scheme).
    url,
    /// A tar, gzipped tar, or `.h9a`, unpacked into memory.
    archive,
    /// The built-in root, `#Hroot`.
    builtin,
    /// An empty tree in memory.
    tmp,
    /// A 9P connection the embedder already holds, as a host descriptor
    /// (Machine.Options only, design/epoch-0/fd-mounts.md).
    fd,

    pub fn flag(k: Kind) []const u8 {
        return switch (k) {
            .dir => "--dir",
            .url => "--url",
            .archive => "--archive",
            .builtin => "--builtin",
            .tmp => "--tmp",
            .fd => "fd",
        };
    }
};

/// How a mount can be changed. `up` makes it the writable layer over
/// what's beneath it (design/epoch-0/upper-layers.md).
pub const Access = enum { ro, rw, eph, up };

/// Where a mount goes relative to what's at DST.
pub const Order = enum { before, after };

/// The two stacks (design/epoch-0/mounts.md, "Stacks").
pub const Stack = enum {
    /// `/`: the 9front root stack, `#Oroot`.
    root,
    /// `#L`: the Linux tree's stack, `#Olinux`.
    linux,

    pub fn dev(s: Stack) []const u8 {
        return switch (s) {
            .root => "#Oroot",
            .linux => "#Olinux",
        };
    }

    pub fn name(s: Stack) [:0]const u8 {
        return switch (s) {
            .root => "root",
            .linux => "linux",
        };
    }
};

pub const Mount = struct {
    kind: Kind,
    /// The host path (resolved by the CLI for `--dir`), URL, or archive
    /// file. Empty for `--builtin` and `--tmp`.
    src: []const u8 = "",
    /// An `.fd` mount's connection (design/epoch-0/fd-mounts.md): a descriptor
    /// in the host process, a POSIX fd or a Windows `HANDLE`, read from
    /// and, without `fd_write`, written to. h9 duplicates it for each run,
    /// and the embedder keeps it.
    fd: ?std.posix.fd_t = null,
    /// The descriptor written to, for a pipe pair. Null for a socket or a
    /// duplex pipe.
    fd_write: ?std.posix.fd_t = null,
    /// A guest path, `#L`, or a path under `#L`.
    dst: []const u8 = "/",
    access: ?Access = null,
    order: ?Order = null,
    create: bool = false,
    recursive: bool = false,
    /// `--dir` only: symlinks resolve inside the tree. Always on under `#L`.
    contained: bool = false,
    /// `--url` settings.
    spec: ?[]const u8 = null,
    user: ?[]const u8 = null,
    auth: ?[]const u8 = null,
    index: ?[]const u8 = null,
    /// `header=` values as given: `Name: value`, or `@FILE`.
    headers: []const []const u8 = &.{},
    ca: ?[]const u8 = null,

    /// The stack this mount joins, and the path under the stack's top it's
    /// rooted at ("" for the top), or null for any other destination.
    pub fn stack(m: Mount) ?struct { Stack, []const u8 } {
        if (std.mem.eql(u8, m.dst, "/")) return .{ .root, "" };
        if (std.mem.eql(u8, m.dst, "#L")) return .{ .linux, "" };
        if (std.mem.startsWith(u8, m.dst, "#L/")) return .{ .linux, std.mem.trim(u8, m.dst[2..], "/") };
        return null;
    }

    /// The name of the `/srv` entry a `--url` posts without mounting
    /// (`/srv/NAME`), or null.
    pub fn srvName(m: Mount) ?[]const u8 {
        if (m.kind != .url and m.kind != .fd) return null;
        const p = "/srv/";
        if (!std.mem.startsWith(u8, m.dst, p) or m.dst.len == p.len) return null;
        const n = m.dst[p.len..];
        if (std.mem.indexOfScalar(u8, n, '/') != null) return null;
        return n;
    }

    /// Writes the mount as its flag would take it, short options and all.
    pub fn format(m: Mount, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s} {s}", .{ m.kind.flag(), m.src });
        if (m.src.len > 0) try w.writeAll(":");
        try w.writeAll(m.dst);
    }

    /// Parses a mount flag's value. `--builtin` and `--tmp` take no SRC:
    /// their value is `DST[:OPTS]`, and `--builtin`'s may be empty. `why`
    /// explains a usage error.
    pub fn parse(arena: std.mem.Allocator, kind: Kind, arg: []const u8, why: *[]const u8) ParseError!Mount {
        var m: Mount = .{ .kind = kind };
        var opts: []const u8 = "";
        if (std.mem.startsWith(u8, arg, "src=") or ((kind == .builtin or kind == .tmp) and std.mem.startsWith(u8, arg, "dst="))) {
            try m.long(arena, arg, why);
        } else {
            const has_src = kind != .builtin and kind != .tmp;
            var dst_part: []const u8 = "";
            if (has_src) {
                if (dstStart(arg)) |i| {
                    m.src = arg[0..i];
                    dst_part = arg[i + 1 ..];
                } else m.src = arg;
            } else dst_part = arg;
            if (dst_part.len > 0) {
                const colon = std.mem.indexOfScalar(u8, dst_part, ':');
                m.dst = if (colon) |c| dst_part[0..c] else dst_part;
                opts = if (colon) |c| dst_part[c + 1 ..] else "";
            } else if (kind == .tmp) {
                why.* = "--tmp needs a destination";
                return error.Usage;
            } else if (kind == .builtin) {
                // With no destination, the built-in root is the bottom of /.
                m.order = .after;
            }
            var it = std.mem.splitScalar(u8, opts, ',');
            while (it.next()) |o| if (o.len > 0) try m.option(arena, o, why);
        }
        try m.check(why);
        return m;
    }

    /// The long form: comma-separated `key=value` fields, a field in
    /// double quotes holding commas.
    fn long(m: *Mount, arena: std.mem.Allocator, arg: []const u8, why: *[]const u8) ParseError!void {
        var fields = try csv(arena, arg);
        _ = &fields;
        for (fields) |f| {
            if (std.mem.startsWith(u8, f, "src=")) {
                m.src = f[4..];
            } else if (std.mem.startsWith(u8, f, "dst=")) {
                m.dst = f[4..];
            } else try m.option(arena, f, why);
        }
    }

    fn option(m: *Mount, arena: std.mem.Allocator, o: []const u8, why: *[]const u8) ParseError!void {
        const Flagged = struct { []const u8, []const u8 };
        const words = [_]Flagged{
            .{ "ro", "readonly" },   .{ "rw", "readwrite" }, .{ "eph", "ephemeral" },
            .{ "up", "upper" },      .{ "b", "before" },     .{ "a", "after" },
            .{ "c", "create" },      .{ "r", "recursive" },  .{ "contained", "contained" },
        };
        for (words, 0..) |wd, i| if (std.mem.eql(u8, o, wd[0]) or std.mem.eql(u8, o, wd[1])) {
            switch (i) {
                0, 1, 2, 3 => {
                    const a: Access = @enumFromInt(i);
                    if (m.access != null and m.access.? != a) return conflict(why, "conflicting options ro, rw, eph, and up");
                    m.access = a;
                },
                4, 5 => {
                    const ord: Order = if (i == 4) .before else .after;
                    if (m.order != null and m.order.? != ord) return conflict(why, "conflicting options b and a");
                    m.order = ord;
                },
                6 => m.create = true,
                7 => m.recursive = true,
                8 => {
                    if (m.kind != .dir) return conflict(why, "contained is for --dir only");
                    m.contained = true;
                },
                else => unreachable,
            }
            return;
        };
        const eq = std.mem.indexOfScalar(u8, o, '=') orelse return conflict(why, try std.fmt.allocPrint(arena, "unknown option '{s}'", .{o}));
        const key = o[0..eq];
        const val = o[eq + 1 ..];
        if (val.len == 0) return conflict(why, try std.fmt.allocPrint(arena, "{s}= needs a value", .{key}));
        if (std.mem.eql(u8, key, "header")) {
            const list = try arena.alloc([]const u8, m.headers.len + 1);
            @memcpy(list[0..m.headers.len], m.headers);
            list[m.headers.len] = val;
            m.headers = list;
            return;
        }
        const slot: *?[]const u8 = if (std.mem.eql(u8, key, "spec"))
            &m.spec
        else if (std.mem.eql(u8, key, "user"))
            &m.user
        else if (std.mem.eql(u8, key, "auth"))
            &m.auth
        else if (std.mem.eql(u8, key, "index"))
            &m.index
        else if (std.mem.eql(u8, key, "ca"))
            &m.ca
        else
            return conflict(why, try std.fmt.allocPrint(arena, "unknown setting '{s}='", .{key}));
        slot.* = val;
    }

    /// The checks that need every option: what each kind and scheme takes.
    fn check(m: *Mount, why: *[]const u8) ParseError!void {
        if (m.dst.len == 0 or (m.dst[0] != '/' and m.dst[0] != '#')) return conflict(why, "the destination must be a guest path or #L");
        if (m.dst[0] == '#' and m.stack() == null) return conflict(why, "the only device destination is #L");
        if ((m.kind == .dir or m.kind == .url or m.kind == .archive) and m.src.len == 0) return conflict(why, "no source");
        // A layer has to be written: an archive and the built-in root never are.
        if (m.access == .up and (m.kind == .archive or m.kind == .builtin)) return conflict(why, "up needs a tree that can be written: a --dir, --url, or --tmp");
        const url_only = m.spec != null or m.user != null or m.auth != null or m.index != null;
        if (url_only and m.kind != .url and m.kind != .fd) return conflict(why, "spec=, user=, auth=, and index= are for --url");
        if (m.headers.len > 0 or m.ca != null) {
            const s = scheme(m.src);
            const web_scheme = m.kind == .url and (s == null or eqAny(s.?, &.{ "ws", "wss", "http", "https" }));
            if (!web_scheme) return conflict(why, "header= and ca= are for ws, wss, http, and https URLs");
            if (m.ca != null and s != null and !eqAny(s.?, &.{ "wss", "https" })) return conflict(why, "ca= is for wss and https URLs");
        }
        if (m.srvName() == null and std.mem.startsWith(u8, m.dst, "/srv/") and m.kind == .url) return conflict(why, "a /srv destination is /srv/NAME");
        if (m.kind == .url) {
            if (scheme(m.src)) |s| {
                if (!eqAny(s, &.{ "tcp", "unix", "ws", "wss", "http", "https", "port" })) return conflict(why, "a URL is tcp://, unix://, ws://, wss://, http://, https://, or port://");
            } else if (std.mem.indexOfScalar(u8, m.src, '!') != null) {
                return conflict(why, "dial strings aren't URLs: use tcp://HOST:PORT or unix:///PATH");
            }
        }
    }
};

pub const ParseError = error{ Usage, OutOfMemory };

fn conflict(why: *[]const u8, msg: []const u8) ParseError {
    why.* = msg;
    return error.Usage;
}

fn eqAny(s: []const u8, list: []const []const u8) bool {
    for (list) |l| if (std.mem.eql(u8, s, l)) return true;
    return false;
}

/// A URL's scheme, if `s` starts with one and `://`.
pub fn scheme(s: []const u8) ?[]const u8 {
    const i = std.mem.indexOf(u8, s, "://") orelse return null;
    if (i == 0) return null;
    for (s[0..i]) |c| if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return null;
    return s[0..i];
}

/// Where DST starts: the last `:` followed by `/` or `#`, except the
/// `://` after a URL's scheme and a Windows drive letter's `:`
/// (design/epoch-0/mounts.md, "Parsing"). Null if there's none.
pub fn dstStart(arg: []const u8) ?usize {
    const skip: ?usize = if (scheme(arg)) |s| s.len else null;
    var i = arg.len;
    while (i > 0) {
        i -= 1;
        if (arg[i] != ':' or i + 1 >= arg.len) continue;
        if (arg[i + 1] != '/' and arg[i + 1] != '#') continue;
        if (skip != null and i == skip.?) continue;
        // C:/roots/9front
        if (i == 1 and std.ascii.isAlphabetic(arg[0])) continue;
        return i;
    }
    return null;
}

/// Splits the long form's comma-separated fields, honouring double quotes
/// (`""` inside quotes is a quote), as CSV does.
fn csv(arena: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var cur: std.ArrayList(u8) = .empty;
    var quoted = false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '"') {
            if (quoted and i + 1 < s.len and s[i + 1] == '"') {
                try cur.append(arena, '"');
                i += 1;
            } else quoted = !quoted;
        } else if (c == ',' and !quoted) {
            try out.append(arena, cur.items);
            cur = .empty;
        } else try cur.append(arena, c);
    }
    try out.append(arena, cur.items);
    return out.items;
}

/// A `--bind SRC:DST[:OPTS]`: SRC is a guest path or `#` device, and DST
/// a guest path. The options are b, a, c, and r.
pub const Bind = struct {
    src: []const u8,
    dst: []const u8,
    order: ?Order = null,
    create: bool = false,
    recursive: bool = false,

    pub fn parse(arg: []const u8, why: *[]const u8) ParseError!Bind {
        const i = dstStart(arg) orelse return conflict(why, "--bind needs SRC:DST");
        const rest = arg[i + 1 ..];
        const colon = std.mem.indexOfScalar(u8, rest, ':');
        var b: Bind = .{ .src = arg[0..i], .dst = if (colon) |c| rest[0..c] else rest };
        if (b.src.len == 0 or (b.src[0] != '/' and b.src[0] != '#')) return conflict(why, "--bind's source is a guest path or # device");
        if (b.dst.len == 0 or (b.dst[0] != '/' and b.dst[0] != '#')) return conflict(why, "--bind's destination is a guest path");
        var it = std.mem.splitScalar(u8, if (colon) |c| rest[c + 1 ..] else "", ',');
        while (it.next()) |o| {
            if (o.len == 0) continue;
            if (std.mem.eql(u8, o, "b") or std.mem.eql(u8, o, "before")) {
                if (b.order == .after) return conflict(why, "conflicting options b and a");
                b.order = .before;
            } else if (std.mem.eql(u8, o, "a") or std.mem.eql(u8, o, "after")) {
                if (b.order == .before) return conflict(why, "conflicting options b and a");
                b.order = .after;
            } else if (std.mem.eql(u8, o, "c") or std.mem.eql(u8, o, "create")) {
                b.create = true;
            } else if (std.mem.eql(u8, o, "r") or std.mem.eql(u8, o, "recursive")) {
                b.recursive = true;
            } else return conflict(why, "--bind takes the options b, a, c, and r");
        }
        return b;
    }
};

const t = std.testing;


test "a mount flag without DST mounts on /, and a URL's :// and a drive letter aren't separators [mounts]" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    const d = try Mount.parse(a, .dir, "./base", &why);
    try t.expectEqualStrings("./base", d.src);
    try t.expectEqualStrings("/", d.dst);
    const u = try Mount.parse(a, .url, "wss://reg.example/alpine:3.20:/", &why);
    try t.expectEqualStrings("wss://reg.example/alpine:3.20", u.src);
    try t.expectEqualStrings("/", u.dst);
    const p = try Mount.parse(a, .url, "ws://127.0.0.1:8564/alpine:3.20:#L", &why);
    try t.expectEqualStrings("ws://127.0.0.1:8564/alpine:3.20", p.src);
    try t.expectEqualStrings("#L", p.dst);
    const tc = try Mount.parse(a, .url, "tcp://127.0.0.1:5640", &why);
    try t.expectEqualStrings("tcp://127.0.0.1:5640", tc.src);
    try t.expectEqualStrings("/", tc.dst);
    const ux = try Mount.parse(a, .url, "unix:///tmp/fs.sock:/n/fs:spec=main", &why);
    try t.expectEqualStrings("unix:///tmp/fs.sock", ux.src);
    try t.expectEqualStrings("/n/fs", ux.dst);
    try t.expectEqualStrings("main", ux.spec.?);
    const win = try Mount.parse(a, .dir, "C:/roots/9front", &why);
    try t.expectEqualStrings("C:/roots/9front", win.src);
    try t.expectEqualStrings("/", win.dst);
    const wd = try Mount.parse(a, .dir, "C:/roots/9front:/n/x:ro", &why);
    try t.expectEqualStrings("C:/roots/9front", wd.src);
    try t.expectEqualStrings("/n/x", wd.dst);
    try t.expectEqual(Access.ro, wd.access.?);
    const opts = try Mount.parse(a, .dir, "./data:/app/data:rw,b,c", &why);
    try t.expectEqualStrings("/app/data", opts.dst);
    try t.expectEqual(Access.rw, opts.access.?);
    try t.expectEqual(Order.before, opts.order.?);
    try t.expect(opts.create);
    // Without an explicit DST, an option is part of the path.
    const no = try Mount.parse(a, .dir, "./base:ro", &why);
    try t.expectEqualStrings("./base:ro", no.src);
    const sub = try Mount.parse(a, .dir, "./etcfix:#L/etc", &why);
    try t.expectEqual(Stack.linux, sub.stack().?[0]);
    try t.expectEqualStrings("etc", sub.stack().?[1]);
    const tmp = try Mount.parse(a, .tmp, "/scratch", &why);
    try t.expectEqualStrings("/scratch", tmp.dst);
    const bi = try Mount.parse(a, .builtin, "", &why);
    try t.expectEqualStrings("/", bi.dst);
    const srv = try Mount.parse(a, .url, "tcp://fs:564:/srv/fs", &why);
    try t.expectEqualStrings("fs", srv.srvName().?);
}

test "the long src= form takes values with colons and quoted commas [mounts]" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var why: []const u8 = "";
    const m = try Mount.parse(arena.allocator(), .url, "src=wss://fs.example/9p,dst=/n/x:y,index=https://cdn.example/9p/.fs/index,\"header=Authorization: Bearer a,b\",header=@h", &why);
    try t.expectEqualStrings("wss://fs.example/9p", m.src);
    try t.expectEqualStrings("/n/x:y", m.dst);
    try t.expectEqualStrings("https://cdn.example/9p/.fs/index", m.index.?);
    try t.expectEqual(@as(usize, 2), m.headers.len);
    try t.expectEqualStrings("Authorization: Bearer a,b", m.headers[0]);
    try t.expectEqualStrings("@h", m.headers[1]);
}

test "conflicting options are a usage error [mounts]" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    for ([_]struct { Kind, []const u8 }{
        .{ .dir, "./x:/:ro,rw" },
        .{ .dir, "./x:/:b,a" },
        .{ .dir, "./x:/:eph,rw" },
        .{ .dir, "./x:/:spec=x" },
        .{ .dir, "./x:/:frob" },
        .{ .url, "tcp://h:564:/:ca=x.pem" },
        .{ .url, "tcp://h:564:/:header=A: b" },
        .{ .url, "tcp!h!564" },
        .{ .url, "ftp://h/x" },
        .{ .tmp, "" },
        .{ .archive, "./x.tgz:#c" },
        .{ .url, "ws://h/x:/:contained" },
    }) |c| try t.expectError(error.Usage, Mount.parse(a, c[0], c[1], &why));
    try t.expectEqual(Access.eph, (try Mount.parse(a, .dir, "./x:/:eph,ephemeral", &why)).access.?);
}

test "up and upper make a mount a writable layer, on a tree that can be written [upper-layers]" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    try t.expectEqual(Access.up, (try Mount.parse(a, .dir, "./app:#L:up", &why)).access.?);
    try t.expectEqual(Access.up, (try Mount.parse(a, .dir, "src=./app,dst=#L,upper", &why)).access.?);
    try t.expectEqual(Access.up, (try Mount.parse(a, .tmp, "#L:up", &why)).access.?);
    try t.expectEqual(Access.up, (try Mount.parse(a, .url, "tcp://h:564:/n/x:up", &why)).access.?);
    for ([_]struct { Kind, []const u8 }{
        .{ .dir, "./x:#L:up,ro" },
        .{ .dir, "./x:#L:up,rw" },
        .{ .dir, "./x:#L:eph,up" },
        .{ .archive, "./x.tar:#L:up" },
        .{ .builtin, "/:up" },
    }) |c| try t.expectError(error.Usage, Mount.parse(a, c[0], c[1], &why));
    try t.expectEqualStrings("A: b", (try Mount.parse(a, .url, "wss://h/x:/:header=A: b,ca=c.pem", &why)).headers[0]);
}

test "--bind SRC:DST:OPTS [mounts]" {
    var why: []const u8 = "";
    const b = try Bind.parse("/usr/glenda/proj/bin:/bin:b", &why);
    try t.expectEqualStrings("/usr/glenda/proj/bin", b.src);
    try t.expectEqualStrings("/bin", b.dst);
    try t.expectEqual(Order.before, b.order.?);
    const d = try Bind.parse("#c:/dev:a,c", &why);
    try t.expectEqualStrings("#c", d.src);
    try t.expect(d.create);
    try t.expectError(error.Usage, Bind.parse("/x:/y:b,a", &why));
    try t.expectError(error.Usage, Bind.parse("/x", &why));
    try t.expectError(error.Usage, Bind.parse("/x:/y:ro", &why));
}
