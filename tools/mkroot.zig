//! Builds the 9front root tree from the pinned QEMU image:
//! `zig build mkroot -- [--force] [--src] [--arch arm64,386,amd64]`, run
//! from the repository root.
//!
//! Boots the image headless in QEMU (no network), tars the file system out
//! onto a second raw disk, and unpacks it into .local/9front/root-<release>,
//! with .local/9front/root pointing at it. The image itself is left
//! untouched.
//!
//! The tree leaves out what running programs doesn't need: boot kernels,
//! /sys/doc and, unless --src is given, /sys/src (needed for self-hosting,
//! design/0010-self-host.md). That's about 250 MB instead of 420 MB.
//!
//! The tree has binaries for the host's architecture unless --arch names
//! others. The image's are arm64, so an arm64 tree is just the image's;
//! /386 and /amd64 are filled with binaries and libraries by
//! cross-compiling the tree's own /sys/src inside h9
//! (design/0009-i386.md): `cd /sys/src && objtype=386 mk install`, with the
//! root writable. Without --src, /sys/src is copied in from the fetched
//! checkout for the build and removed after. It needs a built h9
//! (zig-out/bin/h9, or $H9), with the emulator on hosts without an arm64
//! hypervisor. On an existing tree, the host's architecture is built if
//! it's missing, and --arch builds what it names again, without extracting
//! the tree again.
//!
//! Needs qemu-system-aarch64, qemu-img and bsdtar (or a tar that is
//! bsdtar, as on macOS and Windows).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

const usage = "usage: zig build mkroot -- [--force] [--src] [--arch arm64,386,amd64]";

/// Top-level directories the 9front kernel supplies through #/ rather than
/// the disk. h9 binds devices onto them, so they must exist in the host tree.
const mount_points = [_][]const u8{
    "bin", "boot",    "dev",  "env",  "fd",  "mnt", "mnt/temp", "mnt/term", "mnt/term/cwd", "mnt/wsys", "n",
    "net", "net.alt", "proc", "root", "shr", "srv", "tmp",
};
/// On-disk directories left out of the export: dist holds installer payloads.
const exclude = [_][]const u8{"dist"};
/// Left out when unpacking: kernels and boot files for real hardware, and
/// documentation. bsdtar patterns, matched against the whole path.
const skip = [_][]const u8{
    "arm64/9*", "arm64/s9*", "386/9boot*", "386/*.efi", "386/efiboot.fat",
    "386/mbr",  "386/pbs",   "sys/doc",
};
const skip_src = [_][]const u8{"sys/src"};

const prompt = "H9> ";

/// Architectures --arch can name, as 9front names them. The image's
/// binaries are arm64; the others are built.
const arches = [_][]const u8{ "arm64", "386", "amd64" };
const arm64 = 0;

/// The 9front name of a CPU architecture, as an index into `arches`.
pub fn archOf(cpu: std.Target.Cpu.Arch) u8 {
    return switch (cpu) {
        .x86_64 => 2,
        .x86 => 1,
        else => arm64,
    };
}

const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";

// Process-wide state, so die() can clean up as Python's atexit and
// TemporaryDirectory did: kill QEMU and remove the scratch directory.
var g_io: Io = undefined;
var g_child: ?*std.process.Child = null;
var g_tmp: ?[]const u8 = null;

/// Kills QEMU with SIGKILL where there is one, as Python's Popen.kill did:
/// SIGTERM makes QEMU print "terminating on signal 15".
fn killChild(c: *std.process.Child) void {
    if (builtin.os.tag != .windows) if (c.id) |pid| std.posix.kill(pid, .KILL) catch {};
    c.kill(g_io);
}

fn cleanup() void {
    if (g_child) |c| {
        killChild(c);
        g_child = null;
    }
    if (g_tmp) |t| {
        Dir.cwd().deleteTree(g_io, t) catch {};
        g_tmp = null;
    }
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    cleanup();
    std.debug.print("mkroot: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn log(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("mkroot: " ++ fmt ++ "\n", args);
}

fn oom() noreturn {
    die("out of memory", .{});
}

// ---- Pure helpers (unit-tested below) ----

/// The value of `name=` at the start of a line in pins.sh, up to the first
/// whitespace.
pub fn pinValue(text: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, name) or line.len <= name.len or line[name.len] != '=') continue;
        const v = line[name.len + 1 ..];
        const end = std.mem.indexOfAny(u8, v, " \t\r\x0b\x0c") orelse v.len;
        if (end == 0) continue;
        return v[0..end];
    }
    return null;
}

pub const Options = struct {
    force: bool = false,
    src: bool = false,
    /// Indexes into `arches`, in the order given, without duplicates.
    arch: [arches.len]u8 = undefined,
    narch: usize = 0,

    fn selected(o: *const Options) []const u8 {
        return o.arch[0..o.narch];
    }
};

/// What to build into the tree: the architectures --arch names, or the
/// host's, less arm64, whose binaries come with the image. On an existing
/// tree, without --arch, only a missing one; `has` says whether the tree
/// has an architecture's binaries.
pub fn toBuild(o: Options, host: u8, exists: bool, has: *const fn (u8) bool, out: []u8) []const u8 {
    const want: []const u8 = if (o.narch > 0) o.selected() else &.{host};
    var n: usize = 0;
    for (want) |a| {
        if (a == arm64) continue;
        if (exists and o.narch == 0 and has(a)) continue;
        out[n] = a;
        n += 1;
    }
    return out[0..n];
}

pub const ParseError = union(enum) {
    usage,
    bad_arch: []const u8,
};

pub fn parseArgs(args: []const []const u8, err: *ParseError) error{Invalid}!Options {
    var o: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--force")) {
            o.force = true;
        } else if (std.mem.eql(u8, a, "--src")) {
            o.src = true;
        } else if (std.mem.eql(u8, a, "--arch") or std.mem.startsWith(u8, a, "--arch=")) {
            const v = if (std.mem.eql(u8, a, "--arch")) blk: {
                i += 1;
                if (i == args.len) {
                    err.* = .usage;
                    return error.Invalid;
                }
                break :blk args[i];
            } else a["--arch=".len..];
            var it = std.mem.splitScalar(u8, v, ',');
            while (it.next()) |x| {
                const idx = for (arches, 0..) |name, j| {
                    if (std.mem.eql(u8, name, x)) break j;
                } else {
                    err.* = .{ .bad_arch = x };
                    return error.Invalid;
                };
                if (std.mem.indexOfScalar(u8, o.selected(), @intCast(idx)) == null) {
                    o.arch[o.narch] = @intCast(idx);
                    o.narch += 1;
                }
            }
        } else {
            err.* = .usage;
            return error.Invalid;
        }
    }
    return o;
}

/// The start sector and sector count of the first MBR partition of type
/// `ptype`.
pub fn mbrPartition(mbr: []const u8, ptype: u8) ?[2]u32 {
    if (mbr.len < 512) return null;
    for (0..4) |i| {
        const e = mbr[446 + 16 * i ..][0..16];
        if (e[4] == ptype) return .{
            std.mem.readInt(u32, e[8..12], .little),
            std.mem.readInt(u32, e[12..16], .little),
        };
    }
    return null;
}

pub const FatError = error{ NotFat16, NotFound, OutOfMemory };

/// The bytes of a file in the root directory of a FAT16 volume.
pub fn fat16Read(gpa: std.mem.Allocator, img: []const u8, want: []const u8) FatError![]u8 {
    if (img.len < 32) return error.NotFat16;
    const bps: usize = std.mem.readInt(u16, img[11..13], .little);
    const spc: usize = img[13];
    const rsv: usize = std.mem.readInt(u16, img[14..16], .little);
    const nfats: usize = img[16];
    const nroot: usize = std.mem.readInt(u16, img[17..19], .little);
    const spf: usize = std.mem.readInt(u16, img[22..24], .little);
    if (spf == 0) return error.NotFat16;
    const fat = rsv * bps;
    const root = fat + nfats * spf * bps;
    const data = root + nroot * 32;
    const csize = bps * spc;
    var off = root;
    while (off < data and off + 32 <= img.len) : (off += 32) {
        const e = img[off..][0..32];
        if (e[0] == 0) break;
        if (e[0] == 0xE5 or e[11] & 0x18 != 0) continue;
        const name = std.mem.trim(u8, e[0..8], &std.ascii.whitespace);
        const ext = std.mem.trim(u8, e[8..11], &std.ascii.whitespace);
        var nbuf: [12]u8 = undefined;
        const full = if (ext.len > 0)
            std.fmt.bufPrint(&nbuf, "{s}.{s}", .{ name, ext }) catch unreachable
        else
            name;
        if (!std.ascii.eqlIgnoreCase(full, want)) continue;
        var cl: usize = std.mem.readInt(u16, e[26..28], .little);
        const size: usize = std.mem.readInt(u32, e[28..32], .little);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        while (cl >= 2 and cl < 0xFFF8) {
            const s = @min(img.len, data + (cl - 2) * csize);
            const t = @min(img.len, data + (cl - 1) * csize);
            try out.appendSlice(gpa, img[s..t]);
            const fe = fat + 2 * cl;
            if (fe + 2 > img.len or out.items.len >= size) break;
            cl = std.mem.readInt(u16, img[fe..][0..2], .little);
        }
        if (out.items.len > size) out.shrinkRetainingCapacity(size);
        return out.toOwnedSlice(gpa);
    }
    return error.NotFound;
}

/// What a console command printed: its output without carriage returns and
/// without the first line, which is the echo of the command.
pub fn commandOutput(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    const out = try std.mem.replaceOwned(u8, gpa, raw, "\r", "");
    if (std.mem.indexOfScalar(u8, out, '\n')) |nl| {
        const rest = out[nl + 1 ..];
        std.mem.copyForwards(u8, out, rest);
        return gpa.realloc(out, rest.len);
    }
    return out;
}

// ---- Host helpers ----

const Ctx = struct {
    gpa: std.mem.Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    repo: []const u8,
    local: []const u8,
    bsdtar: []const u8 = "bsdtar",

    fn join(c: Ctx, parts: []const []const u8) []const u8 {
        return std.fs.path.join(c.gpa, parts) catch oom();
    }

    fn rel(c: Ctx, path: []const u8) []const u8 {
        return std.fs.path.relative(c.gpa, c.repo, null, c.repo, path) catch path;
    }

    fn isFile(c: Ctx, path: []const u8) bool {
        const st = Dir.cwd().statFile(c.io, path, .{}) catch return false;
        return st.kind == .file;
    }

    fn isDir(c: Ctx, path: []const u8) bool {
        const st = Dir.cwd().statFile(c.io, path, .{}) catch return false;
        return st.kind == .directory;
    }

    fn exists(c: Ctx, path: []const u8) bool {
        Dir.cwd().access(c.io, path, .{}) catch return false;
        return true;
    }

    fn makePath(c: Ctx, path: []const u8) void {
        Dir.cwd().createDirPath(c.io, path) catch |e| die("creating {s}: {t}", .{ path, e });
    }

    fn rmTree(c: Ctx, path: []const u8) void {
        Dir.cwd().deleteTree(c.io, path) catch {};
    }

    /// The path of `name` on $PATH, or null.
    fn which(c: Ctx, name: []const u8) ?[]const u8 {
        const path = c.env.get("PATH") orelse return null;
        var it = std.mem.tokenizeScalar(u8, path, std.fs.path.delimiter);
        while (it.next()) |d| {
            const p = c.join(&.{ d, std.mem.concat(c.gpa, u8, &.{ name, exe_suffix }) catch oom() });
            if (c.isFile(p)) return p;
        }
        return null;
    }

    /// Runs a command with the terminal's stdio; dies unless it exits 0.
    fn run(c: Ctx, argv: []const []const u8) void {
        var child = std.process.spawn(c.io, .{ .argv = argv }) catch |e| die("{s}: {t}", .{ argv[0], e });
        const term = child.wait(c.io) catch |e| die("{s}: {t}", .{ argv[0], e });
        switch (term) {
            .exited => |code| if (code == 0) return,
            else => {},
        }
        die("{s} failed ({any})", .{ argv[0], term });
    }

    /// Whether `tar` on $PATH is bsdtar.
    fn tarIsBsdtar(c: Ctx) bool {
        _ = c.which("tar") orelse return false;
        const r = std.process.run(c.gpa, c.io, .{ .argv = &.{ "tar", "--version" } }) catch return false;
        return std.mem.indexOf(u8, r.stdout, "bsdtar") != null;
    }
};

/// QEMU's serial console: what the guest prints, and a way to type at it.
const Console = struct {
    c: Ctx,
    child: std.process.Child,
    mr: File.MultiReader = undefined,
    mr_buf: File.MultiReader.Buffer(1) = undefined,
    buf: std.ArrayList(u8) = .empty,
    transcript: std.ArrayList(u8) = .empty,
    eof: bool = false,

    fn start(con: *Console, c: Ctx, argv: []const []const u8) void {
        con.* = .{
            .c = c,
            .child = std.process.spawn(c.io, .{ .argv = argv, .stdin = .pipe, .stdout = .pipe }) catch |e|
                die("{s}: {t}", .{ argv[0], e }),
        };
        g_child = &con.child;
        con.mr.init(c.gpa, c.io, con.mr_buf.toStreams(), &.{con.child.stdout.?});
    }

    fn close(con: *Console) void {
        killChild(&con.child);
        g_child = null;
    }

    /// Waits for `pat` and returns what came before it, consuming both.
    fn until(con: *Console, pat: []const u8, timeout_s: i64) []const u8 {
        const io = con.c.io;
        const deadline: Io.Timeout = .{ .deadline = .fromNow(io, .{
            .raw = .fromSeconds(timeout_s),
            .clock = .awake,
        }) };
        while (true) {
            if (std.mem.indexOf(u8, con.buf.items, pat)) |i| {
                const out = con.c.gpa.dupe(u8, con.buf.items[0..i]) catch oom();
                const rest = con.buf.items[i + pat.len ..];
                std.mem.copyForwards(u8, con.buf.items, rest);
                con.buf.shrinkRetainingCapacity(rest.len);
                return out;
            }
            if (con.eof) break;
            con.mr.fill(1, deadline) catch |e| switch (e) {
                error.Timeout => break,
                else => {
                    con.eof = true;
                },
            };
            const r = con.mr.reader(0);
            const d = r.buffered();
            con.buf.appendSlice(con.c.gpa, d) catch oom();
            con.transcript.appendSlice(con.c.gpa, d) catch oom();
            r.tossBuffered();
        }
        const t = con.transcript.items;
        std.debug.print("{s}", .{t[t.len - @min(t.len, 2000) ..]});
        die("timed out waiting for \"{f}\" from the guest", .{std.zig.fmtString(pat)});
    }

    fn send(con: *Console, line: []const u8) void {
        const in = con.child.stdin.?;
        // The emulated UART drops input that arrives faster than rc reads it.
        for (line) |ch| con.sendByte(in, ch);
        con.sendByte(in, '\n');
    }

    fn sendByte(con: *Console, in: File, ch: u8) void {
        const io = con.c.io;
        in.writeStreamingAll(io, &.{ch}) catch |e| die("writing to QEMU: {t}", .{e});
        io.sleep(.fromMilliseconds(5), .awake) catch {};
    }

    fn cmd(con: *Console, line: []const u8, timeout_s: i64) []const u8 {
        con.send(line);
        const out = con.until(prompt, timeout_s);
        return commandOutput(con.c.gpa, out) catch oom();
    }
};

fn pin(c: Ctx, name: []const u8) []const u8 {
    const path = c.join(&.{ c.repo, "scripts", "pins.sh" });
    const text = Dir.cwd().readFileAlloc(c.io, path, c.gpa, .limited(1 << 20)) catch |e|
        die("reading scripts/pins.sh: {t}", .{e});
    return pinValue(text, name) orelse die("{s} not set in scripts/pins.sh", .{name});
}

fn h9Binary(c: Ctx) []const u8 {
    const h9 = if (c.env.get("H9")) |v| (if (v.len > 0) v else null) else null;
    const path = h9 orelse c.join(&.{ c.repo, "zig-out", "bin", "h9" ++ exe_suffix });
    Dir.cwd().access(c.io, path, .{ .execute = builtin.os.tag != .windows }) catch
        die("no h9 at {s} (zig build, with -Demu=unicorn on hosts without an arm64 hypervisor, or set $H9)", .{path});
    return path;
}

/// Dies unless h9 can run the tree's arm64 compilers: on an arm64 host any
/// backend can, elsewhere only the emulator, which `h9 --check` lists.
fn checkH9(c: Ctx) void {
    const h9 = h9Binary(c);
    if (archOf(builtin.cpu.arch) == arm64) return;
    const r = std.process.run(c.gpa, c.io, .{ .argv = &.{ h9, "--check" } }) catch |e| die("{s} --check: {t}", .{ h9, e });
    if (std.mem.indexOf(u8, r.stdout, "\nbackend emu: ok") != null) return;
    die("{s} has no emulator, which building /{s} needs on this host to run the tree's arm64 compilers; build one and pass it as $H9:\n" ++
        "  zig build -Demu=unicorn -Dtarget={t}-{t}{s} --prefix .local/h9-emu\n" ++
        "  H9=.local/h9-emu/bin/h9 zig build mkroot", .{
        h9,
        arches[archOf(builtin.cpu.arch)],
        builtin.cpu.arch,
        builtin.os.tag,
        if (builtin.os.tag == .linux) "-musl" else "",
    });
}

/// Copies the tree at `src` to `dst`, keeping symbolic links as links.
fn copyTree(c: Ctx, src: []const u8, dst: []const u8) void {
    const io = c.io;
    c.makePath(dst);
    var sd = Dir.cwd().openDir(io, src, .{ .iterate = true }) catch |e| die("opening {s}: {t}", .{ src, e });
    defer sd.close(io);
    var dd = Dir.cwd().openDir(io, dst, .{}) catch |e| die("opening {s}: {t}", .{ dst, e });
    defer dd.close(io);
    var w = sd.walk(c.gpa) catch oom();
    defer w.deinit();
    while (w.next(io) catch |e| die("reading {s}: {t}", .{ src, e })) |e| switch (e.kind) {
        .directory => dd.createDirPath(io, e.path) catch |err| die("creating {s}: {t}", .{ e.path, err }),
        .sym_link => {
            var buf: [Dir.max_path_bytes]u8 = undefined;
            const n = e.dir.readLink(io, e.basename, &buf) catch |err| die("reading link {s}: {t}", .{ e.path, err });
            dd.symLink(io, buf[0..n], e.path, .{}) catch |err| die("linking {s}: {t}", .{ e.path, err });
        },
        else => e.dir.copyFile(e.basename, dd, e.path, io, .{}) catch |err| die("copying {s}: {t}", .{ e.path, err }),
    };
}

/// Cross-compiles /sys/src for `arch` inside h9 and installs it into
/// dest/<arch>/bin and dest/<arch>/lib.
fn addArch(c: Ctx, dest: []const u8, arch: []const u8, keep_src: bool, tmp_parent: []const u8) void {
    const io = c.io;
    if (!c.isFile(c.join(&.{ dest, arch, "mkfile" })))
        die("tree has no /{s}/mkfile to build with", .{arch});
    const src = c.join(&.{ dest, "sys", "src" });
    // A marker in /<arch> says a build is under way. If it's there now, an
    // earlier build was interrupted: its last object files may be cut short
    // yet newer than their sources, so mk would use them. Start over with
    // mk clean. The marker also says whether that build copied /sys/src in,
    // so the copy is still removed after.
    const marker = c.join(&.{ dest, arch, marker_name });
    const prev = Dir.cwd().readFileAlloc(io, marker, c.gpa, .limited(64)) catch null;
    var copied = if (prev) |m| std.mem.startsWith(u8, m, "copied") else false;
    if (prev != null) log("an earlier build of /{s} was interrupted; starting it over", .{arch});
    if (!c.isDir(src)) {
        const checkout = c.join(&.{ c.local, "src", "9front", "sys", "src" });
        if (!c.isDir(checkout))
            die("no /sys/src in the tree and no {s} (run scripts/fetch.sh, or zig build mkroot -- --src)", .{c.rel(checkout)});
        log("copying /sys/src from the fetched checkout", .{});
        copied = true;
        Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = "copied\n" }) catch |e| die("writing {s}: {t}", .{ marker, e });
        copyTree(c, checkout, src);
    }
    Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = if (copied) "copied\n" else "\n" }) catch |e| die("writing {s}: {t}", .{ marker, e });
    // mk install copies into /$objtype/bin's subdirectories, which must exist.
    const arm = c.join(&.{ dest, "arm64", "bin" });
    const bin = c.join(&.{ dest, arch, "bin" });
    c.makePath(bin);
    {
        var ad = Dir.cwd().openDir(io, arm, .{ .iterate = true }) catch |e| die("opening {s}: {t}", .{ arm, e });
        defer ad.close(io);
        // Relative to bin's handle: Windows takes a whole path's aux as
        // the device, but not a name below an open directory.
        var bd = Dir.cwd().openDir(io, bin, .{}) catch |e| die("opening {s}: {t}", .{ bin, e });
        defer bd.close(io);
        var w = ad.walk(c.gpa) catch oom();
        defer w.deinit();
        while (w.next(io) catch |e| die("reading {s}: {t}", .{ arm, e })) |e| {
            if (e.kind == .directory) bd.createDirPath(io, e.path) catch |err| die("creating {s}: {t}", .{ c.join(&.{ bin, e.path }), err });
        }
    }
    c.makePath(c.join(&.{ dest, arch, "lib" }));
    log("building /{s} with h9 ({s})", .{ arch, if (archOf(builtin.cpu.arch) == arm64) "a few minutes" else "about an hour on the emulator" });
    // The compilers and mk are the tree's arm64 binaries, so the machine is
    // arm64 whatever the host; mk clean leaves /sys/src as it was.
    const cmd = std.fmt.allocPrint(c.gpa, "cd /sys/src && {s}objtype={s} mk install && objtype={s} mk clean", .{
        if (prev != null) std.fmt.allocPrint(c.gpa, "objtype={s} mk clean && ", .{arch}) catch oom() else "",
        arch,
        arch,
    }) catch oom();
    const h9 = h9Binary(c);
    // h9's stdout and stderr go to one file, in the order they were written,
    // so a failure can show the end of it.
    const log_path = c.join(&.{ tmp_parent, std.fmt.allocPrint(c.gpa, "mkroot-{s}.log", .{arch}) catch oom() });
    const out = Dir.cwd().createFile(io, log_path, .{ .read = true, .truncate = true }) catch |e| die("creating {s}: {t}", .{ log_path, e });
    defer {
        out.close(io);
        Dir.cwd().deleteFile(io, log_path) catch {};
    }
    const term = blk: {
        defer if (copied and !keep_src) c.rmTree(src);
        var child = std.process.spawn(io, .{
            .argv = &.{ h9, "--arch", "arm64", "--root", dest, "--writable", dest, "--rc", cmd },
            .stdin = .ignore,
            .stdout = .{ .file = out },
            .stderr = .{ .file = out },
        }) catch |e| die("{s}: {t}", .{ h9, e });
        break :blk child.wait(io) catch |e| die("{s}: {t}", .{ h9, e });
    };
    const ok = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        const st = out.stat(io) catch die("building /{s} failed ({any})", .{ arch, term });
        const n: usize = @intCast(@min(st.size, 4000));
        const tail = c.gpa.alloc(u8, n) catch oom();
        const got = out.readPositionalAll(io, tail, st.size - n) catch 0;
        std.debug.print("{s}", .{tail[0..got]});
        switch (term) {
            .exited => |code| die("building /{s} failed (h9 exited {d})", .{ arch, code }),
            else => die("building /{s} failed ({any})", .{ arch, term }),
        }
    }
    for ([_][]const u8{ "bin/cat", "bin/rc", "bin/ls", "lib/libc.a" }) |f| {
        if (!c.isFile(c.join(&.{ dest, arch, f })))
            die("tree is missing /{s}/{s} after the build", .{ arch, f });
    }
    Dir.cwd().deleteFile(io, marker) catch |e| die("removing {s}: {t}", .{ marker, e });
}

/// In /<arch> while mkroot builds it; see addArch.
const marker_name = ".mkroot-building";

fn addArches(c: Ctx, o: Options, dest: []const u8, build: []const u8) void {
    const cache = c.join(&.{ c.local, "cache" });
    c.makePath(cache);
    for (build) |a| addArch(c, dest, arches[a], o.src, cache);
}

fn archList(c: Ctx, list: []const u8, sep: []const u8) []const u8 {
    var names: [arches.len][]const u8 = undefined;
    for (list, 0..) |a, i| names[i] = arches[a];
    return std.mem.join(c.gpa, sep, names[0..list.len]) catch oom();
}

// toBuild's view of the tree being built.
var g_dest: []const u8 = "";
var g_ctx: Ctx = undefined;
fn treeHas(a: u8) bool {
    if (g_ctx.exists(g_ctx.join(&.{ g_dest, arches[a], marker_name }))) return false;
    return g_ctx.isFile(g_ctx.join(&.{ g_dest, arches[a], "bin", "rc" }));
}

/// Reads the first `sectors` sectors of a qcow2 image, through `qemu-img dd`
/// into a raw file in `tmp`.
fn readImage(c: Ctx, image: []const u8, tmp: []const u8, name: []const u8, sectors: u64) []u8 {
    const raw = c.join(&.{ tmp, name });
    const count = std.fmt.allocPrint(c.gpa, "count={d}", .{sectors}) catch oom();
    const in = std.mem.concat(c.gpa, u8, &.{ "if=", image }) catch oom();
    const out = std.mem.concat(c.gpa, u8, &.{ "of=", raw }) catch oom();
    c.run(&.{ "qemu-img", "dd", "-f", "qcow2", "-O", "raw", "bs=512", count, in, out });
    return Dir.cwd().readFileAlloc(c.io, raw, c.gpa, .unlimited) catch |e| die("reading {s}: {t}", .{ raw, e });
}

fn makeTmp(c: Ctx, parent: []const u8) []const u8 {
    var rnd: [6]u8 = undefined;
    c.io.random(&rnd);
    var enc: [8]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&enc, &rnd);
    const p = c.join(&.{ parent, std.mem.concat(c.gpa, u8, &.{ "mkroot.", &enc }) catch oom() });
    Dir.cwd().createDir(c.io, p, .default_dir) catch |e| die("creating {s}: {t}", .{ p, e });
    return p;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.arena.allocator();
    const io = init.io;
    g_io = io;
    const argv = try init.minimal.args.toSlice(gpa);

    var perr: ParseError = .usage;
    const o = parseArgs(argv[1..], &perr) catch switch (perr) {
        .usage => die("{s}", .{usage}),
        .bad_arch => |x| die("--arch: '{s}' isn't one of arm64, 386, amd64", .{x}),
    };

    // build.zig runs this from the repository root.
    const repo = try std.process.currentPathAlloc(io, gpa);
    var c: Ctx = .{
        .gpa = gpa,
        .io = io,
        .env = init.environ_map,
        .repo = repo,
        .local = try std.fs.path.join(gpa, &.{ repo, ".local" }),
    };
    if (!c.isFile(c.join(&.{ repo, "scripts", "pins.sh" })))
        die("run this from the repository root (zig build mkroot)", .{});

    const release = pin(c, "NINEFRONT_RELEASE");
    const nine = c.join(&.{ c.local, "9front" });
    const image = c.join(&.{ nine, try std.fmt.allocPrint(gpa, "9front-{s}.arm64.qcow2", .{release}) });
    const dest = c.join(&.{ nine, try std.fmt.allocPrint(gpa, "root-{s}", .{release}) });
    const link = c.join(&.{ nine, "root" });
    if (!c.exists(image)) die("no {s} (run scripts/fetch.sh)", .{c.rel(image)});
    for ([_][]const u8{ "qemu-system-aarch64", "qemu-img" }) |tool| {
        if (c.which(tool) == null) die("{s} not found", .{tool});
    }
    if (c.which("bsdtar") == null) {
        if (!c.tarIsBsdtar()) die("bsdtar not found", .{});
        c.bsdtar = "tar";
    }
    const exists = c.exists(dest) and !o.force;
    g_ctx = c;
    g_dest = dest;
    var build_buf: [arches.len]u8 = undefined;
    const build = toBuild(o, archOf(builtin.cpu.arch), exists, &treeHas, &build_buf);
    // Building needs an h9 that runs arm64; find that out before booting QEMU.
    if (build.len > 0) checkH9(c);
    if (exists) {
        // An existing tree may predate a mount point (rio's /mnt/temp,
        // design/0015-gfx.md).
        for (mount_points) |d| c.makePath(c.join(&.{ dest, d }));
        if (build.len == 0) {
            log("{s} exists (--force to rebuild); mount points added", .{c.rel(dest)});
            return 0;
        }
        log("{s} exists; adding {s}", .{ c.rel(dest), archList(c, build, ",") });
        addArches(c, o, dest, build);
        log("done: /{s}/bin in {s}", .{ archList(c, build, ",/"), std.fs.path.basename(dest) });
        return 0;
    }

    const cache = c.join(&.{ c.local, "cache" });
    c.makePath(cache);
    const tmp = makeTmp(c, cache);
    g_tmp = tmp;
    {
        const overlay = c.join(&.{ tmp, "overlay.qcow2" });
        c.run(&.{ "qemu-img", "create", "-q", "-f", "qcow2", "-F", "qcow2", "-b", image, overlay });

        // The kernel and plan9.ini live on the image's FAT partition, which
        // U-Boot normally loads; QEMU loads them directly instead.
        const mbr = readImage(c, image, tmp, "mbr.raw", 1);
        // Partition type 0x0B is FAT32 in the table, but 9front formats it FAT16.
        const part = mbrPartition(mbr, 0x0B) orelse die("no partition of type 0xb in the image", .{});
        const start: u64 = part[0];
        const count: u64 = part[1];
        const disk = readImage(c, image, tmp, "fat.raw", start + count);
        const fat = disk[@min(disk.len, start * 512)..];
        const kdata = fat16Read(gpa, fat, "9qemu.u") catch |e| switch (e) {
            error.NotFat16 => die("boot partition is not FAT16", .{}),
            error.NotFound => die("no 9qemu.u on the boot partition", .{}),
            error.OutOfMemory => oom(),
        };
        const kernel = c.join(&.{ tmp, "9qemu.u" });
        try Dir.cwd().writeFile(io, .{ .sub_path = kernel, .data = kdata });
        const ini = c.join(&.{ tmp, "plan9.ini" });
        try Dir.cwd().writeFile(io, .{ .sub_path = ini, .data = "console=0\nnobootprompt=local!/dev/sdF0/fs\nuser=glenda\n" });

        const out = c.join(&.{ tmp, "out.tar" });
        {
            const f = try Dir.cwd().createFile(io, out, .{});
            defer f.close(io);
            try f.setLength(io, 2 << 30);
        }

        log("booting 9front {s} in QEMU", .{release});
        var con: Console = undefined;
        // Plain `virt`, which every QEMU has (QEMU 11 dropped versioned
        // types such as virt-2.12), with highmem=off: from virt-3.0 on, PCIe
        // config space moves above 4 GB, and 9front's kernel panics at boot
        // (kenter: stack bytes left) when it's there.
        con.start(c, &.{
            "qemu-system-aarch64",
            "-M",
            "virt,highmem=off,gic-version=3",
            "-cpu",
            "cortex-a72",
            "-m",
            "2G",
            "-smp",
            "2",
            "-nographic",
            "-nic",
            "none",
            "-kernel",
            kernel,
            "-device",
            try std.fmt.allocPrint(gpa, "loader,file={s},addr=0x40010000,force-raw=on", .{ini}),
            "-drive",
            try std.fmt.allocPrint(gpa, "file={s},format=qcow2,if=none,id=disk", .{overlay}),
            "-device",
            "virtio-blk-pci-non-transitional,drive=disk",
            "-drive",
            try std.fmt.allocPrint(gpa, "file={s},format=raw,if=none,id=out", .{out}),
            "-device",
            "virtio-blk-pci-non-transitional,drive=out",
        });
        _ = con.until("\n% ", 300);
        con.send("prompt=('H'^'9> ' '\t')");
        _ = con.until(prompt, 30);
        const cputype = std.mem.trim(u8, con.cmd("cat /env/cputype", 60), "\x00 \n");
        if (!std.mem.eql(u8, cputype, "arm64")) die("guest cputype is '{s}', not arm64", .{cputype});
        const disks = con.cmd("ls /dev/sd*/data", 60);
        {
            var it = std.mem.tokenizeAny(u8, disks, &std.ascii.whitespace);
            while (it.next()) |d| {
                if (std.mem.eql(u8, d, "/dev/sdG0/data")) break;
            } else die("output disk not found in the guest: {s}", .{disks});
        }

        log("exporting the file system", .{});
        const excl = try std.mem.join(gpa, "|", &exclude);
        const res = con.cmd(try std.fmt.allocPrint(gpa, "cd /root && tar cf /dev/sdG0/data `{{ls | grep -v '^({s})$'}} && echo TAR-OK", .{excl}), 1800);
        if (std.mem.indexOf(u8, res, "TAR-OK") == null) die("tar failed in the guest:\n{s}", .{res});
        _ = con.cmd("fshalt", 60);
        con.close();

        log("unpacking into {s}", .{c.rel(dest)});
        const staging = try std.mem.concat(gpa, u8, &.{ dest, ".tmp" });
        c.rmTree(staging);
        c.makePath(staging);
        var targs: std.ArrayList([]const u8) = .empty;
        try targs.appendSlice(gpa, &.{ c.bsdtar, "-xpf", out, "-C", staging });
        for (skip) |pat| try targs.appendSlice(gpa, &.{ "--exclude", try std.mem.concat(gpa, u8, &.{ "^", pat }) });
        if (!o.src) for (skip_src) |pat| try targs.appendSlice(gpa, &.{ "--exclude", try std.mem.concat(gpa, u8, &.{ "^", pat }) });
        c.run(targs.items);
        for (mount_points) |d| c.makePath(c.join(&.{ staging, d }));
        c.rmTree(dest);
        Dir.rename(Dir.cwd(), staging, Dir.cwd(), dest, io) catch |e| die("renaming {s}: {t}", .{ staging, e });
    }
    cleanup();

    // Replace the link (or whatever is there) with one to the new tree.
    Dir.cwd().deleteFile(io, link) catch |e| switch (e) {
        error.FileNotFound => {},
        error.IsDir => Dir.cwd().deleteDir(io, link) catch |e2| die("removing {s}: {t}", .{ c.rel(link), e2 }),
        else => die("removing {s}: {t}", .{ c.rel(link), e }),
    };
    // Windows lets only an administrator, or Developer Mode, make a link.
    // Without one the tree is still built, and -Droot names it.
    var linked = true;
    Dir.cwd().symLink(io, std.fs.path.basename(dest), link, .{ .is_directory = true }) catch |e| switch (e) {
        error.AccessDenied, error.PermissionDenied => if (builtin.os.tag == .windows) {
            log("can't link {s} to {s}: {t} (turn on Developer Mode, or pass -Droot={s})", .{ c.rel(link), std.fs.path.basename(dest), e, c.rel(dest) });
            linked = false;
        } else die("linking {s}: {t}", .{ c.rel(link), e }),
        else => die("linking {s}: {t}", .{ c.rel(link), e }),
    };
    for ([_][]const u8{ "lib/namespace", "arm64/bin/cat", "arm64/bin/rc" }) |f| {
        if (!c.isFile(c.join(&.{ dest, f }))) die("tree is missing {s}", .{f});
    }
    addArches(c, o, dest, build);
    if (linked)
        log("done: .local/9front/root -> {s}", .{std.fs.path.basename(dest)})
    else
        log("done: {s} (pass it as -Droot)", .{c.rel(dest)});
    return 0;
}

test pinValue {
    const text = "A=1\n# NINEFRONT_RELEASE=0\nNINEFRONT_RELEASE=11952 # comment\nNINEFRONT_REV=abc\n";
    try std.testing.expectEqualStrings("11952", pinValue(text, "NINEFRONT_RELEASE").?);
    try std.testing.expectEqualStrings("abc", pinValue(text, "NINEFRONT_REV").?);
    try std.testing.expect(pinValue(text, "NINEFRONT") == null);
    try std.testing.expect(pinValue(text, "B") == null);
}

test parseArgs {
    var err: ParseError = .usage;
    const o = try parseArgs(&.{ "--src", "--arch", "amd64,386", "--arch=amd64" }, &err);
    try std.testing.expect(o.src and !o.force);
    try std.testing.expectEqualSlices(u8, &.{ 2, 1 }, o.selected());
    try std.testing.expectError(error.Invalid, parseArgs(&.{"--arch"}, &err));
    try std.testing.expect(err == .usage);
    try std.testing.expectError(error.Invalid, parseArgs(&.{"--arch=arm"}, &err));
    try std.testing.expectEqualStrings("arm", err.bad_arch);
    try std.testing.expectError(error.Invalid, parseArgs(&.{"-f"}, &err));
}

fn hasNone(_: u8) bool {
    return false;
}
fn hasAll(_: u8) bool {
    return true;
}

test toBuild {
    var err: ParseError = .usage;
    var buf: [arches.len]u8 = undefined;
    const none: Options = .{};
    // Without --arch: the host's, unless it's arm64 or already there.
    try std.testing.expectEqualSlices(u8, &.{2}, toBuild(none, 2, false, &hasNone, &buf));
    try std.testing.expectEqualSlices(u8, &.{}, toBuild(none, arm64, false, &hasNone, &buf));
    try std.testing.expectEqualSlices(u8, &.{}, toBuild(none, 2, true, &hasAll, &buf));
    try std.testing.expectEqualSlices(u8, &.{2}, toBuild(none, 2, true, &hasNone, &buf));
    // --arch replaces the host's, and builds again on an existing tree.
    const o = try parseArgs(&.{"--arch=arm64"}, &err);
    try std.testing.expectEqualSlices(u8, &.{}, toBuild(o, 2, false, &hasNone, &buf));
    const o2 = try parseArgs(&.{"--arch=arm64,386"}, &err);
    try std.testing.expectEqualSlices(u8, &.{1}, toBuild(o2, 2, true, &hasAll, &buf));
}

test mbrPartition {
    var mbr = [_]u8{0} ** 512;
    mbr[446 + 16 + 4] = 0x0B;
    std.mem.writeInt(u32, mbr[446 + 16 + 8 ..][0..4], 2048, .little);
    std.mem.writeInt(u32, mbr[446 + 16 + 12 ..][0..4], 4096, .little);
    try std.testing.expectEqual([2]u32{ 2048, 4096 }, mbrPartition(&mbr, 0x0B).?);
    try std.testing.expect(mbrPartition(&mbr, 0x83) == null);
}

test fat16Read {
    // A tiny FAT16 volume: 512-byte sectors, 1 sector per cluster, 1
    // reserved sector, 1 FAT of 1 sector, 16 root entries (1 sector).
    const gpa = std.testing.allocator;
    var img = [_]u8{0} ** (512 * 6);
    std.mem.writeInt(u16, img[11..13], 512, .little);
    img[13] = 1;
    std.mem.writeInt(u16, img[14..16], 1, .little);
    img[16] = 1;
    std.mem.writeInt(u16, img[17..19], 16, .little);
    std.mem.writeInt(u16, img[22..24], 1, .little);
    const fat = 512;
    const root = 1024;
    const data = 1536;
    // A deleted entry, a volume label, then 9QEMU.U in clusters 2 and 3.
    img[root] = 0xE5;
    @memcpy(img[root + 32 ..][0..11], "LABEL      ");
    img[root + 32 + 11] = 0x08;
    const e = img[root + 64 ..][0..32];
    @memcpy(e[0..11], "9QEMU   U  ");
    std.mem.writeInt(u16, e[26..28], 2, .little);
    std.mem.writeInt(u32, e[28..32], 600, .little);
    std.mem.writeInt(u16, img[fat + 4 ..][0..2], 3, .little);
    std.mem.writeInt(u16, img[fat + 6 ..][0..2], 0xFFFF, .little);
    @memset(img[data .. data + 512], 'a');
    @memset(img[data + 512 .. data + 1024], 'b');
    const got = try fat16Read(gpa, &img, "9qemu.u");
    defer gpa.free(got);
    try std.testing.expectEqual(600, got.len);
    try std.testing.expectEqual('a', got[511]);
    try std.testing.expectEqual('b', got[512]);
    try std.testing.expectError(error.NotFound, fat16Read(gpa, &img, "plan9.ini"));
}

test commandOutput {
    const gpa = std.testing.allocator;
    const a = try commandOutput(gpa, "cat /env/cputype\r\narm64\r\n");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("arm64\n", a);
    const b = try commandOutput(gpa, "no newline");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("no newline", b);
}
