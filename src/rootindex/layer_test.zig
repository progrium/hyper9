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
    /// Reads of /.fs/index.
    index_reads: u32 = 0,
    /// Whether indexText writes 9p.qid fields.
    index_qids: bool = true,
    /// The seq indexText writes, and .fs/events reports.
    seq: u64 = 0,
    /// .fs/events, if the server has it: its node, what's queued to read,
    /// and a read waiting for records.
    events: ?u32 = null,
    ev_queue: std.ArrayList(u8) = .empty,
    ev_wait: ?struct { tag: u16, count: u32 } = null,
    ev_setup: std.ArrayList(u8) = .empty,
    /// Replies sent after their request, to a read that waited.
    late: std.ArrayList(u8) = .empty,

    fn init() !Server {
        var s: Server = .{};
        try s.nodes.append(gpa, .{ .name = "/", .parent = 0, .qid = .{ .type = wire.QTDIR, .path = 1 }, .mode = wire.DMDIR | 0o775, .mtime = s.clock });
        return s;
    }

    fn deinit(s: *Server) void {
        for (s.nodes.items) |*n| n.data.deinit(gpa);
        s.nodes.deinit(gpa);
        s.fids.deinit(gpa);
        s.ev_queue.deinit(gpa);
        s.ev_setup.deinit(gpa);
        s.late.deinit(gpa);
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

    /// The tree's index text, as mkindex writes it, sorted by path.
    fn indexText(s: *const Server) ![]u8 {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const Line = struct { path: []const u8, line: []const u8 };
        var lines: std.ArrayList(Line) = .empty;
        for (s.nodes.items, 0..) |n, i| {
            if (n.removed or s.underFs(@intCast(i))) continue;
            var pbuf: [512]u8 = undefined;
            const path = try a.dupe(u8, s.pathOf(@intCast(i), &pbuf));
            var esc: std.ArrayList(u8) = .empty;
            for (path) |c| if (c > 0x20 and c < 0x7f and c != '%') try esc.append(a, c) else try esc.print(a, "%{X:0>2}", .{c});
            const d = s.dirOf(@intCast(i));
            const dir = n.qid.type & wire.QTDIR != 0;
            var w: std.ArrayList(u8) = .empty;
            try w.print(a, "{s} {c} {o:0>4} {d} {d} {d} - -", .{ esc.items, @as(u8, if (dir) 'd' else 'f'), n.mode & 0o777, if (dir) 0 else d.length, n.mtime, n.qid.vers });
            if (s.index_qids) try w.print(a, " 9p.qid={x}.{d} 9p.uid=glenda 9p.gid=sys", .{ n.qid.path, n.qid.vers });
            try lines.append(a, .{ .path = path, .line = w.items });
        }
        std.mem.sortUnstable(Line, lines.items, {}, struct {
            fn lt(_: void, x: Line, y: Line) bool {
                return std.mem.order(u8, x.path, y.path) == .lt;
            }
        }.lt);
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        try out.writer.print("{s} seq {d}\n", .{ ri.magic, s.seq });
        for (lines.items) |l| try out.writer.print("{s}\n", .{l.line});
        return out.toOwnedSlice();
    }

    /// Whether node `i` is /.fs or in it.
    fn underFs(s: *const Server, i: u32) bool {
        var at = i;
        while (at != 0) : (at = s.nodes.items[at].parent) {
            if (s.nodes.items[at].parent == 0 and std.mem.eql(u8, s.nodes.items[at].name, ri.fs_dir)) return true;
        }
        return false;
    }

    /// Gives the server .fs/events, which starts at seq `s.seq`.
    fn withEvents(s: *Server) !void {
        if (s.lookupPath("/" ++ ri.fs_dir) == null) _ = try s.add("/" ++ ri.fs_dir, true, "");
        s.events = try s.add("/" ++ ri.fs_dir ++ "/" ++ ri.events_name, false, "");
    }

    /// Sends a change record, answering a waiting read.
    fn push(s: *Server, rec: []const u8) !void {
        try s.ev_queue.appendSlice(gpa, rec);
        try s.ev_queue.append(gpa, '\n');
        if (s.ev_wait) |w| {
            s.ev_wait = null;
            var buf: [1 << 16]u8 = undefined;
            try s.late.appendSlice(gpa, try s.evReply(w.tag, w.count, &buf));
        }
    }

    fn evReply(s: *Server, tag: u16, want: u32, buf: []u8) ![]const u8 {
        const n = @min(want, s.ev_queue.items.len);
        var fb: [1 << 16]u8 = undefined;
        @memcpy(fb[0..n], s.ev_queue.items[0..n]);
        std.mem.copyForwards(u8, s.ev_queue.items, s.ev_queue.items[n..]);
        s.ev_queue.items.len -= n;
        return wire.encode(buf, tag, p9.Rread{ .data = .{ .bytes = fb[0..n] } }, null);
    }

    fn handle(s: *Server, frame: []const u8, out: *std.ArrayList(u8)) !void {
        const d = try wire.decode(p9.T, frame, 1 << 20, false);
        s.counts[frame[4]] += 1;
        if (s.events) |ev| switch (d.msg) {
            .Tread => |r| if (s.fids.get(r.fid) == ev) {
                if (s.ev_queue.items.len == 0) {
                    s.ev_wait = .{ .tag = d.tag, .count = r.count };
                    return;
                }
                var eb: [1 << 16]u8 = undefined;
                return out.appendSlice(gpa, try s.evReply(d.tag, r.count, &eb));
            },
            .Topen => |o| if (s.fids.get(o.fid) == ev) {
                s.ev_queue.clearRetainingCapacity();
                try s.ev_queue.print(gpa, "seq {d}\n", .{s.seq});
            },
            .Twrite => |w| if (s.fids.get(w.fid) == ev) {
                try s.ev_setup.appendSlice(gpa, w.data.bytes);
                var eb: [256]u8 = undefined;
                return out.appendSlice(gpa, try wire.encode(&eb, d.tag, p9.Rwrite{ .count = @intCast(w.data.bytes.len) }, null));
            },
            else => {},
        };
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
                if (std.mem.eql(u8, node.name, ri.index_name) and s.underFs(n)) s.index_reads += 1;
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
    /// Round trips to the server in the last `call`.
    rounds: u32 = 0,

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
        while (r.l.toServer().len > 0 or r.srv.late.items.len > 0) {
            if (r.srv.late.items.len > 0) {
                const late = try gpa.dupe(u8, r.srv.late.items);
                defer gpa.free(late);
                r.srv.late.clearRetainingCapacity();
                for (late) |*c| try r.l.fromServer(c[0..1]);
                continue;
            }
            r.rounds += 1;
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
        r.rounds = 0;
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
    try withIndexText(s, text);
}

fn withIndexText(s: *Server, text: []const u8) !void {
    if (s.lookupPath("/" ++ ri.fs_dir) == null) _ = try s.add("/" ++ ri.fs_dir, true, "");
    _ = try s.add("/" ++ ri.fs_dir ++ "/" ++ ri.index_name, false, text);
}

fn nq(d: wire.Frame(p9.R)) usize {
    return d.msg.Rwalk.wqids.n;
}

test "without .fs/index the layer passes everything through [mount-index]" {
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
    // A walk, a missing name, a partial walk, and a stat: no T-messages
    // but validating /bin, the first time it's used.
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
    try t.expectEqual(@as(u32, 1), s.count(p9.Twalk));
    try t.expectEqual(@as(u32, 1), s.count(p9.Tstat));
    try t.expectEqual(@as(u32, 3), s.total());
}

test "opening a file makes its fid real with one walk [mount-index]" {
    var s = try Server.init();
    defer s.deinit();
    try sampleTree(&s);
    try withIndex(&s);
    var r = Rig.init(&s, .{ .server = .{ .key = "tcp!test" } }, .{});
    defer r.deinit();
    try r.mount();
    _ = try r.walk(1, 2, &.{ "lib", "ndb", "local" });
    s.reset();
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
    const w = try r.walk(1, 2, &.{ "usr", "new" });
    try t.expectEqual(@as(usize, 2), nq(w));
    const gone = try r.walk(1, 3, &.{ "bin", "cat" });
    try t.expectEqual(@as(usize, 1), nq(gone));
    try t.expectEqual(@as(u32, 2), r.l.ndemoted);
    // /lib wasn't touched: once validated, answered locally.
    const nd0 = try r.walk(1, 4, &.{ "lib", "ndb", "x" });
    try t.expectEqual(@as(usize, 2), nq(nd0));
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

test "a second run uses the cache and doesn't read .fs/index [mount-index]" {
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
    const idx = s.lookupPath("/" ++ ri.fs_dir ++ "/" ++ ri.index_name).?;
    try s.nodes.items[idx].data.appendSlice(gpa, "");
    s.touch(idx);
    s.reset();
    var r2 = Rig.init(&s, .{ .server = .{ .key = "tcp!test" } }, c.hooks());
    defer r2.deinit();
    try r2.mount();
    try t.expect(!r2.l.from_cache);
    try t.expect(s.index_reads > 0);
}

test "a malformed .fs/index is ignored and the mount works [mount-index]" {
    var s = try Server.init();
    defer s.deinit();
    try sampleTree(&s);
    try withIndexText(&s, "fsindex 1 seq 0\n/ d 0755 0 0 0 - -\nbroken\n");
    var r = Rig.init(&s, .{ .server = .{ .key = "tcp!test" } }, .{});
    defer r.deinit();
    try r.mount();
    try t.expectEqual(layer.Phase.passthrough, r.l.phase);
    try t.expect(std.mem.indexOf(u8, r.l.notes.items, "line 3") != null);
    const w = try r.walk(1, 2, &.{ "bin", "ls" });
    try t.expectEqual(@as(usize, 2), nq(w));
}

test "a given index is used over a server without .fs/index [mount-index]" {
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
    // Validating /lib, and no Twalk for the name.
    const miss = try r.walk(1, 2, &.{ "lib", "nonesuch" });
    try t.expectEqual(@as(usize, 1), nq(miss));
    try t.expectEqual(@as(u32, 1), s.count(p9.Twalk));
    try t.expectEqual(@as(u32, 1), s.count(p9.Tstat));
}

test "directories are validated as they're used, a walk's path at once [mount-index]" {
    var s = try Server.init();
    defer s.deinit();
    try sampleTree(&s);
    try withIndex(&s);
    var r = Rig.init(&s, .{ .server = .{ .key = "tcp!test" } }, .{});
    defer r.deinit();
    try r.mount();
    // Only the root, at the mount.
    try t.expectEqual(@as(u32, 1), r.l.checked);
    s.reset();
    // /lib and /lib/ndb together: their walks and stats go out before
    // any reply.
    const w = try r.walk(1, 2, &.{ "lib", "ndb", "local" });
    try t.expectEqual(@as(usize, 3), nq(w));
    try t.expectEqual(@as(u32, 3), r.l.checked);
    try t.expectEqual(@as(u32, 2), s.count(p9.Tstat));
    // Walks, stats, then clunks: one at a time would take five.
    try t.expectEqual(@as(u32, 3), r.rounds);
    // A directory's stat and its listing validate it too, once.
    s.reset();
    _ = try r.walk(1, 3, &.{"usr"});
    _ = try r.call(p9.Tstat{ .fid = 3 });
    _ = try r.walk(1, 4, &.{"usr"});
    _ = try r.call(p9.Topen{ .fid = 4, .mode = wire.OREAD });
    try t.expectEqual(@as(u32, 1), s.count(p9.Tstat));
    try t.expectEqual(@as(u32, 4), r.l.checked);
}

test "a flush of a request waiting on validation is answered locally [mount-index]" {
    var s = try Server.init();
    defer s.deinit();
    try sampleTree(&s);
    try withIndex(&s);
    var r = Rig.init(&s, .{ .server = .{ .key = "tcp!test" } }, .{});
    defer r.deinit();
    try r.mount();
    try r.send(50, p9.Twalk{ .fid = 1, .newfid = 2, .wnames = .init(&.{ "bin", "ls" }) });
    try r.send(51, p9.Tflush{ .oldtag = 50 });
    const f = try r.take(51);
    try t.expect(f.msg == .Rflush);
    // Validating /bin finishes, but the walk never runs, and its tag is
    // free again.
    try r.pump();
    try t.expectEqual(@as(usize, 0), r.l.toMount().len);
    try r.send(50, p9.Twalk{ .fid = 1, .newfid = 2, .wnames = .init(&.{ "bin", "ls" }) });
    try r.pump();
    const w = try r.take(50);
    try t.expectEqual(@as(usize, 2), nq(w));
}

test "the root validates by its listing after .fs/index is written [mount-index]" {
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

test "an index without 9p.qid gives each path one qid [mount-index]" {
    var s = try Server.init();
    defer s.deinit();
    try sampleTree(&s);
    s.index_qids = false;
    try withIndex(&s);
    var r = Rig.init(&s, .{ .server = .{ .key = "tcp!test" } }, .{});
    defer r.deinit();
    try r.mount();
    const made = ri.madeUpQidPath("/bin/ls");
    const w = try r.walk(1, 2, &.{ "bin", "ls" });
    try t.expectEqual(made, w.msg.Rwalk.wqids.slice()[1].path);
    // The server's Ropen gets the same qid.path.
    const o = try r.call(p9.Topen{ .fid = 2, .mode = wire.OREAD });
    try t.expectEqual(made, o.msg.Ropen.qid.path);
    // Once /bin is demoted, the server's walk does too.
    _ = try r.walk(1, 3, &.{"bin"});
    const c = try r.call(p9.Tcreate{ .fid = 3, .name = "new", .perm = 0o664, .mode = wire.OWRITE });
    try t.expect(c.msg == .Rcreate);
    s.reset();
    const again = try r.walk(1, 4, &.{ "bin", "ls" });
    try t.expect(s.count(p9.Twalk) > 0);
    try t.expectEqual(made, again.msg.Rwalk.wqids.slice()[1].path);
    try t.expectEqual(ri.madeUpQidPath("/bin"), again.msg.Rwalk.wqids.slice()[0].path);
    const st = try r.call(p9.Tstat{ .fid = 4 });
    const d, _ = attr.Dir.parse(st.msg.Rstat.stat.bytes).?;
    try t.expectEqual(made, d.qid_path);
    // Owners the index doesn't name are the attach's user.
    try t.expectEqualStrings("glenda", d.uid);
}

test "a server with .fs/events is followed, not validated [mount-index]" {
    var s = try Server.init();
    defer s.deinit();
    try sampleTree(&s);
    s.seq = 5;
    try s.withEvents();
    try withIndex(&s);
    var r = Rig.init(&s, .{ .server = .{ .key = "tcp!test" } }, .{});
    defer r.deinit();
    try r.mount();
    try t.expect(r.l.serving());
    try t.expect(r.l.following);
    try t.expect(std.mem.indexOf(u8, s.ev_setup.items, "coalesce") != null);
    try t.expect(std.mem.indexOf(u8, r.l.notes.items, "following the server's changes from seq 5") != null);
    // No directory is validated: a walk sends nothing.
    s.reset();
    const w = try r.walk(1, 2, &.{ "lib", "ndb", "local" });
    try t.expectEqual(@as(usize, 3), nq(w));
    const miss = try r.walk(1, 3, &.{ "bin", "nonesuch" });
    try t.expectEqual(@as(usize, 1), nq(miss));
    try t.expectEqual(@as(u32, 0), s.total());
    // Another client adds /bin/new: its record demotes /bin.
    _ = try s.add("/bin/new", false, "new");
    try s.push("6 put /bin/new f 0664 3 2000 6 - - dev=other");
    try r.pump();
    const found = try r.walk(1, 3, &.{ "bin", "new" });
    try t.expectEqual(@as(usize, 2), nq(found));
    // /lib is still answered locally, and a record at or below the
    // index's seq is dropped.
    try s.push("4 del /lib/ndb/local");
    try r.pump();
    s.reset();
    _ = try r.walk(1, 4, &.{ "lib", "ndb", "local" });
    try t.expectEqual(@as(u32, 0), s.total());
    // A reset ends the index's use.
    try s.push("9 reset");
    try r.pump();
    s.reset();
    _ = try r.walk(1, 5, &.{ "lib", "ndb", "local" });
    try t.expect(s.count(p9.Twalk) > 0);
}

test "a followed index older than the server's seq is ignored [mount-index]" {
    var s = try Server.init();
    defer s.deinit();
    try sampleTree(&s);
    s.seq = 5;
    try s.withEvents();
    try withIndex(&s);
    s.seq = 7;
    var r = Rig.init(&s, .{ .server = .{ .key = "tcp!test" } }, .{});
    defer r.deinit();
    try r.mount();
    try t.expectEqual(layer.Phase.passthrough, r.l.phase);
    try t.expect(std.mem.indexOf(u8, r.l.notes.items, "older than the server's 7") != null);
}
