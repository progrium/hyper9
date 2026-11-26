//! drawterm's devmnt.c (design/kernel-port.md): the 9P client, `#M`. A
//! close translation: the same functions in the same order, with error
//! unions in place of waserror.
//!
//! References are managed as follows:
//! The channel to the server - a network connection or pipe - has one
//! reference for every Chan open on the server.  The server channel has
//! c->mux set to the Mnt used for muxing control to that server.  Mnts
//! have no reference count; they go away when c goes away.
//! Each channel derived from the mount point has mchan set to c,
//! and increfs/decrefs mchan to manage references on the server
//! connection.
//!
//! The device is native (dev.zig's `Native`): the switch calls these
//! functions directly, and `mntdevtab`, the C `Dev` devtab.c and nstab.c
//! name, holds wrappers that raise for C callers. A process waits for its
//! reply in sync.zig's sleep, which parks it.

const std = @import("std");
const port = @import("port.zig");
const sync = @import("sync.zig");
const qio = @import("qio.zig");
const dev = @import("dev.zig");
const chan = @import("chan.zig");
const sysfile = @import("sysfile.zig");
const c = port.c;
const up = port.up;
const Error = port.Error;

const Chan = c.Chan;
const Mnt = c.Mnt;
const Block = c.Block;
const Walkqid = c.Walkqid;
const Fcall = c.Fcall;
const Queue = qio.Queue;

const BIT8SZ: c_int = c.BIT8SZ;
const BIT16SZ: c_int = c.BIT16SZ;
const BIT32SZ: c_int = c.BIT32SZ;
const IOHDRSZ: c_int = c.IOHDRSZ;
const NOTAG: u16 = 0xFFFF;
const NOFID: u32 = 0xFFFFFFFF;

const MAXRPC = IOHDRSZ + 32768;
const MAXRPC0 = IOHDRSZ + 8192; // maximum size of Tversion/Rversion pair

pub const Mntrpc = extern struct {
    c: ?*Chan = null, // Channel for whom we are working
    list: ?*Mntrpc = null, // Free/pending list
    request: Fcall = .{}, // Outgoing file system protocol message
    reply: Fcall = .{}, // Incoming reply
    m: ?*Mnt = null, // Mount device during rpc
    z: ?*c.Rendez = null, // Place to hang out
    b: ?*Block = null, // reply blocks
    flushed: ?*Mntrpc = null, // message this one flushes
    done: u8 = 0, // Rpc completed
};

const TAGSHIFT = 5;
const TAGMASK = (1 << TAGSHIFT) - 1;
const NMASK = (64 * 1024) >> TAGSHIFT;

const Mntalloc = struct {
    lk: c.Lock = std.mem.zeroes(c.Lock),
    list: ?*Mnt = null, // Mount devices in use
    mntfree: ?*Mnt = null, // Free list
    rpcfree: ?*Mntrpc = null,
    nrpcfree: c_uint = 0,
    nrpcused: c_uint = 0,
    id: c_uint = 0,
    tagmask: [NMASK]u32 = @splat(0),
};
var mntalloc: Mntalloc = .{};

const Esbadstat = "invalid directory entry received from server";
const Enoversion = "version not established for mount channel";

/// m->queue, which port.h declares as an incomplete Mntrpc.
fn queueOf(m: *Mnt) *?*Mntrpc {
    return @ptrCast(&m.queue);
}

/// m->q.
fn mq(m: *Mnt) *Queue {
    return @ptrCast(@alignCast(m.q.?));
}

fn gbit16(p: [*]const u8) u16 {
    return std.mem.readInt(u16, p[0..2], .little);
}
fn gbit32(p: [*]const u8) u32 {
    return std.mem.readInt(u32, p[0..4], .little);
}
fn pbit16(p: [*]u8, v: u16) void {
    std.mem.writeInt(u16, p[0..2], v, .little);
}
fn pbit32(p: [*]u8, v: u32) void {
    std.mem.writeInt(u32, p[0..4], v, .little);
}

fn blen(b: *const Block) c_int {
    return @intCast(@intFromPtr(b.wp) - @intFromPtr(b.rp));
}

fn mntreset() void {
    mntalloc.id = 1;
    mntalloc.tagmask[0] = 1; // don't allow 0 as a tag
    mntalloc.tagmask[NMASK - 1] = 0x80000000; // don't allow NOTAG
    _ = c.fmtinstall('F', c.fcallfmt);
    _ = c.fmtinstall('D', c.dirfmt);
    // We can't install %M since eipfmt does and is used in the kernel [sape]
}

/// Version is not multiplexed: message sent only once per connection.
pub fn mntversion(ch: *Chan, version: ?[*]u8, msize_: c_int, returnlen: c_int) Error!c_int {
    sync.qlock(&ch.umqlock); // make sure no one else does this until we've established ourselves
    var locked = true;
    defer if (locked) sync.qunlock(&ch.umqlock);

    // defaults
    var msize = msize_;
    if (msize == 0)
        msize = MAXRPC;
    if (msize > ch.iounit and ch.iounit != 0)
        msize = @intCast(ch.iounit);
    var v: [*:0]const u8 = c.VERSION9P;
    if (version) |ver| {
        if (ver[0] != 0)
            v = @ptrCast(ver);
    }

    // validity
    if (msize < 0)
        return port.kerror("bad iounit in version call");
    if (!std.mem.startsWith(u8, std.mem.span(v), c.VERSION9P))
        return port.kerror("bad 9P version specification");

    if (@as(?*Mnt, ch.mux)) |m| {
        sync.qunlock(&ch.umqlock);
        locked = false;

        var buf: [128:0]u8 = undefined;
        _ = c.strecpy(&buf, @as([*]u8, &buf) + buf.len, m.version);
        const k = std.mem.len(@as([*:0]u8, &buf));
        if (!std.mem.startsWith(u8, std.mem.span(v), buf[0..k])) {
            _ = c.snprint(&buf, buf.len, @constCast("incompatible 9P versions %s %s"), m.version, v);
            return port.kerror(&buf);
        }
        if (returnlen > 0) {
            if (returnlen < k)
                return port.kerror(&port.Eshort);
            @memcpy(version.?[0..k], buf[0..k]);
        }
        return @intCast(k);
    }

    var f: Fcall = .{};
    f.type = c.Tversion;
    f.tag = NOTAG;
    f.msize = @intCast(msize);
    f.version = @constCast(v);
    const msg: [*]u8 = @ptrCast(port.malloc(MAXRPC0) orelse {
        c.exhausted(@constCast("version memory"));
        unreachable;
    });
    defer c.free(msg);
    var k: c_int = @intCast(c.convS2M(&f, msg, MAXRPC0));
    if (k == 0)
        return port.kerror("bad fversion conversion on send");

    c.lock(&ch.ref.lk);
    const oo = ch.offset;
    ch.offset += k;
    c.unlock(&ch.ref.lk);

    var l = try dev.write(dev.of(ch), ch, msg, k, oo);
    if (l < k) {
        c.lock(&ch.ref.lk);
        ch.offset -= k - l;
        c.unlock(&ch.ref.lk);
        return port.kerror("short write in fversion");
    }

    // message sent; receive and decode reply
    k = 0;
    while (k < BIT32SZ or (k < gbit32(msg) and k < MAXRPC0)) : (k += l) {
        l = try dev.read(dev.of(ch), ch, msg + @as(usize, @intCast(k)), MAXRPC0 - k, ch.offset);
        if (l <= 0)
            return port.kerror("EOF receiving fversion reply");
        c.lock(&ch.ref.lk);
        ch.offset += l;
        c.unlock(&ch.ref.lk);
    }

    l = @intCast(c.convM2S(msg, @intCast(k), &f));
    if (l != k)
        return port.kerror("bad fversion conversion on reply");
    if (f.type != c.Rversion) {
        if (f.type == c.Rerror)
            return port.kerror(f.ename);
        return port.kerror("unexpected reply type in fversion");
    }
    if (f.msize > msize)
        return port.kerror("server tries to increase msize in fversion");
    if (f.msize < 256 or f.msize > 1024 * 1024)
        return port.kerror("nonsense value of msize in fversion");
    const fv: [*:0]const u8 = f.version;
    const kv = std.mem.len(fv);
    if (!std.mem.startsWith(u8, std.mem.span(v), fv[0..kv]))
        return port.kerror("bad 9P version returned from server");
    if (returnlen > 0 and returnlen < kv)
        return port.kerror(&port.Eshort);

    var nv: ?[*:0]u8 = null;
    chan.kstrdup(&nv, fv);
    const q = qio.qopen(10 * MAXRPC, 0, null, null) orelse {
        c.free(nv);
        c.exhausted(@constCast("mount queues"));
        unreachable;
    };

    // now build Mnt associated with this connection
    c.lock(&mntalloc.lk);
    var m: *Mnt = undefined;
    if (mntalloc.mntfree) |fm| {
        m = fm;
        mntalloc.mntfree = fm.list;
    } else {
        c.unlock(&mntalloc.lk);
        m = @ptrCast(@alignCast(port.malloc(@sizeOf(Mnt)) orelse {
            qio.qfree(q);
            c.free(nv);
            c.exhausted(@constCast("mount devices"));
            unreachable;
        }));
        c.lock(&mntalloc.lk);
    }
    m.list = mntalloc.list;
    mntalloc.list = m;
    m.version = nv;
    m.id = mntalloc.id;
    mntalloc.id += 1;
    m.q = @ptrCast(q);
    m.msize = @intCast(f.msize);
    c.unlock(&mntalloc.lk);

    if (returnlen > 0)
        @memcpy(version.?[0..kv], fv[0..kv]); // length was checked above

    c.lock(&m.lk);
    queueOf(m).* = null;
    m.rip = null;

    ch.flag |= c.CMSG;
    ch.mux = m;
    m.c = ch;
    c.unlock(&m.lk);

    return @intCast(kv);
}

pub fn mntauth(ch_: *Chan, spec: [*:0]const u8) Error!*Chan {
    var m: ?*Mnt = ch_.mux;
    if (m == null) {
        _ = try mntversion(ch_, null, 0, 0);
        m = ch_.mux;
        if (m == null)
            return port.kerror(Enoversion);
    }

    const ch = mntchan();
    // Close must not be called since it will call mnt recursively
    errdefer chan.chanfree(ch);

    const r = mntralloc(ch);
    defer mntfree(r);

    r.request.type = c.Tauth;
    r.request.afid = @bitCast(ch.fid);
    r.request.uname = &up().user;
    r.request.aname = @constCast(spec);
    try mountrpc(m.?, r);

    ch.qid = r.reply.aqid;
    ch.mchan = m.?.c;
    _ = chan.incref(&m.?.c.*.ref);
    ch.mqid = ch.qid;
    ch.mode = c.ORDWR;
    ch.iounit = @intCast(m.?.msize - IOHDRSZ);

    return ch;
}

pub fn mntattach(ch_: *Chan, ac: ?*Chan, spec: [*:0]const u8, flags: c_int) Error!*Chan {
    if (ac != null and ac.?.mchan != ch_)
        return port.kerror(&port.Ebadusefd);

    var m: ?*Mnt = ch_.mux;
    if (m == null) {
        _ = try mntversion(ch_, null, 0, 0);
        m = ch_.mux;
        if (m == null)
            return port.kerror(Enoversion);
    }

    const ch = mntchan();
    // Close must not be called since it will call mnt recursively
    errdefer chan.chanfree(ch);

    {
        const r = mntralloc(ch);
        defer mntfree(r);
        r.request.type = c.Tattach;
        r.request.fid = @bitCast(ch.fid);
        if (ac) |a|
            r.request.afid = @bitCast(a.fid)
        else
            r.request.afid = NOFID;
        r.request.uname = &up().user;
        r.request.aname = @constCast(spec);
        try mountrpc(m.?, r);

        ch.qid = r.reply.qid;
        ch.mchan = m.?.c;
        _ = chan.incref(&m.?.c.*.ref);
        ch.mqid = ch.qid;
    }

    if (flags & c.MCACHE != 0)
        ch.flag |= c.CCACHE;
    return ch;
}

fn noattach(_: [*:0]const u8) Error!*Chan {
    return port.kerror(&port.Enoattach);
}

fn mntchan() *Chan {
    const ch = dev.devattach('M', null);
    c.lock(&mntalloc.lk);
    ch.dev = mntalloc.id;
    mntalloc.id += 1;
    c.unlock(&mntalloc.lk);

    if (ch.mchan != null)
        port.kpanic("mntchan non-zero %p", .{ch.mchan});
    return ch;
}

/// A walk that fails after its first check is nil, with the error
/// string set, as devmnt.c's waserror returns.
fn mntwalk(ch: *Chan, nc_: ?*Chan, name: [*]const [*:0]const u8, nname: c_int) Error!?*Walkqid {
    if (nc_ != null)
        port.print("mntwalk: nc != nil\n", .{});
    if (nname > c.MAXWELEM)
        return port.kerror("devmnt: too many name elements");
    const wq = dev.walkqid(@intCast(nname));
    var alloc = false;
    return mntwalk1(ch, nc_, name, nname, wq, &alloc) catch {
        if (alloc and wq.libclone != null)
            chan.cclose(wq.libclone);
        c.free(wq);
        return null;
    };
}

fn mntwalk1(ch: *Chan, nc_: ?*Chan, name: [*]const [*:0]const u8, nname: c_int, wq_: *Walkqid, alloc: *bool) Error!?*Walkqid {
    var wq: ?*Walkqid = wq_;
    alloc.* = false;
    const m = mntchk(ch);
    const r = mntralloc(ch);
    var nc = nc_;
    if (nc == null) {
        const n = dev.devclone(ch);
        // Until the other side accepts this fid, we can't mntclose it.
        // Therefore set type to 0 for now; rootclose is known to be safe.
        n.type = 0;
        n.flag |= ch.flag & @as(u16, c.CCACHE);
        alloc.* = true;
        nc = n;
    }
    wq_.libclone = nc;

    defer mntfree(r);
    r.request.type = c.Twalk;
    r.request.fid = @bitCast(ch.fid);
    r.request.newfid = @bitCast(nc.?.fid);
    r.request.nwname = @intCast(nname);
    for (0..@intCast(nname)) |i|
        r.request.wname[i] = @constCast(name[i]);

    try mountrpc(m, r);

    if (r.reply.nwqid > nname)
        return port.kerror("too many QIDs returned by walk");
    if (r.reply.nwqid < nname) {
        if (alloc.*)
            chan.cclose(nc);
        wq_.libclone = null;
        if (r.reply.nwqid == 0) {
            c.free(wq_);
            wq = null;
            return wq;
        }
    }

    // move new fid onto mnt device and update its qid
    if (@as(?*Chan, wq_.libclone)) |cl| {
        if (cl != ch) {
            cl.type = ch.type;
            cl.mchan = ch.mchan;
            _ = chan.incref(&ch.mchan.*.ref);
        }
        if (r.reply.nwqid > 0)
            cl.qid = r.reply.wqid[r.reply.nwqid - 1];
    }
    wq_.nqid = r.reply.nwqid;
    const qids = dev.qids(wq_);
    for (0..r.reply.nwqid) |i|
        qids[i] = r.reply.wqid[i];

    return wq;
}

fn mntstat(ch: *Chan, dp: [*]u8, n_: c_int) Error!c_int {
    var n = n_;
    if (n < BIT16SZ)
        return port.kerror(&port.Eshortstat);
    const m = mntchk(ch);
    const r = mntralloc(ch);
    defer mntfree(r);
    r.request.type = c.Tstat;
    r.request.fid = @bitCast(ch.fid);
    try mountrpc(m, r);

    if (r.reply.nstat > n) {
        n = BIT16SZ;
        pbit16(dp, r.reply.nstat -% 2);
    } else {
        n = r.reply.nstat;
        @memcpy(dp[0..@intCast(n)], r.reply.stat[0..@intCast(n)]);
        try sysfile.validstat(dp, n);
        mntdirfix(dp, ch);
    }
    return n;
}

fn mntopencreate(@"type": c_int, ch: *Chan, name: ?[*:0]const u8, omode: c_int, perm: c_uint) Error!*Chan {
    const m = mntchk(ch);
    const r = mntralloc(ch);
    defer mntfree(r);
    r.request.type = @intCast(@"type");
    r.request.fid = @bitCast(ch.fid);
    r.request.mode = @truncate(@as(c_uint, @bitCast(omode)));
    if (@"type" == c.Tcreate) {
        r.request.perm = perm;
        r.request.name = @constCast(name);
    }
    try mountrpc(m, r);

    ch.qid = r.reply.qid;
    ch.offset = 0;
    ch.mode = @intCast(try sysfile.openmode(@bitCast(omode)));
    ch.iounit = r.reply.iounit;
    if (ch.iounit == 0 or ch.iounit > m.msize - IOHDRSZ)
        ch.iounit = @intCast(m.msize - IOHDRSZ);
    ch.flag |= c.COPEN;

    return ch;
}

fn mntopen(ch: *Chan, omode: c_int) Error!*Chan {
    return mntopencreate(c.Topen, ch, null, omode, 0);
}

fn mntcreate(ch: *Chan, name: [*:0]const u8, omode: c_int, perm: c_uint) Error!*Chan {
    return mntopencreate(c.Tcreate, ch, name, omode, perm);
}

fn mntclunk(ch: *Chan, t: c_int) Error!void {
    const m = mntchk(ch);
    const r = mntralloc(ch);
    defer mntfree(r);
    r.request.type = @intCast(t);
    r.request.fid = @bitCast(ch.fid);
    try mountrpc(m, r);
}

pub fn muxclose(m: *Mnt) void {
    while (queueOf(m).*) |r| {
        queueOf(m).* = r.list;
        mntfree(r);
    }
    m.id = 0;
    c.free(m.version);
    m.version = null;
    qio.qfree(mq(m));
    m.q = null;

    c.lock(&mntalloc.lk);
    var l: *?*Mnt = &mntalloc.list;
    var f_ = l.*;
    while (f_) |f| : (f_ = f.list) {
        if (f == m) {
            l.* = m.list;
            break;
        }
        l = @ptrCast(&f.list);
    }
    m.list = mntalloc.mntfree;
    mntalloc.mntfree = m;
    c.unlock(&mntalloc.lk);
}

fn mntclose(ch: *Chan) Error!void {
    return mntclunk(ch, c.Tclunk);
}

fn mntremove(ch: *Chan) Error!void {
    return mntclunk(ch, c.Tremove);
}

fn mntwstat(ch: *Chan, dp: [*]u8, n: c_int) Error!c_int {
    const m = mntchk(ch);
    const r = mntralloc(ch);
    defer mntfree(r);
    r.request.type = c.Twstat;
    r.request.fid = @bitCast(ch.fid);
    r.request.nstat = @intCast(n);
    r.request.stat = dp;
    try mountrpc(m, r);
    return n;
}

fn mntread(ch: *Chan, buf: ?*anyopaque, n_: c_int, off: i64) Error!c_int {
    const p: [*]u8 = @ptrCast(buf.?);
    const n = try mntrdwr(c.Tread, ch, p, n_, off);
    if (ch.qid.type & c.QTDIR != 0)
        try mntdirsfix(p[0..@intCast(n)], ch);
    return n;
}

/// mntread's check of a directory read from the server: each entry
/// whole and valid, and given the local type and dev.
pub fn mntdirsfix(buf: []u8, ch: *Chan) Error!void {
    var p: usize = 0;
    const e = buf.len;
    while (p + BIT16SZ < e) {
        const dirlen: usize = @as(usize, BIT16SZ) + gbit16(buf[p..].ptr);
        if (p + dirlen > e)
            break;
        try sysfile.validstat(buf[p..].ptr, @intCast(dirlen));
        mntdirfix(buf[p..].ptr, ch);
        p += dirlen;
    }
    if (p != e)
        return port.kerror(Esbadstat);
}

fn mntwrite(ch: *Chan, buf: ?*const anyopaque, n: c_int, off: i64) Error!c_int {
    return mntrdwr(c.Twrite, ch, @ptrCast(@constCast(buf.?)), n, off);
}

fn mntrdwr(@"type": c_int, ch: *Chan, buf: [*]u8, n_: c_int, off_: i64) Error!c_int {
    const m = mntchk(ch);
    var uba = buf;
    var cnt: c_uint = 0;
    var n: c_uint = @bitCast(n_);
    var off = off_;

    while (true) {
        var nreq = n;
        if (nreq > ch.iounit)
            nreq = ch.iounit;

        var nr: c_uint = undefined;
        {
            const r = mntralloc(ch);
            defer mntfree(r);
            r.request.type = @intCast(@"type");
            r.request.fid = @bitCast(ch.fid);
            r.request.offset = off;
            r.request.data = uba;
            r.request.count = nreq;
            try mountrpc(m, r);
            nr = r.reply.count;
            if (nr > nreq)
                nr = nreq;
            if (@"type" == c.Tread)
                nr = @bitCast(qio.readblist(r.b, uba, @bitCast(nr), 0));
        }

        off += nr;
        uba += nr;
        cnt += nr;
        n -= nr;
        if (nr != nreq or n == 0)
            break;
    }
    return @bitCast(cnt);
}

fn mountrpc(m: *Mnt, r: *Mntrpc) Error!void {
    r.reply.tag = 0;
    r.reply.type = c.Tmax; // can't ever be a valid message type

    try mountio(m, r);

    const t = r.reply.type;
    switch (t) {
        c.Rerror => return port.kerror(r.reply.ename),
        c.Rflush => return port.interrupted(),
        else => {
            if (t == r.request.type + 1)
                return;
            port.print("mnt: proc %s %lud: mismatch from %s %s rep %#p tag %d fid %d T%d R%d rp %d\n", .{
                @as([*]u8, &up().text),              up().pid,
                chan.chanpath(m.c),                  chan.chanpath(r.c),
                r,                                   @as(c_int, r.request.tag),
                @as(c_int, @bitCast(r.request.fid)), @as(c_int, r.request.type),
                @as(c_int, r.reply.type),            @as(c_int, r.reply.tag),
            });
            return port.kerror(&port.Emountrpc);
        },
    }
}

/// devmnt.c's mountio: mountio1, again with a flush for each time a note
/// interrupts it.
fn mountio(m: *Mnt, r_: *Mntrpc) Error!void {
    var r = r_;
    while (true) {
        mountio1(m, r) catch |e| {
            if (m.rip == up())
                mntgate(m);
            if (!dev.streq(up().errstr, &port.Eintr)) {
                r = mntflushfree(m, r);
                switch (r.request.type) {
                    c.Tremove, c.Tclunk => {
                        // botch, abandon fid
                        if (!dev.streq(up().errstr, &port.Ehungup))
                            r.c.?.fid = 0;
                    },
                    else => {},
                }
                return e;
            }
            r = mntflushalloc(r);
            continue;
        };
        return;
    }
}

fn mountio1(m: *Mnt, r: *Mntrpc) Error!void {
    c.lock(&m.lk);
    r.z = &up().ksleep;
    r.m = m;
    r.list = queueOf(m).*;
    queueOf(m).* = r;
    c.unlock(&m.lk);

    // Transmit a file system rpc
    var n: c_int = @intCast(c.sizeS2M(&r.request));
    const b = qio.allocb(n);
    n = @intCast(c.convS2M(&r.request, b.wp, @intCast(n)));
    if (n <= 0 or n > m.msize) {
        port.print("mountio: proc %s %lud: convS2M returned %d for tag %d fid %d T%d\n", .{
            @as([*]u8, &up().text),              up().pid,                   n, @as(c_int, r.request.tag),
            @as(c_int, @bitCast(r.request.fid)), @as(c_int, r.request.type),
        });
        qio.freeb(b);
        return port.kerror(&port.Emountrpc);
    }
    b.wp += @intCast(n);
    _ = try dev.bwrite(dev.of(m.c), m.c, b, 0);

    // Gate readers onto the mount point one at a time
    while (true) {
        c.lock(&m.lk);
        if (m.rip == null)
            break;
        c.unlock(&m.lk);
        try sync.sleep(r.z.?, rpcattn, r);
        if (r.done != 0) {
            _ = mntflushfree(m, r);
            return;
        }
    }
    m.rip = up();
    c.unlock(&m.lk);
    while (r.done == 0) {
        if (try mntrpcread(m, r) < 0)
            return port.kerror(&port.Emountrpc);
        mountmux(m, r);
    }
    mntgate(m);
    _ = mntflushfree(m, r);
}

fn doread(m: *Mnt, len: c_int) Error!c_int {
    while (qio.qlen(mq(m)) < len) {
        const b = try dev.bread(dev.of(m.c), m.c, m.msize, 0) orelse return -1;
        if (qio.qaddlist(mq(m), b) == 0)
            return -1;
    }
    return 0;
}

/// Reads one reply from the server into r.reply, with its data in r.b:
/// -1 for a reply that's short or malformed.
pub fn mntrpcread(m: *Mnt, r: *Mntrpc) Error!c_int {
    const q = mq(m);
    r.reply.type = 0;
    r.reply.tag = 0;

    // read at least length, type, and tag and pullup to a single block
    if (try doread(m, BIT32SZ + BIT8SZ + BIT16SZ) < 0)
        return -1;
    var nb = qio.pullupqueue(q, BIT32SZ + BIT8SZ + BIT16SZ).?;

    // read in the rest of the message, avoid ridiculous (for now) message sizes
    var len: c_int = @bitCast(gbit32(nb.rp));
    if (len < BIT32SZ + BIT8SZ + BIT16SZ or len > m.msize) {
        qio.qflush(q);
        return -1;
    }
    if (try doread(m, len) < 0)
        return -1;

    // pullup the header (i.e. everything except data)
    const t = nb.rp[@intCast(BIT32SZ)];
    var hlen: c_int = switch (t) {
        c.Rread => BIT32SZ + BIT8SZ + BIT16SZ + BIT32SZ,
        else => len,
    };
    // (A Rread shorter than its header would pull up past the message,
    // and past what's queued, which drawterm's doesn't check.)
    if (hlen > len)
        hlen = len;
    nb = qio.pullupqueue(q, hlen).?;

    if (c.convM2S(nb.rp, @intCast(len), &r.reply) <= 0) {
        // bad message, dump it
        port.print("mntrpcread: convM2S failed\n", .{});
        _ = qio.qdiscard(q, len);
        return -1;
    }

    // hang the data off of the fcall struct
    var l: *?*Block = &r.b;
    l.* = null;
    while (true) {
        const b = qio.qremove(q).?;
        if (hlen > 0) {
            b.rp += @intCast(hlen);
            len -= hlen;
            hlen = 0;
        }
        const i = blen(b);
        if (i <= len) {
            len -= i;
            l.* = b;
            l = @ptrCast(&b.next);
        } else {
            // split block and put unused bit back
            const nb2 = qio.allocb(i - len);
            const ul: usize = @intCast(len);
            const rest: usize = @intCast(i - len);
            @memcpy(nb2.wp[0..rest], b.rp[ul..][0..rest]);
            b.wp = b.rp + ul;
            nb2.wp += rest;
            qio.qputback(q, nb2);
            l.* = b;
            return 0;
        }
        if (len <= 0)
            break;
    }

    return 0;
}

fn mntgate(m: *Mnt) void {
    c.lock(&m.lk);
    m.rip = null;
    var q_ = queueOf(m).*;
    while (q_) |q| : (q_ = q.list) {
        if (q.done == 0)
            if (sync.wakeup(q.z.?) != null)
                break;
    }
    c.unlock(&m.lk);
}

fn mountmux(m: *Mnt, r: *Mntrpc) void {
    c.lock(&m.lk);
    var l: *?*Mntrpc = queueOf(m);
    var q_ = l.*;
    while (q_) |q| : (q_ = q.list) {
        // look for a reply to a message
        if (q.request.tag == r.reply.tag) {
            l.* = q.list;
            if (q == r) {
                q.done = 1;
                c.unlock(&m.lk);
                return;
            }
            // Completed someone else.
            // Trade pointers to receive buffer.
            q.reply = r.reply;
            q.b = r.b;
            r.b = null;
            const z = q.z.?;
            q.done = 1;
            _ = sync.wakeup(z);
            c.unlock(&m.lk);
            return;
        }
        l = &q.list;
    }
    c.unlock(&m.lk);
    port.print("unexpected reply tag %ud; type %d\n", .{ @as(c_uint, r.reply.tag), @as(c_int, r.reply.type) });
}

/// Create a new flush request and chain the previous
/// requests from it
fn mntflushalloc(r: *Mntrpc) *Mntrpc {
    const fr = mntralloc(r.c.?);
    fr.request.type = c.Tflush;
    if (r.request.type == c.Tflush)
        fr.request.oldtag = r.request.oldtag
    else
        fr.request.oldtag = r.request.tag;
    fr.flushed = r;

    return fr;
}

///  Free a chain of flushes.  Remove each unanswered
///  flush and the original message from the unanswered
///  request queue.  Mark the original message as done
///  and if it hasn't been answered set the reply to to
///  Rflush. Return the original rpc.
fn mntflushfree(m: *Mnt, r_: *Mntrpc) *Mntrpc {
    var r = r_;
    while (true) {
        const fr = r.flushed;
        if (r.done == 0) {
            r.reply.type = c.Rflush;
            mntqrm(m, r);
        }
        const f = fr orelse break;
        mntfree(r);
        r = f;
    }
    return r;
}

fn alloctag() u16 {
    for (&mntalloc.tagmask, 0..) |*t, i| {
        var v = t.*;
        if (v == 0xFFFFFFFF)
            continue;
        var j: u5 = 0;
        while ((v & 1) != 0) : (j += 1)
            v >>= 1;
        t.* |= @as(u32, 1) << j;
        return @intCast(i << TAGSHIFT | j);
    }
    port.kpanic("no friggin tags left", .{});
}

fn freetag(t: u16) void {
    mntalloc.tagmask[t >> TAGSHIFT] &= ~(@as(u32, 1) << @intCast(t & TAGMASK));
}

fn mntralloc(ch: *Chan) *Mntrpc {
    var new: *Mntrpc = undefined;
    c.lock(&mntalloc.lk);
    if (mntalloc.rpcfree) |f| {
        new = f;
        mntalloc.rpcfree = f.list;
        mntalloc.nrpcfree -= 1;
    } else {
        c.unlock(&mntalloc.lk);
        new = @ptrCast(@alignCast(port.malloc(@sizeOf(Mntrpc)) orelse {
            c.exhausted(@constCast("mount rpc header"));
            unreachable;
        }));
        c.lock(&mntalloc.lk);
        new.request.tag = alloctag();
    }
    mntalloc.nrpcused += 1;
    c.unlock(&mntalloc.lk);
    new.c = ch;
    new.done = 0;
    new.flushed = null;
    new.b = null;
    return new;
}

fn mntfree(r: *Mntrpc) void {
    qio.freeblist(r.b);
    c.lock(&mntalloc.lk);
    mntalloc.nrpcused -= 1;
    if (mntalloc.nrpcfree < 32) {
        r.list = mntalloc.rpcfree;
        mntalloc.rpcfree = r;
        mntalloc.nrpcfree += 1;
        c.unlock(&mntalloc.lk);
        return;
    }
    freetag(r.request.tag);
    c.unlock(&mntalloc.lk);
    c.free(r);
}

fn mntqrm(m: *Mnt, r: *Mntrpc) void {
    c.lock(&m.lk);
    r.done = 1;

    var l: *?*Mntrpc = queueOf(m);
    var f_ = l.*;
    while (f_) |f| : (f_ = f.list) {
        if (f == r) {
            l.* = r.list;
            break;
        }
        l = &f.list;
    }
    c.unlock(&m.lk);
}

fn mntchk(ch: *Chan) *Mnt {
    // This routine is mostly vestiges of prior lives; now it's just sanity checking
    const mc: *Chan = ch.mchan orelse port.kpanic("mntchk 1: nil mchan c %s", .{chan.chanpath(ch)});

    const m: ?*Mnt = mc.mux;
    if (m == null)
        port.print("mntchk 2: nil mux c %s c->mchan %s \n", .{ chan.chanpath(ch), chan.chanpath(mc) });

    // Was it closed and reused (was error(Eshutdown); now, it cannot happen)
    if (m.?.id == 0 or m.?.id >= ch.dev)
        port.kpanic("mntchk 3: can't happen", .{});

    return m.?;
}

/// Rewrite channel type and dev for in-flight data to
/// reflect local values.  These entries are known to be
/// the first two in the Dir encoding after the count.
fn mntdirfix(dirbuf: [*]u8, ch: *Chan) void {
    const r: u16 = @truncate(@as(c_uint, @bitCast(dev.of(ch).dc)));
    pbit16(dirbuf + @as(usize, BIT16SZ), r); // skip count
    pbit32(dirbuf + @as(usize, 2 * BIT16SZ), ch.dev);
}

fn rpcattn(v: ?*anyopaque) callconv(.c) c_int {
    const r: *Mntrpc = @ptrCast(@alignCast(v.?));
    return @intFromBool(r.done != 0 or r.m.?.rip == null);
}

pub const Device = dev.Native('M', "mnt", .{
    .reset = mntreset,
    .attach = noattach,
    .walk = mntwalk,
    .stat = mntstat,
    .open = mntopen,
    .create = mntcreate,
    .close = mntclose,
    .read = mntread,
    .write = mntwrite,
    .remove = mntremove,
    .wstat = mntwstat,
});

// The C kernel's names, with its semantics: a function that fails raises
// its error.

fn c_mntversion(ch: *Chan, version: ?[*]u8, msize: c_int, returnlen: c_int) callconv(.c) c_int {
    return mntversion(ch, version, msize, returnlen) catch |e| port.raise(e);
}
fn c_mntauth(ch: *Chan, spec: [*:0]const u8) callconv(.c) *Chan {
    return mntauth(ch, spec) catch |e| port.raise(e);
}
fn c_mntattach(ch: *Chan, ac: ?*Chan, spec: [*:0]const u8, flags: c_int) callconv(.c) *Chan {
    return mntattach(ch, ac, spec, flags) catch |e| port.raise(e);
}
fn c_muxclose(m: *Mnt) callconv(.c) void {
    muxclose(m);
}

pub fn exportC() void {
    @export(&Device.dev, .{ .name = "mntdevtab" });
    @export(&c_mntversion, .{ .name = "mntversion" });
    @export(&c_mntauth, .{ .name = "mntauth" });
    @export(&c_mntattach, .{ .name = "mntattach" });
    @export(&c_muxclose, .{ .name = "muxclose" });
}

const testing = std.testing;
const kt = port.testing;

/// A Mnt whose server is the read end of a pipe holding bytes, which
/// hangs up after them.
const Canned = struct {
    m: Mnt = .{},
    rd: *Chan = undefined,

    fn init(t: *Canned, bytes: []const u8) !void {
        var fds: [2]c_int = undefined;
        _ = try sysfile.pipe(&fds);
        if (bytes.len > 0)
            _ = try sysfile.pwrite(fds[1], bytes.ptr, @intCast(bytes.len), -1);
        _ = try sysfile.close(fds[1]);
        t.rd = try sysfile.fdtochan(fds[0], -1, false, true);
        _ = try sysfile.close(fds[0]);
        t.m = .{};
        t.m.c = t.rd;
        t.m.msize = 8192 + IOHDRSZ;
        t.m.q = @ptrCast(qio.qopen(10 * MAXRPC, 0, null, null).?);
    }

    fn deinit(t: *Canned) void {
        qio.qfree(mq(&t.m));
        chan.cclose(t.rd);
    }
};

fn chainlen(b_: ?*Block) usize {
    var n: usize = 0;
    var b = b_;
    while (b) |bb| : (b = bb.next) n += @intCast(blen(bb));
    return n;
}

test "fuzz: devmnt's reply parser takes any bytes from a server [kernel-port]" {
    _ = try kt.namespace();
    try testing.fuzz({}, struct {
        fn one(_: void, smith: *testing.Smith) anyerror!void {
            var buf: [600]u8 = undefined;
            const n = smith.slice(&buf);
            var t: Canned = .{};
            try t.init(buf[0..n]);
            defer t.deinit();
            var r: Mntrpc = .{};
            defer qio.freeblist(r.b);
            var i: usize = 0;
            while (i < 64) : (i += 1) {
                qio.freeblist(r.b);
                r.b = null;
                const got = mntrpcread(&t.m, &r) catch break;
                if (got < 0) break;
                // A reply's data is what its header says, and nothing
                // else is left hanging off it.
                if (r.reply.type == c.Rread)
                    try testing.expectEqual(@as(usize, r.reply.count), chainlen(r.b))
                else
                    try testing.expectEqual(0, chainlen(r.b));
            }
            try testing.expectEqual(0, up().nerrlab);
        }
    }.one, .{
        .corpus = &.{
            // Rread "hi", Rversion, Rerror, two replies in a row, a Rread
            // shorter than its header, and a size past msize.
            "\x0d\x00\x00\x00\x75\x01\x00\x02\x00\x00\x00hi",
            "\x13\x00\x00\x00\x65\xff\xff\x18\x20\x00\x00\x06\x009P2000",
            "\x0b\x00\x00\x00\x6b\x01\x00\x02\x00no",
            "\x0d\x00\x00\x00\x75\x01\x00\x02\x00\x00\x00hi\x0b\x00\x00\x00\x6b\x02\x00\x02\x00no",
            "\x08\x00\x00\x00\x75\x01\x00\x00",
            "\xff\xff\x00\x00\x75\x01\x00\x00\x00\x00\x00",
        },
    });
}

test "fuzz: a directory read from a server is whole entries, or Esbadstat [kernel-port]" {
    _ = try kt.namespace();
    try testing.fuzz({}, struct {
        fn one(_: void, smith: *testing.Smith) anyerror!void {
            var buf: [400]u8 = undefined;
            const n = smith.slice(&buf);
            const ch = dev.devattach('/', "");
            defer chan.cclose(ch);
            mntdirsfix(buf[0..n], ch) catch {
                try testing.expect(kt.errstr().len > 0);
                return;
            };
            // Each entry got the local type.
            var p: usize = 0;
            while (p < n) {
                try testing.expectEqual(@as(u16, '/'), gbit16(buf[p + 2 ..].ptr));
                p += 2 + @as(usize, gbit16(buf[p..].ptr));
            }
        }
    }.one, .{ .corpus = &.{
        "",
        "\x01\x00",
        "\x31\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00a\x00\x00\x00\x00\x00\x00",
    } });
}

/// A 9P server for the cases, on a pipe's other end: / holds one file,
/// hello.
const Server = struct {
    const hello = "hello, 9p\n";

    fn dir(path: u64, buf: []u8) usize {
        var d: c.Dir = .{};
        d.qid = .{ .path = path, .vers = 0, .type = if (path == 0) c.QTDIR else 0 };
        d.mode = if (path == 0) c.DMDIR | 0o555 else 0o444;
        d.length = if (path == 0) 0 else hello.len;
        d.name = @constCast(if (path == 0) "/" else "hello");
        d.uid = @constCast("none");
        d.gid = @constCast("none");
        d.muid = @constCast("none");
        return c.convD2M(&d, buf.ptr, @intCast(buf.len));
    }

    fn readn(ch: *Chan, buf: [*]u8, n: usize) bool {
        var k: usize = 0;
        while (k < n) {
            const l = dev.read(dev.of(ch), ch, buf + k, @intCast(n - k), 0) catch return false;
            if (l <= 0) return false;
            k += @intCast(l);
        }
        return true;
    }

    fn run(ch: *Chan) void {
        var fids: [32]i64 = @splat(-1);
        var in: [8192 + 24]u8 = undefined;
        var out: [8192 + 24]u8 = undefined;
        var data: [512]u8 = undefined;
        while (true) {
            if (!readn(ch, &in, 4)) break;
            const size = gbit32(&in);
            if (size < 7 or size > in.len or !readn(ch, in[4..].ptr, size - 4)) break;
            var f: Fcall = .{};
            if (c.convM2S(&in, size, &f) != size) break;
            var r: Fcall = .{};
            r.type = f.type + 1;
            r.tag = f.tag;
            switch (f.type) {
                c.Tversion => {
                    r.msize = f.msize;
                    r.version = @constCast("9P2000");
                },
                c.Tattach => {
                    fids[f.fid] = 0;
                    r.qid = .{ .path = 0, .vers = 0, .type = c.QTDIR };
                },
                c.Twalk => {
                    var path = fids[f.fid];
                    var i: usize = 0;
                    while (i < f.nwname) : (i += 1) {
                        if (path != 0 or !std.mem.eql(u8, std.mem.span(f.wname[i]), "hello")) break;
                        path = 1;
                        r.wqid[i] = .{ .path = 1, .vers = 0, .type = 0 };
                    }
                    if (i < f.nwname and i == 0) {
                        r.type = c.Rerror;
                        r.ename = @constCast("file does not exist on the test server");
                    } else {
                        r.nwqid = @intCast(i);
                        if (i == f.nwname) fids[f.newfid] = path;
                    }
                },
                c.Topen => {
                    const path: u64 = @intCast(fids[f.fid]);
                    r.qid = .{ .path = path, .vers = 0, .type = if (path == 0) c.QTDIR else 0 };
                },
                c.Tread => {
                    var n: usize = 0;
                    if (fids[f.fid] == 0) {
                        if (f.offset == 0) n = dir(1, &data);
                    } else if (f.offset < hello.len) {
                        n = @min(hello.len - @as(usize, @intCast(f.offset)), f.count);
                        @memcpy(data[0..n], hello[@intCast(f.offset)..][0..n]);
                    }
                    r.count = @intCast(n);
                    r.data = &data;
                },
                c.Tstat => {
                    r.nstat = @intCast(dir(@intCast(fids[f.fid]), &data));
                    r.stat = &data;
                },
                c.Tclunk => fids[f.fid] = -1,
                else => {
                    r.type = c.Rerror;
                    r.ename = @constCast("not on the test server");
                },
            }
            const n = c.convS2M(&r, &out, out.len);
            _ = dev.write(dev.of(ch), ch, &out, @intCast(n), 0) catch break;
        }
        chan.cclose(ch);
        done.store(true, .release);
    }

    var done: std.atomic.Value(bool) = .init(false);

    /// Waits (up to a few seconds) for the server to see its hangup.
    fn hungup() bool {
        var i: usize = 0;
        while (i < 5000) : (i += 1) {
            if (done.load(.acquire)) return true;
            c.osmsleep(1);
        }
        return false;
    }
};

test "a 9P server's files are mounted, walked, read, and stated through devmnt [kernel-port]" {
    _ = try kt.namespace();
    var fds: [2]c_int = undefined;
    _ = try sysfile.pipe(&fds);
    const sc = try sysfile.fdtochan(fds[1], -1, false, true);
    _ = try sysfile.close(fds[1]);
    var k: kt.Kproc = undefined;
    Server.done.store(false, .release);
    try k.start(Server.run, .{sc});
    defer {
        // A case that failed early leaves the server waiting: a note
        // ends its read.
        if (!Server.done.load(.acquire))
            _ = sync.postnote(k.proc(), 1, "kill", c.NUser);
        k.join();
    }
    try mountcase(fds[0]);
    try testing.expect(Server.hungup());
}

fn mountcase(cfd: c_int) !void {
    const fds = [_]c_int{cfd};

    {
        defer _ = sysfile.close(fds[0]) catch {};
        _ = try sysfile.mount(fds[0], -1, "/mnt", c.MREPL | c.MCREATE, "");
    }

    var buf: [64]u8 = undefined;
    const fd = try sysfile.open("/mnt/hello", c.OREAD);
    const n = try sysfile.pread(fd, &buf, buf.len, -1);
    try testing.expectEqualStrings(Server.hello, buf[0..@intCast(n)]);
    _ = try sysfile.close(fd);

    var st: [256]u8 = undefined;
    const sn = try sysfile.stat("/mnt/hello", &st, st.len);
    var d: c.Dir = undefined;
    var strs: [256]u8 = undefined;
    try testing.expect(c.convM2D(&st, @intCast(sn), &d, &strs) != 0);
    try testing.expectEqualStrings("hello", std.mem.span(d.name));
    try testing.expectEqual(@as(u16, 'M'), d.type);

    // A directory read is fixed up the same way.
    const dfd = try sysfile.open("/mnt", c.OREAD);
    const dn = try sysfile.pread(dfd, &st, st.len, -1);
    try testing.expect(c.convM2D(&st, @intCast(dn), &d, &strs) != 0);
    try testing.expectEqualStrings("hello", std.mem.span(d.name));
    try testing.expectEqual(@as(u16, 'M'), d.type);
    _ = try sysfile.close(dfd);

    // The server's error is the process's.
    try testing.expectError(error.Kernel, sysfile.open("/mnt/nothere", c.OREAD));
    try testing.expect(std.mem.indexOf(u8, kt.errstr(), "on the test server") != null);
    try testing.expectError(error.Kernel, sysfile.create("/mnt/new", c.OWRITE, 0o644));
    try testing.expect(std.mem.indexOf(u8, kt.errstr(), "not on the test server") != null);
    try testing.expectEqual(0, up().nerrlab);

    // Unmounting closes the last reference to the conversation, which
    // hangs up the server.
    _ = try sysfile.unmount(null, "/mnt");
}
