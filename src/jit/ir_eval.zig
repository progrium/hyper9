//! The IR's reference semantics: a plain interpreter of a region.
//!
//! It's the definition every emitter is tested against (random IR, run
//! natively and here, compared), and what a lifter is tested with before
//! any emitter exists (lift, run here, compare with T0).
//!
//! It's also every emitter's fallback: an emitter that hasn't lowered a
//! pure operation yet calls `evalOpC` for it, so adding an op never breaks
//! an emitter.
//!
//! Values hold the type's bits, zero-extended: i1 is 0 or 1, a flags
//! value is the guest's packed flags (see ir.zig), and a v128 is a u128.
//! The FP and vector ops (`Op.isExt`) have their own fallback, `evalExtC`.

const std = @import("std");
const ir = @import("ir.zig");
const ctx_mod = @import("ctx.zig");
const mem = @import("../interp/mem.zig");
const softfloat = @import("../interp/softfloat.zig");
const sf = softfloat;
const Ctx = ctx_mod.Ctx;
const Exit = ctx_mod.Exit;
const Op = ir.Op;
const Type = ir.Type;

fn msb(v: u64, bits: u32) u1 {
    return @truncate(v >> @intCast(bits - 1));
}

fn sx(v: u64, bits: u32) i64 {
    if (bits >= 64) return @bitCast(v);
    const s: u6 = @intCast(64 - bits);
    return @as(i64, @bitCast(v << s)) >> s;
}

/// arm64's AddWithCarry: the result and NZCV (in bits 31..28).
fn addWithCarry(a: u64, b: u64, cin: u1, bits: u32) struct { u64, u64 } {
    const m = maskOf(bits);
    const wide: u128 = @as(u128, a & m) + @as(u128, b & m) + cin;
    const res: u64 = @as(u64, @truncate(wide)) & m;
    const n = msb(res, bits);
    const z: u1 = @intFromBool(res == 0);
    const c: u1 = @intFromBool(wide > m);
    const v = msb((a ^ res) & (b ^ res), bits);
    return .{ res, (@as(u64, n) << 31) | (@as(u64, z) << 30) | (@as(u64, c) << 29) | (@as(u64, v) << 28) };
}

fn maskOf(bits: u32) u64 {
    return if (bits >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(bits)) - 1;
}

pub fn nzcvCond(f: u64, cc: u64) bool {
    const n = (f >> 31) & 1 == 1;
    const z = (f >> 30) & 1 == 1;
    const c = (f >> 29) & 1 == 1;
    const v = (f >> 28) & 1 == 1;
    const r = switch (cc >> 1) {
        0 => z,
        1 => c,
        2 => n,
        3 => v,
        4 => c and !z,
        5 => n == v,
        6 => !z and n == v,
        else => true,
    };
    // The odd codes negate, except 15 (NV), which is always true too.
    return if (cc & 1 == 1 and cc != 15) !r else r;
}

// EFLAGS bits.
pub const CF: u64 = 1 << 0;
pub const PF: u64 = 1 << 2;
pub const AF: u64 = 1 << 4;
pub const ZF: u64 = 1 << 6;
pub const SF: u64 = 1 << 7;
pub const OF: u64 = 1 << 11;
pub const eflags_mask = CF | PF | AF | ZF | SF | OF;

fn szp(res: u64, bits: u32) u64 {
    var f: u64 = 0;
    if (res == 0) f |= ZF;
    if (msb(res, bits) == 1) f |= SF;
    if (@popCount(@as(u8, @truncate(res))) % 2 == 0) f |= PF;
    return f;
}

fn eflagsAdd(a: u64, b: u64, cin: u1, bits: u32) u64 {
    const m = maskOf(bits);
    const wide: u128 = @as(u128, a) + b + cin;
    const res = @as(u64, @truncate(wide)) & m;
    var f = szp(res, bits) | ((a ^ b ^ res) & AF);
    if (wide > m) f |= CF;
    if (msb((a ^ res) & (b ^ res), bits) == 1) f |= OF;
    return f;
}

fn eflagsSub(a: u64, b: u64, cin: u1, bits: u32) u64 {
    const m = maskOf(bits);
    const res = (a -% b -% cin) & m;
    var f = szp(res, bits) | ((a ^ b ^ res) & AF);
    if (@as(u128, a) < @as(u128, b) + cin) f |= CF;
    if (msb((a ^ b) & (a ^ res), bits) == 1) f |= OF;
    return f;
}

pub fn eflagsCond(f: u64, cc: u64) bool {
    const of = f & OF != 0;
    const sign = f & SF != 0;
    const r = switch (cc >> 1) {
        0 => of,
        1 => f & CF != 0,
        2 => f & ZF != 0,
        3 => f & (CF | ZF) != 0,
        4 => sign,
        5 => f & PF != 0,
        6 => sign != of,
        else => f & ZF != 0 or sign != of,
    };
    return if (cc & 1 == 1) !r else r;
}

/// A pure operation's result. `ta` is operand a's type, which sets the
/// width of flags operations and extensions.
pub fn evalPure(op: Op, ty: Type, ta: Type, a: u64, b: u64, c: u64, aux: u64) u64 {
    const bits = ty.bits();
    const m = ty.mask();
    const abits = ta.bits();
    const r: u64 = switch (op) {
        .@"const" => aux,
        .add => a +% b,
        .sub => a -% b,
        .mul => a *% b,
        .mulhu => @truncate((@as(u128, a & m) * (b & m)) >> @intCast(bits)),
        .mulhs => @bitCast(@as(i64, @truncate((@as(i128, sx(a, bits)) * sx(b, bits)) >> @intCast(bits)))),
        .udiv => if (b & m == 0) 0 else (a & m) / (b & m),
        .sdiv => blk: {
            const x = sx(a, bits);
            const y = sx(b, bits);
            if (y == 0) break :blk 0;
            if (y == -1) break :blk @bitCast(-%x);
            break :blk @bitCast(@divTrunc(x, y));
        },
        .urem => if (b & m == 0) a else (a & m) % (b & m),
        .srem => blk: {
            const x = sx(a, bits);
            const y = sx(b, bits);
            if (y == 0) break :blk a;
            if (y == -1) break :blk 0;
            break :blk @bitCast(@rem(x, y));
        },
        .@"and" => a & b,
        .@"or" => a | b,
        .xor => a ^ b,
        .andn => a & ~b,
        .shl => (a & m) << @intCast(b % bits),
        .lshr => (a & m) >> @intCast(b % bits),
        .ashr => @bitCast(sx(a, bits) >> @intCast(b % bits)),
        .ror, .rol => blk: {
            const n0: u32 = @intCast(b % bits);
            const n = if (op == .rol) (bits - n0) % bits else n0;
            if (n == 0) break :blk a;
            break :blk ((a & m) >> @intCast(n)) | ((a & m) << @intCast(bits - n));
        },
        .neg => 0 -% a,
        .not => ~a,
        .clz => @clz(a & m) - (64 - bits),
        .ctz => if (a & m == 0) bits else @ctz(a),
        .popcnt => @popCount(a & m),
        .rbit => @bitReverse(a & m) >> @intCast(64 - bits),
        // One byte or less has nothing to swap.
        .bswap => if (bits <= 8) a & m else @byteSwap(a & m) >> @intCast(64 - bits),
        .zext => a & ta.mask(),
        .sext => @bitCast(sx(a, abits)),
        .trunc => a,
        .select => if (a & 1 == 1) b else c,
        .icmp => @intFromBool(switch (@as(ir.Pred, @enumFromInt(aux))) {
            .eq => a & ta.mask() == b & ta.mask(),
            .ne => a & ta.mask() != b & ta.mask(),
            .ult => a & ta.mask() < b & ta.mask(),
            .ule => a & ta.mask() <= b & ta.mask(),
            .ugt => a & ta.mask() > b & ta.mask(),
            .uge => a & ta.mask() >= b & ta.mask(),
            .slt => sx(a, abits) < sx(b, abits),
            .sle => sx(a, abits) <= sx(b, abits),
            .sgt => sx(a, abits) > sx(b, abits),
            .sge => sx(a, abits) >= sx(b, abits),
        }),
        .@"nzcv.add" => addWithCarry(a, b, 0, abits)[1],
        .@"nzcv.sub" => addWithCarry(a, ~b, 1, abits)[1],
        .@"nzcv.adc" => addWithCarry(a, b, @truncate(c >> 29), abits)[1],
        .@"nzcv.sbc" => addWithCarry(a, ~b, @truncate(c >> 29), abits)[1],
        .@"nzcv.logic" => (@as(u64, msb(a & ta.mask(), abits)) << 31) | (@as(u64, @intFromBool(a & ta.mask() == 0)) << 30),
        .@"nzcv.cond" => @intFromBool(nzcvCond(a, aux)),
        .@"nzcv.pack", .@"nzcv.unpack" => a & 0xf000_0000,
        .@"eflags.add" => eflagsAdd(a & ta.mask(), b & ta.mask(), 0, abits),
        .@"eflags.sub" => eflagsSub(a & ta.mask(), b & ta.mask(), 0, abits),
        .@"eflags.adc" => eflagsAdd(a & ta.mask(), b & ta.mask(), @truncate(c & CF), abits),
        .@"eflags.sbb" => eflagsSub(a & ta.mask(), b & ta.mask(), @truncate(c & CF), abits),
        .@"eflags.logic" => szp(a & ta.mask(), abits),
        .@"eflags.inc" => (eflagsAdd(a & ta.mask(), 1, 0, abits) & ~CF) | (b & CF),
        .@"eflags.dec" => (eflagsSub(a & ta.mask(), 1, 0, abits) & ~CF) | (b & CF),
        .@"eflags.shl" => szp(b & ta.mask(), abits) | (if (msb(a, abits) == 1) CF else 0) | (if (msb(a ^ b, abits) == 1) OF else 0),
        .@"eflags.shr" => szp(b & ta.mask(), abits) | (if (a & 1 == 1) CF else 0) | (if (msb(a ^ b, abits) == 1) OF else 0),
        .@"eflags.mul" => szp(b & ta.mask(), abits) | (if (a & ta.mask() != 0) CF | OF else 0),
        .@"eflags.cond" => @intFromBool(eflagsCond(a, aux)),
        .@"eflags.pack", .@"eflags.unpack" => a & eflags_mask,
        else => unreachable, // not pure
    };
    return if (ty == .flags) r else r & m;
}

/// The fallback emitters call for a pure op they don't lower: `code` is
/// `fallbackCode(op, ty, ta)`.
pub fn evalOpC(code: u64, a: u64, b: u64, c: u64, aux: u64) callconv(.c) u64 {
    const op: Op = @enumFromInt(@as(u16, @truncate(code)));
    const ty: Type = @enumFromInt(@as(u8, @truncate(code >> 16)));
    const ta: Type = @enumFromInt(@as(u8, @truncate(code >> 24)));
    return evalPure(op, ty, ta, a, b, c, aux);
}

pub fn fallbackCode(op: Op, ty: Type, ta: Type) u64 {
    return @as(u64, @intFromEnum(op)) | (@as(u64, @intFromEnum(ty)) << 16) | (@as(u64, @intFromEnum(ta)) << 24);
}

// ---------------------------------------------------------------- FP and vectors

/// softfloat's environment for an `fp.*` op's aux.
pub fn envOf(x: ir.ExtAux) sf.Env {
    return .{
        .rounding = @enumFromInt(x.rounding),
        .daz = x.daz,
        .ftz = x.ftz,
        .ftz_inexact = !x.arm,
        .tininess = if (x.arm) .before_rounding else .after_rounding,
        .nans = @enumFromInt(x.nans),
        .default_nan_negative = !x.arm,
    };
}

/// softfloat's exceptions in the guest's layout: MXCSR's, or FPSR's.
pub fn guestFlags(f: u8, arm: bool) u32 {
    if (!arm) return f & 0x3f;
    return @as(u32, @intFromBool(f & sf.IE != 0)) |
        @as(u32, @intFromBool(f & sf.ZE != 0)) << 1 |
        @as(u32, @intFromBool(f & sf.OE != 0)) << 2 |
        @as(u32, @intFromBool(f & sf.UE != 0)) << 3 |
        @as(u32, @intFromBool(f & sf.PE != 0)) << 4 |
        @as(u32, @intFromBool(f & sf.ID != 0)) << 7;
}

fn FpT(comptime esize: u2) type {
    return switch (esize) {
        1 => u16,
        2 => u32,
        3 => u64,
        else => unreachable,
    };
}

fn esizeOf(t: Type) u2 {
    return switch (t) {
        .i8 => 0,
        .i16 => 1,
        .i32 => 2,
        else => 3,
    };
}

fn laneGet(v: u128, esize: u2, i: usize) u64 {
    const bits = @as(u32, 8) << esize;
    return @as(u64, @truncate(v >> @intCast(i * bits))) & maskOf(bits);
}

fn lanePut(v: *u128, esize: u2, i: usize, x: u64) void {
    const bits = @as(u32, 8) << esize;
    const m: u128 = @as(u128, maskOf(bits)) << @intCast(i * bits);
    v.* = (v.* & ~m) | ((@as(u128, x & maskOf(bits)) << @intCast(i * bits)) & m);
}

/// Arm's FMAX, FMIN, FMAXNM, and FMINNM.
fn armMaxMin(comptime T: type, e: *sf.Env, a: T, b: T, is_max: bool, num: bool) T {
    const F = sf.Fmt(T);
    var x = a;
    var y = b;
    if (num) {
        const qa = sf.isNan(T, a) and !sf.isSnan(T, a);
        const qb = sf.isNan(T, b) and !sf.isSnan(T, b);
        const inf: T = if (is_max) F.sign_bit | F.inf else F.inf;
        if (qa and !qb) x = inf else if (qb and !qa) y = inf;
    }
    if (sf.pickNan(T, e, &.{ x, y })) |r| return r;
    x = sf.daz(T, e, x);
    y = sf.daz(T, e, y);
    if (sf.isZero(T, x) and sf.isZero(T, y)) {
        const sa = x & F.sign_bit != 0;
        const sb = y & F.sign_bit != 0;
        const neg = if (is_max) sa and sb else sa or sb;
        return if (neg) F.sign_bit else 0;
    }
    const o = sf.order(T, x, y);
    return if ((o == .gt) == is_max) x else y;
}

/// a * b + c, by x's rules.
fn fma(comptime T: type, e: *sf.Env, arm: bool, a: T, b: T, c: T) T {
    if (!arm) return sf.mulAdd(T, e, a, b, c);
    // Arm's FPMulAdd: NaNs in the order c, a, b; inf * 0 + qNaN is the
    // default NaN.
    if (sf.pickNan(T, e, &.{ c, a, b })) |r| {
        const inf_zero = (sf.isInf(T, a) and sf.isZero(T, sf.daz(T, e, b))) or (sf.isZero(T, sf.daz(T, e, a)) and sf.isInf(T, b));
        if (sf.isNan(T, c) and !sf.isSnan(T, c) and inf_zero) {
            e.flags |= sf.IE;
            return sf.defaultNan(T, e);
        }
        return r;
    }
    return sf.mulAdd(T, e, a, b, c);
}

/// FP to an integer of I, by x's rules for NaNs and values out of range.
fn toInt(comptime T: type, comptime I: type, e: *sf.Env, x: ir.ExtAux, a: T) I {
    if (sf.toFixed(T, I, e, a, @enumFromInt(x.rounding), x.imm)) |v| return v;
    const signed = @typeInfo(I).int.signedness == .signed;
    if (!x.arm) return if (signed) std.math.minInt(I) else std.math.maxInt(I);
    if (sf.isNan(T, a)) return 0;
    return if (a & sf.Fmt(T).sign_bit != 0) std.math.minInt(I) else std.math.maxInt(I);
}

fn fromInt(comptime T: type, comptime I: type, e: *sf.Env, v: u64, imm: u32) T {
    const U = std.meta.Int(.unsigned, @bitSizeOf(I));
    return sf.fromFixed(T, I, e, @bitCast(@as(U, @truncate(v))), imm);
}

/// One `fp.*` op on scalars of format T (or, for conversions, from or to
/// it): the result's bits, zero-extended.
fn fpScalar(comptime T: type, op: Op, ty: Type, ta: Type, e: *sf.Env, x: ir.ExtAux, a: u64, b: u64, c: u64) u64 {
    const p: T = @truncate(a);
    const q: T = @truncate(b);
    const r: T = @truncate(c);
    return switch (op) {
        .@"fp.add" => sf.add(T, e, p, q),
        .@"fp.sub" => sf.sub(T, e, p, q),
        .@"fp.mul" => sf.mul(T, e, p, q),
        .@"fp.div" => sf.div(T, e, p, q),
        .@"fp.sqrt" => sf.sqrt(T, e, p),
        .@"fp.fma" => fma(T, e, x.arm, p, q, r),
        .@"fp.min" => if (x.arm) armMaxMin(T, e, p, q, false, false) else sf.min(T, e, p, q),
        .@"fp.max" => if (x.arm) armMaxMin(T, e, p, q, true, false) else sf.max(T, e, p, q),
        .@"fp.minnm" => armMaxMin(T, e, p, q, false, true),
        .@"fp.maxnm" => armMaxMin(T, e, p, q, true, true),
        .@"fp.cmp" => @intFromEnum(sf.compare(T, e, p, q, x.exact)),
        .@"fp.round" => sf.roundToInt(T, e, p, @enumFromInt(x.rounding), x.exact),
        // T is the result's format; a is ta's.
        .@"fp.cvt" => switch (ta) {
            inline .i16, .i32, .i64 => |t| sf.convert(T, FpT(esizeOf(t)), e, @truncate(a)),
            else => unreachable,
        },
        .@"fp.fromsint" => if (ta == .i32) fromInt(T, i32, e, a, x.imm) else fromInt(T, i64, e, a, x.imm),
        .@"fp.fromuint" => if (ta == .i32) fromInt(T, u32, e, a, x.imm) else fromInt(T, u64, e, a, x.imm),
        // T is a's format; the result is ty.
        .@"fp.tosint" => if (ty == .i32) @as(u32, @bitCast(toInt(T, i32, e, x, p))) else @bitCast(toInt(T, i64, e, x, p)),
        .@"fp.touint" => if (ty == .i32) toInt(T, u32, e, x, p) else toInt(T, u64, e, x, p),
        else => unreachable,
    };
}

/// The format an `fp.*` op computes in: its result's, but its operand's
/// for comparisons and conversions to integers.
fn fpFormat(op: Op, ty: Type, ta: Type) u2 {
    return switch (op) {
        .@"fp.cmp", .@"fp.tosint", .@"fp.touint" => esizeOf(ta),
        else => esizeOf(ty),
    };
}

/// An `fp.*` op lane-wise on v128.
fn fpVector(op: Op, e: *sf.Env, x: ir.ExtAux, a: u128, b: u128, c: u128) u128 {
    var out: u128 = 0;
    switch (op) {
        .@"fp.cvt" => {
            const to: u2 = @truncate(x.imm);
            const n = @as(u32, 16) >> @max(to, x.esize);
            const half: usize = if (x.imm & 0x100 != 0) n else 0;
            for (0..n) |k| {
                const from_lane = if (to > x.esize) half + k else k;
                const v = laneGet(a, x.esize, from_lane);
                const r: u64 = switch (to) {
                    inline 1...3 => |t| switch (x.esize) {
                        inline 1...3 => |f| if (t == f) unreachable else sf.convert(FpT(t), FpT(f), e, @truncate(v)),
                        else => unreachable,
                    },
                    else => unreachable,
                };
                lanePut(&out, to, k, r);
            }
            return out;
        },
        else => {},
    }
    const lt = ir.laneType(x.esize);
    for (0..x.lanes()) |k| {
        const p = laneGet(a, x.esize, k);
        const q = laneGet(b, x.esize, k);
        const r = laneGet(c, x.esize, k);
        const v: u64 = switch (x.esize) {
            inline 1...3 => |es| blk: {
                const T = FpT(es);
                if (op == .@"fp.cmp") {
                    const o = sf.compare(T, e, @truncate(p), @truncate(q), x.exact);
                    break :blk if (x.imm >> @intFromEnum(o) & 1 != 0) maskOf(x.bits()) else 0;
                }
                break :blk fpScalar(T, op, lt, lt, e, x, p, q, r);
            },
            else => unreachable,
        };
        lanePut(&out, x.esize, k, v);
    }
    return out;
}

fn sat(v: i128, lo: i128, hi: i128) u64 {
    return @truncate(@as(u128, @bitCast(@min(@max(v, lo), hi))));
}

/// A `v.*` op (but v.load and v.store).
fn vecOp(op: Op, x: ir.ExtAux, a: u128, b: u128) u128 {
    const es = x.esize;
    const n = x.lanes();
    const bits = x.bits();
    var out: u128 = 0;
    switch (op) {
        .@"v.make" => return @as(u128, @as(u64, @truncate(b))) << 64 | @as(u64, @truncate(a)),
        .@"v.lane" => return laneGet(a, es, x.imm),
        .@"v.ins" => {
            out = a;
            lanePut(&out, es, x.imm, @truncate(b));
            return out;
        },
        .@"v.dup" => {
            for (0..n) |k| lanePut(&out, es, k, @truncate(a));
            return out;
        },
        .@"v.and" => return a & b,
        .@"v.or" => return a | b,
        .@"v.xor" => return a ^ b,
        .@"v.andn" => return a & ~b,
        .@"v.ext" => {
            if (x.imm == 0) return a;
            const sh: u7 = @intCast(8 * @as(u32, x.imm));
            return (a >> sh) | (b << @intCast(128 - @as(u32, sh)));
        },
        .@"v.tbl" => {
            for (0..16) |k| {
                const idx = laneGet(b, 0, k);
                if (idx < 16) lanePut(&out, 0, k, laneGet(a, 0, @intCast(idx)));
            }
            return out;
        },
        .@"v.zip", .@"v.uzp", .@"v.trn" => {
            const two = x.imm == 1;
            for (0..n) |k| {
                const v = switch (op) {
                    .@"v.uzp" => blk: {
                        const j = 2 * k + @intFromBool(two);
                        break :blk if (j < n) laneGet(a, es, j) else laneGet(b, es, j - n);
                    },
                    .@"v.trn" => blk: {
                        const j = (k & ~@as(usize, 1)) + @intFromBool(two);
                        break :blk if (k & 1 == 0) laneGet(a, es, j) else laneGet(b, es, j);
                    },
                    else => blk: {
                        const j = k / 2 + (if (two) n / 2 else 0);
                        break :blk if (k & 1 == 0) laneGet(a, es, j) else laneGet(b, es, j);
                    },
                };
                lanePut(&out, es, k, v);
            }
            return out;
        },
        .@"v.narrow" => {
            const hb = bits / 2;
            const smax: i128 = (@as(i128, 1) << @intCast(hb - 1)) - 1;
            const smin: i128 = -(@as(i128, 1) << @intCast(hb - 1));
            const umax: i128 = (@as(i128, 1) << @intCast(hb)) - 1;
            for (0..n) |k| {
                const v = laneGet(a, es, k);
                const r: u64 = switch (x.imm) {
                    0 => v,
                    1 => sat(sx(v, bits), smin, smax),
                    2 => sat(sx(v, bits), 0, umax),
                    else => sat(v, 0, umax),
                };
                lanePut(&out, es - 1, k, r);
            }
            return out;
        },
        .@"v.widen" => {
            const half: usize = if (x.imm & 2 != 0) n / 2 else 0;
            for (0..n / 2) |k| {
                const v = laneGet(a, es, half + k);
                lanePut(&out, es + 1, k, if (x.imm & 1 != 0) @bitCast(sx(v, bits)) else v);
            }
            return out;
        },
        else => {},
    }
    for (0..n) |k| {
        const p = laneGet(a, es, k);
        const q = laneGet(b, es, k);
        const sp = sx(p, bits);
        const sq = sx(q, bits);
        const v: u64 = switch (op) {
            .@"v.add" => p +% q,
            .@"v.sub" => p -% q,
            .@"v.mul" => p *% q,
            .@"v.shl" => if (x.imm >= bits) 0 else p << @intCast(x.imm),
            .@"v.lshr" => if (x.imm >= bits) 0 else p >> @intCast(x.imm),
            .@"v.ashr" => @bitCast(sp >> @intCast(@min(x.imm, bits - 1))),
            .@"v.cmp" => if (evalPure(.icmp, .i1, ir.laneType(es), p, q, 0, x.imm) == 1) maxInt64 else 0,
            .@"v.min" => if (if (x.imm & 1 != 0) sp < sq else p < q) p else q,
            .@"v.max" => if (if (x.imm & 1 != 0) sp > sq else p > q) p else q,
            else => unreachable,
        };
        lanePut(&out, es, k, v);
    }
    return out;
}

const maxInt64: u64 = std.math.maxInt(u64);

/// An `fp.*` or `v.*` op (but v.load and v.store), on the Cpu at `cpu`
/// for `fp.*`'s exceptions.
pub fn evalExt(cpu: [*]u8, op: Op, ty: Type, ta: Type, a: u128, b: u128, c: u128, aux: u64, aux2: u64) u128 {
    const x = ir.ExtAux.of(aux);
    if (!op.isFp()) return vecOp(op, x, a, b);
    var e = envOf(x);
    const r: u128 = if (ty == .v128)
        fpVector(op, &e, x, a, b, c)
    else switch (fpFormat(op, ty, ta)) {
        inline 1...3 => |es| fpScalar(FpT(es), op, ty, ta, &e, x, @truncate(a), @truncate(b), @truncate(c)) & ty.mask(),
        else => unreachable,
    };
    if (aux2 != 0 and e.flags != 0) {
        const w: *align(1) u32 = @ptrCast(cpu + @as(usize, @intCast(aux2 - 1)));
        w.* |= guestFlags(e.flags, x.arm);
    }
    return r;
}

/// The fallback emitters call for an `fp.*` or `v.*` op (but v.load and
/// v.store) they don't lower: `code` is `fallbackCode(op, ty, ta)`, and
/// `io` holds a, b, and c, 16 bytes each, little-endian (a scalar in its
/// low bytes, zero-extended). The result goes to io[0..16].
pub fn evalExtC(ctx: *Ctx, code: u64, io: [*]u8, aux: u64, aux2: u64) callconv(.c) void {
    const op: Op = @enumFromInt(@as(u16, @truncate(code)));
    const ty: Type = @enumFromInt(@as(u8, @truncate(code >> 16)));
    const ta: Type = @enumFromInt(@as(u8, @truncate(code >> 24)));
    const a = std.mem.readInt(u128, io[0..16], .little);
    const b = std.mem.readInt(u128, io[16..32], .little);
    const c = std.mem.readInt(u128, io[32..48], .little);
    const cpu: [*]u8 = @ptrFromInt(@as(usize, @intCast(ctx.cpu)));
    std.mem.writeInt(u128, io[0..16], evalExt(cpu, op, ty, ta, a, b, c, aux, aux2), .little);
}

// ---------------------------------------------------------------- regions

pub const Error = error{ OutOfMemory, Unsupported };

fn byteSize(t: Type) Error!usize {
    return switch (t) {
        .i8 => 1,
        .i16 => 2,
        .i32 => 4,
        .i64, .flags => 8,
        .v128 => 16,
        else => error.Unsupported,
    };
}

/// Runs a verified region with ctx's Cpu, TLB, and slow paths, and
/// returns how it left, as generated code would.
pub fn run(gpa: std.mem.Allocator, r: *const ir.Region, ctx: *Ctx) Error!Exit {
    const vals = try gpa.alloc(u128, r.insts.items.len);
    defer gpa.free(vals);
    const cpu: [*]u8 = @ptrFromInt(@as(usize, @intCast(ctx.cpu)));
    const tlb: *mem.Tlb = @ptrFromInt(@as(usize, @intCast(ctx.tlb)));
    var blk: ir.BlockId = 0;
    while (true) {
        const b = r.blocks.items[blk];
        for (b.start..b.start + b.len) |idx| {
            const i = r.insts.items[idx];
            const wa: u128 = if (i.a != ir.none) vals[i.a] else 0;
            const wb: u128 = if (i.b != ir.none) vals[i.b] else 0;
            const wc: u128 = if (i.c != ir.none) vals[i.c] else 0;
            const a: u64 = @truncate(wa);
            const bv: u64 = @truncate(wb);
            const cv: u64 = @truncate(wc);
            const ta: Type = if (i.a != ir.none) r.insts.items[i.a].ty else .none;
            if (i.op.isPure()) {
                vals[idx] = evalPure(i.op, i.ty, ta, a, bv, cv, i.aux);
                continue;
            }
            if (i.op.isExt() and i.op != .@"v.load" and i.op != .@"v.store") {
                vals[idx] = evalExt(cpu, i.op, i.ty, ta, wa, wb, wc, i.aux, i.aux2);
                continue;
            }
            switch (i.op) {
                .getreg => {
                    var v: u128 = 0;
                    @memcpy(std.mem.asBytes(&v)[0..try byteSize(i.ty)], cpu[@intCast(i.aux)..][0..try byteSize(i.ty)]);
                    vals[idx] = v;
                },
                .setreg => @memcpy(cpu[@intCast(i.aux)..][0..try byteSize(ta)], std.mem.asBytes(&wa)[0..try byteSize(ta)]),
                .@"v.load" => {
                    const f: ir.MemFlags = @bitCast(i.aux);
                    if (f.aligned and a % 16 != 0) return left(ctx, i, alignFault(ctx, a, .read, i.aux2));
                    var v: u128 = 0;
                    if (mem.fast(tlb, a, 16, false)) |host| {
                        @memcpy(std.mem.asBytes(&v), @as([*]const u8, @ptrFromInt(host))[0..16]);
                    } else {
                        // Two halves through the slow path, the low first.
                        const slow: mem.SlowLoadFn = @ptrFromInt(@as(usize, @intCast(ctx.slow_load)));
                        for (0..2) |h| {
                            if (slow(ctx, a +% 8 * h, 3) != 0) {
                                ctx.exit_pc = i.aux2;
                                return left(ctx, i, .fault);
                            }
                            v |= @as(u128, ctx.scratch) << @intCast(64 * h);
                        }
                    }
                    vals[idx] = v;
                },
                .@"v.store" => {
                    const f: ir.MemFlags = @bitCast(i.aux);
                    if (f.aligned and a % 16 != 0) return left(ctx, i, alignFault(ctx, a, .write, i.aux2));
                    if (mem.fast(tlb, a, 16, true)) |host| {
                        @memcpy(@as([*]u8, @ptrFromInt(host))[0..16], std.mem.asBytes(&wb));
                    } else {
                        const slow: mem.SlowStoreFn = @ptrFromInt(@as(usize, @intCast(ctx.slow_store)));
                        for (0..2) |h| {
                            if (slow(ctx, a +% 8 * h, 3, @truncate(wb >> @intCast(64 * h))) != 0) {
                                ctx.exit_pc = i.aux2;
                                return left(ctx, i, .fault);
                            }
                        }
                    }
                },
                .load => {
                    const f: ir.MemFlags = @bitCast(i.aux);
                    const n = f.bytes();
                    var v: u64 = 0;
                    if (f.aligned and a % n != 0) return left(ctx, i, alignFault(ctx, a, if (f.rmw) .write else .read, i.aux2));
                    if (mem.fast(tlb, a, n, false)) |host| {
                        @memcpy(std.mem.asBytes(&v)[0..n], @as([*]const u8, @ptrFromInt(host))[0..n]);
                    } else {
                        const slow: mem.SlowLoadFn = @ptrFromInt(@as(usize, @intCast(ctx.slow_load)));
                        if (slow(ctx, a, f.size) != 0) {
                            if (f.rmw) ctx.exit_info = (ctx.exit_info & ~@as(u64, 0xff)) | @intFromEnum(mem.Access.write);
                            ctx.exit_pc = i.aux2;
                            return left(ctx, i, .fault);
                        }
                        v = ctx.scratch;
                    }
                    if (f.signed) v = @bitCast(sx(v, n * 8));
                    vals[idx] = v & i.ty.mask();
                },
                .store => {
                    const f: ir.MemFlags = @bitCast(i.aux);
                    const n = f.bytes();
                    if (f.aligned and a % n != 0) return left(ctx, i, alignFault(ctx, a, .write, i.aux2));
                    if (mem.fast(tlb, a, n, true)) |host| {
                        @memcpy(@as([*]u8, @ptrFromInt(host))[0..n], std.mem.asBytes(&bv)[0..n]);
                    } else {
                        const slow: mem.SlowStoreFn = @ptrFromInt(@as(usize, @intCast(ctx.slow_store)));
                        if (slow(ctx, a, f.size, bv) != 0) {
                            ctx.exit_pc = i.aux2;
                            return left(ctx, i, .fault);
                        }
                    }
                },
                .cas => {
                    const f: ir.MemFlags = @bitCast(i.aux);
                    const m = i.ty.mask();
                    const slow: mem.SlowCasFn = @ptrFromInt(@as(usize, @intCast(ctx.slow_cas)));
                    if (slow(ctx, a, f.size, bv & m, cv & m) != 0) {
                        ctx.exit_pc = i.aux2;
                        return left(ctx, i, .fault);
                    }
                    vals[idx] = ctx.scratch & m;
                },
                .fence => _ = @atomicRmw(u32, &fence_word, .Add, 0, .seq_cst),
                .@"call.interp" => {
                    const f: ctx_mod.InterpFn = @ptrFromInt(@as(usize, @intCast(ctx.interp)));
                    const res = f(ctx, r.handles.items[@intCast(i.aux)], i.aux2);
                    if (res != 0) return left(ctx, i, @enumFromInt(res));
                },
                .@"call.helper" => {
                    const table: [*]const ctx_mod.HelperFn = @ptrFromInt(@as(usize, @intCast(ctx.helpers)));
                    vals[idx] = table[@intCast(i.aux)](ctx, a, bv, cv);
                },
                .poll => if (@atomicLoad(u32, &ctx.exit_request, .monotonic) != 0 or ctx.budget <= 0) {
                    ctx.exit_pc = i.aux;
                    return left(ctx, i, .interrupted);
                },
                .retire => {
                    ctx.retired +%= i.aux;
                    ctx.budget -%= @bitCast(i.aux);
                },
                .br => blk = @intCast(i.aux),
                .brcond => blk = @intCast(if (a & 1 == 1) i.aux else i.aux2),
                .@"exit.chain" => return left(ctx, i, exitAt(ctx, .chain, i.aux)),
                .@"exit.indirect" => return left(ctx, i, exitAt(ctx, .indirect, a)),
                .@"exit.svc" => return left(ctx, i, exitAt(ctx, .svc, i.aux)),
                .@"exit.brk" => return left(ctx, i, exitAt(ctx, .brk, i.aux)),
                .@"exit.undef" => return left(ctx, i, exitAt(ctx, .undef, i.aux)),
                else => unreachable,
            }
        }
    }
}

/// A seq_cst read-modify-write is a full barrier on every host.
var fence_word: u32 = 0;

/// Leaving through `i`: count the instructions it says completed.
fn left(ctx: *Ctx, i: ir.Inst, e: Exit) Exit {
    ctx.retired +%= i.retired;
    ctx.budget -%= i.retired;
    return e;
}

fn exitAt(ctx: *Ctx, e: Exit, pc: u64) Exit {
    ctx.exit_pc = pc;
    return e;
}

fn alignFault(ctx: *Ctx, addr: u64, acc: mem.Access, pc: u64) Exit {
    ctx.exit_pc = pc;
    ctx.exit_addr = addr;
    ctx.exit_info = @as(u64, @intFromEnum(acc)) | (@as(u64, @intFromEnum(mem.FaultKind.alignment)) << 8);
    return .fault;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn pure(op: Op, ty: Type, a: u64, b: u64) u64 {
    return evalPure(op, ty, ty, a, b, 0, 0);
}

test "integer semantics at each width" {
    try testing.expectEqual(@as(u64, 0xff), pure(.sub, .i8, 0, 1));
    try testing.expectEqual(@as(u64, 0xffff_fffe), pure(.shl, .i32, 0xffff_ffff, 33));
    try testing.expectEqual(@as(u64, 0xc000_0000), pure(.ashr, .i32, 0x8000_0000, 1));
    try testing.expectEqual(@as(u64, 0x8000_0001), pure(.ror, .i32, 0x3, 1));
    try testing.expectEqual(@as(u64, 0x8000_0001), pure(.rol, .i32, 0xc000_0000, 1));
    try testing.expectEqual(@as(u64, 0), pure(.udiv, .i64, 5, 0));
    try testing.expectEqual(@as(u64, 0x8000_0000), pure(.sdiv, .i32, 0x8000_0000, 0xffff_ffff));
    try testing.expectEqual(@as(u64, 0xffff_fffe), pure(.sdiv, .i32, 0xffff_fffa, 3));
    try testing.expectEqual(@as(u64, 1), pure(.mulhu, .i64, 1 << 63, 2));
    try testing.expectEqual(@as(u64, 0xffff_ffff_ffff_ffff), pure(.mulhs, .i64, @bitCast(@as(i64, -1)), 1));
    try testing.expectEqual(@as(u64, 31), evalPure(.clz, .i32, .i32, 1, 0, 0, 0));
    try testing.expectEqual(@as(u64, 0x8000_0000), evalPure(.rbit, .i32, .i32, 1, 0, 0, 0));
    try testing.expectEqual(@as(u64, 0x0403_0201), evalPure(.bswap, .i32, .i32, 0x0102_0304, 0, 0, 0));
    try testing.expectEqual(@as(u64, 1), evalPure(.bswap, .i1, .i1, 1, 0, 0, 0));
    try testing.expectEqual(@as(u64, 0xab), evalPure(.bswap, .i8, .i8, 0xab, 0, 0, 0));
    try testing.expectEqual(@as(u64, 0xffff_ffff_ffff_ff80), evalPure(.sext, .i64, .i8, 0x80, 0, 0, 0));
    try testing.expectEqual(@as(u64, 1), evalPure(.icmp, .i1, .i32, 0xffff_ffff, 0, 0, @intFromEnum(ir.Pred.slt)));
}

test "NZCV matches arm64's AddWithCarry" {
    // CMP 0, 1: N, no carry (a borrow).
    try testing.expectEqual(@as(u64, 0x8000_0000), pure(.@"nzcv.sub", .flags, 0, 1) & 0xf000_0000);
    try testing.expectEqual(@as(u64, 0x8000_0000), evalPure(.@"nzcv.sub", .flags, .i64, 0, 1, 0, 0));
    // CMP 5, 5: Z and C.
    try testing.expectEqual(@as(u64, 0x6000_0000), evalPure(.@"nzcv.sub", .flags, .i32, 5, 5, 0, 0));
    // ADDS 0x7fffffff + 1 at 32 bits: N and V.
    try testing.expectEqual(@as(u64, 0x9000_0000), evalPure(.@"nzcv.add", .flags, .i32, 0x7fff_ffff, 1, 0, 0));
    // Conditions: EQ, NE, GE, LT, HI.
    try testing.expect(nzcvCond(0x4000_0000, 0));
    try testing.expect(!nzcvCond(0x4000_0000, 1));
    try testing.expect(nzcvCond(0x9000_0000, 10)); // N == V
    try testing.expect(nzcvCond(0x2000_0000, 8)); // C and !Z
    try testing.expect(nzcvCond(0, 15));
}

test "EFLAGS for add, sub, inc, and logic" {
    // 0xff + 1 at 8 bits: CF ZF PF AF.
    try testing.expectEqual(CF | ZF | PF | AF, evalPure(.@"eflags.add", .flags, .i8, 0xff, 1, 0, 0));
    // 0x7f + 1: OF SF AF.
    try testing.expectEqual(OF | SF | AF, evalPure(.@"eflags.add", .flags, .i8, 0x7f, 1, 0, 0));
    // 0 - 1 at 32 bits: CF SF PF AF.
    try testing.expectEqual(CF | SF | PF | AF, evalPure(.@"eflags.sub", .flags, .i32, 0, 1, 0, 0));
    // INC keeps CF.
    try testing.expectEqual(CF | ZF | PF | AF, evalPure(.@"eflags.inc", .flags, .i8, 0xff, CF, 0, 0));
    try testing.expectEqual(ZF | PF | AF, evalPure(.@"eflags.inc", .flags, .i8, 0xff, 0, 0, 0));
    try testing.expectEqual(ZF | PF, evalPure(.@"eflags.logic", .flags, .i32, 0, 0, 0, 0));
    // SHL 0x81, 1 at 8 bits: pre 0x81, result 0x02: CF, and OF (CF != msb(res)).
    try testing.expectEqual(CF | OF, evalPure(.@"eflags.shl", .flags, .i8, 0x81, 0x02, 0, 0));
    // SHR 0x03, 1: pre 0x03, result 0x01: CF, no OF, PF clear (one bit).
    try testing.expectEqual(CF, evalPure(.@"eflags.shr", .flags, .i8, 0x03, 0x01, 0, 0));
    // SAR 0x80000000, 1 at 32 bits: pre the source, result 0xc0000000: SF PF.
    try testing.expectEqual(SF | PF, evalPure(.@"eflags.shr", .flags, .i32, 0x8000_0000, 0xc000_0000, 0, 0));
    // MUL that overflowed, low half 0: CF OF ZF PF.
    try testing.expectEqual(CF | OF | ZF | PF, evalPure(.@"eflags.mul", .flags, .i16, 1, 0, 0, 0));
    // JL after CMP -1, 0; JBE after CMP 0, 0.
    try testing.expect(eflagsCond(evalPure(.@"eflags.sub", .flags, .i32, 0xffff_ffff, 0, 0, 0), 12));
    try testing.expect(eflagsCond(evalPure(.@"eflags.sub", .flags, .i32, 0, 0, 0, 0), 6));
}

test "a counted loop runs to its exit" {
    const gpa = testing.allocator;
    var region = try ir.parse(gpa,
        \\region 0x1000
        \\b0:
        \\  poll #0x1000
        \\  %0 = getreg:i64 #0x0
        \\  %1 = getreg:i64 #0x8
        \\  %2 = add:i64 %0, %1
        \\  setreg %2 #0x0
        \\  %3 = const:i64 #0x1
        \\  %4 = sub:i64 %1, %3
        \\  setreg %4 #0x8
        \\  %5 = nzcv.sub:flags %1, %3
        \\  retire #0x3
        \\  %6 = nzcv.cond:i1 %5 #0x1
        \\  brcond %6 -> b0 b1
        \\b1:
        \\  exit.svc #0x1010
    );
    defer region.deinit(gpa);
    try testing.expect(ir.verify(&region) == null);
    var regs: [2]u64 = .{ 0, 10 };
    var tlb: mem.Tlb = .{};
    var c: Ctx = .{ .cpu = @intFromPtr(&regs), .tlb = @intFromPtr(&tlb) };
    try testing.expectEqual(Exit.svc, try run(gpa, &region, &c));
    try testing.expectEqual(@as(u64, 55), regs[0]);
    try testing.expectEqual(@as(u64, 0x1010), c.exit_pc);
    try testing.expectEqual(@as(u64, 30), c.retired);
    // A budget stops it at the loop head.
    regs = .{ 0, 10 };
    c.budget = 7;
    try testing.expectEqual(Exit.interrupted, try run(gpa, &region, &c));
    try testing.expectEqual(@as(u64, 10 + 9 + 8), regs[0]); // 3 iterations of 3 spend 7
}

test "loads and stores take the slow path and fault exactly" {
    const gpa = testing.allocator;
    var region = try ir.parse(gpa,
        \\region 0x0
        \\b0:
        \\  %0 = getreg:i64 #0x0
        \\  %1 = const:i32 #0xfffffff0
        \\  store %0, %1 #0x2 @0x100
        \\  %2 = load:i64 %0 #0x8 @0x104
        \\  setreg %2 #0x8
        \\  %3 = const:i64 #0x8
        \\  %4 = add:i64 %0, %3
        \\  %5 = load:i64 %4 #0x3 @0x108
        \\  exit.chain #0x10c
    );
    defer region.deinit(gpa);
    try testing.expect(ir.verify(&region) == null);
    var page: [mem.page_size]u8 align(mem.page_size) = @splat(0);
    const regions = [_]mem.Region{.{ .va = 0x4000, .mem = &page, .write = true }};
    var map: mem.Map = .{ .regions = &regions };
    var tlb: mem.Tlb = .{};
    var regs: [2]u64 = .{ 0x4ffc, 0 };
    var c: Ctx = .{
        .cpu = @intFromPtr(&regs),
        .tlb = @intFromPtr(&tlb),
        .space = @intFromPtr(&map),
        .slow_load = @intFromPtr(&mem.mapSlowLoad),
        .slow_store = @intFromPtr(&mem.mapSlowStore),
        .slow_cas = @intFromPtr(&mem.mapSlowCas),
    };
    // The store and the signed byte load fit; the 8-byte load 8 bytes on
    // is in the unmapped page. State before it is already written.
    try testing.expectEqual(Exit.fault, try run(gpa, &region, &c));
    try testing.expectEqual(@as(u64, 0x108), c.exit_pc);
    try testing.expectEqual(@as(u64, 0x5004), c.exit_addr);
    try testing.expectEqual(@as(u64, 0xffff_ffff_ffff_fff0), regs[1]);
    regs = .{ 0x4ff0, 0 };
    try testing.expectEqual(Exit.chain, try run(gpa, &region, &c));
    try testing.expectEqual(@as(u64, 0x10c), c.exit_pc);
}

fn ext(op: Op, ty: Type, ta: Type, a: u128, b: u128, c: u128, x: ir.ExtAux, flags: ?*u32) u128 {
    var cpu: [4]u32 = .{ 0, 0, 0, 0 };
    const r = evalExt(@ptrCast(&cpu), op, ty, ta, a, b, c, @bitCast(x), if (flags != null) 5 else 0);
    if (flags) |f| f.* = cpu[1];
    return r;
}

const x86_env: ir.ExtAux = .{};
const arm_env: ir.ExtAux = .{ .arm = true, .nans = @intFromEnum(sf.Nans.signaling_first) };

test "fp ops follow the guest's rules" {
    var f: u32 = 0;
    // 1 + 2 = 3, exactly.
    try testing.expectEqual(@as(u128, 0x4040_0000), ext(.@"fp.add", .i32, .i32, 0x3f80_0000, 0x4000_0000, 0, x86_env, &f));
    try testing.expectEqual(@as(u32, 0), f);
    // 1 / 0: infinity and divide-by-zero, in MXCSR's bit 2 or FPSR's bit 1.
    try testing.expectEqual(@as(u128, 0x7ff0_0000_0000_0000), ext(.@"fp.div", .i64, .i64, 0x3ff0_0000_0000_0000, 0, 0, x86_env, &f));
    try testing.expectEqual(@as(u32, 4), f);
    _ = ext(.@"fp.div", .i64, .i64, 0x3ff0_0000_0000_0000, 0, 0, arm_env, &f);
    try testing.expectEqual(@as(u32, 2), f);
    // 0 / 0: the default NaN, negative on x86 and positive on Arm.
    try testing.expectEqual(@as(u128, 0xffc0_0000), ext(.@"fp.div", .i32, .i32, 0, 0, 0, x86_env, null));
    try testing.expectEqual(@as(u128, 0x7fc0_0000), ext(.@"fp.div", .i32, .i32, 0, 0, 0, arm_env, null));
    // 1/3 is inexact.
    _ = ext(.@"fp.div", .i32, .i32, 0x3f80_0000, 0x4040_0000, 0, x86_env, &f);
    try testing.expectEqual(@as(u32, 0x20), f);
    // MINSS gives b for a NaN; FMIN gives the NaN, FMINNM the number.
    try testing.expectEqual(@as(u128, 0x3f80_0000), ext(.@"fp.min", .i32, .i32, 0x7fc0_0001, 0x3f80_0000, 0, x86_env, null));
    try testing.expectEqual(@as(u128, 0x7fc0_0001), ext(.@"fp.min", .i32, .i32, 0x7fc0_0001, 0x3f80_0000, 0, arm_env, null));
    try testing.expectEqual(@as(u128, 0x3f80_0000), ext(.@"fp.minnm", .i32, .i32, 0x7fc0_0001, 0x3f80_0000, 0, arm_env, null));
    // FMAX of zeros is +0, FMIN -0.
    try testing.expectEqual(@as(u128, 0x8000_0000), ext(.@"fp.min", .i32, .i32, 0, 0x8000_0000, 0, arm_env, null));
    try testing.expectEqual(@as(u128, 0), ext(.@"fp.max", .i32, .i32, 0x8000_0000, 0, 0, arm_env, null));
    // Out of range: x86's integer indefinite, Arm's saturation; NaN is 0 on Arm.
    var trunc = x86_env;
    trunc.rounding = @intFromEnum(sf.Rounding.zero);
    try testing.expectEqual(@as(u128, 0x8000_0000), ext(.@"fp.tosint", .i32, .i32, 0x4f80_0000, 0, 0, trunc, null)); // 2^32
    var arm_trunc = arm_env;
    arm_trunc.rounding = @intFromEnum(sf.Rounding.zero);
    try testing.expectEqual(@as(u128, 0x7fff_ffff), ext(.@"fp.tosint", .i32, .i32, 0x4f80_0000, 0, 0, arm_trunc, null));
    try testing.expectEqual(@as(u128, 0), ext(.@"fp.tosint", .i64, .i32, 0x7fc0_0000, 0, 0, arm_trunc, null));
    try testing.expectEqual(@as(u128, 0xffff_ffff_ffff_fffe), ext(.@"fp.tosint", .i64, .i64, 0xc000_0000_0000_0000, 0, 0, trunc, null)); // -2.0
    // Fixed point: 3 / 2^1 = 1.5.
    var fixed = x86_env;
    fixed.imm = 1;
    try testing.expectEqual(@as(u128, 0x3fc0_0000), ext(.@"fp.fromsint", .i32, .i32, 3, 0, 0, fixed, null));
    try testing.expectEqual(@as(u128, 0xbf80_0000), ext(.@"fp.fromsint", .i32, .i64, 0xffff_ffff_ffff_ffff, 0, 0, x86_env, null));
    try testing.expectEqual(@as(u128, 0x4f80_0000), ext(.@"fp.fromuint", .i32, .i32, 0xffff_ffff, 0, 0, x86_env, null));
    // Compare: 1 < 2; NaN unordered.
    try testing.expectEqual(@as(u128, 0), ext(.@"fp.cmp", .i8, .i32, 0x3f80_0000, 0x4000_0000, 0, x86_env, null));
    try testing.expectEqual(@as(u128, 3), ext(.@"fp.cmp", .i8, .i32, 0x7fc0_0000, 0x4000_0000, 0, x86_env, null));
    // Conversions, and rounding to integral: 2.5 to even is 2.
    try testing.expectEqual(@as(u128, 0x3ff8_0000_0000_0000), ext(.@"fp.cvt", .i64, .i32, 0x3fc0_0000, 0, 0, x86_env, null));
    try testing.expectEqual(@as(u128, 0x4000_0000), ext(.@"fp.round", .i32, .i32, 0x4020_0000, 0, 0, x86_env, null));
    // FMA: 2 * 3 + 1, and Arm's inf * 0 + qNaN.
    try testing.expectEqual(@as(u128, 0x40e0_0000), ext(.@"fp.fma", .i32, .i32, 0x4000_0000, 0x4040_0000, 0x3f80_0000, x86_env, null));
    try testing.expectEqual(@as(u128, 0x7fc0_0000), ext(.@"fp.fma", .i32, .i32, 0x7f80_0000, 0, 0x7fc0_0001, arm_env, &f));
    try testing.expectEqual(@as(u32, 1), f);
}

test "vector ops lane by lane" {
    var x: ir.ExtAux = .{ .esize = 0 };
    const ones: u128 = std.math.maxInt(u128);
    const seq: u128 = 0x0f0e0d0c_0b0a0908_07060504_03020100;
    try testing.expectEqual(@as(u128, 0), vecOp(.@"v.add", x, ones, @as(u128, 0x01010101_01010101_01010101_01010101)));
    try testing.expectEqual(@as(u128, 0x0807_0605_0403_0201), vecOp(.@"v.make", x, 0x0807_0605_0403_0201, 0));
    // TBL: out-of-range indexes give 0.
    try testing.expectEqual(seq & ~@as(u128, 0xff), vecOp(.@"v.tbl", x, seq, seq | 0xff));
    // EXT by 1 byte.
    x.imm = 1;
    try testing.expectEqual(@as(u128, 0xaa0f0e0d_0c0b0a09_08070605_04030201), vecOp(.@"v.ext", x, seq, 0xaa));
    // ZIP1 and UZP1 of 32-bit lanes.
    x = .{ .esize = 2 };
    const p: u128 = 0x00000003_00000002_00000001_00000000;
    const q: u128 = 0x00000013_00000012_00000011_00000010;
    try testing.expectEqual(@as(u128, 0x00000011_00000001_00000010_00000000), vecOp(.@"v.zip", x, p, q));
    try testing.expectEqual(@as(u128, 0x00000012_00000010_00000002_00000000), vecOp(.@"v.uzp", x, p, q));
    try testing.expectEqual(@as(u128, 0x00000012_00000002_00000010_00000000), vecOp(.@"v.trn", x, p, q));
    // Shifts past the width; signed compare.
    x.imm = 40;
    try testing.expectEqual(@as(u128, 0), vecOp(.@"v.shl", x, p, 0));
    try testing.expectEqual(ones, vecOp(.@"v.ashr", x, ones, 0));
    x.imm = @intFromEnum(ir.Pred.slt);
    try testing.expectEqual(@as(u128, 0xffff_ffff), vecOp(.@"v.cmp", x, 0xffff_ffff, 0));
    // Saturating narrow of 16-bit lanes to signed bytes, and widening back.
    x = .{ .esize = 1, .imm = 1 };
    try testing.expectEqual(@as(u128, 0x807f), vecOp(.@"v.narrow", x, 0x8000_7fff, 0));
    x = .{ .esize = 0, .imm = 1 };
    try testing.expectEqual(@as(u128, 0xff80_007f), vecOp(.@"v.widen", x, 0x807f, 0));
    // FP lanes: 1+1 in each of four binary32 lanes; binary32 to 64 of the high half.
    const one4: u128 = 0x3f800000_3f800000_3f800000_3f800000;
    try testing.expectEqual(@as(u128, 0x40000000_40000000_40000000_40000000), ext(.@"fp.add", .v128, .v128, one4, one4, 0, .{ .esize = 2 }, null));
    try testing.expectEqual(@as(u128, 0x3ff00000_00000000_3ff00000_00000000), ext(.@"fp.cvt", .v128, .v128, one4, 0, 0, .{ .esize = 2, .imm = 0x103 }, null));
    // fp.cmp's order set: less-or-equal.
    try testing.expectEqual(@as(u128, 0xffffffff_ffffffff_ffffffff_ffffffff), ext(.@"fp.cmp", .v128, .v128, one4, one4, 0, .{ .esize = 2, .imm = 0b0011 }, null));
}
