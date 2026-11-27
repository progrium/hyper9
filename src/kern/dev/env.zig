//! h9's #e, environment variables, one environment per Egrp
//! (src/kern/devenv.c, design/kernel-port.md). Ported from 9front's
//! port/devenv.c at the pinned release (NINEFRONT_REV), replacing
//! drawterm's, which has one machine-wide environment and imports the
//! host process's environment on first attach (SPEC.md, env.scrub). A
//! close translation of the C: the same functions in the same order,
//! with error unions in place of C's error labels. A native device (dev.zig's
//! `Native`).
//!
//! drawterm's Proc has no egrp, and stays as it is, so a Proc's group is
//! kept on its h9 process record (src/kern/proc.c). drawterm's own Egrp
//! and Evalue types don't match 9front's, so this file uses its own
//! (HEgrp, HEvalue). #ec (the kernel configuration group) isn't
//! supported.
//!
//! The namespace kernel has no environments (nstab.c stubs the groups),
//! so it builds none of this but the cases.

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

const Maxenvsize = 1 * 1024 * 1024;
const Maxvalsize = Maxenvsize / 2;
const DELTAENV = 32;
const ENVHASH = 64;

/// A variable. Its name follows it, as the C's flexible name[].
const HEvalue = struct {
    value: ?[*]u8,
    len: c_int,
    vers: c_uint,
    path: u64, // qid.path: HEgrp.path << 32 | index (of HEgrp.ent[])
    size: c_int, // bytes allocated for value
    hash: ?*HEvalue,

    fn name(e: *HEvalue) [*:0]u8 {
        return @ptrCast(@as([*]u8, @ptrCast(e)) + @sizeOf(HEvalue));
    }
};

const HEgrp = struct {
    ref: c.Ref,
    lk: c.RWLock,
    ent: ?[*]?*HEvalue,
    nent: c_int, // number of slots in ent[]
    low: c_int, // lowest free index in ent[]
    alloc: c_int, // bytes allocated for env
    path: c_uint, // generator for qid path
    vers: c_uint, // of HEgrp
    hash: [ENVHASH]?*HEvalue, // hashtable for name lookup
};

fn PATH(p: c_uint, i: c_int) u64 {
    return @as(u64, p) << 32 | @as(u64, @as(c_uint, @bitCast(i)));
}
fn QID(qidpath: u64) c_int {
    return @intCast(@as(c_uint, @truncate(qidpath)) & 0x7FFFFFFF);
}
fn ROUND(s: c_int, sz: c_int) c_int {
    return (s + (sz - 1)) & ~(sz - 1);
}

fn upegrp() Error!*HEgrp {
    return @ptrCast(@alignCast(try @import("../proc.zig").upegrp()));
}

fn hcloseegrp(eg_: ?*HEgrp) void {
    const eg = eg_ orelse return;
    if (chan.decref(&eg.ref) != 0)
        return;
    var i: usize = 0;
    while (i < eg.nent) : (i += 1) {
        const e = eg.ent.?[i] orelse continue;
        c.free(e.value);
        c.free(e);
    }
    c.free(@ptrCast(eg.ent));
    c.free(eg);
}

// Groups for proc.c, which keeps each process's on its record. They're
// void* there, since HEgrp is private to this file.

/// A new, empty environment.
pub fn egrpnew() Error!*HEgrp {
    const eg: *HEgrp = @ptrCast(@alignCast(c.mallocz(@sizeOf(HEgrp), 1) orelse
        return port.kerror(&port.Enomem)));
    eg.ref.ref = 1;
    return eg;
}

/// A copy of an environment, for RFENVG: 9front's envcpy.
pub fn egrpcopy(from: *HEgrp) Error!*HEgrp {
    const to = try egrpnew();
    errdefer hcloseegrp(to);
    sync.rlock(&from.lk);
    defer sync.runlock(&from.lk);
    to.ent = @ptrCast(@alignCast(try envrealloc(to, null, 0, ROUND(from.nent, DELTAENV) * @sizeOf(?*HEvalue))));
    var i: usize = 0;
    while (i < from.nent) : (i += 1) {
        const e = from.ent.?[i] orelse continue;
        const h = envhash(to, e.name());
        const n: c_int = @intCast(std.mem.len(e.name()) + 1);
        const ne: *HEvalue = @ptrCast(@alignCast(try envrealloc(to, null, 0, @sizeOf(HEvalue) + n)));
        @memcpy(ne.name()[0..@intCast(n)], e.name()[0..@intCast(n)]);
        ne.value = null;
        ne.len = 0;
        ne.size = 0;
        ne.vers = 0;
        to.path += 1;
        ne.path = PATH(to.path, to.nent);
        ne.hash = h.*;
        h.* = ne;
        to.ent.?[@intCast(to.nent)] = ne;
        to.nent += 1;
        if (e.len > 0) {
            ne.value = @ptrCast(try envrealloc(to, null, 0, e.len));
            @memcpy(ne.value.?[0..@intCast(e.len)], e.value.?[0..@intCast(e.len)]);
            ne.len = e.len;
            ne.size = e.len;
        }
    }
    to.low = to.nent;
    return to;
}

fn envindex(eg: *HEgrp, qidpath: u64) ?*HEvalue {
    const i = QID(qidpath);
    if (i >= eg.nent)
        return null;
    const e = eg.ent.?[@intCast(i)];
    if (e != null and e.?.path != qidpath)
        return null;
    return e;
}

fn envhash(eg: *HEgrp, name_: [*:0]const u8) *?*HEvalue {
    var h: c_uint = 0;
    var name = name_;
    while (name[0] != 0) : (name += 1)
        h = h *% 131 +% name[0];
    return &eg.hash[h % ENVHASH];
}

fn lookupname(e_: ?*HEvalue, name: [*:0]const u8) ?*HEvalue {
    var e = e_;
    while (e) |v| : (e = v.hash) {
        if (dev.streq(v.name(), name))
            break;
    }
    return e;
}

fn envgrp(ch: *Chan) Error!*HEgrp {
    const a = dev.aux(ch).* orelse return upegrp();
    return @ptrCast(@alignCast(a));
}

/// A Devgen doesn't raise, so the functions that call devwalk, devstat,
/// and devdirread find the group first, which makes it the error there:
/// a chan's group is still the process's when envgen calls envgrp.
fn envgen(ch_: [*c]Chan, name_: [*c]u8, _: [*c]Dirtab, _: c_int, s: c_int, dp: [*c]Dir) callconv(.c) c_int {
    const ch: *Chan = ch_;
    const eg = envgrp(ch) catch return -1;
    if (s == c.DEVDOTDOT) {
        ch.qid.vers = eg.vers;
        dev.devdir(ch, ch.qid, @constCast("#e"), 0, c.eve, 0o775, dp);
        return 1;
    }
    sync.rlock(&eg.lk);
    defer sync.runlock(&eg.lk);
    const e: *HEvalue = blk: {
        if ((ch.qid.type & c.QTDIR) == 0) {
            break :blk envindex(eg, ch.qid.path) orelse return -1;
        } else if (name_ != null) {
            const name: [*:0]const u8 = name_;
            if (std.mem.len(name) >= up().genbuf.len)
                return -1;
            break :blk lookupname(envhash(eg, name).*, name) orelse return -1;
        } else if (s < eg.nent) {
            break :blk eg.ent.?[@intCast(s)] orelse return 0; // deleted, try next
        } else return -1;
    };
    // make sure name string continues to exist after we release lock
    chan.kstrcpy(&up().genbuf, e.name(), up().genbuf.len);
    var q: Qid = undefined;
    dev.mkqid(&q, @bitCast(e.path), e.vers, c.QTFILE);
    dev.devdir(ch, q, &up().genbuf, e.len, c.eve, 0o666, dp);
    return 1;
}

fn envattach(spec: [*:0]const u8) Error!*Chan {
    if (spec[0] != 0)
        return port.kerror(&port.Ebadarg);
    const ch = dev.devattach('e', spec);
    dev.aux(ch).* = null;
    return ch;
}

fn envwalk(ch: *Chan, nc: ?*Chan, name: [*]const [*:0]const u8, nname: c_int) Error!?*Walkqid {
    _ = try envgrp(ch);
    return dev.devwalk(ch, nc, name, nname, null, 0, &envgen);
}

fn envstat(ch: *Chan, db: [*]u8, n: c_int) Error!c_int {
    _ = try envgrp(ch);
    return dev.devstat(ch, db, n, null, 0, &envgen);
}

/// Resizes an allocation charged to eg. 9front measures blocks with
/// msize; the host malloc can't, so callers pass the old size.
fn envrealloc(eg: *HEgrp, old: ?*anyopaque, oldsize: c_int, newsize: c_int) Error!?*anyopaque {
    if (newsize == 0) {
        eg.alloc -= oldsize;
        c.free(old);
        return null;
    }
    if (newsize < 0 or (eg.alloc + newsize) - oldsize > Maxenvsize)
        return port.kerror(&port.Enomem);
    const new = c.realloc(old, @intCast(newsize)) orelse
        return port.kerror(&port.Enomem);
    eg.alloc += newsize - oldsize;
    return new;
}

fn envopen(ch: *Chan, omode: c_int) Error!*Chan {
    const eg = try envgrp(ch);
    if (ch.qid.type & c.QTDIR != 0) {
        if (omode != c.OREAD)
            return port.kerror(&port.Eperm);
    } else {
        const trunc = (omode & c.OTRUNC) != 0;
        if (trunc)
            sync.wlock(&eg.lk)
        else
            sync.rlock(&eg.lk);
        defer if (trunc) sync.wunlock(&eg.lk) else sync.runlock(&eg.lk);
        const e = envindex(eg, ch.qid.path) orelse
            return port.kerror(&port.Enonexist);
        if (trunc and e.len > 0) {
            e.value = @ptrCast(envrealloc(eg, e.value, e.size, 0) catch unreachable); // free
            e.size = 0;
            e.len = 0;
            e.vers += 1;
        }
        ch.qid.vers = e.vers;
    }
    ch.mode = @intCast(try sysfile.openmode(@bitCast(omode)));
    _ = chan.incref(&eg.ref);
    dev.aux(ch).* = eg;
    ch.offset = 0;
    ch.flag |= c.COPEN;
    return ch;
}

fn envcreate(ch: *Chan, name: [*:0]const u8, omode_: c_int, perm: c_uint) Error!*Chan {
    _ = perm;
    if (ch.qid.type != c.QTDIR)
        return port.kerror(&port.Eperm);

    const n: c_int = @intCast(std.mem.len(name) + 1);
    if (n > up().genbuf.len)
        return port.kerror(&port.Etoolong);

    const omode = try sysfile.openmode(@bitCast(omode_));
    const eg = try envgrp(ch);
    {
        sync.wlock(&eg.lk);
        defer sync.wunlock(&eg.lk);

        const h = envhash(eg, name);
        if (lookupname(h.*, name) != null)
            return port.kerror(&port.Eexist);

        var i = eg.low;
        while (i < eg.nent) : (i += 1) {
            if (eg.ent.?[@intCast(i)] == null)
                break;
        }

        if (i >= eg.nent) {
            if (@rem(eg.nent, DELTAENV) == 0)
                eg.ent = @ptrCast(@alignCast(try envrealloc(eg, @ptrCast(eg.ent), eg.nent * @sizeOf(?*HEvalue), (eg.nent + DELTAENV) * @sizeOf(?*HEvalue))));
            i = eg.nent;
            eg.nent += 1;
            eg.ent.?[@intCast(i)] = null;
            eg.low = i;
        }

        const e: *HEvalue = @ptrCast(@alignCast(try envrealloc(eg, null, 0, @sizeOf(HEvalue) + n)));
        @memcpy(e.name()[0..@intCast(n)], name[0..@intCast(n)]);
        e.value = null;
        e.len = 0;
        e.size = 0;
        e.vers = 0;
        eg.path += 1;
        e.path = PATH(eg.path, i);
        e.hash = h.*;
        h.* = e;
        eg.ent.?[@intCast(i)] = e;
        eg.low = i + 1;
        eg.vers += 1;
        dev.mkqid(&ch.qid, @bitCast(e.path), e.vers, c.QTFILE);
    }
    _ = chan.incref(&eg.ref);
    dev.aux(ch).* = eg;
    ch.offset = 0;
    ch.mode = @intCast(omode);
    ch.flag |= c.COPEN;
    return ch;
}

fn envremove(ch: *Chan) Error!void {
    if (ch.qid.type & c.QTDIR != 0)
        return port.kerror(&port.Eperm);

    const eg = try envgrp(ch);
    sync.wlock(&eg.lk);
    defer sync.wunlock(&eg.lk);
    const e = envindex(eg, ch.qid.path) orelse
        return port.kerror(&port.Enonexist);
    var h = envhash(eg, e.name());
    while (h.*) |v| : (h = &v.hash) {
        if (v == e) {
            h.* = e.hash;
            break;
        }
    }
    const i = QID(ch.qid.path);
    eg.ent.?[@intCast(i)] = null;
    if (i < eg.low)
        eg.low = i;
    eg.vers += 1;

    // free
    _ = envrealloc(eg, e.value, e.size, 0) catch unreachable;
    _ = envrealloc(eg, e, @intCast(@sizeOf(HEvalue) + std.mem.len(e.name()) + 1), 0) catch unreachable;
}

fn envclose(ch: *Chan) Error!void {
    if (ch.flag & c.COPEN != 0) {
        // cclose can't fail, so errors from remove will be ignored.
        // since permissions aren't checked,
        // envremove can't not remove it if its there.
        if (ch.flag & c.CRCLOSE != 0)
            envremove(ch) catch {};
        hcloseegrp(@ptrCast(@alignCast(dev.aux(ch).*)));
        dev.aux(ch).* = null;
    }
}

fn envread(ch: *Chan, a: ?*anyopaque, n_: c_int, off: i64) Error!c_int {
    const eg = try envgrp(ch);
    if (ch.qid.type & c.QTDIR != 0)
        return dev.devdirread(ch, @ptrCast(a.?), n_, null, 0, &envgen);

    sync.rlock(&eg.lk);
    defer sync.runlock(&eg.lk);
    const e = envindex(eg, ch.qid.path) orelse
        return port.kerror(&port.Enonexist);
    var n: i64 = n_;
    if (off >= e.len)
        n = 0
    else if (off + n > e.len)
        n = e.len - off;
    if (n <= 0)
        n = 0
    else
        @memcpy(@as([*]u8, @ptrCast(a.?))[0..@intCast(n)], e.value.?[@intCast(off)..][0..@intCast(n)]);
    return @intCast(n);
}

fn envwrite(ch: *Chan, a: ?*const anyopaque, n: c_int, off: i64) Error!c_int {
    const eg = try envgrp(ch);
    sync.wlock(&eg.lk);
    defer sync.wunlock(&eg.lk);
    const e = envindex(eg, ch.qid.path) orelse
        return port.kerror(&port.Enonexist);
    if (off > Maxvalsize or n > (Maxvalsize - off))
        return port.kerror(&port.Etoobig);
    var diff: c_int = @intCast((off + n) - e.len);
    if (diff > 0) {
        e.value = @ptrCast(try envrealloc(eg, e.value, e.size, e.len + diff));
        e.size = e.len + diff;
    } else diff = 0;
    if (n > 0)
        @memcpy(e.value.?[@intCast(off)..][0..@intCast(n)], @as([*]const u8, @ptrCast(a.?))[0..@intCast(n)]);
    if (off > e.len)
        @memset(e.value.?[@intCast(e.len)..@intCast(off)], 0);
    e.len += diff;
    e.vers += 1;
    eg.vers += 1;
    return n;
}

pub const Device = dev.Native('e', "env", .{
    .attach = envattach,
    .walk = envwalk,
    .stat = envstat,
    .open = envopen,
    .create = envcreate,
    .close = envclose,
    .read = envread,
    .write = envwrite,
    .remove = envremove,
    .wstat = dev.devwstat,
    .gens = &.{&envgen},
});

/// A reference to a process's group, for proc.zig.
pub fn egrpincref(eg: *HEgrp) void {
    _ = chan.incref(&eg.ref);
}

/// Drops a reference to a process's group, for proc.zig.
pub fn egrpclose(eg: *HEgrp) void {
    hcloseegrp(eg);
}

pub fn exportC() void {
    @export(&Device.dev, .{ .name = "envdevtab" });
}

// Cases (zig build kern-test), on a group of their own: a chan whose aux
// is a group uses it, so they need no process record.

const testing = std.testing;
const kt = port.testing;

/// #e's root on eg, as an attach and an open leave it. The namespace
/// kernel's table has no #e, so its type is the root device's, whose
/// close does nothing.
fn testDir(eg: *HEgrp) *Chan {
    const ch = chan.newchan();
    ch.qid = .{ .path = 0, .vers = 0, .type = c.QTDIR };
    _ = chan.incref(&eg.ref);
    dev.aux(ch).* = eg;
    return ch;
}

fn closeTest(ch: *Chan) void {
    envclose(ch) catch unreachable;
    ch.flag &= ~@as(c_ushort, c.COPEN | c.CRCLOSE);
    chan.cclose(ch);
}

fn create(eg: *HEgrp, name: [*:0]const u8, val: []const u8) !*Chan {
    const ch = try envcreate(testDir(eg), name, c.ORDWR, 0o666);
    // envcreate took its own reference: drop testDir's.
    _ = chan.decref(&eg.ref);
    try testing.expectEqual(@as(c_int, @intCast(val.len)), try envwrite(ch, val.ptr, @intCast(val.len), 0));
    return ch;
}

test "#e creates, writes, reads, and lists variables, and a copy is apart [kernel-port]" {
    _ = try kt.begin();
    const eg = try egrpnew();
    defer hcloseegrp(eg);
    const a = try create(eg, "user", "glenda");
    defer closeTest(a);
    var buf: [32]u8 = undefined;
    try testing.expectEqual(6, try envread(a, &buf, buf.len, 0));
    try testing.expectEqualStrings("glenda", buf[0..6]);
    try testing.expectEqual(3, try envread(a, &buf, buf.len, 3));
    try testing.expectEqual(0, try envread(a, &buf, buf.len, 10));
    // A write past the end fills the gap with zeros.
    try testing.expectEqual(1, try envwrite(a, "!", 1, 8));
    try testing.expectEqual(9, try envread(a, &buf, buf.len, 0));
    try testing.expectEqualStrings("glenda\x00\x00!", buf[0..9]);

    try testing.expectError(error.Kernel, envcreate(testDir(eg), "user", c.OWRITE, 0o666));
    try testing.expectEqualStrings("file already exists", kt.errstr());
    _ = chan.decref(&eg.ref);

    // The directory lists it, and a walk finds it.
    const dir = testDir(eg);
    defer chan.cclose(dir);
    var db: [256]u8 = undefined;
    const n = try envread(dir, &db, db.len, 0);
    var d: Dir = undefined;
    var strs: [256]u8 = undefined;
    try testing.expect(c.convM2D(&db, @intCast(n), &d, &strs) > 0);
    try testing.expectEqualStrings("user", std.mem.span(d.name));
    try testing.expectEqual(9, d.length);
    const names = [_][*:0]const u8{"user"};
    const wq = (try envwalk(dir, null, &names, 1)).?;
    defer c.free(wq);
    try testing.expectEqual(1, wq.nqid);
    try testing.expectEqual(a.qid.path, dev.qids(wq)[0].path);
    const wc: *Chan = wq.libclone;
    dev.aux(wc).* = null;
    chan.cclose(wc);

    // A copy has the value, and changes apart from it.
    const cp = try egrpcopy(eg);
    defer hcloseegrp(cp);
    try testing.expectEqual(1, cp.nent);
    const ce = cp.ent.?[0].?;
    try testing.expectEqualStrings("user", std.mem.span(ce.name()));
    try testing.expectEqualStrings("glenda\x00\x00!", ce.value.?[0..@intCast(ce.len)]);
    try testing.expectEqual(1, try envwrite(a, "G", 1, 0));
    try testing.expectEqual('g', ce.value.?[0]);
}

test "#e removes, and an ORCLOSE variable goes at its close [kernel-port]" {
    _ = try kt.begin();
    const eg = try egrpnew();
    defer hcloseegrp(eg);
    const a = try create(eg, "a", "1");
    try envremove(a);
    try testing.expectError(error.Kernel, envread(a, null, 0, 0));
    try testing.expectEqualStrings("file does not exist", kt.errstr());
    closeTest(a);
    try testing.expectEqual(0, eg.alloc - @as(c_int, DELTAENV * @sizeOf(?*HEvalue)));

    // The slot is reused.
    const b = try create(eg, "b", "22");
    try testing.expectEqual(0, QID(b.qid.path));
    b.flag |= c.CRCLOSE;
    envclose(b) catch unreachable;
    b.flag &= ~@as(c_ushort, c.COPEN | c.CRCLOSE);
    chan.cclose(b);
    try testing.expectEqual(null, eg.ent.?[0]);
    try testing.expectEqual(null, lookupname(envhash(eg, "b").*, "b"));

    // A value bigger than Maxvalsize is too big.
    const t = try create(eg, "t", "");
    defer closeTest(t);
    try testing.expectError(error.Kernel, envwrite(t, "x", 1, Maxvalsize));
    try testing.expectEqualStrings("read or write too large", kt.errstr());
}
