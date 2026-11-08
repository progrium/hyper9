//! Linux signals on notes (design/0018-linux-personality.md, "Signals"):
//! the per-process state rt_sigaction and friends keep, the mapping
//! between notes and signals, and the rt_sigframe that delivery builds on
//! the user stack and rt_sigreturn restores, laid out as Linux's.

const std = @import("std");
const vmm = @import("../vmm.zig");

pub const nsig = 64;

pub const SIGHUP = 1;
pub const SIGINT = 2;
pub const SIGQUIT = 3;
pub const SIGILL = 4;
pub const SIGTRAP = 5;
pub const SIGABRT = 6;
pub const SIGBUS = 7;
pub const SIGFPE = 8;
pub const SIGKILL = 9;
pub const SIGUSR1 = 10;
pub const SIGSEGV = 11;
pub const SIGUSR2 = 12;
pub const SIGPIPE = 13;
pub const SIGALRM = 14;
pub const SIGTERM = 15;
pub const SIGCHLD = 17;
pub const SIGCONT = 18;
pub const SIGSTOP = 19;
pub const SIGTSTP = 20;
pub const SIGTTIN = 21;
pub const SIGTTOU = 22;
pub const SIGURG = 23;
pub const SIGXCPU = 24;
pub const SIGXFSZ = 25;
pub const SIGWINCH = 28;
pub const SIGSYS = 31;

pub const SIG_DFL: u64 = 0;
pub const SIG_IGN: u64 = 1;

pub const SA_NOCLDSTOP: u64 = 1;
pub const SA_SIGINFO: u64 = 4;
pub const SA_RESTORER: u64 = 0x04000000;
pub const SA_ONSTACK: u64 = 0x08000000;
pub const SA_RESTART: u64 = 0x10000000;
pub const SA_NODEFER: u64 = 0x40000000;
pub const SA_RESETHAND: u64 = 0x80000000;

pub const SS_ONSTACK: u32 = 1;
pub const SS_DISABLE: u32 = 2;

/// si_code values.
pub const SI_USER: i32 = 0;
pub const SI_KERNEL: i32 = 0x80;
pub const SEGV_MAPERR: i32 = 1;
pub const SEGV_ACCERR: i32 = 2;
pub const CLD_EXITED: i32 = 1;
pub const CLD_KILLED: i32 = 2;
pub const CLD_STOPPED: i32 = 5;
pub const CLD_CONTINUED: i32 = 6;

pub fn bit(signo: u32) u64 {
    return @as(u64, 1) << @intCast(signo - 1);
}

pub const unblockable = bit(SIGKILL) | bit(SIGSTOP);

pub const Action = struct {
    handler: u64 = SIG_DFL,
    flags: u64 = 0,
    restorer: u64 = 0,
    mask: u64 = 0,
};

/// What siginfo says about a pending signal.
pub const Info = struct {
    code: i32 = SI_USER,
    pid: u32 = 0,
    /// The faulting address, for SIGSEGV and SIGBUS.
    addr: u64 = 0,
    /// The child's status, for SIGCHLD.
    status: i32 = 0,
};

pub const AltStack = struct { sp: u64 = 0, size: u64 = 0 };

pub const State = struct {
    actions: [nsig + 1]Action = @splat(.{}),
    mask: u64 = 0,
    pending: u64 = 0,
    info: [nsig + 1]Info = @splat(.{}),
    altstack: AltStack = .{},
    /// rt_sigsuspend's caller's mask, restored once a handler returns.
    suspend_mask: ?u64 = null,
    /// Set while the process runs on the alternate stack.
    on_altstack: bool = false,

    /// What a fork child starts with: the actions, mask and alternate
    /// stack; nothing pending.
    pub fn forkCopy(s: *const State) State {
        return .{ .actions = s.actions, .mask = s.mask, .altstack = s.altstack };
    }

    /// execve: caught signals go back to their default; ignored ones
    /// stay ignored, and the mask and pending signals carry over.
    pub fn execReset(s: *State) void {
        for (&s.actions) |*a| a.* = if (a.handler == SIG_IGN) .{ .handler = SIG_IGN } else .{};
        s.altstack = .{};
        s.suspend_mask = null;
        s.on_altstack = false;
    }

    /// Whether a signal posted now would be dropped: ignored, or by
    /// default ignored.
    pub fn ignored(s: *const State, signo: u32) bool {
        const a = s.actions[signo];
        if (signo == SIGKILL or signo == SIGSTOP) return false;
        if (a.handler == SIG_IGN) return true;
        return a.handler == SIG_DFL and defaultAction(signo) == .ignore;
    }

    /// Makes signo pending, unless it's ignored. Returns whether it is.
    pub fn post(s: *State, signo: u32, info: Info) bool {
        if (signo == 0 or signo > nsig) return false;
        if (s.ignored(signo) and s.mask & bit(signo) == 0) return false;
        s.pending |= bit(signo);
        s.info[signo] = info;
        return true;
    }

    /// Takes the lowest pending signal in `set`.
    pub fn takeFrom(s: *State, set: u64) ?u32 {
        const p = s.pending & set;
        if (p == 0) return null;
        const signo: u32 = @as(u32, @ctz(p)) + 1;
        s.pending &= ~bit(signo);
        return signo;
    }

    /// The next signal to deliver: SIGKILL first, then the lowest
    /// unblocked one.
    pub fn next(s: *State) ?u32 {
        const ready = s.pending & ~(s.mask & ~unblockable);
        if (ready & bit(SIGKILL) != 0) return s.takeFrom(bit(SIGKILL));
        return s.takeFrom(ready);
    }

    pub fn deliverable(s: *const State) bool {
        return s.pending & ~(s.mask & ~unblockable) != 0;
    }
};

pub const Default = enum { term, core, ignore, stop, cont };

pub fn defaultAction(signo: u32) Default {
    return switch (signo) {
        SIGCHLD, SIGURG, SIGWINCH => .ignore,
        SIGCONT => .cont,
        SIGSTOP, SIGTSTP, SIGTTIN, SIGTTOU => .stop,
        SIGQUIT, SIGILL, SIGTRAP, SIGABRT, SIGBUS, SIGFPE, SIGSEGV, SIGXCPU, SIGXFSZ, SIGSYS => .core,
        else => .term,
    };
}

pub const NoteSignal = struct { signo: u8, info: Info = .{} };

/// The signal a note maps to (the table in design/0018, "Signals"), or
/// null for a note no signal stands for.
pub fn noteSignal(msg: []const u8) ?NoteSignal {
    const eql = std.mem.eql;
    const starts = std.mem.startsWith;
    if (eql(u8, msg, "interrupt")) return .{ .signo = SIGINT };
    if (eql(u8, msg, "hangup")) return .{ .signo = SIGHUP };
    if (eql(u8, msg, "alarm")) return .{ .signo = SIGALRM };
    if (eql(u8, msg, "kill") or eql(u8, msg, "Killed")) return .{ .signo = SIGKILL };
    if (starts(u8, msg, "linux: signal ")) {
        var rest = msg["linux: signal ".len..];
        if (std.mem.indexOfScalar(u8, rest, ' ')) |i| rest = rest[0..i];
        const n = std.fmt.parseInt(u8, rest, 10) catch return null;
        if (n == 0 or n > nsig) return null;
        return .{ .signo = n };
    }
    if (starts(u8, msg, "sys: write on closed pipe")) return .{ .signo = SIGPIPE, .info = .{ .code = SI_KERNEL } };
    if (starts(u8, msg, "sys: trap: fault") or starts(u8, msg, "sys: bad address")) {
        var info: Info = .{ .code = SEGV_MAPERR };
        if (std.mem.indexOf(u8, msg, "addr=0x")) |i| {
            const s = msg[i + 7 ..];
            const end = std.mem.indexOfAny(u8, s, " ") orelse s.len;
            info.addr = std.fmt.parseInt(u64, s[0..end], 16) catch 0;
        }
        return .{ .signo = SIGSEGV, .info = info };
    }
    if (starts(u8, msg, "sys: trap: illegal instruction")) return .{ .signo = SIGILL, .info = .{ .code = 1 } };
    if (starts(u8, msg, "sys: trap: divide error") or starts(u8, msg, "sys: fp:")) return .{ .signo = SIGFPE, .info = .{ .code = 1 } };
    if (starts(u8, msg, "sys: trap: misaligned") or starts(u8, msg, "sys: trap: alignment")) return .{ .signo = SIGBUS, .info = .{ .code = 1 } };
    if (starts(u8, msg, "sys: trap:")) return .{ .signo = SIGSEGV, .info = .{ .code = SI_KERNEL } };
    return null;
}

/// The note a signal is posted as: the known notes for the signals that
/// have one, so a 9front process reads them as it always has, and
/// `linux: signal N` otherwise.
/// The note for a signal sent to one thread (tgkill), which isn't
/// passed on to another thread that doesn't block it.
pub fn threadNote(signo: u32, buf: []u8) [:0]const u8 {
    return std.fmt.bufPrintZ(buf, "linux: signal {d} thread", .{signo}) catch "linux: signal 15 thread";
}

pub fn isThreadNote(msg: []const u8) bool {
    return std.mem.startsWith(u8, msg, "linux: signal ") and std.mem.endsWith(u8, msg, " thread");
}

pub fn signalNote(signo: u32, buf: []u8) [:0]const u8 {
    return switch (signo) {
        SIGINT => "interrupt",
        SIGHUP => "hangup",
        SIGALRM => "alarm",
        else => std.fmt.bufPrintZ(buf, "linux: signal {d}", .{signo}) catch "linux: signal 15",
    };
}

/// The exit string of a process killed by signo.
pub fn deathNote(signo: u32, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "linux: signal {d}", .{signo}) catch "linux: signal 9";
}

// Frames.

/// Guest memory for frames: `p.readMem(va, []u8)` and
/// `p.writeMem(va, []const u8)`, failing with any error.
fn siginfo(signo: u32, info: Info) [128]u8 {
    return siginfoAt(signo, info, 16, 8);
}

/// siginfo with its union at `u` and pointers of `ptr` bytes: at 16 and
/// 8 on 64-bit, at 12 and 4 on i386.
fn siginfoAt(signo: u32, info: Info, u: usize, ptr: usize) [128]u8 {
    var b: [128]u8 = @splat(0);
    std.mem.writeInt(i32, b[0..4], @intCast(signo), .little);
    std.mem.writeInt(i32, b[8..12], info.code, .little);
    switch (signo) {
        SIGSEGV, SIGBUS, SIGILL, SIGFPE => if (ptr == 8) std.mem.writeInt(u64, b[u..][0..8], info.addr, .little) else std.mem.writeInt(u32, b[u..][0..4], @truncate(info.addr), .little),
        SIGCHLD => {
            std.mem.writeInt(u32, b[u..][0..4], info.pid, .little);
            std.mem.writeInt(i32, b[u + 8 ..][0..4], info.status, .little);
        },
        else => std.mem.writeInt(u32, b[u..][0..4], info.pid, .little),
    }
    return b;
}

pub const Frame = struct {
    signo: u32,
    info: Info,
    act: Action,
    /// The mask to restore when the handler returns.
    saved_mask: u64,
    /// The vDSO's base, for the arm64 default restorer.
    vdso: u64,
    vdso_sigreturn: u64,
};

pub const FrameError = error{Fault};

/// Where the frame goes: the alternate stack's top if the handler asked
/// for it and the process isn't on it already, or below the current sp.
fn frameTop(s: *const State, act: Action, sp: u64) struct { top: u64, alt: bool } {
    if (act.flags & SA_ONSTACK != 0 and s.altstack.size != 0 and !onStack(s, sp))
        return .{ .top = s.altstack.sp + s.altstack.size, .alt = true };
    return .{ .top = sp, .alt = false };
}

pub fn onStack(s: *const State, sp: u64) bool {
    return s.altstack.size != 0 and sp > s.altstack.sp and sp <= s.altstack.sp + s.altstack.size;
}

// arm64's rt_sigframe: siginfo, then ucontext with the sigcontext at 176
// and its __reserved records at 288 of the sigcontext; a frame record
// (x29, x30) above.
const a64_uc = 128;
const a64_mc = a64_uc + 176;
const a64_reserved = a64_mc + 288;
const a64_frame = a64_reserved + 4096; // 4688: sizeof(struct rt_sigframe)
const a64_total = a64_frame + 16;
const FPSIMD_MAGIC = 0x46508001;
const ESR_MAGIC = 0x45535201;

/// Builds the handler's frame on the stack and points `u` at the
/// handler. `x` is the FP state at delivery.
pub fn setup(p: anytype, s: *State, u: *vmm.Ureg, x: *const vmm.Extra, f: Frame) FrameError!void {
    switch (u.*) {
        .arm64 => |*r| try setupArm64(p, s, r, &x.arm64, f),
        .amd64 => |*r| try setupAmd64(p, s, r, &x.amd64, f),
        .i386 => |*r| try setupI386(p, s, r, &x.i386, f),
    }
}

fn put64(b: []u8, off: usize, v: u64) void {
    std.mem.writeInt(u64, b[off..][0..8], v, .little);
}
fn put32(b: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, b[off..][0..4], v, .little);
}
fn get64(b: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, b[off..][0..8], .little);
}
fn get32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

fn writeStack(b: []u8, off: usize, s: *const State, sp: u64) void {
    put64(b, off, s.altstack.sp);
    put32(b, off + 8, if (s.altstack.size == 0) SS_DISABLE else if (onStack(s, sp)) SS_ONSTACK else 0);
    put64(b, off + 16, s.altstack.size);
}

fn setupArm64(p: anytype, s: *State, r: *vmm.arm64.Ureg, x: *const vmm.Arm64Extra, f: Frame) FrameError!void {
    const where = frameTop(s, f.act, r.sp);
    const sp = (where.top -% a64_total) & ~@as(u64, 15);
    var b: [a64_total]u8 = @splat(0);
    @memcpy(b[0..128], &siginfo(f.signo, f.info));
    // ucontext: uc_flags, uc_link, uc_stack, uc_sigmask.
    writeStack(&b, a64_uc + 16, s, r.sp);
    put64(&b, a64_uc + 40, f.saved_mask);
    // sigcontext.
    put64(&b, a64_mc, f.info.addr);
    for (r.r, 0..) |v, i| put64(&b, a64_mc + 8 + 8 * i, v);
    put64(&b, a64_mc + 256, r.sp);
    put64(&b, a64_mc + 264, r.pc);
    put64(&b, a64_mc + 272, r.psr);
    // fpsimd_context.
    var o: usize = a64_reserved;
    put32(&b, o, FPSIMD_MAGIC);
    put32(&b, o + 4, 528);
    put32(&b, o + 8, @truncate(x.fpsr));
    put32(&b, o + 12, @truncate(x.fpcr));
    for (x.v, 0..) |v, i| std.mem.writeInt(u128, b[o + 16 + 16 * i ..][0..16], v, .little);
    o += 528;
    if (f.signo == SIGSEGV or f.signo == SIGBUS) {
        put32(&b, o, ESR_MAGIC);
        put32(&b, o + 4, 16);
        put64(&b, o + 8, 0);
        o += 16;
    }
    // The null record is already zero. The frame record above.
    put64(&b, a64_frame, r.r[29]);
    put64(&b, a64_frame + 8, r.r[30]);
    p.writeMem(sp, &b) catch return error.Fault;

    const restorer = if (f.act.flags & SA_RESTORER != 0) f.act.restorer else if (f.vdso != 0) f.vdso + f.vdso_sigreturn else 0;
    r.r[0] = f.signo;
    r.r[1] = sp;
    r.r[2] = sp + a64_uc;
    r.r[29] = sp + a64_frame;
    r.r[30] = restorer;
    r.sp = sp;
    r.pc = f.act.handler;
    // Handlers run with PSTATE.BTYPE clear and NZCV as they were.
}

// amd64's rt_sigframe: pretcode, ucontext (sigcontext at 40, sigmask at
// 296), siginfo at 312; the fxsave area 64-aligned above it.
const x64_uc = 8;
const x64_mc = x64_uc + 40;
const x64_mask = x64_uc + 296;
const x64_info = x64_uc + 304;
const x64_size = x64_info + 128;
const x64_flags_user: u64 = 0xcd5; // CF PF AF ZF SF DF OF

fn setupAmd64(p: anytype, s: *State, r: *vmm.amd64.Ureg, x: *const vmm.X86Extra, f: Frame) FrameError!void {
    const where = frameTop(s, f.act, r.sp);
    // The red zone isn't the handler's.
    const top = if (where.alt) where.top else where.top -% 128;
    const fp = (top -% 512) & ~@as(u64, 63);
    const sp = ((fp -% x64_size) & ~@as(u64, 15)) -% 8;
    p.writeMem(fp, std.mem.asBytes(&x.fx)) catch return error.Fault;

    var b: [x64_size]u8 = @splat(0);
    put64(&b, 0, f.act.restorer);
    writeStack(&b, x64_uc + 16, s, r.sp);
    const regs = [_]u64{ r.r8, r.r9, r.r10, r.r11, r.r12, r.r13, r.r14, r.r15, r.di, r.si, r.bp, r.bx, r.dx, r.ax, r.cx, r.sp, r.pc, r.flags };
    for (regs, 0..) |v, i| put64(&b, x64_mc + 8 * i, v);
    // cs, gs, fs, ss.
    std.mem.writeInt(u16, b[x64_mc + 144 ..][0..2], @truncate(r.cs), .little);
    std.mem.writeInt(u16, b[x64_mc + 150 ..][0..2], @truncate(r.ss), .little);
    put64(&b, x64_mc + 152, 0); // err
    put64(&b, x64_mc + 160, if (f.signo == SIGSEGV) 14 else 0); // trapno
    put64(&b, x64_mc + 168, f.saved_mask);
    put64(&b, x64_mc + 176, f.info.addr); // cr2
    put64(&b, x64_mc + 184, fp);
    put64(&b, x64_mask, f.saved_mask);
    @memcpy(b[x64_info..][0..128], &siginfo(f.signo, f.info));
    p.writeMem(sp, &b) catch return error.Fault;

    r.di = f.signo;
    r.si = sp + x64_info;
    r.dx = sp + x64_uc;
    r.ax = 0;
    r.sp = sp;
    r.pc = f.act.handler;
    // The handler starts with DF and TF clear, as Linux's does.
    r.flags &= ~@as(u64, 0x500);
}

// i386's frames (arch/x86/include/asm/sigframe.h, design/0105-linux-i386.md).
// A handler with SA_SIGINFO gets an rt_sigframe: pretcode, sig, pinfo and
// puc (the handler's arguments), siginfo at 16, then the ucontext at 144
// (uc_flags, uc_link, uc_stack, the sigcontext at 20 and the mask at 108)
// and retcode. One without gets the old sigframe, which musl's sigreturn
// restorer pops: pretcode, sig, the sigcontext at 8, an unused fpstate,
// the mask's high word at 720 and retcode. The FP state goes above
// either as a struct _fpstate_32, the FXSAVE image at its 112.
const i32_rt_info = 16;
const i32_rt_uc = 144;
const i32_rt_mc = i32_rt_uc + 20;
const i32_rt_mask = i32_rt_uc + 108;
const i32_rt_ret = i32_rt_uc + 116;
const i32_rt_size = i32_rt_ret + 8;
const i32_mc = 8;
const i32_extramask = 720;
const i32_ret = 724;
const i32_size = 732;
const i32_fp_size = 112 + 512;
const i32_flags_user: u32 = 0xcd5; // CF PF AF ZF SF DF OF (and the kernel's AC, which it allows, is left out)

/// The TLS selector: i386 Linux programs load %gs with it, from the GDT
/// entry set_thread_area gives them (design/0105-linux-i386.md, "TLS").
pub const i386_tls_entry = 6;
pub const i386_tls_sel: u32 = (i386_tls_entry << 3) | 3;

fn setupI386(p: anytype, s: *State, r: *vmm.ia32.Ureg, x: *const vmm.X86Extra, f: Frame) FrameError!void {
    const rt = f.act.flags & SA_SIGINFO != 0;
    const where = frameTop(s, f.act, r.sp);
    const fp = (where.top -% i32_fp_size) & ~@as(u64, 63);
    const size: u64 = if (rt) i32_rt_size else i32_size;
    // As Linux's get_sigframe: 16-aligned, less the return address a call
    // would have pushed.
    const sp = ((fp -% size) & ~@as(u64, 15)) -% 4;
    if (sp > 0xffff_ffff) return error.Fault;
    var fpb: [i32_fp_size]u8 = @splat(0);
    // The legacy header: cw, sw, tag; magic 0 at 110 says FXSR follows.
    put32(&fpb, 0, 0xffff0000 | @as(u32, x.fx.fcw));
    put32(&fpb, 4, 0xffff0000 | @as(u32, x.fx.fsw));
    put32(&fpb, 8, 0xffffffff);
    @memcpy(fpb[112..][0..512], std.mem.asBytes(&x.fx));
    p.writeMem(fp, &fpb) catch return error.Fault;

    // The return trampoline, for a handler without a restorer: Linux's
    // retcode, `movl $nr, %eax; int $0x80` (with a `popl %eax` first for
    // the old frame).
    var b: [i32_size]u8 = @splat(0);
    const mc: usize = if (rt) i32_rt_mc else i32_mc;
    const ret_off: usize = if (rt) i32_rt_ret else i32_ret;
    const trampoline = if (rt) [8]u8{ 0xb8, 173, 0, 0, 0, 0xcd, 0x80, 0 } else [8]u8{ 0x58, 0xb8, 119, 0, 0, 0, 0xcd, 0x80 };
    @memcpy(b[ret_off..][0..8], &trampoline);
    const restorer = if (f.act.flags & SA_RESTORER != 0) f.act.restorer else sp + ret_off;
    put32(&b, 0, @truncate(restorer));
    put32(&b, 4, f.signo);
    // sigcontext: gs, fs, es, ds, edi, esi, ebp, esp, ebx, edx, ecx, eax,
    // trapno, err, eip, cs, eflags, esp_at_signal, ss, fpstate, oldmask, cr2.
    const regs = [_]u32{ r.gs, r.fs, r.es, r.ds, r.di, r.si, r.bp, r.sp, r.bx, r.dx, r.cx, r.ax, if (f.signo == SIGSEGV) 14 else 0, 0, r.pc, r.cs, r.flags, r.sp, r.ss, @intCast(fp), @truncate(f.saved_mask), @truncate(f.info.addr) };
    for (regs, 0..) |v, i| put32(&b, mc + 4 * i, v);
    if (rt) {
        put32(&b, 8, @intCast(sp + i32_rt_info));
        put32(&b, 12, @intCast(sp + i32_rt_uc));
        @memcpy(b[i32_rt_info..][0..128], &siginfoAt(f.signo, f.info, 12, 4));
        // uc_stack: ss_sp, ss_flags, ss_size.
        put32(&b, i32_rt_uc + 8, @truncate(s.altstack.sp));
        put32(&b, i32_rt_uc + 12, if (s.altstack.size == 0) SS_DISABLE else if (onStack(s, r.sp)) SS_ONSTACK else 0);
        put32(&b, i32_rt_uc + 16, @truncate(s.altstack.size));
        put64(&b, i32_rt_mask, f.saved_mask);
    } else put32(&b, i32_extramask, @truncate(f.saved_mask >> 32));
    p.writeMem(sp, b[0..@intCast(size)]) catch return error.Fault;

    r.sp = @intCast(sp);
    r.pc = @truncate(f.act.handler);
    // The handler's arguments are on the stack; Linux also passes them in
    // eax, edx and ecx (regparm(3) handlers).
    r.ax = f.signo;
    r.dx = if (rt) @intCast(sp + i32_rt_info) else 0;
    r.cx = if (rt) @intCast(sp + i32_rt_uc) else 0;
    // The handler starts with DF and TF clear, as Linux's does.
    r.flags &= ~@as(u32, 0x500);
}

/// i386's sigreturn (rt or not, by the call's number, still in eax):
/// the registers, the FP state and the mask from the frame. The
/// selectors stay the kernel's, but for %gs, which may be null or the
/// TLS one.
fn restoreI386(p: anytype, r: *vmm.ia32.Ureg, x: *vmm.Extra) FrameError!u64 {
    const rt = r.ax == 173;
    // The handler's `ret` popped pretcode; the old restorer popped sig too.
    const frame: u64 = r.sp -% @as(u32, if (rt) 4 else 8);
    var b: [i32_size]u8 = undefined;
    const size: usize = if (rt) i32_rt_size else i32_size;
    p.readMem(frame, b[0..size]) catch return error.Fault;
    const mc: usize = if (rt) i32_rt_mc else i32_mc;
    const mask: u64 = if (rt) get64(&b, i32_rt_mask) else get32(&b, mc + 80) | @as(u64, get32(&b, i32_extramask)) << 32;
    var n = r.*;
    const gs = get32(&b, mc) & 0xffff;
    n.gs = if (gs == i386_tls_sel) gs else 0;
    const dst = [_]*u32{ &n.di, &n.si, &n.bp, &n.sp, &n.bx, &n.dx, &n.cx, &n.ax };
    for (dst, 0..) |d, i| d.* = get32(&b, mc + 16 + 4 * i);
    n.pc = get32(&b, mc + 56);
    const fl = get32(&b, mc + 64);
    n.flags = (fl & i32_flags_user) | (r.flags & ~i32_flags_user);
    const fp = get32(&b, mc + 76);
    if (fp != 0) {
        var fx: vmm.Fxsave = undefined;
        p.readMem(fp + 112, std.mem.asBytes(&fx)) catch return error.Fault;
        fx.mxcsr &= 0xffff;
        x.i386.fx = fx;
    } else x.i386.fx = vmm.X86Extra.init.fx;
    r.* = n;
    return mask;
}

/// rt_sigreturn: restores the registers, FP state and mask from the frame
/// the handler was entered with, sanitized as noted's are: on arm64 only
/// NZCV comes from the frame, on amd64 only the arithmetic flags, and the
/// selectors are forced. `u` holds the registers at the call.
pub fn restore(p: anytype, s: *State, u: *vmm.Ureg, x: *vmm.Extra) FrameError!void {
    var mask: u64 = 0;
    switch (u.*) {
        .arm64 => |*r| {
            const sp = r.sp;
            if (sp & 15 != 0) return error.Fault;
            var b: [a64_frame]u8 = undefined;
            p.readMem(sp, &b) catch return error.Fault;
            mask = get64(&b, a64_uc + 40);
            var n = r.*;
            for (&n.r, 0..) |*v, i| v.* = get64(&b, a64_mc + 8 + 8 * i);
            n.sp = get64(&b, a64_mc + 256);
            n.pc = get64(&b, a64_mc + 264);
            const psr = get64(&b, a64_mc + 272);
            n.psr = (psr & vmm.arm64.USPSRMASK) | (r.psr & ~vmm.arm64.USPSRMASK);
            if (n.pc & 3 != 0) return error.Fault;
            // The records: fpsimd_context restores the FP state.
            var o: usize = a64_reserved;
            while (o + 8 <= a64_frame) {
                const magic = get32(&b, o);
                const size = get32(&b, o + 4);
                if (magic == 0) break;
                if (size < 8 or size % 16 != 0 or o + size > a64_frame) return error.Fault;
                if (magic == FPSIMD_MAGIC) {
                    if (size != 528) return error.Fault;
                    const fx = &x.arm64;
                    fx.fpsr = get32(&b, o + 8);
                    fx.fpcr = get32(&b, o + 12);
                    for (&fx.v, 0..) |*v, i| v.* = std.mem.readInt(u128, b[o + 16 + 16 * i ..][0..16], .little);
                }
                o += size;
            }
            r.* = n;
        },
        .amd64 => |*r| {
            const sp = r.sp -% 8;
            var b: [x64_size]u8 = undefined;
            p.readMem(sp, &b) catch return error.Fault;
            mask = get64(&b, x64_mask);
            var n = r.*;
            const dst = [_]*u64{ &n.r8, &n.r9, &n.r10, &n.r11, &n.r12, &n.r13, &n.r14, &n.r15, &n.di, &n.si, &n.bp, &n.bx, &n.dx, &n.ax, &n.cx, &n.sp, &n.pc };
            for (dst, 0..) |d, i| d.* = get64(&b, x64_mc + 8 * i);
            const fl = get64(&b, x64_mc + 136);
            n.flags = (fl & x64_flags_user) | (r.flags & ~x64_flags_user);
            n.cs = r.cs;
            n.ss = r.ss;
            // A non-canonical pc would fault in the kernel's sysret.
            if (n.pc >= 1 << 47) return error.Fault;
            const fp = get64(&b, x64_mc + 184);
            if (fp != 0) {
                var fx: vmm.Fxsave = undefined;
                p.readMem(fp, std.mem.asBytes(&fx)) catch return error.Fault;
                // MXCSR's reserved bits would fault FXRSTOR.
                fx.mxcsr &= 0xffff;
                x.amd64.fx = fx;
            } else x.amd64.fx = vmm.X86Extra.init.fx;
            r.* = n;
        },
        .i386 => |*r| mask = try restoreI386(p, r, x),
    }
    s.mask = mask & ~unblockable;
    s.on_altstack = onStack(s, u.stackPointer());
}

test "note signals" {
    try std.testing.expectEqual(@as(u8, SIGINT), noteSignal("interrupt").?.signo);
    try std.testing.expectEqual(@as(u8, 15), noteSignal("linux: signal 15").?.signo);
    const f = noteSignal("sys: trap: fault read addr=0x1234 pc=0x5").?;
    try std.testing.expectEqual(@as(u8, SIGSEGV), f.signo);
    try std.testing.expectEqual(@as(u64, 0x1234), f.info.addr);
    try std.testing.expect(noteSignal("something else") == null);
    var s: State = .{};
    try std.testing.expect(!s.post(SIGCHLD, .{}));
    try std.testing.expect(s.post(SIGTERM, .{}));
    s.mask = bit(SIGTERM);
    try std.testing.expect(s.next() == null);
    s.mask = 0;
    try std.testing.expectEqual(@as(u32, SIGTERM), s.next().?);
}
