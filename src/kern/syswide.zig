//! h9: the file calls beyond 9P2000's (design/file-interface.md, Part
//! 2), which the Linux ABI makes: readlink, symlink, link, rename,
//! getattr, and setattr, by path or fd. Each finds its chans as the
//! other calls do (namec, with nofollow where it acts on a link) and
//! calls the device switch's optional operation (dev.zig), whose
//! defaults are what h9 did before; the defaults that need a walk or a
//! create are here: a link is a copy, and a rename is a wstat within a
//! directory.
//!
//! The C names (`h9_readlink` and the rest) are for src/kern.zig, with
//! sysfile.zig's contract: -1 and the error in `syserrstr`.

const std = @import("std");
const port = @import("port.zig");
const dev = @import("dev.zig");
const chan = @import("chan.zig");
const sysfile = @import("sysfile.zig");
const c = port.c;
const up = port.up;
const Error = port.Error;

const Chan = c.Chan;
const Attr = c.Attr;

/// A path's directory, walked, and its last name, which is the
/// caller's to free (with the directory's chan) by `Parent.deinit`.
const Parent = struct {
    dir: *Chan,
    buf: [*:0]u8,
    name: [*:0]const u8,

    fn deinit(p: Parent) void {
        chan.cclose(p.dir);
        c.free(p.buf);
    }
};

fn parent(path: [*:0]const u8) Error!Parent {
    const buf: [*:0]u8 = @ptrCast(c.strdup(path) orelse return port.kerror(&port.Enomem));
    errdefer c.free(buf);
    const s = std.mem.span(buf);
    var name: [*:0]const u8 = buf;
    var dir: *Chan = undefined;
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| {
        buf[i] = 0;
        name = buf + i + 1;
        dir = try chan.namec(if (i == 0) "/" else buf, c.Aaccess, 0, 0);
    } else dir = try chan.namec(".", c.Aaccess, 0, 0);
    errdefer chan.cclose(dir);
    const n = std.mem.span(name);
    if (n.len == 0 or std.mem.eql(u8, n, ".") or std.mem.eql(u8, n, ".."))
        return port.kerror(&port.Eexist);
    if (dir.qid.type & c.QTDIR == 0)
        return port.kerror(&port.Enotdir);
    return .{ .dir = dir, .buf = buf, .name = name };
}

/// The target of the link path names, into buf: its length.
pub fn readlink(path: [*:0]const u8, buf: []u8) Error!usize {
    const ch = try chan.namecx(path, c.Aaccess, 0, 0, true);
    defer chan.cclose(ch);
    return try dev.readlink(ch, buf) orelse port.kerror("not a symbolic link");
}

/// Makes path a symbolic link to target.
pub fn symlink(path: [*:0]const u8, target: [*:0]const u8) Error!void {
    if (target[0] == 0)
        return port.kerror(&port.Enonexist);
    const p = try parent(path);
    defer p.deinit();
    try dev.symlink(p.dir, p.name, target);
}

/// Makes new another name for old's file, following a link old names
/// if follow is set: a link where old's device has them and new's
/// directory is on the same instance, and otherwise a copy with an
/// exclusive create, as h9 made before (design/file-interface.md), so
/// the "create if absent" that programs use link for holds.
pub fn link(old: [*:0]const u8, new: [*:0]const u8, follow: bool) Error!void {
    const oc = try chan.namecx(old, c.Aaccess, 0, 0, !follow);
    defer chan.cclose(oc);
    if (oc.qid.type & c.QTDIR != 0)
        return port.kerror(&port.Eperm);
    if (oc.ismtpt != 0)
        return port.kerror(&port.Eismtpt);
    {
        const p = try parent(new);
        defer p.deinit();
        if (try dev.link(oc, p.dir, p.name))
            return;
    }
    // The default: a copy, of a link's target, as before.
    const in = try chan.namec(old, c.Aopen, c.OREAD, 0);
    defer chan.cclose(in);
    var a: Attr = undefined;
    try dev.getattr(in, c.Amode, &a);
    if (a.mode & c.DMDIR != 0)
        return port.kerror(&port.Eperm);
    const out = try chan.namec(new, c.Acreate, c.OWRITE | c.OEXCL, a.mode & 0o777);
    defer chan.cclose(out);
    errdefer {
        _ = sysfile.remove(new) catch {};
    }
    const bufsize = 16 << 10;
    const buf: [*]u8 = @ptrCast(c.smalloc(bufsize));
    defer c.free(buf);
    var off: i64 = 0;
    while (true) {
        const n = try dev.read(dev.of(in), in, buf, bufsize, off);
        if (n <= 0) break;
        var w: c_int = 0;
        while (w < n) {
            const k = try dev.write(dev.of(out), out, buf + @as(usize, @intCast(w)), n - w, off + w);
            if (k <= 0) return port.kerror("short write");
            w += k;
        }
        off += n;
    }
}

/// Moves old to new, replacing a file there: the link old names, not
/// its target. Where the device can't, the default renames within one
/// directory by wstat, removing the file at new first, and is
/// "cross-device link" (Linux's EXDEV) across directories, where mv
/// copies.
pub fn rename(old: [*:0]const u8, new: [*:0]const u8) Error!void {
    const oc = try chan.namecx(old, c.Aaccess, 0, 0, true);
    defer chan.cclose(oc);
    if (oc.ismtpt != 0)
        return port.kerror(&port.Eismtpt);
    const p = try parent(new);
    defer p.deinit();
    if (try dev.rename(oc, p.dir, p.name))
        return;
    // The default: a wstat of the name, in old's own directory.
    const op = try parent(old);
    defer op.deinit();
    if (!chan.eqchan(op.dir, p.dir, true))
        return port.kerror(dev.Exdev);
    if (std.mem.orderZ(u8, op.name, p.name) == .eq)
        return;
    if (sysfile.remove(new)) |_| {} else |e| switch (e) {
        error.Interrupted => return e,
        error.Kernel => {},
    }
    var d: c.Dir = undefined;
    dev.nulldir(&d);
    d.name = @constCast(p.name);
    var buf: [c.STATFIXLEN + 512]u8 = undefined;
    const n = c.convD2M(&d, &buf, buf.len);
    if (n <= c.BIT16SZ)
        return port.kerror(&port.Etoolong);
    _ = try dev.wstat(dev.of(oc), oc, &buf, @intCast(n));
}

/// path's attributes, acting on a link if nofollow is set, and its Dir
/// (as stat(2) gives it) into dir, whose length is returned.
pub fn getattr(path: [*:0]const u8, nofollow: bool, mask: u64, a: *Attr, dir: [*]u8, ndir: c_int) Error!c_int {
    const ch = try chan.namecx(path, c.Aaccess, 0, 0, nofollow);
    defer chan.cclose(ch);
    return chanattr(ch, mask, a, dir, ndir);
}

/// fd's, as getattr.
pub fn fgetattr(fd: c_int, mask: u64, a: *Attr, dir: [*]u8, ndir: c_int) Error!c_int {
    const ch = try sysfile.fdtochan(fd, -1, false, true);
    defer chan.cclose(ch);
    return chanattr(ch, mask, a, dir, ndir);
}

fn chanattr(ch: *Chan, mask: u64, a: *Attr, dir: [*]u8, ndir: c_int) Error!c_int {
    const n = try sysfile.chanstat(ch, dir, ndir);
    if (dev.hasgetattr(ch)) {
        try dev.getattr(ch, mask, a);
        return n;
    }
    // The default, from the Dir already read.
    var d: c.Dir = undefined;
    const strs: [*]u8 = @ptrCast(c.smalloc(@intCast(n)));
    defer c.free(strs);
    if (n <= c.BIT16SZ or c.convM2D(dir, @intCast(n), &d, @ptrCast(strs)) == 0)
        return port.kerror(&port.Ebadstat);
    dev.attrfromdir(&d, a);
    return n;
}

/// Sets what mask names of path's attributes from a.
pub fn setattr(path: [*:0]const u8, nofollow: bool, mask: u64, a: *const Attr) Error!void {
    const ch = try chan.namecx(path, c.Aaccess, 0, 0, nofollow);
    defer chan.cclose(ch);
    if (ch.ismtpt != 0 and mask & c.Amode != 0)
        return port.kerror(&port.Eismtpt);
    try dev.setattr(ch, mask, a);
}

/// fd's, as setattr.
pub fn fsetattr(fd: c_int, mask: u64, a: *const Attr) Error!void {
    const ch = try sysfile.fdtochan(fd, -1, true, true);
    defer chan.cclose(ch);
    try dev.setattr(ch, mask, a);
}

/// Makes what was written to fd's file durable, only its data if
/// datasync (the device switch's fsync, Part 3).
pub fn fsync(fd: c_int, datasync: bool) Error!void {
    const ch = try sysfile.fdtochan(fd, -1, false, true);
    defer chan.cclose(ch);
    try dev.fsync(ch, datasync);
}

// The C names, with sysfile.zig's contract.

fn call(comptime f: anytype, args: anytype, fail: anytype) @TypeOf(fail) {
    port.assert(up().nerrlab == 0);
    const r = @call(.auto, f, args) catch {
        const p = up();
        const s = p.syserrstr;
        p.syserrstr = p.errstr;
        p.errstr = s;
        return fail;
    };
    up().notepending = 0;
    return r;
}

fn c_readlink(path: [*:0]const u8, buf: [*]u8, n: c_int) callconv(.c) c_int {
    if (n <= 0) return -1;
    const r = call(readlink, .{ path, buf[0..@intCast(n)] }, @as(usize, std.math.maxInt(usize)));
    return if (r == std.math.maxInt(usize)) -1 else @intCast(r);
}
fn c_symlink(path: [*:0]const u8, target: [*:0]const u8) callconv(.c) c_int {
    return call(struct {
        fn f(p: [*:0]const u8, t: [*:0]const u8) Error!c_int {
            try symlink(p, t);
            return 0;
        }
    }.f, .{ path, target }, @as(c_int, -1));
}
fn c_link(old: [*:0]const u8, new: [*:0]const u8, follow: c_int) callconv(.c) c_int {
    return call(struct {
        fn f(o: [*:0]const u8, n: [*:0]const u8, fl: bool) Error!c_int {
            try link(o, n, fl);
            return 0;
        }
    }.f, .{ old, new, follow != 0 }, @as(c_int, -1));
}
fn c_rename(old: [*:0]const u8, new: [*:0]const u8) callconv(.c) c_int {
    return call(struct {
        fn f(o: [*:0]const u8, n: [*:0]const u8) Error!c_int {
            try rename(o, n);
            return 0;
        }
    }.f, .{ old, new }, @as(c_int, -1));
}
fn c_getattr(path: [*:0]const u8, nofollow: c_int, mask: u64, a: *Attr, dir: [*]u8, ndir: c_int) callconv(.c) c_int {
    return call(getattr, .{ path, nofollow != 0, mask, a, dir, ndir }, @as(c_int, -1));
}
fn c_fgetattr(fd: c_int, mask: u64, a: *Attr, dir: [*]u8, ndir: c_int) callconv(.c) c_int {
    return call(fgetattr, .{ fd, mask, a, dir, ndir }, @as(c_int, -1));
}
fn c_setattr(path: [*:0]const u8, nofollow: c_int, mask: u64, a: *const Attr) callconv(.c) c_int {
    return call(struct {
        fn f(p: [*:0]const u8, nf: bool, m: u64, at: *const Attr) Error!c_int {
            try setattr(p, nf, m, at);
            return 0;
        }
    }.f, .{ path, nofollow != 0, mask, a }, @as(c_int, -1));
}
fn c_fsetattr(fd: c_int, mask: u64, a: *const Attr) callconv(.c) c_int {
    return call(struct {
        fn f(d: c_int, m: u64, at: *const Attr) Error!c_int {
            try fsetattr(d, m, at);
            return 0;
        }
    }.f, .{ fd, mask, a }, @as(c_int, -1));
}

fn c_fsync(fd: c_int, datasync: c_int) callconv(.c) c_int {
    return call(struct {
        fn f(d: c_int, ds: bool) Error!c_int {
            try fsync(d, ds);
            return 0;
        }
    }.f, .{ fd, datasync != 0 }, @as(c_int, -1));
}

/// The switch's optional operations for C, which raise: the overlay's
/// up layers and copy-ups make links in whatever device a layer is.
fn c_devreadlink(ch: *Chan, buf: [*]u8, n: c_int) callconv(.c) c_int {
    if (n <= 0) return -1;
    const r = dev.readlink(ch, buf[0..@intCast(n)]) catch |e| port.raise(e);
    return if (r) |k| @intCast(k) else -1;
}
fn c_devsymlink(ch: *Chan, name: [*:0]const u8, target: [*:0]const u8) callconv(.c) void {
    dev.symlink(ch, name, target) catch |e| port.raise(e);
}
/// 0 once linked or renamed, or 1 if the device can't, as a Devx's are.
fn c_devlink(ch: *Chan, dir: *Chan, name: [*:0]const u8) callconv(.c) c_int {
    return @intFromBool(!(dev.link(ch, dir, name) catch |e| port.raise(e)));
}
fn c_devrename(ch: *Chan, dir: *Chan, name: [*:0]const u8) callconv(.c) c_int {
    return @intFromBool(!(dev.rename(ch, dir, name) catch |e| port.raise(e)));
}
fn c_devgetattr(ch: *Chan, mask: u64, a: *Attr) callconv(.c) void {
    dev.getattr(ch, mask, a) catch |e| port.raise(e);
}

pub fn exportC() void {
    @export(&c_readlink, .{ .name = "h9_readlink" });
    @export(&c_symlink, .{ .name = "h9_symlink" });
    @export(&c_link, .{ .name = "h9_link" });
    @export(&c_rename, .{ .name = "h9_rename" });
    @export(&c_getattr, .{ .name = "h9_getattr" });
    @export(&c_fgetattr, .{ .name = "h9_fgetattr" });
    @export(&c_setattr, .{ .name = "h9_setattr" });
    @export(&c_fsetattr, .{ .name = "h9_fsetattr" });
    @export(&c_fsync, .{ .name = "h9_fsync" });
    @export(&c_devreadlink, .{ .name = "devreadlink" });
    @export(&c_devsymlink, .{ .name = "devsymlink" });
    @export(&c_devlink, .{ .name = "devlink" });
    @export(&c_devrename, .{ .name = "devrename" });
    @export(&c_devgetattr, .{ .name = "devgetattr" });
}

const testing = std.testing;
const kt = port.testing;

test "a device without the operations gets getattr from stat, and no links [file-interface]" {
    _ = try kt.namespace();
    _ = try sysfile.bind("#|", "/mnt", c.MAFTER);
    var a: Attr = undefined;
    var dir: [512]u8 = undefined;
    _ = try getattr("/mnt/factotum", false, c.Abasic, &a, &dir, dir.len);
    try testing.expect(a.mode & c.DMDIR != 0);
    try testing.expect(a.valid & c.Amode != 0);
    // stat says nothing of these, so the default doesn't either.
    try testing.expect(a.valid & (c.Anlink | c.Auid) == 0);
    _ = try getattr("/mnt/data", false, c.Abasic, &a, &dir, dir.len);
    try testing.expect(a.mode & c.DMDIR == 0);
    // Only a link has a target.
    var buf: [64]u8 = undefined;
    try testing.expectError(error.Kernel, readlink("/mnt/data", &buf));
    try testing.expectEqualStrings("not a symbolic link", kt.errstr());
    try testing.expectError(error.Kernel, symlink("/mnt/ln", "data"));
    // The default rename is a wstat in one directory: across two, it's
    // Linux's EXDEV, for mv to copy.
    try testing.expectError(error.Kernel, rename("/mnt/data", "/mnt/factotum/data"));
    try testing.expectEqualStrings(dev.Exdev, kt.errstr());
}
