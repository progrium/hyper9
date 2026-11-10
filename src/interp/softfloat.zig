//! IEEE 754 binary16, binary32, and binary64 in software, for both
//! emulator CPUs: h86's SSE (src/interp/x86/sse.zig) and ha64's FP and
//! AdvSIMD (src/interp/a64/simd_exec.zig). Results never depend on the
//! host's FPU, or on what WebAssembly leaves unspecified (NaN bits, flags,
//! and rounding modes).
//!
//! Values travel as their bit patterns, `u16`, `u32`, and `u64`; each
//! function takes the pattern type as `T`.
//!
//! What differs between the architectures is a parameter in `Env`, whose
//! defaults are SSE's:
//!
//!   - rounding, including ties-away (FRINTA, FCVTAS) and round-to-odd
//!     (FCVTXN);
//!   - tininess, detected after rounding (x86) or before (Arm);
//!   - DAZ, denormal inputs read as zeros, which raises `ID` (Arm's IDC;
//!     x86 ignores it);
//!   - FTZ, tiny results flushed to zero, raising underflow, and inexact
//!     too when `ftz_inexact` (x86) but not without (Arm's FZ);
//!   - which NaN a NaN operand gives: the first NaN operand's, quieted
//!     (x86), the first signaling NaN's else the first quiet one's (Arm
//!     with FPCR.DN clear), or always the default NaN (Arm with DN set);
//!   - the default NaN's sign: negative on x86, positive on Arm.
//!
//! Operations whose rules are one architecture's alone stay with their
//! caller: Arm's FMAX and FMAXNM, its reciprocal estimates, and its
//! saturating integer conversions; x86's MINSS and MAXSS (`min`, `max`)
//! and RCPSS and RSQRTSS (`rcp`, `rsqrt`) are here only because sse.zig
//! used them first.

const std = @import("std");

/// Exception flags, in MXCSR's bit order (and the x87's).
pub const IE: u8 = 1 << 0;
/// A denormal operand was used, not flushed (x86's DE).
pub const DE: u8 = 1 << 1;
pub const ZE: u8 = 1 << 2;
pub const OE: u8 = 1 << 3;
pub const UE: u8 = 1 << 4;
pub const PE: u8 = 1 << 5;
/// A denormal input was flushed to zero by DAZ (Arm's IDC).
pub const ID: u8 = 1 << 6;

pub const Rounding = enum(u3) {
    near_even,
    down,
    up,
    zero,
    /// To nearest, ties away from zero.
    near_away,
    /// Toward zero, then set the lowest bit if inexact.
    odd,

    /// MXCSR's RC and the x87's: nearest, down, up, toward zero.
    pub fn fromX86(rc: u2) Rounding {
        return @enumFromInt(rc);
    }

    /// FPCR's RMode: nearest, up (+inf), down (-inf), toward zero.
    pub fn fromArm(rmode: u2) Rounding {
        return switch (rmode) {
            0 => .near_even,
            1 => .up,
            2 => .down,
            3 => .zero,
        };
    }
};

pub const Nans = enum {
    /// The first NaN operand, quieted (x86).
    first,
    /// The first signaling NaN, else the first quiet one, quieted (Arm).
    signaling_first,
    /// The default NaN (Arm's FPCR.DN).
    default,
};

pub const Tininess = enum { after_rounding, before_rounding };

pub const Env = struct {
    rounding: Rounding = .near_even,
    /// Denormal operands are zeros (raising ID).
    daz: bool = false,
    /// Tiny results are zeros, when underflow is masked.
    ftz: bool = false,
    /// A flushed result raises inexact as well as underflow.
    ftz_inexact: bool = true,
    /// Underflow is masked: a tiny result raises UE only when it's also
    /// inexact. Unmasked, every tiny result does.
    um: bool = true,
    tininess: Tininess = .after_rounding,
    nans: Nans = .first,
    default_nan_negative: bool = true,
    /// The exceptions raised, accumulated.
    flags: u8 = 0,

    pub fn fromMxcsr(m: u32) Env {
        return .{
            .rounding = .fromX86(@truncate(m >> 13)),
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
        pub const frac_bits = switch (T) {
            u16 => 10,
            u32 => 23,
            u64 => 52,
            else => @compileError("softfloat: no format for " ++ @typeName(T)),
        };
        pub const exp_bits = bits - 1 - frac_bits;
        pub const exp_max: T = (1 << exp_bits) - 1;
        pub const bias: i32 = (1 << (exp_bits - 1)) - 1;
        pub const sign_bit: T = 1 << (bits - 1);
        pub const frac_mask: T = (1 << frac_bits) - 1;
        pub const quiet_bit: T = 1 << (frac_bits - 1);
        pub const inf: T = exp_max << frac_bits;
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

pub fn isInf(comptime T: type, a: T) bool {
    return a & ~Fmt(T).sign_bit == Fmt(T).inf;
}

pub fn isZero(comptime T: type, a: T) bool {
    return a & ~Fmt(T).sign_bit == 0;
}

pub fn isDenormal(comptime T: type, a: T) bool {
    const F = Fmt(T);
    return a & F.inf == 0 and a & F.frac_mask != 0;
}

pub fn quiet(comptime T: type, a: T) T {
    return a | Fmt(T).quiet_bit;
}

pub fn defaultNan(comptime T: type, env: *const Env) T {
    const F = Fmt(T);
    return (if (env.default_nan_negative) F.sign_bit else 0) | F.inf | F.quiet_bit;
}

/// `a` as DAZ sees it: a denormal is a zero of its sign, raising ID.
pub fn daz(comptime T: type, env: *Env, a: T) T {
    if (env.daz and isDenormal(T, a)) {
        env.flags |= ID;
        return a & Fmt(T).sign_bit;
    }
    return a;
}

/// The NaN result for an operation on `ops`, by env.nans, raising IE on
/// a signaling NaN; null when none is a NaN. Under DAZ it raises ID for
/// a denormal among them too, as Arm reads every operand first.
pub fn pickNan(comptime T: type, env: *Env, ops: []const T) ?T {
    var first: ?T = null;
    var first_s: ?T = null;
    for (ops) |x| {
        if (!isNan(T, x)) continue;
        if (first == null) first = x;
        if (first_s == null and isSnan(T, x)) first_s = x;
    }
    const f = first orelse return null;
    if (env.daz) for (ops) |x| {
        if (isDenormal(T, x)) env.flags |= ID;
    };
    if (first_s != null) env.flags |= IE;
    return switch (env.nans) {
        .first => quiet(T, f),
        .signaling_first => quiet(T, first_s orelse f),
        .default => defaultNan(T, env),
    };
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
fn unpack(comptime T: type, env: *Env, a: T, den: *bool) Num {
    const F = Fmt(T);
    const sign = a & F.sign_bit != 0;
    const e: i32 = @intCast((a >> F.frac_bits) & F.exp_max);
    const frac: u64 = a & F.frac_mask;
    if (e == F.exp_max) return .{ .sign = sign, .kind = .inf };
    if (e == 0) {
        if (frac == 0) return .{ .sign = sign, .kind = .zero };
        if (env.daz) {
            env.flags |= ID;
            return .{ .sign = sign, .kind = .zero };
        }
        den.* = true;
        return .{ .sign = sign, .kind = .finite, .sig = frac, .exp = 1 - F.bias - F.frac_bits };
    }
    return .{ .sign = sign, .kind = .finite, .sig = frac | (@as(u64, 1) << F.frac_bits), .exp = e - F.bias - F.frac_bits };
}

fn signed(comptime T: type, sign: bool, mag: T) T {
    return if (sign) mag | Fmt(T).sign_bit else mag;
}

/// x86's NaN rule for two operands, by env.nans.
fn nan2(comptime T: type, env: *Env, a: T, b: T) ?T {
    return pickNan(T, env, &.{ a, b });
}

fn invalid(comptime T: type, env: *Env) T {
    env.flags |= IE;
    return defaultNan(T, env);
}

const Rounded = struct { m: u128, inexact: bool };

/// Rounds sig >> shift to an integer by `rnd`, for a value of `sign`.
fn roundAt(sig: u128, shift: i32, sign: bool, rnd: Rounding) Rounded {
    if (shift <= 0) return .{ .m = sig << @intCast(-shift), .inexact = false };
    if (shift >= 128) {
        // sig < 2^127 (callers keep it so), below half of the last place.
        const up = sig != 0 and switch (rnd) {
            .near_even, .near_away, .zero => false,
            .down => sign,
            .up => !sign,
            .odd => true,
        };
        return .{ .m = @intFromBool(up), .inexact = sig != 0 };
    }
    const s: u7 = @intCast(shift);
    const m0 = sig >> s;
    const rem = sig & ((@as(u128, 1) << s) - 1);
    const half = @as(u128, 1) << (s - 1);
    if (rnd == .odd) return .{ .m = m0 | @intFromBool(rem != 0), .inexact = rem != 0 };
    const up = switch (rnd) {
        .near_even => rem > half or (rem == half and m0 & 1 == 1),
        .near_away => rem >= half,
        .down => sign and rem != 0,
        .up => !sign and rem != 0,
        .zero, .odd => false,
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
        if (env.tininess == .after_rounding and top == emin - 1 and
            roundAt(sig, n - (p - 1), sign, env.rounding).m >> @intCast(p) != 0) tiny = false;
    }
    const shift: i32 = if (top >= emin) n - (p - 1) else n - (p - 1) + (emin - top);
    const r = roundAt(sig, shift, sign, env.rounding);
    if (tiny) {
        if (!env.um) {
            env.flags |= UE;
        } else if (env.ftz) {
            env.flags |= UE | (if (env.ftz_inexact) PE else 0);
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
    const to_inf = switch (env.rounding) {
        .near_even, .near_away => true,
        .down => sign,
        .up => !sign,
        .zero, .odd => false,
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

/// v >> d, with the bits shifted out jammed into the lowest bit.
fn jamShift(comptime U: type, v: U, d: u32) U {
    if (d == 0) return v;
    if (d >= @bitSizeOf(U)) return @intFromBool(v != 0);
    const s: std.math.Log2Int(U) = @intCast(d);
    return (v >> s) | @intFromBool(v & ((@as(U, 1) << s) - 1) != 0);
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
        const s = if (x.sign == y.sign) x.sign else env.rounding == .down;
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
    const S = jamShift(u128, @as(u128, small.sig) << 63, @intCast(big.exp - small.exp));
    const e = big.exp - 63;
    if (big_sign == small_sign) return round(T, env, big_sign, jamShift(u128, B + S, 1), e + 1);
    const d = B - S;
    if (d == 0) return signed(T, env.rounding == .down, 0);
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
    if (pickNan(T, env, &.{a})) |r| return r;
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

/// a * b + c, rounded once. A NaN in a or b gives pickNan's result over
/// all three; inf * 0 raises IE and gives c's NaN if it's one, else the
/// default NaN. Arm's rule for inf * 0 + qNaN (the default NaN) is its
/// caller's to apply first.
pub fn mulAdd(comptime T: type, env: *Env, a: T, b: T, c: T) T {
    return mulAddScaled(T, env, a, b, c, 0);
}

/// (a * b + c) * 2^scale, rounded once (Arm's FRSQRTS halves its sum).
pub fn mulAddScaled(comptime T: type, env: *Env, a: T, b: T, c: T, scale: i32) T {
    if (isNan(T, a) or isNan(T, b)) return pickNan(T, env, &.{ a, b, c }).?;
    var den = false;
    const x = unpack(T, env, a, &den);
    const y = unpack(T, env, b, &den);
    if ((x.kind == .inf and y.kind == .zero) or (x.kind == .zero and y.kind == .inf)) {
        env.flags |= IE;
        if (isNan(T, c)) return pickNan(T, env, &.{c}).?;
        _ = daz(T, env, c);
        return defaultNan(T, env);
    }
    if (pickNan(T, env, &.{c})) |r| return r;
    const z = unpack(T, env, c, &den);
    const ps = x.sign != y.sign;
    if (x.kind == .inf or y.kind == .inf) {
        if (z.kind == .inf and z.sign != ps) return invalid(T, env);
        noteDenormal(env, den);
        return signed(T, ps, Fmt(T).inf);
    }
    noteDenormal(env, den);
    if (z.kind == .inf) return signed(T, z.sign, Fmt(T).inf);
    if (x.kind == .zero or y.kind == .zero) {
        if (z.kind == .zero) return signed(T, if (ps == z.sign) ps else env.rounding == .down, 0);
        return round(T, env, z.sign, z.sig, z.exp + scale);
    }
    const P = @as(u128, x.sig) * y.sig;
    const pe = x.exp + y.exp;
    if (z.kind == .zero) return round(T, env, ps, P, pe + scale);
    // Both at 128 bits up in 256, the smaller exponent's shifted down.
    var pw = @as(u256, P) << 128;
    var cw = @as(u256, z.sig) << 128;
    var e: i32 = undefined;
    if (pe >= z.exp) {
        cw = jamShift(u256, cw, @intCast(pe - z.exp));
        e = pe - 128;
    } else {
        pw = jamShift(u256, pw, @intCast(z.exp - pe));
        e = z.exp - 128;
    }
    var sign = ps;
    var sum: u256 = undefined;
    if (ps == z.sign) {
        sum = pw + cw;
    } else if (pw >= cw) {
        sum = pw - cw;
    } else {
        sum = cw - pw;
        sign = z.sign;
    }
    if (sum == 0) return signed(T, env.rounding == .down, 0);
    const n: i32 = 256 - @as(i32, @clz(sum));
    if (n > 126) {
        sum = jamShift(u256, sum, @intCast(n - 126));
        e += n - 126;
    }
    return round(T, env, sign, @intCast(sum), e + scale);
}

/// MINSS and its kin: a < b ? a : b, so a NaN in either, or two zeros,
/// give b. Any NaN, quiet ones too, raises IE. (x86's rule.)
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

/// Orders two values that aren't NaNs (DAZ not applied).
pub fn order(comptime T: type, a: T, b: T) Order {
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
/// when `signaling` (COMISS, CMPPS's LT, LE, NLT, and NLE, and FCMPE).
pub fn compare(comptime T: type, env: *Env, a: T, b: T, signaling: bool) Order {
    const x = daz(T, env, a);
    const y = daz(T, env, b);
    if (isNan(T, a) or isNan(T, b)) {
        if (signaling or isSnan(T, a) or isSnan(T, b)) env.flags |= IE;
        return .un;
    }
    if (!env.daz and (isDenormal(T, a) or isDenormal(T, b))) env.flags |= DE;
    return order(T, x, y);
}

// --------------------------------------------------------- conversions

/// Between formats, rounding when narrowing. A NaN keeps its sign and the
/// top of its payload, quieted (or is the default NaN under Nans.default).
pub fn convert(comptime To: type, comptime From: type, env: *Env, a: From) To {
    const F = Fmt(From);
    const G = Fmt(To);
    if (isNan(From, a)) {
        if (isSnan(From, a)) env.flags |= IE;
        if (env.nans == .default) return defaultNan(To, env);
        const frac = quiet(From, a) & F.frac_mask;
        const f: To = if (G.frac_bits >= F.frac_bits)
            @as(To, @intCast(frac)) << (G.frac_bits - F.frac_bits)
        else
            @intCast(frac >> (F.frac_bits - G.frac_bits));
        return signed(To, a & F.sign_bit != 0, G.inf | f);
    }
    var den = false;
    const x = unpack(From, env, a, &den);
    noteDenormal(env, den);
    return switch (x.kind) {
        .zero => signed(To, x.sign, 0),
        .inf => signed(To, x.sign, G.inf),
        .finite => round(To, env, x.sign, x.sig, x.exp),
    };
}

/// binary32 to binary64: exact.
pub fn f32to64(env: *Env, a: u32) u64 {
    return convert(u64, u32, env, a);
}

/// binary64 to binary32, rounding.
pub fn f64to32(env: *Env, a: u64) u32 {
    return convert(u32, u64, env, a);
}

/// An integer to format T, rounding.
pub fn fromInt(comptime T: type, comptime I: type, env: *Env, v: I) T {
    return fromFixed(T, I, env, v, 0);
}

/// A fixed-point value v / 2^fbits to format T, rounding once.
pub fn fromFixed(comptime T: type, comptime I: type, env: *Env, v: I, fbits: u32) T {
    if (v == 0) return 0;
    const neg = @typeInfo(I).int.signedness == .signed and v < 0;
    return round(T, env, neg, @abs(v), -@as(i32, @intCast(fbits)));
}

/// An i32 to format T, rounding (binary64 is always exact).
pub fn fromI32(comptime T: type, env: *Env, v: i32) T {
    return fromInt(T, i32, env, v);
}

/// `a` rounded by `rnd` to an integer of type I, raising PE if inexact;
/// or null, raising IE, for a NaN, an infinity, or a value out of I's
/// range. What the caller returns then is its architecture's (x86's
/// integer indefinite, Arm's saturation).
pub fn toInt(comptime T: type, comptime I: type, env: *Env, a: T, rnd: Rounding) ?I {
    return toFixed(T, I, env, a, rnd, 0);
}

/// `a` * 2^fbits rounded to an integer of type I, as toInt.
pub fn toFixed(comptime T: type, comptime I: type, env: *Env, a: T, rnd: Rounding, fbits: u32) ?I {
    const info = @typeInfo(I).int;
    if (isNan(T, a)) {
        env.flags |= IE;
        return null;
    }
    var den = false;
    var x = unpack(T, env, a, &den);
    x.exp += @intCast(fbits);
    switch (x.kind) {
        .zero => return 0,
        .inf => {
            env.flags |= IE;
            return null;
        },
        .finite => {},
    }
    // |a| >= 2^65 can't fit; the shifts below need it below 2^127.
    if (x.exp > 64 - @as(i32, Fmt(T).frac_bits)) {
        env.flags |= IE;
        return null;
    }
    const r = roundAt(x.sig, -x.exp, x.sign, rnd);
    const lim: u128 = if (info.signedness == .signed)
        (if (x.sign) @as(u128, 1) << (info.bits - 1) else (@as(u128, 1) << (info.bits - 1)) - 1)
    else if (x.sign) 0 else (@as(u128, 1) << info.bits) - 1;
    if (r.m > lim) {
        env.flags |= IE;
        return null;
    }
    if (r.inexact) env.flags |= PE;
    const U = std.meta.Int(.unsigned, info.bits);
    const m: U = @intCast(r.m);
    return @bitCast(if (x.sign) 0 -% m else m);
}

/// To an i32, rounding in env.rounding, or truncating. NaNs and values out
/// of range give the integer indefinite, 0x80000000, and raise IE.
pub fn toI32(comptime T: type, env: *Env, a: T, truncate: bool) i32 {
    return toInt(T, i32, env, a, if (truncate) .zero else env.rounding) orelse std.math.minInt(i32);
}

/// `a` rounded by `rnd` to an integral value in its own format, raising PE
/// if inexact only when `exact` (Arm's FRINTX; SoftFloat's `exact`).
pub fn roundToInt(comptime T: type, env: *Env, a: T, rnd: Rounding, exact: bool) T {
    if (pickNan(T, env, &.{a})) |r| return r;
    var den = false;
    const x = unpack(T, env, a, &den);
    switch (x.kind) {
        .zero => return signed(T, x.sign, 0),
        .inf => return a,
        .finite => {},
    }
    if (x.exp >= 0) return a;
    const r = roundAt(x.sig, -x.exp, x.sign, rnd);
    if (r.inexact and exact) env.flags |= PE;
    if (r.m == 0) return signed(T, x.sign, 0);
    var e2: Env = .{};
    return round(T, &e2, x.sign, r.m, 0);
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
    if (x & Fmt(u32).sign_bit != 0) return defaultNan(u32, &env);
    // 1/sqrt(a), rounded twice: well within 12 bits. (sqrt(1/a) would
    // lose large a, whose reciprocal is denormal and DAZ reads as zero.)
    const s = div(u32, &env, 0x3f80_0000, sqrt(u32, &env, x));
    if (isDenormal(u32, s)) return 0;
    return s;
}

// --------------------------------------------------------------- tests

const testing = std.testing;

test {
    _ = @import("softfloat_vectors.zig");
}

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
        const h: f16 = @floatCast(c);
        try testing.expectEqual(@as(u16, @bitCast(h)), convert(u16, u32, &env, bits32(c)));
        const e: f64 = @bitCast(r.int(u64) & 0xbfff_ffff_ffff_ffff);
        const fma = @mulAdd(f64, a, b, e);
        if (!std.math.isNan(fma)) try testing.expectEqual(bits64(fma), mulAdd(u64, &env, bits64(a), bits64(b), bits64(e)));
        const fma32 = @mulAdd(f32, c, d, @floatCast(e));
        if (!std.math.isNan(fma32)) try testing.expectEqual(bits32(fma32), mulAdd(u32, &env, bits32(c), bits32(d), bits32(@floatCast(e))));
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
    env.rounding = .up;
    try testing.expectEqual(@as(i32, 3), toI32(u64, &env, bits64(2.5), false));
    // FTZ: the smallest normal halved is zero, with UE and PE.
    env = .{ .ftz = true };
    try testing.expectEqual(@as(u32, 0), mul(u32, &env, 0x0080_0000, 0x3f00_0000));
    try testing.expectEqual(UE | PE, env.flags);
    // DAZ: a denormal is a zero, raising only ID.
    env = .{ .daz = true };
    try testing.expectEqual(@as(u32, 0x3f80_0000), add(u32, &env, 1, 0x3f80_0000));
    try testing.expectEqual(ID, env.flags);
}

test "Arm's NaN, tininess, and flush rules" {
    const arm: Env = .{ .tininess = .before_rounding, .nans = .signaling_first, .default_nan_negative = false, .ftz_inexact = false };
    var env = arm;
    // inf - inf: the default NaN, positive.
    try testing.expectEqual(@as(u32, 0x7fc0_0000), sub(u32, &env, 0x7f80_0000, 0x7f80_0000));
    // A signaling NaN wins over an earlier quiet one.
    env = arm;
    try testing.expectEqual(@as(u32, 0x7fc0_0002), add(u32, &env, 0x7fc0_0001, 0x7f80_0002));
    try testing.expectEqual(IE, env.flags);
    // DN: the default NaN.
    env = arm;
    env.nans = .default;
    try testing.expectEqual(@as(u64, 0x7ff8_0000_0000_0000), mul(u64, &env, 0x7ff0_0000_0000_0001, 0));
    // Tininess: 2^-126 (1 - 2^-25) rounds up to 2^-126. It's tiny before
    // rounding, but not after.
    const t: u64 = 0x380f_ffff_f000_0000;
    env = arm;
    try testing.expectEqual(@as(u32, 0x0080_0000), f64to32(&env, t));
    try testing.expectEqual(UE | PE, env.flags);
    var after: Env = .{};
    try testing.expectEqual(@as(u32, 0x0080_0000), f64to32(&after, t));
    try testing.expectEqual(PE, after.flags);
    // FZ: flushed to zero, raising only underflow.
    env = arm;
    env.ftz = true;
    try testing.expectEqual(@as(u32, 0), f64to32(&env, t));
    try testing.expectEqual(UE, env.flags);
    // Ties away and round to odd.
    env = .{ .rounding = .near_away };
    try testing.expectEqual(bits64(3.0), roundToInt(u64, &env, bits64(2.5), .near_away, false));
    try testing.expectEqual(bits64(-3.0), roundToInt(u64, &env, bits64(-2.5), .near_away, false));
    env = .{ .rounding = .odd };
    try testing.expectEqual(@as(u32, 0x3f80_0001), f64to32(&env, 0x3ff0_0000_0000_0001));
}

test "rsqrt of large and small values" {
    // 2^126: 2^-63, though 1/a is denormal.
    try testing.expectEqual(@as(u32, 0x2000_0000), rsqrt(0x7e80_0000));
    try testing.expectEqual(@as(u32, 0x3f00_0000), rsqrt(0x4080_0000));
}

test "integer conversions" {
    var env: Env = .{};
    try testing.expectEqual(@as(?u32, null), toInt(u64, u32, &env, bits64(-1.0), .zero));
    env = .{};
    try testing.expectEqual(@as(?u32, 0), toInt(u64, u32, &env, bits64(-0.5), .zero));
    try testing.expectEqual(PE, env.flags);
    try testing.expectEqual(@as(?i64, std.math.minInt(i64)), toInt(u64, i64, &env, bits64(-0x1p63), .zero));
    try testing.expectEqual(@as(?u64, 0xffff_ffff_ffff_f800), toInt(u64, u64, &env, 0x43ef_ffff_ffff_ffff, .zero));
    try testing.expectEqual(bits64(0x1p64), fromInt(u64, u64, &env, std.math.maxInt(u64)));
    try testing.expectEqual(bits32(-0x1p63), fromInt(u32, i64, &env, std.math.minInt(i64)));
    // Fixed point: 3 / 2^64 to binary64, and 0.75 * 2^2 to an integer.
    try testing.expectEqual(bits64(0x3p-64), fromFixed(u64, u64, &env, 3, 64));
    try testing.expectEqual(@as(?i32, 3), toFixed(u64, i32, &env, bits64(0.75), .zero, 2));
}
