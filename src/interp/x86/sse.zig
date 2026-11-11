//! h86's MMX, SSE, and SSE2. T0's exec.zig sends every `.sse` table
//! entry here (0F 10-17, 28-2F, 50-7F, C2-C6, D0-FF, and 0F AE's FXSAVE,
//! FXRSTOR, LDMXCSR, and STMXCSR). The mandatory prefix is in
//! `x.i.opsize` (66) and `x.i.rep` (F3, F2); F3 and F2 win over 66.
//!
//! MMX registers are the x87's: MMi is the significand of physical
//! register i, and writing one sets its exponent to all ones. Every MMX
//! instruction first raises #MF for a pending x87 exception, then sets
//! TOP to 0 and tags every register valid; EMMS tags them all empty.
//!
//! Floating point goes through softfloat.zig, so it follows MXCSR (rounding,
//! DAZ, FTZ, the flags) and x86's NaN, MIN/MAX, and conversion rules in
//! software. An unmasked exception raises #XM (vector 19) with the
//! destination as it was and the flags set in MXCSR.
//!
//! 128-bit memory operands must be 16-byte aligned (#GP) except for the
//! unaligned moves (MOVUPS, MOVUPD, MOVDQU).
//!
//! The same code serves hx64 in long mode, where the Exec's `c` is a
//! `cpu.Cpu64` and its `i` a `decode.Inst64` (see `isLong`): REX.R and
//! REX.B reach XMM8-15, REX.W widens the general-register operand of MOVD
//! (to MOVQ), CVTSI2SS/SD, CVT(T)SS/SD2SI, and MOVNTI to 64 bits, and
//! FXSAVE and FXRSTOR keep all 16 XMM registers, with REX.W picking the
//! 64-bit FXSAVE64 layout for FIP and FDP. MMX registers and ModRM.reg's
//! opcode extensions ignore REX. A memory operand's address is the Exec's
//! `addr`, which RIP-relative addressing has already resolved.

const std = @import("std");
const cpu = @import("cpu.zig");
const fp = @import("../softfloat.zig");
const x87 = @import("x87.zig");
const flags = @import("flags.zig");

/// T0's long-mode Exec sends `.sse` entries here: this file takes hx64's.
pub const long_mode = true;

const Pfx = enum { none, p66, f3, f2 };

fn prefix(x: anytype) Pfx {
    return switch (x.i.rep) {
        .rep => .f3,
        .repne => .f2,
        .none => if (x.i.opsize) .p66 else .none,
    };
}

fn ud(x: anytype) !void {
    return x.exc(cpu.vec_ud);
}

const isLong = x87.isLong;

/// ModRM.reg as an MMX register, or as an opcode extension: REX.R doesn't
/// reach either.
fn mmReg(i: anytype) u3 {
    return @truncate(i.modrm >> 3);
}

/// ModRM.rm as an MMX register: REX.B doesn't reach it.
fn mmRm(i: anytype) u3 {
    return @truncate(i.modrm);
}

/// The size of a general-register operand: 8 with REX.W in long mode,
/// else 4.
fn gprSize(x: anytype) u8 {
    if (comptime isLong(@TypeOf(x))) return if (x.i.rex.w == 1) 8 else 4;
    return 4;
}

/// Writes a 32-bit result to a general register, zero-extended into all 64
/// bits in long mode, as every 32-bit destination is.
fn putGpr32(x: anytype, n: anytype, v: u32) void {
    if (comptime isLong(@TypeOf(x))) return x.writeReg(n, 8, v);
    x.writeReg(n, 4, v);
}

/// A general register or memory operand of `size` 4 or 8, zero-extended.
fn gprOrMem(x: anytype, size: u8) !u64 {
    const i = x.i;
    if (comptime isLong(@TypeOf(x))) {
        if (size == 8) return if (i.mem) try x.load64(x.addr) else x.readReg(i.rm(), 8);
    }
    return @as(u32, @truncate(if (i.mem) try x.load(x.addr, 4) else x.readReg(i.rm(), 4)));
}

/// Stores `v` to a general register or memory operand of `size` 4 or 8.
fn putGprOrMem(x: anytype, size: u8, v: u64) !void {
    const i = x.i;
    if (comptime isLong(@TypeOf(x))) {
        if (size == 8) return if (i.mem) try x.store64(x.addr, v) else x.writeReg(i.rm(), 8, v);
    }
    if (i.mem) {
        try x.store(x.addr, 4, @as(u32, @truncate(v)));
    } else putGpr32(x, i.rm(), @truncate(v));
}

// ------------------------------------------------------------ registers

fn getMM(x: anytype, n: u3) u64 {
    return x.c.fpu.st[n].signif;
}

fn setMM(x: anytype, n: u3, v: u64) void {
    x.c.fpu.st[n] = .{ .signif = v, .sign_exp = 0xffff };
}

/// The x87-to-MMX transition every MMX instruction makes.
fn mmx(x: anytype) !void {
    try x87.wait(x);
    x.c.fpu.top = 0;
    x.c.fpu.tag = 0xff;
}

fn alignCheck(x: anytype) !void {
    if (x.addr & 15 != 0) return x.exc(cpu.vec_gp);
}

/// The r/m operand as an XMM value: a register, or `size` bytes of
/// memory in the low bytes (16 checked for alignment when `aligned`).
fn xsrc(x: anytype, size: u8, aligned: bool) !u128 {
    if (!x.i.mem) return x.c.xmm[x.i.rm()];
    if (size == 16 and aligned) try alignCheck(x);
    var buf: [16]u8 = @splat(0);
    try x.loadBytes(x.addr, buf[0..size]);
    return std.mem.readInt(u128, &buf, .little);
}

/// The r/m operand as an MMX value.
fn msrc(x: anytype) !u64 {
    if (!x.i.mem) return getMM(x, mmRm(x.i));
    return x.load64(x.addr);
}

fn storeX(x: anytype, size: u8, v: u128, aligned: bool) !void {
    if (size == 16 and aligned) try alignCheck(x);
    var buf: [16]u8 = undefined;
    std.mem.writeInt(u128, &buf, v, .little);
    try x.storeBytes(x.addr, buf[0..size]);
}

fn xreg(x: anytype) *u128 {
    return &x.c.xmm[x.i.reg()];
}

fn lo64(v: u128) u64 {
    return @truncate(v);
}

fn hi64(v: u128) u64 {
    return @truncate(v >> 64);
}

fn join(lo: u64, hi: u64) u128 {
    return @as(u128, hi) << 64 | lo;
}

// ------------------------------------------------------------ MXCSR

const mxcsr_reserved: u32 = 0xffff_0000;

fn env(x: anytype) fp.Env {
    return fp.Env.fromMxcsr(x.c.mxcsr);
}

/// Sets the flags an operation raised in MXCSR, or raises #XM for an
/// unmasked one, before anything is written.
fn raise(x: anytype, e: *const fp.Env) !void {
    // DAZ's ID flag isn't x86's.
    var f: u32 = e.flags & 0x3f;
    const unmasked = f & ~(x.c.mxcsr >> 7) & 0x3f;
    if (unmasked != 0) {
        // An unmasked IE, DE, or ZE stops the operation before it
        // computes: nothing after them is raised.
        if (unmasked & (fp.IE | fp.DE | fp.ZE) != 0) f &= fp.IE | fp.DE | fp.ZE;
        x.c.mxcsr |= f;
        return x.exc(cpu.vec_xm);
    }
    x.c.mxcsr |= f;
}

// ------------------------------------------------------------ entry

pub fn exec(x: anytype) !void {
    const i = x.i;
    const p = prefix(x);
    const op: u8 = @truncate(i.opcode);
    switch (op) {
        0x10...0x17 => return moves1x(x, op, p),
        0x28, 0x29 => {
            if (p == .f3 or p == .f2) return ud(x);
            if (op == 0x28) {
                xreg(x).* = try xsrc(x, 16, true);
            } else if (i.mem) {
                try storeX(x, 16, xreg(x).*, true);
            } else x.c.xmm[i.rm()] = xreg(x).*;
        },
        0x2a => return cvt2a(x, p),
        0x2b => {
            if (p == .f3 or p == .f2 or !i.mem) return ud(x);
            try storeX(x, 16, xreg(x).*, true);
        },
        0x2c, 0x2d => return cvt2c(x, p, op == 0x2c),
        0x2e, 0x2f => {
            if (p == .f3 or p == .f2) return ud(x);
            var e = env(x);
            const ord = if (p == .none) blk: {
                const b = try xsrc(x, 4, false);
                break :blk fp.compare(u32, &e, @truncate(xreg(x).*), @truncate(b), op == 0x2f);
            } else blk: {
                const b = try xsrc(x, 8, false);
                break :blk fp.compare(u64, &e, lo64(xreg(x).*), lo64(b), op == 0x2f);
            };
            try raise(x, &e);
            const v: u32 = switch (ord) {
                .gt => 0,
                .lt => flags.CF,
                .eq => flags.ZF,
                .un => flags.ZF | flags.PF | flags.CF,
            };
            x.c.fl.setMasked(flags.arith, v);
        },
        0x50 => {
            if (p == .f3 or p == .f2 or i.mem) return ud(x);
            const v = x.c.xmm[i.rm()];
            var m: u32 = 0;
            if (p == .none) {
                for (0..4) |k| m |= (@as(u32, @truncate(v >> @intCast(32 * k + 31))) & 1) << @intCast(k);
            } else {
                for (0..2) |k| m |= (@as(u32, @truncate(v >> @intCast(64 * k + 63))) & 1) << @intCast(k);
            }
            putGpr32(x, i.reg(), m);
        },
        0x51, 0x58, 0x59, 0x5c, 0x5d, 0x5e, 0x5f => return arith(x, p, op),
        0x52, 0x53 => {
            if (p == .p66 or p == .f2) return ud(x);
            const scalar = p == .f3;
            const b = try xsrc(x, if (scalar) 4 else 16, true);
            var a: [4]u32 = @bitCast(xreg(x).*);
            const bs: [4]u32 = @bitCast(b);
            for (0..if (scalar) 1 else 4) |k| a[k] = if (op == 0x52) rsqrt(bs[k]) else fp.rcp(bs[k]);
            xreg(x).* = @bitCast(a);
        },
        0x54...0x57 => {
            if (p == .f3 or p == .f2) return ud(x);
            const b = try xsrc(x, 16, true);
            const a = xreg(x).*;
            xreg(x).* = switch (op) {
                0x54 => a & b,
                0x55 => ~a & b,
                0x56 => a | b,
                else => a ^ b,
            };
        },
        0x5a => return cvt5a(x, p),
        0x5b => return cvt5b(x, p),
        0xe6 => return cvtE6(x, p),
        0xc2 => return cmp(x, p),
        0xc3 => {
            // MOVNTI, 64 bits with REX.W.
            if (p != .none or !i.mem) return ud(x);
            if (comptime isLong(@TypeOf(x))) {
                if (gprSize(x) == 8) return x.store64(x.addr, x.readReg(i.reg(), 8));
            }
            try x.store(x.addr, 4, @as(u32, @truncate(x.readReg(i.reg(), 4))));
        },
        0xc6 => {
            if (p == .f3 or p == .f2) return ud(x);
            const b = try xsrc(x, 16, true);
            const a = xreg(x).*;
            const imm: u8 = @truncate(i.imm);
            if (p == .none) {
                const as: [4]u32 = @bitCast(a);
                const bs: [4]u32 = @bitCast(b);
                const r = [4]u32{ as[imm & 3], as[(imm >> 2) & 3], bs[(imm >> 4) & 3], bs[(imm >> 6) & 3] };
                xreg(x).* = @bitCast(r);
            } else {
                const as: [2]u64 = @bitCast(a);
                const bs: [2]u64 = @bitCast(b);
                xreg(x).* = join(as[imm & 1], bs[(imm >> 1) & 1]);
            }
        },
        0xae => return if (p == .none) fxGroup(x) else ud(x),
        else => return integer(x, p, op),
    }
}

// ------------------------------------------------------------ moves

fn moves1x(x: anytype, op: u8, p: Pfx) !void {
    const i = x.i;
    const d = xreg(x);
    switch (op) {
        0x10 => switch (p) {
            .none, .p66 => d.* = try xsrc(x, 16, false),
            .f3 => {
                if (i.mem) {
                    d.* = try x.load(x.addr, 4);
                } else d.* = (d.* & ~@as(u128, 0xffff_ffff)) | (x.c.xmm[i.rm()] & 0xffff_ffff);
            },
            .f2 => {
                if (i.mem) {
                    d.* = try x.load64(x.addr);
                } else d.* = join(lo64(x.c.xmm[i.rm()]), hi64(d.*));
            },
        },
        0x11 => {
            const s = d.*;
            switch (p) {
                .none, .p66 => if (i.mem) try storeX(x, 16, s, false) else {
                    x.c.xmm[i.rm()] = s;
                },
                .f3 => if (i.mem) try x.store(x.addr, 4, @truncate(s)) else {
                    const r = &x.c.xmm[i.rm()];
                    r.* = (r.* & ~@as(u128, 0xffff_ffff)) | (s & 0xffff_ffff);
                },
                .f2 => if (i.mem) try x.store64(x.addr, lo64(s)) else {
                    const r = &x.c.xmm[i.rm()];
                    r.* = join(lo64(s), hi64(r.*));
                },
            }
        },
        0x12, 0x16 => {
            if (p == .f3 or p == .f2) return ud(x);
            if (!i.mem and p == .p66) return ud(x);
            const v: u64 = if (i.mem) try x.load64(x.addr) else if (op == 0x12) hi64(x.c.xmm[i.rm()]) else lo64(x.c.xmm[i.rm()]);
            d.* = if (op == 0x12) join(v, hi64(d.*)) else join(lo64(d.*), v);
        },
        0x13, 0x17 => {
            if (p == .f3 or p == .f2 or !i.mem) return ud(x);
            try x.store64(x.addr, if (op == 0x13) lo64(d.*) else hi64(d.*));
        },
        0x14, 0x15 => {
            if (p == .f3 or p == .f2) return ud(x);
            const b = try xsrc(x, 16, true);
            const a = d.*;
            if (p == .none) {
                const as: [4]u32 = @bitCast(a);
                const bs: [4]u32 = @bitCast(b);
                const h: usize = if (op == 0x15) 2 else 0;
                d.* = @bitCast([4]u32{ as[h], bs[h], as[h + 1], bs[h + 1] });
            } else {
                d.* = if (op == 0x14) join(lo64(a), lo64(b)) else join(hi64(a), hi64(b));
            }
        },
        else => unreachable,
    }
}

// ------------------------------------------------------------ arithmetic

fn arith(x: anytype, p: Pfx, op: u8) !void {
    return switch (p) {
        .none => lanes(x, u32, 4, op),
        .p66 => lanes(x, u64, 2, op),
        .f3 => lanes(x, u32, 1, op),
        .f2 => lanes(x, u64, 1, op),
    };
}

/// x86's division: a denormal divided by zero raises ZE without DE.
fn div(comptime T: type, e: *fp.Env, a: T, b: T) T {
    const before = e.flags;
    const r = fp.div(T, e, a, b);
    if (fp.isZero(T, b) and !fp.isNan(T, a) and e.flags & fp.ZE != 0) e.flags = before | ((e.flags & ~before) & ~fp.DE);
    return r;
}

/// RSQRTSS: about 1/sqrt(a), as 1/(sqrt(a)), which stays in range where
/// sqrt(1/a) would lose a denormal 1/a to DAZ.
fn rsqrt(a: u32) u32 {
    const F = fp.Fmt(u32);
    if (fp.isNan(u32, a)) return fp.quiet(u32, a);
    var e: fp.Env = .{ .daz = true };
    const v = fp.daz(u32, &e, a);
    if (v & ~F.sign_bit == 0) return v | F.inf;
    if (v & F.sign_bit != 0) return fp.defaultNan(u32, &e);
    const r = fp.div(u32, &e, 0x3f80_0000, fp.sqrt(u32, &e, v));
    return if (fp.isDenormal(u32, r)) 0 else r;
}

// An unmasked overflow or underflow delivers no result, and PE then says
// whether the result with an unbounded exponent would have been inexact,
// not whether the rounded, range-limited one is.

fn unmaskedRange(x: anytype, raised: u8) bool {
    const unmasked = raised & ~(x.c.mxcsr >> 7) & 0x3f;
    return unmasked & (fp.OE | fp.UE) != 0;
}

/// A finite value as m * 2^e.
fn decompose(comptime T: type, v: T) struct { neg: bool, m: u256, e: i32 } {
    const F = fp.Fmt(T);
    const ef: i32 = @intCast((v >> F.frac_bits) & F.exp_max);
    const f: u256 = v & F.frac_mask;
    return .{
        .neg = v & F.sign_bit != 0,
        .m = if (ef == 0) f else f | (@as(u256, 1) << F.frac_bits),
        .e = (if (ef == 0) 1 else ef) - F.bias - F.frac_bits,
    };
}

/// Whether m fits a significand of p bits.
fn fits(m: u256, p: u32) bool {
    if (m == 0) return true;
    return 256 - @clz(m) - @ctz(m) <= p;
}

/// Whether the exact result of add, sub, mul, or div fits T's significand.
fn exactUnbounded(comptime T: type, op: u8, a: T, b: T) bool {
    const p = fp.Fmt(T).frac_bits + 1;
    const x = decompose(T, a);
    const y = decompose(T, b);
    switch (op) {
        0x59 => return fits(x.m * y.m, p),
        0x5e => {
            if (x.m == 0 or y.m == 0) return true;
            const xo = x.m >> @intCast(@ctz(x.m));
            const yo = y.m >> @intCast(@ctz(y.m));
            return xo % yo == 0 and fits(xo / yo, p);
        },
        0x58, 0x5c => {
            if (x.m == 0 or y.m == 0) return true;
            const hi, const lo = if (x.e >= y.e) .{ x, y } else .{ y, x };
            const d = hi.e - lo.e;
            if (d > 190) return false;
            const big = hi.m << @intCast(d);
            const sub = (x.neg != y.neg) != (op == 0x5c);
            const sum = if (!sub) big + lo.m else if (big >= lo.m) big - lo.m else lo.m - big;
            return fits(sum, p);
        },
        else => return true,
    }
}

/// CVTSD2SS's and CVTPD2PS's narrowing, with PE as above.
fn narrow(x: anytype, e: *fp.Env, v: u64) u32 {
    var le = e.*;
    le.flags = 0;
    const r = fp.f64to32(&le, v);
    if (unmaskedRange(x, le.flags)) {
        le.flags &= ~fp.PE;
        if (!fits(decompose(u64, fp.daz(u64, &le, v)).m, 24)) le.flags |= fp.PE;
    }
    e.flags |= le.flags;
    return r;
}

fn lanes(x: anytype, comptime T: type, comptime n: usize, op: u8) !void {
    const k = 16 / @sizeOf(T);
    const b = try xsrc(x, if (n == 1) @sizeOf(T) else 16, true);
    var a: [k]T = @bitCast(xreg(x).*);
    const bs: [k]T = @bitCast(b);
    var e = env(x);
    for (0..n) |j| {
        var le = e;
        le.flags = 0;
        const a0 = a[j];
        a[j] = switch (op) {
            0x51 => fp.sqrt(T, &le, bs[j]),
            0x58 => fp.add(T, &le, a[j], bs[j]),
            0x59 => fp.mul(T, &le, a[j], bs[j]),
            0x5c => fp.sub(T, &le, a[j], bs[j]),
            // DAZ applies to the operand MIN and MAX return, NaN or not.
            0x5d => fp.min(T, &le, fp.daz(T, &le, a[j]), fp.daz(T, &le, bs[j])),
            0x5e => div(T, &le, a[j], bs[j]),
            0x5f => fp.max(T, &le, fp.daz(T, &le, a[j]), fp.daz(T, &le, bs[j])),
            else => unreachable,
        };
        if (unmaskedRange(x, le.flags)) {
            const u = fp.daz(T, &le, a0);
            const v = fp.daz(T, &le, bs[j]);
            le.flags &= ~fp.PE;
            if (!exactUnbounded(T, op, u, v)) le.flags |= fp.PE;
        }
        e.flags |= le.flags;
    }
    try raise(x, &e);
    xreg(x).* = @bitCast(a);
}

fn cmp(x: anytype, p: Pfx) !void {
    return switch (p) {
        .none => cmpLanes(x, u32, 4),
        .p66 => cmpLanes(x, u64, 2),
        .f3 => cmpLanes(x, u32, 1),
        .f2 => cmpLanes(x, u64, 1),
    };
}

fn cmpLanes(x: anytype, comptime T: type, comptime n: usize) !void {
    const k = 16 / @sizeOf(T);
    const b = try xsrc(x, if (n == 1) @sizeOf(T) else 16, true);
    var a: [k]T = @bitCast(xreg(x).*);
    const bs: [k]T = @bitCast(b);
    const pred: u3 = @truncate(x.i.imm);
    // LT, LE, NLT, and NLE signal on a quiet NaN too.
    const signaling = switch (pred) {
        1, 2, 5, 6 => true,
        else => false,
    };
    var e = env(x);
    for (0..n) |j| {
        const o = fp.compare(T, &e, a[j], bs[j], signaling);
        const t = switch (pred) {
            0 => o == .eq,
            1 => o == .lt,
            2 => o == .lt or o == .eq,
            3 => o == .un,
            4 => o != .eq,
            5 => o != .lt,
            6 => !(o == .lt or o == .eq),
            7 => o != .un,
        };
        a[j] = if (t) std.math.maxInt(T) else 0;
    }
    try raise(x, &e);
    xreg(x).* = @bitCast(a);
}

// ------------------------------------------------------------ conversions

fn cvt2a(x: anytype, p: Pfx) !void {
    const i = x.i;
    var e = env(x);
    const d = xreg(x);
    switch (p) {
        .none, .p66 => {
            // CVTPI2PS and CVTPI2PD: from an MMX register (a transition)
            // or memory.
            if (!i.mem) try mmx(x);
            const v = try msrc(x);
            const ints = [2]i32{ @bitCast(@as(u32, @truncate(v))), @bitCast(@as(u32, @truncate(v >> 32))) };
            if (p == .none) {
                const r0 = fp.fromI32(u32, &e, ints[0]);
                const r1 = fp.fromI32(u32, &e, ints[1]);
                try raise(x, &e);
                d.* = (d.* & ~@as(u128, std.math.maxInt(u64))) | @as(u128, r1) << 32 | r0;
            } else {
                d.* = join(fp.fromI32(u64, &e, ints[0]), fp.fromI32(u64, &e, ints[1]));
            }
        },
        .f3, .f2 => {
            // CVTSI2SS and CVTSI2SD, from an i64 with REX.W.
            const size = gprSize(x);
            const raw = try gprOrMem(x, size);
            const v: i64 = if (size == 8) @bitCast(raw) else @as(i32, @bitCast(@as(u32, @truncate(raw))));
            if (p == .f3) {
                const r = fp.fromInt(u32, i64, &e, v);
                try raise(x, &e);
                d.* = (d.* & ~@as(u128, 0xffff_ffff)) | r;
            } else {
                const r = fp.fromInt(u64, i64, &e, v);
                try raise(x, &e);
                d.* = join(r, hi64(d.*));
            }
        },
    }
}

/// CVTTPS2PI, CVTPS2PI, CVTTPD2PI, CVTPD2PI, CVT(T)SS2SI, and CVT(T)SD2SI.
fn cvt2c(x: anytype, p: Pfx, trunc: bool) !void {
    const i = x.i;
    var e = env(x);
    switch (p) {
        .none, .p66 => {
            // #MF, then the operand's faults, then the transition and #XM.
            try x87.wait(x);
            const v = try xsrc(x, if (p == .none) 8 else 16, p == .p66);
            try mmx(x);
            const r = if (p == .none) blk: {
                const a: [4]u32 = @bitCast(v);
                break :blk [2]i32{ fp.toI32(u32, &e, a[0], trunc), fp.toI32(u32, &e, a[1], trunc) };
            } else [2]i32{ fp.toI32(u64, &e, lo64(v), trunc), fp.toI32(u64, &e, hi64(v), trunc) };
            try raise(x, &e);
            setMM(x, mmReg(i), @as(u64, @as(u32, @bitCast(r[1]))) << 32 | @as(u32, @bitCast(r[0])));
        },
        .f3, .f2 => {
            // CVT(T)SS2SI and CVT(T)SD2SI, to an i64 with REX.W: NaNs and
            // values out of range give the integer indefinite, the
            // smallest integer, and raise IE.
            const v = try xsrc(x, if (p == .f3) 4 else 8, false);
            const rnd: fp.Rounding = if (trunc) .zero else e.rounding;
            if (comptime isLong(@TypeOf(x))) if (gprSize(x) == 8) {
                const r = if (p == .f3)
                    fp.toInt(u32, i64, &e, @truncate(v), rnd)
                else
                    fp.toInt(u64, i64, &e, lo64(v), rnd);
                try raise(x, &e);
                x.writeReg(i.reg(), 8, @as(u64, @bitCast(r orelse std.math.minInt(i64))));
                return;
            };
            const r = if (p == .f3)
                fp.toI32(u32, &e, @truncate(v), trunc)
            else
                fp.toI32(u64, &e, lo64(v), trunc);
            try raise(x, &e);
            putGpr32(x, i.reg(), @bitCast(r));
        },
    }
}

fn cvt5a(x: anytype, p: Pfx) !void {
    var e = env(x);
    const d = xreg(x);
    switch (p) {
        .none => {
            const v = try xsrc(x, 8, false);
            const a: [4]u32 = @bitCast(v);
            const r = join(fp.f32to64(&e, a[0]), fp.f32to64(&e, a[1]));
            try raise(x, &e);
            d.* = r;
        },
        .p66 => {
            const v = try xsrc(x, 16, true);
            const r0 = narrow(x, &e, lo64(v));
            const r1 = narrow(x, &e, hi64(v));
            try raise(x, &e);
            d.* = @as(u128, r1) << 32 | r0;
        },
        .f3 => {
            const v = try xsrc(x, 4, false);
            const r = fp.f32to64(&e, @truncate(v));
            try raise(x, &e);
            d.* = join(r, hi64(d.*));
        },
        .f2 => {
            const v = try xsrc(x, 8, false);
            const r = narrow(x, &e, lo64(v));
            try raise(x, &e);
            d.* = (d.* & ~@as(u128, 0xffff_ffff)) | r;
        },
    }
}

fn cvt5b(x: anytype, p: Pfx) !void {
    if (p == .f2) return ud(x);
    var e = env(x);
    const v = try xsrc(x, 16, true);
    var a: [4]u32 = @bitCast(v);
    for (&a) |*l| l.* = switch (p) {
        .none => fp.fromI32(u32, &e, @bitCast(l.*)),
        .p66 => @bitCast(fp.toI32(u32, &e, l.*, false)),
        else => @bitCast(fp.toI32(u32, &e, l.*, true)),
    };
    try raise(x, &e);
    xreg(x).* = @bitCast(a);
}

fn cvtE6(x: anytype, p: Pfx) !void {
    var e = env(x);
    switch (p) {
        .none => return ud(x),
        .f3 => {
            // CVTDQ2PD: exact.
            const v = try xsrc(x, 8, false);
            const a: [4]u32 = @bitCast(v);
            xreg(x).* = join(fp.fromI32(u64, &e, @bitCast(a[0])), fp.fromI32(u64, &e, @bitCast(a[1])));
        },
        .p66, .f2 => {
            const v = try xsrc(x, 16, true);
            const t = p == .p66;
            const r0: u32 = @bitCast(fp.toI32(u64, &e, lo64(v), t));
            const r1: u32 = @bitCast(fp.toI32(u64, &e, hi64(v), t));
            try raise(x, &e);
            xreg(x).* = @as(u128, r1) << 32 | r0;
        },
    }
}

// ------------------------------------------------------------ FXSAVE

fn fxGroup(x: anytype) !void {
    const i = x.i;
    switch (mmReg(i)) {
        0 => return fxsave(x),
        1 => return fxrstor(x),
        2 => {
            const v: u32 = @truncate(try x.load(x.addr, 4));
            if (v & mxcsr_reserved != 0) return x.exc(cpu.vec_gp);
            x.c.mxcsr = v;
        },
        3 => try x.store(x.addr, 4, x.c.mxcsr),
        else => return ud(x),
    }
}

/// FXSAVE's image. In long mode it holds all 16 XMM registers, and
/// FXSAVE64 (REX.W) keeps FIP and FDP as whole 64-bit addresses where
/// FXSAVE keeps 32-bit offsets and a selector, which hx64 has none of and
/// stores as 0. Bytes past the XMM registers aren't written.
fn fxsave(x: anytype) !void {
    try alignCheck(x);
    const long = comptime isLong(@TypeOf(x));
    const nx = if (long) 16 else 8;
    const p = &x.c.fpu;
    var b: [160 + 16 * nx]u8 = @splat(0);
    std.mem.writeInt(u16, b[0..2], p.cw, .little);
    std.mem.writeInt(u16, b[2..4], x87.statusWord(p), .little);
    b[4] = p.tag;
    std.mem.writeInt(u16, b[6..8], p.fop, .little);
    const ptr_mask: u64 = if (!long) 0xffff_ffff_ffff else if (x.i.rex.w == 1) std.math.maxInt(u64) else 0xffff_ffff;
    std.mem.writeInt(u64, b[8..16], p.fip & ptr_mask, .little);
    std.mem.writeInt(u64, b[16..24], p.fdp & ptr_mask, .little);
    std.mem.writeInt(u32, b[24..28], x.c.mxcsr, .little);
    std.mem.writeInt(u32, b[28..32], 0xffff, .little);
    for (0..8) |k| std.mem.writeInt(u80, b[32 + 16 * k ..][0..10], x87.st(p, @intCast(k)).toBits(), .little);
    for (0..nx) |k| std.mem.writeInt(u128, b[160 + 16 * k ..][0..16], x.c.xmm[k], .little);
    try x.storeBytes(x.addr, &b);
}

fn fxrstor(x: anytype) !void {
    try alignCheck(x);
    const long = comptime isLong(@TypeOf(x));
    const nx = if (long) 16 else 8;
    var b: [160 + 16 * nx]u8 = undefined;
    try x.loadBytes(x.addr, &b);
    const mx = std.mem.readInt(u32, b[24..28], .little);
    if (mx & mxcsr_reserved != 0) return x.exc(cpu.vec_gp);
    const p = &x.c.fpu;
    p.cw = std.mem.readInt(u16, b[0..2], .little);
    const sw = std.mem.readInt(u16, b[2..4], .little);
    p.top = @truncate(sw >> 11);
    p.sw = sw & ~@as(u16, 0x3800);
    p.tag = b[4];
    p.fop = std.mem.readInt(u16, b[6..8], .little) & 0x7ff;
    const ptr_mask: u64 = if (!long) 0xffff_ffff_ffff else if (x.i.rex.w == 1) std.math.maxInt(u64) else 0xffff_ffff;
    p.fip = std.mem.readInt(u64, b[8..16], .little) & ptr_mask;
    p.fdp = std.mem.readInt(u64, b[16..24], .little) & ptr_mask;
    x.c.mxcsr = mx;
    for (0..8) |k| p.st[x87.phys(p, @intCast(k))] = .fromBits(std.mem.readInt(u80, b[32 + 16 * k ..][0..10], .little));
    for (0..nx) |k| x.c.xmm[k] = std.mem.readInt(u128, b[160 + 16 * k ..][0..16], .little);
}

// ------------------------------------------------------------ integer SIMD

/// MMX (no prefix) or SSE2 (66) integer instructions and their moves.
fn integer(x: anytype, p: Pfx, op: u8) !void {
    const i = x.i;
    // The ones with F3 or F2 forms.
    switch (op) {
        0x6f, 0x7f => if (p == .f3) {
            // MOVDQU.
            if (op == 0x6f) {
                xreg(x).* = try xsrc(x, 16, false);
            } else if (i.mem) {
                try storeX(x, 16, xreg(x).*, false);
            } else {
                x.c.xmm[i.rm()] = xreg(x).*;
            }
            return;
        },
        0x7e => if (p == .f3) {
            // MOVQ xmm, xmm/m64.
            xreg(x).* = lo64(try xsrc(x, 8, false));
            return;
        },
        0x70 => if (p == .f3 or p == .f2) {
            // PSHUFHW and PSHUFLW.
            const v = try xsrc(x, 16, true);
            var w: [8]u16 = @bitCast(v);
            const s = w;
            const base: usize = if (p == .f3) 4 else 0;
            const imm: u8 = @truncate(i.imm);
            for (0..4) |k| w[base + k] = s[base + ((imm >> @intCast(2 * k)) & 3)];
            xreg(x).* = @bitCast(w);
            return;
        },
        0xd6 => switch (p) {
            .p66 => {
                const v = lo64(xreg(x).*);
                if (i.mem) try x.store64(x.addr, v) else x.c.xmm[i.rm()] = v;
                return;
            },
            .f3 => {
                // MOVQ2DQ.
                if (i.mem) return ud(x);
                try mmx(x);
                xreg(x).* = getMM(x, mmRm(i));
                return;
            },
            .f2 => {
                // MOVDQ2Q.
                if (i.mem) return ud(x);
                try mmx(x);
                setMM(x, mmReg(i), lo64(x.c.xmm[i.rm()]));
                return;
            },
            .none => return ud(x),
        },
        else => {},
    }
    if (p == .f3 or p == .f2) return ud(x);
    // Not in SSE2 (or not defined at all).
    switch (op) {
        0xd0, 0xf0, 0xff, 0x7c, 0x7d, 0x78, 0x79, 0x7a, 0x7b => return ud(x),
        0x6c, 0x6d => if (p == .none) return ud(x),
        0x77 => {
            if (p != .none) return ud(x);
            try x87.wait(x);
            x.c.fpu.tag = 0;
            x.c.fpu.top = 0;
            return;
        },
        else => {},
    }
    if (p == .none) return integerOp(x, u64, op);
    return integerOp(x, u128, op);
}

fn V(comptime W: type, comptime T: type) type {
    return @Vector(@bitSizeOf(W) / @bitSizeOf(T), T);
}

fn vec(comptime W: type, comptime T: type, v: W) V(W, T) {
    return @bitCast(v);
}

fn bits(comptime W: type, v: anytype) W {
    return @bitCast(v);
}

/// A lane-wise comparison's mask: all ones where true.
fn mask(comptime W: type, comptime T: type, c: @Vector(@bitSizeOf(W) / @bitSizeOf(T), bool)) W {
    const n = @bitSizeOf(W) / @bitSizeOf(T);
    const U = std.meta.Int(.unsigned, @bitSizeOf(T));
    const ones: @Vector(n, U) = @splat(std.math.maxInt(U));
    const zeros: @Vector(n, U) = @splat(0);
    return @bitCast(@select(U, c, ones, zeros));
}

/// Whether an MMX form exists, so as to raise #UD before the transition.
fn mmxValid(i: anytype, op: u8) bool {
    return switch (op) {
        0xe7 => i.mem,
        0xd7, 0xc5, 0xf7 => !i.mem,
        0x71, 0x72 => !i.mem and (mmReg(i) == 2 or mmReg(i) == 4 or mmReg(i) == 6),
        0x73 => !i.mem and (mmReg(i) == 2 or mmReg(i) == 6),
        0x6e, 0x7e, 0x6f, 0x7f, 0x70, 0xc4 => true,
        else => binop(u64, op, 0, 0) != null,
    };
}

/// W is u64 for MMX and u128 for XMM.
fn integerOp(x: anytype, comptime W: type, op: u8) !void {
    const i = x.i;
    const is_mmx = W == u64;
    // #UD comes before the MMX transition, which waits and resets TOP.
    if (is_mmx and !mmxValid(i, op)) return ud(x);
    if (is_mmx) try mmx(x);
    const S = struct {
        fn src(xx: anytype) !W {
            return if (is_mmx) try msrc(xx) else try xsrc(xx, 16, true);
        }
        fn get(xx: anytype) W {
            return if (is_mmx) getMM(xx, mmReg(xx.i)) else xx.c.xmm[xx.i.reg()];
        }
        fn set(xx: anytype, v: W) void {
            if (is_mmx) setMM(xx, mmReg(xx.i), v) else xx.c.xmm[xx.i.reg()] = v;
        }
        fn rmGet(xx: anytype) W {
            return if (is_mmx) getMM(xx, mmRm(xx.i)) else xx.c.xmm[xx.i.rm()];
        }
        fn rmSet(xx: anytype, v: W) void {
            if (is_mmx) setMM(xx, mmRm(xx.i), v) else xx.c.xmm[xx.i.rm()] = v;
        }
    };
    switch (op) {
        // Moves.
        0x6e => {
            // MOVD, or MOVQ from a 64-bit register or memory with REX.W.
            S.set(x, try gprOrMem(x, gprSize(x)));
            return;
        },
        0x7e => {
            try putGprOrMem(x, gprSize(x), lo64(S.get(x)));
            return;
        },
        0x6f => {
            S.set(x, try S.src(x));
            return;
        },
        0x7f => {
            const v = S.get(x);
            if (!i.mem) return S.rmSet(x, v);
            if (is_mmx) try x.store64(x.addr, v) else try storeX(x, 16, v, true);
            return;
        },
        0xe7 => {
            // MOVNTQ and MOVNTDQ.
            if (!i.mem) return ud(x);
            const v = S.get(x);
            if (is_mmx) try x.store64(x.addr, v) else try storeX(x, 16, v, true);
            return;
        },
        0xd7 => {
            if (i.mem) return ud(x);
            const v = vec(W, u8, S.rmGet(x));
            const n = @bitSizeOf(W) / 8;
            var m: u32 = 0;
            inline for (0..n) |k| m |= @as(u32, v[k] >> 7) << @intCast(k);
            putGpr32(x, i.reg(), m);
            return;
        },
        0xc5 => {
            if (i.mem) return ud(x);
            const n = @bitSizeOf(W) / 16;
            const v: [n]u16 = @bitCast(S.rmGet(x));
            putGpr32(x, i.reg(), v[@as(usize, @truncate(i.imm)) % n]);
            return;
        },
        0xc4 => {
            const w: u16 = @truncate(if (i.mem) try x.load(x.addr, 2) else x.readReg(i.rm(), 2));
            const n = @bitSizeOf(W) / 16;
            var v: [n]u16 = @bitCast(S.get(x));
            v[@as(usize, @truncate(i.imm)) % n] = w;
            S.set(x, @bitCast(v));
            return;
        },
        0x70 => {
            const T = if (is_mmx) u16 else u32;
            const s: [4]T = @bitCast(try S.src(x));
            var r = s;
            const imm: u8 = @truncate(i.imm);
            for (0..4) |k| r[k] = s[(imm >> @intCast(2 * k)) & 3];
            S.set(x, @bitCast(r));
            return;
        },
        0x71, 0x72, 0x73 => {
            if (i.mem) return ud(x);
            const c: u64 = i.imm & 0xff;
            const v = S.rmGet(x);
            const r: W = switch (op) {
                0x71 => switch (mmReg(i)) {
                    2 => shift(W, u16, v, c, .srl),
                    4 => shift(W, u16, v, c, .sra),
                    6 => shift(W, u16, v, c, .sll),
                    else => return ud(x),
                },
                0x72 => switch (mmReg(i)) {
                    2 => shift(W, u32, v, c, .srl),
                    4 => shift(W, u32, v, c, .sra),
                    6 => shift(W, u32, v, c, .sll),
                    else => return ud(x),
                },
                else => switch (mmReg(i)) {
                    2 => shift(W, u64, v, c, .srl),
                    6 => shift(W, u64, v, c, .sll),
                    3, 7 => blk: {
                        // PSRLDQ and PSLLDQ: bytes, XMM only.
                        if (is_mmx) return ud(x);
                        if (c >= 16) break :blk 0;
                        const n: u7 = @intCast(c * 8);
                        break :blk if (mmReg(i) == 3) v >> n else v << n;
                    },
                    else => return ud(x),
                },
            };
            S.rmSet(x, r);
            return;
        },
        0xf7 => {
            // MASKMOVQ and MASKMOVDQU: to DS:EDI (or another segment).
            if (i.mem) return ud(x);
            const v = vec(W, u8, S.get(x));
            const m = vec(W, u8, S.rmGet(x));
            const a = try maskAddr(x);
            const n = @bitSizeOf(W) / 8;
            inline for (0..n) |k| {
                if (m[k] & 0x80 != 0) try x.store(a +% @as(@TypeOf(a), k), 1, v[k]);
            }
            return;
        },
        else => {},
    }
    const a = S.get(x);
    const b = try S.src(x);
    S.set(x, binop(W, op, a, b) orelse return ud(x));
}

/// MASKMOVQ's and MASKMOVDQU's address: DS:EDI, or another segment's;
/// in long mode RDI (EDI with 67), plus FS's or GS's base.
fn maskAddr(x: anytype) !@TypeOf(x.addr) {
    const i = x.i;
    const s = @intFromEnum(i.seg);
    if (comptime isLong(@TypeOf(x))) {
        var a = x.c.r[7];
        if (i.addr32) a &= 0xffff_ffff;
        if (i.seg == .fs) a +%= x.c.fs_base;
        if (i.seg == .gs) a +%= x.c.gs_base;
        return a;
    }
    if (s >= 4 and x.c.seg_null & (@as(u8, 1) << @intCast(s)) != 0) return x.exc(cpu.vec_gp);
    var a = x.c.r[7];
    if (i.addr16) a &= 0xffff;
    return a +% x.c.seg_base[s];
}

const Shift = enum { sll, srl, sra };

fn shift(comptime W: type, comptime T: type, v: W, count: u64, how: Shift) W {
    const n = @bitSizeOf(W) / @bitSizeOf(T);
    const width = @bitSizeOf(T);
    const S = std.math.Log2Int(T);
    const lanes_: @Vector(n, T) = @bitCast(v);
    if (count >= width) {
        if (how != .sra) return 0;
        const I = std.meta.Int(.signed, width);
        const sl: @Vector(n, I) = @bitCast(lanes_);
        return @bitCast(sl >> @splat(width - 1));
    }
    const c: @Vector(n, S) = @splat(@intCast(count));
    return switch (how) {
        .sll => @bitCast(lanes_ << c),
        .srl => @bitCast(lanes_ >> c),
        .sra => blk: {
            const I = std.meta.Int(.signed, width);
            const sl: @Vector(n, I) = @bitCast(lanes_);
            break :blk @bitCast(sl >> c);
        },
    };
}

fn signed(comptime W: type, comptime T: type, v: W) @Vector(@bitSizeOf(W) / @bitSizeOf(T), T) {
    return @bitCast(v);
}

/// The two-operand integer instructions: a = a op b.
fn binop(comptime W: type, op: u8, a: W, b: W) ?W {
    const B = struct {
        fn u(comptime T: type, v: W) V(W, T) {
            return vec(W, T, v);
        }
        fn s(comptime T: type, v: W) V(W, T) {
            return signed(W, T, v);
        }
    };
    return switch (op) {
        // Unpacks: interleave the low (or high) halves.
        0x60 => unpack(W, u8, a, b, false),
        0x61 => unpack(W, u16, a, b, false),
        0x62 => unpack(W, u32, a, b, false),
        0x68 => unpack(W, u8, a, b, true),
        0x69 => unpack(W, u16, a, b, true),
        0x6a => unpack(W, u32, a, b, true),
        0x6c => unpack(W, u64, a, b, false),
        0x6d => unpack(W, u64, a, b, true),
        // Packs with saturation.
        0x63 => pack(W, i16, i8, a, b),
        0x67 => pack(W, i16, u8, a, b),
        0x6b => pack(W, i32, i16, a, b),
        // Compares.
        0x64 => mask(W, i8, B.s(i8, a) > B.s(i8, b)),
        0x65 => mask(W, i16, B.s(i16, a) > B.s(i16, b)),
        0x66 => mask(W, i32, B.s(i32, a) > B.s(i32, b)),
        0x74 => mask(W, u8, B.u(u8, a) == B.u(u8, b)),
        0x75 => mask(W, u16, B.u(u16, a) == B.u(u16, b)),
        0x76 => mask(W, u32, B.u(u32, a) == B.u(u32, b)),
        // Shifts by a register or memory count (its low 64 bits).
        0xd1 => shift(W, u16, a, lo64(b), .srl),
        0xd2 => shift(W, u32, a, lo64(b), .srl),
        0xd3 => shift(W, u64, a, lo64(b), .srl),
        0xe1 => shift(W, u16, a, lo64(b), .sra),
        0xe2 => shift(W, u32, a, lo64(b), .sra),
        0xf1 => shift(W, u16, a, lo64(b), .sll),
        0xf2 => shift(W, u32, a, lo64(b), .sll),
        0xf3 => shift(W, u64, a, lo64(b), .sll),
        // Arithmetic.
        0xd4 => bits(W, B.u(u64, a) +% B.u(u64, b)),
        0xd5 => bits(W, B.u(u16, a) *% B.u(u16, b)),
        0xd8 => bits(W, B.u(u8, a) -| B.u(u8, b)),
        0xd9 => bits(W, B.u(u16, a) -| B.u(u16, b)),
        0xda => bits(W, @min(B.u(u8, a), B.u(u8, b))),
        0xdb => a & b,
        0xdc => bits(W, B.u(u8, a) +| B.u(u8, b)),
        0xdd => bits(W, B.u(u16, a) +| B.u(u16, b)),
        0xde => bits(W, @max(B.u(u8, a), B.u(u8, b))),
        0xdf => ~a & b,
        0xe0 => avg(W, u8, a, b),
        0xe3 => avg(W, u16, a, b),
        0xe4 => mulhi(W, u16, a, b),
        0xe5 => mulhi(W, i16, a, b),
        0xe8 => bits(W, B.s(i8, a) -| B.s(i8, b)),
        0xe9 => bits(W, B.s(i16, a) -| B.s(i16, b)),
        0xea => bits(W, @min(B.s(i16, a), B.s(i16, b))),
        0xeb => a | b,
        0xec => bits(W, B.s(i8, a) +| B.s(i8, b)),
        0xed => bits(W, B.s(i16, a) +| B.s(i16, b)),
        0xee => bits(W, @max(B.s(i16, a), B.s(i16, b))),
        0xef => a ^ b,
        0xf4 => blk: {
            // PMULUDQ: the even dwords' full products.
            const x32 = B.u(u32, a);
            const y32 = B.u(u32, b);
            var r: V(W, u64) = undefined;
            inline for (0..@bitSizeOf(W) / 64) |k| r[k] = @as(u64, x32[2 * k]) * y32[2 * k];
            break :blk bits(W, r);
        },
        0xf5 => blk: {
            // PMADDWD.
            const x16 = B.s(i16, a);
            const y16 = B.s(i16, b);
            var r: V(W, i32) = undefined;
            inline for (0..@bitSizeOf(W) / 32) |k| {
                const p0 = @as(i32, x16[2 * k]) * y16[2 * k];
                const p1 = @as(i32, x16[2 * k + 1]) * y16[2 * k + 1];
                r[k] = p0 +% p1;
            }
            break :blk bits(W, r);
        },
        0xf6 => blk: {
            // PSADBW: sums of absolute differences, per 8 bytes.
            const x8 = B.u(u8, a);
            const y8 = B.u(u8, b);
            var r: V(W, u64) = @splat(0);
            inline for (0..@bitSizeOf(W) / 64) |k| {
                var sum: u64 = 0;
                inline for (0..8) |j| {
                    const p = x8[8 * k + j];
                    const q = y8[8 * k + j];
                    sum += if (p > q) p - q else q - p;
                }
                r[k] = sum;
            }
            break :blk bits(W, r);
        },
        0xf8 => bits(W, B.u(u8, a) -% B.u(u8, b)),
        0xf9 => bits(W, B.u(u16, a) -% B.u(u16, b)),
        0xfa => bits(W, B.u(u32, a) -% B.u(u32, b)),
        0xfb => bits(W, B.u(u64, a) -% B.u(u64, b)),
        0xfc => bits(W, B.u(u8, a) +% B.u(u8, b)),
        0xfd => bits(W, B.u(u16, a) +% B.u(u16, b)),
        0xfe => bits(W, B.u(u32, a) +% B.u(u32, b)),
        else => null,
    };
}

fn unpack(comptime W: type, comptime T: type, a: W, b: W, high: bool) W {
    const n = @bitSizeOf(W) / @bitSizeOf(T);
    const x: [n]T = @bitCast(a);
    const y: [n]T = @bitCast(b);
    var r: [n]T = undefined;
    const base: usize = if (high) n / 2 else 0;
    for (0..n / 2) |k| {
        r[2 * k] = x[base + k];
        r[2 * k + 1] = y[base + k];
    }
    return @bitCast(r);
}

fn pack(comptime W: type, comptime From: type, comptime To: type, a: W, b: W) W {
    const n = @bitSizeOf(W) / @bitSizeOf(From);
    const x: [n]From = @bitCast(a);
    const y: [n]From = @bitCast(b);
    var r: [2 * n]To = undefined;
    inline for (0..n) |k| {
        r[k] = sat(From, To, x[k]);
        r[n + k] = sat(From, To, y[k]);
    }
    return @bitCast(r);
}

fn sat(comptime From: type, comptime To: type, v: From) To {
    return @intCast(std.math.clamp(v, std.math.minInt(To), std.math.maxInt(To)));
}

fn avg(comptime W: type, comptime T: type, a: W, b: W) W {
    const n = @bitSizeOf(W) / @bitSizeOf(T);
    const x: [n]T = @bitCast(a);
    const y: [n]T = @bitCast(b);
    var r: [n]T = undefined;
    inline for (0..n) |k| r[k] = @intCast((@as(u32, x[k]) + y[k] + 1) >> 1);
    return @bitCast(r);
}

fn mulhi(comptime W: type, comptime T: type, a: W, b: W) W {
    const n = @bitSizeOf(W) / 16;
    const x: [n]T = @bitCast(a);
    const y: [n]T = @bitCast(b);
    var r: [n]u16 = undefined;
    inline for (0..n) |k| {
        const prod: i64 = @as(i64, x[k]) * @as(i64, y[k]);
        r[k] = @truncate(@as(u64, @bitCast(prod)) >> 16);
    }
    return @bitCast(r);
}

// ------------------------------------------------------------ tests

const testing = std.testing;
const decode = @import("decode.zig");

/// A long-mode Exec for the tests here and in x87.zig, until T0 runs long
/// mode: flat memory at `base`, and the operand's address computed as
/// T0's is, RIP-relative included.
pub const TestX64 = struct {
    c: *cpu.Cpu64,
    i: *const decode.Inst64,
    addr: u64 = 0,
    base: u64,
    mem: []u8,
    /// The vector the instruction raised, or 14 for a page fault.
    vector: ?u8 = null,

    pub const Trap = error{Trap};

    pub fn exc(x: *TestX64, v: u8) Trap {
        x.vector = v;
        return error.Trap;
    }

    fn bytes(x: *TestX64, va: u64, n: usize) Trap![]u8 {
        if (va < x.base or va - x.base + n > x.mem.len) return x.exc(cpu.vec_pf);
        const o: usize = @intCast(va - x.base);
        return x.mem[o..][0..n];
    }

    pub fn load(x: *TestX64, va: u64, size: u8) Trap!u64 {
        var buf: [8]u8 = @splat(0);
        @memcpy(buf[0..size], try x.bytes(va, size));
        return std.mem.readInt(u64, &buf, .little);
    }

    pub fn store(x: *TestX64, va: u64, size: u8, v: u64) Trap!void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, v, .little);
        @memcpy(try x.bytes(va, size), buf[0..size]);
    }

    pub fn load64(x: *TestX64, va: u64) Trap!u64 {
        return x.load(va, 8);
    }

    pub fn store64(x: *TestX64, va: u64, v: u64) Trap!void {
        return x.store(va, 8, v);
    }

    pub fn loadBytes(x: *TestX64, va: u64, buf: []u8) Trap!void {
        @memcpy(buf, try x.bytes(va, buf.len));
    }

    pub fn storeBytes(x: *TestX64, va: u64, buf: []const u8) Trap!void {
        @memcpy(try x.bytes(va, buf.len), buf);
    }

    pub fn readReg(x: *const TestX64, n: u4, size: u8) u64 {
        const v = x.c.r[n];
        return if (size == 8) v else v & ((@as(u64, 1) << @intCast(8 * size)) - 1);
    }

    pub fn writeReg(x: *TestX64, n: u4, size: u8, v: u64) void {
        const r = &x.c.r[n];
        switch (size) {
            8 => r.* = v,
            4 => r.* = @as(u32, @truncate(v)),
            else => {
                const m = (@as(u64, 1) << @intCast(8 * size)) - 1;
                r.* = (r.* & ~m) | (v & m);
            },
        }
    }

    /// Runs `i` (an sse or x87 instruction) at RIP, and moves RIP past it
    /// unless it raised something.
    pub fn run(c: *cpu.Cpu64, mem: []u8, base: u64, i: decode.Inst64) ?u8 {
        var x: TestX64 = .{ .c = c, .i = &i, .base = base, .mem = mem };
        if (i.mem) {
            var a: u64 = i.disp;
            if (i.rip_rel) a +%= c.rip + i.len;
            if (i.base != decode.no_reg64) a +%= c.r[i.base];
            if (i.index != decode.no_reg64) a +%= c.r[i.index] << i.scale;
            if (i.addr32) a &= 0xffff_ffff;
            if (i.seg == .fs) a +%= c.fs_base;
            if (i.seg == .gs) a +%= c.gs_base;
            x.addr = a;
        }
        const r = if (i.op == .x87) x87.exec(&x) else exec(&x);
        r catch return x.vector;
        c.rip += i.len;
        return null;
    }
};

/// A long-mode 0F xx instruction for the tests: `modrm` with REX's bits,
/// a register form unless `mem`.
fn inst(op: u8, pfx: Pfx, rex: u4, modrm: u8) decode.Inst64 {
    return .{
        .op = .sse,
        .entry = 0,
        .opcode = 0x0f00 | @as(u16, op),
        .len = 5,
        .size = if (rex & 8 != 0) 8 else 4,
        .opsize = pfx == .p66,
        .rep = switch (pfx) {
            .f3 => .rep,
            .f2 => .repne,
            else => .none,
        },
        .rex = decode.Rex.of(0x40 | @as(u8, rex)),
        .modrm = modrm,
    };
}

/// The same with a memory operand at `addr` (as a disp32, no base).
fn instMem(op: u8, pfx: Pfx, rex: u4, reg: u3, addr: u64) decode.Inst64 {
    var i = inst(op, pfx, rex, 0x04 | @as(u8, reg) << 3);
    i.mem = true;
    i.disp = addr;
    return i;
}

const test_base = 0x10000;

fn f32bits(v: f32) u32 {
    return @bitCast(v);
}

fn f64bits(v: f64) u64 {
    return @bitCast(v);
}

test "long mode: XMM8-15 through REX.R and REX.B" {
    var c: cpu.Cpu64 = .{ .rip = test_base };
    var mem: [64]u8 align(16) = @splat(0);
    c.xmm[12] = 0x1234_5678_9abc_def0_0fed_cba9_8765_4321;
    // movaps %xmm12, %xmm9 (REX.R, REX.B)
    try testing.expectEqual(null, TestX64.run(&c, &mem, test_base, inst(0x28, .none, 0b0101, 0xc0 | 1 << 3 | 4)));
    try testing.expectEqual(c.xmm[12], c.xmm[9]);
    try testing.expectEqual(@as(u128, 0), c.xmm[1]);
    try testing.expectEqual(@as(u128, 0), c.xmm[4]);
    // addsd (mem), %xmm15
    c.xmm[15] = f64bits(1.5);
    std.mem.writeInt(u64, mem[16..24], f64bits(2.25), .little);
    try testing.expectEqual(null, TestX64.run(&c, &mem, test_base, instMem(0x58, .f2, 0b0100, 7, test_base + 16)));
    try testing.expectEqual(@as(u128, f64bits(3.75)), c.xmm[15]);
    // psrlq $4, %xmm9: REX.B picks XMM9, and REX.R doesn't change /2.
    var i = inst(0x73, .p66, 0b0101, 0xc0 | 2 << 3 | 1);
    i.imm = 4;
    try testing.expectEqual(null, TestX64.run(&c, &mem, test_base, i));
    try testing.expectEqual(c.xmm[12] >> 4 & ~(@as(u128, 0xf) << 124 | @as(u128, 0xf) << 60), c.xmm[9]);
}

test "long mode: a RIP-relative operand is the next instruction's RIP plus disp" {
    var c: cpu.Cpu64 = .{ .rip = test_base + 0x20 };
    var mem: [64]u8 align(16) = @splat(0);
    std.mem.writeInt(u64, mem[0x38..0x40], 0x1122_3344_5566_7788, .little);
    // movsd 0x13(%rip), %xmm8, 5 bytes long at 0x20: 0x20 + 5 + 0x13 = 0x38.
    var i = inst(0x10, .f2, 0b0100, 0x05);
    i.mem = true;
    i.rip_rel = true;
    i.disp = 0x13;
    try testing.expectEqual(null, TestX64.run(&c, &mem, test_base, i));
    try testing.expectEqual(@as(u128, 0x1122_3344_5566_7788), c.xmm[8]);
}

test "long mode: MOVD and MOVQ with REX.W" {
    var c: cpu.Cpu64 = .{ .rip = test_base };
    var mem: [64]u8 align(16) = @splat(0);
    c.r[11] = 0x8877_6655_4433_2211;
    c.xmm[10] = std.math.maxInt(u128);
    // movq %r11, %xmm10 (66 REX.WRB 0F 6E)
    try testing.expectEqual(null, TestX64.run(&c, &mem, test_base, inst(0x6e, .p66, 0b1101, 0xc0 | 2 << 3 | 3)));
    try testing.expectEqual(@as(u128, 0x8877_6655_4433_2211), c.xmm[10]);
    // movd %r11d, %xmm10: 32 bits, zero-extended.
    try testing.expectEqual(null, TestX64.run(&c, &mem, test_base, inst(0x6e, .p66, 0b0101, 0xc0 | 2 << 3 | 3)));
    try testing.expectEqual(@as(u128, 0x4433_2211), c.xmm[10]);
    // movq %xmm3, %r9 (66 REX.WB 0F 7E), then movd %xmm3, %r9d clears the
    // upper half.
    c.xmm[3] = 0xdead_beef_0000_0000_cafe_f00d_1234_5678;
    try testing.expectEqual(null, TestX64.run(&c, &mem, test_base, inst(0x7e, .p66, 0b1001, 0xc0 | 3 << 3 | 1)));
    try testing.expectEqual(@as(u64, 0xcafe_f00d_1234_5678), c.r[9]);
    try testing.expectEqual(null, TestX64.run(&c, &mem, test_base, inst(0x7e, .p66, 0b0001, 0xc0 | 3 << 3 | 1)));
    try testing.expectEqual(@as(u64, 0x1234_5678), c.r[9]);
    // movq %xmm3, (mem) with REX.W: 8 bytes.
    try testing.expectEqual(null, TestX64.run(&c, &mem, test_base, instMem(0x7e, .p66, 0b1000, 3, test_base + 8)));
    try testing.expectEqual(@as(u64, 0xcafe_f00d_1234_5678), std.mem.readInt(u64, mem[8..16], .little));
    // movq %rax, %mm1 (REX.WR 0F 6E): MMX registers ignore REX.R.
    c.r[0] = 0x0102_0304_0506_0708;
    try testing.expectEqual(null, TestX64.run(&c, &mem, test_base, inst(0x6e, .none, 0b1100, 0xc0 | 1 << 3 | 0)));
    try testing.expectEqual(@as(u64, 0x0102_0304_0506_0708), c.fpu.st[1].signif);
    // movq %mm1, %r10 (REX.WB 0F 7E)
    try testing.expectEqual(null, TestX64.run(&c, &mem, test_base, inst(0x7e, .none, 0b1001, 0xc0 | 1 << 3 | 2)));
    try testing.expectEqual(@as(u64, 0x0102_0304_0506_0708), c.r[10]);
    // pmovmskb %xmm10, %r12d writes all 64 bits.
    c.r[12] = std.math.maxInt(u64);
    c.xmm[10] = 0x80;
    try testing.expectEqual(null, TestX64.run(&c, &mem, test_base, inst(0xd7, .p66, 0b0101, 0xc0 | 4 << 3 | 2)));
    try testing.expectEqual(@as(u64, 1), c.r[12]);
}

test "long mode: 64-bit integer conversions" {
    var c: cpu.Cpu64 = .{ .rip = test_base };
    var mem: [64]u8 align(16) = @splat(0);
    // cvtsi2sd %rax, %xmm1: 2^53 + 1 rounds to even, inexact.
    c.r[0] = (1 << 53) + 1;
    c.xmm[1] = @as(u128, 0xaaaa) << 64;
    try testing.expectEqual(null, TestX64.run(&c, &mem, test_base, inst(0x2a, .f2, 0b1000, 0xc0 | 1 << 3 | 0)));
    try testing.expectEqual(@as(u128, 0xaaaa) << 64 | f64bits(9007199254740992.0), c.xmm[1]);
    try testing.expect(c.mxcsr & fp.PE != 0);
    // cvtsi2ss (mem), %xmm2 with REX.W: an i64 from memory.
    std.mem.writeInt(i64, mem[0..8], -(1 << 40), .little);
    try testing.expectEqual(null, TestX64.run(&c, &mem, test_base, instMem(0x2a, .f3, 0b1000, 2, test_base)));
    try testing.expectEqual(@as(u128, f32bits(-1099511627776.0)), c.xmm[2]);
    // cvttsd2si %xmm3, %r8: truncates toward zero.
    c.mxcsr = 0x1f80;
    c.xmm[3] = f64bits(-2.75e12);
    try testing.expectEqual(null, TestX64.run(&c, &mem, test_base, inst(0x2c, .f2, 0b1100, 0xc0 | 0 << 3 | 3)));
    try testing.expectEqual(@as(u64, @bitCast(@as(i64, -2_750_000_000_000))), c.r[8]);
    // cvtsd2si %xmm3, %r8 out of range: the 64-bit integer indefinite, and IE.
    c.xmm[3] = f64bits(1e19);
    try testing.expectEqual(null, TestX64.run(&c, &mem, test_base, inst(0x2d, .f2, 0b1100, 0xc0 | 0 << 3 | 3)));
    try testing.expectEqual(@as(u64, 1 << 63), c.r[8]);
    try testing.expect(c.mxcsr & fp.IE != 0);
    // cvtss2si %xmm4, %r8d: 32 bits, zero-extended; round to nearest even.
    c.r[8] = std.math.maxInt(u64);
    c.xmm[4] = f32bits(-2.5);
    try testing.expectEqual(null, TestX64.run(&c, &mem, test_base, inst(0x2d, .f3, 0b0100, 0xc0 | 0 << 3 | 4)));
    try testing.expectEqual(@as(u64, @as(u32, @bitCast(@as(i32, -2)))), c.r[8]);
    // An unmasked IE leaves the destination as it was.
    c.mxcsr = 0x1f80 & ~@as(u32, 1 << 7);
    c.r[8] = 7;
    c.xmm[3] = f64bits(std.math.inf(f64));
    try testing.expectEqual(@as(?u8, cpu.vec_xm), TestX64.run(&c, &mem, test_base, inst(0x2c, .f2, 0b1100, 0xc0 | 0 << 3 | 3)));
    try testing.expectEqual(@as(u64, 7), c.r[8]);
}

test "long mode: FXSAVE64 and FXRSTOR64 keep XMM8-15 and 64-bit pointers" {
    var c: cpu.Cpu64 = .{ .rip = test_base };
    var mem: [1024]u8 align(16) = @splat(0xcc);
    for (&c.xmm, 0..) |*v, k| v.* = @as(u128, k + 1) * 0x0101_0101_0101_0101_0101_0101_0101_0101;
    c.fpu.fip = 0x7fff_1234_5678;
    c.fpu.fdp = 0x0000_7fff_0000_9abc;
    c.mxcsr = 0x1fa0;
    // fxsave64 (mem): REX.W, 0F AE /0.
    var save = instMem(0xae, .none, 0b1000, 0, test_base);
    try testing.expectEqual(null, TestX64.run(&c, &mem, test_base, save));
    try testing.expectEqual(@as(u64, 0x7fff_1234_5678), std.mem.readInt(u64, mem[8..16], .little));
    try testing.expectEqual(@as(u64, 0x7fff_0000_9abc), std.mem.readInt(u64, mem[16..24], .little));
    try testing.expectEqual(c.xmm[15], std.mem.readInt(u128, mem[400..416], .little));
    // Nothing past the XMM registers.
    try testing.expectEqual(@as(u8, 0xcc), mem[416]);
    // Restore into a clean CPU with fxrstor64, REX.R set (still /1).
    var d: cpu.Cpu64 = .{ .rip = test_base };
    var rst = instMem(0xae, .none, 0b1100, 1, test_base);
    try testing.expectEqual(null, TestX64.run(&d, &mem, test_base, rst));
    try testing.expectEqual(c.xmm, d.xmm);
    try testing.expectEqual(c.fpu.fip, d.fpu.fip);
    try testing.expectEqual(c.fpu.fdp, d.fpu.fdp);
    try testing.expectEqual(c.mxcsr, d.mxcsr);
    // fxsave without REX.W keeps 32-bit offsets and no selectors.
    save.rex.w = 0;
    try testing.expectEqual(null, TestX64.run(&c, &mem, test_base, save));
    try testing.expectEqual(@as(u64, 0x1234_5678), std.mem.readInt(u64, mem[8..16], .little));
    try testing.expectEqual(@as(u64, 0x9abc), std.mem.readInt(u64, mem[16..24], .little));
    try testing.expectEqual(c.xmm[8], std.mem.readInt(u128, mem[288..304], .little));
    rst.rex.w = 0;
    try testing.expectEqual(null, TestX64.run(&d, &mem, test_base, rst));
    try testing.expectEqual(@as(u64, 0x1234_5678), d.fpu.fip);
    // Misaligned: #GP.
    try testing.expectEqual(@as(?u8, cpu.vec_gp), TestX64.run(&c, &mem, test_base, instMem(0xae, .none, 0b1000, 0, test_base + 8)));
}

test "long mode: MASKMOVDQU stores to (RDI), or (EDI) with 67" {
    var c: cpu.Cpu64 = .{ .rip = test_base };
    var mem: [64]u8 align(16) = @splat(0);
    c.r[7] = 0xffff_ffff_0000_0000 | (test_base + 16);
    c.xmm[9] = 0x0807_0605_0403_0201;
    c.xmm[10] = 0x80_00_80_00;
    // maskmovdqu %xmm10, %xmm9 with addr32: EDI only.
    var i = inst(0xf7, .p66, 0b0101, 0xc0 | 1 << 3 | 2);
    i.addr32 = true;
    try testing.expectEqual(null, TestX64.run(&c, &mem, test_base, i));
    try testing.expectEqualSlices(u8, &.{ 0, 2, 0, 4, 0 }, mem[16..21]);
    // Without 67, RDI's upper half is outside memory.
    i.addr32 = false;
    try testing.expectEqual(@as(?u8, cpu.vec_pf), TestX64.run(&c, &mem, test_base, i));
}
