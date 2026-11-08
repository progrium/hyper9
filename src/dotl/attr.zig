//! Plan 9 errors and Dirs in Linux's terms: errno numbers from error
//! strings, and `stat`, `statx` and `d_type` from a `Dir`. Shared by the
//! Linux personality (design/0018-linux-personality.md, "Users and stat")
//! and, once it's built, 9P2000.L (design/0022-dotl.md), which names this
//! file.

const std = @import("std");

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
};

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
    };
    var lower: [128]u8 = undefined;
    const n = @min(msg.len, lower.len);
    const l = std.ascii.lowerString(lower[0..n], msg[0..n]);
    for (table) |e| if (std.mem.indexOf(u8, l, e[0]) != null) return e[1];
    return E.IO;
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
        return .{ d, size };
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
