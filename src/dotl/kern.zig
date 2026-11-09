//! The leaves devdotl.c (`#ℓ`, design/0022-dotl.md) calls the translator
//! through: each takes and returns bytes and never raises, returning -1
//! with the error in the caller's ERRMAX buffer. devdotl.c holds a lock
//! per translator around every call.
//!
//! Each machine's user map is registered here by the machine, keyed by
//! its kernel `Hmach`, as hstream.zig keys streams.

const std = @import("std");
const builtin = @import("builtin");
const client = @import("client.zig");
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

fn h9_dotl_new(mach: ?*anyopaque, lz: c_int, err: [*]u8) callconv(.c) ?*client.Client {
    const cfg = configFor(@intFromPtr(mach)) orelse Config{ .user = "none" };
    var seed: [8]u8 = undefined;
    if (cfg.io) |io| io.random(&seed) else std.mem.writeInt(u64, &seed, @intFromPtr(mach) ^ @as(u64, @truncate(@intFromPtr(&seed))), .little);
    const t = gpa.create(client.Client) catch {
        putErr(err, "out of memory");
        return null;
    };
    t.* = client.Client.init(gpa, .{
        .users = .{ .passwd = cfg.user_map, .user = cfg.user, .uid = hostUid() },
        .offer_lz = lz != 0,
        .op_seed = std.mem.readInt(u64, &seed, .little),
    }) catch {
        gpa.destroy(t);
        putErr(err, "out of memory");
        return null;
    };
    return t;
}

fn h9_dotl_free(t: *client.Client) callconv(.c) void {
    t.deinit();
    gpa.destroy(t);
}

fn h9_dotl_frommount(t: *client.Client, buf: [*]const u8, n: c_long, err: [*]u8) callconv(.c) c_int {
    t.fromMount(buf[0..@intCast(n)]) catch {
        putErr(err, "out of memory");
        return -1;
    };
    return 0;
}

fn h9_dotl_fromserver(t: *client.Client, buf: [*]const u8, n: c_long, err: [*]u8) callconv(.c) c_int {
    t.fromServer(buf[0..@intCast(n)]) catch {
        putErr(err, "out of memory");
        return -1;
    };
    return 0;
}

fn h9_dotl_takeserver(t: *client.Client, buf: [*]u8, n: c_long) callconv(.c) c_long {
    const b = t.toServer();
    const k = @min(b.len, @as(usize, @intCast(n)));
    @memcpy(buf[0..k], b[0..k]);
    t.consumedServer(k);
    return @intCast(k);
}

fn h9_dotl_takemount(t: *client.Client, buf: [*]u8, n: c_long) callconv(.c) c_long {
    const b = t.toMount();
    const k = @min(b.len, @as(usize, @intCast(n)));
    @memcpy(buf[0..k], b[0..k]);
    t.consumedMount(k);
    return @intCast(k);
}

fn h9_dotl_mountready(t: *client.Client) callconv(.c) c_int {
    return @intFromBool(t.toMount().len != 0);
}

fn h9_dotl_status(t: *client.Client, buf: [*]u8, n: c_int) callconv(.c) c_int {
    const out = buf[0..@intCast(n)];
    const s = switch (t.version()) {
        .failed => std.fmt.bufPrint(out, "Hungup {s}", .{t.err orelse ""}),
        else => |v| if (t.reconnects != 0 or t.reconnecting)
            std.fmt.bufPrint(out, "{t} reconnects {d}{s}", .{ v, t.reconnects, if (t.reconnecting) " reconnecting" else "" })
        else
            std.fmt.bufPrint(out, "{t}", .{v}),
    } catch out;
    return @intCast(s.len);
}

/// Whether a dropped connection can be resumed (9P2000.L.Z).
fn h9_dotl_canreconnect(t: *client.Client) callconv(.c) c_int {
    return @intFromBool(t.canReconnect());
}

/// Whether the server asked to be dropped (ENOTLEADER).
fn h9_dotl_wantreconnect(t: *client.Client) callconv(.c) c_int {
    return @intFromBool(t.want_reconnect);
}

/// Resumes on a new connection; what to send is in takeserver.
fn h9_dotl_reconnect(t: *client.Client, err: [*]u8) callconv(.c) c_int {
    t.reconnect() catch {
        putErr(err, "out of memory");
        return -1;
    };
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
