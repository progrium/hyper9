//! ha64's front end: arm64 instructions to IR.
//!
//! The lifter works over T0's decoder (src/interp/a64/decode.zig), and its
//! read and write sets. It lifts the integer instructions (moves,
//! arithmetic with and without flags, logical, shifts, bitfields,
//! conditional select and compare, multiply and divide), every branch,
//! loads and stores of one register or a pair (general and FP/SIMD
//! registers, every addressing mode), the exclusive and
//! load-acquire/store-release forms, barriers, and the system registers
//! EL0 reads. STXR and STXP of W pairs are a branch on the monitor and a
//! `cas`. Everything else (FP and SIMD data processing, STXP of X pairs,
//! LDXP, CLREX, DC ZVA, CNTVCT) runs through `call.interp`,
//! which runs T0's handler on the Cpu.
//!
//! Regions: a linear scan from the entry PC that continues through
//! conditional branches and stops after an unconditional branch (B, BL,
//! BR, BLR, RET), SVC, BRK, an undefined instruction, or at the limits.
//! Branch targets inside the scanned range start blocks; a backward one is
//! a loop, with a `poll` at its head.
//!
//! Within a block the lifter keeps each general register's latest value
//! (read once, then reused) and the flags (flags.zig), and writes every
//! result to the Cpu as it's made, so guest state is exact at every
//! operation that can leave. Each op that can leave carries the count of
//! instructions completed before it in the block (`Builder.retired`), so
//! `Ctx.retired` is exact at a fault too, as T0 counts them; a `retire`
//! op is only needed before a branch to another block.

const std = @import("std");
const ir = @import("../ir.zig");
const ctx_mod = @import("../ctx.zig");
const fe = @import("../frontend.zig");
const flags_mod = @import("flags.zig");
const dec = @import("../../interp/a64/decode.zig");
const t0 = @import("../../interp/a64/exec.zig");
const lift_simd = @import("lift_simd.zig");

const Kind = dec.Kind;
const Cpu = t0.Cpu;
const Ref = ir.Ref;
const Type = ir.Type;
const Builder = ir.Builder;
const Flags = flags_mod.Flags;
const ZR = dec.ZR;
const SINK = dec.SINK;

pub const frontend: fe.Frontend = .{ .name = "ha64", .flags = .nzcv, .lift = lift, .interp = interp };

fn regOff(n: u8) u64 {
    return @offsetOf(Cpu, "r") + @as(u64, n) * 8;
}
fn vOff(n: u8) u64 {
    return @offsetOf(Cpu, "v") + @as(u64, n & 31) * 16;
}
fn monOff(comptime field: []const u8) u64 {
    return @offsetOf(Cpu, "monitor") + @offsetOf(t0.Monitor, field);
}

// ---------------------------------------------------------------- classes

/// What the lifter does with an instruction.
pub const How = enum {
    /// Lifted to IR; falls through.
    lift,
    /// Run by `call.interp`; falls through (or leaves the region).
    interp,
    /// B.cond, CBZ, CBNZ, TBZ, TBNZ: ends a block, the scan goes on.
    branch,
    /// B (and B.AL, B.NV): ends the region.
    jump,
    /// BL.
    call,
    /// BR, BLR, RET.
    indirect,
    svc,
    brk,
    undef,

    /// The scan stops after this instruction.
    pub fn ends(h: How) bool {
        return switch (h) {
            .lift, .interp, .branch => false,
            else => true,
        };
    }
};

pub fn classify(o: dec.Op) How {
    if (o.k.isSimd()) return if (lift_simd.lifts(o)) .lift else .interp;
    return switch (dec.regs(o).ctrl) {
        .none => if (lifts(o)) .lift else .interp,
        .jump => .jump,
        .cond => if (o.k == .bcond and o.x >= 14) .jump else .branch,
        .call => .call,
        .indirect, .call_indirect, .ret => .indirect,
        .svc => .svc,
        .brk => .brk,
        .undef, .page_end => .undef,
    };
}

/// Whether a non-branch instruction is lifted (else it's interpreted).
pub fn lifts(o: dec.Op) bool {
    return switch (o.k) {
        .ldxp, .clrex, .dc_zva => false,
        // LSE atomics run on T0 until they're lifted to rmw and cas.
        .ldop, .cas, .casp => false,
        // A pair of X registers is 16 bytes, wider than `cas`.
        .stxp => o.x == 2,
        .mrs => switch (o.imm) {
            dec.sr.nzcv, dec.sr.fpcr, dec.sr.fpsr, dec.sr.tpidr_el0, dec.sr.tpidrro_el0, dec.sr.cntfrq_el0, dec.sr.ctr_el0, dec.sr.dczid_el0 => true,
            else => false, // CNTVCT_EL0 reads T0's clock
        },
        .msr => switch (o.imm) {
            dec.sr.nzcv, dec.sr.fpcr, dec.sr.fpsr, dec.sr.tpidr_el0 => true,
            else => false,
        },
        .undef, .next_page => false,
        _ => false,
        else => true,
    };
}

// ---------------------------------------------------------------- regions

const max_insns = 512;

pub const Insn = struct { pc: u64, word: u32, op: dec.Op, how: How };

pub fn lift(b: *Builder, src: fe.Source, pc: u64, limits: fe.Limits) fe.LiftError!void {
    var buf: [max_insns]Insn = undefined;
    var n: usize = 0;
    const max = @min(limits.max_insns, max_insns);
    const last_page = (pc >> 12) + limits.max_pages - 1;
    var p = pc;
    while (n < max and p >> 12 <= last_page) : (p += 4) {
        var word: [4]u8 = undefined;
        if (src.readAll(p, &word) != 4) break;
        const w = std.mem.readInt(u32, &word, .little);
        const o = dec.decode(w, p);
        const how = classify(o);
        buf[n] = .{ .pc = p, .word = w, .op = o, .how = how };
        n += 1;
        if (how.ends()) break;
    }
    if (n == 0) {
        // Nothing readable: T0 takes the instruction abort.
        b.begin(try b.block());
        try b.exit(.@"exit.chain", pc);
        return;
    }
    const insns = buf[0..n];
    const end = pc + 4 * n; // the first PC past the scanned range

    // Block leaders: the entry, in-range branch targets, and the
    // instructions after conditional branches.
    var leader: [max_insns + 1]bool = @splat(false);
    var loop_head: [max_insns + 1]bool = @splat(false);
    leader[0] = true;
    leader[n] = true; // the fall-out point, if anything reaches it
    for (insns, 0..) |in, i| {
        switch (in.how) {
            .branch, .jump, .call => {
                const t = in.op.imm;
                if (inRange(t, pc, end)) {
                    const ti: usize = @intCast((t - pc) / 4);
                    leader[ti] = true;
                    if (ti <= i) loop_head[ti] = true;
                }
                leader[i + 1] = true;
            },
            else => {},
        }
    }
    loop_head[0] = true; // the entry polls too, so a chained loop sees kicks

    // Which instructions run through call.interp, for the flags' liveness.
    var by_interp: [max_insns]bool = undefined;
    var ops: [max_insns]dec.Op = undefined;
    for (insns, 0..) |in, i| {
        by_interp[i] = in.how == .interp;
        ops[i] = in.op;
    }

    // One block per leader in [0, n], in order; block ids follow.
    var block_of: [max_insns + 1]ir.BlockId = undefined;
    for (0..n + 1) |i| if (leader[i]) {
        block_of[i] = try b.block();
    };

    const R = Region{ .pc = pc, .end = end, .block_of = block_of[0 .. n + 1] };
    var i: usize = 0;
    while (i <= n) {
        const start = i;
        b.begin(block_of[start]);
        if (start == n) {
            // Fall-out: leave for the next PC.
            try b.exit(.@"exit.chain", end);
            break;
        }
        var l: L = .{ .b = b };
        if (loop_head[start]) try b.poll(insns[start].pc);
        // The block's last instruction: the next leader's, less one.
        var last = start;
        while (!leader[last + 1]) last += 1;
        while (true) {
            const in = insns[i];
            switch (in.how) {
                .lift => if (in.op.k.isSimd()) {
                    // A run of FP/SIMD instructions: lift_simd.zig's.
                    var j = i;
                    while (j < last and insns[j + 1].how == .lift and insns[j + 1].op.k.isSimd()) j += 1;
                    try lift_simd.run(&l, insns[i .. j + 1]);
                    i = j;
                } else {
                    // The flags this writes are dead if a later
                    // instruction in the block overwrites them first.
                    l.flags_dead = flags_mod.dead(ops[i + 1 .. last + 1], by_interp[i + 1 .. last + 1]) and i < last;
                    try l.liftOne(in);
                    l.pending += 1;
                },
                .interp => {
                    try l.flush();
                    try b.interp(in.word, in.pc);
                    l.pending += 1;
                    l.clobber();
                },
                .branch => {
                    const c = try l.condition(in.op);
                    l.pending += 1;
                    try l.retireAll();
                    const taken = try R.target(b, in.op.imm);
                    try b.brcond(c, taken, block_of[i + 1]);
                    // Only a target outside the region gets a new block to
                    // fill; one inside is lifted in its turn.
                    if (!inRange(in.op.imm, pc, end)) try fillExit(b, taken, in.op.imm);
                },
                .jump => {
                    l.pending += 1;
                    try l.flushFor(inRange(in.op.imm, pc, end));
                    try R.jumpTo(b, in.op.imm);
                },
                .call => {
                    try l.put(30, try b.konst(.i64, in.pc + 4));
                    l.pending += 1;
                    try l.flushFor(inRange(in.op.imm, pc, end));
                    try R.jumpTo(b, in.op.imm);
                },
                .indirect => {
                    const t = try l.x(in.op.n);
                    if (in.op.k == .blr) try l.put(30, try b.konst(.i64, in.pc + 4));
                    l.pending += 1;
                    try l.flush();
                    try b.exitIndirect(t);
                },
                .svc => {
                    // T0 clears the exclusive monitor at a system call.
                    try clearMonitor(b);
                    l.pending += 1;
                    try l.flush();
                    try b.exit(.@"exit.svc", in.pc + 4);
                },
                // Neither retires: the PC stays at the instruction.
                .brk => {
                    try l.flush();
                    try b.exit(.@"exit.brk", in.pc);
                },
                .undef => {
                    try l.flush();
                    try b.exit(.@"exit.undef", in.pc);
                },
            }
            i += 1;
            if (in.how.ends() or in.how == .branch) break;
            if (leader[i]) {
                try l.retireAll();
                try b.br(block_of[i]);
                break;
            }
        }
        while (i <= n and !leader[i]) i += 1;
    }
}

fn inRange(t: u64, pc: u64, end: u64) bool {
    return t >= pc and t < end and t & 3 == 0;
}

const Region = struct {
    pc: u64,
    end: u64,
    block_of: []const ir.BlockId,

    /// A block id for branching to guest PC `t`: its block if it's in the
    /// region, else a new block that will hold an exit.
    fn target(r: Region, b: *Builder, t: u64) !ir.BlockId {
        if (inRange(t, r.pc, r.end)) return r.block_of[@intCast((t - r.pc) / 4)];
        return b.block();
    }

    fn jumpTo(r: Region, b: *Builder, t: u64) !void {
        if (inRange(t, r.pc, r.end)) return b.br(r.block_of[@intCast((t - r.pc) / 4)]);
        try b.exit(.@"exit.chain", t);
    }
};

fn clearMonitor(b: *Builder) !void {
    const z64 = try b.konst(.i64, 0);
    const z8 = try b.konst(.i8, 0);
    try b.setreg(monOff("valid"), z8);
    try b.setreg(monOff("addr"), z64);
    try b.setreg(monOff("size"), z8);
    try b.setreg(monOff("lo"), z64);
    try b.setreg(monOff("hi"), z64);
}

fn fillExit(b: *Builder, id: ir.BlockId, t: u64) !void {
    if (b.r.blocks.items[id].begun) return;
    b.begin(id);
    try b.exit(.@"exit.chain", t);
}

// ---------------------------------------------------------------- one block

/// A block being lifted: the builder, the cached register and flag values,
/// and the instructions not yet retired.
pub const L = struct {
    b: *Builder,
    /// Each general register slot's current value (i64), once read or
    /// written in this block.
    regs: [dec.nslots]?Ref = @splat(null),
    flags: Flags = .{},
    /// Instructions lifted since the last `retire`.
    pending: u64 = 0,
    /// The instruction being lifted needn't compute its flags.
    flags_dead: bool = false,

    /// Before an operation that can leave: the flags in the Cpu, and the
    /// instructions so far retired.
    pub fn flush(l: *L) !void {
        try l.flags.sync(l.b);
        l.b.retired = @intCast(l.pending);
    }

    fn flushFor(l: *L, in_region: bool) !void {
        if (in_region) return l.retireAll();
        try l.flush();
    }

    /// Before a branch to another block: the block's count, as a `retire`.
    pub fn retireAll(l: *L) !void {
        try l.flags.sync(l.b);
        try l.b.retire(l.pending);
        l.pending = 0;
    }

    /// After `call.interp`, which may have changed any register.
    fn clobber(l: *L) void {
        l.regs = @splat(null);
        l.flags.clobber();
    }

    fn k(l: *L, ty: Type, v: u64) !Ref {
        return l.b.konst(ty, v);
    }

    /// A general register slot as an i64 (ZR reads 0).
    pub fn x(l: *L, s: u8) !Ref {
        if (s == ZR or s == SINK) return l.k(.i64, 0);
        if (l.regs[s]) |v| return v;
        const v = try l.b.getreg(.i64, regOff(s));
        l.regs[s] = v;
        return v;
    }

    /// A register at type `ty` (i64, or the low 32 bits as i32).
    pub fn src(l: *L, s: u8, ty: Type) !Ref {
        const v = try l.x(s);
        return if (ty == .i64) v else l.b.un(.trunc, ty, v);
    }

    /// Writes an i64 to a register slot.
    pub fn put(l: *L, s: u8, v: Ref) !void {
        if (s == SINK or s == ZR) return;
        try l.b.setreg(regOff(s), v);
        l.regs[s] = v;
    }

    /// Writes a value of type `ty`, zero-extended.
    pub fn putT(l: *L, s: u8, v: Ref, ty: Type) !void {
        try l.put(s, if (ty == .i64) v else try l.b.un(.zext, .i64, v));
    }

    fn bin(l: *L, op: ir.Op, ty: Type, a: Ref, c: Ref) !Ref {
        return l.b.bin(op, ty, a, c);
    }

    fn setFlags(l: *L, v: Ref) void {
        l.flags.set(v);
    }

    // ---- operand forms

    /// Rm shifted by type `st` (LSL, LSR, ASR, ROR) and `amt`.
    fn shifted(l: *L, s: u8, ty: Type, st: u8, amt: u8) !Ref {
        const v = try l.src(s, ty);
        if (amt == 0) return v;
        const op: ir.Op = switch (st) {
            0 => .shl,
            1 => .lshr,
            2 => .ashr,
            else => .ror,
        };
        return l.bin(op, ty, v, try l.k(ty, amt));
    }

    /// Rm extended by `option` (UXTB ... SXTX) and shifted left by `amt`,
    /// as an i64.
    fn extended(l: *L, s: u8, option: u8, amt: u8) !Ref {
        const v = try l.x(s);
        const b = l.b;
        const e = switch (option & 7) {
            0 => try l.bin(.@"and", .i64, v, try l.k(.i64, 0xff)),
            1 => try l.bin(.@"and", .i64, v, try l.k(.i64, 0xffff)),
            2 => try b.un(.zext, .i64, try b.un(.trunc, .i32, v)),
            4 => try b.un(.sext, .i64, try b.un(.trunc, .i8, v)),
            5 => try b.un(.sext, .i64, try b.un(.trunc, .i16, v)),
            6 => try b.un(.sext, .i64, try b.un(.trunc, .i32, v)),
            else => v,
        };
        if (amt == 0) return e;
        return l.bin(.shl, .i64, e, try l.k(.i64, amt));
    }

    /// ADD, ADDS, SUB, SUBS (op 0-3) of a and b into d.
    fn arith(l: *L, ty: Type, d: u8, op: u32, a: Ref, c: Ref) !void {
        const sub = op >= 2;
        const res = try l.bin(if (sub) .sub else .add, ty, a, c);
        if (op & 1 == 1 and !l.flags_dead) l.setFlags(try l.b.flags(if (sub) .@"nzcv.sub" else .@"nzcv.add", a, c));
        try l.putT(d, res, ty);
    }

    fn logicFlags(l: *L, res: Ref) !void {
        if (!l.flags_dead) l.setFlags(try l.b.emit(.{ .op = .@"nzcv.logic", .ty = .flags, .a = res }));
    }

    fn ones(l: *L, ty: Type, n: u8) !Ref {
        return l.k(ty, dec.ones(@intCast(n)));
    }

    // ---- instructions

    fn liftOne(l: *L, in: Insn) !void {
        const o = in.op;
        const b = l.b;
        const kd = o.k;
        const X: Type = .i64;
        const W: Type = .i32;
        switch (kd) {
            .nop => {},
            .fence => _ = try b.emit(.{ .op = .fence }),
            .movi => try l.put(o.d, try l.k(X, o.imm)),
            .movk_x, .movk_w => {
                const ty: Type = if (kd == .movk_x) X else W;
                const keep = try l.bin(.@"and", ty, try l.src(o.d, ty), try l.k(ty, ~(@as(u64, 0xffff) << @intCast(o.sh))));
                try l.putT(o.d, try l.bin(.@"or", ty, keep, try l.k(ty, o.imm << @intCast(o.sh))), ty);
            },
            .add_imm_x, .add_imm_w, .adds_imm_x, .adds_imm_w, .subs_imm_x, .subs_imm_w => {
                const ty: Type = switch (kd) {
                    .add_imm_x, .adds_imm_x, .subs_imm_x => X,
                    else => W,
                };
                const op: u32 = switch (kd) {
                    .add_imm_x, .add_imm_w => 0,
                    .adds_imm_x, .adds_imm_w => 1,
                    else => 3,
                };
                try l.arith(ty, o.d, op, try l.src(o.n, ty), try l.k(ty, o.imm));
            },
            .and_imm_x, .and_imm_w, .orr_imm_x, .orr_imm_w, .eor_imm_x, .eor_imm_w, .ands_imm_x, .ands_imm_w => {
                const idx = @intFromEnum(kd) - @intFromEnum(Kind.and_imm_x);
                const ty: Type = if (idx % 2 == 0) X else W;
                const op: ir.Op = switch (idx / 2) {
                    0, 3 => .@"and",
                    1 => .@"or",
                    else => .xor,
                };
                const res = try l.bin(op, ty, try l.src(o.n, ty), try l.k(ty, o.imm));
                if (idx / 2 == 3) try l.logicFlags(res);
                try l.putT(o.d, res, ty);
            },
            .ubfx_x, .ubfx_w, .sbfx_x, .sbfx_w => {
                const ty: Type = if (kd == .ubfx_x or kd == .sbfx_x) X else W;
                const bits: u8 = @intCast(ty.bits());
                const v = try l.src(o.n, ty);
                const res = if (kd == .ubfx_x or kd == .ubfx_w) blk: {
                    const s = try l.bin(.lshr, ty, v, try l.k(ty, o.sh));
                    if (o.sh + o.a >= bits) break :blk s;
                    break :blk try l.bin(.@"and", ty, s, try l.ones(ty, o.a));
                } else blk: {
                    // The field to the top, then arithmetic right.
                    const up = try l.bin(.shl, ty, v, try l.k(ty, bits - o.sh - o.a));
                    break :blk try l.bin(.ashr, ty, up, try l.k(ty, bits - o.a));
                };
                try l.putT(o.d, res, ty);
            },
            .ubfiz_x, .ubfiz_w, .sbfiz_x, .sbfiz_w => {
                const ty: Type = if (kd == .ubfiz_x or kd == .sbfiz_x) X else W;
                const bits: u8 = @intCast(ty.bits());
                const v = try l.src(o.n, ty);
                const field = if (kd == .ubfiz_x or kd == .ubfiz_w)
                    try l.bin(.@"and", ty, v, try l.ones(ty, o.a))
                else
                    try l.bin(.ashr, ty, try l.bin(.shl, ty, v, try l.k(ty, bits - o.a)), try l.k(ty, bits - o.a));
                try l.putT(o.d, try l.bin(.shl, ty, field, try l.k(ty, o.sh)), ty);
            },
            .bfxil_x, .bfxil_w => {
                const ty: Type = if (kd == .bfxil_x) X else W;
                const m = dec.ones(@intCast(o.a));
                const keep = try l.bin(.@"and", ty, try l.src(o.d, ty), try l.k(ty, ~m));
                const field = try l.bin(.@"and", ty, try l.bin(.lshr, ty, try l.src(o.n, ty), try l.k(ty, o.sh)), try l.k(ty, m));
                try l.putT(o.d, try l.bin(.@"or", ty, keep, field), ty);
            },
            .bfi_x, .bfi_w => {
                const ty: Type = if (kd == .bfi_x) X else W;
                const m = dec.ones(@intCast(o.a)) << @intCast(o.sh);
                const keep = try l.bin(.@"and", ty, try l.src(o.d, ty), try l.k(ty, ~m));
                const field = try l.bin(.@"and", ty, try l.bin(.shl, ty, try l.src(o.n, ty), try l.k(ty, o.sh)), try l.k(ty, m));
                try l.putT(o.d, try l.bin(.@"or", ty, keep, field), ty);
            },
            .extr_x, .extr_w => {
                const ty: Type = if (kd == .extr_x) X else W;
                const lo = try l.src(o.m, ty);
                if (o.sh == 0) return l.putT(o.d, lo, ty);
                const hi = try l.src(o.n, ty);
                const res = try l.bin(.@"or", ty, try l.bin(.lshr, ty, lo, try l.k(ty, o.sh)), try l.bin(.shl, ty, hi, try l.k(ty, ty.bits() - o.sh)));
                try l.putT(o.d, res, ty);
            },

            .mov_x => try l.put(o.d, try l.x(o.n)),
            .mov_w => try l.putT(o.d, try l.src(o.n, W), W),
            .and_sreg_x, .and_sreg_w, .bic_sreg_x, .bic_sreg_w, .orr_sreg_x, .orr_sreg_w, .orn_sreg_x, .orn_sreg_w, .eor_sreg_x, .eor_sreg_w, .eon_sreg_x, .eon_sreg_w, .ands_sreg_x, .ands_sreg_w, .bics_sreg_x, .bics_sreg_w => {
                const idx = @intFromEnum(kd) - @intFromEnum(Kind.and_sreg_x);
                const opcn = idx / 2;
                const ty: Type = if (idx % 2 == 0) X else W;
                const a = try l.src(o.n, ty);
                const m = try l.shifted(o.m, ty, o.x, o.sh);
                const res = switch (opcn) {
                    0, 6 => try l.bin(.@"and", ty, a, m),
                    1, 7 => try l.bin(.andn, ty, a, m),
                    2 => try l.bin(.@"or", ty, a, m),
                    3 => try l.bin(.@"or", ty, a, try b.un(.not, ty, m)),
                    4 => try l.bin(.xor, ty, a, m),
                    else => try l.bin(.xor, ty, a, try b.un(.not, ty, m)),
                };
                if (opcn >= 6) try l.logicFlags(res);
                try l.putT(o.d, res, ty);
            },
            .add_sreg_x, .add_sreg_w, .adds_sreg_x, .adds_sreg_w, .sub_sreg_x, .sub_sreg_w, .subs_sreg_x, .subs_sreg_w => {
                const idx = @intFromEnum(kd) - @intFromEnum(Kind.add_sreg_x);
                const ty: Type = if (idx % 2 == 0) X else W;
                try l.arith(ty, o.d, idx / 2, try l.src(o.n, ty), try l.shifted(o.m, ty, o.x, o.sh));
            },
            .add_ereg_x, .add_ereg_w, .adds_ereg_x, .adds_ereg_w, .sub_ereg_x, .sub_ereg_w, .subs_ereg_x, .subs_ereg_w => {
                const idx = @intFromEnum(kd) - @intFromEnum(Kind.add_ereg_x);
                const ty: Type = if (idx % 2 == 0) X else W;
                var m = try l.extended(o.m, o.x, o.sh);
                if (ty == W) m = try b.un(.trunc, W, m);
                try l.arith(ty, o.d, idx / 2, try l.src(o.n, ty), m);
            },
            .add_reg_x, .add_reg_w, .sub_reg_x, .sub_reg_w => {
                const ty: Type = if (kd == .add_reg_x or kd == .sub_reg_x) X else W;
                const op: u32 = if (kd == .sub_reg_x or kd == .sub_reg_w) 2 else 0;
                try l.arith(ty, o.d, op, try l.src(o.n, ty), try l.src(o.m, ty));
            },
            .adc_x, .adc_w, .adcs_x, .adcs_w, .sbc_x, .sbc_w, .sbcs_x, .sbcs_w => {
                const idx = @intFromEnum(kd) - @intFromEnum(Kind.adc_x);
                const ty: Type = if (idx % 2 == 0) X else W;
                const op = idx / 2; // 0 adc, 1 adcs, 2 sbc, 3 sbcs
                const a = try l.src(o.n, ty);
                const m = try l.src(o.m, ty);
                const c = try l.flags.carry(b, ty);
                // SBC is a + ~b + C.
                const m2 = if (op >= 2) try b.un(.not, ty, m) else m;
                const res = try l.bin(.add, ty, try l.bin(.add, ty, a, m2), c);
                if (op & 1 == 1 and !l.flags_dead) {
                    const f = try l.flags.get(b);
                    l.setFlags(try b.emit(.{ .op = if (op >= 2) .@"nzcv.sbc" else .@"nzcv.adc", .ty = .flags, .a = a, .b = m, .c = f }));
                }
                try l.putT(o.d, res, ty);
            },
            .ccmp_x, .ccmp_w => {
                if (l.flags_dead) return;
                const ty: Type = if (kd == .ccmp_x) X else W;
                const c = try l.flags.cond(b, @intCast(o.x));
                const a = try l.src(o.n, ty);
                const m = if (o.a & 1 == 1) try l.k(ty, o.imm) else try l.src(o.m, ty);
                const f = try b.flags(if (o.a & 2 != 0) .@"nzcv.add" else .@"nzcv.sub", a, m);
                const p = try b.un(.@"nzcv.pack", .i32, f);
                const sel = try b.emit(.{ .op = .select, .ty = .i32, .a = c, .b = p, .c = try l.k(.i32, @as(u64, o.sh) << 28) });
                l.setFlags(try b.un(.@"nzcv.unpack", .flags, sel));
            },
            .csel_x, .csel_w => {
                const ty: Type = if (kd == .csel_x) X else W;
                const c = try l.flags.cond(b, @intCast(o.x));
                const n = try l.src(o.n, ty);
                const m = try l.src(o.m, ty);
                const alt = switch (o.a) {
                    0 => m,
                    1 => try l.bin(.add, ty, m, try l.k(ty, 1)),
                    2 => try b.un(.not, ty, m),
                    else => try b.un(.neg, ty, m),
                };
                try l.putT(o.d, try b.emit(.{ .op = .select, .ty = ty, .a = c, .b = n, .c = alt }), ty);
            },
            .rbit_x, .rbit_w, .rev_x, .rev_w, .clz_x, .clz_w => {
                const ty: Type = switch (kd) {
                    .rbit_x, .rev_x, .clz_x => X,
                    else => W,
                };
                const op: ir.Op = switch (kd) {
                    .rbit_x, .rbit_w => .rbit,
                    .rev_x, .rev_w => .bswap,
                    else => .clz,
                };
                try l.putT(o.d, try b.un(op, ty, try l.src(o.n, ty)), ty);
            },
            .rev16_x, .rev16_w => {
                const ty: Type = if (kd == .rev16_x) X else W;
                const v = try l.src(o.n, ty);
                const m = try l.k(ty, 0x00ff00ff00ff00ff);
                const hi = try l.bin(.@"and", ty, try l.bin(.lshr, ty, v, try l.k(ty, 8)), m);
                const lo = try l.bin(.shl, ty, try l.bin(.@"and", ty, v, m), try l.k(ty, 8));
                try l.putT(o.d, try l.bin(.@"or", ty, hi, lo), ty);
            },
            .rev32_x => {
                // Each word byte-reversed: the whole reversed, words swapped.
                const r = try b.un(.bswap, X, try l.x(o.n));
                try l.put(o.d, try l.bin(.ror, X, r, try l.k(X, 32)));
            },
            .cls_x, .cls_w => {
                const ty: Type = if (kd == .cls_x) X else W;
                const v = try l.src(o.n, ty);
                const t = try l.bin(.@"and", ty, try l.bin(.xor, ty, try l.bin(.lshr, ty, v, try l.k(ty, 1)), v), try l.k(ty, ty.mask() >> 1));
                try l.putT(o.d, try l.bin(.sub, ty, try b.un(.clz, ty, t), try l.k(ty, 1)), ty);
            },
            .udiv_x, .udiv_w, .sdiv_x, .sdiv_w, .lslv_x, .lslv_w, .lsrv_x, .lsrv_w, .asrv_x, .asrv_w, .rorv_x, .rorv_w, .smulh, .umulh => {
                const idx = @intFromEnum(kd) - @intFromEnum(Kind.udiv_x);
                const ty: Type = if (kd == .smulh or kd == .umulh or idx % 2 == 0) X else W;
                const op: ir.Op = switch (kd) {
                    .udiv_x, .udiv_w => .udiv,
                    .sdiv_x, .sdiv_w => .sdiv,
                    .lslv_x, .lslv_w => .shl,
                    .lsrv_x, .lsrv_w => .lshr,
                    .asrv_x, .asrv_w => .ashr,
                    .rorv_x, .rorv_w => .ror,
                    .smulh => .mulhs,
                    else => .mulhu,
                };
                try l.putT(o.d, try l.bin(op, ty, try l.src(o.n, ty), try l.src(o.m, ty)), ty);
            },
            .madd_x, .madd_w, .msub_x, .msub_w => {
                const ty: Type = if (kd == .madd_x or kd == .msub_x) X else W;
                const p = try l.bin(.mul, ty, try l.src(o.n, ty), try l.src(o.m, ty));
                const a = try l.src(o.a, ty);
                const res = try l.bin(if (kd == .madd_x or kd == .madd_w) .add else .sub, ty, a, p);
                try l.putT(o.d, res, ty);
            },
            .smaddl, .smsubl, .umaddl, .umsubl => {
                const ext: ir.Op = if (kd == .smaddl or kd == .smsubl) .sext else .zext;
                const n = try b.un(ext, X, try l.src(o.n, W));
                const m = try b.un(ext, X, try l.src(o.m, W));
                const p = try l.bin(.mul, X, n, m);
                try l.put(o.d, try l.bin(if (kd == .smaddl or kd == .umaddl) .add else .sub, X, try l.x(o.a), p));
            },

            .mrs => {
                const sr = dec.sr;
                const v = switch (o.imm) {
                    sr.nzcv => try b.un(.zext, X, try l.flags.packed32(b)),
                    sr.fpcr => try b.un(.zext, X, try b.getreg(.i32, @offsetOf(Cpu, "fpcr"))),
                    sr.fpsr => try b.un(.zext, X, try b.getreg(.i32, @offsetOf(Cpu, "fpsr"))),
                    sr.tpidr_el0 => try b.getreg(X, @offsetOf(Cpu, "tpidr")),
                    sr.tpidrro_el0 => try b.getreg(X, @offsetOf(Cpu, "tpidrro")),
                    sr.cntfrq_el0 => try l.k(X, t0.cntfrq),
                    sr.ctr_el0 => try l.k(X, t0.ctr_el0),
                    sr.dczid_el0 => try l.k(X, t0.dczid_el0),
                    else => unreachable,
                };
                try l.put(o.d, v);
            },
            .msr => {
                const sr = dec.sr;
                const v = try l.x(o.n);
                switch (o.imm) {
                    sr.nzcv => l.setFlags(try b.un(.@"nzcv.unpack", .flags, try b.un(.trunc, W, v))),
                    sr.fpcr, sr.fpsr => {
                        const mask: u64 = if (o.imm == sr.fpcr) t0.fpcr_mask else t0.fpsr_mask;
                        const off: u64 = if (o.imm == sr.fpcr) @offsetOf(Cpu, "fpcr") else @offsetOf(Cpu, "fpsr");
                        try b.setreg(off, try l.bin(.@"and", W, try b.un(.trunc, W, v), try l.k(W, mask)));
                    },
                    sr.tpidr_el0 => try b.setreg(@offsetOf(Cpu, "tpidr"), v),
                    else => unreachable,
                }
            },

            .ldp_x, .ldp_w, .ldpsw, .stp_x, .stp_w, .ldp_vs, .ldp_vd, .ldp_vq, .stp_vs, .stp_vd, .stp_vq => try l.pair(in),
            .ldxr, .ldar => {
                try l.flush();
                const addr = try l.x(o.n);
                const acq = kd == .ldar or o.sh == 1;
                const v = try b.load(X, addr, .{ .size = @intCast(o.x), .aligned = true, .order = if (acq) .acquire else .plain }, in.pc);
                if (kd == .ldxr) {
                    try b.setreg(monOff("valid"), try l.k(.i8, 1));
                    try b.setreg(monOff("addr"), addr);
                    try b.setreg(monOff("size"), try l.k(.i8, @as(u64, 1) << @intCast(o.x)));
                    try b.setreg(monOff("lo"), v);
                    try b.setreg(monOff("hi"), try l.k(X, 0));
                }
                try l.put(o.d, v);
            },
            .stxr, .stxp => try l.storeExclusive(in),
            .stlr => {
                try l.flush();
                const addr = try l.x(o.n);
                try b.store(addr, try l.narrow(try l.x(o.m), @intCast(o.x)), .{ .size = @intCast(o.x), .aligned = true, .order = .release }, in.pc);
            },
            else => {
                if (single(kd)) |s| return l.singleMem(in, s);
                unreachable;
            },
        }
    }

    /// STXR, and STXP of two W registers, as T0 runs them: if the monitor
    /// holds this address and size, a compare-and-swap against the value
    /// LDXR saw (status 0 if it swapped); otherwise status 1, with no
    /// access, after the alignment check. Either way the monitor clears.
    /// It ends the current block: the rest of the instruction's block
    /// continues in a new one.
    fn storeExclusive(l: *L, in: Insn) !void {
        const o = in.op;
        const b = l.b;
        const is_pair = o.k == .stxp;
        const size: u3 = if (is_pair) 3 else @intCast(o.x);
        const bytes = @as(u64, 1) << size;
        const ty: Type = switch (size) {
            0 => .i8,
            1 => .i16,
            2 => .i32,
            else => .i64,
        };
        const addr = try l.x(o.n);
        const valid = try b.icmp(.ne, try b.getreg(.i8, monOff("valid")), try l.k(.i8, 0));
        const same_addr = try b.icmp(.eq, try b.getreg(.i64, monOff("addr")), addr);
        const same_size = try b.icmp(.eq, try b.getreg(.i8, monOff("size")), try l.k(.i8, bytes));
        const match = try l.bin(.@"and", .i1, valid, try l.bin(.@"and", .i1, same_addr, same_size));

        const ok = try b.block();
        const miss = try b.block();
        const fault = try b.block();
        const fail = try b.block();
        const join = try b.block();
        try l.retireAll();
        try b.brcond(match, ok, miss);

        // The monitor's address passed LDXR's alignment check at this
        // size, so the swap can't fault on alignment.
        b.begin(ok);
        const a2 = try b.getreg(.i64, regOff(o.n));
        const lo = try b.getreg(.i64, monOff("lo"));
        const exp = if (ty == .i64) lo else try b.un(.trunc, ty, lo);
        try clearMonitor(b);
        const v = try l.newValue(in, size, is_pair);
        const old = try b.cas(ty, a2, exp, v, .{ .size = size, .aligned = true, .order = .seq_cst }, in.pc);
        const status = try b.un(.zext, .i64, try b.icmp(.ne, old, exp));
        if (o.d != SINK and o.d != ZR) try b.setreg(regOff(o.d), status);
        try b.br(join);

        b.begin(miss);
        const ma = try b.bin(.@"and", .i64, try b.getreg(.i64, regOff(o.n)), try b.konst(.i64, bytes - 1));
        try b.brcond(try b.icmp(.ne, ma, try b.konst(.i64, 0)), fault, fail);

        // Misaligned: the alignment fault, before the monitor clears.
        b.begin(fault);
        const fa = try b.getreg(.i64, regOff(o.n));
        _ = try b.cas(ty, fa, try b.konst(ty, 0), try b.konst(ty, 0), .{ .size = size, .aligned = true, .order = .seq_cst }, in.pc);
        try b.exit(.@"exit.chain", in.pc); // not reached: the cas faults

        b.begin(fail);
        try clearMonitor(b);
        if (o.sh == 1) _ = try b.emit(.{ .op = .fence });
        if (o.d != SINK and o.d != ZR) try b.setreg(regOff(o.d), try b.konst(.i64, 1));
        try b.br(join);

        b.begin(join);
        l.regs = @splat(null);
        l.flags.clobber();
    }

    /// The value a store-exclusive writes, read in the current block.
    fn newValue(l: *L, in: Insn, size: u3, is_pair: bool) !Ref {
        const o = in.op;
        const b = l.b;
        if (is_pair) {
            const w0 = try b.un(.zext, .i64, try b.un(.trunc, .i32, try l.rawX(o.m)));
            const w1 = try b.bin(.shl, .i64, try l.rawX(o.a), try b.konst(.i64, 32));
            return b.bin(.@"or", .i64, w0, w1);
        }
        return l.narrow(try l.rawX(o.m), size);
    }

    /// A register read without the block's cache (in a block made inside
    /// an instruction).
    fn rawX(l: *L, s: u8) !Ref {
        if (s == ZR or s == SINK) return l.b.konst(.i64, 0);
        return l.b.getreg(.i64, regOff(s));
    }

    /// The low 2^size bytes of an i64, at the matching type.
    fn narrow(l: *L, v: Ref, size: u3) !Ref {
        const ty: Type = switch (size) {
            0 => .i8,
            1 => .i16,
            2 => .i32,
            else => return v,
        };
        return l.b.un(.trunc, ty, v);
    }

    fn singleMem(l: *L, in: Insn, s: Single) !void {
        const o = in.op;
        try l.flush();
        // The address and, for the writeback modes, the new base.
        var addr: Ref = undefined;
        var wb: ?Ref = null;
        if (!s.modes) {
            addr = try l.bin(.add, .i64, try l.x(o.n), try l.k(.i64, o.imm));
        } else switch (o.x) {
            1 => {
                addr = try l.x(o.n);
                wb = try l.bin(.add, .i64, addr, try l.k(.i64, o.imm));
            },
            3 => {
                addr = try l.bin(.add, .i64, try l.x(o.n), try l.k(.i64, o.imm));
                wb = addr;
            },
            4 => addr = try l.k(.i64, o.imm),
            5 => addr = try l.bin(.add, .i64, try l.x(o.n), try l.extended(o.m, o.a, o.sh)),
            else => addr = try l.bin(.add, .i64, try l.x(o.n), try l.k(.i64, o.imm)),
        }
        if (s.store) {
            try l.storeReg(o.d, s.v, s.size, addr, in.pc);
        } else {
            try l.loadReg(o.d, s, addr, in.pc);
        }
        if (wb) |v| try l.put(o.n, v);
    }

    /// Stores register `r` (general, or V if `v`) of 2^size bytes at addr.
    fn storeReg(l: *L, r: u8, v: bool, size: u3, addr: Ref, pc: u64) !void {
        const b = l.b;
        if (!v) return b.store(addr, try l.narrow(try l.x(r), size), .{ .size = size }, pc);
        const lo = try b.getreg(.i64, vOff(r));
        if (size < 4) return b.store(addr, try l.narrow(lo, size), .{ .size = size }, pc);
        const hi = try b.getreg(.i64, vOff(r) + 8);
        try b.store(addr, lo, .{ .size = 3 }, pc);
        try b.store(try l.bin(.add, .i64, addr, try l.k(.i64, 8)), hi, .{ .size = 3 }, pc);
    }

    /// The loaded value(s) for register `r`, not yet written: lo and, for
    /// a Q register, hi.
    const Loaded = struct { lo: Ref, hi: ?Ref = null };

    fn loadVal(l: *L, s: Single, addr: Ref, pc: u64) !Loaded {
        const b = l.b;
        if (s.size == 4) {
            const lo = try b.load(.i64, addr, .{ .size = 3 }, pc);
            const hi = try b.load(.i64, try l.bin(.add, .i64, addr, try l.k(.i64, 8)), .{ .size = 3 }, pc);
            return .{ .lo = lo, .hi = hi };
        }
        if (s.signed and s.to32) {
            return .{ .lo = try b.un(.zext, .i64, try b.load(.i32, addr, .{ .size = s.size, .signed = true }, pc)) };
        }
        return .{ .lo = try b.load(.i64, addr, .{ .size = s.size, .signed = s.signed }, pc) };
    }

    fn writeLoaded(l: *L, r: u8, v: bool, val: Loaded) !void {
        if (!v) return l.put(r, val.lo);
        try l.b.setreg(vOff(r), val.lo);
        try l.b.setreg(vOff(r) + 8, val.hi orelse try l.k(.i64, 0));
    }

    fn loadReg(l: *L, r: u8, s: Single, addr: Ref, pc: u64) !void {
        try l.writeLoaded(r, s.v, try l.loadVal(s, addr, pc));
    }

    fn pair(l: *L, in: Insn) !void {
        const o = in.op;
        const kd = o.k;
        try l.flush();
        const s: Single = switch (kd) {
            .ldp_x => .{ .size = 3 },
            .ldp_w => .{ .size = 2 },
            .ldpsw => .{ .size = 2, .signed = true },
            .stp_x => .{ .size = 3, .store = true },
            .stp_w => .{ .size = 2, .store = true },
            .ldp_vs => .{ .size = 2, .v = true },
            .ldp_vd => .{ .size = 3, .v = true },
            .ldp_vq => .{ .size = 4, .v = true },
            .stp_vs => .{ .size = 2, .v = true, .store = true },
            .stp_vd => .{ .size = 3, .v = true, .store = true },
            .stp_vq => .{ .size = 4, .v = true, .store = true },
            else => unreachable,
        };
        const base = try l.x(o.n);
        const addr = if (o.x == 1) base else try l.bin(.add, .i64, base, try l.k(.i64, o.imm));
        const addr2 = try l.bin(.add, .i64, addr, try l.k(.i64, @as(u64, 1) << s.size));
        if (s.store) {
            try l.storeReg(o.d, s.v, s.size, addr, in.pc);
            try l.storeReg(o.m, s.v, s.size, addr2, in.pc);
        } else {
            const v1 = try l.loadVal(s, addr, in.pc);
            const v2 = try l.loadVal(s, addr2, in.pc);
            try l.writeLoaded(o.d, s.v, v1);
            try l.writeLoaded(o.m, s.v, v2);
        }
        if (o.x == 1 or o.x == 3) try l.put(o.n, try l.bin(.add, .i64, base, try l.k(.i64, o.imm)));
    }

    fn condition(l: *L, o: dec.Op) !ir.Ref {
        const b = l.b;
        switch (o.k) {
            .cbz_x, .cbnz_x, .cbz_w, .cbnz_w => {
                const ty: Type = if (o.k == .cbz_x or o.k == .cbnz_x) .i64 else .i32;
                const v = try l.src(o.n, ty);
                return b.icmp(if (o.k == .cbz_x or o.k == .cbz_w) .eq else .ne, v, try l.k(ty, 0));
            },
            .tbz, .tbnz => {
                const bit = try l.bin(.@"and", .i64, try l.x(o.n), try l.k(.i64, @as(u64, 1) << @intCast(o.sh)));
                return b.icmp(if (o.k == .tbz) .eq else .ne, bit, try l.k(.i64, 0));
            },
            .bcond => return l.flags.cond(b, @intCast(o.x)),
            else => unreachable,
        }
    }
};

/// A load or store of one register: log2 of its size (4 for Q), and how.
const Single = struct {
    size: u3,
    signed: bool = false,
    /// A signed load to a W register.
    to32: bool = false,
    v: bool = false,
    store: bool = false,
    /// The _m kinds: the addressing mode is in x.
    modes: bool = false,
};

const single_specs = [_]Single{
    .{ .size = 3 }, // ldr_x
    .{ .size = 2 }, // ldr_w
    .{ .size = 0 }, // ldrb
    .{ .size = 1 }, // ldrh
    .{ .size = 0, .signed = true }, // ldrsb_x
    .{ .size = 0, .signed = true, .to32 = true }, // ldrsb_w
    .{ .size = 1, .signed = true }, // ldrsh_x
    .{ .size = 1, .signed = true, .to32 = true }, // ldrsh_w
    .{ .size = 2, .signed = true }, // ldrsw
    .{ .size = 3, .store = true }, // str_x
    .{ .size = 2, .store = true }, // str_w
    .{ .size = 0, .store = true }, // strb
    .{ .size = 1, .store = true }, // strh
    .{ .size = 0, .v = true }, // ldr_vb
    .{ .size = 1, .v = true },
    .{ .size = 2, .v = true },
    .{ .size = 3, .v = true },
    .{ .size = 4, .v = true }, // ldr_vq
    .{ .size = 0, .v = true, .store = true }, // str_vb
    .{ .size = 1, .v = true, .store = true },
    .{ .size = 2, .v = true, .store = true },
    .{ .size = 3, .v = true, .store = true },
    .{ .size = 4, .v = true, .store = true }, // str_vq
};

comptime {
    // The _o and _m kinds run in the same order as single_specs.
    const o0 = @intFromEnum(Kind.ldr_x_o);
    const m0 = @intFromEnum(Kind.ldr_x_m);
    std.debug.assert(@intFromEnum(Kind.str_vq_o) - o0 == single_specs.len - 1);
    std.debug.assert(m0 - o0 == single_specs.len);
    std.debug.assert(@intFromEnum(Kind.str_vq_m) - m0 == single_specs.len - 1);
    std.debug.assert(@intFromEnum(Kind.ldrsw_m) - m0 == 8 and @intFromEnum(Kind.strh_o) - o0 == 12);
    std.debug.assert(@intFromEnum(Kind.and_imm_x) + 7 == @intFromEnum(Kind.ands_imm_w));
    std.debug.assert(@intFromEnum(Kind.udiv_x) + 11 == @intFromEnum(Kind.rorv_w));
}

fn single(k: Kind) ?Single {
    const v = @intFromEnum(k);
    const o0 = @intFromEnum(Kind.ldr_x_o);
    const m0 = @intFromEnum(Kind.ldr_x_m);
    if (v >= o0 and v < m0) return single_specs[v - o0];
    if (v >= m0 and v < m0 + single_specs.len) {
        var s = single_specs[v - m0];
        s.modes = true;
        return s;
    }
    return null;
}

// ---------------------------------------------------------------- call.interp

/// ha64's `call.interp`: the handle is the instruction word; ctx.frontend
/// is the vCPU's T0 (*t0.Machine).
pub fn interp(c: *ctx_mod.Ctx, handle: u64, pc: u64) callconv(.c) u32 {
    const m: *t0.Machine = @ptrFromInt(@as(usize, @intCast(c.frontend)));
    const o = dec.decode(@truncate(handle), pc);
    switch (t0.step(m, &o, pc)) {
        .next => return 0,
        .jump => |t| {
            c.exit_pc = t;
            return @intFromEnum(ctx_mod.Exit.indirect);
        },
        .exit => switch (m.exit) {
            .syscall => {
                c.exit_pc = m.cpu.pc;
                return @intFromEnum(ctx_mod.Exit.svc);
            },
            .breakpoint => {
                c.exit_pc = pc;
                return @intFromEnum(ctx_mod.Exit.brk);
            },
            .interrupted => {
                c.exit_pc = pc;
                return @intFromEnum(ctx_mod.Exit.interrupted);
            },
            .fault => |f| {
                c.exit_pc = pc;
                c.exit_addr = f.addr;
                c.exit_info = @as(u64, @intFromEnum(f.access)) | (@as(u64, @intFromEnum(f.kind)) << 8) | (f.esr << 16);
                return @intFromEnum(if (f.esr >> 26 == t0.EC_UNKNOWN) ctx_mod.Exit.undef else ctx_mod.Exit.fault);
            },
        },
    }
}
