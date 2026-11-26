//! The host a compiled plan describes (design/host-handles.md, "The
//! policy compiles to handles"). Its directory handles are the trees the
//! plan allows, opened beneath (src/host/dirs.zig); they and the network
//! handles also ask the plan, as devfs's `h9_policy_check` and devip's
//! `h9_net_check` do; its sockets are the host's (src/host/net.zig); the
//! clock is the OS's, entropy the machine's `std.Io`, and the window the
//! GUI backend's claim.

const std = @import("std");
const policy = @import("../policy.zig");
const kern = @import("../kern.zig");
const gfx = @import("../gfx.zig");
const host = @import("host.zig");
const dirs = @import("dirs.zig");
const net = @import("net.zig");

const Host = host.Host;

pub const Extra = struct {
    /// The run's terminal, which the plan doesn't hold.
    console: ?host.Console = null,
    /// The screen asked for; with the plan's `gfx`, the window.
    gfx: ?gfx.Options = null,
    /// Open each directory handle (src/host/dirs.zig), as a machine's
    /// host does; `closeDirs` closes them. A host that's only described,
    /// as a test's or `--print`'s, leaves them unopened.
    open_dirs: bool = false,
};

/// Builds the host `plan` describes. `plan` and what's allocated in
/// `arena` must outlive the host; the plan isn't changed after it's
/// compiled, and the handles only read it (the resolved-name table it
/// points to is its own, and locked).
pub fn fromPlan(arena: std.mem.Allocator, io: std.Io, plan: *const policy.Plan, extra: Extra) error{OutOfMemory}!Host {
    const ctx: *anyopaque = @constCast(plan);
    const rnd = try arena.create(std.Io);
    rnd.* = io;
    return .{
        .dirs = .{ .list = try dirsOf(arena, plan, extra.open_dirs), .ctx = ctx, .vtable = &dirs_vt },
        // `--net=disable` is no dial and no listen. Under outbound the
        // listener is there and refuses every guest address, as devip
        // does now: h9's own loopback listeners, such as the machine's
        // resolver (design/linux-dns.md), are opened through it.
        .dial = if (plan.net == .disable) null else .{ .ctx = ctx, .vtable = &dial_vt },
        .listen = if (plan.net == .disable) null else .{ .ctx = ctx, .vtable = &listen_vt },
        .clock = .{ .vtable = &clock_vt },
        .console = extra.console,
        .random = .{ .ctx = rnd, .vtable = &random_vt },
        .window = if (plan.gfx != null) if (extra.gfx) |g| .{ .options = g, .vtable = &window_vt } else null else null,
        // `#C` is masked in every plan while design/host-cmd.md is built.
        .spawn = null,
    };
}

fn planOf(ctx: *anyopaque) *const policy.Plan {
    return @ptrCast(@alignCast(ctx));
}

const dirs_vt: host.Dirs.VTable = .{ .check = dirsCheck };

fn dirsCheck(ctx: *anyopaque, path: []const u8, op: policy.Op) policy.Verdict {
    return planOf(ctx).check(path, op);
}

const dial_vt: host.Dial.VTable = .{ .allows = dialAllows, .lookup = dialLookup, .resolved = dialResolved, .probe = dialProbe, .connect = dialConnect };

fn dialAllows(ctx: *anyopaque, proto: ?policy.NetProto, addr: *const [16]u8, port: u16) bool {
    return planOf(ctx).netCheck(.connect, proto, addr, port);
}

fn dialLookup(ctx: *anyopaque, proto: ?policy.NetProto, name: []const u8, port: u16) bool {
    return planOf(ctx).netLookup(proto, name, port);
}

fn dialResolved(ctx: *anyopaque, proto: ?policy.NetProto, name: []const u8, port: u16, addrs: []const [16]u8) void {
    planOf(ctx).netResolved(proto, name, port, addrs);
}

fn dialProbe(ctx: *anyopaque, proto: ?policy.NetProto, addr: *const [16]u8) bool {
    return planOf(ctx).netProbe(proto, addr);
}

fn dialConnect(_: *anyopaque, kind: net.Transport, addr: *const [16]u8, port: u16, until: i64) ?net.Fd {
    if (comptime !net.supported) return null;
    return net.dial(kind, addr, port, until);
}

const listen_vt: host.Listen.VTable = .{ .allows = listenAllows, .bind = listenBind };

fn listenBind(_: *anyopaque, kind: net.Transport, addr: *const [16]u8, port: u16) ?net.Listener {
    if (comptime !net.supported) return null;
    return net.listen(kind, addr, port);
}

fn listenAllows(ctx: *anyopaque, proto: ?policy.NetProto, addr: *const [16]u8, port: u16) bool {
    return planOf(ctx).netCheck(.announce, proto, addr, port);
}

const clock_vt: host.Clock.VTable = .{ .wall = clockWall, .mono = clockMono };

fn clockWall(_: ?*anyopaque) i64 {
    return kern.osWallNs();
}

fn clockMono(_: ?*anyopaque) i64 {
    return kern.osMonoNs();
}

const random_vt: host.Random.VTable = .{ .fill = randomFill };

fn randomFill(ctx: *anyopaque, buf: []u8) void {
    const io: *const std.Io = @ptrCast(@alignCast(ctx));
    io.random(buf);
}

const window_vt: host.Window.VTable = .{ .acquire = windowAcquire, .release = windowRelease };

fn windowAcquire(_: ?*anyopaque, io: std.Io, claim: *const gfx.Claim, opts: gfx.Options) gfx.Error!void {
    return gfx.acquire(io, claim, opts);
}

fn windowRelease(_: ?*anyopaque, claim: *const gfx.Claim) void {
    gfx.release(claim);
}

/// The plan's directory handles: one per host tree it allows, named as
/// design/host-handles.md says. `root` is the first host directory on
/// the root stack and `cwd` the host cwd; a path that's both has both
/// names. Each other path an allow rule names is `d1`, `d2`, and so on,
/// in rule order, once.
fn dirsOf(arena: std.mem.Allocator, plan: *const policy.Plan, open: bool) error{OutOfMemory}![]const host.Dir {
    var list: std.ArrayList(host.Dir) = .empty;
    if (rootPath(plan)) |p| try list.append(arena, try dirOf(arena, plan, "root", p));
    if (cwdPath(plan)) |p| try list.append(arena, try dirOf(arena, plan, "cwd", p));
    var n: usize = 0;
    rules: for (plan.rules) |r| {
        if (r.kind == .deny) continue;
        for (list.items) |d| if (std.mem.eql(u8, d.path, r.path)) continue :rules;
        n += 1;
        try list.append(arena, try dirOf(arena, plan, try std.fmt.allocPrint(arena, "d{d}", .{n}), r.path));
    }
    if (open) for (list.items, 0..) |*d, i| {
        // A path that's both the root and the cwd shares one handle.
        const same: ?host.Dir = for (list.items[0..i]) |e| {
            if (std.mem.eql(u8, e.path, d.path)) break e;
        } else null;
        if (same) |e| {
            d.handle = e.handle;
            d.leaf = e.leaf;
        } else if (dirs.openTree(arena, d.path)) |o| {
            d.handle = o.handle;
            d.leaf = o.leaf;
        }
    };
    return list.items;
}

/// Closes the directory handles `fromPlan` opened.
pub fn closeDirs(h: Host) void {
    const d = h.dirs orelse return;
    for (d.list, 0..) |x, i| {
        const shared = for (d.list[0..i]) |e| {
            if (e.handle == x.handle) break true;
        } else false;
        if (!shared) dirs.closeTree(x.handle);
    }
}

fn dirOf(arena: std.mem.Allocator, plan: *const policy.Plan, name: []const u8, path: []const u8) error{OutOfMemory}!host.Dir {
    var deny: std.ArrayList([]const u8) = .empty;
    for (plan.rules) |r| if (r.kind == .deny) if (policy.relUnder(path, r.path)) |rel| {
        try deny.append(arena, rel);
    };
    return .{
        .name = name,
        .path = path,
        // The plan's own verdict at the tree's top: the longest allow
        // rule there, with ties to the first, as devfs decides.
        .writable = plan.check(path, .write) == .allow,
        .contained = isContained(plan, path),
        .deny = deny.items,
    };
}

/// The host path in a bind's `#U` source, without `!c`.
fn hostPathOf(b: policy.Bind) ?[]const u8 {
    if (b.lower) |l| return l;
    if (std.mem.startsWith(u8, b.from, "#U!c")) return b.from[4..];
    if (std.mem.startsWith(u8, b.from, "#U")) return b.from[2..];
    return null;
}

fn rootPath(plan: *const policy.Plan) ?[]const u8 {
    for (plan.binds) |b| if (std.mem.eql(u8, b.to, policy.mount.Stack.root.dev())) if (hostPathOf(b)) |p| return p;
    return null;
}

fn cwdPath(plan: *const policy.Plan) ?[]const u8 {
    const to = plan.guest_cwd orelse return null;
    for (plan.binds) |b| if (std.mem.eql(u8, b.to, to)) if (hostPathOf(b)) |p| return p;
    return null;
}

fn isContained(plan: *const policy.Plan, path: []const u8) bool {
    for (plan.binds) |b| if (hostPathOf(b)) |p| if (std.mem.eql(u8, p, path)) {
        if (b.contained or std.mem.startsWith(u8, b.from, "#U!c")) return true;
    };
    return false;
}

const t = std.testing;

fn compileFor(arena: std.mem.Allocator, mounts: []const policy.mount.Mount, cwd: ?[]const u8, pol: policy.Policy) !policy.Plan {
    var msg: []const u8 = "";
    return policy.compile(arena, .{ .mounts = mounts, .cwd = cwd, .arch = .amd64 }, pol, &msg);
}

test "a plan's host trees are named handles: root, cwd, and d1 on [host-handles]" {
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const mounts = [_]policy.mount.Mount{.{ .kind = .dir, .src = "/r" }};
    const plan = try compileFor(a, &mounts, "/home/me/proj", .{
        .readable = &.{"/data"},
        .writable = &.{"/home/me/proj/out"},
        .read_deny = &.{ "/home/me/proj/.env", "/elsewhere" },
    });
    const h = try fromPlan(a, t.io, &plan, .{});
    const d = h.dirs.?;
    try t.expectEqual(@as(usize, 4), d.list.len);
    const want = [_]struct { []const u8, []const u8, bool }{
        .{ "root", "/r", false },
        .{ "cwd", "/home/me/proj", true },
        .{ "d1", "/data", false },
        .{ "d2", "/home/me/proj/out", true },
    };
    for (want, d.list) |w, got| {
        try t.expectEqualStrings(w[0], got.name);
        try t.expectEqualStrings(w[1], got.path);
        try t.expectEqual(w[2], got.writable);
    }
    try t.expectEqual(@as(usize, 1), d.get("cwd").?.deny.len);
    try t.expectEqualStrings(".env", d.get("cwd").?.deny[0]);
    try t.expectEqual(@as(usize, 0), d.get("root").?.deny.len);
    const held = d.holding("/home/me/proj/out/x.o").?;
    try t.expectEqualStrings("d2", held.dir.name);
    try t.expectEqualStrings("x.o", held.rel);
    try t.expect(d.holding("/etc/passwd") == null);
}

test "a host built from a plan gives the plan's verdicts [host-handles]" {
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const mounts = [_]policy.mount.Mount{.{ .kind = .dir, .src = "/r" }};
    const plan = try compileFor(a, &mounts, "/c", .{ .writable = &.{"/w"}, .read_deny = &.{"/c/secret"}, .net_allow = &.{"tcp!10.0.0.0/8!564"} });
    const h = try fromPlan(a, t.io, &plan, .{});
    const paths = [_][]const u8{ "/", "/r", "/r/x", "/c", "/c/secret", "/c/secret/k", "/w", "/w/y", "/etc", "/c/../w" };
    for (paths) |p| for (std.enums.values(policy.Op)) |op| {
        try t.expectEqual(plan.check(p, op), h.dirs.?.check(p, op));
    };
    const addrs = [_][]const u8{ "10.1.2.3", "192.168.0.1", "169.254.169.254", "::1" };
    for (addrs) |s| {
        const ip = policy.parseIp(s).?;
        for ([_]?policy.NetProto{ .tcp, .udp, null }) |pr| for ([_]u16{ 564, 80 }) |port| {
            try t.expectEqual(plan.netCheck(.connect, pr, &ip, port), h.dial.?.allows(pr, &ip, port));
            try t.expectEqual(plan.netCheck(.announce, pr, &ip, port), h.listen.?.allows(pr, &ip, port));
        };
    }
    try t.expectEqual(plan.netLookup(.tcp, "example.com", 564), h.dial.?.lookup(.tcp, "example.com", 564));
}

test "--net=disable is no dial and no listen, and no window without --gfx [host-handles]" {
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const tight = try compileFor(a, &.{}, "/c", .{ .profile = .tight });
    const h = try fromPlan(a, t.io, &tight, .{ .gfx = .{} });
    try t.expect(h.dial == null and h.listen == null);
    try t.expect(h.window == null);
    try t.expect(h.spawn == null);
    try t.expect(h.clock != null and h.random != null);
    // The tight profile's cwd is read-only; with nothing on / there's no
    // root handle.
    try t.expectEqual(@as(usize, 1), h.dirs.?.list.len);
    try t.expectEqualStrings("cwd", h.dirs.?.list[0].name);
    try t.expect(!h.dirs.?.list[0].writable);
}

test "the outbound listener refuses every guest address [host-handles]" {
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const plan = try compileFor(a, &.{}, null, .{});
    try t.expectEqual(policy.NetMode.outbound, plan.net);
    const h = try fromPlan(a, t.io, &plan, .{});
    const lo = policy.parseIp("127.0.0.1").?;
    try t.expect(!h.listen.?.allows(.tcp, &lo, 8080));
    try t.expect(h.dial.?.allows(.tcp, &lo, 8080));
}

test "a contained --dir is a contained handle, and the clock is the kernel's [host-handles]" {
    var ar: std.heap.ArenaAllocator = .init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const mounts = [_]policy.mount.Mount{.{ .kind = .dir, .src = "/r", .contained = true }};
    const plan = try compileFor(a, &mounts, null, .{});
    const h = try fromPlan(a, t.io, &plan, .{});
    try t.expect(h.dirs.?.get("root").?.contained);
    const before = kern.monoNs();
    const m = h.clock.?.mono();
    try t.expect(m >= before and kern.monoNs() >= m);
    var buf: [32]u8 = @splat(0);
    h.random.?.fill(&buf);
    try t.expect(!std.mem.allEqual(u8, &buf, 0));
}
