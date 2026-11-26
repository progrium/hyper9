//! drawterm's chan.c (design/kernel-port.md): channels, paths, the mount
//! table's heads, mounts, walks across mount points and through unions,
//! and namec. A close translation: the same functions in the same order,
//! with error unions in place of C's error labels, and h9's patches kept: the
//! #O overlay's lower directories in findmount, Linux symbolic links in
//! walkl (followlink), a Linux chroot's .. and #L in namec, and devfs's
//! anchored attach.
//!
//! namec is the one function here with a lot to undo on an error, and
//! keeps C's shape: each of C's error labels is a function whose caller
//! does what the C's error branch did.

const std = @import("std");
const port = @import("port.zig");
const sync = @import("sync.zig");
const dev = @import("dev.zig");
const pgrp = @import("pgrp.zig");
const c = port.c;
const up = port.up;
const Error = port.Error;

const Chan = c.Chan;
const Path = c.Path;
const Mhead = c.Mhead;
const Mount = c.Mount;
const Qid = c.Qid;
const Ref = c.Ref;
const Walkqid = c.Walkqid;

const PATHSLOP = 20;
const PATHMSLOP = 20;

const Chanalloc = struct {
    lk: c.Lock,
    fid: c_int,
    free: ?*Chan,
    list: ?*Chan,
};
var chanalloc: Chanalloc = std.mem.zeroes(Chanalloc);

const Elemlist = struct {
    aname: [*:0]const u8, // original name
    name: ?[*:0]u8 = null, // copy of name, so '/' can be overwritten
    nelems: c_int = 0,
    elems: ?[*][*:0]u8 = null,
    off: ?[*]c_int = null,
    mustbedir: bool = false,
    nerror: c_int = 0,
    prefix: c_int = 0,
};

pub fn chanpath(ch: ?*Chan) [*:0]const u8 {
    const cc = ch orelse return "<nil chan>";
    const p: *Path = cc.path orelse return "<nil path>";
    if (p.s == null)
        return "<nil path.s>";
    return p.s;
}

pub fn isdotdot(p: [*:0]const u8) bool {
    return p[0] == '.' and p[1] == '.' and p[2] == 0;
}

pub fn incref(r: *Ref) c_int {
    c.lock(&r.lk);
    r.ref += 1;
    const x = r.ref;
    c.unlock(&r.lk);
    return x;
}

pub fn decref(r: *Ref) c_int {
    return decrefAt(r, @returnAddress());
}

fn decrefAt(r: *Ref, pc: usize) c_int {
    c.lock(&r.lk);
    r.ref -= 1;
    const x = r.ref;
    c.unlock(&r.lk);
    if (x < 0)
        port.kpanic("decref, pc=0x%p", .{pc});
    return x;
}

/// Rather than strncpy, which zeros the rest of the buffer, kstrcpy
/// truncates if necessary, always zero terminates, does not zero fill,
/// and puts ... at the end of the string if it's too long. Usually used
/// to save a string in up->genbuf.
pub fn kstrcpy(s: [*]u8, t: [*:0]const u8, ns_: c_int) void {
    var ns = ns_;
    var nt: c_int = @intCast(std.mem.len(t));
    if (nt < ns) {
        std.mem.copyForwards(u8, s[0..@intCast(nt)], t[0..@intCast(nt)]);
        s[@intCast(nt)] = 0;
        return;
    }
    // too long, truncate
    nt = ns - 1;
    std.mem.copyForwards(u8, s[0..@intCast(nt)], t[0..@intCast(nt)]);
    s[@intCast(nt)] = 0;
    // append ... if there is space
    ns -= 4;
    if (ns < 0)
        return;
    // look for first byte of UTF-8 sequence by skipping continuation bytes
    while (ns > 0) {
        ns -= 1;
        if ((s[@intCast(ns)] & 0xC0) != 0x80) break;
    }
    @memcpy(s[@intCast(ns)..][0..4], "...\x00");
}

pub fn emptystr(s: ?[*:0]const u8) bool {
    const p = s orelse return true;
    return p[0] == 0;
}

/// Atomically replace *p with copy of s
pub fn kstrdup(p: *?[*:0]u8, s: [*:0]const u8) void {
    kstrdupAt(p, s, @returnAddress());
}

fn kstrdupAt(p: *?[*:0]u8, s: [*:0]const u8, pc: usize) void {
    const n = std.mem.len(s);
    // if it's a user, we can wait for memory; if not, something's very wrong
    const t: [*]u8 = if (c._getproc() != null)
        @ptrCast(c.smalloc(@intCast(n + 1)))
    else
        @ptrCast(port.malloc(@intCast(n + 1)) orelse port.kpanic("kstrdup: no memory", .{}));
    c.setmalloctag(t, pc);
    @memcpy(t[0..n], s[0..n]);
    t[n] = 0;
    const prev = p.*;
    p.* = @ptrCast(t);
    c.free(prev);
}

pub fn chandevreset() Error!void {
    var i: usize = 0;
    while (dev.table()[i]) |d| : (i += 1)
        try dev.reset(d);
}

pub fn chandevinit() Error!void {
    var i: usize = 0;
    while (dev.table()[i]) |d| : (i += 1)
        try dev.init(d);
}

pub fn chandevshutdown() Error!void {
    // shutdown in reverse order
    var i: usize = 0;
    while (dev.table()[i] != null) i += 1;
    while (i > 0) {
        i -= 1;
        try dev.shutdown(dev.table()[i].?);
    }
}

pub fn newchan() *Chan {
    c.lock(&chanalloc.lk);
    const ch: *Chan = if (chanalloc.free) |f| blk: {
        chanalloc.free = f.next;
        f.next = null;
        break :blk f;
    } else blk: {
        c.unlock(&chanalloc.lk);
        const n: *Chan = @ptrCast(@alignCast(c.smalloc(@sizeOf(Chan))));
        c.lock(&chanalloc.lk);
        n.link = chanalloc.list;
        chanalloc.list = n;
        break :blk n;
    };
    if (ch.fid == 0) {
        chanalloc.fid += 1;
        ch.fid = chanalloc.fid;
    }
    c.unlock(&chanalloc.lk);

    // if you get an error before associating with a dev, close calls
    // rootclose, a nop
    ch.type = 0;
    ch.flag = 0;
    ch.ref.ref = 1;
    ch.dev = 0;
    ch.offset = 0;
    ch.devoffset = 0;
    ch.iounit = 0;
    ch.umh = null;
    ch.umc = null;
    ch.uri = 0;
    ch.dri = 0;
    ch.dirrock = null;
    ch.nrock = 0;
    ch.mrock = 0;
    ch.ismtpt = 0;
    ch.mux = null;
    dev.aux(ch).* = null;
    ch.mchan = null;
    ch.mqid = std.mem.zeroes(Qid);
    ch.path = null;

    return ch;
}

pub fn newpath(s: [*:0]const u8) *Path {
    return newpathAt(s, @returnAddress());
}

fn newpathAt(s: [*:0]const u8, pc: usize) *Path {
    const p: *Path = @ptrCast(@alignCast(c.smalloc(@sizeOf(Path))));
    const i: c_int = @intCast(std.mem.len(s));
    p.len = i;
    p.alen = i + PATHSLOP;
    p.s = @ptrCast(c.smalloc(@intCast(p.alen)));
    @memcpy(p.s[0..@intCast(i + 1)], s[0..@intCast(i + 1)]);
    p.ref.ref = 1;

    // Cannot use newpath for arbitrary names because the mtpt array
    // will not be populated correctly. The names #/ and / are allowed,
    // but other names with / in them draw warnings.
    if (std.mem.indexOfScalar(u8, std.mem.span(s), '/') != null and !dev.streq(s, "#/") and !dev.streq(s, "/"))
        port.print("newpath: %s from %#p\n", .{ s, pc });

    p.mlen = 1;
    p.malen = PATHMSLOP;
    p.mtpt = @ptrCast(@alignCast(c.smalloc(@intCast(@as(usize, @intCast(p.malen)) * @sizeOf(?*Chan)))));
    return p;
}

fn copypath(p: *Path) *Path {
    const pp: *Path = @ptrCast(@alignCast(c.smalloc(@sizeOf(Path))));
    pp.ref.ref = 1;

    pp.len = p.len;
    pp.alen = p.alen;
    pp.s = @ptrCast(c.smalloc(@intCast(p.alen)));
    @memcpy(pp.s[0..@intCast(p.len + 1)], p.s[0..@intCast(p.len + 1)]);

    pp.mlen = p.mlen;
    pp.malen = p.malen;
    pp.mtpt = @ptrCast(@alignCast(c.smalloc(@intCast(@as(usize, @intCast(p.malen)) * @sizeOf(?*Chan)))));
    var i: usize = 0;
    while (i < pp.mlen) : (i += 1) {
        pp.mtpt[i] = p.mtpt[i];
        if (@as(?*Chan, pp.mtpt[i])) |m|
            _ = incref(&m.ref);
    }

    return pp;
}

pub fn pathclose(p_: ?*Path) void {
    const p = p_ orelse return;
    if (decref(&p.ref) != 0)
        return;
    var i: usize = 0;
    while (i < p.mlen) : (i += 1)
        if (@as(?*Chan, p.mtpt[i])) |m|
            cclose(m);
    c.free(@ptrCast(p.mtpt));
    c.free(p.s);
    c.free(p);
}

/// In place, rewrite name to compress multiple /, eliminate ., and
/// process .. (Really only called to remove a trailing .. that has been
/// added. Otherwise would need to update n->mtpt as well.)
fn fixdotdotname(p: *Path) void {
    if (p.s[0] == '#') {
        const r: [*c]u8 = c.strchr(p.s, '/');
        if (r == null)
            return;
        _ = c.cleanname(r);

        // The correct name is #i rather than #i/, but the correct name
        // of #/ is #/.
        if (dev.streq(r, "/") and p.s[1] != '/')
            r.* = 0;
    } else _ = c.cleanname(p.s);
    p.len = @intCast(std.mem.len(@as([*:0]u8, @ptrCast(p.s))));
}

fn uniquepath(p_: *Path) *Path {
    var p = p_;
    if (p.ref.ref > 1) {
        // copy on write
        const new = copypath(p);
        pathclose(p);
        p = new;
    }
    return p;
}

fn addelem(p_: *Path, s: [*:0]const u8, from: ?*Chan) *Path {
    if (s[0] == '.' and s[1] == 0)
        return p_;

    const p = uniquepath(p_);

    const i: c_int = @intCast(std.mem.len(s));
    var a = p.len + 1 + i + 1;
    if (a > p.alen) {
        a += PATHSLOP;
        const t: [*]u8 = @ptrCast(c.smalloc(@intCast(a)));
        @memcpy(t[0..@intCast(p.len + 1)], p.s[0..@intCast(p.len + 1)]);
        c.free(p.s);
        p.s = t;
        p.alen = a;
    }
    // don't insert extra slash if one is present
    if (p.len > 0 and p.s[@intCast(p.len - 1)] != '/' and s[0] != '/') {
        p.s[@intCast(p.len)] = '/';
        p.len += 1;
    }
    @memcpy(p.s[@intCast(p.len)..][0..@intCast(i + 1)], s[0..@intCast(i + 1)]);
    p.len += i;
    if (isdotdot(s)) {
        fixdotdotname(p);
        if (p.mlen > 1) {
            p.mlen -= 1;
            if (@as(?*Chan, p.mtpt[@intCast(p.mlen)])) |m| {
                p.mtpt[@intCast(p.mlen)] = null;
                cclose(m);
            }
        }
    } else {
        if (p.mlen >= p.malen) {
            p.malen = p.mlen + 1 + PATHMSLOP;
            const tt: [*][*c]Chan = @ptrCast(@alignCast(c.smalloc(@intCast(@as(usize, @intCast(p.malen)) * @sizeOf(?*Chan)))));
            @memcpy(tt[0..@intCast(p.mlen)], p.mtpt[0..@intCast(p.mlen)]);
            c.free(@ptrCast(p.mtpt));
            p.mtpt = tt;
        }
        p.mtpt[@intCast(p.mlen)] = from;
        p.mlen += 1;
        if (from) |f|
            _ = incref(&f.ref);
    }
    return p;
}

/// h9's, as 9front's Chan.srvname: the /srv name a channel was posted
/// as, which /proc/n/ns prints for a mount of it. drawterm's Chan has no
/// field for it, so it's kept beside the channel, and a flag bit beyond
/// drawterm's says a channel has one, so most frees don't look.
const CSRVNAME = 0x2000; // beside linux.zig's CLROOT and CSROOT
var srvnames: std.AutoHashMapUnmanaged(*Chan, [*:0]u8) = .empty;
var srvnames_lk: c.Lock = std.mem.zeroes(c.Lock);

/// The /srv name ch was posted as, if any. It lives as long as ch.
pub fn srvname(ch: *const Chan) ?[*:0]u8 {
    if (ch.flag & CSRVNAME == 0) return null;
    c.lock(&srvnames_lk);
    defer c.unlock(&srvnames_lk);
    return srvnames.get(@constCast(ch));
}

/// Records the /srv name ch is posted as, unless it has one: a channel
/// keeps the name of its first post, as 9front's.
pub fn setsrvname(ch: *Chan, name: [*:0]const u8) void {
    c.lock(&srvnames_lk);
    defer c.unlock(&srvnames_lk);
    const e = srvnames.getOrPut(std.heap.c_allocator, ch) catch return;
    if (e.found_existing) return;
    e.value_ptr.* = c.strdup(@constCast(name)) orelse {
        srvnames.removeByPtr(e.key_ptr);
        return;
    };
    ch.flag |= CSRVNAME;
}

fn dropsrvname(ch: *Chan) void {
    c.lock(&srvnames_lk);
    defer c.unlock(&srvnames_lk);
    if (srvnames.fetchRemove(ch)) |kv| c.free(kv.value);
}

pub fn chanfree(ch: *Chan) void {
    if (ch.flag & CSRVNAME != 0) dropsrvname(ch);
    ch.flag = c.CFREE;

    if (ch.dirrock != null) {
        c.free(ch.dirrock);
        ch.dirrock = null;
        ch.nrock = 0;
        ch.mrock = 0;
    }
    if (@as(?*Mhead, ch.umh)) |m| {
        putmhead(m);
        ch.umh = null;
    }
    if (@as(?*Chan, ch.umc)) |u| {
        cclose(u);
        ch.umc = null;
    }
    if (ch.mux != null) {
        @import("devmnt.zig").muxclose(ch.mux);
        ch.mux = null;
    }
    if (@as(?*Chan, ch.mchan)) |m| {
        cclose(m);
        ch.mchan = null;
    }

    pathclose(ch.path);
    ch.path = null;

    c.lock(&chanalloc.lk);
    ch.next = chanalloc.free;
    chanalloc.free = ch;
    c.unlock(&chanalloc.lk);
}

pub fn cclose(ch: ?*Chan) void {
    ccloseAt(ch, @returnAddress());
}

fn ccloseAt(ch_: ?*Chan, pc: usize) void {
    const ch = ch_ orelse port.kpanic("cclose %#p", .{pc});
    if (ch.ref.ref < 1 or ch.flag & c.CFREE != 0)
        port.kpanic("cclose %#p", .{pc});

    if (decref(&ch.ref) != 0)
        return;

    dev.close(dev.of(ch), ch) catch {};
    chanfree(ch);
}

/// Make sure we have the only copy of c. (Copy on write.)
pub fn cunique(ch_: *Chan) Error!*Chan {
    var ch = ch_;
    if (ch.ref.ref != 1) {
        const nc = try cclone(ch);
        cclose(ch);
        ch = nc;
    }

    if (@as(?*Mhead, ch.umh)) |m| { //BUG
        port.print("cunique umh != nil from %#p\n", .{@returnAddress()});
        putmhead(m);
        ch.umh = null;
    }

    return ch;
}

pub fn eqqid(a: Qid, b: Qid) bool {
    return a.path == b.path and a.vers == b.vers;
}

pub fn eqchan(a: *const Chan, b: *const Chan, skipvers: bool) bool {
    if (a.qid.path != b.qid.path)
        return false;
    if (!skipvers and a.qid.vers != b.qid.vers)
        return false;
    if (a.type != b.type)
        return false;
    if (a.dev != b.dev)
        return false;
    return true;
}

pub fn eqchantdqid(a: *const Chan, @"type": c_int, devn: c_int, qid: Qid, skipvers: bool) bool {
    if (a.qid.path != qid.path)
        return false;
    if (!skipvers and a.qid.vers != qid.vers)
        return false;
    if (a.type != @"type")
        return false;
    if (a.dev != @as(c_uint, @bitCast(devn)))
        return false;
    return true;
}

pub fn newmhead(from: *Chan) Error!*Mhead {
    return newmheadAt(from, @returnAddress());
}

fn newmheadAt(from: *Chan, pc: usize) Error!*Mhead {
    const mh: *Mhead = @ptrCast(@alignCast(port.malloc(@sizeOf(Mhead)) orelse return port.kerror(&port.Enomem)));
    mh.ref.ref = 1;
    mh.from = from;
    _ = incref(&from.ref);
    c.setmalloctag(mh, pc);
    return mh;
}

// This is necessary because there are many pointers to the top of a
// given mount list:
//
//    - the mhead in the namespace hash table
//    - the mhead in chans returned from findmount: used in namec and
//      then by unionread.
//    - the mhead in chans returned from createdir: used in the
//      open/create race protect, which is gone.
//
// The RWLock in the Mhead protects the mount list it contains. The
// mount list is deleted in cunmount() and closepgrp(). The RWLock
// ensures that nothing is using the mount list at that time.
//
// It is okay to replace c->mh with whatever you want as long as you are
// sure you have a unique reference to it.
//
// This comment might belong somewhere else.
pub fn putmhead(m_: ?*Mhead) void {
    const m = m_ orelse return;
    if (decref(&m.ref) != 0)
        return;
    port.assert(m.mount == null);
    cclose(m.from);
    c.free(m);
}

/// The head of the mount hash chain qid falls in.
fn mounth(pg: *c.Pgrp, qid: Qid) *[*c]Mhead {
    return &pg.mnthash[@intCast(qid.path & (c.MNTHASH - 1))];
}

pub fn cmount(new: *Chan, old: *Chan, flag: c_int, spec: ?[*:0]const u8) Error!c_int {
    if (old.umh != null)
        port.print("cmount: unexpected umh, caller %#p\n", .{@returnAddress()});

    if (c.QTDIR & (old.qid.type ^ new.qid.type) != 0)
        return port.kerror(&port.Emount);

    const order = flag & c.MORDER;

    if ((old.qid.type & c.QTDIR) == 0 and order != c.MREPL)
        return port.kerror(&port.Emount);

    const nm = try pgrp.newmount(new, flag, spec);
    if (@as(?*Mhead, new.umh)) |mh| {
        sync.rlock(&mh.lock);
        defer sync.runlock(&mh.lock);
        errdefer pgrp.mountfree(nm);
        if (@as(?*Mount, mh.mount)) |um_| {
            // Not allowed to bind when the old directory is itself a
            // union. (Maybe it should be allowed, but I don't see what
            // the semantics would be.)
            //
            // We need to check mh->mount->next to tell unions apart
            // from simple mount points, so that things like
            //    mount -c fd /root
            //    bind -c /root /
            // work.
            //
            // The check of mount->mflag allows things like
            //    mount fd /root
            //    bind -c /root /
            //
            // This is far more complicated than it should be, but I
            // don't see an easier way at the moment.
            if ((flag & c.MCREATE) != 0 and (um_.next != null or (um_.mflag & c.MCREATE) == 0))
                return port.kerror(&port.Emount);

            // copy a union when binding it onto a directory
            var f = nm;
            var um: ?*Mount = um_.next;
            while (um) |u| : (um = u.next) {
                const n = try pgrp.newmount(u.to, if (order == c.MREPL) c.MAFTER else order, @ptrCast(u.spec()));
                f.next = n;
                f = n;
            }
        }
    }

    const pg: *c.Pgrp = up().pgrp;
    sync.wlock(&pg.ns);
    var um: ?*Mount = undefined;
    {
        errdefer {
            sync.wunlock(&pg.ns);
            pgrp.mountfree(nm);
        }
        var l = mounth(pg, old.qid);
        var m_: ?*Mhead = l.*;
        while (m_) |m| : (m_ = m.hash) {
            if (eqchan(m.from, old, true))
                break;
            l = &m.hash;
        }
        const m = m_ orelse blk: {
            // nothing mounted here yet. create a mount head and add to
            // the hash table.
            const m = try newmhead(old);
            // if this is a union mount, add the old node to the mount
            // chain.
            if (order != c.MREPL) {
                errdefer putmhead(m);
                const f = try pgrp.newmount(old, 0, null);
                f.umh = m;
                m.mount = f;
                pgrp.pgrpinsert(pg, f);
            }
            l.* = m;
            break :blk m;
        };
        var f_: ?*Mount = nm;
        while (f_) |f| : (f_ = f.next) {
            f.umh = m;
            pgrp.pgrpinsert(pg, f);
        }
        sync.wlock(&m.lock);
        um = m.mount;
        if (um != null and order == c.MAFTER) {
            var f = um.?;
            while (f.next) |n| f = n;
            f.next = nm;
            um = null;
        } else {
            if (order != c.MREPL) {
                var f = nm;
                while (f.next) |n| f = n;
                f.next = um;
                um = null;
            }
            m.mount = nm;
        }
        sync.wunlock(&m.lock);
        f_ = um;
        while (f_) |f| : (f_ = f.next)
            pgrp.pgrpremove(pg, f);
        sync.wunlock(&pg.ns);
    }

    pgrp.mountfree(um);

    return 0;
}

pub fn cunmount(mnt: *Chan, mounted: ?*Chan) Error!void {
    if (mnt.umh != null) // should not happen
        port.print("cunmount newp extra umh %p has %p\n", .{ mnt, mnt.umh });

    // It _can_ happen that mounted->umh is non-nil, because mounted is
    // the result of namec(Aopen) (see sysfile.c:/^sysunmount). If we
    // open a union directory, it will have a umh. Although surprising,
    // this is okay, since the cclose will take care of freeing the umh.

    const pg: *c.Pgrp = up().pgrp;
    sync.wlock(&pg.ns);

    var l = mounth(pg, mnt.qid);
    var m_: ?*Mhead = l.*;
    while (m_) |m| : (m_ = m.hash) {
        if (eqchan(m.from, mnt, true))
            break;
        l = &m.hash;
    }

    const m = m_ orelse {
        sync.wunlock(&pg.ns);
        return port.kerror(&port.Eunmount);
    };

    sync.wlock(&m.lock);
    const mtd = mounted orelse {
        var f_: ?*Mount = m.mount;
        while (f_) |f| : (f_ = f.next)
            pgrp.pgrpremove(pg, f);
        const f = m.mount;
        m.mount = null;
        l.* = m.hash;
        sync.wunlock(&m.lock);
        sync.wunlock(&pg.ns);
        pgrp.mountfree(f);
        putmhead(m);
        return;
    };
    var p: *[*c]Mount = &m.mount;
    var f_: ?*Mount = m.mount;
    while (f_) |f| : (f_ = f.next) {
        if (eqchan(f.to, mtd, true) or
            (f.to.*.mchan != null and eqchan(f.to.*.mchan, mtd, true)))
        {
            pgrp.pgrpremove(pg, f);
            p.* = f.next;
            f.next = null;
            if (m.mount == null) {
                l.* = m.hash;
                sync.wunlock(&m.lock);
                sync.wunlock(&pg.ns);
                pgrp.mountfree(f);
                putmhead(m);
                return;
            }
            sync.wunlock(&m.lock);
            sync.wunlock(&pg.ns);
            pgrp.mountfree(f);
            return;
        }
        p = &f.next;
    }
    sync.wunlock(&m.lock);
    sync.wunlock(&pg.ns);
    return port.kerror(&port.Eunion);
}

pub fn cclone(ch: *Chan) Error!*Chan {
    return ccloneAt(ch, @returnAddress());
}

fn ccloneAt(ch: *Chan, pc: usize) Error!*Chan {
    if (ch.ref.ref < 1 or ch.flag & c.CFREE != 0)
        port.kpanic("cclone: %#p", .{pc});
    const wq: *Walkqid = try dev.walkdev(dev.of(ch), ch, null, undefined, 0) orelse
        return port.kerror("clone failed");
    const nc: *Chan = wq.libclone;
    c.free(wq);
    nc.path = ch.path;
    if (@as(?*Path, ch.path)) |p|
        _ = incref(&p.ref);
    return nc;
}

// h9: src/kern/dev/overlay.zig
extern fn h9_overlay_lowerdev(c_int, c_int, Qid, *c_int, *c_int) c_int;
// h9: the host tree device (src/host/devfs.zig).
const hostfs = @import("host_dev").fs;
// h9: Linux symlinks (design/epoch-0/linux-symlinks.md, src/host/fscheck.h)
extern fn h9_fs_linkwalk() c_int;
extern fn h9_fs_nofollowing() c_int;
extern fn h9_fs_atroot(*Chan) c_int; // h9: src/kern/linux.zig
const Qtsymlink = 0x02; // H9_QTSYMLINK
const Maxlinks = 40; // H9_MAXLINKS
const Linkbuf = 4096;

/// also used by sysfile.c:/^mountfix
pub fn findmount(cp: *?*Chan, mp: ?*?*Mhead, type_: c_int, dev_: c_int, qid: Qid) bool {
    var @"type" = type_;
    var devn = dev_;
    const pg: *c.Pgrp = up().pgrp;
    var samepath = false;
    sync.rlock(&pg.ns);
    var m_: ?*Mhead = mounth(pg, qid).*;
    while (m_) |m| : (m_ = m.hash) {
        if (m.from.*.qid.path == qid.path)
            samepath = true;
        if (eqchantdqid(m.from, @"type", devn, qid, true)) {
            if (mp != null)
                _ = incref(&m.ref);
            sync.rlock(&m.lock);
            const to: *Chan = m.mount.*.to;
            _ = incref(&to.ref);
            sync.runlock(&m.lock);
            sync.runlock(&pg.ns);
            if (mp) |p| {
                putmhead(p.*);
                p.* = m;
            }
            if (cp.*) |old|
                cclose(old);
            cp.* = to;
            return true;
        }
    }
    sync.runlock(&pg.ns);
    // h9: a lower directory seen through a #O overlay keeps the mounts
    // made on it before the overlay (src/kern/dev/overlay.zig), as when a
    // namespace file's overlay goes over / after other binds.
    if (samepath and h9_overlay_lowerdev(@"type", devn, qid, &@"type", &devn) != 0)
        return findmount(cp, mp, @"type", devn, qid);
    return false;
}

/// Calls findmount but also updates path.
fn domount(cp: **Chan, mp: *?*Mhead, path: ?**Path) bool {
    var ch: ?*Chan = cp.*;
    if (!findmount(&ch, mp, cp.*.type, @bitCast(cp.*.dev), cp.*.qid))
        return false;
    cp.* = ch.?;

    if (path) |pp| {
        const p = uniquepath(pp.*);
        if (p.mlen <= 0)
            port.print("domount: path %s has mlen==%d\n", .{ p.s, p.mlen })
        else {
            const from: *Chan = mp.*.?.from;
            _ = incref(&from.ref);
            const lc = &p.mtpt[@intCast(p.mlen - 1)];
            if (@as(?*Chan, lc.*)) |old|
                cclose(old);
            lc.* = from;
        }
        pp.* = p;
    }
    return true;
}

/// If c is the right-hand-side of a mount point, returns the left hand
/// side. Changes name to reflect the fact that we've uncrossed the
/// mountpoint, so name had better be ours to change!
fn undomount(ch: *Chan, path: *Path) *Chan {
    if (path.ref.ref != 1 or path.mlen == 0)
        port.print("undomount: path %s ref %ld mlen %d caller %#p\n", .{ path.s, path.ref.ref, path.mlen, @returnAddress() });

    if (path.mlen > 0) {
        if (@as(?*Chan, path.mtpt[@intCast(path.mlen - 1)])) |nc| {
            cclose(ch);
            path.mtpt[@intCast(path.mlen - 1)] = null;
            return nc;
        }
    }
    return ch;
}

/// Call dev walk but catch errors.
fn ewalk(ch: *Chan, nc: ?*Chan, name: [*]const [*:0]const u8, nname: c_int) ?*Walkqid {
    return dev.walkdev(dev.of(ch), ch, nc, name, nname) catch null;
}

/// Either walks all the way or not at all. No partial results in *cp.
/// *nerror is the number of names to display in an error message.
pub fn walk(cp: **Chan, names: [*]const [*:0]const u8, nnames: c_int, nomount: bool, nerror: ?*c_int) Error!c_int {
    var nlinks: c_int = 0;
    return walkl(cp, names, nnames, nomount, nerror, true, &nlinks);
}

/// h9: the link a Linux process's walk stopped at
/// (design/epoch-0/linux-symlinks.md). c is the directory the walk had reached,
/// path its name; the device's walk of the k names from names (k > 0)
/// ended on a link, the last of them, and rest more names follow it.
/// Walks the link's target and then the rest: an absolute target from
/// the process's root, a relative one from the link's directory, so the
/// result's name is the target's. Returns the walk's result, or nil with
/// the error in errstr.
fn followlink(ch: *Chan, path: *Path, names: [*]const [*:0]const u8, k: c_int, rest: [*]const [*:0]const u8, nrest: c_int, nomount_: bool, follow: bool, nlinks: *c_int) Error!?*Chan {
    var nomount = nomount_;
    nlinks.* += 1;
    if (nlinks.* > Maxlinks) {
        kstrcpy(up().errstr, "too many symbolic links", port.ERRMAX);
        return null;
    }
    // The link itself, to read its target.
    const wq = ewalk(ch, null, names, k) orelse return null;
    const lc_: ?*Chan = wq.libclone;
    if (lc_ == null or wq.nqid != k) {
        if (lc_) |lc|
            cclose(lc);
        c.free(wq);
        kstrcpy(up().errstr, &port.Enonexist, port.ERRMAX);
        return null;
    }
    const lc = lc_.?;
    c.free(wq);
    const buf: [*]u8 = @ptrCast(c.smalloc(Linkbuf));
    // The link's device reads it (design/file-interface.md).
    const got = dev.readlink(lc, buf[0..Linkbuf]) catch {
        cclose(lc);
        c.free(buf);
        return null;
    };
    cclose(lc);
    const n: c_int = @intCast(got orelse 0);
    if (n == 0) {
        c.free(buf);
        kstrcpy(up().errstr, &port.Enonexist, port.ERRMAX);
        return null;
    }
    // The names to walk: the link's directory's (if relative), the
    // target's, and the rest.
    const abs = buf[0] == '/';
    const nn: [*][*:0]const u8 = @ptrCast(@alignCast(c.smalloc(@intCast(@as(usize, @intCast(k + n + nrest)) * @sizeOf([*]u8)))));
    var nnn: usize = 0;
    if (!abs) {
        var i: usize = 0;
        while (i < k - 1) : (i += 1) {
            nn[nnn] = names[i];
            nnn += 1;
        }
    }
    var t = buf;
    while (t[0] != 0) {
        while (t[0] == '/') {
            t[0] = 0;
            t += 1;
        }
        if (t[0] == 0)
            break;
        nn[nnn] = @ptrCast(t);
        nnn += 1;
        while (t[0] != 0 and t[0] != '/')
            t += 1;
    }
    var i: usize = 0;
    while (i < nrest) : (i += 1) {
        nn[nnn] = rest[i];
        nnn += 1;
    }
    var s: *Chan = undefined;
    if (abs) {
        s = cclone(up().slash) catch |e| {
            c.free(@ptrCast(nn));
            c.free(buf);
            return e;
        };
        nomount = false;
    } else {
        s = cclone(ch) catch |e| {
            c.free(@ptrCast(nn));
            c.free(buf);
            return e;
        };
        pathclose(s.path);
        s.path = path;
        _ = incref(&path.ref);
    }
    defer c.free(buf);
    defer c.free(@ptrCast(nn));
    const r = try walkl(&s, nn, @intCast(nnn), nomount, null, follow, nlinks);
    if (r < 0) {
        cclose(s);
        return null;
    }
    return s;
}

fn walkl(cp: **Chan, names: [*]const [*:0]const u8, nnames: c_int, nomount: bool, nerror: ?*c_int, follow: bool, nlinks: *c_int) Error!c_int {
    var ch = cp.*;
    _ = incref(&ch.ref);
    var path: *Path = ch.path;
    _ = incref(&path.ref);
    var mh: ?*Mhead = null;

    // While we haven't gotten all the way down the path:
    //    1. step through a mount point, if any
    //    2. send a walk request for initial dotdot or initial prefix
    //       without dotdot
    //    3. move to the first mountpoint along the way.
    //    4. repeat.
    //
    // Each time through the loop:
    //
    //    If didmount==0, c is on the undomount side of the mount point.
    //    If didmount==1, c is on the domount side of the mount point.
    //     Either way, c's full path is path.
    var didmount = false;
    var nhave: c_int = 0;
    var n: c_int = 0;
    while (nhave < nnames) : (nhave += n) {
        if ((ch.qid.type & c.QTDIR) == 0) {
            if (nerror) |ne|
                ne.* = nhave;
            pathclose(path);
            cclose(ch);
            kstrcpy(up().errstr, &port.Enotdir, port.ERRMAX);
            putmhead(mh);
            return -1;
        }
        var ntry = nnames - nhave;
        if (ntry > c.MAXWELEM)
            ntry = c.MAXWELEM;
        var dotdot = false;
        var i: c_int = 0;
        while (i < ntry) : (i += 1) {
            if (isdotdot(names[@intCast(nhave + i)])) {
                if (i == 0) {
                    dotdot = true;
                    ntry = 1;
                } else ntry = i;
                break;
            }
        }

        // h9: .. at a Linux process's chroot stays there, as on Linux
        // (design/epoch-0/linux-chroot.md).
        if (dotdot and h9_fs_atroot(ch) != 0) {
            n = 1;
            continue;
        }

        if (!dotdot and !nomount and !didmount)
            _ = domount(&ch, &mh, &path);

        var @"type": c_int = ch.type;
        var devn: c_int = @bitCast(ch.dev);
        var wc = ch; // h9: the chan the names were walked from, for followlink

        var wq: *Walkqid = ewalk(ch, null, names + @as(usize, @intCast(nhave)), ntry) orelse blk: {
            // try a union mount, if any
            var found: ?*Walkqid = null;
            if (mh != null and !nomount) {
                const h = mh.?;
                // mh->mount->to == c, so start at mh->mount->next
                sync.rlock(&h.lock);
                var f_: ?*Mount = h.mount;
                if (f_) |f| f_ = f.next;
                while (f_) |f| : (f_ = f.next)
                    if (ewalk(f.to, null, names + @as(usize, @intCast(nhave)), ntry)) |w| {
                        found = w;
                        @"type" = f.to.*.type;
                        devn = @bitCast(f.to.*.dev);
                        wc = f.to;
                        _ = incref(&wc.ref);
                        break;
                    };
                sync.runlock(&h.lock);
            }
            break :blk found orelse {
                cclose(ch);
                pathclose(path);
                if (nerror) |ne|
                    ne.* = nhave + 1;
                putmhead(mh);
                return -1;
            };
        };
        const wqid = dev.qids(wq);

        // h9: a Linux process's walk that stopped at a link, with names
        // left or at a last name it follows, starts again at the link's
        // target (design/epoch-0/linux-symlinks.md), unless a mount point comes
        // before the link: the walk crosses that first.
        if (!dotdot and wq.nqid > 0 and (wqid[@intCast(wq.nqid - 1)].type & Qtsymlink) != 0 and
            (nhave + wq.nqid < nnames or follow) and h9_fs_linkwalk() != 0)
        {
            const k = wq.nqid;
            var nc: ?*Chan = null;
            var nmh: ?*Mhead = null;
            if (!nomount) {
                i = 0;
                while (i < k - 1) : (i += 1)
                    if (findmount(&nc, &nmh, @"type", devn, wqid[@intCast(i)]))
                        break;
            }
            if (nc) |x| {
                cclose(x);
                putmhead(nmh);
                nc = null;
            } else {
                if (@as(?*Chan, wq.libclone)) |cl|
                    cclose(cl);
                c.free(wq);
                const rest = names + @as(usize, @intCast(nhave + k));
                const r = followlink(wc, path, names + @as(usize, @intCast(nhave)), k, rest, nnames - nhave - k, nomount, follow, nlinks);
                if (wc != ch)
                    cclose(wc);
                cclose(ch);
                pathclose(path);
                putmhead(mh);
                const fc = (try r) orelse {
                    if (nerror) |ne|
                        ne.* = nhave + k;
                    return -1;
                };
                cclose(cp.*);
                cp.* = fc;
                if (nerror) |ne|
                    ne.* = nnames;
                return 0;
            }
        }
        if (wc != ch)
            cclose(wc);

        didmount = false;
        var nc: *Chan = undefined;
        var nmh: ?*Mhead = null;
        if (dotdot) {
            port.assert(wq.nqid == 1);
            port.assert(wq.libclone != null);

            path = addelem(path, "..", null);
            nc = undomount(wq.libclone, path);
            nmh = null;
            n = 1;
        } else {
            var mc: ?*Chan = null;
            nmh = null;
            if (!nomount) {
                i = 0;
                while (i < wq.nqid and i < ntry - 1) : (i += 1) {
                    if (findmount(&mc, &nmh, @"type", devn, wqid[@intCast(i)])) {
                        didmount = true;
                        break;
                    }
                }
            }
            if (mc) |x| { // stopped early, at a mount point
                port.assert(didmount);
                if (@as(?*Chan, wq.libclone)) |cl| {
                    cclose(cl);
                    wq.libclone = null;
                }
                n = i + 1;
                nc = x;
            } else { // no mount points along path
                const cl: *Chan = @as(?*Chan, wq.libclone) orelse {
                    cclose(ch);
                    pathclose(path);
                    if (wq.nqid == 0 or (wqid[@intCast(wq.nqid - 1)].type & c.QTDIR) != 0) {
                        if (nerror) |ne|
                            ne.* = nhave + wq.nqid + 1;
                        kstrcpy(up().errstr, &port.Enonexist, port.ERRMAX);
                    } else {
                        if (nerror) |ne|
                            ne.* = nhave + wq.nqid;
                        kstrcpy(up().errstr, &port.Enotdir, port.ERRMAX);
                    }
                    c.free(wq);
                    putmhead(mh);
                    return -1;
                };
                n = wq.nqid;
                nc = cl;
            }
            i = 0;
            while (i < n) : (i += 1) {
                var mtpt: ?*Chan = null;
                if (i == n - 1 and nmh != null)
                    mtpt = nmh.?.from;
                path = addelem(path, names[@intCast(nhave + i)], mtpt);
            }
        }
        cclose(ch);
        ch = nc;
        putmhead(mh);
        mh = nmh;
        c.free(wq);
        wq = undefined;
    }
    putmhead(mh);
    ch = cunique(ch) catch |e| {
        // (cunique's clone failed: c is still ours.)
        cclose(ch);
        pathclose(path);
        return e;
    };

    pathclose(ch.path);
    ch.path = path;

    cclose(cp.*);
    cp.* = ch;
    if (nerror) |ne|
        ne.* = nhave;
    return 0;
}

/// c is a mounted non-creatable directory. find a creatable one.
pub fn createdir(ch: *Chan, m: *Mhead) Error!*Chan {
    sync.rlock(&m.lock);
    var f_: ?*Mount = m.mount;
    while (f_) |f| : (f_ = f.next) {
        if ((f.mflag & c.MCREATE) != 0) {
            const nc = cclone(f.to) catch |e| {
                sync.runlock(&m.lock);
                return e;
            };
            sync.runlock(&m.lock);
            cclose(ch);
            return nc;
        }
    }
    sync.runlock(&m.lock);
    return port.kerror(&port.Enocreate);
}

pub fn saveregisters() void {}

fn growparse(e: *Elemlist) void {
    const Delta = 8;

    if (@mod(e.nelems, Delta) == 0) {
        const ne: usize = @intCast(e.nelems);
        const new: [*][*:0]u8 = @ptrCast(@alignCast(c.smalloc(@intCast((ne + Delta) * @sizeOf([*]u8)))));
        if (e.elems) |old| @memcpy(new[0..ne], old[0..ne]);
        c.free(@ptrCast(e.elems));
        e.elems = new;
        const inew: [*]c_int = @ptrCast(@alignCast(c.smalloc(@intCast((ne + Delta + 1) * @sizeOf(c_int)))));
        @memcpy(inew[0 .. ne + 1], e.off.?[0 .. ne + 1]);
        c.free(@ptrCast(e.off));
        e.off = inew;
    }
}

/// The name is known to be valid. Copy the name so slashes can be
/// overwritten. An empty string will set nelem=0. A path ending in / or
/// /. or /.//./ etc. will have e.mustbedir = 1, so that we correctly
/// reject, e.g., "/adm/users/." when /adm/users is a file rather than a
/// directory.
fn parsename(aname: [*:0]const u8, e: *Elemlist) void {
    kstrdup(&e.name, aname);
    const base: [*:0]u8 = e.name.?;
    var name: [*:0]u8 = base;
    e.nelems = 0;
    e.elems = null;
    e.off = @ptrCast(@alignCast(c.smalloc(@sizeOf(c_int))));
    e.off.?[0] = @intCast(@intFromPtr(skipslash(name)) - @intFromPtr(name));
    while (true) {
        name = skipslash(name);
        if (name[0] == 0) {
            e.off.?[@intCast(e.nelems)] = @intCast(@intFromPtr(name + std.mem.len(name)) - @intFromPtr(base));
            e.mustbedir = true;
            break;
        }
        growparse(e);
        e.elems.?[@intCast(e.nelems)] = name;
        e.nelems += 1;
        const slash: [*c]u8 = c.utfrune(name, '/');
        if (slash == null) {
            e.off.?[@intCast(e.nelems)] = @intCast(@intFromPtr(name + std.mem.len(name)) - @intFromPtr(base));
            e.mustbedir = false;
            break;
        }
        e.off.?[@intCast(e.nelems)] = @intCast(@intFromPtr(slash) - @intFromPtr(base));
        slash.* = 0;
        name = @ptrCast(slash + 1);
    }
}

/// The error for a name: err, with as much of the name as fits.
pub fn namelenerror(aname: [*:0]const u8, len_: c_int, err: [*:0]const u8) error{Kernel} {
    var len = len_;
    const p = up();
    const genbuf: [*c]u8 = &p.genbuf;

    // If the name is short enough, just use the whole thing.
    const errlen: c_int = @intCast(std.mem.len(err));
    if (len < @divTrunc(port.ERRMAX, 3) or len + errlen < @divTrunc(2 * port.ERRMAX, 3)) {
        _ = c.snprint(genbuf, p.genbuf.len, @constCast("%.*s"), c.utfnlen(@constCast(aname), len), aname);
    } else {
        // Print a suffix of the name, but try to get a little info.
        const ename = aname + @as(usize, @intCast(len));
        var next = ename;
        var name = next;
        while (true) {
            name = next;
            if (next == aname)
                break;
            while (@intFromPtr(next) > @intFromPtr(aname)) {
                next -= 1;
                if (next[0] == '/')
                    break;
            }
            len = @intCast(@intFromPtr(ename) - @intFromPtr(next));
            if (!(len < @divTrunc(port.ERRMAX, 3) or len + errlen < @divTrunc(2 * port.ERRMAX, 3)))
                break;
        }

        // If the name is ridiculously long, chop it.
        if (name == ename) {
            name = ename - @divTrunc(port.ERRMAX, 4);
            if (@intFromPtr(name) <= @intFromPtr(aname))
                port.kpanic("bad math in namelenerror", .{});
            // walk out of current UTF sequence
            var i: usize = 0;
            while ((name[0] & 0xC0) == 0x80 and i < c.UTFmax) : (i += 1)
                name += 1;
        }
        _ = c.snprint(genbuf, p.genbuf.len, @constCast("...%.*s"), c.utfnlen(@constCast(name), @intCast(@intFromPtr(ename) - @intFromPtr(name))), name);
    }
    _ = c.snprint(p.errstr, port.ERRMAX, @constCast("%s: %#q"), err, genbuf);
    return error.Kernel;
}

/// Turn a name into a channel. &name[0] is known to be a valid address.
/// It may be a kernel address.
///
/// Opening with amode Aopen, Acreate, Aremove, or Aaccess guarantees
/// that the result will be the only reference to that particular fid.
/// This is necessary since we might pass the result to
/// devtab[]->remove().
///
/// Opening Atodir or Amount does not guarantee this.
///
/// Under certain circumstances, opening Aaccess will cause an
/// unnecessary clone in order to get a cunique Chan so it can attach the
/// correct name. Sysstat and sys_stat need the correct name so they can
/// rewrite the stat info.
// Handle names in the namespace (design/host-handles.md): src/kern.zig's
// leaves, weak since a kernel built without src/kern.zig (the kernel's
// own cases) has no host.
const NsFn = fn ([*]const u8, c_int, [*]u8, c_int) callconv(.c) c_int;
const h9_host_nsname = @extern(?*const NsFn, .{ .name = "h9_host_nsname", .linkage = .weak });
const h9_host_nspath = @extern(?*const NsFn, .{ .name = "h9_host_nspath", .linkage = .weak });

/// `#U` and `#U!c`, the host tree device's names, and where a host path
/// or a handle name starts in `s`.
fn hostfsPrefix(s: []const u8) ?usize {
    if (!std.mem.startsWith(u8, s, "#U")) return null;
    return if (std.mem.startsWith(u8, s[2..], "!c")) 4 else 2;
}

/// A name for the host tree device by a handle's name, `#Ucwd/a` or
/// `#U!croot/a`, as /proc/n/ns prints one, spelled by the host path
/// it stands for, `#U/home/me/a`, so the channel it gives is the one the
/// namespace was built with; null for any other name, or a handle the
/// calling thread's machine doesn't have, which then fails as a bad
/// attach.
fn hostfsByHandle(name: [*:0]const u8) ?[*:0]u8 {
    const s = std.mem.span(name);
    const i = hostfsPrefix(s) orelse return null;
    if (i >= s.len or s[i] == '/') return null;
    const f = h9_host_nspath orelse return null;
    const end = std.mem.indexOfScalarPos(u8, s, i, '/') orelse s.len;
    var buf: [4096]u8 = undefined;
    const n = f(s[i..].ptr, @intCast(end - i), &buf, buf.len);
    if (n < 0) return null;
    const host = buf[0..@intCast(n)];
    const rest = s[end..];
    const total = i + host.len + rest.len;
    const out: [*]u8 = @ptrCast(c.malloc(@intCast(total + 1)) orelse return null);
    @memcpy(out[0..i], s[0..i]);
    @memcpy(out[i..][0..host.len], host);
    @memcpy(out[i + host.len ..][0..rest.len], rest);
    out[total] = 0;
    return @ptrCast(out);
}

/// The name /proc/n/ns prints for a channel's path p: for the host tree
/// device, the machine's handle that holds the host path, by its name
/// (`#U/home/me/a` as `#Ucwd/a`), so no host path shows; p otherwise, or
/// if `buf` is too short or no handle holds it.
pub fn nsname(p: [*:0]const u8, buf: []u8) [*:0]const u8 {
    const s = std.mem.span(p);
    const i = hostfsPrefix(s) orelse return p;
    if (i >= s.len or s[i] != '/') return p;
    const f = h9_host_nsname orelse return p;
    if (buf.len < i + 2) return p;
    @memcpy(buf[0..i], s[0..i]);
    const n = f(s[i..].ptr, @intCast(s.len - i), buf[i..].ptr, @intCast(buf.len - i - 1));
    if (n < 0) return p;
    buf[i + @as(usize, @intCast(n))] = 0;
    return @ptrCast(buf.ptr);
}

pub fn namec(aname_: [*:0]const u8, amode: c_int, omode: c_int, perm: c_uint) Error!*Chan {
    return namecx(aname_, amode, omode, perm, false);
}

/// h9: namec, for a Linux process's lookup that acts on a link in its
/// last name instead of following it when nofollow is set (lstat,
/// readlink, rename; design/file-interface.md), as the process's own
/// flag (h9_fs_nofollow) also says for the calls that set it.
pub fn namecx(aname_: [*:0]const u8, amode: c_int, omode: c_int, perm: c_uint, nofollow: bool) Error!*Chan {
    if (aname_[0] == 0)
        return port.kerror("empty file name");
    var aname: [*:0]u8 = (try validnamedupAt(aname_, true, @returnAddress())).?;
    // h9: a host tree by its handle's name (design/host-handles.md).
    if (hostfsByHandle(aname)) |r| {
        c.free(aname);
        aname = r;
    }
    defer c.free(aname);
    var name: [*:0]u8 = aname;
    const p = up();

    // Find the starting off point (the current slash, the root of a
    // device tree, or the current dot) as well as the name to evaluate
    // starting there.
    var nomount = false;
    var ch: *Chan = undefined;
    switch (name[0]) {
        '/' => {
            ch = p.slash;
            _ = incref(&ch.ref);
        },
        '#' => {
            nomount = true;
            var n: usize = 0;
            while (name[0] != 0 and (name[0] != '/' or n < 2)) {
                if (n >= p.genbuf.len - 1)
                    return port.kerror(&port.Efilename);
                p.genbuf[n] = name[0];
                n += 1;
                name += 1;
            }
            p.genbuf[n] = 0;
            var r: c.Rune = undefined;
            n = @as(usize, @intCast(c.chartorune(&r, @ptrCast(&p.genbuf[1])))) + 1;
            const t = dev.devno(@intCast(r));
            if (t < 0)
                return port.kerror(&port.Ebadsharp);
            // When sandboxing, unmounting a sharp from a union is a
            // valid operation even if the device is blocked. Doing any
            // walks down the device could leak information about the
            // existence of files.
            if ((amode != c.Aunmount or p.genbuf[n] != 0 or name[0] != 0) and pgrp.devmasked(p.pgrp, t))
                return port.kerror(&port.Enoattach);

            ch = try dev.attach(dev.table()[@intCast(t)].?, @ptrCast(&p.genbuf[n]));
            // h9: #L, the Linux view's root (src/kern/dev/linux.zig), is a
            // union with the Linux root tree bound after it, so a walk
            // from it crosses mounts, as one from / does.
            if (r == 'L')
                nomount = false;
        },
        else => {
            ch = p.dot;
            _ = incref(&ch.ref);
        },
    }

    var e: Elemlist = .{ .aname = aname, .prefix = @intCast(@intFromPtr(name) - @intFromPtr(aname)) };
    var nlinks: c_int = 0;
    namec1(&ch, &e, name, nomount, &nlinks, amode, omode, perm, nofollow) catch |err| {
        cclose(ch);
        c.free(e.name);
        c.free(@ptrCast(e.elems));
        // Prepare nice error, showing first e.nerror elements of name.
        if (e.nerror == 0) {
            c.free(@ptrCast(e.off));
            return err;
        }
        var tmperrbuf: [port.ERRMAX:0]u8 = undefined;
        kstrcpy(&tmperrbuf, p.errstr, port.ERRMAX);
        const off = e.off.?[@intCast(e.nerror)];
        if (off == 0)
            port.print("nerror=%d but off=%d\n", .{ e.nerror, off });
        const len = e.prefix + off;
        c.free(@ptrCast(e.off));
        return namelenerror(aname, len, &tmperrbuf);
    };

    // place final element in genbuf for e.g. exec
    if (e.nelems > 0)
        kstrcpy(&p.genbuf, e.elems.?[@intCast(e.nelems - 1)], p.genbuf.len)
    else
        kstrcpy(&p.genbuf, ".", p.genbuf.len);
    c.free(e.name);
    c.free(@ptrCast(e.elems));
    c.free(@ptrCast(e.off));

    return ch;
}

/// namec's work from its starting chan, *cp, which it replaces with the
/// result, and which is namec's to close on an error.
fn namec1(cp: **Chan, e: *Elemlist, name: [*:0]const u8, nomount: bool, nlinks: *c_int, amode: c_int, omode_: c_int, perm: c_uint, want_nofollow: bool) Error!void {
    var omode = omode_;

    // Build a list of elements in the name.
    parsename(name, e);

    // On create, ....
    if (amode == c.Acreate) {
        // perm must have DMDIR if last element is / or /.
        if (e.mustbedir and (perm & c.DMDIR) == 0) {
            e.nerror = e.nelems;
            return port.kerror("create without DMDIR");
        }

        // don't try to walk the last path element just yet.
        if (e.nelems == 0)
            return port.kerror(&port.Eexist);
        e.nelems -= 1;
    }

    // h9: a Linux process's lookup follows a link in its last name
    // unless it's a remove, or the call says not to (namecx's nofollow,
    // or h9_fs_nofollow). A create's walk here stops before its last
    // name.
    const nofollow = amode == c.Aremove or (amode != c.Acreate and h9_fs_linkwalk() != 0 and (want_nofollow or h9_fs_nofollowing() != 0));
    const elems: [*]const [*:0]const u8 = if (e.elems) |el| @ptrCast(el) else &.{};
    if (try walkl(cp, elems, e.nelems, nomount, &e.nerror, !nofollow, nlinks) < 0) {
        if (e.nerror < 0 or e.nerror > e.nelems) {
            port.print("namec %s walk error nerror=%d\n", .{ e.aname, e.nerror });
            e.nerror = 0;
        }
        return error.Kernel;
    }

    // h9: a contained #U attach's tree is where its walk ends (devfs).
    if (nomount and dev.of(cp.*).dc == 'U')
        try hostfs.anchor(cp.*);

    if (e.mustbedir and (cp.*.qid.type & c.QTDIR) == 0)
        return port.kerror("not a directory");

    if (amode == c.Aopen and (omode & 3) == c.OEXEC and (cp.*.qid.type & c.QTDIR) != 0)
        return port.kerror("cannot exec directory");

    switch (amode) {
        c.Aunmount, c.Abind => {
            // When unmounting, the channel must be opend when not a
            // directory in order to get the real chan from something
            // like /srv/cs or /fd/0.
            if (amode == c.Aunmount and (cp.*.qid.type & c.QTDIR) == 0) {
                try open(cp, nomount, amode, omode);
            } else {
                // no need to maintain path - cannot dotdot an Abind
                var m: ?*Mhead = null;
                if (!nomount)
                    _ = domount(cp, &m, null);
                cp.* = cunique(cp.*) catch |err| {
                    putmhead(m);
                    return err;
                };
                cp.*.umh = m;
            }
        },

        c.Aaccess, c.Aremove, c.Aopen => try open(cp, nomount, amode, omode),

        c.Atodir => {
            // Directories (e.g. for cd) are left before the mount point,
            // so one may mount on / or . and see the effect.
            if ((cp.*.qid.type & c.QTDIR) == 0)
                return port.kerror(&port.Enotdir);
        },

        c.Amount => {
            // When mounting on an already mounted upon directory, one
            // wants subsequent mounts to be attached to the original
            // directory, not the replacement. Don't domount.
        },

        c.Acreate => {
            // We've already walked all but the last element. If the
            // last exists, try to open it OTRUNC. If omode&OEXCL is set,
            // just give up.
            e.nelems += 1;
            e.nerror += 1;
            const last: [*]const [*:0]const u8 = @ptrCast(e.elems.? + @as(usize, @intCast(e.nelems - 1)));
            if (try walk(cp, last, 1, nomount, null) == 0) {
                if (omode & c.OEXCL != 0)
                    return port.kerror(&port.Eexist);
                omode |= c.OTRUNC;
                return open(cp, nomount, amode, omode);
            }

            // The semantics of the create(2) system call are that if the
            // file exists and can be written, it is to be opened with
            // truncation. On the other hand, the create(5) message fails
            // if the file exists. If we get two create(2) calls
            // happening simultaneously, they might both get here and
            // send create(5) messages, but only one of the messages will
            // succeed. To provide the expected create(2) semantics, the
            // call with the failed message needs to try the above walk
            // again, opening for truncation. This correctly solves the
            // create/create race, in the sense that any observable
            // outcome can be explained as one happening before the
            // other. The create/create race is quite common. For
            // example, it happens when two rc subshells simultaneously
            // update the same environment variable.
            //
            // The implementation still admits a create/create/remove
            // race:
            // (A) walk to file, fails
            // (B) walk to file, fails
            // (A) create file, succeeds, returns
            // (B) create file, fails
            // (A) remove file, succeeds, returns
            // (B) walk to file, return failure.
            //
            // This is hardly as common as the create/create race, and
            // is really not too much worse than what might happen if (B)
            // got a hold of a file descriptor and then the file was
            // removed -- either way (B) can't do anything with the
            // result of the create call. So we don't care about this
            // race.
            //
            // Applications that care about more fine-grained decision
            // of the races can use the OEXCL flag to get at the
            // underlying create(5) semantics; by default we provide the
            // common case.
            //
            // We need to stay behind the mount point in case we need to
            // do the first walk again (should the create fail).
            //
            // We also need to cross the mount point and find the
            // directory in the union in which we should be creating.
            //
            // The channel staying behind is c, the one moving forward is
            // cnew.
            var m: ?*Mhead = null;
            var cnew: ?*Chan = null;
            if (create(cp.*, &cnew, &m, nomount, e.elems.?[@intCast(e.nelems - 1)], omode, perm)) {
                putmhead(m);
                cclose(cp.*);
                const nc = cnew.?;
                cp.* = nc;
                nc.path = addelem(nc.path, e.elems.?[@intCast(e.nelems - 1)], null);
                return;
            } else |err| {
                // create failed
                if (cnew) |x| cclose(x);
                putmhead(m);
                if (omode & c.OEXCL != 0)
                    return err;
                // save error
                const p = up();
                const createerr = p.errstr;
                var tmperrbuf: [port.ERRMAX]u8 = undefined;
                p.errstr = &tmperrbuf;
                // note: we depend that walk does not error
                const r = walk(cp, last, 1, nomount, null) catch -1;
                p.errstr = createerr;
                if (r < 0)
                    return port.kerror(createerr); // report true error
                omode |= c.OTRUNC;
                return open(cp, nomount, amode, omode);
            }
        },

        else => port.kpanic("unknown namec access %d", .{amode}),
    }
}

/// namec's create of the last name in *cnew, a unique copy of c, or of
/// the creatable directory in the union c is a mount point of (m). An
/// error leaves what it made in cnew and m, for namec to put back.
fn create(ch: *Chan, cnew: *?*Chan, m: *?*Mhead, nomount: bool, name: [*:0]const u8, omode: c_int, perm: c_uint) Error!void {
    if (!nomount and findmount(cnew, m, ch.type, @bitCast(ch.dev), ch.qid)) {
        cnew.* = try createdir(cnew.*.?, m.*.?);
    } else {
        cnew.* = ch;
        _ = incref(&ch.ref);
    }

    // We need our own copy of the Chan because we're about to send a
    // create, which will move it. Once we have our own copy, we can fix
    // the name, which might be wrong if findmount gave us a new Chan.
    cnew.* = try cunique(cnew.*.?);
    const nc = cnew.*.?;
    pathclose(nc.path);
    nc.path = ch.path;
    _ = incref(&nc.path.*.ref);

    cnew.* = try dev.create(dev.of(nc), nc, name, omode & ~@as(c_int, c.OEXCL | c.OCEXEC), perm);
    if (omode & c.ORCLOSE != 0)
        cnew.*.?.flag |= c.CRCLOSE;
}

/// namec's Open: c's mount point crossed, a unique copy of it, and (for
/// an open) the device's open of it.
fn open(cp: **Chan, nomount: bool, amode: c_int, omode: c_int) Error!void {
    // save&update the name; domount might change c
    var path: *Path = cp.*.path;
    _ = incref(&path.ref);
    var m: ?*Mhead = null;
    {
        errdefer pathclose(path);
        if (!nomount)
            _ = domount(cp, &m, &path);
        // our own copy to open or remove
        cp.* = cunique(cp.*) catch |err| {
            putmhead(m);
            return err;
        };
    }

    // now it's our copy anyway, we can put the name back
    pathclose(cp.*.path);
    cp.*.path = path;

    // record whether c is on a mount point
    cp.*.ismtpt = @intFromBool(m != null);

    switch (amode) {
        c.Aaccess, c.Aremove => putmhead(m),

        c.Aopen, c.Acreate, c.Aunmount => {
            // only save the mount head if it's a multiple element union
            if (m) |h| {
                sync.rlock(&h.lock);
                if (h.mount != null and h.mount.*.next != null) {
                    cp.*.umh = h;
                    sync.runlock(&h.lock);
                } else {
                    sync.runlock(&h.lock);
                    putmhead(h);
                }
            }

            // save registers else error() in open has wrong value of c
            // saved
            saveregisters();

            // h9: a link a Linux open didn't follow
            // (design/epoch-0/linux-symlinks.md)
            if ((cp.*.qid.type & Qtsymlink) != 0 and h9_fs_linkwalk() != 0)
                return port.kerror("too many symbolic links");
            cp.* = try dev.open(dev.of(cp.*), cp.*, omode & ~@as(c_int, c.OCEXEC));
            if (omode & c.ORCLOSE != 0)
                cp.*.flag |= c.CRCLOSE;
        },
        else => {},
    }
}

/// name is valid. skip leading / and ./ as much as possible
pub fn skipslash(name_: [*:0]u8) [*:0]u8 {
    var name = name_;
    while (name[0] == '/' or (name[0] == '.' and (name[1] == 0 or name[1] == '/')))
        name += 1;
    return name;
}

pub var isfrog: [256]u8 = blk: {
    var t: [256]u8 = @splat(0);
    for (0..32) |i| t[i] = 1;
    t['/'] = 1;
    t[0x7f] = 1;
    break :blk t;
};

/// Check that the name
///  a) is in valid memory.
///  b) is shorter than 2^16 bytes, so it can fit in a 9P string field.
///  c) contains no frogs.
/// The first byte is known to be addressible by the requester, so the
/// routine works for kernel and user memory both. The parameter slashok
/// flags whether a slash character is an error or a valid character.
///
/// The parameter dup flags whether the string should be copied out of
/// user space before being scanned the second time. (Otherwise a
/// malicious thread could remove the NUL, causing us to access unchecked
/// addresses.)
fn validname0(aname_: [*:0]const u8, slashok: bool, dup: bool, pc: usize) Error!?[*:0]u8 {
    var aname = aname_;
    var name = aname;
    const ename: [*c]const u8 = @ptrCast(c.memchr(name, 0, 1 << 16));

    if (ename == null or @intFromPtr(ename) - @intFromPtr(name) >= (1 << 16))
        return port.kerror(&port.Etoolong);

    var s: ?[*:0]u8 = null;
    if (dup) {
        const n = @intFromPtr(ename) - @intFromPtr(name);
        const d: [*]u8 = @ptrCast(c.smalloc(@intCast(n + 1)));
        @memcpy(d[0..n], name[0..n]);
        d[n] = 0;
        s = @ptrCast(d);
        aname = s.?;
        name = s.?;
        c.setmalloctag(d, pc);
    }

    while (name[0] != 0) {
        // all characters above '~' are ok
        const ch = name[0];
        if (ch >= c.Runeself) {
            var r: c.Rune = undefined;
            name += @intCast(c.chartorune(&r, @constCast(name)));
        } else {
            if (isfrog[ch] != 0)
                if (!slashok or ch != '/') {
                    const p = up();
                    _ = c.snprint(&p.genbuf, p.genbuf.len, @constCast("%s: %q"), &port.Ebadchar, aname);
                    c.free(s);
                    return port.kerror(@ptrCast(&p.genbuf));
                };
            name += 1;
        }
    }
    return s;
}

pub fn validname(aname: [*:0]const u8, slashok: bool) Error!void {
    _ = try validname0(aname, slashok, false, @returnAddress());
}

pub fn validnamedup(aname: [*:0]const u8, slashok: bool) Error![*:0]u8 {
    return (try validname0(aname, slashok, true, @returnAddress())).?;
}

fn validnamedupAt(aname: [*:0]const u8, slashok: bool, pc: usize) Error!?[*:0]u8 {
    return validname0(aname, slashok, true, pc);
}

pub fn isdir(ch: *Chan) Error!void {
    if (ch.qid.type & c.QTDIR != 0)
        return;
    return port.kerror(&port.Enotdir);
}

const DIRSIZE = c.STATFIXLEN + 16 * 4; // enough for encoded stat buf + some reasonable strings

pub fn dirchanstat(ch: *Chan) Error!*c.Dir {
    var nd: usize = DIRSIZE;
    var i: usize = 0;
    while (i < 2) : (i += 1) { // should work by the second try
        const d: *c.Dir = @ptrCast(@alignCast(c.smalloc(@intCast(@sizeOf(c.Dir) + @as(usize, c.BIT16SZ) + nd))));
        errdefer c.free(d);
        const buf: [*]u8 = @ptrCast(@as([*]c.Dir, @ptrCast(d)) + 1);
        const n = try dev.stat(dev.of(ch), ch, buf, @intCast(@as(usize, c.BIT16SZ) + nd));
        if (n < c.BIT16SZ)
            return port.kerror(&port.Eshortstat);
        nd = @as(u16, buf[0]) | @as(u16, buf[1]) << 8; // upper bound on size of Dir + strings
        if (nd <= n) {
            if (c.convM2D(buf, @intCast(n), d, @ptrCast(buf)) == 0)
                return port.kerror(&port.Eshortstat);
            return d;
        }
        // else sizeof(Dir)+BIT16SZ+nd is plenty
        c.free(d);
    }
    return port.kerror(&port.Eshortstat);
}

// The C kernel's names, with its semantics: a function that fails raises
// its error.

fn c_chanpath(ch: ?*Chan) callconv(.c) [*:0]const u8 {
    return chanpath(ch);
}
fn c_isdotdot(p: [*:0]const u8) callconv(.c) c_int {
    return @intFromBool(isdotdot(p));
}
fn c_incref(r: *Ref) callconv(.c) c_int {
    return incref(r);
}
fn c_decref(r: *Ref) callconv(.c) c_int {
    return decrefAt(r, @returnAddress());
}
fn c_kstrcpy(s: [*]u8, t: [*:0]const u8, ns: c_int) callconv(.c) void {
    kstrcpy(s, t, ns);
}
fn c_emptystr(s: ?[*:0]const u8) callconv(.c) c_int {
    return @intFromBool(emptystr(s));
}
fn c_kstrdup(p: *?[*:0]u8, s: [*:0]const u8) callconv(.c) void {
    kstrdupAt(p, s, @returnAddress());
}
fn c_chandevreset() callconv(.c) void {
    chandevreset() catch |e| port.raise(e);
}
fn c_chandevinit() callconv(.c) void {
    chandevinit() catch |e| port.raise(e);
}
fn c_chandevshutdown() callconv(.c) void {
    chandevshutdown() catch |e| port.raise(e);
}
fn c_newchan() callconv(.c) *Chan {
    return newchan();
}
fn c_newpath(s: [*:0]const u8) callconv(.c) *Path {
    return newpathAt(s, @returnAddress());
}
fn c_pathclose(p: ?*Path) callconv(.c) void {
    pathclose(p);
}
fn c_chanfree(ch: *Chan) callconv(.c) void {
    chanfree(ch);
}
fn c_cclose(ch: ?*Chan) callconv(.c) void {
    ccloseAt(ch, @returnAddress());
}
fn c_cunique(ch: *Chan) callconv(.c) *Chan {
    return cunique(ch) catch |e| port.raise(e);
}
fn c_eqqid(a: Qid, b: Qid) callconv(.c) c_int {
    return @intFromBool(eqqid(a, b));
}
fn c_eqchan(a: *Chan, b: *Chan, skipvers: c_int) callconv(.c) c_int {
    return @intFromBool(eqchan(a, b, skipvers != 0));
}
fn c_eqchantdqid(a: *Chan, @"type": c_int, devn: c_int, qid: Qid, skipvers: c_int) callconv(.c) c_int {
    return @intFromBool(eqchantdqid(a, @"type", devn, qid, skipvers != 0));
}
fn c_newmhead(from: *Chan) callconv(.c) *Mhead {
    return newmheadAt(from, @returnAddress()) catch |e| port.raise(e);
}
fn c_putmhead(m: ?*Mhead) callconv(.c) void {
    putmhead(m);
}
fn c_cmount(new: *Chan, old: *Chan, flag: c_int, spec: ?[*:0]const u8) callconv(.c) c_int {
    return cmount(new, old, flag, spec) catch |e| port.raise(e);
}
fn c_cunmount(mnt: *Chan, mounted: ?*Chan) callconv(.c) void {
    cunmount(mnt, mounted) catch |e| port.raise(e);
}
fn c_cclone(ch: ?*Chan) callconv(.c) *Chan {
    const cc = ch orelse port.kpanic("cclone: %#p", .{@returnAddress()});
    return ccloneAt(cc, @returnAddress()) catch |e| port.raise(e);
}
fn c_findmount(cp: *?*Chan, mp: ?*?*Mhead, @"type": c_int, devn: c_int, qid: Qid) callconv(.c) c_int {
    return @intFromBool(findmount(cp, mp, @"type", devn, qid));
}
fn c_walk(cp: **Chan, names: [*]const [*:0]const u8, nnames: c_int, nomount: c_int, nerror: ?*c_int) callconv(.c) c_int {
    return walk(cp, names, nnames, nomount != 0, nerror) catch |e| port.raise(e);
}
fn c_createdir(ch: *Chan, m: *Mhead) callconv(.c) *Chan {
    return createdir(ch, m) catch |e| port.raise(e);
}
fn c_saveregisters() callconv(.c) void {
    saveregisters();
}
fn c_namelenerror(aname: [*:0]const u8, len: c_int, err: [*:0]const u8) callconv(.c) void {
    port.raise(namelenerror(aname, len, err));
}
fn c_namec(aname: [*:0]const u8, amode: c_int, omode: c_int, perm: c_uint) callconv(.c) *Chan {
    return namec(aname, amode, omode, perm) catch |e| port.raise(e);
}
fn c_skipslash(name: [*:0]u8) callconv(.c) [*:0]u8 {
    return skipslash(name);
}
fn c_validname(aname: [*:0]const u8, slashok: c_int) callconv(.c) void {
    _ = validname0(aname, slashok != 0, false, @returnAddress()) catch |e| port.raise(e);
}
fn c_validnamedup(aname: [*:0]const u8, slashok: c_int) callconv(.c) [*:0]u8 {
    return (validname0(aname, slashok != 0, true, @returnAddress()) catch |e| port.raise(e)).?;
}
fn c_isdir(ch: *Chan) callconv(.c) void {
    isdir(ch) catch |e| port.raise(e);
}
fn c_dirchanstat(ch: *Chan) callconv(.c) *c.Dir {
    return dirchanstat(ch) catch |e| port.raise(e);
}

pub fn exportC() void {
    @export(&c_chanpath, .{ .name = "chanpath" });
    @export(&c_isdotdot, .{ .name = "isdotdot" });
    @export(&c_incref, .{ .name = "incref" });
    @export(&c_decref, .{ .name = "decref" });
    @export(&c_kstrcpy, .{ .name = "kstrcpy" });
    @export(&c_emptystr, .{ .name = "emptystr" });
    @export(&c_kstrdup, .{ .name = "kstrdup" });
    @export(&c_chandevreset, .{ .name = "chandevreset" });
    @export(&c_chandevinit, .{ .name = "chandevinit" });
    @export(&c_chandevshutdown, .{ .name = "chandevshutdown" });
    @export(&c_newchan, .{ .name = "newchan" });
    @export(&c_newpath, .{ .name = "newpath" });
    @export(&c_pathclose, .{ .name = "pathclose" });
    @export(&c_chanfree, .{ .name = "chanfree" });
    @export(&c_cclose, .{ .name = "cclose" });
    @export(&c_cunique, .{ .name = "cunique" });
    @export(&c_eqqid, .{ .name = "eqqid" });
    @export(&c_eqchan, .{ .name = "eqchan" });
    @export(&c_eqchantdqid, .{ .name = "eqchantdqid" });
    @export(&c_newmhead, .{ .name = "newmhead" });
    @export(&c_putmhead, .{ .name = "putmhead" });
    @export(&c_cmount, .{ .name = "cmount" });
    @export(&c_cunmount, .{ .name = "cunmount" });
    @export(&c_cclone, .{ .name = "cclone" });
    @export(&c_findmount, .{ .name = "findmount" });
    @export(&c_walk, .{ .name = "walk" });
    @export(&c_createdir, .{ .name = "createdir" });
    @export(&c_saveregisters, .{ .name = "saveregisters" });
    @export(&c_namelenerror, .{ .name = "namelenerror" });
    @export(&c_namec, .{ .name = "namec" });
    @export(&c_skipslash, .{ .name = "skipslash" });
    @export(&isfrog, .{ .name = "isfrog" });
    @export(&c_validname, .{ .name = "validname" });
    @export(&c_validnamedup, .{ .name = "validnamedup" });
    @export(&c_isdir, .{ .name = "isdir" });
    @export(&c_dirchanstat, .{ .name = "dirchanstat" });
}

const testing = std.testing;
const kt = port.testing;

test "kstrcpy truncates with an ellipsis at a UTF-8 boundary [kernel-port]" {
    var buf: [8]u8 = undefined;
    kstrcpy(&buf, "short", buf.len);
    try testing.expectEqualStrings("short", std.mem.sliceTo(&buf, 0));
    kstrcpy(&buf, "much too long", buf.len);
    try testing.expectEqualStrings("muc...", std.mem.sliceTo(&buf, 0));
    // "ab" then a two-byte rune that the cut would split.
    kstrcpy(&buf, "abé€€€", buf.len);
    try testing.expectEqualStrings("ab...", std.mem.sliceTo(&buf, 0));
}

test "a name is cut into elements, and one too long or with a control character is refused [kernel-port]" {
    _ = try kt.begin();
    var e: Elemlist = .{ .aname = "" };
    parsename("/a//b/./c/", &e);
    defer {
        c.free(e.name);
        c.free(@ptrCast(e.elems));
        c.free(@ptrCast(e.off));
    }
    try testing.expectEqual(3, e.nelems);
    try testing.expectEqualStrings("a", std.mem.span(e.elems.?[0]));
    try testing.expectEqualStrings("b", std.mem.span(e.elems.?[1]));
    try testing.expectEqualStrings("c", std.mem.span(e.elems.?[2]));
    try testing.expect(e.mustbedir);

    try validname("ok/name", true);
    try testing.expectError(error.Kernel, validname("a/b", false));
    try testing.expectError(error.Kernel, validname("a\x7fb", true));
    const long = try testing.allocator.allocSentinel(u8, 1 << 16, 0);
    defer testing.allocator.free(long);
    @memset(long, 'a');
    try testing.expectError(error.Kernel, validname(long, true));
    try testing.expectEqualStrings(std.mem.span(@as([*:0]const u8, &port.Etoolong)), kt.errstr());
}

test "fuzz: namec takes any path, and fails or walks with nothing left over [kernel-port]" {
    const sysfile = @import("sysfile.zig");
    _ = try kt.namespace();
    _ = try sysfile.bind("#|", "/mnt", c.MAFTER);
    try testing.fuzz({}, struct {
        fn one(_: void, smith: *testing.Smith) anyerror!void {
            var buf: [300:0]u8 = undefined;
            const n = smith.slice(buf[0..buf.len]);
            buf[n] = 0;
            const amodes = [_]c_int{ c.Aaccess, c.Atodir, c.Aopen, c.Abind, c.Amount };
            const amode = amodes[smith.index(amodes.len)];
            const p = up();
            const ch = namec(&buf, amode, c.OREAD, 0) catch {
                try testing.expect(p.errstr[0] != 0);
                try testing.expectEqual(0, p.nerrlab);
                return;
            };
            try testing.expectEqual(0, p.nerrlab);
            try testing.expect(ch.ref.ref >= 1);
            cclose(ch);
        }
    }.one, .{ .corpus = &.{
        "/",                                                   "#/", "#|",        "#|/data",
        "/mnt/../mnt/./data1",                                 "..", "/../../..", "#/mnt/factotum/..",
        "/mnt/factotum/x/y/z",                                 "#",  "#Z/x",      "/mnt//data//",
        "a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/q/r/s/t/u/v/w/x/y/z",
    } });
}
