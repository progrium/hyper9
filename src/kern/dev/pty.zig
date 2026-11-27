//! src/kern/devpty.c in Zig (design/kernel-port.md): `#τ`, pseudoterminal
//! pairs (design/epoch-0/linux-pty.md). The Linux view serves /dev/ptmx as
//! #τ/ptmx and /dev/pts as #τ itself. A close translation: the same
//! functions in the same order, with error unions for the C's error
//! labels. A native device (dev.zig's `Native`).
//!
//!     #τ/ptmx  a clone file: each open makes a pair and returns its master
//!     #τ/N     pair N's slave, which opens while the master is open and
//!              the pair is unlocked
//!
//! A pair has a queue each way, 64 KiB as Linux's N_TTY buffer is: the
//! master's writes are the slave's reads, and the other way round. It
//! also keeps the Linux state of the terminal: its termios, window size,
//! foreground process group, session, and lock. The Linux ABI reads and
//! writes that through h9_pty_get and h9_pty_set, on an fd of either
//! side; the ioctls are its interface (src/abi/linux/sys.zig). The
//! termios is applied here, as a line discipline (below).
//!
//! Until the slave first opens, a master read waits, as on Linux. When
//! the slave's last open closes, the master reads what's left and then
//! an end of file, which the ABI makes EIO, as Linux has it; opening the
//! slave again reopens it. When the master closes, the slave reads to an
//! end of file, its writes fail with EIO, the session's terminal is
//! gone, and the foreground group is sent SIGHUP through h9_ptysig. A
//! pair goes when both sides have closed, and its number is reused.
//!
//! Pairs belong to the machine of the process that opened ptmx, and
//! numbers start at 0 on each machine: a machine's #τ lists and opens
//! only its own.
//!
//! A pair waits only in its queues, which wait in sync.zig.

const std = @import("std");
const port = @import("../port.zig");
const qio = @import("../qio.zig");
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
const Queue = qio.Queue;

// proc.c: the calling process's machine, with a reference, and its
// release. The machine is only a key here.
extern fn h9_kern_mach() ?*anyopaque;
extern fn h9_kern_putmach(m: ?*anyopaque) void;

pub const Tau = 0x3C4;

const Qdir = 0;
const Qptmx = 1;
const Qmaster = 2;
const Qslave = 3;

const Npty = 4096; // pairs per machine, as Linux's kernel.pty.max
const Ptyq = 64 * 1024; // each way, as Linux's N_TTY buffer
const Termlen = 60; // the ABI's termios, of which the kernel's is the first 36 bytes
const Linemax = 4096; // a canonical line, as N_TTY's
const Chunk = 4096; // input taken through the line discipline at a time
const Maxsig = 8;

// Linux's termios flags and c_cc indices.
const ISTRIP = 0o40;
const INLCR = 0o100;
const IGNCR = 0o200;
const ICRNL = 0o400;
const OPOST = 0o1;
const ONLCR = 0o4;
const OCRNL = 0o10;
const ISIG = 0o1;
const ICANON = 0o2;
const ECHO = 0o10;
const ECHOE = 0o20;
const ECHOK = 0o40;
const ECHONL = 0o100;
const NOFLSH = 0o200;
const ECHOCTL = 0o1000;
const ECHOKE = 0o4000;
const IEXTEN = 0o100000;
const VINTR = 0;
const VQUIT = 1;
const VERASE = 2;
const VKILL = 3;
const VEOF = 4;
const VTIME = 5;
const VMIN = 6;
const VSWTC = 7;
const VSTART = 8;
const VSTOP = 9;
const VSUSP = 10;
const VEOL = 11;
const VREPRINT = 12;
const VDISCARD = 13;
const VWERASE = 14;
const VLNEXT = 15;
const VEOL2 = 16;
const Ccoff = 17;

// Linux's signal numbers.
const Lsighup = 1;
const Lsigint = 2;
const Lsigquit = 3;
const Lsigtstp = 20;

fn QTYPE(p: u64) c_int {
    return @intCast(p & 0xf);
}
fn QNUM(p: u64) c_int {
    return @intCast(@as(u32, @truncate(p >> 4)) & 0x7fffffff);
}
fn QPATH(t: u64, n: c_int) i64 {
    return @bitCast((@as(u64, @intCast(n)) << 4) | t);
}

const Eptyio = "errno 5"; // EIO, through attr.errno

const Pty = struct {
    lk: c.Lock = std.mem.zeroes(c.Lock), // the fields below
    next: ?*Pty = null,
    mach: ?*anyopaque = null, // the Hmach it belongs to, as a key
    n: c_int = 0,
    mopen: c_int = 0, // opens of the master
    sopen: c_int = 0, // opens of the slave
    in: *Queue = undefined, // master to slave
    out: *Queue = undefined, // slave to master

    termios: [Termlen]u8 = @splat(0),
    winsz: [4]u16 = @splat(0), // rows, cols, xpixel, ypixel
    fg: c_uint = 0, // the foreground process group, or 0
    sid: c_uint = 0, // the session it's the terminal of, or 0
    locked: c_int = 0,

    line: [Linemax]u8 = @splat(0), // the canonical line being edited
    nline: c_int = 0,

    watch: dev.rd.Watchers = .{}, // both queues' (design/file-interface.md)
};

/// The pair state h9_pty_get and h9_pty_set copy; src/abi/linux/kc.zig's PtyState.
pub const Ptystate = extern struct {
    termios: [Termlen]u8,
    winsz: [4]u16,
    fg: c_uint,
    sid: c_uint,
    locked: c_int,
    n: c_int,
    master: c_int,
    slaveopen: c_int,
};

const Stermios = 1 << 0;
const Swinsz = 1 << 1;
const Sfg = 1 << 2;
const Ssid = 1 << 3;
const Slock = 1 << 4;

var ptys: struct {
    lk: c.Lock = std.mem.zeroes(c.Lock),
    list: ?*Pty = null,
} = .{};

/// The ABI's default termios, set on each new pair (ptyinit).
var defterm: [Termlen]u8 = @splat(0);

/// Posts Linux signal signo to process group pgrp of the calling
/// process's machine (src/machine.zig): SIGHUP when a master's last
/// close hangs the pair up, and SIGINT, SIGQUIT, and SIGTSTP for the
/// ISIG characters.
var h9_ptysig: ?Ptysig = null;

/// src/abi/linux/kc.zig's PtySig.
const Ptysig = *const fn (c_ulong, c_int) callconv(.c) void;

fn upmach() ?*anyopaque {
    const m = h9_kern_mach();
    h9_kern_putmach(m);
    return m;
}

/// Pair n of the caller's machine, or nil; under ptys.lk.
fn lookup(m: ?*anyopaque, n: c_int) ?*Pty {
    var p = ptys.list;
    while (p) |pp| : (p = pp.next)
        if (pp.mach == m and pp.n == n)
            return pp;
    return null;
}

fn newpty() Error!*Pty {
    const p: *Pty = @ptrCast(@alignCast(port.malloc(@sizeOf(Pty)) orelse {
        c.exhausted(@constCast("memory"));
        unreachable;
    }));
    p.* = .{};
    const in = qio.qopen(Ptyq, 0, null, null);
    const out = qio.qopen(Ptyq, 0, null, null);
    if (in == null or out == null) {
        c.free(in);
        c.free(out);
        c.free(p);
        c.exhausted(@constCast("memory"));
        unreachable;
    }
    p.in = in.?;
    p.out = out.?;
    qio.qsetwatch(p.in, &p.watch);
    qio.qsetwatch(p.out, &p.watch);
    p.termios = defterm;
    const m = upmach();
    p.mach = m;
    p.mopen = 1;
    p.locked = 1;
    c.lock(&ptys.lk);
    var n: c_int = 0;
    while (n < Npty) : (n += 1)
        if (lookup(m, n) == null)
            break;
    if (n == Npty) {
        c.unlock(&ptys.lk);
        qio.qfree(p.in);
        qio.qfree(p.out);
        c.free(p);
        return port.kerror("no free ptys");
    }
    p.n = n;
    // Kept in number order, so the directory lists them so.
    var l: *?*Pty = &ptys.list;
    while (l.*) |q| : (l = &q.next) {
        if (q.mach == m and q.n >= n) break;
    }
    p.next = l.*;
    l.* = p;
    c.unlock(&ptys.lk);
    return p;
}

/// Takes p off the list and frees it; both sides have closed.
fn freepty(p: *Pty) void {
    c.lock(&ptys.lk);
    var l: *?*Pty = &ptys.list;
    while (l.*) |q| : (l = &q.next) {
        if (q == p) {
            l.* = p.next;
            break;
        }
    }
    c.unlock(&ptys.lk);
    qio.qfree(p.in);
    qio.qfree(p.out);
    c.free(p);
}

fn ptyinit() void {
    // c_iflag ICRNL|IXON, c_oflag OPOST|ONLCR, c_cflag CS8|CREAD|B38400, c_lflag ISIG|ICANON|ECHO|ECHOE|ECHOK|IEXTEN|ECHOCTL|ECHOKE
    const cc = [_]u8{ 3, 0x1c, 0x7f, 0x15, 4, 0, 1, 0, 0x11, 0x13, 0x1a, 0, 0x12, 0x0f, 0x17, 0x16 }; // Linux's, through VLNEXT
    const f = [4]u32{ 0o400 | 0o2000, 0o1 | 0o4, 0o60 | 0o200 | 0o17, 0o1 | 0o2 | 0o10 | 0o20 | 0o40 | 0o100000 | 0o1000 | 0o4000 };
    for (f, 0..) |v, i|
        std.mem.writeInt(u32, defterm[4 * i ..][0..4], v, .little);
    @memcpy(defterm[17..][0..cc.len], &cc);
}

// The line discipline (design/epoch-0/linux-pty.md, step 2), as Linux's
// N_TTY applies the pair's termios: input written to the master goes
// through the input flags, ISIG, canonical editing, and echo on its way
// to the slave, and the slave's writes through the output flags on their
// way to the master. Echo is the slave's output too, so it reaches the
// master after output processing. In canonical mode, each line (or a
// VEOF) is a block of its own in the slave's queue, and a read takes at
// most one, so it returns at most a line; an empty block is the end of
// file VEOF on an empty line makes. Echo and lines are added without
// waiting, and dropped when the queue is full, as N_TTY drops input
// beyond its buffer; raw input waits for room, as a master write does on
// Linux. VMIN and VTIME are the ABI's (src/abi/linux/sys.zig).

fn flag(p: *Pty, off: usize) u32 {
    return std.mem.readInt(u32, p.termios[off..][0..4], .little);
}

fn iscc(p: *Pty, ch: u8, v: usize) bool {
    const cc = p.termios[Ccoff + v];
    return cc != 0 and ch == cc; // 0 is _POSIX_VDISABLE
}

/// Output processing of ch into b; returns the bytes it made.
fn opost(oflag: u32, ch_: u8, b: [*]u8) usize {
    var ch = ch_;
    if (oflag & OPOST != 0) {
        if (ch == '\n' and (oflag & ONLCR) != 0) {
            b[0] = '\r';
            b[1] = '\n';
            return 2;
        }
        if (ch == '\r' and (oflag & OCRNL) != 0)
            ch = '\n';
    }
    b[0] = ch;
    return 1;
}

/// The width echo gives ch: 2 for a control character shown as ^X.
fn ctlwidth(lflag: u32, ch: u8) usize {
    return if ((lflag & ECHOCTL) != 0 and (ch < 0x20 or ch == 0x7f) and ch != '\t' and ch != '\n') 2 else 1;
}

/// Echoes ch into e (with output processing); returns the bytes.
fn echo1(p: *Pty, lflag: u32, ch: u8, e: [*]u8) usize {
    if (ctlwidth(lflag, ch) == 2) {
        e[0] = '^';
        e[1] = if (ch == 0x7f) '?' else ch + 0x40;
        return 2;
    }
    return opost(flag(p, 4), ch, e);
}

/// Erases the last character of the line, echoing it away if ECHOE.
fn erase1(p: *Pty, lflag: u32, e: [*]u8) usize {
    if (p.nline == 0)
        return 0;
    p.nline -= 1;
    const ch = p.line[@intCast(p.nline)];
    if (lflag & ECHO == 0)
        return 0;
    if (lflag & ECHOE == 0)
        return echo1(p, lflag, p.termios[Ccoff + VERASE], e);
    var n: usize = 0;
    var w = ctlwidth(lflag, ch);
    while (w > 0) : (w -= 1) {
        @memcpy(e[n..][0..3], "\x08 \x08");
        n += 3;
    }
    return n;
}

const Seg = struct {
    off: usize,
    len: usize,
    line: bool, // a canonical line, added without waiting
};

/// Takes up to Chunk bytes of master input through the discipline, under
/// p.lk: what the slave gets in d (as segments in sg), echo in e, and
/// signals in sigs. Returns how many segments.
fn discipline(p: *Pty, a: []const u8, d: [*]u8, sg: [*]Seg, e: [*]u8, ne: *usize, sigs: *[Maxsig]c_int, nsig: *usize) usize {
    const iflag = flag(p, 0);
    const lflag = flag(p, 12);
    var nd: usize = 0;
    var ns: usize = 0;
    var raw0: ?usize = null; // where the raw segment being built starts in d
    ne.* = 0;
    nsig.* = 0;
    for (a) |ch0| {
        var ch = ch0;
        if (iflag & ISTRIP != 0)
            ch &= 0x7f;
        if (ch == '\r') {
            if (iflag & IGNCR != 0)
                continue;
            if (iflag & ICRNL != 0)
                ch = '\n';
        } else if (ch == '\n' and (iflag & INLCR) != 0)
            ch = '\r';
        if (lflag & ISIG != 0) {
            var sig: c_int = 0;
            if (iscc(p, ch, VINTR))
                sig = Lsigint
            else if (iscc(p, ch, VQUIT))
                sig = Lsigquit
            else if (iscc(p, ch, VSUSP))
                sig = Lsigtstp;
            if (sig != 0) {
                if (lflag & NOFLSH == 0) {
                    qio.qflush(p.in);
                    p.nline = 0;
                    // Nothing written before it in this write reaches the slave either.
                    ns = 0;
                    nd = 0;
                    raw0 = null;
                }
                if (lflag & ECHO != 0)
                    ne.* += echo1(p, lflag, ch, e + ne.*);
                if (nsig.* < Maxsig) {
                    sigs[nsig.*] = sig;
                    nsig.* += 1;
                }
                continue;
            }
        }
        if (lflag & ICANON == 0) {
            if (raw0 == null) {
                raw0 = nd;
                sg[ns] = .{ .off = nd, .len = 0, .line = false };
                ns += 1;
            }
            d[nd] = ch;
            nd += 1;
            sg[ns - 1].len += 1;
            if (lflag & ECHO != 0)
                ne.* += echo1(p, lflag, ch, e + ne.*);
            continue;
        }
        if (iscc(p, ch, VERASE)) {
            ne.* += erase1(p, lflag, e + ne.*);
            continue;
        }
        if ((lflag & IEXTEN) != 0 and iscc(p, ch, VWERASE)) {
            while (p.nline > 0 and (p.line[@intCast(p.nline - 1)] == ' ' or p.line[@intCast(p.nline - 1)] == '\t'))
                ne.* += erase1(p, lflag, e + ne.*);
            while (p.nline > 0 and p.line[@intCast(p.nline - 1)] != ' ' and p.line[@intCast(p.nline - 1)] != '\t')
                ne.* += erase1(p, lflag, e + ne.*);
            continue;
        }
        if (iscc(p, ch, VKILL)) {
            if ((lflag & (ECHO | ECHOKE | ECHOE)) == (ECHO | ECHOKE | ECHOE)) {
                while (p.nline > 0)
                    ne.* += erase1(p, lflag, e + ne.*);
            } else {
                p.nline = 0;
                if (lflag & ECHO != 0) {
                    ne.* += echo1(p, lflag, ch, e + ne.*);
                    if (lflag & ECHOK != 0)
                        ne.* += opost(flag(p, 4), '\n', e + ne.*);
                }
            }
            continue;
        }
        if (iscc(p, ch, VEOF) or ch == '\n' or iscc(p, ch, VEOL) or ((lflag & IEXTEN) != 0 and iscc(p, ch, VEOL2))) {
            // The line is done; VEOF itself isn't part of it.
            if (!iscc(p, ch, VEOF)) {
                if (p.nline < Linemax) {
                    p.line[@intCast(p.nline)] = ch;
                    p.nline += 1;
                }
                if ((lflag & ECHO) != 0 or (ch == '\n' and (lflag & ECHONL) != 0))
                    ne.* += echo1(p, lflag, ch, e + ne.*);
            }
            const nl: usize = @intCast(p.nline);
            @memcpy(d[nd..][0..nl], p.line[0..nl]);
            sg[ns] = .{ .off = nd, .len = nl, .line = true };
            ns += 1;
            nd += nl;
            p.nline = 0;
            raw0 = null;
            continue;
        }
        // An ordinary character: kept, with room left for the newline.
        if (p.nline < Linemax - 1) {
            p.line[@intCast(p.nline)] = ch;
            p.nline += 1;
            if (lflag & ECHO != 0)
                ne.* += echo1(p, lflag, ch, e + ne.*);
        }
    }
    return ns;
}

fn masterwrite(p: *Pty, a: [*]const u8, n: c_int) Error!c_int {
    // d: the chunk and a line; e: echo, at most 6 bytes to erase each byte of the line and the chunk, and 3 to echo each of the chunk.
    const d: [*]u8 = @ptrCast(c.smalloc(Chunk + Linemax));
    defer c.free(d);
    const e: [*]u8 = @ptrCast(c.smalloc(9 * Chunk + 6 * Linemax + 16));
    defer c.free(e);
    const sg: [*]Seg = @ptrCast(@alignCast(c.smalloc((Chunk + 1) * @sizeOf(Seg))));
    defer c.free(sg);
    var sigs: [Maxsig]c_int = undefined;
    const total: usize = @intCast(n);
    var done: usize = 0;
    while (done < total) {
        const m = @min(total - done, Chunk);
        var ne: usize = 0;
        var nsig: usize = 0;
        c.lock(&p.lk);
        const ns = discipline(p, a[done..][0..m], d, sg, e, &ne, &sigs, &nsig);
        const fg = p.fg;
        c.unlock(&p.lk);
        if (ne > 0)
            _ = qio.qiwrite(p.out, e, @intCast(ne));
        for (sg[0..ns]) |s| {
            if (s.line)
                _ = qio.qiwrite(p.in, d + s.off, @intCast(s.len))
            else if (s.len > 0)
                _ = try qio.qwrite(p.in, d + s.off, @intCast(s.len));
        }
        for (sigs[0..nsig]) |sig|
            if (fg != 0)
                if (h9_ptysig) |f| f(fg, sig);
        done += m;
    }
    return n;
}

fn slavewrite(p: *Pty, a: [*]const u8, n: c_int) Error!c_int {
    c.lock(&p.lk);
    const oflag = flag(p, 4);
    c.unlock(&p.lk);
    if (oflag & OPOST == 0 or oflag & (ONLCR | OCRNL) == 0)
        return qio.qwrite(p.out, a, n);
    const b: [*]u8 = @ptrCast(c.smalloc(2 * Chunk));
    defer c.free(b);
    const total: usize = @intCast(n);
    var done: usize = 0;
    while (done < total) {
        const m = @min(total - done, Chunk);
        var nb: usize = 0;
        for (a[done..][0..m]) |ch|
            nb += opost(oflag, ch, b + nb);
        _ = try qio.qwrite(p.out, b, @intCast(nb));
        done += m;
    }
    return n;
}

/// In canonical mode a read returns at most a line, the block it's in.
fn slaveread(p: *Pty, va: [*]u8, n: c_int) Error!c_int {
    c.lock(&p.lk);
    const canon = (flag(p, 12) & ICANON) != 0;
    c.unlock(&p.lk);
    if (!canon)
        return qio.qread(p.in, va, n);
    const b = (try qio.qbread(p.in, n)) orelse return 0;
    const len: usize = @intFromPtr(b.wp) - @intFromPtr(b.rp);
    @memcpy(va[0..len], b.rp[0..len]);
    qio.freeb(b);
    return @intCast(len);
}

fn gendir(ch: *Chan, q: Qid, name: []const u8, perm: c_int, dp: *Dir) void {
    const buf: []u8 = &up().genbuf;
    const s = std.mem.printSentinel(buf, "{s}", .{name}, 0) catch unreachable;
    dev.devdir(ch, q, s.ptr, 0, c.eve, perm, dp);
}

fn ptygen(ch_: [*c]Chan, name_: [*c]u8, tab: [*c]Dirtab, ntab: c_int, s_: c_int, dp_: [*c]Dir) callconv(.c) c_int {
    _ = tab;
    _ = ntab;
    const ch: *Chan = ch_;
    const dp: *Dir = dp_;
    var s = s_;
    var q: Qid = undefined;
    if (s == c.DEVDOTDOT) {
        dev.mkqid(&q, QPATH(Qdir, 0), 0, c.QTDIR);
        dev.devdir(ch, q, @constCast("#τ"), 0, c.eve, dev.dmdir | 0o555, dp);
        return 1;
    }
    if (name_ != null and dev.streq(name_, "ptmx")) {
        s = 0;
    } else if (name_ != null) {
        const name = std.mem.span(@as([*:0]const u8, name_));
        if (name.len == 0 or (name[0] == '0' and name.len > 1))
            return -1;
        const n = std.fmt.parseUnsigned(c_int, name, 10) catch return -1;
        c.lock(&ptys.lk);
        const p = lookup(upmach(), n);
        c.unlock(&ptys.lk);
        if (p == null)
            return -1;
        dev.mkqid(&q, QPATH(Qslave, n), 0, c.QTFILE);
        var nb: [16]u8 = undefined;
        gendir(ch, q, std.mem.print(&nb, "{d}", .{n}) catch unreachable, 0o620, dp);
        return 1;
    }
    if (s == 0) {
        dev.mkqid(&q, QPATH(Qptmx, 0), 0, c.QTFILE);
        dev.devdir(ch, q, @constCast("ptmx"), 0, c.eve, 0o666, dp);
        return 1;
    }
    s -= 1;
    const m = upmach();
    var n: c_int = -1;
    c.lock(&ptys.lk);
    var p = ptys.list;
    while (p) |pp| : (p = pp.next) {
        if (pp.mach == m) {
            if (s == 0) {
                n = pp.n;
                break;
            }
            s -= 1;
        }
    }
    c.unlock(&ptys.lk);
    if (n < 0)
        return -1;
    dev.mkqid(&q, QPATH(Qslave, n), 0, c.QTFILE);
    var nb: [16]u8 = undefined;
    gendir(ch, q, std.mem.print(&nb, "{d}", .{n}) catch unreachable, 0o620, dp);
    return 1;
}

fn ptyattach(spec: [*:0]const u8) Error!*Chan {
    const ch = dev.devattach(Tau, spec);
    dev.mkqid(&ch.qid, QPATH(Qdir, 0), 0, c.QTDIR);
    return ch;
}

fn ptywalk(ch: *Chan, nc: ?*Chan, name: [*]const [*:0]const u8, nname: c_int) Error!?*Walkqid {
    return dev.devwalk(ch, nc, name, nname, null, 0, &ptygen);
}

fn ptystat(ch: *Chan, db: [*]u8, n_: c_int) Error!c_int {
    var d: Dir = undefined;
    var q: Qid = undefined;
    var buf: [16]u8 = undefined;
    switch (QTYPE(ch.qid.path)) {
        Qdir => dev.devdir(ch, ch.qid, @constCast("#τ"), 0, c.eve, dev.dmdir | 0o555, &d),
        Qptmx, Qmaster => {
            // A master is ptmx's, as on Linux: its rdev is 5,2.
            dev.mkqid(&q, @bitCast(ch.qid.path), 0, c.QTFILE);
            dev.devdir(ch, q, @constCast("ptmx"), 0, c.eve, 0o666, &d);
        },
        Qslave => {
            const s = std.mem.printSentinel(&buf, "{d}", .{QNUM(ch.qid.path)}, 0) catch unreachable;
            dev.devdir(ch, ch.qid, s.ptr, 0, c.eve, 0o620, &d);
        },
        else => return port.kerror(&port.Egreg),
    }
    const n: c_int = @intCast(c.convD2M(&d, db, @intCast(n_)));
    if (n == 0)
        return port.kerror(&port.Ebadarg);
    return n;
}

fn ptyopen(ch: *Chan, omode: c_int) Error!*Chan {
    const t = QTYPE(ch.qid.path);
    if (t == Qdir) {
        if (omode != c.OREAD)
            return port.kerror(&port.Eperm);
        ch.mode = @intCast(try sysfile.openmode(@bitCast(omode)));
        ch.flag |= c.COPEN;
        ch.offset = 0;
        return ch;
    }
    // Checked before a pair is made, which a bad mode would leak.
    const mode = try sysfile.openmode(@bitCast(omode));
    dev.aux(ch).* = null;
    var p: *Pty = undefined;
    if (t == Qptmx) {
        p = try newpty();
        dev.mkqid(&ch.qid, QPATH(Qmaster, p.n), 0, c.QTFILE);
    } else if (t == Qslave) {
        c.lock(&ptys.lk);
        var pp = lookup(upmach(), QNUM(ch.qid.path));
        if (pp) |x| {
            c.lock(&x.lk);
            if (x.mopen == 0 or x.locked != 0) {
                c.unlock(&x.lk);
                pp = null;
            } else {
                if (x.sopen == 0)
                    qio.qreopen(x.out);
                x.sopen += 1;
                c.unlock(&x.lk);
            }
        }
        c.unlock(&ptys.lk);
        p = pp orelse return port.kerror(Eptyio);
    } else return port.kerror(&port.Egreg);
    dev.aux(ch).* = p;
    ch.mode = @intCast(mode);
    ch.flag |= c.COPEN;
    ch.offset = 0;
    ch.iounit = qio.qiomaxatomic;
    return ch;
}

fn ptyclose(ch: *Chan) Error!void {
    const p: *Pty = @ptrCast(@alignCast(dev.aux(ch).* orelse return));
    if (ch.flag & c.COPEN == 0)
        return;
    dev.aux(ch).* = null;
    var hup = false;
    var fg: c_uint = 0;
    c.lock(&p.lk);
    if (QTYPE(ch.qid.path) == Qmaster) {
        p.mopen -= 1;
        if (p.mopen == 0) {
            // The slave reads an end of file (Ehungup's), and writes EIO.
            qio.qhangup(p.in, null);
            qio.qhangup(p.out, Eptyio);
            hup = p.sopen > 0 and p.fg != 0;
            fg = p.fg;
            p.sid = 0;
            p.fg = 0;
        }
    } else {
        p.sopen -= 1;
        if (p.sopen == 0)
            qio.qhangup(p.out, Eptyio);
    }
    const gone = p.mopen == 0 and p.sopen == 0;
    c.unlock(&p.lk);
    if (gone)
        freepty(p);
    if (hup)
        if (h9_ptysig) |f| f(fg, Lsighup);
}

fn chanpty(ch: *Chan) Error!*Pty {
    return @ptrCast(@alignCast(dev.aux(ch).* orelse return port.kerror(&port.Egreg)));
}

fn ptyread(ch: *Chan, va: ?*anyopaque, n: c_int, off: i64) Error!c_int {
    _ = off;
    switch (QTYPE(ch.qid.path)) {
        Qdir => return dev.devdirread(ch, @ptrCast(va.?), n, null, 0, &ptygen),
        Qmaster => return qio.qread((try chanpty(ch)).out, @ptrCast(va.?), n),
        Qslave => return slaveread(try chanpty(ch), @ptrCast(va.?), n),
        else => {},
    }
    return port.kerror(&port.Egreg);
}

fn ptywrite(ch: *Chan, va: ?*const anyopaque, n: c_int, off: i64) Error!c_int {
    _ = off;
    // An empty block would read as an end of file.
    if (n == 0)
        return 0;
    switch (QTYPE(ch.qid.path)) {
        Qmaster => return masterwrite(try chanpty(ch), @ptrCast(va.?), n),
        Qslave => return slavewrite(try chanpty(ch), @ptrCast(va.?), n),
        else => {},
    }
    return port.kerror(&port.Eperm);
}

pub const Device = dev.Native(Tau, "pty", .{
    .init = ptyinit,
    .attach = ptyattach,
    .walk = ptywalk,
    .stat = ptystat,
    .open = ptyopen,
    .create = dev.devcreate,
    .close = ptyclose,
    .read = ptyread,
    .write = ptywrite,
    .remove = dev.devremove,
    .wstat = dev.devwstat,
    .gens = &.{&ptygen},
    .ready = ptyready,
    .watch = ptywatch,
    .watchers = ptywatchers,
});

/// Readiness (design/file-interface.md): an open side's queues.
fn ptyready(ch: *Chan, ev: c_int) c_int {
    if (ch.qid.type & c.QTDIR != 0) return dev.readydefault(ev);
    const rq = h9_ptyq(ch, 0) orelse return dev.readydefault(ev);
    return qio.qready(rq, h9_ptyq(ch, 1).?, ev);
}

fn ptywatchers(ch: *Chan) ?*dev.rd.Watchers {
    if (ch.qid.type & c.QTDIR != 0 or h9_ptyq(ch, 0) == null) return null;
    const p: *Pty = @ptrCast(@alignCast(dev.aux(ch).*.?));
    return &p.watch;
}

fn ptywatch(ch: *Chan, ev: c_int, w: *dev.rd.Watch, wk: *dev.rd.Waker) void {
    _ = ev;
    if (ch.qid.type & c.QTDIR != 0 or h9_ptyq(ch, 0) == null) return;
    const p: *Pty = @ptrCast(@alignCast(dev.aux(ch).*.?));
    dev.rd.add(&p.watch, w, wk);
}

/// The queue a read of ch takes from (wr == 0) or a write to ch adds
/// to, for Linux poll (src/kern/linuxnet.zig); nil if ch isn't an open side.
pub fn h9_ptyq(ch: *Chan, wr: c_int) callconv(.c) ?*Queue {
    const p: *Pty = @ptrCast(@alignCast(dev.aux(ch).* orelse return null));
    if (ch.flag & c.COPEN == 0)
        return null;
    return switch (QTYPE(ch.qid.path)) {
        Qmaster => if (wr != 0) p.in else p.out,
        Qslave => if (wr != 0) p.out else p.in,
        else => null,
    };
}

/// The pair behind fd, and its chan, with a reference for the caller;
/// nil if it isn't one.
fn fdpty(fd: c_int, cp: **Chan) Error!?*Pty {
    const ch = try sysfile.fdtochan(fd, -1, false, true);
    if (dev.of(ch).dc != Tau or dev.aux(ch).* == null or (ch.flag & c.COPEN) == 0) {
        chan.cclose(ch);
        return null;
    }
    cp.* = ch;
    return @ptrCast(@alignCast(dev.aux(ch).*.?));
}

/// Copies the state of the pair behind fd into s. Returns 0, or -1 if
/// fd isn't a side of a pair.
pub fn h9_pty_get(fd: c_int, s: *Ptystate) callconv(.c) c_int {
    var ch: *Chan = undefined;
    const p = (fdpty(fd, &ch) catch return -1) orelse return -1;
    c.lock(&p.lk);
    s.termios = p.termios;
    s.winsz = p.winsz;
    s.fg = p.fg;
    s.sid = p.sid;
    s.locked = p.locked;
    s.n = p.n;
    s.master = @intFromBool(QTYPE(ch.qid.path) == Qmaster);
    s.slaveopen = @intFromBool(p.sopen > 0);
    c.unlock(&p.lk);
    chan.cclose(ch);
    return 0;
}

/// Sets the fields of the pair behind fd that `what` names (Stermios,
/// Swinsz, Sfg, Ssid, and Slock) from s. With Ssid and Sfg together and
/// `excl`, it sets them only if the pair is no session's terminal yet, as
/// an open of the slave by a session leader takes it. Returns 0, 1 if
/// excl left it as it was, or -1 if fd isn't a side of a pair.
pub fn h9_pty_set(fd: c_int, s: *const Ptystate, what: c_int, excl: c_int) callconv(.c) c_int {
    var ch: *Chan = undefined;
    const p = (fdpty(fd, &ch) catch return -1) orelse return -1;
    var r: c_int = 0;
    c.lock(&p.lk);
    if (excl != 0 and p.sid != 0) {
        r = 1;
    } else {
        if (what & Stermios != 0) {
            p.termios = s.termios;
            // Out of canonical mode, a line being edited is input to read.
            if ((flag(p, 12) & ICANON) == 0 and p.nline > 0) {
                _ = qio.qiwrite(p.in, &p.line, p.nline);
                p.nline = 0;
            }
        }
        if (what & Swinsz != 0)
            p.winsz = s.winsz;
        if (what & Sfg != 0)
            p.fg = s.fg;
        if (what & Ssid != 0)
            p.sid = s.sid;
        if (what & Slock != 0)
            p.locked = s.locked;
    }
    c.unlock(&p.lk);
    chan.cclose(ch);
    return r;
}

/// The number of the caller's machine's pair that is session sid's
/// terminal, or -1: what /dev/tty opens.
pub fn h9_pty_bysid(sid: c_uint) callconv(.c) c_int {
    if (sid == 0)
        return -1;
    const m = upmach();
    var n: c_int = -1;
    c.lock(&ptys.lk);
    var p = ptys.list;
    while (p) |pp| : (p = pp.next) {
        if (pp.mach == m and pp.sid == sid and pp.mopen > 0) {
            n = pp.n;
            break;
        }
    }
    c.unlock(&ptys.lk);
    return n;
}

/// Bytes queued for fd: to read (wr == 0) or written and not yet read
/// (wr == 1); -1 if fd isn't a side of a pair. With flush, they're
/// discarded instead, and the count is 0.
pub fn h9_pty_queued(fd: c_int, wr: c_int, flush: c_int) callconv(.c) c_int {
    const ch = sysfile.fdtochan(fd, -1, false, true) catch return -1;
    defer chan.cclose(ch);
    if (dev.of(ch).dc != Tau)
        return -1;
    const q = h9_ptyq(ch, wr) orelse return -1;
    if (flush != 0) {
        qio.qflush(q);
        return 0;
    }
    return qio.qlen(q);
}

pub fn h9_pty_setsig(f: ?Ptysig) callconv(.c) void {
    h9_ptysig = f;
}

pub fn exportC() void {
    @export(&Device.dev, .{ .name = "ptydevtab" });
    @export(&h9_ptyq, .{ .name = "h9_ptyq" });
    @export(&h9_pty_get, .{ .name = "h9_pty_get" });
    @export(&h9_pty_set, .{ .name = "h9_pty_set" });
    @export(&h9_pty_bysid, .{ .name = "h9_pty_bysid" });
    @export(&h9_pty_queued, .{ .name = "h9_pty_queued" });
    @export(&h9_pty_setsig, .{ .name = "h9_pty_setsig" });
}

// Cases (zig build kern-test). The namespace kernel has no #τ in its
// table, so they drive a pair directly, as its open and its sides' reads
// and writes do.

const testing = std.testing;
const kt = port.testing;

fn testPty() !*Pty {
    _ = try kt.begin();
    if (defterm[0] == 0) ptyinit();
    const p = try newpty();
    c.lock(&p.lk);
    p.locked = 0;
    p.sopen = 1;
    c.unlock(&p.lk);
    qio.qreopen(p.out);
    return p;
}

fn drop(p: *Pty) void {
    c.lock(&p.lk);
    p.mopen = 0;
    p.sopen = 0;
    c.unlock(&p.lk);
    freepty(p);
}

fn readout(p: *Pty, buf: []u8) ![]u8 {
    const n = qio.qconsume(p.out, buf.ptr, @intCast(buf.len));
    if (n < 0) return buf[0..0];
    return buf[0..@intCast(n)];
}

test "a pty's canonical mode edits a line, echoes it, and the slave reads it whole [kernel-port]" {
    const p = try testPty();
    defer drop(p);
    // "ab", erase, "c", then return: the slave reads "ac\n", the master
    // the echo with the erase and ONLCR's CRLF.
    const in = "ab\x7fc\r";
    try testing.expectEqual(@as(c_int, in.len), try masterwrite(p, in, in.len));
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("ab\x08 \x08c\r\n", try readout(p, &buf));
    try testing.expectEqual(3, try slaveread(p, &buf, buf.len));
    try testing.expectEqualStrings("ac\n", buf[0..3]);

    // VEOF on an empty line is an end of file: an empty block.
    try testing.expectEqual(1, try masterwrite(p, "\x04", 1));
    try testing.expectEqual(0, try slaveread(p, &buf, buf.len));

    // The slave's output goes through ONLCR.
    try testing.expectEqual(3, try slavewrite(p, "x\ny", 3));
    try testing.expectEqualStrings("x\r\ny", try readout(p, &buf));
}

var sigsent: [4]c_int = undefined;
var nsigsent: usize = 0;
fn recordsig(fg: c_ulong, signo: c_int) callconv(.c) void {
    _ = fg;
    sigsent[nsigsent] = signo;
    nsigsent += 1;
}

test "a pty's ISIG characters signal the foreground group and flush the line [kernel-port]" {
    const p = try testPty();
    defer drop(p);
    const old = h9_ptysig;
    defer h9_ptysig = old;
    h9_pty_setsig(&recordsig);
    nsigsent = 0;
    p.fg = 7;
    try testing.expectEqual(4, try masterwrite(p, "abc\x03", 4));
    try testing.expectEqual(1, nsigsent);
    try testing.expectEqual(Lsigint, sigsent[0]);
    try testing.expectEqual(0, p.nline);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("abc^C", try readout(p, &buf));

    // Raw mode: bytes pass as they are, and with no ECHO nothing comes back.
    std.mem.writeInt(u32, p.termios[12..16], 0, .little);
    try testing.expectEqual(3, try masterwrite(p, "q\rz", 3));
    try testing.expectEqual(3, try slaveread(p, &buf, buf.len));
    try testing.expectEqualStrings("q\nz", buf[0..3]);
    try testing.expectEqualStrings("", try readout(p, &buf));
}

test "pairs are numbered from 0 and their numbers reused [kernel-port]" {
    const a = try testPty();
    const b = try testPty();
    try testing.expectEqual(a.n + 1, b.n);
    const n = a.n;
    drop(a);
    const a2 = try testPty();
    try testing.expectEqual(n, a2.n);
    drop(a2);
    drop(b);
}
