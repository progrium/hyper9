//! The devices of src/kern/gfx.c in Zig (design/kernel-port.md): drawterm's
//! devdraw, devcons, devkbd, and devmouse as h9 serves them when a GUI
//! backend is built in (design/epoch-0/gfx.md). Each is a native device
//! wrapping the C one, which the device switch calls through dev.zig's
//! `raising`:
//!
//! - #i opens the screen at its first walk, not its attach, and adds
//!   /dev/screen (design/epoch-0/headless-screen.md).
//! - #c limits /dev/snarf to the machine with the screen.
//! - #b serves kbdfs's format on /dev/kbd, and adds /dev/kbdin.
//! - #m adds /dev/mousein.
//!
//! A close translation: the same functions in the same order, with error
//! unions for the C's error labels. gfx.c keeps the screen interface the
//! backends call and are called by (screeninit, attachscreen, the
//! clipboard, and the rest), which never sets an error label, and the two
//! calls here that need the screen's image (h9_gfx_screenshot and
//! h9_gfx_mousein), which don't raise.
//!
//! In builds with a screen only: -Dgfx=none has devtab.c name the C
//! devices themselves.

const std = @import("std");
const port = @import("../port.zig");
const sync = @import("../sync.zig");
const dev = @import("../dev.zig");
const pgrp = @import("../pgrp.zig");
const qio = @import("../qio.zig");
const c = port.c;
const up = port.up;
const Error = port.Error;

const Chan = c.Chan;
const Dir = c.Dir;
const Dirtab = c.Dirtab;
const Walkqid = c.Walkqid;
const Qid = c.Qid;
const Queue = qio.Queue;
const Rune = c_uint;

// drawterm's devices, which these wrap.
extern var drawdevtab: c.Dev;
extern var consdevtab: c.Dev;
extern var kbddevtab: c.Dev;
extern var mousedevtab: c.Dev;
extern var snarftab: *Dirtab; // devcons.c's /dev/snarf

// src/kern/gfx.c: the screen's image, under drawlock.
extern fn h9_gfx_screenshot(np: *c_int, err: *[*:0]const u8) ?[*]u8;
extern fn h9_gfx_mousein(kind: c_int, x: c_int, y: c_int, b: c_int, msec: c_uint) void;

extern fn strtol(s: [*:0]const u8, end: ?*[*:0]u8, base: c_int) c_long;
extern fn strtoll(s: [*:0]const u8, end: ?*[*:0]u8, base: c_int) c_longlong;

fn devreset_(d: *c.Dev) void {
    d.reset.?();
}
fn devinit_(d: *c.Dev) void {
    d.init.?();
}
fn devshutdown_(d: *c.Dev) void {
    d.shutdown.?();
}

// #i attaches without opening the screen: devdraw's attach opens it, so
// the namespace's bind of #i would open a window for every --gfx run.
// It's opened at the first walk into #i instead, which every draw client
// makes, so a program that never draws opens no window. Listing /dev
// reads #i's own directory, which needs no screen.

var drawopenlk: c.QLock = std.mem.zeroes(c.QLock);
var drawopened = std.atomic.Value(bool).init(false);

fn drawensure() Error!void {
    if (drawopened.load(.acquire))
        return;
    sync.qlock(&drawopenlk);
    defer sync.qunlock(&drawopenlk);
    if (!drawopened.load(.acquire)) {
        const ch = try dev.attach(&drawdevtab, "");
        port.chan.cclose(ch);
        drawopened.store(true, .release);
    }
}

fn lazyattach(spec: [*:0]const u8) Error!*Chan {
    return dev.devattach('i', spec);
}

// /dev/screen (design/epoch-0/headless-screen.md): #i's top directory
// gains a third file beside draw and winname, the screen as an
// uncompressed image(6) file, as 9front's /dev/screen is. Each open takes
// a copy of the screen under drawlock, so a read sees one consistent
// frame, and reads come from that copy. Its qid is above any devdraw
// makes.
const QSCREEN: u64 = 1 << 40;

const Shot = struct {
    n: c_int,
    buf: [*]u8,
};

/// #i's top directory, as devdraw's drawgen makes it, with screen added.
fn topgen(ch: [*c]Chan, name: [*c]u8, tab: [*c]Dirtab, ntab: c_int, s: c_int, dp: [*c]Dir) callconv(.c) c_int {
    _ = name;
    _ = tab;
    _ = ntab;
    var q: Qid = .{ .path = 0, .vers = 0, .type = 0 };
    switch (s) {
        c.DEVDOTDOT => {
            dev.mkqid(&q, 0, 0, c.QTDIR);
            dev.devdir(ch, q, @constCast("#i"), 0, c.eve, 0o500, dp);
        },
        0 => {
            dev.mkqid(&q, 4, 0, c.QTDIR); // devdraw's Q2nd
            dev.devdir(ch, q, @constCast("draw"), 0, c.eve, 0o555, dp);
        },
        1 => {
            dev.mkqid(&q, 2, 0, c.QTFILE); // devdraw's Qwinname
            dev.devdir(ch, q, @constCast("winname"), 0, c.eve, 0o444, dp);
        },
        2 => {
            dev.mkqid(&q, @intCast(QSCREEN), 0, c.QTFILE);
            dev.devdir(ch, q, @constCast("screen"), 0, c.eve, 0o444, dp);
        },
        else => return -1,
    }
    return 1;
}

fn isscreen(ch: *Chan) bool {
    return ch.qid.path == QSCREEN;
}

fn screenshot() Error!*Shot {
    const sh: *Shot = @ptrCast(@alignCast(c.smalloc(@sizeOf(Shot))));
    var err: [*:0]const u8 = "";
    var n: c_int = 0;
    const buf = h9_gfx_screenshot(&n, &err) orelse {
        c.free(sh);
        return port.kerror(err);
    };
    sh.* = .{ .n = n, .buf = buf };
    return sh;
}

fn lazywalk(ch: *Chan, nc: ?*Chan, name: [*]const [*:0]const u8, nname: c_int) Error!?*Walkqid {
    if (nname == 0 and !drawopened.load(.acquire))
        return dev.devwalk(ch, nc, name, 0, null, 0, dev.devgenC());
    if (nname > 0 and ch.qid.path == 0 and dev.streq(name[0], "screen"))
        return dev.devwalk(ch, nc, name, nname, null, 0, &topgen);
    try drawensure();
    return dev.walkdev(&drawdevtab, ch, nc, name, nname);
}

/// #i's own directory, which lists draw, winname and screen without the screen.
fn istop(ch: *Chan) bool {
    return ch.qid.path == 0;
}

fn lazystat(ch: *Chan, db: [*]u8, n: c_int) Error!c_int {
    if (isscreen(ch))
        return dev.devstat(ch, db, n, null, 0, &topgen);
    if (!istop(ch))
        try drawensure();
    return dev.stat(&drawdevtab, ch, db, n);
}

fn lazyopen(ch_: *Chan, omode: c_int) Error!*Chan {
    if (isscreen(ch_)) {
        try drawensure();
        const ch = try dev.devopen(ch_, omode, null, 0, &topgen);
        dev.aux(ch).* = try screenshot();
        return ch;
    }
    if (!istop(ch_))
        try drawensure();
    return dev.open(&drawdevtab, ch_, omode);
}

fn lazyclose(ch: *Chan) Error!void {
    if (isscreen(ch)) {
        if ((ch.flag & c.COPEN) != 0) {
            if (dev.aux(ch).*) |a| {
                const sh: *Shot = @ptrCast(@alignCast(a));
                dev.aux(ch).* = null;
                c.free(sh.buf);
                c.free(sh);
            }
        }
        return;
    }
    return dev.close(&drawdevtab, ch);
}

fn lazyread(ch: *Chan, a: ?*anyopaque, n_: c_int, off: i64) Error!c_int {
    if (istop(ch) and (ch.qid.type & c.QTDIR) != 0)
        return dev.devdirread(ch, @ptrCast(a.?), n_, null, 0, &topgen);
    if (isscreen(ch)) {
        const sh: *Shot = @ptrCast(@alignCast(dev.aux(ch).* orelse return 0));
        if (off >= sh.n)
            return 0;
        var n = n_;
        if (n > sh.n - off)
            n = @intCast(sh.n - off);
        const o: usize = @intCast(off);
        @memcpy(@as([*]u8, @ptrCast(a.?))[0..@intCast(n)], sh.buf[o..][0..@intCast(n)]);
        return n;
    }
    return dev.read(&drawdevtab, ch, a, n_, off);
}

fn lazywrite(ch: *Chan, a: ?*const anyopaque, n: c_int, off: i64) Error!c_int {
    if (isscreen(ch))
        return port.kerror(&port.Eperm);
    return dev.write(&drawdevtab, ch, a, n, off);
}

fn lazyreset() void {
    devreset_(&drawdevtab);
}

fn lazyinit() void {
    devinit_(&drawdevtab);
}

fn lazyshutdown() void {
    devshutdown_(&drawdevtab);
}

fn lazycreate(ch: *Chan, name: [*:0]const u8, omode: c_int, perm: c_uint) Error!*Chan {
    return dev.create(&drawdevtab, ch, name, omode, perm);
}

fn lazyremove(ch: *Chan) Error!void {
    return dev.remove(&drawdevtab, ch);
}

fn lazywstat(ch: *Chan, db: [*]u8, n: c_int) Error!c_int {
    if (isscreen(ch))
        return port.kerror(&port.Eperm);
    return dev.wstat(&drawdevtab, ch, db, n);
}

pub const Draw = dev.Native('i', "draw", .{
    .reset = lazyreset,
    .init = lazyinit,
    .shutdown = lazyshutdown,
    .attach = lazyattach,
    .walk = lazywalk,
    .stat = lazystat,
    .open = lazyopen,
    .create = lazycreate,
    .close = lazyclose,
    .read = lazyread,
    .write = lazywrite,
    .remove = lazyremove,
    .wstat = lazywstat,
    .gens = &.{&topgen},
});

// devcons serves /dev/snarf, from the clipboard, whenever there's a
// screen, and it's never masked. Opening it is limited to processes with
// #i unmasked, so only the machine with the window reaches the clipboard,
// and it opens the screen there: rio opens /dev/snarf before the display,
// and serves its own snarf buffer to its windows when that fails.

fn consopen(ch: *Chan, omode: c_int) Error!*Chan {
    if (ch.qid.path == snarftab.qid.path and (ch.qid.type & c.QTDIR) == 0) {
        if (pgrp.devmasked(up().pgrp, dev.devno('i')))
            return port.kerror(&port.Egreg);
        try drawensure();
    }
    return dev.open(&consdevtab, ch, omode);
}

fn consreset() void {
    devreset_(&consdevtab);
}
fn consinit() void {
    devinit_(&consdevtab);
}
fn consshutdown() void {
    devshutdown_(&consdevtab);
}
fn consattach(spec: [*:0]const u8) Error!*Chan {
    return dev.attach(&consdevtab, spec);
}
fn conswalk(ch: *Chan, nc: ?*Chan, name: [*]const [*:0]const u8, nname: c_int) Error!?*Walkqid {
    return dev.walkdev(&consdevtab, ch, nc, name, nname);
}
fn consstat(ch: *Chan, db: [*]u8, n: c_int) Error!c_int {
    return dev.stat(&consdevtab, ch, db, n);
}
fn conscreate(ch: *Chan, name: [*:0]const u8, omode: c_int, perm: c_uint) Error!*Chan {
    return dev.create(&consdevtab, ch, name, omode, perm);
}
fn consclose(ch: *Chan) Error!void {
    return dev.close(&consdevtab, ch);
}
fn consread(ch: *Chan, a: ?*anyopaque, n: c_int, off: i64) Error!c_int {
    return dev.read(&consdevtab, ch, a, n, off);
}
fn conswrite(ch: *Chan, a: ?*const anyopaque, n: c_int, off: i64) Error!c_int {
    return dev.write(&consdevtab, ch, a, n, off);
}
fn consremove(ch: *Chan) Error!void {
    return dev.remove(&consdevtab, ch);
}
fn conswstat(ch: *Chan, db: [*]u8, n: c_int) Error!c_int {
    return dev.wstat(&consdevtab, ch, db, n);
}

pub const Cons = dev.Native('c', "cons", .{
    .reset = consreset,
    .init = consinit,
    .shutdown = consshutdown,
    .attach = consattach,
    .walk = conswalk,
    .stat = consstat,
    .open = consopen,
    .create = conscreate,
    .close = consclose,
    .read = consread,
    .write = conswrite,
    .remove = consremove,
    .wstat = conswstat,
});

// /dev/kbd. drawterm's devkbd serves the window's keys as 'r' and 'R'
// messages (a rune pressed or released), the format 9front's kbdfs reads
// from the kernel. Programs read kbdfs's own: 'k' and 'K' with the keys
// held after a press or release, and 'c' for each character typed, which
// is how rio gets text for its windows. h9 runs no kbdfs, so #b serves
// that format itself: the backends' kbdkey comes here (gfx-gui.h), and
// devkbd is used only for its open, which allows one reader.
//
// While nothing has /dev/kbd open the keys are dropped. devkbd would put
// them on drawterm's console queue, whose echo writes them to the host's
// stdout, and nothing in h9 reads that queue (/dev/cons is #y).

// keyboard.h's
const KF = 0xF000;
const Spec = 0xF800;
const Kalt = KF | 0x15;
const Kshift = KF | 0x16;
const Kctl = KF | 0x17;
const Kcaps = Spec | 0x64;
const Knum = Spec | 0x65;
const Kaltgr = Spec | 0x67;
const Kmod4 = Spec | 0x68;
const UTFmax = 4;
const Runeerror = 0xFFFD;

var kbdlk: c.Lock = std.mem.zeroes(c.Lock);
var kbdopen: bool = false;
var kbdq9: ?*Queue = null;
var kbddown: [32]Rune = undefined;
var nkbddown: usize = 0;

const Qkbddir = 0; // devkbd.c's
const Qkbd = 1;
const Qkbdin = 0x10; // ours

/// devkbd's directory, with kbdin added (design/epoch-0/headless-screen.md).
var h9kbddir = [_]Dirtab{
    dev.dirtab(".", .{ .path = Qkbddir, .vers = 0, .type = c.QTDIR }, 0, dev.dmdir | 0o555),
    dev.dirtab("kbd", .{ .path = Qkbd, .vers = 0, .type = 0 }, 0, 0o444),
    dev.dirtab("kbdin", .{ .path = Qkbdin, .vers = 0, .type = 0 }, 0, 0o222),
};

fn ismod(r: Rune) bool {
    return switch (r) {
        Kshift, Kctl, Kalt, Kaltgr, Kmod4, Kcaps, Knum => true,
        else => false,
    };
}

fn isdown(r: Rune) bool {
    for (kbddown[0..nkbddown]) |k| {
        if (k == r)
            return true;
    }
    return false;
}

/// Queues 'k' or 'K' and the keys held. Called with kbdlk held.
fn kbdstate(ch: u8) void {
    var buf: [2 + kbddown.len * UTFmax]u8 = undefined;
    buf[0] = ch;
    var n: usize = 1;
    for (kbddown[0..nkbddown]) |*k|
        n += @intCast(c.runetochar(@ptrCast(&buf[n]), k));
    buf[n] = 0;
    n += 1;
    _ = qio.qproduce(kbdq9.?, &buf, @intCast(n));
}

fn kbdunhold(r: Rune) void {
    var i: usize = 0;
    while (i < nkbddown) {
        if (kbddown[i] == r) {
            std.mem.copyForwards(Rune, kbddown[i .. nkbddown - 1], kbddown[i + 1 .. nkbddown]);
            nkbddown -= 1;
        } else i += 1;
    }
}

fn h9_kbdkey(r: Rune, down: c_int) callconv(.c) void {
    if (r == 0 or !@atomicLoad(bool, &kbdopen, .acquire))
        return;
    c.lock(&kbdlk);
    defer c.unlock(&kbdlk);
    const q = kbdq9 orelse return;
    if (!kbdopen)
        return;
    if (down != 0) {
        if (!isdown(r) and nkbddown < kbddown.len) {
            kbddown[nkbddown] = r;
            nkbddown += 1;
            kbdstate('k');
        }
        if (!ismod(r)) {
            // ^X forms, as kbdfs makes them
            var ch = r;
            if (isdown(Kctl) and ch >= '@' and ch < 0x80 and ch != 0x7F)
                ch &= 0x1F;
            var buf: [1 + UTFmax + 1]u8 = undefined;
            buf[0] = 'c';
            var n: usize = 1 + @as(usize, @intCast(c.runetochar(@ptrCast(&buf[1]), &ch)));
            buf[n] = 0;
            n += 1;
            _ = qio.qproduce(q, &buf, @intCast(n));
        }
    } else {
        // A key pressed with shift held may be released without it.
        const n = nkbddown;
        kbdunhold(r);
        if (r >= 'a' and r <= 'z')
            kbdunhold(r - 'a' + 'A')
        else if (r >= 'A' and r <= 'Z')
            kbdunhold(r - 'A' + 'a');
        if (nkbddown != n)
            kbdstate('K');
    }
}

fn kbdopen_(ch_: *Chan, omode: c_int) Error!*Chan {
    if (ch_.qid.path == Qkbdin)
        return dev.devopen(ch_, omode, &h9kbddir, h9kbddir.len, dev.devgenC());
    const ch = try dev.open(&kbddevtab, ch_, omode);
    if (ch.qid.path == Qkbd) {
        c.lock(&kbdlk);
        if (kbdq9) |q| {
            // qreopen keeps what the last reader left unread, so without
            // the flush a new reader starts mid-key, with the 'c' or 'K'
            // of a key typed for someone else.
            qio.qflush(q);
            qio.qreopen(q);
        } else {
            // Room for a burst of keys (each is up to three messages) on a slow machine.
            kbdq9 = qio.qopen(64 * 1024, c.Qmsg, null, null);
            if (kbdq9) |q|
                qio.qnoblock(q, 1);
        }
        nkbddown = 0;
        @atomicStore(bool, &kbdopen, true, .release);
        c.unlock(&kbdlk);
    }
    return ch;
}

fn kbdclose_(ch: *Chan) Error!void {
    if (ch.qid.path == Qkbdin)
        return;
    if (ch.qid.path == Qkbd and (ch.flag & c.COPEN) != 0) {
        c.lock(&kbdlk);
        @atomicStore(bool, &kbdopen, false, .release);
        if (kbdq9) |q|
            qio.qhangup(q, null);
        c.unlock(&kbdlk);
    }
    return dev.close(&kbddevtab, ch);
}

fn kbdread_(ch: *Chan, a: ?*anyopaque, n: c_int, off: i64) Error!c_int {
    if ((ch.qid.type & c.QTDIR) != 0)
        return dev.devdirread(ch, @ptrCast(a.?), n, &h9kbddir, h9kbddir.len, dev.devgenC());
    if (ch.qid.path == Qkbd) {
        const q = kbdq9 orelse return port.kerror(&port.Egreg);
        return qio.qread(q, @ptrCast(a.?), n);
    }
    return dev.read(&kbddevtab, ch, a, n, off);
}

/// A kbdfs message passed through to /dev/kbd's reader as it is.
fn kbdmsg(m: []const u8) void {
    c.lock(&kbdlk);
    if (kbdq9) |q| {
        if (kbdopen)
            _ = qio.qproduce(q, m.ptr, @intCast(m.len));
    }
    c.unlock(&kbdlk);
}

/// /dev/kbdin, as kbdfs's kbdin reads it: a write that doesn't end in a
/// NUL is text, each rune typed (pressed, then released); one that does
/// is NUL-terminated messages, 'r' and 'R' with a rune pressed or
/// released, 'c' with a rune typed without key state, and any other
/// ('k' and 'K' with the keys held) passed to /dev/kbd's reader as it is.
fn kbdinwrite(a: [*]const u8, n: c_int) c_int {
    if (n <= 0)
        return n;
    const un: usize = @intCast(n);
    const s: [*]u8 = @ptrCast(c.smalloc(@intCast(un + 1)));
    defer c.free(s);
    @memcpy(s[0..un], a[0..un]);
    s[un] = 0;
    var r: Rune = undefined;
    if (s[un - 1] != 0) {
        var p: usize = 0;
        while (s[p] != 0) {
            p += @intCast(c.chartorune(&r, @ptrCast(s + p)));
            if (r == 0 or r == Runeerror)
                continue;
            h9_kbdkey(r, 1);
            h9_kbdkey(r, 0);
        }
    } else {
        var p: usize = 0;
        while (p < un) {
            const m = std.mem.len(@as([*:0]u8, @ptrCast(s + p))) + 1;
            defer p += m;
            if (m < 2)
                continue;
            switch (s[p]) {
                'r', 'R' => {
                    _ = c.chartorune(&r, @ptrCast(s + p + 1));
                    if (r != 0)
                        h9_kbdkey(r, @intFromBool(s[p] == 'r'));
                },
                else => kbdmsg(s[p..][0..m]),
            }
        }
    }
    return n;
}

fn kbdwrite_(ch: *Chan, a: ?*const anyopaque, n: c_int, off: i64) Error!c_int {
    if (ch.qid.path == Qkbdin)
        return kbdinwrite(@ptrCast(a.?), n);
    return dev.write(&kbddevtab, ch, a, n, off);
}

fn kbdwalk_(ch: *Chan, nc: ?*Chan, name: [*]const [*:0]const u8, nname: c_int) Error!?*Walkqid {
    return dev.devwalk(ch, nc, name, nname, &h9kbddir, h9kbddir.len, dev.devgenC());
}

fn kbdstat_(ch: *Chan, db: [*]u8, n: c_int) Error!c_int {
    return dev.devstat(ch, db, n, &h9kbddir, h9kbddir.len, dev.devgenC());
}

fn kbdreset_() void {
    devreset_(&kbddevtab);
}
fn kbdinit_() void {
    devinit_(&kbddevtab);
}
fn kbdshutdown_() void {
    devshutdown_(&kbddevtab);
}
fn kbdattach_(spec: [*:0]const u8) Error!*Chan {
    return dev.attach(&kbddevtab, spec);
}
fn kbdcreate_(ch: *Chan, name: [*:0]const u8, omode: c_int, perm: c_uint) Error!*Chan {
    return dev.create(&kbddevtab, ch, name, omode, perm);
}
fn kbdremove_(ch: *Chan) Error!void {
    return dev.remove(&kbddevtab, ch);
}
fn kbdwstat_(ch: *Chan, db: [*]u8, n: c_int) Error!c_int {
    return dev.wstat(&kbddevtab, ch, db, n);
}

pub const Kbd = dev.Native('b', "kbd", .{
    .reset = kbdreset_,
    .init = kbdinit_,
    .shutdown = kbdshutdown_,
    .attach = kbdattach_,
    .walk = kbdwalk_,
    .stat = kbdstat_,
    .open = kbdopen_,
    .create = kbdcreate_,
    .close = kbdclose_,
    .read = kbdread_,
    .write = kbdwrite_,
    .remove = kbdremove_,
    .wstat = kbdwstat_,
});

// /dev/mousein (design/epoch-0/headless-screen.md), beside devmouse's
// files, as 9front's devmouse serves it: each write is one event in
// /dev/mouse's format, 'A' then x, y, buttons and msec for the pointer at
// x, y, 'a' for x and y scaled from 0 to 2^31 across the screen, and any
// other letter (/dev/mouse's 'm') for x and y relative to where it is. A
// msec of 0 is now. They move the kernel's pointer, as the window's
// events do, never the host's.

const Qmousedir = 0; // devmouse.c's
const Qcursor = 1;
const Qmouse = 2;
const Qmousectl = 3;
const Qmousein = 0x10; // ours

var h9mousedir = [_]Dirtab{
    dev.dirtab(".", .{ .path = Qmousedir, .vers = 0, .type = c.QTDIR }, 0, dev.dmdir | 0o555),
    dev.dirtab("cursor", .{ .path = Qcursor, .vers = 0, .type = 0 }, 0, 0o666),
    dev.dirtab("mouse", .{ .path = Qmouse, .vers = 0, .type = 0 }, 0, 0o666),
    dev.dirtab("mousectl", .{ .path = Qmousectl, .vers = 0, .type = 0 }, 0, 0o222),
    dev.dirtab("mousein", .{ .path = Qmousein, .vers = 0, .type = 0 }, 0, 0o222),
};

fn mouseinwrite(a: [*]const u8, n_: c_int) Error!c_int {
    // The pointer stays put until there's a screen to move it on.
    try drawensure();
    var buf: [64]u8 = undefined;
    var n = n_;
    if (n > buf.len - 1)
        n = buf.len - 1;
    const un: usize = @intCast(@max(n, 0));
    @memcpy(buf[0..un], a[0..un]);
    buf[un] = 0;
    var p: [*:0]u8 = @ptrCast(&buf[1]);
    const x: c_int = @truncate(strtol(p, &p, 0));
    if (p[0] == 0)
        return port.kerror(&port.Eshort);
    const y: c_int = @truncate(strtol(p, &p, 0));
    if (p[0] == 0)
        return port.kerror(&port.Eshort);
    const b: c_int = @truncate(strtol(p, &p, 0));
    const msec: c_uint = @truncate(@as(c_ulonglong, @bitCast(strtoll(p, null, 0))));
    h9_gfx_mousein(buf[0], x, y, b, msec);
    return n;
}

fn mousewalk_(ch: *Chan, nc: ?*Chan, name: [*]const [*:0]const u8, nname: c_int) Error!?*Walkqid {
    return dev.devwalk(ch, nc, name, nname, &h9mousedir, h9mousedir.len, dev.devgenC());
}

fn mousestat_(ch: *Chan, db: [*]u8, n: c_int) Error!c_int {
    return dev.devstat(ch, db, n, &h9mousedir, h9mousedir.len, dev.devgenC());
}

fn mouseopen_(ch: *Chan, omode: c_int) Error!*Chan {
    if (ch.qid.path == Qmousein)
        return dev.devopen(ch, omode, &h9mousedir, h9mousedir.len, dev.devgenC());
    return dev.open(&mousedevtab, ch, omode);
}

fn mouseclose_(ch: *Chan) Error!void {
    if (ch.qid.path == Qmousein)
        return;
    return dev.close(&mousedevtab, ch);
}

fn mouseread_(ch: *Chan, a: ?*anyopaque, n: c_int, off: i64) Error!c_int {
    if ((ch.qid.type & c.QTDIR) != 0)
        return dev.devdirread(ch, @ptrCast(a.?), n, &h9mousedir, h9mousedir.len, dev.devgenC());
    return dev.read(&mousedevtab, ch, a, n, off);
}

fn mousewrite_(ch: *Chan, a: ?*const anyopaque, n: c_int, off: i64) Error!c_int {
    if (ch.qid.path == Qmousein)
        return mouseinwrite(@ptrCast(a.?), n);
    return dev.write(&mousedevtab, ch, a, n, off);
}

fn mousereset_() void {
    devreset_(&mousedevtab);
}
fn mouseinit_() void {
    devinit_(&mousedevtab);
}
fn mouseshutdown_() void {
    devshutdown_(&mousedevtab);
}
fn mouseattach_(spec: [*:0]const u8) Error!*Chan {
    return dev.attach(&mousedevtab, spec);
}
fn mousecreate_(ch: *Chan, name: [*:0]const u8, omode: c_int, perm: c_uint) Error!*Chan {
    return dev.create(&mousedevtab, ch, name, omode, perm);
}
fn mouseremove_(ch: *Chan) Error!void {
    return dev.remove(&mousedevtab, ch);
}
fn mousewstat_(ch: *Chan, db: [*]u8, n: c_int) Error!c_int {
    return dev.wstat(&mousedevtab, ch, db, n);
}

pub const Mouse = dev.Native('m', "mouse", .{
    .reset = mousereset_,
    .init = mouseinit_,
    .shutdown = mouseshutdown_,
    .attach = mouseattach_,
    .walk = mousewalk_,
    .stat = mousestat_,
    .open = mouseopen_,
    .create = mousecreate_,
    .close = mouseclose_,
    .read = mouseread_,
    .write = mousewrite_,
    .remove = mouseremove_,
    .wstat = mousewstat_,
});

pub fn exportC() void {
    @export(&Draw.dev, .{ .name = "h9drawdevtab" });
    @export(&Cons.dev, .{ .name = "h9consdevtab" });
    @export(&Kbd.dev, .{ .name = "h9kbddevtab" });
    @export(&Mouse.dev, .{ .name = "h9mousedevtab" });
    @export(&h9_kbdkey, .{ .name = "h9_kbdkey" });
}
