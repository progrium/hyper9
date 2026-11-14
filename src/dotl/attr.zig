//! Plan 9 errors and Dirs in Linux's terms, both ways: errno numbers from
//! error strings and back, `stat`, `statx` and `d_type` from a `Dir`, a
//! `Dir` from .L's `stat`, open modes, and users by name and number.
//! Shared by the Linux personality (design/linux-personality.md,
//! "Users and stat") and 9P2000.L (design/dotl.md), which names this
//! file. The two share the mappings and `/etc/passwd` parsing here, not
//! the policy: each decides which user is which number.

const std = @import("std");
const wire = @import("wire.zig");

pub const E = struct {
    pub const PERM = 1;
    pub const NOENT = 2;
    pub const SRCH = 3;
    pub const INTR = 4;
    pub const IO = 5;
    pub const NXIO = 6;
    pub const @"2BIG" = 7;
    pub const NOEXEC = 8;
    pub const BADF = 9;
    pub const CHILD = 10;
    pub const AGAIN = 11;
    pub const NOMEM = 12;
    pub const ACCES = 13;
    pub const FAULT = 14;
    pub const BUSY = 16;
    pub const EXIST = 17;
    pub const XDEV = 18;
    pub const NODEV = 19;
    pub const NOTDIR = 20;
    pub const ISDIR = 21;
    pub const INVAL = 22;
    pub const NFILE = 23;
    pub const MFILE = 24;
    pub const NOTTY = 25;
    pub const TXTBSY = 26;
    pub const FBIG = 27;
    pub const NOSPC = 28;
    pub const SPIPE = 29;
    pub const ROFS = 30;
    pub const MLINK = 31;
    pub const PIPE = 32;
    pub const RANGE = 34;
    pub const DEADLK = 35;
    pub const NAMETOOLONG = 36;
    pub const NOLCK = 37;
    pub const IDRM = 43;
    pub const NOSYS = 38;
    pub const NOTEMPTY = 39;
    pub const LOOP = 40;
    pub const NODATA = 61;
    pub const TIME = 62;
    pub const OVERFLOW = 75;
    pub const NOTSOCK = 88;
    pub const OPNOTSUPP = 95;
    pub const NOTSUP = 95;
    pub const AFNOSUPPORT = 97;
    pub const ADDRINUSE = 98;
    pub const CONNRESET = 104;
    pub const NOTCONN = 107;
    pub const TIMEDOUT = 110;
    pub const CONNREFUSED = 111;
    pub const HOSTUNREACH = 113;
    pub const DESTADDRREQ = 89;
    pub const MSGSIZE = 90;
    pub const PROTOTYPE = 91;
    pub const NOPROTOOPT = 92;
    pub const PROTONOSUPPORT = 93;
    pub const ADDRNOTAVAIL = 99;
    pub const NETUNREACH = 101;
    pub const CONNABORTED = 103;
    pub const ISCONN = 106;
    pub const ALREADY = 114;
    pub const INPROGRESS = 115;
    pub const STALE = 116;
    pub const DQUOT = 122;
};

/// The Plan 9 error string for an errno, what a .L server's Rlerror becomes
/// (design/dotl.md, "Errors"). `errno` maps each back to the same
/// number; one with no string here is "errno N", which `errno` reads too.
pub fn errstr(e: u32, buf: *[16]u8) []const u8 {
    const table = [_]struct { u16, []const u8 }{
        .{ E.PERM, "operation not permitted" },
        .{ E.NOENT, "file does not exist" },
        .{ E.SRCH, "no such process" },
        .{ E.INTR, "interrupted" },
        .{ E.IO, "i/o error" },
        .{ E.NOEXEC, "exec format error" },
        .{ E.BADF, "bad file descriptor" },
        .{ E.CHILD, "no living children" },
        .{ E.AGAIN, "resource temporarily unavailable" },
        .{ E.NOMEM, "out of memory" },
        .{ E.ACCES, "permission denied" },
        .{ E.BUSY, "device or object already in use" },
        .{ E.EXIST, "file already exists" },
        .{ E.XDEV, "cross-device link" },
        .{ E.NODEV, "no such device" },
        .{ E.NOTDIR, "not a directory" },
        .{ E.ISDIR, "file is a directory" },
        .{ E.INVAL, "invalid argument" },
        .{ E.MFILE, "too many open files" },
        .{ E.TXTBSY, "text file busy" },
        .{ E.FBIG, "file too large" },
        .{ E.NOSPC, "file system full" },
        .{ E.SPIPE, "illegal seek" },
        .{ E.ROFS, "read-only file system" },
        .{ E.MLINK, "too many links" },
        .{ E.PIPE, "broken pipe" },
        .{ E.NAMETOOLONG, "name too long" },
        .{ E.NOSYS, "function not implemented" },
        .{ E.NOTEMPTY, "directory not empty" },
        .{ E.LOOP, "too many symbolic links" },
        .{ E.OVERFLOW, "value too large" },
        .{ E.OPNOTSUPP, "operation not supported" },
        .{ E.CONNRESET, "connection reset" },
        .{ E.NOTCONN, "not connected" },
        .{ E.TIMEDOUT, "connection timed out" },
        .{ E.CONNREFUSED, "connection refused" },
        .{ E.STALE, "stale file handle" },
        .{ E.DQUOT, "disk quota exceeded" },
    };
    for (table) |t| if (t[0] == e) return t[1];
    return std.fmt.bufPrint(buf, "errno {d}", .{e}) catch unreachable;
}

/// The errno for a Plan 9 error string (drawterm's error.h, h9's own
/// devices and the host's strerror through devfs). Unknown strings are EIO.
pub fn errno(msg: []const u8) u16 {
    const table = [_]struct { []const u8, u16 }{
        // Exact kernel strings first, then substrings that servers and
        // the host's strerror use.
        .{ "interrupted", E.INTR },
        .{ "file does not exist", E.NOENT },
        .{ "does not exist", E.NOENT },
        .{ "no such file", E.NOENT },
        .{ "not found", E.NOENT },
        .{ "permission denied", E.ACCES },
        .{ "operation not permitted", E.PERM },
        .{ "file already exists", E.EXIST },
        .{ "file exists", E.EXIST },
        .{ "already exists", E.EXIST },
        .{ "not a directory", E.NOTDIR },
        .{ "is a directory", E.ISDIR },
        .{ "directory not empty", E.NOTEMPTY },
        .{ "not empty", E.NOTEMPTY },
        .{ "write on closed pipe", E.PIPE },
        .{ "broken pipe", E.PIPE },
        .{ "fd out of range or not open", E.BADF },
        .{ "bad file descriptor", E.BADF },
        .{ "no free file descriptors", E.MFILE },
        .{ "too many open files", E.MFILE },
        .{ "no living children", E.CHILD },
        .{ "bad arg in system call", E.INVAL },
        .{ "invalid argument", E.INVAL },
        .{ "name too long", E.NAMETOOLONG },
        .{ "too many symbolic links", E.LOOP },
        .{ "too many levels of symbolic links", E.LOOP },
        .{ "file system full", E.NOSPC },
        .{ "no space left", E.NOSPC },
        .{ "read-only file system", E.ROFS },
        // exportfs -R's "file system read only".
        .{ "read only", E.ROFS },
        .{ "virtual memory allocation failed", E.NOMEM },
        .{ "kernel allocate failed", E.NOMEM },
        .{ "no memory", E.NOMEM },
        .{ "out of memory", E.NOMEM },
        .{ "exec header invalid", E.NOEXEC },
        .{ "exec format error", E.NOEXEC },
        .{ "inappropriate use of fd", E.BADF },
        .{ "seek on a stream", E.SPIPE },
        .{ "illegal seek", E.SPIPE },
        .{ "seek in directory", E.INVAL },
        .{ "negative i/o offset", E.INVAL },
        .{ "connection refused", E.CONNREFUSED },
        .{ "connection timed out", E.TIMEDOUT },
        .{ "connection reset", E.CONNRESET },
        .{ "address already in use", E.ADDRINUSE },
        .{ "address in use", E.ADDRINUSE },
        .{ "network is unreachable", E.NETUNREACH },
        .{ "no route to host", E.HOSTUNREACH },
        .{ "cannot assign requested address", E.ADDRNOTAVAIL },
        .{ "can't assign requested address", E.ADDRNOTAVAIL },
        .{ "not connected", E.NOTCONN },
        .{ "connection aborted", E.CONNABORTED },
        .{ "i/o on hungup channel", E.PIPE },
        .{ "device or object already in use", E.BUSY },
        .{ "mounted directory forbids creation", E.ACCES },
        .{ "is a mount point", E.BUSY },
        .{ "bad character in file name", E.INVAL },
        .{ "file name syntax", E.INVAL },
        .{ "unknown device in # filename", E.NOENT },
        .{ "cross-device link", E.XDEV },
        .{ "text file busy", E.TXTBSY },
        .{ "process exited", E.SRCH },
        .{ "no such process", E.SRCH },
        .{ "would block", E.AGAIN },
        .{ "resource temporarily unavailable", E.AGAIN },
        .{ "operation not supported", E.OPNOTSUPP },
        .{ "function not implemented", E.NOSYS },
        .{ "file too large", E.FBIG },
        .{ "no such device", E.NODEV },
        .{ "too many links", E.MLINK },
        .{ "value too large", E.OVERFLOW },
        .{ "stale file handle", E.STALE },
        .{ "disk quota exceeded", E.DQUOT },
    };
    // What errstr makes of an errno it has no string for.
    if (std.mem.startsWith(u8, msg, "errno ")) {
        if (std.fmt.parseInt(u16, msg["errno ".len..], 10)) |e| return e else |_| {}
    }
    var lower: [128]u8 = undefined;
    const l = unquoted(msg, &lower);
    for (table) |e| if (std.mem.indexOf(u8, l, e[0]) != null) return e[1];
    return E.IO;
}

/// `msg` lowercased into `buf`, without the names it quotes, so only the
/// error proper picks the errno. The kernel's walk errors quote the path
/// with %#q ("file does not exist: '/nix/store/…-interrupted.nix'"), and
/// a file name like that one once turned ENOENT into EINTR, so Nix
/// retried the open millions of times. %q doubles a quote inside a name,
/// and a quote after a letter or digit is an apostrophe ("can't assign
/// requested address"), not an opening quote.
fn unquoted(msg: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < msg.len and n < buf.len) {
        const c = msg[i];
        if (c == '\'' and (i == 0 or !std.ascii.isAlphanumeric(msg[i - 1]))) {
            i += 1;
            while (i < msg.len) {
                if (msg[i] == '\'') {
                    if (i + 1 < msg.len and msg[i + 1] == '\'') {
                        i += 2;
                        continue;
                    }
                    i += 1;
                    break;
                }
                i += 1;
            }
            continue;
        }
        buf[n] = std.ascii.toLower(c);
        n += 1;
        i += 1;
    }
    return buf[0..n];
}

// Linux st_mode bits.
pub const S_IFMT = 0o170000;
pub const S_IFSOCK = 0o140000;
pub const S_IFLNK = 0o120000;
pub const S_IFREG = 0o100000;
pub const S_IFBLK = 0o060000;
pub const S_IFDIR = 0o040000;
pub const S_IFCHR = 0o020000;
pub const S_IFIFO = 0o010000;

// dirent d_type.
pub const DT_FIFO = 1;
pub const DT_CHR = 2;
pub const DT_DIR = 4;
pub const DT_REG = 8;
pub const DT_LNK = 10;
pub const DT_SOCK = 12;

const DMDIR: u32 = 0x80000000;

/// A Plan 9 Dir, parsed (names point into the message).
pub const Dir = struct {
    type: u16,
    dev: u32,
    qid_type: u8,
    qid_vers: u32,
    qid_path: u64,
    mode: u32,
    atime: u32,
    mtime: u32,
    length: u64,
    name: []const u8,
    uid: []const u8,
    gid: []const u8,
    muid: []const u8 = "",

    /// Parses one Dir from the start of `b`; returns it and its size.
    pub fn parse(b: []const u8) ?struct { Dir, usize } {
        if (b.len < 2) return null;
        const size = @as(usize, std.mem.readInt(u16, b[0..2], .little)) + 2;
        if (size > b.len or size < 41 + 8) return null;
        var d: Dir = undefined;
        d.type = std.mem.readInt(u16, b[2..4], .little);
        d.dev = std.mem.readInt(u32, b[4..8], .little);
        d.qid_type = b[8];
        d.qid_vers = std.mem.readInt(u32, b[9..13], .little);
        d.qid_path = std.mem.readInt(u64, b[13..21], .little);
        d.mode = std.mem.readInt(u32, b[21..25], .little);
        d.atime = std.mem.readInt(u32, b[25..29], .little);
        d.mtime = std.mem.readInt(u32, b[29..33], .little);
        d.length = std.mem.readInt(u64, b[33..41], .little);
        var at: usize = 41;
        const strs = [_]*[]const u8{ &d.name, &d.uid, &d.gid };
        for (strs) |s| {
            if (at + 2 > size) return null;
            const l = std.mem.readInt(u16, b[at..][0..2], .little);
            at += 2;
            if (at + l > size) return null;
            s.* = b[at..][0..l];
            at += l;
        }
        d.muid = "";
        if (at + 2 <= size) {
            const l = std.mem.readInt(u16, b[at..][0..2], .little);
            if (at + 2 + l <= size) d.muid = b[at + 2 ..][0..l];
        }
        return .{ d, size };
    }

    /// Packs the Dir as stat(5) lays it out, with its size prefix, at the
    /// start of `out`, returning the bytes.
    pub fn pack(d: *const Dir, out: []u8) wire.Error![]u8 {
        var w: wire.Writer = .{ .b = out, .at = 2 };
        if (out.len < 2) return error.NoSpace;
        try w.int(u16, d.type);
        try w.int(u32, d.dev);
        try w.qid(.{ .type = d.qid_type, .vers = d.qid_vers, .path = d.qid_path });
        try w.int(u32, d.mode);
        try w.int(u32, d.atime);
        try w.int(u32, d.mtime);
        try w.int(u64, d.length);
        for ([_][]const u8{ d.name, d.uid, d.gid, d.muid }) |str| try w.str(str);
        if (w.at - 2 > std.math.maxInt(u16)) return error.NoSpace;
        std.mem.writeInt(u16, out[0..2], @intCast(w.at - 2), .little);
        return out[0..w.at];
    }

    /// A Dir whose every field is wstat(5)'s "don't touch".
    pub const keep: Dir = .{
        .type = 0xffff,
        .dev = 0xffffffff,
        .qid_type = 0xff,
        .qid_vers = 0xffffffff,
        .qid_path = 0xffffffffffffffff,
        .mode = 0xffffffff,
        .atime = 0xffffffff,
        .mtime = 0xffffffff,
        .length = 0xffffffffffffffff,
        .name = "",
        .uid = "",
        .gid = "",
        .muid = "",
    };

    /// Whether a wstat of this Dir changes nothing, which stat(5) makes a
    /// request to commit the file to stable storage.
    pub fn isNull(d: *const Dir) bool {
        return d.mode == keep.mode and d.atime == keep.atime and d.mtime == keep.mtime and
            d.length == keep.length and d.name.len == 0 and d.uid.len == 0 and d.gid.len == 0;
    }
};

/// Whether a .L file of this mode can be opened through 9P2000: a regular
/// file or a directory. Device nodes, FIFOs, and sockets show as empty
/// files that fail to open with "not a regular file".
pub fn openable(mode: u32) bool {
    return mode & S_IFMT == S_IFREG or mode & S_IFMT == S_IFDIR;
}

fn sec32(s: u64) u32 {
    return @intCast(@min(s, std.math.maxInt(u32)));
}

/// The Dir 9P2000 shows for a .L file (design/dotl.md, "`Dir` from a
/// Linux `stat`"): its permission bits with DMDIR for a directory, its
/// size, and its times in seconds. `uid` and `gid` are the names the user
/// map gives its numbers; `muid` is the uid. The qid's type is derived
/// from the mode, since a Plan 9 client reads QTDIR to mean DMDIR and has
/// no use for .L's QTSYMLINK.
pub fn dirFromStat(st: *const wire.Stat, name: []const u8, uid: []const u8, gid: []const u8) Dir {
    const dir = st.mode & S_IFMT == S_IFDIR;
    return .{
        .type = 0,
        .dev = 0,
        .qid_type = if (dir) wire.QTDIR else wire.QTFILE,
        .qid_vers = st.qid.vers,
        .qid_path = st.qid.path,
        .mode = (st.mode & 0o777) | if (dir) DMDIR else 0,
        .atime = sec32(st.atime_sec),
        .mtime = sec32(st.mtime_sec),
        .length = if (st.mode & S_IFMT == S_IFREG) st.size else 0,
        .name = name,
        .uid = uid,
        .gid = gid,
        .muid = uid,
    };
}

/// The .L `stat` a Linux client sees for a Dir from exportfs, the server
/// side's Rgetattr. Every file is a directory or regular file, since
/// that's all 9P2000 shows; ctime is the mtime and btime is unknown.
pub fn statFromDir(d: *const Dir, uid: u32, gid: u32) wire.Stat {
    const s = Stat.fromDir(d, .auto, uid, gid);
    return .{
        .qid = .{ .type = d.qid_type, .vers = d.qid_vers, .path = d.qid_path },
        .mode = s.mode,
        .uid = uid,
        .gid = gid,
        .nlink = s.nlink,
        .size = s.size,
        .blksize = s.blksize,
        .blocks = s.blocks(),
        .atime_sec = d.atime,
        .mtime_sec = d.mtime,
        .ctime_sec = d.mtime,
    };
}

/// A 9P2000 open mode as .L open flags. OEXEC opens for reading, and
/// ORCLOSE is the translator's to keep, not the server's.
pub fn openFlags(mode: u8) u32 {
    const L = wire.L;
    var f: u32 = switch (mode & 3) {
        wire.OREAD, wire.OEXEC => L.RDONLY,
        wire.OWRITE => L.WRONLY,
        else => L.RDWR,
    };
    if (mode & wire.OTRUNC != 0) f |= L.TRUNC;
    return f;
}

/// .L open flags as a 9P2000 open mode, for the server side. Flags 9P2000
/// has no word for (O_APPEND, O_NOFOLLOW, ...) are dropped.
pub fn openMode(flags: u32) u8 {
    const L = wire.L;
    var m: u8 = switch (flags & L.ACCMODE) {
        L.WRONLY => wire.OWRITE,
        L.RDWR => wire.ORDWR,
        else => wire.OREAD,
    };
    if (flags & L.TRUNC != 0) m |= wire.OTRUNC;
    return m;
}

/// A 9P2000 create's permissions as a .L mode: the permission bits only.
/// DMDIR is a Tmkdir rather than a mode bit, and DMAPPEND, DMEXCL, and
/// DMTMP have no .L equivalent.
pub fn createMode(perm: u32) u32 {
    return perm & 0o777;
}

/// A create's mode under directory mode `dir`, by create(5)'s rule: a
/// file's permissions are `perm & (~0666 | (dir & 0666))`, and a
/// directory's `perm & (~0777 | (dir & 0777))`. A Plan 9 file server
/// applies it, and a .L server doesn't, so the translator does.
pub fn createModeIn(perm: u32, dir: u32) u32 {
    const bits: u32 = if (perm & DMDIR != 0) 0o777 else 0o666;
    return createMode(perm & (~bits | (dir & bits)));
}

test "creates take the directory's permissions, as create(5) says" {
    try std.testing.expectEqual(@as(u32, 0o644), createModeIn(0o666, 0o755));
    try std.testing.expectEqual(@as(u32, 0o755), createModeIn(DMDIR | 0o777, 0o755));
    try std.testing.expectEqual(@as(u32, 0o640), createModeIn(0o640, 0o777));
    // Execute bits on a file are the creator's own.
    try std.testing.expectEqual(@as(u32, 0o755), createModeIn(0o777, 0o755));
}

/// What a 9P2000 wstat asks of a .L server: a rename, then a Tsetattr
/// (design/dotl.md, "Twstat"). `valid` is 0 when nothing but the name
/// changes; `sync` is set for the null wstat, which becomes a Tfsync.
pub const Wstat = struct {
    rename: ?[]const u8 = null,
    setattr: SetAttr = .{},
    sync: bool = false,

    pub const SetAttr = struct {
        valid: u32 = 0,
        mode: u32 = 0,
        size: u64 = 0,
        mtime_sec: u64 = 0,
    };
};

pub fn wstat(d: *const Dir) Wstat {
    if (d.isNull()) return .{ .sync = true };
    const L = wire.L;
    var w: Wstat = .{};
    if (d.name.len != 0) w.rename = d.name;
    if (d.mode != Dir.keep.mode) {
        w.setattr.valid |= L.SETATTR_MODE;
        w.setattr.mode = d.mode & 0o777;
    }
    if (d.length != Dir.keep.length) {
        w.setattr.valid |= L.SETATTR_SIZE;
        w.setattr.size = d.length;
    }
    if (d.mtime != Dir.keep.mtime) {
        w.setattr.valid |= L.SETATTR_MTIME | L.SETATTR_MTIME_SET;
        w.setattr.mtime_sec = d.mtime;
    }
    return w;
}

/// The wstat Dir for a .L client's Tsetattr, for the server side: the
/// fields it sets, and "don't touch" for the rest. Owner and group changes
/// aren't carried, since every client acts as the machine's user; atime
/// can't be set through 9P2000 either. `now` is used for a time set to the
/// server's clock (SETATTR_MTIME without SETATTR_MTIME_SET).
pub fn wstatFromSetattr(valid: u32, mode: u32, size: u64, mtime_sec: u64, now: u32) Dir {
    const L = wire.L;
    var d = Dir.keep;
    if (valid & L.SETATTR_MODE != 0) d.mode = mode & 0o777;
    if (valid & L.SETATTR_SIZE != 0) d.length = size;
    if (valid & L.SETATTR_MTIME != 0)
        d.mtime = if (valid & L.SETATTR_MTIME_SET != 0) sec32(mtime_sec) else now;
    return d;
}

/// One line of an `/etc/passwd`-format file.
pub const PasswdEntry = struct {
    name: []const u8,
    uid: u32,
    gid: u32,
};

/// Iterates the entries of an `/etc/passwd`-format file, skipping blank,
/// comment, and malformed lines.
pub const Passwd = struct {
    lines: std.mem.SplitIterator(u8, .scalar),

    pub fn init(text: []const u8) Passwd {
        return .{ .lines = std.mem.splitScalar(u8, text, '\n') };
    }

    pub fn next(p: *Passwd) ?PasswdEntry {
        while (p.lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0 or line[0] == '#') continue;
            var f = std.mem.splitScalar(u8, line, ':');
            const name = f.next() orelse continue;
            _ = f.next() orelse continue;
            const uid = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
            const gid = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
            if (name.len == 0) continue;
            return .{ .name = name, .uid = uid, .gid = gid };
        }
        return null;
    }

    pub fn byName(text: []const u8, name: []const u8) ?PasswdEntry {
        var p = init(text);
        while (p.next()) |e| if (std.mem.eql(u8, e.name, name)) return e;
        return null;
    }

    pub fn byUid(text: []const u8, uid: u32) ?PasswdEntry {
        var p = init(text);
        while (p.next()) |e| if (e.uid == uid) return e;
        return null;
    }
};

/// dotl's user map (design/dotl.md, "The user map"): .L carries
/// numbers and 9P2000 names. `--user-map` gives a passwd file; without
/// one the machine's user is `uid` (the host's uid) and any other number N
/// is the name "N". 0 is sent only for a name the map gives uid 0.
pub const UserMap = struct {
    /// The `--user-map` file's contents, if one was given.
    passwd: ?[]const u8 = null,
    /// The machine's user.
    user: []const u8,
    /// What the machine's user is on the wire without a map entry.
    uid: u32,

    /// The default `uid` for a host uid (`getuid()`, or null on Windows,
    /// which has none). A host root is sent as nobody, so that running h9
    /// as root doesn't claim root on a server without `--user-map` saying
    /// so (design/dotl.md, Security).
    pub fn hostUid(host: ?u32) u32 {
        const h = host orelse return 1000;
        return if (h == 0) nobody else h;
    }

    pub const nobody: u32 = 65534;

    /// The number to send for a user name.
    pub fn number(m: *const UserMap, user: []const u8) u32 {
        if (m.passwd) |text| {
            if (Passwd.byName(text, user)) |e| return e.uid;
        }
        if (std.mem.eql(u8, user, m.user)) return m.uid;
        if (std.fmt.parseInt(u32, user, 10)) |n| {
            if (n != 0) return n;
        } else |_| {}
        return m.uid;
    }

    /// The name to show for a number from the server.
    pub fn name(m: *const UserMap, uid: u32, buf: *[10]u8) []const u8 {
        if (m.passwd) |text| {
            if (Passwd.byUid(text, uid)) |e| return e.name;
        }
        if (uid == m.uid) return m.user;
        return std.fmt.bufPrint(buf, "{d}", .{uid}) catch unreachable;
    }
};

/// What kind of file a Dir is in Linux's terms: decided by the caller
/// from the device (a pipe, the console) where Plan 9 has no file types.
pub const Kind = enum { auto, chr, fifo, link, sock };

pub fn linuxMode(d: *const Dir, kind: Kind) u32 {
    const perm = d.mode & 0o777;
    if (d.mode & DMDIR != 0) return S_IFDIR | perm;
    return perm | @as(u32, switch (kind) {
        .auto => S_IFREG,
        .chr => S_IFCHR,
        .fifo => S_IFIFO,
        .link => S_IFLNK,
        .sock => S_IFSOCK,
    });
}

pub fn dtype(d: *const Dir, kind: Kind) u8 {
    if (d.mode & DMDIR != 0) return DT_DIR;
    return switch (kind) {
        .auto => DT_REG,
        .chr => DT_CHR,
        .fifo => DT_FIFO,
        .link => DT_LNK,
        .sock => DT_SOCK,
    };
}

/// st_dev from the device type and number.
pub fn devNumber(d: *const Dir) u64 {
    return (@as(u64, d.type) << 16) | (d.dev & 0xffff);
}

/// The fields Linux's stat calls report, before layout.
pub const Stat = struct {
    dev: u64,
    ino: u64,
    mode: u32,
    nlink: u32,
    uid: u32,
    gid: u32,
    rdev: u64 = 0,
    size: u64,
    blksize: u32 = 4096,
    atime: u32,
    mtime: u32,

    pub fn fromDir(d: *const Dir, kind: Kind, uid: u32, gid: u32) Stat {
        const mode = linuxMode(d, kind);
        return .{
            .dev = devNumber(d),
            .ino = d.qid_path,
            .mode = mode,
            .nlink = if (d.mode & DMDIR != 0) 2 else 1,
            .uid = uid,
            .gid = gid,
            .rdev = if (kind == .chr) devNumber(d) else 0,
            .size = if (kind == .chr or kind == .fifo) 0 else d.length,
            .atime = d.atime,
            .mtime = d.mtime,
        };
    }

    fn blocks(s: *const Stat) u64 {
        return (s.size + 511) / 512;
    }

    /// The generic `struct stat` (arm64), 128 bytes.
    pub fn generic(s: *const Stat) [128]u8 {
        var b: [128]u8 = @splat(0);
        std.mem.writeInt(u64, b[0..8], s.dev, .little);
        std.mem.writeInt(u64, b[8..16], s.ino, .little);
        std.mem.writeInt(u32, b[16..20], s.mode, .little);
        std.mem.writeInt(u32, b[20..24], s.nlink, .little);
        std.mem.writeInt(u32, b[24..28], s.uid, .little);
        std.mem.writeInt(u32, b[28..32], s.gid, .little);
        std.mem.writeInt(u64, b[32..40], s.rdev, .little);
        std.mem.writeInt(u64, b[48..56], s.size, .little);
        std.mem.writeInt(u32, b[56..60], s.blksize, .little);
        std.mem.writeInt(u64, b[64..72], s.blocks(), .little);
        std.mem.writeInt(u64, b[72..80], s.atime, .little);
        std.mem.writeInt(u64, b[88..96], s.mtime, .little);
        std.mem.writeInt(u64, b[104..112], s.mtime, .little);
        return b;
    }

    /// amd64's `struct stat`, 144 bytes.
    pub fn x86(s: *const Stat) [144]u8 {
        var b: [144]u8 = @splat(0);
        std.mem.writeInt(u64, b[0..8], s.dev, .little);
        std.mem.writeInt(u64, b[8..16], s.ino, .little);
        std.mem.writeInt(u64, b[16..24], s.nlink, .little);
        std.mem.writeInt(u32, b[24..28], s.mode, .little);
        std.mem.writeInt(u32, b[28..32], s.uid, .little);
        std.mem.writeInt(u32, b[32..36], s.gid, .little);
        std.mem.writeInt(u64, b[40..48], s.rdev, .little);
        std.mem.writeInt(u64, b[48..56], s.size, .little);
        std.mem.writeInt(u64, b[56..64], s.blksize, .little);
        std.mem.writeInt(u64, b[64..72], s.blocks(), .little);
        std.mem.writeInt(u64, b[72..80], s.atime, .little);
        std.mem.writeInt(u64, b[88..96], s.mtime, .little);
        std.mem.writeInt(u64, b[104..112], s.mtime, .little);
        return b;
    }

    /// i386's `struct stat64`, 96 bytes: 64-bit dev, ino, rdev, size and
    /// blocks at 4-byte alignment, with the old 32-bit inode at 12.
    pub fn i386Stat64(s: *const Stat) [96]u8 {
        var b: [96]u8 = @splat(0);
        std.mem.writeInt(u64, b[0..8], s.dev, .little);
        std.mem.writeInt(u32, b[12..16], @truncate(s.ino), .little);
        std.mem.writeInt(u32, b[16..20], s.mode, .little);
        std.mem.writeInt(u32, b[20..24], s.nlink, .little);
        std.mem.writeInt(u32, b[24..28], s.uid, .little);
        std.mem.writeInt(u32, b[28..32], s.gid, .little);
        std.mem.writeInt(u64, b[32..40], s.rdev, .little);
        std.mem.writeInt(u64, b[44..52], s.size, .little);
        std.mem.writeInt(u32, b[52..56], s.blksize, .little);
        std.mem.writeInt(u64, b[56..64], s.blocks(), .little);
        std.mem.writeInt(u32, b[64..68], s.atime, .little);
        std.mem.writeInt(u32, b[72..76], s.mtime, .little);
        std.mem.writeInt(u32, b[80..84], s.mtime, .little);
        std.mem.writeInt(u64, b[88..96], s.ino, .little);
        return b;
    }

    /// i386's old `struct stat`, 64 bytes, every field 32 bits but the
    /// mode, link count and ids, which are 16; wider values are truncated.
    pub fn i386Old(s: *const Stat) [64]u8 {
        var b: [64]u8 = @splat(0);
        std.mem.writeInt(u32, b[0..4], @truncate(s.dev), .little);
        std.mem.writeInt(u32, b[4..8], @truncate(s.ino), .little);
        std.mem.writeInt(u16, b[8..10], @truncate(s.mode), .little);
        std.mem.writeInt(u16, b[10..12], @truncate(s.nlink), .little);
        std.mem.writeInt(u16, b[12..14], @truncate(s.uid), .little);
        std.mem.writeInt(u16, b[14..16], @truncate(s.gid), .little);
        std.mem.writeInt(u32, b[16..20], @truncate(s.rdev), .little);
        std.mem.writeInt(u32, b[20..24], @truncate(s.size), .little);
        std.mem.writeInt(u32, b[24..28], s.blksize, .little);
        std.mem.writeInt(u32, b[28..32], @truncate(s.blocks()), .little);
        std.mem.writeInt(u32, b[32..36], s.atime, .little);
        std.mem.writeInt(u32, b[40..44], s.mtime, .little);
        std.mem.writeInt(u32, b[48..52], s.mtime, .little);
        return b;
    }

    /// `struct statx`, 256 bytes, with the basic fields.
    pub fn statx(s: *const Stat) [256]u8 {
        var b: [256]u8 = @splat(0);
        const STATX_BASIC_STATS = 0x7ff;
        std.mem.writeInt(u32, b[0..4], STATX_BASIC_STATS, .little);
        std.mem.writeInt(u32, b[4..8], s.blksize, .little);
        std.mem.writeInt(u32, b[16..20], s.nlink, .little);
        std.mem.writeInt(u32, b[20..24], s.uid, .little);
        std.mem.writeInt(u32, b[24..28], s.gid, .little);
        std.mem.writeInt(u16, b[28..30], @truncate(s.mode), .little);
        std.mem.writeInt(u64, b[32..40], s.ino, .little);
        std.mem.writeInt(u64, b[40..48], s.size, .little);
        std.mem.writeInt(u64, b[48..56], s.blocks(), .little);
        // atime at 64, btime 80, ctime 96, mtime 112: {i64 sec, u32 nsec, i32}.
        std.mem.writeInt(i64, b[64..72], s.atime, .little);
        std.mem.writeInt(i64, b[96..104], s.mtime, .little);
        std.mem.writeInt(i64, b[112..120], s.mtime, .little);
        std.mem.writeInt(u32, b[128..132], @truncate(s.rdev >> 8), .little);
        std.mem.writeInt(u32, b[132..136], @truncate(s.rdev & 0xff), .little);
        std.mem.writeInt(u32, b[136..140], @truncate(s.dev >> 8), .little);
        std.mem.writeInt(u32, b[140..144], @truncate(s.dev & 0xff), .little);
        return b;
    }
};

test "errno from strings" {
    try std.testing.expectEqual(@as(u16, E.NOENT), errno("file does not exist"));
    try std.testing.expectEqual(@as(u16, E.NOENT), errno("'/x' file does not exist"));
    try std.testing.expectEqual(@as(u16, E.NOENT), errno("No such file or directory"));
    try std.testing.expectEqual(@as(u16, E.ACCES), errno("permission denied"));
    try std.testing.expectEqual(@as(u16, E.INTR), errno("interrupted"));
    try std.testing.expectEqual(@as(u16, E.EXIST), errno("file already exists"));
    try std.testing.expectEqual(@as(u16, E.NOTDIR), errno("not a directory"));
    try std.testing.expectEqual(@as(u16, E.ISDIR), errno("file is a directory"));
    try std.testing.expectEqual(@as(u16, E.PIPE), errno("write on closed pipe"));
    try std.testing.expectEqual(@as(u16, E.NOTEMPTY), errno("directory not empty"));
    try std.testing.expectEqual(@as(u16, E.IO), errno("ken has left the building"));
}

test "errno from the error, not the file name it quotes" {
    // The kernel's walk errors, as namelenerror formats them.
    try std.testing.expectEqual(@as(u16, E.NOENT), errno("file does not exist: '/nix/store/abc-source/nixos/nixos-rebuild-target-host-interrupted.nix'"));
    try std.testing.expectEqual(@as(u16, E.NOENT), errno("file does not exist: '/tmp/permission denied'"));
    try std.testing.expectEqual(@as(u16, E.NOTDIR), errno("not a directory: '/x/not found/y'"));
    // %q doubles a quote inside a name.
    try std.testing.expectEqual(@as(u16, E.NOENT), errno("file does not exist: '/tmp/it''s interrupted'"));
    // A name cut off at ERRMAX has no closing quote.
    try std.testing.expectEqual(@as(u16, E.NOENT), errno("file does not exist: '.../is a directory"));
    // An error that's only a quoted name says nothing.
    try std.testing.expectEqual(@as(u16, E.IO), errno("'interrupted'"));
    // Apostrophes aren't quotes.
    try std.testing.expectEqual(@as(u16, E.ADDRNOTAVAIL), errno("can't assign requested address"));
    // The error after a long quoted name still counts.
    try std.testing.expectEqual(@as(u16, E.ACCES), errno("'/" ++ "a" ** 200 ++ "' permission denied"));
}

test "stat from a Dir" {
    var b: [128]u8 = @splat(0);
    const name = "hello";
    std.mem.writeInt(u16, b[2..4], 'M', .little);
    std.mem.writeInt(u64, b[13..21], 42, .little);
    std.mem.writeInt(u32, b[21..25], 0o644, .little);
    std.mem.writeInt(u64, b[33..41], 1234, .little);
    std.mem.writeInt(u16, b[41..43], name.len, .little);
    @memcpy(b[43..][0..name.len], name);
    var at: usize = 43 + name.len;
    for (0..3) |_| {
        std.mem.writeInt(u16, b[at..][0..2], 0, .little);
        at += 2;
    }
    std.mem.writeInt(u16, b[0..2], @intCast(at - 2), .little);
    const d, const n = Dir.parse(&b).?;
    try std.testing.expectEqual(at, n);
    try std.testing.expectEqualStrings("hello", d.name);
    const s = Stat.fromDir(&d, .auto, 0, 0);
    try std.testing.expectEqual(@as(u32, S_IFREG | 0o644), s.mode);
    const g = s.generic();
    try std.testing.expectEqual(@as(u64, 1234), std.mem.readInt(u64, g[48..56], .little));
    try std.testing.expectEqual(@as(u64, 42), std.mem.readInt(u64, g[8..16], .little));
}

test "errstr and errno agree" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("file does not exist", errstr(E.NOENT, &buf));
    try std.testing.expectEqualStrings("permission denied", errstr(E.ACCES, &buf));
    try std.testing.expectEqualStrings("errno 6", errstr(E.NXIO, &buf));
    // Every errno up to 133 maps to a string that maps back to it.
    for (1..134) |e| {
        try std.testing.expectEqual(@as(u16, @intCast(e)), errno(errstr(@intCast(e), &buf)));
    }
}

test "Dir from a .L stat" {
    const st: wire.Stat = .{ .qid = .{ .type = wire.QTDIR, .vers = 3, .path = 42 }, .mode = S_IFDIR | 0o755, .size = 4096, .atime_sec = 10, .mtime_sec = 1 << 40 };
    const d = dirFromStat(&st, "bin", "glenda", "users");
    try std.testing.expectEqual(wire.DMDIR | 0o755, d.mode);
    try std.testing.expectEqual(wire.QTDIR, d.qid_type);
    try std.testing.expectEqual(@as(u64, 0), d.length);
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), d.mtime);
    try std.testing.expectEqualStrings("glenda", d.muid);

    var buf: [128]u8 = undefined;
    const b = try d.pack(&buf);
    const p, const n = Dir.parse(b).?;
    try std.testing.expectEqual(b.len, n);
    try std.testing.expectEqualStrings("bin", p.name);
    try std.testing.expectEqualStrings("users", p.gid);
    try std.testing.expectEqualStrings("glenda", p.muid);
    try std.testing.expectEqual(@as(u64, 42), p.qid_path);

    const f: wire.Stat = .{ .qid = .{ .type = wire.QTSYMLINK, .path = 7 }, .mode = S_IFREG | 0o4644, .size = 12 };
    const fd = dirFromStat(&f, "x", "1", "1");
    try std.testing.expectEqual(@as(u32, 0o644), fd.mode);
    try std.testing.expectEqual(wire.QTFILE, fd.qid_type);
    try std.testing.expectEqual(@as(u64, 12), fd.length);
    const fifo: wire.Stat = .{ .mode = S_IFIFO | 0o600, .size = 5 };
    try std.testing.expectEqual(@as(u64, 0), dirFromStat(&fifo, "p", "", "").length);
    try std.testing.expect(!openable(fifo.mode));
    try std.testing.expect(openable(f.mode));

    const back = statFromDir(&p, 1000, 1000);
    try std.testing.expectEqual(@as(u32, S_IFDIR | 0o755), back.mode);
    try std.testing.expectEqual(@as(u64, 2), back.nlink);
}

test "open modes" {
    const L = wire.L;
    try std.testing.expectEqual(L.RDONLY, openFlags(wire.OREAD));
    try std.testing.expectEqual(L.RDONLY, openFlags(wire.OEXEC));
    try std.testing.expectEqual(L.RDWR | L.TRUNC, openFlags(wire.ORDWR | wire.OTRUNC | wire.ORCLOSE));
    try std.testing.expectEqual(wire.OWRITE | wire.OTRUNC, openMode(L.WRONLY | L.TRUNC | L.CREATE | L.NOFOLLOW));
    try std.testing.expectEqual(wire.OREAD, openMode(L.NOACCESS));
    try std.testing.expectEqual(@as(u32, 0o640), createMode(wire.DMDIR | wire.DMEXCL | 0o640));
}

test "wstat as rename and setattr" {
    const L = wire.L;
    try std.testing.expect(wstat(&Dir.keep).sync);
    var d = Dir.keep;
    d.name = "new";
    d.mode = wire.DMDIR | 0o700;
    const w = wstat(&d);
    try std.testing.expectEqualStrings("new", w.rename.?);
    try std.testing.expectEqual(L.SETATTR_MODE, w.setattr.valid);
    try std.testing.expectEqual(@as(u32, 0o700), w.setattr.mode);
    try std.testing.expect(!w.sync);

    var t = Dir.keep;
    t.length = 0;
    t.mtime = 99;
    const wt = wstat(&t);
    try std.testing.expectEqual(@as(?[]const u8, null), wt.rename);
    try std.testing.expectEqual(L.SETATTR_SIZE | L.SETATTR_MTIME | L.SETATTR_MTIME_SET, wt.setattr.valid);

    const s = wstatFromSetattr(L.SETATTR_SIZE | L.SETATTR_MTIME | L.SETATTR_UID, 0, 5, 0, 1234);
    try std.testing.expectEqual(@as(u64, 5), s.length);
    try std.testing.expectEqual(@as(u32, 1234), s.mtime);
    try std.testing.expectEqual(Dir.keep.mode, s.mode);
    try std.testing.expect(wstatFromSetattr(0, 0, 0, 0, 0).isNull());
}

test "user map" {
    const passwd =
        \\# comment
        \\root:x:0:0:root:/root:/bin/sh
        \\glenda:x:1000:1000::/usr/glenda:/bin/rc
        \\bad line
        \\svc:x:notanumber:1::/:/bin/false
        \\
    ;
    var buf: [10]u8 = undefined;
    // Without a map: the machine's user is the host uid, numbers are names.
    const plain: UserMap = .{ .user = "glenda", .uid = 501 };
    try std.testing.expectEqual(@as(u32, 501), plain.number("glenda"));
    try std.testing.expectEqual(@as(u32, 42), plain.number("42"));
    try std.testing.expectEqual(@as(u32, 501), plain.number("0"));
    try std.testing.expectEqual(@as(u32, 501), plain.number("root"));
    try std.testing.expectEqualStrings("glenda", plain.name(501, &buf));
    try std.testing.expectEqualStrings("0", plain.name(0, &buf));
    // With one: names in it are theirs, 0 included.
    const mapped: UserMap = .{ .passwd = passwd, .user = "glenda", .uid = 501 };
    try std.testing.expectEqual(@as(u32, 1000), mapped.number("glenda"));
    try std.testing.expectEqual(@as(u32, 0), mapped.number("root"));
    try std.testing.expectEqualStrings("root", mapped.name(0, &buf));
    try std.testing.expectEqual(@as(u32, 501), mapped.number("svc"));

    try std.testing.expectEqual(@as(u32, 1000), UserMap.hostUid(null));
    try std.testing.expectEqual(UserMap.nobody, UserMap.hostUid(0));
    try std.testing.expectEqual(@as(u32, 501), UserMap.hostUid(501));
}

fn fuzzDir(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [512]u8 = undefined;
    const n = smith.slice(&buf);
    if (Dir.parse(buf[0..n])) |r| {
        const d, const size = r;
        try std.testing.expect(size <= n);
        _ = wstat(&d);
        _ = statFromDir(&d, 1, 1);
    }
    var p = Passwd.init(buf[0..n]);
    while (p.next()) |_| {}
    var eb: [16]u8 = undefined;
    _ = errno(buf[0..n]);
    _ = errstr(smith.value(u32), &eb);
}

test "fuzz: Dirs, passwd files, and error strings" {
    try std.testing.fuzz({}, fuzzDir, .{});
}
