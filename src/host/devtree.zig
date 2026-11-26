//! The tree device, `#ū` (design/host-handles.md): a directory handle
//! with no host directory beneath it, an embedder's tree in memory
//! (`host.Tree`, such as `host.MemTree`), served read-only. `#ū<name>` is
//! the tree of the machine's handle `name`; namec walks a `#U` path that
//! such a handle holds here instead (src/kern/chan.zig), so a mount of
//! the handle's path, the root's among them, reaches it. A chan's aux is
//! the tree, and its qid's path the entry's number.

const std = @import("std");
const kern = @import("kern");

const port = kern;
const c = kern.c;
const dev = kern.dev;
const Error = port.Error;
const Chan = c.Chan;
const Dir = c.Dir;
const Dirtab = c.Dirtab;
const Walkqid = c.Walkqid;
const Qid = c.Qid;

/// ū, a #U beside #U.
pub const dc: c_int = 0x16B;

// src/kern.zig's leaves: the calling thread's machine's trees.
const Entry = extern struct {
    id: u64,
    len: u64,
    name: [*:0]const u8,
    dir: u8,
    exec: u8,
};
extern fn h9_tree_get(name: [*]const u8, len: c_int) ?*const anyopaque;
extern fn h9_tree_entry(t: *const anyopaque, id: u64, out: *Entry) c_int;
extern fn h9_tree_child(t: *const anyopaque, id: u64, i: c_int, out: *Entry) c_int;
extern fn h9_tree_parent(t: *const anyopaque, id: u64) u64;
extern fn h9_tree_read(t: *const anyopaque, id: u64, off: u64, buf: [*]u8, n: c_int) c_int;

fn treeOf(ch: *Chan) *const anyopaque {
    return dev.aux(ch).*.?;
}

fn qidOf(e: Entry) Qid {
    var q: Qid = undefined;
    dev.mkqid(&q, @bitCast(e.id), 0, if (e.dir != 0) c.QTDIR else c.QTFILE);
    return q;
}

fn dirOf(ch: *Chan, e: Entry, dp: *Dir) void {
    const perm: c_int = if (e.dir != 0) dev.dmdir | 0o555 else if (e.exec != 0) 0o555 else 0o444;
    dev.devdir(ch, qidOf(e), @constCast(e.name), @intCast(e.len), c.eve, perm, dp);
}

/// A directory's children as s counts them; for a file, its siblings, so
/// devstat finds it.
fn treegen(ch_: [*c]Chan, name_: [*c]u8, _: [*c]Dirtab, _: c_int, s: c_int, dp: [*c]Dir) callconv(.c) c_int {
    const ch: *Chan = ch_;
    const t = treeOf(ch);
    var e: Entry = undefined;
    if (s == c.DEVDOTDOT) {
        if (h9_tree_entry(t, h9_tree_parent(t, ch.qid.path), &e) != 0) return -1;
        dirOf(ch, e, dp);
        return 1;
    }
    const at = if (ch.qid.type & c.QTDIR != 0) ch.qid.path else h9_tree_parent(t, ch.qid.path);
    if (name_ != null) {
        const name = std.mem.span(@as([*:0]const u8, name_));
        var i: c_int = 0;
        while (h9_tree_child(t, at, i, &e) == 0) : (i += 1) {
            if (std.mem.eql(u8, std.mem.span(e.name), name)) {
                dirOf(ch, e, dp);
                return 1;
            }
        }
        return -1;
    }
    if (h9_tree_child(t, at, s, &e) != 0) return -1;
    dirOf(ch, e, dp);
    return 1;
}

fn attach(spec: [*:0]const u8) Error!*Chan {
    const name = std.mem.span(spec);
    const t = h9_tree_get(name.ptr, @intCast(name.len)) orelse return port.kerror(&port.Enonexist);
    const ch = dev.devattach(dc, spec);
    dev.aux(ch).* = @constCast(t);
    return ch;
}

fn walk(ch: *Chan, nc: ?*Chan, name: [*]const [*:0]const u8, nname: c_int) Error!?*Walkqid {
    return dev.devwalk(ch, nc, name, nname, null, 0, &treegen);
}

fn stat(ch: *Chan, db: [*]u8, n: c_int) Error!c_int {
    var e: Entry = undefined;
    if (h9_tree_entry(treeOf(ch), ch.qid.path, &e) != 0) return port.kerror(&port.Enonexist);
    var d: Dir = undefined;
    dirOf(ch, e, &d);
    // The top is named by the chan, as devstat names a directory.
    if (ch.qid.path == 0) d.name = @constCast("/");
    if (ch.flag & c.CMSG != 0) d.mode |= c.DMMOUNT;
    const r = c.convD2M(&d, db, @intCast(n));
    if (r == 0) return port.kerror(&port.Ebadarg);
    return @intCast(r);
}

fn open(ch: *Chan, omode: c_int) Error!*Chan {
    const mode = omode & 3;
    if (omode & (c.OTRUNC | c.ORCLOSE) != 0 or (mode != c.OREAD and mode != c.OEXEC))
        return port.kerror(&port.Eperm);
    if (ch.qid.type & c.QTDIR != 0 and mode != c.OREAD) return port.kerror(&port.Eisdir);
    ch.mode = @intCast(try port.sysfile.openmode(@bitCast(omode)));
    ch.offset = 0;
    ch.flag |= c.COPEN;
    return ch;
}

fn close(_: *Chan) Error!void {}

fn read(ch: *Chan, a: ?*anyopaque, n: c_int, off: i64) Error!c_int {
    if (ch.qid.type & c.QTDIR != 0) return dev.devdirread(ch, @ptrCast(a.?), n, null, 0, &treegen);
    if (n <= 0 or off < 0) return 0;
    return h9_tree_read(treeOf(ch), ch.qid.path, @intCast(off), @ptrCast(a.?), n);
}

fn create(_: *Chan, _: [*:0]const u8, _: c_int, _: c_uint) Error!*Chan {
    return port.kerror(&port.Eperm);
}

fn write(_: *Chan, _: ?*const anyopaque, _: c_int, _: i64) Error!c_int {
    return port.kerror(&port.Eperm);
}

fn remove(_: *Chan) Error!void {
    return port.kerror(&port.Eperm);
}

fn wstat(_: *Chan, _: [*]u8, _: c_int) Error!c_int {
    return port.kerror(&port.Eperm);
}

pub const Device = dev.Native(dc, "tree", .{
    .attach = attach,
    .walk = walk,
    .stat = stat,
    .open = open,
    .create = create,
    .close = close,
    .read = read,
    .write = write,
    .remove = remove,
    .wstat = wstat,
    .gens = &.{&treegen},
});

pub fn exportC() void {
    @export(&Device.dev, .{ .name = "treedevtab" });
}
