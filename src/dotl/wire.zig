//! 9P's wire encoding in three dialects (design/dotl.md): 9P2000,
//! which devmnt and exportfs speak; 9P2000.L, Linux's; and `9P2000.L.Z`,
//! ZeroFS's extension of .L (ninep-proto 0.4.0's `wire_messages.rs`).
//!
//! A frame is `size[4] type[1] tag[2] body`, little-endian. Each message is
//! a struct whose fields are in wire order and whose types say how they're
//! encoded (see `encode` and `decode`), with its type number as `id`. A .L.Z
//! mutation also has `mutation = true`: once `9P2000.L.Z` is negotiated it
//! carries an `Envelope` between the tag and the body.
//!
//! Everything here works on caller-owned buffers and never allocates.
//! Decoding is bounds-checked and refuses trailing bytes, so a hostile
//! peer's frame is either a well-formed message or `error.Malformed`.

const std = @import("std");

pub const version_9p = "9P2000";
pub const version_l = "9P2000.L";
pub const version_lz = "9P2000.L.Z";

pub const header_size = 7;
/// The bytes a Tread/Rread and Twrite/Rwrite carry besides data: devmnt's
/// IOHDRSZ, also enough for an enveloped Twrite's header.
pub const io_header = 24;
pub const io_header_lz = io_header + Envelope.wire_size;

pub const notag: u16 = 0xffff;
pub const nofid: u32 = 0xffffffff;
/// Names a walk carries at most, in every dialect.
pub const max_welem = 16;

pub const Error = error{
    /// The bytes aren't the message they claim to be: short, long, a count
    /// past the frame, or an unknown type.
    Malformed,
    /// The frame's size field is over the negotiated msize.
    TooBig,
    /// The output buffer can't hold the message.
    NoSpace,
};

// Qid types. QTSYMLINK is .L's (and .u's); Plan 9 has no use for it.
pub const QTDIR: u8 = 0x80;
pub const QTAPPEND: u8 = 0x40;
pub const QTEXCL: u8 = 0x20;
pub const QTMOUNT: u8 = 0x10;
pub const QTAUTH: u8 = 0x08;
pub const QTTMP: u8 = 0x04;
pub const QTSYMLINK: u8 = 0x02;
pub const QTFILE: u8 = 0x00;

// 9P2000 open modes.
pub const OREAD: u8 = 0;
pub const OWRITE: u8 = 1;
pub const ORDWR: u8 = 2;
pub const OEXEC: u8 = 3;
pub const OTRUNC: u8 = 0x10;
pub const ORCLOSE: u8 = 0x40;

// 9P2000 Dir mode bits.
pub const DMDIR: u32 = 0x80000000;
pub const DMAPPEND: u32 = 0x40000000;
pub const DMEXCL: u32 = 0x20000000;
pub const DMTMP: u32 = 0x04000000;

/// .L's open flags (Linux's generic values, which the protocol fixes
/// whatever the host's architecture).
pub const L = struct {
    pub const RDONLY: u32 = 0o0;
    pub const WRONLY: u32 = 0o1;
    pub const RDWR: u32 = 0o2;
    pub const NOACCESS: u32 = 0o3;
    pub const ACCMODE: u32 = 0o3;
    pub const CREATE: u32 = 0o100;
    pub const EXCL: u32 = 0o200;
    pub const NOCTTY: u32 = 0o400;
    pub const TRUNC: u32 = 0o1000;
    pub const APPEND: u32 = 0o2000;
    pub const NONBLOCK: u32 = 0o4000;
    pub const DSYNC: u32 = 0o10000;
    pub const FASYNC: u32 = 0o20000;
    pub const DIRECT: u32 = 0o40000;
    pub const LARGEFILE: u32 = 0o100000;
    pub const DIRECTORY: u32 = 0o200000;
    pub const NOFOLLOW: u32 = 0o400000;
    pub const NOATIME: u32 = 0o1000000;
    pub const CLOEXEC: u32 = 0o2000000;
    pub const SYNC: u32 = 0o4000000;

    /// Tunlinkat's flag for a directory.
    pub const AT_REMOVEDIR: u32 = 0x200;

    pub const GETATTR_BASIC: u64 = 0x000007ff;
    pub const GETATTR_ALL: u64 = 0x00003fff;

    pub const SETATTR_MODE: u32 = 0x00000001;
    pub const SETATTR_UID: u32 = 0x00000002;
    pub const SETATTR_GID: u32 = 0x00000004;
    pub const SETATTR_SIZE: u32 = 0x00000008;
    pub const SETATTR_ATIME: u32 = 0x00000010;
    pub const SETATTR_MTIME: u32 = 0x00000020;
    pub const SETATTR_CTIME: u32 = 0x00000040;
    pub const SETATTR_ATIME_SET: u32 = 0x00000080;
    pub const SETATTR_MTIME_SET: u32 = 0x00000100;
    /// .L.Z: an atime the server picked for an access, not a change.
    pub const SETATTR_ATIME_ACCESS: u32 = 0x80000000;

    pub const LOCK_RDLCK: u8 = 0;
    pub const LOCK_WRLCK: u8 = 1;
    pub const LOCK_UNLCK: u8 = 2;
    pub const LOCK_FLAGS_BLOCK: u32 = 1;
    pub const LOCK_FLAGS_RECLAIM: u32 = 2;
    pub const LOCK_SUCCESS: u8 = 0;
    pub const LOCK_BLOCKED: u8 = 1;
    pub const LOCK_ERROR: u8 = 2;
    pub const LOCK_GRACE: u8 = 3;

    /// .L.Z: the errnos an HA server answers when it isn't the writer.
    pub const ENOTLEADER: u32 = 108;
    pub const ENOTLEADER_CLEAN: u32 = 107;
    /// .L.Z: an op_id older than the server remembers.
    pub const EOPIDSTALE: u32 = 116;

    pub const OP_FLAG_RETRY: u8 = 1;
    pub const REBIND_REPLAY: u8 = 1;
    pub const REBIND_OPENED: u8 = 2;
    pub const FSYNC_DATASYNC: u32 = 1;
    pub const FSYNC_INODE: u32 = 2;

    /// .L.Z: how long a mutation may be resent with its op_id, and how
    /// long the server remembers its result.
    pub const retry_horizon_s = 120;
    pub const result_retention_s = 150;
    /// .L.Z's largest msize.
    pub const max_msize: u32 = 10 * 1024 * 1024;
};

pub const Qid = struct {
    type: u8 = 0,
    vers: u32 = 0,
    path: u64 = 0,

    pub const wire_size = 13;
};

/// A Linux `stat` as .L's Rgetattr (and .L.Z's attribute replies) carry it.
pub const Stat = struct {
    qid: Qid = .{},
    mode: u32 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    nlink: u64 = 0,
    rdev: u64 = 0,
    size: u64 = 0,
    blksize: u64 = 0,
    blocks: u64 = 0,
    atime_sec: u64 = 0,
    atime_nsec: u64 = 0,
    mtime_sec: u64 = 0,
    mtime_nsec: u64 = 0,
    ctime_sec: u64 = 0,
    ctime_nsec: u64 = 0,
    btime_sec: u64 = 0,
    btime_nsec: u64 = 0,
    gen: u64 = 0,
    data_version: u64 = 0,

    pub const wire_size = Qid.wire_size + 3 * 4 + 15 * 8;
};

/// .L.Z's idempotency fields on a mutation.
pub const Envelope = struct {
    op_id: [16]u8 = @splat(0),
    flags: u8 = 0,
    origin_epoch: u64 = 0,

    pub const wire_size = 25;
};

/// A string: `len[2] bytes`.
pub const Str = []const u8;

/// `count[4] bytes`: Tread and Twrite data, and Rreaddir's entries.
pub const Data = struct {
    bytes: []const u8,
};

/// 9P2000's `stat[n]`: `n[2]` and a packed Dir (see attr.zig's `Dir`),
/// in Rstat and Twstat.
pub const DirBytes = struct {
    bytes: []const u8,
};

/// A walk's names: `nwname[2] wname[s]...`, at most `max_welem`.
pub const Names = struct {
    n: u16 = 0,
    names: [max_welem][]const u8 = undefined,

    pub fn init(names: []const []const u8) Names {
        std.debug.assert(names.len <= max_welem);
        var w: Names = .{ .n = @intCast(names.len) };
        for (names, 0..) |s, i| w.names[i] = s;
        return w;
    }

    pub fn slice(w: *const Names) []const []const u8 {
        return w.names[0..w.n];
    }
};

/// A walk's qids: `nwqid[2] qid[13]...`, at most `max_welem`.
pub const Qids = struct {
    n: u16 = 0,
    qids: [max_welem]Qid = undefined,

    pub fn init(qids: []const Qid) Qids {
        std.debug.assert(qids.len <= max_welem);
        var w: Qids = .{ .n = @intCast(qids.len) };
        for (qids, 0..) |q, i| w.qids[i] = q;
        return w;
    }

    pub fn slice(w: *const Qids) []const Qid {
        return w.qids[0..w.n];
    }
};

/// Messages common to every dialect, also in `p9` and `l`.
pub const common = struct {
    pub const Tversion = struct {
        pub const id = 100;
        msize: u32,
        version: Str,
    };
    pub const Rversion = struct {
        pub const id = 101;
        msize: u32,
        version: Str,
    };
    pub const Tflush = struct {
        pub const id = 108;
        oldtag: u16,
    };
    pub const Rflush = struct {
        pub const id = 109;
    };
    pub const Twalk = struct {
        pub const id = 110;
        fid: u32,
        newfid: u32,
        wnames: Names,
    };
    pub const Rwalk = struct {
        pub const id = 111;
        wqids: Qids,
    };
    pub const Tread = struct {
        pub const id = 116;
        fid: u32,
        offset: u64,
        count: u32,
    };
    pub const Rread = struct {
        pub const id = 117;
        data: Data,
    };
    pub const Twrite = struct {
        pub const id = 118;
        pub const mutation = true;
        fid: u32,
        offset: u64,
        data: Data,
    };
    pub const Rwrite = struct {
        pub const id = 119;
        count: u32,
    };
    pub const Tclunk = struct {
        pub const id = 120;
        fid: u32,
    };
    pub const Rclunk = struct {
        pub const id = 121;
    };
};

/// 9P2000 as devmnt and exportfs speak it (intro(5)).
pub const p9 = struct {
    pub const Tversion = common.Tversion;
    pub const Rversion = common.Rversion;
    pub const Tauth = struct {
        pub const id = 102;
        afid: u32,
        uname: Str,
        aname: Str,
    };
    pub const Rauth = struct {
        pub const id = 103;
        aqid: Qid,
    };
    pub const Tattach = struct {
        pub const id = 104;
        fid: u32,
        afid: u32,
        uname: Str,
        aname: Str,
    };
    pub const Rattach = struct {
        pub const id = 105;
        qid: Qid,
    };
    pub const Rerror = struct {
        pub const id = 107;
        ename: Str,
    };
    pub const Tflush = common.Tflush;
    pub const Rflush = common.Rflush;
    pub const Twalk = common.Twalk;
    pub const Rwalk = common.Rwalk;
    pub const Topen = struct {
        pub const id = 112;
        fid: u32,
        mode: u8,
    };
    pub const Ropen = struct {
        pub const id = 113;
        qid: Qid,
        iounit: u32,
    };
    pub const Tcreate = struct {
        pub const id = 114;
        fid: u32,
        name: Str,
        perm: u32,
        mode: u8,
    };
    pub const Rcreate = struct {
        pub const id = 115;
        qid: Qid,
        iounit: u32,
    };
    pub const Tread = common.Tread;
    pub const Rread = common.Rread;
    pub const Twrite = struct {
        pub const id = 118;
        fid: u32,
        offset: u64,
        data: Data,
    };
    pub const Rwrite = common.Rwrite;
    pub const Tclunk = common.Tclunk;
    pub const Rclunk = common.Rclunk;
    pub const Tremove = struct {
        pub const id = 122;
        fid: u32,
    };
    pub const Rremove = struct {
        pub const id = 123;
    };
    pub const Tstat = struct {
        pub const id = 124;
        fid: u32,
    };
    pub const Rstat = struct {
        pub const id = 125;
        stat: DirBytes,
    };
    pub const Twstat = struct {
        pub const id = 126;
        fid: u32,
        stat: DirBytes,
    };
    pub const Rwstat = struct {
        pub const id = 127;
    };

    pub const T = Union(&.{ Tversion, Tauth, Tattach, Tflush, Twalk, Topen, Tcreate, Tread, Twrite, Tclunk, Tremove, Tstat, Twstat });
    pub const R = Union(&.{ Rversion, Rauth, Rattach, Rerror, Rflush, Rwalk, Ropen, Rcreate, Rread, Rwrite, Rclunk, Rremove, Rstat, Rwstat });
};

/// 9P2000.L, and ZeroFS's `9P2000.L.Z` messages besides.
pub const l = struct {
    pub const Rlerror = struct {
        pub const id = 7;
        ecode: u32,
    };
    pub const Tstatfs = struct {
        pub const id = 8;
        fid: u32,
    };
    pub const Rstatfs = struct {
        pub const id = 9;
        type: u32,
        bsize: u32,
        blocks: u64,
        bfree: u64,
        bavail: u64,
        files: u64,
        ffree: u64,
        fsid: u64,
        namelen: u32,
    };
    pub const Tlopen = struct {
        pub const id = 12;
        fid: u32,
        flags: u32,
    };
    pub const Rlopen = struct {
        pub const id = 13;
        qid: Qid,
        iounit: u32,
    };
    pub const Tlcreate = struct {
        pub const id = 14;
        pub const mutation = true;
        fid: u32,
        name: Str,
        flags: u32,
        mode: u32,
        gid: u32,
    };
    pub const Rlcreate = struct {
        pub const id = 15;
        qid: Qid,
        iounit: u32,
    };
    pub const Tsymlink = struct {
        pub const id = 16;
        pub const mutation = true;
        dfid: u32,
        name: Str,
        symtgt: Str,
        gid: u32,
    };
    pub const Rsymlink = struct {
        pub const id = 17;
        qid: Qid,
    };
    pub const Tmknod = struct {
        pub const id = 18;
        pub const mutation = true;
        dfid: u32,
        name: Str,
        mode: u32,
        major: u32,
        minor: u32,
        gid: u32,
    };
    pub const Rmknod = struct {
        pub const id = 19;
        qid: Qid,
    };
    /// 9P2000's Tremove, which .L keeps: servers without Tunlinkat,
    /// such as diod 1.0, take it instead.
    pub const Tremove = struct {
        pub const id = 122;
        pub const mutation = true;
        fid: u32,
    };
    pub const Rremove = struct {
        pub const id = 123;
    };
    pub const Trename = struct {
        pub const id = 20;
        pub const mutation = true;
        fid: u32,
        dfid: u32,
        name: Str,
    };
    pub const Rrename = struct {
        pub const id = 21;
    };
    pub const Treadlink = struct {
        pub const id = 22;
        fid: u32,
    };
    pub const Rreadlink = struct {
        pub const id = 23;
        target: Str,
    };
    pub const Tgetattr = struct {
        pub const id = 24;
        fid: u32,
        request_mask: u64,
    };
    pub const Rgetattr = struct {
        pub const id = 25;
        valid: u64,
        stat: Stat,
    };
    pub const Tsetattr = struct {
        pub const id = 26;
        pub const mutation = true;
        fid: u32,
        valid: u32,
        mode: u32,
        uid: u32,
        gid: u32,
        size: u64,
        atime_sec: u64,
        atime_nsec: u64,
        mtime_sec: u64,
        mtime_nsec: u64,
    };
    pub const Rsetattr = struct {
        pub const id = 27;
    };
    pub const Txattrwalk = struct {
        pub const id = 30;
        fid: u32,
        newfid: u32,
        name: Str,
    };
    pub const Rxattrwalk = struct {
        pub const id = 31;
        size: u64,
    };
    pub const Txattrcreate = struct {
        pub const id = 32;
        fid: u32,
        name: Str,
        attr_size: u64,
        flags: u32,
    };
    pub const Rxattrcreate = struct {
        pub const id = 33;
    };
    pub const Treaddir = struct {
        pub const id = 40;
        fid: u32,
        offset: u64,
        count: u32,
    };
    /// Entries in `data`; see `DirEntries`.
    pub const Rreaddir = struct {
        pub const id = 41;
        data: Data,
    };
    pub const Tfsync = struct {
        pub const id = 50;
        fid: u32,
        datasync: u32,
    };
    pub const Rfsync = struct {
        pub const id = 51;
    };
    pub const Tlock = struct {
        pub const id = 52;
        fid: u32,
        type: u8,
        flags: u32,
        start: u64,
        length: u64,
        proc_id: u32,
        client_id: Str,
    };
    pub const Rlock = struct {
        pub const id = 53;
        status: u8,
    };
    pub const Tgetlock = struct {
        pub const id = 54;
        fid: u32,
        type: u8,
        start: u64,
        length: u64,
        proc_id: u32,
        client_id: Str,
    };
    pub const Rgetlock = struct {
        pub const id = 55;
        type: u8,
        start: u64,
        length: u64,
        proc_id: u32,
        client_id: Str,
    };
    pub const Tlink = struct {
        pub const id = 70;
        pub const mutation = true;
        dfid: u32,
        fid: u32,
        name: Str,
    };
    pub const Rlink = struct {
        pub const id = 71;
    };
    pub const Tmkdir = struct {
        pub const id = 72;
        pub const mutation = true;
        dfid: u32,
        name: Str,
        mode: u32,
        gid: u32,
    };
    pub const Rmkdir = struct {
        pub const id = 73;
        qid: Qid,
    };
    pub const Trenameat = struct {
        pub const id = 74;
        pub const mutation = true;
        olddirfid: u32,
        oldname: Str,
        newdirfid: u32,
        newname: Str,
    };
    pub const Rrenameat = struct {
        pub const id = 75;
    };
    pub const Tunlinkat = struct {
        pub const id = 76;
        pub const mutation = true;
        dirfid: u32,
        name: Str,
        flags: u32,
    };
    pub const Runlinkat = struct {
        pub const id = 77;
    };
    pub const Tversion = common.Tversion;
    pub const Rversion = common.Rversion;
    /// .L's Tauth adds n_uname, like its Tattach.
    pub const Tauth = struct {
        pub const id = 102;
        afid: u32,
        uname: Str,
        aname: Str,
        n_uname: u32,
    };
    pub const Rauth = struct {
        pub const id = 103;
        aqid: Qid,
    };
    pub const Tattach = struct {
        pub const id = 104;
        fid: u32,
        afid: u32,
        uname: Str,
        aname: Str,
        n_uname: u32,
    };
    pub const Rattach = struct {
        pub const id = 105;
        qid: Qid,
    };
    pub const Tflush = common.Tflush;
    pub const Rflush = common.Rflush;
    pub const Twalk = common.Twalk;
    pub const Rwalk = common.Rwalk;
    pub const Tread = common.Tread;
    pub const Rread = common.Rread;
    pub const Twrite = common.Twrite;
    pub const Rwrite = common.Rwrite;
    pub const Tclunk = common.Tclunk;
    pub const Rclunk = common.Rclunk;

    // 9P2000.L.Z.
    pub const Tfallocate = struct {
        pub const id = 228;
        pub const mutation = true;
        fid: u32,
        offset: u64,
        length: u64,
        mode: u32,
    };
    pub const Rfallocate = struct {
        pub const id = 229;
    };
    pub const Tlopenatread = struct {
        pub const id = 230;
        fid: u32,
        newfid: u32,
        flags: u32,
        count: u32,
    };
    pub const Rlopenatread = struct {
        pub const id = 231;
        qid: Qid,
        iounit: u32,
        eof: u8,
        data: Data,
    };
    /// A fsync that also checks acknowledged writes survived a failover;
    /// answered by Rfsync.
    pub const Tfsyncdur = struct {
        pub const id = 232;
        fid: u32,
        datasync: u32,
        token: u64,
    };
    pub const Tgetlineage = struct {
        pub const id = 233;
    };
    pub const Rgetlineage = struct {
        pub const id = 234;
        token: u64,
        writer_epoch: u64,
    };
    pub const Tlopenat = struct {
        pub const id = 236;
        fid: u32,
        newfid: u32,
        flags: u32,
    };
    pub const Rlopenat = struct {
        pub const id = 237;
        qid: Qid,
        iounit: u32,
    };
    pub const Tlcreateattr = struct {
        pub const id = 238;
        pub const mutation = true;
        dfid: u32,
        newfid: u32,
        name: Str,
        flags: u32,
        mode: u32,
        gid: u32,
    };
    pub const Rlcreateattr = struct {
        pub const id = 239;
        iounit: u32,
        stat: Stat,
    };
    pub const Tmkdirattr = struct {
        pub const id = 240;
        pub const mutation = true;
        dfid: u32,
        name: Str,
        mode: u32,
        gid: u32,
    };
    pub const Rmkdirattr = struct {
        pub const id = 241;
        stat: Stat,
    };
    pub const Tsymlinkattr = struct {
        pub const id = 242;
        pub const mutation = true;
        dfid: u32,
        name: Str,
        symtgt: Str,
        gid: u32,
    };
    pub const Rsymlinkattr = struct {
        pub const id = 243;
        stat: Stat,
    };
    pub const Tmknodattr = struct {
        pub const id = 244;
        pub const mutation = true;
        dfid: u32,
        name: Str,
        mode: u32,
        major: u32,
        minor: u32,
        gid: u32,
    };
    pub const Rmknodattr = struct {
        pub const id = 245;
        stat: Stat,
    };
    pub const Tlinkattr = struct {
        pub const id = 246;
        pub const mutation = true;
        dfid: u32,
        fid: u32,
        name: Str,
    };
    pub const Rlinkattr = struct {
        pub const id = 247;
        stat: Stat,
    };
    pub const Tsetattrattr = struct {
        pub const id = 248;
        pub const mutation = true;
        fid: u32,
        valid: u32,
        mode: u32,
        uid: u32,
        gid: u32,
        size: u64,
        atime_sec: u64,
        atime_nsec: u64,
        mtime_sec: u64,
        mtime_nsec: u64,
    };
    pub const Rsetattrattr = struct {
        pub const id = 249;
        stat: Stat,
    };
    /// Binds `fid` on a new connection to the inode `inode_id` (a
    /// `qid.path` from the old one) under the attach root `root_inode`.
    pub const Trebind = struct {
        pub const id = 250;
        fid: u32,
        inode_id: u64,
        root_inode: u64,
        flags: u8,
        uname: Str,
        n_uname: u32,
    };
    pub const Rrebind = struct {
        pub const id = 251;
        qid: Qid,
    };
    pub const Twalkgetattr = struct {
        pub const id = 252;
        fid: u32,
        newfid: u32,
        wnames: Names,
    };
    pub const Rwalkgetattr = struct {
        pub const id = 253;
        wqids: Qids,
        stat: Stat,
    };
    pub const Treaddirattr = struct {
        pub const id = 254;
        fid: u32,
        offset: u64,
        count: u32,
    };
    /// Entries with attributes in `data`; see `DirEntries`.
    pub const Rreaddirattr = struct {
        pub const id = 255;
        data: Data,
    };

    pub const T = Union(&.{ Tstatfs, Tlopen, Tlcreate, Tsymlink, Tmknod, Trename, Treadlink, Tgetattr, Tsetattr, Txattrwalk, Txattrcreate, Treaddir, Tfsync, Tlock, Tgetlock, Tlink, Tmkdir, Trenameat, Tunlinkat, Tremove, Tversion, Tauth, Tattach, Tflush, Twalk, Tread, Twrite, Tclunk, Tfallocate, Tlopenatread, Tfsyncdur, Tgetlineage, Tlopenat, Tlcreateattr, Tmkdirattr, Tsymlinkattr, Tmknodattr, Tlinkattr, Tsetattrattr, Trebind, Twalkgetattr, Treaddirattr });
    pub const R = Union(&.{ Rlerror, Rstatfs, Rlopen, Rlcreate, Rsymlink, Rmknod, Rrename, Rreadlink, Rgetattr, Rsetattr, Rxattrwalk, Rxattrcreate, Rreaddir, Rfsync, Rlock, Rgetlock, Rlink, Rmkdir, Rrenameat, Runlinkat, Rremove, Rversion, Rauth, Rattach, Rflush, Rwalk, Rread, Rwrite, Rclunk, Rfallocate, Rlopenatread, Rgetlineage, Rlopenat, Rlcreateattr, Rmkdirattr, Rsymlinkattr, Rmknodattr, Rlinkattr, Rsetattrattr, Rrebind, Rwalkgetattr, Rreaddirattr });

    /// Whether a T-message of this type carries an envelope under .L.Z.
    pub fn isMutation(id: u8) bool {
        inline for (@typeInfo(T).@"union".fields) |f| {
            if (f.type.id == id) return @hasDecl(f.type, "mutation");
        }
        return false;
    }
};

/// A tagged union of message types, by their names, to decode any of them.
fn Union(comptime types: []const type) type {
    var names: [types.len][]const u8 = undefined;
    var tys: [types.len]type = undefined;
    var vals: [types.len]u8 = undefined;
    for (types, 0..) |T, i| {
        const full = @typeName(T);
        const dot = std.mem.lastIndexOfScalar(u8, full, '.') orelse 0;
        names[i] = full[dot + 1 ..];
        tys[i] = T;
        vals[i] = T.id;
    }
    const Tag = @Enum(u8, .exhaustive, &names, &vals);
    return @Union(.auto, Tag, &names, &tys, &@splat(.{}));
}

/// A frame's header.
pub const Header = struct {
    size: u32,
    type: u8,
    tag: u16,
};

/// The header of the frame at the start of `b`, once at least 7 bytes are
/// there. A frame shorter than its header, or longer than `msize`, fails:
/// a reader uses this to split a stream into frames.
pub fn header(b: []const u8, msize: u32) Error!?Header {
    if (b.len < header_size) return null;
    const size = std.mem.readInt(u32, b[0..4], .little);
    if (size < header_size) return error.Malformed;
    if (size > msize) return error.TooBig;
    return .{ .size = size, .type = b[4], .tag = std.mem.readInt(u16, b[5..7], .little) };
}

/// Reads fields from a frame's body, bounds-checked.
pub const Reader = struct {
    b: []const u8,
    at: usize = 0,

    pub fn bytes(r: *Reader, n: usize) Error![]const u8 {
        if (n > r.b.len - r.at) return error.Malformed;
        defer r.at += n;
        return r.b[r.at..][0..n];
    }

    pub fn int(r: *Reader, comptime T: type) Error!T {
        const b = try r.bytes(@sizeOf(T));
        return std.mem.readInt(T, b[0..@sizeOf(T)], .little);
    }

    pub fn str(r: *Reader) Error![]const u8 {
        return r.bytes(try r.int(u16));
    }

    pub fn qid(r: *Reader) Error!Qid {
        return .{ .type = try r.int(u8), .vers = try r.int(u32), .path = try r.int(u64) };
    }

    pub fn stat(r: *Reader) Error!Stat {
        var s: Stat = .{ .qid = try r.qid() };
        inline for (@typeInfo(Stat).@"struct".fields[1..]) |f| @field(s, f.name) = try r.int(f.type);
        return s;
    }

    pub fn envelope(r: *Reader) Error!Envelope {
        var e: Envelope = .{};
        @memcpy(&e.op_id, try r.bytes(16));
        e.flags = try r.int(u8);
        e.origin_epoch = try r.int(u64);
        return e;
    }

    pub fn rest(r: *const Reader) usize {
        return r.b.len - r.at;
    }

    fn field(r: *Reader, comptime T: type) Error!T {
        return switch (T) {
            u8, u16, u32, u64 => r.int(T),
            Str => r.str(),
            Qid => r.qid(),
            Stat => r.stat(),
            Data => .{ .bytes = try r.bytes(try r.int(u32)) },
            DirBytes => .{ .bytes = try r.bytes(try r.int(u16)) },
            Names => blk: {
                const n = try r.int(u16);
                if (n > max_welem) return error.Malformed;
                var w: Names = .{ .n = n };
                for (0..n) |i| w.names[i] = try r.str();
                break :blk w;
            },
            Qids => blk: {
                const n = try r.int(u16);
                if (n > max_welem) return error.Malformed;
                var w: Qids = .{ .n = n };
                for (0..n) |i| w.qids[i] = try r.qid();
                break :blk w;
            },
            else => @compileError("no wire encoding for " ++ @typeName(T)),
        };
    }
};

/// Writes fields into a caller's buffer.
pub const Writer = struct {
    b: []u8,
    at: usize = 0,

    pub fn bytes(w: *Writer, s: []const u8) Error!void {
        if (s.len > w.b.len - w.at) return error.NoSpace;
        @memcpy(w.b[w.at..][0..s.len], s);
        w.at += s.len;
    }

    pub fn int(w: *Writer, comptime T: type, v: T) Error!void {
        var b: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &b, v, .little);
        return w.bytes(&b);
    }

    pub fn str(w: *Writer, s: []const u8) Error!void {
        if (s.len > std.math.maxInt(u16)) return error.NoSpace;
        try w.int(u16, @intCast(s.len));
        try w.bytes(s);
    }

    pub fn qid(w: *Writer, q: Qid) Error!void {
        try w.int(u8, q.type);
        try w.int(u32, q.vers);
        try w.int(u64, q.path);
    }

    pub fn stat(w: *Writer, s: Stat) Error!void {
        try w.qid(s.qid);
        inline for (@typeInfo(Stat).@"struct".fields[1..]) |f| try w.int(f.type, @field(s, f.name));
    }

    pub fn envelope(w: *Writer, e: Envelope) Error!void {
        try w.bytes(&e.op_id);
        try w.int(u8, e.flags);
        try w.int(u64, e.origin_epoch);
    }

    fn field(w: *Writer, comptime T: type, v: T) Error!void {
        switch (T) {
            u8, u16, u32, u64 => try w.int(T, v),
            Str => try w.str(v),
            Qid => try w.qid(v),
            Stat => try w.stat(v),
            Data => {
                if (v.bytes.len > std.math.maxInt(u32)) return error.NoSpace;
                try w.int(u32, @intCast(v.bytes.len));
                try w.bytes(v.bytes);
            },
            DirBytes => try w.str(v.bytes),
            Names => {
                try w.int(u16, v.n);
                for (v.slice()) |s| try w.str(s);
            },
            Qids => {
                try w.int(u16, v.n);
                for (v.slice()) |q| try w.qid(q);
            },
            else => @compileError("no wire encoding for " ++ @typeName(T)),
        }
    }
};

/// Encodes `msg` as a frame at the start of `out`, returning the frame.
/// `env` is put after the tag of a .L.Z mutation; pass null for every
/// other dialect, or for a message that isn't one.
pub fn encode(out: []u8, tag: u16, msg: anytype, env: ?Envelope) Error![]u8 {
    const T = @TypeOf(msg);
    var w: Writer = .{ .b = out, .at = 4 };
    if (out.len < header_size) return error.NoSpace;
    try w.int(u8, T.id);
    try w.int(u16, tag);
    if (@hasDecl(T, "mutation")) {
        if (env) |e| try w.envelope(e);
    }
    inline for (@typeInfo(T).@"struct".fields) |f| try w.field(f.type, @field(msg, f.name));
    if (w.at > std.math.maxInt(u32)) return error.NoSpace;
    std.mem.writeInt(u32, out[0..4], @intCast(w.at), .little);
    return out[0..w.at];
}

/// Decodes the body of a frame known to be a `T` (its header already
/// read), after any envelope.
pub fn decodeBody(comptime T: type, body: []const u8) Error!T {
    var r: Reader = .{ .b = body };
    var msg: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |f| @field(msg, f.name) = try r.field(f.type);
    if (r.rest() != 0) return error.Malformed;
    return msg;
}

/// A decoded frame: its tag, envelope (for a .L.Z mutation), and message.
pub fn Frame(comptime U: type) type {
    return struct {
        tag: u16,
        env: ?Envelope = null,
        msg: U,
    };
}

/// Decodes a whole frame as one of `U`'s messages (`p9.T`, `p9.R`, `l.T`
/// or `l.R`). `lz` says `9P2000.L.Z` was negotiated, so mutations carry
/// envelopes. Strings and data point into `frame`.
pub fn decode(comptime U: type, frame: []const u8, msize: u32, lz: bool) Error!Frame(U) {
    const h = (try header(frame, msize)) orelse return error.Malformed;
    if (h.size != frame.len) return error.Malformed;
    var body = frame[header_size..];
    inline for (@typeInfo(U).@"union".fields) |f| {
        if (f.type.id == h.type) {
            var env: ?Envelope = null;
            if (lz and @hasDecl(f.type, "mutation")) {
                var r: Reader = .{ .b = body };
                env = try r.envelope();
                body = body[Envelope.wire_size..];
            }
            return .{ .tag = h.tag, .env = env, .msg = @unionInit(U, f.name, try decodeBody(f.type, body)) };
        }
    }
    return error.Malformed;
}

/// An entry of an Rreaddir or Rreaddirattr: `qid offset type name`, and a
/// `Stat` after it in Rreaddirattr.
pub const DirEntry = struct {
    qid: Qid,
    offset: u64,
    type: u8,
    name: []const u8,
    stat: ?Stat = null,
};

/// Iterates the entries in an Rreaddir's (`attrs` false) or Rreaddirattr's
/// (`attrs` true) data. A malformed entry ends it with an error.
pub const DirEntries = struct {
    r: Reader,
    attrs: bool,

    pub fn init(data: []const u8, attrs: bool) DirEntries {
        return .{ .r = .{ .b = data }, .attrs = attrs };
    }

    pub fn next(it: *DirEntries) Error!?DirEntry {
        if (it.r.rest() == 0) return null;
        var e: DirEntry = .{
            .qid = try it.r.qid(),
            .offset = try it.r.int(u64),
            .type = try it.r.int(u8),
            .name = try it.r.str(),
        };
        if (it.attrs) e.stat = try it.r.stat();
        return e;
    }
};

/// Appends an entry to readdir data being built in `w`, or returns
/// NoSpace (with `w` unchanged) once it wouldn't fit.
pub fn putDirEntry(w: *Writer, e: DirEntry) Error!void {
    const need = Qid.wire_size + 8 + 1 + 2 + e.name.len + @as(usize, if (e.stat != null) Stat.wire_size else 0);
    if (need > w.b.len - w.at) return error.NoSpace;
    try w.qid(e.qid);
    try w.int(u64, e.offset);
    try w.int(u8, e.type);
    try w.str(e.name);
    if (e.stat) |s| try w.stat(s);
}

const t = std.testing;

test "l.Tversion round trip" {
    var buf: [64]u8 = undefined;
    const f = try encode(&buf, notag, l.Tversion{ .msize = 8192, .version = version_lz }, null);
    try t.expectEqualSlices(u8, "\x17\x00\x00\x00\x64\xff\xff\x00\x20\x00\x00\x0a\x009P2000.L.Z", f);
    const d = try decode(l.T, f, 8192, false);
    try t.expectEqual(notag, d.tag);
    try t.expectEqual(@as(u32, 8192), d.msg.Tversion.msize);
    try t.expectEqualStrings(version_lz, d.msg.Tversion.version);
}

test "Tattach differs between 9P2000 and .L" {
    var buf: [64]u8 = undefined;
    const f = try encode(&buf, 1, l.Tattach{ .fid = 0, .afid = nofid, .uname = "glenda", .aname = "", .n_uname = 1000 }, null);
    try t.expectEqual(@as(u32, 1000), (try decode(l.T, f, 8192, false)).msg.Tattach.n_uname);
    // The same frame is 9P2000's Tattach with four bytes left over.
    try t.expectError(error.Malformed, decode(p9.T, f, 8192, false));
    const g = try encode(&buf, 1, p9.Tattach{ .fid = 0, .afid = nofid, .uname = "glenda", .aname = "" }, null);
    try t.expectEqualStrings("glenda", (try decode(p9.T, g, 8192, false)).msg.Tattach.uname);
}

test "walks" {
    var buf: [256]u8 = undefined;
    const f = try encode(&buf, 7, l.Twalk{ .fid = 1, .newfid = 2, .wnames = .init(&.{ "usr", "glenda", "lib" }) }, null);
    const d = try decode(p9.T, f, 8192, false);
    try t.expectEqual(@as(u16, 3), d.msg.Twalk.wnames.n);
    try t.expectEqualStrings("glenda", d.msg.Twalk.wnames.slice()[1]);
    const r = try encode(&buf, 7, l.Rwalkgetattr{ .wqids = .init(&.{ .{ .type = QTDIR, .path = 5 }, .{ .path = 6 } }), .stat = .{ .size = 99, .mode = 0o100644 } }, null);
    const dr = try decode(l.R, r, 8192, false);
    try t.expectEqual(@as(u64, 6), dr.msg.Rwalkgetattr.wqids.slice()[1].path);
    try t.expectEqual(@as(u64, 99), dr.msg.Rwalkgetattr.stat.size);

    // More than 16 names is malformed.
    var big = [_]u8{0} ** 64;
    std.mem.writeInt(u32, big[0..4], 17, .little);
    big[4] = l.Twalk.id;
    std.mem.writeInt(u16, big[15..17], 17, .little);
    try t.expectError(error.Malformed, decode(p9.T, big[0..17], 8192, false));
}

test "mutation envelopes only under .L.Z" {
    var buf: [128]u8 = undefined;
    var env: Envelope = .{ .flags = L.OP_FLAG_RETRY, .origin_epoch = 3 };
    env.op_id[0] = 0xaa;
    const w = l.Twrite{ .fid = 4, .offset = 10, .data = .{ .bytes = "hello" } };
    const plain = try encode(&buf, 2, w, null);
    try t.expectEqual(@as(usize, header_size + 4 + 8 + 4 + 5), plain.len);
    const d = try decode(l.T, plain, 8192, false);
    try t.expectEqual(@as(?Envelope, null), d.env);
    try t.expectEqualStrings("hello", d.msg.Twrite.data.bytes);

    var buf2: [128]u8 = undefined;
    const z = try encode(&buf2, 2, w, env);
    try t.expectEqual(plain.len + Envelope.wire_size, z.len);
    try t.expectEqual(@as(u8, 0xaa), z[header_size]);
    const dz = try decode(l.T, z, 8192, true);
    try t.expectEqual(@as(u8, 0xaa), dz.env.?.op_id[0]);
    try t.expectEqual(@as(u64, 3), dz.env.?.origin_epoch);
    try t.expectEqualStrings("hello", dz.msg.Twrite.data.bytes);

    // A non-mutation never carries one, even when one is given.
    const c = try encode(&buf, 3, l.Tclunk{ .fid = 4 }, env);
    try t.expectEqual(@as(usize, header_size + 4), c.len);
    try t.expectEqual(@as(?Envelope, null), (try decode(l.T, c, 8192, true)).env);

    try t.expect(l.isMutation(l.Tunlinkat.id));
    try t.expect(l.isMutation(l.Tsetattrattr.id));
    try t.expect(!l.isMutation(l.Tfsyncdur.id));
    try t.expect(!l.isMutation(l.Tgetattr.id));
}

test "Rgetattr layout" {
    var buf: [256]u8 = undefined;
    const s: Stat = .{ .qid = .{ .type = QTDIR, .vers = 1, .path = 77 }, .mode = 0o40755, .uid = 1000, .gid = 100, .nlink = 2, .size = 4096, .mtime_sec = 1700000000, .data_version = 9 };
    const f = try encode(&buf, 9, l.Rgetattr{ .valid = L.GETATTR_BASIC, .stat = s }, null);
    try t.expectEqual(@as(usize, header_size + 8 + Stat.wire_size), f.len);
    // mode is right after valid and the qid; data_version is last.
    try t.expectEqual(@as(u32, 0o40755), std.mem.readInt(u32, f[header_size + 8 + 13 ..][0..4], .little));
    try t.expectEqual(@as(u64, 9), std.mem.readInt(u64, f[f.len - 8 ..][0..8], .little));
    try t.expectEqual(s, (try decode(l.R, f, 8192, false)).msg.Rgetattr.stat);
}

test "readdir entries" {
    var data: [256]u8 = undefined;
    var w: Writer = .{ .b = &data };
    try putDirEntry(&w, .{ .qid = .{ .path = 1 }, .offset = 1, .type = 8, .name = "a" });
    try putDirEntry(&w, .{ .qid = .{ .type = QTDIR, .path = 2 }, .offset = 2, .type = 4, .name = "bin" });
    var it = DirEntries.init(data[0..w.at], false);
    try t.expectEqualStrings("a", (try it.next()).?.name);
    const e = (try it.next()).?;
    try t.expectEqualStrings("bin", e.name);
    try t.expectEqual(@as(u64, 2), e.offset);
    try t.expectEqual(@as(?DirEntry, null), try it.next());

    // An entry that doesn't fit leaves the writer as it was.
    var small: [30]u8 = undefined;
    var ws: Writer = .{ .b = &small };
    try putDirEntry(&ws, .{ .qid = .{}, .offset = 1, .type = 8, .name = "a" });
    try t.expectError(error.NoSpace, putDirEntry(&ws, .{ .qid = .{}, .offset = 2, .type = 8, .name = "b" }));
    try t.expectEqual(@as(usize, 25), ws.at);

    var wa: Writer = .{ .b = &data };
    try putDirEntry(&wa, .{ .qid = .{ .path = 3 }, .offset = 1, .type = 8, .name = "x", .stat = .{ .size = 5 } });
    var ia = DirEntries.init(data[0..wa.at], true);
    try t.expectEqual(@as(u64, 5), (try ia.next()).?.stat.?.size);
    // A truncated entry is malformed.
    var ib = DirEntries.init(data[0 .. wa.at - 1], true);
    try t.expectError(error.Malformed, ib.next());
}

test "frames are checked against msize and their own size" {
    var buf: [64]u8 = undefined;
    const f = try encode(&buf, 1, l.Tclunk{ .fid = 1 }, null);
    try t.expectEqual(@as(?Header, null), try header(f[0..6], 8192));
    try t.expectError(error.TooBig, header(f, 8));
    try t.expectError(error.Malformed, decode(p9.T, f[0 .. f.len - 1], 8192, false));
    std.mem.writeInt(u32, f[0..4], 3, .little);
    try t.expectError(error.Malformed, header(f, 8192));
    std.mem.writeInt(u32, f[0..4], @intCast(f.len), .little);
    f[4] = 99;
    try t.expectError(error.Malformed, decode(p9.T, f, 8192, false));
    // An R-message isn't a T-message.
    const r = try encode(&buf, 1, l.Rclunk{}, null);
    try t.expectError(error.Malformed, decode(p9.T, r, 8192, false));
    try t.expectError(error.NoSpace, encode(buf[0..10], 1, l.Tversion{ .msize = 1, .version = version_9p }, null));
}

/// A message of type T with every field filled.
fn sample(comptime T: type) T {
    var msg: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |sf| {
        @field(msg, sf.name) = switch (sf.type) {
            u8 => 0x12,
            u16 => 0x1234,
            u32 => 0x12345678,
            u64 => 0x123456789abcdef0,
            Str => "name",
            Qid => .{ .type = 1, .vers = 2, .path = 3 },
            Stat => .{ .size = 4, .gen = 5 },
            Data => .{ .bytes = "data" },
            DirBytes => .{ .bytes = "dir" },
            Names => .init(&.{ "a", "b" }),
            Qids => .init(&.{.{ .path = 9 }}),
            else => unreachable,
        };
    }
    return msg;
}

test "every message round-trips" {
    inline for (.{ p9.T, p9.R, l.T, l.R }) |U| {
        inline for (@typeInfo(U).@"union".fields) |f| {
            for ([_]bool{ false, true }) |lz| {
                var buf: [512]u8 = undefined;
                const env: ?Envelope = if (lz) .{ .flags = 1 } else null;
                const frame = try encode(&buf, 42, sample(f.type), env);
                const d = try decode(U, frame, 8192, lz);
                try t.expectEqual(@as(u16, 42), d.tag);
                try t.expect(std.meta.activeTag(d.msg) == @field(std.meta.Tag(U), f.name));
                var again: [512]u8 = undefined;
                try t.expectEqualSlices(u8, frame, try encode(&again, 42, @field(d.msg, f.name), d.env));
            }
        }
    }
}

/// What must hold for any bytes from a peer: decoding fails cleanly or
/// gives a message that encodes back to the same bytes, and iterating
/// directory entries ends.
fn checkFrame(frame: []const u8, attrs: bool) !void {
    inline for (.{ p9.T, p9.R, l.T, l.R }) |U| {
        for ([_]bool{ false, true }) |lz| {
            const d = decode(U, frame, 8192, lz) catch continue;
            var out: [1024]u8 = undefined;
            const again = switch (d.msg) {
                inline else => |m| try encode(&out, d.tag, m, d.env),
            };
            try t.expectEqualSlices(u8, frame, again);
        }
    }
    var it = DirEntries.init(frame, attrs);
    while (it.next() catch null) |_| {}
}

test "mutated frames decode cleanly or not at all" {
    var prng: std.Random.DefaultPrng = .init(0x9f2000);
    const rand = prng.random();
    inline for (.{ p9.T, p9.R, l.T, l.R }) |U| {
        inline for (@typeInfo(U).@"union".fields) |f| {
            var buf: [512]u8 = undefined;
            const frame = try encode(&buf, 1, sample(f.type), if (rand.boolean()) Envelope{} else null);
            for (0..50) |_| {
                var m: [512]u8 = undefined;
                var n = frame.len;
                @memcpy(m[0..n], frame);
                for (0..rand.intRangeAtMost(usize, 1, 4)) |_| switch (rand.uintLessThan(u8, 4)) {
                    // A random byte, a random length, a size that agrees
                    // with the length, or a count or length set huge.
                    0 => m[rand.uintLessThan(usize, frame.len)] = rand.int(u8),
                    1 => n = rand.uintAtMost(usize, frame.len),
                    2 => std.mem.writeInt(u32, m[0..4], @intCast(n), .little),
                    else => m[rand.intRangeLessThan(usize, 4, frame.len)] = 0xff,
                };
                try checkFrame(m[0..n], rand.boolean());
            }
        }
    }
}

fn fuzzDecode(_: void, smith: *t.Smith) anyerror!void {
    var buf: [1024]u8 = undefined;
    const n = smith.slice(&buf);
    try checkFrame(buf[0..n], smith.value(bool));
}

test "fuzz: decoding hostile frames" {
    try t.fuzz({}, fuzzDecode, .{});
}
