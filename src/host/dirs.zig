//! Native directory handles (design/host-handles.md, "Files beneath a
//! handle"): opening each tree a plan allows before the machine starts,
//! and `hostDir`, which src/host/dirs.c asks for the handle that holds a
//! host path. The opens beneath a handle are in src/host/dirs.c, beside
//! devfs's C.

const std = @import("std");
const builtin = @import("builtin");
const host = @import("host.zig");

const windows = builtin.os.tag == .windows;
/// Whether this host opens trees as handles: not the web host, whose
/// trees are WASI preopens already.
pub const supported = builtin.os.tag != .wasi and builtin.os.tag != .freestanding;

const Handle = host.Handle;

pub const Opened = struct { handle: Handle, leaf: ?[]const u8 = null };

/// Opens the tree at host path `path`, in the policy's spelling (`/C:/a/b`
/// on Windows): its directory, or for a file its parent's and its name.
/// Null if it can't be opened; its files are then unreachable.
pub fn openTree(arena: std.mem.Allocator, path: []const u8) ?Opened {
    if (comptime !supported) return null;
    if (openDir(arena, path)) |h| return .{ .handle = h };
    const dir = parentOf(path) orelse return null;
    const h = openDir(arena, dir) orelse return null;
    return .{ .handle = h, .leaf = path[if (dir.len == 1) 1 else dir.len + 1 ..] };
}

pub fn closeTree(h: Handle) void {
    if (comptime !supported) return;
    if (h == host.no_handle) return;
    if (windows) _ = CloseHandle(h) else _ = std.c.close(h);
}

/// `/a/b`'s `/a`, `/a`'s `/`, and `/C:/a`'s `/C:`; null for `/` and `/C:`.
fn parentOf(path: []const u8) ?[]const u8 {
    const i = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
    if (windows) {
        if (path.len <= 3) return null;
        return if (i <= 3) path[0..3] else path[0..i];
    }
    if (path.len <= 1) return null;
    return if (i == 0) "/" else path[0..i];
}

fn openDir(arena: std.mem.Allocator, path: []const u8) ?Handle {
    if (windows) {
        const w = longPath(arena, path) orelse return null;
        const h = CreateFileW(w.ptr, FILE_LIST_DIRECTORY | FILE_TRAVERSE | FILE_READ_ATTRIBUTES | SYNCHRONIZE, FILE_SHARE_ALL, null, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, null);
        if (h == host.no_handle) return null;
        // A file opens with backup semantics too: only a directory is a tree's handle.
        var info: BY_HANDLE_FILE_INFORMATION = undefined;
        if (GetFileInformationByHandle(h, &info) == 0 or info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY == 0) {
            _ = CloseHandle(h);
            return null;
        }
        return h;
    }
    const z = arena.dupeSentinel(u8, path, 0) catch return null;
    // O_PATH on Linux: a handle reads nothing itself, so a directory the
    // user can search but not list is a tree too.
    var o: std.c.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };
    if (builtin.os.tag == .linux) o.PATH = true;
    const fd = std.c.open(z, o);
    return if (fd < 0) null else fd;
}

/// `/C:/a/b` as `\\?\C:\a\b`, NUL-terminated: a drive path the Win32
/// calls take whatever its names are.
fn longPath(arena: std.mem.Allocator, path: []const u8) ?[:0]const u16 {
    if (path.len < 3 or path[0] != '/' or path[2] != ':') return null;
    var s: std.ArrayList(u8) = .empty;
    s.appendSlice(arena, "\\\\?\\") catch return null;
    s.appendSlice(arena, path[1..3]) catch return null;
    s.append(arena, '\\') catch return null;
    if (path.len > 4) for (path[4..]) |c| s.append(arena, if (c == '/') '\\' else c) catch return null;
    return std.unicode.utf8ToUtf16LeAllocZ(arena, s.items) catch null;
}

/// What src/host/dirs.c's `h9_host_dir` returns besides a handle.
pub const none: i64 = -2;
pub const outside: i64 = -3;
pub const too_long: i64 = -4;

/// The handle of `h` that holds host path `path`, with the path relative
/// to it in `rel` (NUL-terminated, '/'-separated, "." for its top) and
/// whether it's contained in `contained`: `outside` if none does.
pub fn hostDir(h: *const host.Host, path: []const u8, rel: []u8, contained: *bool) i64 {
    const d = h.dirs orelse return outside;
    const o = d.opened(path) orelse return outside;
    var r = o.rel;
    var buf: [2]u8 = undefined;
    if (o.dir.leaf) |leaf| {
        const n = leaf.len + @intFromBool(r.len > 0) + r.len;
        if (n + 1 > rel.len) return too_long;
        @memcpy(rel[0..leaf.len], leaf);
        if (r.len > 0) {
            rel[leaf.len] = '/';
            @memcpy(rel[leaf.len + 1 ..][0..r.len], r);
        }
        rel[n] = 0;
    } else {
        if (r.len == 0) {
            buf = .{ '.', 0 };
            r = buf[0..1];
        }
        if (r.len + 1 > rel.len) return too_long;
        @memcpy(rel[0..r.len], r);
        rel[r.len] = 0;
    }
    contained.* = o.dir.contained;
    return if (windows) @bitCast(@as(u64, @intFromPtr(o.dir.handle))) else o.dir.handle;
}

// Windows: the calls openDir makes.
const W = std.os.windows;
const FILE_LIST_DIRECTORY: u32 = 0x0001;
const FILE_TRAVERSE: u32 = 0x0020;
const FILE_READ_ATTRIBUTES: u32 = 0x0080;
const SYNCHRONIZE: u32 = 0x00100000;
const FILE_SHARE_ALL: u32 = 0x7;
const OPEN_EXISTING: u32 = 3;
const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x02000000;
const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;
const BY_HANDLE_FILE_INFORMATION = extern struct {
    dwFileAttributes: u32,
    ftCreationTime: [2]u32,
    ftLastAccessTime: [2]u32,
    ftLastWriteTime: [2]u32,
    dwVolumeSerialNumber: u32,
    nFileSizeHigh: u32,
    nFileSizeLow: u32,
    nNumberOfLinks: u32,
    nFileIndexHigh: u32,
    nFileIndexLow: u32,
};
extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, sa: ?*anyopaque, disp: u32, flags: u32, tmpl: ?W.HANDLE) callconv(.winapi) W.HANDLE;
extern "kernel32" fn CloseHandle(h: W.HANDLE) callconv(.winapi) c_int;
extern "kernel32" fn GetFileInformationByHandle(h: W.HANDLE, info: *BY_HANDLE_FILE_INFORMATION) callconv(.winapi) c_int;

test "a tree is its directory's handle, or a file's parent and name [host-handles]" {
    if (comptime !supported or windows) return error.SkipZigTest;
    var ar: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer ar.deinit();
    try std.testing.expectEqualStrings("/", parentOf("/a").?);
    try std.testing.expectEqualStrings("/a", parentOf("/a/b").?);
    try std.testing.expect(parentOf("/") == null);
    const root = openTree(ar.allocator(), "/").?;
    defer closeTree(root.handle);
    try std.testing.expect(root.leaf == null);
    try std.testing.expect(openTree(ar.allocator(), "/nonexistent-h9-path/x") == null);
}

// src/host/dirs.c, for the case below.
extern fn h9_host_open(path: [*:0]const u8, flags: c_int, mode: c_int, nolinks: c_int) c_int;
extern fn h9_host_test_noopenat2(on: c_int) void;

const Escape = struct {
    top: [:0]const u8,
    stop: std.atomic.Value(bool) = .init(false),
    swaps: std.atomic.Value(u32) = .init(0),

    fn z(buf: []u8, comptime fmt: []const u8, args: anytype) [*:0]const u8 {
        return (std.fmt.bufPrintSentinel(buf, fmt, args, 0) catch unreachable).ptr;
    }

    /// Puts the directory and then the link at `tree/sub`, over and over:
    /// each rename replaces it whole, so a walk sees one or the other.
    fn swap(e: *Escape) void {
        var a: [512]u8 = undefined;
        var b: [512]u8 = undefined;
        var c: [512]u8 = undefined;
        const sub = z(&a, "{s}/tree/sub", .{e.top});
        const dir = z(&b, "{s}/tree/sub.dir", .{e.top});
        const lnk = z(&c, "{s}/tree/sub.lnk", .{e.top});
        while (!e.stop.load(.acquire)) {
            _ = std.c.rename(dir, sub);
            _ = std.c.rename(sub, dir);
            _ = std.c.rename(lnk, sub);
            _ = std.c.rename(sub, lnk);
            _ = e.swaps.fetchAdd(1, .release);
        }
    }
};

fn writeFile(path: [*:0]const u8, data: []const u8) !void {
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.Create;
    defer _ = std.c.close(fd);
    if (std.c.write(fd, data.ptr, data.len) != @as(isize, @intCast(data.len))) return error.Write;
}

test "a symlink swapped in mid-walk can't escape a handle [host-handles]" {
    if (comptime !supported) return error.SkipZigTest;
    if (comptime windows) try win.escape() else try escapePosix();
}

fn escapePosix() !void {
    const kern = @import("../kern.zig");
    const policy = @import("../policy.zig");
    if (!kern.available) return error.SkipZigTest;
    var ar: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // T/tree/sub.dir/file is inside; T/tree/sub.lnk is a link out of the
    // tree, to T/out, whose file is outside.
    const top = try std.fmt.allocPrintSentinel(a, "/tmp/h9-escape-{d}", .{std.c.getpid()}, 0);
    var e: Escape = .{ .top = top };
    var p: [8][512]u8 = undefined;
    const paths = [_][*:0]const u8{
        Escape.z(&p[0], "{s}", .{top}),
        Escape.z(&p[1], "{s}/tree", .{top}),
        Escape.z(&p[2], "{s}/tree/sub.dir", .{top}),
        Escape.z(&p[3], "{s}/out", .{top}),
    };
    for (paths) |d| _ = std.c.mkdir(d, 0o755);
    const in_file = Escape.z(&p[4], "{s}/tree/sub.dir/file", .{top});
    const out_file = Escape.z(&p[5], "{s}/out/file", .{top});
    const lnk = Escape.z(&p[6], "{s}/tree/sub.lnk", .{top});
    try writeFile(in_file, "inside");
    try writeFile(out_file, "outside");
    _ = std.c.symlink(Escape.z(&p[7], "{s}/out", .{top}), lnk);
    defer {
        var q: [512]u8 = undefined;
        // Whichever is at tree/sub when the swaps stop.
        _ = std.c.rename(Escape.z(&q, "{s}/tree/sub", .{top}), Escape.z(&p[7], "{s}/tree/sub.x", .{top}));
        _ = std.c.unlink(Escape.z(&q, "{s}/tree/sub.x/file", .{top}));
        _ = std.c.unlink(Escape.z(&q, "{s}/tree/sub.x", .{top}));
        _ = std.c.rmdir(Escape.z(&q, "{s}/tree/sub.x", .{top}));
        _ = std.c.unlink(in_file);
        _ = std.c.unlink(out_file);
        _ = std.c.unlink(lnk);
        var i: usize = paths.len;
        while (i > 0) {
            i -= 1;
            _ = std.c.rmdir(paths[i]);
        }
    }

    // A machine whose only tree is T/tree.
    var msg: []const u8 = "";
    const tree = try std.fmt.allocPrint(a, "{s}/tree", .{top});
    var plan = try policy.compile(a, .{ .mounts = &.{}, .cwd = null, .arch = .amd64 }, .{ .readable = &.{tree} }, &msg);
    const h = try host.fromPlan(a, std.testing.io, &plan, .{ .open_dirs = true });
    defer host.closeDirs(h);
    try std.testing.expect(h.dirs.?.opened(tree) != null);
    plan.host = &h;
    kern.setPlan(&plan);
    defer kern.setPlan(null);

    const th = try std.Thread.spawn(.{}, Escape.swap, .{&e});
    defer {
        e.stop.store(true, .release);
        th.join();
    }
    var pb: [512]u8 = undefined;
    const path = Escape.z(&pb, "{s}/tree/sub/file", .{top});
    // openat2 on Linux, or O_RESOLVE_BENEATH on macOS, then the walk of
    // a name at a time that the BSDs and older kernels use; each following
    // links, and as a Linux process's walk, following none.
    var inside: u32 = 0;
    for ([_]c_int{ 0, 1 }) |walk| {
        h9_host_test_noopenat2(walk);
        defer h9_host_test_noopenat2(0);
        const start = e.swaps.load(.acquire);
        var n: u32 = 0;
        while (n < 20000 or e.swaps.load(.acquire) < start + 50) : (n += 1) {
            for ([_]c_int{ 0, 1 }) |nolinks| {
                const fd = h9_host_open(path, @bitCast(std.c.O{ .ACCMODE = .RDONLY }), 0, nolinks);
                if (fd < 0) continue;
                defer _ = std.c.close(fd);
                var buf: [16]u8 = undefined;
                const k = std.c.read(fd, &buf, buf.len);
                try std.testing.expectEqualStrings("inside", buf[0..@intCast(@max(k, 0))]);
                inside += 1;
            }
            if (n > 2_000_000) break;
        }
    }
    try std.testing.expect(inside > 0);
}

// Windows: the same swap, with a directory symbolic link (which needs
// Developer Mode or the privilege to make; without it the case skips),
// opened through devfs-win32's CreateFile (src/host/dirs.c).
const win = struct {
    extern "kernel32" fn GetTempPathW(n: u32, buf: [*]u16) callconv(.winapi) u32;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
    extern "kernel32" fn CreateDirectoryW(path: [*:0]const u16, sa: ?*anyopaque) callconv(.winapi) c_int;
    extern "kernel32" fn RemoveDirectoryW(path: [*:0]const u16) callconv(.winapi) c_int;
    extern "kernel32" fn DeleteFileW(path: [*:0]const u16) callconv(.winapi) c_int;
    extern "kernel32" fn MoveFileW(old: [*:0]const u16, new: [*:0]const u16) callconv(.winapi) c_int;
    extern "kernel32" fn CreateSymbolicLinkW(link: [*:0]const u16, target: [*:0]const u16, flags: u32) callconv(.winapi) u8;
    extern "kernel32" fn WriteFile(h: W.HANDLE, buf: [*]const u8, n: u32, got: ?*u32, ov: ?*anyopaque) callconv(.winapi) c_int;
    extern "kernel32" fn ReadFile(h: W.HANDLE, buf: [*]u8, n: u32, got: ?*u32, ov: ?*anyopaque) callconv(.winapi) c_int;
    extern fn h9_host_createfilew(path: [*:0]const u16, access: u32, share: u32, sa: ?*anyopaque, disp: u32, flags: u32, out: *W.HANDLE) c_int;
    const GENERIC_READ: u32 = 0x80000000;
    const GENERIC_WRITE: u32 = 0x40000000;
    const CREATE_ALWAYS: u32 = 2;

    fn w(a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]const u16 {
        return std.unicode.utf8ToUtf16LeAllocZ(a, try std.fmt.allocPrint(a, fmt, args));
    }

    const Swap = struct {
        sub: [:0]const u16,
        dir: [:0]const u16,
        lnk: [:0]const u16,
        stop: std.atomic.Value(bool) = .init(false),
        swaps: std.atomic.Value(u32) = .init(0),

        fn run(s: *Swap) void {
            while (!s.stop.load(.acquire)) {
                _ = MoveFileW(s.dir, s.sub);
                _ = MoveFileW(s.sub, s.dir);
                _ = MoveFileW(s.lnk, s.sub);
                _ = MoveFileW(s.sub, s.lnk);
                _ = s.swaps.fetchAdd(1, .release);
            }
        }
    };

    fn escape() !void {
        const kern = @import("../kern.zig");
        const policy = @import("../policy.zig");
        if (!kern.available) return error.SkipZigTest;
        var ar: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer ar.deinit();
        const a = ar.allocator();
        var tb: [600]u16 = undefined;
        const tn = GetTempPathW(tb.len, &tb);
        if (tn == 0 or tn >= tb.len) return error.SkipZigTest;
        const tmp = try std.unicode.utf16LeToUtf8Alloc(a, tb[0..tn]);
        const top = try std.fmt.allocPrint(a, "{s}h9-escape-{d}", .{ std.mem.trimEnd(u8, tmp, "\\"), GetCurrentProcessId() });
        for ([_][]const u8{ "", "\\tree", "\\tree\\sub.dir", "\\out" }) |d| _ = CreateDirectoryW(try w(a, "{s}{s}", .{ top, d }), null);
        const in_file = try w(a, "{s}\\tree\\sub.dir\\file", .{top});
        const out_file = try w(a, "{s}\\out\\file", .{top});
        for ([_]struct { [:0]const u16, []const u8 }{ .{ in_file, "inside" }, .{ out_file, "outside" } }) |f| {
            const h = CreateFileW(f[0], GENERIC_WRITE, FILE_SHARE_ALL, null, CREATE_ALWAYS, 0, null);
            if (h == host.no_handle) return error.Create;
            _ = WriteFile(h, f[1].ptr, @intCast(f[1].len), null, null);
            _ = CloseHandle(h);
        }
        var sw: Swap = .{ .sub = try w(a, "{s}\\tree\\sub", .{top}), .dir = try w(a, "{s}\\tree\\sub.dir", .{top}), .lnk = try w(a, "{s}\\tree\\sub.lnk", .{top}) };
        // A directory link, made unprivileged where Developer Mode allows it.
        const made = CreateSymbolicLinkW(sw.lnk, try w(a, "{s}\\out", .{top}), 0x1 | 0x2) != 0;
        defer {
            _ = MoveFileW(sw.sub, sw.dir);
            _ = DeleteFileW(in_file);
            _ = DeleteFileW(out_file);
            _ = RemoveDirectoryW(sw.lnk);
            for ([_][]const u8{ "\\tree\\sub.dir", "\\out", "\\tree", "" }) |d| _ = RemoveDirectoryW(w(a, "{s}{s}", .{ top, d }) catch continue);
        }
        if (!made) return error.SkipZigTest;

        // The policy's spelling of the tree, "/C:/...".
        var msg: []const u8 = "";
        const tree = try std.fmt.allocPrint(a, "/{s}/tree", .{top});
        for (tree) |*c| if (c.* == '\\') {
            c.* = '/';
        };
        var plan = try policy.compile(a, .{ .mounts = &.{}, .cwd = null, .arch = .amd64 }, .{ .readable = &.{tree} }, &msg);
        const h = try host.fromPlan(a, std.testing.io, &plan, .{ .open_dirs = true });
        defer host.closeDirs(h);
        try std.testing.expect(h.dirs.?.opened(tree) != null);
        plan.host = &h;
        kern.setPlan(&plan);
        defer kern.setPlan(null);

        const th = try std.Thread.spawn(.{}, Swap.run, .{&sw});
        defer {
            sw.stop.store(true, .release);
            th.join();
        }
        const path = try w(a, "{s}\\tree\\sub\\file", .{top});
        var inside: u32 = 0;
        var n: u32 = 0;
        while (n < 20000 or sw.swaps.load(.acquire) < 50) : (n += 1) {
            for ([_]u32{ 0, 0x00200000 }) |flags| { // FILE_FLAG_OPEN_REPARSE_POINT: a Linux process's open
                var fh: W.HANDLE = undefined;
                if (h9_host_createfilew(path, GENERIC_READ, FILE_SHARE_ALL, null, OPEN_EXISTING, flags, &fh) == 0) return error.NoHost;
                if (fh == host.no_handle) continue;
                defer _ = CloseHandle(fh);
                var buf: [16]u8 = undefined;
                var got: u32 = 0;
                _ = ReadFile(fh, &buf, buf.len, &got, null);
                try std.testing.expectEqualStrings("inside", buf[0..got]);
                inside += 1;
            }
            if (n > 2_000_000) break;
        }
        try std.testing.expect(inside > 0);
    }
};
