//! Zig side of the drawterm kern seam (DESIGN.md, "Kernel: drawterm kern/
//! and the Zig seam"). Each call goes through one of kern's `sys*` wrappers,
//! which catch kernel errors with waserror and return -1; `errstr` then
//! holds the message. No Zig frame sits between a waserror and an error.
//!
//! The kernel boots once per host process, on a private thread. Each guest
//! process runs on a thread made by `spawn`, and only that thread may make
//! kernel calls for it.

const std = @import("std");
const build_options = @import("build_options");
const policy = @import("policy.zig");
const consin = @import("consin.zig");
const web = @import("web.zig");

/// False where kern isn't built (a checkout without drawterm).
pub const available = build_options.kern;

pub const Error = error{ KernUnavailable, Kern, OutOfMemory };

pub const OREAD = 0;
pub const OWRITE = 1;
pub const ORDWR = 2;
pub const OEXEC = 3;
pub const MREPL = 0;
pub const MBEFORE = 1;
pub const MAFTER = 2;
pub const MCREATE = 4;
pub const MCACHE = 0x10;
pub const ERRMAX = 128;

/// The C side, or stubs where kern isn't built so h9 still links.
const c = if (available) c_real else c_stub;

const c_stub = struct {
    fn h9_kern_boot() c_int {
        return -1;
    }
    fn h9_kern_park() noreturn {
        unreachable;
    }
    fn h9_kern_spawn(_: [*:0]const u8, _: *const fn (?*anyopaque) callconv(.c) void, _: ?*anyopaque) c_int {
        return -1;
    }
    fn h9_kern_pid() c_ulong {
        return 0;
    }
    fn h9_kern_fork(_: c_int, _: c_ulong, _: *const fn (?*anyopaque) callconv(.c) void, _: ?*anyopaque) c_int {
        return -1;
    }
    fn h9_kern_rfork(_: c_int) c_int {
        return -1;
    }
    fn h9_kern_await(_: [*]u8, _: c_int) c_int {
        return -1;
    }
    fn h9_kern_setexits(_: [*:0]const u8) void {}
    fn h9_kern_gpid() c_ulong {
        return 0;
    }
    fn h9_kern_setgpid(_: c_ulong) void {}
    fn h9_kern_settext(_: [*:0]const u8) void {}
    fn h9_kern_aux() ?*anyopaque {
        return null;
    }
    fn h9_kern_setaux(_: ?*anyopaque) void {}
    fn h9_kern_closeexec() void {}
    fn h9_kern_postnote(_: c_ulong, _: [*:0]const u8, _: c_int) c_int {
        return -1;
    }
    fn h9_kern_postnotepg(_: c_ulong, _: [*:0]const u8, _: c_int) void {}
    fn h9_kern_selfref() ?*anyopaque {
        return null;
    }
    fn h9_kern_postnoteref(_: ?*anyopaque, _: [*:0]const u8, _: c_int) c_int {
        return 0;
    }
    fn h9_kern_unref(_: ?*anyopaque) void {}
    fn h9_kern_noteid() c_ulong {
        return 0;
    }
    fn h9_kern_setnotify(_: c_int) void {}
    fn h9_kern_notepending() c_int {
        return 0;
    }
    fn h9_kern_popnote(_: [*]u8, _: u64) c_int {
        return 0;
    }
    fn h9_kern_noted(_: c_int, _: [*]u8) c_int {
        return -1;
    }
    fn h9_kern_execnotes() void {}
    fn h9_kern_wantstop() c_int {
        return 0;
    }
    fn h9_kern_stopwait() c_int {
        return 0;
    }
    fn h9_kern_unstop() void {}
    fn h9_kern_killed() c_int {
        return 0;
    }
    fn h9_kern_exechang() c_int {
        return 0;
    }
    fn h9_kern_settextpath(_: ?[*:0]const u8) void {}
    fn h9_kern_mach() ?*anyopaque {
        return null;
    }
    fn h9_kern_putmach(_: ?*anyopaque) void {}
    fn h9_hostcmd_machend(_: ?*anyopaque) void {}
    fn h9_kern_postmach(_: ?*anyopaque, _: c_int, _: [*:0]const u8, _: c_int) c_int {
        return 0;
    }
    fn syspipe(_: *[2]c_int) c_int {
        return -1;
    }
    fn h9_kern_user() [*:0]const u8 {
        return "none";
    }
    fn h9_kern_devmask(_: [*:0]const u8) void {}
    fn h9_kern_self() ?*anyopaque {
        return null;
    }
    fn h9_kern_interrupt(_: ?*anyopaque) void {}
    fn h9_kern_sleep(_: c_long) c_int {
        return -1;
    }
    fn h9_rendezvous(_: usize, _: usize) usize {
        return std.math.maxInt(usize);
    }
    fn h9_semacquire(_: *i32, _: c_int) c_int {
        return -1;
    }
    fn h9_tsemacquire(_: *i32, _: c_uint) c_int {
        return -1;
    }
    fn h9_semrelease(_: *i32, _: c_int, _: *c_int) c_int {
        return -1;
    }
    fn h9_tflag_new() ?*anyopaque {
        return null;
    }
    fn h9_tflag_free(_: ?*anyopaque) void {}
    fn h9_tflag_set(_: ?*anyopaque) void {}
    fn h9_tflag_sleep(_: ?*anyopaque, _: c_uint) c_int {
        return -1;
    }
    fn h9_ntimers() c_int {
        return 0;
    }
    fn h9_kern_nanomono() u64 {
        return 0;
    }
    fn h9_cons_wake(_: c_ulong) void {}
    var no_err: [ERRMAX:0]u8 = @splat(0);
    fn h9_kern_errstr() [*:0]u8 {
        return &no_err;
    }
    fn h9_fd2path(_: c_int, _: [*]u8, _: c_uint) c_int {
        return -1;
    }
    fn sysopen(_: [*:0]const u8, _: c_int) c_int {
        return -1;
    }
    fn syscreate(_: [*:0]const u8, _: c_int, _: c_uint) c_int {
        return -1;
    }
    fn sysclose(_: c_int) c_int {
        return -1;
    }
    fn syspread(_: c_int, _: [*]u8, _: c_int, _: i64) c_int {
        return -1;
    }
    fn syspwrite(_: c_int, _: [*]const u8, _: c_int, _: i64) c_int {
        return -1;
    }
    fn sysseek(_: c_int, _: i64, _: c_int) i64 {
        return -1;
    }
    fn sysbind(_: [*:0]const u8, _: [*:0]const u8, _: c_int) c_int {
        return -1;
    }
    fn sysmount(_: c_int, _: c_int, _: [*:0]const u8, _: c_int, _: [*:0]const u8) c_int {
        return -1;
    }
    fn sysunmount(_: ?[*:0]const u8, _: [*:0]const u8) c_int {
        return -1;
    }
    fn h9_fauth(_: c_int, _: [*:0]const u8) c_int {
        return -1;
    }
    fn h9_kern_chdir(_: [*:0]const u8) c_int {
        return -1;
    }
    fn h9_kern_setargs(_: [*]const u8, _: c_int) void {}
    fn sysdup(_: c_int, _: c_int) c_int {
        return -1;
    }
    fn sysstat(_: [*:0]const u8, _: [*]u8, _: c_int) c_int {
        return -1;
    }
    fn sysfstat(_: c_int, _: [*]u8, _: c_int) c_int {
        return -1;
    }
    fn sysremove(_: [*:0]const u8) c_int {
        return -1;
    }
    fn syswstat(_: [*:0]const u8, _: [*]u8, _: c_int) c_int {
        return -1;
    }
    fn sysfwstat(_: c_int, _: [*]u8, _: c_int) c_int {
        return -1;
    }
    fn h9_overlay_newpath(_: ?[*:0]const u8) c_int {
        return -1;
    }
    fn h9_fs_readlinkpath(_: [*:0]const u8, _: [*]u8, _: c_int) c_int {
        return -1;
    }
    fn h9_fs_symlinkpath(_: [*:0]const u8, _: [*:0]const u8) c_int {
        return -1;
    }
    fn h9_fs_renamepath(_: [*:0]const u8, _: [*:0]const u8) c_int {
        return 1;
    }
    fn h9_overlay_drop(_: c_int) void {}
    fn h9_overlay_track(_: c_int, _: ?*anyopaque) void {}
    fn h9_kern_release() void {}
    fn h9_unixdial(_: [*:0]const u8) c_int {
        return -1;
    }
    fn h9_kern_upuser() [*:0]const u8 {
        return "none";
    }
    fn h9_kern_setuser(_: [*:0]const u8) void {}
    fn h9_hstream_wake(_: c_ulong) void {}
    fn h9_hstream_fd(_: c_ulong) c_int {
        return -1;
    }
    fn h9_hstream_wait(_: c_ulong) c_int {
        return -1;
    }
};

const c_real = struct {
    extern fn h9_kern_boot() c_int;
    extern fn h9_kern_park() noreturn;
    extern fn h9_kern_spawn(name: [*:0]const u8, func: *const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque) c_int;
    extern fn h9_kern_pid() c_ulong;
    extern fn h9_kern_fork(flag: c_int, pid: c_ulong, func: *const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque) c_int;
    extern fn h9_kern_rfork(flag: c_int) c_int;
    extern fn h9_kern_await(buf: [*]u8, n: c_int) c_int;
    extern fn h9_kern_setexits(msg: [*:0]const u8) void;
    extern fn h9_kern_gpid() c_ulong;
    extern fn h9_kern_setgpid(pid: c_ulong) void;
    extern fn h9_kern_settext(text: [*:0]const u8) void;
    extern fn h9_kern_aux() ?*anyopaque;
    extern fn h9_kern_setaux(aux: ?*anyopaque) void;
    extern fn h9_kern_closeexec() void;
    extern var h9_notekick: ?*const fn (?*anyopaque) callconv(.c) void;
    extern fn h9_kern_postnote(pid: c_ulong, msg: [*:0]const u8, flag: c_int) c_int;
    extern fn h9_kern_postnotepg(noteid: c_ulong, msg: [*:0]const u8, flag: c_int) void;
    extern fn h9_kern_selfref() ?*anyopaque;
    extern fn h9_kern_postnoteref(ref: ?*anyopaque, msg: [*:0]const u8, flag: c_int) c_int;
    extern fn h9_kern_unref(ref: ?*anyopaque) void;
    extern fn h9_kern_noteid() c_ulong;
    extern fn h9_kern_setnotify(on: c_int) void;
    extern fn h9_kern_notepending() c_int;
    extern fn h9_kern_popnote(msg: [*]u8, pc: u64) c_int;
    extern fn h9_kern_noted(arg: c_int, msg: [*]u8) c_int;
    extern fn h9_kern_execnotes() void;
    extern fn h9_kern_wantstop() c_int;
    extern fn h9_kern_stopwait() c_int;
    extern fn h9_kern_unstop() void;
    extern fn h9_kern_killed() c_int;
    extern fn h9_kern_exechang() c_int;
    extern fn h9_kern_settextpath(path: ?[*:0]const u8) void;
    extern var h9_stopkick: ?*const fn (?*anyopaque) callconv(.c) void;
    extern var h9_procdebug: ?*const fn (?*anyopaque, c_int, c_int, u64, ?*anyopaque, c_long) callconv(.c) c_long;
    extern fn h9_kern_mach() ?*anyopaque;
    extern fn h9_kern_putmach(m: ?*anyopaque) void;
    extern fn h9_hostcmd_machend(m: ?*anyopaque) void;
    extern fn h9_kern_postmach(m: ?*anyopaque, all: c_int, msg: [*:0]const u8, flag: c_int) c_int;
    extern fn syspipe(fd: *[2]c_int) c_int;
    extern fn h9_kern_user() [*:0]const u8;
    extern fn h9_kern_devmask(devs: [*:0]const u8) void;
    extern fn h9_kern_self() ?*anyopaque;
    extern fn h9_kern_interrupt(p: ?*anyopaque) void;
    extern fn h9_kern_sleep(ms: c_long) c_int;
    extern fn h9_rendezvous(tag: usize, val: usize) usize;
    extern fn h9_semacquire(addr: *i32, block: c_int) c_int;
    extern fn h9_tsemacquire(addr: *i32, ms: c_uint) c_int;
    extern fn h9_semrelease(addr: *i32, count: c_int, value: *c_int) c_int;
    extern fn h9_tflag_new() ?*anyopaque;
    extern fn h9_tflag_free(f: ?*anyopaque) void;
    extern fn h9_tflag_set(f: ?*anyopaque) void;
    extern fn h9_tflag_sleep(f: ?*anyopaque, ms: c_uint) c_int;
    extern fn h9_ntimers() c_int;
    extern fn h9_kern_nanomono() u64;
    extern fn h9_cons_wake(id: c_ulong) void;
    extern fn h9_kern_errstr() [*:0]u8;
    extern fn h9_fd2path(fd: c_int, buf: [*]u8, n: c_uint) c_int;
    extern fn sysopen(name: [*:0]const u8, mode: c_int) c_int;
    extern fn syscreate(name: [*:0]const u8, mode: c_int, perm: c_uint) c_int;
    extern fn sysclose(fd: c_int) c_int;
    extern fn syspread(fd: c_int, buf: [*]u8, n: c_int, off: i64) c_int;
    extern fn syspwrite(fd: c_int, buf: [*]const u8, n: c_int, off: i64) c_int;
    extern fn sysseek(fd: c_int, off: i64, whence: c_int) i64;
    extern fn sysbind(old: [*:0]const u8, new: [*:0]const u8, flag: c_int) c_int;
    extern fn sysmount(fd: c_int, afd: c_int, new: [*:0]const u8, flag: c_int, spec: [*:0]const u8) c_int;
    extern fn sysunmount(old: ?[*:0]const u8, new: [*:0]const u8) c_int;
    extern fn h9_fauth(fd: c_int, aname: [*:0]const u8) c_int;
    extern fn h9_kern_chdir(name: [*:0]const u8) c_int;
    extern fn h9_kern_setargs(args: [*]const u8, n: c_int) void;
    // drawterm's ulong and long are 32 bits (include/lib.h), so a ulong*
    // the kernel passes is a *c_uint here, never a *c_ulong: writing 8
    // bytes through it overran pstat's locals and crashed h9.
    extern var h9_procstatus: ?*const fn (?*anyopaque, [*]u8, c_int, *c_uint) callconv(.c) void;
    extern var h9_procthreads: ?*const fn (?*anyopaque, *c_uint, *c_uint) callconv(.c) void;
    extern var h9_wantchld: ?*const fn (?*anyopaque) callconv(.c) c_int;
    extern var h9_procsegment: ?*const fn (?*anyopaque, [*]u8, c_int) callconv(.c) c_int;
    extern fn sysdup(fd0: c_int, fd1: c_int) c_int;
    extern fn sysstat(name: [*:0]const u8, buf: [*]u8, n: c_int) c_int;
    extern fn sysfstat(fd: c_int, buf: [*]u8, n: c_int) c_int;
    extern fn sysremove(name: [*:0]const u8) c_int;
    extern fn syswstat(name: [*:0]const u8, buf: [*]u8, n: c_int) c_int;
    extern fn sysfwstat(fd: c_int, buf: [*]u8, n: c_int) c_int;
    extern fn h9_overlay_newpath(path: ?[*:0]const u8) c_int;
    extern fn h9_fs_readlinkpath(path: [*:0]const u8, buf: [*]u8, nbuf: c_int) c_int;
    extern fn h9_fs_symlinkpath(path: [*:0]const u8, target: [*:0]const u8) c_int;
    extern fn h9_fs_renamepath(old: [*:0]const u8, new: [*:0]const u8) c_int;
    extern fn h9_overlay_drop(id: c_int) void;
    extern fn h9_overlay_track(id: c_int, track: ?*anyopaque) void;
    extern fn h9_kern_release() void;
    extern fn h9_unixdial(path: [*:0]const u8) c_int;
    extern fn h9_kern_upuser() [*:0]const u8;
    extern fn h9_kern_setuser(name: [*:0]const u8) void;
    extern fn h9_hstream_wake(id: c_ulong) void;
    extern fn h9_hstream_fd(id: c_ulong) c_int;
    extern fn h9_hstream_wait(id: c_ulong) c_int;
};

const BootState = enum(u8) { idle, booting, up, failed };
var boot_state: std.atomic.Value(BootState) = .init(.idle);

/// Boots the kernel if it isn't already. Safe to call from any thread.
/// The boot runs on a private thread, which becomes the kernel's first
/// Proc for good and then parks.
pub fn boot() Error!void {
    if (!available) return error.KernUnavailable;
    while (true) switch (boot_state.load(.acquire)) {
        .up => return,
        .failed => return error.Kern,
        // On the web host the boot runs on a coroutine, which needs a turn.
        .booting => if (web.enabled) web.yield() else std.atomic.spinLoopHint(),
        .idle => if (boot_state.cmpxchgStrong(.idle, .booting, .acq_rel, .acquire) == null) {
            // The monotonic clock starts at the wall time of the boot.
            _ = monoNs();
            const t = web.Thread.spawn(.{}, bootThread, .{}) catch {
                boot_state.store(.idle, .release);
                return error.OutOfMemory;
            };
            t.detach();
        },
    };
}

fn bootThread() void {
    const ok = c.h9_kern_boot() >= 0;
    boot_state.store(if (ok) .up else .failed, .release);
    // The thread is the boot Proc now, which h9_kern_spawn clones from.
    if (ok) c.h9_kern_park();
}

/// Runs `func(arg)` on a new kernel process with its own host thread, a
/// fresh namespace containing only #/, no fds, an empty environment and no
/// parent. The process ends when `func` returns.
pub fn spawn(name: [*:0]const u8, comptime T: type, comptime func: fn (*T) void, arg: *T) Error!void {
    try boot();
    const Tramp = struct {
        fn run(p: ?*anyopaque) callconv(.c) void {
            func(@ptrCast(@alignCast(p.?)));
        }
    };
    if (c.h9_kern_spawn(name, Tramp.run, arg) < 0) return error.OutOfMemory;
}

/// rfork flags (9front's libc.h).
pub const RF = struct {
    pub const NAMEG = 1 << 0;
    pub const ENVG = 1 << 1;
    pub const FDG = 1 << 2;
    pub const NOTEG = 1 << 3;
    pub const PROC = 1 << 4;
    pub const MEM = 1 << 5;
    pub const NOWAIT = 1 << 6;
    /// Not 9front's: a Linux thread, whose children are its group leader's (hproc.h).
    pub const LXTHREAD = 1 << 30;
    pub const CNAMEG = 1 << 10;
    pub const CENVG = 1 << 11;
    pub const CFDG = 1 << 12;
    pub const REND = 1 << 13;
    pub const NOMNT = 1 << 14;
};

/// rfork with RF.PROC from a process made by `spawn` or `fork`: runs
/// `func(arg)` on a new kernel process that is the caller's child, with its
/// namespace, fds, environment and rendezvous group shared or copied as
/// `flag` says. `pid` is its machine-local pid. Without RF.NOWAIT, its exit
/// leaves a wait record for the caller's `await`. On error `func` never
/// runs, and `errstr` says why.
pub fn fork(flag: c_int, child_pid: u32, comptime T: type, comptime func: fn (*T) void, arg: *T) Error!void {
    const Tramp = struct {
        fn run(p: ?*anyopaque) callconv(.c) void {
            func(@ptrCast(@alignCast(p.?)));
        }
    };
    _ = try check(c.h9_kern_fork(flag, child_pid, Tramp.run, arg));
}

/// rfork without RF.PROC: changes the caller's own groups.
pub fn rfork(flag: c_int) Error!void {
    _ = try check(c.h9_kern_rfork(flag));
}

/// Waits for a child to exit and writes its wait message to `buf`, as the
/// await syscall returns it: "pid utime stime real 'msg'". Fails with "no
/// living children" when there are none.
pub fn await(buf: []u8) Error!usize {
    return try check(c.h9_kern_await(buf.ptr, clampLen(buf.len)));
}

/// Sets the exit string the parent's wait record carries; "" is success.
pub fn setExits(msg: [*:0]const u8) void {
    c.h9_kern_setexits(msg);
}

/// The calling process's machine-local pid (0 if never set).
pub fn guestPid() u32 {
    return @intCast(c.h9_kern_gpid());
}

pub fn setGuestPid(p: u32) void {
    c.h9_kern_setgpid(p);
}

/// Sets the process's name, as wait messages show it.
pub fn setText(text: [*:0]const u8) void {
    c.h9_kern_settext(text);
}

/// The Zig process attached to the calling kernel process.
pub fn aux() ?*anyopaque {
    return c.h9_kern_aux();
}

pub fn setAux(p: ?*anyopaque) void {
    c.h9_kern_setaux(p);
}

/// Closes the calling process's close-on-exec fds.
pub fn closeExec() void {
    c.h9_kern_closeexec();
}

/// Sets the hook a note posted to a process calls, with the process's
/// `aux`, so a process running guest code takes an exit and sees it. It
/// runs on the posting thread with the target's note lock held, and only
/// while `aux` is set; it must not post notes or block.
pub fn setNoteKick(f: *const fn (?*anyopaque) callconv(.c) void) void {
    if (available) c.h9_notekick = f;
}

/// Sets the hook /proc/n/status calls, with the process's `aux`, for its
/// state (into a buffer of the given size) and its memory in KiB. It runs
/// on the reading thread with the target's note lock held, and only while
/// `aux` is set; it must not block or make kernel calls.
pub fn setProcStatus(f: *const fn (?*anyopaque, [*]u8, c_int, *c_uint) callconv(.c) void) void {
    if (available) c.h9_procstatus = f;
}

/// Sets the hook Linux's /proc/n/status and stat call, with the process's
/// `aux`, for its thread group and how many threads it has. It runs as the
/// status hook does.
pub fn setProcThreads(f: *const fn (?*anyopaque, *c_uint, *c_uint) callconv(.c) void) void {
    if (available) c.h9_procthreads = f;
}

/// Sets the hook a child's exit calls, with the parent's `aux` and its
/// note lock held, to ask whether the parent wants SIGCHLD.
pub fn setWantChld(f: *const fn (?*anyopaque) callconv(.c) c_int) void {
    if (available) c.h9_wantchld = f;
}

/// Sets the hook /proc/n/segment calls, with the process's `aux`, for its
/// text (into a buffer of the given size), returning the length. Like the
/// status hook, it runs on the reading thread with the target's note lock
/// held, and only while `aux` is set.
pub fn setProcSegment(f: *const fn (?*anyopaque, [*]u8, c_int) callconv(.c) c_int) void {
    if (available) c.h9_procsegment = f;
}

/// Sets the hook ctl stop and startstop call, with the process's `aux`,
/// so it checks for a stop request at its next stop point
/// (design/0010-self-host.md). Called as the note kick hook is.
pub fn setStopKick(f: *const fn (?*anyopaque) callconv(.c) void) void {
    if (available) c.h9_stopkick = f;
}

/// /proc/n/mem, regs and fpregs (`DebugFile`): the hook moves bytes
/// between the process with this `aux` and a buffer, and returns how many,
/// or a negative `DebugError`. Called as the status hook is, on the reading
/// or writing thread; a write comes only while the process is stopped.
pub const DebugFn = fn (aux: ?*anyopaque, file: c_int, write: c_int, off: u64, buf: ?*anyopaque, n: c_long) callconv(.c) c_long;

pub const DebugFile = enum(c_int) { mem, regs, fpregs };
pub const DebugError = error{ BadAddress, NoRegs, NoMemory };

/// The hook's return for a `DebugError` (hproc.h's D errors).
pub fn debugCode(e: DebugError) c_long {
    return switch (e) {
        error.BadAddress => -1,
        error.NoRegs => -2,
        error.NoMemory => -3,
    };
}

pub fn setProcDebug(f: *const DebugFn) void {
    if (available) c.h9_procdebug = f;
}

/// At a stop point: whether a debugger asked the calling process to stop
/// here (ctl stop, startstop with a note queued, or exec with hang). Takes
/// the request.
pub fn wantStop() bool {
    return c.h9_kern_wantstop() != 0;
}

/// Stops the calling process until ctl start; false if interrupted while
/// still stopped (by a note, ctl kill or the machine's teardown), when the
/// caller either waits again or calls `unstop`.
pub fn stopWait() bool {
    return c.h9_kern_stopwait() == 0;
}

/// Ends a stop without ctl start, for a process about to die.
pub fn unstop() void {
    c.h9_kern_unstop();
}

/// Whether ctl kill has been written for the calling process.
pub fn killed() bool {
    return c.h9_kern_killed() != 0;
}

/// exec's ctl hang: whether the process now stops before its first
/// instruction (`wantStop` will say so).
pub fn execHang() bool {
    return c.h9_kern_exechang() != 0;
}

/// Keeps the image the calling process runs, opened from `path` in its
/// namespace, for /proc/n/text; null drops it.
pub fn setTextPath(path: ?[:0]const u8) void {
    c.h9_kern_settextpath(if (path) |p| p.ptr else null);
}

/// The most of exec's argv /proc/n/args keeps, as 9front's exec.
pub const args_max = 128;

/// Records exec's argv for /proc/n/args: the strings NUL-terminated and
/// run together, cut to `args_max` bytes at a character boundary.
pub fn setArgs(argv: []const []const u8) void {
    var buf: [args_max]u8 = undefined;
    const n = packArgs(&buf, argv);
    c.h9_kern_setargs(&buf, @intCast(n));
}

fn packArgs(buf: *[args_max]u8, argv: []const []const u8) usize {
    var n: usize = 0;
    for (argv) |a| {
        if (n == buf.len) break;
        if (n + a.len + 1 > buf.len) {
            // As 9front: keep what fits, ending at a UTF-8 boundary.
            var k = buf.len - 1 - n;
            if (k > a.len) k = a.len;
            while (k > 0 and k < a.len and (a[k] & 0xc0) == 0x80) k -= 1;
            @memcpy(buf[n..][0..k], a[0..k]);
            n += k;
            buf[n] = 0;
            n += 1;
            break;
        }
        @memcpy(buf[n..][0..a.len], a);
        n += a.len;
        buf[n] = 0;
        n += 1;
    }
    return n;
}

test "packArgs cuts argv to args_max at a character boundary" {
    var buf: [args_max]u8 = undefined;
    try std.testing.expectEqualStrings("ar\x00vu\x00", buf[0..packArgs(&buf, &.{ "ar", "vu" })]);

    // Exactly full, then more arguments: ar's argv in libc's mkfile.
    const full = "x" ** (args_max - 1);
    try std.testing.expectEqual(args_max, packArgs(&buf, &.{ full, "a.7", "b.7" }));
    try std.testing.expectEqual(0, buf[args_max - 1]);

    // The cut would fall inside é, so it backs up to before it.
    const long = "y" ** (args_max - 5) ++ "\u{e9}z";
    const n = packArgs(&buf, &.{ "ab", long });
    try std.testing.expectEqual(args_max - 1, n);
    try std.testing.expectEqualStrings("y" ** (args_max - 5), buf[3 .. n - 1]);
}

/// Who posted a note (9front's NUser, NExit, NDebug). A note that isn't
/// NUser drops the notes queued before it when the process can't handle
/// it; NDebug makes a death from it print "suicide: note".
pub const NoteFlag = enum(c_int) { user = 0, exit = 1, debug = 2 };

/// Posts a note to the process with machine-local `pid` in the caller's
/// machine. Returns false if its queue was full. Fails, with "process
/// exited" as the error string, if there's no such process.
pub fn postNote(to: u32, msg: [*:0]const u8, flag: NoteFlag) Error!bool {
    return try check(c.h9_kern_postnote(to, msg, @intFromEnum(flag))) != 0;
}

/// A reference to the calling process, for notes posted later from any
/// kernel process (`postNoteRef`); null outside an h9 process.
pub fn selfRef() ?*anyopaque {
    return c.h9_kern_selfref();
}

/// Posts a note to a `selfRef` process; false if it wasn't queued (a full
/// queue, or the process ended).
pub fn postNoteRef(ref: *anyopaque, msg: [*:0]const u8, flag: NoteFlag) bool {
    return c.h9_kern_postnoteref(ref, msg, @intFromEnum(flag)) != 0;
}

pub fn unref(ref: *anyopaque) void {
    c.h9_kern_unref(ref);
}

/// Posts a note to every process but the caller in note group `noteid` of
/// the caller's machine.
pub fn postNoteGroup(noteid: u32, msg: [*:0]const u8, flag: NoteFlag) void {
    c.h9_kern_postnotepg(noteid, msg, @intFromEnum(flag));
}

/// The calling process's note group: machine-local, inherited by children
/// and replaced by RF.NOTEG.
pub fn noteId() u32 {
    return @intCast(c.h9_kern_noteid());
}

/// Records whether the calling process has a note handler (`notify`).
pub fn setNotify(on: bool) void {
    c.h9_kern_setnotify(@intFromBool(on));
}

/// Whether the calling process has a note queued.
pub fn notePending() bool {
    return c.h9_kern_notepending() != 0;
}

/// What to do with a popped note.
pub const NoteAction = enum(c_int) {
    /// Nothing to deliver now.
    none = 0,
    /// Enter the handler; the process is in it until `noted`.
    handle = 1,
    /// The process dies with the note as its status.
    kill = 2,
    /// The same, after printing "suicide: note".
    kill_debug = 3,
};

/// Takes the calling process's next note into `msg`, as 9front's popnote
/// does: a "sys:" note posted to this process alone gets " pc=0x..." with
/// `pc` appended. User notes wait while the process is in its handler.
/// Also clears the "interrupt this call" flag.
pub fn popNote(msg: *[ERRMAX]u8, pc: u64) NoteAction {
    msg[0] = 0;
    return @enumFromInt(c.h9_kern_popnote(msg, pc));
}

/// noted's arguments (9front's libc.h).
pub const Noted = enum(c_int) { cont = 0, dflt = 1, save = 2, rstr = 3, _ };

/// The note bookkeeping of noted: `cont`, `save` and `rstr` leave the
/// handler, and `dflt` (or an unknown argument) kills the
/// process with the last note, which is put in `msg`. Fails, with the
/// error string set, for noted outside a handler with anything but `rstr`.
pub fn noted(arg: Noted, msg: *[ERRMAX]u8) Error!NoteAction {
    msg[0] = 0;
    const r = c.h9_kern_noted(@intFromEnum(arg), msg);
    if (r < 0) return error.Kern;
    return @enumFromInt(r);
}

/// A machine as the kernel sees it: the process tree from one `spawn`.
/// Holding one keeps it valid after its processes have exited.
pub const Mach = opaque {
    /// Releases the reference from `mach`.
    pub fn put(m: *Mach) void {
        c.h9_kern_putmach(m);
    }

    /// Kills every host command (#C) the machine started, and any it
    /// starts later. Safe from any thread.
    pub fn endHostCmds(m: *Mach) void {
        c.h9_hostcmd_machend(m);
    }

    /// Who a host-side note goes to.
    pub const To = enum(c_int) {
        /// The foreground note group: the first process's.
        foreground = 0,
        /// Every process.
        all = 1,
    };

    /// Posts a note from the host side (Ctrl-C, hangup, a timeout). Safe
    /// from any thread, including ones that aren't kernel processes.
    /// Returns how many processes it reached.
    pub fn post(m: *Mach, to: To, msg: [*:0]const u8) u32 {
        return @intCast(c.h9_kern_postmach(m, @intFromEnum(to), msg, @intFromEnum(NoteFlag.user)));
    }
};

/// The calling process's machine, with a reference to release with `put`.
pub fn mach() ?*Mach {
    return @ptrCast(c.h9_kern_mach());
}

/// exec's reset of the calling process's notes: no handler, none queued.
pub fn execNotes() void {
    c.h9_kern_execnotes();
}

/// Makes a pipe and returns its two fds.
pub fn pipe() Error![2]u31 {
    var fd: [2]c_int = .{ -1, -1 };
    _ = try check(c.syspipe(&fd));
    return .{ @intCast(fd[0]), @intCast(fd[1]) };
}

/// The host user, which is the kernel's hostowner (eve).
pub fn user() []const u8 {
    return std.mem.span(c.h9_kern_user());
}

/// The calling Proc's kernel pid.
pub fn pid() u32 {
    return @intCast(c.h9_kern_pid());
}

/// Blocks future attaches of the devices named by `devs` (letters, as in
/// `#U`) in the calling Proc's namespace. Existing binds keep working.
pub fn devmask(devs: [*:0]const u8) void {
    c.h9_kern_devmask(devs);
}

/// The calling kernel process, for `interrupt`.
pub const Proc = opaque {};

pub fn self() *Proc {
    return @ptrCast(c.h9_kern_self().?);
}

/// Makes the process's current or next blocking kernel call fail with
/// "interrupted". The caller must know the process hasn't exited.
pub fn interrupt(p: *Proc) void {
    c.h9_kern_interrupt(p);
}

/// Sleeps for `ms` milliseconds, or until the process is interrupted.
pub fn sleep(ms: i64) Error!void {
    _ = try check(c.h9_kern_sleep(@intCast(std.math.clamp(ms, std.math.minInt(c_long), std.math.maxInt(c_long)))));
}

/// rendezvous(tag, val): waits for another process in the rendezvous group
/// to call it with the same tag, and returns that process's value; or
/// ~0 if a note interrupted the wait.
pub fn rendezvous(tag: u64, val: u64) u64 {
    return c.h9_rendezvous(@intCast(tag), @intCast(val));
}

/// semacquire on the host word backing a guest semaphore, which the caller
/// has checked: aligned, and in a writable segment that stays attached
/// while the call blocks. Returns whether it was acquired; fails with
/// "interrupted" on a note, or "bad arg in system call" for a negative value.
pub fn semacquire(addr: *i32, block: bool) Error!bool {
    return try check(c.h9_semacquire(addr, @intFromBool(block))) != 0;
}

/// tsemacquire: as `semacquire`, waiting at most `ms` milliseconds.
pub fn tsemacquire(addr: *i32, ms: u32) Error!bool {
    return try check(c.h9_tsemacquire(addr, ms)) != 0;
}

/// semrelease: adds `count` to the semaphore, wakes up to `count` waiters,
/// and returns the new value.
pub fn semrelease(addr: *i32, count: i32) Error!i32 {
    var v: c_int = 0;
    _ = try check(c.h9_semrelease(addr, count, &v));
    return v;
}

/// The sandbox plan devfs and devip check for the calling thread's
/// process (see src/kern/fscheck.c and src/kern/netcheck.h). Each guest
/// process runs on its own thread, so the
/// plan is per thread; kernel threads without one aren't restricted.
threadlocal var fs_plan: ?*const policy.Plan = null;

pub fn setPlan(p: ?*const policy.Plan) void {
    fs_plan = p;
}

/// Where a machine's overlay memory comes from: its guest-physical page
/// allocator, so ephemeral files count against `--memory`
/// (design/0006-ephemeral-writes.md). Allocations are whole pages of
/// `page_size` bytes; `alloc` returns null when the machine's memory is
/// used up.
pub const Pages = struct {
    ctx: *anyopaque,
    alloc: *const fn (ctx: *anyopaque, n: usize) ?[*]u8,
    free: *const fn (ctx: *anyopaque, p: [*]u8, n: usize) void,

    pub const page_size = 4096;
};

/// The calling thread's machine's pages, for overlays it makes (and to
/// tell machines apart when one attaches `#O<n>`). Kernel threads without
/// a machine use host pages, uncapped.
threadlocal var fs_pages: ?*const Pages = null;

pub fn setPages(p: ?*const Pages) void {
    fs_pages = p;
}

/// Makes a copy-on-write overlay over the directory `lower` (a path in
/// the caller's namespace), or a tree in memory only when null, and
/// returns its instance number for binding `#O<n>`. An instance that's
/// never attached must be dropped.
pub fn overlayNew(lower: ?[*:0]const u8) Error!u32 {
    return try check(c.h9_overlay_newpath(lower));
}

/// The target of the host link that `path`'s last name is, through `#U`
/// and an overlay over it, as the link has it written
/// (design/0034-symlinks-in-root.md). Fails with "not a symbolic link"
/// for anything else. For the Linux personality's readlinkat; Plan 9
/// programs never see links.
pub fn readlink(path: [*:0]const u8, buf: []u8) Error![]u8 {
    const n = try check(c.h9_fs_readlinkpath(path, buf.ptr, @intCast(@min(buf.len, std.math.maxInt(c_int)))));
    return buf[0..@intCast(n)];
}

/// Makes `path` a symbolic link to `target`: in memory in an overlay, or
/// on the host in a devfs tree, where the new name is checked like a
/// create. For the Linux personality's symlinkat; Plan 9 programs never
/// see links.
pub fn symlink(path: [*:0]const u8, target: [*:0]const u8) Error!void {
    _ = try check(c.h9_fs_symlinkpath(path, target));
}

/// Moves `old` to `new` in another directory with the host's rename,
/// when both are in host (devfs) trees; false if either isn't. For the
/// Linux personality's renameat.
pub fn renameAcross(old: [*:0]const u8, new: [*:0]const u8) Error!bool {
    return try check(c.h9_fs_renamepath(old, new)) == 0;
}

/// Frees an overlay made by `overlayNew` that was never attached.
pub fn overlayDrop(id: u32) void {
    c.h9_overlay_drop(@intCast(id));
}

/// Told of each change to an overlay instance after `overlayTrack`: a
/// create, copy-up, remove or wstat, with the changed path relative to
/// the instance's root (`lib/x`), on the changing process's thread with
/// the instance locked. It must not call into the kernel.
pub const OverlayTrack = struct {
    ctx: *anyopaque,
    changed: *const fn (ctx: *anyopaque, path: []const u8) void,
};

/// Reports later changes to overlay `id`, of the calling thread's
/// machine, to `track`, which must outlive the instance (null stops).
pub fn overlayTrack(id: u32, track: ?*const OverlayTrack) void {
    c.h9_overlay_track(@intCast(id), @ptrCast(@constCast(track)));
}

/// Closes the calling process's fds and namespace and moves its current
/// directory to #/, ahead of its exit. The kernel's exit runs after the
/// process's function returns, which may be after its machine is gone; what
/// the namespace holds, an overlay's pages for one, must go first.
pub fn release() void {
    c.h9_kern_release();
}

/// The calling Proc's error string after a failed call.
pub fn errstr() []const u8 {
    return std.mem.span(c.h9_kern_errstr());
}

/// Swaps `buf` (NUL-terminated, at most ERRMAX) with the error string, as
/// the errstr syscall does.
pub fn swapErrstr(buf: *[ERRMAX]u8) void {
    const k = c.h9_kern_errstr();
    var tmp: [ERRMAX]u8 = undefined;
    const kl = std.mem.len(k);
    @memcpy(tmp[0..kl], k[0..kl]);
    tmp[kl] = 0;
    const bl = std.mem.indexOfScalar(u8, buf, 0) orelse ERRMAX - 1;
    @memcpy(k[0..bl], buf[0..bl]);
    k[bl] = 0;
    @memcpy(buf[0 .. kl + 1], tmp[0 .. kl + 1]);
}

/// Sets the error string, for errors h9 raises itself.
pub fn setErrstr(msg: []const u8) void {
    const k = c.h9_kern_errstr();
    const n = @min(msg.len, ERRMAX - 1);
    @memcpy(k[0..n], msg[0..n]);
    k[n] = 0;
}

fn check(r: c_int) Error!u31 {
    if (r < 0) return error.Kern;
    return @intCast(r);
}

fn clampLen(n: usize) c_int {
    return @intCast(@min(n, std.math.maxInt(c_int)));
}

pub fn open(name: [*:0]const u8, mode: c_int) Error!u31 {
    return check(c.sysopen(name, mode));
}

pub fn create(name: [*:0]const u8, mode: c_int, perm: u32) Error!u31 {
    return check(c.syscreate(name, mode, perm));
}

pub fn close(fd: u31) Error!void {
    _ = try check(c.sysclose(fd));
}

/// One read of at most 2 GiB - 1; `off` -1 uses and advances the fd offset.
pub fn pread(fd: u31, buf: []u8, off: i64) Error!usize {
    return try check(c.syspread(fd, buf.ptr, clampLen(buf.len), off));
}

/// One write of at most 2 GiB - 1; `off` -1 uses and advances the fd offset.
pub fn pwrite(fd: u31, buf: []const u8, off: i64) Error!usize {
    return try check(c.syspwrite(fd, buf.ptr, clampLen(buf.len), off));
}

pub fn seek(fd: u31, off: i64, whence: c_int) Error!i64 {
    const r = c.sysseek(fd, off, whence);
    if (r < 0) return error.Kern;
    return r;
}

pub fn bind(old: [*:0]const u8, new: [*:0]const u8, flag: c_int) Error!void {
    _ = try check(c.sysbind(old, new, flag));
}

/// Mounts the 9P server on `fd` at `new`, authenticated with the auth
/// fd `afd` from `fauth`, or -1 for none. Closes `fd`, as 9front's does.
/// Returns the mount's id.
pub fn mount(fd: u31, afd: i32, new: [*:0]const u8, flag: c_int, spec: [*:0]const u8) Error!u31 {
    return try check(c.sysmount(fd, afd, new, flag, spec));
}

/// Starts authenticating to the 9P server on `fd` as `aname` (Tauth),
/// returning an fd on the auth channel. Fails with the server's error
/// when it needs no authentication.
pub fn fauth(fd: u31, aname: [*:0]const u8) Error!u31 {
    return try check(c.h9_fauth(fd, aname));
}

/// Connects to the unix-domain socket at host path `path` and returns an
/// fd on a channel for it (design/0013-9p-roots.md). Fails on Windows.
pub fn unixDial(path: [*:0]const u8) Error!u31 {
    return try check(c.h9_unixdial(path));
}

/// Wakes guest reads and connects waiting on host stream `id`
/// (src/kern/devhstream.c). Called from the stream's thread, which isn't
/// a kernel process, as `wakeConsole` is.
pub fn hstreamWake(id: u32) void {
    c.h9_hstream_wake(id);
}

/// Sleeps in the kernel until host stream `id` has connected or failed;
/// a note interrupts it.
pub fn hstreamWait(id: u32) Error!void {
    _ = try check(c.h9_hstream_wait(id));
}

/// Makes a channel for host-made stream `id` and returns an fd on it.
/// The channel holds the stream; no path names it.
pub fn hstreamFd(id: u32) Error!u31 {
    return try check(c.h9_hstream_fd(id));
}

/// The calling thread's plan, for checks made in Zig leaves.
pub fn currentPlan() ?*const policy.Plan {
    return fs_plan;
}

/// The calling thread's machine's pages, or null for host pages.
pub fn currentPages() ?*const Pages {
    return fs_pages;
}

/// The calling process's user, which devmnt sends as an attach's uname.
pub fn procUser() [:0]const u8 {
    return std.mem.span(c.h9_kern_upuser());
}

/// Sets the calling process's user, cut to the kernel's 27 bytes.
pub fn setProcUser(name: [*:0]const u8) void {
    c.h9_kern_setuser(name);
}

/// Undoes binds and mounts on `new`: only `old`'s, or all with null.
pub fn unmount(old: ?[*:0]const u8, new: [*:0]const u8) Error!void {
    _ = try check(c.sysunmount(old, new));
}

/// chdir, swapping dot so /proc/n readers never see it freed.
pub fn chdir(name: [*:0]const u8) Error!void {
    _ = try check(c.h9_kern_chdir(name));
}

pub fn dup(fd0: u31, fd1: i32) Error!u31 {
    return check(c.sysdup(fd0, fd1));
}

/// Returns the length of the stat message written to `buf`, or, if `buf`
/// is too small, the BIT16SZ size prefix that tells the caller how big.
pub fn stat(name: [*:0]const u8, buf: []u8) Error!usize {
    return try check(c.sysstat(name, buf.ptr, clampLen(buf.len)));
}

pub fn fstat(fd: u31, buf: []u8) Error!usize {
    return try check(c.sysfstat(fd, buf.ptr, clampLen(buf.len)));
}

pub fn wstat(name: [*:0]const u8, buf: []u8) Error!usize {
    return try check(c.syswstat(name, buf.ptr, clampLen(buf.len)));
}

pub fn fwstat(fd: u31, buf: []u8) Error!usize {
    return try check(c.sysfwstat(fd, buf.ptr, clampLen(buf.len)));
}

pub fn remove(name: [*:0]const u8) Error!void {
    _ = try check(c.sysremove(name));
}

pub fn fd2path(fd: u31, buf: []u8) Error!void {
    _ = try check(c.h9_fd2path(fd, buf.ptr, @intCast(@min(buf.len, std.math.maxInt(c_uint)))));
}

/// One machine's console, behind `#y<id>` (src/kern/devhcons.c).
pub const Console = struct {
    /// Input from the run's reader thread; none means EOF.
    in: ?*consin.ConsoleInput,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    /// Puts the host terminal in or out of raw mode (Machine.Stdio.raw).
    raw: ?Raw = null,
    mutex: std.atomic.Mutex = .unlocked,
    raw_on: bool = false,
    echo_off: bool = false,
    crnl_off: bool = false,

    pub const Raw = struct {
        ctx: *anyopaque,
        set: *const fn (ctx: *anyopaque, on: bool) void,
        /// Turns the host terminal's echo on or off with its line
        /// discipline kept (`echooff` on consctl, a Linux `TCSETS`
        /// without `ECHO`); null if the host can't.
        echo: ?*const fn (ctx: *anyopaque, on: bool) void = null,
        /// Turns the host terminal's CR to NL input mapping on or off
        /// for raw mode (a Linux `TCSETS` with or without `ICRNL`), so
        /// Enter reaches the program as CR when it asks; null if the
        /// host can't.
        crnl: ?*const fn (ctx: *anyopaque, on: bool) void = null,
        /// The host terminal's size, rows then columns, for a Linux
        /// `TIOCGWINSZ`; null, or a null result, if the host can't say.
        size: ?*const fn (ctx: *anyopaque) ?[2]u16 = null,
    };

    /// Turns raw mode on or off, if it isn't already.
    pub fn setRaw(con: *Console, on: bool) void {
        while (!con.mutex.tryLock()) std.atomic.spinLoopHint();
        defer con.mutex.unlock();
        if (con.raw_on == on) return;
        con.raw_on = on;
        if (con.raw) |r| r.set(r.ctx, on);
    }

    /// Turns echo on or off, if it isn't already.
    pub fn setEcho(con: *Console, on: bool) void {
        while (!con.mutex.tryLock()) std.atomic.spinLoopHint();
        defer con.mutex.unlock();
        if (con.echo_off == !on) return;
        con.echo_off = !on;
        if (con.raw) |r| if (r.echo) |f| f(r.ctx, on);
    }

    /// Turns raw mode's CR to NL mapping on or off, if it isn't already.
    pub fn setCrnl(con: *Console, on: bool) void {
        while (!con.mutex.tryLock()) std.atomic.spinLoopHint();
        defer con.mutex.unlock();
        if (con.crnl_off == !on) return;
        con.crnl_off = !on;
        if (con.raw) |r| if (r.crnl) |f| f(r.ctx, on);
    }

    /// The host terminal's rows and columns, if it knows them.
    pub fn size(con: *Console) ?[2]u16 {
        const r = con.raw orelse return null;
        const f = r.size orelse return null;
        return f(r.ctx);
    }

    /// Back to cooked mode with echo, as at the end of a run.
    pub fn reset(con: *Console) void {
        con.setRaw(false);
        con.setEcho(true);
        con.setCrnl(true);
    }
};

/// Wakes a guest read on console `id` sleeping for input. Called from the
/// console's reader thread, which isn't a kernel process: drawterm's
/// wakeup only takes locks and signals the sleeper's thread.
pub fn wakeConsole(id: u32) void {
    c.h9_cons_wake(id);
}

const max_consoles = 64;
var consoles: [max_consoles]std.atomic.Value(?*Console) = @splat(.init(null));

/// Registers a console and returns its id for `#y<id>`.
pub fn addConsole(con: *Console) error{TooManyMachines}!u32 {
    for (&consoles, 0..) |*slot, i| {
        if (slot.cmpxchgStrong(null, con, .acq_rel, .acquire) == null) return @intCast(i);
    }
    return error.TooManyMachines;
}

pub fn removeConsole(id: u32) void {
    consoles[id].store(null, .release);
}

fn console(id: c_ulong) ?*Console {
    if (id >= max_consoles) return null;
    return consoles[id].load(.acquire);
}

// Leaves called from devhcons.c. They never raise kernel errors.

comptime {
    // devhstream.c's leaves.
    _ = @import("hstream.zig");
    if (available) {
        @export(&h9_cons_read, .{ .name = "h9_cons_read" });
        @export(&h9_cons_ready, .{ .name = "h9_cons_ready" });
        @export(&h9_cons_write, .{ .name = "h9_cons_write" });
        @export(&h9_cons_raw, .{ .name = "h9_cons_raw" });
        @export(&h9_cons_echo, .{ .name = "h9_cons_echo" });
        @export(&h9_cons_poll, .{ .name = "h9_cons_poll" });
        @export(&h9_policy_active, .{ .name = "h9_policy_active" });
        @export(&h9_policy_check, .{ .name = "h9_policy_check" });
        @export(&h9_net_check, .{ .name = "h9_net_check" });
        @export(&h9_net_lookup, .{ .name = "h9_net_lookup" });
        @export(&h9_net_resolved, .{ .name = "h9_net_resolved" });
        @export(&h9_overlay_pool, .{ .name = "h9_overlay_pool" });
        @export(&h9_overlay_alloc, .{ .name = "h9_overlay_alloc" });
        @export(&h9_overlay_free, .{ .name = "h9_overlay_free" });
        @export(&h9_overlay_changed, .{ .name = "h9_overlay_changed" });
        @export(&h9_clock_wall, .{ .name = "h9_clock_wall" });
        @export(&h9_clock_mono, .{ .name = "h9_clock_mono" });
        @export(&h9_cons_ncpu, .{ .name = "h9_cons_ncpu" });
        @export(&h9_tools_table, .{ .name = "h9_tools_table" });
    }
}

// The clock (design/0007-go-compat.md): one per host process, in
// nanoseconds. Wall time is the host's real-time clock. Monotonic time is
// the host's monotonic clock, offset so it starts at the wall time when
// the clock is first read, so its values look like wall time but never
// jump with the host's clock. devcons's ticks are the monotonic
// nanoseconds, so fasthz is 10^9.

/// Clock reads need no Io state, so any thread can make them through the
/// global single-threaded Io.
fn clockIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn clockNow(clock: std.Io.Clock) i64 {
    return @intCast(std.Io.Timestamp.now(clockIo(), clock).nanoseconds);
}

/// Wall minus monotonic time at the first read; 0 until then.
var mono_offset: web.Atomic(i64) = .init(0);
var mono_set: std.atomic.Value(bool) = .init(false);

/// Wall time in nanoseconds since the epoch.
pub fn wallNs() i64 {
    return clockNow(.real);
}

/// Monotonic time in nanoseconds, starting near the wall time.
pub fn monoNs() i64 {
    if (!mono_set.load(.acquire)) {
        const off = clockNow(.real) - clockNow(.awake);
        // The first reader to set it wins; the others use its offset.
        _ = mono_offset.cmpxchgStrong(0, off, .acq_rel, .acquire);
        mono_set.store(true, .release);
    }
    return clockNow(.awake) + mono_offset.load(.acquire);
}

fn h9_clock_wall() callconv(.c) i64 {
    return wallNs();
}

fn h9_clock_mono() callconv(.c) i64 {
    return monoNs();
}

/// The CPUs the calling thread's machine may use, for /dev/sysstat; set
/// with the plan. Kernel threads without a machine see one.
threadlocal var cons_ncpu: u32 = 1;

// On the web host, where threadlocals are plain globals, a coroutine's
// park saves and restores them (src/web/coro.c).
comptime {
    if (web.enabled) @export(&h9_web_locals, .{ .name = "h9_web_locals" });
}

fn h9_web_locals(save: c_int, slots: *[4]usize) callconv(.c) void {
    if (save != 0) {
        slots[0] = @intFromPtr(fs_plan);
        slots[1] = @intFromPtr(fs_pages);
        slots[2] = cons_ncpu;
    } else {
        fs_plan = @ptrFromInt(slots[0]);
        fs_pages = @ptrFromInt(slots[1]);
        cons_ncpu = if (slots[2] == 0) 1 else @intCast(slots[2]);
    }
}

pub fn setCpus(n: u32) void {
    cons_ncpu = @max(n, 1);
}

fn h9_cons_ncpu() callconv(.c) c_int {
    return @intCast(@min(cons_ncpu, std.math.maxInt(c_int)));
}

// h9's own guest commands (design/0032-guest-tools.md): the table build.zig
// generates from src/guest/, as constant C structs. devhtools.c reads it
// once at reset and never calls back into Zig.

/// One entry, as src/kern/devhtools.c's `Htool`.
const Htool = extern struct {
    name: [*:0]const u8,
    parent: u32,
    mode: u32,
    data: [*]const u8,
    len: u32,
};

const dmdir: u32 = 0x80000000;

const tools_table = blk: {
    const es = @import("guest_tree").entries;
    var out: [es.len]Htool = undefined;
    for (es, &out) |e, *h| h.* = .{
        .name = e.name.ptr,
        .parent = e.parent,
        .mode = if (e.dir) dmdir | 0o555 else if (e.exec) 0o555 else 0o444,
        .data = e.data.ptr,
        .len = e.data.len,
    };
    const final = out;
    break :blk final;
};

fn h9_tools_table(n: *c_int) callconv(.c) [*]const Htool {
    n.* = tools_table.len;
    return &tools_table;
}

// Leaves called from devoverlay.c. They never raise kernel errors.

fn h9_overlay_pool() callconv(.c) ?*anyopaque {
    return @ptrCast(@constCast(fs_pages));
}

const host_page = std.mem.Alignment.fromByteUnits(Pages.page_size);

/// Zeroed pages, or null when the machine's memory is used up.
fn h9_overlay_alloc(pool: ?*anyopaque, n: c_uint) callconv(.c) ?*anyopaque {
    if (pool) |p| {
        const pages: *const Pages = @ptrCast(@alignCast(p));
        return pages.alloc(pages.ctx, n);
    }
    const mem = std.heap.page_allocator.alignedAlloc(u8, host_page, n) catch return null;
    @memset(mem, 0);
    return mem.ptr;
}

fn h9_overlay_free(pool: ?*anyopaque, ptr: ?*anyopaque, n: c_uint) callconv(.c) void {
    const q: [*]u8 = @ptrCast(ptr orelse return);
    if (pool) |p| {
        const pages: *const Pages = @ptrCast(@alignCast(p));
        return pages.free(pages.ctx, q, n);
    }
    const a: [*]align(Pages.page_size) u8 = @alignCast(q);
    std.heap.page_allocator.free(a[0..n]);
}

fn h9_overlay_changed(track: ?*anyopaque, path: [*:0]const u8) callconv(.c) void {
    const tr: *const OverlayTrack = @ptrCast(@alignCast(track orelse return));
    tr.changed(tr.ctx, std.mem.span(path));
}

fn h9_policy_active() callconv(.c) c_int {
    return @intFromBool(fs_plan != null);
}

fn h9_policy_check(path: [*]const u8, len: c_long, op: c_int) callconv(.c) c_int {
    const p = fs_plan orelse return 0;
    const o = std.enums.fromInt(policy.Op, op) orelse return @intFromEnum(policy.Verdict.hidden);
    return @intFromEnum(p.check(path[0..@intCast(len)], o));
}

// devip's sandbox hooks (src/kern/netcheck.h): leaves that return a
// verdict, 0 or -1, against the calling thread's plan. Kernel threads
// without a plan aren't restricted.

fn netProto(proto: c_int) ?policy.NetProto {
    return std.enums.fromInt(policy.NetProto, proto);
}

fn netPort(port: c_int) ?u16 {
    return std.math.cast(u16, port);
}

fn h9_net_check(op: c_int, proto: c_int, addr: [*]const u8, port: c_int) callconv(.c) c_int {
    const p = fs_plan orelse return 0;
    const o = std.enums.fromInt(policy.NetOp, op) orelse return -1;
    // A port outside 0-65535 matches no pattern; without patterns only
    // the address matters.
    const pt: u16 = netPort(port) orelse blk: {
        if (p.net_allow.len > 0) return -1;
        break :blk 0;
    };
    return if (p.netCheck(o, netProto(proto), addr[0..16], pt)) 0 else -1;
}

fn h9_net_lookup(proto: c_int, name: [*:0]const u8, port: c_int) callconv(.c) c_int {
    const p = fs_plan orelse return 0;
    const pt = netPort(port) orelse return -1;
    return if (p.netLookup(netProto(proto), std.mem.span(name), pt)) 0 else -1;
}

fn h9_net_resolved(proto: c_int, name: [*:0]const u8, port: c_int, addrs: [*]const [16]u8, n: c_int) callconv(.c) void {
    const p = fs_plan orelse return;
    const pt = netPort(port) orelse return;
    p.netResolved(netProto(proto), std.mem.span(name), pt, addrs[0..@intCast(@max(n, 0))]);
}

/// Returns the bytes read, 0 at EOF, -1 on error, or -2 when the caller
/// has to sleep until `h9_cons_ready` and try again.
fn h9_cons_read(id: c_ulong, buf: [*]u8, n: c_long) callconv(.c) c_long {
    const con = console(id) orelse return -1;
    const in = con.in orelse return 0;
    return @intCast(in.read(buf[0..@intCast(n)]));
}

/// For poll: ready, or a read is asked for, whose input wakes pollers.
fn h9_cons_poll(id: c_ulong) callconv(.c) c_int {
    const con = console(id) orelse return 1;
    const in = con.in orelse return 1;
    return @intFromBool(in.request());
}

fn h9_cons_ready(id: c_ulong) callconv(.c) c_int {
    const con = console(id) orelse return 1;
    const in = con.in orelse return 1;
    return @intFromBool(in.ready());
}

/// consctl's rawon and rawoff: 9front's raw mode has no echo, since the
/// program echoes what it wants.
fn h9_cons_raw(id: c_ulong, on: c_int) callconv(.c) void {
    const con = console(id) orelse return;
    con.setEcho(on == 0);
    con.setRaw(on != 0);
}

fn h9_cons_echo(id: c_ulong, on: c_int) callconv(.c) void {
    const con = console(id) orelse return;
    con.setEcho(on != 0);
}

/// Sets console `id`'s raw mode, echo and CR to NL mapping, for a Linux
/// `TCSETS`. The mapping goes first, so raw mode starts with it.
pub fn setConsoleMode(id: u64, raw: bool, echo: bool, crnl: bool) void {
    const con = console(@intCast(id)) orelse return;
    con.setCrnl(crnl);
    con.setRaw(raw);
    con.setEcho(echo);
}

/// Console `id`'s host terminal size, rows then columns, for a Linux
/// `TIOCGWINSZ`; null if the host can't say.
pub fn consoleSize(id: u64) ?[2]u16 {
    const con = console(@intCast(id)) orelse return null;
    return con.size();
}

fn h9_cons_write(id: c_ulong, fd: c_int, buf: [*]const u8, n: c_long) callconv(.c) c_long {
    const con = console(id) orelse return -1;
    const w = if (fd == 2) con.err else con.out;
    while (!con.mutex.tryLock()) std.atomic.spinLoopHint();
    defer con.mutex.unlock();
    w.writeAll(buf[0..@intCast(n)]) catch return -1;
    w.flush() catch return -1;
    return n;
}

test "spawn a process and read a host file through kern" {
    if (!available) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "lib");
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/namespace", .data = "mount -a #s/boot /\n" });
    try tmp.dir.createDirPath(io, "dev");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);

    const T = struct {
        root: [:0]u8,
        err: ?anyerror = null,
        data: [64]u8 = undefined,
        len: usize = 0,
        sysname: [16]u8 = undefined,
        sysname_len: usize = 0,
        missing: []const u8 = "",
        missing_buf: [ERRMAX]u8 = undefined,
        done: std.atomic.Value(bool) = .init(false),

        fn run(t: *@This()) void {
            defer t.done.store(true, .release);
            t.body() catch |e| {
                t.err = e;
            };
        }
        fn body(t: *@This()) !void {
            var spec: [std.fs.max_path_bytes + 3]u8 = undefined;
            try bind(try std.fmt.bufPrintZ(&spec, "#U{s}", .{t.root}), "/", MREPL);
            try bind("#c", "/dev", MREPL);
            const fd = try open("/lib/namespace", OREAD);
            defer close(fd) catch {};
            t.len = try pread(fd, &t.data, 0);
            if (open("/lib/nonexistent", OREAD)) |_| return error.Unexpected else |_| {}
            const e = errstr();
            @memcpy(t.missing_buf[0..e.len], e);
            t.missing = t.missing_buf[0..e.len];
            const s = try open("/dev/sysname", OREAD);
            defer close(s) catch {};
            t.sysname_len = try pread(s, &t.sysname, 0);
        }
    };
    buf[n] = 0;
    var t: T = .{ .root = buf[0..n :0] };
    try spawn("test", T, T.run, &t);
    while (!t.done.load(.acquire)) std.Thread.yield() catch {};
    if (t.err) |e| return e;
    try std.testing.expectEqualStrings("mount -a #s/boot /\n", t.data[0..t.len]);
    try std.testing.expect(std.mem.indexOf(u8, t.missing, "does not exist") != null);
    try std.testing.expectEqualStrings("h9", t.sysname[0..t.sysname_len]);
}

test "fork shares or copies groups, and await returns wait records" {
    if (!available) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "lib");
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/namespace", .data = "ns\n" });
    try tmp.dir.createDirPath(io, "dev");
    try tmp.dir.createDirPath(io, "env");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    buf[n] = 0;

    const T = struct {
        root: [:0]u8,
        err: ?anyerror = null,
        where: []const u8 = "",
        done: std.atomic.Value(bool) = .init(false),
        waits: [4][64]u8 = undefined,
        wait_lens: [4]usize = @splat(0),
        no_child: [ERRMAX]u8 = undefined,
        no_child_len: usize = 0,
        child_saw: [16]u8 = undefined,
        child_saw_len: usize = 0,

        const Self = @This();
        const Child = struct {
            t: *Self,
            kind: enum { copy_env, share_env, new_ns, nowait },
            fn run(ch: *Child) void {
                ch.body() catch |e| {
                    ch.t.err = e;
                    ch.t.where = @tagName(ch.kind);
                };
            }
            fn body(ch: *Child) !void {
                switch (ch.kind) {
                    .copy_env => {
                        ch.t.child_saw_len = try readAll("/env/x", &ch.t.child_saw);
                        try writeAll("/env/x", "child");
                        if (guestPid() != 2) return error.WrongPid;
                        setExits("boom");
                    },
                    .share_env => try writeAll("/env/x", "shared"),
                    .new_ns => {
                        // The copied namespace still has the root; the new bind stays here.
                        var scratch: [16]u8 = undefined;
                        _ = try readAll("/lib/namespace", &scratch);
                        try bind("#c", "/dev", MREPL);
                        _ = try readAll("/dev/sysname", &scratch);
                    },
                    .nowait => {},
                }
            }
        };

        fn run(t: *@This()) void {
            defer t.done.store(true, .release);
            t.body() catch |e| {
                if (t.err == null) t.err = e;
                if (t.where.len == 0) t.where = "parent";
            };
        }
        fn body(t: *@This()) !void {
            var spec: [std.fs.max_path_bytes + 3]u8 = undefined;
            try bind(try std.fmt.bufPrintZ(&spec, "#U{s}", .{t.root}), "/", MREPL);
            try bind("#e", "/env", MREPL | MCREATE);
            setGuestPid(1);
            try writeAll("/env/x", "parent");
            var tmpb: [16]u8 = undefined;

            if (fork(0, 9, Child, Child.run, undefined)) |_| return error.ForkWithoutProc else |_| {}

            var c1: Child = .{ .t = t, .kind = .copy_env };
            try fork(RF.PROC | RF.FDG | RF.ENVG, 2, Child, Child.run, &c1);
            t.wait_lens[0] = try await(&t.waits[0]);
            try std.testing.expectEqualStrings("parent", tmpb[0..try readAll("/env/x", &tmpb)]);

            var c2: Child = .{ .t = t, .kind = .share_env };
            try fork(RF.PROC, 3, Child, Child.run, &c2);
            t.wait_lens[1] = try await(&t.waits[1]);
            try std.testing.expectEqualStrings("shared", tmpb[0..try readAll("/env/x", &tmpb)]);

            var c3: Child = .{ .t = t, .kind = .new_ns };
            try fork(RF.PROC | RF.NAMEG, 4, Child, Child.run, &c3);
            t.wait_lens[2] = try await(&t.waits[2]);
            if (open("/dev/sysname", OREAD)) |_| return error.ChildBindLeaked else |_| {}

            var c4: Child = .{ .t = t, .kind = .nowait };
            try fork(RF.PROC | RF.NOWAIT, 5, Child, Child.run, &c4);
            if (await(&t.waits[3])) |_| return error.AwaitedNowaitChild else |_| {}
            const e = errstr();
            @memcpy(t.no_child[0..e.len], e);
            t.no_child_len = e.len;
            // Let the RFNOWAIT child finish before c4 goes out of scope.
            try sleep(50);
        }

        fn readAll(path: [*:0]const u8, out: []u8) !usize {
            const fd = try open(path, OREAD);
            defer close(fd) catch {};
            return pread(fd, out, 0);
        }
        fn writeAll(path: [*:0]const u8, data: []const u8) !void {
            const fd = try create(path, OWRITE, 0o664);
            defer close(fd) catch {};
            _ = try pwrite(fd, data, 0);
        }
    };
    var t: T = .{ .root = buf[0..n :0] };
    try spawn("test", T, T.run, &t);
    while (!t.done.load(.acquire)) std.Thread.yield() catch {};
    if (t.err) |e| {
        std.debug.print("failed in {s}\n", .{t.where});
        return e;
    }
    try std.testing.expectEqualStrings("parent", t.child_saw[0..t.child_saw_len]);
    // "pid utime stime real 'msg'", with the message as 9front's pexit makes it.
    var f = std.mem.tokenizeScalar(u8, t.waits[0][0..t.wait_lens[0]], ' ');
    try std.testing.expectEqualStrings("2", f.next().?);
    _ = f.next();
    _ = f.next();
    _ = f.next();
    try std.testing.expectEqualStrings("'test 2: boom'", f.rest());
    try std.testing.expect(std.mem.startsWith(u8, t.waits[1][0..t.wait_lens[1]], "3 "));
    try std.testing.expect(std.mem.endsWith(u8, t.waits[1][0..t.wait_lens[1]], " ''"));
    try std.testing.expect(std.mem.startsWith(u8, t.waits[2][0..t.wait_lens[2]], "4 "));
    try std.testing.expectEqualStrings("no living children", t.no_child[0..t.no_child_len]);
}

test "notes queue per process, reach note groups and stay in their machine" {
    if (!available) return error.SkipZigTest;

    const T = struct {
        err: ?anyerror = null,
        where: []const u8 = "",
        done: std.atomic.Value(bool) = .init(false),
        /// Set by the first machine once its children are waiting; the
        /// second machine posts then, and sets `other_done`.
        ready: std.atomic.Value(bool) = .init(false),
        other_done: std.atomic.Value(bool) = .init(false),
        other_err: ?anyerror = null,
        other_noteid: u32 = 0,
        ids: [2]u32 = @splat(0),
        got: [2][ERRMAX]u8 = undefined,
        acts: [2]NoteAction = @splat(.none),

        const Self = @This();
        const Child = struct {
            t: *Self,
            i: usize,
            fn run(ch: *Child) void {
                ch.t.ids[ch.i] = noteId();
                // A note interrupts the sleep.
                while (!notePending()) sleep(5000) catch {};
                ch.t.acts[ch.i] = popNote(&ch.t.got[ch.i], 0);
            }
        };

        fn run(t: *Self) void {
            defer t.done.store(true, .release);
            t.body() catch |e| {
                if (t.err == null) t.err = e;
            };
        }
        fn body(t: *Self) !void {
            setGuestPid(1);
            var msg: [ERRMAX]u8 = undefined;

            // With a handler: user notes wait while in it, sys: notes get a pc.
            t.where = "handler";
            setNotify(true);
            if (!try postNote(1, "one", .user)) return error.NotQueued;
            _ = try postNote(1, "two", .user);
            if (popNote(&msg, 0) != .handle) return error.NotHandled;
            try std.testing.expectEqualStrings("one", std.mem.sliceTo(&msg, 0));
            if (popNote(&msg, 0) != .none) return error.NestedUserNote;
            if (try noted(.cont, &msg) != .none) return error.NotedKilled;
            if (popNote(&msg, 0) != .handle) return error.NotHandled;
            try std.testing.expectEqualStrings("two", std.mem.sliceTo(&msg, 0));
            _ = try noted(.cont, &msg);
            if (noted(.cont, &msg)) |_| return error.NotedOutsideHandler else |_| {}
            _ = try postNote(1, "sys: trap", .user);
            _ = popNote(&msg, 0x1234);
            try std.testing.expectEqualStrings("sys: trap pc=0x1234", std.mem.sliceTo(&msg, 0));
            if (try noted(.dflt, &msg) != .kill) return error.NotedDfltLived;
            try std.testing.expectEqualStrings("sys: trap pc=0x1234", std.mem.sliceTo(&msg, 0));
            execNotes();
            if (postNote(99, "x", .user)) |_| return error.NoSuchProcess else |_| {}

            // Children: 2 shares the note group, 3 has its own.
            t.where = "groups";
            var c0: Child = .{ .t = t, .i = 0 };
            var c1: Child = .{ .t = t, .i = 1 };
            try fork(RF.PROC, 2, Child, Child.run, &c0);
            try fork(RF.PROC | RF.NOTEG, 3, Child, Child.run, &c1);
            while (t.ids[0] == 0 or t.ids[1] == 0) std.Thread.yield() catch {};
            try std.testing.expectEqual(noteId(), t.ids[0]);
            if (t.ids[1] == t.ids[0]) return error.SameNoteGroup;

            // Another machine's group and pids don't reach these.
            t.ready.store(true, .release);
            while (!t.other_done.load(.acquire)) std.Thread.yield() catch {};
            if (t.other_err) |e| return e;
            try std.testing.expectEqual(noteId(), t.other_noteid);
            if (notePending()) return error.NoteToPoster;

            postNoteGroup(noteId(), "hangup", .user);
            var buf: [64]u8 = undefined;
            _ = try await(&buf);
            _ = try postNote(3, "die", .user);
            _ = try await(&buf);
            if (notePending()) return error.NoteToPoster;
        }

        fn other(t: *Self) void {
            defer t.other_done.store(true, .release);
            setGuestPid(1);
            while (!t.ready.load(.acquire)) std.Thread.yield() catch {};
            t.other_noteid = noteId();
            postNoteGroup(noteId(), "wrong machine", .user);
            if (postNote(2, "wrong machine", .user)) |_| {
                t.other_err = error.ReachedOtherMachine;
            } else |_| {}
        }
    };
    var t: T = .{};
    try spawn("test", T, T.run, &t);
    try spawn("other", T, T.other, &t);
    while (!t.done.load(.acquire)) std.Thread.yield() catch {};
    while (!t.other_done.load(.acquire)) std.Thread.yield() catch {};
    if (t.err) |e| {
        std.debug.print("failed in {s}\n", .{t.where});
        return e;
    }
    try std.testing.expectEqualStrings("hangup", std.mem.sliceTo(&t.got[0], 0));
    try std.testing.expectEqual(NoteAction.kill, t.acts[0]);
    try std.testing.expectEqualStrings("die", std.mem.sliceTo(&t.got[1], 0));
    try std.testing.expectEqual(NoteAction.kill, t.acts[1]);
}

test "#p lists and serves only the caller's machine, by machine-local pid" {
    if (!available) return error.SkipZigTest;
    const T = struct {
        const Self = @This();
        err: ?anyerror = null,
        where: []const u8 = "",
        ready: std.atomic.Value(u32) = .init(0),
        go: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(u32) = .init(0),
        lists: [2][64]u8 = undefined,
        list_lens: [2]usize = .{ 0, 0 },
        args: [64]u8 = undefined,
        args_len: usize = 0,
        killed: [64]u8 = undefined,
        killed_len: usize = 0,

        const Child = struct {
            fn run(t: *Self) void {
                // Waits to be killed through ctl.
                while (true) {
                    var msg: [ERRMAX]u8 = undefined;
                    if (popNote(&msg, 0) == .kill) {
                        const s = std.mem.sliceTo(&msg, 0);
                        @memcpy(t.killed[0..s.len], s);
                        t.killed_len = s.len;
                        setExits("killed");
                        return;
                    }
                    sleep(5) catch {};
                }
            }
        };

        fn machine(t: *Self, i: usize) void {
            defer _ = t.done.fetchAdd(1, .release);
            t.body(i) catch |e| {
                t.err = e;
            };
        }

        fn readAll(path: [*:0]const u8, buf: []u8) !usize {
            const fd = try open(path, OREAD);
            defer close(fd) catch {};
            var n: usize = 0;
            while (n < buf.len) {
                const k = try pread(fd, buf[n..], @intCast(n));
                if (k == 0) break;
                n += k;
            }
            return n;
        }

        fn body(t: *Self, i: usize) !void {
            setGuestPid(1);
            try bind("#p", "/", MREPL);
            setArgs(&.{ "prog", "a b", "c" });
            if (i == 0) {
                t.where = "fork";
                try fork(RF.PROC, 2, Self, Child.run, t);
            }
            _ = t.ready.fetchAdd(1, .release);
            while (!t.go.load(.acquire)) std.Thread.yield() catch {};

            // The directory: machine 0 has 1 and 2, machine 1 only 1.
            t.where = "list";
            const d = try open("/", OREAD);
            defer close(d) catch {};
            var buf: [4096]u8 = undefined;
            var off: usize = 0;
            while (true) {
                const n = try pread(d, &buf, 0);
                if (n == 0) break;
                var j: usize = 0;
                while (j + 2 <= n) {
                    const sz = std.mem.readInt(u16, buf[j..][0..2], .little) + 2;
                    // The name: after size[2] type[2] dev[4] qid[13] mode[4] atime[4] mtime[4] length[8].
                    const nl = std.mem.readInt(u16, buf[j + 41 ..][0..2], .little);
                    const name = buf[j + 43 ..][0..nl];
                    @memcpy(t.lists[i][off..][0..name.len], name);
                    off += name.len;
                    t.lists[i][off] = ' ';
                    off += 1;
                    j += sz;
                }
            }
            t.list_lens[i] = off;

            if (i == 1) {
                // Machine 0's pid 2 isn't visible here.
                t.where = "other machine";
                if (open("/2/status", OREAD)) |_| return error.SawOtherMachine else |_| {}
                return;
            }
            t.where = "args";
            t.args_len = try readAll("/1/args", &t.args);
            t.where = "kill";
            const ctl = try open("/2/ctl", OWRITE);
            defer close(ctl) catch {};
            _ = try pwrite(ctl, "kill", 0);
            var w: [128]u8 = undefined;
            _ = try await(&w);
        }
    };
    var t: T = .{};
    var m0: struct { t: *T } = .{ .t = &t };
    var m1: struct { t: *T } = .{ .t = &t };
    const M0 = struct {
        fn run(a: *@TypeOf(m0)) void {
            a.t.machine(0);
        }
    };
    const M1 = struct {
        fn run(a: *@TypeOf(m1)) void {
            a.t.machine(1);
        }
    };
    try spawn("m0", @TypeOf(m0), M0.run, &m0);
    try spawn("m1", @TypeOf(m1), M1.run, &m1);
    while (t.ready.load(.acquire) < 2) std.Thread.yield() catch {};
    t.go.store(true, .release);
    while (t.done.load(.acquire) < 2) std.Thread.yield() catch {};
    if (t.err) |e| {
        std.debug.print("failed in {s}\n", .{t.where});
        return e;
    }
    try std.testing.expectEqualStrings("1 2 ", t.lists[0][0..t.list_lens[0]]);
    try std.testing.expectEqualStrings("1 ", t.lists[1][0..t.list_lens[1]]);
    try std.testing.expectEqualStrings("prog 'a b' c", t.args[0..t.args_len]);
    try std.testing.expectEqualStrings("Killed", t.killed[0..t.killed_len]);
}

test "tsleep returns at its deadline, returns early on wakeup, and fails with interrupted on a note, leaving no timer behind" {
    if (!available) return error.SkipZigTest;
    const T = struct {
        const Self = @This();
        err: ?anyerror = null,
        where: []const u8 = "",
        done: std.atomic.Value(bool) = .init(false),
        proc: std.atomic.Value(?*Proc) = .init(null),
        flag: ?*anyopaque = null,
        rs: [3]c_int = @splat(9),
        ms: [3]u64 = @splat(0),
        timers: [3]c_int = @splat(9),
        intr: [ERRMAX]u8 = undefined,
        intr_len: usize = 0,

        fn run(t: *Self) void {
            defer t.done.store(true, .release);
            t.body() catch |e| {
                t.err = e;
            };
        }

        /// tsleep on the flag for `ms`, after `then` (if any) runs on
        /// another thread 50 ms in.
        fn step(t: *Self, i: usize, ms: c_uint, then: ?*const fn (*Self) void) !void {
            var th: ?std.Thread = null;
            if (then) |f| th = try std.Thread.spawn(.{}, struct {
                fn later(tt: *Self, g: *const fn (*Self) void) void {
                    std.Io.sleep(std.testing.io, .fromMilliseconds(50), .awake) catch {};
                    g(tt);
                }
            }.later, .{ t, f });
            const t0 = c.h9_kern_nanomono();
            t.rs[i] = c.h9_tflag_sleep(t.flag, ms);
            t.ms[i] = (c.h9_kern_nanomono() - t0) / std.time.ns_per_ms;
            if (th) |h| h.join();
            t.timers[i] = c.h9_ntimers();
        }

        fn body(t: *Self) !void {
            t.proc.store(self(), .release);
            t.flag = c.h9_tflag_new() orelse return error.OutOfMemory;
            defer c.h9_tflag_free(t.flag);
            try t.step(0, 100, null);
            try t.step(1, 5000, struct {
                fn f(tt: *Self) void {
                    c.h9_tflag_set(tt.flag);
                }
            }.f);
            c.h9_tflag_free(t.flag);
            t.flag = c.h9_tflag_new() orelse return error.OutOfMemory;
            try t.step(2, 5000, struct {
                fn f(tt: *Self) void {
                    interrupt(tt.proc.load(.acquire).?);
                }
            }.f);
            const e = errstr();
            @memcpy(t.intr[0..e.len], e);
            t.intr_len = e.len;
        }
    };
    var t: T = .{};
    try spawn("tsleep", T, T.run, &t);
    while (!t.done.load(.acquire)) std.Thread.yield() catch {};
    if (t.err) |e| return e;
    errdefer std.debug.print("results {any}, ms {any}, timers {any}\n", .{ t.rs, t.ms, t.timers });
    // The deadline: not set, and not early.
    try std.testing.expectEqual(0, t.rs[0]);
    try std.testing.expect(t.ms[0] >= 100 and t.ms[0] < 1000);
    // Set 50 ms in, well before the deadline.
    try std.testing.expectEqual(1, t.rs[1]);
    try std.testing.expect(t.ms[1] < 2500);
    // Interrupted 50 ms in.
    try std.testing.expectEqual(-1, t.rs[2]);
    try std.testing.expect(t.ms[2] < 2500);
    try std.testing.expectEqualStrings("interrupted", t.intr[0..t.intr_len]);
    try std.testing.expectEqual([3]c_int{ 0, 0, 0 }, t.timers);
}

/// A stat buffer that changes only the name (9P's "don't touch" values
/// elsewhere), for renames through wstat.
fn renameStat(buf: []u8, name: []const u8) []u8 {
    const n = 2 + 2 + 4 + 13 + 4 + 4 + 4 + 8 + (2 + name.len) + 3 * 2;
    @memset(buf[0..n], 0xff);
    std.mem.writeInt(u16, buf[0..2], @intCast(n - 2), .little);
    var o: usize = 2 + 2 + 4 + 13 + 4 + 4 + 4 + 8;
    std.mem.writeInt(u16, buf[o..][0..2], @intCast(name.len), .little);
    @memcpy(buf[o + 2 ..][0..name.len], name);
    o += 2 + name.len;
    for (0..3) |_| {
        std.mem.writeInt(u16, buf[o..][0..2], 0, .little);
        o += 2;
    }
    return buf[0..n];
}

test "#O overlays a host tree in memory and never writes it" {
    if (!available) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "lower/sub");
    try tmp.dir.createDirPath(io, "lower/d");
    try tmp.dir.createDirPath(io, "mnt");
    try tmp.dir.createDirPath(io, "mem");
    try tmp.dir.writeFile(io, .{ .sub_path = "lower/a.txt", .data = "host a\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "lower/sub/b.txt", .data = "host b\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "lower/sub/c.txt", .data = "host c\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "lower/d/x", .data = "x\n" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    buf[n] = 0;

    const T = struct {
        root: [:0]u8,
        err: ?anyerror = null,
        where: []const u8 = "",
        done: std.atomic.Value(bool) = .init(false),
        names: [256]u8 = undefined,
        names_len: usize = 0,

        fn run(t: *@This()) void {
            defer t.done.store(true, .release);
            t.body() catch |e| {
                t.err = e;
            };
        }
        fn readAll(path: [*:0]const u8, out: []u8) ![]u8 {
            const fd = try open(path, OREAD);
            defer close(fd) catch {};
            return out[0..try pread(fd, out, 0)];
        }
        fn writeNew(path: [*:0]const u8, data: []const u8) !void {
            const fd = try create(path, OWRITE, 0o664);
            defer close(fd) catch {};
            _ = try pwrite(fd, data, 0);
        }
        fn expectRead(path: [*:0]const u8, want: []const u8) !void {
            var b: [64]u8 = undefined;
            try std.testing.expectEqualStrings(want, try readAll(path, &b));
        }
        fn missing(path: [*:0]const u8) !void {
            if (open(path, OREAD)) |fd| {
                close(fd) catch {};
                return error.StillThere;
            } else |_| {}
        }
        fn body(t: *@This()) !void {
            var spec: [std.fs.max_path_bytes + 16]u8 = undefined;
            try bind(try std.fmt.bufPrintZ(&spec, "#U{s}", .{t.root}), "/", MREPL);
            const id = try overlayNew("/lower");
            try bind(try std.fmt.bufPrintZ(&spec, "#O{d}", .{id}), "/mnt", MREPL | MCREATE);

            t.where = "read through";
            try expectRead("/mnt/a.txt", "host a\n");
            try expectRead("/mnt/sub/b.txt", "host b\n");

            t.where = "a reader keeps the lower file across a copy-up";
            const r = try open("/mnt/sub/c.txt", OREAD);
            defer close(r) catch {};
            {
                const w = try open("/mnt/sub/c.txt", ORDWR);
                defer close(w) catch {};
                _ = try pwrite(w, "HOST", 0);
            }
            var b: [64]u8 = undefined;
            try std.testing.expectEqualStrings("host c\n", b[0..try pread(r, &b, 0)]);
            try expectRead("/mnt/sub/c.txt", "HOST c\n");

            t.where = "create";
            try writeNew("/mnt/new", "new\n");
            try expectRead("/mnt/new", "new\n");

            t.where = "truncate an existing file";
            try writeNew("/mnt/a.txt", "changed\n");
            try expectRead("/mnt/a.txt", "changed\n");

            t.where = "remove";
            try remove("/mnt/sub/b.txt");
            try missing("/mnt/sub/b.txt");

            t.where = "rm then recreate";
            try remove("/mnt/a.txt");
            try missing("/mnt/a.txt");
            try writeNew("/mnt/a.txt", "again\n");
            try expectRead("/mnt/a.txt", "again\n");

            t.where = "rename a file";
            var st: [128]u8 = undefined;
            _ = try wstat("/mnt/new", renameStat(&st, "newer"));
            try missing("/mnt/new");
            try expectRead("/mnt/newer", "new\n");
            _ = try wstat("/mnt/sub/c.txt", renameStat(&st, "c2.txt"));
            try missing("/mnt/sub/c.txt");
            try expectRead("/mnt/sub/c2.txt", "HOST c\n");

            t.where = "renaming a lower directory or a marker is refused";
            if (wstat("/mnt/d", renameStat(&st, "e"))) |_| return error.RenamedLowerDir else |_| {}
            if (wstat("/mnt/sub", renameStat(&st, "sub2"))) |_| return error.RenamedMarker else |_| {}

            t.where = "a directory in memory can be renamed, and removed once empty";
            _ = try create("/mnt/mdir", OREAD, 0x80000000 | 0o775);
            try writeNew("/mnt/mdir/f", "f\n");
            _ = try wstat("/mnt/mdir", renameStat(&st, "mdir2"));
            try expectRead("/mnt/mdir2/f", "f\n");
            if (remove("/mnt/mdir2")) |_| return error.RemovedNonEmpty else |_| {}
            try remove("/mnt/mdir2/f");
            try remove("/mnt/mdir2");
            if (remove("/mnt/d")) |_| return error.RemovedNonEmptyLower else |_| {}

            t.where = "list";
            const d = try open("/mnt", OREAD);
            defer close(d) catch {};
            var dbuf: [4096]u8 = undefined;
            var off: i64 = 0;
            while (true) {
                const k = try pread(d, &dbuf, off);
                if (k == 0) break;
                off += @intCast(k);
                var j: usize = 0;
                while (j + 2 <= k) {
                    const sz = std.mem.readInt(u16, dbuf[j..][0..2], .little) + 2;
                    const nl = std.mem.readInt(u16, dbuf[j + 41 ..][0..2], .little);
                    const name = dbuf[j + 43 ..][0..nl];
                    @memcpy(t.names[t.names_len..][0..name.len], name);
                    t.names_len += name.len;
                    t.names[t.names_len] = ' ';
                    t.names_len += 1;
                    j += sz;
                }
            }

            t.where = "a tree in memory only";
            const mid = try overlayNew(null);
            try bind(try std.fmt.bufPrintZ(&spec, "#O{d}", .{mid}), "/mem", MREPL | MCREATE);
            try writeNew("/mem/scratch", "scratch\n");
            try expectRead("/mem/scratch", "scratch\n");

            t.where = "another machine's instance can't be attached";
            const other: Pages = .{ .ctx = undefined, .alloc = undefined, .free = undefined };
            setPages(&other);
            defer setPages(null);
            if (bind(try std.fmt.bufPrintZ(&spec, "#O{d}", .{id}), "/mem", MREPL)) |_| return error.AttachedOtherMachine else |_| {}
        }
    };
    var t: T = .{ .root = buf[0..n :0] };
    try spawn("test", T, T.run, &t);
    while (!t.done.load(.acquire)) std.Thread.yield() catch {};
    if (t.err) |e| {
        std.debug.print("failed in {s}\n", .{t.where});
        return e;
    }
    // Each name once, in no particular order.
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(std.testing.allocator);
    var it = std.mem.tokenizeScalar(u8, t.names[0..t.names_len], ' ');
    while (it.next()) |name| {
        if (seen.contains(name)) return error.ListedTwice;
        try seen.put(std.testing.allocator, name, {});
    }
    for ([_][]const u8{ "a.txt", "sub", "d", "newer" }) |want| try std.testing.expect(seen.contains(want));
    try std.testing.expectEqual(@as(u32, 4), seen.count());

    // The host tree is unchanged.
    var hb: [64]u8 = undefined;
    try std.testing.expectEqualStrings("host a\n", try tmp.dir.readFile(io, "lower/a.txt", &hb));
    try std.testing.expectEqualStrings("host b\n", try tmp.dir.readFile(io, "lower/sub/b.txt", &hb));
    try std.testing.expectEqualStrings("host c\n", try tmp.dir.readFile(io, "lower/sub/c.txt", &hb));
    for ([_][]const u8{ "lower/new", "lower/newer", "lower/sub/c2.txt", "lower/mdir", "mnt/new" }) |p| {
        if (tmp.dir.access(io, p, .{})) |_| return error.HostWritten else |_| {}
    }
}

test "#O finds, removes and lists the children of a large directory" {
    if (!available) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "mem");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    buf[n] = 0;
    const count = 20000;
    const T = struct {
        root: [:0]u8,
        err: ?anyerror = null,
        done: std.atomic.Value(bool) = .init(false),
        listed: usize = 0,

        fn run(t: *@This()) void {
            defer t.done.store(true, .release);
            t.body() catch |e| {
                t.err = e;
            };
        }
        fn body(t: *@This()) !void {
            var spec: [std.fs.max_path_bytes + 16]u8 = undefined;
            try bind(try std.fmt.bufPrintZ(&spec, "#U{s}", .{t.root}), "/", MREPL);
            const id = try overlayNew(null);
            try bind(try std.fmt.bufPrintZ(&spec, "#O{d}", .{id}), "/mem", MREPL | MCREATE);
            var p: [32]u8 = undefined;
            for (0..count) |i| close(try create(try std.fmt.bufPrintZ(&p, "/mem/f{d}", .{i}), OWRITE, 0o664)) catch {};
            // Every other one goes, from the middle of the list and its ends.
            var i: usize = 0;
            while (i < count) : (i += 2) try remove(try std.fmt.bufPrintZ(&p, "/mem/f{d}", .{i}));
            for (0..count) |j| {
                const name = try std.fmt.bufPrintZ(&p, "/mem/f{d}", .{j});
                if (open(name, OREAD)) |fd| {
                    close(fd) catch {};
                    if (j % 2 == 0) return error.StillThere;
                } else |e| if (j % 2 == 1) return e;
            }
            const d = try open("/mem", OREAD);
            defer close(d) catch {};
            var dbuf: [8192]u8 = undefined;
            var off: i64 = 0;
            while (true) {
                const k = try pread(d, &dbuf, off);
                if (k == 0) break;
                off += @intCast(k);
                var j: usize = 0;
                while (j + 2 <= k) : (t.listed += 1) j += std.mem.readInt(u16, dbuf[j..][0..2], .little) + 2;
            }
        }
    };
    var t: T = .{ .root = buf[0..n :0] };
    try spawn("test", T, T.run, &t);
    while (!t.done.load(.acquire)) std.Thread.yield() catch {};
    if (t.err) |e| return e;
    try std.testing.expectEqual(@as(usize, count / 2), t.listed);
}

test "#U!c resolves symlinks inside the tree it's bound from [34]" {
    if (!available or @import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    // top is the tree; outside is a sibling an uncontained link reaches.
    try tmp.dir.createDirPath(io, "top/bin");
    try tmp.dir.createDirPath(io, "top/etc");
    try tmp.dir.createDirPath(io, "mnt");
    try tmp.dir.writeFile(io, .{ .sub_path = "top/bin/busybox", .data = "tree busybox\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "top/outside", .data = "inside\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "outside", .data = "host\n" });
    try tmp.dir.symLink(io, "/bin/busybox", "top/bin/ls", .{});
    try tmp.dir.symLink(io, "../../../../../outside", "top/etc/up", .{});
    try tmp.dir.symLink(io, "../outside", "top/rel", .{});
    try tmp.dir.symLink(io, "/bin", "top/bindir", .{});
    try tmp.dir.symLink(io, "loop2", "top/loop", .{});
    try tmp.dir.symLink(io, "loop", "top/loop2", .{});
    try tmp.dir.symLink(io, "/nonexistent", "top/dangling", .{});
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    buf[n] = 0;

    const T = struct {
        root: [:0]u8,
        err: ?anyerror = null,
        where: []const u8 = "",
        done: std.atomic.Value(bool) = .init(false),
        names: [256]u8 = undefined,
        names_len: usize = 0,
        loop_err: [ERRMAX]u8 = undefined,
        loop_err_len: usize = 0,

        fn run(t: *@This()) void {
            defer t.done.store(true, .release);
            t.body() catch |e| {
                t.err = e;
            };
        }
        fn expectRead(path: [*:0]const u8, want: []const u8) !void {
            const fd = try open(path, OREAD);
            defer close(fd) catch {};
            var b: [64]u8 = undefined;
            try std.testing.expectEqualStrings(want, b[0..try pread(fd, &b, 0)]);
        }
        fn body(t: *@This()) !void {
            var spec: [std.fs.max_path_bytes + 16]u8 = undefined;
            try bind(try std.fmt.bufPrintZ(&spec, "#U{s}", .{t.root}), "/", MREPL);
            try bind(try std.fmt.bufPrintZ(&spec, "#U!c{s}/top", .{t.root}), "/mnt", MREPL);

            t.where = "absolute link";
            try expectRead("/mnt/bin/ls", "tree busybox\n");
            t.where = ".. stops at the top";
            try expectRead("/mnt/etc/up", "inside\n");
            try expectRead("/mnt/rel", "inside\n");
            t.where = "uncontained bind follows the host";
            try expectRead("/top/rel", "host\n");
            t.where = "link to a directory";
            try expectRead("/mnt/bindir/busybox", "tree busybox\n");

            t.where = "stat shows the link's own name";
            var st: [256]u8 = undefined;
            const sn = try stat("/mnt/bin/ls", &st);
            const nl = std.mem.readInt(u16, st[41..][0..2], .little);
            try std.testing.expect(sn >= 43 + nl);
            try std.testing.expectEqualStrings("ls", st[43..][0..nl]);

            t.where = "readlink";
            var lb: [64]u8 = undefined;
            try std.testing.expectEqualStrings("/bin/busybox", try readlink("/mnt/bin/ls", &lb));
            if (readlink("/mnt/bin/busybox", &lb)) |_| return error.NotALink else |_| {}

            t.where = "dangling";
            if (open("/mnt/dangling", OREAD)) |fd| {
                close(fd) catch {};
                return error.DanglingOpened;
            } else |_| {}
            try std.testing.expect(std.mem.indexOf(u8, errstr(), "does not exist") != null);

            t.where = "loop";
            if (open("/mnt/loop", OREAD)) |fd| {
                close(fd) catch {};
                return error.LoopOpened;
            } else |_| {}
            const e = errstr();
            @memcpy(t.loop_err[0..e.len], e);
            t.loop_err_len = e.len;

            t.where = "list";
            const d = try open("/mnt", OREAD);
            defer close(d) catch {};
            var dbuf: [4096]u8 = undefined;
            var off: i64 = 0;
            while (true) {
                const k = try pread(d, &dbuf, off);
                if (k == 0) break;
                off += @intCast(k);
                var j: usize = 0;
                while (j + 2 <= k) {
                    const sz = std.mem.readInt(u16, dbuf[j..][0..2], .little) + 2;
                    const l = std.mem.readInt(u16, dbuf[j + 41 ..][0..2], .little);
                    const name = dbuf[j + 43 ..][0..l];
                    @memcpy(t.names[t.names_len..][0..name.len], name);
                    t.names_len += name.len;
                    t.names[t.names_len] = ' ';
                    t.names_len += 1;
                    j += sz;
                }
            }

            t.where = "remove a link, not its target";
            try remove("/mnt/bin/ls");
            try expectRead("/mnt/bin/busybox", "tree busybox\n");
        }
    };
    var t: T = .{ .root = buf[0..n :0] };
    try spawn("test", T, T.run, &t);
    while (!t.done.load(.acquire)) std.Thread.yield() catch {};
    if (t.err) |e| {
        std.debug.print("failed in {s}\n", .{t.where});
        return e;
    }
    try std.testing.expect(std.mem.indexOf(u8, t.loop_err[0..t.loop_err_len], "too many symbolic links") != null);
    // Links listed as their targets; the dangling one and the loop aren't.
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(std.testing.allocator);
    var it = std.mem.tokenizeScalar(u8, t.names[0..t.names_len], ' ');
    while (it.next()) |name| try seen.put(std.testing.allocator, name, {});
    for ([_][]const u8{ "bin", "etc", "outside", "rel", "bindir" }) |want| try std.testing.expect(seen.contains(want));
    for ([_][]const u8{ "dangling", "loop", "loop2" }) |gone| try std.testing.expect(!seen.contains(gone));
    // The link went; its target stayed.
    var hb: [64]u8 = undefined;
    try std.testing.expectEqualStrings("tree busybox\n", try tmp.dir.readFile(io, "top/bin/busybox", &hb));
    if (tmp.dir.readLink(io, "top/bin/ls", &hb)) |_| return error.LinkStillThere else |_| {}
}
