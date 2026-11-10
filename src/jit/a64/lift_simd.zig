//! ha64's front end for FP and AdvSIMD: simd_decode.zig's kinds to the
//! IR's `fp.*` and `v.*` ops. lift.zig hands it each run of consecutive
//! FP/SIMD instructions in a block (`run`); what it doesn't lift
//! (`lifts`) runs through `call.interp` as before.
//!
//! FP ops take their environment from the ExtAux, fixed when the region is
//! lifted, but FPCR is the guest's to change at any time. So a run with
//! an FPCR-dependent op is a diamond: if FPCR's RMode, FZ, DN, and AHP
//! are all clear (Arm's default, and what every program here runs with),
//! the lifted ops; otherwise `call.interp` for each instruction, so T0
//! applies the guest's FPCR. Both paths write their results to the Cpu
//! and meet in a new block. The `fp.*` ops OR their exceptions into
//! FPSR (aux2).
//!
//! A Q=0 vector op's upper half is zeroed. Vector FP ops are lifted for
//! Q=1 only: computing all four lanes of a Q=0 op could raise exceptions
//! from lanes the guest doesn't have.

const std = @import("std");
const builtin = @import("builtin");
const ir = @import("../ir.zig");
const lift = @import("lift.zig");
const dec = @import("../../interp/a64/decode.zig");
const sd = @import("../../interp/a64/simd_decode.zig");
const t0 = @import("../../interp/a64/exec.zig");

const K = sd.Kind;
const Cpu = t0.Cpu;
const Ref = ir.Ref;
const Type = ir.Type;
const Builder = ir.Builder;
const L = lift.L;
const Insn = lift.Insn;

fn vOff(n: u8) u64 {
    return @offsetOf(Cpu, "v") + @as(u64, n & 31) * 16;
}

/// FPCR's bits the fast path assumes clear: AHP, DN, FZ, and RMode.
const fpcr_env: u64 = 0x07c0_0000;
const fpsr_aux2: u64 = 1 + @offsetOf(Cpu, "fpsr");

/// The ExtAux of Arm's default environment.
fn env(esize: u2, imm: u16) u64 {
    const x: ir.ExtAux = .{ .arm = true, .nans = 1, .esize = esize, .imm = imm };
    return @bitCast(x);
}

fn envR(esize: u2, imm: u16, rounding: u3, exact: bool) u64 {
    const x: ir.ExtAux = .{ .arm = true, .nans = 1, .esize = esize, .imm = imm, .rounding = rounding, .exact = exact };
    return @bitCast(x);
}

/// A vector op's aux: its lane size and immediate.
fn vx(esize: u2, imm: u16) u64 {
    const x: ir.ExtAux = .{ .esize = esize, .imm = imm };
    return @bitCast(x);
}

fn ftype(x: u8) Type {
    return switch (x) {
        1 => .i16,
        2 => .i32,
        else => .i64,
    };
}

fn signBit(ty: Type) u64 {
    return @as(u64, 1) << @intCast(ty.bits() - 1);
}

/// Whether the op depends on FPCR (and so needs the diamond).
pub fn needsEnv(kind: K) bool {
    return switch (kind) {
        .f_add, .f_sub, .f_mul, .f_div, .f_sqrt, .f_max, .f_min, .f_maxnm, .f_minnm, .f_nmul, .f_madd, .f_msub, .f_nmadd, .f_nmsub, .f_cmp, .f_cvt, .f_rint, .f_toint, .f_fromint => true,
        .vf_add, .vf_sub, .vf_mul, .vf_div, .vf_max, .vf_min, .vf_maxnm, .vf_minnm, .vf_mla, .vf_mls, .vf_sqrt, .vf_cmeq, .vf_cmge, .vf_cmgt, .vf_cmeq0, .vf_cmge0, .vf_cmgt0, .vf_cmle0, .vf_cmlt0, .vf_fromint, .vf_toint, .vf_rint => true,
        else => false,
    };
}

/// Whether lifting is on. The emitters that run `fp.*` and `v.*` ops (so
/// far x86-64's, and ir_eval) take regions with them; the others decline
/// such a region whole, which would leave its integer code in T0 too. So
/// it's on by default only where the host's emitter has them; tests turn
/// it on to check the lifting on ir_eval.
pub var enabled: bool = builtin.cpu.arch == .x86_64;

/// Whether an FP/SIMD op is lifted (else it runs through call.interp).
pub fn lifts(o: dec.Op) bool {
    if (!enabled) return false;
    const kind = sd.ofKind(o.k);
    const q = o.sh & sd.Q != 0;
    const scalar = o.sh & sd.SCALAR != 0;
    return switch (kind) {
        .f_add, .f_sub, .f_mul, .f_div, .f_sqrt, .f_max, .f_min, .f_maxnm, .f_minnm, .f_nmul, .f_madd, .f_msub, .f_nmadd, .f_nmsub, .f_cmp, .f_cvt, .f_rint, .f_toint, .f_fromint => true,
        .f_mov, .f_abs, .f_neg, .f_mov_i, .f_mov_tog, .f_mov_fromg, .f_csel => true,
        .and_v, .bic_v, .orr_v, .orn_v, .eor_v, .bsl, .bit, .bif, .movi, .orr_vi, .bic_vi => true,
        .add, .sub, .cmeq, .cmgt, .cmge, .cmhi, .cmhs, .cmtst => true,
        .mul => !scalar,
        .smax, .smin, .umax, .umin => o.x < 3,
        .shl, .ushr, .sshr => true,
        .umov, .smov, .ins_g, .ins_e, .dup_g, .dup_e => true,
        .ext, .zip1, .zip2, .uzp1, .uzp2, .trn1, .trn2 => true,
        .tbl => o.a == 0,
        .rev64, .rev32, .rev16 => true,
        .xtn => true,
        .sshll, .ushll => true,
        .ld_multi, .st_multi => o.a & 0xf == 1,
        .ld_single, .st_single => o.a & 0xf == 1,
        .ld_rep => o.a & 0xf == 1,
        .vf_abs, .vf_neg => !scalar,
        .vf_add, .vf_sub, .vf_mul, .vf_div, .vf_max, .vf_min, .vf_maxnm, .vf_minnm, .vf_mla, .vf_mls, .vf_sqrt, .vf_cmeq, .vf_cmge, .vf_cmgt, .vf_cmeq0, .vf_cmge0, .vf_cmgt0, .vf_cmle0, .vf_cmlt0, .vf_fromint, .vf_toint, .vf_rint => q and !scalar,
        else => false,
    };
}

/// Lifts the run `ins` (consecutive lifted FP/SIMD instructions of one
/// block, after l's last), leaving l on the block where the rest of the
/// block goes on.
pub fn run(l: *L, ins: []const Insn) !void {
    var env_dep = false;
    for (ins) |in| env_dep = env_dep or needsEnv(sd.ofKind(in.op.k));
    if (!env_dep) {
        for (ins) |in| {
            try one(l, in);
            l.pending += 1;
        }
        return;
    }
    const b = l.b;
    try l.retireAll();
    const fpcr = try b.getreg(.i32, @offsetOf(Cpu, "fpcr"));
    const masked = try b.bin(.@"and", .i32, fpcr, try b.konst(.i32, fpcr_env));
    const default = try b.icmp(.eq, masked, try b.konst(.i32, 0));
    const fast = try b.block();
    const slow = try b.block();
    const join = try b.block();
    try b.brcond(default, fast, slow);

    b.begin(fast);
    l.* = .{ .b = b };
    for (ins) |in| {
        try one(l, in);
        l.pending += 1;
    }
    try l.retireAll();
    try b.br(join);

    b.begin(slow);
    for (ins, 0..) |in, i| {
        b.retired = @intCast(i);
        try b.interp(in.word, in.pc);
    }
    try b.retire(ins.len);
    try b.br(join);

    b.begin(join);
    l.* = .{ .b = b };
}

// ---------------------------------------------------------------- helpers

fn k(l: *L, ty: Type, v: u64) !Ref {
    return l.b.konst(ty, v);
}

fn vget(l: *L, n: u8) !Ref {
    return l.b.getreg(.v128, vOff(n));
}

fn vset(l: *L, n: u8, v: Ref) !void {
    try l.b.setreg(vOff(n), v);
}

fn ext(l: *L, op: ir.Op, ty: Type, a: Ref, bb: Ref, c: Ref, aux: u64, aux2: u64) !Ref {
    return l.b.emit(.{ .op = op, .ty = ty, .a = a, .b = bb, .c = c, .aux = aux, .aux2 = aux2 });
}

fn vk(l: *L, lo: u64, hi: u64) !Ref {
    return ext(l, .@"v.make", .v128, try k(l, .i64, lo), try k(l, .i64, hi), ir.none, 0, 0);
}

fn make(l: *L, lo: Ref, hi: Ref) !Ref {
    return ext(l, .@"v.make", .v128, lo, hi, ir.none, 0, 0);
}

fn lane(l: *L, v: Ref, esize: u2, i: u16) !Ref {
    return ext(l, .@"v.lane", ir.laneType(esize), v, ir.none, ir.none, vx(esize, i), 0);
}

fn low64(l: *L, v: Ref) !Ref {
    return lane(l, v, 3, 0);
}

/// v with its upper half zeroed, unless Q.
fn shape(l: *L, o: dec.Op, v: Ref) !Ref {
    if (o.sh & sd.Q != 0 and o.sh & sd.SCALAR == 0) return v;
    if (o.sh & sd.SCALAR != 0 and o.x < 3) {
        return make(l, try l.b.un(.zext, .i64, try lane(l, v, @intCast(o.x), 0)), try k(l, .i64, 0));
    }
    return make(l, try low64(l, v), try k(l, .i64, 0));
}

fn vbin(l: *L, op: ir.Op, a: Ref, bb: Ref, aux: u64) !Ref {
    return ext(l, op, .v128, a, bb, ir.none, aux, 0);
}

fn vun(l: *L, op: ir.Op, a: Ref, aux: u64) !Ref {
    return ext(l, op, .v128, a, ir.none, ir.none, aux, 0);
}

/// A scalar FP register's low bits as `ty`.
fn fget(l: *L, n: u8, ty: Type) !Ref {
    return l.b.getreg(ty, vOff(n));
}

/// Writes a scalar to a V register, zeroing the rest.
fn fput(l: *L, n: u8, v: Ref, ty: Type) !void {
    const lo = if (ty == .i64) v else try l.b.un(.zext, .i64, v);
    try vset(l, n, try make(l, lo, try k(l, .i64, 0)));
}

fn fop(l: *L, op: ir.Op, ty: Type, a: Ref, bb: Ref, c: Ref, aux: u64) !Ref {
    return ext(l, op, ty, a, bb, c, aux, fpsr_aux2);
}

fn esz(ty: Type) u2 {
    return switch (ty) {
        .i16 => 1,
        .i32 => 2,
        else => 3,
    };
}

/// A replicated byte-shuffle index vector: within each `container`-byte
/// group, element order reversed for elements of `ebytes`.
fn revIndex(container: u8, ebytes: u8) [16]u8 {
    var idx: [16]u8 = undefined;
    for (0..16) |i| {
        const e = i / ebytes;
        const per = container / ebytes;
        const re = (e / per) * per + (per - 1 - e % per);
        idx[i] = @intCast(re * ebytes + i % ebytes);
    }
    return idx;
}

fn idxVec(l: *L, idx: [16]u8) !Ref {
    return vk(l, std.mem.readInt(u64, idx[0..8], .little), std.mem.readInt(u64, idx[8..16], .little));
}

// ---------------------------------------------------------------- instructions

fn one(l: *L, in: Insn) !void {
    const o = in.op;
    const b = l.b;
    const kd = sd.ofKind(o.k);
    const esize: u2 = @intCast(o.x & 3);
    switch (kd) {
        // ---- scalar FP
        .f_mov, .f_abs, .f_neg => {
            const ty = ftype(o.x);
            var v = try fget(l, o.n, ty);
            if (kd == .f_abs) v = try b.bin(.@"and", ty, v, try k(l, ty, signBit(ty) - 1));
            if (kd == .f_neg) v = try b.bin(.xor, ty, v, try k(l, ty, signBit(ty)));
            try fput(l, o.d, v, ty);
        },
        .f_mov_i => try vset(l, o.d, try vk(l, o.imm, 0)),
        .f_mov_tog => {
            const v = switch (o.x) {
                2 => try b.un(.zext, .i64, try fget(l, o.n, .i32)),
                3 => try fget(l, o.n, .i64),
                else => try b.getreg(.i64, vOff(o.n) + 8),
            };
            try l.put(o.d, v);
        },
        .f_mov_fromg => switch (o.x) {
            2 => try fput(l, o.d, try l.src(o.n, .i32), .i32),
            3 => try fput(l, o.d, try l.x(o.n), .i64),
            else => try vset(l, o.d, try make(l, try b.getreg(.i64, vOff(o.d)), try l.x(o.n))),
        },
        .f_csel => {
            const ty = ftype(o.x);
            const c = try l.flags.cond(b, @intCast(o.a));
            try fput(l, o.d, try b.emit(.{ .op = .select, .ty = ty, .a = c, .b = try fget(l, o.n, ty), .c = try fget(l, o.m, ty) }), ty);
        },
        .f_add, .f_sub, .f_mul, .f_div, .f_max, .f_min, .f_maxnm, .f_minnm, .f_nmul => {
            const ty = ftype(o.x);
            const op: ir.Op = switch (kd) {
                .f_add => .@"fp.add",
                .f_sub => .@"fp.sub",
                .f_mul, .f_nmul => .@"fp.mul",
                .f_div => .@"fp.div",
                .f_max => .@"fp.max",
                .f_min => .@"fp.min",
                .f_maxnm => .@"fp.maxnm",
                else => .@"fp.minnm",
            };
            var r = try fop(l, op, ty, try fget(l, o.n, ty), try fget(l, o.m, ty), ir.none, env(esz(ty), 0));
            if (kd == .f_nmul) r = try b.bin(.xor, ty, r, try k(l, ty, signBit(ty)));
            try fput(l, o.d, r, ty);
        },
        .f_sqrt => {
            const ty = ftype(o.x);
            try fput(l, o.d, try fop(l, .@"fp.sqrt", ty, try fget(l, o.n, ty), ir.none, ir.none, env(esz(ty), 0)), ty);
        },
        .f_madd, .f_msub, .f_nmadd, .f_nmsub => {
            const ty = ftype(o.x);
            const sign = try k(l, ty, signBit(ty));
            var n = try fget(l, o.n, ty);
            var a = try fget(l, o.a, ty);
            if (kd == .f_msub or kd == .f_nmadd) n = try b.bin(.xor, ty, n, sign);
            if (kd == .f_nmadd or kd == .f_nmsub) a = try b.bin(.xor, ty, a, sign);
            try fput(l, o.d, try fop(l, .@"fp.fma", ty, n, try fget(l, o.m, ty), a, env(esz(ty), 0)), ty);
        },
        .f_cmp => {
            const ty = ftype(o.x);
            const rhs = if (o.imm & 2 != 0) try k(l, ty, 0) else try fget(l, o.m, ty);
            const ord = try ext(l, .@"fp.cmp", .i8, try fget(l, o.n, ty), rhs, ir.none, envR(esz(ty), 0, 0, o.imm & 1 != 0), fpsr_aux2);
            // NZCV by order: lt 1000, eq 0110, gt 0010, unordered 0011.
            const sh = try b.bin(.shl, .i32, try b.un(.zext, .i32, ord), try k(l, .i32, 2));
            const nib = try b.bin(.@"and", .i32, try b.bin(.lshr, .i32, try k(l, .i32, 0x3268), sh), try k(l, .i32, 0xf));
            const w = try b.bin(.shl, .i32, nib, try k(l, .i32, 28));
            l.flags.set(try b.un(.@"nzcv.unpack", .flags, w));
        },
        .f_cvt => {
            const to = ftype(o.x);
            const from = ftype(o.a);
            try fput(l, o.d, try fop(l, .@"fp.cvt", to, try fget(l, o.n, from), ir.none, ir.none, env(esz(to), 0)), to);
        },
        .f_rint => {
            const ty = ftype(o.x);
            const ri: u3 = @intCast(o.imm & 7);
            const rnd: u3 = if (ri == 7) 0 else ri;
            try fput(l, o.d, try fop(l, .@"fp.round", ty, try fget(l, o.n, ty), ir.none, ir.none, envR(esz(ty), 0, rnd, o.imm & 8 != 0)), ty);
        },
        .f_toint => {
            const from = ftype(o.x);
            const to: Type = if (o.a == 1) .i64 else .i32;
            const op: ir.Op = if (o.sh == 1) .@"fp.touint" else .@"fp.tosint";
            const r = try fop(l, op, to, try fget(l, o.n, from), ir.none, ir.none, envR(esz(from), @intCast(o.imm >> 8), @intCast(o.imm & 7), false));
            try l.putT(o.d, r, to);
        },
        .f_fromint => {
            const to = ftype(o.x);
            const from: Type = if (o.a == 1) .i64 else .i32;
            const op: ir.Op = if (o.sh == 1) .@"fp.fromuint" else .@"fp.fromsint";
            try fput(l, o.d, try fop(l, op, to, try l.src(o.n, from), ir.none, ir.none, env(esz(to), @intCast(o.imm))), to);
        },

        // ---- bitwise
        .and_v, .bic_v, .orr_v, .orn_v, .eor_v, .bsl, .bit, .bif => {
            const n = try vget(l, o.n);
            const m = try vget(l, o.m);
            const r = switch (kd) {
                .and_v => try vbin(l, .@"v.and", n, m, 0),
                .bic_v => try vbin(l, .@"v.andn", n, m, 0),
                .orr_v => try vbin(l, .@"v.or", n, m, 0),
                .orn_v => try vbin(l, .@"v.or", n, try vbin(l, .@"v.xor", m, try vk(l, std.math.maxInt(u64), std.math.maxInt(u64)), 0), 0),
                .eor_v => try vbin(l, .@"v.xor", n, m, 0),
                .bsl => blk: {
                    const d = try vget(l, o.d);
                    break :blk try vbin(l, .@"v.or", try vbin(l, .@"v.and", d, n, 0), try vbin(l, .@"v.andn", m, d, 0), 0);
                },
                .bit => blk: {
                    const d = try vget(l, o.d);
                    break :blk try vbin(l, .@"v.or", try vbin(l, .@"v.and", n, m, 0), try vbin(l, .@"v.andn", d, m, 0), 0);
                },
                else => blk: {
                    const d = try vget(l, o.d);
                    break :blk try vbin(l, .@"v.or", try vbin(l, .@"v.and", d, m, 0), try vbin(l, .@"v.andn", n, m, 0), 0);
                },
            };
            try vset(l, o.d, try shape(l, o, r));
        },
        .movi => try vset(l, o.d, if (o.sh & sd.Q != 0) try vk(l, o.imm, o.imm) else try vk(l, o.imm, 0)),
        .orr_vi, .bic_vi => {
            const d = try vget(l, o.d);
            const c = try vk(l, o.imm, o.imm);
            const r = if (kd == .orr_vi) try vbin(l, .@"v.or", d, c, 0) else try vbin(l, .@"v.andn", d, c, 0);
            try vset(l, o.d, try shape(l, o, r));
        },

        // ---- integer arithmetic and compares
        .add, .sub, .mul, .smax, .smin, .umax, .umin, .cmeq, .cmgt, .cmge, .cmhi, .cmhs, .cmtst => {
            const n = try vget(l, o.n);
            const m = try vget(l, o.m);
            const r = switch (kd) {
                .add => try vbin(l, .@"v.add", n, m, vx(esize, 0)),
                .sub => try vbin(l, .@"v.sub", n, m, vx(esize, 0)),
                .mul => try vbin(l, .@"v.mul", n, m, vx(esize, 0)),
                .smax => try vbin(l, .@"v.max", n, m, vx(esize, 1)),
                .smin => try vbin(l, .@"v.min", n, m, vx(esize, 1)),
                .umax => try vbin(l, .@"v.max", n, m, vx(esize, 0)),
                .umin => try vbin(l, .@"v.min", n, m, vx(esize, 0)),
                .cmeq => try vbin(l, .@"v.cmp", n, m, vx(esize, @intFromEnum(ir.Pred.eq))),
                .cmgt => try vbin(l, .@"v.cmp", n, m, vx(esize, @intFromEnum(ir.Pred.sgt))),
                .cmge => try vbin(l, .@"v.cmp", n, m, vx(esize, @intFromEnum(ir.Pred.sge))),
                .cmhi => try vbin(l, .@"v.cmp", n, m, vx(esize, @intFromEnum(ir.Pred.ugt))),
                .cmhs => try vbin(l, .@"v.cmp", n, m, vx(esize, @intFromEnum(ir.Pred.uge))),
                else => try vbin(l, .@"v.cmp", try vbin(l, .@"v.and", n, m, 0), try vk(l, 0, 0), vx(esize, @intFromEnum(ir.Pred.ne))),
            };
            try vset(l, o.d, try shape(l, o, r));
        },
        .shl, .ushr, .sshr => {
            const op: ir.Op = switch (kd) {
                .shl => .@"v.shl",
                .ushr => .@"v.lshr",
                else => .@"v.ashr",
            };
            try vset(l, o.d, try shape(l, o, try vun(l, op, try vget(l, o.n), vx(esize, @intCast(o.imm)))));
        },

        // ---- copies
        .umov, .smov => {
            const e = try lane(l, try vget(l, o.n), esize, @intCast(o.imm));
            const ty = ir.laneType(esize);
            var v = if (ty == .i64) e else try b.un(if (kd == .smov) .sext else .zext, .i64, e);
            if (kd == .smov and o.a == 0) v = try b.un(.zext, .i64, try b.un(.trunc, .i32, v));
            try l.put(o.d, v);
        },
        .ins_g => {
            const ty = ir.laneType(esize);
            const g = try l.x(o.n);
            const e = if (ty == .i64) g else try b.un(.trunc, ty, g);
            try vset(l, o.d, try ext(l, .@"v.ins", .v128, try vget(l, o.d), e, ir.none, vx(esize, @intCast(o.imm)), 0));
        },
        .ins_e => {
            const e = try lane(l, try vget(l, o.n), esize, o.a);
            try vset(l, o.d, try ext(l, .@"v.ins", .v128, try vget(l, o.d), e, ir.none, vx(esize, @intCast(o.imm)), 0));
        },
        .dup_g, .dup_e => {
            const ty = ir.laneType(esize);
            const e = if (kd == .dup_e)
                try lane(l, try vget(l, o.n), esize, @intCast(o.imm))
            else if (ty == .i64) try l.x(o.n) else try b.un(.trunc, ty, try l.x(o.n));
            try vset(l, o.d, try shape(l, o, try ext(l, .@"v.dup", .v128, e, ir.none, ir.none, vx(esize, 0), 0)));
        },

        // ---- permutes
        .ext => {
            const n = try vget(l, o.n);
            const m = try vget(l, o.m);
            if (o.sh & sd.Q != 0) {
                try vset(l, o.d, try vbin(l, .@"v.ext", n, m, vx(0, @intCast(o.imm))));
            } else {
                const cat = try make(l, try low64(l, n), try low64(l, m));
                try vset(l, o.d, try shape(l, o, try vbin(l, .@"v.ext", cat, try vk(l, 0, 0), vx(0, @intCast(o.imm)))));
            }
        },
        .zip1, .zip2, .uzp1, .uzp2, .trn1, .trn2 => {
            const q = o.sh & sd.Q != 0;
            var n = try vget(l, o.n);
            var m = try vget(l, o.m);
            const op: ir.Op = switch (kd) {
                .zip1, .zip2 => .@"v.zip",
                .uzp1, .uzp2 => .@"v.uzp",
                else => .@"v.trn",
            };
            const second: u16 = @intFromBool(kd == .zip2 or kd == .uzp2 or kd == .trn2);
            if (q) {
                try vset(l, o.d, try vbin(l, op, n, m, vx(esize, second)));
            } else switch (kd) {
                // On 64-bit vectors: ZIP2 is the high half of ZIP1; UZP
                // works on n:m as one vector.
                .zip2 => {
                    const z = try vbin(l, op, n, m, vx(esize, 0));
                    try vset(l, o.d, try make(l, try lane(l, z, 3, 1), try k(l, .i64, 0)));
                },
                .uzp1, .uzp2 => {
                    n = try make(l, try low64(l, n), try low64(l, m));
                    m = n;
                    try vset(l, o.d, try shape(l, o, try vbin(l, op, n, m, vx(esize, second))));
                },
                else => try vset(l, o.d, try shape(l, o, try vbin(l, op, n, m, vx(esize, second)))),
            }
        },
        .tbl => {
            // One table register: indices past 15 give 0.
            try vset(l, o.d, try shape(l, o, try vbin(l, .@"v.tbl", try vget(l, o.n), try vget(l, o.m), 0)));
        },
        .rev64, .rev32, .rev16 => {
            const container: u8 = switch (kd) {
                .rev64 => 8,
                .rev32 => 4,
                else => 2,
            };
            const idx = try idxVec(l, revIndex(container, @as(u8, 1) << esize));
            try vset(l, o.d, try shape(l, o, try vbin(l, .@"v.tbl", try vget(l, o.n), idx, 0)));
        },
        .xtn => {
            // Narrowing from lanes of esize + 1, into d's lower half, or its
            // upper half for XTN2.
            const nv = try vun(l, .@"v.narrow", try vget(l, o.n), vx(esize + 1, 0));
            if (o.sh & sd.Q != 0) {
                try vset(l, o.d, try make(l, try low64(l, try vget(l, o.d)), try low64(l, nv)));
            } else {
                try vset(l, o.d, nv);
            }
        },
        .sshll, .ushll => {
            const imm: u16 = @as(u16, @intFromBool(kd == .sshll)) | @as(u16, @intFromBool(o.sh & sd.Q != 0)) << 1;
            var w = try vun(l, .@"v.widen", try vget(l, o.n), vx(esize, imm));
            if (o.imm != 0) w = try vun(l, .@"v.shl", w, vx(esize + 1, @intCast(o.imm)));
            try vset(l, o.d, w);
        },

        // ---- loads and stores of one structure element per register
        .ld_multi, .st_multi, .ld_single, .st_single, .ld_rep => try mem(l, in, kd),

        // ---- vector FP (Q=1)
        .vf_abs, .vf_neg => {
            const sign: u64 = if (o.x == 2) 0x8000_0000_8000_0000 else 0x8000_0000_0000_0000;
            const s = try vk(l, sign, sign);
            const n = try vget(l, o.n);
            const r = if (kd == .vf_abs) try vbin(l, .@"v.andn", n, s, 0) else try vbin(l, .@"v.xor", n, s, 0);
            try vset(l, o.d, try shape(l, o, r));
        },
        .vf_add, .vf_sub, .vf_mul, .vf_div, .vf_max, .vf_min, .vf_maxnm, .vf_minnm => {
            const op: ir.Op = switch (kd) {
                .vf_add => .@"fp.add",
                .vf_sub => .@"fp.sub",
                .vf_mul => .@"fp.mul",
                .vf_div => .@"fp.div",
                .vf_max => .@"fp.max",
                .vf_min => .@"fp.min",
                .vf_maxnm => .@"fp.maxnm",
                else => .@"fp.minnm",
            };
            try vset(l, o.d, try fop(l, op, .v128, try vget(l, o.n), try vget(l, o.m), ir.none, env(esize, 0)));
        },
        .vf_mla, .vf_mls => {
            var n = try vget(l, o.n);
            if (kd == .vf_mls) {
                const sign: u64 = if (o.x == 2) 0x8000_0000_8000_0000 else 0x8000_0000_0000_0000;
                n = try vbin(l, .@"v.xor", n, try vk(l, sign, sign), 0);
            }
            try vset(l, o.d, try fop(l, .@"fp.fma", .v128, n, try vget(l, o.m), try vget(l, o.d), env(esize, 0)));
        },
        .vf_sqrt => try vset(l, o.d, try fop(l, .@"fp.sqrt", .v128, try vget(l, o.n), ir.none, ir.none, env(esize, 0))),
        .vf_rint => {
            const ri: u3 = @intCast(o.imm & 7);
            try vset(l, o.d, try fop(l, .@"fp.round", .v128, try vget(l, o.n), ir.none, ir.none, envR(esize, 0, if (ri == 7) 0 else ri, o.imm & 8 != 0)));
        },
        .vf_cmeq, .vf_cmge, .vf_cmgt, .vf_cmeq0, .vf_cmge0, .vf_cmgt0, .vf_cmle0, .vf_cmlt0 => {
            // fp.cmp's order set: bit 0 lt, 1 eq, 2 gt.
            const set: u16, const signaling: bool = switch (kd) {
                .vf_cmeq, .vf_cmeq0 => .{ 2, false },
                .vf_cmge, .vf_cmge0 => .{ 6, true },
                .vf_cmgt, .vf_cmgt0 => .{ 4, true },
                .vf_cmle0 => .{ 3, true },
                else => .{ 1, true },
            };
            const zero_rhs = switch (kd) {
                .vf_cmeq0, .vf_cmge0, .vf_cmgt0, .vf_cmle0, .vf_cmlt0 => true,
                else => false,
            };
            const rhs = if (zero_rhs) try vk(l, 0, 0) else try vget(l, o.m);
            try vset(l, o.d, try fop(l, .@"fp.cmp", .v128, try vget(l, o.n), rhs, ir.none, envR(esize, set, 0, signaling)));
        },
        .vf_fromint => {
            const op: ir.Op = if (o.a == 1) .@"fp.fromuint" else .@"fp.fromsint";
            try vset(l, o.d, try fop(l, op, .v128, try vget(l, o.n), ir.none, ir.none, env(esize, @intCast(o.imm))));
        },
        .vf_toint => {
            const op: ir.Op = if (o.a == 1) .@"fp.touint" else .@"fp.tosint";
            try vset(l, o.d, try fop(l, op, .v128, try vget(l, o.n), ir.none, ir.none, envR(esize, @intCast(o.imm >> 8), @intCast(o.imm & 7), false)));
        },
        else => unreachable,
    }
}

/// LD1/ST1 of one to four registers (no interleaving), the single-lane
/// forms with one register, and LD1R.
fn mem(l: *L, in: Insn, kd: K) !void {
    const o = in.op;
    const b = l.b;
    try l.flush();
    const base = try l.x(o.n);
    const esize: u2 = @intCast(o.x & 3);
    var off: u64 = 0;
    switch (kd) {
        .ld_multi, .st_multi => {
            const nregs: u8 = o.a >> 4;
            const q = o.sh & sd.Q != 0;
            // Loads land in values first, so a fault leaves the registers.
            var vals: [4]Ref = undefined;
            for (0..nregs) |r| {
                const reg: u8 = @intCast((o.d + r) & 31);
                const a0 = try b.bin(.add, .i64, base, try k(l, .i64, off));
                if (kd == .ld_multi) {
                    const lo = try b.load(.i64, a0, .{ .size = 3 }, in.pc);
                    const hi = if (q) try b.load(.i64, try b.bin(.add, .i64, a0, try k(l, .i64, 8)), .{ .size = 3 }, in.pc) else try k(l, .i64, 0);
                    vals[r] = try make(l, lo, hi);
                } else {
                    const v = try vget(l, reg);
                    try b.store(a0, try low64(l, v), .{ .size = 3 }, in.pc);
                    if (q) try b.store(try b.bin(.add, .i64, a0, try k(l, .i64, 8)), try lane(l, v, 3, 1), .{ .size = 3 }, in.pc);
                }
                off += if (q) 16 else 8;
            }
            if (kd == .ld_multi) for (0..nregs) |r| try vset(l, @intCast((o.d + r) & 31), vals[r]);
        },
        .ld_single, .st_single => {
            const ty = ir.laneType(esize);
            const idx: u16 = @intCast(o.imm & 0xff);
            if (kd == .ld_single) {
                const e = try b.load(ty, base, .{ .size = esize }, in.pc);
                try vset(l, o.d, try ext(l, .@"v.ins", .v128, try vget(l, o.d), e, ir.none, vx(esize, idx), 0));
            } else {
                try b.store(base, try lane(l, try vget(l, o.d), esize, idx), .{ .size = esize }, in.pc);
            }
            off = @as(u64, 1) << esize;
        },
        .ld_rep => {
            const ty = ir.laneType(esize);
            const e = try b.load(ty, base, .{ .size = esize }, in.pc);
            try vset(l, o.d, try shape(l, o, try ext(l, .@"v.dup", .v128, e, ir.none, ir.none, vx(esize, 0), 0)));
            off = @as(u64, 1) << esize;
        },
        else => unreachable,
    }
    if (o.imm & (1 << 8) != 0) {
        const inc = try b.bin(.add, .i64, try l.x(o.m), try k(l, .i64, o.imm >> 16));
        try l.put(o.n, try b.bin(.add, .i64, base, inc));
    }
}
