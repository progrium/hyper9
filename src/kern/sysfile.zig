//! drawterm's sysfile.c (design/kernel-port.md): file descriptors and
//! the file system calls. A close translation: the same functions in the
//! same order, with error unions in place of waserror, and h9's patches
//! kept: kserve's chanread and chanstat (h9_chanread and h9_chanstat),
//! Linux's F_DUPFD (h9_dupfrom), and no fd warning for a Linux process.
//!
//! There's no sys* wrapper layer: each call is one function that
//! returns an error union (`open`, `close`, `pread`, ...), and the C ABI
//! names (sysopen, sysclose, ...) are the exports at the bottom, which
//! do what the wrappers did, keeping a failed call's error string as the
//! process's syserrstr and returning -1. werrstr stays C
//! (src/kern/werrstr.c), since it's variadic.
//!
//! The one place a process waits here is rendezvous, which parks it in
//! sync.zig.

const std = @import("std");
const port = @import("port.zig");
const sync = @import("sync.zig");
const dev = @import("dev.zig");
const chan = @import("chan.zig");
const pgrp = @import("pgrp.zig");
const devmnt = @import("devmnt.zig");
const c = port.c;
const up = port.up;
const Error = port.Error;

const Chan = c.Chan;
const Fgrp = c.Fgrp;
const Mhead = c.Mhead;
const Mount = c.Mount;
const Dir = c.Dir;
const Path = c.Path;

extern fn h9_linux_inview() c_int; // h9: src/kern/linux.c

fn unlockfgrp(f: *Fgrp) void {
    const ex = f.exceed;
    f.exceed = 0;
    c.unlock(&f.ref.lk);
    // h9: not for a Linux process, whose fd 2 is its own stderr: Linux
    // prints nothing past 100 fds, and zig build fails a compile that
    // writes anything there (design/epoch-0/linux-personality.md).
    if (ex != 0 and h9_linux_inview() == 0)
        _ = c.pprint(@constCast("warning: process exceeds %d file descriptors\n"), ex);
}

/// fd is always >= 0
fn growfd(f: *Fgrp, fd: c_int) c_int {
    const nfd = f.nfd;
    if (fd < nfd)
        return 0;
    if (fd >= nfd + c.DELTAFD)
        return -1; // out of range
    // Unbounded allocation is unwise; besides, there are only 16 bits of
    // fid in 9P
    if (nfd >= 5000) {
        port.print("no free file descriptors\n", .{});
        return -1;
    }
    const oldfd = f.fd;
    const oldflag = f.flag;
    const n: usize = @intCast(nfd + c.DELTAFD);
    const newfd_: ?[*][*c]Chan = @ptrCast(@alignCast(port.malloc(@intCast(n * @sizeOf(?*Chan)))));
    const newflag: ?[*]u8 = @ptrCast(port.malloc(@intCast(n)));
    if (newfd_ == null or newflag == null) {
        c.free(newflag);
        c.free(@ptrCast(newfd_));
        port.print("no free file descriptors\n", .{});
        return -1;
    }
    const old: usize = @intCast(nfd);
    @memcpy(newfd_.?[0..old], oldfd[0..old]);
    @memcpy(newflag.?[0..old], oldflag[0..old]);
    f.fd = newfd_.?;
    f.flag = newflag.?;
    f.nfd = nfd + c.DELTAFD;
    if (fd > f.maxfd) {
        if (@divTrunc(fd, 100) > @divTrunc(f.maxfd, 100))
            f.exceed = @divTrunc(fd, 100) * 100;
        f.maxfd = fd;
    }
    c.free(@ptrCast(oldfd));
    c.free(oldflag);
    return 1;
}

/// this assumes that the fgrp is locked
fn findfreefd(f: *Fgrp, start: c_int) c_int {
    var fd = start;
    while (fd < f.nfd) : (fd += 1)
        if (f.fd[@intCast(fd)] == null)
            break;
    if (fd >= f.nfd and growfd(f, fd) < 0)
        return -1;
    return fd;
}

pub fn newfd(ch: *Chan, mode: c_int) c_int {
    const f: *Fgrp = up().fgrp;
    c.lock(&f.ref.lk);
    const fd = findfreefd(f, 0);
    if (fd < 0) {
        unlockfgrp(f);
        return -1;
    }
    if (fd > f.maxfd)
        f.maxfd = fd;
    f.fd[@intCast(fd)] = ch;

    // per file-descriptor flags
    var flag: u8 = 0;
    if (mode & c.OCEXEC != 0)
        flag |= c.CCEXEC;
    f.flag[@intCast(fd)] = flag;

    unlockfgrp(f);
    return fd;
}

fn newfd2(fd: *[2]c_int, ch: [2]*Chan) c_int {
    const f: *Fgrp = up().fgrp;
    c.lock(&f.ref.lk);
    fd[0] = findfreefd(f, 0);
    if (fd[0] < 0) {
        unlockfgrp(f);
        return -1;
    }
    fd[1] = findfreefd(f, fd[0] + 1);
    if (fd[1] < 0) {
        unlockfgrp(f);
        return -1;
    }
    if (fd[1] > f.maxfd)
        f.maxfd = fd[1];
    f.fd[@intCast(fd[0])] = ch[0];
    f.fd[@intCast(fd[1])] = ch[1];
    f.flag[@intCast(fd[0])] = 0;
    f.flag[@intCast(fd[1])] = 0;
    unlockfgrp(f);
    return 0;
}

pub fn fdtochan(fd: c_int, mode: c_int, chkmnt: bool, iref: bool) Error!*Chan {
    const f: *Fgrp = up().fgrp;

    c.lock(&f.ref.lk);
    const ch_: ?*Chan = if (fd < 0 or f.nfd <= fd) null else f.fd[@intCast(fd)];
    const ch = ch_ orelse {
        c.unlock(&f.ref.lk);
        return port.kerror(&port.Ebadfd);
    };
    if (iref)
        _ = chan.incref(&ch.ref);
    c.unlock(&f.ref.lk);

    if (chkmnt and (ch.flag & c.CMSG) != 0) {
        if (iref)
            chan.cclose(ch);
        return port.kerror(&port.Ebadusefd);
    }

    if (mode < 0 or ch.mode == c.ORDWR)
        return ch;

    if ((mode & c.OTRUNC) != 0 and ch.mode == c.OREAD) {
        if (iref)
            chan.cclose(ch);
        return port.kerror(&port.Ebadusefd);
    }

    if ((mode & ~@as(c_int, c.OTRUNC)) != ch.mode) {
        if (iref)
            chan.cclose(ch);
        return port.kerror(&port.Ebadusefd);
    }
    return ch;
}

pub fn openmode(o_: c_uint) Error!c_int {
    const o = o_ & ~@as(c_uint, c.OTRUNC | c.OCEXEC | c.ORCLOSE);
    if (o > c.OEXEC)
        return port.kerror(&port.Ebadarg);
    if (o == c.OEXEC)
        return c.OREAD;
    return @intCast(o);
}

/// (drawterm's _sysfd2path printed into nbuf bytes with an unset
/// length; this uses nbuf.)
pub fn fd2path(fd: c_int, buf: [*]u8, nbuf: c_uint) Error!c_int {
    const ch = try fdtochan(fd, -1, false, true);
    _ = c.snprint(buf, @intCast(nbuf), @constCast("%s"), chan.chanpath(ch));
    chan.cclose(ch);
    return 0;
}

pub fn pipe(fd: *[2]c_int) Error!c_int {
    const datastr = [_][*:0]const u8{ "data", "data1" };

    var c0 = try chan.namec("#|", c.Atodir, 0, 0);
    var c1: *Chan = undefined;
    var have1 = false;
    fd.* = .{ -1, -1 };

    errdefer {
        chan.cclose(c0);
        if (have1)
            chan.cclose(c1);
    }
    c1 = try chan.cclone(c0);
    have1 = true;
    if (try chan.walk(&c0, datastr[0..].ptr, 1, true, null) < 0)
        return port.kerror(&port.Egreg);
    if (try chan.walk(&c1, datastr[1..].ptr, 1, true, null) < 0)
        return port.kerror(&port.Egreg);
    c0 = try dev.open(dev.of(c0), c0, c.ORDWR);
    c1 = try dev.open(dev.of(c1), c1, c.ORDWR);
    if (newfd2(fd, .{ c0, c1 }) < 0)
        return port.kerror(&port.Enofd);
    return 0;
}

pub fn dup(fd0: c_int, fd1: c_int) Error!c_int {
    const f: *Fgrp = up().fgrp;

    // Close after dup'ing, so date > #d/1 works
    const ch = try fdtochan(fd0, -1, false, true);
    var fd = fd1;
    if (fd != -1) {
        c.lock(&f.ref.lk);
        if (fd < 0 or growfd(f, fd) < 0) {
            unlockfgrp(f);
            chan.cclose(ch);
            return port.kerror(&port.Ebadfd);
        }
        if (fd > f.maxfd)
            f.maxfd = fd;

        const oc: ?*Chan = f.fd[@intCast(fd)];
        f.fd[@intCast(fd)] = ch;
        f.flag[@intCast(fd)] = 0;
        unlockfgrp(f);
        if (oc) |o|
            chan.cclose(o);
    } else {
        errdefer chan.cclose(ch);
        fd = newfd(ch, 0);
        if (fd < 0)
            return port.kerror(&port.Enofd);
    }
    return fd;
}

pub fn open(name: [*:0]const u8, mode: c_int) Error!c_int {
    _ = try openmode(@bitCast(mode)); // error check only
    const ch = try chan.namec(name, c.Aopen, mode, 0);
    errdefer chan.cclose(ch);
    const fd = newfd(ch, mode);
    if (fd < 0)
        return port.kerror(&port.Enofd);
    return fd;
}

fn fdclose(fd_: c_int, flag: c_int) void {
    var fd = fd_;
    const f: *Fgrp = up().fgrp;

    c.lock(&f.ref.lk);
    const ch: ?*Chan = if (fd <= f.maxfd) f.fd[@intCast(fd)] else null;
    if (ch == null or (flag != 0 and ((f.flag[@intCast(fd)] | ch.?.flag) & flag) == 0)) {
        c.unlock(&f.ref.lk);
        return;
    }
    f.fd[@intCast(fd)] = null;
    if (fd == f.maxfd) {
        while (fd > 0 and f.fd[@intCast(fd)] == null) {
            fd -= 1;
            f.maxfd = fd;
        }
    }
    c.unlock(&f.ref.lk);
    chan.cclose(ch);
}

pub fn close(fd: c_int) Error!c_int {
    _ = try fdtochan(fd, -1, false, false);
    fdclose(fd, 0);
    return 0;
}

pub fn unionread(ch: *Chan, va: ?*anyopaque, n: c_int) c_int {
    sync.qlock(&ch.umqlock);
    const m: *Mhead = ch.umh;
    sync.rlock(&m.lock);
    var mnt: ?*Mount = m.mount;
    // bring mount in sync with c->uri and c->umc
    var i: c_int = 0;
    while (mnt != null and i < ch.uri) : (i += 1)
        mnt = mnt.?.next;

    var nr: c_int = 0;
    while (mnt) |mt| {
        // Error causes component of union to be skipped
        if (mt.to != null)
            unionread1(ch, mt.to, va, n, &nr) catch {};
        if (nr > 0)
            break;

        // Advance to next element
        ch.uri += 1;
        if (@as(?*Chan, ch.umc)) |u| {
            chan.cclose(u);
            ch.umc = null;
        }
        mnt = mt.next;
    }
    sync.runlock(&m.lock);
    sync.qunlock(&ch.umqlock);
    return nr;
}

/// unionread's read of one member of the union, to: an error skips it.
fn unionread1(ch: *Chan, to: *Chan, va: ?*anyopaque, n: c_int, nr: *c_int) Error!void {
    if (ch.umc == null) {
        ch.umc = try chan.cclone(to);
        ch.umc = try dev.open(dev.of(ch.umc), ch.umc, c.OREAD);
    }

    const umc: *Chan = ch.umc;
    nr.* = try dev.read(dev.of(umc), umc, va, n, umc.offset);
    umc.offset += nr.*;
}

fn unionrewind(ch: *Chan) void {
    sync.qlock(&ch.umqlock);
    ch.uri = 0;
    if (@as(?*Chan, ch.umc)) |u| {
        chan.cclose(u);
        ch.umc = null;
    }
    sync.qunlock(&ch.umqlock);
}

fn gbit16(p: [*]const u8) u16 {
    return std.mem.readInt(u16, p[0..2], .little);
}
fn gbit32(p: [*]const u8) u32 {
    return std.mem.readInt(u32, p[0..4], .little);
}
fn gbit64(p: [*]const u8) u64 {
    return std.mem.readInt(u64, p[0..8], .little);
}
fn pbit16(p: [*]u8, v: c_int) void {
    std.mem.writeInt(u16, p[0..2], @truncate(@as(c_uint, @bitCast(v))), .little);
}

/// The bytes from p to q.
fn diff(p: [*]const u8, q: [*]const u8) isize {
    return @bitCast(@intFromPtr(q) -% @intFromPtr(p));
}

/// C's memmove: n bytes from src to dst, which may overlap.
fn memmove(dst: [*]u8, src: [*]const u8, n: usize) void {
    if (n == 0 or dst == src)
        return;
    if (@intFromPtr(dst) < @intFromPtr(src))
        std.mem.copyForwards(u8, dst[0..n], src[0..n])
    else
        std.mem.copyBackwards(u8, dst[0..n], src[0..n]);
}

fn dirfixed(p_: [*]u8, e: [*]u8, d: *Dir) c_int {
    var p = p_;
    const len: c_int = @as(c_int, gbit16(p)) + c.BIT16SZ;
    if (diff(p, e) < len)
        return -1;

    p += c.BIT16SZ; // ignore size
    d.type = @truncate(@as(c_uint, @bitCast(dev.devno(gbit16(p)))));
    p += c.BIT16SZ;
    d.dev = gbit32(p);
    p += c.BIT32SZ;
    d.qid.type = p[0];
    p += c.BIT8SZ;
    d.qid.vers = gbit32(p);
    p += c.BIT32SZ;
    d.qid.path = gbit64(p);
    p += c.BIT64SZ;
    d.mode = gbit32(p);
    p += c.BIT32SZ;
    d.atime = gbit32(p);
    p += c.BIT32SZ;
    d.mtime = gbit32(p);
    p += c.BIT32SZ;
    d.length = @bitCast(gbit64(p));

    return len;
}

fn dirname(p_: [*]u8, n: *c_int) [*]u8 {
    const p = p_ + (c.BIT16SZ + c.BIT16SZ + c.BIT32SZ + c.BIT8SZ + c.BIT32SZ + c.BIT64SZ + c.BIT32SZ + c.BIT32SZ + c.BIT32SZ + c.BIT64SZ);
    n.* = gbit16(p);
    return p + c.BIT16SZ;
}

fn dirsetname(name: [*]const u8, len: c_int, p: [*]u8, n: c_int, maxn: c_int) c_int {
    if (n == c.BIT16SZ)
        return c.BIT16SZ;

    var olen: c_int = undefined;
    const oname = dirname(p, &olen);

    const nn = n + len - olen;
    pbit16(p, nn - c.BIT16SZ);
    if (nn > maxn)
        return c.BIT16SZ;

    if (len != olen)
        memmove(oname + @as(usize, @intCast(len)), oname + @as(usize, @intCast(olen)), @intCast(diff(oname + @as(usize, @intCast(olen)), p + @as(usize, @intCast(n)))));
    pbit16(oname - 2, len);
    memmove(oname, name, @intCast(len));
    return nn;
}

/// Mountfix might have caused the fixed results of the directory read
/// to overflow the buffer. Catch the overflow in c->dirrock.
fn mountrock(ch: *Chan, p_: [*]u8, pe: *[*]u8) void {
    var p = p_;
    const e = pe.*;

    // find last directory entry
    var len: c_int = undefined;
    while (true) {
        len = c.BIT16SZ + @as(c_int, gbit16(p));
        if (diff(p, e) <= len)
            break;
        p += @intCast(len);
    }

    // save it away
    sync.qlock(&ch.rockqlock);
    if (ch.nrock + len > ch.mrock) {
        const n = std.mem.alignForward(usize, @intCast(ch.nrock + len), 1024);
        const r: [*]u8 = @ptrCast(c.smalloc(@intCast(n)));
        if (ch.nrock > 0) @memcpy(r[0..@intCast(ch.nrock)], ch.dirrock[0..@intCast(ch.nrock)]);
        c.free(ch.dirrock);
        ch.dirrock = r;
        ch.mrock = @intCast(n);
    }
    @memcpy(ch.dirrock[@intCast(ch.nrock)..][0..@intCast(len)], p[0..@intCast(len)]);
    ch.nrock += len;
    sync.qunlock(&ch.rockqlock);

    // drop it
    pe.* = p;
}

/// Satisfy a directory read with the results saved in c->dirrock.
fn mountrockread(ch: *Chan, op: [*]u8, n: c_int, nn: *c_int) bool {
    // common case
    if (ch.nrock == 0)
        return false;

    // copy out what we can
    sync.qlock(&ch.rockqlock);
    var rp: [*]u8 = ch.dirrock;
    const erp = rp + @as(usize, @intCast(ch.nrock));
    var p = op;
    const ep = p + @as(usize, @intCast(n));
    while (diff(rp, erp) >= c.BIT16SZ) {
        const dirlen: usize = @as(usize, c.BIT16SZ) + gbit16(rp);
        if (diff(p, ep) < dirlen)
            break;
        @memmove(p[0..dirlen], rp[0..dirlen]);
        p += dirlen;
        rp += dirlen;
    }

    if (p == op) {
        sync.qunlock(&ch.rockqlock);
        return false;
    }

    // shift the rest
    const rest: usize = @intCast(diff(rp, erp));
    if (rp != erp)
        memmove(ch.dirrock, rp, rest);
    ch.nrock = @intCast(rest);

    nn.* = @intCast(diff(op, p));
    sync.qunlock(&ch.rockqlock);
    return true;
}

fn mountrewind(ch: *Chan) void {
    ch.nrock = 0;
}

/// Rewrite the results of a directory read to reflect current name
/// space bindings and mounts. Specifically, replace directory entries
/// for bind and mount points with the results of statting what is
/// mounted there. Except leave the old names.
fn mountfix(ch: *Chan, op: [*]u8, n: c_int, maxn: c_int) Error!c_int {
    var p = op;
    var buf: ?[*]u8 = null;
    var nbuf: c_int = 0;
    defer c.free(buf);
    var e = op + @as(usize, @intCast(n));
    var dirlen: c_int = 0;
    while (diff(p, e) > c.BIT16SZ) : (p += @intCast(dirlen)) {
        var d: Dir = undefined;
        dirlen = dirfixed(p, e, &d);
        if (dirlen < 0)
            break;
        var nc: ?*Chan = null;
        var mh: ?*Mhead = null;
        if (chan.findmount(&nc, &mh, d.type, @bitCast(d.dev), d.qid)) {
            norewrite: {
                // If it's a union directory and the original is in the
                // union, don't rewrite anything.
                const h = mh.?;
                sync.rlock(&h.lock);
                var m: ?*Mount = h.mount;
                while (m) |mt| : (m = mt.next) {
                    if (chan.eqchantdqid(mt.to, d.type, @bitCast(d.dev), d.qid, true)) {
                        sync.runlock(&h.lock);
                        break :norewrite;
                    }
                }
                sync.runlock(&h.lock);

                var nname: c_int = undefined;
                const name = dirname(p, &nname);
                const l = restat(nc.?, &buf, &nbuf, name, nname) catch break :norewrite;

                // Shift data in buffer to accomodate new entry, possibly
                // overflowing into rock.
                var rest: c_int = @intCast(diff(p + @as(usize, @intCast(dirlen)), e));
                if (l > dirlen) {
                    while (diff(op, p) + l + rest > maxn) {
                        mountrock(ch, p, &e);
                        if (e == p) {
                            dirlen = 0;
                            break :norewrite;
                        }
                        rest = @intCast(diff(p + @as(usize, @intCast(dirlen)), e));
                    }
                }
                if (l != dirlen) {
                    memmove(p + @as(usize, @intCast(l)), p + @as(usize, @intCast(dirlen)), @intCast(rest));
                    dirlen = l;
                    e = p + @as(usize, @intCast(dirlen + rest));
                }

                // Rewrite directory entry.
                @memcpy(p[0..@intCast(l)], buf.?[0..@intCast(l)]);
            }
            // Norewrite:
            chan.cclose(nc);
            chan.putmhead(mh);
        }
    }

    if (p != e)
        return port.kerror("oops in rockfix");

    return @intCast(diff(op, e));
}

/// mountfix's stat of what's mounted on an entry, under the entry's name,
/// into *buf: an error leaves the entry as it was.
fn restat(nc: *Chan, buf: *?[*]u8, nbuf: *c_int, name: [*]const u8, nname: c_int) Error!c_int {
    if (buf.* == null) {
        nbuf.* = 4096;
        buf.* = @ptrCast(c.smalloc(@intCast(nbuf.*)));
    }
    var l = try dev.stat(dev.of(nc), nc, buf.*.?, nbuf.*);
    if (l < c.BIT16SZ)
        return port.kerror(&port.Eshortstat);
    const rest = c.BIT16SZ + @as(c_int, gbit16(buf.*.?)) + nname;
    if (rest > nbuf.*) {
        c.free(buf.*);
        nbuf.* = rest;
        buf.* = @ptrCast(c.smalloc(@intCast(nbuf.*)));
        l = try dev.stat(dev.of(nc), nc, buf.*.?, nbuf.*);
    }
    l = dirsetname(name, nname, buf.*.?, l, nbuf.*);
    if (l <= c.BIT16SZ)
        return port.kerror(&port.Eshortstat);
    return l;
}

/// h9: kread's work on a channel, for kserve (src/kern/kserve.c,
/// design/epoch-0/kernel-serve.md), so its directory reads of unions and mount
/// points are sysread's.
pub fn chanread(ch: *Chan, p: [*]u8, n: c_int, offp: ?*i64) Error!c_int {
    // The offset is passed through on directories, normally. Sysseek
    // complains, but pread is used by servers like exportfs, that
    // shouldn't need to worry about this issue.
    //
    // Notice that c->devoffset is the offset that c's dev is seeing. The
    // number of bytes read on this fd (c->offset) may be different due
    // to rewritings in rockfix.
    const off: i64 = if (offp) |o| o.* else ch.offset; // use and maintain channel's offset
    if (off < 0)
        return port.kerror(&port.Enegoff);

    if (off == 0) { // rewind to the beginning of the directory
        if (offp == null or (ch.qid.type & c.QTDIR) != 0) {
            ch.offset = 0;
            ch.devoffset = 0;
        }
        mountrewind(ch);
        unionrewind(ch);
    }

    var nn: c_int = 0;
    var nnn: c_int = 0;
    if (ch.qid.type & c.QTDIR != 0) {
        if (mountrockread(ch, p, n, &nn)) {
            // do nothing: mountrockread filled buffer
        } else if (ch.umh != null)
            nn = unionread(ch, p, n)
        else {
            if (off != ch.offset)
                return port.kerror(&port.Edirseek);
            nn = try dev.read(dev.of(ch), ch, p, n, ch.devoffset);
        }
        nnn = try mountfix(ch, p, nn, n);
    } else {
        nn = try dev.read(dev.of(ch), ch, p, n, off);
        nnn = nn;
    }

    if (offp == null or (ch.qid.type & c.QTDIR) != 0) {
        c.lock(&ch.lk);
        ch.devoffset += nn;
        ch.offset += nnn;
        c.unlock(&ch.lk);
    }
    return nnn;
}

fn kread(fd: c_int, p: [*]u8, n: c_int, offp: ?*i64) Error!c_int {
    const ch = try fdtochan(fd, c.OREAD, true, true);
    defer chan.cclose(ch);
    return chanread(ch, p, n, offp);
}

pub fn pread(fd: c_int, buf: [*]u8, len: c_int, off_: i64) Error!c_int {
    var off = off_;
    return kread(fd, buf, len, if (off != -1) &off else null);
}

fn kwrite(fd: c_int, buf: ?*const anyopaque, len: c_int, offp: ?*i64) Error!c_int {
    var n: c_int = 0;
    const ch = try fdtochan(fd, c.OWRITE, true, true);
    errdefer {
        if (offp == null) {
            c.lock(&ch.ref.lk);
            ch.offset -= n;
            c.unlock(&ch.ref.lk);
        }
        chan.cclose(ch);
    }

    if (ch.qid.type & c.QTDIR != 0)
        return port.kerror(&port.Eisdir);

    n = len;

    var off: i64 = undefined;
    if (offp) |o|
        off = o.*
    else { // use and maintain channel's offset
        c.lock(&ch.ref.lk);
        off = ch.offset;
        ch.offset += n;
        c.unlock(&ch.ref.lk);
    }

    if (off < 0)
        return port.kerror(&port.Enegoff);

    const m = try dev.write(dev.of(ch), ch, buf, n, off);
    if (offp == null and m < n) {
        c.lock(&ch.ref.lk);
        ch.offset -= n - m;
        c.unlock(&ch.ref.lk);
    }

    chan.cclose(ch);
    return m;
}

pub fn pwrite(fd: c_int, buf: ?*const anyopaque, len: c_int, off_: i64) Error!c_int {
    var off = off_;
    return kwrite(fd, buf, len, if (off != -1) &off else null);
}

pub fn seek(fd: c_int, o: i64, @"type": c_int) Error!i64 {
    const ch = try fdtochan(fd, -1, true, true);
    defer chan.cclose(ch);
    if (dev.of(ch).dc == '|')
        return port.kerror(&port.Eisstream);

    var off: i64 = undefined;
    switch (@"type") {
        0 => {
            off = o;
            if ((ch.qid.type & c.QTDIR) != 0 and off != 0)
                return port.kerror(&port.Eisdir);
            if (off < 0)
                return port.kerror(&port.Enegoff);
            ch.offset = off;
        },

        1 => {
            if (ch.qid.type & c.QTDIR != 0)
                return port.kerror(&port.Eisdir);
            c.lock(&ch.ref.lk); // lock for read/write update
            off = o +% ch.offset;
            if (off < 0) {
                c.unlock(&ch.ref.lk);
                return port.kerror(&port.Enegoff);
            }
            ch.offset = off;
            c.unlock(&ch.ref.lk);
        },

        2 => {
            if (ch.qid.type & c.QTDIR != 0)
                return port.kerror(&port.Eisdir);
            const d = try chan.dirchanstat(ch);
            off = d.length +% o;
            c.free(d);
            if (off < 0)
                return port.kerror(&port.Enegoff);
            ch.offset = off;
        },

        else => return port.kerror(&port.Ebadarg),
    }
    ch.uri = 0;
    ch.dri = 0;
    return off;
}

pub fn validstat(s_: [*]const u8, n: c_int) Error!void {
    var s = s_;
    if (c.statcheck(@constCast(s), @bitCast(n)) < 0)
        return port.kerror(&port.Ebadstat);
    // verify that name entry is acceptable
    s += c.STATFIXLEN - 4 * c.BIT16SZ; // location of first string
    // s now points at count for first string. if it's too long, let the
    // server decide; this is only for his protection anyway. otherwise
    // we'd have to allocate and waserror.
    const m = gbit16(s);
    s += c.BIT16SZ;
    var buf: [64:0]u8 = undefined;
    if (@as(usize, m) + 1 > buf.len)
        return;
    @memcpy(buf[0..m], s[0..m]);
    buf[m] = 0;
    // name could be '/'
    if (!dev.streq(&buf, "/"))
        try chan.validname(&buf, false);
}

fn pathlast(p_: ?*Path) ?[*:0]u8 {
    const p = p_ orelse return null;
    if (p.len == 0)
        return null;
    const s: [*c]u8 = c.strrchr(p.s, '/');
    if (s != null)
        return @ptrCast(s + 1);
    return @ptrCast(p.s);
}

pub fn fstat(fd: c_int, s: [*]u8, n: c_int) Error!c_int {
    const l: c_uint = @bitCast(n);
    const ch = try fdtochan(fd, -1, false, true);
    defer chan.cclose(ch);
    var r = try dev.stat(dev.of(ch), ch, s, @bitCast(l));
    if (pathlast(ch.path)) |name|
        r = dirsetname(name, @intCast(std.mem.len(name)), s, r, @bitCast(l));
    return r;
}

/// h9: fstat's work on a channel, for kserve (src/kern/kserve.c).
pub fn chanstat(ch: *Chan, s: [*]u8, n: c_int) Error!c_int {
    var r = try dev.stat(dev.of(ch), ch, s, n);
    if (pathlast(ch.path)) |name| if (name[0] != 0) {
        r = dirsetname(name, @intCast(std.mem.len(name)), s, r, n);
    };
    return r;
}

pub fn stat(name: [*:0]const u8, s: [*]u8, n: c_int) Error!c_int {
    const l: c_uint = @bitCast(n);
    const ch = try chan.namec(name, c.Aaccess, 0, 0);
    defer chan.cclose(ch);
    var r = try dev.stat(dev.of(ch), ch, s, @bitCast(l));
    if (pathlast(ch.path)) |last|
        r = dirsetname(last, @intCast(std.mem.len(last)), s, r, @bitCast(l));
    return r;
}

pub fn chdir(name: [*:0]const u8) Error!c_int {
    const ch = try chan.namec(name, c.Atodir, 0, 0);
    chan.cclose(up().dot);
    up().dot = ch;
    return 0;
}

fn bindmount(ismount: bool, fd: c_int, afd: c_int, arg0: ?[*:0]const u8, arg1: [*:0]const u8, flag: c_int, spec_: ?[*:0]const u8) Error!c_int {
    if ((flag & ~@as(c_int, c.MMASK)) != 0 or (flag & c.MORDER) == (c.MBEFORE | c.MAFTER))
        return port.kerror(&port.Ebadarg);

    var spec: ?[*:0]u8 = null;
    defer if (ismount) c.free(spec);
    var c0: *Chan = undefined;
    if (ismount) {
        if (!pgrp.canmount(up().pgrp))
            return port.kerror(&port.Enoattach);

        spec = try chan.validnamedup(spec_.?, true);
        const bc = try fdtochan(fd, c.ORDWR, false, true);
        defer chan.cclose(bc);
        var ac: ?*Chan = null;
        if (afd >= 0)
            ac = try fdtochan(afd, c.ORDWR, false, true);
        defer if (ac) |a| chan.cclose(a);
        c0 = try devmnt.mntattach(bc, ac, spec.?, flag & c.MCACHE);
    } else {
        c0 = try chan.namec(arg0.?, c.Abind, 0, 0);
    }
    defer chan.cclose(c0);
    const c1 = try chan.namec(arg1, c.Amount, 0, 0);
    defer chan.cclose(c1);
    const ret = try chan.cmount(c0, c1, flag, spec);
    if (ismount)
        fdclose(fd, 0);
    return ret;
}

pub fn bind(old: [*:0]const u8, new: [*:0]const u8, flag: c_int) Error!c_int {
    return bindmount(false, -1, -1, old, new, flag, null);
}

pub fn mount(fd: c_int, afd: c_int, new: [*:0]const u8, flag: c_int, spec: ?[*:0]const u8) Error!c_int {
    return bindmount(true, fd, afd, null, new, flag, spec);
}

pub fn unmount(name: ?[*:0]const u8, old: [*:0]const u8) Error!c_int {
    const cmount = try chan.namec(old, c.Amount, 0, 0);
    defer chan.cclose(cmount);
    if (name) |nm| {
        const cmounted = try chan.namec(nm, c.Aunmount, c.OREAD, 0);
        defer chan.cclose(cmounted);
        try chan.cunmount(cmount, cmounted);
    } else try chan.cunmount(cmount, null);
    return 0;
}

pub fn create(name: [*:0]const u8, mode: c_int, perm: c_uint) Error!c_int {
    _ = try openmode(@bitCast(mode & ~@as(c_int, c.OEXCL))); // error check only; OEXCL okay here
    const ch = try chan.namec(name, c.Acreate, mode, perm);
    errdefer chan.cclose(ch);
    const fd = newfd(ch, mode);
    if (fd < 0)
        return port.kerror(&port.Enofd);
    return fd;
}

pub fn remove(name: [*:0]const u8) Error!c_int {
    const ch = try chan.namec(name, c.Aremove, 0, 0);
    // Removing mount points is disallowed to avoid surprises (which
    // should be removed: the mount point or the mounted Chan?).
    if (ch.ismtpt != 0) {
        chan.cclose(ch);
        return port.kerror(&port.Eismtpt);
    }
    // Remove clunks the fid, but we need to recover the Chan so fake it
    // up. rootclose() is known to be a nop.
    defer {
        ch.type = 0;
        chan.cclose(ch);
    }
    try dev.remove(dev.of(ch), ch);
    return 0;
}

fn wstatChan(ch: *Chan, d: [*]u8, nd: c_int) Error!c_int {
    defer chan.cclose(ch);
    if (ch.ismtpt != 0) {
        // Renaming mount points is disallowed to avoid surprises (which
        // should be renamed? the mount point or the mounted Chan?).
        var namelen: c_int = undefined;
        _ = dirname(d, &namelen);
        if (namelen != 0) {
            const p = chan.chanpath(ch);
            return chan.namelenerror(p, @intCast(std.mem.len(p)), &port.Eismtpt);
        }
    }
    return dev.wstat(dev.of(ch), ch, d, nd);
}

pub fn wstat(name: [*:0]const u8, s: [*]u8, l: c_int) Error!c_int {
    try validstat(s, l);
    const ch = try chan.namec(name, c.Aaccess, 0, 0);
    return wstatChan(ch, s, l);
}

pub fn fwstat(fd: c_int, s: [*]u8, l: c_int) Error!c_int {
    try validstat(s, l);
    const ch = try fdtochan(fd, -1, true, true);
    return wstatChan(ch, s, l);
}

/// A call's start: no waserror is pending (starterror).
fn starterror() void {
    port.assert(up().nerrlab == 0);
}

/// A call that succeeded (enderror). There's no popnote.
fn enderror() void {
    port.assert(up().nerrlab == 0);
    up().notepending = 0;
}

/// A call that failed: its error string becomes the process's
/// syserrstr, as errstr(2) reads it.
fn syserror() void {
    const p = up();
    const s = p.syserrstr;
    p.syserrstr = p.errstr;
    p.errstr = s;
}

/// A call from C: f(args), or (on an error) -1, or what fail is.
fn call(comptime f: anytype, args: anytype, fail: anytype) @TypeOf(fail) {
    starterror();
    const r = @call(.auto, f, args) catch {
        syserror();
        return fail;
    };
    enderror();
    return r;
}

/// h9: fd0 dup'ed onto the lowest free fd at or above min, found and
/// taken under the fgrp's lock, close-on-exec if cexec, for Linux's
/// F_DUPFD and F_DUPFD_CLOEXEC (src/linux/sys.zig). Finding a free fd
/// first and then dup'ing onto it would replace one another thread
/// opened in between.
pub fn dupfrom(fd0: c_int, min: c_int, cexec: bool) Error!c_int {
    const f: *Fgrp = up().fgrp;
    const ch = try fdtochan(fd0, -1, false, true);
    c.lock(&f.ref.lk);
    const fd = findfreefd(f, if (min < 0) 0 else min);
    if (fd < 0) {
        unlockfgrp(f);
        chan.cclose(ch);
        return port.kerror(&port.Enofd);
    }
    if (fd > f.maxfd)
        f.maxfd = fd;
    f.fd[@intCast(fd)] = ch;
    f.flag[@intCast(fd)] = if (cexec) c.CCEXEC else 0;
    unlockfgrp(f);
    return fd;
}

pub fn iounit(fd: c_int) Error!c_uint {
    const ch = try fdtochan(fd, -1, false, false);
    return ch.iounit;
}

pub fn errfmt(fmt: *c.Fmt) c_int {
    const p = up();
    return c.fmtstrcpy(fmt, if (p.nerrlab != 0) p.errstr else p.syserrstr);
}

pub fn errstr(buf: [*]u8, n: c_uint) c_int {
    const p = up();
    var tmp: [port.ERRMAX]u8 = undefined;
    const s: [*]u8 = if (p.nerrlab != 0) p.errstr else p.syserrstr;
    @memcpy(&tmp, s[0..port.ERRMAX]);
    _ = c.utfecpy(s, s + port.ERRMAX, @ptrCast(buf));
    _ = c.utfecpy(buf, buf + n, &tmp);
    return @intCast(std.mem.len(@as([*:0]u8, @ptrCast(buf))));
}

pub fn rerrstr(buf: [*]u8, n: c_uint) c_int {
    const p = up();
    _ = c.utfecpy(buf, buf + n, if (p.nerrlab != 0) p.errstr else p.syserrstr);
    return @intCast(std.mem.len(@as([*:0]u8, @ptrCast(buf))));
}

pub fn rendezvous(arg0: ?*anyopaque, arg1: ?*anyopaque) ?*anyopaque {
    const me = up();
    const tag = arg0;
    const rg: *c.Rgrp = me.rgrp;
    var l: *[*c]c.Proc = &rg.rendhash[@intFromPtr(tag) & ((1 << c.RENDLOG) - 1)];
    me.rendval = @ptrFromInt(~@as(usize, 0));

    c.lock(&rg.ref.lk);
    var p_: ?*c.Proc = l.*;
    while (p_) |p| : (p_ = p.rendhash) {
        if (p.rendtag == tag) {
            l.* = p.rendhash;
            const val = p.rendval;
            p.rendval = arg1;

            while (@as(*volatile c_uint, &p.mach).* != 0) {}
            sync.unpark(p);
            c.unlock(&rg.ref.lk);
            return val;
        }
        l = &p.rendhash;
    }

    // Going to sleep here
    me.rendtag = tag;
    me.rendval = arg1;
    me.rendhash = l.*;
    l.* = me;
    me.state = @intCast(c.Rendezvous);
    c.unlock(&rg.ref.lk);

    sync.park();

    return me.rendval;
}

// The C kernel's names, with its semantics. The internal functions
// C calls raise their errors; the system calls return -1, with the
// error string as the process's syserrstr.

fn c_fdtochan(fd: c_int, mode: c_int, chkmnt: c_int, iref: c_int) callconv(.c) *Chan {
    return fdtochan(fd, mode, chkmnt != 0, iref != 0) catch |e| port.raise(e);
}
fn c_openmode(o: c_uint) callconv(.c) c_int {
    return openmode(o) catch |e| port.raise(e);
}
fn c_newfd(ch: *Chan, mode: c_int) callconv(.c) c_int {
    return newfd(ch, mode);
}
fn c_sysclose_raise(fd: c_int) callconv(.c) c_int {
    return close(fd) catch |e| port.raise(e);
}
fn c_unionread(ch: *Chan, va: ?*anyopaque, n: c_int) callconv(.c) c_int {
    return unionread(ch, va, n);
}
fn c_h9_chanread(ch: *Chan, p: [*]u8, n: c_int, offp: ?*i64) callconv(.c) c_int {
    return chanread(ch, p, n, offp) catch |e| port.raise(e);
}
fn c_validstat(s: [*]const u8, n: c_int) callconv(.c) void {
    validstat(s, n) catch |e| port.raise(e);
}
fn c_h9_chanstat(ch: *Chan, s: [*]u8, n: c_int) callconv(.c) c_int {
    return chanstat(ch, s, n) catch |e| port.raise(e);
}
fn c_sysbind(old: [*:0]const u8, new: [*:0]const u8, flag: c_int) callconv(.c) c_int {
    return call(bind, .{ old, new, flag }, @as(c_int, -1));
}
fn c_syschdir(path: [*:0]const u8) callconv(.c) c_int {
    return call(chdir, .{path}, @as(c_int, -1));
}
fn c_sysclose(fd: c_int) callconv(.c) c_int {
    return call(close, .{fd}, @as(c_int, -1));
}
fn c_syscreate(name: [*:0]const u8, mode: c_int, perm: c_uint) callconv(.c) c_int {
    return call(create, .{ name, mode, perm }, @as(c_int, -1));
}
fn c_sysdup(fd0: c_int, fd1: c_int) callconv(.c) c_int {
    return call(dup, .{ fd0, fd1 }, @as(c_int, -1));
}
fn c_h9_dupfrom(fd0: c_int, min: c_int, cexec: c_int) callconv(.c) c_int {
    return call(dupfrom, .{ fd0, min, cexec != 0 }, @as(c_int, -1));
}
fn c_sysfstat(fd: c_int, buf: [*]u8, n: c_int) callconv(.c) c_int {
    return call(fstat, .{ fd, buf, n }, @as(c_int, -1));
}
fn c_sysfwstat(fd: c_int, buf: [*]u8, n: c_int) callconv(.c) c_int {
    return call(fwstat, .{ fd, buf, n }, @as(c_int, -1));
}
fn c_sysmount(fd: c_int, afd: c_int, new: [*:0]const u8, flag: c_int, spec: ?[*:0]const u8) callconv(.c) c_int {
    return call(mount, .{ fd, afd, new, flag, spec }, @as(c_int, -1));
}
fn c_sysunmount(old: ?[*:0]const u8, new: [*:0]const u8) callconv(.c) c_int {
    return call(unmount, .{ old, new }, @as(c_int, -1));
}
fn c_sysopen(name: [*:0]const u8, mode: c_int) callconv(.c) c_int {
    return call(open, .{ name, mode }, @as(c_int, -1));
}
fn c_syspipe(fd: *[2]c_int) callconv(.c) c_int {
    return call(pipe, .{fd}, @as(c_int, -1));
}
fn c_syspread(fd: c_int, buf: [*]u8, n: c_int, off: i64) callconv(.c) c_int {
    return call(pread, .{ fd, buf, n, off }, @as(c_int, -1));
}
fn c_syspwrite(fd: c_int, buf: ?*const anyopaque, n: c_int, off: i64) callconv(.c) c_int {
    return call(pwrite, .{ fd, buf, n, off }, @as(c_int, -1));
}
fn c_sysread(fd: c_int, buf: [*]u8, n: c_int) callconv(.c) c_int {
    return call(pread, .{ fd, buf, n, -1 }, @as(c_int, -1));
}
fn c_sysremove(path: [*:0]const u8) callconv(.c) c_int {
    return call(remove, .{path}, @as(c_int, -1));
}
fn c_sysseek(fd: c_int, off: i64, whence: c_int) callconv(.c) i64 {
    return call(seek, .{ fd, off, whence }, @as(i64, -1));
}
fn c_sysstat(name: [*:0]const u8, buf: [*]u8, n: c_int) callconv(.c) c_int {
    return call(stat, .{ name, buf, n }, @as(c_int, -1));
}
fn c_syswrite(fd: c_int, buf: ?*const anyopaque, n: c_int) callconv(.c) c_int {
    return call(pwrite, .{ fd, buf, n, -1 }, @as(c_int, -1));
}
fn c_sysiounit(fd: c_int) callconv(.c) c_uint {
    return call(iounit, .{fd}, @as(c_uint, @bitCast(@as(c_int, -1))));
}
fn c_syswstat(name: [*:0]const u8, buf: [*]u8, n: c_int) callconv(.c) c_int {
    return call(wstat, .{ name, buf, n }, @as(c_int, -1));
}
fn c_errfmt(fmt: *c.Fmt) callconv(.c) c_int {
    return errfmt(fmt);
}
fn c_errstr(buf: [*]u8, n: c_uint) callconv(.c) c_int {
    return errstr(buf, n);
}
fn c_rerrstr(buf: [*]u8, n: c_uint) callconv(.c) c_int {
    return rerrstr(buf, n);
}
fn c_sysrendezvous(tag: ?*anyopaque, val: ?*anyopaque) callconv(.c) ?*anyopaque {
    starterror();
    const r = rendezvous(tag, val);
    enderror();
    return r;
}
fn c_sysgetpid() callconv(.c) c_int {
    return @bitCast(up().pid);
}
fn c_sysgetkproc() callconv(.c) ?*anyopaque {
    return up();
}
fn c_syskprocint(p: ?*anyopaque) callconv(.c) void {
    if (p) |x|
        sync.procinterrupt(@ptrCast(@alignCast(x)));
}

pub fn exportC() void {
    @export(&c_fdtochan, .{ .name = "fdtochan" });
    @export(&c_openmode, .{ .name = "openmode" });
    @export(&c_newfd, .{ .name = "newfd" });
    @export(&c_sysclose_raise, .{ .name = "_sysclose" });
    @export(&c_unionread, .{ .name = "unionread" });
    @export(&c_h9_chanread, .{ .name = "h9_chanread" });
    @export(&c_validstat, .{ .name = "validstat" });
    @export(&c_h9_chanstat, .{ .name = "h9_chanstat" });
    @export(&c_sysbind, .{ .name = "sysbind" });
    @export(&c_syschdir, .{ .name = "syschdir" });
    @export(&c_sysclose, .{ .name = "sysclose" });
    @export(&c_syscreate, .{ .name = "syscreate" });
    @export(&c_sysdup, .{ .name = "sysdup" });
    @export(&c_h9_dupfrom, .{ .name = "h9_dupfrom" });
    @export(&c_sysfstat, .{ .name = "sysfstat" });
    @export(&c_sysfwstat, .{ .name = "sysfwstat" });
    @export(&c_sysmount, .{ .name = "sysmount" });
    @export(&c_sysunmount, .{ .name = "sysunmount" });
    @export(&c_sysopen, .{ .name = "sysopen" });
    @export(&c_syspipe, .{ .name = "syspipe" });
    @export(&c_syspread, .{ .name = "syspread" });
    @export(&c_syspwrite, .{ .name = "syspwrite" });
    @export(&c_sysread, .{ .name = "sysread" });
    @export(&c_sysremove, .{ .name = "sysremove" });
    @export(&c_sysseek, .{ .name = "sysseek" });
    @export(&c_sysstat, .{ .name = "sysstat" });
    @export(&c_syswrite, .{ .name = "syswrite" });
    @export(&c_sysiounit, .{ .name = "sysiounit" });
    @export(&c_syswstat, .{ .name = "syswstat" });
    @export(&c_errfmt, .{ .name = "__errfmt" });
    @export(&c_errstr, .{ .name = "errstr" });
    @export(&c_rerrstr, .{ .name = "rerrstr" });
    @export(&c_sysrendezvous, .{ .name = "sysrendezvous" });
    @export(&c_sysgetpid, .{ .name = "sysgetpid" });
    @export(&c_sysgetkproc, .{ .name = "sysgetkproc" });
    @export(&c_syskprocint, .{ .name = "syskprocint" });
}

const testing = std.testing;
const kt = port.testing;

/// The names in a directory, as a read of it gives them, sorted and
/// joined by spaces, into buf.
fn listdir(name: [*:0]const u8, buf: []u8) ![]const u8 {
    const fd = try open(name, c.OREAD);
    defer _ = close(fd) catch {};
    var names: [32][]const u8 = undefined;
    var n: usize = 0;
    var dirbuf: [4096]u8 = undefined;
    var strs: [64][256]u8 = undefined;
    while (true) {
        const m: usize = @intCast(try pread(fd, &dirbuf, dirbuf.len, -1));
        if (m == 0) break;
        var off: usize = 0;
        while (off < m) {
            var d: Dir = undefined;
            const sz = c.convM2D(dirbuf[off..].ptr, @intCast(m - off), &d, &strs[n]);
            try testing.expect(sz != 0);
            names[n] = std.mem.sliceTo(d.name, 0);
            n += 1;
            off += sz;
        }
    }
    std.mem.sort([]const u8, names[0..n], {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    var w: std.Io.Writer = .fixed(buf);
    for (names[0..n], 0..) |nm, i| {
        if (i > 0) try w.writeByte(' ');
        try w.writeAll(nm);
    }
    return w.buffered();
}

/// The name a stat of name gives.
fn statname(name: [*:0]const u8, strs: []u8) ![]const u8 {
    var buf: [512]u8 = undefined;
    const n = try stat(name, &buf, buf.len);
    var d: Dir = undefined;
    try testing.expect(c.convM2D(&buf, @intCast(n), &d, strs.ptr) != 0);
    return std.mem.sliceTo(d.name, 0);
}

test "bind replaces and unions, and unmount undoes it, as 9front's namespace does [kernel-port]" {
    _ = try kt.namespace();
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("factotum", try listdir("/mnt", &buf));

    // Replace: the pipe device's files, under /mnt.
    _ = try bind("#|", "/mnt", c.MREPL);
    try testing.expectEqualStrings("data data1", try listdir("/mnt", &buf));
    _ = try unmount(null, "/mnt");
    try testing.expectEqualStrings("factotum", try listdir("/mnt", &buf));

    // A union, after and before: a read of it lists both, and a walk
    // finds a name in either.
    _ = try bind("#|", "/mnt", c.MAFTER);
    try testing.expectEqualStrings("data data1 factotum", try listdir("/mnt", &buf));
    var strs: [256]u8 = undefined;
    try testing.expectEqualStrings("data", try statname("/mnt/data", &strs));
    try testing.expectEqualStrings("factotum", try statname("/mnt/factotum", &strs));
    // Each attach of #| is a new pipe, so unmounting another one is
    // an error, and unmounting the lot leaves /mnt as it was.
    try testing.expectError(error.Kernel, unmount("#|", "/mnt"));
    try testing.expectEqualStrings(std.mem.span(@as([*:0]const u8, &port.Eunion)), kt.errstr());
    _ = try unmount(null, "/mnt");
    try testing.expectEqualStrings("factotum", try listdir("/mnt", &buf));

    // A bind onto a file needs MREPL, and a directory onto a file fails.
    try testing.expectError(error.Kernel, bind("#|", "/mnt/factotum/x", c.MREPL));
    try testing.expectError(error.Kernel, unmount(null, "/boot"));
}

test "dot-dot crosses back over a mount point, and a path names where a walk went [kernel-port]" {
    const p = try kt.namespace();
    _ = try bind("#|", "/mnt/factotum", c.MREPL);
    _ = try chdir("/mnt/factotum");
    try testing.expectEqualStrings("/mnt/factotum", std.mem.span(chan.chanpath(p.dot)));
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("data data1", try listdir(".", &buf));
    // .. from the pipe device's root is /mnt, not the pipe's own root.
    try testing.expectEqualStrings("factotum", try listdir("..", &buf));
    _ = try chdir("../..");
    try testing.expectEqualStrings("/", std.mem.span(chan.chanpath(p.dot)));
    var strs: [256]u8 = undefined;
    try testing.expectEqualStrings("data1", try statname("mnt/factotum/data1", &strs));
}

test "namec's errors name how far the walk got [kernel-port]" {
    _ = try kt.namespace();
    try testing.expectError(error.Kernel, open("/mnt/nothere/x", c.OREAD));
    try testing.expect(std.mem.indexOf(u8, kt.errstr(), "/mnt/nothere") != null);
    try testing.expect(std.mem.indexOf(u8, kt.errstr(), "does not exist") != null);
    try testing.expectError(error.Kernel, open("#Z", c.OREAD));
    try testing.expectEqualStrings(std.mem.span(@as([*:0]const u8, &port.Ebadsharp)), kt.errstr());
    try testing.expectError(error.Kernel, open("", c.OREAD));
    try testing.expectError(error.Kernel, open("/mnt/bad\x01name", c.OREAD));
    try testing.expectError(error.Kernel, create("/mnt/factotum", c.OREAD, 0));
    // A device a namespace masks can't be attached.
    pgrp.devmask(up().pgrp, false, "|");
    try testing.expectError(error.Kernel, open("#|/data", c.ORDWR));
    try testing.expectEqualStrings(std.mem.span(@as([*:0]const u8, &port.Enoattach)), kt.errstr());
}

extern fn sysopen(name: [*:0]const u8, mode: c_int) c_int;
extern fn syspipe(fd: *[2]c_int) c_int;
extern fn sysclose(fd: c_int) c_int;

test "pipes, dup, close, and seek on fds, and a failed call's error is syserrstr [kernel-port]" {
    const p = try kt.namespace();
    var fds: [2]c_int = undefined;
    try testing.expectEqual(0, syspipe(&fds));
    try testing.expectEqual(5, try pwrite(fds[0], "hello", 5, -1));
    var buf: [16]u8 = undefined;
    try testing.expectEqual(5, try pread(fds[1], &buf, buf.len, -1));
    try testing.expectEqualStrings("hello", buf[0..5]);
    try testing.expectError(error.Kernel, seek(fds[0], 0, 0));
    try testing.expectEqualStrings(std.mem.span(@as([*:0]const u8, &port.Eisstream)), kt.errstr());

    const fd = try dup(fds[1], -1);
    try testing.expect(fd != fds[0] and fd != fds[1]);
    try testing.expectEqual(3, try pwrite(fds[0], "abc", 3, -1));
    try testing.expectEqual(3, try pread(fd, &buf, buf.len, -1));
    try testing.expectEqual(fds[0], try dup(fd, fds[0]));
    _ = try close(fd);
    try testing.expectError(error.Kernel, close(fd));
    try testing.expectEqualStrings(std.mem.span(@as([*:0]const u8, &port.Ebadfd)), kt.errstr());
    _ = try close(fds[0]);
    _ = try close(fds[1]);

    // From C: -1, the error in syserrstr, and the error stack as it was.
    try testing.expectEqual(-1, sysopen("/nothere", c.OREAD));
    try testing.expect(std.mem.indexOf(u8, std.mem.sliceTo(p.syserrstr, 0), "does not exist") != null);
    try testing.expectEqual(-1, sysclose(99));
    try testing.expectEqualStrings(std.mem.span(@as([*:0]const u8, &port.Ebadfd)), std.mem.sliceTo(p.syserrstr, 0));
    try testing.expectEqual(0, p.nerrlab);
}
