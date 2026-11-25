//! x86-64-v2's vector instructions, for hx64: SSE3, SSSE3, SSE4.1, and
//! SSE4.2, with SSE4.2's CRC32. sse.zig sends the 0F 38 and 0F 3A maps
//! here (`map38` and `map3a`, keyed by `Inst64.op3`), and asks `sse3` for
//! the SSE3 forms in the 0F map before its own. h86 doesn't have them:
//! the three-byte maps are #UD in legacy mode (table.long_only), and
//! sse.zig calls `sse3` only in long mode.
//!
//! SSSE3's integer instructions have an MMX form (no prefix) and an XMM
//! one (66), as SSE2's do; everything else is 66-only, but CRC32 (F2)
//! and MOVBE (no prefix, and not reported by CPUID, so #UD). A legacy
//! SSE encoding's 128-bit memory operand must be 16-byte aligned (#GP),
//! except for LDDQU and PCMPESTRI and its siblings; the narrower ones
//! (PMOVSX, ROUNDSS, INSERTPS, PINSRB, the PEXTRs, and the rest) needn't
//! be.

const std = @import("std");
const cpu = @import("cpu.zig");
const fp = @import("../softfloat.zig");
const flags = @import("flags.zig");
const sse = @import("sse.zig");

const Pfx = sse.Pfx;
const ud = sse.ud;
const xreg = sse.xreg;
const xsrc = sse.xsrc;
const lo64 = sse.lo64;
const hi64 = sse.hi64;
const join = sse.join;
const V = sse.V;
const vec = sse.vec;
const bits = sse.bits;
const mask = sse.mask;
const signed = sse.signed;
const sat = sse.sat;

// ------------------------------------------------------------ SSE3

/// The SSE3 forms in the 0F map: MOVSLDUP, MOVSHDUP, MOVDDUP, ADDSUBPS
/// and PD, HADDPS and PD, HSUBPS and PD, and LDDQU. Returns false for
/// anything else, which sse.zig then runs as SSE2 (or raises #UD for).
pub fn sse3(x: anytype, p: Pfx, op: u8) !bool {
    const i = x.i;
    switch (op) {
        0x12, 0x16 => switch (p) {
            .f3 => {
                // MOVSLDUP and MOVSHDUP.
                const s: [4]u32 = @bitCast(try xsrc(x, 16, true));
                const k: usize = if (op == 0x16) 1 else 0;
                xreg(x).* = @bitCast([4]u32{ s[k], s[k], s[k + 2], s[k + 2] });
                return true;
            },
            .f2 => {
                if (op != 0x12) return false;
                // MOVDDUP: the low quadword, twice (8 bytes from memory).
                const v = lo64(try xsrc(x, 8, false));
                xreg(x).* = join(v, v);
                return true;
            },
            else => return false,
        },
        0x7c, 0x7d, 0xd0 => switch (p) {
            .p66 => {
                try horizontal(x, u64, op);
                return true;
            },
            .f2 => {
                try horizontal(x, u32, op);
                return true;
            },
            else => return false,
        },
        0xf0 => {
            if (p != .f2) return false;
            // LDDQU: an unaligned load, memory only.
            if (!i.mem) {
                try ud(x);
                return true;
            }
            xreg(x).* = try xsrc(x, 16, false);
            return true;
        },
        else => return false,
    }
}

/// One floating-point lane of add (58), sub (5C), or mul (59), with
/// MXCSR's flags gathered in `e` and PE for an unmasked overflow or
/// underflow as sse.zig's `lanes` gives it.
fn fpOp(x: anytype, comptime T: type, e: *fp.Env, op: u8, a: T, b: T) T {
    var le = e.*;
    le.flags = 0;
    const r = switch (op) {
        0x58 => fp.add(T, &le, a, b),
        0x5c => fp.sub(T, &le, a, b),
        0x59 => fp.mul(T, &le, a, b),
        else => unreachable,
    };
    if (sse.unmaskedRange(x, le.flags)) {
        const u = fp.daz(T, &le, a);
        const v = fp.daz(T, &le, b);
        le.flags &= ~fp.PE;
        if (!sse.exactUnbounded(T, op, u, v)) le.flags |= fp.PE;
    }
    e.flags |= le.flags;
    return r;
}

/// HADD (7C), HSUB (7D), and ADDSUB (D0), on T's lanes.
fn horizontal(x: anytype, comptime T: type, op: u8) !void {
    const n = 16 / @sizeOf(T);
    const a: [n]T = @bitCast(xreg(x).*);
    const b: [n]T = @bitCast(try xsrc(x, 16, true));
    var e = sse.env(x);
    var r: [n]T = undefined;
    switch (op) {
        0xd0 => for (0..n) |k| {
            r[k] = fpOp(x, T, &e, if (k & 1 == 0) 0x5c else 0x58, a[k], b[k]);
        },
        else => {
            const f: u8 = if (op == 0x7c) 0x58 else 0x5c;
            for (0..n / 2) |k| {
                r[k] = fpOp(x, T, &e, f, a[2 * k], a[2 * k + 1]);
                r[n / 2 + k] = fpOp(x, T, &e, f, b[2 * k], b[2 * k + 1]);
            }
        },
    }
    try sse.raise(x, &e);
    xreg(x).* = @bitCast(r);
}

// ------------------------------------------------------------ 0F 38

/// 0F 38 xx: SSSE3's integer instructions (00-0B, 1C-1E), SSE4.1's (10-
/// 41), SSE4.2's PCMPGTQ (37) and CRC32 (F2 F0 and F1).
pub fn map38(x: anytype) !void {
    const i = x.i;
    const p = sse.prefix(x);
    const op = i.op3;
    // CRC32 and MOVBE take F2 and 66 together, and F2 wins, as `prefix`
    // has it.
    if (op == 0xf0 or op == 0xf1) return if (p == .f2) crc32(x, op) else ud(x);
    switch (op) {
        0x00...0x0b, 0x1c...0x1e => switch (p) {
            .none => return ssse3(x, u64, op),
            .p66 => return ssse3(x, u128, op),
            else => return ud(x),
        },
        else => {},
    }
    if (p != .p66) return ud(x);
    const d = xreg(x);
    switch (op) {
        0x10, 0x14, 0x15 => {
            // PBLENDVB, BLENDVPS, and BLENDVPD: by XMM0's sign bits.
            const b = try xsrc(x, 16, true);
            const sel = switch (op) {
                0x10 => lanesBy(u8, x.c.xmm[0]),
                0x14 => lanesBy(u32, x.c.xmm[0]),
                else => lanesBy(u64, x.c.xmm[0]),
            };
            d.* = (d.* & ~sel) | (b & sel);
        },
        0x17 => {
            // PTEST.
            const b = try xsrc(x, 16, true);
            var f: u32 = 0;
            if (d.* & b == 0) f |= flags.ZF;
            if (~d.* & b == 0) f |= flags.CF;
            x.c.fl.setMasked(flags.arith, f);
        },
        0x20...0x25, 0x30...0x35 => {
            // PMOVSX and PMOVZX: the low 8, 4, or 2 bytes widened.
            const sx = op < 0x30;
            const v: u128 = switch (op & 0xf) {
                0 => try widen(x, u8, u16, sx),
                1 => try widen(x, u8, u32, sx),
                2 => try widen(x, u8, u64, sx),
                3 => try widen(x, u16, u32, sx),
                4 => try widen(x, u16, u64, sx),
                else => try widen(x, u32, u64, sx),
            };
            d.* = v;
        },
        0x2a => {
            // MOVNTDQA: an aligned load, memory only.
            if (!i.mem) return ud(x);
            d.* = try xsrc(x, 16, true);
        },
        0x26, 0x27, 0x2c...0x2f, 0x36, 0x42...0xef, 0xf2...0xff => return ud(x),
        else => {
            const b = try xsrc(x, 16, true);
            d.* = sse41(op, d.*, b) orelse return ud(x);
        },
    }
}

/// All ones in each T lane of `m` whose sign bit is set.
fn lanesBy(comptime T: type, m: u128) u128 {
    const n = 128 / @bitSizeOf(T);
    const S = @Int(.signed, @bitSizeOf(T));
    const v: @Vector(n, S) = @bitCast(m);
    return @bitCast(v >> @splat(@bitSizeOf(T) - 1));
}

/// PMOVSX's and PMOVZX's source, the low 16 / (To / From) bytes of an XMM
/// register or memory, each From widened to To.
fn widen(x: anytype, comptime From: type, comptime To: type, sx: bool) !u128 {
    const n = 128 / @bitSizeOf(To);
    const s = try xsrc(x, n * @sizeOf(From), false);
    const f: [16 / @sizeOf(From)]From = @bitCast(s);
    var r: [n]To = undefined;
    const SF = @Int(.signed, @bitSizeOf(From));
    const ST = @Int(.signed, @bitSizeOf(To));
    inline for (0..n) |k| {
        r[k] = if (sx) @bitCast(@as(ST, @as(SF, @bitCast(f[k])))) else f[k];
    }
    return @bitCast(r);
}

/// SSE4.1's and SSE4.2's two-operand integer instructions in 0F 38:
/// a = a op b, or null for an opcode that isn't one.
fn sse41(op: u8, a: u128, b: u128) ?u128 {
    const W = u128;
    return switch (op) {
        0x28 => blk: {
            // PMULDQ: the even dwords' signed products.
            const x32 = signed(W, i32, a);
            const y32 = signed(W, i32, b);
            const r = [2]i64{ @as(i64, x32[0]) * y32[0], @as(i64, x32[2]) * y32[2] };
            break :blk @bitCast(r);
        },
        0x29 => mask(W, u64, vec(W, u64, a) == vec(W, u64, b)),
        0x2b => blk: {
            // PACKUSDW.
            const x32: [4]i32 = @bitCast(a);
            const y32: [4]i32 = @bitCast(b);
            var r: [8]u16 = undefined;
            for (0..4) |k| {
                r[k] = sat(i32, u16, x32[k]);
                r[4 + k] = sat(i32, u16, y32[k]);
            }
            break :blk @bitCast(r);
        },
        0x37 => mask(W, i64, signed(W, i64, a) > signed(W, i64, b)),
        0x38 => bits(W, @min(signed(W, i8, a), signed(W, i8, b))),
        0x39 => bits(W, @min(signed(W, i32, a), signed(W, i32, b))),
        0x3a => bits(W, @min(vec(W, u16, a), vec(W, u16, b))),
        0x3b => bits(W, @min(vec(W, u32, a), vec(W, u32, b))),
        0x3c => bits(W, @max(signed(W, i8, a), signed(W, i8, b))),
        0x3d => bits(W, @max(signed(W, i32, a), signed(W, i32, b))),
        0x3e => bits(W, @max(vec(W, u16, a), vec(W, u16, b))),
        0x3f => bits(W, @max(vec(W, u32, a), vec(W, u32, b))),
        0x40 => bits(W, vec(W, u32, a) *% vec(W, u32, b)),
        0x41 => blk: {
            // PHMINPOSUW: the least word of b and its index, the first of
            // equals.
            const w: [8]u16 = @bitCast(b);
            var k: u16 = 0;
            for (1..8) |j| {
                if (w[j] < w[k]) k = @intCast(j);
            }
            break :blk @as(u128, w[k]) | @as(u128, k) << 16;
        },
        else => null,
    };
}

/// SSSE3's integer instructions, on MMX (W u64) or XMM (u128) registers.
fn ssse3(x: anytype, comptime W: type, op: u8) !void {
    const i = x.i;
    const is_mmx = W == u64;
    var a: W = undefined;
    var b: W = undefined;
    if (is_mmx) {
        try sse.mmx(x);
        a = sse.getMM(x, sse.mmReg(i));
        b = try sse.msrc(x);
    } else {
        a = xreg(x).*;
        b = try xsrc(x, 16, true);
    }
    const r: W = ssse3Op(W, op, a, b);
    if (is_mmx) sse.setMM(x, sse.mmReg(i), r) else xreg(x).* = r;
}

fn ssse3Op(comptime W: type, op: u8, a: W, b: W) W {
    const nb = @bitSizeOf(W) / 8;
    return switch (op) {
        0x00 => blk: {
            // PSHUFB.
            const s: [nb]u8 = @bitCast(a);
            const c: [nb]u8 = @bitCast(b);
            var r: [nb]u8 = undefined;
            for (0..nb) |k| r[k] = if (c[k] & 0x80 != 0) 0 else s[c[k] & (nb - 1)];
            break :blk @bitCast(r);
        },
        0x01 => hop(W, u16, a, b, .add),
        0x02 => hop(W, u32, a, b, .add),
        0x03 => hop(W, i16, a, b, .adds),
        0x05 => hop(W, u16, a, b, .sub),
        0x06 => hop(W, u32, a, b, .sub),
        0x07 => hop(W, i16, a, b, .subs),
        0x04 => blk: {
            // PMADDUBSW: a's unsigned bytes times b's signed ones, each
            // pair's sum saturated.
            const s: [nb]u8 = @bitCast(a);
            const c: [nb]i8 = @bitCast(b);
            var r: [nb / 2]i16 = undefined;
            for (0..nb / 2) |k| {
                const v = @as(i32, s[2 * k]) * c[2 * k] + @as(i32, s[2 * k + 1]) * c[2 * k + 1];
                r[k] = sat(i32, i16, v);
            }
            break :blk @bitCast(r);
        },
        0x08 => psign(W, i8, a, b),
        0x09 => psign(W, i16, a, b),
        0x0a => psign(W, i32, a, b),
        0x0b => blk: {
            // PMULHRSW.
            const s: [nb / 2]i16 = @bitCast(a);
            const c: [nb / 2]i16 = @bitCast(b);
            var r: [nb / 2]i16 = undefined;
            for (0..nb / 2) |k| {
                const v = ((@as(i32, s[k]) * c[k] >> 14) + 1) >> 1;
                r[k] = @truncate(v);
            }
            break :blk @bitCast(r);
        },
        0x1c => bits(W, @abs(signed(W, i8, b))),
        0x1d => bits(W, @abs(signed(W, i16, b))),
        0x1e => bits(W, @abs(signed(W, i32, b))),
        else => unreachable,
    };
}

const Hop = enum { add, sub, adds, subs };

/// PHADD and PHSUB: each adjacent pair of a's lanes, then b's.
fn hop(comptime W: type, comptime T: type, a: W, b: W, how: Hop) W {
    const n = @bitSizeOf(W) / @bitSizeOf(T);
    const s: [n]T = @bitCast(a);
    const c: [n]T = @bitCast(b);
    var r: [n]T = undefined;
    for (0..n / 2) |k| {
        r[k] = pair(T, s[2 * k], s[2 * k + 1], how);
        r[n / 2 + k] = pair(T, c[2 * k], c[2 * k + 1], how);
    }
    return @bitCast(r);
}

fn pair(comptime T: type, p: T, q: T, how: Hop) T {
    return switch (how) {
        .add => p +% q,
        .sub => p -% q,
        .adds => p +| q,
        .subs => p -| q,
    };
}

/// PSIGNB, W, and D: a negated where b is negative, zero where it's zero.
fn psign(comptime W: type, comptime T: type, a: W, b: W) W {
    const n = @bitSizeOf(W) / @bitSizeOf(T);
    const s: [n]T = @bitCast(a);
    const c: [n]T = @bitCast(b);
    var r: [n]T = undefined;
    for (0..n) |k| r[k] = if (c[k] < 0) 0 -% s[k] else if (c[k] == 0) 0 else s[k];
    return @bitCast(r);
}

/// CRC32 (F2 0F 38 F0 and F1): CRC-32C, accumulated in the destination,
/// over a byte (F0), or a word, doubleword, or quadword (F1, by 66 and
/// REX.W). The destination is 32 bits, or 64 with REX.W, zero-extended.
fn crc32(x: anytype, op: u8) !void {
    const i = x.i;
    const w = i.rex.w == 1;
    const size: u8 = if (op == 0xf0) 1 else if (w) 8 else if (i.opsize) 2 else 4;
    const v: u64 = if (i.mem) try x.load(x.addr, size) else x.readReg(i.rm(), size);
    var c: u32 = @truncate(x.readReg(i.reg(), 4));
    for (0..size) |k| c = crcByte(c, @truncate(v >> @intCast(8 * k)));
    x.writeReg(i.reg(), 8, c);
}

fn crcByte(c0: u32, b: u8) u32 {
    var c = c0 ^ b;
    for (0..8) |_| c = (c >> 1) ^ (0x82f6_3b78 & (0 -% (c & 1)));
    return c;
}

// ------------------------------------------------------------ 0F 3A

/// 0F 3A xx: SSSE3's PALIGNR (0F), SSE4.1's rounds, blends, inserts,
/// extracts, dot products, and MPSADBW, and SSE4.2's string compares
/// (60-63). Every one has an imm8.
pub fn map3a(x: anytype) !void {
    const i = x.i;
    const p = sse.prefix(x);
    const op = i.op3;
    const imm: u8 = @truncate(i.imm);
    if (op == 0x0f) switch (p) {
        .none => {
            try sse.mmx(x);
            const a = sse.getMM(x, sse.mmReg(i));
            const b = try sse.msrc(x);
            return sse.setMM(x, sse.mmReg(i), @truncate(palignr(u64, a, b, imm)));
        },
        .p66 => {
            const b = try xsrc(x, 16, true);
            xreg(x).* = palignr(u128, xreg(x).*, b, imm);
            return;
        },
        else => return ud(x),
    };
    if (p != .p66) return ud(x);
    const d = xreg(x);
    switch (op) {
        0x08 => return round(x, u32, 4, imm),
        0x09 => return round(x, u64, 2, imm),
        0x0a => return round(x, u32, 1, imm),
        0x0b => return round(x, u64, 1, imm),
        0x0c, 0x0d, 0x0e => {
            // BLENDPS, BLENDPD, and PBLENDW: by imm8's bits.
            const b = try xsrc(x, 16, true);
            const sel: u128 = switch (op) {
                0x0c => immLanes(u32, imm),
                0x0d => immLanes(u64, imm),
                else => immLanes(u16, imm),
            };
            d.* = (d.* & ~sel) | (b & sel);
        },
        0x14, 0x15, 0x16, 0x17 => {
            // PEXTRB, PEXTRW, PEXTRD and PEXTRQ, and EXTRACTPS: to a
            // general register, zero-extended, or memory.
            const size: u8 = switch (op) {
                0x14 => 1,
                0x15 => 2,
                0x16 => if (i.rex.w == 1) 8 else 4,
                else => 4,
            };
            const k: u7 = @intCast((imm & (16 / size - 1)) * size);
            const v: u64 = @truncate(d.* >> (k * 8));
            if (i.mem) return x.store(x.addr, size, v);
            x.writeReg(i.rm(), 8, if (size == 8) v else v & ((@as(u64, 1) << @intCast(8 * size)) - 1));
        },
        0x20, 0x22 => {
            // PINSRB, and PINSRD and PINSRQ.
            const size: u8 = if (op == 0x20) 1 else if (i.rex.w == 1) 8 else 4;
            const v: u64 = if (i.mem) try x.load(x.addr, size) else x.readReg(i.rm(), if (size == 1) 4 else size);
            const k: u7 = @intCast((imm & (16 / size - 1)) * size);
            const m: u128 = ((@as(u128, 1) << @intCast(8 * size)) - 1) << k * 8;
            d.* = (d.* & ~m) | ((@as(u128, v) << k * 8) & m);
        },
        0x21 => {
            // INSERTPS: a dword from a register's lane (imm8 7:6) or
            // memory into lane 5:4, then zeros where 3:0 say.
            const s: u32 = if (i.mem)
                @truncate(try x.load(x.addr, 4))
            else
                @truncate(x.c.xmm[i.rm()] >> @as(u7, 32) * @as(u2, @truncate(imm >> 6)));
            var r: [4]u32 = @bitCast(d.*);
            r[(imm >> 4) & 3] = s;
            for (0..4) |k| {
                if (imm & (@as(u8, 1) << @intCast(k)) != 0) r[k] = 0;
            }
            d.* = @bitCast(r);
        },
        0x40 => return dpps(x, imm),
        0x41 => return dppd(x, imm),
        0x42 => {
            // MPSADBW: eight sums of absolute differences of four bytes,
            // from a at offset 4 * imm8[2] (sliding) and b at 4 * imm8[1:0].
            const b: [16]u8 = @bitCast(try xsrc(x, 16, true));
            const a: [16]u8 = @bitCast(d.*);
            const ao: usize = 4 * @as(usize, (imm >> 2) & 1);
            const bo: usize = 4 * @as(usize, imm & 3);
            var r: [8]u16 = undefined;
            for (0..8) |j| {
                var sum: u16 = 0;
                for (0..4) |k| {
                    const u = a[ao + j + k];
                    const v = b[bo + k];
                    sum += if (u > v) u - v else v - u;
                }
                r[j] = sum;
            }
            d.* = @bitCast(r);
        },
        0x60, 0x61, 0x62, 0x63 => return pcmpstr(x, op, imm),
        else => return ud(x),
    }
}

/// a:b shifted right by n bytes, the low half kept.
fn palignr(comptime W: type, a: W, b: W, n: u8) W {
    const D = @Int(.unsigned, 2 * @bitSizeOf(W));
    const both = @as(D, a) << @bitSizeOf(W) | b;
    if (n >= 2 * @sizeOf(W)) return 0;
    return @truncate(both >> @intCast(8 * @as(u16, n)));
}

/// All ones in each T lane whose bit is set in imm.
fn immLanes(comptime T: type, imm: u8) u128 {
    const n = 128 / @bitSizeOf(T);
    var r: [n]T = undefined;
    for (0..n) |k| r[k] = if (imm >> @intCast(k) & 1 != 0) std.math.maxInt(T) else 0;
    return @bitCast(r);
}

/// ROUNDPS, ROUNDPD, ROUNDSS, and ROUNDSD: imm8[1:0] is the rounding,
/// or MXCSR's when imm8[2] is set, and imm8[3] keeps PE from being
/// raised. Only an SNaN raises IE; a denormal raises nothing (DAZ still
/// reads it as zero).
fn round(x: anytype, comptime T: type, comptime n: usize, imm: u8) !void {
    const k = 16 / @sizeOf(T);
    const b = try xsrc(x, if (n == 1) @sizeOf(T) else 16, true);
    var a: [k]T = @bitCast(xreg(x).*);
    const bs: [k]T = @bitCast(b);
    var e = sse.env(x);
    const rc: u2 = if (imm & 4 != 0) @truncate(x.c.mxcsr >> 13) else @truncate(imm);
    const rnd = fp.Rounding.fromX86(rc);
    for (0..n) |j| {
        var le = e;
        le.flags = 0;
        a[j] = fp.roundToInt(T, &le, bs[j], rnd, imm & 8 == 0);
        e.flags |= le.flags & ~fp.DE;
    }
    try sse.raise(x, &e);
    xreg(x).* = @bitCast(a);
}

/// DPPS: the products of the lanes imm8[7:4] picks (+0 for the rest),
/// summed in pairs and then together, each step rounded, into the lanes
/// imm8[3:0] picks (+0 in the rest).
///
/// The SDM sums once and copies the sum, but Intel's CPUs sum for each
/// lane with the operands in another order, which shows when two of them
/// are NaNs, as x86 keeps the first: lane j adds product j^1 to product
/// j, then pair j^2 to that. The sums are otherwise the same, and so are
/// the flags they raise. An unmasked exception in the products raises
/// #XM before the sums.
fn dpps(x: anytype, imm: u8) !void {
    const a: [4]u32 = @bitCast(xreg(x).*);
    const b: [4]u32 = @bitCast(try xsrc(x, 16, true));
    var e = sse.env(x);
    var p: [4]u32 = undefined;
    for (0..4) |k| p[k] = if (imm >> @intCast(4 + k) & 1 != 0) fpOp(x, u32, &e, 0x59, a[k], b[k]) else 0;
    // An unmasked exception in the products stops it there.
    try sse.raise(x, &e);
    e.flags = 0;
    var t: [4]u32 = undefined;
    for (0..4) |k| t[k] = fpOp(x, u32, &e, 0x58, p[k ^ 1], p[k]);
    var r: [4]u32 = undefined;
    for (0..4) |k| {
        const s = fpOp(x, u32, &e, 0x58, t[k], t[k ^ 2]);
        r[k] = if (imm >> @intCast(k) & 1 != 0) s else 0;
    }
    try sse.raise(x, &e);
    xreg(x).* = @bitCast(r);
}

/// DPPD: DPPS's two-lane form, with imm8[5:4] and imm8[1:0]. Lane j adds
/// product j^1 to product j, as on Intel's CPUs (see `dpps`).
fn dppd(x: anytype, imm: u8) !void {
    const a: [2]u64 = @bitCast(xreg(x).*);
    const b: [2]u64 = @bitCast(try xsrc(x, 16, true));
    var e = sse.env(x);
    var p: [2]u64 = undefined;
    for (0..2) |k| p[k] = if (imm >> @intCast(4 + k) & 1 != 0) fpOp(x, u64, &e, 0x59, a[k], b[k]) else 0;
    try sse.raise(x, &e);
    e.flags = 0;
    const s0 = fpOp(x, u64, &e, 0x58, p[0], p[1]);
    const s1 = fpOp(x, u64, &e, 0x58, p[1], p[0]);
    try sse.raise(x, &e);
    xreg(x).* = join(if (imm & 1 != 0) s0 else 0, if (imm & 2 != 0) s1 else 0);
}

/// PCMPESTRI (61), PCMPESTRM (60), PCMPISTRI (63), and PCMPISTRM (62).
/// imm8[1:0] is the elements (unsigned bytes, unsigned words, signed
/// bytes, signed words), [3:2] the aggregation (equal any, ranges, equal
/// each, equal ordered), [5:4] the polarity, and [6] the index's end or
/// the mask's form. The explicit forms' lengths are |RAX| and |RDX| (EAX
/// and EDX without REX.W), at most the element count; the implicit ones'
/// end at the first zero element. The first operand is the XMM register
/// (the set, ranges, or needle), the second the XMM register or memory
/// (the string searched), which needn't be aligned.
fn pcmpstr(x: anytype, op: u8, imm: u8) !void {
    const i = x.i;
    const b = try xsrc(x, 16, false);
    const a = xreg(x).*;
    const words = imm & 1 != 0;
    const n: u5 = if (words) 8 else 16;
    const is_signed = imm & 2 != 0;
    const explicit = op == 0x60 or op == 0x61;
    const la: u5 = if (explicit) explicitLen(x, 0, n) else implicitLen(a, words);
    const lb: u5 = if (explicit) explicitLen(x, 2, n) else implicitLen(b, words);
    const S = struct {
        fn elem(v: u128, k: usize, w: bool, sg: bool) i32 {
            if (w) {
                const h: u16 = @truncate(v >> @intCast(16 * k));
                return if (sg) @as(i16, @bitCast(h)) else h;
            }
            const y: u8 = @truncate(v >> @intCast(8 * k));
            return if (sg) @as(i8, @bitCast(y)) else y;
        }
    };
    var res1: u16 = 0;
    for (0..n) |j| {
        // j indexes b, the string searched; k indexes a.
        const bj = S.elem(b, j, words, is_signed);
        const vb = j < lb;
        const hit = switch ((imm >> 2) & 3) {
            // Equal any.
            0 => blk: {
                if (!vb) break :blk false;
                for (0..la) |k| {
                    if (S.elem(a, k, words, is_signed) == bj) break :blk true;
                }
                break :blk false;
            },
            // Ranges: a holds [lo, hi] pairs.
            1 => blk: {
                if (!vb) break :blk false;
                var k: usize = 0;
                while (k + 1 < la) : (k += 2) {
                    if (S.elem(a, k, words, is_signed) <= bj and bj <= S.elem(a, k + 1, words, is_signed)) break :blk true;
                }
                break :blk false;
            },
            // Equal each: two invalid elements match.
            2 => blk: {
                const va = j < la;
                if (va and vb) break :blk S.elem(a, j, words, is_signed) == bj;
                break :blk !va and !vb;
            },
            // Equal ordered: a, as far as it's valid, starts at j.
            else => blk: {
                var k: usize = 0;
                while (k < n - j) : (k += 1) {
                    if (k >= la) break;
                    if (j + k >= lb) break :blk false;
                    if (S.elem(a, k, words, is_signed) != S.elem(b, j + k, words, is_signed)) break :blk false;
                }
                break :blk true;
            },
        };
        if (hit) res1 |= @as(u16, 1) << @intCast(j);
    }
    const all: u16 = if (words) 0xff else 0xffff;
    const valid_b: u16 = @truncate((@as(u32, 1) << lb) - 1);
    const res2: u16 = switch ((imm >> 4) & 3) {
        0, 2 => res1,
        1 => ~res1 & all,
        else => (res1 ^ valid_b) & all,
    };
    var f: u32 = 0;
    if (res2 != 0) f |= flags.CF;
    if (lb < n) f |= flags.ZF;
    if (la < n) f |= flags.SF;
    if (res2 & 1 != 0) f |= flags.OF;
    if (op == 0x61 or op == 0x63) {
        // The index, into ECX (zero-extended).
        const idx: u32 = if (res2 == 0) n else if (imm & 0x40 != 0) 15 - @as(u32, @clz(res2)) else @ctz(res2);
        x.writeReg(1, 8, idx);
    } else {
        // The mask, into XMM0.
        x.c.xmm[0] = if (imm & 0x40 == 0) res2 else if (words) immLanes(u16, @truncate(res2)) else blk: {
            var r: [16]u8 = undefined;
            for (0..16) |k| r[k] = if (res2 >> @intCast(k) & 1 != 0) 0xff else 0;
            break :blk @bitCast(r);
        };
    }
    _ = i;
    x.c.fl.setMasked(flags.arith, f);
}

/// An explicit length from register `r` (RAX or RDX; EAX or EDX without
/// REX.W): its absolute value, at most `n`.
fn explicitLen(x: anytype, r: u4, n: u5) u5 {
    const v: i64 = if (x.i.rex.w == 1) @bitCast(x.readReg(r, 8)) else @as(i32, @bitCast(@as(u32, @truncate(x.readReg(r, 4)))));
    const m = @abs(v);
    return if (m >= n) n else @intCast(m);
}

/// An implicit length: the index of the first zero element, or the count.
fn implicitLen(v: u128, words: bool) u5 {
    if (words) {
        const w: [8]u16 = @bitCast(v);
        for (w, 0..) |e, k| if (e == 0) return @intCast(k);
        return 8;
    }
    const y: [16]u8 = @bitCast(v);
    for (y, 0..) |e, k| if (e == 0) return @intCast(k);
    return 16;
}

// ------------------------------------------------------------ tests

const testing = std.testing;

test "CRC-32C" {
    // The check value for "123456789", with the conventional pre- and
    // post-inversion around CRC32's accumulation.
    var c: u32 = 0xffff_ffff;
    for ("123456789") |b| c = crcByte(c, b);
    try testing.expectEqual(@as(u32, 0xe306_9283), ~c);
}

test "PSHUFB, PALIGNR, and PHMINPOSUW" {
    const a: u128 = 0x0f0e0d0c_0b0a0908_07060504_03020100;
    // Reverse, and zero where the control's top bit is set.
    const ctl: u128 = 0x00010203_04050607_08090a0b_0c0d0e80;
    try testing.expectEqual(@as(u128, 0x0f0e0d0c_0b0a0908_07060504_03020100 & 0) | 0x00010203_04050607_08090a0b_0c0d0e00, ssse3Op(u128, 0x00, a, ctl));
    try testing.expectEqual(@as(u64, 0x0201000706050403), @as(u64, @truncate(palignr(u64, 0x0706050403020100, 0x0706050403020100, 3))));
    try testing.expectEqual(@as(u128, 0), palignr(u128, a, a, 32));
    const w = [8]u16{ 9, 7, 3, 8, 3, 5, 6, 7 };
    try testing.expectEqual(@as(u128, 3 | 2 << 16), sse41(0x41, 0, @bitCast(w)).?);
}

test "PCMPISTRI finds a substring" {
    const c = try std.testing.allocator.create(cpu.Cpu64);
    defer std.testing.allocator.destroy(c);
    c.* = .{};
    var buf: [16]u8 = @splat(0);
    @memcpy(buf[0..3], "lo ");
    c.xmm[1] = std.mem.readInt(u128, &buf, .little);
    @memset(&buf, 0);
    @memcpy(buf[0..11], "hello world");
    c.xmm[2] = std.mem.readInt(u128, &buf, .little);
    const decode = @import("decode.zig");
    // pcmpistri $0x0c, %xmm2, %xmm1: equal ordered, unsigned bytes.
    const i = try decode.decodeIn(.long, &.{ 0x66, 0x0f, 0x3a, 0x63, 0xca, 0x0c });
    try testing.expectEqual(@as(u8, 0x63), i.op3);
    try testing.expectEqual(@as(u8, 6), i.len);
    var m: [4096]u8 = undefined;
    try testing.expectEqual(@as(?u8, null), sse.TestX64.run(c, &m, 0x10000, i));
    try testing.expectEqual(@as(u64, 3), c.r[1]);
    try testing.expect(c.fl.get() & flags.CF != 0);
}
