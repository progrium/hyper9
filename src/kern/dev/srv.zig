//! h9's devsrv.c (design/kernel-port.md), `#s`: the service registry
//! (design/epoch-0/devsrv.md), ported from 9front's port/devsrv.c at the
//! pinned release. A close translation: the same functions in the same
//! order, with error unions in place of C's error labels. A native device
//! (dev.zig's `Native`).
//!
//! A file server posts a channel by creating a name here and writing the
//! number of an open fd into it; opening the name returns another
//! reference to that channel. Opening clone makes a child board, whose
//! open fd is its lease: closing it closes the board and every service on
//! it. Boards nest, and #s/id1/id2 walks to one.
//!
//! Changes from 9front's:
//! - Each machine has its own root board (Srvmach, hung off Hmach), found
//!   through the calling process's Proc when attaching, so machines
//!   in one host process can't see each other's services. The lock, the
//!   path counter and the all-boards list are per machine too. A board
//!   is the root when it has no parent.
//! - The machine's services are closed by its last process, before it
//!   ends (h9_srvmachclose, from proc.c), as closing a lease does; the
//!   structures go with the machine (h9_srvmachfree).
//! - ccloseq is cclose: drawterm's cclose runs from any kernel thread.
//! - Posting is split from the fd: srvwrite turns the fd into a channel,
//!   and post does the rest, which h9_srvpost offers without a guest fd.
//!
//! srvgen can fail (its permission check on a walk), so it's an `Egen`.

const std = @import("std");
const port = @import("../port.zig");
const sync = @import("../sync.zig");
const dev = @import("../dev.zig");
const chan = @import("../chan.zig");
const sysfile = @import("../sysfile.zig");
const c = port.c;
const up = port.up;
const Error = port.Error;

const Chan = c.Chan;
const Dir = c.Dir;
const Dirtab = c.Dirtab;
const Walkqid = c.Walkqid;
const Qid = c.Qid;

fn SRVTYPE(x: u64) u64 {
    return @as(c_uint, @truncate(x)) & 0x3;
}
fn SRVPATH(x: u64) u64 {
    return x >> 2;
}
fn SRVQID(x: u64, t: u64) u64 {
    return (x << 2) | (t & 0x3);
}

const Link = extern struct {
    link: ?*anyopaque = null,
    name: ?[*:0]u8 = null,
    owner: ?[*:0]u8 = null,
    perm: c_uint = 0,
    path: c_uint = 0,
};

const Srv = extern struct {
    l: Link = .{}, // first, so a Srv is a Link
    chan: ?*Chan = null,
};

const Board = extern struct {
    l: Link = .{}, // first, so a Board is a Link
    ref: c.Ref = std.mem.zeroes(c.Ref),

    closed: c_int = 0,
    srv: ?*Srv = null,
    sm: ?*Srvmach = null,

    // tree linkage
    parent: ?*Board = null, // nil for the machine's root
    child: ?*Board = null,

    // all boards list
    prev: ?*Board = null,
    next: ?*Board = null,
};

/// One machine's registry.
const Srvmach = extern struct {
    lk: c.RWLock,
    path: c_uint,
    root: Board,
};

const Qsrv = 0;
const Qclone = 1;
const Qlease = 2;

/// drawterm's ulong is 32 bits, so not 9front's ~0UL
const Nopath: c_uint = ~@as(c_uint, 0);

const clone = "clone";

fn isroot(b: *Board) bool {
    return b.parent == null;
}

fn lookup(comptime T: type, l: ?*T, name: ?[*:0]const u8, qidpath_: u64) ?*T {
    var qidpath = qidpath_;
    if (qidpath != Nopath) {
        port.assert(SRVTYPE(qidpath) == Qsrv);
        qidpath = SRVPATH(qidpath);
    }
    var lp: ?*Link = @ptrCast(l);
    while (lp) |p| : (lp = @ptrCast(@alignCast(p.link))) {
        if (qidpath != Nopath and p.path == qidpath)
            return @ptrCast(p);
        if (name) |n| if (dev.streq(p.name.?, n))
            return @ptrCast(p);
    }
    return null;
}

fn linkremove(comptime T: type, l: *?*T, name: ?[*:0]const u8, qidpath_: u64) ?*T {
    var qidpath = qidpath_;
    if (qidpath != Nopath) {
        port.assert(SRVTYPE(qidpath) == Qsrv);
        qidpath = SRVPATH(qidpath);
    }
    var last: *?*anyopaque = @ptrCast(l);
    var lp: ?*Link = @ptrCast(l.*);
    while (lp) |p| : (lp = @ptrCast(@alignCast(p.link))) {
        if (qidpath != Nopath and p.path == qidpath)
            break;
        if (name) |n| if (dev.streq(p.name.?, n))
            break;
        last = &p.link;
    }
    const p = lp orelse return null;

    last.* = p.link;
    p.link = null;
    return @ptrCast(p);
}

fn freelink(l: *Link) void {
    c.free(l.name);
    c.free(l.owner);
    c.free(l);
}

/// always called with b->sm->lk wlock'ed
fn boardclunk(b_: *Board) void {
    var b = b_;
    // the root is not ref-counted nor clunkable
    if (isroot(b))
        return;

    if (chan.decref(&b.ref) != 0)
        return;

    // All boards must be walkable from root. So a board is allowed to
    // sit at zero references as long as it still has active children.
    // For leaf nodes we then have to walk up the tree to clear now empty
    // parents.
    while (b.closed != 0 and b.child == null) {
        port.assert(b.srv == null);
        port.assert(b.parent != null);

        // unlink from parent board
        const ch = linkremove(Board, &b.parent.?.child, b.l.name, Nopath).?;
        port.assert(ch == b);

        // unlink from all boards list
        ch.prev.?.next = ch.next;
        ch.next.?.prev = ch.prev;

        b = ch.parent.?;
        freelink(&ch.l);
    }
}

/// The calling process's machine's registry, made on first use. Errors
/// if the caller isn't an h9 process.
fn machsrv() Error!*Srvmach {
    const m: *c.Hmach = (try port.uphproc()).mach;
    c.lock(&m.lk);
    defer c.unlock(&m.lk);
    if (m.srv) |sm| return @ptrCast(@alignCast(sm));
    const sm: *Srvmach = @ptrCast(@alignCast(c.mallocz(@sizeOf(Srvmach), 1) orelse
        return port.kerror(&port.Enomem)));
    sm.root.next = &sm.root;
    sm.root.prev = &sm.root;
    sm.root.sm = sm;
    sm.root.l.path = sm.path;
    sm.path +%= 1;
    sm.root.l.perm = 0o777;
    sm.root.l.name = c.strdup("#s");
    sm.root.l.owner = c.strdup(c.eve);
    if (sm.root.l.name == null or sm.root.l.owner == null) {
        c.free(sm.root.l.name);
        c.free(sm.root.l.owner);
        c.free(sm);
        return port.kerror(&port.Enomem);
    }
    m.srv = sm;
    return sm;
}

fn boardof(ch: *Chan) *Board {
    return @ptrCast(@alignCast(dev.aux(ch).*.?));
}

fn genbuf() [*]u8 {
    return @ptrCast(&up().genbuf);
}

fn srvgen(ch: *Chan, name: ?[*:0]const u8, tab: ?[*]Dirtab, ntab: c_int, s_: c_int, dp: *Dir) Error!c_int {
    _ = .{ tab, ntab };
    var s = s_;
    if (name) |n| if (std.mem.len(n) >= @sizeOf(@TypeOf(up().genbuf)))
        return -1;

    const b = boardof(ch);
    const sm = b.sm.?;
    var sp: ?*Srv = null;
    var child: ?*Board = null;
    var q: Qid = undefined;
    dev.mkqid(&q, ~@as(i64, 0), 0, c.QTFILE);
    sync.rlock(&sm.lk);
    defer sync.runlock(&sm.lk);

    var clonegen = false;
    if (s == -2) { // dot
        child = b;
    } else if (s == c.DEVDOTDOT) {
        child = b.parent orelse &sm.root;
    } else if (name) |n| {
        if (dev.streq(n, clone)) {
            clonegen = true;
        } else {
            sp = lookup(Srv, b.srv, n, Nopath);
            if (sp == null)
                child = lookup(Board, b.child, n, Nopath);
        }
    } else {
        if (s == 0) {
            clonegen = true;
        } else {
            s -= 1;
            sp = b.srv;
            while (sp != null and s > 0) : (sp = @ptrCast(@alignCast(sp.?.l.link)))
                s -= 1;
            child = b.child;
            while (child != null and s > 0) : (child = @ptrCast(@alignCast(child.?.l.link)))
                s -= 1;
        }
    }
    if (clonegen) {
        q.path = SRVQID(SRVPATH(ch.qid.path), Qclone);
        dev.devdir(ch, q, @constCast(clone), 0, c.eve, 0o444, dp);
    } else if (sp) |p| {
        chan.kstrcpy(genbuf(), p.l.name.?, @sizeOf(@TypeOf(up().genbuf)));
        q.path = SRVQID(p.l.path, Qsrv);
        dev.devdir(ch, q, genbuf(), 0, p.l.owner, @bitCast(p.l.perm), dp);
    } else if (child) |b2| {
        if (name != null or s_ == c.DEVDOTDOT) {
            try dev.devpermcheck(b2.l.owner.?, b2.l.perm, c.OEXEC);
            dev.aux(ch).* = b2;
        }
        chan.kstrcpy(genbuf(), b2.l.name.?, @sizeOf(@TypeOf(up().genbuf)));
        q.path = SRVQID(b2.l.path, Qsrv);
        q.type = c.QTDIR;
        dev.devdir(ch, q, genbuf(), 0, b2.l.owner, @bitCast(b2.l.perm | c.DMDIR), dp);
    } else return -1;
    return 1;
}

const srvgenE = dev.egen(srvgen);

fn srvattach(spec: [*:0]const u8) Error!*Chan {
    const sm = try machsrv();
    const ch = dev.devattach('s', spec);
    dev.aux(ch).* = &sm.root;
    return ch;
}

fn srvwalk(ch: *Chan, nc: ?*Chan, name: [*]const [*:0]const u8, nname: c_int) Error!?*Walkqid {
    const wq = (try dev.devwalk(ch, nc, name, nname, null, 0, srvgenE.c)) orelse return null;
    const cl: *Chan = wq.libclone orelse return wq;

    const b = boardof(cl);
    if (isroot(b))
        return wq;

    _ = chan.incref(&b.ref);
    return wq;
}

fn srvstat(ch: *Chan, db: [*]u8, n_: c_int) Error!c_int {
    var d: Dir = undefined;

    // devstat cheats for dir stats, we care about our dir perms
    if (ch.qid.type == c.QTDIR) {
        _ = try srvgen(ch, null, null, 0, -2, &d);
        const n = c.convD2M(&d, db, @intCast(n_));
        if (n == 0)
            return port.kerror(&port.Ebadarg);
        return @intCast(n);
    }

    return dev.devstat(ch, db, n_, null, 0, srvgenE.c);
}

fn srvopen(ch: *Chan, omode: c_int) Error!*Chan {
    if (omode & c.OTRUNC != 0)
        return port.kerror(&port.Eexist);
    if (omode & c.ORCLOSE != 0)
        return port.kerror(&port.Eperm);
    const mode = try sysfile.openmode(@bitCast(omode));

    const b = boardof(ch);
    const sm = b.sm.?;
    if (SRVTYPE(ch.qid.path) == Qclone) {
        sync.wlock(&sm.lk);
        defer sync.wunlock(&sm.lk);
        if (b.closed != 0)
            return port.kerror(&port.Eshutdown);
        const nb: *Board = @ptrCast(@alignCast(c.smalloc(@sizeOf(Board))));
        nb.ref.ref = 1;
        nb.l.perm = 0o770;
        nb.sm = sm;
        var buf: [64]u8 = undefined;
        while (true) {
            nb.l.path = sm.path;
            sm.path +%= 1;
            _ = std.mem.printSentinel(&buf, "{d}", .{@as(c_int, @bitCast(nb.l.path))}, 0) catch unreachable;
            if (lookup(Srv, b.srv, @ptrCast(&buf), Nopath) == null) break;
        }
        chan.kstrdup(&nb.l.name, @ptrCast(&buf));
        chan.kstrdup(&nb.l.owner, @ptrCast(&up().user));

        // link to all boards list
        nb.next = &sm.root;
        nb.prev = sm.root.prev;
        nb.next.?.prev = nb;
        nb.prev.?.next = nb;

        // link to parent board
        nb.parent = b;
        nb.l.link = b.child;
        b.child = nb;

        dev.aux(ch).* = nb;
        ch.qid.path = SRVQID(nb.l.path, Qlease);
        ch.mode = @intCast(mode);
        boardclunk(b);
        return ch;
    }

    const nc = blk: {
        sync.rlock(&sm.lk);
        defer sync.runlock(&sm.lk);
        if (ch.qid.type == c.QTDIR) {
            if (omode != c.OREAD)
                return port.kerror(&port.Eisdir);
            try dev.devpermcheck(b.l.owner.?, b.l.perm, omode);
            ch.mode = @intCast(mode);
            ch.flag |= c.COPEN;
            ch.offset = 0;
            return ch;
        }
        if (b.closed != 0)
            return port.kerror(&port.Eshutdown);

        const sp = lookup(Srv, b.srv, null, ch.qid.path) orelse
            return port.kerror(&port.Eshutdown);
        const nc = sp.chan orelse return port.kerror(&port.Eshutdown);
        if (mode != nc.mode and nc.mode != c.ORDWR)
            return port.kerror(&port.Eperm);
        try dev.devpermcheck(sp.l.owner.?, sp.l.perm, omode);

        _ = chan.incref(&nc.ref);
        break :blk nc;
    };

    chan.cclose(ch);
    return nc;
}

fn srvcreate(ch: *Chan, name: [*:0]const u8, omode: c_int, perm: c_uint) Error!*Chan {
    if (try sysfile.openmode(@bitCast(omode)) != c.OWRITE)
        return port.kerror(&port.Eperm);

    if (std.mem.len(name) >= @sizeOf(@TypeOf(up().genbuf)))
        return port.kerror(&port.Etoolong);

    if (dev.streq(name, clone))
        return port.kerror(&port.Eexist);

    const sp: *Srv = @ptrCast(@alignCast(c.smalloc(@sizeOf(Srv))));
    chan.kstrdup(&sp.l.name, name);
    chan.kstrdup(&sp.l.owner, @ptrCast(&up().user));

    const b = boardof(ch);
    const sm = b.sm.?;
    sync.wlock(&sm.lk);
    {
        errdefer {
            sync.wunlock(&sm.lk);
            freelink(&sp.l);
        }
        if (b.closed != 0)
            return port.kerror(&port.Eshutdown);
        try dev.devpermcheck(b.l.owner.?, b.l.perm, c.OWRITE);
        if (lookup(Srv, b.srv, name, Nopath) != null)
            return port.kerror(&port.Eexist);
        if (lookup(Board, b.child, name, Nopath) != null)
            return port.kerror(&port.Eexist);
    }

    sp.l.perm = perm & 0o777;
    sp.l.path = sm.path;
    sm.path +%= 1;

    ch.qid.path = SRVQID(sp.l.path, Qsrv);
    ch.qid.type = c.QTFILE;

    sp.l.link = b.srv;
    b.srv = sp;

    sync.wunlock(&sm.lk);

    ch.flag |= c.COPEN;
    ch.mode = c.OWRITE;

    return ch;
}

fn srvremove(ch: *Chan) Error!void {
    const b = boardof(ch);
    const sm = b.sm.?;
    const sp = blk: {
        sync.wlock(&sm.lk);
        defer sync.wunlock(&sm.lk);
        errdefer boardclunk(b);
        if (ch.qid.type == c.QTDIR)
            return port.kerror(&port.Eperm);
        switch (SRVTYPE(ch.qid.path)) {
            Qlease, Qclone => return port.kerror(&port.Eperm),
            else => {},
        }

        const sp = lookup(Srv, b.srv, null, ch.qid.path) orelse
            return port.kerror(&port.Enonexist);

        if (!dev.streq(sp.l.owner.?, @ptrCast(&up().user)) and c.iseve() == 0)
            return port.kerror(&port.Eperm);

        _ = linkremove(Srv, &b.srv, null, ch.qid.path);

        boardclunk(b);
        break :blk sp;
    };

    if (sp.chan) |sc|
        chan.cclose(sc);
    freelink(&sp.l);
}

fn srvwstat(ch: *Chan, dp: [*]u8, n_: c_int) Error!c_int {
    switch (SRVTYPE(ch.qid.path)) {
        Qlease, Qclone => return port.kerror(&port.Eperm),
        else => {},
    }
    const b = boardof(ch);
    const sm = b.sm.?;
    if (ch.qid.type == c.QTDIR and isroot(b))
        return port.kerror(&port.Eperm);

    const strs: [*]u8 = @ptrCast(c.smalloc(@intCast(n_)));
    defer c.free(strs);
    var d: Dir = undefined;
    const n = c.convM2D(dp, @intCast(n_), &d, @ptrCast(strs));
    if (n == 0)
        return port.kerror(&port.Eshortstat);

    sync.wlock(&sm.lk);
    defer sync.wunlock(&sm.lk);
    if (b.closed != 0)
        return port.kerror(&port.Eshutdown);

    const lp: *Link = if (ch.qid.type == c.QTDIR)
        &b.l
    else
        @ptrCast(lookup(Srv, b.srv, null, ch.qid.path) orelse return port.kerror(&port.Enonexist));

    if (!dev.streq(lp.owner.?, @ptrCast(&up().user)) and c.iseve() == 0)
        return port.kerror(&port.Eperm);

    if (@as(?[*:0]u8, d.name)) |dn| if (dn[0] != 0 and !dev.streq(lp.name.?, dn)) {
        if (std.mem.indexOfScalar(u8, std.mem.span(dn), '/') != null)
            return port.kerror(&port.Ebadchar);
        if (std.mem.len(dn) >= @sizeOf(@TypeOf(up().genbuf)))
            return port.kerror(&port.Etoolong);

        // Ensure new name doesn't conflict with old names
        if (dev.streq(dn, clone))
            return port.kerror(&port.Eexist);
        const s = if (ch.qid.type == c.QTDIR) b.parent.? else b;
        if (lookup(Srv, s.srv, dn, Nopath) != null)
            return port.kerror(&port.Eexist);
        if (lookup(Board, s.child, dn, Nopath) != null)
            return port.kerror(&port.Eexist);
        chan.kstrdup(&lp.name, dn);
    };
    if (@as(?[*:0]u8, d.uid)) |u| if (u[0] != 0)
        chan.kstrdup(&lp.owner, u);
    if (d.mode != Nopath)
        lp.perm = d.mode & 0o777;

    return @intCast(n);
}

fn srvclose(ch: *Chan) Error!void {
    if ((ch.flag & c.CRCLOSE) != 0 and SRVTYPE(ch.qid.path) != Qlease) {
        // in theory we need to override any changes in removability
        // since open, but since all that's checked is the owner, which
        // is immutable, all is well.
        srvremove(ch) catch {};
        return;
    }

    const b = boardof(ch);
    if (isroot(b))
        return;
    const sm = b.sm.?;

    sync.wlock(&sm.lk);
    if (SRVTYPE(ch.qid.path) != Qlease) {
        boardclunk(b);
        sync.wunlock(&sm.lk);
        return;
    }

    // free later after releasing the lock
    var sp = b.srv;
    b.srv = null;
    b.closed += 1;
    boardclunk(b);
    sync.wunlock(&sm.lk);

    while (sp) |p| {
        sp = @ptrCast(@alignCast(p.l.link));
        if (p.chan) |pc|
            chan.cclose(pc);
        freelink(&p.l);
    }
}

fn srvread(ch: *Chan, va: ?*anyopaque, n: c_int, off: i64) Error!c_int {
    if (SRVTYPE(ch.qid.path) == Qlease) {
        const b = boardof(ch);
        const sm = b.sm.?;
        sync.rlock(&sm.lk);
        defer sync.runlock(&sm.lk);
        return c.readstr(@truncate(@as(u64, @bitCast(off))), @ptrCast(va), @bitCast(n), b.l.name);
    }
    try chan.isdir(ch);
    return dev.devdirread(ch, @ptrCast(va.?), n, null, 0, srvgenE.c);
}

/// The rest of 9front's srvwrite after fdtochan: holds c1 in the entry,
/// found by name or by qid path as lookup does. Consumes the reference
/// to c1, even on error.
fn post(b: *Board, name: ?[*:0]const u8, qidpath: u64, c1: *Chan, srvname: ?[*:0]const u8) Error!void {
    errdefer chan.cclose(c1);
    const sm = b.sm.?;
    sync.wlock(&sm.lk);
    defer sync.wunlock(&sm.lk);
    if (b.closed != 0)
        return port.kerror(&port.Eshutdown);
    if (c1.qid.type & c.QTAUTH != 0)
        return port.kerror("cannot post auth file in srv");
    const sp = lookup(Srv, b.srv, name, qidpath) orelse
        return port.kerror(&port.Enonexist);

    if (sp.chan != null)
        return port.kerror(&port.Ebadusefd);

    sp.chan = c1;

    if (c1.srvname == null) if (srvname) |s|
        chan.kstrdup(@ptrCast(&c1.srvname), s);
}

fn srvwrite(ch: *Chan, va: ?*const anyopaque, n: c_int, off: i64) Error!c_int {
    _ = off;
    if (SRVTYPE(ch.qid.path) == Qlease)
        return port.kerror(&port.Eperm);

    var buf: [32]u8 = undefined;
    if (n >= buf.len)
        return port.kerror(&port.Etoobig);
    const src: [*]const u8 = @ptrCast(va.?);
    @memcpy(buf[0..@intCast(n)], src[0..@intCast(n)]); // so we can NUL-terminate
    buf[@intCast(n)] = 0;
    const fd: c_int = @bitCast(@as(c_uint, @truncate(c.strtoul(@ptrCast(&buf), null, 0))));

    const c1 = try sysfile.fdtochan(fd, -1, false, true); // error check and inc ref
    try post(boardof(ch), null, ch.qid.path, c1, if (@as(?*c.Path, ch.path)) |p| p.s else null);
    return n;
}

/// Posts c as name on board b (a #s chan's aux) without a guest fd, as
/// a write of an fd into a created entry does. Makes the entry, owned by
/// the caller with mode perm, if it doesn't exist. Takes over the
/// caller's reference to c, even on error.
pub fn srvpost(v: *anyopaque, name: [*:0]const u8, ch: *Chan, perm: c_uint) Error!void {
    const b: *Board = @ptrCast(@alignCast(v));
    const sm = b.sm.?;
    const srvname = blk: {
        errdefer chan.cclose(ch);
        if (std.mem.len(name) >= @sizeOf(@TypeOf(up().genbuf)))
            return port.kerror(&port.Etoolong);
        if (dev.streq(name, clone) or std.mem.indexOfScalar(u8, std.mem.span(name), '/') != null)
            return port.kerror(&port.Ebadchar);
        const srvname: [*:0]u8 = c.smprint(@constCast("/srv/%s"), name) orelse
            return port.kerror(&port.Enomem);
        const sp: *Srv = @ptrCast(@alignCast(c.smalloc(@sizeOf(Srv))));
        chan.kstrdup(&sp.l.name, name);
        chan.kstrdup(&sp.l.owner, @ptrCast(&up().user));
        sp.l.perm = perm & 0o777;

        sync.wlock(&sm.lk);
        var err: ?[*:0]const u8 = null;
        if (b.closed != 0)
            err = &port.Eshutdown
        else if (lookup(Board, b.child, name, Nopath) != null or
            lookup(Srv, b.srv, name, Nopath) != null)
            err = &port.Eexist;
        if (err) |e| {
            sync.wunlock(&sm.lk);
            freelink(&sp.l);
            c.free(srvname);
            return port.kerror(e);
        }
        sp.l.path = sm.path;
        sm.path +%= 1;
        sp.l.link = b.srv;
        b.srv = sp;
        sync.wunlock(&sm.lk);
        break :blk srvname;
    };

    defer c.free(srvname);
    try post(b, name, Nopath, ch, srvname);
}

/// Closes every service posted in machine m's registry and every board,
/// as closing each lease would. Called by the machine's last process
/// before it ends (proc.c), so that what the channels hold goes while
/// the machine is still there. Nothing can attach afterwards.
pub fn h9_srvmachclose(m: *c.Hmach) callconv(.c) void {
    c.lock(&m.lk);
    const smp = m.srv;
    c.unlock(&m.lk);
    const sm: *Srvmach = @ptrCast(@alignCast(smp orelse return));

    var list: ?*Srv = null;
    sync.wlock(&sm.lk);
    var b: *Board = &sm.root;
    while (true) {
        b.closed += 1;
        while (b.srv) |sp| {
            b.srv = @ptrCast(@alignCast(sp.l.link));
            sp.l.link = list;
            list = sp;
        }
        b = b.next.?;
        if (b == &sm.root) break;
    }
    sync.wunlock(&sm.lk);

    var sp = list;
    while (sp) |p| {
        sp = @ptrCast(@alignCast(p.l.link));
        if (p.chan) |pc|
            chan.cclose(pc);
        freelink(&p.l);
    }
}

/// Frees machine m's registry when the machine goes (proc.c), after
/// h9_srvmachclose. No chan on it is left: every one was in a process's
/// groups or posted on a board.
pub fn h9_srvmachfree(m: *c.Hmach) callconv(.c) void {
    const sm: *Srvmach = @ptrCast(@alignCast(m.srv orelse return));
    m.srv = null;
    var b = sm.root.next.?;
    while (b != &sm.root) {
        const next = b.next.?;
        c.free(b.l.name);
        c.free(b.l.owner);
        c.free(b);
        b = next;
    }
    c.free(sm.root.l.name);
    c.free(sm.root.l.owner);
    c.free(sm);
}

fn c_h9_srvpost(v: *anyopaque, name: [*:0]const u8, ch: *Chan, perm: c_uint) callconv(.c) void {
    srvpost(v, name, ch, perm) catch |e| port.raise(e);
}

pub const Device = dev.Native('s', "srv", .{
    .attach = srvattach,
    .walk = srvwalk,
    .stat = srvstat,
    .open = srvopen,
    .create = srvcreate,
    .close = srvclose,
    .read = srvread,
    .write = srvwrite,
    .remove = srvremove,
    .wstat = srvwstat,
    .egens = &.{srvgenE},
});

pub fn exportC() void {
    @export(&Device.dev, .{ .name = "srvdevtab" });
    @export(&c_h9_srvpost, .{ .name = "h9_srvpost" });
    @export(&h9_srvmachclose, .{ .name = "h9_srvmachclose" });
    @export(&h9_srvmachfree, .{ .name = "h9_srvmachfree" });
}

const testing = std.testing;
const kt = port.testing;

test "a posted channel opens as itself, names are unique, and a lease's close takes its services [kernel-port]" {
    const p = try kt.namespace();
    const m: *c.Hmach = @ptrCast(@alignCast(c.mallocz(@sizeOf(c.Hmach), 1).?));
    p.mach = m;
    defer {
        h9_srvmachclose(m);
        h9_srvmachfree(m);
        p.mach = null;
        c.free(m);
    }

    // Post a pipe's end as #s/a, and open it back.
    var fds: [2]c_int = undefined;
    _ = try sysfile.pipe(&fds);
    const sfd = try sysfile.create("#s/a", c.OWRITE, 0o666);
    var num: [16]u8 = undefined;
    const s = try std.fmt.bufPrint(&num, "{d}", .{fds[0]});
    try testing.expectEqual(@as(c_int, @intCast(s.len)), try sysfile.pwrite(sfd, s.ptr, @intCast(s.len), -1));
    // A second post to the entry is refused.
    try testing.expectError(error.Kernel, sysfile.pwrite(sfd, s.ptr, @intCast(s.len), -1));
    try testing.expectEqualStrings(std.mem.span(@as([*:0]const u8, &port.Ebadusefd)), kt.errstr());
    _ = try sysfile.close(sfd);
    const ofd = try sysfile.open("#s/a", c.ORDWR);
    const a = try sysfile.fdtochan(fds[0], -1, false, true);
    defer chan.cclose(a);
    const b = try sysfile.fdtochan(ofd, -1, false, true);
    defer chan.cclose(b);
    try testing.expectEqual(a, b);
    _ = try sysfile.close(ofd);

    // Names are unique, and clone is taken.
    try testing.expectError(error.Kernel, sysfile.create("#s/a", c.OWRITE, 0o666));
    try testing.expectError(error.Kernel, sysfile.create("#s/clone", c.OWRITE, 0o666));

    // A lease: a board whose services go when it's closed.
    const lfd = try sysfile.open("#s/clone", c.OREAD);
    var name: [32]u8 = undefined;
    const n = try sysfile.pread(lfd, &name, name.len, 0);
    var path: [64]u8 = undefined;
    const bp = try std.fmt.bufPrintSentinel(&path, "#s/{s}/b", .{name[0..@intCast(n)]}, 0);
    const bfd = try sysfile.create(bp.ptr, c.OWRITE, 0o666);
    _ = try sysfile.pwrite(bfd, s.ptr, @intCast(s.len), -1);
    _ = try sysfile.close(bfd);
    const b2 = try sysfile.open(bp.ptr, c.OREAD);
    _ = try sysfile.close(b2);
    _ = try sysfile.close(lfd);
    try testing.expectError(error.Kernel, sysfile.open(bp.ptr, c.OREAD));

    // srvpost makes an entry and posts without an fd.
    const root = try chan.namec("#s", c.Atodir, 0, 0);
    defer chan.cclose(root);
    _ = chan.incref(&a.ref);
    try srvpost(dev.aux(root).*.?, "c", a, 0o600);
    _ = chan.incref(&a.ref);
    try testing.expectError(error.Kernel, srvpost(dev.aux(root).*.?, "c", a, 0o600));
    try testing.expectEqualStrings(std.mem.span(@as([*:0]const u8, &port.Eexist)), kt.errstr());
    _ = try sysfile.close(fds[0]);
    _ = try sysfile.close(fds[1]);
}
