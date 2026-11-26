//! h9's #y, a machine's console (src/kern/devhcons.c,
//! design/kernel-port.md). A close translation of the C: the same
//! functions in the same order, with error unions in place of C's error labels.
//! A native device (dev.zig's `Native`).
//!
//! drawterm's #c/cons reads and writes the host process's fds 0 and 1;
//! this device serves each machine's Stdio instead, through calls into
//! src/kern.zig. The namespace builder binds it over /dev, so /dev/cons
//! is this device and the rest of #c stays visible.
//!
//! The attach spec names the machine: #y<id>. The calls into kern.zig
//! never fail with a kernel error; they return -1 and this file makes it
//! one.
//!
//! A read never blocks in a host call: a reader thread in Zig
//! (src/consin.zig) reads the host stream, and the guest sleeps here
//! until it has input, so a note or a teardown interrupts the read with
//! Eintr. Processes in a tree share the console, so readers take turns.
//! A QLock can't be interrupted and a Rendez holds only one sleeper, so a
//! reader waiting for its turn sleeps in short slices and checks for a
//! note.
//!
//! The namespace kernel has no console, so it builds none of this but
//! the cases, which run on a console of their own.

const std = @import("std");
const builtin = @import("builtin");
const port = @import("../port.zig");
const sync = @import("../sync.zig");
const dev = @import("../dev.zig");
const c = port.c;
const up = port.up;
const Error = port.Error;

const Chan = c.Chan;
const Dirtab = c.Dirtab;
const Walkqid = c.Walkqid;

// Implemented in Zig (src/kern.zig), with 64-bit counts: the C declared
// them with drawterm's long, which is C's int.
extern fn h9_cons_read(machine: c_ulong, buf: ?*anyopaque, n: c_long) c_long;
extern fn h9_cons_ready(machine: c_ulong) c_int;
extern fn h9_cons_write(machine: c_ulong, fd: c_int, buf: ?*const anyopaque, n: c_long) c_long;
extern fn h9_cons_raw(machine: c_ulong, on: c_int) void;
extern fn h9_cons_echo(machine: c_ulong, on: c_int) void;

const Maxcons = 64; // src/kern.zig's max_consoles
const Wouldblock = -2;

const Hcons = struct {
    lk: c.Lock = std.mem.zeroes(c.Lock),
    busy: bool = false, // a reader has its turn
    nctl: c_int = 0, // open consctl files; the last close turns raw off
    r: c.Rendez = std.mem.zeroes(c.Rendez), // the reader with the turn, waiting for input
};

var hcons: [Maxcons]Hcons = @splat(.{});

fn ready(a: ?*anyopaque) callconv(.c) c_int {
    const h: *Hcons = @ptrCast(@alignCast(a));
    return h9_cons_ready(@intCast((@intFromPtr(h) - @intFromPtr(&hcons)) / @sizeOf(Hcons)));
}

// Called by the reader thread (not a Proc) when input arrives.
extern fn h9_pollwake() void;

fn h9_cons_wake(id: c_ulong) callconv(.c) void {
    if (id < Maxcons)
        _ = sync.wakeup(&hcons[id].r);
    h9_pollwake(); // a Linux poll or epoll on the console (linuxnet.zig)
}

fn taketurn(h: *Hcons) Error!void {
    while (true) {
        c.lock(&h.lk);
        if (!h.busy) {
            h.busy = true;
            c.unlock(&h.lk);
            return;
        }
        c.unlock(&h.lk);
        if (up().notepending != 0) {
            up().notepending = 0;
            return port.interrupted();
        }
        c.osmsleep(5);
    }
}

fn giveturn(h: *Hcons) void {
    c.lock(&h.lk);
    h.busy = false;
    c.unlock(&h.lk);
}

fn consread(id: c_ulong, va: ?*anyopaque, n: c_int) Error!c_int {
    if (id >= Maxcons)
        return port.kerror(&port.Eio);
    const h = &hcons[id];
    try taketurn(h);
    const r = blk: {
        defer giveturn(h);
        while (true) {
            const r = h9_cons_read(id, va, n);
            if (r != Wouldblock) break :blk r;
            try sync.sleep(&h.r, ready, h);
        }
    };
    if (r < 0)
        return port.kerror(&port.Eio);
    return @intCast(r);
}

const Qdir = 0;
const Qcons = 1;
const Qconsctl = 2;
const Qstderr = 3; // h9 extension: writes go to the host stderr

var hconsdir = [_]Dirtab{
    dev.dirtab(".", .{ .path = Qdir, .vers = 0, .type = c.QTDIR }, 0, dev.dmdir | 0o555),
    dev.dirtab("cons", .{ .path = Qcons, .vers = 0, .type = 0 }, 0, 0o660),
    dev.dirtab("consctl", .{ .path = Qconsctl, .vers = 0, .type = 0 }, 0, 0o220),
    dev.dirtab("stderr", .{ .path = Qstderr, .vers = 0, .type = 0 }, 0, 0o220),
};

fn hconsattach(spec: [*:0]const u8) Error!*Chan {
    var e: [*c]u8 = undefined;
    const id = c.strtoul(spec, &e, 10);
    if (spec[0] == 0 or e.* != 0)
        return port.kerror(&port.Ebadspec);
    const ch = dev.devattach('y', spec);
    ch.dev = @intCast(id);
    return ch;
}

fn hconswalk(ch: *Chan, nc: ?*Chan, name: [*]const [*:0]const u8, nname: c_int) Error!?*Walkqid {
    return dev.devwalk(ch, nc, name, nname, &hconsdir, hconsdir.len, dev.devgenC());
}

fn hconsstat(ch: *Chan, db: [*]u8, n: c_int) Error!c_int {
    return dev.devstat(ch, db, n, &hconsdir, hconsdir.len, dev.devgenC());
}

fn hconsopen(ch_: *Chan, omode: c_int) Error!*Chan {
    const ch = try dev.devopen(ch_, omode, &hconsdir, hconsdir.len, dev.devgenC());
    if (ch.qid.path == Qconsctl and ch.dev < Maxcons) {
        const h = &hcons[ch.dev];
        c.lock(&h.lk);
        h.nctl += 1;
        c.unlock(&h.lk);
    }
    return ch;
}

/// As drawterm's and 9front's: the last close of consctl turns raw off,
/// and echo back on.
fn hconsclose(ch: *Chan) Error!void {
    if (ch.qid.path != Qconsctl or (ch.flag & c.COPEN) == 0 or ch.dev >= Maxcons)
        return;
    const h = &hcons[ch.dev];
    c.lock(&h.lk);
    h.nctl -= 1;
    const last = h.nctl == 0;
    c.unlock(&h.lk);
    if (last) {
        h9_cons_raw(ch.dev, 0);
        h9_cons_echo(ch.dev, 1);
    }
}

/// consctl: rawon and rawoff, separated by spaces, as drawterm's, and
/// h9's echooff and echoon, which keep the line discipline.
fn consctl(id: c_ulong, a: [*]const u8, n_: c_int) void {
    var buf: [256]u8 = undefined;
    const n: usize = @min(@as(usize, @intCast(@max(n_, 0))), buf.len - 1);
    @memcpy(buf[0..n], a[0..n]);
    buf[n] = 0;
    const s = std.mem.sliceTo(&buf, 0);
    var i: usize = 0;
    while (true) {
        const w = s[i..];
        if (std.mem.startsWith(u8, w, "rawon"))
            h9_cons_raw(id, 1)
        else if (std.mem.startsWith(u8, w, "rawoff"))
            h9_cons_raw(id, 0)
        else if (std.mem.startsWith(u8, w, "echooff"))
            h9_cons_echo(id, 0)
        else if (std.mem.startsWith(u8, w, "echoon"))
            h9_cons_echo(id, 1);
        i += 1 + (std.mem.indexOfScalar(u8, w, ' ') orelse break);
    }
}

fn hconsread(ch: *Chan, va: ?*anyopaque, n: c_int, off: i64) Error!c_int {
    _ = off;
    switch (ch.qid.path) {
        Qdir => return dev.devdirread(ch, @ptrCast(va.?), n, &hconsdir, hconsdir.len, dev.devgenC()),
        Qcons => return consread(ch.dev, va, n),
        else => {},
    }
    return port.kerror(&port.Egreg);
}

fn hconswrite(ch: *Chan, va: ?*const anyopaque, n: c_int, off: i64) Error!c_int {
    _ = off;
    switch (ch.qid.path) {
        Qcons, Qstderr => {
            const r = h9_cons_write(ch.dev, if (ch.qid.path == Qcons) 1 else 2, va, n);
            if (r < 0)
                return port.kerror(&port.Eio);
            return @intCast(r);
        },
        Qconsctl => {
            consctl(ch.dev, @ptrCast(va.?), n);
            return n;
        },
        else => {},
    }
    return port.kerror(&port.Egreg);
}

pub const Device = dev.Native('y', "hcons", .{
    .attach = hconsattach,
    .walk = hconswalk,
    .stat = hconsstat,
    .open = hconsopen,
    .create = dev.devcreate,
    .close = hconsclose,
    .read = hconsread,
    .write = hconswrite,
    .remove = dev.devremove,
    .wstat = dev.devwstat,
});

pub fn exportC() void {
    @export(&Device.dev, .{ .name = "hconsdevtab" });
    @export(&h9_cons_wake, .{ .name = "h9_cons_wake" });
}

// Cases (zig build kern-test), on a console of their own in place of
// src/kern.zig's: machine 3's input is `input`, a read of nothing would
// block until `available`, and writes and modes are recorded.

const fake = struct {
    var input: []const u8 = "";
    var available: std.atomic.Value(bool) = .init(true);
    var out: [2][64]u8 = undefined;
    var nout: [2]usize = .{ 0, 0 };
    var raw: c_int = -1;
    var echo: c_int = -1;
    var pollwakes: usize = 0;

    fn read(id: c_ulong, buf: ?*anyopaque, n: c_long) callconv(.c) c_long {
        if (id != 3) return -1;
        if (!available.load(.acquire)) return Wouldblock;
        const k = @min(input.len, @as(usize, @intCast(n)));
        @memcpy(@as([*]u8, @ptrCast(buf.?))[0..k], input[0..k]);
        input = input[k..];
        return @intCast(k);
    }
    fn isready(id: c_ulong) callconv(.c) c_int {
        _ = id;
        return @intFromBool(available.load(.acquire));
    }
    fn write(id: c_ulong, fd: c_int, buf: ?*const anyopaque, n: c_long) callconv(.c) c_long {
        if (id != 3) return -1;
        const i: usize = @intCast(fd - 1);
        const k: usize = @intCast(n);
        @memcpy(out[i][nout[i]..][0..k], @as([*]const u8, @ptrCast(buf.?))[0..k]);
        nout[i] += k;
        return n;
    }
    fn setraw(id: c_ulong, on: c_int) callconv(.c) void {
        _ = id;
        raw = on;
    }
    fn setecho(id: c_ulong, on: c_int) callconv(.c) void {
        _ = id;
        echo = on;
    }
    fn pollwake() callconv(.c) void {
        pollwakes += 1;
    }
};

comptime {
    if (builtin.is_test and port.nskernel) {
        @export(&fake.read, .{ .name = "h9_cons_read" });
        @export(&fake.isready, .{ .name = "h9_cons_ready" });
        @export(&fake.write, .{ .name = "h9_cons_write" });
        @export(&fake.setraw, .{ .name = "h9_cons_raw" });
        @export(&fake.setecho, .{ .name = "h9_cons_echo" });
        @export(&fake.pollwake, .{ .name = "h9_pollwake" });
    }
}

const testing = std.testing;
const kt = port.testing;
const chan = @import("../chan.zig");

/// A chan of console 3's file `path`, as a walk from #y3 makes it: the
/// namespace kernel's device table has no #y.
fn testChan(path: u64) *Chan {
    const ch = chan.newchan();
    ch.dev = 3;
    ch.qid = .{ .path = path, .vers = 0, .type = 0 };
    return ch;
}

test "#y reads its machine's input, and writes cons and stderr apart [kernel-port]" {
    _ = try kt.begin();
    fake.input = "hello";
    fake.available.store(true, .release);
    fake.nout = .{ 0, 0 };
    const cons = testChan(Qcons);
    defer chan.cclose(cons);
    var buf: [8]u8 = undefined;
    try testing.expectEqual(5, try hconsread(cons, &buf, buf.len, 0));
    try testing.expectEqualStrings("hello", buf[0..5]);
    try testing.expectEqual(0, try hconsread(cons, &buf, buf.len, 0));

    try testing.expectEqual(2, try hconswrite(cons, "ab", 2, 0));
    const stderr = testChan(Qstderr);
    defer chan.cclose(stderr);
    try testing.expectEqual(1, try hconswrite(stderr, "c", 1, 0));
    try testing.expectEqualStrings("ab", fake.out[0][0..fake.nout[0]]);
    try testing.expectEqualStrings("c", fake.out[1][0..fake.nout[1]]);

    // Another machine's console, or none, is Eio.
    cons.dev = 4;
    try testing.expectError(error.Kernel, hconsread(cons, &buf, buf.len, 0));
    try testing.expectEqualStrings("i/o error", kt.errstr());
    cons.dev = Maxcons;
    try testing.expectError(error.Kernel, hconsread(cons, &buf, buf.len, 0));
    cons.dev = 3;
}

test "a #y read sleeps until input, and a note interrupts it and gives up its turn [kernel-port]" {
    _ = try kt.begin();
    fake.input = "x";
    fake.available.store(false, .release);
    const T = struct {
        fn run(out: *?Error, got: *c_int) void {
            out.* = null;
            const ch = testChan(Qcons);
            defer chan.cclose(ch);
            var b: [4]u8 = undefined;
            got.* = hconsread(ch, &b, b.len, 0) catch |e| blk: {
                out.* = e;
                break :blk -1;
            };
        }
    };
    var err: ?Error = null;
    var got: c_int = 0;
    var k: kt.Kproc = undefined;
    try k.start(T.run, .{ &err, &got });
    try kt.waitAsleep(k.proc());
    sync.procinterrupt(k.proc());
    k.join();
    try testing.expectEqual(error.Interrupted, err.?);
    try testing.expect(!hcons[3].busy);

    // Input wakes a sleeping reader, and its poller.
    try k.start(T.run, .{ &err, &got });
    try kt.waitAsleep(k.proc());
    fake.available.store(true, .release);
    const wakes = fake.pollwakes;
    h9_cons_wake(3);
    k.join();
    try testing.expectEqual(null, err);
    try testing.expectEqual(1, got);
    try testing.expectEqual(wakes + 1, fake.pollwakes);
    try testing.expect(!hcons[3].busy);
}

test "a #y reader waiting for its turn sees a note [kernel-port]" {
    const me = try kt.begin();
    hcons[3].busy = true;
    defer hcons[3].busy = false;
    me.notepending = 1;
    const ch = testChan(Qcons);
    defer chan.cclose(ch);
    var b: [4]u8 = undefined;
    try testing.expectError(error.Interrupted, hconsread(ch, &b, b.len, 0));
    try testing.expectEqual(0, me.notepending);
    try testing.expectEqualStrings("interrupted", kt.errstr());
}

test "consctl sets raw and echo, and its last close turns raw off [kernel-port]" {
    _ = try kt.begin();
    const ch = testChan(Qconsctl);
    defer chan.cclose(ch);
    hcons[3].nctl = 2;
    ch.flag |= c.COPEN;
    const msg = "rawon echooff";
    try testing.expectEqual(@as(c_int, msg.len), try hconswrite(ch, msg, msg.len, 0));
    try testing.expectEqual(1, fake.raw);
    try testing.expectEqual(0, fake.echo);
    try hconsclose(ch);
    try testing.expectEqual(1, fake.raw);
    try hconsclose(ch);
    try testing.expectEqual(0, fake.raw);
    try testing.expectEqual(1, fake.echo);
    try testing.expectEqual(0, hcons[3].nctl);
    ch.flag &= ~@as(c_ushort, c.COPEN);
}
