//! The leaves devdotl.c (`#ℓ`, design/epoch-0/dotl.md) calls the translator
//! through: each takes and returns bytes and never raises, returning -1
//! with the error in the caller's ERRMAX buffer. devdotl.c holds a lock
//! per translator around every call.
//!
//! Each machine's user map is registered here by the machine, keyed by
//! its kernel `Hmach`, as hstream.zig keys streams.

const std = @import("std");
const builtin = @import("builtin");
const client = @import("client.zig");
const server = @import("server.zig");
const attr = @import("attr.zig");
const web = @import("../web.zig");
const kern = @import("../kern.zig");

const gpa = web.gpa;
const ERRMAX = 128;

/// What a machine's translators are made with.
pub const Config = struct {
    /// The machine's user name.
    user: []const u8,
    /// The `--user-map` file's contents, if any.
    user_map: ?[]const u8 = null,
    /// For the op_ids' random seeds.
    io: ?std.Io = null,
};

const Entry = struct { owner: usize, cfg: Config };

var mutex: std.atomic.Mutex = .unlocked;
var configs: [64]?Entry = @splat(null);

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

pub fn unregister(owner: usize) void {
    lock();
    defer mutex.unlock();
    for (&configs) |*e| if (e.* != null and e.*.?.owner == owner) {
        e.* = null;
    };
}

fn configFor(owner: usize) ?Config {
    lock();
    defer mutex.unlock();
    for (configs) |e| if (e != null and e.?.owner == owner) return e.?.cfg;
    return null;
}

/// The host uid sent for the machine's user, by UserMap.hostUid's rule.
fn hostUid() u32 {
    if (builtin.os.tag == .windows or web.enabled or !builtin.link_libc) return attr.UserMap.hostUid(null);
    return attr.UserMap.hostUid(std.c.getuid());
}

fn putErr(err: [*]u8, msg: []const u8) void {
    const n = @min(msg.len, ERRMAX - 1);
    @memcpy(err[0..n], msg[0..n]);
    err[n] = 0;
}

/// A conversation's translator: the client side, for a mount, or the
/// server side, between a `--serve` client and its exportfs. devdotl.c
/// calls the side next to devmnt or exportfs the "mount" side, and the
/// network connection the "server" side, either way.
const Tr = struct {
    side: union(enum) {
        client: client.Client,
        server: server.Server,
    },
    /// The server's name for the client, from a WebSocket handshake's
    /// 9P-User (design/credential-helpers.md), which the user map holds.
    ident: [32]u8 = undefined,
};

fn secondsNow() u32 {
    if (web.enabled or !builtin.link_libc) return 0;
    if (builtin.os.tag == .windows) {
        // 100ns ticks since 1601; Windows' C library has no clock_gettime.
        const ticks = std.os.windows.ntdll.RtlGetSystemTimePrecise();
        const secs = @divFloor(ticks, 10_000_000) - 11_644_473_600;
        return @intCast(@max(0, @min(secs, std.math.maxInt(u32))));
    }
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return @intCast(@max(0, @min(ts.sec, std.math.maxInt(u32))));
}

/// `mode` is 0 for a client offering 9P2000.L, 1 for one offering
/// 9P2000.L.Z, and 2 for the server side. `uid` and `user` are the
/// server's identity for the client, from a WebSocket handshake's 9P-Uid
/// and 9P-User (design/credential-helpers.md), or -1 and null: without a
/// `--user-map`, the map then takes them as the machine's user.
fn h9_dotl_new(mach: ?*anyopaque, mode: c_int, uid: c_long, user: ?[*:0]const u8, err: [*]u8) callconv(.c) ?*Tr {
    const cfg = configFor(@intFromPtr(mach)) orelse Config{ .user = "none" };
    const t = gpa.create(Tr) catch {
        putErr(err, "out of memory");
        return null;
    };
    t.* = .{ .side = undefined };
    var users: attr.UserMap = .{ .passwd = cfg.user_map, .user = cfg.user, .uid = hostUid() };
    if (cfg.user_map == null and uid >= 0 and uid <= std.math.maxInt(u32)) if (user) |u| {
        const name = std.mem.span(u);
        if (name.len > 0 and name.len <= t.ident.len) {
            @memcpy(t.ident[0..name.len], name);
            users.user = t.ident[0..name.len];
            users.uid = @intCast(uid);
        }
    };
    if (mode == 2) {
        t.side = .{ .server = server.Server.init(gpa, .{ .users = users, .now = secondsNow }) };
        return t;
    }
    var seed: [8]u8 = undefined;
    if (cfg.io) |io| io.random(&seed) else std.mem.writeInt(u64, &seed, @intFromPtr(mach) ^ @as(u64, @truncate(@intFromPtr(&seed))), .little);
    t.side = .{ .client = client.Client.init(gpa, .{
        .users = users,
        .offer_lz = mode == 1,
        .op_seed = std.mem.readInt(u64, &seed, .little),
    }) catch {
        gpa.destroy(t);
        putErr(err, "out of memory");
        return null;
    } };
    return t;
}

fn h9_dotl_free(t: *Tr) callconv(.c) void {
    switch (t.side) {
        inline else => |*x| x.deinit(),
    }
    gpa.destroy(t);
}

/// `linkwalk` is whether the writer is a Linux process, whose walks stop
/// at links (design/linux-symlinks.md).
fn h9_dotl_frommount(t: *Tr, buf: [*]const u8, n: c_long, linkwalk: c_int, err: [*]u8) callconv(.c) c_int {
    const b = buf[0..@intCast(n)];
    (switch (t.side) {
        .client => |*c| blk: {
            c.linkwalk = linkwalk != 0;
            break :blk c.fromMount(b);
        },
        .server => |*s| s.fromExport(b),
    }) catch {
        putErr(err, "out of memory");
        return -1;
    };
    return 0;
}

fn h9_dotl_fromserver(t: *Tr, buf: [*]const u8, n: c_long, err: [*]u8) callconv(.c) c_int {
    const b = buf[0..@intCast(n)];
    (switch (t.side) {
        .client => |*c| c.fromServer(b),
        .server => |*s| s.fromClient(b),
    }) catch {
        putErr(err, "out of memory");
        return -1;
    };
    return 0;
}

fn h9_dotl_takeserver(t: *Tr, buf: [*]u8, n: c_long) callconv(.c) c_long {
    const b = switch (t.side) {
        .client => |*c| c.toServer(),
        .server => |*s| s.toClient(),
    };
    const k = @min(b.len, @as(usize, @intCast(n)));
    @memcpy(buf[0..k], b[0..k]);
    switch (t.side) {
        .client => |*c| c.consumedServer(k),
        .server => |*s| s.consumedClient(k),
    }
    return @intCast(k);
}

fn mountBytes(t: *Tr) []const u8 {
    return switch (t.side) {
        .client => |*c| c.toMount(),
        .server => |*s| s.toExport(),
    };
}

fn h9_dotl_takemount(t: *Tr, buf: [*]u8, n: c_long) callconv(.c) c_long {
    const b = mountBytes(t);
    const k = @min(b.len, @as(usize, @intCast(n)));
    @memcpy(buf[0..k], b[0..k]);
    switch (t.side) {
        .client => |*c| c.consumedMount(k),
        .server => |*s| s.consumedExport(k),
    }
    return @intCast(k);
}

fn h9_dotl_mountready(t: *Tr) callconv(.c) c_int {
    return @intFromBool(mountBytes(t).len != 0);
}

fn h9_dotl_status(t: *Tr, buf: [*]u8, n: c_int) callconv(.c) c_int {
    const out = buf[0..@intCast(n)];
    const s = switch (t.side) {
        .client => |*c| switch (c.version()) {
            .failed => std.fmt.bufPrint(out, "Hungup {s}", .{c.err orelse ""}),
            else => |v| if (c.reconnects != 0 or c.reconnecting)
                std.fmt.bufPrint(out, "{t} reconnects {d}{s}", .{ v, c.reconnects, if (c.reconnecting) " reconnecting" else "" })
            else
                std.fmt.bufPrint(out, "{t}", .{v}),
        },
        .server => |*sv| switch (sv.version()) {
            .failed => std.fmt.bufPrint(out, "Hungup {s}", .{sv.err orelse ""}),
            else => |v| std.fmt.bufPrint(out, "serving {t}", .{v}),
        },
    } catch out;
    return @intCast(s.len);
}

/// Whether a dropped connection can be resumed (9P2000.L.Z).
fn h9_dotl_canreconnect(t: *Tr) callconv(.c) c_int {
    return switch (t.side) {
        .client => |*c| @intFromBool(c.canReconnect()),
        .server => 0,
    };
}

/// Whether the server asked to be dropped (ENOTLEADER).
fn h9_dotl_wantreconnect(t: *Tr) callconv(.c) c_int {
    return switch (t.side) {
        .client => |*c| @intFromBool(c.want_reconnect),
        .server => 0,
    };
}

/// Resumes on a new connection; what to send is in takeserver.
fn h9_dotl_reconnect(t: *Tr, err: [*]u8) callconv(.c) c_int {
    switch (t.side) {
        .client => |*c| c.reconnect() catch {
            putErr(err, "out of memory");
            return -1;
        },
        .server => {
            putErr(err, "a served connection can't reconnect");
            return -1;
        },
    }
    return 0;
}

comptime {
    if (kern.available) {
        @export(&h9_dotl_new, .{ .name = "h9_dotl_new" });
        @export(&h9_dotl_free, .{ .name = "h9_dotl_free" });
        @export(&h9_dotl_frommount, .{ .name = "h9_dotl_frommount" });
        @export(&h9_dotl_fromserver, .{ .name = "h9_dotl_fromserver" });
        @export(&h9_dotl_takeserver, .{ .name = "h9_dotl_takeserver" });
        @export(&h9_dotl_takemount, .{ .name = "h9_dotl_takemount" });
        @export(&h9_dotl_mountready, .{ .name = "h9_dotl_mountready" });
        @export(&h9_dotl_status, .{ .name = "h9_dotl_status" });
        @export(&h9_dotl_canreconnect, .{ .name = "h9_dotl_canreconnect" });
        @export(&h9_dotl_wantreconnect, .{ .name = "h9_dotl_wantreconnect" });
        @export(&h9_dotl_reconnect, .{ .name = "h9_dotl_reconnect" });
    }
}
