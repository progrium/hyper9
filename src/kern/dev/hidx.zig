//! h9's #ι, metadata indexes for 9P roots and mounts (src/kern/devhidx.c,
//! design/epoch-0/mount-index.md, design/kernel-port.md). A close
//! translation of the C: the same functions in the same order, with error
//! unions in place of waserror. A native device (dev.zig's `Native`).
//!
//! A conversation puts the index layer (src/rootindex/layer.zig) between
//! devmnt and a server connection: devmnt mounts the conversation's data
//! file, and the layer answers walks, stats, and directory reads from the
//! index and sends the rest to the server, both ways in 9P2000. h9 puts
//! it above #ℓ's conversation for a root or a namespace-file mount, so
//! the server may speak 9P2000.L too.
//!
//! Laid out like #ℓ, but bound nowhere: only h9 makes conversations.
//!
//!     hidx/clone      opening it makes a conversation and opens its ctl
//!     hidx/N/ctl      server KEY: use the server's .fs/index, cached
//!                     under KEY; index ID: use the index the machine
//!                     gave as ID; then fd N: the caller's fd N is the
//!                     server connection, which starts it; reads give N
//!     hidx/N/data     9P2000, for devmnt
//!     hidx/N/status   the index and what it's done: see the layer's
//!                     status
//!
//! A kproc per conversation reads the server connection and feeds the
//! layer, so replies are read whether or not devmnt is reading: the
//! layer's own requests at the first attach (finding and validating the
//! index) happen while devmnt waits for its Rattach. A guest reading data
//! sleeps until the layer has bytes for it, so a note interrupts it.
//!
//! The layer is called through src/rootindex/kern.zig, whose functions
//! take and return bytes and never fail with a kernel error. A QLock per
//! conversation serializes them; another keeps writes to the server in
//! the order the layer queued them, and a write from devmnt holds it
//! until its own requests are written, so they go to the server in the
//! writer's process.
//!
//! The conversation ends when the last of its ctl and data is closed: the
//! kproc is interrupted, and the server connection closed.
//!
//! The namespace kernel has no #ι, so it builds none of this but the
//! cases.

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

// proc.c
extern fn h9_kprocdetach() void;

// Implemented in Zig (src/rootindex/kern.zig), with its own types: the C
// declared the counts with drawterm's long, which is C's int.
extern fn h9_hidx_new(mach: ?*anyopaque, mode: c_int, arg: [*:0]const u8, err: [*]u8) ?*anyopaque;
extern fn h9_hidx_free(t: ?*anyopaque) void;
extern fn h9_hidx_frommount(t: ?*anyopaque, buf: [*]const u8, n: c_long, err: [*]u8) c_int;
extern fn h9_hidx_fromserver(t: ?*anyopaque, buf: [*]const u8, n: c_long, err: [*]u8) c_int;
extern fn h9_hidx_takeserver(t: ?*anyopaque, buf: [*]u8, n: c_long) c_long;
extern fn h9_hidx_takemount(t: ?*anyopaque, buf: [*]u8, n: c_long) c_long;
extern fn h9_hidx_mountready(t: ?*anyopaque) c_int;
extern fn h9_hidx_status(t: ?*anyopaque, buf: [*]u8, n: c_int) c_int;

const Hidxdc = 0x3b9; // ι
const Maxconv = 256;
const Bufsize = 64 * 1024;
const Statussize = 4096;

const Qtopdir = 1;
const Qhidxdir = 2;
const Qclone = 3;
const Qconvdir = 4;
const Qctl = 5;
const Qdata = 6;
const Qstatus = 7;

fn TYPE(q: Qid) c_uint {
    return @as(c_uint, @truncate(q.path)) & 0x1f;
}
fn CONV(q: Qid) c_int {
    return @as(c_int, @bitCast((@as(c_uint, @truncate(q.path)) >> 5))) - 1;
}
fn QID(n: c_int, t: c_uint) i64 {
    return @as(c_uint, @bitCast(n + 1)) << 5 | t;
}

const Conv = struct {
    lk: c.Lock = std.mem.zeroes(c.Lock),
    inuse: bool = false,
    mach: ?*anyopaque = null, // the machine it belongs to
    opens: c_int = 0, // opens of ctl and data; under lk
    refs: c_int = 0, // opens, and the kproc; under lk
    started: bool = false,
    hungup: bool = false, // under lk
    ready: bool = false, // the layer has bytes for devmnt; under tl
    closing: bool = false, // the last open is gone; under lk
    err: [port.ERRMAX:0]u8 = @splat(0),

    srv: ?*Chan = null, // the server connection
    tr: ?*anyopaque = null, // the layer
    kp: ?*c.Proc = null, // the reader, until it exits; under lk
    kpgone: bool = false, // the reader has exited; under lk
    mode: c_int = 0, // 0 none, 1 server, 2 index
    arg: ?[*:0]u8 = null, // server's key, or index's number

    tl: c.QLock = std.mem.zeroes(c.QLock), // the layer: see trlock
    wl: c.QLock = std.mem.zeroes(c.QLock), // writes to the server
    rl: c.QLock = std.mem.zeroes(c.QLock), // a reader of data has its turn
    r: c.Rendez = std.mem.zeroes(c.Rendez), // that reader, waiting for bytes
};

var convlk: c.Lock = std.mem.zeroes(c.Lock);
var convs: [Maxconv]Conv = @splat(.{});

/// Conversation n's server connection, if c is a conversation's data
/// file.
fn datasrv(ch: *Chan) ?*Chan {
    if (dev.of(ch).dc != Hidxdc or TYPE(ch.qid) != Qdata)
        return null;
    const n = CONV(ch.qid);
    if (n < 0 or n >= Maxconv)
        return null;
    return convs[@intCast(n)].srv;
}

/// Whether c, a conversation's data file that devmnt mounted, has a
/// 9P2000.L server behind it, through #ℓ: fscheck.c makes links and
/// FIFOs there with the translator's create forms.
fn h9_hidx_dotl(ch: *Chan) callconv(.c) c_int {
    const srv = datasrv(ch) orelse return 0;
    return @intFromBool(dev.of(srv).dc == 0x2113);
}

/// Whether c is a conversation's data over a 9P2000.L server's #ℓ
/// conversation, so devmnt may send it the wide requests, which the
/// index layer passes on (design/file-interface.md).
extern fn h9_dotl_wide(*Chan) c_int;

fn h9_hidx_wide(ch: *Chan) callconv(.c) c_int {
    const srv = datasrv(ch) orelse return 0;
    return @intFromBool(h9_dotl_wide(srv) != 0);
}

/// The caller's machine, as proc.c's uphproc finds it.
fn upmach() Error!?*anyopaque {
    const m = up().mach orelse return port.kerror("not an h9 process");
    return m;
}

/// The conversation numbered n in machine mach; or null.
fn lookupin(mach: ?*anyopaque, n: c_int) ?*Conv {
    if (n < 0 or n >= Maxconv)
        return null;
    const cv = &convs[@intCast(n)];
    if (!cv.inuse or cv.mach != mach)
        return null;
    return cv;
}

/// The conversation numbered n in the caller's machine; or null.
fn lookup(n: c_int) Error!?*Conv {
    return lookupin(try upmach(), n);
}

fn newconv() Error!*Conv {
    const mach = try upmach();
    c.lock(&convlk);
    defer c.unlock(&convlk);
    for (&convs) |*cv| {
        c.lock(&cv.lk);
        defer c.unlock(&cv.lk);
        if (!cv.inuse and cv.refs == 0) {
            const lk = cv.lk;
            const tl = cv.tl;
            const wl = cv.wl;
            const rl = cv.rl;
            const r = cv.r;
            cv.* = .{ .lk = lk, .tl = tl, .wl = wl, .rl = rl, .r = r };
            cv.inuse = true;
            cv.mach = mach;
            cv.opens = 1;
            cv.refs = 1;
            return cv;
        }
    }
    return port.kerror("no free devices");
}

// The layer is used under tl. Unlocking notes whether it has bytes for
// devmnt, for readable, which runs under a Rendez's spin lock and so
// can't take tl itself.

fn trlock(cv: *Conv) void {
    sync.qlock(&cv.tl);
}

fn trunlock(cv: *Conv) void {
    @atomicStore(bool, &cv.ready, h9_hidx_mountready(cv.tr) != 0, .release);
    sync.qunlock(&cv.tl);
}

/// Drops a reference; the last frees the conversation.
fn convdecref(cv: *Conv) void {
    c.lock(&cv.lk);
    cv.refs -= 1;
    if (cv.refs > 0) {
        c.unlock(&cv.lk);
        return;
    }
    const srv = cv.srv;
    const tr = cv.tr;
    const arg = cv.arg;
    cv.srv = null;
    cv.tr = null;
    cv.kp = null;
    cv.arg = null;
    cv.inuse = false;
    c.unlock(&cv.lk);
    c.free(arg);
    if (tr != null)
        h9_hidx_free(tr);
    if (srv) |s|
        chan.cclose(s);
}

fn convno(cv: *Conv) c_int {
    return @intCast((@intFromPtr(cv) - @intFromPtr(&convs)) / @sizeOf(Conv));
}

/// Marks the conversation hung up with err, and wakes its reader.
fn hangup(cv: *Conv, err: [*:0]const u8) void {
    c.lock(&cv.lk);
    if (!cv.hungup) {
        @atomicStore(bool, &cv.hungup, true, .release);
        _ = c.strecpy(&cv.err, @as([*c]u8, &cv.err) + cv.err.len, @constCast(err));
    }
    c.unlock(&cv.lk);
    _ = sync.wakeup(&cv.r);
}

/// Writes what the layer has for the server, in order, with cv.wl held.
/// A failed write hangs the conversation up.
fn flushlocked(cv: *Conv) void {
    const buf: [*]u8 = @ptrCast(c.smalloc(Bufsize));
    defer c.free(buf);
    while (true) {
        trlock(cv);
        const n = h9_hidx_takeserver(cv.tr, buf, Bufsize);
        trunlock(cv);
        if (n <= 0)
            break;
        const srv = cv.srv.?;
        _ = dev.write(dev.of(srv), srv, buf, @intCast(n), 0) catch {
            hangup(cv, up().errstr);
            return;
        };
    }
}

fn flushserver(cv: *Conv) void {
    sync.qlock(&cv.wl);
    flushlocked(cv);
    sync.qunlock(&cv.wl);
}

fn closing(cv: *Conv) bool {
    c.lock(&cv.lk);
    const r = cv.closing;
    c.unlock(&cv.lk);
    return r;
}

/// The kproc: reads the server connection into the layer. It ends by
/// returning, after which the kproc's trampoline calls pexit.
fn reader(a: ?*anyopaque) callconv(.c) void {
    var err: [port.ERRMAX:0]u8 = undefined;
    const cv: *Conv = @ptrCast(@alignCast(a));
    // It can outlive the machine's namespace, so it drops it, and its dot
    // and slash for #/ (h9_kprocdetach).
    h9_kprocdetach();
    const buf: [*]u8 = @ptrCast(c.smalloc(Bufsize));
    const srv = cv.srv.?;
    while (true) {
        const n = dev.read(dev.of(srv), srv, buf, Bufsize, 0) catch |e| {
            if (closing(cv))
                break;
            // a stray interrupt: read on
            if (e == error.Interrupted) {
                up().notepending = 0;
                continue;
            }
            hangup(cv, up().errstr);
            break;
        };
        if (n <= 0) {
            hangup(cv, &port.Ehungup);
            break;
        }
        trlock(cv);
        const r = h9_hidx_fromserver(cv.tr, buf, n, &err);
        trunlock(cv);
        if (r < 0) {
            hangup(cv, &err);
            break;
        }
        flushserver(cv);
        _ = sync.wakeup(&cv.r);
    }
    c.free(buf);
    hangup(cv, &port.Ehungup);
    c.lock(&cv.lk);
    cv.kp = null;
    cv.kpgone = true;
    c.unlock(&cv.lk);
    convdecref(cv);
}

fn readable(a: ?*anyopaque) callconv(.c) c_int {
    const cv: *Conv = @ptrCast(@alignCast(a));
    return @intFromBool(@atomicLoad(bool, &cv.hungup, .acquire) or @atomicLoad(bool, &cv.ready, .acquire));
}

/// Conversation n's status, for h9 itself, which reads it after #ι is
/// masked; -1 for none.
fn h9_hidx_convstatus(n: c_int, buf: [*]u8, len: c_int) callconv(.c) c_int {
    if (len <= 0)
        return -1;
    const cv = (lookup(n) catch return -1) orelse return -1;
    c.lock(&cv.lk);
    if (!cv.started or cv.hungup or cv.closing) {
        c.unlock(&cv.lk);
        return -1;
    }
    cv.refs += 1;
    c.unlock(&cv.lk);
    trlock(cv);
    const k = h9_hidx_status(cv.tr, buf, len);
    trunlock(cv);
    convdecref(cv);
    return k;
}

fn dataread(cv: *Conv, va: ?*anyopaque, n: c_int) Error!c_int {
    sync.qlock(&cv.rl);
    defer sync.qunlock(&cv.rl);
    if (!cv.started)
        return port.kerror("no server connection");
    while (true) {
        try sync.sleep(&cv.r, readable, cv);
        trlock(cv);
        const r = h9_hidx_takemount(cv.tr, @ptrCast(va.?), n);
        trunlock(cv);
        if (r > 0)
            return @intCast(r);
        if (cv.hungup)
            return port.kerror(&cv.err);
    }
}

fn datawrite(cv: *Conv, va: ?*const anyopaque, n: c_int) Error!c_int {
    var err: [port.ERRMAX:0]u8 = undefined;
    if (!cv.started)
        return port.kerror("no server connection");
    if (cv.hungup)
        return port.kerror(&cv.err);
    // The caller writes its own requests to the server, so a 9P2000.L
    // server's translator (#ℓ) sees whether they're a Linux process's,
    // whose walks stop at links (h9_fs_linkwalk): holding wl from the
    // queueing to the write keeps the reader kproc from sending them
    // first, as its own, which made a walk to a link follow it.
    sync.qlock(&cv.wl);
    trlock(cv);
    const r = h9_hidx_frommount(cv.tr, @ptrCast(va.?), n, &err);
    trunlock(cv);
    if (r < 0) {
        sync.qunlock(&cv.wl);
        return port.kerror(&err);
    }
    flushlocked(cv);
    sync.qunlock(&cv.wl);
    // the layer may have answered itself
    _ = sync.wakeup(&cv.r);
    return n;
}

/// Starts the conversation on server connection ch, which it takes.
fn start(cv: *Conv, ch: *Chan) Error!void {
    var err: [port.ERRMAX:0]u8 = undefined;
    const tr = h9_hidx_new(cv.mach, cv.mode, cv.arg orelse "", &err) orelse {
        chan.cclose(ch);
        return port.kerror(&err);
    };
    c.lock(&cv.lk);
    cv.srv = ch;
    cv.tr = tr;
    cv.started = true;
    cv.refs += 1; // the kproc's
    c.unlock(&cv.lk);
    flushserver(cv);
    const kp: *c.Proc = @ptrCast(@alignCast(c.kproc(@constCast("hidx"), &reader, cv)));
    // The reader may have exited already; see hidxclose.
    c.lock(&cv.lk);
    if (!cv.kpgone) {
        cv.kp = kp;
        if (cv.closing)
            sync.procinterrupt(kp);
    }
    c.unlock(&cv.lk);
}

fn setarg(cv: *Conv, mode: c_int, a: [*]const u8, n_: usize) Error!void {
    if (cv.started)
        return port.kerror("already connected");
    var n = n_;
    while (n > 0 and (a[n - 1] == '\n' or a[n - 1] == ' '))
        n -= 1;
    const arg: [*]u8 = @ptrCast(c.smalloc(@intCast(n + 1)));
    @memcpy(arg[0..n], a[0..n]);
    arg[n] = 0;
    c.lock(&cv.lk);
    c.free(cv.arg);
    cv.arg = @ptrCast(arg);
    cv.mode = mode;
    c.unlock(&cv.lk);
}

fn ctlwrite(cv: *Conv, a: [*]const u8, n: c_int) Error!void {
    const msg = a[0..@intCast(@max(n, 0))];
    // server KEY: the key may hold spaces, so it's the rest of the line
    if (msg.len > 7 and std.mem.startsWith(u8, msg, "server "))
        return setarg(cv, 1, a + 7, msg.len - 7);
    const cb: *c.Cmdbuf = c.parsecmd(@constCast(a), n);
    defer c.free(cb);
    if (cb.nf == 2 and dev.streq(cb.f[0], "fd")) {
        if (cv.started)
            return port.kerror("already connected");
        try start(cv, try sysfile.fdtochan(c.atoi(cb.f[1]), c.ORDWR, true, true));
    } else if (cb.nf == 2 and dev.streq(cb.f[0], "index")) {
        try setarg(cv, 2, cb.f[1], std.mem.len(cb.f[1]));
    } else return port.kerror(&port.Ebadctl);
}

fn convdir(ch: *Chan, n: c_int, dp: *Dir) void {
    const name = std.fmt.bufPrintSentinel(&up().genbuf, "{d}", .{n}, 0) catch unreachable;
    var q: Qid = undefined;
    dev.mkqid(&q, QID(n, Qconvdir), 0, c.QTDIR);
    dev.devdir(ch, q, name.ptr, 0, c.eve, dev.dmdir | 0o555, dp);
}

fn convfile(ch: *Chan, n: c_int, t: c_uint, dp: *Dir) c_int {
    const names = [_][*:0]const u8{ "ctl", "data", "status" };
    if (t < Qctl or t > Qstatus)
        return -1;
    var q: Qid = undefined;
    dev.mkqid(&q, QID(n, t), 0, c.QTFILE);
    dev.devdir(ch, q, @constCast(names[t - Qctl]), 0, c.eve, if (t == Qstatus) 0o444 else 0o666, dp);
    return 1;
}

fn topdir(ch: *Chan, dp: *Dir) void {
    var q: Qid = undefined;
    dev.mkqid(&q, Qtopdir, 0, c.QTDIR);
    dev.devdir(ch, q, @constCast("#\xce\xb9"), 0, c.eve, dev.dmdir | 0o555, dp);
}

fn hidxdir(ch: *Chan, dp: *Dir) void {
    var q: Qid = undefined;
    dev.mkqid(&q, Qhidxdir, 0, c.QTDIR);
    dev.devdir(ch, q, @constCast("hidx"), 0, c.eve, dev.dmdir | 0o555, dp);
}

/// A Devgen doesn't raise, so the functions that call devwalk, devstat,
/// and devdirread check the caller's machine first, and hidxgen reads it
/// from up.
fn hidxgen(ch_: [*c]Chan, name: [*c]u8, tab: [*c]Dirtab, ntab: c_int, s_: c_int, dp_: [*c]Dir) callconv(.c) c_int {
    _ = name;
    _ = tab;
    _ = ntab;
    const ch: *Chan = ch_;
    const dp: *Dir = dp_;
    var s = s_;
    switch (TYPE(ch.qid)) {
        Qtopdir => {
            if (s == c.DEVDOTDOT) {
                topdir(ch, dp);
                return 1;
            }
            if (s == 0) {
                hidxdir(ch, dp);
                return 1;
            }
            return -1;
        },
        Qhidxdir => {
            if (s == c.DEVDOTDOT) {
                topdir(ch, dp);
                return 1;
            }
            if (s == 0) {
                var q: Qid = undefined;
                dev.mkqid(&q, Qclone, 0, c.QTFILE);
                dev.devdir(ch, q, @constCast("clone"), 0, c.eve, 0o666, dp);
                return 1;
            }
            s -= 1;
            var i: c_int = 0;
            while (i < Maxconv) : (i += 1) {
                if (lookupin(up().mach, i) == null)
                    continue;
                if (s == 0) {
                    convdir(ch, i, dp);
                    return 1;
                }
                s -= 1;
            }
            return -1;
        },
        Qclone => {
            var q: Qid = undefined;
            dev.mkqid(&q, Qclone, 0, c.QTFILE);
            dev.devdir(ch, q, @constCast("clone"), 0, c.eve, 0o666, dp);
            return 1;
        },
        Qconvdir => {
            if (s == c.DEVDOTDOT) {
                hidxdir(ch, dp);
                return 1;
            }
            return convfile(ch, CONV(ch.qid), @intCast(Qctl + s), dp);
        },
        else => return convfile(ch, CONV(ch.qid), TYPE(ch.qid), dp),
    }
}

fn hidxattach(spec: [*:0]const u8) Error!*Chan {
    if (spec[0] != 0)
        return port.kerror(&port.Ebadspec);
    const ch = dev.devattach(Hidxdc, spec);
    dev.mkqid(&ch.qid, Qtopdir, 0, c.QTDIR);
    return ch;
}

fn hidxwalk(ch: *Chan, nc: ?*Chan, name: [*]const [*:0]const u8, nname: c_int) Error!?*Walkqid {
    // A walk in hidx/ reaches its conversations, which are the machine's.
    if (nname > 0 and TYPE(ch.qid) == Qhidxdir or nname > 1 and TYPE(ch.qid) == Qtopdir)
        _ = try upmach();
    return dev.devwalk(ch, nc, name, nname, null, 0, &hidxgen);
}

fn hidxstat(ch: *Chan, db: [*]u8, n: c_int) Error!c_int {
    if (TYPE(ch.qid) == Qhidxdir)
        _ = try upmach();
    return dev.devstat(ch, db, n, null, 0, &hidxgen);
}

/// The conversation a chan names.
fn chanconv(ch: *Chan) Error!*Conv {
    return try lookup(CONV(ch.qid)) orelse port.kerror(&port.Ehungup);
}

fn hidxopen(ch: *Chan, omode: c_int) Error!*Chan {
    switch (TYPE(ch.qid)) {
        Qtopdir, Qhidxdir, Qconvdir, Qstatus => {
            if ((omode & 3) != c.OREAD)
                return port.kerror(&port.Eperm);
        },
        Qclone => {
            const cv = try newconv();
            ch.qid.path = @bitCast(QID(convno(cv), Qctl));
        },
        Qctl, Qdata => {
            const cv = try chanconv(ch);
            c.lock(&cv.lk);
            if (cv.closing) {
                c.unlock(&cv.lk);
                return port.kerror(&port.Ehungup);
            }
            cv.opens += 1;
            cv.refs += 1;
            c.unlock(&cv.lk);
        },
        else => {},
    }
    ch.mode = @intCast(try sysfile.openmode(@bitCast(omode)));
    ch.flag |= c.COPEN;
    ch.offset = 0;
    return ch;
}

fn hidxclose(ch: *Chan) Error!void {
    if ((ch.flag & c.COPEN) == 0)
        return;
    switch (TYPE(ch.qid)) {
        Qctl, Qdata => {
            const cv = &convs[@intCast(CONV(ch.qid))];
            // Interrupted under lk: the reader clears kp under lk before
            // it exits, so kp is never a Proc that's gone.
            c.lock(&cv.lk);
            cv.opens -= 1;
            if (cv.opens == 0) {
                cv.closing = true;
                cv.inuse = false;
                if (cv.kp) |kp|
                    sync.procinterrupt(kp);
            }
            c.unlock(&cv.lk);
            convdecref(cv);
        },
        else => {},
    }
}

/// devcons.c's readstr.
fn readstr(off: i64, buf: ?*anyopaque, n_: c_int, str: []const u8) c_int {
    if (off < 0 or off >= str.len)
        return 0;
    const o: usize = @intCast(off);
    const n = @min(@as(usize, @intCast(@max(n_, 0))), str.len - o);
    @memcpy(@as([*]u8, @ptrCast(buf.?))[0..n], str[o..][0..n]);
    return @intCast(n);
}

fn hidxread(ch: *Chan, va: ?*anyopaque, n: c_int, off: i64) Error!c_int {
    var buf: [32]u8 = undefined;
    switch (TYPE(ch.qid)) {
        Qtopdir, Qhidxdir, Qconvdir => {
            if (TYPE(ch.qid) == Qhidxdir)
                _ = try upmach();
            return dev.devdirread(ch, @ptrCast(va.?), n, null, 0, &hidxgen);
        },
        Qctl => return readstr(off, va, n, std.fmt.bufPrint(&buf, "{d}", .{CONV(ch.qid)}) catch unreachable),
        Qstatus => {
            const cv = try chanconv(ch);
            const s: [*]u8 = @ptrCast(c.smalloc(Statussize));
            defer c.free(s);
            var str: []const u8 = undefined;
            c.lock(&cv.lk);
            if (cv.hungup) {
                str = std.fmt.bufPrint(s[0..Statussize], "Hungup {s}\n", .{std.mem.sliceTo(&cv.err, 0)}) catch s[0..Statussize];
                c.unlock(&cv.lk);
            } else if (!cv.started) {
                c.unlock(&cv.lk);
                str = std.fmt.bufPrint(s[0..Statussize], "Idle\n", .{}) catch unreachable;
            } else {
                c.unlock(&cv.lk);
                trlock(cv);
                const k = h9_hidx_status(cv.tr, s, Statussize - 1);
                trunlock(cv);
                str = s[0..@intCast(k)];
            }
            return readstr(off, va, n, str);
        },
        Qdata => return dataread(&convs[@intCast(CONV(ch.qid))], va, n),
        else => {},
    }
    return port.kerror(&port.Egreg);
}

fn hidxwrite(ch: *Chan, va: ?*const anyopaque, n: c_int, off: i64) Error!c_int {
    _ = off;
    switch (TYPE(ch.qid)) {
        Qctl => {
            try ctlwrite(&convs[@intCast(CONV(ch.qid))], @ptrCast(va.?), n);
            return n;
        },
        Qdata => return datawrite(&convs[@intCast(CONV(ch.qid))], va, n),
        else => {},
    }
    return port.kerror(&port.Eperm);
}

pub const Device = dev.Native(Hidxdc, "hidx", .{
    .attach = hidxattach,
    .walk = hidxwalk,
    .stat = hidxstat,
    .open = hidxopen,
    .create = dev.devcreate,
    .close = hidxclose,
    .read = hidxread,
    .write = hidxwrite,
    .remove = dev.devremove,
    .wstat = dev.devwstat,
    .gens = &.{&hidxgen},
});

pub fn exportC() void {
    @export(&Device.dev, .{ .name = "hidxdevtab" });
    @export(&h9_hidx_dotl, .{ .name = "h9_hidx_dotl" });
    @export(&h9_hidx_wide, .{ .name = "h9_hidx_wide" });
    @export(&h9_hidx_convstatus, .{ .name = "h9_hidx_convstatus" });
}

// Cases (zig build kern-test). The namespace kernel has no #ι and no
// index layer, so these reach what needs neither: the tree, and a
// conversation's ctl before it starts.

const testing = std.testing;
const kt = port.testing;

test "#ι takes no spec and needs a machine for its conversations [kernel-port]" {
    _ = try kt.begin();
    try testing.expectError(error.Kernel, hidxattach("x"));
    try testing.expectEqualStrings("bad attach specifier", kt.errstr());
    // The namespace kernel's table has no #ι, so this is the chan an
    // attach makes, with the root device's type, whose close does
    // nothing.
    const top = chan.newchan();
    defer chan.cclose(top);
    dev.mkqid(&top.qid, Qtopdir, 0, c.QTDIR);
    var db: [128]u8 = undefined;
    const n = try hidxread(top, &db, db.len, 0);
    var d: Dir = undefined;
    var strs: [128]u8 = undefined;
    try testing.expectEqual(@as(c_uint, @intCast(n)), c.convM2D(&db, @intCast(n), &d, &strs));
    try testing.expectEqualStrings("hidx", std.mem.span(d.name));
    const names = [_][*:0]const u8{ "hidx", "clone" };
    try testing.expectError(error.Kernel, hidxwalk(top, null, &names, 2));
    try testing.expectEqualStrings("not an h9 process", kt.errstr());
    try testing.expectEqual(-1, h9_hidx_convstatus(0, &db, db.len));
}

test "a #ι conversation's ctl takes server and index before fd [kernel-port]" {
    _ = try kt.begin();
    var cv: Conv = .{};
    try ctlwrite(&cv, "server tcp!host!564 spec \n", 26);
    try testing.expectEqual(1, cv.mode);
    try testing.expectEqualStrings("tcp!host!564 spec", std.mem.span(cv.arg.?));
    try ctlwrite(&cv, "index 3", 7);
    try testing.expectEqual(2, cv.mode);
    try testing.expectEqualStrings("3", std.mem.span(cv.arg.?));
    try testing.expectError(error.Kernel, ctlwrite(&cv, "bogus", 5));
    try testing.expectEqualStrings("bad process or channel control request", kt.errstr());
    try testing.expectError(error.Kernel, dataread(&cv, null, 0));
    try testing.expectEqualStrings("no server connection", kt.errstr());
    cv.started = true;
    try testing.expectError(error.Kernel, ctlwrite(&cv, "index 4", 7));
    try testing.expectEqualStrings("already connected", kt.errstr());
    c.free(cv.arg);
}
