//! Command-line parsing: argv to a Config, with no I/O. See DESIGN.md, "CLI".

const std = @import("std");
const builtin = @import("builtin");
const vmm = @import("h9").vmm;
const policy = @import("h9").policy;
const ws = @import("h9").ws;
const RootChanges = @import("h9").RootChanges;
const gfx = @import("h9").gfx;

pub const usage =
    \\usage: h9 [--backend auto|hvf|kvm|whp|emu] [--arch arm64|amd64|386]
    \\           [--root DIR|DIAL|SOCKET|URL] [--root-spec NAME] [--root-user NAME]
    \\           [--root-header 'NAME: VALUE'|@FILE]... [--root-ca FILE] [--cwd DIR]
    \\           [--env name=value]... [--profile default|tight] [--sandbox DIR]
    \\           [--readable PATH]... [--writable PATH]... [--read-deny PATH]...
    \\           [--write none|scope|ephemeral|overlay] [--net disable|outbound|enable]
    \\           [--net-allow PATTERN]...
    \\           [--memory SIZE] [--timeout DURATION] [--pids N] [--cpus N]
    \\           [--ns FILE] [--host-fs] [--host-cmd] [--no-guest-tools]
    \\           [--gfx[=noclip]] [--gfx-scale N]
    \\           [--strict] [--print] [--trace[=FILE]] [--dump-on-fault]
    \\           [--] program [args...]
    \\       h9 [flags] --rc 'command' [args...]
    \\       h9 [--backend B] [--root DIR|DIAL|SOCKET|URL] [--memory SIZE] --check
    \\       h9 --version
    \\       h9 --help
    \\
;

/// What h9 does: run a program, or one of the tool functions.
pub const Mode = enum {
    run,
    /// --check: probe the backends and the root tree, and run a program.
    check,
    /// --version: print the version, the pins and the backends.
    version,
    /// --help, or -h as the only argument: print the usage to stdout.
    help,
};

pub const Config = struct {
    mode: Mode = .run,
    backend: vmm.BackendKind = .auto,
    /// --arch: the architecture of the binaries to run; null means a host
    /// program's own, or the host's for a guest one.
    arch: ?vmm.Arch = null,
    /// --trace: null for none, "" for stderr, else a file.
    trace: ?[]const u8 = null,
    dump_on_fault: bool = false,
    /// --root; null means $H9ROOT, then the default. See `rootArg`.
    root: ?[]const u8 = null,
    /// --root-spec: the attach name sent to a 9P root.
    root_spec: []const u8 = "",
    /// --root-user: the uname sent in attaches to a 9P root.
    root_user: ?[]const u8 = null,
    /// --root-header values as given: `Name: value`, or `@FILE` for a host
    /// file of them (design/0021-websocket-9p.md).
    root_headers: []const []const u8 = &.{},
    /// --root-ca: PEM certificates a wss:// root must chain to.
    root_ca: ?[]const u8 = null,
    /// --cwd: the host directory bound at /mnt/term/cwd; null means the
    /// host cwd.
    cwd: ?[]const u8 = null,
    /// --env values, as name=value.
    env: []const []const u8 = &.{},
    profile: policy.Profile = .default,
    /// --sandbox DIR: the tight profile with DIR as the writable cwd.
    sandbox: ?[]const u8 = null,
    readable: []const []const u8 = &.{},
    writable: []const []const u8 = &.{},
    read_deny: []const []const u8 = &.{},
    write: ?policy.WriteMode = null,
    net: ?policy.NetMode = null,
    /// --net-allow patterns, checked when the policy is compiled.
    net_allow: []const []const u8 = &.{},
    memory: ?u64 = null,
    timeout_ns: ?u64 = null,
    pids: ?u32 = null,
    cpus: ?u32 = null,
    /// --ns: a namespace file, in newns syntax, replayed before the program.
    ns: ?[]const u8 = null,
    host_fs: bool = false,
    host_cmd: bool = false,
    /// --no-guest-tools: leave out `#H/bin` and mask `#H`
    /// (design/0032-guest-tools.md).
    guest_tools: bool = true,
    /// --gfx, --gfx=noclip and --gfx-scale: a host window
    /// (design/0015-gfx.md); null without --gfx.
    gfx: ?gfx.Options = null,
    strict: bool = false,
    print: bool = false,
    /// --rc: the command line for /bin/rc -c.
    rc: ?[]const u8 = null,
    /// The program followed by its arguments; with --rc, the arguments
    /// that become $*.
    argv: []const []const u8,
};

pub const Error = error{ Usage, OutOfMemory };

/// How a program argument is found (DESIGN.md, "Program resolution").
pub const ProgramKind = enum {
    /// `./x` or `../x`: read on the host, relative to the host cwd.
    host,
    /// Anything else: resolved in the guest namespace.
    guest,
};

pub fn programKind(arg: []const u8) ProgramKind {
    if (std.mem.startsWith(u8, arg, "./") or std.mem.startsWith(u8, arg, "../")) return .host;
    // Windows spells them .\ and ..\ too.
    if (builtin.os.tag == .windows and (std.mem.startsWith(u8, arg, ".\\") or std.mem.startsWith(u8, arg, "..\\"))) return .host;
    return .guest;
}

pub fn parse(gpa: std.mem.Allocator, args: []const []const u8) Error!Config {
    var c: Config = .{ .argv = &.{} };
    var env: std.ArrayList([]const u8) = .empty;
    var readable: std.ArrayList([]const u8) = .empty;
    var writable: std.ArrayList([]const u8) = .empty;
    var read_deny: std.ArrayList([]const u8) = .empty;
    var net_allow: std.ArrayList([]const u8) = .empty;
    var root_headers: std.ArrayList([]const u8) = .empty;
    var gfx_scale: ?u8 = null;
    // Long flags only (DESIGN.md, "Parsing rules"); -h is accepted alone,
    // where it can't be a program's flag.
    if (args.len == 2 and std.mem.eql(u8, args[1], "-h")) return .{ .mode = .help, .argv = &.{} };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (!std.mem.startsWith(u8, a, "--")) break;
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        } else if (std.mem.eql(u8, a, "--trace")) {
            c.trace = "";
        } else if (std.mem.startsWith(u8, a, "--trace=")) {
            c.trace = a["--trace=".len..];
            if (c.trace.?.len == 0) return error.Usage;
        } else if (flag(a, "--dump-on-fault")) {
            c.dump_on_fault = true;
        } else if (flag(a, "--host-fs")) {
            c.host_fs = true;
        } else if (flag(a, "--host-cmd")) {
            c.host_cmd = true;
        } else if (flag(a, "--no-guest-tools")) {
            c.guest_tools = false;
        } else if (flag(a, "--gfx")) {
            const clipboard = if (c.gfx) |g| g.clipboard else true;
            c.gfx = .{ .clipboard = clipboard };
        } else if (flag(a, "--gfx=noclip")) {
            c.gfx = .{ .clipboard = false };
        } else if (std.mem.startsWith(u8, a, "--gfx=")) {
            return error.Usage;
        } else if (value(args, &i, "--gfx-scale")) |v| {
            gfx_scale = std.fmt.parseInt(u8, v orelse return error.Usage, 10) catch return error.Usage;
        } else if (flag(a, "--strict")) {
            c.strict = true;
        } else if (flag(a, "--print")) {
            c.print = true;
        } else if (flag(a, "--check")) {
            if (c.mode != .run) return error.Usage;
            c.mode = .check;
        } else if (flag(a, "--version")) {
            if (c.mode != .run) return error.Usage;
            c.mode = .version;
        } else if (flag(a, "--help")) {
            if (c.mode != .run) return error.Usage;
            c.mode = .help;
        } else if (value(args, &i, "--backend")) |v| {
            c.backend = try enumValue(vmm.BackendKind, v);
        } else if (value(args, &i, "--arch")) |v| {
            c.arch = vmm.Arch.fromName(v orelse return error.Usage) orelse return error.Usage;
        } else if (value(args, &i, "--root-spec")) |v| {
            c.root_spec = v orelse return error.Usage;
        } else if (value(args, &i, "--root-user")) |v| {
            c.root_user = v orelse return error.Usage;
            if (c.root_user.?.len == 0) return error.Usage;
        } else if (value(args, &i, "--root-header")) |v| {
            const h = v orelse return error.Usage;
            if (h.len == 0) return error.Usage;
            try root_headers.append(gpa, h);
        } else if (value(args, &i, "--root-ca")) |v| {
            c.root_ca = v orelse return error.Usage;
            if (c.root_ca.?.len == 0) return error.Usage;
        } else if (value(args, &i, "--root")) |v| {
            c.root = v orelse return error.Usage;
        } else if (value(args, &i, "--cwd")) |v| {
            c.cwd = v orelse return error.Usage;
        } else if (value(args, &i, "--env")) |v| {
            const e = v orelse return error.Usage;
            const eq = std.mem.indexOfScalar(u8, e, '=') orelse return error.Usage;
            if (eq == 0 or std.mem.indexOfScalar(u8, e[0..eq], '/') != null) return error.Usage;
            try env.append(gpa, e);
        } else if (value(args, &i, "--profile")) |v| {
            c.profile = try enumValue(policy.Profile, v);
        } else if (value(args, &i, "--sandbox")) |v| {
            c.sandbox = v orelse return error.Usage;
        } else if (value(args, &i, "--readable")) |v| {
            try readable.append(gpa, v orelse return error.Usage);
        } else if (value(args, &i, "--writable")) |v| {
            try writable.append(gpa, v orelse return error.Usage);
        } else if (value(args, &i, "--read-deny")) |v| {
            try read_deny.append(gpa, v orelse return error.Usage);
        } else if (value(args, &i, "--write")) |v| {
            c.write = try enumValue(policy.WriteMode, v);
        } else if (value(args, &i, "--net-allow")) |v| {
            try net_allow.append(gpa, v orelse return error.Usage);
        } else if (value(args, &i, "--net")) |v| {
            c.net = try enumValue(policy.NetMode, v);
        } else if (value(args, &i, "--memory")) |v| {
            c.memory = policy.parseSize(v orelse return error.Usage) orelse return error.Usage;
        } else if (value(args, &i, "--timeout")) |v| {
            c.timeout_ns = policy.parseDuration(v orelse return error.Usage) orelse return error.Usage;
            if (c.timeout_ns == 0) return error.Usage;
        } else if (value(args, &i, "--pids")) |v| {
            c.pids = try count(v);
        } else if (value(args, &i, "--cpus")) |v| {
            c.cpus = try count(v);
        } else if (value(args, &i, "--ns")) |v| {
            c.ns = v orelse return error.Usage;
        } else if (value(args, &i, "--rc")) |v| {
            c.rc = v orelse return error.Usage;
        } else {
            return error.Usage;
        }
    }
    // --gfx-scale is the window's, so it needs one.
    if (gfx_scale) |n| {
        if (c.gfx == null) return error.Usage;
        c.gfx.?.scale = n;
    }
    if (c.sandbox != null) {
        if (c.host_fs or c.host_cmd or c.cwd != null) return error.Usage;
        c.profile = .tight;
    }
    // The tool functions take no program, so `h9 --check ls` is a mistake.
    if (c.mode != .run) {
        if (c.rc != null or i < args.len) return error.Usage;
    } else if (c.rc == null and i >= args.len) return error.Usage;
    c.env = try env.toOwnedSlice(gpa);
    c.readable = try readable.toOwnedSlice(gpa);
    c.writable = try writable.toOwnedSlice(gpa);
    c.read_deny = try read_deny.toOwnedSlice(gpa);
    c.net_allow = try net_allow.toOwnedSlice(gpa);
    c.root_headers = try root_headers.toOwnedSlice(gpa);
    c.argv = args[i..];
    return c;
}

/// What a --root or $H9ROOT value names (design/0013-9p-roots.md).
pub const RootArg = union(enum) {
    /// `tcp!host!port`, with `tcp!host` given port 564 (9fs).
    tcp: []const u8,
    /// `unix!path`: the socket's host path.
    unix: []const u8,
    /// A `ws://` or `wss://` URL (design/0021-websocket-9p.md).
    ws: []const u8,
    /// Anything else: a host path, a directory or a socket, which the
    /// caller tells apart with stat.
    path: []const u8,
};

/// Reads a --root value. `tcp!` and `unix!` with nothing after them, or
/// a TCP dial string with more than a host and a port, are errors.
pub fn rootArg(arena: std.mem.Allocator, arg: []const u8) error{ OutOfMemory, BadDial }!RootArg {
    if (ws.Url.is(arg)) {
        _ = ws.Url.parse(arg) catch return error.BadDial;
        return .{ .ws = arg };
    }
    if (std.mem.startsWith(u8, arg, "tcp!")) {
        const rest = arg["tcp!".len..];
        var parts = std.mem.splitScalar(u8, rest, '!');
        const host = parts.next().?;
        const port = parts.next();
        if (host.len == 0 or parts.next() != null) return error.BadDial;
        if (port) |p| {
            if (p.len == 0) return error.BadDial;
            return .{ .tcp = arg };
        }
        return .{ .tcp = try std.fmt.allocPrint(arena, "{s}!564", .{arg}) };
    }
    if (std.mem.startsWith(u8, arg, "unix!")) {
        const path = arg["unix!".len..];
        if (path.len == 0) return error.BadDial;
        return .{ .unix = path };
    }
    return .{ .path = arg };
}

fn flag(a: []const u8, comptime name: []const u8) bool {
    return std.mem.eql(u8, a, name);
}

/// A positive count, for --pids and --cpus.
fn count(v: ?[]const u8) Error!u32 {
    const n = std.fmt.parseInt(u32, v orelse return error.Usage, 10) catch return error.Usage;
    return if (n == 0) error.Usage else n;
}

fn enumValue(comptime E: type, v: ?[]const u8) Error!E {
    return std.meta.stringToEnum(E, v orelse return error.Usage) orelse error.Usage;
}

/// Matches `--name=value` or `--name value`. Returns null if args[i.*] is a
/// different flag, and a null value if the value is missing.
fn value(args: []const []const u8, i: *usize, comptime name: []const u8) ??[]const u8 {
    const a = args[i.*];
    if (std.mem.startsWith(u8, a, name ++ "=")) return a[name.len + 1 ..];
    if (!std.mem.eql(u8, a, name)) return null;
    if (i.* + 1 >= args.len) return @as(?[]const u8, null);
    i.* += 1;
    return args[i.*];
}

/// The exit code for a program's `exits` string (design/0007-go-compat.md):
/// 0 for an empty one, n for a decimal number from 1 to 255 (digits only,
/// no sign or leading zero), and 1 for anything else. `print` says whether
/// h9 writes the string to stderr, which it does only in the last case.
pub fn exitStatus(msg: []const u8) struct { code: u8, print: bool } {
    if (msg.len == 0) return .{ .code = 0, .print = false };
    numeric: {
        if (msg.len > 3 or msg[0] == '0') break :numeric;
        for (msg) |c| if (!std.ascii.isDigit(c)) break :numeric;
        const n = std.fmt.parseInt(u16, msg, 10) catch break :numeric;
        if (n > 255) break :numeric;
        return .{ .code = @intCast(n), .print = false };
    }
    return .{ .code = 1, .print = true };
}

/// The line h9 prints on a terminal when a run's changes to the root's
/// overlay are discarded (design/0011-overlay.md): the changed top-level
/// directories, and how to keep them. A 9P root keeps writes under
/// `--write=scope`, since its server decides; a host tree takes
/// `--writable` on the root.
pub fn discardNotice(buf: []u8, c: *const RootChanges, ninep: bool) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    noticeTo(&w, c, ninep) catch {};
    return w.buffered();
}

fn noticeTo(w: *std.Io.Writer, c: *const RootChanges, ninep: bool) std.Io.Writer.Error!void {
    try w.writeAll("h9: changes to the root under ");
    for (c.dirs(), 0..) |*n, i| try w.print("{s}/{s}", .{ if (i > 0) ", " else "", n.slice() });
    if (c.more) try w.writeAll(if (c.count > 0) ", ..." else "...");
    try w.print(" were discarded (rerun with {s} to keep them)", .{if (ninep) "--write=scope" else "--writable \"$H9ROOT\""});
}

const t = std.testing;

test "flags stop at the first non-flag" {
    const c = try parse(t.allocator, &.{ "h9", "--backend", "emu", "--trace", "./ls", "--trace" });
    defer t.allocator.free(c.env);
    try t.expectEqual(vmm.BackendKind.emu, c.backend);
    try t.expectEqualStrings("", c.trace.?);
    try t.expectEqual(@as(usize, 2), c.argv.len);
    try t.expectEqualStrings("--trace", c.argv[1]);
}

test "--arch" {
    try t.expectEqual(vmm.Arch.i386, (try parse(t.allocator, &.{ "h9", "--arch", "386", "/bin/echo" })).arch.?);
    try t.expectEqual(vmm.Arch.amd64, (try parse(t.allocator, &.{ "h9", "--arch=amd64", "/bin/echo" })).arch.?);
    try t.expectEqual(@as(?vmm.Arch, null), (try parse(t.allocator, &.{ "h9", "/bin/echo" })).arch);
    try t.expectError(error.Usage, parse(t.allocator, &.{ "h9", "--arch", "i386", "x" }));
    try t.expectError(error.Usage, parse(t.allocator, &.{ "h9", "--arch" }));
}

test "--backend=value and --" {
    const c = try parse(t.allocator, &.{ "h9", "--backend=hvf", "--", "--weird" });
    defer t.allocator.free(c.env);
    try t.expectEqual(vmm.BackendKind.hvf, c.backend);
    try t.expectEqualStrings("--weird", c.argv[0]);
}

test "--root-spec and --root-user" {
    const c = try parse(t.allocator, &.{ "h9", "--root", "tcp!fs!564", "--root-spec=other", "--root-user", "glenda", "ls" });
    defer t.allocator.free(c.env);
    try t.expectEqualStrings("tcp!fs!564", c.root.?);
    try t.expectEqualStrings("other", c.root_spec);
    try t.expectEqualStrings("glenda", c.root_user.?);
    const d = try parse(t.allocator, &.{ "h9", "ls" });
    defer t.allocator.free(d.env);
    try t.expectEqualStrings("", d.root_spec);
    try t.expectEqual(@as(?[]const u8, null), d.root_user);
    try t.expectError(error.Usage, parse(t.allocator, &.{ "h9", "--root-user=", "ls" }));
    try t.expectError(error.Usage, parse(t.allocator, &.{ "h9", "--root-spec" }));
}

test "--root-header and --root-ca" {
    const c = try parse(t.allocator, &.{ "h9", "--root", "wss://fs/9p", "--root-header", "Authorization: Bearer x", "--root-header=@/tmp/h", "--root-ca", "ca.pem", "ls" });
    defer t.allocator.free(c.env);
    defer t.allocator.free(c.root_headers);
    try t.expectEqual(@as(usize, 2), c.root_headers.len);
    try t.expectEqualStrings("Authorization: Bearer x", c.root_headers[0]);
    try t.expectEqualStrings("@/tmp/h", c.root_headers[1]);
    try t.expectEqualStrings("ca.pem", c.root_ca.?);
    try t.expectEqualStrings("wss://fs/9p", c.root.?);
    try t.expectError(error.Usage, parse(t.allocator, &.{ "h9", "--root-header=", "ls" }));
    try t.expectError(error.Usage, parse(t.allocator, &.{ "h9", "--root-ca" }));
}

test "rootArg reads dial strings and paths" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("tcp!fs.example!5640", (try rootArg(a, "tcp!fs.example!5640")).tcp);
    try t.expectEqualStrings("tcp!fs.example!564", (try rootArg(a, "tcp!fs.example")).tcp);
    try t.expectEqualStrings("/run/fs.sock", (try rootArg(a, "unix!/run/fs.sock")).unix);
    try t.expectEqualStrings("/r", (try rootArg(a, "/r")).path);
    try t.expectEqualStrings("tcpdir", (try rootArg(a, "tcpdir")).path);
    try t.expectEqualStrings("wss://fs.example/9p?t=1", (try rootArg(a, "wss://fs.example/9p?t=1")).ws);
    try t.expectEqualStrings("ws://127.0.0.1:8080", (try rootArg(a, "ws://127.0.0.1:8080")).ws);
    for ([_][]const u8{ "tcp!", "tcp!!564", "tcp!h!", "tcp!h!1!x", "unix!", "ws://", "wss://h:0/" }) |bad| {
        try t.expectError(error.BadDial, rootArg(a, bad));
    }
}

test "--root, --cwd and repeated --env" {
    const c = try parse(t.allocator, &.{ "h9", "--root", "/r", "--cwd=/w", "--env", "a=1", "--env=b=x=y", "cat" });
    defer t.allocator.free(c.env);
    try t.expectEqualStrings("/r", c.root.?);
    try t.expectEqualStrings("/w", c.cwd.?);
    try t.expectEqual(@as(usize, 2), c.env.len);
    try t.expectEqualStrings("b=x=y", c.env[1]);
}

test "usage errors" {
    try t.expectError(error.Usage, parse(t.allocator, &.{"h9"}));
    try t.expectError(error.Usage, parse(t.allocator, &.{ "h9", "--backend" }));
    try t.expectError(error.Usage, parse(t.allocator, &.{ "h9", "--backend", "qemu", "x" }));
    try t.expectError(error.Usage, parse(t.allocator, &.{ "h9", "--nope", "x" }));
    try t.expectError(error.Usage, parse(t.allocator, &.{ "h9", "--env", "noequals", "x" }));
    try t.expectError(error.Usage, parse(t.allocator, &.{ "h9", "--env", "=v", "x" }));
}

test "policy flags" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const c = try parse(arena.allocator(), &.{
        "h9",       "--profile=tight", "--writable",    "./out",           "--readable=/src", "--read-deny", "/src/.env",
        "--memory", "512m",            "--timeout",     "1m",              "--net=disable",   "--write",     "scope",
        "--strict", "--print",         "--trace=t.log", "--dump-on-fault", "mk",
    });
    try t.expectEqual(policy.Profile.tight, c.profile);
    try t.expectEqualStrings("./out", c.writable[0]);
    try t.expectEqualStrings("/src", c.readable[0]);
    try t.expectEqualStrings("/src/.env", c.read_deny[0]);
    try t.expectEqual(@as(?u64, 512 << 20), c.memory);
    try t.expectEqual(@as(?u64, std.time.ns_per_min), c.timeout_ns);
    try t.expectEqual(@as(?policy.NetMode, .disable), c.net);
    try t.expectEqual(@as(?policy.WriteMode, .scope), c.write);
    try t.expect(c.strict and c.print and c.dump_on_fault);
    try t.expectEqualStrings("t.log", c.trace.?);
    try t.expectEqualStrings("mk", c.argv[0]);
}

test "--net-allow is repeatable" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const c = try parse(arena.allocator(), &.{ "h9", "--net-allow", "tcp!*.example.com!443", "--net-allow=udp!10.0.0.53!53", "--net", "enable", "x" });
    try t.expectEqual(@as(usize, 2), c.net_allow.len);
    try t.expectEqualStrings("tcp!*.example.com!443", c.net_allow[0]);
    try t.expectEqualStrings("udp!10.0.0.53!53", c.net_allow[1]);
    try t.expectEqual(@as(?policy.NetMode, .enable), c.net);
    try t.expectError(error.Usage, parse(arena.allocator(), &.{ "h9", "--net-allow" }));
}

test "--sandbox and --rc" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try parse(a, &.{ "h9", "--sandbox", "/w", "--rc", "echo x > f" });
    try t.expectEqual(policy.Profile.tight, c.profile);
    try t.expectEqualStrings("/w", c.sandbox.?);
    try t.expectEqualStrings("echo x > f", c.rc.?);
    try t.expectEqual(@as(usize, 0), c.argv.len);
    try t.expectError(error.Usage, parse(a, &.{ "h9", "--sandbox", "/w", "--host-fs", "ls" }));
    try t.expectError(error.Usage, parse(a, &.{ "h9", "--sandbox", "/w", "--host-cmd", "ls" }));
    try t.expectError(error.Usage, parse(a, &.{ "h9", "--memory", "lots", "ls" }));
    try t.expectError(error.Usage, parse(a, &.{ "h9", "--timeout", "0", "ls" }));
    try t.expectError(error.Usage, parse(a, &.{ "h9", "--write", "maybe", "ls" }));
}

test "--no-guest-tools" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expect((try parse(a, &.{ "h9", "ls" })).guest_tools);
    try t.expect(!(try parse(a, &.{ "h9", "--no-guest-tools", "ls" })).guest_tools);
}

test "--gfx, --gfx=noclip and --gfx-scale" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const off = try parse(a.allocator(), &.{ "h9", "rio" });
    try std.testing.expect(off.gfx == null);
    const on = try parse(a.allocator(), &.{ "h9", "--gfx", "rio" });
    try std.testing.expectEqual(gfx.Options{}, on.gfx.?);
    try std.testing.expectEqualStrings("rio", on.argv[0]);
    const noclip = try parse(a.allocator(), &.{ "h9", "--gfx=noclip", "--gfx-scale", "0", "rio" });
    try std.testing.expectEqual(gfx.Options{ .clipboard = false, .scale = 0 }, noclip.gfx.?);
    const scaled = try parse(a.allocator(), &.{ "h9", "--gfx-scale=2", "--gfx", "rio" });
    try std.testing.expectEqual(gfx.Options{ .scale = 2 }, scaled.gfx.?);
    for ([_][]const []const u8{
        &.{ "h9", "--gfx=yes", "rio" },
        &.{ "h9", "--gfx-scale", "2", "rio" },
        &.{ "h9", "--gfx", "--gfx-scale", "x", "rio" },
        &.{ "h9", "--gfx", "--gfx-scale", "256", "rio" },
    }) |args| try std.testing.expectError(error.Usage, parse(a.allocator(), args));
}

test "--pids, --cpus and --ns" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try parse(a, &.{ "h9", "--pids", "32", "--cpus=2", "--ns", "ns", "rc" });
    try t.expectEqual(@as(?u32, 32), c.pids);
    try t.expectEqual(@as(?u32, 2), c.cpus);
    try t.expectEqualStrings("ns", c.ns.?);
    try t.expectError(error.Usage, parse(a, &.{ "h9", "--pids", "0", "rc" }));
    try t.expectError(error.Usage, parse(a, &.{ "h9", "--cpus", "x", "rc" }));
    try t.expectError(error.Usage, parse(a, &.{ "h9", "--ns" }));
}

test "--check and --version" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqual(Mode.version, (try parse(a, &.{ "h9", "--version" })).mode);
    const c = try parse(a, &.{ "h9", "--backend", "emu", "--root=/r", "--check" });
    try t.expectEqual(Mode.check, c.mode);
    try t.expectEqual(vmm.BackendKind.emu, c.backend);
    try t.expectEqualStrings("/r", c.root.?);
    try t.expectEqual(Mode.run, (try parse(a, &.{ "h9", "ls" })).mode);
    // A flag after the program is the program's.
    try t.expectEqual(Mode.run, (try parse(a, &.{ "h9", "ls", "--version" })).mode);
    try t.expectError(error.Usage, parse(a, &.{ "h9", "--check", "ls" }));
    try t.expectError(error.Usage, parse(a, &.{ "h9", "--version", "--rc", "ls" }));
    try t.expectError(error.Usage, parse(a, &.{ "h9", "--check", "--version" }));
}

test "--help and -h" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqual(Mode.help, (try parse(a, &.{ "h9", "--help" })).mode);
    try t.expectEqual(Mode.help, (try parse(a, &.{ "h9", "-h" })).mode);
    // -h counts only alone; anywhere else it's a program name or argument.
    try t.expectEqualStrings("-h", (try parse(a, &.{ "h9", "--backend", "emu", "-h" })).argv[0]);
    const c = try parse(a, &.{ "h9", "ls", "-h" });
    try t.expectEqual(Mode.run, c.mode);
    try t.expectEqualStrings("-h", c.argv[1]);
    try t.expectError(error.Usage, parse(a, &.{ "h9", "--help", "ls" }));
}

test "program kinds" {
    try t.expectEqual(ProgramKind.host, programKind("./hello"));
    try t.expectEqual(ProgramKind.host, programKind("../out/x"));
    try t.expectEqual(ProgramKind.guest, programKind("/bin/cat"));
    try t.expectEqual(ProgramKind.guest, programKind("cat"));
    try t.expectEqual(ProgramKind.guest, programKind("aux/vga"));
}

test "exits strings to exit codes" {
    const cases = [_]struct { []const u8, u8, bool }{
        .{ "", 0, false },
        .{ "3", 3, false },
        .{ "1", 1, false },
        .{ "125", 125, false },
        .{ "255", 255, false },
        .{ "0", 1, true },
        .{ "03", 1, true },
        .{ "256", 1, true },
        .{ "1000", 1, true },
        .{ "-1", 1, true },
        .{ "+3", 1, true },
        .{ " 3", 1, true },
        .{ "3 ", 1, true },
        .{ "failed", 1, true },
    };
    for (cases) |c| {
        const s = exitStatus(c[0]);
        try t.expectEqual(c[1], s.code);
        try t.expectEqual(c[2], s.print);
    }
}

test "the discarded-changes notice names the top-level directories" {
    var rc: RootChanges = .{};
    rc.note("usr/glenda/lib/profile", "usr/glenda");
    try t.expect(rc.home and !rc.changed);
    rc.note("386/bin/cat", "usr/glenda");
    rc.note("lib/x", "usr/glenda");
    rc.note("386/lib", "usr/glenda");
    rc.note("usr/glendax", "usr/glenda");
    try t.expect(rc.changed);
    var buf: [512]u8 = undefined;
    try t.expectEqualStrings("h9: changes to the root under /386, /lib, /usr were discarded (rerun with --writable \"$H9ROOT\" to keep them)", discardNotice(&buf, &rc, false));
    try t.expectEqualStrings("h9: changes to the root under /386, /lib, /usr were discarded (rerun with --write=scope to keep them)", discardNotice(&buf, &rc, true));
    var many: RootChanges = .{};
    var nb: [8]u8 = undefined;
    for (0..RootChanges.max_names + 2) |i| many.note(try std.fmt.bufPrint(&nb, "d{d}/x", .{i}), "");
    try t.expect(many.more);
    try t.expectEqual(@as(usize, RootChanges.max_names), many.dirs().len);
    try t.expect(std.mem.endsWith(u8, discardNotice(&buf, &many, false), "/d9, ... were discarded (rerun with --writable \"$H9ROOT\" to keep them)"));
}
