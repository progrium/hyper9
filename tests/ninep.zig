//! A small synchronous 9P2000 client for tests (design/epoch-0/namespace-kernel.md):
//! one request at a time over a host descriptor, enough to walk, open,
//! create, read, write, stat, and clunk.

const std = @import("std");

pub const NOFID: u32 = 0xffff_ffff;
pub const OREAD: u8 = 0;
pub const OWRITE: u8 = 1;
pub const ORDWR: u8 = 2;
pub const OTRUNC: u8 = 0x10;
pub const DMDIR: u32 = 0x8000_0000;

const Tversion = 100;
const Tattach = 104;
const Rerror = 107;
const Twalk = 110;
const Topen = 112;
const Tcreate = 114;
const Tread = 116;
const Twrite = 118;
const Tclunk = 120;
const Tremove = 122;
const Tstat = 124;

pub const Error = error{ Rerror, Protocol, Io, OutOfMemory };

pub const Qid = struct { type: u8, vers: u32, path: u64 };

pub const Client = struct {
    fd: std.posix.fd_t,
    gpa: std.mem.Allocator,
    msize: u32 = 8192 + 24,
    next_fid: u32 = 1,
    /// The last Rerror's message.
    err: [256]u8 = undefined,
    err_len: usize = 0,
    buf: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, fd: std.posix.fd_t) Error!Client {
        var c: Client = .{ .fd = fd, .gpa = gpa };
        try c.begin(Tversion);
        try c.put32(c.msize);
        try c.putStr("9P2000");
        const r = try c.rpc();
        c.msize = std.mem.readInt(u32, r[0..4], .little);
        return c;
    }

    pub fn deinit(c: *Client) void {
        c.buf.deinit(c.gpa);
    }

    pub fn errstr(c: *const Client) []const u8 {
        return c.err[0..c.err_len];
    }

    pub fn newFid(c: *Client) u32 {
        defer c.next_fid += 1;
        return c.next_fid;
    }

    /// Attaches a new fid to `aname`.
    pub fn attach(c: *Client, aname: []const u8) Error!u32 {
        const fid = c.newFid();
        try c.begin(Tattach);
        try c.put32(fid);
        try c.put32(NOFID);
        try c.putStr("test");
        try c.putStr(aname);
        _ = try c.rpc();
        return fid;
    }

    /// Walks a new fid from `fid` along `path` ("" or "/": a clone).
    pub fn walk(c: *Client, fid: u32, path: []const u8) Error!u32 {
        const nfid = c.newFid();
        var names: [16][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.tokenizeScalar(u8, path, '/');
        while (it.next()) |w| {
            if (n == names.len) return error.Protocol;
            names[n] = w;
            n += 1;
        }
        try c.begin(Twalk);
        try c.put32(fid);
        try c.put32(nfid);
        try c.put16(@intCast(n));
        for (names[0..n]) |w| try c.putStr(w);
        const r = try c.rpc();
        const got = std.mem.readInt(u16, r[0..2], .little);
        if (got != n) {
            c.setErr("file does not exist");
            return error.Rerror;
        }
        return nfid;
    }

    pub fn open(c: *Client, fid: u32, mode: u8) Error!void {
        try c.begin(Topen);
        try c.put32(fid);
        try c.put8(mode);
        _ = try c.rpc();
    }

    pub fn create(c: *Client, fid: u32, name: []const u8, perm: u32, mode: u8) Error!void {
        try c.begin(Tcreate);
        try c.put32(fid);
        try c.putStr(name);
        try c.put32(perm);
        try c.put8(mode);
        _ = try c.rpc();
    }

    pub fn read(c: *Client, fid: u32, off: u64, out: []u8) Error!usize {
        try c.begin(Tread);
        try c.put32(fid);
        try c.put64(off);
        try c.put32(@intCast(@min(out.len, c.msize - 24)));
        const r = try c.rpc();
        const n = std.mem.readInt(u32, r[0..4], .little);
        @memcpy(out[0..n], r[4..][0..n]);
        return n;
    }

    /// Reads all of `fid` from offset 0, into memory the caller frees.
    pub fn readAll(c: *Client, fid: u32) Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(c.gpa);
        var tmp: [8192]u8 = undefined;
        while (true) {
            const n = try c.read(fid, out.items.len, &tmp);
            if (n == 0) break;
            try out.appendSlice(c.gpa, tmp[0..n]);
        }
        return out.toOwnedSlice(c.gpa);
    }

    pub fn write(c: *Client, fid: u32, off: u64, data: []const u8) Error!usize {
        try c.begin(Twrite);
        try c.put32(fid);
        try c.put64(off);
        try c.put32(@intCast(data.len));
        try c.buf.appendSlice(c.gpa, data);
        const r = try c.rpc();
        return std.mem.readInt(u32, r[0..4], .little);
    }

    pub fn clunk(c: *Client, fid: u32) Error!void {
        try c.begin(Tclunk);
        try c.put32(fid);
        _ = try c.rpc();
    }

    pub fn remove(c: *Client, fid: u32) Error!void {
        try c.begin(Tremove);
        try c.put32(fid);
        _ = try c.rpc();
    }

    /// Whether `path` walks from `fid`.
    pub fn exists(c: *Client, fid: u32, path: []const u8) Error!bool {
        const f = c.walk(fid, path) catch |e| switch (e) {
            error.Rerror => return false,
            else => return e,
        };
        try c.clunk(f);
        return true;
    }

    /// Opens `path` from `fid`, reads it all, and clunks it.
    pub fn cat(c: *Client, fid: u32, path: []const u8) Error![]u8 {
        const f = try c.walk(fid, path);
        defer c.clunk(f) catch {};
        try c.open(f, OREAD);
        return c.readAll(f);
    }

    /// Writes `data` to `path` from `fid` in one Twrite.
    pub fn put(c: *Client, fid: u32, path: []const u8, data: []const u8) Error!void {
        const f = try c.walk(fid, path);
        defer c.clunk(f) catch {};
        try c.open(f, OWRITE);
        _ = try c.write(f, 0, data);
    }

    /// Makes `path`'s last element under its directory from `fid`: a
    /// directory with `dir`, else a file holding `data`.
    pub fn make(c: *Client, fid: u32, path: []const u8, dir: bool, data: []const u8) Error!void {
        const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
        const f = try c.walk(fid, path[0..slash]);
        defer c.clunk(f) catch {};
        const name = std.mem.trimStart(u8, path[slash..], "/");
        try c.create(f, name, if (dir) DMDIR | 0o775 else 0o664, if (dir) OREAD else ORDWR);
        if (!dir and data.len > 0) _ = try c.write(f, 0, data);
    }

    /// The names in directory `path` from `fid`, joined by spaces, sorted.
    pub fn ls(c: *Client, fid: u32, path: []const u8) Error![]u8 {
        const raw = try c.cat(fid, path);
        defer c.gpa.free(raw);
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(c.gpa);
        var p: usize = 0;
        while (p + 2 <= raw.len) {
            const size = std.mem.readInt(u16, raw[p..][0..2], .little);
            const d = raw[p + 2 ..][0..size];
            // type[2] dev[4] qid[13] mode[4] atime[4] mtime[4] length[8] name[s]
            const o = 2 + 4 + 13 + 4 + 4 + 4 + 8;
            const nl = std.mem.readInt(u16, d[o..][0..2], .little);
            try names.append(c.gpa, d[o + 2 ..][0..nl]);
            p += 2 + size;
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        return std.mem.join(c.gpa, " ", names.items);
    }

    fn setErr(c: *Client, msg: []const u8) void {
        const n = @min(msg.len, c.err.len);
        @memcpy(c.err[0..n], msg[0..n]);
        c.err_len = n;
    }

    fn begin(c: *Client, typ: u8) Error!void {
        c.buf.clearRetainingCapacity();
        try c.buf.appendNTimes(c.gpa, 0, 4);
        try c.put8(typ);
        try c.put16(1);
    }
    fn put8(c: *Client, v: u8) Error!void {
        try c.buf.append(c.gpa, v);
    }
    fn put16(c: *Client, v: u16) Error!void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, v, .little);
        try c.buf.appendSlice(c.gpa, &b);
    }
    fn put32(c: *Client, v: u32) Error!void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try c.buf.appendSlice(c.gpa, &b);
    }
    fn put64(c: *Client, v: u64) Error!void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, v, .little);
        try c.buf.appendSlice(c.gpa, &b);
    }
    fn putStr(c: *Client, s: []const u8) Error!void {
        try c.put16(@intCast(s.len));
        try c.buf.appendSlice(c.gpa, s);
    }

    fn writeAll(c: *Client, b: []const u8) Error!void {
        var off: usize = 0;
        while (off < b.len) {
            const n = std.c.write(c.fd, b[off..].ptr, b.len - off);
            if (n <= 0) return error.Io;
            off += @intCast(n);
        }
    }

    fn readFull(c: *Client, b: []u8) Error!void {
        var off: usize = 0;
        while (off < b.len) {
            const n = std.c.read(c.fd, b[off..].ptr, b.len - off);
            if (n <= 0) return error.Io;
            off += @intCast(n);
        }
    }

    /// Sends the request in `buf` and returns the reply's body, after
    /// type and tag, which stays valid until the next request.
    fn rpc(c: *Client) Error![]u8 {
        const typ = c.buf.items[4];
        std.mem.writeInt(u32, c.buf.items[0..4], @intCast(c.buf.items.len), .little);
        try c.writeAll(c.buf.items);
        var hdr: [4]u8 = undefined;
        try c.readFull(&hdr);
        const size = std.mem.readInt(u32, &hdr, .little);
        if (size < 7 or size > 1 << 20) return error.Protocol;
        c.buf.clearRetainingCapacity();
        try c.buf.resize(c.gpa, size - 4);
        try c.readFull(c.buf.items);
        const rtyp = c.buf.items[0];
        const body = c.buf.items[3..];
        if (rtyp == Rerror) {
            const n = std.mem.readInt(u16, body[0..2], .little);
            c.setErr(body[2..][0..n]);
            return error.Rerror;
        }
        if (rtyp != typ + 1) return error.Protocol;
        return body;
    }
};
