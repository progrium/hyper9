//! arm64 Plan 9 user ABI (9front arm64/include/ureg.h, 9/arm64/trap.c).

/// Plan 9 Ureg. `type` holds ESR_EL1 for synchronous exceptions.
pub const Ureg = extern struct {
    r: [31]u64 = @splat(0), // r28 is SB, r30 is the link register
    sp: u64 = 0,
    pc: u64 = 0,
    psr: u64 = 0,
    type: u64 = 0,

    pub fn syscallNumber(u: *const Ureg) u64 {
        return u.r[0];
    }
    pub fn syscallArgs(u: *const Ureg) u64 {
        return u.sp + 8;
    }
    pub fn setReturn(u: *Ureg, v: u64) void {
        u.r[0] = v;
    }
    /// Registers at process entry: R0 holds the Tos pointer.
    pub fn initExec(entry: u64, sp: u64, tos: u64) Ureg {
        var u: Ureg = .{ .sp = sp, .pc = entry };
        u.r[0] = tos;
        return u;
    }
};

/// User-settable PSR bits: NZCV. noted keeps the rest from the kernel's
/// copy, as 9front's setregisters does, so a Ureg the guest wrote can't
/// return to EL1 or mask interrupts (the HVF shim loads `psr` as SPSR_EL1).
pub const USPSRMASK: u64 = 0xf << 28;

/// The Ureg a note handler's `noted` may restore: `saved` as the guest
/// left it, with the PSR's privileged bits from `cur`.
pub fn sanitize(saved: Ureg, cur: *const Ureg) Ureg {
    var u = saved;
    u.psr = (saved.psr & USPSRMASK) | (cur.psr & ~USPSRMASK);
    return u;
}

/// 9front's notify (arm64/trap.c): where the handler's frame goes and how
/// the registers enter it. The kernel copies the interrupted Ureg to
/// `nureg` and the note to `msg`, writes the two words at `sp`+8 and
/// `sp`+16 (the Ureg and the note), and runs `handler` from these
/// registers. Returns null if the frame wouldn't be aligned.
pub fn notifyFrame(u: *const Ureg, handler: u64, errmax: u64) ?NotifyFrame {
    var sp = u.sp;
    sp -%= 256; // debugging: preserve context causing problem
    sp -%= @sizeOf(Ureg);
    sp &= ~@as(u64, 7); // STACKALIGN
    if (handler & 3 != 0) return null;
    const nureg = sp;
    sp -%= 8 + errmax;
    const msg = sp;
    sp -%= 3 * 8;
    var r = u.*;
    r.r[0] = nureg;
    r.sp = sp;
    r.pc = handler;
    r.r[30] = 0;
    return .{ .nureg = nureg, .msg = msg, .sp = sp, .regs = r };
}

pub const NotifyFrame = struct { nureg: u64, msg: u64, sp: u64, regs: Ureg };

comptime {
    const std = @import("std");
    std.debug.assert(@offsetOf(Ureg, "sp") == 248);
    std.debug.assert(@offsetOf(Ureg, "type") == 272);
}

pub const EC_SVC64 = 0x15;
pub const EC_IABT_LOWER = 0x20;
pub const EC_DABT_LOWER = 0x24;
/// Hardware breakpoints (lower and same EL) and BRK, which 9front's trap
/// table all posts as `sys: breakpoint`.
pub const EC_BKPT_LOWER = 0x30;
pub const EC_BKPT_SAME = 0x31;
pub const EC_BRK64 = 0x3c;
