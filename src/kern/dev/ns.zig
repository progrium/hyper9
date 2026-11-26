//! src/kern/devns.c in Zig (design/kernel-port.md): `#N`, the namespace
//! kernel's namespaces (design/epoch-0/namespace-kernel.md). A close
//! translation: the same functions in the same order, with error unions
//! for the C's error labels. A native device (dev.zig's `Native`), in the
//! namespace kernel only.
//!
//!     /ns/clone  open: a new namespace, empty, whose ctl the fid is
//!     /ns/N/ctl  write: newns lines run in N; read: N's id
//!     /ns/N/ns   read: N's mount table, in newns syntax
//!
//! A namespace is a Pgrp, a root (slash), and a dot. An empty one's root
//! is a fresh bare #O, so the host can make mount points with Tcreate;
//! `copy P` as the first line makes it a copy of P's mount table, root
//! and dot instead. #N and #s are masked in every namespace but 0, the
//! control namespace, and a copy of 0 has /ns and /srv unmounted, so a
//! task handed its namespace can't reach the others or the host's board.
//!
//! Each ctl line runs on a kernel process of its own (ctlproc), in N:
//! its Pgrp, slash and dot, as the process that booted the namespace
//! kernel's machine. bind, mount, unmount and cd go to the Zig leaf
//! h9_ns_ctl (src/nskernel.zig), which parses them with src/newns.zig and
//! makes the kernel's system calls, and dials mounts; copy, empty, clear,
//! board, hold and free are done here. Lines of one namespace run one at
//! a time, under its ctl QLock. A line runs on a process of its own so
//! the leaf's system calls are its process's outermost kernel calls.
//!
//! Lifetime: a namespace holds a reference for each open ctl, each
//! attach kserve serves from it (h9_ns_lookup's Kns), and `hold`. The
//! last one going frees it: its Pgrp, root, dot, and board's lease, which
//! closes the board and what was posted there. Namespace 0 is never
//! freed. Ids are never reused.
//!
//! Boards: namespace 0's /srv is #s's root board, the host's. A
//! `srv!NAME` dial opens NAME there, whatever N can see. `board` gives N a
//! board of its own: a child board of the host's (#s/clone), whose lease
//! N holds, bound at N's /srv. The kernel attaches it in namespace 0, so
//! N's mask doesn't refuse it.
//!
//! Mounts' dial strings are recorded by their devmnt channel's dev
//! (h9_ns_dialed), so `ns` prints the dial string a ctl line mounted, and
//! the lines replay.
//!
//! A ctl write waits for its line in sync.zig's sleep, and the server for
//! a connection there too.

const std = @import("std");
const port = @import("../port.zig");
const sync = @import("../sync.zig");
const dev = @import("../dev.zig");
const chan = @import("../chan.zig");
const pgrp = @import("../pgrp.zig");
const sysfile = @import("../sysfile.zig");
const devsrv = @import("srv.zig");
const c = port.c;
const up = port.up;
const Error = port.Error;

const Chan = c.Chan;
const Dir = c.Dir;
const Dirtab = c.Dirtab;
const Walkqid = c.Walkqid;
const Qid = c.Qid;
const Pgrp = c.Pgrp;
const Mount = c.Mount;

// proc.c
extern fn h9_kprocsrc() ?*anyopaque;
extern fn h9_kprocshare(src: ?*anyopaque, text: [*:0]const u8) c_int;
extern fn h9_kprocunshare() void;
extern fn h9_fgrpclose(f: *c.Fgrp) void;
// devoverlay.c, which don't raise.
extern fn h9_overlay_new(ch: ?*Chan) c_int;
extern fn h9_overlay_drop(id: c_int) void;
extern fn h9_overlay_nsunion(ch: *Chan, old: [*:0]const u8, buf: [*]u8, nbuf: c_int) c_int;
// kserve.zig
extern fn h9_kserve_kns(pg: *Pgrp, slash: *Chan, put: *const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque) ?*anyopaque;
// src/nskernel.zig: runs one bind, mount, unmount or cd line in the calling process's namespace.
extern fn h9_ns_ctl(ns: ?*anyopaque, line: [*]const u8, n: c_long, err: [*]u8) c_int;
// src/kern/devshim.c: ns.c's pgrpcpy, which raises.
extern fn h9_shim_pgrpcpy(to: *Pgrp, from: *Pgrp, flag: c_int) c_int;

const Qtop = 0;
const Qclone = 1;
const Qdir = 2;
const Qctl = 3;
const Qns = 4;

const Maxctl = 8192; // bytes in one ctl write

const RFNAMEG = 1 << 0; // hproc.h's

fn QTYPE(p: u64) c_int {
    return @intCast(p & 7);
}
fn QNS(p: u64) c_ulong {
    return @intCast(p >> 3);
}
fn QPATH(id: c_ulong, t: u64) i64 {
    return @bitCast((@as(u64, id) << 3) | t);
}

/// A mount's dial string, by its devmnt channel's dev.
const Dial = struct {
    next: ?*Dial = null,
    dev: c_uint = 0,
    s: ?[*:0]u8 = null,
};

const Ns = struct {
    next: ?*Ns = null,
    id: c_ulong = 0,
    ref: c_int = 0, // under nslock
    hold: bool = false, // under nslock
    used: bool = false, // a line has run, so copy is too late; under ctl
    ctl: c.QLock = std.mem.zeroes(c.QLock), // one line at a time
    lk: c.Lock = std.mem.zeroes(c.Lock), // pg, slash, dot, board, dials
    pg: *Pgrp = undefined,
    slash: *Chan = undefined,
    dot: *Chan = undefined,
    board: ?*Chan = null, // the lease on N's own board, or nil
    dials: ?*Dial = null,
};

/// A ctl line handed to ctlproc.
const Ctl = struct {
    ref: c.Ref = std.mem.zeroes(c.Ref), // the writer's and ctlproc's
    ns: *Ns = undefined,
    line: [*:0]u8 = undefined,
    done: std.atomic.Value(c_int) = .init(0),
    r: c.Rendez = std.mem.zeroes(c.Rendez),
    err: [port.ERRMAX]u8 = @splat(0),
    failed: bool = false,
};

var nslock: c.Lock = std.mem.zeroes(c.Lock);
var nslist: ?*Ns = null;
var nsnext: c_ulong = 0;
var ns0: ?*Ns = null;
var nssrc: ?*anyopaque = null; // the booting process's record, for ctlproc's

const Enons = "no such namespace";
var nsuser: [c.KNAMELEN]u8 = @splat(0); // the booting process's user, ctlproc's

fn create(comptime T: type) ?*T {
    const p: *T = @ptrCast(@alignCast(port.malloc(@sizeOf(T)) orelse return null));
    p.* = .{};
    return p;
}

fn nsget(id: c_ulong) ?*Ns {
    c.lock(&nslock);
    var n = nslist;
    while (n) |x| : (n = x.next)
        if (x.id == id and x.ref > 0)
            break;
    if (n) |x|
        x.ref += 1;
    c.unlock(&nslock);
    return n;
}

fn dialsfree(d_: ?*Dial) void {
    var d = d_;
    while (d) |x| {
        d = x.next;
        c.free(x.s);
        c.free(x);
    }
}

fn nsfree(n: *Ns) void {
    pgrp.closepgrp(n.pg);
    chan.cclose(n.slash);
    chan.cclose(n.dot);
    if (n.board) |b|
        chan.cclose(b);
    dialsfree(n.dials);
    c.free(n);
}

fn nsput(n: *Ns) void {
    c.lock(&nslock);
    n.ref -= 1;
    if (n.ref > 0 or n == ns0) {
        c.unlock(&nslock);
        return;
    }
    var l: *?*Ns = &nslist;
    while (l.*) |x| : (l = &x.next) {
        if (x == n) {
            l.* = n.next;
            break;
        }
    }
    c.unlock(&nslock);
    nsfree(n);
}

/// What the calling process's namespace was, while it runs in another.
const Saved = struct {
    pg: [*c]Pgrp,
    slash: [*c]Chan,
    dot: [*c]Chan,
};

/// Runs the calling process in n, with references to n's groups.
fn nsenter(n: *Ns) Saved {
    const p = up();
    const s: Saved = .{ .pg = p.pgrp, .slash = p.slash, .dot = p.dot };
    c.lock(&n.lk);
    _ = chan.incref(&n.pg.ref);
    p.pgrp = n.pg;
    _ = chan.incref(&n.slash.ref);
    p.slash = n.slash;
    _ = chan.incref(&n.dot.ref);
    p.dot = n.dot;
    c.unlock(&n.lk);
    return s;
}

/// Puts the caller's namespace back; with keepdot, a cd made in n stays n's.
fn nsleave(n: *Ns, s: *const Saved, keepdot: bool) void {
    const p = up();
    var old: ?*Chan = null;
    if (keepdot) {
        c.lock(&n.lk);
        if (p.dot != n.dot) {
            old = n.dot;
            _ = chan.incref(&p.dot.*.ref);
            n.dot = p.dot;
        }
        c.unlock(&n.lk);
    }
    if (old) |o|
        chan.cclose(o);
    pgrp.closepgrp(p.pgrp);
    chan.cclose(p.slash);
    chan.cclose(p.dot);
    p.pgrp = s.pg;
    p.slash = s.slash;
    p.dot = s.dot;
}

/// "#O" and the overlay's id.
fn overlayname(buf: *[32]u8, id: c_int) [*:0]const u8 {
    return (std.mem.printSentinel(buf, "#O{d}", .{id}, 0) catch unreachable).ptr;
}

/// A fresh bare #O, as a root: its path is /.
fn freshroot() Error!*Chan {
    const id = h9_overlay_new(null);
    if (id < 0)
        return port.kerror(up().errstr);
    var buf: [32]u8 = undefined;
    // The chan holds the instance once it's made; it goes with the last one.
    defer h9_overlay_drop(id);
    const ch = try chan.namec(overlayname(&buf, id), c.Atodir, 0, 0);
    chan.pathclose(ch.path);
    ch.path = chan.newpath("/");
    return ch;
}

fn nsnew() Error!*Ns {
    const ch = try freshroot();
    const n = create(Ns) orelse {
        chan.cclose(ch);
        return port.kerror(&port.Enomem);
    };
    n.pg = pgrp.newpgrp() catch |e| {
        chan.cclose(ch);
        c.free(n);
        return e;
    };
    n.slash = ch;
    _ = chan.incref(&ch.ref);
    n.dot = ch;
    n.ref = 1;
    c.lock(&nslock);
    n.id = nsnext;
    nsnext += 1;
    n.next = nslist;
    nslist = n;
    c.unlock(&nslock);
    if (n.id != 0)
        pgrp.devmask(n.pg, false, "Ns");
    return n;
}

/// Mounts the device attach dev on path in the calling process's namespace, made if missing.
fn mountdev(devname: [*:0]const u8, path: [*:0]const u8, flag: c_int) Error!void {
    if (chan.namec(path, c.Acreate, c.OREAD, c.DMDIR | 0o775)) |ch|
        chan.cclose(ch)
    else |_| {}
    const c0 = try chan.namec(devname, c.Atodir, 0, 0);
    defer chan.cclose(c0);
    const c1 = try chan.namec(path, c.Amount, 0, 0);
    defer chan.cclose(c1);
    _ = try chan.cmount(c0, c1, flag, null);
}

/// Makes namespace 0, the control namespace
/// (design/epoch-0/namespace-kernel.md): a bare #O with the namespaces at
/// /ns, the host's board at /srv, and a fresh #O at /tmp. Called once, by
/// the namespace kernel's first process, whose record ctlproc's processes
/// share.
fn nsinit() Error!void {
    if (ns0 != null)
        return port.kerror("namespace kernel already booted");
    nssrc = h9_kprocsrc();
    if (nssrc == null)
        return port.kerror("devns: not an h9 process");
    chan.kstrcpy(&nsuser, @ptrCast(&up().user), nsuser.len);
    const n = try nsnew();
    ns0 = n;
    const s = nsenter(n);
    defer nsleave(n, &s, false);
    try mountdev("#N", "/ns", c.MREPL);
    try mountdev("#s", "/srv", c.MREPL);
    const id = h9_overlay_new(null);
    if (id < 0)
        return port.kerror(up().errstr);
    defer h9_overlay_drop(id);
    var buf: [32]u8 = undefined;
    try mountdev(overlayname(&buf, id), "/tmp", c.MREPL | c.MCREATE);
}

/// A call that failed: its error string becomes the process's
/// syserrstr, as errstr(2) reads it, and -1.
fn syserr() c_int {
    const p = up();
    const s = p.syserrstr;
    p.syserrstr = p.errstr;
    p.errstr = s;
    return -1;
}

/// Returns 0, or -1 with the error string set.
fn h9_ns_init() callconv(.c) c_int {
    nsinit() catch return syserr();
    return 0;
}

// kserve's named source (src/kern/kserve.c): the attach name is a
// namespace's id, and the empty name is 0.

fn knsput(a: ?*anyopaque) callconv(.c) void {
    nsput(@ptrCast(@alignCast(a.?)));
}

/// An id as the C's strtoul read it, with no leading zeros, or null.
fn parseid(s: []const u8) ?c_ulong {
    if (s.len > 1 and s[0] == '0')
        return null;
    return std.fmt.parseUnsigned(c_ulong, s, 10) catch null;
}

fn h9_ns_lookup(aname: ?[*:0]const u8) callconv(.c) ?*anyopaque {
    var id: c_ulong = 0;
    if (aname != null and aname.?[0] != 0)
        id = parseid(std.mem.span(aname.?)) orelse return null;
    const n = nsget(id) orelse return null;
    c.lock(&n.lk);
    const k = h9_kserve_kns(n.pg, n.slash, &knsput, n);
    c.unlock(&n.lk);
    if (k == null)
        nsput(n);
    return k;
}

// The device.

fn nsgen(ch_: [*c]Chan, name: [*c]u8, tab: [*c]Dirtab, ntab: c_int, s_: c_int, dp_: [*c]Dir) callconv(.c) c_int {
    _ = name;
    _ = tab;
    _ = ntab;
    const ch: *Chan = ch_;
    const dp: *Dir = dp_;
    var q: Qid = undefined;
    const t = QTYPE(ch.qid.path);
    if (s_ == c.DEVDOTDOT) {
        dev.mkqid(&q, QPATH(0, Qtop), 0, c.QTDIR);
        dev.devdir(ch, q, @constCast("#N"), 0, c.eve, dev.dmdir | 0o555, dp);
        return 1;
    }
    if (t == Qtop) {
        if (s_ == 0) {
            dev.mkqid(&q, QPATH(0, Qclone), 0, c.QTFILE);
            dev.devdir(ch, q, @constCast("clone"), 0, c.eve, 0o666, dp);
            return 1;
        }
        var s = s_ - 1;
        c.lock(&nslock);
        var n = nslist;
        while (n) |x| : (n = x.next) {
            if (x.ref > 0) {
                if (s == 0) break;
                s -= 1;
            }
        }
        const id: c_ulong = if (n) |x| x.id else 0;
        c.unlock(&nslock);
        if (n == null)
            return -1;
        const buf: []u8 = &up().genbuf;
        const nm = std.mem.printSentinel(buf, "{d}", .{id}, 0) catch unreachable;
        dev.mkqid(&q, QPATH(id, Qdir), 0, c.QTDIR);
        dev.devdir(ch, q, nm.ptr, 0, c.eve, dev.dmdir | 0o555, dp);
        return 1;
    }
    const id = QNS(ch.qid.path);
    switch (s_) {
        0 => {
            dev.mkqid(&q, QPATH(id, Qctl), 0, c.QTFILE);
            dev.devdir(ch, q, @constCast("ctl"), 0, c.eve, 0o666, dp);
            return 1;
        },
        1 => {
            dev.mkqid(&q, QPATH(id, Qns), 0, c.QTFILE);
            dev.devdir(ch, q, @constCast("ns"), 0, c.eve, 0o444, dp);
            return 1;
        },
        else => return -1,
    }
}

fn nsattach(spec: [*:0]const u8) Error!*Chan {
    const ch = dev.devattach('N', spec);
    dev.mkqid(&ch.qid, QPATH(0, Qtop), 0, c.QTDIR);
    return ch;
}

fn nswalk(ch: *Chan, nc: ?*Chan, name: [*]const [*:0]const u8, nname: c_int) Error!?*Walkqid {
    return dev.devwalk(ch, nc, name, nname, null, 0, &nsgen);
}

fn nsstat(ch: *Chan, db: [*]u8, n: c_int) Error!c_int {
    return dev.devstat(ch, db, n, null, 0, &nsgen);
}

fn nsof(ch: *Chan) *Ns {
    return @ptrCast(@alignCast(dev.aux(ch).*.?));
}

fn nsopen(ch: *Chan, omode: c_int) Error!*Chan {
    const t = QTYPE(ch.qid.path);
    // Checked first, so a bad mode leaves no namespace made or held.
    const mode = try sysfile.openmode(@bitCast(omode));
    switch (t) {
        Qtop, Qdir => if (omode != c.OREAD)
            return port.kerror(&port.Eisdir),
        Qclone => {
            const n = try nsnew();
            dev.aux(ch).* = n;
            dev.mkqid(&ch.qid, QPATH(n.id, Qctl), 0, c.QTFILE);
        },
        Qctl, Qns => {
            const n = nsget(QNS(ch.qid.path)) orelse return port.kerror(Enons);
            if (t == Qns and omode != c.OREAD) {
                nsput(n);
                return port.kerror(&port.Eperm);
            }
            dev.aux(ch).* = n;
        },
        else => {},
    }
    ch.mode = @intCast(mode);
    ch.flag |= c.COPEN;
    ch.offset = 0;
    return ch;
}

fn nsclose(ch: *Chan) Error!void {
    if ((ch.flag & c.COPEN) == 0 or dev.aux(ch).* == null)
        return;
    nsput(nsof(ch));
    dev.aux(ch).* = null;
}

/// The mount flags as newns writes them.
fn flagstr(flag: c_int, buf: *[8]u8) [*:0]const u8 {
    var p: usize = 0;
    if (flag & (c.MBEFORE | c.MAFTER | c.MCREATE | c.MCACHE) != 0) {
        buf[p] = '-';
        p += 1;
        if (flag & c.MBEFORE != 0) {
            buf[p] = 'b';
            p += 1;
        }
        if (flag & c.MAFTER != 0) {
            buf[p] = 'a';
            p += 1;
        }
        if (flag & c.MCREATE != 0) {
            buf[p] = 'c';
            p += 1;
        }
        if (flag & c.MCACHE != 0) {
            buf[p] = 'C';
            p += 1;
        }
    }
    buf[p] = 0;
    return @ptrCast(buf);
}

/// A devmnt channel's dial string, or nil. Called with n.lk.
fn dialof(n: *Ns, to: *Chan) ?[*:0]u8 {
    var d = n.dials;
    while (d) |x| : (d = x.next)
        if (x.dev == to.dev)
            return x.s;
    return null;
}

/// N's mount table as newns lines into buf, then its cd; false if buf is
/// too small for them. Called with n.lk.
fn nstextin(n: *Ns, buf: []u8) bool {
    var p: usize = 0;
    var flag: [8]u8 = undefined;
    sync.rlock(&n.pg.ns);
    defer sync.runlock(&n.pg.ns);
    var f: ?*Mount = n.pg.mntorder;
    while (f) |m| : (f = m.order) {
        const left = buf.len - p;
        if (left < 2 * c.KNAMELEN + 64)
            return false;
        _ = flagstr(m.mflag, &flag);
        const to: *Chan = m.to;
        const from: [*c]u8 = @constCast(chan.chanpath(m.umh.*.from));
        const out: [*c]u8 = buf[p..].ptr;
        const nl: c_int = @intCast(left);
        var k: c_int = undefined;
        if (dev.of(to).dc == 'M') {
            var dial: [*c]u8 = dialof(n, to) orelse null;
            if (dial == null)
                dial = if (to.mchan.*.srvname != null) to.mchan.*.srvname else @constCast(chan.chanpath(to.mchan));
            const spec: [*c]u8 = m.spec();
            if (spec[0] != 0)
                k = c.snprint(out, nl, @constCast("mount %s %q %q %q\n"), &flag, dial, from, spec)
            else
                k = c.snprint(out, nl, @constCast("mount %s %q %q\n"), &flag, dial, from);
        } else {
            k = h9_overlay_nsunion(to, from, out, nl);
            if (k < 0)
                k = c.snprint(out, nl, @constCast("bind %s %q %q\n"), &flag, @as([*c]u8, @constCast(chan.chanpath(to))), from);
        }
        if (k >= nl - 1)
            return false;
        p += @intCast(k);
    }
    if (buf.len - p < c.KNAMELEN + 16)
        return false;
    _ = c.snprint(buf[p..].ptr, @intCast(buf.len - p), @constCast("cd %q\n"), @as([*c]u8, @constCast(chan.chanpath(n.dot))));
    return true;
}

/// N's mount table as newns lines, then its cd, in memory the caller frees.
fn nstext(n: *Ns) [*:0]u8 {
    var size: usize = 4096;
    while (true) : (size *= 2) {
        const buf: [*]u8 = @ptrCast(c.smalloc(@intCast(size)));
        c.lock(&n.lk);
        const ok = nstextin(n, buf[0..size]);
        c.unlock(&n.lk);
        if (ok)
            return @ptrCast(buf);
        c.free(buf);
    }
}

fn nsread(ch: *Chan, va: ?*anyopaque, n: c_int, off: i64) Error!c_int {
    const offset: c_uint = @truncate(@as(u64, @bitCast(off)));
    switch (QTYPE(ch.qid.path)) {
        Qtop, Qdir => return dev.devdirread(ch, @ptrCast(va.?), n, null, 0, &nsgen),
        Qctl => {
            var buf: [32]u8 = undefined;
            const s = std.mem.printSentinel(&buf, "{d}", .{nsof(ch).id}, 0) catch unreachable;
            return c.readstr(offset, @ptrCast(va.?), @intCast(n), s.ptr);
        },
        Qns => {
            const s = nstext(nsof(ch));
            defer c.free(s);
            return c.readstr(offset, @ptrCast(va.?), @intCast(n), s);
        },
        else => {},
    }
    return port.kerror(&port.Egreg);
}

/// Records the dial string of the mount a ctl line just made in ns: the
/// devmnt channel in its mount table with no record yet. Called by the
/// Zig leaf, in ns.
fn h9_ns_dialed(v: ?*anyopaque, dial: [*:0]const u8) callconv(.c) void {
    const n: *Ns = @ptrCast(@alignCast(v.?));
    var nd: ?*Dial = create(Dial) orelse return;
    nd.?.s = @ptrCast(c.strdup(dial));
    if (nd.?.s == null) {
        c.free(nd);
        return;
    }
    c.lock(&n.lk);
    sync.rlock(&n.pg.ns);
    var f: ?*Mount = n.pg.mntorder;
    while (f) |m| : (f = m.order) {
        if (dev.of(m.to).dc != 'M')
            continue;
        var d = n.dials;
        while (d) |x| : (d = x.next)
            if (x.dev == m.to.*.dev)
                break;
        if (d == null) {
            nd.?.dev = m.to.*.dev;
            nd.?.next = n.dials;
            n.dials = nd;
            nd = null;
            break;
        }
    }
    sync.runlock(&n.pg.ns);
    c.unlock(&n.lk);
    if (nd) |x| {
        c.free(x.s);
        c.free(x);
    }
}

/// Opens NAME on the host's board, namespace 0's /srv, for a srv!NAME
/// dial: an fd in the calling process.
fn hostsrv(name: [*:0]const u8) Error!c_int {
    const nm = std.mem.span(name);
    if (nm.len == 0 or std.mem.indexOfScalar(u8, nm, '/') != null or dev.streq(name, ".") or dev.streq(name, ".."))
        return port.kerror("bad srv name");
    const path_: ?[*:0]u8 = @ptrCast(c.smprint(@constCast("#s/%s"), name));
    const path = path_ orelse return port.kerror(&port.Enomem);
    defer c.free(path);
    const ch = blk: {
        const n = ns0.?;
        const s = nsenter(n);
        defer nsleave(n, &s, false);
        break :blk try chan.namec(path, c.Aopen, c.ORDWR, 0);
    };
    const fd = sysfile.newfd(ch, 0);
    if (fd < 0) {
        chan.cclose(ch);
        return port.kerror(&port.Enofd);
    }
    return fd;
}

/// An fd, or -1 with the error string set.
fn h9_ns_hostsrv(name: [*:0]const u8) callconv(.c) c_int {
    return hostsrv(name) catch syserr();
}

/// post NAME DIAL: posts fd, a 9P2000 connection the Zig leaf dialed, as
/// NAME on ns's board: the host's for namespace 0, or the one `board`
/// gave it. The fd stays the caller's.
fn srvpost(n: *Ns, name: [*:0]const u8, fd: c_int) Error!void {
    const ch = try sysfile.fdtochan(fd, c.ORDWR, false, true);
    var posted = false;
    defer if (!posted) chan.cclose(ch);
    var b: *Chan = undefined;
    if (n == ns0) {
        const s = nsenter(n);
        defer nsleave(n, &s, false);
        b = try chan.namec("#s", c.Atodir, 0, 0);
    } else {
        c.lock(&n.lk);
        const nb = n.board;
        if (nb) |x|
            _ = chan.incref(&x.ref);
        c.unlock(&n.lk);
        b = nb orelse return port.kerror("post: no board; write board first");
    }
    defer chan.cclose(b);
    // The board takes ch, whatever happens.
    posted = true;
    try devsrv.srvpost(dev.aux(b).*.?, name, ch, 0o666);
}

/// 0, or -1 with the error string set.
fn h9_ns_srvpost(v: ?*anyopaque, name: [*:0]const u8, fd: c_int) callconv(.c) c_int {
    srvpost(@ptrCast(@alignCast(v.?)), name, fd) catch return syserr();
    return 0;
}

/// clear: empties n's mount table in place, so its attaches see it too.
fn nsclear(n: *Ns) void {
    const pg = n.pg;
    sync.wlock(&pg.ns);
    for (&pg.mnthash) |*h| {
        while (@as(?*c.Mhead, h.*)) |f| {
            h.* = f.hash;
            sync.wlock(&f.lock);
            const m = f.mount;
            f.mount = null;
            sync.wunlock(&f.lock);
            pgrp.mountfree(m);
            chan.putmhead(f);
        }
    }
    pg.mntorder = null;
    pg.mntordertail = &pg.mntorder;
    sync.wunlock(&pg.ns);
    c.lock(&n.lk);
    dialsfree(n.dials);
    n.dials = null;
    c.unlock(&n.lk);
}

/// Unmounts everything on path in the calling process's namespace, if anything is.
fn unmountall(path: [*:0]const u8) void {
    const ch = chan.namec(path, c.Amount, 0, 0) catch return;
    defer chan.cclose(ch);
    chan.cunmount(ch, null) catch {};
}

/// copy P: n's mount table, root and dot become copies of P's.
fn nscopy(n: *Ns, pid: c_ulong) Error!void {
    const p = nsget(pid) orelse return port.kerror(Enons);
    defer nsput(p);
    try dev.caught(h9_shim_pgrpcpy(n.pg, p.pg, RFNAMEG));
    // pgrpcpy copied P's mask too: n's own stands.
    pgrp.devmask(n.pg, false, "Ns");
    c.lock(&p.lk);
    const slash = p.slash;
    _ = chan.incref(&slash.ref);
    const dot = p.dot;
    _ = chan.incref(&dot.ref);
    var nd: ?*Dial = null;
    var l: *?*Dial = &nd;
    var d = p.dials;
    while (d) |x| : (d = x.next) {
        const y = create(Dial) orelse break;
        y.dev = x.dev;
        y.s = @ptrCast(c.strdup(x.s));
        if (y.s == null) {
            c.free(y);
            break;
        }
        l.* = y;
        l = &y.next;
    }
    c.unlock(&p.lk);
    c.lock(&n.lk);
    chan.cclose(n.slash);
    n.slash = slash;
    chan.cclose(n.dot);
    n.dot = dot;
    dialsfree(n.dials);
    n.dials = nd;
    c.unlock(&n.lk);
    if (p == ns0) {
        // The control namespace's /ns and host's board stay its own.
        const s = nsenter(n);
        unmountall("/ns");
        unmountall("/srv");
        nsleave(n, &s, false);
    }
}

/// The lease on a fresh child board of the host's, and its directory,
/// attached in namespace 0.
fn newboard(dir: **Chan) Error!*Chan {
    const z = ns0.?;
    const s = nsenter(z);
    defer nsleave(z, &s, false);
    const lease = try chan.namec("#s/clone", c.Aopen, c.ORDWR, 0);
    errdefer chan.cclose(lease);
    var name: [32]u8 = undefined;
    const m = try dev.read(dev.of(lease), lease, &name, name.len - 1, 0);
    if (m <= 0)
        return port.kerror("board: no lease name");
    name[@intCast(m)] = 0;
    const path_: ?[*:0]u8 = @ptrCast(c.smprint(@constCast("#s/%s"), &name));
    const path = path_ orelse return port.kerror(&port.Enomem);
    defer c.free(path);
    dir.* = try chan.namec(path, c.Atodir, 0, 0);
    return lease;
}

/// board: a fresh, empty board of n's own at its /srv.
fn nsboard(n: *Ns) Error!void {
    if (n == ns0)
        return port.kerror("namespace 0's board is the host's");
    var dir: *Chan = undefined;
    const lease = try newboard(&dir);
    {
        errdefer chan.cclose(lease);
        defer chan.cclose(dir);
        const s = nsenter(n);
        defer nsleave(n, &s, false);
        if (chan.namec("/srv", c.Acreate, c.OREAD, c.DMDIR | 0o775)) |ch|
            chan.cclose(ch)
        else |_| {}
        const mnt = try chan.namec("/srv", c.Amount, 0, 0);
        defer chan.cclose(mnt);
        _ = try chan.cmount(dir, mnt, c.MREPL, null);
    }
    c.lock(&n.lk);
    if (n.board) |old| {
        // the old board closes with its lease
        n.board = lease;
        c.unlock(&n.lk);
        chan.cclose(old);
    } else {
        n.board = lease;
        c.unlock(&n.lk);
    }
}

fn ctlput(x: *Ctl) void {
    if (chan.decref(&x.ref) != 0)
        return;
    nsput(x.ns);
    c.free(x.line);
    c.free(x);
}

/// The lines devns runs itself; the rest go to the Zig leaf.
fn isnsline(cmd: []const u8) bool {
    for ([_][]const u8{ "copy", "empty", "clear", "board", "hold", "free" }) |s|
        if (std.mem.eql(u8, cmd, s))
            return true;
    return false;
}

/// Runs one of devns's own lines in n.
fn nsline(n: *Ns, cmd: []const u8, arg: [*:0]const u8) Error!void {
    if (std.mem.eql(u8, cmd, "copy")) {
        if (n.used)
            return port.kerror("copy must be the first line");
        const a = std.mem.span(arg);
        const e = std.mem.indexOfAny(u8, a, " \t") orelse a.len;
        if (a.len == 0 or std.mem.trimStart(u8, a[e..], " \t").len != 0)
            return port.kerror(&port.Ebadctl);
        // strtoul's: digits, and 0 for none.
        var pid: c_ulong = 0;
        for (a[0..e]) |ch| {
            if (ch < '0' or ch > '9') return port.kerror(&port.Ebadctl);
            pid = pid *% 10 +% (ch - '0');
        }
        try nscopy(n, pid);
    } else if (std.mem.eql(u8, cmd, "empty")) {
        if (n.used)
            return port.kerror("empty must be the first line");
    } else if (std.mem.eql(u8, cmd, "clear")) {
        nsclear(n);
    } else if (std.mem.eql(u8, cmd, "board")) {
        try nsboard(n);
    } else if (std.mem.eql(u8, cmd, "hold")) {
        c.lock(&nslock);
        if (!n.hold) {
            n.hold = true;
            n.ref += 1;
        }
        c.unlock(&nslock);
    } else if (std.mem.eql(u8, cmd, "free")) {
        if (n == ns0)
            return port.kerror("namespace 0 can't be freed");
        c.lock(&nslock);
        const had = n.hold;
        n.hold = false;
        c.unlock(&nslock);
        if (had)
            nsput(n);
    }
}

/// Runs x's line in its namespace, as ctlproc's process.
fn ctlrun(x: *Ctl) void {
    const n = x.ns;
    _ = h9_kprocshare(nssrc, "nsctl");
    const p = up();
    const f: ?*c.Fgrp = p.fgrp;
    p.fgrp = pgrp.dupfgrp(null) catch null;
    if (f) |old|
        h9_fgrpclose(old);
    _ = c.strecpy(&p.user, @as([*c]u8, &p.user) + p.user.len, &nsuser);
    const line = std.mem.span(x.line);
    const m = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
    const cmd = line[0..@min(m, 15)];
    var a = m;
    while (a < line.len and (line[a] == ' ' or line[a] == '\t'))
        a += 1;
    if (!isnsline(cmd)) {
        // bind, mount, unmount, cd, post: the Zig leaf, in n.
        const s = nsenter(n);
        if (h9_ns_ctl(n, x.line, @intCast(line.len), &x.err) < 0)
            x.failed = true;
        nsleave(n, &s, true);
    } else nsline(n, cmd, x.line + a) catch {
        chan.kstrcpy(&x.err, up().errstr, x.err.len);
        x.failed = true;
    };
    n.used = true;
    x.done.store(1, .release);
    _ = sync.wakeup(&x.r);
    ctlput(x);
    h9_kprocunshare();
}

/// Runs one line in its namespace, on a process of its own.
fn ctlproc(a: ?*anyopaque) callconv(.c) void {
    ctlrun(@ptrCast(@alignCast(a.?)));
    c.pexit(@constCast(""), 0);
}

fn ctldone(a: ?*anyopaque) callconv(.c) c_int {
    const x: *Ctl = @ptrCast(@alignCast(a.?));
    return x.done.load(.acquire);
}

/// Runs line in n, with its error.
fn runctl(n: *Ns, line: [*:0]const u8) Error!void {
    const x = create(Ctl) orelse return port.kerror(&port.Enomem);
    x.line = @as(?[*:0]u8, @ptrCast(c.strdup(line))) orelse {
        c.free(x);
        return port.kerror(&port.Enomem);
    };
    x.ns = n;
    c.lock(&nslock);
    n.ref += 1;
    c.unlock(&nslock);
    x.ref.ref = 2;
    _ = c.kproc(@constCast("nsctl"), &ctlproc, x);
    defer ctlput(x);
    try sync.sleep(&x.r, &ctldone, x);
    if (x.failed) {
        var err: [port.ERRMAX]u8 = undefined;
        chan.kstrcpy(&err, @ptrCast(&x.err), err.len);
        return port.kerror(@ptrCast(&err));
    }
}

fn nswrite(ch: *Chan, va: ?*const anyopaque, n: c_int, off: i64) Error!c_int {
    _ = off;
    if (QTYPE(ch.qid.path) != Qctl)
        return port.kerror(&port.Eperm);
    if (n > Maxctl)
        return port.kerror(&port.Etoobig);
    const ns = nsof(ch);
    const len: usize = @intCast(n);
    const buf: [*]u8 = @ptrCast(c.smalloc(@intCast(len + 1)));
    defer c.free(buf);
    @memcpy(buf[0..len], @as([*]const u8, @ptrCast(va.?))[0..len]);
    buf[len] = 0;
    sync.qlock(&ns.ctl);
    defer sync.qunlock(&ns.ctl);
    var p: [*:0]u8 = @ptrCast(buf);
    while (p[0] != 0) {
        const rest = std.mem.span(p);
        var e: [*:0]u8 = undefined;
        if (std.mem.indexOfScalar(u8, rest, '\n')) |i| {
            p[i] = 0;
            e = p + i + 1;
        } else e = p + rest.len;
        while (p[0] == ' ' or p[0] == '\t')
            p += 1;
        if (p[0] != 0 and p[0] != '#')
            try runctl(ns, p);
        p = e;
    }
    return n;
}

pub const Device = dev.Native('N', "ns", .{
    .attach = nsattach,
    .walk = nswalk,
    .stat = nsstat,
    .open = nsopen,
    .create = dev.devcreate,
    .close = nsclose,
    .read = nsread,
    .write = nswrite,
    .remove = dev.devremove,
    .wstat = dev.devwstat,
    .gens = &.{&nsgen},
});

// Connections for the namespace kernel's serving process
// (src/nskernel.zig): posted from any thread, a host thread's or a
// stream's, and taken by the server, which sleeps here.

const Nsreq = struct {
    next: ?*Nsreq = null,
    kind: c_int = 0,
    arg: c_long = 0,
    aname: [*:0]u8 = undefined,
};

var reqs: struct {
    lk: c.Lock = std.mem.zeroes(c.Lock),
    head: ?*Nsreq = null,
    tail: ?*?*Nsreq = null,
    r: c.Rendez = std.mem.zeroes(c.Rendez),
} = .{};

/// Posts a connection: kind and arg are the server's, aname its attach
/// name. Returns 0, or -1 out of memory.
fn h9_ns_post(kind: c_int, arg: c_long, aname: ?[*:0]const u8) callconv(.c) c_int {
    const q = create(Nsreq) orelse return -1;
    q.aname = @as(?[*:0]u8, @ptrCast(c.strdup(aname orelse ""))) orelse {
        c.free(q);
        return -1;
    };
    q.kind = kind;
    q.arg = arg;
    q.next = null;
    c.lock(&reqs.lk);
    if (reqs.tail == null)
        reqs.tail = &reqs.head;
    reqs.tail.?.* = q;
    reqs.tail = &q.next;
    c.unlock(&reqs.lk);
    _ = sync.wakeup(&reqs.r);
    return 0;
}

fn havereq(a: ?*anyopaque) callconv(.c) c_int {
    _ = a;
    return @intFromBool(@atomicLoad(?*Nsreq, &reqs.head, .acquire) != null);
}

/// The next connection posted, its attach name copied to aname (n
/// bytes). Sleeps until there is one. Returns 0, or -1 if interrupted.
fn h9_ns_next(kind: *c_int, arg: *c_long, aname: [*]u8, n: c_int) callconv(.c) c_int {
    sync.sleep(&reqs.r, &havereq, null) catch return -1;
    c.lock(&reqs.lk);
    const q = reqs.head.?;
    reqs.head = q.next;
    if (reqs.head == null)
        reqs.tail = &reqs.head;
    c.unlock(&reqs.lk);
    kind.* = q.kind;
    arg.* = q.arg;
    _ = c.strecpy(aname, aname + @as(usize, @intCast(n)), q.aname);
    c.free(q.aname);
    c.free(q);
    return 0;
}

pub fn exportC() void {
    @export(&Device.dev, .{ .name = "nsdevtab" });
    @export(&h9_ns_init, .{ .name = "h9_ns_init" });
    @export(&h9_ns_lookup, .{ .name = "h9_ns_lookup" });
    @export(&h9_ns_dialed, .{ .name = "h9_ns_dialed" });
    @export(&h9_ns_hostsrv, .{ .name = "h9_ns_hostsrv" });
    @export(&h9_ns_srvpost, .{ .name = "h9_ns_srvpost" });
    @export(&h9_ns_post, .{ .name = "h9_ns_post" });
    @export(&h9_ns_next, .{ .name = "h9_ns_next" });
}

// Cases (zig build kern-test). #N needs the namespace kernel booted by
// h9ns_boot's process, which h9_ns_init expects; these cover what runs
// without it.

const testing = std.testing;

test "flagstr spells mount flags as newns does [kernel-port]" {
    var b: [8]u8 = undefined;
    try testing.expectEqualStrings("", std.mem.span(flagstr(c.MREPL, &b)));
    try testing.expectEqualStrings("-b", std.mem.span(flagstr(c.MBEFORE, &b)));
    try testing.expectEqualStrings("-ac", std.mem.span(flagstr(c.MAFTER | c.MCREATE, &b)));
    try testing.expectEqualStrings("-bcC", std.mem.span(flagstr(c.MBEFORE | c.MCREATE | c.MCACHE, &b)));
}

test "attach names are namespace ids, with no leading zeros [kernel-port]" {
    try testing.expectEqual(@as(?c_ulong, 0), parseid("0"));
    try testing.expectEqual(@as(?c_ulong, 12), parseid("12"));
    try testing.expectEqual(@as(?c_ulong, null), parseid("012"));
    try testing.expectEqual(@as(?c_ulong, null), parseid("1x"));
    try testing.expect(h9_ns_lookup("x") == null);
}

test "a namespace from #N/clone runs its ctl lines and prints its table [kernel-port]" {
    _ = try port.testing.namespace();
    const fd = try sysfile.open("#N/clone", c.ORDWR);
    defer _ = sysfile.close(fd) catch {};
    var buf: [256]u8 = undefined;
    const n = try sysfile.pread(fd, &buf, buf.len, 0);
    const id = buf[0..@intCast(n)];
    try testing.expect(parseid(id) != null);
    const ok = "empty\n# a comment\n\nclear\n";
    try testing.expectEqual(@as(c_int, ok.len), try sysfile.pwrite(fd, ok, ok.len, 0));
    // copy is the first line only.
    try testing.expectError(error.Kernel, sysfile.pwrite(fd, "copy 0", 6, 0));
    try testing.expectEqualStrings("copy must be the first line", port.testing.errstr());
    try testing.expectEqual(9, try sysfile.pwrite(fd, "hold\nfree", 9, 0));

    var path: [64]u8 = undefined;
    const nspath = try std.mem.printSentinel(&path, "#N/{s}/ns", .{id}, 0);
    const nfd = try sysfile.open(nspath, c.OREAD);
    defer _ = sysfile.close(nfd) catch {};
    const m = try sysfile.pread(nfd, &buf, buf.len, 0);
    try testing.expectEqualStrings("cd /\n", buf[0..@intCast(m)]);
    try testing.expectError(error.Kernel, sysfile.open(nspath, c.OWRITE));
}
