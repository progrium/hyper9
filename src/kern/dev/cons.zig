//! drawterm's devcons, `#c`, ported to Zig as a native device
//! (design/kernel-port.md): a close translation, the same functions in
//! the same order, with error unions in place of C's error labels, and
//! with h9's changes in place of the patches drawterm's file carried:
//! `pid` and `ppid`, the nanosecond `time` and `bintime`, and a
//! `sysstat` line per CPU (src/kern/consx.c, design/epoch-0/go-compat.md),
//! and, in builds with a screen, `snarf` opened only where `#i` isn't
//! masked (src/kern/dev/gfx.zig).
//!
//! A guest's `/dev/cons` is `#y` (src/kern/dev/hcons.zig), bound before
//! this on /dev; `#c/cons` here reads and writes the host's fds 0 and 1,
//! as drawterm's does. The kernel's console globals (`kmesg`, `kbdq`,
//! `kprintoq`, `screenputs`, `sysname`, and `fasthz`) and the C calls
//! other files make (`putstrn`, `kbdputc`, `readnum`, `readstr`,
//! `return0`, and `printinit`) are exported here under their C names.
//! drawterm's variadic `print`, `iprint`, `pprint`, and `panic` stay C,
//! in src/kern/consprint.c, over `putstrn`.
//!
//! The namespace kernel has no console: src/kern/nstab.c stands in.

const std = @import("std");
const builtin = @import("builtin");
const port = @import("../port.zig");
const sync = @import("../sync.zig");
const qio = @import("../qio.zig");
const dev = @import("../dev.zig");
const chan = @import("../chan.zig");
const c = port.c;
const Error = port.Error;

const Chan = c.Chan;
const Dirtab = c.Dirtab;
const Walkqid = c.Walkqid;
const Queue = qio.Queue;

const windows = builtin.os.tag == .windows;

// The host's fds 0, 1, and 2, as drawterm's C reaches them (its read
// and write, past lib.h's renames).
const host = if (windows) struct {
    extern "c" fn _read(fd: c_int, buf: ?*anyopaque, n: c_uint) c_int;
    extern "c" fn _write(fd: c_int, buf: ?*const anyopaque, n: c_uint) c_int;
    fn read(fd: c_int, buf: [*]u8, n: c_int) c_int {
        return _read(fd, buf, @intCast(n));
    }
    fn write(fd: c_int, buf: [*]const u8, n: c_int) void {
        _ = _write(fd, buf, @intCast(n));
    }
} else struct {
    fn read(fd: c_int, buf: [*]u8, n: c_int) c_int {
        return @intCast(std.c.read(fd, buf, @intCast(n)));
    }
    fn write(fd: c_int, buf: [*]const u8, n: c_int) void {
        _ = std.c.write(fd, buf, @intCast(n));
    }
};

// src/kern/consx.c, h9's files (design/epoch-0/go-compat.md). Their
// long is drawterm's, which is C's int.
extern fn h9_cons_pid(off: c_uint, buf: [*]u8, n: c_int) c_int;
extern fn h9_cons_ppid(off: c_uint, buf: [*]u8, n: c_int) c_int;
extern fn h9_cons_bintime(buf: [*]u8, n: c_int) c_int;
extern fn h9_cons_time(off: c_uint, buf: [*]u8, n: c_int) c_int;
extern fn h9_cons_sysstat(off: c_uint, buf: [*]u8, n: c_int) c_int;

// The screen (screen.h), nil without one; the clipboard; and the rest of
// what devcons calls in drawterm's C.
extern var gscreen: ?*anyopaque;
extern fn clipread() ?[*:0]u8;
extern fn clipwrite(s: ?[*:0]u8) c_int;
extern fn latin1(k: [*]c.Rune, n: c_int) c_int;
extern fn panic(fmt: [*:0]const u8, ...) noreturn;
extern var eve: ?[*:0]u8;
extern var hostdomain: [48]u8;

// The kernel's console state, which other C names (dat.h and fns.h).
var screenputs: ?*const fn ([*c]u8, c_int) callconv(.c) void = null;
var kmesg: c.Kmesg = std.mem.zeroes(c.Kmesg); // console messages
var kbdq: ?*Queue = null; // unprocessed console input
var lineq: ?*Queue = null; // processed console input
var kprintoq: ?*Queue = null; // console output, for /dev/kprint
var kprintinuse: c_int = 0; // test and set whether /dev/kprint is open
var sysname: ?[*:0]u8 = null;
var fasthz: i64 = 1000;

const Kbd = struct {
    lk: c.QLock = std.mem.zeroes(c.QLock),
    raw: bool = false, // true if we shouldn't process input
    ctl: c_int = 0, // number of opens to the control file
    x: usize = 0, // index into line
    line: [1024]u8 = undefined, // current input line
};

var kbd: Kbd = .{};

fn return0(_: ?*anyopaque) callconv(.c) c_int {
    return 0;
}

fn printinit() callconv(.c) void {
    lineq = qio.qopen(2 * 1024, 0, null, null) orelse panic("printinit");
    qio.qnoblock(lineq.?, 1);

    kbdq = qio.qopen(4 * 1024, 0, null, null) orelse panic("kbdinit");
    qio.qnoblock(kbdq.?, 1);
}

fn kmesgputs(str_: [*]const u8, n_: c_int) void {
    var str = str_;
    var n: usize = @intCast(@max(n_, 0));
    const size = kmesg.buf.len;

    c.ilock(&kmesg.lk);
    defer c.iunlock(&kmesg.lk);
    // take the tail of huge writes
    if (n > size) {
        const d = n - size;
        str += d;
        n -= d;
    }

    // slide the buffer down to make room
    var nn: usize = kmesg.n;
    if (nn + n >= size) {
        const d = nn + n - size;
        if (d != 0) std.mem.copyForwards(u8, kmesg.buf[0 .. size - d], kmesg.buf[d..size]);
        nn -= d;
    }

    // copy the data in
    @memcpy(kmesg.buf[nn..][0..n], str[0..n]);
    nn += n;
    kmesg.n = @intCast(nn);
}

/// Prints a string on the console: into kmesg, and to /dev/kprint's
/// reader if there is one, else the screen, else the host's fd 1. With
/// `usewrite`, /dev/kprint's queue may block, which a write to /dev/cons
/// allows and an interrupt-time print doesn't.
fn putstrn0(str: [*]const u8, n: c_int, usewrite: bool) Error!void {
    kmesgputs(str, n);

    if (kprintoq != null and qio.qisclosed(kprintoq.?) == 0) {
        if (usewrite)
            _ = try qio.qwrite(kprintoq.?, str, n)
        else
            _ = qio.qiwrite(kprintoq.?, str, n);
    } else if (screenputs) |sp|
        sp(@constCast(str), n)
    else
        host.write(1, str, n);
}

fn putstrn(str: [*c]u8, n: c_int) callconv(.c) void {
    putstrn0(str, n, false) catch {};
}

fn echoscreen(buf_: [*]const u8, n_: usize) void {
    var ebuf: [128]u8 = undefined;
    var p: usize = 0;
    const e = ebuf.len - 4;
    const sp = screenputs.?;
    for (buf_[0..n_]) |x| {
        if (p >= e) {
            sp(&ebuf, @intCast(p));
            p = 0;
        }
        if (x == 0x15) {
            ebuf[p] = '^';
            ebuf[p + 1] = 'U';
            ebuf[p + 2] = '\n';
            p += 3;
        } else {
            ebuf[p] = x;
            p += 1;
        }
    }
    if (p != 0)
        sp(&ebuf, @intCast(p));
}

fn echo(buf: [*]const u8, n: usize) void {
    if (kbd.raw)
        return;
    if (screenputs != null)
        echoscreen(buf, n)
    else
        host.write(1, buf, @intCast(n));
}

fn kbdputc1(q: *Queue, r: u21) void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(r, &buf) catch std.unicode.utf8Encode(0xFFFD, &buf) catch unreachable;
    echo(&buf, n);
    _ = qio.qproduce(q, &buf, @intCast(n));
}

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

var collecting = false;
var nk: usize = 0;
var kc: [5]c.Rune = undefined;

fn toRune(r: c_int) u21 {
    return if (r >= 0 and r <= 0x10FFFF and !(r >= 0xD800 and r <= 0xDFFF)) @intCast(r) else 0xFFFD;
}

/// A key typed on the screen's window into the console's input queue,
/// with compose (Alt and a sequence) translated, as drawterm's.
fn kbdputc(q_: ?*Queue, ch: c_int) callconv(.c) c_int {
    const q = q_ orelse return 0;
    switch (ch) {
        // ignore modifiers; see nextrune() of kbdfs
        0, Kcaps, Knum, Kshift, Kaltgr, Kmod4, Kctl => return 0,
        Kalt => {
            collecting = true;
            nk = 0;
            return 0;
        },
        else => {},
    }

    if (!collecting) {
        kbdputc1(q, toRune(ch));
        return 0;
    }

    kc[nk] = @bitCast(ch);
    nk += 1;
    const r = latin1(&kc, @intCast(nk));
    if (r < -1) // need more keystrokes
        return 0;
    if (r != -1) // valid sequence
        kbdputc1(q, toRune(r))
    else for (kc[0..nk]) |k|
        kbdputc1(q, toRune(@bitCast(k)));
    nk = 0;
    collecting = false;
    return 0;
}

const Qdir = 0;
const Qbintime = 1;
const Qcons = 2;
const Qconsctl = 3;
const Qdrivers = 4;
const Qkmesg = 5;
const Qkprint = 6;
const Qhostdomain = 7;
const Qhostowner = 8;
const Qnull = 9;
const Qosversion = 10;
const Qpid = 11; // h9
const Qppid = 12; // h9
const Qrandom = 13;
const Qreboot = 14;
const Qshowfile = 15;
const Qsnarf = 16;
const Qsysname = 17;
const Qsysstat = 18;
const Qtime = 19;
const Qzero = 20;

const VLNUMSIZE = 22;
const DOMLEN = 48; // authsrv.h

fn qd(path: u64) c.Qid {
    return .{ .path = path, .vers = 0, .type = 0 };
}

var consdir = [_]Dirtab{
    dev.dirtab(".", .{ .path = Qdir, .vers = 0, .type = c.QTDIR }, 0, dev.dmdir | 0o555),
    dev.dirtab("bintime", qd(Qbintime), 24, 0o664),
    dev.dirtab("cons", qd(Qcons), 0, 0o660),
    dev.dirtab("consctl", qd(Qconsctl), 0, 0o220),
    dev.dirtab("drivers", qd(Qdrivers), 0, 0o444),
    dev.dirtab("hostdomain", qd(Qhostdomain), DOMLEN, 0o664),
    dev.dirtab("hostowner", qd(Qhostowner), 0, 0o664),
    dev.dirtab("kmesg", qd(Qkmesg), 0, 0o440),
    dev.dirtab("kprint", .{ .path = Qkprint, .vers = 0, .type = c.QTEXCL }, 0, c.DMEXCL | 0o440),
    dev.dirtab("null", qd(Qnull), 0, 0o666),
    dev.dirtab("osversion", qd(Qosversion), 0, 0o444),
    dev.dirtab("pid", qd(Qpid), c.NUMSIZE, 0o444), // h9
    dev.dirtab("ppid", qd(Qppid), c.NUMSIZE, 0o444), // h9
    dev.dirtab("random", qd(Qrandom), 0, 0o444),
    dev.dirtab("reboot", qd(Qreboot), 0, 0o664),
    dev.dirtab("showfile", qd(Qshowfile), 0, 0o220),
    dev.dirtab("snarf", qd(Qsnarf), 0, 0o666),
    dev.dirtab("sysname", qd(Qsysname), 0, 0o664),
    dev.dirtab("sysstat", qd(Qsysstat), 0, 0o666),
    dev.dirtab("time", qd(Qtime), c.NUMSIZE + 3 * VLNUMSIZE, 0o664),
    dev.dirtab("zero", qd(Qzero), 0, 0o444),
};

/// A number right-justified in size-1 characters and a space, from off.
fn readnum(off: c_uint, buf: [*c]u8, n_: c_uint, val: c_uint, size_: c_int) callconv(.c) c_int {
    var tmp: [64]u8 = undefined;
    const size: usize = @intCast(@max(size_, 1));
    if (size > tmp.len) return 0;
    // drawterm's "%*.0lud": right-justified in size-1 characters.
    @memset(tmp[0 .. size - 1], ' ');
    var d: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&d, "{d}", .{val}) catch unreachable;
    const k = @min(s.len, size - 1);
    @memcpy(tmp[size - 1 - k .. size - 1], s[s.len - k ..]);
    tmp[size - 1] = ' ';
    if (off >= size)
        return 0;
    var n: usize = n_;
    if (off + n > size)
        n = size - off;
    @memcpy(buf[0..n], tmp[off..][0..n]);
    return @intCast(n);
}

fn readstr(off: c_uint, buf: [*c]u8, n_: c_uint, str: [*c]const u8) callconv(.c) c_int {
    const s = std.mem.span(@as([*:0]const u8, @ptrCast(str)));
    if (off >= s.len)
        return 0;
    var n: usize = n_;
    if (off + n > s.len)
        n = s.len - off;
    @memcpy(buf[0..n], s[off..][0..n]);
    return @intCast(n);
}

fn readStr(off: i64, buf: [*]u8, n: c_int, s: ?[*:0]const u8) c_int {
    return readstr(@truncate(@as(u64, @bitCast(off))), buf, @intCast(n), s orelse "");
}

fn consinit() void {
    c.randominit();
}

fn consattach(spec: [*:0]const u8) Error!*Chan {
    return dev.devattach('c', spec);
}

fn conswalk(ch: *Chan, nc: ?*Chan, name: [*]const [*:0]const u8, nname: c_int) Error!?*Walkqid {
    return dev.devwalk(ch, nc, name, nname, &consdir, consdir.len, dev.devgenC());
}

fn consstat(ch: *Chan, dp: [*]u8, n: c_int) Error!c_int {
    return dev.devstat(ch, dp, n, &consdir, consdir.len, dev.devgenC());
}

/// Whether there's a screen, for snarf.
fn screen() Error!void {
    if (gscreen == null)
        return port.kerror(&port.Egreg);
}

fn consopen(ch_: *Chan, omode: c_int) Error!*Chan {
    // h9: snarf, the clipboard, is the screen's machine's
    // (src/kern/dev/gfx.zig).
    if (port.options.gfx and ch_.qid.path == Qsnarf and (ch_.qid.type & c.QTDIR) == 0)
        try @import("gfx.zig").snarfopen();
    dev.aux(ch_).* = null;
    const ch = try dev.devopen(ch_, omode, &consdir, consdir.len, dev.devgenC());
    switch (ch.qid.path) {
        Qconsctl => {
            sync.qlock(&kbd.lk);
            kbd.ctl += 1;
            sync.qunlock(&kbd.lk);
        },
        Qkprint => {
            if (c.tas(&kprintinuse) != 0) {
                ch.flag &= ~@as(@TypeOf(ch.flag), c.COPEN);
                return port.kerror(&port.Einuse);
            }
            if (kprintoq == null) {
                kprintoq = qio.qopen(8 * 1024, c.Qcoalesce, null, null) orelse {
                    ch.flag &= ~@as(@TypeOf(ch.flag), c.COPEN);
                    return port.kerror(&port.Enomem);
                };
                qio.qnoblock(kprintoq.?, 1);
            } else qio.qreopen(kprintoq.?);
            ch.iounit = @intCast(c.qiomaxatomic);
        },
        Qsnarf => {
            try screen();
            if (omode == c.ORDWR)
                return port.kerror(&port.Eperm);
            dev.aux(ch).* = if (omode == c.OREAD) c.strdup(@constCast("")) else c.mallocz(c.SnarfSize, 1);
        },
        else => {},
    }
    return ch;
}

fn consclose(ch: *Chan) Error!void {
    switch (ch.qid.path) {
        // last close of control file turns off raw
        Qconsctl => if (ch.flag & c.COPEN != 0) {
            sync.qlock(&kbd.lk);
            defer sync.qunlock(&kbd.lk);
            kbd.ctl -= 1;
            if (kbd.ctl == 0)
                kbd.raw = false;
            if (screenputs == null)
                c.setterm(@intFromBool(kbd.raw));
        },
        // close of kprint allows other opens
        Qkprint => if (ch.flag & c.COPEN != 0) {
            kprintinuse = 0;
            qio.qhangup(kprintoq.?, null);
        },
        Qsnarf => {
            try screen();
            const a: ?[*:0]u8 = @ptrCast(dev.aux(ch).*);
            if (ch.mode == c.OWRITE)
                _ = clipwrite(a);
            c.free(a);
        },
        else => {},
    }
}

fn qreadcons(qu: *Queue, buf: [*]u8, n: c_int) Error!c_int {
    if (screenputs == null and !qio.qcanread(qu))
        return host.read(0, buf, n);
    return qio.qread(qu, buf, n);
}

fn readcons(buf: [*]u8, n_: c_int) Error!c_int {
    var n = n_;
    sync.qlock(&kbd.lk);
    defer sync.qunlock(&kbd.lk);
    if (kbd.raw) {
        if (qio.qcanread(lineq.?))
            return qio.qread(lineq.?, buf, n);
        // read as much as possible
        var cbuf = buf;
        while (true) {
            const i = try qreadcons(kbdq.?, cbuf, n);
            if (i <= 0) break;
            cbuf += @intCast(i);
            n -= i;
            if (!(n > 0 and qio.qcanread(kbdq.?))) break;
        }
        return @intCast(@intFromPtr(cbuf) - @intFromPtr(buf));
    }
    while (!qio.qcanread(lineq.?)) {
        var eol = true;
        if (try qreadcons(kbdq.?, kbd.line[kbd.x..].ptr, 1) == 1) {
            eol = false;
            switch (kbd.line[kbd.x]) {
                '\x08' => if (kbd.x != 0) {
                    kbd.x -= 1;
                },
                0x15 => kbd.x = 0,
                '\n' => {
                    kbd.x += 1;
                    eol = true;
                },
                0x04 => eol = true,
                else => kbd.x += 1,
            }
        }
        if (kbd.x == kbd.line.len or eol) {
            _ = try qio.qwrite(lineq.?, &kbd.line, @intCast(kbd.x));
            kbd.x = 0;
        }
    }
    return qio.qread(lineq.?, buf, n);
}

fn drivers(off: i64, buf: [*]u8, n: c_int) c_int {
    var b: [c.READSTR:0]u8 = undefined;
    var w: std.Io.Writer = .fixed(b[0..c.READSTR]);
    const tab = dev.table();
    var i: usize = 0;
    while (tab[i]) |d| : (i += 1) {
        var r: [4]u8 = undefined;
        const k = std.unicode.utf8Encode(toRune(d.dc), &r) catch 0;
        w.print("#{s} {s}\n", .{ r[0..k], std.mem.span(@as([*:0]const u8, @ptrCast(d.name))) }) catch break;
    }
    b[w.end] = 0;
    return readStr(off, buf, n, &b);
}

fn consread(ch: *Chan, va: ?*anyopaque, n: c_int, off: i64) Error!c_int {
    if (n <= 0)
        return n;
    const buf: [*]u8 = @ptrCast(va.?);
    const offset: c_uint = @truncate(@as(u64, @bitCast(off)));
    switch (ch.qid.path) {
        Qdir => return dev.devdirread(ch, buf, n, &consdir, consdir.len, dev.devgenC()),
        Qcons => return readcons(buf, n),
        Qkmesg => {
            // Unlocked, to avoid tying up a process that's writing to the
            // buffer. kmesg.n never gets smaller, so at worst the reader
            // sees a slurred buffer.
            const kn: i64 = kmesg.n;
            if (off >= kn) return 0;
            const m: usize = @intCast(@min(@as(i64, n), kn - off));
            @memcpy(buf[0..m], kmesg.buf[@intCast(off)..][0..m]);
            return @intCast(m);
        },
        Qkprint => return qio.qread(kprintoq.?, buf, n),
        Qtime => return h9_cons_time(offset, buf, n), // h9: nanosecond clock
        Qbintime => return h9_cons_bintime(buf, n), // h9: nanosecond clock, four words
        Qhostowner => return readStr(off, buf, n, eve),
        Qhostdomain => return readStr(off, buf, n, @ptrCast(&hostdomain)),
        Qnull => return 0,
        Qsnarf => {
            try screen();
            if (off == 0) {
                c.free(dev.aux(ch).*);
                dev.aux(ch).* = clipread();
            }
            const a: ?[*:0]const u8 = @ptrCast(dev.aux(ch).*);
            if (a == null) return 0;
            return readStr(off, buf, n, a);
        },
        Qsysstat => return h9_cons_sysstat(offset, buf, n), // h9
        Qpid => return h9_cons_pid(offset, buf, n), // h9
        Qppid => return h9_cons_ppid(offset, buf, n), // h9
        Qsysname => {
            if (sysname == null) return 0;
            return readStr(off, buf, n, sysname);
        },
        Qrandom => return @bitCast(c.randomread(buf, @intCast(n))),
        Qdrivers => return drivers(off, buf, n),
        Qzero => {
            @memset(buf[0..@intCast(n)], 0);
            return n;
        },
        Qosversion => return readStr(off, buf, n, "2000"),
        else => {},
    }
    port.print("consread 0x%llux\n", .{ch.qid.path});
    return port.kerror(&port.Egreg);
}

fn consctl(a: [*]const u8, n_: c_int) void {
    var buf: [256]u8 = undefined;
    const n: usize = @min(@as(usize, @intCast(@max(n_, 0))), buf.len - 1);
    @memcpy(buf[0..n], a[0..n]);
    buf[n] = 0;
    const s = std.mem.sliceTo(&buf, 0);
    var i: usize = 0;
    while (true) {
        const w = s[i..];
        if (std.mem.startsWith(u8, w, "rawon")) {
            sync.qlock(&kbd.lk);
            if (kbd.x != 0) {
                _ = qio.qwrite(kbdq.?, &kbd.line, @intCast(kbd.x)) catch 0;
                kbd.x = 0;
            }
            kbd.raw = true;
            if (screenputs == null)
                c.setterm(1);
            sync.qunlock(&kbd.lk);
        } else if (std.mem.startsWith(u8, w, "rawoff")) {
            sync.qlock(&kbd.lk);
            kbd.raw = false;
            kbd.x = 0;
            if (screenputs == null)
                c.setterm(0);
            sync.qunlock(&kbd.lk);
        }
        i += 1 + (std.mem.indexOfScalar(u8, w, ' ') orelse break);
    }
}

fn iseve() bool {
    return c.iseve() != 0;
}

fn conswrite(ch: *Chan, va: ?*const anyopaque, n: c_int, off: i64) Error!c_int {
    const a: [*]const u8 = @ptrCast(va.?);
    const offset: u64 = @bitCast(off);
    switch (ch.qid.path) {
        Qcons => {
            // putstrn can't fault on guest memory, so the data is copied
            // a buffer at a time.
            var buf: [256]u8 = undefined;
            var l: usize = @intCast(@max(n, 0));
            var p = a;
            while (l > 0) {
                const bp = @min(l, buf.len);
                @memcpy(buf[0..bp], p[0..bp]);
                try putstrn0(&buf, @intCast(bp), true);
                p += bp;
                l -= bp;
            }
        },
        Qconsctl => consctl(a, n),
        Qtime, Qbintime => {
            if (!iseve())
                return port.kerror(&port.Eperm);
            // h9 doesn't set the host's clock.
            return port.kerror(&port.Egreg);
        },
        Qhostowner => return dev.raising(&c.hostownerwrite, .{ @constCast(@as([*c]const u8, a)), n }),
        Qhostdomain => return dev.raising(&c.hostdomainwrite, .{ @constCast(@as([*c]const u8, a)), n }),
        Qnull => {},
        Qreboot => {
            if (!iseve())
                return port.kerror(&port.Eperm);
            const m: usize = @intCast(@max(n, 0));
            var it = std.mem.tokenizeAny(u8, a[0..m], " \t\n");
            const cmd = it.next() orelse "";
            if (std.mem.eql(u8, cmd, "reboot"))
                return port.kerror(&port.Egreg);
            if (std.mem.eql(u8, cmd, "panic"))
                panic("/dev/reboot");
            return port.kerror("unknown control message");
        },
        Qshowfile => return dev.raising(&c.showfilewrite, .{ @constCast(@as([*c]const u8, a)), n }),
        Qsnarf => {
            try screen();
            const m: u64 = @intCast(@max(n, 0));
            if (offset >= c.SnarfSize or offset + m >= c.SnarfSize)
                return port.kerror(&port.Etoobig);
            consdir[Qsnarf].qid.vers +%= 1;
            const d: [*]u8 = @ptrCast(dev.aux(ch).*.?);
            @memcpy(d[@intCast(offset)..][0..@intCast(m)], a[0..@intCast(m)]);
            return n;
        },
        Qsysstat => return 0,
        Qsysname => {
            if (offset != 0)
                return port.kerror(&port.Ebadarg);
            var buf: [256]u8 = undefined;
            if (n <= 0 or n >= buf.len)
                return port.kerror(&port.Ebadarg);
            const m: usize = @intCast(n);
            @memcpy(buf[0..m], a[0..m]);
            buf[m] = 0;
            if (buf[m - 1] == '\n')
                buf[m - 1] = 0;
            chan.kstrdup(&sysname, @ptrCast(&buf));
        },
        else => {
            port.print("conswrite: 0x%llux\n", .{ch.qid.path});
            return port.kerror(&port.Egreg);
        },
    }
    return n;
}

pub const Device = dev.Native('c', "cons", .{
    .init = consinit,
    .attach = consattach,
    .walk = conswalk,
    .stat = consstat,
    .open = consopen,
    .create = dev.devcreate,
    .close = consclose,
    .read = consread,
    .write = conswrite,
    .remove = dev.devremove,
    .wstat = dev.devwstat,
});

pub fn exportC() void {
    @export(&Device.dev, .{ .name = "consdevtab" });
    @export(&screenputs, .{ .name = "screenputs" });
    @export(&kmesg, .{ .name = "kmesg" });
    @export(&kbdq, .{ .name = "kbdq" });
    @export(&kprintoq, .{ .name = "kprintoq" });
    @export(&sysname, .{ .name = "sysname" });
    @export(&fasthz, .{ .name = "fasthz" });
    @export(&return0, .{ .name = "return0" });
    @export(&printinit, .{ .name = "printinit" });
    @export(&putstrn, .{ .name = "putstrn" });
    @export(&kbdputc, .{ .name = "kbdputc" });
    @export(&readnum, .{ .name = "readnum" });
    @export(&readstr, .{ .name = "readstr" });
}
