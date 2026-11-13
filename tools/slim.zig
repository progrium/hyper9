//! `zig build slim`: builds 9box, a multi-call binary of 9front's commands,
//! and a slim root around it (design/multicall.md).
//!
//! The build runs inside h9, against the stock root: src/9box/ is copied
//! into a fresh build directory, which is the machine's cwd and the only
//! thing it can write, and its mkfile builds the commands listed in
//! src/9box/slim with their
//! globals renamed and links them into one binary (src/9box/mkfile). The
//! source is the root's /sys/src (zig build mkroot -- --src) or, without one,
//! the fetched checkout, shared read-only and bound at /sys/src.
//!
//! Then the tree is assembled on the host:
//!
//!     <arch>/bin/9box
//!     <arch>/bin/<cmd>    hard links to 9box, or #!/bin/9box -! stubs
//!     rc/lib/rcmain
//!     rc/bin/lc
//!     adm/timezone/local
//!     bin dev env fd mnt/term/cwd n net proc srv tmp rc/bin    mount points
//!
//! and its size is reported against the same commands copied from the
//! stock root. With `copy` for the links, nothing is built: the tree has
//! the same commands copied from the stock root instead, the separate
//! binaries the box is measured against.
//!
//! usage: slim H9 ROOT SRC9BOX SYSSRC ARCH hard|stub|copy BUILD OUT

const std = @import("std");

const usage = "usage: slim H9 ROOT SRC9BOX SYSSRC ARCH hard|stub|copy BUILD OUT\n";

/// What a stub holds: 9box takes the command from the stub's own path,
/// argv[2] (src/9box/9box.c).
pub const stub = "#!/bin/9box -!\n";

/// The directories h9 binds onto, which a host tree must have, and
/// /rc/bin, which it binds after /$cputype/bin.
const mount_points = [_][]const u8{ "bin", "dev", "env", "fd", "mnt/term/cwd", "n", "net", "proc", "srv", "tmp", "rc/bin" };

/// Files copied from the stock root as they are: rcmain, which rc reads
/// when it starts, and lc, the one rc script the set's commands make
/// (`ls -pF | mc`).
const root_files = [_][]const u8{ "rc/lib/rcmain", "rc/bin/lc", "adm/timezone/local" };

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("slim: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

/// The object letter for `arch`, as /$objtype/mkfile's O.
fn objLetter(arch: []const u8) []const u8 {
    if (std.mem.eql(u8, arch, "arm64")) return "7";
    if (std.mem.eql(u8, arch, "amd64")) return "6";
    if (std.mem.eql(u8, arch, "386")) return "8";
    fail("unknown architecture {s} (arm64, amd64 or 386)", .{arch});
}

/// The guest path of a host path h9 shares with --readable, outside the
/// cwd and the root: /mnt/term followed by the host path, with `/`
/// separators.
fn guestPath(arena: std.mem.Allocator, host: []const u8) ![]const u8 {
    const p = try arena.dupe(u8, host);
    std.mem.replaceScalar(u8, p, '\\', '/');
    if (p.len >= 2 and p[1] == ':') return std.fmt.allocPrint(arena, "/mnt/term/{c}{s}", .{ std.ascii.toLower(p[0]), p[2..] });
    return std.fmt.allocPrint(arena, "/mnt/term{s}", .{p});
}

const Links = enum { hard, stub, copy };

/// The set file in src/9box: the commands 9box is built from.
const set = "slim";

/// The commands in the set file `name` in `dir`, in order and once each,
/// as src/9box/lsset reads it: a name (and a directory) per line, and # to
/// the end of a line a comment.
fn readSet(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8, names: *std.ArrayList([]const u8)) !void {
    const text = dir.readFileAlloc(io, name, arena, .limited(1 << 20)) catch |e| fail("set {s}: {t}", .{ name, e });
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const l = if (std.mem.indexOfScalar(u8, raw, '#')) |h| raw[0..h] else raw;
        var f = std.mem.tokenizeAny(u8, l, " \t");
        const w = f.next() orelse continue;
        for (names.items) |n| {
            if (std.mem.eql(u8, n, w)) break;
        } else try names.append(arena, w);
    }
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len != 9) {
        std.debug.print(usage, .{});
        return 2;
    }
    const h9 = argv[1];
    const root = argv[2];
    const src9box = argv[3];
    const syssrc = argv[4];
    const arch = argv[5];
    const links = argv[6];
    const build = argv[7];
    const out = argv[8];
    const mode = std.meta.stringToEnum(Links, links) orelse fail("-Dslim-links is hard, stub or copy, not {s}", .{links});
    _ = objLetter(arch);
    const cwd = std.Io.Dir.cwd();

    var src_dir = cwd.openDir(io, src9box, .{ .iterate = true }) catch |e| fail("{s}: {t}", .{ src9box, e });
    defer src_dir.close(io);
    src_dir.access(io, set, .{}) catch fail("no set {s} in {s}", .{ set, src9box });
    var root_dir = cwd.openDir(io, root, .{}) catch |e| fail("no root tree at {s} ({t}); run zig build mkroot or pass -Droot", .{ root, e });
    defer root_dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    if (mode == .copy) {
        try readSet(arena, io, src_dir, set, &names);
    } else {
        try build9box(arena, io, h9, root, root_dir, src_dir, syssrc, arch, build);
        // The commands, as the build listed them.
        const set_list = try cwd.readFileAlloc(io, try std.fmt.allocPrint(arena, "{s}/obj/{s}/set", .{ build, arch }), arena, .limited(1 << 20));
        var lines = std.mem.tokenizeScalar(u8, set_list, '\n');
        while (lines.next()) |l| {
            var f = std.mem.tokenizeAny(u8, l, " \t");
            if (f.next()) |n| try names.append(arena, n);
        }
    }

    // The tree.
    cwd.deleteTree(io, out) catch {};
    var out_dir = try cwd.createDirPathOpen(io, out, .{});
    defer out_dir.close(io);
    // Mount points get the root's modes: /tmp, for one, is 0775 there, and
    // h9's private /tmp takes its mode from it.
    for (mount_points) |d| {
        try out_dir.createDirPath(io, d);
        const st = root_dir.statFile(io, d, .{}) catch continue;
        var sub = try out_dir.openDir(io, d, .{ .iterate = true });
        defer sub.close(io);
        sub.setPermissions(io, st.permissions) catch {};
    }
    for (root_files) |f| root_dir.copyFile(f, out_dir, f, io, .{ .make_path = true }) catch |e| fail("{s}/{s}: {t}", .{ root, f, e });
    const bin = try std.fmt.allocPrint(arena, "{s}/bin", .{arch});
    try out_dir.createDirPath(io, bin);
    const box = try std.fmt.allocPrint(arena, "{s}/9box", .{bin});
    if (mode != .copy) {
        var build_dir = try cwd.openDir(io, build, .{});
        defer build_dir.close(io);
        try build_dir.copyFile(try std.fmt.allocPrint(arena, "{s}.9box", .{objLetter(arch)}), out_dir, box, io, .{ .permissions = .executable_file });
    }
    for (names.items) |n| {
        const p = try std.fmt.allocPrint(arena, "{s}/{s}", .{ bin, n });
        switch (mode) {
            .hard => out_dir.hardLink(box, out_dir, p, io, .{}) catch |e| fail("linking {s}: {t}", .{ p, e }),
            .stub => try out_dir.writeFile(io, .{ .sub_path = p, .data = stub, .flags = .{ .permissions = .executable_file } }),
            .copy => root_dir.copyFile(p, out_dir, p, io, .{}) catch |e| fail("{s}/{s}: {t}", .{ root, p, e }),
        }
    }

    // The size, against the same commands copied from the stock root.
    var copied: u64 = 0;
    var missing: usize = 0;
    for (names.items) |n| {
        const st = root_dir.statFile(io, try std.fmt.allocPrint(arena, "{s}/{s}", .{ bin, n }), .{}) catch {
            missing += 1;
            continue;
        };
        copied += st.size;
    }
    if (mode == .copy) {
        std.debug.print("slim: {s}: {d} commands copied from the root, {d} KB", .{ out, names.items.len, copied / 1024 });
    } else {
        const box_size = (try out_dir.statFile(io, box, .{})).size;
        std.debug.print("slim: {s}: {d} commands, 9box {d} KB ({s}); the same commands copied from the root: {d} KB", .{ out, names.items.len, box_size / 1024, if (mode == .hard) "hard links" else "stubs", copied / 1024 });
    }
    if (missing > 0) std.debug.print(" ({d} not in the root)", .{missing});
    std.debug.print("\n", .{});
    return 0;
}

/// Builds 9box in a fresh `build`, inside h9 (src/9box/mkfile).
fn build9box(arena: std.mem.Allocator, io: std.Io, h9: []const u8, root: []const u8, root_dir: std.Io.Dir, src_dir: std.Io.Dir, syssrc: []const u8, arch: []const u8, build: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const o = objLetter(arch);
    const own_src = if (root_dir.access(io, "sys/src/cmd/mkfile", .{})) true else |_| false;
    if (!own_src) cwd.access(io, try std.fs.path.join(arena, &.{ syssrc, "cmd/mkfile" }), .{}) catch
        fail("the root has no /sys/src and there's no checkout at {s}; run scripts/fetch.sh, or zig build mkroot -- --src", .{syssrc});

    // A fresh build directory holding a copy of src/9box.
    cwd.deleteTree(io, build) catch {};
    var build_dir = try cwd.createDirPathOpen(io, build, .{});
    defer build_dir.close(io);
    var it = src_dir.iterate();
    while (try it.next(io)) |e| if (e.kind == .file) try src_dir.copyFile(e.name, build_dir, e.name, io, .{});

    // The build, inside h9: the root as it is, the build directory as the
    // cwd, and the source shared read-only and bound at /sys/src if the
    // root has none.
    const build_abs = try std.Io.Dir.cwd().realPathFileAlloc(io, build, arena);
    var args: std.ArrayList([]const u8) = .empty;
    // The compilers run on an architecture the root has binaries for,
    // arm64 when it can: the 386 tree an ISO unpacks to cross-compiles.
    const host_arch = for ([_][]const u8{ "arm64", "amd64", "386" }) |h| {
        if (root_dir.access(io, try std.fmt.allocPrint(arena, "{s}/bin/rc", .{h}), .{})) break h else |_| {}
    } else fail("the root has no rc for arm64, amd64 or 386", .{});
    try args.appendSlice(arena, &.{ h9, "--arch", host_arch, "--root", root, "--cwd", build_abs });
    var script: std.ArrayList(u8) = .empty;
    if (!own_src) {
        const src_abs = try cwd.realPathFileAlloc(io, syssrc, arena);
        try args.appendSlice(arena, &.{ "--readable", src_abs });
        try script.print(arena, "mkdir -p /sys/src && bind {s} /sys/src && ", .{try guestPath(arena, src_abs)});
    }
    // mk runs one recipe at a time (no NPROC): the emulator runs one
    // process's guest code at a time, and several compilers taking turns
    // on it are slower than one after another.
    try script.print(arena, "cd /mnt/term/cwd && objtype={s} mk -k && test -f {s}.9box", .{ arch, o });
    try args.appendSlice(arena, &.{ "--rc", script.items });
    std.debug.print("slim: building 9box ({s}) inside h9 in {s}\n", .{ arch, build });
    var child = std.process.spawn(io, .{ .argv = args.items }) catch |e| fail("running {s}: {t}", .{ h9, e });
    const term = try child.wait(io);
    switch (term) {
        .exited => |c| if (c != 0) fail("the build failed (h9 exited {d}); the logs are under {s}/obj/{s}", .{ c, build, arch }),
        else => fail("the build failed: {any}", .{term}),
    }
}
