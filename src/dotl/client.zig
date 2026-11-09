//! The client side of the 9P2000.L translator (design/0022-dotl.md, "The
//! translator"): 9P2000 from devmnt on one side, a 9P2000.L server on the
//! other.
//!
//! It's a state machine over bytes, with no I/O of its own: the caller
//! feeds it what devmnt writes (`fromMount`) and what the server sends
//! (`fromServer`), and sends on what it queues (`toServer`, `toMount`).
//! So it's tested with a server in memory and no kernel.
//!
//! It negotiates the dialect itself. devmnt's Tversion waits for the
//! server's answer to the translator's own: `9P2000.L` translates, and
//! `9P2000` passes bytes through both ways unchanged. `9P2000.L.Z` isn't
//! offered yet (stage 4).
//!
//! One devmnt request can become several to the server, so each is an
//! `Op` with its own server tags and server fids, which the translator
//! allocates. An op's memory is an arena freed when it's answered.

const std = @import("std");
const wire = @import("wire.zig");
const attr = @import("attr.zig");

const p9 = wire.p9;
const l = wire.l;
const L = wire.L;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// Who the machine's user is on the wire.
    users: attr.UserMap,
    /// The largest msize offered upstream.
    msize: u32 = 1 << 20,
};

/// What `version` reads, for `#ℓ`'s status file.
pub const Dialect = enum {
    negotiating,
    @"9P2000",
    @"9P2000.L",
    failed,
};

/// Links followed in one walk before "too many symbolic links", as
/// design/0034-symlinks-in-root.md has it.
pub const max_links = 40;

const Fid = struct {
    sfid: u32,
    root: *Root,
    /// Names from the attach root, with every link resolved.
    path: std.ArrayList([]u8) = .empty,
    qid: wire.Qid,
    open: bool = false,
    rclose: bool = false,
    /// A directory read's position: the server's cookie, Dirs packed but
    /// not yet returned, and whether the server has no more.
    cookie: u64 = 0,
    dirbuf: std.ArrayList(u8) = .empty,
    eof: bool = false,
};

/// A hidden server fid at an attach's root, which outlives the fid devmnt
/// attached with, so walks can start from the root (symlinks, parents).
const Root = struct {
    sfid: u32,
    refs: u32,
};

/// Why a server reply was expected.
const Step = union(enum) {
    /// A clunk: the reply frees the server fid.
    clunked: u32,
    /// A Tflush for an op.
    flush: struct { op: *Op, oldtag: u16 },
    /// A step of a walk that follows links.
    resolve: *Resolve,
    /// A step of the op itself; what the number means is the op's own.
    main: u32,
    /// A getattr for entry i of a directory read.
    entry: u32,
};

const Pending = struct {
    op: ?*Op,
    step: Step,
};

const Kind = enum { version, attach, walk, open, create, read, readdir, write, clunk, remove, stat, wstat };

const Op = struct {
    arena: std.heap.ArenaAllocator,
    tag: u16,
    kind: Kind,
    fid: u32 = 0,
    /// Server requests out for this op.
    outstanding: u32 = 0,
    /// Flushed by devmnt: replies are ignored, and once the server has
    /// answered the flushes devmnt gets its Rflush.
    dead: bool = false,
    flush_tag: u16 = 0,
    flushes: u32 = 0,
    /// Server fids this op made that aren't a Fid's yet.
    tmp: std.ArrayList(u32) = .empty,
    /// What the op works with; which fields are used depends on `kind`.
    names: []const []const u8 = &.{},
    newfid: u32 = 0,
    mode: u8 = 0,
    perm: u32 = 0,
    name: []const u8 = "",
    offset: u64 = 0,
    count: u32 = 0,
    data: []const u8 = &.{},
    wstat: attr.Wstat = .{},
    sfid: u32 = 0,
    qid: wire.Qid = .{},
    dir: bool = false,
    resolve: ?*Resolve = null,
    entries: []Entry = &.{},
    entries_left: u32 = 0,

    fn allocator(op: *Op) Allocator {
        return op.arena.allocator();
    }
};

const Entry = struct {
    name: []const u8,
    resolve: ?*Resolve = null,
    stat: ?wire.Stat = null,
};

/// A walk that follows symbolic links inside the attach root, by
/// design/0034-symlinks-in-root.md's rule: an absolute target is relative
/// to the root, `..` stops there, and more than 40 links is an error.
///
/// It first walks all the names in one Twalk. Only when that crosses a
/// link does it go one name at a time from the start, reading each link
/// and splicing its target into the names left.
const Resolve = struct {
    op: *Op,
    /// Which of the op's walks this is (an entry index for a directory
    /// read, 0 otherwise).
    slot: u32,
    start: u32,
    root: *Root,
    names: []const []const u8,
    /// What's done: per name walked, its qid; and the path walked to.
    qids: std.ArrayList(wire.Qid) = .empty,
    path: std.ArrayList([]const u8) = .empty,
    /// The server fid at the end, once every name is walked.
    sfid: u32 = 0,
    err: ?[]const u8 = null,

    // One name at a time: the fid walked so far, and what's left to walk,
    // with a marker after each of the original names.
    cur: u32 = 0,
    cur_qid: wire.Qid = .{},
    queue: std.ArrayList(Item) = .empty,
    next: u32 = 0,
    links: u32 = 0,
    /// The name being walked, and the fid it's walked into.
    pending_name: []const u8 = "",
    tmp: u32 = 0,
    state: enum { fast, clone, step, dotdot, readlink, reroot } = .fast,

    const Item = union(enum) { name: []const u8, done: u32 };
};

pub const Client = struct {
    gpa: Allocator,
    opts: Options,
    dialect: Dialect = .negotiating,
    /// Why the connection failed.
    err: ?[]const u8 = null,
    err_buf: [128]u8 = undefined,

    /// The negotiated msize upstream, and devmnt's.
    msize: u32 = 0,
    mount_msize: u32 = 0,

    in_mount: std.ArrayList(u8) = .empty,
    in_server: std.ArrayList(u8) = .empty,
    out_mount: std.ArrayList(u8) = .empty,
    out_server: std.ArrayList(u8) = .empty,

    /// devmnt's Tversion, until the server answers ours.
    held_version: ?struct { tag: u16, msize: u32 } = null,

    fids: std.AutoHashMapUnmanaged(u32, *Fid) = .empty,
    ops: std.AutoHashMapUnmanaged(u16, *Op) = .empty,
    pending: std.AutoHashMapUnmanaged(u16, Pending) = .empty,
    next_tag: u16 = 0,
    next_sfid: u32 = 1,
    free_sfids: std.ArrayList(u32) = .empty,

    pub fn init(gpa: Allocator, opts: Options) Allocator.Error!Client {
        var c: Client = .{ .gpa = gpa, .opts = opts };
        c.msize = opts.msize;
        // Offer .L straight away; devmnt's Tversion waits for the answer.
        try c.sendServer(0, wire.common.Tversion{ .msize = opts.msize, .version = wire.version_l }, .{ .op = null, .step = .{ .main = 0 } });
        return c;
    }

    pub fn deinit(c: *Client) void {
        var it = c.ops.valueIterator();
        while (it.next()) |op| op.*.arena.deinit();
        c.ops.deinit(c.gpa);
        var fit = c.fids.valueIterator();
        while (fit.next()) |f| c.freeFid(f.*);
        c.fids.deinit(c.gpa);
        c.pending.deinit(c.gpa);
        c.free_sfids.deinit(c.gpa);
        for ([_]*std.ArrayList(u8){ &c.in_mount, &c.in_server, &c.out_mount, &c.out_server }) |b| b.deinit(c.gpa);
    }

    /// The negotiated dialect, for `status`.
    pub fn version(c: *const Client) Dialect {
        return c.dialect;
    }

    /// Bytes to send to the server; `consumedServer` drops what was sent.
    pub fn toServer(c: *const Client) []const u8 {
        return c.out_server.items;
    }

    pub fn consumedServer(c: *Client, n: usize) void {
        consume(&c.out_server, n);
    }

    /// Bytes for devmnt to read; `consumedMount` drops what it read.
    pub fn toMount(c: *const Client) []const u8 {
        return c.out_mount.items;
    }

    pub fn consumedMount(c: *Client, n: usize) void {
        consume(&c.out_mount, n);
    }

    fn consume(b: *std.ArrayList(u8), n: usize) void {
        std.mem.copyForwards(u8, b.items[0 .. b.items.len - n], b.items[n..]);
        b.items.len -= n;
    }

    /// Takes bytes devmnt wrote. A malformed frame fails the connection.
    pub fn fromMount(c: *Client, bytes: []const u8) Allocator.Error!void {
        if (c.dialect == .@"9P2000") return c.out_server.appendSlice(c.gpa, bytes);
        try c.in_mount.appendSlice(c.gpa, bytes);
        // After a failure requests are still read, to answer with the error.
        while (true) {
            const max = if (c.mount_msize != 0) c.mount_msize else c.opts.msize;
            const h = wire.header(c.in_mount.items, max) catch return c.fail("bad 9P message from the mount");
            const hd = h orelse break;
            if (c.in_mount.items.len < hd.size) break;
            const frame = try c.gpa.dupe(u8, c.in_mount.items[0..hd.size]);
            defer c.gpa.free(frame);
            consume(&c.in_mount, hd.size);
            if (c.dialect == .@"9P2000") {
                // devmnt's bytes after its Tversion pass straight through.
                try c.out_server.appendSlice(c.gpa, frame);
                try c.out_server.appendSlice(c.gpa, c.in_mount.items);
                c.in_mount.items.len = 0;
                break;
            }
            const d = wire.decode(p9.T, frame, max, false) catch return c.fail("bad 9P message from the mount");
            try c.request(d.tag, d.msg);
        }
    }

    /// Takes bytes from the server. A reply that's malformed, or for no
    /// request, fails the connection.
    pub fn fromServer(c: *Client, bytes: []const u8) Allocator.Error!void {
        if (c.dialect == .@"9P2000") return c.out_mount.appendSlice(c.gpa, bytes);
        try c.in_server.appendSlice(c.gpa, bytes);
        while (c.dialect != .failed) {
            const h = wire.header(c.in_server.items, c.msize) catch return c.fail("bad 9P message from the server");
            const hd = h orelse break;
            if (c.in_server.items.len < hd.size) break;
            const frame = try c.gpa.dupe(u8, c.in_server.items[0..hd.size]);
            defer c.gpa.free(frame);
            consume(&c.in_server, hd.size);
            const d = wire.decode(l.R, frame, c.msize, false) catch return c.fail("bad 9P message from the server");
            const p = c.pending.fetchRemove(d.tag) orelse return c.fail("9P reply for no request");
            try c.reply(p.value, d.msg);
            if (c.dialect == .@"9P2000") {
                try c.out_mount.appendSlice(c.gpa, c.in_server.items);
                c.in_server.items.len = 0;
                break;
            }
        }
    }

    /// Fails the connection: every op waiting gets the error, and so does
    /// every request after.
    fn fail(c: *Client, msg: []const u8) Allocator.Error!void {
        if (c.dialect == .failed) return;
        c.dialect = .failed;
        const n = @min(msg.len, c.err_buf.len);
        @memcpy(c.err_buf[0..n], msg[0..n]);
        c.err = c.err_buf[0..n];
        if (c.held_version) |h| {
            c.held_version = null;
            try c.rerror(h.tag, c.err.?);
        }
        var it = c.ops.valueIterator();
        while (it.next()) |op| {
            if (!op.*.dead) try c.rerror(op.*.tag, c.err.?);
            op.*.arena.deinit();
        }
        c.ops.clearRetainingCapacity();
        c.pending.clearRetainingCapacity();
    }

    // Queuing messages.

    fn sendMount(c: *Client, tag: u16, msg: anytype) Allocator.Error!void {
        const need = frameSize(msg);
        try c.out_mount.ensureUnusedCapacity(c.gpa, need);
        const f = wire.encode(c.out_mount.unusedCapacitySlice(), tag, msg, null) catch unreachable;
        c.out_mount.items.len += f.len;
    }

    fn rerror(c: *Client, tag: u16, msg: []const u8) Allocator.Error!void {
        // devmnt's ERRMAX is 128.
        try c.sendMount(tag, p9.Rerror{ .ename = msg[0..@min(msg.len, 127)] });
    }

    fn allocTag(c: *Client) u16 {
        while (true) {
            const t = c.next_tag;
            c.next_tag +%= 1;
            if (c.next_tag == wire.notag) c.next_tag = 0;
            if (t != wire.notag and !c.pending.contains(t)) return t;
        }
    }

    fn sendServer(c: *Client, tag: ?u16, msg: anytype, p: Pending) Allocator.Error!void {
        const t = tag orelse c.allocTag();
        try c.pending.put(c.gpa, t, p);
        if (p.op) |op| op.outstanding += 1;
        const need = frameSize(msg);
        try c.out_server.ensureUnusedCapacity(c.gpa, need);
        const f = wire.encode(c.out_server.unusedCapacitySlice(), t, msg, null) catch unreachable;
        c.out_server.items.len += f.len;
    }

    fn send(c: *Client, op: *Op, msg: anytype, step: Step) Allocator.Error!void {
        return c.sendServer(null, msg, .{ .op = op, .step = step });
    }

    fn allocSfid(c: *Client) u32 {
        if (c.free_sfids.pop()) |f| return f;
        defer c.next_sfid += 1;
        return c.next_sfid;
    }

    /// Clunks a server fid; it's reused once the server answers.
    fn clunk(c: *Client, sfid: u32) Allocator.Error!void {
        try c.sendServer(null, wire.common.Tclunk{ .fid = sfid }, .{ .op = null, .step = .{ .clunked = sfid } });
    }

    /// A new server fid for `op`, clunked if the op is flushed.
    fn tmpSfid(c: *Client, op: *Op) Allocator.Error!u32 {
        const f = c.allocSfid();
        try op.tmp.append(op.allocator(), f);
        return f;
    }

    /// Clunks one of `op`'s server fids.
    fn dropTmp(c: *Client, op: *Op, sfid: u32) Allocator.Error!void {
        keep(op, sfid);
        try c.clunk(sfid);
    }

    /// Marks one of `op`'s server fids as kept: the op no longer clunks it.
    fn keep(op: *Op, sfid: u32) void {
        for (op.tmp.items, 0..) |f, i| if (f == sfid) {
            _ = op.tmp.swapRemove(i);
            return;
        };
    }

    // devmnt's requests.

    fn newOp(c: *Client, tag: u16, kind: Kind) Allocator.Error!*Op {
        const op = try c.gpa.create(Op);
        op.* = .{ .arena = .init(c.gpa), .tag = tag, .kind = kind };
        try c.ops.put(c.gpa, tag, op);
        return op;
    }

    /// Answers an op and frees it.
    fn finish(c: *Client, op: *Op, msg: anytype) Allocator.Error!void {
        try c.sendMount(op.tag, msg);
        c.endOp(op);
    }

    fn finishErr(c: *Client, op: *Op, msg: []const u8) Allocator.Error!void {
        try c.rerror(op.tag, msg);
        c.endOp(op);
    }

    fn finishErrno(c: *Client, op: *Op, e: u32) Allocator.Error!void {
        var buf: [16]u8 = undefined;
        try c.finishErr(op, attr.errstr(e, &buf));
    }

    fn endOp(c: *Client, op: *Op) void {
        std.debug.assert(op.outstanding == 0);
        _ = c.ops.remove(op.tag);
        for (op.tmp.items) |f| c.clunk(f) catch {};
        op.arena.deinit();
        c.gpa.destroy(op);
    }

    fn request(c: *Client, tag: u16, msg: p9.T) Allocator.Error!void {
        if (c.dialect == .failed) return c.rerror(tag, c.err.?);
        switch (msg) {
            .Tversion => |v| {
                // The server's Rversion can come before devmnt's Tversion.
                if (c.held_version != null or c.mount_msize != 0) return c.rerror(tag, "version already negotiated");
                if (c.dialect == .@"9P2000.L") return c.answerVersion(tag, v.msize);
                c.held_version = .{ .tag = tag, .msize = v.msize };
                return;
            },
            .Tflush => |f| return c.flush(tag, f.oldtag),
            else => {},
        }
        if (c.dialect != .@"9P2000.L") return c.rerror(tag, "version not negotiated");
        if (c.ops.contains(tag)) return c.rerror(tag, "tag in use");
        switch (msg) {
            .Tversion, .Tflush => unreachable,
            .Tauth => return c.rerror(tag, "authentication not required"),
            .Tattach => |a| {
                if (c.fids.contains(a.fid)) return c.rerror(tag, "fid in use");
                const op = try c.newOp(tag, .attach);
                op.fid = a.fid;
                op.sfid = try c.tmpSfid(op);
                const uname = try op.allocator().dupe(u8, a.uname);
                try c.send(op, l.Tattach{ .fid = op.sfid, .afid = wire.nofid, .uname = uname, .aname = a.aname, .n_uname = c.opts.users.number(uname) }, .{ .main = 0 });
            },
            .Twalk => |w| {
                const f = c.fids.get(w.fid) orelse return c.rerror(tag, "unknown fid");
                if (w.newfid != w.fid and c.fids.contains(w.newfid)) return c.rerror(tag, "fid in use");
                if (f.open) return c.rerror(tag, "walk of open fid");
                const op = try c.newOp(tag, .walk);
                op.fid = w.fid;
                op.newfid = w.newfid;
                const a = op.allocator();
                const names = try a.alloc([]const u8, w.wnames.n);
                for (w.wnames.slice(), names) |s, *d| d.* = try a.dupe(u8, s);
                op.resolve = try c.startResolve(op, 0, f, names);
            },
            .Topen => |o| {
                const f = c.fids.get(o.fid) orelse return c.rerror(tag, "unknown fid");
                if (f.open) return c.rerror(tag, "fid already open");
                const op = try c.newOp(tag, .open);
                op.fid = o.fid;
                op.mode = o.mode;
                try c.send(op, l.Tgetattr{ .fid = f.sfid, .request_mask = L.GETATTR_BASIC }, .{ .main = 0 });
            },
            .Tcreate => |cr| {
                const f = c.fids.get(cr.fid) orelse return c.rerror(tag, "unknown fid");
                if (f.open) return c.rerror(tag, "fid already open");
                if (f.qid.type & wire.QTDIR == 0) return c.rerror(tag, "create in non-directory");
                if (!validName(cr.name)) return c.rerror(tag, "bad character in file name");
                const op = try c.newOp(tag, .create);
                op.fid = cr.fid;
                op.mode = cr.mode;
                op.perm = cr.perm;
                op.name = try op.allocator().dupe(u8, cr.name);
                const gid = c.opts.users.number(c.opts.users.user);
                if (cr.perm & wire.DMDIR != 0) {
                    try c.send(op, l.Tmkdir{ .dfid = f.sfid, .name = op.name, .mode = attr.createMode(cr.perm), .gid = gid }, .{ .main = 0 });
                } else {
                    try c.send(op, l.Tlcreate{ .fid = f.sfid, .name = op.name, .flags = attr.openFlags(cr.mode) | L.CREATE | L.EXCL, .mode = attr.createMode(cr.perm), .gid = gid }, .{ .main = 10 });
                }
            },
            .Tread => |r| {
                const f = c.fids.get(r.fid) orelse return c.rerror(tag, "unknown fid");
                if (!f.open) return c.rerror(tag, "fid not open");
                if (f.qid.type & wire.QTDIR != 0) return c.readDir(tag, r.fid, f, r.offset, r.count);
                const op = try c.newOp(tag, .read);
                try c.send(op, wire.common.Tread{ .fid = f.sfid, .offset = r.offset, .count = @min(r.count, c.msize - wire.io_header) }, .{ .main = 0 });
            },
            .Twrite => |w| {
                const f = c.fids.get(w.fid) orelse return c.rerror(tag, "unknown fid");
                if (!f.open) return c.rerror(tag, "fid not open");
                const op = try c.newOp(tag, .write);
                const n = @min(w.data.bytes.len, c.msize - wire.io_header);
                try c.send(op, wire.common.Twrite{ .fid = f.sfid, .offset = w.offset, .data = .{ .bytes = w.data.bytes[0..n] } }, .{ .main = 0 });
            },
            .Tclunk => |cl| {
                const f = c.fids.get(cl.fid) orelse return c.rerror(tag, "unknown fid");
                if (f.rclose) {
                    const op = try c.newOp(tag, .clunk);
                    op.fid = cl.fid;
                    return c.removeStart(op, f);
                }
                try c.dropFid(cl.fid);
                try c.sendMount(tag, p9.Rclunk{});
            },
            .Tremove => |rm| {
                const f = c.fids.get(rm.fid) orelse return c.rerror(tag, "unknown fid");
                const op = try c.newOp(tag, .remove);
                op.fid = rm.fid;
                try c.removeStart(op, f);
            },
            .Tstat => |s| {
                const f = c.fids.get(s.fid) orelse return c.rerror(tag, "unknown fid");
                const op = try c.newOp(tag, .stat);
                op.fid = s.fid;
                try c.send(op, l.Tgetattr{ .fid = f.sfid, .request_mask = L.GETATTR_BASIC }, .{ .main = 0 });
            },
            .Twstat => |ws| {
                const f = c.fids.get(ws.fid) orelse return c.rerror(tag, "unknown fid");
                const d, _ = attr.Dir.parse(ws.stat.bytes) orelse return c.rerror(tag, "bad stat");
                const op = try c.newOp(tag, .wstat);
                op.fid = ws.fid;
                op.wstat = attr.wstat(&d);
                if (op.wstat.rename) |n| {
                    if (!validName(n)) return c.finishErr(op, "bad character in file name");
                    op.wstat.rename = try op.allocator().dupe(u8, n);
                    if (f.path.items.len == 0) return c.finishErr(op, "can't rename the root");
                    if (std.mem.eql(u8, n, f.path.items[f.path.items.len - 1])) op.wstat.rename = null;
                }
                try c.wstatNext(op, f);
            },
        }
    }

    fn validName(n: []const u8) bool {
        return n.len > 0 and !std.mem.eql(u8, n, ".") and !std.mem.eql(u8, n, "..") and
            std.mem.indexOfScalar(u8, n, '/') == null and std.mem.indexOfScalar(u8, n, 0) == null;
    }

    fn flush(c: *Client, tag: u16, oldtag: u16) Allocator.Error!void {
        const op = c.ops.get(oldtag) orelse return c.sendMount(tag, p9.Rflush{});
        if (op.dead) return c.sendMount(tag, p9.Rflush{});
        if (op.kind == .version) return c.sendMount(tag, p9.Rflush{});
        op.dead = true;
        op.flush_tag = tag;
        // The op's tag is devmnt's to reuse once it has the Rflush, so the
        // op is filed under no tag until then.
        _ = c.ops.remove(oldtag);
        var stags: std.ArrayList(u16) = .empty;
        defer stags.deinit(c.gpa);
        var it = c.pending.iterator();
        while (it.next()) |e| if (e.value_ptr.op == op) try stags.append(c.gpa, e.key_ptr.*);
        for (stags.items) |st| {
            op.flushes += 1;
            try c.sendServer(null, wire.common.Tflush{ .oldtag = st }, .{ .op = null, .step = .{ .flush = .{ .op = op, .oldtag = st } } });
        }
        try c.maybeFlushed(op);
    }

    /// Once a flushed op has nothing out, devmnt gets its Rflush.
    fn maybeFlushed(c: *Client, op: *Op) Allocator.Error!void {
        if (op.outstanding != 0 or op.flushes != 0) return;
        try c.sendMount(op.flush_tag, p9.Rflush{});
        for (op.tmp.items) |f| try c.clunk(f);
        op.arena.deinit();
        c.gpa.destroy(op);
    }

    // Server replies.

    fn reply(c: *Client, p: Pending, msg: l.R) Allocator.Error!void {
        switch (p.step) {
            .clunked => |sfid| {
                try c.free_sfids.append(c.gpa, sfid);
                return;
            },
            .flush => |f| {
                // The flushed request won't be answered now, if it hasn't been.
                if (c.pending.fetchRemove(f.oldtag)) |old| {
                    if (old.value.op) |o| o.outstanding -= 1;
                }
                f.op.flushes -= 1;
                return c.maybeFlushed(f.op);
            },
            else => {},
        }
        const op = p.op orelse {
            // Our own Tversion.
            return c.versioned(msg);
        };
        op.outstanding -= 1;
        if (op.dead) return c.maybeFlushed(op);
        switch (p.step) {
            .resolve => |r| return c.stepResolve(r, msg),
            .main => |n| return c.stepOp(op, n, msg),
            .entry => |i| return c.stepEntry(op, i, msg),
            .clunked, .flush => unreachable,
        }
    }

    fn versioned(c: *Client, msg: l.R) Allocator.Error!void {
        const v = switch (msg) {
            .Rversion => |v| v,
            .Rlerror => |e| {
                var buf: [16]u8 = undefined;
                return c.fail(attr.errstr(e.ecode, &buf));
            },
            else => return c.fail("bad reply to Tversion"),
        };
        if (std.mem.eql(u8, v.version, wire.version_l)) {
            c.dialect = .@"9P2000.L";
        } else if (std.mem.eql(u8, v.version, wire.version_9p)) {
            c.dialect = .@"9P2000";
        } else {
            var buf: [128]u8 = undefined;
            return c.fail(std.fmt.bufPrint(&buf, "server speaks unknown 9P version {s}", .{v.version[0..@min(v.version.len, 64)]}) catch unreachable);
        }
        if (v.msize < 256 or v.msize > c.opts.msize) return c.fail("bad msize from the server");
        c.msize = v.msize;
        if (c.held_version) |h| try c.answerVersion(h.tag, h.msize);
    }

    fn answerVersion(c: *Client, tag: u16, msize: u32) Allocator.Error!void {
        c.held_version = null;
        c.mount_msize = @min(msize, c.msize);
        try c.sendMount(tag, wire.common.Rversion{ .msize = c.mount_msize, .version = wire.version_9p });
    }

    /// The reply's errno if it's an Rlerror, or null.
    fn lerror(msg: l.R) ?u32 {
        return switch (msg) {
            .Rlerror => |e| e.ecode,
            else => null,
        };
    }

    fn unexpected(c: *Client) Allocator.Error!void {
        return c.fail("unexpected 9P reply from the server");
    }

    fn stepOp(c: *Client, op: *Op, n: u32, msg: l.R) Allocator.Error!void {
        switch (op.kind) {
            .attach => return c.stepAttach(op, n, msg),
            .open => return c.stepOpen(op, n, msg),
            .create => return c.stepCreate(op, n, msg),
            .read => {
                if (lerror(msg)) |e| return c.finishErrno(op, e);
                if (msg != .Rread) return c.unexpected();
                return c.finish(op, wire.common.Rread{ .data = msg.Rread.data });
            },
            .readdir => return c.stepReaddir(op, msg),
            .write => {
                if (lerror(msg)) |e| return c.finishErrno(op, e);
                if (msg != .Rwrite) return c.unexpected();
                return c.finish(op, wire.common.Rwrite{ .count = msg.Rwrite.count });
            },
            .clunk, .remove => return c.stepRemove(op, n, msg),
            .stat => {
                if (lerror(msg)) |e| return c.finishErrno(op, e);
                if (msg != .Rgetattr) return c.unexpected();
                const f = c.fids.get(op.fid) orelse return c.finishErr(op, "unknown fid");
                const name = if (f.path.items.len == 0) "/" else f.path.items[f.path.items.len - 1];
                return c.finishStat(op, &msg.Rgetattr.stat, name);
            },
            .wstat => return c.stepWstat(op, n, msg),
            .version, .walk => return c.unexpected(),
        }
    }

    fn finishStat(c: *Client, op: *Op, st: *const wire.Stat, name: []const u8) Allocator.Error!void {
        var ub: [10]u8 = undefined;
        var gb: [10]u8 = undefined;
        const d = attr.dirFromStat(st, name, c.opts.users.name(st.uid, &ub), c.opts.users.name(st.gid, &gb));
        var buf: [512]u8 = undefined;
        const b = d.pack(&buf) catch return c.finishErr(op, "name too long");
        return c.finish(op, p9.Rstat{ .stat = .{ .bytes = b } });
    }

    fn stepAttach(c: *Client, op: *Op, n: u32, msg: l.R) Allocator.Error!void {
        if (lerror(msg)) |e| return c.finishErrno(op, e);
        switch (n) {
            0 => {
                if (msg != .Rattach) return c.unexpected();
                // The hidden root fid is op.sfid; devmnt's fid is a clone.
                op.qid = msg.Rattach.qid;
                const sfid = try c.tmpSfid(op);
                op.newfid = sfid;
                try c.send(op, wire.common.Twalk{ .fid = op.sfid, .newfid = sfid, .wnames = .{} }, .{ .main = 1 });
            },
            1 => {
                if (msg != .Rwalk) return c.unexpected();
                keep(op, op.sfid);
                keep(op, op.newfid);
                const root = try c.gpa.create(Root);
                root.* = .{ .sfid = op.sfid, .refs = 0 };
                try c.addFid(op.fid, op.newfid, root, &.{}, op.qid);
                return c.finish(op, p9.Rattach{ .qid = pq(op.qid) });
            },
            else => unreachable,
        }
    }

    fn addFid(c: *Client, fid: u32, sfid: u32, root: *Root, path: []const []const u8, qid: wire.Qid) Allocator.Error!void {
        const f = try c.gpa.create(Fid);
        f.* = .{ .sfid = sfid, .root = root, .qid = qid };
        root.refs += 1;
        for (path) |p| try f.path.append(c.gpa, try c.gpa.dupe(u8, p));
        if (c.fids.fetchRemove(fid)) |old| {
            try c.clunk(old.value.sfid);
            c.freeFid(old.value);
        }
        try c.fids.put(c.gpa, fid, f);
    }

    fn freeFid(c: *Client, f: *Fid) void {
        for (f.path.items) |p| c.gpa.free(p);
        f.path.deinit(c.gpa);
        f.dirbuf.deinit(c.gpa);
        f.root.refs -= 1;
        if (f.root.refs == 0) {
            c.clunk(f.root.sfid) catch {};
            c.gpa.destroy(f.root);
        }
        c.gpa.destroy(f);
    }

    fn dropFid(c: *Client, fid: u32) Allocator.Error!void {
        const kv = c.fids.fetchRemove(fid) orelse return;
        try c.clunk(kv.value.sfid);
        c.freeFid(kv.value);
    }

    fn stepOpen(c: *Client, op: *Op, n: u32, msg: l.R) Allocator.Error!void {
        if (lerror(msg)) |e| return c.finishErrno(op, e);
        const f = c.fids.get(op.fid) orelse return c.finishErr(op, "unknown fid");
        switch (n) {
            0 => {
                if (msg != .Rgetattr) return c.unexpected();
                const mode = msg.Rgetattr.stat.mode;
                if (!attr.openable(mode)) return c.finishErr(op, "not a regular file");
                op.dir = mode & attr.S_IFMT == attr.S_IFDIR;
                if (op.dir and op.mode & 3 != wire.OREAD) return c.finishErrno(op, attr.E.ISDIR);
                var flags = attr.openFlags(op.mode);
                if (op.dir) flags = L.RDONLY | L.DIRECTORY;
                try c.send(op, l.Tlopen{ .fid = f.sfid, .flags = flags }, .{ .main = 1 });
            },
            1 => {
                if (msg != .Rlopen) return c.unexpected();
                f.open = true;
                f.rclose = op.mode & wire.ORCLOSE != 0;
                f.qid = msg.Rlopen.qid;
                if (op.dir) f.qid.type |= wire.QTDIR;
                return c.finish(op, p9.Ropen{ .qid = pq(f.qid), .iounit = 0 });
            },
            else => unreachable,
        }
    }

    fn stepCreate(c: *Client, op: *Op, n: u32, msg: l.R) Allocator.Error!void {
        if (lerror(msg)) |e| return c.finishErrno(op, e);
        const f = c.fids.get(op.fid) orelse return c.finishErr(op, "unknown fid");
        switch (n) {
            // A directory: Tmkdir, then walk to it and open it.
            0 => {
                if (msg != .Rmkdir) return c.unexpected();
                op.sfid = try c.tmpSfid(op);
                try c.send(op, wire.common.Twalk{ .fid = f.sfid, .newfid = op.sfid, .wnames = .init(&.{op.name}) }, .{ .main = 1 });
            },
            1 => {
                if (msg != .Rwalk) return c.unexpected();
                if (msg.Rwalk.wqids.n != 1) return c.finishErrno(op, attr.E.NOENT);
                try c.send(op, l.Tlopen{ .fid = op.sfid, .flags = L.RDONLY | L.DIRECTORY }, .{ .main = 2 });
            },
            2 => {
                if (msg != .Rlopen) return c.unexpected();
                keep(op, op.sfid);
                try c.clunk(f.sfid);
                f.sfid = op.sfid;
                var q = msg.Rlopen.qid;
                q.type |= wire.QTDIR;
                return c.created(op, f, q);
            },
            // A file: Tlcreate opened the directory's fid as the new file.
            10 => {
                if (msg != .Rlcreate) return c.unexpected();
                return c.created(op, f, msg.Rlcreate.qid);
            },
            else => unreachable,
        }
    }

    fn created(c: *Client, op: *Op, f: *Fid, qid: wire.Qid) Allocator.Error!void {
        try f.path.append(c.gpa, try c.gpa.dupe(u8, op.name));
        f.qid = qid;
        f.open = true;
        f.rclose = op.mode & wire.ORCLOSE != 0;
        return c.finish(op, p9.Rcreate{ .qid = pq(qid), .iounit = 0 });
    }

    // Removing: walk a fid to the parent from the root, then Tunlinkat.
    // A clunk of an ORCLOSE fid does the same and always succeeds.

    fn removeStart(c: *Client, op: *Op, f: *Fid) Allocator.Error!void {
        if (f.path.items.len == 0) {
            try c.dropFid(op.fid);
            if (op.kind == .clunk) return c.finish(op, p9.Rclunk{});
            return c.finishErr(op, "can't remove the root");
        }
        op.dir = f.qid.type & wire.QTDIR != 0;
        op.name = try op.allocator().dupe(u8, f.path.items[f.path.items.len - 1]);
        try c.walkParent(op, f, 0);
    }

    /// Walks a new server fid (`op.sfid`) from `f`'s root to its parent,
    /// sixteen names at a time; each reply comes back as step `base` + 1.
    fn walkParent(c: *Client, op: *Op, f: *Fid, base: u32) Allocator.Error!void {
        const a = op.allocator();
        const dirs = f.path.items[0 .. f.path.items.len - 1];
        const copy = try a.alloc([]const u8, dirs.len);
        for (dirs, copy) |s, *d| d.* = try a.dupe(u8, s);
        op.names = copy;
        op.sfid = try c.tmpSfid(op);
        op.count = 0;
        try c.walkMore(op, f.root.sfid, base);
    }

    fn walkMore(c: *Client, op: *Op, from: u32, base: u32) Allocator.Error!void {
        const at: usize = op.count;
        const n = @min(op.names.len - at, wire.max_welem);
        op.count += @intCast(n);
        try c.send(op, wire.common.Twalk{ .fid = from, .newfid = op.sfid, .wnames = .init(op.names[at..][0..n]) }, .{ .main = base + 1 });
    }

    /// The next step of a parent walk; true once the fid is there.
    fn parentWalked(c: *Client, op: *Op, base: u32, msg: l.R) Allocator.Error!bool {
        if (msg != .Rwalk) {
            try c.unexpected();
            return false;
        }
        if (op.count < op.names.len) {
            try c.walkMore(op, op.sfid, base);
            return false;
        }
        return true;
    }

    fn stepRemove(c: *Client, op: *Op, n: u32, msg: l.R) Allocator.Error!void {
        if (lerror(msg)) |e| {
            try c.dropFid(op.fid);
            if (op.kind == .clunk) return c.finish(op, p9.Rclunk{});
            return c.finishErrno(op, e);
        }
        switch (n) {
            1 => {
                if (!try c.parentWalked(op, 0, msg)) return;
                try c.send(op, l.Tunlinkat{ .dirfid = op.sfid, .name = op.name, .flags = if (op.dir) L.AT_REMOVEDIR else 0 }, .{ .main = 2 });
            },
            2 => {
                if (msg != .Runlinkat) return c.unexpected();
                try c.dropTmp(op, op.sfid);
                try c.dropFid(op.fid);
                if (op.kind == .clunk) return c.finish(op, p9.Rclunk{});
                return c.finish(op, p9.Rremove{});
            },
            else => unreachable,
        }
    }

    // Wstat: a rename (walk to the parent, Trenameat), then a Tsetattr,
    // or a Tfsync for the null wstat.

    fn wstatNext(c: *Client, op: *Op, f: *Fid) Allocator.Error!void {
        if (op.wstat.sync) {
            op.wstat.sync = false;
            return c.send(op, l.Tfsync{ .fid = f.sfid, .datasync = 0 }, .{ .main = 20 });
        }
        if (op.wstat.rename != null) {
            op.name = try op.allocator().dupe(u8, f.path.items[f.path.items.len - 1]);
            return c.walkParent(op, f, 0);
        }
        if (op.wstat.setattr.valid != 0) {
            const s = op.wstat.setattr;
            op.wstat.setattr.valid = 0;
            return c.send(op, l.Tsetattr{ .fid = f.sfid, .valid = s.valid, .mode = s.mode, .uid = 0, .gid = 0, .size = s.size, .atime_sec = 0, .atime_nsec = 0, .mtime_sec = s.mtime_sec, .mtime_nsec = 0 }, .{ .main = 30 });
        }
        return c.finish(op, p9.Rwstat{});
    }

    fn stepWstat(c: *Client, op: *Op, n: u32, msg: l.R) Allocator.Error!void {
        if (lerror(msg)) |e| return c.finishErrno(op, e);
        const f = c.fids.get(op.fid) orelse return c.finishErr(op, "unknown fid");
        switch (n) {
            1 => {
                if (!try c.parentWalked(op, 0, msg)) return;
                try c.send(op, l.Trenameat{ .olddirfid = op.sfid, .oldname = op.name, .newdirfid = op.sfid, .newname = op.wstat.rename.? }, .{ .main = 2 });
            },
            2 => {
                if (msg != .Rrenameat) return c.unexpected();
                try c.dropTmp(op, op.sfid);
                try c.renamed(f, op.wstat.rename.?);
                op.wstat.rename = null;
                return c.wstatNext(op, f);
            },
            20 => {
                if (msg != .Rfsync) return c.unexpected();
                return c.wstatNext(op, f);
            },
            30 => {
                if (msg != .Rsetattr) return c.unexpected();
                return c.wstatNext(op, f);
            },
            else => unreachable,
        }
    }

    /// After a rename, every fid at or under the old path is at the new.
    fn renamed(c: *Client, f: *Fid, new: []const u8) Allocator.Error!void {
        const old = f.path.items;
        const depth = old.len;
        const old_name = try c.gpa.dupe(u8, old[depth - 1]);
        defer c.gpa.free(old_name);
        const prefix = try c.gpa.dupe([]u8, old[0 .. depth - 1]);
        defer c.gpa.free(prefix);
        var it = c.fids.valueIterator();
        while (it.next()) |g| {
            const p = g.*.path.items;
            if (g.*.root != f.root or p.len < depth) continue;
            if (!std.mem.eql(u8, p[depth - 1], old_name)) continue;
            var same = true;
            for (prefix, p[0 .. depth - 1]) |a, b| {
                if (!std.mem.eql(u8, a, b)) {
                    same = false;
                    break;
                }
            }
            if (!same) continue;
            c.gpa.free(p[depth - 1]);
            p[depth - 1] = try c.gpa.dupe(u8, new);
        }
    }

    // Directory reads: Treaddir, then a walk (following links) and a
    // Tgetattr for each entry, packed into Dirs.

    fn readDir(c: *Client, tag: u16, fid: u32, f: *Fid, offset: u64, count: u32) Allocator.Error!void {
        if (offset == 0) {
            f.cookie = 0;
            f.dirbuf.items.len = 0;
            f.eof = false;
        }
        if (f.dirbuf.items.len != 0 or f.eof) return c.deliverDir(tag, f, count);
        const op = try c.newOp(tag, .readdir);
        op.fid = fid;
        op.count = count;
        try c.send(op, l.Treaddir{ .fid = f.sfid, .offset = f.cookie, .count = c.msize - 11 }, .{ .main = 0 });
    }

    /// Returns whole Dirs from the fid's buffer, as many as fit.
    fn deliverDir(c: *Client, tag: u16, f: *Fid, count: u32) Allocator.Error!void {
        const b = f.dirbuf.items;
        var n: usize = 0;
        while (n + 2 <= b.len) {
            const size = @as(usize, std.mem.readInt(u16, b[n..][0..2], .little)) + 2;
            if (n + size > count) break;
            n += size;
        }
        if (n == 0 and b.len != 0) return c.rerror(tag, "directory read too small");
        try c.sendMount(tag, wire.common.Rread{ .data = .{ .bytes = b[0..n] } });
        consume(&f.dirbuf, n);
    }

    fn stepReaddir(c: *Client, op: *Op, msg: l.R) Allocator.Error!void {
        if (lerror(msg)) |e| return c.finishErrno(op, e);
        if (msg != .Rreaddir) return c.unexpected();
        const f = c.fids.get(op.fid) orelse return c.finishErr(op, "unknown fid");
        const a = op.allocator();
        var list: std.ArrayList(Entry) = .empty;
        var it = wire.DirEntries.init(msg.Rreaddir.data.bytes, false);
        var last: ?u64 = null;
        while (it.next() catch return c.fail("bad directory entries from the server")) |e| {
            last = e.offset;
            if (std.mem.eql(u8, e.name, ".") or std.mem.eql(u8, e.name, "..")) continue;
            if (!validName(e.name)) continue;
            try list.append(a, .{ .name = try a.dupe(u8, e.name) });
        }
        if (last) |o| f.cookie = o else f.eof = true;
        if (list.items.len == 0) {
            if (f.eof) return c.endWith(op, f);
            // Only . and ..: read on.
            return c.send(op, l.Treaddir{ .fid = f.sfid, .offset = f.cookie, .count = c.msize - 11 }, .{ .main = 0 });
        }
        op.entries = list.items;
        op.entries_left = @intCast(list.items.len);
        for (op.entries, 0..) |*e, i| {
            const names = try a.alloc([]const u8, 1);
            names[0] = e.name;
            e.resolve = try c.startResolve(op, @intCast(i), f, names);
        }
    }

    fn endWith(c: *Client, op: *Op, f: *Fid) Allocator.Error!void {
        const tag = op.tag;
        const count = op.count;
        c.endOp(op);
        return c.deliverDir(tag, f, count);
    }

    fn entryResolved(c: *Client, op: *Op, r: *Resolve) Allocator.Error!void {
        if (r.err != null or r.qids.items.len != 1) {
            // A dangling link, or an entry gone since: left out.
            return c.entryDone(op);
        }
        keep(op, r.sfid);
        try op.tmp.append(op.allocator(), r.sfid);
        try c.send(op, l.Tgetattr{ .fid = r.sfid, .request_mask = L.GETATTR_BASIC }, .{ .entry = r.slot });
    }

    fn stepEntry(c: *Client, op: *Op, i: u32, msg: l.R) Allocator.Error!void {
        const e = &op.entries[i];
        try c.dropTmp(op, e.resolve.?.sfid);
        switch (msg) {
            .Rgetattr => |g| e.stat = g.stat,
            .Rlerror => {},
            else => return c.unexpected(),
        }
        return c.entryDone(op);
    }

    fn entryDone(c: *Client, op: *Op) Allocator.Error!void {
        op.entries_left -= 1;
        if (op.entries_left != 0) return;
        const f = c.fids.get(op.fid) orelse return c.finishErr(op, "unknown fid");
        for (op.entries) |e| {
            const st = e.stat orelse continue;
            var ub: [10]u8 = undefined;
            var gb: [10]u8 = undefined;
            const d = attr.dirFromStat(&st, e.name, c.opts.users.name(st.uid, &ub), c.opts.users.name(st.gid, &gb));
            var buf: [512]u8 = undefined;
            const b = d.pack(&buf) catch continue;
            try f.dirbuf.appendSlice(c.gpa, b);
        }
        if (f.dirbuf.items.len == 0 and !f.eof) {
            // Every entry was left out: read on.
            op.entries = &.{};
            return c.send(op, l.Treaddir{ .fid = f.sfid, .offset = f.cookie, .count = c.msize - 11 }, .{ .main = 0 });
        }
        return c.endWith(op, f);
    }

    // Walks.

    fn startResolve(c: *Client, op: *Op, slot: u32, f: *Fid, names: []const []const u8) Allocator.Error!*Resolve {
        const a = op.allocator();
        const r = try a.create(Resolve);
        r.* = .{ .op = op, .slot = slot, .start = f.sfid, .root = f.root, .names = names };
        for (f.path.items) |p| try r.path.append(a, p);
        r.sfid = try c.tmpSfid(op);
        r.state = .fast;
        try c.send(op, wire.common.Twalk{ .fid = f.sfid, .newfid = r.sfid, .wnames = .init(names) }, .{ .resolve = r });
        return r;
    }

    fn resolveDone(c: *Client, r: *Resolve) Allocator.Error!void {
        const op = r.op;
        switch (op.kind) {
            .walk => return c.walked(op, r),
            .readdir => return c.entryResolved(op, r),
            else => unreachable,
        }
    }

    fn resolveFail(c: *Client, r: *Resolve, e: u32) Allocator.Error!void {
        var buf: [16]u8 = undefined;
        r.err = try r.op.allocator().dupe(u8, attr.errstr(e, &buf));
        return c.resolveDone(r);
    }

    /// Applies a name to a canonical path: `..` goes up, but not past the
    /// root.
    fn pathStep(a: Allocator, path: *std.ArrayList([]const u8), name: []const u8) Allocator.Error!void {
        if (std.mem.eql(u8, name, "..")) {
            _ = path.pop();
        } else if (!std.mem.eql(u8, name, ".")) {
            try path.append(a, name);
        }
    }

    fn stepResolve(c: *Client, r: *Resolve, msg: l.R) Allocator.Error!void {
        const op = r.op;
        const a = op.allocator();
        switch (r.state) {
            .fast => {
                if (lerror(msg)) |e| {
                    // The first name failed (devmnt's walks never fail
                    // later than that with an error).
                    keep(op, r.sfid);
                    c.free_sfids.append(c.gpa, r.sfid) catch {};
                    return c.resolveFail(r, e);
                }
                if (msg != .Rwalk) return c.unexpected();
                const qids = msg.Rwalk.wqids.slice();
                if (qids.len > r.names.len) return c.fail("bad walk reply from the server");
                const link = for (qids, 0..) |q, i| {
                    if (q.type & wire.QTSYMLINK != 0) break i;
                } else null;
                if (link == null) {
                    for (qids, r.names[0..qids.len]) |q, n| {
                        try r.qids.append(a, q);
                        try pathStep(a, &r.path, n);
                    }
                    if (qids.len < r.names.len) {
                        // A partial walk makes no fid.
                        keep(op, r.sfid);
                        c.free_sfids.append(c.gpa, r.sfid) catch {};
                        if (qids.len == 0) return c.resolveFail(r, attr.E.NOENT);
                    }
                    return c.resolveDone(r);
                }
                // A link: start again one name at a time.
                if (qids.len == r.names.len) try c.dropTmp(op, r.sfid) else {
                    keep(op, r.sfid);
                    c.free_sfids.append(c.gpa, r.sfid) catch {};
                }
                r.path.items.len = 0;
                for (c.fids.get(op.fid).?.path.items) |p| try r.path.append(a, p);
                for (r.names, 0..) |n, i| {
                    try r.queue.append(a, .{ .name = n });
                    try r.queue.append(a, .{ .done = @intCast(i) });
                }
                r.cur = try c.tmpSfid(op);
                r.state = .clone;
                return c.send(op, wire.common.Twalk{ .fid = r.start, .newfid = r.cur, .wnames = .{} }, .{ .resolve = r });
            },
            .clone, .reroot => {
                if (lerror(msg)) |e| return c.resolveStop(r, e);
                if (msg != .Rwalk) return c.unexpected();
                if (r.state == .reroot) r.cur_qid = .{ .type = wire.QTDIR };
                return c.resolveNext(r);
            },
            .step, .dotdot => {
                if (lerror(msg)) |e| {
                    keep(op, r.tmp);
                    c.free_sfids.append(c.gpa, r.tmp) catch {};
                    return c.resolveStop(r, e);
                }
                if (msg != .Rwalk) return c.unexpected();
                if (msg.Rwalk.wqids.n != 1) {
                    keep(op, r.tmp);
                    c.free_sfids.append(c.gpa, r.tmp) catch {};
                    return c.resolveStop(r, attr.E.NOENT);
                }
                const q = msg.Rwalk.wqids.qids[0];
                if (r.state == .step and q.type & wire.QTSYMLINK != 0) {
                    r.links += 1;
                    if (r.links > max_links) {
                        try c.dropTmp(op, r.tmp);
                        return c.resolveStop(r, attr.E.LOOP);
                    }
                    r.state = .readlink;
                    return c.send(op, l.Treadlink{ .fid = r.tmp }, .{ .resolve = r });
                }
                try c.dropTmp(op, r.cur);
                r.cur = r.tmp;
                r.cur_qid = q;
                if (r.state == .dotdot) _ = r.path.pop() else try r.path.append(a, r.pending_name);
                return c.resolveNext(r);
            },
            .readlink => {
                try c.dropTmp(op, r.tmp);
                if (lerror(msg)) |e| return c.resolveStop(r, e);
                if (msg != .Rreadlink) return c.unexpected();
                const target = try a.dupe(u8, msg.Rreadlink.target);
                if (target.len == 0) return c.resolveStop(r, attr.E.NOENT);
                // The target's names go before what's left.
                var parts: std.ArrayList(Resolve.Item) = .empty;
                var it = std.mem.tokenizeScalar(u8, target, '/');
                while (it.next()) |p| try parts.append(a, .{ .name = p });
                try r.queue.insertSlice(a, r.next, parts.items);
                if (target[0] == '/') {
                    try c.dropTmp(op, r.cur);
                    r.cur = try c.tmpSfid(op);
                    r.path.items.len = 0;
                    r.state = .reroot;
                    return c.send(op, wire.common.Twalk{ .fid = r.root.sfid, .newfid = r.cur, .wnames = .{} }, .{ .resolve = r });
                }
                return c.resolveNext(r);
            },
        }
    }

    /// Walks the next name in the queue, or finishes.
    fn resolveNext(c: *Client, r: *Resolve) Allocator.Error!void {
        const op = r.op;
        while (r.next < r.queue.items.len) {
            const item = r.queue.items[r.next];
            r.next += 1;
            switch (item) {
                .done => |i| {
                    std.debug.assert(i == r.qids.items.len);
                    try r.qids.append(op.allocator(), r.cur_qid);
                },
                .name => |n| {
                    if (std.mem.eql(u8, n, ".")) continue;
                    if (std.mem.eql(u8, n, "..")) {
                        // `..` stops at the attach root.
                        if (r.path.items.len == 0) continue;
                        r.tmp = try c.tmpSfid(op);
                        r.state = .dotdot;
                        return c.send(op, wire.common.Twalk{ .fid = r.cur, .newfid = r.tmp, .wnames = .init(&.{".."}) }, .{ .resolve = r });
                    }
                    r.pending_name = n;
                    r.tmp = try c.tmpSfid(op);
                    r.state = .step;
                    return c.send(op, wire.common.Twalk{ .fid = r.cur, .newfid = r.tmp, .wnames = .init(&.{n}) }, .{ .resolve = r });
                },
            }
        }
        r.sfid = r.cur;
        return c.resolveDone(r);
    }

    /// A name failed: the walk ends with what it has, or with the error
    /// if that's nothing.
    fn resolveStop(c: *Client, r: *Resolve, e: u32) Allocator.Error!void {
        try c.dropTmp(r.op, r.cur);
        if (r.qids.items.len == 0) return c.resolveFail(r, e);
        return c.resolveDone(r);
    }

    fn walked(c: *Client, op: *Op, r: *Resolve) Allocator.Error!void {
        if (r.err) |e| return c.finishErr(op, e);
        const qids = r.qids.items;
        var out: [wire.max_welem]wire.Qid = undefined;
        for (qids, out[0..qids.len]) |q, *o| o.* = pq(q);
        if (qids.len == r.names.len) {
            keep(op, r.sfid);
            const f = c.fids.get(op.fid) orelse return c.finishErr(op, "unknown fid");
            const root = f.root;
            const qid = if (qids.len == 0) f.qid else qids[qids.len - 1];
            try c.addFid(op.newfid, r.sfid, root, r.path.items, pq(qid));
        }
        return c.finish(op, wire.common.Rwalk{ .wqids = .init(out[0..qids.len]) });
    }
};

/// A .L qid as devmnt sees it: QTDIR or a plain file.
fn pq(q: wire.Qid) wire.Qid {
    return .{ .type = q.type & wire.QTDIR, .vers = q.vers, .path = q.path };
}

fn frameSize(msg: anytype) usize {
    // The size of what wire.encode writes: the header and each field.
    var n: usize = wire.header_size;
    const T = @TypeOf(msg);
    inline for (@typeInfo(T).@"struct".fields) |f| {
        const v = @field(msg, f.name);
        n += switch (f.type) {
            u8, u16, u32, u64 => @sizeOf(f.type),
            wire.Str => 2 + v.len,
            wire.Qid => wire.Qid.wire_size,
            wire.Stat => wire.Stat.wire_size,
            wire.Data => 4 + v.bytes.len,
            wire.DirBytes => 2 + v.bytes.len,
            wire.Names => blk: {
                var s: usize = 2;
                for (v.slice()) |x| s += 2 + x.len;
                break :blk s;
            },
            wire.Qids => 2 + v.n * wire.Qid.wire_size,
            else => @compileError("no size for " ++ @typeName(f.type)),
        };
    }
    return n;
}

const testing = std.testing;
const TestServer = @import("testserver.zig").Server;

/// devmnt and a server in memory, with the translator between.
const Harness = struct {
    c: Client,
    s: *TestServer,
    next_tag: u16 = 1,
    replies: std.ArrayList(u8) = .empty,
    last: []u8 = &.{},

    fn init(version: []const u8) !Harness {
        const s = try TestServer.init(testing.allocator);
        s.version = version;
        return .{ .c = try .init(testing.allocator, .{ .users = .{ .user = "glenda", .uid = 1000 }, .msize = 1 << 16 }), .s = s };
    }

    fn deinit(h: *Harness) void {
        h.c.deinit();
        h.s.deinit();
        h.replies.deinit(testing.allocator);
        testing.allocator.free(h.last);
    }

    /// Moves bytes both ways until neither side has any.
    fn pump(h: *Harness) !void {
        while (true) {
            var moved = false;
            if (h.c.toServer().len != 0) {
                const b = try testing.allocator.dupe(u8, h.c.toServer());
                defer testing.allocator.free(b);
                h.c.consumedServer(b.len);
                try h.s.feed(b);
                moved = true;
            }
            if (h.s.out.items.len != 0) {
                const b = try h.s.out.toOwnedSlice(h.s.gpa);
                defer h.s.gpa.free(b);
                try h.c.fromServer(b);
                moved = true;
            }
            if (!moved) break;
        }
        try h.replies.appendSlice(testing.allocator, h.c.toMount());
        h.c.consumedMount(h.c.toMount().len);
    }

    fn send(h: *Harness, msg: anytype) !u16 {
        const tag = h.next_tag;
        h.next_tag += 1;
        var buf: [9000]u8 = undefined;
        try h.c.fromMount(try wire.encode(&buf, tag, msg, null));
        try h.pump();
        return tag;
    }

    /// The next reply devmnt would read, or null.
    fn next(h: *Harness) !?wire.Frame(p9.R) {
        const hd = (try wire.header(h.replies.items, 1 << 20)) orelse return null;
        testing.allocator.free(h.last);
        h.last = try testing.allocator.dupe(u8, h.replies.items[0..hd.size]);
        Client.consume(&h.replies, hd.size);
        return try wire.decode(p9.R, h.last, 1 << 20, false);
    }

    fn rpc(h: *Harness, msg: anytype) !p9.R {
        const tag = try h.send(msg);
        const r = (try h.next()) orelse return error.NoReply;
        try testing.expectEqual(tag, r.tag);
        return r.msg;
    }

    fn ok(h: *Harness, msg: anytype) !p9.R {
        const r = try h.rpc(msg);
        if (r == .Rerror) {
            std.debug.print("Rerror: {s}\n", .{r.Rerror.ename});
            return error.Rerror;
        }
        return r;
    }

    fn err(h: *Harness, msg: anytype) ![]const u8 {
        const r = try h.rpc(msg);
        if (r != .Rerror) return error.NoError;
        return r.Rerror.ename;
    }

    /// Versions and attaches fid 0.
    fn mount(h: *Harness) !void {
        _ = try h.ok(p9.Tversion{ .msize = 8192 + 24, .version = wire.version_9p });
        _ = try h.ok(p9.Tattach{ .fid = 0, .afid = wire.nofid, .uname = "glenda", .aname = "" });
    }

    fn walk(h: *Harness, fid: u32, newfid: u32, path: []const []const u8) !p9.R {
        return h.rpc(p9.Twalk{ .fid = fid, .newfid = newfid, .wnames = .init(path) });
    }

    /// Walks fid 0 to `path` as `newfid`, opens it, and reads it all.
    fn cat(h: *Harness, newfid: u32, path: []const []const u8) ![]u8 {
        const w = try h.walk(0, newfid, path);
        if (w == .Rerror) {
            std.debug.print("walk: {s}\n", .{w.Rerror.ename});
            return error.Rerror;
        }
        _ = try h.ok(p9.Topen{ .fid = newfid, .mode = wire.OREAD });
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            const r = try h.ok(p9.Tread{ .fid = newfid, .offset = out.items.len, .count = 8192 });
            if (r.Rread.data.bytes.len == 0) break;
            try out.appendSlice(testing.allocator, r.Rread.data.bytes);
        }
        _ = try h.ok(p9.Tclunk{ .fid = newfid });
        return out.toOwnedSlice(testing.allocator);
    }

    /// Reads directory `path` and returns its entries' names and Dirs.
    fn ls(h: *Harness, path: []const []const u8, count: u32) !std.ArrayList(attr.Dir) {
        _ = try h.ok(p9.Twalk{ .fid = 0, .newfid = 99, .wnames = .init(path) });
        _ = try h.ok(p9.Topen{ .fid = 99, .mode = wire.OREAD });
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(testing.allocator);
        var off: u64 = 0;
        while (true) {
            const r = try h.ok(p9.Tread{ .fid = 99, .offset = off, .count = count });
            const b = r.Rread.data.bytes;
            if (b.len == 0) break;
            off += b.len;
            try bytes.appendSlice(testing.allocator, b);
        }
        _ = try h.ok(p9.Tclunk{ .fid = 99 });
        var dirs: std.ArrayList(attr.Dir) = .empty;
        const keepb = try h.s.arena.allocator().dupe(u8, bytes.items);
        var at: usize = 0;
        while (at < keepb.len) {
            const d, const n = attr.Dir.parse(keepb[at..]).?;
            try dirs.append(h.s.arena.allocator(), d);
            at += n;
        }
        return dirs;
    }
};

fn hasName(dirs: []const attr.Dir, name: []const u8) ?attr.Dir {
    for (dirs) |d| if (std.mem.eql(u8, d.name, name)) return d;
    return null;
}

test "negotiates .L and attaches as the host uid" {
    var h = try Harness.init(wire.version_l);
    defer h.deinit();
    const v = try h.ok(p9.Tversion{ .msize = 8216, .version = wire.version_9p });
    try testing.expectEqualStrings(wire.version_9p, v.Rversion.version);
    try testing.expectEqual(@as(u32, 8216), v.Rversion.msize);
    try testing.expectEqual(Dialect.@"9P2000.L", h.c.version());
    const a = try h.ok(p9.Tattach{ .fid = 0, .afid = wire.nofid, .uname = "glenda", .aname = "" });
    try testing.expectEqual(wire.QTDIR, a.Rattach.qid.type);
    try testing.expectEqualStrings("glenda", h.s.attached_as.?[0]);
    try testing.expectEqual(@as(u32, 1000), h.s.attached_as.?[1]);
    try testing.expectEqualStrings("authentication not required", try h.err(p9.Tauth{ .afid = 1, .uname = "glenda", .aname = "" }));
}

test "the server's Rversion can come before devmnt's Tversion" {
    var h = try Harness.init(wire.version_l);
    defer h.deinit();
    try h.pump();
    try testing.expectEqual(Dialect.@"9P2000.L", h.c.version());
    try h.mount();
    try testing.expectEqualStrings("version already negotiated", try h.err(p9.Tversion{ .msize = 8216, .version = wire.version_9p }));
}

test "reads, writes, creates, and removes" {
    var h = try Harness.init(wire.version_l);
    defer h.deinit();
    _ = try h.s.add("etc/motd", .file, "hello from .L\n");
    try h.mount();
    const got = try h.cat(1, &.{ "etc", "motd" });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("hello from .L\n", got);

    // Create a file, write it, read it back, stat it.
    _ = try h.ok(p9.Twalk{ .fid = 0, .newfid = 2, .wnames = .init(&.{"etc"}) });
    const cr = try h.ok(p9.Tcreate{ .fid = 2, .name = "new", .perm = 0o640, .mode = wire.ORDWR });
    try testing.expectEqual(wire.QTFILE, cr.Rcreate.qid.type);
    try testing.expectEqual(@as(u32, 5), (try h.ok(p9.Twrite{ .fid = 2, .offset = 0, .data = .{ .bytes = "12345" } })).Rwrite.count);
    const st = try h.ok(p9.Tstat{ .fid = 2 });
    const d, _ = attr.Dir.parse(h.last[9..]).?;
    _ = st;
    try testing.expectEqualStrings("new", d.name);
    try testing.expectEqual(@as(u64, 5), d.length);
    try testing.expectEqual(@as(u32, 0o640), d.mode);
    try testing.expectEqualStrings("glenda", d.uid);
    _ = try h.ok(p9.Tclunk{ .fid = 2 });
    try testing.expectEqualStrings("12345", h.s.lookup("etc/new").?.data.items);

    // An existing name can't be created.
    _ = try h.ok(p9.Twalk{ .fid = 0, .newfid = 3, .wnames = .init(&.{"etc"}) });
    try testing.expectEqualStrings("file already exists", try h.err(p9.Tcreate{ .fid = 3, .name = "new", .perm = 0o640, .mode = wire.OWRITE }));

    // A directory, then a file in it.
    const dc = try h.ok(p9.Tcreate{ .fid = 3, .name = "sub", .perm = wire.DMDIR | 0o755, .mode = wire.OREAD });
    try testing.expectEqual(wire.QTDIR, dc.Rcreate.qid.type);
    _ = try h.ok(p9.Tclunk{ .fid = 3 });
    try testing.expect(h.s.lookup("etc/sub").?.kind == .dir);

    // Remove the file, then a non-empty directory fails.
    _ = try h.ok(p9.Twalk{ .fid = 0, .newfid = 4, .wnames = .init(&.{ "etc", "new" }) });
    _ = try h.ok(p9.Tremove{ .fid = 4 });
    try testing.expectEqual(@as(?*@import("testserver.zig").Node, null), h.s.lookup("etc/new"));
    _ = try h.ok(p9.Twalk{ .fid = 0, .newfid = 5, .wnames = .init(&.{"etc"}) });
    try testing.expectEqualStrings("directory not empty", try h.err(p9.Tremove{ .fid = 5 }));
    // The fid is gone even so.
    try testing.expectEqualStrings("unknown fid", try h.err(p9.Tstat{ .fid = 5 }));

    // ORCLOSE removes at clunk.
    _ = try h.ok(p9.Twalk{ .fid = 0, .newfid = 6, .wnames = .init(&.{"etc"}) });
    _ = try h.ok(p9.Tcreate{ .fid = 6, .name = "tmp", .perm = 0o600, .mode = wire.OWRITE | wire.ORCLOSE });
    try testing.expect(h.s.lookup("etc/tmp") != null);
    _ = try h.ok(p9.Tclunk{ .fid = 6 });
    try testing.expectEqual(@as(?*@import("testserver.zig").Node, null), h.s.lookup("etc/tmp"));
}

test "walks: partial, errors, and dotdot" {
    var h = try Harness.init(wire.version_l);
    defer h.deinit();
    _ = try h.s.add("a/b/c", .file, "c");
    try h.mount();
    try testing.expectEqualStrings("file does not exist", (try h.walk(0, 1, &.{"nope"})).Rerror.ename);
    const p = try h.walk(0, 1, &.{ "a", "nope", "c" });
    try testing.expectEqual(@as(u16, 1), p.Rwalk.wqids.n);
    // No fid was made by the partial walk.
    try testing.expectEqualStrings("unknown fid", try h.err(p9.Tstat{ .fid = 1 }));
    _ = try h.ok(p9.Twalk{ .fid = 0, .newfid = 1, .wnames = .init(&.{ "a", "b", "..", "b", "c" }) });
    _ = try h.ok(p9.Tstat{ .fid = 1 });
    const d, _ = attr.Dir.parse(h.last[9..]).?;
    try testing.expectEqualStrings("c", d.name);
    // .. at the root stays there.
    _ = try h.ok(p9.Twalk{ .fid = 0, .newfid = 2, .wnames = .init(&.{ "..", "..", "a" }) });
    // Walking a fid to itself replaces it.
    _ = try h.ok(p9.Twalk{ .fid = 2, .newfid = 2, .wnames = .init(&.{"b"}) });
    _ = try h.ok(p9.Tstat{ .fid = 2 });
    const d2, _ = attr.Dir.parse(h.last[9..]).?;
    try testing.expectEqualStrings("b", d2.name);
    try testing.expectEqual(wire.DMDIR | 0o755, d2.mode);
}

test "symlinks are followed inside the mount" {
    var h = try Harness.init(wire.version_l);
    defer h.deinit();
    _ = try h.s.add("etc/passwd", .file, "root:x:0:0\n");
    _ = try h.s.add("usr/lib/x", .file, "x\n");
    _ = try h.s.add("lib", .link, "usr/lib");
    _ = try h.s.add("usr/abs", .link, "/etc/passwd");
    _ = try h.s.add("usr/rel", .link, "../etc/passwd");
    _ = try h.s.add("usr/escape", .link, "../../../../../etc/passwd");
    _ = try h.s.add("usr/chain", .link, "abs");
    _ = try h.s.add("loop", .link, "loop");
    _ = try h.s.add("dangling", .link, "nowhere");
    try h.mount();
    for ([_][]const []const u8{ &.{ "usr", "abs" }, &.{ "usr", "rel" }, &.{ "usr", "escape" }, &.{ "usr", "chain" } }, 10..) |path, fid| {
        const got = try h.cat(@intCast(fid), path);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings("root:x:0:0\n", got);
    }
    // Through a link to a directory, with a qid for each name.
    const w = try h.walk(0, 1, &.{ "lib", "x" });
    try testing.expectEqual(@as(u16, 2), w.Rwalk.wqids.n);
    try testing.expectEqual(wire.QTDIR, w.Rwalk.wqids.qids[0].type);
    const got = try h.cat(2, &.{ "lib", "x" });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("x\n", got);
    // A fid's path is its link's target's, so .. from /lib goes to /usr.
    _ = try h.ok(p9.Twalk{ .fid = 0, .newfid = 3, .wnames = .init(&.{"lib"}) });
    _ = try h.ok(p9.Twalk{ .fid = 3, .newfid = 3, .wnames = .init(&.{ "..", "abs" }) });
    try testing.expectEqualStrings("too many symbolic links", (try h.walk(0, 4, &.{"loop"})).Rerror.ename);
    try testing.expectEqualStrings("file does not exist", (try h.walk(0, 4, &.{"dangling"})).Rerror.ename);
    // A link that fails partway is a partial walk.
    try testing.expectEqual(@as(u16, 1), (try h.walk(0, 4, &.{ "usr", "loop" })).Rwalk.wqids.n);
}

test "directory reads" {
    var h = try Harness.init(wire.version_l);
    defer h.deinit();
    for (0..40) |i| {
        var name: [16]u8 = undefined;
        _ = try h.s.add(try std.fmt.bufPrint(&name, "d/file{d}", .{i}), .file, "data");
    }
    _ = try h.s.add("d/sub/f", .file, "");
    _ = try h.s.add("d/link", .link, "sub");
    _ = try h.s.add("d/dangling", .link, "nowhere");
    _ = try h.s.add("d/fifo", .fifo, "");
    (try h.s.add("d/owned", .file, "")).uid = 7;
    try h.mount();
    // Small reads, so the Dirs come in several.
    var dirs = try h.ls(&.{"d"}, 200);
    try testing.expectEqual(@as(usize, 40 + 4), dirs.items.len);
    try testing.expect(hasName(dirs.items, ".") == null);
    try testing.expect(hasName(dirs.items, "dangling") == null);
    const link = hasName(dirs.items, "link").?;
    try testing.expectEqual(wire.DMDIR | 0o755, link.mode);
    try testing.expectEqual(@as(u64, 4), hasName(dirs.items, "file39").?.length);
    try testing.expectEqualStrings("7", hasName(dirs.items, "owned").?.uid);
    try testing.expectEqualStrings("glenda", hasName(dirs.items, "file0").?.uid);
    try testing.expectEqual(@as(u64, 0), hasName(dirs.items, "fifo").?.length);
    dirs = try h.ls(&.{"d"}, 8192);
    try testing.expectEqual(@as(usize, 44), dirs.items.len);

    // A FIFO doesn't open.
    _ = try h.ok(p9.Twalk{ .fid = 0, .newfid = 5, .wnames = .init(&.{ "d", "fifo" }) });
    try testing.expectEqualStrings("not a regular file", try h.err(p9.Topen{ .fid = 5, .mode = wire.OREAD }));
    // Nor does a directory for writing.
    _ = try h.ok(p9.Twalk{ .fid = 0, .newfid = 6, .wnames = .init(&.{"d"}) });
    try testing.expectEqualStrings("file is a directory", try h.err(p9.Topen{ .fid = 6, .mode = wire.OWRITE }));
}

test "wstat renames, truncates, and syncs" {
    var h = try Harness.init(wire.version_l);
    defer h.deinit();
    _ = try h.s.add("dir/f", .file, "abcdef");
    try h.mount();
    _ = try h.ok(p9.Twalk{ .fid = 0, .newfid = 1, .wnames = .init(&.{ "dir", "f" }) });
    var d = attr.Dir.keep;
    d.name = "g";
    d.length = 2;
    var buf: [128]u8 = undefined;
    const b = try d.pack(&buf);
    _ = try h.ok(p9.Twstat{ .fid = 1, .stat = .{ .bytes = b } });
    try testing.expectEqualStrings("ab", h.s.lookup("dir/g").?.data.items);
    _ = try h.ok(p9.Tstat{ .fid = 1 });
    const st, _ = attr.Dir.parse(h.last[9..]).?;
    try testing.expectEqualStrings("g", st.name);
    // Its new path is what removes it.
    const n = h.s.log.items.len;
    const nb = try attr.Dir.keep.pack(&buf);
    _ = try h.ok(p9.Twstat{ .fid = 1, .stat = .{ .bytes = nb } });
    try testing.expectEqual(@as(u8, l.Tfsync.id), h.s.log.items[n]);
    _ = try h.ok(p9.Tremove{ .fid = 1 });
    try testing.expect(h.s.lookup("dir/g") == null);
}

test "9P2000 servers pass through" {
    var h = try Harness.init(wire.version_9p);
    defer h.deinit();
    const v = try h.ok(p9.Tversion{ .msize = 8216, .version = wire.version_9p });
    try testing.expectEqual(@as(u32, 8216), v.Rversion.msize);
    try testing.expectEqual(Dialect.@"9P2000", h.c.version());
    var buf: [64]u8 = undefined;
    const f = try wire.encode(&buf, 9, p9.Tstat{ .fid = 3 }, null);
    try h.c.fromMount(f);
    try testing.expectEqualSlices(u8, f, h.c.toServer());
    h.c.consumedServer(f.len);
    try h.c.fromServer("\x07\x00\x00\x00\x7f\x09\x00");
    try testing.expectEqualStrings("\x07\x00\x00\x00\x7f\x09\x00", h.c.toMount());
}

test "an unknown version fails the mount" {
    var h = try Harness.init("9P2000.u");
    defer h.deinit();
    try testing.expectEqualStrings("server speaks unknown 9P version 9P2000.u", try h.err(p9.Tversion{ .msize = 8216, .version = wire.version_9p }));
}

test "a flush flushes the server's requests" {
    var h = try Harness.init(wire.version_l);
    defer h.deinit();
    _ = try h.s.add("f", .file, "data");
    try h.mount();
    _ = try h.ok(p9.Twalk{ .fid = 0, .newfid = 1, .wnames = .init(&.{"f"}) });
    _ = try h.ok(p9.Topen{ .fid = 1, .mode = wire.OREAD });
    h.s.hold = true;
    const rt = try h.send(p9.Tread{ .fid = 1, .offset = 0, .count = 10 });
    try testing.expectEqual(@as(?wire.Frame(p9.R), null), try h.next());
    const ft = try h.send(p9.Tflush{ .oldtag = rt });
    const r = (try h.next()).?;
    try testing.expectEqual(ft, r.tag);
    try testing.expect(r.msg == .Rflush);
    try h.s.release();
    try h.pump();
    try testing.expectEqual(@as(?wire.Frame(p9.R), null), try h.next());
    // The tag is free again.
    _ = try h.ok(p9.Tclunk{ .fid = 1 });
}

test "a reply for no request fails the connection" {
    var h = try Harness.init(wire.version_l);
    defer h.deinit();
    try h.mount();
    var buf: [32]u8 = undefined;
    try h.c.fromServer(try wire.encode(&buf, 999, wire.common.Rclunk{}, null));
    try testing.expectEqual(Dialect.failed, h.c.version());
    try testing.expectEqualStrings("9P reply for no request", try h.err(p9.Tstat{ .fid = 0 }));
}
