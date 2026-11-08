//! h9's own guest commands (design/0032-guest-tools.md): the tree under
//! src/guest/, read by build.zig at configure time and written out as a
//! Zig table that src/kern.zig hands to `#H` (src/kern/devhtools.c).
//!
//! Only rc scripts and data go in the tree. A file is executable (0555)
//! when its repository mode is, and then it must start with `#!/bin/rc`;
//! any other file is data (0444). Directories are 0555. Names starting
//! with `.` are left out, so a `.gitkeep` can hold an empty directory.
//!
//! The same table, built with `buildRoot` and written with `renderRoot`,
//! is the built-in root `#Hroot` serves (design/0087-builtin-root.md): the mount
//! points h9 binds onto, and for each architecture the build embeds,
//! multicall's tree of 9front's commands (design/0064-multicall.md). Its
//! executables are 9front binaries rather than rc scripts, entries with
//! the same bytes share them, and the bytes are embedded with @embedFile
//! rather than written into the generated source.

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
    /// In a shared table (`share`), the index of this file's contents in
    /// the blobs it returned.
    blob: ?u32 = null,
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
    return buildTable(arena, &always, inputs, true, why);
}

/// The directories the built-in root always has: what h9's namespace binds
/// onto (src/policy.zig), and `usr` so `$home` has a parent.
pub const root_skeleton = [_][]const u8{ "bin", "dev", "env", "fd", "mnt/term/cwd", "net", "proc", "srv", "tmp", "usr" };

/// The built-in root's table for `inputs`, the files of multicall's trees.
/// Any file may be executable. A path in two trees, such as
/// `rc/lib/rcmain`, is kept once if both have the same bytes.
pub fn buildRoot(arena: std.mem.Allocator, inputs: []const Input, why: *[]const u8) BuildError![]Entry {
    var seen: std.StringHashMapUnmanaged([]const u8) = .empty;
    var kept: std.ArrayList(Input) = .empty;
    for (inputs) |in| {
        const gop = try seen.getOrPut(arena, in.path);
        if (gop.found_existing) {
            if (std.mem.eql(u8, gop.value_ptr.*, in.data)) continue;
            why.* = try std.fmt.allocPrint(arena, "{s} differs between the trees", .{in.path});
            return error.Rejected;
        }
        gop.value_ptr.* = in.data;
        try kept.append(arena, in);
    }
    return buildTable(arena, &root_skeleton, kept.items, false, why);
}

fn buildTable(arena: std.mem.Allocator, dirs: []const []const u8, inputs: []const Input, scripts_only: bool, why: *[]const u8) BuildError![]Entry {
    var paths: std.StringArrayHashMapUnmanaged(?Input) = .empty;
    for (dirs) |d| {
        // Every ancestor of an always-present directory is one too.
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, d, i, '/')) |slash| : (i = slash + 1) try paths.put(arena, d[0..slash], null);
        try paths.put(arena, d, null);
    }
    for (inputs) |in| {
        if (scripts_only) if (reject(in)) |r| {
            why.* = try std.fmt.allocPrint(arena, "{s} {s}", .{ in.path, r });
            return error.Rejected;
        };
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
            why.* = try std.fmt.allocPrint(arena, "{s} {s}", .{ in.path, if (gop.value_ptr.* == null) "is a file and a directory" else "is in the tree twice" });
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
    return scanLimited(arena, io, dir, 1 << 20);
}

/// `scan`, with files of up to `limit` bytes. On a host without executable
/// bits, a 9front a.out is executable too.
pub fn scanLimited(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, limit: usize) ![]Input {
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
        const data = try e.dir.readFileAlloc(io, e.basename, arena, .limited(limit));
        const path = try arena.dupe(u8, e.path);
        std.mem.replaceScalar(u8, path, std.fs.path.sep, '/');
        const exec = if (std.Io.File.Permissions.has_executable_bit) blk: {
            const st = try e.dir.statFile(io, e.basename, .{});
            break :blk st.permissions.toMode() & 0o111 != 0;
        } else std.mem.startsWith(u8, data, "#!") or isAout(data);
        try out.append(arena, .{ .path = path, .exec = exec, .data = data });
    }
    return out.items;
}

/// Whether `data` starts with a 9front a.out magic (arm64, amd64 or 386).
fn isAout(data: []const u8) bool {
    if (data.len < 4) return false;
    // As src/aout.zig's: 386, amd64 and arm64.
    const magic = std.mem.readInt(u32, data[0..4], .big);
    return magic == 0x000001eb or magic == 0x00008a97 or magic == 0x00008c47;
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

/// Gives entries with the same contents the same blob, and returns the
/// blobs, in order of first use. Empty files and directories have none.
pub fn share(arena: std.mem.Allocator, entries: []Entry) error{OutOfMemory}![]const []const u8 {
    var blobs: std.ArrayList([]const u8) = .empty;
    var index: std.StringHashMapUnmanaged(u32) = .empty;
    for (entries) |*e| {
        if (e.dir or e.data.len == 0) continue;
        const gop = try index.getOrPut(arena, e.data);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(blobs.items.len);
            try blobs.append(arena, e.data);
        }
        e.blob = gop.value_ptr.*;
    }
    return blobs.items;
}

/// The name a blob is embedded under, beside the generated source.
pub fn blobName(buf: []u8, i: u32) []const u8 {
    return std.fmt.bufPrint(buf, "blob{d}", .{i}) catch unreachable;
}

/// The name of multicall's tree for `release` and `arch` in its
/// directory, as `zig build slim` names it.
pub fn treeName(buf: []u8, release: []const u8, arch: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "slim-{s}-{s}", .{ release, arch }) catch unreachable;
}

/// What a directory of multicall's trees has for one architecture.
pub const Found = union(enum) {
    /// The pinned release's tree.
    found,
    /// None, but there's one from another release, by name: stale.
    stale: []const u8,
    missing,
};

/// Looks through `names`, a directory's entries, for `arch`'s tree of
/// `release`.
pub fn findTree(names: []const []const u8, release: []const u8, arch: []const u8) Found {
    var buf: [128]u8 = undefined;
    const want = treeName(&buf, release, arch);
    var stale: ?[]const u8 = null;
    for (names) |n| {
        if (std.mem.eql(u8, n, want)) return .found;
        // slim-<release>-<arch>, where release has no dashes.
        if (!std.mem.startsWith(u8, n, "slim-") or !std.mem.endsWith(u8, n, arch)) continue;
        const mid = n["slim-".len .. n.len - arch.len];
        if (mid.len < 2 or mid[mid.len - 1] != '-' or std.mem.indexOfScalar(u8, mid[0 .. mid.len - 1], '-') != null) continue;
        stale = n;
    }
    return if (stale) |s| .{ .stale = s } else .missing;
}

/// What `h9 --version` and `--check` say about the built-in root.
pub const RootInfo = struct {
    /// The 9front release the trees were built from.
    release: []const u8,
    /// multicall's set (src/9box), the trees' name.
    set: []const u8 = "slim",
    /// The architectures embedded, in 9front's names; empty for the
    /// skeleton only.
    arches: []const []const u8,
    /// Commands per architecture: the names in `/<arch>/bin`.
    commands: usize,
};

/// The built-in root's table as Zig source, for src/kern.zig to import as
/// `builtin_root`. Contents are `share`d first, and each blob is embedded
/// from the file `blobName` names in the same directory.
pub fn renderRoot(w: *std.Io.Writer, entries: []const Entry, nblobs: usize, info: RootInfo) std.Io.Writer.Error!void {
    try w.writeAll(
        \\//! Generated by build.zig from multicall's trees (tools/guesttree.zig).
        \\pub const Entry = struct { name: [:0]const u8, parent: u32, dir: bool, exec: bool, data: []const u8 };
        \\
    );
    try w.print("pub const release = \"{f}\";\n", .{std.zig.fmtString(info.release)});
    try w.print("pub const set = \"{f}\";\n", .{std.zig.fmtString(info.set)});
    try w.writeAll("pub const arches = [_][]const u8{");
    for (info.arches, 0..) |a, i| try w.print("{s}\"{f}\"", .{ if (i > 0) ", " else " ", std.zig.fmtString(a) });
    try w.writeAll(if (info.arches.len > 0) " };\n" else "};\n");
    try w.print("pub const commands = {d};\n", .{info.commands});
    var nb: [32]u8 = undefined;
    for (0..nblobs) |i| try w.print("const b{d} = @embedFile(\"{s}\");\n", .{ i, blobName(&nb, @intCast(i)) });
    try w.writeAll("pub const entries = [_]Entry{\n");
    for (entries) |e| {
        try w.print("    .{{ .name = \"{f}\", .parent = {d}, .dir = {}, .exec = {}, .data = ", .{ std.zig.fmtString(e.name), e.parent, e.dir, e.exec });
        if (e.blob) |b| try w.print("b{d}", .{b}) else try w.writeAll("\"\"");
        try w.writeAll(" },\n");
    }
    try w.writeAll("};\n");
}

/// The number of commands in `/<arch>/bin` of a built-in root table, with
/// `9box` itself left out.
pub fn countCommands(entries: []const Entry, arch: []const u8) usize {
    for (entries, 0..) |a, ai| {
        if (ai == 0 or a.parent != 0 or !a.dir or !std.mem.eql(u8, a.name, arch)) continue;
        for (entries, 0..) |b, bi| {
            if (b.parent != ai or !b.dir or !std.mem.eql(u8, b.name, "bin")) continue;
            var n: usize = 0;
            for (entries) |c| if (c.parent == bi and !c.dir and !std.mem.eql(u8, c.name, "9box")) {
                n += 1;
            };
            return n;
        }
    }
    return 0;
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

test "the built-in root has its skeleton with nothing in it" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var why: []const u8 = "";
    const es = try buildRoot(arena.allocator(), &.{}, &why);
    // "", the skeleton, and mnt and mnt/term as cwd's parents.
    try t.expectEqual(1 + root_skeleton.len + 2, es.len);
    for (es) |e| try t.expect(e.dir);
    for (es[1..], 1..) |e, i| try t.expect(e.parent < i);
    try t.expectEqual(0, countCommands(es, "arm64"));
}

test "the built-in root takes binaries, and shares their contents" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    const box7 = "\x00\x00\x8a\x97 arm64 9box";
    const box6 = "\x00\x00\x8a\x97 amd64 9box";
    const rcmain = "# rcmain\n";
    const es = try buildRoot(a, &.{
        .{ .path = "arm64/bin/9box", .exec = true, .data = box7 },
        .{ .path = "arm64/bin/ls", .exec = true, .data = box7 },
        .{ .path = "arm64/bin/rc", .exec = true, .data = box7 },
        .{ .path = "rc/lib/rcmain", .exec = false, .data = rcmain },
        .{ .path = "amd64/bin/9box", .exec = true, .data = box6 },
        .{ .path = "amd64/bin/ls", .exec = true, .data = box6 },
        // The same file from the second tree is kept once.
        .{ .path = "rc/lib/rcmain", .exec = false, .data = rcmain },
    }, &why);
    const blobs = try share(a, es);
    try t.expectEqual(3, blobs.len);
    try t.expectEqual(2, countCommands(es, "arm64"));
    try t.expectEqual(1, countCommands(es, "amd64"));
    var box7_blob: ?u32 = null;
    for (es) |e| if (e.blob) |b| {
        if (std.mem.eql(u8, e.data, box7)) {
            if (box7_blob) |prev| try t.expectEqual(prev, b) else box7_blob = b;
        }
        try t.expectEqualStrings(e.data, blobs[b]);
    } else try t.expect(e.dir or e.data.len == 0);

    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try renderRoot(&out.writer, es, blobs.len, .{ .release = "11952", .arches = &.{ "arm64", "amd64" }, .commands = 2 });
    const src = out.written();
    try t.expect(std.mem.indexOf(u8, src, "const b2 = @embedFile(\"blob2\");") != null);
    try t.expect(std.mem.indexOf(u8, src, "pub const arches = [_][]const u8{ \"arm64\", \"amd64\" };") != null);
    // The bytes aren't in the source.
    try t.expect(std.mem.indexOf(u8, src, "arm64 9box") == null);
}

test "a path that differs between the built-in root's trees is rejected" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var why: []const u8 = "";
    try t.expectError(error.Rejected, buildRoot(arena.allocator(), &.{
        .{ .path = "rc/lib/rcmain", .exec = false, .data = "one" },
        .{ .path = "rc/lib/rcmain", .exec = false, .data = "two" },
    }, &why));
    try t.expectEqualStrings("rc/lib/rcmain differs between the trees", why);
    // A file where the skeleton has a directory.
    try t.expectError(error.Rejected, buildRoot(arena.allocator(), &.{.{ .path = "tmp", .exec = false, .data = "x" }}, &why));
}

test "a tree from another release is stale" {
    const names = [_][]const u8{ "root", "slim-copy-11952-arm64", "slim-11800-amd64", "slim-11952-arm64", "slim-11952-386" };
    try t.expectEqual(Found.found, findTree(&names, "11952", "arm64"));
    try t.expectEqual(Found.found, findTree(&names, "11952", "386"));
    try t.expectEqualStrings("slim-11800-amd64", findTree(&names, "11952", "amd64").stale);
    try t.expectEqual(Found.missing, findTree(names[0..2], "11952", "arm64"));
}

test "a.out magics are recognized" {
    try t.expect(isAout("\x00\x00\x8a\x97rest"));
    try t.expect(isAout("\x00\x00\x01\xebrest"));
    try t.expect(isAout("\x00\x00\x8c\x47rest"));
    try t.expect(!isAout("#!/bin/rc\n"));
}
