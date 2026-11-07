//! The sandbox policy (DESIGN.md, "Sandbox policy"): profiles and explicit
//! settings, compiled into a Plan that the machine's namespace builder
//! follows and `--print` shows. The Plan's access rules are what devfs
//! checks through `h9_fs_check` (src/kern.zig), and its network patterns
//! are what devip checks through `h9_net_check` and `h9_net_lookup`.
//!
//! All host paths here are absolute and already resolved (symlinks
//! followed); the CLI resolves them before building a Policy.

const std = @import("std");
const aout = @import("aout.zig");

pub const Profile = enum { default, tight };

pub const WriteMode = enum {
    /// Deny all writes.
    none,
    /// Persist writes to the writable paths only.
    scope,
    /// Writable paths are copy-on-write overlays in memory, discarded at
    /// exit (design/0006-ephemeral-writes.md).
    ephemeral,
    /// Like scope, with a copy-on-write overlay over the root: writes to
    /// the root succeed and are discarded at exit (design/0011-overlay.md).
    /// The default.
    overlay,
};

pub const NetMode = enum {
    disable,
    /// Clients work, `announce` is refused (design/0005-net-policy.md).
    outbound,
    enable,
};

/// The default timeout of the tight profile.
pub const tight_timeout_ns: u64 = 10 * std.time.ns_per_min;

pub const Policy = struct {
    profile: Profile = .default,
    /// Host paths bound read-only.
    readable: []const []const u8 = &.{},
    /// Host paths bound read-write; inside a read-only tree they override it.
    writable: []const []const u8 = &.{},
    /// Host paths hidden even inside a bound tree.
    read_deny: []const []const u8 = &.{},
    /// Null means the default, overlay, in both profiles.
    write: ?WriteMode = null,
    /// Null means the profile's default: outbound, or disable for tight.
    net: ?NetMode = null,
    /// Egress allowlist of dial-string patterns (`tcp!10.0.0.0/8!564`);
    /// when non-empty, every connect and cs lookup must match one.
    net_allow: []const []const u8 = &.{},
    /// Cap on guest memory in bytes; null means the backend's region size.
    memory: ?u64 = null,
    /// Machine deadline; null means the profile's default.
    timeout_ns: ?u64 = null,
    /// Cap on live processes in the machine; null means unlimited.
    pids: ?u32 = null,
    /// Cap on vCPUs running guest code at once; null means the backend's
    /// limit (64 on HVF) or, on the emulator, unlimited.
    cpus: ?u32 = null,
    /// Whether the cwd is writable; null means the profile's default.
    /// `--sandbox` sets it.
    cwd_writable: ?bool = null,
    /// Expose all of the host filesystem at /mnt/term.
    host_fs: bool = false,
    /// Leave devcmd (`#C`) unmasked.
    host_cmd: bool = false,
};

/// How a bound tree can be changed: not at all, on the host, in an
/// overlay in memory (`eph`), which never writes the host, or as a 9P
/// root's server decides (`9p`, design/0013-9p-roots.md).
pub const Access = enum { ro, rw, eph, @"9p" };

/// An allow or deny rule on a host path and everything beneath it.
/// `allow_eph` is a tree under an overlay: read-only to devfs, since the
/// overlay never writes its lower tree.
pub const Rule = struct {
    path: []const u8,
    kind: enum { allow_ro, allow_rw, allow_eph, deny },
};

/// One bind in the namespace, in the order the builder runs them.
pub const Bind = struct {
    from: []const u8,
    to: []const u8,
    flag: Flag = .repl,
    create: bool = false,
    /// Set for host trees, to show in the plan.
    access: ?Access = null,
    /// The machine's console: `from` gets the console id appended.
    console: bool = false,
    /// Fine to fail (a root tree without the mount point, say).
    optional: bool = false,
    /// Tried in turn if `to` fails (older root trees).
    fallback: ?[]const u8 = null,
    /// A fresh `#O` overlay instance over `lower` (a host path, through
    /// `#U`), bound over `to`; `from` is `#O`. Printed as `bind -c '#O'`
    /// with the host path in a comment; in a namespace file a bare `#O`
    /// overlays whatever `to` is at that point (src/newns.zig).
    lower: ?[]const u8 = null,
    /// A mount of the 9P server posted at `from` (`#s/root`), rather than
    /// a bind, with the attach name `spec`.
    mount: bool = false,
    spec: []const u8 = "",
    /// Shown as a comment in the plan when there's no `lower`.
    note: ?[]const u8 = null,

    pub const Flag = enum { repl, before, after };
};

/// A 9P server as the root (design/0013-9p-roots.md): the machine
/// connects to it, posts the connection as `#s/root` and mounts that at /.
pub const NinePRoot = struct {
    kind: enum { tcp, unix, ws },
    /// The dial string, `tcp!host!port` or `unix!path`, or a `ws://` or
    /// `wss://` URL (design/0021-websocket-9p.md), for the plan and errors.
    addr: []const u8,
    /// The attach name.
    spec: []const u8 = "",
    /// The attach uname; null means the machine's user.
    user: ?[]const u8 = null,
    /// A WebSocket root's handshake headers, `Name: value`; the plan
    /// shows their names only.
    headers: []const []const u8 = &.{},
    /// Its `--root-ca` file.
    ca: ?[]const u8 = null,
    /// The proxy it goes through, if any.
    proxy: ?[]const u8 = null,
};

/// The host-stream device, `#ℏ`, whose tree is the guest's /net/ws.
pub const hstream_dev = "ℏ";

/// Where a 9P root's connection is posted, and the board name it's under.
pub const root_srv = "#s/root";

/// Capabilities this build knows, in the order the plan prints them.
pub const Capability = enum {
    @"env.scrub",
    @"fs.read.deny",
    @"fs.read.scope",
    @"fs.write.ephemeral",
    @"fs.write.overlay",
    @"fs.write.scope",
    @"ipc.restrict",
    @"kernel.isolation",
    @"net.allow",
    @"net.disable",
    @"net.outbound",
    @"proc.timeout",
    @"res.cpu",
    @"res.memory",
    @"res.pids",

    /// Whether this build can enforce it.
    pub fn enforceable(c: Capability) bool {
        return switch (c) {
            else => true,
        };
    }
};

pub const CapSet = std.EnumSet(Capability);

pub const Plan = struct {
    profile: Profile,
    write: WriteMode,
    net: NetMode,
    memory: ?u64,
    timeout_ns: ?u64,
    pids: ?u32,
    cpus: ?u32,
    /// The --net-allow patterns; empty means no allowlist.
    net_allow: []const NetPattern = &.{},
    /// The machine's resolved-name table, when a pattern names hosts.
    names: ?*NameTable = null,
    /// Device letters masked after the namespace is built.
    devmask: []const u8,
    binds: []const Bind,
    rules: []const Rule,
    enforces: CapSet,
    /// Requested but not enforceable by this build; `--strict` refuses them.
    unenforced: CapSet,
    caveats: []const []const u8,
    /// Where the cwd lands in the guest; null without a root or cwd.
    guest_cwd: ?[]const u8,
    /// The 9P root to connect before the namespace is built, if any.
    root_9p: ?NinePRoot = null,
    /// The machine's window, with --gfx (design/0015-gfx.md).
    gfx: ?Gfx = null,
    /// Whether the root is under a copy-on-write overlay
    /// (design/0011-overlay.md): the bind of `#O` onto `/`. The builder
    /// makes `$home` in it, and the machine reports the guest's changes.
    root_overlay: bool = false,

    /// Checks `op` on the resolved host path `path`.
    pub fn check(p: *const Plan, path: []const u8, op: Op) Verdict {
        return checkRules(p.rules, path, op);
    }

    /// Whether a connect or announce is allowed. `addr` is devip's
    /// 16-byte form, with IPv4 as IPv4-mapped IPv6.
    pub fn netCheck(p: *const Plan, op: NetOp, proto: ?NetProto, addr: *const [16]u8, port: u16) bool {
        if (p.net == .disable) return false;
        switch (op) {
            .announce => return p.net == .enable,
            .connect => {},
        }
        if (p.net_allow.len == 0) return !isLinkLocal(addr);
        const pr = proto orelse return false;
        for (p.net_allow) |pat| if (pat.matchAddr(pr, addr, port)) return true;
        const names = p.names orelse return false;
        return names.allows(p.net_allow, pr, addr, port);
    }

    /// Whether devip's cs may resolve `name` for proto and port.
    pub fn netLookup(p: *const Plan, proto: ?NetProto, name: []const u8, port: u16) bool {
        if (p.net == .disable) return false;
        if (p.net_allow.len == 0) return true;
        const pr = proto orelse return false;
        for (p.net_allow) |pat| if (pat.matchName(pr, name, port)) return true;
        return false;
    }

    /// Records the addresses cs resolved for an allowed name.
    pub fn netResolved(p: *const Plan, proto: ?NetProto, name: []const u8, port: u16, addrs: []const [16]u8) void {
        const names = p.names orelse return;
        const pr = proto orelse return;
        for (addrs) |*a| names.record(pr, a, port, name);
    }

    /// Prints the plan in the format of DESIGN.md, "Plan output".
    pub fn print(p: *const Plan, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("profile:  {t}\n", .{p.profile});
        try w.writeAll("enforces:");
        var it = p.enforces.iterator();
        while (it.next()) |c| try w.print(" {t}", .{c});
        try w.writeAll("\n");
        if (p.unenforced.count() > 0) {
            try w.writeAll("unenforced:");
            var u = p.unenforced.iterator();
            while (u.next()) |c| try w.print(" {t}", .{c});
            try w.writeAll("\n");
        }
        try w.print("limits:   write={t} net={t}", .{ p.write, p.net });
        if (p.memory) |m| try w.print(" memory={f}", .{fmtSize(m)});
        if (p.timeout_ns) |d| try w.print(" timeout={f}", .{fmtDuration(d)});
        if (p.pids) |n| try w.print(" pids={d}", .{n});
        if (p.cpus) |n| try w.print(" cpus={d}", .{n});
        try w.writeAll("\n");
        try w.writeAll("devmask: ");
        // Device names are runes: #ℏ is three bytes.
        var dv = (std.unicode.Utf8View.init(p.devmask) catch unreachable).iterator();
        while (dv.nextCodepointSlice()) |d| try w.print(" #{s}", .{d});
        try w.writeAll("\n");
        if (p.gfx) |g| try w.print("gfx:      {s} scale={d} clipboard={s}\n", .{ g.backend, g.scale, if (g.clipboard) "host" else "private" });
        if (p.net_allow.len > 0) {
            try w.writeAll("net-allow:\n");
            for (p.net_allow) |pat| try w.print("  {s}\n", .{pat.text});
        }
        try w.writeAll("namespace:\n");
        for (p.binds) |b| {
            var line: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
            defer line.deinit();
            const lw = &line.writer;
            lw.writeAll(if (b.mount) "  mount" else "  bind") catch return error.WriteFailed;
            switch (b.flag) {
                .repl => {},
                .before => lw.writeAll(" -b") catch return error.WriteFailed,
                .after => lw.writeAll(" -a") catch return error.WriteFailed,
            }
            if (b.create) lw.writeAll(if (b.flag == .repl) " -c" else "c") catch return error.WriteFailed;
            lw.print(" '{s}{s}' {s}", .{ b.from, if (b.console) "<id>" else "", b.to }) catch return error.WriteFailed;
            // Always written for a mount, '' when empty, so newns can tell
            // the spec from the access column.
            if (b.mount) lw.print(" '{s}'", .{b.spec}) catch return error.WriteFailed;
            try w.writeAll(line.written());
            if (b.access) |a| {
                const pad = 56 -| line.written().len;
                try w.splatByteAll(' ', pad + 1);
                try w.print("{t}", .{a});
            }
            if (b.lower orelse b.note) |l| try w.print("  # {s}", .{l});
            try w.writeAll("\n");
        }
        if (p.rules.len > 0) {
            try w.writeAll("access:\n");
            for (p.rules) |r| try w.print("  {s} {s}\n", .{ switch (r.kind) {
                .allow_ro => "ro  ",
                .allow_rw => "rw  ",
                .allow_eph => "eph ",
                .deny => "deny",
            }, r.path });
        }
        try w.writeAll("caveats:\n");
        for (p.caveats) |c| try w.print("  - {s}\n", .{c});
    }
};

pub const CompileError = error{ OutOfMemory, Conflict };

/// A 9P root's comment in the plan: the dial string or URL, with a URL's
/// query elided, header names, the proxy and `--root-ca`, and the user.
fn rootNote(arena: std.mem.Allocator, r: NinePRoot) error{OutOfMemory}![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    if (r.kind == .ws) {
        if (std.mem.indexOfScalar(u8, r.addr, '?')) |q| {
            w.print("{s}…", .{r.addr[0 .. q + 1]}) catch return error.OutOfMemory;
        } else w.writeAll(r.addr) catch return error.OutOfMemory;
        if (r.headers.len > 0) {
            w.writeAll("  (") catch return error.OutOfMemory;
            for (r.headers, 0..) |h, i| {
                const colon = std.mem.indexOfScalar(u8, h, ':') orelse h.len;
                w.print("{s}{s}: …", .{ if (i > 0) ", " else "", std.mem.trim(u8, h[0..colon], " \t") }) catch return error.OutOfMemory;
            }
            w.writeAll(")") catch return error.OutOfMemory;
        }
        if (r.proxy) |p| w.print("  via {f}", .{elideUserinfo(p)}) catch return error.OutOfMemory;
        if (r.ca) |ca| w.print("  --root-ca {s}", .{ca}) catch return error.OutOfMemory;
    } else w.writeAll(r.addr) catch return error.OutOfMemory;
    if (r.user) |u| w.print(" as {s}", .{u}) catch return error.OutOfMemory;
    return out.written();
}

/// A proxy URL with its userinfo replaced by `…`.
fn elideUserinfo(url: []const u8) ElidedUserinfo {
    return .{ .url = url };
}

const ElidedUserinfo = struct {
    url: []const u8,
    pub fn format(e: ElidedUserinfo, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const scheme_end = if (std.mem.indexOf(u8, e.url, "://")) |i| i + 3 else 0;
        const rest = e.url[scheme_end..];
        const host_end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        const at = std.mem.lastIndexOfScalar(u8, rest[0..host_end], '@') orelse return w.writeAll(e.url);
        try w.print("{s}…@{s}", .{ e.url[0..scheme_end], rest[at + 1 ..] });
    }
};

/// A machine's window (design/0015-gfx.md), as the plan shows it.
pub const Gfx = struct {
    /// The GUI backend's name: cocoa, win32, x11 or headless.
    backend: []const u8,
    /// Whether /dev/snarf is the host clipboard (not `--gfx=noclip`).
    clipboard: bool = true,
    scale: u8 = 1,
};

pub const Inputs = struct {
    /// Host root tree, or null for a 9P root or a machine with devices
    /// only.
    root: ?[]const u8,
    /// A 9P server as the root, instead of a host tree.
    root_9p: ?NinePRoot = null,
    /// Host directory bound at /mnt/term/cwd.
    cwd: ?[]const u8,
    arch: aout.Arch,
    /// Bind h9's own commands (`#H/bin`) after /bin; false leaves out
    /// the bind and masks `#H` (design/0032-guest-tools.md).
    guest_tools: bool = true,
    /// A host window: `#i`, `#m` and `#b` on /dev. Without one they're
    /// masked (design/0015-gfx.md).
    gfx: ?Gfx = null,
};

/// Compiles a policy. Allocations go in `arena`. `err_msg` explains a
/// Conflict.
pub fn compile(arena: std.mem.Allocator, in: Inputs, pol: Policy, err_msg: *[]const u8) CompileError!Plan {
    const tight = pol.profile == .tight;
    const write_req = pol.write orelse .overlay;
    const net = pol.net orelse (if (tight) NetMode.disable else .outbound);

    // Every mode is enforceable now; `unenforced` stays for capabilities a
    // future build knows but can't enforce.
    const unenforced: CapSet = .initEmpty();
    const write = write_req;

    // h9 can't make devmnt read-only, so `none` can't be kept for a
    // server it doesn't control.
    if (write == .none and in.root_9p != null) {
        err_msg.* = if (in.root_9p.?.kind == .ws) "--write=none can't be enforced on a WebSocket root" else "--write=none can't be enforced on a 9P root";
        return error.Conflict;
    }
    if (write_req == .none and pol.writable.len > 0) {
        err_msg.* = "--write=none conflicts with --writable";
        return error.Conflict;
    }
    if (pol.host_cmd and !@import("build_options").host_cmd) {
        err_msg.* = "--host-cmd: this h9 was built without host commands (zig build -Dhost-cmd)";
        return error.Conflict;
    }
    if (net == .disable and pol.net_allow.len > 0) {
        err_msg.* = "--net-allow conflicts with --net=disable";
        return error.Conflict;
    }
    const net_allow = try arena.alloc(NetPattern, pol.net_allow.len);
    var name_patterns = false;
    for (pol.net_allow, net_allow) |text, *pat| {
        var why: []const u8 = "";
        pat.* = parseNetPattern(text, &why) catch {
            err_msg.* = try std.fmt.allocPrint(arena, "--net-allow '{s}': {s}", .{ text, why });
            return error.Conflict;
        };
        if (pat.host == .name or pat.host == .suffix) name_patterns = true;
    }
    const names: ?*NameTable = if (name_patterns) blk: {
        const nt = try arena.create(NameTable);
        nt.* = .{};
        break :blk nt;
    } else null;

    // Under ephemeral, every path scope would make writable is an overlay
    // instead. The tight profile's cwd is too: it's read-only under scope
    // to keep the host's files safe, and an overlay never writes them.
    // Overlay is scope for the cwd and writable paths.
    const eph = write == .ephemeral;
    const can_write = write == .scope or write == .overlay or eph;
    const cwd_rw = can_write and (pol.cwd_writable orelse (!tight or eph));

    var rules: std.ArrayList(Rule) = .empty;
    var binds: std.ArrayList(Bind) = .empty;
    var caveats: std.ArrayList([]const u8) = .empty;

    const acc = struct {
        eph: bool,
        fn of(a: @This(), rw: bool) Access {
            return if (!rw) .ro else if (a.eph) .eph else .rw;
        }
        fn rule(a: @This(), rw: bool) @TypeOf(@as(Rule, undefined).kind) {
            return if (!rw) .allow_ro else if (a.eph) .allow_eph else .allow_rw;
        }
        /// The bind of host path `p` at `to`: from `#U`, or an overlay over
        /// it when writable under ephemeral.
        fn bind(a: @This(), arena_: std.mem.Allocator, p: []const u8, to: []const u8, rw: bool) std.mem.Allocator.Error!Bind {
            if (rw and a.eph) return .{ .from = "#O", .to = to, .create = true, .access = .eph, .lower = p };
            return .{ .from = try std.fmt.allocPrint(arena_, "#U{s}", .{p}), .to = to, .create = rw, .access = a.of(rw) };
        }
    }{ .eph = eph };

    // `--writable` on the root itself makes it write the host, except
    // under ephemeral, where nothing does.
    var root_rw = false;
    if (in.root) |root| for (pol.writable) |w| if (std.mem.eql(u8, w, root)) {
        root_rw = can_write and !eph;
    };
    // The root's overlay (design/0011-overlay.md): under overlay and
    // ephemeral, over any kind of root, unless the root writes the host.
    const root_overlay = (write == .overlay or eph) and !root_rw and (in.root != null or in.root_9p != null);

    if (in.root) |root| {
        // The overlay never writes its lower tree, so devfs keeps the
        // root read-only (`allow_eph`).
        try rules.append(arena, .{ .path = root, .kind = if (root_overlay) .allow_eph else if (root_rw) .allow_rw else .allow_ro });
        try binds.append(arena, .{ .from = try std.fmt.allocPrint(arena, "#U{s}", .{root}), .to = "/", .create = root_rw, .access = if (root_rw) .rw else .ro });
    }
    // A 9P root isn't a host path, so it has no access rule: its server
    // decides what can be written.
    if (in.root_9p) |r| try binds.append(arena, .{
        .from = root_srv,
        .to = "/",
        .mount = true,
        .spec = r.spec,
        .access = .@"9p",
        .note = try rootNote(arena, r),
    });
    // Right after the root, before every other bind, so the device sees
    // only the root's own files and everything else is bound over it.
    // Over a host tree the lower tree is the root's path through `#U`;
    // over a 9P root it's the mount, a bare `#O`.
    if (root_overlay) try binds.append(arena, .{ .from = "#O", .to = "/", .create = true, .access = .eph, .lower = in.root });
    const has_root = in.root != null or in.root_9p != null;

    try binds.append(arena, .{ .from = "#c", .to = "/dev", .optional = true });
    try binds.append(arena, .{ .from = "#y", .to = "/dev", .flag = .before, .console = true });
    // The window's devices (design/0015-gfx.md), after the console so
    // /dev/cons stays the terminal.
    if (in.gfx != null) for ([_][]const u8{ "#i", "#m", "#b" }) |d| {
        try binds.append(arena, .{ .from = d, .to = "/dev", .flag = .after });
    };
    try binds.append(arena, .{ .from = "#e", .to = "/env", .create = true, .optional = true });
    try binds.append(arena, .{ .from = "#d", .to = "/fd", .optional = true });
    try binds.append(arena, .{ .from = "#p", .to = "/proc", .optional = true });
    // The machine's own service registry (design/0008-devsrv.md): it shows
    // nothing outside the machine, so it's in both profiles.
    try binds.append(arena, .{ .from = "#s", .to = "/srv", .create = true, .optional = true });
    if (net != .disable) {
        try binds.append(arena, .{ .from = "#I", .to = "/net", .optional = true });
        try binds.append(arena, .{ .from = "#" ++ hstream_dev, .to = "/net", .flag = .after, .optional = true, .note = "WebSockets, under --net" });
    }
    if (has_root) {
        try binds.append(arena, .{ .from = try std.fmt.allocPrint(arena, "/{s}/bin", .{in.arch.name()}), .to = "/bin", .optional = true });
        try binds.append(arena, .{ .from = "/rc/bin", .to = "/bin", .flag = .after, .optional = true });
        // h9's own commands (design/0032-guest-tools.md), after the root's
        // so a root command of the same name wins.
        if (in.guest_tools) try binds.append(arena, .{ .from = "#H/bin", .to = "/bin", .flag = .after, .optional = true, .note = "h9's commands" });
    }

    // A private /tmp in memory, over the root tree's own empty /tmp, in
    // both profiles. --write=none leaves the root's read-only /tmp.
    if (in.root) |root| if (write != .none) {
        try binds.append(arena, .{
            .from = "#O",
            .to = "/tmp",
            .create = true,
            .access = .eph,
            .lower = try std.fmt.allocPrint(arena, "{s}{s}tmp", .{ root, if (std.mem.endsWith(u8, root, "/")) "" else "/" }),
            .optional = true,
        });
    };
    // Over a 9P root, the overlay's lower tree is the root's own /tmp: a
    // bare #O, as in a namespace file.
    if (in.root_9p != null and write != .none) {
        try binds.append(arena, .{ .from = "#O", .to = "/tmp", .create = true, .access = .eph, .optional = true });
    }

    // Readable and writable paths outside the root and cwd appear under
    // /mnt/term at their host path, as in drawterm: the host's / is
    // unioned after the tree's /mnt/term, and devfs shows only the bound
    // paths and their ancestors.
    var need_mnt_term = pol.host_fs;
    for ([_][]const []const u8{ pol.readable, pol.writable }) |list| for (list) |p| {
        if (guestPlace(in, p) == .mnt_term) need_mnt_term = true;
    };
    // --host-fs shows the whole host read-only; --writable still applies.
    if (pol.host_fs) try rules.append(arena, .{ .path = "/", .kind = .allow_ro });
    if (has_root and need_mnt_term) {
        try binds.append(arena, .{ .from = "#U/", .to = "/mnt/term", .flag = .after, .access = if (pol.host_fs) .ro else null });
    }

    var guest_cwd: ?[]const u8 = null;
    if (in.cwd) |cwd| {
        try rules.append(arena, .{ .path = cwd, .kind = acc.rule(cwd_rw) });
        if (has_root) {
            var b = try acc.bind(arena, cwd, "/mnt/term/cwd", cwd_rw);
            b.fallback = "/mnt/term";
            try binds.append(arena, b);
            guest_cwd = "/mnt/term/cwd";
        }
    }

    for ([_][]const []const u8{ pol.readable, pol.writable }, [_]bool{ false, true }) |list, want_rw| for (list) |p| {
        const rw = want_rw and can_write;
        try rules.append(arena, .{ .path = p, .kind = acc.rule(rw) });
        if (!has_root) continue;
        const to: []const u8 = switch (guestPlace(in, p)) {
            .root_top, .cwd_top => continue,
            .root => |rel| try std.fmt.allocPrint(arena, "/{s}", .{rel}),
            .cwd => |rel| try std.fmt.allocPrint(arena, "/mnt/term/cwd/{s}", .{rel}),
            .mnt_term => try std.fmt.allocPrint(arena, "/mnt/term{s}", .{p}),
        };
        try binds.append(arena, try acc.bind(arena, p, to, rw));
    };

    for (pol.read_deny) |p| try rules.append(arena, .{ .path = p, .kind = .deny });

    var devmask: std.ArrayList(u8) = .empty;
    if (!pol.host_cmd) try devmask.append(arena, 'C');
    if (net == .disable) {
        try devmask.append(arena, 'I');
        try devmask.appendSlice(arena, hstream_dev);
    }
    if (!in.guest_tools) try devmask.append(arena, 'H');
    if (!pol.host_fs) try devmask.append(arena, 'U');
    // Without a window, a guest can neither open one nor reach the screen
    // another machine in the process has.
    if (in.gfx == null) try devmask.appendSlice(arena, "bim");

    var enforces: CapSet = .initMany(&.{ .@"env.scrub", .@"ipc.restrict", .@"kernel.isolation", .@"fs.write.scope" });
    if (write == .overlay or eph) enforces.insert(.@"fs.write.overlay");
    if (!pol.host_fs) enforces.insert(.@"fs.read.scope");
    if (pol.read_deny.len > 0) enforces.insert(.@"fs.read.deny");
    if (eph) enforces.insert(.@"fs.write.ephemeral");
    if (net == .disable) enforces.insert(.@"net.disable");
    if (net == .outbound) enforces.insert(.@"net.outbound");
    if (net_allow.len > 0) enforces.insert(.@"net.allow");
    if (pol.memory != null) enforces.insert(.@"res.memory");
    if (pol.pids != null) enforces.insert(.@"res.pids");
    if (pol.cpus != null) enforces.insert(.@"res.cpu");
    const timeout = pol.timeout_ns orelse (if (tight) tight_timeout_ns else null);
    if (timeout != null) enforces.insert(.@"proc.timeout");

    // Overlaid paths never reach the host, so the hardlink and res.disk
    // caveats are only for paths writable on the host.
    var any_rw = false;
    var any_eph = false;
    for (rules.items) |r| switch (r.kind) {
        .allow_rw => any_rw = true,
        // The root's overlay has its own caveat.
        .allow_eph => if (!(root_overlay and in.root != null and std.mem.eql(u8, r.path, in.root.?))) {
            any_eph = true;
        },
        else => {},
    };
    if (root_overlay) try caveats.append(arena, "writes to the root are kept in memory, count against --memory, and are lost when the machine ends; when memory runs out they fail with \"file system full\"");
    if (any_eph) try caveats.append(arena, "ephemeral files count against --memory and are lost when the machine ends");
    if (any_eph or root_overlay) try caveats.append(arena, "a file opened for writing is copied into memory whole the first time");
    if (any_rw) {
        try caveats.append(arena, "hardlinks under writable paths can modify host files outside them");
        try caveats.append(arena, "writes to writable paths are not capped (no res.disk)");
    }
    if (in.root_9p) |r| {
        // Under the root's overlay nothing reaches the server.
        if (!root_overlay) try caveats.append(arena, "writes to the 9P root go to its server, which decides what can be written");
        const plain = switch (r.kind) {
            .tcp => true,
            .unix => false,
            .ws => !std.mem.startsWith(u8, r.addr, "wss://"),
        };
        if (plain) try caveats.append(arena, "the 9P root's connection isn't encrypted");
    }
    try caveats.append(arena, "paths are checked after resolving symlinks, so a host process renaming paths concurrently can race the check");
    if (net != .disable) {
        if (net_allow.len == 0) {
            try caveats.append(arena, "outbound connections can reach any address the host can except link-local, including its loopback and local network");
            try caveats.append(arena, "refusing link-local doesn't cover every cloud metadata endpoint: some, such as fd00:ec2::254 and 100.100.100.200, use other ranges");
            try caveats.append(arena, "the guest can make the host resolve any name");
        }
        if (name_patterns) try caveats.append(arena, "name patterns trust the host's resolver: a name is allowed to reach whatever address it resolves to");
        if (net == .enable) try caveats.append(arena, "servers in the guest are reachable by anything that can reach the host's ports");
    }
    if (in.gfx) |g| {
        if (g.clipboard) try caveats.append(arena, "the guest can read and write the host clipboard through /dev/snarf");
        try caveats.append(arena, "the guest can draw anything in its window, including what looks like a host dialog");
    }
    if (pol.host_cmd) try caveats.append(arena, "#C runs host commands with the host user's rights");
    if (pol.host_fs) try caveats.append(arena, "--host-fs exposes the whole host filesystem");
    try caveats.append(arena, "/proc/n/ns shows the host paths of bound host trees");
    try caveats.append(arena, "the h9 process itself is not host-sandboxed");

    return .{
        .profile = pol.profile,
        .write = write,
        .net = net,
        .memory = pol.memory,
        .timeout_ns = timeout,
        .pids = pol.pids,
        .cpus = pol.cpus,
        .net_allow = net_allow,
        .names = names,
        .devmask = devmask.items,
        .binds = binds.items,
        .rules = rules.items,
        .enforces = enforces,
        .unenforced = unenforced,
        .caveats = caveats.items,
        .guest_cwd = guest_cwd,
        .root_9p = in.root_9p,
        .root_overlay = root_overlay,
        .gfx = in.gfx,
    };
}

const Place = union(enum) {
    root_top,
    root: []const u8,
    cwd_top,
    cwd: []const u8,
    mnt_term,
};

/// Where a host path appears in the guest: inside the root tree, inside
/// the cwd (the deeper of the two wins), or at /mnt/term/<path>.
fn guestPlace(in: Inputs, p: []const u8) Place {
    const in_root = if (in.root) |r| relUnder(r, p) else null;
    const in_cwd = if (in.cwd) |c| relUnder(c, p) else null;
    if (in_cwd != null and (in_root == null or in.cwd.?.len >= in.root.?.len)) {
        return if (in_cwd.?.len == 0) .cwd_top else .{ .cwd = in_cwd.? };
    }
    if (in_root) |rel| return if (rel.len == 0) .root_top else .{ .root = rel };
    return .mnt_term;
}

/// The path of `p` relative to `dir` if `p` is `dir` or beneath it.
pub fn relUnder(dir: []const u8, p: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, dir, "/")) return std.mem.trimStart(u8, p, "/");
    if (!std.mem.startsWith(u8, p, dir)) return null;
    if (p.len == dir.len) return "";
    if (p[dir.len] != '/') return null;
    return p[dir.len + 1 ..];
}

pub const Op = enum(c_int) { walk = 0, read = 1, write = 2, create = 3, remove = 4, rename = 5 };

pub const Verdict = enum(c_int) { allow = 0, hidden = -1, read_only = -2 };

/// The access decision for a resolved host path. Deny rules win; then the
/// longest allow rule covering the path decides. Ancestors of allowed
/// paths can be walked and listed, but not changed. Everything else is
/// hidden. Renaming a directory with any rule strictly beneath it would
/// move those paths out from under their rules, so it's refused.
pub fn checkRules(rules: []const Rule, path: []const u8, op: Op) Verdict {
    var best: ?Rule = null;
    var ancestor = false;
    var beneath = false;
    for (rules) |r| {
        if (relUnder(r.path, path) != null) {
            if (r.kind == .deny) return .hidden;
            if (best == null or r.path.len > best.?.path.len) best = r;
        } else if (relUnder(path, r.path) != null) {
            beneath = true;
            if (r.kind != .deny) ancestor = true;
        }
    }
    const mutates = op == .write or op == .create or op == .remove or op == .rename;
    if (op == .rename and beneath) return if (best == null and !ancestor) .hidden else .read_only;
    if (best) |r| return if (mutates and r.kind != .allow_rw) .read_only else .allow;
    if (ancestor) return if (mutates) .read_only else .allow;
    return .hidden;
}

/// Parses sizes such as `512m`, `2g`, `64k` or a plain byte count.
pub fn parseSize(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    const last = std.ascii.toLower(s[s.len - 1]);
    const mult: u64 = switch (last) {
        'k' => 1 << 10,
        'm' => 1 << 20,
        'g' => 1 << 30,
        't' => 1 << 40,
        else => 1,
    };
    const digits = if (mult == 1) s else s[0 .. s.len - 1];
    const n = std.fmt.parseInt(u64, digits, 10) catch return null;
    return std.math.mul(u64, n, mult) catch null;
}

/// Parses durations such as `30s`, `1m`, `500ms`, `2h`, or plain seconds.
pub fn parseDuration(s: []const u8) ?u64 {
    const units = [_]struct { []const u8, u64 }{
        .{ "ms", std.time.ns_per_ms },
        .{ "s", std.time.ns_per_s },
        .{ "m", std.time.ns_per_min },
        .{ "h", std.time.ns_per_hour },
    };
    for (units) |u| if (std.mem.endsWith(u8, s, u[0])) {
        const n = std.fmt.parseInt(u64, s[0 .. s.len - u[0].len], 10) catch return null;
        return std.math.mul(u64, n, u[1]) catch null;
    };
    const n = std.fmt.parseInt(u64, s, 10) catch return null;
    return std.math.mul(u64, n, std.time.ns_per_s) catch null;
}

fn fmtSize(n: u64) std.fmt.Alt(u64, writeSize) {
    return .{ .data = n };
}

fn writeSize(n: u64, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const units = [_]struct { u64, u8 }{ .{ 1 << 40, 'T' }, .{ 1 << 30, 'G' }, .{ 1 << 20, 'M' }, .{ 1 << 10, 'K' } };
    for (units) |u| if (n >= u[0] and n % u[0] == 0) return w.print("{d}{c}", .{ n / u[0], u[1] });
    try w.print("{d}", .{n});
}

fn fmtDuration(n: u64) std.fmt.Alt(u64, writeDuration) {
    return .{ .data = n };
}

fn writeDuration(n: u64, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const units = [_]struct { u64, []const u8 }{ .{ std.time.ns_per_hour, "h" }, .{ std.time.ns_per_min, "m" }, .{ std.time.ns_per_s, "s" }, .{ std.time.ns_per_ms, "ms" } };
    for (units) |u| if (n >= u[0] and n % u[0] == 0) return w.print("{d}{s}", .{ n / u[0], u[1] });
    try w.print("{d}ns", .{n});
}

// The network policy (design/0005-net-policy.md).

/// devip's operations, matching H9_NETCONNECT and H9_NETANNOUNCE in
/// src/kern/netcheck.h.
pub const NetOp = enum(c_int) { connect = 0, announce = 1 };

/// devip's protocols, matching S_TCP and S_UDP in devip.h.
pub const NetProto = enum(c_int) { tcp = 0, udp = 1 };

/// One --net-allow pattern, `proto!host!port`.
pub const NetPattern = struct {
    /// Null for `net` or `*`: both protocols.
    proto: ?NetProto,
    host: Host,
    port_lo: u16,
    port_hi: u16,
    /// The pattern as given, for `--print`.
    text: []const u8,

    pub const Host = union(enum) {
        /// `*`: every address and every name.
        any,
        /// An address or CIDR range. IPv4 is kept IPv4-mapped, with `bits`
        /// counted over all 128.
        cidr: struct { addr: [16]u8, bits: u8, v4: bool },
        /// A host name, matched without regard to case.
        name: []const u8,
        /// `*.example.com`, kept as `.example.com`: one or more labels
        /// before it.
        suffix: []const u8,
    };

    fn matchProtoPort(pat: NetPattern, proto: NetProto, port: u16) bool {
        if (pat.proto) |pp| if (pp != proto) return false;
        return port >= pat.port_lo and port <= pat.port_hi;
    }

    /// Whether the pattern allows a connect to an address by itself.
    pub fn matchAddr(pat: NetPattern, proto: NetProto, addr: *const [16]u8, port: u16) bool {
        if (!pat.matchProtoPort(proto, port)) return false;
        return switch (pat.host) {
            .any => true,
            .cidr => |c| c.v4 == isV4(addr) and prefixMatch(&c.addr, addr, c.bits),
            .name, .suffix => false,
        };
    }

    /// Whether the pattern allows cs to resolve `name`.
    pub fn matchName(pat: NetPattern, proto: NetProto, name: []const u8, port: u16) bool {
        if (!pat.matchProtoPort(proto, port)) return false;
        const n = std.mem.trimEnd(u8, name, ".");
        return switch (pat.host) {
            .any => true,
            .cidr => false,
            .name => |want| std.ascii.eqlIgnoreCase(n, want),
            .suffix => |suf| n.len > suf.len and std.ascii.eqlIgnoreCase(n[n.len - suf.len ..], suf),
        };
    }
};

/// Parses a --net-allow pattern. `why` says what's wrong on error.
pub fn parseNetPattern(text: []const u8, why: *[]const u8) error{Invalid}!NetPattern {
    var it = std.mem.splitScalar(u8, text, '!');
    const proto_s = it.next().?;
    const host_s = it.next() orelse return invalid(why, "want proto!host!port");
    const port_s = it.next() orelse return invalid(why, "want proto!host!port");
    if (it.next() != null) return invalid(why, "want proto!host!port");

    const proto: ?NetProto = if (std.mem.eql(u8, proto_s, "tcp"))
        .tcp
    else if (std.mem.eql(u8, proto_s, "udp"))
        .udp
    else if (std.mem.eql(u8, proto_s, "net") or std.mem.eql(u8, proto_s, "*"))
        null
    else
        return invalid(why, "the protocol must be tcp, udp, net or *");

    var lo: u16 = 0;
    var hi: u16 = 65535;
    if (!std.mem.eql(u8, port_s, "*")) {
        const bad = "the port must be a number, a range such as 8000-8099, or *";
        if (std.mem.indexOfScalar(u8, port_s, '-')) |dash| {
            lo = parsePort(port_s[0..dash]) orelse return invalid(why, bad);
            hi = parsePort(port_s[dash + 1 ..]) orelse return invalid(why, bad);
            if (lo > hi) return invalid(why, "the port range is backwards");
        } else {
            lo = parsePort(port_s) orelse return invalid(why, bad);
            hi = lo;
        }
    }

    const host = try parseHost(host_s, why);
    return .{ .proto = proto, .host = host, .port_lo = lo, .port_hi = hi, .text = text };
}

fn invalid(why: *[]const u8, msg: []const u8) error{Invalid} {
    why.* = msg;
    return error.Invalid;
}

fn parsePort(s: []const u8) ?u16 {
    if (s.len == 0) return null;
    for (s) |ch| if (!std.ascii.isDigit(ch)) return null;
    return std.fmt.parseInt(u16, s, 10) catch null;
}

fn parseHost(s: []const u8, why: *[]const u8) error{Invalid}!NetPattern.Host {
    if (s.len == 0) return invalid(why, "the host is empty");
    if (std.mem.eql(u8, s, "*")) return .any;
    if (std.mem.indexOfScalar(u8, s, '/')) |slash| {
        const a = parseIp(s[0..slash]) orelse return invalid(why, "a CIDR range needs an IPv4 or IPv6 address before the /");
        const v4 = isV4(&a);
        const max: u8 = if (v4) 32 else 128;
        const bits_s = s[slash + 1 ..];
        if (bits_s.len == 0) return invalid(why, "the prefix length is missing");
        for (bits_s) |ch| if (!std.ascii.isDigit(ch)) return invalid(why, "the prefix length must be a number");
        const bits = std.fmt.parseInt(u8, bits_s, 10) catch return invalid(why, "the prefix length is too long");
        if (bits > max) return invalid(why, if (v4) "an IPv4 prefix is at most 32 bits" else "an IPv6 prefix is at most 128 bits");
        return .{ .cidr = .{ .addr = a, .bits = if (v4) bits + 96 else bits, .v4 = v4 } };
    }
    if (parseIp(s)) |a| return .{ .cidr = .{ .addr = a, .bits = 128, .v4 = isV4(&a) } };
    const n = std.mem.trimEnd(u8, s, ".");
    if (std.mem.startsWith(u8, n, "*.")) {
        if (!validName(n[2..])) return invalid(why, "not an address, a CIDR range, * or a host name");
        return .{ .suffix = n[1..] };
    }
    if (!validName(n)) return invalid(why, "not an address, a CIDR range, * or a host name");
    return .{ .name = n };
}

/// Letters, digits, hyphens and underscores, in dot-separated labels.
fn validName(s: []const u8) bool {
    if (s.len == 0 or s.len > 253) return false;
    var labels = std.mem.splitScalar(u8, s, '.');
    while (labels.next()) |l| {
        if (l.len == 0 or l.len > 63) return false;
        for (l) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_')) return false;
    }
    return true;
}

const v4_prefix = [12]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };

/// Whether a 16-byte address is IPv4-mapped.
pub fn isV4(a: *const [16]u8) bool {
    return std.mem.eql(u8, a[0..12], &v4_prefix);
}

fn prefixMatch(p: *const [16]u8, a: *const [16]u8, bits: u8) bool {
    const whole = bits / 8;
    if (!std.mem.eql(u8, p[0..whole], a[0..whole])) return false;
    const rest: u3 = @intCast(bits % 8);
    if (rest == 0) return true;
    const mask: u8 = @as(u8, 0xff) << @intCast(8 - @as(u4, rest));
    return (p[whole] & mask) == (a[whole] & mask);
}

/// 169.254.0.0/16 and fe80::/10, refused without --net-allow.
pub fn isLinkLocal(a: *const [16]u8) bool {
    if (isV4(a)) return a[12] == 169 and a[13] == 254;
    return a[0] == 0xfe and (a[1] & 0xc0) == 0x80;
}

/// Parses an IPv4 or IPv6 address into devip's 16-byte form, IPv4 as
/// IPv4-mapped. IPv4-mapped IPv6 spellings come out as IPv4.
pub fn parseIp(s: []const u8) ?[16]u8 {
    var out: [16]u8 = undefined;
    if (std.mem.indexOfScalar(u8, s, ':') == null) {
        @memcpy(out[0..12], &v4_prefix);
        if (!parseV4(s, out[12..16])) return null;
        return out;
    }
    // IPv6: up to eight groups, one `::`, and an optional IPv4 tail.
    var head: [16]u8 = @splat(0);
    var tail: [16]u8 = @splat(0);
    var nhead: usize = 0;
    var ntail: usize = 0;
    var gap = false;
    var rest = s;
    if (std.mem.startsWith(u8, rest, "::")) {
        gap = true;
        rest = rest[2..];
    } else if (std.mem.startsWith(u8, rest, ":")) return null;
    while (rest.len > 0) {
        const end = std.mem.indexOfScalar(u8, rest, ':') orelse rest.len;
        const group = rest[0..end];
        const buf = if (gap) &tail else &head;
        const n = if (gap) &ntail else &nhead;
        if (end == rest.len and std.mem.indexOfScalar(u8, group, '.') != null) {
            if (n.* + 4 > 16) return null;
            if (!parseV4(group, buf[n.*..][0..4])) return null;
            n.* += 4;
            rest = rest[end..];
            break;
        }
        if (group.len == 0 or group.len > 4) return null;
        const v = std.fmt.parseInt(u16, group, 16) catch return null;
        if (n.* + 2 > 16) return null;
        buf[n.*] = @intCast(v >> 8);
        buf[n.* + 1] = @truncate(v);
        n.* += 2;
        rest = rest[end..];
        if (rest.len == 0) break;
        rest = rest[1..];
        if (std.mem.startsWith(u8, rest, ":")) {
            if (gap) return null;
            gap = true;
            rest = rest[1..];
        } else if (rest.len == 0) return null;
    }
    if (gap) {
        if (nhead + ntail > 14) return null;
    } else if (nhead != 16) return null;
    out = @splat(0);
    @memcpy(out[0..nhead], head[0..nhead]);
    @memcpy(out[16 - ntail ..], tail[0..ntail]);
    return out;
}

fn parseV4(s: []const u8, out: *[4]u8) bool {
    var parts = std.mem.splitScalar(u8, s, '.');
    var i: usize = 0;
    while (parts.next()) |part| : (i += 1) {
        if (i == 4 or part.len == 0 or part.len > 3) return false;
        for (part) |ch| if (!std.ascii.isDigit(ch)) return false;
        out[i] = std.fmt.parseInt(u8, part, 10) catch return false;
    }
    return i == 4;
}

/// What devip's cs resolved for allowed names, so a later connect to
/// one of the addresses can be matched against name patterns. One per
/// machine; it keeps the most recent `capacity` entries.
pub const NameTable = struct {
    lock: std.atomic.Mutex = .unlocked,
    entries: [capacity]Entry = undefined,
    /// Entries recorded so far; the oldest is overwritten once full.
    count: usize = 0,

    pub const capacity = 1024;
    pub const max_name = 255;

    pub const Entry = struct {
        proto: NetProto,
        port: u16,
        addr: [16]u8,
        name_len: u8,
        name_buf: [max_name]u8,

        pub fn name(e: *const Entry) []const u8 {
            return e.name_buf[0..e.name_len];
        }
    };

    fn acquire(nt: *NameTable) void {
        while (!nt.lock.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn record(nt: *NameTable, proto: NetProto, addr: *const [16]u8, port: u16, name: []const u8) void {
        if (name.len > max_name) return;
        nt.acquire();
        defer nt.lock.unlock();
        const e = &nt.entries[nt.count % capacity];
        e.* = .{ .proto = proto, .port = port, .addr = addr.*, .name_len = @intCast(name.len), .name_buf = undefined };
        @memcpy(e.name_buf[0..name.len], name);
        nt.count += 1;
    }

    /// Whether a name that resolved to addr for proto and port matches a
    /// name pattern.
    pub fn allows(nt: *NameTable, pats: []const NetPattern, proto: NetProto, addr: *const [16]u8, port: u16) bool {
        nt.acquire();
        defer nt.lock.unlock();
        const n = @min(nt.count, capacity);
        for (nt.entries[0..n]) |*e| {
            if (e.proto != proto or e.port != port or !std.mem.eql(u8, &e.addr, addr)) continue;
            for (pats) |pat| switch (pat.host) {
                .name, .suffix => if (pat.matchName(proto, e.name(), port)) return true,
                else => {},
            };
        }
        return false;
    }
};

const t = std.testing;

test "rules: deny wins, longest allow decides, ancestors are read-only" {
    const rules = [_]Rule{
        .{ .path = "/r", .kind = .allow_ro },
        .{ .path = "/r/usr/me", .kind = .allow_rw },
        .{ .path = "/w", .kind = .allow_rw },
        .{ .path = "/w/.env", .kind = .deny },
        .{ .path = "/home/me/proj", .kind = .allow_ro },
    };
    try t.expectEqual(Verdict.allow, checkRules(&rules, "/r/bin/cat", .read));
    try t.expectEqual(Verdict.read_only, checkRules(&rules, "/r/bin/cat", .write));
    try t.expectEqual(Verdict.allow, checkRules(&rules, "/r/usr/me/x", .create));
    try t.expectEqual(Verdict.allow, checkRules(&rules, "/w/f", .remove));
    try t.expectEqual(Verdict.hidden, checkRules(&rules, "/w/.env", .read));
    try t.expectEqual(Verdict.hidden, checkRules(&rules, "/w/.env/x", .walk));
    try t.expectEqual(Verdict.allow, checkRules(&rules, "/w/.envrc", .read));
    try t.expectEqual(Verdict.allow, checkRules(&rules, "/home", .walk));
    try t.expectEqual(Verdict.read_only, checkRules(&rules, "/home", .create));
    try t.expectEqual(Verdict.hidden, checkRules(&rules, "/home/other", .walk));
    try t.expectEqual(Verdict.hidden, checkRules(&rules, "/rx", .read));
    try t.expectEqual(Verdict.allow, checkRules(&rules, "/", .read));
    // Renames can't move rules' paths.
    try t.expectEqual(Verdict.read_only, checkRules(&rules, "/w", .rename));
    try t.expectEqual(Verdict.read_only, checkRules(&rules, "/r/usr", .rename));
    try t.expectEqual(Verdict.allow, checkRules(&rules, "/w/f", .rename));
    try t.expectEqual(Verdict.read_only, checkRules(&rules, "/r/bin", .rename));
}

test "compile: default and tight profiles" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var msg: []const u8 = "";
    const in: Inputs = .{ .root = "/r", .cwd = "/w", .arch = .arm64 };

    const d = try compile(arena.allocator(), in, .{}, &msg);
    try t.expectEqual(Verdict.allow, d.check("/w/f", .create));
    try t.expectEqual(Verdict.read_only, d.check("/r/f", .create));
    try t.expectEqualStrings("CUbim", d.devmask);
    try t.expect(!d.enforces.contains(.@"net.disable"));
    try t.expectEqual(@as(?u64, null), d.timeout_ns);

    const tt = try compile(arena.allocator(), in, .{ .profile = .tight }, &msg);
    try t.expectEqual(Verdict.read_only, tt.check("/w/f", .create));
    try t.expectEqualStrings("CI" ++ hstream_dev ++ "Ubim", tt.devmask);
    try t.expect(tt.enforces.contains(.@"net.disable"));
    try t.expect(tt.enforces.contains(.@"proc.timeout"));

    // --sandbox: tight, with the cwd writable.
    const sb = try compile(arena.allocator(), in, .{ .profile = .tight, .cwd_writable = true }, &msg);
    try t.expectEqual(Verdict.allow, sb.check("/w/f", .create));

    // An explicit writable path under a read-only cwd.
    const wr = try compile(arena.allocator(), in, .{ .profile = .tight, .writable = &.{"/w/out"} }, &msg);
    try t.expectEqual(Verdict.allow, wr.check("/w/out/x", .create));
    try t.expectEqual(Verdict.read_only, wr.check("/w/x", .create));
    var found = false;
    for (wr.binds) |b| if (std.mem.eql(u8, b.to, "/mnt/term/cwd/out")) {
        found = true;
    };
    try t.expect(found);
}

test "compile: --write=none conflicts with --writable" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var msg: []const u8 = "";
    const in: Inputs = .{ .root = "/r", .cwd = "/w", .arch = .arm64 };
    try t.expectError(error.Conflict, compile(arena.allocator(), in, .{ .write = .none, .writable = &.{"/w"} }, &msg));
}

test "compile: the root's overlay (design/0011-overlay.md)" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var msg: []const u8 = "";
    const in: Inputs = .{ .root = "/r", .cwd = "/w", .arch = .arm64 };

    const Find = struct {
        /// The index of the first bind onto `to` from `from`.
        fn at(p: Plan, from: []const u8, to: []const u8) ?usize {
            for (p.binds, 0..) |b, i| if (std.mem.eql(u8, b.from, from) and std.mem.eql(u8, b.to, to)) return i;
            return null;
        }
    };

    // The default, in both profiles: #U then #O on /, before every other
    // bind, and devfs keeps the root read-only.
    for ([_]Profile{ .default, .tight }) |prof| {
        const p = try compile(a, in, .{ .profile = prof }, &msg);
        try t.expectEqual(WriteMode.overlay, p.write);
        try t.expect(p.root_overlay);
        try t.expectEqual(@as(?usize, 0), Find.at(p, "#U/r", "/"));
        try t.expectEqual(@as(?usize, 1), Find.at(p, "#O", "/"));
        const o = p.binds[1];
        try t.expectEqualStrings("/r", o.lower.?);
        try t.expect(o.create);
        try t.expectEqual(Access.eph, o.access.?);
        try t.expectEqual(Verdict.read_only, p.check("/r/lib/x", .create));
        try t.expectEqual(Verdict.allow, p.check("/r/lib/x", .read));
        try t.expect(p.enforces.contains(.@"fs.write.overlay"));
        try t.expect(p.unenforced.count() == 0);
    }
    // The cwd still writes the host under overlay, and tight's stays
    // read-only.
    try t.expectEqual(Verdict.allow, (try compile(a, in, .{ .write = .overlay }, &msg)).check("/w/f", .create));
    try t.expectEqual(Verdict.read_only, (try compile(a, in, .{ .profile = .tight }, &msg)).check("/w/f", .create));

    // scope and none keep the root read-only, with no overlay.
    for ([_]WriteMode{ .scope, .none }) |w| for ([_]Profile{ .default, .tight }) |prof| {
        const p = try compile(a, in, .{ .profile = prof, .write = w }, &msg);
        try t.expect(!p.root_overlay);
        try t.expectEqual(@as(?usize, null), Find.at(p, "#O", "/"));
        try t.expect(!p.enforces.contains(.@"fs.write.overlay"));
    };

    // Ephemeral overlays the root too, writable or not.
    for ([_][]const []const u8{ &.{}, &.{"/r"} }) |wr| {
        const p = try compile(a, in, .{ .write = .ephemeral, .writable = wr }, &msg);
        try t.expect(p.root_overlay);
        try t.expectEqual(@as(?usize, 0), Find.at(p, "#U/r", "/"));
        try t.expectEqual(@as(?usize, 1), Find.at(p, "#O", "/"));
        try t.expectEqual(Verdict.read_only, p.check("/r/f", .create));
        try t.expect(p.enforces.contains(.@"fs.write.overlay"));
        try t.expect(p.enforces.contains(.@"fs.write.ephemeral"));
    }

    // --writable on the root writes the host, with no overlay, under
    // scope and overlay.
    for ([_]WriteMode{ .scope, .overlay }) |w| {
        const p = try compile(a, in, .{ .write = w, .writable = &.{"/r"} }, &msg);
        try t.expect(!p.root_overlay);
        try t.expectEqual(@as(?usize, null), Find.at(p, "#O", "/"));
        try t.expect(p.binds[0].create);
        try t.expectEqual(Access.rw, p.binds[0].access.?);
        try t.expectEqual(Verdict.allow, p.check("/r/f", .create));
    }

    // A writable path inside the root is bound from #U over the overlay.
    const g = try compile(a, in, .{ .writable = &.{"/r/usr/glenda"} }, &msg);
    const gi = Find.at(g, "#U/r/usr/glenda", "/usr/glenda").?;
    try t.expect(gi > Find.at(g, "#O", "/").?);
    try t.expectEqual(Verdict.allow, g.check("/r/usr/glenda/x", .create));
    try t.expectEqual(Verdict.read_only, g.check("/r/usr/x", .create));

    // A 9P root: a bare #O over the mount, and no "server" caveat.
    const nr = try compile(a, .{ .root = null, .root_9p = .{ .kind = .tcp, .addr = "tcp!h!564" }, .cwd = "/w", .arch = .arm64 }, .{}, &msg);
    try t.expect(nr.root_overlay);
    const ni = Find.at(nr, "#O", "/").?;
    try t.expectEqual(@as(usize, 1), ni);
    try t.expectEqual(@as(?[]const u8, null), nr.binds[ni].lower);
    for (nr.caveats) |c| try t.expect(std.mem.indexOf(u8, c, "go to its server") == null);
    const ns = try compile(a, .{ .root = null, .root_9p = .{ .kind = .tcp, .addr = "tcp!h!564" }, .cwd = "/w", .arch = .arm64 }, .{ .write = .scope }, &msg);
    try t.expect(!ns.root_overlay);
    var server = false;
    for (ns.caveats) |c| if (std.mem.indexOf(u8, c, "go to its server") != null) {
        server = true;
    };
    try t.expect(server);

    // The plan as --print shows it.
    const d = try compile(a, in, .{}, &msg);
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try d.print(&out.writer);
    const text = out.written();
    try t.expect(std.mem.indexOf(u8, text, "enforces: env.scrub fs.read.scope fs.write.overlay fs.write.scope") != null);
    try t.expect(std.mem.indexOf(u8, text, "limits:   write=overlay") != null);
    try t.expect(std.mem.indexOf(u8, text, "  bind '#U/r' /") != null);
    try t.expect(std.mem.indexOf(u8, text, "  bind -c '#O' /                                         eph  # /r\n") != null);
    try t.expect(std.mem.indexOf(u8, text, "  eph  /r\n") != null);
    try t.expect(std.mem.indexOf(u8, text, "writes to the root are kept in memory") != null);
    try t.expect(std.mem.indexOf(u8, text, "ephemeral files count against --memory") == null);
}

test "compile: paths outside the root and cwd go under /mnt/term" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var msg: []const u8 = "";
    const p = try compile(arena.allocator(), .{ .root = "/r", .cwd = "/w", .arch = .arm64 }, .{ .readable = &.{"/src/proj"} }, &msg);
    var union_bind = false;
    var path_bind = false;
    for (p.binds) |b| {
        if (std.mem.eql(u8, b.from, "#U/") and std.mem.eql(u8, b.to, "/mnt/term")) union_bind = true;
        if (std.mem.eql(u8, b.to, "/mnt/term/src/proj")) path_bind = true;
    }
    try t.expect(union_bind and path_bind);
    try t.expectEqual(Verdict.allow, p.check("/src", .walk));
    try t.expectEqual(Verdict.hidden, p.check("/etc/passwd", .read));
}

test "sizes and durations" {
    try t.expectEqual(@as(?u64, 512 << 20), parseSize("512m"));
    try t.expectEqual(@as(?u64, 2 << 30), parseSize("2G"));
    try t.expectEqual(@as(?u64, 4096), parseSize("4096"));
    try t.expectEqual(@as(?u64, null), parseSize("x"));
    try t.expectEqual(@as(?u64, 30 * std.time.ns_per_s), parseDuration("30s"));
    try t.expectEqual(@as(?u64, 500 * std.time.ns_per_ms), parseDuration("500ms"));
    try t.expectEqual(@as(?u64, std.time.ns_per_min), parseDuration("1m"));
    try t.expectEqual(@as(?u64, 5 * std.time.ns_per_s), parseDuration("5"));
    try t.expectEqual(@as(?u64, null), parseDuration("1y"));
}

fn tip(s: []const u8) [16]u8 {
    return parseIp(s).?;
}

fn tpat(s: []const u8) !NetPattern {
    var why: []const u8 = "";
    return parseNetPattern(s, &why);
}

test "net: address parsing" {
    try t.expect(isV4(&tip("10.0.0.5")));
    try t.expect(isV4(&tip("::ffff:10.0.0.5")));
    try t.expectEqualSlices(u8, &tip("10.0.0.5"), &tip("::ffff:10.0.0.5"));
    try t.expect(!isV4(&tip("::1")));
    try t.expectEqual(@as(u8, 1), tip("::1")[15]);
    try t.expectEqualSlices(u8, &tip("fe80:0:0:0:0:0:0:1"), &tip("fe80::1"));
    try t.expectEqual(@as(u8, 0xfd), tip("fd00:ec2::254")[0]);
    try t.expectEqual(@as(u8, 0x54), tip("fd00:ec2::254")[15]);
    for ([_][]const u8{ "1.2.3", "1.2.3.4.5", "256.0.0.1", "1..2.3", ":::", "1::2::3", "1:2:3:4:5:6:7:8:9", "12345::", ":1::", "1:" }) |bad| {
        try t.expectEqual(@as(?[16]u8, null), parseIp(bad));
    }
}

test "net: pattern parsing" {
    const a = try tpat("tcp!10.0.0.0/8!564");
    try t.expectEqual(@as(?NetProto, .tcp), a.proto);
    try t.expectEqual(@as(u16, 564), a.port_lo);
    try t.expectEqual(@as(u8, 104), a.host.cidr.bits);
    const b = try tpat("net!*.example.com!8000-8099");
    try t.expectEqual(@as(?NetProto, null), b.proto);
    try t.expectEqualStrings(".example.com", b.host.suffix);
    try t.expectEqual(@as(u16, 8099), b.port_hi);
    const c = try tpat("*!*!*");
    try t.expect(c.host == .any and c.port_lo == 0 and c.port_hi == 65535);
    try t.expectEqualStrings("api.example.com", (try tpat("udp!api.example.com.!53")).host.name);
    var why: []const u8 = "";
    for ([_][]const u8{ "tcp!1.2.3.4", "il!1.2.3.4!1", "tcp!1.2.3.4!http", "tcp!1.2.3.4!9-1", "tcp!1.2.3.4!70000", "tcp!10.0.0.0/33!1", "tcp!::/129!1", "tcp!a*b.com!1", "tcp!!1", "tcp!1.2.3.4!1!r" }) |bad| {
        try t.expectError(error.Invalid, parseNetPattern(bad, &why));
        try t.expect(why.len > 0);
    }
}

test "net: CIDR edges and IPv4-mapped matching" {
    const v4 = try tpat("tcp!10.0.0.0/8!*");
    try t.expect(v4.matchAddr(.tcp, &tip("10.255.255.255"), 1));
    try t.expect(v4.matchAddr(.tcp, &tip("::ffff:10.1.2.3"), 1));
    try t.expect(!v4.matchAddr(.tcp, &tip("11.0.0.0"), 1));
    try t.expect(!v4.matchAddr(.udp, &tip("10.0.0.1"), 1));
    const odd = try tpat("tcp!192.168.4.0/22!*");
    try t.expect(odd.matchAddr(.tcp, &tip("192.168.7.255"), 1));
    try t.expect(!odd.matchAddr(.tcp, &tip("192.168.8.0"), 1));
    const v6 = try tpat("tcp!fd00::/8!*");
    try t.expect(v6.matchAddr(.tcp, &tip("fdff::1"), 1));
    try t.expect(!v6.matchAddr(.tcp, &tip("fe00::1"), 1));
    // An IPv6 pattern never matches an IPv4 address.
    const all6 = try tpat("tcp!::/0!*");
    try t.expect(all6.matchAddr(.tcp, &tip("::1"), 1));
    try t.expect(!all6.matchAddr(.tcp, &tip("10.0.0.1"), 1));
    const all4 = try tpat("tcp!0.0.0.0/0!*");
    try t.expect(all4.matchAddr(.tcp, &tip("10.0.0.1"), 1));
    try t.expect(!all4.matchAddr(.tcp, &tip("::1"), 1));
    const one = try tpat("tcp!10.0.0.5!443");
    try t.expect(one.matchAddr(.tcp, &tip("10.0.0.5"), 443));
    try t.expect(!one.matchAddr(.tcp, &tip("10.0.0.6"), 443));
    try t.expect(!one.matchAddr(.tcp, &tip("10.0.0.5"), 444));
    // Link-local, however IPv4 is written.
    try t.expect(isLinkLocal(&tip("169.254.169.254")));
    try t.expect(isLinkLocal(&tip("::ffff:169.254.0.1")));
    try t.expect(isLinkLocal(&tip("fe80::1")));
    try t.expect(isLinkLocal(&tip("febf::1")));
    try t.expect(!isLinkLocal(&tip("fec0::1")));
    try t.expect(!isLinkLocal(&tip("::a9fe:a9fe")));
    try t.expect(!isLinkLocal(&tip("127.0.0.1")));
}

test "net: port ranges and name wildcards" {
    const r = try tpat("tcp!*!8000-8099");
    try t.expect(r.matchAddr(.tcp, &tip("1.2.3.4"), 8000));
    try t.expect(r.matchAddr(.tcp, &tip("1.2.3.4"), 8099));
    try t.expect(!r.matchAddr(.tcp, &tip("1.2.3.4"), 7999));
    try t.expect(!r.matchAddr(.tcp, &tip("1.2.3.4"), 8100));
    const w = try tpat("tcp!*.example.com!443");
    try t.expect(w.matchName(.tcp, "a.example.com", 443));
    try t.expect(w.matchName(.tcp, "a.b.EXAMPLE.com.", 443));
    try t.expect(!w.matchName(.tcp, "example.com", 443));
    try t.expect(!w.matchName(.tcp, "badexample.com", 443));
    try t.expect(!w.matchName(.tcp, "a.example.com", 80));
    try t.expect(!w.matchAddr(.tcp, &tip("1.2.3.4"), 443));
    const n = try tpat("net!localhost!*");
    try t.expect(n.matchName(.udp, "LocalHost", 9));
    try t.expect(!n.matchName(.tcp, "localhost.example", 9));
    const a = try tpat("tcp!127.0.0.1!*");
    try t.expect(!a.matchName(.tcp, "localhost", 1));
}

test "net: the plan's checks" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var msg: []const u8 = "";
    const in: Inputs = .{ .root = "/r", .cwd = "/w", .arch = .arm64 };

    const d = try compile(arena.allocator(), in, .{}, &msg);
    try t.expectEqual(NetMode.outbound, d.net);
    try t.expect(d.enforces.contains(.@"net.outbound"));
    try t.expect(!d.enforces.contains(.@"net.allow"));
    try t.expect(d.netCheck(.connect, .tcp, &tip("127.0.0.1"), 80));
    try t.expect(!d.netCheck(.connect, .tcp, &tip("169.254.169.254"), 80));
    try t.expect(!d.netCheck(.connect, .udp, &tip("fe80::1"), 53));
    try t.expect(!d.netCheck(.announce, .tcp, &tip("127.0.0.1"), 8080));
    try t.expect(d.netLookup(.tcp, "anything.example", 80));

    const e = try compile(arena.allocator(), in, .{ .net = .enable }, &msg);
    try t.expect(e.netCheck(.announce, .udp, &tip("0.0.0.0"), 53));
    try t.expect(!e.netCheck(.connect, .tcp, &tip("169.254.169.254"), 80));

    // Patterns are the whole policy.
    const ll = try compile(arena.allocator(), in, .{ .net_allow = &.{"tcp!169.254.0.0/16!*"} }, &msg);
    try t.expect(ll.netCheck(.connect, .tcp, &tip("169.254.169.254"), 80));
    try t.expect(!ll.netCheck(.connect, .tcp, &tip("127.0.0.1"), 80));
    try t.expect(!ll.netLookup(.tcp, "localhost", 80));
    try t.expect(ll.names == null);
    try t.expect(ll.enforces.contains(.@"net.allow"));

    const nm = try compile(arena.allocator(), in, .{ .net_allow = &.{ "tcp!*.example.com!443", "udp!10.0.0.53!53" } }, &msg);
    try t.expect(nm.netLookup(.tcp, "api.example.com", 443));
    try t.expect(!nm.netLookup(.tcp, "api.example.com", 80));
    try t.expect(!nm.netLookup(.udp, "api.example.com", 443));
    try t.expect(!nm.netLookup(.tcp, "example.org", 443));
    try t.expect(!nm.netCheck(.connect, .tcp, &tip("93.184.216.34"), 443));
    nm.netResolved(.tcp, "api.example.com", 443, &.{ tip("93.184.216.34"), tip("2606:2800::1") });
    try t.expect(nm.netCheck(.connect, .tcp, &tip("93.184.216.34"), 443));
    try t.expect(nm.netCheck(.connect, .tcp, &tip("2606:2800::1"), 443));
    try t.expect(!nm.netCheck(.connect, .tcp, &tip("93.184.216.34"), 80));
    try t.expect(!nm.netCheck(.connect, .udp, &tip("93.184.216.34"), 443));
    try t.expect(nm.netCheck(.connect, .udp, &tip("10.0.0.53"), 53));
    try t.expect(!nm.netCheck(.connect, null, &tip("10.0.0.53"), 53));

    try t.expectError(error.Conflict, compile(arena.allocator(), in, .{ .net = .disable, .net_allow = &.{"tcp!*!*"} }, &msg));
    try t.expectError(error.Conflict, compile(arena.allocator(), in, .{ .net_allow = &.{"tcp!x!y"} }, &msg));
    try t.expect(std.mem.indexOf(u8, msg, "tcp!x!y") != null);
}

test "net: the resolved-name table keeps the most recent entries" {
    const nt = try t.allocator.create(NameTable);
    defer t.allocator.destroy(nt);
    nt.* = .{};
    const pats = [_]NetPattern{try tpat("tcp!*.example.com!443")};
    nt.record(.tcp, &tip("10.0.0.1"), 443, "first.example.com");
    try t.expect(nt.allows(&pats, .tcp, &tip("10.0.0.1"), 443));
    var i: u32 = 0;
    while (i < NameTable.capacity) : (i += 1) {
        var a = tip("10.1.0.0");
        a[14] = @truncate(i >> 8);
        a[15] = @truncate(i);
        nt.record(.tcp, &a, 443, "later.example.com");
    }
    // The first entry was evicted; the newest are kept.
    try t.expect(!nt.allows(&pats, .tcp, &tip("10.0.0.1"), 443));
    try t.expect(nt.allows(&pats, .tcp, &tip("10.1.3.255"), 443));
    try t.expect(nt.allows(&pats, .tcp, &tip("10.1.0.0"), 443));
    // A name that no longer matches a pattern allows nothing.
    nt.record(.tcp, &tip("10.2.0.1"), 443, "other.org");
    try t.expect(!nt.allows(&pats, .tcp, &tip("10.2.0.1"), 443));
}

test "net: --print shows patterns and caveats" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var msg: []const u8 = "";
    const p = try compile(arena.allocator(), .{ .root = "/r", .cwd = "/w", .arch = .arm64 }, .{ .net_allow = &.{ "tcp!*.example.com!443", "udp!10.0.0.53!53" } }, &msg);
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try p.print(&out.writer);
    const s = out.written();
    try t.expect(std.mem.indexOf(u8, s, "net.allow net.outbound") != null);
    try t.expect(std.mem.indexOf(u8, s, "net=outbound") != null);
    try t.expect(std.mem.indexOf(u8, s, "net-allow:\n  tcp!*.example.com!443\n  udp!10.0.0.53!53\nnamespace:") != null);
    try t.expect(std.mem.indexOf(u8, s, "name patterns trust the host's resolver") != null);
    try t.expect(std.mem.indexOf(u8, s, "not restricted beyond") == null);
}

test "compile: a private /tmp, and --write=ephemeral overlays the writable paths" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var msg: []const u8 = "";
    const in: Inputs = .{ .root = "/r", .cwd = "/w", .arch = .arm64 };

    const Find = struct {
        fn bind(p: Plan, to: []const u8) ?Bind {
            for (p.binds) |b| if (std.mem.eql(u8, b.to, to)) return b;
            return null;
        }
    };

    // /tmp is an overlay over the root's /tmp in both profiles, and the
    // host temp dir isn't bound.
    for ([_]Profile{ .default, .tight }) |prof| {
        const p = try compile(arena.allocator(), in, .{ .profile = prof }, &msg);
        const tmp = Find.bind(p, "/tmp").?;
        try t.expectEqualStrings("#O", tmp.from);
        try t.expectEqualStrings("/r/tmp", tmp.lower.?);
        try t.expect(tmp.create);
        try t.expectEqual(Access.eph, tmp.access.?);
        try t.expect(!p.enforces.contains(.@"fs.write.ephemeral"));
    }
    const none = try compile(arena.allocator(), in, .{ .write = .none }, &msg);
    try t.expectEqual(@as(?Bind, null), Find.bind(none, "/tmp"));

    // Ephemeral: the cwd and writable paths are overlays, read-only to devfs.
    const e = try compile(arena.allocator(), in, .{ .write = .ephemeral, .writable = &.{"/w/out"} }, &msg);
    try t.expect(e.enforces.contains(.@"fs.write.ephemeral"));
    try t.expect(e.unenforced.count() == 0);
    try t.expectEqual(WriteMode.ephemeral, e.write);
    const cwd = Find.bind(e, "/mnt/term/cwd").?;
    try t.expectEqualStrings("#O", cwd.from);
    try t.expectEqualStrings("/w", cwd.lower.?);
    try t.expectEqualStrings("/mnt/term", cwd.fallback.?);
    try t.expectEqualStrings("/w/out", Find.bind(e, "/mnt/term/cwd/out").?.lower.?);
    try t.expectEqual(Verdict.read_only, e.check("/w/f", .create));
    try t.expectEqual(Verdict.read_only, e.check("/w/out/f", .write));
    try t.expectEqual(Verdict.allow, e.check("/w/out/f", .read));
    // The root is read-only to devfs, under an overlay (design/0011-overlay.md).
    try t.expectEqualStrings("#U/r", Find.bind(e, "/").?.from);
    try t.expectEqual(Verdict.read_only, e.check("/r/f", .create));
    for (e.caveats) |c| try t.expect(std.mem.indexOf(u8, c, "hardlinks") == null);

    // The tight profile's cwd is an overlay too.
    const te = try compile(arena.allocator(), in, .{ .profile = .tight, .write = .ephemeral }, &msg);
    try t.expectEqualStrings("#O", Find.bind(te, "/mnt/term/cwd").?.from);


    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try e.print(&out.writer);
    const text = out.written();
    try t.expect(std.mem.indexOf(u8, text, "enforces: env.scrub fs.read.scope fs.write.ephemeral fs.write.overlay fs.write.scope") != null);
    try t.expect(std.mem.indexOf(u8, text, "limits:   write=ephemeral") != null);
    try t.expect(std.mem.indexOf(u8, text, "  bind -c '#O' /mnt/term/cwd") != null);
    try t.expect(std.mem.indexOf(u8, text, " eph  # /w\n") != null);
    try t.expect(std.mem.indexOf(u8, text, " eph  # /r/tmp\n") != null);
    try t.expect(std.mem.indexOf(u8, text, "  eph  /w\n") != null);
    try t.expect(std.mem.indexOf(u8, text, "ephemeral files count against --memory") != null);
}

test "compile: #s at /srv in both profiles, and never masked" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var msg: []const u8 = "";
    const in: Inputs = .{ .root = "/r", .cwd = "/w", .arch = .arm64 };
    for ([_]Profile{ .default, .tight }) |prof| {
        const p = try compile(arena.allocator(), in, .{ .profile = prof }, &msg);
        var found = false;
        for (p.binds) |b| if (std.mem.eql(u8, b.to, "/srv")) {
            try t.expectEqualStrings("#s", b.from);
            try t.expect(b.create);
            found = true;
        };
        try t.expect(found);
        try t.expect(std.mem.indexOfScalar(u8, p.devmask, 's') == null);

        var out: std.Io.Writer.Allocating = .init(t.allocator);
        defer out.deinit();
        try p.print(&out.writer);
        try t.expect(std.mem.indexOf(u8, out.written(), "  bind -c '#s' /srv\n") != null);
    }
}

test "compile: #H/bin after /rc/bin in both profiles, and guest_tools = false masks #H" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var msg: []const u8 = "";
    for ([_]Profile{ .default, .tight }) |prof| {
        const p = try compile(arena.allocator(), .{ .root = "/r", .cwd = "/w", .arch = .arm64 }, .{ .profile = prof }, &msg);
        var rc_at: ?usize = null;
        var h_at: ?usize = null;
        for (p.binds, 0..) |b, i| {
            if (std.mem.eql(u8, b.from, "/rc/bin")) rc_at = i;
            if (std.mem.eql(u8, b.from, "#H/bin")) {
                try t.expectEqualStrings("/bin", b.to);
                try t.expectEqual(Bind.Flag.after, b.flag);
                h_at = i;
            }
        }
        try t.expect(h_at.? > rc_at.?);
        try t.expect(std.mem.indexOfScalar(u8, p.devmask, 'H') == null);

        var out: std.Io.Writer.Allocating = .init(t.allocator);
        defer out.deinit();
        try p.print(&out.writer);
        try t.expect(std.mem.indexOf(u8, out.written(), "  bind -a '#H/bin' /bin  # h9's commands\n") != null);

        const off = try compile(arena.allocator(), .{ .root = "/r", .cwd = "/w", .arch = .arm64, .guest_tools = false }, .{ .profile = prof }, &msg);
        for (off.binds) |b| try t.expect(!std.mem.startsWith(u8, b.from, "#H"));
        try t.expect(std.mem.indexOfScalar(u8, off.devmask, 'H') != null);
    }
}

test "compile: --gfx binds #i, #m and #b after the console, and masks them without it" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var msg: []const u8 = "";
    for ([_]Profile{ .default, .tight }) |prof| {
        const off = try compile(arena.allocator(), .{ .root = "/r", .cwd = "/w", .arch = .arm64 }, .{ .profile = prof }, &msg);
        for ("bim") |d| try t.expect(std.mem.indexOfScalar(u8, off.devmask, d) != null);
        for (off.binds) |b| for ([_][]const u8{ "#i", "#m", "#b" }) |d| try t.expect(!std.mem.eql(u8, b.from, d));
        try t.expect(off.gfx == null);

        const on = try compile(arena.allocator(), .{ .root = "/r", .cwd = "/w", .arch = .arm64, .gfx = .{ .backend = "x11" } }, .{ .profile = prof }, &msg);
        for ("bim") |d| try t.expect(std.mem.indexOfScalar(u8, on.devmask, d) == null);
        var y_at: ?usize = null;
        var want: usize = 0;
        for (on.binds, 0..) |b, i| {
            if (std.mem.eql(u8, b.from, "#y")) y_at = i;
            for ([_][]const u8{ "#i", "#m", "#b" }, 0..) |d, k| if (std.mem.eql(u8, b.from, d)) {
                try t.expectEqual(want, k);
                try t.expectEqual(y_at.? + 1 + k, i);
                try t.expectEqualStrings("/dev", b.to);
                try t.expectEqual(Bind.Flag.after, b.flag);
                want += 1;
            };
        }
        try t.expectEqual(3, want);

        var out: std.Io.Writer.Allocating = .init(t.allocator);
        defer out.deinit();
        try on.print(&out.writer);
        const text = out.written();
        try t.expect(std.mem.indexOf(u8, text, "gfx:      x11 scale=1 clipboard=host\n") != null);
        try t.expect(std.mem.indexOf(u8, text, "  bind -a '#i' /dev\n  bind -a '#m' /dev\n  bind -a '#b' /dev\n") != null);
        try t.expect(std.mem.indexOf(u8, text, "host clipboard through /dev/snarf") != null);
        try t.expect(std.mem.indexOf(u8, text, "looks like a host dialog") != null);

        const noclip = try compile(arena.allocator(), .{ .root = "/r", .cwd = "/w", .arch = .arm64, .gfx = .{ .backend = "cocoa", .clipboard = false, .scale = 2 } }, .{ .profile = prof }, &msg);
        out.clearRetainingCapacity();
        try noclip.print(&out.writer);
        try t.expect(std.mem.indexOf(u8, out.written(), "gfx:      cocoa scale=2 clipboard=private\n") != null);
        try t.expect(std.mem.indexOf(u8, out.written(), "/dev/snarf") == null);
        try t.expect(std.mem.indexOf(u8, out.written(), "looks like a host dialog") != null);
    }
}
