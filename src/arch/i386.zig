//! 386 Plan 9 user ABI (9front 386/include/ureg.h, 9/pc/trap.c, pc/mem.h).
//!
//! Backend-independent: a backend that runs 386 code in compatibility mode
//! under a 64-bit shim uses this as the emulator does.

/// Plan 9 Ureg: 19 32-bit words. `nsp` is the kernel's pushal copy of SP
/// and means nothing to user code; `sp` is the user stack pointer.
pub const Ureg = extern struct {
    di: u32 = 0,
    si: u32 = 0,
    bp: u32 = 0,
    nsp: u32 = 0,
    bx: u32 = 0,
    dx: u32 = 0,
    cx: u32 = 0,
    ax: u32 = 0,
    gs: u32 = 0,
    fs: u32 = 0,
    es: u32 = 0,
    ds: u32 = 0,
    trap: u32 = 0,
    ecode: u32 = 0,
    pc: u32 = 0,
    cs: u32 = 0,
    flags: u32 = 0,
    sp: u32 = 0,
    ss: u32 = 0,

    pub fn syscallNumber(u: *const Ureg) u64 {
        return u.ax;
    }
    /// Arguments are 4-byte words on the user stack above the return PC.
    pub fn syscallArgs(u: *const Ureg) u64 {
        return @as(u64, u.sp) + 4;
    }
    /// The result goes in AX; a vlong result (seek) goes through a pointer.
    pub fn setReturn(u: *Ureg, v: u64) void {
        u.ax = @truncate(v);
    }
    /// Registers at process entry (execregs): AX holds the Tos pointer, as
    /// execregs returns it as the syscall's result, and SP points at argc.
    pub fn initExec(entry: u64, sp: u64, tos: u64) Ureg {
        return .{
            .ax = @intCast(tos),
            .sp = @intCast(sp),
            .pc = @intCast(entry),
            .cs = UESEL,
            .ss = UDSEL,
            .ds = UDSEL,
            .es = UDSEL,
            .fs = NULLSEL,
            .gs = NULLSEL,
        };
    }
};

/// The flags a user may set through noted (setregisters): CF, PF, AF, ZF,
/// SF, DF and OF. TF, IF, IOPL and the rest stay as the kernel had them.
pub const UFLAGSMASK: u32 = 0xCD5;

/// The Ureg a note handler's `noted` may restore: `saved` as the guest
/// left it, with the segment selectors and the privileged flags taken from
/// `cur`, as 9front's setregisters does (it forces RPL 3 on CS and SS; h9
/// keeps the selectors outright, since nothing else is valid in user mode).
pub fn sanitize(saved: Ureg, cur: *const Ureg) Ureg {
    var u = saved;
    u.flags = (saved.flags & UFLAGSMASK) | (cur.flags & ~UFLAGSMASK);
    u.cs = cur.cs;
    u.ss = cur.ss;
    u.ds = cur.ds;
    u.es = cur.es;
    u.fs = cur.fs;
    u.gs = cur.gs;
    return u;
}

/// 9front's notify (pc/trap.c); see arm64.notifyFrame. No register carries
/// the Ureg: the handler finds it at SP+4 and the note at SP+8, with a
/// zero return PC at SP. The words are 4 bytes.
pub fn notifyFrame(u: *const Ureg, handler: u64, errmax: u64) ?NotifyFrame {
    if (handler > 0xffff_ffff) return null;
    var sp: u64 = u.sp;
    sp -%= 256; // debugging: preserve context causing problem
    sp -%= @sizeOf(Ureg);
    const nureg = sp;
    sp -%= 4 + errmax;
    const msg = sp;
    sp -%= 3 * 4;
    if (sp > 0xffff_ffff) return null;
    var r = u.*;
    r.sp = @intCast(sp);
    r.pc = @intCast(handler);
    r.cs = UESEL;
    r.ss = UDSEL;
    r.ds = UDSEL;
    r.es = UDSEL;
    return .{ .nureg = nureg, .msg = msg, .sp = sp, .regs = r };
}

pub const NotifyFrame = struct { nureg: u64, msg: u64, sp: u64, regs: Ureg };

// pc/mem.h: SELECTOR(UESEG, SELGDT, 3), SELECTOR(UDSEG, SELGDT, 3) and
// SELECTOR(NULLSEG, SELGDT, 0).
pub const UESEL: u32 = (4 << 3) | 3;
pub const UDSEL: u32 = (3 << 3) | 3;
pub const NULLSEL: u32 = 0;

/// pc/io.h VectorSYSCALL: INT $64, which 9front puts in Ureg.trap.
pub const vector_syscall = 64;
/// Linux's int 0x80 (design/linux-i386.md). Backends report both as a
/// `.syscall` exit with the vector in Ureg.trap, and the process model
/// takes each personality's own.
pub const vector_linux = 0x80;

comptime {
    const std = @import("std");
    std.debug.assert(@sizeOf(Ureg) == 19 * 4);
    std.debug.assert(@offsetOf(Ureg, "trap") == 48);
    std.debug.assert(@offsetOf(Ureg, "pc") == 56);
    std.debug.assert(@offsetOf(Ureg, "sp") == 68);
}

test "notify frame" {
    const std = @import("std");
    const u: Ureg = .{ .sp = 0xdfffe000, .pc = 0x1234, .flags = 0x246 };
    const f = notifyFrame(&u, 0x2000, 128).?;
    try std.testing.expectEqual(@as(u64, 0xdfffe000 - 256 - 76), f.nureg);
    try std.testing.expectEqual(f.nureg - 4 - 128, f.msg);
    try std.testing.expectEqual(f.msg - 12, f.sp);
    try std.testing.expectEqual(@as(u32, 0x2000), f.regs.pc);
    try std.testing.expectEqual(UESEL, f.regs.cs);
}

test "sanitize keeps the selectors and privileged flags" {
    const std = @import("std");
    const cur: Ureg = .initExec(0x1020, 0xdfffef00, 0xdffffe00);
    var saved = cur;
    saved.cs = 0x08; // kernel code
    saved.ss = 0x10;
    saved.fs = 0x1b;
    saved.flags = 0x3000 | 0x200 | 0x100 | 0x8d5; // IOPL 3, IF, TF, user bits
    saved.pc = 0x1100;
    const r = sanitize(saved, &cur);
    try std.testing.expectEqual(UESEL, r.cs);
    try std.testing.expectEqual(UDSEL, r.ss);
    try std.testing.expectEqual(NULLSEL, r.fs);
    try std.testing.expectEqual(@as(u32, 0x8d5), r.flags);
    try std.testing.expectEqual(@as(u32, 0x1100), r.pc);
}
