//! The host a kernel is given (design/host-handles.md): a table of
//! handles, each the one way a device reaches outside the machine. A
//! handle that's null is a capability the machine doesn't have, so
//! `Host{}` reaches nothing. The policy is which handles exist and what
//! each allows; `fromPlan` (src/host/planned.zig) builds the table a
//! compiled plan describes.
//!
//! Each handle is an interface, a context and a table of functions, as
//! `std.mem.Allocator` is, so an embedder can supply its own: an
//! in-memory tree, a dialer through its own proxy, or a clock it
//! controls.

const std = @import("std");
const builtin = @import("builtin");
const policy = @import("../policy.zig");
const kern = @import("../kern.zig");
const consin = @import("../consin.zig");
const gfx = @import("../gfx.zig");

pub const planned = @import("planned.zig");
pub const fromPlan = planned.fromPlan;
pub const closeDirs = planned.closeDirs;
pub const net = @import("net.zig");
pub const memtree = @import("memtree.zig");
pub const MemTree = memtree.MemTree;

/// An open directory handle: an fd, or on Windows a `HANDLE`.
pub const Handle = if (builtin.os.tag == .windows) std.os.windows.HANDLE else c_int;
/// No handle: a tree that couldn't be opened, or one that's described
/// but not opened (a plan's in a test, or the web host's).
pub const no_handle: Handle = if (builtin.os.tag == .windows) std.os.windows.INVALID_HANDLE_VALUE else -1;

pub const Host = struct {
    /// Named directory handles: the host trees the machine can reach.
    dirs: ?Dirs = null,
    /// Outbound connections, and the names that may be resolved for them.
    dial: ?Dial = null,
    /// Listening addresses.
    listen: ?Listen = null,
    /// Wall and monotonic time.
    clock: ?Clock = null,
    /// The terminal.
    console: ?Console = null,
    /// Entropy.
    random: ?Random = null,
    /// The `--gfx` window, or the headless screen.
    window: ?Window = null,
    /// Host commands (design/host-cmd.md).
    spawn: ?Spawn = null,
};

/// A host tree, by the name the plan gives it.
pub const Dir = struct {
    /// `cwd` for the host cwd, `root` for a host directory at the root of
    /// `/`, and `d1`, `d2`, and so on for the rest, in the plan's order.
    name: []const u8,
    /// The resolved host path the handle is opened on. Only the host side
    /// (`--print`) shows it.
    path: []const u8,
    /// Whether the tree can be changed on the host. A tree under an
    /// overlay is read-only here: the overlay never writes it.
    writable: bool,
    /// Links in the tree resolve inside it (design/epoch-0/symlinks-in-root.md).
    contained: bool = false,
    /// Read-deny paths beneath the tree, relative to it: the one rule a
    /// handle can't express alone.
    deny: []const []const u8 = &.{},
    /// The tree's directory, opened before the machine starts; the host
    /// tree device opens every file beneath it (src/host/dirs.c).
    handle: Handle = no_handle,
    /// For a tree that's one file, its name in `handle`'s directory.
    leaf: ?[]const u8 = null,
    /// A tree with no host directory: an embedder's, in memory, which
    /// `#ū` (src/host/devtree.zig) serves read-only where `path` is bound.
    /// `path` names it in the plan and in mounts, and `handle` is unused.
    tree: ?Tree = null,
};

/// A read-only tree an embedder serves itself. Entries are numbered, the
/// top 0; a directory's children are listed in order.
pub const Tree = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const Entry = struct {
        id: u64,
        name: [:0]const u8,
        dir: bool,
        len: u64 = 0,
        /// Listed with execute permission.
        exec: bool = false,
    };

    pub const VTable = struct {
        entry: *const fn (ctx: *anyopaque, id: u64) ?Entry,
        /// The directory holding `id`, which is 0 for the top.
        parent: *const fn (ctx: *anyopaque, id: u64) u64,
        /// The `i`th entry of directory `id`.
        child: *const fn (ctx: *anyopaque, id: u64, i: usize) ?Entry,
        /// Bytes of file `id` from `off` into `buf`: how many, 0 at the end.
        read: *const fn (ctx: *anyopaque, id: u64, off: u64, buf: []u8) usize,
    };

    pub fn entry(t: Tree, id: u64) ?Entry {
        return t.vtable.entry(t.ctx, id);
    }
    pub fn parent(t: Tree, id: u64) u64 {
        return t.vtable.parent(t.ctx, id);
    }
    pub fn child(t: Tree, id: u64, i: usize) ?Entry {
        return t.vtable.child(t.ctx, id, i);
    }
    pub fn read(t: Tree, id: u64, off: u64, buf: []u8) usize {
        return t.vtable.read(t.ctx, id, off, buf);
    }
    /// The entry of directory `id` named `name`.
    pub fn lookup(t: Tree, id: u64, name: []const u8) ?Entry {
        var i: usize = 0;
        while (t.child(id, i)) |e| : (i += 1) if (std.mem.eql(u8, e.name, name)) return e;
        return null;
    }
};

pub const Dirs = struct {
    list: []const Dir,
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The verdict on `op` on a resolved host path.
        check: *const fn (ctx: *anyopaque, path: []const u8, op: policy.Op) policy.Verdict,
    };

    /// The handle named `name`.
    pub fn get(d: Dirs, name: []const u8) ?*const Dir {
        for (d.list) |*x| if (std.mem.eql(u8, x.name, name)) return x;
        return null;
    }

    /// The handle whose tree holds host path `path`, the deepest if
    /// several do, and the path relative to it: how a namespace file that
    /// names `#U` by a host path finds its handle.
    pub fn holding(d: Dirs, path: []const u8) ?struct { dir: *const Dir, rel: []const u8 } {
        var best: ?*const Dir = null;
        for (d.list) |*x| if (policy.relUnder(x.path, path) != null) {
            if (best == null or x.path.len > best.?.path.len) best = x;
        };
        const b = best orelse return null;
        return .{ .dir = b, .rel = policy.relUnder(b.path, path).? };
    }

    /// The open handle that holds host path `path`, the deepest if several
    /// do, and the path relative to it: where the host tree device opens
    /// a file.
    pub fn opened(d: Dirs, path: []const u8) ?struct { dir: *const Dir, rel: []const u8 } {
        var best: ?*const Dir = null;
        for (d.list) |*x| if (x.handle != no_handle and policy.relUnder(x.path, path) != null) {
            if (best == null or x.path.len > best.?.path.len) best = x;
        };
        const b = best orelse return null;
        return .{ .dir = b, .rel = policy.relUnder(b.path, path).? };
    }

    pub fn check(d: Dirs, path: []const u8, op: policy.Op) policy.Verdict {
        return d.vtable.check(d.ctx, path, op);
    }
};

/// Addresses are devip's 16 bytes, IPv4 as IPv4-mapped IPv6. A null
/// protocol is one devip doesn't name (neither TCP nor UDP).
pub const Dial = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        allows: *const fn (ctx: *anyopaque, proto: ?policy.NetProto, addr: *const [16]u8, port: u16) bool,
        lookup: *const fn (ctx: *anyopaque, proto: ?policy.NetProto, name: []const u8, port: u16) bool,
        resolved: *const fn (ctx: *anyopaque, proto: ?policy.NetProto, name: []const u8, port: u16, addrs: []const [16]u8) void,
        probe: *const fn (ctx: *anyopaque, proto: ?policy.NetProto, addr: *const [16]u8) bool,
        connect: *const fn (ctx: *anyopaque, kind: net.Transport, addr: *const [16]u8, port: u16, until: i64) ?net.Fd,
    };

    /// Whether a connection to `addr!port` may be made.
    pub fn allows(d: Dial, proto: ?policy.NetProto, addr: *const [16]u8, port: u16) bool {
        return d.vtable.allows(d.ctx, proto, addr, port);
    }

    /// Whether `name` may be resolved, for `proto` and `port`.
    pub fn lookup(d: Dial, proto: ?policy.NetProto, name: []const u8, port: u16) bool {
        return d.vtable.lookup(d.ctx, proto, name, port);
    }

    /// Records what an allowed name resolved to, so a connection to one
    /// of its addresses is allowed as the name is.
    pub fn resolved(d: Dial, proto: ?policy.NetProto, name: []const u8, port: u16, addrs: []const [16]u8) void {
        d.vtable.resolved(d.ctx, proto, name, port, addrs);
    }

    /// Whether a connection to `addr` is getaddrinfo's route probe, a
    /// UDP connect to an address recorded for an allowed name that sends
    /// nothing (design/linux-dns.md): allowed, but not to send.
    pub fn probe(d: Dial, proto: ?policy.NetProto, addr: *const [16]u8) bool {
        return d.vtable.probe(d.ctx, proto, addr);
    }

    /// Dials `addr!port` for h9 itself, by `until` (monotonic ms): the
    /// machine's resolver's forwarded queries. It's the host's to make,
    /// so `allows` isn't asked.
    pub fn connect(d: Dial, kind: net.Transport, addr: *const [16]u8, port: u16, until: i64) ?net.Fd {
        return d.vtable.connect(d.ctx, kind, addr, port, until);
    }
};

pub const Listen = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        allows: *const fn (ctx: *anyopaque, proto: ?policy.NetProto, addr: *const [16]u8, port: u16) bool,
        bind: *const fn (ctx: *anyopaque, kind: net.Transport, addr: *const [16]u8, port: u16) ?net.Listener,
    };

    /// Whether the guest may announce on `addr!port`.
    pub fn allows(l: Listen, proto: ?policy.NetProto, addr: *const [16]u8, port: u16) bool {
        return l.vtable.allows(l.ctx, proto, addr, port);
    }

    /// Listens on `addr!port` for h9 itself (port 0 for one the host
    /// picks): the machine's resolver's loopback sockets. Under
    /// `--net=outbound`, where `allows` refuses every guest address, this
    /// is why the listener exists at all.
    pub fn bind(l: Listen, kind: net.Transport, addr: *const [16]u8, port: u16) ?net.Listener {
        return l.vtable.bind(l.ctx, kind, addr, port);
    }
};

pub const Clock = struct {
    ctx: ?*anyopaque = null,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Nanoseconds since the epoch.
        wall: *const fn (ctx: ?*anyopaque) i64,
        /// Nanoseconds that never go backwards.
        mono: *const fn (ctx: ?*anyopaque) i64,
    };

    pub fn wall(c: Clock) i64 {
        return c.vtable.wall(c.ctx);
    }

    pub fn mono(c: Clock) i64 {
        return c.vtable.mono(c.ctx);
    }
};

/// The host streams behind the guest's console: reads from `in` (none
/// means EOF), writes to fd 1 go to `out` and to fd 2 to `err`. This is
/// `Machine.Stdio`.
pub const Console = struct {
    in: ?*std.Io.Reader = null,
    /// Makes a blocked read of `in` return, so a run can end while a
    /// console read is pending. Without it such a run ends `stuck`.
    in_cancel: ?consin.Cancel = null,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    /// Called when the guest turns raw mode on or off (writing `rawon`
    /// or `rawoff` to /dev/consctl, or closing its last consctl), and
    /// echo (`echooff`, `echoon`). The CLI puts the host terminal in
    /// raw mode or turns its echo off. The machine turns both back
    /// when a run ends.
    raw: ?kern.Console.Raw = null,
};

pub const Random = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        fill: *const fn (ctx: *anyopaque, buf: []u8) void,
    };

    pub fn fill(r: Random, buf: []u8) void {
        r.vtable.fill(r.ctx, buf);
    }
};

pub const Window = struct {
    /// The screen asked for.
    options: gfx.Options,
    ctx: ?*anyopaque = null,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Takes the screen for `claim`, whose `close` runs when the user
        /// closes it.
        acquire: *const fn (ctx: ?*anyopaque, io: std.Io, claim: *const gfx.Claim, opts: gfx.Options) gfx.Error!void,
        release: *const fn (ctx: ?*anyopaque, claim: *const gfx.Claim) void,
    };

    pub fn acquire(w: Window, io: std.Io, claim: *const gfx.Claim) gfx.Error!void {
        return w.vtable.acquire(w.ctx, io, claim, w.options);
    }

    pub fn release(w: Window, claim: *const gfx.Claim) void {
        w.vtable.release(w.ctx, claim);
    }
};

/// Host commands. Whether this handle stays here or moves to host-cmd
/// is an open issue of design/host-handles.md; a plan never gives one
/// while `#C` is masked.
pub const Spawn = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Whether the host command `path` may be run.
        allows: *const fn (ctx: *anyopaque, path: []const u8) bool,
    };

    pub fn allows(s: Spawn, path: []const u8) bool {
        return s.vtable.allows(s.ctx, path);
    }
};

test {
    _ = planned;
    _ = @import("dirs.zig");
    _ = memtree;
}

test "an empty Host has no handles [host-handles]" {
    const h: Host = .{};
    try std.testing.expect(h.dirs == null and h.dial == null and h.listen == null and h.clock == null);
    try std.testing.expect(h.console == null and h.random == null and h.window == null and h.spawn == null);
}
