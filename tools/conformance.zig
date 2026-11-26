//! The namespace conformance check (design/kernel-port.md):
//! tests/conformance/ns.rc, a script of namespace operations, run on h9
//! and compared with what 9front's own kernel printed for it,
//! tests/conformance/9front.out.
//!
//!   zig build conformance                 run it on h9, on each engine, and compare
//!   zig build conformance -- --oracle     record 9front.out on 9front under QEMU
//!
//! The oracle boots the pinned arm64 image as zig build mkroot does
//! (tools/mkroot.zig, which needs scripts/fetch.sh image and
//! qemu-system-aarch64), hands it the script on a raw disk, and runs it
//! with rc. Without KVM for arm64 that's TCG, which takes some minutes,
//! so the result is checked in and the check needs no QEMU.
//!
//! Check mode is run by build.zig as
//! `conformance --h9 PATH --root DIR --engines E,E [--arch A]`, from the
//! repository root. It skips, and succeeds, when the root tree is
//! missing, as the integration cases do. Each engine's transcript is
//! written to zig-out/conformance/<engine>.out.

const std = @import("std");
const mkroot = @import("mkroot.zig");
const Io = std.Io;
const Dir = Io.Dir;

const script_path = "tests/conformance/ns.rc";
const golden_path = "tests/conformance/9front.out";

const die = mkroot.die;
const log = mkroot.log;
const oom = mkroot.oom;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.arena.allocator();
    const io = init.io;
    mkroot.g_io = io;
    mkroot.g_name = "conformance";
    const argv = try init.minimal.args.toSlice(gpa);

    var oracle = false;
    var h9: ?[]const u8 = null;
    var root: ?[]const u8 = null;
    var engines: []const u8 = "auto";
    var arch: ?[]const u8 = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--oracle")) {
            oracle = true;
            continue;
        }
        if (i + 1 >= argv.len) die("{s} needs a value", .{a});
        const v = argv[i + 1];
        i += 1;
        if (std.mem.eql(u8, a, "--h9")) h9 = v else if (std.mem.eql(u8, a, "--root")) root = v else if (std.mem.eql(u8, a, "--engines")) engines = v else if (std.mem.eql(u8, a, "--arch")) arch = v else die("unknown flag {s}", .{a});
    }

    const repo = try std.process.currentPathAlloc(io, gpa);
    const c: mkroot.Ctx = .{
        .gpa = gpa,
        .io = io,
        .env = init.environ_map,
        .repo = repo,
        .local = try std.fs.path.join(gpa, &.{ repo, ".local" }),
    };
    const script = Dir.cwd().readFileAlloc(io, script_path, gpa, .limited(1 << 20)) catch |e|
        die("reading {s}: {t} (run this from the repository root)", .{ script_path, e });
    if (oracle) return runOracle(c, script);
    return check(c, script, h9 orelse die("--h9 is needed without --oracle", .{}), root orelse die("--root is needed without --oracle", .{}), engines, arch);
}

/// Runs the script on h9 on each engine and compares what it printed with
/// the golden transcript.
fn check(c: mkroot.Ctx, script: []const u8, h9: []const u8, root: []const u8, engines: []const u8, arch: ?[]const u8) u8 {
    const gpa = c.gpa;
    const io = c.io;
    if (!c.isFile(c.join(&.{ root, "lib", "namespace" }))) {
        log("skipped: no root tree at {s} (zig build mkroot, or -Droot)", .{root});
        return 0;
    }
    const golden = Dir.cwd().readFileAlloc(io, golden_path, gpa, .limited(1 << 20)) catch |e|
        die("reading {s}: {t} (zig build conformance -- --oracle records it)", .{ golden_path, e });
    const out_dir = "zig-out/conformance";
    c.makePath(out_dir);
    // One rc command, with the script's errors in its output, as they are
    // on 9front's console.
    const cmd = std.mem.concat(gpa, u8, &.{ "{\n", script, "\n} >[2=1]" }) catch oom();
    var failed = false;
    var it = std.mem.tokenizeScalar(u8, engines, ',');
    while (it.next()) |engine| {
        var args: std.ArrayList([]const u8) = .empty;
        args.appendSlice(gpa, &.{ h9, "--engine", engine, "--dir", root, "--timeout", "300s" }) catch oom();
        if (arch) |a| args.appendSlice(gpa, &.{ "--arch", a }) catch oom();
        args.appendSlice(gpa, &.{ "--rc", cmd }) catch oom();
        const r = std.process.run(gpa, io, .{ .argv = args.items, .stdout_limit = .limited(1 << 20), .stderr_limit = .limited(1 << 20) }) catch |e|
            die("running {s}: {t}", .{ h9, e });
        const out = c.join(&.{ out_dir, std.mem.concat(gpa, u8, &.{ engine, ".out" }) catch oom() });
        Dir.cwd().writeFile(io, .{ .sub_path = out, .data = r.stdout }) catch |e| die("writing {s}: {t}", .{ out, e });
        if (std.mem.eql(u8, r.stdout, golden)) {
            log("{s}: matches 9front", .{engine});
            continue;
        }
        failed = true;
        log("{s}: differs from 9front ({s} against {s}):", .{ engine, out, golden_path });
        printDiff(golden, r.stdout);
        if (r.stderr.len > 0) std.debug.print("h9's stderr:\n{s}\n", .{r.stderr});
    }
    return if (failed) 1 else 0;
}

/// Prints the first lines where `want` and `got` differ, with a few lines
/// of context before them.
fn printDiff(want: []const u8, got: []const u8) void {
    var wl = std.mem.splitScalar(u8, want, '\n');
    var gl = std.mem.splitScalar(u8, got, '\n');
    var ctx: [4][]const u8 = undefined;
    var n: usize = 0;
    var line: usize = 1;
    while (true) : (line += 1) {
        const w = wl.next();
        const g = gl.next();
        if (w == null and g == null) return;
        if (w != null and g != null and std.mem.eql(u8, w.?, g.?)) {
            ctx[n % ctx.len] = w.?;
            n += 1;
            continue;
        }
        const k = @min(n, ctx.len);
        for (0..k) |j| std.debug.print("  {s}\n", .{ctx[(n - k + j) % ctx.len]});
        std.debug.print("line {d}:\n", .{line});
        var shown: usize = 0;
        var w2 = w;
        var g2 = g;
        while (shown < 8 and (w2 != null or g2 != null)) : (shown += 1) {
            if (w2) |x| std.debug.print("- {s}\n", .{x});
            if (g2) |x| std.debug.print("+ {s}\n", .{x});
            w2 = wl.next();
            g2 = gl.next();
        }
        return;
    }
}

/// Boots 9front under QEMU, runs the script there, and writes what it
/// printed to the golden file.
fn runOracle(c: mkroot.Ctx, script: []const u8) u8 {
    const gpa = c.gpa;
    const io = c.io;
    const release = mkroot.pin(c, "NINEFRONT_RELEASE");
    const image = c.join(&.{ c.local, "9front", std.fmt.allocPrint(gpa, "9front-{s}.arm64.qcow2", .{release}) catch oom() });
    if (!c.exists(image)) die("no {s} (run scripts/fetch.sh image)", .{c.rel(image)});
    for ([_][]const u8{ "qemu-system-aarch64", "qemu-img" }) |tool| {
        if (c.which(tool) == null) die("{s} not found", .{tool});
    }
    const cache = c.join(&.{ c.local, "cache" });
    c.makePath(cache);
    const tmp = mkroot.makeTmp(c, cache);
    mkroot.g_tmp = tmp;

    // The script on a raw disk, padded with newlines to whole sectors, so
    // rc can read the disk as the script.
    const disk = c.join(&.{ tmp, "script.raw" });
    {
        const size = std.mem.alignForward(usize, script.len + 1, 1 << 16);
        const data = gpa.alloc(u8, size) catch oom();
        @memset(data, '\n');
        @memcpy(data[0..script.len], script);
        Dir.cwd().writeFile(io, .{ .sub_path = disk, .data = data }) catch |e| die("writing {s}: {t}", .{ disk, e });
    }

    log("booting 9front {s} in QEMU", .{release});
    var con: mkroot.Console = undefined;
    mkroot.boot(c, &con, image, tmp, disk);
    log("running {s}", .{script_path});
    // The markers are spelt with a ^ so the console's echo of the
    // command doesn't match them.
    con.send("rc /dev/sdG0/data >/tmp/conformance.out >[2=1]; echo CONF-^BEGIN; cat /tmp/conformance.out; echo CONF-^END");
    _ = con.until("CONF-BEGIN\r\n", 1800);
    const raw = con.until("CONF-END", 600);
    const out = std.mem.replaceOwned(u8, gpa, raw, "\r", "") catch oom();
    _ = con.cmd("fshalt", 120);
    con.close();
    mkroot.cleanup();

    Dir.cwd().writeFile(io, .{ .sub_path = golden_path, .data = out }) catch |e| die("writing {s}: {t}", .{ golden_path, e });
    log("wrote {s}", .{golden_path});
    return 0;
}
