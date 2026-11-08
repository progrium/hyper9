//! Unpacks a 9front release ISO into a root tree:
//! `zig build isoroot -- ISO DIR`, run from the repository root.
//!
//! The Pages workflow (.github/workflows/pages.yml) uses it to get a 386
//! root for the browser host's root archive from the pinned 386 ISO
//! (`scripts/fetch.sh iso386`), without the hour-long cross-compile that
//! `zig build mkroot -- --arch 386` does (design/0009-i386.md chose the
//! cross-compile for development roots, and that still stands; the demo
//! only needs the release's own binaries).
//!
//! 9front's ISOs are ISO 9660 with Joliet and Plan 9's system-use
//! extension (disk/mk9660 -9cj). Names come from the Joliet tree, since
//! the primary tree's are conformed to upper case; modes come from the
//! primary tree's Plan 9 extension, matched by extent, since both trees
//! point at the same file data. Plan 9 names longer than Joliet's 64
//! characters come from the extension too, where it has them. Files
//! keep their Plan 9 permission bits, directories get 0775.

const std = @import("std");
const Io = std.Io;

const sector = 2048;
const flag_dir = 0x02;
const flag_multi = 0x80;

const Meta = struct { mode: u32, name: []const u8 };

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len != 3) {
        std.debug.print("usage: zig build isoroot -- ISO DIR\n", .{});
        return 2;
    }
    const cwd = Io.Dir.cwd();
    var iso = try cwd.openFile(io, argv[1], .{});
    defer iso.close(io);
    const r: Reader = .{ .io = io, .file = iso, .arena = arena };

    // Volume descriptors from sector 16 until the terminator (type 255).
    var primary: ?[]const u8 = null;
    var joliet: ?[]const u8 = null;
    var s: u64 = 16;
    while (true) : (s += 1) {
        const vd = try r.read(s * sector, sector);
        if (!std.mem.eql(u8, vd[1..6], "CD001")) return fail("{s}: not an ISO 9660 image", .{argv[1]});
        switch (vd[0]) {
            1 => primary = vd[156..190],
            // A supplementary descriptor is Joliet when its escape
            // sequence names UCS-2 (%/@, %/C or %/E).
            2 => if (vd[88] == '%' and vd[89] == '/' and std.mem.indexOfScalar(u8, "@CE", vd[90]) != null) {
                joliet = vd[156..190];
            },
            255 => break,
            else => {},
        }
    }
    const p = primary orelse return fail("{s}: no primary volume descriptor", .{argv[1]});
    const j = joliet orelse return fail("{s}: no Joliet tree", .{argv[1]});

    var meta: std.AutoHashMapUnmanaged(u32, Meta) = .empty;
    try r.walkPrimary(p, &meta);

    try cwd.createDirPath(io, argv[2]);
    var out = try cwd.openDir(io, argv[2], .{});
    defer out.close(io);
    var n: usize = 0;
    try r.unpack(j, &meta, out, "", &n);
    std.debug.print("isoroot: {d} files into {s}\n", .{ n, argv[2] });
    return 0;
}

fn fail(comptime fmt: []const u8, args: anytype) u8 {
    std.debug.print("isoroot: " ++ fmt ++ "\n", args);
    return 1;
}

/// A directory record, as ISO 9660 lays it out.
const Record = struct {
    raw: []const u8,

    fn extent(rec: Record) u32 {
        return std.mem.readInt(u32, rec.raw[2..6], .little);
    }
    fn size(rec: Record) u32 {
        return std.mem.readInt(u32, rec.raw[10..14], .little);
    }
    fn flags(rec: Record) u8 {
        return rec.raw[25];
    }
    fn name(rec: Record) []const u8 {
        return rec.raw[33..][0..rec.raw[32]];
    }
    /// "." and "..", which are the bytes 0 and 1.
    fn isDot(rec: Record) bool {
        return rec.raw[32] == 1 and rec.raw[33] <= 1;
    }
    /// Plan 9's extension: name, uid and gid, each a length byte and the
    /// bytes, then a 32-bit mode at the next even offset, as
    /// 9660srv reads it.
    fn plan9(rec: Record) ?Meta {
        var o: usize = 33 + rec.raw[32];
        if (o & 1 != 0) o += 1;
        var fields: [3][]const u8 = undefined;
        for (&fields) |*f| {
            if (o >= rec.raw.len) return null;
            const l = rec.raw[o];
            if (o + 1 + l > rec.raw.len) return null;
            f.* = rec.raw[o + 1 ..][0..l];
            o += 1 + l;
        }
        if (o & 1 != 0) o += 1;
        if (o + 4 > rec.raw.len) return null;
        return .{ .mode = std.mem.readInt(u32, rec.raw[o..][0..4], .little), .name = fields[0] };
    }
};

const Reader = struct {
    io: Io,
    file: Io.File,
    arena: std.mem.Allocator,

    fn read(r: Reader, off: u64, len: usize) ![]u8 {
        const buf = try r.arena.alloc(u8, len);
        if (try r.file.readPositionalAll(r.io, buf, off) != len) return error.EndOfStream;
        return buf;
    }

    /// The records of the directory that `dir` (a record) points at.
    fn records(r: Reader, dir: Record) !std.ArrayList(Record) {
        const data = try r.read(@as(u64, dir.extent()) * sector, dir.size());
        var list: std.ArrayList(Record) = .empty;
        var i: usize = 0;
        while (i < data.len) {
            const l = data[i];
            // Records don't cross sectors; a zero length pads to the next.
            if (l == 0) {
                i = (i / sector + 1) * sector;
                continue;
            }
            if (l < 34 or i + l > data.len) return error.BadRecord;
            const rec: Record = .{ .raw = data[i..][0..l] };
            if (!rec.isDot()) try list.append(r.arena, rec);
            i += l;
        }
        return list;
    }

    fn walkPrimary(r: Reader, dir: []const u8, meta: *std.AutoHashMapUnmanaged(u32, Meta)) !void {
        const recs = try r.records(.{ .raw = dir });
        for (recs.items) |rec| {
            if (rec.flags() & flag_dir != 0) {
                try r.walkPrimary(rec.raw, meta);
            } else if (rec.plan9()) |m| {
                try meta.put(r.arena, rec.extent(), m);
            }
        }
    }

    fn unpack(r: Reader, dir: []const u8, meta: *const std.AutoHashMapUnmanaged(u32, Meta), out: Io.Dir, prefix: []const u8, n: *usize) !void {
        const recs = try r.records(.{ .raw = dir });
        for (recs.items) |rec| {
            if (rec.flags() & flag_multi != 0) return error.MultiExtentFile;
            var name = try jolietName(r.arena, rec.name());
            const m = if (rec.flags() & flag_dir == 0) meta.get(rec.extent()) else null;
            if (m) |mm| if (mm.name.len > 0) {
                name = mm.name;
            };
            if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null or std.mem.eql(u8, name, "..")) return error.BadName;
            const path = if (prefix.len == 0) name else try std.fmt.allocPrint(r.arena, "{s}/{s}", .{ prefix, name });
            if (rec.flags() & flag_dir != 0) {
                try out.createDirPath(r.io, path);
                try r.unpack(rec.raw, meta, out, path, n);
                continue;
            }
            const data = try r.read(@as(u64, rec.extent()) * sector, rec.size());
            var f = try out.createFile(r.io, path, .{});
            defer f.close(r.io);
            try f.writeStreamingAll(r.io, data);
            const mode: u32 = if (m) |mm| mm.mode & 0o777 else 0o664;
            try f.setPermissions(r.io, .fromMode(@intCast(mode)));
            r.arena.free(data);
            n.* += 1;
        }
    }
};

/// A Joliet name, UCS-2 big-endian, as UTF-8 without its ";1" version.
fn jolietName(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i + 1 < raw.len) : (i += 2) {
        const c: u21 = std.mem.readInt(u16, raw[i..][0..2], .big);
        var buf: [4]u8 = undefined;
        const l = std.unicode.utf8Encode(c, &buf) catch return error.BadName;
        try out.appendSlice(arena, buf[0..l]);
    }
    const s = out.items;
    if (std.mem.lastIndexOfScalar(u8, s, ';')) |k| return s[0..k];
    return s;
}

test "jolietName" {
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    try std.testing.expectEqualStrings("rc", try jolietName(a.allocator(), "\x00r\x00c\x00;\x001"));
    try std.testing.expectEqualStrings("namespace", try jolietName(a.allocator(), "\x00n\x00a\x00m\x00e\x00s\x00p\x00a\x00c\x00e"));
}

test "plan9 mode" {
    // A file record named "RC" (even, so one pad byte) with uid and gid
    // "sys" and mode 0775.
    const raw = [_]u8{0} ** 32 ++ [_]u8{ 2, 'R', 'C', 0, 0, 3, 's', 'y', 's', 3, 's', 'y', 's', 0, 0xfd, 0x01, 0, 0 };
    const m = (Record{ .raw = &raw }).plan9().?;
    try std.testing.expectEqual(@as(u32, 0o775), m.mode);
    try std.testing.expectEqualStrings("", m.name);
}
