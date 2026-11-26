//! h9's kserve.c (design/kernel-port.md): h9's 9P2000 server in the
//! kernel (design/epoch-0/kernel-serve.md). A close translation: the same
//! functions in the same order, with error unions in place of C's error labels.
//! serve's per-connection path (src/machine.zig) hands it a channel that
//! reads and writes whole 9P2000 messages, a #ℓ conversation's data, and
//! it answers them from kernel channels directly, in place of an exportfs
//! guest process.
//!
//! A fid holds a Chan. Twalk clones the fid's channel and walks it with
//! chan.zig's walk(), one name at a time, so the walk crosses mounts as
//! namec's does and each Rwalk qid is the one a stat there would give
//! (the mounted directory's, for a mount point). An unopened fid's
//! channel is left before a mount point, as walk() leaves it, so .. back
//! across a mount is walk()'s own. Topen, Tstat and Twstat cross the
//! mount point as namec's Aopen and Aaccess do, and Tcreate finds a
//! union's MCREATE member with chan.zig's createdir, as namec's Acreate
//! does. Reads of a directory go through sysfile.zig's chanread, so
//! unions and mount points read as through read(2).
//!
//! Each connection has a reader kproc, which parses messages and hands
//! them to workers: up to Nworker kprocs (coroutines on the web host),
//! started as requests need them and kept until the connection ends, so
//! a request that blocks holds up only its worker. Past that, requests
//! wait in a queue of up to Maxqueue, and past that the reader stops
//! reading. Tflush is answered by the reader: a request still queued is
//! dropped and Rflush sent at once; one a worker is running is
//! interrupted, as a note interrupts a system call, and its Rflush
//! follows the worker's reply.
//!
//! The workers run as the process that started serving (serve's server
//! Proc): its namespace, its user, a record in its machine
//! (h9_kprocshare), and its plan and pages (h9_kern_locals), so devfs's
//! checks, the write policy and --read-deny apply as to exportfs's system
//! calls. Their slash is the attach root, marked (h9_fs_markroot) under
//! --serve-root so walkl's h9_fs_atroot stops .. there. A connection's
//! source of namespaces is an interface (Ksource), for namespace-kernel's
//! namespaces by attach name; serve's is the server Proc's.
//!
//! kserve parses untrusted input in the kernel: convM2S bounds-checks
//! each message, and a message it can't parse ends the connection.
//!
//! h9: a client that offers `9P2000.ready` in its Tversion gets it, and
//! may send Tready (design/file-interface.md, Part 1): tag fid[4]
//! events[4], which a worker answers with Rready events[4] once the
//! fid's channel has one of the events (Linux's poll bits, through the
//! device switch's `ready` and `watch`), or at once with the bit Rnow.
//! A Tflush ends a waiting one, as it does a read.

const std = @import("std");
const port = @import("port.zig");
const sync = @import("sync.zig");
const dev = @import("dev.zig");
const chan = @import("chan.zig");
const pgrp = @import("pgrp.zig");
const sysfile = @import("sysfile.zig");
const c = port.c;
const up = port.up;
const Error = port.Error;

const Chan = c.Chan;
const Mhead = c.Mhead;
const Fcall = c.Fcall;
const Proc = c.Proc;

// proc.c
extern fn h9_kprocsrc() ?*anyopaque;
extern fn h9_kprocput(hp: ?*anyopaque) void;
extern fn h9_kprocshare(hp: ?*anyopaque, text: [*:0]const u8) c_int;
extern fn h9_kprocunshare() void;
// linux.zig, or nstab.c's in the namespace kernel
extern fn h9_fs_markroot(ch: *Chan, lx: c_int) void;
// src/kern.zig: the calling thread's plan, pages and CPUs
extern fn h9_kern_locals(save: c_int, slots: *[4]usize) void;

const Maxmsg = 8192 + c.IOHDRSZ; // as exportfs's
const Nworker = 32; // requests run at once, per connection
const Maxqueue = 64; // requests waiting for a worker
const Maxfid = 4096; // fids per connection
const Nfidhash = 64;

const NOFID: u32 = 0xFFFFFFFF;

/// A namespace a fid is served from: a Pgrp and the root .. stops at. A
/// named source's (h9_kserve_kns) calls put(arg) when its last fid goes.
const Kns = extern struct {
    ref: c.Ref,
    pg: *c.Pgrp,
    slash: *Chan,
    put: ?*const fn (?*anyopaque) callconv(.c) void,
    arg: ?*anyopaque,
};

const Kfid = extern struct {
    next: ?*Kfid,
    fid: u32,
    ref: c_int, // the table's, and each request's; under the conn's lk
    c: *Chan, // under lk: a walk or open replaces it
    wc: ?*Chan, // once open, the channel it was walked to, or nil
    open: c_int,
    mode: c_int, // the open mode
    ns: *Kns,
};

const Kreq = extern struct {
    next: ?*Kreq,
    f: Fcall,
    buf: ?[*]u8, // the message f points into
    flushed: c_int, // a Tflush interrupted it
    done: c_int, // its reply is going; no more interrupts
    ftag: [8]u16, // the flushes' tags, answered after it
    nftag: c_int,
};

const Kworker = extern struct {
    next: ?*Kworker, // on the conn's list
    inext: ?*Kworker, // on the idle list
    k: *Kconn,
    p: ?*Proc, // set by the worker; nil once it's leaving
    r: c.Rendez,
    req: ?*Kreq, // handed to it while idle
    cur: ?*Kreq, // the request it's running
    out: [*]u8, // reply buffer
    data: [*]u8, // read buffer
};

const Kconn = extern struct {
    lk: c.Lock,
    ref: c.Ref, // the reader's, each worker's
    next: ?*Kconn, // on the server's list; under the server's lk
    s: *Kserver,
    c: *Chan, // the connection
    wlk: c.QLock, // serializes replies
    msize: u32,
    dead: c_int, // the connection is ending; under lk

    reader: ?*Proc, // under lk; nil once it's leaving
    rr: c.Rendez, // the reader waits here while the queue is full
    workers: ?*Kworker,
    idle: ?*Kworker,
    nworker: c_int,
    qhead: ?*Kreq,
    qtail: *?*Kreq,
    nqueue: c_int,

    fids: [Nfidhash]?*Kfid,
    nfid: c_int,

    aname: ?[*:0]u8, // the attach name the host fixed, or nil

    xready: c_int, // h9: the client's version took Tready
};

// h9: readiness (design/file-interface.md), devmnt.zig's.
const Vready = c.VERSION9P ++ ".ready";
const Tready = 160;
const Rnow: u32 = 0x40000000;

/// Where attaches get their namespace (design/epoch-0/kernel-serve.md,
/// Namespaces).
const Ksource = struct {
    lookup: *const fn (*Kserver, [*:0]const u8) ?*Kns,
};

const Named = *const fn ([*:0]const u8) callconv(.c) ?*anyopaque;

const Kserver = extern struct {
    lk: c.Lock,
    conns: ?*Kconn,
    nconn: c_int,
    closing: c_int,
    readonly: c_int,
    ns: ?*Kns, // the plan's namespace
    src: *const Ksource,
    named: ?Named, // a named source's lookup
    hp: ?*anyopaque, // the starter's record, for the workers'
    locals: [4]usize,
    user: [c.KNAMELEN]u8,
    ended: ?*const fn (?*anyopaque) callconv(.c) void,
    arg: ?*anyopaque,
    r: c.Rendez,
};

const Enofid = "unknown fid";
const Efidinuse = "fid in use";
const Etoomanyfids = "too many fids";
const Eopen = "fid already open";
const Enotopen = "fid not open";
const Ebadmsg = "unexpected 9P message";
const Enoauth = "kserve: authentication not required";
const Ereadonly = "file system read only"; // exportfs -R's

fn alloc(comptime T: type) ?*T {
    return @ptrCast(@alignCast(c.mallocz(@sizeOf(T), 1)));
}

/// The source with only the plan's namespace: every attach gets it.
fn planlookup(s: *Kserver, aname: [*:0]const u8) ?*Kns {
    _ = aname;
    _ = chan.incref(&s.ns.?.ref);
    return s.ns;
}

const plansource: Ksource = .{ .lookup = planlookup };

/// Named namespaces (namespace-kernel): the attach name picks one.
fn namedlookup(s: *Kserver, aname: [*:0]const u8) ?*Kns {
    return @ptrCast(@alignCast(s.named.?(aname)));
}

const namedsource: Ksource = .{ .lookup = namedlookup };

fn nsput(ns_: ?*Kns) void {
    const ns = ns_ orelse return;
    if (chan.decref(&ns.ref) != 0)
        return;
    pgrp.closepgrp(ns.pg);
    chan.cclose(ns.slash);
    if (ns.put) |put|
        put(ns.arg);
    c.free(ns);
}

/// The calling kproc becomes one of the server's: its machine, user,
/// plan and pages, no fds, and the server's namespace.
fn kpinit(s: *Kserver, text: [*:0]const u8) void {
    h9_kern_locals(0, &s.locals);
    _ = h9_kprocshare(s.hp, text);
    const p = up();
    const user: [*]u8 = @ptrCast(&p.user);
    _ = c.strecpy(user, user + p.user.len, @ptrCast(&s.user));
    const f: ?*c.Fgrp = p.fgrp;
    p.fgrp = pgrp.dupfgrp(null) catch port.kpanic("kserve: %s", .{p.errstr});
    if (f) |ff|
        pgrp.closefgrp(ff);
}

/// Runs the calling worker in ns, if it isn't already.
fn usens(ns: *Kns) void {
    const p = up();
    if (p.pgrp != ns.pg) {
        const pg: ?*c.Pgrp = p.pgrp;
        _ = chan.incref(&ns.pg.ref);
        p.pgrp = ns.pg;
        if (pg) |g|
            pgrp.closepgrp(g);
    }
    if (p.slash != ns.slash) {
        var ch: ?*Chan = p.slash;
        _ = chan.incref(&ns.slash.ref);
        p.slash = ns.slash;
        if (ch) |x|
            chan.cclose(x);
        ch = p.dot;
        _ = chan.incref(&ns.slash.ref);
        p.dot = ns.slash;
        if (ch) |x|
            chan.cclose(x);
    }
}

/// Leaves the server's state, before pexit.
fn kpexit() noreturn {
    h9_kprocunshare();
    const p = up();
    if (@as(?*c.Pgrp, p.pgrp)) |g| {
        pgrp.closepgrp(g);
        p.pgrp = null;
    }
    if (@as(?*c.Fgrp, p.fgrp)) |f| {
        pgrp.closefgrp(f);
        p.fgrp = null;
    }
    c.pexit(@constCast(""), 0);
    unreachable;
}

// Fids. The table is under the connection's lk.

fn fidslot(k: *Kconn, fid: u32) *?*Kfid {
    var l: *?*Kfid = &k.fids[fid % Nfidhash];
    while (l.*) |f| : (l = &f.next) {
        if (f.fid == fid)
            break;
    }
    return l;
}

/// The fid, referenced, or an error.
fn fidget(k: *Kconn, fid: u32) Error!*Kfid {
    c.lock(&k.lk);
    const f = fidslot(k, fid).*;
    if (f) |x|
        x.ref += 1;
    c.unlock(&k.lk);
    return f orelse port.kerror(Enofid);
}

fn fidput(k: *Kconn, f: *Kfid) void {
    c.lock(&k.lk);
    f.ref -= 1;
    const last = f.ref == 0;
    c.unlock(&k.lk);
    if (!last)
        return;
    chan.cclose(f.c);
    if (f.wc) |wc|
        chan.cclose(wc);
    nsput(f.ns);
    c.free(f);
}

/// Adds a fid for ch in ns, taking ch's reference.
fn fidnew(k: *Kconn, fid: u32, ch: *Chan, ns: *Kns) Error!void {
    const f = alloc(Kfid) orelse {
        chan.cclose(ch);
        return port.kerror(&port.Enomem);
    };
    f.fid = fid;
    f.c = ch;
    f.ref = 1;
    _ = chan.incref(&ns.ref);
    f.ns = ns;
    c.lock(&k.lk);
    const l = fidslot(k, fid);
    if (l.* != null or k.nfid >= Maxfid) {
        const inuse = l.* != null;
        c.unlock(&k.lk);
        f.ref = 0;
        chan.cclose(ch);
        nsput(ns);
        c.free(f);
        return port.kerror(if (inuse) Efidinuse else Etoomanyfids);
    }
    l.* = f;
    k.nfid += 1;
    c.unlock(&k.lk);
}

/// Takes the fid out of the table; the caller's reference keeps it.
fn fiddel(k: *Kconn, f: *Kfid) void {
    c.lock(&k.lk);
    const l = fidslot(k, f.fid);
    const had = l.* == f;
    if (had) {
        l.* = f.next;
        k.nfid -= 1;
    }
    c.unlock(&k.lk);
    if (had)
        fidput(k, f);
}

/// The fid's channel, referenced.
fn fidchan(k: *Kconn, f: *Kfid) *Chan {
    c.lock(&k.lk);
    const ch = f.c;
    _ = chan.incref(&ch.ref);
    c.unlock(&k.lk);
    return ch;
}

/// The channel a walk from the fid starts at, referenced: its own, or
/// once it's open, the one it was walked to. 9P2000 doesn't walk an open
/// fid, but 9P2000.L does (dotl's translator passes such walks on), and
/// exportfs allowed it.
fn fidwalkchan(k: *Kconn, f: *Kfid) Error!*Chan {
    c.lock(&k.lk);
    const ch: ?*Chan = if (f.open != 0) f.wc else f.c;
    if (ch) |x|
        _ = chan.incref(&x.ref);
    c.unlock(&k.lk);
    return ch orelse port.kerror(Eopen);
}

/// Replaces the fid's channel with ch, and its walked one with wc,
/// taking their references.
fn fidset(k: *Kconn, f: *Kfid, ch: *Chan, wc: ?*Chan, open: c_int, mode: c_int) void {
    c.lock(&k.lk);
    const o = f.c;
    const ow = f.wc;
    f.c = ch;
    f.wc = wc;
    f.open = open;
    f.mode = mode;
    c.unlock(&k.lk);
    chan.cclose(o);
    if (ow) |x|
        chan.cclose(x);
}

fn findmount(cp: *?*Chan, mp: ?*?*Mhead, ch: *Chan) bool {
    return chan.findmount(cp, mp, ch.type, @bitCast(ch.dev), ch.qid);
}

/// The channel a stat or open of ch sees: what's mounted on ch, with
/// ch's name, as namec's domount gives it, or ch. Referenced; with mp,
/// the mount's head too, or nil.
fn crossmount(ch: *Chan, mp: ?*?*Mhead) Error!*Chan {
    var nc_: ?*Chan = null;
    var m: ?*Mhead = null;
    if (mp) |p|
        p.* = null;
    if (!findmount(&nc_, &m, ch)) {
        _ = chan.incref(&ch.ref);
        return ch;
    }
    const nc = chan.cunique(nc_.?) catch |e| {
        chan.cclose(nc_);
        chan.putmhead(m);
        return e;
    };
    chan.pathclose(nc.path);
    nc.path = ch.path;
    _ = chan.incref(&ch.path.*.ref);
    nc.ismtpt = 1;
    if (mp) |p|
        p.* = m
    else
        chan.putmhead(m);
    return nc;
}

/// The qid a stat of ch gives.
fn statqid(ch: *Chan) c.Qid {
    var nc: ?*Chan = null;
    var m: ?*Mhead = null;
    if (!findmount(&nc, &m, ch))
        return ch.qid;
    const q = nc.?.qid;
    chan.cclose(nc);
    chan.putmhead(m);
    return q;
}

fn writemode(mode: c_int) bool {
    return (mode & 3) == c.OWRITE or (mode & 3) == c.ORDWR or (mode & (c.OTRUNC | c.ORCLOSE)) != 0;
}

fn checkname(name: [*:0]const u8) Error!void {
    if (name[0] == 0 or dev.streq(name, ".") or dev.streq(name, ".."))
        return port.kerror(&port.Ebadarg);
    try chan.validname(name, false);
}

fn iohdrmax(k: *Kconn) u32 {
    return k.msize - c.IOHDRSZ;
}

// The requests. An error is the Rerror.

fn rattach(k: *Kconn, t: *Fcall, r: *Fcall) Error!void {
    if (t.afid != NOFID)
        return port.kerror(Enoauth);
    // A connection the host gave an attach name attaches only to that.
    const ns_ = if (k.aname) |an| blk: {
        if (t.aname[0] != 0 and !dev.streq(t.aname, an))
            return port.kerror("no such namespace");
        break :blk k.s.src.lookup(k.s, an);
    } else k.s.src.lookup(k.s, t.aname);
    const ns = ns_ orelse return port.kerror("no such namespace");
    defer nsput(ns);
    usens(ns);
    const ch = try chan.cclone(ns.slash);
    r.qid = statqid(ch);
    try fidnew(k, t.fid, ch, ns);
}

fn rwalk(k: *Kconn, t: *Fcall, r: *Fcall) Error!void {
    if (t.nwname > c.MAXWELEM)
        return port.kerror(&port.Etoolong);
    const f = try fidget(k, t.fid);
    defer fidput(k, f);
    if (t.newfid != t.fid) {
        c.lock(&k.lk);
        const inuse = fidslot(k, t.newfid).* != null;
        c.unlock(&k.lk);
        if (inuse)
            return port.kerror(Efidinuse);
    }
    if (f.open != 0 and t.newfid == t.fid)
        return port.kerror(Eopen);
    usens(f.ns);
    var ch = try fidwalkchan(k, f);
    {
        errdefer chan.cclose(ch);
        r.nwqid = 0;
        var i: usize = 0;
        while (i < t.nwname) : (i += 1) {
            var name: [*:0]const u8 = t.wname[i];
            if (dev.streq(name, ".")) {
                r.wqid[i] = statqid(ch);
                r.nwqid += 1;
                continue;
            }
            if (!dev.streq(name, "..") and (name[0] == 0 or std.mem.indexOfScalar(u8, std.mem.span(name), '/') != null)) {
                if (i == 0)
                    return port.kerror(&port.Enonexist);
                break;
            }
            if (try chan.walk(&ch, @ptrCast(&name), 1, false, null) < 0) {
                if (i == 0)
                    return error.Kernel; // the walk's error, in errstr
                break;
            }
            r.wqid[i] = statqid(ch);
            r.nwqid += 1;
        }
    }
    if (r.nwqid < t.nwname)
        chan.cclose(ch)
    else if (t.newfid == t.fid)
        fidset(k, f, ch, null, 0, 0)
    else
        try fidnew(k, t.newfid, ch, f.ns);
}

fn ropen(k: *Kconn, t: *Fcall, r: *Fcall) Error!void {
    const mode: c_int = t.mode;
    _ = try sysfile.openmode(@bitCast(mode));
    if (k.s.readonly != 0 and writemode(mode))
        return port.kerror(Ereadonly);
    const f = try fidget(k, t.fid);
    defer fidput(k, f);
    if (f.open != 0)
        return port.kerror(Eopen);
    usens(f.ns);
    const wc = fidchan(k, f);
    errdefer chan.cclose(wc);
    var m: ?*Mhead = null;
    var ch = try crossmount(wc, &m);
    // As namec's Aopen: our own copy, with a union's head kept for
    // reads.
    {
        errdefer {
            chan.cclose(ch);
            chan.putmhead(m);
        }
        ch = try chan.cunique(ch);
        if (m) |um| {
            sync.rlock(&um.lock);
            if (@as(?*c.Mount, um.mount)) |mt| if (mt.next != null) {
                ch.umh = um;
                m = null;
            };
            sync.runlock(&um.lock);
        }
    }
    chan.putmhead(m);
    {
        errdefer chan.cclose(ch);
        ch = try dev.open(dev.of(ch), ch, mode & ~@as(c_int, c.OCEXEC));
        if (mode & c.ORCLOSE != 0)
            ch.flag |= c.CRCLOSE;
    }
    r.qid = ch.qid;
    r.iounit = ch.iounit;
    if (r.iounit == 0 or r.iounit > iohdrmax(k))
        r.iounit = iohdrmax(k);
    fidset(k, f, ch, wc, 1, mode);
}

fn rcreate(k: *Kconn, t: *Fcall, r: *Fcall) Error!void {
    const mode: c_int = t.mode;
    _ = try sysfile.openmode(@bitCast(mode));
    if (k.s.readonly != 0)
        return port.kerror(Ereadonly);
    try checkname(t.name);
    const f = try fidget(k, t.fid);
    defer fidput(k, f);
    if (f.open != 0)
        return port.kerror(Eopen);
    usens(f.ns);
    const ch = fidchan(k, f);
    errdefer chan.cclose(ch);
    if ((ch.qid.type & c.QTDIR) == 0)
        return port.kerror(&port.Enotdir);
    // As namec's Acreate: in a union, its MCREATE member.
    var m: ?*Mhead = null;
    var cnew_: ?*Chan = null;
    const cnew = blk: {
        errdefer {
            chan.putmhead(m);
            if (cnew_) |x|
                chan.cclose(x);
        }
        if (findmount(&cnew_, &m, ch))
            cnew_ = try chan.createdir(cnew_.?, m.?)
        else {
            cnew_ = ch;
            _ = chan.incref(&ch.ref);
        }
        cnew_ = try chan.cunique(cnew_.?);
        const x = cnew_.?;
        chan.pathclose(x.path);
        x.path = ch.path;
        _ = chan.incref(&ch.path.*.ref);
        cnew_ = try dev.create(dev.of(x), x, t.name, mode & ~@as(c_int, c.OEXCL | c.OCEXEC), t.perm);
        if (mode & c.ORCLOSE != 0)
            cnew_.?.flag |= c.CRCLOSE;
        break :blk cnew_.?;
    };
    chan.putmhead(m);
    errdefer chan.cclose(cnew);
    // The new file, unopened, for walks from the fid (fidwalkchan).
    var w = try chan.cclone(ch);
    var name: [*:0]const u8 = t.name;
    var wc: ?*Chan = w;
    if ((chan.walk(&w, @ptrCast(&name), 1, false, null) catch |e| {
        chan.cclose(w);
        return e;
    }) < 0) {
        chan.cclose(w);
        wc = null;
    } else wc = w;
    chan.cclose(ch);
    // Its name, for a stat: the walked file's, when the walk found it.
    if (wc) |x| {
        chan.pathclose(cnew.path);
        cnew.path = x.path;
        _ = chan.incref(&x.path.*.ref);
    }
    r.qid = cnew.qid;
    r.iounit = cnew.iounit;
    if (r.iounit == 0 or r.iounit > iohdrmax(k))
        r.iounit = iohdrmax(k);
    fidset(k, f, cnew, wc, 1, mode);
}

fn rread(k: *Kconn, w: *Kworker, t: *Fcall, r: *Fcall) Error!void {
    const f = try fidget(k, t.fid);
    defer fidput(k, f);
    if (f.open == 0)
        return port.kerror(Enotopen);
    if ((f.mode & 3) == c.OWRITE)
        return port.kerror(&port.Eperm);
    usens(f.ns);
    var n: c_int = @bitCast(t.count);
    if (n > iohdrmax(k))
        n = @intCast(iohdrmax(k));
    var off: i64 = t.offset;
    if (off < 0)
        return port.kerror(&port.Enegoff);
    const ch = fidchan(k, f);
    defer chan.cclose(ch);
    if (ch.qid.type & c.QTDIR != 0)
        n = try sysfile.chanread(ch, w.data, n, &off)
    else
        n = try dev.read(dev.of(ch), ch, w.data, n, off);
    r.count = @bitCast(n);
    r.data = w.data;
}

fn rwrite(k: *Kconn, t: *Fcall, r: *Fcall) Error!void {
    const f = try fidget(k, t.fid);
    defer fidput(k, f);
    if (f.open == 0)
        return port.kerror(Enotopen);
    if ((f.mode & 3) != c.OWRITE and (f.mode & 3) != c.ORDWR)
        return port.kerror(&port.Eperm);
    if (t.offset < 0)
        return port.kerror(&port.Enegoff);
    usens(f.ns);
    const ch = fidchan(k, f);
    defer chan.cclose(ch);
    if (ch.qid.type & c.QTDIR != 0)
        return port.kerror(&port.Eisdir);
    r.count = @bitCast(try dev.write(dev.of(ch), ch, t.data, @bitCast(t.count), t.offset));
}

fn rclunk(k: *Kconn, t: *Fcall) Error!void {
    const f = try fidget(k, t.fid);
    fiddel(k, f);
    // The last reference closes the channel, removing it under ORCLOSE.
    usens(f.ns);
    fidput(k, f);
}

fn rremove(k: *Kconn, t: *Fcall) Error!void {
    const f = try fidget(k, t.fid);
    // Tremove clunks the fid, whether or not the remove succeeds.
    fiddel(k, f);
    defer fidput(k, f);
    if (k.s.readonly != 0)
        return port.kerror(Ereadonly);
    usens(f.ns);
    var wc = fidchan(k, f);
    var ch = blk: {
        errdefer chan.cclose(wc);
        const ch = if (f.open != 0) wc else try crossmount(wc, null);
        if (ch != wc) {
            chan.cclose(wc);
            wc = ch;
        }
        // As remove(2): not a mount point.
        if (ch.ismtpt != 0)
            return port.kerror(&port.Eismtpt);
        break :blk ch;
    };
    ch = chan.cunique(ch) catch |e| {
        chan.cclose(ch);
        return e;
    };
    dev.remove(dev.of(ch), ch) catch |e| {
        ch.type = 0; // as sysremove: remove clunked it
        chan.cclose(ch);
        return e;
    };
    ch.type = 0;
    chan.cclose(ch);
}

/// The channel a stat or wstat of f sees, referenced.
fn statchan(k: *Kconn, f: *Kfid) Error!*Chan {
    const wc = fidchan(k, f);
    const ch = if (f.open != 0) wc else crossmount(wc, null) catch |e| {
        chan.cclose(wc);
        return e;
    };
    if (ch != wc)
        chan.cclose(wc);
    return ch;
}

fn rstat(k: *Kconn, w: *Kworker, t: *Fcall, r: *Fcall) Error!void {
    const f = try fidget(k, t.fid);
    defer fidput(k, f);
    usens(f.ns);
    const ch = try statchan(k, f);
    const n = blk: {
        defer chan.cclose(ch);
        const n = try sysfile.chanstat(ch, w.data, @intCast(iohdrmax(k)));
        if (n <= c.BIT16SZ)
            return port.kerror(&port.Eshortstat);
        break :blk n;
    };
    r.stat = w.data;
    r.nstat = @intCast(n);
}

fn rwstat(k: *Kconn, t: *Fcall) Error!void {
    if (k.s.readonly != 0)
        return port.kerror(Ereadonly);
    if (c.statcheck(t.stat, t.nstat) < 0)
        return port.kerror(&port.Ebadstat);
    const f = try fidget(k, t.fid);
    defer fidput(k, f);
    usens(f.ns);
    const ch = try statchan(k, f);
    defer chan.cclose(ch);
    // As wstat(2): a mount point isn't renamed.
    const p = t.stat + c.BIT16SZ + c.BIT16SZ + c.BIT32SZ + c.QIDSZ + c.BIT32SZ + c.BIT32SZ + c.BIT32SZ + c.BIT64SZ;
    const nlen = @as(u16, p[0]) | @as(u16, p[1]) << 8;
    if (ch.ismtpt != 0 and nlen != 0)
        return port.kerror(&port.Eismtpt);
    _ = try dev.wstat(dev.of(ch), ch, t.stat, t.nstat);
}

/// Writes one reply. Errors end the connection.
fn reply(k: *Kconn, r: *Fcall, buf: [*]u8) void {
    var n = c.convS2M(r, buf, k.msize);
    if (n == 0) {
        // too big for msize: an error instead
        r.type = c.Rerror;
        r.ename = @constCast("reply too big");
        n = c.convS2M(r, buf, k.msize);
    }
    sync.qlock(&k.wlk);
    if (k.dead == 0)
        _ = dev.write(dev.of(k.c), k.c, buf, @intCast(n), 0) catch 0;
    sync.qunlock(&k.wlk);
}

fn rflushed(k: *Kconn, q: *Kreq, buf: [*]u8) void {
    var i: usize = 0;
    while (i < q.nftag) : (i += 1) {
        var r = std.mem.zeroes(Fcall);
        r.type = c.Rflush;
        r.tag = q.ftag[i];
        reply(k, &r, buf);
    }
}

fn request(k: *Kconn, w: *Kworker, t: *Fcall, r: *Fcall) Error!void {
    return switch (t.type) {
        c.Tattach => rattach(k, t, r),
        c.Twalk => rwalk(k, t, r),
        c.Topen => ropen(k, t, r),
        c.Tcreate => rcreate(k, t, r),
        c.Tread => rread(k, w, t, r),
        c.Twrite => rwrite(k, t, r),
        c.Tclunk => rclunk(k, t),
        c.Tremove => rremove(k, t),
        c.Tstat => rstat(k, w, t, r),
        c.Twstat => rwstat(k, t),
        Tready => rready(k, t, r),
        else => port.kerror(Ebadmsg),
    };
}

/// Tready: the events of t.count ready on the fid's channel, waiting
/// until one is unless Rnow asks for an answer now. Into r.count.
fn rready(k: *Kconn, t: *Fcall, r: *Fcall) Error!void {
    const f = try fidget(k, t.fid);
    defer fidput(k, f);
    if (f.open == 0)
        return port.kerror(Enotopen);
    usens(f.ns);
    const ch = fidchan(k, f);
    defer chan.cclose(ch);
    const ev: c_int = @intCast(t.count & 0xffff);
    const all = ev | dev.rd.Err | dev.rd.Hup;
    if (t.count & Rnow != 0) {
        r.count = @bitCast(dev.ready(ch, ev) & all);
        return;
    }
    var s: dev.rd.Sleeper = .{};
    var w: dev.rd.Watch = .{};
    while (true) {
        s.arm();
        var got = dev.ready(ch, ev) & all;
        if (got == 0) {
            dev.watch(ch, ev, &w, &s.waker);
            defer dev.rd.unwatch(&w);
            got = dev.ready(ch, ev) & all;
            if (got == 0)
                _ = try s.wait(0);
        }
        if (got != 0) {
            r.count = @bitCast(got);
            return;
        }
    }
}

/// Writes an Rready, which convS2M doesn't know.
fn replyready(k: *Kconn, r: *Fcall) void {
    var b: [11]u8 = undefined;
    std.mem.writeInt(u32, b[0..4], b.len, .little);
    b[4] = Tready + 1;
    std.mem.writeInt(u16, b[5..7], r.tag, .little);
    std.mem.writeInt(u32, b[7..11], r.count, .little);
    sync.qlock(&k.wlk);
    if (k.dead == 0)
        _ = dev.write(dev.of(k.c), k.c, &b, b.len, 0) catch 0;
    sync.qunlock(&k.wlk);
}

/// Runs a request on worker w and replies.
fn run(k: *Kconn, w: *Kworker, q: *Kreq) void {
    const t = &q.f;
    var r = std.mem.zeroes(Fcall);
    var ebuf: [port.ERRMAX]u8 = undefined;
    r.type = t.type + 1;
    r.tag = t.tag;
    r.fid = t.fid;
    request(k, w, t, &r) catch {
        chan.kstrcpy(&ebuf, up().errstr, ebuf.len);
        r = std.mem.zeroes(Fcall);
        r.type = c.Rerror;
        r.tag = t.tag;
        r.ename = &ebuf;
    };
    // Out of reach of a Tflush's interrupt before the reply goes, but
    // still found by one, whose Rflush then follows the reply.
    c.lock(&k.lk);
    q.done = 1;
    c.unlock(&k.lk);
    up().notepending = 0;
    if (r.type == Tready + 1) replyready(k, &r) else reply(k, &r, w.out);
    c.lock(&k.lk);
    w.cur = null;
    c.unlock(&k.lk);
    rflushed(k, q, w.out);
}

fn freereq(q_: ?*Kreq) void {
    const q = q_ orelse return;
    c.free(q.buf);
    c.free(q);
}

fn haswork(a: ?*anyopaque) callconv(.c) c_int {
    const w: *Kworker = @ptrCast(@alignCast(a.?));
    return @intFromBool(@as(*volatile ?*Kreq, &w.req).* != null or @as(*volatile c_int, &w.k.dead).* != 0);
}

/// Takes the next request for w, marking it running, or nil once dead.
fn nextreq(k: *Kconn, w: *Kworker) ?*Kreq {
    while (true) {
        c.lock(&k.lk);
        var q = w.req;
        w.req = null;
        if (q == null) {
            q = k.qhead;
            if (q) |x| {
                k.qhead = x.next;
                if (k.qhead == null)
                    k.qtail = &k.qhead;
                k.nqueue -= 1;
                _ = sync.wakeup(&k.rr);
            }
        }
        if (q) |x| {
            w.cur = x;
            up().notepending = 0;
            c.unlock(&k.lk);
            return x;
        }
        if (k.dead != 0) {
            c.unlock(&k.lk);
            return null;
        }
        w.inext = k.idle;
        k.idle = w;
        c.unlock(&k.lk);
        sync.sleep(&w.r, haswork, w) catch {};
        up().notepending = 0;
        // A wake for shutdown leaves it on the idle list; take it off.
        c.lock(&k.lk);
        var l: *?*Kworker = &k.idle;
        while (l.*) |x| : (l = &x.inext) {
            if (x == w) {
                l.* = w.inext;
                break;
            }
        }
        c.unlock(&k.lk);
    }
}

fn worker(a: ?*anyopaque) callconv(.c) void {
    const w: *Kworker = @ptrCast(@alignCast(a.?));
    const k = w.k;
    kpinit(k.s, "kserve");
    c.lock(&k.lk);
    w.p = up();
    c.unlock(&k.lk);
    while (nextreq(k, w)) |q| {
        run(k, w, q);
        freereq(q);
    }
    c.lock(&k.lk);
    w.p = null;
    var l: *?*Kworker = &k.workers;
    while (l.*) |x| : (l = &x.next) {
        if (x == w) {
            l.* = w.next;
            break;
        }
    }
    k.nworker -= 1;
    c.unlock(&k.lk);
    c.free(w.out);
    c.free(w.data);
    c.free(w);
    kconnput(k);
    kpexit();
}

/// Hands q to a worker, or queues it. Called with k->lk held.
fn dispatch(k: *Kconn, q: *Kreq) void {
    if (k.idle) |w| {
        k.idle = w.inext;
        w.req = q;
        c.unlock(&k.lk);
        _ = sync.wakeup(&w.r);
        c.lock(&k.lk);
        return;
    }
    if (k.nworker < Nworker) {
        const w_ = alloc(Kworker);
        var out: ?[*]u8 = null;
        var data: ?[*]u8 = null;
        if (w_ != null) {
            out = @ptrCast(c.malloc(k.msize));
            data = @ptrCast(c.malloc(k.msize));
        }
        if (w_) |w| if (out != null and data != null) {
            w.out = out.?;
            w.data = data.?;
            w.k = k;
            w.req = q;
            w.next = k.workers;
            k.workers = w;
            k.nworker += 1;
            _ = chan.incref(&k.ref);
            c.unlock(&k.lk);
            _ = c.kproc(@constCast("kserve"), worker, w);
            c.lock(&k.lk);
            return;
        };
        if (w_) |w| {
            c.free(out);
            c.free(data);
            c.free(w);
        }
    }
    q.next = null;
    k.qtail.* = q;
    k.qtail = &q.next;
    k.nqueue += 1;
}

/// Tflush, on the reader: a queued request is dropped and answered at
/// once; a running one is interrupted and answered after its reply; an
/// unknown one (already answered) at once.
fn flush(k: *Kconn, t: *Fcall, buf: [*]u8) void {
    c.lock(&k.lk);
    var l: *?*Kreq = &k.qhead;
    const q_: ?*Kreq = while (l.*) |q| : (l = &q.next) {
        if (q.f.tag == t.oldtag) {
            l.* = q.next;
            if (k.qtail == &q.next)
                k.qtail = l;
            k.nqueue -= 1;
            break q;
        }
    } else null;
    if (q_ == null) {
        var w_ = k.workers;
        while (w_) |w| : (w_ = w.next) {
            const wq_ = if (w.cur != null) w.cur else w.req;
            if (wq_) |wq| if (wq.f.tag == t.oldtag and wq.nftag < wq.ftag.len) {
                wq.ftag[@intCast(wq.nftag)] = t.tag;
                wq.nftag += 1;
                if (w.cur == wq and wq.done == 0 and wq.flushed == 0 and w.p != null) {
                    wq.flushed = 1;
                    sync.procinterrupt(w.p.?);
                }
                c.unlock(&k.lk);
                return;
            };
        }
    }
    c.unlock(&k.lk);
    freereq(q_);
    var r = std.mem.zeroes(Fcall);
    r.type = c.Rflush;
    r.tag = t.tag;
    reply(k, &r, buf);
}

/// Clunks every fid, for Tversion and the end of the connection.
fn clunkall(k: *Kconn) void {
    for (0..Nfidhash) |i| {
        while (true) {
            c.lock(&k.lk);
            const f_ = k.fids[i];
            if (f_) |f| {
                k.fids[i] = f.next;
                k.nfid -= 1;
            }
            c.unlock(&k.lk);
            const f = f_ orelse break;
            usens(f.ns);
            fidput(k, f);
        }
    }
}

fn version(k: *Kconn, t: *Fcall, buf: [*]u8) void {
    clunkall(k);
    var r = std.mem.zeroes(Fcall);
    r.type = c.Rversion;
    r.tag = t.tag;
    r.msize = t.msize;
    if (r.msize > Maxmsg)
        r.msize = Maxmsg;
    if (r.msize < 256)
        r.msize = 256;
    r.version = @constCast(if (c.strncmp(t.version, "9P2000", 6) == 0) "9P2000" else "unknown");
    // h9: readiness, for a client that asks for it.
    k.xready = @intFromBool(dev.streq(t.version, Vready));
    if (k.xready != 0)
        r.version = @constCast(Vready);
    // The workers' buffers are Maxmsg; only replies shrink.
    k.msize = r.msize;
    reply(k, &r, buf);
}

/// Reads into buf until it holds n bytes; false at EOF.
fn readn(k: *Kconn, buf: [*]u8, n: c_int, have: *c_int, cap: c_int) Error!bool {
    while (have.* < n) {
        const m = try dev.read(dev.of(k.c), k.c, buf + @as(usize, @intCast(have.*)), cap - have.*, 0);
        if (m <= 0)
            return false;
        have.* += m;
    }
    return true;
}

fn fullqueue(a: ?*anyopaque) callconv(.c) c_int {
    const k: *Kconn = @ptrCast(@alignCast(a.?));
    return @intFromBool(@as(*volatile c_int, &k.nqueue).* < Maxqueue or @as(*volatile c_int, &k.dead).* != 0);
}

/// Ends the connection: no more replies, and every worker interrupted.
fn hangup(k: *Kconn) void {
    c.lock(&k.lk);
    k.dead = 1;
    var w_ = k.workers;
    while (w_) |w| : (w_ = w.next) {
        if (w.p) |p|
            sync.procinterrupt(p);
        _ = sync.wakeup(&w.r);
    }
    if (k.reader) |r| if (r != up())
        sync.procinterrupt(r);
    c.unlock(&k.lk);
}

fn gbit32(p: [*]const u8) u32 {
    return @as(u32, p[0]) | @as(u32, p[1]) << 8 | @as(u32, p[2]) << 16 | @as(u32, p[3]) << 24;
}

/// One message read and handled: false when the connection ends.
fn readone(k: *Kconn, buf: [*]u8, rbuf: [*]u8, have: *c_int) Error!bool {
    if (k.dead != 0 or !try readn(k, buf, c.BIT32SZ, have, 2 * Maxmsg))
        return false;
    const size: c_int = @bitCast(gbit32(buf));
    if (size < c.BIT32SZ + c.BIT8SZ + c.BIT16SZ or size > Maxmsg or !try readn(k, buf, size, have, 2 * Maxmsg))
        return false;
    // Parsed in a copy of its own, since convM2S rewrites the strings in
    // place and the Fcall points into it.
    const q_ = alloc(Kreq);
    if (q_) |q|
        q.buf = @ptrCast(c.malloc(@intCast(size)));
    const q = q_ orelse return port.kerror(&port.Enomem);
    if (q.buf == null) {
        freereq(q);
        return port.kerror(&port.Enomem);
    }
    const sz: usize = @intCast(size);
    @memcpy(q.buf.?[0..sz], buf[0..sz]);
    have.* -= size;
    std.mem.copyForwards(u8, buf[0..@intCast(have.*)], buf[sz..][0..@intCast(have.*)]);
    if (k.xready != 0 and q.buf.?[4] == Tready) {
        // h9: size[4] Tready tag[2] fid[4] events[4], which convM2S
        // doesn't know.
        if (size != 15) {
            freereq(q);
            return false;
        }
        const m = q.buf.?;
        q.f.type = Tready;
        q.f.tag = std.mem.readInt(u16, m[5..7], .little);
        q.f.fid = std.mem.readInt(u32, m[7..11], .little);
        q.f.count = std.mem.readInt(u32, m[11..15], .little);
    } else if (c.convM2S(q.buf.?, @intCast(size), &q.f) != size) {
        freereq(q);
        return false;
    }
    switch (q.f.type) {
        c.Tversion => {
            version(k, &q.f, rbuf);
            freereq(q);
        },
        c.Tflush => {
            flush(k, &q.f, rbuf);
            freereq(q);
        },
        c.Tauth => {
            var t = std.mem.zeroes(Fcall);
            t.type = c.Rerror;
            t.tag = q.f.tag;
            t.ename = @constCast(Enoauth);
            freereq(q);
            reply(k, &t, rbuf);
        },
        else => {
            c.lock(&k.lk);
            dispatch(k, q);
            c.unlock(&k.lk);
            // Backpressure: past Maxqueue waiting, read no more.
            try sync.sleep(&k.rr, fullqueue, k);
        },
    }
    return true;
}

fn reader(a: ?*anyopaque) callconv(.c) void {
    const k: *Kconn = @ptrCast(@alignCast(a.?));
    kpinit(k.s, "kserve");
    c.lock(&k.lk);
    k.reader = up();
    c.unlock(&k.lk);
    const buf: [*]u8 = @ptrCast(c.smalloc(2 * Maxmsg));
    const rbuf: [*]u8 = @ptrCast(c.smalloc(Maxmsg));
    var have: c_int = 0;
    while (true) {
        const more = readone(k, buf, rbuf, &have) catch {
            // A stray interrupt reads on; a hangup or a closing server
            // ends it.
            if (dev.streq(up().errstr, &port.Eintr) and k.dead == 0 and k.s.closing == 0) {
                up().notepending = 0;
                continue;
            }
            break;
        };
        if (!more)
            break;
    }
    c.free(buf);
    c.free(rbuf);
    hangup(k);
    c.lock(&k.lk);
    k.reader = null;
    c.unlock(&k.lk);
    kconnput(k);
    kpexit();
}

/// The connection's last reference: its fids, its channel, its slot.
fn kconnput(k: *Kconn) void {
    if (chan.decref(&k.ref) != 0)
        return;
    while (k.qhead) |q| {
        k.qhead = q.next;
        freereq(q);
    }
    clunkall(k);
    chan.cclose(k.c);
    c.free(k.aname);
    const s = k.s;
    c.lock(&s.lk);
    var l: *?*Kconn = &s.conns;
    while (l.*) |x| : (l = &x.next) {
        if (x == k) {
            l.* = k.next;
            break;
        }
    }
    s.nconn -= 1;
    c.unlock(&s.lk);
    c.free(k);
    if (s.ended) |e|
        e(s.arg);
}

/// Starts serving the calling process's namespace: read-only if
/// readonly, from root (a path in it, "/" for all of it), with ..
/// stopping there. ended(arg) is called as each connection ends, on a
/// kernel thread. Returns the server, or nil with the error string set.
fn h9_kserve_new(readonly: c_int, root: [*:0]const u8, ended: ?*const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const s: *Kserver = @ptrCast(@alignCast(c.smalloc(@sizeOf(Kserver))));
    const ns: *Kns = @ptrCast(@alignCast(c.smalloc(@sizeOf(Kns))));
    s.hp = h9_kprocsrc();
    const ch = slash(s, root) catch {
        c.free(ns);
        h9_kprocput(s.hp);
        c.free(s);
        return null;
    };
    ns.ref.ref = 1;
    ns.pg = up().pgrp;
    _ = chan.incref(&ns.pg.ref);
    ns.slash = ch;
    s.ns = ns;
    s.src = &plansource;
    s.readonly = readonly;
    s.ended = ended;
    s.arg = arg;
    h9_kern_locals(1, &s.locals);
    _ = c.strecpy(&s.user, @as([*]u8, &s.user) + s.user.len, @ptrCast(&up().user));
    return s;
}

/// h9_kserve_new's root, a channel of its own when it isn't "/", marked
/// as a served attach root.
fn slash(s: *Kserver, root: [*:0]const u8) Error!*Chan {
    if (s.hp == null)
        return port.kerror("kserve: not an h9 process");
    var ch = try chan.namec(root, c.Atodir, 0, 0);
    if (!dev.streq(root, "/")) {
        const r = chan.cclone(ch) catch |e| {
            chan.cclose(ch);
            return e;
        };
        chan.cclose(ch);
        ch = r;
        h9_fs_markroot(ch, 0);
    }
    return ch;
}

/// A Kns for a named source: pg and slash, referenced, with put(arg)
/// called when its last fid is clunked.
fn h9_kserve_kns(pg: *c.Pgrp, sl: *Chan, put: ?*const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const ns = alloc(Kns) orelse return null;
    ns.ref.ref = 1;
    _ = chan.incref(&pg.ref);
    ns.pg = pg;
    _ = chan.incref(&sl.ref);
    ns.slash = sl;
    ns.put = put;
    ns.arg = arg;
    return ns;
}

/// Starts a server of named namespaces
/// (design/epoch-0/namespace-kernel.md, Serving): each Tattach gets
/// lookup(aname)'s Kns (h9_kserve_kns), or fails with "no such
/// namespace" for nil. Otherwise as h9_kserve_new.
fn h9_kserve_newnamed(lookup: Named, ended: ?*const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const s = alloc(Kserver) orelse {
        chan.kstrcpy(up().errstr, &port.Enomem, port.ERRMAX);
        return null;
    };
    s.hp = h9_kprocsrc();
    if (s.hp == null) {
        c.free(s);
        chan.kstrcpy(up().errstr, "kserve: not an h9 process", port.ERRMAX);
        return null;
    }
    s.src = &namedsource;
    s.named = lookup;
    s.ended = ended;
    s.arg = arg;
    h9_kern_locals(1, &s.locals);
    _ = c.strecpy(&s.user, @as([*]u8, &s.user) + s.user.len, @ptrCast(&up().user));
    return s;
}

/// Serves connection fd of the calling process. Returns 0, or -1 with
/// the error string set.
fn h9_kserve_conn(v: *anyopaque, fd: c_int) callconv(.c) c_int {
    kconnstart(@ptrCast(@alignCast(v)), fd, null) catch return -1;
    return 0;
}

/// As h9_kserve_conn, with every attach on the connection to aname
/// (design/epoch-0/namespace-kernel.md, Security): a Tattach naming
/// another fails.
fn h9_kserve_connas(v: *anyopaque, fd: c_int, aname: [*:0]const u8) callconv(.c) c_int {
    kconnstart(@ptrCast(@alignCast(v)), fd, aname) catch return -1;
    return 0;
}

fn kconnstart(s: *Kserver, fd: c_int, aname: ?[*:0]const u8) Error!void {
    const ch = try sysfile.fdtochan(fd, c.ORDWR, true, true);
    const k = alloc(Kconn) orelse {
        chan.cclose(ch);
        return port.kerror(&port.Enomem);
    };
    if (aname) |an| {
        k.aname = c.strdup(an) orelse {
            c.free(k);
            chan.cclose(ch);
            return port.kerror(&port.Enomem);
        };
    }
    k.s = s;
    k.c = ch;
    k.msize = Maxmsg;
    k.qtail = &k.qhead;
    k.ref.ref = 1; // the reader's
    c.lock(&s.lk);
    k.next = s.conns;
    s.conns = k;
    s.nconn += 1;
    c.unlock(&s.lk);
    _ = c.kproc(@constCast("kserve"), reader, k);
}

/// Connections still being served.
fn h9_kserve_nconn(v: *anyopaque) callconv(.c) c_int {
    const s: *Kserver = @ptrCast(@alignCast(v));
    return s.nconn;
}

/// Ends every connection and waits for them, then frees the server.
/// Called by the process that made it.
fn h9_kserve_close(v: *anyopaque) callconv(.c) void {
    const s: *Kserver = @ptrCast(@alignCast(v));
    s.closing = 1;
    while (true) {
        c.lock(&s.lk);
        const n = s.nconn;
        var k_ = s.conns;
        while (k_) |k| : (k_ = k.next)
            hangup(k);
        c.unlock(&s.lk);
        if (n == 0)
            break;
        sync.tsleep(&s.r, &c.return0, null, 20) catch {};
        up().notepending = 0;
    }
    nsput(s.ns);
    h9_kprocput(s.hp);
    c.free(s);
}

/// Ends every connection of server v as kserve_close does, without
/// waiting for them, from any thread: a child machine's servers of its
/// caller's paths (src/kern/dev/machine.zig) once the child has ended.
fn h9_kserve_hangupall(v: *anyopaque) callconv(.c) void {
    const s: *Kserver = @ptrCast(@alignCast(v));
    c.lock(&s.lk);
    var k_ = s.conns;
    while (k_) |k| : (k_ = k.next) {
        c.lock(&k.lk);
        k.dead = 1;
        var w_ = k.workers;
        while (w_) |w| : (w_ = w.next) {
            if (w.p) |p|
                sync.procinterrupt(p);
            _ = sync.wakeup(&w.r);
        }
        if (k.reader) |r|
            sync.procinterrupt(r);
        c.unlock(&k.lk);
    }
    c.unlock(&s.lk);
}

pub fn exportC() void {
    @export(&h9_kserve_hangupall, .{ .name = "h9_kserve_hangupall" });
    @export(&h9_kserve_new, .{ .name = "h9_kserve_new" });
    @export(&h9_kserve_kns, .{ .name = "h9_kserve_kns" });
    @export(&h9_kserve_newnamed, .{ .name = "h9_kserve_newnamed" });
    @export(&h9_kserve_conn, .{ .name = "h9_kserve_conn" });
    @export(&h9_kserve_connas, .{ .name = "h9_kserve_connas" });
    @export(&h9_kserve_nconn, .{ .name = "h9_kserve_nconn" });
    @export(&h9_kserve_close, .{ .name = "h9_kserve_close" });
}
