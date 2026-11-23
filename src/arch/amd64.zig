//! amd64 Plan 9 user ABI (9front amd64/include/ureg.h, 9/pc64/trap.c).

pub const Ureg = extern struct {
    ax: u64 = 0,
    bx: u64 = 0,
    cx: u64 = 0,
    dx: u64 = 0,
    si: u64 = 0,
    di: u64 = 0,
    bp: u64 = 0, // RARG: the syscall number, and the first argument of calls
    r8: u64 = 0,
    r9: u64 = 0,
    r10: u64 = 0,
    r11: u64 = 0,
    r12: u64 = 0,
    r13: u64 = 0,
    r14: u64 = 0,
    r15: u64 = 0,
    ds: u16 = 0,
    es: u16 = 0,
    fs: u16 = 0,
    gs: u16 = 0,
    type: u64 = 0,
    @"error": u64 = 0,
    pc: u64 = 0,
    cs: u64 = 0,
    flags: u64 = 0,
    sp: u64 = 0,
    ss: u64 = 0,

    pub fn syscallNumber(u: *const Ureg) u64 {
        return u.bp;
    }
    pub fn syscallArgs(u: *const Ureg) u64 {
        return u.sp + 8;
    }
    pub fn setReturn(u: *Ureg, v: u64) void {
        u.ax = v;
    }
    /// A syscall's return as 9front's forkret (pc64/l.s) makes it: AX holds
    /// the result, and BX, DX, SI, DI, R8 to R10, R12, R13, and BP are
    /// zeroed. CX and R11 hold the PC and flags (SYSRET); only R14 and R15
    /// (up and m in the kernel, restored for the user) survive.
    pub fn sysReturn(u: *Ureg, v: u64) void {
        u.ax = v;
        inline for (.{ "bx", "dx", "si", "di", "r8", "r9", "r10", "r12", "r13", "bp" }) |r| @field(u, r) = 0;
    }
    /// Registers at process entry (execregs): AX holds the Tos pointer and
    /// R14/R15 (extern register variables) start at zero.
    pub fn initExec(entry: u64, sp: u64, tos: u64) Ureg {
        return .{ .ax = tos, .sp = sp, .pc = entry, .cs = UESEL, .ss = UDSEL };
    }
};

/// The Ureg a note handler's `noted` may restore: `saved` as the guest
/// left it, with the segment selectors, the system flags (above the low
/// byte) and a canonical PC enforced, as 9front's setregisters does.
pub fn sanitize(saved: Ureg, cur: *const Ureg) Ureg {
    var u = saved;
    u.cs = UESEL;
    u.ss = UDSEL;
    u.flags = (saved.flags & 0x00ff) | (cur.flags & 0xff00);
    u.pc &= UADDRMASK;
    return u;
}

/// 9front's notify (pc64/trap.c); see arm64.notifyFrame. The handler's
/// first argument, the Ureg, goes in BP (RARG), and the word at `sp` is a
/// zero return PC.
pub fn notifyFrame(u: *const Ureg, handler: u64, errmax: u64) ?NotifyFrame {
    var sp = u.sp;
    sp -%= 256;
    sp -%= @sizeOf(Ureg);
    const nureg = sp;
    sp -%= 8 + errmax;
    const msg = sp;
    sp -%= 3 * 8;
    var r = u.*;
    r.sp = sp;
    r.pc = handler;
    r.bp = nureg;
    r.cs = UESEL;
    r.ss = UDSEL;
    return .{ .nureg = nureg, .msg = msg, .sp = sp, .regs = r };
}

pub const NotifyFrame = struct { nureg: u64, msg: u64, sp: u64, regs: Ureg };

/// pc64/mem.h: the canonical user address mask.
pub const UADDRMASK: u64 = 0x00007fffffffffff;

// pc64/mem.h: SELECTOR(UESEG, SELGDT, 3) and SELECTOR(UDSEG, SELGDT, 3).
pub const UESEL = (5 << 3) | 3;
pub const UDSEL = (4 << 3) | 3;

comptime {
    const std = @import("std");
    std.debug.assert(@offsetOf(Ureg, "type") == 128);
    std.debug.assert(@offsetOf(Ureg, "pc") == 144);
    std.debug.assert(@sizeOf(Ureg) == 184);
}
