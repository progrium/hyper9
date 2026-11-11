//! IR to x86-64 machine code.
//!
//! Registers come from regalloc.zig, as in emit/arm64.zig: values in
//! host registers (or frame slots when they run out; a v128 always has a
//! slot pair), and the region's most used guest register-file fields
//! ("chunks") pinned to host registers, written back to the Cpu only
//! when dirty, and only where guest state must be exact: at exits, before
//! call.interp and call.helper (which reload every chunk after), and on a
//! slow path's fault exit. Most operations still load their operands into
//! rax (a), rcx (b), and rdx (c), compute into rax, and move that to their
//! value's register or slot; `direct` computes the common ones straight
//! into the value's register, with constants as immediates (`foldConst`).
//! A load's or store's slow path goes after the blocks (`goCold`), so the
//! fast path falls through.
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

pub const emitter_def: emitter.Emitter = .{ .name = "x86-64", .lazy_eflags = true, .emit = emit };

const win64 = builtin.os.tag == .windows;
/// SSE2 is every x86-64's; SSSE3 and SSE4.1 only where the build targets
/// them (the host's own CPU for native builds).
const ssse3 = builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .ssse3);
const sse41 = builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .sse4_1);
const sse42 = builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .sse4_2);
const fma3 = builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .fma);

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
/// Where MXCSR goes through on its way to and from a register: the last
/// staging slot, free outside a call.
const mxcsr_tmp = staging + 32;
/// The guest's flags word while pending.flags defers it (E.pend_off).
const pend_slot = io_base + 48;
/// NZCV pending in the host's form (E.raw_inv), the 4 bytes after
/// pend_slot: OF from seto, then lahf's byte. 0xff in the first means
/// nothing is pending there, and pend_slot holds the flags too.
const raw_slot = pend_slot + 4;
/// The same_page hint's pairs: a page number and its TLB delta, each
/// saved by an access that a later one in its block names (hintPlan).
const hint_slots = 4;
const hint_base = pend_slot + 8;
/// Where a call keeps the live values of caller-saved registers.
const save_base = hint_base + 16 * hint_slots;
const slots_base = save_base + 8 * 16;

/// The callee-saved registers every region pushes after rbp, in order.
const saved_regs: []const u8 = if (win64) &.{ RBX, R12, R13, R14, R15, RSI, RDI } else &.{ RBX, R12, R13, R14, R15 };
/// Bytes from rbp down to the last push: rsp at the chain entry is rbp
/// less this.
const saved_bytes: u8 = 8 * saved_regs.len;
/// How far below rbp the pushes end: rbp is set right after `push rbp`
/// (a frame-pointer chain, for SysV stack walks), or on Win64 after every
/// push, as its unwinder wants a frame register set last.
const rbp_above: u8 = if (win64) 0 else saved_bytes;

/// Win64's UNWIND_INFO for every region (codemem.Region.addUnwind): no
/// prolog to undo partway (unwinding only ever starts in a body), rbp the
/// frame register, and the codes in reverse prolog order: rsp = rbp, then
/// the pushes, saved_regs backward and rbp last.
pub const win64_unwind: []const u8 = blk: {
    var b: []const u8 = &.{ 1, 0, saved_regs.len + 2, RBP };
    b = b ++ &[_]u8{ 0, 3 }; // UWOP_SET_FPREG
    var k = saved_regs.len;
    while (k > 0) {
        k -= 1;
        b = b ++ &[_]u8{ 0, @as(u8, saved_regs[k]) << 4 }; // UWOP_PUSH_NONVOL
    }
    b = b ++ &[_]u8{ 0, RBP << 4 };
    if ((saved_regs.len + 2) % 2 != 0) b = b ++ &[_]u8{ 0, 0 };
    break :blk b;
};
/// Registers a call may clobber, of those regalloc hands out.
const caller_saved_mask: u64 = if (win64) (1 << R8) else (1 << RSI) | (1 << RDI) | (1 << R8);
/// Instructions retired since ctx.retired and ctx.budget were last
/// brought up to date (ir.zig's rule): `retire` adds here, and `flush`
/// moves it to the Ctx at exits and calls.
const PENDING = R9;

pub const host: regalloc.Host = .{
    .regs = &.{ RSI, RDI, R8, R12, R13, R14, R15 },
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

/// A poll's way out, emitted after the blocks: the jcc's rel32 to land,
/// and what leave() needs.
const Cold = struct { at: usize, pc: u64, retired: u64, dirty: regalloc.ChunkSet };

/// Positions in `E.cold_code` are this plus the offset there, until it's
/// appended after the blocks.
const cold_at: usize = 1 << 40;

/// A rel32 from one of main and cold code to the other, patched once the
/// cold code has its place.
const Cross = struct { at: usize, to: usize };

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
    /// Some fp op reports exceptions to the guest (aux2): MXCSR's flags
    /// then hold only what native ops raised since they were last cleared,
    /// all of it already in the guest's words (see fpNative).
    watch: bool = false,
    /// A condition computed early into r11 (condEarly), to go to its
    /// value when the emit loop reaches it.
    pending: ?usize = null,
    /// pending.flags deferred (pendMode): the Cpu offset of the flags
    /// word, which pend_slot holds for the whole region. It's the word in
    /// memory except while flags are pending, and goes out at every exit
    /// and call (syncPend); null when each pending.flags writes at once.
    pend_off: ?i32 = null,
    /// With pend_off, for nzcv: pending.flags keeps the host's flags
    /// as they are (raw_slot), packing them only at syncPend. True when
    /// the region's flags ops leave CF as Arm's !C (subtracts), false
    /// when as C (adds and logic ops); null when they mix, or for eflags.
    raw_inv: ?bool = null,
    /// The flags op whose host flags are in EFLAGS now (sameFlags tells
    /// which others it serves), or null. Ops that keep EFLAGS leave it
    /// (keepsFlags); movImm then doesn't use xor.
    hf: ?ir.Ref = null,
    /// lower() set hf (to a new op, or kept it).
    hf_set: bool = false,
    /// Poll exits, emitted out of line after the blocks.
    cold: std.ArrayList(Cold) = .empty,
    /// Per instruction: the hint pair a load or store saves its page and
    /// delta to (a later access names it), or -1; and the pair it may
    /// take them from instead of the TLB (its same_page hint), or -1.
    hint_save: []i8 = &.{},
    hint_use: []i8 = &.{},
    /// Slow paths, out of line (goCold), so the fast paths are dense.
    cold_code: std.ArrayList(u8) = .empty,
    in_cold: bool = false,
    cross: std.ArrayList(Cross) = .empty,

    /// What follows goes to the cold code, until goHot.
    fn goCold(e: *E) !void {
        std.debug.assert(!e.in_cold);
        try e.cross.ensureUnusedCapacity(e.gpa, 4);
        e.in_cold = true;
    }
    fn goHot(e: *E) void {
        e.in_cold = false;
    }
    fn buf(e: *E) *std.ArrayList(u8) {
        return if (e.in_cold) &e.cold_code else e.out;
    }

    /// pend_slot to the guest's word. r10 and r11 only.
    fn syncPend(e: *E) !void {
        const off = e.pend_off orelse return;
        if (e.raw_inv) |inv| {
            // Host flags pending: NZCV from them into pend_slot first.
            try e.rm(false, &.{0x80}, 7, RSP, raw_slot); // cmp byte [rsp+raw], 0xff
            try e.b(0xff);
            const none = try e.fwd(CC.e);
            try e.rm(false, &.{ 0x0f, 0xb6 }, R11, RSP, raw_slot + 1); // movzx r11d, lahf's byte
            try e.mov(R10, R11);
            try e.aluImm(false, 4, R10, 1);
            if (inv) try e.aluImm(false, 6, R10, 1);
            try e.shiftImm(false, 4, R10, 29); // C
            try e.aluImm(false, 4, R11, 0xc0);
            try e.shiftImm(false, 4, R11, 24); // N, Z
            try e.rr(false, &.{0x09}, R10, R11);
            try e.rm(false, &.{ 0x0f, 0xb6 }, R10, RSP, raw_slot); // movzx r10d, OF
            try e.shiftImm(false, 4, R10, 28); // V
            try e.rr(false, &.{0x09}, R10, R11);
            try e.rm(false, &.{0x8b}, R10, RSP, pend_slot);
            try e.aluImm(false, 4, R10, 0x0fff_ffff);
            try e.rr(false, &.{0x09}, R10, R11);
            try e.rm(false, &.{0x89}, R11, RSP, pend_slot);
            try e.rawNone();
            e.land(none);
        }
        try e.rm(false, &.{0x8b}, R11, RSP, pend_slot); // mov r11d, [rsp+pend]
        try e.ldCtx(R10, ctx.off.cpu);
        try e.rm(false, &.{0x89}, R11, R10, off); // mov [cpu+off], r11d
    }
    /// The guest's word to pend_slot, once it has changed in memory. rax
    /// and r10 only (r11 may hold condEarly's condition).
    fn reloadPend(e: *E) !void {
        const off = e.pend_off orelse return;
        try e.ldCtx(R10, ctx.off.cpu);
        try e.rm(false, &.{0x8b}, RAX, R10, off);
        try e.rm(false, &.{0x89}, RAX, RSP, pend_slot);
        if (e.raw_inv != null) try e.rawNone();
    }
    fn setHf(e: *E, v: ir.Ref) void {
        e.hf = v;
        e.hf_set = true;
    }
    /// raw_slot holds nothing pending. Leaves EFLAGS alone.
    fn rawNone(e: *E) !void {
        try e.rm(false, &.{0xc6}, 0, RSP, raw_slot); // mov byte [rsp+raw], 0xff
        try e.b(0xff);
    }

    fn pos(e: *E) usize {
        if (e.in_cold) return cold_at + e.cold_code.items.len;
        return e.out.items.len - e.base;
    }
    fn b(e: *E, v: u8) !void {
        try e.buf().append(e.gpa, v);
    }
    fn bs(e: *E, v: []const u8) !void {
        try e.buf().appendSlice(e.gpa, v);
    }
    fn d32(e: *E, v: u32) !void {
        try e.bs(std.mem.asBytes(&std.mem.nativeToLittle(u32, v)));
    }
    fn q64(e: *E, v: u64) !void {
        try e.bs(std.mem.asBytes(&std.mem.nativeToLittle(u64, v)));
    }
    fn patch32(e: *E, at: usize, v: u32) void {
        const bytes = if (at >= cold_at) e.cold_code.items[at - cold_at ..] else e.out.items[e.base + at ..];
        std.mem.writeInt(u32, bytes[0..4], v, .little);
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
    /// `dst` = value `v`, from its register or slot, or for a constant
    /// kept nowhere (foldConst), its value. EFLAGS are kept.
    fn ldVal(e: *E, dst: u8, v: ir.Ref) !void {
        switch (e.p.locs[v]) {
            .reg => |x| try e.mov(dst, @intCast(x)),
            .slot => |s| try e.ldSlot(dst, s),
            .none => {
                const k = e.r.insts.items[v];
                std.debug.assert(k.op == .@"const");
                const hf = e.hf;
                e.hf = v; // not xor: it would change EFLAGS
                defer e.hf = hf;
                try e.movImm(dst, k.aux);
            },
        }
    }
    /// The ALU op whose "op reg, r/m" opcode is `opc` (add, or, and, sub,
    /// xor, or cmp), with `d` and value `v`: v's register, its slot, or a
    /// constant kept nowhere as an immediate. r10 is clobbered for a
    /// constant that doesn't fit one.
    fn aluVal(e: *E, w: bool, opc: u8, d: u8, v: ir.Ref) !void {
        switch (e.p.locs[v]) {
            .reg => |x| try e.rr(w, &.{opc}, d, @intCast(x)),
            .slot => |s| try e.rm(w, &.{opc}, d, RSP, slotDisp(s)),
            .none => {
                const k = e.r.insts.items[v].aux;
                if (immFits(w, k)) {
                    const ext: u8 = switch (opc) {
                        0x03 => 0,
                        0x0b => 1,
                        0x23 => 4,
                        0x2b => 5,
                        0x33 => 6,
                        0x3b => 7,
                        else => unreachable,
                    };
                    try e.aluImm(w, ext, d, @bitCast(@as(u32, @truncate(k))));
                } else {
                    try e.ldVal(R10, v);
                    try e.rr(w, &.{opc}, d, R10);
                }
            },
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
        if (imm == 0 and e.hf == null) {
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
        if (imm >= -128 and imm <= 127) {
            try e.rr(w, &.{0x83}, n, dst);
            return e.b(@bitCast(@as(i8, @intCast(imm))));
        }
        try e.rr(w, &.{0x81}, n, dst);
        try e.d32(@bitCast(imm));
    }

    /// op qword [base+disp], imm32: /n of 0x81 (0x83 for an imm8).
    fn aluMemImm(e: *E, n: u8, base: u8, disp: i32, imm: i32) !void {
        if (imm >= -128 and imm <= 127) {
            try e.rm(true, &.{0x83}, n, base, disp);
            return e.b(@bitCast(@as(i8, @intCast(imm))));
        }
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
        const to = e.pos();
        if ((at >= cold_at) != (to >= cold_at)) {
            // goCold made room.
            e.cross.appendAssumeCapacity(.{ .at = at, .to = to });
            return;
        }
        e.patch32(at, @bitCast(@as(i32, @intCast(@as(isize, @intCast(to)) - @as(isize, @intCast(at + 4))))));
    }

    /// ctx.retired += n, ctx.budget -= n. No registers.
    /// On a path out: counts `n` more, then flushes what's pending.
    fn retireOn(e: *E, n: u64) !void {
        try e.retireLater(n);
        try e.flush();
    }
    /// pending += n.
    fn retireLater(e: *E, n: u64) !void {
        if (n == 0) return;
        if (n > std.math.maxInt(i32)) {
            try e.movImm(R10, n);
            try e.rr(true, &.{0x01}, R10, PENDING); // add r9, r10
        } else try e.rm(true, &.{0x8d}, PENDING, PENDING, @intCast(n)); // lea r9, [r9+n]: EFLAGS kept
    }
    /// ctx.retired += pending, ctx.budget -= pending, pending = 0.
    fn flush(e: *E) !void {
        try e.rm(true, &.{0x01}, PENDING, CTX, ctx.off.retired); // add [retired], r9
        // Locked: a kick from another thread lowers the budget too
        // (cache.request), and an unlocked sub could lose its store.
        try e.b(0xf0);
        try e.rm(true, &.{0x29}, PENDING, CTX, ctx.off.budget); // lock sub [budget], r9
        try e.rr(false, &.{0x31}, PENDING, PENDING); // xor r9d, r9d
    }

    /// Sets exit_pc and leaves with `code`, counting `n` retired.
    fn leave(e: *E, code: ctx.Exit, pc: u64, n: u64) !void {
        try e.writeback(e.dirty);
        try e.syncPend();
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
        try e.flush();
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
        try e.rr(false, &.{0x31}, PENDING, PENDING); // r9 is the callee's
        try e.restoreRegs(live);
        if (e.watch) try clearHostFlags(e);
    }

    /// With the host's flags just set as the flags op at `idx` defines
    /// them: the first `cond` of it later in the block, if only ops that
    /// leave r11 alone come between, is computed now with a setcc (instead
    /// of a popfq when it's reached). Right after, it goes to its value;
    /// further on, r11 holds it until then (`pending`). `ccOf` maps the
    /// condition's aux to a host condition, or null.
    fn condEarly(e: *E, r: *const ir.Region, idx: usize, cond: Op, ccOf: *const fn (u64) ?u8) !void {
        const blk = r.blocks.items[e.block];
        var k = idx + 1;
        while (k < blk.start + blk.len) : (k += 1) {
            const n = r.insts.items[k];
            if (n.op == cond and n.a == idx) break;
            const keeps_r11 = switch (n.op) {
                .@"const", .getreg, .add, .sub, .@"and", .@"or", .xor, .zext, .trunc, .@"nzcv.pack", .@"eflags.pack", .retire => n.ty != .v128,
                .setreg => r.insts.items[n.a].ty != .v128,
                else => false,
            };
            if (!keeps_r11) return;
        } else return;
        const cc = ccOf(r.insts.items[k].aux) orelse return;
        try e.bs(&.{ 0x41, 0x0f, 0x90 + cc, 0xc3 }); // setcc r11b
        try e.bs(&.{ 0x45, 0x0f, 0xb6, 0xdb }); // movzx r11d, r11b
        e.pending = k;
    }

    /// lea rsp, [rbp - rbp_above]: the frame torn down to the pushes.
    fn dropFrame(e: *E) !void {
        try e.bs(&.{ 0x48, 0x8d, 0x65, @bitCast(-@as(i8, rbp_above)) });
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
    const extend = try lazyExtend(gpa, r);
    defer gpa.free(extend);
    var p = regalloc.planExtended(gpa, r, host, null, extend) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooLarge => error.TooLarge,
    };
    defer p.deinit(gpa);
    var e: E = .{ .gpa = gpa, .out = out, .base = out.items.len, .r = r, .p = &p };
    e.pend_off = pendMode(r, &p);
    if (e.pend_off != null) e.raw_inv = rawMode(r);
    for (r.insts.items) |i| {
        if (i.op.isFp() and i.aux2 != 0) e.watch = true;
    }
    try replan(&e, &p, extend);
    if (p.slots > (std.math.maxInt(i32) - slots_base) / 8) return error.TooLarge;
    defer e.fixups.deinit(gpa);
    defer e.cold.deinit(gpa);
    defer e.cold_code.deinit(gpa);
    defer e.cross.deinit(gpa);
    e.hint_save = try gpa.alloc(i8, r.insts.items.len);
    defer gpa.free(e.hint_save);
    e.hint_use = try gpa.alloc(i8, r.insts.items.len);
    defer gpa.free(e.hint_use);
    hintPlan(r, e.hint_save, e.hint_use);
    const block_pos = try gpa.alloc(usize, r.blocks.items.len);
    defer gpa.free(block_pos);

    // Prologue.
    try e.b(0x55); // push rbp
    if (!win64) try e.bs(&.{ 0x48, 0x89, 0xe5 }); // mov rbp, rsp
    for (saved_regs) |x| {
        try e.rex(false, 0, 0, x);
        try e.b(0x50 + (x & 7)); // push
    }
    if (win64) try e.bs(&.{ 0x48, 0x89, 0xe5 }); // mov rbp, rsp: as win64_unwind says
    try e.mov(CTX, if (win64) RCX else RDI);
    // The chain entry: linked sites and jump-cache hits land here, with rbx
    // the context and rsp at rbp - rbp_above (the frame torn down).
    e.code.chain_entry = @intCast(e.pos());
    // The pushes leave rsp 8 off 16-byte alignment (an odd number of
    // them); the frame puts it back.
    comptime std.debug.assert(saved_regs.len % 2 == 1);
    const frame: u32 = ((slots_base + p.slots * 8 + 15) & ~@as(u32, 15)) + 8;
    try e.rr(true, &.{0x81}, 5, RSP); // sub rsp, frame
    try e.d32(frame);
    try e.rr(false, &.{0x31}, PENDING, PENDING); // xor r9d, r9d: nothing pending
    try e.loadChunks();
    try e.reloadPend();
    if (e.watch) try clearHostFlags(&e);

    for (r.blocks.items, 0..) |blk, bi| {
        block_pos[bi] = e.pos();
        e.block = @intCast(bi);
        e.dirty = p.dirty_in[bi];
        e.hf = null;
        var idx = blk.start;
        while (idx < blk.start + blk.len) : (idx += 1) {
            e.idx = idx;
            if (e.pending == idx) {
                e.pending = null;
                e.hf = null;
                try e.stVal(@intCast(idx), R11);
                continue;
            }
            e.hf_set = false;
            try lower(&e, r, idx);
            if (!e.hf_set and !keepsFlags(&e, r, idx)) e.hf = null;
            if (e.pend_off) |po| switch (r.insts.items[idx].op) {
                // The callee may have changed the word; a setreg over it
                // drops what's pending.
                .@"call.interp" => try e.reloadPend(),
                .@"call.helper" => if (r.insts.items[idx].aux2 & ir.helper_no_regs == 0) try e.reloadPend(),
                .setreg => if (overlaps(r, r.insts.items[idx], @intCast(po))) try e.reloadPend(),
                else => {},
            };
            // The guest set an exception word: start the host's flags over.
            if (e.watch and r.insts.items[idx].op == .setreg and setsWatched(r, r.insts.items[idx])) try clearHostFlags(&e);
        }
    }

    // The polls' ways out.
    for (e.cold.items) |c| {
        e.land(c.at);
        e.dirty = c.dirty;
        e.hf = null;
        try e.leave(.interrupted, c.pc, c.retired);
    }

    // The slow paths.
    const cold_pos = e.pos();
    try e.out.appendSlice(gpa, e.cold_code.items);
    const place = struct {
        fn f(at: usize, cp: usize) usize {
            return if (at >= cold_at) at - cold_at + cp else at;
        }
    }.f;

    // Epilogue: eax holds the exit code.
    const epi = e.pos();
    try e.dropFrame();
    try popAndReturn(&e);

    for (e.fixups.items) |f| {
        const to = if (f.target == epilogue) epi else block_pos[f.target];
        const at = place(f.pos, cold_pos);
        e.patch32(at, @bitCast(@as(i32, @intCast(@as(isize, @intCast(to)) - @as(isize, @intCast(at + 4))))));
    }
    for (e.cross.items) |c| {
        const at = place(c.at, cold_pos);
        const to = place(c.to, cold_pos);
        e.patch32(at, @bitCast(@as(i32, @intCast(@as(isize, @intCast(to)) - @as(isize, @intCast(at + 4))))));
    }
    e.code.entry = 0;
    return e.code;
}

/// Plans the region again with the values kept nowhere left out (regalloc's
/// `virtual`): those kept in EFLAGS (deferIcmp, deferNzcv), and getregs
/// of a whole chunk that read its register in place (chunkAlias), whose
/// location becomes that register. The chunks don't change.
fn replan(e: *E, p: *regalloc.Plan, extend: []const u32) !void {
    const r = e.r;
    const n = r.insts.items.len;
    const virt = try e.gpa.alloc(bool, n);
    defer e.gpa.free(virt);
    const alias = try e.gpa.alloc(u8, n);
    defer e.gpa.free(alias);
    var any = false;
    for (r.blocks.items, 0..) |blk, bi| {
        e.block = @intCast(bi);
        for (blk.start..blk.start + blk.len) |idx| {
            alias[idx] = chunkAlias(e, r, idx) orelse 0xff;
            virt[idx] = alias[idx] != 0xff or deferIcmp(e, r, idx) or deferNzcv(e, r, idx) or lazyOnly(e, r, idx) or foldConst(r, idx);
            any = any or virt[idx];
        }
    }
    e.block = 0;
    if (!any) return;
    var q = regalloc.planExtended(e.gpa, r, host, virt, extend) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooLarge => error.TooLarge,
    };
    std.debug.assert(q.chunks.len == p.chunks.len);
    for (alias, 0..) |a, v| if (a != 0xff) {
        q.locs[v] = .{ .reg = a };
    };
    p.deinit(e.gpa);
    p.* = q;
}

/// The chunk register getreg `idx` may read in place, its value never
/// copied out: a whole chunk (movesOnly) that nothing changes while the
/// value lives.
fn chunkAlias(e: *const E, r: *const ir.Region, idx: usize) ?u8 {
    const i = r.insts.items[idx];
    if (i.op != .getreg) return null;
    const ck = e.p.chunk_of[idx];
    if (ck == regalloc.no_chunk or !movesOnly(e, r, idx)) return null;
    for (idx + 1..e.p.end[idx] + 1) |j| {
        const n = r.insts.items[j];
        switch (n.op) {
            .setreg => if (e.p.chunk_of[j] == ck) return null,
            .@"call.interp", .copy, .@"pending.flags" => return null,
            .@"call.helper" => if (n.aux2 & ir.helper_no_regs == 0) return null,
            else => {},
        }
    }
    return @intCast(e.p.chunks[ck].reg);
}

/// Whether getreg or setreg `i` touches a byte of the u32 at `off`.
fn overlaps(r: *const ir.Region, i: ir.Inst, off: u64) bool {
    const t = if (i.op == .setreg) r.insts.items[i.a].ty else i.ty;
    const n: u64 = switch (t) {
        .i1, .i8 => 1,
        .i16 => 2,
        .i32 => 4,
        .v128 => 16,
        else => 8,
    };
    return i.aux < off + 4 and off < i.aux + n;
}

/// The flags word's Cpu offset when pending.flags can stay pending for
/// the whole region, across its edges (E.pend_off): every pending.flags
/// names the same word and kind, nothing in the region reads the word
/// (so it's stale in memory only where nothing looks), and no chunk
/// holds it. Null otherwise: each pending.flags is written at once.
fn pendMode(r: *const ir.Region, p: *const regalloc.Plan) ?i32 {
    var off: ?u64 = null;
    var kind: u64 = 0;
    for (r.insts.items) |i| if (i.op == .@"pending.flags") {
        if (i.aux2 == 2) return null; // lazy: written at once (lazyStore)
        if (off) |o| {
            if (o != i.aux or kind != i.aux2) return null;
        } else {
            off = i.aux;
            kind = i.aux2;
        }
    };
    const o = off orelse return null;
    for (r.insts.items) |i| if (i.op == .getreg and overlaps(r, i, o)) return null;
    for (p.chunks) |c| if (o < c.off + c.bytes and c.off < o + 4) return null;
    return std.math.cast(i32, o);
}

/// Whether setreg `i` writes a byte of a word some fp op reports to.
fn setsWatched(r: *const ir.Region, i: ir.Inst) bool {
    const n: u64 = switch (r.insts.items[i.a].ty) {
        .i8 => 1,
        .i16 => 2,
        .i32 => 4,
        .v128 => 16,
        else => 8,
    };
    for (r.insts.items) |f| {
        if (!f.op.isFp() or f.aux2 == 0) continue;
        const w = f.aux2 - 1;
        if (i.aux < w + 4 and w < i.aux + n) return true;
    }
    return false;
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
    if (try inFlags(e, r, idx)) return;
    // A constant kept nowhere: its uses take it as it is (foldConst).
    if (i.op == .@"const" and e.p.locs[dst] == .none) return;
    if (try direct(e, i, dst)) return;
    if (try chunkMove(e, r, idx)) return;
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
                // At i32 too, so EFLAGS are the op's (flagSrc).
                .add => try e.rr(ty != .i32, &.{0x01}, RCX, RAX),
                .sub => try e.rr(ty != .i32, &.{0x29}, RCX, RAX),
                .@"and" => try e.rr(true, &.{0x21}, RCX, RAX),
                .@"or" => try e.rr(true, &.{0x09}, RCX, RAX),
                .xor => try e.rr(true, &.{0x31}, RCX, RAX),
                .mul => try e.rr(true, &.{ 0x0f, 0xaf }, RAX, RCX), // imul rax, rcx
                else => unreachable,
            }
            try maskTo(e, ty);
            if ((i.op == .add or i.op == .sub) and native(ty)) e.setHf(dst);
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
            e.setHf(dst);
        } else if (ta == .i8 or ta == .i16) {
            // Widened to 32 bits, signed for the signed predicates.
            const signed = i.aux >= @intFromEnum(ir.Pred.slt);
            const op2: u8 = (if (ta == .i8) @as(u8, 0xb6) else 0xb7) | (if (signed) @as(u8, 8) else 0);
            try e.bs(&.{ 0x0f, op2, 0xc0 }); // movzx/movsx eax, al/ax
            try e.bs(&.{ 0x0f, op2, 0xc9 }); // movzx/movsx ecx, cl/cx
            try e.rr(false, &.{0x39}, RCX, RAX); // cmp eax, ecx
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
            // After a subtract the host's CF is Arm's !C, the form
            // nzcv_cc is for.
            if (i.op == .@"nzcv.sub" or i.op == .@"nzcv.sbc") try e.condEarly(r, idx, .@"nzcv.cond", nzcvCc);
            const invert_c = i.op == .@"nzcv.sub" or i.op == .@"nzcv.sbc";
            if (lahf_ok) {
                try lahfNzcv(e, invert_c, i.op == .@"nzcv.logic");
            } else {
                try hostFlags(e);
                try packNzcv(e, invert_c, i.op == .@"nzcv.logic");
            }
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
            try e.condEarly(r, idx, .@"eflags.cond", if (i.op == .@"eflags.inc" or i.op == .@"eflags.dec") eflagsCcNoCf else eflagsCc);
            if (lahf_ok) {
                // lahf's SF ZF AF PF CF sit where EFLAGS has them; OF is
                // bit 11.
                try e.bs(&.{ 0x0f, 0x90, 0xc2 }); // seto dl
                try e.b(0x9f); // lahf
                try e.bs(&.{ 0x0f, 0xb6, 0xc4 }); // movzx eax, ah
                try e.bs(&.{ 0x0f, 0xb6, 0xd2 }); // movzx edx, dl
                try e.shiftImm(false, 4, RDX, 11);
                try e.rr(false, &.{0x09}, RDX, RAX);
            } else try hostFlags(e);
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
            try e.syncPend();
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
            try e.syncPend();
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
            // A helper that touches no guest register (helper_no_regs)
            // leaves the chunks, dirty or not, and pending flags as they
            // are: they're in callee-saved registers and the frame.
            const regs = i.aux2 & ir.helper_no_regs == 0;
            if (regs) {
                try e.writeback(e.dirty);
                try e.syncPend();
                e.dirty = 0;
            }
            try e.ldCtx(R11, ctx.off.helpers);
            try e.load(R11, R11, std.math.cast(i32, i.aux * 8) orelse return error.Unsupported);
            // Missing arguments are 0, as in ir_eval.
            const args = [3]E.Arg{
                if (i.a != ir.none) .{ .reg = RAX } else .{ .imm = 0 },
                if (i.b != ir.none) .{ .reg = RCX } else .{ .imm = 0 },
                if (i.c != ir.none) .{ .reg = RDX } else .{ .imm = 0 },
            };
            try e.call(&args);
            if (regs) try e.loadChunks();
        },
        .poll => {
            // The budget alone: a request lowers it too (cache.request).
            try e.rm(true, &.{0x39}, PENDING, CTX, ctx.off.budget); // cmp [budget], r9: budget - pending
            try e.cold.append(e.gpa, .{ .at = try e.fwd(CC.le), .pc = i.aux, .retired = i.retired, .dirty = e.dirty });
        },
        .retire => try e.retireLater(i.aux),
        .@"pending.flags" => {
            // Written at once, which ir.zig allows. A chunk over the word
            // goes out first and comes back after.
            const mask: u32 = if (i.aux2 == 0) 0xf000_0000 else @intCast(ir_eval.eflags_mask);
            const off: i32 = std.math.cast(i32, i.aux) orelse return error.Unsupported;
            var over: regalloc.ChunkSet = 0;
            for (e.p.chunks, 0..) |c, k| {
                if (i.aux < c.off + c.bytes and c.off < i.aux + 4) over |= @as(regalloc.ChunkSet, 1) << @intCast(k);
            }
            try e.aluImm(false, 4, RAX, @bitCast(mask)); // and eax, mask
            if (e.raw_inv) |inv| {
                // To raw_slot's form: V, then N Z and C as lahf has them.
                try e.mov(RCX, RAX);
                try e.shiftImm(false, 5, RCX, 28);
                try e.aluImm(false, 4, RCX, 1);
                try e.rm(false, &.{0x88}, RCX, RSP, raw_slot); // mov [rsp+raw], cl
                try e.mov(RDX, RAX);
                try e.shiftImm(false, 5, RDX, 24);
                try e.aluImm(false, 4, RDX, 0xc0);
                try e.shiftImm(false, 5, RAX, 29);
                try e.aluImm(false, 4, RAX, 1);
                if (inv) try e.aluImm(false, 6, RAX, 1);
                try e.rr(false, &.{0x09}, RDX, RAX);
                try e.rm(false, &.{0x88}, RAX, RSP, raw_slot + 1); // mov [rsp+raw+1], al
                return;
            }
            if (e.pend_off != null) {
                // Merged into pend_slot (pendMode saw to it that no chunk
                // holds the word).
                try e.rm(false, &.{0x8b}, RCX, RSP, pend_slot);
                try e.aluImm(false, 4, RCX, @bitCast(~mask));
                try e.rr(false, &.{0x09}, RCX, RAX); // or eax, ecx
                try e.rm(false, &.{0x89}, RAX, RSP, pend_slot);
                return;
            }
            try e.writeback(over & e.dirty);
            e.dirty &= ~over;
            // Merged into the word: old & ~mask | pack.
            try e.ldCtx(R10, ctx.off.cpu);
            try e.rm(false, &.{0x8b}, RCX, R10, off); // mov ecx, [cpu+off]
            try e.aluImm(false, 4, RCX, @bitCast(~mask)); // and ecx, ~mask
            try e.rr(false, &.{0x09}, RCX, RAX); // or eax, ecx
            try e.rm(false, &.{0x89}, RAX, R10, off); // mov [cpu+off], eax
            for (e.p.chunks, 0..) |_, k| {
                if (over & (@as(regalloc.ChunkSet, 1) << @intCast(k)) != 0) try e.chunkAccess(k, false);
            }
        },
        .br => if (i.aux != e.block + 1) try e.jmpTo(null, @intCast(i.aux)),
        .brcond => {
            try e.rr(false, &.{0x85}, RAX, RAX);
            try branch(e, CC.ne, i);
        },
        .@"exit.chain" => {
            try e.writeback(e.dirty);
            try e.syncPend();
            try e.retireOn(i.retired);
            try e.dropFrame(); // the chain entry's stack
            std.debug.assert(!e.in_cold);
            while ((e.pos() + 1) % 4 != 0) try e.b(0x90);
            const site = e.pos();
            try e.bs(&.{ 0xe9, 0, 0, 0, 0 }); // jmp .+5, until linked
            if (e.code.nchains < emitter.max_chains) {
                e.code.chains[e.code.nchains] = .{ .site = @intCast(site), .pc = i.aux };
                e.code.nchains += 1;
            }
            // Unlinked (or never linkable: another page, or past the
            // sites the cache keeps): the jump cache, inline, at the
            // target's fixed entry.
            {
                const slot: i32 = @intCast(ctx.jumpIndex(i.aux) * @sizeOf(ctx.JumpEntry));
                try e.ldCtx(R10, ctx.off.jump);
                try e.rr(true, &.{0x85}, R10, R10); // test r10, r10
                const none = try e.fwd(CC.e);
                try e.movImm(RCX, i.aux);
                try e.rm(true, &.{0x39}, RCX, R10, slot); // cmp [r10+slot], rcx
                const miss = try e.fwd(CC.ne);
                try e.rm(false, &.{0xff}, 4, R10, slot + @offsetOf(ctx.JumpEntry, "code")); // jmp [r10+slot+code]
                e.land(none);
                e.land(miss);
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
            try e.syncPend();
            try e.retireOn(i.retired);
            try e.stCtx(ctx.off.exit_pc, RAX);
            // The jump cache, inline: a hit goes straight to the target's
            // chain entry, with the frame torn down as at a chain site.
            try e.ldCtx(R10, ctx.off.jump);
            try e.rr(true, &.{0x85}, R10, R10); // test r10, r10
            const none = try e.fwd(CC.e);
            // ctx.jumpIndex: ((pc ^ pc >> 12) >> 2) & (jump_entries - 1)
            try e.mov(RCX, RAX);
            try e.shiftImm(true, 5, RCX, 12); // shr rcx, 12
            try e.rr(true, &.{0x31}, RAX, RCX); // xor rcx, rax
            try e.shiftImm(true, 5, RCX, 2); // shr rcx, 2
            try e.aluImm(false, 4, RCX, ctx.jump_entries - 1); // and ecx, 4095
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

// ---- EFLAGS across ops
//
// A compare feeding a brcond, and an nzcv op feeding pending.flags, can
// stay in the host's EFLAGS from where they're computed to their use, if
// every op between leaves EFLAGS alone or would set them the same way
// (sameFlags). Then the compare is a jcc, and pending.flags stores lahf
// and seto (raw_slot) rather than packing NZCV.

/// The host flags an op leaves, where two ops can share them: those of
/// `sub` (or `add`) a, b at `ty`. sub, nzcv.sub, and icmp (a cmp) give
/// the same ones.
const FlagSrc = struct { add: bool, a: ir.Ref, b: ir.Ref, ty: Type };

fn flagSrc(r: *const ir.Region, idx: usize) ?FlagSrc {
    const i = r.insts.items[idx];
    const ta: Type = if (i.a != ir.none) r.insts.items[i.a].ty else .none;
    return switch (i.op) {
        .add, .sub => if (native(i.ty)) .{ .add = i.op == .add, .a = i.a, .b = i.b, .ty = i.ty } else null,
        .@"nzcv.add", .@"nzcv.sub", .icmp => if (native(ta)) .{ .add = i.op == .@"nzcv.add", .a = i.a, .b = i.b, .ty = ta } else null,
        else => null,
    };
}

fn sameFlags(r: *const ir.Region, x: usize, y: usize) bool {
    const fx = flagSrc(r, x) orelse return false;
    const fy = flagSrc(r, y) orelse return false;
    return std.meta.eql(fx, fy);
}

/// getreg or setreg `idx` is only moves: a whole chunk (not i1, which
/// maskTo ands), or the Cpu in memory.
fn movesOnly(e: *const E, r: *const ir.Region, idx: usize) bool {
    const i = r.insts.items[idx];
    const t = if (i.op == .getreg) i.ty else r.insts.items[i.a].ty;
    const sz = sizeLog2(t) orelse return false;
    if (i.op == .setreg and e.watch and setsWatched(r, i)) return false;
    const ck = e.p.chunk_of[idx];
    if (ck == regalloc.no_chunk) return std.math.cast(i32, i.aux) != null;
    const c = e.p.chunks[ck];
    return i.aux == c.off and (@as(u32, 1) << @intCast(sz)) == c.bytes;
}

/// Ops that leave EFLAGS as they are (lower doesn't set hf for them).
fn keepsFlags(e: *const E, r: *const ir.Region, idx: usize) bool {
    const i = r.insts.items[idx];
    return switch (i.op) {
        .@"const" => true,
        .retire => i.aux <= std.math.maxInt(i32),
        .getreg, .setreg => movesOnly(e, r, idx),
        else => false,
    };
}

/// Whether EFLAGS as op `src` set them get past op `j` unchanged.
fn passes(e: *const E, r: *const ir.Region, j: usize, src: usize) bool {
    const n = r.insts.items[j];
    return switch (n.op) {
        .@"const", .retire, .getreg, .setreg => keepsFlags(e, r, j),
        .add, .sub, .icmp => sameFlags(r, src, j),
        .@"nzcv.add", .@"nzcv.sub" => sameFlags(r, src, j) and deferNzcv(e, r, j),
        .@"pending.flags" => e.raw_inv != null and deferNzcv(e, r, n.a),
        else => false,
    };
}

/// The one use of `idx`, later in its block, when it's of op `op` and
/// EFLAGS from `idx` reach it; else null.
fn flagUse(e: *const E, r: *const ir.Region, idx: usize, op: Op) ?usize {
    if (e.p.uses[idx] != 1) return null;
    const blk = r.blocks.items[e.block];
    var k = idx + 1;
    while (k < blk.start + blk.len) : (k += 1) {
        const n = r.insts.items[k];
        if (n.op == op and n.a == idx) return k;
        if (!passes(e, r, k, idx)) return null;
    }
    return null;
}

/// An icmp that's only its brcond's jcc.
fn deferIcmp(e: *const E, r: *const ir.Region, idx: usize) bool {
    const i = r.insts.items[idx];
    if (i.op != .icmp or !native(r.insts.items[i.a].ty)) return false;
    return flagUse(e, r, idx, .brcond) != null;
}

/// An nzcv op that's only its pending.flags' raw store.
fn deferNzcv(e: *const E, r: *const ir.Region, idx: usize) bool {
    const inv = e.raw_inv orelse return false;
    const i = r.insts.items[idx];
    const want = switch (i.op) {
        .@"nzcv.sub" => true,
        .@"nzcv.add", .@"nzcv.logic" => false,
        else => return false,
    };
    if (want != inv or !native(r.insts.items[i.a].ty)) return false;
    return flagUse(e, r, idx, .@"pending.flags") != null;
}

/// For pendMode's nzcv word: raw_slot's sense of CF (E.raw_inv), if the
/// region's pending flags agree on it.
fn rawMode(r: *const ir.Region) ?bool {
    var inv: ?bool = null;
    for (r.insts.items) |i| if (i.op == .@"pending.flags") {
        if (i.aux2 != 0) return null;
        const want = switch (r.insts.items[i.a].op) {
            .@"nzcv.sub", .@"nzcv.sbc" => true,
            .@"nzcv.add", .@"nzcv.adc", .@"nzcv.logic" => false,
            else => continue,
        };
        if (inv) |v| {
            if (v != want) return null;
        } else inv = want;
    };
    return inv;
}

/// brcond `i` on host condition `cc`, falling through where it can.
fn branch(e: *E, cc: u8, i: ir.Inst) !void {
    const next = e.block + 1;
    if (i.aux2 == next) {
        try e.jmpTo(cc, @intCast(i.aux));
    } else if (i.aux == next) {
        try e.jmpTo(cc ^ 1, @intCast(i.aux2));
    } else {
        try e.jmpTo(cc, @intCast(i.aux));
        try e.jmpTo(null, @intCast(i.aux2));
    }
}

// ---- lazy eflags (pending.flags aux2 = 2)

/// The lazy pending.flags in `idx`'s block that uses flags op `idx`, if
/// one does.
fn lazyUse(r: *const ir.Region, idx: usize) ?usize {
    const i = r.insts.items[idx];
    if (ir.lazyKind(i.op) == null) return null;
    for (idx + 1..r.insts.items.len) |k| {
        const n = r.insts.items[k];
        if (n.op == .@"pending.flags" and n.a == idx and n.aux2 == 2) return k;
        if (n.op.isTerminator()) return null;
    }
    return null;
}

/// A flags op whose one use is a lazy pending.flags: it's never computed,
/// as the record takes its operands.
fn lazyOnly(e: *const E, r: *const ir.Region, idx: usize) bool {
    return e.p.uses[idx] == 1 and lazyUse(r, idx) != null;
}

/// Per value, the lazy pending.flags that reads it as an operand of the
/// flags op it names (regalloc.planExtended), or 0.
fn lazyExtend(gpa: std.mem.Allocator, r: *const ir.Region) ![]u32 {
    const ext = try gpa.alloc(u32, r.insts.items.len);
    @memset(ext, 0);
    for (r.insts.items, 0..) |i, k| {
        if (i.op != .@"pending.flags" or i.aux2 != 2) continue;
        const f = r.insts.items[i.a];
        for ([_]ir.Ref{ f.a, f.b, f.c }) |o| {
            if (o != ir.none) ext[o] = @max(ext[o], @as(u32, @intCast(k)));
        }
    }
    return ext;
}

/// pending.flags `i`, lazily (aux2 = 2): ir.lazyRecord of its flags op's
/// operands, stored at once at aux + 4. The operands are 64-bit slots:
/// narrower ones are zero-extended into them.
fn lazyStore(e: *E, r: *const ir.Region, i: ir.Inst) !void {
    const f = r.insts.items[i.a];
    const ft = r.insts.items[f.a].ty;
    const kind = ir.lazyKind(f.op).?;
    const size: u32 = ft.bits() / 8;
    const w = size == 8;
    const d: i32 = std.math.cast(i32, i.aux + 4) orelse return error.Unsupported;
    // A chunk over the record goes out first and comes back after.
    var over: regalloc.ChunkSet = 0;
    for (e.p.chunks, 0..) |c, k| {
        if (i.aux + 4 < c.off + c.bytes and c.off < i.aux + 4 + @sizeOf(ir.LazyRecord)) over |= @as(regalloc.ChunkSet, 1) << @intCast(k);
    }
    try e.writeback(over & e.dirty);
    e.dirty &= ~over;
    if (f.a != ir.none) try e.ldVal(RAX, f.a);
    if (f.b != ir.none) try e.ldVal(RCX, f.b);
    if (f.c != ir.none) try e.ldVal(RDX, f.c);
    try e.ldCtx(R10, ctx.off.cpu);
    const hdr: u32 = @intFromEnum(kind) | size << 8;
    // r11 = the carry in: c's CF (adc, sbb), or b's (inc and dec keep it).
    const cin: ?u8 = switch (f.op) {
        .@"eflags.adc", .@"eflags.sbb" => RDX,
        .@"eflags.inc", .@"eflags.dec" => RCX,
        else => null,
    };
    if (cin) |c| {
        try e.rr(false, &.{0x8b}, R11, c); // mov r11d, c
        try e.aluImm(false, 4, R11, 1);
        try e.rr(false, &.{0x8b}, RDX, R11); // mov edx, r11d
        try e.shiftImm(false, 4, RDX, 16);
        try e.aluImm(false, 1, RDX, @bitCast(hdr));
        try e.rm(false, &.{0x89}, RDX, R10, d);
    } else try storeImm32(e, d, hdr);
    // The operands stored whole: a (and b, for add, sub, shifts, and mul)
    // zero-extended from 32 bits; narrower ones the masks below make so.
    if (!w) {
        try e.rr(false, &.{0x8b}, RAX, RAX); // mov eax, eax
        if (kind == .add or kind == .sub or kind == .shl or kind == .shr or kind == .mul) try e.rr(false, &.{0x8b}, RCX, RCX);
    }
    switch (kind) {
        .add, .sub => {
            try e.rm(true, &.{0x89}, RAX, R10, d + 4);
            try e.rm(true, &.{0x89}, RCX, R10, d + 12);
            const opc: u8 = if (kind == .add) 0x03 else 0x2b; // add/sub r, r/m
            try e.rr(w, &.{0x8b}, RDX, RAX);
            try e.rr(w, &.{opc}, RDX, RCX);
            if (cin != null) try e.rr(w, &.{opc}, RDX, R11);
        },
        .logic => {
            try storeImm64(e, d + 4, 0);
            try storeImm64(e, d + 12, 0);
            try e.rr(w, &.{0x8b}, RDX, RAX);
        },
        .inc, .dec => {
            try e.rm(true, &.{0x89}, RAX, R10, d + 4);
            try storeImm64(e, d + 12, 1);
            try e.rr(w, &.{0x8b}, RDX, RAX);
            try e.aluImm(w, if (kind == .inc) 0 else 5, RDX, 1);
        },
        .shl, .shr => {
            try e.rm(true, &.{0x89}, RAX, R10, d + 4);
            try storeImm64(e, d + 12, 0);
            try e.rr(w, &.{0x8b}, RDX, RCX);
        },
        .mul => {
            try e.rr(false, &.{0x8b}, RDX, RAX);
            try e.aluImm(false, 4, RDX, 1);
            try e.rm(true, &.{0x89}, RDX, R10, d + 4);
            try storeImm64(e, d + 12, 0);
            try e.rr(w, &.{0x8b}, RDX, RCX);
        },
        .none => unreachable,
    }
    switch (size) {
        1 => try e.bs(&.{ 0x0f, 0xb6, 0xd2 }), // movzx edx, dl
        2 => try e.bs(&.{ 0x0f, 0xb7, 0xd2 }), // movzx edx, dx
        else => {},
    }
    try e.rm(true, &.{0x89}, RDX, R10, d + 20);
    for (e.p.chunks, 0..) |_, k| {
        if (over & (@as(regalloc.ChunkSet, 1) << @intCast(k)) != 0) try e.chunkAccess(k, false);
    }
}

/// mov qword [r10+d], imm (sign-extended from 32 bits).
fn storeImm64(e: *E, d: i32, imm: u32) !void {
    try e.rm(true, &.{0xc7}, 0, R10, d);
    try e.d32(imm);
}

/// mov dword [r10+d], imm.
fn storeImm32(e: *E, d: i32, imm: u32) !void {
    try e.rm(false, &.{0xc7}, 0, R10, d);
    try e.d32(imm);
}

/// The ops kept in EFLAGS (deferIcmp, deferNzcv), the pending.flags and
/// brcond that use them, and nothing else (false).
fn inFlags(e: *E, r: *const ir.Region, idx: usize) !bool {
    const i = r.insts.items[idx];
    if (lazyOnly(e, r, idx)) return true; // lazyStore reads its operands
    if (i.op == .@"pending.flags" and i.aux2 == 2) {
        try lazyStore(e, r, i);
        return true;
    }
    switch (i.op) {
        .icmp, .@"nzcv.add", .@"nzcv.sub", .@"nzcv.logic" => {
            if (!(if (i.op == .icmp) deferIcmp(e, r, idx) else deferNzcv(e, r, idx))) return false;
            if (e.hf) |h| if (sameFlags(r, h, idx)) {
                e.hf_set = true;
                return true;
            };
            const w = r.insts.items[i.a].ty == .i64;
            try e.ldVal(RAX, i.a);
            if (i.op == .@"nzcv.logic") {
                try e.rr(w, &.{0x85}, RAX, RAX); // test rax, rax
            } else {
                const opc: u8 = if (i.op == .@"nzcv.add") 0x03 else 0x3b; // add/cmp rax, b
                try e.aluVal(w, opc, RAX, i.b);
            }
            e.setHf(@intCast(idx));
            return true;
        },
        .@"pending.flags" => {
            if (e.raw_inv == null or !deferNzcv(e, r, i.a)) return false;
            try e.rm(false, &.{ 0x0f, 0x90 }, 0, RSP, raw_slot); // seto [rsp+raw]
            try e.b(0x9f); // lahf
            try e.rm(false, &.{0x88}, 4, RSP, raw_slot + 1); // mov [rsp+raw+1], ah
            e.hf_set = true;
            return true;
        },
        .brcond => {
            if (!deferIcmp(e, r, i.a)) return false;
            try branch(e, pred_cc[@intCast(r.insts.items[i.a].aux)], i);
            return true;
        },
        else => return false,
    }
}

/// getreg or setreg of a whole chunk, straight between its register and
/// the value's (movesOnly).
fn chunkMove(e: *E, r: *const ir.Region, idx: usize) !bool {
    const i = r.insts.items[idx];
    if (i.op != .getreg and i.op != .setreg) return false;
    const ck = e.p.chunk_of[idx];
    if (ck == regalloc.no_chunk or !movesOnly(e, r, idx)) return false;
    const creg: u8 = @intCast(e.p.chunks[ck].reg);
    if (i.op == .getreg) {
        try e.stVal(@intCast(idx), creg);
    } else {
        try e.ldVal(creg, i.a);
        e.dirty |= @as(regalloc.ChunkSet, 1) << @intCast(ck);
    }
    return true;
}

/// Ops computed straight into their value's register, when it has one:
/// constants, and 32- and 64-bit add, sub, and, or, and xor, whose b is
/// read from its register or slot. A value never shares a register with
/// its operands, so the result register can be written first. Returns
/// false, emitting nothing, for the rest.
fn direct(e: *E, i: ir.Inst, dst: ir.Ref) !bool {
    if (i.op == .setreg and e.p.chunk_of[dst] == regalloc.no_chunk) {
        // From the value's register straight to the Cpu.
        const x: u8 = @intCast(e.p.reg(i.a) orelse return false);
        const sz = sizeLog2(e.r.insts.items[i.a].ty) orelse return false;
        const disp: i32 = std.math.cast(i32, i.aux) orelse return false;
        try e.ldCtx(R10, ctx.off.cpu);
        switch (sz) {
            0 => {
                // A byte store from sil or dil wants a REX.
                try e.b(0x40 | ((x >> 3) << 2) | 1);
                try e.b(0x88);
                try e.modrmMem(x, R10, disp);
            },
            1 => try e.rm16(&.{0x89}, x, R10, disp),
            2 => try e.rm(false, &.{0x89}, x, R10, disp),
            else => try e.rm(true, &.{0x89}, x, R10, disp),
        }
        return true;
    }
    const d: u8 = @intCast(e.p.reg(dst) orelse return false);
    switch (i.op) {
        .getreg => {
            // From the Cpu straight to the value's register.
            if (e.p.chunk_of[dst] != regalloc.no_chunk) return false;
            const sz = sizeLog2(i.ty) orelse return false;
            const disp: i32 = std.math.cast(i32, i.aux) orelse return false;
            try e.ldCtx(R10, ctx.off.cpu);
            switch (sz) {
                0 => try e.rm(false, &.{ 0x0f, 0xb6 }, d, R10, disp), // movzx d32, byte
                1 => try e.rm(false, &.{ 0x0f, 0xb7 }, d, R10, disp),
                2 => try e.rm(false, &.{0x8b}, d, R10, disp),
                else => try e.rm(true, &.{0x8b}, d, R10, disp),
            }
        },
        .@"const" => try e.movImm(d, i.aux),
        .add, .sub, .@"and", .@"or", .xor => {
            if (i.ty != .i32 and i.ty != .i64) return false;
            // The "op reg, r/m" forms; 32-bit forms zero-extend.
            const opc: u8 = switch (i.op) {
                .add => 0x03,
                .sub => 0x2b,
                .@"and" => 0x23,
                .@"or" => 0x0b,
                .xor => 0x33,
                else => unreachable,
            };
            const w = i.ty == .i64;
            try e.ldVal(d, i.a);
            try e.aluVal(w, opc, d, i.b);
            if (i.op == .add or i.op == .sub) e.setHf(dst);
        },
        .shl, .lshr, .ashr, .ror, .rol => {
            // By a constant: op d, imm8 (x86 takes it mod the width, as
            // with cl).
            if (i.ty != .i32 and i.ty != .i64) return false;
            const k = e.r.insts.items[i.b];
            if (k.op != .@"const") return false;
            const n: u8 = switch (i.op) {
                .shl => 4,
                .lshr => 5,
                .ashr => 7,
                .ror => 1,
                .rol => 0,
                else => unreachable,
            };
            const w = i.ty == .i64;
            try e.ldVal(d, i.a);
            const by: u8 = @intCast(k.aux & (if (w) @as(u64, 63) else 31));
            if (by != 0) {
                try e.shiftImm(w, n, d, by);
            } else if (!w) try e.rr(false, &.{0x89}, d, d); // mov d32, d32: zero-extended as the 32-bit op would
        },
        else => return false,
    }
    return true;
}

/// Whether constant `k` is the imm32 of an op of width w (64-bit ops
/// sign-extend it).
fn immFits(w: bool, k: u64) bool {
    if (!w) return true;
    const v: i64 = @bitCast(k);
    return v >= std.math.minInt(i32) and v <= std.math.maxInt(i32);
}

/// A constant kept nowhere: every use reads it as an immediate (aluVal,
/// direct's shifts) or materializes it where it's needed (ldVal), so it
/// needs no register across its life.
fn foldConst(r: *const ir.Region, idx: usize) bool {
    const k = r.insts.items[idx];
    if (k.op != .@"const") return false;
    return switch (k.ty) {
        .i1, .i8, .i16, .i32, .i64 => true,
        else => false,
    };
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
    const key = @as(usize, @intFromEnum(i.op)) * 4 + ir.ExtAux.of(i.aux).esize;
    if (key < ext_fallbacks.len) ext_fallbacks[key] +|= 1;
    return extFallback(e, r, i, dst);
}

/// The `fp.*` and `v.*` ops compiled to ir_eval's fallback outright (not
/// a native op's slow path), by op and lane size (op * 4 + esize), for
/// the fuzzers' reports. Not atomic: a
/// tally, not an invariant.
pub var ext_fallbacks: [300 * 4]u32 = @splat(0);

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
    try tlbLookup(e, 16, table);
    const miss1 = try e.fwd(CC.ne);
    try e.rm(true, &.{0x03}, RAX, RDX, table + 8);
    if (store) {
        try vload(e, 0, RSP, slotDisp(e.vslot(i.b)));
        try vstore(e, RAX, 0, 0);
    } else {
        try vload(e, 0, RAX, 0);
        try vstore(e, RSP, slotDisp(e.vslot(dst)), 0);
    }
    const join = try e.fwd(null);
    e.land(miss1);
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
        try e.syncPend();
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
        .none => {
            // A constant kept nowhere (foldConst).
            try e.ldVal(R10, v);
            try sse(e, 0x66, true, &.{0x6e}, x, R10);
        },
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
        .@"v.zip", .@"v.uzp", .@"v.trn" => true,
        .@"v.mul" => es == 1 or (es == 2 and sse41),
        .@"v.shl", .@"v.lshr" => es != 0 and x.imm < 256,
        .@"v.ashr" => (es == 1 or es == 2) and x.imm < 256,
        .@"v.cmp" => es <= 2 or (es == 3 and (sse42 or (sse41 and (x.imm == 0 or x.imm == 1)))),
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
        .@"v.uzp" => switch (es) {
            // Even lanes (imm 0) or odd lanes of a, then of b.
            0, 1 => {
                // Each lane's half, sign-extended to the whole lane, then
                // a signed pack, which can't saturate.
                const sh: u8 = if (es == 0) 0x71 else 0x72;
                const n: u8 = if (es == 0) 8 else 16;
                for ([_]u8{ 0, 1 }) |v| {
                    if (x.imm == 0) try sseI(e, 0x66, &.{sh}, 6, v, n); // psllw/pslld
                    try sseI(e, 0x66, &.{sh}, 4, v, n); // psraw/psrad
                }
                try sse(e, 0x66, false, &.{if (es == 0) 0x63 else 0x6b}, 0, 1); // packsswb / packssdw
            },
            2 => try sseI(e, null, &.{0xc6}, 0, 1, if (x.imm == 0) 0x88 else 0xdd), // shufps
            3 => try sse(e, 0x66, false, &.{if (x.imm == 0) 0x6c else 0x6d}, 0, 1), // punpckl/hqdq
        },
        .@"v.trn" => switch (es) {
            // Pairs: (a's lane, b's lane) from the even lanes (imm 0) or
            // the odd ones.
            0, 1 => {
                const sh: u8 = if (es == 0) 0x71 else 0x72;
                const n: u8 = if (es == 0) 8 else 16;
                if (x.imm == 0) {
                    try sseI(e, 0x66, &.{sh}, 6, 0, n); // a's even lanes, alone
                    try sseI(e, 0x66, &.{sh}, 2, 0, n);
                    try sseI(e, 0x66, &.{sh}, 6, 1, n); // b's, moved up
                } else {
                    try sseI(e, 0x66, &.{sh}, 2, 0, n); // a's odd lanes, moved down
                    try sseI(e, 0x66, &.{sh}, 2, 1, n); // b's, alone
                    try sseI(e, 0x66, &.{sh}, 6, 1, n);
                }
                try sse(e, 0x66, false, &.{0xeb}, 0, 1); // por
            },
            2 => {
                try sseI(e, null, &.{0xc6}, 0, 1, if (x.imm == 0) 0x88 else 0xdd); // shufps: a's two, b's two
                try sseI(e, 0x66, &.{0x70}, 0, 0, 0xd8); // pshufd: interleave them
            },
            3 => try sse(e, 0x66, false, &.{if (x.imm == 0) 0x6c else 0x6d}, 0, 1),
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
        3 => &.{ 0x38, 0x37 }, // pcmpgtq (SSE4.2)
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
    if (x.daz or x.ftz) return false;
    // Nearest, as the host's MXCSR has it, except for the ops that name
    // their own: conversions to integers toward zero, and rounds.
    switch (i.op) {
        .@"fp.tosint" => if (x.rounding != 0 and x.rounding != 3) return false,
        .@"fp.round" => if (x.rounding > 3 or !sse41) return false,
        else => if (x.rounding != 0) return false,
    }
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
        .@"fp.tosint" => if (vec or x.imm != 0) return false,
        .@"fp.fromsint", .@"fp.fromuint" => if (vec or x.imm != 0 or (i.ty != .i32 and i.ty != .i64)) return false,
        .@"fp.round" => {},
        .@"fp.fma" => if (!fma3) return false,
        else => if (arith == null) return false,
    }
    try ldX(e, 0, i.a, ta);
    if (i.b != ir.none) try ldX(e, 1, i.b, r.insts.items[i.b].ty);
    if (i.c != ir.none) try ldX(e, 2, i.c, r.insts.items[i.c].ty);
    var nan_check = true;
    var slow: [4]?usize = .{ null, null, null, null };
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
            // cvtss2si / cvtsd2si (nearest), or cvtt (toward zero).
            try sse(e, if (dbl) 0xf2 else 0xf3, i.ty == .i64, &.{if (x.rounding == 3) 0x2c else 0x2d}, RAX, 0);
            if (x.arm) {
                // x86's "integer indefinite" (the minimum) for a NaN or
                // out of range: Arm saturates, so the slow path decides.
                if (i.ty == .i64) {
                    try e.movImm(R10, @as(u64, 1) << 63);
                    try e.rr(true, &.{0x39}, R10, RAX); // cmp rax, r10
                } else {
                    try e.aluImm(false, 7, RAX, std.math.minInt(i32)); // cmp eax, min
                }
                slow[2] = try e.fwd(CC.e);
            }
            try maskTo(e, i.ty);
            try e.stVal(dst, RAX);
            nan_check = false;
        },
        .@"fp.fromuint" => {
            // A u32 is exact as a signed 64-bit integer; a u64 is when its
            // top bit is clear.
            try e.ldVal(RAX, i.a);
            if (ta == .i64) {
                try e.rr(true, &.{0x85}, RAX, RAX); // test rax, rax
                slow[2] = try e.fwd(CC.s);
            }
            try sse(e, 0x66, false, &.{0xef}, 0, 0); // pxor xmm0, xmm0
            try sse(e, if (i.ty == .i64) 0xf2 else 0xf3, true, &.{0x2a}, 0, RAX); // cvtsi2ss / sd from r64
            nan_check = false;
        },
        .@"fp.round" => {
            // roundss/sd/ps/pd with the rounding in imm8, and bit 3 to keep
            // inexact quiet unless the op raises it.
            const opc: u8 = if (vec) (if (dbl) 0x09 else 0x08) else (if (dbl) 0x0b else 0x0a);
            try sseI(e, 0x66, &.{ 0x3a, opc }, 0, 0, @as(u8, x.rounding) | (if (x.exact) @as(u8, 0) else 8));
        },
        .@"fp.fromsint" => {
            try e.ldVal(RAX, i.a);
            try sse(e, 0x66, false, &.{0xef}, 0, 0); // pxor xmm0, xmm0
            try sse(e, if (i.ty == .i64) 0xf2 else 0xf3, ta == .i64, &.{0x2a}, 0, RAX); // cvtsi2ss / sd
            nan_check = false;
        },
        .@"fp.fma" => {
            // vfmadd213ss/sd/ps/pd xmm0, xmm1, xmm2: xmm0 = xmm1 * xmm0 +
            // xmm2, rounded once. VEX: C4, RXB and map 0F38, W vvvv
            // (xmm1, inverted) L pp (66).
            try e.bs(&.{ 0xc4, 0xe2, @as(u8, if (dbl) 0x80 else 0) | 0x71, if (vec) 0xa8 else 0xa9, 0xc2 });
        },
        else => try sse(e, pfx, false, &.{arith.?}, 0, if (i.op == .@"fp.sqrt") 0 else 1),
    }
    // To the slow path on a NaN result, or an exception SSE and the
    // guest may see differently.
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
    if (watch and x.arm and i.op != .@"fp.cmp" and i.op != .@"fp.tosint") {
        // Arm detects tininess before rounding, SSE after: a result that
        // rounded up to the smallest normal may be Arm's underflow but not
        // the host's. The slow path decides.
        if (vec) {
            try sse(e, null, false, &.{0x28}, 2, 0); // movaps xmm2, xmm0
            if (dbl) {
                try sseI(e, 0x66, &.{0x73}, 6, 2, 1); // psllq xmm2, 1: no sign
                try e.movImm(RAX, 0x0020_0000_0000_0000);
                try sse(e, 0x66, true, &.{0x6e}, 1, RAX); // movq xmm1, rax
                try sse(e, 0x66, false, &.{0x6c}, 1, 1); // punpcklqdq xmm1, xmm1
                try sse(e, 0x66, false, &.{0x76}, 2, 1); // pcmpeqd xmm2, xmm1
                try sseI(e, 0x66, &.{0x70}, 1, 2, 0xb1); // pshufd xmm1, xmm2, swap dwords
                try sse(e, 0x66, false, &.{0xdb}, 2, 1); // pand xmm2, xmm1
            } else {
                try sseI(e, 0x66, &.{0x72}, 6, 2, 1); // pslld xmm2, 1
                try splat32(e, 1, 0x0100_0000);
                try sse(e, 0x66, false, &.{0x76}, 2, 1); // pcmpeqd xmm2, xmm1
            }
            try sse(e, 0x66, false, &.{0xd7}, RAX, 2); // pmovmskb eax, xmm2
            try e.bs(&.{ 0x85, 0xc0 }); // test eax, eax
            slow[3] = try e.fwd(CC.ne);
        } else {
            try sse(e, 0x66, dbl, &.{0x7e}, 0, RAX); // movd/movq rax, xmm0
            try e.rr(dbl, &.{0xd1}, 4, RAX); // shl rax, 1: no sign
            try e.movImm(R11, if (dbl) 0x0020_0000_0000_0000 else 0x0100_0000);
            try e.rr(dbl, &.{0x39}, R11, RAX); // cmp rax, r11
            slow[3] = try e.fwd(CC.e);
        }
    }
    if (watch) {
        // MXCSR's flags are sticky, and every one up to this op is already
        // in the guest's words, so ORing them in again changes nothing.
        try e.bs(&.{ 0x0f, 0xae, 0x5c, 0x24, mxcsr_tmp }); // stmxcsr [rsp+tmp]
        try e.rm(false, &.{0x8b}, RAX, RSP, mxcsr_tmp);
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
    // An op that reports nothing mustn't leave its flags for one that does.
    if (!watch and e.watch) try clearHostFlags(e);
    if (i.op != .@"fp.cmp" and i.op != .@"fp.tosint") try stX(e, dst, 0, i.ty);
    if (slow[0] != null or slow[1] != null or slow[2] != null or slow[3] != null) {
        const done = try e.fwd(null);
        for (slow) |s0| if (s0) |at| e.land(at);
        try extFallback(e, r, i, dst);
        // What the native try raised isn't the guest's (the slow path
        // reported the op's own); extFallback's call cleared it, when
        // anything watches.
        e.land(done);
    }
    return true;
}

/// Clears MXCSR's exception flags.
fn clearHostFlags(e: *E) !void {
    try e.bs(&.{ 0x0f, 0xae, 0x5c, 0x24, mxcsr_tmp }); // stmxcsr [rsp+tmp]
    try e.rm(false, &.{0x81}, 4, RSP, mxcsr_tmp); // and dword [rsp+tmp], ~0x3f
    try e.d32(@bitCast(@as(i32, ~@as(i32, 0x3f))));
    try e.bs(&.{ 0x0f, 0xae, 0x54, 0x24, mxcsr_tmp }); // ldmxcsr [rsp+tmp]
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
fn nzcvCc(aux: u64) ?u8 {
    return if (aux < 14) nzcv_cc[@intCast(aux)] else null;
}
fn eflagsCc(aux: u64) ?u8 {
    return @intCast(aux & 15);
}
/// inc and dec leave the host's CF alone.
fn eflagsCcNoCf(aux: u64) ?u8 {
    const cc: u8 = @intCast(aux & 15);
    return if (cc == CC.b or cc == CC.ae or cc == CC.be or cc == CC.a) null else cc;
}

/// LAHF works in 64-bit mode (every x86-64 since 2005 but the first).
const lahf_ok = builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .sahf);

/// rax = NZCV (bits 31..28) from the host's flags, through lahf and seto
/// rather than pushfq.
fn lahfNzcv(e: *E, invert_c: bool, logic: bool) !void {
    try e.bs(&.{ 0x0f, 0x90, 0xc1 }); // seto cl
    try e.b(0x9f); // lahf: ah = SF ZF 0 AF 0 PF 1 CF
    try e.bs(&.{ 0x0f, 0xb6, 0xc4 }); // movzx eax, ah
    if (logic) {
        // C = V = 0.
        try e.aluImm(false, 4, RAX, 0xc0);
        try e.shiftImm(false, 4, RAX, 24);
        return;
    }
    if (invert_c) try e.aluImm(false, 6, RAX, 1); // xor eax, 1
    try e.bs(&.{ 0x0f, 0xb6, 0xc9 }); // movzx ecx, cl
    try e.shiftImm(false, 4, RCX, 28); // V
    try e.mov(RDX, RAX);
    try e.aluImm(false, 4, RDX, 1);
    try e.shiftImm(false, 4, RDX, 29); // C
    try e.aluImm(false, 4, RAX, 0xc0);
    try e.shiftImm(false, 4, RAX, 24); // N, Z
    try e.rr(false, &.{0x09}, RDX, RAX);
    try e.rr(false, &.{0x09}, RCX, RAX);
}

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
    try e.flush();
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
    try e.rr(false, &.{0x31}, PENDING, PENDING); // r9 is the callee's
    try e.restoreRegs(live);
    if (e.watch) try clearHostFlags(e);
}

/// A load or store through the TLB, with the slow path inline after the
/// fast path's jump over it. rax is the address, rcx the value to store.
/// rdx = this va's entry in the TLB (less `table`), and the flags set by
/// comparing its tag with the page of the access's last byte: equal (ZF)
/// only if every byte of the `n` at rax is on a page the TLB holds, since
/// the entry is the first byte's (a page and the next never share one).
/// rax is kept; r10 is clobbered.
fn tlbLookup(e: *E, n: u32, table: i32) !void {
    comptime std.debug.assert(mem.page_shift == 12 and mem.entries == 256 and @sizeOf(mem.TlbEntry) == 16);
    try e.rr(false, &.{0x89}, RAX, RDX); // mov edx, eax
    try e.shiftImm(false, 5, RDX, 8); // shr edx, 8
    try e.aluImm(false, 4, RDX, 0xff0); // and edx, 0xff0: ((va >> 12) & 255) * 16
    try e.rm(true, &.{0x03}, RDX, CTX, ctx.off.tlb); // add rdx, [rbx+tlb]
    if (n > 1) {
        try e.rm(true, &.{0x8d}, R10, RAX, @intCast(n - 1)); // lea r10, [rax+n-1]
    } else try e.mov(R10, RAX);
    try e.shiftImm(true, 5, R10, mem.page_shift); // shr r10, 12
    try e.rm(true, &.{0x39}, R10, RDX, table); // cmp [rdx+table], r10
}

/// Which loads and stores save their page and TLB delta for a later one
/// to reuse (MemFlags.same_page), in which of the hint_slots pairs, and
/// which may reuse them: those whose hint names an access of the same
/// block, with no call between that could change the TLB, whose pair no
/// other access has taken since.
fn hintPlan(r: *const ir.Region, save: []i8, use: []i8) void {
    @memset(save, -1);
    @memset(use, -1);
    for (r.blocks.items) |blk| {
        // The accesses that some later one names.
        const end = blk.start + blk.len;
        var named = std.StaticBitSet(4096).initEmpty();
        if (blk.len > named.capacity()) continue;
        for (blk.start..end) |k| {
            const i = r.insts.items[k];
            if (i.op != .load and i.op != .store) continue;
            const f: ir.MemFlags = @bitCast(i.aux);
            if (f.same_page == 0 or f.same_page > k - blk.start) continue;
            named.set(k - f.same_page - blk.start);
        }
        var owner: [hint_slots]usize = @splat(std.math.maxInt(usize));
        var next: u8 = 0;
        var last_call: usize = blk.start;
        for (blk.start..end) |k| {
            const i = r.insts.items[k];
            switch (i.op) {
                .@"call.interp", .@"call.helper", .copy => last_call = k + 1,
                .load, .store => {
                    const f: ir.MemFlags = @bitCast(i.aux);
                    if (f.same_page != 0 and f.same_page <= k - blk.start) {
                        const j = k - f.same_page;
                        const sj = save[j];
                        if (sj >= 0 and owner[@intCast(sj)] == j and j >= last_call and r.insts.items[j].op == i.op) use[k] = sj;
                    }
                    if (named.isSet(k - blk.start)) {
                        save[k] = @intCast(next);
                        owner[next] = k;
                        next = (next + 1) % hint_slots;
                    }
                },
                else => {},
            }
        }
    }
}

fn memOp(e: *E, i: ir.Inst) !void {
    const f: ir.MemFlags = @bitCast(i.aux);
    const store = i.op == .store;
    const n = f.bytes();
    if (f.size > 3) return error.Unsupported;
    if (f.aligned and n > 1) {
        try e.bs(&.{ 0xa8, @intCast(n - 1) }); // test al, n-1
        const bad = try e.fwd(CC.ne);
        try e.goCold();
        e.land(bad);
        try e.stCtx(ctx.off.exit_addr, RAX);
        const acc: u64 = if (store or f.rmw) @intFromEnum(mem.Access.write) else @intFromEnum(mem.Access.read);
        try e.movImm(RAX, acc | (@as(u64, @intFromEnum(mem.FaultKind.alignment)) << 8));
        try e.stCtx(ctx.off.exit_info, RAX);
        try e.leave(.fault, i.aux2, i.retired);
        e.goHot();
    }
    const table: i32 = if (store) mem.tlb_write_off else mem.tlb_read_off;
    const save: ?i32 = if (e.hint_save[e.idx] >= 0) hint_base + 16 * @as(i32, e.hint_save[e.idx]) else null;
    var hinted: ?usize = null;
    if (e.hint_use[e.idx] >= 0) {
        // The page an earlier access in the block found: every byte on it
        // takes its delta, with no TLB load.
        const pair: i32 = hint_base + 16 * @as(i32, e.hint_use[e.idx]);
        try e.mov(R10, RAX);
        try e.shiftImm(true, 5, R10, mem.page_shift); // shr r10, 12
        try e.rm(true, &.{0x3b}, R10, RSP, pair); // cmp r10, [rsp+page]
        const other = try e.fwd(CC.ne);
        var cross: ?usize = null;
        if (n > 1) {
            try e.rm(true, &.{0x8d}, RDX, RAX, @intCast(n - 1)); // lea rdx, [rax+n-1]
            try e.shiftImm(true, 5, RDX, mem.page_shift);
            try e.rr(true, &.{0x39}, R10, RDX); // cmp rdx, r10
            cross = try e.fwd(CC.ne);
        }
        try e.load(RDX, RSP, pair + 8);
        if (save) |sv| {
            try e.store(RSP, sv, R10);
            try e.store(RSP, sv + 8, RDX);
        }
        try e.rr(true, &.{0x01}, RDX, RAX); // add rax, rdx
        hinted = try e.fwd(null);
        e.land(other);
        if (cross) |c| e.land(c);
    }
    try tlbLookup(e, n, table);
    const miss1 = try e.fwd(CC.ne);
    if (save) |sv| {
        try e.store(RSP, sv, R10); // the page (the tag, which matched)
        try e.load(RDX, RDX, table + 8);
        try e.store(RSP, sv + 8, RDX);
        try e.rr(true, &.{0x01}, RDX, RAX); // add rax, rdx
    } else try e.rm(true, &.{0x03}, RAX, RDX, table + 8); // add rax, [rdx+delta]
    if (hinted) |h| e.land(h);
    if (store) {
        switch (f.size) {
            0 => try e.bs(&.{ 0x88, 0x08 }), // mov [rax], cl
            1 => try e.bs(&.{ 0x66, 0x89, 0x08 }),
            2 => try e.bs(&.{ 0x89, 0x08 }),
            else => try e.bs(&.{ 0x48, 0x89, 0x08 }),
        }
    } else if (f.signed) {
        switch (f.size) {
            0 => try e.bs(&.{ 0x48, 0x0f, 0xbe, 0x00 }), // movsx rax, byte [rax]
            1 => try e.bs(&.{ 0x48, 0x0f, 0xbf, 0x00 }),
            2 => try e.bs(&.{ 0x48, 0x63, 0x00 }), // movsxd rax, dword [rax]
            else => try e.bs(&.{ 0x48, 0x8b, 0x00 }),
        }
    } else {
        switch (f.size) {
            0 => try e.bs(&.{ 0x0f, 0xb6, 0x00 }), // movzx eax, byte [rax]
            1 => try e.bs(&.{ 0x0f, 0xb7, 0x00 }),
            2 => try e.bs(&.{ 0x8b, 0x00 }),
            else => try e.bs(&.{ 0x48, 0x8b, 0x00 }),
        }
    }
    // Slow path, out of line.
    try e.goCold();
    e.land(miss1);
    if (save) |sv| {
        // No page for a later access to take: `invalid`, which no page
        // number (va >> 12) equals.
        try e.movImm(R10, mem.TlbEntry.invalid);
        try e.store(RSP, sv, R10);
    }
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
    try e.syncPend();
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
    if (!store) {
        try e.ldCtx(RAX, ctx.off.scratch);
        if (f.signed) {
            const t: Type = switch (f.size) {
                0 => .i8,
                1 => .i16,
                2 => .i32,
                else => .i64,
            };
            try signExtend(e, t);
        }
    }
    const join = try e.fwd(null);
    e.goHot();
    e.land(join);
    if (store and f.order == .seq_cst) try e.bs(&.{ 0x0f, 0xae, 0xf0 }); // mfence
    if (!store) try maskTo(e, i.ty);
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
    const pending_cases = try cases.generatePending(gpa);
    defer cases.free(gpa, pending_cases);
    const lazy_cases = try cases.generateLazyFlags(gpa);
    defer cases.free(gpa, lazy_cases);
    const all = try std.mem.concat(gpa, cases.Case, &.{ int_cases, ext_cases, pending_cases, lazy_cases });
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

    // Unlinked again, A's chain exit finds B in the jump cache.
    const zero: i32 = 0;
    region.write(site + 1, std.mem.asBytes(&zero));
    regs = .{ 5, 0x2000 };
    cx.retired = 0;
    try std.testing.expectEqual(ctx.Exit.svc, @as(ctx.Exit, @enumFromInt(region.entry(off + starts[0])(&cx))));
    try std.testing.expectEqual(@as(u64, 16), regs[0]);
    try std.testing.expectEqual(@as(u64, 2), cx.retired);
}

// ---------------------------------------------------------------- random regions

const check = @import("../check.zig");
const native_mod = @import("native.zig");

/// The region-by-region tests below run random programs until this many
/// regions have been checked natively, or give up after max_programs.
const min_regions = 400;
const max_programs = 5000;

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
    // Programs until min_regions regions have run, whatever the random
    // stream's mix of classes, within max_programs.
    var i: u64 = 0;
    while (regions < min_regions and i < max_programs) : (i += 1) {
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
    try std.testing.expect(regions >= min_regions);
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
    // Programs until min_regions regions have run, whatever the random
    // stream's mix of classes, within max_programs.
    var i: u64 = 0;
    while (regions < min_regions and i < max_programs) : (i += 1) {
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
    try std.testing.expect(regions >= min_regions);
}

// ---------------------------------------------------------------- random IR

const irfuzz = @import("fuzz.zig");

/// Runs `r` natively in `region` (reset first).
/// Region `r` through jit/opt, as the pipeline gives it, then emitted and
/// run (callers check it against ir_eval on `r` itself).
fn runNative(gpa: std.mem.Allocator, region: *codemem.Region, env: *cases.Env, r: *const ir.Region, c: cases.Case) !cases.Result {
    var ro = try irfuzz.optimized(gpa, r);
    defer ro.deinit(gpa);
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(gpa);
    const out = try emitRegion(gpa, &ro, &code);
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
        // opt making an invalid region counts as differing.
        const got = runNative(gpa, region, env, &r, c) catch |err| linux.exit(if (err == error.Invalid) 1 else 2);
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

/// Random regions per `zig build vcpu`, from fuzz_seed; H9_FUZZ_COUNT and
/// H9_FUZZ_SEED override them.
const fuzz_count = 3000;
const fuzz_seed = 0x5eed;

/// An integer from the environment (Linux, without libc), or `default`.
fn envInt(name: []const u8, default: u64) u64 {
    const linux = std.os.linux;
    const fd = linux.open("/proc/self/environ", .{}, 0);
    if (@as(isize, @bitCast(fd)) < 0) return default;
    defer _ = linux.close(@intCast(fd));
    var buf: [1 << 16]u8 = undefined;
    var n: usize = 0;
    while (n < buf.len) {
        const k = linux.read(@intCast(fd), buf[n..].ptr, buf.len - n);
        if (@as(isize, @bitCast(k)) <= 0) break;
        n += k;
    }
    var it = std.mem.splitScalar(u8, buf[0..n], 0);
    while (it.next()) |kv| {
        if (kv.len > name.len and std.mem.startsWith(u8, kv, name) and kv[name.len] == '=')
            return std.fmt.parseInt(u64, kv[name.len + 1 ..], 0) catch default;
    }
    return default;
}

test "random regions match ir_eval" {
    if (!supported or builtin.os.tag != .linux or !codemem.available()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const env = try gpa.create(cases.Env);
    defer gpa.destroy(env);
    var region = try codemem.Region.init(1 << 20);
    defer region.deinit();
    const count = envInt("H9_FUZZ_COUNT", fuzz_count);
    const first = envInt("H9_FUZZ_SEED", fuzz_seed);
    for (0..count) |n| {
        const seed = first +% n;
        var prng: std.Random.DefaultPrng = .init(seed);
        const rnd = prng.random();
        var r = try irfuzz.generate(gpa, rnd, .{ .lazy_records = true });
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


