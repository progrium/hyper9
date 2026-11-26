//! The host tree device, `#U` (design/host-handles.md): files beneath the
//! machine's directory handles. `devfs_posix.zig` is the POSIX hosts' and
//! the web host's, and `devfs_win32.zig` Windows'. A kernel built
//! without one (the namespace kernel, unless it keeps devfs) gets the
//! stand-ins below, which have no host tree.
//!
//! What the rest of the kernel calls directly: `anchor` (namec, once a
//! walk from a `#U` attach is done), `mkfifo` and `isfifo` (the Linux
//! ABI's FIFOs, src/kern/fscheck.zig and dev/overlay.zig), and `syncfs`
//! and `sync` (src/kern/linux.zig).

const builtin = @import("builtin");
const kern = @import("kern");

const c = kern.c;
const Chan = c.Chan;
const Error = kern.Error;

/// src/host/fscheck.c's operations, as policy.Op numbers them.
pub const Walk: c_int = 0;
pub const Read: c_int = 1;
pub const Write: c_int = 2;
pub const Create: c_int = 3;
pub const Remove: c_int = 4;
/// The source of a rename.
pub const Rename: c_int = 5;

/// h9_fs_resolvein's result for more than 40 links.
pub const RESLOOP: c_int = -3;
pub const ELOOP = "too many symbolic links";

/// A Linux link, which a Linux process's walk stops at
/// (design/epoch-0/linux-symlinks.md), and a FIFO (9P2000.u's
/// DMNAMEDPIPE).
pub const QTSYMLINK: u8 = 0x02;
pub const DMSYMLINK: c_uint = 0x02000000;
pub const DMFIFO: c_uint = 0x00200000;

const impl = if (!kern.options.hostfs)
    none
else if (builtin.os.tag == .windows)
    @import("devfs_win32.zig")
else
    @import("devfs_posix.zig");

pub const Device = impl.Device;

pub fn anchor(ch: *Chan) Error!void {
    return impl.anchor(ch);
}

pub fn mkfifo(ch: *Chan, name: [*:0]const u8, perm: c_uint) Error!void {
    return impl.mkfifo(ch, name, perm);
}

pub fn isfifo(ch: *Chan) bool {
    return impl.isfifoChan(ch);
}

pub fn syncfs(ch: *Chan) Error!void {
    return impl.syncfs(ch);
}

pub fn sync() Error!void {
    return impl.syncall();
}

pub fn exportC() void {
    if (kern.options.hostfs) @export(&impl.Device.dev, .{ .name = "fsdevtab" });
}

const none = struct {
    const Device = void;
    fn anchor(_: *Chan) Error!void {}
    fn mkfifo(_: *Chan, _: [*:0]const u8, _: c_uint) Error!void {
        return kern.kerror(&kern.Eperm);
    }
    fn isfifoChan(_: *Chan) bool {
        return false;
    }
    fn syncfs(_: *Chan) Error!void {}
    fn syncall() Error!void {}
};
