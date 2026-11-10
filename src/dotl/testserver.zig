//! A 9P2000.L server over a tree in memory, for testing the translator
//! without a kernel or a real server. It answers like a Linux server:
//! walks stop at a symlink, Treaddir includes `.` and `..`, and errors
//! are errnos. `hold` keeps requests unanswered until `release`, to test
//! flushes.
//!
//! With `version` set to `9P2000.L.Z` it speaks ZeroFS's extension as far
//! as the translator uses it: envelopes, whose op_ids it remembers so a
//! resent mutation is applied once, and Trebind. `reset` starts a new
//! connection on the same tree, as a server restarting keeps its files,
//! and `drop_after_write` drops the connection after applying a write and
//! before answering it, as a crash at the worst moment would.

const std = @import("std");
const wire = @import("wire.zig");
const attr = @import("attr.zig");

const l = wire.l;
const L = wire.L;
const E = attr.E;
const Allocator = std.mem.Allocator;

pub const Node = struct {
    name: []u8,
    kind: enum { dir, file, link, fifo },
    mode: u32 = 0o644,
    uid: u32 = 1000,
    gid: u32 = 1000,
    mtime: u64 = 0,
    data: std.ArrayList(u8) = .empty,
    target: []u8 = &.{},
    parent: ?*Node = null,
    children: std.ArrayList(*Node) = .empty,
    path: u64,

    fn qid(n: *const Node) wire.Qid {
        return .{ .type = switch (n.kind) {
            .dir => wire.QTDIR,
            .link => wire.QTSYMLINK,
            else => wire.QTFILE,
        }, .path = n.path };
    }

    fn stat(n: *const Node) wire.Stat {
        const fmt: u32 = switch (n.kind) {
            .dir => attr.S_IFDIR,
            .file => attr.S_IFREG,
            .link => attr.S_IFLNK,
            .fifo => attr.S_IFIFO,
        };
        return .{ .qid = n.qid(), .mode = fmt | n.mode, .uid = n.uid, .gid = n.gid, .nlink = 1, .size = n.data.items.len, .mtime_sec = n.mtime };
    }

    pub fn child(n: *const Node, name: []const u8) ?*Node {
        for (n.children.items) |c| if (std.mem.eql(u8, c.name, name)) return c;
        return null;
    }
};

const SFid = struct { node: *Node, open: bool = false };

pub const Server = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    root: *Node,
    next_path: u64 = 1,
    fids: std.AutoHashMapUnmanaged(u32, SFid) = .empty,
    /// The version it answers with.
    version: []const u8 = wire.version_l,
    msize: u32 = 1 << 16,
    in: std.ArrayList(u8) = .empty,
    out: std.ArrayList(u8) = .empty,
    hold: bool = false,
    held: std.ArrayList([]u8) = .empty,
    /// Every request's type, in order.
    log: std.ArrayList(u8) = .empty,
    /// The uname and n_uname of the last attach.
    attached_as: ?struct { []const u8, u32 } = null,
    /// `9P2000.L.Z` was negotiated on this connection.
    lz: bool = false,
    /// Answer `unknown` to any version but `version` exactly, as some
    /// .L servers do.
    strict_version: bool = false,
    /// Replies to mutations by op_id, kept across connections.
    done: std.AutoHashMapUnmanaged([16]u8, []u8) = .empty,
    /// Writes applied, across connections.
    writes: u32 = 0,
    /// After this many writes, apply the next one and then drop the
    /// connection without answering it: `dropped` is set, and the
    /// transport should close.
    drop_after_write: ?u32 = null,
    dropped: bool = false,
    /// Answers this many mutations with ENOTLEADER, without applying
    /// them, as an HA server that lost the lead would.
    not_leader: u32 = 0,
    /// Mutations applied, and resent ones answered from `done`.
    applied: u32 = 0,
    replayed: u32 = 0,

    pub fn init(gpa: Allocator) !*Server {
        const s = try gpa.create(Server);
        s.* = .{ .gpa = gpa, .arena = .init(gpa), .root = undefined };
        s.root = try s.newNode(null, "", .dir);
        s.root.mode = 0o755;
        return s;
    }

    /// A new connection on the same tree: fids and buffers start over.
    pub fn reset(s: *Server) void {
        s.fids.clearRetainingCapacity();
        s.in.items.len = 0;
        s.out.items.len = 0;
        for (s.held.items) |h| s.gpa.free(h);
        s.held.items.len = 0;
        s.hold = false;
        s.lz = false;
        s.msize = 1 << 16;
        s.dropped = false;
    }

    pub fn deinit(s: *Server) void {
        var it = s.done.valueIterator();
        while (it.next()) |v| s.gpa.free(v.*);
        s.done.deinit(s.gpa);
        s.fids.deinit(s.gpa);
        s.in.deinit(s.gpa);
        s.out.deinit(s.gpa);
        for (s.held.items) |h| s.gpa.free(h);
        s.held.deinit(s.gpa);
        s.log.deinit(s.gpa);
        s.arena.deinit();
        s.gpa.destroy(s);
    }

    fn newNode(s: *Server, parent: ?*Node, name: []const u8, kind: @FieldType(Node, "kind")) !*Node {
        const a = s.arena.allocator();
        const n = try a.create(Node);
        n.* = .{ .name = try a.dupe(u8, name), .kind = kind, .parent = parent, .path = s.next_path };
        s.next_path += 1;
        if (kind == .dir) n.mode = 0o755;
        if (parent) |p| try p.children.append(a, n);
        return n;
    }

    /// Makes the node at `path` (and the directories above it).
    pub fn add(s: *Server, path: []const u8, kind: @FieldType(Node, "kind"), contents: []const u8) !*Node {
        var dir = s.root;
        var it = std.mem.tokenizeScalar(u8, path, '/');
        var name = it.next().?;
        while (it.next()) |next| {
            dir = dir.child(name) orelse try s.newNode(dir, name, .dir);
            name = next;
        }
        const n = try s.newNode(dir, name, kind);
        if (kind == .link) n.target = try s.arena.allocator().dupe(u8, contents) else try n.data.appendSlice(s.arena.allocator(), contents);
        return n;
    }

    pub fn lookup(s: *Server, path: []const u8) ?*Node {
        var n = s.root;
        var it = std.mem.tokenizeScalar(u8, path, '/');
        while (it.next()) |name| n = n.child(name) orelse return null;
        return n;
    }

    /// Takes the client's bytes and answers whole requests.
    pub fn feed(s: *Server, bytes: []const u8) !void {
        try s.in.appendSlice(s.gpa, bytes);
        while (try wire.header(s.in.items, s.msize)) |h| {
            if (s.dropped) return;
            if (s.in.items.len < h.size) break;
            const frame = try s.gpa.dupe(u8, s.in.items[0..h.size]);
            std.mem.copyForwards(u8, s.in.items, s.in.items[h.size..]);
            s.in.items.len -= h.size;
            try s.log.append(s.gpa, h.type);
            if (h.type == l.Tflush.id) {
                defer s.gpa.free(frame);
                const d = try wire.decode(l.T, frame, s.msize, false);
                for (s.held.items, 0..) |held, i| {
                    if (std.mem.readInt(u16, held[5..7], .little) == d.msg.Tflush.oldtag) {
                        s.gpa.free(s.held.orderedRemove(i));
                        break;
                    }
                }
                try s.send(d.tag, l.Rflush{});
                continue;
            }
            if (s.hold) {
                try s.held.append(s.gpa, frame);
                continue;
            }
            defer s.gpa.free(frame);
            try s.handle(frame);
        }
    }

    /// Answers every held request, in order.
    pub fn release(s: *Server) !void {
        s.hold = false;
        const held = try s.held.toOwnedSlice(s.gpa);
        defer s.gpa.free(held);
        for (held) |f| {
            defer s.gpa.free(f);
            try s.handle(f);
        }
    }

    fn send(s: *Server, tag: u16, msg: anytype) !void {
        try s.out.ensureUnusedCapacity(s.gpa, s.msize);
        const f = try wire.encode(s.out.unusedCapacitySlice(), tag, msg, null);
        s.out.items.len += f.len;
    }

    fn lerr(s: *Server, tag: u16, e: u32) !void {
        try s.send(tag, l.Rlerror{ .ecode = e });
    }

    fn handle(s: *Server, frame: []const u8) !void {
        const d = try wire.decode(l.T, frame, s.msize, s.lz);
        const e = d.env orelse return s.handleMsg(d);
        // A mutation: answered from `done` if its op_id was applied.
        if (s.done.get(e.op_id)) |r| {
            s.replayed += 1;
            const at = s.out.items.len;
            try s.out.appendSlice(s.gpa, r);
            std.mem.writeInt(u16, s.out.items[at + 5 ..][0..2], d.tag, .little);
            return;
        }
        if (s.not_leader > 0) {
            s.not_leader -= 1;
            return s.lerr(d.tag, L.ENOTLEADER);
        }
        const at = s.out.items.len;
        try s.handleMsg(d);
        s.applied += 1;
        try s.done.put(s.gpa, e.op_id, try s.gpa.dupe(u8, s.out.items[at..]));
        if (d.msg == .Twrite) {
            s.writes += 1;
            if (s.drop_after_write) |n| if (s.writes > n) {
                s.drop_after_write = null;
                s.out.items.len = at;
                s.dropped = true;
            };
        }
    }

    fn readDir(s: *Server, tag: u16, fid: u32, offset: u64, count: u32, attrs: bool) !void {
        if (attrs and !s.lz) return s.lerr(tag, E.OPNOTSUPP);
        const f = s.fids.get(fid) orelse return s.lerr(tag, E.BADF);
        if (f.node.kind != .dir) return s.lerr(tag, E.NOTDIR);
        var buf: [1 << 16]u8 = undefined;
        var w: wire.Writer = .{ .b = buf[0..@min(buf.len, count)] };
        const kids = f.node.children.items;
        var i: u64 = offset;
        while (i < kids.len + 2) : (i += 1) {
            const node = switch (i) {
                0 => f.node,
                1 => f.node.parent orelse f.node,
                else => kids[i - 2],
            };
            const e: wire.DirEntry = .{
                .qid = node.qid(),
                .offset = i + 1,
                .type = if (i < 2) attr.DT_DIR else attr.DT_REG,
                .name = switch (i) {
                    0 => ".",
                    1 => "..",
                    else => node.name,
                },
                .stat = if (attrs) node.stat() else null,
            };
            wire.putDirEntry(&w, e) catch break;
        }
        if (attrs)
            try s.send(tag, l.Rreaddirattr{ .data = .{ .bytes = buf[0..w.at] } })
        else
            try s.send(tag, l.Rreaddir{ .data = .{ .bytes = buf[0..w.at] } });
    }

    /// Walks `names` from `n` as far as they go: the node reached, and
    /// how many names were walked, their qids in `qids`.
    fn walkNames(from: *Node, names: []const []const u8, qids: []wire.Qid) struct { *Node, usize } {
        var n = from;
        var k: usize = 0;
        for (names) |name| {
            if (n.kind != .dir) break;
            n = if (std.mem.eql(u8, name, "..")) (n.parent orelse n) else (n.child(name) orelse break);
            qids[k] = n.qid();
            k += 1;
        }
        return .{ n, k };
    }

    fn nodeByPath(n: *Node, path: u64) ?*Node {
        if (n.path == path) return n;
        for (n.children.items) |c| if (nodeByPath(c, path)) |f| return f;
        return null;
    }

    fn handleMsg(s: *Server, d: wire.Frame(l.T)) !void {
        const tag = d.tag;
        const a = s.arena.allocator();
        switch (d.msg) {
            .Tversion => |v| {
                s.msize = @min(s.msize, v.msize);
                var ver = s.version;
                if (!std.mem.eql(u8, v.version, s.version)) {
                    if (s.strict_version) {
                        ver = "unknown";
                    } else if (std.mem.eql(u8, s.version, wire.version_lz)) {
                        ver = wire.version_l;
                    }
                }
                s.lz = std.mem.eql(u8, ver, wire.version_lz);
                try s.send(tag, wire.common.Rversion{ .msize = s.msize, .version = ver });
            },
            .Trebind => |rb| {
                if (!s.lz) return s.lerr(tag, E.OPNOTSUPP);
                const n = nodeByPath(s.root, rb.inode_id) orelse return s.lerr(tag, E.NOENT);
                try s.fids.put(s.gpa, rb.fid, .{ .node = n });
                try s.send(tag, l.Rrebind{ .qid = n.qid() });
            },
            .Tattach => |at| {
                s.attached_as = .{ try a.dupe(u8, at.uname), at.n_uname };
                try s.fids.put(s.gpa, at.fid, .{ .node = s.root });
                try s.send(tag, l.Rattach{ .qid = s.root.qid() });
            },
            .Twalk => |w| {
                const f = s.fids.get(w.fid) orelse return s.lerr(tag, E.BADF);
                if (w.newfid != w.fid and s.fids.contains(w.newfid)) return s.lerr(tag, E.BADF);
                var qids: [wire.max_welem]wire.Qid = undefined;
                const n, const k = walkNames(f.node, w.wnames.slice(), &qids);
                if (k == 0 and w.wnames.n != 0) return s.lerr(tag, if (n.kind != .dir) E.NOTDIR else E.NOENT);
                if (k == w.wnames.n) try s.fids.put(s.gpa, w.newfid, .{ .node = n });
                try s.send(tag, wire.common.Rwalk{ .wqids = .init(qids[0..k]) });
            },
            // A full walk with the destination's attributes, or an error.
            .Twalkgetattr => |w| {
                if (!s.lz) return s.lerr(tag, E.OPNOTSUPP);
                const f = s.fids.get(w.fid) orelse return s.lerr(tag, E.BADF);
                if (w.newfid != w.fid and s.fids.contains(w.newfid)) return s.lerr(tag, E.BADF);
                var qids: [wire.max_welem]wire.Qid = undefined;
                const n, const k = walkNames(f.node, w.wnames.slice(), &qids);
                if (k != w.wnames.n) return s.lerr(tag, if (n.kind != .dir) E.NOTDIR else E.NOENT);
                try s.fids.put(s.gpa, w.newfid, .{ .node = n });
                try s.send(tag, l.Rwalkgetattr{ .wqids = .init(qids[0..k]), .stat = n.stat() });
            },
            .Treadlink => |r| {
                const f = s.fids.get(r.fid) orelse return s.lerr(tag, E.BADF);
                if (f.node.kind != .link) return s.lerr(tag, E.INVAL);
                try s.send(tag, l.Rreadlink{ .target = f.node.target });
            },
            .Tgetattr => |g| {
                const f = s.fids.get(g.fid) orelse return s.lerr(tag, E.BADF);
                try s.send(tag, l.Rgetattr{ .valid = L.GETATTR_BASIC, .stat = f.node.stat() });
            },
            .Tlopen => |o| {
                const f = s.fids.getPtr(o.fid) orelse return s.lerr(tag, E.BADF);
                if (f.node.kind == .dir and o.flags & L.ACCMODE != L.RDONLY) return s.lerr(tag, E.ISDIR);
                if (o.flags & L.TRUNC != 0) f.node.data.items.len = 0;
                f.open = true;
                try s.send(tag, l.Rlopen{ .qid = f.node.qid(), .iounit = 0 });
            },
            // Opens a copy of the fid, and reads from 0.
            .Tlopenatread => |o| {
                if (!s.lz) return s.lerr(tag, E.OPNOTSUPP);
                const f = s.fids.get(o.fid) orelse return s.lerr(tag, E.BADF);
                if (f.open or s.fids.contains(o.newfid)) return s.lerr(tag, E.BADF);
                if (f.node.kind == .dir) return s.lerr(tag, E.ISDIR);
                if (o.flags & L.TRUNC != 0) f.node.data.items.len = 0;
                try s.fids.put(s.gpa, o.newfid, .{ .node = f.node, .open = true });
                const data = f.node.data.items;
                const n = @min(data.len, o.count, s.msize - (wire.header_size + wire.Qid.wire_size + 4 + 1 + 4));
                try s.send(tag, l.Rlopenatread{ .qid = f.node.qid(), .iounit = 0, .eof = @intFromBool(n == data.len), .data = .{ .bytes = data[0..n] } });
            },
            .Tread => |r| {
                const f = s.fids.get(r.fid) orelse return s.lerr(tag, E.BADF);
                if (!f.open) return s.lerr(tag, E.BADF);
                const data = f.node.data.items;
                const off = @min(r.offset, data.len);
                const n = @min(data.len - off, r.count);
                try s.send(tag, wire.common.Rread{ .data = .{ .bytes = data[off..][0..n] } });
            },
            .Twrite => |w| {
                const f = s.fids.get(w.fid) orelse return s.lerr(tag, E.BADF);
                if (!f.open) return s.lerr(tag, E.BADF);
                const end = w.offset + w.data.bytes.len;
                if (f.node.data.items.len < end) try f.node.data.appendNTimes(a, 0, end - f.node.data.items.len);
                @memcpy(f.node.data.items[w.offset..end], w.data.bytes);
                try s.send(tag, wire.common.Rwrite{ .count = @intCast(w.data.bytes.len) });
            },
            .Treaddir => |r| try s.readDir(tag, r.fid, r.offset, r.count, false),
            .Treaddirattr => |r| try s.readDir(tag, r.fid, r.offset, r.count, true),
            .Tlcreate => |cr| {
                const f = s.fids.getPtr(cr.fid) orelse return s.lerr(tag, E.BADF);
                if (f.node.child(cr.name) != null) return s.lerr(tag, E.EXIST);
                const n = try s.newNode(f.node, cr.name, .file);
                n.mode = cr.mode;
                n.uid = 1000;
                f.node = n;
                f.open = true;
                try s.send(tag, l.Rlcreate{ .qid = n.qid(), .iounit = 0 });
            },
            // Creates and opens newfid, and keeps dfid.
            .Tlcreateattr => |cr| {
                if (!s.lz) return s.lerr(tag, E.OPNOTSUPP);
                const f = s.fids.get(cr.dfid) orelse return s.lerr(tag, E.BADF);
                if (s.fids.contains(cr.newfid)) return s.lerr(tag, E.BADF);
                if (f.node.child(cr.name) != null) return s.lerr(tag, E.EXIST);
                const n = try s.newNode(f.node, cr.name, .file);
                n.mode = cr.mode;
                n.uid = 1000;
                try s.fids.put(s.gpa, cr.newfid, .{ .node = n, .open = true });
                try s.send(tag, l.Rlcreateattr{ .iounit = 0, .stat = n.stat() });
            },
            .Tmkdir => |m| {
                const f = s.fids.get(m.dfid) orelse return s.lerr(tag, E.BADF);
                if (f.node.child(m.name) != null) return s.lerr(tag, E.EXIST);
                const n = try s.newNode(f.node, m.name, .dir);
                n.mode = m.mode;
                try s.send(tag, l.Rmkdir{ .qid = n.qid() });
            },
            .Tunlinkat => |u| {
                const f = s.fids.get(u.dirfid) orelse return s.lerr(tag, E.BADF);
                const n = f.node.child(u.name) orelse return s.lerr(tag, E.NOENT);
                if (n.kind == .dir and u.flags & L.AT_REMOVEDIR == 0) return s.lerr(tag, E.ISDIR);
                if (n.kind != .dir and u.flags & L.AT_REMOVEDIR != 0) return s.lerr(tag, E.NOTDIR);
                if (n.children.items.len != 0) return s.lerr(tag, E.NOTEMPTY);
                for (f.node.children.items, 0..) |c, i| if (c == n) {
                    _ = f.node.children.orderedRemove(i);
                    break;
                };
                try s.send(tag, l.Runlinkat{});
            },
            .Trenameat => |r| {
                const od = s.fids.get(r.olddirfid) orelse return s.lerr(tag, E.BADF);
                const nd = s.fids.get(r.newdirfid) orelse return s.lerr(tag, E.BADF);
                const n = od.node.child(r.oldname) orelse return s.lerr(tag, E.NOENT);
                if (nd.node.child(r.newname) != null) return s.lerr(tag, E.EXIST);
                for (od.node.children.items, 0..) |c, i| if (c == n) {
                    _ = od.node.children.orderedRemove(i);
                    break;
                };
                n.name = try a.dupe(u8, r.newname);
                n.parent = nd.node;
                try nd.node.children.append(a, n);
                try s.send(tag, l.Rrenameat{});
            },
            .Tsetattr => |sa| {
                const f = s.fids.get(sa.fid) orelse return s.lerr(tag, E.BADF);
                if (sa.valid & L.SETATTR_MODE != 0) f.node.mode = sa.mode & 0o7777;
                if (sa.valid & L.SETATTR_SIZE != 0) {
                    const len: usize = @intCast(sa.size);
                    if (f.node.data.items.len < len) try f.node.data.appendNTimes(a, 0, len - f.node.data.items.len) else f.node.data.items.len = len;
                }
                if (sa.valid & L.SETATTR_MTIME_SET != 0) f.node.mtime = sa.mtime_sec;
                try s.send(tag, l.Rsetattr{});
            },
            .Tfsync => |fs| {
                _ = s.fids.get(fs.fid) orelse return s.lerr(tag, E.BADF);
                try s.send(tag, l.Rfsync{});
            },
            .Tclunk => |cl| {
                if (!s.fids.remove(cl.fid)) return s.lerr(tag, E.BADF);
                try s.send(tag, wire.common.Rclunk{});
            },
            else => try s.lerr(tag, E.OPNOTSUPP),
        }
    }
};
