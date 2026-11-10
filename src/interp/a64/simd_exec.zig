//! FP and AdvSIMD execution for ha64's T0.
//!
//! `handlers[i]` runs simd_decode.zig's kind `decode.simd_base + i`, with
//! the same signature as exec.zig's handlers. Its state is exec.Cpu's `v`,
//! `fpcr`, and `fpsr`; exec.undef faults an instruction with EC 0.
//!
//! FP arithmetic goes through src/interp/softfloat.zig with Arm's rules
//! (`env`): FPCR's RMode, FZ, and DN; tininess before rounding; the
//! positive default NaN; signaling NaNs before quiet ones. So results and
//! FPSR's cumulative flags are the same bits on every host. FPCR.AHP
//! (alternative half precision) isn't modeled: FCVT to and from half is
//! always IEEE.

const std = @import("std");
const exec = @import("exec.zig");
const dec = @import("decode.zig");
const sd = @import("simd_decode.zig");
const sf = @import("../softfloat.zig");

const K = sd.Kind;
const Op = dec.Op;
const Machine = exec.Machine;
const Next = exec.Next;
const Cpu = exec.Cpu;

comptime {
    std.debug.assert(@import("builtin").cpu.arch.endian() == .little);
}

pub const handlers = blk: {
    @setEvalBranchQuota(200000);
    const fields = @typeInfo(K).@"enum".fields;
    var h: [fields.len]exec.Handler = undefined;
    for (fields, 0..) |f, i| {
        std.debug.assert(f.value == i);
        h[i] = handlerFor(@enumFromInt(f.value));
    }
    break :blk h;
};

fn handlerFor(comptime k: K) exec.Handler {
    return &struct {
        fn f(m: *Machine, o: *const Op, pc: u64) Next {
            return run(k, m, o, pc);
        }
    }.f;
}

/// FPSR.QC, the cumulative saturation flag.
const QC: u32 = 1 << 27;

// ---------------------------------------------------------------- lanes

fn UInt(comptime s: comptime_int) type {
    return std.meta.Int(.unsigned, 8 << s);
}

fn Signed(comptime T: type) type {
    return std.meta.Int(.signed, @bitSizeOf(T));
}

fn Wide(comptime T: type) type {
    return std.meta.Int(.unsigned, 2 * @bitSizeOf(T));
}

inline fn lane(v: u128, comptime T: type, i: usize) T {
    return @truncate(v >> @intCast(i * @bitSizeOf(T)));
}

inline fn put(r: *u128, comptime T: type, i: usize, x: T) void {
    r.* |= @as(u128, x) << @intCast(i * @bitSizeOf(T));
}

inline fn setLane(r: *u128, comptime T: type, i: usize, x: T) void {
    const sh: u7 = @intCast(i * @bitSizeOf(T));
    r.* = (r.* & ~(@as(u128, std.math.maxInt(T)) << sh)) | @as(u128, x) << sh;
}

inline fn sx(comptime T: type, a: T) i128 {
    return @as(Signed(T), @bitCast(a));
}

inline fn zx(comptime T: type, a: T) i128 {
    return a;
}

fn satS(comptime T: type, v: i128, qc: *bool) T {
    const S = Signed(T);
    if (v > std.math.maxInt(S)) {
        qc.* = true;
        return std.math.maxInt(S);
    }
    if (v < std.math.minInt(S)) {
        qc.* = true;
        return @bitCast(@as(S, std.math.minInt(S)));
    }
    return @bitCast(@as(S, @intCast(v)));
}

fn satU(comptime T: type, v: i128, qc: *bool) T {
    if (v > std.math.maxInt(T)) {
        qc.* = true;
        return std.math.maxInt(T);
    }
    if (v < 0) {
        qc.* = true;
        return 0;
    }
    return @intCast(v);
}

inline fn ones(comptime T: type, b: bool) T {
    return if (b) std.math.maxInt(T) else 0;
}

/// The number of elements of type T an op works on.
inline fn count(o: *const Op, comptime T: type) usize {
    if (o.sh & sd.SCALAR != 0) return 1;
    return (if (o.sh & sd.Q != 0) @as(usize, 16) else 8) / @sizeOf(T);
}

/// The register's bits an op of shape `sh` keeps: 64 or 128.
inline fn mask(o: *const Op) u128 {
    return if (o.sh & sd.Q != 0) std.math.maxInt(u128) else std.math.maxInt(u64);
}

fn pmul8(a: u8, b: u8) u16 {
    var r: u16 = 0;
    for (0..8) |i| {
        if (b >> @intCast(i) & 1 == 1) r ^= @as(u16, a) << @intCast(i);
    }
    return r;
}

// ---------------------------------------------------------------- dispatch

fn run(comptime k: K, m: *Machine, o: *const Op, pc: u64) Next {
    const cpu = m.cpu;
    var qc = false;
    switch (k) {
        // three same, and by element
        .shadd, .uhadd, .srhadd, .urhadd, .shsub, .uhsub, .sqadd, .uqadd, .sqsub, .uqsub, .cmgt, .cmhi, .cmge, .cmhs, .cmeq, .cmtst, .sshl, .ushl, .sqshl, .uqshl, .srshl, .urshl, .sqrshl, .uqrshl, .smax, .umax, .smin, .umin, .sabd, .uabd, .saba, .uaba, .add, .sub, .mla, .mls, .mul, .pmul, .sqdmulh, .sqrdmulh => ew(k, k, false, cpu, o, &qc),
        .mul_e => ew(k, .mul, true, cpu, o, &qc),
        .mla_e => ew(k, .mla, true, cpu, o, &qc),
        .mls_e => ew(k, .mls, true, cpu, o, &qc),
        .sqdmulh_e => ew(k, .sqdmulh, true, cpu, o, &qc),
        .sqrdmulh_e => ew(k, .sqrdmulh, true, cpu, o, &qc),
        // two-register misc, elementwise
        .suqadd, .usqadd, .cls, .clz, .cnt, .not, .rbit, .sqabs, .sqneg, .abs, .neg, .cmgt0, .cmge0, .cmeq0, .cmle0, .cmlt0 => ew(k, k, false, cpu, o, &qc),
        .rev64, .rev32, .rev16 => rev(k, cpu, o),
        // shift by immediate, elementwise
        .sshr, .ushr, .ssra, .usra, .srshr, .urshr, .srsra, .ursra, .sri, .shl, .sli, .sqshlu, .sqshl_i, .uqshl_i => ew(k, k, false, cpu, o, &qc),
        .smaxp, .umaxp, .sminp, .uminp, .addp => pairwise(k, cpu, o),
        .and_v, .bic_v, .orr_v, .orn_v, .eor_v, .bsl, .bit, .bif, .movi, .orr_vi, .bic_vi => logical(k, cpu, o),
        // long and wide
        .saddl, .uaddl, .saddw, .uaddw, .ssubl, .usubl, .ssubw, .usubw, .sabal, .uabal, .sabdl, .uabdl, .smlal, .umlal, .smlsl, .umlsl, .smull, .umull, .sqdmlal, .sqdmlsl, .sqdmull, .pmull, .shll, .sshll, .ushll => long(k, k, false, cpu, o, &qc),
        .smull_e => long(k, .smull, true, cpu, o, &qc),
        .umull_e => long(k, .umull, true, cpu, o, &qc),
        .smlal_e => long(k, .smlal, true, cpu, o, &qc),
        .umlal_e => long(k, .umlal, true, cpu, o, &qc),
        .smlsl_e => long(k, .smlsl, true, cpu, o, &qc),
        .umlsl_e => long(k, .umlsl, true, cpu, o, &qc),
        .sqdmull_e => long(k, .sqdmull, true, cpu, o, &qc),
        .sqdmlal_e => long(k, .sqdmlal, true, cpu, o, &qc),
        .sqdmlsl_e => long(k, .sqdmlsl, true, cpu, o, &qc),
        .saddlp, .uaddlp, .sadalp, .uadalp => addlp(k, cpu, o),
        // narrowing
        .addhn, .raddhn, .subhn, .rsubhn, .xtn, .sqxtn, .uqxtn, .sqxtun, .shrn, .rshrn, .sqshrn, .uqshrn, .sqrshrn, .uqrshrn, .sqshrun, .sqrshrun => narrow(k, cpu, o, &qc),
        .saddlv, .uaddlv, .smaxv, .umaxv, .sminv, .uminv, .addv => acrossLanes(k, cpu, o),
        .dup_e, .dup_g, .smov, .umov, .ins_g, .ins_e => copy(k, cpu, o),
        .uzp1, .uzp2, .trn1, .trn2, .zip1, .zip2 => permute(k, cpu, o),
        .ext => {
            const n = cpu.v[o.n];
            const mm = cpu.v[o.m];
            const sh: u8 = @intCast(o.imm * 8);
            if (o.sh & sd.Q != 0) {
                const cat = @as(u256, mm) << 128 | n;
                cpu.v[o.d] = @truncate(cat >> sh);
            } else {
                const cat = @as(u128, @as(u64, @truncate(mm))) << 64 | @as(u64, @truncate(n));
                cpu.v[o.d] = @as(u64, @truncate(cat >> @intCast(sh)));
            }
        },
        .tbl, .tbx => {
            var table: [64]u8 = undefined;
            const nregs = @as(usize, o.a) + 1;
            for (0..nregs) |i| std.mem.writeInt(u128, table[i * 16 ..][0..16], cpu.v[(o.n + i) & 31], .little);
            const idx = cpu.v[o.m];
            const old = cpu.v[o.d];
            var r: u128 = 0;
            for (0..count(o, u8)) |i| {
                const j = lane(idx, u8, i);
                const b: u8 = if (j < nregs * 16) table[j] else if (k == .tbx) lane(old, u8, i) else 0;
                put(&r, u8, i, b);
            }
            cpu.v[o.d] = r;
        },
        .f_mov, .f_abs, .f_neg, .f_sqrt, .f_cvt, .f_rint, .f_cmp, .f_ccmp, .f_mov_i, .f_mul, .f_div, .f_add, .f_sub, .f_max, .f_min, .f_maxnm, .f_minnm, .f_nmul, .f_csel, .f_madd, .f_msub, .f_nmadd, .f_nmsub, .f_toint, .f_fromint, .f_mov_tog, .f_mov_fromg => fpScalar(k, cpu, o),
        _ => return exec.undef(m, pc),
    }
    if (qc) cpu.fpsr |= QC;
    return .next;
}

// ---------------------------------------------------------------- integer, elementwise

/// d = f(n, m, d) elementwise, m's element o.imm when `indexed`.
inline fn ew(comptime k0: K, comptime k: K, comptime indexed: bool, cpu: *Cpu, o: *const Op, qc: *bool) void {
    _ = k0;
    switch (o.x) {
        inline 0...3 => |s| {
            const T = UInt(s);
            const a = cpu.v[o.n];
            const b = cpu.v[o.m];
            const dd = cpu.v[o.d];
            var r: u128 = 0;
            const bi: T = if (indexed) lane(b, T, @intCast(o.imm)) else 0;
            for (0..count(o, T)) |i| {
                put(&r, T, i, elem(k, T, lane(a, T, i), if (indexed) bi else lane(b, T, i), lane(dd, T, i), @intCast(o.imm), qc));
            }
            cpu.v[o.d] = r;
        },
        else => unreachable,
    }
}

/// A shift by a register's signed low byte (SSHL and its kin).
fn shiftReg(comptime T: type, a: T, b: T, comptime signed: bool, comptime rounding: bool, comptime saturating: bool, qc: *bool) T {
    const N: i32 = @bitSizeOf(T);
    const sh: i32 = @as(i8, @bitCast(@as(u8, @truncate(b))));
    const v: i128 = if (signed) sx(T, a) else zx(T, a);
    if (sh >= 0) {
        if (!saturating) return if (sh >= N) 0 else a << @intCast(sh);
        if (v == 0) return 0;
        if (sh >= N) {
            qc.* = true;
            return if (signed) (if (v < 0) @bitCast(@as(Signed(T), std.math.minInt(Signed(T)))) else std.math.maxInt(Signed(T))) else std.math.maxInt(T);
        }
        const r = v << @intCast(sh);
        return if (signed) satS(T, r, qc) else satU(T, r, qc);
    }
    const n: i32 = -sh;
    if (rounding) {
        if (n > N) return 0;
        const r = (v + (@as(i128, 1) << @intCast(n - 1))) >> @intCast(n);
        return if (saturating) (if (signed) satS(T, r, qc) else satU(T, r, qc)) else @truncate(@as(u128, @bitCast(r)));
    }
    if (n >= N) return if (signed and v < 0) std.math.maxInt(T) else 0;
    return @truncate(@as(u128, @bitCast(v >> @intCast(n))));
}

fn elem(comptime k: K, comptime T: type, a: T, b: T, d: T, sh: u32, qc: *bool) T {
    const N = @bitSizeOf(T);
    const W = Wide(T);
    return switch (k) {
        .shadd => @truncate(@as(u128, @bitCast((sx(T, a) + sx(T, b)) >> 1))),
        .uhadd => @truncate((@as(W, a) + b) >> 1),
        .srhadd => @truncate(@as(u128, @bitCast((sx(T, a) + sx(T, b) + 1) >> 1))),
        .urhadd => @truncate((@as(W, a) + b + 1) >> 1),
        .shsub => @truncate(@as(u128, @bitCast((sx(T, a) - sx(T, b)) >> 1))),
        .uhsub => @truncate(@as(u128, @bitCast((zx(T, a) - zx(T, b)) >> 1))),
        .sqadd => satS(T, sx(T, a) + sx(T, b), qc),
        .uqadd => satU(T, zx(T, a) + zx(T, b), qc),
        .sqsub => satS(T, sx(T, a) - sx(T, b), qc),
        .uqsub => satU(T, zx(T, a) - zx(T, b), qc),
        .cmgt => ones(T, sx(T, a) > sx(T, b)),
        .cmhi => ones(T, a > b),
        .cmge => ones(T, sx(T, a) >= sx(T, b)),
        .cmhs => ones(T, a >= b),
        .cmeq => ones(T, a == b),
        .cmtst => ones(T, a & b != 0),
        .sshl => shiftReg(T, a, b, true, false, false, qc),
        .ushl => shiftReg(T, a, b, false, false, false, qc),
        .sqshl => shiftReg(T, a, b, true, false, true, qc),
        .uqshl => shiftReg(T, a, b, false, false, true, qc),
        .srshl => shiftReg(T, a, b, true, true, false, qc),
        .urshl => shiftReg(T, a, b, false, true, false, qc),
        .sqrshl => shiftReg(T, a, b, true, true, true, qc),
        .uqrshl => shiftReg(T, a, b, false, true, true, qc),
        .smax => if (sx(T, a) > sx(T, b)) a else b,
        .umax => @max(a, b),
        .smin => if (sx(T, a) < sx(T, b)) a else b,
        .umin => @min(a, b),
        .sabd => @truncate(@abs(sx(T, a) - sx(T, b))),
        .uabd => @truncate(@abs(zx(T, a) - zx(T, b))),
        .saba => d +% @as(T, @truncate(@abs(sx(T, a) - sx(T, b)))),
        .uaba => d +% @as(T, @truncate(@abs(zx(T, a) - zx(T, b)))),
        .add => a +% b,
        .sub => a -% b,
        .mla => d +% a *% b,
        .mls => d -% a *% b,
        .mul => a *% b,
        .pmul => if (T == u8) @truncate(pmul8(a, b)) else unreachable,
        .sqdmulh => satS(T, (2 * sx(T, a) * sx(T, b)) >> N, qc),
        .sqrdmulh => satS(T, (2 * sx(T, a) * sx(T, b) + (@as(i128, 1) << (N - 1))) >> N, qc),
        // two-register misc
        .suqadd => satS(T, sx(T, d) + zx(T, a), qc),
        .usqadd => satU(T, zx(T, d) + sx(T, a), qc),
        .cls => blk: {
            const inv: T = if (sx(T, a) < 0) std.math.maxInt(T) else 0;
            break :blk @as(T, @clz(a ^ inv)) -| 1;
        },
        .clz => @clz(a),
        .cnt => @popCount(a),
        .not => ~a,
        .rbit => @bitReverse(a),
        .sqabs => satS(T, @intCast(@abs(sx(T, a))), qc),
        .sqneg => satS(T, -sx(T, a), qc),
        .abs => @truncate(@abs(sx(T, a))),
        .neg => 0 -% a,
        .cmgt0 => ones(T, sx(T, a) > 0),
        .cmge0 => ones(T, sx(T, a) >= 0),
        .cmeq0 => ones(T, a == 0),
        .cmle0 => ones(T, sx(T, a) <= 0),
        .cmlt0 => ones(T, sx(T, a) < 0),
        // shift by immediate
        .sshr => @truncate(@as(u128, @bitCast(sx(T, a) >> @intCast(sh)))),
        .ushr => @truncate(@as(u128, a) >> @intCast(sh)),
        .ssra => d +% @as(T, @truncate(@as(u128, @bitCast(sx(T, a) >> @intCast(sh))))),
        .usra => d +% @as(T, @truncate(@as(u128, a) >> @intCast(sh))),
        .srshr => @truncate(@as(u128, @bitCast((sx(T, a) + (@as(i128, 1) << @intCast(sh - 1))) >> @intCast(sh)))),
        .urshr => @truncate(@as(u128, @bitCast((zx(T, a) + (@as(i128, 1) << @intCast(sh - 1))) >> @intCast(sh)))),
        .srsra => d +% @as(T, @truncate(@as(u128, @bitCast((sx(T, a) + (@as(i128, 1) << @intCast(sh - 1))) >> @intCast(sh))))),
        .ursra => d +% @as(T, @truncate(@as(u128, @bitCast((zx(T, a) + (@as(i128, 1) << @intCast(sh - 1))) >> @intCast(sh))))),
        .shl => @truncate(@as(W, a) << @intCast(sh)),
        .sli => blk: {
            const mk: T = @truncate(@as(W, std.math.maxInt(T)) << @intCast(sh));
            break :blk (d & ~mk) | @as(T, @truncate(@as(W, a) << @intCast(sh)));
        },
        .sri => blk: {
            const mk: T = @truncate(@as(W, std.math.maxInt(T)) >> @intCast(sh));
            break :blk (d & ~mk) | @as(T, @truncate(@as(W, a) >> @intCast(sh)));
        },
        .sqshl_i => satS(T, sx(T, a) << @intCast(sh), qc),
        .uqshl_i => satU(T, zx(T, a) << @intCast(sh), qc),
        .sqshlu => satU(T, sx(T, a) << @intCast(sh), qc),
        else => unreachable,
    };
}

fn rev(comptime k: K, cpu: *Cpu, o: *const Op) void {
    const container: usize = switch (k) {
        .rev64 => 8,
        .rev32 => 4,
        else => 2,
    };
    switch (o.x) {
        inline 0...2 => |s| {
            const T = UInt(s);
            if (comptime container <= @sizeOf(T)) unreachable;
            const per = container / @sizeOf(T);
            const a = cpu.v[o.n];
            var r: u128 = 0;
            for (0..count(o, T)) |i| put(&r, T, i, lane(a, T, i ^ (per - 1)));
            cpu.v[o.d] = r;
        },
        else => unreachable,
    }
}

fn pairwise(comptime k: K, cpu: *Cpu, o: *const Op) void {
    switch (o.x) {
        inline 0...3 => |s| {
            const T = UInt(s);
            const a = cpu.v[o.n];
            const b = cpu.v[o.m];
            const scalar = o.sh & sd.SCALAR != 0;
            const c: usize = if (scalar) 2 else count(o, T);
            const at = struct {
                fn f(x: u128, y: u128, cc: usize, j: usize) T {
                    return if (j < cc) lane(x, T, j) else lane(y, T, j - cc);
                }
            }.f;
            var r: u128 = 0;
            var dummy = false;
            for (0..if (scalar) 1 else c) |i| {
                const p = at(a, b, c, 2 * i);
                const q = at(a, b, c, 2 * i + 1);
                put(&r, T, i, switch (k) {
                    .addp => p +% q,
                    .smaxp => elem(.smax, T, p, q, 0, 0, &dummy),
                    .umaxp => @max(p, q),
                    .sminp => elem(.smin, T, p, q, 0, 0, &dummy),
                    .uminp => @min(p, q),
                    else => unreachable,
                });
            }
            cpu.v[o.d] = r;
        },
        else => unreachable,
    }
}

fn logical(comptime k: K, cpu: *Cpu, o: *const Op) void {
    const n = cpu.v[o.n];
    const m = cpu.v[o.m];
    const d = cpu.v[o.d];
    const imm = @as(u128, o.imm) << 64 | o.imm;
    const r: u128 = switch (k) {
        .and_v => n & m,
        .bic_v => n & ~m,
        .orr_v => n | m,
        .orn_v => n | ~m,
        .eor_v => n ^ m,
        .bsl => (d & n) | (~d & m),
        .bit => (n & m) | (d & ~m),
        .bif => (d & m) | (n & ~m),
        .movi => imm,
        .orr_vi => d | imm,
        .bic_vi => d & ~imm,
        else => unreachable,
    };
    cpu.v[o.d] = r & mask(o);
}

// ---------------------------------------------------------------- integer, long and narrow

/// Wide results from narrow operands (the lower or, for Q, upper half of
/// n and m); for the _w forms n is already wide.
inline fn long(comptime k0: K, comptime k: K, comptime indexed: bool, cpu: *Cpu, o: *const Op, qc: *bool) void {
    _ = k0;
    switch (o.x) {
        inline 0...2 => |s| {
            const T = UInt(s);
            const W = UInt(s + 1);
            const scalar = o.sh & sd.SCALAR != 0;
            const c: usize = if (scalar) 1 else 8 / @sizeOf(T);
            const off: usize = if (!scalar and o.sh & sd.Q != 0) c else 0;
            const n = cpu.v[o.n];
            const m = cpu.v[o.m];
            const dd = cpu.v[o.d];
            const bi: T = if (indexed) lane(m, T, @intCast(o.imm)) else 0;
            var r: u128 = 0;
            for (0..c) |i| {
                const a = lane(n, T, i + off);
                const b = if (indexed) bi else lane(m, T, i + off);
                const d = lane(dd, W, i);
                const aw = lane(n, W, i);
                const v: W = switch (k) {
                    .saddl => @truncate(@as(u128, @bitCast(sx(T, a) + sx(T, b)))),
                    .uaddl => @as(W, a) + b,
                    .saddw => aw +% @as(W, @truncate(@as(u128, @bitCast(sx(T, b))))),
                    .uaddw => aw +% b,
                    .ssubl => @truncate(@as(u128, @bitCast(sx(T, a) - sx(T, b)))),
                    .usubl => @as(W, a) -% b,
                    .ssubw => aw -% @as(W, @truncate(@as(u128, @bitCast(sx(T, b))))),
                    .usubw => aw -% b,
                    .sabal => d +% @as(W, @truncate(@abs(sx(T, a) - sx(T, b)))),
                    .uabal => d +% @as(W, @truncate(@abs(zx(T, a) - zx(T, b)))),
                    .sabdl => @truncate(@abs(sx(T, a) - sx(T, b))),
                    .uabdl => @truncate(@abs(zx(T, a) - zx(T, b))),
                    .smlal => d +% @as(W, @truncate(@as(u128, @bitCast(sx(T, a) * sx(T, b))))),
                    .umlal => d +% @as(W, a) * b,
                    .smlsl => d -% @as(W, @truncate(@as(u128, @bitCast(sx(T, a) * sx(T, b))))),
                    .umlsl => d -% @as(W, a) * b,
                    .smull => @truncate(@as(u128, @bitCast(sx(T, a) * sx(T, b)))),
                    .umull => @as(W, a) * b,
                    .sqdmull => satS(W, 2 * sx(T, a) * sx(T, b), qc),
                    .sqdmlal => satS(W, sx(W, d) + sx(W, satS(W, 2 * sx(T, a) * sx(T, b), qc)), qc),
                    .sqdmlsl => satS(W, sx(W, d) - sx(W, satS(W, 2 * sx(T, a) * sx(T, b), qc)), qc),
                    .pmull => if (T == u8) pmul8(a, b) else unreachable,
                    .shll => @as(W, a) << @bitSizeOf(T),
                    .sshll => @truncate(@as(u128, @bitCast(sx(T, a) << @intCast(o.imm)))),
                    .ushll => @as(W, a) << @intCast(o.imm),
                    else => unreachable,
                };
                put(&r, W, i, v);
            }
            cpu.v[o.d] = r;
        },
        else => unreachable,
    }
}

fn addlp(comptime k: K, cpu: *Cpu, o: *const Op) void {
    switch (o.x) {
        inline 0...2 => |s| {
            const T = UInt(s);
            const W = UInt(s + 1);
            const n = cpu.v[o.n];
            const dd = cpu.v[o.d];
            var r: u128 = 0;
            for (0..count(o, W)) |i| {
                const p = lane(n, T, 2 * i);
                const q = lane(n, T, 2 * i + 1);
                const sum: W = switch (k) {
                    .saddlp, .sadalp => @truncate(@as(u128, @bitCast(sx(T, p) + sx(T, q)))),
                    else => @as(W, p) + q,
                };
                put(&r, W, i, if (k == .sadalp or k == .uadalp) sum +% lane(dd, W, i) else sum);
            }
            cpu.v[o.d] = r;
        },
        else => unreachable,
    }
}

/// Narrow results from wide operands, into d's lower half, or for the
/// "2" forms (Q) its upper half, keeping the lower.
fn narrow(comptime k: K, cpu: *Cpu, o: *const Op, qc: *bool) void {
    switch (o.x) {
        inline 0...2 => |s| {
            const T = UInt(s);
            const W = UInt(s + 1);
            const N = @bitSizeOf(T);
            const scalar = o.sh & sd.SCALAR != 0;
            const c: usize = if (scalar) 1 else 8 / @sizeOf(T);
            const n = cpu.v[o.n];
            const m = cpu.v[o.m];
            const sh: u32 = @intCast(o.imm);
            var r: u128 = 0;
            for (0..c) |i| {
                const a = lane(n, W, i);
                const b = lane(m, W, i);
                const half: i128 = if (sh == 0) 0 else @as(i128, 1) << @intCast(sh - 1);
                const v: T = switch (k) {
                    .addhn => @truncate((a +% b) >> N),
                    .raddhn => @truncate((@as(u128, a) + b + (@as(u128, 1) << (N - 1))) >> N),
                    .subhn => @truncate((a -% b) >> N),
                    .rsubhn => @truncate((a -% b +% (@as(W, 1) << (N - 1))) >> N),
                    .xtn => @truncate(a),
                    .sqxtn => satS(T, sx(W, a), qc),
                    .uqxtn => satU(T, zx(W, a), qc),
                    .sqxtun => satU(T, sx(W, a), qc),
                    .shrn => @truncate(a >> @intCast(sh)),
                    .rshrn => @truncate(@as(u128, @bitCast((zx(W, a) + half) >> @intCast(sh)))),
                    .sqshrn => satS(T, sx(W, a) >> @intCast(sh), qc),
                    .uqshrn => satU(T, zx(W, a) >> @intCast(sh), qc),
                    .sqrshrn => satS(T, (sx(W, a) + half) >> @intCast(sh), qc),
                    .uqrshrn => satU(T, (zx(W, a) + half) >> @intCast(sh), qc),
                    .sqshrun => satU(T, sx(W, a) >> @intCast(sh), qc),
                    .sqrshrun => satU(T, (sx(W, a) + half) >> @intCast(sh), qc),
                    else => unreachable,
                };
                put(&r, T, i, v);
            }
            cpu.v[o.d] = if (!scalar and o.sh & sd.Q != 0) (cpu.v[o.d] & std.math.maxInt(u64)) | r << 64 else r;
        },
        else => unreachable,
    }
}

fn acrossLanes(comptime k: K, cpu: *Cpu, o: *const Op) void {
    switch (o.x) {
        inline 0...2 => |s| {
            const T = UInt(s);
            const n = cpu.v[o.n];
            const c = count(o, T);
            var acc: i128 = if (k == .saddlv or k == .smaxv or k == .sminv) sx(T, lane(n, T, 0)) else zx(T, lane(n, T, 0));
            for (1..c) |i| {
                const e = lane(n, T, i);
                switch (k) {
                    .saddlv => acc += sx(T, e),
                    .uaddlv, .addv => acc += e,
                    .smaxv => acc = @max(acc, sx(T, e)),
                    .umaxv => acc = @max(acc, zx(T, e)),
                    .sminv => acc = @min(acc, sx(T, e)),
                    .uminv => acc = @min(acc, zx(T, e)),
                    else => unreachable,
                }
            }
            if (k == .smaxv or k == .sminv) acc = sx(T, @truncate(@as(u128, @bitCast(acc))));
            const bitsz: u8 = if (k == .saddlv or k == .uaddlv) 2 * @bitSizeOf(T) else @bitSizeOf(T);
            cpu.v[o.d] = @as(u128, @bitCast(acc)) & ((@as(u128, 1) << @intCast(bitsz)) - 1);
        },
        else => unreachable,
    }
}

fn copy(comptime k: K, cpu: *Cpu, o: *const Op) void {
    switch (o.x) {
        inline 0...3 => |s| {
            const T = UInt(s);
            const idx: usize = @intCast(o.imm);
            switch (k) {
                .dup_e, .dup_g => {
                    const e: T = if (k == .dup_e) lane(cpu.v[o.n], T, idx) else @truncate(cpu.r[o.n]);
                    var r: u128 = 0;
                    for (0..count(o, T)) |i| put(&r, T, i, e);
                    cpu.v[o.d] = r;
                },
                .smov => {
                    const e: u64 = @truncate(@as(u128, @bitCast(sx(T, lane(cpu.v[o.n], T, idx)))));
                    cpu.r[o.d] = if (o.a == 1) e else e & 0xffff_ffff;
                },
                .umov => cpu.r[o.d] = lane(cpu.v[o.n], T, idx),
                .ins_g => setLane(&cpu.v[o.d], T, idx, @truncate(cpu.r[o.n])),
                .ins_e => setLane(&cpu.v[o.d], T, idx, lane(cpu.v[o.n], T, o.a)),
                else => unreachable,
            }
        },
        else => unreachable,
    }
}

fn permute(comptime k: K, cpu: *Cpu, o: *const Op) void {
    switch (o.x) {
        inline 0...3 => |s| {
            const T = UInt(s);
            const n = cpu.v[o.n];
            const m = cpu.v[o.m];
            const c = count(o, T);
            var r: u128 = 0;
            for (0..c) |i| {
                const e: T = switch (k) {
                    .uzp1, .uzp2 => blk: {
                        const j = 2 * i + @intFromBool(k == .uzp2);
                        break :blk if (j < c) lane(n, T, j) else lane(m, T, j - c);
                    },
                    .trn1, .trn2 => blk: {
                        const j = (i & ~@as(usize, 1)) + @intFromBool(k == .trn2);
                        break :blk if (i & 1 == 0) lane(n, T, j) else lane(m, T, j);
                    },
                    .zip1, .zip2 => blk: {
                        const j = i / 2 + (if (k == .zip2) c / 2 else 0);
                        break :blk if (i & 1 == 0) lane(n, T, j) else lane(m, T, j);
                    },
                    else => unreachable,
                };
                put(&r, T, i, e);
            }
            cpu.v[o.d] = r;
        },
        else => unreachable,
    }
}

// ---------------------------------------------------------------- FP

/// softfloat's environment for FPCR, for format x (FZ doesn't apply to
/// half precision, which has its own FZ16 in later architectures).
pub fn env(fpcr: u32, x: u8) sf.Env {
    return envFz(fpcr, x != 1, x != 1);
}

fn envFz(fpcr: u32, in: bool, out: bool) sf.Env {
    const fz = fpcr >> 24 & 1 == 1;
    return .{
        .rounding = .fromArm(@truncate(fpcr >> 22)),
        .daz = fz and in,
        .ftz = fz and out,
        .ftz_inexact = false,
        .tininess = .before_rounding,
        .nans = if (fpcr >> 25 & 1 == 1) .default else .signaling_first,
        .default_nan_negative = false,
    };
}

/// softfloat's flags as FPSR's cumulative bits: IOC, DZC, OFC, UFC, IXC,
/// and IDC.
pub fn fpsrBits(f: u8) u32 {
    return @as(u32, @intFromBool(f & sf.IE != 0)) |
        @as(u32, @intFromBool(f & sf.ZE != 0)) << 1 |
        @as(u32, @intFromBool(f & sf.OE != 0)) << 2 |
        @as(u32, @intFromBool(f & sf.UE != 0)) << 3 |
        @as(u32, @intFromBool(f & sf.PE != 0)) << 4 |
        @as(u32, @intFromBool(f & sf.ID != 0)) << 7;
}

fn FT(comptime x: comptime_int) type {
    return switch (x) {
        1 => u16,
        2 => u32,
        3 => u64,
        else => unreachable,
    };
}

/// FMAX, FMIN, FMAXNM, FMINNM: Arm's rules.
fn maxMin(comptime T: type, e: *sf.Env, a: T, b: T, comptime is_max: bool, comptime num: bool) T {
    const F = sf.Fmt(T);
    var x = a;
    var y = b;
    if (num) {
        const qa = sf.isNan(T, a) and !sf.isSnan(T, a);
        const qb = sf.isNan(T, b) and !sf.isSnan(T, b);
        const inf: T = if (is_max) F.sign_bit | F.inf else F.inf;
        if (qa and !qb) x = inf else if (qb and !qa) y = inf;
    }
    if (sf.pickNan(T, e, &.{ x, y })) |r| return r;
    x = sf.daz(T, e, x);
    y = sf.daz(T, e, y);
    if (sf.isZero(T, x) and sf.isZero(T, y)) {
        const sa = x & F.sign_bit != 0;
        const sb = y & F.sign_bit != 0;
        const neg = if (is_max) sa and sb else sa or sb;
        return if (neg) F.sign_bit else 0;
    }
    const o = sf.order(T, x, y);
    return if ((o == .gt) == is_max) x else y;
}

/// FMADD's core: addend + n * m, with Arm's NaN rules (FPMulAdd).
pub fn mulAdd(comptime T: type, e: *sf.Env, addend: T, n: T, m: T) T {
    if (sf.pickNan(T, e, &.{ addend, n, m })) |r| {
        const inf_zero = (sf.isInf(T, n) and sf.isZero(T, sf.daz(T, e, m))) or (sf.isZero(T, sf.daz(T, e, n)) and sf.isInf(T, m));
        if (sf.isNan(T, addend) and !sf.isSnan(T, addend) and inf_zero) {
            e.flags |= sf.IE;
            return sf.defaultNan(T, e);
        }
        return r;
    }
    return sf.mulAdd(T, e, n, m, addend);
}

/// The NZCV of an FP comparison.
fn nzcvOf(o: sf.Order) u32 {
    return switch (o) {
        .lt => 0b1000,
        .eq => 0b0110,
        .gt => 0b0010,
        .un => 0b0011,
    };
}

fn toIntSat(comptime T: type, comptime I: type, e: *sf.Env, a: T, rnd: sf.Rounding, fbits: u32) I {
    if (sf.toFixed(T, I, e, a, rnd, fbits)) |v| return v;
    if (sf.isNan(T, a)) return 0;
    return if (a & sf.Fmt(T).sign_bit != 0) std.math.minInt(I) else std.math.maxInt(I);
}

fn fpScalar(comptime k: K, cpu: *Cpu, o: *const Op) void {
    switch (k) {
        .f_mov_i => return {
            cpu.v[o.d] = o.imm;
        },
        .f_mov_tog => return {
            const v = cpu.v[o.n];
            cpu.r[o.d] = switch (o.x) {
                2 => @as(u32, @truncate(v)),
                3 => @as(u64, @truncate(v)),
                else => @as(u64, @truncate(v >> 64)),
            };
        },
        .f_mov_fromg => return {
            const g = cpu.r[o.n];
            cpu.v[o.d] = switch (o.x) {
                2 => @as(u32, @truncate(g)),
                3 => g,
                else => (cpu.v[o.d] & std.math.maxInt(u64)) | @as(u128, g) << 64,
            };
        },
        .f_cvt => return switch (o.x) {
            inline 1...3 => |to| switch (o.a) {
                inline 1...3 => |from| {
                    if (to == from) unreachable;
                    var e = envFz(cpu.fpcr, from != 1, to != 1);
                    cpu.v[o.d] = sf.convert(FT(to), FT(from), &e, @truncate(cpu.v[o.n]));
                    cpu.fpsr |= fpsrBits(e.flags);
                },
                else => unreachable,
            },
            else => unreachable,
        },
        else => {},
    }
    switch (o.x) {
        inline 2, 3 => |x| {
            const T = FT(x);
            const F = sf.Fmt(T);
            var e = env(cpu.fpcr, x);
            const n: T = @truncate(cpu.v[o.n]);
            const m: T = @truncate(cpu.v[o.m]);
            const r: T = switch (k) {
                .f_mov => n,
                .f_abs => n & ~F.sign_bit,
                .f_neg => n ^ F.sign_bit,
                .f_sqrt => sf.sqrt(T, &e, n),
                .f_rint => blk: {
                    const ri = o.imm & 7;
                    const rnd: sf.Rounding = if (ri == 7) e.rounding else @enumFromInt(ri);
                    break :blk sf.roundToInt(T, &e, n, rnd, o.imm & 8 != 0);
                },
                .f_cmp, .f_ccmp => {
                    if (k == .f_ccmp and !exec.cond(cpu.nzcv, o.a)) {
                        cpu.nzcv = @as(u32, @intCast(o.imm & 0xf)) << 28;
                        return;
                    }
                    const b: T = if (k == .f_cmp and o.imm & 2 != 0) 0 else m;
                    const signaling = if (k == .f_cmp) o.imm & 1 != 0 else o.imm & 0x10 != 0;
                    const ord = sf.compare(T, &e, n, b, signaling);
                    cpu.nzcv = nzcvOf(ord) << 28;
                    cpu.fpsr |= fpsrBits(e.flags);
                    return;
                },
                .f_mul => sf.mul(T, &e, n, m),
                .f_div => sf.div(T, &e, n, m),
                .f_add => sf.add(T, &e, n, m),
                .f_sub => sf.sub(T, &e, n, m),
                .f_max => maxMin(T, &e, n, m, true, false),
                .f_min => maxMin(T, &e, n, m, false, false),
                .f_maxnm => maxMin(T, &e, n, m, true, true),
                .f_minnm => maxMin(T, &e, n, m, false, true),
                .f_nmul => sf.mul(T, &e, n, m) ^ F.sign_bit,
                .f_csel => if (exec.cond(cpu.nzcv, o.a)) n else m,
                .f_madd, .f_msub, .f_nmadd, .f_nmsub => blk: {
                    const a: T = @truncate(cpu.v[o.a]);
                    const neg_a = k == .f_nmadd or k == .f_nmsub;
                    const neg_n = k == .f_msub or k == .f_nmadd;
                    break :blk mulAdd(T, &e, if (neg_a) a ^ F.sign_bit else a, if (neg_n) n ^ F.sign_bit else n, m);
                },
                .f_toint => {
                    const rnd: sf.Rounding = @enumFromInt(o.imm & 7);
                    const fbits: u32 = @intCast(o.imm >> 8);
                    const v: u64 = if (o.sh == 1) (if (o.a == 1)
                        toIntSat(T, u64, &e, n, rnd, fbits)
                    else
                        toIntSat(T, u32, &e, n, rnd, fbits)) else if (o.a == 1)
                        @bitCast(toIntSat(T, i64, &e, n, rnd, fbits))
                    else
                        @as(u32, @bitCast(toIntSat(T, i32, &e, n, rnd, fbits)));
                    cpu.r[o.d] = v;
                    cpu.fpsr |= fpsrBits(e.flags);
                    return;
                },
                .f_fromint => blk: {
                    const g = cpu.r[o.n];
                    const fbits: u32 = @intCast(o.imm);
                    break :blk if (o.sh == 1) (if (o.a == 1)
                        sf.fromFixed(T, u64, &e, g, fbits)
                    else
                        sf.fromFixed(T, u32, &e, @truncate(g), fbits)) else if (o.a == 1)
                        sf.fromFixed(T, i64, &e, @bitCast(g), fbits)
                    else
                        sf.fromFixed(T, i32, &e, @bitCast(@as(u32, @truncate(g))), fbits);
                },
                else => unreachable,
            };
            cpu.v[o.d] = r;
            cpu.fpsr |= fpsrBits(e.flags);
        },
        else => unreachable,
    }
}

test {
    _ = @import("simd_oracle_test.zig");
}
