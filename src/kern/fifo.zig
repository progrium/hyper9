//! FIFOs for the Linux ABI (src/kern/fifo.c, design/epoch-0/linux-fifo.md,
//! design/kernel-port.md). A close translation of the C: the same
//! functions in the same order, with error unions in place of waserror.
//!
//! A FIFO file (an overlay's Nfifo node, or a host FIFO in a devfs tree)
//! is never read or written itself. A Linux open of one joins a pipe kept
//! for it in a table keyed by the file's identity: its device, instance,
//! and qid path, as src/abi/linux/locks.zig keys file locks. A host
//! file's qid path is its host device and inode, so its key leaves out
//! devfs's attach number, and machines in one h9 process that open one
//! host FIFO share its pipe. One table serves every machine.
//!
//! The pipe is devpipe's, in FIFO mode (dev/pipe.zig's fifopipe): one
//! queue that every open reads and writes, with its opens counted by
//! mode, so read, write, poll, and fstat are a pipe's. The entry holds
//! the pipe's directory, and goes once nothing has the pipe open: its
//! queue is empty then, so a later open starts afresh, as on Linux.
//!
//! The open rules are Linux's. An open joins the pipe first, so that the
//! other end's waiters see it, and then O_RDONLY waits for a writer and
//! O_WRONLY for a reader, unless one has come since the wait began (as
//! Linux's open counters say), even if it has gone again; a note
//! interrupts the wait, and the join is undone. With O_NONBLOCK, a read
//! open returns at once, and a write open with no reader fails ("no
//! reader", the caller's ENXIO). O_RDWR returns at once, as both.
//!
//! It waits only in tsleep.zig.

const std = @import("std");
const port = @import("port.zig");
const sync = @import("sync.zig");
const tsleepz = @import("tsleep.zig");
const dev = @import("dev.zig");
const chan = @import("chan.zig");
const sysfile = @import("sysfile.zig");
const devpipe = @import("dev/pipe.zig");
const c = port.c;
const up = port.up;
const Error = port.Error;

const Chan = c.Chan;

// src/kern/devshim.c's, since what they call can raise.
extern fn h9_shim_overlay_lower(ch: *Chan, r: *?*Chan) c_int;
extern fn h9_shim_fs_chanisfifo(ch: *Chan, r: *c_int) c_int;

const Fifo = struct {
    next: ?*Fifo,
    dc: c_int,
    dev: c_uint,
    path: u64,
    dir: *Chan, // the pipe's directory
    gen: [2]c_uint, // opens for reading (0) and for writing (1) so far
    r: c.Rendez,
};

const Wait = struct {
    f: *Fifo,
    end: usize, // the end waited for: 0 a reader, 1 a writer
    gen: c_uint,
};

var fifolk: c.QLock = std.mem.zeroes(c.QLock);
var fifos: ?*Fifo = null;

const Enoreader = "no reader";

const Key = struct { dc: c_int, dev: c_uint, path: u64 };

/// The key for c's file: a host file's by its host identity, through an
/// overlay.
fn fifokey(ch_: *Chan) Error!Key {
    var ch = ch_;
    var l: ?*Chan = null;
    try dev.caught(h9_shim_overlay_lower(ch, &l));
    if (l) |lc|
        ch = lc;
    const dc: c_int = dev.of(ch).dc;
    const k: Key = .{ .dc = dc, .dev = if (dc == 'U') 0 else ch.dev, .path = ch.qid.path };
    if (l) |lc|
        chan.cclose(lc);
    return k;
}

/// Drops entries nothing has open. With fifolk held.
fn fifogc() void {
    var l: *?*Fifo = &fifos;
    while (l.*) |f| {
        if (devpipe.fiforefs(f.dir, 0) == 0 and devpipe.fiforefs(f.dir, 1) == 0) {
            l.* = f.next;
            chan.cclose(f.dir);
            c.free(f);
            continue;
        }
        l = &f.next;
    }
}

/// The entry for the key, made if there's none. With fifolk held.
fn fifoget(k: Key) Error!*Fifo {
    var f_ = fifos;
    while (f_) |f| : (f_ = f.next) {
        if (f.dc == k.dc and f.dev == k.dev and f.path == k.path)
            return f;
    }
    const f: *Fifo = @ptrCast(@alignCast(port.malloc(@sizeOf(Fifo)) orelse
        return port.kerror(&port.Enomem)));
    errdefer c.free(f);
    f.* = .{
        .next = fifos,
        .dc = k.dc,
        .dev = k.dev,
        .path = k.path,
        .dir = try devpipe.fifopipe(),
        .gen = .{ 0, 0 },
        .r = std.mem.zeroes(c.Rendez),
    };
    fifos = f;
    return f;
}

/// Whether the end w waits for has an open, or has had one since the
/// wait began.
fn arrived(a: ?*anyopaque) callconv(.c) c_int {
    const w: *Wait = @ptrCast(@alignCast(a));
    const gen = @as(*volatile c_uint, &w.f.gen[w.end]).*;
    return @intFromBool(gen != w.gen or devpipe.fiforefs(w.f.dir, @intCast(w.end)) > 0);
}

/// An open of f's pipe's data file in mode.
fn fifochan(f: *Fifo, mode: c_int) Error!*Chan {
    const name = [_][*:0]const u8{"data"};
    const wq = try dev.walkdev(dev.of(f.dir), f.dir, null, &name, 1) orelse
        return port.kerror(&port.Enonexist);
    const ch_: ?*Chan = wq.libclone;
    c.free(wq);
    const ch = ch_ orelse return port.kerror(&port.Enonexist);
    errdefer chan.cclose(ch);
    return dev.open(dev.of(ch), ch, mode);
}

/// Whether fd is a FIFO's file, which a Linux open must join instead
/// (fifojoin).
pub fn isfifo(fd: c_int) Error!bool {
    const ch = try sysfile.fdtochan(fd, -1, false, true);
    defer chan.cclose(ch);
    if (ch.qid.type & c.QTDIR != 0)
        return false;
    var r: c_int = 0;
    try dev.caught(h9_shim_fs_chanisfifo(ch, &r));
    return r != 0;
}

/// Replaces fd, an open FIFO file, with an open of its pipe in mode
/// (OREAD, OWRITE, or ORDWR), waiting for the other end unless nonblock
/// or ORDWR. Fails with "no reader" for a nonblocking write open with no
/// reader, or with the note's interruption.
pub fn fifojoin(fd: c_int, mode: c_int, nonblock: bool) Error!void {
    const k = blk: {
        const ch = try sysfile.fdtochan(fd, -1, false, true);
        defer chan.cclose(ch);
        break :blk try fifokey(ch);
    };
    const rd = mode != c.OWRITE;
    const wr = mode != c.OREAD;
    sync.qlock(&fifolk);
    const ch = joinlocked(k, mode, rd, wr, nonblock) catch |e| {
        sync.qunlock(&fifolk);
        return e;
    };
    sync.qunlock(&fifolk);
    errdefer chan.cclose(ch);
    const fg: *c.Fgrp = up().fgrp;
    c.lock(&fg.ref.lk);
    const old: *Chan = (if (fd > fg.maxfd) null else fg.fd[@intCast(fd)]) orelse {
        c.unlock(&fg.ref.lk);
        return port.kerror(&port.Ebadfd);
    };
    fg.fd[@intCast(fd)] = ch;
    c.unlock(&fg.ref.lk);
    chan.cclose(old);
}

/// fifojoin's part under fifolk, which it holds again when it returns,
/// whether or not it fails.
fn joinlocked(k: Key, mode: c_int, rd: bool, wr: bool, nonblock: bool) Error!*Chan {
    fifogc();
    const f = try fifoget(k);
    if (wr and !rd and nonblock and devpipe.fiforefs(f.dir, 0) == 0)
        return port.kerror(Enoreader);
    const ch = try fifochan(f, mode);
    errdefer chan.cclose(ch);
    if (rd)
        f.gen[0] += 1;
    if (wr)
        f.gen[1] += 1;
    _ = sync.wakeup(&f.r);
    if (!(rd and wr) and !nonblock) {
        var w: Wait = .{ .f = f, .end = @intFromBool(rd), .gen = undefined };
        w.gen = f.gen[w.end];
        while (arrived(&w) == 0) {
            sync.qunlock(&fifolk);
            tsleepz.tsleep(&f.r, arrived, &w, 100) catch |e| {
                // A note that comes after the other end has (a child's
                // exit, say) doesn't undo the meeting, which the
                // restarted open couldn't find again once the other end
                // has gone. The note stays pending for the syscall's
                // return.
                sync.qlock(&fifolk);
                if (arrived(&w) == 0)
                    return e;
                break;
            };
            sync.qlock(&fifolk);
        }
    }
    return ch;
}

// The C names, which src/abi/linux/kc.zig calls: each returns -1 with
// the error in syserrstr, as proc.c's syserr leaves it.

fn syserr() c_int {
    const p = up().syserrstr;
    up().syserrstr = up().errstr;
    up().errstr = p;
    return -1;
}

/// 1 or 0, or -1 with the error set.
fn h9_linux_isfifo(fd: c_int) callconv(.c) c_int {
    return @intFromBool(isfifo(fd) catch return syserr());
}

/// 0, or -1 with the error set.
fn h9_linux_fifojoin(fd: c_int, mode: c_int, nonblock: c_int) callconv(.c) c_int {
    fifojoin(fd, mode, nonblock != 0) catch return syserr();
    return 0;
}

pub fn exportC() void {
    @export(&h9_linux_isfifo, .{ .name = "h9_linux_isfifo" });
    @export(&h9_linux_fifojoin, .{ .name = "h9_linux_fifojoin" });
}

// Cases (zig build kern-test). A pipe's data file stands in for a FIFO
// file: fifojoin joins whatever file fd is open on, by its key.

const testing = std.testing;
const kt = port.testing;

/// Two fds open on one file, for a FIFO's two openers.
fn twoFds() ![2]c_int {
    var fds: [2]c_int = undefined;
    _ = try sysfile.pipe(&fds);
    _ = try sysfile.close(fds[1]);
    return .{ fds[0], try sysfile.dup(fds[0], -1) };
}

test "FIFO opens meet in one pipe, and a nonblocking writer needs a reader [kernel-port]" {
    _ = try kt.namespace();
    const fds = try twoFds();
    try testing.expect(!try isfifo(fds[0])); // the namespace kernel has no FIFO files

    try testing.expectError(error.Kernel, fifojoin(fds[1], c.OWRITE, true));
    try testing.expectEqualStrings("no reader", kt.errstr());
    try fifojoin(fds[0], c.OREAD, true);
    try fifojoin(fds[1], c.OWRITE, true);
    try testing.expectEqual(3, try sysfile.pwrite(fds[1], "abc", 3, -1));
    var buf: [8]u8 = undefined;
    try testing.expectEqual(3, try sysfile.pread(fds[0], &buf, buf.len, -1));
    try testing.expectEqualStrings("abc", buf[0..3]);
    _ = try sysfile.close(fds[0]);
    _ = try sysfile.close(fds[1]);

    // Nothing has it open: the next join's gc drops the entry.
    sync.qlock(&fifolk);
    fifogc();
    sync.qunlock(&fifolk);
}

test "a FIFO read open waits for a writer, and a note interrupts it [kernel-port]" {
    const me = try kt.namespace();
    const fds = try twoFds();
    const T = struct {
        fn run(fg: *c.Fgrp, fd: c_int, out: *?Error) void {
            up().fgrp = fg;
            out.* = null;
            fifojoin(fd, c.OREAD, false) catch |e| {
                out.* = e;
            };
        }
    };
    var err: ?Error = null;
    var k: kt.Kproc = undefined;
    try k.start(T.run, .{ me.fgrp, fds[0], &err });
    try kt.waitAsleep(k.proc());
    sync.procinterrupt(k.proc());
    k.join();
    try testing.expectEqual(error.Interrupted, err.?);
    k.proc().fgrp = null;

    // Again, and a writer's open lets it go.
    try k.start(T.run, .{ me.fgrp, fds[0], &err });
    try kt.waitAsleep(k.proc());
    try fifojoin(fds[1], c.OWRITE, false);
    k.join();
    k.proc().fgrp = null;
    try testing.expectEqual(null, err);
    try testing.expectEqual(1, try sysfile.pwrite(fds[1], "z", 1, -1));
    var buf: [2]u8 = undefined;
    try testing.expectEqual(1, try sysfile.pread(fds[0], &buf, buf.len, -1));
    _ = try sysfile.close(fds[0]);
    _ = try sysfile.close(fds[1]);
}
