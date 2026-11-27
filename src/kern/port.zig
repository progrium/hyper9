//! The kernel's Zig (design/kernel-port.md): drawterm's kern/ ported a
//! file at a time, as close translations, with error unions in place of
//! C's error labels. The rest of the kernel is still C, so each ported file also
//! exports drawterm's C functions under their own names, with their own
//! semantics: a C caller sees no change, and an error becomes C's
//! error() again at that boundary.
//!
//! - `qio.zig`: qio.c and allocb.c, queues and blocks.
//! - `sync.zig`: qlock.c, rwlock.c, and sleep.c, the kernel's locks and
//!   sleep and wakeup.
//! - `dev.zig`: dev.c, the helpers devices are built from, and the
//!   device switch, which calls C devices through `raising`.
//! - `pgrp.zig`: pgrp.c, mount tables, and file descriptor groups.
//! - `chan.zig`: chan.c, channels, paths, mounts, walks, and namec.
//! - `sysfile.zig`: sysfile.c, file descriptors and the file system
//!   calls.
//! - `syswide.zig`: h9's file calls beyond 9P2000's, readlink, symlink,
//!   link, rename, getattr, and setattr (design/file-interface.md).
//! - `devmnt.zig`: devmnt.c, the 9P client.
//! - `dev/pipe.zig` and `dev/root.zig`: devpipe.c and devroot.c.
//! - `dev/srv.zig`: h9's devsrv.c, the service registry.
//! - `dev/overlay.zig`: h9's devoverlay.c, `#O`'s overlays and unions.
//! - `dev/linux.zig`: h9's devlinux.c, the Linux view's root (the kern
//!   library's only: the namespace kernel has no Linux view).
//! - `linux.zig`: h9's linux.c, the Linux ABI's kernel helpers (the kern
//!   library's only, too).
//! - `kserve.zig`: h9's kserve.c, the kernel's 9P2000 server.
//! - `dev/pty.zig`: h9's src/kern/devpty.c, the Linux ABI's ptys.
//! - `netcheck.zig`: h9's src/kern/netcheck.c, devip's sandbox hooks.
//! - `dev/ns.zig`: h9's src/kern/devns.c, the namespace kernel's #N.
//! - `fscheck.zig`: the kernel's half of h9's src/host/fscheck.c, FIFOs
//!   by path for the Linux ABI.
//! - `linuxnet.zig` and `dev/eventfd.zig`: h9's src/kern/linuxnet.c,
//!   the Linux ABI's readiness and socket calls, and #ε.
//! - `ready.zig`: readiness, the device switch's `ready` and `watch`
//!   (design/file-interface.md).
//! - `dev/gfx.zig`: the devices of h9's src/kern/gfx.c, #i, #c, #b, and
//!   #m over drawterm's, in builds with a screen (`options.gfx`).
//!
//! The files only the full kernel has (devip's hooks, the Linux ABI, and
//! the screen) export their C names only there: `options.nskernel` says
//! the namespace kernel is being built.
//!
//! And h9's own C, as it's ported:
//!
//! - `glue.zig`: glue.c, booting the kernel, and the Zig side's small
//!   calls into it.
//! - `proc.zig`: proc.c, the process record, notes, rfork, and wait
//!   records, with drawterm's procinit.c.
//! - `dev/proc.zig`: devproc.c, #p.
//! - `tsleep.zig`: tsleep.c, sleep with a timeout.
//! - `sema.zig`: sema.c, semaphores and rendezvous for guests.
//! - `dev/cons.zig`: drawterm's devcons.c, #c.
//! - `dev/hcons.zig`: devhcons.c, #y, a machine's console.
//! - `fifo.zig`: fifo.c, the Linux ABI's FIFOs.
//! - `rootdial.zig`: rootdial.c, unix socket roots and host descriptors.
//! - `dev/env.zig`: devenv.c, #e, environment variables.
//! - `dev/hstream.zig`: devhstream.c, #ℏ, host streams.
//! - `dev/hidx.zig`: devhidx.c, #ι, metadata indexes for 9P mounts.
//! - `dev/dotl.zig`: devdotl.c, h9's 9P2000.L translation device, `#ℓ`.
//! - `dev/machine.zig`: `#μ`, child machines (design/child-machines.md),
//!   new in Zig.
//!
//! This file is the root the kernel builds compile (build.zig's addKern,
//! and src/nskernel.zig), and holds what the ported files share: the C
//! kernel's types (`c`, translated from port.h with the kernel's flags),
//! `up`, and errors.

const std = @import("std");
const builtin = @import("builtin");

pub const c = @import("kern_c");
pub const options = @import("kern_options");
pub const qio = @import("qio.zig");
pub const sync = @import("sync.zig");
pub const dev = @import("dev.zig");
pub const pgrp = @import("pgrp.zig");
pub const chan = @import("chan.zig");
pub const sysfile = @import("sysfile.zig");
pub const syswide = @import("syswide.zig");
pub const devmnt = @import("devmnt.zig");
pub const devpipe = @import("dev/pipe.zig");
pub const devroot = @import("dev/root.zig");
pub const devsrv = @import("dev/srv.zig");
pub const devoverlay = @import("dev/overlay.zig");
pub const devlinux = @import("dev/linux.zig");
pub const linux = @import("linux.zig");
pub const kserve = @import("kserve.zig");
pub const devpty = @import("dev/pty.zig");
pub const netcheck = @import("netcheck.zig");
pub const fscheck = @import("fscheck.zig");
pub const devns = @import("dev/ns.zig");
pub const linuxnet = @import("linuxnet.zig");
pub const ready = @import("ready.zig");
pub const deveventfd = @import("dev/eventfd.zig");
pub const devgfx = @import("dev/gfx.zig");
pub const glue = @import("glue.zig");
pub const process = @import("proc.zig");
pub const devproc = @import("dev/proc.zig");
pub const tsleep = @import("tsleep.zig");
pub const sema = @import("sema.zig");
pub const devcons = @import("dev/cons.zig");
pub const devhcons = @import("dev/hcons.zig");
pub const fifo = @import("fifo.zig");
pub const rootdial = @import("rootdial.zig");
pub const devenv = @import("dev/env.zig");
pub const devhstream = @import("dev/hstream.zig");
pub const devhidx = @import("dev/hidx.zig");
pub const devmachine = @import("dev/machine.zig");

/// Whether this is the namespace kernel (src/nskernel.zig,
/// design/epoch-0/namespace-kernel.md), which builds with H9_NSKERNEL and
/// has none of h9's devices for running programs (#y, for one).
pub const nskernel = @hasDecl(c, "H9_NSKERNEL");
pub const devdotl = @import("dev/dotl.zig");

comptime {
    qio.exportC();
    sync.exportC();
    dev.exportC();
    pgrp.exportC();
    chan.exportC();
    sysfile.exportC();
    syswide.exportC();
    devmnt.exportC();
    devpipe.exportC();
    devroot.exportC();
    devpty.exportC();
    if (!options.nskernel) {
        netcheck.exportC();
        linuxnet.exportC();
    }
    // Without devfs, nstab.c stands in for these.
    if (options.hostfs) fscheck.exportC();
    if (options.nskernel) devns.exportC();
    if (options.gfx) devgfx.exportC();
    glue.exportC();
    process.exportC();
    if (!nskernel) devproc.exportC();
    tsleep.exportC();
    sema.exportC();
    if (!nskernel) devcons.exportC();
    if (!nskernel) devhcons.exportC();
    fifo.exportC();
    rootdial.exportC();
    if (!nskernel) devenv.exportC();
    devhstream.exportC();
    if (!nskernel) devhidx.exportC();
    if (!nskernel) devmachine.exportC();
    devsrv.exportC();
    devoverlay.exportC();
    kserve.exportC();
    if (!nskernel) {
        devlinux.exportC();
        linux.exportC();
    }
    devdotl.exportC();
    @import("host_dev").exportC();
}

test {
    // build.zig's kern-test: these files' cases, linked with the native
    // namespace kernel for the C they run under.
    _ = @import("h9ns");
    _ = qio;
    _ = sync;
    _ = dev;
    _ = pgrp;
    _ = chan;
    _ = sysfile;
    _ = syswide;
    _ = devmnt;
    _ = devpipe;
    _ = devroot;
    _ = devsrv;
    _ = devoverlay;
    _ = devpty;
    _ = netcheck;
    _ = fscheck;
    _ = devns;
    _ = linuxnet;
    _ = ready;
    _ = deveventfd;
    _ = glue;
    _ = process;
    _ = devproc;
    _ = tsleep;
    _ = sema;
    _ = devhcons;
    _ = fifo;
    _ = rootdial;
    _ = devenv;
    _ = devhstream;
    _ = devhidx;
    _ = devdotl;
}

/// A kernel error. The Plan 9 error string is on the process, in
/// `up.errstr`, as C's error() leaves it: `Kernel` for any error, and
/// `Interrupted` when a note interrupted a sleep (the string is Eintr).
pub const Error = error{ Kernel, Interrupted };

/// The current process, drawterm's `up`: the drawterm Proc at the start
/// of its record (h9proc.h).
pub inline fn up() *c.Proc {
    return c._getproc();
}

/// The current process's whole record.
pub inline fn hup() *c.Hproc {
    return hproc(c._getproc());
}

/// The record a drawterm Proc starts: every Proc is made as an Hproc
/// (proc.zig's newproc).
pub inline fn hproc(p: *c.Proc) *c.Hproc {
    return @alignCast(@fieldParentPtr("p", p));
}

/// proc.c's h9_uphproc for Zig: the current process, if it's a guest
/// process (it has a machine), and otherwise an error.
pub fn uphproc() error{Kernel}!*c.Hproc {
    const p: *c.Proc = c._getproc() orelse return error.Kernel;
    const h = hproc(p);
    if (h.mach == null)
        return kerror("not an h9 process");
    return h;
}

pub const ERRMAX = c.ERRMAX;

// error.c's strings. They're arrays (char Eintr[]), which translate-c
// reads as pointers, so they're declared here.
pub extern const Enoerror: [0:0]u8;
pub extern const Emount: [0:0]u8;
pub extern const Eunmount: [0:0]u8;
pub extern const Eunion: [0:0]u8;
pub extern const Emountrpc: [0:0]u8;
pub extern const Eshutdown: [0:0]u8;
pub extern const Enocreate: [0:0]u8;
pub extern const Enonexist: [0:0]u8;
pub extern const Eexist: [0:0]u8;
pub extern const Ebadsharp: [0:0]u8;
pub extern const Enotdir: [0:0]u8;
pub extern const Eisdir: [0:0]u8;
pub extern const Ebadchar: [0:0]u8;
pub extern const Efilename: [0:0]u8;
pub extern const Eperm: [0:0]u8;
pub extern const Ebadusefd: [0:0]u8;
pub extern const Ebadarg: [0:0]u8;
pub extern const Einuse: [0:0]u8;
pub extern const Eio: [0:0]u8;
pub extern const Etoobig: [0:0]u8;
pub extern const Etoosmall: [0:0]u8;
pub extern const Enoport: [0:0]u8;
pub extern const Ehungup: [0:0]u8;
pub extern const Ebadctl: [0:0]u8;
pub extern const Enodev: [0:0]u8;
pub extern const Eprocdied: [0:0]u8;
pub extern const Enochild: [0:0]u8;
pub extern const Eioload: [0:0]u8;
pub extern const Enovmem: [0:0]u8;
pub extern const Ebadfd: [0:0]u8;
pub extern const Enofd: [0:0]u8;
pub extern const Eisstream: [0:0]u8;
pub extern const Ebadexec: [0:0]u8;
pub extern const Etimedout: [0:0]u8;
pub extern const Econrefused: [0:0]u8;
pub extern const Econinuse: [0:0]u8;
pub extern const Eintr: [0:0]u8;
pub extern const Enomem: [0:0]u8;
pub extern const Enoswap: [0:0]u8;
pub extern const Esoverlap: [0:0]u8;
pub extern const Emouseset: [0:0]u8;
pub extern const Eshort: [0:0]u8;
pub extern const Egreg: [0:0]u8;
pub extern const Ebadspec: [0:0]u8;
pub extern const Enoreg: [0:0]u8;
pub extern const Enoattach: [0:0]u8;
pub extern const Eshortstat: [0:0]u8;
pub extern const Ebadstat: [0:0]u8;
pub extern const Enegoff: [0:0]u8;
pub extern const Ecmdargs: [0:0]u8;
pub extern const Etoolong: [0:0]u8;
pub extern const Edirseek: [0:0]u8;
pub extern const Eismtpt: [0:0]u8;

/// C's error(msg) for Zig: stores msg as the process's error string, and
/// returns the error for the caller to return.
pub fn kerror(msg: [*:0]const u8) error{Kernel} {
    chan.kstrcpy(up().errstr, msg, ERRMAX);
    return error.Kernel;
}

/// error(Eintr), for a sleep a note broke.
pub fn interrupted() error{Interrupted} {
    chan.kstrcpy(up().errstr, &Eintr, ERRMAX);
    return error.Interrupted;
}

/// Raises the error a Zig function returned in the C kernel, as C's
/// error() would have: the string is already on the process. Only an
/// exported function, at the boundary, calls it, and with no `defer`
/// pending in its frame, since it longjmps out of it.
pub fn raise(err: Error) noreturn {
    switch (err) {
        error.Kernel, error.Interrupted => {},
    }
    c.nexterror();
    unreachable;
}

/// drawterm's malloc (kern/alloc.c), which clears what it allocates.
/// The Zig's c.malloc got uncleared memory (libc's, or the compiler's
/// idea of malloc), so the Zig allocates with mallocz.
pub fn malloc(n: usize) ?*anyopaque {
    return c.mallocz(@intCast(n), 1);
}

/// drawterm's panic, which doesn't return.
pub fn kpanic(comptime fmt: [:0]const u8, args: anytype) noreturn {
    @call(.auto, c.panic, .{@as([*c]u8, @constCast(fmt.ptr))} ++ args);
    unreachable;
}

/// drawterm's print, to the kernel's console.
pub fn print(comptime fmt: [:0]const u8, args: anytype) void {
    _ = @call(.auto, c.print, .{@as([*c]u8, @constCast(fmt.ptr))} ++ args);
}

/// For the cases in qio.zig and sync.zig: a booted kernel, and host
/// threads that are kernel processes.
pub const testing = struct {
    extern fn h9ns_boot() c_int;
    extern fn _setproc(p: *c.Proc) void;

    threadlocal var proc: ?*c.Proc = null;

    /// Boots the namespace kernel the cases link (once), and makes the
    /// calling thread a process of its own, so `up` works.
    pub fn begin() !*c.Proc {
        if (h9ns_boot() != 0) return error.Boot;
        return become();
    }

    fn become() *c.Proc {
        if (proc) |p| return p;
        const p: *c.Proc = c.newproc();
        _setproc(p);
        proc = p;
        return p;
    }

    /// A process on a host thread of its own, running f(args).
    pub const Kproc = struct {
        thread: std.Thread,
        p: std.atomic.Value(?*c.Proc) = .init(null),

        pub fn start(k: *Kproc, comptime f: anytype, args: anytype) !void {
            k.* = .{ .thread = undefined };
            k.thread = try std.Thread.spawn(.{}, run, .{ k, f, args });
            while (k.p.load(.acquire) == null) std.Thread.yield() catch {};
        }

        fn run(k: *Kproc, comptime f: anytype, args: anytype) void {
            k.p.store(become(), .release);
            @call(.auto, f, args);
        }

        pub fn proc(k: *Kproc) *c.Proc {
            return k.p.load(.acquire).?;
        }

        pub fn join(k: *Kproc) void {
            k.thread.join();
        }
    };

    /// Waits (up to a few seconds) for p to be asleep on a Rendez, as
    /// sleep leaves it: committed, so a wakeup or a note is what ends it.
    pub fn waitAsleep(p: *c.Proc) !void {
        var i: usize = 0;
        while (i < 5000) : (i += 1) {
            if (@as(*volatile [*c]c.Rendez, &p.r).* != null) return;
            c.osmsleep(1);
        }
        return error.NeverSlept;
    }

    /// The process's error string.
    pub fn errstr() []const u8 {
        return std.mem.sliceTo(up().errstr, 0);
    }

    /// begin, and a namespace of the process's own: a new mount table
    /// and file descriptors, with / and dot at the root device's root.
    /// Each call starts the namespace again.
    pub fn namespace() !*c.Proc {
        const p = try begin();
        try namespaceOf(p);
        return p;
    }

    /// namespace's, for p, which must be `up` (a process on a
    /// continuation, as sync.zig's cases run).
    pub fn namespaceOf(p: *c.Proc) !void {
        if (@as(?*c.Pgrp, p.pgrp)) |old| pgrp.closepgrp(old);
        p.pgrp = try pgrp.newpgrp();
        p.fgrp = try pgrp.dupfgrp(null);
        if (p.rgrp == null) p.rgrp = try pgrp.newrgrp();
        if (@as(?*c.Chan, p.slash)) |s| chan.cclose(s);
        if (@as(?*c.Chan, p.dot)) |d| chan.cclose(d);
        const slash = try chan.namec("#/", c.Atodir, 0, 0);
        chan.pathclose(slash.path);
        slash.path = chan.newpath("/");
        p.slash = slash;
        p.dot = try chan.cclone(slash);
    }
};

/// C's assert, which the kernel builds keep on.
pub fn assert(ok: bool) void {
    if (!ok) kpanic("assert failed", .{});
}
