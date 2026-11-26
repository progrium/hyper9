const std = @import("std");
const frontmatter = @import("tools/frontmatter.zig");
const guesttree = @import("tools/guesttree.zig");

const drawterm = "third_party/drawterm";

// drawterm's kern/Makefile OFILES with AUDIO=none, without devtab.c and
// devenv.c (src/kern/dev/env.zig is our own), procinit.c (src/kern/proc.c has it,
// for the one process record), devcmd.c (host commands live on the
// host-cmd branch while design/host-cmd.md rethinks them), or the files
// ported to Zig (design/kernel-port.md, src/kern/port.zig): allocb.c,
// chan.c, dev.c, devmnt.c, devpipe.c, devroot.c, pgrp.c, qio.c, qlock.c,
// rwlock.c, sleep.c, and sysfile.c. Plus the OS files below.
const kern_sources = [_][]const u8{
    "alloc.c",    "data.c",    "devaudio.c", "devaudio-none.c",
    "devcons.c",  "devdraw.c", "devip.c",    "devkbd.c",
    "devmouse.c", "devssl.c",  "devtls.c",   "error.c",
    "parse.c",    "stub.c",    "term.c",     "waserror.c",
};
// OS=posix (Make.unix), and OS=win32 with FS=fs-win32 (Make.win64).
const kern_posix = [_][]const u8{ "devfs-posix.c", "devip-posix.c", "devlfd-posix.c", "posix.c" };
const kern_win32 = [_][]const u8{ "devfs-win32.c", "devip-win32.c", "devlfd-win32.c", "win32.c" };
// The web host (design/epoch-0/browser-host.md): devfs and devlfd build
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
    // drawterm's names (error, print, lock, panic) stay inside h9, so in
    // libh9 (src/capi.zig), a shared library, they don't bind to libc's.
    "-fvisibility=hidden",
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
/// Programs in tests/fixtures/segattach, for tests/engines.zig.
const segattach_fixtures = [_][]const u8{
    "shared_rfork", "memory_rfork", "place",  "sixth",     "detach",
    "segbrk",       "segfree",      "ronly",  "execfault", "headroom",
    "brkstop",      "exec_a",       "exec_b", "sibling",   "procseg",
};
/// Programs in tests/fixtures/overlay, for tests/engines.zig. They use the
/// segattach fixtures' lib.S.
const overlay_fixtures = [_][]const u8{ "tmp_own", "tmp_absent", "copyup_reader", "root_own", "root_absent" };
/// Programs in tests/fixtures/srv, for tests/engines.zig, with the same lib.S.
const srv_fixtures = [_][]const u8{ "board", "hold", "absent", "orclose" };
const fdmount_fixtures = [_][]const u8{ "cat", "create" };
/// Programs in tests/fixtures/htools, for tests/engines.zig, with the same lib.S.
const htools_fixtures = [_][]const u8{ "tree", "masked" };

/// Programs in tests/fixtures/sema, for tests/engines.zig; they include
/// the segattach fixtures' lib.S.
const sema_fixtures = [_][]const u8{
    "rendezvous", "semacquire", "count", "badarg", "odd", "unmapped", "interrupt",
};

/// Programs in tests/fixtures/net, for tests/engines.zig. They share
/// tests/fixtures/segattach/lib.S.
const net_fixtures = [_][]const u8{ "ctl", "cs", "dns" };
/// C programs in tests/fixtures/linux, built static for Linux on arm64 and
/// amd64, for the linux-personality cases in tests/integration.zig.
const linux_fixture_names = [_][]const u8{ "hello", "probe", "die", "sigreturn", "net", "threads", "files", "tls386", "bigexe", "pty", "fifo", "cowfork", "symlink", "chroot" };

/// Programs in tests/fixtures/gfx, for tests/engines.zig's [gfx] cases on
/// the headless backend, with the same lib.S.
const gfx_fixtures = [_][]const u8{ "binds", "drawnew", "draw", "kbd", "mouse", "snarf", "sleep" };

/// The h9 the integration cases run: the native binary, or h9-node for
/// the web host (-Dweb). `step` builds it.
const Integration = struct {
    bin: std.Build.LazyPath,
    arch: ?[]const u8,
    web: bool,
    step: *std.Build.Step,
    /// With `web`: a native h9 that runs the root's 386 binaries, for the
    /// cases' 9P servers (H9_TEST_SERVER), since the web host can't listen.
    server: ?std.Build.LazyPath = null,
    server_step: *std.Build.Step = undefined,
};

/// Runs tests/integration.zig against the h9 binary. `filters` selects
/// cases by name; with `pending`, cases tagged with a proposal that isn't
/// implemented run instead of skipping. `it.arch`, if given, is passed to
/// h9 as --arch (from -Darch). `guest_test` says h9 was built with
/// -Dguest-test. `src`, if given, is a 9front checkout's `sys` directory,
/// which the self-host cases bind over /sys when the root lacks /sys/src. The cases are split
/// `shards` ways (H9_TEST_SHARD, tests/integration.zig's skipShard), one
/// run of the same binary for each, which the build runner runs side by
/// side: the cases mostly wait on h9, terminals, and sockets, so one run
/// leaves most cores idle. `step` depends on every run.
fn addIntegration(b: *std.Build, step: *std.Build.Step, shards: u32, optimize: std.lang.Optimize, filters: []const []const u8, it: Integration, root: []const u8, engines: []const u8, pending: bool, go: ?GoFixtures, guest_test: bool, src: ?[]const u8) []*std.Build.Step.Run {
    // The paths the cases find by default: the install prefix isn't known
    // until the build runs, so they're build options, not environment
    // variables (tests/integration.zig's getenv).
    const paths = b.addOptions();
    paths.addOptionPathUntracked("H9_TEST_BIN", it.bin);
    paths.addOptionPathUntracked("H9_TEST_LINUX", b.graph.path(.install_prefix, "fixtures/linux"));
    if (it.server) |sv| paths.addOptionPathUntracked("H9_TEST_SERVER", sv);
    if (go) |g| paths.addOptionPathUntracked("H9_TEST_GO", g.dir);
    const tests = integrationTests(b, b.graph.host, optimize, filters, paths);
    const n = @max(shards, 1);
    const runs = b.allocator.alloc(*std.Build.Step.Run, n) catch @panic("OOM");
    for (runs, 0..) |*r, i| {
        r.* = addIntegrationRun(b, tests, it, root, engines, pending, go, guest_test, src);
        if (n > 1) {
            r.*.setName(b.fmt("integration {d}/{d}", .{ i + 1, n }));
            r.*.setEnvironmentVariable("H9_TEST_SHARD", b.fmt("{d}/{d}", .{ i, n }));
        }
        step.dependOn(&r.*.step);
    }
    return runs;
}

/// One run of the integration binary `tests`, set up as addIntegration says.
fn addIntegrationRun(b: *std.Build, tests: *std.Build.Step.Compile, it: Integration, root: []const u8, engines: []const u8, pending: bool, go: ?GoFixtures, guest_test: bool, src: ?[]const u8) *std.Build.Step.Run {
    const run = b.addRunArtifact(tests);
    // The self-host cases' source when the root has no /sys/src
    // (design/epoch-0/self-host.md).
    if (src) |dir| run.setEnvironmentVariable("H9_TEST_SRC", dir);
    run.step.dependOn(it.step);
    if (it.server != null) run.step.dependOn(it.server_step);
    // h9 serves tests/fixtures/guest in #H (design/epoch-0/guest-tools.md).
    if (guest_test) run.setEnvironmentVariable("H9_TEST_GUEST_TOOLS", "1");
    if (it.arch) |a| run.setEnvironmentVariable("H9_TEST_ARCH", a);
    if (it.web) run.setEnvironmentVariable("H9_TEST_WEB", "1");
    if (go) |g| {
        run.step.dependOn(g.step);
        // On the sud engine when it's in the list, else the emulator.
        if (std.mem.indexOf(u8, engines, "sud") != null) run.setEnvironmentVariable("H9_TEST_GO_ENGINE", "sud");
    }
    run.setEnvironmentVariable("H9_TEST_ROOT", root);
    run.setEnvironmentVariable("H9_TEST_ENGINES", engines);
    // The Linux fixtures and the Alpine roots from scripts/fetch.sh
    // (design/epoch-0/linux-personality.md).
    run.setEnvironmentVariable("H9_TEST_LINUX_ROOT", pathFromRoot(b, ".local/linux"));
    // diod, for the [dotl] cases against a real 9P2000.L server
    // (scripts/fetch.sh diod); they skip without it.
    run.setEnvironmentVariable("H9_TEST_DIOD", pathFromRoot(b, ".local/bin/diod"));
    // ZeroFS, for the [dotl] cases against a 9P2000.L.Z server
    // (scripts/fetch.sh zerofs); they skip without it.
    run.setEnvironmentVariable("H9_TEST_ZEROFS", pathFromRoot(b, ".local/bin/zerofs"));
    // The tree `zig build slim` makes, for the multicall cases, which skip
    // without it (design/epoch-0/multicall.md).
    const release = pin(b.root.root_dir.handle.readFileAlloc(b.graph.io, "scripts/pins.sh", b.allocator, .limited(1 << 16)) catch "", "NINEFRONT_RELEASE");
    run.setEnvironmentVariable("H9_TEST_SLIM_ROOT", pathFromRoot(b, b.fmt(".local/9front/slim-{s}-{s}", .{ release, it.arch orelse "arm64" })));
    if (pending) run.setEnvironmentVariable("H9_TEST_PENDING", "1");
    run.has_side_effects = true;
    return run;
}

/// The Go fixtures (tests/fixtures/go, design/epoch-0/go-compat.md): plan9/amd64
/// binaries built with the pinned Go toolchain into `dir` by `step`.
const GoFixtures = struct { dir: std.Build.LazyPath, step: *std.Build.Step };

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
    const dir = b.graph.path(.install_prefix, "fixtures/go");
    const run = b.addSystemCommand(&.{ go, "-C", "tests/fixtures/go", "build", "-trimpath", "-o" });
    run.addDirectoryArg2(dir, .{ .suffix = std.fs.path.sep_str, .make_absolute = true });
    run.addArg("./...");
    run.setCwd(b.path("."));
    goEnv(run, version);
    run.has_side_effects = true;
    return .{ .dir = dir, .step = &run.step };
}

/// tests/integration.zig as a test binary. It links libc for the pty in
/// tests/term.zig.
fn integrationTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, filters: []const []const u8, paths: *std.Build.Step.Options) *std.Build.Step.Compile {
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
                .{ .name = "test_paths", .module = paths.createModule() },
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
    var dir = b.root.root_dir.handle.openDir(io, "design", .{ .iterate = true }) catch {
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

/// Test-name filters for the cases tagged with a proposal, by its slug:
/// `[x]`, `[x, `, `, x]` and `, x, `.
fn tagFilters(b: *std.Build, p: frontmatter.Proposal) []const []const u8 {
    const t = p.slug;
    return b.allocator.dupe([]const u8, &.{ b.fmt("[{s}]", .{t}), b.fmt("[{s}, ", .{t}), b.fmt(", {s}]", .{t}), b.fmt(", {s}, ", .{t}) }) catch @panic("OOM");
}

/// Registers a web test file as a demo of each proposal one of its cases is
/// tagged with, so `zig build proposal -Dp=...` runs the file. The file's
/// cases run together; they aren't filtered by tag.
fn addWebCases(b: *std.Build, demos: *std.StringHashMapUnmanaged(std.ArrayList(*std.Build.Step)), file: []const u8, step: *std.Build.Step) void {
    const text = b.root.root_dir.handle.readFileAlloc(b.graph.io, file, b.allocator, .limited(1 << 24)) catch return;
    for (proposals(b)) |p| if (p.slug.len > 0 and frontmatter.tagsCase(text, p.slug)) addDemo(b, demos, p.slug, step);
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

/// The emulator, h9's own CPUs (src/engine/hcpu/engine.zig on src/engine/hcpu/hcpu.zig): ha64
/// for arm64 guests, h86 for 386, and hx64 for amd64. It's built in on
/// every target that has a JIT for it (arm64 and x86-64, and the web
/// host, which sets it itself) and left out elsewhere
/// (design/epoch-0/retire-unicorn.md).
pub const Emu = enum { none, hcpu };

/// The emulator a target gets: hcpu wherever it has a JIT.
fn emuFor(t: std.Target) Emu {
    return switch (t.cpu.arch) {
        .aarch64, .x86_64 => .hcpu,
        else => .none,
    };
}

/// Unicorn as the lockstep oracle (tools/lockstep.zig): its translated
/// header, the prebuilt libunicorn.a scripts/fetch.sh unpacks from the
/// PyPI wheels, and the target the tools that link it are built for.
/// Unicorn is GPLv2, so only the test tools link it, never h9.
const Oracle = struct {
    module: *std.Build.Module,
    lib: std.Build.LazyPath,
    /// On Linux arm64, a stand-in for symbols the musl wheel expects.
    compat: ?*std.Build.Step.Compile,
    /// The wheels' Linux libraries are for musl, so on Linux the tools
    /// that link one are built for musl too.
    target: std.Build.ResolvedTarget,
};

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

/// The lockstep oracle for `target`, or why there isn't one: a hint for
/// the steps that need it to fail with.
fn addOracle(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) union(enum) { ok: Oracle, missing: []const u8 } {
    const t = target.result;
    const oracle_target = if (t.os.tag == .linux and !t.abi.isMusl())
        b.resolveTargetQuery(.{ .cpu_arch = t.cpu.arch, .os_tag = .linux, .abi = .musl })
    else
        target;
    const name = unicornDir(oracle_target.result) orelse
        return .{ .missing = "Unicorn's prebuilt library is for macOS arm64 and Linux arm64 and x86_64 only" };
    const dir = b.pathJoin(&.{ ".local/unicorn", name });
    const lib = b.pathJoin(&.{ dir, "lib/libunicorn.a" });
    b.root.root_dir.handle.access(b.graph.io, lib, .{}) catch
        return .{ .missing = b.fmt("{s} is missing; run scripts/fetch.sh unicorn", .{lib}) };
    const wf = b.addWriteFiles();
    const h = wf.add("unicorn.h", "#include <unicorn/unicorn.h>\n");
    const tc = b.addTranslateC(.{ .root_source_file = h, .target = oracle_target, .optimize = optimize });
    tc.addIncludePath(b.path(b.pathJoin(&.{ dir, "include" })));
    var compat: ?*std.Build.Step.Compile = null;
    if (oracle_target.result.os.tag == .linux and oracle_target.result.cpu.arch == .aarch64) {
        // An archive, not a source file: the root module's objects can reach
        // the linker twice, and archive members don't clash.
        const c = b.addLibrary(.{
            .name = "unicorn_compat",
            .linkage = .static,
            .root_module = b.createModule(.{ .target = oracle_target, .optimize = optimize }),
        });
        c.root_module.addAssemblyFile(b.path("tools/lockstep_compat_aarch64.S"));
        compat = c;
    }
    return .{ .ok = .{ .module = tc.createModule(), .lib = b.path(lib), .compat = compat, .target = oracle_target } };
}

/// Links the oracle's Unicorn into the compile step's root module.
fn linkOracle(c: *std.Build.Step.Compile, o: Oracle) void {
    const m = c.root_module;
    m.link_libc = true;
    m.addObjectFile(o.lib);
    if (o.compat) |compat| m.linkLibrary(compat);
}

/// `git describe --tags --always --dirty` for the source tree, or
/// build.zig.zon's version when that fails (a source tarball).
fn gitVersion(b: *std.Build) []const u8 {
    var code: u8 = 0;
    const out = b.runAllowFail(&.{ "git", "-C", b.root.root_dir.path orelse ".", "describe", "--tags", "--always", "--dirty" }, &code, .ignore) catch
        return zonVersion(b);
    const v = std.mem.trim(u8, out, " \r\n");
    return if (v.len > 0) v else zonVersion(b);
}

/// build.zig.zon's `.version`, read as text so the manifest needs no type.
fn zonVersion(b: *std.Build) []const u8 {
    const zon = b.root.root_dir.handle.readFileAlloc(b.graph.io, "build.zig.zon", b.allocator, .limited(1 << 16)) catch return "unknown";
    const key = ".version = \"";
    const i = std.mem.indexOf(u8, zon, key) orelse return "unknown";
    const rest = zon[i + key.len ..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, '"') orelse return "unknown"];
}

/// The table of src/guest/ (with tests/fixtures/guest with `with_test`)
/// as a generated Zig file, and the number of entries in its bin. A file
/// the tree can't hold fails the build.
fn guestTree(b: *std.Build, with_test: bool) struct { file: std.Build.LazyPath, bin: usize } {
    const io = b.graph.io;
    const wf = b.addWriteFiles();
    var inputs: std.ArrayList(guesttree.Input) = .empty;
    for ([_][]const u8{ "src/guest", "tests/fixtures/guest" }, [_]bool{ true, with_test }) |sub, want| {
        if (!want) continue;
        var dir = b.root.root_dir.handle.openDir(io, sub, .{ .iterate = true }) catch continue;
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

/// The built-in root `#Hroot` serves (design/epoch-0/builtin-root.md), as a
/// generated Zig file with its contents embedded beside it: the skeleton,
/// and multicall's tree (`zig build slim`, design/epoch-0/multicall.md) for
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
    // hcpu runs all three on any host.
    if (emu == .hcpu) return &.{ "arm64", "amd64", "386" };
    if (native) |n| return if (std.mem.eql(u8, n, "arm64")) &.{"arm64"} else &.{"amd64"};
    return &.{};
}

/// drawterm's kern and the libraries it uses, as a static library for
/// `target`. `web` builds it for the web host
/// (design/epoch-0/browser-host.md): wasm32-wasi, with src/kern/os-wasm.c in
/// place of posix.c, the coroutines it runs on (src/web/coro.c), and
/// setjmp/longjmp on wasm exception handling.
fn addKern(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, web: bool, gfx: Gfx, exported: bool) *std.Build.Step.Compile {
    const os = target.result.os.tag;
    const flags: []const []const u8 = if (web) &kern_flags_web else if (os == .windows) &kern_flags_win32 else &kern_flags;
    // The library's root is the kernel's Zig, which exports the C
    // functions of the drawterm files it replaces.
    const kern = b.addLibrary(.{
        .name = if (gfx == .headless and !exported) "kern-headless" else "kern",
        .linkage = .static,
        .root_module = kernPort(b, target, optimize, flags, gfx != .none),
    });
    kern.root_module.addIncludePath(b.path(drawterm));
    kern.root_module.addIncludePath(b.path(drawterm ++ "/include"));
    kern.root_module.addIncludePath(b.path(drawterm ++ "/kern"));
    kern.root_module.addIncludePath(b.path("src/kern")); // fscheck.h and netcheck.h, for devfs and devip
    kern.root_module.addCSourceFiles(.{
        .root = b.path(drawterm ++ "/kern"),
        .files = &kern_sources,
        .flags = flags,
    });
    kern.root_module.addCSourceFiles(.{
        .root = b.path(drawterm ++ "/kern"),
        .files = if (web) &kern_web else if (os == .windows) &kern_win32 else &kern_posix,
        .flags = flags,
    });
    kern.root_module.addCSourceFiles(.{
        .root = b.path("src/kern"),
        .files = &.{ "procshim.c", "devtab.c", "devdup.c", "devoverlay.c", "devsrv.c", "devhtools.c", "fscheck.c", "consx.c", "devshim.c", "werrstr.c", "devdotl.c", "kserve.c" },
        .flags = flags,
    });
    // The Linux ABI (design/epoch-0/linux-personality.md) and its host
    // sockets (design/epoch-0/linux-net.md).
    kern.root_module.addCSourceFiles(.{ .root = b.path("src/kern"), .files = &.{ "linux.c", "devlinux.c" }, .flags = flags });
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
        kern.root_module.addAssemblyFile(b.path("src/web/sjlj_tag.S"));
        // wasi-libc's setjmp/longjmp runtime for wasm exception handling,
        // which Zig's wasi-libc doesn't build.
        kern.root_module.addCSourceFile(.{
            .file = b.graph.path(.zig_lib, "libc/wasi/libc-top-half/musl/src/setjmp/wasm32/rt.c"),
            .flags = &.{ "-mllvm", "-wasm-enable-sjlj" },
        });
        for ([_][]const u8{ "wasi-emulated-signal", "wasi-emulated-process-clocks", "wasi-emulated-mman", "wasi-emulated-getpid" }) |l|
            kern.root_module.linkSystemLibrary(l, .{});
    } else kern.root_module.addCSourceFiles(.{
        .root = b.path(drawterm ++ "/posix-port"),
        .files = &kern_port,
        .flags = flags,
    });
    return kern;
}

/// The kernel's Zig (design/kernel-port.md): src/kern/port.zig, the root
/// of the drawterm files ported so far, with the C kernel's types
/// translated from src/kern/port.h under the same macros as the C files
/// it's linked with (`flags`), so the two agree on every layout.
fn kernPort(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, flags: []const []const u8, gfx: bool) *std.Build.Module {
    const tc = b.addTranslateC(.{ .root_source_file = b.path("src/kern/port.h"), .target = target, .optimize = optimize });
    // On the web, wasi-libc's setjmp.h (for Label) wants exception
    // handling, which the C kernel is built with (webTarget) and
    // translate-c isn't told of; it changes no layout.
    if (target.result.cpu.arch == .wasm32) tc.defineCMacroRaw("__wasm_exception_handling__=1");
    tc.addIncludePath(b.path(drawterm));
    tc.addIncludePath(b.path(drawterm ++ "/include"));
    tc.addIncludePath(b.path(drawterm ++ "/kern"));
    tc.addIncludePath(b.path("src/kern"));
    for (flags) |f| if (std.mem.startsWith(u8, f, "-D")) tc.defineCMacroRaw(f[2..]);
    if (target.result.os.tag == .macos) if (b.graph.environ_map.get("SDKROOT")) |sdk|
        tc.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) });
    // Which kernel the Zig is built into, for the files only one of them
    // has: the namespace kernel leaves out devip, the Linux ABI, and the
    // screen.
    const options = b.addOptions();
    var nskernel = false;
    var hostfs = false;
    for (flags) |f| {
        nskernel = nskernel or std.mem.eql(u8, f, "-DH9_NSKERNEL");
        hostfs = hostfs or std.mem.eql(u8, f, "-DH9_NSKERNEL_HOSTFS");
    }
    options.addOption(bool, "nskernel", nskernel);
    // devfs (#U), which the full kernel always has.
    options.addOption(bool, "hostfs", hostfs or !nskernel);
    // A screen (src/kern/gfx.c and src/kern/dev/gfx.zig), not nogfx.c.
    options.addOption(bool, "gfx", gfx);
    return b.createModule(.{
        .root_source_file = b.path("src/kern/port.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "kern_c", .module = tc.createModule() },
            .{ .name = "kern_options", .module = options.createModule() },
        },
    });
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
fn addWeb(b: *std.Build, optimize: std.lang.Optimize, parts: ModuleParts, gfx: Gfx) Web {
    const target = webTarget(b, false);
    var p = parts;
    p.target = target;
    p.optimize = optimize;
    // h9's own CPUs (`--engine hcpu`). The JIT
    // tier here is the wasm one (src/engine/hcpu/jit/wasm_t1.zig and emit/wasm.zig),
    // not the native code cache, which hcpu leaves out on the web.
    p.emu = .hcpu;
    p.jit = true;
    // The browser runs 386 only (design/epoch-0/builtin-root.md, Open issues: every
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
    // its regions there (src/engine/hcpu/jit/emit/wasm.zig).
    exe.import_table = true;
    // The main coroutine's stack; kernel processes get their own.
    exe.stack_size = 1 << 20;
    exe.rdynamic = true;
    exe.use_lld = true;
    const dir: std.Build.InstallDir = .{ .custom = "web" };
    const all = b.step("web-install", "");
    all.dependOn(&b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = dir } }).step);
    for ([_][]const u8{ "h9-web.js", "h9-node", "worker.js", "wasi-mem.js", "statictree.js", "index.html", "package.json" }) |f|
        all.dependOn(&b.addInstallFileWithDir(b.path(b.pathJoin(&.{ "src/web", f })), dir, f).step);
    return .{ .exe = exe, .install = all };
}

// The namespace kernel (design/epoch-0/namespace-kernel.md): drawterm's channels,
// mount tables, devmnt and these devices, and nothing for running
// programs. src/kern/nstab.c is its device table and stands in for what
// the left-out files would define.
const nskern_sources = [_][]const u8{
    "alloc.c", "data.c", "error.c", "parse.c", "stub.c", "waserror.c",
};
const nskern_h9 = [_][]const u8{
    "procshim.c",   "nstab.c",   "devoverlay.c", "devsrv.c",
    "devdotl.c",    "kserve.c",  "devshim.c",    "werrstr.c",
};
// libc's files the kernel subset uses, from kern_libs' list.
const nskern_libc_skip = [_][]const u8{ "pushssl.c", "pushtls.c", "crypt.c", "dial.c" };

/// The namespace kernel for `target`: natively a static library with the
/// C API in src/nskernel/h9ns.h, and for wasm32-wasi h9ns.wasm, run by
/// h9ns.js in a Worker. `hostfs` keeps devfs (#U) natively.
fn addNsKernel(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, web: bool, hostfs: bool) struct { artifact: *std.Build.Step.Compile, mod: *std.Build.Module, port: *std.Build.Module } {
    const options = b.addOptions();
    options.addOption(bool, "kern", true);
    options.addOption(bool, "nskernel", true);
    const root = b.createModule(.{
        .root_source_file = b.path("src/nskernel.zig"),
        .target = if (web) webTarget(b, false) else target,
        .optimize = optimize,
        .link_libc = true,
    });
    root.addOptions("build_options", options);
    // On the web the C kernel turns on wasm exception handling, for
    // setjmp and longjmp, which wasi-libc doesn't build with (webTarget),
    // so it's a library of its own; natively it's in the one archive.
    const m = if (web) blk: {
        const kern = b.addLibrary(.{
            .name = "h9ns-kern",
            .linkage = .static,
            .root_module = b.createModule(.{ .target = webTarget(b, true), .optimize = optimize, .link_libc = true }),
        });
        root.linkLibrary(kern);
        break :blk kern.root_module;
    } else root;
    m.addIncludePath(b.path(drawterm));
    m.addIncludePath(b.path(drawterm ++ "/include"));
    m.addIncludePath(b.path(drawterm ++ "/kern"));
    m.addIncludePath(b.path("src/kern"));
    const windows = !web and target.result.os.tag == .windows;
    const base: []const []const u8 = if (web) &kern_flags_web else if (windows) &kern_flags_win32 else &kern_flags;
    const extra: []const []const u8 = if (hostfs and !web) &.{ "-DH9_NSKERNEL", "-DH9_NSKERNEL_HOSTFS" } else &.{"-DH9_NSKERNEL"};
    const flags = std.mem.concat(b.allocator, []const u8, &.{ base, extra }) catch @panic("OOM");
    // The kernel's Zig (src/kern/port.zig), which src/nskernel.zig
    // imports.
    const port = kernPort(b, root.resolved_target.?, optimize, flags, false);
    root.addImport("kern_port", port);
    m.addCSourceFiles(.{ .root = b.path(drawterm ++ "/kern"), .files = &nskern_sources, .flags = flags });
    m.addCSourceFiles(.{ .root = b.path("src/kern"), .files = &nskern_h9, .flags = flags });
    var libc: std.ArrayList([]const u8) = .empty;
    for (kern_libs[0].files) |f| {
        for (nskern_libc_skip) |skip| {
            if (std.mem.eql(u8, f, skip)) break;
        } else libc.append(b.allocator, f) catch @panic("OOM");
    }
    m.addCSourceFiles(.{ .root = b.path(drawterm ++ "/libc"), .files = libc.items, .flags = flags });
    // Zig's bundled memccpy, musl's and wasi-libc's, is broken; see
    // src/kern/memccpy.c.
    if (web or target.result.abi.isMusl()) {
        m.addCSourceFiles(.{ .root = b.path("src/kern"), .files = &.{"memccpy.c"}, .flags = flags });
        m.addCMacro("memccpy", "h9_memccpy");
    }
    if (web) {
        m.addCSourceFiles(.{ .root = b.path(drawterm ++ "/posix-port"), .files = &.{"tas.c"}, .flags = flags });
        m.addCSourceFiles(.{ .root = b.path("src/kern"), .files = &.{"os-wasm.c"}, .flags = flags });
        m.addCSourceFiles(.{ .root = b.path("src/web"), .files = &.{"coro.c"}, .flags = flags });
        m.addAssemblyFile(b.path("src/web/stack.S"));
        m.addAssemblyFile(b.path("src/web/sjlj_tag.S"));
        m.addCSourceFile(.{
            .file = b.graph.path(.zig_lib, "libc/wasi/libc-top-half/musl/src/setjmp/wasm32/rt.c"),
            .flags = &.{ "-mllvm", "-wasm-enable-sjlj" },
        });
        for ([_][]const u8{ "wasi-emulated-signal", "wasi-emulated-process-clocks", "wasi-emulated-mman", "wasi-emulated-getpid" }) |l|
            m.linkSystemLibrary(l, .{});
    } else if (windows) {
        // As the kern library builds for Windows (addKern): drawterm's
        // win32.c and h9's host lock and timers in glue-win32.c, with no
        // host sockets (src/nskernel.zig has h9so_errstr).
        m.addCSourceFiles(.{ .root = b.path(drawterm ++ "/kern"), .files = &.{ "win32.c", "devlfd-win32.c" }, .flags = flags });
        m.addCSourceFiles(.{ .root = b.path("src/kern"), .files = &.{"glue-win32.c"}, .flags = flags });
        if (hostfs) {
            m.addCSourceFiles(.{ .root = b.path(drawterm ++ "/kern"), .files = &.{"devfs-win32.c"}, .flags = flags });
            m.addCSourceFiles(.{ .root = b.path("src/kern"), .files = &.{"fscheck.c"}, .flags = flags });
        }
        m.addCSourceFiles(.{ .root = b.path(drawterm ++ "/posix-port"), .files = &kern_port, .flags = flags });
        m.linkSystemLibrary("ws2_32", .{});
        m.linkSystemLibrary("advapi32", .{});
    } else {
        m.addCSourceFiles(.{ .root = b.path(drawterm ++ "/kern"), .files = &.{ "posix.c", "devlfd-posix.c" }, .flags = flags });
        if (hostfs) {
            m.addCSourceFiles(.{ .root = b.path(drawterm ++ "/kern"), .files = &.{"devfs-posix.c"}, .flags = flags });
            m.addCSourceFiles(.{ .root = b.path("src/kern"), .files = &.{"fscheck.c"}, .flags = flags });
        }
        m.addCSourceFiles(.{ .root = b.path(drawterm ++ "/posix-port"), .files = &kern_port, .flags = flags });
        if (target.result.os.tag == .macos) addSdkPaths(b, m);
    }
    if (web) {
        const exe = b.addExecutable(.{ .name = "h9ns", .root_module = root });
        exe.import_memory = true;
        exe.stack_size = 1 << 20;
        exe.rdynamic = true;
        exe.use_lld = true;
        return .{ .artifact = exe, .mod = root, .port = port };
    }
    return .{ .artifact = b.addLibrary(.{ .name = "h9ns", .linkage = .static, .root_module = root }), .mod = root, .port = port };
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
                    .optimize = .fast,
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
            const bin = b.addObjCopy(exe.getEmittedBin(), .{ .format = .binary }).getOutput();
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

/// The GUI backend behind --gfx (design/epoch-0/gfx.md), from -Dgfx.
pub const Gfx = enum {
    /// No screen: src/kern/nogfx.c, and --gfx fails with GfxNotBuilt.
    none,
    /// Only the screen in memory (src/kern/gfx-headless.c,
    /// design/epoch-0/headless-screen.md): --gfx=headless, and no window. The
    /// window backends below link it too.
    headless,
    /// drawterm's gui-x11, against a glibc target and the system's libX11.
    x11,
    /// drawterm's gui-win32.
    win32,
    /// drawterm's gui-cocoa, built with the macOS SDK.
    cocoa,
    /// A page's canvas, on the web host (src/kern/gfx-web.c,
    /// design/epoch-0/browser-gfx.md).
    web,

    fn default(t: std.Target) Gfx {
        return switch (t.os.tag) {
            .macos => .cocoa,
            .windows => .win32,
            .wasi => .web,
            // Static Linux builds can't have a window, but can have the
            // headless screen (design/epoch-0/headless-screen.md).
            else => .headless,
        };
    }

    /// Why this backend can't be built for `t`, if it can't.
    fn unsupported(g: Gfx, t: std.Target) ?[]const u8 {
        return switch (g) {
            .none, .headless => null,
            .cocoa => if (t.os.tag != .macos) "Cocoa is macOS only" else null,
            .win32 => if (t.os.tag != .windows) "Win32 is Windows only" else null,
            .x11 => if (t.os.tag != .linux) "X11 is built for Linux only" else if (t.abi.isMusl()) "X11 needs a glibc target, such as -Dtarget=x86_64-linux-gnu, to link the system's libX11" else null,
            .web => if (t.os.tag != .wasi) "web is the web host's backend (zig build web)" else null,
        };
    }
};

/// What every h9 module shares; `addH9Module` makes one per GUI backend.
const ModuleParts = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    emu: Emu,
    /// With hcpu: build the JIT tier, not just the interpreter.
    jit: bool,
    /// With hcpu: run every region through the T1-against-T0 check
    /// (src/engine/hcpu/jit/check/engine.zig).
    jit_check: bool,
    /// With hcpu: ir.verify each region after lifting and after opt
    /// (opt.verify), even where the hcpu module has no runtime safety.
    jit_verify: bool,
    /// How src/engine/hcpu/interp/ and src/engine/hcpu/jit/ (the hcpu module) are optimized.
    hcpu_optimize: std.lang.Optimize,
    shim: std.Build.LazyPath,
    shim_amd64: std.Build.LazyPath,
    /// The sud engine's stub, for Linux x86_64 hosts.
    sud_stub: std.Build.LazyPath,
    guest_tree: std.Build.LazyPath,
    /// The built-in root (design/epoch-0/builtin-root.md).
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
    // The emulator's CPUs (src/engine/hcpu/hcpu.zig), as a module of their own, so
    // they can be optimized when the rest of h9 isn't.
    mod.addImport("hcpu", b.createModule(.{
        .root_source_file = b.path("src/engine/hcpu/hcpu.zig"),
        .target = target,
        .optimize = p.hcpu_optimize,
    }));
    mod.addAnonymousImport("shim_arm64", .{ .root_source_file = p.shim });
    mod.addAnonymousImport("shim_amd64", .{ .root_source_file = p.shim_amd64 });
    if (os == .linux and target.result.cpu.arch == .x86_64)
        mod.addAnonymousImport("sud_stub", .{ .root_source_file = p.sud_stub });

    const web = os == .wasi;
    // The web host's kern turns on wasm exception handling, for setjmp
    // and longjmp.
    const kern = addKern(b, if (web) webTarget(b, true) else target, optimize, web, gfx, exported);
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
    // The headless screen (design/epoch-0/headless-screen.md) is linked into every
    // native build with graphics, beside the window backend if there is
    // one; src/kern/gfx.c calls one or the other per machine.
    if (gfx != .web) {
        m.addCMacro("H9_GFX_HEADLESS", "1");
        m.addCSourceFiles(.{ .root = b.path("src/kern"), .files = &.{"gfx-headless.c"}, .flags = flags });
    }
    if (gfx != .web and gfx != .headless) m.addCMacro("H9_GFX_WINDOW", "1");
    const gui = std.mem.concat(b.allocator, []const u8, &.{ flags, &.{ "-include", pathFromRoot(b, "src/kern/gfx-gui.h") } }) catch @panic("OOM");
    const gui_exit = std.mem.concat(b.allocator, []const u8, &.{ gui, &.{"-DH9_GUI_EXIT"} }) catch @panic("OOM");
    switch (gfx) {
        .none => unreachable,
        .headless => {},
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
    // This file reads what's on disk while it configures: the pins, the
    // proposals, the roots and tools under .local, and which programs are
    // on PATH. Zig can't track all of that, so the configuration isn't
    // cached between runs.
    b.graph.poisonCache();
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os = target.result.os.tag;
    // hcpu is built in wherever it has a JIT, arm64 and x86-64 hosts, so
    // `auto` falls back to it without a hypervisor (design/epoch-0/hcpu.md). There's
    // no option to pick another emulator (design/epoch-0/retire-unicorn.md); -Demu
    // and -Dunicorn are kept only to say so.
    const emu = emuFor(target.result);
    for ([_][]const u8{ "emu", "unicorn" }) |gone| {
        if (b.option([]const u8, gone, "Removed: hcpu is always built in (design/epoch-0/retire-unicorn.md)") != null)
            b.getInstallStep().dependOn(&b.addFail(b.fmt("-D{s} is gone: hcpu, h9's own emulator, is always built in, and Unicorn is only zig build lockstep's oracle (design/epoch-0/retire-unicorn.md)", .{gone})).step);
    }
    // T0 in a Debug build runs several times slower than in a release one,
    // enough for long integration cases to time out.
    const hcpu_debug = b.option(bool, "hcpu-debug", "Build src/engine/hcpu/interp and src/engine/hcpu/jit with -Doptimize too, not ReleaseFast, in Debug builds (for debugging the emulator's CPUs)") orelse false;
    const hcpu_optimize: std.lang.Optimize = if (optimize == .debug and !hcpu_debug) .fast else optimize;
    const jit_check = b.option(bool, "jit-check", "Check every region against T0 as it runs (slow; for zig build integration)") orelse false;
    const jit_verify = b.option(bool, "jit-verify", "Verify every region after lifting and after opt, panicking on a bad one (default: on in Debug and ReleaseSafe builds)") orelse
        (optimize == .debug or optimize == .safe);
    const no_jit = b.option(bool, "no-jit", "The emulator's interpreter tier only, as on hosts that forbid generated code") orelse false;

    const gfx_opt = b.option(Gfx, "gfx", "GUI backend for --gfx (design/epoch-0/gfx.md): cocoa, win32, x11, web, headless (only --gfx=headless) or none (default: cocoa on macOS, win32 on Windows, web for zig build web, headless elsewhere); the window backends also link the headless screen");
    const gfx = gfx_opt orelse Gfx.default(target.result);
    // zig build web's: web, the web host's only GUI backend, unless
    // -Dgfx=none leaves graphics out (design/epoch-0/browser-gfx.md).
    const web_gfx: Gfx = if (gfx_opt == .none) .none else .web;
    if (gfx.unsupported(target.result)) |why| b.getInstallStep().dependOn(&b.addFail(b.fmt("-Dgfx={t}: {s}", .{ gfx, why })).step);

    // The arm64 guest shim, assembled freestanding and embedded as raw bytes.
    const shim_obj = b.addObject(.{
        .name = "shim_arm64",
        .root_module = b.createModule(.{
            .target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .freestanding }),
            .optimize = .small,
        }),
    });
    shim_obj.root_module.addAssemblyFile(b.path("src/arch/arm64/shim.S"));
    const shim_bin = b.addObjCopy(shim_obj.getEmittedBin(), .{ .format = .binary, .only_section = ".text" });
    // The amd64 shim, for KVM on x86_64 (design/epoch-0/kvm.md).
    const shim_amd64_obj = b.addObject(.{
        .name = "shim_amd64",
        .root_module = b.createModule(.{
            .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .freestanding }),
            .optimize = .small,
        }),
    });
    shim_amd64_obj.root_module.addAssemblyFile(b.path("src/arch/amd64/shim.S"));
    const shim_amd64_bin = b.addObjCopy(shim_amd64_obj.getEmittedBin(), .{ .format = .binary, .only_section = ".text" });

    // The sud engine's stub (design/epoch-0/native-backend.md): a freestanding
    // static program, linked high so the guest's whole layout is free, and
    // embedded in h9.
    const sud_stub = b.addExecutable(.{
        .name = "h9-stub",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/engine/sud_stub.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .none }),
            .optimize = .small,
            .single_threaded = true,
            .strip = true,
            .pic = false,
            .code_model = .large,
        }),
    });
    sud_stub.pie = false;
    sud_stub.image_base = 0x6000_0000_0000; // sud_abi.stub_base

    const kern_step = b.step("kern", "Compile drawterm's kern");
    const have_drawterm = if (b.root.root_dir.handle.access(b.graph.io, drawterm ++ "/kern/sysfile.c", .{})) true else |_| false;

    // h9's own guest commands, served by #H (design/epoch-0/guest-tools.md).
    // Debug builds also serve tests/fixtures/guest, for the integration
    // cases; release builds leave it out.
    const guest_test = b.option(bool, "guest-test", "Serve tests/fixtures/guest in #H too, for the integration cases (default: in Debug builds)") orelse (optimize == .debug);
    const guest_tree = guestTree(b, guest_test);

    // For --version: scripts/release.sh passes -Dversion; otherwise git
    // describe, or build.zig.zon's version where there's no git checkout.
    const version = b.option([]const u8, "version", "Version h9 --version reports (default: git describe, else build.zig.zon's)") orelse gitVersion(b);
    const pins = b.root.root_dir.handle.readFileAlloc(b.graph.io, "scripts/pins.sh", b.allocator, .limited(1 << 16)) catch "";

    // The built-in root (design/epoch-0/builtin-root.md): multicall's trees for
    // the architectures this build runs, from `zig build slim`. A release
    // fails without them; a development build gets the skeleton only.
    const builtin_dir = b.option([]const u8, "builtin-root", "Directory of zig build slim's trees for the built-in root (default .local/9front)") orelse
        pathFromRoot(b, ".local/9front");
    const release_build = b.option(bool, "release", "A release build: fail if the built-in root is missing an architecture's commands (design/epoch-0/builtin-root.md)") orelse false;
    const builtin_root = builtinRoot(b, builtin_dir, pin(pins, "NINEFRONT_RELEASE"), builtinArches(target.result, emu), if (release_build) .required else .warn);

    const parts: ModuleParts = .{
        .target = target,
        .optimize = optimize,
        .emu = emu,
        .jit = !no_jit,
        .jit_check = jit_check,
        .jit_verify = jit_verify,
        .hcpu_optimize = hcpu_optimize,
        .shim = shim_bin.getOutput(),
        .shim_amd64 = shim_amd64_bin.getOutput(),
        .sud_stub = sud_stub.getEmittedBin(),
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
    // The tests' module, with the headless screen for the [gfx] cases:
    // the -Dgfx build's own when it has one (design/epoch-0/headless-screen.md),
    // so a window backend's build runs them beside its window.
    const test_mod = if (gfx != .none and gfx != .web) mod else addH9Module(b, parts, .headless, false);

    // The web host (design/epoch-0/browser-host.md): h9 for wasm32-wasi
    // with its JS host and a demo page, in zig-out/web.
    const web_step = b.step("web", "Build the web host into zig-out/web (design/epoch-0/browser-host.md)");
    const web = addWeb(b, optimize, parts, web_gfx);
    web_step.dependOn(web.install);
    // The demo page's root archive, from a 386 root tree and the paths
    // src/web/root.list names; left out without one.
    const web_root = b.option([]const u8, "web-root", "386 root tree for the web host's root archive (default .local/9front/root386)") orelse
        pathFromRoot(b, ".local/9front/root386");
    if (std.Io.Dir.cwd().access(b.graph.io, b.pathJoin(&.{ web_root, "386/bin/rc" }), .{})) {
        const webroot = b.addExecutable(.{
            .name = "webroot",
            .root_module = b.createModule(.{ .root_source_file = b.path("tools/webroot.zig"), .target = b.graph.host, .optimize = .safe }),
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
    const web_linux_root = b.option([]const u8, "web-linux-root", "arm64 Linux root tree for the web host's Linux archive (default .local/linux/alpine-arm64-web)") orelse
        pathFromRoot(b, ".local/linux/alpine-arm64-web");
    if (std.Io.Dir.cwd().access(b.graph.io, b.pathJoin(&.{ web_linux_root, "bin/busybox" }), .{})) {
        const webroot = b.addExecutable(.{
            .name = "webroot",
            .root_module = b.createModule(.{ .root_source_file = b.path("tools/webroot.zig"), .target = b.graph.host, .optimize = .safe }),
        });
        const mk = b.addRunArtifact(webroot);
        mk.addArg(web_linux_root);
        mk.addFileArg(b.path("src/web/linux.list"));
        const archive = mk.addOutputFileArg("linux.h9a");
        web.install.dependOn(&b.addInstallFileWithDir(archive, .{ .custom = "web" }, "linux.h9a").step);
    } else |_| {}
    // The 9front layer ?linux puts at /9 (nine-arm64.h9a), from the arm64
    // slim root `zig build slim -Darch=arm64` makes and
    // src/web/nine-arm64.list, so a Linux program there has rc and
    // wsmount; left out without one.
    const web_nine_root = b.option([]const u8, "web-nine-arm64-root", "arm64 9front root tree for ?linux's 9front layer (default .local/9front/slim-<release>-arm64)") orelse
        pathFromRoot(b, b.fmt(".local/9front/slim-{s}-arm64", .{pin(pins, "NINEFRONT_RELEASE")}));
    if (std.Io.Dir.cwd().access(b.graph.io, b.pathJoin(&.{ web_nine_root, "arm64/bin/rc" }), .{})) {
        const webroot = b.addExecutable(.{
            .name = "webroot",
            .root_module = b.createModule(.{ .root_source_file = b.path("tools/webroot.zig"), .target = b.graph.host, .optimize = .safe }),
        });
        const mk = b.addRunArtifact(webroot);
        mk.addArg(web_nine_root);
        mk.addFileArg(b.path("src/web/nine-arm64.list"));
        const archive = mk.addOutputFileArg("nine-arm64.h9a");
        web.install.dependOn(&b.addInstallFileWithDir(archive, .{ .custom = "web" }, "nine-arm64.h9a").step);
    } else |_| {}
    // The demo page in Chromium through Playwright (tests/web/browser.mjs).
    const web_test = b.addSystemCommand(&.{ "node", "tests/web/browser.mjs" });
    web_test.addDirectoryArg2(b.graph.path(.install_prefix, "web"), .{ .make_absolute = true });
    web_test.setCwd(b.path("."));
    web_test.has_side_effects = true;
    web_test.expectExitCode(0);
    web_test.step.dependOn(web.install);
    // Graphics on the canvas (tests/web/gfx.mjs, design/epoch-0/browser-gfx.md).
    const web_gfx_test = b.addSystemCommand(&.{ "node", "tests/web/gfx.mjs" });
    web_gfx_test.addDirectoryArg2(b.graph.path(.install_prefix, "web"), .{ .make_absolute = true });
    web_gfx_test.setCwd(b.path("."));
    web_gfx_test.has_side_effects = true;
    web_gfx_test.expectExitCode(0);
    web_gfx_test.step.dependOn(web.install);
    const web_test_step = b.step("web-test", "Run the web host's demo page, its canvas cases, and the namespace kernel's machine cases in Chromium with Playwright (needs a 386 root for root.h9a)");
    web_test_step.dependOn(&web_test.step);

    // The namespace kernel (design/epoch-0/namespace-kernel.md): h9ns.wasm and its
    // JS host, and libh9ns.a with h9ns.h, in zig-out/nskernel.
    const ns_hostfs = b.option(bool, "nskernel-hostfs", "Keep devfs (#U) in the native namespace kernel, for embedders that lend host directories") orelse false;
    const ns_step = b.step("nskernel", "Build the namespace kernel into zig-out/nskernel (design/epoch-0/namespace-kernel.md)");
    const ns_dir: std.Build.InstallDir = .{ .custom = "nskernel" };
    const ns_web = addNsKernel(b, webTarget(b, false), optimize, true, false).artifact;
    ns_step.dependOn(&b.addInstallArtifact(ns_web, .{ .dest_dir = .{ .override = ns_dir } }).step);
    for ([_][]const u8{ "h9ns.js", "h9ns-worker.js" }) |f|
        ns_step.dependOn(&b.addInstallFileWithDir(b.path(b.pathJoin(&.{ "src/web", f })), ns_dir, f).step);
    for ([_][]const u8{ "h9-web.js", "wasi-mem.js", "statictree.js" }) |f|
        ns_step.dependOn(&b.addInstallFileWithDir(b.path(b.pathJoin(&.{ "src/web", f })), ns_dir, f).step);
    const ns_lib = addNsKernel(b, target, optimize, false, ns_hostfs);
    ns_step.dependOn(&b.addInstallArtifact(ns_lib.artifact, .{ .dest_dir = .{ .override = ns_dir } }).step);
    ns_step.dependOn(&b.addInstallFileWithDir(b.path("src/nskernel/h9ns.h"), ns_dir, "h9ns.h").step);
    // Its cases: tests/nskernel.zig through the native library, and
    // tests/web/nskernel.mjs through h9ns.wasm under Node.
    const ns_test_step = b.step("nskernel-test", "Run the namespace kernel's cases, natively and under Node (design/epoch-0/namespace-kernel.md)");
    const ns_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/nskernel.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "h9ns", .module = ns_lib.mod },
        },
    }) });
    ns_test_step.dependOn(&b.addRunArtifact(ns_tests).step);
    // The kernel's Zig's own cases (src/kern/*.zig), on the
    // native namespace kernel, which they import for its C and the boot.
    const kport_ns = addNsKernel(b, target, optimize, false, false);
    kport_ns.port.addImport("h9ns", kport_ns.mod);
    const kport_tests = b.addTest(.{ .name = "kern-port", .root_module = kport_ns.port });
    const kern_test_step = b.step("kern-test", "Run the kernel's Zig cases (src/kern/*.zig, design/kernel-port.md)");
    kern_test_step.dependOn(&b.addRunArtifact(kport_tests).step);
    const ns_node = b.addSystemCommand(&.{ "node", "tests/web/nskernel.mjs" });
    ns_node.addDirectoryArg2(b.graph.path(.install_prefix, "nskernel"), .{ .make_absolute = true });
    ns_node.setCwd(b.path("."));
    ns_node.has_side_effects = true;
    ns_node.expectExitCode(0);
    ns_node.step.dependOn(ns_step);
    ns_test_step.dependOn(&ns_node.step);
    // With an h9 machine in Chromium (tests/web/nskernel-browser.mjs), which
    // needs the web build and its 386 root: run with web-test.
    const ns_browser = b.addSystemCommand(&.{ "node", "tests/web/nskernel-browser.mjs" });
    ns_browser.addDirectoryArg2(b.graph.path(.install_prefix, "nskernel"), .{ .make_absolute = true });
    ns_browser.addDirectoryArg2(b.graph.path(.install_prefix, "web"), .{ .make_absolute = true });
    ns_browser.setCwd(b.path("."));
    ns_browser.has_side_effects = true;
    ns_browser.expectExitCode(0);
    ns_browser.step.dependOn(ns_step);
    ns_browser.step.dependOn(web.install);
    web_test_step.dependOn(&ns_browser.step);
    if (web_gfx != .none) web_test_step.dependOn(&web_gfx_test.step);

    const exe = b.addExecutable(.{
        .name = "h9",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "h9", .module = mod.mod },
                // --check runs the hello fixture on each engine.
                .{ .name = "hello", .module = b.createModule(.{ .root_source_file = b.path("tests/fixtures/hello.zig"), .target = target }) },
            },
        }),
    });
    if (os == .macos) {
        addSdkPaths(b, exe.root_module);
        exe.root_module.linkFramework("Hypervisor", .{});
    }

    const install_exe = b.addInstallArtifact(exe, .{});
    // The installed h9, which the demos, cases, and tools run.
    const h9 = b.graph.path(.install_bin, exe.out_filename);
    b.getInstallStep().dependOn(&install_exe.step);

    // HVF refuses hv_vm_create without the hypervisor entitlement.
    var signed_step = &install_exe.step;
    if (os == .macos and b.graph.host.result.os.tag == .macos) {
        const sign = b.addSystemCommand(&.{ "codesign", "--force", "--sign", "-", "--entitlements" });
        sign.addFileArg(b.path("h9.entitlements"));
        sign.addFileArg(h9);
        sign.step.dependOn(&install_exe.step);
        b.getInstallStep().dependOn(&sign.step);
        signed_step = &sign.step;
    }

    const run_cmd = runH9(b, h9, signed_step, &.{});
    run_cmd.addPassthruArgs();
    b.step("run", "Run h9").dependOn(&run_cmd.step);

    // Fixed paths, not the install prefix, so `--prefix /usr/local clean` can't remove it.
    const clean_cmd = b.addSystemCommand(&.{ "rm", "-rf", pathFromRoot(b, "zig-out"), pathFromRoot(b, ".zig-cache") });
    b.step("clean", "Remove zig-out and .zig-cache").dependOn(&clean_cmd.step);

    // Fixtures: hand-assembled hello a.outs for arm64 and amd64.
    const mkhello = b.addExecutable(.{
        .name = "mkhello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fixtures/mkhello.zig"),
            .target = b.graph.host,
            .imports = &.{
                .{ .name = "aout", .module = b.createModule(.{ .root_source_file = b.path("src/abi/plan9/aout.zig"), .target = b.graph.host }) },
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

    // Linux fixtures (tests/fixtures/linux, design/epoch-0/linux-personality.md):
    // static musl programs for arm64, amd64, and 386, in fixtures/linux/<arch>.
    const linux_fixtures = b.step("linux-fixtures", "Build the Linux fixtures in tests/fixtures/linux (static musl, arm64, amd64, and 386)");
    for ([_][]const u8{ "arm64", "amd64", "386" }, [_]std.Target.Cpu.Arch{ .aarch64, .x86_64, .x86 }) |arch, cpu| {
        const lt = b.resolveTargetQuery(.{ .cpu_arch = cpu, .os_tag = .linux, .abi = .musl });
        for (linux_fixture_names) |name| {
            const m = b.createModule(.{ .target = lt, .optimize = .small, .link_libc = true });
            m.addCSourceFile(.{ .file = b.path(b.fmt("tests/fixtures/linux/{s}.c", .{name})), .flags = &.{ "-std=c11", "-D_GNU_SOURCE" } });
            const fx = b.addExecutable(.{ .name = name, .root_module = m, .linkage = .static });
            // Segments aligned to 64K on every architecture, as arm64's
            // linkers align them by default, so the [cow-fork] sharing
            // case's blob sits at its offset's place in h9's chunks
            // (src/abi/linux/pagecache.zig) on amd64 too.
            if (std.mem.eql(u8, name, "bigexe")) fx.link_z_max_page_size = 64 << 10;
            const inst = b.addInstallArtifact(fx, .{ .dest_dir = .{ .override = .{ .custom = b.fmt("fixtures/linux/{s}", .{arch}) } } });
            linux_fixtures.dependOn(&inst.step);
        }
    }
    b.getInstallStep().dependOn(linux_fixtures);

    // Proposal demos that aren't integration cases, by the proposal's slug;
    // `zig build proposal -Dp=...` runs them along with its tagged cases.
    var demos: std.StringHashMapUnmanaged(std.ArrayList(*std.Build.Step)) = .empty;
    addWebCases(b, &demos, "tests/web/browser.mjs", &web_test.step);
    addWebCases(b, &demos, "tests/web/nskernel.mjs", &ns_node.step);
    addWebCases(b, &demos, "tests/web/nskernel-browser.mjs", &ns_browser.step);
    if (web_gfx != .none) addWebCases(b, &demos, "tests/web/gfx.mjs", &web_gfx_test.step);

    // Baseline demos: the host architecture's hello on the default engine,
    // and on the emulator when it's built in.
    const host_hello = if (target.result.cpu.arch == .x86_64) hellos[1] else hellos[0];
    const hello_demo = runH9(b, h9, signed_step, &.{});
    hello_demo.addFileArg(host_hello);
    hello_demo.expectStdOutEqual("hello\n");
    hello_demo.step.dependOn(signed_step);
    addDemo(b, &demos, "baseline", &hello_demo.step);
    if (emu != .none) {
        const emu_demo = runH9(b, h9, signed_step, &.{ "--engine", "hcpu" });
        emu_demo.addFileArg(host_hello);
        emu_demo.expectStdOutEqual("hello\n");
        emu_demo.step.dependOn(signed_step);
        addDemo(b, &demos, "baseline", &emu_demo.step);
        // 386 runs on the emulator on every host.
        const i386_demo = runH9(b, h9, signed_step, &.{ "--engine", "hcpu" });
        i386_demo.addFileArg(hellos[2]);
        i386_demo.expectStdOutEqual("hello\n");
        i386_demo.step.dependOn(signed_step);
        addDemo(b, &demos, "i386", &i386_demo.step);
    }

    // The rest run real 9front binaries from a host root tree, so they're
    // left out without one, as the integration cases skip.
    const root = b.option([]const u8, "root", "9front root tree for the demos and integration tests (default .local/9front/root)") orelse
        pathFromRoot(b, ".local/9front/root");
    // The self-host demos and cases need /sys/src: the root's (zig build
    // mkroot -- --src), or else this checkout's, which scripts/fetch.sh makes at the
    // root's revision.
    const src_dir: ?[]const u8 = b.option([]const u8, "src", "9front source's sys directory for the self-host cases when the root has no /sys/src (default .local/src/9front/sys)") orelse blk: {
        const d = pathFromRoot(b, ".local/src/9front/sys");
        b.root.root_dir.handle.access(b.graph.io, ".local/src/9front/sys/src", .{}) catch break :blk null;
        break :blk d;
    };

    if (b.root.root_dir.handle.readFileAlloc(b.graph.io, b.pathJoin(&.{ root, "lib/namespace" }), b.allocator, .limited(1 << 20))) |namespace| {
        const cat_demo = runH9(b, h9, signed_step, &.{ "--dir", root, "/bin/cat", "/lib/namespace" });
        cat_demo.expectStdOutEqual(namespace);
        cat_demo.step.dependOn(signed_step);
        addDemo(b, &demos, "baseline", &cat_demo.step);
        // The tight profile's cwd is read-only, so rc's redirection fails. The
        // cwd is a fresh directory, so nothing is left behind if it doesn't.
        const tight_cwd = b.addWriteFiles();
        _ = tight_cwd.add(".keep", "");
        const tight_demo = runH9(b, h9, signed_step, &.{ "--dir", root, "--profile=tight", "--cwd" });
        tight_demo.addDirectoryArg(tight_cwd.getDirectory());
        tight_demo.addArgs(&.{ "--rc", "echo x > /mnt/term/cwd/f" });
        tight_demo.expectExitCode(1);
        tight_demo.expectStdErrMatch("can't create");
        tight_demo.step.dependOn(signed_step);
        addDemo(b, &demos, "baseline", &tight_demo.step);
    } else |_| {}

    // ls prints each member of the /bin union, duplicates and all, so the
    // count is the root's two directories' entries and #H/bin's added
    // together (design/epoch-0/guest-tools.md).
    if (countBin(b, root)) |n| {
        const ls_demo = runH9(b, h9, signed_step, &.{ "--dir", root, "--rc", "ls /bin | wc -l" });
        ls_demo.expectStdOutEqual(b.fmt("{d: >7}\n", .{n + guest_tree.bin}));
        ls_demo.step.dependOn(signed_step);
        addDemo(b, &demos, "baseline", &ls_demo.step);
    }

    // Self-host demos (design/epoch-0/self-host.md), with the root's arm64
    // binaries: they need /sys/src, the root's or `src_dir` bound over
    // /sys.
    const root_src = if (b.root.root_dir.handle.access(b.graph.io, b.pathJoin(&.{ root, "sys/src/cmd/ls.c" }), .{})) |_| true else |_| false;
    if (root_src or src_dir != null) {
        // A scratch cwd unioned before /sys/src/cmd, so mk reads the stock
        // mkfile and source there and writes into the scratch directory,
        // and the symbols name /sys/src/cmd as the shipped binary's do.
        const bind_src = if (root_src) "" else b.fmt("bind -a /mnt/term{s} /sys && ", .{src_dir.?});
        const ls_cwd = b.addWriteFiles();
        _ = ls_cwd.add(".keep", "");
        const ls_build = runH9(b, h9, signed_step, &.{ "--dir", root, "--arch", "arm64", "--timeout", "600s" });
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
        const acid_demo = runH9(b, h9, signed_step, &.{ "--dir", root, "--arch", "arm64", "--timeout", "60s", "--rc", "sleep 5 & sleep 1; acid $apid; echo kill >/proc/$apid/ctl" });
        acid_demo.setStdIn(.{ .bytes = "stk()\n" });
        acid_demo.expectStdOutMatch("main(argv=");
        acid_demo.expectStdOutMatch("/sys/src/cmd/sleep.c:");
        acid_demo.has_side_effects = true;
        acid_demo.step.dependOn(signed_step);
        addDemo(b, &demos, "self-host", &acid_demo.step);
    }

    // Each integration case runs on every engine built in that runs the
    // cases' architecture here. -Darch runs them with another
    // architecture's binaries from the root (/386/bin, /amd64/bin).
    const test_arch = b.option([]const u8, "arch", "Architecture of the root's binaries for the integration cases: arm64, amd64 or 386 (default the host's)");
    const native_arch: ?[]const u8 = switch (target.result.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "amd64",
        else => null,
    };
    const cases_arch = test_arch orelse native_arch orelse "arm64";
    var engines: std.ArrayList(u8) = .empty;
    // A macOS VM has no HVF (kern.hv_support is 0), so h9 can't run there on hvf.
    if (os == .macos and std.mem.eql(u8, cases_arch, "arm64") and target.result.cpu.arch == .aarch64 and
        (b.graph.host.result.os.tag != .macos or hostHasHvf(b)))
        engines.appendSlice(b.allocator, "hvf,") catch @panic("OOM");
    // KVM runs the host's architecture, when this user can open /dev/kvm.
    if (os == .linux and b.graph.host.result.os.tag == .linux and native_arch != null and std.mem.eql(u8, cases_arch, native_arch.?) and
        target.result.cpu.arch == b.graph.host.result.cpu.arch)
    {
        if (std.Io.Dir.accessAbsolute(b.graph.io, "/dev/kvm", .{ .read = true, .write = true })) |_|
            engines.appendSlice(b.allocator, "kvm,") catch @panic("OOM")
        else |_| {}
    }
    // WHP runs amd64 on Windows x86_64, when the Windows Hypervisor Platform
    // feature is on, which is when its DLL is in System32.
    if (os == .windows and b.graph.host.result.os.tag == .windows and target.result.cpu.arch == .x86_64 and
        std.mem.eql(u8, cases_arch, "amd64"))
    {
        if (std.Io.Dir.accessAbsolute(b.graph.io, "C:\\Windows\\System32\\WinHvPlatform.dll", .{})) |_|
            engines.appendSlice(b.allocator, "whp,") catch @panic("OOM")
        else |_| {}
    }
    // The sud engine (design/epoch-0/native-backend.md) runs amd64 on Linux
    // x86_64 when the kernel has Syscall User Dispatch and seccomp; h9
    // skips it where it can't run, as it does an engine that isn't built.
    if (os == .linux and b.graph.host.result.os.tag == .linux and target.result.cpu.arch == .x86_64 and
        b.graph.host.result.cpu.arch == .x86_64 and std.mem.eql(u8, cases_arch, "amd64"))
        engines.appendSlice(b.allocator, "sud,") catch @panic("OOM");
    if (emu != .none) engines.appendSlice(b.allocator, "hcpu,") catch @panic("OOM");
    // -Dengines picks the engines instead, such as only `sud` for a
    // quick run where there's no KVM.
    const want_engines = b.option([]const u8, "engines", "Engines to run the integration cases on, comma-separated (default: every one built in that runs here)");
    // -Dweb runs them on the web host under Node instead: h9-node on h9's
    // own 386 CPU (h86), with the root's 386 binaries
    // (design/epoch-0/browser-host.md), or with -Darch=arm64 on ha64.
    const test_web = b.option(bool, "web", "Run the integration cases on the web host under Node (386, or arm64 with -Darch=arm64)") orelse false;
    const engine_list = if (test_web) want_engines orelse "hcpu" else if (want_engines) |w| w else if (engines.items.len > 0) engines.items else "auto";
    const it: Integration = if (test_web) .{
        .bin = b.graph.path(.install_prefix, "web/h9-node"),
        .arch = test_arch orelse "386",
        .web = true,
        .step = web.install,
        // The native h9 serves the WebSocket cases' roots on the
        // emulator.
        .server = if (emu != .none) h9 else null,
        .server_step = signed_step,
    } else .{ .bin = h9, .arch = test_arch, .web = false, .step = signed_step };

    // Runs real binaries through the h9 CLI; skipped without a root tree.
    // Cases tagged with a proposal that isn't implemented skip unless
    // -Dpending is given.
    const run_pending = b.option(bool, "pending", "Also run integration cases of proposals that aren't implemented yet") orelse false;
    // The Go fixtures run on the emulator, so they're built only with it.
    const go_version = pin(pins, "GO_VERSION");
    const go_bin = b.findProgram(.{ .names = &.{"go"} });
    const go_fixtures: ?GoFixtures = if (go_bin) |g| addGoFixtures(b, g, go_version) else null;
    const go_fixtures_step = b.step("go-fixtures", "Build the Go fixtures in tests/fixtures/go (plan9/amd64, GO_VERSION from scripts/pins.sh)");
    if (go_fixtures) |g| go_fixtures_step.dependOn(g.step) else go_fixtures_step.dependOn(&b.addFail("go-fixtures: no go on PATH").step);
    const go_cases: ?GoFixtures = if (emu != .none or std.mem.indexOf(u8, engine_list, "sud") != null) go_fixtures else null;
    // The Linux Go fixtures (design/epoch-0/linux-threads.md), with the same
    // toolchain, into fixtures/linux/<arch>/go.
    if (go_bin) |g| for ([_][]const u8{ "arm64", "amd64", "386" }) |arch| {
        const run = b.addSystemCommand(&.{ g, "-C", "tests/fixtures/linux/go", "build", "-trimpath", "-o" });
        run.addDirectoryArg2(b.graph.path(.install_prefix, b.fmt("fixtures/linux/{s}/go", .{arch})), .{ .suffix = std.fs.path.sep_str, .make_absolute = true });
        run.addArg("./...");
        run.setCwd(b.path("."));
        goEnv(run, go_version);
        run.setEnvironmentVariable("GOOS", "linux");
        run.setEnvironmentVariable("GOARCH", arch);
        run.has_side_effects = true;
        linux_fixtures.dependOn(&run.step);
    };
    // Go's own tests for time, syscall, os and runtime on the emulator, by
    // hand or on a schedule; nothing depends on it.
    const go_stdtest = b.step("go-stdtest", "Run Go's time, syscall, os and runtime tests on the emulator (needs go)");
    if (emu == .none) {
        go_stdtest.dependOn(&b.addFail("go-stdtest: needs the emulator, which this target doesn't have").step);
    } else {
        const run_stdtest = b.addSystemCommand(&.{ "bash", "scripts/go-stdtest.sh" });
        run_stdtest.addFileArg2(h9, .{ .make_absolute = true });
        run_stdtest.addDirectoryArg2(b.graph.path(.install_prefix, "go-stdtest"), .{ .make_absolute = true });
        run_stdtest.setCwd(b.path("."));
        run_stdtest.addPassthruArgs();
        run_stdtest.has_side_effects = true;
        run_stdtest.stdio = .inherit;
        run_stdtest.step.dependOn(signed_step);
        go_stdtest.dependOn(&run_stdtest.step);
    }
    const it_filters = b.option([]const []const u8, "filter", "Run only the integration cases whose names contain one of these") orelse &.{};
    const it_shards = b.option(u32, "shards", "Split the integration cases across this many runs at once (default 4; 1 runs them in one)") orelse 4;
    const integration_step = b.step("integration", "Run real 9front binaries from the root tree through h9");
    for (addIntegration(b, integration_step, it_shards, optimize, it_filters, it, root, engine_list, run_pending, if (test_web) null else go_cases, guest_test, src_dir)) |run_integration| {
        if (!test_web) run_integration.step.dependOn(linux_fixtures);
        // -Djit-check checks every region against T0, one region at a time
        // across vCPUs: the cases' timeouts stretch (H9_TEST_SLOW, unless it's
        // set already). Eight processes contending for /env need about 40.
        if (jit_check and b.graph.environ_map.get("H9_TEST_SLOW") == null) run_integration.setEnvironmentVariable("H9_TEST_SLOW", "40");
    }

    // The namespace conformance check (design/kernel-port.md,
    // tools/conformance.zig): tests/conformance/ns.rc on h9, on each engine
    // -Dengines picks, against what 9front printed for it
    // (tests/conformance/9front.out). `-- --oracle` records that on 9front
    // under QEMU instead.
    const conformance_tool = b.addExecutable(.{
        .name = "conformance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/conformance.zig"),
            .target = b.graph.host,
        }),
    });
    const run_conformance = b.addRunArtifact(conformance_tool);
    run_conformance.setCwd(b.path("."));
    run_conformance.has_side_effects = true;
    run_conformance.stdio = .inherit;
    run_conformance.addArg("--h9");
    run_conformance.addFileArg2(h9, .{ .make_absolute = true });
    run_conformance.addArgs(&.{ "--root", root, "--engines", engine_list });
    if (test_arch) |a| run_conformance.addArgs(&.{ "--arch", a });
    run_conformance.addPassthruArgs();
    run_conformance.step.dependOn(signed_step);
    b.step("conformance", "Run tests/conformance/ns.rc on h9 and compare it with 9front's transcript; -- --oracle records that under QEMU").dependOn(&run_conformance.step);

    // The workloads (tests/workloads): real programs on real roots, in
    // parallel, timed, by scripts/workloads.sh. Too slow for every PR, so
    // a workflow runs them every two days (.github/workflows/workloads.yml).
    // -Darch and -Dengines pick the roots' architecture and the engine
    // (the first one listed), and arguments after -- pick cases by name.
    const workloads_step = b.step("workloads", "Run the workloads in tests/workloads: real programs on real roots, timed (scripts/fetch.sh workloads for the Linux root)");
    const run_workloads = b.addSystemCommand(&.{ "bash", "scripts/workloads.sh" });
    run_workloads.addFileArg2(h9, .{ .make_absolute = true });
    run_workloads.addDirectoryArg2(b.graph.path(.install_prefix, "workloads"), .{ .make_absolute = true });
    run_workloads.setCwd(b.path("."));
    run_workloads.addPassthruArgs();
    run_workloads.setEnvironmentVariable("H9_WL_ARCH", test_arch orelse switch (target.result.cpu.arch) {
        .x86_64 => "amd64",
        .x86 => "386",
        else => "arm64",
    });
    if (want_engines) |w| run_workloads.setEnvironmentVariable("H9_WL_ENGINE", std.mem.sliceTo(w, ','));
    run_workloads.has_side_effects = true;
    run_workloads.stdio = .inherit;
    run_workloads.step.dependOn(signed_step);
    workloads_step.dependOn(&run_workloads.step);

    // 9box and a slim root around it (design/epoch-0/multicall.md), built inside
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
            .optimize = .safe,
            .imports = &.{
                .{ .name = "a64decode", .module = b.createModule(.{ .root_source_file = b.path("src/engine/hcpu/interp/a64/decode.zig") }) },
                .{ .name = "aout", .module = b.createModule(.{ .root_source_file = b.path("src/abi/plan9/aout.zig") }) },
            },
        }),
    });
    const run_a64inv = b.addRunArtifact(a64inv);
    run_a64inv.has_side_effects = true;
    // The root's binaries unless paths are given after --: the tool
    // decides, since build.zig can't see those arguments.
    run_a64inv.addArgs(&.{ "--default", b.pathJoin(&.{ root, "arm64" }) });
    run_a64inv.addPassthruArgs();
    b.step("a64-inventory", "Report the arm64 instructions in binaries (default: the root tree's arm64): zig build a64-inventory -- PATH...").dependOn(&run_a64inv.step);

    // The 386 instruction inventory over h86's decoder and T0
    // (tools/x86inv.zig): zig build x86-inventory -- PATH...
    const x86inv = b.addExecutable(.{
        .name = "x86inv",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/x86inv.zig"),
            .target = b.graph.host,
            .optimize = .safe,
            .imports = &.{
                .{ .name = "hcpu", .module = b.createModule(.{ .root_source_file = b.path("src/engine/hcpu/hcpu.zig") }) },
                .{ .name = "aout", .module = b.createModule(.{ .root_source_file = b.path("src/abi/plan9/aout.zig") }) },
            },
        }),
    });
    const run_x86inv = b.addRunArtifact(x86inv);
    run_x86inv.has_side_effects = true;
    // The root's binaries unless paths are given after --: the tool
    // decides, since build.zig can't see those arguments.
    run_x86inv.addArgs(&.{ "--default", b.pathJoin(&.{ root, "386" }) });
    run_x86inv.addPassthruArgs();
    b.step("x86-inventory", "Report the 386 instructions in binaries (default: the root tree's 386): zig build x86-inventory -- PATH...").dependOn(&run_x86inv.step);

    // The amd64 instruction inventory over hx64's decoder and T0
    // (tools/x64inv.zig): zig build x64-inventory -- PATH...
    const x64inv = b.addExecutable(.{
        .name = "x64inv",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/x64inv.zig"),
            .target = b.graph.host,
            .optimize = .safe,
            .imports = &.{
                .{ .name = "hcpu", .module = b.createModule(.{ .root_source_file = b.path("src/engine/hcpu/hcpu.zig") }) },
                .{ .name = "aout", .module = b.createModule(.{ .root_source_file = b.path("src/abi/plan9/aout.zig") }) },
            },
        }),
    });
    const run_x64inv = b.addRunArtifact(x64inv);
    run_x64inv.has_side_effects = true;
    // The root's binaries unless paths are given after --: the tool
    // decides, since build.zig can't see those arguments.
    run_x64inv.addArgs(&.{ "--default", b.pathJoin(&.{ root, "amd64" }) });
    run_x64inv.addPassthruArgs();
    b.step("x64-inventory", "Report the amd64 instructions in binaries (default: the root tree's amd64): zig build x64-inventory -- PATH...").dependOn(&run_x64inv.step);

    const slim_tool = b.addExecutable(.{
        .name = "slim",
        .root_module = b.createModule(.{ .root_source_file = b.path("tools/slim.zig"), .target = b.graph.host }),
    });
    const run_slim = b.addRunArtifact(slim_tool);
    run_slim.has_side_effects = true;
    run_slim.stdio = .inherit;
    run_slim.setCwd(b.path("."));
    const release = pin(pins, "NINEFRONT_RELEASE");
    run_slim.addFileArg2(h9, .{ .make_absolute = true });
    run_slim.addArgs(&.{
        root,
        pathFromRoot(b, "src/9box"),
        pathFromRoot(b, ".local/src/9front/sys/src"),
        slim_arch,
        slim_links,
        pathFromRoot(b, b.fmt(".local/build/9box/{s}", .{slim_arch})),
        // -Dslim-links=copy is the separate binaries the box is measured
        // against, in a tree of its own.
        pathFromRoot(b, b.fmt(".local/9front/slim{s}-{s}-{s}", .{ if (std.mem.eql(u8, slim_links, "copy")) "-copy" else "", release, slim_arch })),
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
    run_wsrelay.addPassthruArgs();
    b.step("wsrelay", "Relay WebSockets to a TCP 9P server: zig build wsrelay -- LISTEN_PORT TARGET_PORT").dependOn(&run_wsrelay.step);

    // One proposal's demos, web cases, and integration cases (design/),
    // whatever its status, by slug.
    const proposal_step = b.step("proposal", "Run one proposal's demos, web cases, and integration cases: -Dp=<slug>");
    // A demo registered for a slug that isn't a proposal would never run.
    var demo_slugs = demos.keyIterator();
    while (demo_slugs.next()) |slug| if (frontmatter.resolve(proposals(b), slug.*) == null)
        std.debug.panic("build.zig: addDemo for `{s}`, which isn't a proposal under design/", .{slug.*});
    if (b.option([]const u8, "p", "With zig build proposal: the proposal, by slug")) |ref| {
        const ps = proposals(b);
        if (frontmatter.resolve(ps, ref)) |i| {
            for (addIntegration(b, proposal_step, 1, optimize, tagFilters(b, ps[i]), it, root, engine_list, true, if (test_web) null else go_cases, guest_test, src_dir)) |run_cases| {
                if (!test_web) run_cases.step.dependOn(linux_fixtures);
            }
            if (demos.get(ps[i].slug)) |steps| for (steps.items) |s| proposal_step.dependOn(s);
        } else proposal_step.dependOn(&b.addFail(b.fmt("-Dp={s} isn't a proposal under design/", .{ref})).step);
    } else proposal_step.dependOn(&b.addFail("zig build proposal needs -Dp=<slug>").step);

    // The design tool (design/epoch-0/proposals.md), run from the repository
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
    // `sign` and `propose` ask questions on the terminal.
    run_design.stdio = .inherit;
    run_design.addPassthruArgs();
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
    run_mkroot.addPassthruArgs();
    b.step("mkroot", "Build the 9front root tree in .local/9front/root: zig build mkroot -- [--force] [--src] [--arch arm64,386,amd64]").dependOn(&run_mkroot.step);

    // Unpacks a 9front release ISO into a root tree (tools/isoroot.zig),
    // for the Pages workflow's 386 root: zig build isoroot -- ISO DIR.
    const isoroot_tool = b.addExecutable(.{
        .name = "isoroot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/isoroot.zig"),
            .target = b.graph.host,
            .optimize = .safe,
        }),
    });
    const run_isoroot = b.addRunArtifact(isoroot_tool);
    run_isoroot.setCwd(b.path("."));
    run_isoroot.has_side_effects = true;
    run_isoroot.stdio = .inherit;
    run_isoroot.addPassthruArgs();
    b.step("isoroot", "Unpack a 9front release ISO into a root tree: zig build isoroot -- ISO DIR").dependOn(&run_isoroot.step);

    const mod_tests = b.addTest(.{ .root_module = test_mod.mod });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    // Runs the same programs on every engine built in and compares them.
    const engine_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/engines.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "h9", .module = test_mod.mod },
            .{ .name = "hello", .module = b.createModule(.{ .root_source_file = b.path("tests/fixtures/hello.zig"), .target = target }) },
        },
    }) });
    if (os == .macos) {
        addSdkPaths(b, engine_tests.root_module);
        engine_tests.root_module.linkFramework("Hypervisor", .{});
    }
    // The segattach, overlay, srv, fdmount, htools, sema, net and gfx fixtures, assembled freestanding as the shim is, and
    // embedded as raw text for tests/engines.zig to wrap in an a.out.
    for ([_]struct { dir: []const u8, prefix: []const u8, names: []const []const u8 }{
        .{ .dir = "segattach", .prefix = "seg", .names = &segattach_fixtures },
        .{ .dir = "overlay", .prefix = "ov", .names = &overlay_fixtures },
        .{ .dir = "srv", .prefix = "srv", .names = &srv_fixtures },
        .{ .dir = "fdmount", .prefix = "fdmount", .names = &fdmount_fixtures },
        .{ .dir = "htools", .prefix = "htools", .names = &htools_fixtures },
        .{ .dir = "sema", .prefix = "sema", .names = &sema_fixtures },
        .{ .dir = "net", .prefix = "net", .names = &net_fixtures },
        .{ .dir = "gfx", .prefix = "gfx", .names = &gfx_fixtures },
    }) |set| for (set.names) |name| {
        const obj = b.addObject(.{
            .name = name,
            .root_module = b.createModule(.{
                .target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .freestanding }),
                .optimize = .small,
            }),
        });
        obj.root_module.addAssemblyFile(b.path(b.fmt("tests/fixtures/{s}/{s}.S", .{ set.dir, name })));
        obj.root_module.addIncludePath(b.path("tests/fixtures/segattach"));
        const bin = b.addObjCopy(obj.getEmittedBin(), .{ .format = .binary, .only_section = ".text" });
        engine_tests.root_module.addAnonymousImport(b.fmt("{s}_{s}", .{ set.prefix, name }), .{ .root_source_file = bin.getOutput() });
    };
    const test_step = b.step("test", "Run unit tests and the engine tests (not the integration cases)");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    // The kernel's Zig's own cases (design/kernel-port.md).
    test_step.dependOn(kern_test_step);
    // The scheduler's primitives (design/scheduler.md).
    test_step.dependOn(addSchedTests(b, target, optimize));
    // h9.wasm too, so a change to the shared engine or JIT code that breaks
    // wasm32 (64-bit atomics, threads) is caught where it's made.
    test_step.dependOn(&web.exe.step);
    addHcpuTests(b, test_step, target, optimize);
    addJitTestTools(b, target, optimize);
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
    const run_engine_tests = b.addRunArtifact(engine_tests);
    // The [gfx] cases that run rio and acme take them from the root tree.
    run_engine_tests.setEnvironmentVariable("H9_TEST_ROOT", root);
    // The Alpine roots from scripts/fetch.sh, for the [linux-fifo] case that
    // runs two Linux machines in one process.
    run_engine_tests.setEnvironmentVariable("H9_TEST_LINUX_ROOT", pathFromRoot(b, ".local/linux"));
    if (os == .macos and b.graph.host.result.os.tag == .macos) {
        const sign = b.addSystemCommand(&.{ "codesign", "--force", "--sign", "-", "--entitlements" });
        sign.addFileArg(b.path("h9.entitlements"));
        sign.addFileArg(engine_tests.getEmittedBin());
        run_engine_tests.step.dependOn(&sign.step);
    }
    test_step.dependOn(&run_engine_tests.step);
    // With hcpu, the engine cases run on each tier: T1 (the default)
    // above, and T0 here (design/epoch-0/hcpu.md).
    if (emu == .hcpu and !no_jit) {
        const run_t0 = b.addRunArtifact(engine_tests);
        run_t0.setName("run test engines (hcpu T0)");
        run_t0.setEnvironmentVariable("H9_TEST_ROOT", root);
        run_t0.setEnvironmentVariable("H9_HCPU_TIER", "t0");
        run_t0.step.dependOn(&run_engine_tests.step);
        test_step.dependOn(&run_t0.step);
    }
    // The integration cases are their own step, `zig build integration`, so
    // running both doesn't run them twice; `zig build test integration`
    // runs everything.

    // libh9 (src/capi.zig): machines behind a C ABI, as a shared library,
    // with its header, in zig-out/libh9 (docs/embedding.md, "From C and
    // other languages").
    const libh9 = b.addLibrary(.{
        .name = "h9",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/capi.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            // Debug info is most of a release build's size (30 MB of 36).
            .strip = if (optimize == .debug) null else true,
            .imports = &.{.{ .name = "h9", .module = mod.mod }},
        }),
    });
    if (os == .macos) {
        addSdkPaths(b, libh9.root_module);
        libh9.root_module.linkFramework("Hypervisor", .{});
    }
    if (target.result.ofmt == .elf) libh9.setVersionScript(b.path("src/capi/libh9.map"));
    const libh9_dir: std.Build.InstallDir = .{ .custom = "libh9" };
    const libh9_step = b.step("libh9", "Build libh9, h9 behind a C ABI (src/capi/h9.h), into zig-out/libh9");
    libh9_step.dependOn(&b.addInstallArtifact(libh9, .{
        .dest_dir = .{ .override = libh9_dir },
        .implib_dir = if (os == .windows) .{ .override = libh9_dir } else .disabled,
        .pdb_dir = .disabled,
    }).step);
    libh9_step.dependOn(&b.addInstallFileWithDir(b.path("src/capi/h9.h"), libh9_dir, "h9.h").step);

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
    const install_embed = b.addInstallArtifact(embed_example, .{});
    b.step("embed", "Build docs/embedding/embed.zig, the embedding guide's example, as zig-out/bin/embed").dependOn(&install_embed.step);
    // zig build test runs it on the hello fixture where an engine can: the
    // default engine (auto: HVF on an arm64 Mac that has it, signed like h9,
    // else the emulator) for one machine, and the emulator for the second.
    // HVF allows one VM per host process.
    const hvf_host = os == .macos and target.result.cpu.arch == .aarch64 and b.graph.host.result.os.tag == .macos;
    const runs_here = os == b.graph.host.result.os.tag and target.result.cpu.arch == b.graph.host.result.cpu.arch;
    if (hvf_host or (emu != .none and runs_here)) {
        const run_embed = b.addRunArtifact(embed_example);
        if (hvf_host) {
            const sign = b.addSystemCommand(&.{ "codesign", "--force", "--sign", "-", "--entitlements" });
            sign.addFileArg(b.path("h9.entitlements"));
            sign.addFileArg(embed_example.getEmittedBin());
            run_embed.step.dependOn(&sign.step);
        }
        const machines: []const u8 = if (emu != .none) "2" else "1";
        run_embed.addArgs(&.{ "-j", machines });
        run_embed.addFileArg(host_hello);
        // Machine 0's engine isn't named: auto picks it when it runs.
        run_embed.addCheck(.{ .expect_stdout_match = "machine 0 (" });
        run_embed.addCheck(.{ .expect_stdout_match = "): exited \"\"\n  hello\n" });
        if (emu != .none) run_embed.addCheck(.{ .expect_stdout_match = "machine 1 (hcpu): exited \"\"\n  hello\n" });
        run_embed.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&run_embed.step);
    }

    // docs/embedding/hello.c, libh9 from C. zig build test runs it on the
    // hello fixture where the embed example runs, with the emulator, so
    // it needs no entitlement.
    const libh9_example = b.addExecutable(.{
        .name = "libh9-hello",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    libh9_example.root_module.addCSourceFile(.{ .file = b.path("docs/embedding/hello.c") });
    libh9_example.root_module.addIncludePath(b.path("src/capi"));
    libh9_example.root_module.linkLibrary(libh9);
    b.step("libh9-example", "Build docs/embedding/hello.c, libh9 from C, as zig-out/bin/libh9-hello").dependOn(&b.addInstallArtifact(libh9_example, .{}).step);
    if (emu != .none and runs_here) {
        const run_c = b.addRunArtifact(libh9_example);
        run_c.addFileArg(host_hello);
        run_c.addArgs(&.{ "--engine", "hcpu" });
        run_c.addCheck(.{ .expect_stdout_match = "engine hcpu, arch " });
        run_c.addCheck(.{ .expect_stdout_match = "hello\nexited \"\"\n" });
        run_c.addCheck(.{ .expect_term = .{ .exited = 0 } });
        test_step.dependOn(&run_c.step);
    }

    // ha64's [hcpu] cases, through the engine interface on
    // T0 and T1; they skip without the emulator.
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
    const a64_jit_run = b.addRunArtifact(a64_jit);
    test_step.dependOn(&a64_jit_run.step);
    b.step("a64-jit", "Run ha64's [hcpu] cases on T0 and T1 (tests/a64.zig)").dependOn(&a64_jit_run.step);

    // The speed numbers in SPEC.md's "Limits and selection". Always
    // ReleaseFast (the h9 module inherits it), whatever -Doptimize says.
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/bench.zig"),
            .target = target,
            .optimize = .fast,
            .imports = &.{.{ .name = "h9", .module = mod.mod }},
        }),
    });
    if (os == .macos) {
        addSdkPaths(b, bench.root_module);
        bench.root_module.linkFramework("Hypervisor", .{});
    }
    addComputeBenches(b, bench);
    const run_bench = b.addRunArtifact(bench);
    run_bench.has_side_effects = true;
    run_bench.addPassthruArgs();
    if (os == .macos and b.graph.host.result.os.tag == .macos) {
        const sign = b.addSystemCommand(&.{ "codesign", "--force", "--sign", "-", "--entitlements" });
        sign.addFileArg(b.path("h9.entitlements"));
        sign.addFileArg(bench.getEmittedBin());
        run_bench.step.dependOn(&sign.step);
    }
    b.step("bench", "Time a compute loop, pwrite round trips, and the compute benchmarks on every engine built in (-- compute: those only; the emulator on T0 and T1)").dependOn(&run_bench.step);

    // For running the tests in a VM (scripts/lima/vm test): the engine
    // tests and the integration tests, built for the target.
    const install_tests_step = b.step("install-tests", "Install the engine and integration tests as zig-out/bin/engine-tests and integration-tests");
    install_tests_step.dependOn(&b.addInstallArtifact(engine_tests, .{ .dest_sub_path = b.fmt("engine-tests{s}", .{target.result.exeFileExt()}) }).step);
    install_tests_step.dependOn(&b.addInstallArtifact(integrationTests(b, target, optimize, &.{}, b.addOptions()), .{ .dest_sub_path = b.fmt("integration-tests{s}", .{target.result.exeFileExt()}) }).step);
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

/// zig build x64check [-Dcheck-n=N] [-Dcheck-seed=S] [-Dcheck-mode=int|x87|sse|v2]:
/// hx64's T0 against the host CPU in long mode (tools/x86check): N random
/// instructions (default 100000) run natively by oracle64.c and on T0.
/// x86-64 Linux hosts only. They're options, not arguments after `--`,
/// because the build wires them into three steps, and build.zig can't
/// see those arguments.
fn addX64check(b: *std.Build, hcpu: *std.Build.Module) void {
    const step = b.step("x64check", "Check hx64's T0 against the host CPU in long mode (-Dcheck-n, -Dcheck-seed, -Dcheck-mode=int|x87|sse|v2; x86-64 Linux)");
    const host = b.graph.host.result;
    if (host.cpu.arch != .x86_64 or host.os.tag != .linux) {
        step.dependOn(&b.addFail("x64check: needs an x86-64 Linux host, where the CPU is the oracle").step);
        return;
    }
    const oracle = b.addExecutable(.{
        .name = "oracle64",
        .root_module = b.createModule(.{
            .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl }),
            .optimize = .fast,
            .link_libc = true,
        }),
    });
    // No sanitizer: its traps are SIGILL, which the oracle takes as the
    // guest's.
    oracle.root_module.addCSourceFile(.{ .file = b.path("tools/x86check/oracle64.c"), .flags = &.{"-fno-sanitize=all"} });
    const check = b.addExecutable(.{
        .name = "x86check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/x86check/x86check.zig"),
            .target = b.graph.host,
            .optimize = .safe,
            .link_libc = true,
            .imports = &.{.{ .name = "hcpu", .module = hcpu }},
        }),
    });
    const n = b.option([]const u8, "check-n", "x64check: how many random instructions (default 100000)") orelse "100000";
    const seed = b.option([]const u8, "check-seed", "x64check: the random seed (default 1)") orelse "1";
    const mode = b.option([]const u8, "check-mode", "x64check: int, x87, sse, or v2 (default int)") orelse "int";
    const gen = b.addRunArtifact(check);
    gen.addArgs(&.{ "gen64", n, seed });
    const cases = gen.addOutputFileArg("cases.bin");
    gen.addArg(mode);
    const run = b.addRunArtifact(oracle);
    run.addFileArg(cases);
    const answers = run.addOutputFileArg("answers.bin");
    const cmp = b.addRunArtifact(check);
    cmp.has_side_effects = true;
    cmp.setEnvironmentVariable("X86CHECK_MODE", mode);
    cmp.addArg("cmp64");
    cmp.addFileArg(cases);
    cmp.addFileArg(answers);
    step.dependOn(&cmp.step);
}

/// The scheduler's primitives' cases (src/kern/sched/, design/scheduler.md):
/// kernel stacks, and park and resume, with no kernel or engine. They run
/// for -Dtarget where the host can run it, and are only compiled for one
/// it can't. On wasm32-wasi they're compiled too, and with Binaryen's
/// wasm-opt on PATH, run through its Asyncify pass and under Node's WASI.
fn addSchedTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Step {
    const step = b.step("sched-test", "Run the scheduler's kernel stack and park and resume cases (src/kern/sched/, design/scheduler.md)");
    const mk = struct {
        fn tests(bb: *std.Build, t: std.Build.ResolvedTarget, o: std.lang.Optimize) *std.Build.Step.Compile {
            return bb.addTest(.{ .name = "sched", .root_module = bb.createModule(.{
                .root_source_file = bb.path("src/kern/sched/sched.zig"),
                .target = t,
                .optimize = o,
                .link_libc = t.result.os.tag != .windows,
            }) });
        }
    };
    const native = mk.tests(b, target, optimize);
    const run = b.addRunArtifact(native);
    run.skip_foreign_checks = true;
    step.dependOn(&run.step);

    const wasm = mk.tests(b, webTarget(b, false), optimize);
    if (b.findProgram(.{ .names = &.{"wasm-opt"} })) |wasm_opt| {
        const asyncify = b.addSystemCommand(&.{ wasm_opt, "--asyncify" });
        for ([_][]const u8{ "bulk-memory", "mutable-globals", "sign-ext", "nontrapping-float-to-int", "multivalue", "reference-types" }) |f|
            asyncify.addArg(b.fmt("--enable-{s}", .{f}));
        asyncify.addArtifactArg(wasm);
        asyncify.addArg("-o");
        const out = asyncify.addOutputFileArg("sched.wasm");
        const node = b.addSystemCommand(&.{ "node", "--no-warnings", "tests/web/wasi-test.mjs" });
        node.addFileArg(out);
        node.setCwd(b.path("."));
        node.expectExitCode(0);
        step.dependOn(&node.step);
    } else step.dependOn(&wasm.step);
    return step;
}

/// The JIT's test tools (src/engine/hcpu/jit/README.md, "Test tools"): lockstep against
/// Unicorn (tools/lockstep.zig, with the prebuilt library fetched), the
/// fuzzers, and the litmus tests.
fn addJitTestTools(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) void {
    // The fuzzers: the region check always, and lockstep against Unicorn
    // when the oracle's library has been fetched.
    // ReleaseSafe unless -Doptimize says otherwise: fast, and still checked.
    const fuzz_optimize: std.lang.Optimize = if (optimize == .debug) .safe else optimize;
    const oracle: ?Oracle, const oracle_missing: []const u8 = switch (addOracle(b, target, fuzz_optimize)) {
        .ok => |o| .{ o, "" },
        .missing => |why| .{ null, why },
    };
    // The fuzzers that link the oracle are built for its target (musl on
    // Linux), the rest for -Dtarget.
    const fuzz_target = if (oracle) |o| o.target else target;
    const lockstep_step = b.step("lockstep", "Run the lockstep tests against Unicorn, the oracle (needs scripts/fetch.sh unicorn)");
    if (oracle) |o| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path("tools/lockstep.zig"),
            .target = o.target,
            .optimize = optimize,
            .imports = &.{.{ .name = "unicorn", .module = o.module }},
        }) });
        linkOracle(t, o);
        lockstep_step.dependOn(&b.addRunArtifact(t).step);
    } else lockstep_step.dependOn(&b.addFail(b.fmt("lockstep: no oracle: {s}", .{oracle_missing})).step);

    const fuzz_hcpu = b.createModule(.{ .root_source_file = b.path("src/engine/hcpu/hcpu.zig"), .target = target, .optimize = fuzz_optimize });
    const fuzzer_hcpu = if (oracle) |o| b.createModule(.{ .root_source_file = b.path("src/engine/hcpu/hcpu.zig"), .target = o.target, .optimize = fuzz_optimize }) else fuzz_hcpu;
    const fuzz_lockstep: ?*std.Build.Module = if (oracle) |o| b.createModule(.{
        .root_source_file = b.path("tools/lockstep.zig"),
        .target = o.target,
        .optimize = fuzz_optimize,
        .imports = &.{.{ .name = "unicorn", .module = o.module }},
    }) else null;
    const fuzz_options = b.addOptions();
    fuzz_options.addOption(bool, "unicorn", oracle != null);
    // zig build fuzz-long: the three fuzzers with the region check, generated
    // code (--native), and lockstep when the oracle's library is fetched, for
    // -Dfuzz-minutes (default 60), -Dfuzz-jobs processes each (default 2),
    // tallying divergences instead of stopping. Each job starts its seeds
    // 2^40 apart from -Dfuzz-seed (default: from the clock).
    const fuzz_long = b.step("fuzz-long", "Run fuzz-a64, fuzz-x86, and fuzz-x64 with the region check and --native for an hour across seeds (-Dfuzz-minutes, -Dfuzz-jobs, -Dfuzz-seed)");
    const fuzz_minutes = b.option(u32, "fuzz-minutes", "zig build fuzz-long: how long to fuzz (default 60)") orelse 60;
    const fuzz_jobs = b.option(u32, "fuzz-jobs", "zig build fuzz-long: processes per fuzzer (default 2)") orelse 2;
    const fuzz_seed = b.option(u64, "fuzz-seed", "zig build fuzz-long: the first seed (default: from the clock)") orelse
        @as(u64, @truncate(@as(u128, @bitCast(@as(i128, std.Io.Timestamp.now(b.graph.io, .real).nanoseconds)))));
    var fuzz_exes: [3]*std.Build.Step.Compile = undefined;
    var fuzz_i: usize = 0;
    for ([_][]const u8{ "a64", "x86", "x64" }) |arch| {
        const exe = b.addExecutable(.{
            .name = b.fmt("fuzz-{s}", .{arch}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("tests/jit/fuzz_{s}.zig", .{arch})),
                .target = fuzz_target,
                .optimize = fuzz_optimize,
                .imports = &.{.{ .name = "hcpu", .module = fuzzer_hcpu }},
            }),
        });
        exe.root_module.addOptions("fuzz_options", fuzz_options);
        if (fuzz_lockstep) |ls| {
            exe.root_module.addImport("lockstep", ls);
            linkOracle(exe, oracle.?);
        }
        const run = b.addRunArtifact(exe);
        run.has_side_effects = true;
        run.addPassthruArgs();
        b.step(b.fmt("fuzz-{s}", .{arch}), b.fmt("Fuzz the {s} T0 and lifter with random programs (-- --help for options; lockstep needs scripts/fetch.sh unicorn)", .{arch})).dependOn(&run.step);
        fuzz_exes[fuzz_i] = exe;
        fuzz_i += 1;
    }
    const fuzz_long_exe = b.addExecutable(.{
        .name = "fuzz-long",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/jit/fuzz_long.zig"),
            .target = b.graph.host,
            .optimize = .safe,
        }),
    });
    const long = b.addRunArtifact(fuzz_long_exe);
    long.has_side_effects = true;
    long.addArgs(&.{ "--minutes", b.fmt("{d}", .{fuzz_minutes}), "--jobs", b.fmt("{d}", .{fuzz_jobs}), "--seed", b.fmt("{d}", .{fuzz_seed}) });
    for (fuzz_exes) |e| long.addArtifactArg(e);
    fuzz_long.dependOn(&long.step);

    addX64check(b, fuzz_hcpu);

    const litmus = b.addExecutable(.{
        .name = "litmus",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/jit/litmus.zig"),
            .target = target,
            .optimize = fuzz_optimize,
            .imports = &.{.{ .name = "hcpu", .module = fuzz_hcpu }},
        }),
    });
    const litmus_run = b.addRunArtifact(litmus);
    litmus_run.has_side_effects = true;
    litmus_run.addPassthruArgs();
    b.step("litmus", "Run the threading litmus tests on every tier, with their outcome tallies (-- --iters N --tier T --only NAME)").dependOn(&litmus_run.step);
}

/// src/engine/hcpu/hcpu.zig's tests, split into parts by name filter: the three slow
/// groups (the emitters', the checkers' with the litmus tests, and the 386
/// JIT's, each about 20 s in Debug), and the rest. A test's name starts
/// with its file's path under src/, dots for slashes, so the rest is every
/// other file and directory in src/engine/hcpu/jit, src/engine/hcpu/interp, and src/engine/hcpu/hcpu.zig
/// itself, listed from the tree so a new file lands in a part. A test in
/// a file elsewhere that src/engine/hcpu/hcpu.zig reaches would be in no part: add
/// its prefix here.
fn hcpuTestParts(b: *std.Build) []const []const []const u8 {
    const slow = [_][]const u8{ "emit", "check", "x86" };
    var rest: std.ArrayList([]const u8) = .empty;
    rest.appendSlice(b.allocator, &.{ "hcpu.", "interp." }) catch @panic("OOM");
    const io = b.graph.io;
    var dir = b.root.root_dir.handle.openDir(io, "src/engine/hcpu/jit", .{ .iterate = true }) catch |err|
        std.debug.panic("build.zig: can't list src/engine/hcpu/jit: {t}", .{err});
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch |err| std.debug.panic("build.zig: can't list src/engine/hcpu/jit: {t}", .{err})) |entry| {
        const stem = switch (entry.kind) {
            .directory => entry.name,
            .file => if (std.mem.endsWith(u8, entry.name, ".zig")) entry.name[0 .. entry.name.len - 4] else continue,
            else => continue,
        };
        for (slow) |sl| {
            if (std.mem.eql(u8, stem, sl)) break;
        } else rest.append(b.allocator, b.fmt("jit.{s}.", .{stem})) catch @panic("OOM");
    }
    var parts: std.ArrayList([]const []const u8) = .empty;
    for (slow) |sl| parts.append(b.allocator, b.allocator.dupe([]const u8, &.{b.fmt("jit.{s}.", .{sl})}) catch @panic("OOM")) catch @panic("OOM");
    parts.append(b.allocator, rest.items) catch @panic("OOM");
    return parts.items;
}

/// The emulator's own CPUs (src/engine/hcpu/hcpu.zig): the JIT layer's unit tests,
/// natively, and the wasm emitter's under Node when Node is installed
/// (tests/jit/run.mjs). `zig build hcpu` runs just these. `zig build
/// hcpu-web`, and `web-test` with it, runs the wasm emitter's in Chromium.
fn addHcpuTests(b: *std.Build, test_step: *std.Build.Step, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) void {
    const step = b.step("hcpu", "Run the emulator CPU and JIT tests (src/engine/hcpu/hcpu.zig), natively and under Node");
    // A test binary runs its tests one at a time, and these take about a
    // minute, so they're split by name into a few binaries the build
    // runner runs side by side (hcpuTestParts).
    const hcpu_mod = b.createModule(.{
        .root_source_file = b.path("src/engine/hcpu/hcpu.zig"),
        .target = target,
        .optimize = optimize,
    });
    for (hcpuTestParts(b)) |filters| {
        const tests = b.addTest(.{ .root_module = hcpu_mod, .filters = filters });
        const run = b.addRunArtifact(tests);
        step.dependOn(&run.step);
        test_step.dependOn(&run.step);
    }

    // h86's [hcpu] cases, on T0 and T1.
    const x86 = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/x86.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "hcpu", .module = b.createModule(.{
            .root_source_file = b.path("src/engine/hcpu/hcpu.zig"),
            .target = target,
            .optimize = optimize,
        }) }},
    }) });
    const x86_run = b.addRunArtifact(x86);
    step.dependOn(&x86_run.step);
    test_step.dependOn(&x86_run.step);
    b.step("x86-jit", "Run h86's [hcpu] cases on T0 and T1 (tests/x86.zig)").dependOn(&x86_run.step);

    // hx64's [hcpu] cases, on T0 and T1 (design/epoch-0/hcpu.md).
    const x64 = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/x64.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "hcpu", .module = b.createModule(.{
            .root_source_file = b.path("src/engine/hcpu/hcpu.zig"),
            .target = target,
            .optimize = optimize,
        }) }},
    }) });
    const x64_run = b.addRunArtifact(x64);
    step.dependOn(&x64_run.step);
    test_step.dependOn(&x64_run.step);
    b.step("x64-jit", "Run hx64's [hcpu] cases on T0 and T1 (tests/x64.zig)").dependOn(&x64_run.step);

    // h86's memory-model litmus tests: compiled code on host threads.
    // ReleaseSafe unless -Doptimize says otherwise, so the threads race.
    const litmus = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/jit/litmus_x86.zig"),
        .target = target,
        .optimize = if (optimize == .debug) .safe else optimize,
        .imports = &.{.{ .name = "hcpu", .module = b.createModule(.{
            .root_source_file = b.path("src/engine/hcpu/hcpu.zig"),
            .target = target,
            .optimize = if (optimize == .debug) .safe else optimize,
        }) }},
    }) });
    const litmus_run = b.addRunArtifact(litmus);
    step.dependOn(&litmus_run.step);
    test_step.dependOn(&litmus_run.step);
    b.step("litmus-x86", "Run h86's memory-model litmus tests on compiled code").dependOn(&litmus_run.step);

    // ha64's memory-model litmus tests: every tier on host threads. About
    // two minutes at 5000 runs a test, so in zig build hcpu, not test.
    const litmus_a64 = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/jit/litmus_a64.zig"),
        .target = target,
        .optimize = if (optimize == .debug) .safe else optimize,
        .imports = &.{.{ .name = "hcpu", .module = b.createModule(.{
            .root_source_file = b.path("src/engine/hcpu/hcpu.zig"),
            .target = target,
            .optimize = if (optimize == .debug) .safe else optimize,
        }) }},
    }) });
    const litmus_a64_run = b.addRunArtifact(litmus_a64);
    step.dependOn(&litmus_a64_run.step);
    b.step("litmus-a64", "Run ha64's memory-model litmus tests on every tier").dependOn(&litmus_a64_run.step);

    const node = b.findProgram(.{ .names = &.{"node"} }) orelse return;
    const runtime = b.addExecutable(.{
        .name = "jit-runtime",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/jit/wasm_runtime.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            // Debug: optimizing the stand-in T0's dispatch for wasm takes minutes.
            .optimize = .debug,
            .imports = &.{.{ .name = "hcpu", .module = b.createModule(.{ .root_source_file = b.path("src/engine/hcpu/hcpu.zig") }) }},
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
    b.step("hcpu-web", "Run the wasm emitter's tests in Chromium with Playwright").dependOn(&browser_run.step);
    if (b.top_level_steps.get("web-test")) |web_test| web_test.step.dependOn(&browser_run.step);
}

/// `sub` under the build root, for paths outside the build graph: roots
/// and tools in .local, which the build reads or hands to programs as is.
fn pathFromRoot(b: *std.Build, sub: []const u8) []const u8 {
    return b.pathJoin(&.{ b.root.root_dir.path orelse ".", b.root.sub_path, sub });
}

/// A run of the installed h9 (`h9`) with `args`, once `signed` has
/// installed (and on macOS signed) it.
fn runH9(b: *std.Build, h9: std.Build.LazyPath, signed: *std.Build.Step, args: []const []const u8) *std.Build.Step.Run {
    const run = std.Build.Step.Run.create(b, b.fmt("run h9 {s}", .{if (args.len > 0) args[0] else ""}));
    run.addFileArg(h9);
    run.addArgs(args);
    run.step.dependOn(signed);
    return run;
}
