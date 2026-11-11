//! Command-line parsing: argv to a Config, with no I/O. See SPEC.md, "CLI".

const std = @import("std");
const builtin = @import("builtin");
const vmm = @import("h9").vmm;
const policy = @import("h9").policy;
const ws = @import("h9").ws;
const RootChanges = @import("h9").RootChanges;
const gfx = @import("h9").gfx;
const serve = @import("h9").serve;

pub const usage =
    \\usage: h9 [--backend auto|hvf|kvm|whp|native|emu] [--arch arm64|amd64|386]
    \\           [--root DIR|DIAL|SOCKET|URL] [--root-spec NAME] [--root-user NAME]
    \\           [--root-header 'NAME: VALUE'|@FILE]... [--root-ca FILE] [--cwd DIR]
    \\           [--env name=value]... [--profile default|tight] [--sandbox DIR]
    \\           [--readable PATH]... [--writable PATH]... [--read-deny PATH]...
    \\           [--write none|scope|ephemeral|overlay] [--net disable|outbound|enable]
    \\           [--net-allow PATTERN]... [--root-contained] [--user-map FILE]
    \\           [--builtin auto|only|before|after|off]
    \\           [--memory SIZE] [--timeout DURATION] [--pids N] [--cpus N]
    \\           [--ns FILE] [--host-fs] [--host-cmd] [--no-guest-tools]
    \\           [--gfx[=noclip]] [--gfx-scale N]
    \\           [--serve unix!PATH|tcp!HOST!PORT|ws://HOST:PORT[/PATH]]...
    \\           [--serve-root PATH] [--serve-token @FILE] [--serve-origin ORIGIN]...
    \\           [--serve-net]
    \\           [--strict] [--print] [--trace[=FILE]] [--dump-on-fault]
    \\           [--] program [args...]
    \\       h9 [flags] --rc 'command' [args...]
    \\       h9 [flags] --rc
    \\       h9 [flags] --serve ADDR...
    \\       h9 [--backend B] [--root DIR|DIAL|SOCKET|URL] [--builtin MODE] [--memory SIZE] --check
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

/// --builtin (design/builtin-root.md): how the built-in root takes part.
/// `auto` is `only` when no root is found and `off` otherwise; the rest
/// are `policy.Builtin`'s.
pub const BuiltinMode = enum { auto, only, before, after, off };

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
    /// A second --root, for a machine with a 9front and a Linux root
    /// (design/linux-personality.md, "CLI and API").
    root2: ?[]const u8 = null,
    /// --root-spec: the attach name sent to a 9P root.
    root_spec: []const u8 = "",
    /// --root-user: the uname sent in attaches to a 9P root.
    root_user: ?[]const u8 = null,
    /// --root-header values as given: `Name: value`, or `@FILE` for a host
    /// file of them (design/websocket-9p.md).
    root_headers: []const []const u8 = &.{},
    /// --root-ca: PEM certificates a wss:// root must chain to.
    root_ca: ?[]const u8 = null,
    /// --user-map: a passwd file mapping names to the numbers a 9P2000.L
    /// server sees (design/dotl.md).
    user_map: ?[]const u8 = null,
    /// --root-contained: the root tree's symlinks resolve inside it
    /// (design/symlinks-in-root.md).
    root_contained: bool = false,
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
    /// (design/guest-tools.md).
    guest_tools: bool = true,
    /// --builtin.
    builtin: BuiltinMode = .auto,
    /// --gfx, --gfx=noclip and --gfx-scale: a host window
    /// (design/gfx.md); null without --gfx.
    gfx: ?gfx.Options = null,
    strict: bool = false,
    print: bool = false,
    /// --serve addresses, checked (design/serve.md).
    serve: []const []const u8 = &.{},
    /// --serve-root: the guest path each connection exports.
    serve_root: ?[]const u8 = null,
    /// --serve-token: `@FILE`, the token's host file.
    serve_token: ?[]const u8 = null,
    /// --serve-origin values.
    serve_origins: []const []const u8 = &.{},
    /// --serve-net: export /net too.
    serve_net: bool = false,
    /// --rc: the command line for /bin/rc -c.
    rc: ?[]const u8 = null,
    /// --rc as the last argument: a login rc, which runs the root's
    /// /rc/lib/rcmain.local, its default command
    /// (design/default-command.md).
    rc_login: bool = false,
    /// The program followed by its arguments; with --rc, the arguments
    /// that become $*.
    argv: []const []const u8,
};

pub const Error = error{ Usage, OutOfMemory };

/// How a program argument is found (SPEC.md, "Program resolution").
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
    var serve_addrs: std.ArrayList([]const u8) = .empty;
    var serve_origins: std.ArrayList([]const u8) = .empty;
    var gfx_scale: ?u8 = null;
    // Long flags only (SPEC.md, "Parsing rules"); -h is accepted alone,
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
        } else if (flag(a, "--serve-net")) {
            c.serve_net = true;
        } else if (value(args, &i, "--serve-root")) |v| {
            const r = v orelse return error.Usage;
            if (r.len == 0 or r[0] != '/') return error.Usage;
            c.serve_root = r;
        } else if (value(args, &i, "--serve-token")) |v| {
            // Only from a file, so the token isn't in the process listing.
            const tok = v orelse return error.Usage;
            if (tok.len < 2 or tok[0] != '@') return error.Usage;
            c.serve_token = tok;
        } else if (value(args, &i, "--serve-origin")) |v| {
            const o = v orelse return error.Usage;
            if (o.len == 0) return error.Usage;
            try serve_origins.append(gpa, o);
        } else if (value(args, &i, "--serve")) |v| {
            const addr = v orelse return error.Usage;
            _ = serve.Listen.parse(addr) catch return error.Usage;
            try serve_addrs.append(gpa, addr);
        } else if (flag(a, "--root-contained")) {
            c.root_contained = true;
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
        } else if (value(args, &i, "--user-map")) |v| {
            c.user_map = v orelse return error.Usage;
            if (c.user_map.?.len == 0) return error.Usage;
        } else if (value(args, &i, "--root-ca")) |v| {
            c.root_ca = v orelse return error.Usage;
            if (c.root_ca.?.len == 0) return error.Usage;
        } else if (value(args, &i, "--root")) |v| {
            const r = v orelse return error.Usage;
            // The last two count: one may be a 9front tree and one a Linux
            // tree, and a later one of a kind replaces an earlier one.
            if (c.root == null) c.root = r else if (c.root2 == null) c.root2 = r else {
                c.root = c.root2;
                c.root2 = r;
            }
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
        } else if (value(args, &i, "--builtin")) |v| {
            c.builtin = try enumValue(BuiltinMode, v);
        } else if (value(args, &i, "--rc")) |v| {
            // With no value, --rc is the last argument: a login rc.
            c.rc = v;
            c.rc_login = v == null;
        } else {
            return error.Usage;
        }
    }
    // --gfx-scale is the window's, so it needs one.
    if (gfx_scale) |n| {
        if (c.gfx == null) return error.Usage;
        c.gfx.?.scale = n;
    }
    // --builtin=only is the root, so another can't be named.
    if (c.builtin == .only and c.root != null) return error.Usage;
    if (c.sandbox != null) {
        if (c.host_fs or c.host_cmd or c.cwd != null) return error.Usage;
        c.profile = .tight;
    }
    // The --serve flags apply to a --serve (design/serve.md), and
    // any origin needs the token, or every page could mount the machine.
    const serving = serve_addrs.items.len > 0;
    if (!serving and (c.serve_root != null or c.serve_token != null or serve_origins.items.len > 0 or c.serve_net)) return error.Usage;
    for (serve_origins.items) |o| if (std.mem.eql(u8, o, "*") and c.serve_token == null) return error.Usage;
    // The tool functions take no program, so `h9 --check ls` is a mistake.
    // No program is a run that only serves, with --serve.
    const rc = c.rc != null or c.rc_login;
    if (c.mode != .run) {
        if (rc or i < args.len or serving) return error.Usage;
    } else if (!rc and i >= args.len and !serving) return error.Usage;
    c.serve = try serve_addrs.toOwnedSlice(gpa);
    c.serve_origins = try serve_origins.toOwnedSlice(gpa);
    c.env = try env.toOwnedSlice(gpa);
    c.readable = try readable.toOwnedSlice(gpa);
    c.writable = try writable.toOwnedSlice(gpa);
    c.read_deny = try read_deny.toOwnedSlice(gpa);
    c.net_allow = try net_allow.toOwnedSlice(gpa);
    c.root_headers = try root_headers.toOwnedSlice(gpa);
    c.argv = args[i..];
    return c;
}

/// What a --root or $H9ROOT value names (design/9p-roots.md).
pub const RootArg = union(enum) {
    /// `tcp!host!port`, with `tcp!host` given port 564 (9fs).
    tcp: []const u8,
    /// `unix!path`: the socket's host path.
    unix: []const u8,
    /// A `ws://` or `wss://` URL (design/websocket-9p.md).
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

/// The URL a --root value without a scheme names
/// (design/schemeless-roots.md), or null if it isn't shaped like
/// one: `host[:port][/path][?query]`, where the host is `localhost`, a
/// dotted name, or a bracketed IPv6 address, or there's a port. A
/// loopback host (`localhost`, 127.0.0.0/8, `[::1]`) is `ws://`, any
/// other `wss://`. The caller tries the value as a host path first.
pub fn schemelessRoot(arena: std.mem.Allocator, arg: []const u8) error{OutOfMemory}!?[]const u8 {
    if (arg.len == 0) return null;
    switch (arg[0]) {
        '.', '/', '~', '-' => return null,
        else => {},
    }
    for (arg) |c| switch (c) {
        '\\', '!', '@' => return null,
        else => if (c <= ' ' or c == 0x7f) return null,
    };
    const end = std.mem.indexOfAny(u8, arg, "/?#") orelse arg.len;
    const authority = arg[0..end];
    var host = authority;
    var has_port = false;
    if (authority.len > 0 and authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return null;
        host = authority[1..close];
        if (host.len == 0) return null;
        for (host) |c| if (!std.ascii.isHex(c) and c != ':' and c != '.') return null;
        const after = authority[close + 1 ..];
        if (after.len > 0) {
            if (after[0] != ':') return null;
            has_port = true;
        }
    } else {
        if (std.mem.indexOfScalar(u8, authority, ':')) |colon| {
            host = authority[0..colon];
            has_port = true;
        }
        if (!hostName(host)) return null;
        if (!has_port and !std.ascii.eqlIgnoreCase(host, "localhost") and std.mem.indexOfScalar(u8, host, '.') == null) return null;
    }
    const scheme = if (loopback(host)) "ws://" else "wss://";
    const slash = if (end == arg.len) "/" else "";
    const url = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ scheme, arg, slash });
    _ = ws.Url.parse(url) catch return null;
    return url;
}

/// Letters, digits, `-`, and `.`, with no empty label and no label that
/// starts or ends with `-`.
fn hostName(h: []const u8) bool {
    if (h.len == 0) return false;
    var labels = std.mem.splitScalar(u8, h, '.');
    while (labels.next()) |l| {
        if (l.len == 0 or l.len > 63 or l[0] == '-' or l[l.len - 1] == '-') return false;
        for (l) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    }
    return true;
}

/// A literal loopback host: `localhost`, an IPv4 address in 127.0.0.0/8,
/// or `::1`. Names aren't resolved, so the scheme never depends on DNS.
fn loopback(h: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(h, "localhost")) return true;
    if (std.mem.eql(u8, h, "::1") or std.mem.eql(u8, h, "0:0:0:0:0:0:0:1")) return true;
    const a = std.Io.net.Ip4Address.parse(h, 0) catch return false;
    return a.bytes[0] == 127;
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

/// A host exit code, and whether h9 prints the message behind it.
pub const Exit = struct { code: u8, print: bool };

/// The exit code for a program's `exits` string (design/go-compat.md):
/// 0 for an empty one, n for a decimal number from 1 to 255 (digits only,
/// no sign or leading zero), and 1 for anything else. `print` says whether
/// h9 writes the string to stderr, which it does only in the last case.
pub fn exitStatus(msg: []const u8) Exit {
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

/// Signals by name, in Linux's order on x86 and arm, so a Linux signal
/// number N is the field with value N.
pub const Signal = enum(u8) {
    HUP = 1,
    INT,
    QUIT,
    ILL,
    TRAP,
    ABRT,
    BUS,
    FPE,
    KILL,
    USR1,
    SEGV,
    USR2,
    PIPE,
    ALRM,
    TERM,
    STKFLT,
    CHLD,
    CONT,
    STOP,
    TSTP,
    TTIN,
    TTOU,
    URG,
    XCPU,
    XFSZ,
    VTALRM,
    PROF,
    WINCH,
    IO,
    PWR,
    SYS,

    /// The host's number for the signal, as a host shell decodes an exit
    /// status of 128+N, or null if the host has no such signal. Windows has
    /// no signals to speak of, and Git Bash and MSYS expect Linux's numbers.
    pub fn host(s: Signal) ?u8 {
        return hostNumber(builtin.os.tag, s);
    }

    fn hostNumber(comptime os: std.Target.Os.Tag, s: Signal) ?u8 {
        // The web host's runtime gives no signal numbers of its own; Linux's
        // match macOS's for the signals that stop a machine (HUP, INT, TERM).
        if (os == .windows or os == .wasi) return @intFromEnum(s);
        const SIG = std.posix.SIG;
        switch (s) {
            inline else => |tag| {
                const name = @tagName(tag);
                if (!@hasField(SIG, name)) return null;
                return @intCast(@intFromEnum(@field(SIG, name)));
            },
        }
    }

    pub fn fromLinux(n: u32) ?Signal {
        return std.enums.fromInt(Signal, n);
    }
};

/// APE's `sigtab` (/sys/src/ape/lib/ap/plan9/signal.c in the pinned
/// 9front), in its order: a note that starts with `msg` is signal `sig`, as
/// APE's `wait` and note handler decide. The test below checks it against
/// the pinned source when it's been fetched.
pub const sigtab = [_]struct { msg: []const u8, sig: Signal }{
    .{ .msg = "hangup", .sig = .HUP },
    .{ .msg = "interrupt", .sig = .INT },
    .{ .msg = "quit", .sig = .QUIT },
    .{ .msg = "alarm", .sig = .ALRM },
    .{ .msg = "sys: trap: illegal instruction", .sig = .ILL },
    .{ .msg = "sys: trap: reserved instruction", .sig = .ILL },
    .{ .msg = "sys: trap: reserved", .sig = .ILL },
    .{ .msg = "sys: trap: arithmetic overflow", .sig = .FPE },
    .{ .msg = "abort", .sig = .ABRT },
    .{ .msg = "sys: fp:", .sig = .FPE },
    .{ .msg = "exit", .sig = .KILL },
    .{ .msg = "die", .sig = .KILL },
    .{ .msg = "kill", .sig = .KILL },
    .{ .msg = "sys: trap: bus error", .sig = .SEGV },
    .{ .msg = "sys: trap: address error", .sig = .SEGV },
    .{ .msg = "sys: trap: TLB", .sig = .SEGV },
    .{ .msg = "sys: write on closed pipe", .sig = .PIPE },
    .{ .msg = "term", .sig = .TERM },
    .{ .msg = "usr1", .sig = .USR1 },
    .{ .msg = "usr2", .sig = .USR2 },
    .{ .msg = "virtual alarm", .sig = .VTALRM },
    .{ .msg = "profiling alarm", .sig = .PROF },
};

/// The signal APE's `sigtab` maps a note to, by prefix, or null.
pub fn noteSignal(note: []const u8) ?Signal {
    for (sigtab) |e| if (std.mem.startsWith(u8, note, e.msg)) return e.sig;
    return null;
}

/// The exit code for a first process killed by a note
/// (design/exit-status.md). `stopped_by` is the host signal that started a
/// teardown, for `h9: machine stopped`. `print` says whether h9 writes
/// `h9: prog: note` to stderr: always, except for an interrupt or a
/// closed pipe, which shells don't report either.
pub fn killedStatus(note: []const u8, stopped_by: ?Signal) Exit {
    const exit_timeout = 124;
    const exit_failed = 125;
    if (std.mem.eql(u8, note, "h9: timeout")) return .{ .code = exit_timeout, .print = true };
    if (std.mem.eql(u8, note, "h9: machine stopped")) {
        // Stopped with no host signal to blame: an embedder's or h9's own
        // stop, so h9's failure.
        const s = stopped_by orelse return .{ .code = exit_failed, .print = true };
        return .{ .code = signalCode(s) orelse 1, .print = true };
    }
    // h9's or the hypervisor's failures, not the guest's (src/machine.zig).
    if (std.mem.eql(u8, note, "halted") or
        std.mem.startsWith(u8, note, "sys: trap: unexpected exit") or
        std.mem.startsWith(u8, note, "h9: "))
        return .{ .code = exit_failed, .print = true };
    // The Linux personality's notes (design/linux-personality.md).
    if (std.mem.startsWith(u8, note, "linux: signal ")) {
        const n = std.fmt.parseInt(u32, note["linux: signal ".len..], 10) catch return .{ .code = 1, .print = true };
        const s = Signal.fromLinux(n) orelse return .{ .code = 1, .print = true };
        return signalStatus(s);
    }
    if (noteSignal(note)) |s| return signalStatus(s);
    // A fault sigtab doesn't name: what a crashed program usually reports.
    // (sigtab already has `sys: fp:`.)
    if (std.mem.startsWith(u8, note, "sys: trap: ") or
        std.mem.startsWith(u8, note, "sys: bad address"))
        return signalStatus(.SEGV);
    return .{ .code = 1, .print = true };
}

fn signalCode(s: Signal) ?u8 {
    const n = s.host() orelse return null;
    return 128 + n;
}

fn signalStatus(s: Signal) Exit {
    return .{ .code = signalCode(s) orelse 1, .print = s != .INT and s != .PIPE };
}

/// The line h9 prints on a terminal when a run's changes to the root's
/// overlay are discarded (design/overlay.md): the changed top-level
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

test "--root-contained" {
    const c = try parse(t.allocator, &.{ "h9", "--root", "/tree", "--root-contained", "ls" });
    defer t.allocator.free(c.env);
    try t.expect(c.root_contained);
    const d = try parse(t.allocator, &.{ "h9", "ls" });
    defer t.allocator.free(d.env);
    try t.expect(!d.root_contained);
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

test "schemelessRoot reads host/path as wss:// and leaves paths alone" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][2][]const u8{
        .{ "fs.example.com/9p", "wss://fs.example.com/9p" },
        .{ "fs.example.com", "wss://fs.example.com/" },
        .{ "fs.example.com:8443", "wss://fs.example.com:8443/" },
        .{ "fs.example.com/9p?t=1", "wss://fs.example.com/9p?t=1" },
        .{ "fs.example.com?t=1", "wss://fs.example.com?t=1" },
        .{ "10.0.0.5/9p", "wss://10.0.0.5/9p" },
        .{ "fs:8443/9p", "wss://fs:8443/9p" },
        .{ "[2001:db8::1]:8443/9p", "wss://[2001:db8::1]:8443/9p" },
        .{ "localhost:8080/9p", "ws://localhost:8080/9p" },
        .{ "localhost/9p", "ws://localhost/9p" },
        .{ "LOCALHOST", "ws://LOCALHOST/" },
        .{ "127.0.0.1:8080/9p", "ws://127.0.0.1:8080/9p" },
        .{ "127.1.2.3/9p", "ws://127.1.2.3/9p" },
        .{ "[::1]:8080/9p", "ws://[::1]:8080/9p" },
        .{ "localhost.example.com/9p", "wss://localhost.example.com/9p" },
    };
    for (cases) |c| {
        const got = (try schemelessRoot(a, c[0])) orelse return error.TestExpectedUrl;
        try t.expectEqualStrings(c[1], got);
    }
    for ([_][]const u8{
        "",               "root",          "root/9p",       "dist/root",     "./9front.img", "../r",
        "/abs/root",      "~/root",        "-x.y",          ".local/9front", "C:\\root",     "C:/root",
        "tcp!h.x!564",    "u@fs.example",  "fs .example/x", "fs..example/x", "-fs.example",  "fs-.example/x",
        "fs.example:0/x", "fs.example:x/", "[::1/x",        "[]:80/",        "[::1]x/",      "fs_x.example/",
    }) |bad| {
        if (try schemelessRoot(a, bad)) |u| {
            std.debug.print("{s} -> {s}\n", .{ bad, u });
            return error.TestUnexpectedUrl;
        }
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

test "--rc alone is a login rc" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const login = try parse(a, &.{ "h9", "--root", "r", "--rc" });
    try t.expect(login.rc_login);
    try t.expectEqual(@as(?[]const u8, null), login.rc);
    try t.expectEqual(@as(usize, 0), login.argv.len);
    // --rc= is an empty command line, not a login rc.
    const empty = try parse(a, &.{ "h9", "--rc=" });
    try t.expect(!empty.rc_login);
    try t.expectEqualStrings("", empty.rc.?);
    // --rc takes the next argument as its value, wherever it is.
    const flag_cmd = try parse(a, &.{ "h9", "--rc", "--root", "x" });
    try t.expect(!flag_cmd.rc_login);
    try t.expectEqualStrings("--root", flag_cmd.rc.?);
    try t.expectEqualStrings("x", flag_cmd.argv[0]);
    // The last --rc wins.
    const last = try parse(a, &.{ "h9", "--rc", "ls", "--rc" });
    try t.expect(last.rc_login);
    try t.expectEqual(@as(?[]const u8, null), last.rc);
    try t.expectError(error.Usage, parse(a, &.{ "h9", "--check", "--rc" }));
}

test "--no-guest-tools" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expect((try parse(a, &.{ "h9", "ls" })).guest_tools);
    try t.expect(!(try parse(a, &.{ "h9", "--no-guest-tools", "ls" })).guest_tools);
}

test "--builtin [builtin-root]" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqual(BuiltinMode.auto, (try parse(a, &.{ "h9", "ls" })).builtin);
    try t.expectEqual(BuiltinMode.only, (try parse(a, &.{ "h9", "--builtin=only", "ls" })).builtin);
    try t.expectEqual(BuiltinMode.before, (try parse(a, &.{ "h9", "--builtin", "before", "--root", "/r", "ls" })).builtin);
    try t.expectEqual(BuiltinMode.off, (try parse(a, &.{ "h9", "--builtin=off", "--check" })).builtin);
    try t.expectError(error.Usage, parse(a, &.{ "h9", "--builtin=only", "--root", "/r", "ls" }));
    try t.expectError(error.Usage, parse(a, &.{ "h9", "--root", "/r", "--builtin", "only", "ls" }));
    try t.expectError(error.Usage, parse(a, &.{ "h9", "--builtin=always", "ls" }));
    try t.expectError(error.Usage, parse(a, &.{ "h9", "--builtin" }));
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

test "--serve and its flags [serve]" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try parse(a, &.{ "h9", "--serve", "unix!/tmp/h9.sock", "--serve=tcp!127.0.0.1!0", "--serve-root", "/usr", "--serve-net", "ls" });
    try t.expectEqual(@as(usize, 2), c.serve.len);
    try t.expectEqualStrings("tcp!127.0.0.1!0", c.serve[1]);
    try t.expectEqualStrings("/usr", c.serve_root.?);
    try t.expect(c.serve_net);
    try t.expectEqualStrings("ls", c.argv[0]);
    // No program serves only; without --serve it's still an error.
    const only = try parse(a, &.{ "h9", "--serve", "ws://127.0.0.1:8080/9p", "--serve-token", "@tok", "--serve-origin", "*", "--serve-origin", "https://app.example" });
    try t.expectEqual(@as(usize, 0), only.argv.len);
    try t.expectEqualStrings("@tok", only.serve_token.?);
    try t.expectEqual(@as(usize, 2), only.serve_origins.len);
    try t.expectError(error.Usage, parse(a, &.{"h9"}));
    for ([_][]const []const u8{
        &.{ "h9", "--serve", "/tmp/sock", "ls" },
        &.{ "h9", "--serve", "wss://h:1/", "ls" },
        &.{ "h9", "--serve", "ws://:8080/", "ls" },
        &.{ "h9", "--serve-root", "/", "ls" },
        &.{ "h9", "--serve-net", "ls" },
        &.{ "h9", "--serve-token", "@f", "ls" },
        &.{ "h9", "--serve-origin", "https://x", "ls" },
        &.{ "h9", "--serve", "tcp!h!1", "--serve-token", "plain", "ls" },
        &.{ "h9", "--serve", "tcp!h!1", "--serve-origin", "*", "ls" },
        &.{ "h9", "--serve", "tcp!h!1", "--serve-root", "rel", "ls" },
        &.{ "h9", "--serve", "tcp!h!1", "--check" },
    }) |bad| try t.expectError(error.Usage, parse(a, bad));
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

test "notes that kill the first process to exit codes" {
    const linux = builtin.os.tag == .linux or builtin.os.tag == .windows;
    const cases = [_]struct { []const u8, ?Signal, u8, bool }{
        // sigtab, with nothing printed for interrupt and a closed pipe.
        .{ "interrupt", null, 130, false },
        .{ "sys: write on closed pipe pc=0x1234", null, 141, false },
        .{ "hangup", null, 129, true },
        .{ "term", null, 143, true },
        .{ "kill", null, 137, true },
        .{ "die", null, 137, true },
        .{ "alarm", null, 142, true },
        .{ "abort", null, 134, true },
        .{ "sys: trap: illegal instruction pc=0x10", null, 132, true },
        .{ "sys: fp: divide by zero pc=0x10", null, 136, true },
        .{ "usr1", null, if (linux) 138 else 158, true },
        .{ "usr2", null, if (linux) 140 else 159, true },
        // Other faults are SIGSEGV.
        .{ "sys: trap: fault read addr=0x0 pc=0x1000", null, 139, true },
        .{ "sys: trap: misaligned pc pc=0x1001", null, 139, true },
        .{ "sys: bad address in syscall pc=0x1000", null, 139, true },
        // h9's own.
        .{ "h9: timeout", null, 124, true },
        .{ "h9: timeout", .INT, 124, true },
        .{ "h9: machine stopped", .INT, 130, true },
        .{ "h9: machine stopped", .HUP, 129, true },
        .{ "h9: machine stopped", .TERM, 143, true },
        .{ "h9: machine stopped", null, 125, true },
        .{ "halted", null, 125, true },
        .{ "sys: trap: unexpected exit 0x5 pc=0x1000", null, 125, true },
        .{ "h9: OutOfMemory", null, 125, true },
        // The Linux personality's, by name on the host.
        .{ "linux: signal 2", null, 130, false },
        .{ "linux: signal 13", null, 141, false },
        .{ "linux: signal 9", null, 137, true },
        .{ "linux: signal 7", null, if (linux) 135 else 138, true },
        .{ "linux: signal 10", null, if (linux) 138 else 158, true },
        .{ "linux: signal 16", null, if (linux) 144 else 1, true },
        .{ "linux: signal 0", null, 1, true },
        .{ "linux: signal 64", null, 1, true },
        .{ "linux: signal x", null, 1, true },
        // Anything else is a message.
        .{ "something", null, 1, true },
        .{ "", null, 1, true },
        .{ "Killed", null, 1, true },
        .{ "h9", null, 1, true },
    };
    for (cases) |c| {
        errdefer std.debug.print("note {s}\n", .{c[0]});
        const s = killedStatus(c[0], c[1]);
        try t.expectEqual(c[2], s.code);
        try t.expectEqual(c[3], s.print);
    }
}

test "host signal numbers" {
    if (builtin.os.tag.isDarwin()) {
        try t.expectEqual(@as(?u8, 10), Signal.BUS.host());
        try t.expectEqual(@as(?u8, 30), Signal.USR1.host());
        try t.expectEqual(@as(?u8, null), Signal.STKFLT.host());
    } else if (builtin.os.tag == .linux) {
        try t.expectEqual(@as(?u8, 7), Signal.BUS.host());
        try t.expectEqual(@as(?u8, 10), Signal.USR1.host());
    }
    // Windows uses Linux's numbers, wherever the test runs.
    try t.expectEqual(@as(?u8, 7), Signal.hostNumber(.windows, .BUS));
    try t.expectEqual(@as(?Signal, .SYS), Signal.fromLinux(31));
    try t.expectEqual(@as(?Signal, null), Signal.fromLinux(32));
}

test "sigtab matches the pinned 9front's" {
    // Fetched by scripts/fetch.sh; zig build test runs from the repo root.
    const io = t.io;
    const src = std.Io.Dir.cwd().readFileAlloc(io, ".local/src/9front/sys/src/ape/lib/ap/plan9/signal.c", t.allocator, .limited(1 << 20)) catch return error.SkipZigTest;
    defer t.allocator.free(src);
    const start = std.mem.indexOf(u8, src, "} sigtab[] = {") orelse return error.TestUnexpectedResult;
    const end = std.mem.indexOfPos(u8, src, start, "};") orelse return error.TestUnexpectedResult;
    var lines = std.mem.tokenizeScalar(u8, src[start..end], '\n');
    _ = lines.next();
    var i: usize = 0;
    while (lines.next()) |line| {
        const q0 = std.mem.indexOfScalar(u8, line, '"') orelse continue;
        const q1 = std.mem.indexOfScalarPos(u8, line, q0 + 1, '"') orelse return error.TestUnexpectedResult;
        const sig = std.mem.trim(u8, line[q1 + 1 ..], ", \t}");
        try t.expect(i < sigtab.len);
        try t.expectEqualStrings(line[q0 + 1 .. q1], sigtab[i].msg);
        var nb: [16]u8 = undefined;
        try t.expectEqualStrings(sig, try std.fmt.bufPrint(&nb, "SIG{t}", .{sigtab[i].sig}));
        i += 1;
    }
    try t.expectEqual(sigtab.len, i);
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
