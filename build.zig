const std = @import("std");
const unicorn_src = @import("build/unicorn.zig");
const frontmatter = @import("tools/frontmatter.zig");
const guesttree = @import("tools/guesttree.zig");

const drawterm = "third_party/drawterm";

// drawterm's kern/Makefile OFILES with AUDIO=none, without devtab.c and
// devenv.c (src/kern/ has our own) or devpipe.c (built with kern_notes
// below), plus the OS files below.
const kern_sources = [_][]const u8{
    "alloc.c",    "allocb.c",        "chan.c",   "data.c",     "dev.c",
    "devaudio.c", "devaudio-none.c", "devcmd.c", "devcons.c",  "devdraw.c",
    "devip.c",    "devkbd.c",        "devmnt.c", "devmouse.c", "devroot.c",
    "devssl.c",   "devtls.c",        "error.c",  "parse.c",    "pgrp.c",
    "procinit.c", "rwlock.c",        "sleep.c",  "stub.c",     "sysfile.c",
    "qio.c",      "qlock.c",         "term.c",   "waserror.c",
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

const kern_flags_common = [_][]const u8{
    "-Wall",
    "-Wno-missing-braces",
    "-D_THREAD_SAFE",
    "-fno-sanitize=undefined",
};
// PTHREAD, as Make.linux, makes libc/lock.c's Lock a pthread mutex. Without
// it unlock is a plain store with no release ordering, so on arm64 another
// thread can take the lock before seeing the writes made under it, which
// corrupted QLock queues and hung processes under contention.
const kern_flags = kern_flags_common ++ [_][]const u8{"-DPTHREAD"};
// Make.win64's CFLAGS.
const kern_flags_win32 = kern_flags_common ++ [_][]const u8{ "-DWINDOWS", "-DUNICODE" };

/// Zig's own macOS SDK detection runs xcodebuild, which fails in some
/// environments; SDKROOT (set by scripts/env.sh) is used when present.
/// Programs in tests/fixtures/segattach, for tests/backends.zig.
const segattach_fixtures = [_][]const u8{
    "shared_rfork", "memory_rfork", "place",  "sixth",     "detach",
    "segbrk",       "segfree",      "ronly",  "execfault", "headroom",
    "brkstop",      "exec_a",       "exec_b", "sibling",   "procseg",
};
/// Programs in tests/fixtures/overlay, for tests/backends.zig. They use the
/// segattach fixtures' lib.S.
const overlay_fixtures = [_][]const u8{ "tmp_own", "tmp_absent", "copyup_reader", "root_own", "root_absent" };
/// Programs in tests/fixtures/srv, for tests/backends.zig, with the same lib.S.
const srv_fixtures = [_][]const u8{ "board", "hold", "absent", "orclose" };
/// Programs in tests/fixtures/htools, for tests/backends.zig, with the same lib.S.
const htools_fixtures = [_][]const u8{ "tree", "masked" };

/// Programs in tests/fixtures/sema, for tests/backends.zig; they include
/// the segattach fixtures' lib.S.
const sema_fixtures = [_][]const u8{
    "rendezvous", "semacquire", "count", "badarg", "odd", "unmapped", "interrupt",
};

/// Programs in tests/fixtures/net, for tests/backends.zig. They share
/// tests/fixtures/segattach/lib.S.
const net_fixtures = [_][]const u8{ "ctl", "cs" };

/// Programs in tests/fixtures/gfx, for tests/backends.zig's [gfx] cases on
/// the headless backend, with the same lib.S.
const gfx_fixtures = [_][]const u8{ "binds", "drawnew", "draw", "kbd", "mouse", "snarf", "sleep" };

/// Runs tests/integration.zig against the h9 binary. `filters` selects
/// cases by name; with `pending`, cases tagged with a proposal that isn't
/// implemented run instead of skipping. `arch`, if given, is passed to h9
/// as --arch (from -Darch). `guest_test` says h9 was built with
/// -Dguest-test, and `host_cmd` that it was built with -Dhost-cmd. `src`,
/// if given, is a 9front checkout's `sys` directory, which the self-host
/// cases bind over /sys when the root lacks /sys/src.
fn addIntegration(b: *std.Build, optimize: std.builtin.OptimizeMode, filters: []const []const u8, h9_bin: []const u8, root: []const u8, backends: []const u8, pending: bool, arch: ?[]const u8, go: ?GoFixtures, guest_test: bool, host_cmd: bool, src: ?[]const u8) *std.Build.Step.Run {
    const run = b.addRunArtifact(integrationTests(b, b.graph.host, optimize, filters));
    // The self-host cases' source when the root has no /sys/src
    // (design/0010-self-host.md).
    if (src) |dir| run.setEnvironmentVariable("H9_TEST_SRC", dir);
    // h9 serves tests/fixtures/guest in #H (design/0032-guest-tools.md).
    if (guest_test) run.setEnvironmentVariable("H9_TEST_GUEST_TOOLS", "1");
    // Built with -Dhost-cmd: the host command cases run.
    if (host_cmd) run.setEnvironmentVariable("H9_TEST_HOST_CMD", "1");
    if (arch) |a| run.setEnvironmentVariable("H9_TEST_ARCH", a);
    if (go) |g| {
        run.setEnvironmentVariable("H9_TEST_GO", g.dir);
        run.step.dependOn(g.step);
    }
    run.setEnvironmentVariable("H9_TEST_BIN", h9_bin);
    run.setEnvironmentVariable("H9_TEST_ROOT", root);
    run.setEnvironmentVariable("H9_TEST_BACKENDS", backends);
    // The tree `zig build slim` makes, for the multicall cases, which skip
    // without it (design/0064-multicall.md).
    const release = pin(b.build_root.handle.readFileAlloc(b.graph.io, "scripts/pins.sh", b.allocator, .limited(1 << 16)) catch "", "NINEFRONT_RELEASE");
    run.setEnvironmentVariable("H9_TEST_SLIM_ROOT", b.pathFromRoot(b.fmt(".local/9front/slim-{s}-{s}", .{ release, arch orelse "arm64" })));
    if (pending) run.setEnvironmentVariable("H9_TEST_PENDING", "1");
    run.has_side_effects = true;
    return run;
}

/// The Go fixtures (tests/fixtures/go, design/0007-go-compat.md): plan9/amd64
/// binaries built with the pinned Go toolchain into `dir` by `step`.
const GoFixtures = struct { dir: []const u8, step: *std.Build.Step };

/// The environment for building plan9/amd64 binaries with Go at the
/// pinned version: GOTOOLCHAIN makes any installed Go fetch that exact
/// toolchain, so every host builds the same binaries.
fn goEnv(run: *std.Build.Step.Run, version: []const u8) void {
    run.setEnvironmentVariable("GOOS", "plan9");
    run.setEnvironmentVariable("GOARCH", "amd64");
    run.setEnvironmentVariable("CGO_ENABLED", "0");
    run.setEnvironmentVariable("GOTOOLCHAIN", run.step.owner.fmt("go{s}", .{version}));
}

/// `go build` of every program in tests/fixtures/go into zig-out/fixtures/go.
/// Go's own cache decides what to rebuild, so the step always runs.
fn addGoFixtures(b: *std.Build, go: []const u8, version: []const u8) GoFixtures {
    const dir = b.getInstallPath(.prefix, "fixtures/go");
    const run = b.addSystemCommand(&.{ go, "-C", "tests/fixtures/go", "build", "-trimpath", "-o", b.fmt("{s}{s}", .{ dir, std.fs.path.sep_str }), "./..." });
    run.setCwd(b.path("."));
    goEnv(run, version);
    run.has_side_effects = true;
    return .{ .dir = dir, .step = &run.step };
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
            .imports = &.{
                .{ .name = "design", .module = designModule(b) },
                .{ .name = "ws", .module = b.createModule(.{ .root_source_file = b.path("src/ws.zig") }) },
            },
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

/// The table of src/guest/ (with src/guest-hostcmd/ under -Dhost-cmd, and
/// tests/fixtures/guest with `with_test`)
/// as a generated Zig file, and the number of entries in its bin. A file
/// the tree can't hold fails the build.
fn guestTree(b: *std.Build, with_test: bool, host_cmd: bool) struct { file: std.Build.LazyPath, bin: usize } {
    const io = b.graph.io;
    const wf = b.addWriteFiles();
    var inputs: std.ArrayList(guesttree.Input) = .empty;
    for ([_][]const u8{ "src/guest", "src/guest-hostcmd", "tests/fixtures/guest" }, [_]bool{ true, host_cmd, with_test }) |sub, want| {
        if (!want) continue;
        var dir = b.build_root.handle.openDir(io, sub, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        const found = guesttree.scan(b.allocator, io, dir) catch |err| {
            wf.step.dependOn(&b.addFail(b.fmt("{s}: {t}", .{ sub, err })).step);
            return .{ .file = wf.add("guest_tree.zig", ""), .bin = 0 };
        };
        inputs.appendSlice(b.allocator, found) catch @panic("OOM");
    }
    var why: []const u8 = "";
    const entries = guesttree.build(b.allocator, inputs.items, &why) catch |err| switch (err) {
        error.Rejected => {
            wf.step.dependOn(&b.addFail(b.fmt("guest tree: {s}", .{why})).step);
            return .{ .file = wf.add("guest_tree.zig", ""), .bin = 0 };
        },
        error.OutOfMemory => @panic("OOM"),
    };
    var out: std.Io.Writer.Allocating = .init(b.allocator);
    guesttree.render(&out.writer, entries) catch @panic("OOM");
    var bin: usize = 0;
    for (entries) |e| {
        if (e.parent == 0 or entries[e.parent].parent != 0) continue;
        if (std.mem.eql(u8, entries[e.parent].name, "bin")) bin += 1;
    }
    return .{ .file = wf.add("guest_tree.zig", out.written()), .bin = bin };
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

/// The GUI backend behind --gfx (design/0015-gfx.md), from -Dgfx.
pub const Gfx = enum {
    /// No screen: src/kern/nogfx.c, and --gfx fails with GfxNotBuilt.
    none,
    /// A screen in memory, for tests (src/kern/gfx-headless.c).
    headless,
    /// drawterm's gui-x11, against a glibc target and the system's libX11.
    x11,
    /// drawterm's gui-win32.
    win32,
    /// drawterm's gui-cocoa, built with the macOS SDK.
    cocoa,

    fn default(t: std.Target) Gfx {
        return switch (t.os.tag) {
            .macos => .cocoa,
            .windows => .win32,
            else => .none,
        };
    }

    /// Why this backend can't be built for `t`, if it can't.
    fn unsupported(g: Gfx, t: std.Target) ?[]const u8 {
        return switch (g) {
            .none, .headless => null,
            .cocoa => if (t.os.tag != .macos) "Cocoa is macOS only" else null,
            .win32 => if (t.os.tag != .windows) "Win32 is Windows only" else null,
            .x11 => if (t.os.tag != .linux) "X11 is built for Linux only" else if (t.abi.isMusl()) "X11 needs a glibc target, such as -Dtarget=x86_64-linux-gnu, to link the system's libX11" else null,
        };
    }
};

/// What every h9 module shares; `addH9Module` makes one per GUI backend.
const ModuleParts = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    emu: Emu,
    unicorn: ?*std.Build.Module,
    shim: std.Build.LazyPath,
    shim_amd64: std.Build.LazyPath,
    host_cmd: bool,
    guest_tree: std.Build.LazyPath,
    have_drawterm: bool,
    version: []const u8,
    pins: []const u8,
};

const H9Module = struct { mod: *std.Build.Module, kern: *std.Build.Step.Compile };

/// The h9 module and the drawterm kern it links, with GUI backend `gfx`.
/// `exported` makes it the package's `h9` module, for embedders.
fn addH9Module(b: *std.Build, p: ModuleParts, gfx: Gfx, exported: bool) H9Module {
    const target = p.target;
    const optimize = p.optimize;
    const os = target.result.os.tag;
    const opts: std.Build.Module.CreateOptions = .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    };
    const mod = if (exported) b.addModule("h9", opts) else b.createModule(opts);
    if (p.unicorn) |uc| mod.addImport("unicorn", uc);
    mod.addAnonymousImport("shim_arm64", .{ .root_source_file = p.shim });
    mod.addAnonymousImport("shim_amd64", .{ .root_source_file = p.shim_amd64 });

    const kern = b.addLibrary(.{
        .name = if (gfx == .headless and !exported) "kern-headless" else "kern",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    kern.root_module.addIncludePath(b.path(drawterm));
    kern.root_module.addIncludePath(b.path(drawterm ++ "/include"));
    kern.root_module.addIncludePath(b.path(drawterm ++ "/kern"));
    kern.root_module.addIncludePath(b.path("src/kern")); // fscheck.h and netcheck.h, for devfs and devip
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
        // oscmd and friends are renamed so src/kern/hostcmd.c can wrap them:
        // a machine's host commands die with it.
        .flags = std.mem.concat(b.allocator, []const u8, &.{ flags, &.{ "-Doscmd=h9_dt_oscmd", "-Doscmdkill=h9_dt_oscmdkill", "-Doscmdfree=h9_dt_oscmdfree" } }) catch @panic("OOM"),
    });
    kern.root_module.addCSourceFiles(.{
        .root = b.path("src/kern"),
        .files = &.{ "glue.c", "proc.c", "devtab.c", "devhcons.c", "devenv.c", "devdup.c", "devproc.c", "devoverlay.c", "devsrv.c", "devhtools.c", "fscheck.c", "netcheck.c", "consx.c", "tsleep.c", "sema.c", "rootdial.c", "devhstream.c", "hostcmd.c" },
        .flags = flags,
    });
    addGfxSources(b, kern, gfx, flags);
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
    if (os == .macos) addSdkPaths(b, kern.root_module);
    kern.root_module.addCSourceFiles(.{
        .root = b.path(drawterm ++ "/posix-port"),
        .files = &kern_port,
        .flags = flags,
    });
    // devtab.c lists devcmd (#C) only under -Dhost-cmd.
    if (p.host_cmd) kern.root_module.addCMacro("H9_HOSTCMD", "1");
    if (!p.have_drawterm) {
        const fail = b.addFail(drawterm ++ " is missing; run scripts/vendor-drawterm.sh");
        kern.step.dependOn(&fail.step);
    }
    // Everything that imports the h9 module links kern.
    mod.linkLibrary(kern);

    mod.addAnonymousImport("guest_tree", .{ .root_source_file = p.guest_tree });

    const options = b.addOptions();
    options.addOption(Emu, "emu", p.emu);
    options.addOption(bool, "kern", p.have_drawterm);
    options.addOption(bool, "host_cmd", p.host_cmd);
    options.addOption([]const u8, "gfx", @tagName(gfx));
    options.addOption([]const u8, "version", p.version);
    options.addOption([]const u8, "ninefront_release", pin(p.pins, "NINEFRONT_RELEASE"));
    options.addOption([]const u8, "ninefront_rev", pin(p.pins, "NINEFRONT_REV"));
    options.addOption([]const u8, "drawterm_rev", pin(p.pins, "DRAWTERM_REV"));
    mod.addOptions("build_options", options);
    return .{ .mod = mod, .kern = kern };
}

/// The screen for kern: src/kern/nogfx.c, or src/kern/gfx.c with a
/// backend. drawterm's backends compile unmodified, with
/// src/kern/gfx-gui.h included first to rename what gfx.c wraps and to
/// send their exits through the machine's hangup path.
fn addGfxSources(b: *std.Build, kern: *std.Build.Step.Compile, gfx: Gfx, flags: []const []const u8) void {
    const m = kern.root_module;
    if (gfx == .none) {
        m.addCMacro("H9_GFX_NONE", "1");
        m.addCSourceFiles(.{ .root = b.path("src/kern"), .files = &.{"nogfx.c"}, .flags = flags });
        return;
    }
    m.addCSourceFiles(.{ .root = b.path("src/kern"), .files = &.{"gfx.c"}, .flags = flags });
    const gui = std.mem.concat(b.allocator, []const u8, &.{ flags, &.{ "-include", b.pathFromRoot("src/kern/gfx-gui.h") } }) catch @panic("OOM");
    const gui_exit = std.mem.concat(b.allocator, []const u8, &.{ gui, &.{"-DH9_GUI_EXIT"} }) catch @panic("OOM");
    switch (gfx) {
        .none => unreachable,
        .headless => m.addCSourceFiles(.{ .root = b.path("src/kern"), .files = &.{"gfx-headless.c"}, .flags = flags }),
        .x11 => {
            m.addCSourceFiles(.{ .root = b.path(drawterm ++ "/gui-x11"), .files = &.{"x11.c"}, .flags = gui_exit });
            m.addCSourceFiles(.{ .root = b.path(drawterm ++ "/gui-x11"), .files = &.{"keysym2ucs-x11.c"}, .flags = flags });
            m.linkSystemLibrary("X11", .{});
        },
        .win32 => {
            m.addCSourceFiles(.{ .root = b.path(drawterm ++ "/gui-win32"), .files = &.{"screen.c"}, .flags = gui_exit });
            m.linkSystemLibrary("gdi32", .{});
            m.linkSystemLibrary("user32", .{});
        },
        .cocoa => {
            const objc = std.mem.concat(b.allocator, []const u8, &.{ gui, &.{"-fobjc-arc"} }) catch @panic("OOM");
            m.addCSourceFiles(.{ .root = b.path(drawterm ++ "/gui-cocoa"), .files = &.{"screen.m"}, .flags = objc, .language = .objective_c });
            m.addCSourceFiles(.{ .root = b.path("src/kern"), .files = &.{"gfx-cocoa.m"}, .flags = &.{"-fobjc-arc"}, .language = .objective_c });
            m.linkFramework("Cocoa", .{});
            m.linkFramework("Metal", .{});
            m.linkFramework("QuartzCore", .{});
        },
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os = target.result.os.tag;
    // Host commands (#C, --host-cmd, hcmd) are left out unless asked for,
    // while design/host-cmd rethinks them.
    const host_cmd = b.option(bool, "host-cmd", "Build in host commands: #C, --host-cmd and hcmd (default: off; design/host-cmd.md)") orelse false;
    var emu = b.option(Emu, "emu", "Emulator backend to build in (GPLv2 Unicorn: dev, CI and the h9-emu release only)") orelse .none;
    // No wheel exists for Windows, so it always builds from source.
    const unicorn_from = b.option(UnicornFrom, "unicorn", "With -Demu=unicorn: the prebuilt wheel library or a source build (default: prebuilt, source on Windows)") orelse
        if (os == .windows) UnicornFrom.source else .prebuilt;

    const gfx = b.option(Gfx, "gfx", "GUI backend for --gfx (design/0015-gfx.md): cocoa, win32, x11, headless (tests) or none (default: cocoa on macOS, win32 on Windows, none elsewhere)") orelse Gfx.default(target.result);
    if (gfx.unsupported(target.result)) |why| b.getInstallStep().dependOn(&b.addFail(b.fmt("-Dgfx={t}: {s}", .{ gfx, why })).step);

    // Unicorn's translated header, shared by every h9 module.
    var unicorn_mod: ?*std.Build.Module = null;
    if (emu == .unicorn) {
        // On failure addUnicorn has already made the install step fail.
        if (addUnicorn(b, target, optimize, unicorn_from)) |uc| unicorn_mod = uc else emu = .none;
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
    // The amd64 shim, for KVM on x86_64 (design/0016-kvm.md).
    const shim_amd64_obj = b.addObject(.{
        .name = "shim_amd64",
        .root_module = b.createModule(.{
            .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .freestanding }),
            .optimize = .ReleaseSmall,
        }),
    });
    shim_amd64_obj.root_module.addAssemblyFile(b.path("src/arch/amd64/shim.S"));
    const shim_amd64_bin = b.addObjCopy(shim_amd64_obj.getEmittedBin(), .{ .format = .bin, .only_section = ".text" });

    const kern_step = b.step("kern", "Compile drawterm's kern");
    const have_drawterm = if (b.build_root.handle.access(b.graph.io, drawterm ++ "/kern/sysfile.c", .{})) true else |_| false;

    // h9's own guest commands, served by #H (design/0032-guest-tools.md).
    // Debug builds also serve tests/fixtures/guest, for the integration
    // cases; release builds leave it out.
    const guest_test = b.option(bool, "guest-test", "Serve tests/fixtures/guest in #H too, for the integration cases (default: in Debug builds)") orelse (optimize == .Debug);
    const guest_tree = guestTree(b, guest_test, host_cmd);

    // For --version: scripts/release.sh passes -Dversion; otherwise git
    // describe, or build.zig.zon's version where there's no git checkout.
    const version = b.option([]const u8, "version", "Version h9 --version reports (default: git describe, else build.zig.zon's)") orelse gitVersion(b);
    const pins = b.build_root.handle.readFileAlloc(b.graph.io, "scripts/pins.sh", b.allocator, .limited(1 << 16)) catch "";

    const parts: ModuleParts = .{
        .target = target,
        .optimize = optimize,
        .emu = emu,
        .unicorn = unicorn_mod,
        .shim = shim_bin.getOutput(),
        .shim_amd64 = shim_amd64_bin.getOutput(),
        .host_cmd = host_cmd,
        .guest_tree = guest_tree.file,
        .have_drawterm = have_drawterm,
        .version = version,
        .pins = pins,
    };
    // The h9 module, with the -Dgfx backend: h9, embedders and the tools.
    const mod = addH9Module(b, parts, gfx, true);
    kern_step.dependOn(&mod.kern.step);
    // The tests' module, with the headless backend for the [gfx] cases.
    const test_mod = if (gfx == .headless) mod else addH9Module(b, parts, .headless, false);

    const exe = b.addExecutable(.{
        .name = "h9",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "h9", .module = mod.mod },
                // --check runs the hello fixture on each backend.
                .{ .name = "hello", .module = b.createModule(.{ .root_source_file = b.path("tests/fixtures/hello.zig"), .target = target }) },
            },
        }),
    });
    if (os == .macos) {
        addSdkPaths(b, exe.root_module);
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
    var hellos: [3]std.Build.LazyPath = undefined;
    for (&hellos, [_][]const u8{ "arm64", "amd64", "386" }, [_][]const u8{ "hello", "hello-amd64", "hello-386" }) |*out, arch, name| {
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
        // 386 runs on the emulator on every host.
        const i386_demo = b.addSystemCommand(&.{ b.getInstallPath(.bin, exe.out_filename), "--backend", "emu" });
        i386_demo.addFileArg(hellos[2]);
        i386_demo.expectStdOutEqual("hello\n");
        i386_demo.step.dependOn(signed_step);
        addDemo(b, &demos, "i386", &i386_demo.step);
    }

    // The rest run real 9front binaries from a host root tree, so they're
    // left out without one, as the integration cases skip.
    const root = b.option([]const u8, "root", "9front root tree for the demos and integration tests (default .local/9front/root)") orelse
        b.pathFromRoot(".local/9front/root");
    const h9_bin = b.getInstallPath(.bin, exe.out_filename);
    // The self-host demos and cases need /sys/src: the root's (scripts/mkroot.py
    // --src), or else this checkout's, which scripts/fetch.sh makes at the
    // root's revision.
    const src_dir: ?[]const u8 = b.option([]const u8, "src", "9front source's sys directory for the self-host cases when the root has no /sys/src (default .local/src/9front/sys)") orelse blk: {
        const d = b.pathFromRoot(".local/src/9front/sys");
        b.build_root.handle.access(b.graph.io, ".local/src/9front/sys/src", .{}) catch break :blk null;
        break :blk d;
    };

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
    // count is the root's two directories' entries and #H/bin's added
    // together (design/0032-guest-tools.md).
    if (countBin(b, root)) |n| {
        const ls_demo = b.addSystemCommand(&.{ h9_bin, "--root", root, "--rc", "ls /bin | wc -l" });
        ls_demo.expectStdOutEqual(b.fmt("{d: >7}\n", .{n + guest_tree.bin}));
        ls_demo.step.dependOn(signed_step);
        addDemo(b, &demos, "baseline", &ls_demo.step);
    }

    // Self-host demos (design/0010-self-host.md), with the root's arm64
    // binaries: they need /sys/src, the root's or `src_dir` bound over
    // /sys.
    const root_src = if (b.build_root.handle.access(b.graph.io, b.pathJoin(&.{ root, "sys/src/cmd/ls.c" }), .{})) |_| true else |_| false;
    if (root_src or src_dir != null) {
        // A scratch cwd unioned before /sys/src/cmd, so mk reads the stock
        // mkfile and source there and writes into the scratch directory,
        // and the symbols name /sys/src/cmd as the shipped binary's do.
        const bind_src = if (root_src) "" else b.fmt("bind -a /mnt/term{s} /sys && ", .{src_dir.?});
        const ls_cwd = b.addWriteFiles();
        _ = ls_cwd.add(".keep", "");
        const ls_build = b.addSystemCommand(&.{ h9_bin, "--root", root, "--arch", "arm64", "--timeout", "600s" });
        if (!root_src) ls_build.addArgs(&.{ "--readable", src_dir.? });
        ls_build.addArg("--cwd");
        ls_build.addDirectoryArg(ls_cwd.getDirectory());
        ls_build.addArgs(&.{ "--rc", b.fmt("{s}bind -bc /mnt/term/cwd /sys/src/cmd && cd /sys/src/cmd && mk 7.ls >/dev/null && ./7.ls -d / && cmp 7.ls /arm64/bin/ls && echo identical", .{bind_src}) });
        ls_build.expectStdOutEqual("/\nidentical\n");
        ls_build.has_side_effects = true;
        ls_build.step.dependOn(signed_step);
        addDemo(b, &demos, "self-host", &ls_build.step);
    }
    if (countBin(b, root) != null) {
        // acid attaches to a sleeping process and prints its stack.
        const acid_demo = b.addSystemCommand(&.{ h9_bin, "--root", root, "--arch", "arm64", "--timeout", "60s", "--rc", "sleep 5 & sleep 1; acid $apid; echo kill >/proc/$apid/ctl" });
        acid_demo.setStdIn(.{ .bytes = "stk()\n" });
        acid_demo.expectStdOutMatch("main(argv=");
        acid_demo.expectStdOutMatch("/sys/src/cmd/sleep.c:");
        acid_demo.has_side_effects = true;
        acid_demo.step.dependOn(signed_step);
        addDemo(b, &demos, "self-host", &acid_demo.step);
    }

    // Each integration case runs on every backend built in that runs the
    // cases' architecture here. -Darch runs them with another
    // architecture's binaries from the root (/386/bin, /amd64/bin).
    const test_arch = b.option([]const u8, "arch", "Architecture of the root's binaries for the integration cases: arm64, amd64 or 386 (default the host's)");
    const native_arch: ?[]const u8 = switch (target.result.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "amd64",
        else => null,
    };
    const cases_arch = test_arch orelse native_arch orelse "arm64";
    var backends: std.ArrayList(u8) = .empty;
    if (os == .macos and std.mem.eql(u8, cases_arch, "arm64") and target.result.cpu.arch == .aarch64)
        backends.appendSlice(b.allocator, "hvf,") catch @panic("OOM");
    // KVM runs the host's architecture, when this user can open /dev/kvm.
    if (os == .linux and b.graph.host.result.os.tag == .linux and native_arch != null and std.mem.eql(u8, cases_arch, native_arch.?) and
        target.result.cpu.arch == b.graph.host.result.cpu.arch)
    {
        if (std.Io.Dir.accessAbsolute(b.graph.io, "/dev/kvm", .{ .read = true, .write = true })) |_|
            backends.appendSlice(b.allocator, "kvm,") catch @panic("OOM")
        else |_| {}
    }
    // WHP runs amd64 on Windows x86_64, when the Windows Hypervisor Platform
    // feature is on, which is when its DLL is in System32.
    if (os == .windows and b.graph.host.result.os.tag == .windows and target.result.cpu.arch == .x86_64 and
        std.mem.eql(u8, cases_arch, "amd64"))
    {
        if (std.Io.Dir.accessAbsolute(b.graph.io, "C:\\Windows\\System32\\WinHvPlatform.dll", .{})) |_|
            backends.appendSlice(b.allocator, "whp,") catch @panic("OOM")
        else |_| {}
    }
    if (emu == .unicorn) backends.appendSlice(b.allocator, "emu,") catch @panic("OOM");
    const backend_list = if (backends.items.len > 0) backends.items else "auto";

    // Runs real binaries through the h9 CLI; skipped without a root tree.
    // Cases tagged with a proposal that isn't implemented skip unless
    // -Dpending is given.
    const run_pending = b.option(bool, "pending", "Also run integration cases of proposals that aren't implemented yet") orelse false;
    // The Go fixtures run on the emulator, so they're built only with it.
    const go_version = pin(pins, "GO_VERSION");
    const go_bin = b.findProgram(&.{"go"}, &.{}) catch null;
    const go_fixtures: ?GoFixtures = if (go_bin) |g| addGoFixtures(b, g, go_version) else null;
    const go_fixtures_step = b.step("go-fixtures", "Build the Go fixtures in tests/fixtures/go (plan9/amd64, GO_VERSION from scripts/pins.sh)");
    if (go_fixtures) |g| go_fixtures_step.dependOn(g.step) else go_fixtures_step.dependOn(&b.addFail("go-fixtures: no go on PATH").step);
    const go_cases: ?GoFixtures = if (emu == .unicorn) go_fixtures else null;
    // Go's own tests for time, syscall, os and runtime on the emulator, by
    // hand or on a schedule; nothing depends on it.
    const go_stdtest = b.step("go-stdtest", "Run Go's time, syscall, os and runtime tests on the emulator (needs -Demu=unicorn and go)");
    if (emu != .unicorn) {
        go_stdtest.dependOn(&b.addFail("go-stdtest: needs -Demu=unicorn").step);
    } else {
        const run_stdtest = b.addSystemCommand(&.{ "bash", "scripts/go-stdtest.sh", h9_bin, b.getInstallPath(.prefix, "go-stdtest") });
        run_stdtest.setCwd(b.path("."));
        if (b.args) |args| run_stdtest.addArgs(args);
        run_stdtest.has_side_effects = true;
        run_stdtest.stdio = .inherit;
        run_stdtest.step.dependOn(signed_step);
        go_stdtest.dependOn(&run_stdtest.step);
    }
    const run_integration = addIntegration(b, optimize, &.{}, h9_bin, root, backend_list, run_pending, test_arch, go_cases, guest_test, host_cmd, src_dir);
    run_integration.step.dependOn(signed_step);
    b.step("integration", "Run real 9front binaries from the root tree through h9").dependOn(&run_integration.step);

    // 9box and a slim root around it (design/0064-multicall.md), built inside
    // the h9 just built, against the root tree. -Darch picks the
    // architecture, as for the integration cases.
    const slim_links = b.option([]const u8, "slim-links", "With zig build slim: hard (hard links to 9box, the default), stub (#!/bin/9box -! files) or copy (no 9box: the same commands' binaries copied, in slim-copy-*)") orelse "hard";
    const slim_arch = test_arch orelse switch (target.result.cpu.arch) {
        .x86_64 => "amd64",
        .x86 => "386",
        else => "arm64",
    };
    const slim_tool = b.addExecutable(.{
        .name = "slim",
        .root_module = b.createModule(.{ .root_source_file = b.path("tools/slim.zig"), .target = b.graph.host }),
    });
    const run_slim = b.addRunArtifact(slim_tool);
    run_slim.has_side_effects = true;
    run_slim.stdio = .inherit;
    run_slim.setCwd(b.path("."));
    const release = pin(pins, "NINEFRONT_RELEASE");
    run_slim.addArgs(&.{
        h9_bin,
        root,
        b.pathFromRoot("src/9box"),
        b.pathFromRoot(".local/src/9front/sys/src"),
        slim_arch,
        slim_links,
        b.pathFromRoot(b.fmt(".local/build/9box/{s}", .{slim_arch})),
        // -Dslim-links=copy is the separate binaries the box is measured
        // against, in a tree of its own.
        b.pathFromRoot(b.fmt(".local/9front/slim{s}-{s}-{s}", .{ if (std.mem.eql(u8, slim_links, "copy")) "-copy" else "", release, slim_arch })),
    });
    run_slim.step.dependOn(signed_step);
    b.step("slim", "Build 9box and a slim root in .local/9front/slim-<release>-<arch>: -Dslim-links=hard|stub|copy, -Darch").dependOn(&run_slim.step);

    // The WebSocket relay the websocket-9p cases use, as a program for the
    // demo: zig build wsrelay -- LISTEN_PORT TARGET_PORT.
    const wsrelay = b.addExecutable(.{
        .name = "wsrelay",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/wsrelay.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{.{ .name = "ws", .module = b.createModule(.{ .root_source_file = b.path("src/ws.zig") }) }},
        }),
    });
    const run_wsrelay = b.addRunArtifact(wsrelay);
    if (b.args) |args| run_wsrelay.addArgs(args);
    b.step("wsrelay", "Relay WebSockets to a TCP 9P server: zig build wsrelay -- LISTEN_PORT TARGET_PORT").dependOn(&run_wsrelay.step);

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
            const run_cases = addIntegration(b, optimize, tagFilters(b, ps[i]), h9_bin, root, backend_list, true, test_arch, go_cases, guest_test, host_cmd, src_dir);
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

    const mod_tests = b.addTest(.{ .root_module = test_mod.mod });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    linkUnicorn(mod_tests); // exe_tests shares exe's root module, already linked
    // Runs the same programs on every backend built in and compares them.
    const backend_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/backends.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "h9", .module = test_mod.mod },
            .{ .name = "hello", .module = b.createModule(.{ .root_source_file = b.path("tests/fixtures/hello.zig"), .target = target }) },
        },
    }) });
    if (os == .macos) {
        addSdkPaths(b, backend_tests.root_module);
        backend_tests.root_module.linkFramework("Hypervisor", .{});
    }
    linkUnicorn(backend_tests);
    // The segattach, overlay, srv, htools, sema, net and gfx fixtures, assembled freestanding as the shim is, and
    // embedded as raw text for tests/backends.zig to wrap in an a.out.
    for ([_]struct { dir: []const u8, prefix: []const u8, names: []const []const u8 }{
        .{ .dir = "segattach", .prefix = "seg", .names = &segattach_fixtures },
        .{ .dir = "overlay", .prefix = "ov", .names = &overlay_fixtures },
        .{ .dir = "srv", .prefix = "srv", .names = &srv_fixtures },
        .{ .dir = "htools", .prefix = "htools", .names = &htools_fixtures },
        .{ .dir = "sema", .prefix = "sema", .names = &sema_fixtures },
        .{ .dir = "net", .prefix = "net", .names = &net_fixtures },
        .{ .dir = "gfx", .prefix = "gfx", .names = &gfx_fixtures },
    }) |set| for (set.names) |name| {
        const obj = b.addObject(.{
            .name = name,
            .root_module = b.createModule(.{
                .target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .freestanding }),
                .optimize = .ReleaseSmall,
            }),
        });
        obj.root_module.addAssemblyFile(b.path(b.fmt("tests/fixtures/{s}/{s}.S", .{ set.dir, name })));
        obj.root_module.addIncludePath(b.path("tests/fixtures/segattach"));
        const bin = b.addObjCopy(obj.getEmittedBin(), .{ .format = .bin, .only_section = ".text" });
        backend_tests.root_module.addAnonymousImport(b.fmt("{s}_{s}", .{ set.prefix, name }), .{ .root_source_file = bin.getOutput() });
    };
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    // The guest tree's rules (tools/guesttree.zig), which build.zig applies.
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tools/guesttree.zig"),
        .target = b.graph.host,
    }) })).step);
    // The design tool's tests read tools/testdata from the repository root.
    const design_tests = b.addRunArtifact(b.addTest(.{ .root_module = design_tool.root_module }));
    design_tests.setCwd(b.path("."));
    test_step.dependOn(&design_tests.step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
    // HVF needs the entitlement, so the test binary is signed like h9.
    const run_backend_tests = b.addRunArtifact(backend_tests);
    // The [gfx] cases that run rio and acme take them from the root tree.
    run_backend_tests.setEnvironmentVariable("H9_TEST_ROOT", root);
    if (os == .macos and b.graph.host.result.os.tag == .macos) {
        const sign = b.addSystemCommand(&.{ "codesign", "--force", "--sign", "-", "--entitlements" });
        sign.addFileArg(b.path("h9.entitlements"));
        sign.addFileArg(backend_tests.getEmittedBin());
        run_backend_tests.step.dependOn(&sign.step);
    }
    test_step.dependOn(&run_backend_tests.step);
    test_step.dependOn(&run_integration.step);

    // docs/embedding/embed.zig, docs/embedding.md's example of embedding h9.
    const embed_example = b.addExecutable(.{
        .name = "embed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("docs/embedding/embed.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "h9", .module = mod.mod }},
        }),
    });
    if (os == .macos) {
        addSdkPaths(b, embed_example.root_module);
        embed_example.root_module.linkFramework("Hypervisor", .{});
    }
    linkUnicorn(embed_example);
    const install_embed = b.addInstallArtifact(embed_example, .{});
    b.step("embed", "Build docs/embedding/embed.zig, the embedding guide's example, as zig-out/bin/embed").dependOn(&install_embed.step);
    // zig build test runs it on the hello fixture where a backend can: HVF
    // on an arm64 Mac (signed like h9) for one machine, and the emulator for
    // the second. HVF allows one VM per host process.
    const hvf_host = os == .macos and target.result.cpu.arch == .aarch64 and b.graph.host.result.os.tag == .macos;
    if (hvf_host or emu == .unicorn) {
        const run_embed = b.addRunArtifact(embed_example);
        if (hvf_host) {
            const sign = b.addSystemCommand(&.{ "codesign", "--force", "--sign", "-", "--entitlements" });
            sign.addFileArg(b.path("h9.entitlements"));
            sign.addFileArg(embed_example.getEmittedBin());
            run_embed.step.dependOn(&sign.step);
        }
        const machines: []const u8 = if (emu == .unicorn) "2" else "1";
        run_embed.addArgs(&.{ "-j", machines });
        run_embed.addFileArg(host_hello);
        const first = b.fmt("machine 0 ({s}): exited \"\"\n  hello\n", .{if (hvf_host) "hvf" else "emu"});
        run_embed.expectStdOutEqual(if (emu == .unicorn) b.fmt("{s}machine 1 (emu): exited \"\"\n  hello\n", .{first}) else first);
        test_step.dependOn(&run_embed.step);
    }

    // The speed numbers in DESIGN.md's "Limits and selection". Always
    // ReleaseFast (the h9 module inherits it), whatever -Doptimize says.
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "h9", .module = mod.mod }},
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
