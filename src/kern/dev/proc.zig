//! h9's devproc.c (design/kernel-port.md): `#p`, /proc, ported from
//! 9front's port/devproc.c at the pinned release (NINEFRONT_REV),
//! serving h9's process records (src/kern/proc.zig, hproc.h) instead of
//! 9front's Proc table. See SPEC.md, "Process model". A close
//! translation of the C, with error unions in place of error labels. A
//! native device (dev.zig's `Native`).
//!
//! A machine sees only its own processes: the directory lists and walks
//! the caller's machine, by machine-local pid, and the pid in a qid is
//! looked up in the caller's machine on every open, read and write.
//!
//! Served: args, ctl (kill, hang, nohang, close, closefiles, stop,
//! start, waitstop, startstop), fd, fpregs, mem, note, noteid, notepg,
//! ns, ppid, regs, segment, status, text and wait. The debugging files
//! and ctl messages, which acid uses, are design/epoch-0/self-host.md's:
//! memory and registers come from the Zig process through h9_procdebug,
//! and the stopping is proc.zig's. kregs, kfpregs, proc, profile,
//! syscall, trace and watchpt have no meaning here, nor do traceme,
//! startsyscall, profile, wired, pri and the real-time messages. The CPU
//! times in status are 0.
//!
//! The record's debug QLock stands in for 9front's p->debug: the process
//! takes it to swap its groups (rfork, chdir) and to mark itself gone at
//! exit, so a reader that holds it can take references to the groups.
//!
//! A process waits here only in sync.zig's sleep: for a wait record, and
//! for another process to stop.

const std = @import("std");
const port = @import("../port.zig");
const sync = @import("../sync.zig");
const dev = @import("../dev.zig");
const chan = @import("../chan.zig");
const pgrp = @import("../pgrp.zig");
const sysfile = @import("../sysfile.zig");
const proc = @import("../proc.zig");
const c = port.c;
const up = port.up;
const Error = port.Error;

const Chan = c.Chan;
const Dir = c.Dir;
const Dirtab = c.Dirtab;
const Walkqid = c.Walkqid;
const Qid = c.Qid;
const Proc = c.Proc;
const Hmach = c.Hmach;
const Hnote = c.Hnote;
const Hwait = c.Hwait;
const Pgrp = c.Pgrp;
const Fgrp = c.Fgrp;
const Mount = c.Mount;

extern fn h9_overlay_nsunion(ch: *Chan, old: [*:0]const u8, buf: [*]u8, nbuf: c_int) c_int; // devoverlay.c
extern fn procfdprint(ch: *Chan, fd: c_int, w: c_int, s: [*]u8, ns: c_int) c_int; // devdup.c

const Qdir = 0;
const Qargs = 1;
const Qctl = 2;
const Qfd = 3;
const Qfpregs = 4;
const Qmem = 5;
const Qnote = 6;
const Qnoteid = 7;
const Qnotepg = 8;
const Qns = 9;
const Qppid = 10;
const Qregs = 11;
const Qsegment = 12;
const Qstatus = 13;
const Qtext = 14;
const Qwait = 15;

const CMclose = 0;
const CMclosefiles = 1;
const CMhang = 2;
const CMkill = 3;
const CMnohang = 4;
const CMstart = 5;
const CMstartstop = 6;
const CMstop = 7;
const CMwaitstop = 8;

const QSHIFT = 5; // the file's Q in the low bits, the pid above
const Procmode = 0o640; // 9front's default p->procmode
const Npids = 1024; // processes listed in /proc
const PriNormal = 10;

fn QID(q: Qid) u64 {
    return q.path & ((1 << QSHIFT) - 1);
}
fn PIDQ(q: Qid) c_uint {
    return @truncate(q.path >> QSHIFT);
}

fn qid(path: u64) Qid {
    return .{ .path = path, .vers = 0, .type = 0 };
}

var procdir = [_]Dirtab{
    dev.dirtab("args", qid(Qargs), 0, 0o660),
    dev.dirtab("ctl", qid(Qctl), 0, 0o000),
    dev.dirtab("fd", qid(Qfd), 0, 0o444),
    dev.dirtab("fpregs", qid(Qfpregs), 0, 0o000),
    dev.dirtab("mem", qid(Qmem), 0, 0o000),
    dev.dirtab("note", qid(Qnote), 0, 0o000),
    dev.dirtab("noteid", qid(Qnoteid), 0, 0o664),
    dev.dirtab("notepg", qid(Qnotepg), 0, 0o000),
    dev.dirtab("ns", qid(Qns), 0, 0o444),
    dev.dirtab("ppid", qid(Qppid), 0, 0o444),
    dev.dirtab("regs", qid(Qregs), 0, 0o000),
    dev.dirtab("segment", qid(Qsegment), 0, 0o444),
    dev.dirtab("status", qid(Qstatus), 0, 0o444),
    dev.dirtab("text", qid(Qtext), 0, 0o000),
    dev.dirtab("wait", qid(Qwait), 0, 0o400),
};

const Cmd = struct { index: c_int, cmd: [:0]const u8, narg: c_int };

const proccmd = [_]Cmd{
    .{ .index = CMclose, .cmd = "close", .narg = 2 },
    .{ .index = CMclosefiles, .cmd = "closefiles", .narg = 1 },
    .{ .index = CMhang, .cmd = "hang", .narg = 1 },
    .{ .index = CMkill, .cmd = "kill", .narg = 1 },
    .{ .index = CMnohang, .cmd = "nohang", .narg = 1 },
    .{ .index = CMstart, .cmd = "start", .narg = 1 },
    .{ .index = CMstartstop, .cmd = "startstop", .narg = 1 },
    .{ .index = CMstop, .cmd = "stop", .narg = 1 },
    .{ .index = CMwaitstop, .cmd = "waitstop", .narg = 1 },
};

// drawterm's parse.c's cmderror and lookupcmd, which raise. parsecmd is
// the C's: it doesn't.

/// Reconstruct original message, for error diagnostic
fn cmderror(cb: *c.Cmdbuf, s: [*:0]const u8) error{Kernel} {
    const buf: [*]u8 = &up().genbuf;
    const e = buf + port.ERRMAX - 10;
    var p = c.seprint(buf, e, @constCast("%s \""), s);
    var i: c_int = 0;
    while (i < cb.nf) : (i += 1) {
        if (i > 0)
            p = c.seprint(p, e, @constCast(" "));
        p = c.seprint(p, e, @constCast("%q"), cb.f[@intCast(i)]);
    }
    _ = c.strcpy(p, "\"");
    return port.kerror(@ptrCast(buf));
}

/// Look up entry in table
fn lookupcmd(cb: *c.Cmdbuf, ctab: []const Cmd) Error!*const Cmd {
    if (cb.nf == 0)
        return port.kerror("empty control message");

    for (ctab) |*ct| {
        if (!dev.streq(ct.cmd, "*")) // wildcard always matches
            if (!dev.streq(ct.cmd, cb.f[0]))
                continue;
        if (ct.narg != 0 and ct.narg != cb.nf)
            return cmderror(cb, &port.Ecmdargs);
        return ct;
    }

    return cmderror(cb, "unknown control message");
}

fn upmach() Error!*Hmach {
    return (try uphproc()).mach;
}

fn uphproc() Error!*Proc {
    const p: ?*Proc = c._getproc();
    if (p == null or p.?.mach == null)
        return port.kerror("not an h9 process");
    return p.?;
}

/// The process the chan names, in the caller's machine, with a
/// reference.
fn chanproc(ch: *Chan) Error!*Proc {
    return proc.h9_pidlookup(try upmach(), PIDQ(ch.qid)) orelse port.kerror(&port.Eprocdied);
}

/// procgen fails, as the C's raised, when the caller isn't a guest
/// process, so it's an Egen (dev.zig), whose Zig the switch calls
/// directly.
fn procgen(ch: *Chan, name_: ?[*:0]const u8, tab: ?[*]Dirtab, ntab: c_int, s: c_int, dp: *Dir) Error!c_int {
    _ = .{ tab, ntab };
    var q: Qid = undefined;
    if (s == c.DEVDOTDOT) {
        dev.mkqid(&q, Qdir, 0, c.QTDIR);
        dev.devdir(ch, q, @constCast("#p"), 0, c.eve, 0o555, dp);
        return 1;
    }

    const genbuf: [*]u8 = &up().genbuf;
    if (ch.qid.path == Qdir) {
        var pid: c_uint = undefined;
        if (name_) |name| {
            // ignore s and use name to find pid
            var ename: [*c]u8 = undefined;
            pid = @truncate(c.strtoul(name, &ename, 10));
            if (pid == 0 or ename[0] != 0)
                return -1;
        } else {
            var pids: [Npids]c_uint = undefined;
            const n = proc.h9_pids(try upmach(), &pids, pids.len);
            if (s >= n)
                return -1;
            pid = pids[@intCast(s)];
        }
        const h = proc.h9_pidlookup(try upmach(), pid) orelse
            return if (name_ != null) -1 else 0;
        proc.h9_putproc(h);
        // String comparison is done in devwalk so name must match its
        // formatted pid.
        _ = c.snprint(genbuf, @sizeOf(@TypeOf(up().genbuf)), @constCast("%lud"), pid);
        if (name_) |name| if (!dev.streq(name, @ptrCast(genbuf)))
            return -1;
        dev.mkqid(&q, @as(i64, pid) << QSHIFT, pid, c.QTDIR);
        dev.devdir(ch, q, genbuf, 0, c.eve, 0o555, dp);
        return 1;
    }

    if (s >= procdir.len)
        return -1;
    const t = &procdir[@intCast(s)];
    const pid = PIDQ(ch.qid);
    const h = proc.h9_pidlookup(try upmach(), pid) orelse return -1;
    var perm = t.perm;
    if (perm == 0)
        perm = Procmode
    else // just copy read bits
        perm |= Procmode & 0o444;
    var n: i64 = 0;
    if (t.qid.path == Qwait)
        n = h.nwait; // incorrect size, but >0 means there's something to read
    proc.h9_putproc(h);
    dev.mkqid(&q, @intCast((@as(u64, pid) << QSHIFT) | t.qid.path), ch.qid.vers, c.QTFILE);
    dev.devdir(ch, q, &t.name, n, c.eve, perm, dp);
    return 1;
}

fn procattach(spec: [*:0]const u8) Error!*Chan {
    return dev.devattach('p', spec);
}

fn procwalk(ch: *Chan, nc: ?*Chan, name: [*]const [*:0]const u8, nname: c_int) Error!?*Walkqid {
    return dev.devwalk(ch, nc, name, nname, null, 0, procgenE.c);
}

fn procstat(ch: *Chan, db: [*]u8, n: c_int) Error!c_int {
    return dev.devstat(ch, db, n, null, 0, procgenE.c);
}

fn procopen(ch: *Chan, omode0: c_int) Error!*Chan {
    if (ch.qid.type & c.QTDIR != 0)
        return dev.devopen(ch, omode0, null, 0, procgenE.c);

    const h = try chanproc(ch);
    defer proc.h9_putproc(h);
    const omode = try sysfile.openmode(@bitCast(omode0));
    var vers = h.pid;
    switch (QID(ch.qid)) {
        Qstatus, Qppid, Qsegment, Qns, Qfd => if (omode != c.OREAD)
            return port.kerror(&port.Eperm),

        Qctl, Qargs, Qwait, Qnoteid, Qnote, Qmem, Qregs, Qfpregs => {},

        Qtext => {
            // As 9front's proctext: the open is the image's own channel.
            if (omode != c.OREAD)
                return port.kerror(&port.Eperm);
            c.lock(&h.nlk);
            const tc_: ?*Chan = h.textc;
            if (tc_) |tc|
                _ = chan.incref(&tc.ref);
            c.unlock(&h.nlk);
            const tc = tc_ orelse return port.kerror(&port.Eprocdied);
            tc.offset = 0;
            chan.cclose(ch);
            return tc;
        },

        Qnotepg => {
            if (omode != c.OWRITE)
                return port.kerror(&port.Eperm);
            // Remember the group, as 9front does: writes go to it.
            vers = h.noteid;
        },

        else => return port.kerror(&port.Egreg),
    }
    if (vers == 0)
        return port.kerror(&port.Eprocdied);
    ch.qid.vers = vers;
    return dev.devopen(ch, omode, null, 0, procgenE.c);
}

fn procclose(ch: *Chan) Error!void {
    _ = ch;
}

fn procargs(h: *Proc, buf: [*]u8, nbuf: c_int) c_int {
    c.lock(&h.alk);
    defer c.unlock(&h.alk);
    if (h.setargs != 0)
        return c.snprint(buf, nbuf, @constCast("%s [%s]"), @as([*]u8, &h.text), @as([*]u8, &h.args));
    var a: [*]u8 = &h.args;
    var n = h.nargs;
    var j: c_int = 0;
    while (j < nbuf - 1) {
        if (n <= 0)
            break;
        if (j != 0) {
            buf[@intCast(j)] = ' ';
            j += 1;
        }
        const m = c.snprint(buf + @as(usize, @intCast(j)), nbuf - j, @constCast("%q"), a);
        const k: c_int = @intCast(std.mem.len(@as([*:0]u8, @ptrCast(a))) + 1);
        a += @intCast(k);
        n -= k;
        j += m;
    }
    return j;
}

fn int2flag(flag: c_int, s_: [*]u8) void {
    var s = s_;
    if (flag == 0) {
        s[0] = 0;
        return;
    }
    s[0] = '-';
    s += 1;
    for ([_]struct { c_int, u8 }{ .{ c.MAFTER, 'a' }, .{ c.MBEFORE, 'b' }, .{ c.MCREATE, 'c' }, .{ c.MCACHE, 'C' } }) |f| {
        if (flag & f[0] != 0) {
            s[0] = f[1];
            s += 1;
        }
    }
    s[0] = 0;
}

/// The target's groups and dot, with references, taken under its debug
/// lock so it can't swap or drop them meanwhile. Eprocdied if it has
/// gone.
const Groups = struct {
    pg: ?*Pgrp = null,
    fg: ?*Fgrp = null,
    dot: ?*Chan = null,
};

fn takegroups(h: *Proc) Error!Groups {
    var g: Groups = .{};
    sync.qlock(&h.debug);
    defer sync.qunlock(&h.debug);
    const dot: *Chan = h.dot orelse return port.kerror(&port.Eprocdied);
    g.dot = dot;
    _ = chan.incref(&dot.ref);
    g.pg = h.pgrp;
    if (g.pg) |pg|
        _ = chan.incref(&pg.ref);
    g.fg = h.fgrp;
    if (g.fg) |fg|
        _ = chan.incref(&fg.ref);
    return g;
}

fn dropgroups(g: *Groups) void {
    if (g.pg) |pg|
        pgrp.closepgrp(pg);
    if (g.fg) |fg|
        proc.h9_fgrpclose(fg);
    if (g.dot) |dot|
        chan.cclose(dot);
}

fn readns1(ch: *Chan, g: *Groups, buf: [*]u8, nbuf: c_int) Error!c_int {
    const pg = g.pg orelse return port.kerror(&port.Eprocdied);
    if (ch.nrock < 0)
        return 0;

    sync.rlock(&pg.ns);
    defer sync.runlock(&pg.ns);
    var i: c_int = 0;
    var f_: ?*Mount = pg.mntorder;
    while (f_) |f| : (f_ = f.order) {
        if (i >= ch.nrock)
            break;
        i += 1;
    }
    if (f_) |f| {
        ch.nrock = i + 1;
        var flag: [10]u8 = undefined;
        int2flag(f.mflag, &flag);
        const fp: [*]u8 = &flag;
        const from = chan.chanpath(f.umh.*.from);
        if (dev.streq(chan.chanpath(f.to), "#M")) {
            // A posted channel prints as its /srv name, as on 9front
            // (design/epoch-0/devsrv.md).
            const mc: *Chan = f.to.*.mchan;
            const srv: [*c]const u8 = if (mc.srvname != null) mc.srvname else chan.chanpath(mc);
            const spec: [*:0]u8 = @ptrCast(f.spec());
            i = if (spec[0] != 0)
                c.snprint(buf, nbuf, @constCast("mount %s %q %q %q\n"), fp, srv, from, spec)
            else
                c.snprint(buf, nbuf, @constCast("mount %s %q %q\n"), fp, srv, from);
        } else {
            // An unnamed union as the bind -r lines that make it
            // (design/epoch-0/mounts.md).
            i = h9_overlay_nsunion(f.to, from, buf, nbuf);
            if (i < 0)
                i = c.snprint(buf, nbuf, @constCast("bind %s %q %q\n"), fp, chan.chanpath(f.to), from);
        }
    } else {
        ch.nrock = -1;
        i = c.snprint(buf, nbuf, @constCast("cd %q\n"), chan.chanpath(g.dot));
    }
    return i;
}

fn readfd1(ch: *Chan, g: *Groups, buf: [*]u8, nbuf: c_int) c_int {
    const fg = g.fg orelse return 0;
    if (ch.nrock == 0) {
        ch.nrock = 1;
        return c.snprint(buf, nbuf, @constCast("%s\n"), chan.chanpath(g.dot));
    }
    c.lock(&fg.ref.lk);
    defer c.unlock(&fg.ref.lk);
    var n: c_int = 0;
    while (true) {
        const i = ch.nrock - 1;
        if (i < 0 or i > fg.maxfd)
            break;
        ch.nrock += 1;
        if (@as(?*Chan, fg.fd[@intCast(i)])) |f| {
            n = procfdprint(f, i, 0, buf, nbuf);
            break;
        }
    }
    return n;
}

fn prochaswaitq(x: ?*anyopaque) callconv(.c) c_int {
    const h: *Proc = @ptrCast(@alignCast(x.?));
    return @intFromBool(@as(*volatile c_int, &h.exited).* != 0 or @as(*volatile [*c]Hwait, &h.waitq).* != null);
}

fn statusread(h: *Proc, buf: [*]u8, nbuf: c_int) c_int {
    var state: [c.KNAMELEN]u8 = undefined;
    var mem: c_uint = 0;

    _ = c.strcpy(&state, "New");
    c.lock(&h.nlk);
    if (h.exited != 0)
        _ = c.strcpy(&state, "Moribund")
    else if (h.stopped != 0)
        _ = c.strcpy(&state, "Stopped")
    else if (h.stopwait != 0)
        _ = c.strcpy(&state, "Stopwait")
    else if (h.aux != null) if (c.h9_procstatus) |f|
        f(h.aux, &state, state.len, &mem);
    c.unlock(&h.nlk);
    const zero: c_uint = 0;
    const pri: c_uint = PriNormal;
    return c.snprint(buf, nbuf, @constCast("%-27s %-27s %-11s " ++
        "%11lud %11lud %11lud " ++
        "%11lud %11lud %11lud " ++
        "%11lud %11lud %11lud\n"), @as([*]u8, &h.text), c.eve, @as([*]u8, &state), zero, zero, c.ticks() -% h.start, zero, zero, zero, mem, pri, pri);
}

/// Moves n bytes of process h's memory or registers at off through the
/// Zig side, with the error for a failure. Writes need it stopped, as on
/// 9front.
fn procdebugio(h: *Proc, what: c_int, write: bool, off: u64, va: ?*anyopaque, n: c_int) Error!c_int {
    c.lock(&h.nlk);
    if (write and h.stopped == 0) {
        c.unlock(&h.nlk);
        return port.kerror(&port.Ebadctl);
    }
    var r: c_int = c.Dnoreg;
    if (h.exited != 0)
        r = 0
    else if (h.aux != null) if (c.h9_procdebug) |f| {
        r = f(h.aux, what, @intFromBool(write), off, va, n);
    };
    c.unlock(&h.nlk);
    if (h.exited != 0)
        return port.kerror(&port.Eprocdied);
    return switch (r) {
        c.Dbadaddr => port.kerror("bad address"),
        c.Dnoreg => port.kerror(&port.Enoreg),
        c.Dnomem => port.kerror(&port.Enomem),
        else => r,
    };
}

fn procread(ch: *Chan, va_: ?*anyopaque, n_: c_int, off: i64) Error!c_int {
    var statbuf: [8192]u8 = undefined; // ns prints a union as a line per member
    var offset: c_uint = @truncate(@as(u64, @bitCast(off)));
    var n = n_;
    const va: [*]u8 = @ptrCast(va_.?);

    if (ch.qid.type & c.QTDIR != 0)
        return dev.devdirread(ch, va, n, null, 0, procgenE.c);

    const h = try chanproc(ch);
    defer proc.h9_putproc(h);

    var j: c_int = undefined;
    switch (QID(ch.qid)) {
        Qctl => return c.readnum(offset, va, @bitCast(n), h.pid, c.NUMSIZE),
        Qnoteid => return c.readnum(offset, va, @bitCast(n), h.noteid, c.NUMSIZE),
        Qmem => return procdebugio(h, c.Dmem, false, @bitCast(off), va, n),
        Qregs => return procdebugio(h, c.Dregs, false, @bitCast(off), va, n),
        Qfpregs => return procdebugio(h, c.Dfpregs, false, @bitCast(off), va, n),
        Qppid => return c.readnum(offset, va, @bitCast(n), h.ppid, c.NUMSIZE),

        Qstatus => j = statusread(h, &statbuf, statbuf.len),

        Qargs => j = procargs(h, &statbuf, statbuf.len),

        Qsegment => {
            j = 0;
            c.lock(&h.nlk);
            if (h.exited == 0 and h.aux != null) if (c.h9_procsegment) |f| {
                j = f(h.aux, &statbuf, statbuf.len);
            };
            c.unlock(&h.nlk);
        },

        Qwait => {
            if (!sync.canqlock(&h.qwaitr))
                return port.kerror(&port.Einuse);
            const w = blk: {
                defer sync.qunlock(&h.qwaitr);
                c.lock(&h.exl);
                while (h.waitq == null and h.exited == 0) {
                    if (h == up() and h.nchild == 0) {
                        c.unlock(&h.exl);
                        return port.kerror(&port.Enochild);
                    }
                    c.unlock(&h.exl);
                    try sync.sleep(&h.waitr, prochaswaitq, h);
                    c.lock(&h.exl);
                }
                const w: *Hwait = h.waitq orelse {
                    c.unlock(&h.exl);
                    return port.kerror(&port.Eprocdied);
                };
                h.waitq = w.next;
                h.nwait -= 1;
                c.unlock(&h.exl);
                break :blk w;
            };
            j = c.snprint(&statbuf, statbuf.len, @constCast("%lud %lud %lud %lud %q"), w.pid, w.time[0], w.time[1], w.time[2], @as([*]u8, &w.msg));
            c.free(w);
            offset = 0;
        },

        Qns, Qfd => {
            var g = try takegroups(h);
            {
                defer dropgroups(&g);
                if (offset == 0 or offset != ch.mrock) {
                    ch.nrock = 0;
                    ch.mrock = 0;
                }
                j = 0;
                while (true) {
                    if (QID(ch.qid) == Qns)
                        j = try readns1(ch, &g, &statbuf, statbuf.len)
                    else
                        j = readfd1(ch, &g, &statbuf, statbuf.len);
                    if (j == 0)
                        break;
                    ch.mrock += j;
                    if (ch.mrock > offset)
                        break;
                }
            }
            const i: c_int = ch.mrock -% @as(c_int, @bitCast(offset));
            if (i <= 0 or i > j)
                return 0;
            if (i < n)
                n = i;
            offset = @intCast(j - i);
        },

        Qnote => {
            if (n < 1) // must accept at least the '\0'
                return port.kerror(&port.Etoosmall);
            c.lock(&h.nlk);
            defer c.unlock(&h.nlk);
            if (h.nnote == 0)
                return 0;
            const note: *Hnote = h.note[0];
            const i: c_int = @intCast(std.mem.len(@as([*:0]u8, @ptrCast(&note.msg))) + 1);
            if (i < n)
                n = i;
            const m: usize = @intCast(n - 1);
            @memcpy(va[0..m], note.msg[0..m]);
            va[m] = 0;
            proc.h9_freenote(note);
            h.nnote -= 1;
            const nn: usize = @intCast(h.nnote);
            if (nn > 0)
                std.mem.copyForwards([*c]Hnote, h.note[0..nn], h.note[1 .. nn + 1]);
            h.note[nn] = null;
            return n;
        },

        else => return port.kerror(&port.Egreg),
    }

    // statbufread:
    const o: usize = offset;
    if (o >= j)
        return 0;
    if (o + @as(usize, @intCast(n)) > j)
        n = j - @as(c_int, @intCast(o));
    const len: usize = @intCast(n);
    @memcpy(va[0..len], statbuf[o .. o + len]);
    return n;
}

fn procctlclosefiles(h: *Proc, all: bool, fd_: c_int) Error!void {
    var fd = fd_;
    if (fd < 0)
        return port.kerror(&port.Ebadfd);
    var g = try takegroups(h);
    defer dropgroups(&g);
    const f = g.fg orelse return port.kerror(&port.Eprocdied);
    c.lock(&f.ref.lk);
    while (fd <= f.maxfd) {
        if (@as(?*Chan, f.fd[@intCast(fd)])) |ch| {
            f.fd[@intCast(fd)] = null;
            c.unlock(&f.ref.lk);
            chan.cclose(ch);
            c.lock(&f.ref.lk);
        }
        if (!all)
            break;
        fd += 1;
    }
    c.unlock(&f.ref.lk);
}

fn stoppedorgone(a: ?*anyopaque) callconv(.c) c_int {
    const h: *Proc = @ptrCast(@alignCast(a.?));
    return @intFromBool(@as(*volatile c_int, &h.stopped).* != 0 or @as(*volatile c_int, &h.exited).* != 0);
}

/// 9front's procstopwait: asks h to stop with ctl (Pstopme, Ptraceme; 0
/// only waits) and waits until it has, unless it's the caller, which
/// stops at its next stop point. A process spinning in guest code is
/// kicked; one blocked in a syscall stops when the call returns.
fn procstopwait(h: *Proc, ctl: c_int) Error!void {
    const me = try uphproc();
    c.lock(&h.nlk);
    // Unlike 9front, a process may stop itself while a debugger waits
    // for it to: it doesn't wait, so they don't conflict.
    if (h.pdbg != 0 and h != me) {
        c.unlock(&h.nlk);
        return port.kerror(&port.Einuse);
    }
    if (h.stopped != 0 or h.exited != 0) {
        c.unlock(&h.nlk);
        return;
    }
    if (ctl != 0) {
        h.procctl = ctl;
        if (h.aux != null) if (c.h9_stopkick) |k| k(h.aux);
    }
    if (h == me) {
        c.unlock(&h.nlk);
        return;
    }
    h.pdbg = 1;
    c.unlock(&h.nlk);
    me.stopwait = 1;
    defer {
        me.stopwait = 0;
        c.lock(&h.nlk);
        h.pdbg = 0;
        c.unlock(&h.nlk);
    }
    try sync.sleep(&h.stopr, stoppedorgone, h);
    if (h.exited != 0)
        return port.kerror(&port.Eprocdied);
}

/// Resumes a stopped process, for ctl start and startstop.
fn procstart(h: *Proc, ctl: c_int) Error!void {
    c.lock(&h.nlk);
    if (h.stopped == 0) {
        c.unlock(&h.nlk);
        return port.kerror(&port.Ebadctl);
    }
    h.procctl = ctl;
    h.stopped = 0;
    c.unlock(&h.nlk);
    _ = sync.wakeup(&h.startr);
}

fn procctlreq(h: *Proc, va: [*]u8, n: c_int) Error!void {
    const cb: *c.Cmdbuf = c.parsecmd(va, n);
    defer c.free(cb);
    const ct = try lookupcmd(cb, &proccmd);
    switch (ct.index) {
        CMclose => try procctlclosefiles(h, false, c.atoi(cb.f[1])),
        CMclosefiles => try procctlclosefiles(h, true, 0),
        CMhang => h.hang = 1,
        CMkill => proc.h9_killproc(h),
        CMnohang => h.hang = 0,
        CMstart => try procstart(h, 0),
        CMstartstop => {
            try procstart(h, c.Ptraceme);
            try procstopwait(h, c.Ptraceme);
        },
        CMstop => try procstopwait(h, c.Pstopme),
        CMwaitstop => try procstopwait(h, 0),
        else => return port.kerror(&port.Ebadctl),
    }
}

fn procwrite(ch: *Chan, va_: ?*const anyopaque, n: c_int, off: i64) Error!c_int {
    var buf: [port.ERRMAX]u8 = undefined;
    const offset: c_uint = @truncate(@as(u64, @bitCast(off)));
    const va: [*]u8 = @ptrCast(@constCast(va_.?));

    if (ch.qid.type & c.QTDIR != 0)
        return port.kerror(&port.Eisdir);

    // use the remembered noteid in the channel qid
    if (QID(ch.qid) == Qnotepg) {
        if (n >= buf.len)
            return port.kerror(&port.Etoobig);
        const len: usize = @intCast(n);
        @memcpy(buf[0..len], va[0..len]);
        buf[len] = 0;
        proc.h9_postnotepg(try upmach(), ch.qid.vers, @ptrCast(&buf), c.NUser);
        return n;
    }

    const h = try chanproc(ch);
    defer proc.h9_putproc(h);
    switch (QID(ch.qid)) {
        Qargs => {
            if (offset != 0 or n >= buf.len or n >= c.ARGSLEN)
                return port.kerror(&port.Etoobig);
            const len: usize = @intCast(n);
            c.lock(&h.alk);
            @memcpy(h.args[0..len], va[0..len]);
            h.args[len] = 0;
            h.nargs = 0;
            h.setargs = 1;
            c.unlock(&h.alk);
        },

        Qctl => try procctlreq(h, va, n),

        Qmem => return procdebugio(h, c.Dmem, true, @bitCast(off), va, n),
        Qregs => return procdebugio(h, c.Dregs, true, @bitCast(off), va, n),
        Qfpregs => return procdebugio(h, c.Dfpregs, true, @bitCast(off), va, n),

        Qnote => {
            if (n >= buf.len)
                return port.kerror(&port.Etoobig);
            const len: usize = @intCast(n);
            @memcpy(buf[0..len], va[0..len]);
            buf[len] = 0;
            const nt = proc.h9_mknote(@ptrCast(&buf), c.NUser) orelse return port.kerror(&port.Enomem);
            if (proc.h9_pushnote(h, nt) == 0)
                return port.kerror("note not posted");
        },

        Qnoteid => {
            if (offset != 0 or n >= buf.len)
                return port.kerror(&port.Etoobig);
            const len: usize = @intCast(n);
            @memcpy(buf[0..len], va[0..len]);
            buf[len] = 0;
            const id = c.atoi(&buf);
            if (id <= 0)
                return port.kerror(&port.Ebadarg);
            if (proc.h9_setnoteid(h, @intCast(id)) < 0)
                return port.kerror(&port.Eperm);
        },

        else => return port.kerror(&port.Egreg),
    }
    return n;
}

const procgenE = dev.egen(procgen);

pub const Device = dev.Native('p', "proc", .{
    .attach = procattach,
    .walk = procwalk,
    .stat = procstat,
    .open = procopen,
    .create = dev.devcreate,
    .close = procclose,
    .read = procread,
    .write = procwrite,
    .remove = dev.devremove,
    .wstat = dev.devwstat,
    .egens = &.{procgenE},
});

pub fn exportC() void {
    @export(&Device.dev, .{ .name = "procdevtab" });
}
