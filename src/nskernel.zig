//! The namespace kernel (design/epoch-0/namespace-kernel.md): h9's kernel with
//! nothing for running programs, holding namespaces that `#N`
//! (src/kern/dev/ns.zig) makes and composes, served over 9P2000 by kserve
//! with each attach name a namespace's id.
//!
//! On the web host it's `h9ns.wasm`, whose `main` boots the kernel and
//! serves each port the page hands it (h9ns.js's `connect`). Natively it's
//! `libh9ns.a`, with the C API in `h9ns.h`.
//!
//! This file has the Zig leaves #N (src/kern/dev/ns.zig) calls: `h9_ns_ctl`, which runs a
//! ctl line's bind, mount, unmount or cd in the calling process's
//! namespace, and the dials its mounts make.

const std = @import("std");
const builtin = @import("builtin");
const kern = @import("kern.zig");
const hstream = @import("hstream.zig");
const newns = @import("newns.zig");
const web = @import("web.zig");
/// Host descriptors (fd! dials, h9ns_serve, h9ns_addfd) are POSIX's: not
/// on the web, or on Windows, where the namespace kernel builds only for
/// the kernel's own cases (zig build kern-test).
const nofds = web.enabled or builtin.os.tag == .windows;
const dotl = @import("dotl/kern.zig");

comptime {
    // #ℓ's and #ℏ's leaves.
    _ = dotl;
    _ = hstream;
    // The kernel's Zig (design/kernel-port.md), with the C functions of
    // the drawterm files it replaces.
    _ = @import("kern_port");
}

const gpa = web.gpa;
const ERRMAX = kern.ERRMAX;

/// For tests/nskernel.zig: the translator's 9P2000.L test server.
pub const DotlTestServer = @import("dotl/testserver.zig").Server;

extern fn h9_ns_init() c_int;
extern fn h9_ns_lookup(aname: [*:0]const u8) callconv(.c) ?*anyopaque;
extern fn h9_ns_dialed(ns: ?*anyopaque, dial: [*:0]const u8) void;
extern fn h9_ns_hostsrv(name: [*:0]const u8) c_int;
extern fn h9_ns_srvpost(ns: ?*anyopaque, name: [*:0]const u8, fd: c_int) c_int;
extern fn h9_ns_post(kind: c_int, arg: c_long, aname: [*:0]const u8) c_int;
extern fn h9_ns_next(kind: *c_int, arg: *c_long, aname: [*]u8, n: c_int) c_int;

/// What `h9_ns_post` hands the server.
const Post = enum(c_int) {
    /// A host stream that's ready to serve (hstream.Served.ready): its id.
    stream = 1,
    /// A host descriptor (`h9ns_serve`), which the kernel takes.
    fd = 2,
};

fn putErr(err: [*]u8, msg: []const u8) void {
    const n = @min(msg.len, ERRMAX - 1);
    @memcpy(err[0..n], msg[0..n]);
    err[n] = 0;
}

/// The kernel's messages (panic, pprint), on the host's standard error.
export fn h9_ns_log(buf: [*]const u8, n: c_int) c_int {
    if (n <= 0) return 0;
    if (comptime builtin.os.tag == .windows)
        _ = _write(2, buf, @intCast(n))
    else
        _ = std.c.write(2, buf, @intCast(n));
    return n;
}

/// The C runtime's write on Windows, where std.c.write takes a HANDLE.
extern "c" fn _write(fd: c_int, buf: [*]const u8, n: c_uint) c_int;

/// drawterm's win32.c asks src/host/hostsock-win32.c for a Winsock
/// error's text, and the namespace kernel has no host sockets: Windows's
/// own text it is.
fn h9so_errstr(e: c_int) callconv(.c) ?[*:0]const u8 {
    _ = e;
    return null;
}

comptime {
    if (builtin.os.tag == .windows) @export(&h9so_errstr, .{ .name = "h9so_errstr" });
}

// Mounts' dials.

/// The machine the namespace kernel's processes belong to, as hstream's
/// and dotl's owner key.
fn owner() usize {
    const mc = kern.mach() orelse return 0;
    const o = @intFromPtr(mc);
    mc.put();
    return o;
}

/// Host descriptors `h9ns_addfd` named, for `fd!NAME` dials. Native only.
const Fds = struct {
    var lock: std.atomic.Mutex = .unlocked;
    var names: [32]?struct { name: [64]u8, len: usize, fd: std.posix.fd_t } = @splat(null);

    fn spin() void {
        while (!lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn add(name: []const u8, fd: std.posix.fd_t) bool {
        if (name.len == 0 or name.len > 64) return false;
        spin();
        defer lock.unlock();
        var free: ?usize = null;
        for (&names, 0..) |*e, i| {
            if (e.*) |x| {
                if (std.mem.eql(u8, x.name[0..x.len], name)) {
                    _ = std.c.close(x.fd);
                    e.*.?.fd = fd;
                    return true;
                }
            } else if (free == null) free = i;
        }
        const i = free orelse return false;
        names[i] = .{ .name = undefined, .len = name.len, .fd = fd };
        @memcpy(names[i].?.name[0..name.len], name);
        return true;
    }

    /// A duplicate of `name`'s descriptor, which the caller owns.
    fn dup(name: []const u8) ?std.posix.fd_t {
        spin();
        defer lock.unlock();
        for (names) |e| if (e) |x| if (std.mem.eql(u8, x.name[0..x.len], name)) {
            const d = std.c.dup(x.fd);
            return if (d < 0) null else d;
        };
        return null;
    }
};

const DialError = kern.Error || error{Dial};

/// Opens a mount's dial (design/epoch-0/namespace-kernel.md, Composing) and
/// returns an fd on its 9P connection. `why` holds the error for
/// `error.Dial`; `error.Kern` leaves it in the kernel's error string.
fn rawDial(d: []const u8, why: *[]const u8) DialError!u31 {
    var buf: [256]u8 = undefined;
    if (std.mem.startsWith(u8, d, "srv!")) {
        const name = std.fmt.bufPrintSentinel(&buf, "{s}", .{d["srv!".len..]}, 0) catch {
            why.* = "srv name too long";
            return error.Dial;
        };
        const fd = h9_ns_hostsrv(name);
        if (fd < 0) return error.Kern;
        return @intCast(fd);
    }
    if (std.mem.startsWith(u8, d, "port!")) {
        const id = hstream.openPort(owner(), d["port!".len..]) catch |e| {
            why.* = switch (e) {
                error.Unsupported => "ports need the web host",
                error.BadUrl => "bad port name",
                error.TooManyStreams => "too many streams",
                error.OutOfMemory => "out of memory",
                error.SystemResources => "can't start a thread",
            };
            return error.Dial;
        };
        defer hstream.release(id);
        try kern.hstreamWait(id);
        return try kern.hstreamFd(id);
    }
    if (std.mem.startsWith(u8, d, "fd!")) {
        if (comptime nofds) {
            why.* = if (web.enabled) "host descriptors need a native host" else "host descriptors need a POSIX host";
            return error.Dial;
        }
        const fd = Fds.dup(d["fd!".len..]) orelse {
            why.* = "no such fd name";
            return error.Dial;
        };
        // The kernel takes the copy, and closes it on failure.
        const fds = try kern.hostFdDial(fd, fd);
        return fds[0];
    }
    if (std.mem.startsWith(u8, d, "ws://") or std.mem.startsWith(u8, d, "wss://")) {
        const id = hstream.openHost(owner(), d, .{}) catch |e| {
            why.* = switch (e) {
                error.BadUrl => "bad URL",
                error.TooManyStreams => "too many streams",
                error.OutOfMemory => "out of memory",
                error.SystemResources => "can't start a thread",
            };
            return error.Dial;
        };
        defer hstream.release(id);
        try kern.hstreamWait(id);
        return try kern.hstreamFd(id);
    }
    // A /srv entry, or any file that is a 9P connection, in the namespace.
    const path = std.fmt.bufPrintSentinel(&buf, "{s}", .{d}, 0) catch {
        why.* = "dial too long";
        return error.Dial;
    };
    return try kern.open(path, kern.ORDWR);
}

/// Whether dial string `d` names something already speaking 9P2000 to
/// devmnt: a posted service, which `post` made a `#ℓ` conversation, or a
/// file in the namespace.
fn posted(d: []const u8) bool {
    for ([_][]const u8{ "port!", "fd!", "ws://", "wss://" }) |p| if (std.mem.startsWith(u8, d, p)) return false;
    return true;
}

/// `d`'s connection as an fd devmnt can mount: a host connection goes
/// through a `#ℓ` conversation, so 9P2000.L servers work too; a posted
/// one already did.
fn dial(d: []const u8, why: *[]const u8) DialError!u31 {
    const conn = try rawDial(d, why);
    if (posted(d)) return conn;
    defer kern.close(conn) catch {};
    var cmd: [32]u8 = undefined;
    return try dotlConv(std.fmt.bufPrint(&cmd, "fd {d}", .{conn}) catch unreachable);
}

/// Starts a `#ℓ` conversation with ctl message `msg` and returns an fd on
/// its data file, which devmnt mounts and kserve serves.
fn dotlConv(msg: []const u8) kern.Error!u31 {
    const dev = "#ℓ/dotl/";
    const clone = try kern.open(dev ++ "clone", kern.ORDWR);
    defer kern.close(clone) catch {};
    var nbuf: [16]u8 = undefined;
    const n = std.mem.trim(u8, nbuf[0..try kern.pread(clone, &nbuf, 0)], " \n");
    _ = try kern.pwrite(clone, msg, 0);
    var path: [64]u8 = undefined;
    return kern.open(std.fmt.bufPrintSentinel(&path, dev ++ "{s}/data", .{n}, 0) catch return error.Kern, kern.ORDWR);
}

fn mountFlag(f: newns.Flag) c_int {
    var flag: c_int = switch (f.order) {
        .repl => kern.MREPL,
        .before => kern.MBEFORE,
        .after => kern.MAFTER,
    };
    if (f.create) flag |= kern.MCREATE;
    if (f.cache) flag |= kern.MCACHE;
    return flag;
}

// The ctl lines.

const LineError = kern.Error || error{Dial};

/// Binds `#O<id>` at `to` with `flag`, and unpins the instance, so it
/// lives as long as something holds it.
fn bindInstance(id: u32, to: [:0]const u8, flag: c_int) kern.Error!void {
    var spec: [16]u8 = undefined;
    defer kern.overlayDrop(id);
    try kern.bind(std.fmt.bufPrintSentinel(&spec, "#O{d}", .{id}, 0) catch unreachable, to, flag);
}

fn bindOp(b: anytype, from: [:0]const u8, to: [:0]const u8) kern.Error!void {
    const fresh = std.mem.eql(u8, from, "#O");
    var num: [16]u8 = undefined;
    if (b.flag.upper) {
        // `bind -u` (design/epoch-0/upper-layers.md): from is a writable layer
        // over what to is now; a bare #O is a fresh one in memory.
        const id = try kern.unionAdd("", to, "", .{ .after = true });
        errdefer kern.overlayDrop(id);
        const ids = std.fmt.bufPrintSentinel(&num, "{d}", .{id}, 0) catch unreachable;
        if (fresh) {
            const layer = try kern.overlayNew(null);
            var lb: [16]u8 = undefined;
            defer kern.overlayDrop(layer);
            _ = try kern.unionAdd(ids, std.fmt.bufPrintSentinel(&lb, "#O{d}", .{layer}, 0) catch unreachable, "", .{ .up = true, .create = true });
        } else _ = try kern.unionAdd(ids, from, "", .{ .up = true, .create = true });
        return bindInstance(id, to, kern.MREPL | kern.MCREATE);
    }
    if (b.flag.recursive) {
        // `bind -r` (design/epoch-0/mounts.md): a union merged at every depth.
        const flags: kern.UnionFlags = .{ .after = b.flag.order == .after, .create = b.flag.create };
        if (kern.unionOf(to)) |id| {
            _ = try kern.unionAdd(std.fmt.bufPrintSentinel(&num, "{d}", .{id}, 0) catch unreachable, from, "", flags);
            return;
        }
        const id = try kern.unionAdd("", to, "", .{ .after = true });
        errdefer kern.overlayDrop(id);
        _ = try kern.unionAdd(std.fmt.bufPrintSentinel(&num, "{d}", .{id}, 0) catch unreachable, from, "", flags);
        return bindInstance(id, to, kern.MREPL | kern.MCREATE);
    }
    if (fresh) {
        // A bare #O: a fresh overlay over what to is now, which takes
        // creates: writes are what it's for.
        const id = try kern.overlayNew(to);
        return bindInstance(id, to, mountFlag(b.flag) | kern.MCREATE);
    }
    try kern.bind(from, to, mountFlag(b.flag));
}

fn runOp(ns: ?*anyopaque, arena: std.mem.Allocator, op: newns.Op, why: *[]const u8) LineError!void {
    switch (op) {
        .bind => |b| try bindOp(b, try arena.dupeSentinel(u8, b.from, 0), try arena.dupeSentinel(u8, b.to, 0)),
        .mount => |m| {
            if (m.settings.len > 0) {
                why.* = "mount settings aren't taken here";
                return error.Dial;
            }
            const conv = try dial(m.file, why);
            defer kern.close(conv) catch {};
            _ = try kern.mount(conv, -1, try arena.dupeSentinel(u8, m.to, 0), mountFlag(m.flag), try arena.dupeSentinel(u8, m.spec, 0));
            h9_ns_dialed(ns, try arena.dupeSentinel(u8, m.file, 0));
        },
        .unmount => |u| try kern.unmount(if (u.from) |f| try arena.dupeSentinel(u8, f, 0) else null, try arena.dupeSentinel(u8, u.to, 0)),
        .cd => |d| try kern.chdir(try arena.dupeSentinel(u8, d, 0)),
        // #N runs clear itself.
        .clear => {
            why.* = "clear: not in a line with others";
            return error.Dial;
        },
    }
}

/// Runs one ctl line (design/epoch-0/namespace-kernel.md, Composing) in the
/// calling process's namespace, which #N has set to namespace `ns`'s.
/// Returns 0, or -1 with the error in `err` (ERRMAX bytes); the line's
/// operations before a failed one stand.
export fn h9_ns_ctl(ns: ?*anyopaque, line: [*]const u8, n: c_long, err: [*]u8) c_int {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var line_no: usize = 0;
    const text = line[0..@intCast(n)];
    // post NAME DIAL: a connection on the namespace's board.
    var words = std.mem.tokenizeAny(u8, text, " \t");
    if (words.next()) |w| if (std.mem.eql(u8, w, "post")) {
        const name = words.next() orelse "";
        const d = words.next() orelse "";
        if (name.len == 0 or d.len == 0 or words.next() != null) {
            putErr(err, "usage: post name dial");
            return -1;
        }
        var why: []const u8 = "";
        const fd = dial(d, &why) catch |e| {
            putErr(err, if (e == error.Dial) why else kern.errstr());
            return -1;
        };
        defer kern.close(fd) catch {};
        const nm = arena.dupeSentinel(u8, name, 0) catch {
            putErr(err, "out of memory");
            return -1;
        };
        if (h9_ns_srvpost(ns, nm, fd) < 0) {
            putErr(err, kern.errstr());
            return -1;
        }
        return 0;
    };
    const ops = newns.parse(arena, text, &line_no) catch |e| {
        putErr(err, switch (e) {
            error.OutOfMemory => "out of memory",
            error.Syntax => "bad ctl line",
        });
        return -1;
    };
    for (ops) |op| {
        var why: []const u8 = "";
        runOp(ns, arena, op, &why) catch |e| {
            putErr(err, switch (e) {
                error.Kern => kern.errstr(),
                error.KernUnavailable => "no kernel",
                error.Dial => why,
                error.OutOfMemory => "out of memory",
            });
            return -1;
        };
    }
    return 0;
}

// Serving.

var booted: web.Atomic(u8) = .init(0); // 0 not yet, 1 up, 2 failed
var boot_err: [ERRMAX]u8 = @splat(0);
var server: ?*kern.Kserve = null;
var threaded: if (web.enabled) void else std.Io.Threaded = undefined;

fn theIo() std.Io {
    if (comptime web.enabled) return web.io();
    return threaded.io();
}

const Boot = struct {};
var boot_arg: Boot = .{};
var ns_kernel: ?*kern.Kernel = null;
const no_host: @import("host/host.zig").Host = .{};

/// The namespace kernel's first process: makes namespace 0 and the
/// server, then serves each connection posted to it until the host
/// process ends.
fn serverMain(_: *Boot) void {
    kern.setText("h9ns");
    if (h9_ns_init() < 0) return failBoot(kern.errstr());
    if (kern.Kernel.ofMach(@ptrFromInt(owner()))) |k| dotl.register(k, .{ .user = kern.user(), .io = theIo() });
    server = kern.Kserve.newNamed(&h9_ns_lookup, null, null) catch return failBoot(kern.errstr());
    booted.store(1, .release);
    if (comptime web.enabled) {
        const th = web.Thread.spawn(.{}, acceptPorts, .{owner()}) catch return;
        th.detach();
    }
    var aname: [64]u8 = undefined;
    while (true) {
        var kind: c_int = 0;
        var arg: c_long = 0;
        if (h9_ns_next(&kind, &arg, &aname, aname.len) < 0) continue;
        serveOne(kind, arg, std.mem.sliceTo(&aname, 0));
    }
}

fn failBoot(msg: []const u8) void {
    const n = @min(msg.len, ERRMAX - 1);
    @memcpy(boot_err[0..n], msg[0..n]);
    boot_err[n] = 0;
    booted.store(2, .release);
}

/// Hands one connection to kserve, through a `#ℓ` conversation's server
/// side (design/epoch-0/dotl.md), so a 9P2000.L client is translated, as
/// serve's per-connection path does.
fn serveOne(kind: c_int, arg: c_long, aname: []const u8) void {
    const fd: u31 = switch (std.enums.fromInt(Post, kind) orelse return) {
        .stream => blk: {
            const id: u32 = @intCast(arg);
            defer hstream.release(id);
            break :blk kern.hstreamFd(id) catch return;
        },
        .fd => if (comptime nofds) return else blk: {
            const fds = kern.hostFdDial(@intCast(arg), @intCast(arg)) catch return;
            break :blk fds[0];
        },
    };
    var cmd: [32]u8 = undefined;
    const data = dotlConv(std.fmt.bufPrint(&cmd, "serve {d}", .{fd}) catch unreachable);
    kern.close(fd) catch {};
    const sfd = data catch return;
    defer kern.close(sfd) catch {};
    var nb: [64]u8 = undefined;
    const an = std.fmt.bufPrintSentinel(&nb, "{s}", .{aname}, 0) catch return;
    server.?.connAs(sfd, an) catch {};
}

/// What an accepted stream tells: its attach name rides in the context.
const Accepted = struct {
    aname: [64]u8 = @splat(0),
    served: hstream.Served = undefined,

    fn ready(ctx: *anyopaque, id: u32) void {
        const a: *Accepted = @ptrCast(@alignCast(ctx));
        if (h9_ns_post(@backingInt(Post.stream), @intCast(id), @ptrCast(&a.aname)) < 0) hstream.release(id);
    }

    fn done(ctx: *anyopaque, handed: bool) void {
        _ = handed;
        const a: *Accepted = @ptrCast(@alignCast(ctx));
        gpa.destroy(a);
    }
};

/// The JS host's served ports' attach names (h9ns.js's `connect`).
const js = struct {
    extern "h9" fn port_aname(id: i32, buf: [*]u8, n: u32) i32;
};

/// Takes each port the page hands the kernel to serve, on the web host.
fn acceptPorts(own: usize) void {
    while (true) {
        const sock = hstream.acceptPort() orelse return;
        const a = gpa.create(Accepted) catch {
            hstream.dropPort(sock);
            continue;
        };
        a.* = .{};
        const n = js.port_aname(sock, &a.aname, a.aname.len - 1);
        if (n < 0) {
            gpa.destroy(a);
            hstream.dropPort(sock);
            continue;
        }
        a.served = .{ .ctx = a, .ready = Accepted.ready, .done = Accepted.done };
        hstream.openAcceptedPort(own, null, sock, &a.served) catch gpa.destroy(a);
    }
}

/// Boots the kernel and namespace 0, once. Returns 0, or -1 with the
/// reason in `h9ns_error`.
fn bootOnce() c_int {
    switch (booted.load(.acquire)) {
        1 => return 0,
        2 => return -1,
        else => {},
    }
    if (comptime !web.enabled) {
        threaded = .init(std.heap.page_allocator, .{});
    }
    hstream.setIo(theIo());
    // The namespace kernel's one Kernel, for the host process's life.
    const k = kern.Kernel.init(std.heap.page_allocator, &no_host) catch {
        failBoot("can't start the kernel");
        return -1;
    };
    k.spawn("h9ns", Boot, serverMain, &boot_arg) catch {
        k.deinit();
        failBoot("can't start the kernel");
        return -1;
    };
    ns_kernel = k;
    while (booted.load(.acquire) == 0) web.yield();
    return if (booted.load(.acquire) == 1) 0 else -1;
}

// The native API (h9ns.h).

/// Boots the namespace kernel. Returns 0, or -1 (see h9ns_error).
export fn h9ns_boot() c_int {
    return bootOnce();
}

/// Why the last call failed.
export fn h9ns_error() [*:0]const u8 {
    return @ptrCast(&boot_err);
}

/// Serves 9P2000 (or 9P2000.L) on host descriptor `fd`, attached to
/// namespace `aname` (its id; "" or null is 0), until the far end hangs
/// up. The kernel takes `fd`. Returns 0 once serving has started, or -1.
export fn h9ns_serve(fd: c_int, aname: ?[*:0]const u8) c_int {
    if (comptime nofds) return -1;
    if (bootOnce() < 0) return -1;
    if (fd < 0) return -1;
    if (h9_ns_post(@backingInt(Post.fd), fd, aname orelse "") < 0) return -1;
    return 0;
}

/// Names host descriptor `fd`, a 9P server, so a ctl line can mount it as
/// `fd!NAME`. Each mount dials a duplicate; the kernel keeps `fd` and
/// closes it if the name is given again. Returns 0, or -1.
export fn h9ns_addfd(name: ?[*:0]const u8, fd: c_int) c_int {
    if (comptime nofds) return -1;
    const n = std.mem.span(name orelse return -1);
    for (n) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.')) return -1;
    return if (Fds.add(n, fd)) 0 else -1;
}

/// The web host's: boots and serves the ports the page hands it.
pub fn main() void {
    if (comptime !web.enabled) return;
    web.task.runMain(serve);
}

/// The first task on the web host's executor.
fn serve() void {
    if (bootOnce() < 0) {
        std.debug.print("h9ns: {s}\n", .{std.mem.sliceTo(&boot_err, 0)});
        return;
    }
    while (true) web.task.sleep(1 << 30);
}
