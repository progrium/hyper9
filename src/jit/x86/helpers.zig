//! h86's `call.helper` table: what lifted code calls for instructions it
//! runs in Zig rather than IR, without leaving the region.
//!
//! x87: every D8-DF instruction runs x87.zig, T0's own, on the Cpu, with
//! the operand's linear address worked out in the IR (so a null FS or GS
//! has faulted there) and memory through the lift.Mem in ctx.frontend.
//! If it traps (#MF for a pending exception, #UD, a page fault), the
//! helper puts back everything it changed and returns nonzero, and the
//! region's guard runs the instruction on T0 through `call.interp`, which
//! raises it with all its detail. A memory operand is translated (both
//! pages if it crosses) before anything is written, so a fault leaves
//! memory as it was too.
//!
//! The table goes in ctx.helpers wherever h86's lifted code runs:
//! vmm/h86.zig, the region check's bind (check/x86.zig), and the tests.

const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const lift = @import("lift.zig");
const cpu_mod = @import("../../interp/x86/cpu.zig");
const exec = @import("../../interp/x86/exec.zig");
const x87 = @import("../../interp/x86/x87.zig");
const dec = @import("../../interp/x86/decode.zig");
const f80_mod = @import("../../interp/x86/f80.zig");
const F80 = f80_mod.F80;

const Ctx = ctx_mod.Ctx;
const Cpu = cpu_mod.Cpu;

pub const Index = enum(u8) { x87 = 0, x87fast = 1 };

pub const table = [_]ctx_mod.HelperFn{ x87Helper, x87Fast };

/// The pointer for ctx.helpers.
pub fn tableAddr() u64 {
    return @intFromPtr(&table);
}

/// x87's first argument: what the helper needs of the instruction.
pub const X87Arg = packed struct(u64) {
    pc: u32,
    /// The opcode's low 3 bits (D8-DF).
    op: u3,
    modrm: u8,
    mem: bool,
    seg: u3,
    opsize: bool,
    _: u16 = 0,
};

fn x87Helper(c: *Ctx, a: u64, addr: u64, _: u64) callconv(.c) u64 {
    const cpu = c.cpuPtr(Cpu);
    const m: *lift.Mem = @ptrFromInt(@as(usize, @intCast(c.frontend)));
    const arg: X87Arg = @bitCast(a);
    // What x87.zig may change: the FPU, EAX (FNSTSW AX), EFLAGS (FCOMI),
    // and, on a trap, trap and ecode. EIP is the instruction's while it
    // runs (the last-instruction pointer).
    const fpu = cpu.fpu;
    const eax = cpu.r[0];
    const fl = cpu.fl;
    const eip = cpu.eip;
    const trap = cpu.trap;
    const ecode = cpu.ecode;
    cpu.eip = arg.pc;
    var x: exec.Exec(*lift.Mem) = .{ .c = cpu, .m = m, .opts = .{}, .addr = @truncate(addr) };
    x.i = .{
        .op = .x87,
        .entry = 0,
        .opcode = 0xd8 | @as(u16, arg.op),
        .len = 0,
        .size = 4,
        .opsize = arg.opsize,
        .seg = @enumFromInt(arg.seg),
        .modrm = arg.modrm,
        .mem = arg.mem,
    };
    x87.exec(&x) catch {
        cpu.fpu = fpu;
        cpu.r[0] = eax;
        cpu.fl = fl;
        cpu.eip = eip;
        cpu.trap = trap;
        cpu.ecode = ecode;
        return 1;
    };
    cpu.eip = eip;
    return 0;
}

/// x87fast's kinds: the x87's data movement, the bulk of what x87 code
/// runs (awk's: 88% of its x87 instructions), each done straight on the
/// Fpu when it's exact and raises nothing. Otherwise the helper changes
/// nothing and returns `refuse`, and the region's guard runs the
/// instruction on T0. The memory forms' wait and last-instruction note
/// are the lifter's, before the access, as T0 orders them.
pub const Fast = enum(u8) {
    /// FLD m64fp: b is the double.
    fld64,
    /// FST and FSTP m64fp, first half: the double ST(0) rounds to, or
    /// `refuse`. Changes nothing, so the store can fault after it.
    fst64,
    /// The second half, after the store: PE and C1, and the pop for FSTP.
    fst64_done,
    /// FLD ST(i).
    fld_st,
    /// FST and FSTP ST(i).
    fst_st,
    /// FLDZ and FLD1.
    fld_const,
    /// FXCH ST(i).
    fxch,
    /// D8, DA, DC, and DE's arithmetic and compares with a memory operand:
    /// b is the operand, c its linear address (for the note).
    arith_mem,
    /// FILD m32int: b is the integer.
    fild32,
    /// FIST, FISTP, and FISTTP to m16int or m32int (i is r, `pop` m16),
    /// first half: the integer, or `refuse`. Changes nothing.
    fist,
    /// The second half, after the store: the status word, and the pop.
    fist_done,
    /// FLDCW: b is the word.
    fldcw,
};

/// x87fast's first argument.
pub const FastArg = packed struct(u64) {
    kind: Fast,
    /// ST(i)'s i; for fld_const, 1 for FLD1; for fst64_done and fst_st,
    /// whether to pop (in `pop`).
    i: u3 = 0,
    pop: bool = false,
    _0: u4 = 0,
    /// The opcode's low 3 bits and the ModRM byte, for the note.
    op: u3 = 0,
    seg: u3 = 0,
    _1: u2 = 0,
    modrm: u8 = 0,
    pc: u32 = 0,
};

/// What x87fast returns when it won't: no double has these bits that the
/// helper gives (it's a NaN).
pub const refuse: u64 = std.math.maxInt(u64);

const C1: u16 = 1 << 9;
const PE: u16 = 1 << 5;
const PM: u16 = 1 << 5;
const ES: u16 = 1 << 7;

fn x87Fast(c: *Ctx, a: u64, b: u64, c_: u64) callconv(.c) u64 {
    const cpu = c.cpuPtr(Cpu);
    const p = &cpu.fpu;
    const arg: FastArg = @bitCast(a);
    switch (arg.kind) {
        .fld64 => {
            const v = f80Of(b) orelse return refuse;
            if (!empty(p, 7)) return refuse;
            push(p, v);
            p.sw &= ~C1;
        },
        .fst64 => return f64Of(p) orelse refuse,
        .arith_mem => {
            const eip = cpu.eip;
            cpu.eip = arg.pc;
            defer cpu.eip = eip;
            var x: exec.Exec(*lift.Mem) = .{ .c = cpu, .m = undefined, .opts = .{}, .addr = @truncate(c_) };
            x.i = .{ .op = .x87, .entry = 0, .opcode = 0xd8 | @as(u16, arg.op), .len = 0, .size = 4, .seg = @enumFromInt(arg.seg), .modrm = arg.modrm, .mem = true };
            x87.arithMem(&x, arg.op, @truncate(arg.modrm >> 3), b);
        },
        .fild32 => {
            if (!empty(p, 7)) return refuse;
            push(p, f80_mod.fromI32(@bitCast(@as(u32, @truncate(b)))));
            p.sw &= ~C1;
        },
        .fist, .fist_done => {
            const size: u8 = if (arg.pop) 2 else 4;
            const r = x87.fistPeek(p, size, arg.i) orelse return refuse;
            if (arg.kind == .fist) return @as(u64, @as(u32, @bitCast(@as(i32, @truncate(r.n))))) & (if (size == 2) @as(u64, 0xffff) else 0xffff_ffff);
            p.sw = r.sw;
            if (arg.i != 2) pop(p);
        },
        .fldcw => {
            p.cw = (@as(u16, @truncate(b)) & 0x1f3f) | 0x40;
            x87.summarize(p);
        },
        .fst64_done => {
            const v = st(p, 0);
            const lost = v.signif & 0x7ff;
            if (lost != 0) {
                p.sw |= PE;
                // Rounded up, in magnitude: nearest took the half above.
                const up = lost > 0x400 or (lost == 0x400 and v.signif & 0x800 != 0);
                p.sw = if (up) p.sw | C1 else p.sw & ~C1;
            } else p.sw &= ~C1;
            if (arg.pop) pop(p);
        },
        .fld_st, .fst_st, .fld_const, .fxch => {
            if (p.sw & ES != 0) return refuse;
            switch (arg.kind) {
                .fld_st => if (empty(p, arg.i) or !empty(p, 7)) return refuse,
                .fst_st => if (empty(p, 0)) return refuse,
                .fld_const => if (!empty(p, 7)) return refuse,
                .fxch => if (empty(p, 0) or empty(p, arg.i)) return refuse,
                else => unreachable,
            }
            p.fop = (@as(u16, arg.op) << 8) | arg.modrm;
            p.fip = (@as(u64, cpu.seg[1]) << 32) | arg.pc;
            switch (arg.kind) {
                .fld_st => push(p, st(p, arg.i)),
                .fst_st => {
                    set(p, arg.i, st(p, 0));
                    if (arg.pop) pop(p);
                },
                .fld_const => push(p, if (arg.i == 1) F80.one else F80.zero),
                .fxch => {
                    const t = st(p, 0);
                    set(p, 0, st(p, arg.i));
                    set(p, arg.i, t);
                },
                else => unreachable,
            }
            p.sw &= ~C1;
        },
    }
    return 0;
}

fn phys(p: *const cpu_mod.Fpu, i: u3) u3 {
    return p.top +% i;
}

fn empty(p: *const cpu_mod.Fpu, i: u3) bool {
    return p.tag & (@as(u8, 1) << phys(p, i)) == 0;
}

fn st(p: *const cpu_mod.Fpu, i: u3) F80 {
    return p.st[phys(p, i)];
}

fn set(p: *cpu_mod.Fpu, i: u3, v: F80) void {
    const r = phys(p, i);
    p.st[r] = v;
    p.tag |= @as(u8, 1) << r;
}

fn push(p: *cpu_mod.Fpu, v: F80) void {
    p.top -%= 1;
    set(p, 0, v);
}

fn pop(p: *cpu_mod.Fpu) void {
    p.tag &= ~(@as(u8, 1) << p.top);
    p.top +%= 1;
}

/// A double as an 80-bit value, for a normal or a zero: what FLD makes of
/// it, exactly and with nothing raised. Null for the rest (denormals
/// raise DE, NaNs may raise IE).
fn f80Of(bits: u64) ?F80 {
    const sign: u16 = @intCast(bits >> 63);
    const e: u16 = @intCast((bits >> 52) & 0x7ff);
    const m = bits & 0xf_ffff_ffff_ffff;
    if (e == 0) {
        if (m != 0) return null;
        return .{ .sign_exp = sign << 15, .signif = 0 };
    }
    if (e == 0x7ff) return null;
    return .{ .sign_exp = (sign << 15) | (e + (16383 - 1023)), .signif = (1 << 63) | (m << 11) };
}

/// ST(0) as a double, rounded to nearest, when it's a zero or a normal
/// that stays one, and inexact only where PE is masked. Null for the rest.
fn f64Of(p: *const cpu_mod.Fpu) ?u64 {
    if (empty(p, 0)) return null;
    // Round to nearest only.
    if (p.cw & 0xc00 != 0) return null;
    const v = st(p, 0);
    const sign = @as(u64, v.sign_exp >> 15) << 63;
    const e: u64 = v.sign_exp & 0x7fff;
    if (e == 0 and v.signif == 0) return sign;
    // A normal with its integer bit, in a double's normal range.
    if (v.signif >> 63 == 0 or e < 16383 - 1022 or e > 16383 + 1023) return null;
    const lost = v.signif & 0x7ff;
    if (lost != 0 and p.cw & PM == 0) return null;
    var m = v.signif >> 11; // 53 bits, the integer bit on top
    var de = e + 1023 - 16383;
    if (lost > 0x400 or (lost == 0x400 and m & 1 != 0)) {
        m += 1;
        if (m >> 53 != 0) {
            m >>= 1;
            de += 1;
            if (de >= 0x7ff) return null;
        }
    }
    return sign | (de << 52) | (m & 0xf_ffff_ffff_ffff);
}
