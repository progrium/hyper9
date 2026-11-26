//! The kernel's half of src/kern/fscheck.c in Zig (design/kernel-port.md):
//! the Linux ABI's links, renames, and FIFOs by paths in the caller's
//! namespace, through #U, overlays, and 9P2000.L mounts (fscheck.h). A
//! close translation of the same functions, in the same order, with error
//! unions for the C's error labels. fscheck.c keeps the host's half, the
//! policy checks on host paths, which never sets an error label.
//!
//! The *path calls return -1 with the error in errstr, as the sys*
//! wrappers do; the rest raise for the C that calls them, as they did.
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

const H9_QTSYMLINK = 0x02;
const H9_DMSYMLINK: c_uint = 0x02000000;
const H9_DMFIFO: c_uint = 0x00200000;

// proc.c: whether the next lookup acts on a link in its last name.
extern fn h9_fs_nofollow(on: c_int) c_int;
// devoverlay.c's and devfs's, which don't raise.
extern fn h9_overlay_readlink(ch: *Chan, buf: [*]u8, nbuf: c_int) c_int;
extern fn h9_overlay_isfifo(ch: *Chan) c_int;
extern fn h9_fs_readlink(ch: *Chan, buf: [*]u8, nbuf: c_int) c_int;
extern fn h9_fs_isfifo(ch: *Chan) c_int;
// devhidx.c
extern fn h9_hidx_dotl(ch: *Chan) c_int;
// src/kern/devshim.c: those that raise.
extern fn h9_shim_overlay_lower(ch: *Chan, r: *?*Chan) c_int;
extern fn h9_shim_overlay_symlink(ch: *Chan, name: [*:0]const u8, target: [*:0]const u8) c_int;
extern fn h9_shim_overlay_move(ch: *Chan, dc: *Chan, name: [*:0]const u8, r: *c_int) c_int;
extern fn h9_shim_overlay_mkfifo(ch: *Chan, name: [*:0]const u8, perm: c_uint) c_int;
extern fn h9_shim_fs_symlink(ch: *Chan, name: [*:0]const u8, target: [*:0]const u8) c_int;
extern fn h9_shim_fs_rename(ch: *Chan, dir: *Chan, name: [*:0]const u8, r: *c_int) c_int;
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

/// The chan path names with nofollow set, so a Linux process's walk
/// stops on a link in its last name (design/epoch-0/linux-symlinks.md).
fn namecnofollow(path: [*:0]const u8) Error!*Chan {
    const nf = h9_fs_nofollow(1);
    defer _ = h9_fs_nofollow(nf);
    return chan.namec(path, c.Aaccess, 0, 0);
}

/// The target of the link that path's last name is, through #U and an
/// overlay over it, for the Linux ABI's readlinkat and lstat
/// (design/epoch-0/symlinks-in-root.md). Plan 9 programs never see links,
/// so it's a leaf, not a 9P message.
fn readlinkpath(path: [*:0]const u8, buf: [*]u8, nbuf: c_int) Error!c_int {
    const ch = try namecnofollow(path);
    defer chan.cclose(ch);
    const n = try chanreadlink(ch, buf, nbuf);
    if (n < 0)
        return port.kerror("not a symbolic link");
    return n;
}

/// Returns the target's length, with it in buf, or -1 with the error in
/// errstr, as the sys* wrappers do.
fn h9_fs_readlinkpath(path: [*:0]const u8, buf: [*]u8, nbuf: c_int) callconv(.c) c_int {
    return readlinkpath(path, buf, nbuf) catch syserr();
}

/// A link on a 9P mount reads as its target: the 9P2000.L client opens a
/// link a Linux process's walk stopped at without the server, and its
/// reads are the server's Treadlink (src/dotl/client.zig).
fn mntreadlink(ch: *Chan, buf: [*]u8, nbuf: c_int) Error!c_int {
    if (dev.of(ch).dc != 'M' or (ch.qid.type & H9_QTSYMLINK) == 0 or nbuf <= 0)
        return -1;
    var r = try chan.cclone(ch);
    defer chan.cclose(r);
    r = try dev.open(dev.of(r), r, c.OREAD);
    const n = try dev.read(dev.of(r), r, buf, nbuf - 1, 0);
    buf[@intCast(n)] = 0;
    return n;
}

/// The target of the link ch is on: an overlay's own, or one in the tree
/// that holds the name, down through overlays and unions
/// (design/epoch-0/mounts.md). Its length, with it in buf, or -1 if ch
/// isn't on a link.
pub fn chanreadlink(ch: *Chan, buf: [*]u8, nbuf: c_int) Error!c_int {
    _ = chan.incref(&ch.ref);
    var l = ch;
    defer chan.cclose(l);
    while (true) {
        const n = h9_overlay_readlink(l, buf, nbuf);
        if (n >= 0)
            return n;
        var nl: ?*Chan = null;
        try dev.caught(h9_shim_overlay_lower(l, &nl));
        if (nl == null) {
            const m = h9_fs_readlink(l, buf, nbuf);
            if (m >= 0)
                return m;
            return mntreadlink(l, buf, nbuf);
        }
        chan.cclose(l);
        l = nl.?;
    }
}

fn h9_fs_chanreadlink(ch: *Chan, buf: [*]u8, nbuf: c_int) callconv(.c) c_int {
    return chanreadlink(ch, buf, nbuf) catch |e| port.raise(e);
}

/// The directory a new name in path goes in, open for Aaccess, and the
/// name, which is path's last element, in dir, a copy of path the caller
/// frees: what renamepath, symlinkpath, and mkfifopath share.
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

/// Moves old to new in another directory, for the Linux ABI's renameat: a
/// host rename when both are in devfs trees (fscheck.h), and a move in
/// memory when both are in one overlay (devoverlay.c).
fn renamepath(old: [*:0]const u8, new: [*:0]const u8) Error!c_int {
    // The link old names is moved, not its target.
    const oc = try namecnofollow(old);
    defer chan.cclose(oc);
    var dir: ?[*:0]u8 = null;
    defer c.free(dir);
    const nn = try newname(new, &dir);
    defer chan.cclose(nn.ch);
    var r: c_int = 1;
    if (dev.of(oc).dc == 'U' and dev.of(nn.ch).dc == 'U')
        try dev.caught(h9_shim_fs_rename(oc, nn.ch, nn.name, &r))
    else if (dev.of(oc).dc == 'O' and dev.of(nn.ch).dc == 'O')
        try dev.caught(h9_shim_overlay_move(oc, nn.ch, nn.name, &r));
    return r;
}

/// 0, 1 if it can't (the caller's EXDEV), or -1 with the error in errstr.
fn h9_fs_renamepath(old: [*:0]const u8, new: [*:0]const u8) callconv(.c) c_int {
    return renamepath(old, new) catch syserr();
}

/// Makes path a symbolic link to target, for the Linux ABI's symlinkat:
/// in memory in an overlay, on the host in a devfs tree, where the new
/// name is checked like a create, or on a 9P2000.L mount by Tsymlink.
/// Anywhere else it's "permission denied".
fn symlinkpath(path: [*:0]const u8, target: [*:0]const u8) Error!void {
    var dir: ?[*:0]u8 = null;
    defer c.free(dir);
    const nn = try newname(path, &dir);
    switch (dev.of(nn.ch).dc) {
        // The overlay takes the chan, whatever happens.
        'O' => return dev.caught(h9_shim_overlay_symlink(nn.ch, nn.name, target)),
        'U' => {
            defer chan.cclose(nn.ch);
            try dev.caught(h9_shim_fs_symlink(nn.ch, nn.name, target));
        },
        'M' => {
            defer chan.cclose(nn.ch);
            try mntsymlink(nn.ch, nn.name, target);
        },
        else => {
            chan.cclose(nn.ch);
            return port.kerror(&port.Eperm);
        },
    }
}

/// 0, or -1 with the error in errstr.
fn h9_fs_symlinkpath(path: [*:0]const u8, target: [*:0]const u8) callconv(.c) c_int {
    symlinkpath(path, target) catch return syserr();
    return 0;
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

/// Makes name in the 9P2000.L mount directory dir a link to target: a
/// create with H9_DMSYMLINK, then a write of the target, which the
/// translator makes a Tsymlink (src/dotl/client.zig). Anywhere else, such
/// as a plain 9P mount, it's Eperm.
fn mntsymlink(dir: *Chan, name: [*:0]const u8, target: [*:0]const u8) Error!void {
    if (dev.of(dir).dc != 'M' or !dotlmount(dir))
        return port.kerror(&port.Eperm);
    const n: c_int = @intCast(std.mem.len(target));
    if (n == 0)
        return port.kerror(&port.Enonexist);
    var nc = try chan.cclone(dir);
    defer chan.cclose(nc);
    nc = try dev.create(dev.of(nc), nc, name, c.OWRITE, 0o777 | H9_DMSYMLINK);
    if (try dev.write(dev.of(nc), nc, @ptrCast(target), n, 0) != n)
        return port.kerror("short write");
}

fn h9_fs_mntsymlink(dir: *Chan, name: [*:0]const u8, target: [*:0]const u8) callconv(.c) void {
    mntsymlink(dir, name, target) catch |e| port.raise(e);
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
    @export(&h9_fs_readlinkpath, .{ .name = "h9_fs_readlinkpath" });
    @export(&h9_fs_chanreadlink, .{ .name = "h9_fs_chanreadlink" });
    @export(&h9_fs_renamepath, .{ .name = "h9_fs_renamepath" });
    @export(&h9_fs_symlinkpath, .{ .name = "h9_fs_symlinkpath" });
    @export(&h9_fs_mntsymlink, .{ .name = "h9_fs_mntsymlink" });
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

test "the path calls refuse a bad last name, a file as the directory, and devices with no links [kernel-port]" {
    const id = try overlayTmp();
    defer h9_overlay_drop(id);
    try testing.expectError(error.Kernel, mkfifopath("/root/..", 0o644));
    try testing.expectEqualStrings(std.mem.span(@as([*:0]const u8, &port.Eexist)), kt.errstr());
    try mkfifopath("/root/f", 0o644);
    try testing.expectError(error.Kernel, symlinkpath("/root/f/x", "y"));
    try testing.expectEqualStrings(std.mem.span(@as([*:0]const u8, &port.Enotdir)), kt.errstr());
    // The root device has no links, and no FIFOs.
    try testing.expectError(error.Kernel, symlinkpath("/x", "y"));
    try testing.expectEqualStrings(std.mem.span(@as([*:0]const u8, &port.Eperm)), kt.errstr());
    try testing.expectError(error.Kernel, mkfifopath("/x", 0o644));
    try testing.expectEqualStrings("operation not permitted", kt.errstr());
    // The C calls give -1, with the error in syserrstr.
    try testing.expectEqual(-1, h9_fs_mkfifopath("/x", 0o644));
    try testing.expectEqualStrings("operation not permitted", std.mem.sliceTo(up().syserrstr, 0));
}

test "renamepath moves a name within an overlay [kernel-port]" {
    const id = try overlayTmp();
    defer h9_overlay_drop(id);
    _ = try sysfile.close(try sysfile.create("/root/a", c.OWRITE, 0o644));
    _ = try sysfile.close(try sysfile.create("/root/d", c.OREAD, c.DMDIR | 0o755));
    try testing.expectEqual(0, try renamepath("/root/a", "/root/d/b"));
    _ = try sysfile.close(try sysfile.open("/root/d/b", c.OREAD));
    try testing.expectError(error.Kernel, sysfile.open("/root/a", c.OREAD));
    // Across devices it's the caller's EXDEV.
    try testing.expectEqual(1, try renamepath("/root/d/b", "/c"));
}
