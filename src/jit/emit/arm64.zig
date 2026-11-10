//! IR to arm64 machine code.
//!
//! This is the spill-everything form: every value lives in its frame slot
//! (alloc.spillAll), and each operation loads its operands into scratch
//! registers, computes, and stores its result. Linear scan replaces the
//! loads and stores later without changing the lowering of each op.
//!
//! Registers: x19 holds the Ctx (ctx.arm64_ctx_reg); x0–x16 are scratch;
//! slot k is at [sp + 8k]. The function is a ctx.EntryFn.
//!
//! Pure ops this file doesn't lower call ir_eval.evalOpC, so the IR can
//! grow ahead of it.

const std = @import("std");
const ir = @import("../ir.zig");
const ir_eval = @import("../ir_eval.zig");
const ctx = @import("../ctx.zig");
const mem = @import("../../interp/mem.zig");
const alloc_mod = @import("../alloc.zig");
const emitter = @import("../emitter.zig");
const Op = ir.Op;
const Type = ir.Type;
const EmitError = emitter.EmitError;

pub const emitter_def: emitter.Emitter = .{ .name = "arm64", .emit = emit };

const CTX = ctx.arm64_ctx_reg;
const ZR = 31;
const SP = 31;

const Fixup = struct {
    pos: usize,
    kind: enum { b26, b19 },
    /// A block id, or `epilogue`.
    target: u32,
};
const epilogue = std.math.maxInt(u32);

const E = struct {
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    base: usize,
    fixups: std.ArrayList(Fixup) = .empty,

    fn put(e: *E, w: u32) !void {
        try e.out.appendSlice(e.gpa, std.mem.asBytes(&std.mem.nativeToLittle(u32, w)));
    }
    fn pos(e: *E) usize {
        return e.out.items.len - e.base;
    }
    fn patch(e: *E, at: usize, w: u32) void {
        std.mem.writeInt(u32, e.out.items[e.base + at ..][0..4], w, .little);
    }
    fn word(e: *E, at: usize) u32 {
        return std.mem.readInt(u32, e.out.items[e.base + at ..][0..4], .little);
    }

    /// Xd = imm, with MOVZ and MOVKs.
    fn movImm(e: *E, rd: u32, imm: u64) !void {
        try e.put(0xD2800000 | @as(u32, @as(u16, @truncate(imm))) << 5 | rd);
        var hw: u32 = 1;
        while (hw < 4) : (hw += 1) {
            const chunk: u16 = @truncate(imm >> @intCast(hw * 16));
            if (chunk != 0) try e.put(0xF2800000 | hw << 21 | @as(u32, chunk) << 5 | rd);
        }
    }
    fn ldrSlot(e: *E, rt: u32, slot: u32) !void {
        try e.put(0xF9400000 | slot << 10 | SP << 5 | rt);
    }
    fn strSlot(e: *E, rt: u32, slot: u32) !void {
        try e.put(0xF9000000 | slot << 10 | SP << 5 | rt);
    }
    /// LDR Xt, [x19, #off] (off a multiple of 8).
    fn ldrCtx(e: *E, rt: u32, off: u32) !void {
        try e.put(0xF9400000 | (off / 8) << 10 | CTX << 5 | rt);
    }
    fn strCtx(e: *E, rt: u32, off: u32) !void {
        try e.put(0xF9000000 | (off / 8) << 10 | CTX << 5 | rt);
    }
    fn mov(e: *E, rd: u32, rm: u32) !void {
        try e.put(0xAA0003E0 | rm << 16 | rd);
    }
    fn branch(e: *E, kind: @TypeOf(@as(Fixup, undefined).kind), base_word: u32, target: u32) !void {
        try e.fixups.append(e.gpa, .{ .pos = e.pos(), .kind = kind, .target = target });
        try e.put(base_word);
    }
    /// A forward branch within an op; returns where to patch.
    fn fwd(e: *E, base_word: u32) !usize {
        const p = e.pos();
        try e.put(base_word);
        return p;
    }
    /// Points the 19-bit branch at `at` to here.
    fn land19(e: *E, at: usize) void {
        const d: u32 = @intCast((e.pos() - at) / 4);
        e.patch(at, e.word(at) | (d & 0x7ffff) << 5);
    }
    fn land26(e: *E, at: usize) void {
        const d: u32 = @intCast((e.pos() - at) / 4);
        e.patch(at, e.word(at) | (d & 0x3ffffff));
    }
    /// On a path out: ctx.retired += n and ctx.budget -= n (the
    /// instructions the leaving op says completed). Uses x9 and x10 only.
    fn retireOn(e: *E, n: u32) !void {
        if (n == 0) return;
        try e.movImm(10, n);
        try e.ldrCtx(9, ctx.off.retired);
        try e.put(0x8B0A0129); // add x9, x9, x10
        try e.strCtx(9, ctx.off.retired);
        try e.ldrCtx(9, ctx.off.budget);
        try e.put(0xCB0A0129); // sub x9, x9, x10
        try e.strCtx(9, ctx.off.budget);
    }
    /// Sets exit_pc and leaves with `code` (in w0), counting `n` retired.
    fn leave(e: *E, code: ctx.Exit, pc: u64, n: u32) !void {
        try e.retireOn(n);
        try e.movImm(1, pc);
        try e.strCtx(1, ctx.off.exit_pc);
        try e.put(0x52800000 | @as(u32, @intFromEnum(code)) << 5); // movz w0, #code
        try e.branch(.b26, 0x14000000, epilogue);
    }
};

fn sf(t: Type) u32 {
    return if (t == .i64 or t == .flags) 0x8000_0000 else 0;
}

fn native32or64(t: Type) bool {
    return t == .i32 or t == .i64;
}

/// Register-form LDR/STR opcodes by access size, for [Xn, Xm].
const ldr_reg = [4]u32{ 0x38606800, 0x78606800, 0xB8606800, 0xF8606800 };
const str_reg = [4]u32{ 0x38206800, 0x78206800, 0xB8206800, 0xF8206800 };

fn sizeLog2(t: Type) ?u32 {
    return switch (t) {
        .i8 => 0,
        .i16 => 1,
        .i32 => 2,
        .i64, .flags => 3,
        else => null,
    };
}

/// arm64 conditions for icmp's predicates.
const pred_cond = [_]u32{ 0, 1, 3, 9, 8, 2, 11, 13, 12, 10 };

pub fn emit(gpa: std.mem.Allocator, r: *const ir.Region, a: *const alloc_mod.Allocation, out: *std.ArrayList(u8)) EmitError!emitter.Code {
    if (a.slots > 4095) return error.TooLarge;
    var e: E = .{ .gpa = gpa, .out = out, .base = out.items.len };
    defer e.fixups.deinit(gpa);
    const block_pos = try gpa.alloc(usize, r.blocks.items.len);
    defer gpa.free(block_pos);

    // Prologue.
    const frame: u32 = (a.slots * 8 + 15) & ~@as(u32, 15);
    try e.put(0xA9BE7BFD); // stp x29, x30, [sp, #-32]!
    try e.put(0xF9000BF3); // str x19, [sp, #16]
    try e.put(0x910003FD); // mov x29, sp
    try e.mov(CTX, 0);
    if (frame >> 12 != 0) try e.put(0xD1400000 | (frame >> 12) << 10 | SP << 5 | SP); // sub sp, sp, #hi, lsl 12
    if (frame & 0xfff != 0) try e.put(0xD1000000 | (frame & 0xfff) << 10 | SP << 5 | SP);

    // Blocks in id order; block 0 falls in from the prologue.
    for (r.blocks.items, 0..) |blk, bi| {
        block_pos[bi] = e.pos();
        for (blk.start..blk.start + blk.len) |idx| try lower(&e, r, a, idx);
    }

    // Epilogue: w0 holds the exit code.
    const epi = e.pos();
    try e.put(0x910003BF); // mov sp, x29
    try e.put(0xF9400BF3); // ldr x19, [sp, #16]
    try e.put(0xA8C27BFD); // ldp x29, x30, [sp], #32
    try e.put(0xD65F03C0); // ret

    for (e.fixups.items) |f| {
        const to = if (f.target == epilogue) epi else block_pos[f.target];
        const d: u32 = @bitCast(@as(i32, @intCast(@as(isize, @intCast(to)) - @as(isize, @intCast(f.pos)))) >> 2);
        const w = e.word(f.pos);
        e.patch(f.pos, switch (f.kind) {
            .b26 => w | (d & 0x3ffffff),
            .b19 => w | (d & 0x7ffff) << 5,
        });
    }
    return .{ .entry = 0 };
}

fn slotOf(a: *const alloc_mod.Allocation, ref: ir.Ref) u32 {
    return a.locs[ref].slot;
}

fn lower(e: *E, r: *const ir.Region, a: *const alloc_mod.Allocation, idx: usize) EmitError!void {
    const i = r.insts.items[idx];
    const ty = i.ty;
    const ta: Type = if (i.a != ir.none) r.insts.items[i.a].ty else .none;
    const dst: u32 = if (ty != .none) slotOf(a, @intCast(idx)) else 0;
    // Operands into x0, x1, x2.
    if (i.a != ir.none) try e.ldrSlot(0, slotOf(a, i.a));
    if (i.b != ir.none) try e.ldrSlot(1, slotOf(a, i.b));
    if (i.c != ir.none) try e.ldrSlot(2, slotOf(a, i.c));

    const s = sf(ty);
    switch (i.op) {
        .@"const" => try e.movImm(0, i.aux),
        .getreg, .setreg => {
            const t = if (i.op == .getreg) ty else ta;
            const sz = sizeLog2(t) orelse return error.Unsupported;
            try e.ldrCtx(9, ctx.off.cpu);
            try e.movImm(10, i.aux);
            if (i.op == .getreg)
                try e.put(ldr_reg[sz] | 10 << 16 | 9 << 5 | 0)
            else
                try e.put(str_reg[sz] | 10 << 16 | 9 << 5 | 0);
        },
        .add, .sub, .@"and", .@"or", .xor, .andn, .shl, .lshr, .ashr, .ror, .mul, .udiv, .sdiv => if (native32or64(ty)) {
            const base: u32 = switch (i.op) {
                .add => 0x0B000000,
                .sub => 0x4B000000,
                .@"and" => 0x0A000000,
                .@"or" => 0x2A000000,
                .xor => 0x4A000000,
                .andn => 0x0A200000,
                .shl => 0x1AC02000,
                .lshr => 0x1AC02400,
                .ashr => 0x1AC02800,
                .ror => 0x1AC02C00,
                .mul => 0x1B007C00, // madd with ra = zr
                .udiv => 0x1AC00800,
                .sdiv => 0x1AC00C00,
                else => unreachable,
            };
            try e.put(s | base | 1 << 16 | 0 << 5 | 0);
        } else try fallback(e, i, ta),
        .mulhu, .mulhs => if (ty == .i64) {
            try e.put((if (i.op == .mulhu) @as(u32, 0x9BC07C00) else 0x9B407C00) | 1 << 16 | 0);
        } else try fallback(e, i, ta),
        .neg => if (native32or64(ty)) try e.put(s | 0x4B000000 | 0 << 16 | ZR << 5 | 0) else try fallback(e, i, ta),
        .not => if (native32or64(ty)) try e.put(s | 0x2A200000 | 0 << 16 | ZR << 5 | 0) else try fallback(e, i, ta),
        .clz => if (native32or64(ty)) try e.put(s | 0x5AC01000) else try fallback(e, i, ta),
        .rbit => if (native32or64(ty)) try e.put(s | 0x5AC00000) else try fallback(e, i, ta),
        .bswap => if (ty == .i64) try e.put(0xDAC00C00) else if (ty == .i32) try e.put(0x5AC00800) else try fallback(e, i, ta),
        .zext => {}, // values are kept zero-extended
        .trunc => switch (ty) {
            .i1 => try e.put(0xD3400000), // ubfx x0, x0, #0, #1
            .i8 => try e.put(0xD3401C00),
            .i16 => try e.put(0xD3403C00),
            .i32 => try e.put(0x2A0003E0), // mov w0, w0
            .i64 => {},
            else => return error.Unsupported,
        },
        .sext => {
            const from = ta.bits() - 1;
            if (ty == .i64) {
                try e.put(0x93400000 | from << 10); // sbfm x0, x0, #0, #from
            } else if (ty == .i32) {
                try e.put(0x13000000 | from << 10); // sbfm w0, w0, #0, #from
            } else try fallback(e, i, ta);
        },
        .select => {
            try e.put(0xF100001F); // cmp x0, #0
            try e.put(0x9A821020); // csel x0, x1, x2, ne
        },
        .icmp => if (native32or64(ta)) {
            try e.put(sf(ta) | 0x6B000000 | 1 << 16 | 0 << 5 | ZR); // cmp
            try e.put(0x9A9F07E0 | (pred_cond[@intCast(i.aux)] ^ 1) << 12); // cset x0, cond
        } else try fallback(e, i, ta),
        .@"nzcv.add", .@"nzcv.sub", .@"nzcv.logic", .@"nzcv.adc", .@"nzcv.sbc" => {
            const s2 = sf(ta);
            if (i.op == .@"nzcv.adc" or i.op == .@"nzcv.sbc") try e.put(0xD51B4202); // msr nzcv, x2
            try e.put(s2 | ZR | switch (i.op) {
                .@"nzcv.add" => @as(u32, 0x2B000000) | 1 << 16, // adds zr, x0, x1
                .@"nzcv.sub" => 0x6B000000 | 1 << 16, // subs (cmp)
                .@"nzcv.logic" => 0x6A000000 | 0 << 16, // ands zr, x0, x0 (tst)
                .@"nzcv.adc" => 0x3A000000 | 1 << 16,
                .@"nzcv.sbc" => 0x7A000000 | 1 << 16,
                else => unreachable,
            });
            try e.put(0xD53B4200); // mrs x0, nzcv
        },
        .@"nzcv.cond" => if (i.aux >= 14) {
            try e.movImm(0, 1);
        } else {
            try e.put(0xD51B4200); // msr nzcv, x0
            try e.put(0x9A9F07E0 | @as(u32, @intCast(i.aux ^ 1)) << 12); // cset x0, cond
        },
        .@"nzcv.pack", .@"nzcv.unpack" => {
            try e.put(0xD35C7C00); // lsr x0, x0, #28 (ubfm x0, x0, #28, #31 keeps 4 bits)
            try e.put(0xD3641C00 | 0); // lsl x0, x0, #28 (ubfm #36, #3)
        },
        .load, .store => try memOp(e, i),
        .fence => try e.put(switch (i.aux) {
            1 => @as(u32, 0xD50339BF),
            2 => 0xD5033ABF,
            else => 0xD5033BBF,
        }),
        .@"call.interp" => {
            try e.mov(0, CTX);
            try e.movImm(1, r.handles.items[@intCast(i.aux)]);
            try e.movImm(2, i.aux2);
            try e.ldrCtx(16, ctx.off.interp);
            try e.put(0xD63F0200); // blr x16
            if (i.retired == 0) {
                try e.branch(.b19, 0x35000000, epilogue); // cbnz w0, epilogue
            } else {
                const on = try e.fwd(0x34000000); // cbz w0, on
                try e.retireOn(i.retired);
                try e.branch(.b26, 0x14000000, epilogue);
                e.land19(on);
            }
        },
        .@"call.helper" => {
            try e.mov(3, 2);
            try e.mov(2, 1);
            try e.mov(1, 0);
            try e.mov(0, CTX);
            try e.ldrCtx(16, ctx.off.helpers);
            try e.movImm(17, i.aux * 8);
            try e.put(0xF8716A10); // ldr x16, [x16, x17]
            try e.put(0xD63F0200); // blr x16
        },
        .poll => {
            try e.put(0xB9400000 | (ctx.off.exit_request / 4) << 10 | CTX << 5 | 0); // ldr w0, [x19, #exit_request]
            const req = try e.fwd(0x35000000); // cbnz w0, out
            try e.ldrCtx(0, ctx.off.budget);
            try e.put(0xF100001F); // cmp x0, #0
            const ok = try e.fwd(0x5400000C); // b.gt cont
            e.land19(req);
            try e.leave(.interrupted, i.aux, i.retired);
            e.land19(ok);
        },
        .retire => {
            try e.movImm(1, i.aux);
            try e.ldrCtx(0, ctx.off.retired);
            try e.put(0x8B010000); // add x0, x0, x1
            try e.strCtx(0, ctx.off.retired);
            try e.ldrCtx(0, ctx.off.budget);
            try e.put(0xCB010000); // sub x0, x0, x1
            try e.strCtx(0, ctx.off.budget);
        },
        .br => try e.branch(.b26, 0x14000000, @intCast(i.aux)),
        .brcond => {
            try e.branch(.b19, 0xB5000000, @intCast(i.aux)); // cbnz x0, then
            try e.branch(.b26, 0x14000000, @intCast(i.aux2));
        },
        .@"exit.chain" => try e.leave(.chain, i.aux, i.retired),
        .@"exit.svc" => try e.leave(.svc, i.aux, i.retired),
        .@"exit.brk" => try e.leave(.brk, i.aux, i.retired),
        .@"exit.undef" => try e.leave(.undef, i.aux, i.retired),
        .@"exit.indirect" => {
            try e.retireOn(i.retired);
            try e.strCtx(0, ctx.off.exit_pc);
            try e.put(0x52800000 | @as(u32, @intFromEnum(ctx.Exit.indirect)) << 5);
            try e.branch(.b26, 0x14000000, epilogue);
        },
        else => if (i.op.isPure()) try fallback(e, i, ta) else return error.Unsupported,
    }
    if (ty != .none) try e.strSlot(0, dst);
}

/// x0 = ir_eval.evalOpC(code, x0, x1, x2, aux).
fn fallback(e: *E, i: ir.Inst, ta: Type) !void {
    try e.mov(3, 2);
    try e.mov(2, 1);
    try e.mov(1, 0);
    try e.movImm(0, ir_eval.fallbackCode(i.op, i.ty, ta));
    try e.movImm(4, i.aux);
    try e.movImm(16, @intFromPtr(&ir_eval.evalOpC));
    try e.put(0xD63F0200); // blr x16
}

/// A load or store through the TLB, with the slow path out of line.
/// x0 is the address, x1 the value to store.
fn memOp(e: *E, i: ir.Inst) !void {
    const f: ir.MemFlags = @bitCast(i.aux);
    if (f.aligned or f.order != .plain) return error.Unsupported;
    const store = i.op == .store;
    const n = f.bytes();
    if (!store and f.signed and i.ty != .i64 and i.ty != .i32) return error.Unsupported;
    try e.ldrCtx(9, ctx.off.tlb);
    try e.put(0xD34CFC0A); // lsr x10, x0, #12
    try e.put(0xD3401D4B); // ubfx x11, x10, #0, #8
    try e.put(0x8B0B1129); // add x9, x9, x11, lsl #4
    if (store) try e.put(0x91400529); // add x9, x9, #1, lsl #12 (the write table)
    try e.put(0xF940012C); // ldr x12, [x9]
    try e.put(0xF940052D); // ldr x13, [x9, #8]
    try e.put(0xEB0A019F); // cmp x12, x10
    const miss1 = try e.fwd(0x54000001); // b.ne slow
    try e.put(0xD3402C0E); // ubfx x14, x0, #0, #12
    try e.put(0xF10001DF | (mem.page_size - n) << 10); // cmp x14, #(page - n)
    const miss2 = try e.fwd(0x54000008); // b.hi slow
    if (store) {
        try e.put(str_reg[f.size] | 13 << 16 | 0 << 5 | 1); // str x1, [x0, x13]
    } else {
        try e.put(ldr_reg[f.size] | 13 << 16 | 0 << 5 | 0); // ldr x0, [x0, x13]
    }
    const join = try e.fwd(0x14000000); // b join
    // Slow path.
    e.land19(miss1);
    e.land19(miss2);
    if (store) try e.mov(3, 1);
    try e.mov(1, 0);
    try e.mov(0, CTX);
    try e.movImm(2, f.size);
    try e.ldrCtx(16, if (store) ctx.off.slow_store else ctx.off.slow_load);
    try e.put(0xD63F0200); // blr x16
    const ok = try e.fwd(0x34000000); // cbz w0, ok
    try e.retireOn(i.retired);
    try e.movImm(1, i.aux2);
    try e.strCtx(1, ctx.off.exit_pc);
    try e.branch(.b26, 0x14000000, epilogue);
    e.land19(ok);
    if (!store) try e.ldrCtx(0, ctx.off.scratch);
    e.land26(join);
    if (!store and f.signed) {
        const from = n * 8 - 1;
        if (i.ty == .i64) try e.put(0x93400000 | from << 10) else try e.put(0x13000000 | from << 10);
    }
}

// ---------------------------------------------------------------- tests

const testexec = @import("../testexec.zig");
const cases = @import("cases.zig");

test "emitted code matches ir_eval on the shared cases" {
    if (!testexec.supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const all = try cases.generate(gpa);
    defer cases.free(gpa, all);
    const env = try gpa.create(cases.Env);
    defer gpa.destroy(env);
    for (all, 0..) |c, n| {
        var r = try cases.parse(gpa, c);
        defer r.deinit(gpa);
        var a = try alloc_mod.spillAll(gpa, &r);
        defer a.deinit(gpa);
        var code: std.ArrayList(u8) = .empty;
        defer code.deinit(gpa);
        const out = try emit(gpa, &r, &a, &code);
        const x = try testexec.load(code.items);
        defer x.deinit();
        const want = try env.evalCase(gpa, &r, c);
        const cx = env.reset(c);
        const got = env.result(@enumFromInt(x.entry(out.entry)(cx)));
        cases.expectSame(n, c, want, got) catch |err| return err;
    }
}
