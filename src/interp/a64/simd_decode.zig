//! FP and AdvSIMD decoding for ha64: Armv8.0's scalar FP and AdvSIMD
//! data processing at EL0, and the SIMD structure loads and stores.
//!
//! decode.zig sends here every word in the "data processing, SIMD and FP"
//! groups, and the SIMD structure loads and stores (LD1 and the rest).
//! Kinds are numbered from decode.simd_base; exec.zig dispatches them to
//! simd_exec.zig's handlers. Loads and stores of single FP/SIMD registers
//! (LDR, STR, LDP, STP, and LDUR of B, H, S, D, and Q) are decode.zig's.
//! Later architecture versions' encodings (FP16 arithmetic, RDM, dot
//! product, the crypto extensions) decode to .undef.
//!
//! The contract with decode.zig:
//!   decode(w, pc) Op     an Op with k = .undef or a kind >= simd_base
//!   info(k) Info         for kinds >= simd_base
//!   regs(o) Regs         likewise
//!
//! Operand fields:
//!
//!   d, n, m, a  V registers (0-31), or general register slots where a
//!               kind's comment says so (decode.zig's slot numbering)
//!   x           log2 of the element size in bytes (0 B, 1 H, 2 S, 3 D):
//!               for narrowing kinds the narrow (destination) size, for
//!               widening ones the narrow (source) size; for FP, the
//!               format (1 half, 2 single, 3 double)
//!   sh          the shape: bit 0 is Q (128 bits, or the upper half for
//!               the "2" forms), bit 1 scalar (one element, the rest of
//!               the register zeroed)
//!   imm         a shift amount, an element index, an expanded immediate,
//!               or a sub-operation, by kind

const std = @import("std");
const d = @import("decode.zig");

pub const Q: u8 = 1;
pub const SCALAR: u8 = 2;

/// This file's kinds, as offsets from decode.simd_base.
pub const Kind = enum(u16) {
    // ---- three same, integer: d = n op m, elementwise (vector or scalar)
    shadd,
    uhadd,
    srhadd,
    urhadd,
    shsub,
    uhsub,
    sqadd,
    uqadd,
    sqsub,
    uqsub,
    cmgt,
    cmhi,
    cmge,
    cmhs,
    cmeq,
    cmtst,
    sshl,
    ushl,
    sqshl,
    uqshl,
    srshl,
    urshl,
    sqrshl,
    uqrshl,
    smax,
    umax,
    smin,
    umin,
    sabd,
    uabd,
    /// d += |n - m|
    saba,
    uaba,
    add,
    sub,
    /// d += n * m
    mla,
    mls,
    mul,
    pmul,
    sqdmulh,
    sqrdmulh,
    /// Pairwise over n:m.
    smaxp,
    umaxp,
    sminp,
    uminp,
    addp,
    /// Bitwise, on the whole register.
    and_v,
    bic_v,
    orr_v,
    orn_v,
    eor_v,
    bsl,
    bit,
    bif,

    // ---- three different: x is the narrow size, sh's Q the "2" form
    saddl,
    uaddl,
    /// n is wide.
    saddw,
    uaddw,
    ssubl,
    usubl,
    ssubw,
    usubw,
    /// Narrowing: wide n and m, the high halves into d.
    addhn,
    raddhn,
    subhn,
    rsubhn,
    sabal,
    uabal,
    sabdl,
    uabdl,
    smlal,
    umlal,
    smlsl,
    umlsl,
    smull,
    umull,
    sqdmlal,
    sqdmlsl,
    sqdmull,
    pmull,

    // ---- two-register miscellaneous: d = op n
    rev64,
    rev32,
    rev16,
    /// Pairwise add long: x the narrow size.
    saddlp,
    uaddlp,
    sadalp,
    uadalp,
    /// d = sat(d + n), n's other signedness.
    suqadd,
    usqadd,
    cls,
    clz,
    cnt,
    not,
    rbit,
    sqabs,
    sqneg,
    abs,
    neg,
    cmgt0,
    cmge0,
    cmeq0,
    cmle0,
    cmlt0,
    /// Narrowing: x the narrow size, n wide.
    xtn,
    sqxtn,
    uqxtn,
    sqxtun,
    /// Widening shift by the element size: x the narrow size.
    shll,

    // ---- across lanes: a scalar in d
    saddlv,
    uaddlv,
    smaxv,
    umaxv,
    sminv,
    uminv,
    addv,

    // ---- shift by immediate: imm is the shift
    sshr,
    ushr,
    ssra,
    usra,
    srshr,
    urshr,
    srsra,
    ursra,
    sri,
    shl,
    sli,
    sqshlu,
    sqshl_i,
    uqshl_i,
    /// Narrowing, x the narrow size.
    shrn,
    rshrn,
    sqshrn,
    uqshrn,
    sqrshrn,
    uqrshrn,
    sqshrun,
    sqrshrun,
    /// Widening, x the narrow size.
    sshll,
    ushll,

    // ---- by element: m's element imm is the second operand (x is the
    // size; for the long forms, the narrow size)
    mul_e,
    mla_e,
    mls_e,
    sqdmulh_e,
    sqrdmulh_e,
    smull_e,
    umull_e,
    smlal_e,
    umlal_e,
    smlsl_e,
    umlsl_e,
    sqdmull_e,
    sqdmlal_e,
    sqdmlsl_e,

    // ---- copy
    /// d = n's element imm, duplicated (one element, scalar).
    dup_e,
    /// d = general register n, duplicated.
    dup_g,
    /// General register d = n's element imm, sign-extended (a: 1 to X)
    /// or zero-extended.
    smov,
    umov,
    /// d's element imm = general register n.
    ins_g,
    /// d's element imm = n's element a.
    ins_e,

    // ---- modified immediate: imm is the 64-bit pattern
    movi,
    orr_vi,
    bic_vi,

    // ---- scalar FP: x is the format (1 H, 2 S, 3 D)
    f_mov,
    f_abs,
    f_neg,
    f_sqrt,
    /// FCVT: x the destination format, a the source's.
    f_cvt,
    /// FRINT*: imm is the rounding (softfloat.Rounding), or 7 for FPCR's;
    /// bit 3 raises inexact (FRINTX).
    f_rint,
    /// FCMP, FCMPE: imm bit 0 signals on a quiet NaN (E), bit 1 compares
    /// with zero.
    f_cmp,
    /// FCCMP, FCCMPE: a is the condition, imm bits 3:0 the NZCV when it
    /// fails, bit 4 E.
    f_ccmp,
    /// FMOV (immediate): imm is the value's bits.
    f_mov_i,
    f_mul,
    f_div,
    f_add,
    f_sub,
    f_max,
    f_min,
    f_maxnm,
    f_minnm,
    f_nmul,
    /// a is the condition.
    f_csel,
    /// d = a + n * m, and the negated forms; a is Ra.
    f_madd,
    f_msub,
    f_nmadd,
    f_nmsub,
    /// FCVT[NPMZA][SU] and the fixed-point FCVTZ[SU]: d is a general
    /// register; imm bits 2:0 the rounding (softfloat.Rounding), bits 15:8
    /// the fraction bits; sh 1 unsigned; a 1 for a 64-bit result.
    f_toint,
    /// SCVTF, UCVTF, integer and fixed-point: n is a general register;
    /// imm the fraction bits; sh 1 unsigned; a 1 for a 64-bit source.
    f_fromint,
    /// FMOV to a general register d: x 2 (W from S), 3 (X from D), or 4
    /// (X from V.D[1]).
    f_mov_tog,
    /// FMOV from general register n, with f_mov_tog's x.
    f_mov_fromg,

    // ---- permute, extract, and table lookup
    uzp1,
    uzp2,
    trn1,
    trn2,
    zip1,
    zip2,
    /// imm is the byte index.
    ext,
    /// a is the number of table registers less one.
    tbl,
    tbx,

    _,
};

pub fn kk(k: Kind) d.Kind {
    return @enumFromInt(d.simd_base + @intFromEnum(k));
}

pub fn ofKind(k: d.Kind) Kind {
    return @enumFromInt(@intFromEnum(k) - d.simd_base);
}

inline fn bits(w: u32, comptime hi: u5, comptime lo: u5) u32 {
    return (w >> lo) & ((@as(u32, 1) << (hi - lo + 1)) - 1);
}

inline fn bit(w: u32, comptime b: u5) u32 {
    return (w >> b) & 1;
}

fn op(k: Kind, w: u32, x: u32, sh: u32) d.Op {
    return .{ .k = kk(k), .d = @intCast(bits(w, 4, 0)), .n = @intCast(bits(w, 9, 5)), .m = @intCast(bits(w, 20, 16)), .x = @intCast(x), .sh = @intCast(sh) };
}

const none: d.Op = .{};

/// Decodes the instruction word `w` at `pc`.
pub fn decode(w: u32, pc: u64) d.Op {
    _ = pc;
    const hi = bits(w, 28, 24);
    if (bit(w, 31) == 0) {
        if (hi == 0b01110) return vec01110(w, false);
        if (hi == 0b01111) return vec01111(w, false);
        if (hi == 0b11110 and bits(w, 30, 30) == 1) return vec01110(w, true);
        if (hi == 0b11111 and bits(w, 30, 30) == 1) return vec01111(w, true);
    }
    if (bit(w, 30) == 0 and bit(w, 29) == 0) {
        if (hi == 0b11110) return fpScalar(w);
        if (hi == 0b11111 and bit(w, 31) == 0) return fp3(w);
    }
    return none;
}

/// The scalar FP format of a type field: 00 S, 01 D, 11 H.
fn ftype(t: u32) ?u32 {
    return switch (t) {
        0 => 2,
        1 => 3,
        3 => 1,
        else => null,
    };
}

fn fop(k: Kind, w: u32, x: u32) d.Op {
    var o = op(k, w, x, 0);
    o.a = 0;
    return o;
}

/// Bits 28:24 = 11110 with bits 30:29 = 00: the scalar FP groups.
fn fpScalar(w: u32) d.Op {
    const x = ftype(bits(w, 23, 22)) orelse return none;
    const sf = bit(w, 31);
    if (bit(w, 21) == 0) return fpFixed(w, x);
    if (bits(w, 15, 10) == 0) return fpInt(w, x);
    if (sf != 0) return none;
    // Beyond conversions, half precision is FP16's (Armv8.2).
    if (bits(w, 14, 10) == 0b10000) {
        const opc = bits(w, 20, 15);
        if (opc >> 2 == 0b0001) { // FCVT
            const to = ftype(opc & 3) orelse return none;
            if (to == x) return none;
            var o = fop(.f_cvt, w, to);
            o.a = @intCast(x);
            return o;
        }
        if (x == 1) return none;
        if (opc <= 3) return fop(switch (opc) {
            0 => .f_mov,
            1 => .f_abs,
            2 => .f_neg,
            else => .f_sqrt,
        }, w, x);
        if (opc >> 3 == 1) {
            const r: u64 = switch (opc & 7) {
                0 => 0, // N: near_even
                1 => 2, // P: up
                2 => 1, // M: down
                3 => 3, // Z
                4 => 4, // A: near_away
                6 => 7 | 8, // X: FPCR's, exact
                7 => 7, // I: FPCR's
                else => return none,
            };
            var o = fop(.f_rint, w, x);
            o.imm = r;
            return o;
        }
        return none;
    }
    if (x == 1) return none;
    if (bits(w, 13, 10) == 0b1000) {
        if (bits(w, 15, 14) != 0 or bits(w, 2, 0) != 0) return none;
        var o = fop(.f_cmp, w, x);
        o.imm = bit(w, 4) | bit(w, 3) << 1;
        o.d = 0;
        return o;
    }
    if (bits(w, 12, 10) == 0b100) {
        if (bits(w, 9, 5) != 0) return none;
        var o = fop(.f_mov_i, w, x);
        o.n = 0;
        o.m = 0;
        o.imm = vfpExpandImm(bits(w, 20, 13), x);
        return o;
    }
    switch (bits(w, 11, 10)) {
        0b01 => {
            var o = fop(.f_ccmp, w, x);
            o.a = @intCast(bits(w, 15, 12));
            o.imm = bits(w, 3, 0) | bit(w, 4) << 4;
            o.d = 0;
            return o;
        },
        0b10 => return fop(switch (bits(w, 15, 12)) {
            0 => .f_mul,
            1 => .f_div,
            2 => .f_add,
            3 => .f_sub,
            4 => .f_max,
            5 => .f_min,
            6 => .f_maxnm,
            7 => .f_minnm,
            8 => .f_nmul,
            else => return none,
        }, w, x),
        0b11 => {
            var o = fop(.f_csel, w, x);
            o.a = @intCast(bits(w, 15, 12));
            return o;
        },
        else => return none,
    }
}

/// VFPExpandImm: an 8-bit FMOV immediate as a value of format x.
pub fn vfpExpandImm(imm8: u32, x: u32) u64 {
    const a: u64 = imm8 >> 7;
    const b: u64 = imm8 >> 6 & 1;
    const cdefgh: u64 = imm8 & 0x3f;
    return switch (x) {
        1 => a << 15 | (b ^ 1) << 14 | (if (b == 1) @as(u64, 3) else 0) << 12 | cdefgh << 6,
        2 => a << 31 | (b ^ 1) << 30 | (if (b == 1) @as(u64, 0x1f) else 0) << 25 | cdefgh << 19,
        else => a << 63 | (b ^ 1) << 62 | (if (b == 1) @as(u64, 0xff) else 0) << 54 | cdefgh << 48,
    };
}

/// Register 31 as ZR, for a general-register write.
fn gw(r: u32) u8 {
    return if (r == 31) d.SINK else @intCast(r);
}

fn fpFixed(w: u32, x: u32) d.Op {
    if (x == 1) return none;
    const sf = bit(w, 31);
    const scale = bits(w, 15, 10);
    if (sf == 0 and scale < 32) return none;
    const fbits: u64 = 64 - scale;
    const rmode = bits(w, 20, 19);
    const opc = bits(w, 18, 16);
    if (rmode == 0 and (opc == 2 or opc == 3)) {
        var o = fop(.f_fromint, w, x);
        o.sh = @intCast(opc & 1);
        o.a = @intCast(sf);
        o.imm = fbits;
        o.m = 0;
        return o;
    }
    if (rmode == 3 and (opc == 0 or opc == 1)) {
        var o = fop(.f_toint, w, x);
        o.d = gw(bits(w, 4, 0));
        o.sh = @intCast(opc & 1);
        o.a = @intCast(sf);
        o.imm = 3 | fbits << 8;
        o.m = 0;
        return o;
    }
    return none;
}

fn fpInt(w: u32, x: u32) d.Op {
    const sf = bit(w, 31);
    const rmode = bits(w, 20, 19);
    const opc = bits(w, 18, 16);
    const t = bits(w, 23, 22);
    switch (opc) {
        0, 1, 4, 5 => {
            if (x == 1) return none;
            if (opc >= 4 and rmode != 0) return none;
            const r: u64 = if (opc >= 4) 4 else switch (rmode) {
                0 => 0,
                1 => 2,
                2 => 1,
                else => 3,
            };
            var o = fop(.f_toint, w, x);
            o.d = gw(bits(w, 4, 0));
            o.sh = @intCast(opc & 1);
            o.a = @intCast(sf);
            o.imm = r;
            o.m = 0;
            return o;
        },
        2, 3 => {
            if (x == 1 or rmode != 0) return none;
            var o = fop(.f_fromint, w, x);
            o.sh = @intCast(opc & 1);
            o.a = @intCast(sf);
            o.m = 0;
            return o;
        },
        6, 7 => {
            const fx: u32 = if (rmode == 0 and sf == 0 and t == 0) 2 else if (rmode == 0 and sf == 1 and t == 1) 3 else if (rmode == 1 and sf == 1 and t == 2) 4 else return none;
            var o: d.Op = .{ .k = kk(if (opc == 6) .f_mov_tog else .f_mov_fromg), .x = @intCast(fx) };
            if (opc == 6) {
                o.d = gw(bits(w, 4, 0));
                o.n = @intCast(bits(w, 9, 5));
            } else {
                o.d = @intCast(bits(w, 4, 0));
                o.n = @intCast(bits(w, 9, 5));
            }
            return o;
        },
        else => return none,
    }
}

fn fp3(w: u32) d.Op {
    const x = ftype(bits(w, 23, 22)) orelse return none;
    if (x == 1) return none;
    var o = fop(switch (bit(w, 21) << 1 | bit(w, 15)) {
        0 => .f_madd,
        1 => .f_msub,
        2 => .f_nmadd,
        else => .f_nmsub,
    }, w, x);
    o.a = @intCast(bits(w, 14, 10));
    return o;
}

/// The AdvSIMD groups under bits 28:24 = 01110 (vector) and 11110 (scalar):
/// three same, three different, two-register misc, across lanes, pairwise,
/// copy, permute, extract, and table lookup.
fn vec01110(w: u32, scalar: bool) d.Op {
    const q = bit(w, 30);
    if (bit(w, 21) == 1) {
        if (bit(w, 10) == 1) return threeSame(w, scalar, q);
        if (bits(w, 11, 10) == 0) return threeDiff(w, scalar, q);
        if (bits(w, 11, 10) == 0b10) {
            if (bits(w, 20, 17) == 0b0000) return twoMisc(w, scalar, q);
            if (bits(w, 20, 17) == 0b1000) return if (scalar) pairwise(w) else across(w, q);
        }
        return none;
    }
    if (bit(w, 15) != 0) return none;
    if (!scalar and bit(w, 29) == 0 and bits(w, 23, 21) == 0 and bit(w, 10) == 1) return copy(w, q);
    if (!scalar and bit(w, 29) == 1 and bits(w, 23, 21) == 0 and bit(w, 10) == 1) {
        // INS (element)
        if (q != 1) return none;
        const sz = esizeOf(bits(w, 20, 16)) orelse return none;
        var o = op(.ins_e, w, sz, Q);
        o.imm = bits(w, 20, 16) >> @intCast(sz + 1);
        o.a = @intCast(bits(w, 14, 11) >> @intCast(sz));
        o.m = 0;
        return o;
    }
    if (scalar) {
        // DUP (element), scalar: 01 0 11110000 imm5 0 0000 1
        if (bit(w, 29) == 0 and bits(w, 23, 21) == 0 and bits(w, 14, 10) == 0b00001) {
            const sz = esizeOf(bits(w, 20, 16)) orelse return none;
            var o = op(.dup_e, w, sz, SCALAR);
            o.imm = bits(w, 20, 16) >> @intCast(sz + 1);
            o.m = 0;
            return o;
        }
        return none;
    }
    if (bit(w, 29) == 0 and bits(w, 11, 10) == 0 and bits(w, 23, 22) == 0) {
        // TBL, TBX
        var o = op(if (bit(w, 12) == 1) .tbx else .tbl, w, 0, q);
        o.a = @intCast(bits(w, 14, 13));
        return o;
    }
    if (bit(w, 29) == 0 and bits(w, 11, 10) == 0b10) {
        const size = bits(w, 23, 22);
        if (size == 3 and q == 0) return none;
        const k: Kind = switch (bits(w, 14, 12)) {
            0b001 => .uzp1,
            0b010 => .trn1,
            0b011 => .zip1,
            0b101 => .uzp2,
            0b110 => .trn2,
            0b111 => .zip2,
            else => return none,
        };
        return op(k, w, size, q);
    }
    if (bit(w, 29) == 1 and bits(w, 23, 22) == 0 and bit(w, 10) == 0) {
        const imm4 = bits(w, 14, 11);
        if (q == 0 and imm4 >= 8) return none;
        var o = op(.ext, w, 0, q);
        o.imm = imm4;
        return o;
    }
    return none;
}

/// The element size an imm5 (copy) encodes: its lowest set bit.
fn esizeOf(imm5: u32) ?u32 {
    if (imm5 & 0xf == 0) return null;
    return @ctz(imm5);
}

fn copy(w: u32, q: u32) d.Op {
    const imm5 = bits(w, 20, 16);
    const sz = esizeOf(imm5) orelse return none;
    const idx = imm5 >> @intCast(sz + 1);
    switch (bits(w, 14, 11)) {
        0b0000 => { // DUP (element)
            if (sz == 3 and q == 0) return none;
            var o = op(.dup_e, w, sz, q);
            o.imm = idx;
            o.m = 0;
            return o;
        },
        0b0001 => { // DUP (general)
            if (sz == 3 and q == 0) return none;
            var o = op(.dup_g, w, sz, q);
            o.m = 0;
            return o;
        },
        0b0011 => { // INS (general)
            if (q != 1) return none;
            var o = op(.ins_g, w, sz, Q);
            o.imm = idx;
            o.m = 0;
            return o;
        },
        0b0101, 0b0111 => { // SMOV, UMOV: d is a general register
            const signed = bits(w, 14, 11) == 0b0101;
            if (signed) {
                if (sz == 3 or (q == 0 and sz == 2)) return none;
            } else {
                if (q == 1 and sz != 3) return none;
                if (q == 0 and sz == 3) return none;
            }
            var o = op(if (signed) .smov else .umov, w, sz, 0);
            o.d = if (bits(w, 4, 0) == 31) d.SINK else @intCast(bits(w, 4, 0));
            o.a = @intCast(q);
            o.imm = idx;
            o.m = 0;
            return o;
        },
        else => return none,
    }
}

const Rule = enum {
    /// Sizes 0-2, or 3 with Q.
    any,
    /// Sizes 0-2.
    no_d,
    /// Size 1 or 2.
    hs,
    /// Size 0 only.
    b,
    /// The logical ops: any size field (it's the sub-op).
    logical,
};

const Entry = struct { k: Kind, rule: Rule, scalar: enum { no, d_only, any, hs } = .no };

fn three(k: Kind, rule: Rule) Entry {
    return .{ .k = k, .rule = rule };
}

fn threeSame(w: u32, scalar: bool, q: u32) d.Op {
    const u = bit(w, 29);
    const size = bits(w, 23, 22);
    const opc = bits(w, 15, 11);
    if (opc >= 0b11000) return none; // FP: later
    const e: Entry = if (u == 0) switch (opc) {
        0b00000 => three(.shadd, .no_d),
        0b00001 => .{ .k = .sqadd, .rule = .any, .scalar = .any },
        0b00010 => three(.srhadd, .no_d),
        0b00011 => three(switch (size) {
            0 => .and_v,
            1 => .bic_v,
            2 => .orr_v,
            else => .orn_v,
        }, .logical),
        0b00100 => three(.shsub, .no_d),
        0b00101 => .{ .k = .sqsub, .rule = .any, .scalar = .any },
        0b00110 => .{ .k = .cmgt, .rule = .any, .scalar = .d_only },
        0b00111 => .{ .k = .cmge, .rule = .any, .scalar = .d_only },
        0b01000 => .{ .k = .sshl, .rule = .any, .scalar = .d_only },
        0b01001 => .{ .k = .sqshl, .rule = .any, .scalar = .any },
        0b01010 => .{ .k = .srshl, .rule = .any, .scalar = .d_only },
        0b01011 => .{ .k = .sqrshl, .rule = .any, .scalar = .any },
        0b01100 => three(.smax, .no_d),
        0b01101 => three(.smin, .no_d),
        0b01110 => three(.sabd, .no_d),
        0b01111 => three(.saba, .no_d),
        0b10000 => .{ .k = .add, .rule = .any, .scalar = .d_only },
        0b10001 => .{ .k = .cmtst, .rule = .any, .scalar = .d_only },
        0b10010 => three(.mla, .no_d),
        0b10011 => three(.mul, .no_d),
        0b10100 => three(.smaxp, .no_d),
        0b10101 => three(.sminp, .no_d),
        0b10110 => .{ .k = .sqdmulh, .rule = .hs, .scalar = .hs },
        0b10111 => three(.addp, .any),
        else => return none,
    } else switch (opc) {
        0b00000 => three(.uhadd, .no_d),
        0b00001 => .{ .k = .uqadd, .rule = .any, .scalar = .any },
        0b00010 => three(.urhadd, .no_d),
        0b00011 => three(switch (size) {
            0 => .eor_v,
            1 => .bsl,
            2 => .bit,
            else => .bif,
        }, .logical),
        0b00100 => three(.uhsub, .no_d),
        0b00101 => .{ .k = .uqsub, .rule = .any, .scalar = .any },
        0b00110 => .{ .k = .cmhi, .rule = .any, .scalar = .d_only },
        0b00111 => .{ .k = .cmhs, .rule = .any, .scalar = .d_only },
        0b01000 => .{ .k = .ushl, .rule = .any, .scalar = .d_only },
        0b01001 => .{ .k = .uqshl, .rule = .any, .scalar = .any },
        0b01010 => .{ .k = .urshl, .rule = .any, .scalar = .d_only },
        0b01011 => .{ .k = .uqrshl, .rule = .any, .scalar = .any },
        0b01100 => three(.umax, .no_d),
        0b01101 => three(.umin, .no_d),
        0b01110 => three(.uabd, .no_d),
        0b01111 => three(.uaba, .no_d),
        0b10000 => .{ .k = .sub, .rule = .any, .scalar = .d_only },
        0b10001 => .{ .k = .cmeq, .rule = .any, .scalar = .d_only },
        0b10010 => three(.mls, .no_d),
        0b10011 => three(.pmul, .b),
        0b10100 => three(.umaxp, .no_d),
        0b10101 => three(.uminp, .no_d),
        0b10110 => .{ .k = .sqrdmulh, .rule = .hs, .scalar = .hs },
        else => return none,
    };
    if (scalar) {
        const ok = switch (e.scalar) {
            .no => false,
            .d_only => size == 3,
            .any => true,
            .hs => size == 1 or size == 2,
        };
        if (!ok) return none;
        return op(e.k, w, size, SCALAR);
    }
    if (!sizeOk(e.rule, size, q)) return none;
    return op(e.k, w, if (e.rule == .logical) 0 else size, q);
}

fn sizeOk(rule: Rule, size: u32, q: u32) bool {
    return switch (rule) {
        .any => size != 3 or q == 1,
        .no_d => size != 3,
        .hs => size == 1 or size == 2,
        .b => size == 0,
        .logical => true,
    };
}

fn threeDiff(w: u32, scalar: bool, q: u32) d.Op {
    const u = bit(w, 29);
    const size = bits(w, 23, 22);
    const opc = bits(w, 15, 12);
    if (size == 3) return none;
    const k: Kind = switch (opc) {
        0b0000 => if (u == 0) .saddl else .uaddl,
        0b0001 => if (u == 0) .saddw else .uaddw,
        0b0010 => if (u == 0) .ssubl else .usubl,
        0b0011 => if (u == 0) .ssubw else .usubw,
        0b0100 => if (u == 0) .addhn else .raddhn,
        0b0101 => if (u == 0) .sabal else .uabal,
        0b0110 => if (u == 0) .subhn else .rsubhn,
        0b0111 => if (u == 0) .sabdl else .uabdl,
        0b1000 => if (u == 0) .smlal else .umlal,
        0b1001 => if (u == 0) .sqdmlal else return none,
        0b1010 => if (u == 0) .smlsl else .umlsl,
        0b1011 => if (u == 0) .sqdmlsl else return none,
        0b1100 => if (u == 0) .smull else .umull,
        0b1101 => if (u == 0) .sqdmull else return none,
        0b1110 => if (u == 0 and size == 0) .pmull else return none,
        else => return none,
    };
    const sat = k == .sqdmlal or k == .sqdmlsl or k == .sqdmull;
    if (sat and size == 0) return none;
    if (scalar) {
        if (!sat) return none;
        return op(k, w, size, SCALAR);
    }
    return op(k, w, size, q);
}

fn twoMisc(w: u32, scalar: bool, q: u32) d.Op {
    const u = bit(w, 29);
    const size = bits(w, 23, 22);
    const opc = bits(w, 16, 12);
    const Sc = enum { no, d_only, any, narrow };
    const e: struct { k: Kind, rule: Rule, sc: Sc = .no } = if (u == 0) switch (opc) {
        0b00000 => .{ .k = .rev64, .rule = .no_d },
        0b00001 => .{ .k = .rev16, .rule = .b },
        0b00010 => .{ .k = .saddlp, .rule = .no_d },
        0b00011 => .{ .k = .suqadd, .rule = .any, .sc = .any },
        0b00100 => .{ .k = .cls, .rule = .no_d },
        0b00101 => .{ .k = .cnt, .rule = .b },
        0b00110 => .{ .k = .sadalp, .rule = .no_d },
        0b00111 => .{ .k = .sqabs, .rule = .any, .sc = .any },
        0b01000 => .{ .k = .cmgt0, .rule = .any, .sc = .d_only },
        0b01001 => .{ .k = .cmeq0, .rule = .any, .sc = .d_only },
        0b01010 => .{ .k = .cmlt0, .rule = .any, .sc = .d_only },
        0b01011 => .{ .k = .abs, .rule = .any, .sc = .d_only },
        0b10010 => .{ .k = .xtn, .rule = .no_d },
        0b10100 => .{ .k = .sqxtn, .rule = .no_d, .sc = .narrow },
        else => return none,
    } else switch (opc) {
        0b00000 => .{ .k = .rev32, .rule = if (size <= 1) .logical else return none },
        0b00010 => .{ .k = .uaddlp, .rule = .no_d },
        0b00011 => .{ .k = .usqadd, .rule = .any, .sc = .any },
        0b00100 => .{ .k = .clz, .rule = .no_d },
        0b00101 => switch (size) {
            0 => .{ .k = .not, .rule = .logical },
            1 => .{ .k = .rbit, .rule = .logical },
            else => return none,
        },
        0b00110 => .{ .k = .uadalp, .rule = .no_d },
        0b00111 => .{ .k = .sqneg, .rule = .any, .sc = .any },
        0b01000 => .{ .k = .cmge0, .rule = .any, .sc = .d_only },
        0b01001 => .{ .k = .cmle0, .rule = .any, .sc = .d_only },
        0b01011 => .{ .k = .neg, .rule = .any, .sc = .d_only },
        0b10010 => .{ .k = .sqxtun, .rule = .no_d, .sc = .narrow },
        0b10011 => .{ .k = .shll, .rule = .no_d },
        0b10100 => .{ .k = .uqxtn, .rule = .no_d, .sc = .narrow },
        else => return none,
    };
    if (scalar) {
        const ok = switch (e.sc) {
            .no => false,
            .d_only => size == 3,
            .any => true,
            .narrow => size != 3,
        };
        if (!ok) return none;
        return op(e.k, w, size, SCALAR);
    }
    if (!sizeOk(e.rule, size, q)) return none;
    // NOT and RBIT work on bytes, whatever the size field says.
    const x = if (e.k == .not or e.k == .rbit) 0 else size;
    return op(e.k, w, x, q);
}

fn across(w: u32, q: u32) d.Op {
    const u = bit(w, 29);
    const size = bits(w, 23, 22);
    const opc = bits(w, 16, 12);
    const k: Kind = switch (opc) {
        0b00011 => if (u == 0) .saddlv else .uaddlv,
        0b01010 => if (u == 0) .smaxv else .umaxv,
        0b11010 => if (u == 0) .sminv else .uminv,
        0b11011 => if (u == 0) .addv else return none,
        else => return none, // FP: later
    };
    if (size == 3 or (size == 2 and q == 0)) return none;
    return op(k, w, size, q);
}

fn pairwise(w: u32) d.Op {
    // Scalar ADDP: 01 0 11110 11 11000 11011 10
    if (bit(w, 29) == 0 and bits(w, 16, 12) == 0b11011) {
        if (bits(w, 23, 22) != 3) return none;
        return op(.addp, w, 3, Q | SCALAR);
    }
    return none; // FP: later
}

/// Bits 28:24 = 01111 (vector) and 11111 (scalar): modified immediate,
/// shift by immediate, and by element.
fn vec01111(w: u32, scalar: bool) d.Op {
    const q = bit(w, 30);
    if (bit(w, 10) == 1) {
        if (bit(w, 23) != 0) return none;
        if (bits(w, 22, 19) == 0) return if (scalar) none else modImm(w, q);
        return shiftImm(w, scalar, q);
    }
    return byElement(w, scalar, q);
}

fn modImm(w: u32, q: u32) d.Op {
    const opb = bit(w, 29);
    const cmode = bits(w, 15, 12);
    if (bit(w, 11) != 0) return none; // FMOV (half): FP16
    const imm8: u64 = bits(w, 18, 16) << 5 | bits(w, 9, 5);
    const rep = struct {
        fn f(v: u64, comptime n: u7) u64 {
            var r: u64 = 0;
            var i: u7 = 0;
            while (i < 64) : (i += n) r |= v << @intCast(i);
            return r;
        }
    }.f;
    var k: Kind = .movi;
    var imm: u64 = undefined;
    switch (cmode >> 1) {
        0, 1, 2, 3 => {
            imm = rep(imm8 << @intCast(8 * (cmode >> 1)), 32);
            if (cmode & 1 == 1) {
                k = if (opb == 0) .orr_vi else .bic_vi;
            } else if (opb == 1) imm = ~imm;
        },
        4, 5 => {
            imm = rep(imm8 << @intCast(8 * ((cmode >> 1) & 1)), 16);
            if (cmode & 1 == 1) {
                k = if (opb == 0) .orr_vi else .bic_vi;
            } else if (opb == 1) imm = ~imm;
        },
        6 => {
            imm = rep(if (cmode & 1 == 0) imm8 << 8 | 0xff else imm8 << 16 | 0xffff, 32);
            if (opb == 1) imm = ~imm;
        },
        7 => if (cmode == 0b1110) {
            if (opb == 0) {
                imm = rep(imm8, 8);
            } else {
                imm = 0;
                for (0..8) |i| {
                    if (imm8 >> @intCast(i) & 1 == 1) imm |= @as(u64, 0xff) << @intCast(8 * i);
                }
            }
        } else {
            // FMOV (vector, immediate)
            const a = imm8 >> 7;
            const b = imm8 >> 6 & 1;
            const cdefgh = imm8 & 0x3f;
            if (opb == 0) {
                const s: u64 = a << 31 | (b ^ 1) << 30 | (if (b == 1) @as(u64, 0x1f) else 0) << 25 | cdefgh << 19;
                imm = rep(s, 32);
            } else {
                if (q == 0) return none;
                imm = a << 63 | (b ^ 1) << 62 | (if (b == 1) @as(u64, 0xff) else 0) << 54 | cdefgh << 48;
            }
        },
        else => unreachable,
    }
    var o = op(k, w, 3, q);
    o.n = 0;
    o.m = 0;
    o.imm = imm;
    return o;
}

fn shiftImm(w: u32, scalar: bool, q: u32) d.Op {
    const u = bit(w, 29);
    const immh = bits(w, 22, 19);
    const immhb = bits(w, 22, 16);
    const opc = bits(w, 15, 11);
    const sz: u32 = 31 - @clz(immh); // log2 of the element size in bytes
    const esize: u32 = @as(u32, 8) << @intCast(sz);
    const right = 2 * esize - immhb;
    const left = immhb - esize;
    const Shape = enum { same, narrow, long };
    const SC = enum { no, d_only, any };
    const e: struct { k: Kind, left: bool, shape: Shape = .same, sc: SC = .d_only } = if (u == 0) switch (opc) {
        0b00000 => .{ .k = .sshr, .left = false },
        0b00010 => .{ .k = .ssra, .left = false },
        0b00100 => .{ .k = .srshr, .left = false },
        0b00110 => .{ .k = .srsra, .left = false },
        0b01010 => .{ .k = .shl, .left = true },
        0b01110 => .{ .k = .sqshl_i, .left = true, .sc = .any },
        0b10000 => .{ .k = .shrn, .left = false, .shape = .narrow, .sc = .no },
        0b10001 => .{ .k = .rshrn, .left = false, .shape = .narrow, .sc = .no },
        0b10010 => .{ .k = .sqshrn, .left = false, .shape = .narrow, .sc = .any },
        0b10011 => .{ .k = .sqrshrn, .left = false, .shape = .narrow, .sc = .any },
        0b10100 => .{ .k = .sshll, .left = true, .shape = .long, .sc = .no },
        else => return none, // SCVTF and FCVTZS (fixed): later
    } else switch (opc) {
        0b00000 => .{ .k = .ushr, .left = false },
        0b00010 => .{ .k = .usra, .left = false },
        0b00100 => .{ .k = .urshr, .left = false },
        0b00110 => .{ .k = .ursra, .left = false },
        0b01000 => .{ .k = .sri, .left = false },
        0b01010 => .{ .k = .sli, .left = true },
        0b01100 => .{ .k = .sqshlu, .left = true, .sc = .any },
        0b01110 => .{ .k = .uqshl_i, .left = true, .sc = .any },
        0b10000 => .{ .k = .sqshrun, .left = false, .shape = .narrow, .sc = .any },
        0b10001 => .{ .k = .sqrshrun, .left = false, .shape = .narrow, .sc = .any },
        0b10010 => .{ .k = .uqshrn, .left = false, .shape = .narrow, .sc = .any },
        0b10011 => .{ .k = .uqrshrn, .left = false, .shape = .narrow, .sc = .any },
        0b10100 => .{ .k = .ushll, .left = true, .shape = .long, .sc = .no },
        else => return none,
    };
    if (e.shape != .same and sz == 3) return none;
    if (scalar) {
        switch (e.sc) {
            .no => return none,
            .d_only => if (sz != 3) return none,
            .any => {},
        }
    } else if (e.shape == .same and sz == 3 and q == 0) return none;
    var o = op(e.k, w, sz, if (scalar) SCALAR else q);
    o.m = 0;
    o.imm = if (e.left) left else right;
    return o;
}

fn byElement(w: u32, scalar: bool, q: u32) d.Op {
    const u = bit(w, 29);
    const size = bits(w, 23, 22);
    const opc = bits(w, 15, 12);
    const Shape = enum { same, long };
    const e: struct { k: Kind, shape: Shape, sc: bool = false } = if (u == 0) switch (opc) {
        0b0010 => .{ .k = .smlal_e, .shape = .long },
        0b0011 => .{ .k = .sqdmlal_e, .shape = .long, .sc = true },
        0b0110 => .{ .k = .smlsl_e, .shape = .long },
        0b0111 => .{ .k = .sqdmlsl_e, .shape = .long, .sc = true },
        0b1000 => .{ .k = .mul_e, .shape = .same },
        0b1010 => .{ .k = .smull_e, .shape = .long },
        0b1011 => .{ .k = .sqdmull_e, .shape = .long, .sc = true },
        0b1100 => .{ .k = .sqdmulh_e, .shape = .same, .sc = true },
        0b1101 => .{ .k = .sqrdmulh_e, .shape = .same, .sc = true },
        else => return none, // FMLA, FMLS, FMUL: later
    } else switch (opc) {
        0b0000 => .{ .k = .mla_e, .shape = .same },
        0b0010 => .{ .k = .umlal_e, .shape = .long },
        0b0100 => .{ .k = .mls_e, .shape = .same },
        0b0110 => .{ .k = .umlsl_e, .shape = .long },
        0b1010 => .{ .k = .umull_e, .shape = .long },
        else => return none, // FMULX, RDM: later or not v8.0
    };
    if (scalar and !e.sc) return none;
    var idx: u32 = undefined;
    var rm: u32 = undefined;
    switch (size) {
        1 => {
            idx = bit(w, 11) << 2 | bit(w, 21) << 1 | bit(w, 20);
            rm = bits(w, 19, 16);
        },
        2 => {
            idx = bit(w, 11) << 1 | bit(w, 21);
            rm = bits(w, 20, 16);
        },
        else => return none,
    }
    var o = op(e.k, w, size, if (scalar) SCALAR else q);
    o.m = @intCast(rm);
    o.imm = idx;
    return o;
}

// ---------------------------------------------------------------- read and write sets

/// How a kind uses its fields: a V register read, written, or both; a
/// general register; or nothing.
const U = enum { none, vr, vw, vrw, gr, gw };

const Uses = struct { d: U = .vw, n: U = .vr, m: U = .none, a: U = .none, vreg_extra: u8 = 0, flags: d.Use = .none, mem: d.MemUse = .none };

fn uses(k: Kind) Uses {
    return switch (k) {
        // d read too: accumulating, inserting, and the narrowing "2" forms
        // (which keep d's lower half; `regs` refines by Q).
        .saba, .uaba, .mla, .mls, .bsl, .bit, .bif, .sabal, .uabal, .smlal, .umlal, .smlsl, .umlsl, .sqdmlal, .sqdmlsl => .{ .d = .vrw, .m = .vr },
        .mla_e, .mls_e, .smlal_e, .umlal_e, .smlsl_e, .umlsl_e, .sqdmlal_e, .sqdmlsl_e => .{ .d = .vrw, .m = .vr },
        .addhn, .raddhn, .subhn, .rsubhn => .{ .d = .vrw, .m = .vr },
        .sadalp, .uadalp, .suqadd, .usqadd => .{ .d = .vrw },
        .xtn, .sqxtn, .uqxtn, .sqxtun => .{ .d = .vrw },
        .ssra, .usra, .srsra, .ursra, .sri, .sli => .{ .d = .vrw },
        .shrn, .rshrn, .sqshrn, .uqshrn, .sqrshrn, .uqrshrn, .sqshrun, .sqrshrun => .{ .d = .vrw },
        .orr_vi, .bic_vi => .{ .d = .vrw, .n = .none },
        .movi => .{ .n = .none },
        .tbx => .{ .d = .vrw, .m = .vr },
        .tbl => .{ .m = .vr },
        .dup_g => .{ .n = .gr },
        .smov, .umov => .{ .d = .gw },
        .ins_g => .{ .d = .vrw, .n = .gr },
        .ins_e => .{ .d = .vrw },
        .dup_e => .{},
        .rev64, .rev32, .rev16, .saddlp, .uaddlp, .cls, .clz, .cnt, .not, .rbit, .sqabs, .sqneg, .abs, .neg => .{},
        .cmgt0, .cmge0, .cmeq0, .cmle0, .cmlt0, .shll => .{},
        .saddlv, .uaddlv, .smaxv, .umaxv, .sminv, .uminv, .addv => .{},
        .sshr, .ushr, .srshr, .urshr, .shl, .sqshlu, .sqshl_i, .uqshl_i, .sshll, .ushll => .{},
        .f_mov, .f_abs, .f_neg, .f_sqrt, .f_cvt, .f_rint => .{},
        .f_cmp => .{ .d = .none, .m = .vr, .flags = .w },
        .f_ccmp => .{ .d = .none, .m = .vr, .flags = .rw },
        .f_csel => .{ .m = .vr, .flags = .r },
        .f_mov_i => .{ .n = .none },
        .f_madd, .f_msub, .f_nmadd, .f_nmsub => .{ .m = .vr, .a = .vr },
        .f_toint, .f_mov_tog => .{ .d = .gw },
        .f_fromint => .{ .n = .gr },
        .f_mov_fromg => .{ .n = .gr },
        else => .{ .m = .vr },
    };
}

pub fn info(k: d.Kind) d.Info {
    const u = uses(ofKind(k));
    const conv = struct {
        fn f(x: U) d.Use {
            return switch (x) {
                .none => .none,
                .vr, .gr => .r,
                .vw, .gw => .w,
                .vrw => .rw,
            };
        }
    }.f;
    return .{ .d = conv(u.d), .n = conv(u.n), .m = conv(u.m), .a = conv(u.a), .vreg = u.d == .vr or u.d == .vw or u.d == .vrw, .mem = u.mem, .flags = u.flags };
}

pub fn regs(o: d.Op) d.Regs {
    const k = ofKind(o.k);
    const u = uses(k);
    var r: d.Regs = .{ .mem = u.mem, .flags = u.flags };
    const put = struct {
        fn f(rr: *d.Regs, x: U, s: u8) void {
            switch (x) {
                .none => {},
                .vr => rr.vread |= @as(u32, 1) << @intCast(s & 31),
                .vw => rr.vwrite |= @as(u32, 1) << @intCast(s & 31),
                .vrw => {
                    rr.vread |= @as(u32, 1) << @intCast(s & 31);
                    rr.vwrite |= @as(u32, 1) << @intCast(s & 31);
                },
                .gr => if (s != d.ZR and s != d.SINK) {
                    rr.read |= @as(u64, 1) << @intCast(s);
                },
                .gw => if (s != d.ZR and s != d.SINK) {
                    rr.write |= @as(u64, 1) << @intCast(s);
                },
            }
        }
    }.f;
    var du = u.d;
    // The narrowing ops read d only for their "2" forms.
    switch (k) {
        .addhn, .raddhn, .subhn, .rsubhn, .xtn, .sqxtn, .uqxtn, .sqxtun, .shrn, .rshrn, .sqshrn, .uqshrn, .sqrshrn, .uqrshrn, .sqshrun, .sqrshrun => {
            if (o.sh != Q) du = .vw;
        },
        // FMOV V.D[1], Xn keeps the lower half.
        .f_mov_fromg => if (o.x == 4) {
            du = .vrw;
        },
        else => {},
    }
    put(&r, du, o.d);
    put(&r, u.n, o.n);
    put(&r, u.m, o.m);
    put(&r, u.a, o.a);
    switch (k) {
        .tbl, .tbx => for (0..@as(usize, o.a) + 1) |i| {
            r.vread |= @as(u32, 1) << @intCast((o.n + i) & 31);
        },
        else => {},
    }
    return r;
}
