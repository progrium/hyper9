//! h9's devlinux.c (design/kernel-port.md), `#L`: the Linux view's root
//! (design/epoch-0/linux-personality.md, "The Linux view"). A close
//! translation: the same functions in the same order, with error unions
//! in place of C's error labels. A native device (dev.zig's `Native`), in the
//! kern library only: the namespace kernel has no Linux view.
//!
//! Its root directory holds 9, tmp and mnt/term as mount points, and it
//! serves dev, proc and sys itself. The namespace builder binds the Linux
//! root tree after it, so the tree's own files show through, and binds
//! the 9front root, /tmp, /mnt/term, the console and #d onto its mount
//! points.
//!
//! The tree is a fixed table; /proc adds a directory for each of the
//! machine's processes, with the same entries for each, and /proc/n/fd
//! lists the process's open fds. A qid path holds the table index in its
//! low byte, the fd above it and the pid above that; devices under /dev
//! also set Qchr, so stat reports them as character devices
//! (src/abi/linux/sys.zig).
//!
//! Text files are made when they're opened, by h9_linux_gen (Zig) or
//! here, and read from that copy.

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
const Hproc = c.Hproc;

const Devc = 'L'; // #λ before design/epoch-0/mounts.md

const Q = enum(u8) {
    root = 0,
    @"9",
    tmp,
    mnt,
    term,
    termcwd,
    dev,
    proc,
    sys,
    // dev
    null,
    zero,
    full,
    random,
    urandom,
    tty,
    console,
    fddir,
    stdin,
    stdout,
    stderr,
    pts,
    ptmx,
    shm,
    // proc
    self,
    threadself,
    cpuinfo,
    meminfo,
    stat,
    uptime,
    mounts,
    loadavg,
    version,
    filesystems,
    psys,
    kernel,
    randomdir,
    uuid,
    bootid,
    vm,
    overcommit,
    osrelease,
    ostype,
    hostname,
    pidmax,
    // sys
    devices,
    system,
    cpu,
    online,
    possible,
    // #Letc: an /etc to union after the root's
    etc,
    resolv,
    // /proc/n
    pid,
    exe,
    cwd,
    maps,
    pfd,
    pstat,
    status,
    statm,
    cmdline,
    environ,
    comm,
    pmounts,
    task,
    fdent,
};

const Nq: c_int = @typeInfo(Q).@"enum".field_names.len;
const Qfirstpid: c_int = @backingInt(Q.exe); // a /proc/n entry

const FDSHIFT = 8;
const PIDSHIFT = 24;

const Qchr: u64 = 1 << 40;
fn QFILE(p: u64) c_int {
    return @intCast(p & 0xff);
}
fn QFD(p: u64) c_int {
    return @intCast((p >> FDSHIFT) & 0xffff);
}
fn QPID(p: u64) c_uint {
    return @intCast((p >> PIDSHIFT) & 0xffff);
}

const Lent = struct {
    name: [*:0]const u8,
    parent: Q,
    mode: c_int, // DMDIR|0555 or a file's mode
    chr: bool = false, // a character device
};

const D = dev.dmdir;

const tab: [Nq]Lent = blk: {
    var t: [Nq]Lent = undefined;
    const e = struct {
        fn f(tt: *[Nq]Lent, q: Q, name: [*:0]const u8, parent: Q, mode: c_int, chr: bool) void {
            tt[@backingInt(q)] = .{ .name = name, .parent = parent, .mode = mode, .chr = chr };
        }
    }.f;
    e(&t, .root, "#L", .root, D | 0o555, false);
    e(&t, .@"9", "9", .root, D | 0o555, false);
    e(&t, .tmp, "tmp", .root, D | 0o777, false);
    e(&t, .mnt, "mnt", .root, D | 0o555, false);
    e(&t, .term, "term", .mnt, D | 0o555, false);
    e(&t, .termcwd, "cwd", .term, D | 0o555, false);
    e(&t, .dev, "dev", .root, D | 0o555, false);
    e(&t, .proc, "proc", .root, D | 0o555, false);
    e(&t, .sys, "sys", .root, D | 0o555, false);

    e(&t, .null, "null", .dev, 0o666, true);
    e(&t, .zero, "zero", .dev, 0o666, true);
    e(&t, .full, "full", .dev, 0o666, true);
    e(&t, .random, "random", .dev, 0o444, true);
    e(&t, .urandom, "urandom", .dev, 0o444, true);
    e(&t, .tty, "tty", .dev, 0o666, true);
    e(&t, .console, "console", .dev, 0o666, true);
    e(&t, .fddir, "fd", .dev, D | 0o555, false);
    e(&t, .stdin, "stdin", .dev, 0o666, true);
    e(&t, .stdout, "stdout", .dev, 0o666, true);
    e(&t, .stderr, "stderr", .dev, 0o666, true);
    e(&t, .pts, "pts", .dev, D | 0o555, false);
    e(&t, .ptmx, "ptmx", .dev, 0o666, true); // #τ/ptmx is bound on it (design/epoch-0/linux-pty.md)
    e(&t, .shm, "shm", .dev, D | 0o777, false);

    e(&t, .self, "self", .proc, D | 0o555, false);
    e(&t, .threadself, "thread-self", .proc, D | 0o555, false);
    e(&t, .cpuinfo, "cpuinfo", .proc, 0o444, false);
    e(&t, .meminfo, "meminfo", .proc, 0o444, false);
    e(&t, .stat, "stat", .proc, 0o444, false);
    e(&t, .uptime, "uptime", .proc, 0o444, false);
    e(&t, .mounts, "mounts", .proc, 0o444, false);
    e(&t, .loadavg, "loadavg", .proc, 0o444, false);
    e(&t, .version, "version", .proc, 0o444, false);
    e(&t, .filesystems, "filesystems", .proc, 0o444, false);
    e(&t, .psys, "sys", .proc, D | 0o555, false);
    e(&t, .kernel, "kernel", .psys, D | 0o555, false);
    e(&t, .randomdir, "random", .kernel, D | 0o555, false);
    e(&t, .uuid, "uuid", .randomdir, 0o444, false);
    e(&t, .bootid, "boot_id", .randomdir, 0o444, false);
    e(&t, .vm, "vm", .psys, D | 0o555, false);
    e(&t, .overcommit, "overcommit_memory", .vm, 0o444, false);
    e(&t, .osrelease, "osrelease", .kernel, 0o444, false);
    e(&t, .ostype, "ostype", .kernel, 0o444, false);
    e(&t, .hostname, "hostname", .kernel, 0o444, false);
    e(&t, .pidmax, "pid_max", .kernel, 0o444, false);

    e(&t, .devices, "devices", .sys, D | 0o555, false);
    e(&t, .system, "system", .devices, D | 0o555, false);
    e(&t, .cpu, "cpu", .system, D | 0o555, false);
    e(&t, .online, "online", .cpu, 0o444, false);
    e(&t, .possible, "possible", .cpu, 0o444, false);

    e(&t, .etc, "etc", .etc, D | 0o555, false);
    e(&t, .resolv, "resolv.conf", .etc, 0o444, false);

    e(&t, .pid, "", .proc, D | 0o555, false);
    e(&t, .exe, "exe", .pid, 0o777, false);
    e(&t, .cwd, "cwd", .pid, 0o777, false);
    e(&t, .maps, "maps", .pid, 0o444, false);
    e(&t, .pfd, "fd", .pid, D | 0o500, false);
    e(&t, .pstat, "stat", .pid, 0o444, false);
    e(&t, .status, "status", .pid, 0o444, false);
    e(&t, .statm, "statm", .pid, 0o444, false);
    e(&t, .cmdline, "cmdline", .pid, 0o444, false);
    e(&t, .environ, "environ", .pid, 0o400, false);
    e(&t, .comm, "comm", .pid, 0o444, false);
    e(&t, .pmounts, "mounts", .pid, 0o444, false);
    e(&t, .task, "task", .pid, D | 0o555, false);
    e(&t, .fdent, "", .pfd, 0o777, false);
    break :blk t;
};

fn q_(q: Q) c_int {
    return @backingInt(q);
}

/// Implemented in Zig (src/machine.zig): writes the text of file q into
/// buf, for the process whose Zig record is aux (nil for the
/// machine-wide files), and returns its length, or -1 if it has none.
const Gen = *const fn (aux: ?*anyopaque, name: [*:0]const u8, pid: c_uint, buf: [*]u8, n: c_int) callconv(.c) c_int;
var h9_linuxgen: ?Gen = null;

extern var h9_procstatus: ?*const fn (?*anyopaque, [*]u8, c_int, *c_uint) callconv(.c) void; // proc.c
extern var h9_procthreads: ?*const fn (?*anyopaque, *c_uint, *c_uint) callconv(.c) void; // proc.c

const Npids = 1024;
const Ntext = 64 * 1024;

fn upmach() Error!*c.Hmach {
    return (try port.uphproc()).mach;
}

fn mkpath(q: c_int, pid: c_uint, fd: c_int) u64 {
    var p: u64 = @as(u64, @intCast(q)) | (@as(u64, @as(c_uint, @bitCast(fd))) << FDSHIFT) | (@as(u64, pid) << PIDSHIFT);
    if (tab[@intCast(q)].chr)
        p |= Qchr;
    return p;
}

fn genbuf() []u8 {
    return &up().genbuf;
}

fn mkentry(ch: *Chan, q: c_int, pid: c_uint, fd: c_int, dp: *Dir) void {
    const mode = tab[@intCast(q)].mode;
    var qid: Qid = undefined;
    dev.mkqid(&qid, @bitCast(mkpath(q, pid, fd)), 0, if (mode & D != 0) c.QTDIR else c.QTFILE);
    var name: [*:0]const u8 = tab[@intCast(q)].name;
    if (q == q_(.pid)) {
        name = (std.fmt.bufPrintSentinel(genbuf(), "{d}", .{pid}, 0) catch unreachable).ptr;
    } else if (q == q_(.fdent)) {
        name = (std.fmt.bufPrintSentinel(genbuf(), "{d}", .{fd}, 0) catch unreachable).ptr;
    }
    dev.devdir(ch, qid, @constCast(name), 0, c.eve, mode, dp);
    // /proc and /sys files are length 0, as on Linux, but resolv.conf
    // stands in for a regular file: c-ares (curl, so git over https)
    // sizes it with lseek, reads nothing from a 0-length one, and falls
    // back to a nameserver at 127.0.0.1.
    if (q == q_(.resolv)) if (h9_linuxgen) |gen| {
        const buf: [*]u8 = @ptrCast(c.smalloc(Ntext));
        const n = gen(null, name, 0, buf, Ntext);
        c.free(buf);
        if (n > 0)
            dp.length = n;
    };
    if (tab[@intCast(q)].chr)
        dp.qid.path |= Qchr;
}

/// h9_pidlookup in the caller's machine: nil if the caller isn't an h9
/// process, as C's lookup raised there.
fn pidlookup(pid: c_uint) Error!?*Hproc {
    return c.h9_pidlookup(try upmach(), pid);
}

/// Whether pid is a process of the caller's machine.
fn pidok(pid: c_uint) Error!bool {
    const h = try pidlookup(pid) orelse return false;
    c.h9_putproc(h);
    return true;
}

/// The fds open in process pid, into fds (up to n); returns how many.
fn pidfds(pid: c_uint, fds: []c_int) Error!usize {
    const h = try pidlookup(pid) orelse return 0;
    var count: usize = 0;
    sync.qlock(&h.debug);
    if (h.exited == 0) if (@as(?*c.Fgrp, h.p.fgrp)) |f| {
        c.lock(&f.ref.lk);
        var i: usize = 0;
        while (i <= f.maxfd) : (i += 1) {
            if (f.fd[i] != null and count < fds.len) {
                fds[count] = @intCast(i);
                count += 1;
            }
        }
        c.unlock(&f.ref.lk);
    };
    sync.qunlock(&h.debug);
    c.h9_putproc(h);
    return count;
}

/// The thread group of pid: its own pid unless it's a Linux thread.
fn tgidof(pid: c_uint) Error!c_uint {
    var tgid: c_uint = pid;
    var nthr: c_uint = 0;
    if (try pidlookup(pid)) |h| {
        if (h.aux != null) if (h9_procthreads) |f|
            f(h.aux, &tgid, &nthr);
        c.h9_putproc(h);
    }
    return tgid;
}

/// The pids of thread group tg, or with tg 0 the pids /proc lists: as
/// on Linux, each group's leader and not its other threads, which are
/// still there by name and in the leader's task directory (htop and btop
/// would show each thread as a process).
fn procpids(tg: c_uint, pids: []c_uint) Error!usize {
    const n: usize = @intCast(c.h9_pids(try upmach(), pids.ptr, @intCast(pids.len)));
    var m: usize = 0;
    for (0..n) |i| {
        const tgid = try tgidof(pids[i]);
        if (if (tg == 0) tgid == pids[i] else tgid == tg) {
            pids[m] = pids[i];
            m += 1;
        }
    }
    return m;
}

/// strtoul(name, &end, 10) with *end == 0 and a name that isn't empty.
fn number(name: [*:0]const u8) ?c_uint {
    var end: [*c]u8 = undefined;
    const v = c.strtoul(name, &end, 10);
    if (end[0] != 0 or name[0] == 0)
        return null;
    return @truncate(v);
}

fn linuxgen(ch: *Chan, name: ?[*:0]const u8, dt: ?[*]Dirtab, ntab: c_int, s_: c_int, dp: *Dir) Error!c_int {
    _ = .{ dt, ntab };
    var s = s_;
    const q = QFILE(ch.qid.path);
    var pid = QPID(ch.qid.path);
    if (q >= Nq)
        return -1;
    if (s == c.DEVDOTDOT) {
        if (q == q_(.pid))
            mkentry(ch, q_(.proc), 0, 0, dp)
        else if (q == q_(.pfd) or q == q_(.task))
            mkentry(ch, q_(.pid), pid, 0, dp)
        else
            mkentry(ch, q_(tab[@intCast(q)].parent), 0, 0, dp);
        return 1;
    }
    if (q == q_(.pid)) {
        var i = Qfirstpid;
        while (i < q_(.fdent)) : (i += 1) {
            const hit = if (name) |n| dev.streq(tab[@intCast(i)].name, n) else blk: {
                s -= 1;
                break :blk s + 1 == 0;
            };
            if (hit) {
                mkentry(ch, i, pid, 0, dp);
                return 1;
            }
        }
        return -1;
    }
    if (q == q_(.pfd)) {
        var fds: [256]c_int = undefined;
        if (name) |n| {
            const i = number(n) orelse return -1;
            var k = try pidfds(pid, &fds);
            while (k > 0) {
                k -= 1;
                if (fds[k] == @as(c_int, @bitCast(i))) {
                    mkentry(ch, q_(.fdent), pid, @bitCast(i), dp);
                    return 1;
                }
            }
            return -1;
        }
        const k = try pidfds(pid, &fds);
        if (s >= k)
            return -1;
        mkentry(ch, q_(.fdent), pid, fds[@intCast(s)], dp);
        return 1;
    }
    var pids: [Npids]c_uint = undefined;
    if (q == q_(.task)) {
        // task/n is /proc/n, for each thread n of the group.
        if (name) |nm| {
            const k = number(nm) orelse return -1;
            if (!try pidok(k) or try tgidof(k) != pid)
                return -1;
            mkentry(ch, q_(.pid), k, 0, dp);
            return 1;
        }
        const k = try procpids(pid, &pids);
        if (s >= k)
            return -1;
        mkentry(ch, q_(.pid), pids[@intCast(s)], 0, dp);
        return 1;
    }
    if (q == q_(.proc)) if (name) |nm| {
        // self and thread-self are the caller's own directory.
        if (dev.streq(nm, "self") or dev.streq(nm, "thread-self")) {
            pid = (try port.uphproc()).p.pid;
            mkentry(ch, q_(.pid), pid, 0, dp);
            const g = genbuf();
            _ = c.strecpy(g.ptr, g.ptr + g.len, @constCast(nm));
            dp.name = g.ptr;
            return 1;
        }
        if (number(nm)) |k| {
            pid = k;
            if (!try pidok(pid))
                return -1;
            mkentry(ch, q_(.pid), pid, 0, dp);
            return if (dev.streq(dp.name, nm)) 1 else -1;
        }
    };
    var i: c_int = 1;
    while (i < q_(.pid)) : (i += 1) {
        if (q_(tab[@intCast(i)].parent) != q or i == q)
            continue;
        const hit = if (name) |n| dev.streq(tab[@intCast(i)].name, n) else blk: {
            s -= 1;
            break :blk s + 1 == 0;
        };
        if (hit) {
            mkentry(ch, i, 0, 0, dp);
            return 1;
        }
    }
    if (q == q_(.proc) and name == null) {
        const k = try procpids(0, &pids);
        if (s >= k)
            return -1;
        mkentry(ch, q_(.pid), pids[@intCast(s)], 0, dp);
        return 1;
    }
    return -1;
}

const linuxgenE = dev.egen(linuxgen);

/// #L is the Linux view's top; #Letc is a directory of files the
/// machine makes for a root that lacks them, bound after the root's /etc
/// (design/epoch-0/linux-net.md, "DNS").
fn linuxattach(spec: [*:0]const u8) Error!*Chan {
    if (dev.streq(spec, "etc")) {
        const ch = dev.devattach(Devc, spec);
        dev.mkqid(&ch.qid, @bitCast(mkpath(q_(.etc), 0, 0)), 0, c.QTDIR);
        return ch;
    }
    if (spec[0] != 0)
        return port.kerror(&port.Ebadspec);
    return dev.devattach(Devc, spec);
}

fn linuxwalk(ch: *Chan, nc: ?*Chan, name: [*]const [*:0]const u8, nname: c_int) Error!?*Walkqid {
    return dev.devwalk(ch, nc, name, nname, null, 0, linuxgenE.c);
}

fn linuxstat(ch: *Chan, db: [*]u8, n_: c_int) Error!c_int {
    const q = QFILE(ch.qid.path);
    if (q >= Nq)
        return port.kerror(&port.Enonexist);
    var d: Dir = undefined;
    mkentry(ch, q, QPID(ch.qid.path), QFD(ch.qid.path), &d);
    const n = c.convD2M(&d, db, @intCast(n_));
    if (n == 0)
        return port.kerror(&port.Ebadarg);
    return @intCast(n);
}

/// A file's text, made at open.
const Text = extern struct {
    n: c_int,
    buf: [1]u8,
};

fn textbuf(t: *Text) [*]u8 {
    return @ptrCast(&t.buf);
}

fn cmdline(pid: c_uint, buf: [*]u8, n: c_int, comm: bool) Error!c_int {
    const h = try pidlookup(pid) orelse return port.kerror(&port.Eprocdied);
    defer c.h9_putproc(h);
    var len: c_int = undefined;
    if (comm) {
        len = c.snprint(buf, n, @constCast("%s\n"), textof(h));
    } else {
        c.lock(&h.alk);
        len = h.nargs;
        if (len > n)
            len = n;
        @memcpy(buf[0..@intCast(len)], h.args[0..@intCast(len)]);
        c.unlock(&h.alk);
        if (len == 0)
            len = c.snprint(buf, n, @constCast("%s"), textof(h)) + 1;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            if (buf[i] == ' ' and h.setargs != 0)
                buf[i] = 0;
        }
    }
    return len;
}

/// status: 0 stat, 1 status, 2 statm
fn pstat(pid: c_uint, buf: [*]u8, n: c_int, status: c_int) Error!c_int {
    const h = try pidlookup(pid) orelse return port.kerror(&port.Eprocdied);
    defer c.h9_putproc(h);
    const ppid: c_uint = h.ppid;
    var mem: c_uint = 0;
    var state: [64]u8 = @splat(0);
    var tgid: c_uint = pid;
    var nthr: c_uint = 1;
    if (h.aux != null) if (h9_procstatus) |f|
        f(h.aux, &state, state.len, &mem);
    if (h.aux != null) if (h9_procthreads) |f|
        f(h.aux, &tgid, &nthr);
    const st: [*:0]const u8 = if (dev.streq(@ptrCast(&state), "Running")) "R" else "S";
    if (status == 2) {
        // Pages: size resident shared text lib data dt. htop drops a
        // process whose statm it can't read.
        return c.snprint(buf, n, @constCast("%lud %lud 0 0 0 %lud 0\n"), mem / 4, mem / 4, mem / 4);
    } else if (status != 0) {
        const running: [*:0]const u8 = if (st[0] == 'R') "running" else "sleeping";
        return c.snprint(buf, n, @constCast("Name:\t%s\nUmask:\t0022\nState:\t%s (%s)\nTgid:\t%lud\nNgid:\t0\nPid:\t%lud\nPPid:\t%lud\n" ++
            "TracerPid:\t0\nUid:\t0\t0\t0\t0\nGid:\t0\t0\t0\t0\nFDSize:\t64\nGroups:\t\n" ++
            "VmPeak:\t%8lud kB\nVmSize:\t%8lud kB\nVmRSS:\t%8lud kB\nThreads:\t%lud\n" ++
            "SigQ:\t0/0\nSigPnd:\t0000000000000000\nShdPnd:\t0000000000000000\n" ++
            "Cpus_allowed_list:\t0\n"), textof(h), st, running, tgid, pid, ppid, mem, mem, mem, nthr);
    } else {
        // All 52 fields: procps and busybox read past rss.
        return c.snprint(buf, n, @constCast("%lud (%s) %s %lud %lud %lud 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 %lud 0 %lud %lud %lud" ++
            " 18446744073709551615 0 0 0 0 0 0 0 0 0 0 0 0 17 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n"), pid, textof(h), st, ppid, pid, pid, nthr, h.start, mem *% 1024, mem / 4);
    }
}

fn linuxopen(ch: *Chan, omode: c_int) Error!*Chan {
    const q = QFILE(ch.qid.path);
    const pid = QPID(ch.qid.path);
    if (q >= Nq)
        return port.kerror(&port.Enonexist);
    if ((ch.qid.type & c.QTDIR) != 0 and (omode & 3) != c.OREAD)
        return port.kerror(&port.Eisdir);
    if ((omode & 3) != c.OREAD and (tab[@intCast(q)].mode & 0o222) == 0)
        return port.kerror(&port.Eperm);
    if (q == q_(.pid) or q == q_(.pfd) or q == q_(.task))
        if (!try pidok(pid))
            return port.kerror(&port.Eprocdied);
    dev.aux(ch).* = null;
    if ((ch.qid.type & c.QTDIR) == 0 and !tab[@intCast(q)].chr and q != q_(.exe) and q != q_(.cwd) and q != q_(.fdent)) {
        const t: *Text = @ptrCast(@alignCast(c.smalloc(@sizeOf(Text) + Ntext)));
        errdefer c.free(t);
        const buf = textbuf(t);
        var n: c_int = -1;
        switch (@as(Q, @fromBackingInt(@intCast(q)))) {
            .cmdline => n = try cmdline(pid, buf, Ntext, false),
            .comm => n = try cmdline(pid, buf, Ntext, true),
            .pstat => n = try pstat(pid, buf, Ntext, 0),
            .status => n = try pstat(pid, buf, Ntext, 1),
            .statm => n = try pstat(pid, buf, Ntext, 2),
            .overcommit => n = c.snprint(buf, Ntext, @constCast("0\n")),
            .ostype => n = c.snprint(buf, Ntext, @constCast("Linux\n")),
            .pidmax => n = c.snprint(buf, Ntext, @constCast("32768\n")),
            else => {
                if (q >= Qfirstpid) {
                    const h = try pidlookup(pid) orelse return port.kerror(&port.Eprocdied);
                    // aux is the Zig process only under nlk (h9_kern_setaux).
                    c.lock(&h.nlk);
                    const aux = h.aux;
                    if (h9_linuxgen) |gen| if (aux != null) {
                        n = gen(aux, tab[@intCast(q)].name, pid, buf, Ntext);
                    };
                    c.unlock(&h.nlk);
                    c.h9_putproc(h);
                } else if (h9_linuxgen) |gen|
                    n = gen(null, tab[@intCast(q)].name, pid, buf, Ntext);
            },
        }
        if (n < 0)
            n = 0;
        t.n = n;
        dev.aux(ch).* = t;
    }
    ch.mode = @intCast(try sysfile.openmode(@bitCast(omode)));
    ch.flag |= c.COPEN;
    ch.offset = 0;
    return ch;
}

fn linuxclose(ch: *Chan) Error!void {
    if ((ch.flag & c.COPEN) != 0) if (dev.aux(ch).*) |t| {
        c.free(t);
        dev.aux(ch).* = null;
    };
}

fn linuxread(ch: *Chan, va: ?*anyopaque, n_: c_int, off: i64) Error!c_int {
    var n = n_;
    if (ch.qid.type & c.QTDIR != 0)
        return dev.devdirread(ch, @ptrCast(va.?), n, null, 0, linuxgenE.c);
    const q = QFILE(ch.qid.path);
    const p: [*]u8 = @ptrCast(va.?);
    switch (q) {
        q_(.null) => return 0,
        q_(.full), q_(.zero) => {
            @memset(p[0..@intCast(n)], 0);
            return n;
        },
        q_(.random), q_(.urandom) => return @bitCast(c.randomread(va, @bitCast(n))),
        else => {},
    }
    const t: *Text = @ptrCast(@alignCast(dev.aux(ch).* orelse return 0));
    if (off < 0)
        return 0;
    if (off >= t.n)
        return 0;
    if (n > t.n - off)
        n = @intCast(t.n - off);
    @memcpy(p[0..@intCast(n)], textbuf(t)[@intCast(off)..][0..@intCast(n)]);
    return n;
}

fn linuxwrite(ch: *Chan, va: ?*const anyopaque, n: c_int, off: i64) Error!c_int {
    _ = .{ va, off };
    switch (QFILE(ch.qid.path)) {
        q_(.null), q_(.zero), q_(.random), q_(.urandom) => return n,
        q_(.full) => return port.kerror("no space left on device"),
        else => {},
    }
    return port.kerror(&port.Eperm);
}

fn linuxremove(ch: *Chan) Error!void {
    _ = ch;
    return port.kerror(&port.Eperm);
}

fn linuxwstat(ch: *Chan, db: [*]u8, n: c_int) Error!c_int {
    _ = .{ ch, db, n };
    return port.kerror(&port.Eperm);
}

pub const Device = dev.Native(Devc, "linux", .{
    .attach = linuxattach,
    .walk = linuxwalk,
    .stat = linuxstat,
    .open = linuxopen,
    .create = dev.devcreate,
    .close = linuxclose,
    .read = linuxread,
    .write = linuxwrite,
    .remove = linuxremove,
    .wstat = linuxwstat,
    .egens = &.{linuxgenE},
});

fn h9_linux_setgen(f: ?Gen) callconv(.c) void {
    h9_linuxgen = f;
}

pub fn exportC() void {
    @export(&Device.dev, .{ .name = "linuxdevtab" });
    @export(&h9_linux_setgen, .{ .name = "h9_linux_setgen" });
}

/// h's text, for snprint's %s.
fn textof(h: *Hproc) [*:0]const u8 {
    return @ptrCast(&h.text);
}
