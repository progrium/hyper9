//! h9's glue.c (design/kernel-port.md): h9's replacement for drawterm's
//! main.c and cpu.c, which boots drawterm's kern without a cpu
//! connection, and the small calls the Zig side makes into the kernel
//! (src/kern.zig's). The screen is src/kern/gfx.c with a GUI backend, or
//! src/kern/nogfx.c without one (design/epoch-0/gfx.md). See SPEC.md,
//! "Kernel: h9's Zig and drawterm's C" in spec/kernel.md.
//!
//! A close translation of the C, with error unions in place of
//! the C's error labels. Each function is exported under its C name.

const std = @import("std");
const builtin = @import("builtin");
const port = @import("port.zig");
const sync = @import("sync.zig");
const pgrp = @import("pgrp.zig");
const chan = @import("chan.zig");
const sysfile = @import("sysfile.zig");
const devmnt = @import("devmnt.zig");
const c = port.c;
const up = port.up;
const Error = port.Error;

const Chan = c.Chan;

/// The C's `#if defined(WINDOWS) || defined(H9_WEB)`: the hosts with no
/// POSIX user database or pthread timer here.
const nonposix = @hasDecl(c, "WINDOWS") or @hasDecl(c, "H9_WEB");

var argv0: ?[*:0]u8 = null;
extern var kerndate: c_uint;
const tnow = if (nonposix) struct {
    extern fn h9_tnow() u64;
}.h9_tnow else timer.h9_tnow;

/// Compose sequences only matter for GUI keyboard input.
fn latin1(k: ?*c.Rune, n: c_int) callconv(.c) c_int {
    _ = k;
    _ = n;
    return -1;
}

// devtls's in-kernel factotum path, unused: a guest runs its own
// factotum and posts it in /srv (design/epoch-0/devsrv.md).
extern fn werrstr(f: [*:0]const u8, ...) void; // werrstr.c

fn auth_allocrpc(afd: c_int) callconv(.c) ?*anyopaque {
    _ = afd;
    werrstr("no factotum");
    return null;
}
fn auth_freerpc(rpc: ?*anyopaque) callconv(.c) void {
    _ = rpc;
}
fn auth_rpc(rpc: ?*anyopaque, verb: [*c]u8, a: ?*anyopaque, n: c_int) callconv(.c) c_int {
    _ = rpc;
    _ = verb;
    _ = a;
    _ = n;
    return -1;
}

extern fn h9_hostuser() [*c]u8; // glue-win32.c, os-wasm.c

var user: [64]u8 = undefined;

fn hostuser() [*c]u8 {
    if (nonposix) return h9_hostuser();
    const pw: ?*c.struct_passwd = c.getpwuid(c.getuid());
    if (pw == null)
        return @constCast("none");
    _ = c.strecpy(&user, @as([*]u8, &user) + user.len, pw.?.pw_name);
    return &user;
}

extern fn h9_proc_boot() void; // proc.zig

/// Boots the kernel. The calling thread becomes the kernel's first Proc
/// for good, so callers use a private thread (src/kern.zig). Machines'
/// processes are made later with h9_kern_spawn (proc.zig). Returns 0.
/// A device's reset or init that fails is a panic: the C raised with no
/// label to catch it.
fn h9_kern_boot() callconv(.c) c_int {
    kerndate = @bitCast(c.seconds());
    c.eve = hostuser();

    c.osinit();
    c.procinit0();
    c.printinit();
    chan.chandevreset() catch port.kpanic("h9_kern_boot: %s", .{up().errstr});
    chan.chandevinit() catch port.kpanic("h9_kern_boot: %s", .{up().errstr});
    // After chandevinit: devip sets sysname to the host name.
    chan.kstrdup(@ptrCast(&c.sysname), "h9");
    _ = c.quotefmtinstall();
    h9_proc_boot();
    return 0;
}

/// Parks the boot thread for good once the kernel is up.
fn h9_kern_park() callconv(.c) void {
    while (true)
        c.procsleep();
}

/// The host user, which is hostowner.
fn h9_kern_user() callconv(.c) [*c]u8 {
    return c.eve;
}

/// The calling Proc's pid.
fn h9_kern_pid() callconv(.c) c_uint {
    return up().pid;
}

/// Masks the devices whose letters are in devs from future attaches.
fn h9_kern_devmask(devs: [*:0]const u8) callconv(.c) void {
    pgrp.devmask(up().pgrp, false, devs);
}

/// The calling Proc, and interrupting one (for timeouts).
fn h9_kern_self() callconv(.c) ?*anyopaque {
    return up();
}

fn h9_kern_interrupt(p: *c.Proc) callconv(.c) void {
    sync.procinterrupt(p);
}

/// sleep(ms): drawterm has no tsleep, so this sleeps in short slices
/// and stops early when the Proc is interrupted. Returns 0, or -1 with
/// "interrupted" as the error string.
fn h9_kern_sleep(ms_: c_int) callconv(.c) c_int {
    // What's left is measured against a deadline on the monotonic clock
    // rather than counted down by slices: each osmsleep can overshoot (on
    // a busy host or macOS's efficiency cores, several times over), and
    // counting slices added every overshoot to the sleep.
    if (ms_ <= 0) {
        c.osyield();
        return 0;
    }
    const deadline = tnow() + @as(u64, @intCast(ms_)) * 1000000;
    while (true) {
        if (up().notepending != 0) {
            up().notepending = 0;
            chan.kstrcpy(up().syserrstr, &port.Eintr, port.ERRMAX);
            return -1;
        }
        const now = tnow();
        if (now >= deadline) break;
        const ms: u64 = (deadline - now + 999999) / 1000000;
        c.osmsleep(@intCast(@min(ms, 20)));
    }
    return 0;
}

/// The current Proc's error string, for the Zig side.
fn h9_kern_errstr() callconv(.c) [*c]u8 {
    return if (up().nerrlab != 0) up().errstr else up().syserrstr;
}

/// A failed call's error string becomes syserrstr, as sysfile.c's
/// wrappers left it.
fn syserr() c_int {
    const p = up();
    const s = p.syserrstr;
    p.syserrstr = p.errstr;
    p.errstr = s;
    return -1;
}

/// fd2path: drawterm's _sysfd2path passes an uninitialised length and
/// has no sys* wrapper.
fn fd2path(fd: c_int, buf: [*]u8, nbuf: c_uint) Error!void {
    const ch = try sysfile.fdtochan(fd, -1, false, true);
    _ = c.snprint(buf, @bitCast(nbuf), @constCast("%s"), chan.chanpath(ch));
    chan.cclose(ch);
}

fn h9_fd2path(fd: c_int, buf: [*]u8, nbuf: c_uint) callconv(.c) c_int {
    fd2path(fd, buf, nbuf) catch return syserr();
    return 0;
}

/// fauth(fd, aname), as 9front's sysfauth (port/auth.c): sends Tauth
/// over the 9P channel on fd with devmnt's mntauth, and returns a new
/// fd, close on exec, on the auth channel; or an error, which is the
/// server's ("authentication not required", say) when it refuses.
/// design/epoch-0/devsrv.md.
fn fauth(fd: c_int, aname_: [*:0]const u8) Error!c_int {
    const ac = blk: {
        const aname = try chan.validnamedup(aname_, true);
        defer c.free(aname);
        const ch = try sysfile.fdtochan(fd, c.ORDWR, false, true);
        defer chan.cclose(ch);

        // at this point ac is responsible for keeping ch alive
        break :blk try devmnt.mntauth(ch, aname);
    };
    errdefer chan.cclose(ac);

    // always mark it close on exec
    const nfd = sysfile.newfd(ac, c.OCEXEC);
    if (nfd < 0)
        return port.kerror(&port.Enofd);
    return nfd;
}

fn h9_fauth(fd: c_int, aname: [*:0]const u8) callconv(.c) c_int {
    const nfd = fauth(fd, aname) catch return syserr();
    up().notepending = 0;
    return nfd;
}

// The host side of tsleep's timer kproc (tsleep.c): a lock, and a wait
// on a condition variable until a deadline on the monotonic clock. The
// Windows version is in glue-win32.c, and the web host's in os-wasm.c.
const timer = struct {
    var tmu: std.c.pthread_mutex_t = .{}; // PTHREAD_MUTEX_INITIALIZER
    var tcond: std.c.pthread_cond_t = undefined;

    fn h9_tinit() callconv(.c) void {
        var a: c.pthread_condattr_t = undefined;

        _ = c.pthread_condattr_init(&a);
        // macOS has no clock attribute; its relative wait is on a
        // monotonic clock.
        if (!builtin.os.tag.isDarwin())
            _ = c.pthread_condattr_setclock(&a, c.CLOCK_MONOTONIC);
        _ = c.pthread_cond_init(@ptrCast(&tcond), &a);
        _ = c.pthread_condattr_destroy(&a);
    }

    fn h9_tnow() callconv(.c) u64 {
        var ts: c.struct_timespec = undefined;

        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        return @as(u64, @intCast(ts.tv_sec)) * 1000000000 + @as(u64, @intCast(ts.tv_nsec));
    }

    fn h9_tlock() callconv(.c) void {
        _ = std.c.pthread_mutex_lock(&tmu);
    }

    fn h9_tunlock() callconv(.c) void {
        _ = std.c.pthread_mutex_unlock(&tmu);
    }

    fn h9_tsignal() callconv(.c) void {
        _ = std.c.pthread_cond_signal(&tcond);
    }

    extern fn pthread_cond_timedwait_relative_np(cond: *std.c.pthread_cond_t, mu: *std.c.pthread_mutex_t, ts: *const c.struct_timespec) c_int;

    fn h9_twait(when_: u64) callconv(.c) void {
        var when = when_;
        var ts: c.struct_timespec = undefined;

        if (when == 0) {
            _ = std.c.pthread_cond_wait(&tcond, &tmu);
            return;
        }
        const now = h9_tnow();
        if (when <= now)
            return;
        if (builtin.os.tag.isDarwin()) {
            when -= now;
            ts.tv_sec = @intCast(when / 1000000000);
            ts.tv_nsec = @intCast(when % 1000000000);
            _ = pthread_cond_timedwait_relative_np(&tcond, &tmu, &ts);
        } else {
            ts.tv_sec = @intCast(when / 1000000000);
            ts.tv_nsec = @intCast(when % 1000000000);
            _ = c.pthread_cond_timedwait(@ptrCast(&tcond), @ptrCast(&tmu), &ts);
        }
    }
};

pub fn exportC() void {
    @export(&argv0, .{ .name = "argv0" });
    @export(&latin1, .{ .name = "latin1" });
    @export(&auth_allocrpc, .{ .name = "auth_allocrpc" });
    @export(&auth_freerpc, .{ .name = "auth_freerpc" });
    @export(&auth_rpc, .{ .name = "auth_rpc" });
    @export(&h9_kern_boot, .{ .name = "h9_kern_boot" });
    @export(&h9_kern_park, .{ .name = "h9_kern_park" });
    @export(&h9_kern_user, .{ .name = "h9_kern_user" });
    @export(&h9_kern_pid, .{ .name = "h9_kern_pid" });
    @export(&h9_kern_devmask, .{ .name = "h9_kern_devmask" });
    @export(&h9_kern_self, .{ .name = "h9_kern_self" });
    @export(&h9_kern_interrupt, .{ .name = "h9_kern_interrupt" });
    @export(&h9_kern_sleep, .{ .name = "h9_kern_sleep" });
    @export(&h9_kern_errstr, .{ .name = "h9_kern_errstr" });
    @export(&h9_fd2path, .{ .name = "h9_fd2path" });
    @export(&h9_fauth, .{ .name = "h9_fauth" });
    if (!nonposix) {
        @export(&timer.h9_tinit, .{ .name = "h9_tinit" });
        @export(&timer.h9_tnow, .{ .name = "h9_tnow" });
        @export(&timer.h9_tlock, .{ .name = "h9_tlock" });
        @export(&timer.h9_tunlock, .{ .name = "h9_tunlock" });
        @export(&timer.h9_tsignal, .{ .name = "h9_tsignal" });
        @export(&timer.h9_twait, .{ .name = "h9_twait" });
    }
}

const testing = std.testing;
const kt = port.testing;

test "fd2path names an fd's file, and a bad fd's error is syserrstr [kernel-port]" {
    _ = try kt.namespace();
    var fds: [2]c_int = undefined;
    _ = try sysfile.pipe(&fds);
    defer _ = sysfile.close(fds[0]) catch {};
    defer _ = sysfile.close(fds[1]) catch {};
    var buf: [64]u8 = undefined;
    try testing.expectEqual(0, h9_fd2path(fds[0], &buf, buf.len));
    try testing.expectEqualStrings("#|/data", std.mem.sliceTo(&buf, 0));
    try testing.expectEqual(-1, h9_fd2path(99, &buf, buf.len));
    try testing.expectEqualStrings(std.mem.span(@as([*:0]const u8, &port.Ebadfd)), std.mem.sliceTo(up().syserrstr, 0));
}

test "fauth on a pipe fails with the error on syserrstr [kernel-port]" {
    _ = try kt.namespace();
    try testing.expectEqual(-1, h9_fauth(99, ""));
    try testing.expectEqualStrings(std.mem.span(@as([*:0]const u8, &port.Ebadfd)), std.mem.sliceTo(up().syserrstr, 0));
}

test "the kernel's sleep is cut short by a note [kernel-port]" {
    _ = try kt.begin();
    try testing.expectEqual(0, h9_kern_sleep(1));
    up().notepending = 1;
    try testing.expectEqual(-1, h9_kern_sleep(1000));
    try testing.expectEqual(0, up().notepending);
    try testing.expectEqualStrings(std.mem.span(@as([*:0]const u8, &port.Eintr)), std.mem.sliceTo(up().syserrstr, 0));
}

test "the timer's wait ends at its deadline [kernel-port]" {
    if (nonposix) return error.SkipZigTest else try timerWait();
}

fn timerWait() !void {
    const t0 = timer.h9_tnow();
    timer.h9_tlock();
    timer.h9_twait(t0 + 2 * std.time.ns_per_ms);
    timer.h9_tunlock();
    try testing.expect(timer.h9_tnow() >= t0 + 2 * std.time.ns_per_ms);
}
