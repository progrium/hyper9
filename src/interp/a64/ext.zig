//! ha64's Armv8.0 optional extensions on T0: CRC32 (FEAT_CRC32), and the
//! cryptographic ones, AES with PMULL (FEAT_AES and FEAT_PMULL), SHA1, and
//! SHA256 (FEAT_SHA1 and FEAT_SHA256). Linux programs use them only when
//! AT_HWCAP says so, and h9 says so on the emulator (vmm.Backend.hwcaps),
//! since both tiers run them.
//!
//! decode.zig hands CRC32's encodings here (`decodeDp2`), and
//! simd_decode.zig the crypto ones (`decodeCrypto`). Kinds from
//! `dec.ext_base` up are this file's: exec.zig dispatches them to
//! `handlers`, and decode.zig's `info` and `regs` ask `info` and `regs`
//! here. T1 runs them through call.interp.

const std = @import("std");
const dec = @import("decode.zig");
const exec = @import("exec.zig");

const Op = dec.Op;
const Machine = exec.Machine;
const Next = exec.Next;

pub const Kind = enum(u16) {
    /// CRC32B, H, W, and X, and CRC32CB, CH, CW, and CX: d = the CRC of
    /// the low 1, 2, 4, or 8 bytes of m, from the accumulator n (W
    /// registers but for X's m). x is log2 of the size.
    crc32,
    crc32c,
    // The crypto kinds: d, n, and m are V registers.
    /// AESE and AESD Vd.16B, Vn.16B: a round's AddRoundKey (d ^ n), then
    /// ShiftRows and SubBytes, or their inverses.
    aese,
    aesd,
    /// AESMC and AESIMC Vd.16B, Vn.16B: MixColumns and its inverse.
    aesmc,
    aesimc,
    /// SHA1C, SHA1P, and SHA1M Qd, Sn, Vm.4S: four rounds of SHA-1 with
    /// the choose, parity, and majority functions.
    sha1c,
    sha1p,
    sha1m,
    /// SHA1SU0 Vd.4S, Vn.4S, Vm.4S and SHA1SU1 Vd.4S, Vn.4S: the schedule.
    sha1su0,
    sha1su1,
    /// SHA1H Sd, Sn: ROL(n, 30).
    sha1h,
    /// SHA256H Qd, Qn, Vm.4S and SHA256H2 Qd, Qn, Vm.4S: four rounds of
    /// SHA-256, the two halves of the state.
    sha256h,
    sha256h2,
    /// SHA256SU0 Vd.4S, Vn.4S and SHA256SU1 Vd.4S, Vn.4S, Vm.4S.
    sha256su0,
    sha256su1,
    /// PMULL and PMULL2 Vd.1Q, Vn.1D, Vm.1D: the 64 by 64 bit carryless
    /// product, of the low halves, or (sh 1, PMULL2) the high ones.
    pmull_q,
};

pub fn kind(k: Kind) dec.Kind {
    return @enumFromInt(dec.ext_base + @intFromEnum(k));
}

pub fn of(k: dec.Kind) ?Kind {
    const v = @intFromEnum(k);
    if (v < dec.ext_base) return null;
    return std.enums.fromInt(Kind, v - dec.ext_base);
}

inline fn bits(w: u32, comptime hi: u5, comptime lo: u5) u32 {
    return (w >> lo) & ((@as(u32, 1) << (hi - lo + 1)) - 1);
}

/// Data processing (2 source) opcodes 010xxx: CRC32 and CRC32C. Null for
/// anything else, which stays unallocated.
pub fn decodeDp2(w: u32) ?Op {
    const opcode = bits(w, 15, 10);
    if (opcode >> 3 != 0b010) return null;
    const sf = bits(w, 31, 31) == 1;
    const sz: u8 = @intCast(opcode & 3);
    // Only the X form takes sf.
    if (sf != (sz == 3)) return null;
    const rd = bits(w, 4, 0);
    return .{
        .k = kind(if (opcode & 4 != 0) .crc32c else .crc32),
        .d = if (rd == 31) dec.SINK else @intCast(rd),
        .n = @intCast(bits(w, 9, 5)),
        .m = @intCast(bits(w, 20, 16)),
        .x = sz,
    };
}

/// The crypto encodings: AES, SHA1, SHA256, and PMULL's 1Q form. Null
/// for anything else, which simd_decode.zig decodes.
pub fn decodeCrypto(w: u32) ?Op {
    const k: Kind = if (w & 0xffff_cc00 == 0x4e28_4800) switch (bits(w, 13, 12)) {
        0 => .aese,
        1 => .aesd,
        2 => .aesmc,
        else => .aesimc,
    } else if (w & 0xffe0_8c00 == 0x5e00_0000) switch (bits(w, 14, 12)) {
        0 => .sha1c,
        1 => .sha1p,
        2 => .sha1m,
        3 => .sha1su0,
        4 => .sha256h,
        5 => .sha256h2,
        6 => .sha256su1,
        else => return null,
    } else if (w & 0xffff_cc00 == 0x5e28_0800) switch (bits(w, 13, 12)) {
        0 => .sha1h,
        1 => .sha1su1,
        2 => .sha256su0,
        else => return null,
    } else if (w & 0xbfe0_fc00 == 0x0ee0_e000) .pmull_q else return null;
    return .{
        .k = kind(k),
        .d = @intCast(bits(w, 4, 0)),
        .n = @intCast(bits(w, 9, 5)),
        .m = @intCast(bits(w, 20, 16)),
        .sh = @intCast(bits(w, 30, 30)),
    };
}

pub fn info(k: dec.Kind) dec.Info {
    return switch (of(k) orelse return .{ .ctrl = .undef }) {
        .crc32, .crc32c => .{ .d = .w, .n = .r, .m = .r },
        .aesmc, .aesimc, .sha1h => .{ .d = .w, .n = .r, .vreg = true },
        .aese, .aesd, .sha1su1, .sha256su0 => .{ .d = .rw, .n = .r, .vreg = true },
        .pmull_q => .{ .d = .w, .n = .r, .m = .r, .vreg = true },
        .sha1c, .sha1p, .sha1m, .sha1su0, .sha256h, .sha256h2, .sha256su1 => .{ .d = .rw, .n = .r, .m = .r, .vreg = true },
    };
}

/// The registers `o` reads and writes: general ones for CRC32, V ones
/// for the rest.
pub fn regs(o: Op) dec.Regs {
    const i = info(o.k);
    var r: dec.Regs = .{ .ctrl = i.ctrl };
    const Use = @TypeOf(i.d);
    const slots = [_]struct { u: Use, s: u8 }{ .{ .u = i.d, .s = o.d }, .{ .u = i.n, .s = o.n }, .{ .u = i.m, .s = o.m } };
    for (slots) |e| {
        const rd = e.u == .r or e.u == .rw;
        const wr = e.u == .w or e.u == .rw;
        if (i.vreg) {
            const b = @as(u32, 1) << @intCast(e.s & 31);
            if (rd) r.vread |= b;
            if (wr) r.vwrite |= b;
        } else if (e.s != dec.ZR and e.s != dec.SINK) {
            const b = @as(u64, 1) << @intCast(e.s);
            if (rd) r.read |= b;
            if (wr) r.write |= b;
        }
    }
    return r;
}

// ---------------------------------------------------------------- CRC32

/// The reflected polynomials: CRC-32 (ISO-HDLC) and CRC-32C (Castagnoli).
const poly_crc32: u32 = 0xedb8_8320;
const poly_crc32c: u32 = 0x82f6_3b78;

fn crcTable(comptime poly: u32) [256]u32 {
    @setEvalBranchQuota(10000);
    var t: [256]u32 = undefined;
    for (&t, 0..) |*e, i| {
        var c: u32 = @intCast(i);
        for (0..8) |_| c = if (c & 1 != 0) (c >> 1) ^ poly else c >> 1;
        e.* = c;
    }
    return t;
}

const table_crc32 = crcTable(poly_crc32);
const table_crc32c = crcTable(poly_crc32c);

/// The architecture's CRC32 step: no inversion on the way in or out,
/// bytes least significant first.
pub fn crc(comptime c: bool, acc: u32, data: u64, size: u4) u32 {
    const t = if (c) &table_crc32c else &table_crc32;
    var v = acc;
    var d = data;
    for (0..size) |_| {
        v = (v >> 8) ^ t[@as(u8, @truncate(v ^ @as(u32, @truncate(d))))];
        d >>= 8;
    }
    return v;
}

// ---------------------------------------------------------------- AES

const sbox: [256]u8 = blk: {
    @setEvalBranchQuota(1_000_000);
    var t: [256]u8 = undefined;
    // The inverse in GF(2^8), a^254 (0 for 0), then the affine map.
    for (0..256) |i| {
        var inv: u8 = 1;
        for (0..254) |_| inv = gmul(inv, @intCast(i));
        var x = inv;
        var y = inv;
        for (0..4) |_| {
            y = std.math.rotl(u8, y, 1);
            x ^= y;
        }
        t[i] = x ^ 0x63;
    }
    break :blk t;
};

const inv_sbox: [256]u8 = blk: {
    var t: [256]u8 = undefined;
    for (sbox, 0..) |v, i| t[v] = @intCast(i);
    break :blk t;
};

fn gmul(a: u8, b: u8) u8 {
    var x = a;
    var y = b;
    var p: u8 = 0;
    while (y != 0) : (y >>= 1) {
        if (y & 1 != 0) p ^= x;
        x = (x << 1) ^ (if (x & 0x80 != 0) @as(u8, 0x1b) else 0);
    }
    return p;
}

/// The state's bytes, column by column, as AES and the register have them.
fn bytesOf(v: u128) [16]u8 {
    return @bitCast(std.mem.nativeToLittle(u128, v));
}

fn valueOf(b: [16]u8) u128 {
    return std.mem.littleToNative(u128, @bitCast(b));
}

pub fn aesRound(comptime decrypt: bool, state: u128, key: u128) u128 {
    const in = bytesOf(state ^ key);
    var out: [16]u8 = undefined;
    for (0..4) |c| for (0..4) |r| {
        const from = r + 4 * ((c + r) % 4);
        const to = r + 4 * c;
        if (decrypt) out[from] = inv_sbox[in[to]] else out[to] = sbox[in[from]];
    };
    return valueOf(out);
}

pub fn aesMix(comptime inverse: bool, state: u128) u128 {
    const in = bytesOf(state);
    var out: [16]u8 = undefined;
    const m: [4]u8 = if (inverse) .{ 14, 11, 13, 9 } else .{ 2, 3, 1, 1 };
    for (0..4) |c| for (0..4) |r| {
        var x: u8 = 0;
        for (0..4) |j| x ^= gmul(m[(j + 4 - r) % 4], in[4 * c + j]);
        out[4 * c + r] = x;
    };
    return valueOf(out);
}

// ---------------------------------------------------------------- SHA

inline fn lane(v: u128, i: usize) u32 {
    return @truncate(v >> @intCast(32 * i));
}

fn lanes(l: [4]u32) u128 {
    var v: u128 = 0;
    for (l, 0..) |x, i| v |= @as(u128, x) << @intCast(32 * i);
    return v;
}

const rol = std.math.rotl;
const ror = std.math.rotr;

pub fn sha1Rounds(comptime f: enum { choose, parity, majority }, x0: u128, y0: u32, w: u128) u128 {
    var x = x0;
    var y = y0;
    for (0..4) |e| {
        const b = lane(x, 1);
        const c = lane(x, 2);
        const d = lane(x, 3);
        const t = switch (f) {
            .choose => ((c ^ d) & b) ^ d,
            .parity => b ^ c ^ d,
            .majority => (b & c) | ((b | c) & d),
        };
        y = y +% rol(u32, lane(x, 0), 5) +% t +% lane(w, e);
        x = (x & ~(@as(u128, 0xffff_ffff) << 32)) | @as(u128, rol(u32, b, 30)) << 32;
        // ROL(Y:X, 32), 160 bits.
        const top = lane(x, 3);
        x = x << 32 | y;
        y = top;
    }
    return x;
}

pub fn sha1su0(d: u128, n: u128, m: u128) u128 {
    return ((n << 64) | (d >> 64)) ^ d ^ m;
}

pub fn sha1su1(d: u128, n: u128) u128 {
    const t = d ^ (n >> 32);
    const w0 = rol(u32, lane(t, 0), 1);
    return lanes(.{ w0, rol(u32, lane(t, 1), 1), rol(u32, lane(t, 2), 1), rol(u32, lane(t, 3), 1) ^ rol(u32, w0, 1) });
}

pub fn sha256Rounds(comptime part1: bool, x0: u128, y0: u128, w: u128) u128 {
    var x = x0;
    var y = y0;
    for (0..4) |e| {
        const ch = ((lane(y, 1) ^ lane(y, 2)) & lane(y, 0)) ^ lane(y, 2);
        const a = lane(x, 0);
        const b = lane(x, 1);
        const c = lane(x, 2);
        const maj = (a & b) | ((a | b) & c);
        const s1 = ror(u32, lane(y, 0), 6) ^ ror(u32, lane(y, 0), 11) ^ ror(u32, lane(y, 0), 25);
        const s0 = ror(u32, a, 2) ^ ror(u32, a, 13) ^ ror(u32, a, 22);
        const t = lane(y, 3) +% s1 +% ch +% lane(w, e);
        const x3 = t +% lane(x, 3);
        const y3 = t +% s0 +% maj;
        // ROL(Y:X, 32), 256 bits, with the new tops.
        const nx = x << 32 | y3;
        const ny = y << 32 | x3;
        x = nx;
        y = ny;
    }
    return if (part1) x else y;
}

pub fn sha256su0(d: u128, n: u128) u128 {
    const t = (n << 96) | (d >> 32);
    var r: [4]u32 = undefined;
    for (&r, 0..) |*o, e| {
        const v = lane(t, e);
        o.* = (ror(u32, v, 7) ^ ror(u32, v, 18) ^ (v >> 3)) +% lane(d, e);
    }
    return lanes(r);
}

pub fn sha256su1(d: u128, n: u128, m: u128) u128 {
    const t0 = (m << 96) | (n >> 32);
    var r: [4]u32 = undefined;
    for (0..4) |e| {
        const v = if (e < 2) lane(m, e + 2) else r[e - 2];
        r[e] = (ror(u32, v, 17) ^ ror(u32, v, 19) ^ (v >> 10)) +% lane(d, e) +% lane(t0, e);
    }
    return lanes(r);
}

// ---------------------------------------------------------------- PMULL

pub fn clmul64(a: u64, b: u64) u128 {
    var r: u128 = 0;
    for (0..64) |i| {
        if (b >> @intCast(i) & 1 != 0) r ^= @as(u128, a) << @intCast(i);
    }
    return r;
}

// ---------------------------------------------------------------- handlers

pub const handlers = blk: {
    const fields = @typeInfo(Kind).@"enum".fields;
    var h: [fields.len]exec.Handler = undefined;
    for (fields, 0..) |f, i| {
        std.debug.assert(f.value == i);
        h[i] = handlerFor(@enumFromInt(f.value));
    }
    break :blk h;
};

fn handlerFor(comptime k: Kind) exec.Handler {
    return &struct {
        fn f(m: *Machine, o: *const Op, pc: u64) Next {
            _ = pc;
            const r = &m.cpu.r;
            const v = &m.cpu.v;
            switch (k) {
                .crc32, .crc32c => {
                    const size = @as(u4, 1) << @intCast(o.x);
                    r[o.d] = crc(k == .crc32c, @truncate(r[o.n]), r[o.m], size);
                },
                .aese, .aesd => v[o.d] = aesRound(k == .aesd, v[o.d], v[o.n]),
                .aesmc, .aesimc => v[o.d] = aesMix(k == .aesimc, v[o.n]),
                .sha1c => v[o.d] = sha1Rounds(.choose, v[o.d], lane(v[o.n], 0), v[o.m]),
                .sha1p => v[o.d] = sha1Rounds(.parity, v[o.d], lane(v[o.n], 0), v[o.m]),
                .sha1m => v[o.d] = sha1Rounds(.majority, v[o.d], lane(v[o.n], 0), v[o.m]),
                .sha1su0 => v[o.d] = sha1su0(v[o.d], v[o.n], v[o.m]),
                .sha1su1 => v[o.d] = sha1su1(v[o.d], v[o.n]),
                .sha1h => v[o.d] = rol(u32, lane(v[o.n], 0), 30),
                .sha256h => v[o.d] = sha256Rounds(true, v[o.d], v[o.n], v[o.m]),
                .sha256h2 => v[o.d] = sha256Rounds(false, v[o.n], v[o.d], v[o.m]),
                .sha256su0 => v[o.d] = sha256su0(v[o.d], v[o.n]),
                .sha256su1 => v[o.d] = sha256su1(v[o.d], v[o.n], v[o.m]),
                .pmull_q => {
                    const sh: u7 = if (o.sh != 0) 64 else 0;
                    v[o.d] = clmul64(@truncate(v[o.n] >> sh), @truncate(v[o.m] >> sh));
                },
            }
            return .next;
        }
    }.f;
}

// ---------------------------------------------------------------- tests

test "CRC32 and CRC32C check values" {
    // The standard check: the CRC of "123456789", with the usual
    // inversion around the architecture's step.
    const s = "123456789";
    var a: u32 = 0xffff_ffff;
    var b: u32 = 0xffff_ffff;
    for (s) |ch| {
        a = crc(false, a, ch, 1);
        b = crc(true, b, ch, 1);
    }
    try std.testing.expectEqual(@as(u32, 0xcbf4_3926), ~a);
    try std.testing.expectEqual(@as(u32, 0xe306_9283), ~b);
    // Wider steps agree with bytewise ones.
    const x: u64 = 0x0807_0605_0403_0201;
    var bytewise: u32 = 0x1234_5678;
    for (0..8) |i| bytewise = crc(true, bytewise, x >> @intCast(8 * i), 1);
    try std.testing.expectEqual(bytewise, crc(true, 0x1234_5678, x, 8));
}

test "decode CRC32 forms" {
    // crc32b w0, w1, w2
    const o = decodeDp2(0x1ac24020).?;
    try std.testing.expectEqual(kind(.crc32), o.k);
    try std.testing.expectEqual(@as(u8, 0), o.x);
    // crc32cx w3, w4, x5
    const c = decodeDp2(0x9ac55c83).?;
    try std.testing.expectEqual(kind(.crc32c), c.k);
    try std.testing.expectEqual(@as(u8, 3), c.x);
    // crc32x with sf clear, and crc32w with sf set, are unallocated.
    try std.testing.expect(decodeDp2(0x1ac54c83) == null);
    try std.testing.expect(decodeDp2(0x9ac54883) == null);
}

fn expandKey(key: [16]u8) [11]u128 {
    var w: [44]u32 = undefined;
    for (0..4) |i| w[i] = std.mem.readInt(u32, key[4 * i ..][0..4], .little);
    var rcon: u8 = 1;
    for (4..44) |i| {
        var t = w[i - 1];
        if (i % 4 == 0) {
            t = ror(u32, t, 8);
            var b: [4]u8 = @bitCast(t);
            for (&b) |*x| x.* = sbox[x.*];
            t = @as(u32, @bitCast(b)) ^ rcon;
            rcon = gmul(rcon, 2);
        }
        w[i] = w[i - 4] ^ t;
    }
    var rk: [11]u128 = undefined;
    for (&rk, 0..) |*k, i| k.* = lanes(w[4 * i ..][0..4].*);
    return rk;
}

test "AESE, AESMC, AESD, and AESIMC: FIPS-197's example" {
    const key = [16]u8{ 0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6, 0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c };
    const plain = [16]u8{ 0x32, 0x43, 0xf6, 0xa8, 0x88, 0x5a, 0x30, 0x8d, 0x31, 0x31, 0x98, 0xa2, 0xe0, 0x37, 0x07, 0x34 };
    const cipher = [16]u8{ 0x39, 0x25, 0x84, 0x1d, 0x02, 0xdc, 0x09, 0xfb, 0xdc, 0x11, 0x85, 0x97, 0x19, 0x6a, 0x0b, 0x32 };
    const rk = expandKey(key);
    var s = valueOf(plain);
    for (0..9) |i| s = aesMix(false, aesRound(false, s, rk[i]));
    s = aesRound(false, s, rk[9]) ^ rk[10];
    try std.testing.expectEqual(valueOf(cipher), s);
    s = aesRound(true, s, rk[10]);
    var i: usize = 9;
    while (i > 0) : (i -= 1) s = aesRound(true, aesMix(true, s ^ rk[i]), 0);
    try std.testing.expectEqual(valueOf(plain), s ^ rk[0]);
}

fn add4(a: u128, b: u128) u128 {
    var r: [4]u32 = undefined;
    for (&r, 0..) |*x, i| x.* = lane(a, i) +% lane(b, i);
    return lanes(r);
}

/// "abc", padded: one block's 16 big-endian words, four to a vector.
fn abcBlock() [4]u128 {
    var words: [16]u32 = @splat(0);
    words[0] = 0x6162_6380;
    words[15] = 24;
    var v: [4]u128 = undefined;
    for (&v, 0..) |*x, i| x.* = lanes(words[4 * i ..][0..4].*);
    return v;
}

test "SHA1C, SHA1P, SHA1M, SHA1H, SHA1SU0, and SHA1SU1: SHA-1 of \"abc\"" {
    const h0 = [5]u32{ 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0 };
    const ks = [4]u32{ 0x5a827999, 0x6ed9eba1, 0x8f1bbcdc, 0xca62c1d6 };
    var w: [20]u128 = undefined;
    @memcpy(w[0..4], &abcBlock());
    for (0..16) |j| w[j + 4] = sha1su1(sha1su0(w[j], w[j + 1], w[j + 2]), w[j + 3]);
    var abcd = lanes(h0[0..4].*);
    var e = h0[4];
    for (0..20) |j| {
        const k = ks[j / 5];
        const tmp = add4(w[j], lanes(.{ k, k, k, k }));
        const e1 = rol(u32, lane(abcd, 0), 30);
        abcd = switch (j / 5) {
            0 => sha1Rounds(.choose, abcd, e, tmp),
            2 => sha1Rounds(.majority, abcd, e, tmp),
            else => sha1Rounds(.parity, abcd, e, tmp),
        };
        e = e1;
    }
    abcd = add4(abcd, lanes(h0[0..4].*));
    e +%= h0[4];
    try std.testing.expectEqual(lanes(.{ 0xa9993e36, 0x4706816a, 0xba3e2571, 0x7850c26c }), abcd);
    try std.testing.expectEqual(@as(u32, 0x9cd0d89d), e);
}

test "SHA256H, SHA256H2, SHA256SU0, and SHA256SU1: SHA-256 of \"abc\"" {
    const k = [64]u32{
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    };
    const h0 = lanes(.{ 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a });
    const h1 = lanes(.{ 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 });
    var w: [16]u128 = undefined;
    @memcpy(w[0..4], &abcBlock());
    for (0..12) |j| w[j + 4] = sha256su1(sha256su0(w[j], w[j + 1]), w[j + 2], w[j + 3]);
    var abcd = h0;
    var efgh = h1;
    for (0..16) |j| {
        const tmp = add4(w[j], lanes(k[4 * j ..][0..4].*));
        const prev = abcd;
        abcd = sha256Rounds(true, abcd, efgh, tmp);
        efgh = sha256Rounds(false, prev, efgh, tmp);
    }
    try std.testing.expectEqual(lanes(.{ 0xba7816bf, 0x8f01cfea, 0x414140de, 0x5dae2223 }), add4(abcd, h0));
    try std.testing.expectEqual(lanes(.{ 0xb00361a3, 0x96177a9c, 0xb410ff61, 0xf20015ad }), add4(efgh, h1));
}

test "PMULL 1Q and the crypto decodes" {
    try std.testing.expectEqual(@as(u128, 0x189), clmul64(0x87, 3));
    try std.testing.expectEqual(@as(u128, 0x5555_5555_5555_5555_5555_5555_5555_5555), clmul64(~@as(u64, 0), ~@as(u64, 0)));
    // aese v0.16b, v1.16b; aesimc v2.16b, v3.16b
    try std.testing.expectEqual(kind(.aese), decodeCrypto(0x4e284820).?.k);
    try std.testing.expectEqual(kind(.aesimc), decodeCrypto(0x4e287862).?.k);
    // sha1c q0, s1, v2.4s; sha256su1 v0.4s, v1.4s, v2.4s; sha1h s0, s1
    try std.testing.expectEqual(kind(.sha1c), decodeCrypto(0x5e020020).?.k);
    try std.testing.expectEqual(kind(.sha256su1), decodeCrypto(0x5e026020).?.k);
    try std.testing.expectEqual(kind(.sha1h), decodeCrypto(0x5e280820).?.k);
    // pmull2 v0.1q, v1.2d, v2.2d
    const p = decodeCrypto(0x4ee2e020).?;
    try std.testing.expectEqual(kind(.pmull_q), p.k);
    try std.testing.expectEqual(@as(u8, 1), p.sh);
    // pmull v0.8h, v1.8b, v2.8b is simd_decode's.
    try std.testing.expect(decodeCrypto(0x0e22e020) == null);
}
