//! The other end of an `.fd` mount (design/epoch-0/fd-mounts.md) for
//! tests/backends.zig: a 9P2000 server over a tree in memory, small
//! enough to read, and a thread that serves it, or src/dotl/testserver.zig's
//! 9P2000.L one, on host descriptors the test holds, as an embedder's
//! in-process server would.

const std = @import("std");
const builtin = @import("builtin");

pub const fd_t = std.posix.fd_t;

/// A 9P2000 server over a tree in memory: walks, opens, reads, writes,
/// creates, removes, and stats, which is what devmnt asks of a mount and
/// of an `up` layer. Bytes go in with `feed`, and the replies collect in
/// `out`. A Tversion starts the session over, as 9P says, keeping the
/// tree.
pub const Mem9p = struct {
    gpa: std.mem.Allocator,
    root: *Node,
    next_path: u64 = 1,
    fids: std.AutoHashMapUnmanaged(u32, *Node) = .empty,
    in: std.ArrayList(u8) = .empty,
    out: std.ArrayList(u8) = .empty,
    /// How many Tversions it's had: one per run.
    versions: u32 = 0,
    /// The aname and uname of the last attach.
    aname: [64]u8 = undefined,
    aname_len: usize = 0,
    uname: [64]u8 = undefined,
    uname_len: usize = 0,

    pub const Node = struct {
        name: []u8,
        dir: bool,
        path: u64,
        data: std.ArrayList(u8) = .empty,
        children: std.ArrayList(*Node) = .empty,
        parent: ?*Node = null,
    };

    pub fn init(gpa: std.mem.Allocator) !*Mem9p {
        const s = try gpa.create(Mem9p);
        s.* = .{ .gpa = gpa, .root = undefined };
        s.root = try s.newNode("/", true, null);
        return s;
    }

    pub fn deinit(s: *Mem9p) void {
        s.freeNode(s.root);
        s.fids.deinit(s.gpa);
        s.in.deinit(s.gpa);
        s.out.deinit(s.gpa);
        s.gpa.destroy(s);
    }

    fn newNode(s: *Mem9p, name: []const u8, dir: bool, parent: ?*Node) !*Node {
        const n = try s.gpa.create(Node);
        n.* = .{ .name = try s.gpa.dupe(u8, name), .dir = dir, .path = s.next_path, .parent = parent };
        s.next_path += 1;
        if (parent) |p| try p.children.append(s.gpa, n);
        return n;
    }

    fn freeNode(s: *Mem9p, n: *Node) void {
        for (n.children.items) |c| s.freeNode(c);
        n.children.deinit(s.gpa);
        n.data.deinit(s.gpa);
        s.gpa.free(n.name);
        s.gpa.destroy(n);
    }

    /// Adds a file at `path`, with the directories above it.
    pub fn add(s: *Mem9p, path: []const u8, contents: []const u8) !void {
        var dir = s.root;
        var it = std.mem.tokenizeScalar(u8, path, '/');
        while (it.next()) |el| {
            if (it.peek() == null) {
                const f = try s.newNode(el, false, dir);
                try f.data.appendSlice(s.gpa, contents);
                return;
            }
            dir = child(dir, el) orelse try s.newNode(el, true, dir);
        }
    }

    /// The contents of the file at `path`, or null.
    pub fn read(s: *Mem9p, path: []const u8) ?[]const u8 {
        var n = s.root;
        var it = std.mem.tokenizeScalar(u8, path, '/');
        while (it.next()) |el| n = child(n, el) orelse return null;
        return n.data.items;
    }

    fn child(n: *Node, name: []const u8) ?*Node {
        for (n.children.items) |c| if (std.mem.eql(u8, c.name, name)) return c;
        return null;
    }

    pub fn feed(s: *Mem9p, bytes: []const u8) !void {
        try s.in.appendSlice(s.gpa, bytes);
        while (s.in.items.len >= 4) {
            const size = std.mem.readInt(u32, s.in.items[0..4], .little);
            if (size < 7) return error.BadMessage;
            if (s.in.items.len < size) return;
            try s.one(s.in.items[4..size]);
            s.in.replaceRangeAssumeCapacity(0, size, &.{});
        }
    }

    const Reply = struct {
        s: *Mem9p,
        start: usize,

        fn int(r: Reply, comptime T: type, v: T) !void {
            var b: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(T, &b, v, .little);
            try r.s.out.appendSlice(r.s.gpa, &b);
        }
        fn str(r: Reply, v: []const u8) !void {
            try r.int(u16, @intCast(v.len));
            try r.s.out.appendSlice(r.s.gpa, v);
        }
        fn qid(r: Reply, n: *const Node) !void {
            try r.s.out.append(r.s.gpa, if (n.dir) 0x80 else 0);
            try r.int(u32, 0);
            try r.int(u64, n.path);
        }
        fn done(r: Reply) void {
            const len: u32 = @intCast(r.s.out.items.len - r.start);
            std.mem.writeInt(u32, r.s.out.items[r.start..][0..4], len, .little);
        }
    };

    fn begin(s: *Mem9p, typ: u8, tag: u16) !Reply {
        const r: Reply = .{ .s = s, .start = s.out.items.len };
        try s.out.appendNTimes(s.gpa, 0, 4);
        try s.out.append(s.gpa, typ);
        try r.int(u16, tag);
        return r;
    }

    fn fail(s: *Mem9p, tag: u16, msg: []const u8) !void {
        const r = try s.begin(107, tag);
        try r.str(msg);
        r.done();
    }

    fn stat(s: *Mem9p, r: Reply, n: *const Node) !void {
        _ = s;
        const name = if (n.parent == null) "/" else n.name;
        const size: u16 = @intCast(2 + 4 + 13 + 4 + 4 + 4 + 8 + 2 + name.len + 3 * (2 + 4));
        try r.int(u16, size);
        try r.int(u16, 0);
        try r.int(u32, 0);
        try r.qid(n);
        try r.int(u32, if (n.dir) 0x800001ed else 0o644);
        try r.int(u32, 0);
        try r.int(u32, 0);
        try r.int(u64, if (n.dir) 0 else n.data.items.len);
        try r.str(name);
        try r.str("none");
        try r.str("none");
        try r.str("none");
    }

    fn one(s: *Mem9p, m: []const u8) !void {
        var c: Cursor = .{ .m = m, .o = 0 };
        const typ = try c.int(u8);
        const tag = try c.int(u16);
        switch (typ) {
            100 => { // Tversion
                const msize = try c.int(u32);
                s.fids.clearRetainingCapacity();
                s.versions += 1;
                const r = try s.begin(101, tag);
                try r.int(u32, @min(msize, 8192));
                try r.str("9P2000");
                r.done();
            },
            102 => try s.fail(tag, "no authentication required"),
            104 => { // Tattach
                const fid = try c.int(u32);
                _ = try c.int(u32);
                const un = try c.str();
                const an = try c.str();
                s.uname_len = @min(un.len, s.uname.len);
                @memcpy(s.uname[0..s.uname_len], un[0..s.uname_len]);
                s.aname_len = @min(an.len, s.aname.len);
                @memcpy(s.aname[0..s.aname_len], an[0..s.aname_len]);
                try s.fids.put(s.gpa, fid, s.root);
                const r = try s.begin(105, tag);
                try r.qid(s.root);
                r.done();
            },
            108 => (try s.begin(109, tag)).done(), // Tflush
            110 => { // Twalk
                const fid = try c.int(u32);
                const newfid = try c.int(u32);
                const nw = try c.int(u16);
                var n = s.fids.get(fid) orelse return s.fail(tag, "unknown fid");
                var qids: [16]*Node = undefined;
                var i: usize = 0;
                while (i < nw) : (i += 1) {
                    const name = try c.str();
                    const next = if (std.mem.eql(u8, name, "..")) n.parent orelse n else if (!n.dir) null else child(n, name);
                    if (next == null) break;
                    n = next.?;
                    qids[i] = n;
                }
                if (i == 0 and nw > 0) return s.fail(tag, "file does not exist");
                if (i == nw) try s.fids.put(s.gpa, newfid, n);
                const r = try s.begin(111, tag);
                try r.int(u16, @intCast(i));
                for (qids[0..i]) |q| try r.qid(q);
                r.done();
            },
            112 => { // Topen
                const fid = try c.int(u32);
                const mode = try c.int(u8);
                const n = s.fids.get(fid) orelse return s.fail(tag, "unknown fid");
                if (mode & 0x10 != 0 and !n.dir) n.data.clearRetainingCapacity();
                const r = try s.begin(113, tag);
                try r.qid(n);
                try r.int(u32, 0);
                r.done();
            },
            114 => { // Tcreate
                const fid = try c.int(u32);
                const name = try c.str();
                const perm = try c.int(u32);
                const dir = s.fids.get(fid) orelse return s.fail(tag, "unknown fid");
                if (child(dir, name) != null) return s.fail(tag, "file already exists");
                const n = try s.newNode(name, perm & 0x80000000 != 0, dir);
                try s.fids.put(s.gpa, fid, n);
                const r = try s.begin(115, tag);
                try r.qid(n);
                try r.int(u32, 0);
                r.done();
            },
            116 => { // Tread
                const fid = try c.int(u32);
                const off = try c.int(u64);
                const count = try c.int(u32);
                const n = s.fids.get(fid) orelse return s.fail(tag, "unknown fid");
                const r = try s.begin(117, tag);
                const at = s.out.items.len;
                try r.int(u32, 0);
                if (n.dir) {
                    // Whole entries from the one at `off`.
                    var pos: u64 = 0;
                    for (n.children.items) |ch| {
                        const before = s.out.items.len;
                        try s.stat(r, ch);
                        const len = s.out.items.len - before;
                        pos += len;
                        if (pos <= off) {
                            s.out.items.len = before;
                        } else if (s.out.items.len - at - 4 > count) {
                            s.out.items.len = before;
                            break;
                        }
                    }
                } else if (off < n.data.items.len) {
                    const d = n.data.items[@intCast(off)..];
                    try s.out.appendSlice(s.gpa, d[0..@min(d.len, count)]);
                }
                std.mem.writeInt(u32, s.out.items[at..][0..4], @intCast(s.out.items.len - at - 4), .little);
                r.done();
            },
            118 => { // Twrite
                const fid = try c.int(u32);
                const off: usize = @intCast(try c.int(u64));
                const count = try c.int(u32);
                const data = try c.bytes(count);
                const n = s.fids.get(fid) orelse return s.fail(tag, "unknown fid");
                if (n.data.items.len < off + data.len) try n.data.appendNTimes(s.gpa, 0, off + data.len - n.data.items.len);
                @memcpy(n.data.items[off..][0..data.len], data);
                const r = try s.begin(119, tag);
                try r.int(u32, count);
                r.done();
            },
            120 => { // Tclunk
                _ = s.fids.remove(try c.int(u32));
                (try s.begin(121, tag)).done();
            },
            122 => { // Tremove
                const fid = try c.int(u32);
                const n = s.fids.get(fid) orelse return s.fail(tag, "unknown fid");
                _ = s.fids.remove(fid);
                const p = n.parent orelse return s.fail(tag, "can't remove the root");
                for (p.children.items, 0..) |ch, i| if (ch == n) {
                    _ = p.children.orderedRemove(i);
                    break;
                };
                s.freeNode(n);
                (try s.begin(123, tag)).done();
            },
            124 => { // Tstat
                const n = s.fids.get(try c.int(u32)) orelse return s.fail(tag, "unknown fid");
                const r = try s.begin(125, tag);
                const at = s.out.items.len;
                try r.int(u16, 0);
                try s.stat(r, n);
                std.mem.writeInt(u16, s.out.items[at..][0..2], @intCast(s.out.items.len - at - 2), .little);
                r.done();
            },
            126 => (try s.begin(127, tag)).done(), // Twstat: kept as is
            else => try s.fail(tag, "not supported"),
        }
    }

    const Cursor = struct {
        m: []const u8,
        o: usize,
        fn int(c: *Cursor, comptime T: type) !T {
            if (c.o + @sizeOf(T) > c.m.len) return error.BadMessage;
            defer c.o += @sizeOf(T);
            return std.mem.readInt(T, c.m[c.o..][0..@sizeOf(T)], .little);
        }
        fn bytes(c: *Cursor, n: usize) ![]const u8 {
            if (c.o + n > c.m.len) return error.BadMessage;
            defer c.o += n;
            return c.m[c.o..][0..n];
        }
        fn str(c: *Cursor) ![]const u8 {
            return c.bytes(try c.int(u16));
        }
    };
};

/// Serves `S` (Mem9p, or the 9P2000.L test server, anything with `feed`
/// and `out`) on host descriptors `rd` and `wr` in a thread of its own,
/// until `rd` reaches its end: when the test closes its end, which it
/// can only see once h9 has closed its copies. The test looks at the
/// server after `join`.
pub fn Pump(comptime S: type) type {
    return struct {
        server: *S,
        rd: fd_t,
        wr: fd_t,
        thread: std.Thread = undefined,
        err: ?anyerror = null,

        const Self = @This();

        pub fn start(p: *Self) !void {
            p.thread = try std.Thread.spawn(.{}, run, .{p});
        }

        pub fn join(p: *Self) void {
            p.thread.join();
        }

        fn run(p: *Self) void {
            p.loop() catch |e| {
                p.err = e;
            };
        }

        fn loop(p: *Self) !void {
            var buf: [1 << 16]u8 = undefined;
            while (true) {
                const n = try readFd(p.rd, &buf);
                if (n == 0) return;
                try p.server.feed(buf[0..n]);
                if (p.server.out.items.len > 0) {
                    try writeFd(p.wr, p.server.out.items);
                    p.server.out.items.len = 0;
                }
            }
        }
    };
}

/// Reads what `fd` has, 0 at its end (or a broken pipe on Windows).
pub fn readFd(fd: fd_t, buf: []u8) !usize {
    if (builtin.os.tag == .windows) {
        var got: u32 = 0;
        if (!win.ReadFile(fd, buf.ptr, @intCast(buf.len), &got, null).toBool()) return 0;
        return got;
    }
    while (true) {
        const n = std.c.read(fd, buf.ptr, buf.len);
        if (n >= 0) return @intCast(n);
        const e = std.c._errno().*;
        if (e == @backingInt(std.c.E.INTR)) continue;
        // The other end closed with a reply it hadn't read: at the end of
        // a test, when the test closes its end after the run.
        if (e == @backingInt(std.c.E.CONNRESET)) return 0;
        std.debug.print("read: errno {d}\n", .{e});
        return error.ReadFailed;
    }
}

pub fn writeFd(fd: fd_t, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        if (builtin.os.tag == .windows) {
            var put: u32 = 0;
            if (!win.WriteFile(fd, data[off..].ptr, @intCast(data.len - off), &put, null).toBool()) return error.WriteFailed;
            off += put;
            continue;
        }
        const n = std.c.write(fd, data[off..].ptr, data.len - off);
        if (n < 0) {
            if (std.c._errno().* == @backingInt(std.c.E.INTR)) continue;
            return error.WriteFailed;
        }
        off += @intCast(n);
    }
}

pub fn closeFd(fd: fd_t) void {
    if (builtin.os.tag == .windows) {
        _ = win.CloseHandle(fd);
    } else _ = std.c.close(fd);
}

/// A connected stream pair: a socketpair on POSIX.
pub fn socketPair() ![2]fd_t {
    if (builtin.os.tag == .windows) {
        return error.SkipZigTest;
    } else {
        var sv: [2]std.c.fd_t = undefined;
        if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &sv) != 0) return error.SocketPair;
        return sv;
    }
}

/// A pipe: the end read from, then the end written to.
pub fn pipe() ![2]fd_t {
    if (builtin.os.tag == .windows) {
        var r: fd_t = undefined;
        var w: fd_t = undefined;
        if (!win.CreatePipe(&r, &w, null, 0).toBool()) return error.Pipe;
        return .{ r, w };
    }
    var p: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&p) != 0) return error.Pipe;
    return p;
}

/// Whether `fd` is still open in this process.
pub fn isOpen(fd: fd_t) bool {
    if (builtin.os.tag == .windows) {
        var flags: u32 = 0;
        return win.GetHandleInformation(fd, &flags).toBool();
    }
    return std.c.fcntl(fd, std.c.F.GETFD, @as(c_int, 0)) >= 0;
}

pub const win = struct {
    const w = std.os.windows;
    pub extern "kernel32" fn ReadFile(h: w.HANDLE, buf: [*]u8, n: u32, got: *u32, ov: ?*anyopaque) callconv(.winapi) w.BOOL;
    pub extern "kernel32" fn WriteFile(h: w.HANDLE, buf: [*]const u8, n: u32, put: *u32, ov: ?*anyopaque) callconv(.winapi) w.BOOL;
    pub extern "kernel32" fn CloseHandle(h: w.HANDLE) callconv(.winapi) w.BOOL;
    pub extern "kernel32" fn CreatePipe(r: *w.HANDLE, wr: *w.HANDLE, sa: ?*anyopaque, size: u32) callconv(.winapi) w.BOOL;
    pub extern "kernel32" fn GetHandleInformation(h: w.HANDLE, flags: *u32) callconv(.winapi) w.BOOL;
};

/// Some descriptor, for the cases that never use it.
pub const std_out: fd_t = if (builtin.os.tag == .windows) @ptrFromInt(4) else 1;

/// A winsock TCP socket, for the case that an `.fd` mount refuses one.
pub fn winSocket() !fd_t {
    var data: [400]u8 align(8) = undefined;
    if (ws.WSAStartup(0x0202, &data) != 0) return error.WinsockFailed;
    const s = ws.socket(2, 1, 6); // AF_INET, SOCK_STREAM, IPPROTO_TCP
    if (@intFromPtr(s) == std.math.maxInt(usize)) return error.SocketFailed;
    return s;
}

pub fn winCloseSocket(s: fd_t) void {
    _ = ws.closesocket(s);
    _ = ws.WSACleanup();
}

const ws = struct {
    extern "ws2_32" fn WSAStartup(version: u16, data: *anyopaque) callconv(.winapi) i32;
    extern "ws2_32" fn WSACleanup() callconv(.winapi) i32;
    extern "ws2_32" fn socket(af: i32, typ: i32, proto: i32) callconv(.winapi) std.os.windows.HANDLE;
    extern "ws2_32" fn closesocket(s: std.os.windows.HANDLE) callconv(.winapi) i32;
};
