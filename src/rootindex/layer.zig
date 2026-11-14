//! The index layer (design/mount-index.md, "Serving from the index"):
//! a state machine over 9P2000 between devmnt and a server connection,
//! which answers walks, stats, and directory reads from a metadata index
//! and sends opens, reads, and writes on to the server.
//!
//! Like the 9P2000.L translator (src/dotl/client.zig) it has no I/O of
//! its own: `#ι` (src/kern/devhidx.c) feeds it what devmnt writes
//! (`fromMount`) and what the server sends (`fromServer`), and sends on
//! what it queues (`toServer`, `toMount`). The host cache is reached
//! through `Hooks`, so the tests run it against a server in memory.
//!
//! Every fid devmnt uses is either real (the server has it) or virtual
//! (only the index knows it, by its entry). devmnt's own fids and tags
//! pass through unchanged; the layer's own requests use fids from
//! `0xF0000000` and tags from `0xFFFE` down, which devmnt, allocating
//! from the bottom, never reaches.
//!
//! At devmnt's first attach the layer holds the Rattach back while it
//! finds the index (the one it was given, or the server's `/.h9index`,
//! through the cache), and validates every indexed directory against the
//! server, with up to 64 outstanding at once. A directory whose qid or
//! mtime differs is demoted, and so is anything a mutation through the
//! mount touches: a demoted entry is served by plain 9P for the rest of
//! the connection. Later attaches, such as a guest's own mount of
//! `/srv/root`, pass through, so `mkindex` sees the server.

const std = @import("std");
const wire = @import("../dotl/wire.zig");
const attr = @import("../dotl/attr.zig");
const ri = @import("../rootindex.zig");

const p9 = wire.p9;
const Allocator = std.mem.Allocator;
const Index = ri.Index;

/// What devmnt is told for a name the index says isn't there.
pub const enonexist = "file does not exist";

/// Directories validated at once.
pub const max_validating = 64;
/// Reads of `/.h9index` outstanding at once.
const max_reads = 16;
const first_private_fid: u32 = 0xF0000000;
const first_private_tag: u16 = 0xFFFE;
const last_private_tag: u16 = 0xF000;

pub const Hooks = struct {
    ctx: ?*anyopaque = null,
    /// A compiled index cached under `key` at `version`, which the
    /// caller then owns (allocated with the layer's allocator); or null.
    lookup: ?*const fn (ctx: ?*anyopaque, key: []const u8, version: []const u8) ?[]u8 = null,
    /// Keeps a compiled index under `key` at `version`.
    store: ?*const fn (ctx: ?*anyopaque, key: []const u8, version: []const u8, compiled: []const u8) void = null,
    /// A monotonic clock, for how long validation took.
    now_ns: ?*const fn () u64 = null,
};

pub const Source = union(enum) {
    /// No index: everything passes through.
    none,
    /// A compiled index given with the mount (`--root-index`), owned by
    /// the layer from `init`, and what to call it.
    given: struct { compiled: []u8, label: []const u8, cached: bool = false },
    /// The server's `/.h9index`, cached under `key`: its address and
    /// attach name.
    server: struct { key: []const u8 },
};

pub const Error = error{ OutOfMemory, Malformed };

const Fid = struct {
    real: bool,
    /// Its index entry, while the index can answer for it.
    node: ?u32,
    open: enum { no, local, real } = .no,
    /// A directory read answered locally: the next child, and the offset
    /// devmnt is at.
    cursor: u32 = 0,
    offset: u64 = 0,
};

const Kind = enum {
    plain,
    version,
    attach_first,
    attach,
    walk,
    /// A virtual fid's walk sent from the root, its path first.
    walk_root,
    stat,
    open,
    create,
    remove,
    wstat,
    write,
    flush,
};

/// A devmnt request the layer is answering, by its tag.
const Pending = struct {
    kind: Kind,
    fid: u32 = 0,
    newfid: u32 = 0,
    node: ?u32 = null,
    /// A walk's names, and for walk_root how many of the path came first.
    names: [][]u8 = &.{},
    prefix: usize = 0,
    mode: u8 = 0,
    oldtag: u16 = 0,
    /// Waiting for its fid to be made real, with the request to send.
    making_real: bool = false,
    frame: ?[]u8 = null,
    flushed: bool = false,
    aname: ?[]u8 = null,
};

/// The layer's own requests, by tag.
const Priv = union(enum) {
    root_clone,
    idx_walk,
    idx_stat,
    idx_open,
    idx_read: struct { off: u64, count: u32 },
    val_walk: struct { slot: u32, start: usize, end: usize },
    val_stat: u32,
    list_walk,
    list_open,
    list_read: u64,
    make_real: struct { tag: u16, fid: u32, start: usize, end: usize },
    clunk: u32,
};

const Slot = struct {
    entry: u32,
    pfid: ?u32 = null,
};

pub const Phase = enum { attach, bootstrap, serving, passthrough, failed };

pub const Layer = struct {
    gpa: Allocator,
    source: Source,
    hooks: Hooks,
    phase: Phase,

    in_mount: std.ArrayList(u8) = .empty,
    in_server: std.ArrayList(u8) = .empty,
    out_mount: std.ArrayList(u8) = .empty,
    out_server: std.ArrayList(u8) = .empty,
    /// devmnt's requests during the bootstrap, handled after it.
    deferred: std.ArrayList(u8) = .empty,
    scratch: std.ArrayList(u8) = .empty,

    msize: u32 = 1 << 24,
    index: ?Index = null,
    /// What the index is called in notes and status.
    label: []const u8 = "/.h9index",
    demoted: std.DynamicBitSetUnmanaged = .{},
    /// Entries whose own stat goes to the server though they still
    /// answer walks: the root, when only its listing validated.
    stale_stat: std.DynamicBitSetUnmanaged = .{},

    fids: std.AutoHashMapUnmanaged(u32, Fid) = .empty,
    pending: std.AutoHashMapUnmanaged(u16, Pending) = .empty,
    private: std.AutoHashMapUnmanaged(u16, Priv) = .empty,
    next_tag: u16 = first_private_tag,
    free_pfids: std.ArrayList(u32) = .empty,
    next_pfid: u32 = first_private_fid,

    attach_fid: u32 = 0,
    held_attach: ?[]u8 = null,
    privroot: ?u32 = null,
    root_clone_pending: bool = false,
    abandoning: bool = false,

    // The server's /.h9index.
    pidx: u32 = 0,
    idx_version: [96]u8 = undefined,
    idx_version_len: usize = 0,
    idx_len: u64 = 0,
    idx_buf: []u8 = &.{},
    idx_next: u64 = 0,
    idx_eof: u64 = std.math.maxInt(u64),
    idx_reads: u32 = 0,
    idx_chunk: u32 = 0,
    from_cache: bool = false,

    // Validation.
    slots: std.ArrayList(Slot) = .empty,
    slot_next: usize = 0,
    validating: u32 = 0,
    checked: u32 = 0,
    ndemoted: u32 = 0,
    listing: std.ArrayList(u8) = .empty,
    list_pfid: u32 = 0,
    list_pending: bool = false,
    t_start: u64 = 0,
    t_ms: u64 = 0,

    /// T-messages devmnt sent, and the layer sent the server.
    from_mount_t: u64 = 0,
    to_server_t: u64 = 0,
    /// Of those, the ones sent to find and check the index.
    boot_t: u64 = 0,
    /// Notes for `-v`, a line each.
    notes: std.ArrayList(u8) = .empty,
    err: ?[]const u8 = null,

    pub fn init(gpa: Allocator, source: Source, hooks: Hooks) Layer {
        var l: Layer = .{
            .gpa = gpa,
            .source = source,
            .hooks = hooks,
            .phase = if (source == .none) .passthrough else .attach,
        };
        switch (source) {
            .given => |g| {
                l.label = g.label;
                l.from_cache = g.cached;
            },
            else => {},
        }
        return l;
    }

    pub fn deinit(l: *Layer) void {
        const gpa = l.gpa;
        for ([_]*std.ArrayList(u8){ &l.in_mount, &l.in_server, &l.out_mount, &l.out_server, &l.deferred, &l.scratch, &l.notes, &l.listing }) |b| b.deinit(gpa);
        var it = l.pending.valueIterator();
        while (it.next()) |p| freePending(gpa, p);
        l.pending.deinit(gpa);
        l.private.deinit(gpa);
        l.fids.deinit(gpa);
        l.free_pfids.deinit(gpa);
        l.slots.deinit(gpa);
        l.demoted.deinit(gpa);
        l.stale_stat.deinit(gpa);
        if (l.held_attach) |h| gpa.free(h);
        if (l.idx_buf.len > 0) gpa.free(l.idx_buf);
        if (l.index) |*x| x.deinit(gpa);
        switch (l.source) {
            .given => |g| if (l.index == null) gpa.free(g.compiled),
            else => {},
        }
        l.* = undefined;
    }

    /// Bytes to send to the server; `consumedServer` drops what was sent.
    pub fn toServer(l: *const Layer) []const u8 {
        return l.out_server.items;
    }

    pub fn consumedServer(l: *Layer, n: usize) void {
        consume(&l.out_server, n);
    }

    /// Bytes for devmnt to read; `consumedMount` drops what it read.
    pub fn toMount(l: *const Layer) []const u8 {
        return l.out_mount.items;
    }

    pub fn consumedMount(l: *Layer, n: usize) void {
        consume(&l.out_mount, n);
    }

    fn consume(b: *std.ArrayList(u8), n: usize) void {
        std.mem.copyForwards(u8, b.items[0 .. b.items.len - n], b.items[n..]);
        b.items.len -= n;
    }

    /// Whether the index is serving (after the first attach's bootstrap).
    pub fn serving(l: *const Layer) bool {
        return l.phase == .serving;
    }

    /// Takes bytes devmnt wrote.
    pub fn fromMount(l: *Layer, bytes: []const u8) Error!void {
        if (l.phase == .failed) return error.Malformed;
        try l.in_mount.appendSlice(l.gpa, bytes);
        while (true) {
            const h = wire.header(l.in_mount.items, l.msize) catch return l.fail("bad 9P message from the mount");
            const hd = h orelse break;
            if (l.in_mount.items.len < hd.size) break;
            const frame = try l.gpa.dupe(u8, l.in_mount.items[0..hd.size]);
            defer l.gpa.free(frame);
            consume(&l.in_mount, hd.size);
            l.from_mount_t += 1;
            if (l.phase == .bootstrap) {
                try l.deferred.appendSlice(l.gpa, frame);
                continue;
            }
            try l.request(frame);
        }
    }

    /// Takes bytes from the server.
    pub fn fromServer(l: *Layer, bytes: []const u8) Error!void {
        if (l.phase == .failed) return error.Malformed;
        try l.in_server.appendSlice(l.gpa, bytes);
        while (true) {
            const h = wire.header(l.in_server.items, l.msize) catch return l.fail("bad 9P message from the server");
            const hd = h orelse break;
            if (l.in_server.items.len < hd.size) break;
            const frame = try l.gpa.dupe(u8, l.in_server.items[0..hd.size]);
            defer l.gpa.free(frame);
            consume(&l.in_server, hd.size);
            try l.reply(frame);
        }
    }

    fn fail(l: *Layer, msg: []const u8) Error {
        l.phase = .failed;
        l.err = msg;
        return error.Malformed;
    }

    // Sending.

    fn sendServer(l: *Layer, tag: u16, msg: anytype) Error!void {
        try l.scratch.resize(l.gpa, @max(@as(usize, 1 << 16), @min(l.msize, 1 << 20)));
        const f = wire.encode(l.scratch.items, tag, msg, null) catch return l.fail("9P message too big");
        try l.out_server.appendSlice(l.gpa, f);
        l.countSent();
    }

    fn forward(l: *Layer, frame: []const u8) Error!void {
        try l.out_server.appendSlice(l.gpa, frame);
        l.countSent();
    }

    fn countSent(l: *Layer) void {
        l.to_server_t += 1;
        if (l.phase == .bootstrap) l.boot_t += 1;
    }

    fn sendMount(l: *Layer, tag: u16, msg: anytype) Error!void {
        try l.scratch.resize(l.gpa, @max(@as(usize, 1 << 16), @min(l.msize, 1 << 20)));
        const f = wire.encode(l.scratch.items, tag, msg, null) catch return l.fail("9P message too big");
        try l.out_mount.appendSlice(l.gpa, f);
    }

    fn rerror(l: *Layer, tag: u16, msg: []const u8) Error!void {
        return l.sendMount(tag, p9.Rerror{ .ename = msg });
    }

    fn allocTag(l: *Layer) ?u16 {
        var tries: usize = 0;
        while (tries < first_private_tag - last_private_tag) : (tries += 1) {
            const t = l.next_tag;
            l.next_tag = if (l.next_tag == last_private_tag) first_private_tag else l.next_tag - 1;
            if (!l.private.contains(t) and !l.pending.contains(t)) return t;
        }
        return null;
    }

    fn privSend(l: *Layer, what: Priv, msg: anytype) Error!void {
        const tag = l.allocTag() orelse return l.fail("out of private tags");
        try l.private.put(l.gpa, tag, what);
        try l.sendServer(tag, msg);
    }

    fn allocPfid(l: *Layer) u32 {
        if (l.free_pfids.pop()) |f| return f;
        defer l.next_pfid += 1;
        return l.next_pfid;
    }

    fn clunkPrivate(l: *Layer, fid: u32) Error!void {
        try l.privSend(.{ .clunk = fid }, p9.Tclunk{ .fid = fid });
    }

    // The index.

    fn ix(l: *const Layer) *const Index {
        return &l.index.?;
    }

    fn isDemoted(l: *const Layer, i: u32) bool {
        return l.demoted.isSet(i);
    }

    fn demote(l: *Layer, i: u32) void {
        if (l.index == null or i >= l.ix().n) return;
        if (!l.demoted.isSet(i)) {
            l.demoted.set(i);
            if (l.ix().isDir(i)) l.ndemoted += 1;
        }
    }

    /// Whether the index answers lookups in entry `i`.
    fn answerable(l: *const Layer, i: u32) bool {
        const x = l.ix();
        return x.isDir(i) and !x.unindexed(i) and !l.isDemoted(i);
    }

    /// The entry `names` lead to from `node`, through answerable
    /// directories, if its qid.path is `last`; or null.
    fn resolve(l: *const Layer, node: ?u32, names: []const []const u8, last: ?wire.Qid) ?u32 {
        var cur = node orelse return null;
        const x = l.ix();
        for (names) |n| {
            if (!l.answerable(cur)) return null;
            cur = if (std.mem.eql(u8, n, "..")) x.parent(cur) else x.lookup(cur, n) orelse return null;
        }
        if (last) |q| if (x.qid(cur).path != q.path) return null;
        return cur;
    }

    // devmnt's requests.

    fn request(l: *Layer, frame: []const u8) Error!void {
        // Without an index everything passes, and before the first
        // attach so does all but Tversion's msize and the attach.
        if (l.phase == .passthrough) return l.forward(frame);
        if (l.phase == .attach and frame[4] != p9.Tattach.id and frame[4] != p9.Tversion.id) return l.forward(frame);
        const d = wire.decode(p9.T, frame, l.msize, false) catch return l.fail("bad 9P message from the mount");
        const tag = d.tag;
        if (tag >= last_private_tag and tag != wire.notag) return l.fail("devmnt tag in the layer's range");
        if (l.pending.contains(tag)) return l.fail("tag in use");
        switch (d.msg) {
            .Tversion => {
                try l.pending.put(l.gpa, tag, .{ .kind = .version });
                return l.forward(frame);
            },
            .Tattach => |a| {
                if (l.phase == .attach) {
                    try l.pending.put(l.gpa, tag, .{ .kind = .attach_first, .fid = a.fid });
                } else try l.pending.put(l.gpa, tag, .{ .kind = .attach, .fid = a.fid });
                return l.forward(frame);
            },
            .Tflush => |f| return l.flush(tag, frame, f.oldtag),
            .Twalk => |w| return l.walk(tag, frame, w),
            .Tstat => |s| {
                const f = l.fids.getPtr(s.fid) orelse return l.plain(tag, frame);
                if (f.node) |n| if (!l.isDemoted(n) and !l.stale_stat.isSet(n)) {
                    var buf: [4096]u8 = undefined;
                    const dir = l.ix().dir(n);
                    if (dir.pack(&buf)) |packed_dir| {
                        return l.sendMount(tag, p9.Rstat{ .stat = .{ .bytes = packed_dir } });
                    } else |_| {}
                };
                return l.viaReal(tag, frame, s.fid, .{ .kind = .stat, .fid = s.fid });
            },
            .Topen => |o| {
                const f = l.fids.getPtr(o.fid) orelse return l.plain(tag, frame);
                if (f.node) |n| if (l.answerable(n) and o.mode & 3 == wire.OREAD and o.mode & (wire.OTRUNC | wire.ORCLOSE) == 0 and f.open == .no) {
                    f.open = .local;
                    f.cursor = 0;
                    f.offset = 0;
                    return l.sendMount(tag, p9.Ropen{ .qid = l.ix().qid(n), .iounit = 0 });
                };
                return l.viaReal(tag, frame, o.fid, .{ .kind = .open, .fid = o.fid, .mode = o.mode });
            },
            .Tread => |r| {
                const f = l.fids.getPtr(r.fid) orelse return l.plain(tag, frame);
                if (f.open == .local) return l.dirRead(tag, f, r.offset, r.count);
                return l.plain(tag, frame);
            },
            .Twrite => |w| {
                if (!l.fids.contains(w.fid)) return l.plain(tag, frame);
                try l.pending.put(l.gpa, tag, .{ .kind = .write, .fid = w.fid });
                return l.forward(frame);
            },
            .Tclunk => |c| {
                const f = l.fids.fetchRemove(c.fid) orelse return l.plain(tag, frame);
                if (f.value.real) return l.plain(tag, frame);
                return l.sendMount(tag, p9.Rclunk{});
            },
            .Tcreate => |c| {
                if (!l.fids.contains(c.fid)) return l.plain(tag, frame);
                return l.viaReal(tag, frame, c.fid, .{ .kind = .create, .fid = c.fid });
            },
            .Tremove => |r| {
                const f = l.fids.get(r.fid) orelse return l.plain(tag, frame);
                return l.viaReal(tag, frame, r.fid, .{ .kind = .remove, .fid = r.fid, .node = f.node });
            },
            .Twstat => |w| {
                const f = l.fids.get(w.fid) orelse return l.plain(tag, frame);
                return l.viaReal(tag, frame, w.fid, .{ .kind = .wstat, .fid = w.fid, .node = f.node });
            },
            .Tauth => return l.plain(tag, frame),
        }
    }

    fn plain(l: *Layer, tag: u16, frame: []const u8) Error!void {
        if (tag != wire.notag) try l.pending.put(l.gpa, tag, .{ .kind = .plain });
        return l.forward(frame);
    }

    /// Sends `frame` once fid is real, making it so first if it's virtual.
    fn viaReal(l: *Layer, tag: u16, frame: []const u8, fid: u32, p: Pending) Error!void {
        const f = l.fids.getPtr(fid).?;
        var pend = p;
        if (f.real) {
            try l.pending.put(l.gpa, tag, pend);
            return l.forward(frame);
        }
        pend.making_real = true;
        pend.frame = try l.gpa.dupe(u8, frame);
        try l.pending.put(l.gpa, tag, pend);
        return l.makeReal(tag, fid, 0);
    }

    /// Walks the server's fid `fid` to its entry's path from the root, in
    /// steps of at most 16 names, from step `done`.
    fn makeReal(l: *Layer, tag: u16, fid: u32, done: usize) Error!void {
        const f = l.fids.getPtr(fid).?;
        var buf: [ri.max_depth][]const u8 = undefined;
        const names = l.ix().pathNames(f.node.?, &buf) orelse return l.makeRealFailed(tag, fid, enonexist, done > 0);
        const end = @min(names.len, done + wire.max_welem);
        const from = if (done == 0) l.privroot.? else fid;
        try l.privSend(.{ .make_real = .{ .tag = tag, .fid = fid, .start = done, .end = end } }, p9.Twalk{ .fid = from, .newfid = fid, .wnames = .init(names[done..end]) });
    }

    fn makeRealFailed(l: *Layer, tag: u16, fid: u32, msg: []const u8, exists: bool) Error!void {
        if (exists) try l.clunkPrivate(fid);
        if (l.fids.get(fid)) |f| if (f.node) |n| {
            // The index is wrong about it: its directory has changed.
            l.demote(n);
            l.demote(l.ix().parent(n));
        };
        var p = l.pending.fetchRemove(tag).?.value;
        defer freePending(l.gpa, &p);
        if (p.kind == .remove) _ = l.fids.remove(fid);
        if (!p.flushed) try l.rerror(tag, msg);
    }

    fn madeReal(l: *Layer, tag: u16, fid: u32) Error!void {
        if (l.fids.getPtr(fid)) |f| f.real = true;
        const p = l.pending.getPtr(tag).?;
        const frame = p.frame.?;
        p.frame = null;
        p.making_real = false;
        defer l.gpa.free(frame);
        if (p.flushed) {
            var gone = l.pending.fetchRemove(tag).?.value;
            freePending(l.gpa, &gone);
            return;
        }
        return l.forward(frame);
    }

    fn flush(l: *Layer, tag: u16, frame: []const u8, oldtag: u16) Error!void {
        if (l.pending.getPtr(oldtag)) |p| if (p.making_real) {
            // Not sent yet: it never will be.
            p.flushed = true;
            return l.sendMount(tag, p9.Rflush{});
        };
        // To the server, even for a request the layer answered, so this
        // Rflush can't overtake an earlier flush's of the same request:
        // devmnt drops a chain of flushes when the last is answered.
        try l.pending.put(l.gpa, tag, .{ .kind = .flush, .oldtag = oldtag });
        return l.forward(frame);
    }

    fn walk(l: *Layer, tag: u16, frame: []const u8, w: p9.Twalk) Error!void {
        const names = w.wnames.slice();
        const f = (l.fids.get(w.fid)) orelse return l.plain(tag, frame);
        if (f.node == null or f.open != .no or (w.newfid == w.fid and f.real)) {
            if (!f.real) return l.rerror(tag, "walk of an open fid");
            return l.forwardWalk(tag, frame, w, f.node);
        }
        const x = l.ix();
        var cur = f.node.?;
        var qids: [wire.max_welem]wire.Qid = undefined;
        var i: usize = 0;
        while (i < names.len) : (i += 1) {
            if (!l.answerable(cur)) break;
            const next = if (std.mem.eql(u8, names[i], "..")) x.parent(cur) else x.lookup(cur, names[i]) orelse {
                if (i == 0) return l.rerror(tag, enonexist);
                return l.sendMount(tag, p9.Rwalk{ .wqids = .init(qids[0..i]) });
            };
            qids[i] = x.qid(next);
            cur = next;
        }
        if (i == names.len) {
            try l.fids.put(l.gpa, w.newfid, .{ .real = false, .node = cur });
            return l.sendMount(tag, p9.Rwalk{ .wqids = .init(qids[0..i]) });
        }
        // A name the index can't answer for: the server's walk.
        if (f.real) return l.forwardWalk(tag, frame, w, f.node);
        var buf: [ri.max_depth][]const u8 = undefined;
        const prefix = x.pathNames(f.node.?, &buf) orelse return l.rerror(tag, enonexist);
        if (prefix.len + names.len <= wire.max_welem) {
            var all: [wire.max_welem][]const u8 = undefined;
            @memcpy(all[0..prefix.len], prefix);
            @memcpy(all[prefix.len..][0..names.len], names);
            try l.pending.put(l.gpa, tag, .{ .kind = .walk_root, .fid = w.fid, .newfid = w.newfid, .node = f.node, .names = try dupeNames(l.gpa, names), .prefix = prefix.len });
            return l.sendServer(tag, p9.Twalk{ .fid = l.privroot.?, .newfid = w.newfid, .wnames = .init(all[0 .. prefix.len + names.len]) });
        }
        return l.viaReal(tag, frame, w.fid, .{ .kind = .walk, .fid = w.fid, .newfid = w.newfid, .node = f.node, .names = try dupeNames(l.gpa, names) });
    }

    fn forwardWalk(l: *Layer, tag: u16, frame: []const u8, w: p9.Twalk, node: ?u32) Error!void {
        try l.pending.put(l.gpa, tag, .{ .kind = .walk, .fid = w.fid, .newfid = w.newfid, .node = node, .names = try dupeNames(l.gpa, w.wnames.slice()) });
        return l.forward(frame);
    }

    fn dirRead(l: *Layer, tag: u16, f: *Fid, offset: u64, count: u32) Error!void {
        if (offset == 0) {
            f.cursor = 0;
            f.offset = 0;
        } else if (offset != f.offset) return l.rerror(tag, "bad offset in directory read");
        const x = l.ix();
        const c = x.children(f.node.?);
        const max = @min(count, l.msize -| wire.io_header);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(l.gpa);
        var buf: [4096]u8 = undefined;
        while (f.cursor < c.count) {
            const d = x.dir(c.first + f.cursor);
            const b = d.pack(&buf) catch return l.fail("stat too big");
            if (out.items.len + b.len > max) break;
            try out.appendSlice(l.gpa, b);
            f.cursor += 1;
        }
        if (out.items.len == 0 and f.cursor < c.count) return l.rerror(tag, "directory entry too big for the read");
        f.offset += out.items.len;
        return l.sendMount(tag, p9.Rread{ .data = .{ .bytes = out.items } });
    }

    // The server's replies.

    fn reply(l: *Layer, frame: []const u8) Error!void {
        const tag = std.mem.readInt(u16, frame[5..7], .little);
        if (l.private.fetchRemove(tag)) |kv| {
            const d = wire.decode(p9.R, frame, l.msize, false) catch return l.fail("bad 9P message from the server");
            return l.privateReply(kv.value, d.msg);
        }
        var p = (l.pending.fetchRemove(tag) orelse {
            // Untracked (passthrough): devmnt's.
            return l.out_mount.appendSlice(l.gpa, frame);
        }).value;
        defer freePending(l.gpa, &p);
        if (p.kind == .plain) return l.out_mount.appendSlice(l.gpa, frame);
        const d = wire.decode(p9.R, frame, l.msize, false) catch return l.fail("bad 9P message from the server");
        const ok = d.msg != .Rerror;
        switch (p.kind) {
            .plain => unreachable,
            .version => if (d.msg == .Rversion) {
                l.msize = @max(d.msg.Rversion.msize, 256);
            },
            .attach_first => if (d.msg == .Rattach) {
                try l.fids.put(l.gpa, p.fid, .{ .real = true, .node = null });
                l.attach_fid = p.fid;
                l.held_attach = try l.gpa.dupe(u8, frame);
                return l.bootstrap();
            },
            .attach => if (ok) try l.fids.put(l.gpa, p.fid, .{ .real = true, .node = null }),
            .walk => if (d.msg == .Rwalk and d.msg.Rwalk.wqids.n == p.names.len) {
                const q = if (p.names.len == 0) null else d.msg.Rwalk.wqids.slice()[p.names.len - 1];
                const node = if (l.index != null) l.resolve(p.node, constNames(p.names), q) else null;
                try l.fids.put(l.gpa, p.newfid, .{ .real = true, .node = node });
            },
            .walk_root => {
                if (d.msg != .Rwalk) return l.out_mount.appendSlice(l.gpa, frame);
                const got = d.msg.Rwalk.wqids.slice();
                if (got.len < p.prefix or (got.len == p.prefix and p.names.len > 0)) {
                    if (got.len < p.prefix) if (p.node) |n| {
                        l.demote(n);
                        l.demote(l.ix().parent(n));
                    };
                    return l.rerror(tag, enonexist);
                }
                const mine = got[p.prefix..];
                if (mine.len == p.names.len) {
                    const q = if (mine.len == 0) null else mine[mine.len - 1];
                    try l.fids.put(l.gpa, p.newfid, .{ .real = true, .node = l.resolve(p.node, constNames(p.names), q) });
                }
                return l.sendMount(tag, p9.Rwalk{ .wqids = .init(mine) });
            },
            .stat => {},
            .open => if (d.msg == .Ropen) {
                if (l.fids.getPtr(p.fid)) |f| {
                    f.open = .real;
                    if (f.node) |n| {
                        const q = d.msg.Ropen.qid;
                        const iq = l.ix().qid(n);
                        if (q.path != iq.path or q.vers != iq.vers or p.mode & 3 != wire.OREAD and p.mode & 3 != wire.OEXEC or p.mode & wire.OTRUNC != 0) l.demote(n);
                    }
                }
            },
            .create => if (d.msg == .Rcreate) {
                if (l.fids.getPtr(p.fid)) |f| {
                    if (f.node) |n| l.demote(n);
                    f.node = null;
                    f.open = .real;
                }
            },
            .remove => {
                _ = l.fids.remove(p.fid);
                if (ok) if (p.node) |n| {
                    l.demote(n);
                    l.demote(l.ix().parent(n));
                };
            },
            .wstat => if (ok) if (p.node) |n| {
                l.demote(n);
                l.demote(l.ix().parent(n));
            },
            .write => if (ok) if (l.fids.get(p.fid)) |f| if (f.node) |n| l.demote(n),
            .flush => if (l.pending.fetchRemove(p.oldtag)) |kv| {
                var gone = kv.value;
                freePending(l.gpa, &gone);
            },
        }
        return l.out_mount.appendSlice(l.gpa, frame);
    }

    // The bootstrap: finding the index, and validating it.

    fn bootstrap(l: *Layer) Error!void {
        l.phase = .bootstrap;
        if (l.hooks.now_ns) |now| l.t_start = now();
        const pr = l.allocPfid();
        l.root_clone_pending = true;
        try l.privSend(.root_clone, p9.Twalk{ .fid = l.attach_fid, .newfid = pr, .wnames = .init(&.{}) });
        l.privroot = pr;
        switch (l.source) {
            .none => unreachable,
            .given => |g| {
                l.index = Index.init(g.compiled) catch {
                    try l.note("index: {s}: compiled index is damaged; ignored", .{l.label});
                    l.gpa.free(g.compiled);
                    return l.abandon();
                };
                l.index.?.owned = true;
                try l.indexReady();
            },
            .server => {
                l.pidx = l.allocPfid();
                try l.privSend(.idx_walk, p9.Twalk{ .fid = l.attach_fid, .newfid = l.pidx, .wnames = .init(&.{ri.file_name}) });
            },
        }
    }

    /// No index after all: the mount is plain 9P.
    fn abandon(l: *Layer) Error!void {
        if (l.abandoning) return;
        l.abandoning = true;
        if (l.index) |*x| x.deinit(l.gpa);
        l.index = null;
        if (!l.root_clone_pending) if (l.privroot) |pr| try l.clunkPrivate(pr);
        return l.finishBootstrap(.passthrough);
    }

    fn finishBootstrap(l: *Layer, to: Phase) Error!void {
        l.phase = to;
        if (l.held_attach) |h| {
            l.held_attach = null;
            defer l.gpa.free(h);
            try l.out_mount.appendSlice(l.gpa, h);
        }
        const d = l.deferred;
        l.deferred = .empty;
        defer {
            var dd = d;
            dd.deinit(l.gpa);
        }
        var at: usize = 0;
        while (at < d.items.len) {
            const size = std.mem.readInt(u32, d.items[at..][0..4], .little);
            try l.request(d.items[at..][0..size]);
            at += size;
        }
    }

    fn note(l: *Layer, comptime fmt: []const u8, args: anytype) Error!void {
        var w: std.Io.Writer.Allocating = .fromArrayList(l.gpa, &l.notes);
        defer l.notes = w.toArrayList();
        w.writer.print(fmt ++ "\n", args) catch return error.OutOfMemory;
    }

    fn version(l: *const Layer) []const u8 {
        return l.idx_version[0..l.idx_version_len];
    }

    fn privateReply(l: *Layer, what: Priv, msg: p9.R) Error!void {
        switch (what) {
            .clunk => |fid| if (fid >= first_private_fid) try l.free_pfids.append(l.gpa, fid),
            .root_clone => {
                l.root_clone_pending = false;
                if (msg != .Rwalk) {
                    l.privroot = null;
                    try l.note("index: {s}: can't walk the root: {s}; ignored", .{ l.label, errText(msg) });
                    return l.abandon();
                }
                if (l.abandoning) return l.clunkPrivate(l.privroot.?);
                return l.maybeValidate();
            },
            .idx_walk => {
                const found = msg == .Rwalk and msg.Rwalk.wqids.n == 1;
                if (l.abandoning) return if (found) l.clunkPrivate(l.pidx);
                if (!found) return l.abandon();
                try l.privSend(.idx_stat, p9.Tstat{ .fid = l.pidx });
            },
            .idx_stat => {
                if (l.abandoning) return l.clunkPrivate(l.pidx);
                const st = statOf(msg) orelse {
                    try l.clunkPrivate(l.pidx);
                    try l.note("index: {s}: can't stat it: {s}; ignored", .{ l.label, errText(msg) });
                    return l.abandon();
                };
                if (st.length > ri.max_text) {
                    try l.clunkPrivate(l.pidx);
                    try l.note("index: {s} is larger than 256 MB; ignored", .{l.label});
                    return l.abandon();
                }
                l.idx_len = st.length;
                const v = std.fmt.bufPrint(&l.idx_version, "{x}.{d}.{d}.{d}", .{ st.qid_path, st.qid_vers, st.mtime, st.length }) catch unreachable;
                l.idx_version_len = v.len;
                if (l.cached()) |b| {
                    if (Index.init(b)) |x| {
                        l.index = x;
                        l.index.?.owned = true;
                        l.from_cache = true;
                        try l.clunkPrivate(l.pidx);
                        return l.indexReady();
                    } else |_| l.gpa.free(b);
                }
                try l.privSend(.idx_open, p9.Topen{ .fid = l.pidx, .mode = wire.OREAD });
            },
            .idx_open => {
                if (l.abandoning) return l.clunkPrivate(l.pidx);
                if (msg != .Ropen) {
                    try l.clunkPrivate(l.pidx);
                    try l.note("index: {s}: can't open it: {s}; ignored", .{ l.label, errText(msg) });
                    return l.abandon();
                }
                const io = msg.Ropen.iounit;
                l.idx_chunk = if (io > 0) @min(io, l.msize -| wire.io_header) else l.msize -| wire.io_header;
                if (l.idx_chunk == 0) l.idx_chunk = 8192;
                l.idx_buf = try l.gpa.alloc(u8, @intCast(l.idx_len));
                try l.readMore();
                if (l.idx_reads == 0) return l.indexRead();
            },
            .idx_read => |r| {
                l.idx_reads -= 1;
                if (l.abandoning) {
                    if (l.idx_reads == 0) try l.clunkPrivate(l.pidx);
                    return;
                }
                if (msg != .Rread) {
                    try l.note("index: {s}: can't read it: {s}; ignored", .{ l.label, errText(msg) });
                    try l.abandon();
                    if (l.idx_reads == 0) try l.clunkPrivate(l.pidx);
                    return;
                }
                const data = msg.Rread.data.bytes;
                const n = @min(data.len, r.count);
                if (n == 0) {
                    l.idx_eof = @min(l.idx_eof, r.off);
                } else {
                    @memcpy(l.idx_buf[@intCast(r.off)..][0..n], data[0..n]);
                    // A short read: ask for the rest.
                    if (n < r.count) try l.readAt(r.off + n, r.count - @as(u32, @intCast(n)));
                }
                try l.readMore();
                if (l.idx_reads == 0) return l.indexRead();
            },
            .val_walk => |v| return l.valWalked(v.slot, v.start, v.end, msg),
            .val_stat => |slot| return l.valStatted(slot, msg),
            .list_walk => {
                if (msg != .Rwalk) return l.listDone(false);
                try l.privSend(.list_open, p9.Topen{ .fid = l.list_pfid, .mode = wire.OREAD });
            },
            .list_open => {
                if (msg != .Ropen) {
                    try l.clunkPrivate(l.list_pfid);
                    l.list_pfid = 0;
                    return l.listDone(false);
                }
                try l.privSend(.{ .list_read = 0 }, p9.Tread{ .fid = l.list_pfid, .offset = 0, .count = l.msize -| wire.io_header });
            },
            .list_read => |off| {
                if (msg != .Rread) return l.listDone(false);
                const data = msg.Rread.data.bytes;
                if (data.len == 0) return l.listDone(l.listingMatches());
                try l.listing.appendSlice(l.gpa, data);
                if (l.listing.items.len > ri.max_text) return l.listDone(false);
                try l.privSend(.{ .list_read = off + data.len }, p9.Tread{ .fid = l.list_pfid, .offset = off + data.len, .count = l.msize -| wire.io_header });
            },
            .make_real => |m| {
                if (msg != .Rwalk) return l.makeRealFailed(m.tag, m.fid, errText(msg), m.start > 0);
                if (msg.Rwalk.wqids.n != m.end - m.start) return l.makeRealFailed(m.tag, m.fid, enonexist, m.start > 0);
                const f = l.fids.getPtr(m.fid) orelse return l.makeRealFailed(m.tag, m.fid, enonexist, true);
                if (m.end < l.ix().depth(f.node.?)) return l.makeReal(m.tag, m.fid, m.end);
                return l.madeReal(m.tag, m.fid);
            },
        }
    }

    fn cached(l: *Layer) ?[]u8 {
        const key = switch (l.source) {
            .server => |s| s.key,
            else => return null,
        };
        const lookup = l.hooks.lookup orelse return null;
        return lookup(l.hooks.ctx, key, l.version());
    }

    fn readAt(l: *Layer, off: u64, count: u32) Error!void {
        l.idx_reads += 1;
        try l.privSend(.{ .idx_read = .{ .off = off, .count = count } }, p9.Tread{ .fid = l.pidx, .offset = off, .count = count });
    }

    fn readMore(l: *Layer) Error!void {
        while (l.idx_reads < max_reads and l.idx_next < @min(l.idx_len, l.idx_eof)) {
            const n: u32 = @intCast(@min(@as(u64, l.idx_chunk), l.idx_len - l.idx_next));
            try l.readAt(l.idx_next, n);
            l.idx_next += n;
        }
    }

    /// Every read of /.h9index is back: compile it.
    fn indexRead(l: *Layer) Error!void {
        try l.clunkPrivate(l.pidx);
        const text = l.idx_buf[0..@intCast(@min(l.idx_len, l.idx_eof))];
        var diag: ri.Diag = .{};
        const compiled = ri.compile(l.gpa, text, &diag) catch |e| {
            switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.UnknownVersion => try l.note("index: {s}: unknown format version; ignored", .{l.label}),
                error.TooBig => try l.note("index: {s} is larger than 256 MB; ignored", .{l.label}),
                error.BadIndex => try l.note("index: {s}: line {d}: {s}; ignored", .{ l.label, diag.line, diag.msg }),
            }
            return l.abandon();
        };
        l.gpa.free(l.idx_buf);
        l.idx_buf = &.{};
        l.index = Index.init(compiled) catch {
            l.gpa.free(compiled);
            return l.abandon();
        };
        l.index.?.owned = true;
        if (l.hooks.store) |store| store(l.hooks.ctx, l.source.server.key, l.version(), compiled);
        return l.indexReady();
    }

    fn indexReady(l: *Layer) Error!void {
        const n = l.ix().n;
        try l.demoted.resize(l.gpa, n, false);
        try l.stale_stat.resize(l.gpa, n, false);
        try l.fids.put(l.gpa, l.attach_fid, .{ .real = true, .node = ri.root });
        return l.maybeValidate();
    }

    /// Starts validating once both the root's clone and the index are in.
    fn maybeValidate(l: *Layer) Error!void {
        if (l.root_clone_pending or l.index == null or l.phase != .bootstrap or l.slots.items.len > 0) return;
        const x = l.ix();
        for (0..x.n) |i| {
            const e: u32 = @intCast(i);
            if (x.isDir(e) and !x.unindexed(e)) try l.slots.append(l.gpa, .{ .entry = e });
        }
        if (l.slots.items.len == 0) return l.validated();
        try l.validateMore();
    }

    fn validateMore(l: *Layer) Error!void {
        while (l.validating < max_validating and l.slot_next < l.slots.items.len) {
            const s: u32 = @intCast(l.slot_next);
            l.slot_next += 1;
            l.validating += 1;
            const e = l.slots.items[s].entry;
            if (e == ri.root) {
                try l.privSend(.{ .val_stat = s }, p9.Tstat{ .fid = l.privroot.? });
                continue;
            }
            const pf = l.allocPfid();
            l.slots.items[s].pfid = pf;
            try l.valWalk(s, 0);
        }
    }

    fn valWalk(l: *Layer, s: u32, done: usize) Error!void {
        const slot = l.slots.items[s];
        var buf: [ri.max_depth][]const u8 = undefined;
        const names = l.ix().pathNames(slot.entry, &buf) orelse {
            l.demote(slot.entry);
            return l.valDone(s, done > 0);
        };
        const end = @min(names.len, done + wire.max_welem);
        const from = if (done == 0) l.privroot.? else slot.pfid.?;
        try l.privSend(.{ .val_walk = .{ .slot = s, .start = done, .end = end } }, p9.Twalk{ .fid = from, .newfid = slot.pfid.?, .wnames = .init(names[done..end]) });
    }

    fn valWalked(l: *Layer, s: u32, start: usize, end: usize, msg: p9.R) Error!void {
        const slot = l.slots.items[s];
        if (msg != .Rwalk or msg.Rwalk.wqids.n != end - start) {
            l.demote(slot.entry);
            return l.valDone(s, start > 0);
        }
        if (end < l.ix().depth(slot.entry)) return l.valWalk(s, end);
        try l.privSend(.{ .val_stat = s }, p9.Tstat{ .fid = slot.pfid.? });
    }

    fn valStatted(l: *Layer, s: u32, msg: p9.R) Error!void {
        const slot = l.slots.items[s];
        const x = l.ix();
        const e = slot.entry;
        const q = x.qid(e);
        const same = if (statOf(msg)) |st| st.qid_path == q.path and st.qid_vers == q.vers and st.mtime == x.mtime(e) and st.qid_type & wire.QTDIR != 0 else false;
        if (!same) {
            if (e == ri.root and statOf(msg) != null and statOf(msg).?.qid_path == q.path) {
                // Writing /.h9index changes the root's own mtime, so the
                // root is checked by its listing instead.
                l.validating -= 1;
                try l.listRoot();
                return l.validateMore();
            }
            l.demote(e);
        }
        return l.valDone(s, slot.pfid != null);
    }

    fn valDone(l: *Layer, s: u32, clunk: bool) Error!void {
        const slot = &l.slots.items[s];
        if (slot.pfid) |pf| {
            if (clunk) try l.clunkPrivate(pf) else try l.free_pfids.append(l.gpa, pf);
            slot.pfid = null;
        }
        l.checked += 1;
        l.validating -= 1;
        try l.validateMore();
        if (l.validating == 0 and l.slot_next == l.slots.items.len and !l.list_pending) return l.validated();
    }

    fn listRoot(l: *Layer) Error!void {
        l.list_pending = true;
        l.list_pfid = l.allocPfid();
        try l.privSend(.list_walk, p9.Twalk{ .fid = l.privroot.?, .newfid = l.list_pfid, .wnames = .init(&.{}) });
    }

    /// Whether the root's listing, read from the server, is the index's:
    /// the same names (but the index itself), with the same qid.paths.
    fn listingMatches(l: *Layer) bool {
        const x = l.ix();
        var b = l.listing.items;
        var n: u32 = 0;
        while (b.len > 0) {
            const d, const size = attr.Dir.parse(b) orelse return false;
            b = b[size..];
            if (std.mem.eql(u8, d.name, ri.file_name)) continue;
            const e = x.lookup(ri.root, d.name) orelse return false;
            if (x.qid(e).path != d.qid_path) return false;
            if (x.qid(e).vers != d.qid_vers or x.mtime(e) != d.mtime) l.demote(e);
            n += 1;
        }
        var want = x.children(ri.root).count;
        if (x.lookup(ri.root, ri.file_name) != null) want -= 1;
        return n == want;
    }

    fn listDone(l: *Layer, ok: bool) Error!void {
        if (l.list_pfid != 0) try l.clunkPrivate(l.list_pfid);
        l.list_pfid = 0;
        l.listing.clearAndFree(l.gpa);
        if (ok) l.stale_stat.set(ri.root) else l.demote(ri.root);
        l.list_pending = false;
        l.checked += 1;
        if (l.validating == 0 and l.slot_next == l.slots.items.len) return l.validated();
    }

    fn validated(l: *Layer) Error!void {
        if (l.phase != .bootstrap) return;
        if (l.hooks.now_ns) |now| l.t_ms = (now() -| l.t_start) / std.time.ns_per_ms;
        const x = l.ix();
        try l.note("index: {s}: {d} entries, {d} dirs{s}; checked {d} dirs in {d} ms, {d} demoted", .{ l.label, x.n, x.ndirs, if (l.from_cache) " (cached)" else "", l.checked, l.t_ms, l.ndemoted });
        if (l.checked > 0 and l.ndemoted * 4 > l.checked) {
            if (l.source == .server)
                try l.note("index: {s} looks stale; rebuild it with mkindex", .{l.label})
            else
                try l.note("index: {s} looks stale", .{l.label});
        }
        return l.finishBootstrap(.serving);
    }

    /// What `#ι`'s status file reads: the index and what it's done.
    pub fn status(l: *const Layer, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (l.phase) {
            .failed => try w.print("failed {s}\n", .{l.err orelse ""}),
            .attach, .bootstrap => try w.writeAll("starting\n"),
            .passthrough => try w.writeAll("index none\n"),
            .serving => {
                const x = l.ix();
                try w.print("index {s} entries {d} dirs {d} checked {d} demoted {d} ms {d}{s}\n", .{ l.label, x.n, x.ndirs, l.checked, l.ndemoted, l.t_ms, if (l.from_cache) " cached" else "" });
            },
        }
        try w.print("requests {d} sent {d} bootstrap {d}\n", .{ l.from_mount_t, l.to_server_t, l.boot_t });
        try w.writeAll(l.notes.items);
    }
};

fn statOf(msg: p9.R) ?attr.Dir {
    if (msg != .Rstat) return null;
    const d, _ = attr.Dir.parse(msg.Rstat.stat.bytes) orelse return null;
    return d;
}

fn errText(msg: p9.R) []const u8 {
    return if (msg == .Rerror) msg.Rerror.ename else "unexpected reply";
}

fn dupeNames(gpa: Allocator, names: []const []const u8) Allocator.Error![][]u8 {
    const out = try gpa.alloc([]u8, names.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |s| gpa.free(s);
        gpa.free(out);
    }
    for (names) |s| {
        out[n] = try gpa.dupe(u8, s);
        n += 1;
    }
    return out;
}

fn constNames(names: [][]u8) []const []const u8 {
    return @ptrCast(names);
}

fn freePending(gpa: Allocator, p: *Pending) void {
    for (p.names) |s| gpa.free(s);
    if (p.names.len > 0) gpa.free(p.names);
    if (p.frame) |f| gpa.free(f);
    if (p.aname) |a| gpa.free(a);
    p.names = &.{};
    p.frame = null;
    p.aname = null;
}

test {
    _ = @import("layer_test.zig");
}
