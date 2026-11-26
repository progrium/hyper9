//! drawterm's dev.c (design/kernel-port.md): the helpers devices are
//! built from (devattach, devwalk, devstat, devdirread, devopen, and the
//! rest), and the device switch, through which the Zig kernel calls a
//! device. A close translation: the same functions in the same order,
//! with error unions in place of C's error labels.
//!
//! The switch is the bottom half of this file. A device is still a C
//! `Dev` in `devtab` (src/kern/devtab.c, or nstab.c in the namespace
//! kernel), and the switch calls a C device's functions, and a C Devgen,
//! through `raising`, which catches the device's error() under the one
//! label h9 sets (third_party/drawterm-glue/catch.c) and hands it back
//! as an error union. A device ported to Zig is a `Native`
//! in `natives`, and the switch calls its Zig functions directly.
//!
//! drawterm's devtab.c is h9's own src/kern/devtab.c and nstab.c, which
//! are C until h9's devices are ported, since the table names them.

const std = @import("std");
const port = @import("port.zig");
const qio = @import("qio.zig");
const chan = @import("chan.zig");
const sysfile = @import("sysfile.zig");
pub const rd = @import("ready.zig");
const c = port.c;
const up = port.up;
const Error = port.Error;

const Chan = c.Chan;
const Dev = c.Dev;
const Dir = c.Dir;
const Dirtab = c.Dirtab;
const Qid = c.Qid;
const Walkqid = c.Walkqid;
const Block = c.Block;
pub const Attr = c.Attr;

/// DMDIR as a long, for a Dirtab perm or devdir.
pub const dmdir: c_int = @bitCast(@as(c_uint, c.DMDIR));

/// A Dirtab entry, for a device's table.
pub fn dirtab(comptime name: []const u8, qid: Qid, length: i64, perm: c_int) Dirtab {
    var d = std.mem.zeroes(Dirtab);
    @memcpy(d.name[0..name.len], name);
    d.qid = qid;
    d.length = length;
    d.perm = perm;
    return d;
}

/// A C Devgen: int (*)(Chan*, char*, Dirtab*, int, int, Dir*).
pub const Devgen = fn ([*c]Chan, [*c]u8, [*c]Dirtab, c_int, c_int, [*c]Dir) callconv(.c) c_int;

extern var kerndate: c_uint;

/// The device table, an array C declares as `Dev *devtab[]`, ended by nil.
extern var devtab: [0]?*Dev;

pub fn table() [*]?*Dev {
    return @ptrCast(&devtab);
}

/// devtab[c->type].
pub fn of(ch: *const Chan) *Dev {
    return table()[ch.type].?;
}

pub fn mkqid(q: *Qid, path: i64, vers: c_uint, @"type": c_int) void {
    q.type = @truncate(@as(c_uint, @bitCast(@"type")));
    q.vers = vers;
    q.path = @bitCast(path);
}

pub fn devno(ch: c_int) c_int {
    var i: usize = 0;
    while (table()[i]) |d| : (i += 1) {
        if (d.dc == ch)
            return @intCast(i);
    }
    return -1;
}

pub fn devdir(ch: *Chan, qid_: Qid, n: [*c]u8, length: i64, user: [*c]u8, perm: c_int, db: *Dir) void {
    var qid = qid_;
    db.name = n;
    if (ch.flag & c.CMSG != 0)
        qid.type |= c.QTMOUNT;
    db.qid = qid;
    db.type = @intCast(of(ch).dc);
    db.dev = ch.dev;
    db.mode = @bitCast(@as(c_int, @truncate(perm)));
    db.mode |= @as(c_uint, qid.type) << 24;
    db.atime = @bitCast(@as(c_int, @truncate(c.seconds())));
    db.mtime = kerndate;
    db.length = length;
    db.uid = user;
    db.gid = c.eve;
    db.muid = user;
}

// (Here, Devgen is the prototype; devgen is the function in dev.c.)
//
// A Devgen is expected to return the directory entry for ".." if you
// pass it s==DEVDOTDOT (-1). Otherwise...
//
// There are two contradictory rules.
//
// (i) If c is a directory, a Devgen is expected to list its children as
// you iterate s.
//
// (ii) Whether or not c is a directory, a Devgen is expected to list its
// siblings as you iterate s.
//
// devgen always returns the list of children in the root directory.
// Thus it follows (i) when c is the root and (ii) otherwise. Many other
// Devgens follow (i) when c is a directory and (ii) otherwise.
//
// devwalk assumes (i). It knows that devgen breaks (i) for children
// that are themselves directories, and explicitly catches them.
//
// devstat assumes (ii). If the Devgen in question follows (i) for this
// particular c, devstat will not find the necessary info. With our
// particular Devgen functions, this happens only for directories, so
// devstat makes something up, assuming c->name, c->qid, eve, DMDIR|0555.
//
// devdirread assumes (i). The callers have to make sure that the Devgen
// satisfies (i) for the chan being read.

/// The zeroth element of the table MUST be the directory itself for ..
pub fn devgen(ch: *Chan, name: ?[*:0]const u8, tab_: ?[*]Dirtab, ntab: c_int, i_: c_int, dp: *Dir) c_int {
    var tab = tab_ orelse return -1;
    var i = i_;
    if (i == c.DEVDOTDOT) {
        // nothing
    } else if (name) |nm| {
        i = 1;
        while (i < ntab) : (i += 1)
            if (streq(@ptrCast(&tab[@intCast(i)].name), nm))
                break;
        if (i == ntab)
            return -1;
        tab += @intCast(i);
    } else {
        // skip over the first element, that for . itself
        i += 1;
        if (i >= ntab)
            return -1;
        tab += @intCast(i);
    }
    devdir(ch, tab[0].qid, &tab[0].name, tab[0].length, c.eve, tab[0].perm, dp);
    return 1;
}

pub fn devreset() void {}

pub fn devinit() void {}

pub fn devshutdown() void {}

pub fn devattach(tc: c_int, spec_: ?[*:0]const u8) *Chan {
    const spec: [*:0]const u8 = spec_ orelse "";
    const ch: *Chan = chan.newchan();
    mkqid(&ch.qid, 0, 0, c.QTDIR);
    ch.type = @intCast(devno(tc));
    // snprint(buf, n, "#%C%s", tc, spec)
    const n: usize = 1 + @as(usize, c.UTFmax) + std.mem.len(spec) + 1;
    const buf: [*]u8 = @ptrCast(c.smalloc(@intCast(n)));
    buf[0] = '#';
    var r: c.Rune = @intCast(tc);
    const k: usize = @intCast(c.runetochar(buf + 1, &r));
    @memcpy(buf[1 + k ..][0 .. std.mem.len(spec) + 1], spec[0 .. std.mem.len(spec) + 1]);
    ch.path = chan.newpath(@ptrCast(buf));
    c.free(buf);
    return ch;
}

pub fn devclone(ch: *Chan) *Chan {
    if (ch.flag & c.COPEN != 0)
        port.kpanic("clone of open file type %C", .{of(ch).dc});

    const nc: *Chan = chan.newchan();

    nc.type = ch.type;
    nc.dev = ch.dev;
    nc.mode = ch.mode;
    nc.qid = ch.qid;
    nc.offset = ch.offset;
    nc.umh = null;
    aux(nc).* = aux(ch).*;
    nc.mqid = ch.mqid;
    return nc;
}

/// A Walkqid with room for n qids.
pub fn walkqid(n: usize) *Walkqid {
    const size = @offsetOf(Walkqid, "qid") + @max(n, 1) * @sizeOf(Qid);
    return @ptrCast(@alignCast(c.smalloc(@intCast(size))));
}

/// wq.qid as a slice of n.
pub fn qids(wq: *Walkqid) [*]Qid {
    return @ptrCast(&wq.qid);
}

/// A walk of c's directory to the names: an error if c isn't one, and
/// otherwise nil (with the error string set) for a walk that failed at
/// its first name.
pub fn devwalk(ch: *Chan, nc_: ?*Chan, name: [*]const [*:0]const u8, nname: c_int, tab: ?[*]Dirtab, ntab: c_int, gen: *const Devgen) Error!?*Walkqid {
    if (nname > 0)
        try chan.isdir(ch);

    const alloc = nc_ == null;
    const wq = walkqid(@intCast(nname));
    walk(ch, nc_, name, nname, tab, ntab, gen, wq) catch {
        if (alloc and wq.libclone != null)
            chan.cclose(wq.libclone);
        c.free(wq);
        return null;
    };
    if (wq.nqid < nname) {
        if (alloc)
            chan.cclose(wq.libclone);
        wq.libclone = null;
    } else if (@as(?*Chan, wq.libclone)) |cl| {
        // attach cloned channel to same device
        cl.type = ch.type;
    }
    return wq;
}

/// devwalk's loop: the names it walks, into wq. An error is what
/// devwalk's error label caught, and a short walk returns.
fn walk(ch: *Chan, nc_: ?*Chan, name: [*]const [*:0]const u8, nname: c_int, tab: ?[*]Dirtab, ntab: c_int, gen: *const Devgen, wq: *Walkqid) Error!void {
    const nc = nc_ orelse blk: {
        const n = devclone(ch);
        n.type = 0; // device doesn't know about this channel yet
        break :blk n;
    };
    wq.libclone = nc;
    const q = qids(wq);
    var dir: Dir = undefined;

    var j: usize = 0;
    names: while (j < nname) : (j += 1) {
        if (nc.qid.type & c.QTDIR == 0) {
            if (j == 0)
                return port.kerror(&port.Enotdir);
            return;
        }
        const n = name[j];
        if (streq(n, ".")) {
            q[@intCast(wq.nqid)] = nc.qid;
            wq.nqid += 1;
            continue;
        }
        if (streq(n, "..")) {
            if (try callgen(gen, nc, null, tab, ntab, c.DEVDOTDOT, &dir) != 1) {
                port.print("devgen walk .. in dev%s %llux broken\n", .{ of(nc).name, nc.qid.path });
                return port.kerror("broken devgen");
            }
            nc.qid = dir.qid;
            q[@intCast(wq.nqid)] = nc.qid;
            wq.nqid += 1;
            continue;
        }
        // Ugly problem: If we're using devgen, make sure we're walking
        // the directory itself, represented by the first entry in the
        // table, and not trying to step into a sub-directory of the
        // table, e.g. /net/net. Devgen itself should take care of the
        // problem, but it doesn't have the necessary information (that
        // we're doing a walk).
        const notfound = gen == &c_devgen and nc.qid.path != tab.?[0].qid.path;
        var i: c_int = 0;
        while (true) : (i += 1) {
            const r: c_int = if (notfound) -1 else try callgen(gen, nc, n, tab, ntab, i, &dir);
            switch (r) {
                -1 => {
                    // Notfound:
                    if (j == 0)
                        return port.kerror(&port.Enonexist);
                    chan.kstrcpy(up().errstr, &port.Enonexist, port.ERRMAX);
                    return;
                },
                0 => continue,
                1 => if (streq(n, dir.name)) {
                    nc.qid = dir.qid;
                    q[@intCast(wq.nqid)] = nc.qid;
                    wq.nqid += 1;
                    continue :names;
                },
                else => {},
            }
        }
    }
    // We processed at least one name, so will return some data. If we
    // didn't process all nname entries succesfully, devwalk drops the
    // cloned channel and returns just the Qids of the walks.
}

pub fn devstat(ch: *Chan, db: [*]u8, n_: c_int, tab: ?[*]Dirtab, ntab: c_int, gen: *const Devgen) Error!c_int {
    var dir: Dir = undefined;
    var i: c_int = 0;
    while (true) : (i += 1) {
        switch (try callgen(gen, ch, null, tab, ntab, i, &dir)) {
            -1 => {
                if (ch.qid.type & c.QTDIR != 0) {
                    var elem: [*:0]const u8 = undefined;
                    if (@as(?*c.Path, ch.path)) |path| {
                        const s: [*:0]const u8 = path.s;
                        if (streq(s, "/")) {
                            elem = "/";
                        } else {
                            elem = s;
                            var p = s;
                            while (p[0] != 0) : (p += 1)
                                if (p[0] == '/') {
                                    elem = p + 1;
                                };
                        }
                    } else elem = "???";
                    devdir(ch, ch.qid, @constCast(elem), 0, c.eve, dmdir | 0o555, &dir);
                    const n = c.convD2M(&dir, db, @intCast(n_));
                    if (n == 0)
                        return port.kerror(&port.Ebadarg);
                    return @intCast(n);
                }

                return port.kerror(&port.Enonexist);
            },
            0 => {},
            1 => if (ch.qid.path == dir.qid.path) {
                if (ch.flag & c.CMSG != 0)
                    dir.mode |= c.DMMOUNT;
                const n = c.convD2M(&dir, db, @intCast(n_));
                if (n == 0)
                    return port.kerror(&port.Ebadarg);
                return @intCast(n);
            },
            else => {},
        }
    }
}

pub fn devdirread(ch: *Chan, d_: [*]u8, n: c_int, tab: ?[*]Dirtab, ntab: c_int, gen: *const Devgen) Error!c_int {
    var d = d_;
    var m: c_int = 0;
    var dir: Dir = undefined;
    while (m < n) : (ch.dri += 1) {
        switch (try callgen(gen, ch, null, tab, ntab, ch.dri, &dir)) {
            -1 => return m,
            0 => {},
            1 => {
                const dsz: c_int = @intCast(c.convD2M(&dir, d, @intCast(n - m)));
                if (dsz <= c.BIT16SZ) { // <= not < because this isn't stat; read is stuck
                    if (m == 0)
                        return port.kerror(&port.Eshort);
                    return m;
                }
                m += dsz;
                d += @intCast(dsz);
            },
            else => {},
        }
    }

    return m;
}

/// error(Eperm) if open permission not granted for up->user.
pub fn devpermcheck(fileuid: [*:0]const u8, perm_: c_uint, omode: c_int) Error!void {
    const access = [_]c_uint{ 0o400, 0o200, 0o600, 0o100 };
    var perm = perm_;

    if (streq(@ptrCast(&up().user), fileuid))
        perm <<= 0
    else if (streq(@ptrCast(&up().user), c.eve))
        perm <<= 3
    else
        perm <<= 6;

    const t = access[@intCast(omode & 3)];
    if ((t & perm) != t)
        return port.kerror(&port.Eperm);
}

pub fn devopen(ch: *Chan, omode: c_int, tab: ?[*]Dirtab, ntab: c_int, gen: *const Devgen) Error!*Chan {
    var dir: Dir = undefined;
    var i: c_int = 0;
    find: while (true) : (i += 1) {
        switch (try callgen(gen, ch, null, tab, ntab, i, &dir)) {
            -1 => break :find,
            0 => {},
            1 => if (ch.qid.path == dir.qid.path) {
                try devpermcheck(dir.uid, dir.mode, omode);
                break :find;
            },
            else => {},
        }
    }
    // Return:
    ch.offset = 0;
    if ((ch.qid.type & c.QTDIR != 0) and omode != c.OREAD)
        return port.kerror(&port.Eperm);
    ch.mode = @intCast(try sysfile.openmode(@bitCast(omode)));
    ch.flag |= c.COPEN;
    return ch;
}

pub fn devcreate(ch: *Chan, name: [*:0]const u8, mode: c_int, perm: c_uint) Error!*Chan {
    _ = .{ ch, name, mode, perm };
    return port.kerror(&port.Eperm);
}

pub fn devbread(ch: *Chan, n: c_int, offset: c_uint) Error!*Block {
    const bp = qio.allocb(@intCast(n));
    // (allocb doesn't fail: it panics.)
    errdefer qio.freeb(bp);
    bp.wp += @intCast(try read(of(ch), ch, bp.wp, n, offset));
    return bp;
}

pub fn devbwrite(ch: *Chan, bp: *Block, offset: c_uint) Error!c_int {
    defer qio.freeb(bp);
    return write(of(ch), ch, bp.rp, @intCast(@intFromPtr(bp.wp) - @intFromPtr(bp.rp)), offset);
}

pub fn devremove(ch: *Chan) Error!void {
    _ = ch;
    return port.kerror(&port.Eperm);
}

pub fn devwstat(ch: *Chan, a: [*]u8, n: c_int) Error!c_int {
    _ = .{ ch, a, n };
    return port.kerror(&port.Eperm);
}

pub fn devpower(a: c_int) Error!void {
    _ = a;
    return port.kerror(&port.Eperm);
}

pub fn devconfig(a: c_int, b: [*c]u8, cf: ?*c.DevConf) Error!c_int {
    _ = .{ a, b, cf };
    return port.kerror(&port.Eperm);
}

/// strcmp(a, b) == 0.
pub fn streq(a: [*:0]const u8, b: [*:0]const u8) bool {
    return std.mem.orderZ(u8, a, b) == .eq;
}

/// A Chan's aux, in its anonymous union with mid (translate-c's
/// `unnamed_0`).
pub fn aux(ch: *Chan) *?*anyopaque {
    return &ch.unnamed_0.aux;
}

// The device switch.

/// A device ported to Zig: its functions, with error unions.
pub const Ops = struct {
    reset: *const fn () void = devreset,
    init: *const fn () void = devinit,
    shutdown: *const fn () void = devshutdown,
    attach: *const fn ([*:0]const u8) Error!*Chan,
    walk: *const fn (*Chan, ?*Chan, [*]const [*:0]const u8, c_int) Error!?*Walkqid,
    stat: *const fn (*Chan, [*]u8, c_int) Error!c_int,
    open: *const fn (*Chan, c_int) Error!*Chan,
    create: *const fn (*Chan, [*:0]const u8, c_int, c_uint) Error!*Chan,
    close: *const fn (*Chan) Error!void,
    read: *const fn (*Chan, ?*anyopaque, c_int, i64) Error!c_int,
    bread: *const fn (*Chan, c_int, c_uint) Error!?*Block = devbreadOpt,
    write: *const fn (*Chan, ?*const anyopaque, c_int, i64) Error!c_int,
    bwrite: *const fn (*Chan, *Block, c_uint) Error!c_int = devbwrite,
    remove: *const fn (*Chan) Error!void,
    wstat: *const fn (*Chan, [*]u8, c_int) Error!c_int,
    /// The device's own Devgens, which are Zig that doesn't raise, so
    /// callgen calls them directly.
    gens: []const *const Devgen = &.{},
    /// The device's own Devgens that can fail (`Egen`): callgen calls
    /// their Zig directly.
    egens: []const Egen = &.{},

    // The optional operations (design/file-interface.md, src/kern/devx.h):
    // null takes the switch's default.

    /// The target of the link ch is, into buf: its length, or null if
    /// ch isn't a link.
    readlink: ?*const fn (*Chan, []u8) Error!?usize = null,
    symlink: ?*const fn (*Chan, [*:0]const u8, [*:0]const u8) Error!void = null,
    /// False if the device can't, for the default (a copy).
    link: ?*const fn (*Chan, *Chan, [*:0]const u8) Error!bool = null,
    getattr: ?*const fn (*Chan, u64, *Attr) Error!void = null,
    setattr: ?*const fn (*Chan, u64, *const Attr) Error!void = null,
    /// False if the device can't, for the default to try.
    rename: ?*const fn (*Chan, *Chan, [*:0]const u8) Error!bool = null,
    /// Whether getattr says more than stat for ch, if it doesn't always,
    /// so a stat needn't ask twice where it says no more.
    hasattr: ?*const fn (*Chan) bool = null,
    /// ch's Dir, from the Attr its getattr just gave, into a buffer of
    /// n: its length, or null where a stat says more (or differs), so a
    /// stat with attributes asks the device once.
    attrstat: ?*const fn (*Chan, *const Attr, [*]u8, c_int) ?c_int = null,

    // Readiness (ready.zig, Part 1).

    /// The events of ev ready on ch now (ready.zig's bits), plus an
    /// error or a hangup, which are always reported.
    ready: ?*const fn (*Chan, c_int) c_int = null,
    /// Hangs w, with waker wk, on what ch's readiness comes from, for a
    /// call when it may have changed; ready.unwatch takes it off.
    watch: ?*const fn (*Chan, c_int, *rd.Watch, *rd.Waker) void = null,

    // Part 3.

    /// Makes what was written to ch's file durable, only its data (and
    /// the size) if datasync.
    fsync: ?*const fn (*Chan, bool) Error!void = null,
};

/// A Devgen in Zig that can fail, as a C Devgen can raise.
pub const Zgen = fn (*Chan, ?[*:0]const u8, ?[*]Dirtab, c_int, c_int, *Dir) Error!c_int;

/// A native device's Devgen that can fail: `z`, and `c`, its C form
/// (which raises), the Devgen devwalk and the rest are handed.
pub const Egen = struct { c: *const Devgen, z: *const Zgen };

/// z as an Egen.
pub fn egen(comptime z: Zgen) Egen {
    const W = struct {
        fn gen(ch: [*c]Chan, name: [*c]u8, tab: [*c]Dirtab, ntab: c_int, i: c_int, dp: [*c]Dir) callconv(.c) c_int {
            return z(ch, name, tab, ntab, i, dp) catch |e| port.raise(e);
        }
    };
    return .{ .c = &W.gen, .z = &z };
}

fn devbreadOpt(ch: *Chan, n: c_int, offset: c_uint) Error!?*Block {
    return try devbread(ch, n, offset);
}

/// A native device: `ops`, which the switch calls directly, and `dev`,
/// the C Dev the device table names, whose functions raise for C
/// callers.
pub fn Native(comptime dc: c_int, comptime name: [:0]const u8, comptime o: Ops) type {
    return struct {
        pub const ops = o;

        fn c_reset() callconv(.c) void {
            o.reset();
        }
        fn c_init() callconv(.c) void {
            o.init();
        }
        fn c_shutdown() callconv(.c) void {
            o.shutdown();
        }
        fn c_attach(spec: [*c]u8) callconv(.c) [*c]Chan {
            return o.attach(spec orelse "") catch |e| port.raise(e);
        }
        fn c_walk(ch: [*c]Chan, nc: [*c]Chan, nm: [*c][*c]u8, n: c_int) callconv(.c) [*c]Walkqid {
            return o.walk(ch, nc, @ptrCast(nm), n) catch |e| port.raise(e);
        }
        fn c_stat(ch: [*c]Chan, db: [*c]u8, n: c_int) callconv(.c) c_int {
            return o.stat(ch, db, n) catch |e| port.raise(e);
        }
        fn c_open(ch: [*c]Chan, omode: c_int) callconv(.c) [*c]Chan {
            return o.open(ch, omode) catch |e| port.raise(e);
        }
        fn c_create(ch: [*c]Chan, nm: [*c]u8, omode: c_int, perm: c_uint) callconv(.c) [*c]Chan {
            return o.create(ch, nm, omode, perm) catch |e| port.raise(e);
        }
        fn c_close(ch: [*c]Chan) callconv(.c) void {
            o.close(ch) catch |e| port.raise(e);
        }
        fn c_read(ch: [*c]Chan, a: ?*anyopaque, n: c_int, off: i64) callconv(.c) c_int {
            return o.read(ch, a, n, off) catch |e| port.raise(e);
        }
        fn c_bread(ch: [*c]Chan, n: c_int, off: c_uint) callconv(.c) [*c]Block {
            return o.bread(ch, n, off) catch |e| port.raise(e);
        }
        fn c_write(ch: [*c]Chan, a: ?*anyopaque, n: c_int, off: i64) callconv(.c) c_int {
            return o.write(ch, a, n, off) catch |e| port.raise(e);
        }
        fn c_bwrite(ch: [*c]Chan, b: [*c]Block, off: c_uint) callconv(.c) c_int {
            return o.bwrite(ch, b, off) catch |e| port.raise(e);
        }
        fn c_remove(ch: [*c]Chan) callconv(.c) void {
            o.remove(ch) catch |e| port.raise(e);
        }
        fn c_wstat(ch: [*c]Chan, db: [*c]u8, n: c_int) callconv(.c) c_int {
            return o.wstat(ch, db, n) catch |e| port.raise(e);
        }

        pub var dev: Dev = .{
            .dc = dc,
            .name = @constCast(name.ptr),
            .reset = &c_reset,
            .init = &c_init,
            .shutdown = &c_shutdown,
            .attach = &c_attach,
            .walk = &c_walk,
            .stat = &c_stat,
            .open = &c_open,
            .create = &c_create,
            .close = &c_close,
            .read = &c_read,
            .bread = &c_bread,
            .write = &c_write,
            .bwrite = &c_bwrite,
            .remove = &c_remove,
            .wstat = &c_wstat,
        };
    };
}

/// The native devices, whose functions the switch calls directly.
const natives = .{
    @import("devmnt.zig").Device,
    @import("dev/pipe.zig").Device,
    @import("dev/root.zig").Device,
    @import("dev/pty.zig").Device,
    @import("dev/hstream.zig").Device,
    @import("dev/srv.zig").Device,
    @import("dev/overlay.zig").Device,
    @import("dev/dotl.zig").Device,
} ++ (if (port.options.hostfs) .{
    // The host's tree (src/host/devfs.zig).
    @import("host_dev").fs.Device,
} else .{}) ++ (if (port.options.nskernel) .{
    @import("dev/ns.zig").Device,
} else .{
    // h9's own, which the namespace kernel doesn't build.
    @import("dev/proc.zig").Device,
    @import("dev/eventfd.zig").Device,
    @import("dev/hcons.zig").Device,
    @import("dev/env.zig").Device,
    @import("dev/hidx.zig").Device,
    @import("dev/linux.zig").Device,
    // The host's network (src/host/devip.zig).
    @import("host_dev").ip.Device,
}) ++ (if (port.options.gfx) .{
    @import("dev/gfx.zig").Draw,
    @import("dev/gfx.zig").Cons,
    @import("dev/gfx.zig").Kbd,
    @import("dev/gfx.zig").Mouse,
} else .{});

/// d's functions, if it's native.
fn nativeOps(d: *Dev) ?*const Ops {
    inline for (natives) |N| {
        if (d == &N.dev) return &N.ops;
    }
    return null;
}

// third_party/drawterm-glue/catch.c: f(arg), or -1 if it raised, with
// the error string on the process.
extern fn h9_catch(f: *const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque) c_int;

fn Result(comptime F: type) type {
    const P = @typeInfo(F).pointer.child;
    return @typeInfo(P).@"fn".return_type.?;
}

/// f(args...), for C that can raise: drawterm's devices and the rest of
/// its code h9 builds. The call runs under drawterm-glue's label, and an
/// error() in it comes back as an error union. f is a C function
/// pointer, and the trampoline between the label and it is a Zig frame
/// with nothing to undo.
pub fn raising(f: anytype, args: anytype) Error!Result(@TypeOf(f)) {
    const Call = struct {
        f: @TypeOf(f),
        args: @TypeOf(args),
        r: Result(@TypeOf(f)) = undefined,
        fn run(p: ?*anyopaque) callconv(.c) void {
            const call: *@This() = @ptrCast(@alignCast(p.?));
            call.r = @call(.auto, call.f, call.args);
        }
    };
    var call: Call = .{ .f = f, .args = args };
    try caught(h9_catch(&Call.run, &call));
    return call.r;
}

/// The error a C function `raising` called raised, which is on the
/// process: Interrupted if it was Eintr.
pub fn caught(rc: c_int) Error!void {
    if (rc == 0) return;
    if (streq(up().errstr, &port.Eintr)) return error.Interrupted;
    return error.Kernel;
}

pub fn reset(d: *Dev) Error!void {
    if (nativeOps(d)) |o| return o.reset();
    try raising(d.reset.?, .{});
}

pub fn init(d: *Dev) Error!void {
    if (nativeOps(d)) |o| return o.init();
    try raising(d.init.?, .{});
}

pub fn shutdown(d: *Dev) Error!void {
    if (nativeOps(d)) |o| return o.shutdown();
    try raising(d.shutdown.?, .{});
}

pub fn attach(d: *Dev, spec: [*:0]const u8) Error!*Chan {
    if (nativeOps(d)) |o| return o.attach(spec);
    return try raising(d.attach.?, .{@constCast(spec)});
}

/// A device's walk, which returns nil (with the error string set) for a
/// walk that failed at its first name.
pub fn walkdev(d: *Dev, ch: *Chan, nc: ?*Chan, name: [*]const [*:0]const u8, nname: c_int) Error!?*Walkqid {
    if (nativeOps(d)) |o| return o.walk(ch, nc, name, nname);
    return try raising(d.walk.?, .{ ch, nc, @as([*c][*c]u8, @ptrCast(@constCast(name))), nname });
}

pub fn stat(d: *Dev, ch: *Chan, db: [*]u8, n: c_int) Error!c_int {
    if (nativeOps(d)) |o| return o.stat(ch, db, n);
    return try raising(d.stat.?, .{ ch, db, n });
}

pub fn open(d: *Dev, ch: *Chan, omode: c_int) Error!*Chan {
    if (nativeOps(d)) |o| return o.open(ch, omode);
    return try raising(d.open.?, .{ ch, omode });
}

pub fn create(d: *Dev, ch: *Chan, name: [*:0]const u8, omode: c_int, perm: c_uint) Error!*Chan {
    if (nativeOps(d)) |o| return o.create(ch, name, omode, perm);
    return try raising(d.create.?, .{ ch, @constCast(name), omode, perm });
}

pub fn close(d: *Dev, ch: *Chan) Error!void {
    if (nativeOps(d)) |o| return o.close(ch);
    try raising(d.close.?, .{ch});
}

pub fn read(d: *Dev, ch: *Chan, a: ?*anyopaque, n: c_int, off: i64) Error!c_int {
    if (nativeOps(d)) |o| return o.read(ch, a, n, off);
    return try raising(d.read.?, .{ ch, a, n, off });
}

pub fn bread(d: *Dev, ch: *Chan, n: c_int, off: c_uint) Error!?*Block {
    if (nativeOps(d)) |o| return o.bread(ch, n, off);
    return try raising(d.bread.?, .{ ch, n, off });
}

pub fn write(d: *Dev, ch: *Chan, a: ?*const anyopaque, n: c_int, off: i64) Error!c_int {
    if (nativeOps(d)) |o| return o.write(ch, a, n, off);
    return try raising(d.write.?, .{ ch, @constCast(a), n, off });
}

/// A device's bwrite, which frees b, whatever happens.
pub fn bwrite(d: *Dev, ch: *Chan, b: *Block, off: c_uint) Error!c_int {
    if (nativeOps(d)) |o| return o.bwrite(ch, b, off);
    return try raising(d.bwrite.?, .{ ch, b, off });
}

pub fn remove(d: *Dev, ch: *Chan) Error!void {
    if (nativeOps(d)) |o| return o.remove(ch);
    try raising(d.remove.?, .{ch});
}

pub fn wstat(d: *Dev, ch: *Chan, db: [*]u8, n: c_int) Error!c_int {
    if (nativeOps(d)) |o| return o.wstat(ch, db, n);
    return try raising(d.wstat.?, .{ ch, db, n });
}

// The optional operations (design/file-interface.md, src/kern/devx.h).
// A native device has them in its Ops, and a C device in a Devx in
// devxtab, called through `raising`. Each one a device lacks has a
// default here, or in sysfile.zig's path calls for those that need a
// walk or a create.

/// The C devices' optional operations, ended by nil (devtab.c, nstab.c).
extern var devxtab: [0]?*c.Devx;

/// d's optional operations, if it's a C device with any.
fn devx(d: *Dev) ?*c.Devx {
    const t: [*]?*c.Devx = @ptrCast(&devxtab);
    var i: usize = 0;
    while (t[i]) |x| : (i += 1) {
        if (x.dc == d.dc) return x;
    }
    return null;
}


/// Linux's EXDEV, as src/dotl/attr.zig names it.
pub const Exdev = "cross-device link";

/// Whether a and b are on one instance of one device, which a link and a
/// rename need (design/file-interface.md, Security).
pub fn sameinst(a: *const Chan, b: *const Chan) bool {
    return a.type == b.type and a.dev == b.dev;
}

/// The target of the link ch is, as written, into buf: its length, or
/// null if ch isn't a link. By default nothing is.
pub fn readlink(ch: *Chan, buf: []u8) Error!?usize {
    if (buf.len == 0) return null;
    const d = of(ch);
    if (nativeOps(d)) |o| {
        const f = o.readlink orelse return null;
        return f(ch, buf);
    }
    const x = devx(d) orelse return null;
    if (x.readlink == null) return null;
    const r = try raising(x.readlink.?, .{ ch, buf.ptr, @as(c_int, @intCast(@min(buf.len, std.math.maxInt(c_int)))) });
    return if (r < 0) null else @intCast(r);
}

/// Makes name in the directory ch a symbolic link to target. By default
/// "permission denied".
pub fn symlink(ch: *Chan, name: [*:0]const u8, target: [*:0]const u8) Error!void {
    const d = of(ch);
    if (nativeOps(d)) |o| {
        const f = o.symlink orelse return port.kerror(&port.Eperm);
        return f(ch, name, target);
    }
    const x = devx(d) orelse return port.kerror(&port.Eperm);
    if (x.symlink == null) return port.kerror(&port.Eperm);
    try raising(x.symlink.?, .{ ch, @constCast(name), @constCast(target) });
}

/// Makes name in the directory dir another name for ch's file: true, or
/// false if the device has no links, or the two are on different
/// instances, for the caller's default (a copy).
pub fn link(ch: *Chan, dir: *Chan, name: [*:0]const u8) Error!bool {
    if (!sameinst(ch, dir)) return false;
    const d = of(ch);
    if (nativeOps(d)) |o| {
        const f = o.link orelse return false;
        return f(ch, dir, name);
    }
    const x = devx(d) orelse return false;
    if (x.link == null) return false;
    const r = try raising(x.link.?, .{ ch, dir, @constCast(name) });
    return r == 0;
}

/// Whether ch's device has its own getattr, so its stat doesn't say it
/// all.
pub fn hasgetattr(ch: *Chan) bool {
    const d = of(ch);
    if (nativeOps(d)) |o| {
        if (o.getattr == null) return false;
        const f = o.hasattr orelse return true;
        return f(ch);
    }
    const x = devx(d) orelse return false;
    return x.getattr != null;
}

/// ch's Dir from a, which ch's getattr gave, if the device makes one
/// (attrstat), or null for a stat.
pub fn attrstat(ch: *Chan, a: *const Attr, dir: [*]u8, n: c_int) ?c_int {
    const o = nativeOps(of(ch)) orelse return null;
    const f = o.attrstat orelse return null;
    return f(ch, a, dir, n);
}

/// ch's attributes, what mask asks for and whatever else the device
/// has; a.valid says which. By default they're built from stat.
pub fn getattr(ch: *Chan, mask: u64, a: *Attr) Error!void {
    a.* = std.mem.zeroes(Attr);
    const d = of(ch);
    if (nativeOps(d)) |o| if (o.getattr) |f| return f(ch, mask, a);
    if (devx(d)) |x| if (x.getattr != null) return raising(x.getattr.?, .{ ch, mask, a });
    return getattrdefault(ch, a);
}

/// The default getattr: from stat.
pub fn getattrdefault(ch: *Chan, a: *Attr) Error!void {
    const d = of(ch);
    var buf: [c.Attrstatlen]u8 = undefined;
    const n = try stat(d, ch, &buf, buf.len);
    var dir: Dir = undefined;
    var strs: [buf.len]u8 = undefined;
    if (c.convM2D(&buf, @intCast(n), &dir, &strs) == 0)
        return port.kerror(&port.Ebadstat);
    attrfromdir(&dir, a);
}

/// The attributes a Dir gives: the mode, size, and times in seconds; no
/// link count, ids, or change time.
pub fn attrfromdir(dir: *const Dir, a: *Attr) void {
    a.* = std.mem.zeroes(Attr);
    a.valid = c.Amode | c.Aatime | c.Amtime | c.Aino | c.Asize;
    a.qid = dir.qid;
    a.mode = dir.mode;
    a.size = @bitCast(dir.length);
    a.atime = dir.atime;
    a.mtime = dir.mtime;
}

/// Sets what mask names from a. By default a wstat, which has no ids,
/// and times in seconds.
pub fn setattr(ch: *Chan, mask: u64, a: *const Attr) Error!void {
    const d = of(ch);
    if (nativeOps(d)) |o| if (o.setattr) |f| return f(ch, mask, a);
    if (devx(d)) |x| if (x.setattr != null) return raising(x.setattr.?, .{ ch, mask, @constCast(a) });
    return setattrdefault(ch, mask, a);
}

/// The default setattr: a wstat.
pub fn setattrdefault(ch: *Chan, mask: u64, a: *const Attr) Error!void {
    const d = of(ch);
    if (mask & (c.Auid | c.Agid) != 0)
        return port.kerror(&port.Eperm);
    var dir: Dir = undefined;
    nulldir(&dir);
    if (mask & c.Amode != 0) dir.mode = a.mode;
    if (mask & c.Asize != 0) dir.length = @bitCast(a.size);
    const now: c_uint = @truncate(@as(c_ulong, @bitCast(@as(c_long, c.seconds()))));
    if (mask & c.Aatime != 0) dir.atime = if (a.atimens == c.Anow) now else @truncate(@as(u64, @bitCast(a.atime)));
    if (mask & c.Amtime != 0) dir.mtime = if (a.mtimens == c.Anow) now else @truncate(@as(u64, @bitCast(a.mtime)));
    var buf: [c.STATFIXLEN + 16]u8 = undefined;
    const n = c.convD2M(&dir, &buf, buf.len);
    _ = try wstat(d, ch, &buf, @intCast(n));
}

/// A Dir a wstat changes nothing with: every field ~0, and every
/// string empty.
pub fn nulldir(dir: *Dir) void {
    @memset(std.mem.asBytes(dir), 0xff);
    const empty: [*c]u8 = @constCast("");
    dir.name = empty;
    dir.uid = empty;
    dir.gid = empty;
    dir.muid = empty;
}

/// Moves ch to name in the directory dir, replacing what's there: true,
/// or false if the device has no rename of its own or can't do this
/// one, or the two are on different instances, for the caller's default.
pub fn rename(ch: *Chan, dir: *Chan, name: [*:0]const u8) Error!bool {
    if (!sameinst(ch, dir)) return false;
    const d = of(ch);
    if (nativeOps(d)) |o| {
        const f = o.rename orelse return false;
        return f(ch, dir, name);
    }
    const x = devx(d) orelse return false;
    if (x.rename == null) return false;
    const r = try raising(x.rename.?, .{ ch, dir, @constCast(name) });
    return r == 0;
}

/// Makes what was written to ch's file durable. By default the null
/// wstat, which a host tree serves with the host's fsync.
pub fn fsync(ch: *Chan, datasync: bool) Error!void {
    if (nativeOps(of(ch))) |o| if (o.fsync) |f| return f(ch, datasync);
    return fsyncdefault(ch);
}

pub fn fsyncdefault(ch: *Chan) Error!void {
    var dir: Dir = undefined;
    nulldir(&dir);
    var buf: [c.STATFIXLEN + 16]u8 = undefined;
    const n = c.convD2M(&dir, &buf, buf.len);
    _ = try wstat(of(ch), ch, &buf, @intCast(n));
}

/// The events of ev ready on ch now, of ready.zig's, with an error or
/// a hangup always reported. By default a read and a write: a file
/// never blocks, so a read blocks as it would.
pub fn ready(ch: *Chan, ev: c_int) c_int {
    const d = of(ch);
    if (nativeOps(d)) |o| {
        const f = o.ready orelse return readydefault(ev);
        return f(ch, ev);
    }
    if (devx(d)) |x| if (x.ready) |f| return f(ch, ev);
    return readydefault(ev);
}

pub fn readydefault(ev: c_int) c_int {
    return ev & (rd.In | rd.Out);
}

/// Hangs w, with waker wk, on ch, for a call when its readiness may
/// have changed. By default nothing changes, and it's never called.
pub fn watch(ch: *Chan, ev: c_int, w: *rd.Watch, wk: *rd.Waker) void {
    w.* = .{ .waker = wk };
    const d = of(ch);
    if (nativeOps(d)) |o| {
        if (o.watch) |f| f(ch, ev, w, wk);
        return;
    }
    if (devx(d)) |x| if (x.watch) |f| f(ch, ev, w, wk);
}

/// (*gen)(c, name, tab, ntab, i, dp): devgen, or a native device's own,
/// directly, or a C device's own Devgen through `raising`.
pub fn callgen(gen: *const Devgen, ch: *Chan, name: ?[*:0]const u8, tab: ?[*]Dirtab, ntab: c_int, i: c_int, dp: *Dir) Error!c_int {
    if (gen == &c_devgen)
        return devgen(ch, name, tab, ntab, i, dp);
    inline for (natives) |N| {
        for (N.ops.gens) |g| if (gen == g)
            return gen(ch, @constCast(name), tab, ntab, i, dp);
        for (N.ops.egens) |g| if (gen == g.c)
            return g.z(ch, name, tab, ntab, i, dp);
    }
    return try raising(gen, .{ ch, @constCast(name), tab, ntab, i, dp });
}

/// devgen as a C Devgen, for a native device's devwalk, devstat, and the
/// rest.
pub fn devgenC() *const Devgen {
    return &c_devgen;
}

// The C kernel's names, with its semantics: a function that fails raises
// its error.

fn c_mkqid(q: *Qid, path: i64, vers: c_uint, @"type": c_int) callconv(.c) void {
    mkqid(q, path, vers, @"type");
}
fn c_devno(ch: c_int) callconv(.c) c_int {
    return devno(ch);
}
fn c_devdir(ch: *Chan, qid: Qid, n: [*c]u8, length: i64, user: [*c]u8, perm: c_int, db: *Dir) callconv(.c) void {
    devdir(ch, qid, n, length, user, perm, db);
}
fn c_devgen(ch: [*c]Chan, name: [*c]u8, tab: [*c]Dirtab, ntab: c_int, i: c_int, dp: [*c]Dir) callconv(.c) c_int {
    return devgen(ch, name, tab, ntab, i, dp);
}
fn c_devreset() callconv(.c) void {
    devreset();
}
fn c_devinit() callconv(.c) void {
    devinit();
}
fn c_devshutdown() callconv(.c) void {
    devshutdown();
}
fn c_devattach(tc: c_int, spec: ?[*:0]const u8) callconv(.c) *Chan {
    return devattach(tc, spec);
}
fn c_devclone(ch: *Chan) callconv(.c) *Chan {
    return devclone(ch);
}
fn c_devwalk(ch: *Chan, nc: ?*Chan, name: [*]const [*:0]const u8, nname: c_int, tab: ?[*]Dirtab, ntab: c_int, gen: *const Devgen) callconv(.c) ?*Walkqid {
    return devwalk(ch, nc, name, nname, tab, ntab, gen) catch |e| port.raise(e);
}
fn c_devstat(ch: *Chan, db: [*]u8, n: c_int, tab: ?[*]Dirtab, ntab: c_int, gen: *const Devgen) callconv(.c) c_int {
    return devstat(ch, db, n, tab, ntab, gen) catch |e| port.raise(e);
}
fn c_devdirread(ch: *Chan, d: [*]u8, n: c_int, tab: ?[*]Dirtab, ntab: c_int, gen: *const Devgen) callconv(.c) c_int {
    return devdirread(ch, d, n, tab, ntab, gen) catch |e| port.raise(e);
}
fn c_devpermcheck(fileuid: [*:0]const u8, perm: c_uint, omode: c_int) callconv(.c) void {
    devpermcheck(fileuid, perm, omode) catch |e| port.raise(e);
}
fn c_devopen(ch: *Chan, omode: c_int, tab: ?[*]Dirtab, ntab: c_int, gen: *const Devgen) callconv(.c) *Chan {
    return devopen(ch, omode, tab, ntab, gen) catch |e| port.raise(e);
}
fn c_devcreate(ch: *Chan, name: [*c]u8, mode: c_int, perm: c_uint) callconv(.c) *Chan {
    return devcreate(ch, @ptrCast(name), mode, perm) catch |e| port.raise(e);
}
fn c_devbread(ch: *Chan, n: c_int, offset: c_uint) callconv(.c) *Block {
    return devbread(ch, n, offset) catch |e| port.raise(e);
}
fn c_devbwrite(ch: *Chan, bp: *Block, offset: c_uint) callconv(.c) c_int {
    return devbwrite(ch, bp, offset) catch |e| port.raise(e);
}
fn c_devremove(ch: *Chan) callconv(.c) void {
    devremove(ch) catch |e| port.raise(e);
}
fn c_devwstat(ch: *Chan, a: [*c]u8, n: c_int) callconv(.c) c_int {
    return devwstat(ch, @ptrCast(a), n) catch |e| port.raise(e);
}
fn c_devpower(a: c_int) callconv(.c) void {
    devpower(a) catch |e| port.raise(e);
}
fn c_devconfig(a: c_int, b: [*c]u8, cf: ?*c.DevConf) callconv(.c) c_int {
    return devconfig(a, b, cf) catch |e| port.raise(e);
}

pub fn exportC() void {
    @export(&c_mkqid, .{ .name = "mkqid" });
    @export(&c_devno, .{ .name = "devno" });
    @export(&c_devdir, .{ .name = "devdir" });
    @export(&c_devgen, .{ .name = "devgen" });
    @export(&c_devreset, .{ .name = "devreset" });
    @export(&c_devinit, .{ .name = "devinit" });
    @export(&c_devshutdown, .{ .name = "devshutdown" });
    @export(&c_devattach, .{ .name = "devattach" });
    @export(&c_devclone, .{ .name = "devclone" });
    @export(&c_devwalk, .{ .name = "devwalk" });
    @export(&c_devstat, .{ .name = "devstat" });
    @export(&c_devdirread, .{ .name = "devdirread" });
    @export(&c_devpermcheck, .{ .name = "devpermcheck" });
    @export(&c_devopen, .{ .name = "devopen" });
    @export(&c_devcreate, .{ .name = "devcreate" });
    @export(&c_devbread, .{ .name = "devbread" });
    @export(&c_devbwrite, .{ .name = "devbwrite" });
    @export(&c_devremove, .{ .name = "devremove" });
    @export(&c_devwstat, .{ .name = "devwstat" });
    @export(&c_devpower, .{ .name = "devpower" });
    @export(&c_devconfig, .{ .name = "devconfig" });
}

const testing = std.testing;
const kt = port.testing;

/// A device table for the cases: ".", a file, and a directory.
fn testTab() [3]Dirtab {
    var tab: [3]Dirtab = std.mem.zeroes([3]Dirtab);
    const entries = [_]struct { []const u8, u64, u8, c_int }{
        .{ ".", 0, c.QTDIR, dmdir | 0o555 },
        .{ "file", 1, 0, 0o640 },
        .{ "sub", 2, c.QTDIR, dmdir | 0o555 },
    };
    for (&tab, entries) |*t, e| {
        @memcpy(t.name[0..e[0].len], e[0]);
        t.qid = .{ .path = e[1], .vers = 0, .type = e[2] };
        t.perm = e[3];
    }
    return tab;
}

/// A chan at the root of the root device, for the table's walks: any
/// device that keeps nothing in a chan does, for devdir's type.
fn testChan() *Chan {
    return devattach('/', "");
}

fn expectErrstr(s: *const [0:0]u8) !void {
    try testing.expectEqualStrings(std.mem.sliceTo(@as([*:0]const u8, s), 0), kt.errstr());
}

test "devwalk walks a Dirtab, and stops short at a name that isn't there [kernel-port]" {
    _ = try kt.begin();
    var tab = testTab();
    const ch = testChan();
    defer chan.cclose(ch);

    const one = [_][*:0]const u8{"file"};
    const wq = (try devwalk(ch, null, &one, 1, &tab, tab.len, &c_devgen)).?;
    try testing.expectEqual(1, wq.nqid);
    try testing.expectEqual(1, qids(wq)[0].path);
    try testing.expectEqual(ch.type, wq.libclone.*.type);
    chan.cclose(wq.libclone);
    c.free(wq);

    // Past a file: the qids so far, and no clone.
    const past = [_][*:0]const u8{ "file", "x" };
    const wq2 = (try devwalk(ch, null, &past, 2, &tab, tab.len, &c_devgen)).?;
    try testing.expectEqual(1, wq2.nqid);
    try testing.expect(wq2.libclone == null);
    c.free(wq2);

    // A name that isn't there, first: nil, and the error.
    const none = [_][*:0]const u8{"nothere"};
    try testing.expect(try devwalk(ch, null, &none, 1, &tab, tab.len, &c_devgen) == null);
    try expectErrstr(&port.Enonexist);

    // One after a good one: the good one's qid, and the error string.
    const later = [_][*:0]const u8{ ".", "nothere" };
    const wq3 = (try devwalk(ch, null, &later, 2, &tab, tab.len, &c_devgen)).?;
    try testing.expectEqual(1, wq3.nqid);
    try testing.expect(wq3.libclone == null);
    try expectErrstr(&port.Enonexist);
    c.free(wq3);

    // A walk from a file is an error, not nil.
    const file = devclone(ch);
    defer chan.cclose(file);
    file.qid = tab[1].qid;
    try testing.expectError(error.Kernel, devwalk(file, null, &none, 1, &tab, tab.len, &c_devgen));
    try expectErrstr(&port.Enotdir);
}

test "devstat, devdirread, and devopen find a chan's entry in its Dirtab [kernel-port]" {
    _ = try kt.begin();
    var tab = testTab();
    const ch = testChan();
    defer chan.cclose(ch);

    // The root isn't in its own list (devgen skips "."), so devstat
    // makes its entry up.
    var buf: [256]u8 = undefined;
    var d: Dir = undefined;
    var strs: [256]u8 = undefined;
    var n = try devstat(ch, &buf, buf.len, &tab, tab.len, &c_devgen);
    try testing.expect(c.convM2D(&buf, @intCast(n), &d, &strs) != 0);
    try testing.expectEqual(c.DMDIR | 0o555, d.mode);
    // (Its name is the path's last element: "#/" has an empty one.)
    try testing.expectEqualStrings("", std.mem.sliceTo(d.name, 0));

    const file = devclone(ch);
    defer chan.cclose(file);
    file.qid = tab[1].qid;
    n = try devstat(file, &buf, buf.len, &tab, tab.len, &c_devgen);
    try testing.expect(c.convM2D(&buf, @intCast(n), &d, &strs) != 0);
    try testing.expectEqualStrings("file", std.mem.sliceTo(d.name, 0));
    try testing.expectEqual(0o640, d.mode);

    // A file not in the table.
    const gone = devclone(ch);
    defer chan.cclose(gone);
    gone.qid = .{ .path = 9, .vers = 0, .type = 0 };
    try testing.expectError(error.Kernel, devstat(gone, &buf, buf.len, &tab, tab.len, &c_devgen));
    try expectErrstr(&port.Enonexist);

    // The directory's entries, and a buffer too small for one.
    var dirbuf: [512]u8 = undefined;
    ch.dri = 0;
    const m: usize = @intCast(try devdirread(ch, &dirbuf, dirbuf.len, &tab, tab.len, &c_devgen));
    var off: usize = 0;
    for ([_][]const u8{ "file", "sub" }) |want| {
        const sz = c.convM2D(dirbuf[off..].ptr, @intCast(m - off), &d, &strs);
        try testing.expect(sz != 0);
        try testing.expectEqualStrings(want, std.mem.sliceTo(d.name, 0));
        off += sz;
    }
    try testing.expectEqual(m, off);
    ch.dri = 0;
    try testing.expectError(error.Kernel, devdirread(ch, &dirbuf, 8, &tab, tab.len, &c_devgen));
    try expectErrstr(&port.Eshort);

    // devopen checks the entry's mode for the process's user, who owns
    // the file (devgen makes eve its owner, and the case runs as eve):
    // 0640 lets it read and write, not execute.
    try testing.expectError(error.Kernel, devopen(file, c.OEXEC, &tab, tab.len, &c_devgen));
    try expectErrstr(&port.Eperm);
    file.qid = tab[2].qid;
    try testing.expectError(error.Kernel, devopen(file, c.OWRITE, &tab, tab.len, &c_devgen));
    file.qid = tab[1].qid;
    _ = try devopen(file, c.ORDWR, &tab, tab.len, &c_devgen);
    try testing.expect(file.flag & c.COPEN != 0);
    try testing.expectEqual(c.ORDWR, file.mode);
}

/// A C Devgen that raises.
fn badgen(ch: [*c]Chan, name: [*c]u8, tab: [*c]Dirtab, ntab: c_int, i: c_int, dp: [*c]Dir) callconv(.c) c_int {
    _ = .{ ch, name, tab, ntab, i, dp };
    c.@"error"(@constCast(if (badintr) &port.Eintr else "bad devgen"));
    return 0;
}
var badintr = false;

test "the switch hands a C function's error() back as an error union [kernel-port]" {
    _ = try kt.begin();
    var tab = testTab();
    const ch = testChan();
    defer chan.cclose(ch);
    const depth = up().nerrlab;

    var buf: [256]u8 = undefined;
    try testing.expectError(error.Kernel, devstat(ch, &buf, buf.len, &tab, tab.len, &badgen));
    try testing.expectEqualStrings("bad devgen", kt.errstr());
    badintr = true;
    defer badintr = false;
    try testing.expectError(error.Interrupted, devstat(ch, &buf, buf.len, &tab, tab.len, &badgen));
    // A walk catches it, as devwalk's error label did.
    const names = [_][*:0]const u8{"file"};
    try testing.expect(try devwalk(ch, null, &names, 1, &tab, tab.len, &badgen) == null);
    // And the error stack is as it was.
    try testing.expectEqual(depth, up().nerrlab);
}

test "the switch reads and writes a C device, a pipe [kernel-port]" {
    _ = try kt.begin();
    const pipe = table()[@intCast(devno('|'))].?;
    const root = try attach(pipe, "");
    defer chan.cclose(root);
    var ends: [2]*Chan = undefined;
    for (&ends, [_][*:0]const u8{ "data", "data1" }) |*e, name| {
        const wq = (try walkdev(pipe, root, null, &[_][*:0]const u8{name}, 1)).?;
        defer c.free(wq);
        e.* = try open(pipe, wq.libclone, c.ORDWR);
    }
    defer for (ends) |e| chan.cclose(e);

    try testing.expectEqual(5, try write(pipe, ends[0], "hello", 5, 0));
    var buf: [16]u8 = undefined;
    const n = try read(pipe, ends[1], &buf, buf.len, 0);
    try testing.expectEqualStrings("hello", buf[0..@intCast(n)]);

    // Blocks.
    const b = qio.allocb(3);
    @memcpy(b.wp[0..3], "abc");
    b.wp += 3;
    try testing.expectEqual(3, try bwrite(pipe, ends[1], b, 0));
    const got = (try bread(pipe, ends[0], 16, 0)).?;
    defer qio.freeb(got);
    try testing.expectEqualStrings("abc", got.rp[0..3]);

    // A device's error: a stat buffer too small for any entry.
    var small: [1]u8 = undefined;
    try testing.expectError(error.Kernel, stat(pipe, ends[0], &small, small.len));
    try expectErrstr(&port.Eshortstat);
}
