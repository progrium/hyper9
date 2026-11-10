//! ha64's front end: arm64 instructions to IR.
//!
//! This is the tracer-bullet lifter, over the spike decoder in
//! src/interp/a64/spike.zig. It lifts the handful of classes a counted
//! loop needs (MOVZ and friends, ADD and SUB, SUBS and ADDS, LDR and STR
//! with an immediate offset, B, B.cond, CBZ and CBNZ, SVC), and runs every
//! other non-branch instruction through `call.interp`. A branch it doesn't
//! lift ends the region before it, so T0 runs it.
//!
//! Regions: a linear scan from the entry PC that continues through
//! conditional branches and stops after B or SVC, before an unlifted
//! branch, or at the limits. Branch targets inside the scanned range start
//! blocks; a backward one is a loop, with a `poll` at its head.

const std = @import("std");
const ir = @import("../ir.zig");
const ctx_mod = @import("../ctx.zig");
const fe = @import("../frontend.zig");
const t0 = @import("../../interp/a64/spike.zig");

const Kind = t0.Kind;
const Cpu = t0.Cpu;

pub const frontend: fe.Frontend = .{ .name = "ha64", .flags = .nzcv, .lift = lift, .interp = interp };

fn regOff(n: u8) u64 {
    return @offsetOf(Cpu, "r") + @as(u64, n) * 8;
}
const nzcv_off = @offsetOf(Cpu, "nzcv");
const ZR = 31;

const Class = enum { lifted, interp, branch_cond, branch, stop, unlifted_branch };

fn classify(k: Kind) Class {
    return switch (k) {
        .movi, .add_imm_x, .add_imm_w, .subs_imm_x, .subs_imm_w, .adds_imm_x, .adds_imm_w, .add_reg_x, .add_reg_w, .sub_reg_x, .sub_reg_w, .ldr_x_o, .ldr_w_o, .str_x_o, .str_w_o, .nop => .lifted,
        .bcond_0, .bcond_1, .bcond_2, .bcond_3, .bcond_4, .bcond_5, .bcond_6, .bcond_7, .bcond_8, .bcond_9, .bcond_10, .bcond_11, .bcond_12, .bcond_13, .cbz_x, .cbz_w, .cbnz_x, .cbnz_w => .branch_cond,
        .bcond_14, .bcond_15, .b => .branch,
        .svc => .stop,
        .bl, .br, .blr, .ret, .tbz, .tbnz, .brk, .undef, .next_page => .unlifted_branch,
        else => .interp,
    };
}

const Insn = struct { pc: u64, word: u32, op: t0.Op };

pub fn lift(b: *ir.Builder, src: fe.Source, pc: u64, limits: fe.Limits) fe.LiftError!void {
    var buf: [512]Insn = undefined;
    var n: usize = 0;
    const max = @min(limits.max_insns, buf.len);
    const last_page = (pc >> 12) + limits.max_pages - 1;
    var p = pc;
    scan: while (n < max and p >> 12 <= last_page) : (p += 4) {
        var word: [4]u8 = undefined;
        if (src.readAll(p, &word) != 4) break;
        const w = std.mem.readInt(u32, &word, .little);
        const o = t0.decode(w, p);
        switch (classify(o.k)) {
            .unlifted_branch => break :scan,
            .branch, .stop => {
                buf[n] = .{ .pc = p, .word = w, .op = o };
                n += 1;
                break :scan;
            },
            else => {
                buf[n] = .{ .pc = p, .word = w, .op = o };
                n += 1;
            },
        }
    }
    const insns = buf[0..n];
    const end = pc + 4 * n; // the first PC past the scanned range

    // Block leaders: the entry, in-range branch targets, and the
    // instructions after conditional branches.
    var leader: [513]bool = @splat(false);
    var loop_head: [513]bool = @splat(false);
    leader[0] = true;
    leader[n] = true; // the fall-out point, if anything reaches it
    for (insns, 0..) |in, i| {
        const c = classify(in.op.k);
        if (c == .branch_cond or c == .branch) {
            const t = in.op.imm;
            if (t >= pc and t < end and t & 3 == 0) {
                const ti: usize = @intCast((t - pc) / 4);
                leader[ti] = true;
                if (ti <= i) loop_head[ti] = true;
            }
            leader[i + 1] = true;
        }
    }
    loop_head[0] = true; // the entry polls too, so a chained loop sees kicks

    // One block per leader in [0, n], in order; block ids follow.
    var block_of: [513]ir.BlockId = undefined;
    var nblocks: u32 = 0;
    for (0..n + 1) |i| if (leader[i]) {
        block_of[i] = try b.block();
        nblocks += 1;
    };

    var i: usize = 0;
    while (i <= n) {
        const start = i;
        b.begin(block_of[start]);
        if (start == n) {
            // Fall-out: leave for the next PC.
            try b.exit(.@"exit.chain", end);
            break;
        }
        if (loop_head[start]) try b.poll(insns[start].pc);
        var count: u64 = 0;
        while (true) {
            const in = insns[i];
            count += 1;
            i += 1;
            switch (classify(in.op.k)) {
                .lifted => try liftOne(b, in),
                .interp => try b.interp(in.word, in.pc),
                .stop => {
                    try b.retire(count);
                    try b.exit(.@"exit.svc", in.pc + 4);
                    break;
                },
                .branch => {
                    try b.retire(count);
                    try jumpTo(b, in.op.imm, pc, end, &block_of);
                    break;
                },
                .branch_cond => {
                    try b.retire(count);
                    const c = try condition(b, in);
                    const taken = try target(b, in.op.imm, pc, end, &block_of);
                    try b.brcond(c, taken, block_of[i]);
                    // `taken` may be a new exit block: fill it.
                    try fillExit(b, taken, in.op.imm);
                    break;
                },
                .unlifted_branch => unreachable,
            }
            if (leader[i]) {
                try b.retire(count);
                try b.br(block_of[i]);
                break;
            }
        }
        while (i <= n and !leader[i]) i += 1;
    }
}

/// A block id for branching to guest PC `t`: its block if it's in the
/// region, else a new block that will hold an exit.
fn target(b: *ir.Builder, t: u64, pc: u64, end: u64, block_of: []const ir.BlockId) !ir.BlockId {
    if (t >= pc and t < end and t & 3 == 0) return block_of[@intCast((t - pc) / 4)];
    return b.block();
}

fn fillExit(b: *ir.Builder, id: ir.BlockId, t: u64) !void {
    if (b.r.blocks.items[id].begun) return;
    b.begin(id);
    try b.exit(.@"exit.chain", t);
}

fn jumpTo(b: *ir.Builder, t: u64, pc: u64, end: u64, block_of: []const ir.BlockId) !void {
    if (t >= pc and t < end and t & 3 == 0) return b.br(block_of[@intCast((t - pc) / 4)]);
    try b.exit(.@"exit.chain", t);
}

fn get(b: *ir.Builder, n: u8, ty: ir.Type) !ir.Ref {
    if (n == ZR) return b.konst(ty, 0);
    return b.getreg(ty, regOff(n));
}

/// Writes a 64-bit register; a 32-bit result is zero-extended first.
fn put(b: *ir.Builder, d: u8, v: ir.Ref, ty: ir.Type) !void {
    const v64 = if (ty == .i32) try b.un(.zext, .i64, v) else v;
    try b.setreg(regOff(d), v64);
}

fn setFlags(b: *ir.Builder, f: ir.Ref) !void {
    try b.setreg(nzcv_off, try b.un(.@"nzcv.pack", .i32, f));
}

fn liftOne(b: *ir.Builder, in: Insn) !void {
    const o = in.op;
    switch (o.k) {
        .nop => {},
        .movi => try b.setreg(regOff(o.d), try b.konst(.i64, o.imm)),
        .add_imm_x, .add_imm_w, .adds_imm_x, .adds_imm_w, .subs_imm_x, .subs_imm_w => {
            const ty: ir.Type = switch (o.k) {
                .add_imm_x, .adds_imm_x, .subs_imm_x => .i64,
                else => .i32,
            };
            const x = try get(b, o.n, ty);
            const y = try b.konst(ty, o.imm);
            const sub = o.k == .subs_imm_x or o.k == .subs_imm_w;
            const res = try b.bin(if (sub) .sub else .add, ty, x, y);
            if (o.k != .add_imm_x and o.k != .add_imm_w)
                try setFlags(b, try b.flags(if (sub) .@"nzcv.sub" else .@"nzcv.add", x, y));
            try put(b, o.d, res, ty);
        },
        .add_reg_x, .add_reg_w, .sub_reg_x, .sub_reg_w => {
            const ty: ir.Type = if (o.k == .add_reg_x or o.k == .sub_reg_x) .i64 else .i32;
            const x = try get(b, o.n, ty);
            const y = try get(b, o.m, ty);
            const sub = o.k == .sub_reg_x or o.k == .sub_reg_w;
            try put(b, o.d, try b.bin(if (sub) .sub else .add, ty, x, y), ty);
        },
        .ldr_x_o, .ldr_w_o, .str_x_o, .str_w_o => {
            const wide = o.k == .ldr_x_o or o.k == .str_x_o;
            const base = try get(b, o.n, .i64);
            const addr = try b.bin(.add, .i64, base, try b.konst(.i64, o.imm));
            const f: ir.MemFlags = .{ .size = if (wide) 3 else 2 };
            const ty: ir.Type = if (wide) .i64 else .i32;
            if (o.k == .ldr_x_o or o.k == .ldr_w_o) {
                try put(b, o.d, try b.load(ty, addr, f, in.pc), ty);
            } else {
                try b.store(addr, try get(b, o.d, ty), f, in.pc);
            }
        },
        else => unreachable,
    }
}

fn condition(b: *ir.Builder, in: Insn) !ir.Ref {
    const o = in.op;
    switch (o.k) {
        .cbz_x, .cbnz_x, .cbz_w, .cbnz_w => {
            const ty: ir.Type = if (o.k == .cbz_x or o.k == .cbnz_x) .i64 else .i32;
            const v = try get(b, o.n, ty);
            const zero = try b.konst(ty, 0);
            return b.icmp(if (o.k == .cbz_x or o.k == .cbz_w) .eq else .ne, v, zero);
        },
        else => {
            const cc: u4 = @intCast(@intFromEnum(o.k) - @intFromEnum(Kind.bcond_0));
            const f = try b.un(.@"nzcv.unpack", .flags, try b.getreg(.i32, nzcv_off));
            return b.cond(.@"nzcv.cond", f, cc);
        },
    }
}

/// ha64's `call.interp`: the handle is the instruction word; ctx.frontend
/// is the T0 memory (*t0.Mem) the stand-in T0 reads and writes through.
pub fn interp(c: *ctx_mod.Ctx, handle: u64, pc: u64) callconv(.c) u32 {
    const cpu = c.cpuPtr(Cpu);
    const m: *t0.Mem = @ptrFromInt(@as(usize, @intCast(c.frontend)));
    const o = t0.decode(@truncate(handle), pc);
    switch (t0.step(cpu, m, &o, pc)) {
        .next => return 0,
        .jump => |t| {
            c.exit_pc = t;
            return @intFromEnum(ctx_mod.Exit.indirect);
        },
        .exit => |e| switch (e) {
            .syscall => {
                c.exit_pc = cpu.pc;
                return @intFromEnum(ctx_mod.Exit.svc);
            },
            .interrupted => {
                c.exit_pc = pc;
                return @intFromEnum(ctx_mod.Exit.interrupted);
            },
            .fault => |f| {
                c.exit_pc = pc;
                c.exit_addr = f.addr;
                c.exit_info = @as(u64, switch (f.access) {
                    .read => 0,
                    .write => 1,
                    .exec => 2,
                }) | (f.esr << 16);
                return @intFromEnum(if (f.esr >> 26 == t0.EC_UNKNOWN) ctx_mod.Exit.undef else ctx_mod.Exit.fault);
            },
        },
    }
}
