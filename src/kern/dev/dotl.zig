//! h9's devdotl.c (design/kernel-port.md): `#ℓ`, 9P2000.L translation
//! (design/epoch-0/dotl.md). A close translation: the same functions in
//! the same order, with error unions in place of C's error labels. A native
//! device (dev.zig's `Native`).
//!
//! A conversation puts the translator (src/dotl/client.zig) between
//! devmnt and a server connection: devmnt mounts the conversation's data
//! file and speaks 9P2000, and the translator speaks 9P2000.L to the
//! server, or passes 9P2000 through when that's what the server speaks.
//!
//! Laid out like devip's protocol directories, under /net with the
//! namespace builder's bind -a '#ℓ' /net:
//!
//!        dotl/clone      opening it makes a conversation and opens its ctl
//!        dotl/N/ctl      fd N: the caller's fd N is the server connection;
//!                        fd R W: read the server from fd R, write it to fd W
//!                        (a pipe pair, design/epoch-0/fd-mounts.md);
//!                        dial ADDR[,ADDR...]: dial the first that answers
//!                        (tcp!, or unix! for h9's own root dials), and
//!                        again on a drop if the server speaks 9P2000.L.Z;
//!                        version 9P2000.L: don't offer .L.Z;
//!                        serve N: the server side, for a 9P2000.L client
//!                        on fd N, with an exportfs on data;
//!                        reads give N
//!        dotl/N/data     9P2000, for devmnt
//!        dotl/N/status   the dialect: negotiating, 9P2000, 9P2000.L,
//!                        9P2000.L.Z, or Hungup and why; "reconnects N"
//!                        follows once the connection has been resumed
//!
//! A kproc per conversation reads the server connection and feeds the
//! translator, so replies are read whether or not devmnt is reading:
//! many of devmnt's requests are answered by the translator itself, and
//! one request can take several round trips. A guest reading data sleeps
//! until the translator has bytes for it, so a note interrupts it.
//!
//! The translator is called through leaves (src/dotl/kern.zig)
//! that take and return bytes and never raise. A QLock per
//! conversation serializes them; another keeps writes to the server in
//! the order the translator queued them.
//!
//! A dialed conversation reconnects: when the connection drops, or a
//! 9P2000.L.Z server answers ENOTLEADER, the reader dials the addresses
//! again, round the list, for up to 120 seconds (ZeroFS's retry horizon),
//! and the translator resumes on the new connection. It dials TCP through
//! #I with the dialer's plan, so --net and --net-allow apply as to the
//! first dial, in a namespace of its own (with the dialer's device mask),
//! since one shared with the guest's would hold its own mount.
//!
//! The conversation ends when the last of its ctl and data is closed: the
//! kproc is interrupted, and the server connection closed. A host
//! descriptor through devlfd can't be interrupted in its read, so the
//! kproc waits for it to be readable first, in a wait the close wakes
//! (h9_hostwait, src/kern/rootdial.c): an embedder's descriptor
//! (design/epoch-0/fd-mounts.md) stays open after the run, and a reader
//! left in its read would take the next run's replies.

const std = @import("std");
const port = @import("../port.zig");
const sync = @import("../sync.zig");
const dev = @import("../dev.zig");
const chan = @import("../chan.zig");
const pgrp = @import("../pgrp.zig");
const sysfile = @import("../sysfile.zig");
const rootdial = @import("../rootdial.zig");
const hstream = @import("hstream.zig");
const c = port.c;
const up = port.up;
const Error = port.Error;

const Chan = c.Chan;
const Dir = c.Dir;
const Dirtab = c.Dirtab;
const Walkqid = c.Walkqid;
const Qid = c.Qid;
const Pgrp = c.Pgrp;
const Proc = c.Proc;

// src/kern/proc.zig
extern fn h9_kprocdetach() void;

// src/kern.zig: the calling thread's sandbox plan.
extern fn h9_plan_get() ?*anyopaque;
extern fn h9_plan_set(plan: ?*anyopaque) void;
// src/kern/rootdial.zig
extern fn h9_hostwait_new(fd: ?*anyopaque) ?*anyopaque;
extern fn h9_hostwait(w: ?*anyopaque) c_int;
extern fn h9_hostwait_wake(w: ?*anyopaque) void;
extern fn h9_hostwait_free(w: ?*anyopaque) void;

// Implemented in Zig (src/dotl/kern.zig), as it declares them.
extern fn h9_dotl_new(mach: ?*anyopaque, mode: c_int, uid: c_long, user: ?[*:0]const u8, err: [*]u8) ?*anyopaque;
extern fn h9_dotl_canreconnect(t: ?*anyopaque) c_int;
extern fn h9_dotl_wantreconnect(t: ?*anyopaque) c_int;
extern fn h9_dotl_reconnect(t: ?*anyopaque, err: [*]u8) c_int;
extern fn h9_dotl_free(t: ?*anyopaque) void;
extern fn h9_dotl_frommount(t: ?*anyopaque, buf: [*]const u8, n: c_long, linkwalk: c_int, err: [*]u8) c_int;
// linux.c: whether up's walks stop at links (design/epoch-0/linux-symlinks.md)
extern fn h9_fs_linkwalk() c_int;
extern fn h9_dotl_fromserver(t: ?*anyopaque, buf: [*]const u8, n: c_long, err: [*]u8) c_int;
extern fn h9_dotl_takeserver(t: ?*anyopaque, buf: [*]u8, n: c_long) c_long;
extern fn h9_dotl_takemount(t: ?*anyopaque, buf: [*]u8, n: c_long) c_long;
extern fn h9_dotl_mountready(t: ?*anyopaque) c_int;
extern fn h9_dotl_status(t: ?*anyopaque, buf: [*]u8, n: c_int) c_int;
extern fn h9_dotl_translating(t: ?*anyopaque) c_int;

const Dotldc = 0x2113; // ℓ
const Maxconv = 256;
const Bufsize = 64 * 1024;

const Qtopdir = 1;
const Qdotldir = 2;
const Qclone = 3;
const Qconvdir = 4;
const Qctl = 5;
const Qdata = 6;
const Qstatus = 7;

// drawterm's ulong is 32 bits, so the C's paths were.
fn TYPE(q: Qid) u32 {
    return @as(u32, @truncate(q.path)) & 0x1f;
}
fn CONV(q: Qid) c_int {
    return @bitCast((@as(u32, @truncate(q.path)) >> 5) -% 1);
}
fn QID(n: c_int, t: u32) u32 {
    return ((@as(u32, @bitCast(n)) +% 1) << 5) | t;
}

const Conv = struct {
    lk: c.Lock,
    inuse: bool,
    mach: ?*anyopaque, // the machine it belongs to
    opens: c_int, // opens of ctl and data; under lk
    refs: c_int, // opens, and the kproc; under lk
    started: bool,
    hungup: bool, // under lk
    ready: bool, // the translator has bytes for devmnt; under tl
    closing: bool, // the last open is gone; under lk
    err: [port.ERRMAX]u8,

    srv: ?*Chan, // the server connection
    srvw: ?*Chan, // fd R W's: the one written to, or nil for srv
    hw: ?*anyopaque, // the reader's wait on a host descriptor, or nil
    tr: ?*anyopaque, // the translator
    kp: ?*Proc, // the reader, until it exits; under lk
    kpgone: bool, // the reader has exited; under lk
    nolz: bool, // ctl's version 9P2000.L
    serving: bool, // ctl's serve: the server side
    iduid: c_int, // ctl's user: the server's uid for us, or -1
    iduser: [c.KNAMELEN]u8, // and its name for us
    addrs: ?[*:0]u8, // dial's or redial's addresses, to redial
    at: c_int, // which of them was dialed last
    plan: ?*anyopaque, // the dialer's plan, for redials
    pg: ?*Pgrp, // the reader's namespace, until it takes it

    tl: c.QLock, // the translator: see trlock
    wl: c.QLock, // writes to the server
    rl: c.QLock, // a reader of data has its turn
    r: c.Rendez, // that reader, waiting for bytes
};

var convlk: c.Lock = std.mem.zeroes(c.Lock);
var convs: [Maxconv]Conv = std.mem.zeroes([Maxconv]Conv);

/// strecpy(dst, dst+len, src): src, cut to fit, terminated.
fn strecpy(dst: []u8, src: [*:0]const u8) void {
    const s = std.mem.sliceTo(src, 0);
    const n = @min(s.len, dst.len - 1);
    @memcpy(dst[0..n], s[0..n]);
    dst[n] = 0;
}

fn strz(b: []const u8) [*:0]const u8 {
    return @ptrCast(b.ptr);
}

/// The caller's machine, as proc.c's h9_uphproc finds it.
fn upmach() Error!*anyopaque {
    const m: ?*anyopaque = @ptrCast(up().mach);
    return m orelse port.kerror("not an h9 process");
}

/// The conversation numbered n in the caller's machine; or nil. (For a
/// process that isn't h9's, which has no machine, drawterm's raised; it
/// has no conversations, since it can't make one.)
fn lookup(n: c_int) ?*Conv {
    if (n < 0 or n >= Maxconv)
        return null;
    const cv = &convs[@intCast(n)];
    if (!cv.inuse or cv.mach == null or cv.mach != @as(?*anyopaque, @ptrCast(up().mach)))
        return null;
    return cv;
}

/// Conversations are numbered across machines, so a number names one
/// conversation in one machine; another machine's are hidden from it.
fn newconv() Error!*Conv {
    // (Before the locks, which drawterm's raised under.)
    const mach = try upmach();
    c.lock(&convlk);
    for (&convs) |*cv| {
        c.lock(&cv.lk);
        if (!cv.inuse and cv.refs == 0) {
            cv.inuse = true;
            cv.mach = mach;
            cv.opens = 1;
            cv.refs = 1;
            cv.started = false;
            cv.hungup = false;
            cv.ready = false;
            cv.closing = false;
            cv.err[0] = 0;
            cv.srv = null;
            cv.srvw = null;
            cv.hw = null;
            cv.tr = null;
            cv.kp = null;
            cv.kpgone = false;
            cv.nolz = false;
            cv.serving = false;
            cv.addrs = null;
            cv.plan = null;
            cv.pg = null;
            cv.iduid = -1;
            cv.iduser[0] = 0;
            c.unlock(&cv.lk);
            c.unlock(&convlk);
            return cv;
        }
        c.unlock(&cv.lk);
    }
    c.unlock(&convlk);
    return port.kerror("no free devices");
}

/// The translator is used under tl. Unlocking notes whether it has bytes
/// for devmnt, for readable, which runs under a Rendez's spin lock and so
/// can't take tl itself.
fn trlock(cv: *Conv) void {
    sync.qlock(&cv.tl);
}

fn trunlock(cv: *Conv) void {
    cv.ready = h9_dotl_mountready(cv.tr) != 0;
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
    const srvw = cv.srvw;
    const hw = cv.hw;
    const tr = cv.tr;
    const addrs = cv.addrs;
    const pg = cv.pg;
    cv.srv = null;
    cv.srvw = null;
    cv.hw = null;
    cv.tr = null;
    cv.kp = null;
    cv.addrs = null;
    cv.pg = null;
    cv.inuse = false;
    c.unlock(&cv.lk);
    c.free(addrs);
    if (pg) |g|
        pgrp.closepgrp(g);
    if (tr != null)
        h9_dotl_free(tr);
    if (srv) |s|
        chan.cclose(s);
    if (srvw) |w|
        chan.cclose(w);
    h9_hostwait_free(hw);
}

fn convno(cv: *Conv) c_int {
    return @intCast(cv - &convs[0]);
}

/// Marks the conversation hung up with err, and wakes its reader.
fn hangup(cv: *Conv, err: [*:0]const u8) void {
    c.lock(&cv.lk);
    if (!cv.hungup) {
        cv.hungup = true;
        strecpy(&cv.err, err);
    }
    c.unlock(&cv.lk);
    _ = sync.wakeup(&cv.r);
}

/// Writes what the translator has for the server, in order. A failed
/// write hangs the conversation up.
fn flushserver(cv: *Conv) void {
    const buf: [*]u8 = @ptrCast(c.smalloc(Bufsize));
    sync.qlock(&cv.wl);
    const r = flushloop(cv, buf);
    sync.qunlock(&cv.wl);
    c.free(buf);
    r catch hangup(cv, up().errstr);
}

fn flushloop(cv: *Conv, buf: [*]u8) Error!void {
    while (true) {
        trlock(cv);
        const n = h9_dotl_takeserver(cv.tr, buf, Bufsize);
        trunlock(cv);
        if (n <= 0)
            break;
        const w = cv.srvw orelse cv.srv.?;
        _ = try dev.write(dev.of(w), w, buf, @intCast(n), 0);
    }
}

/// TCP dials through #I, as dial(2) does through /net: cs translates the
/// address, and each translation is tried in turn. Fails with the last
/// error.
fn dialone(ipport: [*:0]const u8) Error!*Chan {
    var buf: [32]u8 = undefined;
    var cmd: [160]u8 = undefined;

    const ctl = try chan.namec("#I/tcp/clone", c.Aopen, c.ORDWR, 0);
    defer chan.cclose(ctl);
    var n: usize = @intCast(@max(0, try dev.read(dev.of(ctl), ctl, &buf, buf.len - 1, 0)));
    if (n <= 0)
        return port.kerror(&port.Ehungup);
    buf[n] = 0;
    while (n > 0 and (buf[n - 1] == '\n' or buf[n - 1] == ' ')) {
        n -= 1;
        buf[n] = 0;
    }
    const conn = bprint(&cmd, "connect {s}", .{ipport});
    _ = try dev.write(dev.of(ctl), ctl, conn.ptr, @intCast(conn.len), 0);
    const data = bprint(&cmd, "#I/tcp/{s}/data", .{buf[0..n]});
    return chan.namec(data.ptr, c.Aopen, c.ORDWR, 0);
}

/// snprint: fmt into buf, cut to fit, terminated.
fn bprint(buf: []u8, comptime fmt: []const u8, args: anytype) [:0]const u8 {
    var w: std.Io.Writer = .fixed(buf[0 .. buf.len - 1]);
    w.print(fmt, args) catch {};
    buf[w.end] = 0;
    return buf[0..w.end :0];
}

fn hasprefix(s: [*:0]const u8, p: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.sliceTo(s, 0), p);
}

fn dialaddr(mach: ?*anyopaque, addr: [*:0]const u8) Error!*Chan {
    var buf: [256]u8 = undefined;
    var err: [port.ERRMAX]u8 = undefined;

    // A host unix socket, only for a dial h9 makes itself (a root's),
    // which runs with no plan: a guest has no way to the host's sockets.
    if (hasprefix(addr, "unix!")) {
        if (h9_plan_get() != null)
            return port.kerror("dial: unix sockets are for roots");
        return rootdial.unixchan(addr + 5);
    }
    // A WebSocket h9 makes itself (a root's or a namespace file's mount),
    // through hstream with the machine's handshake options, so a
    // credential helper runs again (design/epoch-0/credential-helpers.md).
    if (hasprefix(addr, "ws://") or hasprefix(addr, "wss://")) {
        if (h9_plan_get() != null)
            return port.kerror("dial: WebSockets are for h9's own mounts");
        // a host-made WebSocket's channel, connected
        return hstream.dial(mach, addr);
    }
    if (!hasprefix(addr, "tcp!") and !hasprefix(addr, "net!"))
        return port.kerror("dial: only tcp addresses");
    const cs = try chan.namec("#I/cs", c.Aopen, c.ORDWR, 0);
    defer chan.cclose(cs);
    const alen = std.mem.len(addr);
    _ = try dev.write(dev.of(cs), cs, addr, @intCast(alen), 0);
    strecpy(&err, "dial: no address");
    // cs answers one "/net/tcp/clone ip!port" line per read
    var off: i64 = 0;
    while (true) {
        const n = try dev.read(dev.of(cs), cs, &buf, buf.len - 1, off);
        off += n;
        if (n <= 0)
            return port.kerror(strz(&err));
        const k: usize = @intCast(n);
        buf[k] = 0;
        if (buf[k - 1] == '\n')
            buf[k - 1] = 0;
        const line = std.mem.sliceTo(&buf, 0);
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        if (dialone(strz(buf[sp + 1 ..]))) |ch|
            return ch
        else |_|
            strecpy(&err, up().errstr);
    }
}

/// Dials the first of a comma-separated list that answers, starting at
/// address at.* and going round, and sets at.* to it.
fn dialany(mach: ?*anyopaque, addrs: [*:0]const u8, at: *c_int) Error!*Chan {
    var err: [port.ERRMAX]u8 = undefined;
    var f: [16][*c]u8 = undefined;

    const len = std.mem.len(addrs);
    const list: [*]u8 = @ptrCast(c.smalloc(@intCast(len + 1)));
    defer c.free(list);
    @memcpy(list[0 .. len + 1], addrs[0 .. len + 1]);
    const nf = c.getfields(list, &f, f.len, 1, @constCast(","));
    strecpy(&err, "dial: no address");
    if (nf > 0)
        at.* = @rem(at.*, nf);
    var i: c_int = 0;
    while (i < nf) : (i += 1) {
        const k = @rem(at.* + i, nf);
        if (dialaddr(mach, @ptrCast(f[@intCast(k)]))) |ch| {
            at.* = k;
            return ch;
        } else |_| strecpy(&err, up().errstr);
    }
    return port.kerror(strz(&err));
}

fn closing(cv: *Conv) bool {
    c.lock(&cv.lk);
    const r = cv.closing;
    c.unlock(&cv.lk);
    return r;
}

fn return0(a: ?*anyopaque) callconv(.c) c_int {
    _ = a;
    return 0;
}

/// After a drop, dials again and resumes the translator on the new
/// connection, if the conversation was dialed and the server speaks
/// 9P2000.L.Z. Tries round the addresses for 120 seconds, a second apart,
/// starting with the one that dropped, or with the next when the server
/// said it isn't the leader (`next`). Returns true when resumed.
fn redial(cv: *Conv, next: bool) bool {
    var err: [port.ERRMAX]u8 = undefined;

    const addrs = cv.addrs orelse return false;
    trlock(cv);
    var r = h9_dotl_canreconnect(cv.tr);
    trunlock(cv);
    if (r == 0)
        return false;
    const deadline = c.h9_tnow() + 120 * 1000000000;
    if (next) {
        const n: c_int = @intCast(std.mem.count(u8, std.mem.sliceTo(addrs, 0), ",") + 1);
        // Back to the first, or behind one address: give it a second.
        cv.at += 1;
        if (cv.at >= n) {
            cv.at = 0;
            sync.tsleep(&up().ksleep, &return0, null, 1000) catch return false;
        }
    }
    var ch: *Chan = undefined;
    while (true) {
        if (closing(cv))
            return false;
        if (dialany(cv.mach, addrs, &cv.at)) |d| {
            ch = d;
            break;
        } else |_| {}
        up().notepending = 0;
        if (c.h9_tnow() > deadline)
            return false;
        sync.tsleep(&up().ksleep, &return0, null, 1000) catch return false;
    }
    // Writes to the old connection are done with.
    sync.qlock(&cv.wl);
    const old = cv.srv;
    cv.srv = ch;
    trlock(cv);
    r = h9_dotl_reconnect(cv.tr, &err);
    trunlock(cv);
    sync.qunlock(&cv.wl);
    chan.cclose(old);
    if (r < 0)
        return false;
    flushserver(cv);
    return true;
}

/// One read of the server connection, once it's readable.
fn readserver(cv: *Conv, buf: [*]u8) Error!c_int {
    // woken only by the last close
    if (cv.hw != null and h9_hostwait(cv.hw) == 0)
        return port.kerror(&port.Ehungup);
    const s = cv.srv.?;
    return dev.read(dev.of(s), s, buf, Bufsize, 0);
}

/// The kproc: reads the server connection into the translator.
fn reader(a: ?*anyopaque) callconv(.c) void {
    var err: [port.ERRMAX]u8 = undefined;
    const cv: *Conv = @ptrCast(@alignCast(a.?));
    var firstnl: u64 = 0;
    var lastnl: u64 = 0;

    // It can outlive the machine's namespace, so it drops it, and its dot
    // and slash for #/ (h9_kprocdetach).
    h9_kprocdetach();
    // A dialed conversation redials in a namespace of its own.
    c.lock(&cv.lk);
    if (cv.pg) |pg| {
        up().pgrp = pg;
        cv.pg = null;
    }
    c.unlock(&cv.lk);
    h9_plan_set(cv.plan);
    const buf: [*]u8 = @ptrCast(c.smalloc(Bufsize));
    while (true) {
        const n = readserver(cv, buf) catch {
            if (closing(cv))
                break;
            // a stray interrupt: read on
            if (dev.streq(up().errstr, &port.Eintr)) {
                up().notepending = 0;
                continue;
            }
            strecpy(&err, up().errstr);
            if (redial(cv, false))
                continue;
            hangup(cv, strz(&err));
            break;
        };
        if (n <= 0) {
            if (!closing(cv) and redial(cv, false))
                continue;
            hangup(cv, &port.Ehungup);
            break;
        }
        trlock(cv);
        const r = h9_dotl_fromserver(cv.tr, buf, n, &err);
        const want = h9_dotl_wantreconnect(cv.tr);
        trunlock(cv);
        if (r < 0) {
            hangup(cv, strz(&err));
            break;
        }
        flushserver(cv);
        _ = sync.wakeup(&cv.r);
        // ENOTLEADER: drop this connection for the next address, for 120
        // seconds of them with no 10 second gap.
        if (want == 0)
            continue;
        const now = c.h9_tnow();
        if (now > lastnl + 10 * 1000000000)
            firstnl = now;
        lastnl = now;
        if (now > firstnl + 120 * 1000000000 or !redial(cv, true)) {
            hangup(cv, "server is not the leader");
            break;
        }
    }
    c.free(buf);
    hangup(cv, &port.Ehungup);
    c.lock(&cv.lk);
    cv.kp = null;
    cv.kpgone = true;
    c.unlock(&cv.lk);
    convdecref(cv);
    // It ends by returning, after which the kproc's trampoline calls
    // pexit.
}

fn readable(a: ?*anyopaque) callconv(.c) c_int {
    const cv: *Conv = @ptrCast(@alignCast(a.?));
    return @intFromBool(@as(*volatile bool, &cv.hungup).* or @as(*volatile bool, &cv.ready).*);
}

fn dataread(cv: *Conv, va: [*]u8, n: c_int) Error!c_int {
    sync.qlock(&cv.rl);
    defer sync.qunlock(&cv.rl);
    if (!cv.started)
        return port.kerror("no server connection");
    // A wakeup doesn't mean devmnt has bytes: the reader wakes after
    // every server reply, and most go back to the server as requests.
    while (true) {
        try sync.sleep(&cv.r, &readable, cv);
        trlock(cv);
        const r = h9_dotl_takemount(cv.tr, va, n);
        trunlock(cv);
        if (r > 0)
            return @intCast(r);
        if (cv.hungup)
            return port.kerror(strz(&cv.err));
    }
}

fn datawrite(cv: *Conv, va: [*]const u8, n: c_int) Error!c_int {
    var err: [port.ERRMAX]u8 = undefined;

    if (!cv.started)
        return port.kerror("no server connection");
    if (cv.hungup)
        return port.kerror(strz(&cv.err));
    trlock(cv);
    // devmnt writes a request in the process that makes it
    const r = h9_dotl_frommount(cv.tr, va, n, h9_fs_linkwalk(), &err);
    trunlock(cv);
    if (r < 0)
        return port.kerror(strz(&err));
    flushserver(cv);
    // the translator may have answered itself
    _ = sync.wakeup(&cv.r);
    return n;
}

/// Starts the conversation on server connection ch, which it takes, and
/// w, if not nil, for writes to the server, which it also takes.
fn start2(cv: *Conv, ch: *Chan, w: ?*Chan) Error!void {
    var err: [port.ERRMAX]u8 = undefined;

    const mode: c_int = if (cv.serving) 2 else @intFromBool(!cv.nolz);
    const tr = h9_dotl_new(cv.mach, mode, cv.iduid, if (cv.iduid >= 0) strz(&cv.iduser) else null, &err);
    if (tr == null) {
        chan.cclose(ch);
        if (w) |ww|
            chan.cclose(ww);
        return port.kerror(strz(&err));
    }
    // A host descriptor's read can't be interrupted, so the reader waits
    // where a close can wake it.
    var hw: ?*anyopaque = null;
    if (dev.of(ch).dc == 0x3C6)
        hw = h9_hostwait_new(dev.aux(ch).*);
    c.lock(&cv.lk);
    cv.srv = ch;
    cv.srvw = w;
    cv.hw = hw;
    cv.tr = tr;
    cv.started = true;
    cv.refs += 1; // the kproc's
    c.unlock(&cv.lk);
    flushserver(cv);
    const kp: ?*Proc = @ptrCast(@alignCast(c.kproc(@constCast("dotl"), &reader, cv)));
    // The reader may have exited already; see dotlclose.
    c.lock(&cv.lk);
    if (!cv.kpgone) {
        cv.kp = kp;
        if (cv.closing) {
            sync.procinterrupt(kp.?);
            h9_hostwait_wake(cv.hw);
        }
    }
    c.unlock(&cv.lk);
}

fn start(cv: *Conv, ch: *Chan) Error!void {
    return start2(cv, ch, null);
}

/// C's atoi.
fn atoi(s: [*:0]const u8) c_int {
    return @truncate(strtol(s));
}

/// C's strtol(s, nil, 10), saturating as it does.
fn strtol(s_: [*:0]const u8) c_long {
    var s: []const u8 = std.mem.sliceTo(s_, 0);
    s = std.mem.trimStart(u8, s, " \t\n\r\x0b\x0c");
    var neg = false;
    if (s.len > 0 and (s[0] == '-' or s[0] == '+')) {
        neg = s[0] == '-';
        s = s[1..];
    }
    var v: c_long = 0;
    for (s) |ch| {
        if (ch < '0' or ch > '9') break;
        const d: c_long = ch - '0';
        v = std.math.mul(c_long, v, 10) catch return if (neg) std.math.minInt(c_long) else std.math.maxInt(c_long);
        v = (if (neg) std.math.sub(c_long, v, d) else std.math.add(c_long, v, d)) catch
            return if (neg) std.math.minInt(c_long) else std.math.maxInt(c_long);
    }
    return v;
}

/// A namespace for a dialed conversation's reader, with the dialer's
/// device mask.
fn readerpgrp() Error!*Pgrp {
    const pg = try pgrp.newpgrp();
    if (@as(?*Pgrp, up().pgrp)) |p|
        pg.devmask = p.devmask;
    return pg;
}

fn dupstr(s: [*:0]const u8) [*:0]u8 {
    const len = std.mem.len(s);
    const p: [*]u8 = @ptrCast(c.smalloc(@intCast(len + 1)));
    @memcpy(p[0 .. len + 1], s[0 .. len + 1]);
    return @ptrCast(p);
}

fn fields(cb: *c.Cmdbuf) [*]const [*:0]const u8 {
    return @ptrCast(cb.f);
}

fn ctlwrite(cv: *Conv, a: [*]const u8, n: c_int) Error!void {
    const cb: *c.Cmdbuf = c.parsecmd(@constCast(a), n);
    defer c.free(cb);
    const nf = cb.nf;
    const f = fields(cb);
    if (nf == 2 and dev.streq(f[0], "fd")) {
        if (cv.started)
            return port.kerror("already connected");
        try start(cv, try sysfile.fdtochan(atoi(f[1]), c.ORDWR, true, true));
    } else if (nf == 3 and dev.streq(f[0], "fd")) {
        if (cv.started)
            return port.kerror("already connected");
        const ch = try sysfile.fdtochan(atoi(f[1]), c.OREAD, true, true);
        const w = sysfile.fdtochan(atoi(f[2]), c.OWRITE, true, true) catch |e| {
            chan.cclose(ch);
            return e;
        };
        try start2(cv, ch, w);
    } else if (nf == 2 and dev.streq(f[0], "serve")) {
        if (cv.started)
            return port.kerror("already connected");
        cv.serving = true;
        try start(cv, try sysfile.fdtochan(atoi(f[1]), c.ORDWR, true, true));
    } else if (nf == 2 and dev.streq(f[0], "dial")) {
        if (cv.started)
            return port.kerror("already connected");
        cv.at = 0;
        const ch = try dialany(cv.mach, f[1], &cv.at);
        const pg = readerpgrp() catch |e| {
            chan.cclose(ch);
            return e;
        };
        const addrs = dupstr(f[1]);
        c.lock(&cv.lk);
        cv.addrs = addrs;
        cv.plan = h9_plan_get();
        cv.pg = pg;
        c.unlock(&cv.lk);
        try start(cv, ch);
    } else if (nf == 2 and dev.streq(f[0], "redial")) {
        // Before fd: the addresses to dial if the connection drops, for a
        // connection h9 made itself (a WebSocket root or mount), so with
        // no plan, as a root's dial has.
        if (cv.started)
            return port.kerror("already connected");
        if (h9_plan_get() != null)
            return port.kerror("redial: for h9's own connections");
        const pg = try readerpgrp();
        const addrs = dupstr(f[1]);
        c.lock(&cv.lk);
        c.free(cv.addrs);
        cv.addrs = addrs;
        cv.at = 0;
        cv.plan = null;
        if (cv.pg) |old|
            pgrp.closepgrp(old);
        cv.pg = pg;
        c.unlock(&cv.lk);
    } else if (nf == 3 and dev.streq(f[0], "user")) {
        // Before fd: the server's uid and name for us (9P-Uid, 9P-User).
        if (cv.started)
            return port.kerror("already connected");
        if (std.mem.len(f[2]) >= c.KNAMELEN or f[2][0] == 0)
            return port.kerror("user: name too long");
        // drawterm's long, as strtol's result was
        cv.iduid = @truncate(strtol(f[1]));
        strecpy(&cv.iduser, f[2]);
    } else if (nf == 2 and dev.streq(f[0], "version")) {
        if (cv.started)
            return port.kerror("already connected");
        if (dev.streq(f[1], "9P2000.L"))
            cv.nolz = true
        else if (dev.streq(f[1], "9P2000.L.Z"))
            cv.nolz = false
        else
            return port.kerror("version: 9P2000.L or 9P2000.L.Z");
    } else return port.kerror(&port.Ebadctl);
}

fn convdir(ch: *Chan, n: c_int, dp: *Dir) void {
    var q: Qid = undefined;
    const g = &up().genbuf;
    _ = bprint(g, "{d}", .{n});
    dev.mkqid(&q, QID(n, Qconvdir), 0, c.QTDIR);
    dev.devdir(ch, q, g, 0, c.eve, dev.dmdir | 0o555, dp);
}

fn convfile(ch: *Chan, n: c_int, t: u32, dp: *Dir) c_int {
    const name: [*:0]const u8 = switch (t) {
        Qctl => "ctl",
        Qdata => "data",
        Qstatus => "status",
        else => return -1,
    };
    var q: Qid = undefined;
    dev.mkqid(&q, QID(n, t), 0, c.QTFILE);
    dev.devdir(ch, q, @constCast(name), 0, c.eve, if (t == Qstatus) 0o444 else 0o666, dp);
    return 1;
}

fn topdir(ch: *Chan, dp: *Dir) void {
    var q: Qid = undefined;
    dev.mkqid(&q, Qtopdir, 0, c.QTDIR);
    dev.devdir(ch, q, @constCast("#\xe2\x84\x93"), 0, c.eve, dev.dmdir | 0o555, dp);
}

fn dotldir(ch: *Chan, dp: *Dir) void {
    var q: Qid = undefined;
    dev.mkqid(&q, Qdotldir, 0, c.QTDIR);
    dev.devdir(ch, q, @constCast("dotl"), 0, c.eve, dev.dmdir | 0o555, dp);
}

fn dotlgen(ch_: [*c]Chan, name: [*c]u8, tab: [*c]Dirtab, ntab: c_int, s_: c_int, dp_: [*c]Dir) callconv(.c) c_int {
    _ = .{ name, tab, ntab };
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
                dotldir(ch, dp);
                return 1;
            }
            return -1;
        },
        Qdotldir => {
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
                if (lookup(i) == null)
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
                dotldir(ch, dp);
                return 1;
            }
            if (s < 0) return -1;
            return convfile(ch, CONV(ch.qid), Qctl + @as(u32, @intCast(s)), dp);
        },
        else => return convfile(ch, CONV(ch.qid), TYPE(ch.qid), dp),
    }
}

fn dotlattach(spec: [*:0]const u8) Error!*Chan {
    if (spec[0] != 0)
        return port.kerror(&port.Ebadspec);
    const ch = dev.devattach(Dotldc, spec);
    dev.mkqid(&ch.qid, Qtopdir, 0, c.QTDIR);
    return ch;
}

fn dotlwalk(ch: *Chan, nc: ?*Chan, name: [*]const [*:0]const u8, nname: c_int) Error!?*Walkqid {
    return dev.devwalk(ch, nc, name, nname, null, 0, &dotlgen);
}

fn dotlstat(ch: *Chan, db: [*]u8, n: c_int) Error!c_int {
    return dev.devstat(ch, db, n, null, 0, &dotlgen);
}

/// The conversation a chan names; or an error.
fn chanconv(ch: *Chan) Error!*Conv {
    return lookup(CONV(ch.qid)) orelse port.kerror(&port.Ehungup);
}

fn dotlopen(ch: *Chan, omode: c_int) Error!*Chan {
    var mode: ?c_int = null;
    switch (TYPE(ch.qid)) {
        Qtopdir, Qdotldir, Qconvdir, Qstatus => {
            if ((omode & 3) != c.OREAD)
                return port.kerror(&port.Eperm);
        },
        Qclone => {
            mode = try sysfile.openmode(@bitCast(omode));
            const cv = try newconv();
            ch.qid.path = QID(convno(cv), Qctl);
        },
        Qctl, Qdata => {
            mode = try sysfile.openmode(@bitCast(omode));
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
    // A conversation's open checks its mode before it's counted, as a
    // pipe's does (drawterm's counted it, and failed the open after).
    ch.mode = @intCast(mode orelse try sysfile.openmode(@bitCast(omode)));
    ch.flag |= c.COPEN;
    ch.offset = 0;
    return ch;
}

fn dotlclose(ch: *Chan) Error!void {
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
                h9_hostwait_wake(cv.hw);
            }
            c.unlock(&cv.lk);
            convdecref(cv);
        },
        else => {},
    }
}

fn readstr(off: i64, va: ?*anyopaque, n: c_int, s: [*:0]const u8) c_int {
    return c.readstr(@truncate(@as(u64, @bitCast(off))), @ptrCast(va), @bitCast(n), @constCast(s));
}

fn dotlread(ch: *Chan, va: ?*anyopaque, n: c_int, off: i64) Error!c_int {
    var buf: [port.ERRMAX + 32]u8 = undefined;

    switch (TYPE(ch.qid)) {
        Qtopdir, Qdotldir, Qconvdir => return dev.devdirread(ch, @ptrCast(va.?), n, null, 0, &dotlgen),
        Qctl => return readstr(off, va, n, bprint(&buf, "{d}", .{CONV(ch.qid)})),
        Qstatus => {
            const cv = try chanconv(ch);
            c.lock(&cv.lk);
            if (cv.hungup) {
                _ = bprint(&buf, "Hungup {s}\n", .{std.mem.sliceTo(&cv.err, 0)});
                c.unlock(&cv.lk);
            } else if (!cv.started) {
                c.unlock(&cv.lk);
                _ = bprint(&buf, "Idle\n", .{});
            } else {
                c.unlock(&cv.lk);
                trlock(cv);
                var k: usize = @intCast(h9_dotl_status(cv.tr, &buf, buf.len - 2));
                trunlock(cv);
                buf[k] = '\n';
                k += 1;
                buf[k] = 0;
            }
            return readstr(off, va, n, strz(&buf));
        },
        Qdata => return dataread(&convs[@intCast(CONV(ch.qid))], @ptrCast(va.?), n),
        else => return port.kerror(&port.Egreg),
    }
}

fn dotlwrite(ch: *Chan, va: ?*const anyopaque, n: c_int, off: i64) Error!c_int {
    _ = off;
    switch (TYPE(ch.qid)) {
        Qctl => {
            try ctlwrite(&convs[@intCast(CONV(ch.qid))], @ptrCast(va.?), n);
            return n;
        },
        Qdata => return datawrite(&convs[@intCast(CONV(ch.qid))], @ptrCast(va.?), n),
        else => return port.kerror(&port.Eperm),
    }
}

/// Whether ch, a server connection devmnt mounted, is a conversation's
/// data whose client side translates to 9P2000.L, so devmnt may send it
/// the wide requests (design/file-interface.md, src/kern/devmnt.zig).
pub fn h9_dotl_wide(ch: *Chan) callconv(.c) c_int {
    if (dev.of(ch).dc != Dotldc or TYPE(ch.qid) != Qdata)
        return 0;
    const n = CONV(ch.qid);
    if (n < 0 or n >= Maxconv)
        return 0;
    const cv = &convs[@intCast(n)];
    var r: c_int = 0;
    sync.qlock(&cv.tl);
    if (cv.inuse and !cv.serving and cv.tr != null)
        r = h9_dotl_translating(cv.tr);
    sync.qunlock(&cv.tl);
    return r;
}

pub const Device = dev.Native(Dotldc, "dotl", .{
    .attach = dotlattach,
    .walk = dotlwalk,
    .stat = dotlstat,
    .open = dotlopen,
    .create = dev.devcreate,
    .close = dotlclose,
    .read = dotlread,
    .write = dotlwrite,
    .remove = dev.devremove,
    .wstat = dev.devwstat,
    .gens = &.{&dotlgen},
});

pub fn exportC() void {
    @export(&Device.dev, .{ .name = "dotldevtab" });
    @export(&h9_dotl_wide, .{ .name = "h9_dotl_wide" });
}

const testing = std.testing;
const kt = port.testing;
const devmnt = @import("../devmnt.zig");

fn ctlmsg(fd: c_int, msg: []const u8) Error!c_int {
    return sysfile.pwrite(fd, msg.ptr, @intCast(msg.len), -1);
}

fn readfile(name: [*:0]const u8, buf: []u8) ![]const u8 {
    const fd = try sysfile.open(name, c.OREAD);
    defer _ = sysfile.close(fd) catch {};
    const n = try sysfile.pread(fd, buf.ptr, @intCast(buf.len), 0);
    return buf[0..@intCast(n)];
}

/// Makes the case's process a machine's, as a conversation's maker is.
fn inmach(p: *Proc) void {
    p.mach = @ptrCast(@alignCast(h9_kern_newmach(null)));
}

fn outmach(p: *Proc) void {
    h9_kern_machdetach(p.mach);
    p.mach = null;
}

extern fn h9_kern_newmach(kernel: ?*anyopaque) ?*anyopaque;
extern fn h9_kern_machdetach(m: ?*anyopaque) void;

fn expectErrstr(s: [*:0]const u8) !void {
    // (An open's error names the path after it.)
    try testing.expectEqualStrings(std.mem.span(s), kt.errstr()[0..@min(kt.errstr().len, std.mem.len(s))]);
}

test "a #ℓ conversation is made by its clone, takes its ctl's messages, and goes at its last close [kernel-port]" {
    const p = try kt.namespace();
    try testing.expectError(error.Kernel, sysfile.open("#ℓ/dotl/clone", c.ORDWR));
    try testing.expect(std.mem.startsWith(u8, kt.errstr(), "not an h9 process"));
    try testing.expect(c.canlock(&convlk) != 0);
    c.unlock(&convlk);
    inmach(p);
    defer outmach(p);
    const fd = try sysfile.open("#ℓ/dotl/clone", c.ORDWR);
    var nbuf: [16]u8 = undefined;
    const num = nbuf[0..@intCast(try sysfile.pread(fd, &nbuf, nbuf.len, 0))];
    var buf: [64]u8 = undefined;
    var path: [64]u8 = undefined;
    var spath: [64]u8 = undefined;

    const status = bprint(&spath, "#ℓ/dotl/{s}/status", .{num});
    try testing.expectEqualStrings("Idle\n", try readfile(status.ptr, &buf));
    try testing.expectEqualStrings(num, try readfile(bprint(&path, "#ℓ/dotl/{s}/ctl", .{num}).ptr, &buf));
    try testing.expectError(error.Kernel, sysfile.open(status.ptr, c.OWRITE));
    try expectErrstr(&port.Eperm);

    try testing.expectError(error.Kernel, ctlmsg(fd, "bogus"));
    try expectErrstr(&port.Ebadctl);
    try testing.expectError(error.Kernel, ctlmsg(fd, "version 9P2000"));
    try expectErrstr("version: 9P2000.L or 9P2000.L.Z");
    try testing.expectError(error.Kernel, ctlmsg(fd, "user 0 " ++ @as([c.KNAMELEN]u8, @splat('x'))));
    try expectErrstr("user: name too long");
    try testing.expectError(error.Kernel, ctlmsg(fd, "fd 99"));
    try expectErrstr(&port.Ebadfd);
    try testing.expectError(error.Kernel, ctlmsg(fd, "dial il!x!1"));
    try expectErrstr("dial: only tcp addresses");
    _ = try ctlmsg(fd, "version 9P2000.L");

    // No connection yet.
    const data = try sysfile.open(bprint(&path, "#ℓ/dotl/{s}/data", .{num}).ptr, c.ORDWR);
    try testing.expectError(error.Kernel, sysfile.pread(data, &buf, buf.len, 0));
    try expectErrstr("no server connection");
    try testing.expectError(error.Kernel, sysfile.pwrite(data, "x", 1, -1));
    try expectErrstr("no server connection");

    // It's gone once its ctl and data are closed.
    _ = try sysfile.close(data);
    try testing.expectEqualStrings("Idle\n", try readfile(status.ptr, &buf));
    _ = try sysfile.close(fd);
    try testing.expectError(error.Kernel, sysfile.open(status.ptr, c.OREAD));
    try testing.expectEqual(0, up().nerrlab);
}

test "a 9P2000 server through a #ℓ conversation is passed through to devmnt [kernel-port]" {
    const p = try kt.namespace();
    inmach(p);
    defer outmach(p);
    var fds: [2]c_int = undefined;
    _ = try sysfile.pipe(&fds);
    const sc = try sysfile.fdtochan(fds[1], -1, false, true);
    _ = try sysfile.close(fds[1]);
    var k: kt.Kproc = undefined;
    devmnt.Server.done.store(false, .release);
    try k.start(devmnt.Server.run, .{sc});
    defer {
        if (!devmnt.Server.done.load(.acquire))
            _ = sync.postnote(k.proc(), 1, "kill", c.NUser);
        k.join();
    }

    const cfd = try sysfile.open("#ℓ/dotl/clone", c.ORDWR);
    var nbuf: [16]u8 = undefined;
    const num = nbuf[0..@intCast(try sysfile.pread(cfd, &nbuf, nbuf.len, 0))];
    var path: [64]u8 = undefined;
    var msg: [32]u8 = undefined;
    _ = try ctlmsg(cfd, bprint(&msg, "fd {d}", .{fds[0]}));
    _ = try sysfile.close(fds[0]);
    const dfd = try sysfile.open(bprint(&path, "#ℓ/dotl/{s}/data", .{num}).ptr, c.ORDWR);
    try testing.expectError(error.Kernel, ctlmsg(cfd, "version 9P2000.L"));
    try expectErrstr("already connected");
    _ = try sysfile.close(cfd);

    // mountcase closes the data fd, and its unmount the conversation,
    // which hangs up the server.
    try devmnt.mountcase(dfd);
    try testing.expect(devmnt.Server.hungup());
}
