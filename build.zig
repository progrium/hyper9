const std = @import("std");
const unicorn_src = @import("build/unicorn.zig");
const frontmatter = @import("tools/frontmatter.zig");

const drawterm = "third_party/drawterm";

// drawterm's kern/Makefile OFILES with AUDIO=none, without devtab.c and
// devenv.c (src/kern/ has our own) or devpipe.c (built with kern_notes
// below), plus the OS files below.
const kern_sources = [_][]const u8{
    "alloc.c",    "allocb.c",        "chan.c",   "data.c",     "dev.c",
    "devaudio.c", "devaudio-none.c", "devcmd.c", "devcons.c",  "devdraw.c",
    "devip.c",    "devkbd.c",        "devmnt.c", "devmouse.c",
    "devroot.c",  "devssl.c",        "devtls.c", "error.c",    "parse.c",
    "pgrp.c",     "procinit.c",      "rwlock.c", "sleep.c",    "stub.c",
    "sysfile.c",  "qio.c",           "qlock.c",  "term.c",     "waserror.c",
};
// drawterm files that post notes, built so their notes reach h9's note
// queue (src/kern/proc.c) instead of drawterm's postnote.
const kern_notes = [_][]const u8{"devpipe.c"};
// OS=posix (Make.unix), and OS=win32 with FS=fs-win32 (Make.win64).
const kern_posix = [_][]const u8{ "devfs-posix.c", "devip-posix.c", "devlfd-posix.c", "posix.c" };
const kern_win32 = [_][]const u8{ "devfs-win32.c", "devip-win32.c", "devlfd-win32.c", "win32.c" };

/// The drawterm libraries kern needs, with each Makefile's OFILES. The GUI,
/// exportfs, libauth and drawterm's own main/cpu code are left out.
const kern_libs = [_]struct { dir: []const u8, files: []const []const u8 }{
    .{ .dir = "libc", .files = &.{
        "atexit.c",      "charstod.c",    "cleanname.c",    "convD2M.c",      "convM2D.c",
        "convM2S.c",     "convS2M.c",     "ctime.c",        "crypt.c",        "dial.c",
        "dirfstat.c",    "dirfwstat.c",   "dirmodefmt.c",   "dirstat.c",      "dirwstat.c",
        "dofmt.c",       "dorfmt.c",      "encodefmt.c",    "fcallfmt.c",     "fltfmt.c",
        "fmt.c",         "fmtfd.c",       "fmtfdflush.c",   "fmtlock.c",      "fmtprint.c",
        "fmtquote.c",    "fmtrune.c",     "fmtstr.c",       "fmtvprint.c",    "fprint.c",
        "getenv.c",      "getfields.c",   "lock.c",         "mallocz.c",      "nan64.c",
        "netmkaddr.c",   "nsec.c",        "pow10.c",        "pushssl.c",      "pushtls.c",
        "read9pmsg.c",   "readn.c",       "rune.c",         "runefmtstr.c",   "runeseprint.c",
        "runesmprint.c", "runesnprint.c", "runesprint.c",   "runestrchr.c",   "runestrlen.c",
        "runestrstr.c",  "runetype.c",    "runevseprint.c", "runevsmprint.c", "runevsnprint.c",
        "seprint.c",     "smprint.c",     "snprint.c",      "sprint.c",       "strecpy.c",
        "strtod.c",      "strtoll.c",     "sysfatal.c",     "time.c",         "tokenize.c",
        "truerand.c",    "u16.c",         "u32.c",          "u64.c",          "utfecpy.c",
        "utflen.c",      "utfnlen.c",     "utfrrune.c",     "utfrune.c",      "utfutf.c",
        "vfprint.c",     "vseprint.c",    "vsmprint.c",     "vsnprint.c",
    } },
    .{ .dir = "libsec", .files = &.{
        "aes.c",       "aesni.c",        "aesCBC.c",        "aes_gcm.c",   "poly1305.c",
        "chacha.c",    "chachablock.c",  "ccpoly.c",        "des.c",       "des3CBC.c",
        "desmodes.c",  "ecc.c",          "jacobian.c",      "secp256k1.c", "secp256r1.c",
        "secp384r1.c", "curve25519.c",   "curve25519_dh.c", "genrandom.c", "fastrand.c",
        "nfastrand.c", "prng.c",         "hmac.c",          "hkdf.c",      "pbkdf2.c",
        "rsaalloc.c",  "rsadecrypt.c",   "rsaencrypt.c",    "dh.c",        "rc4.c",
        "md5.c",       "md5block.c",     "sha1.c",          "sha2_128.c",  "sha2_64.c",
        "sha1block.c", "sha2block128.c", "sha2block64.c",   "tlshand.c",   "x509.c",
        "tsmemcmp.c",
    } },
    .{ .dir = "libmp", .files = &.{
        "betomp.c",   "cnfield.c",        "crt.c",         "gmfield.c",    "letomp.c",
        "mpadd.c",    "mpaux.c",          "mpcmp.c",       "mpdigdiv.c",   "mpdiv.c",
        "mpexp.c",    "mpextendedgcd.c",  "mpfactorial.c", "mpfield.c",    "mpfmt.c",
        "mpinvert.c", "mpleft.c",         "mplogic.c",     "mpmod.c",      "mpmodop.c",
        "mpmul.c",    "mpnrand.c",        "mprand.c",      "mpright.c",    "mpsel.c",
        "mpsub.c",    "mptobe.c",         "mptober.c",     "mptoi.c",      "mptole.c",
        "mptolel.c",  "mptoui.c",         "mptouv.c",      "mptov.c",      "mpvecadd.c",
        "mpveccmp.c", "mpvecdigmuladd.c", "mpvecsub.c",    "mpvectscmp.c", "strtomp.c",
    } },
    .{ .dir = "libauthsrv", .files = &.{
        "_asgetticket.c", "_asrdresp.c", "convA2M.c",  "convM2A.c",      "convM2PR.c",
        "convM2T.c",      "convM2TR.c",  "convPR2M.c", "convT2M.c",      "convTR2M.c",
        "nvcsum.c",       "passtokey.c", "readcons.c", "_asgetpakkey.c", "_asgetresp.c",
        "_asrequest.c",   "authpak.c",   "form1.c",
    } },
    .{ .dir = "libip", .files = &.{ "eipfmt.c", "parseip.c", "classmask.c", "bo.c", "ipaux.c" } },
    .{ .dir = "libmemdraw", .files = &.{
        "alloc.c",  "arc.c",     "cload.c",          "cmap.c",     "cread.c",
        "defont.c", "draw.c",    "ellipse.c",        "fillpoly.c", "hwdraw.c",
        "line.c",   "load.c",    "openmemsubfont.c", "poly.c",     "read.c",
        "string.c", "subfont.c", "unload.c",         "write.c",    "warp.c",
    } },
    .{ .dir = "libmemlayer", .files = &.{
        "draw.c",     "warp.c",    "lalloc.c", "layerop.c", "ldelete.c",
        "lhide.c",    "line.c",    "load.c",   "lorigin.c", "lsetrefresh.c",
        "ltofront.c", "ltorear.c", "unload.c",
    } },
    .{ .dir = "libdraw", .files = &.{
        "alloc.c",    "arith.c",    "badrect.c", "bytesperline.c", "chan.c",
        "defont.c",   "drawrepl.c", "fmt.c",     "icossin.c",      "icossin2.c",
        "rectclip.c", "rgb.c",      "warp.c",    "mkwarp.c",
    } },
};

// posix-port's getcallerpc and tas are compiler builtins, so Windows uses
// them too (drawterm's win32 builds take them from per-CPU assembly).
const kern_port = [_][]const u8{ "getcallerpc.c", "tas.c" };

const kern_flags = [_][]const u8{
    "-Wall",
    "-Wno-missing-braces",
    "-D_THREAD_SAFE",
    "-fno-sanitize=undefined",
};
// Make.win64's CFLAGS.
const kern_flags_win32 = kern_flags ++ [_][]const u8{ "-DWINDOWS", "-DUNICODE" };

/// Zig's own macOS SDK detection runs xcodebuild, which fails in some
/// environments; SDKROOT (set by scripts/env.sh) is used when present.
/// Runs tests/integration.zig against the h9 binary. `filters` selects
/// cases by name; with `pending`, cases tagged with a proposal that isn't
/// implemented run instead of skipping.
fn addIntegration(b: *std.Build, optimize: std.builtin.OptimizeMode, filters: []const []const u8, h9_bin: []const u8, root: []const u8, backends: []const u8, pending: bool) *std.Build.Step.Run {
    const run = b.addRunArtifact(integrationTests(b, b.graph.host, optimize, filters));
    run.setEnvironmentVariable("H9_TEST_BIN", h9_bin);
    run.setEnvironmentVariable("H9_TEST_ROOT", root);
    run.setEnvironmentVariable("H9_TEST_BACKENDS", backends);
    if (pending) run.setEnvironmentVariable("H9_TEST_PENDING", "1");
    run.has_side_effects = true;
    return run;
}

/// tests/integration.zig as a test binary. It links libc for the pty in
/// tests/term.zig.
fn integrationTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, filters: []const []const u8) *std.Build.Step.Compile {
    return b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = target.result.os.tag != .windows,
            .imports = &.{.{ .name = "design", .module = designModule(b) }},
        }),
        .filters = filters,
    });
}

/// The proposals under design/, read from their frontmatter at configure
/// time. Bad files are left out; `zig build design -- check` reports them.
fn proposals(b: *std.Build) []const frontmatter.Proposal {
    const S = struct {
        var ps: ?[]const frontmatter.Proposal = null;
    };
    if (S.ps) |ps| return ps;
    const io = b.graph.io;
    var diags: frontmatter.Diags = .{ .gpa = b.allocator };
    var dir = b.build_root.handle.openDir(io, "design", .{ .iterate = true }) catch {
        S.ps = &.{};
        return S.ps.?;
    };
    defer dir.close(io);
    S.ps = frontmatter.scan(b.allocator, io, dir, &diags) catch &.{};
    return S.ps.?;
}

/// Build options for the integration tests: the tags of proposals that
/// aren't implemented, whose cases skip (built in, so the binary from
/// install-tests knows them too).
fn designModule(b: *std.Build) *std.Build.Module {
    const S = struct {
        var m: ?*std.Build.Module = null;
    };
    if (S.m) |m| return m;
    const options = b.addOptions();
    options.addOption([]const u8, "pending_tags", frontmatter.pendingTags(b.allocator, proposals(b)) catch @panic("OOM"));
    S.m = options.createModule();
    return S.m.?;
}

/// Test-name filters for the cases tagged with a proposal, by its slug or
/// its id: `[x]`, `[x, `, `, x]` and `, x, ` for each.
fn tagFilters(b: *std.Build, p: frontmatter.Proposal) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var names: [2][]const u8 = .{ p.slug, "" };
    var n: usize = 1;
    if (p.id) |id| {
        names[1] = b.fmt("{d}", .{id});
        n = 2;
    }
    for (names[0..n]) |t| {
        out.appendSlice(b.allocator, &.{ b.fmt("[{s}]", .{t}), b.fmt("[{s}, ", .{t}), b.fmt(", {s}]", .{t}), b.fmt(", {s}, ", .{t}) }) catch @panic("OOM");
    }
    return out.items;
}

/// Registers a demo for the proposal with this slug, which
/// `zig build proposal -Dp=...` runs.
fn addDemo(b: *std.Build, demos: *std.StringHashMapUnmanaged(std.ArrayList(*std.Build.Step)), slug: []const u8, step: *std.Build.Step) void {
    const entry = demos.getOrPut(b.allocator, slug) catch @panic("OOM");
    if (!entry.found_existing) entry.value_ptr.* = .empty;
    entry.value_ptr.append(b.allocator, step) catch @panic("OOM");
}

/// The number of entries in the root tree's /arm64/bin and /rc/bin, which
/// `ls /bin` lists one after the other; null without a tree.
fn countBin(b: *std.Build, root: []const u8) ?usize {
    const io = b.graph.io;
    var total: usize = 0;
    for ([_][]const u8{ "arm64/bin", "rc/bin" }) |sub| {
        var dir = std.Io.Dir.cwd().openDir(io, b.pathJoin(&.{ root, sub }), .{ .iterate = true }) catch return null;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch return null) |_| total += 1;
    }
    return total;
}

fn addSdkPaths(b: *std.Build, m: *std.Build.Module) void {
    const sdk = b.graph.environ_map.get("SDKROOT") orelse return;
    m.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
    m.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) });
    m.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
}

pub const Emu = enum { none, unicorn };

/// Where -Demu=unicorn gets Unicorn: the PyPI wheels' libunicorn.a, or a
/// build from the patched source (build/unicorn.zig).
pub const UnicornFrom = enum { prebuilt, source };

/// Directory under .local/unicorn (see UNICORN_WHEELS in scripts/pins.sh)
/// with the prebuilt libunicorn.a for this target, if one exists.
fn unicornDir(t: std.Target) ?[]const u8 {
    return switch (t.os.tag) {
        .macos => if (t.cpu.arch == .aarch64) "aarch64-macos" else null,
        .linux => if (t.abi.isMusl()) switch (t.cpu.arch) {
            .aarch64 => "aarch64-linux-musl",
            .x86_64 => "x86_64-linux-musl",
            else => null,
        } else null,
        else => null,
    };
}

/// Adds Unicorn: returns its translated header as a module and records the
/// libraries for `linkUnicorn`.
fn addUnicorn(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, from: UnicornFrom) ?*std.Build.Module {
    if (from == .source) return addUnicornSource(b, target, optimize);
    const name = unicornDir(target.result) orelse {
        b.getInstallStep().dependOn(&b.addFail("-Demu=unicorn: no prebuilt Unicorn for this target (macOS arm64 and linux-musl arm64/x86_64 only; try -Dunicorn=source)").step);
        return null;
    };
    const dir = b.pathJoin(&.{ ".local/unicorn", name });
    const lib = b.pathJoin(&.{ dir, "lib/libunicorn.a" });
    if (b.build_root.handle.access(b.graph.io, lib, .{})) {} else |_| {
        b.getInstallStep().dependOn(&b.addFail(b.fmt("{s} is missing; run scripts/fetch.sh", .{lib})).step);
        return null;
    }
    const wf = b.addWriteFiles();
    const h = wf.add("unicorn.h", "#include <unicorn/unicorn.h>\n");
    const tc = b.addTranslateC(.{ .root_source_file = h, .target = target, .optimize = optimize });
    tc.addIncludePath(b.path(b.pathJoin(&.{ dir, "include" })));
    unicorn_lib = b.path(lib);
    if (target.result.os.tag == .linux and target.result.cpu.arch == .aarch64) {
        // An archive, not a source file: the root module's objects can reach
        // the linker twice, and archive members don't clash.
        const compat = b.addLibrary(.{
            .name = "unicorn_compat",
            .linkage = .static,
            .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
        });
        compat.root_module.addAssemblyFile(b.path("src/vmm/unicorn_compat_aarch64.S"));
        unicorn_compat = compat;
    }
    return tc.createModule();
}

/// Unicorn from the source that scripts/fetch.sh unpacks and patches.
fn addUnicornSource(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) ?*std.Build.Module {
    if (unicorn_src.configName(target.result) == null) {
        b.getInstallStep().dependOn(&b.addFail("-Dunicorn=source: no config for this target in third_party/unicorn/config").step);
        return null;
    }
    if (b.build_root.handle.access(b.graph.io, unicorn_src.src_dir ++ "/.h9-stamp", .{})) {} else |_| {
        b.getInstallStep().dependOn(&b.addFail(unicorn_src.src_dir ++ " is missing; run scripts/fetch.sh").step);
        return null;
    }
    const uc = unicorn_src.build(b, target, optimize).?;
    unicorn_libs = uc.libs;
    const wf = b.addWriteFiles();
    // translate-c can't handle mingw's fortified wcscat/wcscpy, which
    // ReleaseSafe turns on; only Unicorn's declarations are needed here.
    const h = wf.add("unicorn.h", "#undef _FORTIFY_SOURCE\n#include <unicorn/unicorn.h>\n");
    const tc = b.addTranslateC(.{ .root_source_file = h, .target = target, .optimize = optimize });
    tc.addIncludePath(uc.include);
    return tc.createModule();
}

var unicorn_lib: ?std.Build.LazyPath = null;
var unicorn_compat: ?*std.Build.Step.Compile = null;
var unicorn_libs: ?[3]*std.Build.Step.Compile = null;

/// Links Unicorn into the compile step's root module.
fn linkUnicorn(c: *std.Build.Step.Compile) void {
    const m = c.root_module;
    if (unicorn_libs) |libs| {
        m.link_libc = true;
        for (libs) |l| m.linkLibrary(l);
        return;
    }
    const lib = unicorn_lib orelse return;
    m.link_libc = true;
    m.addObjectFile(lib);
    if (unicorn_compat) |compat| m.linkLibrary(compat);
}

/// `git describe --tags --always --dirty` for the source tree, or
/// build.zig.zon's version when that fails (a source tarball).
fn gitVersion(b: *std.Build) []const u8 {
    var code: u8 = 0;
    const out = b.runAllowFail(&.{ "git", "-C", b.build_root.path orelse ".", "describe", "--tags", "--always", "--dirty" }, &code, .ignore) catch
        return zonVersion(b);
    const v = std.mem.trim(u8, out, " \r\n");
    return if (v.len > 0) v else zonVersion(b);
}

/// build.zig.zon's `.version`, read as text so the manifest needs no type.
fn zonVersion(b: *std.Build) []const u8 {
    const zon = b.build_root.handle.readFileAlloc(b.graph.io, "build.zig.zon", b.allocator, .limited(1 << 16)) catch return "unknown";
    const key = ".version = \"";
    const i = std.mem.indexOf(u8, zon, key) orelse return "unknown";
    const rest = zon[i + key.len ..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, '"') orelse return "unknown"];
}

/// The value of `NAME=value` in scripts/pins.sh, without a trailing
/// comment, or "unknown".
fn pin(pins: []const u8, comptime name: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, pins, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, name ++ "=")) continue;
        var toks = std.mem.tokenizeAny(u8, line[name.len + 1 ..], " \t#");
        return toks.next() orelse "unknown";
    }
    return "unknown";
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os = target.result.os.tag;
    var emu = b.option(Emu, "emu", "Emulator backend to build in (GPLv2 Unicorn: dev, CI and the h9-emu release only)") orelse .none;
    // No wheel exists for Windows, so it always builds from source.
    const unicorn_from = b.option(UnicornFrom, "unicorn", "With -Demu=unicorn: the prebuilt wheel library or a source build (default: prebuilt, source on Windows)") orelse
        if (os == .windows) UnicornFrom.source else .prebuilt;

    const mod = b.addModule("h9", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    if (emu == .unicorn) {
        // On failure addUnicorn has already made the install step fail.
        if (addUnicorn(b, target, optimize, unicorn_from)) |uc| mod.addImport("unicorn", uc) else emu = .none;
    }
    // The arm64 guest shim, assembled freestanding and embedded as raw bytes.
    const shim_obj = b.addObject(.{
        .name = "shim_arm64",
        .root_module = b.createModule(.{
            .target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .freestanding }),
            .optimize = .ReleaseSmall,
        }),
    });
    shim_obj.root_module.addAssemblyFile(b.path("src/arch/arm64/shim.S"));
    const shim_bin = b.addObjCopy(shim_obj.getEmittedBin(), .{ .format = .bin, .only_section = ".text" });
    mod.addAnonymousImport("shim_arm64", .{ .root_source_file = shim_bin.getOutput() });

    const kern = b.addLibrary(.{
        .name = "kern",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    kern.root_module.addIncludePath(b.path(drawterm));
    kern.root_module.addIncludePath(b.path(drawterm ++ "/include"));
    kern.root_module.addIncludePath(b.path(drawterm ++ "/kern"));
    kern.root_module.addIncludePath(b.path("src/kern")); // fscheck.h, for devfs
    const flags: []const []const u8 = if (os == .windows) &kern_flags_win32 else &kern_flags;
    kern.root_module.addCSourceFiles(.{
        .root = b.path(drawterm ++ "/kern"),
        .files = &kern_sources,
        .flags = flags,
    });
    kern.root_module.addCSourceFiles(.{
        .root = b.path(drawterm ++ "/kern"),
        .files = &kern_notes,
        .flags = std.mem.concat(b.allocator, []const u8, &.{ flags, &.{"-Dpostnote=h9_postnote"} }) catch @panic("OOM"),
    });
    kern.root_module.addCSourceFiles(.{
        .root = b.path(drawterm ++ "/kern"),
        .files = if (os == .windows) &kern_win32 else &kern_posix,
        .flags = flags,
    });
    kern.root_module.addCSourceFiles(.{
        .root = b.path("src/kern"),
        .files = &.{ "glue.c", "proc.c", "devtab.c", "devhcons.c", "devenv.c", "devdup.c", "devproc.c", "fscheck.c" },
        .flags = flags,
    });
    for (kern_libs) |l| kern.root_module.addCSourceFiles(.{
        .root = b.path(b.pathJoin(&.{ drawterm, l.dir })),
        .files = l.files,
        .flags = flags,
    });
    // Zig's bundled musl memccpy is broken; see src/kern/memccpy.c.
    if (target.result.abi.isMusl()) {
        kern.root_module.addCSourceFiles(.{ .root = b.path("src/kern"), .files = &.{"memccpy.c"}, .flags = flags });
        kern.root_module.addCMacro("memccpy", "h9_memccpy");
    }
    if (os == .windows) {
        kern.root_module.addCSourceFiles(.{ .root = b.path("src/kern"), .files = &.{"glue-win32.c"}, .flags = flags });
        kern.root_module.linkSystemLibrary("ws2_32", .{});
        kern.root_module.linkSystemLibrary("advapi32", .{});
    }
    kern.root_module.addCSourceFiles(.{
        .root = b.path(drawterm ++ "/posix-port"),
        .files = &kern_port,
        .flags = flags,
    });
    const kern_step = b.step("kern", "Compile drawterm's kern");
    const have_drawterm = if (b.build_root.handle.access(b.graph.io, drawterm ++ "/kern/sysfile.c", .{})) true else |_| false;
    if (!have_drawterm) {
        const fail = b.addFail(drawterm ++ " is missing; run scripts/vendor-drawterm.sh");
        kern.step.dependOn(&fail.step);
    }
    const build_kern = have_drawterm;
    kern_step.dependOn(&kern.step);
    // Everything that imports the h9 module links kern.
    mod.linkLibrary(kern);

    const options = b.addOptions();
    options.addOption(Emu, "emu", emu);
    options.addOption(bool, "kern", build_kern);
    // For --version: scripts/release.sh passes -Dversion; otherwise git
    // describe, or build.zig.zon's version where there's no git checkout.
    options.addOption([]const u8, "version", b.option([]const u8, "version", "Version h9 --version reports (default: git describe, else build.zig.zon's)") orelse gitVersion(b));
    const pins = b.build_root.handle.readFileAlloc(b.graph.io, "scripts/pins.sh", b.allocator, .limited(1 << 16)) catch "";
    options.addOption([]const u8, "ninefront_release", pin(pins, "NINEFRONT_RELEASE"));
    options.addOption([]const u8, "ninefront_rev", pin(pins, "NINEFRONT_REV"));
    options.addOption([]const u8, "drawterm_rev", pin(pins, "DRAWTERM_REV"));
    mod.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "h9",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "h9", .module = mod },
                // --check runs the hello fixture on each backend.
                .{ .name = "hello", .module = b.createModule(.{ .root_source_file = b.path("tests/fixtures/hello.zig"), .target = target }) },
            },
        }),
    });
    if (os == .macos) {
        addSdkPaths(b, exe.root_module);
        addSdkPaths(b, kern.root_module);
        exe.root_module.linkFramework("Hypervisor", .{});
    }
    linkUnicorn(exe);

    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);

    // HVF refuses hv_vm_create without the hypervisor entitlement.
    var signed_step = &install_exe.step;
    if (os == .macos and b.graph.host.result.os.tag == .macos) {
        const sign = b.addSystemCommand(&.{ "codesign", "--force", "--sign", "-", "--entitlements" });
        sign.addFileArg(b.path("h9.entitlements"));
        sign.addArg(b.getInstallPath(.bin, exe.out_filename));
        sign.step.dependOn(&install_exe.step);
        b.getInstallStep().dependOn(&sign.step);
        signed_step = &sign.step;
    }

    const run_cmd = b.addSystemCommand(&.{b.getInstallPath(.bin, exe.out_filename)});
    run_cmd.step.dependOn(signed_step);
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run h9").dependOn(&run_cmd.step);

    // Fixed paths, not the install prefix, so `--prefix /usr/local clean` can't remove it.
    const clean_cmd = b.addSystemCommand(&.{ "rm", "-rf", b.pathFromRoot("zig-out"), b.pathFromRoot(".zig-cache") });
    b.step("clean", "Remove zig-out and .zig-cache").dependOn(&clean_cmd.step);

    // Fixtures: hand-assembled hello a.outs for arm64 and amd64.
    const mkhello = b.addExecutable(.{
        .name = "mkhello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fixtures/mkhello.zig"),
            .target = b.graph.host,
            .imports = &.{
                .{ .name = "aout", .module = b.createModule(.{ .root_source_file = b.path("src/aout.zig"), .target = b.graph.host }) },
                .{ .name = "hello", .module = b.createModule(.{ .root_source_file = b.path("tests/fixtures/hello.zig"), .target = b.graph.host }) },
            },
        }),
    });
    var hellos: [2]std.Build.LazyPath = undefined;
    for (&hellos, [_][]const u8{ "arm64", "amd64" }, [_][]const u8{ "hello", "hello-amd64" }) |*out, arch, name| {
        const gen = b.addRunArtifact(mkhello);
        gen.addArg(arch);
        out.* = gen.addOutputFileArg(name);
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(out.*, .{ .custom = "fixtures" }, name).step);
    }

    // Proposal demos that aren't integration cases, by the proposal's slug;
    // `zig build proposal -Dp=...` runs them along with its tagged cases.
    var demos: std.StringHashMapUnmanaged(std.ArrayList(*std.Build.Step)) = .empty;

    // Baseline demos: the host architecture's hello on the default backend,
    // and on the emulator when it's built in.
    const host_hello = if (target.result.cpu.arch == .x86_64) hellos[1] else hellos[0];
    const hello_demo = b.addSystemCommand(&.{b.getInstallPath(.bin, exe.out_filename)});
    hello_demo.addFileArg(host_hello);
    hello_demo.expectStdOutEqual("hello\n");
    hello_demo.step.dependOn(signed_step);
    addDemo(b, &demos, "baseline", &hello_demo.step);
    if (emu == .unicorn) {
        const emu_demo = b.addSystemCommand(&.{ b.getInstallPath(.bin, exe.out_filename), "--backend", "emu" });
        emu_demo.addFileArg(host_hello);
        emu_demo.expectStdOutEqual("hello\n");
        emu_demo.step.dependOn(signed_step);
        addDemo(b, &demos, "baseline", &emu_demo.step);
    }

    // The rest run real 9front binaries from a host root tree, so they're
    // left out without one, as the integration cases skip.
    const root = b.option([]const u8, "root", "9front root tree for the demos and integration tests (default .local/9front/root)") orelse
        b.pathFromRoot(".local/9front/root");
    const h9_bin = b.getInstallPath(.bin, exe.out_filename);

    if (b.build_root.handle.readFileAlloc(b.graph.io, b.pathJoin(&.{ root, "lib/namespace" }), b.allocator, .limited(1 << 20))) |namespace| {
        const cat_demo = b.addSystemCommand(&.{ h9_bin, "--root", root, "/bin/cat", "/lib/namespace" });
        cat_demo.expectStdOutEqual(namespace);
        cat_demo.step.dependOn(signed_step);
        addDemo(b, &demos, "baseline", &cat_demo.step);
        // The tight profile's cwd is read-only, so rc's redirection fails. The
        // cwd is a fresh directory, so nothing is left behind if it doesn't.
        const tight_cwd = b.addWriteFiles();
        _ = tight_cwd.add(".keep", "");
        const tight_demo = b.addSystemCommand(&.{ h9_bin, "--root", root, "--profile=tight", "--cwd" });
        tight_demo.addDirectoryArg(tight_cwd.getDirectory());
        tight_demo.addArgs(&.{ "--rc", "echo x > /mnt/term/cwd/f" });
        tight_demo.expectExitCode(1);
        tight_demo.expectStdErrMatch("can't create");
        tight_demo.step.dependOn(signed_step);
        addDemo(b, &demos, "baseline", &tight_demo.step);
    } else |_| {}

    // ls prints each member of the /bin union, duplicates and all, so the
    // count is the two directories' entries added together.
    if (countBin(b, root)) |n| {
        const ls_demo = b.addSystemCommand(&.{ h9_bin, "--root", root, "--rc", "ls /bin | wc -l" });
        ls_demo.expectStdOutEqual(b.fmt("{d: >7}\n", .{n}));
        ls_demo.step.dependOn(signed_step);
        addDemo(b, &demos, "baseline", &ls_demo.step);
    }

    // Each integration case runs on every backend built in that runs arm64 here.
    var backends: std.ArrayList(u8) = .empty;
    if (os == .macos and target.result.cpu.arch == .aarch64) backends.appendSlice(b.allocator, "hvf,") catch @panic("OOM");
    if (emu == .unicorn) backends.appendSlice(b.allocator, "emu,") catch @panic("OOM");
    const backend_list = if (backends.items.len > 0) backends.items else "auto";

    // Runs real binaries through the h9 CLI; skipped without a root tree.
    // Cases tagged with a proposal that isn't implemented skip unless
    // -Dpending is given.
    const run_pending = b.option(bool, "pending", "Also run integration cases of proposals that aren't implemented yet") orelse false;
    const run_integration = addIntegration(b, optimize, &.{}, h9_bin, root, backend_list, run_pending);
    run_integration.step.dependOn(signed_step);
    b.step("integration", "Run real 9front binaries from the root tree through h9").dependOn(&run_integration.step);

    // One proposal's demos and integration cases (design/), whatever its
    // status, by id or slug.
    const proposal_step = b.step("proposal", "Run one proposal's demos and integration cases: -Dp=<id or slug>");
    // A demo registered for a slug that isn't a proposal would never run.
    var demo_slugs = demos.keyIterator();
    while (demo_slugs.next()) |slug| if (frontmatter.resolve(proposals(b), slug.*) == null)
        std.debug.panic("build.zig: addDemo for `{s}`, which isn't a proposal under design/", .{slug.*});
    if (b.option([]const u8, "p", "With zig build proposal: the proposal, by id or slug")) |ref| {
        const ps = proposals(b);
        if (frontmatter.resolve(ps, ref)) |i| {
            const run_cases = addIntegration(b, optimize, tagFilters(b, ps[i]), h9_bin, root, backend_list, true);
            run_cases.step.dependOn(signed_step);
            proposal_step.dependOn(&run_cases.step);
            if (demos.get(ps[i].slug)) |steps| for (steps.items) |s| proposal_step.dependOn(s);
        } else proposal_step.dependOn(&b.addFail(b.fmt("-Dp={s} isn't a proposal under design/", .{ref})).step);
    } else proposal_step.dependOn(&b.addFail("zig build proposal needs -Dp=<id or slug>").step);

    // The design tool (design/0001-proposals.md), run from the repository
    // root: zig build design -- check, list, ready and so on.
    const design_tool = b.addExecutable(.{
        .name = "design",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/design.zig"),
            .target = b.graph.host,
        }),
    });
    const run_design = b.addRunArtifact(design_tool);
    run_design.setCwd(b.path("."));
    run_design.has_side_effects = true;
    if (b.args) |args| run_design.addArgs(args);
    b.step("design", "Run the design tool: zig build design -- <command> (help lists them)").dependOn(&run_design.step);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    linkUnicorn(mod_tests); // exe_tests shares exe's root module, already linked
    // Runs the same programs on every backend built in and compares them.
    const backend_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/backends.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "h9", .module = mod },
            .{ .name = "hello", .module = b.createModule(.{ .root_source_file = b.path("tests/fixtures/hello.zig"), .target = target }) },
        },
    }) });
    if (os == .macos) {
        addSdkPaths(b, backend_tests.root_module);
        backend_tests.root_module.linkFramework("Hypervisor", .{});
    }
    linkUnicorn(backend_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    // The design tool's tests read tools/testdata from the repository root.
    const design_tests = b.addRunArtifact(b.addTest(.{ .root_module = design_tool.root_module }));
    design_tests.setCwd(b.path("."));
    test_step.dependOn(&design_tests.step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    // HVF needs the entitlement, so the test binary is signed like h9.
    const run_backend_tests = b.addRunArtifact(backend_tests);
    if (os == .macos and b.graph.host.result.os.tag == .macos) {
        const sign = b.addSystemCommand(&.{ "codesign", "--force", "--sign", "-", "--entitlements" });
        sign.addFileArg(b.path("h9.entitlements"));
        sign.addFileArg(backend_tests.getEmittedBin());
        run_backend_tests.step.dependOn(&sign.step);
    }
    test_step.dependOn(&run_backend_tests.step);
    test_step.dependOn(&run_integration.step);

    // The speed numbers in DESIGN.md's "Limits and selection". Always
    // ReleaseFast (the h9 module inherits it), whatever -Doptimize says.
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "h9", .module = mod }},
        }),
    });
    if (os == .macos) {
        addSdkPaths(b, bench.root_module);
        bench.root_module.linkFramework("Hypervisor", .{});
    }
    linkUnicorn(bench);
    const run_bench = b.addRunArtifact(bench);
    run_bench.has_side_effects = true;
    if (os == .macos and b.graph.host.result.os.tag == .macos) {
        const sign = b.addSystemCommand(&.{ "codesign", "--force", "--sign", "-", "--entitlements" });
        sign.addFileArg(b.path("h9.entitlements"));
        sign.addFileArg(bench.getEmittedBin());
        run_bench.step.dependOn(&sign.step);
    }
    b.step("bench", "Time a compute loop and pwrite round trips on every backend built in").dependOn(&run_bench.step);

    // For running the tests in a VM (scripts/lima/vm test): the backend
    // tests and the integration tests, built for the target.
    const install_tests_step = b.step("install-tests", "Install the backend and integration tests as zig-out/bin/backend-tests and integration-tests");
    install_tests_step.dependOn(&b.addInstallArtifact(backend_tests, .{ .dest_sub_path = b.fmt("backend-tests{s}", .{target.result.exeFileExt()}) }).step);
    install_tests_step.dependOn(&b.addInstallArtifact(integrationTests(b, target, optimize, &.{}), .{ .dest_sub_path = b.fmt("integration-tests{s}", .{target.result.exeFileExt()}) }).step);
}
