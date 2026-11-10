//! IR to a wasm module, for the browser host (and Node).
//!
//! One region is one module with one function, exported as "run": a
//! ctx.EntryFn taking the Ctx's address in linear memory. Batching regions
//! into modules, tail calls between them, and a shared function table come
//! later; the IR doesn't change for them.
//!
//! Control flow is a dispatch loop: a `loop` around nested `block`s and a
//! `br_table` on the current block's index, so any CFG the IR can express
//! lowers without restructuring. Every value is an i64 local (the
//! spill-everything allocation's slot k is local 1+k).
//!
//! Imports, all from "env", provided by the module that owns memory (h9.wasm
//! in the browser):
//!
//! | name | type | is |
//! | --- | --- | --- |
//! | memory | memory | linear memory with Ctx, the Cpu, the TLB, and guest RAM |
//! | eval | (i64 code, i64 a, i64 b, i64 c, i64 aux) -> i64 | ir_eval.evalOpC |
//! | slow_load | (i32 ctx, i64 va, i32 size_log2) -> i32 | mem.SlowLoadFn |
//! | slow_store | (i32 ctx, i64 va, i32 size_log2, i64 v) -> i32 | mem.SlowStoreFn |
//! | interp | (i32 ctx, i64 handle, i64 pc) -> i32 | ctx.InterpFn |
//! | helper | (i32 ctx, i64 index, i64 a, i64 b, i64 c) -> i64 | the helper table |

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

pub const emitter_def: emitter.Emitter = .{ .name = "wasm", .emit = emit };

const F_EVAL = 0;
const F_SLOW_LOAD = 1;
const F_SLOW_STORE = 2;
const F_INTERP = 3;
const F_HELPER = 4;

const I32 = 0x7F;
const I64 = 0x7E;

const W = struct {
    gpa: std.mem.Allocator,
    b: std.ArrayList(u8) = .empty,

    fn byte(w: *W, x: u8) !void {
        try w.b.append(w.gpa, x);
    }
    fn bytes(w: *W, x: []const u8) !void {
        try w.b.appendSlice(w.gpa, x);
    }
    fn uleb(w: *W, v0: u64) !void {
        var v = v0;
        while (true) {
            const x: u8 = @truncate(v & 0x7f);
            v >>= 7;
            if (v == 0) return w.byte(x);
            try w.byte(x | 0x80);
        }
    }
    fn sleb(w: *W, v0: i64) !void {
        var v = v0;
        while (true) {
            const x: u8 = @truncate(@as(u64, @bitCast(v)) & 0x7f);
            v >>= 7;
            if ((v == 0 and x & 0x40 == 0) or (v == -1 and x & 0x40 != 0)) return w.byte(x);
            try w.byte(x | 0x80);
        }
    }
    fn i64c(w: *W, v: u64) !void {
        try w.byte(0x42);
        try w.sleb(@bitCast(v));
    }
    fn i32c(w: *W, v: i32) !void {
        try w.byte(0x41);
        try w.sleb(v);
    }
    fn get(w: *W, l: u32) !void {
        try w.byte(0x20);
        try w.uleb(l);
    }
    fn set(w: *W, l: u32) !void {
        try w.byte(0x21);
        try w.uleb(l);
    }
    fn tee(w: *W, l: u32) !void {
        try w.byte(0x22);
        try w.uleb(l);
    }
    /// A memory instruction with alignment hint 0 and `offset`.
    fn memop(w: *W, opcode: u8, offset: u64) !void {
        try w.byte(opcode);
        try w.byte(0);
        try w.uleb(offset);
    }
    fn call(w: *W, f: u32) !void {
        try w.byte(0x10);
        try w.uleb(f);
    }
    /// A section: id, then its contents' length, then the contents.
    fn section(w: *W, id: u8, body: []const u8) !void {
        try w.byte(id);
        try w.uleb(body.len);
        try w.bytes(body);
    }
};

const Locals = struct {
    slots: u32,
    fn val(_: Locals, slot: u32) u32 {
        return 1 + slot;
    }
    fn blk(l: Locals) u32 {
        return 1 + l.slots;
    }
    fn tmp(l: Locals) u32 {
        return 2 + l.slots;
    }
    fn ent(l: Locals) u32 {
        return 3 + l.slots;
    }
    fn code(l: Locals) u32 {
        return 4 + l.slots;
    }
};

pub fn emit(gpa: std.mem.Allocator, r: *const ir.Region, a: *const alloc_mod.Allocation, out: *std.ArrayList(u8)) EmitError!emitter.Code {
    var body: W = .{ .gpa = gpa };
    defer body.b.deinit(gpa);
    const L: Locals = .{ .slots = a.slots };

    // Locals: the values, then $blk (i32), $tmp (i64), $ent and $code (i32).
    try body.uleb(4);
    try body.uleb(a.slots);
    try body.byte(I64);
    try body.uleb(1);
    try body.byte(I32);
    try body.uleb(1);
    try body.byte(I64);
    try body.uleb(2);
    try body.byte(I32);

    const n: u32 = @intCast(r.blocks.items.len);
    try body.bytes(&.{ 0x03, 0x40 }); // loop
    for (0..n) |_| try body.bytes(&.{ 0x02, 0x40 }); // block
    try body.get(L.blk());
    try body.byte(0x0E); // br_table
    try body.uleb(n);
    for (0..n) |k| try body.uleb(k);
    try body.uleb(n - 1);
    for (r.blocks.items, 0..) |blk, k| {
        try body.byte(0x0B); // end: block k's body follows
        const depth: u32 = @intCast(n - 1 - k); // to the loop
        for (blk.start..blk.start + blk.len) |idx| try lower(&body, r, a, L, idx, depth);
    }
    try body.byte(0x0B); // end loop
    try body.byte(0x00); // unreachable
    try body.byte(0x0B); // end function

    var m: W = .{ .gpa = gpa };
    defer m.b.deinit(gpa);
    try m.bytes(&.{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 });

    var sec: W = .{ .gpa = gpa };
    defer sec.b.deinit(gpa);
    // Types.
    const types = [_][]const u8{
        &.{ 1, I32, 1, I32 }, // run
        &.{ 5, I64, I64, I64, I64, I64, 1, I64 }, // eval
        &.{ 3, I32, I64, I32, 1, I32 }, // slow_load
        &.{ 4, I32, I64, I32, I64, 1, I32 }, // slow_store
        &.{ 3, I32, I64, I64, 1, I32 }, // interp
        &.{ 5, I32, I64, I64, I64, I64, 1, I64 }, // helper
    };
    try sec.uleb(types.len);
    for (types) |t| {
        try sec.byte(0x60);
        try sec.bytes(t);
    }
    try m.section(1, sec.b.items);
    // Imports.
    sec.b.clearRetainingCapacity();
    const imports = [_]struct { []const u8, u32 }{ .{ "eval", 1 }, .{ "slow_load", 2 }, .{ "slow_store", 3 }, .{ "interp", 4 }, .{ "helper", 5 } };
    try sec.uleb(imports.len + 1);
    try name(&sec, "env");
    try name(&sec, "memory");
    try sec.bytes(&.{ 0x02, 0x00, 0x00 }); // memory, min 0 pages
    for (imports) |imp| {
        try name(&sec, "env");
        try name(&sec, imp[0]);
        try sec.byte(0x00);
        try sec.uleb(imp[1]);
    }
    try m.section(2, sec.b.items);
    // Functions: one, of type 0, numbered after the imports.
    try m.section(3, &.{ 1, 0 });
    // Exports.
    sec.b.clearRetainingCapacity();
    try sec.uleb(1);
    try name(&sec, "run");
    try sec.byte(0x00);
    try sec.uleb(imports.len);
    try m.section(7, sec.b.items);
    // Code.
    sec.b.clearRetainingCapacity();
    try sec.uleb(1);
    try sec.uleb(body.b.items.len);
    try sec.bytes(body.b.items);
    try m.section(10, sec.b.items);

    try out.appendSlice(gpa, m.b.items);
    return .{ .entry = 0 };
}

fn name(w: *W, s: []const u8) !void {
    try w.uleb(s.len);
    try w.bytes(s);
}

/// Pushes operand `ref` (i64, zero 0 if none).
fn operand(w: *W, a: *const alloc_mod.Allocation, L: Locals, ref: ir.Ref) !void {
    if (ref == ir.none) return w.i64c(0);
    try w.get(L.val(a.locs[ref].slot));
}

/// Pushes the i32 Cpu address from ctx.cpu.
fn cpuAddr(w: *W) !void {
    try w.get(0);
    try w.memop(0x28, ctx.off.cpu); // i32.load
}

const load_op = [_]u8{ 0x31, 0x33, 0x35, 0x29 }; // i64.load8_u, 16_u, 32_u, i64.load
const store_op = [_]u8{ 0x3C, 0x3D, 0x3E, 0x37 }; // i64.store8, 16, 32, i64.store

fn sizeLog2(t: Type) ?u32 {
    return switch (t) {
        .i8 => 0,
        .i16 => 1,
        .i32 => 2,
        .i64, .flags => 3,
        else => null,
    };
}

/// Sets exit_pc to the i64 on the stack (or `pc`) and returns `code`.
fn leave(w: *W, code: ctx.Exit, pc: ?u64, value: ?u32) !void {
    try w.get(0);
    if (value) |l| try w.get(l) else try w.i64c(pc.?);
    try w.memop(0x37, ctx.off.exit_pc);
    try w.i32c(@intCast(@intFromEnum(code)));
    try w.byte(0x0F); // return
}

fn lower(w: *W, r: *const ir.Region, a: *const alloc_mod.Allocation, L: Locals, idx: usize, depth: u32) EmitError!void {
    const i = r.insts.items[idx];
    const ty = i.ty;
    const ta: Type = if (i.a != ir.none) r.insts.items[i.a].ty else .none;
    const A = struct {
        fn op(wr: *W, al: *const alloc_mod.Allocation, l: Locals, ref: ir.Ref) !void {
            return operand(wr, al, l, ref);
        }
    };
    switch (i.op) {
        .@"const" => try w.i64c(i.aux),
        .getreg => {
            const sz = sizeLog2(ty) orelse return error.Unsupported;
            try cpuAddr(w);
            try w.memop(load_op[sz], i.aux);
        },
        .setreg => {
            const sz = sizeLog2(ta) orelse return error.Unsupported;
            try cpuAddr(w);
            try A.op(w, a, L, i.a);
            try w.memop(store_op[sz], i.aux);
            return;
        },
        .add, .sub, .mul, .@"and", .@"or", .xor, .shl, .lshr, .ashr, .ror, .rol, .andn => if (ty == .i64 or ty == .i32) {
            const wide = ty == .i64;
            try A.op(w, a, L, i.a);
            if (!wide) try w.byte(0xA7); // i32.wrap_i64
            try A.op(w, a, L, i.b);
            if (!wide) try w.byte(0xA7);
            if (i.op == .andn) {
                if (wide) try w.i64c(std.math.maxInt(u64)) else try w.i32c(-1);
                try w.byte(if (wide) 0x85 else 0x73); // xor
            }
            const op64: u8 = switch (i.op) {
                .add => 0x7C,
                .sub => 0x7D,
                .mul => 0x7E,
                .@"and", .andn => 0x83,
                .@"or" => 0x84,
                .xor => 0x85,
                .shl => 0x86,
                .ashr => 0x87,
                .lshr => 0x88,
                .rol => 0x89,
                .ror => 0x8A,
                else => unreachable,
            };
            // The i32 opcodes are in the same order, 0x12 lower.
            try w.byte(if (wide) op64 else op64 - 0x12);
            if (!wide) try w.byte(0xAD); // i64.extend_i32_u
        } else try fallback(w, a, L, i, ta),
        .icmp => if (ta == .i64 or ta == .i32) {
            const wide = ta == .i64;
            try A.op(w, a, L, i.a);
            if (!wide) try w.byte(0xA7);
            try A.op(w, a, L, i.b);
            if (!wide) try w.byte(0xA7);
            // eq ne lt_u le_u gt_u ge_u lt_s le_s gt_s ge_s
            const ops64 = [_]u8{ 0x51, 0x52, 0x54, 0x58, 0x56, 0x5A, 0x53, 0x57, 0x55, 0x59 };
            const op = ops64[@intCast(i.aux)];
            try w.byte(if (wide) op else op - 0x0B);
            try w.byte(0xAD);
        } else try fallback(w, a, L, i, ta),
        .zext => try A.op(w, a, L, i.a),
        .trunc => {
            try A.op(w, a, L, i.a);
            if (ty != .i64) {
                try w.i64c(ty.mask());
                try w.byte(0x83);
            }
        },
        .sext => {
            try A.op(w, a, L, i.a);
            try w.byte(switch (ta) {
                .i8 => 0xC2,
                .i16 => 0xC3,
                .i32 => 0xC4,
                else => return error.Unsupported,
            });
            if (ty != .i64) {
                try w.i64c(ty.mask());
                try w.byte(0x83);
            }
        },
        .select => {
            try A.op(w, a, L, i.b);
            try A.op(w, a, L, i.c);
            try A.op(w, a, L, i.a);
            try w.byte(0xA7);
            try w.byte(0x1B);
        },
        .@"nzcv.add", .@"nzcv.sub" => try nzcv(w, a, L, i, ta),
        .@"nzcv.pack", .@"nzcv.unpack" => {
            try A.op(w, a, L, i.a);
            try w.i64c(0xf000_0000);
            try w.byte(0x83);
        },
        .load, .store => {
            try memOp(w, a, L, i);
            if (i.op == .store) return;
        },
        .fence => return, // one thread per memory in the browser
        .@"call.interp" => {
            try w.get(0);
            try w.i64c(r.handles.items[@intCast(i.aux)]);
            try w.i64c(i.aux2);
            try w.call(F_INTERP);
            try w.tee(L.code());
            try w.bytes(&.{ 0x04, 0x40 }); // if
            try w.get(L.code());
            try w.byte(0x0F);
            try w.byte(0x0B);
            return;
        },
        .@"call.helper" => {
            try w.get(0);
            try w.i64c(i.aux);
            try A.op(w, a, L, i.a);
            try A.op(w, a, L, i.b);
            try A.op(w, a, L, i.c);
            try w.call(F_HELPER);
            if (ty == .none) {
                try w.byte(0x1A); // drop
                return;
            }
        },
        .poll => {
            try w.get(0);
            try w.memop(0x28, ctx.off.exit_request);
            try w.get(0);
            try w.memop(0x29, ctx.off.budget);
            try w.i64c(0);
            try w.byte(0x57); // i64.le_s
            try w.byte(0x72); // i32.or
            try w.bytes(&.{ 0x04, 0x40 });
            try leave(w, .interrupted, i.aux, null);
            try w.byte(0x0B);
            return;
        },
        .retire => {
            for ([_]struct { u32, u8 }{ .{ ctx.off.retired, 0x7C }, .{ ctx.off.budget, 0x7D } }) |f| {
                try w.get(0);
                try w.get(0);
                try w.memop(0x29, f[0]);
                try w.i64c(i.aux);
                try w.byte(f[1]);
                try w.memop(0x37, f[0]);
            }
            return;
        },
        .br => {
            try w.i32c(@intCast(i.aux));
            try w.set(L.blk());
            try w.byte(0x0C);
            try w.uleb(depth);
            return;
        },
        .brcond => {
            try A.op(w, a, L, i.a);
            try w.byte(0xA7);
            try w.bytes(&.{ 0x04, 0x40 });
            try w.i32c(@intCast(i.aux));
            try w.set(L.blk());
            try w.byte(0x05); // else
            try w.i32c(@intCast(i.aux2));
            try w.set(L.blk());
            try w.byte(0x0B);
            try w.byte(0x0C);
            try w.uleb(depth);
            return;
        },
        .@"exit.chain" => return leave(w, .chain, i.aux, null),
        .@"exit.svc" => return leave(w, .svc, i.aux, null),
        .@"exit.brk" => return leave(w, .brk, i.aux, null),
        .@"exit.undef" => return leave(w, .undef, i.aux, null),
        .@"exit.indirect" => return leave(w, .indirect, null, L.val(a.locs[i.a].slot)),
        else => if (i.op.isPure()) try fallback(w, a, L, i, ta) else return error.Unsupported,
    }
    try w.set(L.val(a.locs[idx].slot));
}

fn fallback(w: *W, a: *const alloc_mod.Allocation, L: Locals, i: ir.Inst, ta: Type) !void {
    try w.i64c(ir_eval.fallbackCode(i.op, i.ty, ta));
    try operand(w, a, L, i.a);
    try operand(w, a, L, i.b);
    try operand(w, a, L, i.c);
    try w.i64c(i.aux);
    try w.call(F_EVAL);
}

/// NZCV of a + b or a - b, eagerly, as ir_eval packs it.
fn nzcv(w: *W, a: *const alloc_mod.Allocation, L: Locals, i: ir.Inst, ta: Type) !void {
    const bits: u64 = ta.bits();
    const m = ta.mask();
    const sub = i.op == .@"nzcv.sub";
    const va = L.val(a.locs[i.a].slot);
    const vb = L.val(a.locs[i.b].slot);
    const t = L.tmp();
    // t = (a op b) & mask
    try w.get(va);
    try w.get(vb);
    try w.byte(if (sub) 0x7D else 0x7C);
    try w.i64c(m);
    try w.byte(0x83);
    try w.set(t);
    // N
    try w.get(t);
    try w.i64c(bits - 1);
    try w.byte(0x88);
    try w.i64c(31);
    try w.byte(0x86);
    // Z
    try w.get(t);
    try w.byte(0x50); // i64.eqz
    try w.byte(0xAD);
    try w.i64c(30);
    try w.byte(0x86);
    try w.byte(0x84);
    // C: no borrow (a >= b), or a carry (t < a)
    if (sub) {
        try w.get(va);
        try w.get(vb);
        try w.byte(0x5A); // ge_u
    } else {
        try w.get(t);
        try w.get(va);
        try w.byte(0x54); // lt_u
    }
    try w.byte(0xAD);
    try w.i64c(29);
    try w.byte(0x86);
    try w.byte(0x84);
    // V: sub ((a^b)&(a^t)), add ((a^t)&(b^t)), top bit
    try w.get(va);
    try w.get(if (sub) vb else t);
    try w.byte(0x85);
    try w.get(if (sub) va else vb);
    try w.get(t);
    try w.byte(0x85);
    try w.byte(0x83);
    try w.i64c(bits - 1);
    try w.byte(0x88);
    try w.i64c(1);
    try w.byte(0x83);
    try w.i64c(28);
    try w.byte(0x86);
    try w.byte(0x84);
}

fn memOp(w: *W, a: *const alloc_mod.Allocation, L: Locals, i: ir.Inst) !void {
    const f: ir.MemFlags = @bitCast(i.aux);
    if (f.aligned or f.order != .plain) return error.Unsupported;
    const store = i.op == .store;
    const n = f.bytes();
    const va = L.val(a.locs[i.a].slot);
    // ent = tlb + ((va >> 12) & 255) * 16, in the read or write table
    try w.get(0);
    try w.memop(0x28, ctx.off.tlb);
    try w.get(va);
    try w.i64c(mem.page_shift);
    try w.byte(0x88);
    try w.byte(0xA7);
    try w.i32c(mem.entries - 1);
    try w.byte(0x71);
    try w.i32c(4);
    try w.byte(0x74);
    try w.byte(0x6A);
    if (store) {
        try w.i32c(mem.tlb_write_off);
        try w.byte(0x6A);
    }
    try w.set(L.ent());
    // hit = tag == va >> 12 && (va & 0xfff) <= page - n
    try w.get(L.ent());
    try w.memop(0x29, 0);
    try w.get(va);
    try w.i64c(mem.page_shift);
    try w.byte(0x88);
    try w.byte(0x51);
    try w.get(va);
    try w.i64c(mem.page_size - 1);
    try w.byte(0x83);
    try w.i64c(mem.page_size - n);
    try w.byte(0x58); // le_u
    try w.byte(0x71); // i32.and
    try w.bytes(&.{ 0x04, if (store) 0x40 else I64 }); // if
    // Fast path: host = (va + delta) as i32.
    try w.get(va);
    try w.get(L.ent());
    try w.memop(0x29, 8);
    try w.byte(0x7C);
    try w.byte(0xA7);
    if (store) {
        try operand(w, a, L, i.b);
        try w.memop(store_op[f.size], 0);
    } else try w.memop(load_op[f.size], 0);
    try w.byte(0x05); // else: the slow path
    try w.get(0);
    try w.get(va);
    try w.i32c(@intCast(f.size));
    if (store) {
        try operand(w, a, L, i.b);
        try w.call(F_SLOW_STORE);
    } else try w.call(F_SLOW_LOAD);
    try w.tee(L.code());
    try w.bytes(&.{ 0x04, 0x40 });
    try w.get(0);
    try w.i64c(i.aux2);
    try w.memop(0x37, ctx.off.exit_pc);
    try w.get(L.code());
    try w.byte(0x0F);
    try w.byte(0x0B);
    if (!store) {
        try w.get(0);
        try w.memop(0x29, ctx.off.scratch);
    }
    try w.byte(0x0B); // end if; a load leaves its value
    if (store) return;
    if (f.signed) {
        try w.byte(switch (f.size) {
            0 => 0xC2,
            1 => 0xC3,
            2 => 0xC4,
            else => 0x01, // nop: already 64 bits
        });
        if (i.ty != .i64) {
            try w.i64c(i.ty.mask());
            try w.byte(0x83);
        }
    }
}
