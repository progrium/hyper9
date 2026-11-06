//! h9's own guest commands (design/0032-guest-tools.md): the tree under
//! src/guest/, read by build.zig at configure time and written out as a
//! Zig table that src/kern.zig hands to `#H` (src/kern/devhtools.c).
//!
//! Only rc scripts and data go in the tree. A file is executable (0555)
//! when its repository mode is, and then it must start with `#!/bin/rc`;
//! any other file is data (0444). Directories are 0555. Names starting
//! with `.` are left out, so a `.gitkeep` can hold an empty directory.

const std = @import("std");

/// A file found in a tree, by its guest path relative to the tree's top
/// (`bin/wsmount`), with `/` separators.
pub const Input = struct {
    path: []const u8,
    exec: bool,
    data: []const u8,
};

/// One entry of the table. Entry 0 is the top directory, with an empty
/// name; every other entry comes after its parent, so an entry's index is
/// its qid path and stays the same from one run of a build to the next.
pub const Entry = struct {
    name: []const u8,
    parent: u32,
    dir: bool,
    exec: bool = false,
    data: []const u8 = "",
};

/// Directories the tree always has, even with nothing in them.
const always = [_][]const u8{"bin"};

pub const rc_magic = "#!/bin/rc";

/// Why `in` can't be in the tree, or null when it can.
pub fn reject(in: Input) ?[]const u8 {
    if (in.exec and !std.mem.startsWith(u8, in.data, rc_magic))
        return "is executable but isn't an rc script (it must start with " ++ rc_magic ++ ")";
    return null;
}

pub const BuildError = error{ OutOfMemory, Rejected };

/// The table for `inputs`, from any number of trees. `why` names the
/// file and the reason on Rejected.
pub fn build(arena: std.mem.Allocator, inputs: []const Input, why: *[]const u8) BuildError![]Entry {
    var paths: std.StringArrayHashMapUnmanaged(?Input) = .empty;
    for (always) |d| try paths.put(arena, d, null);
    for (inputs) |in| {
        if (reject(in)) |r| {
            why.* = try std.fmt.allocPrint(arena, "{s} {s}", .{ in.path, r });
            return error.Rejected;
        }
        // Every ancestor is a directory.
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, in.path, i, '/')) |slash| : (i = slash + 1) {
            const d = in.path[0..slash];
            if (paths.get(d)) |prev| if (prev != null) {
                why.* = try std.fmt.allocPrint(arena, "{s} is a file and a directory", .{d});
                return error.Rejected;
            };
            try paths.put(arena, d, null);
        }
        const gop = try paths.getOrPut(arena, in.path);
        if (gop.found_existing) {
            why.* = try std.fmt.allocPrint(arena, "{s} is in the tree twice", .{in.path});
            return error.Rejected;
        }
        gop.value_ptr.* = in;
    }

    // Sorted, a directory comes before everything in it.
    const keys = try arena.dupe([]const u8, paths.keys());
    std.mem.sort([]const u8, keys, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    var index: std.StringHashMapUnmanaged(u32) = .empty;
    var out: std.ArrayList(Entry) = .empty;
    try out.append(arena, .{ .name = "", .parent = 0, .dir = true });
    try index.put(arena, "", 0);
    for (keys) |p| {
        const slash = std.mem.lastIndexOfScalar(u8, p, '/');
        const parent = index.get(if (slash) |s| p[0..s] else "").?;
        const name = if (slash) |s| p[s + 1 ..] else p;
        try index.put(arena, p, @intCast(out.items.len));
        try out.append(arena, if (paths.get(p).?) |in|
            .{ .name = name, .parent = parent, .dir = false, .exec = in.exec, .data = in.data }
        else
            .{ .name = name, .parent = parent, .dir = true });
    }
    return out.items;
}

/// Reads every file under `dir`, leaving out names that start with `.`.
/// On a host without executable bits (Windows), a file is executable when
/// it starts with `#!`.
pub fn scan(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) ![]Input {
    var out: std.ArrayList(Input) = .empty;
    var w = try dir.walk(arena);
    defer w.deinit();
    while (try w.next(io)) |e| {
        if (hidden(e.path)) continue;
        switch (e.kind) {
            .directory => continue,
            .file => {},
            else => return error.NotAFile,
        }
        const data = try e.dir.readFileAlloc(io, e.basename, arena, .limited(1 << 20));
        const path = try arena.dupe(u8, e.path);
        std.mem.replaceScalar(u8, path, std.fs.path.sep, '/');
        const exec = if (std.Io.File.Permissions.has_executable_bit) blk: {
            const st = try e.dir.statFile(io, e.basename, .{});
            break :blk st.permissions.toMode() & 0o111 != 0;
        } else std.mem.startsWith(u8, data, "#!");
        try out.append(arena, .{ .path = path, .exec = exec, .data = data });
    }
    return out.items;
}

fn hidden(path: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |el| if (el.len > 0 and el[0] == '.') return true;
    return false;
}

/// The table as Zig source, for src/kern.zig to import as `guest_tree`.
pub fn render(w: *std.Io.Writer, entries: []const Entry) std.Io.Writer.Error!void {
    try w.writeAll(
        \\//! Generated by build.zig from src/guest/ (tools/guesttree.zig).
        \\pub const Entry = struct { name: [:0]const u8, parent: u32, dir: bool, exec: bool, data: []const u8 };
        \\pub const entries = [_]Entry{
        \\
    );
    for (entries) |e| try w.print("    .{{ .name = \"{f}\", .parent = {d}, .dir = {}, .exec = {}, .data = \"{f}\" }},\n", .{
        std.zig.fmtString(e.name), e.parent, e.dir, e.exec, std.zig.fmtString(e.data),
    });
    try w.writeAll("};\n");
}

const t = std.testing;

test "an executable that isn't an rc script is rejected" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var why: []const u8 = "";
    for ([_][]const u8{ "\x00\x00\x8a\x97", "#!/bin/sh\necho hi\n", "echo hi\n", "" }) |data| {
        try t.expectError(error.Rejected, build(arena.allocator(), &.{.{ .path = "bin/x", .exec = true, .data = data }}, &why));
        try t.expect(std.mem.startsWith(u8, why, "bin/x is executable but isn't an rc script"));
    }
}

test "rc scripts and data are accepted, and the tree always has bin" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var why: []const u8 = "";
    const empty = try build(arena.allocator(), &.{}, &why);
    try t.expectEqual(2, empty.len);
    try t.expectEqualStrings("bin", empty[1].name);
    try t.expect(empty[1].dir);

    const es = try build(arena.allocator(), &.{
        .{ .path = "lib/h9/notes", .exec = false, .data = "\x00binary data is fine\n" },
        .{ .path = "bin/wsmount", .exec = true, .data = "#!/bin/rc\necho hi\n" },
    }, &why);
    // "", bin, bin/wsmount, lib, lib/h9, lib/h9/notes
    try t.expectEqual(6, es.len);
    try t.expectEqualStrings("wsmount", es[2].name);
    try t.expectEqual(1, es[2].parent);
    try t.expect(es[2].exec and !es[2].dir);
    try t.expectEqualStrings("notes", es[5].name);
    try t.expectEqual(4, es[5].parent);
    try t.expectEqual(3, es[4].parent);
    try t.expect(es[3].dir and es[4].dir and !es[5].exec);
    for (es[1..], 1..) |e, i| try t.expect(e.parent < i);
}

test "a path twice, or a file where a directory is, is rejected" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var why: []const u8 = "";
    try t.expectError(error.Rejected, build(arena.allocator(), &.{
        .{ .path = "bin/x", .exec = false, .data = "" },
        .{ .path = "bin/x", .exec = false, .data = "" },
    }, &why));
    try t.expectError(error.Rejected, build(arena.allocator(), &.{
        .{ .path = "lib", .exec = false, .data = "" },
        .{ .path = "lib/x", .exec = false, .data = "" },
    }, &why));
}

test "render escapes names and contents" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var why: []const u8 = "";
    const es = try build(arena.allocator(), &.{.{ .path = "bin/q", .exec = true, .data = "#!/bin/rc\necho \"a\\b\"\n" }}, &why);
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try render(&out.writer, es);
    try t.expect(std.mem.indexOf(u8, out.written(), "\"#!/bin/rc\\necho \\\"a\\\\b\\\"\\n\"") != null);
}

test "dot names are hidden" {
    try t.expect(hidden(".gitkeep"));
    try t.expect(hidden("bin/.gitkeep"));
    try t.expect(!hidden("bin/wsmount"));
}
