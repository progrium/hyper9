//! IEEE binary32 and binary64 in software, with SSE's rules: MXCSR's
//! rounding control, DAZ and FTZ, and its six exception flags; x86's NaN
//! propagation (the first operand's NaN, else the second's, quieted) and
//! default NaN (the negative quiet NaN); tininess detected after
//! rounding. sse.zig runs every SSE and SSE2 floating-point operation
//! through these, so results don't depend on the host's FPU or on what
//! WebAssembly leaves unspecified (NaN bits, flags, rounding modes).
//!
//! Values travel as their bit patterns, `u32` for binary32 and `u64` for
//! binary64; each function takes the pattern type as `T`.

const std = @import("std");

/// MXCSR's exception flags, in its bit order (and the x87's).
pub const IE: u8 = 1 << 0;
pub const DE: u8 = 1 << 1;
pub const ZE: u8 = 1 << 2;
pub const OE: u8 = 1 << 3;
pub const UE: u8 = 1 << 4;
pub const PE: u8 = 1 << 5;

pub const Env = struct {
    /// Rounding control: nearest, down, up, toward zero.
    rc: u2 = 0,
    /// Denormal operands are zero.
    daz: bool = false,
    /// Tiny results are zero, when underflow is masked.
    ftz: bool = false,
    /// Underflow is masked: a tiny result raises UE only when it's also
    /// inexact. Unmasked, every tiny result does.
    um: bool = true,
    /// The exceptions raised, accumulated.
    flags: u8 = 0,

    pub fn fromMxcsr(m: u32) Env {
        return .{
            .rc = @truncate(m >> 13),
            .daz = m & (1 << 6) != 0,
            .ftz = m & (1 << 15) != 0,
            .um = m & (1 << 11) != 0,
        };
    }
};

/// The constants of a format, by its bit-pattern type.
pub fn Fmt(comptime T: type) type {
    return struct {
        pub const bits = @bitSizeOf(T);
        pub const frac_bits = if (T == u32) 23 else 52;
        pub const exp_bits = bits - 1 - frac_bits;
        pub const exp_max: T = (1 << exp_bits) - 1;
        pub const bias: i32 = (1 << (exp_bits - 1)) - 1;
        pub const sign_bit: T = 1 << (bits - 1);
        pub const frac_mask: T = (1 << frac_bits) - 1;
        pub const quiet_bit: T = 1 << (frac_bits - 1);
        pub const inf: T = exp_max << frac_bits;
        pub const default_nan: T = sign_bit | inf | quiet_bit;
        pub const max_finite: T = inf - 1;
    };
}

pub fn isNan(comptime T: type, a: T) bool {
    const F = Fmt(T);
    return a & ~F.sign_bit > F.inf;
}

pub fn isSnan(comptime T: type, a: T) bool {
    const F = Fmt(T);
    return isNan(T, a) and a & F.quiet_bit == 0;
}

pub fn isDenormal(comptime T: type, a: T) bool {
    const F = Fmt(T);
    return a & F.inf == 0 and a & F.frac_mask != 0;
}

pub fn quiet(comptime T: type, a: T) T {
    return a | Fmt(T).quiet_bit;
}

/// A denormal as DAZ sees it: a zero of its sign.
fn daz(comptime T: type, env: *const Env, a: T) T {
    if (env.daz and isDenormal(T, a)) return a & Fmt(T).sign_bit;
    return a;
}

const Kind = enum { zero, finite, inf };

/// A number that isn't a NaN: sign * sig * 2^exp.
const Num = struct {
    sign: bool,
    kind: Kind,
    sig: u64 = 0,
    exp: i32 = 0,
};

/// Unpacks `a` (not a NaN), DAZ applied, noting a denormal in `den`.
fn unpack(comptime T: type, env: *const Env, a: T, den: *bool) Num {
    const F = Fmt(T);
    const sign = a & F.sign_bit != 0;
    const e: i32 = @intCast((a >> F.frac_bits) & F.exp_max);
    const frac: u64 = a & F.frac_mask;
    if (e == F.exp_max) return .{ .sign = sign, .kind = .inf };
    if (e == 0) {
        if (frac == 0) return .{ .sign = sign, .kind = .zero };
        if (env.daz) return .{ .sign = sign, .kind = .zero };
        den.* = true;
        return .{ .sign = sign, .kind = .finite, .sig = frac, .exp = 1 - F.bias - F.frac_bits };
    }
    return .{ .sign = sign, .kind = .finite, .sig = frac | (@as(u64, 1) << F.frac_bits), .exp = e - F.bias - F.frac_bits };
}

fn signed(comptime T: type, sign: bool, mag: T) T {
    return if (sign) mag | Fmt(T).sign_bit else mag;
}

/// x86's NaN result for an operation on `a` and `b`, raising IE on a
/// signaling NaN, or null when neither is a NaN.
fn nan2(comptime T: type, env: *Env, a: T, b: T) ?T {
    const na = isNan(T, a);
    const nb = isNan(T, b);
    if (!na and !nb) return null;
    if (isSnan(T, a) or isSnan(T, b)) env.flags |= IE;
    return quiet(T, if (na) a else b);
}

fn invalid(comptime T: type, env: *Env) T {
    env.flags |= IE;
    return Fmt(T).default_nan;
}

const Rounded = struct { m: u128, inexact: bool };

/// Rounds sig >> shift to an integer in `rc`, for a value of `sign`.
fn roundAt(sig: u128, shift: i32, sign: bool, rc: u2) Rounded {
    if (shift <= 0) return .{ .m = sig << @intCast(-shift), .inexact = false };
    if (shift >= 128) {
        // sig < 2^127 (callers keep it so), below half of the last place.
        const up = sig != 0 and switch (rc) {
            0, 3 => false,
            1 => sign,
            2 => !sign,
        };
        return .{ .m = @intFromBool(up), .inexact = sig != 0 };
    }
    const s: u7 = @intCast(shift);
    const m0 = sig >> s;
    const rem = sig & ((@as(u128, 1) << s) - 1);
    const half = @as(u128, 1) << (s - 1);
    const up = switch (rc) {
        0 => rem > half or (rem == half and m0 & 1 == 1),
        1 => sign and rem != 0,
        2 => !sign and rem != 0,
        3 => false,
    };
    return .{ .m = m0 + @intFromBool(up), .inexact = rem != 0 };
}

/// Rounds sign * sig * 2^e (sig below 2^127, with any bits beyond the
/// exact value jammed into its lowest bit) to format T.
fn round(comptime T: type, env: *Env, sign: bool, sig: u128, e: i32) T {
    const F = Fmt(T);
    if (sig == 0) return signed(T, sign, 0);
    const p: i32 = F.frac_bits + 1;
    const emin: i32 = 1 - F.bias;
    const n: i32 = 127 - @as(i32, @clz(sig));
    const top = e + n;
    var tiny = false;
    if (top < emin) {
        tiny = true;
        // Tininess after rounding: rounded to full precision with an
        // unbounded exponent, is it still below 2^emin?
        if (top == emin - 1 and roundAt(sig, n - (p - 1), sign, env.rc).m >> @intCast(p) != 0) tiny = false;
    }
    const shift: i32 = if (top >= emin) n - (p - 1) else n - (p - 1) + (emin - top);
    const r = roundAt(sig, shift, sign, env.rc);
    if (tiny) {
        if (!env.um) {
            env.flags |= UE;
        } else if (env.ftz) {
            env.flags |= UE | PE;
            return signed(T, sign, 0);
        } else if (r.inexact) env.flags |= UE;
    }
    if (r.inexact) env.flags |= PE;
    var m = r.m;
    if (top >= emin) {
        var ex = top;
        if (m >> @intCast(p) != 0) {
            m >>= 1;
            ex += 1;
        }
        if (ex > F.bias) return overflow(T, env, sign);
        const be: T = @intCast(ex + F.bias);
        return signed(T, sign, (be << F.frac_bits) | (@as(T, @truncate(m)) & F.frac_mask));
    }
    // A denormal, or the smallest normal if it rounded up to it.
    return signed(T, sign, @truncate(m));
}

fn overflow(comptime T: type, env: *Env, sign: bool) T {
    const F = Fmt(T);
    env.flags |= OE | PE;
    const to_inf = switch (env.rc) {
        0 => true,
        1 => sign,
        2 => !sign,
        3 => false,
    };
    return signed(T, sign, if (to_inf) F.inf else F.max_finite);
}

fn noteDenormal(env: *Env, den: bool) void {
    if (den) env.flags |= DE;
}

/// The significand moved up so its top bit is bit 63, and the exponent
/// to match.
fn norm(x: Num) struct { sig: u64, exp: i32 } {
    const z: u6 = @intCast(@clz(x.sig));
    return .{ .sig = x.sig << z, .exp = x.exp - z };
}

fn jamShift(v: u128, d: u32) u128 {
    if (d == 0) return v;
    if (d >= 128) return @intFromBool(v != 0);
    const s: u7 = @intCast(d);
    return (v >> s) | @intFromBool(v & ((@as(u128, 1) << s) - 1) != 0);
}

// ---------------------------------------------------------- arithmetic

pub fn add(comptime T: type, env: *Env, a: T, b: T) T {
    return addSub(T, env, a, b, false);
}

pub fn sub(comptime T: type, env: *Env, a: T, b: T) T {
    return addSub(T, env, a, b, true);
}

fn addSub(comptime T: type, env: *Env, a: T, b: T, negate: bool) T {
    if (nan2(T, env, a, b)) |r| return r;
    var den = false;
    const x = unpack(T, env, a, &den);
    var y = unpack(T, env, b, &den);
    if (negate) y.sign = !y.sign;
    if (x.kind == .inf or y.kind == .inf) {
        if (x.kind == .inf and y.kind == .inf and x.sign != y.sign) return invalid(T, env);
        noteDenormal(env, den);
        return signed(T, if (x.kind == .inf) x.sign else y.sign, Fmt(T).inf);
    }
    noteDenormal(env, den);
    if (x.kind == .zero and y.kind == .zero) {
        const s = if (x.sign == y.sign) x.sign else env.rc == 1;
        return signed(T, s, 0);
    }
    if (x.kind == .zero) return round(T, env, y.sign, y.sig, y.exp);
    if (y.kind == .zero) return round(T, env, x.sign, x.sig, x.exp);
    const nx = norm(x);
    const ny = norm(y);
    // The larger magnitude first, with its top bit at 126.
    const x_big = nx.exp > ny.exp or (nx.exp == ny.exp and nx.sig >= ny.sig);
    const big = if (x_big) nx else ny;
    const small = if (x_big) ny else nx;
    const big_sign = if (x_big) x.sign else y.sign;
    const small_sign = if (x_big) y.sign else x.sign;
    const B = @as(u128, big.sig) << 63;
    const S = jamShift(@as(u128, small.sig) << 63, @intCast(big.exp - small.exp));
    const e = big.exp - 63;
    if (big_sign == small_sign) return round(T, env, big_sign, jamShift(B + S, 1), e + 1);
    const d = B - S;
    if (d == 0) return signed(T, env.rc == 1, 0);
    return round(T, env, big_sign, d, e);
}

pub fn mul(comptime T: type, env: *Env, a: T, b: T) T {
    if (nan2(T, env, a, b)) |r| return r;
    var den = false;
    const x = unpack(T, env, a, &den);
    const y = unpack(T, env, b, &den);
    const s = x.sign != y.sign;
    if (x.kind == .inf or y.kind == .inf) {
        if (x.kind == .zero or y.kind == .zero) return invalid(T, env);
        noteDenormal(env, den);
        return signed(T, s, Fmt(T).inf);
    }
    noteDenormal(env, den);
    if (x.kind == .zero or y.kind == .zero) return signed(T, s, 0);
    return round(T, env, s, @as(u128, x.sig) * y.sig, x.exp + y.exp);
}

pub fn div(comptime T: type, env: *Env, a: T, b: T) T {
    if (nan2(T, env, a, b)) |r| return r;
    var den = false;
    const x = unpack(T, env, a, &den);
    const y = unpack(T, env, b, &den);
    const s = x.sign != y.sign;
    if (x.kind == .inf) {
        if (y.kind == .inf) return invalid(T, env);
        noteDenormal(env, den);
        return signed(T, s, Fmt(T).inf);
    }
    if (y.kind == .inf) {
        noteDenormal(env, den);
        return signed(T, s, 0);
    }
    if (y.kind == .zero) {
        if (x.kind == .zero) return invalid(T, env);
        noteDenormal(env, den);
        env.flags |= ZE;
        return signed(T, s, Fmt(T).inf);
    }
    noteDenormal(env, den);
    if (x.kind == .zero) return signed(T, s, 0);
    const nx = norm(x);
    const ny = norm(y);
    const num = @as(u128, nx.sig) << 63;
    var q = num / ny.sig;
    if (num % ny.sig != 0) q |= 1;
    return round(T, env, s, q, nx.exp - ny.exp - 63);
}

pub fn sqrt(comptime T: type, env: *Env, a: T) T {
    if (isNan(T, a)) {
        if (isSnan(T, a)) env.flags |= IE;
        return quiet(T, a);
    }
    var den = false;
    const x = unpack(T, env, a, &den);
    if (x.kind == .zero) return signed(T, x.sign, 0);
    if (x.sign) return invalid(T, env);
    noteDenormal(env, den);
    if (x.kind == .inf) return Fmt(T).inf;
    const nx = norm(x);
    // sig * 2^exp = (sig << s) * 2^(exp - s), with exp - s even.
    const s: u7 = if (@mod(nx.exp - 62, 2) == 0) 62 else 63;
    const m = @as(u128, nx.sig) << s;
    var q: u128 = std.math.sqrt(m);
    if (q * q != m) q |= 1;
    return round(T, env, false, q, @divExact(nx.exp - s, 2));
}

/// MINSS and its kin: a < b ? a : b, so a NaN in either, or two zeros,
/// give b. Any NaN, quiet ones too, raises IE.
pub fn min(comptime T: type, env: *Env, a: T, b: T) T {
    return minMax(T, env, a, b, false);
}

/// MAXSS and its kin: a > b ? a : b, with MIN's rules.
pub fn max(comptime T: type, env: *Env, a: T, b: T) T {
    return minMax(T, env, a, b, true);
}

fn minMax(comptime T: type, env: *Env, a: T, b: T, is_max: bool) T {
    if (isNan(T, a) or isNan(T, b)) {
        env.flags |= IE;
        return b;
    }
    if (!env.daz and (isDenormal(T, a) or isDenormal(T, b))) env.flags |= DE;
    const x = daz(T, env, a);
    const y = daz(T, env, b);
    const o = order(T, x, y);
    return if (o == (if (is_max) Order.gt else Order.lt)) x else y;
}

pub const Order = enum(u2) { lt, eq, gt, un };

/// Orders two values that aren't NaNs.
fn order(comptime T: type, a: T, b: T) Order {
    const F = Fmt(T);
    const ma = a & ~F.sign_bit;
    const mb = b & ~F.sign_bit;
    if (ma == 0 and mb == 0) return .eq;
    const sa = a & F.sign_bit != 0;
    const sb = b & F.sign_bit != 0;
    if (sa != sb) return if (sa) .lt else .gt;
    if (ma == mb) return .eq;
    return if ((ma < mb) != sa) .lt else .gt;
}

/// Compares a with b. A signaling NaN raises IE, and so does a quiet one
/// when `signaling` (COMISS, and CMPPS's LT, LE, NLT, and NLE).
pub fn compare(comptime T: type, env: *Env, a: T, b: T, signaling: bool) Order {
    if (isNan(T, a) or isNan(T, b)) {
        if (signaling or isSnan(T, a) or isSnan(T, b)) env.flags |= IE;
        return .un;
    }
    if (!env.daz and (isDenormal(T, a) or isDenormal(T, b))) env.flags |= DE;
    return order(T, daz(T, env, a), daz(T, env, b));
}

// --------------------------------------------------------- conversions

/// binary32 to binary64: exact.
pub fn f32to64(env: *Env, a: u32) u64 {
    if (isNan(u32, a)) {
        if (isSnan(u32, a)) env.flags |= IE;
        const q: u64 = quiet(u32, a);
        return (q >> 31) << 63 | 0x7ff0_0000_0000_0000 | (q & 0x7f_ffff) << 29;
    }
    var den = false;
    const x = unpack(u32, env, a, &den);
    noteDenormal(env, den);
    return switch (x.kind) {
        .zero => signed(u64, x.sign, 0),
        .inf => signed(u64, x.sign, Fmt(u64).inf),
        .finite => round(u64, env, x.sign, x.sig, x.exp),
    };
}

/// binary64 to binary32, rounding.
pub fn f64to32(env: *Env, a: u64) u32 {
    if (isNan(u64, a)) {
        if (isSnan(u64, a)) env.flags |= IE;
        const q = quiet(u64, a);
        return @as(u32, @truncate(q >> 63)) << 31 | 0x7f80_0000 | @as(u32, @truncate((q >> 29) & 0x7f_ffff));
    }
    var den = false;
    const x = unpack(u64, env, a, &den);
    noteDenormal(env, den);
    return switch (x.kind) {
        .zero => signed(u32, x.sign, 0),
        .inf => signed(u32, x.sign, Fmt(u32).inf),
        .finite => round(u32, env, x.sign, x.sig, x.exp),
    };
}

/// An i32 to format T, rounding (binary64 is always exact).
pub fn fromI32(comptime T: type, env: *Env, v: i32) T {
    if (v == 0) return 0;
    return round(T, env, v < 0, @abs(v), 0);
}

/// To an i32, rounding in env.rc, or truncating. NaNs and values out of
/// range give the integer indefinite, 0x80000000, and raise IE.
pub fn toI32(comptime T: type, env: *Env, a: T, truncate: bool) i32 {
    const indefinite = std.math.minInt(i32);
    if (isNan(T, a)) {
        env.flags |= IE;
        return indefinite;
    }
    var den = false;
    const x = unpack(T, env, a, &den);
    switch (x.kind) {
        .zero => return 0,
        .inf => {
            env.flags |= IE;
            return indefinite;
        },
        .finite => {},
    }
    const rc: u2 = if (truncate) 3 else env.rc;
    // |a| >= 2^32 can't fit; the shifts below need it below 2^64.
    if (x.exp > 31 - @as(i32, Fmt(T).frac_bits)) {
        env.flags |= IE;
        return indefinite;
    }
    const r = roundAt(x.sig, -x.exp, x.sign, rc);
    const lim: u128 = if (x.sign) 1 << 31 else (1 << 31) - 1;
    if (r.m > lim) {
        env.flags |= IE;
        return indefinite;
    }
    if (r.inexact) env.flags |= PE;
    const m: u32 = @truncate(r.m);
    return @bitCast(if (x.sign) 0 -% m else m);
}

// ------------------------------------------- reciprocal approximations

/// RCPSS: about 1/a, to 12 bits or better. It raises nothing, reads
/// denormals as zeros, and gives zero for a result too small to be
/// normal.
pub fn rcp(a: u32) u32 {
    if (isNan(u32, a)) return quiet(u32, a);
    var env: Env = .{ .daz = true };
    const r = div(u32, &env, 0x3f80_0000, a);
    if (isDenormal(u32, r)) return r & Fmt(u32).sign_bit;
    return r;
}

/// RSQRTSS: about 1/sqrt(a), with RCPSS's rules. A negative a (not a
/// zero) gives the default NaN.
pub fn rsqrt(a: u32) u32 {
    if (isNan(u32, a)) return quiet(u32, a);
    var env: Env = .{ .daz = true };
    const x = daz(u32, &env, a);
    if (x & ~Fmt(u32).sign_bit == 0) return x | Fmt(u32).inf;
    if (x & Fmt(u32).sign_bit != 0) return Fmt(u32).default_nan;
    // 1/sqrt(a) = sqrt(1/a), rounded twice: well within 12 bits.
    const s = sqrt(u32, &env, div(u32, &env, 0x3f80_0000, x));
    if (isDenormal(u32, s)) return 0;
    return s;
}

// --------------------------------------------------------------- tests

const testing = std.testing;

fn bits32(v: f32) u32 {
    return @bitCast(v);
}

fn bits64(v: f64) u64 {
    return @bitCast(v);
}

test "binary32 and binary64 arithmetic matches the host in nearest" {
    var prng: std.Random.DefaultPrng = .init(7);
    const r = prng.random();
    for (0..20000) |_| {
        const a: f64 = @bitCast(r.int(u64) & 0xbfff_ffff_ffff_ffff);
        const b: f64 = @bitCast(r.int(u64) & 0xbfff_ffff_ffff_ffff);
        var env: Env = .{};
        try testing.expectEqual(bits64(a + b), add(u64, &env, bits64(a), bits64(b)));
        try testing.expectEqual(bits64(a - b), sub(u64, &env, bits64(a), bits64(b)));
        try testing.expectEqual(bits64(a * b), mul(u64, &env, bits64(a), bits64(b)));
        try testing.expectEqual(bits64(a / b), div(u64, &env, bits64(a), bits64(b)));
        try testing.expectEqual(bits64(@sqrt(@abs(a))), sqrt(u64, &env, bits64(@abs(a))));
        const c: f32 = @bitCast(r.int(u32));
        const d: f32 = @bitCast(r.int(u32));
        if (std.math.isNan(c) or std.math.isNan(d)) continue;
        const s32 = add(u32, &env, bits32(c), bits32(d));
        if (!std.math.isNan(c + d)) try testing.expectEqual(bits32(c + d), s32);
        const q32 = div(u32, &env, bits32(c), bits32(d));
        if (!std.math.isNan(c / d)) try testing.expectEqual(bits32(c / d), q32);
        try testing.expectEqual(bits32(@floatCast(a)), f64to32(&env, bits64(a)));
        try testing.expectEqual(bits64(@floatCast(c)), f32to64(&env, bits32(c)));
    }
}

test "x86's NaN and conversion rules" {
    var env: Env = .{};
    // inf - inf: the default NaN, negative.
    try testing.expectEqual(@as(u32, 0xffc0_0000), sub(u32, &env, 0x7f80_0000, 0x7f80_0000));
    try testing.expect(env.flags & IE != 0);
    // The first operand's NaN wins, quieted.
    env = .{};
    try testing.expectEqual(@as(u32, 0x7fc0_0001), add(u32, &env, 0x7f80_0001, 0x7fc0_0002));
    // MIN gives the second operand for a NaN or two zeros.
    try testing.expectEqual(@as(u32, 0x7f80_0001), min(u32, &env, 0x3f80_0000, 0x7f80_0001));
    try testing.expectEqual(@as(u32, 0x8000_0000), min(u32, &env, 0, 0x8000_0000));
    try testing.expectEqual(@as(u32, 0), max(u32, &env, 0x8000_0000, 0));
    // CVTTSS2SI of 2^31 overflows; of -2^31 doesn't.
    env = .{};
    try testing.expectEqual(@as(i32, std.math.minInt(i32)), toI32(u32, &env, 0x4f00_0000, true));
    try testing.expect(env.flags & IE != 0);
    env = .{};
    try testing.expectEqual(@as(i32, std.math.minInt(i32)), toI32(u32, &env, 0xcf00_0000, true));
    try testing.expectEqual(@as(u8, 0), env.flags);
    // 2.5 rounds to 2 in nearest, 3 up.
    try testing.expectEqual(@as(i32, 2), toI32(u64, &env, bits64(2.5), false));
    env.rc = 2;
    try testing.expectEqual(@as(i32, 3), toI32(u64, &env, bits64(2.5), false));
    // FTZ: the smallest normal halved is zero, with UE and PE.
    env = .{ .ftz = true };
    try testing.expectEqual(@as(u32, 0), mul(u32, &env, 0x0080_0000, 0x3f00_0000));
    try testing.expectEqual(UE | PE, env.flags);
    // DAZ: a denormal is a zero, with no DE.
    env = .{ .daz = true };
    try testing.expectEqual(@as(u32, 0x3f80_0000), add(u32, &env, 1, 0x3f80_0000));
    try testing.expectEqual(@as(u8, 0), env.flags);
}
