//! The leaves `#ι` (src/kern/devhidx.c, design/mount-index.md) calls the
//! index layer through: each takes and returns bytes and never raises,
//! returning -1 with the error in the caller's ERRMAX buffer. devhidx.c
//! holds a lock per layer around every call.
//!
//! Each machine registers its cache directory here, keyed by its kernel
//! `Hmach`, as dotl/kern.zig keys user maps, and hands over the compiled
//! indexes it read for `--root-index` with `give`, which a conversation
//! then takes by number.

const std = @import("std");
const builtin = @import("builtin");
const web = @import("../web.zig");
const kern = @import("../kern.zig");
const ri = @import("../rootindex.zig");
const layer = ri.layer;
const Cache = ri.cache.Cache;

const gpa = web.gpa;
/// What compiled indexes given to `give` are allocated with.
pub const allocator = gpa;
const ERRMAX = 128;

pub const Config = struct {
    /// The compiled indexes' directory, or null for none.
    cache_dir: ?[]const u8 = null,
    io: ?std.Io = null,
};

const Entry = struct { owner: usize, cfg: Config };
const Given = struct { owner: usize, id: u32, compiled: []u8, label: []u8 };

var mutex: std.atomic.Mutex = .unlocked;
var configs: [64]?Entry = @splat(null);
var given: std.ArrayList(Given) = .empty;
var next_id: u32 = 1;

fn lock() void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

/// Registers machine `owner`'s configuration until `unregister`. The
/// strings must outlive the registration.
pub fn register(owner: usize, cfg: Config) void {
    lock();
    defer mutex.unlock();
    for (&configs) |*e| if (e.* == null or e.*.?.owner == owner) {
        e.* = .{ .owner = owner, .cfg = cfg };
        return;
    };
}

/// Drops machine `owner`'s configuration and any index it gave and no
/// conversation took.
pub fn unregister(owner: usize) void {
    lock();
    defer mutex.unlock();
    for (&configs) |*e| if (e.* != null and e.*.?.owner == owner) {
        e.* = null;
    };
    var i: usize = 0;
    while (i < given.items.len) {
        if (given.items[i].owner == owner) {
            const g = given.swapRemove(i);
            gpa.free(g.compiled);
            gpa.free(g.label);
        } else i += 1;
    }
}

fn configFor(owner: usize) Config {
    lock();
    defer mutex.unlock();
    for (configs) |e| if (e != null and e.?.owner == owner) return e.?.cfg;
    return .{};
}

/// Hands a compiled index (allocated with web.gpa, which `#ι` then owns)
/// to machine `owner`'s next conversation that names the returned id.
pub fn give(owner: usize, compiled: []u8, label: []const u8) error{OutOfMemory}!u32 {
    const l = try gpa.dupe(u8, label);
    errdefer gpa.free(l);
    lock();
    defer mutex.unlock();
    const id = next_id;
    next_id += 1;
    try given.append(gpa, .{ .owner = owner, .id = id, .compiled = compiled, .label = l });
    return id;
}

fn take(owner: usize, id: u32) ?Given {
    lock();
    defer mutex.unlock();
    for (given.items, 0..) |g, i| if (g.owner == owner and g.id == id) return given.swapRemove(i);
    return null;
}

var clock_io: ?std.Io = null;

fn nowNs() u64 {
    const io = clock_io orelse return 0;
    return @intCast(@max(0, std.Io.Timestamp.now(io, .awake).nanoseconds));
}

/// A conversation's layer, and what it was made with.
const Conv = struct {
    l: layer.Layer,
    key: []u8,
    label: []u8,
    cache: ?Cache,
};

fn putErr(err: [*]u8, msg: []const u8) void {
    const n = @min(msg.len, ERRMAX - 1);
    @memcpy(err[0..n], msg[0..n]);
    err[n] = 0;
}

fn lookupHook(ctx: ?*anyopaque, key: []const u8, version: []const u8) ?[]u8 {
    const c: *Conv = @ptrCast(@alignCast(ctx.?));
    const cache = c.cache orelse return null;
    return cache.lookup(key, version);
}

fn storeHook(ctx: ?*anyopaque, key: []const u8, version: []const u8, compiled: []const u8) void {
    const c: *Conv = @ptrCast(@alignCast(ctx.?));
    const cache = c.cache orelse return;
    cache.store(key, version, compiled);
}

/// `mode` 0 passes through, 1 uses the server's /.h9index cached under
/// `arg`, and 2 the index machine `mach` gave as number `arg`.
fn h9_hidx_new(mach: ?*anyopaque, mode: c_int, arg: [*:0]const u8, err: [*]u8) callconv(.c) ?*Conv {
    const owner = @intFromPtr(mach);
    const cfg = configFor(owner);
    if (cfg.io) |io| clock_io = io;
    const c = gpa.create(Conv) catch {
        putErr(err, "out of memory");
        return null;
    };
    const a = std.mem.span(arg);
    c.* = .{ .l = undefined, .key = &.{}, .label = &.{}, .cache = null };
    if (cfg.cache_dir) |d| if (cfg.io) |io| {
        c.cache = .{ .gpa = gpa, .io = io, .dir = d };
    };
    const hooks: layer.Hooks = .{ .ctx = c, .lookup = lookupHook, .store = storeHook, .now_ns = nowNs };
    const source: layer.Source = switch (mode) {
        0 => .none,
        1 => blk: {
            c.key = gpa.dupe(u8, a) catch {
                gpa.destroy(c);
                putErr(err, "out of memory");
                return null;
            };
            break :blk .{ .server = .{ .key = c.key } };
        },
        else => blk: {
            const id = std.fmt.parseInt(u32, a, 10) catch 0;
            const g = take(owner, id) orelse {
                gpa.destroy(c);
                putErr(err, "no such index");
                return null;
            };
            c.label = g.label;
            break :blk .{ .given = .{ .compiled = g.compiled, .label = c.label } };
        },
    };
    c.l = .init(gpa, source, hooks);
    return c;
}

fn h9_hidx_free(c: *Conv) callconv(.c) void {
    c.l.deinit();
    gpa.free(c.key);
    gpa.free(c.label);
    gpa.destroy(c);
}

fn h9_hidx_frommount(c: *Conv, buf: [*]const u8, n: c_long, err: [*]u8) callconv(.c) c_int {
    c.l.fromMount(buf[0..@intCast(n)]) catch |e| {
        putErr(err, if (e == error.OutOfMemory) "out of memory" else c.l.err orelse "bad 9P message");
        return -1;
    };
    return 0;
}

fn h9_hidx_fromserver(c: *Conv, buf: [*]const u8, n: c_long, err: [*]u8) callconv(.c) c_int {
    c.l.fromServer(buf[0..@intCast(n)]) catch |e| {
        putErr(err, if (e == error.OutOfMemory) "out of memory" else c.l.err orelse "bad 9P message");
        return -1;
    };
    return 0;
}

fn h9_hidx_takeserver(c: *Conv, buf: [*]u8, n: c_long) callconv(.c) c_long {
    const b = c.l.toServer();
    const k = @min(b.len, @as(usize, @intCast(n)));
    @memcpy(buf[0..k], b[0..k]);
    c.l.consumedServer(k);
    return @intCast(k);
}

fn h9_hidx_takemount(c: *Conv, buf: [*]u8, n: c_long) callconv(.c) c_long {
    const b = c.l.toMount();
    const k = @min(b.len, @as(usize, @intCast(n)));
    @memcpy(buf[0..k], b[0..k]);
    c.l.consumedMount(k);
    return @intCast(k);
}

fn h9_hidx_mountready(c: *Conv) callconv(.c) c_int {
    return @intFromBool(c.l.toMount().len != 0);
}

fn h9_hidx_status(c: *Conv, buf: [*]u8, n: c_int) callconv(.c) c_int {
    var w: std.Io.Writer = .fixed(buf[0..@intCast(n)]);
    c.l.status(&w) catch {};
    return @intCast(w.buffered().len);
}

comptime {
    if (kern.available) {
        @export(&h9_hidx_new, .{ .name = "h9_hidx_new" });
        @export(&h9_hidx_free, .{ .name = "h9_hidx_free" });
        @export(&h9_hidx_frommount, .{ .name = "h9_hidx_frommount" });
        @export(&h9_hidx_fromserver, .{ .name = "h9_hidx_fromserver" });
        @export(&h9_hidx_takeserver, .{ .name = "h9_hidx_takeserver" });
        @export(&h9_hidx_takemount, .{ .name = "h9_hidx_takemount" });
        @export(&h9_hidx_mountready, .{ .name = "h9_hidx_mountready" });
        @export(&h9_hidx_status, .{ .name = "h9_hidx_status" });
    }
}
