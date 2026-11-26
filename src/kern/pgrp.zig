//! drawterm's pgrp.c (design/kernel-port.md): process groups (the mount
//! table, Pgrp), rendezvous groups (Rgrp), file descriptor groups
//! (Fgrp), and mounts. A close translation: the same functions in the
//! same order, with error unions in place of error().

const std = @import("std");
const port = @import("port.zig");
const sync = @import("sync.zig");
const dev = @import("dev.zig");
const chan = @import("chan.zig");
const c = port.c;
const Error = port.Error;

const Pgrp = c.Pgrp;
const Rgrp = c.Rgrp;
const Fgrp = c.Fgrp;
const Mount = c.Mount;
const Mhead = c.Mhead;
const Chan = c.Chan;

pub fn newpgrp() Error!*Pgrp {
    const p: *Pgrp = @ptrCast(@alignCast(port.malloc(@sizeOf(Pgrp)) orelse return port.kerror(&port.Enomem)));
    p.ref.ref = 1;
    p.mntordertail = &p.mntorder;
    return p;
}

pub fn newrgrp() Error!*Rgrp {
    const r: *Rgrp = @ptrCast(@alignCast(port.malloc(@sizeOf(Rgrp)) orelse return port.kerror(&port.Enomem)));
    r.ref.ref = 1;
    return r;
}

pub fn closergrp(r: *Rgrp) void {
    if (chan.decref(&r.ref) == 0)
        c.free(r);
}

pub fn closepgrp(p: *Pgrp) void {
    if (chan.decref(&p.ref) != 0)
        return;

    for (&p.mnthash) |*h| {
        while (@as(?*Mhead, h.*)) |f| {
            h.* = f.hash;
            sync.wlock(&f.lock);
            const m = f.mount;
            f.mount = null;
            sync.wunlock(&f.lock);
            mountfree(m);
            chan.putmhead(f);
        }
    }
    c.free(p);
}

pub fn pgrpinsert(pg: *Pgrp, m: *Mount) void {
    m.order = null;
    pg.mntordertail.* = m;
    pg.mntordertail = &m.order;
}

pub fn pgrpremove(pg: *Pgrp, m: *Mount) void {
    var l: *[*c]Mount = &pg.mntorder;
    var f_: ?*Mount = pg.mntorder;
    while (f_) |f| : (f_ = f.order) {
        if (f == m) {
            l.* = f.order;
            if (l.* == null)
                pg.mntordertail = l;
            f.order = null;
            return;
        }
        l = &f.order;
    }
}

pub fn canmount(pgrp: *Pgrp) bool {
    // Devmnt is not usable directly from user procs, so having it
    // masked is interpreted to block any mounts.
    return !devmasked(pgrp, dev.devno('M'));
}

pub fn devmasked(pgrp: *Pgrp, i: c_int) bool {
    const u: c_uint = @bitCast(i);
    return (pgrp.devmask[u >> 3] & (@as(u8, 1) << @intCast(u & 7))) != 0;
}

pub fn devmask(pgrp: *Pgrp, invert_: bool, devs_: [*:0]const u8) void {
    var mask = std.mem.zeroes(@TypeOf(pgrp.devmask));
    const invert: u8 = if (invert_) 0xFF else 0;
    var devs = devs_;

    while (devs[0] != 0) {
        var r: c.Rune = undefined;
        devs += @intCast(c.chartorune(&r, @constCast(devs)));
        const i = dev.devno(@intCast(r));
        if (i < 0)
            continue;
        const u: c_uint = @intCast(i);
        mask[u >> 3] |= @as(u8, 1) << @intCast(u & 7);
    }

    sync.wlock(&pgrp.ns);
    for (&pgrp.devmask, mask) |*d, m|
        d.* |= m ^ invert;
    sync.wunlock(&pgrp.ns);
}

pub fn dupfgrp(f_: ?*Fgrp) Error!*Fgrp {
    const new: *Fgrp = @ptrCast(@alignCast(port.malloc(@sizeOf(Fgrp)) orelse return port.kerror(&port.Enomem)));
    new.ref.ref = 1;
    const f = f_ orelse {
        new.nfd = c.DELTAFD;
        new.fd = @ptrCast(@alignCast(port.malloc(c.DELTAFD * @sizeOf(?*Chan))));
        new.flag = @ptrCast(port.malloc(c.DELTAFD * @sizeOf(u8)));
        if (new.fd == null or new.flag == null) {
            c.free(new.flag);
            c.free(@ptrCast(new.fd));
            c.free(new);
            return port.kerror(&port.Enomem);
        }
        return new;
    };

    c.lock(&f.ref.lk);
    // Make new fd list shorter if possible, preserving quantization
    new.nfd = f.maxfd + 1;
    const i = @mod(new.nfd, c.DELTAFD);
    if (i != 0)
        new.nfd += c.DELTAFD - i;
    const nfd: usize = @intCast(new.nfd);
    new.fd = @ptrCast(@alignCast(port.malloc(@intCast(nfd * @sizeOf(?*Chan)))));
    new.flag = @ptrCast(port.malloc(@intCast(nfd * @sizeOf(u8))));
    if (new.fd == null or new.flag == null) {
        c.unlock(&f.ref.lk);
        c.free(new.flag);
        c.free(@ptrCast(new.fd));
        c.free(new);
        return port.kerror(&port.Enomem);
    }
    new.maxfd = f.maxfd;
    var j: usize = 0;
    while (j <= f.maxfd) : (j += 1) {
        if (@as(?*Chan, f.fd[j])) |ch| {
            new.fd[j] = ch;
            new.flag[j] = f.flag[j];
            _ = chan.incref(&ch.ref);
        }
    }
    c.unlock(&f.ref.lk);

    return new;
}

/// (drawterm's closefgrp leaves the chans to its caller: h9's proc.c
/// closes them.)
pub fn closefgrp(f_: ?*Fgrp) void {
    const f = f_ orelse return;
    if (chan.decref(&f.ref) != 0)
        return;

    c.free(f.flag);
    c.free(@ptrCast(f.fd));
    c.free(f);
}

pub fn newmount(to: *Chan, flag: c_int, spec_: ?[*:0]const u8) Error!*Mount {
    return newmountAt(to, flag, spec_, @returnAddress());
}

/// newmount, with the caller's pc for the malloc tag.
pub fn newmountAt(to: *Chan, flag: c_int, spec_: ?[*:0]const u8, pc: usize) Error!*Mount {
    const spec: [*:0]const u8 = spec_ orelse "";
    const len = std.mem.len(spec);
    const m: *Mount = @ptrCast(@alignCast(port.malloc(@intCast(@sizeOf(Mount) + len + 1)) orelse return port.kerror(&port.Enomem)));
    m.to = to;
    _ = chan.incref(&to.ref);
    m.mflag = flag;
    const dst: [*]u8 = @ptrCast(m.spec());
    @memcpy(dst[0 .. len + 1], spec[0 .. len + 1]);
    c.setmalloctag(m, pc);
    return m;
}

pub fn mountfree(m_: ?*Mount) void {
    var m = m_;
    while (m) |f| {
        m = f.next;
        chan.cclose(f.to);
        c.free(f);
    }
}

// The C kernel's names, with its semantics: a function that fails raises
// its error.

fn c_newpgrp() callconv(.c) *Pgrp {
    return newpgrp() catch |e| port.raise(e);
}
fn c_newrgrp() callconv(.c) *Rgrp {
    return newrgrp() catch |e| port.raise(e);
}
fn c_closergrp(r: *Rgrp) callconv(.c) void {
    closergrp(r);
}
fn c_closepgrp(p: *Pgrp) callconv(.c) void {
    closepgrp(p);
}
fn c_pgrpinsert(pg: *Pgrp, m: *Mount) callconv(.c) void {
    pgrpinsert(pg, m);
}
fn c_pgrpremove(pg: *Pgrp, m: *Mount) callconv(.c) void {
    pgrpremove(pg, m);
}
fn c_canmount(pg: *Pgrp) callconv(.c) c_int {
    return @intFromBool(canmount(pg));
}
fn c_devmasked(pg: *Pgrp, i: c_int) callconv(.c) c_int {
    return @intFromBool(devmasked(pg, i));
}
fn c_devmask(pg: *Pgrp, invert: c_int, devs: [*:0]const u8) callconv(.c) void {
    devmask(pg, invert != 0, devs);
}
fn c_dupfgrp(f: ?*Fgrp) callconv(.c) *Fgrp {
    return dupfgrp(f) catch |e| port.raise(e);
}
fn c_closefgrp(f: ?*Fgrp) callconv(.c) void {
    closefgrp(f);
}
fn c_newmount(to: *Chan, flag: c_int, spec: ?[*:0]const u8) callconv(.c) *Mount {
    return newmountAt(to, flag, spec, @returnAddress()) catch |e| port.raise(e);
}
fn c_mountfree(m: ?*Mount) callconv(.c) void {
    mountfree(m);
}

pub fn exportC() void {
    @export(&c_newpgrp, .{ .name = "newpgrp" });
    @export(&c_newrgrp, .{ .name = "newrgrp" });
    @export(&c_closergrp, .{ .name = "closergrp" });
    @export(&c_closepgrp, .{ .name = "closepgrp" });
    @export(&c_pgrpinsert, .{ .name = "pgrpinsert" });
    @export(&c_pgrpremove, .{ .name = "pgrpremove" });
    @export(&c_canmount, .{ .name = "canmount" });
    @export(&c_devmasked, .{ .name = "devmasked" });
    @export(&c_devmask, .{ .name = "devmask" });
    @export(&c_dupfgrp, .{ .name = "dupfgrp" });
    @export(&c_closefgrp, .{ .name = "closefgrp" });
    @export(&c_newmount, .{ .name = "newmount" });
    @export(&c_mountfree, .{ .name = "mountfree" });
}
