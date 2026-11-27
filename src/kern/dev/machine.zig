//! h9's #μ, the machine device (design/child-machines.md): a guest
//! process starts a child machine through a conversation, as #C's and
//! #ℏ's. A native device (dev.zig's `Native`), built only into h9's own
//! kernel, not the namespace kernel.
//!
//! The conversations are kept by the host side, src/child.zig, which
//! this file calls with the conversation's number; it compiles a
//! child's plan, starts it on the parent's engine, and holds its
//! console. A guest read sleeps here until the host side has bytes, and
//! is woken by h9_child_wake, so a note interrupts it. The host calls
//! never fail with kernel errors: they return -1 with the error in an
//! ERRMAX buffer, and this file makes it one.
//!
//! Attached with no spec, it serves the calling machine's children,
//! which the namespace builder binds after #c on /dev:
//!
//!     machine/clone       opening it makes a conversation and opens its ctl
//!     machine/N/ctl       options, one per line, then exec; reads give N
//!     machine/N/data      the child's console: writes are its input
//!     machine/N/stderr    its standard error, with a `stderr` line
//!     machine/N/wait      blocks until it exits; reads as its status
//!     machine/N/plan      its compiled plan, as --print prints it
//!     machine/N/note      a write posts the note to it
//!
//! Attached with spec `sN`, it's channel N of the paths the calling
//! child machine's plan named (`policy.fromCaller`): the root of a 9P
//! mount of that path in its caller's namespace, served by kserve as the
//! caller when the child started, which is how the child's namespace is
//! built from its caller's.
//!
//! Closing the last fd on a conversation kills its child.

const std = @import("std");
const port = @import("../port.zig");
const sync = @import("../sync.zig");
const dev = @import("../dev.zig");
const chan = @import("../chan.zig");
const sysfile = @import("../sysfile.zig");
const devmnt = @import("../devmnt.zig");
const c = port.c;
const up = port.up;
const hup = port.hup;
const Error = port.Error;

const Chan = c.Chan;
const Dir = c.Dir;
const Dirtab = c.Dirtab;
const Walkqid = c.Walkqid;
const Qid = c.Qid;

// Implemented by the host side (src/child.zig), for the calling process.
extern fn h9_child_clone(err: [*]u8) c_long;
extern fn h9_child_convs(out: [*]c_int, max: c_int) c_int;
extern fn h9_child_mine(n: c_int) c_int;
extern fn h9_child_open(id: c_ulong, kind: c_int, err: [*]u8) c_int;
extern fn h9_child_close(id: c_ulong, kind: c_int) void;
extern fn h9_child_ctl(id: c_ulong, buf: [*]const u8, n: c_long, err: [*]u8) c_long;
extern fn h9_child_npaths(id: c_ulong) c_int;
extern fn h9_child_path(id: c_ulong, i: c_int, buf: [*]u8, n: c_int) c_int;
extern fn h9_child_start(id: c_ulong, srcs: [*]?*anyopaque, n: c_int, cwd: [*:0]const u8, err: [*]u8) c_int;
extern fn h9_child_read(id: c_ulong, kind: c_int, buf: [*]u8, n: c_long, off: i64, err: [*]u8) c_long;
extern fn h9_child_ready(id: c_ulong, kind: c_int) c_int;
extern fn h9_child_write(id: c_ulong, kind: c_int, buf: [*]const u8, n: c_long, err: [*]u8) c_long;
extern fn h9_child_source(n: c_int) ?*anyopaque;
// kserve.zig
extern fn h9_kserve_new(readonly: c_int, root: [*:0]const u8, ended: ?*const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque) ?*anyopaque;
extern fn h9_kserve_conn(s: *anyopaque, fd: c_int) c_int;
extern fn h9_kserve_close(s: *anyopaque) void;
extern fn h9_kserve_hangupall(s: *anyopaque) void;

const Mudc = 0x03BC; // μ
const Maxconv = 64; // src/child.zig's max_convs
/// The most paths a child's plan may name.
const Maxsrc = 64;
const Wouldblock = -2;

// The conversation's files, which are also the kinds the host side's
// open, read, and write take.
const Kctl = 0;
const Kdata = 1;
const Kstderr = 2;
const Kwait = 3;
const Kplan = 4;
const Knote = 5;
/// An open of data for writing, counted apart, so the child's input
/// ends when the last writer closes.
const Kdatawrite = 6;

const Qtopdir = 1;
const Qmachdir = 2;
const Qclone = 3;
const Qconvdir = 4;
const Qctl = 5; // Qctl + Kxxx is each file
const Qlast = Qctl + Knote;

fn TYPE(q: Qid) c_uint {
    return @as(c_uint, @truncate(q.path)) & 0x1f;
}
fn CONV(q: Qid) c_int {
    return @as(c_int, @bitCast((@as(c_uint, @truncate(q.path)) >> 5))) - 1;
}
fn QID(n: c_int, t: c_uint) i64 {
    return @as(c_uint, @bitCast(n + 1)) << 5 | t;
}
fn ID(ch: *Chan) c_ulong {
    return @intCast(@intFromPtr(dev.aux(ch).*) - 1);
}

const names = [_][*:0]const u8{ "ctl", "data", "stderr", "wait", "plan", "note" };

const Slot = struct {
    lk: c.Lock = std.mem.zeroes(c.Lock),
    busy: [3]bool = .{ false, false, false }, // a reader of data, stderr, or wait has its turn
    r: [3]c.Rendez = std.mem.zeroes([3]c.Rendez),
};

var slots: [Maxconv]Slot = @splat(.{});

/// Called by the host side, from any thread, when a conversation has
/// bytes or its child ended.
fn h9_child_wake(id: c_ulong) callconv(.c) void {
    const s = &slots[id % Maxconv];
    for (&s.r) |*r| _ = sync.wakeup(r);
}

/// Closes a channel the device walked for a child's namespace.
fn h9_child_dropsrc(ch: ?*anyopaque) callconv(.c) void {
    chan.cclose(@ptrCast(@alignCast(ch orelse return)));
}

const Want = struct { id: c_ulong, kind: c_int };

fn readable(a: ?*anyopaque) callconv(.c) c_int {
    const w: *Want = @ptrCast(@alignCast(a));
    return h9_child_ready(w.id, w.kind);
}

/// As #ℏ's: a Rendez holds one sleeper, so readers take turns.
fn taketurn(s: *Slot, k: usize) Error!void {
    while (true) {
        c.lock(&s.lk);
        if (!s.busy[k]) {
            s.busy[k] = true;
            c.unlock(&s.lk);
            return;
        }
        c.unlock(&s.lk);
        if (up().notepending != 0) {
            up().notepending = 0;
            return port.interrupted();
        }
        c.osmsleep(5);
    }
}

fn giveturn(s: *Slot, k: usize) void {
    c.lock(&s.lk);
    s.busy[k] = false;
    c.unlock(&s.lk);
}

/// A read of data, stderr, or wait, which waits for the child.
fn blockread(id: c_ulong, kind: c_int, va: ?*anyopaque, n: c_int, off: i64) Error!c_int {
    var err: [port.ERRMAX:0]u8 = undefined;
    const s = &slots[id % Maxconv];
    const k: usize = @intCast(kind - Kdata);
    try taketurn(s, k);
    const r = blk: {
        defer giveturn(s, k);
        var w: Want = .{ .id = id, .kind = kind };
        while (true) {
            const r = h9_child_read(id, kind, @ptrCast(va.?), n, off, &err);
            if (r != Wouldblock) break :blk r;
            try sync.sleep(&s.r[k], readable, &w);
        }
    };
    if (r < 0)
        return port.kerror(&err);
    return @intCast(r);
}

/// The caller must be a machine's process.
fn upmach() Error!void {
    if (hup().mach == null) return port.kerror("not an h9 process");
}

fn topdir(ch: *Chan, dp: *Dir) void {
    var q: Qid = undefined;
    dev.mkqid(&q, Qtopdir, 0, c.QTDIR);
    dev.devdir(ch, q, @constCast("#\xce\xbc"), 0, c.eve, dev.dmdir | 0o555, dp);
}

fn machdir(ch: *Chan, dp: *Dir) void {
    var q: Qid = undefined;
    dev.mkqid(&q, Qmachdir, 0, c.QTDIR);
    dev.devdir(ch, q, @constCast("machine"), 0, c.eve, dev.dmdir | 0o555, dp);
}

fn convdir(ch: *Chan, n: c_int, dp: *Dir) void {
    const name = std.fmt.bufPrintSentinel(&up().genbuf, "{d}", .{n}, 0) catch unreachable;
    var q: Qid = undefined;
    dev.mkqid(&q, QID(n, Qconvdir), 0, c.QTDIR);
    dev.devdir(ch, q, name.ptr, 0, c.eve, dev.dmdir | 0o555, dp);
}

fn convfile(ch: *Chan, n: c_int, t: c_uint, dp: *Dir) c_int {
    if (t < Qctl or t > Qlast)
        return -1;
    const k = t - Qctl;
    var q: Qid = undefined;
    dev.mkqid(&q, QID(n, t), 0, c.QTFILE);
    const perm: c_int = switch (k) {
        Kwait, Kplan, Kstderr => 0o444,
        Knote => 0o222,
        else => 0o666,
    };
    dev.devdir(ch, q, @constCast(names[k]), 0, c.eve, perm, dp);
    return 1;
}

/// A Devgen doesn't raise, so the functions that call devwalk, devstat,
/// and devdirread check the caller's machine first.
fn mugen(ch_: [*c]Chan, name: [*c]u8, tab: [*c]Dirtab, ntab: c_int, s: c_int, dp_: [*c]Dir) callconv(.c) c_int {
    _ = name;
    _ = tab;
    _ = ntab;
    const ch: *Chan = ch_;
    const dp: *Dir = dp_;
    switch (TYPE(ch.qid)) {
        Qtopdir => {
            if (s == c.DEVDOTDOT) {
                topdir(ch, dp);
                return 1;
            }
            if (s == 0) {
                machdir(ch, dp);
                return 1;
            }
            return -1;
        },
        Qmachdir => {
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
            var convs: [Maxconv]c_int = undefined;
            const nc = h9_child_convs(&convs, Maxconv);
            if (s - 1 < nc) {
                convdir(ch, convs[@intCast(s - 1)], dp);
                return 1;
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
                machdir(ch, dp);
                return 1;
            }
            if (h9_child_mine(CONV(ch.qid)) == 0) return -1;
            return convfile(ch, CONV(ch.qid), @intCast(Qctl + s), dp);
        },
        else => return convfile(ch, CONV(ch.qid), TYPE(ch.qid), dp),
    }
}

fn muattach(spec: [*:0]const u8) Error!*Chan {
    if (spec[0] == 's') {
        // A child's caller's channel, while its namespace is built.
        const n = std.fmt.parseInt(c_int, std.mem.span(spec + 1), 10) catch return port.kerror(&port.Ebadspec);
        const src = h9_child_source(n) orelse return port.kerror(&port.Ebadspec);
        return chan.cclone(@ptrCast(@alignCast(src)));
    }
    if (spec[0] != 0)
        return port.kerror(&port.Ebadspec);
    try upmach();
    const ch = dev.devattach(Mudc, spec);
    dev.mkqid(&ch.qid, Qtopdir, 0, c.QTDIR);
    return ch;
}

fn muwalk(ch: *Chan, nc: ?*Chan, name: [*]const [*:0]const u8, nname: c_int) Error!?*Walkqid {
    try upmach();
    return dev.devwalk(ch, nc, name, nname, null, 0, &mugen);
}

fn mustat(ch: *Chan, db: [*]u8, n: c_int) Error!c_int {
    try upmach();
    return dev.devstat(ch, db, n, null, 0, &mugen);
}

/// The kind an open of file type t holds the conversation with.
fn kindof(t: c_uint, omode: c_int) c_int {
    const k: c_int = @intCast(t - Qctl);
    if (k == Kdata and (omode & 3) != c.OREAD) return Kdatawrite;
    return k;
}

fn muopen(ch: *Chan, omode: c_int) Error!*Chan {
    var err: [port.ERRMAX:0]u8 = undefined;
    try upmach();
    const t = TYPE(ch.qid);
    switch (t) {
        Qtopdir, Qmachdir, Qconvdir => {
            if ((omode & 3) != c.OREAD)
                return port.kerror(&port.Eperm);
        },
        Qclone => {
            const id = h9_child_clone(&err);
            if (id < 0)
                return port.kerror(&err);
            ch.qid.path = @bitCast(QID(@intCast(id), Qctl));
            dev.aux(ch).* = @ptrFromInt(@as(usize, @intCast(id)) + 1);
        },
        else => {
            const k: c_int = @intCast(t - Qctl);
            const ro = k == Kwait or k == Kplan or k == Kstderr;
            if (ro and (omode & 3) != c.OREAD or k == Knote and (omode & 3) == c.OREAD)
                return port.kerror(&port.Eperm);
            const n = CONV(ch.qid);
            if (h9_child_mine(n) == 0)
                return port.kerror(&port.Ehungup);
            if (h9_child_open(@intCast(n), kindof(t, omode), &err) < 0)
                return port.kerror(&err);
            dev.aux(ch).* = @ptrFromInt(@as(usize, @intCast(n)) + 1);
        },
    }
    ch.mode = @intCast(try sysfile.openmode(@bitCast(omode)));
    ch.flag |= c.COPEN;
    ch.offset = 0;
    return ch;
}

fn muclose(ch: *Chan) Error!void {
    if ((ch.flag & c.COPEN) == 0)
        return;
    const t = TYPE(ch.qid);
    if (t >= Qctl and t <= Qlast)
        h9_child_close(ID(ch), kindof(t, ch.mode));
}

fn readstr(off: i64, buf: ?*anyopaque, n_: c_int, str: []const u8) c_int {
    if (off < 0 or off >= str.len)
        return 0;
    const o: usize = @intCast(off);
    const n = @min(@as(usize, @intCast(@max(n_, 0))), str.len - o);
    @memcpy(@as([*]u8, @ptrCast(buf.?))[0..n], str[o..][0..n]);
    return @intCast(n);
}

fn muread(ch: *Chan, va: ?*anyopaque, n: c_int, off: i64) Error!c_int {
    var buf: [32]u8 = undefined;
    var err: [port.ERRMAX:0]u8 = undefined;
    switch (TYPE(ch.qid)) {
        Qtopdir, Qmachdir, Qconvdir => {
            try upmach();
            return dev.devdirread(ch, @ptrCast(va.?), n, null, 0, &mugen);
        },
        Qctl => return readstr(off, va, n, std.fmt.bufPrint(&buf, "{d}", .{CONV(ch.qid)}) catch unreachable),
        Qctl + Kdata, Qctl + Kstderr, Qctl + Kwait => return blockread(ID(ch), @intCast(TYPE(ch.qid) - Qctl), va, n, off),
        Qctl + Kplan => {
            const r = h9_child_read(ID(ch), Kplan, @ptrCast(va.?), n, off, &err);
            if (r < 0)
                return port.kerror(&err);
            return @intCast(r);
        },
        else => {},
    }
    return port.kerror(&port.Egreg);
}

/// Each conversation's servers still running (source), under servedlk:
/// their fids hold channels of the caller's, so its machine waits for
/// them.
var servedlk: c.Lock = std.mem.zeroes(c.Lock);
var cells: [Maxconv][Maxsrc]?*Cell = @splat(@splat(null));
var nserved: [Maxconv]std.atomic.Value(u32) = @splat(.init(0));

/// The servers conversation id's child still has.
fn h9_child_nserved(id: c_ulong) callconv(.c) c_int {
    return @intCast(nserved[id % Maxconv].load(.acquire));
}

/// Ends the connections of conversation id's servers, from any thread,
/// once its child has ended: a channel the child's kernel still holds
/// would keep one open.
fn h9_child_unserve(id: c_ulong) callconv(.c) void {
    c.lock(&servedlk);
    defer c.unlock(&servedlk);
    for (cells[id % Maxconv]) |cl| if (cl) |x| h9_kserve_hangupall(x.sv);
}

const Cell = struct { sv: *anyopaque, id: c_ulong };

fn track(cell: *Cell) void {
    c.lock(&servedlk);
    defer c.unlock(&servedlk);
    for (&cells[cell.id % Maxconv]) |*cl| if (cl.* == null) {
        cl.* = cell;
        break;
    };
    _ = nserved[cell.id % Maxconv].fetchAdd(1, .acq_rel);
}

/// A source's server, freed when its one connection ends.
fn served(a: ?*anyopaque) callconv(.c) void {
    const cell: *Cell = @ptrCast(@alignCast(a.?));
    const id = cell.id;
    c.lock(&servedlk);
    for (&cells[id % Maxconv]) |*cl| if (cl.* == cell) {
        cl.* = null;
    };
    c.unlock(&servedlk);
    h9_kserve_close(cell.sv);
    c.free(@ptrCast(cell));
    _ = nserved[id % Maxconv].fetchSub(1, .release);
}

/// Path `p` of the caller's namespace, served by kserve over a pipe and
/// attached as a 9P mount: a channel to it alone would lose the mounts
/// and unions under it, which live in the caller's Pgrp. The server runs
/// as the caller, so its walks cross the caller's mounts and devfs
/// checks the caller's plan.
fn source(id: c_ulong, p: [*:0]const u8) Error!*Chan {
    const cell: *Cell = @ptrCast(@alignCast(c.smalloc(@sizeOf(Cell))));
    const sv = h9_kserve_new(0, p, &served, @ptrCast(cell)) orelse {
        c.free(@ptrCast(cell));
        return port.kerror(up().errstr);
    };
    cell.* = .{ .sv = sv, .id = id };
    var fd: [2]c_int = .{ -1, -1 };
    {
        // Until the connection starts, the server goes here.
        errdefer {
            h9_kserve_close(sv);
            c.free(@ptrCast(cell));
        }
        _ = try sysfile.pipe(&fd);
        errdefer {
            _ = sysfile.close(fd[0]) catch {};
            _ = sysfile.close(fd[1]) catch {};
        }
        if (h9_kserve_conn(sv, fd[0]) < 0)
            return port.kerror(up().errstr);
    }
    // From here the connection's end frees it (served).
    track(cell);
    defer {
        _ = sysfile.close(fd[0]) catch {};
        _ = sysfile.close(fd[1]) catch {};
    }
    const bc = try sysfile.fdtochan(fd[1], c.ORDWR, false, true);
    defer chan.cclose(bc);
    return devmnt.mntattach(bc, null, "", 0);
}

/// `exec`: serves each path the child's plan names from the caller's
/// namespace (source), and starts it with their channels and the
/// caller's cwd.
fn execute(id: c_ulong) Error!void {
    var err: [port.ERRMAX:0]u8 = undefined;
    var srcs: [Maxsrc]?*anyopaque = @splat(null);
    const np = h9_child_npaths(id);
    if (np < 0 or np > Maxsrc)
        return port.kerror("too many paths for a child");
    var got: usize = 0;
    defer for (srcs[0..got]) |s| if (s) |p| chan.cclose(@ptrCast(@alignCast(p)));
    var pbuf: [1024:0]u8 = undefined;
    for (0..@intCast(np)) |i| {
        const len = h9_child_path(id, @intCast(i), &pbuf, pbuf.len);
        if (len < 0)
            return port.kerror("path too long");
        pbuf[@intCast(len)] = 0;
        const ch = source(id, &pbuf) catch |e| {
            if (e == error.Interrupted) return e;
            var msg: [port.ERRMAX:0]u8 = undefined;
            const m = std.fmt.bufPrintSentinel(&msg, "{s}: {s}", .{ pbuf[0..@intCast(len)], std.mem.span(@as([*:0]const u8, up().errstr)) }, 0) catch "a path can't be walked";
            return port.kerror(m.ptr);
        };
        srcs[got] = ch;
        got += 1;
    }
    const cwd: [*:0]const u8 = chan.chanpath(up().dot);
    if (h9_child_start(id, &srcs, np, cwd, &err) < 0)
        return port.kerror(&err);
    // The child holds them now.
    got = 0;
}

fn muwrite(ch: *Chan, va: ?*const anyopaque, n: c_int, off: i64) Error!c_int {
    _ = off;
    var err: [port.ERRMAX:0]u8 = undefined;
    switch (TYPE(ch.qid)) {
        Qctl => {
            const id = ID(ch);
            const r = h9_child_ctl(id, @ptrCast(va.?), n, &err);
            if (r < 0)
                return port.kerror(&err);
            if (r == 1)
                try execute(id);
            return n;
        },
        Qctl + Kdata, Qctl + Knote => {
            const r = h9_child_write(ID(ch), @intCast(TYPE(ch.qid) - Qctl), @ptrCast(va.?), n, &err);
            if (r < 0)
                return port.kerror(&err);
            return @intCast(r);
        },
        else => {},
    }
    return port.kerror(&port.Eperm);
}

pub const Device = dev.Native(Mudc, "machine", .{
    .attach = muattach,
    .walk = muwalk,
    .stat = mustat,
    .open = muopen,
    .create = dev.devcreate,
    .close = muclose,
    .read = muread,
    .write = muwrite,
    .remove = dev.devremove,
    .wstat = dev.devwstat,
    .gens = &.{&mugen},
});

pub fn exportC() void {
    @export(&Device.dev, .{ .name = "machinedevtab" });
    @export(&h9_child_wake, .{ .name = "h9_child_wake" });
    @export(&h9_child_dropsrc, .{ .name = "h9_child_dropsrc" });
    @export(&h9_child_nserved, .{ .name = "h9_child_nserved" });
    @export(&h9_child_unserve, .{ .name = "h9_child_unserve" });
}
