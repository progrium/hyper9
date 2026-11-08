//! The native backend's stub (design/native-backend.md): a tiny static
//! x86_64 Linux program, linked at `abi.stub_base`, that hosts one guest
//! address space. h9 starts one per address space, with the guest's RAM
//! file and its control page as file descriptors 3 and 4.
//!
//! At startup the stub unmaps everything outside its own range (the
//! kernel's stack, vDSO and vvar), so the whole of 9front's amd64 layout
//! is free; installs one signal handler, on an alternate stack, for the
//! signals guest code raises; turns on Syscall User Dispatch, so every
//! syscall made outside its own range raises SIGSYS; and installs a
//! seccomp filter that lets through only the few calls the stub itself
//! makes, from its own range. Then it traps once (UD2) to enter the
//! handler, which is the only way in or out of guest code.
//!
//! The handler writes the guest's registers and why it stopped to the
//! control page, tells h9, and waits. When h9 resumes it, it carries out
//! the map and unmap requests h9 queued, loads the registers back into
//! the signal frame, and returns into the guest through rt_sigreturn.
//!
//! The stub has no libc and no thread-local storage, so FS belongs to the
//! guest.

const std = @import("std");
const linux = std.os.linux;
const abi = @import("native_abi.zig");

const ctl: *volatile abi.Ctl = @ptrFromInt(abi.ctl_addr);

export var stub_stack: [16 * 1024]u8 align(16) = undefined;
var alt_stack: [64 * 1024]u8 align(16) = undefined;
/// Syscall User Dispatch's selector, read-only so the guest can't flip it
/// (SYSCALL_DISPATCH_FILTER_BLOCK).
const selector: u8 = 1;
var starting: bool = true;
/// The FS base as last set or read.
var fs_base: u64 = 0;
var parent: usize = 0;

pub export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ leaq stub_stack+16384(%%rip), %%rsp
        \\ xorl %%ebp, %%ebp
        \\ call stubMain
        \\ ud2
    );
}

fn sys(n: linux.SYS, a: usize, b: usize, c: usize, d: usize, e: usize, f: usize) usize {
    return linux.syscall6(n, a, b, c, d, e, f);
}

fn die(code: usize) noreturn {
    _ = sys(.exit_group, code, 0, 0, 0, 0, 0);
    unreachable;
}

fn check(rc: usize, code: usize) void {
    if (rc > std.math.maxInt(usize) - 4095) die(code);
}

const PR_SET_NO_NEW_PRIVS = 38;
const PR_SET_SYSCALL_USER_DISPATCH = 59;
const PR_SYS_DISPATCH_ON = 1;
const ARCH_SET_FS = 0x1002;
const ARCH_GET_FS = 0x1003;

const SA_SIGINFO = 4;
const SA_ONSTACK = 0x0800_0000;
const SA_RESTORER = 0x0400_0000;

const KSigaction = extern struct {
    handler: usize,
    flags: u64,
    restorer: usize,
    mask: u64,
};

export fn stubRestore() callconv(.naked) noreturn {
    asm volatile (
        \\ movl $15, %%eax
        \\ syscall
    );
}

export fn stubMain() callconv(.c) noreturn {
    parent = sys(.getppid, 0, 0, 0, 0, 0, 0);
    // Everything but the stub's own range: the kernel's stack, vDSO and
    // vvar, wherever ASLR put them.
    check(sys(.munmap, 0, abi.stub_base, 0, 0, 0, 0), 10);
    check(sys(.munmap, abi.stub_end, abi.user_top - abi.stub_end, 0, 0, 0, 0), 11);
    const PROT_RW = 3; // PROT_READ | PROT_WRITE
    const MAP_SHARED_FIXED = 0x01 | 0x10;
    check(sys(.mmap, abi.ctl_addr, abi.ctl_size, PROT_RW, MAP_SHARED_FIXED, abi.ctl_fd, 0), 12);
    _ = sys(.close, abi.ctl_fd, 0, 0, 0, 0, 0);

    const ss: linux.stack_t = .{ .sp = &alt_stack, .flags = 0, .size = alt_stack.len };
    check(sys(.sigaltstack, @intFromPtr(&ss), 0, 0, 0, 0, 0), 13);
    const act: KSigaction = .{
        .handler = @intFromPtr(&handler),
        .flags = SA_SIGINFO | SA_ONSTACK | SA_RESTORER,
        .restorer = @intFromPtr(&stubRestore),
        .mask = ~@as(u64, 0),
    };
    for ([_]u32{ 4, 5, 7, 8, 11, 23, 31 }) |sig| { // ILL TRAP BUS FPE SEGV URG SYS
        check(sys(.rt_sigaction, sig, @intFromPtr(&act), 0, 8, 0, 0), 14);
    }
    // h9's threads may block signals; the guest runs with none blocked.
    const none: u64 = 0;
    check(sys(.rt_sigprocmask, linux.SIG.SETMASK, @intFromPtr(&none), 0, 8, 0, 0), 15);

    check(sys(.prctl, PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0, 0), 16);
    check(sys(.prctl, PR_SET_SYSCALL_USER_DISPATCH, PR_SYS_DISPATCH_ON, abi.stub_base, abi.stub_end - abi.stub_base, @intFromPtr(&selector), 0), 17);
    installFilter();

    // Into the handler, which reports `ready` and enters the guest.
    asm volatile ("ud2");
    unreachable;
}

// ---- seccomp ----

const SockFilter = extern struct { code: u16, jt: u8, jf: u8, k: u32 };
const SockFprog = extern struct { len: u16, filter: [*]const SockFilter };

fn stmt(code: u16, k: u32) SockFilter {
    return .{ .code = code, .jt = 0, .jf = 0, .k = k };
}
fn jump(code: u16, k: u32, jt: u8, jf: u8) SockFilter {
    return .{ .code = code, .jt = jt, .jf = jf, .k = k };
}

const BPF_LD_W_ABS = 0x20;
const BPF_JEQ_K = 0x15;
const BPF_JGE_K = 0x35;
const BPF_RET_K = 0x06;
const RET_ALLOW = 0x7fff_0000;
const RET_KILL_PROCESS = 0x8000_0000;
const AUDIT_ARCH_X86_64 = 0xc000_003e;

/// The calls the stub makes after this point.
const allowed = [_]linux.SYS{ .futex, .rt_sigreturn, .munmap, .exit_group, .getppid, .arch_prctl };

/// Allows `allowed`, and `mmap` of the RAM file, from the stub's range
/// only; kills the stub on anything else. Syscall User Dispatch already
/// turns every syscall from outside the range into SIGSYS, so this is
/// the backstop: it holds if the guest finds a way past dispatch, or
/// jumps into the stub's code.
fn installFilter() void {
    const n = allowed.len;
    const f = comptime blk: {
        var p: [9 + n + 4]SockFilter = undefined;
        var i: usize = 0;
        p[i] = stmt(BPF_LD_W_ABS, 4); // arch
        i += 1;
        p[i] = jump(BPF_JEQ_K, AUDIT_ARCH_X86_64, 1, 0);
        i += 1;
        p[i] = stmt(BPF_RET_K, RET_KILL_PROCESS);
        i += 1;
        p[i] = stmt(BPF_LD_W_ABS, 12); // instruction_pointer, high half
        i += 1;
        p[i] = jump(BPF_JEQ_K, @intCast(abi.stub_base >> 32), 1, 0);
        i += 1;
        p[i] = stmt(BPF_RET_K, RET_KILL_PROCESS);
        i += 1;
        p[i] = stmt(BPF_LD_W_ABS, 0); // nr
        i += 1;
        // n allowed calls, then mmap, each jumping to the ALLOW at the end.
        for (allowed, 0..) |s, j| {
            p[i] = jump(BPF_JEQ_K, @intFromEnum(s), @intCast(n - j + 4), 0);
            i += 1;
        }
        p[i] = jump(BPF_JEQ_K, @intFromEnum(linux.SYS.mmap), 1, 0);
        i += 1;
        p[i] = stmt(BPF_RET_K, RET_KILL_PROCESS);
        i += 1;
        // mmap: only of the RAM file (args[4], at 16 + 4 * 8).
        p[i] = stmt(BPF_LD_W_ABS, 48);
        i += 1;
        p[i] = jump(BPF_JEQ_K, abi.ram_fd, 1, 0);
        i += 1;
        p[i] = stmt(BPF_RET_K, RET_KILL_PROCESS);
        i += 1;
        p[i] = stmt(BPF_RET_K, RET_ALLOW);
        i += 1;
        break :blk p[0..i].*;
    };
    const prog: SockFprog = .{ .len = f.len, .filter = &f };
    const PR_SET_SECCOMP = 22;
    const SECCOMP_MODE_FILTER = 2;
    check(sys(.prctl, PR_SET_SECCOMP, SECCOMP_MODE_FILTER, @intFromPtr(&prog), 0, 0, 0), 18);
}

// ---- the handler ----

/// struct sigcontext (x86_64), at uc_mcontext.
const Mcontext = extern struct {
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
    di: u64,
    si: u64,
    bp: u64,
    bx: u64,
    dx: u64,
    ax: u64,
    cx: u64,
    sp: u64,
    ip: u64,
    flags: u64,
    cs: u16,
    gs: u16,
    fs: u16,
    ss: u16,
    err: u64,
    trapno: u64,
    oldmask: u64,
    cr2: u64,
    fpstate: ?[*]u8,
};

const Ucontext = extern struct {
    flags: u64,
    link: usize,
    ss_sp: usize,
    ss_flags: u64,
    ss_size: u64,
    mc: Mcontext,
};

const Siginfo = extern struct {
    signo: i32,
    errno: i32,
    code: i32,
    _pad: i32,
    addr: u64,
};

const FP_XSTATE_MAGIC1: u32 = 0x4650_5853;

fn futexWait(p: *volatile u32, v: u32, ts: ?*const linux.timespec) void {
    _ = sys(.futex, @intFromPtr(p), 0, v, @intFromPtr(ts), 0, 0); // FUTEX_WAIT, shared
}

fn futexWake(p: *volatile u32) void {
    _ = sys(.futex, @intFromPtr(p), 1, 1, 0, 0, 0); // FUTEX_WAKE, shared
}

fn load(p: *volatile u32) u32 {
    return @atomicLoad(u32, @volatileCast(p), .seq_cst);
}

fn store(p: *volatile u32, v: u32) void {
    @atomicStore(u32, @volatileCast(p), v, .seq_cst);
}

/// Spins this many rounds for h9's answer before sleeping on the futex.
const spin_rounds = 4000;

/// Waits for h9 to hand the stub something other than `exited`. If h9
/// goes away, the stub follows.
fn waitHost() u32 {
    var i: usize = 0;
    while (i < spin_rounds) : (i += 1) {
        const s = load(&ctl.state);
        if (s != @intFromEnum(abi.State.exited)) return s;
        std.atomic.spinLoopHint();
    }
    const ts: linux.timespec = .{ .sec = 1, .nsec = 0 };
    while (true) {
        store(&ctl.stub_waiting, 1);
        const s = load(&ctl.state);
        if (s != @intFromEnum(abi.State.exited)) {
            store(&ctl.stub_waiting, 0);
            return s;
        }
        futexWait(&ctl.state, s, &ts);
        store(&ctl.stub_waiting, 0);
        if (sys(.getppid, 0, 0, 0, 0, 0, 0) != parent) die(0);
    }
}

fn exited(why: abi.Why) void {
    ctl.why = why;
    store(&ctl.state, @intFromEnum(abi.State.exited));
    if (load(&ctl.host_waiting) != 0) futexWake(&ctl.state);
}

fn doOps() void {
    const n = @min(ctl.nops, abi.max_ops);
    for (0..n) |i| {
        const op = ctl.ops[i];
        switch (op.kind) {
            .map => _ = sys(.mmap, op.va, op.len, op.prot, 0x01 | 0x10, abi.ram_fd, op.off),
            .unmap => _ = sys(.munmap, op.va, op.len, 0, 0, 0, 0),
        }
    }
    ctl.nops = 0;
}

fn saveRegs(mc: *const Mcontext) void {
    const r = &ctl.regs;
    r.ax = mc.ax;
    r.bx = mc.bx;
    r.cx = mc.cx;
    r.dx = mc.dx;
    r.si = mc.si;
    r.di = mc.di;
    r.bp = mc.bp;
    r.r8 = mc.r8;
    r.r9 = mc.r9;
    r.r10 = mc.r10;
    r.r11 = mc.r11;
    r.r12 = mc.r12;
    r.r13 = mc.r13;
    r.r14 = mc.r14;
    r.r15 = mc.r15;
    r.pc = mc.ip;
    r.sp = mc.sp;
    r.flags = mc.flags;
    if (mc.fpstate) |fp| {
        @memcpy(@volatileCast(&ctl.fx), fp[0..abi.fx_len]);
        const magic = std.mem.readInt(u32, fp[464..468], .little);
        ctl.xstate_bv = if (magic == FP_XSTATE_MAGIC1) std.mem.readInt(u64, fp[512..520], .little) else 3;
    }
    fs_base = 0;
    _ = sys(.arch_prctl, ARCH_GET_FS, @intFromPtr(&fs_base), 0, 0, 0, 0);
    ctl.fs_base = fs_base;
}

fn loadRegs(mc: *Mcontext) void {
    const r = &ctl.regs;
    mc.ax = r.ax;
    mc.bx = r.bx;
    mc.cx = r.cx;
    mc.dx = r.dx;
    mc.si = r.si;
    mc.di = r.di;
    mc.bp = r.bp;
    mc.r8 = r.r8;
    mc.r9 = r.r9;
    mc.r10 = r.r10;
    mc.r11 = r.r11;
    mc.r12 = r.r12;
    mc.r13 = r.r13;
    mc.r14 = r.r14;
    mc.r15 = r.r15;
    mc.ip = r.pc;
    mc.sp = r.sp;
    mc.flags = r.flags;
    if (mc.fpstate) |fp| {
        @memcpy(fp[0..abi.fx_len], @volatileCast(&ctl.fx));
        // Reserved MXCSR bits would make rt_sigreturn fail.
        const mxcsr = std.mem.readInt(u32, fp[24..28], .little);
        std.mem.writeInt(u32, fp[24..28], mxcsr & 0xffff, .little);
        if (std.mem.readInt(u32, fp[464..468], .little) == FP_XSTATE_MAGIC1) {
            // x87 and SSE come from the image, not their initial state.
            const bv = std.mem.readInt(u64, fp[512..520], .little);
            std.mem.writeInt(u64, fp[512..520], bv | 3, .little);
        }
    }
    if (ctl.fs_base != fs_base) {
        fs_base = ctl.fs_base;
        _ = sys(.arch_prctl, ARCH_SET_FS, fs_base, 0, 0, 0, 0);
    }
}

fn handler(sig: i32, info: *const Siginfo, ucp: *anyopaque) callconv(.c) void {
    const uc: *Ucontext = @ptrCast(@alignCast(ucp));
    const mc = &uc.mc;
    if (starting) {
        starting = false;
        exited(.ready);
    } else {
        const why: abi.Why = switch (sig) {
            31 => .syscall,
            23 => blk: {
                // A kick h9 has since taken back, or one meant for an
                // earlier run: carry on.
                if (@atomicRmw(u32, @volatileCast(&ctl.kick), .Xchg, 0, .seq_cst) == 0) return;
                break :blk .interrupted;
            },
            else => .trap,
        };
        saveRegs(mc);
        ctl.signo = @intCast(sig);
        ctl.trapno = mc.trapno;
        ctl.err = mc.err;
        ctl.addr = if (sig == 11 or sig == 7) info.addr else mc.ip;
        exited(why);
    }
    while (true) {
        const s = waitHost();
        doOps();
        if (s == @intFromEnum(abi.State.ops)) {
            exited(.ops_done);
            continue;
        }
        break;
    }
    loadRegs(mc);
    store(&ctl.state, @intFromEnum(abi.State.guest));
}

pub const panic = std.debug.no_panic;
