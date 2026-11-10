//! IR to x86-64 machine code.
//!
//! Registers come from regalloc.zig, as in emit/arm64.zig: values in
//! host registers (or frame slots when they run out; a v128 always has a
//! slot pair), and the region's most used guest register-file fields
//! ("chunks") pinned to host registers, written back to the Cpu only
//! when dirty, and only where guest state must be exact: at exits, before
//! call.interp and call.helper (which reload every chunk after), and on a
//! slow path's fault exit. Each operation still loads its operands into
//! rax (a), rcx (b), and rdx (c), computes into rax, and moves that to its
//! value's register or slot.
//!
//! Fixed registers: rbx the Ctx (ctx.x64_ctx_reg), rbp the frame. rax,
//! rcx, rdx, r10, r11, and xmm0 to xmm2 are scratch. Values take rsi, rdi,
//! r8, r9, and whatever of r12 to r15 no chunk has; chunks take r12 to r15,
//! which survive the slow paths' calls. A call saves the live values in
//! caller-saved registers in a save area of the frame.
//!
//! The frame, from rbp down: the caller's return address above, then the
//! saved rbp, rbx, r12 to r15 (and rsi and rdi on Win64, where they're
//! callee-saved), then `sub rsp, frame`. From rsp up: 48 bytes of outgoing
//! argument space (the Win64 shadow space and a fifth argument), 40 bytes
//! where a call's arguments are staged before they go to the ABI's
//! registers, 48 for evalExtC's operands, the call save area, then the
//! value slots. Calls follow SysV, or Win64 on Windows.
//!
//! Chaining (cache.zig's contract, as emit/arm64.zig): `exit.chain` writes
//! back, drops the frame back to the saved registers, then has its site, a
//! `jmp rel32` with the rel32 4-byte aligned, which falls through to the
//! exit. A linked site jumps to the target's chain entry, which is past
//! the target's pushes (every region saves the same registers), so the
//! frame shape carries over, and which loads the target's chunks. The exit
//! sets ctx.exit_info to the site's address. `exit.indirect` looks the
//! target up in the jump cache (ctx.jump) inline and, on a hit, leaves the
//! same way for the target's chain entry.
//!
//! Pure ops this file doesn't lower call ir_eval.evalOpC.

const std = @import("std");
const builtin = @import("builtin");
const ir = @import("../ir.zig");
const ir_eval = @import("../ir_eval.zig");
const ctx = @import("../ctx.zig");
const mem = @import("../../interp/mem.zig");
const alloc_mod = @import("../alloc.zig");
const regalloc = @import("../regalloc.zig");
const emitter = @import("../emitter.zig");
const Op = ir.Op;
const Type = ir.Type;
const EmitError = emitter.EmitError;

pub const emitter_def: emitter.Emitter = .{ .name = "x86-64", .emit = emit };

const win64 = builtin.os.tag == .windows;
/// SSE2 is every x86-64's; SSSE3 and SSE4.1 only where the build targets
/// them (the host's own CPU for native builds).
const ssse3 = builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .ssse3);
const sse41 = builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .sse4_1);

// Registers.
const RAX = 0;
const RCX = 1;
const RDX = 2;
const RBX = 3;
const RSP = 4;
const RBP = 5;
const RSI = 6;
const RDI = 7;
const R8 = 8;
const R9 = 9;
const R10 = 10;
const R11 = 11;
const R12 = 12;
const R13 = 13;
const R14 = 14;
const R15 = 15;
const CTX = ctx.x64_ctx_reg;

const arg_regs: []const u8 = if (win64) &.{ RCX, RDX, R8, R9 } else &.{ RDI, RSI, RDX, RCX, R8 };
const outgoing = 48;
const staging = outgoing;
/// evalExtC's operands and result: a, b, and c, 16 bytes each.
const io_base = staging + 40;
/// Where a call keeps the live values of caller-saved registers.
const save_base = io_base + 48;
const slots_base = save_base + 8 * 16;

/// The callee-saved registers every region pushes after rbp, in order.
const saved_regs: []const u8 = if (win64) &.{ RBX, R12, R13, R14, R15, RSI, RDI } else &.{ RBX, R12, R13, R14, R15 };
/// Bytes from rbp down to the last push: rsp at the chain entry is rbp
/// less this.
const saved_bytes: u8 = 8 * saved_regs.len;
/// Registers a call may clobber, of those regalloc hands out.
const caller_saved_mask: u64 = if (win64) (1 << R8) | (1 << R9) else (1 << RSI) | (1 << RDI) | (1 << R8) | (1 << R9);

pub const host: regalloc.Host = .{
    .regs = &.{ RSI, RDI, R8, R9, R12, R13, R14, R15 },
    .pin_regs = &.{ R15, R14, R13, R12 },
    .max_pinned = 4,
    .callee_saved = ((1 << R12) | (1 << R13) | (1 << R14) | (1 << R15)) | (if (win64) (1 << RSI) | (1 << RDI) else 0),
};

// Condition codes.
const CC = struct {
    const o = 0;
    const no = 1;
    const b = 2;
    const ae = 3;
    const e = 4;
    const ne = 5;
    const be = 6;
    const a = 7;
    const s = 8;
    const ns = 9;
    const l = 0xc;
    const ge = 0xd;
    const le = 0xe;
    const g = 0xf;
};

/// icmp's predicates as x86 conditions.
const pred_cc = [_]u8{ CC.e, CC.ne, CC.b, CC.be, CC.a, CC.ae, CC.l, CC.le, CC.g, CC.ge };

/// arm64 conditions as x86 conditions over flags built with CF = !C.
const nzcv_cc = [14]u8{ CC.e, CC.ne, CC.ae, CC.b, CC.s, CC.ns, CC.o, CC.no, CC.a, CC.be, CC.ge, CC.l, CC.g, CC.le };

const epilogue = std.math.maxInt(u32);

const Fixup = struct { pos: usize, target: u32 };

const E = struct {
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    base: usize,
    fixups: std.ArrayList(Fixup) = .empty,
    code: emitter.Code = .{},
    r: *const ir.Region,
    p: *const regalloc.Plan,
    /// The block and instruction being lowered.
    block: ir.BlockId = 0,
    idx: usize = 0,
    /// The chunks that may be dirty here.
    dirty: regalloc.ChunkSet = 0,

    fn pos(e: *E) usize {
        return e.out.items.len - e.base;
    }
    fn b(e: *E, v: u8) !void {
        try e.out.append(e.gpa, v);
    }
    fn bs(e: *E, v: []const u8) !void {
        try e.out.appendSlice(e.gpa, v);
    }
    fn d32(e: *E, v: u32) !void {
        try e.bs(std.mem.asBytes(&std.mem.nativeToLittle(u32, v)));
    }
    fn q64(e: *E, v: u64) !void {
        try e.bs(std.mem.asBytes(&std.mem.nativeToLittle(u64, v)));
    }
    fn patch32(e: *E, at: usize, v: u32) void {
        std.mem.writeInt(u32, e.out.items[e.base + at ..][0..4], v, .little);
    }

    /// A REX prefix if it's needed (or forced by `w`).
    fn rex(e: *E, w: bool, reg: u8, index: u8, base: u8) !void {
        const v: u8 = 0x40 | (@as(u8, @intFromBool(w)) << 3) | ((reg >> 3) << 2) | ((index >> 3) << 1) | (base >> 3);
        if (v != 0x40) try e.b(v);
    }

    /// op reg, rm (register direct).
    fn rr(e: *E, w: bool, opc: []const u8, reg: u8, dst: u8) !void {
        try e.rex(w, reg, 0, dst);
        try e.bs(opc);
        try e.b(0xc0 | ((reg & 7) << 3) | (dst & 7));
    }

    /// op reg, [base + disp].
    fn rm(e: *E, w: bool, opc: []const u8, reg: u8, base: u8, disp: i32) !void {
        try e.rex(w, reg, 0, base);
        try e.bs(opc);
        try e.modrmMem(reg, base, disp);
    }

    /// Like `rm` with a 16-bit operand-size prefix.
    fn rm16(e: *E, opc: []const u8, reg: u8, base: u8, disp: i32) !void {
        try e.b(0x66);
        try e.rm(false, opc, reg, base, disp);
    }

    fn modrmMem(e: *E, reg: u8, base: u8, disp: i32) !void {
        const short = disp >= -128 and disp <= 127;
        const mode: u8 = if (disp == 0 and (base & 7) != RBP) 0 else if (short) 1 else 2;
        try e.b((mode << 6) | ((reg & 7) << 3) | (base & 7));
        if ((base & 7) == RSP) try e.b(0x24);
        switch (mode) {
            1 => try e.b(@bitCast(@as(i8, @intCast(disp)))),
            2 => try e.d32(@bitCast(disp)),
            else => {},
        }
    }

    fn mov(e: *E, dst: u8, src: u8) !void {
        if (dst != src) try e.rr(true, &.{0x89}, src, dst);
    }
    fn load(e: *E, dst: u8, base: u8, disp: i32) !void {
        try e.rm(true, &.{0x8b}, dst, base, disp);
    }
    fn store(e: *E, base: u8, disp: i32, src: u8) !void {
        try e.rm(true, &.{0x89}, src, base, disp);
    }
    fn ldSlot(e: *E, dst: u8, slot: u32) !void {
        try e.load(dst, RSP, @intCast(slots_base + slot * 8));
    }
    fn stSlot(e: *E, slot: u32, src: u8) !void {
        try e.store(RSP, @intCast(slots_base + slot * 8), src);
    }
    /// `dst` = value `v`, from its register or slot.
    fn ldVal(e: *E, dst: u8, v: ir.Ref) !void {
        switch (e.p.locs[v]) {
            .reg => |x| try e.mov(dst, @intCast(x)),
            .slot => |s| try e.ldSlot(dst, s),
            .none => unreachable,
        }
    }
    /// Value `v` = `src`.
    fn stVal(e: *E, v: ir.Ref, src: u8) !void {
        switch (e.p.locs[v]) {
            .reg => |x| try e.mov(@intCast(x), src),
            .slot => |s| try e.stSlot(s, src),
            .none => {},
        }
    }
    /// A v128 value's slot pair.
    fn vslot(e: *E, v: ir.Ref) u32 {
        return e.p.locs[v].slot;
    }

    // ---- chunks and calls

    fn chunkAccess(e: *E, k: usize, to_cpu: bool) !void {
        const c = e.p.chunks[k];
        const reg: u8 = @intCast(c.reg);
        const disp: i32 = @intCast(c.off);
        if (to_cpu) switch (c.bytes) {
            1 => try e.rm(false, &.{0x88}, reg, R10, disp),
            2 => try e.rm16(&.{0x89}, reg, R10, disp),
            4 => try e.rm(false, &.{0x89}, reg, R10, disp),
            else => try e.rm(true, &.{0x89}, reg, R10, disp),
        } else switch (c.bytes) {
            1 => try e.rm(false, &.{ 0x0f, 0xb6 }, reg, R10, disp),
            2 => try e.rm(false, &.{ 0x0f, 0xb7 }, reg, R10, disp),
            4 => try e.rm(false, &.{0x8b}, reg, R10, disp),
            else => try e.rm(true, &.{0x8b}, reg, R10, disp),
        }
    }
    /// Loads every chunk from the Cpu. Uses r10.
    fn loadChunks(e: *E) !void {
        if (e.p.chunks.len == 0) return;
        try e.ldCtx(R10, ctx.off.cpu);
        for (0..e.p.chunks.len) |k| try e.chunkAccess(k, false);
    }
    /// Stores the chunks in `set` to the Cpu. Uses r10.
    fn writeback(e: *E, set: regalloc.ChunkSet) !void {
        if (set == 0) return;
        try e.ldCtx(R10, ctx.off.cpu);
        for (0..e.p.chunks.len) |k| {
            if (set & (@as(regalloc.ChunkSet, 1) << @intCast(k)) != 0) try e.chunkAccess(k, true);
        }
    }
    /// The caller-saved registers holding values a call at the current
    /// instruction must keep.
    fn saveMask(e: *E) u64 {
        return e.p.liveAcross(e.r, e.block, e.idx) & caller_saved_mask;
    }
    fn saveRegs(e: *E, m: u64) !void {
        for (0..16) |x| if (m & (@as(u64, 1) << @intCast(x)) != 0) try e.store(RSP, @intCast(save_base + 8 * x), @intCast(x));
    }
    fn restoreRegs(e: *E, m: u64) !void {
        for (0..16) |x| if (m & (@as(u64, 1) << @intCast(x)) != 0) try e.load(@intCast(x), RSP, @intCast(save_base + 8 * x));
    }
    fn ldCtx(e: *E, dst: u8, off: u32) !void {
        try e.load(dst, CTX, @intCast(off));
    }
    fn stCtx(e: *E, off: u32, src: u8) !void {
        try e.store(CTX, @intCast(off), src);
    }

    fn movImm(e: *E, dst: u8, imm: u64) !void {
        if (imm == 0) {
            try e.rr(false, &.{0x31}, dst, dst); // xor r32, r32
        } else if (imm <= std.math.maxInt(u32)) {
            try e.rex(false, 0, 0, dst);
            try e.b(0xb8 + (dst & 7));
            try e.d32(@intCast(imm));
        } else if (@as(i64, @bitCast(imm)) >= std.math.minInt(i32) and @as(i64, @bitCast(imm)) < 0) {
            try e.rr(true, &.{0xc7}, 0, dst);
            try e.d32(@truncate(imm));
        } else {
            try e.rex(true, 0, 0, dst);
            try e.b(0xb8 + (dst & 7));
            try e.q64(imm);
        }
    }

    /// op r/m, imm32 (sign-extended): /n of 0x81.
    fn aluImm(e: *E, w: bool, n: u8, dst: u8, imm: i32) !void {
        try e.rr(w, &.{0x81}, n, dst);
        try e.d32(@bitCast(imm));
    }

    /// op qword [base+disp], imm32: /n of 0x81.
    fn aluMemImm(e: *E, n: u8, base: u8, disp: i32, imm: i32) !void {
        try e.rm(true, &.{0x81}, n, base, disp);
        try e.d32(@bitCast(imm));
    }

    fn shiftImm(e: *E, w: bool, n: u8, dst: u8, by: u8) !void {
        try e.rr(w, &.{0xc1}, n, dst);
        try e.b(by);
    }

    fn setcc(e: *E, cc: u8) !void {
        try e.bs(&.{ 0x0f, 0x90 + cc, 0xc0 }); // setcc al
        try e.bs(&.{ 0x0f, 0xb6, 0xc0 }); // movzx eax, al
    }

    /// A rel32 jump (cc null: jmp) to a block or the epilogue.
    fn jmpTo(e: *E, cc: ?u8, target: u32) !void {
        if (cc) |c| try e.bs(&.{ 0x0f, 0x80 + c }) else try e.b(0xe9);
        try e.fixups.append(e.gpa, .{ .pos = e.pos(), .target = target });
        try e.d32(0);
    }
    /// A forward rel32 jump within an op; `land` it.
    fn fwd(e: *E, cc: ?u8) !usize {
        if (cc) |c| try e.bs(&.{ 0x0f, 0x80 + c }) else try e.b(0xe9);
        const p = e.pos();
        try e.d32(0);
        return p;
    }
    fn land(e: *E, at: usize) void {
        e.patch32(at, @bitCast(@as(i32, @intCast(@as(isize, @intCast(e.pos())) - @as(isize, @intCast(at + 4))))));
    }

    /// ctx.retired += n, ctx.budget -= n. No registers.
    fn retireOn(e: *E, n: u64) !void {
        if (n == 0) return;
        if (n > std.math.maxInt(i32)) {
            try e.movImm(R10, n);
            try e.rm(true, &.{0x01}, R10, CTX, ctx.off.retired); // add [retired], r10
            try e.rm(true, &.{0x29}, R10, CTX, ctx.off.budget); // sub [budget], r10
            return;
        }
        try e.aluMemImm(0, CTX, ctx.off.retired, @intCast(n));
        try e.aluMemImm(5, CTX, ctx.off.budget, @intCast(n));
    }

    /// Sets exit_pc and leaves with `code`, counting `n` retired.
    fn leave(e: *E, code: ctx.Exit, pc: u64, n: u64) !void {
        try e.writeback(e.dirty);
        try e.retireOn(n);
        try e.movImm(RAX, pc);
        try e.stCtx(ctx.off.exit_pc, RAX);
        try e.movImm(RAX, @intFromEnum(code));
        try e.jmpTo(null, epilogue);
    }

    const Arg = union(enum) { reg: u8, imm: u64 };

    /// Calls the function whose address is in `fnreg` (rax or r11), with
    /// the context first and then `args`. The result is in rax.
    fn call(e: *E, args: []const Arg) !void {
        std.debug.assert(args.len + 1 <= 5);
        const live = e.saveMask();
        try e.saveRegs(live);
        // Stage every argument, then load the ABI's registers from there,
        // so no argument overwrites another on its way.
        try e.store(RSP, staging, CTX);
        for (args, 1..) |a, k| switch (a) {
            .reg => |r| try e.store(RSP, @intCast(staging + 8 * k), r),
            .imm => |v| {
                try e.movImm(R10, v);
                try e.store(RSP, @intCast(staging + 8 * k), R10);
            },
        };
        for (0..args.len + 1) |k| {
            if (k < arg_regs.len) {
                try e.load(arg_regs[k], RSP, @intCast(staging + 8 * k));
            } else {
                try e.load(R10, RSP, @intCast(staging + 8 * k));
                try e.store(RSP, @intCast(8 * k), R10);
            }
        }
        try e.bs(&.{ 0x41, 0xff, 0xd3 }); // call r11
        try e.restoreRegs(live);
    }

    /// lea rsp, [rbp - saved_bytes]: the frame torn down to the pushes.
    fn dropFrame(e: *E) !void {
        try e.bs(&.{ 0x48, 0x8d, 0x65, @bitCast(-@as(i8, saved_bytes)) });
    }
};

fn sizeLog2(t: Type) ?u32 {
    return switch (t) {
        .i8 => 0,
        .i16 => 1,
        .i32 => 2,
        .i64, .flags => 3,
        else => null,
    };
}

fn native(t: Type) bool {
    return t == .i32 or t == .i64;
}

/// The Emitter interface. This emitter plans its own registers
/// (regalloc.zig), so `a` is unused.
pub fn emit(gpa: std.mem.Allocator, r: *const ir.Region, a: *const alloc_mod.Allocation, out: *std.ArrayList(u8)) EmitError!emitter.Code {
    _ = a;
    return emitRegion(gpa, r, out);
}

pub fn emitRegion(gpa: std.mem.Allocator, r: *const ir.Region, out: *std.ArrayList(u8)) EmitError!emitter.Code {
    var p = regalloc.plan(gpa, r, host, null) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooLarge => error.TooLarge,
    };
    defer p.deinit(gpa);
    if (p.slots > (std.math.maxInt(i32) - slots_base) / 8) return error.TooLarge;
    var e: E = .{ .gpa = gpa, .out = out, .base = out.items.len, .r = r, .p = &p };
    defer e.fixups.deinit(gpa);
    const block_pos = try gpa.alloc(usize, r.blocks.items.len);
    defer gpa.free(block_pos);

    // Prologue.
    try e.b(0x55); // push rbp
    try e.bs(&.{ 0x48, 0x89, 0xe5 }); // mov rbp, rsp
    for (saved_regs) |x| {
        try e.rex(false, 0, 0, x);
        try e.b(0x50 + (x & 7)); // push
    }
    try e.mov(CTX, if (win64) RCX else RDI);
    // The chain entry: linked sites and jump-cache hits land here, with rbx
    // the context and rsp at rbp - saved_bytes (the frame torn down).
    e.code.chain_entry = @intCast(e.pos());
    // The pushes leave rsp 8 off 16-byte alignment (an odd number of
    // them); the frame puts it back.
    comptime std.debug.assert(saved_regs.len % 2 == 1);
    const frame: u32 = ((slots_base + p.slots * 8 + 15) & ~@as(u32, 15)) + 8;
    try e.rr(true, &.{0x81}, 5, RSP); // sub rsp, frame
    try e.d32(frame);
    try e.loadChunks();

    for (r.blocks.items, 0..) |blk, bi| {
        block_pos[bi] = e.pos();
        e.block = @intCast(bi);
        e.dirty = p.dirty_in[bi];
        for (blk.start..blk.start + blk.len) |idx| {
            e.idx = idx;
            try lower(&e, r, idx);
        }
    }

    // Epilogue: eax holds the exit code.
    const epi = e.pos();
    try e.dropFrame();
    try popAndReturn(&e);

    for (e.fixups.items) |f| {
        const to = if (f.target == epilogue) epi else block_pos[f.target];
        e.patch32(f.pos, @bitCast(@as(i32, @intCast(@as(isize, @intCast(to)) - @as(isize, @intCast(f.pos + 4))))));
    }
    e.code.entry = 0;
    return e.code;
}

fn popAndReturn(e: *E) !void {
    var k = saved_regs.len;
    while (k > 0) {
        k -= 1;
        const x = saved_regs[k];
        try e.rex(false, 0, 0, x);
        try e.b(0x58 + (x & 7)); // pop
    }
    try e.b(0x5d); // pop rbp
    try e.b(0xc3); // ret
}

/// Masks rax to `t`'s width (values are kept zero-extended).
fn maskTo(e: *E, t: Type) !void {
    switch (t) {
        .i1 => try e.aluImm(false, 4, RAX, 1), // and eax, 1
        .i8 => try e.bs(&.{ 0x0f, 0xb6, 0xc0 }), // movzx eax, al
        .i16 => try e.bs(&.{ 0x0f, 0xb7, 0xc0 }), // movzx eax, ax
        .i32 => try e.bs(&.{ 0x89, 0xc0 }), // mov eax, eax
        else => {},
    }
}

/// rax = sign-extension of rax from `t` to 64 bits.
fn signExtend(e: *E, t: Type) !void {
    switch (t) {
        .i1 => {
            try e.shiftImm(true, 4, RAX, 63);
            try e.shiftImm(true, 7, RAX, 63);
        },
        .i8 => try e.bs(&.{ 0x48, 0x0f, 0xbe, 0xc0 }), // movsx rax, al
        .i16 => try e.bs(&.{ 0x48, 0x0f, 0xbf, 0xc0 }), // movsx rax, ax
        .i32 => try e.bs(&.{ 0x48, 0x63, 0xc0 }), // movsxd rax, eax
        else => {},
    }
}

/// An ALU op on al/ax/eax/rax with cl/cx/ecx/rcx at `bits`: `opc8` is the
/// 8-bit opcode (r/m8, r8), and the wider form is opc8 + 1.
fn aluWidth(e: *E, bits: u32, opc8: u8) !void {
    switch (bits) {
        8 => try e.bs(&.{ opc8, 0xc8 }),
        16 => try e.bs(&.{ 0x66, opc8 + 1, 0xc8 }),
        32 => try e.bs(&.{ opc8 + 1, 0xc8 }),
        else => try e.bs(&.{ 0x48, opc8 + 1, 0xc8 }),
    }
}

/// rax = the host's arithmetic flags (pushfq; pop rax).
fn hostFlags(e: *E) !void {
    try e.b(0x9c);
    try e.b(0x58);
}

fn lower(e: *E, r: *const ir.Region, idx: usize) EmitError!void {
    const i = r.insts.items[idx];
    const ty = i.ty;
    const ta: Type = if (i.a != ir.none) r.insts.items[i.a].ty else .none;
    const dst: ir.Ref = @intCast(idx);
    if (i.op.isExt() or ty == .v128 or (i.op == .setreg and ta == .v128)) return lowerExt(e, r, i, dst);
    if (i.a != ir.none) try e.ldVal(RAX, i.a);
    if (i.b != ir.none) try e.ldVal(RCX, i.b);
    if (i.c != ir.none) try e.ldVal(RDX, i.c);
    const w = ty == .i64;

    switch (i.op) {
        .@"const" => try e.movImm(RAX, i.aux),
        .getreg, .setreg => {
            const t = if (i.op == .getreg) ty else ta;
            const sz = sizeLog2(t) orelse return error.Unsupported;
            const ck = e.p.chunk_of[idx];
            if (ck != regalloc.no_chunk) {
                const c = e.p.chunks[ck];
                const creg: u8 = @intCast(c.reg);
                const sh: u8 = @intCast((i.aux - c.off) * 8);
                const whole = (@as(u32, 1) << @intCast(sz)) == c.bytes;
                if (i.op == .getreg) {
                    try e.mov(RAX, creg);
                    if (sh != 0) try e.shiftImm(true, 5, RAX, sh); // shr rax, sh
                    try maskTo(e, t);
                    try e.stVal(dst, RAX);
                } else {
                    // Values are zero-extended, so the chunk stays so.
                    if (whole) {
                        try e.mov(creg, RAX);
                    } else {
                        const bits: u6 = @intCast(8 * (@as(u32, 1) << @intCast(sz)));
                        const mask: u64 = ((@as(u64, 1) << bits) - 1) << @intCast(sh);
                        try e.movImm(R10, ~mask);
                        try e.rr(true, &.{0x21}, R10, creg); // and creg, r10
                        try e.mov(R10, RAX);
                        if (sh != 0) try e.shiftImm(true, 4, R10, sh); // shl r10, sh
                        try e.rr(true, &.{0x09}, R10, creg); // or creg, r10
                    }
                    e.dirty |= @as(regalloc.ChunkSet, 1) << @intCast(ck);
                }
                return;
            }
            try e.ldCtx(R10, ctx.off.cpu);
            const disp: i32 = std.math.cast(i32, i.aux) orelse return error.Unsupported;
            if (i.op == .getreg) switch (sz) {
                0 => try e.rm(false, &.{ 0x0f, 0xb6 }, RAX, R10, disp), // movzx eax, byte
                1 => try e.rm(false, &.{ 0x0f, 0xb7 }, RAX, R10, disp),
                2 => try e.rm(false, &.{0x8b}, RAX, R10, disp),
                else => try e.rm(true, &.{0x8b}, RAX, R10, disp),
            } else switch (sz) {
                0 => try e.rm(false, &.{0x88}, RAX, R10, disp),
                1 => try e.rm16(&.{0x89}, RAX, R10, disp),
                2 => try e.rm(false, &.{0x89}, RAX, R10, disp),
                else => try e.rm(true, &.{0x89}, RAX, R10, disp),
            }
        },
        .add, .sub, .@"and", .@"or", .xor, .mul => {
            switch (i.op) {
                .add => try e.rr(true, &.{0x01}, RCX, RAX),
                .sub => try e.rr(true, &.{0x29}, RCX, RAX),
                .@"and" => try e.rr(true, &.{0x21}, RCX, RAX),
                .@"or" => try e.rr(true, &.{0x09}, RCX, RAX),
                .xor => try e.rr(true, &.{0x31}, RCX, RAX),
                .mul => try e.rr(true, &.{ 0x0f, 0xaf }, RAX, RCX), // imul rax, rcx
                else => unreachable,
            }
            try maskTo(e, ty);
        },
        .andn => {
            try e.rr(true, &.{0xf7}, 2, RCX); // not rcx
            try e.rr(true, &.{0x21}, RCX, RAX);
            try maskTo(e, ty);
        },
        .neg, .not => {
            try e.rr(true, &.{0xf7}, if (i.op == .neg) 3 else 2, RAX);
            try maskTo(e, ty);
        },
        .shl, .lshr, .ashr, .ror, .rol => if (native(ty)) {
            const n: u8 = switch (i.op) {
                .shl => 4,
                .lshr => 5,
                .ashr => 7,
                .ror => 1,
                .rol => 0,
                else => unreachable,
            };
            try e.rr(w, &.{0xd3}, n, RAX); // op rax, cl (x86 takes the count mod the width)
        } else try fallback(e, i, ta),
        .mulhu, .mulhs => if (ty == .i64) {
            try e.rr(true, &.{0xf7}, if (i.op == .mulhu) 4 else 5, RCX); // mul/imul rcx
            try e.mov(RAX, RDX);
        } else try fallback(e, i, ta),
        .udiv, .sdiv, .urem, .srem => if (native(ty)) {
            try divide(e, i.op, w);
        } else try fallback(e, i, ta),
        .clz => {
            // 63 - bsr, with bsr of 0 taken as -1; then less the bits above
            // the type.
            try e.movImm(RCX, std.math.maxInt(u64));
            try e.rr(true, &.{ 0x0f, 0xbd }, RAX, RAX); // bsr rax, rax
            try e.rr(true, &.{ 0x0f, 0x44 }, RAX, RCX); // cmovz rax, rcx
            // not gives -1 - idx; adding bits gives (63 - idx) - (64 - bits).
            try e.rr(true, &.{0xf7}, 2, RAX); // not rax
            try e.aluImm(true, 0, RAX, @intCast(ty.bits())); // add rax, bits
            try maskTo(e, ty);
        },
        .ctz => {
            try e.movImm(RCX, ty.bits());
            try e.rr(true, &.{ 0x0f, 0xbc }, RAX, RAX); // bsf rax, rax
            try e.rr(true, &.{ 0x0f, 0x44 }, RAX, RCX); // cmovz rax, rcx
        },
        .bswap => if (native(ty)) {
            try e.rex(w, 0, 0, RAX);
            try e.bs(&.{ 0x0f, 0xc8 });
        } else try fallback(e, i, ta),
        .zext => {},
        .trunc => try maskTo(e, ty),
        .sext => {
            if (!ta.isInt()) return error.Unsupported;
            try signExtend(e, ta);
            try maskTo(e, ty);
        },
        .select => {
            try e.rr(true, &.{0x85}, RAX, RAX); // test rax, rax
            try e.mov(RAX, RDX);
            try e.rr(true, &.{ 0x0f, 0x45 }, RAX, RCX); // cmovne rax, rcx
        },
        .icmp => if (native(ta)) {
            try e.rr(ta == .i64, &.{0x39}, RCX, RAX); // cmp rax, rcx
            try e.setcc(pred_cc[@intCast(i.aux)]);
        } else try fallback(e, i, ta),
        .@"nzcv.add", .@"nzcv.sub", .@"nzcv.logic", .@"nzcv.adc", .@"nzcv.sbc" => if (native(ta)) {
            const w2 = ta == .i64;
            switch (i.op) {
                .@"nzcv.add" => try e.rr(w2, &.{0x01}, RCX, RAX),
                .@"nzcv.sub" => try e.rr(w2, &.{0x29}, RCX, RAX),
                .@"nzcv.logic" => try e.rr(w2, &.{0x85}, RAX, RAX),
                .@"nzcv.adc" => {
                    try btImm(e, RDX, 29);
                    try e.rr(w2, &.{0x11}, RCX, RAX);
                },
                .@"nzcv.sbc" => {
                    try btImm(e, RDX, 29);
                    try e.b(0xf5); // cmc: x86 borrows when arm64's C is clear
                    try e.rr(w2, &.{0x19}, RCX, RAX);
                },
                else => unreachable,
            }
            try hostFlags(e);
            const invert_c = i.op == .@"nzcv.sub" or i.op == .@"nzcv.sbc";
            try packNzcv(e, invert_c, i.op == .@"nzcv.logic");
        } else try fallback(e, i, ta),
        .@"nzcv.cond" => if (i.aux >= 14) {
            try e.movImm(RAX, 1);
        } else {
            // Host flags from NZCV, with CF = !C, then the matching setcc.
            try e.movImm(RCX, 2);
            inline for (.{ .{ 24, 0x80 }, .{ 24, 0x40 }, .{ 17, 0x800 } }) |m| {
                try e.mov(RDX, RAX);
                try e.shiftImm(false, 5, RDX, m[0]);
                try e.aluImm(false, 4, RDX, m[1]);
                try e.rr(false, &.{0x09}, RDX, RCX);
            }
            try e.mov(RDX, RAX);
            try e.shiftImm(false, 5, RDX, 29);
            try e.aluImm(false, 4, RDX, 1);
            try e.aluImm(false, 6, RDX, 1); // xor edx, 1
            try e.rr(false, &.{0x09}, RDX, RCX);
            try e.b(0x51); // push rcx
            try e.b(0x9d); // popfq
            try e.setcc(nzcv_cc[@intCast(i.aux)]);
        },
        .@"nzcv.pack", .@"nzcv.unpack" => try e.aluImm(false, 4, RAX, @bitCast(@as(u32, 0xf000_0000))),
        .@"eflags.add", .@"eflags.sub", .@"eflags.adc", .@"eflags.sbb", .@"eflags.logic", .@"eflags.inc", .@"eflags.dec" => {
            const bits = ta.bits();
            if (bits != 8 and bits != 16 and bits != 32 and bits != 64) return fallback(e, i, ta);
            var mask: u32 = @intCast(ir_eval.eflags_mask);
            switch (i.op) {
                .@"eflags.add" => try aluWidth(e, bits, 0x00),
                .@"eflags.sub" => try aluWidth(e, bits, 0x28),
                .@"eflags.adc" => {
                    try btImm(e, RDX, 0);
                    try aluWidth(e, bits, 0x10);
                },
                .@"eflags.sbb" => {
                    try btImm(e, RDX, 0);
                    try aluWidth(e, bits, 0x18);
                },
                .@"eflags.logic" => {
                    try aluWidthTest(e, bits);
                    mask &= ~@as(u32, @intCast(ir_eval.AF)); // AF is undefined after TEST
                },
                .@"eflags.inc", .@"eflags.dec" => {
                    const n: u8 = if (i.op == .@"eflags.inc") 0 else 1;
                    switch (bits) {
                        8 => try e.bs(&.{ 0xfe, 0xc0 | (n << 3) }),
                        16 => try e.bs(&.{ 0x66, 0xff, 0xc0 | (n << 3) }),
                        32 => try e.bs(&.{ 0xff, 0xc0 | (n << 3) }),
                        else => try e.bs(&.{ 0x48, 0xff, 0xc0 | (n << 3) }),
                    }
                    mask &= ~@as(u32, @intCast(ir_eval.CF));
                },
                else => unreachable,
            }
            try hostFlags(e);
            try e.aluImm(false, 4, RAX, @intCast(mask));
            if (i.op == .@"eflags.inc" or i.op == .@"eflags.dec") {
                try e.aluImm(false, 4, RCX, 1); // CF from b
                try e.rr(false, &.{0x09}, RCX, RAX);
            }
        },
        .@"eflags.cond" => {
            try e.aluImm(false, 4, RAX, @intCast(ir_eval.eflags_mask));
            try e.aluImm(false, 1, RAX, 2); // or eax, 2 (the reserved bit)
            try e.b(0x50); // push rax
            try e.b(0x9d); // popfq
            try e.setcc(@intCast(i.aux));
        },
        .@"eflags.pack", .@"eflags.unpack" => try e.aluImm(false, 4, RAX, @intCast(ir_eval.eflags_mask)),
        .load, .store => try memOp(e, i),
        .cas => {
            const f: ir.MemFlags = @bitCast(i.aux);
            try e.ldCtx(R11, ctx.off.slow_cas);
            try e.call(&.{ .{ .reg = RAX }, .{ .imm = f.size }, .{ .reg = RCX }, .{ .reg = RDX } });
            try e.rr(false, &.{0x85}, RAX, RAX); // test eax, eax
            const ok = try e.fwd(CC.e);
            try e.writeback(e.dirty);
            try e.retireOn(i.retired);
            try e.movImm(RCX, i.aux2);
            try e.stCtx(ctx.off.exit_pc, RCX);
            try e.jmpTo(null, epilogue);
            e.land(ok);
            try e.ldCtx(RAX, ctx.off.scratch);
        },
        .fence => if (i.aux == 0) try e.bs(&.{ 0x0f, 0xae, 0xf0 }), // mfence; TSO orders the rest
        .@"call.interp" => {
            try e.writeback(e.dirty);
            e.dirty = 0;
            try e.ldCtx(R11, ctx.off.interp);
            try e.call(&.{ .{ .imm = r.handles.items[@intCast(i.aux)] }, .{ .imm = i.aux2 } });
            try e.loadChunks();
            try e.rr(false, &.{0x85}, RAX, RAX);
            if (i.retired == 0) {
                try e.jmpTo(CC.ne, epilogue);
            } else {
                const on = try e.fwd(CC.e);
                try e.retireOn(i.retired);
                try e.jmpTo(null, epilogue);
                e.land(on);
            }
        },
        .@"call.helper" => {
            try e.writeback(e.dirty);
            e.dirty = 0;
            try e.ldCtx(R11, ctx.off.helpers);
            try e.load(R11, R11, std.math.cast(i32, i.aux * 8) orelse return error.Unsupported);
            // Missing arguments are 0, as in ir_eval.
            const args = [3]E.Arg{
                if (i.a != ir.none) .{ .reg = RAX } else .{ .imm = 0 },
                if (i.b != ir.none) .{ .reg = RCX } else .{ .imm = 0 },
                if (i.c != ir.none) .{ .reg = RDX } else .{ .imm = 0 },
            };
            try e.call(&args);
            try e.loadChunks();
        },
        .poll => {
            try e.bs(&.{ 0x83, 0x7b, ctx.off.exit_request, 0x00 }); // cmp dword [rbx+exit_request], 0
            const req = try e.fwd(CC.ne);
            try e.bs(&.{ 0x48, 0x83, 0x7b, ctx.off.budget, 0x00 }); // cmp qword [rbx+budget], 0
            const ok = try e.fwd(CC.g);
            e.land(req);
            try e.leave(.interrupted, i.aux, i.retired);
            e.land(ok);
        },
        .retire => try e.retireOn(i.aux),
        .br => try e.jmpTo(null, @intCast(i.aux)),
        .brcond => {
            try e.rr(false, &.{0x85}, RAX, RAX);
            try e.jmpTo(CC.ne, @intCast(i.aux));
            try e.jmpTo(null, @intCast(i.aux2));
        },
        .@"exit.chain" => {
            try e.writeback(e.dirty);
            try e.retireOn(i.retired);
            try e.dropFrame(); // the chain entry's stack
            while ((e.pos() + 1) % 4 != 0) try e.b(0x90);
            const site = e.pos();
            try e.bs(&.{ 0xe9, 0, 0, 0, 0 }); // jmp .+5, until linked
            if (e.code.nchains < emitter.max_chains) {
                e.code.chains[e.code.nchains] = .{ .site = @intCast(site), .pc = i.aux };
                e.code.nchains += 1;
            }
            // lea rax, [rip - (distance back to the site)]
            const disp: i32 = -@as(i32, @intCast(e.pos() + 7 - site));
            try e.bs(&.{ 0x48, 0x8d, 0x05 });
            try e.d32(@bitCast(disp));
            try e.stCtx(ctx.off.exit_info, RAX);
            try e.movImm(RAX, i.aux);
            try e.stCtx(ctx.off.exit_pc, RAX);
            try e.movImm(RAX, @intFromEnum(ctx.Exit.chain));
            try popAndReturn(e);
        },
        .@"exit.svc" => try e.leave(.svc, i.aux, i.retired),
        .@"exit.brk" => try e.leave(.brk, i.aux, i.retired),
        .@"exit.undef" => try e.leave(.undef, i.aux, i.retired),
        .@"exit.indirect" => {
            try e.writeback(e.dirty);
            try e.retireOn(i.retired);
            try e.stCtx(ctx.off.exit_pc, RAX);
            // The jump cache, inline: a hit goes straight to the target's
            // chain entry, with the frame torn down as at a chain site.
            try e.ldCtx(R10, ctx.off.jump);
            try e.rr(true, &.{0x85}, R10, R10); // test r10, r10
            const none = try e.fwd(CC.e);
            try e.mov(RCX, RAX);
            try e.shiftImm(true, 5, RCX, 10); // shr rcx, 10
            try e.rr(true, &.{0x31}, RAX, RCX); // xor rcx, rax
            try e.aluImm(false, 4, RCX, ctx.jump_entries - 1); // and ecx, 1023
            try e.rr(true, &.{0x6b}, RCX, RCX); // imul rcx, rcx, 24
            try e.b(@sizeOf(ctx.JumpEntry));
            try e.rr(true, &.{0x01}, RCX, R10); // add r10, rcx
            try e.rm(true, &.{0x39}, RAX, R10, 0); // cmp [r10], rax
            const miss = try e.fwd(CC.ne);
            try e.load(R10, R10, @offsetOf(ctx.JumpEntry, "code"));
            try e.dropFrame();
            try e.bs(&.{ 0x41, 0xff, 0xe2 }); // jmp r10
            e.land(none);
            e.land(miss);
            try e.movImm(RAX, @intFromEnum(ctx.Exit.indirect));
            try e.jmpTo(null, epilogue);
        },
        else => if (i.op.isPure()) try fallback(e, i, ta) else return error.Unsupported,
    }
    if (ty != .none) try e.stVal(dst, RAX);
}

/// movdqu xmm`x`, [base+disp]
fn vload(e: *E, x: u8, base: u8, disp: i32) !void {
    try e.b(0xf3);
    try e.rm(false, &.{ 0x0f, 0x6f }, x, base, disp);
}

/// movdqu [base+disp], xmm`x`
fn vstore(e: *E, base: u8, disp: i32, x: u8) !void {
    try e.b(0xf3);
    try e.rm(false, &.{ 0x0f, 0x7f }, x, base, disp);
}

fn slotDisp(slot: u32) i32 {
    return @intCast(slots_base + slot * 8);
}

/// The FP and vector ops, and v128 getreg and setreg: each through
/// ir_eval.evalExtC for now, and v.load and v.store inline.
fn lowerExt(e: *E, r: *const ir.Region, i: ir.Inst, dst: ir.Ref) EmitError!void {
    switch (i.op) {
        .getreg, .setreg => {
            const disp: i32 = std.math.cast(i32, i.aux) orelse return error.Unsupported;
            try e.ldCtx(R10, ctx.off.cpu);
            if (i.op == .getreg) {
                try vload(e, 0, R10, disp);
                try vstore(e, RSP, slotDisp(e.vslot(dst)), 0);
            } else {
                try vload(e, 0, RSP, slotDisp(e.vslot(i.a)));
                try vstore(e, R10, disp, 0);
            }
            return;
        },
        .@"v.load", .@"v.store" => return vmemOp(e, i, dst),
        else => {},
    }
    if (!i.op.isExt()) return error.Unsupported;
    if (try vecNative(e, r, i, dst)) return;
    if (try fpNative(e, r, i, dst)) return;
    return extFallback(e, r, i, dst);
}

/// ir_eval.evalExtC for an `fp.*` or `v.*` op.
fn extFallback(e: *E, r: *const ir.Region, i: ir.Inst, dst: ir.Ref) EmitError!void {
    // Stage the operands, each zero-extended to 16 bytes.
    for (i.operands(), 0..) |o, k| {
        if (o == ir.none) continue;
        const at: i32 = @intCast(io_base + 16 * k);
        if (r.insts.items[o].ty == .v128) {
            try vload(e, 0, RSP, slotDisp(e.vslot(o)));
            try vstore(e, RSP, at, 0);
        } else {
            try e.ldVal(RAX, o);
            try e.store(RSP, at, RAX);
            try e.rr(false, &.{0x31}, RAX, RAX);
            try e.store(RSP, at + 8, RAX);
        }
    }
    const ta: Type = if (i.a != ir.none) r.insts.items[i.a].ty else .none;
    try e.rm(true, &.{0x8d}, RAX, RSP, io_base); // lea rax, [rsp+io]
    try e.movImm(R11, @intFromPtr(&ir_eval.evalExtC));
    try e.call(&.{ .{ .imm = ir_eval.fallbackCode(i.op, i.ty, ta) }, .{ .reg = RAX }, .{ .imm = i.aux }, .{ .imm = i.aux2 } });
    if (i.ty == .v128) {
        try vload(e, 0, RSP, io_base);
        try vstore(e, RSP, slotDisp(e.vslot(dst)), 0);
    } else if (i.ty != .none) {
        try e.load(RAX, RSP, io_base);
        try e.stVal(dst, RAX);
    }
}

/// v.load and v.store: 16 bytes through the TLB, or two 8-byte halves
/// through the slow path.
fn vmemOp(e: *E, i: ir.Inst, dst: ir.Ref) !void {
    const f: ir.MemFlags = @bitCast(i.aux);
    const store = i.op == .@"v.store";
    try e.ldVal(RAX, i.a);
    if (f.aligned) {
        try e.bs(&.{ 0xa8, 15 }); // test al, 15
        const ok = try e.fwd(CC.e);
        try e.stCtx(ctx.off.exit_addr, RAX);
        const acc: u64 = @intFromEnum(if (store) mem.Access.write else mem.Access.read);
        try e.movImm(RAX, acc | (@as(u64, @intFromEnum(mem.FaultKind.alignment)) << 8));
        try e.stCtx(ctx.off.exit_info, RAX);
        try e.leave(.fault, i.aux2, i.retired);
        e.land(ok);
    }
    const table: i32 = if (store) mem.tlb_write_off else mem.tlb_read_off;
    try e.mov(R10, RAX);
    try e.shiftImm(true, 5, R10, mem.page_shift);
    try e.ldCtx(R11, ctx.off.tlb);
    try e.rr(false, &.{ 0x0f, 0xb6 }, RDX, R10);
    try e.shiftImm(false, 4, RDX, 4);
    try e.rr(true, &.{0x01}, RDX, R11);
    try e.rm(true, &.{0x39}, R10, R11, table);
    const miss1 = try e.fwd(CC.ne);
    try e.mov(RDX, RAX);
    try e.aluImm(false, 4, RDX, mem.page_size - 1);
    try e.aluImm(false, 7, RDX, mem.page_size - 16);
    const miss2 = try e.fwd(CC.a);
    try e.rm(true, &.{0x03}, RAX, R11, table + 8);
    if (store) {
        try vload(e, 0, RSP, slotDisp(e.vslot(i.b)));
        try vstore(e, RAX, 0, 0);
    } else {
        try vload(e, 0, RAX, 0);
        try vstore(e, RSP, slotDisp(e.vslot(dst)), 0);
    }
    const join = try e.fwd(null);
    e.land(miss1);
    e.land(miss2);
    // Two halves, the low first; the address is kept in the io area.
    try e.store(RSP, io_base, RAX);
    for (0..2) |h| {
        try e.load(RAX, RSP, io_base);
        if (h == 1) try e.aluImm(true, 0, RAX, 8);
        if (store) {
            try e.ldSlot(RCX, e.vslot(i.b) + @as(u32, @intCast(h)));
            try e.ldCtx(R11, ctx.off.slow_store);
            try e.call(&.{ .{ .reg = RAX }, .{ .imm = 3 }, .{ .reg = RCX } });
        } else {
            try e.ldCtx(R11, ctx.off.slow_load);
            try e.call(&.{ .{ .reg = RAX }, .{ .imm = 3 } });
        }
        try e.rr(false, &.{0x85}, RAX, RAX);
        const ok = try e.fwd(CC.e);
        try e.writeback(e.dirty);
        try e.mov(RCX, RAX);
        try e.retireOn(i.retired);
        try e.movImm(RDX, i.aux2);
        try e.stCtx(ctx.off.exit_pc, RDX);
        try e.mov(RAX, RCX);
        try e.jmpTo(null, epilogue);
        e.land(ok);
        if (!store) {
            try e.ldCtx(RAX, ctx.off.scratch);
            try e.store(RSP, slotDisp(e.vslot(dst) + @as(u32, @intCast(h))), RAX);
        }
    }
    e.land(join);
    if (store and f.order == .seq_cst) try e.bs(&.{ 0x0f, 0xae, 0xf0 });
}

// ---------------------------------------------------------------- SSE

/// An SSE op on registers: [prefix] 0F opc... modrm(reg, rm). xmm and
/// general registers are numbered alike; `w` sets REX.W.
fn sse(e: *E, prefix: ?u8, w: bool, opc: []const u8, reg: u8, rm: u8) !void {
    if (prefix) |p| try e.b(p);
    try e.rex(w, reg, 0, rm);
    try e.b(0x0f);
    try e.bs(opc);
    try e.b(0xc0 | ((reg & 7) << 3) | (rm & 7));
}

/// The same with an imm8 after.
fn sseI(e: *E, prefix: ?u8, opc: []const u8, reg: u8, rm: u8, imm: u8) !void {
    try sse(e, prefix, false, opc, reg, rm);
    try e.b(imm);
}

/// xmm`x` = value `v`: 16 bytes, or a scalar's 8.
fn ldX(e: *E, x: u8, v: ir.Ref, t: Type) !void {
    if (t == .v128) return vload(e, x, RSP, slotDisp(e.vslot(v)));
    switch (e.p.locs[v]) {
        .reg => |g| try sse(e, 0x66, true, &.{0x6e}, x, @intCast(g)), // movq xmm, r64
        .slot => |s| {
            try e.b(0xf3); // movq xmm, m64
            try e.rm(false, &.{ 0x0f, 0x7e }, x, RSP, slotDisp(s));
        },
        .none => unreachable,
    }
}

/// The value in xmm`x` to value `v`: 16 bytes, or a scalar of type t,
/// zero-extended to 8.
fn stX(e: *E, v: ir.Ref, x: u8, t: Type) !void {
    if (t == .v128) return vstore(e, RSP, slotDisp(e.vslot(v)), x);
    try sse(e, 0x66, t == .i64, &.{0x7e}, x, RAX); // movd/movq rax, xmm
    try maskTo(e, t);
    try e.stVal(v, RAX);
}

/// xmm`x` = imm32 in every 32-bit lane.
fn splat32(e: *E, x: u8, v: u32) !void {
    try e.movImm(RAX, v);
    try sse(e, 0x66, false, &.{0x6e}, x, RAX); // movd
    try sseI(e, 0x66, &.{0x70}, x, x, 0); // pshufd x, x, 0
}

/// Integer `v.*` ops that SSE2 (or SSSE3 and SSE4.1 where the build
/// allows) does exactly: a in xmm0, b in xmm1, the result in xmm0.
/// Returns false, emitting nothing, for the rest.
fn vecNative(e: *E, r: *const ir.Region, i: ir.Inst, dst: ir.Ref) !bool {
    _ = r;
    if (i.op.isFp()) return false;
    const x = ir.ExtAux.of(i.aux);
    const es = x.esize;
    // Per lane size: byte, word, dword, qword forms (0 if none).
    const T4 = [4]u8;
    const can = switch (i.op) {
        .@"v.make", .@"v.and", .@"v.or", .@"v.xor", .@"v.andn", .@"v.add", .@"v.sub", .@"v.lane", .@"v.ins", .@"v.dup", .@"v.ext" => true,
        .@"v.zip" => true,
        .@"v.mul" => es == 1 or (es == 2 and sse41),
        .@"v.shl", .@"v.lshr" => es != 0 and x.imm < 256,
        .@"v.ashr" => (es == 1 or es == 2) and x.imm < 256,
        .@"v.cmp" => es <= 2 or (es == 3 and sse41 and (x.imm == 0 or x.imm == 1)),
        .@"v.min", .@"v.max" => switch (es) {
            0 => x.imm == 0 or sse41,
            1 => x.imm == 1 or sse41,
            2 => sse41,
            3 => false,
        },
        .@"v.tbl" => ssse3,
        .@"v.narrow" => (es == 1 and x.imm != 3) or (es == 2 and (x.imm == 1 or (x.imm == 2 and sse41))),
        .@"v.widen" => es <= 1 or (x.imm & 1 == 0) or sse41,
        else => false,
    };
    if (!can) return false;
    switch (i.op) {
        .@"v.make" => {
            try e.ldVal(RAX, i.a);
            try e.ldVal(RCX, i.b);
            try e.stSlot(e.vslot(dst), RAX);
            try e.stSlot(e.vslot(dst) + 1, RCX);
            return true;
        },
        .@"v.lane" => {
            const off: i32 = slotDisp(e.vslot(i.a)) + @as(i32, x.imm) * @as(i32, @intCast(x.bits() / 8));
            switch (es) {
                0 => try e.rm(false, &.{ 0x0f, 0xb6 }, RAX, RSP, off),
                1 => try e.rm(false, &.{ 0x0f, 0xb7 }, RAX, RSP, off),
                2 => try e.rm(false, &.{0x8b}, RAX, RSP, off),
                3 => try e.load(RAX, RSP, off),
            }
            try e.stVal(dst, RAX);
            return true;
        },
        .@"v.ins" => {
            try vload(e, 0, RSP, slotDisp(e.vslot(i.a)));
            try vstore(e, RSP, slotDisp(e.vslot(dst)), 0);
            try e.ldVal(RAX, i.b);
            const off: i32 = slotDisp(e.vslot(dst)) + @as(i32, x.imm) * @as(i32, @intCast(x.bits() / 8));
            switch (es) {
                0 => try e.rm(false, &.{0x88}, RAX, RSP, off),
                1 => try e.rm16(&.{0x89}, RAX, RSP, off),
                2 => try e.rm(false, &.{0x89}, RAX, RSP, off),
                3 => try e.store(RSP, off, RAX),
            }
            return true;
        },
        .@"v.dup" => {
            try e.ldVal(RAX, i.a);
            try sse(e, 0x66, true, &.{0x6e}, 0, RAX); // movq xmm0, rax
            switch (es) {
                0 => {
                    try sse(e, 0x66, false, &.{0x60}, 0, 0); // punpcklbw
                    try sseI(e, 0xf2, &.{0x70}, 0, 0, 0); // pshuflw 0
                    try sseI(e, 0x66, &.{0x70}, 0, 0, 0); // pshufd 0
                },
                1 => {
                    try sseI(e, 0xf2, &.{0x70}, 0, 0, 0);
                    try sseI(e, 0x66, &.{0x70}, 0, 0, 0);
                },
                2 => try sseI(e, 0x66, &.{0x70}, 0, 0, 0),
                3 => try sse(e, 0x66, false, &.{0x6c}, 0, 0), // punpcklqdq
            }
            try vstore(e, RSP, slotDisp(e.vslot(dst)), 0);
            return true;
        },
        else => {},
    }
    try vload(e, 0, RSP, slotDisp(e.vslot(i.a)));
    if (i.b != ir.none) try vload(e, 1, RSP, slotDisp(e.vslot(i.b)));
    switch (i.op) {
        .@"v.and" => try sse(e, 0x66, false, &.{0xdb}, 0, 1),
        .@"v.or" => try sse(e, 0x66, false, &.{0xeb}, 0, 1),
        .@"v.xor" => try sse(e, 0x66, false, &.{0xef}, 0, 1),
        .@"v.andn" => {
            try sse(e, 0x66, false, &.{0xdf}, 1, 0); // pandn xmm1, xmm0: ~b & a
            try sse(e, 0x66, false, &.{0x6f}, 0, 1); // movdqa xmm0, xmm1
        },
        .@"v.add" => try sse(e, 0x66, false, &.{(T4{ 0xfc, 0xfd, 0xfe, 0xd4 })[es]}, 0, 1),
        .@"v.sub" => try sse(e, 0x66, false, &.{(T4{ 0xf8, 0xf9, 0xfa, 0xfb })[es]}, 0, 1),
        .@"v.mul" => if (es == 1) try sse(e, 0x66, false, &.{0xd5}, 0, 1) else try sse(e, 0x66, false, &.{ 0x38, 0x40 }, 0, 1),
        .@"v.shl", .@"v.lshr", .@"v.ashr" => {
            // psllw/d/q, psrlw/d/q, psraw/d by imm8: /6, /2, /4 of 0F 71-73.
            const n: u8 = switch (i.op) {
                .@"v.shl" => 6,
                .@"v.lshr" => 2,
                else => 4,
            };
            try sseI(e, 0x66, &.{0x70 + @as(u8, es)}, n, 0, @intCast(x.imm));
        },
        .@"v.cmp" => try vecCmp(e, es, @enumFromInt(x.imm)),
        .@"v.min", .@"v.max" => {
            const max = i.op == .@"v.max";
            const signed = x.imm & 1 != 0;
            switch (es) {
                0 => if (signed) try sse(e, 0x66, false, &.{ 0x38, if (max) 0x3c else 0x38 }, 0, 1) else try sse(e, 0x66, false, &.{if (max) 0xde else 0xda}, 0, 1),
                1 => if (signed) try sse(e, 0x66, false, &.{if (max) 0xee else 0xea}, 0, 1) else try sse(e, 0x66, false, &.{ 0x38, if (max) 0x3e else 0x3a }, 0, 1),
                2 => try sse(e, 0x66, false, &.{ 0x38, if (signed) (if (max) 0x3d else 0x39) else (if (max) 0x3f else 0x3b) }, 0, 1),
                3 => unreachable,
            }
        },
        .@"v.zip" => {
            const lo = T4{ 0x60, 0x61, 0x62, 0x6c };
            const hi = T4{ 0x68, 0x69, 0x6a, 0x6d };
            try sse(e, 0x66, false, &.{if (x.imm == 0) lo[es] else hi[es]}, 0, 1);
        },
        .@"v.ext" => if (x.imm != 0) {
            try sseI(e, 0x66, &.{0x73}, 3, 0, @intCast(x.imm)); // psrldq xmm0, imm
            try sseI(e, 0x66, &.{0x73}, 7, 1, @intCast(16 - x.imm)); // pslldq xmm1, 16-imm
            try sse(e, 0x66, false, &.{0xeb}, 0, 1); // por
        },
        .@"v.tbl" => {
            // pshufb zeroes a byte whose index has bit 7 set; set it for
            // indexes 16 to 127 too.
            try splat32(e, 2, 0x0f0f_0f0f);
            try sse(e, 0x66, false, &.{0x6f}, 3, 1); // movdqa xmm3, xmm1
            try sse(e, 0x66, false, &.{0x64}, 3, 2); // pcmpgtb xmm3, xmm2
            try sse(e, 0x66, false, &.{0xeb}, 1, 3); // por xmm1, xmm3
            try sse(e, 0x66, false, &.{ 0x38, 0x00 }, 0, 1); // pshufb xmm0, xmm1
        },
        .@"v.narrow" => {
            try sse(e, 0x66, false, &.{0xef}, 1, 1); // pxor xmm1, xmm1
            if (es == 1) {
                if (x.imm == 0) {
                    try splat32(e, 2, 0x00ff_00ff);
                    try sse(e, 0x66, false, &.{0xdb}, 0, 2); // pand: packuswb then can't saturate
                }
                try sse(e, 0x66, false, &.{if (x.imm == 1) 0x63 else 0x67}, 0, 1); // packsswb / packuswb
            } else if (x.imm == 1) {
                try sse(e, 0x66, false, &.{0x6b}, 0, 1); // packssdw
            } else {
                try sse(e, 0x66, false, &.{ 0x38, 0x2b }, 0, 1); // packusdw
            }
        },
        .@"v.widen" => {
            if (x.imm & 2 != 0) try sseI(e, 0x66, &.{0x73}, 3, 0, 8); // psrldq xmm0, 8
            if (x.imm & 1 == 0) {
                try sse(e, 0x66, false, &.{0xef}, 1, 1); // pxor xmm1, xmm1
                try sse(e, 0x66, false, &.{(T4{ 0x60, 0x61, 0x62, 0 })[es]}, 0, 1); // punpckl with zero
            } else if (es <= 1) {
                try sse(e, 0x66, false, &.{(T4{ 0x60, 0x61, 0, 0 })[es]}, 0, 0); // each lane twice
                try sseI(e, 0x66, &.{if (es == 0) 0x71 else 0x72}, 4, 0, if (es == 0) 8 else 16); // psraw / psrad
            } else {
                try sse(e, 0x66, false, &.{ 0x38, 0x25 }, 0, 0); // pmovsxdq
            }
        },
        else => unreachable,
    }
    try vstore(e, RSP, slotDisp(e.vslot(dst)), 0);
    return true;
}

/// xmm0 = lanes of xmm0 <pred> xmm1, all ones or zero. Clobbers xmm1-3.
fn vecCmp(e: *E, es: u2, p: ir.Pred) !void {
    const eq_op: []const u8 = switch (es) {
        0 => &.{0x74},
        1 => &.{0x75},
        2 => &.{0x76},
        3 => &.{ 0x38, 0x29 }, // pcmpeqq
    };
    const gt_op: []const u8 = switch (es) {
        0 => &.{0x64},
        1 => &.{0x65},
        2 => &.{0x66},
        3 => &.{ 0x38, 0x37 }, // pcmpgtq (SSE4.2): never chosen
    };
    switch (p) {
        .eq, .ne => try sse(e, 0x66, false, eq_op, 0, 1),
        else => {
            // Unsigned: flip each lane's sign bit, then compare signed.
            const unsigned = switch (p) {
                .ult, .ule, .ugt, .uge => true,
                else => false,
            };
            if (unsigned) {
                try sse(e, 0x66, false, &.{0x76}, 2, 2); // pcmpeqd xmm2, xmm2: all ones
                try sseI(e, 0x66, &.{if (es == 3) 0x73 else if (es == 2) 0x72 else 0x71}, 6, 2, @intCast((@as(u32, 8) << es) - 1)); // the top bit of each lane
                if (es == 0) {
                    // No psllb: make 0x80 bytes from 0x8080 words.
                    try sse(e, 0x66, false, &.{0x76}, 2, 2);
                    try sseI(e, 0x66, &.{0x71}, 6, 2, 15);
                    try sse(e, 0x66, false, &.{0x6f}, 3, 2);
                    try sseI(e, 0x66, &.{0x71}, 2, 3, 8);
                    try sse(e, 0x66, false, &.{0xeb}, 2, 3);
                }
                try sse(e, 0x66, false, &.{0xef}, 0, 2);
                try sse(e, 0x66, false, &.{0xef}, 1, 2);
            }
            // gt: a > b; lt: b > a; le: !(a > b); ge: !(b > a).
            switch (p) {
                .sgt, .ugt, .sle, .ule => try sse(e, 0x66, false, gt_op, 0, 1),
                else => {
                    try sse(e, 0x66, false, gt_op, 1, 0);
                    try sse(e, 0x66, false, &.{0x6f}, 0, 1);
                },
            }
        },
    }
    switch (p) {
        .ne, .sle, .ule, .sge, .uge => {
            try sse(e, 0x66, false, &.{0x76}, 2, 2); // all ones
            try sse(e, 0x66, false, &.{0xef}, 0, 2); // pxor: not
        },
        else => {},
    }
}

/// `fp.*` ops natively where the host's SSE gives the guest's result:
/// round to nearest, no DAZ or FZ, no NaN result, and, when the guest
/// watches exceptions (aux2), none but overflow, divide-by-zero, and
/// inexact, which map one to one. Otherwise ir_eval runs it (the slow
/// path), from the same operands. Returns false, emitting nothing, for an
/// op or form it doesn't do.
fn fpNative(e: *E, r: *const ir.Region, i: ir.Inst, dst: ir.Ref) !bool {
    const x = ir.ExtAux.of(i.aux);
    if (x.rounding != 0 or x.daz or x.ftz) return false;
    const ta: Type = r.insts.items[i.a].ty;
    const vec = i.ty == .v128;
    const es: u2 = if (vec) x.esize else switch (if (i.op == .@"fp.cmp" or i.op == .@"fp.tosint") ta else i.ty) {
        .i32 => 2,
        .i64 => 3,
        else => return false,
    };
    if (es < 2) return false;
    const dbl = es == 3;
    // ps/pd and ss/sd prefixes.
    const pfx: ?u8 = if (vec) (if (dbl) 0x66 else null) else (if (dbl) 0xf2 else 0xf3);
    const arith: ?u8 = switch (i.op) {
        .@"fp.add" => 0x58,
        .@"fp.mul" => 0x59,
        .@"fp.sub" => 0x5c,
        .@"fp.div" => 0x5e,
        .@"fp.sqrt" => 0x51,
        .@"fp.min" => if (x.arm) null else 0x5d,
        .@"fp.max" => if (x.arm) null else 0x5f,
        else => null,
    };
    const watch = i.aux2 != 0;
    switch (i.op) {
        .@"fp.cmp" => if (vec) return false,
        .@"fp.cvt" => if (vec or (ta != .i32 and ta != .i64) or (i.ty != .i32 and i.ty != .i64)) return false,
        .@"fp.tosint" => if (vec or x.imm != 0 or x.arm) return false,
        .@"fp.fromsint" => if (vec or x.imm != 0 or (i.ty != .i32 and i.ty != .i64)) return false,
        else => if (arith == null) return false,
    }
    if (watch) try clearHostFlags(e);
    try ldX(e, 0, i.a, ta);
    if (i.b != ir.none) try ldX(e, 1, i.b, r.insts.items[i.b].ty);
    var nan_check = true;
    switch (i.op) {
        .@"fp.cmp" => {
            // comis (signaling) or ucomis: ZF PF CF give the order.
            try sse(e, if (dbl) 0x66 else null, false, &.{if (x.exact) 0x2f else 0x2e}, 0, 1);
            try e.bs(&.{ 0x0f, 0x9a, 0xc1 }); // setp cl
            try e.bs(&.{ 0x0f, 0x92, 0xc2 }); // setb dl
            try e.bs(&.{ 0x0f, 0x94, 0xc0 }); // sete al
            // un: 3; else 2 - 2*CF - ZF.
            try e.bs(&.{ 0x0f, 0xb6, 0xc0 }); // movzx eax, al
            try e.bs(&.{ 0x0f, 0xb6, 0xd2 }); // movzx edx, dl
            try e.bs(&.{ 0x0f, 0xb6, 0xc9 }); // movzx ecx, cl
            try e.bs(&.{ 0x01, 0xd2 }); // add edx, edx
            try e.bs(&.{ 0x01, 0xd0 }); // add eax, edx
            try e.bs(&.{ 0xf7, 0xd8 }); // neg eax
            try e.bs(&.{ 0x83, 0xc0, 0x02 }); // add eax, 2
            try e.bs(&.{ 0x85, 0xc9 }); // test ecx, ecx
            try e.bs(&.{ 0xb9, 3, 0, 0, 0 }); // mov ecx, 3
            try e.bs(&.{ 0x0f, 0x45, 0xc1 }); // cmovne eax, ecx
            try e.stVal(dst, RAX);
            nan_check = false;
        },
        .@"fp.cvt" => try sse(e, if (dbl) 0xf3 else 0xf2, false, &.{0x5a}, 0, 0), // cvtss2sd / cvtsd2ss (by the source)
        .@"fp.tosint" => {
            try sse(e, if (dbl) 0xf2 else 0xf3, i.ty == .i64, &.{0x2d}, RAX, 0); // cvtss2si / cvtsd2si, nearest
            try maskTo(e, i.ty);
            try e.stVal(dst, RAX);
            nan_check = false;
        },
        .@"fp.fromsint" => {
            try e.ldVal(RAX, i.a);
            try sse(e, 0x66, false, &.{0xef}, 0, 0); // pxor xmm0, xmm0
            try sse(e, if (i.ty == .i64) 0xf2 else 0xf3, ta == .i64, &.{0x2a}, 0, RAX); // cvtsi2ss / sd
            nan_check = false;
        },
        else => try sse(e, pfx, false, &.{arith.?}, 0, if (i.op == .@"fp.sqrt") 0 else 1),
    }
    // To the slow path on a NaN result, or an exception SSE and the
    // guest may see differently.
    var slow: [2]?usize = .{ null, null };
    if (nan_check) {
        try sse(e, null, false, &.{0x28}, 2, 0); // movaps xmm2, xmm0
        if (vec) {
            try sseI(e, if (dbl) 0x66 else null, &.{0xc2}, 2, 2, 3); // cmpunordps/pd xmm2, xmm2
            try sse(e, if (dbl) 0x66 else null, false, &.{0x50}, RAX, 2); // movmskps/pd eax, xmm2
            try e.bs(&.{ 0x85, 0xc0 }); // test eax, eax
            slow[0] = try e.fwd(CC.ne);
        } else {
            const rdbl = i.ty == .i64;
            try sse(e, if (rdbl) 0x66 else null, false, &.{0x2e}, 2, 2); // ucomis xmm2, xmm2
            slow[0] = try e.fwd(0xa); // jp
        }
    }
    if (watch) {
        try e.bs(&.{ 0x0f, 0xae, 0x5c, 0x24, @intCast(io_base) }); // stmxcsr [rsp+io]
        try e.rm(false, &.{0x8b}, RAX, RSP, io_base);
        try e.aluImm(false, 4, RAX, 0x3f);
        try e.bs(&.{ 0xa8, 0x13 }); // test al, IE|DE|UE
        slow[1] = try e.fwd(CC.ne);
        // ZE, OE, and PE, in the guest's layout.
        if (x.arm) {
            // MXCSR ZE (2) OE (3) PE (5) to FPSR DZC (1) OFC (2) IXC (4).
            try e.bs(&.{ 0xd1, 0xe8 }); // shr eax, 1
        }
        try e.ldCtx(R10, ctx.off.cpu);
        try e.rm(false, &.{0x09}, RAX, R10, @intCast(i.aux2 - 1)); // or [cpu+off], eax
    }
    if (i.op != .@"fp.cmp" and i.op != .@"fp.tosint") try stX(e, dst, 0, i.ty);
    if (slow[0] != null or slow[1] != null) {
        const done = try e.fwd(null);
        for (slow) |s0| if (s0) |at| e.land(at);
        try extFallback(e, r, i, dst);
        e.land(done);
    }
    return true;
}

/// Clears MXCSR's exception flags, through the io area.
fn clearHostFlags(e: *E) !void {
    try e.bs(&.{ 0x0f, 0xae, 0x5c, 0x24, @intCast(io_base) }); // stmxcsr [rsp+io]
    try e.rm(false, &.{0x81}, 4, RSP, io_base); // and dword [rsp+io], ~0x3f
    try e.d32(@bitCast(@as(i32, ~@as(i32, 0x3f))));
    try e.bs(&.{ 0x0f, 0xae, 0x54, 0x24, @intCast(io_base) }); // ldmxcsr [rsp+io]
}

fn aluWidthTest(e: *E, bits: u32) !void {
    switch (bits) {
        8 => try e.bs(&.{ 0x84, 0xc0 }),
        16 => try e.bs(&.{ 0x66, 0x85, 0xc0 }),
        32 => try e.bs(&.{ 0x85, 0xc0 }),
        else => try e.bs(&.{ 0x48, 0x85, 0xc0 }),
    }
}

/// bt r64, imm8: CF = bit `n` of `reg`.
fn btImm(e: *E, reg: u8, n: u8) !void {
    try e.rr(true, &.{ 0x0f, 0xba }, 4, reg);
    try e.b(n);
}

/// rax = NZCV (bits 31..28) from host flags in rax.
fn packNzcv(e: *E, invert_c: bool, logic: bool) !void {
    try e.mov(RDX, RAX);
    try e.movImm(RAX, 0);
    // N from SF (bit 7), Z from ZF (bit 6): shift both up to 31 and 30.
    try e.mov(RCX, RDX);
    try e.aluImm(false, 4, RCX, 0xc0);
    try e.shiftImm(false, 4, RCX, 24);
    try e.rr(false, &.{0x09}, RCX, RAX);
    if (logic) return; // C = V = 0
    // C from CF (bit 0) to 29.
    try e.mov(RCX, RDX);
    try e.aluImm(false, 4, RCX, 1);
    if (invert_c) try e.aluImm(false, 6, RCX, 1);
    try e.shiftImm(false, 4, RCX, 29);
    try e.rr(false, &.{0x09}, RCX, RAX);
    // V from OF (bit 11) to 28.
    try e.mov(RCX, RDX);
    try e.aluImm(false, 4, RCX, 0x800);
    try e.shiftImm(false, 4, RCX, 17);
    try e.rr(false, &.{0x09}, RCX, RAX);
}

/// rax = rax op rcx, with arm64's (and ir_eval's) rules for 0 and -1.
fn divide(e: *E, op: Op, w: bool) !void {
    const rem = op == .urem or op == .srem;
    const signed = op == .sdiv or op == .srem;
    try e.rr(w, &.{0x85}, RCX, RCX); // test rcx, rcx
    // By zero: a quotient is 0, a remainder is a.
    const by_zero = try e.fwd(CC.e);
    var by_m1: ?usize = null;
    if (signed) {
        try e.aluImm(w, 7, RCX, -1); // cmp rcx, -1
        by_m1 = try e.fwd(CC.e);
    }
    if (signed) {
        if (w) try e.bs(&.{ 0x48, 0x99 }) else try e.b(0x99); // cqo / cdq
        try e.rr(w, &.{0xf7}, 7, RCX); // idiv rcx
    } else {
        try e.rr(false, &.{0x31}, RDX, RDX); // xor edx, edx
        try e.rr(w, &.{0xf7}, 6, RCX); // div rcx
    }
    if (rem) try e.mov(RAX, RDX);
    const done1 = try e.fwd(null);
    if (by_m1) |p| {
        e.land(p);
        // MIN / -1 would trap: the quotient is -a (MIN stays MIN), the
        // remainder 0.
        if (rem) try e.movImm(RAX, 0) else try e.rr(w, &.{0xf7}, 3, RAX); // neg
    }
    const done2 = try e.fwd(null);
    e.land(by_zero);
    if (!rem) try e.movImm(RAX, 0);
    e.land(done1);
    e.land(done2);
    if (!w) try e.bs(&.{ 0x89, 0xc0 }); // mov eax, eax
}

/// rax = ir_eval.evalOpC(code, rax, rcx, rdx, aux).
fn fallback(e: *E, i: ir.Inst, ta: Type) !void {
    // evalOpC doesn't take the context first, so stage its five
    // arguments by hand.
    const live = e.saveMask();
    try e.saveRegs(live);
    const args = [_]E.Arg{ .{ .imm = ir_eval.fallbackCode(i.op, i.ty, ta) }, .{ .reg = RAX }, .{ .reg = RCX }, .{ .reg = RDX }, .{ .imm = i.aux } };
    for (args, 0..) |arg, k| switch (arg) {
        .reg => |rg| try e.store(RSP, @intCast(staging + 8 * k), rg),
        .imm => |v| {
            try e.movImm(R10, v);
            try e.store(RSP, @intCast(staging + 8 * k), R10);
        },
    };
    for (0..5) |k| {
        if (k < arg_regs.len) {
            try e.load(arg_regs[k], RSP, @intCast(staging + 8 * k));
        } else {
            try e.load(R10, RSP, @intCast(staging + 8 * k));
            try e.store(RSP, @intCast(8 * k), R10);
        }
    }
    try e.movImm(R11, @intFromPtr(&ir_eval.evalOpC));
    try e.bs(&.{ 0x41, 0xff, 0xd3 }); // call r11
    try e.restoreRegs(live);
}

/// A load or store through the TLB, with the slow path inline after the
/// fast path's jump over it. rax is the address, rcx the value to store.
fn memOp(e: *E, i: ir.Inst) !void {
    const f: ir.MemFlags = @bitCast(i.aux);
    const store = i.op == .store;
    const n = f.bytes();
    if (f.size > 3) return error.Unsupported;
    if (f.aligned and n > 1) {
        try e.bs(&.{ 0xa8, @intCast(n - 1) }); // test al, n-1
        const ok = try e.fwd(CC.e);
        try e.stCtx(ctx.off.exit_addr, RAX);
        const acc: u64 = if (store or f.rmw) @intFromEnum(mem.Access.write) else @intFromEnum(mem.Access.read);
        try e.movImm(RAX, acc | (@as(u64, @intFromEnum(mem.FaultKind.alignment)) << 8));
        try e.stCtx(ctx.off.exit_info, RAX);
        try e.leave(.fault, i.aux2, i.retired);
        e.land(ok);
    }
    const table: i32 = if (store) mem.tlb_write_off else mem.tlb_read_off;
    // r10 = &tlb.{read,write}[(va >> 12) & 255]
    try e.mov(R10, RAX);
    try e.shiftImm(true, 5, R10, mem.page_shift); // shr r10, 12
    try e.ldCtx(R11, ctx.off.tlb);
    try e.rr(false, &.{ 0x0f, 0xb6 }, RDX, R10); // movzx edx, r10b
    try e.shiftImm(false, 4, RDX, 4); // shl edx, 4
    try e.rr(true, &.{0x01}, RDX, R11); // add r11, rdx
    try e.rm(true, &.{0x39}, R10, R11, table); // cmp [r11+table], r10
    const miss1 = try e.fwd(CC.ne);
    try e.mov(RDX, RAX);
    try e.aluImm(false, 4, RDX, mem.page_size - 1); // and edx, 0xfff
    try e.aluImm(false, 7, RDX, @intCast(mem.page_size - n)); // cmp edx, page - n
    const miss2 = try e.fwd(CC.a);
    try e.rm(true, &.{0x03}, RAX, R11, table + 8); // add rax, [r11+delta]
    if (store) {
        switch (f.size) {
            0 => try e.bs(&.{ 0x88, 0x08 }), // mov [rax], cl
            1 => try e.bs(&.{ 0x66, 0x89, 0x08 }),
            2 => try e.bs(&.{ 0x89, 0x08 }),
            else => try e.bs(&.{ 0x48, 0x89, 0x08 }),
        }
    } else {
        switch (f.size) {
            0 => try e.bs(&.{ 0x0f, 0xb6, 0x00 }), // movzx eax, byte [rax]
            1 => try e.bs(&.{ 0x0f, 0xb7, 0x00 }),
            2 => try e.bs(&.{ 0x8b, 0x00 }),
            else => try e.bs(&.{ 0x48, 0x8b, 0x00 }),
        }
    }
    const join = try e.fwd(null);
    // Slow path.
    e.land(miss1);
    e.land(miss2);
    if (store) {
        try e.ldCtx(R11, ctx.off.slow_store);
        try e.call(&.{ .{ .reg = RAX }, .{ .imm = f.size }, .{ .reg = RCX } });
    } else {
        try e.ldCtx(R11, ctx.off.slow_load);
        try e.call(&.{ .{ .reg = RAX }, .{ .imm = f.size } });
    }
    try e.rr(false, &.{0x85}, RAX, RAX);
    const ok = try e.fwd(CC.e);
    try e.writeback(e.dirty);
    try e.mov(RCX, RAX); // the exit code
    if (!store and f.rmw) {
        // Report the read-modify-write's fault as a write.
        try e.ldCtx(RDX, ctx.off.exit_info);
        try e.aluImm(true, 4, RDX, -256);
        try e.aluImm(true, 1, RDX, @intFromEnum(mem.Access.write));
        try e.stCtx(ctx.off.exit_info, RDX);
    }
    try e.retireOn(i.retired);
    try e.movImm(RDX, i.aux2);
    try e.stCtx(ctx.off.exit_pc, RDX);
    try e.mov(RAX, RCX);
    try e.jmpTo(null, epilogue);
    e.land(ok);
    if (!store) try e.ldCtx(RAX, ctx.off.scratch);
    e.land(join);
    if (store and f.order == .seq_cst) try e.bs(&.{ 0x0f, 0xae, 0xf0 }); // mfence
    if (!store) {
        if (f.signed) {
            const t: Type = switch (f.size) {
                0 => .i8,
                1 => .i16,
                2 => .i32,
                else => .i64,
            };
            try signExtend(e, t);
        }
        try maskTo(e, i.ty);
    }
}

// ---------------------------------------------------------------- tests

const codemem = @import("../codemem.zig");
const cases = @import("cases.zig");

pub const supported = builtin.cpu.arch == .x86_64;

test "emitted code matches ir_eval on the shared cases" {
    if (!supported or !codemem.available()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const int_cases = try cases.generate(gpa);
    defer cases.free(gpa, int_cases);
    const ext_cases = try cases.generateExt(gpa);
    defer cases.free(gpa, ext_cases);
    const all = try std.mem.concat(gpa, cases.Case, &.{ int_cases, ext_cases });
    defer gpa.free(all);
    const env = try gpa.create(cases.Env);
    defer gpa.destroy(env);
    var region = try codemem.Region.init(16 << 20);
    defer region.deinit();
    for (all, 0..) |c, n| {
        var r = try cases.parse(gpa, c);
        defer r.deinit(gpa);
        var a = try alloc_mod.spillAll(gpa, &r);
        defer a.deinit(gpa);
        var code: std.ArrayList(u8) = .empty;
        defer code.deinit(gpa);
        const out = try emit(gpa, &r, &a, &code);
        const off = region.alloc(code.items.len, 16) orelse blk: {
            region.reset();
            break :blk region.alloc(code.items.len, 16).?;
        };
        region.write(off, code.items);
        const want = try env.evalCase(gpa, &r, c);
        // Through the slow path (an empty TLB), then the inline fast path.
        for (0..2) |pass| {
            const cx = env.reset(c);
            if (pass == 1) {
                const k = (cases.data_va >> mem.page_shift) & (mem.entries - 1);
                const e: mem.TlbEntry = .{ .tag = cases.data_va >> mem.page_shift, .delta = @intFromPtr(&env.page) -% cases.data_va };
                env.tlb.read[k] = e;
                env.tlb.write[k] = e;
            }
            const got = env.result(@enumFromInt(region.entry(off + out.entry)(cx)));
            cases.expectSame(n, c, want, got) catch |err| return err;
        }
    }
}

test "chain sites link, and the jump cache finds a target inline" {
    if (!supported or !codemem.available()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    // A adds 1 to x0 and chains to 0x2000; B adds 10 and leaves through
    // svc. C jumps to x1 indirectly.
    const texts = [_][]const u8{
        "region 0x1000\nb0:\n %0 = getreg:i64 #0x0\n %1 = const:i64 #0x1\n %2 = add:i64 %0, %1\n setreg %2 #0x0\n retire #0x1\n exit.chain #0x2000\n",
        "region 0x2000\nb0:\n poll #0x2000\n %0 = getreg:i64 #0x0\n %1 = const:i64 #0xa\n %2 = add:i64 %0, %1\n setreg %2 #0x0\n exit.svc #0x2004 !1\n",
        "region 0x3000\nb0:\n %0 = getreg:i64 #0x8\n exit.indirect %0 !2\n",
    };
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(gpa);
    var outs: [3]emitter.Code = undefined;
    var starts: [3]u32 = undefined;
    for (texts, 0..) |t, k| {
        var r = try ir.parse(gpa, t);
        defer r.deinit(gpa);
        var a = try alloc_mod.spillAll(gpa, &r);
        defer a.deinit(gpa);
        while (code.items.len % 16 != 0) try code.append(gpa, 0xcc);
        starts[k] = @intCast(code.items.len);
        outs[k] = try emit(gpa, &r, &a, &code);
    }
    try std.testing.expectEqual(@as(u8, 1), outs[0].nchains);
    try std.testing.expectEqual(@as(u64, 0x2000), outs[0].chains[0].pc);
    var region = try codemem.Region.init(code.items.len);
    defer region.deinit();
    const off = region.alloc(code.items.len, 16).?;
    region.write(off, code.items);
    var regs: [2]u64 = .{ 5, 0x2000 };
    var tlb: mem.Tlb = .{};
    var cx: ctx.Ctx = .{ .cpu = @intFromPtr(&regs), .tlb = @intFromPtr(&tlb), .budget = 100 };

    // Unlinked: A leaves with .chain, naming its site.
    try std.testing.expectEqual(ctx.Exit.chain, @as(ctx.Exit, @enumFromInt(region.entry(off + starts[0])(&cx))));
    try std.testing.expectEqual(@as(u64, 0x2000), cx.exit_pc);
    const site = off + starts[0] + outs[0].chains[0].site;
    try std.testing.expectEqual(@as(u32, 0), (site + 1) % 4);
    try std.testing.expectEqual(@intFromPtr(region.exec(site)), cx.exit_info);

    // Linked: A runs straight into B.
    const target = off + starts[1] + outs[1].chain_entry;
    const rel: i32 = @intCast(@as(i64, target) - @as(i64, site + 5));
    region.write(site + 1, std.mem.asBytes(&rel));
    regs = .{ 5, 0x2000 };
    cx.retired = 0;
    try std.testing.expectEqual(ctx.Exit.svc, @as(ctx.Exit, @enumFromInt(region.entry(off + starts[0])(&cx))));
    try std.testing.expectEqual(@as(u64, 16), regs[0]);
    try std.testing.expectEqual(@as(u64, 2), cx.retired);

    // Indirect: a miss leaves; a jump-cache hit runs B.
    var jc: [ctx.jump_entries]ctx.JumpEntry = @splat(.{});
    cx.jump = @intFromPtr(&jc);
    regs = .{ 5, 0x2000 };
    try std.testing.expectEqual(ctx.Exit.indirect, @as(ctx.Exit, @enumFromInt(region.entry(off + starts[2])(&cx))));
    try std.testing.expectEqual(@as(u64, 0x2000), cx.exit_pc);
    jc[ctx.jumpIndex(0x2000)] = .{ .pc = 0x2000, .code = @intFromPtr(region.exec(target)) };
    cx.retired = 0;
    try std.testing.expectEqual(ctx.Exit.svc, @as(ctx.Exit, @enumFromInt(region.entry(off + starts[2])(&cx))));
    try std.testing.expectEqual(@as(u64, 15), regs[0]);
    try std.testing.expectEqual(@as(u64, 3), cx.retired);
}

// ---------------------------------------------------------------- random regions

const check = @import("../check.zig");
const native_mod = @import("native.zig");

/// Checks one lifted region from Cpu `start`: with ir_eval, and then, if
/// that agrees with T0, natively. Returns false on a native divergence
/// (printed), null if ir_eval itself diverges (the lifter's, not ours),
/// and true otherwise, leaving the native run's results in `run`.
fn checkNative(gpa: std.mem.Allocator, run: *check.Run, code: *native_mod.Native, reg: *const ir.Region, start: []const u8) !?bool {
    if (!try run.check(.{ .ir_eval = reg }, start, .{})) return null;
    const f = (try code.compile(gpa, reg)).?;
    if (try run.check(.{ .entry = f }, start, .{})) return true;
    std.debug.print("x86-64 code diverges:\n{s}", .{run.report.items});
    ir.print(reg, &std.debug.lockStderr(&.{}).file_writer.interface) catch {};
    std.debug.unlockStderr();
    return false;
}

test "random arm64 programs agree with T0 natively, region by region" {
    if (!supported or !codemem.available()) return error.SkipZigTest;
    const fuzz = check.fuzz_a64;
    const gen = check.gen_a64;
    const gpa = std.testing.allocator;
    const s = try gpa.create(fuzz.Space);
    defer gpa.destroy(s);
    s.load(&.{}, 0);
    const run = try check.Run.init(gpa, &check.a64.guest, check.mapBacking(&s.map));
    defer run.deinit();
    var code = try native_mod.Native.init();
    defer code.deinit();
    var prng = std.Random.DefaultPrng.init(0x64);
    var buf: [65]u32 = undefined;
    var regions: u32 = 0;
    for (0..300) |i| {
        const words = gen.program(prng.random(), .{ .len = 48 }, &buf);
        s.load(words, i);
        var cpu = s.cpu(prng.random());
        const backing = check.mapBacking(&s.map);
        for (0..64) |_| {
            var reg = try check.liftAt(gpa, &check.a64.guest, &backing, cpu.pc, .{});
            defer reg.deinit(gpa);
            const ok = try checkNative(gpa, run, &code, &reg, std.mem.asBytes(&cpu)) orelse break;
            if (!ok) return error.Diverged;
            regions += 1;
            const o = run.out[check.Run.t1];
            run.shadow[check.Run.t1].commit();
            cpu = std.mem.bytesToValue(@TypeOf(cpu), run.cpu[check.Run.t1]);
            if (o.retired == 0 or (o.exit != .chain and o.exit != .indirect)) break;
        }
    }
    // At least every program's first region: most end there, at a fault
    // or the SVC, and a new gen_a64 class can tip the few that chain.
    try std.testing.expect(regions >= 300);
}

test "random 386 programs agree with T0 natively, region by region" {
    if (!supported or !codemem.available()) return error.SkipZigTest;
    const gen = check.gen_x86;
    const X86 = check.x86;
    const gpa = std.testing.allocator;
    const Space = struct {
        code: [mem.page_size]u8 align(mem.page_size) = @splat(0),
        data: [mem.page_size]u8 align(mem.page_size) = @splat(0),
        stack: [mem.page_size]u8 align(mem.page_size) = @splat(0),
        regions: [3]mem.Region = undefined,
        map: mem.Map = undefined,

        fn load(sp: *@This(), bytes: []const u8, seed: u64) void {
            sp.code = @splat(0xCC);
            @memcpy(sp.code[0..bytes.len], bytes);
            var p = std.Random.DefaultPrng.init(seed);
            p.random().bytes(&sp.data);
            p.random().bytes(&sp.stack);
            sp.regions = .{
                .{ .va = gen.code_va, .mem = &sp.code, .exec = true },
                .{ .va = gen.data_va, .mem = &sp.data, .write = true },
                .{ .va = gen.stack_va, .mem = &sp.stack, .write = true },
            };
            sp.map = .{ .regions = &sp.regions };
        }
    };
    const s = try gpa.create(Space);
    defer gpa.destroy(s);
    s.load(&.{}, 0);
    const run = try check.Run.init(gpa, &X86.guest, check.mapBacking(&s.map));
    defer run.deinit();
    var code = try native_mod.Native.init();
    defer code.deinit();
    var buf: [mem.page_size - 16]u8 = undefined;
    var regions: u32 = 0;
    for (0..300) |i| {
        var prng = std.Random.DefaultPrng.init(0x86 + i);
        const bytes = gen.program(prng.random(), .{ .len = 48 }, &buf);
        const regs = gen.registers(prng.random());
        s.load(bytes, i);
        var cpu: X86.Cpu = .{};
        cpu.r = regs.r;
        cpu.eip = gen.code_va;
        cpu.fl.set(regs.eflags);
        const backing = check.mapBacking(&s.map);
        for (0..64) |_| {
            var reg = check.liftAt(gpa, &X86.guest, &backing, cpu.eip, .{}) catch |e| switch (e) {
                error.Unsupported => break,
                else => return e,
            };
            defer reg.deinit(gpa);
            const ok = try checkNative(gpa, run, &code, &reg, std.mem.asBytes(&cpu)) orelse break;
            if (!ok) return error.Diverged;
            regions += 1;
            const o = run.out[check.Run.t1];
            run.shadow[check.Run.t1].commit();
            @memcpy(std.mem.asBytes(&cpu), run.cpu[check.Run.t1]);
            if (o.retired == 0 or (o.exit != .chain and o.exit != .indirect)) break;
        }
    }
    try std.testing.expect(regions > 300);
}

// ---------------------------------------------------------------- random IR

const irfuzz = @import("fuzz.zig");

/// Runs `r` natively in `region` (reset first).
fn runNative(gpa: std.mem.Allocator, region: *codemem.Region, env: *cases.Env, r: *const ir.Region, c: cases.Case) !cases.Result {
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(gpa);
    const out = try emitRegion(gpa, r, &code);
    region.reset();
    const off = region.alloc(code.items.len, 16) orelse return error.TooLarge;
    region.write(off, code.items);
    const cx = env.reset(c);
    return env.result(@enumFromInt(region.entry(off + out.entry)(cx)));
}

/// Whether the region (as text) still runs differently natively, in a
/// child process with an alarm, so a crash or a hang counts as differing.
fn stillDiffers(gpa: std.mem.Allocator, region: *codemem.Region, env: *cases.Env, text: []const u8, c: cases.Case) bool {
    var r = ir.parse(gpa, text) catch return false;
    defer r.deinit(gpa);
    if (ir.verify(&r) != null) return false;
    for (r.blocks.items, 0..) |blk, bi| {
        const t = r.insts.items[blk.start + blk.len - 1];
        // ir_eval must finish: leave loops alone.
        if ((t.op == .br or t.op == .brcond) and t.aux <= bi) return false;
        if (t.op == .brcond and t.aux2 <= bi) return false;
    }
    const want = env.evalCase(gpa, &r, c) catch return false;
    const linux = std.os.linux;
    const pid = linux.fork();
    if (pid == 0) {
        _ = linux.syscall1(.alarm, 1);
        const got = runNative(gpa, region, env, &r, c) catch linux.exit(2);
        linux.exit(if (cases.same(want, got)) 0 else 1);
    }
    var status: u32 = 0;
    _ = linux.waitpid(@intCast(pid), &status, 0);
    return status != 0 and status != 2 << 8;
}

/// Deletes runs of instruction lines while the region keeps differing.
fn reduce(gpa: std.mem.Allocator, region: *codemem.Region, env: *cases.Env, text: []const u8, c: cases.Case) ![]u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| if (l.len != 0) try lines.append(gpa, l);
    var run: usize = lines.items.len / 2;
    while (run > 0) {
        var changed = false;
        var k: usize = lines.items.len;
        while (k > 0) {
            const start = k -| run;
            k = start;
            var keep: std.ArrayList([]const u8) = .empty;
            defer keep.deinit(gpa);
            for (lines.items, 0..) |l, j| {
                const t = std.mem.trimStart(u8, l, " ");
                const term = std.mem.startsWith(u8, t, "br") or std.mem.startsWith(u8, t, "exit.");
                if (j >= start and j < start + run and l[0] == ' ' and !term) continue;
                try keep.append(gpa, l);
            }
            if (keep.items.len == lines.items.len) continue;
            const joined = try std.mem.join(gpa, "\n", keep.items);
            defer gpa.free(joined);
            if (stillDiffers(gpa, region, env, joined, c)) {
                std.mem.swap(std.ArrayList([]const u8), &lines, &keep);
                changed = true;
            }
        }
        if (!changed) run /= 2;
    }
    return std.mem.join(gpa, "\n", lines.items);
}

/// Random regions per `zig build vcpu`, from fuzz_seed.
const fuzz_count = 3000;
const fuzz_seed = 0x5eed;

test "random regions match ir_eval" {
    if (!supported or builtin.os.tag != .linux or !codemem.available()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const env = try gpa.create(cases.Env);
    defer gpa.destroy(env);
    var region = try codemem.Region.init(1 << 20);
    defer region.deinit();
    for (0..fuzz_count) |n| {
        const seed = fuzz_seed +% n;
        var prng: std.Random.DefaultPrng = .init(seed);
        const rnd = prng.random();
        var r = try irfuzz.generate(gpa, rnd, .{});
        defer r.deinit(gpa);
        const c: cases.Case = .{ .text = "", .regs = irfuzz.regs(rnd), .budget = irfuzz.budget(rnd) };
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try ir.print(&r, &aw.writer);
        if (!stillDiffers(gpa, &region, env, aw.written(), c)) continue;
        const small = try reduce(gpa, &region, env, aw.written(), c);
        defer gpa.free(small);
        std.debug.print("fuzz seed 0x{x} differs: regs {any} budget {d}\nreduced:\n{s}\n", .{ seed, c.regs, c.budget, small });
        var r2 = try ir.parse(gpa, small);
        defer r2.deinit(gpa);
        const want = try env.evalCase(gpa, &r2, c);
        const got = try runNative(gpa, &region, env, &r2, c);
        std.debug.print(" want {any}\n  got {any}\n", .{ want, got });
        return error.TestExpectedEqual;
    }
}
