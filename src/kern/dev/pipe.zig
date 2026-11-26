//! drawterm's devpipe.c (design/kernel-port.md): pipes, `#|`, with h9's
//! Linux FIFOs (design/epoch-0/linux-fifo.md). A close translation: the
//! same functions in the same order, with error unions in place of
//! waserror. A native device (dev.zig's `Native`).
//!
//! A pipe waits only in its queues, which wait in sync.zig.

const std = @import("std");
const port = @import("../port.zig");
const sync = @import("../sync.zig");
const qio = @import("../qio.zig");
const dev = @import("../dev.zig");
const sysfile = @import("../sysfile.zig");
const c = port.c;
const up = port.up;
const Error = port.Error;

const Chan = c.Chan;
const Dir = c.Dir;
const Dirtab = c.Dirtab;
const Walkqid = c.Walkqid;
const Block = c.Block;
const Qid = c.Qid;
const Queue = qio.Queue;

// h9: src/kern/proc.c's postnote, whose notes reach h9's note queue
// (drawterm's devpipe.c is built with -Dpostnote=h9_postnote).
extern fn h9_postnote(p: *c.Proc, dolock: c_int, msg: [*:0]const u8, flag: c_int) c_int;

const Pipe = struct {
    lk: c.QLock = std.mem.zeroes(c.QLock),
    next: ?*Pipe = null,
    ref: c_int = 0,
    path: c_uint = 0,
    q: [2]*Queue = undefined,
    qref: [2]c_int = .{ 0, 0 },
    fifo: bool = false, // h9: a Linux FIFO's pipe (h9_fifopipe)
    fref: [2]c_int = .{ 0, 0 }, // h9: a FIFO's opens for reading and for writing
};

var pipealloc: struct {
    lk: c.Lock = std.mem.zeroes(c.Lock),
    path: c_uint = 0,
} = .{};

const Qdir = 0;
const Qdata0 = 1;
const Qdata1 = 2;

// netif.h's
fn NETTYPE(x: u64) u64 {
    return x & 0x1f;
}
fn NETID(x: u64) u64 {
    return x >> 5;
}
fn NETQID(i: u64, t: u64) u64 {
    return (i << 5) | t;
}

var pipedir = [_]Dirtab{
    dev.dirtab(".", .{ .path = Qdir, .vers = 0, .type = c.QTDIR }, 0, dev.dmdir | 0o500),
    dev.dirtab("data", .{ .path = Qdata0, .vers = 0, .type = 0 }, 0, 0o600),
    dev.dirtab("data1", .{ .path = Qdata1, .vers = 0, .type = 0 }, 0, 0o600),
};
const NPIPEDIR = 3;

fn pipeof(ch: *Chan) *Pipe {
    return @ptrCast(@alignCast(dev.aux(ch).*.?));
}

fn pipeinit() void {
    if (c.conf.pipeqsize == 0) {
        if (c.conf.nmach > 1)
            c.conf.pipeqsize = 256 * 1024
        else
            c.conf.pipeqsize = 32 * 1024;
    }
}

/// create a pipe, no streams are created until an open
fn pipeattach(spec: [*:0]const u8) Error!*Chan {
    const ch = dev.devattach('|', spec);
    const p: *Pipe = @ptrCast(@alignCast(port.malloc(@sizeOf(Pipe)) orelse {
        c.exhausted(@constCast("memory"));
        unreachable;
    }));
    p.* = .{};
    p.ref = 1;

    p.q[0] = qio.qopen(@intCast(c.conf.pipeqsize), 0, null, null) orelse {
        c.free(p);
        c.exhausted(@constCast("memory"));
        unreachable;
    };
    p.q[1] = qio.qopen(@intCast(c.conf.pipeqsize), 0, null, null) orelse {
        c.free(p.q[0]);
        c.free(p);
        c.exhausted(@constCast("memory"));
        unreachable;
    };

    c.lock(&pipealloc.lk);
    pipealloc.path += 1;
    p.path = pipealloc.path;
    c.unlock(&pipealloc.lk);

    dev.mkqid(&ch.qid, @intCast(NETQID(2 * @as(u64, p.path), Qdir)), 0, c.QTDIR);
    dev.aux(ch).* = p;
    ch.dev = 0;
    return ch;
}

fn pipegen(ch_: [*c]Chan, name: [*c]u8, tab_: [*c]Dirtab, ntab: c_int, i_: c_int, dp: [*c]Dir) callconv(.c) c_int {
    _ = name;
    const ch: *Chan = ch_;

    if (i_ == c.DEVDOTDOT) {
        dev.devdir(ch, ch.qid, @constCast("#|"), 0, c.eve, dev.dmdir | 0o555, dp);
        return 1;
    }
    const i = i_ + 1; // skip .
    if (tab_ == null or i >= ntab)
        return -1;

    const tab = &tab_[@intCast(i)];
    const p = pipeof(ch);
    const len: i64 = switch (tab.qid.path) {
        Qdata0 => qio.qlen(p.q[0]),
        Qdata1 => qio.qlen(p.q[1]),
        else => tab.length,
    };
    var q: Qid = undefined;
    dev.mkqid(&q, @intCast(NETQID(NETID(ch.qid.path), tab.qid.path)), 0, c.QTFILE);
    dev.devdir(ch, q, &tab.name, len, c.eve, tab.perm, dp);
    return 1;
}

fn pipewalk(ch: *Chan, nc: ?*Chan, name: [*]const [*:0]const u8, nname: c_int) Error!?*Walkqid {
    const wq_ = try dev.devwalk(ch, nc, name, nname, &pipedir, NPIPEDIR, &pipegen);
    if (wq_) |wq| {
        if (wq.libclone != null and wq.libclone != ch) {
            const p = pipeof(ch);
            sync.qlock(&p.lk);
            p.ref += 1;
            if (ch.flag & c.COPEN != 0) {
                port.print("channel open in pipewalk\n", .{});
                switch (NETTYPE(ch.qid.path)) {
                    Qdata0 => p.qref[0] += 1,
                    Qdata1 => p.qref[1] += 1,
                    else => {},
                }
            }
            sync.qunlock(&p.lk);
        }
    }
    return wq_;
}

fn pipestat(ch: *Chan, db: [*]u8, n_: c_int) Error!c_int {
    const p = pipeof(ch);
    var dir: Dir = undefined;

    switch (NETTYPE(ch.qid.path)) {
        Qdir => dev.devdir(ch, ch.qid, @constCast("."), 0, c.eve, dev.dmdir | 0o555, &dir),
        Qdata0 => dev.devdir(ch, ch.qid, @constCast("data"), qio.qlen(p.q[0]), c.eve, 0o600, &dir),
        Qdata1 => dev.devdir(ch, ch.qid, @constCast("data1"), qio.qlen(p.q[1]), c.eve, 0o600, &dir),
        else => port.kpanic("pipestat", .{}),
    }
    const n: c_int = @intCast(c.convD2M(&dir, db, @intCast(n_)));
    if (n < c.BIT16SZ)
        return port.kerror(&port.Eshortstat);
    return n;
}

// h9: a Linux FIFO's pipe (design/epoch-0/linux-fifo.md) has one queue, q[0],
// that every open reads and writes, as a Linux pipe does, whichever data
// file it's of. Its opens are counted by their mode: ORDWR is a reader and
// a writer. Once the last writer closes, readers drain the queue and then
// read EOF, as does a reader that opens with no writer; once the last
// reader closes, writes fail. A reader and a writer both open again make
// a working pipe, and the last close of all empties it.
fn fifoopen(p: *Pipe, mode: c_int) void {
    if (mode != c.OWRITE)
        p.fref[0] += 1;
    if (mode != c.OREAD)
        p.fref[1] += 1;
    if (p.fref[0] > 0 and p.fref[1] > 0)
        qio.qreopen(p.q[0])
    else if (p.fref[1] == 0)
        qio.qhangup(p.q[0], null); // a reader with no writer reads EOF
}

fn fifoclose(p: *Pipe, mode: c_int) void {
    if (mode != c.OWRITE) {
        p.fref[0] -= 1;
        if (p.fref[0] == 0)
            qio.qhangup(p.q[0], null);
    }
    if (mode != c.OREAD) {
        p.fref[1] -= 1;
        if (p.fref[1] == 0)
            qio.qhangup(p.q[0], null);
    }
    if (p.fref[0] == 0 and p.fref[1] == 0) {
        qio.qclose(p.q[0]);
        qio.qreopen(p.q[0]);
    }
}

// h9: a FIFO read at the end of a hung-up queue is EOF however often
// it's read, as on Linux; qread fails a fourth.
fn fifoeof(p: *Pipe) bool {
    return p.fifo and qio.qisclosed(p.q[0]) != 0 and qio.qlen(p.q[0]) == 0;
}

/// if the stream doesn't exist, create it
fn pipeopen(ch: *Chan, omode: c_int) Error!*Chan {
    if (ch.qid.type & c.QTDIR != 0) {
        if (omode != c.OREAD)
            return port.kerror(&port.Ebadarg);
        ch.mode = @intCast(omode);
        ch.flag |= c.COPEN;
        ch.offset = 0;
        return ch;
    }

    const p = pipeof(ch);
    const mode = try sysfile.openmode(@bitCast(omode));
    sync.qlock(&p.lk);
    if (p.fifo)
        fifoopen(p, mode)
    else switch (NETTYPE(ch.qid.path)) {
        Qdata0 => p.qref[0] += 1,
        Qdata1 => p.qref[1] += 1,
        else => {},
    }
    sync.qunlock(&p.lk);

    ch.mode = @intCast(mode);
    ch.flag |= c.COPEN;
    ch.offset = 0;
    ch.iounit = qio.qiomaxatomic;
    return ch;
}

fn pipeclose(ch: *Chan) Error!void {
    const p = pipeof(ch);
    sync.qlock(&p.lk);

    if ((ch.flag & c.COPEN) != 0 and p.fifo and NETTYPE(ch.qid.path) != Qdir)
        fifoclose(p, ch.mode)
    else if (ch.flag & c.COPEN != 0) {
        // closing either side hangs up the stream
        switch (NETTYPE(ch.qid.path)) {
            Qdata0 => {
                p.qref[0] -= 1;
                if (p.qref[0] == 0) {
                    qio.qhangup(p.q[1], null);
                    qio.qclose(p.q[0]);
                }
            },
            Qdata1 => {
                p.qref[1] -= 1;
                if (p.qref[1] == 0) {
                    qio.qhangup(p.q[0], null);
                    qio.qclose(p.q[1]);
                }
            },
            else => {},
        }
    }

    // if both sides are closed, they are reusable
    if (!p.fifo and p.qref[0] == 0 and p.qref[1] == 0) {
        qio.qreopen(p.q[0]);
        qio.qreopen(p.q[1]);
    }

    // free the structure on last close
    p.ref -= 1;
    if (p.ref == 0) {
        sync.qunlock(&p.lk);
        c.free(p.q[0]);
        c.free(p.q[1]);
        c.free(p);
    } else sync.qunlock(&p.lk);
}

fn piperead(ch: *Chan, va: ?*anyopaque, n: c_int, offset: i64) Error!c_int {
    _ = offset;
    const p = pipeof(ch);

    switch (NETTYPE(ch.qid.path)) {
        Qdir => return dev.devdirread(ch, @ptrCast(va.?), n, &pipedir, NPIPEDIR, &pipegen),
        Qdata0, Qdata1 => {
            if (fifoeof(p))
                return 0;
            return qio.qread(p.q[@intFromBool(NETTYPE(ch.qid.path) == Qdata1 and !p.fifo)], @ptrCast(va.?), n);
        },
        else => port.kpanic("piperead", .{}),
    }
}

fn pipebread(ch: *Chan, n: c_int, offset: c_uint) Error!?*Block {
    const p = pipeof(ch);

    switch (NETTYPE(ch.qid.path)) {
        Qdata0, Qdata1 => {
            if (fifoeof(p))
                return qio.allocb(0);
            return qio.qbread(p.q[@intFromBool(NETTYPE(ch.qid.path) == Qdata1 and !p.fifo)], n);
        },
        else => {},
    }

    return try dev.devbread(ch, n, offset);
}

/// A failed write to a pipe sends the process a note, unless the pipe
/// is a mounted queue.
fn closedpipe(ch: *Chan) void {
    // avoid notes when pipe is a mounted queue
    if ((ch.flag & c.CMSG) == 0)
        _ = h9_postnote(up(), 1, "sys: write on closed pipe", c.NUser);
}

/// a write to a closed pipe causes a note to be sent to
/// the process.
fn pipewrite(ch: *Chan, va: ?*const anyopaque, n: c_int, offset: i64) Error!c_int {
    _ = offset;
    errdefer closedpipe(ch);

    const p = pipeof(ch);
    const vp: [*]const u8 = @ptrCast(va.?);
    return switch (NETTYPE(ch.qid.path)) {
        Qdata0 => try qio.qwrite(p.q[if (p.fifo) 0 else 1], vp, n),
        Qdata1 => try qio.qwrite(p.q[0], vp, n),
        else => port.kpanic("pipewrite", .{}),
    };
}

fn pipebwrite(ch: *Chan, bp: *Block, offset: c_uint) Error!c_int {
    _ = offset;
    errdefer closedpipe(ch);

    const p = pipeof(ch);
    return switch (NETTYPE(ch.qid.path)) {
        Qdata0 => try qio.qbwrite(p.q[if (p.fifo) 0 else 1], bp),
        Qdata1 => try qio.qbwrite(p.q[0], bp),
        else => port.kpanic("pipebwrite", .{}),
    };
}

pub const Device = dev.Native('|', "pipe", .{
    .init = pipeinit,
    .attach = pipeattach,
    .walk = pipewalk,
    .stat = pipestat,
    .open = pipeopen,
    .create = dev.devcreate,
    .close = pipeclose,
    .read = piperead,
    .bread = pipebread,
    .write = pipewrite,
    .bwrite = pipebwrite,
    .remove = dev.devremove,
    .wstat = dev.devwstat,
    .gens = &.{&pipegen},
});

/// h9: the queue a read of c takes from (wr == 0) or a write to c adds
/// to, for Linux poll (src/kern/linuxnet.c); nil if c isn't a data file.
pub fn h9_pipeq(ch: *Chan, wr: c_int) callconv(.c) ?*Queue {
    const p: *Pipe = @ptrCast(@alignCast(dev.aux(ch).* orelse return null));
    if (p.fifo and NETTYPE(ch.qid.path) != Qdir)
        return p.q[0];
    return switch (NETTYPE(ch.qid.path)) {
        Qdata0 => p.q[if (wr != 0) 1 else 0],
        Qdata1 => p.q[if (wr != 0) 0 else 1],
        else => null,
    };
}

/// h9: a new pipe for a Linux FIFO (src/kern/fifo.c), as its directory's
/// chan, and opens of its data file (see fifoopen).
pub fn h9_fifopipe() callconv(.c) *Chan {
    const ch = pipeattach("") catch |e| port.raise(e);
    pipeof(ch).fifo = true;
    return ch;
}

/// h9: a FIFO's opens for reading (end 0) or writing (end 1), by its directory's chan.
pub fn h9_fiforefs(dir: *Chan, end: c_int) callconv(.c) c_int {
    const p = pipeof(dir);
    sync.qlock(&p.lk);
    const n = p.fref[@intFromBool(end != 0)];
    sync.qunlock(&p.lk);
    return n;
}

pub fn exportC() void {
    @export(&Device.dev, .{ .name = "pipedevtab" });
    @export(&h9_pipeq, .{ .name = "h9_pipeq" });
    @export(&h9_fifopipe, .{ .name = "h9_fifopipe" });
    @export(&h9_fiforefs, .{ .name = "h9_fiforefs" });
}

const testing = std.testing;
const kt = port.testing;
const chan = @import("../chan.zig");

test "a write on a pipe whose reader closed fails, with a note unless it's a mount's [kernel-port]" {
    const p = try kt.namespace();
    var fds: [2]c_int = undefined;
    _ = try sysfile.pipe(&fds);
    _ = try sysfile.close(fds[1]);
    p.notepending = 0;
    try testing.expectError(error.Kernel, sysfile.pwrite(fds[0], "x", 1, -1));
    try testing.expectEqual(1, p.notepending);
    p.notepending = 0;

    // A mounted queue's (CMSG) writes fail with no note.
    const ch = try sysfile.fdtochan(fds[0], -1, false, true);
    defer chan.cclose(ch);
    ch.flag |= c.CMSG;
    try testing.expectError(error.Kernel, dev.write(dev.of(ch), ch, "x", 1, 0));
    try testing.expectEqual(0, p.notepending);
    _ = try sysfile.close(fds[0]);
}

test "a FIFO's pipe is one queue, and reads EOF after its last writer however often [kernel-port]" {
    _ = try kt.namespace();
    const dir = h9_fifopipe();
    defer chan.cclose(dir);
    const names = [_][*:0]const u8{"data"};
    var ends: [2]*Chan = undefined;
    for (&ends, [_]c_int{ c.OREAD, c.OWRITE }) |*e, mode| {
        const wq = (try dev.walkdev(dev.of(dir), dir, null, &names, 1)).?;
        defer c.free(wq);
        e.* = try dev.open(dev.of(wq.libclone), wq.libclone, mode);
    }
    try testing.expectEqual(1, h9_fiforefs(dir, 0));
    try testing.expectEqual(1, h9_fiforefs(dir, 1));

    // data1 isn't needed: the writer's data writes where the reader reads.
    try testing.expectEqual(3, try dev.write(dev.of(ends[1]), ends[1], "abc", 3, 0));
    chan.cclose(ends[1]);
    try testing.expectEqual(0, h9_fiforefs(dir, 1));
    var buf: [8]u8 = undefined;
    try testing.expectEqual(3, try dev.read(dev.of(ends[0]), ends[0], &buf, buf.len, 0));
    try testing.expectEqualStrings("abc", buf[0..3]);
    for (0..5) |_|
        try testing.expectEqual(0, try dev.read(dev.of(ends[0]), ends[0], &buf, buf.len, 0));
    chan.cclose(ends[0]);
}
