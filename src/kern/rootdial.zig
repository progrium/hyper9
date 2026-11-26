//! The host side of 9P roots (src/kern/rootdial.c,
//! design/epoch-0/ninep-roots.md, design/kernel-port.md): connecting a unix
//! socket root, and the user name devmnt sends in a root's attach. A
//! close translation of the C: the same functions in the same order,
//! with error unions in place of waserror.
//!
//! A unix socket root is connected by h9 on the host and wrapped as a
//! channel with devlfd's lfdchan, as drawterm wraps the host's stdio.
//! Windows has AF_UNIX, but a winsock handle doesn't go through
//! devlfd-win32's ReadFile and WriteFile, so it isn't supported there.
//!
//! An embedder's descriptors (design/epoch-0/fd-mounts.md) come in already
//! duplicated by h9 (Machine.connectUrl), and are wrapped the same way.

const std = @import("std");
const builtin = @import("builtin");
const port = @import("port.zig");
const chan = @import("chan.zig");
const sysfile = @import("sysfile.zig");
const c = port.c;
const up = port.up;
const Error = port.Error;

const Chan = c.Chan;

const windows = builtin.os.tag == .windows;
const web = @hasDecl(c, "H9_WEB");
const posix = !windows and !web;

/// The host error (errno) as the process's error string, as drawterm's
/// oserror leaves it.
fn oserror() error{Kernel} {
    c.oserrstr();
    return error.Kernel;
}

/// Connects to the unix-domain socket at the host path `path` and
/// returns a devlfd channel for it.
pub fn unixchan(path: [*:0]const u8) Error!*Chan {
    if (!posix)
        return port.kerror("unix socket roots need a POSIX host");
    var sa = std.mem.zeroes(std.c.sockaddr.un);
    sa.family = std.c.AF.UNIX;
    const p = std.mem.span(path);
    if (p.len >= sa.path.len)
        return port.kerror("socket path too long");
    @memcpy(sa.path[0..p.len], p);
    const s = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    if (s < 0)
        return oserror();
    if (std.c.connect(s, @ptrCast(&sa), @sizeOf(std.c.sockaddr.un)) < 0) {
        const e = oserror();
        _ = std.c.close(s);
        return e;
    }
    // closing the channel closes s (devlfd's lfdclose)
    return c.lfdchan(@ptrFromInt(@as(usize, @intCast(s))));
}

/// Connects to the unix-domain socket at the host path `path` and
/// returns a new fd on a devlfd channel for it.
pub fn unixdial(path: [*:0]const u8) Error!c_int {
    const ch = try unixchan(path);
    const fd = sysfile.newfd(ch, 0);
    if (fd < 0) {
        chan.cclose(ch);
        return port.kerror(&port.Enofd);
    }
    return fd;
}

/// Wraps host descriptors rd and wr, which the channels take, as devlfd
/// channels, and returns new fds on them in rfd and wfd; wr may be the
/// same as rd, for a socket or a duplex pipe, and then wfd is -1. On an
/// error the descriptors are closed.
pub fn hostfddial(rd: ?*anyopaque, wr: ?*anyopaque, rfd: *c_int, wfd: *c_int) Error!void {
    rfd.* = -1;
    wfd.* = -1;
    if (web)
        return port.kerror("host descriptors need a native host");
    // closing a channel closes its descriptor (devlfd's lfdclose)
    var rc: ?*Chan = c.lfdchan(rd);
    var wc: ?*Chan = if (wr != rd) c.lfdchan(wr) else null;
    errdefer {
        if (rc) |ch| chan.cclose(ch);
        if (wc) |ch| chan.cclose(ch);
        if (rfd.* >= 0) _ = sysfile.close(rfd.*) catch {};
        rfd.* = -1;
        wfd.* = -1;
    }
    rfd.* = sysfile.newfd(rc.?, 0);
    if (rfd.* < 0)
        return port.kerror(&port.Enofd);
    rc = null;
    if (wc) |ch| {
        wfd.* = sysfile.newfd(ch, 0);
        if (wfd.* < 0)
            return port.kerror(&port.Enofd);
        wc = null;
    }
}

// A wait for a host descriptor to be readable that can be woken, so a #ℓ
// conversation's reader on a descriptor h9 doesn't own the other end of
// (an embedder's, design/epoch-0/fd-mounts.md) ends with the
// conversation, rather than blocking in the host's read until the other
// end writes or closes. Closing h9's copy wouldn't wake that read, and
// shutting the stream down would end the embedder's too.
//
// On POSIX it polls the descriptor with a pipe beside it, which wake
// writes. Windows can't poll a pipe handle, so it peeks it, sleeping a
// little longer each time it finds nothing, up to Hwaitmax ms.

const Hwaitmax = 8;

const Hostwait = struct {
    fd: ?*anyopaque,
    woken: std.atomic.Value(bool) = .init(false),
    p: if (posix) [2]std.c.fd_t else void = undefined,
};

const win = struct {
    const BOOL = std.os.windows.BOOL;
    const DWORD = std.os.windows.DWORD;
    const HANDLE = std.os.windows.HANDLE;
    extern "kernel32" fn PeekNamedPipe(h: HANDLE, buf: ?*anyopaque, n: DWORD, read: ?*DWORD, avail: ?*DWORD, left: ?*DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;
};

pub fn hostwait_new(fd: ?*anyopaque) ?*Hostwait {
    if (web)
        return null;
    const w: *Hostwait = @ptrCast(@alignCast(port.malloc(@sizeOf(Hostwait)) orelse return null));
    w.* = .{ .fd = fd };
    if (posix) {
        if (std.c.pipe(&w.p) < 0) {
            c.free(w);
            return null;
        }
        _ = std.c.fcntl(w.p[0], std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
        _ = std.c.fcntl(w.p[1], std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
        const nonblock: c_int = @bitCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })));
        _ = std.c.fcntl(w.p[1], std.c.F.SETFL, std.c.fcntl(w.p[1], std.c.F.GETFL) | nonblock);
    }
    return w;
}

/// True when the descriptor has bytes, has hung up, or can't be waited
/// on (the read says which), and false once woken.
pub fn hostwait(w_: ?*Hostwait) bool {
    const w = w_ orelse return true;
    if (web)
        return true;
    if (windows) {
        var ms: win.DWORD = 0;
        while (true) {
            if (w.woken.load(.acquire))
                return false;
            var avail: win.DWORD = 0;
            if (win.PeekNamedPipe(@ptrCast(w.fd), null, 0, null, &avail, null) == .FALSE or avail > 0)
                return true;
            win.Sleep(ms);
            if (ms < Hwaitmax)
                ms = if (ms == 0) 1 else ms * 2;
        }
    }
    while (true) {
        if (w.woken.load(.acquire))
            return false;
        var p = [2]std.c.pollfd{
            .{ .fd = @intCast(@intFromPtr(w.fd)), .events = std.c.POLL.IN, .revents = 0 },
            .{ .fd = w.p[0], .events = std.c.POLL.IN, .revents = 0 },
        };
        if (std.c.poll(&p, 2, -1) < 0) {
            if (std.c.errno(@as(c_int, -1)) == .INTR)
                continue;
            return true;
        }
        if (w.woken.load(.acquire) or (p[1].revents & std.c.POLL.IN) != 0)
            return false;
        if (p[0].revents != 0)
            return true;
    }
}

pub fn hostwait_wake(w_: ?*Hostwait) void {
    const w = w_ orelse return;
    w.woken.store(true, .release);
    if (posix) {
        const b = [1]u8{0};
        _ = std.c.write(w.p[1], &b, 1);
    }
}

pub fn hostwait_free(w_: ?*Hostwait) void {
    const w = w_ orelse return;
    if (posix) {
        _ = std.c.close(w.p[0]);
        _ = std.c.close(w.p[1]);
    }
    c.free(w);
}

/// The calling process's user, which devmnt sends as the attach uname.
pub fn upuser() [*:0]u8 {
    return @ptrCast(&up().user);
}

/// Sets it. Names longer than the kernel's KNAMELEN are cut short.
pub fn setuser(name: [*:0]const u8) void {
    const u = &up().user;
    _ = c.strecpy(@ptrCast(u), @as([*c]u8, @ptrCast(u)) + u.len, @constCast(name));
}

// The C names. The dials, for src/kern.zig, return -1 with the error in
// syserrstr.

fn syserr() c_int {
    const p = up().syserrstr;
    up().syserrstr = up().errstr;
    up().errstr = p;
    return -1;
}

fn h9_unixdial(path: [*:0]const u8) callconv(.c) c_int {
    return unixdial(path) catch return syserr();
}
fn h9_hostfddial(rd: ?*anyopaque, wr: ?*anyopaque, rfd: *c_int, wfd: *c_int) callconv(.c) c_int {
    hostfddial(rd, wr, rfd, wfd) catch return syserr();
    return 0;
}
fn h9_hostwait_new(fd: ?*anyopaque) callconv(.c) ?*anyopaque {
    return hostwait_new(fd);
}
fn h9_hostwait(w: ?*anyopaque) callconv(.c) c_int {
    return @intFromBool(hostwait(@ptrCast(@alignCast(w))));
}
fn h9_hostwait_wake(w: ?*anyopaque) callconv(.c) void {
    hostwait_wake(@ptrCast(@alignCast(w)));
}
fn h9_hostwait_free(w: ?*anyopaque) callconv(.c) void {
    hostwait_free(@ptrCast(@alignCast(w)));
}
fn h9_kern_upuser() callconv(.c) [*:0]u8 {
    return upuser();
}
fn h9_kern_setuser(name: [*:0]const u8) callconv(.c) void {
    setuser(name);
}

pub fn exportC() void {
    @export(&h9_unixdial, .{ .name = "h9_unixdial" });
    @export(&h9_hostfddial, .{ .name = "h9_hostfddial" });
    @export(&h9_hostwait_new, .{ .name = "h9_hostwait_new" });
    @export(&h9_hostwait, .{ .name = "h9_hostwait" });
    @export(&h9_hostwait_wake, .{ .name = "h9_hostwait_wake" });
    @export(&h9_hostwait_free, .{ .name = "h9_hostwait_free" });
    @export(&h9_kern_upuser, .{ .name = "h9_kern_upuser" });
    @export(&h9_kern_setuser, .{ .name = "h9_kern_setuser" });
}

// Cases (zig build kern-test).

const testing = std.testing;
const kt = port.testing;

test "a unix dial to nothing fails with the host's error, and leaves no fd [kernel-port]" {
    _ = try kt.namespace();
    if (!posix) return error.SkipZigTest;
    try testing.expectError(error.Kernel, unixdial("/nonexistent/h9-kernel-port.sock"));
    try testing.expect(kt.errstr().len > 0);
    var long: [200:0]u8 = @splat('a');
    long[0] = '/';
    try testing.expectError(error.Kernel, unixdial(&long));
    try testing.expectEqualStrings("socket path too long", kt.errstr());
}

test "host descriptors become fds, and a wait on one wakes [kernel-port]" {
    _ = try kt.namespace();
    if (!posix) return error.SkipZigTest;
    var fds: [2]std.c.fd_t = undefined;
    try testing.expectEqual(0, std.c.pipe(&fds));
    var rfd: c_int = undefined;
    var wfd: c_int = undefined;
    try hostfddial(@ptrFromInt(@as(usize, @intCast(fds[0]))), @ptrFromInt(@as(usize, @intCast(fds[1]))), &rfd, &wfd);
    try testing.expect(rfd >= 0 and wfd >= 0);

    const w = hostwait_new(@ptrFromInt(@as(usize, @intCast(fds[0])))).?;
    defer hostwait_free(w);
    try testing.expectEqual(1, try sysfile.pwrite(wfd, "x", 1, -1));
    try testing.expect(hostwait(w));
    var b: [1]u8 = undefined;
    try testing.expectEqual(1, try sysfile.pread(rfd, &b, 1, -1));
    hostwait_wake(w);
    try testing.expect(!hostwait(w));
    _ = try sysfile.close(rfd);
    _ = try sysfile.close(wfd);
}

test "the attach user is the process's, cut to KNAMELEN [kernel-port]" {
    _ = try kt.begin();
    const saved = up().user;
    defer up().user = saved;
    setuser("glenda");
    try testing.expectEqualStrings("glenda", std.mem.span(upuser()));
    const long: [100:0]u8 = @splat('u');
    setuser(&long);
    try testing.expectEqual(up().user.len - 1, std.mem.span(upuser()).len);
}
