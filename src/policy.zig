//! The sandbox policy (DESIGN.md, "Sandbox policy"): profiles and explicit
//! settings, compiled into a Plan that the machine's namespace builder
//! follows and `--print` shows. The Plan's access rules are what devfs
//! checks through `h9_fs_check` (src/kern.zig).
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
    /// Discard all writes on exit (design/ephemeral-writes.md; not enforced yet).
    ephemeral,
    /// Copy-on-write over the root (design/overlay.md; not enforced yet).
    overlay,
};

pub const NetMode = enum {
    disable,
    /// Clients work, `announce` is refused (design/net-policy.md; not enforced yet).
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
    /// Null means the profile's default (scope).
    write: ?WriteMode = null,
    /// Null means the profile's default.
    net: ?NetMode = null,
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
    /// The host temp dir, bound at /tmp (a private ramfs is proposed in
    /// design/ephemeral-writes.md).
    tmp: ?[]const u8 = null,
};

pub const Access = enum { ro, rw };

/// An allow or deny rule on a host path and everything beneath it.
pub const Rule = struct {
    path: []const u8,
    kind: enum { allow_ro, allow_rw, deny },
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

    pub const Flag = enum { repl, before, after };
};

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
    @"net.disable",
    @"net.outbound",
    @"proc.timeout",
    @"res.cpu",
    @"res.memory",
    @"res.pids",

    /// Whether this build can enforce it.
    pub fn enforceable(c: Capability) bool {
        return switch (c) {
            .@"fs.write.ephemeral", .@"fs.write.overlay", .@"net.outbound" => false,
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

    /// Checks `op` on the resolved host path `path`.
    pub fn check(p: *const Plan, path: []const u8, op: Op) Verdict {
        return checkRules(p.rules, path, op);
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
        for (p.devmask) |d| try w.print(" #{c}", .{d});
        try w.writeAll("\nnamespace:\n");
        for (p.binds) |b| {
            var line: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
            defer line.deinit();
            const lw = &line.writer;
            lw.writeAll("  bind") catch return error.WriteFailed;
            switch (b.flag) {
                .repl => {},
                .before => lw.writeAll(" -b") catch return error.WriteFailed,
                .after => lw.writeAll(" -a") catch return error.WriteFailed,
            }
            if (b.create) lw.writeAll(if (b.flag == .repl) " -c" else "c") catch return error.WriteFailed;
            lw.print(" '{s}{s}' {s}", .{ b.from, if (b.console) "<id>" else "", b.to }) catch return error.WriteFailed;
            try w.writeAll(line.written());
            if (b.access) |a| {
                const pad = 56 -| line.written().len;
                try w.splatByteAll(' ', pad + 1);
                try w.print("{t}", .{a});
            }
            try w.writeAll("\n");
        }
        if (p.rules.len > 0) {
            try w.writeAll("access:\n");
            for (p.rules) |r| try w.print("  {s} {s}\n", .{ switch (r.kind) {
                .allow_ro => "ro  ",
                .allow_rw => "rw  ",
                .deny => "deny",
            }, r.path });
        }
        try w.writeAll("caveats:\n");
        for (p.caveats) |c| try w.print("  - {s}\n", .{c});
    }
};

pub const CompileError = error{ OutOfMemory, Conflict };

pub const Inputs = struct {
    /// Host root tree, or null for a machine with devices only.
    root: ?[]const u8,
    /// Host directory bound at /mnt/term/cwd.
    cwd: ?[]const u8,
    arch: aout.Arch,
};

/// Compiles a policy. Allocations go in `arena`. `err_msg` explains a
/// Conflict.
pub fn compile(arena: std.mem.Allocator, in: Inputs, pol: Policy, err_msg: *[]const u8) CompileError!Plan {
    const tight = pol.profile == .tight;
    const write_req = pol.write orelse .scope;
    const net_req = pol.net orelse (if (tight) NetMode.disable else .enable);

    var unenforced: CapSet = .initEmpty();
    // Unenforceable modes fall back to the safer choice: writes are denied
    // rather than persisted, and outbound leaves the network as it is.
    const write: WriteMode = switch (write_req) {
        .ephemeral => blk: {
            unenforced.insert(.@"fs.write.ephemeral");
            break :blk .none;
        },
        .overlay => blk: {
            unenforced.insert(.@"fs.write.overlay");
            break :blk .none;
        },
        else => write_req,
    };
    const net: NetMode = if (net_req == .outbound) blk: {
        unenforced.insert(.@"net.outbound");
        break :blk .enable;
    } else net_req;

    if (write_req == .none and pol.writable.len > 0) {
        err_msg.* = "--write=none conflicts with --writable";
        return error.Conflict;
    }

    const can_write = write == .scope;
    const cwd_rw = can_write and (pol.cwd_writable orelse !tight);
    const tmp_rw = can_write and !tight;

    var rules: std.ArrayList(Rule) = .empty;
    var binds: std.ArrayList(Bind) = .empty;
    var caveats: std.ArrayList([]const u8) = .empty;

    const acc = struct {
        fn of(rw: bool) Access {
            return if (rw) .rw else .ro;
        }
        fn rule(rw: bool) @TypeOf(@as(Rule, undefined).kind) {
            return if (rw) .allow_rw else .allow_ro;
        }
    };

    // Writable paths inside the root make the root's top a creatable mount.
    var root_rw = false;
    if (in.root) |root| {
        for (pol.writable) |w| if (std.mem.eql(u8, w, root)) {
            root_rw = can_write;
        };
        try rules.append(arena, .{ .path = root, .kind = acc.rule(root_rw) });
        try binds.append(arena, .{
            .from = try std.fmt.allocPrint(arena, "#U{s}", .{root}),
            .to = "/",
            .create = root_rw,
            .access = acc.of(root_rw),
        });
    }

    try binds.append(arena, .{ .from = "#c", .to = "/dev", .optional = true });
    try binds.append(arena, .{ .from = "#y", .to = "/dev", .flag = .before, .console = true });
    try binds.append(arena, .{ .from = "#e", .to = "/env", .create = true, .optional = true });
    try binds.append(arena, .{ .from = "#d", .to = "/fd", .optional = true });
    try binds.append(arena, .{ .from = "#p", .to = "/proc", .optional = true });
    if (net != .disable) try binds.append(arena, .{ .from = "#I", .to = "/net", .optional = true });
    if (in.root != null) {
        try binds.append(arena, .{ .from = try std.fmt.allocPrint(arena, "/{t}/bin", .{in.arch}), .to = "/bin", .optional = true });
        try binds.append(arena, .{ .from = "/rc/bin", .to = "/bin", .flag = .after, .optional = true });
    }

    // The host temp dir (design/ephemeral-writes.md proposes a ramfs); the tight profile leaves the
    // root's read-only /tmp instead.
    if (in.root != null and tmp_rw) if (pol.tmp) |tmp| {
        try rules.append(arena, .{ .path = tmp, .kind = .allow_rw });
        try binds.append(arena, .{
            .from = try std.fmt.allocPrint(arena, "#U{s}", .{tmp}),
            .to = "/tmp",
            .create = true,
            .access = .rw,
            .optional = true,
        });
    };

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
    if (in.root != null and need_mnt_term) {
        try binds.append(arena, .{ .from = "#U/", .to = "/mnt/term", .flag = .after, .access = if (pol.host_fs) .ro else null });
    }

    var guest_cwd: ?[]const u8 = null;
    if (in.cwd) |cwd| {
        try rules.append(arena, .{ .path = cwd, .kind = acc.rule(cwd_rw) });
        if (in.root != null) {
            try binds.append(arena, .{
                .from = try std.fmt.allocPrint(arena, "#U{s}", .{cwd}),
                .to = "/mnt/term/cwd",
                .fallback = "/mnt/term",
                .create = cwd_rw,
                .access = acc.of(cwd_rw),
            });
            guest_cwd = "/mnt/term/cwd";
        }
    }

    for ([_][]const []const u8{ pol.readable, pol.writable }, [_]bool{ false, true }) |list, want_rw| for (list) |p| {
        const rw = want_rw and can_write;
        try rules.append(arena, .{ .path = p, .kind = acc.rule(rw) });
        if (in.root == null) continue;
        const to: []const u8 = switch (guestPlace(in, p)) {
            .root_top, .cwd_top => continue,
            .root => |rel| try std.fmt.allocPrint(arena, "/{s}", .{rel}),
            .cwd => |rel| try std.fmt.allocPrint(arena, "/mnt/term/cwd/{s}", .{rel}),
            .mnt_term => try std.fmt.allocPrint(arena, "/mnt/term{s}", .{p}),
        };
        try binds.append(arena, .{
            .from = try std.fmt.allocPrint(arena, "#U{s}", .{p}),
            .to = to,
            .create = rw,
            .access = acc.of(rw),
        });
    };

    for (pol.read_deny) |p| try rules.append(arena, .{ .path = p, .kind = .deny });

    var devmask: std.ArrayList(u8) = .empty;
    if (!pol.host_cmd) try devmask.append(arena, 'C');
    if (net == .disable) try devmask.append(arena, 'I');
    if (!pol.host_fs) try devmask.append(arena, 'U');

    var enforces: CapSet = .initMany(&.{ .@"env.scrub", .@"ipc.restrict", .@"kernel.isolation", .@"fs.write.scope" });
    if (!pol.host_fs) enforces.insert(.@"fs.read.scope");
    if (pol.read_deny.len > 0) enforces.insert(.@"fs.read.deny");
    if (net == .disable) enforces.insert(.@"net.disable");
    if (pol.memory != null) enforces.insert(.@"res.memory");
    if (pol.pids != null) enforces.insert(.@"res.pids");
    if (pol.cpus != null) enforces.insert(.@"res.cpu");
    const timeout = pol.timeout_ns orelse (if (tight) tight_timeout_ns else null);
    if (timeout != null) enforces.insert(.@"proc.timeout");

    var any_rw = false;
    for (rules.items) |r| if (r.kind == .allow_rw) {
        any_rw = true;
    };
    if (any_rw) {
        try caveats.append(arena, "hardlinks under writable paths can modify host files outside them");
        try caveats.append(arena, "writes to writable paths are not capped (no res.disk)");
    }
    try caveats.append(arena, "paths are checked after resolving symlinks, so a host process renaming paths concurrently can race the check");
    if (net != .disable) try caveats.append(arena, "the network is not restricted beyond --net=disable");
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
        .devmask = devmask.items,
        .binds = binds.items,
        .rules = rules.items,
        .enforces = enforces,
        .unenforced = unenforced,
        .caveats = caveats.items,
        .guest_cwd = guest_cwd,
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
    if (best) |r| return if (mutates and r.kind == .allow_ro) .read_only else .allow;
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
    try t.expectEqualStrings("CU", d.devmask);
    try t.expect(!d.enforces.contains(.@"net.disable"));
    try t.expectEqual(@as(?u64, null), d.timeout_ns);

    const tt = try compile(arena.allocator(), in, .{ .profile = .tight }, &msg);
    try t.expectEqual(Verdict.read_only, tt.check("/w/f", .create));
    try t.expectEqualStrings("CIU", tt.devmask);
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

test "compile: unenforceable modes fall back and are reported" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var msg: []const u8 = "";
    const in: Inputs = .{ .root = "/r", .cwd = "/w", .arch = .arm64 };
    const p = try compile(arena.allocator(), in, .{ .write = .overlay, .net = .outbound }, &msg);
    try t.expect(p.unenforced.contains(.@"fs.write.overlay"));
    try t.expect(p.unenforced.contains(.@"net.outbound"));
    try t.expectEqual(WriteMode.none, p.write);
    try t.expectEqual(Verdict.read_only, p.check("/w/f", .create));
    try t.expectError(error.Conflict, compile(arena.allocator(), in, .{ .write = .none, .writable = &.{"/w"} }, &msg));
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
