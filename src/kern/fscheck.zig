//! The kernel's half of src/kern/fscheck.c in Zig (design/kernel-port.md):
//! the Linux ABI's FIFOs by paths in the caller's namespace, through #U,
//! overlays, and 9P2000.L mounts (fscheck.h). A close translation of the
//! same functions, in the same order, with error unions for the C's error
//! labels. fscheck.c keeps the host's half, the policy checks on host
//! paths, which never sets an error label. Links and renames are device
//! operations (design/file-interface.md, src/kern/syswide.zig).
//!
//! h9_fs_mkfifopath returns -1 with the error in errstr, as the sys*
//! wrappers do; h9_fs_chanisfifo raises for the C that calls it.
//! devoverlay's and devfs's calls that raise go through
//! src/kern/devshim.c.

const std = @import("std");
const port = @import("port.zig");
const dev = @import("dev.zig");
const chan = @import("chan.zig");
const c = port.c;
const up = port.up;
const Error = port.Error;

const Chan = c.Chan;

const H9_DMFIFO: c_uint = 0x00200000;

// devoverlay.c's and devfs's, which don't raise.
extern fn h9_overlay_isfifo(ch: *Chan) c_int;
extern fn h9_fs_isfifo(ch: *Chan) c_int;
// devhidx.c
extern fn h9_hidx_dotl(ch: *Chan) c_int;
// src/kern/devshim.c: those that raise.
extern fn h9_shim_overlay_mkfifo(ch: *Chan, name: [*:0]const u8, perm: c_uint) c_int;
extern fn h9_shim_fs_mkfifo(ch: *Chan, name: [*:0]const u8, perm: c_uint) c_int;


/// A call that failed: its error string becomes the process's
/// syserrstr, as errstr(2) reads it, and -1.
fn syserr() c_int {
    const p = up();
    const s = p.syserrstr;
    p.syserrstr = p.errstr;
    p.errstr = s;
    return -1;
}

/// The directory a new name in path goes in, open for Aaccess, and the
/// name, which is path's last element, in dir, a copy of path the caller
/// frees.
fn newname(path: [*:0]const u8, dir: *?[*:0]u8) Error!struct { ch: *Chan, name: [*:0]u8 } {
    const d_: ?[*:0]u8 = @ptrCast(c.strdup(path));
    const d = d_ orelse return port.kerror(&port.Enomem);
    dir.* = d;
    const s = std.mem.span(d);
    var name: [*:0]u8 = undefined;
    var ch: *Chan = undefined;
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| {
        d[i] = 0;
        name = d + i + 1;
        ch = try chan.namec(if (d[0] != 0) d else "/", c.Aaccess, 0, 0);
    } else {
        name = d;
        ch = try chan.namec(".", c.Aaccess, 0, 0);
    }
    errdefer chan.cclose(ch);
    if (name[0] == 0 or dev.streq(name, ".") or dev.streq(name, ".."))
        return port.kerror(&port.Eexist);
    if ((ch.qid.type & c.QTDIR) == 0)
        return port.kerror(&port.Enotdir);
    return .{ .ch = ch, .name = name };
}

/// Whether the mount chan ch is a 9P2000.L server's, through devdotl
/// (#ℓ), directly or under a mount index (#ι, devhidx.c).
fn dotlmount(ch: *Chan) bool {
    const m: *Chan = @as(?*Chan, ch.mchan) orelse return false;
    if (dev.of(m).dc == 0x2113)
        return true;
    // The namespace kernel has no mount index.
    return !port.options.nskernel and h9_hidx_dotl(m) != 0;
}

/// Makes path a FIFO, for the Linux ABI's mknodat
/// (design/epoch-0/linux-fifo.md): a node in memory in an overlay, or a
/// host FIFO in a devfs tree, where the new name is checked like a
/// create. Anywhere else, such as a plain 9P root, it's "operation not
/// permitted". On a 9P2000.L root it's a Tmknod (src/dotl/client.zig).
fn mkfifopath(path: [*:0]const u8, perm: c_uint) Error!void {
    var dir: ?[*:0]u8 = null;
    defer c.free(dir);
    const nn = try newname(path, &dir);
    var ch = nn.ch;
    switch (dev.of(ch).dc) {
        // The overlay takes the chan, whatever happens.
        'O' => return dev.caught(h9_shim_overlay_mkfifo(ch, nn.name, perm)),
        'U' => {
            defer chan.cclose(ch);
            try dev.caught(h9_shim_fs_mkfifo(ch, nn.name, perm));
        },
        // A 9P2000.L server's: devdotl's translator makes a create with H9_DMFIFO a Tmknod.
        'M' => if (dotlmount(ch)) {
            defer chan.cclose(ch);
            ch = try dev.create(dev.of(ch), ch, nn.name, c.OREAD, (perm & 0o777) | H9_DMFIFO);
        } else {
            chan.cclose(ch);
            return port.kerror("operation not permitted");
        },
        else => {
            chan.cclose(ch);
            return port.kerror("operation not permitted"); // Linux's EPERM: no FIFOs here
        },
    }
}

/// 0, or -1 with the error in errstr.
fn h9_fs_mkfifopath(path: [*:0]const u8, perm: c_uint) callconv(.c) c_int {
    mkfifopath(path, perm) catch return syserr();
    return 0;
}

/// Whether ch is a FIFO's chan: an overlay's FIFO node, a host FIFO in a
/// devfs tree, directly or below an overlay, or a FIFO on a 9P2000.L
/// server, whose Dir has H9_DMFIFO.
pub fn chanisfifo(ch: *Chan) Error!bool {
    switch (dev.of(ch).dc) {
        'O' => return h9_overlay_isfifo(ch) != 0,
        'U' => return h9_fs_isfifo(ch) != 0,
        'M' => {
            if (!dotlmount(ch))
                return false;
            var buf: [1024]u8 = undefined;
            const n = try dev.stat(dev.of(ch), ch, &buf, buf.len);
            var d: c.Dir = undefined;
            if (c.convM2D(&buf, @intCast(n), &d, null) != n)
                return false;
            return (d.mode & H9_DMFIFO) != 0;
        },
        else => return false,
    }
}

fn h9_fs_chanisfifo(ch: *Chan) callconv(.c) c_int {
    return @intFromBool(chanisfifo(ch) catch |e| port.raise(e));
}

pub fn exportC() void {
    @export(&h9_fs_mkfifopath, .{ .name = "h9_fs_mkfifopath" });
    @export(&h9_fs_chanisfifo, .{ .name = "h9_fs_chanisfifo" });
}

// Cases (zig build kern-test): the namespace kernel has overlays, and
// nstab.c's stand-ins for devfs.

const testing = std.testing;
const kt = port.testing;
const sysfile = @import("sysfile.zig");

extern fn h9_overlay_new(ch: ?*Chan) c_int;
extern fn h9_overlay_drop(id: c_int) void;

/// A fresh overlay bound at /root in a namespace of the process's own.
fn overlayTmp() !c_int {
    _ = try kt.namespace();
    const id = h9_overlay_new(null);
    try testing.expect(id >= 0);
    var buf: [32]u8 = undefined;
    const spec = try std.mem.printSentinel(&buf, "#O{d}", .{id}, 0);
    _ = try sysfile.bind(spec, "/root", c.MREPL | c.MCREATE);
    return id;
}

test "mkfifopath makes a FIFO in an overlay, and chanisfifo sees it [kernel-port]" {
    const id = try overlayTmp();
    defer h9_overlay_drop(id);
    try mkfifopath("/root/f", 0o644);
    const ch = try chan.namec("/root/f", c.Aaccess, 0, 0);
    defer chan.cclose(ch);
    try testing.expect(try chanisfifo(ch));
    const d = try chan.namec("/root", c.Aaccess, 0, 0);
    defer chan.cclose(d);
    try testing.expect(!try chanisfifo(d));
}

test "mkfifopath refuses a bad last name, a file as the directory, and devices with no FIFOs [kernel-port]" {
    const id = try overlayTmp();
    defer h9_overlay_drop(id);
    try testing.expectError(error.Kernel, mkfifopath("/root/..", 0o644));
    try testing.expectEqualStrings(std.mem.span(@as([*:0]const u8, &port.Eexist)), kt.errstr());
    try mkfifopath("/root/f", 0o644);
    try testing.expectError(error.Kernel, mkfifopath("/root/f/x", 0o644));
    try testing.expectEqualStrings(std.mem.span(@as([*:0]const u8, &port.Enotdir)), kt.errstr());
    // The root device has no FIFOs.
    try testing.expectError(error.Kernel, mkfifopath("/x", 0o644));
    try testing.expectEqualStrings("operation not permitted", kt.errstr());
    // The C calls give -1, with the error in syserrstr.
    try testing.expectEqual(-1, h9_fs_mkfifopath("/x", 0o644));
    try testing.expectEqualStrings("operation not permitted", std.mem.sliceTo(up().syserrstr, 0));
}
