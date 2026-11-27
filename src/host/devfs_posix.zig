//! The host tree device, `#U`, on POSIX hosts and the web host
//! (design/host-handles.md): drawterm's devfs-posix.c, ported to Zig as a
//! native device, with h9's changes to it. A close translation: the same
//! functions in the same order, with error unions in place of C's error
//! labels.
//!
//! Files are named by their resolved host path, and opened beneath the
//! machine's directory handle that holds each (src/host/dirs.c's
//! `h9_host_open`, `h9_host_stat`, `h9_host_lstat`, and
//! `h9_host_readlink`), so no open follows a link out of a handle. The
//! policy checks (src/host/fscheck.c) stay as the second line: read-deny,
//! and the verdict on what was opened. Every check of a file it opened is
//! of the fd (`allowfd`), or of a name in a directory fd (`allowat`), so a
//! swapped link can't steer an operation past it.

const std = @import("std");
const builtin = @import("builtin");
const kern = @import("kern");
const hc = @import("host_libc");
const fs = @import("devfs.zig");

const port = kern;
const c = kern.c;
const dev = kern.dev;
const chan = kern.chan;
const sync = kern.sync;
const sysfile = kern.sysfile;
const Error = port.Error;
const Chan = c.Chan;
const Dir = c.Dir;
const Qid = c.Qid;
const Walkqid = c.Walkqid;
const Attr = c.Attr;

const wasi = builtin.os.tag == .wasi;
const linux = builtin.os.tag == .linux;
const apple = builtin.os.tag.isDarwin();

const Stat = hc.struct_stat;

const name_max: usize = if (@hasDecl(hc, "NAME_MAX")) hc.NAME_MAX else 256;
const path_max: usize = if (@hasDecl(hc, "PATH_MAX")) hc.PATH_MAX else 4096;

const Walk = fs.Walk;
const Read = fs.Read;
const Write = fs.Write;
const Create = fs.Create;
const Remove = fs.Remove;
const Rename = fs.Rename;

// The host's half of the policy (src/host/fscheck.c), which never raises.
extern fn h9_fs_resolvein(top: [*:0]const u8, dir: [*:0]const u8, rel: [*:0]const u8, buf: [*]u8, nbuf: c_int) c_int;
extern fn h9_fs_check(path: [*:0]const u8, op: c_int) c_int;
extern fn h9_fs_checkname(path: [*:0]const u8, op: c_int) c_int;
extern fn h9_fs_checkfd(fd: c_int, op: c_int) c_int;
extern fn h9_fs_checkat(dfd: c_int, name: [*:0]const u8, op: c_int) c_int;
// The web host's notes of what each fd was opened by (fscheck.c).
const notes = if (wasi) struct {
    extern fn h9_fs_notefd(fd: c_int, path: [*:0]const u8) void;
    extern fn h9_fs_notefdat(fd: c_int, dfd: c_int, name: [*:0]const u8) void;
} else struct {
    fn h9_fs_notefd(_: c_int, _: [*:0]const u8) void {}
    fn h9_fs_notefdat(_: c_int, _: c_int, _: [*:0]const u8) void {}
};
// src/kern/linux.zig: whether the calling process's walks stop at links.
extern fn h9_fs_linkwalk() c_int;

// Files beneath the machine's directory handles (src/host/dirs.c). The
// web host's trees are WASI preopens, opened by path.
const beneath = if (wasi) struct {
    fn stat(p: [*:0]const u8, st: *Stat) c_int {
        return hc.stat(p, st);
    }
    fn lstat(p: [*:0]const u8, st: *Stat) c_int {
        return hc.lstat(p, st);
    }
    fn readlink(p: [*:0]const u8, buf: [*]u8, n: usize) isize {
        return hc.readlink(p, buf, n);
    }
} else struct {
    extern fn h9_host_open(path: [*:0]const u8, flags: c_int, mode: c_int, nolinks: c_int) c_int;
    extern fn h9_host_stat(path: [*:0]const u8, st: *Stat) c_int;
    extern fn h9_host_lstat(path: [*:0]const u8, st: *Stat) c_int;
    extern fn h9_host_readlink(path: [*:0]const u8, buf: [*]u8, n: usize) isize;
    const stat = h9_host_stat;
    const lstat = h9_host_lstat;
    const readlink = h9_host_readlink;
};

const Ufsinfo = struct {
    mode: c_uint,
    fd: c_int,
    uid: c_uint,
    gid: c_uint,
    dir: ?*hc.DIR,
    offset: i64,
    oq: c.QLock,
    path: [*:0]u8,
    nextname: [name_max + 1]u8,
    /// A contained attach (#U!c, design/epoch-0/symlinks-in-root.md)
    /// resolves links inside top, its tree, once namec's walk has set it
    /// (`anchor`). path is then always resolved, and lpath, if set, is the
    /// link the last name was, in its resolved directory.
    contained: bool,
    top: ?[*:0]u8,
    lpath: ?[*:0]u8,
    /// path holds no links (design/epoch-0/linux-symlinks.md): a Linux
    /// process's walk, which looks each name up without following it,
    /// made it, from a canonical path.
    canon: bool,
};

fn uifOf(ch: *Chan) *Ufsinfo {
    return @ptrCast(@alignCast(dev.aux(ch).*.?));
}

fn errno() c_int {
    return std.c._errno().*;
}

fn setErrno(e: c_int) void {
    std.c._errno().* = e;
}

/// The host's error, as the process's error string.
fn oserr() error{Kernel} {
    return oserrOf(errno());
}

fn oserrOf(e: c_int) error{Kernel} {
    return port.kerror(@ptrCast(hc.strerror(e)));
}

fn isMode(m: anytype, fmt: c_uint) bool {
    return (@as(c_uint, @intCast(m)) & @as(c_uint, @intCast(hc.S_IFMT))) == fmt;
}
const S_IFDIR: c_uint = @intCast(hc.S_IFDIR);
const S_IFLNK: c_uint = @intCast(hc.S_IFLNK);
const S_IFIFO: c_uint = @intCast(hc.S_IFIFO);

fn isdir(st: *const Stat) bool {
    return isMode(st.st_mode, S_IFDIR);
}
fn islnk(m: anytype) bool {
    return isMode(m, S_IFLNK);
}
fn isfifo(m: anytype) bool {
    return isMode(m, S_IFIFO);
}

/// C's conversion of an integer to a narrower or wider one: truncated,
/// or extended by the source's sign.
fn cv(comptime T: type, v: anytype) T {
    const V = @TypeOf(v);
    if (V == comptime_int) return @intCast(v);
    const vi = @typeInfo(V).int;
    const ti = @typeInfo(T).int;
    if (ti.bits <= vi.bits) {
        const u: @Int(.unsigned, vi.bits) = @bitCast(v);
        return @bitCast(@as(@Int(.unsigned, ti.bits), @truncate(u)));
    }
    const w: @Int(vi.signedness, ti.bits) = v;
    return @bitCast(w);
}

/// A timespec field of st: `which` is a, m, or c.
fn stTime(st: *const Stat, comptime which: []const u8) hc.struct_timespec {
    if (@hasField(Stat, "st_" ++ which ++ "tim")) return @field(st, "st_" ++ which ++ "tim");
    return @field(st, "st_" ++ which ++ "timespec");
}

fn stSec(st: *const Stat, comptime which: []const u8) i64 {
    return @intCast(stTime(st, which).tv_sec);
}

fn stNsec(st: *const Stat, comptime which: []const u8) i64 {
    return @intCast(stTime(st, which).tv_nsec);
}

/// A copy of s in the kernel's heap.
fn dupz(s: []const u8) [*:0]u8 {
    const p: [*]u8 = @ptrCast(c.smalloc(@intCast(s.len + 1)));
    @memcpy(p[0..s.len], s);
    p[s.len] = 0;
    return @ptrCast(p);
}

fn span(s: [*:0]const u8) []const u8 {
    return std.mem.span(s);
}

fn free(p: anytype) void {
    c.free(@ptrCast(@constCast(p)));
}

// The web host (design/epoch-0/browser-host.md) has no permission bits:
// every file stats as 0775 and chmod fails. Programs that check what they
// set (PostgreSQL wants its data directory 0700 or 0750) need the mode
// back, so the web host remembers the permission bits a create or wstat
// gave each file, by inode, for the life of the machine.

const Wmode = struct {
    dev: u64,
    ino: u64,
    mode: c_uint,
    next: ?*Wmode,
};
var wmodes: [256]?*Wmode = @splat(null);

fn wmodeslot(st: *const Stat) *?*Wmode {
    const k = cv(u64, st.st_ino) ^ cv(u64, st.st_dev);
    return &wmodes[@intCast(k & 255)];
}

fn wmodeset(st: *const Stat, mode: anytype) void {
    const m: c_uint = cv(c_uint, mode) & 0o777;
    var w = wmodeslot(st).*;
    while (w) |x| : (w = x.next) {
        if (x.ino == cv(u64, st.st_ino) and x.dev == cv(u64, st.st_dev)) {
            x.mode = m;
            return;
        }
    }
    const n: *Wmode = @ptrCast(@alignCast(port.malloc(@sizeOf(Wmode)) orelse return));
    n.* = .{ .dev = cv(u64, st.st_dev), .ino = cv(u64, st.st_ino), .mode = m, .next = wmodeslot(st).* };
    wmodeslot(st).* = n;
}

fn wmodeof(st: *const Stat) c_uint {
    var w = wmodeslot(st).*;
    while (w) |x| : (w = x.next) {
        if (x.ino == cv(u64, st.st_ino) and x.dev == cv(u64, st.st_dev))
            return x.mode;
    }
    return cv(c_uint, st.st_mode) & 0o777;
}

/// A file's permission bits, as a Dir shows them.
fn stmode(st: *const Stat) c_uint {
    if (wasi) return wmodeof(st);
    return cv(c_uint, st.st_mode) & 0o777;
}

/// The web host's Dirs: WASI gives no permission bits, which devoverlay
/// takes as unwritable and ls shows as ----------. The policy, not the
/// mode, decides what the guest may do, so a file that reads as mode 0
/// reads as rwxrwxr-x.
fn webmode(m: c_uint) c_uint {
    if (wasi and m & 0o777 == 0) return m | 0o775;
    return m;
}

/// The chan's own name on the host: the link, not its target.
fn ownpath(uif: *Ufsinfo) [*:0]u8 {
    return uif.lpath orelse uif.path;
}

/// Linux symlinks (design/epoch-0/linux-symlinks.md). A Linux process's
/// walk looks each name up with lstat and stops at a link, and its opens
/// refuse links: a path that holds none (canon) is opened without
/// following any, so a link swapped in since the walk fails the open
/// (ELOOP) instead of being followed by the host. The web host has no /
/// to start from, so its last name alone isn't followed.
fn lxmode(uif: *Ufsinfo) bool {
    return uif.canon and h9_fs_linkwalk() != 0;
}

/// open(2), beneath the machine's directory handle that holds path, with
/// no link followed for a Linux process's walk.
fn openpath(uif: *Ufsinfo, path: [*:0]const u8, flags: c_int, mode: c_int) c_int {
    if (wasi) {
        if (lxmode(uif))
            return hc.open(path, flags | hc.O_NOFOLLOW, mode);
        return hc.open(path, flags, mode);
    }
    return beneath.h9_host_open(path, flags, mode, @intFromBool(lxmode(uif)));
}

/// The policy's verdict as an error: hidden, or read-only.
fn verdict(r: c_int) Error!void {
    switch (r) {
        0 => return,
        -2 => return port.kerror(&port.Eperm),
        else => return port.kerror(&port.Enonexist),
    }
}

/// The policy's decision for the file fd opened, by the file the fd is
/// rather than by resolving a path again, so a swapped link can't steer
/// an open past the check.
fn allowfd(fd: c_int, op: c_int) Error!void {
    return verdict(h9_fs_checkfd(fd, op));
}

/// The same for the entry name in the directory dfd is, judged by that
/// directory's canonical path joined to name, without following name.
fn allowat(dfd: c_int, name: [*:0]const u8, op: c_int) Error!void {
    return verdict(h9_fs_checkat(dfd, name, op));
}

fn lastelem(s: [*:0]u8) [*:0]u8 {
    const t = std.mem.lastIndexOfScalar(u8, span(s), '/') orelse return s;
    if (s[t + 1] == 0) return s + t;
    return s + t + 1;
}

/// Opens the parent directory of path for an *at operation, and checks it
/// by the directory the fd actually is, so an openat, mkdirat, unlinkat,
/// or renameat relative to the fd can't be steered outside the policy by
/// a swapped parent component. Copies path's last element into base.
/// Returns the fd, which the caller closes.
fn parentfd(uif: *Ufsinfo, path: [*:0]const u8, base: *[name_max + 1]u8) Error!c_int {
    var dir: [path_max]u8 = undefined;
    const p = span(path);
    var fd: c_int = undefined;
    var dirz: [*:0]const u8 = ".";
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |slash| {
        const last = p[slash + 1 ..];
        if (last.len > name_max) return oserrOf(hc.ENAMETOOLONG);
        @memcpy(base[0..last.len], last);
        base[last.len] = 0;
        if (slash == 0) {
            dir[0] = '/';
            dir[1] = 0;
        } else {
            if (slash >= dir.len) return oserrOf(hc.ENAMETOOLONG);
            @memcpy(dir[0..slash], p[0..slash]);
            dir[slash] = 0;
        }
        dirz = @ptrCast(&dir);
        fd = openpath(uif, dirz, hc.O_RDONLY | hc.O_DIRECTORY, 0);
    } else {
        if (p.len > name_max) return oserrOf(hc.ENAMETOOLONG);
        @memcpy(base[0..p.len], p);
        base[p.len] = 0;
        fd = hc.open(".", hc.O_RDONLY | hc.O_DIRECTORY);
    }
    if (fd < 0) return oserr();
    errdefer _ = hc.close(fd);
    notes.h9_fs_notefd(fd, dirz);
    try allowfd(fd, Walk);
    return fd;
}

/// A directory, opened beneath its handle and checked as a walk, for a
/// create of name in it as op.
fn dirfdFor(uif: *Ufsinfo, name: [*:0]const u8, op: c_int) Error!c_int {
    const dfd = openpath(uif, uif.path, hc.O_RDONLY | hc.O_DIRECTORY, 0);
    if (dfd < 0) return oserr();
    errdefer _ = hc.close(dfd);
    notes.h9_fs_notefd(dfd, uif.path);
    try allowfd(dfd, Walk);
    try allowat(dfd, name, op);
    return dfd;
}

var devno: c_int = 0;

fn fsattach(spec: [*:0]const u8) Error!*Chan {
    // h9: the only spec is !c, a contained tree.
    var contained = false;
    if (spec[0] != 0) {
        if (!dev.streq(spec, "!c")) return port.kerror(&port.Ebadspec);
        contained = true;
    }
    var st: Stat = undefined;
    if (hc.stat("/", &st) < 0) return oserr();

    const ch = dev.devattach('U', spec);
    const uif: *Ufsinfo = @ptrCast(@alignCast(port.malloc(@sizeOf(Ufsinfo)).?));
    uif.mode = cv(c_uint, st.st_mode);
    uif.uid = cv(c_uint, st.st_uid);
    uif.gid = cv(c_uint, st.st_gid);
    uif.path = dupz("/");
    uif.contained = contained;
    uif.canon = true;

    dev.aux(ch).* = uif;
    ch.dev = cv(@TypeOf(ch.dev), @atomicRmw(c_int, &devno, .Add, 1, .monotonic));
    ch.qid.type = c.QTDIR;
    return ch;
}

fn fsclone(ch: *Chan, nc: *Chan) void {
    const uif: *Ufsinfo = @ptrCast(@alignCast(port.malloc(@sizeOf(Ufsinfo)).?));
    uif.* = uifOf(ch).*;
    uif.path = dupz(span(uif.path));
    if (uif.top) |t| uif.top = dupz(span(t));
    if (uif.lpath) |l| uif.lpath = dupz(span(l));
    dev.aux(nc).* = uif;
}

fn setpath(uif: *Ufsinfo, path: [*:0]u8, lpath: ?[*:0]u8) void {
    free(uif.path);
    uif.path = path;
    free(uif.lpath);
    uif.lpath = lpath;
}

fn setstat(ch: *Chan, uif: *Ufsinfo, st: *const Stat) void {
    uif.mode = cv(c_uint, st.st_mode);
    uif.uid = cv(c_uint, st.st_uid);
    uif.gid = cv(c_uint, st.st_gid);
    ch.qid = fsqid(st);
}

fn isdot(name: [*:0]const u8) bool {
    return dev.streq(name, ".");
}

/// A final name that's a link to nothing is walked to as the link
/// itself, so it can be renamed, removed and lstat'd (an open of it still
/// fails, following it). False if name isn't such a link.
fn danglingwalk(ch: *Chan, name: [*:0]const u8) bool {
    const uif = uifOf(ch);
    if (chan.isdotdot(name) or isdot(name)) return false;
    const path = catpath(uif.path, name);
    var st: Stat = undefined;
    if (h9_fs_checkname(path, Walk) < 0 or beneath.lstat(path, &st) < 0 or !islnk(st.st_mode)) {
        free(path);
        return false;
    }
    setpath(uif, path, null);
    uif.canon = false;
    setstat(ch, uif, &st);
    return true;
}

/// A walk in a contained tree, resolved by fscheck.c inside it: 1, 0 if
/// name doesn't exist, or -1 for too many links.
fn walkin(ch: *Chan, name: [*:0]const u8) c_int {
    const uif = uifOf(ch);
    var buf: [path_max]u8 = undefined;
    const r = h9_fs_resolvein(uif.top.?, uif.path, name, &buf, buf.len);
    if (r == fs.RESLOOP) return -1;
    const bz: [*:0]const u8 = @ptrCast(&buf);
    var st: Stat = undefined;
    if (r < 0 or h9_fs_check(bz, Walk) < 0 or beneath.stat(bz, &st) < 0)
        return @intFromBool(danglingwalk(ch, name));
    var lpath: ?[*:0]u8 = null;
    if (!chan.isdotdot(name)) {
        const l = catpath(uif.path, name);
        if (dev.streq(l, bz)) free(l) else lpath = l;
    }
    setpath(uif, dupz(span(bz)), lpath);
    uif.canon = true; // h9_fs_resolvein's paths hold no links
    setstat(ch, uif, &st);
    return 1;
}

/// A walk for a Linux process (design/epoch-0/linux-symlinks.md), in
/// either mode: the name is looked up with lstat and checked by its own
/// path, and a link is walked to as itself, with QTSYMLINK in its qid,
/// for the kernel's walk to follow. ".." is the path's parent, since the
/// path holds no links, and stops at a contained tree's top.
fn walklx(ch: *Chan, name: [*:0]const u8) bool {
    const uif = uifOf(ch);
    if (!uif.canon) {
        if (!wasi) {
            var buf: [path_max]u8 = undefined;
            if (hc.realpath(uif.path, &buf) == null) return false;
            free(uif.path);
            uif.path = dupz(span(@as([*:0]const u8, @ptrCast(&buf))));
        }
        // The web host's opens refuse only a last name that's a link (openpath).
        free(uif.lpath);
        uif.lpath = null;
        uif.canon = true;
    }
    if (isdot(name)) return true;
    var path: [*:0]u8 = undefined;
    if (chan.isdotdot(name)) {
        path = dupz(span(uif.path));
        if (uif.top == null or !dev.streq(path, uif.top.?)) {
            if (std.mem.lastIndexOfScalar(u8, span(path), '/')) |s| {
                if (s == 0) path[1] = 0 else path[s] = 0;
            }
        }
    } else path = catpath(uif.path, name);
    var st: Stat = undefined;
    if (h9_fs_checkname(path, Walk) < 0 or beneath.lstat(path, &st) < 0) {
        free(path);
        return false;
    }
    setpath(uif, path, null);
    setstat(ch, uif, &st);
    if (islnk(st.st_mode)) ch.qid.type |= fs.QTSYMLINK;
    return true;
}

fn walk1(ch: *Chan, name: [*:0]const u8) c_int {
    const uif = uifOf(ch);
    if (h9_fs_linkwalk() != 0) return @intFromBool(walklx(ch, name));
    if (uif.top != null) return walkin(ch, name);
    const path = catpath(uif.path, name);
    var st: Stat = undefined;
    if (h9_fs_check(path, Walk) < 0 or beneath.stat(path, &st) < 0) {
        free(path);
        return @intFromBool(danglingwalk(ch, name));
    }
    free(uif.path);
    uif.path = path;
    uif.canon = false;
    setstat(ch, uif, &st);
    return 1;
}

fn fswalk(ch: *Chan, nc_: ?*Chan, name: [*]const [*:0]const u8, nname: c_int) Error!?*Walkqid {
    if (nc_ != null) port.kpanic("fswalk: nc != nil", .{});
    const n: usize = @intCast(nname);
    const wq = dev.walkqid(n);
    const nc = dev.devclone(ch);
    fsclone(ch, nc);
    wq.libclone = nc;
    var loop: c_int = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        loop = walk1(nc, name[i]);
        if (loop <= 0) break;
        dev.qids(wq)[i] = nc.qid;
        // h9: a Linux process's walk stops at a link (walklx).
        if (nc.qid.type & fs.QTSYMLINK != 0) {
            i += 1;
            break;
        }
    }
    if (i != n) {
        chan.cclose(nc);
        wq.libclone = null;
    }
    // h9: a link loop in a contained tree is an error, not a missing name.
    if (loop < 0) {
        c.free(wq);
        return port.kerror(fs.ELOOP);
    }
    wq.nqid = @intCast(i);
    // h9: as devwalk does, so namec tries the rest of a union.
    if (i == 0 and n > 0) {
        c.free(wq);
        chan.kstrcpy(port.up().errstr, &port.Enonexist, port.ERRMAX);
        return null;
    }
    return wq;
}

/// ch is an open file, with a host fd (uif.fd is 0, not -1, before open).
fn openfile(ch: *Chan) bool {
    return ch.flag & c.COPEN != 0 and ch.qid.type & c.QTDIR == 0 and uifOf(ch).fd >= 0;
}

/// The host's stat for ch, as stat and getattr give it.
fn hoststat(ch: *Chan, st: *Stat) Error!void {
    const uif = uifOf(ch);
    // An open file is the one its fd has, which a rename since may have
    // moved from its path (wstat); a dangling link (danglingwalk) has
    // only its own stat.
    if (openfile(ch) and hc.fstat(uif.fd, st) == 0) return;
    if (ch.qid.type & fs.QTSYMLINK != 0) {
        // A link a Linux walk stopped at is itself, DMSYMLINK by its qid.
        if (beneath.lstat(uif.path, st) < 0) return oserr();
        return;
    }
    if (beneath.lstat(uif.path, st) < 0) {
        if (beneath.lstat(ownpath(uif), st) < 0) return oserr();
    } else if (islnk(st.st_mode)) {
        // A link is stat'd as its target only if the policy shows the
        // target. A link walked to as itself because its target is
        // hidden (danglingwalk) keeps its own stat, so the size and
        // times of a file outside the policy don't show through it.
        var t: Stat = undefined;
        if (h9_fs_check(uif.path, Walk) == 0 and beneath.stat(uif.path, &t) == 0)
            st.* = t;
    }
}

fn dirOf(ch: *Chan, d: *Dir, qid: Qid, st: *const Stat) void {
    d.uid = c.eve;
    d.gid = c.eve;
    d.muid = c.eve;
    d.qid = qid;
    var mode: c_uint = (@as(c_uint, qid.type) << 24) | stmode(st);
    if (isfifo(st.st_mode)) mode |= fs.DMFIFO;
    d.mode = cv(@TypeOf(d.mode), webmode(mode));
    d.atime = cv(@TypeOf(d.atime), stSec(st, "a"));
    d.mtime = cv(@TypeOf(d.mtime), stSec(st, "m"));
    d.length = @intCast(st.st_size);
    d.type = 'U';
    d.dev = cv(@TypeOf(d.dev), ch.dev);
}

fn fsstat(ch: *Chan, buf: [*]u8, n: c_int) Error!c_int {
    if (n < c.BIT16SZ) return port.kerror(&port.Eshortstat);
    const uif = uifOf(ch);
    var st: Stat = undefined;
    try hoststat(ch, &st);
    var d: Dir = undefined;
    d.name = lastelem(ownpath(uif));
    dirOf(ch, &d, ch.qid, &st);
    return @intCast(c.convD2M(&d, buf, @intCast(n)));
}

fn fsopen(ch: *Chan, mode: c_int) Error!*Chan {
    const omode = try sysfile.openmode(@bitCast(mode));
    const uif = uifOf(ch);
    // A link walked to as itself has no target to open (danglingwalk).
    if (ch.qid.type & fs.QTSYMLINK != 0)
        return port.kerror(fs.ELOOP); // a Linux open that doesn't follow it
    if (islnk(uif.mode)) return port.kerror(&port.Enonexist);
    const op: c_int = if (omode == c.OREAD and mode & c.OTRUNC == 0) Read else Write;
    // Open first, then check the file the fd actually refers to (allowfd),
    // rather than checking uif.path and opening it as two separate
    // resolutions. A guest thread that swaps a path component for a
    // symlink between a check and the open can't redirect this open past
    // the policy: the fd and the check see one inode. The open reads
    // nothing until it has passed the check, and a truncation waits until
    // then so a denied file is left intact.
    if (ch.qid.type & c.QTDIR != 0) {
        if (omode != c.OREAD) return port.kerror(&port.Eperm);
        const fd = openpath(uif, uif.path, hc.O_RDONLY | hc.O_DIRECTORY, 0);
        if (fd < 0) return oserr();
        errdefer _ = hc.close(fd);
        notes.h9_fs_notefd(fd, uif.path);
        try allowfd(fd, op);
        if (mode & c.ORCLOSE != 0) try allowfd(fd, Remove);
        uif.dir = @as(?*hc.DIR, hc.fdopendir(fd)) orelse return oserr();
    } else if (isfifo(uif.mode)) {
        // A host FIFO is opened only to check it, without waiting for the
        // other end, and never read or written (fsread, fswrite): a Linux
        // program's open joins h9's own pipe for it (src/kern/fifo.zig),
        // and a Plan 9 program sees an empty file.
        const fd = openpath(uif, uif.path, hc.O_RDONLY | hc.O_NONBLOCK, 0);
        if (fd < 0) return oserr();
        errdefer _ = hc.close(fd);
        notes.h9_fs_notefd(fd, uif.path);
        try allowfd(fd, op);
        if (mode & c.ORCLOSE != 0) try allowfd(fd, Remove);
        uif.fd = fd;
    } else {
        var m = try omodeflags(omode & 3);
        // A truncation needs write access and must wait for the check.
        if (mode & c.OTRUNC != 0 and m & hc.O_ACCMODE == hc.O_RDONLY)
            m = (m & ~@as(c_int, hc.O_ACCMODE)) | hc.O_RDWR;
        const fd = openpath(uif, uif.path, m, 0o666);
        if (fd < 0) return oserr();
        errdefer _ = hc.close(fd);
        notes.h9_fs_notefd(fd, uif.path);
        try allowfd(fd, op);
        if (mode & c.ORCLOSE != 0) try allowfd(fd, Remove);
        if (mode & c.OTRUNC != 0 and hc.ftruncate(fd, 0) < 0) return oserr();
        uif.fd = fd;
    }
    uif.offset = 0;
    ch.offset = 0;
    ch.mode = @intCast(omode);
    ch.flag |= c.COPEN;
    return ch;
}

fn fscreate(ch: *Chan, name: [*:0]const u8, mode: c_int, perm: c_uint) Error!*Chan {
    const omode = try sysfile.openmode(@bitCast(mode & ~@as(c_int, c.OEXCL)));
    const uif = uifOf(ch);
    const path = catpath(uif.path, name);
    errdefer free(path);
    var fd: c_int = -1;
    var dir: ?*hc.DIR = null;
    var st: Stat = undefined;
    const pmode: c_uint = uif.mode & perm & 0o777;
    // Create relative to an fd for the parent directory, checked by the
    // directory the fd actually is. Check the new name's own slot before
    // creating (allowat) and the created file by the file it actually is
    // (allowfd) after, so a swapped parent component can't steer the
    // create outside the policy, and a symlink left in place of the name
    // can't hand back a write to a file outside it. A truncation waits
    // for that check.
    const dfd = try dirfdFor(uif, name, Create);
    defer _ = hc.close(dfd);
    if (perm & c.DMDIR != 0) {
        if (omode != c.OREAD) return port.kerror(&port.Eperm);
        if (hc.mkdirat(dfd, name, @intCast(pmode)) < 0) {
            if (errno() != hc.EEXIST or mode & c.OEXCL != 0) return oserr();
        }
        const nofollow: c_int = if (lxmode(uif)) hc.O_NOFOLLOW else 0;
        const dirfd = hc.openat(dfd, name, hc.O_RDONLY | hc.O_DIRECTORY | nofollow);
        if (dirfd < 0) return oserr();
        {
            errdefer _ = hc.close(dirfd);
            notes.h9_fs_notefdat(dirfd, dfd, name);
            try allowfd(dirfd, Create);
            dir = @as(?*hc.DIR, hc.fdopendir(dirfd)) orelse return oserr();
        }
        // dir now owns the fd; this isn't a file fd.
        errdefer _ = hc.closedir(dir);
        if (hc.fstatat(dfd, name, &st, 0) < 0) return oserr();
    } else {
        // POSIX specifies that O_TRUNC with O_RDONLY is undefined.
        // OpenBSD chooses to return an error.
        const m0 = omode & 3;
        var m = try omodeflags(if (m0 == c.OREAD) c.ORDWR else m0);
        m |= hc.O_CREAT;
        if (mode & c.OEXCL != 0) m |= hc.O_EXCL;
        // A Linux create doesn't follow a link left in its name.
        if (lxmode(uif)) m |= hc.O_NOFOLLOW;
        fd = hc.openat(dfd, name, m, pmode);
        if (fd < 0) return oserr();
        errdefer _ = hc.close(fd);
        notes.h9_fs_notefdat(fd, dfd, name);
        try allowfd(fd, Create);
        if (hc.ftruncate(fd, 0) < 0) return oserr();
        if (hc.fstat(fd, &st) < 0) return oserr();
    }
    // The parent's mode has no permission bits to inherit on the web host.
    if (wasi) wmodeset(&st, perm & 0o777);
    ch.qid = fsqid(&st);
    uif.fd = fd;
    uif.dir = dir;
    setpath(uif, path, null);
    uif.offset = 0;

    ch.offset = 0;
    ch.mode = @intCast(omode);
    ch.flag |= c.COPEN;
    return ch;
}

fn fsclose(ch: *Chan) Error!void {
    const uif = uifOf(ch);
    if (ch.flag & c.COPEN != 0) {
        if (ch.qid.type & c.QTDIR != 0) {
            if (uif.dir) |d| _ = hc.closedir(d);
        } else _ = hc.close(uif.fd);
        ch.flag &= ~@as(@TypeOf(ch.flag), c.COPEN);
        if (ch.flag & c.CRCLOSE != 0) return fsremove(ch);
    }
    free(uif.path);
    free(uif.top);
    free(uif.lpath);
    free(uif);
}

fn seek(uif: *Ufsinfo, offset: i64) Error!void {
    if (uif.offset != offset) {
        if (wasi) {
            // WASI's own seek: lld links wasi-libc's lseek to this call
            // through a stub that traps, as if the two disagreed on its
            // type. WASI's error numbers are wasi-libc's errno values.
            var pos: std.os.wasi.filesize_t = undefined;
            const rc = std.os.wasi.fd_seek(uif.fd, offset, .SET, &pos);
            if (rc != .SUCCESS) return oserrOf(@intFromEnum(rc));
        } else if (hc.lseek(uif.fd, @intCast(offset), 0) < 0) return oserr();
        uif.offset = offset;
    }
}

fn fsread(ch: *Chan, va: ?*anyopaque, n: c_int, offset: i64) Error!c_int {
    if (ch.qid.type & c.QTDIR != 0) return dirread(ch, @ptrCast(va), n, offset);
    const uif = uifOf(ch);
    if (isfifo(uif.mode)) return 0; // see fsopen
    sync.qlock(&uif.oq);
    defer sync.qunlock(&uif.oq);
    try seek(uif, offset);
    const r = hc.read(uif.fd, va, @intCast(n));
    if (r < 0) return oserr();
    uif.offset += @intCast(r);
    return @intCast(r);
}

fn fswrite(ch: *Chan, va: ?*const anyopaque, n: c_int, offset: i64) Error!c_int {
    const uif = uifOf(ch);
    if (isfifo(uif.mode)) return port.kerror(&port.Eperm); // see fsopen
    sync.qlock(&uif.oq);
    defer sync.qunlock(&uif.oq);
    try seek(uif, offset);
    const r = hc.write(uif.fd, va, @intCast(n));
    if (r < 0) return oserr();
    uif.offset += @intCast(r);
    return @intCast(r);
}

fn fsremove(ch: *Chan) Error!void {
    defer fsclose(ch) catch {};
    const uif = uifOf(ch);
    // Remove the entry relative to an fd for its parent directory, checked
    // (allowat) by that directory's own canonical path joined to the
    // name, so a swapped parent component can't steer the unlink outside
    // the policy. A link is removed, not its target.
    var base: [name_max + 1]u8 = undefined;
    const dfd = try parentfd(uif, ownpath(uif), &base);
    defer _ = hc.close(dfd);
    const bz: [*:0]const u8 = @ptrCast(&base);
    try allowat(dfd, bz, Remove);
    const flags: c_int = if (ch.qid.type & c.QTDIR != 0) hc.AT_REMOVEDIR else 0;
    if (hc.unlinkat(dfd, bz, flags) < 0) return oserr();
}

fn nochange(d: *const Dir) bool {
    return ~d.mode == 0 and ~d.atime == 0 and ~d.mtime == 0 and ~@as(u64, @bitCast(d.length)) == 0 and d.name[0] == 0;
}

fn fswstat(ch: *Chan, buf: [*]u8, n: c_int) Error!c_int {
    var d: Dir = undefined;
    var strs: [name_max * 3]u8 = undefined;
    if (c.convM2D(buf, @intCast(n), &d, @ptrCast(&strs)) != n) return port.kerror(&port.Ebadstat);

    const uif = uifOf(ch);
    // A wstat that changes nothing syncs the open file or directory
    // (fsync(2) for Linux programs; a directory's makes a rename or a
    // create in it durable).
    if (nochange(&d)) {
        try flush(ch);
        return n;
    }
    const trunc = ~@as(u64, @bitCast(d.length)) != 0;
    const dmode: c_uint = cv(c_uint, d.mode);
    // Find the file to change and bind the metadata operations to it
    // through a file descriptor, never by re-resolving its path. An open
    // file may have been renamed since (Zig renames its cache entries into
    // place, then truncates the output it still has open), so its path is
    // stale: it is changed through its own fd. Otherwise the file is
    // opened once and checked by the file the fd actually refers to
    // (allowfd), then changed through that fd (fchmod, futimens,
    // ftruncate), so a symlink swapped after the check can't redirect the
    // change to a file outside the policy. A dangling link (danglingwalk)
    // is checked and renamed as itself, and has no fd.
    var st: Stat = undefined;
    var fdst: Stat = undefined;
    var nbase: [name_max + 1]u8 = undefined;
    var opfd: c_int = -1;
    var wfd: c_int = -1;
    var nfd: c_int = -1;
    defer {
        if (opfd >= 0) _ = hc.close(opfd);
        if (nfd >= 0) _ = hc.close(nfd);
    }
    if (openfile(ch) and hc.fstat(uif.fd, &fdst) == 0 and
        (beneath.stat(uif.path, &st) < 0 or st.st_dev != fdst.st_dev or st.st_ino != fdst.st_ino))
    {
        const fl = hc.fcntl(uif.fd, hc.F_GETFL);
        if (fl < 0 or fl & hc.O_ACCMODE == hc.O_RDONLY or d.name[0] != 0) return oserrOf(hc.ENOENT);
        wfd = uif.fd;
        st = fdst;
    } else if (ch.qid.type & fs.QTSYMLINK != 0 or beneath.stat(uif.path, &st) < 0) {
        // And a link a Linux walk stopped at is changed as itself.
        if (beneath.lstat(ownpath(uif), &st) < 0) return oserr();
        if (!islnk(st.st_mode)) return oserr();
        if (h9_fs_checkname(ownpath(uif), Write) < 0) return port.kerror(&port.Eperm);
    } else if ((~d.mode != 0 and dmode & 0o777 != stmode(&st)) or ~d.atime != 0 or ~d.mtime != 0 or trunc) {
        // Truncation needs write access; it waits for the check below. A
        // rename alone needs no fd (it's done relative to the parent's,
        // below), so it doesn't open the file at all.
        opfd = openpath(uif, uif.path, if (trunc) hc.O_RDWR else hc.O_RDONLY, 0);
        if (opfd < 0) {
            // A file its owner can't read (mode 0000, as apk's temporary
            // etc/shadow is) can still have its mode and times set by its
            // owner, as on Linux. It's changed by name relative to an fd
            // for its parent, checked like a rename's (parentfd, allowat),
            // never following a link at its name, so a link swapped in
            // after the check is changed itself, not its target.
            if (wasi or errno() != hc.EACCES or trunc) return oserr();
            nfd = try parentfd(uif, uif.path, &nbase);
        }
        wfd = opfd;
    }
    const nbz: [*:0]const u8 = @ptrCast(&nbase);
    if (opfd >= 0) {
        notes.h9_fs_notefd(opfd, uif.path);
        try allowfd(opfd, Write);
        if (hc.fstat(opfd, &st) < 0) return oserr();
    }
    if (nfd >= 0) {
        try allowat(nfd, nbz, Write);
        if (hc.fstatat(nfd, nbz, &st, hc.AT_SYMLINK_NOFOLLOW) < 0) return oserr();
        if (islnk(st.st_mode)) return oserrOf(hc.EACCES);
    }
    const setmode = ~d.mode != 0 and dmode & 0o777 != stmode(&st);
    const settimes = ~d.atime != 0 or ~d.mtime != 0;

    // Try things in increasing order of harm to the file. mtime should
    // come after truncate so that if you do both the mtime actually takes
    // effect, but i'd rather leave truncate until last.
    if (setmode) {
        if (wasi) {
            if (wfd < 0) return oserrOf(hc.ENOENT);
            wmodeset(&st, dmode);
        } else if (nfd >= 0) {
            // musl and libSystem chmod by name without following a link.
            if (hc.fchmodat(nfd, nbz, @intCast(dmode & 0o777), hc.AT_SYMLINK_NOFOLLOW) < 0) return oserr();
        } else if (wfd < 0) {
            return oserrOf(hc.ENOENT);
        } else if (hc.fchmod(wfd, @intCast(dmode & 0o777)) < 0) return oserr();
        uif.mode &= ~@as(c_uint, 0o777);
        uif.mode |= dmode & 0o777;
    }
    if (settimes) {
        var ts: [2]hc.struct_timespec = std.mem.zeroes([2]hc.struct_timespec);
        ts[0].tv_sec = @intCast(if (~d.atime != 0) @as(i64, d.atime) else stSec(&st, "a"));
        ts[1].tv_sec = @intCast(if (~d.mtime != 0) @as(i64, d.mtime) else stSec(&st, "m"));
        if (nfd >= 0) {
            if (hc.utimensat(nfd, nbz, &ts, hc.AT_SYMLINK_NOFOLLOW) < 0) return oserr();
        } else if (wfd < 0) {
            return oserrOf(hc.ENOENT);
        } else _ = hc.futimens(wfd, &ts);
    }
    if (d.name[0] != 0 and !dev.streq(d.name, lastelem(ownpath(uif)))) {
        // A link is renamed, not its target. Rename relative to an fd for
        // the (shared) parent directory, checked by that directory's own
        // canonical path (allowat), so a swapped parent component can't
        // steer the rename outside the policy.
        var base: [name_max + 1]u8 = undefined;
        const dfd = try parentfd(uif, ownpath(uif), &base);
        defer _ = hc.close(dfd);
        const bz: [*:0]const u8 = @ptrCast(&base);
        try allowat(dfd, d.name, Create);
        try allowat(dfd, bz, Rename);
        var tst: Stat = undefined;
        if (hc.fstatat(dfd, d.name, &tst, hc.AT_SYMLINK_NOFOLLOW) >= 0) return port.kerror(&port.Eexist);
        if (hc.renameat(dfd, bz, dfd, d.name) < 0) return oserr();

        const own = span(ownpath(uif));
        const dirlen = @intFromPtr(lastelem(ownpath(uif))) - @intFromPtr(ownpath(uif));
        const dirpath = dupz(own[0..dirlen]);
        const newpath = catpath(dirpath, d.name);
        free(dirpath);
        if (uif.lpath) |l| {
            free(l);
            uif.lpath = newpath;
        } else {
            free(uif.path);
            uif.path = newpath;
        }
    }
    if (trunc) {
        if (wfd < 0) return oserrOf(hc.ENOENT);
        if (hc.ftruncate(wfd, @intCast(d.length)) < 0) return oserr();
    }
    return n;
}

fn fsqid(st: *const Stat) Qid {
    var q: Qid = std.mem.zeroes(Qid);
    if (isdir(st)) q.type = c.QTDIR;
    q.path = (cv(u64, st.st_dev) << 32) | cv(u64, st.st_ino);
    q.vers = cv(@TypeOf(q.vers), stSec(st, "m"));
    return q;
}

fn catpath(base: [*:0]const u8, ext: [*:0]const u8) [*:0]u8 {
    const b = span(base);
    const e = span(ext);
    const p: [*]u8 = @ptrCast(c.smalloc(@intCast(b.len + e.len + 2)));
    @memcpy(p[0..b.len], b);
    var n = b.len;
    if (n > 0 and p[n - 1] != '/') {
        p[n] = '/';
        n += 1;
    }
    @memcpy(p[n..][0..e.len], e);
    p[n + e.len] = 0;
    return @ptrCast(p);
}

fn isdots(name: []const u8) bool {
    return std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..");
}

fn p9readdir(name: *[name_max + 1]u8, uif: *Ufsinfo) bool {
    if (uif.nextname[0] != 0) {
        name.* = uif.nextname;
        uif.nextname[0] = 0;
        return true;
    }
    const de: *hc.struct_dirent = @as(?*hc.struct_dirent, hc.readdir(uif.dir)) orelse return false;
    // A flexible array on WASI, which translate-c makes a function.
    const dn: [*:0]const u8 = if (@hasField(hc.struct_dirent, "_d_name")) @ptrCast(de.d_name()) else @ptrCast(&de.d_name);
    const s = std.mem.sliceTo(dn, 0);
    const k = @min(s.len, name_max);
    @memcpy(name[0..k], s[0..k]);
    name[k] = 0;
    return true;
}

fn dirread(ch: *Chan, va: [*]u8, count: c_int, offset: i64) Error!c_int {
    var i: c_int = 0;
    const uif = uifOf(ch);
    const lx = h9_fs_linkwalk() != 0;

    if (uif.offset != offset) {
        if (offset != 0) return port.kerror("bad offset in fsdirread");
        uif.offset = offset; // sync offset
        uif.nextname[0] = 0;
        hc.rewinddir(uif.dir);
    }
    var de: [name_max + 1]u8 = undefined;
    while (i + c.BIT16SZ < count) {
        if (!p9readdir(&de, uif)) break;
        const dez: [*:0]u8 = @ptrCast(&de);
        const name = span(dez);
        if (name.len == 0 or isdots(name)) continue;

        var st: Stat = undefined;
        if (lx) {
            // For a Linux process, an entry is listed as itself, and a link
            // as a link, whether its target exists or not
            // (design/epoch-0/linux-symlinks.md).
            const p = catpath(uif.path, dez);
            defer free(p);
            if (h9_fs_checkname(p, Walk) < 0 or beneath.lstat(p, &st) < 0) continue;
        } else {
            // In a contained tree, an entry is listed as its walk resolves
            // it, and a link whose target is missing isn't.
            var p: [*:0]u8 = undefined;
            if (uif.top) |top| {
                var buf: [path_max]u8 = undefined;
                if (h9_fs_resolvein(top, uif.path, dez, &buf, buf.len) < 0) continue;
                p = dupz(span(@as([*:0]const u8, @ptrCast(&buf))));
            } else p = catpath(uif.path, dez);
            defer free(p);
            if (h9_fs_check(p, Walk) < 0) continue;
            if (beneath.stat(p, &st) < 0) {
                if (uif.top != null) continue;
                // But continue... probably a bad symlink.
                st = std.mem.zeroes(Stat);
            }
        }
        var d: Dir = undefined;
        d.name = dez;
        var q = fsqid(&st);
        if (islnk(st.st_mode)) q.type |= fs.QTSYMLINK;
        dirOf(ch, &d, q, &st);
        const n: c_int = @intCast(c.convD2M(&d, va + @as(usize, @intCast(i)), @intCast(count - i)));
        if (n == c.BIT16SZ) {
            uif.nextname = de;
            break;
        }
        i += n;
    }
    uif.offset += i;
    return i;
}

/// namec's, once a walk from a #U attach is done. A contained attach's
/// tree is where the walk ended, canonical.
pub fn anchor(ch: *Chan) Error!void {
    const uif = uifOf(ch);
    if (!uif.contained or uif.top != null) return;
    var buf: [path_max]u8 = undefined;
    if (hc.realpath(uif.path, &buf) == null) return oserr();
    const b = span(@as([*:0]const u8, @ptrCast(&buf)));
    uif.top = dupz(b);
    setpath(uif, dupz(b), null);
    uif.canon = true;
}

/// The target of the link ch's last name was, as it's written.
fn fsreadlink(ch: *Chan, buf: []u8) Error!?usize {
    if (buf.len == 0) return null;
    const uif = uifOf(ch);
    const p = ownpath(uif);
    var st: Stat = undefined;
    if (h9_fs_checkname(p, Walk) < 0 or beneath.lstat(p, &st) < 0 or !islnk(st.st_mode)) return null;
    const n = beneath.readlink(p, buf.ptr, buf.len - 1);
    if (n < 0) return null;
    buf[@intCast(n)] = 0;
    return @intCast(n);
}

/// Makes name in the directory ch a symbolic link to target, for the
/// Linux ABI's symlinkat. The new name is checked like a create; the
/// target is checked whenever a walk follows the link. It's made relative
/// to an fd for the directory, checked by the directory the fd actually
/// refers to and the new name's own slot.
fn fssymlink(ch: *Chan, name: [*:0]const u8, target: [*:0]const u8) Error!void {
    const dfd = try dirfdFor(uifOf(ch), name, Create);
    defer _ = hc.close(dfd);
    if (hc.symlinkat(target, dfd, name) < 0) return oserr();
}

/// Makes name in the directory ch a FIFO, for the Linux ABI's mknodat
/// (design/epoch-0/linux-fifo.md). The new name is checked like a create.
pub fn mkfifo(ch: *Chan, name: [*:0]const u8, perm: c_uint) Error!void {
    if (wasi or dev.of(ch).dc != 'U') return port.kerror(&port.Eperm);
    const dfd = try dirfdFor(uifOf(ch), name, Create);
    defer _ = hc.close(dfd);
    if (hc.mkfifoat(dfd, name, @intCast(perm & 0o777)) < 0) return oserr();
}

/// Whether the devfs chan ch is a host FIFO's.
pub fn isfifoChan(ch: *Chan) bool {
    if (dev.of(ch).dc != 'U') return false;
    return isfifo(uifOf(ch).mode);
}

/// The source's parent and the destination directory, each opened and
/// checked, for a rename or a link of ch to name in dir: the source's
/// name is checked as op.
fn twodirs(ch: *Chan, dir: *Chan, name: [*:0]const u8, op: c_int, base: *[name_max + 1]u8, ddfd: *c_int) Error!c_int {
    if (span(name).len > name_max) return oserrOf(hc.ENAMETOOLONG);
    const sdfd = try parentfd(uifOf(ch), ownpath(uifOf(ch)), base);
    errdefer _ = hc.close(sdfd);
    ddfd.* = try dirfdFor(uifOf(dir), name, Create);
    errdefer _ = hc.close(ddfd.*);
    try allowat(sdfd, @ptrCast(base), op);
    return sdfd;
}

/// ch moved to name in directory dir, for renameat across directories,
/// relative to fds for the source and destination parent directories,
/// each checked by the directory the fd actually refers to, so a swapped
/// parent component can't steer the rename outside the policy. The
/// source link is moved, not its target.
fn fsrename(ch: *Chan, dir: *Chan, name: [*:0]const u8) Error!bool {
    if (dev.of(ch).dc != 'U' or dev.of(dir).dc != 'U') return port.kerror(&port.Eperm);
    var base: [name_max + 1]u8 = undefined;
    var ddfd: c_int = -1;
    const sdfd = try twodirs(ch, dir, name, Rename, &base, &ddfd);
    defer {
        _ = hc.close(ddfd);
        _ = hc.close(sdfd);
    }
    if (hc.renameat(sdfd, @ptrCast(&base), ddfd, name) < 0) return oserr();
    return true;
}

/// Makes name in the directory dir another name for ch's file
/// (design/file-interface.md), relative to fds for both parent
/// directories, as rename is. The new name is checked like a create, and
/// the old like a write, since the new name writes it.
fn fslink(ch: *Chan, dir: *Chan, name: [*:0]const u8) Error!bool {
    if (dev.of(dir).dc != 'U') return port.kerror(&port.Eperm);
    var base: [name_max + 1]u8 = undefined;
    var ddfd: c_int = -1;
    const sdfd = try twodirs(ch, dir, name, Write, &base, &ddfd);
    defer {
        _ = hc.close(ddfd);
        _ = hc.close(sdfd);
    }
    if (hc.linkat(sdfd, @ptrCast(&base), ddfd, name, 0) < 0) return oserr();
    return true;
}

/// ch's attributes, from the host's stat (design/file-interface.md).
fn fsgetattr(ch: *Chan, mask: u64, a: *Attr) Error!void {
    _ = mask;
    var st: Stat = undefined;
    try hoststat(ch, &st);
    a.valid = c.Abasic;
    a.qid = ch.qid;
    var mode: c_uint = (@as(c_uint, ch.qid.type) << 24) | stmode(&st);
    if (isfifo(st.st_mode)) mode |= fs.DMFIFO;
    a.mode = cv(@TypeOf(a.mode), mode);
    a.uid = cv(@TypeOf(a.uid), st.st_uid);
    a.gid = cv(@TypeOf(a.gid), st.st_gid);
    a.nlink = @intCast(st.st_nlink);
    a.rdev = cv(@TypeOf(a.rdev), st.st_rdev);
    a.size = cv(@TypeOf(a.size), st.st_size);
    a.blocks = cv(@TypeOf(a.blocks), st.st_blocks);
    a.atime = stSec(&st, "a");
    a.atimens = stNsec(&st, "a");
    a.mtime = stSec(&st, "m");
    a.mtimens = stNsec(&st, "m");
    a.ctime = stSec(&st, "c");
    a.ctimens = stNsec(&st, "c");
}

/// The host fd of an open file or directory, or -1. uif.fd is 0 until a
/// file is opened, and a directory's is never set: its DIR is.
fn hostfd(ch: *Chan) c_int {
    const uif = uifOf(ch);
    if (ch.flag & c.COPEN == 0) return -1;
    if (ch.qid.type & c.QTDIR != 0) return if (uif.dir) |d| hc.dirfd(d) else -1;
    return uif.fd;
}

/// Syncs an open file or directory to the host's disk. On macOS fsync(2)
/// leaves the data in the drive's cache; F_FULLFSYNC flushes it, and
/// fsync stands in where the file system can't. Hosts that can't sync a
/// directory say EINVAL (or EBADF for one opened read-only), as
/// PostgreSQL's fsync_fname allows for.
fn flush(ch: *Chan) Error!void {
    const fd = hostfd(ch);
    if (fd < 0) return;
    if (@hasDecl(hc, "F_FULLFSYNC")) {
        if (hc.fcntl(fd, hc.F_FULLFSYNC) == 0) return;
    }
    if (hc.fsync(fd) < 0) {
        const e = errno();
        if (e != hc.EINVAL and !(e == hc.EBADF and ch.qid.type & c.QTDIR != 0)) return oserrOf(e);
    }
}

/// syncfs(2) on the open devfs chan ch: Linux's syncfs on the host file
/// system it's on. Elsewhere, sync(2) and then the file's own sync, which
/// on macOS (F_FULLFSYNC) also flushes the drive's cache; the web host
/// has only the file's.
pub fn syncfs(ch: *Chan) Error!void {
    if (dev.of(ch).dc != 'U') return;
    const fd = hostfd(ch);
    if (fd < 0) return;
    if (linux) {
        if (hc.syncfs(fd) < 0) return oserr();
        return;
    }
    if (!wasi) hc.sync();
    try flush(ch);
}

/// sync(2): every host file system (none on the web host).
pub fn syncall() Error!void {
    if (!wasi) hc.sync();
}

fn omodeflags(m: c_int) Error!c_int {
    return switch (m) {
        c.OREAD, c.OEXEC => hc.O_RDONLY,
        c.OWRITE => hc.O_WRONLY,
        c.ORDWR => hc.O_RDWR,
        else => port.kerror(&port.Ebadarg),
    };
}

pub const Device = dev.Native('U', "fs", .{
    .attach = fsattach,
    .walk = fswalk,
    .stat = fsstat,
    .open = fsopen,
    .create = fscreate,
    .close = fsclose,
    .read = fsread,
    .write = fswrite,
    .remove = fsremove,
    .wstat = fswstat,
    .readlink = fsreadlink,
    .symlink = fssymlink,
    .link = fslink,
    .getattr = fsgetattr,
    .rename = fsrename,
});
