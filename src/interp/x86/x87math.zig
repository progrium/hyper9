//! What the x87 computes that SoftFloat doesn't: FPREM's truncating
//! partial remainder (and FPREM1's), FSIN, FCOS, FSINCOS, FPTAN, FPATAN,
//! F2XM1, FYL2X, FYL2XP1, FSCALE, and FXTRACT, all in software so every
//! host gives the same bits.
//!
//! The remainders are exact integer arithmetic. The transcendentals work
//! in binary128 (Zig's f128, which compiler-rt computes in software on
//! every target), 113 bits against the x87's 64, then round once more to
//! the 80-bit result in the control word's rounding mode, so they are
//! within an ulp or so of the x87's own results, not bit for bit. As the
//! x87 does, FSIN, FCOS, FSINCOS, and FPTAN reduce their argument by an
//! approximation of pi (`pi_x87`), not the true pi, which is what keeps
//! them near the hardware's results for large arguments.
//!
//! Callers handle empty registers, unsupported encodings, and the
//! denormal exception; these see values and raise the rest through the
//! SoftFloat `Env`.

const std = @import("std");
const sf = @import("f80.zig");
const F80 = sf.F80;
const Env = sf.Env;

// ---------------------------------------------------------- remainders

pub const Rem = struct {
    r: F80,
    /// The quotient's low bits, for C0, C3, and C1.
    q: u64 = 0,
    /// The reduction is incomplete (C2): run it again.
    partial: bool = false,
};

/// An F80 that isn't zero, inf, or NaN, as sig * 2^(exp - 63) with sig's
/// top bit set (exp unbiased).
const Norm = struct { sig: u64, exp: i32 };

fn normalize(a: F80) Norm {
    var e: i32 = a.exp();
    if (e == 0) e = 1;
    const z: u6 = @intCast(@clz(a.signif));
    return .{ .sig = a.signif << z, .exp = e - 0x3fff - z };
}

/// sign * m * 2^u, exactly (m < 2^64, and the value in the 80-bit range,
/// a denormal at worst).
fn packExact(sign: bool, m: u64, u: i32) F80 {
    const s: u16 = if (sign) 0x8000 else 0;
    if (m == 0) return .{ .sign_exp = s, .signif = 0 };
    const z: u6 = @intCast(@clz(m));
    const sig = m << z;
    const e = u + 63 - @as(i32, z) + 0x3fff;
    if (e >= 1) return .{ .sign_exp = s | @as(u16, @intCast(e)), .signif = sig };
    const sh: u32 = @intCast(1 - e);
    return .{ .sign_exp = s, .signif = if (sh >= 64) 0 else sig >> @intCast(sh) };
}

/// FPREM (`nearest` false: the quotient truncated, as C's fmod) and
/// FPREM1 (`nearest`: rounded to nearest even, the IEEE remainder) of a
/// by b, both finite, nonzero, and supported. Exponents more than 63
/// apart give a partial remainder: a reduced by b * 2^(d - n) times its
/// truncated quotient, with n between 32 and 63, and C2 set.
pub fn remainder(a: F80, b: F80, nearest: bool) Rem {
    const x = normalize(a);
    const y = normalize(b);
    const d = x.exp - y.exp;
    const sign = a.sign();
    if (d < 0) {
        if (!nearest or d < -1) return .{ .r = a };
        // |a| in [|b|/2, |b|): rounds to 1 above the half.
        const den = @as(u128, y.sig) << 1;
        const num: u128 = x.sig;
        if (2 * num > den) return .{ .r = packExact(!sign, @intCast(den - num), x.exp - 63), .q = 1 };
        return .{ .r = a };
    }
    if (d >= 64) {
        const n: u7 = @intCast(32 | (d & 31));
        const num = @as(u128, x.sig) << n;
        const q = num / y.sig;
        const r = num % y.sig;
        return .{ .r = packExact(sign, @intCast(r), x.exp - 63 - n), .q = @truncate(q), .partial = true };
    }
    const num = @as(u128, x.sig) << @intCast(d);
    var q = num / y.sig;
    var r = num % y.sig;
    var s = sign;
    if (nearest and (2 * r > y.sig or (2 * r == y.sig and q & 1 == 1))) {
        q += 1;
        r = y.sig - r;
        s = !s;
    }
    return .{ .r = packExact(s, @intCast(r), y.exp - 63), .q = @truncate(q) };
}

// ------------------------------------------------------------ binary128

const f128_frac = 112;

/// A finite, supported F80 as binary128, exactly: the exponents share a
/// bias and a range.
pub fn toF128(a: F80) f128 {
    const sign: u128 = @as(u128, @intFromBool(a.sign())) << 127;
    if (a.signif == 0) return @bitCast(sign);
    var e: i32 = a.exp();
    if (e == 0) e = 1;
    const z: u6 = @intCast(@clz(a.signif));
    const ne = e - z;
    if (ne >= 1) {
        const sig = a.signif << z;
        const frac: u128 = @as(u128, sig & 0x7fff_ffff_ffff_ffff) << (f128_frac - 63);
        return @bitCast(sign | @as(u128, @intCast(ne)) << f128_frac | frac);
    }
    // A binary128 denormal: sig * 2^(1 - 0x3fff - 63) = frac * 2^(1 - 0x3fff - 112).
    return @bitCast(sign | @as(u128, a.signif) << (f128_frac - 63));
}

/// v * 2^k: binary128 keeps intermediate results normal this way, since
/// compiler-rt's binary128 loses bits on denormal results, and the x87's
/// tiny results are denormals there.
pub const Scaled = struct { v: f128, k: i32 = 0 };

/// v as m * 2^k with |m| in [1, 2), or v itself if it's 0, inf, or NaN.
pub fn split(v: f128) Scaled {
    const b = f128bits(v);
    const e: i32 = @intCast((b >> f128_frac) & 0x7fff);
    if (e == 0x7fff or v == 0) return .{ .v = v };
    if (e == 0) {
        const n = split(v * 0x1p200);
        return .{ .v = n.v, .k = n.k - 200 };
    }
    const m: f128 = @bitCast((b & ~(@as(u128, 0x7fff) << f128_frac)) | (@as(u128, 0x3fff) << f128_frac));
    return .{ .v = m, .k = e - 0x3fff };
}

pub fn mul(a: Scaled, b: Scaled) Scaled {
    const x = split(a.v);
    const y = split(b.v);
    return .{ .v = x.v * y.v, .k = x.k + y.k + a.k + b.k };
}

/// Rounds a binary128 value to an F80 in env's rounding mode, at full
/// precision, raising PE, UE, and OE as rounding does.
pub fn round80(env: *Env, v: f128) F80 {
    return roundScaled(env, .{ .v = v });
}

pub fn roundScaled(env: *Env, sv: Scaled) F80 {
    const saved = env.precision;
    env.precision = .p80;
    defer env.precision = saved;
    const b: u128 = @bitCast(sv.v);
    const s: u16 = if (b >> 127 != 0) 0x8000 else 0;
    const e: i32 = @intCast((b >> f128_frac) & 0x7fff);
    const frac = b & ((@as(u128, 1) << f128_frac) - 1);
    if (e == 0x7fff) {
        if (frac == 0) return .{ .sign_exp = s | 0x7fff, .signif = 1 << 63 };
        return .{ .sign_exp = s | 0x7fff, .signif = (1 << 63) | (1 << 62) | @as(u64, @truncate(frac >> 49)) };
    }
    if (e == 0 and frac == 0) return .{ .sign_exp = s, .signif = 0 };
    // value = S * 2^(E - 0x3fff - 112), S's top bit at 112.
    var S: u128 = if (e == 0) frac else (@as(u128, 1) << f128_frac) | frac;
    var E: i64 = if (e == 0) 1 else e;
    const z: u7 = @intCast(@clz(S) - 15);
    S <<= z;
    E -= z;
    E += sv.k;
    if (E > 0x7ffe) {
        const big: F80 = .{ .sign_exp = s | 0x7ffe, .signif = 0xffff_ffff_ffff_ffff };
        return env.mul(big, .{ .sign_exp = 0x7ffe, .signif = 1 << 63 });
    }
    if (E >= 1) {
        const hi: F80 = .{ .sign_exp = s | @as(u16, @intCast(E)), .signif = @truncate(S >> 49) };
        const low: u64 = @truncate(S & ((1 << 49) - 1));
        if (low == 0) return hi;
        // lo = low * 2^(E - 0x3fff - 112); with its top bit moved to bit
        // 63, its biased exponent is E - 49 - lz.
        const lz: u6 = @intCast(@clz(low));
        const fe = E - 49 - lz;
        const lo: F80 = if (fe >= 1)
            .{ .sign_exp = s | @as(u16, @intCast(fe)), .signif = low << lz }
        else
            // Below hi's last place by far more than a rounding needs:
            // a sticky bit is enough.
            .{ .sign_exp = s, .signif = 1 };
        return env.add(hi, lo);
    }
    // A denormal: m = S * 2^(E - 1 - 49), in units of the last place.
    const sh: u64 = @intCast(1 - E + 49);
    const m: u64 = if (sh >= 128) 0 else @truncate(S >> @intCast(sh));
    const rem: u128 = if (sh >= 128) S else S & ((@as(u128, 1) << @intCast(sh)) - 1);
    if (rem == 0) return .{ .sign_exp = s, .signif = m };
    env.flags.inexact = true;
    env.flags.underflow = true;
    const half: u128 = if (sh >= 129) std.math.maxInt(u128) else @as(u128, 1) << @intCast(sh - 1);
    const up = switch (env.rounding) {
        .near_even => rem > half or (rem == half and m & 1 == 1),
        .near_max_mag => rem >= half,
        .min => s != 0,
        .max => s == 0,
        .min_mag => false,
    };
    const r = m + @intFromBool(up);
    return .{ .sign_exp = s | @intFromBool(r >> 63 != 0), .signif = r };
}

fn f128bits(v: f128) u128 {
    return @bitCast(v);
}

const ln2: f128 = std.math.ln2;
const log2e: f128 = std.math.log2e;
const pi: f128 = std.math.pi;

/// log2(x) for finite x > 0.
pub fn log2(x_in: f128) f128 {
    var x = x_in;
    var k: i32 = 0;
    var b = f128bits(x);
    if ((b >> f128_frac) & 0x7fff == 0) {
        x *= 0x1p120;
        k = -120;
        b = f128bits(x);
    }
    k += @as(i32, @intCast((b >> f128_frac) & 0x7fff)) - 0x3fff;
    var m: f128 = @bitCast((b & ((@as(u128, 1) << f128_frac) - 1)) | (@as(u128, 0x3fff) << f128_frac));
    if (m > std.math.sqrt2) {
        m *= 0.5;
        k += 1;
    }
    return @as(f128, @floatFromInt(k)) + log2Series((m - 1) / (m + 1));
}

/// log2(1 + x) for x > -1.
pub fn log2p1(x: f128) Scaled {
    // Tiny: x / ln 2, to far more than 64 bits.
    if (@abs(x) < 0x1p-120) return mul(.{ .v = x }, .{ .v = log2e });
    if (@abs(x) < 0.29) return .{ .v = log2Series(x / (2 + x)) };
    return .{ .v = log2(1 + x) };
}

/// 2 * atanh(s) / ln 2 = log2((1 + s) / (1 - s)), for small |s|.
fn log2Series(s: f128) f128 {
    const s2 = s * s;
    var sum = s;
    var term = s;
    var n: f128 = 3;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        term *= s2;
        const t = term / n;
        if (@abs(t) <= @abs(sum) * 0x1p-120) break;
        sum += t;
        n += 2;
    }
    return 2 * sum * log2e;
}

/// 2^x - 1.
pub fn exp2m1(x: f128) Scaled {
    if (@abs(x) < 0x1p-120) return mul(.{ .v = x }, .{ .v = ln2 });
    return .{ .v = exp2m1Series(x) };
}

fn exp2m1Series(x: f128) f128 {
    const t = x * ln2;
    var sum = t;
    var term = t;
    var k: f128 = 2;
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        term = term * t / k;
        if (@abs(term) <= @abs(sum) * 0x1p-120) break;
        sum += term;
        k += 1;
    }
    return sum;
}

/// atan2(y, x) for finite y and x, not both zero.
pub fn atan2(y: f128, x: f128) Scaled {
    // atan(t) = t for tiny t; keep it exact.
    if (x > 0) {
        const ys = split(y);
        const xs = split(x);
        if (ys.k - xs.k < -100) return .{ .v = ys.v / xs.v, .k = ys.k - xs.k };
    }
    return .{ .v = atan2Wide(y, x) };
}

fn atan2Wide(y: f128, x: f128) f128 {
    const ay = @abs(y);
    const ax = @abs(x);
    var t: f128 = if (ay <= ax) std.math.atan(ay / ax) else pi / 2 - std.math.atan(ax / ay);
    if (x < 0 or (x == 0 and std.math.signbit(x))) t = pi - t;
    return if (std.math.signbit(y)) -t else t;
}

// ---------------------------------------------------------------- trig

/// The x87's pi for FSIN, FCOS, FSINCOS, and FPTAN: 66 bits,
/// pi_x87 * 2^-64. Reducing by it, exactly, is what the hardware does.
pub const pi_x87: u128 = 0x3_243f_6a88_85a3_08d3;
const pi_x87_bits = 66;

/// x (finite, |x| < 2^63) reduced: x = k * (pi_x87 / 2) + r, |r| <= pi_x87/4,
/// with r in binary128 and k mod 4.
pub const Reduced = struct { r: f128, k: u2 };

pub fn reduce(x: F80) Reduced {
    const v = toF128(x);
    if (@abs(v) <= pi / 4) return .{ .r = v, .k = 0 };
    const n = normalize(x);
    // x = sig * 2^(e - 63), with e < 63. halfpi = pi_x87 * 2^-65.
    // k = round(x / halfpi) = round(sig * 2^(e + 2) / pi_x87).
    // Work in units of 2^-65-64: X = sig << (e + 2 + 64)... kept as u256.
    const sh: u32 = @intCast(n.exp + 2 + 64);
    const X: u256 = @as(u256, n.sig) << @intCast(sh); // x * 2^129 * 2^-63... (units of 2^-129)
    const P: u256 = @as(u256, pi_x87) << 64; // halfpi in units of 2^-129
    var k = X / P;
    var r: u256 = X % P;
    var neg = false;
    if (r > P / 2) {
        k += 1;
        r = P - r;
        neg = true;
    }
    // r in units of 2^-129 (< 2^129 * pi/4).
    var rf: f128 = 0;
    if (r != 0) {
        const z: u32 = @clz(r);
        const top: u32 = 255 - z;
        // Keep 120 bits for the binary128 conversion, rounding by jam.
        var m: u128 = undefined;
        var sh2: i32 = undefined;
        if (top >= 119) {
            const d: u8 = @intCast(top - 119);
            m = @truncate(r >> d);
            if (r & ((@as(u256, 1) << d) - 1) != 0) m |= 1;
            sh2 = @as(i32, d) - 129;
        } else {
            m = @truncate(r);
            sh2 = -129;
        }
        rf = std.math.ldexp(@as(f128, @floatFromInt(m)), sh2);
    }
    if (neg) rf = -rf;
    if (x.sign()) rf = -rf;
    var kk: u2 = @truncate(@as(u64, @truncate(k)));
    if (x.sign()) kk = 0 -% kk;
    return .{ .r = rf, .k = kk };
}

pub fn sin(x: F80) f128 {
    const red = reduce(x);
    return switch (red.k) {
        0 => @sin(red.r),
        1 => @cos(red.r),
        2 => -@sin(red.r),
        3 => -@cos(red.r),
    };
}

pub fn cos(x: F80) f128 {
    const red = reduce(x);
    return switch (red.k) {
        0 => @cos(red.r),
        1 => -@sin(red.r),
        2 => -@cos(red.r),
        3 => @sin(red.r),
    };
}

pub fn tan(x: F80) f128 {
    const red = reduce(x);
    const t = @tan(red.r);
    return if (red.k & 1 == 0) t else -1 / t;
}

// --------------------------------------------------------------- tests

const testing = std.testing;

fn ext(v: f64) F80 {
    var env: Env = .{};
    return env.fromF64(@bitCast(v));
}

fn back(v: F80) f64 {
    var env: Env = .{};
    return @bitCast(env.toF64(v));
}

test "FPREM and FPREM1" {
    // fmod(7, 2) = 1 with quotient 3; remainder(7, 2) = -1 with 4.
    var r = remainder(ext(7), ext(2), false);
    try testing.expectEqual(@as(f64, 1), back(r.r));
    try testing.expectEqual(@as(u64, 3), r.q);
    r = remainder(ext(7), ext(2), true);
    try testing.expectEqual(@as(f64, -1), back(r.r));
    try testing.expectEqual(@as(u64, 4), r.q);
    r = remainder(ext(-5.5), ext(2), false);
    try testing.expectEqual(@as(f64, -1.5), back(r.r));
    r = remainder(ext(1.5), ext(2), true);
    try testing.expectEqual(@as(f64, -0.5), back(r.r));
    // 2^100 mod 3 needs more than one pass.
    var a = ext(0x1p100);
    var passes: usize = 0;
    while (true) : (passes += 1) {
        r = remainder(a, ext(3), false);
        a = r.r;
        if (!r.partial) break;
    }
    try testing.expect(passes >= 1);
    try testing.expectEqual(@as(f64, 1), back(a)); // 2^100 = 16^25 = 1 mod 3
}

test "binary128 round trip and transcendentals" {
    var env: Env = .{};
    const vals = [_]f64{ 1, -2.5, 0x1p-1070, 3.14159, 1e300 };
    for (vals) |v| try testing.expectEqual(v, back(round80(&env, toF128(ext(v)))));
    try testing.expectApproxEqRel(@as(f64, 0.8414709848078965), back(round80(&env, sin(ext(1)))), 1e-15);
    try testing.expectApproxEqRel(@as(f64, -0.4161468365471424), back(round80(&env, cos(ext(2)))), 1e-15);
    try testing.expectApproxEqRel(@as(f64, -2.185039863261519), back(round80(&env, tan(ext(2)))), 1e-15);
    try testing.expectApproxEqRel(@as(f64, 3.321928094887362), back(round80(&env, log2(10))), 1e-15);
    try testing.expectApproxEqRel(@as(f64, 0.41421356237309503), back(roundScaled(&env, exp2m1(0.5))), 1e-15);
    try testing.expectApproxEqRel(@as(f64, 0.5849625007211562), back(roundScaled(&env, log2p1(0.5))), 1e-15);
    try testing.expectApproxEqRel(@as(f64, 2.356194490192345), back(roundScaled(&env, atan2(1, -1))), 1e-15);
}
