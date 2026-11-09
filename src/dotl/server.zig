//! The server side of the 9P2000.L translator (design/0022-dotl.md,
//! "Serving 9P2000.L"): 9P2000.L from a Linux client on one side, 9P2000
//! to the connection's exportfs on the other.
//!
//! Like the client side it's a state machine over bytes, with no I/O of
//! its own: the caller feeds it what the client sends (`fromClient`) and
//! what exportfs writes (`fromExport`), and sends on what it queues
//! (`toClient`, `toExport`).
//!
//! The client's first Tversion picks the dialect. `9P2000.L` translates,
//! `9P2000.L.Z` is answered with `9P2000.L` (version(5) lets a server
//! pick), and anything else passes through to exportfs both ways
//! unchanged, so a 9P2000 client mounts it directly and exportfs answers
//! a version it doesn't know.
//!
//! One client request can take several exportfs requests (a Tmkdir is a
//! walk, a create, and a clunk), so each is an `Op`, and the translator
//! allocates exportfs's tags and fids itself.

const std = @import("std");
const wire = @import("wire.zig");
const attr = @import("attr.zig");

const Allocator = std.mem.Allocator;
const p9 = wire.p9;
const l = wire.l;
const L = wire.L;
const E = attr.E;

pub const Options = struct {
    users: attr.UserMap,
    /// Seconds since the epoch, for a Tsetattr that sets a time to now.
    now: *const fn () u32 = zeroTime,
    /// The largest msize offered to exportfs.
    msize: u32 = 1 << 16,
};

fn zeroTime() u32 {
    return 0;
}

pub const Dialect = enum { negotiating, @"9P2000", @"9P2000.L", failed };

const Fid = struct {
    efid: u32,
    qid: wire.Qid,
    /// A directory's listing for Treaddir, read whole at offset 0: each
    /// entry encoded, and whether it's loaded.
    listing: std.ArrayList(u8) = .empty,
    offsets: std.ArrayList(u32) = .empty,
    listed: bool = false,
    listed_gen: u64 = 0,
};

const Kind = enum {
    version,
    attach,
    walk,
    lopen,
    lcreate,
    mkdir,
    read,
    write,
    clunk,
    getattr,
    setattr,
    readdir,
    unlinkat,
    renameat,
    fsync,
    /// A Tflush to exportfs for the client's, for op `target`.
    flush,
    /// A clunk of the translator's own, whose reply frees the fid.
    drop,
};

const Op = struct {
    arena: std.heap.ArenaAllocator,
    /// The client's tag, and exportfs's for the request out.
    ctag: u16,
    etag: u16 = 0,
    kind: Kind,
    step: u32 = 0,
    fid: u32 = 0,
    newfid: u32 = 0,
    /// exportfs fids this op made, clunked if it fails.
    tmp: u32 = wire.nofid,
    tmp2: u32 = wire.nofid,
    name: []const u8 = "",
    name2: []const u8 = "",
    nwalk: u16 = 0,
    qid: wire.Qid = .{},
    count: u32 = 0,
    offset: u64 = 0,
    /// exportfs's offset in a directory being read.
    eoff: u64 = 0,
    retried: bool = false,
    /// Flushed by the client: whatever exportfs answers is dropped, and
    /// the op is freed with the flush's answer (`answered` once exportfs
    /// answered the op itself).
    flushed: bool = false,
    answered: bool = false,
    target: ?*Op = null,

    fn allocator(op: *Op) Allocator {
        return op.arena.allocator();
    }
};

pub const Server = struct {
    gpa: Allocator,
    opts: Options,
    dialect: Dialect = .negotiating,
    err: ?[]const u8 = null,
    msize: u32 = 0,
    in_client: std.ArrayList(u8) = .empty,
    out_client: std.ArrayList(u8) = .empty,
    in_export: std.ArrayList(u8) = .empty,
    out_export: std.ArrayList(u8) = .empty,
    fids: std.AutoHashMapUnmanaged(u32, *Fid) = .empty,
    /// Ops by exportfs's tag for the request out.
    ops: std.AutoHashMapUnmanaged(u16, *Op) = .empty,
    next_tag: u16 = 0,
    next_efid: u32 = 0,
    free_efids: std.ArrayList(u32) = .empty,
    /// Counts mutations, which drop every directory listing.
    gen: u64 = 0,

    pub fn init(gpa: Allocator, opts: Options) Server {
        return .{ .gpa = gpa, .opts = opts };
    }

    pub fn deinit(s: *Server) void {
        var fi = s.fids.valueIterator();
        while (fi.next()) |f| s.freeFid(f.*);
        s.fids.deinit(s.gpa);
        var oi = s.ops.valueIterator();
        while (oi.next()) |op| {
            if (op.*.target) |t| if (t.answered) s.endOp(t);
            s.endOp(op.*);
        }
        s.ops.deinit(s.gpa);
        s.in_client.deinit(s.gpa);
        s.out_client.deinit(s.gpa);
        s.in_export.deinit(s.gpa);
        s.out_export.deinit(s.gpa);
        s.free_efids.deinit(s.gpa);
        locks.dropOwner(@intFromPtr(s));
    }

    pub fn version(s: *const Server) Dialect {
        return s.dialect;
    }

    /// Bytes for exportfs, and dropping what was sent.
    pub fn toExport(s: *const Server) []const u8 {
        return s.out_export.items;
    }

    pub fn consumedExport(s: *Server, n: usize) void {
        consume(&s.out_export, n);
    }

    /// Bytes for the client.
    pub fn toClient(s: *const Server) []const u8 {
        return s.out_client.items;
    }

    pub fn consumedClient(s: *Server, n: usize) void {
        consume(&s.out_client, n);
    }

    fn consume(b: *std.ArrayList(u8), n: usize) void {
        std.mem.copyForwards(u8, b.items, b.items[n..]);
        b.items.len -= n;
    }

    /// What the client sent.
    pub fn fromClient(s: *Server, bytes: []const u8) Allocator.Error!void {
        if (s.dialect == .@"9P2000") return s.out_export.appendSlice(s.gpa, bytes);
        if (s.dialect == .failed) return;
        try s.in_client.appendSlice(s.gpa, bytes);
        while (s.dialect != .failed) {
            const max = if (s.msize != 0) s.msize else s.opts.msize + 4096;
            const h = wire.header(s.in_client.items, max) catch return s.fail("bad 9P message from the client");
            const hd = h orelse return;
            if (s.in_client.items.len < hd.size) return;
            const frame = try s.gpa.dupe(u8, s.in_client.items[0..hd.size]);
            defer s.gpa.free(frame);
            consume(&s.in_client, hd.size);
            if (s.dialect == .negotiating) {
                try s.negotiate(frame);
                if (s.dialect == .@"9P2000") {
                    // What came after the Tversion goes too.
                    try s.out_export.appendSlice(s.gpa, s.in_client.items);
                    s.in_client.items.len = 0;
                    return;
                }
                continue;
            }
            const d = wire.decode(l.T, frame, s.msize, false) catch {
                // A message .L has that this side doesn't serve, or a
                // malformed one: refused, not fatal.
                try s.lerror(hd.tag, E.OPNOTSUPP);
                continue;
            };
            try s.request(d.tag, d.msg);
        }
    }

    /// What exportfs wrote.
    pub fn fromExport(s: *Server, bytes: []const u8) Allocator.Error!void {
        if (s.dialect == .@"9P2000") return s.out_client.appendSlice(s.gpa, bytes);
        if (s.dialect == .failed) return;
        try s.in_export.appendSlice(s.gpa, bytes);
        while (s.dialect != .failed) {
            const h = wire.header(s.in_export.items, s.opts.msize + 4096) catch return s.fail("bad 9P message from exportfs");
            const hd = h orelse return;
            if (s.in_export.items.len < hd.size) return;
            const frame = try s.gpa.dupe(u8, s.in_export.items[0..hd.size]);
            defer s.gpa.free(frame);
            consume(&s.in_export, hd.size);
            const d = wire.decode(p9.R, frame, s.opts.msize + 4096, false) catch return s.fail("bad 9P message from exportfs");
            const kv = s.ops.fetchRemove(d.tag) orelse continue;
            try s.reply(kv.value, d.msg);
        }
    }

    fn fail(s: *Server, msg: []const u8) Allocator.Error!void {
        s.dialect = .failed;
        s.err = msg;
    }

    /// The client's first message: a Tversion picks the dialect.
    fn negotiate(s: *Server, frame: []const u8) Allocator.Error!void {
        const d = wire.decode(p9.T, frame, std.math.maxInt(u32), false) catch null;
        const v = if (d) |x| (if (x.msg == .Tversion) x.msg.Tversion else null) else null;
        if (v == null or !std.mem.startsWith(u8, v.?.version, wire.version_l)) {
            // 9P2000, or anything else: exportfs's to answer.
            s.dialect = .@"9P2000";
            return s.out_export.appendSlice(s.gpa, frame);
        }
        if (v.?.msize < 256) {
            try s.lerror(d.?.tag, E.INVAL);
            return s.fail("msize too small");
        }
        const op = try s.newOp(d.?.tag, .version);
        try s.send(op, wire.common.Tversion{ .msize = @min(v.?.msize, s.opts.msize), .version = wire.version_9p });
        s.dialect = .@"9P2000.L";
        // Requests wait for the Rversion: msize is 0 until then, which
        // fails any frame, so hold them by leaving msize for the reply.
        s.msize = @min(v.?.msize, s.opts.msize);
    }

    // Sending.

    fn put(s: *Server, out: *std.ArrayList(u8), tag: u16, msg: anytype) Allocator.Error!void {
        var need: usize = 256;
        while (true) {
            try out.ensureUnusedCapacity(s.gpa, need);
            const f = wire.encode(out.unusedCapacitySlice(), tag, msg, null) catch {
                need *= 4;
                continue;
            };
            out.items.len += f.len;
            return;
        }
    }

    fn sendClient(s: *Server, tag: u16, msg: anytype) Allocator.Error!void {
        return s.put(&s.out_client, tag, msg);
    }

    fn lerror(s: *Server, tag: u16, e: u32) Allocator.Error!void {
        return s.sendClient(tag, l.Rlerror{ .ecode = e });
    }

    fn allocTag(s: *Server) u16 {
        while (true) {
            const t = s.next_tag;
            s.next_tag +%= 1;
            if (s.next_tag == wire.notag) s.next_tag = 0;
            if (!s.ops.contains(t)) return t;
        }
    }

    /// Sends `msg` to exportfs as `op`'s next step.
    fn send(s: *Server, op: *Op, msg: anytype) Allocator.Error!void {
        op.etag = if (op.kind == .version) wire.notag else s.allocTag();
        try s.ops.put(s.gpa, op.etag, op);
        return s.put(&s.out_export, op.etag, msg);
    }

    fn allocEfid(s: *Server) u32 {
        if (s.free_efids.pop()) |f| return f;
        defer s.next_efid += 1;
        return s.next_efid;
    }

    /// Clunks an exportfs fid; the reply is ignored.
    fn clunkEfid(s: *Server, efid: u32) Allocator.Error!void {
        const op = try s.newOp(wire.notag, .drop);
        op.tmp = efid;
        try s.send(op, wire.common.Tclunk{ .fid = efid });
    }

    fn newOp(s: *Server, ctag: u16, kind: Kind) Allocator.Error!*Op {
        const op = try s.gpa.create(Op);
        op.* = .{ .arena = .init(s.gpa), .ctag = ctag, .kind = kind };
        return op;
    }

    fn endOp(s: *Server, op: *Op) void {
        op.arena.deinit();
        s.gpa.destroy(op);
    }

    fn finish(s: *Server, op: *Op, msg: anytype) Allocator.Error!void {
        try s.sendClient(op.ctag, msg);
        s.endOp(op);
    }

    /// Ends `op` with errno `e`, clunking the fids it made.
    fn finishErrno(s: *Server, op: *Op, e: u32) Allocator.Error!void {
        if (op.tmp != wire.nofid) try s.clunkEfid(op.tmp);
        if (op.tmp2 != wire.nofid) try s.clunkEfid(op.tmp2);
        try s.lerror(op.ctag, e);
        s.endOp(op);
    }

    fn freeFid(s: *Server, f: *Fid) void {
        f.listing.deinit(s.gpa);
        f.offsets.deinit(s.gpa);
        s.gpa.destroy(f);
    }

    fn addFid(s: *Server, fid: u32, efid: u32, qid: wire.Qid) Allocator.Error!void {
        const f = try s.gpa.create(Fid);
        f.* = .{ .efid = efid, .qid = qid };
        if (try s.fids.fetchPut(s.gpa, fid, f)) |old| {
            if (old.value.efid != efid) try s.clunkEfid(old.value.efid);
            s.freeFid(old.value);
        }
    }

    // The client's requests.

    fn request(s: *Server, tag: u16, msg: l.T) Allocator.Error!void {
        switch (msg) {
            .Tversion => return s.lerror(tag, E.INVAL),
            .Tflush => |fl| return s.flush(tag, fl.oldtag),
            .Tattach => |a| {
                if (s.fids.contains(a.fid)) return s.lerror(tag, E.BADF);
                const op = try s.newOp(tag, .attach);
                op.fid = a.fid;
                op.tmp = s.allocEfid();
                var nb: [10]u8 = undefined;
                const uname = try op.allocator().dupe(u8, s.opts.users.name(a.n_uname, &nb));
                try s.send(op, p9.Tattach{ .fid = op.tmp, .afid = wire.nofid, .uname = uname, .aname = a.aname });
            },
            .Twalk => |w| {
                const f = s.fids.get(w.fid) orelse return s.lerror(tag, E.BADF);
                if (w.newfid != w.fid and s.fids.contains(w.newfid)) return s.lerror(tag, E.BADF);
                const op = try s.newOp(tag, .walk);
                op.fid = w.fid;
                op.newfid = w.newfid;
                op.nwalk = w.wnames.n;
                op.qid = f.qid;
                const efid = if (w.newfid == w.fid) f.efid else s.allocEfid();
                if (w.newfid != w.fid) op.tmp = efid;
                try s.send(op, wire.common.Twalk{ .fid = f.efid, .newfid = efid, .wnames = w.wnames });
            },
            .Tlopen => |o| {
                const f = s.fids.get(o.fid) orelse return s.lerror(tag, E.BADF);
                const op = try s.newOp(tag, .lopen);
                op.fid = o.fid;
                if (o.flags & L.TRUNC != 0) s.gen += 1;
                try s.send(op, p9.Topen{ .fid = f.efid, .mode = attr.openMode(o.flags) });
            },
            .Tlcreate => |cr| {
                const f = s.fids.get(cr.fid) orelse return s.lerror(tag, E.BADF);
                const op = try s.newOp(tag, .lcreate);
                op.fid = cr.fid;
                s.gen += 1;
                try s.send(op, p9.Tcreate{ .fid = f.efid, .name = cr.name, .perm = cr.mode & 0o777, .mode = attr.openMode(cr.flags) });
            },
            .Tmkdir => |m| {
                const f = s.fids.get(m.dfid) orelse return s.lerror(tag, E.BADF);
                const op = try s.newOp(tag, .mkdir);
                op.name = try op.allocator().dupe(u8, m.name);
                op.count = m.mode & 0o777;
                op.tmp = s.allocEfid();
                s.gen += 1;
                try s.send(op, wire.common.Twalk{ .fid = f.efid, .newfid = op.tmp, .wnames = .{} });
            },
            .Tread => |r| {
                const f = s.fids.get(r.fid) orelse return s.lerror(tag, E.BADF);
                const op = try s.newOp(tag, .read);
                try s.send(op, wire.common.Tread{ .fid = f.efid, .offset = r.offset, .count = @min(r.count, s.msize - wire.io_header) });
            },
            .Twrite => |w| {
                const f = s.fids.get(w.fid) orelse return s.lerror(tag, E.BADF);
                const op = try s.newOp(tag, .write);
                s.gen += 1;
                const n = @min(w.data.bytes.len, s.msize - wire.io_header);
                try s.send(op, p9.Twrite{ .fid = f.efid, .offset = w.offset, .data = .{ .bytes = w.data.bytes[0..n] } });
            },
            .Tclunk => |cl| {
                const kv = s.fids.fetchRemove(cl.fid) orelse return s.lerror(tag, E.BADF);
                const op = try s.newOp(tag, .clunk);
                op.tmp = kv.value.efid;
                s.freeFid(kv.value);
                try s.send(op, wire.common.Tclunk{ .fid = op.tmp });
            },
            .Tgetattr => |g| {
                const f = s.fids.get(g.fid) orelse return s.lerror(tag, E.BADF);
                const op = try s.newOp(tag, .getattr);
                try s.send(op, p9.Tstat{ .fid = f.efid });
            },
            .Tsetattr => |sa| {
                const f = s.fids.get(sa.fid) orelse return s.lerror(tag, E.BADF);
                var d = attr.wstatFromSetattr(sa.valid, sa.mode, sa.size, sa.mtime_sec, s.opts.now());
                if (d.mode != attr.Dir.keep.mode and f.qid.type & wire.QTDIR != 0) d.mode |= wire.DMDIR;
                // Only owner, group, or atime: nothing 9P2000 can carry.
                if (d.mode == attr.Dir.keep.mode and d.length == attr.Dir.keep.length and d.mtime == attr.Dir.keep.mtime)
                    return s.sendClient(tag, l.Rsetattr{});
                const op = try s.newOp(tag, .setattr);
                s.gen += 1;
                return s.wstat(op, f.efid, &d);
            },
            .Treaddir => |r| {
                const f = s.fids.get(r.fid) orelse return s.lerror(tag, E.BADF);
                if (f.qid.type & wire.QTDIR == 0) return s.lerror(tag, E.NOTDIR);
                if (r.offset != 0 and f.listed and f.listed_gen == s.gen) return s.deliverDir(tag, f, r.offset, r.count);
                // Read the whole directory, from the start.
                f.listing.items.len = 0;
                f.offsets.items.len = 0;
                f.listed = false;
                const op = try s.newOp(tag, .readdir);
                op.fid = r.fid;
                op.offset = r.offset;
                op.count = r.count;
                try s.dirSelf(f);
                try s.send(op, wire.common.Tread{ .fid = f.efid, .offset = 0, .count = s.msize - wire.io_header });
            },
            .Tunlinkat => |u| {
                const f = s.fids.get(u.dirfid) orelse return s.lerror(tag, E.BADF);
                const op = try s.newOp(tag, .unlinkat);
                op.tmp = s.allocEfid();
                s.gen += 1;
                try s.send(op, wire.common.Twalk{ .fid = f.efid, .newfid = op.tmp, .wnames = .init(&.{u.name}) });
            },
            .Trenameat => |r| {
                const from = s.fids.get(r.olddirfid) orelse return s.lerror(tag, E.BADF);
                const to = s.fids.get(r.newdirfid) orelse return s.lerror(tag, E.BADF);
                // Plan 9 renames only within a directory.
                if (from.qid.path != to.qid.path) return s.lerror(tag, E.XDEV);
                const op = try s.newOp(tag, .renameat);
                op.fid = r.olddirfid;
                op.name = try op.allocator().dupe(u8, r.oldname);
                op.name2 = try op.allocator().dupe(u8, r.newname);
                op.tmp = s.allocEfid();
                s.gen += 1;
                try s.send(op, wire.common.Twalk{ .fid = from.efid, .newfid = op.tmp, .wnames = .init(&.{op.name}) });
            },
            .Tfsync => |fs| {
                const f = s.fids.get(fs.fid) orelse return s.lerror(tag, E.BADF);
                const op = try s.newOp(tag, .fsync);
                var d = attr.Dir.keep;
                return s.wstat(op, f.efid, &d);
            },
            .Tstatfs => |st| {
                if (!s.fids.contains(st.fid)) return s.lerror(tag, E.BADF);
                return s.sendClient(tag, l.Rstatfs{
                    .type = 0x01021997, // V9FS_MAGIC
                    .bsize = 8192,
                    .blocks = 1 << 24,
                    .bfree = 1 << 23,
                    .bavail = 1 << 23,
                    .files = 1 << 20,
                    .ffree = 1 << 19,
                    .fsid = 0,
                    .namelen = 255,
                });
            },
            .Tlock => |lk| {
                const f = s.fids.get(lk.fid) orelse return s.lerror(tag, E.BADF);
                return s.sendClient(tag, l.Rlock{ .status = locks.lock(@intFromPtr(s), f.qid.path, lk.proc_id, lk.type, lk.start, lk.length) });
            },
            .Tgetlock => |gl| {
                const f = s.fids.get(gl.fid) orelse return s.lerror(tag, E.BADF);
                var r: l.Rgetlock = .{ .type = L.LOCK_UNLCK, .start = gl.start, .length = gl.length, .proc_id = gl.proc_id, .client_id = gl.client_id };
                if (locks.conflict(@intFromPtr(s), f.qid.path, gl.proc_id, gl.type, gl.start, gl.length)) |c| {
                    r = .{ .type = c.type, .start = c.start, .length = c.length, .proc_id = c.proc_id, .client_id = "" };
                }
                return s.sendClient(tag, r);
            },
            .Treadlink => return s.lerror(tag, E.INVAL),
            else => return s.lerror(tag, E.OPNOTSUPP),
        }
    }

    /// A wstat of `d` on exportfs fid `efid` as `op`'s next step.
    fn wstat(s: *Server, op: *Op, efid: u32, d: *const attr.Dir) Allocator.Error!void {
        var buf: [512]u8 = undefined;
        const b = d.pack(&buf) catch return s.finishErrno(op, E.INVAL);
        const stat = try op.allocator().dupe(u8, b);
        return s.send(op, p9.Twstat{ .fid = efid, .stat = .{ .bytes = stat } });
    }

    fn flush(s: *Server, tag: u16, oldtag: u16) Allocator.Error!void {
        var it = s.ops.valueIterator();
        while (it.next()) |o| {
            const op = o.*;
            if (op.ctag != oldtag or op.flushed or op.kind == .version or op.kind == .flush or op.kind == .drop) continue;
            op.flushed = true;
            const f = try s.newOp(tag, .flush);
            f.target = op;
            return s.send(f, wire.common.Tflush{ .oldtag = op.etag });
        }
        return s.sendClient(tag, wire.common.Rflush{});
    }

    // exportfs's replies.

    fn errnoOf(msg: p9.R) ?u32 {
        return switch (msg) {
            .Rerror => |e| attr.errno(e.ename),
            else => null,
        };
    }

    fn reply(s: *Server, op: *Op, msg: p9.R) Allocator.Error!void {
        switch (op.kind) {
            .drop => {
                try s.free_efids.append(s.gpa, op.tmp);
                s.endOp(op);
                return;
            },
            .flush => {
                // exportfs answers the flushed request, if at all, before
                // the Rflush: if it didn't, the request is gone.
                const t = op.target.?;
                if (!t.answered) {
                    _ = s.ops.remove(t.etag);
                    try s.dropFlushed(t, null);
                }
                s.endOp(t);
                return s.finish(op, wire.common.Rflush{});
            },
            else => {},
        }
        if (op.flushed) {
            op.answered = true;
            return s.dropFlushed(op, msg);
        }
        switch (op.kind) {
            .version => {
                if (msg != .Rversion or !std.mem.startsWith(u8, msg.Rversion.version, wire.version_9p)) {
                    try s.lerror(op.ctag, E.INVAL);
                    s.endOp(op);
                    return s.fail("exportfs refused 9P2000");
                }
                if (msg.Rversion.msize < 256) {
                    try s.lerror(op.ctag, E.INVAL);
                    s.endOp(op);
                    return s.fail("exportfs's msize is too small");
                }
                s.msize = @min(s.msize, msg.Rversion.msize);
                return s.finish(op, l.Rversion{ .msize = s.msize, .version = wire.version_l });
            },
            .attach => {
                if (errnoOf(msg)) |e| {
                    try s.free_efids.append(s.gpa, op.tmp);
                    op.tmp = wire.nofid;
                    return s.finishErrno(op, e);
                }
                if (msg != .Rattach) return s.finishErrno(op, E.IO);
                try s.addFid(op.fid, op.tmp, msg.Rattach.qid);
                return s.finish(op, l.Rattach{ .qid = msg.Rattach.qid });
            },
            .walk => {
                if (errnoOf(msg)) |e| {
                    if (op.tmp != wire.nofid) try s.free_efids.append(s.gpa, op.tmp);
                    op.tmp = wire.nofid;
                    return s.finishErrno(op, e);
                }
                if (msg != .Rwalk) return s.finishErrno(op, E.IO);
                const q = msg.Rwalk.wqids.slice();
                if (q.len == op.nwalk) {
                    const qid = if (q.len == 0) op.qid else q[q.len - 1];
                    if (op.newfid == op.fid) {
                        if (s.fids.get(op.fid)) |f| f.qid = qid;
                    } else {
                        try s.addFid(op.newfid, op.tmp, qid);
                    }
                } else if (op.tmp != wire.nofid) {
                    // A partial walk makes no fid.
                    try s.free_efids.append(s.gpa, op.tmp);
                }
                return s.finish(op, wire.common.Rwalk{ .wqids = msg.Rwalk.wqids });
            },
            .lopen => {
                if (errnoOf(msg)) |e| return s.finishErrno(op, e);
                if (msg != .Ropen) return s.finishErrno(op, E.IO);
                if (s.fids.get(op.fid)) |f| f.qid = msg.Ropen.qid;
                return s.finish(op, l.Rlopen{ .qid = msg.Ropen.qid, .iounit = msg.Ropen.iounit });
            },
            .lcreate => {
                if (errnoOf(msg)) |e| return s.finishErrno(op, e);
                if (msg != .Rcreate) return s.finishErrno(op, E.IO);
                if (s.fids.get(op.fid)) |f| f.qid = msg.Rcreate.qid;
                return s.finish(op, l.Rlcreate{ .qid = msg.Rcreate.qid, .iounit = msg.Rcreate.iounit });
            },
            .mkdir => return s.stepMkdir(op, msg),
            .read => {
                if (errnoOf(msg)) |e| return s.finishErrno(op, e);
                if (msg != .Rread) return s.finishErrno(op, E.IO);
                return s.finish(op, wire.common.Rread{ .data = msg.Rread.data });
            },
            .write => {
                if (errnoOf(msg)) |e| return s.finishErrno(op, e);
                if (msg != .Rwrite) return s.finishErrno(op, E.IO);
                return s.finish(op, wire.common.Rwrite{ .count = msg.Rwrite.count });
            },
            .clunk => {
                try s.free_efids.append(s.gpa, op.tmp);
                return s.finish(op, wire.common.Rclunk{});
            },
            .getattr => {
                if (errnoOf(msg)) |e| return s.finishErrno(op, e);
                if (msg != .Rstat) return s.finishErrno(op, E.IO);
                const d, _ = attr.Dir.parse(msg.Rstat.stat.bytes) orelse return s.finishErrno(op, E.IO);
                const st = attr.statFromDir(&d, s.opts.users.number(d.uid), s.opts.users.number(d.gid));
                return s.finish(op, l.Rgetattr{ .valid = L.GETATTR_BASIC, .stat = st });
            },
            .setattr => {
                if (errnoOf(msg)) |e| return s.finishErrno(op, e);
                return s.finish(op, l.Rsetattr{});
            },
            .fsync => {
                // A file server that can't sync has nothing to sync.
                return s.finish(op, l.Rfsync{});
            },
            .flush, .drop => unreachable,
            .readdir => return s.stepReaddir(op, msg),
            .unlinkat => return s.stepUnlinkat(op, msg),
            .renameat => return s.stepRenameat(op, msg),
        }
    }

    /// Cleans up after a flushed op, with exportfs's answer if it gave
    /// one: what the op made on exportfs still has to go. The flush's
    /// answer frees it.
    fn dropFlushed(s: *Server, op: *Op, msg: ?p9.R) Allocator.Error!void {
        const ok = if (msg) |m| errnoOf(m) == null else false;
        var made = false;
        if (ok) switch (op.kind) {
            .walk => made = op.tmp != wire.nofid and msg.? == .Rwalk and msg.?.Rwalk.wqids.n == op.nwalk,
            .attach => made = true,
            // A clunk or a remove gets rid of the fid either way.
            .clunk => {},
            else => {},
        };
        if (op.kind == .clunk) {
            try s.free_efids.append(s.gpa, op.tmp);
        } else if (made) {
            try s.clunkEfid(op.tmp);
        } else if (op.tmp != wire.nofid and (op.kind == .walk or op.kind == .attach)) {
            try s.free_efids.append(s.gpa, op.tmp);
        } else {
            // Mid-way through several steps: the fids it made go.
            if (op.tmp != wire.nofid) try s.clunkEfid(op.tmp);
            if (op.tmp2 != wire.nofid) try s.clunkEfid(op.tmp2);
        }
        op.tmp = wire.nofid;
        op.tmp2 = wire.nofid;
    }

    /// Tmkdir: clone the directory's fid, create in it, clunk it.
    fn stepMkdir(s: *Server, op: *Op, msg: p9.R) Allocator.Error!void {
        if (errnoOf(msg)) |e| {
            if (op.step == 0) {
                try s.free_efids.append(s.gpa, op.tmp);
                op.tmp = wire.nofid;
            }
            return s.finishErrno(op, e);
        }
        switch (op.step) {
            0 => {
                op.step = 1;
                try s.send(op, p9.Tcreate{ .fid = op.tmp, .name = op.name, .perm = wire.DMDIR | op.count, .mode = wire.OREAD });
            },
            1 => {
                if (msg != .Rcreate) return s.finishErrno(op, E.IO);
                op.qid = msg.Rcreate.qid;
                op.step = 2;
                const efid = op.tmp;
                op.tmp = wire.nofid;
                try s.clunkEfid(efid);
                return s.finish(op, l.Rmkdir{ .qid = op.qid });
            },
            else => unreachable,
        }
    }

    /// Tunlinkat: walk to the name, then remove it, which clunks it.
    fn stepUnlinkat(s: *Server, op: *Op, msg: p9.R) Allocator.Error!void {
        switch (op.step) {
            0 => {
                if (errnoOf(msg)) |e| {
                    try s.free_efids.append(s.gpa, op.tmp);
                    op.tmp = wire.nofid;
                    return s.finishErrno(op, e);
                }
                if (msg != .Rwalk or msg.Rwalk.wqids.n != 1) {
                    try s.free_efids.append(s.gpa, op.tmp);
                    op.tmp = wire.nofid;
                    return s.finishErrno(op, E.NOENT);
                }
                op.step = 1;
                try s.send(op, p9.Tremove{ .fid = op.tmp });
            },
            1 => {
                // Tremove clunks the fid, whatever happens.
                try s.free_efids.append(s.gpa, op.tmp);
                op.tmp = wire.nofid;
                if (errnoOf(msg)) |e| return s.finishErrno(op, e);
                return s.finish(op, l.Runlinkat{});
            },
            else => unreachable,
        }
    }

    /// Trenameat in one directory: walk to the old name and wstat the new
    /// one. A name that's taken is removed first, as rename(2) replaces
    /// it.
    fn stepRenameat(s: *Server, op: *Op, msg: p9.R) Allocator.Error!void {
        switch (op.step) {
            0 => {
                if (errnoOf(msg)) |e| {
                    try s.free_efids.append(s.gpa, op.tmp);
                    op.tmp = wire.nofid;
                    return s.finishErrno(op, e);
                }
                if (msg != .Rwalk or msg.Rwalk.wqids.n != 1) {
                    try s.free_efids.append(s.gpa, op.tmp);
                    op.tmp = wire.nofid;
                    return s.finishErrno(op, E.NOENT);
                }
                return s.renameNow(op);
            },
            1 => {
                if (errnoOf(msg)) |e| {
                    if (e != E.EXIST or op.retried) return s.finishErrno(op, e);
                    op.retried = true;
                    const f = s.fids.get(op.fid) orelse return s.finishErrno(op, E.BADF);
                    op.tmp2 = s.allocEfid();
                    op.step = 2;
                    return s.send(op, wire.common.Twalk{ .fid = f.efid, .newfid = op.tmp2, .wnames = .init(&.{op.name2}) });
                }
                const efid = op.tmp;
                op.tmp = wire.nofid;
                try s.clunkEfid(efid);
                return s.finish(op, l.Rrenameat{});
            },
            2 => {
                if (errnoOf(msg) != null or msg != .Rwalk or msg.Rwalk.wqids.n != 1) {
                    try s.free_efids.append(s.gpa, op.tmp2);
                    op.tmp2 = wire.nofid;
                    return s.finishErrno(op, E.EXIST);
                }
                op.step = 3;
                try s.send(op, p9.Tremove{ .fid = op.tmp2 });
            },
            3 => {
                try s.free_efids.append(s.gpa, op.tmp2);
                op.tmp2 = wire.nofid;
                if (errnoOf(msg)) |e| return s.finishErrno(op, e);
                return s.renameNow(op);
            },
            else => unreachable,
        }
    }

    fn renameNow(s: *Server, op: *Op) Allocator.Error!void {
        op.step = 1;
        var d = attr.Dir.keep;
        d.name = op.name2;
        return s.wstat(op, op.tmp, &d);
    }

    // Directory reads: the whole directory into a listing on the fid,
    // with entry indexes as offsets.

    fn putEntry(s: *Server, f: *Fid, qid: wire.Qid, dtype: u8, name: []const u8) Allocator.Error!void {
        var buf: [wire.Qid.wire_size + 8 + 1 + 2 + 512]u8 = undefined;
        var w: wire.Writer = .{ .b = &buf };
        const index: u64 = f.offsets.items.len + 1;
        wire.putDirEntry(&w, .{ .qid = qid, .offset = index, .type = dtype, .name = name }) catch return;
        try f.offsets.append(s.gpa, @intCast(f.listing.items.len));
        try f.listing.appendSlice(s.gpa, buf[0..w.at]);
    }

    /// `.` and `..`, as Linux servers list them.
    fn dirSelf(s: *Server, f: *Fid) Allocator.Error!void {
        try s.putEntry(f, f.qid, attr.DT_DIR, ".");
        try s.putEntry(f, f.qid, attr.DT_DIR, "..");
    }

    fn stepReaddir(s: *Server, op: *Op, msg: p9.R) Allocator.Error!void {
        const f = s.fids.get(op.fid) orelse return s.finishErrno(op, E.BADF);
        if (errnoOf(msg)) |e| return s.finishErrno(op, e);
        if (msg != .Rread) return s.finishErrno(op, E.IO);
        const b = msg.Rread.data.bytes;
        if (b.len == 0) {
            f.listed = true;
            f.listed_gen = s.gen;
            const tag = op.ctag;
            const off = op.offset;
            const count = op.count;
            s.endOp(op);
            return s.deliverDir(tag, f, off, count);
        }
        var at: usize = 0;
        while (at < b.len) {
            const d, const n = attr.Dir.parse(b[at..]) orelse return s.finishErrno(op, E.IO);
            at += n;
            const dir = d.mode & wire.DMDIR != 0;
            try s.putEntry(f, .{ .type = d.qid_type, .vers = d.qid_vers, .path = d.qid_path }, if (dir) attr.DT_DIR else attr.DT_REG, d.name);
        }
        op.eoff += b.len;
        try s.send(op, wire.common.Tread{ .fid = f.efid, .offset = op.eoff, .count = s.msize - wire.io_header });
    }

    /// Answers a Treaddir from the listing: the entries from index
    /// `offset`, as many as fit in `count`.
    fn deliverDir(s: *Server, tag: u16, f: *Fid, offset: u64, count: u32) Allocator.Error!void {
        const n = f.offsets.items.len;
        if (offset >= n) return s.sendClient(tag, l.Rreaddir{ .data = .{ .bytes = "" } });
        const start = f.offsets.items[@intCast(offset)];
        var end = start;
        var i: usize = @intCast(offset);
        const limit = @min(count, s.msize - wire.io_header);
        while (i < n) : (i += 1) {
            const next: u32 = if (i + 1 < n) f.offsets.items[i + 1] else @intCast(f.listing.items.len);
            if (next - start > limit) break;
            end = next;
        }
        return s.sendClient(tag, l.Rreaddir{ .data = .{ .bytes = f.listing.items[start..end] } });
    }
};

/// Advisory byte-range locks for .L clients (Tlock, Tgetlock), shared by
/// every connection a process serves: a lock is held by a connection and
/// a client process id on a file, by qid.path.
const locks = struct {
    const Lock = struct {
        owner: usize,
        path: u64,
        proc_id: u32,
        type: u8,
        start: u64,
        /// The end, exclusive; maxInt for "to the end of the file".
        end: u64,
    };

    var mu: std.atomic.Mutex = .unlocked;
    var table: std.ArrayList(Lock) = .empty;
    const gpa = std.heap.page_allocator;

    fn acquire() void {
        while (!mu.tryLock()) std.atomic.spinLoopHint();
    }

    fn endOf(start: u64, length: u64) u64 {
        return if (length == 0) std.math.maxInt(u64) else start +| length;
    }

    fn mine(k: Lock, owner: usize, proc_id: u32) bool {
        return k.owner == owner and k.proc_id == proc_id;
    }

    /// The first lock another holder has that conflicts with `type`
    /// over the range.
    fn conflict(owner: usize, path: u64, proc_id: u32, typ: u8, start: u64, length: u64) ?l.Rgetlock {
        acquire();
        defer mu.unlock();
        const end = endOf(start, length);
        for (table.items) |k| {
            if (k.path != path or mine(k, owner, proc_id)) continue;
            if (k.end <= start or end <= k.start) continue;
            if (typ == L.LOCK_RDLCK and k.type == L.LOCK_RDLCK) continue;
            return .{ .type = k.type, .start = k.start, .length = if (k.end == std.math.maxInt(u64)) 0 else k.end - k.start, .proc_id = k.proc_id, .client_id = "" };
        }
        return null;
    }

    fn lock(owner: usize, path: u64, proc_id: u32, typ: u8, start: u64, length: u64) u8 {
        if (typ != L.LOCK_UNLCK and conflict(owner, path, proc_id, typ, start, length) != null) return L.LOCK_BLOCKED;
        acquire();
        defer mu.unlock();
        const end = endOf(start, length);
        // Drop the holder's own locks over the range, keeping what's
        // outside it, then add the new one.
        var i: usize = 0;
        while (i < table.items.len) {
            const k = table.items[i];
            if (k.path != path or !mine(k, owner, proc_id) or k.end <= start or end <= k.start) {
                i += 1;
                continue;
            }
            _ = table.swapRemove(i);
            if (k.start < start) table.append(gpa, .{ .owner = owner, .path = path, .proc_id = proc_id, .type = k.type, .start = k.start, .end = start }) catch return L.LOCK_ERROR;
            if (end < k.end) table.append(gpa, .{ .owner = owner, .path = path, .proc_id = proc_id, .type = k.type, .start = end, .end = k.end }) catch return L.LOCK_ERROR;
        }
        if (typ != L.LOCK_UNLCK) table.append(gpa, .{ .owner = owner, .path = path, .proc_id = proc_id, .type = typ, .start = start, .end = end }) catch return L.LOCK_ERROR;
        return L.LOCK_SUCCESS;
    }

    /// Releases every lock a connection holds, when it ends.
    fn dropOwner(owner: usize) void {
        acquire();
        defer mu.unlock();
        var i: usize = 0;
        while (i < table.items.len) {
            if (table.items[i].owner == owner) _ = table.swapRemove(i) else i += 1;
        }
    }
};

const testing = std.testing;
const TestServer = @import("testserver.zig").Server;
const Client = @import("client.zig").Client;

/// A Linux client's view of the server side, with exportfs played by the
/// client side over a .L server in memory: .L in, 9P2000 between, .L to
/// the tree.
const Chain = struct {
    sv: Server,
    cl: Client,
    ts: *TestServer,
    next_tag: u16 = 1,
    replies: std.ArrayList(u8) = .empty,
    last: []u8 = &.{},

    fn init() !Chain {
        const ts = try TestServer.init(testing.allocator);
        ts.version = wire.version_l;
        return .{
            .sv = .init(testing.allocator, .{ .users = .{ .user = "glenda", .uid = 1000 }, .now = fixedNow }),
            .cl = try .init(testing.allocator, .{ .users = .{ .user = "glenda", .uid = 1000 }, .msize = 1 << 16, .offer_lz = false }),
            .ts = ts,
        };
    }

    fn fixedNow() u32 {
        return 1234;
    }

    fn deinit(h: *Chain) void {
        h.sv.deinit();
        h.cl.deinit();
        h.ts.deinit();
        h.replies.deinit(testing.allocator);
        testing.allocator.free(h.last);
    }

    fn pump(h: *Chain) !void {
        const a = testing.allocator;
        while (true) {
            var moved = false;
            if (h.sv.toExport().len != 0) {
                const b = try a.dupe(u8, h.sv.toExport());
                defer a.free(b);
                h.sv.consumedExport(b.len);
                try h.cl.fromMount(b);
                moved = true;
            }
            if (h.cl.toServer().len != 0) {
                const b = try a.dupe(u8, h.cl.toServer());
                defer a.free(b);
                h.cl.consumedServer(b.len);
                try h.ts.feed(b);
                moved = true;
            }
            if (h.ts.out.items.len != 0) {
                const b = try h.ts.out.toOwnedSlice(h.ts.gpa);
                defer h.ts.gpa.free(b);
                try h.cl.fromServer(b);
                moved = true;
            }
            if (h.cl.toMount().len != 0) {
                const b = try a.dupe(u8, h.cl.toMount());
                defer a.free(b);
                h.cl.consumedMount(b.len);
                try h.sv.fromExport(b);
                moved = true;
            }
            if (!moved) break;
        }
        try h.replies.appendSlice(a, h.sv.toClient());
        h.sv.consumedClient(h.sv.toClient().len);
    }

    fn rpc(h: *Chain, msg: anytype) !l.R {
        const tag = h.next_tag;
        h.next_tag += 1;
        var buf: [9000]u8 = undefined;
        try h.sv.fromClient(try wire.encode(&buf, tag, msg, null));
        try h.pump();
        const hd = (try wire.header(h.replies.items, 1 << 20)) orelse return error.NoReply;
        testing.allocator.free(h.last);
        h.last = try testing.allocator.dupe(u8, h.replies.items[0..hd.size]);
        Server.consume(&h.replies, hd.size);
        const d = try wire.decode(l.R, h.last, 1 << 20, false);
        try testing.expectEqual(tag, d.tag);
        return d.msg;
    }

    fn ok(h: *Chain, msg: anytype) !l.R {
        const r = try h.rpc(msg);
        if (r == .Rlerror) {
            std.debug.print("Rlerror: {d}\n", .{r.Rlerror.ecode});
            return error.Rlerror;
        }
        return r;
    }

    fn errno(h: *Chain, msg: anytype) !u32 {
        const r = try h.rpc(msg);
        if (r != .Rlerror) return error.NoError;
        return r.Rlerror.ecode;
    }

    fn mount(h: *Chain) !void {
        const v = try h.ok(l.Tversion{ .msize = 8192 + 24, .version = "9P2000.L" });
        try testing.expectEqualStrings("9P2000.L", v.Rversion.version);
        _ = try h.ok(l.Tattach{ .fid = 0, .afid = wire.nofid, .uname = "", .aname = "", .n_uname = 1000 });
    }
};

test "a .L client lists, reads, writes, renames, and removes" {
    var h = try Chain.init();
    defer h.deinit();
    _ = try h.ts.add("etc/motd", .file, "hello\n");
    _ = try h.ts.add("etc/passwd", .file, "root\n");
    try h.mount();
    try testing.expectEqual(Dialect.@"9P2000.L", h.sv.version());

    // Walk, getattr, open, read.
    _ = try h.ok(l.Twalk{ .fid = 0, .newfid = 1, .wnames = .init(&.{ "etc", "motd" }) });
    const g = try h.ok(l.Tgetattr{ .fid = 1, .request_mask = L.GETATTR_BASIC });
    try testing.expectEqual(@as(u64, 6), g.Rgetattr.stat.size);
    try testing.expectEqual(@as(u32, attr.S_IFREG), g.Rgetattr.stat.mode & attr.S_IFMT);
    try testing.expectEqual(@as(u32, 1000), g.Rgetattr.stat.uid);
    _ = try h.ok(l.Tlopen{ .fid = 1, .flags = L.RDONLY });
    try testing.expectEqualStrings("hello\n", (try h.ok(wire.common.Tread{ .fid = 1, .offset = 0, .count = 100 })).Rread.data.bytes);
    _ = try h.ok(wire.common.Tclunk{ .fid = 1 });

    // A partial walk answers how far it got; a first name that's missing
    // is ENOENT.
    const pw = try h.ok(l.Twalk{ .fid = 0, .newfid = 1, .wnames = .init(&.{ "etc", "nope" }) });
    try testing.expectEqual(@as(u16, 1), pw.Rwalk.wqids.n);
    try testing.expectEqual(E.NOENT, try h.errno(l.Twalk{ .fid = 0, .newfid = 1, .wnames = .init(&.{"nope"}) }));

    // Readdir, in two calls.
    _ = try h.ok(l.Twalk{ .fid = 0, .newfid = 2, .wnames = .init(&.{"etc"}) });
    _ = try h.ok(l.Tlopen{ .fid = 2, .flags = L.RDONLY | L.DIRECTORY });
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(testing.allocator);
    var off: u64 = 0;
    while (true) {
        const r = try h.ok(l.Treaddir{ .fid = 2, .offset = off, .count = 40 });
        if (r.Rreaddir.data.bytes.len == 0) break;
        var it = wire.DirEntries.init(r.Rreaddir.data.bytes, false);
        while (try it.next()) |e| {
            try names.appendSlice(testing.allocator, e.name);
            try names.append(testing.allocator, ' ');
            off = e.offset;
        }
    }
    try testing.expectEqualStrings(". .. motd passwd ", names.items);

    // Create, write, setattr, mkdir, rename, unlink.
    _ = try h.ok(l.Twalk{ .fid = 0, .newfid = 3, .wnames = .init(&.{"etc"}) });
    _ = try h.ok(l.Tlcreate{ .fid = 3, .name = "new", .flags = L.WRONLY | L.CREATE, .mode = 0o640, .gid = 1000 });
    _ = try h.ok(wire.common.Twrite{ .fid = 3, .offset = 0, .data = .{ .bytes = "abcdef" } });
    _ = try h.ok(l.Tsetattr{ .fid = 3, .valid = L.SETATTR_SIZE | L.SETATTR_MODE, .mode = 0o600, .uid = 0, .gid = 0, .size = 3, .atime_sec = 0, .atime_nsec = 0, .mtime_sec = 0, .mtime_nsec = 0 });
    _ = try h.ok(wire.common.Tclunk{ .fid = 3 });
    try testing.expectEqualStrings("abc", h.ts.lookup("etc/new").?.data.items);
    try testing.expectEqual(@as(u32, 0o600), h.ts.lookup("etc/new").?.mode & 0o777);
    // Linux makes, renames, and removes through a directory's walked fid,
    // which isn't open: 9P2000 can't walk from an open one.
    _ = try h.ok(l.Twalk{ .fid = 0, .newfid = 4, .wnames = .init(&.{"etc"}) });
    const md = try h.ok(l.Tmkdir{ .dfid = 4, .name = "sub", .mode = 0o755, .gid = 1000 });
    try testing.expectEqual(wire.QTDIR, md.Rmkdir.qid.type & wire.QTDIR);
    _ = try h.ok(l.Trenameat{ .olddirfid = 4, .oldname = "new", .newdirfid = 4, .newname = "passwd" });
    try testing.expectEqualStrings("abc", h.ts.lookup("etc/passwd").?.data.items);
    try testing.expectEqual(@as(?*@import("testserver.zig").Node, null), h.ts.lookup("etc/new"));
    _ = try h.ok(l.Tunlinkat{ .dirfid = 4, .name = "passwd", .flags = 0 });
    _ = try h.ok(l.Tunlinkat{ .dirfid = 4, .name = "sub", .flags = L.AT_REMOVEDIR });
    try testing.expectEqual(E.NOENT, try h.errno(l.Tunlinkat{ .dirfid = 4, .name = "passwd", .flags = 0 }));
    try testing.expectEqual(@as(?*@import("testserver.zig").Node, null), h.ts.lookup("etc/sub"));

    // Renames across directories aren't Plan 9's.
    try testing.expectEqual(E.XDEV, try h.errno(l.Trenameat{ .olddirfid = 4, .oldname = "motd", .newdirfid = 0, .newname = "motd" }));
    // Nor are links.
    try testing.expectEqual(E.OPNOTSUPP, try h.errno(l.Tsymlink{ .dfid = 4, .name = "l", .symtgt = "motd", .gid = 0 }));
}

test "a 9P2000 client passes through, and locks are advisory per holder" {
    var h = try Chain.init();
    defer h.deinit();
    var buf: [128]u8 = undefined;
    try h.sv.fromClient(try wire.encode(&buf, wire.notag, wire.common.Tversion{ .msize = 8216, .version = "9P2000" }, null));
    try h.pump();
    try testing.expectEqual(Dialect.@"9P2000", h.sv.version());
    const d = try wire.decode(p9.R, h.replies.items, 1 << 20, false);
    try testing.expectEqualStrings("9P2000", d.msg.Rversion.version);

    // Locks.
    const a: usize = 1;
    const b: usize = 2;
    defer locks.dropOwner(a);
    defer locks.dropOwner(b);
    try testing.expectEqual(L.LOCK_SUCCESS, locks.lock(a, 7, 1, L.LOCK_WRLCK, 0, 10));
    try testing.expectEqual(L.LOCK_BLOCKED, locks.lock(b, 7, 1, L.LOCK_RDLCK, 5, 1));
    try testing.expectEqual(L.LOCK_SUCCESS, locks.lock(b, 7, 1, L.LOCK_RDLCK, 10, 0));
    try testing.expectEqual(L.LOCK_SUCCESS, locks.lock(a, 7, 1, L.LOCK_UNLCK, 0, 0));
    try testing.expectEqual(L.LOCK_SUCCESS, locks.lock(b, 7, 1, L.LOCK_RDLCK, 5, 1));
    try testing.expect(locks.conflict(a, 7, 1, L.LOCK_WRLCK, 0, 0) != null);
}

test "fuzz: hostile bytes from the client and from exportfs" {
    try testing.fuzz({}, struct {
        fn one(_: void, smith: *testing.Smith) anyerror!void {
            var sv: Server = .init(testing.allocator, .{ .users = .{ .user = "glenda", .uid = 1000 } });
            defer sv.deinit();
            var buf: [64]u8 = undefined;
            try sv.fromClient(try wire.encode(&buf, 1, wire.common.Tversion{ .msize = 8216, .version = "9P2000.L" }, null));
            var in: [2048]u8 = undefined;
            const n = smith.slice(&in);
            const half = n / 2;
            try sv.fromClient(in[0..half]);
            try sv.fromExport(in[half..n]);
        }
    }.one, .{});
}
