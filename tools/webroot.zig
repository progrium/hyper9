//! Makes the browser host's root archive (design/0012-browser-host.md)
//! from a root tree and a list of paths in it:
//!
//!     webroot ROOT LIST OUT
//!
//! Each line of LIST is a path relative to ROOT: a file, or a directory
//! taken whole. A path ending in `/` is a directory taken empty, such as a
//! mount point, and `#` starts a comment. Directories above each path are
//! added too. src/web/worker.js reads the archive:
//!
//!     "h9root1\n"
//!     entries, each: u32 path length, path, u32 mode, u32 size, data
//!
//! little-endian, with POSIX modes (S_IFDIR for directories, which have no
//! data), in path order.

const std = @import("std");

const S_IFDIR: u32 = 0o040000;
const S_IFREG: u32 = 0o100000;

const Entry = struct {
    path: []const u8,
    mode: u32,
    /// The file's host path; null for a directory.
    src: ?[]const u8,
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len != 4) {
        std.debug.print("usage: webroot ROOT LIST OUT\n", .{});
        return 2;
    }
    const root_path = argv[1];
    const cwd = std.Io.Dir.cwd();
    var root = try cwd.openDir(io, root_path, .{ .iterate = true });
    defer root.close(io);
    const list = try cwd.readFileAlloc(io, argv[2], arena, .limited(1 << 20));

    var entries: std.StringArrayHashMapUnmanaged(Entry) = .empty;
    var lines = std.mem.splitScalar(u8, list, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, if (std.mem.indexOfScalar(u8, raw, '#')) |i| raw[0..i] else raw, " \t\r");
        if (line.len == 0) continue;
        const empty = line[line.len - 1] == '/';
        const path = std.mem.trimEnd(u8, line, "/");
        try addParents(arena, &entries, path);
        if (empty) {
            try entries.put(arena, path, .{ .path = path, .mode = S_IFDIR | 0o775, .src = null });
            continue;
        }
        const st = root.statFile(io, path, .{}) catch |err| {
            std.debug.print("webroot: {s}/{s}: {t}\n", .{ root_path, path, err });
            return 1;
        };
        if (st.kind != .directory) {
            try entries.put(arena, path, .{ .path = path, .mode = S_IFREG | fileMode(st), .src = path });
            continue;
        }
        try entries.put(arena, path, .{ .path = path, .mode = S_IFDIR | fileMode(st), .src = null });
        var dir = try root.openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(arena);
        defer walker.deinit();
        while (try walker.next(io)) |e| {
            const p = try std.fmt.allocPrint(arena, "{s}/{s}", .{ path, e.path });
            const est = try dir.statFile(io, e.path, .{});
            const dirp = est.kind == .directory;
            try entries.put(arena, p, .{ .path = p, .mode = (if (dirp) S_IFDIR else S_IFREG) | fileMode(est), .src = if (dirp) null else p });
        }
    }

    const Ctx = struct {
        keys: [][]const u8,
        pub fn lessThan(c: @This(), a: usize, b: usize) bool {
            return std.mem.order(u8, c.keys[a], c.keys[b]) == .lt;
        }
    };
    entries.sort(Ctx{ .keys = entries.keys() });

    var out_file = try cwd.createFile(io, argv[3], .{});
    defer out_file.close(io);
    var buf: [1 << 16]u8 = undefined;
    var fw = out_file.writer(io, &buf);
    const w = &fw.interface;
    try w.writeAll("h9root1\n");
    for (entries.values()) |e| {
        const data: []const u8 = if (e.src) |s| try root.readFileAlloc(io, s, arena, .limited(1 << 30)) else "";
        try w.writeInt(u32, @intCast(e.path.len), .little);
        try w.writeAll(e.path);
        try w.writeInt(u32, e.mode, .little);
        try w.writeInt(u32, @intCast(data.len), .little);
        try w.writeAll(data);
    }
    try w.flush();
    return 0;
}

fn fileMode(st: std.Io.File.Stat) u32 {
    if (@TypeOf(st.permissions) == void) return 0o775;
    return @intCast(st.permissions.toMode() & 0o777);
}

/// Adds the directories above `path`.
fn addParents(arena: std.mem.Allocator, entries: *std.StringArrayHashMapUnmanaged(Entry), path: []const u8) !void {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, path, i, '/')) |j| : (i = j + 1) {
        const p = path[0..j];
        if (!entries.contains(p)) try entries.put(arena, p, .{ .path = p, .mode = S_IFDIR | 0o775, .src = null });
    }
}
