//! The host tree device, `#U`, on Windows (design/host-handles.md):
//! drawterm's devfs-win32.c, ported to Zig as a native device, with h9's
//! changes to it. A close translation: the same functions in the same
//! order, with error unions in place of C's error labels.
//!
//! Paths are "" (the list of drives), "C:", and "C:\a\b". Files are
//! opened and directories made through src/host/fscheck.c's wrappers of
//! the Win32 calls (`h9_fs_createfile`, `h9_fs_createdir`, and the rest),
//! which open beneath the machine's directory handle that holds each path
//! with NtCreateFile a name at a time (src/host/dirs.c), so the host
//! follows no symbolic link or junction out of a handle, and which spell
//! a drive path "\\?\C:\a\b" so that names Windows reserves are files
//! like any other. The policy checks stay as the second line: an open is
//! checked by the file its handle opened (`allowhandle`).

const std = @import("std");
const kern = @import("kern");
const w = @import("win32.zig");
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

const HANDLE = w.HANDLE;
const WCHAR = w.WCHAR;
const FindData = w.WIN32_FIND_DATAW;
const invalid = w.INVALID_HANDLE_VALUE;
const MAX_PATH = w.MAX_PATH;

const Walk = fs.Walk;
const Read = fs.Read;
const Write = fs.Write;
const Create = fs.Create;
const Remove = fs.Remove;
const Rename = fs.Rename;

// src/host/fscheck.c: the policy's checks of devfs's paths, which never
// raise, and the Win32 calls beneath the machine's directory handles.
extern fn h9_fs_resolveinw(top: [*:0]const WCHAR, dir: [*:0]const WCHAR, rel: [*:0]const u8, buf: [*]WCHAR, nbuf: c_int) c_int;
extern fn h9_fs_readlinkw(path: [*:0]const WCHAR, buf: [*]u8, nbuf: c_int) c_int;
extern fn h9_fs_checkw(path: [*:0]const WCHAR, op: c_int) c_int;
extern fn h9_fs_checknamew(path: [*:0]const WCHAR, op: c_int) c_int;
extern fn h9_fs_checkhandlew(h: HANDLE, op: c_int) c_int;
extern fn h9_fs_findfirst(path: [*:0]const WCHAR, wfd: *FindData) HANDLE;
extern fn h9_fs_createfile(path: [*:0]const WCHAR, access: u32, share: u32, sa: ?*anyopaque, disp: u32, flags: u32, tmpl: ?HANDLE) HANDLE;
extern fn h9_fs_createdir(path: [*:0]const WCHAR, sa: ?*anyopaque) w.BOOL;
extern fn h9_fs_removedir(path: [*:0]const WCHAR) w.BOOL;
extern fn h9_fs_deletefile(path: [*:0]const WCHAR) w.BOOL;
extern fn h9_fs_movefile(old: [*:0]const WCHAR, new: [*:0]const WCHAR) w.BOOL;
extern fn h9_fs_getattr(path: [*:0]const WCHAR) u32;
// src/kern/linux.zig: whether the calling process's walks stop at links.
extern fn h9_fs_linkwalk() c_int;

const Tpath = enum { root, volume, file };

/// A directory being read: a search (FindFirstFile), or for "" the
/// list of drives.
const DirState = struct {
    handle: HANDLE,
    wfd: FindData,
    drivebuf: ?[*]WCHAR,
    drivep: [*]WCHAR,
    /// Don't move to the next item.
    keep: bool,
};

const Ufsinfo = struct {
    fh: HANDLE,
    dir: ?*DirState,
    offset: i64,
    oq: c.QLock,
    path: [*:0]WCHAR,
    /// A contained attach (#U!c, design/epoch-0/symlinks-in-root.md)
    /// resolves links inside top once namec's walk has set it (`anchor`).
    /// path is then always resolved, and lpath, if set, is the link the
    /// last name was, in its resolved directory.
    contained: bool,
    top: ?[*:0]WCHAR,
    lpath: ?[*:0]WCHAR,
};

fn newdir() *DirState {
    const d = alloc(DirState);
    d.* = .{ .handle = invalid, .wfd = std.mem.zeroes(FindData), .drivebuf = null, .drivep = undefined, .keep = false };
    return d;
}

fn uifOf(ch: *Chan) *Ufsinfo {
    return @ptrCast(@alignCast(dev.aux(ch).*.?));
}

fn alloc(comptime T: type) *T {
    return @ptrCast(@alignCast(c.smalloc(@sizeOf(T))));
}

fn free(p: anytype) void {
    c.free(@ptrCast(@constCast(p)));
}

fn wspan(s: [*:0]const WCHAR) []const WCHAR {
    return std.mem.span(s);
}

fn wstrdup(s: []const WCHAR) [*:0]WCHAR {
    const d: [*]WCHAR = @ptrCast(@alignCast(c.smalloc(@intCast((s.len + 1) * 2))));
    @memcpy(d[0..s.len], s);
    d[s.len] = 0;
    return @ptrCast(d);
}

fn wcseq(a: [*:0]const WCHAR, b: [*:0]const WCHAR) bool {
    return std.mem.eql(WCHAR, wspan(a), wspan(b));
}

/// The chan's own name on the host: the link, not its target.
fn ownpath(uif: *Ufsinfo) [*:0]WCHAR {
    return uif.lpath orelse uif.path;
}

/// The policy's verdict as an error: hidden, or read-only.
fn verdict(r: c_int) Error!void {
    switch (r) {
        0 => return,
        -2 => return port.kerror(&port.Eperm),
        else => return port.kerror(&port.Enonexist),
    }
}

fn allow(path: [*:0]const WCHAR, op: c_int) Error!void {
    return verdict(h9_fs_checkw(path, op));
}

/// The policy's decision for an open handle, by the file the handle
/// actually opened (GetFinalPathNameByHandle) rather than by resolving a
/// path again, so a swapped component can't steer an open past it.
fn allowhandle(h: HANDLE, op: c_int) Error!void {
    return verdict(h9_fs_checkhandlew(h, op));
}

/// A symbolic link or a junction, which a Linux process's walk stops at
/// (design/epoch-0/linux-symlinks.md). FindFirstFile reads a name's own
/// entry without following it, with the reparse tag in dwReserved0.
fn wfdislink(wfd: *const FindData) bool {
    return wfd.dwFileAttributes & w.FILE_ATTRIBUTE_REPARSE_POINT != 0 and
        (wfd.dwReserved0 == w.IO_REPARSE_TAG_SYMLINK or wfd.dwReserved0 == w.IO_REPARSE_TAG_MOUNT_POINT);
}

/// A link's Dir, for a Linux process: DMSYMLINK, its target's length.
fn linkdir(path: [*:0]const WCHAR, d: *Dir, qid: Qid) void {
    var target: [MAX_PATH * 3]u8 = undefined;
    d.qid = qid;
    d.mode = (d.mode & ~@as(@TypeOf(d.mode), c.DMDIR)) | fs.DMSYMLINK;
    const n = h9_fs_readlinkw(path, &target, target.len);
    d.length = if (n > 0) n else 0;
}

fn unixtime(ft: *const w.FILETIME) c_uint {
    var t: i64 = @bitCast((@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime);
    t -= 116444736000000000;
    const s: i64 = if (t < 0) -1 - @divTrunc(-t - 1, 10000000) else @divTrunc(t, 10000000);
    return @truncate(@as(u64, @bitCast(s)));
}

fn filetime(ut: c_uint) w.FILETIME {
    const t: i64 = @as(i64, ut) * 10000000 + 116444736000000000;
    const u: u64 = @bitCast(t);
    return .{ .dwLowDateTime = @truncate(u), .dwHighDateTime = @truncate(u >> 32) };
}

fn pathhash(p: [*:0]const WCHAR) u64 {
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(std.mem.sliceAsBytes(wspan(p)), &digest, .{});
    return std.mem.readInt(u64, digest[0..8], .little);
}

fn wfdtodmode(wfd: *const FindData) c_uint {
    var m: c_uint = c.DMREAD | c.DMWRITE | c.DMEXEC;
    if (wfd.dwFileAttributes & w.FILE_ATTRIBUTE_DIRECTORY != 0) m |= c.DMDIR;
    if (wfd.dwFileAttributes & w.FILE_ATTRIBUTE_READONLY != 0) m &= ~@as(c_uint, c.DMWRITE);
    // Owner bits only (0700, 0600, 0500). Windows has no group or other
    // bits, and Postgres refuses a data directory that reads as group- or
    // world-writable.
    return (m & 0o7) << 6 | (m & ~@as(c_uint, 0o777));
}

/// FindFirstFile of path, closed: its own entry, not following it.
fn findone(path: [*:0]const WCHAR, wfd: *FindData) bool {
    const h = h9_fs_findfirst(path, wfd);
    if (h == invalid) return false;
    _ = w.FindClose(h);
    return true;
}

/// A FindFirstFile or FindNextFile entry is the parent directory's copy
/// of a name's times and size, which NTFS updates lazily: a directory's
/// last-write time there stays at what it was before a name was made in
/// it, so a listing (or a walk) and a stat would disagree on its mtime
/// and qid.vers, and an index made from a listing would be stale
/// (design/epoch-0/mount-index.md). GetFileAttributesEx reads the name's
/// own record, so each takes the times and size from there; the
/// attributes and reparse tag stay the entry's.
fn ownrecord(path: [*:0]const WCHAR, wfd: *FindData) void {
    var fa: w.WIN32_FILE_ATTRIBUTE_DATA = undefined;
    if (w.GetFileAttributesExW(path, w.GetFileExInfoStandard, &fa) == 0) return;
    wfd.ftLastAccessTime = fa.ftLastAccessTime;
    wfd.ftLastWriteTime = fa.ftLastWriteTime;
    wfd.nFileSizeHigh = fa.nFileSizeHigh;
    wfd.nFileSizeLow = fa.nFileSizeLow;
}

/// A host file's qid from its entry, once ownrecord has updated it.
fn fileqid(path: [*:0]const WCHAR, wfd: *const FindData) Qid {
    var q: Qid = std.mem.zeroes(Qid);
    q.type = if (wfd.dwFileAttributes & w.FILE_ATTRIBUTE_DIRECTORY != 0) c.QTDIR else c.QTFILE;
    q.path = pathhash(path);
    q.vers = unixtime(&wfd.ftLastWriteTime);
    return q;
}

fn wfdtoqid(path: [*:0]const WCHAR, wfd_: ?*const FindData) Error!Qid {
    var q: Qid = std.mem.zeroes(Qid);
    switch (pathtype(path)) {
        .volume, .root => {
            q.type = c.QTDIR;
            q.path = pathhash(path);
            q.vers = 0;
        },
        .file => {
            var f: FindData = undefined;
            if (wfd_) |x| f = x.* else if (!findone(path, &f)) return w.oserr();
            ownrecord(path, &f);
            q = fileqid(path, &f);
        },
    }
    return q;
}

fn wfdtodir(path: [*:0]const WCHAR, d: *Dir, wfd_: ?*const FindData) Error!void {
    var wfd = wfd_;
    var f: FindData = undefined;
    switch (pathtype(path)) {
        .volume, .root => {
            wfd = null;
            d.mode = 0o777 | c.DMDIR;
            d.atime = @truncate(@as(c_uint, @bitCast(c.seconds())));
            d.mtime = kerndate;
            d.length = 0;
        },
        .file => {
            if (wfd == null) {
                if (!findone(path, &f)) return w.oserr();
                // FindFirstFile reads the directory entry, whose size and
                // times NTFS updates lazily while another handle writes,
                // so a stat right after a write could see the old size.
                // GetFileAttributesEx reads the file's own record.
                var fa: w.WIN32_FILE_ATTRIBUTE_DATA = undefined;
                if (w.GetFileAttributesExW(path, w.GetFileExInfoStandard, &fa) != 0) {
                    f.dwFileAttributes = fa.dwFileAttributes;
                    f.ftLastAccessTime = fa.ftLastAccessTime;
                    f.ftLastWriteTime = fa.ftLastWriteTime;
                    f.nFileSizeHigh = fa.nFileSizeHigh;
                    f.nFileSizeLow = fa.nFileSizeLow;
                }
            } else {
                // A listing's entry, as a stat sees it (ownrecord).
                f = wfd.?.*;
                ownrecord(path, &f);
            }
            wfd = &f;
            const x = wfd.?;
            d.mode = wfdtodmode(x);
            d.atime = unixtime(&x.ftLastAccessTime);
            d.mtime = unixtime(&x.ftLastWriteTime);
            d.length = @bitCast((@as(u64, x.nFileSizeHigh) << 32) | x.nFileSizeLow);
        },
    }
    d.qid = if (wfd) |x| fileqid(path, x) else try wfdtoqid(path, null);
    d.uid = c.eve;
    d.gid = c.eve;
    d.muid = c.eve;
}

extern var kerndate: c_uint;

fn lastelem(ch: *Chan) [*:0]u8 {
    const s: [*:0]u8 = @constCast(chan.chanpath(ch));
    const t = std.mem.lastIndexOfScalar(u8, std.mem.span(s), '/') orelse return s;
    if (s[t + 1] == 0) return s + t;
    return s + t + 1;
}

fn pathtype(path: [*:0]const WCHAR) Tpath {
    if (path[0] == 0 or path[1] == 0) return .root;
    if (path[1] == ':' and path[2] == 0) return .volume;
    return .file;
}

fn checkvolume(path: [*:0]const WCHAR) bool {
    var vol: [MAX_PATH]WCHAR = undefined;
    var volname: [MAX_PATH]WCHAR = undefined;
    var fsysname: [MAX_PATH]WCHAR = undefined;
    var complen: w.DWORD = 0;
    var flags: w.DWORD = 0;
    const p = wspan(path);
    if (p.len + 2 > vol.len) return false;
    @memcpy(vol[0..p.len], p);
    vol[p.len] = '\\';
    vol[p.len + 1] = 0;
    return w.GetVolumeInformationW(@ptrCast(&vol), &volname, MAX_PATH, null, &complen, &flags, &fsysname, MAX_PATH) != 0;
}

var devno: c_int = 0;

fn fsattach(spec: [*:0]const u8) Error!*Chan {
    // The only spec is !c, a contained tree.
    var contained = false;
    if (spec[0] != 0) {
        if (!dev.streq(spec, "!c")) return port.kerror(&port.Ebadspec);
        contained = true;
    }
    const uif = alloc(Ufsinfo);
    uif.* = .{
        .fh = invalid,
        .dir = null,
        .offset = 0,
        .oq = std.mem.zeroes(c.QLock),
        .path = wstrdup(&.{}),
        .contained = contained,
        .top = null,
        .lpath = null,
    };

    const ch = dev.devattach('U', spec);
    dev.aux(ch).* = uif;
    ch.dev = @bitCast(@atomicRmw(c_int, &devno, .Add, 1, .monotonic));
    ch.qid.type = c.QTDIR;
    return ch;
}

fn fsclone(ch: *Chan, nc: *Chan) void {
    const uif = alloc(Ufsinfo);
    uif.* = uifOf(ch).*;
    uif.path = wstrdup(wspan(uif.path));
    if (uif.top) |t| uif.top = wstrdup(wspan(t));
    if (uif.lpath) |l| uif.lpath = wstrdup(wspan(l));
    dev.aux(nc).* = uif;
}

fn setpath(uif: *Ufsinfo, path: [*:0]WCHAR, lpath: ?[*:0]WCHAR) void {
    free(uif.path);
    uif.path = path;
    free(uif.lpath);
    uif.lpath = lpath;
}

/// A walk in a contained tree, resolved by fscheck.c inside it: 1, 0 if
/// name doesn't exist, or -1 for too many links.
fn walkin(ch: *Chan, name: [*:0]const u8) Error!c_int {
    const uif = uifOf(ch);
    var buf: [MAX_PATH * 4]WCHAR = undefined;
    const r = h9_fs_resolveinw(uif.top.?, uif.path, name, &buf, buf.len);
    if (r == fs.RESLOOP) return -1;
    const bz: [*:0]const WCHAR = @ptrCast(&buf);
    if (r < 0 or h9_fs_checkw(bz, Walk) < 0) return 0;
    if (pathtype(bz) == .file) {
        var wfd: FindData = undefined;
        if (!findone(bz, &wfd)) return 0;
        ch.qid = try wfdtoqid(bz, &wfd);
    } else ch.qid = try wfdtoqid(bz, null);
    var lpath: ?[*:0]WCHAR = null;
    if (!chan.isdotdot(name)) {
        const l = catpath(uif.path, name);
        if (wcseq(l, bz)) free(l) else lpath = l;
    }
    setpath(uif, wstrdup(wspan(bz)), lpath);
    return 1;
}

/// A walk for a Linux process (design/epoch-0/linux-symlinks.md), in
/// either mode: the name is looked up as itself and checked by its own
/// path, and a link (wfdislink) is walked to as itself, with QTSYMLINK in
/// its qid, for the kernel's walk to follow. ".." stops at a contained
/// tree's top.
fn walklx(ch: *Chan, name: [*:0]const u8) Error!bool {
    const uif = uifOf(ch);
    if (dev.streq(name, ".")) return true;
    if (chan.isdotdot(name) and uif.top != null and wcseq(uif.path, uif.top.?)) return true;
    const p = catpath(uif.path, name);
    errdefer free(p);
    if (h9_fs_checknamew(p, Walk) < 0) {
        free(p);
        return false;
    }
    switch (pathtype(p)) {
        .volume, .root => |t| {
            if (t == .volume and !checkvolume(p)) {
                free(p);
                return false;
            }
            ch.qid = try wfdtoqid(p, null);
        },
        .file => {
            var wfd: FindData = undefined;
            if (!findone(p, &wfd)) {
                free(p);
                return false;
            }
            ch.qid = try wfdtoqid(p, &wfd);
            if (wfdislink(&wfd)) ch.qid.type = fs.QTSYMLINK;
        },
    }
    setpath(uif, p, null);
    return true;
}

fn walk1(ch: *Chan, name: [*:0]const u8) Error!c_int {
    const uif = uifOf(ch);
    if (h9_fs_linkwalk() != 0) return @intFromBool(try walklx(ch, name));
    if (uif.top != null) return walkin(ch, name);
    const p = catpath(uif.path, name);
    errdefer free(p);
    if (h9_fs_checkw(p, Walk) < 0) {
        free(p);
        return 0;
    }
    switch (pathtype(p)) {
        .volume, .root => |t| {
            if (t == .volume and !checkvolume(p)) {
                free(p);
                return 0;
            }
            ch.qid = try wfdtoqid(p, null);
        },
        .file => {
            var wfd: FindData = undefined;
            if (!findone(p, &wfd)) {
                free(p);
                return 0;
            }
            ch.qid = try wfdtoqid(p, &wfd);
        },
    }
    free(uif.path);
    uif.path = p;
    return 1;
}

fn fswalk(ch: *Chan, nc_: ?*Chan, name: [*]const [*:0]const u8, nname: c_int) Error!?*Walkqid {
    if (nc_ != null) port.kpanic("fswalk: nc != nil", .{});
    const n: usize = @intCast(nname);
    const wq = dev.walkqid(n);
    errdefer c.free(wq);
    const nc = dev.devclone(ch);
    fsclone(ch, nc);
    wq.libclone = nc;
    var loop: c_int = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        loop = walk1(nc, name[i]) catch |e| {
            chan.cclose(nc);
            return e;
        };
        if (loop <= 0) break;
        dev.qids(wq)[i] = nc.qid;
        // A Linux process's walk stops at a link (walklx).
        if (nc.qid.type & fs.QTSYMLINK != 0) {
            i += 1;
            break;
        }
    }
    if (i != n) {
        chan.cclose(nc);
        wq.libclone = null;
    }
    // A link loop in a contained tree is an error, not a missing name.
    if (loop < 0) return port.kerror(fs.ELOOP);
    wq.nqid = @intCast(i);
    // As devwalk does, so namec tries the rest of a union.
    if (i == 0 and n > 0) {
        c.free(wq);
        chan.kstrcpy(port.up().errstr, &port.Enonexist, port.ERRMAX);
        return null;
    }
    return wq;
}

fn fsstat(ch: *Chan, buf: [*]u8, n: c_int) Error!c_int {
    if (n < c.BIT16SZ) return port.kerror(&port.Eshortstat);
    const uif = uifOf(ch);
    var d: Dir = undefined;
    d.name = lastelem(ch);
    try wfdtodir(uif.path, &d, null);
    if (ch.qid.type & fs.QTSYMLINK != 0) linkdir(uif.path, &d, ch.qid);
    d.type = 'U';
    d.dev = @bitCast(ch.dev);
    return @intCast(c.convD2M(&d, buf, @intCast(n)));
}

fn fsopen(ch: *Chan, mode: c_int) Error!*Chan {
    const omode = try sysfile.openmode(@bitCast(mode));
    const uif = uifOf(ch);
    // A link a Linux walk stopped at isn't followed (design/epoch-0/linux-symlinks.md).
    if (ch.qid.type & fs.QTSYMLINK != 0) return port.kerror(fs.ELOOP);
    const op: c_int = if (omode == c.OREAD and mode & c.OTRUNC == 0) Read else Write;
    if (ch.qid.type & c.QTDIR != 0) {
        // A directory is listed by search, not a handle, so check its path.
        try allow(uif.path, op);
        if (mode & c.ORCLOSE != 0) try allow(uif.path, Remove);
        if (omode != c.OREAD) return port.kerror(&port.Eperm);
        const d = newdir();
        errdefer free(d);
        switch (pathtype(uif.path)) {
            .root => {
                const buf: [*]WCHAR = @ptrCast(@alignCast(c.smalloc(@sizeOf(WCHAR) * MAX_PATH)));
                if (w.GetLogicalDriveStringsW(MAX_PATH - 1, buf) == 0) {
                    const e = w.oserr();
                    free(buf);
                    return e;
                }
                d.drivebuf = buf;
                d.drivep = buf;
            },
            .volume, .file => {
                const p = catpath(uif.path, "*.*");
                defer free(p);
                d.handle = h9_fs_findfirst(p, &d.wfd);
                if (d.handle == invalid) return w.oserr();
            },
        }
        d.keep = true;
        uif.dir = d;
    } else {
        uif.dir = null;
        // FILE_READ_ATTRIBUTES so GetFinalPathNameByHandle works on a
        // write-only open (the handle check needs it).
        var access = try fsaccess(omode & 3) | w.FILE_READ_ATTRIBUTES;
        // A truncation needs write access and must wait for the check.
        if (mode & c.OTRUNC != 0) access |= w.GENERIC_WRITE;
        // Open first, then check the file the handle actually refers to
        // (allowhandle), rather than checking uif.path and opening it as
        // two separate resolutions. The open follows links as before, but
        // the truncation is withheld (OPEN_EXISTING, then SetEndOfFile)
        // until the check passes, so a denied file keeps its contents. A
        // Linux process's open doesn't follow a link swapped in since its
        // walk: it opens the reparse point itself and refuses it
        // (design/epoch-0/linux-symlinks.md).
        const lx = h9_fs_linkwalk() != 0;
        // As POSIX, a file can be removed while open.
        const share = w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE;
        const flags = w.FILE_ATTRIBUTE_NORMAL | (if (lx) w.FILE_FLAG_OPEN_REPARSE_POINT else 0);
        uif.fh = h9_fs_createfile(uif.path, access, share, null, w.OPEN_EXISTING, flags, null);
        if (uif.fh == invalid) return w.oserr();
        errdefer {
            _ = w.CloseHandle(uif.fh);
            uif.fh = invalid;
        }
        if (lx) {
            var fi: w.BY_HANDLE_FILE_INFORMATION = undefined;
            if (w.GetFileInformationByHandle(uif.fh, &fi) == 0) return w.oserr();
            if (fi.dwFileAttributes & w.FILE_ATTRIBUTE_REPARSE_POINT != 0) return port.kerror(fs.ELOOP);
        }
        try allowhandle(uif.fh, op);
        if (mode & c.ORCLOSE != 0) try allowhandle(uif.fh, Remove);
        if (mode & c.OTRUNC != 0) {
            if (w.SetFilePointer(uif.fh, 0, null, w.FILE_BEGIN) == w.INVALID_SET_FILE_POINTER or w.SetEndOfFile(uif.fh) == 0)
                return w.oserr();
        }
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
    const newpath = catpath(uif.path, name);
    errdefer free(newpath);
    var d: ?*DirState = null;
    var h: HANDLE = invalid;
    try allow(newpath, Create);
    if (perm & c.DMDIR != 0) {
        if (omode != c.OREAD or pathtype(uif.path) == .root) return port.kerror(&port.Eperm);
        if (h9_fs_createdir(newpath, null) == 0) {
            if (w.GetLastError() != w.ERROR_ALREADY_EXISTS or mode & c.OEXCL != 0) return w.oserr();
        }
        const x = newdir();
        const p = catpath(newpath, "*.*");
        x.handle = h9_fs_findfirst(p, &x.wfd);
        free(p);
        if (x.handle == invalid) {
            const e = w.oserr();
            free(x);
            return e;
        }
        x.keep = true;
        d = x;
    } else {
        h = h9_fs_createfile(newpath, try fsaccess(omode & 3), w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE, // as in fsopen
            null, if (mode & c.OEXCL != 0) w.CREATE_NEW else w.CREATE_ALWAYS, w.FILE_ATTRIBUTE_NORMAL, null);
        if (h == invalid) return w.oserr();
    }
    errdefer {
        if (d) |x| {
            _ = w.FindClose(x.handle);
            free(x);
        } else _ = w.CloseHandle(h);
    }
    ch.qid = try wfdtoqid(newpath, null);
    uif.dir = d;
    uif.fh = h;
    setpath(uif, newpath, null);
    uif.offset = 0;

    ch.offset = 0;
    ch.mode = @intCast(omode);
    ch.flag |= c.COPEN;
    return ch;
}

fn fsclose(ch: *Chan) Error!void {
    const uif = uifOf(ch);
    if (ch.flag & c.COPEN != 0) {
        if (uif.dir) |d| {
            if (d.drivebuf) |b| {
                free(b);
                d.drivebuf = null;
            } else {
                _ = w.FindClose(d.handle);
                free(d);
            }
        } else _ = w.CloseHandle(uif.fh);
        ch.flag &= ~@as(@TypeOf(ch.flag), c.COPEN);
        if (ch.flag & c.CRCLOSE != 0) return fsremove(ch);
    }
    free(uif.path);
    free(uif.top);
    free(uif.lpath);
    free(uif);
}

fn seek(uif: *Ufsinfo, offset: i64) void {
    if (uif.offset != offset) {
        var high: i32 = @truncate(offset >> 32);
        const lo = w.SetFilePointer(uif.fh, @bitCast(@as(u32, @truncate(@as(u64, @bitCast(offset))))), &high, w.FILE_BEGIN);
        uif.offset = @as(i64, lo) | (@as(i64, high) << 32);
    }
}

fn fsread(ch: *Chan, va: ?*anyopaque, n: c_int, offset: i64) Error!c_int {
    if (ch.qid.type & c.QTDIR != 0) return dirread(ch, @ptrCast(va), n, offset);
    const uif = uifOf(ch);
    sync.qlock(&uif.oq);
    defer sync.qunlock(&uif.oq);
    seek(uif, offset);
    var r: w.DWORD = 0;
    if (w.ReadFile(uif.fh, va, @intCast(n), &r, null) == 0) return w.oserr();
    uif.offset += r;
    return @intCast(r);
}

fn fswrite(ch: *Chan, va: ?*const anyopaque, n: c_int, offset: i64) Error!c_int {
    if (ch.qid.type & c.QTDIR != 0) return dirread(ch, @ptrCast(@constCast(va)), n, offset);
    const uif = uifOf(ch);
    sync.qlock(&uif.oq);
    defer sync.qunlock(&uif.oq);
    seek(uif, offset);
    var r: w.DWORD = 0;
    if (w.WriteFile(uif.fh, va, @intCast(n), &r, null) == 0) return w.oserr();
    uif.offset += r;
    return @intCast(r);
}

/// path's own entry, a link itself rather than its target, opened for
/// deletion or renaming beneath the machine's directory handle
/// (h9_fs_createfile goes through src/host/dirs.c's walk), so what the
/// host deletes or renames is the file that walk found, not whatever
/// the path names by the time the host resolves it again.
fn openown(path: [*:0]const WCHAR) Error!HANDLE {
    const h = h9_fs_createfile(path, w.DELETE | w.SYNCHRONIZE | w.FILE_READ_ATTRIBUTES, w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE, null, w.OPEN_EXISTING, w.FILE_FLAG_OPEN_REPARSE_POINT | w.FILE_FLAG_BACKUP_SEMANTICS, null);
    if (h == invalid) return w.oserr();
    return h;
}

/// Removes path's own entry, a file, an empty directory, or a link,
/// through a handle (openown). With POSIX semantics the name goes at
/// once, even while the file is open, rather than when the last handle
/// closes, so a new file can take the name right away; where the file
/// system doesn't support that, the classic disposition, on the same
/// handle.
fn removeown(path: [*:0]const WCHAR) Error!void {
    const h = try openown(path);
    defer _ = w.CloseHandle(h);
    // FILE_DISPOSITION_INFO_EX: DELETE | POSIX_SEMANTICS | IGNORE_READONLY_ATTRIBUTE
    const fdx: extern struct { Flags: w.DWORD } = .{ .Flags = 0x1 | 0x2 | 0x10 };
    if (w.SetFileInformationByHandle(h, w.FileDispositionInfoEx, &fdx, @sizeOf(@TypeOf(fdx))) != 0) return;
    const err = w.GetLastError();
    // FILE_DISPOSITION_INFO's DeleteFile, for a file system without the Ex form.
    const fd: extern struct { DeleteFile: u8 } = .{ .DeleteFile = 1 };
    if (w.SetFileInformationByHandle(h, w.FileDispositionInfo, &fd, @sizeOf(@TypeOf(fd))) != 0) return;
    // The Ex form's error says more (a directory that isn't empty, say)
    // unless it was only unsupported.
    if (err != 50 and err != 87) w.SetLastError(err); // ERROR_NOT_SUPPORTED, ERROR_INVALID_PARAMETER
    return w.oserr();
}

/// Renames path's own entry to name within its directory, through a
/// handle (openown): NtSetInformationFile's FileRenameInformation with no
/// root directory and a bare name renames the file where it is, so the
/// host never resolves the new name's directory again. Not
/// SetFileInformationByHandle, which reads a bare name as relative to
/// the process's current directory and would move the file there. An
/// existing name isn't replaced, as MoveFile didn't.
fn renameown(path: [*:0]const WCHAR, name: []const WCHAR) Error!void {
    for (name) |ch| if (ch == '\\' or ch == '/' or ch == ':') return port.kerror(&port.Ebadchar);
    if (name.len == 0 or name.len > MAX_PATH) return port.kerror(&port.Ebadstat);
    const h = try openown(path);
    defer _ = w.CloseHandle(h);
    // FILE_RENAME_INFO: ReplaceIfExists (padded), RootDirectory, FileNameLength, FileName.
    const Info = extern struct { replace: w.DWORD, root: ?HANDLE, len: w.DWORD, name: [MAX_PATH + 1]WCHAR };
    var info: Info = .{ .replace = 0, .root = null, .len = @intCast(name.len * 2), .name = undefined };
    @memcpy(info.name[0..name.len], name);
    info.name[name.len] = 0;
    var iosb: w.IO_STATUS_BLOCK = undefined;
    const st = w.NtSetInformationFile(h, &iosb, &info, @intCast(@offsetOf(Info, "name") + (name.len + 1) * 2), w.FileRenameInformation);
    if (st < 0) {
        w.SetLastError(@intCast(w.RtlNtStatusToDosError(st)));
        return w.oserr();
    }
}

fn fsremove(ch: *Chan) Error!void {
    defer fsclose(ch) catch {};
    const uif = uifOf(ch);
    // A link is removed, not its target.
    try allow(ownpath(uif), Remove);
    // ownpath is the link itself for a link (lpath, or a link a Linux
    // walk stopped at), else the file.
    try removeown(ownpath(uif));
}

fn nochange(d: *const Dir) bool {
    return ~d.mode == 0 and ~d.atime == 0 and ~d.mtime == 0 and ~@as(u64, @bitCast(d.length)) == 0 and d.name[0] == 0;
}

fn fswstat(ch: *Chan, buf: [*]u8, n: c_int) Error!c_int {
    var strs: [MAX_PATH * 3]u8 = undefined;
    var d: Dir = undefined;
    if (c.convM2D(buf, @intCast(n), &d, @ptrCast(&strs)) != n) return port.kerror(&port.Ebadstat);
    const uif = uifOf(ch);
    // A wstat that changes nothing syncs the file (fsync(2) for Linux
    // programs). A directory isn't opened as a handle here (it's a
    // FindFirstFile search), and NTFS logs a rename or create in it
    // itself, so a directory has nothing to sync.
    if (nochange(&d)) {
        // Fails on a read-only handle, which has nothing to sync.
        if (uif.fh != invalid and @intFromPtr(uif.fh) != 0) _ = w.FlushFileBuffers(uif.fh);
        return n;
    }
    if (pathtype(uif.path) != .file) return port.kerror(&port.Ebadstat);
    try allow(uif.path, Write);
    // Change the length: truncate, ftruncate, and fallocate, which grows
    // a file this way. Upstream ignored it, so the call succeeded with the
    // file unchanged.
    if (~@as(u64, @bitCast(d.length)) != 0) {
        const h = h9_fs_createfile(uif.path, w.GENERIC_WRITE, w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE, null, w.OPEN_EXISTING, w.FILE_ATTRIBUTE_NORMAL, null);
        if (h == invalid) return w.oserr();
        defer _ = w.CloseHandle(h);
        try allowhandle(h, Write);
        if (w.SetFilePointerEx(h, d.length, null, w.FILE_BEGIN) == 0 or w.SetEndOfFile(h) == 0) return w.oserr();
    }
    if (~d.atime != 0 or ~d.mtime != 0) {
        var ta: w.FILETIME = undefined;
        var tm: w.FILETIME = undefined;
        var pta: ?*const w.FILETIME = null;
        var ptm: ?*const w.FILETIME = null;
        if (~d.atime != 0) {
            ta = filetime(d.atime);
            pta = &ta;
        }
        if (~d.mtime != 0) {
            tm = filetime(d.mtime);
            ptm = &tm;
        }
        const h = h9_fs_createfile(uif.path, w.FILE_WRITE_ATTRIBUTES | w.FILE_READ_ATTRIBUTES, w.FILE_SHARE_READ | w.FILE_SHARE_WRITE, null, w.OPEN_EXISTING, w.FILE_ATTRIBUTE_NORMAL, null);
        if (h != invalid) {
            defer _ = w.CloseHandle(h);
            // Check the file the handle actually opened, not the path.
            try allowhandle(h, Write);
            _ = w.SetFileTime(h, null, pta, ptm);
        }
    }
    // Change the name.
    if (d.name[0] != 0) {
        // A link is renamed, not its target. Replace the last path
        // element with d.name.
        const own = wspan(ownpath(uif));
        var l: usize = own.len;
        if (l <= 1) return port.kerror(&port.Ebadstat);
        l -= 1;
        while (l > 0) : (l -= 1) {
            if (own[l - 1] == '\\') break;
        }
        if (l == 0) return port.kerror(&port.Ebadstat);
        const base = wstrdup(own[0..l]);
        const newpath = catpath(base, d.name);
        free(base);
        errdefer free(newpath);
        if (!wcseq(ownpath(uif), newpath)) {
            try allow(newpath, Create);
            try allow(ownpath(uif), Rename);
            const np = wspan(newpath);
            const slash = std.mem.lastIndexOfScalar(WCHAR, np, '\\') orelse return port.kerror(&port.Ebadstat);
            try renameown(ownpath(uif), np[slash + 1 ..]);
        }
        if (uif.lpath) |lp| {
            free(lp);
            uif.lpath = newpath;
        } else {
            free(uif.path);
            uif.path = newpath;
        }
    }
    // Attributes aren't changed.
    ch.qid = try wfdtoqid(uif.path, null);
    return n;
}

/// base and the UTF-8 name ext, joined by a backslash.
fn catpath(base: [*:0]const WCHAR, ext: [*:0]const u8) [*:0]WCHAR {
    const b = wspan(base);
    const e = std.mem.span(ext);
    const m = e.len * 4;
    const path: [*]WCHAR = @ptrCast(@alignCast(c.smalloc(@intCast((b.len + m + 2) * 2))));
    @memcpy(path[0..b.len], b);
    var n = b.len;
    if (n > 0 and path[n - 1] != '\\') {
        path[n] = '\\';
        n += 1;
    }
    const k = w.MultiByteToWideChar(w.CP_UTF8, 0, ext, -1, path + n, @intCast(m + 1));
    path[n + (if (k > 0) @as(usize, @intCast(k)) - 1 else 0)] = 0;
    return @ptrCast(path);
}

/// base and the wide name ext, joined by a backslash.
fn catpathw(base: [*:0]const WCHAR, ext: []const WCHAR) [*:0]WCHAR {
    const b = wspan(base);
    const path: [*]WCHAR = @ptrCast(@alignCast(c.smalloc(@intCast((b.len + ext.len + 2) * 2))));
    @memcpy(path[0..b.len], b);
    var n = b.len;
    if (n > 0 and path[n - 1] != '\\') {
        path[n] = '\\';
        n += 1;
    }
    @memcpy(path[n..][0..ext.len], ext);
    path[n + ext.len] = 0;
    return @ptrCast(path);
}

fn isdots(name: []const u8) bool {
    return std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..");
}

/// The wide string s as UTF-8 in buf, NUL-terminated.
fn toutf8(s: [*:0]const WCHAR, buf: []u8) [:0]u8 {
    const k = w.WideCharToMultiByte(w.CP_UTF8, 0, s, -1, buf.ptr, @intCast(buf.len), null, null);
    if (k <= 0) {
        buf[0] = 0;
        return buf[0..0 :0];
    }
    return buf[0..@as(usize, @intCast(k)) - 1 :0];
}

fn dirread(ch: *Chan, va: [*]u8, count: c_int, offset: i64) Error!c_int {
    var i: c_int = 0;
    const uif = uifOf(ch);
    const ds = uif.dir.?;
    // Links listed as links (design/epoch-0/linux-symlinks.md).
    const lx = h9_fs_linkwalk() != 0;
    const t = pathtype(uif.path);
    if (uif.offset != offset) {
        if (offset != 0) return port.kerror("bad offset in fsdirread");
        uif.offset = offset; // sync offset
        switch (t) {
            .root => ds.drivep = ds.drivebuf.?,
            .volume, .file => {
                _ = w.FindClose(ds.handle);
                const p = catpath(uif.path, "*.*");
                ds.handle = h9_fs_findfirst(p, &ds.wfd);
                free(p);
                if (ds.handle == invalid) return w.oserr();
            },
        }
        ds.keep = true;
    }
    var debuf: [MAX_PATH * 3]u8 = undefined;
    while (i + c.BIT16SZ < count) {
        if (!ds.keep) {
            switch (t) {
                .root => {
                    ds.drivep += 4;
                    if (ds.drivep[0] == 0) break;
                },
                .volume, .file => if (w.FindNextFileW(ds.handle, &ds.wfd) == 0) break,
            }
        } else ds.keep = false;
        var de: [:0]u8 = undefined;
        if (t == .root) {
            ds.drivep[2] = 0;
            de = toutf8(@ptrCast(ds.drivep), &debuf);
        } else de = toutf8(@ptrCast(&ds.wfd.cFileName), &debuf);
        if (de.len == 0 or isdots(de)) continue;
        var d: Dir = undefined;
        // In a contained tree, an entry is listed as its walk resolves
        // it, and a link whose target is missing isn't.
        if (uif.top != null and t != .root and !lx) {
            var buf: [MAX_PATH * 4]WCHAR = undefined;
            if (h9_fs_resolveinw(uif.top.?, uif.path, de.ptr, &buf, buf.len) < 0) continue;
            const bz: [*:0]const WCHAR = @ptrCast(&buf);
            if (h9_fs_checkw(bz, Walk) < 0) continue;
            if (pathtype(bz) == .file) {
                var f: FindData = undefined;
                if (!findone(bz, &f)) continue;
                try wfdtodir(bz, &d, &f);
            } else try wfdtodir(bz, &d, null);
        } else {
            const p = if (t == .root)
                catpathw(uif.path, wspan(@ptrCast(ds.drivep)))
            else
                catpathw(uif.path, std.mem.sliceTo(&ds.wfd.cFileName, 0));
            defer free(p);
            if ((if (lx) h9_fs_checknamew(p, Walk) else h9_fs_checkw(p, Walk)) < 0) continue;
            if (t == .root) {
                try wfdtodir(p, &d, null);
            } else {
                try wfdtodir(p, &d, &ds.wfd);
                if (lx and wfdislink(&ds.wfd)) {
                    var q = d.qid;
                    q.type = fs.QTSYMLINK;
                    linkdir(p, &d, q);
                }
            }
        }
        d.name = de.ptr;
        d.type = 'U';
        d.dev = @bitCast(ch.dev);
        const n: c_int = @intCast(c.convD2M(&d, va + @as(usize, @intCast(i)), @intCast(count - i)));
        if (n == c.BIT16SZ) {
            ds.keep = true;
            break;
        }
        i += n;
    }
    uif.offset += i;
    return i;
}

/// namec's, once a walk from a #U attach is done. A contained attach's
/// tree is where the walk ended, by its final path. The list of drives
/// can't be a tree, so a contained attach left there isn't one.
pub fn anchor(ch: *Chan) Error!void {
    const uif = uifOf(ch);
    if (!uif.contained or uif.top != null) return;
    switch (pathtype(uif.path)) {
        .root => {
            uif.contained = false;
            return;
        },
        .volume => {
            uif.top = wstrdup(wspan(uif.path));
            return;
        },
        .file => {},
    }
    const h = h9_fs_createfile(uif.path, 0, w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE, null, w.OPEN_EXISTING, w.FILE_FLAG_BACKUP_SEMANTICS, null);
    if (h == invalid) return w.oserr();
    var buf: [MAX_PATH * 4]WCHAR = undefined;
    const n = w.GetFinalPathNameByHandleW(h, &buf, buf.len, w.FILE_NAME_NORMALIZED | w.VOLUME_NAME_DOS);
    _ = w.CloseHandle(h);
    // Only drive paths, \\?\C:\..., are allowed; not UNC or devices.
    if (n == 0 or n >= buf.len or !std.mem.eql(WCHAR, buf[0..4], &.{ '\\', '\\', '?', '\\' }) or buf[5] != ':')
        return port.kerror(&port.Enonexist);
    var p = buf[4..n];
    if (p.len > 2 and p[p.len - 1] == '\\') p = p[0 .. p.len - 1];
    uif.top = wstrdup(p);
    setpath(uif, wstrdup(p), null);
}

/// Symbolic links aren't made on Windows hosts.
///
/// This is load-bearing for the sandbox. fscreate, fsremove, and the
/// wstat rename path still check a path string and then let the host
/// re-resolve it (CreateFile, DeleteFile, MoveFile), which is the same
/// check-then-act shape the POSIX backend had to close. It is safe here
/// only because the guest has no way to win that race: it can't plant a
/// reparse point (no symlink or junction creation anywhere in this
/// driver) and can't move a file across directories into an in-policy
/// name (rename is EXDEV), so it can never make the check and the
/// operation resolve to different files. fsopen and the wstat time-set
/// don't rely on that: they open first and check the handle
/// (allowhandle).
///
/// If link or junction creation is ever added here, the create, remove,
/// and rename paths must move to handle-bound checks first (open then
/// check, and a handle-relative create via the NT RootDirectory, as
/// devfs_posix.zig does with openat, unlinkat, and renameat), or this
/// race reopens.
fn fssymlink(_: *Chan, _: [*:0]const u8, _: [*:0]const u8) Error!void {
    return port.kerror(&port.Eperm);
}

/// syncfs(2) on ch syncs its own file, as fsync does. Directories, and
/// sync(2)'s every volume, need a volume handle, which needs an
/// administrator, so they have nothing to sync here.
pub fn syncfs(ch: *Chan) Error!void {
    if (dev.of(ch).dc != 'U' or ch.flag & c.COPEN == 0) return;
    const uif = uifOf(ch);
    if (uif.fh != invalid and @intFromPtr(uif.fh) != 0) _ = w.FlushFileBuffers(uif.fh);
}

pub fn syncall() Error!void {}

/// renameat across directories stays EXDEV here for now.
fn fsrename(_: *Chan, _: *Chan, _: [*:0]const u8) Error!bool {
    return false;
}

/// Windows has no FIFOs (design/epoch-0/linux-fifo.md).
pub fn mkfifo(_: *Chan, _: [*:0]const u8, _: c_uint) Error!void {
    return port.kerror(&port.Eperm);
}

pub fn isfifoChan(_: *Chan) bool {
    return false;
}

/// The target of the link ch's last name was, as it's written.
fn fsreadlink(ch: *Chan, buf: []u8) Error!?usize {
    if (buf.len == 0) return null;
    const uif = uifOf(ch);
    const own = ownpath(uif);
    if (pathtype(own) != .file or h9_fs_checknamew(own, Walk) < 0) return null;
    const n = h9_fs_readlinkw(own, buf.ptr, @intCast(@min(buf.len, std.math.maxInt(c_int))));
    if (n < 0) return null;
    return @intCast(n);
}

fn fsaccess(m: c_int) Error!u32 {
    return switch (m & 3) {
        c.OREAD => w.GENERIC_READ,
        c.OWRITE => w.GENERIC_WRITE,
        c.ORDWR => w.GENERIC_READ | w.GENERIC_WRITE,
        else => port.kerror(&port.Eperm),
    };
}

/// Links aren't made here (see fssymlink), so a Linux link is the
/// switch's default, a copy, and its attributes are built from stat.
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
    .rename = fsrename,
});
