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

const std = @import("std");
const cpu = @import("cpu.zig");
const fp = @import("../softfloat.zig");
const x87 = @import("x87.zig");
const flags = @import("flags.zig");

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
    if (!x.i.mem) return getMM(x, x.i.rm());
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
    const i = &x.i;
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
            x.writeReg(i.reg(), 4, m);
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
            if (p != .none or !i.mem) return ud(x);
            try x.store(x.addr, 4, x.readReg(i.reg(), 4));
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
    const i = &x.i;
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
    const i = &x.i;
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
            const v: i32 = @bitCast(if (i.mem) try x.load(x.addr, 4) else x.readReg(i.rm(), 4));
            if (p == .f3) {
                const r = fp.fromI32(u32, &e, v);
                try raise(x, &e);
                d.* = (d.* & ~@as(u128, 0xffff_ffff)) | r;
            } else {
                d.* = join(fp.fromI32(u64, &e, v), hi64(d.*));
            }
        },
    }
}

/// CVTTPS2PI, CVTPS2PI, CVTTPD2PI, CVTPD2PI, CVT(T)SS2SI, and CVT(T)SD2SI.
fn cvt2c(x: anytype, p: Pfx, trunc: bool) !void {
    const i = &x.i;
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
            setMM(x, i.reg(), @as(u64, @as(u32, @bitCast(r[1]))) << 32 | @as(u32, @bitCast(r[0])));
        },
        .f3 => {
            const v = try xsrc(x, 4, false);
            const r = fp.toI32(u32, &e, @truncate(v), trunc);
            try raise(x, &e);
            x.writeReg(i.reg(), 4, @bitCast(r));
        },
        .f2 => {
            const v = try xsrc(x, 8, false);
            const r = fp.toI32(u64, &e, lo64(v), trunc);
            try raise(x, &e);
            x.writeReg(i.reg(), 4, @bitCast(r));
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
    const i = &x.i;
    switch (i.reg()) {
        0 => return fxsave(x),
        1 => return fxrstor(x),
        2 => {
            const v = try x.load(x.addr, 4);
            if (v & mxcsr_reserved != 0) return x.exc(cpu.vec_gp);
            x.c.mxcsr = v;
        },
        3 => try x.store(x.addr, 4, x.c.mxcsr),
        else => return ud(x),
    }
}

fn fxsave(x: anytype) !void {
    try alignCheck(x);
    const p = &x.c.fpu;
    var b: [288]u8 = @splat(0);
    std.mem.writeInt(u16, b[0..2], p.cw, .little);
    std.mem.writeInt(u16, b[2..4], x87.statusWord(p), .little);
    b[4] = p.tag;
    std.mem.writeInt(u16, b[6..8], p.fop, .little);
    std.mem.writeInt(u64, b[8..16], p.fip & 0xffff_ffff_ffff, .little);
    std.mem.writeInt(u64, b[16..24], p.fdp & 0xffff_ffff_ffff, .little);
    std.mem.writeInt(u32, b[24..28], x.c.mxcsr, .little);
    std.mem.writeInt(u32, b[28..32], 0xffff, .little);
    for (0..8) |k| std.mem.writeInt(u80, b[32 + 16 * k ..][0..10], x87.st(p, @intCast(k)).toBits(), .little);
    for (0..8) |k| std.mem.writeInt(u128, b[160 + 16 * k ..][0..16], x.c.xmm[k], .little);
    try x.storeBytes(x.addr, &b);
}

fn fxrstor(x: anytype) !void {
    try alignCheck(x);
    var b: [288]u8 = undefined;
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
    p.fip = std.mem.readInt(u64, b[8..16], .little) & 0xffff_ffff_ffff;
    p.fdp = std.mem.readInt(u64, b[16..24], .little) & 0xffff_ffff_ffff;
    x.c.mxcsr = mx;
    for (0..8) |k| p.st[x87.phys(p, @intCast(k))] = .fromBits(std.mem.readInt(u80, b[32 + 16 * k ..][0..10], .little));
    for (0..8) |k| x.c.xmm[k] = std.mem.readInt(u128, b[160 + 16 * k ..][0..16], .little);
}

// ------------------------------------------------------------ integer SIMD

/// MMX (no prefix) or SSE2 (66) integer instructions and their moves.
fn integer(x: anytype, p: Pfx, op: u8) !void {
    const i = &x.i;
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
                xreg(x).* = getMM(x, i.rm());
                return;
            },
            .f2 => {
                // MOVDQ2Q.
                if (i.mem) return ud(x);
                try mmx(x);
                setMM(x, i.reg(), lo64(x.c.xmm[i.rm()]));
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
        0x71, 0x72 => !i.mem and (i.reg() == 2 or i.reg() == 4 or i.reg() == 6),
        0x73 => !i.mem and (i.reg() == 2 or i.reg() == 6),
        0x6e, 0x7e, 0x6f, 0x7f, 0x70, 0xc4 => true,
        else => binop(u64, op, 0, 0) != null,
    };
}

/// W is u64 for MMX and u128 for XMM.
fn integerOp(x: anytype, comptime W: type, op: u8) !void {
    const i = &x.i;
    const is_mmx = W == u64;
    // #UD comes before the MMX transition, which waits and resets TOP.
    if (is_mmx and !mmxValid(i, op)) return ud(x);
    if (is_mmx) try mmx(x);
    const S = struct {
        fn src(xx: anytype) !W {
            return if (is_mmx) try msrc(xx) else try xsrc(xx, 16, true);
        }
        fn get(xx: anytype) W {
            return if (is_mmx) getMM(xx, xx.i.reg()) else xx.c.xmm[xx.i.reg()];
        }
        fn set(xx: anytype, v: W) void {
            if (is_mmx) setMM(xx, xx.i.reg(), v) else xx.c.xmm[xx.i.reg()] = v;
        }
        fn rmGet(xx: anytype) W {
            return if (is_mmx) getMM(xx, xx.i.rm()) else xx.c.xmm[xx.i.rm()];
        }
        fn rmSet(xx: anytype, v: W) void {
            if (is_mmx) setMM(xx, xx.i.rm(), v) else xx.c.xmm[xx.i.rm()] = v;
        }
    };
    switch (op) {
        // Moves.
        0x6e => {
            const v = if (i.mem) try x.load(x.addr, 4) else x.readReg(i.rm(), 4);
            S.set(x, v);
            return;
        },
        0x7e => {
            const v: u32 = @truncate(S.get(x));
            if (i.mem) try x.store(x.addr, 4, v) else x.writeReg(i.rm(), 4, v);
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
            x.writeReg(i.reg(), 4, m);
            return;
        },
        0xc5 => {
            if (i.mem) return ud(x);
            const n = @bitSizeOf(W) / 16;
            const v: [n]u16 = @bitCast(S.rmGet(x));
            x.writeReg(i.reg(), 4, v[@as(usize, @truncate(i.imm)) % n]);
            return;
        },
        0xc4 => {
            const w: u16 = @truncate(if (i.mem) try x.load(x.addr, 2) else x.readReg(i.rm(), 4));
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
                0x71 => switch (i.reg()) {
                    2 => shift(W, u16, v, c, .srl),
                    4 => shift(W, u16, v, c, .sra),
                    6 => shift(W, u16, v, c, .sll),
                    else => return ud(x),
                },
                0x72 => switch (i.reg()) {
                    2 => shift(W, u32, v, c, .srl),
                    4 => shift(W, u32, v, c, .sra),
                    6 => shift(W, u32, v, c, .sll),
                    else => return ud(x),
                },
                else => switch (i.reg()) {
                    2 => shift(W, u64, v, c, .srl),
                    6 => shift(W, u64, v, c, .sll),
                    3, 7 => blk: {
                        // PSRLDQ and PSLLDQ: bytes, XMM only.
                        if (is_mmx) return ud(x);
                        if (c >= 16) break :blk 0;
                        const n: u7 = @intCast(c * 8);
                        break :blk if (i.reg() == 3) v >> n else v << n;
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
            const s = @intFromEnum(i.seg);
            if (s >= 4 and x.c.seg_null & (@as(u8, 1) << @intCast(s)) != 0) return x.exc(cpu.vec_gp);
            var a = x.c.r[7];
            if (i.addr16) a &= 0xffff;
            a +%= x.c.seg_base[s];
            const n = @bitSizeOf(W) / 8;
            inline for (0..n) |k| {
                if (m[k] & 0x80 != 0) try x.store(a +% @as(u32, @intCast(k)), 1, v[k]);
            }
            return;
        },
        else => {},
    }
    const a = S.get(x);
    const b = try S.src(x);
    S.set(x, binop(W, op, a, b) orelse return ud(x));
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
