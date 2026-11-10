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
// The web host (design/0012-browser-host.md): devfs and devlfd build
// against wasi-libc; posix.c and devip-posix.c are replaced by
// src/kern/os-wasm.c and devip-wasm.c.
const kern_web = [_][]const u8{ "devfs-posix.c", "devlfd-posix.c" };

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
// The web host's: drawterm's dtos.h needs a named OS, and wasi-libc
// hides signals, process clocks, mmap and getpid behind these. setjmp and
// longjmp (waserror) use wasm exception handling (webTarget).
const kern_flags_web = kern_flags_common ++ [_][]const u8{
    "-Dlinux",
    "-DH9_WEB",
    "-D_WASI_EMULATED_SIGNAL",
    "-D_WASI_EMULATED_PROCESS_CLOCKS",
    "-D_WASI_EMULATED_MMAN",
    "-D_WASI_EMULATED_GETPID",
    "-mllvm",
    "-wasm-enable-sjlj",
};
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
/// C programs in tests/fixtures/linux, built static for Linux on arm64 and
/// amd64, for the linux-personality cases in tests/integration.zig.
const linux_fixture_names = [_][]const u8{ "hello", "probe", "die", "sigreturn", "net", "threads", "files" };

/// Programs in tests/fixtures/gfx, for tests/backends.zig's [gfx] cases on
/// the headless backend, with the same lib.S.
const gfx_fixtures = [_][]const u8{ "binds", "drawnew", "draw", "kbd", "mouse", "snarf", "sleep" };

/// The h9 the integration cases run: the native binary, or h9-node for
/// the web host (-Dweb). `step` builds it.
const Integration = struct {
    bin: []const u8,
    arch: ?[]const u8,
    web: bool,
    step: *std.Build.Step,
    /// With `web`: a native h9 that runs the root's 386 binaries, for the
    /// cases' 9P servers (H9_TEST_SERVER), since the web host can't listen.
    server: ?[]const u8 = null,
    server_step: *std.Build.Step = undefined,
};

/// Runs tests/integration.zig against the h9 binary. `filters` selects
/// cases by name; with `pending`, cases tagged with a proposal that isn't
/// implemented run instead of skipping. `it.arch`, if given, is passed to
/// h9 as --arch (from -Darch). `guest_test` says h9 was built with
/// -Dguest-test, and `host_cmd` that it was built with -Dhost-cmd. `src`,
/// if given, is a 9front checkout's `sys` directory, which the self-host
/// cases bind over /sys when the root lacks /sys/src.
fn addIntegration(b: *std.Build, optimize: std.builtin.OptimizeMode, filters: []const []const u8, it: Integration, root: []const u8, backends: []const u8, pending: bool, go: ?GoFixtures, guest_test: bool, host_cmd: bool, src: ?[]const u8) *std.Build.Step.Run {
    const run = b.addRunArtifact(integrationTests(b, b.graph.host, optimize, filters));
    // The self-host cases' source when the root has no /sys/src
    // (design/0010-self-host.md).
    if (src) |dir| run.setEnvironmentVariable("H9_TEST_SRC", dir);
    run.step.dependOn(it.step);
    if (it.server != null) run.step.dependOn(it.server_step);
    const h9_bin = it.bin;
    // h9 serves tests/fixtures/guest in #H (design/0032-guest-tools.md).
    if (guest_test) run.setEnvironmentVariable("H9_TEST_GUEST_TOOLS", "1");
    // Built with -Dhost-cmd: the host command cases run.
    if (host_cmd) run.setEnvironmentVariable("H9_TEST_HOST_CMD", "1");
    if (it.arch) |a| run.setEnvironmentVariable("H9_TEST_ARCH", a);
    if (it.web) run.setEnvironmentVariable("H9_TEST_WEB", "1");
    if (it.server) |sv| run.setEnvironmentVariable("H9_TEST_SERVER", sv);
    if (go) |g| {
        run.setEnvironmentVariable("H9_TEST_GO", g.dir);
        run.step.dependOn(g.step);
        // On the native backend when it's in the list, else the emulator.
        if (std.mem.indexOf(u8, backends, "native") != null) run.setEnvironmentVariable("H9_TEST_GO_BACKEND", "native");
    }
    run.setEnvironmentVariable("H9_TEST_BIN", h9_bin);
    run.setEnvironmentVariable("H9_TEST_ROOT", root);
    run.setEnvironmentVariable("H9_TEST_BACKENDS", backends);
    // The Linux fixtures and the Alpine roots from scripts/fetch.sh
    // (design/0018-linux-personality.md).
    run.setEnvironmentVariable("H9_TEST_LINUX", b.getInstallPath(.prefix, "fixtures/linux"));
    run.setEnvironmentVariable("H9_TEST_LINUX_ROOT", b.pathFromRoot(".local/linux"));
    // The tree `zig build slim` makes, for the multicall cases, which skip
    // without it (design/0064-multicall.md).
    const release = pin(b.build_root.handle.readFileAlloc(b.graph.io, "scripts/pins.sh", b.allocator, .limited(1 << 16)) catch "", "NINEFRONT_RELEASE");
    run.setEnvironmentVariable("H9_TEST_SLIM_ROOT", b.pathFromRoot(b.fmt(".local/9front/slim-{s}-{s}", .{ release, it.arch orelse "arm64" })));
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
                .{ .name = "dotltest", .module = b.createModule(.{ .root_source_file = b.path("src/dotl/testserver.zig") }) },
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

/// none: no emulator. unicorn: Unicorn (GPLv2). zig: h9's own CPUs, ha64
/// for arm64 guests and h86 for 386 (src/vcpu.zig; in progress on the vcpu
/// branch, so it isn't usable yet).
pub const Emu = enum { none, unicorn, zig };

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

/// The built-in root `#Hroot` serves (design/0087-builtin-root.md), as a
/// generated Zig file with its contents embedded beside it: the skeleton,
/// and multicall's tree (`zig build slim`, design/0064-multicall.md) for
/// each of `arches` found in `dir` for the pinned `release`. A missing or
/// stale tree is left out with a warning (none when `quiet`), or fails the
/// build when `required`.
fn builtinRoot(b: *std.Build, dir: []const u8, release: []const u8, arches: []const []const u8, missing: enum { warn, quiet, required }) std.Build.LazyPath {
    const io = b.graph.io;
    const wf = b.addWriteFiles();
    var names: std.ArrayList([]const u8) = .empty;
    if (std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true })) |d| {
        var dd = d;
        defer dd.close(io);
        var it = dd.iterate();
        while (it.next(io) catch null) |e| names.append(b.allocator, b.dupe(e.name)) catch @panic("OOM");
    } else |_| {}
    var inputs: std.ArrayList(guesttree.Input) = .empty;
    var found: std.ArrayList([]const u8) = .empty;
    for (arches) |arch| {
        var nb: [128]u8 = undefined;
        const name = guesttree.treeName(&nb, release, arch);
        const why: []const u8 = switch (guesttree.findTree(names.items, release, arch)) {
            .found => {
                var tree = std.Io.Dir.cwd().openDir(io, b.pathJoin(&.{ dir, name }), .{ .iterate = true }) catch |err| {
                    wf.step.dependOn(&b.addFail(b.fmt("built-in root: {s}: {t}", .{ name, err })).step);
                    continue;
                };
                defer tree.close(io);
                const got = guesttree.scanLimited(b.allocator, io, tree, 64 << 20) catch |err| {
                    wf.step.dependOn(&b.addFail(b.fmt("built-in root: {s}: {t}", .{ name, err })).step);
                    continue;
                };
                inputs.appendSlice(b.allocator, got) catch @panic("OOM");
                found.append(b.allocator, arch) catch @panic("OOM");
                continue;
            },
            .stale => |other| b.fmt("{s} is from another 9front release than the pinned {s}", .{ other, release }),
            .missing => b.fmt("no {s} in {s}", .{ name, dir }),
        };
        const msg = b.fmt("built-in root: {s}, so {s} gets the skeleton only; zig build slim -Darch={s} makes it", .{ why, arch, arch });
        switch (missing) {
            .required => wf.step.dependOn(&b.addFail(msg).step),
            .warn => std.log.warn("{s}", .{msg}),
            .quiet => {},
        }
    }
    var why: []const u8 = "";
    const entries = guesttree.buildRoot(b.allocator, inputs.items, &why) catch |err| switch (err) {
        error.Rejected => {
            wf.step.dependOn(&b.addFail(b.fmt("built-in root: {s}", .{why})).step);
            return wf.add("builtin_root.zig", "");
        },
        error.OutOfMemory => @panic("OOM"),
    };
    const blobs = guesttree.share(b.allocator, entries) catch @panic("OOM");
    for (blobs, 0..) |data, i| {
        var nb: [32]u8 = undefined;
        _ = wf.add(b.dupe(guesttree.blobName(&nb, @intCast(i))), data);
    }
    var commands: usize = 0;
    for (found.items) |arch| commands = @max(commands, guesttree.countCommands(entries, arch));
    var out: std.Io.Writer.Allocating = .init(b.allocator);
    guesttree.renderRoot(&out.writer, entries, blobs.len, .{ .release = release, .arches = found.items, .commands = commands }) catch @panic("OOM");
    return wf.add("builtin_root.zig", out.written());
}

/// The architectures a build's built-in root embeds: those it can run.
fn builtinArches(target: std.Target, emu: Emu) []const []const u8 {
    const native: ?[]const u8 = switch (target.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "amd64",
        else => null,
    };
    if (emu == .unicorn) {
        return if (native != null and std.mem.eql(u8, native.?, "arm64")) &.{ "arm64", "amd64", "386" } else &.{ "amd64", "386" };
    }
    if (native) |n| return if (std.mem.eql(u8, n, "arm64")) &.{"arm64"} else &.{"amd64"};
    return &.{};
}

/// drawterm's kern and the libraries it uses, as a static library for
/// `target`. `web` builds it for the browser host
/// (design/0012-browser-host.md): wasm32-wasi, with src/kern/os-wasm.c in
/// place of posix.c, the coroutines it runs on (src/web/coro.c), and
/// setjmp/longjmp on wasm exception handling.
fn addKern(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, web: bool, host_cmd: bool, gfx: Gfx, exported: bool) *std.Build.Step.Compile {
    const os = target.result.os.tag;
    const kern = b.addLibrary(.{
        .name = if (gfx == .headless and !exported) "kern-headless" else "kern",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    kern.root_module.addIncludePath(b.path(drawterm));
    kern.root_module.addIncludePath(b.path(drawterm ++ "/include"));
    kern.root_module.addIncludePath(b.path(drawterm ++ "/kern"));
    kern.root_module.addIncludePath(b.path("src/kern")); // fscheck.h and netcheck.h, for devfs and devip
    const flags: []const []const u8 = if (web) &kern_flags_web else if (os == .windows) &kern_flags_win32 else &kern_flags;
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
    // oscmd and friends are renamed so src/kern/hostcmd.c can wrap them:
    // a machine's host commands die with it. The web host has none, and
    // os-wasm.c stubs them.
    kern.root_module.addCSourceFiles(.{
        .root = b.path(drawterm ++ "/kern"),
        .files = if (web) &kern_web else if (os == .windows) &kern_win32 else &kern_posix,
        .flags = if (web) flags else std.mem.concat(b.allocator, []const u8, &.{ flags, &.{ "-Doscmd=h9_dt_oscmd", "-Doscmdkill=h9_dt_oscmdkill", "-Doscmdfree=h9_dt_oscmdfree" } }) catch @panic("OOM"),
    });
    kern.root_module.addCSourceFiles(.{
        .root = b.path("src/kern"),
        .files = &.{ "glue.c", "proc.c", "devtab.c", "devhcons.c", "devenv.c", "devdup.c", "devproc.c", "devoverlay.c", "devsrv.c", "devhtools.c", "fscheck.c", "netcheck.c", "consx.c", "tsleep.c", "sema.c", "rootdial.c", "devhstream.c", "devdotl.c" },
        .flags = flags,
    });
    if (!web) kern.root_module.addCSourceFiles(.{ .root = b.path("src/kern"), .files = &.{"hostcmd.c"}, .flags = flags });
    // The Linux personality (design/0018-linux-personality.md) and its host
    // sockets (design/0050-linux-net.md).
    kern.root_module.addCSourceFiles(.{ .root = b.path("src/kern"), .files = &.{ "linux.c", "devlinux.c", "linuxnet.c" }, .flags = flags });
    if (web) {
        kern.root_module.addCSourceFiles(.{ .root = b.path("src/kern"), .files = &.{"hostsock-wasm.c"}, .flags = flags });
    } else if (os != .windows) kern.root_module.addCSourceFiles(.{ .root = b.path("src/kern"), .files = &.{ "hostsock-posix.c", "hostif-posix.c" }, .flags = flags });
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
        kern.root_module.addCSourceFiles(.{ .root = b.path("src/kern"), .files = &.{ "glue-win32.c", "hostsock-win32.c" }, .flags = flags });
        kern.root_module.linkSystemLibrary("ws2_32", .{});
        kern.root_module.linkSystemLibrary("advapi32", .{});
    }
    if (os == .macos) addSdkPaths(b, kern.root_module);
    if (web) {
        // No __builtin_return_address on wasm: os-wasm.c has getcallerpc.
        kern.root_module.addCSourceFiles(.{ .root = b.path(drawterm ++ "/posix-port"), .files = &.{"tas.c"}, .flags = flags });
        kern.root_module.addCSourceFiles(.{ .root = b.path("src/kern"), .files = &.{ "os-wasm.c", "devip-wasm.c" }, .flags = flags });
        kern.root_module.addCSourceFiles(.{ .root = b.path("src/web"), .files = &.{"coro.c"}, .flags = flags });
        kern.root_module.addAssemblyFile(b.path("src/web/stack.S"));
        // wasi-libc's setjmp/longjmp runtime for wasm exception handling,
        // which Zig's wasi-libc doesn't build.
        kern.root_module.addCSourceFile(.{
            .file = .{ .cwd_relative = b.pathJoin(&.{ b.graph.zig_lib_directory.path orelse ".", "libc/wasi/libc-top-half/musl/src/setjmp/wasm32/rt.c" }) },
            .flags = &.{ "-mllvm", "-wasm-enable-sjlj" },
        });
        for ([_][]const u8{ "wasi-emulated-signal", "wasi-emulated-process-clocks", "wasi-emulated-mman", "wasi-emulated-getpid" }) |l|
            kern.root_module.linkSystemLibrary(l, .{});
    } else kern.root_module.addCSourceFiles(.{
        .root = b.path(drawterm ++ "/posix-port"),
        .files = &kern_port,
        .flags = flags,
    });
    // devtab.c lists devcmd (#C) only under -Dhost-cmd.
    if (host_cmd and !web) kern.root_module.addCMacro("H9_HOSTCMD", "1");
    return kern;
}

/// The web target. kern alone turns on wasm exception handling, for
/// setjmp and longjmp: wasi-libc doesn't build with it.
fn webTarget(b: *std.Build, eh: bool) std.Build.ResolvedTarget {
    return b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
        .cpu_features_add = if (eh) std.Target.wasm.featureSet(&.{.exception_handling}) else .empty,
    });
}

const Web = struct {
    exe: *std.Build.Step.Compile,
    /// Installs everything into zig-out/web.
    install: *std.Build.Step,
};

/// h9.wasm, the JS host and the demo page, installed in
/// zig-out/web.
fn addWeb(b: *std.Build, optimize: std.builtin.OptimizeMode, parts: ModuleParts, gfx: Gfx) Web {
    const target = webTarget(b, false);
    var p = parts;
    p.target = target;
    p.optimize = optimize;
    // h9's own CPUs (`--backend emu`, or `v86`, its old name). The JIT
    // tier here is the wasm one (src/jit/wasm_t1.zig and emit/wasm.zig),
    // not the native code cache, which zemu leaves out on the web.
    p.emu = .zig;
    p.jit = true;
    p.unicorn = null;
    p.host_cmd = false;
    // The browser runs 386 only (design/0087-builtin-root.md, Open issues: every
    // byte is downloaded per page load).
    p.builtin_root = builtinRoot(b, p.builtin_dir, pin(p.pins, "NINEFRONT_RELEASE"), &.{"386"}, .quiet);
    const mod = addH9Module(b, p, gfx, false).mod;
    const exe = b.addExecutable(.{
        .name = "h9",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "h9", .module = mod },
                .{ .name = "hello", .module = b.createModule(.{ .root_source_file = b.path("tests/fixtures/hello.zig"), .target = target }) },
            },
        }),
    });
    exe.import_memory = true;
    // The function table too, so h9-web.js can grow it: the JIT installs
    // its regions there (src/jit/emit/wasm.zig).
    exe.import_table = true;
    // The main coroutine's stack; kernel processes get their own.
    exe.stack_size = 1 << 20;
    exe.rdynamic = true;
    exe.use_lld = true;
    const dir: std.Build.InstallDir = .{ .custom = "web" };
    const all = b.step("web-install", "");
    all.dependOn(&b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = dir } }).step);
    for ([_][]const u8{ "h9-web.js", "h9-node", "worker.js", "wasi-mem.js", "index.html", "package.json" }) |f|
        all.dependOn(&b.addInstallFileWithDir(b.path(b.pathJoin(&.{ "src/web", f })), dir, f).step);
    return .{ .exe = exe, .install = all };
}

/// The compute benchmarks (tests/bench/*.c): each built as an arm64 and a
/// 386 guest text segment, embedded in the bench as "bench_<name>_<arch>",
/// and compiled for the host too (as bench_<name>), for the checksum each
/// guest run must match.
const compute_benches = [_][]const u8{ "fib", "sieve", "md5", "qsort", "fp" };

fn addComputeBenches(b: *std.Build, bench: *std.Build.Step.Compile) void {
    const flags = &.{ "-O2", "-ffreestanding", "-fno-builtin", "-ffp-contract=off", "-fno-stack-protector", "-fno-pic", "-fno-asynchronous-unwind-tables" };
    const arches = [_]struct { name: []const u8, query: std.Target.Query, ld: []const u8 }{
        .{ .name = "arm64", .query = .{ .cpu_arch = .aarch64, .os_tag = .freestanding }, .ld = "tests/bench/link_arm64.ld" },
        // SSE2 for doubles, so they round as the host's do (x87 keeps 80 bits).
        .{ .name = "386", .query = .{ .cpu_arch = .x86, .os_tag = .freestanding, .cpu_model = .{ .explicit = &std.Target.x86.cpu.pentium4 } }, .ld = "tests/bench/link_386.ld" },
    };
    for (compute_benches) |name| {
        for (arches) |a| {
            const exe = b.addExecutable(.{
                .name = b.fmt("bench-{s}-{s}", .{ name, a.name }),
                .root_module = b.createModule(.{
                    .target = b.resolveTargetQuery(a.query),
                    .optimize = .ReleaseFast,
                    .pic = false,
                    .strip = true,
                }),
            });
            exe.root_module.addCSourceFiles(.{ .files = &.{ "tests/bench/start.c", b.fmt("tests/bench/{s}.c", .{name}) }, .flags = flags });
            exe.setLinkerScript(b.path(a.ld));
            exe.entry = .{ .symbol_name = "_start" };
            exe.pie = false;
            exe.bundle_compiler_rt = true;
            // The whole image: the linker scripts keep only text.
            const bin = b.addObjCopy(exe.getEmittedBin(), .{ .format = .bin }).getOutput();
            bench.root_module.addAnonymousImport(b.fmt("bench_{s}_{s}", .{ name, a.name }), .{ .root_source_file = bin });
        }
        bench.root_module.addCSourceFile(.{ .file = b.path(b.fmt("tests/bench/{s}.c", .{name})), .flags = &.{ "-O2", "-ffp-contract=off", b.fmt("-Dcompute=bench_{s}", .{name}) } });
    }
    bench.root_module.link_libc = true;
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
    /// A page's canvas, on the browser host (src/kern/gfx-web.c,
    /// design/0120-browser-gfx.md).
    web,

    fn default(t: std.Target) Gfx {
        return switch (t.os.tag) {
            .macos => .cocoa,
            .windows => .win32,
            .wasi => .web,
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
            .web => if (t.os.tag != .wasi) "web is the browser host's backend (zig build web)" else null,
        };
    }
};

/// What every h9 module shares; `addH9Module` makes one per GUI backend.
const ModuleParts = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    emu: Emu,
    /// With -Demu=zig: build the JIT tier, not just the interpreter.
    jit: bool,
    /// With -Demu=zig: run every region through the T1-against-T0 check
    /// (src/jit/check/vmm.zig).
    jit_check: bool,
    /// With -Demu=zig: ir.verify each region after lifting and after opt
    /// (opt.verify), even where the vcpu module has no runtime safety.
    jit_verify: bool,
    /// How src/interp/ and src/jit/ (the vcpu module) are optimized.
    vcpu_optimize: std.builtin.OptimizeMode,
    unicorn: ?*std.Build.Module,
    shim: std.Build.LazyPath,
    shim_amd64: std.Build.LazyPath,
    /// The native backend's stub, for Linux x86_64 hosts.
    native_stub: std.Build.LazyPath,
    host_cmd: bool,
    guest_tree: std.Build.LazyPath,
    /// The built-in root (design/0087-builtin-root.md).
    builtin_root: std.Build.LazyPath,
    /// Where its trees are, for the web host's.
    builtin_dir: []const u8,
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
    // The emulator's CPUs (src/vcpu.zig), as a module of their own, so
    // they can be optimized when the rest of h9 isn't.
    mod.addImport("vcpu", b.createModule(.{
        .root_source_file = b.path("src/vcpu.zig"),
        .target = target,
        .optimize = p.vcpu_optimize,
    }));
    if (p.unicorn) |uc| mod.addImport("unicorn", uc);
    mod.addAnonymousImport("shim_arm64", .{ .root_source_file = p.shim });
    mod.addAnonymousImport("shim_amd64", .{ .root_source_file = p.shim_amd64 });
    if (os == .linux and target.result.cpu.arch == .x86_64)
        mod.addAnonymousImport("native_stub", .{ .root_source_file = p.native_stub });

    const web = os == .wasi;
    // The web host's kern turns on wasm exception handling, for setjmp
    // and longjmp, and has no host commands.
    const kern = addKern(b, if (web) webTarget(b, true) else target, optimize, web, p.host_cmd and !web, gfx, exported);
    if (!p.have_drawterm) {
        const fail = b.addFail(drawterm ++ " is missing; run scripts/vendor-drawterm.sh");
        kern.step.dependOn(&fail.step);
    }
    // Everything that imports the h9 module links kern.
    mod.linkLibrary(kern);

    mod.addAnonymousImport("guest_tree", .{ .root_source_file = p.guest_tree });
    mod.addAnonymousImport("builtin_root", .{ .root_source_file = p.builtin_root });

    const options = b.addOptions();
    options.addOption(Emu, "emu", p.emu);
    options.addOption(bool, "jit", p.jit);
    options.addOption(bool, "jit_check", p.jit_check);
    options.addOption(bool, "jit_verify", p.jit_verify);
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
        .web => m.addCSourceFiles(.{ .root = b.path("src/kern"), .files = &.{"gfx-web.c"}, .flags = flags }),
        .x11 => {
            m.addCMacro("H9_GFX_X11", "1");
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
    var emu = b.option(Emu, "emu", "Emulator backend to build in: unicorn (GPLv2: dev, CI and the h9-emu release only), or zig (h9's own, in progress)") orelse .none;
    // T0 in a Debug build runs several times slower than in a release one,
    // enough for long integration cases to time out against Unicorn's JIT.
    const vcpu_debug = b.option(bool, "vcpu-debug", "Build src/interp and src/jit with -Doptimize too, not ReleaseFast, in Debug builds (for debugging the emulator's CPUs)") orelse false;
    const vcpu_optimize: std.builtin.OptimizeMode = if (optimize == .Debug and !vcpu_debug) .ReleaseFast else optimize;
    const jit_check = b.option(bool, "jit-check", "With -Demu=zig: check every region against T0 as it runs (slow; for zig build integration)") orelse false;
    const jit_verify = b.option(bool, "jit-verify", "With -Demu=zig: verify every region after lifting and after opt, panicking on a bad one (default: on in Debug and ReleaseSafe builds)") orelse
        (optimize == .Debug or optimize == .ReleaseSafe);
    const no_jit = b.option(bool, "no-jit", "With -Demu=zig: the interpreter tier only, as on hosts that forbid generated code") orelse false;
    // No wheel exists for Windows, so it always builds from source.
    const unicorn_from = b.option(UnicornFrom, "unicorn", "With -Demu=unicorn: the prebuilt wheel library or a source build (default: prebuilt, source on Windows)") orelse
        if (os == .windows) UnicornFrom.source else .prebuilt;

    const gfx_opt = b.option(Gfx, "gfx", "GUI backend for --gfx (design/0015-gfx.md): cocoa, win32, x11, web, headless (tests) or none (default: cocoa on macOS, win32 on Windows, web for zig build web, none elsewhere)");
    const gfx = gfx_opt orelse Gfx.default(target.result);
    // zig build web's: web, the browser host's only GUI backend, unless
    // -Dgfx=none leaves graphics out (design/0120-browser-gfx.md).
    const web_gfx: Gfx = if (gfx_opt == .none) .none else .web;
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

    // The native backend's stub (design/0095-native-backend.md): a freestanding
    // static program, linked high so the guest's whole layout is free, and
    // embedded in h9.
    const native_stub = b.addExecutable(.{
        .name = "h9-stub",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vmm/native_stub.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .none }),
            .optimize = .ReleaseSmall,
            .single_threaded = true,
            .strip = true,
            .pic = false,
            .code_model = .large,
        }),
    });
    native_stub.pie = false;
    native_stub.image_base = 0x6000_0000_0000; // native_abi.stub_base

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

    // The built-in root (design/0087-builtin-root.md): multicall's trees for
    // the architectures this build runs, from `zig build slim`. A release
    // fails without them; a development build gets the skeleton only.
    const builtin_dir = b.option([]const u8, "builtin-root", "Directory of zig build slim's trees for the built-in root (default .local/9front)") orelse
        b.pathFromRoot(".local/9front");
    const release_build = b.option(bool, "release", "A release build: fail if the built-in root is missing an architecture's commands (design/0087-builtin-root.md)") orelse false;
    const builtin_root = builtinRoot(b, builtin_dir, pin(pins, "NINEFRONT_RELEASE"), builtinArches(target.result, emu), if (release_build) .required else .warn);

    const parts: ModuleParts = .{
        .target = target,
        .optimize = optimize,
        .emu = emu,
        .jit = !no_jit,
        .jit_check = jit_check,
        .jit_verify = jit_verify,
        .vcpu_optimize = vcpu_optimize,
        .unicorn = unicorn_mod,
        .shim = shim_bin.getOutput(),
        .shim_amd64 = shim_amd64_bin.getOutput(),
        .native_stub = native_stub.getEmittedBin(),
        .host_cmd = host_cmd,
        .guest_tree = guest_tree.file,
        .builtin_root = builtin_root,
        .builtin_dir = builtin_dir,
        .have_drawterm = have_drawterm,
        .version = version,
        .pins = pins,
    };
    // The h9 module, with the -Dgfx backend: h9, embedders and the tools.
    const mod = addH9Module(b, parts, gfx, true);
    kern_step.dependOn(&mod.kern.step);
    // The tests' module, with the headless backend for the [gfx] cases.
    const test_mod = if (gfx == .headless) mod else addH9Module(b, parts, .headless, false);

    // The browser host (design/0012-browser-host.md): h9 for wasm32-wasi
    // with its JS host and a demo page, in zig-out/web.
    const web_step = b.step("web", "Build the browser host into zig-out/web (design/0012-browser-host.md)");
    const web = addWeb(b, optimize, parts, web_gfx);
    web_step.dependOn(web.install);
    // The demo page's root archive, from a 386 root tree and the paths
    // src/web/root.list names; left out without one.
    const web_root = b.option([]const u8, "web-root", "386 root tree for the browser host's root archive (default .local/9front/root386)") orelse
        b.pathFromRoot(".local/9front/root386");
    if (std.Io.Dir.cwd().access(b.graph.io, b.pathJoin(&.{ web_root, "386/bin/rc" }), .{})) {
        const webroot = b.addExecutable(.{
            .name = "webroot",
            .root_module = b.createModule(.{ .root_source_file = b.path("tools/webroot.zig"), .target = b.graph.host, .optimize = .ReleaseSafe }),
        });
        const mk = b.addRunArtifact(webroot);
        mk.addArg(web_root);
        mk.addFileArg(b.path("src/web/root.list"));
        const archive = mk.addOutputFileArg("root.h9a");
        web.install.dependOn(&b.addInstallFileWithDir(archive, .{ .custom = "web" }, "root.h9a").step);
    } else |_| {}
    // The demo page's Linux root archive for ?linux, from the arm64 Alpine
    // root `scripts/fetch.sh alpinearm64web` makes and src/web/linux.list;
    // left out without one.
    const web_linux_root = b.option([]const u8, "web-linux-root", "arm64 Linux root tree for the browser host's Linux archive (default .local/linux/alpine-arm64-web)") orelse
        b.pathFromRoot(".local/linux/alpine-arm64-web");
    if (std.Io.Dir.cwd().access(b.graph.io, b.pathJoin(&.{ web_linux_root, "bin/busybox" }), .{})) {
        const webroot = b.addExecutable(.{
            .name = "webroot",
            .root_module = b.createModule(.{ .root_source_file = b.path("tools/webroot.zig"), .target = b.graph.host, .optimize = .ReleaseSafe }),
        });
        const mk = b.addRunArtifact(webroot);
        mk.addArg(web_linux_root);
        mk.addFileArg(b.path("src/web/linux.list"));
        const archive = mk.addOutputFileArg("linux.h9a");
        web.install.dependOn(&b.addInstallFileWithDir(archive, .{ .custom = "web" }, "linux.h9a").step);
    } else |_| {}
    // The demo page in Chromium through Playwright (tests/web/browser.mjs).
    const web_test = b.addSystemCommand(&.{ "node", "tests/web/browser.mjs", b.getInstallPath(.{ .custom = "web" }, "") });
    web_test.setCwd(b.path("."));
    web_test.has_side_effects = true;
    web_test.expectExitCode(0);
    web_test.step.dependOn(web.install);
    // Graphics on the canvas (tests/web/gfx.mjs, design/0120-browser-gfx.md).
    const web_gfx_test = b.addSystemCommand(&.{ "node", "tests/web/gfx.mjs", b.getInstallPath(.{ .custom = "web" }, "") });
    web_gfx_test.setCwd(b.path("."));
    web_gfx_test.has_side_effects = true;
    web_gfx_test.expectExitCode(0);
    web_gfx_test.step.dependOn(web.install);
    const web_test_step = b.step("web-test", "Run the browser host's demo page and its canvas cases in Chromium with Playwright (needs a 386 root for root.h9a)");
    web_test_step.dependOn(&web_test.step);
    if (web_gfx != .none) web_test_step.dependOn(&web_gfx_test.step);

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

    // Linux fixtures (tests/fixtures/linux, design/0018-linux-personality.md):
    // static musl programs for arm64, amd64, and 386, in fixtures/linux/<arch>.
    const linux_fixtures = b.step("linux-fixtures", "Build the Linux fixtures in tests/fixtures/linux (static musl, arm64, amd64, and 386)");
    for ([_][]const u8{ "arm64", "amd64", "386" }, [_]std.Target.Cpu.Arch{ .aarch64, .x86_64, .x86 }) |arch, cpu| {
        const lt = b.resolveTargetQuery(.{ .cpu_arch = cpu, .os_tag = .linux, .abi = .musl });
        for (linux_fixture_names) |name| {
            const m = b.createModule(.{ .target = lt, .optimize = .ReleaseSmall, .link_libc = true });
            m.addCSourceFile(.{ .file = b.path(b.fmt("tests/fixtures/linux/{s}.c", .{name})), .flags = &.{ "-std=c11", "-D_GNU_SOURCE" } });
            const fx = b.addExecutable(.{ .name = name, .root_module = m, .linkage = .static });
            const inst = b.addInstallArtifact(fx, .{ .dest_dir = .{ .override = .{ .custom = b.fmt("fixtures/linux/{s}", .{arch}) } } });
            linux_fixtures.dependOn(&inst.step);
        }
    }
    b.getInstallStep().dependOn(linux_fixtures);

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
    // The self-host demos and cases need /sys/src: the root's (zig build
    // mkroot -- --src), or else this checkout's, which scripts/fetch.sh makes at the
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
    // A macOS VM has no HVF (kern.hv_support is 0), so h9 can't run there on hvf.
    if (os == .macos and std.mem.eql(u8, cases_arch, "arm64") and target.result.cpu.arch == .aarch64 and
        (b.graph.host.result.os.tag != .macos or hostHasHvf(b)))
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
    // The native backend (design/0095-native-backend.md) runs amd64 on Linux
    // x86_64 when the kernel has Syscall User Dispatch and seccomp; h9
    // skips it where it can't run, as it does a backend that isn't built.
    if (os == .linux and b.graph.host.result.os.tag == .linux and target.result.cpu.arch == .x86_64 and
        b.graph.host.result.cpu.arch == .x86_64 and std.mem.eql(u8, cases_arch, "amd64"))
        backends.appendSlice(b.allocator, "native,") catch @panic("OOM");
    if (emu == .unicorn) backends.appendSlice(b.allocator, "emu,") catch @panic("OOM");
    // -Dbackends picks the backends instead, such as only `native` for a
    // quick run where there's no KVM.
    const want_backends = b.option([]const u8, "backends", "Backends to run the integration cases on, comma-separated (default: every one built in that runs here)");
    // -Dweb runs them on the web host under Node instead: h9-node on h9's
    // own 386 CPU (h86), with the root's 386 binaries
    // (design/0012-browser-host.md).
    const test_web = b.option(bool, "web", "Run the integration cases on the web host under Node (386)") orelse false;
    const backend_list = if (test_web) want_backends orelse "emu" else if (want_backends) |w| w else if (backends.items.len > 0) backends.items else "auto";
    const it: Integration = if (test_web) .{
        .bin = b.getInstallPath(.{ .custom = "web" }, "h9-node"),
        .arch = "386",
        .web = true,
        .step = web.install,
        // With -Demu=unicorn, the native h9 serves the WebSocket cases'
        // roots on the emulator.
        .server = if (emu == .unicorn) h9_bin else null,
        .server_step = signed_step,
    } else .{ .bin = h9_bin, .arch = test_arch, .web = false, .step = signed_step };

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
    const go_cases: ?GoFixtures = if (emu == .unicorn or std.mem.indexOf(u8, backend_list, "native") != null) go_fixtures else null;
    // The Linux Go fixtures (design/0049-linux-threads.md), with the same
    // toolchain, into fixtures/linux/<arch>/go.
    if (go_bin) |g| for ([_][]const u8{ "arm64", "amd64", "386" }) |arch| {
        const dir = b.getInstallPath(.prefix, b.fmt("fixtures/linux/{s}/go", .{arch}));
        const run = b.addSystemCommand(&.{ g, "-C", "tests/fixtures/linux/go", "build", "-trimpath", "-o", b.fmt("{s}{s}", .{ dir, std.fs.path.sep_str }), "./..." });
        run.setCwd(b.path("."));
        goEnv(run, go_version);
        run.setEnvironmentVariable("GOOS", "linux");
        run.setEnvironmentVariable("GOARCH", arch);
        run.has_side_effects = true;
        linux_fixtures.dependOn(&run.step);
    };
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
    const it_filters = b.option([]const []const u8, "filter", "Run only the integration cases whose names contain one of these") orelse &.{};
    const run_integration = addIntegration(b, optimize, it_filters, it, root, backend_list, run_pending, if (test_web) null else go_cases, guest_test, host_cmd and !test_web, src_dir);
    if (!test_web) run_integration.step.dependOn(linux_fixtures);
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
    // The arm64 instruction inventory over ha64's decoder
    // (tools/a64inv.zig): zig build a64-inventory -- PATH...
    const a64inv = b.addExecutable(.{
        .name = "a64inv",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/a64inv.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "a64decode", .module = b.createModule(.{ .root_source_file = b.path("src/interp/a64/decode.zig") }) },
                .{ .name = "aout", .module = b.createModule(.{ .root_source_file = b.path("src/aout.zig") }) },
            },
        }),
    });
    const run_a64inv = b.addRunArtifact(a64inv);
    run_a64inv.has_side_effects = true;
    if (b.args) |args| run_a64inv.addArgs(args) else run_a64inv.addArg(b.pathJoin(&.{ root, "arm64" }));
    b.step("a64-inventory", "Report the arm64 instructions in binaries (default: the root tree's arm64): zig build a64-inventory -- PATH...").dependOn(&run_a64inv.step);

    // The 386 instruction inventory over h86's decoder and T0
    // (tools/x86inv.zig): zig build x86-inventory -- PATH...
    const x86inv = b.addExecutable(.{
        .name = "x86inv",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/x86inv.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "vcpu", .module = b.createModule(.{ .root_source_file = b.path("src/vcpu.zig") }) },
                .{ .name = "aout", .module = b.createModule(.{ .root_source_file = b.path("src/aout.zig") }) },
            },
        }),
    });
    const run_x86inv = b.addRunArtifact(x86inv);
    run_x86inv.has_side_effects = true;
    if (b.args) |args| run_x86inv.addArgs(args) else run_x86inv.addArg(b.pathJoin(&.{ root, "386" }));
    b.step("x86-inventory", "Report the 386 instructions in binaries (default: the root tree's 386): zig build x86-inventory -- PATH...").dependOn(&run_x86inv.step);

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
            const run_cases = addIntegration(b, optimize, tagFilters(b, ps[i]), it, root, backend_list, true, if (test_web) null else go_cases, guest_test, host_cmd and !test_web, src_dir);
            if (!test_web) run_cases.step.dependOn(linux_fixtures);
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

    // Builds the 9front root tree from the pinned image (tools/mkroot.zig),
    // run from the repository root: zig build mkroot -- [--force] [--src]
    // [--arch arm64,386,amd64].
    const mkroot_tool = b.addExecutable(.{
        .name = "mkroot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/mkroot.zig"),
            .target = b.graph.host,
        }),
    });
    const run_mkroot = b.addRunArtifact(mkroot_tool);
    run_mkroot.setCwd(b.path("."));
    run_mkroot.has_side_effects = true;
    run_mkroot.stdio = .inherit;
    if (b.args) |args| run_mkroot.addArgs(args);
    b.step("mkroot", "Build the 9front root tree in .local/9front/root: zig build mkroot -- [--force] [--src] [--arch arm64,386,amd64]").dependOn(&run_mkroot.step);

    // Unpacks a 9front release ISO into a root tree (tools/isoroot.zig),
    // for the Pages workflow's 386 root: zig build isoroot -- ISO DIR.
    const isoroot_tool = b.addExecutable(.{
        .name = "isoroot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/isoroot.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const run_isoroot = b.addRunArtifact(isoroot_tool);
    run_isoroot.setCwd(b.path("."));
    run_isoroot.has_side_effects = true;
    run_isoroot.stdio = .inherit;
    if (b.args) |args| run_isoroot.addArgs(args);
    b.step("isoroot", "Unpack a 9front release ISO into a root tree: zig build isoroot -- ISO DIR").dependOn(&run_isoroot.step);

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
    const test_step = b.step("test", "Run unit tests and the backend tests (not the integration cases)");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    // h9.wasm too, so a change to the shared vmm or JIT code that breaks
    // wasm32 (64-bit atomics, threads) is caught where it's made.
    test_step.dependOn(&web.exe.step);
    addVcpuTests(b, test_step, target, optimize);
    addJitTestTools(b, test_step, target, optimize, unicorn_mod);
    b.step("unit", "Run the h9 module's unit tests only").dependOn(&b.addRunArtifact(mod_tests).step);
    // The guest tree's rules (tools/guesttree.zig), which build.zig applies.
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tools/guesttree.zig"),
        .target = b.graph.host,
    }) })).step);
    // The time limits on the tests' listeners (tests/deadline.zig).
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/deadline.zig"),
        .target = b.graph.host,
    }) })).step);
    // The design tool's tests read tools/testdata from the repository root.
    const design_tests = b.addRunArtifact(b.addTest(.{ .root_module = design_tool.root_module }));
    design_tests.setCwd(b.path("."));
    test_step.dependOn(&design_tests.step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mkroot_tool.root_module })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = isoroot_tool.root_module })).step);
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
    // The integration cases are their own step, `zig build integration`, so
    // running both doesn't run them twice; `zig build test integration`
    // runs everything.

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
    // zig build test runs it on the hello fixture where a backend can: the
    // default backend (auto: HVF on an arm64 Mac that has it, signed like h9,
    // else the emulator) for one machine, and the emulator for the second.
    // HVF allows one VM per host process.
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
        // Machine 0's backend isn't named: auto picks it when it runs.
        run_embed.addCheck(.{ .expect_stdout_match = "machine 0 (" });
        run_embed.addCheck(.{ .expect_stdout_match = "): exited \"\"\n  hello\n" });
        if (emu == .unicorn) run_embed.addCheck(.{ .expect_stdout_match = "machine 1 (emu): exited \"\"\n  hello\n" });
        run_embed.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&run_embed.step);
    }

    // The arm64 JIT plan's [a64-jit] cases, through the vmm interface on
    // T0 and T1; they skip without -Demu=zig.
    const a64_jit = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/a64.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "h9", .module = mod.mod }},
    }) });
    if (os == .macos) {
        addSdkPaths(b, a64_jit.root_module);
        a64_jit.root_module.linkFramework("Hypervisor", .{});
    }
    linkUnicorn(a64_jit);
    const a64_jit_run = b.addRunArtifact(a64_jit);
    test_step.dependOn(&a64_jit_run.step);
    b.step("a64-jit", "Run the arm64 JIT plan's [a64-jit] cases on T0 and T1 (tests/a64.zig; needs -Demu=zig)").dependOn(&a64_jit_run.step);

    // The speed numbers in SPEC.md's "Limits and selection". Always
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
    addComputeBenches(b, bench);
    const run_bench = b.addRunArtifact(bench);
    run_bench.has_side_effects = true;
    if (b.args) |a| run_bench.addArgs(a);
    if (os == .macos and b.graph.host.result.os.tag == .macos) {
        const sign = b.addSystemCommand(&.{ "codesign", "--force", "--sign", "-", "--entitlements" });
        sign.addFileArg(b.path("h9.entitlements"));
        sign.addFileArg(bench.getEmittedBin());
        run_bench.step.dependOn(&sign.step);
    }
    b.step("bench", "Time a compute loop, pwrite round trips, and the compute benchmarks on every backend built in (-- compute: those only; -Demu=zig for T0 and T1)").dependOn(&run_bench.step);

    // For running the tests in a VM (scripts/lima/vm test): the backend
    // tests and the integration tests, built for the target.
    const install_tests_step = b.step("install-tests", "Install the backend and integration tests as zig-out/bin/backend-tests and integration-tests");
    install_tests_step.dependOn(&b.addInstallArtifact(backend_tests, .{ .dest_sub_path = b.fmt("backend-tests{s}", .{target.result.exeFileExt()}) }).step);
    install_tests_step.dependOn(&b.addInstallArtifact(integrationTests(b, target, optimize, &.{}), .{ .dest_sub_path = b.fmt("integration-tests{s}", .{target.result.exeFileExt()}) }).step);
}

/// Whether this Mac can run HVF: a macOS VM reports kern.hv_support 0.
fn hostHasHvf(b: *std.Build) bool {
    const r = std.process.run(b.allocator, b.graph.io, .{ .argv = &.{ "sysctl", "-n", "kern.hv_support" } }) catch return false;
    const ok = switch (r.term) {
        .exited => |code| code == 0,
        else => false,
    };
    return ok and std.mem.eql(u8, std.mem.trim(u8, r.stdout, " \t\r\n"), "1");
}

/// The JIT's test tools (src/jit/README.md, "Test tools"): lockstep against
/// Unicorn (with -Demu=unicorn), the fuzzers, and the litmus tests.
fn addJitTestTools(b: *std.Build, test_step: *std.Build.Step, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, unicorn: ?*std.Build.Module) void {
    const vcpu = b.createModule(.{ .root_source_file = b.path("src/vcpu.zig"), .target = target, .optimize = optimize });
    const lockstep_step = b.step("lockstep", "Run the lockstep tests against Unicorn (needs -Demu=unicorn)");
    const lockstep: ?*std.Build.Module = if (unicorn) |uc| b.createModule(.{
        .root_source_file = b.path("src/vmm/lockstep.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "unicorn", .module = uc }},
    }) else null;
    if (lockstep) |ls| {
        const t = b.addTest(.{ .root_module = ls });
        linkUnicorn(t);
        lockstep_step.dependOn(&b.addRunArtifact(t).step);
        test_step.dependOn(&b.addRunArtifact(t).step);
    } else lockstep_step.dependOn(&b.addFail("lockstep: needs -Demu=unicorn").step);

    // The fuzzers: the region check always, lockstep with -Demu=unicorn.
    // ReleaseSafe unless -Doptimize says otherwise: fast, and still checked.
    const fuzz_optimize: std.builtin.OptimizeMode = if (optimize == .Debug) .ReleaseSafe else optimize;
    const fuzz_vcpu = b.createModule(.{ .root_source_file = b.path("src/vcpu.zig"), .target = target, .optimize = fuzz_optimize });
    const fuzz_lockstep: ?*std.Build.Module = if (unicorn) |uc| b.createModule(.{
        .root_source_file = b.path("src/vmm/lockstep.zig"),
        .target = target,
        .optimize = fuzz_optimize,
        .imports = &.{.{ .name = "unicorn", .module = uc }},
    }) else null;
    const fuzz_options = b.addOptions();
    fuzz_options.addOption(bool, "unicorn", unicorn != null);
    // zig build fuzz-long: both fuzzers with the region check, generated
    // code (--native), and lockstep when Unicorn is built in, for
    // -Dfuzz-minutes (default 60), -Dfuzz-jobs processes each (default 2),
    // tallying divergences instead of stopping. Each job starts its seeds
    // 2^40 apart from -Dfuzz-seed (default: from the clock).
    const fuzz_long = b.step("fuzz-long", "Run fuzz-a64 and fuzz-x86 with the region check and --native for an hour across seeds (-Dfuzz-minutes, -Dfuzz-jobs, -Dfuzz-seed)");
    const fuzz_minutes = b.option(u32, "fuzz-minutes", "zig build fuzz-long: how long to fuzz (default 60)") orelse 60;
    const fuzz_jobs = b.option(u32, "fuzz-jobs", "zig build fuzz-long: processes per fuzzer (default 2)") orelse 2;
    const fuzz_seed = b.option(u64, "fuzz-seed", "zig build fuzz-long: the first seed (default: from the clock)") orelse
        @as(u64, @truncate(@as(u128, @bitCast(@as(i128, std.Io.Timestamp.now(b.graph.io, .real).nanoseconds)))));
    var fuzz_exes: [2]*std.Build.Step.Compile = undefined;
    var fuzz_i: usize = 0;
    for ([_][]const u8{ "a64", "x86" }) |arch| {
        const exe = b.addExecutable(.{
            .name = b.fmt("fuzz-{s}", .{arch}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("tests/jit/fuzz_{s}.zig", .{arch})),
                .target = target,
                .optimize = fuzz_optimize,
                .imports = &.{.{ .name = "vcpu", .module = fuzz_vcpu }},
            }),
        });
        exe.root_module.addOptions("fuzz_options", fuzz_options);
        if (fuzz_lockstep) |ls| {
            exe.root_module.addImport("lockstep", ls);
            linkUnicorn(exe);
        }
        const run = b.addRunArtifact(exe);
        run.has_side_effects = true;
        if (b.args) |a| run.addArgs(a);
        b.step(b.fmt("fuzz-{s}", .{arch}), b.fmt("Fuzz the {s} T0 and lifter with random programs (-- --help for options; lockstep needs -Demu=unicorn)", .{arch})).dependOn(&run.step);
        fuzz_exes[fuzz_i] = exe;
        fuzz_i += 1;
    }
    const fuzz_long_exe = b.addExecutable(.{
        .name = "fuzz-long",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/jit/fuzz_long.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const long = b.addRunArtifact(fuzz_long_exe);
    long.has_side_effects = true;
    long.addArgs(&.{ "--minutes", b.fmt("{d}", .{fuzz_minutes}), "--jobs", b.fmt("{d}", .{fuzz_jobs}), "--seed", b.fmt("{d}", .{fuzz_seed}) });
    for (fuzz_exes) |e| long.addArtifactArg(e);
    fuzz_long.dependOn(&long.step);
    _ = vcpu;

    const litmus = b.addExecutable(.{
        .name = "litmus",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/jit/litmus.zig"),
            .target = target,
            .optimize = fuzz_optimize,
            .imports = &.{.{ .name = "vcpu", .module = fuzz_vcpu }},
        }),
    });
    const litmus_run = b.addRunArtifact(litmus);
    litmus_run.has_side_effects = true;
    if (b.args) |a| litmus_run.addArgs(a);
    b.step("litmus", "Run the threading litmus tests on every tier, with their outcome tallies (-- --iters N --tier T --only NAME)").dependOn(&litmus_run.step);
}

/// The emulator's own CPUs (src/vcpu.zig): the JIT layer's unit tests,
/// natively, and the wasm emitter's under Node when Node is installed
/// (tests/jit/run.mjs). `zig build vcpu` runs just these. `zig build
/// vcpu-web`, and `web-test` with it, runs the wasm emitter's in Chromium.
fn addVcpuTests(b: *std.Build, test_step: *std.Build.Step, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const step = b.step("vcpu", "Run the emulator CPU and JIT tests (src/vcpu.zig), natively and under Node");
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/vcpu.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const run = b.addRunArtifact(tests);
    step.dependOn(&run.step);
    test_step.dependOn(&run.step);

    // The 386 JIT plan's [x86-jit] cases, on T0 and T1.
    const x86 = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/x86.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "vcpu", .module = b.createModule(.{
            .root_source_file = b.path("src/vcpu.zig"),
            .target = target,
            .optimize = optimize,
        }) }},
    }) });
    const x86_run = b.addRunArtifact(x86);
    step.dependOn(&x86_run.step);
    test_step.dependOn(&x86_run.step);
    b.step("x86-jit", "Run the 386 JIT plan's [x86-jit] cases on T0 and T1 (tests/x86.zig)").dependOn(&x86_run.step);

    // h86's memory-model litmus tests: compiled code on host threads.
    // ReleaseSafe unless -Doptimize says otherwise, so the threads race.
    const litmus = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/jit/litmus_x86.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
        .imports = &.{.{ .name = "vcpu", .module = b.createModule(.{
            .root_source_file = b.path("src/vcpu.zig"),
            .target = target,
            .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
        }) }},
    }) });
    const litmus_run = b.addRunArtifact(litmus);
    step.dependOn(&litmus_run.step);
    test_step.dependOn(&litmus_run.step);
    b.step("litmus-x86", "Run h86's memory-model litmus tests on compiled code").dependOn(&litmus_run.step);

    // ha64's memory-model litmus tests: every tier on host threads. About
    // two minutes at 5000 runs a test, so in zig build vcpu, not test.
    const litmus_a64 = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/jit/litmus_a64.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
        .imports = &.{.{ .name = "vcpu", .module = b.createModule(.{
            .root_source_file = b.path("src/vcpu.zig"),
            .target = target,
            .optimize = if (optimize == .Debug) .ReleaseSafe else optimize,
        }) }},
    }) });
    const litmus_a64_run = b.addRunArtifact(litmus_a64);
    step.dependOn(&litmus_a64_run.step);
    b.step("litmus-a64", "Run ha64's memory-model litmus tests on every tier").dependOn(&litmus_a64_run.step);

    const node = b.findProgram(&.{"node"}, &.{}) catch return;
    const runtime = b.addExecutable(.{
        .name = "jit-runtime",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/jit/wasm_runtime.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            // Debug: optimizing the stand-in T0's dispatch for wasm takes minutes.
            .optimize = .Debug,
            .imports = &.{.{ .name = "vcpu", .module = b.createModule(.{ .root_source_file = b.path("src/vcpu.zig") }) }},
        }),
    });
    runtime.entry = .disabled;
    runtime.rdynamic = true;
    // Imported, as h9.wasm's is, so h9-web.js's JIT installer can grow it.
    runtime.import_table = true;
    const node_run = b.addSystemCommand(&.{ node, "tests/jit/run.mjs" });
    node_run.addFileArg(runtime.getEmittedBin());
    node_run.expectExitCode(0);
    step.dependOn(&node_run.step);
    test_step.dependOn(&node_run.step);

    const browser_run = b.addSystemCommand(&.{ node, "tests/jit/browser.mjs" });
    browser_run.addFileArg(runtime.getEmittedBin());
    browser_run.setCwd(b.path("."));
    browser_run.has_side_effects = true;
    browser_run.expectExitCode(0);
    b.step("vcpu-web", "Run the wasm emitter's tests in Chromium with Playwright").dependOn(&browser_run.step);
    if (b.top_level_steps.get("web-test")) |web_test| web_test.step.dependOn(&browser_run.step);
}
