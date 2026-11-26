//! drawterm's devroot.c (design/kernel-port.md): the root device, `#/`,
//! with its directories and boot files. A close translation: the same
//! functions in the same order, with error unions in place of waserror.
//! A native device (dev.zig's `Native`).

const std = @import("std");
const port = @import("../port.zig");
const dev = @import("../dev.zig");
const c = port.c;
const Error = port.Error;

const Chan = c.Chan;
const Dir = c.Dir;
const Dirtab = c.Dirtab;
const Walkqid = c.Walkqid;
const Qid = c.Qid;

const Qdir = 0;
const Qboot = 0x1000;
const Qmnt = 0x2000;
const Qfactotum = Qmnt + 1;

const Nrootfiles = 32;
const Nbootfiles = 32;
const Nmntfiles = 2;

const Dirlist = struct {
    base: c_uint,
    dir: [*]Dirtab,
    data: [*]?[*]const u8,
    ndir: c_int,
    mdir: c_int,
};

fn dirs(comptime n: usize, comptime first: []const Dirtab) [n]Dirtab {
    var d: [n]Dirtab = @splat(std.mem.zeroes(Dirtab));
    for (first, 0..) |f, i| d[i] = f;
    return d;
}

const qdir: Qid = .{ .path = Qdir, .vers = 0, .type = c.QTDIR };
const qboot: Qid = .{ .path = Qboot, .vers = 0, .type = c.QTDIR };
const qmnt: Qid = .{ .path = Qmnt, .vers = 0, .type = c.QTDIR };

var rootdir = dirs(Nrootfiles, &.{
    dev.dirtab("#/", qdir, 0, dev.dmdir | 0o555),
    dev.dirtab("boot", qboot, 0, dev.dmdir | 0o555),
    dev.dirtab("mnt", qmnt, 0, dev.dmdir | 0o555),
});
var rootdata: [Nrootfiles]?[*]const u8 = @splat(null);
var rootlist: Dirlist = .{
    .base = 0,
    .dir = &rootdir,
    .data = &rootdata,
    .ndir = 3,
    .mdir = Nrootfiles,
};

var bootdir = dirs(Nbootfiles, &.{
    dev.dirtab("boot", qboot, 0, dev.dmdir | 0o555),
});
var bootdata: [Nbootfiles]?[*]const u8 = @splat(null);
var bootlist: Dirlist = .{
    .base = Qboot,
    .dir = &bootdir,
    .data = &bootdata,
    .ndir = 1,
    .mdir = Nbootfiles,
};

var mntdata: [Nmntfiles]?[*]const u8 = @splat(null);
var mntdir = dirs(Nmntfiles, &.{
    dev.dirtab("mnt", qmnt, 0, dev.dmdir | 0o555),
    dev.dirtab("factotum", .{ .path = Qfactotum, .vers = 0, .type = c.QTDIR }, 0, dev.dmdir | 0o555),
});
var mntlist: Dirlist = .{
    .base = Qmnt,
    .dir = &mntdir,
    .data = &mntdata,
    .ndir = 2,
    .mdir = Nmntfiles,
};

/// add a file to the list
fn addlist(l: *Dirlist, name: []const u8, contents: ?[*]const u8, len: c_uint, perm: c_int) void {
    if (l.ndir >= l.mdir)
        port.kpanic("too many root files", .{});
    const n: usize = @intCast(l.ndir);
    l.data[n] = contents;
    const d = &l.dir[n];
    @memcpy(d.name[0..name.len], name);
    d.name[name.len] = 0;
    d.length = len;
    d.perm = perm;
    d.qid.type = 0;
    d.qid.vers = 0;
    l.ndir += 1;
    d.qid.path = @as(u64, @intCast(l.ndir)) + l.base;
    if (perm & dev.dmdir != 0)
        d.qid.type |= c.QTDIR;
}

/// add a root file
pub fn addbootfile(name: [*:0]const u8, contents: [*]const u8, len: c_uint) callconv(.c) void {
    addlist(&bootlist, std.mem.span(name), contents, len, 0o555);
}

/// add a root directory
fn addrootdir(name: []const u8) void {
    addlist(&rootlist, name, null, 0, dev.dmdir | 0o555);
}

fn rootreset() void {
    addrootdir("bin");
    addrootdir("dev");
    addrootdir("env");
    addrootdir("fd");
    addrootdir("net");
    addrootdir("net.alt");
    addrootdir("proc");
    addrootdir("root");
    addrootdir("srv");
}

fn rootattach(spec: [*:0]const u8) Error!*Chan {
    return dev.devattach('/', spec);
}

fn rootgen(ch_: [*c]Chan, name: [*c]u8, dirt: [*c]Dirtab, ndirt: c_int, s: c_int, dp: [*c]Dir) callconv(.c) c_int {
    _ = dirt;
    _ = ndirt;
    const ch: *Chan = ch_;

    switch (ch.qid.path) {
        Qdir => {
            if (s == c.DEVDOTDOT) {
                dev.devdir(ch, qdir, @constCast("#/"), 0, c.eve, 0o555, dp);
                return 1;
            }
            return dev.devgen(ch, name, rootlist.dir, rootlist.ndir, s, dp);
        },
        Qmnt => {
            if (s == c.DEVDOTDOT) {
                dev.devdir(ch, qdir, @constCast("#/"), 0, c.eve, 0o555, dp);
                return 1;
            }
            return dev.devgen(ch, name, mntlist.dir, mntlist.ndir, s, dp);
        },
        Qboot => {
            if (s == c.DEVDOTDOT) {
                dev.devdir(ch, qdir, @constCast("#/"), 0, c.eve, 0o555, dp);
                return 1;
            }
            return dev.devgen(ch, name, bootlist.dir, bootlist.ndir, s, dp);
        },
        else => {
            if (s == c.DEVDOTDOT) {
                var tqiddir = qdir;
                tqiddir.path = ch.qid.path & 0xF000;
                dev.devdir(ch, tqiddir, @constCast("#/"), 0, c.eve, 0o555, dp);
                return 1;
            }
            if (s != 0)
                return -1;
            var t: i64 = undefined;
            var l: *Dirlist = undefined;
            switch (ch.qid.path & 0xF000) {
                Qdir => {
                    t = @as(i64, @bitCast(ch.qid.path)) - 1;
                    l = &rootlist;
                },
                Qboot => {
                    t = @as(i64, @bitCast(ch.qid.path)) - Qboot - 1;
                    l = &bootlist;
                },
                Qmnt => {
                    t = @as(i64, @bitCast(ch.qid.path)) - Qmnt - 1;
                    l = &mntlist;
                },
                else => return -1,
            }
            if (t >= l.ndir)
                return -1;
            if (t < 0) {
                port.print("rootgen %llud %d %d\n", .{ ch.qid.path, s, @as(c_int, @intCast(t)) });
                port.kpanic("whoops", .{});
            }
            const d = &l.dir[@intCast(t)];
            dev.devdir(ch, d.qid, &d.name, d.length, c.eve, d.perm, dp);
            return 1;
        },
    }
    return -1;
}

fn rootwalk(ch: *Chan, nc: ?*Chan, name: [*]const [*:0]const u8, nname: c_int) Error!?*Walkqid {
    return dev.devwalk(ch, nc, name, nname, null, 0, &rootgen);
}

fn rootstat(ch: *Chan, dp: [*]u8, n: c_int) Error!c_int {
    return dev.devstat(ch, dp, n, null, 0, &rootgen);
}

fn rootopen(ch: *Chan, omode: c_int) Error!*Chan {
    return dev.devopen(ch, omode, null, 0, dev.devgenC());
}

/// sysremove() knows this is a nop
fn rootclose(ch: *Chan) Error!void {
    _ = ch;
}

fn rootread(ch: *Chan, buf: ?*anyopaque, n_: c_int, off: i64) Error!c_int {
    var t: u64 = ch.qid.path;
    var n: u64 = @intCast(n_);
    const offset: u64 = @as(c_uint, @truncate(@as(u64, @bitCast(off))));

    switch (t) {
        Qdir, Qboot, Qmnt => return dev.devdirread(ch, @ptrCast(buf.?), n_, null, 0, &rootgen),
        else => {},
    }

    var l: *Dirlist = undefined;
    if (t & Qboot != 0)
        l = &bootlist
    else if (t & Qmnt != 0)
        l = &mntlist
    else
        l = &bootlist;
    t &= 0xFFF;
    t -%= 1;

    if (t >= l.ndir)
        return port.kerror(&port.Egreg);

    const d = &l.dir[@intCast(t)];
    const data = l.data[@intCast(t)];
    const length: u64 = @bitCast(d.length);
    if (offset >= length)
        return 0;
    if (offset + n > length)
        n = length - offset;
    const dst: [*]u8 = @ptrCast(buf.?);
    @memcpy(dst[0..@intCast(n)], data.?[@intCast(offset)..][0..@intCast(n)]);
    return @intCast(n);
}

fn rootwrite(ch: *Chan, v: ?*const anyopaque, n: c_int, o: i64) Error!c_int {
    _ = ch;
    _ = v;
    _ = n;
    _ = o;
    return port.kerror(&port.Egreg);
}

pub const Device = dev.Native('/', "root", .{
    .reset = rootreset,
    .attach = rootattach,
    .walk = rootwalk,
    .stat = rootstat,
    .open = rootopen,
    .create = dev.devcreate,
    .close = rootclose,
    .read = rootread,
    .write = rootwrite,
    .remove = dev.devremove,
    .wstat = dev.devwstat,
    .gens = &.{&rootgen},
});

pub fn exportC() void {
    @export(&Device.dev, .{ .name = "rootdevtab" });
    @export(&addbootfile, .{ .name = "addbootfile" });
}

const testing = std.testing;
const kt = port.testing;
const sysfile = @import("../sysfile.zig");

test "#/ lists its directories, and a boot file reads what was added [kernel-port]" {
    _ = try kt.namespace();
    var buf: [2048]u8 = undefined;
    const fd = try sysfile.open("#/", c.OREAD);
    const n: usize = @intCast(try sysfile.pread(fd, &buf, buf.len, -1));
    _ = try sysfile.close(fd);
    var names: [32][]const u8 = undefined;
    var nn: usize = 0;
    var strs: [256]u8 = undefined;
    var off: usize = 0;
    defer for (names[0..nn]) |x| testing.allocator.free(x);
    while (off < n) : (nn += 1) {
        var d: Dir = undefined;
        const sz = c.convM2D(buf[off..].ptr, @intCast(n - off), &d, &strs);
        try testing.expect(sz != 0);
        names[nn] = try testing.allocator.dupe(u8, std.mem.span(d.name));
        off += sz;
    }
    for ([_][]const u8{ "boot", "mnt", "bin", "dev", "env", "fd", "net", "net.alt", "proc", "root", "srv" }) |want| {
        for (names[0..nn]) |x| {
            if (std.mem.eql(u8, x, want)) break;
        } else return error.Missing;
    }

    const contents = "a boot file\n";
    addbootfile("kernport-test", contents, contents.len);
    // (Not "#/boot/...": that's the root device with the spec "boot".)
    const bfd = try sysfile.open("/boot/kernport-test", c.OREAD);
    defer _ = sysfile.close(bfd) catch {};
    const m = try sysfile.pread(bfd, &buf, buf.len, 2);
    try testing.expectEqualStrings(contents[2..], buf[0..@intCast(m)]);
    try testing.expectError(error.Kernel, sysfile.pwrite(bfd, "x", 1, 0));
}
