//! The x87's 80-bit extended format in software: a Zig port of the
//! `extF80` functions of Berkeley SoftFloat Release 3e, with the 8086
//! specialization (x87 NaN rules, tininess detected after rounding).
//!
//! It covers what an x87 needs, which is what v86 takes from SoftFloat:
//! add, sub, mul, div, rem, sqrt, roundToInt, the six comparisons, and the
//! conversions to and from i32, i64, f32, and f64. Rounding mode, rounding
//! precision (the x87's PC field), and the exception flags live in an `Env`
//! that each call takes, not in globals, so every vCPU keeps its own.
//!
//! The port follows SoftFloat's `SOFTFLOAT_FAST_INT64` sources, the ones
//! built for 64-bit hosts, with `u128` standing in for `struct uint128`.
//! Results match SoftFloat bit for bit: tools/testfloat.zig checks them
//! against Berkeley TestFloat's vectors (scripts/testfloat.sh), and the
//! tests below run a sample of those vectors (f80-vectors.txt).
//!
//! SoftFloat's notice, which its license asks every copy to keep:
//!
//! Copyright 2011, 2012, 2013, 2014, 2015, 2016, 2017 The Regents of the
//! University of California.  All rights reserved.
//!
//! Redistribution and use in source and binary forms, with or without
//! modification, are permitted provided that the following conditions are met:
//!
//!  1. Redistributions of source code must retain the above copyright notice,
//!     this list of conditions, and the following disclaimer.
//!
//!  2. Redistributions in binary form must reproduce the above copyright
//!     notice, this list of conditions, and the following disclaimer in the
//!     documentation and/or other materials provided with the distribution.
//!
//!  3. Neither the name of the University nor the names of its contributors
//!     may be used to endorse or promote products derived from this software
//!     without specific prior written permission.
//!
//! THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS "AS IS", AND ANY
//! EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
//! WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, ARE
//! DISCLAIMED.  IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE FOR
//! ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
//! DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
//! SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
//! CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
//! LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
//! OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
//! SUCH DAMAGE.

const std = @import("std");

/// An 80-bit extended value: the 64-bit significand, with its explicit
/// integer bit, and the sign and 15-bit biased exponent.
pub const F80 = extern struct {
    signif: u64,
    sign_exp: u16,

    pub const zero: F80 = .{ .sign_exp = 0, .signif = 0 };
    pub const one: F80 = .{ .sign_exp = 0x3FFF, .signif = 0x8000000000000000 };
    pub const inf: F80 = .{ .sign_exp = 0x7FFF, .signif = 0x8000000000000000 };
    /// The x87's "real indefinite", the default NaN.
    pub const default_nan: F80 = .{ .sign_exp = 0xFFFF, .signif = 0xC000000000000000 };

    /// The value with this 80-bit memory image (sign and exponent on top).
    pub fn fromBits(bits: u80) F80 {
        return .{ .sign_exp = @truncate(bits >> 64), .signif = @truncate(bits) };
    }

    pub fn toBits(a: F80) u80 {
        return @as(u80, a.sign_exp) << 64 | a.signif;
    }

    pub fn sign(a: F80) bool {
        return a.sign_exp >> 15 != 0;
    }

    pub fn exp(a: F80) u15 {
        return @truncate(a.sign_exp);
    }

    pub fn neg(a: F80) F80 {
        return .{ .sign_exp = a.sign_exp ^ 0x8000, .signif = a.signif };
    }

    pub fn abs(a: F80) F80 {
        return .{ .sign_exp = a.sign_exp & 0x7FFF, .signif = a.signif };
    }

    pub fn isNan(a: F80) bool {
        return isNanUI(a.sign_exp, a.signif);
    }

    pub fn isSignalingNan(a: F80) bool {
        return isSigNanUI(a.sign_exp, a.signif);
    }

    pub fn isInf(a: F80) bool {
        return a.sign_exp & 0x7FFF == 0x7FFF and a.signif & 0x7FFFFFFFFFFFFFFF == 0;
    }

    /// A denormal or pseudo-denormal: exponent zero and a nonzero
    /// significand. An x87 operand like this raises DE.
    pub fn isDenormal(a: F80) bool {
        return a.sign_exp & 0x7FFF == 0 and a.signif != 0;
    }
};

/// SoftFloat's rounding modes, numbered as SoftFloat and TestFloat number
/// them. `fromX87` maps the x87 control word's RC field.
pub const Rounding = enum(u3) {
    near_even = 0,
    min_mag = 1,
    min = 2,
    max = 3,
    near_max_mag = 4,

    pub fn fromX87(rc: u2) Rounding {
        return switch (rc) {
            0 => .near_even,
            1 => .min,
            2 => .max,
            3 => .min_mag,
        };
    }
};

/// The rounding precision of add, sub, mul, div, and sqrt: the x87
/// control word's PC field. The exponent range stays the extended one.
pub const Precision = enum {
    p32,
    p64,
    p80,

    pub fn fromX87(pc: u2) Precision {
        return switch (pc) {
            0 => .p32,
            2 => .p64,
            // 1 is reserved; the x87 rounds to 64 bits there too.
            1, 3 => .p80,
        };
    }
};

/// SoftFloat's exception flags, in its bit order. They accumulate until
/// the caller clears them.
pub const Flags = packed struct(u8) {
    inexact: bool = false,
    underflow: bool = false,
    overflow: bool = false,
    /// Division of a finite nonzero value by zero.
    infinite: bool = false,
    invalid: bool = false,
    pad: u3 = 0,

    pub fn any(f: Flags) bool {
        return @as(u8, @bitCast(f)) != 0;
    }

    /// The flags as x87 status word exception bits: IE, ZE, OE, UE, and PE.
    /// DE isn't SoftFloat's to raise; see `F80.isDenormal`.
    pub fn x87(f: Flags) u16 {
        return @as(u16, @intFromBool(f.invalid)) << 0 |
            @as(u16, @intFromBool(f.infinite)) << 2 |
            @as(u16, @intFromBool(f.overflow)) << 3 |
            @as(u16, @intFromBool(f.underflow)) << 4 |
            @as(u16, @intFromBool(f.inexact)) << 5;
    }
};

/// The floating-point environment: SoftFloat's `softfloat_roundingMode`,
/// `extF80_roundingPrecision`, and `softfloat_exceptionFlags`.
pub const Env = struct {
    rounding: Rounding = .near_even,
    precision: Precision = .p80,
    flags: Flags = .{},

    // Arithmetic.

    pub fn add(env: *Env, a: F80, b: F80) F80 {
        if (a.sign() == b.sign()) return env.addMags(a.sign_exp, a.signif, b.sign_exp, b.signif, a.sign());
        return env.subMags(a.sign_exp, a.signif, b.sign_exp, b.signif, a.sign());
    }

    pub fn sub(env: *Env, a: F80, b: F80) F80 {
        if (a.sign() == b.sign()) return env.subMags(a.sign_exp, a.signif, b.sign_exp, b.signif, a.sign());
        return env.addMags(a.sign_exp, a.signif, b.sign_exp, b.signif, a.sign());
    }

    pub fn mul(env: *Env, a: F80, b: F80) F80 {
        const sign_z = a.sign() != b.sign();
        var exp_a: i32 = a.exp();
        var sig_a = a.signif;
        var exp_b: i32 = b.exp();
        var sig_b = b.signif;
        if (exp_a == 0x7FFF) {
            if (sig_a & 0x7FFFFFFFFFFFFFFF != 0 or (exp_b == 0x7FFF and sig_b & 0x7FFFFFFFFFFFFFFF != 0))
                return env.propagateNan(a, b);
            return env.infArg(sign_z, @as(u64, @intCast(exp_b)) | sig_b);
        }
        if (exp_b == 0x7FFF) {
            if (sig_b & 0x7FFFFFFFFFFFFFFF != 0) return env.propagateNan(a, b);
            return env.infArg(sign_z, @as(u64, @intCast(exp_a)) | sig_a);
        }
        if (exp_a == 0) exp_a = 1;
        if (sig_a & 0x8000000000000000 == 0) {
            if (sig_a == 0) return pack(sign_z, 0, 0);
            const n = normSubnormalSig(sig_a);
            exp_a += n.exp;
            sig_a = n.sig;
        }
        if (exp_b == 0) exp_b = 1;
        if (sig_b & 0x8000000000000000 == 0) {
            if (sig_b == 0) return pack(sign_z, 0, 0);
            const n = normSubnormalSig(sig_b);
            exp_b += n.exp;
            sig_b = n.sig;
        }
        var exp_z = exp_a + exp_b - 0x3FFE;
        var sig128_z = @as(u128, sig_a) * sig_b;
        if (sig128_z < 1 << 127) {
            exp_z -= 1;
            sig128_z <<= 1;
        }
        return env.roundPack(sign_z, exp_z, hi(sig128_z), lo(sig128_z), env.precision);
    }

    fn infArg(env: *Env, sign_z: bool, mag_bits: u64) F80 {
        if (mag_bits == 0) {
            env.flags.invalid = true;
            return F80.default_nan;
        }
        return pack(sign_z, 0x7FFF, 0x8000000000000000);
    }

    pub fn div(env: *Env, a: F80, b: F80) F80 {
        const sign_z = a.sign() != b.sign();
        var exp_a: i32 = a.exp();
        var sig_a = a.signif;
        var exp_b: i32 = b.exp();
        var sig_b = b.signif;
        if (exp_a == 0x7FFF) {
            if (sig_a & 0x7FFFFFFFFFFFFFFF != 0) return env.propagateNan(a, b);
            if (exp_b == 0x7FFF) {
                if (sig_b & 0x7FFFFFFFFFFFFFFF != 0) return env.propagateNan(a, b);
                return env.invalid();
            }
            return pack(sign_z, 0x7FFF, 0x8000000000000000);
        }
        if (exp_b == 0x7FFF) {
            if (sig_b & 0x7FFFFFFFFFFFFFFF != 0) return env.propagateNan(a, b);
            return pack(sign_z, 0, 0);
        }
        if (exp_b == 0) exp_b = 1;
        if (sig_b & 0x8000000000000000 == 0) {
            if (sig_b == 0) {
                if (sig_a == 0) return env.invalid();
                env.flags.infinite = true;
                return pack(sign_z, 0x7FFF, 0x8000000000000000);
            }
            const n = normSubnormalSig(sig_b);
            exp_b += n.exp;
            sig_b = n.sig;
        }
        if (exp_a == 0) exp_a = 1;
        if (sig_a & 0x8000000000000000 == 0) {
            if (sig_a == 0) return pack(sign_z, 0, 0);
            const n = normSubnormalSig(sig_a);
            exp_a += n.exp;
            sig_a = n.sig;
        }
        var exp_z = exp_a - exp_b + 0x3FFF;
        var r: u128 = undefined;
        if (sig_a < sig_b) {
            exp_z -= 1;
            r = @as(u128, sig_a) << 32;
        } else {
            r = @as(u128, sig_a) << 31;
        }
        const recip32 = approxRecip32_1(@truncate(sig_b >> 32));
        var sig_z: u64 = 0;
        var ix: i32 = 2;
        // SoftFloat's q is uint_fast32_t, 64 bits on the hosts it's tested on.
        var q: u64 = undefined;
        while (true) {
            const q64 = @as(u64, @as(u32, @truncate(hi(r) >> 2))) * recip32;
            q = (q64 +% 0x80000000) >> 32;
            ix -= 1;
            if (ix < 0) break;
            r <<= 29;
            r -%= mul64ByShifted32To128(sig_b, @truncate(q));
            if (neg128(r)) {
                q -%= 1;
                r +%= @as(u128, sig_b) << 32;
            }
            sig_z = (sig_z << 29) +% q;
        }
        if ((q +% 1) & 0x3FFFFF < 2) {
            r <<= 29;
            r -%= mul64ByShifted32To128(sig_b, @truncate(q));
            const term = @as(u128, sig_b) << 32;
            if (neg128(r)) {
                q -%= 1;
                r +%= term;
            } else if (term <= r) {
                q +%= 1;
                r -%= term;
            }
            if (r != 0) q |= 1;
        }
        sig_z = (sig_z << 6) +% (q >> 23);
        const sig_z_extra = q << 41;
        return env.roundPack(sign_z, exp_z, sig_z, sig_z_extra, env.precision);
    }

    /// The IEEE remainder, a - n*b with n the integer nearest a/b (ties to
    /// even), exact and so independent of rounding mode and precision. The
    /// x87's FPREM1 computes it, given enough iterations.
    pub fn rem(env: *Env, a: F80, b: F80) F80 {
        const sign_a = a.sign();
        var exp_a: i32 = a.exp();
        var sig_a = a.signif;
        var exp_b: i32 = b.exp();
        var sig_b = b.signif;
        if (exp_a == 0x7FFF) {
            if (sig_a & 0x7FFFFFFFFFFFFFFF != 0 or (exp_b == 0x7FFF and sig_b & 0x7FFFFFFFFFFFFFFF != 0))
                return env.propagateNan(a, b);
            return env.invalid();
        }
        if (exp_b == 0x7FFF) {
            if (sig_b & 0x7FFFFFFFFFFFFFFF != 0) return env.propagateNan(a, b);
            // b is an infinity. Doubling exp_b makes exp_diff below less
            // than -1, which returns a canonicalized a.
            exp_b += exp_b;
        }
        if (exp_b == 0) exp_b = 1;
        if (sig_b & 0x8000000000000000 == 0) {
            if (sig_b == 0) return env.invalid();
            const n = normSubnormalSig(sig_b);
            exp_b += n.exp;
            sig_b = n.sig;
        }
        if (exp_a == 0) exp_a = 1;
        if (sig_a & 0x8000000000000000 == 0) {
            if (sig_a == 0) return copyA(sign_a, 0, sig_a);
            const n = normSubnormalSig(sig_a);
            exp_a += n.exp;
            sig_a = n.sig;
        }
        var exp_diff = exp_a - exp_b;
        if (exp_diff < -1) return copyA(sign_a, exp_a, sig_a);
        var r: u128 = @as(u128, sig_a) << 32;
        var shifted_sig_b: u128 = @as(u128, sig_b) << 32;
        var q: u64 = undefined;
        var alt_rem: u128 = undefined;
        var have_alt = false;
        if (exp_diff < 1) {
            if (exp_diff != 0) {
                exp_b -= 1;
                shifted_sig_b = @as(u128, sig_b) << 33;
                q = 0;
            } else {
                q = @intFromBool(sig_b <= sig_a);
                if (q != 0) r -%= shifted_sig_b;
            }
        } else {
            const recip32 = approxRecip32_1(@truncate(sig_b >> 32));
            exp_diff -= 30;
            var q64: u64 = undefined;
            while (true) {
                q64 = @as(u64, @as(u32, @truncate(hi(r) >> 2))) * recip32;
                if (exp_diff < 0) break;
                q = (q64 +% 0x80000000) >> 32;
                r <<= 29;
                r -%= mul64ByShifted32To128(sig_b, @truncate(q));
                if (neg128(r)) r +%= shifted_sig_b;
                exp_diff -= 29;
            }
            // (exp_diff can't be less than -29 here.)
            q = @as(u32, @truncate(q64 >> 32)) >> @as(u5, @truncate(@as(u32, @bitCast(~exp_diff))));
            r <<= @intCast(exp_diff + 30);
            r -%= mul64ByShifted32To128(sig_b, @truncate(q));
            if (neg128(r)) {
                alt_rem = r +% shifted_sig_b;
                have_alt = true;
            }
        }
        if (!have_alt) {
            while (true) {
                alt_rem = r;
                q +%= 1;
                r -%= shifted_sig_b;
                if (neg128(r)) break;
            }
        }
        const mean_rem = r +% alt_rem;
        if (neg128(mean_rem) or (mean_rem == 0 and q & 1 != 0)) r = alt_rem;
        var sign_rem = sign_a;
        if (neg128(r)) {
            sign_rem = !sign_rem;
            r = 0 -% r;
        }
        return env.normRoundPack(sign_rem, if (r != 0) exp_b + 32 else 0, hi(r), lo(r), .p80);
    }

    fn copyA(sign_a: bool, exp_a_in: i32, sig_a_in: u64) F80 {
        var exp_a = exp_a_in;
        var sig_a = sig_a_in;
        if (exp_a < 1) {
            sig_a >>= @intCast(1 - exp_a);
            exp_a = 0;
        }
        return pack(sign_a, exp_a, sig_a);
    }

    pub fn sqrt(env: *Env, a: F80) F80 {
        const sign_a = a.sign();
        var exp_a: i32 = a.exp();
        var sig_a = a.signif;
        if (exp_a == 0x7FFF) {
            if (sig_a & 0x7FFFFFFFFFFFFFFF != 0) return env.propagateNan(a, F80.zero);
            if (!sign_a) return a;
            return env.invalid();
        }
        if (sign_a) {
            if (sig_a == 0) return pack(sign_a, 0, 0);
            return env.invalid();
        }
        if (exp_a == 0) exp_a = 1;
        if (sig_a & 0x8000000000000000 == 0) {
            if (sig_a == 0) return pack(sign_a, 0, 0);
            const n = normSubnormalSig(sig_a);
            exp_a += n.exp;
            sig_a = n.sig;
        }
        // (sig32_z is a lower bound on the square root of sig32_a, which
        // makes it one on the square root of sig_a too.)
        const exp_z = ((exp_a - 0x3FFF) >> 1) + 0x3FFF;
        const odd: u1 = @intCast(exp_a & 1);
        const sig32_a: u32 = @truncate(sig_a >> 32);
        const recip_sqrt32 = approxRecipSqrt32_1(odd, sig32_a);
        var sig32_z: u64 = (@as(u64, sig32_a) * recip_sqrt32) >> 32;
        var r: u128 = undefined;
        if (odd != 0) {
            sig32_z >>= 1;
            r = @as(u128, sig_a) << 61;
        } else {
            r = @as(u128, sig_a) << 62;
        }
        r -%= @as(u128, sig32_z *% sig32_z) << 64;
        var q: u64 = (@as(u64, @as(u32, @truncate(hi(r) >> 2))) * recip_sqrt32) >> 32;
        var x64: u64 = sig32_z << 32;
        var sig_z: u64 = x64 +% (q << 3);
        const y = r << 29;
        // (Repeating this loop is a rare occurrence.)
        while (true) {
            r = y -% mul64ByShifted32To128(x64 +% sig_z, @truncate(q));
            if (!neg128(r)) break;
            q -%= 1;
            sig_z -%= 1 << 3;
        }
        q = ((hi(r) >> 2) *% recip_sqrt32 >> 32) +% 2;
        x64 = sig_z;
        sig_z = (sig_z << 1) +% (q >> 25);
        var sig_z_extra: u64 = q << 39;
        if (q & 0xFFFFFF <= 2) {
            q &= ~@as(u64, 0xFFFF);
            sig_z_extra = q << 39;
            var term = mul64ByShifted32To128(x64 +% (q >> 27), @truncate(q));
            x64 = @as(u64, @as(u32, @truncate(q << 5))) * @as(u32, @truncate(q));
            term +%= x64;
            r <<= 28;
            r -%= term;
            if (neg128(r)) {
                if (sig_z_extra == 0) sig_z -%= 1;
                sig_z_extra -%= 1;
            } else if (r != 0) {
                sig_z_extra |= 1;
            }
        }
        return env.roundPack(false, exp_z, sig_z, sig_z_extra, env.precision);
    }

    /// Rounds to an integral value in `mode` (not env.rounding), at full
    /// precision. `exact` raises inexact when that changes the value, as
    /// FRNDINT does.
    pub fn roundToInt(env: *Env, a: F80, mode: Rounding, exact: bool) F80 {
        const sign_ui: u16 = a.sign_exp & 0x8000;
        const negative = sign_ui != 0;
        var exp: i32 = a.exp();
        var sig_a = a.signif;
        if (sig_a & 0x8000000000000000 == 0 and exp != 0x7FFF) {
            if (sig_a == 0) return .{ .sign_exp = sign_ui, .signif = 0 };
            const n = normSubnormalSig(sig_a);
            exp += n.exp;
            sig_a = n.sig;
        }
        if (0x403E <= exp) {
            if (exp == 0x7FFF) {
                if (sig_a & 0x7FFFFFFFFFFFFFFF != 0)
                    return env.propagateNanUI(a.sign_exp, sig_a, 0, 0);
                return .{ .sign_exp = sign_ui | 0x7FFF, .signif = 0x8000000000000000 };
            }
            return .{ .sign_exp = sign_ui | @as(u16, @intCast(exp)), .signif = sig_a };
        }
        if (exp <= 0x3FFE) {
            if (exact) env.flags.inexact = true;
            const mag1 = switch (mode) {
                .near_even => sig_a & 0x7FFFFFFFFFFFFFFF != 0 and exp == 0x3FFE,
                .near_max_mag => exp == 0x3FFE,
                .min => negative,
                .max => !negative,
                .min_mag => false,
            };
            if (mag1) return .{ .sign_exp = sign_ui | 0x3FFF, .signif = 0x8000000000000000 };
            return .{ .sign_exp = sign_ui, .signif = 0 };
        }
        var ui_z64: u16 = sign_ui | @as(u16, @intCast(exp));
        const last_bit_mask = @as(u64, 1) << @intCast(0x403E - exp);
        const round_bits_mask = last_bit_mask - 1;
        var sig_z = sig_a;
        if (mode == .near_max_mag) {
            sig_z +%= last_bit_mask >> 1;
        } else if (mode == .near_even) {
            sig_z +%= last_bit_mask >> 1;
            if (sig_z & round_bits_mask == 0) sig_z &= ~last_bit_mask;
        } else if (mode == (if (negative) Rounding.min else Rounding.max)) {
            sig_z +%= round_bits_mask;
        }
        sig_z &= ~round_bits_mask;
        if (sig_z == 0) {
            ui_z64 += 1;
            sig_z = 0x8000000000000000;
        }
        if (sig_z != sig_a and exact) env.flags.inexact = true;
        return .{ .sign_exp = ui_z64, .signif = sig_z };
    }

    // Comparisons. The plain ones and eq_signaling raise invalid on any
    // NaN; eq and the _quiet ones only on a signaling NaN.

    pub fn eq(env: *Env, a: F80, b: F80) bool {
        if (a.isNan() or b.isNan()) {
            if (a.isSignalingNan() or b.isSignalingNan()) env.flags.invalid = true;
            return false;
        }
        return eqBits(a, b);
    }

    pub fn eqSignaling(env: *Env, a: F80, b: F80) bool {
        if (a.isNan() or b.isNan()) {
            env.flags.invalid = true;
            return false;
        }
        return eqBits(a, b);
    }

    pub fn le(env: *Env, a: F80, b: F80) bool {
        if (a.isNan() or b.isNan()) {
            env.flags.invalid = true;
            return false;
        }
        return leBits(a, b);
    }

    pub fn leQuiet(env: *Env, a: F80, b: F80) bool {
        if (a.isNan() or b.isNan()) {
            if (a.isSignalingNan() or b.isSignalingNan()) env.flags.invalid = true;
            return false;
        }
        return leBits(a, b);
    }

    pub fn lt(env: *Env, a: F80, b: F80) bool {
        if (a.isNan() or b.isNan()) {
            env.flags.invalid = true;
            return false;
        }
        return ltBits(a, b);
    }

    pub fn ltQuiet(env: *Env, a: F80, b: F80) bool {
        if (a.isNan() or b.isNan()) {
            if (a.isSignalingNan() or b.isSignalingNan()) env.flags.invalid = true;
            return false;
        }
        return ltBits(a, b);
    }

    fn eqBits(a: F80, b: F80) bool {
        return a.signif == b.signif and
            (a.sign_exp == b.sign_exp or (a.signif == 0 and (a.sign_exp | b.sign_exp) & 0x7FFF == 0));
    }

    fn leBits(a: F80, b: F80) bool {
        const sa = a.sign();
        if (sa != b.sign()) return sa or ((a.sign_exp | b.sign_exp) & 0x7FFF | a.signif | b.signif) == 0;
        return (a.sign_exp == b.sign_exp and a.signif == b.signif) or (sa != lt128(a, b));
    }

    fn ltBits(a: F80, b: F80) bool {
        const sa = a.sign();
        if (sa != b.sign()) return sa and ((a.sign_exp | b.sign_exp) & 0x7FFF | a.signif | b.signif) != 0;
        return (a.sign_exp != b.sign_exp or a.signif != b.signif) and (sa != lt128(a, b));
    }

    fn lt128(a: F80, b: F80) bool {
        return a.sign_exp < b.sign_exp or (a.sign_exp == b.sign_exp and a.signif < b.signif);
    }

    // Conversions to integers. Out of range and NaN give the x87's
    // "integer indefinite" (the most negative value) and raise invalid.

    /// To i32, rounding in `mode`. `exact` raises inexact on a fraction.
    pub fn toI32(env: *Env, a: F80, mode: Rounding, exact: bool) i32 {
        const sign = a.sign();
        const exp: i32 = a.exp();
        var sig = a.signif;
        // (8086's i32_fromNaN is the overflow value, so a NaN needs no
        // case of its own: it overflows.)
        var shift_dist = 0x4032 - exp;
        if (shift_dist <= 0) shift_dist = 1;
        sig = shiftRightJam64(sig, @intCast(shift_dist));
        return env.roundToI32(sign, sig, mode, exact);
    }

    /// To i64, rounding in `mode`. `exact` raises inexact on a fraction.
    pub fn toI64(env: *Env, a: F80, mode: Rounding, exact: bool) i64 {
        const sign = a.sign();
        const exp: i32 = a.exp();
        var sig = a.signif;
        const shift_dist = 0x403E - exp;
        var sig_extra: u64 = 0;
        if (shift_dist <= 0) {
            if (shift_dist != 0) {
                env.flags.invalid = true;
                return std.math.minInt(i64);
            }
        } else {
            const r = shiftRightJam64Extra(sig, 0, @intCast(shift_dist));
            sig = r.v;
            sig_extra = r.extra;
        }
        return env.roundToI64(sign, sig, sig_extra, mode, exact);
    }

    /// To i32, truncating (FISTTP).
    pub fn toI32MinMag(env: *Env, a: F80, exact: bool) i32 {
        const exp: i32 = a.exp();
        const sig = a.signif;
        const shift_dist = 0x403E - exp;
        if (64 <= shift_dist) {
            if (exact and (exp != 0 or sig != 0)) env.flags.inexact = true;
            return 0;
        }
        const sign = a.sign();
        if (shift_dist < 33) {
            if (a.sign_exp == 0x8000 | 0x401E and sig < 0x8000000100000000) {
                if (exact and sig & 0xFFFFFFFF != 0) env.flags.inexact = true;
                return std.math.minInt(i32);
            }
            env.flags.invalid = true;
            return std.math.minInt(i32);
        }
        const abs_z = sig >> @intCast(shift_dist);
        if (exact and (abs_z & 0xFFFFFFFF) << @intCast(shift_dist) != sig) env.flags.inexact = true;
        const z: u32 = @truncate(abs_z);
        return @bitCast(if (sign) 0 -% z else z);
    }

    /// To i64, truncating (FISTTP).
    pub fn toI64MinMag(env: *Env, a: F80, exact: bool) i64 {
        const exp: i32 = a.exp();
        const sig = a.signif;
        const shift_dist = 0x403E - exp;
        if (64 <= shift_dist) {
            if (exact and (exp != 0 or sig != 0)) env.flags.inexact = true;
            return 0;
        }
        const sign = a.sign();
        if (shift_dist <= 0) {
            if (a.sign_exp == 0x8000 | 0x403E and sig == 0x8000000000000000) return std.math.minInt(i64);
            env.flags.invalid = true;
            return std.math.minInt(i64);
        }
        const abs_z = sig >> @intCast(shift_dist);
        if (exact and sig << @intCast(64 - shift_dist) != 0) env.flags.inexact = true;
        return @bitCast(if (sign) 0 -% abs_z else abs_z);
    }

    fn roundToI32(env: *Env, sign: bool, sig_in: u64, mode: Rounding, exact: bool) i32 {
        var sig = sig_in;
        var round_increment: u64 = 0x800;
        if (mode != .near_max_mag and mode != .near_even) {
            round_increment = 0;
            if (if (sign) mode == .min else mode == .max) round_increment = 0xFFF;
        }
        const round_bits = sig & 0xFFF;
        sig +%= round_increment;
        if (sig & 0xFFFFF00000000000 != 0) return env.invalidI32();
        var sig32: u32 = @truncate(sig >> 12);
        if (round_bits == 0x800 and mode == .near_even) sig32 &= ~@as(u32, 1);
        const z: i32 = @bitCast(if (sign) 0 -% sig32 else sig32);
        if (z != 0 and ((z < 0) != sign)) return env.invalidI32();
        if (round_bits != 0 and exact) env.flags.inexact = true;
        return z;
    }

    fn invalidI32(env: *Env) i32 {
        env.flags.invalid = true;
        return std.math.minInt(i32);
    }

    fn roundToI64(env: *Env, sign: bool, sig_in: u64, sig_extra: u64, mode: Rounding, exact: bool) i64 {
        var sig = sig_in;
        const increment = if (mode == .near_max_mag or mode == .near_even)
            0x8000000000000000 <= sig_extra
        else
            sig_extra != 0 and (if (sign) mode == .min else mode == .max);
        if (increment) {
            sig +%= 1;
            if (sig == 0) {
                env.flags.invalid = true;
                return std.math.minInt(i64);
            }
            if (sig_extra == 0x8000000000000000 and mode == .near_even) sig &= ~@as(u64, 1);
        }
        const z: i64 = @bitCast(if (sign) 0 -% sig else sig);
        if (z != 0 and ((z < 0) != sign)) {
            env.flags.invalid = true;
            return std.math.minInt(i64);
        }
        if (sig_extra != 0 and exact) env.flags.inexact = true;
        return z;
    }

    // Conversions between formats. Narrowing rounds in env.rounding and
    // ignores env.precision; widening is exact.

    /// To an f32 bit pattern.
    pub fn toF32(env: *Env, a: F80) u32 {
        const sign = a.sign();
        var exp: i32 = a.exp();
        const sig = a.signif;
        if (exp == 0x7FFF) {
            if (sig & 0x7FFFFFFFFFFFFFFF != 0) {
                const n = env.toCommonNan(a);
                return @as(u32, @intFromBool(n.sign)) << 31 | 0x7FC00000 | @as(u32, @truncate(n.v64 >> 41));
            }
            return packF32(sign, 0xFF, 0);
        }
        const sig32: u32 = @truncate(shortShiftRightJam64(sig, 33));
        if (exp == 0 and sig32 == 0) return packF32(sign, 0, 0);
        exp -= 0x3F81;
        return env.roundPackToF32(sign, exp, sig32);
    }

    /// To an f64 bit pattern.
    pub fn toF64(env: *Env, a: F80) u64 {
        const sign = a.sign();
        var exp: i32 = a.exp();
        var sig = a.signif;
        if (exp == 0 and sig == 0) return packF64(sign, 0, 0);
        if (exp == 0x7FFF) {
            if (sig & 0x7FFFFFFFFFFFFFFF != 0) {
                const n = env.toCommonNan(a);
                return @as(u64, @intFromBool(n.sign)) << 63 | 0x7FF8000000000000 | n.v64 >> 12;
            }
            return packF64(sign, 0x7FF, 0);
        }
        sig = shortShiftRightJam64(sig, 1);
        exp -= 0x3C01;
        return env.roundPackToF64(sign, exp, sig);
    }

    /// From an f32 bit pattern. Raises invalid on a signaling NaN.
    pub fn fromF32(env: *Env, a: u32) F80 {
        const sign = a >> 31 != 0;
        var exp: i32 = @intCast(a >> 23 & 0xFF);
        var frac: u32 = a & 0x007FFFFF;
        if (exp == 0xFF) {
            if (frac != 0) {
                if (a & 0x7FC00000 == 0x7F800000 and a & 0x003FFFFF != 0) env.flags.invalid = true;
                return fromCommonNan(.{ .sign = sign, .v64 = @as(u64, a) << 41 });
            }
            return pack(sign, 0x7FFF, 0x8000000000000000);
        }
        if (exp == 0) {
            if (frac == 0) return pack(sign, 0, 0);
            const shift: u5 = @intCast(@clz(frac) - 8);
            exp = 1 - @as(i32, shift);
            frac <<= shift;
        }
        return pack(sign, exp + 0x3F80, @as(u64, frac | 0x00800000) << 40);
    }

    /// From an f64 bit pattern. Raises invalid on a signaling NaN.
    pub fn fromF64(env: *Env, a: u64) F80 {
        const sign = a >> 63 != 0;
        var exp: i32 = @intCast(a >> 52 & 0x7FF);
        var frac: u64 = a & 0x000FFFFFFFFFFFFF;
        if (exp == 0x7FF) {
            if (frac != 0) {
                if (a & 0x7FF8000000000000 == 0x7FF0000000000000 and a & 0x0007FFFFFFFFFFFF != 0) env.flags.invalid = true;
                return fromCommonNan(.{ .sign = sign, .v64 = a << 12 });
            }
            return pack(sign, 0x7FFF, 0x8000000000000000);
        }
        if (exp == 0) {
            if (frac == 0) return pack(sign, 0, 0);
            const shift: u6 = @intCast(@clz(frac) - 11);
            exp = 1 - @as(i32, shift);
            frac <<= shift;
        }
        return pack(sign, exp + 0x3C00, (frac | 0x0010000000000000) << 11);
    }

    // The shared rounding and NaN machinery.

    fn invalid(env: *Env) F80 {
        env.flags.invalid = true;
        return F80.default_nan;
    }

    fn addMags(env: *Env, ui_a64: u16, ui_a0: u64, ui_b64: u16, ui_b0: u64, sign_z: bool) F80 {
        const exp_a: i32 = ui_a64 & 0x7FFF;
        var sig_a = ui_a0;
        const exp_b: i32 = ui_b64 & 0x7FFF;
        var sig_b = ui_b0;
        var exp_diff = exp_a - exp_b;
        var exp_z: i32 = undefined;
        var sig_z: u64 = undefined;
        var sig_z_extra: u64 = 0;
        if (exp_diff == 0) {
            if (exp_a == 0x7FFF) {
                if ((sig_a | sig_b) & 0x7FFFFFFFFFFFFFFF != 0) return env.propagateNanUI(ui_a64, ui_a0, ui_b64, ui_b0);
                return .{ .sign_exp = ui_a64, .signif = ui_a0 };
            }
            sig_z = sig_a +% sig_b;
            if (exp_a == 0) {
                const n = normSubnormalSig(sig_z);
                return env.roundPack(sign_z, n.exp + 1, n.sig, 0, env.precision);
            }
            exp_z = exp_a;
            return env.addShiftRight1(sign_z, exp_z, sig_z, sig_z_extra);
        }
        aligned: {
            if (exp_diff < 0) {
                if (exp_b == 0x7FFF) {
                    if (sig_b & 0x7FFFFFFFFFFFFFFF != 0) return env.propagateNanUI(ui_a64, ui_a0, ui_b64, ui_b0);
                    return pack(sign_z, 0x7FFF, ui_b0);
                }
                exp_z = exp_b;
                if (exp_a == 0) {
                    exp_diff += 1;
                    if (exp_diff == 0) break :aligned;
                }
                const r = shiftRightJam64Extra(sig_a, 0, @intCast(-exp_diff));
                sig_a = r.v;
                sig_z_extra = r.extra;
            } else {
                if (exp_a == 0x7FFF) {
                    if (sig_a & 0x7FFFFFFFFFFFFFFF != 0) return env.propagateNanUI(ui_a64, ui_a0, ui_b64, ui_b0);
                    return .{ .sign_exp = ui_a64, .signif = ui_a0 };
                }
                exp_z = exp_a;
                if (exp_b == 0) {
                    exp_diff -= 1;
                    if (exp_diff == 0) break :aligned;
                }
                const r = shiftRightJam64Extra(sig_b, 0, @intCast(exp_diff));
                sig_b = r.v;
                sig_z_extra = r.extra;
            }
        }
        sig_z = sig_a +% sig_b;
        if (sig_z & 0x8000000000000000 != 0) return env.roundPack(sign_z, exp_z, sig_z, sig_z_extra, env.precision);
        return env.addShiftRight1(sign_z, exp_z, sig_z, sig_z_extra);
    }

    fn addShiftRight1(env: *Env, sign_z: bool, exp_z: i32, sig_z: u64, sig_z_extra: u64) F80 {
        // shortShiftRightJam64Extra by 1, with the carry out of the add as
        // the new integer bit.
        const v = sig_z >> 1 | 0x8000000000000000;
        const extra = sig_z << 63 | @intFromBool(sig_z_extra != 0);
        return env.roundPack(sign_z, exp_z + 1, v, extra, env.precision);
    }

    fn subMags(env: *Env, ui_a64: u16, ui_a0: u64, ui_b64: u16, ui_b0: u64, sign_in: bool) F80 {
        var sign_z = sign_in;
        const exp_a: i32 = ui_a64 & 0x7FFF;
        var sig_a = ui_a0;
        const exp_b: i32 = ui_b64 & 0x7FFF;
        var sig_b = ui_b0;
        var exp_diff = exp_a - exp_b;
        var exp_z: i32 = undefined;
        var sig_extra: u64 = 0;
        var sig128: u128 = undefined;
        if (exp_diff > 0) {
            // expABigger
            if (exp_a == 0x7FFF) {
                if (sig_a & 0x7FFFFFFFFFFFFFFF != 0) return env.propagateNanUI(ui_a64, ui_a0, ui_b64, ui_b0);
                return .{ .sign_exp = ui_a64, .signif = ui_a0 };
            }
            if (exp_b == 0) exp_diff -= 1;
            if (exp_diff != 0) {
                const r = shiftRightJam128(@as(u128, sig_b) << 64, @intCast(exp_diff));
                sig_b = hi(r);
                sig_extra = lo(r);
            }
            exp_z = exp_a;
            sig128 = (@as(u128, sig_a) << 64) -% (@as(u128, sig_b) << 64 | sig_extra);
        } else if (exp_diff < 0) {
            // expBBigger
            if (exp_b == 0x7FFF) {
                if (sig_b & 0x7FFFFFFFFFFFFFFF != 0) return env.propagateNanUI(ui_a64, ui_a0, ui_b64, ui_b0);
                return pack(!sign_z, 0x7FFF, 0x8000000000000000);
            }
            if (exp_a == 0) exp_diff += 1;
            if (exp_diff != 0) {
                const r = shiftRightJam128(@as(u128, sig_a) << 64, @intCast(-exp_diff));
                sig_a = hi(r);
                sig_extra = lo(r);
            }
            exp_z = exp_b;
            sign_z = !sign_z;
            sig128 = (@as(u128, sig_b) << 64) -% (@as(u128, sig_a) << 64 | sig_extra);
        } else {
            if (exp_a == 0x7FFF) {
                if ((sig_a | sig_b) & 0x7FFFFFFFFFFFFFFF != 0) return env.propagateNanUI(ui_a64, ui_a0, ui_b64, ui_b0);
                return env.invalid();
            }
            exp_z = if (exp_a == 0) 1 else exp_a;
            if (sig_b < sig_a) {
                sig128 = (@as(u128, sig_a) << 64) -% (@as(u128, sig_b) << 64);
            } else if (sig_a < sig_b) {
                sign_z = !sign_z;
                sig128 = (@as(u128, sig_b) << 64) -% (@as(u128, sig_a) << 64);
            } else {
                return pack(env.rounding == .min, 0, 0);
            }
        }
        return env.normRoundPack(sign_z, exp_z, hi(sig128), lo(sig128), env.precision);
    }

    fn normRoundPack(env: *Env, sign: bool, exp_in: i32, sig_in: u64, sig_extra_in: u64, precision: Precision) F80 {
        var exp = exp_in;
        var sig = sig_in;
        var sig_extra = sig_extra_in;
        if (sig == 0) {
            exp -= 64;
            sig = sig_extra;
            sig_extra = 0;
        }
        const shift = @clz(sig);
        exp -= @as(i32, shift);
        if (shift != 0 and shift != 64) {
            const x = (@as(u128, sig) << 64 | sig_extra) << shift;
            sig = hi(x);
            sig_extra = lo(x);
        }
        return env.roundPack(sign, exp, sig, sig_extra, precision);
    }

    /// softfloat_roundPackToExtF80: rounds sig.sig_extra (a significand
    /// with its binary point after sig's top bit, scaled by 2^(exp-0x3FFF))
    /// to `precision` in env.rounding, raising flags.
    fn roundPack(env: *Env, sign: bool, exp_in: i32, sig_in: u64, sig_extra_in: u64, precision: Precision) F80 {
        var exp = exp_in;
        var sig = sig_in;
        var sig_extra = sig_extra_in;
        const mode = env.rounding;
        const near_even = mode == .near_even;
        const toward = mode == (if (sign) Rounding.min else Rounding.max);
        if (precision != .p80) {
            var round_increment: u64 = if (precision == .p64) 0x400 else 0x0000008000000000;
            var round_mask: u64 = if (precision == .p64) 0x7FF else 0x000000FFFFFFFFFF;
            sig |= @intFromBool(sig_extra != 0);
            if (!near_even and mode != .near_max_mag) round_increment = if (toward) round_mask else 0;
            var round_bits = sig & round_mask;
            if (0x7FFD <= @as(u32, @bitCast(exp -% 1))) {
                if (exp <= 0) {
                    const is_tiny = exp < 0 or sig <= sig +% round_increment;
                    sig = shiftRightJam64(sig, @intCast(1 - exp));
                    round_bits = sig & round_mask;
                    if (round_bits != 0) {
                        if (is_tiny) env.flags.underflow = true;
                        env.flags.inexact = true;
                    }
                    sig +%= round_increment;
                    exp = @intFromBool(sig & 0x8000000000000000 != 0);
                    round_increment = round_mask + 1;
                    if (near_even and round_bits << 1 == round_increment) round_mask |= round_increment;
                    sig &= ~round_mask;
                    return pack(sign, exp, sig);
                }
                if (0x7FFE < exp or (exp == 0x7FFE and sig +% round_increment < sig))
                    return env.overflow(sign, round_mask);
            }
            if (round_bits != 0) env.flags.inexact = true;
            sig +%= round_increment;
            if (sig < round_increment) {
                exp += 1;
                sig = 0x8000000000000000;
            }
            round_increment = round_mask + 1;
            if (near_even and round_bits << 1 == round_increment) round_mask |= round_increment;
            sig &= ~round_mask;
            return pack(sign, exp, sig);
        }
        var do_increment = 0x8000000000000000 <= sig_extra;
        if (!near_even and mode != .near_max_mag) do_increment = toward and sig_extra != 0;
        if (0x7FFD <= @as(u32, @bitCast(exp -% 1))) {
            if (exp <= 0) {
                const is_tiny = exp < 0 or !do_increment or sig < 0xFFFFFFFFFFFFFFFF;
                const r = shiftRightJam64Extra(sig, sig_extra, @intCast(1 - exp));
                exp = 0;
                sig = r.v;
                sig_extra = r.extra;
                if (sig_extra != 0) {
                    if (is_tiny) env.flags.underflow = true;
                    env.flags.inexact = true;
                }
                do_increment = 0x8000000000000000 <= sig_extra;
                if (!near_even and mode != .near_max_mag) do_increment = toward and sig_extra != 0;
                if (do_increment) {
                    sig +%= 1;
                    if (sig_extra & 0x7FFFFFFFFFFFFFFF == 0 and near_even) sig &= ~@as(u64, 1);
                    exp = @intFromBool(sig & 0x8000000000000000 != 0);
                }
                return pack(sign, exp, sig);
            }
            if (0x7FFE < exp or (exp == 0x7FFE and sig == 0xFFFFFFFFFFFFFFFF and do_increment))
                return env.overflow(sign, 0);
        }
        if (sig_extra != 0) env.flags.inexact = true;
        if (do_increment) {
            sig +%= 1;
            if (sig == 0) {
                exp += 1;
                sig = 0x8000000000000000;
            } else if (sig_extra & 0x7FFFFFFFFFFFFFFF == 0 and near_even) {
                sig &= ~@as(u64, 1);
            }
        }
        return pack(sign, exp, sig);
    }

    fn overflow(env: *Env, sign: bool, round_mask: u64) F80 {
        env.flags.overflow = true;
        env.flags.inexact = true;
        const mode = env.rounding;
        if (mode == .near_even or mode == .near_max_mag or mode == (if (sign) Rounding.min else Rounding.max))
            return pack(sign, 0x7FFF, 0x8000000000000000);
        return pack(sign, 0x7FFE, ~round_mask);
    }

    fn roundPackToF32(env: *Env, sign: bool, exp_in: i32, sig_in: u32) u32 {
        var exp = exp_in;
        var sig = sig_in;
        const mode = env.rounding;
        const near_even = mode == .near_even;
        var round_increment: u32 = 0x40;
        if (!near_even and mode != .near_max_mag)
            round_increment = if (mode == (if (sign) Rounding.min else Rounding.max)) 0x7F else 0;
        var round_bits = sig & 0x7F;
        if (0xFD <= @as(u32, @bitCast(exp))) {
            if (exp < 0) {
                const is_tiny = exp < -1 or @as(u64, sig) + round_increment < 0x80000000;
                sig = shiftRightJam32(sig, @intCast(-exp));
                exp = 0;
                round_bits = sig & 0x7F;
                if (is_tiny and round_bits != 0) env.flags.underflow = true;
            } else if (0xFD < exp or 0x80000000 <= @as(u64, sig) + round_increment) {
                env.flags.overflow = true;
                env.flags.inexact = true;
                return packF32(sign, 0xFF, 0) - @intFromBool(round_increment == 0);
            }
        }
        sig = @truncate((@as(u64, sig) + round_increment) >> 7);
        if (round_bits != 0) env.flags.inexact = true;
        if (round_bits == 0x40 and near_even) sig &= ~@as(u32, 1);
        if (sig == 0) exp = 0;
        return packF32(sign, exp, sig);
    }

    fn roundPackToF64(env: *Env, sign: bool, exp_in: i32, sig_in: u64) u64 {
        var exp = exp_in;
        var sig = sig_in;
        const mode = env.rounding;
        const near_even = mode == .near_even;
        var round_increment: u64 = 0x200;
        if (!near_even and mode != .near_max_mag)
            round_increment = if (mode == (if (sign) Rounding.min else Rounding.max)) 0x3FF else 0;
        var round_bits = sig & 0x3FF;
        // SoftFloat casts exp to uint16_t here; extF80's exponents always fit
        // in an int_fast16_t, so the cast only folds negatives up.
        if (0x7FD <= @as(u16, @truncate(@as(u32, @bitCast(exp))))) {
            if (exp < 0) {
                const is_tiny = exp < -1 or sig +% round_increment < 0x8000000000000000;
                sig = shiftRightJam64(sig, @intCast(-exp));
                exp = 0;
                round_bits = sig & 0x3FF;
                if (is_tiny and round_bits != 0) env.flags.underflow = true;
            } else if (0x7FD < exp or 0x8000000000000000 <= sig +% round_increment) {
                env.flags.overflow = true;
                env.flags.inexact = true;
                return packF64(sign, 0x7FF, 0) - @intFromBool(round_increment == 0);
            }
        }
        sig = (sig +% round_increment) >> 10;
        if (round_bits != 0) env.flags.inexact = true;
        if (round_bits == 0x200 and near_even) sig &= ~@as(u64, 1);
        if (sig == 0) exp = 0;
        return packF64(sign, exp, sig);
    }

    fn propagateNan(env: *Env, a: F80, b: F80) F80 {
        return env.propagateNanUI(a.sign_exp, a.signif, b.sign_exp, b.signif);
    }

    /// The 8086 rule: a signaling NaN raises invalid; a quiet NaN wins over
    /// a signaling one; between two of the same kind, the larger
    /// significand wins. The result is always quiet.
    fn propagateNanUI(env: *Env, ui_a64: u16, ui_a0: u64, ui_b64: u16, ui_b0: u64) F80 {
        const sig_nan_a = isSigNanUI(ui_a64, ui_a0);
        const sig_nan_b = isSigNanUI(ui_b64, ui_b0);
        const a: F80 = .{ .sign_exp = ui_a64, .signif = ui_a0 | 0xC000000000000000 };
        const b: F80 = .{ .sign_exp = ui_b64, .signif = ui_b0 | 0xC000000000000000 };
        if (sig_nan_a or sig_nan_b) {
            env.flags.invalid = true;
            if (sig_nan_a and !sig_nan_b) return if (isNanUI(ui_b64, ui_b0)) b else a;
            if (!sig_nan_a) return if (isNanUI(ui_a64, ui_a0)) a else b;
        }
        const mag_a64 = ui_a64 & 0x7FFF;
        const mag_b64 = ui_b64 & 0x7FFF;
        if (mag_a64 < mag_b64) return b;
        if (mag_b64 < mag_a64) return a;
        if (ui_a0 < ui_b0) return b;
        if (ui_b0 < ui_a0) return a;
        if (ui_a64 < ui_b64) return a;
        return b;
    }

    fn toCommonNan(env: *Env, a: F80) CommonNan {
        if (a.isSignalingNan()) env.flags.invalid = true;
        return .{ .sign = a.sign(), .v64 = a.signif << 1 };
    }
};

const CommonNan = struct { sign: bool, v64: u64 };

fn fromCommonNan(n: CommonNan) F80 {
    return .{ .sign_exp = @as(u16, @intFromBool(n.sign)) << 15 | 0x7FFF, .signif = 0xC000000000000000 | n.v64 >> 1 };
}

/// From i32. Always exact.
pub fn fromI32(a: i32) F80 {
    if (a == 0) return F80.zero;
    const sign = a < 0;
    var abs_a: u32 = @bitCast(a);
    if (sign) abs_a = 0 -% abs_a;
    const shift = @clz(abs_a);
    return pack(sign, 0x401E - @as(i32, shift), @as(u64, abs_a << @intCast(shift)) << 32);
}

/// From i64. Always exact.
pub fn fromI64(a: i64) F80 {
    if (a == 0) return F80.zero;
    const sign = a < 0;
    var abs_a: u64 = @bitCast(a);
    if (sign) abs_a = 0 -% abs_a;
    const shift = @clz(abs_a);
    return pack(sign, 0x403E - @as(i32, shift), abs_a << @intCast(shift));
}

fn pack(sign: bool, exp: i32, sig: u64) F80 {
    return .{ .sign_exp = @as(u16, @intFromBool(sign)) << 15 | @as(u16, @intCast(exp)), .signif = sig };
}

fn packF32(sign: bool, exp: i32, sig: u32) u32 {
    return (@as(u32, @intFromBool(sign)) << 31) +% (@as(u32, @bitCast(exp)) << 23) +% sig;
}

fn packF64(sign: bool, exp: i32, sig: u64) u64 {
    return (@as(u64, @intFromBool(sign)) << 63) +% (@as(u64, @intCast(exp)) << 52) +% sig;
}

fn isNanUI(ui64: u16, ui0: u64) bool {
    return ui64 & 0x7FFF == 0x7FFF and ui0 & 0x7FFFFFFFFFFFFFFF != 0;
}

fn isSigNanUI(ui64: u16, ui0: u64) bool {
    return ui64 & 0x7FFF == 0x7FFF and ui0 & 0x4000000000000000 == 0 and ui0 & 0x3FFFFFFFFFFFFFFF != 0;
}

fn hi(x: u128) u64 {
    return @truncate(x >> 64);
}

fn lo(x: u128) u64 {
    return @truncate(x);
}

fn neg128(x: u128) bool {
    return x >> 127 != 0;
}

const ExpSig = struct { exp: i32, sig: u64 };

fn normSubnormalSig(sig: u64) ExpSig {
    // (SoftFloat's shift by 64 of a zero sig leaves it zero.)
    if (sig == 0) return .{ .exp = -64, .sig = 0 };
    const shift = @clz(sig);
    return .{ .exp = -@as(i32, shift), .sig = sig << @intCast(shift) };
}

fn shortShiftRightJam64(a: u64, dist: u6) u64 {
    return a >> dist | @intFromBool(a & ((@as(u64, 1) << dist) - 1) != 0);
}

fn shiftRightJam32(a: u32, dist: u32) u32 {
    if (dist < 31) return a >> @intCast(dist) | @intFromBool(a << @intCast((32 -% dist) & 31) != 0);
    return @intFromBool(a != 0);
}

fn shiftRightJam64(a: u64, dist: u32) u64 {
    if (dist < 63) return a >> @intCast(dist) | @intFromBool(a << @intCast((64 -% dist) & 63) != 0);
    return @intFromBool(a != 0);
}

const Sig64Extra = struct { v: u64, extra: u64 };

fn shiftRightJam64Extra(a: u64, extra: u64, dist: u32) Sig64Extra {
    var z: Sig64Extra = undefined;
    if (dist < 64) {
        z.v = a >> @intCast(dist);
        z.extra = if (dist == 0) 0 else a << @intCast(64 - dist);
    } else {
        z.v = 0;
        z.extra = if (dist == 64) a else @intFromBool(a != 0);
    }
    z.extra |= @intFromBool(extra != 0);
    return z;
}

fn shiftRightJam128(a: u128, dist: u32) u128 {
    if (dist == 0) return a;
    if (dist < 128) return a >> @intCast(dist) | @intFromBool(a << @intCast(128 - dist) != 0);
    return @intFromBool(a != 0);
}

/// (a * b) << 32, to 128 bits.
fn mul64ByShifted32To128(a: u64, b: u32) u128 {
    return (@as(u128, a) * b) << 32;
}

const approx_recip_1k0s = [16]u16{ 0xFFC4, 0xF0BE, 0xE363, 0xD76F, 0xCCAD, 0xC2F0, 0xBA16, 0xB201, 0xAA97, 0xA3C6, 0x9D7A, 0x97A6, 0x923C, 0x8D32, 0x887E, 0x8417 };
const approx_recip_1k1s = [16]u16{ 0xF0F1, 0xD62C, 0xBFA1, 0xAC77, 0x9C0A, 0x8DDB, 0x8185, 0x76BA, 0x6D3B, 0x64D4, 0x5D5C, 0x56B1, 0x50B6, 0x4B55, 0x4679, 0x4211 };
const approx_recip_sqrt_1k0s = [16]u16{ 0xB4C9, 0xFFAB, 0xAA7D, 0xF11C, 0xA1C5, 0xE4C7, 0x9A43, 0xDA29, 0x93B5, 0xD0E5, 0x8DED, 0xC8B7, 0x88C6, 0xC16D, 0x8424, 0xBAE1 };
const approx_recip_sqrt_1k1s = [16]u16{ 0xA5A5, 0xEA42, 0x8C21, 0xC62D, 0x788F, 0xAA7F, 0x6928, 0x94B6, 0x5CC7, 0x8335, 0x52A6, 0x74E2, 0x4A3E, 0x68FE, 0x432B, 0x5EFD };

/// An approximation of 2^32/a, for a with its top bit set.
fn approxRecip32_1(a: u32) u32 {
    const index = a >> 27 & 0xF;
    const eps: u16 = @truncate(a >> 11);
    const r0: u16 = @truncate(@as(u64, approx_recip_1k0s[index]) -% ((@as(u64, approx_recip_1k1s[index]) * eps) >> 20));
    const sigma0: u32 = ~@as(u32, @truncate((@as(u64, r0) * a) >> 7));
    var r: u64 = (@as(u64, r0) << 16) +% ((@as(u64, r0) * sigma0) >> 24);
    const sqr_sigma0: u32 = @truncate((@as(u64, sigma0) * sigma0) >> 32);
    r +%= (@as(u64, @as(u32, @truncate(r))) * sqr_sigma0) >> 48;
    return @truncate(r);
}

/// An approximation of 2^31/sqrt(a) (2^31/sqrt(2a) when odd_exp is 0).
fn approxRecipSqrt32_1(odd_exp: u1, a: u32) u32 {
    const index = (a >> 27 & 0xE) + odd_exp;
    const eps: u16 = @truncate(a >> 12);
    const r0: u16 = @truncate(@as(u64, approx_recip_sqrt_1k0s[index]) -% ((@as(u64, approx_recip_sqrt_1k1s[index]) * eps) >> 20));
    var e_sqr_r0: u64 = @as(u64, r0) * r0;
    if (odd_exp == 0) e_sqr_r0 <<= 1;
    const sigma0: u32 = ~@as(u32, @truncate((@as(u64, @as(u32, @truncate(e_sqr_r0))) * a) >> 23));
    var r: u64 = (@as(u64, r0) << 16) +% ((@as(u64, r0) * sigma0) >> 25);
    const sqr_sigma0: u32 = @truncate((@as(u64, sigma0) * sigma0) >> 32);
    r +%= (@as(u64, @as(u32, @truncate((r >> 1) +% (r >> 3) -% (@as(u64, r0) << 14)))) * sqr_sigma0) >> 48;
    if (r & 0x80000000 == 0) r = 0x80000000;
    return @truncate(r);
}

test "simple values" {
    var env: Env = .{};
    const two = env.add(F80.one, F80.one);
    try std.testing.expectEqual(@as(u80, 0x4000_8000000000000000), two.toBits());
    try std.testing.expectEqual(two, env.sqrt(env.mul(two, two)));
    try std.testing.expect(!env.flags.any());
    const third = env.div(F80.one, fromI32(3));
    try std.testing.expect(env.flags.inexact);
    try std.testing.expectEqual(@as(u80, 0x3FFD_AAAAAAAAAAAAAAAB), third.toBits());
    try std.testing.expectEqual(@as(i32, -7), env.toI32(fromI64(-7), .near_even, true));
    try std.testing.expectEqual(@as(u64, 0x3FF0000000000000), env.toF64(F80.one));
    try std.testing.expectEqual(F80.one, env.fromF32(0x3F800000));
    env.flags = .{};
    _ = env.div(F80.one, F80.zero);
    try std.testing.expect(env.flags.infinite);
    try std.testing.expectEqual(@as(u16, 0x04), env.flags.x87());
}

test "testfloat sample" {
    try @import("f80_vectors.zig").run(@embedFile("f80-vectors.txt"));
}
