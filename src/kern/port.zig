//! The kernel's Zig (design/kernel-port.md): drawterm's kern/ ported a
//! file at a time, as close translations, with error unions in place of
//! waserror. The rest of the kernel is still C, so each ported file also
//! exports drawterm's C functions under their own names, with their own
//! semantics: a C caller sees no change, and an error becomes C's
//! error() again at that boundary.
//!
//! - `qio.zig`: qio.c and allocb.c, queues and blocks.
//! - `sync.zig`: qlock.c, rwlock.c, and sleep.c, the kernel's locks and
//!   sleep and wakeup.
//!
//! This file is the root the kernel builds compile (build.zig's addKern,
//! and src/nskernel.zig), and holds what the ported files share: the C
//! kernel's types (`c`, translated from port.h with the kernel's flags),
//! `up`, and errors.

const std = @import("std");
const builtin = @import("builtin");

pub const c = @import("kern_c");
pub const qio = @import("qio.zig");
pub const sync = @import("sync.zig");

comptime {
    qio.exportC();
    sync.exportC();
}

test {
    // build.zig's kern-test: these files' cases, linked with the native
    // namespace kernel for the C they run under.
    _ = @import("h9ns");
    _ = qio;
    _ = sync;
}

/// A kernel error. The Plan 9 error string is on the process, in
/// `up.errstr`, as C's error() leaves it: `Kernel` for any error, and
/// `Interrupted` when a note interrupted a sleep (the string is Eintr).
pub const Error = error{ Kernel, Interrupted };

/// The current process, drawterm's `up`.
pub inline fn up() *c.Proc {
    return c._getproc();
}

pub const ERRMAX = c.ERRMAX;

// error.c's strings. They're arrays (char Eintr[]), which translate-c
// reads as pointers, so they're declared here.
pub extern const Eintr: [0:0]u8;
pub extern const Ehungup: [0:0]u8;

/// C's error(msg) for Zig: stores msg as the process's error string, and
/// returns the error for the caller to return.
pub fn kerror(msg: [*:0]const u8) error{Kernel} {
    c.kstrcpy(up().errstr, @constCast(msg), ERRMAX);
    return error.Kernel;
}

/// error(Eintr), for a sleep a note broke.
pub fn interrupted() error{Interrupted} {
    c.kstrcpy(up().errstr, @constCast(&Eintr), ERRMAX);
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
};

/// C's assert, which the kernel builds keep on.
pub fn assert(ok: bool) void {
    if (!ok) kpanic("assert failed", .{});
}
