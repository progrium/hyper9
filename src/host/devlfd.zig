//! The host descriptor device, `#φ` (design/host-handles.md): drawterm's
//! devlfd-posix.c and devlfd-win32.c, ported to Zig as a native device.
//! A channel of it holds a host file descriptor (a HANDLE on Windows)
//! that it reads and writes as it is: the host's stdio for the console,
//! a unix-socket root's connection (src/kern/rootdial.zig), and a
//! process's pipes from drawterm's oscmd. drawterm names it `#L`, which
//! h9's Linux device has, so it's φ here (design/mounts.md).

const std = @import("std");
const builtin = @import("builtin");
const kern = @import("kern");

const port = kern;
const c = kern.c;
const dev = kern.dev;
const chan = kern.chan;
const Error = port.Error;
const Chan = c.Chan;
const Walkqid = c.Walkqid;

const windows = builtin.os.tag == .windows;
const win32 = if (windows) @import("win32.zig") else struct {};

/// φ.
pub const dc: c_int = 0x3C6;

/// A channel of the device for the host descriptor fd.
pub fn lfdchan(fd: ?*anyopaque) *Chan {
    const ch = chan.newchan();
    ch.type = @intCast(dev.devno(dc));
    dev.aux(ch).* = fd;
    ch.path = chan.newpath("fd");
    ch.mode = c.ORDWR;
    ch.qid.type = 0;
    ch.qid.path = 0;
    ch.qid.vers = 0;
    ch.dev = 0;
    ch.offset = 0;
    return ch;
}

fn c_lfdchan(fd: ?*anyopaque) callconv(.c) *Chan {
    return lfdchan(fd);
}

/// The host's error, as drawterm's oserror leaves it.
fn oserror() error{Kernel} {
    if (windows) return win32.oserr();
    c.oserrstr();
    return error.Kernel;
}

fn egreg() error{Kernel} {
    return port.kerror(&port.Egreg);
}

fn attach(_: [*:0]const u8) Error!*Chan {
    return egreg();
}

fn walk(_: *Chan, _: ?*Chan, _: [*]const [*:0]const u8, _: c_int) Error!?*Walkqid {
    return egreg();
}

fn stat(_: *Chan, _: [*]u8, _: c_int) Error!c_int {
    return egreg();
}

fn open(_: *Chan, _: c_int) Error!*Chan {
    return egreg();
}

fn close(ch: *Chan) Error!void {
    if (windows) {
        _ = win32.CloseHandle(dev.aux(ch).*.?);
    } else {
        _ = std.c.close(@intCast(@intFromPtr(dev.aux(ch).*)));
    }
}

// Neither reads nor writes at the offset: a pipe can't.

fn read(ch: *Chan, buf: ?*anyopaque, n: c_int, _: i64) Error!c_int {
    if (windows) {
        var r: win32.DWORD = 0;
        if (win32.ReadFile(dev.aux(ch).*.?, buf, @intCast(n), &r, null) == 0) return oserror();
        return @intCast(r);
    }
    const r = std.c.read(@intCast(@intFromPtr(dev.aux(ch).*)), @ptrCast(buf), @intCast(n));
    if (r < 0) return oserror();
    return @intCast(r);
}

fn write(ch: *Chan, buf: ?*const anyopaque, n: c_int, _: i64) Error!c_int {
    if (windows) {
        var r: win32.DWORD = 0;
        if (win32.WriteFile(dev.aux(ch).*.?, buf, @intCast(n), &r, null) == 0) return oserror();
        return @intCast(r);
    }
    const r = std.c.write(@intCast(@intFromPtr(dev.aux(ch).*)), @ptrCast(buf), @intCast(n));
    if (r < 0) return oserror();
    return @intCast(r);
}

pub const Device = dev.Native(dc, "lfd", .{
    .attach = attach,
    .walk = walk,
    .stat = stat,
    .open = open,
    .create = dev.devcreate,
    .close = close,
    .read = read,
    .write = write,
    .remove = dev.devremove,
    .wstat = dev.devwstat,
});

pub fn exportC() void {
    @export(&Device.dev, .{ .name = "lfddevtab" });
    @export(&c_lfdchan, .{ .name = "lfdchan" });
}
