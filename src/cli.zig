//! Command-line parsing: argv to a Config, with no I/O. See SPEC.md, "CLI".

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("h9").engine;
const policy = @import("h9").policy;
const ws = @import("h9").ws;
const RootChanges = @import("h9").RootChanges;
const gfx = @import("h9").gfx;
const serve = @import("h9").serve;
const cred = @import("h9").cred;
const mount = @import("h9").policy.mount;

/// Why the last `parse` failed, when there's more to say than the usage:
/// a mount flag's mistake, or a removed flag's replacement.
pub var why: []const u8 = "";

pub const usage =
    \\usage: h9 [--engine auto|hvf|kvm|whp|sud|hcpu] [--arch arm64|amd64|386]
    \\           [--dir PATH[:DST[:OPTS]]]... [--url URL[:DST[:OPTS]]]...
    \\           [--archive FILE[:DST[:OPTS]]]... [--builtin[=DST[:OPTS]]]...
    \\           [--tmp DST[:OPTS]]... [--bind SRC:DST[:OPTS]]... [--cwd DIR]
    \\           [--cred 'PATTERN=COMMAND']... [--index auto|none] [--index-cache DIR]
    \\           [--env name=value]... [--profile default|tight] [--sandbox DIR]
    \\           [--readable PATH]... [--writable PATH]... [--read-deny PATH]...
    \\           [--write none|scope|ephemeral|overlay] [--net disable|outbound|enable]
    \\           [--net-allow PATTERN]... [--user-map FILE]
    \\           [--memory SIZE] [--timeout DURATION] [--pids N] [--cpus N]
    \\           [--ns 'LINE; LINE'|@FILE]... [--host-fs] [--no-guest-tools]
    \\           [--gfx[=noclip|=headless]] [--gfx-scale N] [--gfx-size WxH]
    \\           [--serve unix!PATH|tcp!HOST!PORT|ws://HOST:PORT[/PATH]]...
    \\           [--serve-root PATH] [--serve-token @FILE] [--serve-origin ORIGIN]...
    \\           [--serve-net] [--children]
    \\           [--print] [--trace[=FILE]] [-v|--verbose]
    \\           [--] program [args...]
    \\       h9 [flags] --rc 'command' [args...]
    \\       h9 [flags] --rc
    \\       h9 [flags] --serve ADDR...
    \\       h9 --plan FILE|- [narrowing flags] [program [args...]]
    \\       h9 [--engine E] [mount flags] [--memory SIZE] --check
    \\       h9 --version
    \\       h9 --help
    \\
;

/// What h9 does: run a program, or one of the tool functions.
pub const Mode = enum {
    run,
    /// --check: probe the engines and the root tree, and run a program.
    check,
    /// --version: print the version, the pins and the engines.
    version,
    /// --help, or -h as the only argument: print the usage to stdout.
    help,
};

/// --index (design/epoch-0/mount-index.md).
pub const IndexMode = enum { auto, none };

pub const Config = struct {
    mode: Mode = .run,
    engine: engine.Choice = .auto,
    /// --arch: the architecture of the binaries to run; null means a host
    /// program's own, or the host's for a guest one.
    arch: ?engine.Arch = null,
    /// --trace: null for none, "" for stderr, else a file.
    trace: ?[]const u8 = null,
    /// The mount flags in order (design/epoch-0/mounts.md): --dir, --url,
    /// --archive, --builtin, and --tmp. A --dir's path is as given; the
    /// caller resolves it.
    mounts: []const mount.Mount = &.{},
    /// --bind values in order.
    binds: []const mount.Bind = &.{},
    /// --cred values, `PATTERN=COMMAND`, checked
    /// (design/epoch-0/credential-helpers.md).
    cred: []const []const u8 = &.{},
    /// --index: whether indexes are used.
    index: IndexMode = .auto,
    /// --index-cache: where compiled indexes are kept; null for the
    /// default.
    index_cache: ?[]const u8 = null,
    /// -v or --verbose: notes on stderr, such as the index's validation.
    verbose: bool = false,
    /// --user-map: a passwd file mapping names to the numbers a 9P2000.L
    /// server sees (design/epoch-0/dotl.md).
    user_map: ?[]const u8 = null,
    /// --cwd: the host directory bound at /mnt/term/cwd; null means the
    /// host cwd.
    cwd: ?[]const u8 = null,
    /// Whether the cwd is writable, from a plan's `cwd PATH rw|ro`
    /// (design/plan-format.md); null means the profile's default.
    cwd_writable: ?bool = null,
    /// --plan: the plan file to run, `-` for stdin (design/plan-format.md).
    /// The caller reads it and applies it with `withPlan`.
    plan: ?[]const u8 = null,
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
    /// --ns values in order: namespace lines inline, with `;` between
    /// them, or `@FILE` for a host file (design/epoch-0/mounts.md).
    ns: []const []const u8 = &.{},
    host_fs: bool = false,
    /// --children: the guest can start child machines
    /// (design/child-machines.md).
    children: bool = false,
    /// --no-guest-tools: leave out `#H/bin` and mask `#H`
    /// (design/epoch-0/guest-tools.md).
    guest_tools: bool = true,
    /// --gfx, --gfx=noclip and --gfx-scale: a host window
    /// (design/epoch-0/gfx.md); null without --gfx.
    gfx: ?gfx.Options = null,
    print: bool = false,
    /// --serve addresses, checked (design/epoch-0/serve.md).
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
    /// (design/epoch-0/default-command.md).
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
    var mounts: std.ArrayList(mount.Mount) = .empty;
    var binds: std.ArrayList(mount.Bind) = .empty;
    var creds: std.ArrayList([]const u8) = .empty;
    why = "";
    var serve_addrs: std.ArrayList([]const u8) = .empty;
    var serve_origins: std.ArrayList([]const u8) = .empty;
    var ns: std.ArrayList([]const u8) = .empty;
    var gfx_scale: ?u8 = null;
    var gfx_size: ?gfx.HeadlessSize = null;
    var gfx_window = false;
    var gfx_noclip = false;
    var gfx_headless = false;
    // Long flags only (SPEC.md, "Parsing rules"); -h is accepted alone,
    // where it can't be a program's flag.
    if (args.len == 2 and std.mem.eql(u8, args[1], "-h")) return .{ .mode = .help, .argv = &.{} };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        // -v is the one short flag, before the program.
        if (std.mem.eql(u8, a, "-v")) {
            c.verbose = true;
            continue;
        }
        if (!std.mem.startsWith(u8, a, "--")) break;
        if (std.mem.eql(u8, a, "--")) {
            i += 1;
            break;
        } else if (std.mem.eql(u8, a, "--trace")) {
            c.trace = "";
        } else if (std.mem.startsWith(u8, a, "--trace=")) {
            c.trace = a["--trace=".len..];
            if (c.trace.?.len == 0) return error.Usage;
        } else if (flag(a, "--host-fs")) {
            c.host_fs = true;
        } else if (flag(a, "--no-guest-tools")) {
            c.guest_tools = false;
        } else if (flag(a, "--children")) {
            c.children = true;
        } else if (flag(a, "--gfx")) {
            gfx_window = true;
        } else if (flag(a, "--gfx=noclip")) {
            gfx_noclip = true;
        } else if (flag(a, "--gfx=headless")) {
            gfx_headless = true;
        } else if (std.mem.startsWith(u8, a, "--gfx=")) {
            return error.Usage;
        } else if (value(args, &i, "--gfx-scale")) |v| {
            gfx_scale = std.fmt.parseInt(u8, v orelse return error.Usage, 10) catch return error.Usage;
        } else if (value(args, &i, "--gfx-size")) |v| {
            gfx_size = parseGfxSize(v orelse return error.Usage) orelse return error.Usage;
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
        } else if (flag(a, "--print")) {
            c.print = true;
        } else if (value(args, &i, "--plan")) |v| {
            c.plan = v orelse return error.Usage;
            if (c.plan.?.len == 0) return error.Usage;
        } else if (flag(a, "--verbose")) {
            c.verbose = true;
        } else if (value(args, &i, "--index-cache")) |v| {
            c.index_cache = v orelse return error.Usage;
            if (c.index_cache.?.len == 0) return error.Usage;
        } else if (value(args, &i, "--index")) |v| {
            c.index = try enumValue(IndexMode, v);
        } else if (flag(a, "--check")) {
            if (c.mode != .run) return error.Usage;
            c.mode = .check;
        } else if (flag(a, "--version")) {
            if (c.mode != .run) return error.Usage;
            c.mode = .version;
        } else if (flag(a, "--help")) {
            if (c.mode != .run) return error.Usage;
            c.mode = .help;
        } else if (value(args, &i, "--engine")) |v| {
            c.engine = try enumValue(engine.Choice, v);
        } else if (value(args, &i, "--arch")) |v| {
            c.arch = engine.Arch.fromName(v orelse return error.Usage) orelse return error.Usage;
        } else if (value(args, &i, "--cred")) |v| {
            const spec = v orelse return error.Usage;
            const h = cred.parse(gpa, spec) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.Usage;
            gpa.free(h.argv);
            try creds.append(gpa, spec);
        } else if (value(args, &i, "--user-map")) |v| {
            c.user_map = v orelse return error.Usage;
            if (c.user_map.?.len == 0) return error.Usage;
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
            const text = v orelse return error.Usage;
            if (text.len == 0 or std.mem.eql(u8, text, "@")) return error.Usage;
            try ns.append(gpa, text);
        } else if (removed(a)) |r| {
            why = r;
            return error.Usage;
        } else if (flag(a, "--builtin") or std.mem.startsWith(u8, a, "--builtin=")) {
            // No value but after `=`, so `--builtin rc` runs rc.
            const v = if (a.len > "--builtin".len) a["--builtin=".len..] else "";
            if (std.meta.stringToEnum(enum { auto, only, before, after, off }, v) != null or
                (v.len == 0 and i + 1 < args.len and std.meta.stringToEnum(enum { auto, only, before, after, off }, args[i + 1]) != null))
            {
                why = "--builtin MODE was removed: use --builtin alone for the bottom of /, --builtin=/:b for its top, or a --dir or --url on / without --builtin to leave it out";
                return error.Usage;
            }
            try mounts.append(gpa, try mountFlag(gpa, .builtin, v));
        } else if (value(args, &i, "--dir")) |v| {
            try mounts.append(gpa, try mountFlag(gpa, .dir, v orelse return error.Usage));
        } else if (value(args, &i, "--url")) |v| {
            try mounts.append(gpa, try mountFlag(gpa, .url, v orelse return error.Usage));
        } else if (value(args, &i, "--archive")) |v| {
            try mounts.append(gpa, try mountFlag(gpa, .archive, v orelse return error.Usage));
        } else if (value(args, &i, "--tmp")) |v| {
            try mounts.append(gpa, try mountFlag(gpa, .tmp, v orelse return error.Usage));
        } else if (value(args, &i, "--bind")) |v| {
            try binds.append(gpa, try bindFlag(gpa, v orelse return error.Usage));
        } else if (value(args, &i, "--rc")) |v| {
            // With no value, --rc is the last argument: a login rc.
            c.rc = v;
            c.rc_login = v == null;
        } else {
            return error.Usage;
        }
    }
    // --gfx and --gfx=noclip are a window, --gfx=headless a screen in
    // memory (design/epoch-0/headless-screen.md); --gfx-scale and noclip are the
    // window's, and --gfx-size the headless screen's.
    if (gfx_headless) {
        if (gfx_window or gfx_noclip or gfx_scale != null) return error.Usage;
        c.gfx = .{ .screen = .headless, .size = gfx_size };
    } else {
        if (gfx_size != null) return error.Usage;
        if (gfx_window or gfx_noclip) c.gfx = .{ .clipboard = !gfx_noclip };
        if (gfx_scale) |n| {
            if (c.gfx == null) return error.Usage;
            c.gfx.?.scale = n;
        }
    }
    if (c.sandbox != null) {
        if (c.host_fs or c.cwd != null) return error.Usage;
        c.profile = .tight;
    }
    // The --serve flags apply to a --serve (design/epoch-0/serve.md), and
    // any origin needs the token, or every page could mount the machine.
    const serving = serve_addrs.items.len > 0;
    if (!serving and (c.serve_root != null or c.serve_token != null or serve_origins.items.len > 0 or c.serve_net)) return error.Usage;
    for (serve_origins.items) |o| if (std.mem.eql(u8, o, "*") and c.serve_token == null) return error.Usage;
    // The tool functions take no program, so `h9 --check ls` is a mistake.
    // No program is a run that only serves, with --serve.
    // A plan may have its own run line (design/plan-format.md).
    const rc = c.rc != null or c.rc_login;
    if (c.mode != .run) {
        if (rc or i < args.len or serving or c.plan != null) return error.Usage;
    } else if (!rc and i >= args.len and !serving and c.plan == null) return error.Usage;
    c.serve = try serve_addrs.toOwnedSlice(gpa);
    c.serve_origins = try serve_origins.toOwnedSlice(gpa);
    c.env = try env.toOwnedSlice(gpa);
    c.readable = try readable.toOwnedSlice(gpa);
    c.writable = try writable.toOwnedSlice(gpa);
    c.read_deny = try read_deny.toOwnedSlice(gpa);
    c.net_allow = try net_allow.toOwnedSlice(gpa);
    c.cred = try creds.toOwnedSlice(gpa);
    c.mounts = try mounts.toOwnedSlice(gpa);
    c.binds = try binds.toOwnedSlice(gpa);
    c.ns = try ns.toOwnedSlice(gpa);
    c.argv = args[i..];
    return c;
}

/// The plan's run line for the program the flags name: `--rc 'cmd'` is
/// `/bin/rc -c cmd`, `--rc` alone `/bin/rc -l`, and otherwise the
/// program and its arguments. Null when there's none (`--serve` only).
pub fn runLine(gpa: std.mem.Allocator, c: Config) Error!?[]const []const u8 {
    if (c.rc) |cmd| return try std.mem.concat(gpa, []const u8, &.{ &.{ "/bin/rc", "-c", cmd }, c.argv });
    if (c.rc_login) return try gpa.dupe([]const u8, &.{ "/bin/rc", "-l" });
    if (c.argv.len == 0) return null;
    return c.argv;
}

/// The plan the flags give, as `narrow` takes it: only what they set
/// (design/plan-format.md). The program isn't in it.
pub fn flagSpec(c: Config) policy.Spec {
    return .{
        .mounts = c.mounts,
        .binds = c.binds,
        .ns = c.ns,
        .policy = .{
            .profile = c.profile,
            .readable = c.readable,
            .writable = c.writable,
            .read_deny = c.read_deny,
            .write = c.write,
            .net = c.net,
            .net_allow = c.net_allow,
            .memory = c.memory,
            .timeout_ns = c.timeout_ns,
            .pids = c.pids,
            .cpus = c.cpus,
            .cwd_writable = if (c.sandbox != null) true else c.cwd_writable,
            .host_fs = c.host_fs,
            .children = c.children,
        },
        .guest_tools = c.guest_tools,
        .engine = if (c.engine == .auto) null else std.meta.stringToEnum(policy.EngineChoice, @tagName(c.engine)),
        .arch = c.arch,
        .env = c.env,
        .cwd = c.sandbox orelse c.cwd,
        .gfx = if (c.gfx) |g| .{
            .headless = g.screen == .headless,
            .clipboard = g.clipboard,
            .scale = if (g.screen == .headless or g.scale == 1) null else g.scale,
            .size = if (g.size) |sz| .{ sz.dx, sz.dy } else null,
        } else null,
        .serve = c.serve,
        .serve_root = c.serve_root,
        .serve_token = c.serve_token,
        .serve_origins = c.serve_origins,
        .serve_net = c.serve_net,
    };
}

/// Applies plan `text` (`--plan`, design/plan-format.md) to the flags in
/// `c`: the flags narrow the plan (`policy.narrow`), a program on the
/// command line replaces its run line, and the flags the plan doesn't
/// cover (`--trace`, `-v`, `--index`, `--cred`, `--print`, and the like)
/// stay as given. A line the plan can't parse, a flag that widens it, and
/// a plan without a program when the command line has none, are usage
/// errors, with `why` saying which.
pub fn withPlan(gpa: std.mem.Allocator, c: Config, text: []const u8) Error!Config {
    var perr: policy.PlanError = .{};
    const base = policy.parsePlan(gpa, text, &perr) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        why = try std.fmt.allocPrint(gpa, "--plan {s}: line {d}: {s}", .{ c.plan orelse "", perr.line, perr.msg });
        return error.Usage;
    };
    var w: []const u8 = "";
    const p = policy.narrow(gpa, base, flagSpec(c), &w) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        why = try std.fmt.allocPrint(gpa, "--plan {s}: {s}", .{ c.plan orelse "", w });
        return error.Usage;
    };
    var r = c;
    r.mounts = p.mounts;
    r.binds = p.binds;
    r.ns = p.ns;
    r.profile = p.policy.profile;
    r.readable = p.policy.readable;
    r.writable = p.policy.writable;
    r.read_deny = p.policy.read_deny;
    r.write = p.policy.write;
    r.net = p.policy.net;
    r.net_allow = p.policy.net_allow;
    r.memory = p.policy.memory;
    r.timeout_ns = p.policy.timeout_ns;
    r.pids = p.policy.pids;
    r.cpus = p.policy.cpus;
    r.host_fs = p.policy.host_fs;
    r.children = p.policy.children;
    r.guest_tools = p.guest_tools;
    r.cwd = p.cwd;
    r.cwd_writable = p.policy.cwd_writable;
    r.sandbox = null;
    if (p.engine) |e| r.engine = std.meta.stringToEnum(engine.Choice, @tagName(e)).?;
    r.arch = p.arch;
    r.env = p.env;
    r.gfx = if (p.gfx) |g| .{
        .screen = if (g.headless) .headless else .window,
        .clipboard = g.clipboard,
        .scale = g.scale orelse 1,
        .size = if (g.size) |sz| .{ .dx = sz[0], .dy = sz[1] } else null,
    } else null;
    r.serve = p.serve;
    for (r.serve) |addr| _ = serve.Listen.parse(addr) catch {
        why = try std.fmt.allocPrint(gpa, "--plan {s}: serve {s}: not an address h9 can listen on", .{ c.plan orelse "", addr });
        return error.Usage;
    };
    r.serve_root = p.serve_root;
    r.serve_token = p.serve_token;
    r.serve_origins = p.serve_origins;
    r.serve_net = p.serve_net;
    for (r.serve_origins) |o| if (std.mem.eql(u8, o, "*") and r.serve_token == null) {
        why = try std.fmt.allocPrint(gpa, "--plan {s}: serveorigin * needs servetoken", .{c.plan orelse ""});
        return error.Usage;
    };
    // The command line's program, or the plan's run line, which may be
    // rc as --rc gives it.
    if (c.rc == null and !c.rc_login and c.argv.len == 0) if (p.run) |argv| {
        if (argv.len >= 3 and std.mem.eql(u8, argv[0], "/bin/rc") and std.mem.eql(u8, argv[1], "-c")) {
            r.rc = argv[2];
            r.argv = argv[3..];
        } else if (argv.len == 2 and std.mem.eql(u8, argv[0], "/bin/rc") and std.mem.eql(u8, argv[1], "-l")) {
            r.rc_login = true;
            r.argv = &.{};
        } else r.argv = argv;
    };
    if (r.rc == null and !r.rc_login and r.argv.len == 0 and r.serve.len == 0 and r.mode == .run) {
        why = try std.fmt.allocPrint(gpa, "--plan {s}: no program: the plan has no run line, and none was given", .{c.plan orelse ""});
        return error.Usage;
    }
    return r;
}

/// The flags design/epoch-0/mounts.md removed, and what replaces each, for the
/// usage error (exit 2) that names it.
fn removed(a: []const u8) ?[]const u8 {
    const list = [_]struct { []const u8, []const u8 }{
        .{ "--root-spec", "--root-spec was removed: use spec=NAME, as in --url URL:/:spec=NAME" },
        .{ "--root-user", "--root-user was removed: use user=NAME, as in --url URL:/:user=NAME" },
        .{ "--root-header", "--root-header was removed: use header=, as in --url URL:/:header=@FILE" },
        .{ "--root-ca", "--root-ca was removed: use ca=FILE, as in --url wss://HOST/PATH:/:ca=FILE" },
        .{ "--root-index", "--root-index was removed: use index=FILE, as in --url URL:/:index=FILE" },
        .{ "--root-contained", "--root-contained was removed: use the contained option, as in --dir PATH:/:contained" },
        .{ "--root", "--root was removed: use --dir PATH for a host directory, or --url URL for a 9P server" },
    };
    for (list) |e| {
        if (std.mem.eql(u8, a, e[0]) or (std.mem.startsWith(u8, a, e[0]) and a[e[0].len] == '=')) return e[1];
    }
    return null;
}

/// Parses a mount flag's value, keeping its mistake in `why`.
fn mountFlag(gpa: std.mem.Allocator, kind: mount.Kind, v: []const u8) Error!mount.Mount {
    var w: []const u8 = "";
    return mount.Mount.parse(gpa, kind, v, &w) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Usage => {
            why = std.fmt.allocPrint(gpa, "{s} {s}: {s}", .{ kind.flag(), v, w }) catch w;
            return error.Usage;
        },
    };
}

fn bindFlag(gpa: std.mem.Allocator, v: []const u8) Error!mount.Bind {
    var w: []const u8 = "";
    return mount.Bind.parse(v, &w) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Usage => {
            why = std.fmt.allocPrint(gpa, "--bind {s}: {s}", .{ v, w }) catch w;
            return error.Usage;
        },
    };
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

/// The exit code for a program's `exits` string (design/epoch-0/go-compat.md):
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
/// (design/epoch-0/exit-status.md). `stopped_by` is the host signal that started a
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
    // The Linux ABI's notes (design/epoch-0/linux-personality.md).
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
/// overlay are discarded (design/epoch-0/overlay.md): the changed top-level
/// directories, and how to keep them. A 9P root keeps writes under
/// `--write=scope`, since its server decides; otherwise a layer keeps
/// them in a directory of the user's (design/epoch-0/upper-layers.md).
pub fn discardNotice(buf: []u8, c: *const RootChanges, ninep: bool) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    noticeTo(&w, c, ninep) catch {};
    return w.buffered();
}

fn noticeTo(w: *std.Io.Writer, c: *const RootChanges, ninep: bool) std.Io.Writer.Error!void {
    try w.writeAll("h9: changes to the root under ");
    for (c.dirs(), 0..) |*n, i| try w.print("{s}/{s}", .{ if (i > 0) ", " else "", n.slice() });
    if (c.more) try w.writeAll(if (c.count > 0) ", ..." else "...");
    if (ninep) return w.writeAll(" were discarded (rerun with --write=scope to keep them)");
    try w.writeAll(" were discarded (--dir DIR:/:up keeps them in DIR)");
}

const t = std.testing;

test "flags stop at the first non-flag" {
    const c = try parse(t.allocator, &.{ "h9", "--engine", "hcpu", "--trace", "./ls", "--trace" });
    defer t.allocator.free(c.env);
    try t.expectEqual(engine.Choice.hcpu, c.engine);
    try t.expectEqualStrings("", c.trace.?);
    try t.expectEqual(@as(usize, 2), c.argv.len);
    try t.expectEqualStrings("--trace", c.argv[1]);
}

test "--engine and its values [renames]" {
    inline for (.{ "auto", "hvf", "kvm", "whp", "sud", "hcpu" }) |name| {
        const c = try parse(t.allocator, &.{ "h9", "--engine", name, "/bin/echo" });
        defer t.allocator.free(c.env);
        try t.expectEqual(@field(engine.Choice, name), c.engine);
    }
    try t.expectError(error.Usage, parse(t.allocator, &.{ "h9", "--engine", "emulator", "/bin/echo" }));
}

test "--backend and the old engine names are gone [renames]" {
    try t.expectError(error.Usage, parse(t.allocator, &.{ "h9", "--backend", "hcpu", "/bin/echo" }));
    inline for (.{ "native", "emu", "v86" }) |old| {
        try t.expectError(error.Usage, parse(t.allocator, &.{ "h9", "--engine", old, "/bin/echo" }));
    }
}

test "--arch" {
    try t.expectEqual(engine.Arch.i386, (try parse(t.allocator, &.{ "h9", "--arch", "386", "/bin/echo" })).arch.?);
    try t.expectEqual(engine.Arch.amd64, (try parse(t.allocator, &.{ "h9", "--arch=amd64", "/bin/echo" })).arch.?);
    try t.expectEqual(@as(?engine.Arch, null), (try parse(t.allocator, &.{ "h9", "/bin/echo" })).arch);
    try t.expectError(error.Usage, parse(t.allocator, &.{ "h9", "--arch", "i386", "x" }));
    try t.expectError(error.Usage, parse(t.allocator, &.{ "h9", "--arch" }));
}

test "--engine=value and --" {
    const c = try parse(t.allocator, &.{ "h9", "--engine=hvf", "--", "--weird" });
    defer t.allocator.free(c.env);
    try t.expectEqual(engine.Choice.hvf, c.engine);
    try t.expectEqualStrings("--weird", c.argv[0]);
}

test "--cred is checked and kept as given [credential-helpers]" {
    const c = try parse(t.allocator, &.{ "h9", "--cred", "*.wanix.io=wanix token", "--cred=fs.example=cat /tmp/h", "ls" });
    defer t.allocator.free(c.env);
    defer t.allocator.free(c.cred);
    try t.expectEqual(@as(usize, 2), c.cred.len);
    try t.expectEqualStrings("fs.example=cat /tmp/h", c.cred[1]);
    for ([_][]const u8{ "*=cat", "*.=cat", "wanix.io", "wanix.io=", "wss://wanix.io=cat" }) |bad|
        try t.expectError(error.Usage, parse(t.allocator, &.{ "h9", "--cred", bad, "ls" }));
}

test "--index, --index-cache, and -v, and --root-index is removed [mount-index]" {
    const c = try parse(t.allocator, &.{ "h9", "--index-cache=/tmp/c", "-v", "ls" });
    try t.expectEqualStrings("/tmp/c", c.index_cache.?);
    try t.expect(c.verbose);
    try t.expectEqual(IndexMode.auto, c.index);
    try t.expectEqualStrings("ls", c.argv[0]);
    const d = try parse(t.allocator, &.{ "h9", "--index", "none", "--verbose", "ls", "-v" });
    try t.expectEqual(IndexMode.none, d.index);
    try t.expect(d.verbose);
    try t.expectEqualStrings("-v", d.argv[1]);
    try t.expectError(error.Usage, parse(t.allocator, &.{ "h9", "--index", "some", "ls" }));
    try t.expectError(error.Usage, parse(t.allocator, &.{ "h9", "--root-index", "x", "ls" }));
}

test "the mount flags parse in order, and --bind after them [mounts]" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try parse(a, &.{ "h9", "--builtin", "--dir", "./base", "--url=tcp://fs:564/main:/n/fs:ro", "--archive", "fix.tgz:/:b", "--tmp", "/scratch", "--bind", "/n/fs/bin:/bin:a", "--builtin=/:b", "rc" });
    try t.expectEqual(@as(usize, 6), c.mounts.len);
    try t.expectEqual(mount.Kind.builtin, c.mounts[0].kind);
    try t.expectEqual(mount.Order.after, c.mounts[0].order.?);
    try t.expectEqualStrings("./base", c.mounts[1].src);
    try t.expectEqualStrings("/", c.mounts[1].dst);
    try t.expectEqualStrings("tcp://fs:564/main", c.mounts[2].src);
    try t.expectEqualStrings("/n/fs", c.mounts[2].dst);
    try t.expectEqual(mount.Access.ro, c.mounts[2].access.?);
    try t.expectEqual(mount.Kind.tmp, c.mounts[4].kind);
    try t.expectEqual(mount.Order.before, c.mounts[5].order.?);
    try t.expectEqual(@as(usize, 1), c.binds.len);
    try t.expectEqualStrings("/bin", c.binds[0].dst);
    try t.expectEqualStrings("rc", c.argv[0]);
    // A bare --builtin takes no value, so the program follows it.
    const b = try parse(a, &.{ "h9", "--builtin", "ls" });
    try t.expectEqualStrings("ls", b.argv[0]);
    try t.expectError(error.Usage, parse(a, &.{ "h9", "--tmp", "", "ls" }));
    try t.expectError(error.Usage, parse(a, &.{ "h9", "--dir", "./x:/:bogus", "ls" }));
    try t.expectStringStartsWith(why, "--dir ./x:/:bogus: ");
}

test "--root and its flags are removed, with their replacements named [mounts]" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const []const u8{
        &.{ "h9", "--root", "/r", "ls" },
        &.{ "h9", "--root=/r", "ls" },
        &.{ "h9", "--root-spec", "x", "ls" },
        &.{ "h9", "--root-user=glenda", "ls" },
        &.{ "h9", "--root-header", "A: b", "ls" },
        &.{ "h9", "--root-ca", "ca.pem", "ls" },
        &.{ "h9", "--root-contained", "ls" },
        &.{ "h9", "--builtin", "only", "ls" },
        &.{ "h9", "--builtin=off", "ls" },
    }) |args| {
        try t.expectError(error.Usage, parse(a, args));
        try t.expect(std.mem.indexOf(u8, why, "was removed: ") != null);
    }
}

test "--cwd and repeated --env" {
    const c = try parse(t.allocator, &.{ "h9", "--cwd=/w", "--env", "a=1", "--env=b=x=y", "cat" });
    defer t.allocator.free(c.env);
    try t.expectEqualStrings("/w", c.cwd.?);
    try t.expectEqual(@as(usize, 2), c.env.len);
    try t.expectEqualStrings("b=x=y", c.env[1]);
}

test "usage errors" {
    try t.expectError(error.Usage, parse(t.allocator, &.{"h9"}));
    try t.expectError(error.Usage, parse(t.allocator, &.{ "h9", "--engine" }));
    try t.expectError(error.Usage, parse(t.allocator, &.{ "h9", "--engine", "qemu", "x" }));
    try t.expectError(error.Usage, parse(t.allocator, &.{ "h9", "--nope", "x" }));
    try t.expectError(error.Usage, parse(t.allocator, &.{ "h9", "--env", "noequals", "x" }));
    try t.expectError(error.Usage, parse(t.allocator, &.{ "h9", "--env", "=v", "x" }));
}

test "policy flags" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const c = try parse(arena.allocator(), &.{
        "h9",       "--profile=tight", "--writable", "./out", "--readable=/src", "--read-deny", "/src/.env",
        "--memory", "512m",            "--timeout",  "1m",    "--net=disable",   "--write",     "scope",
        "--print",  "--trace=t.log",   "mk",
    });
    try t.expectEqual(policy.Profile.tight, c.profile);
    try t.expectEqualStrings("./out", c.writable[0]);
    try t.expectEqualStrings("/src", c.readable[0]);
    try t.expectEqualStrings("/src/.env", c.read_deny[0]);
    try t.expectEqual(@as(?u64, 512 << 20), c.memory);
    try t.expectEqual(@as(?u64, std.time.ns_per_min), c.timeout_ns);
    try t.expectEqual(@as(?policy.NetMode, .disable), c.net);
    try t.expectEqual(@as(?policy.WriteMode, .scope), c.write);
    try t.expect(c.print);
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
    try t.expectError(error.Usage, parse(a, &.{ "h9", "--memory", "lots", "ls" }));
    try t.expectError(error.Usage, parse(a, &.{ "h9", "--timeout", "0", "ls" }));
    try t.expectError(error.Usage, parse(a, &.{ "h9", "--write", "maybe", "ls" }));
}

test "--rc alone is a login rc" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const login = try parse(a, &.{ "h9", "--dir", "r", "--rc" });
    try t.expect(login.rc_login);
    try t.expectEqual(@as(?[]const u8, null), login.rc);
    try t.expectEqual(@as(usize, 0), login.argv.len);
    // --rc= is an empty command line, not a login rc.
    const empty = try parse(a, &.{ "h9", "--rc=" });
    try t.expect(!empty.rc_login);
    try t.expectEqualStrings("", empty.rc.?);
    // --rc takes the next argument as its value, wherever it is.
    const flag_cmd = try parse(a, &.{ "h9", "--rc", "--dir", "x" });
    try t.expect(!flag_cmd.rc_login);
    try t.expectEqualStrings("--dir", flag_cmd.rc.?);
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

/// --gfx-size's WxH: each from 1 to 16384.
fn parseGfxSize(v: []const u8) ?gfx.HeadlessSize {
    const x = std.mem.indexOfScalar(u8, v, 'x') orelse return null;
    const dx = std.fmt.parseInt(u16, v[0..x], 10) catch return null;
    const dy = std.fmt.parseInt(u16, v[x + 1 ..], 10) catch return null;
    if (dx == 0 or dy == 0 or dx > 16384 or dy > 16384) return null;
    return .{ .dx = dx, .dy = dy };
}

test "--gfx=headless and --gfx-size [headless-screen]" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const hl = try parse(a.allocator(), &.{ "h9", "--gfx=headless", "rio" });
    try std.testing.expectEqual(gfx.Options{ .screen = .headless }, hl.gfx.?);
    const sized = try parse(a.allocator(), &.{ "h9", "--gfx-size", "640x480", "--gfx=headless", "rio" });
    try std.testing.expectEqual(gfx.Options{ .screen = .headless, .size = .{ .dx = 640, .dy = 480 } }, sized.gfx.?);
    for ([_][]const []const u8{
        &.{ "h9", "--gfx-size", "640x480", "rio" },
        &.{ "h9", "--gfx", "--gfx-size", "640x480", "rio" },
        &.{ "h9", "--gfx=headless", "--gfx-scale", "2", "rio" },
        &.{ "h9", "--gfx=headless", "--gfx=noclip", "rio" },
        &.{ "h9", "--gfx=headless", "--gfx", "rio" },
        &.{ "h9", "--gfx=headless", "--gfx-size", "640", "rio" },
        &.{ "h9", "--gfx=headless", "--gfx-size", "0x480", "rio" },
        &.{ "h9", "--gfx=headless", "--gfx-size", "640x70000", "rio" },
    }) |args| try std.testing.expectError(error.Usage, parse(a.allocator(), args));
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
    const c = try parse(a, &.{ "h9", "--pids", "32", "--cpus=2", "--ns", "@ns", "--ns=bind /a /b; bind /c /d", "rc" });
    try t.expectEqual(@as(?u32, 32), c.pids);
    try t.expectEqual(@as(?u32, 2), c.cpus);
    try t.expectEqual(@as(usize, 2), c.ns.len);
    try t.expectEqualStrings("@ns", c.ns[0]);
    try t.expectEqualStrings("bind /a /b; bind /c /d", c.ns[1]);
    try t.expectError(error.Usage, parse(a, &.{ "h9", "--ns", "@", "rc" }));
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
    const c = try parse(a, &.{ "h9", "--engine", "hcpu", "--dir=/r", "--check" });
    try t.expectEqual(Mode.check, c.mode);
    try t.expectEqual(engine.Choice.hcpu, c.engine);
    try t.expectEqualStrings("/r", c.mounts[0].src);
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
    try t.expectEqualStrings("-h", (try parse(a, &.{ "h9", "--engine", "hcpu", "-h" })).argv[0]);
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
        // The Linux ABI's, by name on the host.
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
    try t.expectEqualStrings("h9: changes to the root under /386, /lib, /usr were discarded (--dir DIR:/:up keeps them in DIR)", discardNotice(&buf, &rc, false));
    try t.expectEqualStrings("h9: changes to the root under /386, /lib, /usr were discarded (rerun with --write=scope to keep them)", discardNotice(&buf, &rc, true));
    var many: RootChanges = .{};
    var nb: [8]u8 = undefined;
    for (0..RootChanges.max_names + 2) |i| many.note(try std.fmt.bufPrint(&nb, "d{d}/x", .{i}), "");
    try t.expect(many.more);
    try t.expectEqual(@as(usize, RootChanges.max_names), many.dirs().len);
    try t.expect(std.mem.endsWith(u8, discardNotice(&buf, &many, false), "/d9, ... were discarded (--dir DIR:/:up keeps them in DIR)"));
}
