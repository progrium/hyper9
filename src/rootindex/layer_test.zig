//! Recorded-conversation tests for the index layer (design/mount-index.md):
//! devmnt's requests are fed in by hand, and the server is a 9P2000 tree
//! in memory that counts what it's sent.

const std = @import("std");
const wire = @import("../dotl/wire.zig");
const attr = @import("../dotl/attr.zig");
const ri = @import("../rootindex.zig");
const layer = @import("layer.zig");

const p9 = wire.p9;
const t = std.testing;
const gpa = t.allocator;

const Node = struct {
    name: []const u8,
    parent: u32,
    qid: wire.Qid,
    mode: u32,
    mtime: u32,
    data: std.ArrayList(u8) = .empty,
    removed: bool = false,
};

/// A 9P2000 server over a tree in memory.
const Server = struct {
    nodes: std.ArrayList(Node) = .empty,
    fids: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    counts: [256]u32 = @splat(0),
    next_path: u64 = 100,
    clock: u32 = 1000,
    arena: std.heap.ArenaAllocator = .init(gpa),
    /// Reads of /.h9index.
    index_reads: u32 = 0,

    fn init() !Server {
        var s: Server = .{};
        try s.nodes.append(gpa, .{ .name = "/", .parent = 0, .qid = .{ .type = wire.QTDIR, .path = 1 }, .mode = wire.DMDIR | 0o775, .mtime = s.clock });
        return s;
    }

    fn deinit(s: *Server) void {
        for (s.nodes.items) |*n| n.data.deinit(gpa);
        s.nodes.deinit(gpa);
        s.fids.deinit(gpa);
        s.arena.deinit();
    }

    fn total(s: *const Server) u32 {
        var n: u32 = 0;
        for (s.counts) |c| n += c;
        return n;
    }

    fn count(s: *const Server, comptime T: type) u32 {
        return s.counts[T.id];
    }

    fn reset(s: *Server) void {
        s.counts = @splat(0);
        s.index_reads = 0;
    }

    fn child(s: *const Server, dir: u32, name: []const u8) ?u32 {
        for (s.nodes.items, 0..) |n, i| if (!n.removed and i != 0 and n.parent == dir and std.mem.eql(u8, n.name, name)) return @intCast(i);
        return null;
    }

    /// Adds a file or directory at `path`, changing its directory.
    fn add(s: *Server, path: []const u8, dir: bool, data: []const u8) !u32 {
        const slash = std.mem.lastIndexOfScalar(u8, path, '/').?;
        const parent = if (slash == 0) 0 else s.lookupPath(path[0..slash]).?;
        s.clock += 1;
        s.next_path += 1;
        try s.nodes.append(gpa, .{
            .name = try s.arena.allocator().dupe(u8, path[slash + 1 ..]),
            .parent = parent,
            .qid = .{ .type = if (dir) wire.QTDIR else 0, .path = s.next_path },
            .mode = if (dir) wire.DMDIR | 0o775 else 0o664,
            .mtime = s.clock,
        });
        try s.nodes.items[s.nodes.items.len - 1].data.appendSlice(gpa, data);
        s.touch(parent);
        return @intCast(s.nodes.items.len - 1);
    }

    fn touch(s: *Server, i: u32) void {
        s.clock += 1;
        s.nodes.items[i].qid.vers += 1;
        s.nodes.items[i].mtime = s.clock;
    }

    fn lookupPath(s: *const Server, path: []const u8) ?u32 {
        var cur: u32 = 0;
        var it = std.mem.tokenizeScalar(u8, path, '/');
        while (it.next()) |n| cur = s.child(cur, n) orelse return null;
        return cur;
    }

    fn dirOf(s: *const Server, i: u32) attr.Dir {
        const n = &s.nodes.items[i];
        return .{ .type = 0, .dev = 0, .qid_type = n.qid.type, .qid_vers = n.qid.vers, .qid_path = n.qid.path, .mode = n.mode, .atime = n.mtime, .mtime = n.mtime, .length = if (n.qid.type & wire.QTDIR != 0) 0 else n.data.items.len, .name = n.name, .uid = "glenda", .gid = "sys" };
    }

    fn pathOf(s: *const Server, i: u32, buf: []u8) []const u8 {
        if (i == 0) return "/";
        var parts: [32][]const u8 = undefined;
        var k: usize = 0;
        var at = i;
        while (at != 0) : (at = s.nodes.items[at].parent) {
            parts[k] = s.nodes.items[at].name;
            k += 1;
        }
        var w: std.Io.Writer = .fixed(buf);
        while (k > 0) {
            k -= 1;
            w.print("/{s}", .{parts[k]}) catch unreachable;
        }
        return w.buffered();
    }

    /// The tree's index text, as mkindex writes it.
    fn indexText(s: *const Server) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        try out.writer.writeAll(ri.magic_line ++ "\n");
        // Breadth first is parent first, which is all the format needs.
        var order: std.ArrayList(u32) = .empty;
        defer order.deinit(gpa);
        try order.append(gpa, 0);
        var at: usize = 0;
        while (at < order.items.len) : (at += 1) {
            for (s.nodes.items, 0..) |n, i| if (!n.removed and i != 0 and n.parent == order.items[at] and !std.mem.eql(u8, n.name, ri.file_name)) try order.append(gpa, @intCast(i));
        }
        var pbuf: [512]u8 = undefined;
        for (order.items) |i| {
            const n = &s.nodes.items[i];
            const d = s.dirOf(i);
            const ty: u8 = if (n.qid.type & wire.QTDIR != 0) 'd' else '-';
            try out.writer.print("{s} {x:0>16} {d} {c} 0{o} {d} {d} glenda sys\n", .{ s.pathOf(i, &pbuf), n.qid.path, n.qid.vers, ty, n.mode, d.length, n.mtime });
        }
        return out.toOwnedSlice();
    }

    fn handle(s: *Server, frame: []const u8, out: *std.ArrayList(u8)) !void {
        const d = try wire.decode(p9.T, frame, 1 << 20, false);
        s.counts[frame[4]] += 1;
        var buf: [1 << 16]u8 = undefined;
        const r = s.answer(d.msg, &buf) catch |e| {
            const msg: []const u8 = switch (e) {
                error.NotFound => "file does not exist",
                error.BadFid => "unknown fid",
                else => "error",
            };
            return out.appendSlice(gpa, try wire.encode(&buf, d.tag, p9.Rerror{ .ename = msg }, null));
        };
        var fb: [1 << 17]u8 = undefined;
        const f = switch (r) {
            inline else => |m| try wire.encode(&fb, d.tag, m, null),
        };
        try out.appendSlice(gpa, f);
    }

    fn fid(s: *Server, f: u32) !u32 {
        const n = s.fids.get(f) orelse return error.BadFid;
        if (s.nodes.items[n].removed) return error.NotFound;
        return n;
    }

    fn answer(s: *Server, msg: p9.T, buf: []u8) !p9.R {
        switch (msg) {
            .Tversion => |v| return .{ .Rversion = .{ .msize = @min(v.msize, 8192 + 24), .version = "9P2000" } },
            .Tattach => |a| {
                try s.fids.put(gpa, a.fid, 0);
                return .{ .Rattach = .{ .qid = s.nodes.items[0].qid } };
            },
            .Twalk => |w| {
                var cur = try s.fid(w.fid);
                if (w.newfid != w.fid and s.fids.contains(w.newfid)) return error.FidInUse;
                var qids: [16]wire.Qid = undefined;
                const names = w.wnames.slice();
                for (names, 0..) |n, i| {
                    if (s.nodes.items[cur].qid.type & wire.QTDIR == 0) {
                        if (i == 0) return error.NotFound;
                        return .{ .Rwalk = .{ .wqids = .init(qids[0..i]) } };
                    }
                    cur = if (std.mem.eql(u8, n, "..")) s.nodes.items[cur].parent else s.child(cur, n) orelse {
                        if (i == 0) return error.NotFound;
                        return .{ .Rwalk = .{ .wqids = .init(qids[0..i]) } };
                    };
                    qids[i] = s.nodes.items[cur].qid;
                }
                try s.fids.put(gpa, w.newfid, cur);
                return .{ .Rwalk = .{ .wqids = .init(qids[0..names.len]) } };
            },
            .Tstat => |st| {
                const n = try s.fid(st.fid);
                return .{ .Rstat = .{ .stat = .{ .bytes = try s.dirOf(n).pack(buf) } } };
            },
            .Topen => |o| {
                const n = try s.fid(o.fid);
                if (o.mode & wire.OTRUNC != 0) {
                    s.nodes.items[n].data.items.len = 0;
                    s.touch(n);
                }
                return .{ .Ropen = .{ .qid = s.nodes.items[n].qid, .iounit = 0 } };
            },
            .Tcreate => |c| {
                const dir = try s.fid(c.fid);
                var pbuf: [512]u8 = undefined;
                var w: std.Io.Writer = .fixed(&pbuf);
                const pp = s.pathOf(dir, buf);
                try w.print("{s}/{s}", .{ if (dir == 0) "" else pp, c.name });
                const n = try s.add(w.buffered(), c.perm & wire.DMDIR != 0, "");
                try s.fids.put(gpa, c.fid, n);
                return .{ .Rcreate = .{ .qid = s.nodes.items[n].qid, .iounit = 0 } };
            },
            .Tread => |r| {
                const n = try s.fid(r.fid);
                const node = &s.nodes.items[n];
                if (node.qid.type & wire.QTDIR != 0) {
                    // Offsets count bytes of Dirs, as stat(5) has it.
                    var all: std.ArrayList(u8) = .empty;
                    defer all.deinit(gpa);
                    var db: [1024]u8 = undefined;
                    for (s.nodes.items, 0..) |c, i| if (!c.removed and i != 0 and c.parent == n) try all.appendSlice(gpa, try s.dirOf(@intCast(i)).pack(&db));
                    const off: usize = @intCast(@min(r.offset, all.items.len));
                    var end = off;
                    while (end < all.items.len) {
                        const sz = @as(usize, std.mem.readInt(u16, all.items[end..][0..2], .little)) + 2;
                        if (end + sz - off > r.count) break;
                        end += sz;
                    }
                    @memcpy(buf[0 .. end - off], all.items[off..end]);
                    return .{ .Rread = .{ .data = .{ .bytes = buf[0 .. end - off] } } };
                }
                if (std.mem.eql(u8, node.name, ri.file_name)) s.index_reads += 1;
                const off: usize = @intCast(@min(r.offset, node.data.items.len));
                const end = @min(node.data.items.len, off + r.count);
                @memcpy(buf[0 .. end - off], node.data.items[off..end]);
                return .{ .Rread = .{ .data = .{ .bytes = buf[0 .. end - off] } } };
            },
            .Twrite => |w| {
                const n = try s.fid(w.fid);
                try s.nodes.items[n].data.appendSlice(gpa, w.data.bytes);
                s.touch(n);
                return .{ .Rwrite = .{ .count = @intCast(w.data.bytes.len) } };
            },
            .Tclunk => |c| {
                if (s.fids.fetchRemove(c.fid) == null) return error.BadFid;
                return .{ .Rclunk = .{} };
            },
            .Tremove => |r| {
                const n = s.fids.get(r.fid) orelse return error.BadFid;
                _ = s.fids.remove(r.fid);
                s.nodes.items[n].removed = true;
                s.touch(s.nodes.items[n].parent);
                return .{ .Rremove = .{} };
            },
            .Twstat => return .{ .Rwstat = .{} },
            .Tflush => return .{ .Rflush = .{} },
            .Tauth => return error.NoAuth,
        }
    }
};

/// The cache, in memory.
const MemCache = struct {
    key: ?[]u8 = null,
    version: ?[]u8 = null,
    bytes: ?[]u8 = null,
    lookups: u32 = 0,

    fn deinit(c: *MemCache) void {
        for ([_]?[]u8{ c.key, c.version, c.bytes }) |b| if (b) |x| gpa.free(x);
    }

    fn hooks(c: *MemCache) layer.Hooks {
        return .{ .ctx = c, .lookup = lookup, .store = store };
    }

    fn lookup(ctx: ?*anyopaque, key: []const u8, version: []const u8) ?[]u8 {
        const c: *MemCache = @ptrCast(@alignCast(ctx.?));
        c.lookups += 1;
        if (c.key == null or !std.mem.eql(u8, c.key.?, key) or !std.mem.eql(u8, c.version.?, version)) return null;
        return gpa.dupe(u8, c.bytes.?) catch null;
    }

    fn store(ctx: ?*anyopaque, key: []const u8, version: []const u8, compiled: []const u8) void {
        const c: *MemCache = @ptrCast(@alignCast(ctx.?));
        c.deinit();
        c.key = gpa.dupe(u8, key) catch unreachable;
        c.version = gpa.dupe(u8, version) catch unreachable;
        c.bytes = gpa.dupe(u8, compiled) catch unreachable;
    }
};

/// devmnt, the layer, and the server, wired together.
const Rig = struct {
    srv: *Server,
    l: layer.Layer,
    out: std.ArrayList(u8) = .empty,
    next_tag: u16 = 1,

    /// A new connection to `srv`.
    fn init(srv: *Server, source: layer.Source, hooks: layer.Hooks) Rig {
        srv.fids.clearRetainingCapacity();
        return .{ .srv = srv, .l = .init(gpa, source, hooks) };
    }

    fn deinit(r: *Rig) void {
        r.l.deinit();
        r.out.deinit(gpa);
    }

    /// Runs the server until the layer has nothing more for it.
    fn pump(r: *Rig) !void {
        while (r.l.toServer().len > 0) {
            const b = try gpa.dupe(u8, r.l.toServer());
            defer gpa.free(b);
            r.l.consumedServer(b.len);
            var replies: std.ArrayList(u8) = .empty;
            defer replies.deinit(gpa);
            var at: usize = 0;
            while (at < b.len) {
                const sz = std.mem.readInt(u32, b[at..][0..4], .little);
                try r.srv.handle(b[at..][0..sz], &replies);
                at += sz;
            }
            // Fed back a byte at a time, so framing is exercised too.
            for (replies.items) |*c| try r.l.fromServer(c[0..1]);
        }
    }

    fn send(r: *Rig, tag: u16, msg: anytype) !void {
        var buf: [1 << 16]u8 = undefined;
        try r.l.fromMount(try wire.encode(&buf, tag, msg, null));
    }

    /// Sends one request and returns devmnt's reply.
    fn call(r: *Rig, msg: anytype) !wire.Frame(p9.R) {
        const tag = r.next_tag;
        r.next_tag += 1;
        try r.send(tag, msg);
        try r.pump();
        return r.take(tag);
    }

    fn take(r: *Rig, tag: u16) !wire.Frame(p9.R) {
        const b = r.l.toMount();
        if (b.len < 7) return error.NoReply;
        const sz = std.mem.readInt(u32, b[0..4], .little);
        r.out.clearRetainingCapacity();
        try r.out.appendSlice(gpa, b[0..sz]);
        r.l.consumedMount(sz);
        const d = try wire.decode(p9.R, r.out.items, 1 << 20, false);
        try t.expectEqual(tag, d.tag);
        return d;
    }

    fn mount(r: *Rig) !void {
        _ = try r.call(p9.Tversion{ .msize = 8192 + 24, .version = "9P2000" });
        const a = try r.call(p9.Tattach{ .fid = 1, .afid = wire.nofid, .uname = "glenda", .aname = "" });
        try t.expect(a.msg == .Rattach);
    }

    fn walk(r: *Rig, fid: u32, newfid: u32, names: []const []const u8) !wire.Frame(p9.R) {
        return r.call(p9.Twalk{ .fid = fid, .newfid = newfid, .wnames = .init(names) });
    }
};

/// A tree like a small root: /bin with a few files, /lib/ndb, /usr.
fn sampleTree(s: *Server) !void {
    _ = try s.add("/bin", true, "");
    _ = try s.add("/bin/ls", false, "ls binary");
    _ = try s.add("/bin/cat", false, "cat binary");
    _ = try s.add("/lib", true, "");
    _ = try s.add("/lib/ndb", true, "");
    _ = try s.add("/lib/ndb/local", false, "sys=h9");
    _ = try s.add("/usr", true, "");
}

fn withIndex(s: *Server) !void {
    const text = try s.indexText();
    defer gpa.free(text);
    _ = try s.add("/" ++ ri.file_name, false, text);
}

fn nq(d: wire.Frame(p9.R)) usize {
    return d.msg.Rwalk.wqids.n;
}

test "without /.h9index the layer passes everything through [mount-index]" {
    var s = try Server.init();
    defer s.deinit();
    try sampleTree(&s);
    var r = Rig.init(&s, .{ .server = .{ .key = "tcp!test" } }, .{});
    defer r.deinit();
    try r.mount();
    try t.expectEqual(layer.Phase.passthrough, r.l.phase);
    s.reset();
    const w = try r.walk(1, 2, &.{ "bin", "ls" });
    try t.expectEqual(@as(usize, 2), nq(w));
    try t.expectEqual(@as(u32, 1), s.count(p9.Twalk));
}

test "walks, stats, and directory reads are answered from the index [mount-index]" {
    var s = try Server.init();
    defer s.deinit();
    try sampleTree(&s);
    try withIndex(&s);
    var r = Rig.init(&s, .{ .server = .{ .key = "tcp!test" } }, .{});
    defer r.deinit();
    try r.mount();
    try t.expect(r.l.serving());
    try t.expectEqual(@as(u32, 0), r.l.ndemoted);
    s.reset();
    // A walk, a missing name, a partial walk, and a stat: no T-messages.
    const w = try r.walk(1, 2, &.{ "bin", "ls" });
    try t.expectEqual(@as(usize, 2), nq(w));
    try t.expectEqual(s.nodes.items[s.lookupPath("/bin/ls").?].qid.path, w.msg.Rwalk.wqids.slice()[1].path);
    const miss = try r.walk(1, 3, &.{"nonesuch"});
    try t.expect(miss.msg == .Rerror);
    try t.expectEqualStrings(layer.enonexist, miss.msg.Rerror.ename);
    const part = try r.walk(1, 3, &.{ "bin", "nonesuch" });
    try t.expectEqual(@as(usize, 1), nq(part));
    const st = try r.call(p9.Tstat{ .fid = 2 });
    const d, _ = attr.Dir.parse(st.msg.Rstat.stat.bytes).?;
    try t.expectEqualStrings("ls", d.name);
    try t.expectEqual(@as(u64, 9), d.length);
    // A directory read.
    _ = try r.walk(1, 4, &.{"bin"});
    const o = try r.call(p9.Topen{ .fid = 4, .mode = wire.OREAD });
    try t.expect(o.msg == .Ropen);
    const rd = try r.call(p9.Tread{ .fid = 4, .offset = 0, .count = 8192 });
    var b = rd.msg.Rread.data.bytes;
    var seen: usize = 0;
    while (b.len > 0) {
        const e, const sz = attr.Dir.parse(b).?;
        try t.expect(std.mem.eql(u8, e.name, "cat") or std.mem.eql(u8, e.name, "ls"));
        b = b[sz..];
        seen += 1;
    }
    try t.expectEqual(@as(usize, 2), seen);
    const end = try r.call(p9.Tread{ .fid = 4, .offset = rd.msg.Rread.data.bytes.len, .count = 8192 });
    try t.expectEqual(@as(usize, 0), end.msg.Rread.data.bytes.len);
    _ = try r.call(p9.Tclunk{ .fid = 4 });
    try t.expectEqual(@as(u32, 0), s.total());
}

test "opening a file makes its fid real with one walk [mount-index]" {
    var s = try Server.init();
    defer s.deinit();
    try sampleTree(&s);
    try withIndex(&s);
    var r = Rig.init(&s, .{ .server = .{ .key = "tcp!test" } }, .{});
    defer r.deinit();
    try r.mount();
    s.reset();
    _ = try r.walk(1, 2, &.{ "lib", "ndb", "local" });
    const o = try r.call(p9.Topen{ .fid = 2, .mode = wire.OREAD });
    try t.expect(o.msg == .Ropen);
    try t.expectEqual(@as(u32, 1), s.count(p9.Twalk));
    try t.expectEqual(@as(u32, 1), s.count(p9.Topen));
    const rd = try r.call(p9.Tread{ .fid = 2, .offset = 0, .count = 100 });
    try t.expectEqualStrings("sys=h9", rd.msg.Rread.data.bytes);
    _ = try r.call(p9.Tclunk{ .fid = 2 });
    try t.expectEqual(@as(u32, 1), s.count(p9.Tclunk));
}

test "a file changed in place is demoted when opened [mount-index]" {
    var s = try Server.init();
    defer s.deinit();
    try sampleTree(&s);
    try withIndex(&s);
    // After indexing: the file's contents and qid.vers change, its
    // directory's don't.
    const ls = s.lookupPath("/bin/ls").?;
    try s.nodes.items[ls].data.appendSlice(gpa, " v2");
    s.nodes.items[ls].qid.vers += 1;
    var r = Rig.init(&s, .{ .server = .{ .key = "tcp!test" } }, .{});
    defer r.deinit();
    try r.mount();
    _ = try r.walk(1, 2, &.{ "bin", "ls" });
    // Until it's opened, its stat is the index's.
    const before = try r.call(p9.Tstat{ .fid = 2 });
    const d0, _ = attr.Dir.parse(before.msg.Rstat.stat.bytes).?;
    try t.expectEqual(@as(u64, 9), d0.length);
    _ = try r.call(p9.Topen{ .fid = 2, .mode = wire.OREAD });
    const rd = try r.call(p9.Tread{ .fid = 2, .offset = 0, .count = 100 });
    try t.expectEqualStrings("ls binary v2", rd.msg.Rread.data.bytes);
    s.reset();
    const after = try r.call(p9.Tstat{ .fid = 2 });
    const d1, _ = attr.Dir.parse(after.msg.Rstat.stat.bytes).?;
    try t.expectEqual(@as(u64, 12), d1.length);
    try t.expectEqual(@as(u32, 1), s.count(p9.Tstat));
}

test "files added and removed after indexing demote their directories [mount-index]" {
    var s = try Server.init();
    defer s.deinit();
    try sampleTree(&s);
    try withIndex(&s);
    _ = try s.add("/usr/new", false, "new");
    s.nodes.items[s.lookupPath("/bin/cat").?].removed = true;
    s.touch(s.lookupPath("/bin").?);
    var r = Rig.init(&s, .{ .server = .{ .key = "tcp!test" } }, .{});
    defer r.deinit();
    try r.mount();
    try t.expectEqual(@as(u32, 2), r.l.ndemoted);
    const w = try r.walk(1, 2, &.{ "usr", "new" });
    try t.expectEqual(@as(usize, 2), nq(w));
    const gone = try r.walk(1, 3, &.{ "bin", "cat" });
    try t.expectEqual(@as(usize, 1), nq(gone));
    // /lib wasn't touched: still answered locally.
    s.reset();
    const nd = try r.walk(1, 4, &.{ "lib", "ndb", "x" });
    try t.expectEqual(@as(usize, 2), nq(nd));
    try t.expectEqual(@as(u32, 0), s.total());
}

test "a file created through the mount is found by the next walk [mount-index]" {
    var s = try Server.init();
    defer s.deinit();
    try sampleTree(&s);
    try withIndex(&s);
    var r = Rig.init(&s, .{ .server = .{ .key = "tcp!test" } }, .{});
    defer r.deinit();
    try r.mount();
    _ = try r.walk(1, 2, &.{"usr"});
    const c = try r.call(p9.Tcreate{ .fid = 2, .name = "made", .perm = 0o664, .mode = wire.OWRITE });
    try t.expect(c.msg == .Rcreate);
    _ = try r.call(p9.Twrite{ .fid = 2, .offset = 0, .data = .{ .bytes = "hi" } });
    _ = try r.call(p9.Tclunk{ .fid = 2 });
    const w = try r.walk(1, 3, &.{ "usr", "made" });
    try t.expectEqual(@as(usize, 2), nq(w));
    const st = try r.call(p9.Tstat{ .fid = 3 });
    const d, _ = attr.Dir.parse(st.msg.Rstat.stat.bytes).?;
    try t.expectEqual(@as(u64, 2), d.length);
}

test "a removed file's directory is demoted [mount-index]" {
    var s = try Server.init();
    defer s.deinit();
    try sampleTree(&s);
    try withIndex(&s);
    var r = Rig.init(&s, .{ .server = .{ .key = "tcp!test" } }, .{});
    defer r.deinit();
    try r.mount();
    _ = try r.walk(1, 2, &.{ "bin", "cat" });
    const rm = try r.call(p9.Tremove{ .fid = 2 });
    try t.expect(rm.msg == .Rremove);
    const w = try r.walk(1, 3, &.{ "bin", "cat" });
    try t.expectEqual(@as(usize, 1), nq(w));
}

test "a walk past the index from a virtual fid goes from the root [mount-index]" {
    var s = try Server.init();
    defer s.deinit();
    try sampleTree(&s);
    try withIndex(&s);
    _ = try s.add("/usr/glenda", true, "");
    var r = Rig.init(&s, .{ .server = .{ .key = "tcp!test" } }, .{});
    defer r.deinit();
    try r.mount();
    // /usr is demoted; /usr's virtual fid walks from the root.
    _ = try r.walk(1, 2, &.{"usr"});
    s.reset();
    const w = try r.walk(2, 3, &.{"glenda"});
    try t.expectEqual(@as(usize, 1), nq(w));
    try t.expectEqual(@as(u32, 1), s.count(p9.Twalk));
    const st = try r.call(p9.Tstat{ .fid = 3 });
    const d, _ = attr.Dir.parse(st.msg.Rstat.stat.bytes).?;
    try t.expectEqualStrings("glenda", d.name);
}

test "a flush of an open still making its fid real is answered locally [mount-index]" {
    var s = try Server.init();
    defer s.deinit();
    try sampleTree(&s);
    try withIndex(&s);
    var r = Rig.init(&s, .{ .server = .{ .key = "tcp!test" } }, .{});
    defer r.deinit();
    try r.mount();
    _ = try r.walk(1, 2, &.{ "bin", "ls" });
    s.reset();
    try r.send(50, p9.Topen{ .fid = 2, .mode = wire.OREAD });
    try r.send(51, p9.Tflush{ .oldtag = 50 });
    _ = try r.take(51);
    try r.pump();
    // The walk went; the open didn't, and has no reply.
    try t.expectEqual(@as(u32, 1), s.count(p9.Twalk));
    try t.expectEqual(@as(u32, 0), s.count(p9.Topen));
    try t.expectEqual(@as(usize, 0), r.l.toMount().len);
}

test "a path deeper than 16 names is made real in steps [mount-index]" {
    var s = try Server.init();
    defer s.deinit();
    var p: std.ArrayList(u8) = .empty;
    defer p.deinit(gpa);
    var parts: [20][]const u8 = undefined;
    for (0..20) |i| {
        try p.print(gpa, "/d{d}", .{i});
        _ = try s.add(p.items, true, "");
        parts[i] = s.nodes.items[s.nodes.items.len - 1].name;
    }
    try p.appendSlice(gpa, "/f");
    _ = try s.add(p.items, false, "deep");
    try withIndex(&s);
    var r = Rig.init(&s, .{ .server = .{ .key = "tcp!test" } }, .{});
    defer r.deinit();
    try r.mount();
    try t.expectEqual(@as(u32, 0), r.l.ndemoted);
    _ = try r.walk(1, 2, parts[0..16]);
    var rest: [5][]const u8 = undefined;
    @memcpy(rest[0..4], parts[16..20]);
    rest[4] = "f";
    _ = try r.walk(2, 3, &rest);
    s.reset();
    _ = try r.call(p9.Topen{ .fid = 3, .mode = wire.OREAD });
    try t.expectEqual(@as(u32, 2), s.count(p9.Twalk));
    const rd = try r.call(p9.Tread{ .fid = 3, .offset = 0, .count = 100 });
    try t.expectEqualStrings("deep", rd.msg.Rread.data.bytes);
}

test "a second run uses the cache and doesn't read /.h9index [mount-index]" {
    var s = try Server.init();
    defer s.deinit();
    try sampleTree(&s);
    try withIndex(&s);
    var c: MemCache = .{};
    defer c.deinit();
    {
        var r = Rig.init(&s, .{ .server = .{ .key = "tcp!test" } }, c.hooks());
        defer r.deinit();
        try r.mount();
        try t.expect(c.bytes != null);
    }
    s.reset();
    var r = Rig.init(&s, .{ .server = .{ .key = "tcp!test" } }, c.hooks());
    defer r.deinit();
    try r.mount();
    try t.expect(r.l.serving());
    try t.expect(r.l.from_cache);
    try t.expectEqual(@as(u32, 0), s.index_reads);
    // A rewritten index is fetched again.
    const idx = s.lookupPath("/" ++ ri.file_name).?;
    try s.nodes.items[idx].data.appendSlice(gpa, "");
    s.touch(idx);
    s.reset();
    var r2 = Rig.init(&s, .{ .server = .{ .key = "tcp!test" } }, c.hooks());
    defer r2.deinit();
    try r2.mount();
    try t.expect(!r2.l.from_cache);
    try t.expect(s.index_reads > 0);
}

test "a malformed /.h9index is ignored and the mount works [mount-index]" {
    var s = try Server.init();
    defer s.deinit();
    try sampleTree(&s);
    _ = try s.add("/" ++ ri.file_name, false, "h9index 1\n/ 1 0 d 020000000775 0 0 a b\nbroken\n");
    var r = Rig.init(&s, .{ .server = .{ .key = "tcp!test" } }, .{});
    defer r.deinit();
    try r.mount();
    try t.expectEqual(layer.Phase.passthrough, r.l.phase);
    try t.expect(std.mem.indexOf(u8, r.l.notes.items, "line 3") != null);
    const w = try r.walk(1, 2, &.{ "bin", "ls" });
    try t.expectEqual(@as(usize, 2), nq(w));
}

test "a given index is used over a server without /.h9index [mount-index]" {
    var s = try Server.init();
    defer s.deinit();
    try sampleTree(&s);
    const text = try s.indexText();
    defer gpa.free(text);
    var diag: ri.Diag = .{};
    const compiled = try ri.compile(gpa, text, &diag);
    var r = Rig.init(&s, .{ .given = .{ .compiled = compiled, .label = "x.h9index" } }, .{});
    defer r.deinit();
    try r.mount();
    try t.expect(r.l.serving());
    s.reset();
    const miss = try r.walk(1, 2, &.{ "lib", "nonesuch" });
    try t.expectEqual(@as(usize, 1), nq(miss));
    try t.expectEqual(@as(u32, 0), s.total());
}

test "the root validates by its listing after /.h9index is written [mount-index]" {
    var s = try Server.init();
    defer s.deinit();
    try sampleTree(&s);
    // withIndex changed the root's qid.vers and mtime after indexing.
    try withIndex(&s);
    var r = Rig.init(&s, .{ .server = .{ .key = "tcp!test" } }, .{});
    defer r.deinit();
    try r.mount();
    try t.expect(!r.l.demoted.isSet(ri.root));
    s.reset();
    const miss = try r.walk(1, 2, &.{"nonesuch"});
    try t.expect(miss.msg == .Rerror);
    try t.expectEqual(@as(u32, 0), s.total());
    // The root's own stat is the server's.
    const st = try r.call(p9.Tstat{ .fid = 1 });
    const d, _ = attr.Dir.parse(st.msg.Rstat.stat.bytes).?;
    try t.expectEqual(s.nodes.items[0].mtime, d.mtime);
}

test "a second attach passes through [mount-index]" {
    var s = try Server.init();
    defer s.deinit();
    try sampleTree(&s);
    try withIndex(&s);
    var r = Rig.init(&s, .{ .server = .{ .key = "tcp!test" } }, .{});
    defer r.deinit();
    try r.mount();
    const a = try r.call(p9.Tattach{ .fid = 9, .afid = wire.nofid, .uname = "glenda", .aname = "" });
    try t.expect(a.msg == .Rattach);
    s.reset();
    _ = try r.walk(9, 10, &.{"nonesuch"});
    try t.expectEqual(@as(u32, 1), s.count(p9.Twalk));
    _ = try r.walk(9, 11, &.{ "bin", "ls" });
    const st = try r.call(p9.Tstat{ .fid = 11 });
    try t.expect(st.msg == .Rstat);
    try t.expectEqual(@as(u32, 1), s.count(p9.Tstat));
}
