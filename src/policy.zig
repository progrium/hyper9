//! The sandbox policy (SPEC.md, "Sandbox policy"): profiles and explicit
//! settings, compiled into a Plan that the machine's namespace builder
//! follows and `--print` shows. The Plan's access rules are what devfs
//! checks through `h9_fs_check` (src/kern.zig), and its network patterns
//! are what devip checks through `h9_net_check` and `h9_net_lookup`.
//!
//! All host paths here are absolute and already resolved (symlinks
//! followed); the CLI resolves them before building a Policy.

const std = @import("std");
const aout = @import("abi/plan9/aout.zig");
pub const mount = @import("mount.zig");
const newns = @import("newns.zig");
const web = @import("web.zig").enabled;
const resolver = @import("resolver.zig");

pub const Profile = enum { default, tight };

pub const WriteMode = enum {
    /// Deny all writes.
    none,
    /// Persist writes to the writable paths only.
    scope,
    /// Writable paths are copy-on-write overlays in memory, discarded at
    /// exit (design/epoch-0/ephemeral-writes.md).
    ephemeral,
    /// Like scope, with a copy-on-write overlay over the root: writes to
    /// the root succeed and are discarded at exit (design/epoch-0/overlay.md).
    /// The default.
    overlay,
};

pub const NetMode = enum {
    disable,
    /// Clients work, `announce` is refused (design/epoch-0/net-policy.md).
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
    /// Cap on guest memory in bytes; null means the engine's region size.
    memory: ?u64 = null,
    /// Machine deadline; null means the profile's default.
    timeout_ns: ?u64 = null,
    /// Cap on live processes in the machine; null means unlimited.
    pids: ?u32 = null,
    /// Cap on vCPUs running guest code at once; null means the engine's
    /// limit (64 on HVF) or, on the emulator, unlimited.
    cpus: ?u32 = null,
    /// Whether the cwd is writable; null means the profile's default.
    /// `--sandbox` sets it.
    cwd_writable: ?bool = null,
    /// Expose all of the host filesystem at /mnt/term.
    host_fs: bool = false,
};

/// How a bound tree can be changed: not at all, on the host, in an
/// overlay in memory (`eph`), which never writes the host, or as a 9P
/// root's server decides (`9p`, design/epoch-0/ninep-roots.md), or never, as
/// constant data in the h9 binary (`builtin`, design/epoch-0/builtin-root.md),
/// or as the writable layer over what's beneath it, which is only read
/// (`up`, design/epoch-0/upper-layers.md).
pub const Access = enum { ro, rw, eph, up, @"9p", builtin };

/// The built-in root's device path.
pub const builtin_dev = "#Hroot";

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
    /// `lower` is a contained tree, through `#U!c`
    /// (design/epoch-0/symlinks-in-root.md).
    contained: bool = false,
    /// A mount of the 9P server posted at `from` (`#s/root`), rather than
    /// a bind, with the attach name `spec`.
    mount: bool = false,
    spec: []const u8 = "",
    /// Shown as a comment in the plan when there's no `lower`.
    note: ?[]const u8 = null,
    /// With `console`: bind the console's `cons` file, not its directory.
    cons_file: bool = false,
    /// `bind -r`: a union merged at every depth (design/epoch-0/mounts.md). On
    /// `#Oroot` or `#Olinux`, optionally with a path below, it adds a
    /// member to that stack.
    recursive: bool = false,
    /// `bind -u`: `from` is the writable layer over `to`
    /// (design/epoch-0/upper-layers.md): the stack's up member on `#Oroot` or
    /// `#Olinux`, and anywhere else a union of the two.
    upper: bool = false,
    /// Make `to` as a directory in the root's overlay if it's missing;
    /// without an overlay, a missing `to` fails, or is skipped when
    /// `optional`.
    make: bool = false,
    /// As `make`, for `from`: the root's `/mnt`, which 9front binds over
    /// the kernel's.
    make_from: bool = false,
    /// With `from` `#O`: a fresh instance in memory only (`--tmp`), not an
    /// overlay over `to`.
    empty: bool = false,
    /// With `empty`: the host archive unpacked into it (`--archive`).
    archive: ?[]const u8 = null,
    /// With `mount`: the 9P connection h9 makes, `from` being its URL. A
    /// `to` of `/srv/NAME` posts it there without mounting it.
    url: ?NinePRoot = null,
    /// With `url`: a connection the embedder already holds, as host
    /// descriptors (design/epoch-0/fd-mounts.md): the one read from, and the one
    /// written to if it's another.
    fd: ?std.posix.fd_t = null,
    fd_write: ?std.posix.fd_t = null,
    /// The flag this line came from, for errors (`--dir ./x:/app`).
    what: ?[]const u8 = null,

    pub const Flag = enum { repl, before, after };
};

/// A 9P server as the root (design/epoch-0/ninep-roots.md): the machine
/// connects to it, posts the connection as `#s/root` and mounts that at /.
pub const NinePRoot = struct {
    kind: enum { tcp, unix, ws, port },
    /// The dial string, `tcp!host!port` or `unix!path`, a `ws://` or
    /// `wss://` URL (design/epoch-0/websocket-9p.md), or on the web host
    /// a page's port, `port!NAME` (design/epoch-0/port-streams.md), for the plan
    /// and errors.
    addr: []const u8,
    /// The attach name.
    spec: []const u8 = "",
    /// The attach uname; null means the machine's user.
    user: ?[]const u8 = null,
    /// A WebSocket root's handshake headers, `Name: value`; the plan
    /// shows their names only.
    headers: []const []const u8 = &.{},
    /// Its `ca=` file.
    ca: ?[]const u8 = null,
    /// The proxy it goes through, if any.
    proxy: ?[]const u8 = null,
    /// The credential helper that applies to it, as `PATTERN=COMMAND`
    /// (design/epoch-0/credential-helpers.md); the plan never shows what it
    /// prints.
    cred: ?[]const u8 = null,
    /// Its metadata index (design/epoch-0/mount-index.md), as the plan shows it.
    index: Index = .auto,
    /// `b3=`: the BLAKE3 hash its index must have (design/plan-format.md,
    /// "Pinned roots"); h9 refuses the tree when it has another, or when
    /// there's no index h9 can check.
    b3: ?[32]u8 = null,
    /// An `http://` or `https://` URL, or one without a scheme, as that:
    /// `addr` is its WebSocket form, and when the handshake is answered
    /// with anything but a 101, h9 fetches `http/.fs/index` for a static
    /// tree instead (design/epoch-0/mounts.md, "The probe").
    http: ?[]const u8 = null,

    pub const Index = union(enum) {
        /// The server's `.fs/index`, if it has one.
        auto,
        /// `--index none`.
        none,
        /// `index=`: the file or URL, and for a file its counts.
        given: struct { from: []const u8, entries: ?u32 = null, dirs: ?u32 = null },
    };
};

/// The listeners that serve the namespace over 9P (design/epoch-0/serve.md),
/// as the plan shows them.
pub const Serve = struct {
    pub const Listener = struct {
        /// The address as `--serve` takes it.
        addr: []const u8,
        /// `port`: the ports the page hands the machine to serve, on the
        /// web host (design/epoch-0/port-streams.md).
        kind: enum { unix, tcp, ws, port },
    };
    listeners: []const Listener,
    /// The guest path each connection exports.
    root: []const u8 = "/",
    /// WebSocket listeners require a token.
    token: bool = false,
    /// Origins WebSocket listeners accept.
    origins: []const []const u8 = &.{},
    /// `/net` is exported.
    net: bool = false,
    /// There's no program: the run only serves. The CLI sets it.
    only: bool = false,
};

/// The host-stream device, `#ℏ`, whose tree is the guest's /net/ws.
pub const hstream_dev = "ℏ";

/// The 9P2000.L device, `#ℓ`, whose tree is the guest's /net/dotl
/// (design/epoch-0/dotl.md).
pub const dotl_dev = "ℓ";

/// The index layer's device, `#ι` (design/epoch-0/mount-index.md), which only
/// h9 opens, for the 9P connections it makes.
pub const hidx_dev = "ι";

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
    /// Whether the machine resolves for the guest (design/linux-dns.md):
    /// a name pattern, and a network. Every connect to port 53 then goes
    /// to the machine's resolver, `dns`, which the machine starts with a
    /// run; without one it's refused.
    resolves: bool = false,
    dns: ?*resolver.Resolver = null,
    /// Device letters masked after the namespace is built.
    devmask: []const u8,
    binds: []const Bind,
    rules: []const Rule,
    enforces: CapSet,
    caveats: []const []const u8,
    /// Where the cwd lands in the guest; null without a root or cwd.
    guest_cwd: ?[]const u8,
    /// The machine's window, with --gfx (design/epoch-0/gfx.md).
    gfx: ?Gfx = null,
    /// Whether the root is under a copy-on-write overlay
    /// (design/epoch-0/overlay.md): the bind of `#O` onto `/`. The builder
    /// makes `$home` in it, and the machine reports the guest's changes.
    root_overlay: bool = false,
    /// The host's DNS servers: a connect to port 53 on one is allowed
    /// even when it's link-local, as a cloud VM's resolver is.
    nameservers: []const [16]u8 = &.{},
    /// The `--serve` listeners (design/epoch-0/serve.md), if any.
    serve: ?Serve = null,

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
        if (p.net_allow.len == 0) return !isLinkLocal(addr) or (port == 53 and p.isNameserver(addr));
        const pr = proto orelse return false;
        for (p.net_allow) |pat| if (pat.matchAddr(pr, addr, port)) return true;
        const names = p.names orelse return false;
        return names.allows(p.net_allow, pr, addr, port);
    }

    fn isNameserver(p: *const Plan, addr: *const [16]u8) bool {
        for (p.nameservers) |*ns| if (std.mem.eql(u8, ns, addr)) return true;
        return false;
    }

    /// Whether a UDP connect that `netCheck` refuses is allowed as a
    /// probe (design/linux-dns.md, Updates): one to an address the
    /// resolved-name table recorded for a name a pattern covers, with any
    /// protocol and port. getaddrinfo connects a UDP socket to each
    /// address it got, which sends nothing, to rank them by whether the
    /// host has a route; the conversation it makes may not send.
    pub fn netProbe(p: *const Plan, proto: ?NetProto, addr: *const [16]u8) bool {
        if (p.net == .disable or p.net_allow.len == 0) return false;
        if (proto != .udp) return false;
        const names = p.names orelse return false;
        return names.recorded(p.net_allow, addr);
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

    /// Prints the plan in the format of SPEC.md, "Plan output".
    pub fn print(p: *const Plan, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("profile:  {t}\n", .{p.profile});
        if (p.serve) |sv| if (sv.only) try w.writeAll("program:  none (serve only)\n");
        try w.writeAll("enforces:");
        var it = p.enforces.iterator();
        while (it.next()) |c| try w.print(" {t}", .{c});
        try w.writeAll("\n");
        try w.print("limits:   write={t} net={t}", .{ p.write, p.net });
        if (p.memory) |m| try w.print(" memory={f}", .{fmtSize(m)});
        if (p.timeout_ns) |d| try w.print(" timeout={f}", .{fmtDuration(d)});
        // Serving runs no guest processes, so --pids is the program's
        // alone (design/epoch-0/kernel-serve.md).
        if (p.pids) |n| try w.print(" pids={d}", .{n});
        if (p.cpus) |n| try w.print(" cpus={d}", .{n});
        try w.writeAll("\n");
        try w.writeAll("devmask: ");
        // Device names are runes: #ℏ is three bytes.
        var dv = (std.unicode.Utf8View.init(p.devmask) catch unreachable).iterator();
        while (dv.nextCodepointSlice()) |d| try w.print(" #{s}", .{d});
        try w.writeAll("\n");
        if (p.gfx) |g| if (g.headless) |sz|
            try w.print("gfx:      headless {d}x{d}\n", .{ sz.dx, sz.dy })
        else
            try w.print("gfx:      {s} scale={d} clipboard={s}\n", .{ g.backend, g.scale, if (!g.clipboard) "private" else if (g.isWeb()) "page" else "host" });
        if (p.net_allow.len > 0) {
            try w.writeAll("net-allow:\n");
            for (p.net_allow) |pat| try w.print("  {s}\n", .{pat.text});
        }
        try w.writeAll("namespace:\n");
        for (p.binds) |b| {
            // An embedder's connection has no address to replay
            // (design/epoch-0/fd-mounts.md), so it's a comment, and the rest of
            // the plan still replays.
            if (b.fd != null) {
                try w.print("  # mount: an embedder's connection on {s}\n", .{shownTo(b.to)});
                continue;
            }
            var line: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
            defer line.deinit();
            const lw = &line.writer;
            lw.writeAll(if (b.mount) "  mount" else "  bind") catch return error.WriteFailed;
            if (b.upper) {
                lw.writeAll(" -u") catch return error.WriteFailed;
            } else if (b.recursive or b.flag != .repl or b.create) {
                lw.writeAll(" -") catch return error.WriteFailed;
                if (b.recursive) lw.writeAll("r") catch return error.WriteFailed;
                switch (b.flag) {
                    .repl => {},
                    .before => lw.writeAll("b") catch return error.WriteFailed,
                    .after => lw.writeAll("a") catch return error.WriteFailed,
                }
                if (b.create) lw.writeAll("c") catch return error.WriteFailed;
            }
            // A target in #L is quoted, since newns reads a word starting
            // with # as a comment.
            const q = if (b.to.len > 0 and b.to[0] == '#') "'" else "";
            // A URL's query can hold a token, so it's elided, as in the
            // note.
            const from = if (b.url != null and b.url.?.kind == .ws) if (std.mem.indexOfScalar(u8, b.from, '?')) |i| b.from[0 .. i + 1] else b.from else b.from;
            lw.print(" '{s}{s}{s}{s}' {s}{s}{s}", .{ from, if (from.len < b.from.len) "…" else "", if (b.console) "<id>" else "", if (b.cons_file) "/cons" else "", q, b.to, q }) catch return error.WriteFailed;
            // Always written for a mount, '' when empty, so newns can tell
            // the spec from the access column.
            if (b.mount) lw.print(" '{s}'", .{b.spec}) catch return error.WriteFailed;
            // A 9P mount's settings, as namespace files take them
            // (design/epoch-0/mounts.md, "Namespace files"); a header's value
            // only when it's from a file.
            if (b.url) |r| {
                if (r.user) |u| lw.print(" 'user={s}'", .{u}) catch return error.WriteFailed;
                if (r.ca) |ca| lw.print(" 'ca={s}'", .{ca}) catch return error.WriteFailed;
                for (r.headers) |h| if (h.len > 0 and h[0] == '@') {
                    lw.print(" 'header={s}'", .{h}) catch return error.WriteFailed;
                };
            }
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
        if (p.serve) |sv| {
            try w.writeAll("serve:    # 9P2000 and 9P2000.L, served by the kernel\n");
            for (sv.listeners) |l| {
                var line: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
                defer line.deinit();
                line.writer.print("  {s}", .{l.addr}) catch return error.WriteFailed;
                try w.writeAll(line.written());
                try w.splatByteAll(' ', (40 -| line.written().len) + 1);
                try w.print("kernel{s} -r {s}", .{ if (p.write == .none) " -R" else "", sv.root });
                if (l.kind == .ws) {
                    try w.print("   ({s}origins: ", .{if (sv.token) "token, " else ""});
                    if (sv.origins.len == 0) try w.writeAll("none");
                    for (sv.origins, 0..) |o, i| try w.print("{s}{s}", .{ if (i > 0) " " else "", o });
                    try w.writeAll(")");
                }
                try w.writeAll("\n");
            }
        }
        try writeCaveats(w, p.caveats);
    }
};

/// Writes the plan's caveats, the one place they're written: after the
/// compiled plan in `Plan.print`, and so, as comments, at the end of a
/// plan file's text (`printPlan`).
pub fn writeCaveats(w: *std.Io.Writer, caveats: []const []const u8) std.Io.Writer.Error!void {
    try w.writeAll("caveats:\n");
    for (caveats) |c| try w.print("  - {s}\n", .{c});
}

pub const CompileError = error{ OutOfMemory, Conflict };

/// A 9P root's comment in the plan: the dial string or URL, with a URL's
/// query elided, header names, the proxy and `ca=`, and the user.
/// A bind's target as a mount gives it: `/` and `#L` for the stacks.
fn shownTo(to: []const u8) []const u8 {
    if (std.mem.eql(u8, to, mount.Stack.root.dev())) return "/";
    if (std.mem.eql(u8, to, mount.Stack.linux.dev())) return "#L";
    return to;
}

pub fn rootNoteOf(arena: std.mem.Allocator, r: NinePRoot) error{OutOfMemory}![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    if (r.kind == .ws) {
        if (std.mem.indexOfScalar(u8, r.addr, '?')) |q| {
            w.print("{s}…", .{r.addr[0 .. q + 1]}) catch return error.OutOfMemory;
        } else w.writeAll(r.addr) catch return error.OutOfMemory;
        if (r.http != null) w.writeAll(" or a static tree") catch return error.OutOfMemory;
        if (r.headers.len > 0) {
            w.writeAll("  (") catch return error.OutOfMemory;
            for (r.headers, 0..) |h, i| {
                const colon = std.mem.indexOfScalar(u8, h, ':') orelse h.len;
                w.print("{s}{s}: …", .{ if (i > 0) ", " else "", std.mem.trim(u8, h[0..colon], " \t") }) catch return error.OutOfMemory;
            }
            w.writeAll(")") catch return error.OutOfMemory;
        }
        if (r.proxy) |p| w.print("  via {f}", .{elideUserinfo(p)}) catch return error.OutOfMemory;
        if (r.ca) |ca| w.print("  ca={s}", .{ca}) catch return error.OutOfMemory;
        if (r.cred) |c| w.print("  cred {s}", .{c}) catch return error.OutOfMemory;
    } else w.writeAll(r.addr) catch return error.OutOfMemory;
    if (r.user) |u| w.print(" as {s}", .{u}) catch return error.OutOfMemory;
    (switch (r.index) {
        .auto => w.writeAll("  index=/.fs/index"),
        .none => w.writeAll("  index=none"),
        .given => |g| blk: {
            // A URL's query can hold a token.
            const q = std.mem.indexOfScalar(u8, g.from, '?');
            w.print("  index={s}{s}", .{ if (q) |i| g.from[0 .. i + 1] else g.from, if (q != null) "…" else "" }) catch break :blk error.WriteFailed;
            if (g.entries) |n| w.print(" {d} entries {d} dirs", .{ n, g.dirs orelse 0 }) catch break :blk error.WriteFailed;
        },
    }) catch return error.OutOfMemory;
    if (r.b3) |h| w.print("  pinned b3={x}", .{&h}) catch return error.OutOfMemory;
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

/// A machine's window (design/epoch-0/gfx.md), as the plan shows it.
pub const Gfx = struct {
    /// The GUI backend's name: cocoa, win32, x11, web or headless.
    backend: []const u8,
    /// Whether /dev/snarf is the host clipboard (not `--gfx=noclip`). On
    /// the web host, the page's, as the user pastes into the canvas.
    clipboard: bool = true,
    scale: u8 = 1,
    /// The headless screen's size, for a machine with the headless screen
    /// (design/epoch-0/headless-screen.md) rather than a window.
    headless: ?struct { dx: u16, dy: u16 } = null,

    /// The web host's canvas (design/epoch-0/browser-gfx.md).
    pub fn isWeb(g: Gfx) bool {
        return std.mem.eql(u8, g.backend, "web");
    }
};

pub const Inputs = struct {
    /// The mounts, in the order given (design/epoch-0/mounts.md). `.dir` sources
    /// are absolute host paths with symlinks resolved, and `.archive`
    /// ones host paths h9 reads before the machine starts. Mounts on `/`
    /// stack into the root, and on `#L` into the Linux tree; with none on
    /// `/`, the root stack is empty and the machine has devices only.
    mounts: []const mount.Mount = &.{},
    /// `--bind` lines, run after every mount, in order.
    binds: []const mount.Bind = &.{},
    /// Host directory bound at /mnt/term/cwd.
    cwd: ?[]const u8,
    arch: aout.Arch,
    /// Bind h9's own commands (`#H/bin`) after /bin; false leaves out
    /// the bind and masks `#H` (design/epoch-0/guest-tools.md).
    guest_tools: bool = true,
    /// The host's DNS servers, which port 53 may reach even when they're
    /// link-local (design/epoch-0/linux-net.md).
    nameservers: []const []const u8 = &.{},
    /// A host window: `#i`, `#m` and `#b` on /dev. Without one they're
    /// masked (design/epoch-0/gfx.md).
    gfx: ?Gfx = null,
    /// What the plan says about the built-in root beside its bind.
    builtin_note: ?[]const u8 = null,
    /// `--serve` listeners (design/epoch-0/serve.md).
    serve: ?Serve = null,
};

/// Whether host path `path` is one `--writable` names, and writing is allowed.
fn hostWritable(writable: []const []const u8, path: []const u8, allowed: bool) bool {
    if (!allowed) return false;
    for (writable) |w| if (std.mem.eql(u8, w, path)) return true;
    return false;
}

/// The Linux view's device (design/epoch-0/linux-personality.md, "The Linux
/// view"): `#L`, devlinux, which was `#λ` before design/epoch-0/mounts.md.
pub const linux_view = "#L";

/// Compiles a policy. Allocations go in `arena`. `err_msg` explains a
/// Conflict.
pub fn compile(arena: std.mem.Allocator, in: Inputs, pol: Policy, err_msg: *[]const u8) CompileError!Plan {
    const tight = pol.profile == .tight;
    const write_req = pol.write orelse .overlay;
    const net = pol.net orelse (if (tight) NetMode.disable else .outbound);

    // On the web host the network is WebSockets only (`/net/ws`), which
    // the modes govern as natively.
    const write = write_req;

    // h9 can't make devmnt read-only, so `none` can't be kept for a
    // server it doesn't control.
    for (in.mounts) |m| {
        if (write_req == .none and m.access != null and m.access.? != .ro) {
            err_msg.* = try std.fmt.allocPrint(arena, "--write=none conflicts with {t}: {f}", .{ m.access.?, m });
            return error.Conflict;
        }
        if (write == .none and (m.kind == .url or m.kind == .fd)) {
            const what = if (std.mem.eql(u8, m.dst, "/")) "root" else "mount";
            err_msg.* = try std.fmt.allocPrint(arena, "--write=none can't be enforced on a {s} {s}", .{ if (isWs(m.src)) "WebSocket" else "9P", what });
            return error.Conflict;
        }
        if (m.contained and m.kind != .dir) {
            err_msg.* = "contained needs a host directory";
            return error.Conflict;
        }
        // design/epoch-0/fd-mounts.md: the descriptors are an .fd mount's, and it
        // needs the one it reads.
        // The messages are constant: Machine.init frees the arena on
        // a conflict.
        if (m.kind == .fd and m.fd == null) {
            err_msg.* = "fd: an .fd mount needs one";
            return error.Conflict;
        }
        if (m.kind != .fd and (m.fd != null or m.fd_write != null)) {
            err_msg.* = if (m.fd_write != null) "fd_write: only an .fd mount takes it" else "fd: only an .fd mount takes it";
            return error.Conflict;
        }
        // A layer writes the host, which ephemeral never does.
        if (write_req == .ephemeral and m.access == .up) {
            err_msg.* = try std.fmt.allocPrint(arena, "--write=ephemeral conflicts with up: {f}", .{m});
            return error.Conflict;
        }
    }
    // A stack takes one layer (design/epoch-0/upper-layers.md).
    for ([_]mount.Stack{ .root, .linux }) |st| {
        var ups: usize = 0;
        for (in.mounts) |m| if (m.stack()) |ms| if (ms[0] == st and m.access == .up) {
            ups += 1;
        };
        if (ups > 1) {
            err_msg.* = try std.fmt.allocPrint(arena, "{s} has more than one up member", .{if (st == .root) "/" else "#L"});
            return error.Conflict;
        }
    }
    if (write_req == .none and pol.writable.len > 0) {
        err_msg.* = "--write=none conflicts with --writable";
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

    // The stacks (design/epoch-0/mounts.md, "Stacks"): a member marked rw takes
    // creates and writes, and the stack then has no overlay. Otherwise
    // the stack is under one with --write=overlay or ephemeral.
    var stack_rw = [2]bool{ false, false };
    var stack_n = [2]usize{ 0, 0 };
    for (in.mounts) |m| if (m.stack()) |st| {
        stack_n[@intFromEnum(st[0])] += 1;
        if ((m.access == .rw or m.access == .up) and can_write and !eph) stack_rw[@intFromEnum(st[0])] = true;
        // A 9P server decides what's writable under --write=scope, as
        // before (design/epoch-0/ninep-roots.md).
        if ((m.kind == .url or m.kind == .fd) and write == .scope and m.access != .ro) stack_rw[@intFromEnum(st[0])] = true;
    };
    // `--writable` on a stack's host directory makes it write the host,
    // as `--writable "$H9ROOT"` did before.
    for (in.mounts) |m| if (m.stack()) |st| if (m.kind == .dir and hostWritable(pol.writable, m.src, can_write and !eph)) {
        stack_rw[@intFromEnum(st[0])] = true;
    };
    const overlay_mode = write == .overlay or eph;
    // With nothing on `/`, the root is an empty tree in memory, so the
    // namespace's mount points, such as /mnt/term, can still be made.
    const root_overlay = (overlay_mode and !stack_rw[0]) or stack_n[0] == 0;
    const linux_overlay = overlay_mode and !stack_rw[1];
    const has_linux = stack_n[1] > 0;

    // `/` on 9front's pattern (design/epoch-0/mounts.md, "Building /"): the
    // kernel's `#/` first, so its names never reach the root tree, and
    // the root stack after it and at /root.
    try binds.append(arena, .{ .from = "#/", .to = "/", .note = "the kernel's names: bin dev env fd net proc root srv" });
    for ([_]mount.Stack{ .root, .linux }) |st| {
        const overlaid = if (st == .root) root_overlay else linux_overlay;
        var first = true;
        for (in.mounts) |m| {
            const ms = m.stack() orelse continue;
            if (ms[0] != st) continue;
            const to = if (ms[1].len == 0) st.dev() else try std.fmt.allocPrint(arena, "{s}/{s}", .{ st.dev(), ms[1] });
            const flag: Bind.Flag = if (m.order) |o| (if (o == .before) .before else .after) else if (first) .repl else .before;
            first = false;
            try binds.append(arena, try memberBind(arena, in, pol, m, to, flag, true, st == .linux, overlaid, can_write and !eph, &rules));
        }
        if (st == .root and stack_n[0] == 0) {
            try binds.append(arena, .{ .from = "#O", .to = st.dev(), .recursive = true, .create = true, .access = .eph, .empty = true, .note = "nothing on /: an empty tree in memory" });
        }
        if (st == .linux and !has_linux) continue;
        if (overlaid and stack_n[@intFromEnum(st)] > 0) try binds.append(arena, .{ .from = "#O", .to = st.dev(), .create = true, .access = .eph });
        if (st == .root) {
            try binds.append(arena, .{ .from = st.dev(), .to = "/", .flag = .after, .create = root_overlay or stack_rw[0] });
            try binds.append(arena, .{ .from = st.dev(), .to = "/root", .note = "$rootdir: the root stack without the namespace's binds" });
            // The kernel's `#/` has a `mnt`, so the root's comes before
            // it, as 9front's /lib/namespace binds $rootdir/mnt.
            try binds.append(arena, .{ .from = "/root/mnt", .to = "/mnt", .create = true, .optional = true, .make_from = true });
        }
    }
    const has_root = true;

    try binds.append(arena, .{ .from = "#c", .to = "/dev", .optional = true });
    try binds.append(arena, .{ .from = "#y", .to = "/dev", .flag = .before, .console = true });
    // The window's devices (design/epoch-0/gfx.md), after the console so
    // /dev/cons stays the terminal.
    if (in.gfx != null) for ([_][]const u8{ "#i", "#m", "#b" }) |d| {
        try binds.append(arena, .{ .from = d, .to = "/dev", .flag = .after });
    };
    try binds.append(arena, .{ .from = "#e", .to = "/env", .create = true, .optional = true });
    try binds.append(arena, .{ .from = "#d", .to = "/fd", .optional = true });
    try binds.append(arena, .{ .from = "#p", .to = "/proc", .optional = true });
    // The machine's own service registry (design/epoch-0/devsrv.md): it shows
    // nothing outside the machine, so it's in both profiles.
    try binds.append(arena, .{ .from = "#s", .to = "/srv", .create = true, .optional = true });
    if (net != .disable and web) {
        // No sockets on the web host: WebSockets are its whole network.
        try binds.append(arena, .{ .from = "#" ++ hstream_dev, .to = "/net", .optional = true, .note = "WebSockets, under --net" });
    } else if (net != .disable) {
        try binds.append(arena, .{ .from = "#I", .to = "/net", .optional = true });
        try binds.append(arena, .{ .from = "#" ++ hstream_dev, .to = "/net", .flag = .after, .optional = true, .note = "WebSockets, under --net" });
    }
    // 9P2000.L mounts (design/epoch-0/dotl.md) reach nothing by themselves:
    // a conversation translates a connection the guest already has.
    try binds.append(arena, .{ .from = "#" ++ dotl_dev, .to = "/net", .flag = .after, .optional = true, .note = "9P2000.L mounts" });
    if (has_root) {
        try binds.append(arena, .{ .from = try std.fmt.allocPrint(arena, "/{s}/bin", .{in.arch.name()}), .to = "/bin", .optional = true });
        try binds.append(arena, .{ .from = "/rc/bin", .to = "/bin", .flag = .after, .optional = true });
        // h9's own commands (design/epoch-0/guest-tools.md), after the root's
        // so a root command of the same name wins.
        if (in.guest_tools) try binds.append(arena, .{ .from = "#H/bin", .to = "/bin", .flag = .after, .optional = true, .note = "h9's commands" });
        // h9's bind(1), with -r for unions (design/epoch-0/mounts.md), before the
        // root's.
        if (in.guest_tools) try binds.append(arena, .{ .from = "#H/over", .to = "/bin", .flag = .before, .optional = true, .note = "h9's bind, with -r" });
    }

    // A private /tmp in memory, over the root's own /tmp, in both
    // profiles; made in the root's overlay if the root has none.
    // --write=none leaves the root's read-only /tmp.
    if (write != .none) try binds.append(arena, .{ .from = "#O", .to = "/tmp", .create = true, .access = .eph, .optional = true, .make = true });

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
        try binds.append(arena, .{ .from = "#U/", .to = "/mnt/term", .flag = .after, .access = if (pol.host_fs) .ro else null, .make = true });
    }

    var guest_cwd: ?[]const u8 = null;
    if (in.cwd) |cwd| {
        try rules.append(arena, .{ .path = cwd, .kind = acc.rule(cwd_rw) });
        if (has_root) {
            var b = try acc.bind(arena, cwd, "/mnt/term/cwd", cwd_rw);
            b.fallback = "/mnt/term";
            b.make = true;
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

    // Mounts on any other destination take Plan 9's rules: the mount
    // replaces what's there, b and a make a one-level union with it, and
    // r a union merged at every depth. A missing destination is made in
    // the root's overlay.
    for (in.mounts) |m| {
        if (m.stack() != null) continue;
        const flag: Bind.Flag = if (m.order) |o| (if (o == .before) .before else .after) else .repl;
        var b = try memberBind(arena, in, pol, m, m.dst, flag, false, false, false, can_write and !eph, &rules);
        b.recursive = m.recursive and !b.upper;
        b.make = m.srvName() == null;
        b.what = try std.fmt.allocPrint(arena, "{f}", .{m});
        try binds.append(arena, b);
    }

    // The Linux view (design/epoch-0/linux-personality.md): the Linux stack
    // after devlinux's own directories, and the shared trees on its mount
    // points, only with a Linux tree: without one, a Linux binary from a
    // host path sees devlinux's own tree.
    const lv = linux_view;
    if (has_linux) {
        try binds.append(arena, .{ .from = mount.Stack.linux.dev(), .to = lv, .flag = .after, .create = linux_overlay or stack_rw[1] });
        try binds.append(arena, .{ .from = "/", .to = lv ++ "/9", .note = "the 9front root" });
        if (write != .none) try binds.append(arena, .{ .from = "/tmp", .to = lv ++ "/tmp", .create = true, .optional = true });
        try binds.append(arena, .{ .from = "/mnt/term", .to = lv ++ "/mnt/term", .optional = true });
        try binds.append(arena, .{ .from = "#d", .to = lv ++ "/dev/fd", .optional = true });
        // Pseudoterminals (design/epoch-0/linux-pty.md): /dev/pts is #τ, and
        // /dev/ptmx its clone file.
        try binds.append(arena, .{ .from = "#τ", .to = lv ++ "/dev/pts", .optional = true });
        try binds.append(arena, .{ .from = "#τ/ptmx", .to = lv ++ "/dev/ptmx", .optional = true });
        // /dev/shm is a tmpfs on Linux: an empty writable tree of its
        // own, kept in memory, for shm_open and for scripts that keep
        // secrets off the disk (passage, pass).
        if (write != .none) try binds.append(arena, .{ .from = "#O", .to = lv ++ "/dev/shm", .create = true, .access = .eph, .optional = true });
        for ([_][]const u8{ "stdin", "stdout", "stderr" }, 0..) |name, fd| {
            try binds.append(arena, .{ .from = try std.fmt.allocPrint(arena, "#d/{d}", .{fd}), .to = try std.fmt.allocPrint(arena, lv ++ "/dev/{s}", .{name}), .optional = true });
        }
        for ([_][]const u8{ "tty", "console" }) |name| {
            try binds.append(arena, .{ .from = "#y", .to = try std.fmt.allocPrint(arena, lv ++ "/dev/{s}", .{name}), .console = true, .optional = true, .cons_file = true });
        }
    }

    // --bind runs after every mount, in the order given, and before --ns.
    for (in.binds) |b| try binds.append(arena, .{
        .from = b.src,
        .to = b.dst,
        .flag = if (b.order) |o| (if (o == .before) .before else .after) else .repl,
        .create = b.create,
        .recursive = b.recursive,
        .what = try std.fmt.allocPrint(arena, "--bind {s}:{s}", .{ b.src, b.dst }),
    });

    var devmask: std.ArrayList(u8) = .empty;
    // #C (host commands) isn't built while design/host-cmd.md rethinks
    // it, and stays masked.
    try devmask.append(arena, 'C');
    if (net == .disable or web) try devmask.append(arena, 'I');
    if (net == .disable) try devmask.appendSlice(arena, hstream_dev);
    if (!in.guest_tools) try devmask.append(arena, 'H');
    if (!pol.host_fs) try devmask.append(arena, 'U');
    // h9's own mounts are through #ι by now, and a guest conversation
    // could read the host's index cache.
    try devmask.appendSlice(arena, hidx_dev);
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
        .allow_eph => if (!(root_overlay and isStackDir(in, r.path))) {
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
    // Layers (design/epoch-0/upper-layers.md).
    for (binds.items) |b| if (b.upper) {
        const onto = if (std.mem.eql(u8, b.to, mount.Stack.root.dev())) "/" else if (std.mem.eql(u8, b.to, mount.Stack.linux.dev())) "#L" else b.to;
        try caveats.append(arena, try std.fmt.allocPrint(arena, "changes to {s} are written to its layer as they're made, so a run that fails leaves a partial one", .{onto}));
    };
    for (binds.items) |b| if (b.url) |r| {
        const is_root = std.mem.eql(u8, b.to, mount.Stack.root.dev());
        const what = if (is_root) "the 9P root" else try std.fmt.allocPrint(arena, "the 9P mount on {s}", .{b.to});
        // Under the root's overlay nothing reaches the server.
        if (!(is_root and root_overlay)) try caveats.append(arena, try std.fmt.allocPrint(arena, "writes to {s} go to its server, which decides what can be written", .{what}));
        const plain = switch (r.kind) {
            .tcp => true,
            // A port never leaves the page (design/epoch-0/port-streams.md).
            .unix, .port => false,
            .ws => !std.mem.startsWith(u8, r.addr, "wss://"),
        };
        if (plain) try caveats.append(arena, try std.fmt.allocPrint(arena, "{s}'s connection isn't encrypted", .{what}));
    };
    try caveats.append(arena, "paths are checked after resolving symlinks, so a host process renaming paths concurrently can race the check");
    // A Linux program resolves names itself, through the host's DNS
    // servers (design/epoch-0/linux-net.md).
    var nameservers: std.ArrayList([16]u8) = .empty;
    if (has_linux and net != .disable) for (in.nameservers) |ns| {
        if (resolver.parseServer(ns)) |s| try nameservers.append(arena, s.addr);
    };
    var ll_dns = false;
    for (nameservers.items) |*a| ll_dns = ll_dns or isLinkLocal(a);
    if (net != .disable and web) {
        try caveats.append(arena, "the web host's network is WebSockets only, at /net/ws, to anywhere the browser's own rules allow");
        if (net_allow.len > 0) try caveats.append(arena, "the browser resolves names itself, so --net-allow checks a name, not the addresses it resolves to, and link-local names aren't refused");
    } else if (net != .disable) {
        if (net_allow.len == 0) {
            try caveats.append(arena, "outbound connections can reach any address the host can except link-local, including its loopback and local network");
            if (ll_dns) try caveats.append(arena, "a Linux program can reach the host's link-local DNS server on port 53");
            try caveats.append(arena, "refusing link-local doesn't cover every cloud metadata endpoint: some, such as fd00:ec2::254 and 100.100.100.200, use other ranges");
            try caveats.append(arena, "the guest can make the host resolve any name");
        }
        if (name_patterns) try caveats.append(arena, "name patterns trust the host's resolver: a name is allowed to reach whatever address it resolves to");
        // The machine resolves for the guest (design/linux-dns.md).
        if (name_patterns) try caveats.append(arena, "DNS queries to port 53 go to h9's resolver, which forwards names the allowlist covers to the host's DNS servers");
        if (net == .enable) try caveats.append(arena, "servers in the guest are reachable by anything that can reach the host's ports");
    }
    if (in.gfx) |g| {
        // The headless screen reaches nothing on the host: no window, and
        // its clipboard is a buffer in h9 (design/epoch-0/headless-screen.md).
        if (g.headless != null) {} else if (g.isWeb()) {
            if (g.clipboard) try caveats.append(arena, "the guest can write the page's clipboard, and read what the user pastes into its canvas");
            try caveats.append(arena, "the guest can draw anything in its canvas, including what looks like the page's own UI or a browser dialog");
        } else {
            if (g.clipboard) try caveats.append(arena, "the guest can read and write the host clipboard through /dev/snarf");
            try caveats.append(arena, "the guest can draw anything in its window, including what looks like a host dialog");
        }
    }
    if (pol.host_fs) try caveats.append(arena, "--host-fs exposes the whole host filesystem");
    var serve_plan = in.serve;
    if (serve_plan) |*sv| {
        // Unix sockets rely on file permissions, and TCP has nothing, so
        // both are listed, as is a WebSocket listener without a token.
        // A port is the page's, which made it and decided who's on the
        // other end (design/epoch-0/port-streams.md).
        for (sv.listeners) |l| if (l.kind != .port and (l.kind != .ws or !sv.token)) {
            try caveats.append(arena, try std.fmt.allocPrint(arena, "served without authentication on {s}", .{l.addr}));
        };
        if (sv.net) for (sv.listeners) |l| {
            try caveats.append(arena, try std.fmt.allocPrint(arena, "/net served on {s}: clients can dial out from the host's address, under --net={t}", .{ l.addr, net }));
        };
    }
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
        .resolves = name_patterns and net != .disable and !web,
        .devmask = devmask.items,
        .binds = binds.items,
        .rules = rules.items,
        .enforces = enforces,
        .caveats = caveats.items,
        .guest_cwd = guest_cwd,
        .root_overlay = root_overlay,
        .nameservers = nameservers.items,
        .gfx = in.gfx,
        .serve = serve_plan,
    };
}


/// Whether a URL is a WebSocket's, or will probe for one.
fn isWs(url: []const u8) bool {
    const s = mount.scheme(url) orelse return true;
    return !std.mem.eql(u8, s, "tcp") and !std.mem.eql(u8, s, "unix") and !std.mem.eql(u8, s, "port");
}

/// The 9P connection a `--url` mount makes (design/epoch-0/mounts.md, "URLs"):
/// `tcp://HOST:PORT[/SPEC]` dials `tcp!HOST!PORT`, `unix:///PATH` the
/// socket at PATH, and `ws://` and `wss://` as they are. `http://` and
/// `https://` probe for a WebSocket, and fall back to a static dotfs
/// tree; a URL without a scheme is `http://` for a loopback host and
/// `https://` for any other. `port://NAME[/SPEC]` is the page's port
/// NAME (design/epoch-0/port-streams.md), `port!NAME`.
pub fn ninePConn(arena: std.mem.Allocator, m: mount.Mount) error{OutOfMemory}!NinePRoot {
    var r: NinePRoot = .{ .kind = .ws, .addr = m.src, .user = m.user, .headers = m.headers, .ca = m.ca };
    const s = mount.scheme(m.src);
    if (s) |sc| {
        const rest = m.src[sc.len + 3 ..];
        if (std.mem.eql(u8, sc, "tcp")) {
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
            const hostport = rest[0..slash];
            const colon = std.mem.lastIndexOfScalar(u8, hostport, ':') orelse hostport.len;
            var host = hostport[0..colon];
            if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host = host[1 .. host.len - 1];
            const port = if (colon < hostport.len) hostport[colon + 1 ..] else "564";
            r.kind = .tcp;
            r.addr = try std.fmt.allocPrint(arena, "tcp!{s}!{s}", .{ host, port });
            if (slash < rest.len) r.spec = rest[slash + 1 ..];
        } else if (std.mem.eql(u8, sc, "unix")) {
            r.kind = .unix;
            r.addr = try std.fmt.allocPrint(arena, "unix!{s}", .{rest});
        } else if (std.mem.eql(u8, sc, "port")) {
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
            r.kind = .port;
            r.addr = try std.fmt.allocPrint(arena, "port!{s}", .{rest[0..slash]});
            if (slash < rest.len) r.spec = rest[slash + 1 ..];
        } else if (std.mem.eql(u8, sc, "http")) {
            r.addr = try std.fmt.allocPrint(arena, "ws://{s}", .{rest});
            r.http = m.src;
        } else if (std.mem.eql(u8, sc, "https")) {
            r.addr = try std.fmt.allocPrint(arena, "wss://{s}", .{rest});
            r.http = m.src;
        }
    } else {
        const host_end = std.mem.indexOfAny(u8, m.src, "/:") orelse m.src.len;
        const host = m.src[0..host_end];
        const loop = std.mem.eql(u8, host, "localhost") or std.mem.startsWith(u8, host, "127.") or std.mem.eql(u8, host, "[::1]");
        // A bare host is the server's top, `/`.
        const slash = if (std.mem.indexOfAny(u8, m.src, "/?#") == null) "/" else "";
        r.addr = try std.fmt.allocPrint(arena, "{s}://{s}{s}", .{ if (loop) "ws" else "wss", m.src, slash });
        r.http = try std.fmt.allocPrint(arena, "{s}://{s}{s}", .{ if (loop) "http" else "https", m.src, slash });
    }
    if (m.spec) |sp| r.spec = sp;
    return r;
}

/// A mount's line of the plan. `on_stack` makes it a member of the stack
/// `to` names (`#Oroot`, `#Olinux/etc`); `overlaid` says that stack is
/// under an overlay; `host_rw_ok` that a host path may be written.
fn memberBind(arena: std.mem.Allocator, in: Inputs, pol: Policy, m: mount.Mount, to: []const u8, flag: Bind.Flag, on_stack: bool, linux: bool, overlaid: bool, host_rw_ok: bool, rules: *std.ArrayList(Rule)) CompileError!Bind {
    if (m.access == .up) return upperBind(arena, m, to, linux, rules);
    switch (m.kind) {
        .dir => {
            const want_rw = m.access == .rw or hostWritable(pol.writable, m.src, true);
            const rw = want_rw and host_rw_ok;
            // Under --write=ephemeral, rw is eph: nothing writes the host.
            const e = !on_stack and (m.access == .eph or (want_rw and !host_rw_ok and pol.write == .ephemeral));
            const contained = m.contained or linux;
            try rules.append(arena, .{ .path = m.src, .kind = if (rw) .allow_rw else if (e or (on_stack and overlaid)) .allow_eph else .allow_ro });
            if (e) return .{ .from = "#O", .to = to, .flag = flag, .create = true, .access = .eph, .lower = m.src, .contained = contained };
            return .{
                .from = try std.fmt.allocPrint(arena, "#U{s}{s}", .{ if (contained) "!c" else "", m.src }),
                .to = to,
                .flag = flag,
                .recursive = on_stack,
                .create = rw or (m.create and !on_stack),
                .access = if (rw) .rw else .ro,
            };
        },
        .url, .fd => {
            var r = if (m.kind == .url) try ninePConn(arena, m) else NinePRoot{ .kind = .unix, .addr = "fd", .spec = m.spec orelse "", .user = m.user };
            // The root's is set with the machine's options.
            if (m.index) |ix| r.index = .{ .given = .{ .from = ix } };
            r.b3 = if (m.b3) |h| mount.pinHash(h) else null;
            return .{
                // The URL h9 connects to, so a replay needs no scheme
                // rule: an `http` one probes again.
                // A port by its dial string, which a replay mounts.
                .from = if (r.kind == .ws) r.http orelse r.addr else if (r.kind == .port) r.addr else m.src,
                .to = to,
                .flag = flag,
                .mount = true,
                .recursive = on_stack,
                .create = m.create or (on_stack and !overlaid and host_rw_ok and m.access != .ro),
                .spec = r.spec,
                .access = .@"9p",
                .url = r,
                .fd = m.fd,
                .fd_write = m.fd_write,
                .note = try rootNoteOf(arena, r),
            };
        },
        .builtin => return .{ .from = builtin_dev, .to = to, .flag = flag, .recursive = on_stack, .access = .builtin, .note = in.builtin_note },
        .tmp => return .{ .from = "#O", .to = to, .flag = flag, .recursive = on_stack, .create = true, .access = .eph, .empty = true, .note = "an empty tree in memory" },
        .archive => return .{ .from = "#O", .to = to, .flag = flag, .recursive = on_stack, .create = !on_stack, .access = .eph, .empty = true, .archive = m.src, .note = try std.fmt.allocPrint(arena, "the archive {s}", .{m.src}) },
    }
}

/// An `up` mount's line (design/epoch-0/upper-layers.md): `bind -u` of the
/// layer onto `to`, which a host directory writes as `rw` does; what's
/// beneath it is only read.
fn upperBind(arena: std.mem.Allocator, m: mount.Mount, to: []const u8, linux: bool, rules: *std.ArrayList(Rule)) CompileError!Bind {
    switch (m.kind) {
        .dir => {
            const contained = m.contained or linux;
            try rules.append(arena, .{ .path = m.src, .kind = .allow_rw });
            return .{ .from = try std.fmt.allocPrint(arena, "#U{s}{s}", .{ if (contained) "!c" else "", m.src }), .to = to, .upper = true, .create = true, .access = .up };
        },
        .url, .fd => {
            var r = if (m.kind == .url) try ninePConn(arena, m) else NinePRoot{ .kind = .unix, .addr = "fd", .spec = m.spec orelse "", .user = m.user };
            if (m.index) |ix| r.index = .{ .given = .{ .from = ix } };
            r.b3 = if (m.b3) |h| mount.pinHash(h) else null;
            return .{
                .from = if (r.kind == .ws) r.http orelse r.addr else if (r.kind == .port) r.addr else m.src,
                .to = to,
                .mount = true,
                .upper = true,
                .create = true,
                .spec = r.spec,
                .access = .up,
                .url = r,
                .fd = m.fd,
                .fd_write = m.fd_write,
                .note = try rootNoteOf(arena, r),
            };
        },
        .tmp => return .{ .from = "#O", .to = to, .upper = true, .create = true, .access = .up, .empty = true, .note = "a layer in memory" },
        // mount.zig refuses up on these.
        .builtin, .archive => unreachable,
    }
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
    // The deepest host directory on the root stack's top that holds p.
    var root: ?[]const u8 = null;
    var in_root: ?[]const u8 = null;
    for (in.mounts) |m| {
        if (m.kind != .dir or !std.mem.eql(u8, m.dst, "/")) continue;
        const rel = relUnder(m.src, p) orelse continue;
        if (root == null or m.src.len > root.?.len) {
            root = m.src;
            in_root = rel;
        }
    }
    const in_cwd = if (in.cwd) |c| relUnder(c, p) else null;
    if (in_cwd != null and (in_root == null or in.cwd.?.len >= root.?.len)) {
        return if (in_cwd.?.len == 0) .cwd_top else .{ .cwd = in_cwd.? };
    }
    if (in_root) |rel| return if (rel.len == 0) .root_top else .{ .root = rel };
    return .mnt_term;
}

/// The guest path of the resolved host file `host` under a compiled
/// plan, or null if the guest can't read it: it's outside the root, the
/// cwd, every readable path, and every `--dir` mount, or a deny rule
/// hides it. `mounts`, `cwd`, and `pol` are the plan's inputs. The CLI
/// runs a host `#!` script by this path, so that its interpreter, a
/// guest program, can open it (design/epoch-0/host-scripts.md).
pub fn guestPath(arena: std.mem.Allocator, plan: *const Plan, mounts: []const mount.Mount, cwd: ?[]const u8, pol: Policy, host: []const u8) error{OutOfMemory}!?[]const u8 {
    // Without a root nothing is bound; with one, the cwd always is.
    if (plan.guest_cwd == null) return null;
    if (plan.check(host, .read) != .allow) return null;
    const in: Inputs = .{ .mounts = mounts, .cwd = cwd, .arch = .arm64 };
    switch (guestPlace(in, host)) {
        .root_top, .cwd_top => return null,
        .root => |rel| return try std.fmt.allocPrint(arena, "/{s}", .{rel}),
        .cwd => |rel| return try std.fmt.allocPrint(arena, "/mnt/term/cwd/{s}", .{rel}),
        .mnt_term => {},
    }
    // Readable and writable paths, and --host-fs, appear at their host
    // path under /mnt/term.
    var shared = pol.host_fs;
    for ([_][]const []const u8{ pol.readable, pol.writable }) |list| for (list) |p| {
        if (relUnder(p, host) != null) shared = true;
    };
    if (shared) return try std.fmt.allocPrint(arena, "/mnt/term{s}", .{host});
    // A host directory mounted elsewhere: the deepest that holds it.
    var best: ?mount.Mount = null;
    var best_rel: []const u8 = "";
    for (mounts) |m| {
        if (m.kind != .dir or m.stack() != null or m.dst.len == 0 or m.dst[0] != '/') continue;
        const rel = relUnder(m.src, host) orelse continue;
        if (best == null or m.src.len > best.?.src.len) {
            best = m;
            best_rel = rel;
        }
    }
    const m = best orelse return null;
    if (best_rel.len == 0) return null;
    const dst = std.mem.trimEnd(u8, m.dst, "/");
    return try std.fmt.allocPrint(arena, "{s}/{s}", .{ dst, best_rel });
}

/// Whether host path `p` is a directory on one of the stacks.
fn isStackDir(in: Inputs, p: []const u8) bool {
    for (in.mounts) |m| if (m.kind == .dir and m.stack() != null and std.mem.eql(u8, m.src, p)) return true;
    return false;
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

// The network policy (design/epoch-0/net-policy.md).

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
        return pat.matchHostName(name);
    }

    /// Whether the pattern's host covers `name`, for any protocol and port.
    pub fn matchHostName(pat: NetPattern, name: []const u8) bool {
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
        /// Null in an entry the machine's resolver recorded from a DNS
        /// answer, which has neither (design/linux-dns.md): it matches
        /// any connect's, which the patterns then decide.
        proto: ?NetProto,
        port: ?u16,
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

    pub fn record(nt: *NameTable, proto: ?NetProto, addr: *const [16]u8, port: ?u16, name: []const u8) void {
        if (name.len > max_name) return;
        nt.acquire();
        defer nt.lock.unlock();
        const e = &nt.entries[nt.count % capacity];
        e.* = .{ .proto = proto, .port = port, .addr = addr.*, .name_len = @intCast(name.len), .name_buf = undefined };
        @memcpy(e.name_buf[0..name.len], name);
        nt.count += 1;
    }

    /// Whether a name that resolved to addr for proto and port matches a
    /// name pattern. An entry without a protocol or port takes the
    /// connect's.
    pub fn allows(nt: *NameTable, pats: []const NetPattern, proto: NetProto, addr: *const [16]u8, port: u16) bool {
        nt.acquire();
        defer nt.lock.unlock();
        const n = @min(nt.count, capacity);
        for (nt.entries[0..n]) |*e| {
            if (e.proto) |ep| if (ep != proto) continue;
            if (e.port) |ept| if (ept != port) continue;
            if (!std.mem.eql(u8, &e.addr, addr)) continue;
            for (pats) |pat| switch (pat.host) {
                .name, .suffix => if (pat.matchName(proto, e.name(), port)) return true,
                else => {},
            };
        }
        return false;
    }

    /// Whether addr is recorded for a name a name pattern covers, with
    /// any protocol and port: what `Plan.netProbe` allows a UDP probe to.
    pub fn recorded(nt: *NameTable, pats: []const NetPattern, addr: *const [16]u8) bool {
        nt.acquire();
        defer nt.lock.unlock();
        const n = @min(nt.count, capacity);
        for (nt.entries[0..n]) |*e| {
            if (!std.mem.eql(u8, &e.addr, addr)) continue;
            for (pats) |pat| switch (pat.host) {
                .name, .suffix => if (pat.matchHostName(e.name())) return true,
                else => {},
            };
        }
        return false;
    }
};

// The plan as text (design/plan-format.md): the lines a plan file takes,
// their parser and printer, and the narrowing rule.

/// An `engine` line's names: engine.Choice's (machine.zig checks they
/// match), kept here so the policy needs no engine.
pub const EngineChoice = enum { auto, hvf, kvm, whp, hcpu, sud };

/// A `gfx` line: a window (`--gfx`, `--gfx=noclip`, and `--gfx-scale`),
/// or the headless screen (`--gfx=headless` and `--gfx-size`).
pub const GfxSpec = struct {
    headless: bool = false,
    /// /dev/snarf is the host's clipboard; false is `noclip`.
    clipboard: bool = true,
    scale: ?u8 = null,
    size: ?[2]u16 = null,
};

/// Where each of a plan's settings came from: a line number, from 1, or
/// 0 for none (a default, or a Spec made from flags or `Machine.Options`).
/// Narrowing's errors name these lines.
pub const Lines = struct {
    profile: u32 = 0,
    write: u32 = 0,
    net: u32 = 0,
    devices: u32 = 0,
    memory: u32 = 0,
    pids: u32 = 0,
    cpus: u32 = 0,
    timeout: u32 = 0,
    engine: u32 = 0,
    arch: u32 = 0,
    cwd: u32 = 0,
    gfx: u32 = 0,
    serve_root: u32 = 0,
    serve_net: u32 = 0,
    /// One per item of the list of the same name.
    mounts: []const u32 = &.{},
    net_allow: []const u32 = &.{},
    readable: []const u32 = &.{},
    writable: []const u32 = &.{},
    serve: []const u32 = &.{},
    serve_origins: []const u32 = &.{},
};

/// A plan's contents (design/plan-format.md): what decides what a machine
/// is, and nothing about the host that runs it (its stdio, caches,
/// credential helpers, and proxies). Every way of starting a machine
/// takes one: `h9 --plan`, the flags (which compile to one),
/// `Machine.Options.plan`, and the page's `createMachine({ plan })`.
/// Host paths are as written: the CLI resolves relative ones from its
/// working directory, as it does a flag's.
pub const Spec = struct {
    /// `dir`, `url`, `archive`, `builtin`, and `tmp` lines: the mount
    /// flags, each taking its flag's value.
    mounts: []const mount.Mount = &.{},
    /// `bind SRC:DST[:OPTS]` lines, with one value: `--bind`.
    binds: []const mount.Bind = &.{},
    /// Namespace lines (`bind` and `mount` with two values or more,
    /// `unmount`, `cd`, and `clear`), as `--ns` text, replayed in order
    /// after the binds.
    ns: []const []const u8 = &.{},
    /// `profile`, `write`, `net`, `netallow`, `allow read`, `allow write`,
    /// `deny read`, and `devices host-fs`, and the limits.
    policy: Policy = .{},
    /// `devices guest-tools`: `#H/bin`, h9's own commands.
    guest_tools: bool = true,
    engine: ?EngineChoice = null,
    arch: ?aout.Arch = null,
    /// `env NAME=VALUE` lines.
    env: []const []const u8 = &.{},
    /// `cwd PATH [rw|ro]`: the host directory at /mnt/term/cwd; its mode
    /// is `policy.cwd_writable`.
    cwd: ?[]const u8 = null,
    gfx: ?GfxSpec = null,
    /// `serve ADDR` lines, as `--serve` takes them.
    serve: []const []const u8 = &.{},
    serve_root: ?[]const u8 = null,
    /// `servetoken @FILE`: the host file holding the token, never the
    /// token.
    serve_token: ?[]const u8 = null,
    serve_origins: []const []const u8 = &.{},
    serve_net: bool = false,
    /// `run PROG ARGS...`: optional, and a program on the command line
    /// replaces it.
    run: ?[]const []const u8 = null,
    /// Comments the printer writes in the plan's namespace section, for
    /// what a plan can't hold as text, such as an embedder's connection.
    notes: []const []const u8 = &.{},
    lines: Lines = .{},

    /// The network mode the plan gets: its `net` line's, or its profile's.
    pub fn netMode(s: Spec) NetMode {
        return s.policy.net orelse if (s.policy.profile == .tight) .disable else .outbound;
    }

    pub fn writeMode(s: Spec) WriteMode {
        return s.policy.write orelse .overlay;
    }

    /// The timeout the plan gets: its `timeout` line's, or its profile's.
    pub fn timeout(s: Spec) ?u64 {
        return s.policy.timeout_ns orelse if (s.policy.profile == .tight) tight_timeout_ns else null;
    }

    /// Whether the cwd is writable, as far as the plan says: `compile`
    /// also needs the write mode to allow it.
    pub fn cwdWritable(s: Spec) bool {
        return s.policy.cwd_writable orelse (s.policy.profile != .tight or s.writeMode() == .ephemeral);
    }

    /// Writes the plan's lines, every default spelled out, so that
    /// `parsePlan` reads back a plan that compiles to the same machine.
    pub fn write(s: Spec, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("# h9 plan (design/plan-format.md): h9 --plan FILE runs it\n");
        try s.writeNamespace(w);
        try s.writePolicy(w);
        try s.writeLimits(w);
    }

    fn writeNamespace(s: Spec, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer scratch.deinit();
        try w.writeAll("\n# namespace\n");
        for (s.mounts) |m0| {
            if (m0.kind == .fd) continue;
            var arg: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
            defer arg.deinit();
            // A URL's query and a header's value can hold a token, so they
            // are written as `…`, which `parsePlan` refuses, as the plan's
            // comments always have: a plan that needs them names them in
            // a file, `header=@FILE`, or has them written in by hand.
            var m = m0;
            var hs: [16][]const u8 = undefined;
            if (m.kind == .url) {
                if (std.mem.indexOfScalar(u8, m.src, '?')) |q| m.src = std.fmt.allocPrint(scratch.allocator(), "{s}?" ++ elided, .{m.src[0..q]}) catch return error.WriteFailed;
                for (m.headers, 0..) |h, i| if (i < hs.len) {
                    const colon = std.mem.indexOfScalar(u8, h, ':');
                    hs[i] = if (h.len > 0 and h[0] == '@') h else std.fmt.allocPrint(scratch.allocator(), "{s}: " ++ elided, .{std.mem.trim(u8, h[0 .. colon orelse h.len], " \t")}) catch return error.WriteFailed;
                };
                m.headers = hs[0..@min(m.headers.len, hs.len)];
            }
            m.writeArg(&arg.writer) catch return error.WriteFailed;
            try w.writeAll(@tagName(m.kind));
            if (arg.written().len > 0) {
                try w.writeAll(" ");
                try writeWord(w, arg.written());
            }
            try w.writeAll("\n");
        }
        for (s.mounts) |m| if (m.kind == .fd) try w.print("# mount: an embedder's connection on {s}, passed beside the plan\n", .{m.dst});
        for (s.notes) |n| try w.print("# {s}\n", .{n});
        for (s.binds) |b| {
            var arg: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
            defer arg.deinit();
            b.writeArg(&arg.writer) catch return error.WriteFailed;
            try w.writeAll("bind ");
            try writeWord(w, arg.written());
            try w.writeAll("\n");
        }
        for (s.ns) |t_| try writeNsText(w, t_);
    }

    fn writePolicy(s: Spec, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const p = s.policy;
        try w.writeAll("\n# policy\n");
        try w.print("profile {t}\n", .{p.profile});
        try w.print("write {t}\n", .{s.writeMode()});
        try w.print("net {t}\n", .{s.netMode()});
        for (p.net_allow) |pat| {
            try w.writeAll("netallow ");
            try writeWord(w, pat);
            try w.writeAll("\n");
        }
        for ([_][]const []const u8{ p.readable, p.writable, p.read_deny }, [_][]const u8{ "allow read", "allow write", "deny read" }) |list, what| for (list) |path| {
            try w.print("{s} ", .{what});
            try writeWord(w, path);
            try w.writeAll("\n");
        };
        try w.writeAll("devices");
        if (p.host_fs) try w.writeAll(" host-fs");
        if (s.guest_tools) try w.writeAll(" guest-tools");
        try w.writeAll("\n");
    }

    fn writeLimits(s: Spec, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const p = s.policy;
        try w.writeAll("\n# limits and the run\n");
        if (p.memory) |m| try w.print("memory {f}\n", .{fmtSize(m)}) else try w.writeAll("# memory: the engine's default\n");
        if (p.pids) |n| try w.print("pids {d}\n", .{n}) else try w.writeAll("# pids: unlimited\n");
        if (p.cpus) |n| try w.print("cpus {d}\n", .{n}) else try w.writeAll("# cpus: as many as the engine runs\n");
        if (s.timeout()) |d| try w.print("timeout {f}\n", .{fmtDuration(d)}) else try w.writeAll("# timeout: none\n");
        try w.print("engine {t}\n", .{s.engine orelse .auto});
        if (s.arch) |a| try w.print("arch {s}\n", .{a.name()});
        for (s.env) |e| {
            try w.writeAll("env ");
            try writeWord(w, e);
            try w.writeAll("\n");
        }
        if (s.cwd) |c| {
            try w.writeAll("cwd ");
            try writeWord(w, c);
            try w.print(" {s}\n", .{if (s.cwdWritable()) "rw" else "ro"});
        }
        if (s.gfx) |g| {
            if (g.headless) {
                try w.writeAll("gfx headless");
                if (g.size) |sz| try w.print(" {d}x{d}", .{ sz[0], sz[1] });
            } else {
                try w.writeAll("gfx window");
                if (!g.clipboard) try w.writeAll(" noclip");
                if (g.scale) |n| try w.print(" scale={d}", .{n});
            }
            try w.writeAll("\n");
        }
        for (s.serve) |a| {
            try w.writeAll("serve ");
            try writeWord(w, a);
            try w.writeAll("\n");
        }
        if (s.serve_root) |r| {
            try w.writeAll("serveroot ");
            try writeWord(w, r);
            try w.writeAll("\n");
        }
        if (s.serve_token) |f| {
            try w.writeAll("servetoken ");
            try writeWord(w, f);
            try w.writeAll("\n");
        }
        for (s.serve_origins) |o| {
            try w.writeAll("serveorigin ");
            try writeWord(w, o);
            try w.writeAll("\n");
        }
        if (s.serve_net) try w.writeAll("servenet\n");
        if (s.run) |argv| {
            try w.writeAll("run");
            for (argv) |a| {
                try w.writeAll(" ");
                try writeWord(w, a);
            }
            try w.writeAll("\n");
        }
    }

    /// The plan's text, allocated in `arena`.
    pub fn text(s: Spec, arena: std.mem.Allocator) error{OutOfMemory}![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        s.write(&out.writer) catch return error.OutOfMemory;
        return out.written();
    }
};

/// What a plan's text has in place of a secret it leaves out.
const elided = "…";

/// Writes a word as namespace files read it: in single quotes, with `''`
/// for a quote, when it's empty or has a blank, a quote, `;`, or `#`.
pub fn writeWord(w: *std.Io.Writer, word: []const u8) std.Io.Writer.Error!void {
    if (word.len > 0 and std.mem.indexOfAny(u8, word, " \t\r\n';#") == null) return w.writeAll(word);
    try w.writeAll("'");
    for (word) |c| {
        if (c == '\'') try w.writeAll("'");
        try w.writeByte(c);
    }
    try w.writeAll("'");
}

/// Writes `--ns` text as plan lines: a line per command, its words quoted
/// as needed and its comments dropped.
fn writeNsText(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch.deinit();
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var rest = raw;
        while (rest.len > 0) {
            var words: std.ArrayList([]const u8) = .empty;
            rest = newns.split(scratch.allocator(), rest, &words) catch {
                // Not namespace syntax: compile refuses it, so show it.
                try w.print("# {s}\n", .{raw});
                break;
            };
            if (words.items.len == 0) continue;
            for (words.items, 0..) |word, i| {
                if (i > 0) try w.writeAll(" ");
                try writeWord(w, word);
            }
            try w.writeAll("\n");
        }
    }
}

/// Where a plan's text is wrong: the line, from 1, and what's wrong.
pub const PlanError = struct {
    line: u32 = 0,
    msg: []const u8 = "",
};

pub const PlanParseError = error{ Syntax, OutOfMemory };

/// Parses a plan's text (design/plan-format.md, "The format"). Strings
/// are allocated in `arena`, or point into `text`. A line h9 doesn't
/// know, or a value it can't take, is `error.Syntax`, with the line and
/// why in `err`.
pub fn parsePlan(arena: std.mem.Allocator, text: []const u8, err: *PlanError) PlanParseError!Spec {
    var p: PlanParser = .{ .arena = arena, .err = err };
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: u32 = 0;
    while (lines.next()) |raw| {
        n += 1;
        p.line = n;
        // A line that starts with `#` is a comment to its end, `;` and
        // all, so the caveats `--print` writes as comments stay comments.
        if (std.mem.trimStart(u8, raw, " \t\r").len > 0 and std.mem.trimStart(u8, raw, " \t\r")[0] == '#') continue;
        var rest = raw;
        while (rest.len > 0) {
            var words: std.ArrayList([]const u8) = .empty;
            rest = newns.split(arena, rest, &words) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Syntax => return p.fail("a quote isn't closed", .{}),
            };
            if (words.items.len == 0) continue;
            try p.take(words.items);
        }
    }
    return p.finish();
}

const PlanParser = struct {
    arena: std.mem.Allocator,
    err: *PlanError,
    line: u32 = 0,
    s: Spec = .{},
    mounts: std.ArrayList(mount.Mount) = .empty,
    mount_lines: std.ArrayList(u32) = .empty,
    binds: std.ArrayList(mount.Bind) = .empty,
    ns: std.ArrayList(u8) = .empty,
    /// The first namespace line, and the first that isn't a mount.
    first_ns: u32 = 0,
    first_bind: u32 = 0,
    net_allow: std.ArrayList([]const u8) = .empty,
    net_allow_lines: std.ArrayList(u32) = .empty,
    readable: std.ArrayList([]const u8) = .empty,
    readable_lines: std.ArrayList(u32) = .empty,
    writable: std.ArrayList([]const u8) = .empty,
    writable_lines: std.ArrayList(u32) = .empty,
    read_deny: std.ArrayList([]const u8) = .empty,
    env: std.ArrayList([]const u8) = .empty,
    serve: std.ArrayList([]const u8) = .empty,
    serve_lines: std.ArrayList(u32) = .empty,
    origins: std.ArrayList([]const u8) = .empty,
    origin_lines: std.ArrayList(u32) = .empty,

    fn fail(p: *PlanParser, comptime fmt: []const u8, args: anytype) PlanParseError {
        p.err.* = .{ .line = p.line, .msg = try std.fmt.allocPrint(p.arena, fmt, args) };
        return error.Syntax;
    }

    /// The one argument a line takes.
    fn one(p: *PlanParser, w: []const []const u8) PlanParseError![]const u8 {
        if (w.len != 2) return p.fail("{s} takes one value", .{w[0]});
        return w[1];
    }

    fn enumOf(p: *PlanParser, comptime E: type, w: []const []const u8) PlanParseError!E {
        const v = try p.one(w);
        return std.meta.stringToEnum(E, v) orelse {
            var names: std.Io.Writer.Allocating = .init(p.arena);
            for (std.meta.fieldNames(E), 0..) |f, i| names.writer.print("{s}{s}", .{ if (i > 0) ", " else "", f }) catch return error.OutOfMemory;
            return p.fail("{s} '{s}': not {s}", .{ w[0], v, names.written() });
        };
    }

    fn count(p: *PlanParser, w: []const []const u8) PlanParseError!u32 {
        const v = try p.one(w);
        const n = std.fmt.parseInt(u32, v, 10) catch 0;
        if (n == 0) return p.fail("{s} '{s}': not a count", .{ w[0], v });
        return n;
    }

    fn take(p: *PlanParser, w: []const []const u8) PlanParseError!void {
        const cmd = w[0];
        const a = p.arena;
        if (std.meta.stringToEnum(mount.Kind, cmd)) |kind| {
            if (kind == .fd) return p.fail("unknown line '{s}'", .{cmd});
            if (w.len > 2) return p.fail("{s} takes one value, as --{s} does", .{ cmd, cmd });
            if (p.first_bind != 0) return p.fail("{s} comes after the namespace line on line {d}, but mounts run first: move it up", .{ cmd, p.first_bind });
            if (kind != .builtin and w.len < 2) return p.fail("{s} needs a value, as --{s} does", .{ cmd, cmd });
            if (w.len == 2 and std.mem.indexOf(u8, w[1], elided) != null)
                return p.fail("{s}: a URL's query or a header's value was left out here (…): write it in, or use header=@FILE", .{cmd});
            var why: []const u8 = "";
            const m = mount.Mount.parse(a, kind, if (w.len == 2) w[1] else "", &why) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Usage => return p.fail("{s}: {s}", .{ cmd, why }),
            };
            try p.mounts.append(a, m);
            try p.mount_lines.append(a, p.line);
            return;
        }
        if (std.mem.eql(u8, cmd, "bind") and w.len == 2) return p.bindLine(w);
        if (newns.isCommand(cmd)) return p.namespaceLine(w);
        const pol = &p.s.policy;
        if (std.mem.eql(u8, cmd, "profile")) {
            pol.profile = try p.enumOf(Profile, w);
            p.s.lines.profile = p.line;
        } else if (std.mem.eql(u8, cmd, "write")) {
            pol.write = try p.enumOf(WriteMode, w);
            p.s.lines.write = p.line;
        } else if (std.mem.eql(u8, cmd, "net")) {
            pol.net = try p.enumOf(NetMode, w);
            p.s.lines.net = p.line;
        } else if (std.mem.eql(u8, cmd, "netallow")) {
            const v = try p.one(w);
            var why: []const u8 = "";
            _ = parseNetPattern(v, &why) catch return p.fail("netallow '{s}': {s}", .{ v, why });
            try p.net_allow.append(a, v);
            try p.net_allow_lines.append(a, p.line);
        } else if (std.mem.eql(u8, cmd, "allow") or std.mem.eql(u8, cmd, "deny")) {
            const allow = cmd[0] == 'a';
            if (w.len != 3) return p.fail("{s} takes {s} and a host path", .{ cmd, if (allow) "read or write" else "read" });
            if (w[2].len == 0) return p.fail("{s}: an empty path", .{cmd});
            if (std.mem.eql(u8, w[1], "read")) {
                if (allow) {
                    try p.readable.append(a, w[2]);
                    try p.readable_lines.append(a, p.line);
                } else try p.read_deny.append(a, w[2]);
            } else if (allow and std.mem.eql(u8, w[1], "write")) {
                try p.writable.append(a, w[2]);
                try p.writable_lines.append(a, p.line);
            } else return p.fail("{s} '{s}': not {s}", .{ cmd, w[1], if (allow) "read or write" else "read" });
        } else if (std.mem.eql(u8, cmd, "devices")) {
            pol.host_fs = false;
            p.s.guest_tools = false;
            for (w[1..]) |d| {
                if (std.mem.eql(u8, d, "host-fs")) {
                    pol.host_fs = true;
                } else if (std.mem.eql(u8, d, "guest-tools")) {
                    p.s.guest_tools = true;
                } else return p.fail("devices '{s}': not host-fs or guest-tools", .{d});
            }
            p.s.lines.devices = p.line;
        } else if (std.mem.eql(u8, cmd, "memory")) {
            const v = try p.one(w);
            pol.memory = parseSize(v) orelse return p.fail("memory '{s}': not a size, such as 512M", .{v});
            p.s.lines.memory = p.line;
        } else if (std.mem.eql(u8, cmd, "pids")) {
            pol.pids = try p.count(w);
            p.s.lines.pids = p.line;
        } else if (std.mem.eql(u8, cmd, "cpus")) {
            pol.cpus = try p.count(w);
            p.s.lines.cpus = p.line;
        } else if (std.mem.eql(u8, cmd, "timeout")) {
            const v = try p.one(w);
            const d = parseDuration(v) orelse 0;
            if (d == 0) return p.fail("timeout '{s}': not a duration, such as 30s or 5m", .{v});
            pol.timeout_ns = d;
            p.s.lines.timeout = p.line;
        } else if (std.mem.eql(u8, cmd, "engine")) {
            p.s.engine = try p.enumOf(EngineChoice, w);
            p.s.lines.engine = p.line;
        } else if (std.mem.eql(u8, cmd, "arch")) {
            const v = try p.one(w);
            p.s.arch = aout.Arch.fromName(v) orelse return p.fail("arch '{s}': not arm64, amd64, or 386", .{v});
            p.s.lines.arch = p.line;
        } else if (std.mem.eql(u8, cmd, "env")) {
            const v = try p.one(w);
            const eq = std.mem.indexOfScalar(u8, v, '=') orelse 0;
            if (eq == 0 or std.mem.indexOfScalar(u8, v[0..eq], '/') != null) return p.fail("env '{s}': not NAME=VALUE", .{v});
            try p.env.append(a, v);
        } else if (std.mem.eql(u8, cmd, "cwd")) {
            if (w.len < 2 or w.len > 3 or w[1].len == 0) return p.fail("cwd takes a host path, and rw or ro", .{});
            p.s.cwd = w[1];
            if (w.len == 3) pol.cwd_writable = if (std.mem.eql(u8, w[2], "rw")) true else if (std.mem.eql(u8, w[2], "ro")) false else return p.fail("cwd '{s}': not rw or ro", .{w[2]});
            p.s.lines.cwd = p.line;
        } else if (std.mem.eql(u8, cmd, "gfx")) {
            p.s.gfx = try p.gfx(w);
            p.s.lines.gfx = p.line;
        } else if (std.mem.eql(u8, cmd, "serve")) {
            const v = try p.one(w);
            if (!std.mem.startsWith(u8, v, "unix!") and !std.mem.startsWith(u8, v, "tcp!") and !std.mem.startsWith(u8, v, "ws://"))
                return p.fail("serve '{s}': not unix!PATH, tcp!HOST!PORT, or ws://HOST:PORT[/PATH]", .{v});
            try p.serve.append(a, v);
            try p.serve_lines.append(a, p.line);
        } else if (std.mem.eql(u8, cmd, "serveroot")) {
            const v = try p.one(w);
            if (v.len == 0 or v[0] != '/') return p.fail("serveroot '{s}': not an absolute guest path", .{v});
            p.s.serve_root = v;
            p.s.lines.serve_root = p.line;
        } else if (std.mem.eql(u8, cmd, "servetoken")) {
            const v = try p.one(w);
            // A file, so the token itself isn't in the plan.
            if (v.len < 2 or v[0] != '@') return p.fail("servetoken takes @FILE, the token's host file", .{});
            p.s.serve_token = v;
        } else if (std.mem.eql(u8, cmd, "serveorigin")) {
            const v = try p.one(w);
            if (v.len == 0) return p.fail("serveorigin: an empty origin", .{});
            try p.origins.append(a, v);
            try p.origin_lines.append(a, p.line);
        } else if (std.mem.eql(u8, cmd, "servenet")) {
            if (w.len != 1) return p.fail("servenet takes no value", .{});
            p.s.serve_net = true;
            p.s.lines.serve_net = p.line;
        } else if (std.mem.eql(u8, cmd, "run")) {
            if (w.len < 2) return p.fail("run needs a program", .{});
            p.s.run = try a.dupe([]const u8, w[1..]);
        } else return p.fail("unknown line '{s}'", .{cmd});
    }

    fn gfx(p: *PlanParser, w: []const []const u8) PlanParseError!GfxSpec {
        if (w.len < 2) return p.fail("gfx takes window or headless", .{});
        var g: GfxSpec = .{};
        if (std.mem.eql(u8, w[1], "headless")) {
            g.headless = true;
            if (w.len > 3) return p.fail("gfx headless takes a size, WxH", .{});
            if (w.len == 3) {
                const x = std.mem.indexOfScalar(u8, w[2], 'x') orelse return p.fail("gfx headless '{s}': not WxH", .{w[2]});
                const dx = std.fmt.parseInt(u16, w[2][0..x], 10) catch 0;
                const dy = std.fmt.parseInt(u16, w[2][x + 1 ..], 10) catch 0;
                if (dx == 0 or dy == 0 or dx > 16384 or dy > 16384) return p.fail("gfx headless '{s}': each side is 1 to 16384", .{w[2]});
                g.size = .{ dx, dy };
            }
            return g;
        }
        if (!std.mem.eql(u8, w[1], "window")) return p.fail("gfx '{s}': not window or headless", .{w[1]});
        for (w[2..]) |o| {
            if (std.mem.eql(u8, o, "noclip")) {
                g.clipboard = false;
            } else if (std.mem.startsWith(u8, o, "scale=")) {
                g.scale = std.fmt.parseInt(u8, o["scale=".len..], 10) catch return p.fail("gfx '{s}': not scale=N", .{o});
            } else return p.fail("gfx window '{s}': not noclip or scale=N", .{o});
        }
        return g;
    }

    /// A namespace line, checked as `--ns` checks it, and replayed as
    /// `--ns` is, after the mounts and the `--bind`s.
    fn namespaceLine(p: *PlanParser, w: []const []const u8) PlanParseError!void {
        const a = p.arena;
        var line: std.Io.Writer.Allocating = .init(a);
        for (w, 0..) |word, i| {
            if (i > 0) line.writer.writeAll(" ") catch return error.OutOfMemory;
            writeWord(&line.writer, word) catch return error.OutOfMemory;
        }
        var ln: usize = 0;
        _ = newns.parse(a, line.written(), &ln) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Syntax => return p.fail("{s}: not a namespace line h9 takes", .{w[0]}),
        };
        if (p.first_bind == 0) p.first_bind = p.line;
        if (p.first_ns == 0) p.first_ns = p.line;
        try p.ns.appendSlice(a, line.written());
        try p.ns.append(a, '\n');
    }

    /// A `bind` line with one value, `--bind`'s: `bind SRC:DST[:OPTS]`.
    fn bindLine(p: *PlanParser, w: []const []const u8) PlanParseError!void {
        if (p.first_ns != 0) return p.fail("bind {s} comes after the namespace line on line {d}, but --bind lines run first: move it up", .{ w[1], p.first_ns });
        var why: []const u8 = "";
        const b = mount.Bind.parse(w[1], &why) catch return p.fail("bind {s}: {s}", .{ w[1], why });
        if (p.first_bind == 0) p.first_bind = p.line;
        try p.binds.append(p.arena, b);
    }

    fn finish(p: *PlanParser) PlanParseError!Spec {
        var s = p.s;
        s.mounts = p.mounts.items;
        s.lines.mounts = p.mount_lines.items;
        s.binds = p.binds.items;
        if (p.ns.items.len > 0) s.ns = try p.arena.dupe([]const u8, &.{p.ns.items});
        s.policy.net_allow = p.net_allow.items;
        s.lines.net_allow = p.net_allow_lines.items;
        s.policy.readable = p.readable.items;
        s.lines.readable = p.readable_lines.items;
        s.policy.writable = p.writable.items;
        s.lines.writable = p.writable_lines.items;
        s.policy.read_deny = p.read_deny.items;
        s.env = p.env.items;
        s.serve = p.serve.items;
        s.lines.serve = p.serve_lines.items;
        s.serve_origins = p.origins.items;
        s.lines.serve_origins = p.origin_lines.items;
        return s;
    }
};

/// Writes a plan (design/plan-format.md) as `--print` does: its lines,
/// and then what h9 compiles them to, which isn't read back, as
/// comments, ending with the caveats.
pub fn printPlan(w: *std.Io.Writer, spec: Spec, plan: *const Plan) std.Io.Writer.Error!void {
    try spec.write(w);
    try w.writeAll("\n# What h9 builds from these lines (comments, not read back):\n");
    var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();
    plan.print(&out.writer) catch return error.WriteFailed;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out.written(), "\n"), '\n');
    while (it.next()) |l| try w.print("# {s}\n", .{l});
}

pub const NarrowError = error{ Widens, OutOfMemory };

/// Narrows plan `base` by `by` (design/plan-format.md): the rule for
/// flags given with `--plan`, and for a child machine's plan under its
/// parent's. What `by` leaves unset, its defaults, keeps `base`'s
/// setting; what it sets replaces `base`'s where it's no wider: a lower
/// limit, a mount or a path made read-only, a network rule removed, a
/// path denied, a device left out. `by.profile` tight narrows to the
/// tight profile's settings. Anything wider is `error.Widens`, with
/// `why` naming the line of `base` it conflicts with. `by.run` replaces
/// the run, and `by.env` adds to or replaces `base`'s variables.
/// Allocations go in `arena`; the result may share `base`'s and `by`'s.
pub fn narrow(arena: std.mem.Allocator, base: Spec, by: Spec, why: *[]const u8) NarrowError!Spec {
    var n: Narrowing = .{ .arena = arena, .base = base, .by = by, .why = why };
    return n.run();
}

const Narrowing = struct {
    arena: std.mem.Allocator,
    base: Spec,
    by: Spec,
    why: *[]const u8,

    /// `what` (in plan syntax) widens `base`'s line `line`, `had`.
    fn widens(n: *Narrowing, what: []const u8, line: u32, had: []const u8) NarrowError {
        n.why.* = if (line > 0)
            try std.fmt.allocPrint(n.arena, "{s} widens the plan's line {d}: {s}", .{ what, line, had })
        else
            try std.fmt.allocPrint(n.arena, "{s} widens the plan, which has {s}", .{ what, had });
        return error.Widens;
    }

    fn str(n: *Narrowing, comptime fmt: []const u8, args: anytype) NarrowError![]const u8 {
        return std.fmt.allocPrint(n.arena, fmt, args);
    }

    fn run(n: *Narrowing) NarrowError!Spec {
        const base = n.base;
        const by = n.by;
        var r = base;
        const a = n.arena;
        // A tight profile narrows to its own settings, which an explicit
        // setting in `by` overrides.
        const tight = by.policy.profile == .tight;
        if (base.policy.profile == .tight and by.policy.profile == .default and by.lines.profile > 0)
            return n.widens("profile default", base.lines.profile, "profile tight");
        if (tight) r.policy.profile = .tight;

        // Limits: lower only.
        inline for (.{ .{ "memory", "memory" }, .{ "pids", "pids" }, .{ "cpus", "cpus" } }) |f| {
            if (@field(by.policy, f[0])) |v| {
                if (@field(base.policy, f[0])) |had| if (v > had) {
                    return n.widens(try n.limitText(f[1], v), @field(base.lines, f[1]), try n.limitText(f[1], had));
                };
                @field(r.policy, f[0]) = v;
            }
        }
        const had_timeout = base.timeout();
        const want_timeout = by.policy.timeout_ns orelse if (tight) tight_timeout_ns else null;
        if (want_timeout) |v| {
            if (had_timeout) |h| if (v > h) {
                if (by.policy.timeout_ns != null) return n.widens(try n.str("timeout {f}", .{fmtDuration(v)}), base.lines.timeout, try n.str("timeout {f}", .{fmtDuration(h)}));
            };
            r.policy.timeout_ns = if (had_timeout) |h| @min(h, v) else v;
        } else r.policy.timeout_ns = had_timeout;

        // The network: disable < outbound < enable, and an allowlist only
        // ever loses patterns.
        const had_net = base.netMode();
        const want_net: ?NetMode = by.policy.net orelse if (tight) .disable else null;
        if (want_net) |v| {
            if (@intFromEnum(v) > @intFromEnum(had_net)) return n.widens(try n.str("net {t}", .{v}), base.lines.net, try n.str("net {t}", .{had_net}));
            r.policy.net = v;
        } else r.policy.net = had_net;
        if (by.policy.net_allow.len > 0) {
            if (r.policy.net == .disable) return n.widens(try n.str("netallow {s}", .{by.policy.net_allow[0]}), base.lines.net, "net disable");
            if (base.policy.net_allow.len > 0) for (by.policy.net_allow) |pat| {
                const known = for (base.policy.net_allow) |b| {
                    if (std.mem.eql(u8, b, pat)) break true;
                } else false;
                if (!known) return n.widens(try n.str("netallow {s}", .{pat}), lineAt(base.lines.net_allow, 0), try n.str("netallow {s}", .{base.policy.net_allow[0]}));
            };
            r.policy.net_allow = by.policy.net_allow;
        }
        if (r.policy.net == .disable) r.policy.net_allow = &.{};

        // Writes: none narrows everything, ephemeral keeps the host from
        // being written, and scope and overlay differ in what they write
        // (a 9P root, or memory), so neither narrows the other.
        const had_write = base.writeMode();
        if (by.policy.write) |v| {
            if (!writeNarrows(v, had_write)) return n.widens(try n.str("write {t}", .{v}), base.lines.write, try n.str("write {t}", .{had_write}));
            r.policy.write = v;
        } else r.policy.write = had_write;

        // Host paths: a readable path only where the plan already shares
        // something, a writable one only where it already writes, and a
        // denied one anywhere.
        var readable: std.ArrayList([]const u8) = .empty;
        var writable: std.ArrayList([]const u8) = .empty;
        try readable.appendSlice(a, base.policy.readable);
        for (by.policy.readable) |p| {
            if (!n.shares(p)) return n.widens(try n.str("allow read {s}", .{p}), 0, try n.str("nothing that shares {s}", .{p}));
            try readable.append(a, p);
        }
        for (base.policy.writable) |p| {
            const ro = for (by.policy.readable) |q| {
                if (std.mem.eql(u8, q, p)) break true;
            } else false;
            if (!ro) try writable.append(a, p);
        }
        for (by.policy.writable) |p| {
            if (!n.writes(p)) {
                const at = n.covering(p);
                return n.widens(try n.str("allow write {s}", .{p}), at.line, at.text orelse try n.str("nothing that writes {s}", .{p}));
            }
            const dup = for (writable.items) |q| {
                if (std.mem.eql(u8, q, p)) break true;
            } else false;
            if (!dup) try writable.append(a, p);
        }
        if (r.policy.write == .none) {
            try readable.appendSlice(a, writable.items);
            writable.clearRetainingCapacity();
        }
        r.policy.readable = readable.items;
        r.policy.writable = writable.items;
        r.policy.read_deny = try std.mem.concat(a, []const u8, &.{ base.policy.read_deny, by.policy.read_deny });

        // The cwd: the plan's, made read-only if `by` says so.
        if (by.cwd) |c| if (base.cwd == null or !std.mem.eql(u8, c, base.cwd.?)) {
            return n.widens(try n.str("cwd {s}", .{c}), base.lines.cwd, if (base.cwd) |b| try n.str("cwd {s}", .{b}) else "no cwd");
        };
        const had_cwd_rw = base.cwdWritable();
        const want_cwd_rw: ?bool = by.policy.cwd_writable orelse if (tight) false else null;
        if (want_cwd_rw) |v| {
            if (v and !had_cwd_rw) return n.widens(try n.str("cwd {s} rw", .{base.cwd orelse "."}), base.lines.cwd, try n.str("cwd {s} ro", .{base.cwd orelse "."}));
            r.policy.cwd_writable = v;
        } else r.policy.cwd_writable = had_cwd_rw;

        // Devices: only left out.
        if (by.policy.host_fs and !base.policy.host_fs) return n.widens("devices host-fs", base.lines.devices, "no host-fs");
        if (!by.guest_tools) r.guest_tools = false;

        // Mounts: only ones the plan has, with an access no wider.
        var mounts = try a.dupe(mount.Mount, base.mounts);
        for (by.mounts) |m| {
            const at = for (mounts, 0..) |b, i| {
                if (b.kind == m.kind and std.mem.eql(u8, b.src, m.src) and std.mem.eql(u8, b.dst, m.dst)) break i;
            } else return n.widens(try n.str("{s} {f}", .{ @tagName(m.kind), argOf(m) }), 0, try n.str("no such mount", .{}));
            const b = mounts[at];
            if (accessRank(m) > accessRank(b)) return n.widens(try n.str("{s} {f}", .{ @tagName(m.kind), argOf(m) }), lineAt(base.lines.mounts, at), try n.str("{s} {f}", .{ @tagName(b.kind), argOf(b) }));
            if (m.access != null) mounts[at].access = m.access;
        }
        if (r.policy.write == .none) for (mounts) |*m| {
            if (m.access != null and m.access.? != .ro) m.access = .ro;
        };
        r.mounts = mounts;
        if (by.binds.len > 0) return n.widens(try n.str("bind {s}:{s}", .{ by.binds[0].src, by.binds[0].dst }), 0, "no such bind");
        if (by.ns.len > 0) return n.widens(try n.str("the namespace lines {s}", .{std.mem.trim(u8, by.ns[0], " \n")}), 0, "no such lines");

        // The machine: a different engine or architecture is another
        // machine, but a plan without one, or with `engine auto`, takes
        // any but sud, which isn't a security boundary.
        if (by.engine) |e| {
            const had = base.engine;
            const ok = if (had) |h| h == e or (h == .auto and e != .sud) else true;
            if (!ok) return n.widens(try n.str("engine {t}", .{e}), base.lines.engine, try n.str("engine {t}", .{had.?}));
            r.engine = e;
        }
        if (by.arch) |x| {
            if (base.arch) |h| if (h != x) return n.widens(try n.str("arch {s}", .{x.name()}), base.lines.arch, try n.str("arch {s}", .{h.name()}));
            r.arch = x;
        }
        if (by.env.len > 0) {
            var env: std.ArrayList([]const u8) = .empty;
            for (base.env) |e| {
                const name = e[0 .. std.mem.indexOfScalar(u8, e, '=') orelse e.len];
                const replaced = for (by.env) |f| {
                    if (std.mem.startsWith(u8, f, name) and f.len > name.len and f[name.len] == '=') break true;
                } else false;
                if (!replaced) try env.append(a, e);
            }
            try env.appendSlice(a, by.env);
            r.env = env.items;
        }

        // A window, and serving, only as the plan has them.
        if (by.gfx) |g| {
            const had = base.gfx orelse return n.widens(try n.str("gfx {s}", .{if (g.headless) "headless" else "window"}), 0, "no gfx");
            if (had.headless != g.headless or (g.clipboard and !had.clipboard))
                return n.widens(try n.str("gfx {s}{s}", .{ if (g.headless) "headless" else "window", if (g.clipboard or g.headless) "" else " noclip" }), base.lines.gfx, try n.str("gfx {s}{s}", .{ if (had.headless) "headless" else "window", if (had.clipboard or had.headless) "" else " noclip" }));
            r.gfx = g;
        }
        for (by.serve) |s| {
            const known = for (base.serve) |b| {
                if (std.mem.eql(u8, b, s)) break true;
            } else false;
            if (!known) return n.widens(try n.str("serve {s}", .{s}), lineAt(base.lines.serve, 0), if (base.serve.len > 0) try n.str("serve {s}", .{base.serve[0]}) else "no serve");
        }
        if (by.serve.len > 0) r.serve = by.serve;
        if (by.serve_net and !base.serve_net) return n.widens("servenet", 0, "no servenet");
        if (by.serve_root) |root| {
            const had = base.serve_root orelse "/";
            if (relUnder(had, root) == null) return n.widens(try n.str("serveroot {s}", .{root}), base.lines.serve_root, try n.str("serveroot {s}", .{had}));
            r.serve_root = root;
        }
        if (by.serve_token) |tk| r.serve_token = tk;
        if (by.serve_origins.len > 0) {
            for (by.serve_origins) |o| {
                const known = for (base.serve_origins) |b| {
                    if (std.mem.eql(u8, b, o)) break true;
                } else false;
                if (!known) return n.widens(try n.str("serveorigin {s}", .{o}), lineAt(base.lines.serve_origins, 0), if (base.serve_origins.len > 0) try n.str("serveorigin {s}", .{base.serve_origins[0]}) else "no serveorigin");
            }
            r.serve_origins = by.serve_origins;
        }
        if (by.run) |argv| r.run = argv;
        // A result has no lines of its own.
        r.lines = .{};
        return r;
    }

    fn limitText(n: *Narrowing, comptime what: []const u8, v: anytype) NarrowError![]const u8 {
        if (comptime std.mem.eql(u8, what, "memory")) return n.str("memory {f}", .{fmtSize(v)});
        return n.str(what ++ " {d}", .{v});
    }

    /// Whether the plan shares host path `p` with the guest at all.
    fn shares(n: *Narrowing, p: []const u8) bool {
        const b = n.base;
        if (b.policy.host_fs) return true;
        if (b.cwd) |c| if (relUnder(c, p) != null) return true;
        for ([_][]const []const u8{ b.policy.readable, b.policy.writable }) |list| for (list) |q| {
            if (relUnder(q, p) != null) return true;
        };
        for (b.mounts) |m| if (m.kind == .dir and relUnder(m.src, p) != null) return true;
        return false;
    }

    /// Whether the plan already lets the guest write host path `p`.
    fn writes(n: *Narrowing, p: []const u8) bool {
        const b = n.base;
        if (b.writeMode() == .none) return false;
        if (b.cwd) |c| if (b.cwdWritable() and relUnder(c, p) != null) return true;
        for (b.policy.writable) |q| if (relUnder(q, p) != null) return true;
        for (b.mounts) |m| if (m.kind == .dir and (m.access == .rw or m.access == .up) and relUnder(m.src, p) != null) return true;
        return false;
    }

    /// The plan's line that shares `p` read-only, for an error.
    fn covering(n: *Narrowing, p: []const u8) struct { line: u32, text: ?[]const u8 } {
        const b = n.base;
        for (b.policy.readable, 0..) |q, i| if (relUnder(q, p) != null) return .{ .line = lineAt(b.lines.readable, i), .text = n.str("allow read {s}", .{q}) catch null };
        if (b.cwd) |c| if (relUnder(c, p) != null) return .{ .line = b.lines.cwd, .text = n.str("cwd {s} ro", .{c}) catch null };
        for (b.mounts, 0..) |m, i| if (m.kind == .dir and relUnder(m.src, p) != null) return .{ .line = lineAt(b.lines.mounts, i), .text = n.str("dir {f}", .{argOf(m)}) catch null };
        return .{ .line = 0, .text = null };
    }
};

fn lineAt(lines: []const u32, i: usize) u32 {
    return if (i < lines.len) lines[i] else 0;
}

/// Whether write mode `v` is no wider than `had`.
fn writeNarrows(v: WriteMode, had: WriteMode) bool {
    if (v == had or v == .none) return true;
    return v == .ephemeral and had != .none;
}

/// How much a mount lets the guest change: ro, then eph (in memory),
/// then rw and up (the source). No access is its destination's default:
/// on a stack, the overlay's eph, and elsewhere ro.
fn accessRank(m: mount.Mount) u8 {
    const a = m.access orelse return if (m.stack() != null) 1 else 0;
    return switch (a) {
        .ro => 0,
        .eph => 1,
        .rw, .up => 2,
    };
}

fn argOf(m: mount.Mount) std.fmt.Alt(mount.Mount, writeMountArg) {
    return .{ .data = m };
}

fn writeMountArg(m: mount.Mount, w: *std.Io.Writer) std.Io.Writer.Error!void {
    return m.writeArg(w);
}

const t = std.testing;

const r_mounts = [_]mount.Mount{.{ .kind = .dir, .src = "/r" }};

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
    const in: Inputs = .{ .mounts = &r_mounts, .cwd = "/w", .arch = .arm64 };

    const d = try compile(arena.allocator(), in, .{}, &msg);
    try t.expectEqual(Verdict.allow, d.check("/w/f", .create));
    try t.expectEqual(Verdict.read_only, d.check("/r/f", .create));
    try t.expectEqualStrings("CU" ++ hidx_dev ++ "bim", d.devmask);
    try t.expect(!d.enforces.contains(.@"net.disable"));
    try t.expectEqual(@as(?u64, null), d.timeout_ns);

    const tt = try compile(arena.allocator(), in, .{ .profile = .tight }, &msg);
    try t.expectEqual(Verdict.read_only, tt.check("/w/f", .create));
    try t.expectEqualStrings("CI" ++ hstream_dev ++ "U" ++ hidx_dev ++ "bim", tt.devmask);
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

test "compile: an up member is bind -u on its stack, which then has no overlay [upper-layers]" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var msg: []const u8 = "";
    const ms = [_]mount.Mount{
        .{ .kind = .dir, .src = "/r" },
        .{ .kind = .dir, .src = "/alpine", .dst = "#L" },
        .{ .kind = .dir, .src = "/app", .dst = "#L", .access = .up },
        .{ .kind = .dir, .src = "/deps", .dst = "#L" },
        .{ .kind = .tmp, .dst = "/n/x", .access = .up },
    };
    const p = try compile(a, .{ .mounts = &ms, .cwd = "/w", .arch = .amd64 }, .{}, &msg);
    try t.expectEqual(Verdict.allow, p.check("/app/f", .create));
    try t.expectEqual(Verdict.read_only, p.check("/deps/f", .create));
    var up_line = false;
    var tmp_line = false;
    for (p.binds) |b| {
        // The Linux stack has a layer, so no overlay in memory.
        try t.expect(!(std.mem.eql(u8, b.from, "#O") and std.mem.eql(u8, b.to, "#Olinux")));
        if (b.upper and std.mem.eql(u8, b.from, "#U!c/app")) up_line = true;
        if (b.upper and b.empty and std.mem.eql(u8, b.to, "/n/x")) tmp_line = true;
    }
    try t.expect(up_line);
    try t.expect(tmp_line);
    var out: std.Io.Writer.Allocating = .init(a);
    try p.print(&out.writer);
    try t.expect(std.mem.indexOf(u8, out.written(), "bind -u '#U!c/app' '#Olinux'") != null);

    // Two layers on a stack, and a layer under --write=ephemeral, conflict.
    const two = [_]mount.Mount{
        .{ .kind = .dir, .src = "/a", .dst = "#L", .access = .up },
        .{ .kind = .dir, .src = "/b", .dst = "#L", .access = .up },
    };
    try t.expectError(error.Conflict, compile(a, .{ .mounts = &two, .cwd = "/w", .arch = .amd64 }, .{}, &msg));
    try t.expectError(error.Conflict, compile(a, .{ .mounts = two[0..1], .cwd = "/w", .arch = .amd64 }, .{ .write = .ephemeral }, &msg));
    try t.expectError(error.Conflict, compile(a, .{ .mounts = two[0..1], .cwd = "/w", .arch = .amd64 }, .{ .write = .none }, &msg));
}

test "compile: --write=none conflicts with --writable" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var msg: []const u8 = "";
    const in: Inputs = .{ .mounts = &r_mounts, .cwd = "/w", .arch = .arm64 };
    try t.expectError(error.Conflict, compile(arena.allocator(), in, .{ .write = .none, .writable = &.{"/w"} }, &msg));
}

test "compile: paths outside the root and cwd go under /mnt/term" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var msg: []const u8 = "";
    const p = try compile(arena.allocator(), .{ .mounts = &r_mounts, .cwd = "/w", .arch = .arm64 }, .{ .readable = &.{"/src/proj"} }, &msg);
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

test "guestPath: a host file's guest path, or null if the guest can't read it [host-scripts]" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var msg: []const u8 = "";
    const mounts = r_mounts ++ [_]mount.Mount{.{ .kind = .dir, .src = "/data", .dst = "/n/data" }};
    const pol: Policy = .{ .readable = &.{"/src/proj"}, .read_deny = &.{"/w/secret"} };
    const p = try compile(a, .{ .mounts = &mounts, .cwd = "/w", .arch = .arm64 }, pol, &msg);
    try t.expectEqualStrings("/mnt/term/cwd/greet", (try guestPath(a, &p, &mounts, "/w", pol, "/w/greet")).?);
    try t.expectEqualStrings("/mnt/term/cwd/a/b", (try guestPath(a, &p, &mounts, "/w", pol, "/w/a/b")).?);
    try t.expectEqualStrings("/mnt/term/src/proj/x", (try guestPath(a, &p, &mounts, "/w", pol, "/src/proj/x")).?);
    try t.expectEqualStrings("/n/data/x", (try guestPath(a, &p, &mounts, "/w", pol, "/data/x")).?);
    try t.expectEqualStrings("/bin/x", (try guestPath(a, &p, &mounts, "/w", pol, "/r/bin/x")).?);
    try t.expectEqual(null, try guestPath(a, &p, &mounts, "/w", pol, "/w/secret/x"));
    try t.expectEqual(null, try guestPath(a, &p, &mounts, "/w", pol, "/etc/x"));
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

test "an entry without a protocol or port takes the connect's, which the patterns decide [linux-dns]" {
    const nt = try t.allocator.create(NameTable);
    defer t.allocator.destroy(nt);
    nt.* = .{};
    const pats = [_]NetPattern{try tpat("tcp!api.example.com!443")};
    nt.record(null, &tip("10.0.0.7"), null, "api.example.com");
    try t.expect(nt.allows(&pats, .tcp, &tip("10.0.0.7"), 443));
    try t.expect(!nt.allows(&pats, .tcp, &tip("10.0.0.7"), 80));
    try t.expect(!nt.allows(&pats, .udp, &tip("10.0.0.7"), 443));
    try t.expect(!nt.allows(&pats, .tcp, &tip("10.0.0.8"), 443));
    // An entry cs recorded still needs its own protocol and port.
    nt.record(.tcp, &tip("10.0.0.9"), 80, "api.example.com");
    try t.expect(!nt.allows(&pats, .tcp, &tip("10.0.0.9"), 443));
}

test "a UDP connect to a recorded address is allowed as a probe, and nothing else is [linux-dns]" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var msg: []const u8 = "";
    const p = try compile(arena.allocator(), .{ .mounts = &r_mounts, .cwd = "/w", .arch = .arm64 }, .{ .net_allow = &.{"tcp!registry.example.com!443"} }, &msg);
    const v6 = tip("2001:db8::1");
    p.names.?.record(null, &tip("10.0.0.7"), null, "registry.example.com");
    p.names.?.record(null, &v6, null, "registry.example.com");
    p.names.?.record(.tcp, &tip("10.0.0.6"), 443, "registry.example.com");
    p.names.?.record(null, &tip("10.0.0.8"), null, "other.example.com");
    // The probe's port matches no pattern, so netCheck refuses it.
    try t.expect(!p.netCheck(.connect, .udp, &tip("10.0.0.7"), 9));
    try t.expect(p.netProbe(.udp, &tip("10.0.0.7")));
    try t.expect(p.netProbe(.udp, &v6));
    try t.expect(p.netProbe(.udp, &tip("10.0.0.6")));
    // TCP, an address recorded for a name no pattern covers, and one
    // never recorded aren't probes.
    try t.expect(!p.netProbe(.tcp, &tip("10.0.0.7")));
    try t.expect(!p.netProbe(null, &tip("10.0.0.7")));
    try t.expect(!p.netProbe(.udp, &tip("10.0.0.8")));
    try t.expect(!p.netProbe(.udp, &tip("10.0.0.9")));
}

test "net: --print shows patterns and caveats" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var msg: []const u8 = "";
    const p = try compile(arena.allocator(), .{ .mounts = &r_mounts, .cwd = "/w", .arch = .arm64 }, .{ .net_allow = &.{ "tcp!*.example.com!443", "udp!10.0.0.53!53" } }, &msg);
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
    const in: Inputs = .{ .mounts = &r_mounts, .cwd = "/w", .arch = .arm64 };

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
        try t.expectEqual(@as(?[]const u8, null), tmp.lower);
        try t.expect(tmp.create);
        try t.expectEqual(Access.eph, tmp.access.?);
        try t.expect(!p.enforces.contains(.@"fs.write.ephemeral"));
    }
    const none = try compile(arena.allocator(), in, .{ .write = .none }, &msg);
    try t.expectEqual(@as(?Bind, null), Find.bind(none, "/tmp"));

    // Ephemeral: the cwd and writable paths are overlays, read-only to devfs.
    const e = try compile(arena.allocator(), in, .{ .write = .ephemeral, .writable = &.{"/w/out"} }, &msg);
    try t.expect(e.enforces.contains(.@"fs.write.ephemeral"));
    try t.expectEqual(WriteMode.ephemeral, e.write);
    const cwd = Find.bind(e, "/mnt/term/cwd").?;
    try t.expectEqualStrings("#O", cwd.from);
    try t.expectEqualStrings("/w", cwd.lower.?);
    try t.expectEqualStrings("/mnt/term", cwd.fallback.?);
    try t.expectEqualStrings("/w/out", Find.bind(e, "/mnt/term/cwd/out").?.lower.?);
    try t.expectEqual(Verdict.read_only, e.check("/w/f", .create));
    try t.expectEqual(Verdict.read_only, e.check("/w/out/f", .write));
    try t.expectEqual(Verdict.allow, e.check("/w/out/f", .read));
    // The root is read-only to devfs, under an overlay (design/epoch-0/overlay.md).
    try t.expectEqualStrings("#U/r", Find.bind(e, "#Oroot").?.from);
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
    try t.expect(std.mem.indexOf(u8, text, "  bind -c '#O' /tmp ") != null);
    try t.expect(std.mem.indexOf(u8, text, "  eph  /w\n") != null);
    try t.expect(std.mem.indexOf(u8, text, "ephemeral files count against --memory") != null);
}

test "compile: #s at /srv in both profiles, and never masked" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var msg: []const u8 = "";
    const in: Inputs = .{ .mounts = &r_mounts, .cwd = "/w", .arch = .arm64 };
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
        const p = try compile(arena.allocator(), .{ .mounts = &r_mounts, .cwd = "/w", .arch = .arm64 }, .{ .profile = prof }, &msg);
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

        const off = try compile(arena.allocator(), .{ .mounts = &r_mounts, .cwd = "/w", .arch = .arm64, .guest_tools = false }, .{ .profile = prof }, &msg);
        for (off.binds) |b| try t.expect(!std.mem.startsWith(u8, b.from, "#H"));
        try t.expect(std.mem.indexOfScalar(u8, off.devmask, 'H') != null);
    }
}

test "compile: --gfx binds #i, #m and #b after the console, and masks them without it" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var msg: []const u8 = "";
    for ([_]Profile{ .default, .tight }) |prof| {
        const off = try compile(arena.allocator(), .{ .mounts = &r_mounts, .cwd = "/w", .arch = .arm64 }, .{ .profile = prof }, &msg);
        for ("bim") |d| try t.expect(std.mem.indexOfScalar(u8, off.devmask, d) != null);
        for (off.binds) |b| for ([_][]const u8{ "#i", "#m", "#b" }) |d| try t.expect(!std.mem.eql(u8, b.from, d));
        try t.expect(off.gfx == null);

        const on = try compile(arena.allocator(), .{ .mounts = &r_mounts, .cwd = "/w", .arch = .arm64, .gfx = .{ .backend = "x11" } }, .{ .profile = prof }, &msg);
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

        const noclip = try compile(arena.allocator(), .{ .mounts = &r_mounts, .cwd = "/w", .arch = .arm64, .gfx = .{ .backend = "cocoa", .clipboard = false, .scale = 2 } }, .{ .profile = prof }, &msg);
        out.clearRetainingCapacity();
        try noclip.print(&out.writer);
        try t.expect(std.mem.indexOf(u8, out.written(), "gfx:      cocoa scale=2 clipboard=private\n") != null);
        try t.expect(std.mem.indexOf(u8, out.written(), "/dev/snarf") == null);
        try t.expect(std.mem.indexOf(u8, out.written(), "looks like a host dialog") != null);
    }
}

test "compile: the web host's canvas shows clipboard=page and its own caveats" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var msg: []const u8 = "";
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    const page = try compile(arena.allocator(), .{ .mounts = &r_mounts, .cwd = "/w", .arch = .i386, .gfx = .{ .backend = "web", .scale = 0 } }, .{}, &msg);
    try page.print(&out.writer);
    try t.expect(std.mem.indexOf(u8, out.written(), "gfx:      web scale=0 clipboard=page\n") != null);
    try t.expect(std.mem.indexOf(u8, out.written(), "the guest can write the page's clipboard, and read what the user pastes into its canvas") != null);
    try t.expect(std.mem.indexOf(u8, out.written(), "looks like the page's own UI or a browser dialog") != null);
    try t.expect(std.mem.indexOf(u8, out.written(), "host clipboard") == null);

    const private = try compile(arena.allocator(), .{ .mounts = &r_mounts, .cwd = "/w", .arch = .i386, .gfx = .{ .backend = "web", .clipboard = false, .scale = 2 } }, .{}, &msg);
    out.clearRetainingCapacity();
    try private.print(&out.writer);
    try t.expect(std.mem.indexOf(u8, out.written(), "gfx:      web scale=2 clipboard=private\n") != null);
    try t.expect(std.mem.indexOf(u8, out.written(), "page's clipboard") == null);
}

/// The compile inputs a plan gives, for the plan tests.
fn testInputs(s: Spec) Inputs {
    return .{
        .mounts = s.mounts,
        .binds = s.binds,
        .cwd = s.cwd,
        .arch = s.arch orelse .amd64,
        .guest_tools = s.guest_tools,
        .gfx = if (s.gfx) |g| .{ .backend = "headless", .clipboard = g.clipboard, .scale = g.scale orelse 1, .headless = if (g.headless) .{ .dx = 1024, .dy = 768 } else null } else null,
    };
}

fn testCompiled(arena: std.mem.Allocator, s: Spec) ![]const u8 {
    var why: []const u8 = "";
    const p = try compile(arena, testInputs(s), s.policy, &why);
    var out: std.Io.Writer.Allocating = .init(arena);
    try p.print(&out.writer);
    return out.written();
}

test "a plan's text round-trips through its parser for every policy case [plan-format]" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = [_]mount.Mount{.{ .kind = .dir, .src = "/r" }};
    var why: []const u8 = "";
    const url = try mount.Mount.parse(a, .url, "src=wss://fs.example/9p,dst=/n/fs,ro,header=@/h,index=https://cdn.example/i,b3=abababababababababababababababababababababababababababababababab", &why);
    const cases = [_]Spec{
        .{ .mounts = &root, .cwd = "/home/me/proj" },
        .{ .mounts = &root, .cwd = "/home/me/proj", .policy = .{ .profile = .tight } },
        .{ .mounts = &root, .cwd = "/c", .policy = .{ .write = .none } },
        .{ .mounts = &root, .cwd = "/c", .policy = .{ .write = .scope, .writable = &.{"/out"} } },
        .{ .mounts = &root, .cwd = "/c", .policy = .{ .write = .ephemeral, .writable = &.{"/out"} } },
        .{ .mounts = &root, .cwd = "/c", .policy = .{ .net = .disable } },
        .{ .mounts = &root, .cwd = "/c", .policy = .{ .net = .enable, .net_allow = &.{ "tcp!*.example.com!443", "udp!10.0.0.53!53" } } },
        .{ .mounts = &root, .cwd = "/c", .policy = .{ .readable = &.{"/data set"}, .read_deny = &.{"/data set/.env"} } },
        .{ .mounts = &root, .cwd = "/c", .policy = .{ .memory = 512 << 20, .pids = 32, .cpus = 2, .timeout_ns = 90 * std.time.ns_per_s } },
        .{ .mounts = &root, .cwd = "/c", .policy = .{ .host_fs = true }, .guest_tools = false },
        .{ .mounts = &root, .cwd = "/sb", .policy = .{ .profile = .tight, .cwd_writable = true } },
        .{ .mounts = &root, .cwd = "/c", .gfx = .{ .headless = true, .size = .{ 640, 480 } } },
        .{ .mounts = &root, .cwd = "/c", .gfx = .{ .clipboard = false, .scale = 2 } },
        .{
            .mounts = &.{ root[0], .{ .kind = .builtin, .order = .after }, .{ .kind = .tmp, .dst = "/n/t", .access = .up }, .{ .kind = .archive, .src = "/a b.tgz", .dst = "/n/a" }, .{ .kind = .dir, .src = "/x:/y", .dst = "/n/x", .access = .rw, .contained = true }, url },
            .binds = &.{.{ .src = "/n/x/bin", .dst = "/bin", .order = .before }},
            .ns = &.{"bind -b '#Hroot/bin' /bin\nmount -c tcp!fs!564 /n/fs ''\nbind /a '/b c'\n"},
            .cwd = "/c",
            .engine = .sud,
            .arch = .i386,
            .env = &.{ "A=1", "B=two words" },
            .serve = &.{ "tcp!127.0.0.1!0", "ws://127.0.0.1:0/9p" },
            .serve_root = "/usr",
            .serve_token = "@tok",
            .serve_origins = &.{"http://a.example"},
            .serve_net = true,
            .run = &.{ "/bin/rc", "-c", "ls /bin | wc -l; echo 'q'" },
        },
    };
    for (cases) |c| {
        const text1 = try c.text(a);
        errdefer std.debug.print("{s}\n", .{text1});
        var err: PlanError = .{};
        const back = parsePlan(a, text1, &err) catch |e| {
            std.debug.print("line {d}: {s}\n", .{ err.line, err.msg });
            return e;
        };
        try t.expectEqualStrings(text1, try back.text(a));
        try t.expectEqualStrings(try testCompiled(a, c), try testCompiled(a, back));
    }
}

test "a plan leaves out a URL's query and a header's value, and refuses to run without them [plan-format]" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    const m = try mount.Mount.parse(a, .url, "ws://127.0.0.1:1/9p?token=s3cret:/:header=Authorization: Bearer s3cret", &why);
    const text = try (Spec{ .mounts = &.{m} }).text(a);
    try t.expect(std.mem.indexOf(u8, text, "s3cret") == null);
    try t.expect(std.mem.indexOf(u8, text, "url 'src=ws://127.0.0.1:1/9p?…,dst=/,header=Authorization: …'\n") != null);
    var err: PlanError = .{};
    try t.expectError(error.Syntax, parsePlan(a, text, &err));
    try t.expectEqual(@as(u32, 4), err.line);
}

test "an unknown plan line is an error with its line number [plan-format]" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var err: PlanError = .{};
    try t.expectError(error.Syntax, parsePlan(a, "# a plan\nmemory 512M\n\nfrobnicate 3\nnet outbound\n", &err));
    try t.expectEqual(@as(u32, 4), err.line);
    try t.expectEqualStrings("unknown line 'frobnicate'", err.msg);
    // A line after a `;` is the same line, and a bad value names it too.
    try t.expectError(error.Syntax, parsePlan(a, "net outbound; memory lots\n", &err));
    try t.expectEqual(@as(u32, 1), err.line);
    try t.expectError(error.Syntax, parsePlan(a, "bind /a:/b\ndir /r\n", &err));
    try t.expectEqual(@as(u32, 2), err.line);
    try t.expectError(error.Syntax, parsePlan(a, "\n\ndir /r:/:bogus\n", &err));
    try t.expectEqual(@as(u32, 3), err.line);
    try t.expectError(error.Syntax, parsePlan(a, "bind -b /a /b\nbind /x:/y\n", &err));
    try t.expectEqual(@as(u32, 2), err.line);
    const ok = try parsePlan(a, "dir /r\nbind /x:/bin:b\nbind -b /x /bin\nmount -c tcp!fs!564 /n/fs\nrun ls -l\n", &err);
    try t.expectEqual(@as(usize, 1), ok.binds.len);
    try t.expectEqualStrings("bind -b /x /bin\nmount -c tcp!fs!564 /n/fs\n", ok.ns[0]);
    try t.expectEqualStrings("-l", ok.run.?[1]);
}

test "narrowing takes lower limits, read-only paths, and fewer rules, and refuses wider ones [plan-format]" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var err: PlanError = .{};
    const base = try parsePlan(a,
        \\dir /r
        \\dir /src:/src:rw
        \\allow write /out
        \\netallow tcp!*.example.com!443
        \\netallow tcp!10.0.0.1!80
        \\memory 512M
        \\cwd /c rw
        \\engine auto
    , &err);
    var why: []const u8 = "";
    const ok = try narrow(a, base, .{
        .policy = .{ .memory = 64 << 20, .readable = &.{"/out"}, .read_deny = &.{"/c/.env"}, .net_allow = &.{"tcp!10.0.0.1!80"}, .timeout_ns = std.time.ns_per_s },
        .mounts = &.{.{ .kind = .dir, .src = "/src", .dst = "/src", .access = .ro }},
        .engine = .hcpu,
    }, &why);
    try t.expectEqual(@as(?u64, 64 << 20), ok.policy.memory);
    try t.expectEqual(@as(usize, 0), ok.policy.writable.len);
    try t.expectEqual(@as(usize, 1), ok.policy.net_allow.len);
    try t.expectEqual(mount.Access.ro, ok.mounts[1].access.?);
    try t.expectEqual(EngineChoice.hcpu, ok.engine.?);
    // The tight profile narrows to its settings.
    const tight = try narrow(a, base, .{ .policy = .{ .profile = .tight } }, &why);
    try t.expectEqual(NetMode.disable, tight.netMode());
    try t.expectEqual(@as(usize, 0), tight.policy.net_allow.len);
    try t.expect(!tight.cwdWritable());
    try t.expectEqual(@as(?u64, tight_timeout_ns), tight.timeout());

    const wide = [_]struct { Spec, []const u8 }{
        .{ .{ .policy = .{ .memory = 1 << 30 } }, "memory 1G widens the plan's line 6: memory 512M" },
        .{ .{ .policy = .{ .writable = &.{"/etc"} } }, "allow write /etc widens the plan, which has nothing that writes /etc" },
        .{ .{ .policy = .{ .net = .enable } }, "net enable widens the plan, which has net outbound" },
        .{ .{ .policy = .{ .net_allow = &.{"tcp!*!*"} } }, "netallow tcp!*!* widens the plan's line 4: netallow tcp!*.example.com!443" },
        .{ .{ .mounts = &.{.{ .kind = .dir, .src = "/etc", .dst = "/n/etc" }} }, "dir /etc:/n/etc widens the plan, which has no such mount" },
        .{ .{ .engine = .sud }, "engine sud widens the plan's line 8: engine auto" },
        .{ .{ .policy = .{ .host_fs = true } }, "devices host-fs widens the plan, which has no host-fs" },
    };
    for (wide) |c| {
        try t.expectError(error.Widens, narrow(a, base, c[0], &why));
        try t.expectEqualStrings(c[1], why);
    }
    // A read-only cwd stays read-only.
    const ro = try parsePlan(a, "cwd /c ro\nnet disable\n", &err);
    try t.expectError(error.Widens, narrow(a, ro, .{ .policy = .{ .cwd_writable = true } }, &why));
    try t.expectEqualStrings("cwd /c rw widens the plan's line 1: cwd /c ro", why);
    try t.expectError(error.Widens, narrow(a, ro, .{ .policy = .{ .net = .outbound } }, &why));
    try t.expectEqualStrings("net outbound widens the plan's line 2: net disable", why);
}
