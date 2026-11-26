//! h9's devoverlay.c (design/kernel-port.md): `#O`, copy-on-write
//! overlays (design/epoch-0/ephemeral-writes.md) and unions
//! (design/epoch-0/mounts.md). A close translation: the same functions
//! in the same order, with error unions in place of waserror. A native
//! device (dev.zig's `Native`), with readlink, symlink, getattr, and
//! rename as optional operations of its `dev.Ops`.
//!
//! An instance is a tree in memory, optionally above a lower directory
//! (a chan of another device, usually #U). Walks look in memory first and
//! fall through to the lower tree, whose own checks (devfs's h9_fs_check,
//! --read-deny, symlink resolution) apply. Creates, writes, removes and
//! renames land in memory: a lower file is copied up whole the first time
//! it's changed, and a removed lower name is hidden by a whiteout. The
//! lower tree is never written.
//!
//! Each node in the memory tree is one of:
//!    Ncopy    a file or directory that exists in memory, with its own data
//!        and Dir; a copied directory has nothing beneath it in the lower
//!        tree
//!    Nwhite    a name removed from the lower tree
//!    Nmark    a lower directory with changed children in memory; its Dir is
//!        a snapshot of the lower one's and its qid is the lower qid
//!    Nlink    a symbolic link made by the Linux ABI (symlink below),
//!        holding its target. A walk follows it, as devfs follows a contained
//!        tree's links: an absolute target from the instance root, a
//!        relative one from the link's directory. The chan keeps the link
//!        beside the target, so remove and rename act on the link, and
//!        readlink reads it. A final link whose target is
//!        missing is walked to as itself, and opening it fails. Its qid
//!        has H9_QTSYMLINK. A Linux process's walk doesn't follow it,
//!        or a lower tree's link: it stops there, for the kernel's walk
//!        to follow from the process's root (design/epoch-0/linux-symlinks.md).
//!    Nfifo    a FIFO made by the Linux ABI (h9_overlay_mkfifo,
//!        design/epoch-0/linux-fifo.md): a file with no data, whose Dir has
//!        H9_DMFIFO. A Linux open of it joins a pipe (src/kern/fifo.c);
//!        a Plan 9 program reads it as empty and can't write it.
//!
//! Memory: data blocks, nodes, names and strings all come from the
//! machine's guest-physical page allocator through Zig leaves
//! (h9_overlay_alloc, src/kern.zig), so they count against --memory. Data
//! is a list of page-sized blocks. Nodes and strings come from a small
//! size-class allocator on the same pages, which returns its pages when the
//! instance is freed. Running out fails the operation with "file system
//! full" and changes nothing.
//!
//! Instances are made by the namespace builder (h9_overlay_new, or
//! h9_overlay_newpath from Zig) and bound with `bind '#O<n>' target`.
//! Attaching checks that the instance belongs to the caller's machine, so
//! machines in one host process can't reach each other's. The last close
//! of the last chan on an instance frees it.
//!
//! Tracking: once h9_overlay_track gives an instance a tracker, each
//! create, copy-up, remove and wstat calls h9_overlay_changed with the
//! changed path, for the root overlay's discarded-changes notice
//! (design/epoch-0/overlay.md). Writes to a file already in memory aren't
//! reported again: its create or copy-up was.
//!
//! Locking: each instance's tree is guarded by its QLock, held across
//! lower-device calls made for walks, copy-ups and directory reads. The
//! instance table is guarded by a Lock, which also guards instance
//! reference counts.

const std = @import("std");
const port = @import("../port.zig");
const sync = @import("../sync.zig");
const dev = @import("../dev.zig");
const chan = @import("../chan.zig");
const sysfile = @import("../sysfile.zig");
const devmnt = @import("../devmnt.zig");
const c = port.c;
const up = port.up;
const Error = port.Error;
const kerror = port.kerror;

const Chan = c.Chan;
const Dir = c.Dir;
const Dirtab = c.Dirtab;
const Qid = c.Qid;
const Walkqid = c.Walkqid;
const Attr = c.Attr;

// Implemented in Zig (src/kern.zig). They never raise kernel errors.
extern fn h9_overlay_pool() ?*anyopaque;
extern fn h9_overlay_alloc(pool: ?*anyopaque, n: c_uint) ?*anyopaque;
extern fn h9_overlay_free(pool: ?*anyopaque, p: ?*anyopaque, n: c_uint) void;
extern fn h9_overlay_changed(track: ?*anyopaque, path: [*:0]const u8) void;
// src/kern/fscheck.c
extern fn h9_plan_get() ?*anyopaque;
extern fn h9_fs_linkwalk() c_int;
extern fn h9_clock_mono() i64;
// devfs's (src/kern/fscheck.h), which doesn't raise.
extern fn h9_fs_isfifo(ch: *Chan) c_int;
// fscheck.c's, which can raise (a 9P server's stat); only an exported
// function with nothing to undo calls it.
extern fn h9_fs_chanisfifo(ch: *Chan) c_int;
// devfs's h9_fs_mkfifo, as a call that returns -1 with the error set.
extern fn h9_fs_mkfifoz(ch: *Chan, name: [*:0]const u8, perm: c_uint) c_int;

// src/kern/fscheck.h's.
const H9_DMFIFO: c_uint = 0x00200000;
const H9_QTSYMLINK: u8 = 0x02;
const H9_DMSYMLINK: c_uint = 0x02000000;
const H9_ELOOP = "too many symbolic links";

const QTDIR: u8 = c.QTDIR;
const QTFILE: u8 = c.QTFILE;
const DMDIR: c_uint = @as(c_uint, c.DMDIR);
const DMEXCL: c_uint = @as(c_uint, c.DMEXCL);
const DMAPPEND: c_uint = @as(c_uint, c.DMAPPEND);
const OREAD: c_int = c.OREAD;
const OWRITE: c_int = c.OWRITE;
const ORDWR: c_int = c.ORDWR;
const OEXEC: c_int = c.OEXEC;
const OTRUNC: c_int = c.OTRUNC;
const ORCLOSE: c_int = c.ORCLOSE;
const OCEXEC: c_int = c.OCEXEC;
const OEXCL: c_int = c.OEXCL;
const COPEN: c_ushort = c.COPEN;
const CRCLOSE: c_ushort = c.CRCLOSE;
const BIT16SZ = c.BIT16SZ;
const ERRMAX = c.ERRMAX;
const nulldir: c_uint = std.math.maxInt(c_uint);

const Pgsize = 4096; // engine.page_size
const Ndirect = 8; // data blocks held in the node
const Perpage = Pgsize / @sizeOf(?*anyopaque);
const Minclass = 5; // 32 bytes
const Nclass = 7; // 32..2048
const Pghdr = 16; // per-page header of the small allocator
const Maxname = 1024;
const Maxinst = 256;
const Copybuf = 16 * Pgsize;

const Ncopy = 0;
const Nwhite = 1;
const Nmark = 2;
const Nlink = 3;
const Nfifo = 4;

const Maxlinks = 40; // links followed in one walk, as Linux allows

const Maxfile: i64 = (Ndirect + Perpage * Perpage) * Pgsize;
const Copybit: u64 = 1 << 63;

const Efull = "file system full";
const Enotempty = "directory not empty";
const Elocked = "file is locked"; // ramfs's

const Cow = 0;
const Union = 1;

const Maxmembers = 64;
const Qbuckets = 256;

/// A union's member: a tree, rooted at a path in the union.
const Member = extern struct {
    id: c_int,
    root: *Chan,
    at: [*c]u8, // "" for the union's top, or a path such as "etc"
    create: c_int, // creates may go here (bind -c)
    isup: c_int, // the writable layer over the others (bind -u); only ever mem[0]
};

const Qmap = extern struct {
    next: ?*Qmap,
    type: c_int,
    dev: c_uint,
    path: u64,
    qpath: u64,
};

const Pg = extern struct {
    next: ?*Pg,
};

const Chunk = extern struct {
    next: ?*Chunk,
};

const Node = extern struct {
    kind: c_int,
    ref: c_int, // chans holding it, plus 1 while it's in the tree
    inlower: c_int, // the lower tree has this name here
    parent: ?*Node, // nil once detached
    child: ?*Node,
    next: ?*Node,
    prev: ?*Node, // in the parent's child list, for unlinking in O(1)
    hnext: ?*Node, // in the parent's hash chain
    htab: ?[*]?*Node, // a directory's children by name, once it has many; host memory
    hsize: c_int,
    nchild: c_int,
    name: [*c]u8,
    uid: [*c]u8,
    gid: [*c]u8,
    muid: [*c]u8,
    qid: Qid,
    mode: c_uint,
    atime: c_uint,
    mtime: c_uint,
    length: i64,
    direct: [Ndirect]?[*]u8,
    ind: ?[*]?[*]?[*]u8, // Perpage pointers to pages of Perpage block pointers
    link: [*c]u8, // an Nlink's target
    excl: c_int, // a DMEXCL file that a chan has open
};

const Inst = extern struct {
    id: c_int,
    ref: c_int, // under instlock
    pinned: c_int, // made, not attached yet: the first attach takes this ref
    pool: ?*anyopaque,
    ql: c.QLock,
    lower: ?*Chan, // root of the lower tree, or nil
    root: ?*Node,
    qidgen: u64,
    pages: ?*Pg, // the small allocator's pages
    free: [Nclass]?*Chunk,
    track: ?*anyopaque, // told of each change once set (h9_overlay_track), or nil

    // Unions (design/epoch-0/mounts.md, "Union instances"); see below.
    mode: c_int, // Cow or Union
    name: [16]u8, // a named union's name ("root", "linux"), or ""
    cow: ?*Inst, // a named union's copy-on-write instance over it, not counted in ref
    over: ?*Inst, // a cow instance's named union, which points back here
    mem: ?[*]Member, // the members, top first; host memory
    nmem: c_int,
    memgen: c_int, // the next member's id
    qtab: ?[*]?*Qmap, // (device, dev, qid path) to the instance's qid path
    qmem: u32, // bytes of qid table and snapshots, counted against the pool
    upql: c.QLock, // serializes changes to an up member's tree (design/epoch-0/upper-layers.md)
    upgen: u32, // counts directories made in the up member's tree; under ql
    wcl: c.QLock, // the walk cache's lock
    wc: ?*Wcache, // the walk cache (unstep), made on first use; under wcl

    fn members(in: *Inst) []Member {
        return in.mem.?[0..@intCast(in.nmem)];
    }
};

/// A chan's state.
const Ovc = extern struct {
    inst: *Inst,
    node: ?*Node, // with a ref, or nil for a lower-only name
    lower: ?*Chan, // the lower chan for this name, or nil
    path: [*c]u8, // names from the instance root, '/'-separated
    lopen: c_int, // lower is open; I/O goes to it
    dir: [*c]u8, // directory snapshot
    ndir: c_int,
    lnk: ?*Node, // with a ref: the link the walk's last name followed, or nil
    lpath: [*c]u8, // lnk's path
    excl: c_int, // this chan holds node's DMEXCL open
    nlinks: c_int, // links followed in this walk
};

/// A union chan's state. Its first field is the instance, as an Ovc's is.
const Unc = extern struct {
    inst: *Inst,
    path: [*c]u8, // names from the union's top
    n: c_int, // members with this name
    mc: [Maxmembers]?*Chan, // their chans: one for a file, each one's directory for a directory
    mid: [Maxmembers]c_int, // their member ids
    mcreate: [Maxmembers]c_int,
    lopen: c_int, // mc[0] is open; file I/O goes to it
    dir: [*c]u8, // directory snapshot, from the pool
    ndir: c_int,
    dircap: c_int,
    noup: c_int, // walks leave out the up member: what's below the layer
    upseen: u32, // the instance's upgen when the members were found

    fn n0(u: *Unc) *Chan {
        return u.mc[0].?;
    }
};

// Small helpers for the C strings the state holds.

fn slen(s: [*c]const u8) usize {
    return std.mem.len(@as([*:0]const u8, @ptrCast(s)));
}

fn span(s: [*c]const u8) [:0]const u8 {
    return std.mem.span(@as([*:0]const u8, @ptrCast(s)));
}

fn eq(a: [*c]const u8, b: [*c]const u8) bool {
    return std.mem.orderZ(u8, @ptrCast(a), @ptrCast(b)) == .eq;
}

fn z(s: [*c]const u8) [*:0]const u8 {
    return @ptrCast(s);
}

/// The index of the last '/' in s, if it has one: strrchr.
fn lastslash(s: [*c]const u8) ?usize {
    return std.mem.lastIndexOfScalar(u8, span(s), '/');
}

/// strdup, from the kernel's malloc; nil if it's out of memory.
fn strdupn(s: [*c]const u8) [*c]u8 {
    const t = span(s);
    const p: [*]u8 = @ptrCast(port.malloc(t.len + 1) orelse return null);
    @memcpy(p[0 .. t.len + 1], t.ptr[0 .. t.len + 1]);
    return p;
}

/// strdup, or Enomem.
fn strdupe(s: [*c]const u8) Error![*c]u8 {
    const p = strdupn(s);
    if (p == null) return kerror(&port.Enomem);
    return p;
}

/// up->errstr = s, for a walk that ends with a name it didn't find.
fn seterr(s: [*:0]const u8) void {
    chan.kstrcpy(up().errstr, s, ERRMAX);
}

fn gbit16(p: [*c]const u8) c_int {
    return @as(c_int, p[0]) | (@as(c_int, p[1]) << 8);
}

fn now() c_uint {
    return @bitCast(@as(c_int, @truncate(c.seconds())));
}

fn auxof(ch: *Chan) ?*anyopaque {
    return dev.aux(ch).*;
}

fn ovcof(ch: *Chan) *Ovc {
    return @ptrCast(@alignCast(auxof(ch).?));
}

fn uncof(ch: *Chan) *Unc {
    return @ptrCast(@alignCast(auxof(ch).?));
}

/// The device's character.
fn dcof(ch: *Chan) c_int {
    return dev.of(ch).dc;
}

// The device switch, for the lower tree's chans and a union's members.

fn dwalk1(ch: *Chan, name: [*c]const u8) Error!?*Walkqid {
    var names = [1][*:0]const u8{z(name)};
    return dev.walkdev(dev.of(ch), ch, null, &names, 1);
}
fn dstat(ch: *Chan, db: [*]u8, n: c_int) Error!c_int {
    return dev.stat(dev.of(ch), ch, db, n);
}
fn dopen(ch: *Chan, omode: c_int) Error!*Chan {
    return dev.open(dev.of(ch), ch, omode);
}
fn dcreate(ch: *Chan, name: [*c]const u8, omode: c_int, perm: c_uint) Error!*Chan {
    return dev.create(dev.of(ch), ch, z(name), omode, perm);
}
fn dread(ch: *Chan, a: ?*anyopaque, n: c_int, off: i64) Error!c_int {
    return dev.read(dev.of(ch), ch, a, n, off);
}
fn dwrite(ch: *Chan, a: ?*const anyopaque, n: c_int, off: i64) Error!c_int {
    return dev.write(dev.of(ch), ch, a, n, off);
}
fn dremove(ch: *Chan) Error!void {
    return dev.remove(dev.of(ch), ch);
}
fn dwstat(ch: *Chan, db: [*]u8, n: c_int) Error!c_int {
    return dev.wstat(dev.of(ch), ch, db, n);
}

fn isunion(ch: *Chan) bool {
    if (isctl(ch)) return false; // h9: a clone chan's aux is a Ctl
    const o: *Ovc = @ptrCast(@alignCast(auxof(ch) orelse return false));
    return o.inst.mode == Union;
}

var instlock: c.Lock = std.mem.zeroes(c.Lock);
var insts: [Maxinst]?*Inst = @splat(null);
var nextid: c_int = 0;

// Pages and the small allocator.

fn pgalloc(in: *Inst) ?*anyopaque {
    return h9_overlay_alloc(in.pool, Pgsize);
}

fn pgfree(in: *Inst, p: ?*anyopaque) void {
    if (p != null)
        h9_overlay_free(in.pool, p, Pgsize);
}

fn sizeclass(n: usize) ?usize {
    var k: usize = 0;
    while (k < Nclass) : (k += 1)
        if (n <= (@as(usize, 1) << @intCast(Minclass + k)))
            return k;
    return null;
}

/// Zeroed memory for bookkeeping, or nil when the machine's memory is used up.
fn ovmalloc(in: *Inst, n: usize) ?*anyopaque {
    const k = sizeclass(n) orelse return null;
    const sz: usize = @as(usize, 1) << @intCast(Minclass + k);
    if (in.free[k] == null) {
        const p: [*]u8 = @ptrCast(pgalloc(in) orelse return null);
        const pg: *Pg = @ptrCast(@alignCast(p));
        pg.next = in.pages;
        in.pages = pg;
        var off: usize = Pghdr;
        while (off + sz <= Pgsize) : (off += sz) {
            const ck: *Chunk = @ptrCast(@alignCast(p + off));
            ck.next = in.free[k];
            in.free[k] = ck;
        }
    }
    const ck = in.free[k].?;
    in.free[k] = ck.next;
    const b: [*]u8 = @ptrCast(ck);
    @memset(b[0..sz], 0);
    return ck;
}

fn ovmfree(in: *Inst, p: ?*anyopaque, n: usize) void {
    const ck: *Chunk = @ptrCast(@alignCast(p orelse return));
    const k = sizeclass(n).?;
    ck.next = in.free[k];
    in.free[k] = ck;
}

fn ovnew(in: *Inst, comptime T: type) ?*T {
    return @ptrCast(@alignCast(ovmalloc(in, @sizeOf(T)) orelse return null));
}

fn ovstrdup(in: *Inst, s: [*c]const u8) [*c]u8 {
    const n = slen(s) + 1;
    const p: [*]u8 = @ptrCast(ovmalloc(in, n) orelse return null);
    @memcpy(p[0..n], s[0..n]);
    return p;
}

fn ovstrfree(in: *Inst, s: [*c]u8) void {
    if (s != null)
        ovmfree(in, s, slen(s) + 1);
}

// Data blocks.

/// The slot for block b, allocating index pages if alloc; nil if absent or out of memory.
fn blkslot(in: *Inst, n: *Node, b_: u64, alloc: bool) ?*?[*]u8 {
    var b = b_;
    if (b < Ndirect)
        return &n.direct[@intCast(b)];
    b -= Ndirect;
    const i_1: usize = @intCast(b / Perpage);
    const i_2: usize = @intCast(b % Perpage);
    if (i_1 >= Perpage)
        return null;
    if (n.ind == null) {
        if (!alloc) return null;
        n.ind = @ptrCast(@alignCast(pgalloc(in) orelse return null));
    }
    const ind = n.ind.?;
    if (ind[i_1] == null) {
        if (!alloc) return null;
        ind[i_1] = @ptrCast(@alignCast(pgalloc(in) orelse return null));
    }
    const pg: [*]?[*]u8 = @ptrCast(@alignCast(ind[i_1].?));
    return &pg[i_2];
}

/// Frees the blocks wholly at or beyond len, and zeroes the tail of the last one.
fn trimblocks(in: *Inst, n: *Node, len: i64) void {
    const first: u64 = @intCast(@divTrunc(len + Pgsize - 1, Pgsize));
    var b: u64 = first;
    while (b < Ndirect) : (b += 1) {
        pgfree(in, n.direct[@intCast(b)]);
        n.direct[@intCast(b)] = null;
    }
    if (n.ind) |ind| {
        var i: u64 = 0;
        while (i < Perpage) : (i += 1) {
            const pgp = ind[@intCast(i)] orelse continue;
            const pg: [*]?[*]u8 = @ptrCast(@alignCast(pgp));
            var j: u64 = 0;
            while (j < Perpage) : (j += 1) {
                b = Ndirect + i * Perpage + j;
                if (b >= first and pg[@intCast(j)] != null) {
                    pgfree(in, pg[@intCast(j)]);
                    pg[@intCast(j)] = null;
                }
            }
            if (Ndirect + (i + 1) * Perpage <= first)
                continue;
            if (Ndirect + i * Perpage >= first) {
                pgfree(in, @ptrCast(ind[@intCast(i)]));
                ind[@intCast(i)] = null;
            }
        }
        if (first <= Ndirect) {
            pgfree(in, @ptrCast(ind));
            n.ind = null;
        }
    }
    if (@rem(len, Pgsize) != 0) {
        const o: usize = @intCast(@rem(len, Pgsize));
        if (blkslot(in, n, @intCast(@divTrunc(len, Pgsize)), false)) |s|
            if (s.*) |p| @memset(p[o..Pgsize], 0);
    }
}

fn blkread(in: *Inst, n: *Node, a: [*]u8, cnt_: c_int, off: i64) c_int {
    var cnt: i64 = cnt_;
    if (off >= n.length)
        return 0;
    if (off + cnt > n.length)
        cnt = n.length - off;
    var done: i64 = 0;
    while (done < cnt) {
        const o: usize = @intCast(@rem(off + done, Pgsize));
        var m: i64 = Pgsize - @as(i64, @intCast(o));
        if (m > cnt - done)
            m = cnt - done;
        const dst = a[@intCast(done)..][0..@intCast(m)];
        const s = blkslot(in, n, @intCast(@divTrunc(off + done, Pgsize)), false);
        if (s == null or s.?.* == null)
            @memset(dst, 0)
        else
            @memcpy(dst, s.?.*.?[o..][0..@intCast(m)]);
        done += m;
    }
    return @intCast(cnt);
}

/// Writes all of a or nothing: Efull, leaving the length as it was.
fn blkwrite(in: *Inst, n: *Node, a: [*]const u8, cnt: c_int, off: i64) Error!void {
    if (cnt <= 0)
        return;
    if (off < 0 or off + cnt > Maxfile)
        return kerror(&port.Etoobig);
    const last: u64 = @intCast(@divTrunc(off + cnt - 1, Pgsize));
    var b: u64 = @intCast(@divTrunc(off, Pgsize));
    while (b <= last) : (b += 1) {
        const s = blkslot(in, n, b, true);
        if (s != null and s.?.* == null)
            s.?.* = @ptrCast(pgalloc(in));
        if (s == null or s.?.* == null) {
            trimblocks(in, n, n.length);
            return kerror(Efull);
        }
    }
    var done: i64 = 0;
    while (done < cnt) {
        const o: usize = @intCast(@rem(off + done, Pgsize));
        var m: i64 = Pgsize - @as(i64, @intCast(o));
        if (m > cnt - done)
            m = cnt - done;
        const s = blkslot(in, n, @intCast(@divTrunc(off + done, Pgsize)), false).?;
        @memcpy(s.*.?[o..][0..@intCast(m)], a[@intCast(done)..][0..@intCast(m)]);
        done += m;
    }
    if (off + cnt > n.length)
        n.length = off + cnt;
}

// Nodes.

fn nodefree(in: *Inst, n: *Node) void {
    var ch = n.child;
    while (ch) |k| {
        const nc = k.next;
        k.parent = null;
        k.next = null;
        k.prev = null;
        k.hnext = null;
        nodeunref(in, k);
        ch = nc;
    }
    n.child = null;
    c.free(@ptrCast(n.htab));
    n.htab = null;
    trimblocks(in, n, 0);
    ovstrfree(in, n.link);
    ovstrfree(in, n.name);
    ovstrfree(in, n.uid);
    ovstrfree(in, n.gid);
    ovstrfree(in, n.muid);
    ovmfree(in, n, @sizeOf(Node));
}

fn nodeunref(in: *Inst, n_: ?*Node) void {
    const n = n_ orelse return;
    n.ref -= 1;
    if (n.ref == 0)
        nodefree(in, n);
}

fn namehash(name: [*c]const u8) u32 {
    var h: u32 = 2166136261;
    for (span(name)) |ch|
        h = (h ^ ch) *% 16777619;
    return h;
}

/// Rebuilds d's hash table with n buckets (a power of two). On failure the
/// old table stays: chains get longer, lookups stay right.
fn rehash(d: *Node, n: c_int) void {
    const t: [*]?*Node = @ptrCast(@alignCast(c.mallocz(@intCast(@as(usize, @intCast(n)) * @sizeOf(?*Node)), 1) orelse return));
    var ch = d.child;
    while (ch) |k| : (ch = k.next) {
        const h = namehash(k.name) & @as(u32, @intCast(n - 1));
        k.hnext = t[h];
        t[h] = k;
    }
    c.free(@ptrCast(d.htab));
    d.htab = t;
    d.hsize = n;
}

fn findchild(d: *Node, name: [*c]const u8) ?*Node {
    if (d.htab) |t| {
        var ch = t[namehash(name) & @as(u32, @intCast(d.hsize - 1))];
        while (ch) |k| : (ch = k.hnext)
            if (eq(k.name, name))
                return k;
        return null;
    }
    var ch = d.child;
    while (ch) |k| : (ch = k.next)
        if (eq(k.name, name))
            return k;
    return null;
}

const Hmin = 64; // a directory with more children than this gets a table

fn ovlink(d: *Node, ch: *Node) void {
    ch.parent = d;
    ch.prev = null;
    ch.next = d.child;
    if (d.child) |f|
        f.prev = ch;
    d.child = ch;
    d.nchild += 1;
    if (d.htab) |t| {
        const h = namehash(ch.name) & @as(u32, @intCast(d.hsize - 1));
        ch.hnext = t[h];
        t[h] = ch;
    }
    if (d.nchild > (if (d.htab != null) 2 * d.hsize else Hmin))
        rehash(d, if (d.htab != null) 2 * d.hsize else 2 * Hmin);
}

/// Takes ch out of its directory and drops the tree's reference.
fn ovunlink(in: *Inst, ch: *Node) void {
    const d = ch.parent orelse return;
    if (ch.prev) |p|
        p.next = ch.next
    else
        d.child = ch.next;
    if (ch.next) |n|
        n.prev = ch.prev;
    if (d.htab) |t| {
        var l = &t[namehash(ch.name) & @as(u32, @intCast(d.hsize - 1))];
        while (l.*) |k| : (l = &k.hnext)
            if (k == ch) {
                l.* = ch.hnext;
                break;
            };
    }
    d.nchild -= 1;
    ch.parent = null;
    ch.next = null;
    ch.prev = null;
    ch.hnext = null;
    nodeunref(in, ch);
}

fn setstrs(in: *Inst, n: *Node, uid: [*c]const u8, gid: [*c]const u8, muid: [*c]const u8) Error!void {
    const u = ovstrdup(in, uid);
    const g = ovstrdup(in, gid);
    const m = ovstrdup(in, muid);
    if (u == null or g == null or m == null) {
        ovstrfree(in, u);
        ovstrfree(in, g);
        ovstrfree(in, m);
        return kerror(Efull);
    }
    ovstrfree(in, n.uid);
    ovstrfree(in, n.gid);
    ovstrfree(in, n.muid);
    n.uid = u;
    n.gid = g;
    n.muid = m;
}

fn ovuser() [*c]u8 {
    const p = up();
    return if (p.user[0] != 0) @ptrCast(&p.user) else c.eve;
}

/// A new, unlinked node with a reference for the tree.
fn newnode(in: *Inst, kind: c_int, name: [*c]const u8) Error!*Node {
    if (slen(name) >= Maxname)
        return kerror(&port.Etoolong);
    const n = ovnew(in, Node) orelse return kerror(Efull);
    n.kind = kind;
    n.ref = 1;
    n.name = ovstrdup(in, name);
    if (n.name == null) {
        ovmfree(in, n, @sizeOf(Node));
        return kerror(Efull);
    }
    errdefer nodefree(in, n);
    if (kind != Nwhite)
        try setstrs(in, n, c.eve, c.eve, c.eve);
    return n;
}

fn newqid(in: *Inst, n: *Node, isdir: bool) void {
    in.qidgen += 1;
    dev.mkqid(&n.qid, @bitCast(Copybit | in.qidgen), 0, if (isdir) QTDIR else QTFILE);
}

fn setdir(in: *Inst, n: *Node, d: *const Dir) Error!void {
    try setstrs(in, n, d.uid, d.gid, d.muid);
    n.mode = d.mode;
    n.atime = d.atime;
    n.mtime = d.mtime;
    n.length = d.length;
}

fn node2dir(ch: *Chan, n: *Node, d: *Dir) void {
    d.type = @intCast(dcof(ch));
    d.dev = ch.dev;
    d.qid = n.qid;
    d.mode = n.mode;
    if (n.kind == Nfifo)
        d.mode |= H9_DMFIFO;
    // A link is one only to a Linux process (design/epoch-0/linux-symlinks.md).
    if (n.kind == Nlink) {
        if (h9_fs_linkwalk() != 0)
            d.mode |= H9_DMSYMLINK
        else
            d.qid.type &= ~H9_QTSYMLINK;
    }
    d.atime = n.atime;
    d.mtime = n.mtime;
    d.length = if (n.qid.type & QTDIR != 0) 0 else n.length;
    d.name = if (n.parent == null and n.name[0] == 0) @constCast("/") else n.name;
    d.uid = n.uid;
    d.gid = n.gid;
    d.muid = n.muid;
}

// The lower tree.

/// Walks lower by one name; nil (with the error set) if it isn't there.
fn lowerwalk1(lc: *Chan, name: [*c]const u8) Error!?*Chan {
    const wq = try dwalk1(lc, name) orelse return null;
    var nc: ?*Chan = wq.libclone;
    if (wq.nqid != 1 and nc != null) {
        chan.cclose(nc);
        nc = null;
    }
    c.free(wq);
    return nc;
}

/// Walks the instance's lower root by the first n names of path; nil if absent.
fn lowerwalk(in: *Inst, path: [*c]const u8, n: usize) Error!?*Chan {
    const lower = in.lower orelse return null;
    var ch = try chan.cclone(lower);
    errdefer chan.cclose(ch);
    var s = path;
    var i: usize = 0;
    var buf: [Maxname]u8 = undefined;
    while (i < n and s[0] != 0) : (i += 1) {
        const e = std.mem.indexOfScalar(u8, span(s), '/') orelse slen(s);
        if (e >= buf.len) {
            chan.cclose(ch);
            return null;
        }
        @memcpy(buf[0..e], s[0..e]);
        buf[e] = 0;
        const nc = try lowerwalk1(ch, &buf);
        chan.cclose(ch);
        ch = nc orelse return null;
        s = if (s[e] != 0) s + e + 1 else s + e;
    }
    return ch;
}

/// The lower file's Dir, with its strings in strs (at least nstrs bytes).
fn lowerstat(lc: *Chan, d: *Dir, buf: [*]u8, nbuf: c_int, strs: [*]u8) Error!void {
    const n = try dstat(lc, buf, nbuf);
    if (n < BIT16SZ or c.convM2D(buf, @intCast(n), d, strs) != n)
        return kerror(&port.Ebadstat);
}

/// A stat buffer and room for its strings.
const Statbuf = struct {
    buf: [1024 + 4 * Maxname]u8 = undefined,
    strs: [1024 + 4 * Maxname]u8 = undefined,

    fn stat(sb: *Statbuf, lc: *Chan, d: *Dir) Error!void {
        return lowerstat(lc, d, &sb.buf, sb.buf.len, &sb.strs);
    }
};

// Chan state.

fn ovcnew(in: *Inst, n: ?*Node, lower: ?*Chan, path: [*c]const u8) Error!*Ovc {
    const o: *Ovc = @ptrCast(@alignCast(port.malloc(@sizeOf(Ovc)) orelse return kerror(&port.Enomem)));
    o.path = strdupn(path);
    if (o.path == null) {
        c.free(o);
        return kerror(&port.Enomem);
    }
    o.inst = in;
    o.node = n;
    if (n) |k|
        k.ref += 1;
    o.lower = lower;
    return o;
}

fn ovcfree(o_: ?*Ovc) void {
    const o = o_ orelse return;
    const in = o.inst;
    if (o.lower) |l|
        chan.cclose(l);
    sync.qlock(&in.ql);
    if (o.excl != 0)
        o.node.?.excl = 0;
    nodeunref(in, o.node);
    nodeunref(in, o.lnk);
    sync.qunlock(&in.ql);
    c.free(o.dir);
    c.free(o.lpath);
    c.free(o.path);
    c.free(o);
    instdecref(in);
}

/// dir/name, allocated: name alone if dir is "".
fn pathjoinn(dir: [*c]const u8, name: [*c]const u8) [*c]u8 {
    if (dir[0] == 0)
        return strdupn(name);
    const a = span(dir);
    const b = span(name);
    const p: [*]u8 = @ptrCast(port.malloc(a.len + 1 + b.len + 1) orelse return null);
    @memcpy(p[0..a.len], a);
    p[a.len] = '/';
    @memcpy(p[a.len + 1 ..][0..b.len], b);
    p[a.len + 1 + b.len] = 0;
    return p;
}

fn pathjoin(dir: [*c]const u8, name: [*c]const u8) Error![*c]u8 {
    const p = pathjoinn(dir, name);
    if (p == null)
        return kerror(&port.Enomem);
    return p;
}

fn npathelem(path_: [*c]const u8) usize {
    if (path_[0] == 0)
        return 0;
    var n: usize = 1;
    for (span(path_)) |ch|
        if (ch == '/') {
            n += 1;
        };
    return n;
}

/// Copies the i'th name of path into buf.
fn pathelem(path_: [*c]const u8, i_: usize, buf: [*]u8) void {
    var path = path_;
    var i = i_;
    while (i > 0) : (i -= 1)
        path += std.mem.indexOfScalar(u8, span(path), '/').? + 1;
    const e = std.mem.indexOfScalar(u8, span(path), '/') orelse slen(path);
    @memcpy(buf[0..e], path[0..e]);
    buf[e] = 0;
}

/// Finds a lower-only name in memory, in case it has since been copied up,
/// marked or removed. Returns -1 if it's gone: removed, or a node that has
/// left the tree.
fn adopt(o: *Ovc) c_int {
    if (o.node) |n| {
        if (n != o.inst.root and n.parent == null)
            return -1;
        return if (n.kind == Nwhite) -1 else 0;
    }
    var cur = o.inst.root.?;
    const n = npathelem(o.path);
    var buf: [Maxname]u8 = undefined;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        pathelem(o.path, i, &buf);
        const ch = findchild(cur, &buf) orelse return 0;
        if (ch.kind == Nwhite)
            return -1;
        cur = ch;
    }
    o.node = cur;
    cur.ref += 1;
    return 0;
}

/// An open file whose name was removed: its node lives on until the last
/// close, so stat and wstat (a truncate) still reach it, as they do on
/// Linux. WebKit makes its shared memory by opening a file in /dev/shm,
/// removing it, and then truncating it to size.
fn removedopen(ch: *Chan) bool {
    const o = ovcof(ch);
    const n = o.node orelse return false;
    return (ch.flag & COPEN) != 0 and n != o.inst.root and
        n.parent == null and (n.kind == Ncopy or n.kind == Nfifo);
}

/// Brings a chan up to date with the tree, for operations other than I/O on an open chan.
fn refresh(ch: *Chan) Error!void {
    const o = ovcof(ch);
    if (removedopen(ch))
        return;
    if (adopt(o) < 0)
        return kerror(&port.Enonexist);
    if (o.node != null and (ch.flag & COPEN) == 0)
        ch.qid = o.node.?.qid;
}

/// A fresh, unopened lower chan for o's name, or nil.
fn lowerfor(o: *Ovc) Error!?*Chan {
    const l = o.lower orelse return null;
    if (o.lopen == 0)
        return try chan.cclone(l);
    return lowerwalk(o.inst, o.path, npathelem(o.path));
}

/// Permission to open a file or directory of this mode, by its owner bits:
/// the guest is the owner of everything in the tree, as devfs presents it.
fn ovperm(mode: c_uint, omode: c_int) Error!void {
    const need = [_]c_uint{ 4, 2, 6, 1 };
    var t = need[@intCast(omode & 3)];
    if (omode & OTRUNC != 0)
        t |= 2;
    if (((mode >> 6) & t) != t)
        return kerror(&port.Eperm);
}

/// Reports a change at path to the instance's tracker, if it has one.
fn changed(in: *Inst, path: [*c]const u8) void {
    wcdrop(in, path, false);
    if (in.track) |t|
        h9_overlay_changed(t, z(path));
}

/// The directory node for the first n names of path, making markers for
/// lower directories that have none yet.
fn markpath(in: *Inst, path: [*c]const u8, n: usize) Error!*Node {
    var cur = in.root.?;
    var name: [Maxname]u8 = undefined;
    var sb: Statbuf = .{};
    var i: usize = 0;
    while (i < n) : (i += 1) {
        pathelem(path, i, &name);
        if (findchild(cur, &name)) |ch| {
            if (ch.kind == Nwhite or (ch.qid.type & QTDIR) == 0)
                return kerror(&port.Enonexist);
            cur = ch;
            continue;
        }
        if (cur.kind != Nmark)
            return kerror(&port.Enonexist);
        const lc = try lowerwalk(in, path, i + 1) orelse return kerror(&port.Enonexist);
        defer chan.cclose(lc);
        var d: Dir = undefined;
        try sb.stat(lc, &d);
        if ((d.qid.type & QTDIR) == 0)
            return kerror(&port.Enotdir);
        const ch = try newnode(in, Nmark, &name);
        ch.qid = d.qid;
        ch.inlower = 1;
        setdir(in, ch, &d) catch |e| {
            nodefree(in, ch);
            return e;
        };
        ovlink(cur, ch);
        cur = ch;
    }
    return cur;
}

/// Copies a lower-only file into memory, whole unless trunc, and points
/// the chan at the copy. Efull (changing nothing) if memory runs out.
fn copyup(ch: *Chan, trunc: bool) Error!void {
    const o = ovcof(ch);
    const in = o.inst;
    const ne = npathelem(o.path);
    if (ne == 0 or o.lower == null)
        return kerror(&port.Eperm);
    const dir = try markpath(in, o.path, ne - 1);
    var name: [Maxname]u8 = undefined;
    pathelem(o.path, ne - 1, &name);
    var sb: Statbuf = .{};
    var d: Dir = undefined;
    try sb.stat(o.lower.?, &d);
    const n = try newnode(in, Ncopy, &name);
    n.inlower = 1;
    newqid(in, n, false);
    {
        errdefer nodefree(in, n);
        try setdir(in, n, &d);
        n.length = 0;
        if (!trunc) {
            var lc = try lowerfor(o) orelse return kerror(&port.Enonexist);
            defer chan.cclose(lc);
            lc = try dopen(lc, OREAD);
            const data: [*]u8 = @ptrCast(c.smalloc(Copybuf));
            defer c.free(data);
            var off: i64 = 0;
            while (off < d.length) {
                const r = try dread(lc, data, Copybuf, off);
                if (r <= 0)
                    break;
                try blkwrite(in, n, data, r, off);
                off += r;
            }
        }
    }
    ovlink(dir, n);
    o.node = n;
    n.ref += 1;
    if ((ch.flag & COPEN) == 0)
        ch.qid = n.qid;
    changed(in, o.path);
}

/// Appends m bytes at p to a snapshot that realloc grows, with *cap its size.
fn snapput(dir: *[*c]u8, ndir: *c_int, cap: *c_int, p: [*]const u8, m: c_int) Error!void {
    if (ndir.* + m > cap.*) {
        cap.* = (ndir.* + m) * 2 + 1024;
        dir.* = @ptrCast(c.realloc(dir.*, @intCast(cap.*)));
        if (dir.* == null)
            return kerror(&port.Enomem);
    }
    @memcpy(dir.*[@intCast(ndir.*)..][0..@intCast(m)], p[0..@intCast(m)]);
    ndir.* += m;
}

/// Packs the merged directory into the chan's snapshot.
fn snapshot(ch: *Chan) Error!void {
    const o = ovcof(ch);
    const n = o.node.?;
    c.free(o.dir);
    o.dir = null;
    o.ndir = 0;
    var cap: c_int = 0;
    var d: Dir = undefined;
    var k = n.child;
    while (k) |e| : (k = e.next) {
        if (e.kind == Nwhite)
            continue;
        node2dir(ch, e, &d);
        const m: c_int = @intCast(c.sizeD2M(&d));
        if (o.ndir + m > cap) {
            cap = (o.ndir + m) * 2 + 1024;
            o.dir = @ptrCast(c.realloc(o.dir, @intCast(cap)));
            if (o.dir == null)
                return kerror(&port.Enomem);
        }
        o.ndir += @intCast(c.convD2M(&d, o.dir + @as(usize, @intCast(o.ndir)), @intCast(m)));
    }
    if (n.kind != Nmark)
        return;
    var lc = try lowerfor(o) orelse return;
    defer chan.cclose(lc);
    lc = try dopen(lc, OREAD);
    const buf: [*]u8 = @ptrCast(c.smalloc(8192 + 8192));
    defer c.free(buf);
    const strs = buf + 8192;
    var off: i64 = 0;
    while (true) {
        const r = try dread(lc, buf, 8192, off);
        if (r <= 0)
            break;
        const e = buf + @as(usize, @intCast(r));
        var p = buf;
        while (@intFromPtr(p + BIT16SZ) <= @intFromPtr(e)) {
            const m = BIT16SZ + gbit16(p);
            if (@intFromPtr(p + @as(usize, @intCast(m))) > @intFromPtr(e) or c.convM2D(p, @intCast(m), &d, strs) != m)
                break;
            if (findchild(n, d.name) == null)
                try snapput(&o.dir, &o.ndir, &cap, p, m);
            p += @intCast(m);
        }
        off += r;
    }
}

/// Whether the merged directory has any entries.
fn dirempty(ch: *Chan) Error!bool {
    const o = ovcof(ch);
    if (o.node) |n| {
        var k = n.child;
        while (k) |e| : (k = e.next)
            if (e.kind != Nwhite)
                return false;
        if (n.kind == Ncopy)
            return true;
    }
    if (o.lower == null)
        return true;
    if (o.node != null) {
        try snapshot(ch);
        const empty = o.ndir == 0;
        c.free(o.dir);
        o.dir = null;
        o.ndir = 0;
        return empty;
    }
    var lc = try lowerfor(o) orelse return true;
    defer chan.cclose(lc);
    lc = try dopen(lc, OREAD);
    const buf: [*]u8 = @ptrCast(c.smalloc(8192));
    defer c.free(buf);
    const r = try dread(lc, buf, 8192, 0);
    return r <= 0;
}

// Instances.

fn instlookup(id: c_int) ?*Inst {
    for (insts) |in|
        if (in != null and in.?.id == id)
            return in;
    return null;
}

fn instfree(in: *Inst) void {
    sync.qlock(&in.ql);
    nodeunref(in, in.root);
    in.root = null;
    var p = in.pages;
    while (p) |pg| {
        const np = pg.next;
        pgfree(in, pg);
        p = np;
    }
    in.pages = null;
    sync.qunlock(&in.ql);
    if (in.lower) |l|
        chan.cclose(l);
    wcfree(in);
    if (in.mem) |mem| {
        for (mem[0..@intCast(in.nmem)]) |m| {
            chan.cclose(m.root);
            c.free(m.at);
        }
    }
    c.free(@ptrCast(in.mem));
    c.free(in);
}

fn instdecref(in: *Inst) void {
    c.lock(&instlock);
    in.ref -= 1;
    const last = in.ref == 0;
    if (last) {
        for (&insts) |*s|
            if (s.* == in) {
                s.* = null;
            };
        // A named union's cow isn't counted in its ref: forget each other.
        if (in.over) |o|
            o.cow = null;
        if (in.cow) |w|
            w.over = null;
        in.over = null;
        in.cow = null;
    }
    c.unlock(&instlock);
    if (last)
        instfree(in);
}

fn instincref(in: *Inst) void {
    c.lock(&instlock);
    in.ref += 1;
    c.unlock(&instlock);
}

/// A free slot in insts and the next id for in, or "too many overlays".
/// Under instlock, which it releases on an error.
fn instput(in: *Inst) Error!void {
    for (&insts) |*s| {
        if (s.* == null) {
            in.id = nextid;
            nextid += 1;
            s.* = in;
            return;
        }
    }
    c.unlock(&instlock);
    return kerror("too many overlays");
}

/// Makes an instance over lower (nil: a tree in memory only) for the
/// calling thread's machine: its number. The instance is freed when the
/// last chan from its first attach is closed, or by h9_overlay_drop if
/// it's never attached.
pub fn overlaynew(lower: ?*Chan) Error!c_int {
    const in: *Inst = @ptrCast(@alignCast(port.malloc(@sizeOf(Inst)) orelse return kerror(&port.Enomem)));
    in.pool = h9_overlay_pool();
    in.ref = 1;
    in.pinned = 1;
    errdefer instfree(in);
    if (lower) |l| {
        if ((l.qid.type & QTDIR) == 0)
            return kerror(&port.Enotdir);
        var sb: Statbuf = .{};
        var d: Dir = undefined;
        try sb.stat(l, &d);
        in.lower = try chan.cclone(l);
        const r = try newnode(in, Nmark, "");
        r.inlower = 1;
        r.qid = l.qid;
        in.root = r;
        try setdir(in, r, &d);
    } else {
        const r = try newnode(in, Ncopy, "");
        in.root = r;
        dev.mkqid(&r.qid, @bitCast(Copybit), 0, QTDIR);
        r.mode = DMDIR | 0o777;
        r.atime = now();
        r.mtime = r.atime;
    }
    c.lock(&instlock);
    try instput(in);
    c.unlock(&instlock);
    return in.id;
}

/// For the namespace builder in Zig: an instance over the directory at
/// path (nil: none).
fn newpath(path: ?[*:0]const u8) Error!c_int {
    var ch: ?*Chan = null;
    if (path) |p|
        ch = try chan.namec(p, c.Aaccess, 0, 0);
    defer if (ch) |x| chan.cclose(x);
    return overlaynew(ch);
}

/// The lower chan for ch's name, for ovreadlink and ovgetattr,
/// or nil if ch isn't an overlay chan or its name is in memory: a link
/// copied up is a file now.
fn lowerof(ch: *Chan) Error!?*Chan {
    if (dcof(ch) != 'O' or isctl(ch))
        return null;
    if (isunion(ch)) {
        // The member's chan that holds the name.
        const u = uncof(ch);
        if (u.n == 0)
            return null;
        if (u.lopen == 0)
            return try chan.cclone(u.n0());
        return null;
    }
    const o = ovcof(ch);
    sync.qlock(&o.inst.ql);
    defer sync.qunlock(&o.inst.ql);
    if (adopt(o) == 0 and (o.node == null or o.node.?.kind == Nmark))
        return lowerfor(o);
    return null;
}

/// Makes name in the directory ch a symbolic link to target, for the
/// Linux ABI's symlinkat. ch is an overlay chan, which this closes.
fn symlink(ch_: *Chan, name: [*c]const u8, target: [*c]const u8) Error!void {
    var ch = ch_;
    {
        errdefer chan.cclose(ch);
        if (slen(target) >= 2048)
            return kerror(&port.Etoolong);
        if (isunion(ch)) {
            // In the layer, or on the first member that takes creates.
            try unmknod(ch, name, target, 0);
            chan.cclose(ch);
            return;
        }
        ch = try ovcreate(ch, name, OREAD, 0o666);
    }
    defer chan.cclose(ch);
    const o = ovcof(ch);
    const in = o.inst;
    sync.qlock(&in.ql);
    defer sync.qunlock(&in.ql);
    const n = o.node.?;
    const s = ovstrdup(in, target);
    if (s == null) {
        try removelocked(ch);
        return kerror(Efull);
    }
    n.kind = Nlink;
    n.qid.type |= H9_QTSYMLINK;
    n.link = s;
    n.mode = 0o777;
    n.length = @intCast(slen(target));
}

/// The target of the link ch was walked through as its last name, into buf;
/// its length, or nil if ch isn't an overlay chan on a link of its own (a
/// lower name's link is devfs's, through lowerof).
fn readlinkown(ch: *Chan, buf: []u8) ?usize {
    if (dcof(ch) != 'O' or buf.len == 0 or isctl(ch) or isunion(ch))
        return null;
    const o = ovcof(ch);
    sync.qlock(&o.inst.ql);
    defer sync.qunlock(&o.inst.ql);
    var l = o.lnk;
    if (l == null and o.node != null and o.node.?.kind == Nlink)
        l = o.node;
    const k = l orelse return null;
    if (k.parent == null)
        return null;
    const n = @min(slen(k.link), buf.len - 1);
    @memcpy(buf[0..n], k.link[0..n]);
    buf[n] = 0;
    return n;
}

/// Makes name in the directory ch a FIFO, for the Linux ABI's
/// mknodat. ch is an overlay chan, which this closes.
fn mkfifo(ch_: *Chan, name: [*c]const u8, perm: c_uint) Error!void {
    var ch = ch_;
    {
        errdefer chan.cclose(ch);
        if (isunion(ch)) {
            try unmknod(ch, name, null, perm & 0o777);
            chan.cclose(ch);
            return;
        }
        ch = try ovcreate(ch, name, OREAD, perm & 0o777);
    }
    const o = ovcof(ch);
    const in = o.inst;
    sync.qlock(&in.ql);
    o.node.?.kind = Nfifo;
    sync.qunlock(&in.ql);
    chan.cclose(ch);
}

/// Whether the overlay chan ch is a FIFO's: a FIFO node in memory, or a
/// host FIFO in the lower tree. Called from C: h9_fs_chanisfifo can
/// raise, and nothing here has anything to undo when it does.
fn isfifo(ch: *Chan) callconv(.c) c_int {
    if (dcof(ch) != 'O' or isctl(ch))
        return 0;
    if (isunion(ch)) {
        // The member's file that holds the name.
        const u = uncof(ch);
        if (u.n == 0 or u.mc[0] == null)
            return 0;
        return h9_fs_chanisfifo(u.n0());
    }
    const o = ovcof(ch);
    sync.qlock(&o.inst.ql);
    var l: ?*Chan = null;
    var r: c_int = 0;
    if (o.node) |n|
        r = @intFromBool(n.kind == Nfifo)
    else
        l = o.lower;
    sync.qunlock(&o.inst.ql);
    if (l) |x|
        r = h9_fs_isfifo(x);
    return r;
}

/// Frees an instance that was made but never attached.
fn drop(id: c_int) callconv(.c) void {
    c.lock(&instlock);
    const in = instlookup(id);
    if (in == null or in.?.pinned == 0 or in.?.pool != h9_overlay_pool()) {
        c.unlock(&instlock);
        return;
    }
    in.?.pinned = 0;
    c.unlock(&instlock);
    instdecref(in.?);
}

/// Gives an instance of the calling thread's machine a tracker (nil: none)
/// for h9_overlay_changed. Changes before this aren't reported.
fn track(id: c_int, t: ?*anyopaque) callconv(.c) void {
    c.lock(&instlock);
    if (instlookup(id)) |in|
        if (in.pool == h9_overlay_pool()) {
            in.track = t;
        };
    c.unlock(&instlock);
}

var ovtype: c_int = -2;

/// For findmount (chan.zig): a directory an instance shows from its lower
/// tree, or a marker for one, has the lower qid, so a mount on that lower
/// directory, made before the instance, shows through it as well. Returns 1
/// and the lower device's type and dev for (type, dev, qid) on an
/// instance with a lower tree, unless qid is a copy's own.
fn lowerdev(@"type": c_int, devn: c_int, qid: Qid, ltype: *c_int, ldev: *c_int) callconv(.c) c_int {
    if (ovtype == -2)
        ovtype = dev.devno('O');
    if (@"type" != ovtype or (qid.type & QTDIR) == 0 or (qid.path & Copybit) != 0)
        return 0;
    var r: c_int = 0;
    c.lock(&instlock);
    if (instlookup(devn)) |in| {
        if (in.lower) |l| {
            ltype.* = l.type;
            ldev.* = @bitCast(l.dev);
            r = 1;
        }
    }
    c.unlock(&instlock);
    return r;
}

// Unions (design/epoch-0/mounts.md, "Union instances").
//
// A union instance has no tree in memory: it has an ordered list of
// members, each a chan on another device's directory, rooted at the
// union's top or at a path below it (a member rooted at "etc" is walked
// only for etc and the paths under it). A walk walks each member that
// has the current directory to the same name, in order, top first. The
// first member that has the name decides what it is: a file is that
// member's file, and a directory is merged over every member with a
// directory by that name, at every depth. Walks are device walks, so a
// member is its own tree, not the mounts on it.
//
// Writes, removes and wstats go to the member that holds the name (the
// first), and creates go to the first member marked create that has the
// directory, or fail with "mounted directory forbids creation". A
// copy-on-write instance over a union (bind -c '#O' over it) keeps all
// of them in memory instead.
//
// Qids: each (device, dev, qid path) a member shows gets the union's own
// qid path from a table, so names from different members never share
// one, and the same file reached twice keeps one. The table and
// directory snapshots come from the machine's pages, as an overlay's
// data does.
//
// Named unions: "#Oroot" and "#Olinux" (any name of letters) are found
// by name in the attaching machine; a cow instance over a named union,
// made by h9_overlay_cowname, is what attaching the name gives from then
// on, so the name stands for the whole stack.

fn unrootqid() Qid {
    var q: Qid = undefined;
    dev.mkqid(&q, 0, 0, QTDIR);
    return q;
}

/// The table's entry for a member file (its device, dev, and qid path),
/// made if it's missing. Under in.ql.
fn qmapof(in: *Inst, @"type": c_int, devn: c_uint, path: u64) Error!*Qmap {
    const h: usize = @intCast((path ^ (path >> 17) ^ (@as(u64, @intCast(@"type")) << 7) ^ devn) % Qbuckets);
    const qtab = in.qtab.?;
    var m = qtab[h];
    while (m) |e| : (m = e.next)
        if (e.type == @"type" and e.dev == devn and e.path == path)
            return e;
    const e = ovnew(in, Qmap) orelse return kerror(Efull);
    e.type = @"type";
    e.dev = devn;
    e.path = path;
    in.qidgen += 1;
    e.qpath = in.qidgen;
    e.next = qtab[h];
    qtab[h] = e;
    return e;
}

fn qmapofchan(in: *Inst, mc: *Chan) Error!*Qmap {
    return qmapof(in, mc.type, mc.dev, mc.qid.path);
}

/// The union's qid for a member chan's. Under in.ql.
fn unqid(in: *Inst, mc: *Chan) Error!Qid {
    var q = mc.qid;
    q.path = (try qmapofchan(in, mc)).qpath;
    return q;
}

/// unqid, taking in.ql.
fn unqidlocked(in: *Inst, mc: *Chan) Error!Qid {
    sync.qlock(&in.ql);
    defer sync.qunlock(&in.ql);
    return unqid(in, mc);
}

/// The union qid path of below, a directory below the up layer, which
/// upwalk is about to make in the layer.
fn upqpath(in: *Inst, below: *Chan) Error!u64 {
    sync.qlock(&in.ql);
    defer sync.qunlock(&in.ql);
    return (try qmapofchan(in, below)).qpath;
}

/// Gives made, the up layer's copy of a directory below it, the union
/// qid path qp the directory had, so the directory keeps its identity
/// once the layer has it, as overlayfs keeps a directory's inode on copy
/// up: an fd opened on it before (a Linux dirfd, which h9_linux_dotfd
/// checks against a fresh walk), and stat's inode, see the same one.
fn upkeepqid(in: *Inst, made: *Chan, qp: u64) Error!void {
    sync.qlock(&in.ql);
    defer sync.qunlock(&in.ql);
    (try qmapofchan(in, made)).qpath = qp;
}

fn uncnew(in: *Inst, path: [*c]const u8) Error!*Unc {
    const u: *Unc = @ptrCast(@alignCast(port.malloc(@sizeOf(Unc)) orelse return kerror(&port.Enomem)));
    u.path = strdupn(path);
    if (u.path == null) {
        c.free(u);
        return kerror(&port.Enomem);
    }
    u.inst = in;
    return u;
}

fn unclear(u: *Unc) void {
    for (u.mc[0..@intCast(u.n)]) |m|
        if (m) |x| chan.cclose(x);
    u.n = 0;
}

fn undirfree(u: *Unc) void {
    if (u.dir != null)
        h9_overlay_free(u.inst.pool, u.dir, @intCast(u.dircap));
    u.dir = null;
    u.ndir = 0;
    u.dircap = 0;
}

fn uncfree(u_: ?*Unc) void {
    const u = u_ orelse return;
    const in = u.inst;
    unclear(u);
    undirfree(u);
    c.free(u.path);
    c.free(u);
    instdecref(in);
}

fn unadd(u: *Unc, ch: *Chan, m: *const Member) void {
    if (u.n >= Maxmembers) {
        chan.cclose(ch);
        return;
    }
    const i: usize = @intCast(u.n);
    u.mc[i] = ch;
    u.mid[i] = m.id;
    u.mcreate[i] = m.create;
    u.n += 1;
}

/// The index of member id in the instance, or null once it's gone. Under in.ql.
fn unmemidx(in: *Inst, id: c_int) ?usize {
    for (in.members(), 0..) |m, i|
        if (m.id == id)
            return i;
    return null;
}

/// Puts u at the union's top: each member rooted there.
fn untop(u: *Unc) Error!void {
    const in = u.inst;
    unclear(u);
    sync.qlock(&in.ql);
    defer sync.qunlock(&in.ql);
    for (in.members()) |*m|
        if (m.at[0] == 0 and !(u.noup != 0 and m.isup != 0))
            unadd(u, try chan.cclone(m.root), m);
}

// Whiteouts (design/epoch-0/upper-layers.md): in a union, a member's
// .wh.NAME hides NAME in the members below it, and a directory holding
// .wh..wh..opq isn't merged with the directories below it, as in an OCI
// image layer. Neither shows in a directory read. A walk asks for the
// whiteout only when a member misses a name, and only above the bottom.
const Whprefix = ".wh.";
const Whopaque = ".wh..wh..opq";

fn iswhname(name: [*c]const u8) bool {
    return std.mem.startsWith(u8, span(name), Whprefix);
}

/// .wh.name in buf, or null if it's too long.
fn whname(buf: *[Maxname]u8, name: [*c]const u8) ?[*:0]const u8 {
    const n = span(name);
    if (n.len + 4 >= Maxname)
        return null;
    @memcpy(buf[0..4], Whprefix);
    @memcpy(buf[4..][0..n.len], n);
    buf[4 + n.len] = 0;
    return @ptrCast(buf);
}

/// Whether a walk of dir to name finds it, leaving the error string as it was.
fn probe(dir: *Chan, name: [*c]const u8) Error!bool {
    var err: [ERRMAX]u8 = undefined;
    chan.kstrcpy(&err, z(up().errstr), ERRMAX);
    const w = try lowerwalk1(dir, name);
    chan.kstrcpy(up().errstr, @ptrCast(&err), ERRMAX);
    const x = w orelse return false;
    chan.cclose(x);
    return true;
}

/// Whether the member directory dir has a whiteout for name.
fn haswh(dir: *Chan, name: [*c]const u8) Error!bool {
    var wh: [Maxname]u8 = undefined;
    const s = whname(&wh, name) orelse return false;
    return probe(dir, s);
}

/// Whether the member directory dir is opaque.
fn isopaque(dir: *Chan) Error!bool {
    return probe(dir, Whopaque);
}

// The walk cache. A step of a union walk (unstep) asks each member for
// the name, and for whiteouts and opaque markers, which is a host stat
// or a 9P walk per member for every name of every walk. A stack with an
// up layer keeps what its steps found, keyed by the new path and by
// what decides the answer: the members the step started from, whether
// the walk leaves the layer out, whether it's a Linux process's walk,
// and the calling machine's access rules. An entry holds the members'
// chans, cloned for each use, or that the name doesn't exist.
//
// Changes through the instance drop what they change: changed() drops
// the path, and a change that moves or removes a directory, or the
// members themselves, drops everything. An entry is kept for at most a
// second, so a change made on the host to a tree in the stack is seen
// within that. A step that ran while its path was dropped doesn't keep
// what it found (the drop log).
const Wcbuckets = 1024; // a power of 2
const Wcmax = 8192; // entries; more drops everything
const Wclog = 64; // drops remembered, for steps in flight

const Wcttl: i64 = 1000000000; // ns

const Wce = extern struct {
    next: ?*Wce,
    path: [*c]u8,
    noup: c_int,
    lx: c_int,
    plan: ?*anyopaque,
    nkey: c_int,
    kmid: [*c]c_int, // the member ids the step started from
    ng: c_int, // 0: the name doesn't exist
    mc: [*c]?*Chan,
    mid: [*c]c_int,
    mcreate: [*c]c_int,
    born: i64,
};

const Wcache = extern struct {
    tab: [Wcbuckets]?*Wce,
    n: c_int,
    seq: u32, // counts drops
    log: [Wclog][*c]u8, // the path of drop seq%Wclog; nil for everything
};

fn wchash(s: [*c]const u8) usize {
    return namehash(s) & (Wcbuckets - 1);
}

/// h mod n, for the open-addressed tables.
fn hmod(name: [*c]const u8, n: usize) usize {
    return @as(usize, namehash(name)) % n;
}

/// Whether in keeps a walk cache: a stack with an up layer.
fn wcon(in: *Inst) bool {
    sync.qlock(&in.ql);
    defer sync.qunlock(&in.ql);
    return in.mode == Union and in.nmem > 0 and in.mem.?[0].isup != 0;
}

/// Unlinks *l onto *dead, for wcfreelist outside wcl.
fn wcunlink(wc: *Wcache, l: *?*Wce, dead: *?*Wce) void {
    const e = l.*.?;
    l.* = e.next;
    e.next = dead.*;
    dead.* = e;
    wc.n -= 1;
}

fn wcfreelist(e_: ?*Wce) void {
    var e = e_;
    while (e) |x| {
        const next = x.next;
        var i: usize = 0;
        while (i < x.ng) : (i += 1)
            chan.cclose(x.mc[i]);
        c.free(@ptrCast(x.mc));
        c.free(x.mid);
        c.free(x.mcreate);
        c.free(x.kmid);
        c.free(x.path);
        c.free(x);
        e = next;
    }
}

fn wclogadd(wc: *Wcache, path: [*c]const u8) void {
    wc.seq +%= 1;
    const l = &wc.log[wc.seq % Wclog];
    c.free(l.*);
    l.* = if (path != null) strdupn(path) else null;
}

/// Everything, under wcl.
fn wcclear(wc: *Wcache) ?*Wce {
    var dead: ?*Wce = null;
    for (&wc.tab) |*t|
        while (t.* != null)
            wcunlink(wc, t, &dead);
    return dead;
}

/// Drops what the cache has for path, or with all everything: a change
/// at path, or one that moves or removes a directory.
fn wcdrop(in: *Inst, path: [*c]const u8, all: bool) void {
    var dead: ?*Wce = null;
    sync.qlock(&in.wcl);
    const wc = in.wc orelse {
        sync.qunlock(&in.wcl);
        return;
    };
    if (all or path == null) {
        dead = wcclear(wc);
        wclogadd(wc, null);
    } else {
        var l = &wc.tab[wchash(path)];
        while (l.*) |e| {
            if (eq(e.path, path))
                wcunlink(wc, l, &dead)
            else
                l = &e.next;
        }
        wclogadd(wc, path);
    }
    sync.qunlock(&in.wcl);
    wcfreelist(dead);
}

fn wcfree(in: *Inst) void {
    sync.qlock(&in.wcl);
    const wc_ = in.wc;
    in.wc = null;
    sync.qunlock(&in.wcl);
    const wc = wc_ orelse return;
    const dead = wcclear(wc);
    for (wc.log) |l|
        c.free(l);
    c.free(wc);
    wcfreelist(dead);
}

fn wcmatch(e: *Wce, u: *Unc, np: [*c]const u8, lx: c_int, plan: ?*anyopaque) bool {
    if (e.noup != u.noup or e.lx != lx or e.plan != plan or e.nkey != u.n)
        return false;
    for (u.mid[0..@intCast(u.n)], 0..) |m, i|
        if (e.kmid[i] != m)
            return false;
    return eq(e.path, np);
}

/// A step's members: their chans, ids, and whether each takes creates.
const Got = struct {
    mc: [Maxmembers]*Chan = undefined,
    id: [Maxmembers]c_int = undefined,
    cr: [Maxmembers]c_int = undefined,
    n: usize = 0,

    fn add(g: *Got, ch: *Chan, id: c_int, cr: c_int) void {
        g.mc[g.n] = ch;
        g.id[g.n] = id;
        g.cr[g.n] = cr;
        g.n += 1;
    }

    fn close(g: *Got) void {
        for (g.mc[0..g.n]) |m|
            chan.cclose(m);
        g.n = 0;
    }
};

/// Looks up u's step to np. Returns 1 with the members' chans cloned
/// into got, -1 if the name doesn't exist, and 0 if the cache has
/// nothing for it. Also returns the drop count, for wcput.
fn wcget(in: *Inst, u: *Unc, np: [*c]const u8, got: *Got, seq: *u32) Error!c_int {
    const lx = h9_fs_linkwalk();
    const plan = h9_plan_get();
    const tnow = h9_clock_mono();
    var dead: ?*Wce = null;
    var r: c_int = 0;
    sync.qlock(&in.wcl);
    defer {
        sync.qunlock(&in.wcl);
        wcfreelist(dead);
    }
    if (in.wc == null) {
        in.wc = @ptrCast(@alignCast(port.malloc(@sizeOf(Wcache)) orelse {
            seq.* = 0;
            return 0;
        }));
    }
    const wc = in.wc.?;
    seq.* = wc.seq;
    var l = &wc.tab[wchash(np)];
    while (l.*) |e| : (l = &e.next) {
        if (!wcmatch(e, u, np, lx, plan))
            continue;
        if (tnow - e.born > Wcttl) {
            wcunlink(wc, l, &dead);
            break;
        }
        if (e.ng == 0) {
            r = -1;
            break;
        }
        errdefer got.close();
        var i: usize = 0;
        while (i < e.ng) : (i += 1)
            got.add(try chan.cclone(e.mc[i].?), e.mid[i], e.mcreate[i]);
        r = 1;
        break;
    }
    return r;
}

/// Keeps u's step to np, found from the members in kmid since drop
/// count seq: got's members (none if the name doesn't exist), unless np
/// was dropped meanwhile.
fn wcput(in: *Inst, noup: c_int, kmid: []const c_int, np: [*c]const u8, seq: u32, born: i64, got: *const Got) void {
    const e: *Wce = @ptrCast(@alignCast(port.malloc(@sizeOf(Wce)) orelse return));
    const ng = got.n;
    e.path = strdupn(np);
    e.kmid = @ptrCast(@alignCast(port.malloc(@max(kmid.len, 1) * @sizeOf(c_int))));
    e.mc = @ptrCast(@alignCast(port.malloc(@max(ng, 1) * @sizeOf(?*Chan))));
    e.mid = @ptrCast(@alignCast(port.malloc(@max(ng, 1) * @sizeOf(c_int))));
    e.mcreate = @ptrCast(@alignCast(port.malloc(@max(ng, 1) * @sizeOf(c_int))));
    if (e.path == null or e.kmid == null or e.mc == null or e.mid == null or e.mcreate == null) {
        wcfreelist(e);
        return;
    }
    e.noup = noup;
    e.lx = h9_fs_linkwalk();
    e.plan = h9_plan_get();
    e.nkey = @intCast(kmid.len);
    @memcpy(e.kmid[0..kmid.len], kmid);
    e.born = born;
    var i: usize = 0;
    while (i < ng) : (i += 1) {
        e.mc[i] = chan.cclone(got.mc[i]) catch {
            e.ng = @intCast(i);
            wcfreelist(e);
            return;
        };
        e.mid[i] = got.id[i];
        e.mcreate[i] = got.cr[i];
    }
    e.ng = @intCast(ng);
    var dead: ?*Wce = null;
    sync.qlock(&in.wcl);
    const wc = in.wc orelse {
        sync.qunlock(&in.wcl);
        wcfreelist(e);
        return;
    };
    if (wc.seq -% seq >= Wclog) {
        sync.qunlock(&in.wcl);
        wcfreelist(e);
        return;
    }
    var s = seq +% 1;
    while (s != wc.seq +% 1) : (s +%= 1) {
        const l = wc.log[s % Wclog];
        if (l == null or eq(l, np)) {
            sync.qunlock(&in.wcl);
            wcfreelist(e);
            return;
        }
    }
    if (wc.n >= Wcmax)
        dead = wcclear(wc);
    const h = wchash(np);
    e.next = wc.tab[h];
    wc.tab[h] = e;
    wc.n += 1;
    sync.qunlock(&in.wcl);
    wcfreelist(dead);
}

/// The up member's chan for path, if a step the cache keeps found the
/// name there (upwalk's shortcut); nil otherwise.
fn wcup(in: *Inst, path: [*c]const u8, upmid: c_int) ?*Chan {
    const lx = h9_fs_linkwalk();
    const plan = h9_plan_get();
    const tnow = h9_clock_mono();
    var ch: ?*Chan = null;
    sync.qlock(&in.wcl);
    if (in.wc) |wc| {
        var e = wc.tab[wchash(path)];
        while (e) |x| : (e = x.next) {
            if (x.ng > 0 and x.mid[0] == upmid and x.lx == lx and x.plan == plan and
                tnow - x.born <= Wcttl and eq(x.path, path))
            {
                ch = chan.cclone(x.mc[0].?) catch null;
                break;
            }
        }
    }
    sync.qunlock(&in.wcl);
    return ch;
}

/// Re-resolves u from the top along path, for "..".
fn unreroot(u: *Unc, nc: *Chan, path: [*c]const u8) Error!void {
    // path is often u.path itself (uncreate, unremove), which is freed
    // below, so walk a copy of it.
    const p = try strdupe(path);
    defer c.free(p);
    try untop(u);
    c.free(u.path);
    u.path = strdupn("");
    if (u.path == null)
        return kerror(&port.Enomem);
    nc.qid = unrootqid();
    const n = npathelem(p);
    var buf: [Maxname]u8 = undefined;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        pathelem(p, i, &buf);
        if (!try unstep(u, nc, &buf))
            return kerror(&port.Enonexist);
    }
}

/// Walks u by one name; returns false (with the error set) if it isn't there.
/// Members are taken in the instance's order: those that have u's
/// directory, and those rooted at the new name.
fn unstep(u: *Unc, nc: *Chan, name: [*c]const u8) Error!bool {
    if (eq(name, "."))
        return true;
    if (eq(name, "..")) {
        if (u.path[0] == 0)
            return true;
        const dir = try strdupe(u.path);
        defer c.free(dir);
        if (lastslash(dir)) |s|
            dir[s] = 0
        else
            dir[0] = 0;
        try unreroot(u, nc, dir);
        return true;
    }
    if ((nc.qid.type & QTDIR) == 0) {
        seterr(&port.Enotdir);
        return false;
    }
    const in = u.inst;
    // Before unfresh, so a directory the layer makes meanwhile is looked for again.
    sync.qlock(&in.ql);
    const gen = in.upgen;
    sync.qunlock(&in.ql);
    try unfresh(u);
    const np = try pathjoin(u.path, name);

    var got: Got = .{};
    search: {
        errdefer c.free(np);
        errdefer got.close();

        // The walk cache: what an earlier step from the same members found.
        const wc = wcon(in);
        var kmid: [Maxmembers]c_int = undefined;
        var nkey: usize = 0;
        var wseq: u32 = 0;
        var born: i64 = 0;
        if (wc) {
            born = h9_clock_mono();
            switch (try wcget(in, u, np, &got, &wseq)) {
                -1 => {
                    c.free(np);
                    seterr(&port.Enonexist);
                    return false;
                },
                1 => break :search,
                else => {},
            }
            nkey = @intCast(u.n);
            @memcpy(kmid[0..nkey], u.mid[0..nkey]);
        }

        // In member order: u's chans (at the top, every member rooted there,
        // so members added since u was made are seen), and fresh roots of
        // members rooted at np, which aren't walked.
        var have: [Maxmembers]?*Chan = undefined;
        var hid: [Maxmembers]c_int = undefined;
        var hcr: [Maxmembers]c_int = undefined;
        var hroot: [Maxmembers]bool = undefined;
        var nh: usize = 0;
        errdefer for (have[0..nh]) |h| if (h) |x| chan.cclose(x);
        {
            sync.qlock(&in.ql);
            defer sync.qunlock(&in.ql);
            for (in.members()) |*m| {
                if (nh >= Maxmembers)
                    break;
                if (u.noup != 0 and m.isup != 0)
                    continue;
                var ch: ?*Chan = null;
                var isroot = false;
                var j: usize = 0;
                while (j < u.n) : (j += 1)
                    if (u.mid[j] == m.id)
                        break;
                if (j < u.n)
                    ch = try chan.cclone(u.mc[j].?)
                else if (u.path[0] == 0 and m.at[0] == 0)
                    ch = try chan.cclone(m.root)
                else if (eq(m.at, np)) {
                    ch = try chan.cclone(m.root);
                    isroot = true;
                }
                const x = ch orelse continue;
                have[nh] = x;
                hroot[nh] = isroot;
                hid[nh] = m.id;
                hcr[nh] = m.create;
                nh += 1;
            }
        }

        var decided = false;
        var why: [ERRMAX]u8 = undefined;
        why[0] = 0;
        var k: usize = 0;
        while (k < nh) : (k += 1) {
            var ch = have[k].?;
            have[k] = null;
            // A member rooted at np is its own root, not walked.
            if (!hroot[k]) {
                up().errstr[0] = 0;
                const w_ = lowerwalk1(ch, name) catch |e| {
                    chan.cclose(ch);
                    return e;
                };
                const w = w_ orelse {
                    // The first member's reason, such as a link loop.
                    if (why[0] == 0)
                        chan.kstrcpy(&why, z(up().errstr), ERRMAX);
                    // A whiteout hides the name in the members below.
                    const wh = if (k < nh - 1) haswh(ch, name) catch |e| {
                        chan.cclose(ch);
                        return e;
                    } else false;
                    chan.cclose(ch);
                    if (wh) {
                        if (!decided)
                            chan.kstrcpy(&why, &port.Enonexist, ERRMAX);
                        break;
                    }
                    continue;
                };
                chan.cclose(ch);
                ch = w;
            }
            if (!decided) {
                decided = true;
                got.add(ch, hid[k], hcr[k]);
                if ((ch.qid.type & QTDIR) == 0)
                    break;
                // An opaque directory isn't merged with those below it.
                if (k < nh - 1 and try isopaque(ch))
                    break;
                continue;
            }
            if ((ch.qid.type & QTDIR) == 0) {
                chan.cclose(ch); // hidden by a directory above it
                continue;
            }
            got.add(ch, hid[k], hcr[k]);
            if (k < nh - 1 and try isopaque(ch))
                break;
        }
        while (k < nh) : (k += 1)
            if (have[k]) |x| {
                chan.cclose(x);
                have[k] = null;
            };
        if (got.n == 0) {
            if (wc and (why[0] == 0 or eq(&why, &port.Enonexist)))
                wcput(in, u.noup, kmid[0..nkey], np, wseq, born, &got);
            c.free(np);
            seterr(if (why[0] != 0) @ptrCast(&why) else &port.Enonexist);
            return false;
        }
        if (wc)
            wcput(in, u.noup, kmid[0..nkey], np, wseq, born, &got);
    }
    // found:
    unclear(u);
    for (0..got.n) |i| {
        u.mc[i] = got.mc[i];
        u.mid[i] = got.id[i];
        u.mcreate[i] = got.cr[i];
    }
    u.n = @intCast(got.n);
    u.upseen = gen;
    c.free(u.path);
    u.path = np;
    nc.qid = try unqidlocked(in, u.n0());
    return true;
}

fn unwalk(ch: *Chan, nc_: ?*Chan, name: [*]const [*:0]const u8, nname: c_int) Error!?*Walkqid {
    _ = nc_;
    const u = uncof(ch);
    const in = u.inst;
    const wq = dev.walkqid(@intCast(nname));
    const nc = dev.devclone(ch);
    nc.type = 0;
    dev.aux(nc).* = null;
    instincref(in);
    var nu_: ?*Unc = null;
    var i: usize = 0;
    {
        // A member's error, such as a link loop, is the walk's.
        errdefer {
            if (nu_) |nu| uncfree(nu) else instdecref(in);
            chan.cclose(nc);
            c.free(wq);
        }
        const nu = try uncnew(in, u.path);
        nu_ = nu;
        var j: usize = 0;
        while (j < u.n) : (j += 1) {
            nu.mc[j] = try chan.cclone(u.mc[j].?);
            nu.mid[j] = u.mid[j];
            nu.mcreate[j] = u.mcreate[j];
            nu.n = @intCast(j + 1);
        }
        nu.noup = u.noup;
        nu.upseen = u.upseen;
        if (nname == 0)
            try unfresh(nu);
        while (i < nname) : (i += 1) {
            if (!try unstep(nu, nc, name[i]))
                break;
            dev.qids(wq)[i] = nc.qid;
            // A Linux process's walk stops at a member's link (ovwalk).
            if (nc.qid.type & H9_QTSYMLINK != 0) {
                i += 1;
                break;
            }
        }
    }
    wq.nqid = @intCast(i);
    if (i < nname) {
        uncfree(nu_);
        chan.cclose(nc);
        if (i == 0) {
            c.free(wq);
            return null;
        }
        wq.libclone = null;
        return wq;
    }
    dev.aux(nc).* = nu_;
    nc.type = ch.type;
    wq.libclone = nc;
    return wq;
}

fn unstat(ch: *Chan, db: [*]u8, n: c_int) Error!c_int {
    const u = uncof(ch);
    const in = u.inst;
    const s: [*c]u8 = if (lastslash(u.path)) |k| u.path + k + 1 else u.path;
    if (u.path[0] == 0 and (ch.flag & COPEN) == 0)
        try untop(u);
    var d: Dir = std.mem.zeroes(Dir);
    var sb: Statbuf = .{};
    if (u.n == 0) {
        // The top of a union with no members there: an empty directory.
        d.name = @constCast("/");
        d.uid = c.eve;
        d.gid = c.eve;
        d.muid = c.eve;
        d.qid = unrootqid();
        d.mode = DMDIR | 0o555;
        d.atime = now();
        d.mtime = d.atime;
    } else {
        try sb.stat(u.n0(), &d);
        d.qid = if (u.path[0] == 0) unrootqid() else try unqidlocked(in, u.n0());
        if (u.path[0] == 0)
            d.name = @constCast("/")
        else
            d.name = s;
        if (d.qid.type & QTDIR != 0)
            d.length = 0;
    }
    const r = c.convD2M(&d, db, @intCast(n));
    if (r == 0)
        return kerror(&port.Eshortstat);
    return @intCast(r);
}

/// Appends m bytes at p to u's snapshot.
fn undirput(u: *Unc, p: [*]const u8, m: c_int) Error!void {
    if (u.ndir + m > u.dircap) {
        var cap: c_int = (u.ndir + m) * 2 + 8192;
        cap = (cap + Pgsize - 1) & ~@as(c_int, Pgsize - 1);
        const nb: [*]u8 = @ptrCast(h9_overlay_alloc(u.inst.pool, @intCast(cap)) orelse return kerror(Efull));
        if (u.dir != null) {
            @memcpy(nb[0..@intCast(u.ndir)], u.dir[0..@intCast(u.ndir)]);
            h9_overlay_free(u.inst.pool, u.dir, @intCast(u.dircap));
        }
        u.dir = nb;
        u.dircap = cap;
    }
    @memcpy(u.dir[@intCast(u.ndir)..][0..@intCast(m)], p[0..@intCast(m)]);
    u.ndir += m;
}

/// Whether the snapshot has an entry by name.
fn undirhas(u: *Unc, name: [*c]const u8, htab: []const usize) bool {
    const h: usize = namehash(name);
    var d: Dir = undefined;
    var strs: [4 * Maxname + 16]u8 = undefined;
    for (0..htab.len) |i| {
        const off = htab[(h + i) % htab.len];
        if (off == 0)
            return false;
        const p = u.dir + (off - 1);
        if (c.convM2D(p, @intCast(BIT16SZ + gbit16(p)), &d, &strs) > 0 and eq(d.name, name))
            return true;
    }
    return false;
}

/// A set of names, for the names a member's whiteouts hide below it.
const Hide = struct {
    tab: ?[*][*c]u8 = null,
    size: usize = 0,
    n: usize = 0,

    fn has(h: *Hide, name: [*c]const u8) bool {
        if (h.size == 0)
            return false;
        const t = h.tab.?;
        var k = hmod(name, h.size);
        while (t[k] != null) : (k = (k + 1) % h.size)
            if (eq(t[k], name))
                return true;
        return false;
    }

    fn put(h: *Hide, name: [*c]const u8) Error!void {
        if (h.has(name))
            return;
        if ((h.n + 1) * 2 > h.size) {
            const ot = h.tab;
            const os = h.size;
            const ns = if (os != 0) os * 2 else 64;
            const nt: [*][*c]u8 = @ptrCast(@alignCast(c.mallocz(@intCast(ns * @sizeOf([*c]u8)), 1) orelse return kerror(&port.Enomem)));
            h.tab = nt;
            h.size = ns;
            if (ot) |o| {
                for (o[0..os]) |s| {
                    if (s == null) continue;
                    var k = hmod(s, ns);
                    while (nt[k] != null) : (k = (k + 1) % ns) {}
                    nt[k] = s;
                }
            }
            c.free(@ptrCast(ot));
        }
        const t = h.tab.?;
        var k = hmod(name, h.size);
        while (t[k] != null) : (k = (k + 1) % h.size) {}
        t[k] = strdupn(name);
        if (t[k] == null)
            return kerror(&port.Enomem);
        h.n += 1;
    }

    fn free(h: *Hide) void {
        if (h.tab) |t|
            for (t[0..h.size]) |s| c.free(s);
        c.free(@ptrCast(h.tab));
        h.* = .{};
    }
};

/// Packs the merged directory into u's snapshot: each name once, the
/// first member's entry, leaving out whiteouts, the names they hide in
/// the members below them, and the members below an opaque directory.
/// With probing, stores nothing, and returns true at the first name it
/// would list: whether the merged directory has any.
fn unlist(u: *Unc, probing: bool) Error!bool {
    const in = u.inst;
    if (!probing)
        undirfree(u);
    var htab: []usize = &.{};
    var nent: usize = 0;
    var found = false;
    var hide: Hide = .{};
    var pend: Hide = .{};
    const buf: [*]u8 = @ptrCast(c.smalloc(8192 + 8192));
    defer {
        c.free(buf);
        if (htab.len > 0) c.free(htab.ptr);
        hide.free();
        pend.free();
    }
    const strs = buf + 8192;
    var d: Dir = undefined;
    var i: usize = 0;
    while (i < u.n and !found) : (i += 1) {
        var opaque_ = false;
        var lc = try chan.cclone(u.mc[i].?);
        defer chan.cclose(lc);
        lc = try dopen(lc, OREAD);
        var off: i64 = 0;
        while (!found) {
            const r = try dread(lc, buf, 8192, off);
            if (r <= 0)
                break;
            const e = buf + @as(usize, @intCast(r));
            var p = buf;
            while (@intFromPtr(p + BIT16SZ) <= @intFromPtr(e)) {
                const m = BIT16SZ + gbit16(p);
                defer p += @intCast(m);
                if (@intFromPtr(p + @as(usize, @intCast(m))) > @intFromPtr(e) or c.convM2D(p, @intCast(m), &d, strs) != m)
                    break;
                if (iswhname(d.name)) {
                    if (eq(d.name, Whopaque))
                        opaque_ = true
                    else if (i < u.n - 1)
                        try pend.put(d.name + 4);
                    continue;
                }
                if (hide.has(d.name))
                    continue;
                if (probing) {
                    found = true;
                    break;
                }
                if (nent * 2 >= htab.len) {
                    // Rebuild the name table, twice as big.
                    const ns: usize = if (htab.len != 0) htab.len * 2 else 256;
                    const nt: [*]usize = @ptrCast(@alignCast(c.mallocz(@intCast(ns * @sizeOf(usize)), 1) orelse return kerror(&port.Enomem)));
                    var o2: usize = 0;
                    while (o2 + BIT16SZ <= @as(usize, @intCast(u.ndir))) : (o2 += @intCast(BIT16SZ + gbit16(u.dir + o2))) {
                        var d2: Dir = undefined;
                        var s2: [4 * Maxname + 16]u8 = undefined;
                        const q = u.dir + o2;
                        if (c.convM2D(q, @intCast(BIT16SZ + gbit16(q)), &d2, &s2) <= 0)
                            continue;
                        var k = hmod(d2.name, ns);
                        while (nt[k] != 0) : (k = (k + 1) % ns) {}
                        nt[k] = o2 + 1;
                    }
                    if (htab.len > 0) c.free(htab.ptr);
                    htab = nt[0..ns];
                }
                if (undirhas(u, d.name, htab))
                    continue;
                // The entry's qid, as a walk to it gives it: the member chan's device.
                {
                    sync.qlock(&in.ql);
                    defer sync.qunlock(&in.ql);
                    d.qid.path = (try qmapof(in, lc.type, lc.dev, d.qid.path)).qpath;
                }
                var ent: [1024 + 4 * Maxname]u8 = undefined;
                const em: c_int = @intCast(c.convD2M(&d, &ent, ent.len));
                if (em <= BIT16SZ)
                    continue;
                var k = hmod(d.name, htab.len);
                while (htab[k] != 0) : (k = (k + 1) % htab.len) {}
                htab[k] = @as(usize, @intCast(u.ndir)) + 1;
                try undirput(u, &ent, em);
                nent += 1;
            }
            off += r;
        }
        // This member's whiteouts apply to the members below it, not to itself.
        if (pend.tab) |t|
            for (t[0..pend.size]) |s| if (s != null) try hide.put(s);
        pend.free();
        if (opaque_)
            break;
    }
    return found;
}

fn unsnapshot(ch: *Chan) Error!void {
    _ = try unlist(uncof(ch), false);
}

// Up layers (design/epoch-0/upper-layers.md). A union's up member, always its
// first, is a writable tree over the others, as overlayfs's upperdir is:
// a file from below is copied into it on its first change, a removed
// name below gets a whiteout in it, and a directory made again over a
// whiteout is opaque, so the tree is an OCI image layer, unpacked. Its
// changes are made through its own device, so a host directory, an #O
// tree in memory, or a 9P server keeps them. A member rooted below the
// top takes the changes under its path only.
//
// upql serializes the layer's changes, so two chans copying one file up
// don't both make it. It's held across device calls; in.ql isn't.

/// The up member's id, if in has one and path is under it; -1 otherwise.
fn upid(in: *Inst, path: [*c]const u8) c_int {
    var id: c_int = -1;
    sync.qlock(&in.ql);
    if (in.nmem > 0 and in.mem.?[0].isup != 0) {
        const m = &in.mem.?[0];
        const n = slen(m.at);
        if (n == 0 or (std.mem.startsWith(u8, span(path), span(m.at)) and (path[n] == 0 or path[n] == '/')))
            id = m.id;
    }
    sync.qunlock(&in.ql);
    return id;
}

/// Whether u's name is from below the layer, under an up member.
fn upbelow(u: *Unc) bool {
    const id = upid(u.inst, u.path);
    return id >= 0 and u.n > 0 and u.mid[0] != id;
}

/// The first n names of path, allocated.
fn pathprefix(path: [*c]const u8, n_: usize) Error![*c]u8 {
    var e: usize = 0;
    var n = n_;
    while (n > 0 and path[e] != 0) {
        n -= 1;
        if (std.mem.indexOfScalar(u8, span(path + e), '/')) |s| {
            e += s;
        } else {
            e = slen(path);
            break;
        }
        if (n > 0)
            e += 1;
    }
    const p: [*]u8 = @ptrCast(port.malloc(e + 1) orelse return kerror(&port.Enomem));
    @memcpy(p[0..e], path[0..e]);
    p[e] = 0;
    return p;
}

/// A fresh walk of in from its top along path, without the up member if
/// noup: what's below the layer. nil if there's nothing there. The Unc
/// holds a ref on in.
fn unlookup(in: *Inst, path: [*c]const u8, noup: c_int) Error!?*Unc {
    instincref(in);
    var u_: ?*Unc = null;
    errdefer if (u_) |u| uncfree(u) else instdecref(in);
    const u = try uncnew(in, "");
    u_ = u;
    u.noup = noup;
    try untop(u);
    var tmp: Chan = std.mem.zeroes(Chan);
    tmp.qid = unrootqid();
    const n = npathelem(path);
    var buf: [Maxname]u8 = undefined;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        pathelem(path, i, &buf);
        if (!try unstep(u, &tmp, &buf) or u.n == 0) {
            uncfree(u);
            return null;
        }
    }
    if (u.n == 0) {
        uncfree(u);
        return null;
    }
    return u;
}

/// Whether path exists below the layer, and if so whether it's a directory.
fn upexists(in: *Inst, path: [*c]const u8, noup: c_int, isdir: ?*bool) Error!bool {
    const t = try unlookup(in, path, noup) orelse return false;
    if (isdir) |d|
        d.* = (t.n0().qid.type & QTDIR) != 0;
    uncfree(t);
    return true;
}

/// Notes a directory made in the up member's tree (unfresh).
fn upmade(in: *Inst) void {
    sync.qlock(&in.ql);
    in.upgen +%= 1;
    sync.qunlock(&in.ql);
}

/// A directory named while the up layer didn't have it, such as a
/// process's working directory, has only the members below the layer.
/// Once the layer has made directories since u's members were found,
/// look for u's in it again, so that walks, reads, and creates from u
/// see what's changed there, as they would from a fresh walk.
fn unfresh(u: *Unc) Error!void {
    const in = u.inst;
    if (u.noup != 0 or u.n == 0 or u.dir != null or (u.n0().qid.type & QTDIR) == 0)
        return;
    sync.qlock(&in.ql);
    const gen = in.upgen;
    sync.qunlock(&in.ql);
    if (u.upseen == gen)
        return;
    u.upseen = gen;
    if (!upbelow(u))
        return;
    const ch = try upwalk(in, u.path, false) orelse return;
    if ((ch.qid.type & QTDIR) == 0) {
        chan.cclose(ch);
        return;
    }
    sync.qlock(&in.ql);
    const id = in.mem.?[0].id;
    const cr = in.mem.?[0].create;
    sync.qunlock(&in.ql);
    const opaq = isopaque(ch) catch |e| {
        chan.cclose(ch);
        return e;
    };
    if (opaq) {
        for (u.mc[0..@intCast(u.n)]) |m|
            chan.cclose(m);
        u.n = 0;
    } else if (u.n == Maxmembers) {
        u.n -= 1;
        chan.cclose(u.mc[@intCast(u.n)]);
    }
    var i: usize = @intCast(u.n);
    while (i > 0) : (i -= 1) {
        u.mc[i] = u.mc[i - 1];
        u.mid[i] = u.mid[i - 1];
        u.mcreate[i] = u.mcreate[i - 1];
    }
    u.mc[0] = ch;
    u.mid[0] = id;
    u.mcreate[0] = cr;
    u.n += 1;
}

/// Walks the up member to path, a union path under it. With make, a
/// directory missing from the layer is made there, with the mode of the
/// one below it; without, a missing name is nil.
fn upwalk(in: *Inst, path: [*c]const u8, make: bool) Error!?*Chan {
    sync.qlock(&in.ql);
    if (in.nmem == 0 or in.mem.?[0].isup == 0) {
        sync.qunlock(&in.ql);
        return null;
    }
    var ch = chan.cclone(in.mem.?[0].root) catch |e| {
        sync.qunlock(&in.ql);
        return e;
    };
    const nat = npathelem(in.mem.?[0].at);
    const upmid = in.mem.?[0].id;
    sync.qunlock(&in.ql);
    if (path[0] != 0) {
        if (wcup(in, path, upmid)) |nc| {
            chan.cclose(ch);
            return nc;
        }
    }
    errdefer chan.cclose(ch);
    const n = npathelem(path);
    var buf: [Maxname]u8 = undefined;
    var sb: Statbuf = .{};
    var i = nat;
    while (i < n) : (i += 1) {
        pathelem(path, i, &buf);
        var nc = try lowerwalk1(ch, &buf);
        if (nc == null) {
            if (!make) {
                chan.cclose(ch);
                return null;
            }
            const pre = try pathprefix(path, i + 1);
            defer c.free(pre);
            var d: Dir = undefined;
            var qp: u64 = undefined;
            {
                const t = try unlookup(in, pre, 0) orelse return kerror(&port.Enonexist);
                defer uncfree(t);
                try sb.stat(t.n0(), &d);
                if ((d.qid.type & QTDIR) == 0)
                    return kerror(&port.Enotdir);
                qp = try upqpath(in, t.n0());
            }
            var x = try chan.cclone(ch);
            x = dcreate(x, &buf, OREAD, DMDIR | (d.mode & 0o777)) catch |e| {
                chan.cclose(x);
                return e;
            };
            chan.cclose(x);
            upmade(in);
            // The directory has the layer among its members now.
            wcdrop(in, pre, false);
            const y = try lowerwalk1(ch, &buf) orelse return kerror(&port.Enonexist);
            upkeepqid(in, y, qp) catch |e| {
                chan.cclose(y);
                return e;
            };
            nc = y;
        }
        chan.cclose(ch);
        ch = nc.?;
    }
    return ch;
}

/// Makes name in the directory dir, on any device that has them, a
/// symbolic link, by its symlink operation (design/file-interface.md).
fn mklink(dir: *Chan, name: [*c]const u8, target: [*c]const u8) Error!void {
    return dev.symlink(dir, z(name), z(target));
}

/// As mklink, a FIFO.
fn mkfifo1(dir: *Chan, name: [*c]const u8, perm: c_uint) Error!void {
    switch (dcof(dir)) {
        'U' => try dev.caught(h9_fs_mkfifoz(dir, z(name), perm)),
        'O' => try mkfifo(try chan.cclone(dir), name, perm),
        'M' => {
            // A 9P2000.L server's makes a create with H9_DMFIFO a Tmknod.
            var nc = try chan.cclone(dir);
            defer chan.cclose(nc);
            nc = try dcreate(nc, name, OREAD, (perm & 0o777) | H9_DMFIFO);
        },
        else => return kerror(&port.Eperm),
    }
}

/// Makes the empty file name in dir, for a whiteout or an opaque marker.
fn mkmark(dir: *Chan, name: [*c]const u8) Error!void {
    var nc = try chan.cclone(dir);
    defer chan.cclose(nc);
    nc = try dcreate(nc, name, OREAD, 0o444);
}

/// Removes name from dir, if it's there.
fn rmname(dir: *Chan, name: [*c]const u8) Error!void {
    const ch = try lowerwalk1(dir, name) orelse return;
    defer {
        ch.type = 0;
        chan.cclose(ch);
    }
    try dremove(ch);
}

/// Makes the whiteout for name in the layer directory dir.
fn mkwh(dir: *Chan, name: [*c]const u8) Error!void {
    var wh: [Maxname]u8 = undefined;
    const s = whname(&wh, name) orelse return kerror(&port.Etoolong);
    try mkmark(dir, s);
}

/// Removes the whiteout for name from dir; whether there was one.
fn rmwh(dir: *Chan, name: [*c]const u8) Error!bool {
    if (!try haswh(dir, name))
        return false;
    var wh: [Maxname]u8 = undefined;
    try rmname(dir, whname(&wh, name).?);
    return true;
}

/// Removes the whiteouts and opaque marker in the layer directory dir.
fn rmmarks(dir: *Chan) Error!void {
    var names: [*c][*c]u8 = null;
    var nn: usize = 0;
    var cap: usize = 0;
    defer {
        for (0..nn) |i|
            c.free(names[i]);
        c.free(@ptrCast(names));
    }
    {
        const buf: [*]u8 = @ptrCast(c.smalloc(8192 + 8192));
        defer c.free(buf);
        const strs = buf + 8192;
        var lc = try chan.cclone(dir);
        defer chan.cclose(lc);
        lc = try dopen(lc, OREAD);
        var d: Dir = undefined;
        var off: i64 = 0;
        while (true) {
            const r = try dread(lc, buf, 8192, off);
            if (r <= 0)
                break;
            const e = buf + @as(usize, @intCast(r));
            var p = buf;
            while (@intFromPtr(p + BIT16SZ) <= @intFromPtr(e)) {
                const m = BIT16SZ + gbit16(p);
                defer p += @intCast(m);
                if (@intFromPtr(p + @as(usize, @intCast(m))) > @intFromPtr(e) or c.convM2D(p, @intCast(m), &d, strs) != m)
                    break;
                if (!iswhname(d.name))
                    continue;
                if (nn == cap) {
                    cap = if (cap != 0) cap * 2 else 16;
                    const nb: [*c][*c]u8 = @ptrCast(@alignCast(c.realloc(@ptrCast(names), @intCast(cap * @sizeOf([*c]u8)))));
                    if (nb == null)
                        return kerror(&port.Enomem);
                    names = nb;
                }
                names[nn] = strdupn(d.name);
                if (names[nn] == null)
                    return kerror(&port.Enomem);
                nn += 1;
            }
            off += r;
        }
    }
    for (0..nn) |i|
        try rmname(dir, names[i]);
}

/// Points u at the layer's chan ch for its name.
fn upset(u: *Unc, ch: *Chan, id: c_int) void {
    unclear(u);
    u.mc[0] = ch;
    u.mid[0] = id;
    u.mcreate[0] = 1;
    u.n = 1;
    u.lopen = 0;
}

/// Copies u's file from below into the layer, whole unless trunc, with
/// its parent directories, and points the chan at the copy. A link is
/// made again as a link, and a FIFO as a FIFO. Under upql.
fn upcopy(ch: *Chan, trunc: bool) Error!void {
    const u = uncof(ch);
    const in = u.inst;
    const id = upid(in, u.path);
    if (id < 0)
        return kerror(&port.Eperm);
    const pcopy = try strdupe(u.path);
    defer c.free(pcopy);
    var dir: [*c]const u8 = "";
    var name: [*c]u8 = pcopy;
    if (lastslash(pcopy)) |s| {
        pcopy[s] = 0;
        dir = pcopy;
        name = pcopy + s + 1;
    }
    var nc: *Chan = undefined;
    {
        const pd = try upwalk(in, dir, true) orelse return kerror(&port.Eperm);
        defer chan.cclose(pd);
        // Another chan may have copied it up already.
        nc = try lowerwalk1(pd, name) orelse blk: {
            {
                const t = try unlookup(in, u.path, 1) orelse return kerror(&port.Enonexist);
                var lc = lc: {
                    defer uncfree(t);
                    break :lc try chan.cclone(t.n0());
                };
                defer chan.cclose(lc);
                var sb: Statbuf = .{};
                var d: Dir = undefined;
                try sb.stat(lc, &d);
                if (d.qid.type & QTDIR != 0)
                    return kerror(&port.Eisdir);
                if ((d.qid.type & H9_QTSYMLINK) != 0 or (d.mode & H9_DMSYMLINK) != 0) {
                    var tgt: [2048]u8 = undefined;
                    _ = try dev.readlink(lc, &tgt) orelse return kerror(&port.Eperm);
                    try mklink(pd, name, &tgt);
                } else if (d.mode & H9_DMFIFO != 0) {
                    try mkfifo1(pd, name, d.mode & 0o777);
                } else {
                    var w = try chan.cclone(pd);
                    {
                        defer chan.cclose(w);
                        w = try dcreate(w, name, OWRITE, d.mode & 0o777);
                        if (!trunc) {
                            lc = try dopen(lc, OREAD);
                            const data: [*]u8 = @ptrCast(c.smalloc(Copybuf));
                            defer c.free(data);
                            var off: i64 = 0;
                            while (off < d.length) {
                                const r = try dread(lc, data, Copybuf, off);
                                if (r <= 0)
                                    break;
                                _ = try dwrite(w, data, r, off);
                                off += r;
                            }
                        }
                    }
                    // The mode and times, as the create may have masked the mode.
                    if (try lowerwalk1(pd, name)) |x| {
                        defer chan.cclose(x);
                        var nd: Dir = undefined;
                        dev.nulldir(&nd);
                        nd.mode = d.mode & ~DMDIR;
                        nd.mtime = d.mtime;
                        var wbuf: [256]u8 = undefined;
                        const n = c.convD2M(&nd, &wbuf, wbuf.len);
                        _ = dwstat(x, &wbuf, @intCast(n)) catch {};
                    }
                }
            }
            break :blk try lowerwalk1(pd, name) orelse return kerror(&port.Enonexist);
        };
    }
    const wasopen = u.lopen;
    if (wasopen != 0) {
        // An open chan goes on reading and writing, now the copy.
        nc = dopen(nc, ch.mode) catch |e| {
            chan.cclose(nc);
            return e;
        };
    }
    upset(u, nc, id);
    u.lopen = wasopen;
    if (wasopen == 0)
        ch.qid = try unqidlocked(in, u.n0());
    changed(in, u.path);
}

fn unopen(ch: *Chan, omode: c_int) Error!*Chan {
    const u = uncof(ch);
    const in = u.inst;
    const mode = try sysfile.openmode(@bitCast(omode));
    if (ch.qid.type & QTDIR != 0) {
        if (mode != OREAD or (omode & OTRUNC) != 0)
            return kerror(&port.Eisdir);
        if (u.path[0] == 0)
            try untop(u)
        else
            try unfresh(u);
        try unsnapshot(ch);
    } else {
        if (u.n == 0)
            return kerror(&port.Enonexist);
        // A file from below is copied into an up layer to be written.
        if (((mode != OREAD and mode != OEXEC) or (omode & OTRUNC) != 0) and upbelow(u)) {
            sync.qlock(&in.upql);
            defer sync.qunlock(&in.upql);
            try upcopy(ch, (omode & OTRUNC) != 0);
        }
        u.mc[0] = try dopen(u.n0(), omode & ~(ORCLOSE | OCEXEC));
        u.lopen = 1;
        ch.qid = try unqidlocked(in, u.n0());
    }
    if (omode & ORCLOSE != 0)
        ch.flag |= CRCLOSE;
    ch.mode = @intCast(mode);
    ch.flag |= COPEN;
    ch.offset = 0;
    return ch;
}

/// Whole directory entries of a snapshot from off, into a.
fn snapread(dir: [*c]const u8, ndir: c_int, a: ?*anyopaque, n: c_int, off: i64) c_int {
    var m: i64 = 0;
    while (off + m + BIT16SZ <= ndir) {
        const sz: i64 = BIT16SZ + gbit16(dir + @as(usize, @intCast(off + m)));
        if (m + sz > n)
            break;
        m += sz;
    }
    if (m > 0) {
        const dst: [*]u8 = @ptrCast(a.?);
        @memcpy(dst[0..@intCast(m)], dir[@intCast(off)..][0..@intCast(m)]);
    }
    return @intCast(m);
}

fn unread(ch: *Chan, a: ?*anyopaque, n: c_int, off: i64) Error!c_int {
    const u = uncof(ch);
    if (u.lopen != 0)
        return dread(u.n0(), a, n, off);
    if ((ch.qid.type & QTDIR) == 0)
        return kerror(&port.Eperm);
    if (off == 0 or u.dir == null)
        try unsnapshot(ch);
    return snapread(u.dir, u.ndir, a, n, off);
}

fn unwrite(ch: *Chan, a: ?*const anyopaque, n: c_int, off: i64) Error!c_int {
    const u = uncof(ch);
    if (ch.qid.type & QTDIR != 0)
        return kerror(&port.Eisdir);
    if (u.lopen == 0)
        return kerror(&port.Eperm);
    return dwrite(u.n0(), a, n, off);
}

/// Splits path into its directory (allocated) and last name (in path).
fn pathsplit(path: [*c]u8, name: *[*c]u8) Error![*c]u8 {
    const s = lastslash(path) orelse {
        name.* = path;
        return pathprefix(path, 0);
    };
    name.* = path + s + 1;
    return pathprefix(path, npathelem(path) - 1);
}

/// Makes name in u's directory in the layer, for uncreate: its parent
/// directories are copied up, a whiteout for it is removed, and a
/// directory made over one is opaque. Returns the new chan, as the
/// device's create left it.
fn upcreate(ch: *Chan, name: [*c]const u8, np: [*c]const u8, omode: c_int, perm: c_uint) Error!*Chan {
    const u = uncof(ch);
    const in = u.inst;
    if (iswhname(name))
        return kerror(&port.Eperm);
    sync.qlock(&in.upql);
    const nc = upcreatelocked(u, name, np, omode, perm) catch |e| {
        sync.qunlock(&in.upql);
        return e;
    };
    sync.qunlock(&in.upql);
    changed(in, np);
    return nc;
}

fn upcreatelocked(u: *Unc, name: [*c]const u8, np: [*c]const u8, omode: c_int, perm: c_uint) Error!*Chan {
    const in = u.inst;
    var isdir = false;
    if (try upexists(in, np, 0, &isdir))
        if (isdir or (perm & DMDIR) != 0 or (omode & OEXCL) != 0)
            return kerror(&port.Eexist);
    const pd = try upwalk(in, u.path, true) orelse return kerror(&port.Eperm);
    defer chan.cclose(pd);
    const waswh = try rmwh(pd, name);
    var nc = try chan.cclone(pd);
    errdefer chan.cclose(nc);
    nc = try dcreate(nc, name, omode, perm);
    if ((perm & DMDIR) != 0 and waswh) {
        if (try lowerwalk1(pd, name)) |d| {
            defer chan.cclose(d);
            try mkmark(d, Whopaque);
        }
    }
    // After the opaque marker, so that unfresh never sees the directory without it.
    if (perm & DMDIR != 0)
        upmade(in);
    return nc;
}

/// Removes u's name under the layer: from the layer if it's there, with
/// a whiteout in its place if the name exists below.
fn upremove(u: *Unc) Error!void {
    const in = u.inst;
    const id = upid(in, u.path);
    sync.qlock(&in.upql);
    defer sync.qunlock(&in.upql);
    var isdir = false;
    var inlayer = false;
    {
        const t = try unlookup(in, u.path, 0) orelse return kerror(&port.Enonexist);
        defer uncfree(t);
        isdir = (t.n0().qid.type & QTDIR) != 0;
        if (isdir and try unlist(t, true))
            return kerror(Enotempty);
        inlayer = t.mid[0] == id;
    }
    const below = try upexists(in, u.path, 1, null);
    var name: [*c]u8 = undefined;
    const dir = try pathsplit(u.path, &name);
    defer c.free(dir);
    if (inlayer) {
        const lc = try upwalk(in, u.path, false) orelse return kerror(&port.Enonexist);
        errdefer chan.cclose(lc);
        if (isdir) {
            try rmmarks(lc);
            wcdrop(in, null, true);
        }
        try dremove(lc);
        lc.type = 0;
        chan.cclose(lc);
    }
    if (below) {
        const pd = try upwalk(in, dir, true) orelse return kerror(&port.Eperm);
        defer chan.cclose(pd);
        try mkwh(pd, name);
    }
    changed(in, u.path);
}

/// A name ovname refuses: "file name too long", or "bad character in file name".
fn badname(name: [*c]const u8) error{Kernel} {
    return kerror(if (slen(name) >= Maxname) &port.Etoolong else &port.Ebadchar);
}

/// Makes name in the union directory ch a link to target, or with target
/// nil a FIFO: in the layer when it's under one, and otherwise in the
/// first member that takes creates.
fn unmknod(ch: *Chan, name: [*c]const u8, target: [*c]const u8, perm: c_uint) Error!void {
    const u = uncof(ch);
    const in = u.inst;
    if (!ovname(name))
        return badname(name);
    const np = try pathjoin(u.path, name);
    defer c.free(np);
    if (upid(in, np) < 0) {
        if (u.path[0] == 0)
            try untop(u);
        var i: usize = 0;
        while (i < u.n) : (i += 1)
            if (u.mcreate[i] != 0)
                break;
        if (i == u.n)
            return kerror(&port.Enocreate);
        if (target != null)
            try mklink(u.mc[i].?, name, target)
        else
            try mkfifo1(u.mc[i].?, name, perm);
        wcdrop(in, np, false);
    } else {
        if (iswhname(name))
            return kerror(&port.Eperm);
        sync.qlock(&in.upql);
        {
            errdefer sync.qunlock(&in.upql);
            if (try upexists(in, np, 0, null))
                return kerror(&port.Eexist);
            const pd = try upwalk(in, u.path, true) orelse return kerror(&port.Eperm);
            defer chan.cclose(pd);
            _ = try rmwh(pd, name);
            if (target != null)
                try mklink(pd, name, target)
            else
                try mkfifo1(pd, name, perm);
        }
        sync.qunlock(&in.upql);
        changed(in, np);
    }
}

/// Moves ch's name to name in the directory dch, both union chans, for
/// move: within a layer, with the layer's own rename. A file from below
/// is copied up first, and its old name whited out. Returns 1 if it
/// can't (a directory from below, or a device that can't rename across
/// directories), and 0 once moved.
fn unmove(ch: *Chan, dch: *Chan, name: [*c]const u8) Error!c_int {
    const u = uncof(ch);
    const ud = uncof(dch);
    const in = u.inst;
    if (ud.inst != in)
        return 1;
    if (!ovname(name))
        return badname(name);
    const np = try pathjoin(ud.path, name);
    defer c.free(np);
    const id = upid(in, u.path);
    if (id < 0 or upid(in, np) < 0)
        return 1;
    sync.qlock(&in.upql);
    defer sync.qunlock(&in.upql);
    return unmovelocked(ch, u, ud, name, np, id);
}

fn unmovelocked(ch: *Chan, u: *Unc, ud: *Unc, name: [*c]const u8, np: [*c]const u8, id: c_int) Error!c_int {
    const in = u.inst;
    if (iswhname(name))
        return kerror(&port.Eperm);
    if (u.path[0] == 0)
        return kerror(&port.Eperm);
    if (eq(np, u.path))
        return 0;
    var isdir = false;
    var inlayer = false;
    {
        const t = try unlookup(in, u.path, 0) orelse return kerror(&port.Enonexist);
        defer uncfree(t);
        isdir = (t.n0().qid.type & QTDIR) != 0;
        inlayer = t.mid[0] == id;
    }
    const belowold = try upexists(in, u.path, 1, null);
    if (isdir and belowold) {
        // overlayfs without redirect_dir: mv copies instead.
        return 1;
    }
    const ul = slen(u.path);
    if (isdir and std.mem.startsWith(u8, span(np), span(u.path)) and np[ul] == '/')
        return kerror(&port.Ebadarg); // into itself: EINVAL
    const belownew = try upexists(in, np, 1, null);
    var tdir = false;
    if (try upexists(in, np, 0, &tdir) and tdir) {
        if (try unlookup(in, np, 0)) |t| {
            defer uncfree(t);
            if (try unlist(t, true))
                return kerror(Enotempty);
            if (t.mid[0] == id) {
                // An empty directory in the layer: its markers would keep the host's rename from replacing it.
                if (try upwalk(in, np, false)) |d| {
                    errdefer chan.cclose(d);
                    try rmmarks(d);
                    try dremove(d);
                    d.type = 0;
                    chan.cclose(d);
                }
            }
        }
    }
    if (!inlayer)
        try upcopy(ch, false);
    var oname: [*c]u8 = undefined;
    const odir = try pathsplit(u.path, &oname);
    defer c.free(odir);
    const oc_ = try upwalk(in, u.path, false);
    defer if (oc_) |x| chan.cclose(x);
    const pd_ = try upwalk(in, ud.path, true);
    defer if (pd_) |x| chan.cclose(x);
    const oc = oc_ orelse return kerror(&port.Enonexist);
    const pd = pd_ orelse return kerror(&port.Enonexist);
    const waswh = try rmwh(pd, name);
    // The layer's own rename, where its device has one (design/file-interface.md).
    var moved = try dev.rename(oc, pd, z(name));
    if (!moved and eq(odir, ud.path)) {
        // In one directory, any device renames with a wstat.
        var nd: Dir = undefined;
        dev.nulldir(&nd);
        nd.name = @constCast(name);
        var wbuf: [Maxname + 64]u8 = undefined;
        _ = try dwstat(oc, &wbuf, @intCast(c.convD2M(&nd, &wbuf, wbuf.len)));
        moved = true;
    }
    if (!moved) {
        if (waswh)
            try mkwh(pd, name);
    } else {
        if (belowold) {
            if (try upwalk(in, odir, true)) |od| {
                defer chan.cclose(od);
                try mkwh(od, oname);
            }
        }
        if (isdir and (waswh or belownew)) {
            if (try lowerwalk1(pd, name)) |d| {
                defer chan.cclose(d);
                try mkmark(d, Whopaque);
            }
        }
        wcdrop(in, null, true);
        changed(in, u.path);
        changed(in, np);
    }
    return if (moved) 0 else 1;
}

fn uncreate(ch: *Chan, name: [*c]const u8, omode: c_int, perm: c_uint) Error!*Chan {
    const u = uncof(ch);
    const in = u.inst;
    if ((ch.qid.type & QTDIR) == 0)
        return kerror(&port.Enotdir);
    if (!ovname(name))
        return badname(name);
    if (u.path[0] == 0)
        try untop(u)
    else
        try unfresh(u);
    const np = try pathjoin(u.path, name);
    var nc: *Chan = undefined;
    var id: c_int = undefined;
    var cr: c_int = undefined;
    {
        errdefer c.free(np);
        id = upid(in, np);
        if (id >= 0) {
            nc = try upcreate(ch, name, np, omode & ~OCEXEC, perm);
            cr = 1;
        } else {
            var i: usize = 0;
            while (i < u.n) : (i += 1)
                if (u.mcreate[i] != 0)
                    break;
            if (i == u.n)
                return kerror(&port.Enocreate);
            var x = try chan.cclone(u.mc[i].?);
            x = dcreate(x, name, omode & ~OCEXEC, perm) catch |e| {
                chan.cclose(x);
                return e;
            };
            nc = x;
            wcdrop(in, np, false);
            id = u.mid[i];
            cr = u.mcreate[i];
        }
    }
    upset(u, nc, id);
    u.mcreate[0] = cr;
    c.free(u.path);
    u.path = np;
    u.lopen = @intFromBool((nc.qid.type & QTDIR) == 0);
    ch.qid = try unqidlocked(in, nc);
    if (u.lopen == 0) {
        // A directory: readable as the new member directory, through a snapshot.
        chan.cclose(u.mc[0]);
        u.mc[0] = null;
        u.n = 0;
        try unreroot(u, ch, np);
    }
    if (omode & ORCLOSE != 0)
        ch.flag |= CRCLOSE;
    ch.mode = @intCast(try sysfile.openmode(@bitCast(omode)));
    ch.flag |= COPEN;
    ch.offset = 0;
    return ch;
}

fn unremove(ch: *Chan) Error!void {
    const u = uncof(ch);
    errdefer {
        dev.aux(ch).* = null;
        uncfree(u);
    }
    if (u.path[0] == 0 or u.n == 0)
        return kerror(&port.Eperm);
    if (upid(u.inst, u.path) >= 0) {
        unclear(u);
        u.lopen = 0;
        try upremove(u);
        dev.aux(ch).* = null;
        uncfree(u);
        return;
    }
    var mc = u.n0();
    u.mc[0] = null;
    if (u.lopen != 0) {
        // An open chan can't be removed by devfs and the like: a fresh one can.
        chan.cclose(mc);
        try unreroot(u, ch, u.path);
        mc = u.n0();
        u.mc[0] = null;
    }
    const isdir = (mc.qid.type & QTDIR) != 0;
    try dremove(mc);
    wcdrop(u.inst, u.path, isdir);
    dev.aux(ch).* = null;
    uncfree(u);
}

fn unclose(ch: *Chan) void {
    const u: *Unc = @ptrCast(@alignCast(auxof(ch) orelse return));
    if ((ch.flag & (COPEN | CRCLOSE)) == (COPEN | CRCLOSE) and u.n > 0)
        unrclose(ch, u) catch {};
    dev.aux(ch).* = null;
    uncfree(u);
}

/// The remove an ORCLOSE chan's close makes.
fn unrclose(ch: *Chan, u: *Unc) Error!void {
    if (upid(u.inst, u.path) >= 0) {
        unclear(u);
        u.lopen = 0;
        try upremove(u);
        return;
    }
    if (u.lopen != 0) {
        if (u.mc[0]) |x| chan.cclose(x);
        u.mc[0] = null;
        u.lopen = 0;
        try unreroot(u, ch, u.path);
    }
    const mc = u.mc[0] orelse return;
    u.mc[0] = null;
    try dremove(mc);
    wcdrop(u.inst, u.path, true);
}

/// A wstat under the layer: a file from below is copied up, and a
/// directory made in the layer, before it's changed there. A rename
/// whites out the old name if it exists below, and a directory from
/// below can't be renamed.
fn upwstat(ch: *Chan, db: [*]u8, n: c_int) Error!c_int {
    const u = uncof(ch);
    const in = u.inst;
    const strs: [*]u8 = @ptrCast(c.smalloc(@intCast(n)));
    defer c.free(strs);
    sync.qlock(&in.upql);
    defer sync.qunlock(&in.upql);
    var dd: Dir = undefined;
    if (c.convM2D(db, @intCast(n), &dd, strs) != n)
        return kerror(&port.Ebadstat);
    var namep: [*c]u8 = undefined;
    const dir = try pathsplit(u.path, &namep);
    defer c.free(dir);
    // The old name, which a reroot of u.path below would free.
    var name: [Maxname]u8 = undefined;
    chan.kstrcpy(&name, z(namep), Maxname);
    const isdir = (u.n0().qid.type & QTDIR) != 0;
    const chname = dd.name[0] != 0 and !eq(dd.name, &name);
    const change = chname or dd.mode != nulldir or dd.mtime != nulldir or dd.length != -1 or
        dd.uid[0] != 0 or dd.gid[0] != 0;
    if (chname and iswhname(dd.name))
        return kerror(&port.Eperm);
    const belowold = try upexists(in, u.path, 1, null);
    if (chname and isdir and belowold)
        return kerror(dev.Exdev);
    if (change and upbelow(u)) {
        if (isdir) {
            if (try upwalk(in, u.path, true)) |d|
                chan.cclose(d);
            try unreroot(u, ch, u.path);
            changed(in, u.path);
        } else try upcopy(ch, dd.length == 0);
    }
    if (!chname)
        return dwstat(u.n0(), db, n);
    const np = try pathjoin(dir, dd.name);
    var r: c_int = undefined;
    {
        errdefer c.free(np);
        const pd = try upwalk(in, dir, true) orelse return kerror(&port.Enonexist);
        defer chan.cclose(pd);
        const waswh = try rmwh(pd, dd.name);
        r = dwstat(u.n0(), db, n) catch |e| {
            if (waswh)
                try mkwh(pd, dd.name);
            return e;
        };
        if (belowold)
            try mkwh(pd, &name);
        if (isdir and waswh) {
            if (try lowerwalk1(pd, dd.name)) |d| {
                defer chan.cclose(d);
                try mkmark(d, Whopaque);
            }
        }
    }
    wcdrop(in, null, true);
    changed(in, u.path);
    changed(in, np);
    c.free(u.path);
    u.path = np;
    return r;
}

fn unwstat(ch: *Chan, db: [*]u8, n: c_int) Error!c_int {
    const u = uncof(ch);
    if (u.n == 0 or u.path[0] == 0)
        return kerror(&port.Eperm);
    if (upid(u.inst, u.path) >= 0)
        return upwstat(ch, db, n);
    const r = try dwstat(u.n0(), db, n);
    // A rename moves what's under it too.
    wcdrop(u.inst, u.path, (u.n0().qid.type & QTDIR) != 0);
    return r;
}

/// A union chan at the top of in, holding the caller's reference to in
/// (which an error leaves to the caller).
fn unattach(in: *Inst, spec: [*c]const u8) Error!*Chan {
    const ch = dev.devattach('O', z(spec));
    ch.dev = @bitCast(in.id);
    ch.qid = unrootqid();
    errdefer chan.cclose(ch);
    const u = try uncnew(in, "");
    dev.aux(ch).* = u;
    untop(u) catch |e| {
        // h9: not uncfree, which would drop the reference the caller drops.
        dev.aux(ch).* = null;
        unclear(u);
        c.free(u.path);
        c.free(u);
        return e;
    };
    return ch;
}

/// Makes a union instance for the calling thread's machine, unattached (pinned).
fn unnew(name: ?[*:0]const u8) Error!*Inst {
    const in: *Inst = @ptrCast(@alignCast(port.malloc(@sizeOf(Inst)) orelse return kerror(&port.Enomem)));
    in.mode = Union;
    in.pool = h9_overlay_pool();
    in.ref = 1;
    in.pinned = 1;
    if (name) |s| {
        const t = std.mem.span(s);
        const k = @min(t.len, in.name.len - 1);
        @memcpy(in.name[0..k], t[0..k]);
        in.name[k] = 0;
    }
    in.mem = @ptrCast(@alignCast(c.mallocz(Maxmembers * @sizeOf(Member), 1) orelse {
        c.free(in);
        return kerror(&port.Enomem);
    }));
    in.qtab = @ptrCast(@alignCast(ovmalloc(in, Qbuckets * @sizeOf(?*Qmap)) orelse {
        instfree(in);
        return kerror(Efull);
    }));
    c.lock(&instlock);
    instput(in) catch |e| {
        instfree(in);
        return e;
    };
    c.unlock(&instlock);
    return in;
}

/// The named union of the calling thread's machine, or nil. Under instlock.
fn unnamed(name: [*c]const u8) ?*Inst {
    const pool = h9_overlay_pool();
    for (insts) |in_| {
        const in = in_ orelse continue;
        if (in.mode == Union and in.pool == pool and eq(&in.name, name))
            return in;
    }
    return null;
}

fn unvalidname(s: [*c]const u8) bool {
    const t = span(s);
    for (t) |ch|
        if (!(ch >= 'a' and ch <= 'z'))
            return false;
    return t.len > 0 and t.len < 16;
}

/// Adds the directory ch as a member of in, rooted at at, on top unless
/// after. An up member goes on top whatever after says, and others go
/// below it; a union has at most one.
fn unaddmember(in: *Inst, ch: *Chan, at: [*c]const u8, after: bool, create: bool, isup: bool) Error!void {
    if ((ch.qid.type & QTDIR) == 0)
        return kerror(&port.Enotdir);
    const a = try strdupe(at);
    const root = chan.cclone(ch) catch |e| {
        c.free(a);
        return e;
    };
    sync.qlock(&in.ql);
    if (in.nmem >= Maxmembers) {
        sync.qunlock(&in.ql);
        chan.cclose(root);
        c.free(a);
        return kerror("too many union members");
    }
    const mem = in.mem.?;
    const nmem: usize = @intCast(in.nmem);
    const top: usize = @intFromBool(in.nmem > 0 and mem[0].isup != 0);
    if (isup and top != 0) {
        sync.qunlock(&in.ql);
        chan.cclose(root);
        c.free(a);
        return kerror("a union has one up member");
    }
    var m: *Member = undefined;
    if (after and !isup) {
        m = &mem[nmem];
    } else {
        std.mem.copyBackwards(Member, mem[top + 1 .. nmem + 1], mem[top..nmem]);
        m = &mem[top];
    }
    in.memgen += 1;
    m.id = in.memgen;
    m.root = root;
    m.at = a;
    m.create = @intFromBool(create or isup);
    m.isup = @intFromBool(isup);
    in.nmem += 1;
    sync.qunlock(&in.ql);
    wcdrop(in, null, true);
}

/// Removes the member whose root is the same file as ch; false if none is.
fn undelmember(in: *Inst, ch: *Chan) bool {
    sync.qlock(&in.ql);
    const mem = in.members();
    const i = for (mem, 0..) |m, i| {
        const r = m.root;
        if (r.type == ch.type and r.dev == ch.dev and r.qid.path == ch.qid.path)
            break i;
    } else {
        sync.qunlock(&in.ql);
        return false;
    };
    const r = mem[i].root;
    const a = mem[i].at;
    std.mem.copyForwards(Member, mem[i .. mem.len - 1], mem[i + 1 ..]);
    in.nmem -= 1;
    sync.qunlock(&in.ql);
    wcdrop(in, null, true);
    chan.cclose(r);
    c.free(a);
    return true;
}

const Uafter = 1; // match h9_overlay_union's flags in src/kern.zig
const Ucreate = 2;
const Uup = 4; // the union's up layer (design/epoch-0/upper-layers.md)

/// The error as the sys* wrappers report it: in syserrstr.
fn unerrswap() void {
    const p = up();
    const s = p.syserrstr;
    p.syserrstr = p.errstr;
    p.errstr = s;
}

/// An instance number, as strtol reads it: null if spec isn't one.
fn specid(spec: [*c]const u8) ?c_int {
    var e: [*c]u8 = undefined;
    const id = c.strtol(spec, &e, 10);
    if (e[0] != 0 or id < 0)
        return null;
    return @truncate(id);
}

// For the namespace builder in Zig: adds the directory at path (in the
// caller's namespace) as a member of a union, rooted at at ("" for its
// top). spec names the union: a name ("root", made if it doesn't exist),
// an instance number, or "" for a new unnamed one. flags are Uafter (the
// bottom, not the top) and Ucreate. Returns the instance's number, or -1
// with the error as the sys* wrappers report it. A union made here is
// pinned until it's attached, h9_overlay_unpin drops a named one, or
// h9_overlay_drop an unnamed one.

/// Adds the directory ch to the union spec names; see h9_overlay_union.
fn unionchan(spec: [*c]const u8, ch: *Chan, at_: [*c]const u8, flags: c_int) Error!c_int {
    var at = at_;
    while (at[0] == '/')
        at += 1;
    var in: *Inst = undefined;
    if (spec[0] == 0) {
        in = try unnew(null);
    } else if (unvalidname(spec)) {
        c.lock(&instlock);
        const n = unnamed(spec);
        c.unlock(&instlock);
        in = n orelse try unnew(z(spec));
    } else {
        const id = specid(spec) orelse return kerror(&port.Ebadarg);
        c.lock(&instlock);
        var n = instlookup(id);
        if (n != null and (n.?.mode != Union or n.?.pool != h9_overlay_pool()))
            n = null;
        c.unlock(&instlock);
        in = n orelse return kerror(&port.Enonexist);
    }
    try unaddmember(in, ch, at, flags & Uafter != 0, flags & Ucreate != 0, flags & Uup != 0);
    return in.id;
}

fn unionpath(spec: [*:0]const u8, path: [*:0]const u8, at: [*:0]const u8, flags: c_int) Error!c_int {
    const ch = try chan.namec(path, c.Aaccess, 0, 0);
    defer chan.cclose(ch);
    return unionchan(spec, ch, at, flags);
}

/// As unionpath, with the member a 9P connection: the server on fd
/// (in the caller's fd table) attached with aname, as mount(2) would. fd
/// is left open.
fn unionmount(spec: [*:0]const u8, fd: c_int, aname: [*:0]const u8, at: [*:0]const u8, flags: c_int) Error!c_int {
    const bc = try sysfile.fdtochan(fd, ORDWR, false, true);
    const ch = blk: {
        defer chan.cclose(bc);
        break :blk try devmnt.mntattach(bc, null, aname, 0);
    };
    defer chan.cclose(ch);
    // Through a path, as unionpath takes one: the chan's own.
    return unionchan(spec, ch, at, flags);
}

/// The unnamed union ch is the top of, or nil.
fn nsinst(ch: *Chan) ?*Inst {
    if (dcof(ch) != 'O' or !isunion(ch))
        return null;
    const u = uncof(ch);
    if (u.path[0] != 0 or u.inst.name[0] != 0)
        return null;
    return u.inst;
}

/// in's members as bind -r lines onto old, in the order that makes them
/// again: old's own member first (a union itself if bind -r made one over
/// another, printed in turn), then those above it with -b and those
/// below it with -a.
fn nsunion1(in: *Inst, old: [*c]const u8, p_: [*c]u8, e: [*c]u8, depth: c_int) [*c]u8 {
    var p = p_;
    sync.qlock(&in.ql);
    defer sync.qunlock(&in.ql);
    const mem = in.members();
    var j: usize = mem.len;
    var i: usize = mem.len;
    while (i > 0) {
        i -= 1;
        if (eq(chan.chanpath(mem[i].root), old)) {
            j = i;
            break;
        }
    }
    if (j < mem.len and depth < 8) {
        if (nsinst(mem[j].root)) |sub| {
            if (sub != in)
                p = nsunion1(sub, old, p, e, depth + 1);
        }
    }
    i = j;
    while (i > 0 and @intFromPtr(p) < @intFromPtr(e)) {
        i -= 1;
        const m = &mem[i];
        if (m.at[0] != 0)
            continue;
        const fmt: [*c]const u8 = if (m.isup != 0) "bind -u %q %q\n" else if (m.create != 0) "bind -rbc %q %q\n" else "bind -rb %q %q\n";
        p = c.seprint(p, e, @constCast(fmt), chan.chanpath(m.root), old);
    }
    i = j + 1;
    while (i < mem.len and @intFromPtr(p) < @intFromPtr(e)) : (i += 1) {
        const m = &mem[i];
        if (m.at[0] == 0) {
            const fmt: [*c]const u8 = if (m.create != 0) "bind -rac %q %q\n" else "bind -ra %q %q\n";
            p = c.seprint(p, e, @constCast(fmt), chan.chanpath(m.root), old);
        }
    }
    return p;
}

/// For devproc's ns: if ch is the top of an unnamed union bound at old,
/// prints it as the bind -r lines that make it again and returns their
/// length; otherwise -1. A member rooted below the top can't be written
/// as a line and is left out.
fn nsunion(ch: *Chan, old: [*c]const u8, buf: [*c]u8, nbuf: c_int) callconv(.c) c_int {
    const in = nsinst(ch) orelse return -1;
    const e = nsunion1(in, old, buf, buf + @as(usize, @intCast(nbuf)), 0);
    return @intCast(@intFromPtr(e) - @intFromPtr(buf));
}

/// The number of the union whose top path is (in the caller's namespace),
/// or -1: for bind -r onto a union already there.
fn unionof(path: [*:0]const u8) Error!c_int {
    const ch = try chan.namec(path, c.Aaccess, 0, 0);
    defer chan.cclose(ch);
    if (dcof(ch) == 'O' and isunion(ch)) {
        const u = uncof(ch);
        if (u.path[0] == 0)
            return u.inst.id;
    }
    return -1;
}

/// Gives the named union name a copy-on-write instance over it, which
/// attaching the name gives from then on: the cow instance's number.
fn cowname(name: [*:0]const u8) Error!c_int {
    if (!unvalidname(name))
        return kerror(&port.Ebadarg);
    c.lock(&instlock);
    var u = unnamed(name);
    c.unlock(&instlock);
    if (u == null)
        _ = try unnew(name);
    var spec: [32]u8 = undefined;
    const s = std.fmt.bufPrintSentinel(&spec, "#O{s}", .{std.mem.span(name)}, 0) catch unreachable;
    const ch = try chan.namec(s, c.Aaccess, 0, 0);
    const id = blk: {
        defer chan.cclose(ch);
        break :blk try overlaynew(ch);
    };
    c.lock(&instlock);
    const cw = instlookup(id);
    u = unnamed(name);
    if (cw != null and u != null) {
        if (u.?.cow) |old|
            old.over = null;
        u.?.cow = cw;
        cw.?.over = u;
    }
    c.unlock(&instlock);
    return id;
}

/// Drops the pinned ref of a named union and its cow that were never attached.
fn unpin(name: [*:0]const u8) callconv(.c) void {
    c.lock(&instlock);
    const u = unnamed(name);
    var du = false;
    var dc = false;
    var cw: ?*Inst = null;
    if (u) |x| {
        cw = x.cow;
        if (cw != null and cw.?.pinned != 0) {
            cw.?.pinned = 0;
            dc = true;
        }
        if (x.pinned != 0) {
            x.pinned = 0;
            du = true;
        }
    }
    c.unlock(&instlock);
    if (dc)
        instdecref(cw.?);
    if (du)
        instdecref(u.?);
}

// The device.

// The control tree (design/epoch-0/mounts.md, "Union instances"): a bare #O
// attach is a directory with one file, clone. Opening clone makes an
// unnamed union owned by the opener's machine, unattached; reading it
// gives the union's number, and writes to it take
//
//    add [-a|-b] [-c] PATH    PATH's directory as a member, on top (-b,
//                the default) or at the bottom (-a); -c takes creates
//    upper PATH        PATH's directory as the union's up layer, on top
//                (design/epoch-0/upper-layers.md)
//    del PATH        removes the member that is PATH's directory
//    cow            a copy-on-write instance over the union, which
//                attaching the union's number gives from then on
//
// with PATH resolved in the writer's namespace, so a member is a tree the
// writer could already walk. Binding #ON attaches it; closing clone
// before that lets it go. Its chans have dev Ctldev, and aux nil, or a
// Ctl once clone is open.
const Ctldev: c_uint = std.math.maxInt(c_uint); // ulong is 32 bits here

const Qctldir = 0;
const Qclone = 1;

const Ctl = extern struct {
    id: c_int, // the union clone made
    cow: c_int, // its cow instance, or -1
};

var ctltab = [_]Dirtab{
    dev.dirtab(".", .{ .path = Qctldir, .vers = 0, .type = c.QTDIR }, 0, dev.dmdir | 0o555),
    dev.dirtab("clone", .{ .path = Qclone, .vers = 0, .type = 0 }, 0, 0o666),
};

fn isctl(ch: *Chan) bool {
    return ch.dev == Ctldev;
}

fn ctlof(ch: *Chan) ?*Ctl {
    return @ptrCast(@alignCast(auxof(ch)));
}

fn ctlattach() *Chan {
    const ch = dev.devattach('O', "");
    ch.dev = Ctldev;
    dev.mkqid(&ch.qid, Qctldir, 0, QTDIR);
    dev.aux(ch).* = null;
    return ch;
}

fn ctlwalk(ch: *Chan, nc: ?*Chan, name: [*]const [*:0]const u8, nname: c_int) Error!?*Walkqid {
    return dev.devwalk(ch, nc, name, nname, &ctltab, ctltab.len, dev.devgenC());
}

fn ctlstat(ch: *Chan, db: [*]u8, n: c_int) Error!c_int {
    return dev.devstat(ch, db, n, &ctltab, ctltab.len, dev.devgenC());
}

fn ctlopen(ch: *Chan, omode: c_int) Error!*Chan {
    if (ch.qid.path != Qclone)
        return dev.devopen(ch, omode, &ctltab, ctltab.len, dev.devgenC());
    const k: *Ctl = @ptrCast(@alignCast(c.smalloc(@sizeOf(Ctl))));
    k.cow = -1;
    const in = unnew(null) catch |e| {
        c.free(k);
        return e;
    };
    k.id = in.id;
    errdefer {
        drop(k.id);
        c.free(k);
    }
    const r = try dev.devopen(ch, omode, &ctltab, ctltab.len, dev.devgenC());
    dev.aux(r).* = k;
    return r;
}

fn ctlclose(ch: *Chan) void {
    const k = ctlof(ch) orelse return;
    dev.aux(ch).* = null;
    // Never attached: they go now. The cow holds the union until it goes.
    if (k.cow >= 0)
        drop(k.cow);
    drop(k.id);
    c.free(k);
}

fn ctlread(ch: *Chan, a: ?*anyopaque, n: c_int, off: i64) Error!c_int {
    if (ch.qid.type & QTDIR != 0)
        return dev.devdirread(ch, @ptrCast(a.?), n, &ctltab, ctltab.len, dev.devgenC());
    const k = ctlof(ch) orelse return kerror(&port.Ebadusefd);
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrintSentinel(&buf, "{d}\n", .{k.id}, 0) catch unreachable;
    return c.readstr(@truncate(@as(u64, @bitCast(off))), @ptrCast(a), @intCast(n), @constCast(s.ptr));
}

/// The union clone made, with a reference; Enonexist if it's gone.
fn ctlinst(k: *Ctl) Error!*Inst {
    c.lock(&instlock);
    defer c.unlock(&instlock);
    const in = instlookup(k.id) orelse return kerror(&port.Enonexist);
    if (in.mode != Union or in.pool != h9_overlay_pool())
        return kerror(&port.Enonexist);
    in.ref += 1;
    return in;
}

fn ctlwrite(ch: *Chan, a: ?*const anyopaque, n: c_int, off: i64) Error!c_int {
    _ = off;
    if (ch.qid.type & QTDIR != 0)
        return kerror(&port.Eisdir);
    const k = ctlof(ch) orelse return kerror(&port.Ebadusefd);
    const cb: *c.Cmdbuf = c.parsecmd(@ptrCast(@constCast(a)), n);
    defer c.free(cb);
    var in: ?*Inst = null;
    var mc: ?*Chan = null;
    defer {
        if (mc) |x| chan.cclose(x);
        if (in) |x| instdecref(x);
    }
    if (cb.nf < 1)
        return kerror(&port.Ebadctl);
    const f = cb.f;
    const nf: usize = @intCast(cb.nf);
    if (eq(f[0], "upper")) {
        if (nf != 2)
            return kerror(&port.Ebadctl);
        const x = try ctlinst(k);
        in = x;
        mc = try chan.namec(z(f[1]), c.Aaccess, 0, 0);
        try unaddmember(x, mc.?, "", false, true, true);
    } else if (eq(f[0], "add")) {
        var after = false;
        var create = false;
        var i: usize = 1;
        while (i + 1 < nf) : (i += 1) {
            if (eq(f[i], "-a"))
                after = true
            else if (eq(f[i], "-b"))
                after = false
            else if (eq(f[i], "-c"))
                create = true
            else if (eq(f[i], "-ac") or eq(f[i], "-ca")) {
                after = true;
                create = true;
            } else if (eq(f[i], "-bc") or eq(f[i], "-cb"))
                create = true
            else
                return kerror(&port.Ebadctl);
        }
        if (nf < 2)
            return kerror(&port.Ebadctl);
        const path = f[nf - 1];
        const x = try ctlinst(k);
        in = x;
        mc = try chan.namec(z(path), c.Aaccess, 0, 0);
        try unaddmember(x, mc.?, "", after, create, false);
    } else if (eq(f[0], "del")) {
        if (nf != 2)
            return kerror(&port.Ebadctl);
        const x = try ctlinst(k);
        in = x;
        mc = try chan.namec(z(f[1]), c.Aaccess, 0, 0);
        if (!undelmember(x, mc.?))
            return kerror("not a member");
    } else if (eq(f[0], "cow")) {
        if (nf != 1 or k.cow >= 0)
            return kerror(&port.Ebadctl);
        // As cowname does for a named union.
        const un = try ctlinst(k);
        in = un;
        mc = try unattach(un, "");
        in = null; // mc holds the reference now
        const id = try overlaynew(mc.?);
        c.lock(&instlock);
        if (instlookup(id)) |cw| {
            un.cow = cw;
            cw.over = un;
        }
        c.unlock(&instlock);
        k.cow = id;
    } else return kerror(&port.Ebadctl);
    return n;
}

fn ovattach(spec: [*:0]const u8) Error!*Chan {
    if (spec[0] == 0)
        return ctlattach();
    var in_: ?*Inst = undefined;
    if (unvalidname(spec)) {
        // A named union, made empty on first use; or the cow over it.
        c.lock(&instlock);
        in_ = unnamed(spec);
        c.unlock(&instlock);
        if (in_ == null)
            _ = try unnew(spec);
        c.lock(&instlock);
        in_ = unnamed(spec);
        if (in_ != null and in_.?.cow != null)
            in_ = in_.?.cow;
    } else {
        const id = specid(spec) orelse return kerror(&port.Ebadarg);
        c.lock(&instlock);
        in_ = instlookup(id);
        // A union clone gave a cow: the number stands for both.
        if (in_) |x| {
            if (x.mode == Union and x.name[0] == 0 and x.cow != null)
                in_ = x.cow;
        }
    }
    const in = in_ orelse {
        c.unlock(&instlock);
        return kerror(&port.Enonexist);
    };
    if (in.pool != h9_overlay_pool()) {
        c.unlock(&instlock);
        return kerror(&port.Enonexist);
    }
    if (in.pinned != 0)
        in.pinned = 0
    else
        in.ref += 1;
    c.unlock(&instlock);
    errdefer instdecref(in);
    if (in.mode == Union)
        return unattach(in, spec);
    const ch = dev.devattach('O', spec);
    ch.dev = @bitCast(in.id);
    ch.qid = in.root.?.qid;
    errdefer chan.cclose(ch);
    sync.qlock(&in.ql);
    defer sync.qunlock(&in.ql);
    const lower = if (in.lower) |l| try chan.cclone(l) else null;
    dev.aux(ch).* = ovcnew(in, in.root, lower, "") catch |e| {
        chan.cclose(lower);
        return e;
    };
    return ch;
}

/// Re-resolves o from the instance root along path, for "..".
fn ovreroot(o: *Ovc, nc: *Chan, path: [*c]const u8) Error!void {
    const in = o.inst;
    if (o.lower) |l|
        chan.cclose(l);
    o.lower = null;
    nodeunref(in, o.node);
    o.node = in.root;
    in.root.?.ref += 1;
    if (in.lower) |l|
        o.lower = try chan.cclone(l);
    const p = o.path;
    o.path = strdupn("");
    nc.qid = in.root.?.qid;
    defer c.free(p);
    if (o.path == null)
        return kerror(&port.Enomem);
    const n = npathelem(path);
    var buf: [Maxname]u8 = undefined;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        pathelem(path, i, &buf);
        if (!try ovstep(o, nc, &buf, false))
            return kerror(&port.Enonexist);
    }
}

/// Forgets the link a walk's last name followed.
fn droplink(o: *Ovc) void {
    nodeunref(o.inst, o.lnk);
    o.lnk = null;
    c.free(o.lpath);
    o.lpath = null;
}

/// o is at an Nlink: walks it to the link's target. last says this was
/// the walk's last name: then the chan keeps the link beside the target,
/// or stays on the link if the target is missing.
fn follow(o: *Ovc, nc: *Chan, last: bool) Error!void {
    const l = o.node.?;
    o.nlinks += 1;
    if (o.nlinks > Maxlinks)
        return kerror(H9_ELOOP);
    const lpath = try strdupe(o.path);
    const link = span(l.link);
    var tp: [*c]u8 = undefined;
    if (link.len > 0 and link[0] == '/') {
        var s: usize = 0;
        while (s < link.len and link[s] == '/') s += 1;
        tp = strdupn(link.ptr + s);
    } else {
        const n = lastslash(lpath) orelse 0;
        tp = @ptrCast(port.malloc(n + 1 + link.len + 1));
        if (tp != null) {
            if (n > 0) {
                @memcpy(tp[0..n], lpath[0..n]);
                tp[n] = '/';
                @memcpy(tp[n + 1 ..][0 .. link.len + 1], link.ptr[0 .. link.len + 1]);
            } else @memcpy(tp[0 .. link.len + 1], link.ptr[0 .. link.len + 1]);
        }
    }
    if (tp == null) {
        c.free(lpath);
        return kerror(&port.Enomem);
    }
    // Empty names (a//b, a trailing /) are dropped.
    {
        var w: usize = 0;
        var r: usize = 0;
        while (tp[r] != 0) : (r += 1) {
            if (tp[r] == '/' and tp[r + 1] == '/')
                continue;
            tp[w] = tp[r];
            w += 1;
        }
        tp[w] = 0;
        if (w > 0 and tp[w - 1] == '/')
            tp[w - 1] = 0;
    }
    l.ref += 1;
    ovreroot(o, nc, tp) catch |e| {
        c.free(tp);
        if (!last) {
            nodeunref(o.inst, l);
            c.free(lpath);
            return e;
        }
        // A dangling link, walked to as itself.
        if (o.lower) |x|
            chan.cclose(x);
        o.lower = null;
        nodeunref(o.inst, o.node);
        o.node = l;
        c.free(o.path);
        o.path = lpath;
        nc.qid = l.qid;
        return;
    };
    c.free(tp);
    if (last) {
        o.lnk = l;
        o.lpath = lpath;
    } else {
        nodeunref(o.inst, l);
        c.free(lpath);
    }
}

/// Puts a chan that followed a link back on the link itself, for remove and rename.
fn onlink(o: *Ovc) void {
    const l = o.lnk orelse return;
    if (o.lower) |x|
        chan.cclose(x);
    o.lower = null;
    nodeunref(o.inst, o.node);
    o.node = l;
    o.lnk = null;
    c.free(o.path);
    o.path = o.lpath;
    o.lpath = null;
}

/// Walks o (and nc's qid) by one name; returns false if it isn't there. A link
/// is followed; last says the name is the walk's last (see follow).
fn ovstep(o: *Ovc, nc: *Chan, name: [*c]const u8, last: bool) Error!bool {
    if (eq(name, "."))
        return true;
    droplink(o);
    if (eq(name, "..")) {
        if (o.path[0] == 0)
            return true;
        const dir = try strdupe(o.path);
        defer c.free(dir);
        if (lastslash(dir)) |s|
            dir[s] = 0
        else
            dir[0] = 0;
        try ovreroot(o, nc, dir);
        return true;
    }
    if ((nc.qid.type & QTDIR) == 0) {
        seterr(&port.Enotdir);
        return false;
    }
    // The directory may have changed in memory since this chan reached it.
    if (adopt(o) < 0) {
        seterr(&port.Enonexist);
        return false;
    }
    const ch = if (o.node) |n| findchild(n, name) else null;
    var nn: ?*Node = null;
    var nl: ?*Chan = null;
    if (ch) |k| {
        if (k.kind == Nwhite) {
            seterr(&port.Enonexist);
            return false;
        }
        nn = k;
        if (k.kind == Nmark and o.lower != null) {
            nl = try lowerwalk1(o.lower.?, name);
            if (nl == null)
                return false;
        }
    } else {
        if ((o.node != null and o.node.?.kind == Ncopy) or o.lower == null) {
            seterr(&port.Enonexist);
            return false;
        }
        nl = try lowerwalk1(o.lower.?, name);
        if (nl == null)
            return false;
    }
    const np = pathjoin(o.path, name) catch |e| {
        chan.cclose(nl);
        return e;
    };
    c.free(o.path);
    o.path = np;
    if (o.lower) |x|
        chan.cclose(x);
    o.lower = nl;
    if (nn) |k|
        k.ref += 1;
    nodeunref(o.inst, o.node);
    o.node = nn;
    nc.qid = if (nn) |k| k.qid else nl.?.qid;
    // A Linux process's walk stops at the link (ovwalk).
    if (nn != null and nn.?.kind == Nlink and h9_fs_linkwalk() == 0)
        follow(o, nc, last) catch return false; // the error is in up.errstr
    return true;
}

fn ovwalk(ch: *Chan, nc_: ?*Chan, name: [*]const [*:0]const u8, nname: c_int) Error!?*Walkqid {
    if (isctl(ch))
        return ctlwalk(ch, nc_, name, nname);
    if (isunion(ch))
        return unwalk(ch, nc_, name, nname);

    if (nc_ != null)
        port.kpanic("ovwalk: nc != nil", .{});
    const o = ovcof(ch);
    const in = o.inst;
    const wq = dev.walkqid(@intCast(nname));
    const nc = dev.devclone(ch);
    nc.type = 0; // our close mustn't see it until it's done
    dev.aux(nc).* = null;
    var no: ?*Ovc = null;
    instincref(in);
    sync.qlock(&in.ql);
    const i = ovwalk1(o, nc, name, nname, wq, &no) catch {
        sync.qunlock(&in.ql);
        if (no) |x| ovcfree(x) else instdecref(in);
        chan.cclose(nc);
        c.free(wq);
        return null;
    };
    wq.nqid = @intCast(i);
    sync.qunlock(&in.ql);
    if (i < nname) {
        ovcfree(no);
        chan.cclose(nc);
        if (i == 0) {
            c.free(wq);
            return null;
        }
        wq.libclone = null;
        return wq;
    }
    dev.aux(nc).* = no;
    nc.type = ch.type;
    wq.libclone = nc;
    return wq;
}

/// ovwalk's walk, under in.ql: the names walked.
fn ovwalk1(o: *Ovc, nc: *Chan, name: [*]const [*:0]const u8, nname: c_int, wq: *Walkqid, nop: *?*Ovc) Error!usize {
    const no = try ovcnew(o.inst, o.node, null, o.path);
    nop.* = no;
    if (o.lower) |l|
        no.lower = try chan.cclone(l);
    if (o.lnk) |l| {
        no.lpath = try strdupe(o.lpath);
        no.lnk = l;
        l.ref += 1;
    }
    var i: usize = 0;
    while (i < nname) : (i += 1) {
        no.nlinks = 0;
        if (!try ovstep(no, nc, name[i], i == nname - 1))
            break;
        dev.qids(wq)[i] = nc.qid;
        // A Linux process's walk stops at a link, its own or the lower tree's.
        if (nc.qid.type & H9_QTSYMLINK != 0) {
            i += 1;
            break;
        }
    }
    return i;
}

fn ovstat(ch: *Chan, db: [*]u8, n: c_int) Error!c_int {
    if (isctl(ch))
        return ctlstat(ch, db, n);
    if (isunion(ch))
        return unstat(ch, db, n);

    const o = ovcof(ch);
    const in = o.inst;
    sync.qlock(&in.ql);
    defer sync.qunlock(&in.ql);
    if (o.lopen == 0)
        try refresh(ch);
    if (o.node != null and o.lopen == 0) {
        var d: Dir = undefined;
        node2dir(ch, o.node.?, &d);
        const r = c.convD2M(&d, db, @intCast(n));
        if (r == 0)
            return kerror(&port.Eshortstat);
        return @intCast(r);
    }
    return dstat(o.lower.?, db, n);
}

fn iswrite(omode: c_int) bool {
    const m = omode & 3;
    return m == OWRITE or m == ORDWR or (omode & OTRUNC) != 0;
}

fn ovopen(ch: *Chan, omode: c_int) Error!*Chan {
    if (isctl(ch))
        return ctlopen(ch, omode);
    if (isunion(ch))
        return unopen(ch, omode);

    const o = ovcof(ch);
    const in = o.inst;
    const mode = try sysfile.openmode(@bitCast(omode));
    sync.qlock(&in.ql);
    defer sync.qunlock(&in.ql);
    try refresh(ch);
    if (o.node != null and o.node.?.kind == Nlink)
        return kerror(if (h9_fs_linkwalk() != 0) H9_ELOOP else &port.Enonexist); // a link not followed, or whose target is missing
    // Exclusive use, as 9front's file servers do: one open at a time.
    if (o.node != null and (o.node.?.mode & DMEXCL) != 0 and o.node.?.excl != 0)
        return kerror(Elocked);
    if (ch.qid.type & QTDIR != 0) {
        if (mode != OREAD or (omode & OTRUNC) != 0)
            return kerror(&port.Eisdir);
        if (o.node == null) {
            o.lower = try dopen(o.lower.?, OREAD);
            o.lopen = 1;
        }
    } else if (o.node == null and h9_fs_isfifo(o.lower.?) != 0) {
        // A host FIFO isn't copied up for a write: it has no data, and
        // a Linux open of it joins a pipe instead (src/kern/fifo.c).
        o.lower = try dopen(o.lower.?, OREAD);
        o.lopen = 1;
    } else if (!iswrite(omode)) {
        if (o.node) |n|
            try ovperm(n.mode, omode)
        else {
            o.lower = try dopen(o.lower.?, omode & ~(OTRUNC | ORCLOSE | OCEXEC));
            o.lopen = 1;
        }
    } else {
        if (o.node == null) {
            var sb: Statbuf = .{};
            var d: Dir = undefined;
            try sb.stat(o.lower.?, &d);
            try ovperm(d.mode, omode);
            try copyup(ch, (omode & OTRUNC) != 0);
        } else try ovperm(o.node.?.mode, omode);
        const n = o.node.?;
        if ((omode & OTRUNC) != 0 and n.length > 0) {
            n.length = 0;
            trimblocks(in, n, 0);
        }
        if (omode & OTRUNC != 0) {
            n.qid.vers +%= 1;
            n.mtime = now();
        }
        ch.qid = n.qid;
    }
    if (o.node) |n| {
        if ((n.mode & DMEXCL) != 0 and (ch.qid.type & QTDIR) == 0) {
            n.excl = 1;
            o.excl = 1;
        }
    }
    if (omode & ORCLOSE != 0)
        ch.flag |= CRCLOSE;
    ch.mode = @intCast(mode);
    ch.flag |= COPEN;
    ch.offset = 0;
    return ch;
}

fn ovname(name: [*c]const u8) bool {
    if (name[0] == 0 or eq(name, ".") or eq(name, ".."))
        return false;
    if (std.mem.indexOfScalar(u8, span(name), '/') != null)
        return false;
    return slen(name) < Maxname;
}

fn ovcreate(ch: *Chan, name: [*c]const u8, omode: c_int, perm: c_uint) Error!*Chan {
    if (isctl(ch))
        return kerror(&port.Eperm);
    if (isunion(ch))
        return uncreate(ch, name, omode, perm);

    const o = ovcof(ch);
    const in = o.inst;
    if ((ch.qid.type & QTDIR) == 0)
        return kerror(&port.Enotdir);
    if (!ovname(name))
        return badname(name);
    if ((perm & DMDIR) != 0 and try sysfile.openmode(@bitCast(omode)) != OREAD)
        return kerror(&port.Eperm);
    sync.qlock(&in.ql);
    defer sync.qunlock(&in.ql);
    try refresh(ch);
    if (o.node == null) {
        const d = try markpath(in, o.path, npathelem(o.path));
        d.ref += 1;
        o.node = d;
    }
    const dir = o.node.?;
    try ovperm(dir.mode, OWRITE);
    const ex = findchild(dir, name);
    if (ex != null and ex.?.kind != Nwhite)
        return kerror(&port.Eexist);
    if (ex == null and dir.kind == Nmark and o.lower != null) {
        if (try lowerwalk1(o.lower.?, name)) |lc| {
            chan.cclose(lc);
            return kerror(&port.Eexist);
        }
    }
    const fresh = ex == null;
    const np = try pathjoin(o.path, name);
    var k: *Node = undefined;
    {
        errdefer c.free(np);
        if (fresh) {
            k = try newnode(in, Ncopy, name);
            setstrs(in, k, ovuser(), ovuser(), ovuser()) catch |e| {
                nodefree(in, k);
                return e;
            };
        } else {
            // Over a whiteout: the name exists below, hidden by the copy.
            k = ex.?;
            try setstrs(in, k, ovuser(), ovuser(), ovuser());
            k.kind = Ncopy;
            k.inlower = 1;
        }
    }
    newqid(in, k, (perm & DMDIR) != 0);
    if (perm & DMDIR != 0)
        k.mode = (perm & ~@as(c_uint, 0o777)) | (perm & dir.mode & 0o777)
    else
        k.mode = (perm & ~@as(c_uint, 0o666)) | (perm & dir.mode & 0o666);
    k.atime = now();
    k.mtime = k.atime;
    k.length = 0;
    if (fresh)
        ovlink(dir, k);
    c.free(o.path);
    o.path = np;
    if (o.lower) |l|
        chan.cclose(l);
    o.lower = null;
    k.ref += 1;
    nodeunref(in, o.node);
    o.node = k;
    ch.qid = k.qid;
    changed(in, o.path);
    if ((k.mode & DMEXCL) != 0 and (perm & DMDIR) == 0) {
        k.excl = 1;
        o.excl = 1;
    }
    if (omode & ORCLOSE != 0)
        ch.flag |= CRCLOSE;
    ch.mode = @intCast(try sysfile.openmode(@bitCast(omode)));
    ch.flag |= COPEN;
    ch.offset = 0;
    return ch;
}

/// Removes the chan's name from the tree. Called with the instance locked.
fn removelocked(ch: *Chan) Error!void {
    const o = ovcof(ch);
    const in = o.inst;
    onlink(o);
    try refresh(ch);
    if (o.node == in.root)
        return kerror(&port.Eperm);
    if (o.node) |n| {
        if ((n.qid.type & QTDIR) != 0 and !try dirempty(ch))
            return kerror(Enotempty);
        const dir = n.parent.?;
        try ovperm(dir.mode, OWRITE);
        var w: ?*Node = null;
        if (n.inlower != 0)
            w = try newnode(in, Nwhite, n.name);
        ovunlink(in, n);
        if (w) |x| {
            x.inlower = 1;
            ovlink(dir, x);
        }
        changed(in, o.path);
        return;
    }
    if ((ch.qid.type & QTDIR) != 0 and !try dirempty(ch))
        return kerror(Enotempty);
    const ne = npathelem(o.path);
    const dir = try markpath(in, o.path, ne - 1);
    try ovperm(dir.mode, OWRITE);
    var name: [Maxname]u8 = undefined;
    pathelem(o.path, ne - 1, &name);
    const w = try newnode(in, Nwhite, &name);
    w.inlower = 1;
    ovlink(dir, w);
    changed(in, o.path);
}

fn ovremove(ch: *Chan) Error!void {
    if (isctl(ch))
        return kerror(&port.Eperm);
    if (isunion(ch))
        return unremove(ch);

    const o = ovcof(ch);
    const in = o.inst;
    {
        // sysremove doesn't close the chan through us afterwards.
        errdefer {
            dev.aux(ch).* = null;
            ovcfree(o);
        }
        sync.qlock(&in.ql);
        defer sync.qunlock(&in.ql);
        try removelocked(ch);
    }
    dev.aux(ch).* = null;
    ovcfree(o);
}

fn ovclose(ch: *Chan) Error!void {
    if (isctl(ch)) {
        ctlclose(ch);
        return;
    }
    const o: *Ovc = @ptrCast(@alignCast(auxof(ch) orelse return));
    if (isunion(ch)) {
        unclose(ch);
        return;
    }
    const in = o.inst;
    if ((ch.flag & (COPEN | CRCLOSE)) == (COPEN | CRCLOSE)) {
        sync.qlock(&in.ql);
        removelocked(ch) catch {};
        sync.qunlock(&in.ql);
    }
    dev.aux(ch).* = null;
    ovcfree(o);
}

fn ovread(ch: *Chan, a: ?*anyopaque, n: c_int, off: i64) Error!c_int {
    if (isctl(ch))
        return ctlread(ch, a, n, off);
    if (isunion(ch))
        return unread(ch, a, n, off);

    const o = ovcof(ch);
    const in = o.inst;
    if (o.lopen != 0)
        return dread(o.lower.?, a, n, off);
    sync.qlock(&in.ql);
    defer sync.qunlock(&in.ql);
    if (ch.qid.type & QTDIR != 0) {
        if (off == 0 or o.dir == null)
            try snapshot(ch);
        // Whole entries only, from off.
        return snapread(o.dir, o.ndir, a, n, off);
    }
    const m = blkread(in, o.node.?, @ptrCast(a.?), n, off);
    o.node.?.atime = now();
    return m;
}

fn ovwrite(ch: *Chan, a: ?*const anyopaque, n: c_int, off_: i64) Error!c_int {
    if (isctl(ch))
        return ctlwrite(ch, a, n, off_);
    if (isunion(ch))
        return unwrite(ch, a, n, off_);

    const o = ovcof(ch);
    const in = o.inst;
    var off = off_;
    if (ch.qid.type & QTDIR != 0)
        return kerror(&port.Eisdir);
    if (o.lopen != 0 or o.node == null)
        return kerror(&port.Eperm);
    sync.qlock(&in.ql);
    defer sync.qunlock(&in.ql);
    const nd = o.node.?;
    if (nd.kind == Nfifo)
        return kerror(&port.Eperm);
    if (nd.mode & DMAPPEND != 0)
        off = nd.length;
    if (!eq(nd.muid, ovuser()))
        try setstrs(in, nd, nd.uid, nd.gid, ovuser());
    try blkwrite(in, nd, @ptrCast(a.?), n, off);
    nd.qid.vers +%= 1;
    nd.mtime = now();
    return n;
}

/// Renames n within its directory.
fn ovrename(ch: *Chan, n: *Node, name: [*c]const u8) Error!void {
    const o = ovcof(ch);
    const in = o.inst;
    if (!ovname(name))
        return badname(name);
    const dir = n.parent orelse return kerror(&port.Eperm);
    try ovperm(dir.mode, OWRITE);
    const ex = findchild(dir, name);
    if (ex == n)
        return;
    if (ex != null and ex.?.kind != Nwhite)
        return kerror(&port.Eexist);
    if (ex == null and dir.kind == Nmark) {
        const ne = npathelem(o.path);
        if (try lowerwalk(in, o.path, ne - 1)) |dl| {
            const lc = lowerwalk1(dl, name) catch |e| {
                chan.cclose(dl);
                return e;
            };
            chan.cclose(dl);
            if (lc) |x| {
                chan.cclose(x);
                return kerror(&port.Eexist);
            }
        }
    }
    const nm = ovstrdup(in, name);
    if (nm == null)
        return kerror(Efull);
    var w: ?*Node = null;
    if (n.inlower != 0) {
        w = newnode(in, Nwhite, n.name) catch |e| {
            ovstrfree(in, nm);
            return e;
        };
        w.?.inlower = 1;
    }
    // The path for this chan; others holding n keep theirs, unused while they hold n.
    const ne: usize = if (lastslash(o.path)) |s| s + 1 else 0;
    const nl = slen(name);
    const np: [*c]u8 = @ptrCast(port.malloc(ne + nl + 1));
    if (np == null) {
        ovstrfree(in, nm);
        if (w) |x|
            nodefree(in, x);
        return kerror(&port.Enomem);
    }
    @memcpy(np[0..ne], o.path[0..ne]);
    @memcpy(np[ne..][0 .. nl + 1], name[0 .. nl + 1]);
    c.free(o.path);
    o.path = np;
    n.ref += 1;
    ovunlink(in, n);
    ovstrfree(in, n.name);
    n.name = nm;
    n.inlower = 0;
    if (ex) |x| {
        // Over a whiteout: the copy now hides the lower file of that name.
        n.inlower = 1;
        ovunlink(in, x);
    }
    ovlink(dir, n);
    if (w) |x|
        ovlink(dir, x);
}

/// Moves ch's name into the directory dch as name, the overlay's rename
/// (design/file-interface.md), for the Linux ABI's renameat, as
/// ovrename does within one directory for a wstat. Both are overlay
/// chans; returns 1 if they're in different instances, or ch is a
/// directory still in the lower tree (Linux's overlayfs refuses that
/// with EXDEV too, and mv copies), and 0 once moved. A file or link
/// named name in dch is replaced, as rename(2) replaces it, and so is an
/// empty directory in memory; a directory beneath ch can't be the
/// target. Zig's cache, for one, makes each entry in tmp/ and renames
/// it into place.
fn move(ch: *Chan, dch: *Chan, name: [*c]const u8) Error!c_int {
    if (isunion(ch) or isunion(dch)) {
        if (!isunion(ch) or !isunion(dch))
            return 1;
        return unmove(ch, dch, name);
    }
    const o = ovcof(ch);
    const od = ovcof(dch);
    const in = o.inst;
    if (od.inst != in)
        return 1;
    if (!ovname(name))
        return badname(name);
    sync.qlock(&in.ql);
    defer sync.qunlock(&in.ql);
    onlink(o);
    try refresh(ch);
    try refresh(dch);
    if (o.node == in.root)
        return kerror(&port.Eperm);
    const isdir = (ch.qid.type & QTDIR) != 0;
    if (isdir and (o.node == null or o.node.?.kind == Nmark))
        return 1;
    if ((dch.qid.type & QTDIR) == 0)
        return kerror(&port.Enotdir);
    if (o.node == null)
        try copyup(ch, false);
    const n = o.node.?;
    const odir = n.parent orelse return kerror(&port.Enonexist);
    try ovperm(odir.mode, OWRITE);
    var dir = od.node;
    if (dir == null or dir.?.kind == Nwhite)
        dir = try markpath(in, od.path, npathelem(od.path));
    const dn = dir.?;
    if (dn.kind == Nlink or (dn.qid.type & QTDIR) == 0)
        return kerror(&port.Enotdir);
    try ovperm(dn.mode, OWRITE);
    var d: ?*Node = dn;
    while (d) |x| : (d = x.parent)
        if (x == n)
            return kerror(&port.Ebadarg); // into itself: EINVAL
    const ex = findchild(dn, name);
    if (ex == n)
        return 0;
    var lowerex = false;
    if (ex != null and ex.?.kind != Nwhite) {
        const x = ex.?;
        if ((x.qid.type & QTDIR) != 0 and (x.kind != Ncopy or x.nchild != 0))
            return kerror(Enotempty);
        lowerex = x.inlower != 0;
    } else if (ex != null) {
        lowerex = true; // a whiteout: the lower name stays hidden under n
    } else if (dn.kind == Nmark) {
        if (try lowerwalk(in, od.path, npathelem(od.path))) |dl| {
            const lc = lowerwalk1(dl, name) catch |e| {
                chan.cclose(dl);
                return e;
            };
            chan.cclose(dl);
            if (lc) |x| {
                lowerex = true;
                const xdir = (x.qid.type & QTDIR) != 0;
                chan.cclose(x);
                if (xdir)
                    return kerror(Enotempty);
            }
        }
    }
    var w: ?*Node = null;
    if (n.inlower != 0) {
        w = try newnode(in, Nwhite, n.name);
        w.?.inlower = 1;
    }
    const nm = ovstrdup(in, name);
    if (nm == null) {
        if (w) |x|
            nodefree(in, x);
        return kerror(Efull);
    }
    const np = pathjoinn(od.path, name);
    if (np == null) {
        ovstrfree(in, nm);
        if (w) |x|
            nodefree(in, x);
        return kerror(&port.Enomem);
    }
    // The path for this chan; others holding n keep theirs, unused while they hold n.
    const oldpath = o.path;
    o.path = np;
    n.ref += 1;
    ovunlink(in, n);
    if (w) |x|
        ovlink(odir, x);
    if (ex) |x|
        ovunlink(in, x);
    ovstrfree(in, n.name);
    n.name = nm;
    n.inlower = @intFromBool(lowerex);
    ovlink(dn, n);
    dn.mtime = now();
    odir.mtime = dn.mtime;
    changed(in, oldpath);
    changed(in, o.path);
    c.free(oldpath);
    return 0;
}

fn ovwstat(ch: *Chan, db: [*]u8, n: c_int) Error!c_int {
    if (isctl(ch))
        return kerror(&port.Eperm);
    if (isunion(ch))
        return unwstat(ch, db, n);

    const o = ovcof(ch);
    const in = o.inst;
    const strs: [*]u8 = @ptrCast(c.smalloc(@intCast(n)));
    defer c.free(strs);
    var d: Dir = undefined;
    if (c.convM2D(db, @intCast(n), &d, strs) != n)
        return kerror(&port.Ebadstat);
    sync.qlock(&in.ql);
    defer sync.qunlock(&in.ql);
    // A rename renames the link; other changes go to its target.
    if (o.lnk != null and d.name[0] != 0 and !eq(d.name, o.lnk.?.name)) {
        onlink(o);
        ch.qid = o.node.?.qid;
    }
    try refresh(ch);
    const gone = removedopen(ch);
    const isdir = (ch.qid.type & QTDIR) != 0;
    var nd = o.node;
    const cur: [*c]const u8 = if (nd) |x| x.name else if (lastslash(o.path)) |s| o.path + s + 1 else o.path;
    const chname = d.name[0] != 0 and !eq(d.name, cur);
    const chmode = d.mode != nulldir;
    const chmtime = d.mtime != nulldir;
    const chlen = d.length != -1;
    if (chlen and isdir and d.length != 0)
        return kerror(&port.Eisdir);
    if (chmode and ((d.mode & DMDIR) != 0) != isdir)
        return kerror(&port.Eperm);
    if (chname and isdir and (nd == null or nd.?.kind == Nmark))
        return kerror(&port.Eperm); // a lower directory can't be renamed
    if (o.node == in.root and chname)
        return kerror(&port.Eperm);
    if (gone and chname)
        return kerror(&port.Enonexist);
    if (chname or chmode or chmtime or chlen) {
        if (nd == null) {
            if (isdir) {
                const x = try markpath(in, o.path, npathelem(o.path));
                x.ref += 1;
                o.node = x;
            } else try copyup(ch, false);
            nd = o.node;
        }
        const x = nd.?;
        if (chlen) {
            if (d.length < 0 or d.length > Maxfile)
                return kerror(&port.Etoobig);
            if (d.length < x.length)
                trimblocks(in, x, d.length);
            x.length = d.length;
            x.qid.vers +%= 1;
        }
        if (!gone)
            changed(in, o.path);
        if (chname) {
            try ovrename(ch, x, d.name);
            changed(in, o.path);
        }
        if (chmode)
            x.mode = (x.mode & DMDIR) | (d.mode & ~DMDIR);
        if (chmtime)
            x.mtime = d.mtime;
        if ((ch.flag & COPEN) == 0 or o.lopen == 0)
            ch.qid = x.qid;
    }
    return n;
}

/// The target of the link ch is: an overlay's own, or the lower tree's,
/// through its device, for a name that's below (design/file-interface.md).
fn ovreadlink(ch: *Chan, buf: []u8) Error!?usize {
    if (readlinkown(ch, buf)) |n|
        return n;
    const l = try lowerof(ch) orelse return null;
    defer chan.cclose(l);
    return dev.readlink(l, buf);
}

fn ovsymlink(ch: *Chan, name: [*:0]const u8, target: [*:0]const u8) Error!void {
    return symlink(try chan.cclone(ch), name, target);
}

/// ch's attributes: its stat's, with the lower tree's links, ids, device,
/// and nanoseconds for a name that's below, or a union's member's
/// (design/file-interface.md).
fn ovgetattr(ch: *Chan, mask: u64, a: *Attr) Error!void {
    var buf: [c.Attrstatlen]u8 = undefined;
    var strs: [buf.len]u8 = undefined;
    const n = try ovstat(ch, &buf, buf.len);
    var d: Dir = undefined;
    if (c.convM2D(&buf, @intCast(n), &d, &strs) == 0)
        return kerror(&port.Ebadstat);
    a.* = std.mem.zeroes(Attr);
    a.valid = c.Amode | c.Aatime | c.Amtime | c.Aino | c.Asize;
    a.qid = d.qid;
    a.mode = d.mode;
    a.size = @bitCast(d.length);
    a.atime = d.atime;
    a.mtime = d.mtime;
    const l = try lowerof(ch) orelse return;
    var la: Attr = undefined;
    {
        defer chan.cclose(l);
        try dev.getattr(l, mask, &la);
    }
    a.nlink = la.nlink;
    a.valid |= la.valid & (c.Anlink | c.Auid | c.Agid | c.Ardev | c.Ablocks);
    a.uid = la.uid;
    a.gid = la.gid;
    a.rdev = la.rdev;
    a.blocks = la.blocks;
    if ((la.valid & c.Aatime) != 0 and la.atime == a.atime)
        a.atimens = la.atimens;
    if ((la.valid & c.Amtime) != 0 and la.mtime == a.mtime)
        a.mtimens = la.mtimens;
    if (la.valid & c.Actime != 0) {
        a.valid |= c.Actime;
        a.ctime = la.ctime;
        a.ctimens = la.ctimens;
    }
}

fn ovrename1(ch: *Chan, dch: *Chan, name: [*:0]const u8) Error!bool {
    if (isctl(ch) or isctl(dch))
        return kerror(&port.Eperm);
    return try move(ch, dch, name) == 0;
}

fn ovcreateOp(ch: *Chan, name: [*:0]const u8, omode: c_int, perm: c_uint) Error!*Chan {
    return ovcreate(ch, name, omode, perm);
}

/// The device. A link is the switch's default, a copy: the tree in
/// memory has one name per node.
pub const Device = dev.Native('O', "overlay", .{
    .attach = ovattach,
    .walk = ovwalk,
    .stat = ovstat,
    .open = ovopen,
    .create = ovcreateOp,
    .close = ovclose,
    .read = ovread,
    .write = ovwrite,
    .remove = ovremove,
    .wstat = ovwstat,
    .readlink = ovreadlink,
    .symlink = ovsymlink,
    .getattr = ovgetattr,
    .rename = ovrename1,
});

// The C names, for the C that calls them.

/// h9_overlay_new: -1 with the error set.
fn c_new(lower: ?*Chan) callconv(.c) c_int {
    return overlaynew(lower) catch -1;
}
/// h9_overlay_newpath, and the other calls from the namespace builder:
/// -1 with the error as the sys* wrappers report it.
fn c_newpath(path: ?[*:0]const u8) callconv(.c) c_int {
    return newpath(path) catch {
        unerrswap();
        return -1;
    };
}
fn c_union(spec: [*:0]const u8, path: [*:0]const u8, at: [*:0]const u8, flags: c_int) callconv(.c) c_int {
    return unionpath(spec, path, at, flags) catch {
        unerrswap();
        return -1;
    };
}
fn c_unionmount(spec: [*:0]const u8, fd: c_int, aname: [*:0]const u8, at: [*:0]const u8, flags: c_int) callconv(.c) c_int {
    return unionmount(spec, fd, aname, at, flags) catch {
        unerrswap();
        return -1;
    };
}
fn c_unionof(path: [*:0]const u8) callconv(.c) c_int {
    return unionof(path) catch {
        unerrswap();
        return -1;
    };
}
fn c_cowname(name: [*:0]const u8) callconv(.c) c_int {
    return cowname(name) catch {
        unerrswap();
        return -1;
    };
}
/// h9_overlay_lower and h9_overlay_mkfifo raise, for fifo.c and fscheck.c.
fn c_lower(ch: *Chan) callconv(.c) ?*Chan {
    return lowerof(ch) catch |e| port.raise(e);
}
fn c_mkfifo(ch: *Chan, name: [*:0]const u8, perm: c_uint) callconv(.c) void {
    mkfifo(ch, name, perm) catch |e| port.raise(e);
}

pub fn exportC() void {
    @export(&Device.dev, .{ .name = "overlaydevtab" });
    @export(&c_new, .{ .name = "h9_overlay_new" });
    @export(&c_newpath, .{ .name = "h9_overlay_newpath" });
    @export(&c_lower, .{ .name = "h9_overlay_lower" });
    @export(&c_mkfifo, .{ .name = "h9_overlay_mkfifo" });
    @export(&isfifo, .{ .name = "h9_overlay_isfifo" });
    @export(&drop, .{ .name = "h9_overlay_drop" });
    @export(&track, .{ .name = "h9_overlay_track" });
    @export(&lowerdev, .{ .name = "h9_overlay_lowerdev" });
    @export(&c_union, .{ .name = "h9_overlay_union" });
    @export(&c_unionmount, .{ .name = "h9_overlay_unionmount" });
    @export(&nsunion, .{ .name = "h9_overlay_nsunion" });
    @export(&c_unionof, .{ .name = "h9_overlay_unionof" });
    @export(&c_cowname, .{ .name = "h9_overlay_cowname" });
    @export(&unpin, .{ .name = "h9_overlay_unpin" });
}

const testing = std.testing;
const kt = port.testing;

/// "#O<id>", and its top attached, which holds the instance while a case runs.
const Top = struct {
    spec: [24]u8 = undefined,
    ch: *Chan = undefined,

    fn at(t: *Top, id: c_int) ![*:0]const u8 {
        const s = try std.fmt.bufPrintSentinel(&t.spec, "#O{d}", .{id}, 0);
        t.ch = try chan.namec(s, c.Aaccess, 0, 0);
        return s;
    }

    fn path(t: *Top, buf: []u8, name: []const u8) ![:0]u8 {
        return std.fmt.bufPrintSentinel(buf, "{s}/{s}", .{ std.mem.sliceTo(&t.spec, 0), name }, 0);
    }
};

fn putfile(path: [*:0]const u8, data: []const u8) !void {
    const fd = try sysfile.create(path, c.OWRITE, 0o666);
    defer _ = sysfile.close(fd) catch {};
    _ = try sysfile.pwrite(fd, data.ptr, @intCast(data.len), 0);
}

fn getfile(path: [*:0]const u8, buf: []u8) ![]u8 {
    const fd = try sysfile.open(path, c.OREAD);
    defer _ = sysfile.close(fd) catch {};
    const n: usize = @intCast(try sysfile.pread(fd, buf.ptr, @intCast(buf.len), 0));
    return buf[0..n];
}

fn exists(path: [*:0]const u8) bool {
    var buf: [512]u8 = undefined;
    _ = sysfile.stat(path, &buf, buf.len) catch return false;
    return true;
}

/// The names a directory read gives, joined by spaces, sorted.
fn listing(path: [*:0]const u8, out: []u8) ![]const u8 {
    const fd = try sysfile.open(path, c.OREAD);
    defer _ = sysfile.close(fd) catch {};
    var names: [32][]const u8 = undefined;
    var store: [32][64]u8 = undefined;
    var nn: usize = 0;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n: usize = @intCast(try sysfile.pread(fd, &buf, buf.len, -1));
        if (n == 0) break;
        var p: usize = 0;
        while (p + BIT16SZ <= n) {
            const m: usize = @intCast(BIT16SZ + gbit16(&buf[p]));
            var d: Dir = undefined;
            var strs: [512]u8 = undefined;
            if (c.convM2D(&buf[p], @intCast(m), &d, &strs) != m) break;
            const s = span(d.name);
            @memcpy(store[nn][0..s.len], s);
            names[nn] = store[nn][0..s.len];
            nn += 1;
            p += m;
        }
    }
    std.mem.sort([]const u8, names[0..nn], {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    var w: usize = 0;
    for (names[0..nn], 0..) |s, i| {
        if (i > 0) {
            out[w] = ' ';
            w += 1;
        }
        @memcpy(out[w..][0..s.len], s);
        w += s.len;
    }
    return out[0..w];
}

test "a copy-on-write tree copies up and whites out, and never writes the tree below [kernel-port]" {
    _ = try kt.namespace();
    var low: Top = .{};
    _ = try low.at(try newpath(null));
    defer chan.cclose(low.ch);
    var pb: [64]u8 = undefined;
    var buf: [64]u8 = undefined;
    try putfile(try low.path(&pb, "f"), "below");
    _ = try sysfile.close(try sysfile.create(try low.path(&pb, "d"), c.OREAD, c.DMDIR | 0o777));
    try putfile(try low.path(&pb, "d/g"), "deep");

    var t: Top = .{};
    _ = try t.at(try overlaynew(low.ch));
    defer chan.cclose(t.ch);

    // A create lands in memory, and the tree below doesn't have it.
    try putfile(try t.path(&pb, "new"), "hello");
    try testing.expectEqualStrings("hello", try getfile(try t.path(&pb, "new"), &buf));
    try testing.expect(!exists(try low.path(&pb, "new")));

    // A write copies the file up whole first.
    {
        const fd = try sysfile.open(try t.path(&pb, "f"), c.OWRITE);
        defer _ = sysfile.close(fd) catch {};
        _ = try sysfile.pwrite(fd, "BE", 2, 0);
    }
    try testing.expectEqualStrings("BElow", try getfile(try t.path(&pb, "f"), &buf));
    try testing.expectEqualStrings("below", try getfile(try low.path(&pb, "f"), &buf));

    // A directory from below is removed once it's empty, and the removed
    // names are whiteouts.
    try testing.expectError(error.Kernel, sysfile.remove(try t.path(&pb, "d")));
    try testing.expectEqualStrings(Enotempty, kt.errstr());
    _ = try sysfile.remove(try t.path(&pb, "d/g"));
    var lb: [256]u8 = undefined;
    try testing.expectEqualStrings("", try listing(try t.path(&pb, "d"), &lb));
    _ = try sysfile.remove(try t.path(&pb, "d"));
    try testing.expect(!exists(try t.path(&pb, "d")));
    try testing.expectEqualStrings("d f", try listing(try low.path(&pb, "."), &lb));
    try testing.expectEqualStrings("f new", try listing(try t.path(&pb, "."), &lb));

    // A file can't be made over a name that's there, and a whiteout
    // gives the name back to a create.
    try testing.expectError(error.Kernel, sysfile.create(try t.path(&pb, "new"), c.OWRITE | c.OEXCL, 0o666));
    try putfile(try t.path(&pb, "d"), "file now");
    try testing.expectEqualStrings("file now", try getfile(try t.path(&pb, "d"), &buf));
    try testing.expectEqualStrings("deep", try getfile(try low.path(&pb, "d/g"), &buf));
}

test "a union merges its members, and a whiteout hides a name below it [kernel-port]" {
    _ = try kt.namespace();
    var a: Top = .{};
    var b: Top = .{};
    _ = try a.at(try newpath(null));
    defer chan.cclose(a.ch);
    _ = try b.at(try newpath(null));
    defer chan.cclose(b.ch);
    var pb: [64]u8 = undefined;
    var buf: [64]u8 = undefined;
    try putfile(try a.path(&pb, "x"), "ax");
    try putfile(try a.path(&pb, "both"), "A");
    try putfile(try a.path(&pb, ".wh.y"), "");
    try putfile(try b.path(&pb, "both"), "B");
    try putfile(try b.path(&pb, "y"), "by");
    try putfile(try b.path(&pb, "z"), "bz");

    // a on top, b at the bottom.
    const id = try unionchan("", a.ch, "", 0);
    var ib: [16]u8 = undefined;
    try testing.expectEqual(id, try unionchan(try std.fmt.bufPrintSentinel(&ib, "{d}", .{id}, 0), b.ch, "", Uafter));
    var u: Top = .{};
    _ = try u.at(id);
    defer chan.cclose(u.ch);
    try testing.expectEqualStrings("A", try getfile(try u.path(&pb, "both"), &buf));
    try testing.expectEqualStrings("bz", try getfile(try u.path(&pb, "z"), &buf));
    try testing.expect(!exists(try u.path(&pb, "y")));
    var lb: [256]u8 = undefined;
    try testing.expectEqualStrings("both x z", try listing(try u.path(&pb, "."), &lb));

    // A create goes to the first member that takes creates: none here.
    try testing.expectError(error.Kernel, sysfile.create(try u.path(&pb, "new"), c.OWRITE, 0o666));
    try testing.expect(std.mem.startsWith(u8, kt.errstr(), std.mem.span(@as([*:0]const u8, &port.Enocreate))));
}

test "an up layer takes a union's changes, copying up and whiting out [kernel-port]" {
    _ = try kt.namespace();
    var up_: Top = .{};
    var low: Top = .{};
    _ = try up_.at(try newpath(null));
    defer chan.cclose(up_.ch);
    _ = try low.at(try newpath(null));
    defer chan.cclose(low.ch);
    var pb: [64]u8 = undefined;
    var buf: [64]u8 = undefined;
    try putfile(try low.path(&pb, "f"), "below");
    try putfile(try low.path(&pb, "g"), "gone soon");
    _ = try sysfile.close(try sysfile.create(try low.path(&pb, "d"), c.OREAD, c.DMDIR | 0o777));
    try putfile(try low.path(&pb, "d/h"), "deep");

    const id = try unionchan("", low.ch, "", 0);
    var ib: [16]u8 = undefined;
    _ = try unionchan(try std.fmt.bufPrintSentinel(&ib, "{d}", .{id}, 0), up_.ch, "", Uup);
    var u: Top = .{};
    _ = try u.at(id);
    defer chan.cclose(u.ch);

    // A write copies the file up whole first; the member below keeps its own.
    {
        const fd = try sysfile.open(try u.path(&pb, "f"), c.OWRITE);
        defer _ = sysfile.close(fd) catch {};
        _ = try sysfile.pwrite(fd, "BE", 2, 0);
    }
    try testing.expectEqualStrings("BElow", try getfile(try u.path(&pb, "f"), &buf));
    try testing.expectEqualStrings("BElow", try getfile(try up_.path(&pb, "f"), &buf));
    try testing.expectEqualStrings("below", try getfile(try low.path(&pb, "f"), &buf));

    // A remove of a name below leaves a whiteout in the layer.
    _ = try sysfile.remove(try u.path(&pb, "g"));
    try testing.expect(!exists(try u.path(&pb, "g")));
    try testing.expect(exists(try up_.path(&pb, ".wh.g")));
    try testing.expect(exists(try low.path(&pb, "g")));

    // A create under a directory from below makes the directory in the layer.
    try putfile(try u.path(&pb, "d/new"), "n");
    try testing.expect(exists(try up_.path(&pb, "d/new")));
    var lb: [256]u8 = undefined;
    try testing.expectEqualStrings("d f", try listing(try u.path(&pb, "."), &lb));
    try testing.expectEqualStrings("h new", try listing(try u.path(&pb, "d"), &lb));
    // A whiteout's name can't be made in a layer.
    try testing.expectError(error.Kernel, sysfile.create(try u.path(&pb, ".wh.f"), c.OWRITE, 0o666));
}
