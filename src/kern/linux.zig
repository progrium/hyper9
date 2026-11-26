//! h9's linux.c (design/kernel-port.md): kernel helpers for the Linux
//! ABI (design/epoch-0/linux-personality.md): the per-process root swap
//! at exec, walks relative to a directory fd, fd flags, await without
//! blocking, chroot, and futexes. A close translation: the same functions
//! in the same order, with error unions in place of waserror. The kern
//! library's only: the namespace kernel has no Linux processes, and
//! src/kern/nstab.c stands in for the hooks chan.zig calls.
//!
//! Each exported function returns -1 with the error string set on
//! failure, as glue.c's wrappers do (`syserr`).

const std = @import("std");
const port = @import("port.zig");
const sync = @import("sync.zig");
const dev = @import("dev.zig");
const chan = @import("chan.zig");
const sysfile = @import("sysfile.zig");
const c = port.c;
const up = port.up;
const Error = port.Error;

const Chan = c.Chan;
const Proc = c.Proc;

/// The current process, or nil on a thread that isn't one.
fn upq() ?*Proc {
    return c._getproc();
}

/// Swaps the error strings after a caught error, as proc.c's syserr
/// does.
fn syserr() c_int {
    const p = up();
    const s = p.syserrstr;
    p.syserrstr = p.errstr;
    p.errstr = s;
    return -1;
}

/// Swaps up->dot, or up->slash with which != 0, holding the record's
/// debug lock as chdir does.
fn swapchan(ch: ?*Chan, which: bool) Error!?*Chan {
    const h = try port.uphproc();
    sync.qlock(&h.debug);
    defer sync.qunlock(&h.debug);
    const p = up();
    var old: ?*Chan = undefined;
    if (which) {
        old = p.slash;
        p.slash = ch;
    } else {
        old = p.dot;
        p.dot = ch;
    }
    return old;
}

// Mark the Chan that is a root where .. stops (h9_fs_markroot): a
// chroot's (design/epoch-0/linux-chroot.md), held in the record's lroot
// and as slash, and a served attach root (kserve,
// design/epoch-0/kernel-serve.md), held as its workers' slash. Only a
// chroot's makes the process's root the Linux view. Not drawterm flags:
// only this file sets or reads them, and clones don't copy them.
const CLROOT = 0x4000;
const CSROOT = 0x8000;

/// Whether path s is p or under it.
fn under(s: [*:0]const u8, p: [*:0]const u8) bool {
    const n = std.mem.len(p);
    return c.strncmp(s, p, n) == 0 and (s[n] == 0 or s[n] == '/');
}

/// Renames dot's path for the other view (design/0018, "The Linux
/// view"): going to Linux, a path under /tmp or /mnt/term is kept, one in
/// #L loses the prefix, and any other gets /9 before it; going to 9front,
/// /9 is stripped and any other path gets #L before it. dot becomes a
/// walk to the new name from the new root, so its path is a proper one,
/// if that reaches the same directory; otherwise it's kept as it was.
fn renamedot(tolinux: bool) void {
    const d: *Chan = up().dot orelse return;
    const path: *c.Path = d.path orelse return;
    const s: [*:0]const u8 = path.s;
    var n: ?[*:0]u8 = undefined;
    if (tolinux) {
        if (c.strncmp(s, "#\xce\xbb", 3) == 0)
            n = c.smprint(@constCast("%s"), if (s[3] != 0) s + 3 else "/")
        else if (under(s, "/tmp") or under(s, "/mnt/term") or s[0] != '/')
            return
        else
            n = c.smprint(@constCast("/9%s"), if (dev.streq(s, "/")) "" else s);
    } else {
        if (under(s, "/9"))
            n = c.smprint(@constCast("%s"), if (s[2] != 0) s + 2 else "/")
        else if (under(s, "/tmp") or under(s, "/mnt/term") or s[0] != '/')
            return
        else
            n = c.smprint(@constCast("#\xce\xbb%s"), if (dev.streq(s, "/")) "" else s);
    }
    const name = n orelse return;
    const ch = chan.namec(name, c.Atodir, 0, 0) catch {
        c.free(name);
        return;
    };
    c.free(name);
    if (ch.type != d.type or ch.dev != d.dev or ch.qid.path != d.qid.path) {
        chan.cclose(ch);
        return;
    }
    chan.cclose(swapchan(ch, false) catch unreachable);
}

/// Sets the calling process's root: the Linux view (#L, renamed /) when
/// linux is set, and the machine's 9front root (#/) otherwise. A Chan's
/// mounts are keyed by its qid, so a fresh attach sees the machine's
/// binds.
fn topchan(name: [*:0]const u8) Error!*Chan {
    const ch = try chan.namec(name, c.Atodir, 0, 0);
    chan.pathclose(ch.path);
    ch.path = chan.newpath("/");
    return ch;
}

/// The calling process's Linux root, referenced: its chroot's
/// (design/epoch-0/linux-chroot.md), or #L.
fn linuxroot() Error!*Chan {
    const ch: *Chan = (try port.uphproc()).lroot orelse return topchan("#L");
    _ = chan.incref(&ch.ref);
    return ch;
}

/// Sets the calling process's root: the Linux view (#L, renamed /, or
/// the directory a chroot chose) when linux is set, and the machine's
/// 9front root (#/) otherwise. A Chan's mounts are keyed by its qid, so a
/// fresh attach sees the machine's binds.
fn h9_linux_setslash(tolinux: c_int) callconv(.c) c_int {
    const ch = (if (tolinux != 0) linuxroot() else topchan("#/")) catch return syserr();
    chan.cclose(swapchan(ch, true) catch return syserr());
    renamedot(tolinux != 0);
    return 0;
}

/// Whether the calling process's root is the Linux view, or a chroot in
/// it.
fn inview() bool {
    const s: *Chan = up().slash orelse return false;
    return dev.of(s).dc == 'L' or (s.flag & CLROOT) != 0;
}

fn h9_linux_inview() callconv(.c) c_int {
    return @intFromBool(inview());
}

/// Whether the calling process's walks stop at links, for the kernel's
/// walk to follow from its root (design/epoch-0/linux-symlinks.md): a
/// Linux process's, whose root is the Linux view.
fn h9_fs_linkwalk() callconv(.c) c_int {
    return @intFromBool(upq() != null and inview());
}

fn samedir(a: *Chan, b: *Chan) bool {
    return a.type == b.type and a.dev == b.dev and a.qid.path == b.qid.path;
}

/// Whether ch is what's mounted on the mount point d. Atodir leaves a
/// chan before its mount point, as cd does, so a directory with
/// something bound on it, such as the Linux view's /tmp, walks to #L's
/// own entry, while the fd is the overlay's. Walks from d cross the
/// mount.
fn mountedon(d: *Chan, ch: *Chan) bool {
    var t: ?*Chan = d;
    _ = chan.incref(&d.ref);
    const ok = chan.findmount(&t, null, d.type, @bitCast(d.dev), d.qid) and samedir(t.?, ch);
    chan.cclose(t);
    return ok;
}

/// namec(path, Atodir) from the top of the Linux view rather than the
/// calling process's chroot: an fd opened before a chroot was named from
/// there (design/epoch-0/linux-chroot.md).
fn fromtop(path: [*:0]const u8) Error!*Chan {
    const old = try swapchan(try topchan("#L"), true);
    defer chan.cclose(swapchan(old, true) catch unreachable);
    return chan.namec(path, c.Atodir, 0, 0);
}

/// Makes fd's directory the calling process's dot, for a walk relative
/// to it (openat and friends), and returns the old dot for
/// h9_linux_dotrestore. The fd's Chan is open and an open Chan can't be
/// cloned, so dot is a fresh walk to the fd's path, checked to reach the
/// same directory.
fn dotfd(fd: c_int) Error!?*Chan {
    const ch = try sysfile.fdtochan(fd, -1, false, true);
    const d = blk: {
        errdefer chan.cclose(ch);
        if ((ch.qid.type & c.QTDIR) == 0)
            return port.kerror(&port.Enotdir);
        var d: *Chan = undefined;
        if ((up().slash.*.flag & CLROOT) == 0) {
            d = try chan.namec(chan.chanpath(ch), c.Atodir, 0, 0);
        } else {
            // In a chroot, the fd's path may be one from before it,
            // named from the Linux view's top, as Linux lets an fd from
            // outside a chroot be used in it.
            var dd: ?*Chan = chan.namec(chan.chanpath(ch), c.Atodir, 0, 0) catch null;
            if (dd) |x| if (!samedir(x, ch) and !mountedon(x, ch)) {
                chan.cclose(x);
                dd = null;
            };
            d = dd orelse try fromtop(chan.chanpath(ch));
        }
        if (!samedir(d, ch) and !mountedon(d, ch)) {
            chan.cclose(d);
            return port.kerror("directory moved");
        }
        break :blk d;
    };
    chan.cclose(ch);
    return swapchan(d, false);
}

fn h9_linux_dotfd(fd: c_int) callconv(.c) ?*anyopaque {
    const old = dotfd(fd) catch {
        _ = syserr();
        return null;
    };
    return old;
}

fn h9_linux_dotrestore(old: ?*anyopaque) callconv(.c) void {
    chan.cclose(swapchan(@ptrCast(@alignCast(old)), false) catch return);
}

/// What fd is: its device's character, qid path and type, and open
/// mode, and whether it's close-on-exec. For isatty, d_type and fcntl.
fn h9_linux_fdinfo(fd: c_int, dc: *c_int, devn: *c_uint, qpath: *u64, qtype: *c_int, mode: *c_int, cexec: *c_int) callconv(.c) c_int {
    const ch = sysfile.fdtochan(fd, -1, false, true) catch return syserr();
    dc.* = dev.of(ch).dc;
    devn.* = ch.dev;
    qpath.* = ch.qid.path;
    qtype.* = ch.qid.type;
    mode.* = ch.mode;
    chan.cclose(ch);
    const f: *c.Fgrp = up().fgrp;
    c.lock(&f.ref.lk);
    cexec.* = @intFromBool(fd <= f.maxfd and (f.flag[@intCast(fd)] & c.CCEXEC) != 0);
    c.unlock(&f.ref.lk);
    return 0;
}

/// fd's channel, as an identity for the open file description it is
/// (dup and fork share it), and *refs, the references to it besides this
/// call's. 0 if fd isn't open.
fn h9_linux_fdchan(fd: c_int, refs: *c_int) callconv(.c) usize {
    const ch = sysfile.fdtochan(fd, -1, false, true) catch return 0;
    const id = @intFromPtr(ch);
    refs.* = @intCast(ch.ref.ref - 1);
    chan.cclose(ch);
    return id;
}

/// fd's channel, with a reference h9_linux_chanput releases: what a
/// lazily filled private file mapping reads its pages from
/// (src/abi/linux/mm.zig), after the fd is closed or renumbered. nil if
/// fd isn't open for reading.
fn h9_linux_changet(fd: c_int) callconv(.c) ?*anyopaque {
    return sysfile.fdtochan(fd, c.OREAD, false, true) catch null;
}

/// Reads up to n bytes at off from a h9_linux_changet channel: the
/// count, 0 at the end, or -1 with the error string set.
fn h9_linux_chanpread(v: *anyopaque, buf: ?*anyopaque, n: c_int, off: i64) callconv(.c) c_int {
    const ch: *Chan = @ptrCast(@alignCast(v));
    return dev.read(dev.of(ch), ch, buf, n, off) catch syserr();
}

fn h9_linux_chanput(v: *anyopaque) callconv(.c) void {
    chan.cclose(@ptrCast(@alignCast(v)));
}

// devfs's syncs (src/kern/fscheck.h), which raise the host's error.
// They're called as a C Devgen is, through dev.zig's callgen and so the
// shim's waserror (src/kern/devshim.c), which leaves the error on the
// process.
extern fn h9_fs_syncfs(ch: *Chan) void;
extern fn h9_fs_sync() void;

fn syncfsgen(ch: [*c]Chan, name: [*c]u8, tab: [*c]c.Dirtab, ntab: c_int, i: c_int, dp: [*c]c.Dir) callconv(.c) c_int {
    _ = .{ name, tab, ntab, dp };
    if (i == 0) h9_fs_syncfs(ch) else h9_fs_sync();
    return 0;
}

/// h9_fs_syncfs(ch), or with ch nil h9_fs_sync().
fn fssync(ch: ?*Chan) Error!void {
    var dir: c.Dir = undefined;
    var dummy: Chan = undefined;
    _ = try dev.callgen(&syncfsgen, ch orelse &dummy, null, null, 0, @intFromBool(ch == null), &dir);
}

/// syncfs(2): syncs the host file system behind fd's channel. Only devfs
/// has one; other devices, and 9P servers, have nothing to sync.
fn h9_linux_syncfs(fd: c_int) callconv(.c) c_int {
    const ch = sysfile.fdtochan(fd, -1, false, true) catch return syserr();
    defer chan.cclose(ch);
    if (dev.of(ch).dc == 'U')
        fssync(ch) catch return syserr();
    return 0;
}

/// sync(2): syncs every host file system.
fn h9_linux_sync() callconv(.c) c_int {
    fssync(null) catch return syserr();
    return 0;
}

/// The CPU time the calling process's wait record reports, in ms.
fn h9_linux_setcputime(user: c_uint, sys: c_uint) callconv(.c) void {
    const h = port.uphproc() catch return;
    h.cputime[0] = user;
    h.cputime[1] = sys;
}

/// Sets or clears fd's close-on-exec flag.
fn h9_linux_setcexec(fd: c_int, on: c_int) callconv(.c) c_int {
    const f: *c.Fgrp = up().fgrp;
    c.lock(&f.ref.lk);
    defer c.unlock(&f.ref.lk);
    if (fd < 0 or fd > f.maxfd or f.fd[@intCast(fd)] == null) {
        chan.kstrcpy(up().syserrstr, &port.Ebadfd, port.ERRMAX);
        return -1;
    }
    if (on != 0)
        f.flag[@intCast(fd)] |= c.CCEXEC
    else
        f.flag[@intCast(fd)] &= ~@as(u8, c.CCEXEC);
    return 0;
}

/// The highest fd in use, or -1.
fn h9_linux_maxfd() callconv(.c) c_int {
    const f: *c.Fgrp = up().fgrp;
    c.lock(&f.ref.lk);
    defer c.unlock(&f.ref.lk);
    var n: c_int = -1;
    var i: c_int = 0;
    while (i <= f.maxfd) : (i += 1) {
        if (f.fd[@intCast(i)] != null)
            n = i;
    }
    return n;
}

/// Lists the open fds into fds (up to n) and returns how many there
/// are, for /proc/n/fd.
fn h9_linux_fds(fds: [*]c_int, n: c_int) callconv(.c) c_int {
    const f: *c.Fgrp = up().fgrp;
    var count: c_int = 0;
    c.lock(&f.ref.lk);
    defer c.unlock(&f.ref.lk);
    var i: c_int = 0;
    while (i <= f.maxfd) : (i += 1) {
        if (f.fd[@intCast(i)] != null) {
            if (count < n)
                fds[@intCast(count)] = i;
            count += 1;
        }
    }
    return count;
}

const Wsleep = struct {
    ph: *Proc,
    gen: c_uint,
};

fn waitchanged(a: ?*anyopaque) callconv(.c) c_int {
    const x: *Wsleep = @ptrCast(@alignCast(a.?));
    return @intFromBool(@as(*volatile c_uint, &x.ph.wgen).* != x.gen);
}

fn unsleep(ph: *Proc, h: *Proc) void {
    var l: *?*Proc = @ptrCast(&ph.wsleep);
    while (l.*) |p| : (l = @ptrCast(&p.wnext)) {
        if (p == h) {
            l.* = h.wnext;
            break;
        }
    }
    h.wnext = null;
}

/// await for the Linux ABI: the wait record of the child `want`, or of
/// any child when want <= 0. Without block, returns 0 when there are
/// children but no such record yet, as wait4's WNOHANG. With peek, the
/// record stays, as waitid's WNOWAIT. Fails with Enochild when no child
/// could match, and is interrupted by notes.
///
/// A Linux thread's children are its group leader's (RFLXTHREAD), so
/// any thread waits on the leader's records: Go's os/exec waits for a
/// child on whichever thread the goroutine runs on. Each waiter sleeps on
/// its own Rendez, on the leader's wsleep list, since several threads
/// can wait at once.
fn await_(buf: [*]u8, n: c_int, block: bool, want: c_int, peek: bool) Error!c_int {
    const h = try port.uphproc();
    const ph: *Proc = h.waiter orelse h;
    c.lock(&ph.exl);
    var l: *?*c.Hwait = undefined;
    var w: *c.Hwait = undefined;
    while (true) {
        l = @ptrCast(&ph.waitq);
        const found = while (l.*) |x| : (l = @ptrCast(&x.next)) {
            if (want <= 0 or x.pid == @as(c_uint, @bitCast(want)))
                break x;
        } else null;
        if (found) |x| {
            w = x;
            break;
        }
        if (ph.nchild == 0 or ph.dead != 0) {
            c.unlock(&ph.exl);
            return port.kerror(&port.Enochild);
        }
        if (!block) {
            c.unlock(&ph.exl);
            return 0;
        }
        var x: Wsleep = .{ .ph = ph, .gen = ph.wgen };
        h.wnext = ph.wsleep;
        ph.wsleep = h;
        c.unlock(&ph.exl);
        sync.sleep(&h.lwaitr, waitchanged, &x) catch |e| {
            c.lock(&ph.exl);
            unsleep(ph, h);
            c.unlock(&ph.exl);
            return e;
        };
        c.lock(&ph.exl);
        unsleep(ph, h);
    }
    var copy: c.Hwait = undefined;
    if (peek) {
        copy = w.*;
        w = &copy;
    } else {
        l.* = w.next;
        ph.nwait -= 1;
    }
    c.unlock(&ph.exl);
    const len = c.snprint(buf, n, @constCast("%lud %lud %lud %lud %q"), w.pid, w.time[0], w.time[1], w.time[2], @as([*:0]const u8, @ptrCast(&w.msg)));
    if (!peek)
        c.free(w);
    return len;
}

fn h9_linux_await(buf: [*]u8, n: c_int, block: c_int, want: c_int, peek: c_int) callconv(.c) c_int {
    return await_(buf, n, block != 0, want, peek != 0) catch syserr();
}

/// The calling process's parent's pid, or 1 for a machine's first
/// process.
fn h9_linux_ppid() callconv(.c) c_uint {
    const h = port.uphproc() catch return 1;
    return if (h.ppid != 0) h.ppid else 1;
}

/// The calling process's working directory as a path in its view.
fn h9_linux_getcwd(buf: [*]u8, n: c_int) callconv(.c) c_int {
    const d: *Chan = up().dot orelse {
        chan.kstrcpy(up().syserrstr, &port.Enonexist, port.ERRMAX);
        return -1;
    };
    if (n <= 0) {
        chan.kstrcpy(up().syserrstr, &port.Enonexist, port.ERRMAX);
        return -1;
    }
    return c.snprint(buf, n, @constCast("%s"), chan.chanpath(d));
}

/// Makes fd's directory the working directory.
fn h9_linux_fchdir(fd: c_int) callconv(.c) c_int {
    const old = h9_linux_dotfd(fd) orelse return -1;
    chan.cclose(@ptrCast(@alignCast(old)));
    return 0;
}

/// chroot(2) (design/epoch-0/linux-chroot.md): path, walked as any Linux
/// path is, becomes the calling process's Linux root, which its later
/// forks keep and exec doesn't change. Its absolute paths, its links'
/// absolute targets, and .. at the top stop there. The working directory
/// stays as it is; if it's under the new root, its name becomes the name
/// from there. A process can only name directories it can already reach,
/// so the root never widens past the Linux view: chroot to the view's
/// own top is no chroot at all.
fn chroot(path: [*:0]const u8) Error!void {
    var p: ?[*:0]u8 = null;
    var cc: ?*Chan = null;
    errdefer {
        c.free(p);
        if (cc) |x| chan.cclose(x);
    }
    const h = try port.uphproc();
    const nc = try chan.namec(path, c.Atodir, 0, 0);
    // A clone, so the walk's chan (up->slash itself, for "/") isn't
    // changed.
    cc = blk: {
        defer chan.cclose(nc);
        break :blk try chan.cclone(nc);
    };
    const t = try topchan("#L");
    const top = samedir(cc.?, t) or mountedon(t, cc.?);
    chan.cclose(t);
    p = c.strdup(chan.chanpath(cc)) orelse return port.kerror(&port.Enomem);
    if (top) {
        chan.cclose(cc);
        cc = null;
    } else {
        h9_fs_markroot(cc.?, 1);
    }

    // The working directory's name from the new root, if it's under it.
    var n: ?[*:0]u8 = null;
    const dot: ?*Chan = up().dot;
    const s: ?[*:0]const u8 = if (dot) |d| if (@as(?*c.Path, d.path)) |dp| dp.s else null else null;
    if (s) |ss| if (!dev.streq(p.?, "/") and under(ss, p.?)) {
        const pl = std.mem.len(p.?);
        n = c.strdup(if (ss[pl] != 0) ss + pl else "/") orelse return port.kerror(&port.Enomem);
    };
    c.free(p);
    p = n;

    const old: ?*Chan = h.lroot;
    h.lroot = cc;
    cc = null;
    if (old) |o|
        chan.cclose(o);
    chan.cclose(try swapchan(try linuxroot(), true));

    // Renamed by a walk from the new root, as renamedot does, so its
    // Path is a proper one; kept as it was if that walk goes elsewhere.
    if (p) |pp| if (chan.namec(pp, c.Atodir, 0, 0)) |t2| {
        const d: *Chan = up().dot;
        if (samedir(t2, d) or mountedon(t2, d))
            chan.cclose(try swapchan(t2, false))
        else
            chan.cclose(t2);
    } else |_| {};
    c.free(p);
    p = null;
}

fn h9_linux_chroot(path: [*:0]const u8) callconv(.c) c_int {
    chroot(path) catch return syserr();
    return 0;
}

/// Whether ch is the calling process's chroot's root, where .. stays
/// (chan.zig's walkl), as Linux's does at a process's root. Not for the
/// Linux view's own top, whose devices already keep .. there.
fn h9_fs_atroot(ch: *Chan) callconv(.c) c_int {
    const p = upq() orelse return 0;
    const r: *Chan = p.slash orelse return 0;
    if ((r.flag & (CLROOT | CSROOT)) == 0)
        return 0;
    return @intFromBool(samedir(ch, r) or mountedon(r, ch));
}

/// Makes ch, a channel of the caller's own (a clone), a root where ..
/// stops once it's a process's slash: named "/", and marked as a
/// chroot's (lx set) or a served attach root's.
fn h9_fs_markroot(ch: *Chan, lx: c_int) callconv(.c) void {
    chan.pathclose(ch.path);
    ch.path = chan.newpath("/");
    ch.flag |= if (lx != 0) CLROOT else CSROOT;
}

// futex (design/epoch-0/linux-threads.md): waiters queued by key (the
// address space) and guest address, sleeping with the kernel's sleep, so
// a note interrupts them as it does any wait. The value check and the
// enqueue are under the same lock a waker takes, so a wake after the
// guest changes the word can't fall between them.
const Fwait = struct {
    key: ?*const anyopaque,
    addr: u64,
    bitset: u32,
    woken: c_int,
    r: c.Rendez,
    next: ?*Fwait,
};

const Nfhash = 64;
var flk: c.Lock = std.mem.zeroes(c.Lock);
var fq: [Nfhash]?*Fwait = @splat(null);

fn fhash(key: ?*const anyopaque, addr: u64) usize {
    return @intCast(((@intFromPtr(key) >> 4) ^ (addr >> 2)) & (Nfhash - 1));
}

fn fenq(w: *Fwait) void {
    const h = fhash(w.key, w.addr);
    w.next = fq[h];
    fq[h] = w;
}

/// Removes w from its queue, if it's still on one. With flk held.
fn fdeq(w: *Fwait) void {
    var l: *?*Fwait = &fq[fhash(w.key, w.addr)];
    while (l.*) |x| : (l = &x.next) {
        if (x == w) {
            l.* = w.next;
            return;
        }
    }
}

fn fwoken(a: ?*anyopaque) callconv(.c) c_int {
    const w: *Fwait = @ptrCast(@alignCast(a.?));
    return @as(*volatile c_int, &w.woken).*;
}

/// Waits on addr if *word is val: returns 0 when woken, 1 if *word
/// wasn't val (EAGAIN), 2 at the timeout (ms >= 0), and -1 with the error
/// set when a note interrupted it.
fn h9_futex_wait(key: ?*const anyopaque, addr: u64, word: *u32, val: u32, bitset: u32, ms: c_int) callconv(.c) c_int {
    var w: Fwait = std.mem.zeroes(Fwait);
    w.key = key;
    w.addr = addr;
    w.bitset = bitset;
    c.lock(&flk);
    if (@atomicLoad(u32, word, .seq_cst) != val) {
        c.unlock(&flk);
        return 1;
    }
    fenq(&w);
    c.unlock(&flk);
    (if (ms < 0)
        sync.sleep(&w.r, fwoken, &w)
    else if (ms > 0)
        sync.tsleep(&w.r, fwoken, &w, @intCast(ms))) catch {
        c.lock(&flk);
        fdeq(&w);
        c.unlock(&flk);
        return syserr();
    };
    // A waker sets woken and calls wakeup with flk held, so once this
    // has the lock, no waker still touches w.
    c.lock(&flk);
    fdeq(&w);
    c.unlock(&flk);
    return if (w.woken != 0) 0 else 2;
}

/// Wakes up to n waiters on addr whose bitset meets bitset, and moves up
/// to nreq more to addr2 (requeue). With word set, does nothing and
/// returns -2 unless *word is val (FUTEX_CMP_REQUEUE's EAGAIN). Returns
/// how many were woken and requeued.
fn h9_futex_wake(key: ?*const anyopaque, addr: u64, n: c_int, bitset: u32, addr2: u64, nreq: c_int, word: ?*u32, val: u32) callconv(.c) c_int {
    var woken: c_int = 0;
    var req: c_int = 0;
    var moved: ?*Fwait = null;
    c.lock(&flk);
    if (word) |wd| if (@atomicLoad(u32, wd, .seq_cst) != val) {
        c.unlock(&flk);
        return -2;
    };
    var l: *?*Fwait = &fq[fhash(key, addr)];
    while (l.*) |w| {
        if (w.key != key or w.addr != addr or (w.bitset & bitset) == 0) {
            l = &w.next;
            continue;
        }
        if (woken < n) {
            l.* = w.next;
            w.woken = 1;
            _ = sync.wakeup(&w.r);
            woken += 1;
        } else if (req < nreq) {
            l.* = w.next;
            w.next = moved;
            moved = w;
            req += 1;
        } else break;
    }
    while (moved) |w| {
        moved = w.next;
        w.addr = addr2;
        fenq(w);
    }
    c.unlock(&flk);
    return woken + req;
}

pub fn exportC() void {
    @export(&h9_linux_setslash, .{ .name = "h9_linux_setslash" });
    @export(&h9_linux_inview, .{ .name = "h9_linux_inview" });
    @export(&h9_fs_linkwalk, .{ .name = "h9_fs_linkwalk" });
    @export(&h9_linux_dotfd, .{ .name = "h9_linux_dotfd" });
    @export(&h9_linux_dotrestore, .{ .name = "h9_linux_dotrestore" });
    @export(&h9_linux_fdinfo, .{ .name = "h9_linux_fdinfo" });
    @export(&h9_linux_fdchan, .{ .name = "h9_linux_fdchan" });
    @export(&h9_linux_changet, .{ .name = "h9_linux_changet" });
    @export(&h9_linux_chanpread, .{ .name = "h9_linux_chanpread" });
    @export(&h9_linux_chanput, .{ .name = "h9_linux_chanput" });
    @export(&h9_linux_syncfs, .{ .name = "h9_linux_syncfs" });
    @export(&h9_linux_sync, .{ .name = "h9_linux_sync" });
    @export(&h9_linux_setcputime, .{ .name = "h9_linux_setcputime" });
    @export(&h9_linux_setcexec, .{ .name = "h9_linux_setcexec" });
    @export(&h9_linux_maxfd, .{ .name = "h9_linux_maxfd" });
    @export(&h9_linux_fds, .{ .name = "h9_linux_fds" });
    @export(&h9_linux_await, .{ .name = "h9_linux_await" });
    @export(&h9_linux_ppid, .{ .name = "h9_linux_ppid" });
    @export(&h9_linux_getcwd, .{ .name = "h9_linux_getcwd" });
    @export(&h9_linux_fchdir, .{ .name = "h9_linux_fchdir" });
    @export(&h9_linux_chroot, .{ .name = "h9_linux_chroot" });
    @export(&h9_fs_atroot, .{ .name = "h9_fs_atroot" });
    @export(&h9_fs_markroot, .{ .name = "h9_fs_markroot" });
    @export(&h9_futex_wait, .{ .name = "h9_futex_wait" });
    @export(&h9_futex_wake, .{ .name = "h9_futex_wake" });
}
