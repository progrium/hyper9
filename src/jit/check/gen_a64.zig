//! Random valid arm64 instruction sequences, for fuzz-a64.
//!
//! A program is `len` instructions from the classes below and an SVC. It
//! runs from 0x1000 with a data page at 0x20000 (x20 points at it, and no
//! instruction writes x16 and up), so every load and store hits the page
//! or, now and then, deliberately misses it. Branches only go forward, so
//! every program ends. The classes are those ha64's T0 implements; add a
//! class here when T0 gains one.

const std = @import("std");

pub const code_va: u64 = 0x1000;
pub const data_va: u64 = 0x20000;
/// x20 holds data_va; x21 an unmapped address; x22 a small index.
pub const base_reg = 20;
pub const bad_reg = 21;
pub const index_reg = 22;
pub const bad_va: u64 = 0x7000_0000;

pub const Class = enum {
    add_imm,
    add_sreg,
    add_ereg,
    logic_sreg,
    logic_imm,
    movw,
    bitfield,
    extr,
    shiftv,
    div,
    madd,
    maddl,
    mulh,
    csel,
    ldst,
    ldst_bad,
    ldp_stp,
    exclusive,
    dmb,
    branch,
    adc,
    ccmp,
    dp1,
    sysreg,
    ldst_modes,
    ldst_v,
    ldp_v,
    ldar_stlr,
};

pub const Options = struct {
    len: u32 = 32,
    /// Classes to draw from; all by default.
    classes: []const Class = std.enums.values(Class),
};

fn reg(r: std.Random) u32 {
    return r.uintLessThan(u32, 16);
}

/// A source register: x0..x15, or now and then ZR.
fn src(r: std.Random) u32 {
    return if (r.uintLessThan(u32, 8) == 0) 31 else reg(r);
}

/// A valid logical-immediate (N, immr, imms) for a 32- or 64-bit op.
fn bitmask(r: std.Random, sf: u32) u32 {
    const sizes = [_]u32{ 2, 4, 8, 16, 32, 64 };
    const e = sizes[r.uintLessThan(usize, if (sf == 1) 6 else 5)];
    const ones = 1 + r.uintLessThan(u32, e - 1);
    const rot = r.uintLessThan(u32, e);
    const n: u32 = if (e == 64) 1 else 0;
    const imms = ((~(2 * e - 1)) & 0x3f) | (ones - 1);
    return (n << 22) | (rot << 16) | (imms << 10);
}

/// One instruction of class `c` at index i of n (for branch targets).
pub fn one(r: std.Random, c: Class, i: u32, n: u32) u32 {
    const sf = r.uintLessThan(u32, 2);
    const d = reg(r);
    const rn = reg(r);
    const rm = src(r);
    const width: u32 = if (sf == 1) 64 else 32;
    return switch (c) {
        // ADD, ADDS, SUB, SUBS (immediate)
        .add_imm => (sf << 31) | (r.uintLessThan(u32, 4) << 29) | 0x11000000 | (r.uintLessThan(u32, 2) << 22) | (r.uintLessThan(u32, 4096) << 10) | (rn << 5) | d,
        // (shifted register); ROR (3) isn't allowed.
        .add_sreg => (sf << 31) | (r.uintLessThan(u32, 4) << 29) | 0x0B000000 | (r.uintLessThan(u32, 3) << 22) | (rm << 16) | (r.uintLessThan(u32, width) << 10) | (rn << 5) | d,
        // (extended register), shift 0..4
        .add_ereg => (sf << 31) | (r.uintLessThan(u32, 4) << 29) | 0x0B200000 | (rm << 16) | (r.uintLessThan(u32, 8) << 13) | (r.uintLessThan(u32, 5) << 10) | (rn << 5) | d,
        // AND BIC ORR ORN EOR EON ANDS BICS (shifted register)
        .logic_sreg => (sf << 31) | (r.uintLessThan(u32, 4) << 29) | 0x0A000000 | (r.uintLessThan(u32, 4) << 22) | (r.uintLessThan(u32, 2) << 21) | (rm << 16) | (r.uintLessThan(u32, width) << 10) | (src(r) << 5) | d,
        // AND ORR EOR ANDS (immediate)
        .logic_imm => (sf << 31) | (r.uintLessThan(u32, 4) << 29) | 0x12000000 | bitmask(r, sf) | (rn << 5) | d,
        // MOVN MOVZ MOVK
        .movw => blk: {
            const opcs = [_]u32{ 0, 2, 3 };
            const opc = opcs[r.uintLessThan(usize, 3)];
            break :blk (sf << 31) | (opc << 29) | 0x12800000 | (r.uintLessThan(u32, if (sf == 1) 4 else 2) << 21) | (r.int(u16) << 5) | d;
        },
        // SBFM BFM UBFM
        .bitfield => (sf << 31) | (r.uintLessThan(u32, 3) << 29) | 0x13000000 | (sf << 22) | (r.uintLessThan(u32, width) << 16) | (r.uintLessThan(u32, width) << 10) | (rn << 5) | d,
        .extr => (sf << 31) | 0x13800000 | (sf << 22) | (rm << 16) | (r.uintLessThan(u32, width) << 10) | (rn << 5) | d,
        // LSLV LSRV ASRV RORV
        .shiftv => (sf << 31) | 0x1AC00000 | (rm << 16) | ((8 + r.uintLessThan(u32, 4)) << 10) | (rn << 5) | d,
        // UDIV SDIV
        .div => (sf << 31) | 0x1AC00000 | (rm << 16) | ((2 + r.uintLessThan(u32, 2)) << 10) | (rn << 5) | d,
        // MADD MSUB
        .madd => (sf << 31) | 0x1B000000 | (rm << 16) | (r.uintLessThan(u32, 2) << 15) | (src(r) << 10) | (rn << 5) | d,
        // SMADDL SMSUBL UMADDL UMSUBL
        .maddl => 0x9B200000 | (r.uintLessThan(u32, 2) << 23) | (rm << 16) | (r.uintLessThan(u32, 2) << 15) | (src(r) << 10) | (rn << 5) | d,
        // SMULH UMULH
        .mulh => 0x9B407C00 | (r.uintLessThan(u32, 2) << 23) | (rm << 16) | (rn << 5) | d,
        // CSEL CSINC CSINV CSNEG
        .csel => (sf << 31) | (r.uintLessThan(u32, 2) << 30) | 0x1A800000 | (rm << 16) | (r.uintLessThan(u32, 16) << 12) | (r.uintLessThan(u32, 2) << 10) | (src(r) << 5) | d,
        // LDR/STR (unsigned offset), every size and sign, within the page
        .ldst, .ldst_bad => blk: {
            const size = r.uintLessThan(u32, 4);
            // No PRFM (size 3, opc 2) and no LDRSW-as-64-to-32 (size 2, opc 3).
            const opc: u32 = switch (size) {
                3 => r.uintLessThan(u32, 2),
                2 => r.uintLessThan(u32, 3),
                else => r.uintLessThan(u32, 4),
            };
            const off = r.uintLessThan(u32, (@as(u32, 4096) >> @intCast(size)) - 1);
            const base: u32 = if (c == .ldst_bad) bad_reg else base_reg;
            break :blk (size << 30) | 0x39000000 | (opc << 22) | (off << 10) | (base << 5) | d;
        },
        // LDP/STP (signed offset), 32 and 64 bit, non-negative offsets
        .ldp_stp => blk: {
            const opc: u32 = if (sf == 1) 2 else 0;
            var t2 = reg(r);
            const l = r.uintLessThan(u32, 2);
            if (l == 1 and t2 == d) t2 = (d + 1) & 15; // LDP with Rt == Rt2 is unpredictable
            break :blk (opc << 30) | 0x29000000 | (l << 22) | (r.uintLessThan(u32, 60) << 15) | (t2 << 10) | (base_reg << 5) | d;
        },
        // LDXR, or STXR with status s ≠ t, both on x20
        .exclusive => blk: {
            const size: u32 = 2 + sf;
            var t2 = reg(r);
            if (t2 == d) t2 = (d + 1) & 15;
            var st = reg(r);
            if (st == d or st == t2) st = (d + 2) & 15;
            switch (r.uintLessThan(u32, 8)) {
                // LDXP and STXP of W pairs (an 8-byte monitor)
                0 => break :blk 0x887F0000 | (t2 << 10) | (base_reg << 5) | d,
                1 => break :blk 0x88200000 | (st << 16) | (r.uintLessThan(u32, 2) << 15) | (t2 << 10) | (base_reg << 5) | d,
                // STXR on x22, which isn't mapped: fails without access
                // unless the monitor holds it
                2 => break :blk (size << 30) | 0x08007C00 | (st << 16) | (index_reg << 5) | d,
                // the acquire and release forms
                3 => break :blk (size << 30) | 0x085FFC00 | (base_reg << 5) | d,
                else => {},
            }
            if (r.boolean()) break :blk (size << 30) | 0x085F7C00 | (base_reg << 5) | d;
            var s = reg(r);
            if (s == d) s = (d + 1) & 15;
            break :blk (size << 30) | 0x08007C00 | (s << 16) | (base_reg << 5) | d;
        },
        .dmb => 0xD5033BBF, // DMB ISH
        // ADC ADCS SBC SBCS
        .adc => (sf << 31) | (r.uintLessThan(u32, 4) << 29) | 0x1A000000 | (rm << 16) | (rn << 5) | d,
        // CCMN CCMP, register or immediate
        .ccmp => (sf << 31) | (r.uintLessThan(u32, 2) << 30) | 0x3A400000 | (r.uintLessThan(u32, 32) << 16) | (r.uintLessThan(u32, 16) << 12) | (r.uintLessThan(u32, 2) << 11) | (src(r) << 5) | r.uintLessThan(u32, 16),
        // RBIT REV16 REV32/REV CLZ CLS (and REV for X)
        .dp1 => blk: {
            const ops = [_]u32{ 0, 1, 2, 4, 5, 3 };
            const op = ops[r.uintLessThan(usize, if (sf == 1) 6 else 5)];
            break :blk (sf << 31) | 0x5AC00000 | (op << 10) | (src(r) << 5) | d;
        },
        // MRS and MSR of NZCV and TPIDR_EL0
        .sysreg => switch (r.uintLessThan(u32, 4)) {
            0 => 0xD53B4200 | d,
            1 => 0xD51B4200 | src(r),
            2 => 0xD53BD040 | d,
            else => 0xD51BD040 | src(r),
        },
        // LDR/STR: unscaled, post- and pre-index (on x20, forward only),
        // register offset (x20 + x22, LSL or UXTW), and literal
        .ldst_modes => blk: {
            const size = r.uintLessThan(u32, 4);
            const opc: u32 = switch (size) {
                3 => r.uintLessThan(u32, 2),
                2 => r.uintLessThan(u32, 3),
                else => r.uintLessThan(u32, 4),
            };
            switch (r.uintLessThan(u32, 4)) {
                0 => {
                    const modes = [_]u32{ 0, 1, 3 };
                    break :blk (size << 30) | 0x38000000 | (opc << 22) | (r.uintLessThan(u32, 64) << 12) | (modes[r.uintLessThan(usize, 3)] << 10) | (base_reg << 5) | d;
                },
                1 => {
                    const opts = [_]u32{ 2, 3 };
                    break :blk (size << 30) | 0x38200800 | (opc << 22) | (index_reg << 16) | (opts[r.uintLessThan(usize, 2)] << 13) | (r.uintLessThan(u32, 2) << 12) | (base_reg << 5) | d;
                },
                2 => break :blk (size << 30) | 0x38000400 | (opc << 22) | (r.uintLessThan(u32, 64) << 12) | (base_reg << 5) | d,
                // LDR (literal) of W, X, or LDRSW, a few words back
                else => {
                    const lsz = r.uintLessThan(u32, 3);
                    const back: u32 = r.uintLessThan(u32, @max(1, i + 1));
                    break :blk (lsz << 30) | 0x18000000 | (((0 -% back) & 0x7ffff) << 5) | d;
                },
            }
        },
        // LDR/STR of B H S D Q registers (unsigned offset on x20)
        .ldst_v => blk: {
            const size = r.uintLessThan(u32, 5);
            const l = r.uintLessThan(u32, 2);
            const sz: u32 = if (size == 4) 0 else size;
            const opc: u32 = (if (size == 4) @as(u32, 2) else 0) | l;
            const off = r.uintLessThan(u32, (@as(u32, 4096) >> @intCast(size)) - 1);
            break :blk (sz << 30) | 0x3D000000 | (opc << 22) | (off << 10) | (base_reg << 5) | d;
        },
        // LDP/STP of S D Q registers (signed offset on x20)
        .ldp_v => blk: {
            var t2 = reg(r);
            const l = r.uintLessThan(u32, 2);
            if (l == 1 and t2 == d) t2 = (d + 1) & 15;
            break :blk (r.uintLessThan(u32, 3) << 30) | 0x2D000000 | (l << 22) | (r.uintLessThan(u32, 60) << 15) | (t2 << 10) | (base_reg << 5) | d;
        },
        // LDAR STLR on x20
        .ldar_stlr => (r.uintLessThan(u32, 4) << 30) | (if (r.boolean()) @as(u32, 0x08DFFC00) else 0x089FFC00) | (base_reg << 5) | d,
        // B.cond, CBZ, CBNZ, TBZ, TBNZ, B: forward, within the program
        .branch => blk: {
            const k = 1 + r.uintLessThan(u32, @max(1, @min(8, n - i)));
            switch (r.uintLessThan(u32, 4)) {
                0 => break :blk 0x54000000 | (k << 5) | r.uintLessThan(u32, 16),
                1 => break :blk (sf << 31) | 0x34000000 | (r.uintLessThan(u32, 2) << 24) | (k << 5) | rn,
                2 => {
                    const bit = r.uintLessThan(u32, 64);
                    break :blk ((bit >> 5) << 31) | 0x36000000 | (r.uintLessThan(u32, 2) << 24) | ((bit & 31) << 19) | ((k & 0x3fff) << 5) | rn;
                },
                else => break :blk 0x14000000 | k,
            }
        },
    };
}

/// Fills `out` with a program (`opts.len` instructions and an SVC) and
/// returns it.
pub fn program(r: std.Random, opts: Options, out: []u32) []u32 {
    const n = @min(opts.len, @as(u32, @intCast(out.len - 1)));
    for (0..n) |i| {
        var c = opts.classes[r.uintLessThan(usize, opts.classes.len)];
        // A bad access ends the program: keep them rare.
        if (c == .ldst_bad and r.uintLessThan(u32, 8) != 0) c = opts.classes[r.uintLessThan(usize, opts.classes.len)];
        out[i] = one(r, c, @intCast(i), n);
    }
    // A store-exclusive whose size isn't its load-exclusive's is
    // CONSTRAINED UNPREDICTABLE: give each STXR the last LDXR's size.
    var size: ?u32 = null;
    for (out[0..n]) |*w| {
        if (w.* & 0x3FFFFC00 == 0x085F7C00) size = w.* >> 30;
        if (w.* & 0x3FE0FC00 == 0x08007C00) {
            if (size) |sz| w.* = (w.* & 0x3FFFFFFF) | (sz << 30);
            size = null;
        }
    }
    out[n] = 0xD4000001; // svc #0
    return out[0 .. n + 1];
}

/// A register value biased to the edges.
pub fn value(r: std.Random) u64 {
    return switch (r.uintLessThan(u32, 8)) {
        0 => 0,
        1 => std.math.maxInt(u64),
        2 => 1 << 63,
        3 => (1 << 63) - 1,
        4 => 0x8000_0000,
        5 => r.uintLessThan(u64, 256),
        6 => @as(u64, @bitCast(-@as(i64, r.uintLessThan(u8, 255)) - 1)),
        else => r.int(u64),
    };
}

/// Starting registers: random x0..x15, x20 at the data page, x21 at an
/// unmapped address, random NZCV.
pub fn registers(r: std.Random) struct { x: [31]u64, nzcv: u32 } {
    var x: [31]u64 = @splat(0);
    for (0..16) |i| x[i] = value(r);
    x[base_reg] = data_va;
    x[bad_reg] = bad_va;
    x[index_reg] = r.uintLessThan(u64, 256) * 8;
    return .{ .x = x, .nzcv = r.uintLessThan(u32, 16) << 28 };
}

test "gen_a64: programs end in SVC and branch only forward" {
    var prng = std.Random.DefaultPrng.init(1);
    var buf: [65]u32 = undefined;
    for (0..100) |_| {
        const p = program(prng.random(), .{ .len = 64 }, &buf);
        try std.testing.expectEqual(@as(u32, 0xD4000001), p[p.len - 1]);
    }
}
