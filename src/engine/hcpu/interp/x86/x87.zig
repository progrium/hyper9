//! h86's x87: every D8-DF instruction, and FWAIT. T0's exec.zig sends
//! them here; see exec.zig's header for what an `Exec` offers.
//!
//! Arithmetic is SoftFloat's (f80.zig), in the rounding mode and
//! precision the control word picks, with an `Env` made per instruction
//! from it, so each vCPU's state is its own `Fpu`. FPREM, FPREM1, the
//! transcendentals, FSCALE, and FXTRACT are in x87math.zig.
//!
//! Exceptions: every one sets its flag in the status word. A masked one
//! takes the x87's default response (the indefinite NaN, an infinity, a
//! denormal...). An unmasked one also sets ES and B, and the next waiting
//! instruction (this file's, FWAIT, or MMX's) raises #MF (vector 16)
//! instead of running. Unmasked IE, DE, and ZE leave the destination and
//! the stack as they were; unmasked OE and UE write the masked response
//! rather than the hardware's exponent-wrapped one, a difference only a
//! handler that reads the result could see. Stores to memory are skipped
//! for any unmasked exception but PE.
//!
//! C1 follows the hardware: set when a result was rounded up, and on a
//! stack overflow; clear on an underflow.

const std = @import("std");
const cpu = @import("cpu.zig");
const sf = @import("f80.zig");
const xm = @import("x87math.zig");
const flags = @import("flags.zig");

const F80 = sf.F80;
const Fpu = cpu.Fpu;

// Status word.
pub const IE: u16 = 1 << 0;
pub const DE: u16 = 1 << 1;
pub const ZE: u16 = 1 << 2;
pub const OE: u16 = 1 << 3;
pub const UE: u16 = 1 << 4;
pub const PE: u16 = 1 << 5;
pub const SF: u16 = 1 << 6;
pub const ES: u16 = 1 << 7;
pub const C0: u16 = 1 << 8;
pub const C1: u16 = 1 << 9;
pub const C2: u16 = 1 << 10;
pub const C3: u16 = 1 << 14;
pub const B: u16 = 1 << 15;
const exc_mask: u16 = 0x3f;

const indefinite = F80.default_nan;

/// T0's long-mode Exec sends `.x87` and `.fwait` entries here: this file
/// takes hx64's.
pub const long_mode = true;

/// Whether the Exec type `X` (a pointer) runs in long mode (hx64): its Cpu
/// is a Cpu64. sse.zig asks too.
pub fn isLong(comptime X: type) bool {
    const P = @typeInfo(X).pointer.child;
    return @typeInfo(@FieldType(P, "c")).pointer.child == cpu.Cpu64;
}

// ------------------------------------------------------------ registers

/// The physical register ST(i) is.
pub inline fn phys(p: *const Fpu, i: u3) u3 {
    return p.top +% i;
}

pub inline fn isEmpty(p: *const Fpu, i: u3) bool {
    return p.tag & (@as(u8, 1) << phys(p, i)) == 0;
}

pub inline fn st(p: *const Fpu, i: u3) F80 {
    return p.st[phys(p, i)];
}

pub inline fn setSt(p: *Fpu, i: u3, v: F80) void {
    const r = phys(p, i);
    p.st[r] = v;
    p.tag |= @as(u8, 1) << r;
}

fn push(p: *Fpu, v: F80) void {
    p.top -%= 1;
    setSt(p, 0, v);
}

fn pop(p: *Fpu) void {
    p.tag &= ~(@as(u8, 1) << p.top);
    p.top +%= 1;
}

/// Sets or clears ES and B by whether an unmasked exception's flag is
/// set, as loading the control word or an environment does.
pub fn summarize(p: *Fpu) void {
    if (p.sw & ~p.cw & exc_mask != 0) p.sw |= ES | B else p.sw &= ~(ES | B);
}

/// The status word with TOP in it.
pub fn statusWord(p: *const Fpu) u16 {
    return (p.sw & ~@as(u16, 0x3800)) | (@as(u16, p.top) << 11);
}

/// An unnormal, pseudo-infinity, or pseudo-NaN: the x87 refuses them.
fn unsupported(a: F80) bool {
    return a.exp() != 0 and a.signif >> 63 == 0;
}

/// The two-bit tag FSTENV and FSAVE store for physical register r:
/// valid, zero, special, or empty.
fn fullTag(p: *const Fpu, r: u3) u2 {
    if (p.tag & (@as(u8, 1) << r) == 0) return 3;
    const v = p.st[r];
    const e = v.exp();
    if (e == 0x7fff or unsupported(v)) return 2;
    if (e == 0) return if (v.signif == 0) 1 else 2;
    return 0;
}

pub fn tagWord(p: *const Fpu) u16 {
    var t: u16 = 0;
    for (0..8) |r| t |= @as(u16, fullTag(p, @intCast(r))) << @intCast(2 * r);
    return t;
}

/// The abridged tag of a full tag word: empty where it says 11.
pub fn abridge(t: u16) u8 {
    var a: u8 = 0;
    for (0..8) |r| {
        if ((t >> @intCast(2 * r)) & 3 != 3) a |= @as(u8, 1) << @intCast(r);
    }
    return a;
}

/// FNINIT: the registers keep their bits, but all are empty.
pub fn init(p: *Fpu) void {
    p.* = .{ .st = p.st };
}

// ------------------------------------------------------------ an operation

/// One instruction's arithmetic: the SoftFloat environment the control
/// word makes, and the exceptions and C1 it raises.
const Op = struct {
    p: *Fpu,
    env: sf.Env,
    /// Exceptions not counted in env.flags: DE, stack faults (IE and SF),
    /// invalid operands SoftFloat doesn't see.
    exc: u16 = 0,
    c1: bool = false,
    /// C1 stays as it was unless a stack fault sets it (FNOP, FCMOVcc,
    /// and FCOMI's family).
    keep_c1: bool = false,

    fn begin(p: *Fpu) Op {
        return .{ .p = p, .env = .{
            .rounding = sf.Rounding.fromX87(@truncate(p.cw >> 10)),
            .precision = sf.Precision.fromX87(@truncate(p.cw >> 8)),
        } };
    }

    fn raised(o: *const Op) u16 {
        return o.exc | o.env.flags.x87();
    }

    /// No unmasked IE, DE, or ZE: the result may be written.
    fn ok(o: *const Op) bool {
        return o.raised() & (IE | DE | ZE) & ~o.p.cw == 0;
    }

    /// No unmasked exception but PE: a store to memory may happen.
    fn okStore(o: *const Op) bool {
        return o.raised() & (IE | DE | ZE | OE | UE) & ~o.p.cw == 0;
    }

    fn underflow(o: *Op) void {
        o.exc |= IE | SF;
        o.c1 = false;
    }

    fn overflow(o: *Op) void {
        o.exc |= IE | SF;
        o.c1 = true;
    }

    fn invalid(o: *Op) F80 {
        o.exc |= IE;
        return indefinite;
    }

    /// Writes the status word: the exception flags, C1, and the summary.
    fn done(o: *Op) void {
        var f = o.raised();
        // A stack fault is all an instruction reports before computing.
        if (f & SF != 0) f &= ~DE;
        // An unmasked IE, DE, or ZE stops the operation before it
        // computes, so nothing after it is raised and nothing rounded.
        if (f & (IE | DE | ZE) & ~o.p.cw != 0) {
            f &= ~(OE | UE | PE);
            if (f & SF == 0) o.c1 = false;
        }
        var sw = o.p.sw | (f & 0x7f);
        if (o.keep_c1 and f & SF == 0) o.c1 = sw & C1 != 0;
        sw = (sw & ~C1) | (if (o.c1) C1 else 0);
        if (f & ~o.p.cw & exc_mask != 0) sw |= ES | B;
        o.p.sw = sw;
    }

    /// Writes C3, C2, C1, and C0 together, with the status.
    fn doneCC(o: *Op, cc: u16) void {
        o.done();
        o.p.sw = (o.p.sw & ~(C0 | C1 | C2 | C3)) | cc;
    }

    /// ST(i), or a stack underflow and the indefinite NaN if it's empty.
    fn get(o: *Op, i: u3) F80 {
        if (isEmpty(o.p, i)) {
            o.underflow();
            return indefinite;
        }
        return st(o.p, i);
    }

    /// DE for a denormal among operands none of which is a NaN.
    fn denormals(o: *Op, a: F80, b: F80, b_den: bool) void {
        if (a.isNan() or b.isNan()) return;
        if (a.isDenormal() or b.isDenormal() or b_den) o.exc |= DE;
    }

    /// Sets C1 if `r` was rounded up: if rounding toward zero (`t`) gave
    /// a smaller magnitude.
    fn roundedUp(o: *Op, r: F80, t: F80) void {
        o.c1 = (r.sign_exp & 0x7fff) != (t.sign_exp & 0x7fff) or r.signif != t.signif;
    }

    /// A trial environment for rounding toward zero.
    fn chop(o: *const Op) sf.Env {
        var e = o.env;
        e.rounding = .min_mag;
        e.flags = .{};
        return e;
    }

    /// add (0), mul (1), sub (4: a - b), subr (5: b - a), div (6: a / b),
    /// and divr (7: b / a). `b_den` says b came from a denormal in memory.
    fn arith(o: *Op, k: u3, a: F80, b: F80, b_den: bool) F80 {
        if (unsupported(a) or unsupported(b)) return o.invalid();
        // A division by zero doesn't look at the dividend: no DE.
        const by_zero = (k == 6 and b.signif == 0 and !b.isNan()) or (k == 7 and a.signif == 0 and !a.isNan());
        if (!by_zero) o.denormals(a, b, b_den);
        const r = compute(&o.env, k, a, b);
        // C1: rounded up, as rounding toward zero would show (f80.zig
        // tracks it, so the operation isn't done twice).
        if (o.env.flags.inexact) o.c1 = o.env.rounded_up;
        return r;
    }

    /// FSQRT, at the control word's precision.
    fn arithSqrt(o: *Op, a: F80) F80 {
        const r = o.env.sqrt(a);
        if (o.env.flags.inexact) o.c1 = o.env.rounded_up;
        return r;
    }

    /// Rounds a binary128 result (x87math's) to the 80-bit format,
    /// setting C1 if it rounded up.
    fn round(o: *Op, v: f128) F80 {
        return o.roundScaled(.{ .v = v });
    }

    fn roundScaled(o: *Op, v: xm.Scaled) F80 {
        const r = xm.roundScaled(&o.env, v);
        if (o.env.flags.inexact) {
            var e = o.chop();
            o.roundedUp(r, xm.roundScaled(&e, v));
        }
        return r;
    }
};

fn compute(env: *sf.Env, k: u3, a: F80, b: F80) F80 {
    return switch (k) {
        0 => env.add(a, b),
        1 => env.mul(a, b),
        4 => env.sub(a, b),
        5 => env.sub(b, a),
        6 => env.div(a, b),
        7 => env.div(b, a),
        else => unreachable,
    };
}

const Order = enum { gt, lt, eq, un };

/// FCOM's (or, `quiet`, FUCOM's) comparison of a with b.
fn compare(o: *Op, a: F80, b: F80, b_den: bool, quiet: bool) Order {
    if (unsupported(a) or unsupported(b)) {
        o.exc |= IE;
        return .un;
    }
    if (a.isNan() or b.isNan()) {
        if (!quiet or a.isSignalingNan() or b.isSignalingNan()) o.exc |= IE;
        return .un;
    }
    o.denormals(a, b, b_den);
    if (o.env.eq(a, b)) return .eq;
    return if (o.env.lt(a, b)) .lt else .gt;
}

fn ccOf(ord: Order) u16 {
    return switch (ord) {
        .gt => 0,
        .lt => C0,
        .eq => C3,
        .un => C3 | C2 | C0,
    };
}

// ------------------------------------------------------------ the CPU side

/// #MF if an unmasked exception is pending, for a waiting instruction.
pub fn wait(x: anytype) !void {
    if (x.c.fpu.sw & ES != 0) return x.exc(cpu.vec_mf);
}

/// FWAIT: #MF for a pending unmasked exception.
pub fn fwait(x: anytype) !void {
    return wait(x);
}

/// Notes the instruction and its operand for FSTENV, FSAVE, and FXSAVE:
/// the opcode's low 11 bits, and the instruction and operand pointers,
/// each with its selector above the offset.
fn note(x: anytype) void {
    const p = &x.c.fpu;
    const i = x.i;
    p.fop = (@as(u16, @as(u3, @truncate(i.opcode))) << 8) | i.modrm;
    if (comptime isLong(@TypeOf(x))) {
        // Long mode has no selectors: the pointers are whole addresses.
        p.fip = x.c.rip;
        if (i.mem) p.fdp = x.addr;
        return;
    }
    p.fip = (@as(u64, x.c.seg[1]) << 32) | x.c.eip;
    if (i.mem) p.fdp = (@as(u64, x.c.seg[@intFromEnum(i.seg)]) << 32) | x.addr;
}

/// Runs a D8-DF instruction.
pub fn exec(x: anytype) !void {
    const i = x.i;
    const op: u3 = @truncate(i.opcode);
    // REX doesn't reach ModRM's fields here: reg is an opcode extension
    // and rm an ST(i).
    const reg: u3 = @truncate(i.modrm >> 3);
    if (i.mem) return execMem(x, op, reg);
    return execReg(x, op, reg, @truncate(i.modrm));
}

// ------------------------------------------------------------ memory forms

fn isDen32(v: u32) bool {
    return v & 0x7f80_0000 == 0 and v & 0x7f_ffff != 0;
}

fn isDen64(v: u64) bool {
    return v & 0x7ff0_0000_0000_0000 == 0 and v & 0xf_ffff_ffff_ffff != 0;
}

/// An m32fp operand of arithmetic: a signaling NaN stays signaling, for
/// the operation to raise IE and pick between NaNs as the x87 does.
fn widen32(env: *sf.Env, v: u32) F80 {
    if (v & 0x7f80_0000 == 0x7f80_0000 and v & 0x7f_ffff != 0)
        return .{ .sign_exp = @as(u16, @truncate(v >> 16)) & 0x8000 | 0x7fff, .signif = (1 << 63) | (@as(u64, v & 0x7f_ffff) << 40) };
    return env.fromF32(v);
}

fn widen64(env: *sf.Env, v: u64) F80 {
    if (v & 0x7ff0_0000_0000_0000 == 0x7ff0_0000_0000_0000 and v & 0xf_ffff_ffff_ffff != 0)
        return .{ .sign_exp = @as(u16, @truncate(v >> 48)) & 0x8000 | 0x7fff, .signif = (1 << 63) | ((v & 0xf_ffff_ffff_ffff) << 11) };
    return env.fromF64(v);
}

fn execMem(x: anytype, op: u3, r: u3) !void {
    const p = &x.c.fpu;
    const a = x.addr;
    // The control instructions, which don't wait (FLDCW, FLDENV, and
    // FRSTOR don't either) and leave the last-instruction pointers alone.
    switch (op) {
        1 => switch (r) {
            1 => return x.exc(cpu.vec_ud),
            4 => {
                try wait(x);
                return fldenv(x, a);
            },
            5 => {
                try wait(x);
                p.cw = @truncate(try x.load(a, 2));
                p.cw = (p.cw & 0x1f3f) | 0x40;
                summarize(p);
                return;
            },
            6 => return fstenv(x, a),
            7 => return x.store(a, 2, p.cw),
            else => {},
        },
        3 => if (r == 4 or r == 6) return x.exc(cpu.vec_ud),
        5 => switch (r) {
            4 => {
                try wait(x);
                return frstor(x, a);
            },
            5 => return x.exc(cpu.vec_ud),
            6 => return fsave(x, a),
            7 => return x.store(a, 2, statusWord(p)),
            else => {},
        },
        else => {},
    }
    try wait(x);
    // Arithmetic with a memory operand: D8 m32fp, DA m32int, DC m64fp,
    // DE m16int.
    if (op & 1 == 0) {
        var o = Op.begin(p);
        var b: F80 = undefined;
        var b_den = false;
        switch (op) {
            0 => {
                const v: u32 = @truncate(try x.load(a, 4));
                b_den = isDen32(v);
                b = widen32(&o.env, v);
            },
            2 => b = sf.fromI32(@bitCast(@as(u32, @truncate(try x.load(a, 4))))),
            4 => {
                const v = try x.load64(a);
                b_den = isDen64(v);
                b = widen64(&o.env, v);
            },
            6 => b = sf.fromI32(@as(i16, @bitCast(@as(u16, @truncate(try x.load(a, 2)))))),
            else => unreachable,
        }
        note(x);
        return arithOrCompare(&o, r, 0, b, b_den, false);
    }
    note(x);
    switch (op) {
        1 => switch (r) {
            0 => {
                const v: u32 = @truncate(try x.load(a, 4));
                var o = Op.begin(p);
                const f = o.env.fromF32(v);
                if (isDen32(v)) o.exc |= DE;
                return fld(&o, f);
            },
            2, 3 => return fstFloat(x, a, 4, r == 3),
            else => unreachable,
        },
        3 => switch (r) {
            0 => {
                const v: u32 = @truncate(try x.load(a, 4));
                var o = Op.begin(p);
                return fld(&o, sf.fromI32(@bitCast(v)));
            },
            1, 2, 3 => return fist(x, a, 4, r),
            5 => {
                var buf: [10]u8 = undefined;
                try x.loadBytes(a, &buf);
                var o = Op.begin(p);
                return fld(&o, F80.fromBits(std.mem.readInt(u80, &buf, .little)));
            },
            7 => {
                var o = Op.begin(p);
                const v = o.get(0);
                if (!o.ok()) return o.done();
                var buf: [10]u8 = undefined;
                std.mem.writeInt(u80, &buf, v.toBits(), .little);
                try x.storeBytes(a, &buf);
                pop(p);
                return o.done();
            },
            else => unreachable,
        },
        5 => switch (r) {
            0 => {
                const v = try x.load64(a);
                var o = Op.begin(p);
                const f = o.env.fromF64(v);
                if (isDen64(v)) o.exc |= DE;
                return fld(&o, f);
            },
            1, 2, 3 => if (r == 1) return fist(x, a, 8, 1) else return fstFloat(x, a, 8, r == 3),
            else => unreachable,
        },
        7 => switch (r) {
            0 => {
                const v: u16 = @truncate(try x.load(a, 2));
                var o = Op.begin(p);
                return fld(&o, sf.fromI32(@as(i16, @bitCast(@as(u16, @truncate(v))))));
            },
            1, 2, 3 => return fist(x, a, 2, r),
            4 => return fbld(x, a),
            5 => {
                const v = try x.load64(a);
                var o = Op.begin(p);
                return fld(&o, sf.fromI64(@bitCast(v)));
            },
            6 => return fbstp(x, a),
            7 => return fist(x, a, 8, 3),
        },
        else => unreachable,
    }
}

/// Pushes v, or the indefinite NaN on a stack overflow.
fn fld(o: *Op, v: F80) void {
    var val = v;
    if (o.exc & SF == 0 and !isEmpty(o.p, 7)) {
        o.overflow();
        val = indefinite;
    }
    // A load's DE doesn't stop it: the value is exact.
    if (o.raised() & IE & ~o.p.cw == 0) push(o.p, val);
    o.done();
}

/// FST and FSTP to an m32fp or m64fp.
fn fstFloat(x: anytype, a: anytype, size: u8, do_pop: bool) !void {
    const p = &x.c.fpu;
    var o = Op.begin(p);
    const v = o.get(0);
    var bits: u64 = undefined;
    if (unsupported(v)) {
        _ = o.invalid();
        bits = if (size == 4) 0xffc0_0000 else 0xfff8_0000_0000_0000;
    } else if (size == 4) {
        bits = o.env.toF32(v);
        if (o.env.flags.inexact) {
            var e = o.chop();
            o.c1 = (bits & 0x7fff_ffff) != (e.toF32(v) & 0x7fff_ffff);
        }
    } else {
        bits = o.env.toF64(v);
        if (o.env.flags.inexact) {
            var e = o.chop();
            o.c1 = (bits & 0x7fff_ffff_ffff_ffff) != (e.toF64(v) & 0x7fff_ffff_ffff_ffff);
        }
    }
    if (!o.okStore()) return o.done();
    if (size == 4) try x.store(a, 4, @truncate(bits)) else try x.store64(a, bits);
    if (do_pop) pop(p);
    o.done();
}

/// FIST (r 2), FISTP (3), and FISTTP (1) to `size` bytes.
fn fist(x: anytype, a: anytype, size: u8, r: u3) !void {
    const p = &x.c.fpu;
    var o = Op.begin(p);
    const v = o.get(0);
    const trunc = r == 1;
    var n: i64 = undefined;
    var bad = false;
    if (unsupported(v) or v.isNan()) {
        bad = true;
    } else {
        const mode = if (trunc) sf.Rounding.min_mag else o.env.rounding;
        var e = o.env;
        n = convert(&e, v, size, mode, trunc);
        if (e.flags.invalid) {
            bad = true;
        } else {
            o.env.flags = e.flags;
            if (e.flags.inexact and !trunc) {
                var t = o.chop();
                o.c1 = n != convert(&t, v, size, .min_mag, true);
            }
        }
    }
    if (bad) {
        o.exc |= IE;
        n = switch (size) {
            2 => std.math.minInt(i16),
            4 => std.math.minInt(i32),
            else => std.math.minInt(i64),
        };
    }
    if (!o.okStore()) return o.done();
    switch (size) {
        2 => try x.store(a, 2, @as(u16, @bitCast(@as(i16, @truncate(n))))),
        4 => try x.store(a, 4, @as(u32, @bitCast(@as(i32, @truncate(n))))),
        else => try x.store64(a, @bitCast(n)),
    }
    if (r != 2) pop(p);
    o.done();
}

// ------------------------------------------------------------ for h86's T1

/// What execMem does for D8, DA, DC, and DE's arithmetic and compares once
/// the operand `v` is loaded (with the note after, as there), for h86's
/// lifted code (jit/x86/helpers.zig), which has done the wait and the load.
/// Nothing in it traps.
pub fn arithMem(x: anytype, op: u3, r: u3, v: u64) void {
    note(x);
    arithMemOp(&x.c.fpu, op, r, v);
}

/// arithMem without the note, which the caller makes.
pub fn arithMemOp(p: *Fpu, op: u3, r: u3, v: u64) void {
    var o = Op.begin(p);
    var b: F80 = undefined;
    var b_den = false;
    switch (op) {
        0 => {
            b_den = isDen32(@truncate(v));
            b = widen32(&o.env, @truncate(v));
        },
        2 => b = sf.fromI32(@bitCast(@as(u32, @truncate(v)))),
        4 => {
            b_den = isDen64(v);
            b = widen64(&o.env, v);
        },
        6 => b = sf.fromI32(@as(i16, @bitCast(@as(u16, @truncate(v))))),
        else => unreachable,
    }
    arithOrCompare(&o, r, 0, b, b_den, false);
}

/// FIST, FISTP, or FISTTP (`r` 2, 3, 1) to `size` bytes, without the store:
/// the integer, and the status word it leaves. Null where nothing would be
/// stored (a stack fault or an unmasked exception), for T0 to run.
pub fn fistPeek(p: *const Fpu, size: u8, r: u3) ?struct { n: i64, sw: u16 } {
    var q = p.*;
    var o = Op.begin(&q);
    const v = o.get(0);
    const trunc = r == 1;
    if (unsupported(v) or v.isNan()) return null;
    const mode = if (trunc) sf.Rounding.min_mag else o.env.rounding;
    var e = o.env;
    const n = convert(&e, v, size, mode, trunc);
    if (e.flags.invalid) return null;
    o.env.flags = e.flags;
    if (e.flags.inexact and !trunc) {
        var t = o.chop();
        o.c1 = n != convert(&t, v, size, .min_mag, true);
    }
    if (!o.okStore() or o.raised() & SF != 0) return null;
    o.done();
    return .{ .n = n, .sw = q.sw };
}

/// v to an integer of `size` bytes; env.flags.invalid if it doesn't fit.
fn convert(env: *sf.Env, v: F80, size: u8, mode: sf.Rounding, trunc: bool) i64 {
    if (size == 8) return if (trunc) env.toI64MinMag(v, true) else env.toI64(v, mode, true);
    const n: i64 = if (trunc) env.toI32MinMag(v, true) else env.toI32(v, mode, true);
    if (size == 2 and !env.flags.invalid and (n < std.math.minInt(i16) or n > std.math.maxInt(i16))) {
        env.flags.invalid = true;
    }
    return n;
}

fn fbld(x: anytype, a: anytype) !void {
    var buf: [10]u8 = undefined;
    try x.loadBytes(a, &buf);
    var n: i64 = 0;
    var k: usize = 9;
    while (k > 0) {
        k -= 1;
        n = n * 100 + @as(i64, buf[k] >> 4) * 10 + (buf[k] & 15);
    }
    var v = sf.fromI64(n);
    if (buf[9] & 0x80 != 0) v = v.neg();
    var o = Op.begin(&x.c.fpu);
    fld(&o, v);
}

fn fbstp(x: anytype, a: anytype) !void {
    const p = &x.c.fpu;
    var o = Op.begin(p);
    const v = o.get(0);
    var buf: [10]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0xc0, 0xff, 0xff };
    var bad = unsupported(v) or v.isNan() or v.isInf();
    if (!bad) {
        var e = o.env;
        const n = e.toI64(v, o.env.rounding, true);
        if (e.flags.invalid or n > 999_999_999_999_999_999 or n < -999_999_999_999_999_999) {
            bad = true;
        } else {
            o.env.flags = e.flags;
            if (e.flags.inexact) {
                var t = o.chop();
                o.c1 = n != t.toI64(v, .min_mag, true);
            }
            var m: u64 = @abs(n);
            for (0..9) |k| {
                const lo: u8 = @intCast(m % 10);
                m /= 10;
                const hi: u8 = @intCast(m % 10);
                m /= 10;
                buf[k] = hi << 4 | lo;
            }
            buf[9] = if (v.sign()) 0x80 else 0;
        }
    }
    if (bad) o.exc |= IE;
    if (!o.okStore()) return o.done();
    try x.storeBytes(a, &buf);
    pop(p);
    o.done();
}

// ------------------------------------------------------------ environment

/// Whether the environment has the 16-bit layout: a 66 prefix, which REX.W
/// overrides in long mode.
fn env16(x: anytype) bool {
    if (comptime isLong(@TypeOf(x))) return x.i.opsize and x.i.rex.w == 0;
    return x.i.opsize;
}

/// The environment's size: 28 bytes, or 14 with a 16-bit operand size.
fn envSize(x: anytype) u32 {
    return if (env16(x)) 14 else 28;
}

fn putEnv(x: anytype, buf: []u8) void {
    const p = &x.c.fpu;
    // In long mode the pointers are addresses, with no selector to keep:
    // FCS and FDS are 0, and only the low 32 bits of each fit.
    const long = comptime isLong(@TypeOf(x));
    const fip: u32 = @truncate(p.fip);
    const fcs: u16 = if (long) 0 else @truncate(p.fip >> 32);
    const fdp: u32 = @truncate(p.fdp);
    const fds: u16 = if (long) 0 else @truncate(p.fdp >> 32);
    if (env16(x)) {
        const w = [7]u16{ p.cw, statusWord(p), tagWord(p), @truncate(fip), fcs, @truncate(fdp), fds };
        for (w, 0..) |v, k| std.mem.writeInt(u16, buf[2 * k ..][0..2], v, .little);
        return;
    }
    const d = [7]u32{
        0xffff_0000 | @as(u32, p.cw),
        0xffff_0000 | @as(u32, statusWord(p)),
        0xffff_0000 | @as(u32, tagWord(p)),
        fip,
        (@as(u32, p.fop & 0x7ff) << 16) | fcs,
        fdp,
        0xffff_0000 | @as(u32, fds),
    };
    for (d, 0..) |v, k| std.mem.writeInt(u32, buf[4 * k ..][0..4], v, .little);
}

fn getEnv(x: anytype, buf: []const u8) void {
    const p = &x.c.fpu;
    var w: [7]u32 = undefined;
    if (env16(x)) {
        for (&w, 0..) |*v, k| v.* = std.mem.readInt(u16, buf[2 * k ..][0..2], .little);
    } else {
        for (&w, 0..) |*v, k| v.* = std.mem.readInt(u32, buf[4 * k ..][0..4], .little);
    }
    p.cw = (@as(u16, @truncate(w[0])) & 0x1f3f) | 0x40;
    const sw: u16 = @truncate(w[1]);
    p.top = @truncate(sw >> 11);
    p.sw = sw & ~@as(u16, 0x3800);
    p.tag = abridge(@truncate(w[2]));
    const long = comptime isLong(@TypeOf(x));
    p.fip = if (long) w[3] else (@as(u64, w[4] & 0xffff) << 32) | w[3];
    p.fop = if (env16(x)) 0 else @truncate((w[4] >> 16) & 0x7ff);
    p.fdp = if (long) w[5] else (@as(u64, w[6] & 0xffff) << 32) | w[5];
    summarize(p);
}

fn fstenv(x: anytype, a: anytype) !void {
    var buf: [28]u8 = undefined;
    const n = envSize(x);
    putEnv(x, buf[0..n]);
    try x.storeBytes(a, buf[0..n]);
    x.c.fpu.cw |= exc_mask;
    summarize(&x.c.fpu);
}

fn fldenv(x: anytype, a: anytype) !void {
    var buf: [28]u8 = undefined;
    const n = envSize(x);
    try x.loadBytes(a, buf[0..n]);
    getEnv(x, buf[0..n]);
}

fn fsave(x: anytype, a: anytype) !void {
    const p = &x.c.fpu;
    var buf: [108]u8 = undefined;
    const n = envSize(x);
    putEnv(x, buf[0..n]);
    for (0..8) |k| std.mem.writeInt(u80, buf[n + 10 * k ..][0..10], st(p, @intCast(k)).toBits(), .little);
    try x.storeBytes(a, buf[0 .. n + 80]);
    init(p);
}

fn frstor(x: anytype, a: anytype) !void {
    const p = &x.c.fpu;
    var buf: [108]u8 = undefined;
    const n = envSize(x);
    try x.loadBytes(a, buf[0 .. n + 80]);
    getEnv(x, buf[0..n]);
    for (0..8) |k| p.st[phys(p, @intCast(k))] = F80.fromBits(std.mem.readInt(u80, buf[n + 10 * k ..][0..10], .little));
}

// ------------------------------------------------------------ register forms

/// D8 and DC's (and DE's popping) eight: FADD, FMUL, FCOM, FCOMP, FSUB,
/// FSUBR, FDIV, FDIVR, between ST(0) and `b`, the result to ST(dst).
fn arithOrCompare(o: *Op, r: u3, dst: u3, b: F80, b_den: bool, do_pop: bool) void {
    const p = o.p;
    const a = o.get(0);
    if (r == 2 or r == 3) {
        const ord = if (o.raised() & SF != 0) Order.un else compare(o, a, b, b_den, false);
        // The condition codes even for an unmasked exception; no pop.
        if (r == 3 and o.ok()) pop(p);
        return o.doneCC(ccOf(ord));
    }
    const res = if (o.raised() & SF != 0) indefinite else o.arith(r, a, b, b_den);
    if (!o.ok()) return o.done();
    setSt(p, dst, res);
    if (do_pop) pop(p);
    o.done();
}

fn execReg(x: anytype, op: u3, r: u3, rm: u3) !void {
    const p = &x.c.fpu;
    // The non-waiting controls, and the undefined encodings.
    switch (op) {
        1 => switch (r) {
            2 => if (rm != 0) return x.exc(cpu.vec_ud),
            4 => if (rm == 2 or rm == 3 or rm == 6 or rm == 7) return x.exc(cpu.vec_ud),
            5 => if (rm == 7) return x.exc(cpu.vec_ud),
            else => {},
        },
        2 => if (r >= 4 and !(r == 5 and rm == 1)) return x.exc(cpu.vec_ud),
        3 => switch (r) {
            4 => switch (rm) {
                0, 1, 4 => return, // FNENI, FNDISI, FNSETPM: nothing on a 387 or later
                2 => {
                    p.sw &= ~@as(u16, 0x80ff);
                    return;
                },
                3 => return init(p),
                else => return x.exc(cpu.vec_ud),
            },
            7 => return x.exc(cpu.vec_ud),
            else => {},
        },
        5 => if (r == 6 or r == 7) return x.exc(cpu.vec_ud),
        6 => if (r == 3 and rm != 1) return x.exc(cpu.vec_ud),
        7 => switch (r) {
            4 => {
                if (rm != 0) return x.exc(cpu.vec_ud);
                x.writeReg(0, 2, statusWord(p));
                return;
            },
            7 => return x.exc(cpu.vec_ud),
            else => {},
        },
        else => {},
    }
    try wait(x);
    note(x);
    var o = Op.begin(p);
    switch (op) {
        0 => {
            const b = o.get(rm);
            return arithOrCompare(&o, r, 0, b, false, false);
        },
        4, 6 => {
            const b = o.get(rm);
            // DC and DE: ST(i) = ST(i) op ST(0), where r 4 is ST(0) - ST(i)
            // as in D8 (FSUBR's mnemonic), 5 ST(i) - ST(0), and so on.
            // DC D0 is FCOM again, DC D8 and DE D0 FCOMP (and DE D8 FCOMPP).
            if (op == 6 and r == 3) return fcompp(&o, false);
            if (r == 2 or r == 3) return arithOrCompare(&o, if (op == 6) 3 else r, 0, b, false, false);
            return arithOrCompare(&o, r, rm, b, false, op == 6);
        },
        1 => return d9(x, &o, r, rm),
        2 => {
            if (r == 5) return fcompp(&o, true);
            return fcmov(x, &o, r, rm, false);
        },
        3 => switch (r) {
            0, 1, 2, 3 => return fcmov(x, &o, r, rm, true),
            5, 6 => return fcomi(x, &o, rm, r == 5, false),
            else => unreachable,
        },
        5 => switch (r) {
            0 => {
                p.tag &= ~(@as(u8, 1) << phys(p, rm));
                return o.done();
            },
            1 => return fxch(&o, rm),
            2, 3 => return fstReg(&o, rm, r == 3),
            4, 5 => {
                const a = o.get(0);
                const b = o.get(rm);
                const ord = if (o.raised() & SF != 0) Order.un else compare(&o, a, b, false, true);
                if (r == 5 and o.ok()) pop(p);
                return o.doneCC(ccOf(ord));
            },
            else => unreachable,
        },
        7 => switch (r) {
            0 => {
                p.tag &= ~(@as(u8, 1) << phys(p, rm));
                pop(p);
                return o.done();
            },
            1 => return fxch(&o, rm),
            2, 3 => return fstReg(&o, rm, true),
            5, 6 => return fcomi(x, &o, rm, r == 5, true),
            else => unreachable,
        },
    }
}

/// FCOMPP (or, `quiet`, FUCOMPP).
fn fcompp(o: *Op, quiet: bool) void {
    const a = o.get(0);
    const b = o.get(1);
    const ord = if (o.raised() & SF != 0) Order.un else compare(o, a, b, false, quiet);
    if (o.ok()) {
        pop(o.p);
        pop(o.p);
    }
    o.doneCC(ccOf(ord));
}

fn fcmov(x: anytype, o: *Op, r: u3, rm: u3, negate: bool) void {
    o.keep_c1 = true;
    const fl = &x.c.fl;
    var c = switch (r) {
        0 => fl.cf(),
        1 => fl.zf(),
        2 => fl.cf() or fl.zf(),
        3 => fl.pf(),
        else => unreachable,
    };
    if (negate) c = !c;
    if (isEmpty(o.p, 0) or isEmpty(o.p, rm)) {
        o.underflow();
        if (o.ok()) setSt(o.p, 0, indefinite);
        return o.done();
    }
    if (c) setSt(o.p, 0, st(o.p, rm));
    o.done();
}

fn fcomi(x: anytype, o: *Op, rm: u3, quiet: bool, do_pop: bool) void {
    o.keep_c1 = true;
    const a = o.get(0);
    const b = o.get(rm);
    const ord = if (o.raised() & SF != 0) Order.un else compare(o, a, b, false, quiet);
    const v: u32 = switch (ord) {
        .gt => 0,
        .lt => flags.CF,
        .eq => flags.ZF,
        .un => flags.ZF | flags.PF | flags.CF,
    };
    x.c.fl.setMasked(flags.arith, v);
    if (do_pop and o.ok()) pop(o.p);
    o.done();
}

fn fxch(o: *Op, rm: u3) void {
    var a = st(o.p, 0);
    var b = st(o.p, rm);
    if (isEmpty(o.p, 0) or isEmpty(o.p, rm)) {
        o.underflow();
        if (!o.ok()) return o.done();
        if (isEmpty(o.p, 0)) a = indefinite;
        if (isEmpty(o.p, rm)) b = indefinite;
    }
    setSt(o.p, 0, b);
    setSt(o.p, rm, a);
    o.done();
}

/// FST and FSTP ST(i).
fn fstReg(o: *Op, rm: u3, do_pop: bool) void {
    const v = o.get(0);
    if (!o.ok()) return o.done();
    setSt(o.p, rm, v);
    if (do_pop) pop(o.p);
    o.done();
}

/// The constants' significands to 64 bits in nearest, and whether
/// rounding down or toward zero takes one off (the bits beyond are under
/// a half) or rounding up adds one.
const Const = struct { e: u16, sig: u64, down: bool = false, up: bool = false };

const constants = [7]Const{
    .{ .e = 0x3fff, .sig = 0x8000_0000_0000_0000 }, // FLD1
    .{ .e = 0x4000, .sig = 0xd49a_784b_cd1b_8afe, .up = true }, // FLDL2T
    .{ .e = 0x3fff, .sig = 0xb8aa_3b29_5c17_f0bc, .down = true }, // FLDL2E
    .{ .e = 0x4000, .sig = 0xc90f_daa2_2168_c235, .down = true }, // FLDPI
    .{ .e = 0x3ffd, .sig = 0x9a20_9a84_fbcf_f799, .down = true }, // FLDLG2
    .{ .e = 0x3ffe, .sig = 0xb172_17f7_d1cf_79ac, .down = true }, // FLDLN2
    .{ .e = 0, .sig = 0 }, // FLDZ
};

fn d9(x: anytype, o: *Op, r: u3, rm: u3) void {
    _ = x;
    const p = o.p;
    switch (r) {
        0 => {
            // FLD ST(i): read before the push.
            const v = o.get(rm);
            return fld(o, v);
        },
        1 => return fxch(o, rm),
        2 => { // FNOP
            o.keep_c1 = true;
            return o.done();
        },
        3 => {
            // D9 D8+i, FSTPNCE: FSTP, but an empty ST(0) is no underflow,
            // just a pop that stores nothing.
            if (!isEmpty(p, 0)) setSt(p, rm, st(p, 0));
            pop(p);
            return o.done();
        },
        4 => switch (rm) {
            0, 1 => {
                const v = o.get(0);
                if (!o.ok()) return o.done();
                setSt(p, 0, if (o.raised() & SF != 0) v else if (rm == 0) v.neg() else v.abs());
                return o.done();
            },
            4 => {
                const a = o.get(0);
                const ord = if (o.raised() & SF != 0) Order.un else compare(o, a, F80.zero, false, false);
                return o.doneCC(ccOf(ord));
            },
            5 => return o.doneCC(fxam(p)),
            else => unreachable,
        },
        5 => {
            const c = constants[rm];
            var sig = c.sig;
            switch (o.env.rounding) {
                .min, .min_mag => if (c.down) {
                    sig -= 1;
                },
                .max => if (c.up) {
                    sig += 1;
                },
                else => {},
            }
            return fld(o, .{ .sign_exp = c.e, .signif = sig });
        },
        6 => switch (rm) {
            0 => return unary(o, .f2xm1),
            1 => return binaryPop(o, .fyl2x),
            2 => return pushing(o, .fptan),
            3 => return binaryPop(o, .fpatan),
            4 => return pushing(o, .fxtract),
            5 => return fprem(o, true),
            6 => {
                p.top -%= 1;
                return o.done();
            },
            7 => {
                p.top +%= 1;
                return o.done();
            },
        },
        7 => switch (rm) {
            0 => return fprem(o, false),
            1 => return binaryPop(o, .fyl2xp1),
            2 => return unary(o, .fsqrt),
            3 => return pushing(o, .fsincos),
            4 => return unary(o, .frndint),
            5 => return fscale(o),
            6 => return unary(o, .fsin),
            7 => return unary(o, .fcos),
        },
    }
}

/// FXAM's class of ST(0) in C3, C2, and C0, with its sign in C1.
fn fxam(p: *const Fpu) u16 {
    const v = st(p, 0);
    const sign: u16 = if (v.sign()) C1 else 0;
    if (isEmpty(p, 0)) return sign | C3 | C0;
    if (unsupported(v)) return sign;
    const e = v.exp();
    if (e == 0x7fff) return sign | (if (v.signif << 1 == 0) C2 | C0 else C0);
    if (e == 0) return sign | (if (v.signif == 0) C3 else C3 | C2);
    return sign | C2;
}

/// 2^63: FSIN, FCOS, FSINCOS, and FPTAN refuse anything this large, and
/// set C2.
fn tooLarge(v: F80) bool {
    return v.exp() >= 0x3fff + 63;
}

const Unary = enum { f2xm1, fsqrt, frndint, fsin, fcos };

fn unary(o: *Op, k: Unary) void {
    const p = o.p;
    const a = o.get(0);
    var res: F80 = undefined;
    if (o.raised() & SF != 0) {
        res = indefinite;
    } else if (unsupported(a)) {
        res = o.invalid();
    } else if (a.isNan()) {
        res = o.env.add(a, a);
    } else if ((k == .fsin or k == .fcos) and tooLarge(a) and !a.isInf()) {
        // Out of range: C2, and ST(0) as it was.
        o.p.sw |= C2;
        return o.done();
    } else {
        // An invalid square root sees no denormal.
        if (a.isDenormal() and !(k == .fsqrt and a.sign())) o.exc |= DE;
        res = switch (k) {
            .fsqrt => o.arithSqrt(a),
            .frndint => blk: {
                const v = o.env.roundToInt(a, o.env.rounding, true);
                // Rounded up if the magnitude grew.
                if (o.env.flags.inexact) {
                    var e = o.chop();
                    o.roundedUp(v, e.roundToInt(a, .min_mag, false));
                }
                break :blk v;
            },
            .f2xm1 => if (!a.isInf() and a.exp() >= 0x3fff and !(a.exp() == 0x3fff and a.signif == 1 << 63)) blk: {
                // Beyond [-1, 1]: the x87 leaves ST(0) and sets PE.
                o.env.flags.inexact = true;
                break :blk a;
            } else if (a.isInf())
                (if (a.sign()) F80.one.neg() else a)
            else if (a.signif == 0) a else o.roundScaled(xm.exp2m1(xm.toF128(a))),
            .fsin => if (a.isInf()) o.invalid() else if (a.signif == 0) a else o.roundScaled(xm.sin(a)),
            .fcos => if (a.isInf()) o.invalid() else if (a.signif == 0) F80.one else o.roundScaled(xm.cos(a)),
        };
    }
    // FSIN and FCOS clear C2 and leave C3 and C0.
    if (k == .fsin or k == .fcos) o.p.sw &= ~C2;
    if (!o.ok()) return o.done();
    setSt(p, 0, res);
    o.done();
}

const Binary = enum { fyl2x, fyl2xp1, fpatan };

/// ST(1) = f(ST(1), ST(0)), then a pop.
fn binaryPop(o: *Op, k: Binary) void {
    const p = o.p;
    const a = o.get(0);
    const b = o.get(1);
    var res: F80 = undefined;
    if (o.raised() & SF != 0) {
        res = indefinite;
    } else if (unsupported(a) or unsupported(b)) {
        res = o.invalid();
    } else if (a.isNan() or b.isNan()) {
        res = o.env.add(b, a);
    } else {
        // FYL2X of a negative x is invalid before it looks further.
        const neg_log = k == .fyl2x and a.sign() and a.signif != 0;
        if ((a.isDenormal() or b.isDenormal()) and !neg_log) o.exc |= DE;
        res = switch (k) {
            .fpatan => fpatan(o, b, a),
            .fyl2x => fyl2x(o, b, a, false),
            .fyl2xp1 => fyl2x(o, b, a, true),
        };
    }
    if (!o.ok()) return o.done();
    setSt(p, 1, res);
    pop(p);
    o.done();
}

fn signedInf(sign: bool) F80 {
    return if (sign) F80.inf.neg() else F80.inf;
}

fn signedZero(sign: bool) F80 {
    return if (sign) F80.zero.neg() else F80.zero;
}

/// atan(y / x) in the quadrant of (x, y).
fn fpatan(o: *Op, y: F80, x: F80) F80 {
    const pi: f128 = std.math.pi;
    const yi = y.isInf();
    const xi = x.isInf();
    var v: f128 = undefined;
    if (yi and xi) {
        v = if (x.sign()) 3 * pi / 4 else pi / 4;
    } else if (yi) {
        v = pi / 2;
    } else if (xi) {
        if (!x.sign()) return signedZero(y.sign());
        v = pi;
    } else if (y.signif == 0) {
        if (!x.sign()) return y;
        v = pi;
    } else if (x.signif == 0) {
        v = pi / 2;
    } else {
        return o.roundScaled(xm.atan2(xm.toF128(y), xm.toF128(x)));
    }
    return o.round(if (y.sign()) -v else v);
}

/// y * log2(x), or y * log2(1 + x) for FYL2XP1.
fn fyl2x(o: *Op, y: F80, x: F80, p1: bool) F80 {
    if (p1) {
        // The x87 defines it for |x| < 1 - sqrt(2)/2; zeros are exact.
        if (x.signif == 0) {
            if (y.isInf()) return o.invalid();
            return signedZero(x.sign() != y.sign());
        }
        if (x.isInf()) {
            if (x.sign()) return o.invalid();
            if (y.signif == 0) return o.invalid();
            return signedInf(y.sign());
        }
        const xf = xm.toF128(x);
        if (xf <= -1) {
            if (xf < -1) return o.invalid();
            // log2(0): -inf.
            if (y.signif == 0) return o.invalid();
            if (y.isInf()) return signedInf(!y.sign());
            o.env.flags.infinite = true;
            return signedInf(!y.sign());
        }
        if (y.isInf()) return signedInf(y.sign() != x.sign());
        if (y.signif == 0) return signedZero(y.sign() != x.sign());
        return mulLog(o, xm.toF128(y), xm.log2p1(xf));
    }
    if (x.sign() and x.signif != 0) return o.invalid();
    if (x.signif == 0) {
        if (y.signif == 0 and !y.isInf()) return o.invalid();
        if (!y.isInf()) o.env.flags.infinite = true;
        return signedInf(!y.sign());
    }
    if (x.isInf()) {
        if (y.signif == 0) return o.invalid();
        return signedInf(y.sign());
    }
    const one = x.sign_exp == 0x3fff and x.signif == 1 << 63;
    if (one) {
        if (y.isInf()) return o.invalid();
        return signedZero(y.sign());
    }
    const below = x.exp() < 0x3fff;
    if (y.isInf()) return signedInf(y.sign() != below);
    if (y.signif == 0) return signedZero(y.sign() != below);
    return mulLog(o, xm.toF128(y), .{ .v = xm.log2(xm.toF128(x)) });
}

/// y * l, rounded once.
fn mulLog(o: *Op, y: f128, l: xm.Scaled) F80 {
    return o.roundScaled(xm.mul(.{ .v = y }, l));
}

const Pushing = enum { fptan, fsincos, fxtract };

/// FPTAN, FSINCOS, and FXTRACT: ST(0) replaced and one more pushed.
fn pushing(o: *Op, k: Pushing) void {
    const p = o.p;
    if (isEmpty(p, 0) or !isEmpty(p, 7)) {
        if (isEmpty(p, 0)) o.underflow() else o.overflow();
        if (o.ok()) {
            setSt(p, 0, indefinite);
            push(p, indefinite);
        }
        if (k != .fxtract) p.sw &= ~C2;
        return o.done();
    }
    const a = st(p, 0);
    var lo: F80 = undefined; // what stays in ST(1)
    var hi: F80 = undefined; // what's pushed
    if (unsupported(a)) {
        lo = o.invalid();
        hi = lo;
    } else if (a.isNan()) {
        lo = o.env.add(a, a);
        hi = lo;
    } else if (k != .fxtract and tooLarge(a) and !a.isInf()) {
        p.sw |= C2;
        return o.done();
    } else {
        if (a.isDenormal()) o.exc |= DE;
        switch (k) {
            .fptan => {
                if (a.isInf()) {
                    lo = o.invalid();
                    hi = lo;
                } else {
                    lo = if (a.signif == 0) a else o.roundScaled(xm.tan(a));
                    hi = F80.one;
                }
            },
            .fsincos => {
                if (a.isInf()) {
                    lo = o.invalid();
                    hi = lo;
                } else if (a.signif == 0) {
                    lo = a;
                    hi = F80.one;
                } else {
                    // C1 reflects the last rounding, the cosine's.
                    lo = o.roundScaled(xm.sin(a));
                    hi = o.roundScaled(xm.cos(a));
                }
            },
            .fxtract => {
                if (a.isInf()) {
                    lo = F80.inf;
                    hi = a;
                } else if (a.signif == 0) {
                    o.env.flags.infinite = true;
                    lo = F80.inf.neg();
                    hi = a;
                } else {
                    var e: i32 = a.exp();
                    if (e == 0) e = 1;
                    const z: u6 = @intCast(@clz(a.signif));
                    lo = sf.fromI32(e - 0x3fff - z);
                    hi = .{ .sign_exp = (a.sign_exp & 0x8000) | 0x3fff, .signif = a.signif << z };
                }
            },
        }
    }
    // FPTAN and FSINCOS clear C2 and leave C3 and C0.
    if (k != .fxtract) p.sw &= ~C2;
    if (!o.ok()) return o.done();
    setSt(p, 0, lo);
    push(p, hi);
    o.done();
}

fn fprem(o: *Op, nearest: bool) void {
    const p = o.p;
    const a = o.get(0);
    const b = o.get(1);
    var res: F80 = undefined;
    var cc: u16 = 0;
    var computed = false;
    if (o.raised() & SF != 0) {
        res = indefinite;
    } else if (unsupported(a) or unsupported(b)) {
        res = o.invalid();
    } else if (a.isNan() or b.isNan()) {
        res = o.env.add(a, b);
    } else if (a.isInf() or b.signif == 0) {
        res = o.invalid();
    } else {
        if (a.isDenormal() or b.isDenormal()) o.exc |= DE;
        if (a.signif == 0 or b.isInf()) {
            computed = true;
            res = a;
        } else {
            const r = xm.remainder(a, b, nearest);
            computed = true;
            res = r.r;
            if (r.partial) {
                cc = C2;
            } else {
                if (r.q & 4 != 0) cc |= C0;
                if (r.q & 2 != 0) cc |= C3;
                if (r.q & 1 != 0) cc |= C1;
            }
        }
    }
    // A pseudo-denormal (exponent 0, integer bit set) that comes back
    // unchanged comes back as the hardware gives it: the same value, with
    // the smallest normal exponent.
    if (computed and res.sign_exp & 0x7fff == 0 and res.signif >> 63 != 0) res.sign_exp |= 1;
    // Special operands leave C3 and C0 as they were.
    if (!computed or !o.ok()) p.sw &= ~C2;
    if (!o.ok()) return o.done();
    setSt(p, 0, res);
    if (!computed) return o.done();
    o.doneCC(cc);
}

fn fscale(o: *Op) void {
    const p = o.p;
    const a = o.get(0);
    const b = o.get(1);
    var res: F80 = undefined;
    if (o.raised() & SF != 0) {
        res = indefinite;
    } else if (unsupported(a) or unsupported(b)) {
        res = o.invalid();
    } else if (a.isNan() or b.isNan()) {
        res = o.env.add(a, b);
    } else if (b.isInf()) {
        if (a.isDenormal()) o.exc |= DE;
        if (!b.sign()) {
            res = if (a.signif == 0) o.invalid() else signedInf(a.sign());
        } else {
            res = if (a.isInf()) o.invalid() else signedZero(a.sign());
        }
    } else {
        if (a.isDenormal() or b.isDenormal()) o.exc |= DE;
        if (a.isInf() or a.signif == 0) {
            res = a;
        } else {
            var t = o.env;
            const n: i32 = std.math.clamp(t.toI32MinMag(b, false), -(1 << 20), 1 << 20);
            res = scale(o, a, if (b.exp() >= 0x3fff + 31) (if (b.sign()) -(1 << 20) else 1 << 20) else n);
        }
    }
    if (!o.ok()) return o.done();
    setSt(p, 0, res);
    o.done();
}

/// a * 2^n, rounding at full precision only if it leaves the normal range.
fn scale(o: *Op, a: F80, n: i32) F80 {
    var e: i32 = a.exp();
    if (e == 0) e = 1;
    const z: u6 = @intCast(@clz(a.signif));
    const sig = a.signif << z;
    const t = e - z + n;
    const s = a.sign_exp & 0x8000;
    if (t >= 1 and t <= 0x7ffe) return .{ .sign_exp = s | @as(u16, @intCast(t)), .signif = sig };
    const saved = o.env.precision;
    o.env.precision = .p80;
    defer o.env.precision = saved;
    if (t < 1) {
        const m: F80 = .{ .sign_exp = s | @as(u16, @intCast(@max(t + 16000, 1))), .signif = sig };
        const r = o.env.mul(m, .{ .sign_exp = 0x3fff - 16000, .signif = 1 << 63 });
        if (o.env.flags.inexact) {
            var c = o.chop();
            o.roundedUp(r, c.mul(m, .{ .sign_exp = 0x3fff - 16000, .signif = 1 << 63 }));
        }
        return r;
    }
    const m: F80 = .{ .sign_exp = s | @as(u16, @intCast(@min(t - 16000, 0x7ffe))), .signif = sig };
    const r = o.env.mul(m, .{ .sign_exp = 0x3fff + 16000, .signif = 1 << 63 });
    if (o.env.flags.inexact) {
        var c = o.chop();
        o.roundedUp(r, c.mul(m, .{ .sign_exp = 0x3fff + 16000, .signif = 1 << 63 }));
    }
    return r;
}

// ------------------------------------------------------------ tests

const testing = std.testing;

fn f64of(v: F80) f64 {
    var env: sf.Env = .{};
    return @bitCast(env.toF64(v));
}

fn ext(v: f64) F80 {
    var env: sf.Env = .{};
    return env.fromF64(@bitCast(v));
}

test "the stack, a sum, and an underflow" {
    var p: Fpu = .{};
    var o = Op.begin(&p);
    fld(&o, ext(1.5));
    o = Op.begin(&p);
    fld(&o, ext(2.25));
    try testing.expectEqual(@as(u3, 6), p.top);
    o = Op.begin(&p);
    arithOrCompare(&o, 0, 1, o.get(1), false, true); // FADDP
    try testing.expectEqual(@as(f64, 3.75), f64of(st(&p, 0)));
    try testing.expectEqual(@as(u3, 7), p.top);
    // Empty ST(1): a masked underflow gives the indefinite NaN.
    o = Op.begin(&p);
    arithOrCompare(&o, 0, 0, o.get(1), false, false);
    try testing.expect(p.sw & (IE | SF) == IE | SF);
    try testing.expect(st(&p, 0).isNan());
    try testing.expect(p.sw & ES == 0);
}

test "an unmasked exception is pending until the next waiting instruction" {
    var p: Fpu = .{ .cw = 0x037b }; // ZE unmasked
    var o = Op.begin(&p);
    fld(&o, ext(0));
    o = Op.begin(&p);
    fld(&o, ext(1));
    o = Op.begin(&p);
    arithOrCompare(&o, 6, 0, o.get(1), false, false); // 1 / 0
    try testing.expect(p.sw & (ZE | ES | B) == ZE | ES | B);
    // The destination stays.
    try testing.expectEqual(@as(f64, 1), f64of(st(&p, 0)));
}

test "FXAM, FPREM's condition codes, and FXTRACT" {
    var p: Fpu = .{};
    try testing.expectEqual(C3 | C0, fxam(&p));
    var o = Op.begin(&p);
    fld(&o, ext(3));
    o = Op.begin(&p);
    fld(&o, ext(-7));
    o = Op.begin(&p);
    fprem(&o, false); // -7 rem 3 = -1, quotient 2
    try testing.expectEqual(@as(f64, -1), f64of(st(&p, 0)));
    try testing.expectEqual(C3, p.sw & (C0 | C1 | C2 | C3));
    o = Op.begin(&p);
    pushing(&o, .fxtract);
    try testing.expectEqual(@as(f64, -1), f64of(st(&p, 0)));
    try testing.expectEqual(@as(f64, 0), f64of(st(&p, 1)));
}

const TestX64 = @import("sse.zig").TestX64;
const decode = @import("decode.zig");

/// A long-mode D8-DF instruction for the tests, with REX's bits.
fn inst64(opcode: u8, rex: u4, modrm: u8) decode.Inst64 {
    return .{ .op = .x87, .entry = 0, .opcode = opcode, .len = 3, .size = 4, .rex = decode.Rex.of(0x40 | @as(u8, rex)), .modrm = modrm };
}

test "long mode: loads, stores, and 64-bit pointers" {
    const base = 0x7fff_0000_0000;
    var c: cpu.Cpu64 = .{ .rip = base + 0x40 };
    var mem: [128]u8 align(16) = @splat(0);
    std.mem.writeInt(u64, mem[0x80 - 0x30 ..][0..8], @bitCast(@as(f64, 2.5)), .little);
    // fldl 0x...(%rip), 3 bytes + disp at 0x40: the operand at 0x50.
    var i = inst64(0xdd, 0, 0x05);
    i.mem = true;
    i.rip_rel = true;
    i.len = 7;
    i.disp = 0x50 - 0x47;
    try testing.expectEqual(null, TestX64.run(&c, &mem, base, i));
    try testing.expectEqual(@as(f64, 2.5), f64of(st(&c.fpu, 0)));
    // FIP is the whole RIP, FDP the whole address.
    try testing.expectEqual(@as(u64, base + 0x40), c.fpu.fip);
    try testing.expectEqual(@as(u64, base + 0x50), c.fpu.fdp);
    // fld %st(0) with REX.B: ST(i) ignores REX.
    try testing.expectEqual(null, TestX64.run(&c, &mem, base, inst64(0xd9, 0b0001, 0xc0)));
    // faddp; fistpll (%r9) at 64 bits.
    try testing.expectEqual(null, TestX64.run(&c, &mem, base, inst64(0xde, 0, 0xc1)));
    c.r[9] = base + 8;
    i = inst64(0xdf, 0b0001, 0x01 | 7 << 3);
    i.mem = true;
    i.base = 9;
    try testing.expectEqual(null, TestX64.run(&c, &mem, base, i));
    try testing.expectEqual(@as(i64, 5), std.mem.readInt(i64, mem[8..16], .little));
    // fnstsw %ax writes AX, and leaves the rest of RAX.
    c.r[0] = 0xffff_ffff_ffff_ffff;
    try testing.expectEqual(null, TestX64.run(&c, &mem, base, inst64(0xdf, 0, 0xe0)));
    try testing.expectEqual(@as(u64, 0xffff_ffff_ffff_0000) | statusWord(&c.fpu), c.r[0]);
    // fnstenv (%r9): 32-bit offsets, with FCS and FDS 0.
    i = inst64(0xd9, 0b0001, 0x01 | 6 << 3);
    i.mem = true;
    i.base = 9;
    try testing.expectEqual(null, TestX64.run(&c, &mem, base, i));
    try testing.expectEqual(@as(u32, @truncate(c.fpu.fip)), std.mem.readInt(u32, mem[8 + 12 ..][0..4], .little));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, mem[8 + 16 ..][0..4], .little) & 0xffff);
    try testing.expectEqual(@as(u32, 0xffff_0000), std.mem.readInt(u32, mem[8 + 24 ..][0..4], .little));
}

test "long mode: REX.W overrides 66 on FNSTENV" {
    const base = 0x10000;
    var c: cpu.Cpu64 = .{ .rip = base };
    var mem: [64]u8 align(16) = @splat(0);
    // 66 48 d9 33: fnstenv (%rbx), the 28-byte layout.
    var i = inst64(0xd9, 0b1000, 0x03 | 6 << 3);
    i.opsize = true;
    i.mem = true;
    i.base = 3;
    c.r[3] = base;
    try testing.expectEqual(null, TestX64.run(&c, &mem, base, i));
    try testing.expectEqual(@as(u32, 0xffff_037f), std.mem.readInt(u32, mem[0..4], .little));
    // Without REX.W it is the 14-byte one.
    @memset(&mem, 0);
    c.fpu.cw = 0x37f;
    i.rex.w = 0;
    try testing.expectEqual(null, TestX64.run(&c, &mem, base, i));
    try testing.expectEqual(@as(u32, 0x0000_037f), std.mem.readInt(u32, mem[0..4], .little));
}

test "FPREM1 gives back a pseudo-denormal with the smallest normal exponent" {
    var p: Fpu = .{};
    var o = Op.begin(&p);
    fld(&o, ext(3));
    o = Op.begin(&p);
    fld(&o, .{ .sign_exp = 0, .signif = 0xc394_da7c_f98b_ecd2 });
    o = Op.begin(&p);
    fprem(&o, true);
    try testing.expectEqual(F80{ .sign_exp = 1, .signif = 0xc394_da7c_f98b_ecd2 }, st(&p, 0));
}
