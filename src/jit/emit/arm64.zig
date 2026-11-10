//! IR to arm64 machine code.
//!
//! Registers come from regalloc.zig: values in host registers (or frame
//! slots when they run out), and the region's most used guest register-file
//! fields ("chunks") pinned to host registers for the whole region, written
//! back to the Cpu only when dirty, and only where guest state must be
//! exact: at exits, before calls, and on a slow path's fault exit.
//!
//! Fixed registers: x19 the Ctx (ctx.arm64_ctx_reg), x20 the Cpu, x21 the
//! TLB's read table, x22 its write table. x9 to x13, x16, and x17 are
//! scratch. x18 is the platform's. Everything else is regalloc's: values
//! prefer x0 to x8, x14, and x15, chunks prefer x23 to x28. Slot k is at
//! [sp + 8k]; above the slots is a save area for calls out.
//!
//! Lowering:
//!
//! - Every pure op is lowered natively at every width (values are kept
//!   zero-extended in registers), except the EFLAGS ops that are only
//!   ever materialized (adc, sbb, shifts, and mul), which call
//!   `ir_eval.evalOpC`.
//! - Flags live in the host's NZCV where they can. A flags value whose
//!   every use can read NZCV is never materialized, and a condition that
//!   only feeds a branch or a select becomes a b.cond or csel. Both NZCV
//!   (arm64's own flags, one to one) and EFLAGS (the x86 conditions that map
//!   onto NZCV) work this way. Materialized EFLAGS come from NZCV through a
//!   16-entry table, with PF and AF computed beside it.
//! - Loads and stores check the TLB inline (6 instructions, 7 with a size
//!   over 1), with the slow path in an out-of-line stub that saves what's
//!   live (NZCV too) and, on a fault, writes back the dirty chunks and
//!   leaves.
//! - `poll` is 5 instructions inline, with its exit out of line.
//! - Chaining is cache.zig's contract: `exit.chain` writes back, tears
//!   the frame down to x29, and ends in one patchable `B` (`b .+4` while
//!   unlinked) that falls through to the exit, which names the site in
//!   exit_info. A linked site, and an `exit.indirect` that hits in the jump
//!   cache, land on the next region's `chain_entry`, which reuses the save
//!   area (every region saves the same registers, and x19 to x22 hold the
//!   same values in every region of a vCPU) and sets up its own frame.
//! - `ctx.retired` is exact at every exit: an op that can leave adds its
//!   `Inst.retired` on the way out only.
//! - Region.tso (x86 guests): loads are LDAR and stores STLR, a misaligned
//!   access takes the slow path, and the slow path is fenced.
//!
//! The function is a ctx.EntryFn.

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
const Ref = ir.Ref;
const EmitError = emitter.EmitError;

pub const emitter_def: emitter.Emitter = .{ .name = "arm64", .lazy_eflags = true, .emit = emit };

// ---------------------------------------------------------------- registers

const CTX: u5 = ctx.arm64_ctx_reg;
const CPU: u5 = 20;
const TLBR: u5 = 21;
const TLBW: u5 = 22;
/// Operand scratch (a, b, c), the result's scratch, and temporaries.
const S0: u5 = 9;
const S1: u5 = 10;
const S2: u5 = 11;
const SD: u5 = 12;
const T0: u5 = 13;
const IP0: u5 = 16;
const IP1: u5 = 17;
/// Retired instructions not yet added to ctx.retired and taken from the
/// budget (in a region with `retire`s).
const RC: u5 = 28;
const FP: u5 = 29;
const ZR: u5 = 31;
const SP: u5 = 31;

/// The allocatable registers a call clobbers, in save-area order.
const caller_saved = [_]u5{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 14, 15 };
const caller_saved_mask: u64 = blk: {
    var m: u64 = 0;
    for (caller_saved) |x| m |= 1 << x;
    break :blk m;
};
/// The save area: the caller-saved registers, then NZCV.
/// The save area, above the value slots: the caller-saved registers, NZCV,
/// a vector access's address, and evalExtC's 48 bytes of operands.
const nzcv_save = caller_saved.len;
const va_save = nzcv_save + 1;
const io_save = va_save + 1;
/// The host's FPCR, in a region that runs FP copies under the guest's.
const fpcr_save = io_save + 6;
/// Carried lazy flags: an evalOpC code (0 when nothing's carried) and its
/// operands.
const lz_save = fpcr_save + 1;
/// The pinned V registers across C calls, 16-byte aligned (an even slot).
const vsave = (lz_save + 4 + 1) & ~@as(usize, 1);
const max_vchunks = 16;
const save_slots: u32 = vsave + 2 * max_vchunks;

pub const host: regalloc.Host = .{
    .regs = &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 14, 15, 23, 24, 25, 26, 27 },
    .pin_regs = &.{ 27, 26, 25, 24, 23, 15, 14, 8, 7, 6 },
    .max_pinned = 10,
    .callee_saved = 0x3F << 23,
    .guest_nzcv = @offsetOf(@import("../../interp/a64/exec.zig").Cpu, "nzcv"),
    .guest_fpcr = @offsetOf(@import("../../interp/a64/exec.zig").Cpu, "fpcr"),
    .guest_fpsr = @offsetOf(@import("../../interp/a64/exec.zig").Cpu, "fpsr"),
};

/// The callee-saved pairs the prologue stores above x29/x30, at
/// [x29 + 16 + 16k]. Every region saves the same set, so a chained jump
/// can reuse the frame.
const saved_pairs = [_][2]u5{ .{ 19, 20 }, .{ 21, 22 }, .{ 23, 24 }, .{ 25, 26 }, .{ 27, 28 } };
const save_bytes = 16 + 16 * saved_pairs.len;

// ---------------------------------------------------------------- encodings

const Cond = u4;
const EQ: Cond = 0;
const NE: Cond = 1;

fn inv(c: Cond) Cond {
    return c ^ 1;
}

/// arm64 conditions for icmp's predicates.
const pred_cond = [_]Cond{ 0, 1, 3, 9, 8, 2, 11, 13, 12, 10 };

/// x86 conditions (Jcc's cc) as arm64 conditions on the NZCV that the
/// lowering of each EFLAGS producer leaves, or -1 where none fits.
const Kind = enum { sub, add, logic, incdec };
const x86_cc = std.enums.EnumArray(Kind, [16]i8).init(.{
    .sub = .{ 6, 7, 3, 2, 0, 1, 9, 8, 4, 5, -1, -1, 11, 10, 13, 12 },
    .add = .{ 6, 7, 2, 3, 0, 1, -1, -1, 4, 5, -1, -1, 11, 10, 13, 12 },
    .logic = .{ 6, 7, 2, 3, 0, 1, 0, 1, 4, 5, -1, -1, 11, 10, 13, 12 },
    .incdec = .{ 6, 7, -1, -1, 0, 1, -1, -1, 4, 5, -1, -1, 11, 10, 13, 12 },
});

fn eflagsKind(op: Op) ?Kind {
    return switch (op) {
        .@"eflags.sub" => .sub,
        .@"eflags.add" => .add,
        .@"eflags.logic" => .logic,
        .@"eflags.inc", .@"eflags.dec" => .incdec,
        else => null,
    };
}

/// EFLAGS' CF ZF SF OF from NZCV (index N<<3 | Z<<2 | C<<1 | V), with CF
/// as arm64's C, or (after a subtraction) its inverse.
fn eflagsTable(comptime borrow: bool) [16]u16 {
    var t: [16]u16 = undefined;
    for (&t, 0..) |*e, i| {
        var f: u16 = 0;
        if (i & 8 != 0) f |= @intCast(ir_eval.SF);
        if (i & 4 != 0) f |= @intCast(ir_eval.ZF);
        if (i & 1 != 0) f |= @intCast(ir_eval.OF);
        if ((i & 2 != 0) != borrow) f |= @intCast(ir_eval.CF);
        e.* = f;
    }
    return t;
}
const tables = [2][16]u16{ eflagsTable(false), eflagsTable(true) };

const ld_imm = [4]u32{ 0x39400000, 0x79400000, 0xB9400000, 0xF9400000 };
const st_imm = [4]u32{ 0x39000000, 0x79000000, 0xB9000000, 0xF9000000 };
const ld_reg = [4]u32{ 0x38606800, 0x78606800, 0xB8606800, 0xF8606800 };
const st_reg = [4]u32{ 0x38206800, 0x78206800, 0xB8206800, 0xF8206800 };

/// An unlinked chain site: b .+4.
const chain_unlinked: u32 = 0x14000001;

fn sizeLog2(t: Type) ?u2 {
    return switch (t) {
        .i8 => 0,
        .i16 => 1,
        .i32 => 2,
        .i64, .flags => 3,
        else => null,
    };
}

fn sfOf(bits: u32) u32 {
    return if (bits > 32) 0x8000_0000 else 0;
}

// ---------------------------------------------------------------- emitter state

const Fixup = struct {
    pos: usize,
    kind: enum { b26, b19, adr },
    label: u32,
};

const Stub = union(enum) {
    slow: struct {
        label: u32,
        back: u32,
        store: bool,
        size: u2,
        va: u5,
        val: u5,
        dst: u5,
        save: u64,
        dirty: regalloc.ChunkSet,
        pc: u64,
        retired: u32,
        rmw: bool,
        tso: bool,
        /// Just the fault exit (cas, which made its call inline).
        fault_only: bool = false,
        pend: ?Pend = null,
    },
    poll: struct { label: u32, dirty: regalloc.ChunkSet, pc: u64, retired: u32, pend: ?Pend = null },
    misaligned: struct { label: u32, va: u5, acc: mem.Access, dirty: regalloc.ChunkSet, pc: u64, retired: u32, pend: ?Pend = null },
    /// v.load and v.store's slow path: two 8-byte halves, the low first.
    vslow: struct {
        label: u32,
        back: u32,
        store: bool,
        va: u5,
        slot: u32,
        save: u64,
        dirty: regalloc.ChunkSet,
        pc: u64,
        retired: u32,
        tso: bool,
        pend: ?Pend = null,
    },
};

/// A pending.flags not yet written: value v, packed by group, for Cpu
/// offset off.
const Pend = struct {
    v: Ref,
    off: u64,
    group: u64,
    /// Lazy: written on the block's way out only where a successor needs
    /// them (Lazy.edge_pend), and the value may be virtual, recomputed then.
    edge: bool = false,
    /// Carried into this block in the frame's lz slots (v is none): written,
    /// from them, only by a fault or poll stub before they're replaced.
    carried: bool = false,
};

/// Lazy pending flags, across a region whose pending.flags all name one
/// slot and kind: where a block's last pending.flags (with nothing after it
/// that could see the slot) is written, edge by edge.
const Lazy = struct {
    on: bool = false,
    /// pending.flags written on their block's outgoing edges only.
    edge_pend: []bool = &.{},
    /// Per block: entered with flags pending, would anything see them
    /// before they're replaced (a poll counting)?
    need_full: []bool = &.{},
    /// Per block: the block starts with a poll.
    entry_poll: []bool = &.{},
    /// Per block: need_full, but past an entry poll (which an edge carrying
    /// flags does itself).
    need_after_poll: []bool = &.{},
    /// Per block: a label just past its entry poll.
    after_poll: []u32 = &.{},
    /// Per block: flags pending at entry are replaced before anything but
    /// a fault or a poll could see them, so an edge may carry them in the
    /// lz slots rather than write them.
    carry_ok: []bool = &.{},
    /// Per block: some edge carries flags in.
    carried_in: []bool = &.{},
    off: u64 = 0,
    group: u64 = 0,

    fn deinit(l: *Lazy, gpa: std.mem.Allocator) void {
        gpa.free(l.edge_pend);
        gpa.free(l.need_full);
        gpa.free(l.entry_poll);
        gpa.free(l.need_after_poll);
        gpa.free(l.after_poll);
        gpa.free(l.carry_ok);
        gpa.free(l.carried_in);
    }
};

const Event = enum { none, need, replace };

/// What `i` does to flags pending in the 4 bytes at `off`.
fn pendEvent(r: *const ir.Region, i: ir.Inst, off: u64) Event {
    return switch (i.op) {
        .@"pending.flags" => .replace,
        .setreg => blk: {
            const sz = sizeLog2(r.insts.items[i.a].ty) orelse break :blk .need;
            break :blk if (i.aux < off + 4 and off < i.aux + (@as(u64, 1) << sz)) .replace else .none;
        },
        .getreg => blk: {
            const n: u64 = @max(i.ty.bits() / 8, 1);
            break :blk if (i.aux < off + 4 and off < i.aux + n) .need else .none;
        },
        .load, .store, .cas, .@"v.load", .@"v.store", .poll, .@"call.interp", .copy => .need,
        .@"call.helper" => if (regalloc.touchesRegs(i)) .need else .none,
        .br, .brcond => .none,
        else => if (i.op.isTerminator()) .need else .none,
    };
}

/// Whether flags pending at instruction `from` of block `b` could be seen
/// before they're replaced.
fn needFrom(r: *const ir.Region, b: usize, from: usize, off: u64, need_full: []const bool) bool {
    const blk = r.blocks.items[b];
    for (blk.start + from..blk.start + blk.len) |idx| {
        const i = r.insts.items[idx];
        switch (pendEvent(r, i, off)) {
            .need => return true,
            .replace => return false,
            .none => {},
        }
        switch (i.op) {
            .br => return need_full[i.aux],
            .brcond => return need_full[i.aux] or need_full[i.aux2],
            else => {},
        }
    }
    return true;
}

fn lazyFlags(gpa: std.mem.Allocator, r: *const ir.Region) !Lazy {
    const nb = r.blocks.items.len;
    var l: Lazy = .{};
    errdefer l.deinit(gpa);
    l.edge_pend = try gpa.alloc(bool, r.insts.items.len);
    @memset(l.edge_pend, false);
    l.need_full = try gpa.alloc(bool, nb);
    @memset(l.need_full, false);
    l.entry_poll = try gpa.alloc(bool, nb);
    l.need_after_poll = try gpa.alloc(bool, nb);
    l.after_poll = try gpa.alloc(u32, nb);
    @memset(l.after_poll, 0);
    l.carry_ok = try gpa.alloc(bool, nb);
    @memset(l.carry_ok, false);
    l.carried_in = try gpa.alloc(bool, nb);
    @memset(l.carried_in, false);
    var off: ?u64 = null;
    var group: u64 = 0;
    for (r.insts.items) |i| {
        if (i.op != .@"pending.flags") continue;
        if (off) |o| {
            if (o != i.aux or group != i.aux2) return l;
        } else {
            off = i.aux;
            group = i.aux2;
        }
    }
    const o = off orelse return l;
    l.on = true;
    l.off = o;
    l.group = group;
    for (r.blocks.items, 0..) |blk, b| l.entry_poll[b] = r.insts.items[blk.start].op == .poll;
    var changed = true;
    while (changed) {
        changed = false;
        for (0..nb) |b| {
            if (l.need_full[b]) continue;
            if (needFrom(r, b, 0, o, l.need_full)) {
                l.need_full[b] = true;
                changed = true;
            }
        }
    }
    for (0..nb) |b| l.need_after_poll[b] = if (l.entry_poll[b]) needFrom(r, b, 1, o, l.need_full) else l.need_full[b];
    for (r.blocks.items, 0..) |blk, b| {
        for (blk.start..blk.start + blk.len) |idx| {
            const i = r.insts.items[idx];
            switch (i.op) {
                .load, .store, .cas, .@"v.load", .@"v.store", .poll => continue,
                else => {},
            }
            switch (pendEvent(r, i, o)) {
                .replace => l.carry_ok[b] = true,
                .need => {},
                .none => if (!i.op.isTerminator()) continue,
            }
            break;
        }
    }
    for (r.blocks.items) |blk| {
        const last = blk.start + blk.len - 1;
        const t = r.insts.items[last].op;
        if (t != .br and t != .brcond) continue;
        var k = last;
        while (k > blk.start) {
            k -= 1;
            const i = r.insts.items[k];
            if (i.op == .@"pending.flags") {
                l.edge_pend[k] = true;
                const term = r.insts.items[last];
                const succ = [2]u64{ term.aux, if (t == .brcond) term.aux2 else term.aux };
                for (succ) |sb| if (l.need_full[sb] and l.carry_ok[sb] and group != 2) {
                    l.carried_in[sb] = true;
                };
                break;
            }
            if (pendEvent(r, i, o) != .none) break;
        }
    }
    return l;
}

/// Per instruction, what the flags pre-pass decided.
const Decide = struct {
    /// No code: a dead pure value.
    skip: bool = false,
    /// No location: a flags value kept in NZCV, or a condition fused into
    /// its uses.
    virtual: bool = false,
    /// nzcv.cond, adc, sbc: write the flags operand to NZCV first.
    msr: bool = false,
    /// brcond and select: branch or select on this arm64 condition of NZCV
    /// rather than on an i1 register. eflags.cond: compute from NZCV.
    host_cc: ?Cond = null,
    /// Operand b is a constant the instruction takes as an immediate.
    imm_b: bool = false,
};

const E = struct {
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    base: usize,
    r: *const ir.Region,
    p: regalloc.Plan,
    d: []Decide,
    fixups: std.ArrayList(Fixup) = .empty,
    labels: std.ArrayList(?usize) = .empty,
    stubs: std.ArrayList(Stub) = .empty,
    code: emitter.Code = .{},
    table_label: [2]?u32 = .{ null, null },
    epilogue: u32 = 0,
    /// The epilogue past its FP part, for paths that did it already (and
    /// tore the frame down).
    epilogue_plain: u32 = 0,
    /// The region runs FP copies: the guest's FPCR is the host's while it
    /// runs, and host FPSR collects their exceptions until an exit, a call,
    /// or a read of the guest's FPSR moves them into it.
    fp: bool = false,
    dirty: regalloc.ChunkSet = 0,
    block: ir.BlockId = 0,
    pend: ?Pend = null,
    lazy: Lazy = .{},
    /// Guest V registers pinned to host v16 and up for the region: those
    /// only copies touch. Written back at exits and calls (`vwritten`).
    vchunks: [max_vchunks]u32 = undefined,
    nv: u8 = 0,
    vwritten: u16 = 0,
    /// The region's retires count in RC, flushed at exits and calls.
    lazy_retire: bool = false,

    fn deinit(e: *E) void {
        e.fixups.deinit(e.gpa);
        e.labels.deinit(e.gpa);
        e.stubs.deinit(e.gpa);
    }

    fn put(e: *E, w: u32) !void {
        try e.out.appendSlice(e.gpa, std.mem.asBytes(&std.mem.nativeToLittle(u32, w)));
    }
    fn pos(e: *E) usize {
        return e.out.items.len - e.base;
    }
    fn word(e: *E, at: usize) u32 {
        return std.mem.readInt(u32, e.out.items[e.base + at ..][0..4], .little);
    }
    fn patch(e: *E, at: usize, w: u32) void {
        std.mem.writeInt(u32, e.out.items[e.base + at ..][0..4], w, .little);
    }

    fn label(e: *E) !u32 {
        try e.labels.append(e.gpa, null);
        return @intCast(e.labels.items.len - 1);
    }
    fn bind(e: *E, l: u32) void {
        e.labels.items[l] = e.pos();
    }
    fn jump(e: *E, kind: @FieldType(Fixup, "kind"), w: u32, l: u32) !void {
        try e.fixups.append(e.gpa, .{ .pos = e.pos(), .kind = kind, .label = l });
        try e.put(w);
    }
    fn b(e: *E, l: u32) !void {
        try e.jump(.b26, 0x14000000, l);
    }
    fn bcond(e: *E, c: Cond, l: u32) !void {
        try e.jump(.b19, 0x54000000 | @as(u32, c), l);
    }
    fn cbnz(e: *E, sf64: bool, rt: u5, l: u32) !void {
        try e.jump(.b19, (if (sf64) @as(u32, 0xB5000000) else 0x35000000) | rt, l);
    }
    fn cbz(e: *E, sf64: bool, rt: u5, l: u32) !void {
        try e.jump(.b19, (if (sf64) @as(u32, 0xB4000000) else 0x34000000) | rt, l);
    }

    // ---- moves and constants

    fn mov(e: *E, rd: u5, rm: u5) !void {
        if (rd != rm) try e.put(0xAA0003E0 | @as(u32, rm) << 16 | @as(u32, rd));
    }
    fn movImm(e: *E, rd: u5, imm: u64) !void {
        if (imm >> 32 == 0) {
            const lo: u16 = @truncate(imm);
            const hi: u16 = @truncate(imm >> 16);
            if (hi == 0) return e.put(0x52800000 | @as(u32, lo) << 5 | @as(u32, rd));
            if (lo == 0) return e.put(0x52A00000 | @as(u32, hi) << 5 | @as(u32, rd));
            if (hi == 0xffff) return e.put(0x12800000 | @as(u32, ~lo) << 5 | @as(u32, rd));
            if (lo == 0xffff) return e.put(0x12A00000 | @as(u32, ~hi) << 5 | @as(u32, rd));
            try e.put(0x52800000 | @as(u32, lo) << 5 | @as(u32, rd));
            return e.put(0x72A00000 | @as(u32, hi) << 5 | @as(u32, rd));
        }
        var ones: u32 = 0;
        var zeros: u32 = 0;
        for (0..4) |k| {
            const c: u16 = @truncate(imm >> @intCast(k * 16));
            if (c == 0xffff) ones += 1;
            if (c == 0) zeros += 1;
        }
        const neg = ones > zeros;
        const skip: u16 = if (neg) 0xffff else 0;
        var first = true;
        for (0..4) |k| {
            const c: u16 = @truncate(imm >> @intCast(k * 16));
            if (c == skip) continue;
            const hw: u32 = @intCast(k);
            if (first) {
                if (neg)
                    try e.put(0x92800000 | hw << 21 | @as(u32, ~c) << 5 | @as(u32, rd))
                else
                    try e.put(0xD2800000 | hw << 21 | @as(u32, c) << 5 | @as(u32, rd));
                first = false;
            } else try e.put(0xF2800000 | hw << 21 | @as(u32, c) << 5 | @as(u32, rd));
        }
        if (first) try e.put((if (neg) @as(u32, 0x92800000) else 0xD2800000) | @as(u32, rd));
    }

    // ---- memory

    fn ldrSlot(e: *E, rt: u5, slot: u32) !void {
        try e.put(0xF9400000 | slot << 10 | @as(u32, SP) << 5 | rt);
    }
    fn strSlot(e: *E, rt: u5, slot: u32) !void {
        try e.put(0xF9000000 | slot << 10 | @as(u32, SP) << 5 | rt);
    }
    fn ldrCtx(e: *E, rt: u5, off: u32) !void {
        try e.put(0xF9400000 | (off / 8) << 10 | @as(u32, CTX) << 5 | rt);
    }
    /// LDR Xt, [Xn, #off].
    fn ldrCtx2(e: *E, rt: u5, rn: u5, off: u32) !void {
        try e.put(0xF9400000 | (off / 8) << 10 | @as(u32, rn) << 5 | rt);
    }
    fn strCtx(e: *E, rt: u5, off: u32) !void {
        try e.put(0xF9000000 | (off / 8) << 10 | @as(u32, CTX) << 5 | rt);
    }
    /// A sized load or store at [rn + off]; IP1 is scratch for big offsets.
    fn ldst(e: *E, store: bool, size: u2, rt: u5, rn: u5, off: u64) !void {
        if (off % (@as(u64, 1) << size) == 0 and off >> size < 4096) {
            const imm: u32 = @intCast(off >> size);
            try e.put((if (store) st_imm[size] else ld_imm[size]) | imm << 10 | @as(u32, rn) << 5 | rt);
        } else {
            try e.movImm(IP1, off);
            try e.put((if (store) st_reg[size] else ld_reg[size]) | @as(u32, IP1) << 16 | @as(u32, rn) << 5 | rt);
        }
    }

    // ---- bitfields and logical immediates

    fn ubfm(e: *E, sf64: bool, rd: u5, rn: u5, immr: u32, imms: u32) !void {
        try e.put((if (sf64) @as(u32, 0xD3400000) else 0x53000000) | immr << 16 | imms << 10 | @as(u32, rn) << 5 | @as(u32, rd));
    }
    fn sbfm(e: *E, sf64: bool, rd: u5, rn: u5, immr: u32, imms: u32) !void {
        try e.put((if (sf64) @as(u32, 0x93400000) else 0x13000000) | immr << 16 | imms << 10 | @as(u32, rn) << 5 | @as(u32, rd));
    }
    fn bfm(e: *E, sf64: bool, rd: u5, rn: u5, immr: u32, imms: u32) !void {
        try e.put((if (sf64) @as(u32, 0xB3400000) else 0x33000000) | immr << 16 | imms << 10 | @as(u32, rn) << 5 | @as(u32, rd));
    }
    fn ubfx(e: *E, rd: u5, rn: u5, lsb: u32, width: u32) !void {
        try e.ubfm(lsb + width > 32, rd, rn, lsb, lsb + width - 1);
    }
    fn sbfx64(e: *E, rd: u5, rn: u5, width: u32) !void {
        try e.sbfm(true, rd, rn, 0, width - 1);
    }
    /// Inserts rn's low `width` bits at `lsb` of rd, 64-bit.
    fn bfi(e: *E, rd: u5, rn: u5, lsb: u32, width: u32) !void {
        try e.bfm(true, rd, rn, (64 - lsb) % 64, width - 1);
    }
    fn lslImm(e: *E, sf64: bool, rd: u5, rn: u5, s: u32) !void {
        const n: u32 = if (sf64) 64 else 32;
        try e.ubfm(sf64, rd, rn, (n - s) % n, n - 1 - s);
    }
    fn lsrImm(e: *E, sf64: bool, rd: u5, rn: u5, s: u32) !void {
        try e.ubfm(sf64, rd, rn, s, if (sf64) 63 else 31);
    }
    /// AND, ORR, or EOR (opc 0, 1, 2) with a run of `len` ones at `lsb`.
    fn logImm(e: *E, opc: u32, sf64: bool, rd: u5, rn: u5, lsb: u32, len: u32) !void {
        const size: u32 = if (sf64) 64 else 32;
        const n: u32 = if (sf64) 1 else 0;
        const immr = (size - lsb) % size;
        try e.put((if (sf64) @as(u32, 0x92000000) else 0x12000000) | opc << 29 | n << 22 | immr << 16 | (len - 1) << 10 | @as(u32, rn) << 5 | @as(u32, rd));
    }
    /// rd = rn zero-extended from `bits` (rd = rn for 64).
    fn zx(e: *E, rd: u5, rn: u5, bits: u32) !void {
        switch (bits) {
            64 => try e.mov(rd, rn),
            32 => try e.put(0x2A0003E0 | @as(u32, rn) << 16 | @as(u32, rd)),
            else => try e.ubfm(false, rd, rn, 0, bits - 1),
        }
    }
    /// A data-processing (shifted register) op: base | sf | rm | rn | rd.
    fn dp(e: *E, base: u32, sf64: bool, rd: u5, rn: u5, rm: u5) !void {
        try e.put(base | (if (sf64) @as(u32, 0x8000_0000) else 0) | @as(u32, rm) << 16 | @as(u32, rn) << 5 | @as(u32, rd));
    }
    fn dpShift(e: *E, base: u32, sf64: bool, rd: u5, rn: u5, rm: u5, shift: u2, amount: u32) !void {
        try e.put(base | (if (sf64) @as(u32, 0x8000_0000) else 0) | @as(u32, shift) << 22 | @as(u32, rm) << 16 | amount << 10 | @as(u32, rn) << 5 | @as(u32, rd));
    }
    fn cset(e: *E, rd: u5, c: Cond) !void {
        try e.put(0x1A9F07E0 | @as(u32, inv(c)) << 12 | @as(u32, rd));
    }
    fn call(e: *E, rn: u5) !void {
        try e.put(0xD63F0000 | @as(u32, rn) << 5);
    }
    /// A call to C code that leaves the Cpu alone: the pinned V registers
    /// (caller-saved) kept in the frame across it.
    fn callOut(e: *E, rn: u5) !void {
        for (0..e.nv) |k| try e.vslot(true, @intCast(16 + k), k);
        try e.call(rn);
        for (0..e.nv) |k| try e.vslot(false, @intCast(16 + k), k);
    }
    /// A call that reads and writes the Cpu: the written V registers written
    /// back before, and every pinned one reloaded after.
    fn callInterp(e: *E, rn: u5) !void {
        try e.vWriteback();
        try e.call(rn);
        try e.vLoad();
    }
    fn vslot(e: *E, store: bool, qt: u5, k: usize) !void {
        const off: u32 = @intCast((e.saveArea(vsave) + 2 * k) * 8);
        try e.put((if (store) @as(u32, 0x3D800000) else 0x3DC00000) | (off / 16) << 10 | @as(u32, SP) << 5 | qt);
    }
    fn vLoad(e: *E) !void {
        for (e.vchunks[0..e.nv], 0..) |off, k| try vldst(e, false, @intCast(16 + k), off);
    }
    fn vWriteback(e: *E) !void {
        for (e.vchunks[0..e.nv], 0..) |off, k| if (e.vwritten & (@as(u16, 1) << @intCast(k)) != 0) try vldst(e, true, @intCast(16 + k), off);
    }
    fn vchunkOf(e: *E, off: u64) ?u5 {
        for (e.vchunks[0..e.nv], 0..) |o, k| if (o == off) return @intCast(16 + k);
        return null;
    }

    // ---- values

    /// The register holding v, loading it into `scratch` if it's in a slot.
    fn src(e: *E, v: Ref, scratch: u5) !u5 {
        return switch (e.p.locs[v]) {
            .reg => |x| @intCast(x),
            .slot => |s| {
                try e.ldrSlot(scratch, s);
                return scratch;
            },
            .none => unreachable,
        };
    }
    /// The register to compute value `idx` in.
    fn dst(e: *E, idx: usize) u5 {
        return switch (e.p.locs[idx]) {
            .reg => |x| @intCast(x),
            else => SD,
        };
    }
    fn finish(e: *E, idx: usize, reg: u5) !void {
        switch (e.p.locs[idx]) {
            .reg => |x| try e.mov(@intCast(x), reg),
            .slot => |s| try e.strSlot(reg, s),
            .none => {},
        }
    }

    // ---- chunks, calls, and exits

    fn chunkLoad(e: *E, k: usize) !void {
        const c = e.p.chunks[k];
        try e.ldst(false, @intCast(std.math.log2_int(u8, c.bytes)), @intCast(c.reg), CPU, c.off);
    }
    fn loadChunks(e: *E) !void {
        for (0..e.p.chunks.len) |k| try e.chunkLoad(k);
    }
    fn writeback(e: *E, set: regalloc.ChunkSet) !void {
        for (e.p.chunks, 0..) |c, k| {
            if (set & (@as(regalloc.ChunkSet, 1) << @intCast(k)) == 0) continue;
            try e.ldst(true, @intCast(std.math.log2_int(u8, c.bytes)), @intCast(c.reg), CPU, c.off);
        }
    }
    fn saveArea(e: *E, j: usize) u32 {
        return e.p.slots + @as(u32, @intCast(j));
    }
    fn saveRegs(e: *E, mask: u64) !void {
        for (caller_saved, 0..) |x, j| if (mask & (@as(u64, 1) << x) != 0) try e.strSlot(x, e.saveArea(j));
    }
    fn restoreRegs(e: *E, mask: u64) !void {
        for (caller_saved, 0..) |x, j| if (mask & (@as(u64, 1) << x) != 0) try e.ldrSlot(x, e.saveArea(j));
    }
    /// What a call at `idx` must keep: live values and, unless the call
    /// reloads them, the pinned chunks, in caller-saved registers.
    fn saveMask(e: *E, idx: usize, chunks: bool) u64 {
        var m = e.p.liveAcross(e.r, e.block, idx);
        if (chunks) m |= e.p.pinnedRegs();
        return m & caller_saved_mask;
    }
    /// On a path out: ctx.retired += n and ctx.budget -= n. Uses x16, x17.
    fn retireOn(e: *E, n: u32) !void {
        if (e.lazy_retire) {
            // RC and n, together, and RC is 0 again.
            for ([2]u32{ ctx.off.retired, ctx.off.budget }, [2]u32{ 0x0B000000, 0x4B000000 }, [2]u32{ 0x91000000, 0xD1000000 }) |off, reg_op, imm_op| {
                try e.ldrCtx(IP0, off);
                try e.dp(reg_op, true, IP0, IP0, RC);
                if (n != 0) {
                    if (n < 4096) try e.put(imm_op | n << 10 | @as(u32, IP0) << 5 | IP0) else {
                        try e.movImm(IP1, n);
                        try e.dp(reg_op, true, IP0, IP0, IP1);
                    }
                }
                try e.strCtx(IP0, off);
            }
            return e.mov(RC, ZR);
        }
        if (n == 0) return;
        for ([2]u32{ ctx.off.retired, ctx.off.budget }, [2]u32{ 0x91000000, 0xD1000000 }) |off, op| {
            try e.ldrCtx(IP0, off);
            if (n < 4096) {
                try e.put(op | n << 10 | @as(u32, IP0) << 5 | IP0);
            } else {
                try e.movImm(IP1, n);
                try e.dp(if (op == 0x91000000) 0x0B000000 else 0x4B000000, true, IP0, IP0, IP1);
            }
            try e.strCtx(IP0, off);
        }
    }
    /// Sets exit_pc and leaves with `code`, after writing back `dirty` and
    /// counting `retired`.
    fn leave(e: *E, code: ctx.Exit, pc: u64, dirty: regalloc.ChunkSet, retired: u32) !void {
        return e.leaveTo(code, pc, dirty, retired, e.epilogue);
    }
    fn leaveTo(e: *E, code: ctx.Exit, pc: u64, dirty: regalloc.ChunkSet, retired: u32, to: u32) !void {
        if (to != e.epilogue_plain) try e.vWriteback();
        try e.writeback(dirty);
        try e.retireOn(retired);
        try e.movImm(IP0, pc);
        try e.strCtx(IP0, ctx.off.exit_pc);
        try e.put(0x52800000 | @as(u32, @intFromEnum(code)) << 5);
        try e.b(to);
    }
};

// ---------------------------------------------------------------- the flags pre-pass

fn fallsBack(op: Op) bool {
    return switch (op) {
        .@"eflags.adc", .@"eflags.sbb", .@"eflags.shl", .@"eflags.shr", .@"eflags.mul" => true,
        else => false,
    };
}

fn producesFlags(op: Op) bool {
    return switch (op) {
        .icmp, .@"nzcv.add", .@"nzcv.sub", .@"nzcv.logic", .@"nzcv.adc", .@"nzcv.sbc" => true,
        else => eflagsKind(op) != null,
    };
}

/// What NZCV holds, as the pre-pass and the lowering track it: the flags
/// of value `ref`, in one of three senses.
const Live = struct {
    ref: Ref = ir.none,
    mode: enum {
        /// NZCV is the value's bits 31..28: an nzcv producer, or MSR.
        nzcv,
        /// NZCV is the arm64 flags of the EFLAGS producer's operation.
        eflags,
        /// NZCV is an icmp's compare.
        icmp,
    } = .nzcv,

    fn is(l: Live, ref: Ref, mode: @FieldType(Live, "mode")) bool {
        return ref != ir.none and l.ref == ref and l.mode == mode;
    }
};

/// The arm64 condition NZCV gives for the i1 `v` while NZCV holds `live`,
/// or null.
fn hostCond(r: *const ir.Region, v: Ref, live: Live) ?Cond {
    const i = r.insts.items[v];
    switch (i.op) {
        .icmp => if (live.is(v, .icmp)) return pred_cond[@intCast(i.aux)],
        .@"nzcv.cond" => if (i.aux < 14 and live.is(i.a, .nzcv)) return @intCast(i.aux),
        .@"eflags.cond" => if (live.is(i.a, .eflags)) {
            const k = eflagsKind(r.insts.items[i.a].op) orelse return null;
            const c = x86_cc.get(k)[@intCast(i.aux)];
            if (c >= 0) return @intCast(c);
        },
        else => {},
    }
    return null;
}

/// Whether `i` can take operand b, the constant `v`, as an immediate.
fn immB(r: *const ir.Region, i: ir.Inst, v: u64) bool {
    const ta = r.insts.items[i.a].ty;
    const W = ta.bits();
    return switch (i.op) {
        .add, .sub => (W == 32 or W == 64) and v < 4096,
        .shl, .lshr, .ashr => W == 32 or W == 64,
        .icmp => (W == 32 or W == 64) and v < 4096,
        .@"nzcv.add", .@"nzcv.sub" => v < 4096,
        else => false,
    };
}

/// Decides, for each instruction, where flags and conditions live. The
/// lowering follows these decisions exactly, so it leaves NZCV as this
/// pass models it.
fn decide(gpa: std.mem.Allocator, r: *const ir.Region, edge_pend: []const bool) ![]Decide {
    const n = r.insts.items.len;
    const d = try gpa.alloc(Decide, n);
    errdefer gpa.free(d);
    @memset(d, .{});
    const uses = try gpa.alloc(u32, n);
    defer gpa.free(uses);
    @memset(uses, 0);
    for (r.insts.items) |i| for (i.operands()) |o| {
        if (o != ir.none) uses[o] += 1;
    };
    const need = try gpa.alloc(bool, n);
    defer gpa.free(need);
    @memset(need, false);

    for (r.blocks.items) |blk| {
        var live: Live = .{};
        for (blk.start..blk.start + blk.len) |idx| {
            const i = r.insts.items[idx];
            if (i.op.isPure() and uses[idx] == 0) {
                d[idx].skip = true;
                d[idx].virtual = true;
                continue;
            }
            var clobber = false;
            switch (i.op) {
                .brcond, .select => {
                    if (hostCond(r, i.a, live)) |c| {
                        d[idx].host_cc = c;
                    } else {
                        need[i.a] = true;
                        clobber = i.op == .select;
                    }
                    if (i.op == .select) {
                        need[i.b] = true;
                        need[i.c] = true;
                    }
                },
                .@"nzcv.cond" => if (i.aux < 14) {
                    if (!live.is(i.a, .nzcv)) {
                        need[i.a] = true;
                        d[idx].msr = true;
                        live = .{ .ref = i.a, .mode = .nzcv };
                    }
                } else {
                    need[i.a] = true;
                },
                .@"nzcv.adc", .@"nzcv.sbc" => {
                    need[i.a] = true;
                    need[i.b] = true;
                    if (!live.is(i.c, .nzcv)) {
                        need[i.c] = true;
                        d[idx].msr = true;
                    }
                },
                .@"eflags.cond" => {
                    if (hostCond(r, @intCast(idx), live)) |c| {
                        d[idx].host_cc = c;
                    } else need[i.a] = true;
                },
                // Lazy, edge by edge: a producer is recomputed where needed.
                .@"pending.flags" => if (i.aux2 != 2 and !(edge_pend[idx] and rematerializable(r.insts.items[i.a].op))) {
                    need[i.a] = true;
                },
                else => {
                    for (i.operands()) |o| if (o != ir.none) {
                        need[o] = true;
                    };
                    clobber = switch (i.op) {
                        .poll, .@"call.interp", .@"call.helper", .cas, .copy => true,
                        else => fallsBack(i.op) or i.op.isExt(),
                    };
                },
            }
            if (producesFlags(i.op)) {
                live = .{ .ref = @intCast(idx), .mode = if (i.op == .icmp) .icmp else if (eflagsKind(i.op) != null) .eflags else .nzcv };
            } else if (clobber) live = .{};
        }
    }
    // Flags whose only uses are lazy records (pending.flags aux2 2) aren't
    // computed at all: the record takes the operands.
    {
        const rec = try gpa.alloc(u32, n);
        defer gpa.free(rec);
        @memset(rec, 0);
        for (r.insts.items) |i| if (i.op == .@"pending.flags" and i.aux2 == 2) {
            rec[i.a] += 1;
        };
        for (r.insts.items, 0..) |i, idx| if (rec[idx] != 0 and rec[idx] == uses[idx] and ir.lazyKind(i.op) != null) {
            d[idx].skip = true;
            d[idx].virtual = true;
        };
    }
    // Constants an add, sub, compare, or shift takes as an immediate; one
    // nothing else reads isn't materialized at all.
    const imm_uses = try gpa.alloc(u32, n);
    defer gpa.free(imm_uses);
    @memset(imm_uses, 0);
    for (r.insts.items, 0..) |i, idx| {
        if (d[idx].skip or i.b == ir.none or i.a == i.b) continue;
        const c = r.insts.items[i.b];
        if (c.op != .@"const") continue;
        if (immB(r, i, c.aux)) {
            d[idx].imm_b = true;
            imm_uses[i.b] += 1;
        }
    }
    for (r.insts.items, 0..) |i, idx| {
        if (i.op == .@"const" and !d[idx].skip and uses[idx] == imm_uses[idx]) {
            d[idx].skip = true;
            d[idx].virtual = true;
        }
    }
    // A flags producer or condition nothing reads from a register stays
    // virtual. eflags.cond is only virtual if it was computed from NZCV.
    for (r.insts.items, 0..) |i, idx| {
        if (d[idx].skip or need[idx]) continue;
        switch (i.op) {
            .icmp, .@"nzcv.add", .@"nzcv.sub", .@"nzcv.logic", .@"nzcv.adc", .@"nzcv.sbc" => d[idx].virtual = true,
            .@"nzcv.cond" => d[idx].virtual = i.aux < 14,
            .@"eflags.cond" => d[idx].virtual = d[idx].host_cc != null,
            else => if (eflagsKind(i.op) != null) {
                d[idx].virtual = true;
            },
        }
    }
    return d;
}

// ---------------------------------------------------------------- emit

/// The Emitter interface. The arm64 emitter plans its own registers
/// (regalloc.zig), so `a` is unused.
pub fn emit(gpa: std.mem.Allocator, r: *const ir.Region, a: *const alloc_mod.Allocation, out: *std.ArrayList(u8)) EmitError!emitter.Code {
    _ = a;
    return emitRegion(gpa, r, out);
}

pub fn emitRegion(gpa: std.mem.Allocator, r: *const ir.Region, out: *std.ArrayList(u8)) EmitError!emitter.Code {
    var lazy = try lazyFlags(gpa, r);
    defer lazy.deinit(gpa);
    const d = try decide(gpa, r, lazy.edge_pend);
    defer gpa.free(d);
    const virtual = try gpa.alloc(bool, d.len);
    defer gpa.free(virtual);
    for (d, virtual) |x, *v| v.* = x.virtual;
    // Lazy flags' values, or a virtual producer's operands, live to the
    // block's terminator, where the edges may write them.
    const extend = try gpa.alloc(u32, d.len);
    defer gpa.free(extend);
    @memset(extend, 0);
    for (r.blocks.items) |blk| {
        const last: u32 = @intCast(blk.start + blk.len - 1);
        for (blk.start..last) |idx| {
            if (!lazy.edge_pend[idx]) continue;
            const f = r.insts.items[idx].a;
            if (d[f].virtual) {
                for (r.insts.items[f].operands()) |o| if (o != ir.none) {
                    extend[o] = last;
                };
            } else extend[f] = last;
        }
    }
    var p = regalloc.planExtended(gpa, r, host, virtual, extend) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.TooLarge => error.TooLarge,
    };
    defer p.deinit(gpa);

    var e: E = .{ .gpa = gpa, .out = out, .base = out.items.len, .r = r, .p = p, .d = d, .lazy = lazy };
    defer e.deinit();
    for (r.blocks.items) |_| _ = try e.label();
    e.epilogue = try e.label();
    e.epilogue_plain = try e.label();
    pickVchunks(&e);
    for (lazy.after_poll) |*lbl| lbl.* = try e.label();
    for (r.insts.items) |i| {
        if (i.op == .copy and i.aux & regalloc.copy_fp != 0 and !regalloc.isCall(i)) e.fp = true;
        if (i.op == .retire) e.lazy_retire = true;
    }

    // Prologue.
    const frame: u32 = ((p.slots + save_slots) * 8 + 15) & ~@as(u32, 15);
    try e.put(0xA9800000 | @as(u32, @as(u7, @bitCast(@as(i7, -@as(i7, @intCast(save_bytes / 8)))))) << 15 | 30 << 10 | @as(u32, SP) << 5 | @as(u32, FP)); // stp x29, x30, [sp, #-save]!
    for (saved_pairs, 0..) |pr, k| try e.put(0xA9000000 | @as(u32, @intCast(2 + 2 * k)) << 15 | @as(u32, pr[1]) << 10 | @as(u32, SP) << 5 | @as(u32, pr[0]));
    try e.put(0x910003FD); // mov x29, sp
    try e.mov(CTX, 0);
    try e.ldrCtx(CPU, ctx.off.cpu);
    try e.ldrCtx(TLBR, ctx.off.tlb);
    try e.put(0x91400000 | 1 << 10 | @as(u32, TLBR) << 5 | @as(u32, TLBW)); // add x22, x21, #1, lsl #12
    comptime std.debug.assert(mem.tlb_write_off == 4096 and mem.tlb_read_off == 0);
    // The chain entry: a chained jump arrives here with x19 to x22 and the
    // frame's save area as above.
    e.code.chain_entry = @intCast(e.pos());
    try e.put(0x910003BF); // mov sp, x29
    if (frame >> 12 != 0) try e.put(0xD1400000 | (frame >> 12) << 10 | @as(u32, SP) << 5 | @as(u32, SP));
    if (frame & 0xfff != 0) try e.put(0xD1000000 | (frame & 0xfff) << 10 | @as(u32, SP) << 5 | @as(u32, SP));
    if (e.fp) try fpEnter(&e, true);
    if (e.lazy_retire) try e.mov(RC, ZR);
    if (lazy.on) try e.strSlot(ZR, e.saveArea(lz_save));
    try e.vLoad();
    try e.loadChunks();

    for (r.blocks.items, 0..) |blk, bi| {
        e.block = @intCast(bi);
        e.bind(@intCast(bi));
        e.dirty = p.dirty_in[bi];
        e.pend = null;
        if (lazy.on and lazy.carried_in[bi]) e.pend = .{ .v = ir.none, .off = lazy.off, .group = lazy.group, .carried = true };
        for (blk.start..blk.start + blk.len) |idx| {
            if (d[idx].skip) continue;
            try lower(&e, idx);
            if (idx == blk.start and lazy.on and lazy.entry_poll[bi]) e.bind(lazy.after_poll[bi]);
        }
    }

    // Epilogue: w0 holds the exit code.
    e.bind(e.epilogue);
    if (e.fp) try fpLeave(&e);
    e.bind(e.epilogue_plain);
    try e.put(0x910003BF); // mov sp, x29
    for (saved_pairs, 0..) |pr, k| try e.put(0xA9400000 | @as(u32, @intCast(2 + 2 * k)) << 15 | @as(u32, pr[1]) << 10 | @as(u32, SP) << 5 | @as(u32, pr[0]));
    try e.put(0xA8C00000 | @as(u32, save_bytes / 8) << 15 | 30 << 10 | @as(u32, SP) << 5 | @as(u32, FP)); // ldp x29, x30, [sp], #save
    try e.put(0xD65F03C0); // ret

    var si: usize = 0;
    while (si < e.stubs.items.len) : (si += 1) try emitStub(&e, e.stubs.items[si]);
    for (e.table_label, 0..) |tl, k| if (tl) |l| {
        e.bind(l);
        for (tables[k]) |entry| try e.out.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeToLittle(u16, entry)));
    };

    for (e.fixups.items) |f| {
        const to = e.labels.items[f.label].?;
        const delta = @as(i64, @intCast(to)) - @as(i64, @intCast(f.pos));
        const w = e.word(f.pos);
        e.patch(f.pos, switch (f.kind) {
            .b26 => blk: {
                if (delta < -(1 << 27) or delta >= (1 << 27)) return error.TooLarge;
                break :blk w | (@as(u32, @truncate(@as(u64, @bitCast(delta >> 2)))) & 0x3ffffff);
            },
            .b19 => blk: {
                if (delta < -(1 << 20) or delta >= (1 << 20)) return error.TooLarge;
                break :blk w | (@as(u32, @truncate(@as(u64, @bitCast(delta >> 2)))) & 0x7ffff) << 5;
            },
            .adr => blk: {
                if (delta < -(1 << 20) or delta >= (1 << 20)) return error.TooLarge;
                const u: u32 = @truncate(@as(u64, @bitCast(delta)));
                break :blk w | (u & 3) << 29 | ((u >> 2) & 0x7ffff) << 5;
            },
        });
    }
    e.code.entry = 0;
    return e.code;
}

fn emitStub(e: *E, s: Stub) !void {
    switch (s) {
        .slow => |x| {
            e.bind(x.label);
            if (x.fault_only) {
                try e.restoreRegs(x.save);
                return e.leave(.fault, x.pc, try stubPend(e, x.pend, x.dirty), x.retired);
            }
            try e.saveRegs(x.save);
            try e.put(0xD53B4200 | @as(u32, IP0)); // mrs x16, nzcv
            try e.strSlot(IP0, e.saveArea(nzcv_save));
            try e.mov(IP1, x.va);
            if (x.store) try e.mov(3, x.val);
            try e.mov(1, IP1);
            try e.mov(0, CTX);
            try e.movImm(2, x.size);
            // TSO: the slow path's plain accesses are fenced instead.
            if (x.tso and x.store) try e.put(0xD5033BBF); // dmb ish
            try e.ldrCtx(IP0, if (x.store) ctx.off.slow_store else ctx.off.slow_load);
            try e.callOut(IP0);
            const fault = try e.label();
            try e.cbnz(false, 0, fault);
            if (x.tso and !x.store) try e.put(0xD5033BBF);
            if (!x.store) try e.ldrCtx(x.dst, ctx.off.scratch);
            try e.restoreRegs(x.save);
            try e.ldrSlot(IP0, e.saveArea(nzcv_save));
            try e.put(0xD51B4200 | @as(u32, IP0)); // msr nzcv, x16
            try e.b(x.back);
            e.bind(fault);
            try e.restoreRegs(x.save);
            if (x.rmw) try reportWrite(e);
            try e.leave(.fault, x.pc, try stubPend(e, x.pend, x.dirty), x.retired);
        },
        .poll => |x| {
            e.bind(x.label);
            try e.leave(.interrupted, x.pc, try stubPend(e, x.pend, x.dirty), x.retired);
        },
        .vslow => |x| {
            e.bind(x.label);
            try e.saveRegs(x.save);
            try e.put(0xD53B4200 | @as(u32, IP0)); // mrs x16, nzcv
            try e.strSlot(IP0, e.saveArea(nzcv_save));
            try e.strSlot(x.va, e.saveArea(va_save));
            const fault = try e.label();
            for (0..2) |h| {
                try e.ldrSlot(1, e.saveArea(va_save));
                if (h == 1) try e.put(0x91000000 | 8 << 10 | 1 << 5 | 1); // add x1, x1, #8
                try e.mov(0, CTX);
                try e.movImm(2, 3);
                if (x.store) try e.ldrSlot(3, x.slot + @as(u32, @intCast(h)));
                try e.ldrCtx(IP0, if (x.store) ctx.off.slow_store else ctx.off.slow_load);
                try e.callOut(IP0);
                try e.cbnz(false, 0, fault);
                if (!x.store) {
                    try e.ldrCtx(IP0, ctx.off.scratch);
                    try e.strSlot(IP0, x.slot + @as(u32, @intCast(h)));
                }
            }
            if (x.tso and !x.store) try e.put(0xD5033BBF);
            try e.restoreRegs(x.save);
            try e.ldrSlot(IP0, e.saveArea(nzcv_save));
            try e.put(0xD51B4200 | @as(u32, IP0)); // msr nzcv, x16
            try e.b(x.back);
            e.bind(fault);
            try e.restoreRegs(x.save);
            try e.leave(.fault, x.pc, try stubPend(e, x.pend, x.dirty), x.retired);
        },
        .misaligned => |x| {
            e.bind(x.label);
            try e.strCtx(x.va, ctx.off.exit_addr);
            try e.movImm(IP0, @as(u64, @intFromEnum(x.acc)) | (@as(u64, @intFromEnum(mem.FaultKind.alignment)) << 8));
            try e.strCtx(IP0, ctx.off.exit_info);
            try e.leave(.fault, x.pc, try stubPend(e, x.pend, x.dirty), x.retired);
        },
    }
}

/// Writes pending flags (packed for their group) to the guest.
fn writePend(e: *E, p: Pend) !void {
    if (p.group == 2) return writeRecord(e, p);
    var skip: ?u32 = null;
    const f = if (p.carried) blk: {
        // From the lz slots, if anything's carried: evalOpC(code, a, b, c).
        skip = try e.label();
        try e.ldrSlot(IP0, e.saveArea(lz_save));
        try e.cbz(true, IP0, skip.?);
        try e.saveRegs(caller_saved_mask);
        try e.mov(0, IP0);
        for (1..4) |k| try e.ldrSlot(@intCast(k), e.saveArea(lz_save + k));
        try e.movImm(4, 0);
        try e.movImm(IP0, @intFromPtr(&ir_eval.evalOpC));
        try e.callOut(IP0);
        try e.mov(SD, 0);
        try e.restoreRegs(caller_saved_mask);
        try e.strSlot(ZR, e.saveArea(lz_save));
        break :blk SD;
    } else if (e.p.locs[p.v] == .none) try rematFlags(e, p.v) else try e.src(p.v, S0);
    if (p.group == 0) {
        try e.logImm(0, true, IP0, f, 28, 4);
    } else {
        try e.movImm(IP0, ir_eval.eflags_mask);
        try e.dp(0x0A000000, false, IP0, f, IP0);
    }
    // Merged into the slot, keeping its other bits (ir.zig: EFLAGS' DF,
    // IF, and bit 1).
    try readGuest(e, p.off, 4, IP1);
    try e.movImm(S0, if (p.group == 0) 0xf000_0000 else ir_eval.eflags_mask);
    try e.dp(0x0A200000, false, IP1, IP1, S0); // bic w17, w17, w9
    try e.dp(0x2A000000, false, IP0, IP0, IP1); // orr w16, w16, w17
    try writeGuest(e, p.off, 4, IP0);
    if (skip) |l| e.bind(l);
}

/// A lazy pending.flags (aux2 2): ir.LazyRecord at off + 4, from the
/// producer's operands, as ir.lazyRecord makes it.
fn writeRecord(e: *E, p: Pend) !void {
    const f = e.r.insts.items[p.v];
    const ta = e.r.insts.items[f.a].ty;
    const W = ta.bits();
    const kind = ir.lazyKind(f.op).?;
    const a = try e.src(f.a, S0);
    const base = p.off + 4;
    // kind | size << 8 | cin << 16
    try e.movImm(IP0, @as(u64, @intFromEnum(kind)) | @as(u64, W / 8) << 8);
    const cin: ?Ref = switch (f.op) {
        .@"eflags.adc", .@"eflags.sbb" => f.c,
        .@"eflags.inc", .@"eflags.dec" => f.b,
        else => null,
    };
    if (cin) |c| {
        try e.ubfx(IP1, try e.src(c, S2), 0, 1);
        try e.dpShift(0x2A000000, false, IP0, IP0, IP1, 0, 16);
    }
    try e.ldst(true, 2, IP0, CPU, base);
    switch (kind) {
        .add, .sub => {
            const b = try e.src(f.b, S1);
            try e.ldst(true, 2, a, CPU, base + 4);
            try e.ldst(true, 2, b, CPU, base + 8);
            try e.dp(if (kind == .add) 0x0B000000 else 0x4B000000, false, IP0, a, b);
            if (cin != null) try e.dp(if (kind == .add) 0x0B000000 else 0x4B000000, false, IP0, IP0, IP1);
            if (W < 32) try e.zx(IP0, IP0, W);
            try e.ldst(true, 2, IP0, CPU, base + 12);
        },
        .logic => {
            try e.ldst(true, 2, ZR, CPU, base + 4);
            try e.ldst(true, 2, ZR, CPU, base + 8);
            try e.ldst(true, 2, a, CPU, base + 12);
        },
        .inc, .dec => {
            try e.ldst(true, 2, a, CPU, base + 4);
            try e.movImm(IP0, 1);
            try e.ldst(true, 2, IP0, CPU, base + 8);
            try e.put((if (kind == .inc) @as(u32, 0x11000400) else 0x51000400) | @as(u32, a) << 5 | IP0); // a ± 1
            if (W < 32) try e.zx(IP0, IP0, W);
            try e.ldst(true, 2, IP0, CPU, base + 12);
        },
        .shl, .shr, .mul => {
            const b = try e.src(f.b, S1);
            if (kind == .mul) {
                try e.logImm(0, false, IP0, a, 0, 1);
                try e.ldst(true, 2, IP0, CPU, base + 4);
            } else try e.ldst(true, 2, a, CPU, base + 4);
            try e.ldst(true, 2, ZR, CPU, base + 8);
            try e.ldst(true, 2, b, CPU, base + 12);
        },
        .none => unreachable,
    }
}

/// Carries lazy pending flags over an edge in the lz slots: the producer's
/// evalOpC code and operands (or the materialized value, as an unpack).
fn carryPend(e: *E, p: Pend) !void {
    const fi = e.r.insts.items[p.v];
    if (e.p.locs[p.v] == .none) {
        const ta = e.r.insts.items[fi.a].ty;
        try e.movImm(IP0, ir_eval.fallbackCode(fi.op, fi.ty, ta));
        try e.strSlot(IP0, e.saveArea(lz_save));
        for ([3]Ref{ fi.a, fi.b, fi.c }, 1..) |o, k| {
            if (o == ir.none) continue;
            if (k == 2 and e.d[p.v].imm_b) {
                try e.movImm(IP0, e.r.insts.items[o].aux);
                try e.strSlot(IP0, e.saveArea(lz_save + k));
            } else try e.strSlot(try e.src(o, S0), e.saveArea(lz_save + k));
        }
    } else {
        const unpack: Op = if (p.group == 0) .@"nzcv.unpack" else .@"eflags.unpack";
        try e.movImm(IP0, ir_eval.fallbackCode(unpack, .flags, .i32));
        try e.strSlot(IP0, e.saveArea(lz_save));
        try e.strSlot(try e.src(p.v, S0), e.saveArea(lz_save + 1));
    }
}

/// Whether a flags value can be recomputed from its operands where lazy
/// pending flags are written (so it needn't be materialized where made).
fn rematerializable(op: Op) bool {
    return switch (op) {
        .@"nzcv.add", .@"nzcv.sub", .@"nzcv.logic" => true,
        else => eflagsKind(op) != null,
    };
}

/// Recomputes the virtual flags value `v` from its operands, into x12.
fn rematFlags(e: *E, v: Ref) !u5 {
    const i = e.r.insts.items[v];
    if (eflagsKind(i.op) != null) {
        try eflagsCore(e, v, SD);
        return SD;
    }
    const ta = e.r.insts.items[i.a].ty;
    const a = try e.src(i.a, S0);
    const s64 = ta == .i64;
    switch (i.op) {
        .@"nzcv.logic" => try e.dp(0x6A000000, s64, ZR, a, a),
        .@"nzcv.add", .@"nzcv.sub" => if (e.d[v].imm_b) {
            const imm: u32 = @intCast(e.r.insts.items[i.b].aux);
            try e.put((if (i.op == .@"nzcv.add") @as(u32, 0x31000000) else 0x71000000) | (if (s64) @as(u32, 0x8000_0000) else 0) | imm << 10 | @as(u32, a) << 5 | ZR);
        } else {
            const bb = try e.src(i.b, S1);
            try e.dp(if (i.op == .@"nzcv.add") 0x2B000000 else 0x6B000000, s64, ZR, a, bb);
        },
        else => unreachable,
    }
    try e.put(0xD53B4200 | @as(u32, SD)); // mrs x12, nzcv
    return SD;
}

/// A branch to block `t` carrying lazy pending flags: written if `t` needs
/// them; else, if `t` starts with a poll, that poll is done here (writing
/// them only if it leaves) and the branch skips it; else they're dropped.
fn edgeTo(e: *E, t: u32, fallthrough_ok: bool) !void {
    const lz = &e.lazy;
    if (e.pend) |p| if (p.edge) {
        if (lz.need_full[t] and lz.carry_ok[t] and p.group != 2) {
            try carryPend(e, p);
        } else if (lz.need_full[t] and !(lz.entry_poll[t] and !lz.need_after_poll[t])) {
            try writePend(e, p);
        } else if (lz.entry_poll[t] and !lz.need_after_poll[t]) {
            const poll = e.r.insts.items[e.r.blocks.items[t].start];
            const l = try e.label();
            try e.stubs.append(e.gpa, .{ .poll = .{ .label = l, .dirty = e.dirty, .pc = poll.aux, .retired = poll.retired, .pend = p } });
            try pollCheck(e, l);
            return e.b(lz.after_poll[t]);
        }
    };
    if (!(fallthrough_ok and t == e.block + 1)) try e.b(t);
}

/// exit_request, and the budget less what's retired but not yet counted:
/// to `l` if the region must leave.
fn pollCheck(e: *E, l: u32) !void {
    try e.put(0xB9400000 | (ctx.off.exit_request / 4) << 10 | @as(u32, CTX) << 5 | @as(u32, IP0)); // ldr w16, [x19, #exit_request]
    try e.ldrCtx(IP1, ctx.off.budget);
    if (e.lazy_retire) try e.dp(0x6B000000, true, ZR, IP1, RC) else try e.put(0xF100001F | @as(u32, IP1) << 5); // cmp x17, x28 or #0
    try e.put(0x7A400800 | 12 << 12 | @as(u32, IP0) << 5); // ccmp w16, #0, #0, gt
    try e.bcond(NE, l);
}

/// Writes the main line's pending flags, if any, now.
fn flushPend(e: *E) !void {
    if (e.pend) |p| try writePend(e, p);
    e.pend = null;
}

/// A stub's way out: its pending flags written, and its dirty set with
/// their chunk.
fn stubPend(e: *E, p: ?Pend, dirty: regalloc.ChunkSet) !regalloc.ChunkSet {
    const pp = p orelse return dirty;
    try writePend(e, pp);
    if (e.p.chunkAt(pp.off, 4)) |k| return dirty | @as(regalloc.ChunkSet, 1) << @intCast(k);
    return dirty;
}

/// A read-modify-write's load faulted: report the access as a write.
fn reportWrite(e: *E) !void {
    try e.ldrCtx(IP0, ctx.off.exit_info);
    try e.logImm(0, true, IP0, IP0, 8, 56);
    try e.logImm(1, true, IP0, IP0, 0, 1);
    try e.strCtx(IP0, ctx.off.exit_info);
}

fn lower(e: *E, idx: usize) EmitError!void {
    const r = e.r;
    const i = r.insts.items[idx];
    const dd = e.d[idx];
    const ty = i.ty;
    const ta: Type = if (i.a != ir.none) r.insts.items[i.a].ty else .none;
    const W = ty.bits();
    const sf = W > 32;
    if (e.pend) |p| switch (i.op) {
        .@"call.interp", .copy => try flushPend(e),
        .@"call.helper" => if (regalloc.touchesRegs(i)) try flushPend(e),
        .setreg => if (sizeLog2(ta)) |sz| if (i.aux < p.off + 4 and p.off < i.aux + (@as(u64, 1) << sz)) {
            if (p.carried) try e.strSlot(ZR, e.saveArea(lz_save));
            e.pend = null;
        },
        else => if (i.op.isTerminator() and !(p.edge and (i.op == .br or i.op == .brcond))) try flushPend(e),
    };
    if (i.op.isExt() or ty == .v128 or ta == .v128) return lowerExt(e, idx);

    switch (i.op) {
        .@"const" => {
            const rd = e.dst(idx);
            try e.movImm(rd, if (ty == .flags) i.aux else i.aux & ty.mask());
            try e.finish(idx, rd);
        },
        .getreg => {
            if (e.fp and i.aux == host.guest_fpsr.?) try fpFlush(e);
            if (vchunkFor(e, i.aux, W / 8)) |vc| {
                const rd = e.dst(idx);
                try vGetSet(e, false, vc.q, vc.base, i.aux, W / 8, @intCast(idx), rd);
                return e.finish(idx, rd);
            }
            const rd = e.dst(idx);
            const ck = e.p.chunk_of[idx];
            if (ck != regalloc.no_chunk) {
                const c = e.p.chunks[ck];
                const lsb: u32 = @intCast((i.aux - c.off) * 8);
                const bits: u32 = if (ty == .flags) 64 else W;
                if (bits == @as(u32, c.bytes) * 8) try e.mov(rd, @intCast(c.reg)) else try e.ubfx(rd, @intCast(c.reg), lsb, bits);
            } else {
                try e.ldst(false, sizeLog2(ty) orelse return error.Unsupported, rd, CPU, i.aux);
            }
            try e.finish(idx, rd);
        },
        .setreg => {
            if (vchunkFor(e, i.aux, ta.bits() / 8)) |vc| {
                const v = try e.src(i.a, S0);
                return vGetSet(e, true, vc.q, vc.base, i.aux, ta.bits() / 8, i.a, v);
            }
            const v = try e.src(i.a, S0);
            const ck = e.p.chunk_of[idx];
            if (ck != regalloc.no_chunk) {
                const c = e.p.chunks[ck];
                const lsb: u32 = @intCast((i.aux - c.off) * 8);
                const bits = ta.bits();
                if (bits == @as(u32, c.bytes) * 8) try e.mov(@intCast(c.reg), v) else try e.bfi(@intCast(c.reg), v, lsb, bits);
                e.dirty |= @as(regalloc.ChunkSet, 1) << @intCast(ck);
            } else {
                try e.ldst(true, sizeLog2(ta) orelse return error.Unsupported, v, CPU, i.aux);
            }
            if (e.fp and i.aux == host.guest_fpsr.?) try e.put(0xD51B4420 | @as(u32, ZR)); // msr fpsr, xzr: the guest's write replaces what's pending
            if (e.fp and i.aux == host.guest_fpcr.?) try e.put(0xD51B4400 | @as(u32, v)); // msr fpcr
        },
        .add, .sub => if (dd.imm_b) {
            const a = try e.src(i.a, S0);
            const rd = e.dst(idx);
            const imm: u32 = @intCast(r.insts.items[i.b].aux);
            try e.put((if (i.op == .add) @as(u32, 0x11000000) else 0x51000000) | (if (sf) @as(u32, 0x8000_0000) else 0) | imm << 10 | @as(u32, a) << 5 | rd);
            try e.finish(idx, rd);
        } else try binOp(e, idx),
        .mul, .@"and", .@"or", .xor, .andn, .udiv => try binOp(e, idx),
        .shl, .lshr, .ashr => if (dd.imm_b) {
            const a = try e.src(i.a, S0);
            const rd = e.dst(idx);
            const k: u32 = @intCast(r.insts.items[i.b].aux % W);
            switch (i.op) {
                .shl => try e.lslImm(sf, rd, a, k),
                .lshr => try e.lsrImm(sf, rd, a, k),
                else => try e.sbfm(sf, rd, a, k, W - 1),
            }
            try e.finish(idx, rd);
        } else try shiftOp(e, idx),
        .ror, .rol => try shiftOp(e, idx),
        .mulhu, .mulhs => {
            const a = try e.src(i.a, S0);
            const bb = try e.src(i.b, S1);
            const rd = e.dst(idx);
            const signed = i.op == .mulhs;
            switch (W) {
                64 => try e.dp(if (signed) 0x9B407C00 else 0x9BC07C00, false, rd, a, bb),
                32 => {
                    try e.dp(if (signed) 0x9B207C00 else 0x9BA07C00, false, rd, a, bb); // smull/umull
                    try e.lsrImm(true, rd, rd, 32);
                },
                else => {
                    if (signed) {
                        try e.sbfm(false, IP0, a, 0, W - 1);
                        try e.sbfm(false, IP1, bb, 0, W - 1);
                        try e.dp(0x1B007C00, false, rd, IP0, IP1);
                    } else try e.dp(0x1B007C00, false, rd, a, bb);
                    try e.ubfx(rd, rd, W, W);
                },
            }
            try e.finish(idx, rd);
        },
        .sdiv, .urem, .srem => {
            var a = try e.src(i.a, S0);
            var bb = try e.src(i.b, S1);
            const rd = e.dst(idx);
            const signed = i.op != .urem;
            if (signed and W < 32) {
                try e.sbfm(false, IP1, a, 0, W - 1);
                try e.sbfm(false, T0, bb, 0, W - 1);
                a = IP1;
                bb = T0;
            }
            const div: u32 = if (signed) 0x1AC00C00 else 0x1AC00800;
            if (i.op == .sdiv) {
                try e.dp(div, sf, rd, a, bb);
            } else {
                try e.dp(div, sf, IP0, a, bb);
                try e.put(0x1B008000 | (if (sf) @as(u32, 0x8000_0000) else 0) | @as(u32, bb) << 16 | @as(u32, a) << 10 | @as(u32, IP0) << 5 | @as(u32, rd)); // msub rd, q, b, a
            }
            if (signed and W < 32) try e.zx(rd, rd, W);
            try e.finish(idx, rd);
        },
        .neg => {
            const a = try e.src(i.a, S0);
            const rd = e.dst(idx);
            try e.dp(0x4B000000, sf, rd, ZR, a);
            if (W < 32) try e.zx(rd, rd, W);
            try e.finish(idx, rd);
        },
        .not => {
            const a = try e.src(i.a, S0);
            const rd = e.dst(idx);
            if (W >= 32) try e.dp(0x2A200000, sf, rd, ZR, a) else try e.logImm(2, false, rd, a, 0, W);
            try e.finish(idx, rd);
        },
        .clz => {
            const a = try e.src(i.a, S0);
            const rd = e.dst(idx);
            try e.put((if (sf) @as(u32, 0xDAC01000) else 0x5AC01000) | @as(u32, a) << 5 | @as(u32, rd));
            if (W < 32) try e.put(0x51000000 | (32 - W) << 10 | @as(u32, rd) << 5 | @as(u32, rd)); // sub w, w, #(32 - W)
            try e.finish(idx, rd);
        },
        .ctz => {
            var a = try e.src(i.a, S0);
            const rd = e.dst(idx);
            if (W < 32) {
                try e.logImm(1, false, IP0, a, W, 1); // orr #1<<W: W when a is 0
                a = IP0;
            }
            try e.put((if (sf) @as(u32, 0xDAC00000) else 0x5AC00000) | @as(u32, a) << 5 | @as(u32, IP0)); // rbit
            try e.put((if (sf) @as(u32, 0xDAC01000) else 0x5AC01000) | @as(u32, IP0) << 5 | @as(u32, rd)); // clz
            try e.finish(idx, rd);
        },
        .popcnt => {
            const a = try e.src(i.a, S0);
            const rd = e.dst(idx);
            try e.put(0x9E670000 | @as(u32, a) << 5 | 0); // fmov d0, x
            try e.put(0x0E205800); // cnt v0.8b, v0.8b
            try e.put(0x0E31B800); // addv b0, v0.8b
            try e.put(0x1E260000 | @as(u32, rd)); // fmov w, s0
            try e.finish(idx, rd);
        },
        .rbit => {
            const a = try e.src(i.a, S0);
            const rd = e.dst(idx);
            if (W == 1) try e.mov(rd, a) else {
                try e.put((if (sf) @as(u32, 0xDAC00000) else 0x5AC00000) | @as(u32, a) << 5 | @as(u32, rd));
                if (W < 32) try e.lsrImm(false, rd, rd, 32 - W);
            }
            try e.finish(idx, rd);
        },
        .bswap => {
            const a = try e.src(i.a, S0);
            const rd = e.dst(idx);
            switch (W) {
                64 => try e.put(0xDAC00C00 | @as(u32, a) << 5 | @as(u32, rd)),
                32 => try e.put(0x5AC00800 | @as(u32, a) << 5 | @as(u32, rd)),
                16 => try e.put(0x5AC00400 | @as(u32, a) << 5 | @as(u32, rd)), // rev16
                else => try e.mov(rd, a),
            }
            try e.finish(idx, rd);
        },
        .zext => {
            const a = try e.src(i.a, S0);
            const rd = e.dst(idx);
            try e.mov(rd, a);
            try e.finish(idx, rd);
        },
        .trunc => {
            const a = try e.src(i.a, S0);
            const rd = e.dst(idx);
            try e.zx(rd, a, if (ty == .i1) 1 else W);
            try e.finish(idx, rd);
        },
        .sext => {
            const a = try e.src(i.a, S0);
            const rd = e.dst(idx);
            const from = ta.bits();
            if (from == W) try e.mov(rd, a) else if (W == 64) try e.sbfx64(rd, a, from) else {
                try e.sbfm(false, rd, a, 0, from - 1);
                if (W < 32) try e.zx(rd, rd, W);
            }
            try e.finish(idx, rd);
        },
        .select => {
            const bb = try e.src(i.b, S1);
            const c = try e.src(i.c, S2);
            const rd = e.dst(idx);
            const cc: Cond = dd.host_cc orelse blk: {
                const a = try e.src(i.a, S0);
                try e.put(0x7100001F | @as(u32, a) << 5); // cmp w, #0
                break :blk NE;
            };
            try e.put(0x9A800000 | @as(u32, c) << 16 | @as(u32, cc) << 12 | @as(u32, bb) << 5 | @as(u32, rd)); // csel
            try e.finish(idx, rd);
        },
        .icmp => if (dd.imm_b) {
            // 32 or 64 bits against a 12-bit constant.
            const a = try e.src(i.a, S0);
            const imm: u32 = @intCast(r.insts.items[i.b].aux);
            try e.put(0x71000000 | (if (ta.bits() > 32) @as(u32, 0x8000_0000) else 0) | imm << 10 | @as(u32, a) << 5 | ZR); // cmp #imm
            if (!dd.virtual) {
                const rd = e.dst(idx);
                try e.cset(rd, pred_cond[@intCast(i.aux)]);
                try e.finish(idx, rd);
            }
        } else {
            var a = try e.src(i.a, S0);
            var bb = try e.src(i.b, S1);
            const bits = ta.bits();
            const pred: ir.Pred = @enumFromInt(i.aux);
            const signed = @intFromEnum(pred) >= @intFromEnum(ir.Pred.slt);
            if (signed and bits < 32) {
                try e.sbfm(false, IP0, a, 0, bits - 1);
                try e.sbfm(false, IP1, bb, 0, bits - 1);
                a = IP0;
                bb = IP1;
            }
            try e.dp(0x6B000000, bits > 32, ZR, a, bb); // cmp
            if (!dd.virtual) {
                const rd = e.dst(idx);
                try e.cset(rd, pred_cond[@intCast(i.aux)]);
                try e.finish(idx, rd);
            }
        },
        .@"nzcv.add", .@"nzcv.sub", .@"nzcv.logic", .@"nzcv.adc", .@"nzcv.sbc" => {
            const a = try e.src(i.a, S0);
            const s64 = ta == .i64;
            if (dd.msr) {
                const c = try e.src(i.c, S2);
                try e.put(0xD51B4200 | @as(u32, c)); // msr nzcv
            }
            switch (i.op) {
                .@"nzcv.logic" => try e.dp(0x6A000000, s64, ZR, a, a), // tst
                .@"nzcv.add", .@"nzcv.sub" => if (dd.imm_b) {
                    const imm: u32 = @intCast(r.insts.items[i.b].aux);
                    try e.put((if (i.op == .@"nzcv.add") @as(u32, 0x31000000) else 0x71000000) | (if (s64) @as(u32, 0x8000_0000) else 0) | imm << 10 | @as(u32, a) << 5 | ZR); // adds/subs zr, a, #imm
                } else {
                    const bb = try e.src(i.b, S1);
                    try e.dp(if (i.op == .@"nzcv.add") 0x2B000000 else 0x6B000000, s64, ZR, a, bb);
                },
                else => {
                    const bb = try e.src(i.b, S1);
                    try e.dp(switch (i.op) {
                        .@"nzcv.add" => 0x2B000000,
                        .@"nzcv.sub" => 0x6B000000,
                        .@"nzcv.adc" => 0x3A000000,
                        .@"nzcv.sbc" => 0x7A000000,
                        else => unreachable,
                    }, s64, ZR, a, bb);
                },
            }
            if (!dd.virtual) {
                const rd = e.dst(idx);
                try e.put(0xD53B4200 | @as(u32, rd)); // mrs
                try e.finish(idx, rd);
            }
        },
        .@"nzcv.cond" => {
            if (i.aux >= 14) {
                const rd = e.dst(idx);
                try e.movImm(rd, 1);
                try e.finish(idx, rd);
            } else {
                if (dd.msr) {
                    const f = try e.src(i.a, S0);
                    try e.put(0xD51B4200 | @as(u32, f));
                }
                if (!dd.virtual) {
                    const rd = e.dst(idx);
                    try e.cset(rd, @intCast(i.aux));
                    try e.finish(idx, rd);
                }
            }
        },
        .@"pending.flags" => {
            // Deferred: written only on the way out of the block, before a
            // call, or when other flags take a different slot.
            if (e.pend) |p| {
                if (p.carried) {
                    try e.strSlot(ZR, e.saveArea(lz_save)); // replaced
                } else if (p.off != i.aux or p.group != i.aux2) try writePend(e, p);
            }
            e.pend = .{ .v = i.a, .off = i.aux, .group = i.aux2, .edge = e.lazy.edge_pend[idx] };
        },
        .@"nzcv.pack", .@"nzcv.unpack" => {
            const a = try e.src(i.a, S0);
            const rd = e.dst(idx);
            try e.logImm(0, true, rd, a, 28, 4);
            try e.finish(idx, rd);
        },
        .@"eflags.add", .@"eflags.sub", .@"eflags.logic", .@"eflags.inc", .@"eflags.dec" => try eflagsOp(e, idx),
        .@"eflags.shl", .@"eflags.shr", .@"eflags.mul" => try shiftMulFlags(e, idx),
        .@"eflags.cond" => {
            if (dd.host_cc) |c| {
                if (!dd.virtual) {
                    const rd = e.dst(idx);
                    try e.cset(rd, c);
                    try e.finish(idx, rd);
                }
            } else {
                const f = try e.src(i.a, S0);
                const rd = e.dst(idx);
                switch (i.aux >> 1) {
                    0 => try e.ubfx(rd, f, 11, 1),
                    1 => try e.ubfx(rd, f, 0, 1),
                    2 => try e.ubfx(rd, f, 6, 1),
                    3 => {
                        try e.lsrImm(false, IP0, f, 6);
                        try e.dp(0x2A000000, false, IP0, IP0, f);
                        try e.logImm(0, false, rd, IP0, 0, 1);
                    },
                    4 => try e.ubfx(rd, f, 7, 1),
                    5 => try e.ubfx(rd, f, 2, 1),
                    6 => {
                        try e.dpShift(0x4A000000, false, IP0, f, f, 1, 4); // eor f, f, f, lsr #4
                        try e.ubfx(rd, IP0, 7, 1);
                    },
                    else => {
                        try e.dpShift(0x4A000000, false, IP0, f, f, 1, 4);
                        try e.dpShift(0x2A000000, false, IP0, f, IP0, 1, 1); // orr: bit 6 is ZF | (SF ^ OF)
                        try e.ubfx(rd, IP0, 6, 1);
                    },
                }
                if (i.aux & 1 == 1) try e.logImm(2, false, rd, rd, 0, 1);
                try e.finish(idx, rd);
            }
        },
        .@"eflags.pack", .@"eflags.unpack" => {
            const a = try e.src(i.a, S0);
            const rd = e.dst(idx);
            try e.movImm(IP0, ir_eval.eflags_mask);
            try e.dp(0x0A000000, false, rd, a, IP0);
            try e.finish(idx, rd);
        },
        .load, .store => try memOp(e, idx),
        .cas => try casOp(e, idx),
        .fence => try e.put(switch (i.aux) {
            1 => @as(u32, 0xD50339BF),
            2 => 0xD5033ABF,
            else => 0xD5033BBF,
        }),
        .@"call.interp" => {
            try e.writeback(e.dirty);
            e.dirty = 0;
            const save = e.saveMask(idx, false);
            try e.saveRegs(save);
            if (e.fp) try fpLeave(e);
            if (e.lazy_retire) try e.retireOn(0);
            try e.mov(0, CTX);
            try e.movImm(1, r.handles.items[@intCast(i.aux)]);
            try e.movImm(2, i.aux2);
            try e.ldrCtx(IP0, ctx.off.interp);
            try e.callInterp(IP0);
            if (i.retired == 0) {
                try e.cbnz(false, 0, e.epilogue);
            } else {
                const on = try e.label();
                try e.cbz(false, 0, on);
                try e.retireOn(i.retired);
                try e.b(e.epilogue);
                e.bind(on);
            }
            try e.restoreRegs(save);
            if (e.fp) try fpEnter(e, false);
            try e.loadChunks();
        },
        .copy => try copyOp(e, idx),
        .@"call.helper" => {
            // A helper_no_regs helper leaves guest registers alone: no
            // write-back or reload, and the chunks just kept like values.
            const regs = regalloc.touchesRegs(i);
            if (regs) {
                try e.writeback(e.dirty);
                e.dirty = 0;
            }
            const args = [3]Ref{ i.a, i.b, i.c };
            const scr = [3]u5{ S0, S1, S2 };
            for (args, scr) |v, s| if (v != ir.none) try e.mov(s, try e.src(v, s));
            const save = e.saveMask(idx, !regs);
            try e.saveRegs(save);
            // Missing arguments are 0, as in ir_eval.
            if (e.fp) try fpLeave(e);
            if (e.lazy_retire) try e.retireOn(0);
            for (args, scr, 1..) |v, s, k| try e.mov(@intCast(k), if (v != ir.none) s else ZR);
            try e.mov(0, CTX);
            try e.ldrCtx(IP0, ctx.off.helpers);
            try e.ldst(false, 3, IP0, IP0, i.aux * 8);
            if (regs) try e.callInterp(IP0) else try e.callOut(IP0);
            try e.mov(SD, 0);
            try e.restoreRegs(save);
            if (e.fp) try fpEnter(e, false);
            if (regs) try e.loadChunks();
            if (ty != .none) try e.finish(idx, SD);
        },
        .poll => {
            const l = try e.label();
            try e.stubs.append(e.gpa, .{ .poll = .{ .label = l, .dirty = e.dirty, .pc = i.aux, .retired = i.retired, .pend = e.pend } });
            try e.put(0xB9400000 | (ctx.off.exit_request / 4) << 10 | @as(u32, CTX) << 5 | @as(u32, IP0)); // ldr w16, [x19, #exit_request]
            try e.ldrCtx(IP1, ctx.off.budget);
            // budget - pending > 0, and no exit request.
            if (e.lazy_retire) try e.dp(0x6B000000, true, ZR, IP1, RC) else try e.put(0xF100001F | @as(u32, IP1) << 5); // cmp x17, x28 or #0
            try e.put(0x7A400800 | 12 << 12 | @as(u32, IP0) << 5); // ccmp w16, #0, #0, gt
            try e.bcond(NE, l);
        },
        .retire => if (e.lazy_retire) {
            if (i.aux < 4096) try e.put(0x91000000 | @as(u32, @intCast(i.aux)) << 10 | @as(u32, RC) << 5 | RC) else {
                try e.movImm(IP0, i.aux);
                try e.dp(0x0B000000, true, RC, RC, IP0);
            }
        } else {
            // retired += n; budget -= n
            for ([2]u32{ ctx.off.retired, ctx.off.budget }, [2]u32{ 0x91000000, 0xD1000000 }, [2]u32{ 0x0B000000, 0x4B000000 }) |off, imm_op, reg_op| {
                try e.ldrCtx(IP0, off);
                if (i.aux < 4096) {
                    try e.put(imm_op | @as(u32, @intCast(i.aux)) << 10 | @as(u32, IP0) << 5 | @as(u32, IP0));
                } else {
                    try e.movImm(IP1, i.aux);
                    try e.dp(reg_op, true, IP0, IP0, IP1);
                }
                try e.strCtx(IP0, off);
            }
        },
        .br => try edgeTo(e, @intCast(i.aux), true),
        .brcond => if (e.pend != null and e.pend.?.edge) {
            // Each edge does its own flags work.
            const then: u32 = @intCast(i.aux);
            const els: u32 = @intCast(i.aux2);
            const lthen = try e.label();
            if (dd.host_cc) |c| try e.bcond(c, lthen) else try e.cbnz(false, try e.src(i.a, S0), lthen);
            try edgeTo(e, els, false);
            e.bind(lthen);
            try edgeTo(e, then, true);
        } else {
            const then: u32 = @intCast(i.aux);
            const els: u32 = @intCast(i.aux2);
            if (dd.host_cc) |c| {
                if (then == e.block + 1) {
                    try e.bcond(inv(c), els);
                } else {
                    try e.bcond(c, then);
                    if (els != e.block + 1) try e.b(els);
                }
            } else {
                const v = try e.src(i.a, S0);
                if (then == e.block + 1) {
                    try e.cbz(false, v, els);
                } else {
                    try e.cbnz(false, v, then);
                    if (els != e.block + 1) try e.b(els);
                }
            }
        },
        .@"exit.chain" => {
            // The chain site: the frame torn down, then one B that falls
            // through to the exit, which names the site in exit_info.
            try e.vWriteback();
            try e.writeback(e.dirty);
            try e.retireOn(i.retired);
            if (e.fp) try fpLeave(e);
            try e.put(0x910003BF); // mov sp, x29
            const site = e.pos();
            try e.put(chain_unlinked);
            if (e.code.nchains < emitter.max_chains) {
                e.code.chains[e.code.nchains] = .{ .site = @intCast(site), .pc = i.aux };
                e.code.nchains += 1;
            }
            // Unlinked (or not linkable, across pages): the jump cache,
            // with the target's index known now, before the dispatcher.
            const miss = try e.label();
            try e.ldrCtx(IP0, ctx.off.jump);
            try e.cbz(true, IP0, miss);
            try e.movImm(IP1, ctx.jumpIndex(i.aux) * @sizeOf(ctx.JumpEntry));
            try e.dp(0x0B000000, true, IP0, IP0, IP1);
            try e.ldrCtx2(IP1, IP0, 0);
            try e.movImm(T0, i.aux);
            try e.dp(0x6B000000, true, ZR, IP1, T0); // cmp
            try e.bcond(NE, miss);
            try e.ldrCtx2(IP0, IP0, 16);
            try e.put(0xD61F0000 | @as(u32, IP0) << 5); // br x16
            e.bind(miss);
            const back: u32 = @bitCast(@as(i32, @intCast(@as(isize, @intCast(site)) - @as(isize, @intCast(e.pos())))));
            try e.put(0x10000000 | (back & 3) << 29 | ((back >> 2) & 0x7ffff) << 5 | @as(u32, IP0)); // adr x16, site
            try e.strCtx(IP0, ctx.off.exit_info);
            try e.leaveTo(.chain, i.aux, 0, 0, e.epilogue_plain);
        },
        .@"exit.svc" => try e.leave(.svc, i.aux, e.dirty, i.retired),
        .@"exit.brk" => try e.leave(.brk, i.aux, e.dirty, i.retired),
        .@"exit.undef" => try e.leave(.undef, i.aux, e.dirty, i.retired),
        .@"exit.indirect" => {
            const v = try e.src(i.a, S0);
            try e.vWriteback();
            try e.writeback(e.dirty);
            try e.retireOn(i.retired);
            try e.strCtx(v, ctx.off.exit_pc);
            if (e.fp) try fpLeave(e);
            // The jump cache, inline: a hit goes straight to the target's
            // chain entry.
            const miss = try e.label();
            try e.ldrCtx(IP0, ctx.off.jump);
            try e.cbz(true, IP0, miss);
            // ctx.jumpIndex: ((pc ^ pc >> 12) >> 2) & (jump_entries - 1)
            try e.dpShift(0x4A000000, true, IP1, v, v, 1, 12); // eor x17, v, v, lsr #12
            try e.ubfx(IP1, IP1, 2, std.math.log2_int(u32, ctx.jump_entries));
            try e.movImm(T0, @sizeOf(ctx.JumpEntry));
            try e.put(0x9B000000 | @as(u32, T0) << 16 | @as(u32, IP0) << 10 | @as(u32, IP1) << 5 | IP0); // madd x16, x17, x13, x16
            try e.ldrCtx2(IP1, IP0, 0);
            try e.dp(0x6B000000, true, ZR, IP1, v); // cmp
            try e.bcond(NE, miss);
            try e.ldrCtx2(IP0, IP0, 16);
            try e.put(0x910003BF); // mov sp, x29
            try e.put(0xD61F0000 | @as(u32, IP0) << 5); // br x16
            e.bind(miss);
            try e.put(0x52800000 | @as(u32, @intFromEnum(ctx.Exit.indirect)) << 5);
            try e.b(e.epilogue_plain);
        },
        else => if (i.op.isPure()) try fallback(e, idx) else return error.Unsupported,
    }
}

fn binOp(e: *E, idx: usize) EmitError!void {
    const r = e.r;
    const i = r.insts.items[idx];
    const W = i.ty.bits();
    const sf = W > 32;
    const a = try e.src(i.a, S0);
    const bb = try e.src(i.b, S1);
    const rd = e.dst(idx);
    try e.dp(switch (i.op) {
        .add => 0x0B000000,
        .sub => 0x4B000000,
        .mul => 0x1B007C00,
        .@"and" => 0x0A000000,
        .@"or" => 0x2A000000,
        .xor => 0x4A000000,
        .andn => 0x0A200000,
        .udiv => 0x1AC00800,
        else => unreachable,
    }, sf, rd, a, bb);
    if (W < 32 and (i.op == .add or i.op == .sub or i.op == .mul)) try e.zx(rd, rd, W);
    try e.finish(idx, rd);
}

fn shiftOp(e: *E, idx: usize) EmitError!void {
    const r = e.r;
    const i = r.insts.items[idx];
    const W = i.ty.bits();
    const sf = W > 32;
    var a = try e.src(i.a, S0);
    var amt = try e.src(i.b, S1);
    const rd = e.dst(idx);
    if (i.op == .rol) {
        try e.dp(0x4B000000, sf, IP0, ZR, amt); // neg
        amt = IP0;
    }
    if (W < 32) {
        try e.logImm(0, false, IP0, amt, 0, std.math.log2_int(u32, W)); // amount mod W
        amt = IP0;
        switch (i.op) {
            .ashr => {
                try e.sbfm(false, IP1, a, 0, W - 1);
                a = IP1;
            },
            .ror, .rol => {
                // Replicate the value across 32 bits; a 32-bit rotate
                // by less than W then rotates it at W.
                try e.dpShift(0x2A000000, false, IP1, a, a, 0, W);
                if (W == 8) try e.dpShift(0x2A000000, false, IP1, IP1, IP1, 0, 16);
                a = IP1;
            },
            else => {},
        }
    }
    try e.dp(switch (i.op) {
        .shl => 0x1AC02000,
        .lshr => 0x1AC02400,
        .ashr => 0x1AC02800,
        .ror, .rol => 0x1AC02C00,
        else => unreachable,
    }, sf, rd, a, amt);
    if (W < 32 and i.op != .lshr) try e.zx(rd, rd, W);
    try e.finish(idx, rd);
}

/// An EFLAGS producer: its flags into NZCV (operands shifted to the top of
/// a 32-bit register, so N Z C V are the narrow operation's), and, unless
/// it's virtual, the packed EFLAGS value.
fn eflagsOp(e: *E, idx: usize) !void {
    const i = e.r.insts.items[idx];
    if (fallsBack(i.op)) return fallback(e, idx);
    if (e.d[idx].virtual) return eflagsCore(e, idx, null);
    const rd = e.dst(idx);
    try eflagsCore(e, idx, rd);
    try e.finish(idx, rd);
}

/// An EFLAGS producer's flags into NZCV and, given `rd`, packed into rd.
fn eflagsCore(e: *E, idx: usize, rd_: ?u5) !void {
    const i = e.r.insts.items[idx];
    const ta = e.r.insts.items[i.a].ty;
    const W = ta.bits();
    const s: u32 = 32 - W;
    const a = try e.src(i.a, S0);
    var bb: u5 = ZR;
    const kind = eflagsKind(i.op).?;
    switch (i.op) {
        .@"eflags.add", .@"eflags.sub" => bb = try e.src(i.b, S1),
        .@"eflags.inc", .@"eflags.dec" => {
            try e.movImm(T0, @as(u64, 1) << @intCast(s));
            bb = T0;
        },
        else => {},
    }
    var sa = a;
    if (s != 0) {
        try e.lslImm(false, IP0, a, s);
        sa = IP0;
    }
    switch (i.op) {
        .@"eflags.logic" => try e.dp(0x6A000000, false, ZR, sa, sa),
        .@"eflags.add" => try e.dpShift(0x2B000000, false, ZR, sa, bb, 0, s),
        .@"eflags.sub" => try e.dpShift(0x6B000000, false, ZR, sa, bb, 0, s),
        .@"eflags.inc" => try e.dp(0x2B000000, false, ZR, sa, bb),
        .@"eflags.dec" => try e.dp(0x6B000000, false, ZR, sa, bb),
        else => unreachable,
    }
    const rd = rd_ orelse return;
    const borrow = kind == .sub or i.op == .@"eflags.dec";
    const t = @intFromBool(borrow);
    if (e.table_label[t] == null) e.table_label[t] = try e.label();
    try e.put(0xD53B4200 | @as(u32, IP1)); // mrs x17, nzcv
    try e.ubfx(IP1, IP1, 28, 4);
    try e.jump(.adr, 0x10000000 | @as(u32, IP0), e.table_label[t].?);
    try e.put(0x78607800 | @as(u32, IP1) << 16 | @as(u32, IP0) << 5 | @as(u32, rd)); // ldrh rd, [x16, x17, lsl #1]
    // The low byte of the result, for PF (and with the operands, AF).
    const res = IP1;
    switch (i.op) {
        .@"eflags.logic" => try e.mov(res, a),
        .@"eflags.add" => try e.dp(0x0B000000, false, res, a, bb),
        .@"eflags.sub" => try e.dp(0x4B000000, false, res, a, bb),
        .@"eflags.inc" => try e.put(0x11000400 | @as(u32, a) << 5 | @as(u32, res)),
        .@"eflags.dec" => try e.put(0x51000400 | @as(u32, a) << 5 | @as(u32, res)),
        else => unreachable,
    }
    if (kind != .logic) {
        if (bb == T0) {
            try e.dp(0x4A000000, false, IP0, a, res); // a ^ res (b is 1, which leaves bit 4 alone)
        } else {
            try e.dp(0x4A000000, false, IP0, a, bb);
            try e.dp(0x4A000000, false, IP0, IP0, res);
        }
        try e.logImm(0, false, IP0, IP0, 4, 1);
        try e.dp(0x2A000000, false, rd, rd, IP0); // AF
    }
    try e.dpShift(0x4A000000, false, res, res, res, 1, 4);
    try e.dpShift(0x4A000000, false, res, res, res, 1, 2);
    try e.dpShift(0x4A000000, false, res, res, res, 1, 1);
    try e.logImm(2, false, res, res, 0, 1); // even parity
    try e.bfi(rd, res, 2, 1); // PF
    if (kind == .incdec) {
        const cf = try e.src(i.b, S1);
        try e.bfi(rd, cf, 0, 1);
    }
}

/// The FP and vector ops, and v128 getreg and setreg. v128 values live in
/// pairs of frame slots; v.load and v.store are inline, and every other op
/// calls ir_eval.evalExtC for now (copy.zig will lower FP and AdvSIMD).
fn lowerExt(e: *E, idx: usize) !void {
    const i = e.r.insts.items[idx];
    const ta: Type = if (i.a != ir.none) e.r.insts.items[i.a].ty else .none;
    switch (i.op) {
        .getreg => {
            if (i.ty != .v128) return error.Unsupported;
            if (vchunkFor(e, i.aux, 16)) |vc| return vGetSet(e, false, vc.q, vc.base, i.aux, 16, @intCast(idx), 0);
            const k = e.p.locs[idx].slot;
            try e.ldst(false, 3, S0, CPU, i.aux);
            try e.ldst(false, 3, S1, CPU, i.aux + 8);
            try e.strSlot(S0, k);
            try e.strSlot(S1, k + 1);
        },
        .setreg => {
            if (ta != .v128) return error.Unsupported;
            if (vchunkFor(e, i.aux, 16)) |vc| return vGetSet(e, true, vc.q, vc.base, i.aux, 16, i.a, 0);
            const k = e.p.locs[i.a].slot;
            try e.ldrSlot(S0, k);
            try e.ldrSlot(S1, k + 1);
            try e.ldst(true, 3, S0, CPU, i.aux);
            try e.ldst(true, 3, S1, CPU, i.aux + 8);
        },
        .@"v.load", .@"v.store" => try vmemOp(e, idx),
        else => {
            if (!i.op.isExt()) return error.Unsupported;
            if (try vecNative(e, idx)) return;
            if (try fpNative(e, idx)) return;
            try extFallback(e, idx);
        },
    }
}

/// io[0..48] = a, b, c; evalExtC(ctx, code, io, aux, aux2); result = io[0..16].
fn extFallback(e: *E, idx: usize) !void {
    const i = e.r.insts.items[idx];
    const ta: Type = if (i.a != ir.none) e.r.insts.items[i.a].ty else .none;
    const io = e.saveArea(io_save);
    for ([3]Ref{ i.a, i.b, i.c }, 0..) |v, k| {
        const at = io + 2 * @as(u32, @intCast(k));
        if (v == ir.none) {
            try e.strSlot(ZR, at);
            try e.strSlot(ZR, at + 1);
        } else if (e.r.insts.items[v].ty == .v128) {
            const sl = e.p.locs[v].slot;
            try e.ldrSlot(S0, sl);
            try e.strSlot(S0, at);
            try e.ldrSlot(S0, sl + 1);
            try e.strSlot(S0, at + 1);
        } else {
            try e.strSlot(try e.src(v, S0), at);
            try e.strSlot(ZR, at + 1);
        }
    }
    const save = e.saveMask(idx, true);
    try e.saveRegs(save);
    try e.mov(0, CTX);
    try e.movImm(1, ir_eval.fallbackCode(i.op, i.ty, ta));
    try e.movImm(IP0, @as(u64, io) * 8);
    try e.put(0x8B206000 | @as(u32, IP0) << 16 | @as(u32, SP) << 5 | 2); // add x2, sp, x16
    try e.movImm(3, i.aux);
    try e.movImm(4, i.aux2);
    try e.movImm(IP0, @intFromPtr(&ir_eval.evalExtC));
    try e.callOut(IP0);
    try e.restoreRegs(save);
    if (i.ty == .v128) {
        const sl = e.p.locs[idx].slot;
        try e.ldrSlot(S0, io);
        try e.strSlot(S0, sl);
        try e.ldrSlot(S0, io + 1);
        try e.strSlot(S0, sl + 1);
    } else if (i.ty != .none) {
        try e.ldrSlot(SD, io);
        try e.finish(idx, SD);
    }
}

// ---------------------------------------------------------------- x86's FP and vectors

const LO: Cond = 3;
const MI: Cond = 4;
const HI: Cond = 8;
const GT: Cond = 12;

/// The 128-bit ops that are two 64-bit halves (v.and, v.or, v.xor, v.andn),
/// v.make, and v.lane of a word or doubleword, on the values' slot pairs.
/// Returns false, emitting nothing, for the rest.
fn vecNative(e: *E, idx: usize) !bool {
    const i = e.r.insts.items[idx];
    const x = ir.ExtAux.of(i.aux);
    switch (i.op) {
        .@"v.make" => {
            const k = e.p.locs[idx].slot;
            try e.strSlot(try e.src(i.a, S0), k);
            try e.strSlot(try e.src(i.b, S1), k + 1);
        },
        .@"v.and", .@"v.or", .@"v.xor", .@"v.andn" => {
            const base: u32 = switch (i.op) {
                .@"v.and" => 0x8A000000,
                .@"v.or" => 0xAA000000,
                .@"v.xor" => 0xCA000000,
                .@"v.andn" => 0x8A200000, // bic
                else => unreachable,
            };
            const ka = e.p.locs[i.a].slot;
            const kb = e.p.locs[i.b].slot;
            const kd = e.p.locs[idx].slot;
            for (0..2) |h| {
                try e.ldrSlot(S0, ka + @as(u32, @intCast(h)));
                try e.ldrSlot(S1, kb + @as(u32, @intCast(h)));
                try e.put(base | @as(u32, S1) << 16 | @as(u32, S0) << 5 | S0);
                try e.strSlot(S0, kd + @as(u32, @intCast(h)));
            }
        },
        .@"v.lane" => {
            if (x.esize < 2) return false;
            const k = e.p.locs[i.a].slot;
            const off = @as(u64, k) * 8 + @as(u64, x.imm) * (x.bits() / 8);
            try e.ldst(false, @intCast(x.esize), T0, SP, off);
            try e.finish(idx, T0);
        },
        else => return false,
    }
    return true;
}

/// Branches to `slow` if the `w`-bit FP value in `r` is (with `tiny`) a
/// zero-exponent or smallest-exponent nonzero, (with `nan`) a NaN, or
/// (with `den`) a denormal.
fn fpClass(e: *E, r: u5, w: u32, den: bool, tiny: bool, nan: bool, slow: u32) !void {
    const sf = w == 64;
    const mant: u6 = if (sf) 52 else 23;
    try e.lslImm(sf, IP1, r, 1); // the sign gone
    if (nan) {
        // Above the infinities' exponent with a zero fraction.
        const inf: u64 = (if (sf) @as(u64, 0x7ff) else 0xff) << (mant + 1);
        try e.movImm(IP0, inf);
        try e.dp(0x6B000000, sf, ZR, IP1, IP0); // cmp
        try e.bcond(HI, slow);
    }
    if (den or tiny) {
        try e.put((if (sf) @as(u32, 0xD1000400) else 0x51000400) | @as(u32, IP1) << 5 | IP1); // sub #1: a zero wraps
        const lim: u64 = (@as(u64, if (tiny) 2 else 1) << (mant + 1)) - 1;
        try e.movImm(IP0, lim);
        try e.dp(0x6B000000, sf, ZR, IP1, IP0);
        try e.bcond(LO, slow);
    }
}

/// x86's scalar FP natively, under the host's FPCR (round to nearest, no
/// FZ, no DN), where arm64's result and flags are x86's: no denormal
/// operand (x86's DE), no NaN result (the NaNs it picks differ), no tiny
/// result (tininess is before rounding here, after on x86), and no
/// invalid or underflow. Then FPSR's DZC, OFC, and IXC are x86's ZE, OE,
/// and PE one bit up. Otherwise ir_eval runs it, after. Returns false,
/// emitting nothing, for an op or form it doesn't do.
fn fpNative(e: *E, idx: usize) !bool {
    const i = e.r.insts.items[idx];
    if (!i.op.isFp() or i.ty == .v128) return false;
    const x = ir.ExtAux.of(i.aux);
    if (x.arm or x.daz or x.ftz) return false;
    const ta = e.r.insts.items[i.a].ty;
    // The FP operand's width, and its FP register type bit (22: double).
    const fw: u32 = switch (i.op) {
        .@"fp.fromsint" => if (x.imm != 0 or (ta != .i32 and ta != .i64)) return false else i.ty.bits(),
        .@"fp.tosint" => if (x.imm != 0 or (x.rounding != 0 and x.rounding != 3)) return false else ta.bits(),
        else => if (x.rounding != 0) return false else ta.bits(),
    };
    if (fw != 32 and fw != 64) return false;
    if (i.ty != .i8 and i.ty != .i32 and i.ty != .i64) return false;
    const dbl: u32 = if (fw == 64) 1 << 22 else 0;
    switch (i.op) {
        .@"fp.add", .@"fp.sub", .@"fp.mul", .@"fp.div", .@"fp.sqrt", .@"fp.min", .@"fp.max", .@"fp.cmp", .@"fp.fromsint", .@"fp.tosint" => {},
        .@"fp.cvt" => if (ta.bits() == i.ty.bits() or (ta != .i32 and ta != .i64)) return false,
        else => return false,
    }
    const slow = try e.label();
    const done = try e.label();
    const a = try e.src(i.a, S0);
    const b: u5 = if (i.b != ir.none) try e.src(i.b, S1) else ZR;
    const sfa = ta == .i64;
    // fmov to d0/s0 and d1/s1 (fp.fromsint takes a general register).
    if (i.op != .@"fp.fromsint") {
        try e.put((if (sfa) @as(u32, 0x9E670000) else 0x1E270000) | @as(u32, a) << 5 | 0);
        if (i.b != ir.none) try e.put((if (sfa) @as(u32, 0x9E670000) else 0x1E270000) | @as(u32, b) << 5 | 1);
        try fpClass(e, a, fw, true, false, i.op == .@"fp.cmp" or i.op == .@"fp.min" or i.op == .@"fp.max" or i.op == .@"fp.cvt", slow);
        if (i.b != ir.none) try fpClass(e, b, fw, true, false, i.op == .@"fp.cmp" or i.op == .@"fp.min" or i.op == .@"fp.max", slow);
    }
    try e.put(0xD51B4420 | @as(u32, ZR)); // msr fpsr, xzr
    const rw: u32 = i.ty.bits();
    switch (i.op) {
        .@"fp.add", .@"fp.sub", .@"fp.mul", .@"fp.div" => {
            const base: u32 = switch (i.op) {
                .@"fp.add" => 0x1E202800,
                .@"fp.sub" => 0x1E203800,
                .@"fp.mul" => 0x1E200800,
                .@"fp.div" => 0x1E201800,
                else => unreachable,
            };
            try e.put(base | dbl | 1 << 16 | 0 << 5 | 2);
        },
        .@"fp.sqrt" => try e.put(0x1E21C000 | dbl | 0 << 5 | 2),
        .@"fp.min", .@"fp.max" => {
            // a < b ? a : b, and a > b ? a : b: b for unordered or equal.
            try e.put(0x1E202000 | dbl | 1 << 16 | 0 << 5); // fcmp s0/d0, s1/d1
            try e.put(0x1E200C00 | dbl | 1 << 16 | @as(u32, if (i.op == .@"fp.min") MI else GT) << 12 | 0 << 5 | 2);
        },
        .@"fp.cmp" => {
            // An Order: lt 0, eq 1, gt 2 (no NaN gets here).
            try e.put(0x1E202000 | dbl | 1 << 16 | 0 << 5);
            try e.movImm(T0, 2);
            try e.movImm(IP0, 1);
            try e.put(0x9A800000 | @as(u32, T0) << 16 | @as(u32, EQ) << 12 | @as(u32, IP0) << 5 | T0); // csel x13, x16, x13, eq
            try e.put(0x9A800000 | @as(u32, T0) << 16 | @as(u32, MI) << 12 | @as(u32, ZR) << 5 | T0); // csel x13, xzr, x13, mi
        },
        .@"fp.cvt" => try e.put(if (fw == 64) @as(u32, 0x1E624000) | 0 << 5 | 2 else 0x1E22C000 | 0 << 5 | 2),
        .@"fp.fromsint" => {
            // scvtf s2/d2 from w/x.
            const base: u32 = if (sfa) 0x9E220000 else 0x1E220000;
            try e.put(base | dbl | @as(u32, a) << 5 | 2);
        },
        .@"fp.tosint" => {
            // fcvtzs or fcvtns to w/x.
            const base: u32 = if (x.rounding == 3) 0x1E380000 else 0x1E200000;
            try e.put(base | (if (rw == 64) @as(u32, 1) << 31 else 0) | dbl | 0 << 5 | T0);
        },
        else => unreachable,
    }
    // The result to T0, and its check.
    switch (i.op) {
        .@"fp.cmp", .@"fp.tosint" => {},
        else => {
            const sfr = rw == 64;
            try e.put((if (sfr) @as(u32, 0x9E660000) else 0x1E260000) | 2 << 5 | T0);
            if (i.op != .@"fp.min" and i.op != .@"fp.max" and i.op != .@"fp.fromsint")
                try fpClass(e, T0, rw, false, true, true, slow);
        },
    }
    try e.put(0xD53B4420 | @as(u32, IP0)); // mrs x16, fpsr
    // Invalid (fp.tosint's NaN or out of range: x86's indefinite), and
    // underflow (a tiny result that rounded to zero, which the result's
    // check doesn't see).
    try e.logImm(3, false, ZR, IP0, 0, 1); // tst w16, #1 (IOC)
    try e.bcond(NE, slow);
    try e.logImm(3, false, ZR, IP0, 3, 1); // tst w16, #8 (UFC)
    try e.bcond(NE, slow);
    if (i.aux2 != 0) {
        // DZC (1), OFC (2), IXC (4) to ZE (2), OE (3), PE (5).
        try e.movImm(IP1, 0x16);
        try e.dp(0x0A000000, false, IP0, IP0, IP1);
        try e.lslImm(false, IP0, IP0, 1);
        const skip = try e.label();
        try e.cbz(false, IP0, skip);
        try e.ldst(false, 2, S2, CPU, i.aux2 - 1);
        try e.dp(0x2A000000, false, S2, S2, IP0);
        try e.ldst(true, 2, S2, CPU, i.aux2 - 1);
        e.bind(skip);
    }
    try e.finish(idx, T0);
    try e.b(done);
    e.bind(slow);
    try extFallback(e, idx);
    e.bind(done);
    return true;
}

/// eflags.shl, shr, and mul, materialized: SF ZF PF from b, and CF and OF
/// (AF is 0).
fn shiftMulFlags(e: *E, idx: usize) !void {
    const i = e.r.insts.items[idx];
    const W: u32 = e.r.insts.items[i.a].ty.bits();
    const a = try e.src(i.a, S0);
    const b = try e.src(i.b, S1);
    const rd = T0;
    try e.movImm(rd, 0);
    // SF
    try e.ubfx(IP0, b, W - 1, 1);
    try e.bfi(rd, IP0, 7, 1);
    // ZF
    try e.dp(0xEB000000, true, ZR, b, ZR); // cmp b, #0 (b is zero-extended)
    try e.cset(IP0, EQ);
    try e.bfi(rd, IP0, 6, 1);
    // PF: even parity of the low byte.
    try e.mov(IP1, b);
    try e.dpShift(0x4A000000, false, IP1, IP1, IP1, 1, 4);
    try e.dpShift(0x4A000000, false, IP1, IP1, IP1, 1, 2);
    try e.dpShift(0x4A000000, false, IP1, IP1, IP1, 1, 1);
    try e.logImm(2, false, IP1, IP1, 0, 1);
    try e.bfi(rd, IP1, 2, 1);
    switch (i.op) {
        .@"eflags.mul" => {
            // CF = OF = (a != 0): a is the overflow, not just its bit 0.
            try e.dp(0xEB000000, true, ZR, a, ZR); // cmp a, #0
            try e.cset(IP0, NE);
            try e.bfi(rd, IP0, 0, 1);
            try e.bfi(rd, IP0, 11, 1);
        },
        else => {
            // CF: shl's msb(a), shr's a & 1. OF: msb(a ^ b).
            if (i.op == .@"eflags.shl") {
                try e.ubfx(IP0, a, W - 1, 1);
                try e.bfi(rd, IP0, 0, 1);
            } else try e.bfi(rd, a, 0, 1);
            try e.dp(0xCA000000, true, IP0, a, b);
            try e.ubfx(IP0, IP0, W - 1, 1);
            try e.bfi(rd, IP0, 11, 1);
        },
    }
    try e.finish(idx, rd);
}

/// A 16-byte load or store through the TLB.
fn vmemOp(e: *E, idx: usize) !void {
    const i = e.r.insts.items[idx];
    const f: ir.MemFlags = @bitCast(i.aux);
    const store = i.op == .@"v.store";
    const tso = e.r.tso and tsoOn();
    const va = try e.src(i.a, S0);
    const slot = e.p.locs[if (store) i.b else idx].slot;
    if (f.aligned) {
        const l = try e.label();
        try e.stubs.append(e.gpa, .{ .misaligned = .{ .label = l, .va = va, .acc = if (store) .write else .read, .dirty = e.dirty, .pc = i.aux2, .retired = i.retired, .pend = e.pend } });
        try e.logImm(0, true, IP0, va, 0, 4);
        try e.cbnz(true, IP0, l);
    }
    if (store) {
        try e.ldrSlot(S1, slot);
        try e.ldrSlot(S2, slot + 1);
        if (tso or f.order != .plain) try e.put(0xD5033BBF); // dmb ish
    }
    try e.put(0x91000000 | 15 << 10 | @as(u32, va) << 5 | T0); // add x13, va, #15
    try e.ubfx(IP0, va, 12, 8);
    try e.dpShift(0x0B000000, true, IP0, if (store) TLBW else TLBR, IP0, 0, 4);
    try e.put(0xA9400000 | @as(u32, IP0) << 10 | @as(u32, IP0) << 5 | IP1); // ldp x17, x16, [x16]
    try e.dpShift(0x4A000000, true, IP1, IP1, T0, 1, 12);
    const slow = try e.label();
    const join = try e.label();
    try e.cbnz(true, IP1, slow);
    try e.dp(0x0B000000, true, IP0, va, IP0); // host address
    if (store) {
        try e.put(0xA9000000 | @as(u32, S2) << 10 | @as(u32, IP0) << 5 | S1); // stp x10, x11, [x16]
    } else {
        try e.put(0xA9400000 | @as(u32, S2) << 10 | @as(u32, IP0) << 5 | S1); // ldp x10, x11, [x16]
        try e.strSlot(S1, slot);
        try e.strSlot(S2, slot + 1);
    }
    e.bind(join);
    if (!store and (tso or f.order != .plain)) try e.put(0xD50339BF); // dmb ishld
    try e.stubs.append(e.gpa, .{ .vslow = .{
        .label = slow,
        .back = join,
        .store = store,
        .va = va,
        .slot = slot,
        .save = e.saveMask(idx, true),
        .dirty = e.dirty,
        .pc = i.aux2,
        .retired = i.retired,
        .tso = tso,
        .pend = e.pend,
    } });
}

/// A guest arm64 instruction run as itself (ir.zig, Op.copy), its register
/// fields rewritten to the host registers holding the guest's: a pinned
/// chunk's register, or a scratch register (x9-x11, x13; v0-v3) loaded
/// from the Cpu and stored back. Guest NZCV goes through host NZCV. An FP or
/// saturating one runs under the guest's FPCR, its exceptions (and QC) ORed
/// into the guest's FPSR, and the host's FPCR put back.
fn copyOp(e: *E, idx: usize) !void {
    const i = e.r.insts.items[idx];
    if (regalloc.isCall(i)) {
        try e.writeback(e.dirty);
        e.dirty = 0;
        const save = e.saveMask(idx, false);
        try e.saveRegs(save);
        if (e.fp) try fpLeave(e);
        if (e.lazy_retire) try e.retireOn(0);
        try e.mov(0, CTX);
        try e.movImm(1, i.aux & 0xffff_ffff);
        try e.movImm(2, 0);
        try e.ldrCtx(IP0, ctx.off.interp);
        try e.callInterp(IP0);
        try e.cbnz(false, 0, e.epilogue);
        try e.restoreRegs(save);
        if (e.fp) try fpEnter(e, false);
        return e.loadChunks();
    }
    const fields = regalloc.copyFields(i.aux2);
    const scratch_x = [4]u5{ S0, S1, S2, T0 };
    var regs: [4]u5 = undefined;
    var nx: usize = 0;
    var nv: u5 = 0;
    var word: u32 = @truncate(i.aux);
    const pos = [4]u5{ 0, 5, 16, 10 };
    for (fields, 0..) |fo, k| {
        const f = fo orelse continue;
        // The same register in two fields gets one host register.
        var reg: ?u5 = null;
        for (fields[0..k], 0..) |go, j| if (go) |g| if (g.off == f.off and g.vec == f.vec) {
            reg = regs[j];
        };
        if (reg == null) {
            // Loaded if any field naming the register reads it.
            var read = false;
            for (fields[k..]) |go| if (go) |g| if (g.off == f.off and g.vec == f.vec and g.read) {
                read = true;
            };
            if (f.vec and !(k == 2 and regalloc.byElementH(@truncate(i.aux))) and e.vchunkOf(f.off) != null) {
                reg = e.vchunkOf(f.off).?;
            } else if (f.vec) {
                // v0-v3: under 16, for the by-element forms' 4-bit Rm.
                reg = nv;
                nv += 1;
                if (read) try vldst(e, false, reg.?, f.off);
            } else if (exactChunk(e, f.off, 8)) |c| {
                reg = c;
            } else {
                reg = scratch_x[nx];
                nx += 1;
                if (read) try readGuest(e, f.off, 8, reg.?);
            }
        }
        regs[k] = reg.?;
        var field: u32 = reg.?;
        if (f.vec and k == 2 and regalloc.byElementH(@truncate(i.aux))) {
            // A by-element op with H lanes has a 4-bit Rm and its index's M
            // bit in bit 20; scratch V registers are under 16.
            field |= (word >> 16) & 16;
        }
        word = (word & ~(@as(u32, 31) << pos[k])) | field << pos[k];
    }
    const nz = host.guest_nzcv.?;
    if (i.aux & regalloc.copy_reads_nzcv != 0) {
        try readGuest(e, nz, 4, IP0);
        try e.put(0xD51B4200 | @as(u32, IP0)); // msr nzcv, x16
    }
    try e.put(word);
    if (i.aux & regalloc.copy_writes_nzcv != 0) {
        try e.put(0xD53B4200 | @as(u32, IP0)); // mrs x16, nzcv
        try writeGuest(e, nz, 4, IP0);
    }

    for (fields, 0..) |fo, k| {
        const f = fo orelse continue;
        if (!f.write) continue;
        var dup = false;
        for (fields[0..k]) |go| if (go) |g| if (g.write and g.off == f.off and g.vec == f.vec) {
            dup = true;
        };
        if (dup) continue;
        if (f.vec) {
            if (regs[k] < 16) try vldst(e, true, regs[k], f.off);
        } else try writeGuest(e, f.off, 8, regs[k]);
    }
}


/// Moves the exceptions host FPSR collected into the guest's FPSR, and
/// clears it. Uses x16, x17.
fn fpFlush(e: *E) !void {
    const done = try e.label();
    try e.put(0xD53B4420 | @as(u32, IP0)); // mrs x16, fpsr
    try e.cbz(true, IP0, done);
    try e.ldst(false, 2, IP1, CPU, host.guest_fpsr.?);
    try e.dp(0x2A000000, false, IP1, IP1, IP0);
    try e.ldst(true, 2, IP1, CPU, host.guest_fpsr.?);
    try e.put(0xD51B4420 | @as(u32, ZR)); // msr fpsr, xzr
    e.bind(done);
}

/// Leaving an FP region, or calling out of it: FPSR flushed, and the host's
/// FPCR back. Uses x16, x17 and NZCV; needs the frame.
fn fpLeave(e: *E) !void {
    try fpFlush(e);
    const same = try e.label();
    try e.ldrSlot(IP0, e.saveArea(fpcr_save));
    try e.put(0xD53B4400 | @as(u32, IP1)); // mrs x17, fpcr
    try e.dp(0x6B000000, true, ZR, IP0, IP1);
    try e.bcond(EQ, same);
    try e.put(0xD51B4400 | @as(u32, IP0)); // msr fpcr, x16
    e.bind(same);
}

/// Entering an FP region (at its chain entry, `entry`), or back from a call:
/// the guest's FPCR, written only if it differs, since MSR FPCR is slow.
fn fpEnter(e: *E, entry: bool) !void {
    const same = try e.label();
    try e.put(0xD53B4400 | @as(u32, IP0)); // mrs x16, fpcr
    if (entry) {
        try e.strSlot(IP0, e.saveArea(fpcr_save));
        // Whatever the host left in FPSR isn't the guest's.
        const clear = try e.label();
        try e.put(0xD53B4420 | @as(u32, IP1)); // mrs x17, fpsr
        try e.cbz(true, IP1, clear);
        try e.put(0xD51B4420 | @as(u32, ZR)); // msr fpsr, xzr
        e.bind(clear);
    }
    try e.ldst(false, 2, IP1, CPU, host.guest_fpcr.?);
    try e.dp(0x6B000000, true, ZR, IP0, IP1);
    try e.bcond(EQ, same);
    try e.put(0xD51B4400 | @as(u32, IP1)); // msr fpcr, x17
    e.bind(same);
}

/// Picks the guest V registers only (non-interp) copies touch, up to 16,
/// to keep in host v16 and up.
fn pickVchunks(e: *E) void {
    const r = e.r;
    var offs: [64]u32 = undefined;
    var n: usize = 0;
    var bad: [64]bool = @splat(false);
    for (r.insts.items) |i| {
        if (i.op != .copy or regalloc.isCall(i)) continue;
        for (regalloc.copyFields(i.aux2), 0..) |fo, k| if (fo) |f| if (f.vec) {
            const idx = for (offs[0..n], 0..) |o, j| {
                if (o == f.off) break j;
            } else blk: {
                if (n == offs.len) break :blk null;
                offs[n] = f.off;
                n += 1;
                break :blk n - 1;
            };
            // A by-element H op's Rm needs a register under 16.
            if (idx) |j| if (k == 2 and regalloc.byElementH(@truncate(i.aux))) {
                bad[j] = true;
            };
        };
    }
    // Anything else touching a V register's bytes keeps it in the Cpu, but
    // a getreg or setreg of its whole, or of a 64- or 32-bit lane.
    for (r.insts.items) |i| {
        const range: ?[2]u64 = switch (i.op) {
            .getreg => .{ i.aux, i.aux + @max(i.ty.bits() / 8, 1) },
            .setreg => .{ i.aux, i.aux + @max(r.insts.items[i.a].ty.bits() / 8, 1) },
            .@"pending.flags" => .{ i.aux, i.aux + 4 },
            else => null,
        };
        const rg = range orelse continue;
        for (offs[0..n], 0..) |o, j| if (rg[0] < o + 16 and o < rg[1]) {
            if (!(i.op != .@"pending.flags" and vLane(o, rg[0], rg[1] - rg[0]))) bad[j] = true;
        };
    }
    for (offs[0..n], 0..) |o, j| {
        if (bad[j] or e.nv == max_vchunks) continue;
        e.vchunks[e.nv] = o;
        e.nv += 1;
    }
    // Which of them copies and setregs write.
    for (r.insts.items) |i| {
        if (i.op == .setreg) for (e.vchunks[0..e.nv], 0..) |o, k| if (i.aux >= o and i.aux < o + 16) {
            e.vwritten |= @as(u16, 1) << @intCast(k);
        };
        if (i.op != .copy or regalloc.isCall(i)) continue;
        for (regalloc.copyFields(i.aux2)) |fo| if (fo) |f| if (f.vec and f.write) {
            for (e.vchunks[0..e.nv], 0..) |o, k| if (o == f.off) {
                e.vwritten |= @as(u16, 1) << @intCast(k);
            };
        };
    }
}

/// Whether `bytes` at `at` is all of the V register at `o`, or one of its
/// 64- or 32-bit lanes.
fn vLane(o: u64, at: u64, bytes: u64) bool {
    return switch (bytes) {
        16 => at == o,
        8, 4 => (at - o) % bytes == 0,
        else => false,
    };
}

/// getreg or setreg of a pinned V register (or a lane): `reg` is the GPR
/// side for a lane; a whole one goes through value `v`'s slot pair.
fn vGetSet(e: *E, set: bool, q: u5, base: u64, at: u64, bytes: u32, v: Ref, reg: u5) !void {
    if (bytes == 16) {
        const slot = e.p.locs[v].slot;
        try e.movImm(IP1, slot * 8);
        try e.dp(0x8B206000, true, IP1, SP, IP1); // add x17, sp, x17
        try e.put((if (set) @as(u32, 0x3DC00000) else 0x3D800000) | @as(u32, IP1) << 5 | q); // ldr/str q
        return;
    }
    const lane: u32 = @intCast((at - base) / bytes);
    const imm5: u32 = if (bytes == 8) (lane << 4) | 0b01000 else (lane << 3) | 0b00100;
    if (set) {
        try e.put(0x4E001C00 | imm5 << 16 | @as(u32, reg) << 5 | q); // ins vq.ts[lane], reg
    } else {
        try e.put((if (bytes == 8) @as(u32, 0x4E003C00) else 0x0E003C00) | imm5 << 16 | @as(u32, q) << 5 | reg); // umov reg, vq.ts[lane]
    }
}

/// The pinned V register holding Cpu bytes [at, at + bytes), and its base.
fn vchunkFor(e: *E, at: u64, bytes: u64) ?struct { q: u5, base: u64 } {
    for (e.vchunks[0..e.nv], 0..) |o, k| if (at >= o and at + bytes <= o + 16) return .{ .q = @intCast(16 + k), .base = o };
    return null;
}

/// The register of the chunk that is exactly `bytes` bytes at `off`.
fn exactChunk(e: *E, off: u64, bytes: u64) ?u5 {
    const k = e.p.chunkAt(off, bytes) orelse return null;
    const c = e.p.chunks[k];
    return if (c.off == off and c.bytes == bytes) @intCast(c.reg) else null;
}

/// rd = the guest's `bytes` bytes at Cpu offset `off`, from its chunk or
/// the Cpu.
fn readGuest(e: *E, off: u64, bytes: u32, rd: u5) !void {
    if (e.p.chunkAt(off, bytes)) |k| {
        const c = e.p.chunks[k];
        if (c.bytes == bytes) return e.mov(rd, @intCast(c.reg));
        return e.ubfx(rd, @intCast(c.reg), @intCast((off - c.off) * 8), bytes * 8);
    }
    try e.ldst(false, @intCast(std.math.log2_int(u32, bytes)), rd, CPU, off);
}

/// The guest's `bytes` bytes at Cpu offset `off` = rs's low bytes.
fn writeGuest(e: *E, off: u64, bytes: u32, rs: u5) !void {
    if (e.p.chunkAt(off, bytes)) |k| {
        const c = e.p.chunks[k];
        if (c.bytes == bytes) try e.mov(@intCast(c.reg), rs) else try e.bfi(@intCast(c.reg), rs, @intCast((off - c.off) * 8), bytes * 8);
        e.dirty |= @as(regalloc.ChunkSet, 1) << @intCast(k);
        return;
    }
    try e.ldst(true, @intCast(std.math.log2_int(u32, bytes)), rs, CPU, off);
}

/// LDR or STR Qt, [Cpu + off].
fn vldst(e: *E, store: bool, qt: u5, off: u64) !void {
    try e.movImm(IP1, off);
    try e.dp(0x0B000000, true, IP1, CPU, IP1);
    try e.put((if (store) @as(u32, 0x3D800000) else 0x3DC00000) | @as(u32, IP1) << 5 | qt);
}

/// H9_TSO=off ignores Region.tso: for measuring what TSO costs, never
/// for running guests (x86 programs can then see reorderings).
fn tsoOn() bool {
    const S = struct {
        var known: std.atomic.Value(u8) = .init(0);
    };
    switch (S.known.load(.monotonic)) {
        1 => return false,
        2 => return true,
        else => {},
    }
    // Only where libc is linked (h9 itself; not the vcpu unit tests).
    if (!builtin.link_libc) return true;
    const getenv = @extern(*const fn ([*:0]const u8) callconv(.c) ?[*:0]const u8, .{ .name = "getenv" });
    const off = if (getenv("H9_TSO")) |v| std.mem.eql(u8, std.mem.span(v), "off") else false;
    S.known.store(if (off) 1 else 2, .monotonic);
    return !off;
}

/// Whether the host has FEAT_LRCPC (LDAPR): every Apple core does, and
/// Linux reports it in AT_HWCAP. Tests and benchmarks can turn it off.
pub var use_lrcpc: bool = true;
var lrcpc_known: std.atomic.Value(u8) = .init(0); // 0 unknown, 1 no, 2 yes

fn hasLrcpc() bool {
    if (!use_lrcpc) return false;
    switch (lrcpc_known.load(.monotonic)) {
        1 => return false,
        2 => return true,
        else => {},
    }
    const yes = builtin.cpu.arch == .aarch64 and switch (builtin.os.tag) {
        .macos, .ios => blk: {
            const sysctlbyname = @extern(*const fn ([*:0]const u8, ?*anyopaque, ?*usize, ?*anyopaque, usize) callconv(.c) c_int, .{ .name = "sysctlbyname" });
            var v: u32 = 0;
            var len: usize = @sizeOf(u32);
            break :blk sysctlbyname("hw.optional.arm.FEAT_LRCPC", &v, &len, null, 0) == 0 and v != 0;
        },
        .linux => std.os.linux.getauxval(std.elf.AT_HWCAP) & (1 << 15) != 0,
        else => false,
    };
    lrcpc_known.store(if (yes) 2 else 1, .monotonic);
    return yes;
}

/// cas through the runtime's slow_cas (an inline host CAS behind the TLB
/// check is for later).
fn casOp(e: *E, idx: usize) !void {
    const i = e.r.insts.items[idx];
    const f: ir.MemFlags = @bitCast(i.aux);
    const args = [3]Ref{ i.a, i.b, i.c };
    const scr = [3]u5{ S0, S1, S2 };
    for (args, scr) |v, s| try e.mov(s, try e.src(v, s));
    const save = e.saveMask(idx, true);
    try e.saveRegs(save);
    try e.mov(1, S0);
    try e.mov(3, S1);
    try e.mov(4, S2);
    try e.mov(0, CTX);
    try e.movImm(2, f.size);
    try e.ldrCtx(IP0, ctx.off.slow_cas);
    try e.callOut(IP0);
    const fault = try e.label();
    try e.stubs.append(e.gpa, .{ .slow = .{
        .label = fault,
        .back = 0,
        .store = true,
        .size = 0,
        .va = 0,
        .val = 0,
        .dst = 0,
        .save = save,
        .dirty = e.dirty,
        .pc = i.aux2,
        .retired = i.retired,
        .rmw = false,
        .tso = false,
        .fault_only = true,
        .pend = e.pend,
    } });
    try e.cbnz(false, 0, fault);
    try e.ldrCtx(SD, ctx.off.scratch);
    try e.restoreRegs(save);
    try e.zx(SD, SD, i.ty.bits());
    try e.finish(idx, SD);
}

/// The result = ir_eval.evalOpC(code, a, b, c, aux).
fn fallback(e: *E, idx: usize) !void {
    const i = e.r.insts.items[idx];
    const ta: Type = if (i.a != ir.none) e.r.insts.items[i.a].ty else .none;
    const args = [3]Ref{ i.a, i.b, i.c };
    const scr = [3]u5{ S0, S1, S2 };
    for (args, scr) |v, s| if (v != ir.none) try e.mov(s, try e.src(v, s));
    const save = e.saveMask(idx, true);
    try e.saveRegs(save);
    for (args, scr, 1..) |v, s, k| if (v != ir.none) try e.mov(@intCast(k), s);
    try e.movImm(0, ir_eval.fallbackCode(i.op, i.ty, ta));
    try e.movImm(4, i.aux);
    try e.movImm(IP0, @intFromPtr(&ir_eval.evalOpC));
    try e.callOut(IP0);
    try e.mov(SD, 0);
    try e.restoreRegs(save);
    try e.finish(idx, SD);
}

/// A load or store through the TLB, with the slow path in a stub:
///
///     add  x13, va, #(size - 1)        ; the last byte, if size > 1
///     ubfx x16, va, #12, #8
///     add  x16, x21, x16, lsl #4       ; x22 for stores
///     ldp  x17, x16, [x16]             ; tag, delta
///     eor  x17, x17, x13, lsr #12      ; a page-crossing access misses
///     cbnz x17, slow
///     ldr  rd, [va, x16]
fn memOp(e: *E, idx: usize) !void {
    const i = e.r.insts.items[idx];
    const f: ir.MemFlags = @bitCast(i.aux);
    const store = i.op == .store;
    const size: u2 = @intCast(f.size);
    const n = f.bytes();
    const va = try e.src(i.a, S0);
    const val: u5 = if (store) try e.src(i.b, S1) else 0;
    const rd: u5 = if (store) 0 else e.dst(idx);

    const tso = e.r.tso and tsoOn();
    if (f.aligned and n > 1) {
        const l = try e.label();
        try e.stubs.append(e.gpa, .{ .misaligned = .{ .label = l, .va = va, .acc = if (store or f.rmw) .write else .read, .dirty = e.dirty, .pc = i.aux2, .retired = i.retired, .pend = e.pend } });
        try e.logImm(0, true, IP0, va, 0, std.math.log2_int(u32, n));
        try e.cbnz(true, IP0, l);
    }
    if (!tso and store and f.order != .plain) try e.put(0xD5033BBF); // dmb ish

    var last = va;
    if (n > 1) {
        try e.put(0x91000000 | (n - 1) << 10 | @as(u32, va) << 5 | @as(u32, T0));
        last = T0;
    }
    try e.ubfx(IP0, va, 12, 8);
    try e.dpShift(0x0B000000, true, IP0, if (store) TLBW else TLBR, IP0, 0, 4);
    try e.put(0xA9400000 | @as(u32, IP0) << 10 | @as(u32, IP0) << 5 | @as(u32, IP1)); // ldp x17, x16, [x16]
    try e.dpShift(0x4A000000, true, IP1, IP1, last, 1, 12);
    const slow = try e.label();
    const join = try e.label();
    try e.cbnz(true, IP1, slow);
    if (tso) {
        // LDAR and STLR fault on a misaligned address: those go slow.
        if (n > 1) {
            try e.logImm(0, true, IP1, va, 0, std.math.log2_int(u32, n));
            try e.cbnz(true, IP1, slow);
        }
        try e.dp(0x0B000000, true, IP0, va, IP0); // add x16, va, delta
        const sz = @as(u32, size) << 30;
        if (store) {
            try e.put(0x089FFC00 | sz | @as(u32, IP0) << 5 | val); // stlr
        } else if (hasLrcpc()) {
            try e.put(0x38BFC000 | sz | @as(u32, IP0) << 5 | rd); // ldapr: acquire is all TSO needs
        } else {
            try e.put(0x08DFFC00 | sz | @as(u32, IP0) << 5 | rd); // ldar
        }
    } else if (store) {
        try e.put(st_reg[size] | @as(u32, IP0) << 16 | @as(u32, va) << 5 | val);
    } else {
        try e.put(ld_reg[size] | @as(u32, IP0) << 16 | @as(u32, va) << 5 | rd);
    }
    e.bind(join);
    try e.stubs.append(e.gpa, .{ .slow = .{
        .label = slow,
        .back = join,
        .store = store,
        .size = size,
        .va = va,
        .val = val,
        .dst = rd,
        .save = e.saveMask(idx, true),
        .dirty = e.dirty,
        .pc = i.aux2,
        .retired = i.retired,
        .rmw = f.rmw,
        .tso = tso,
        .pend = e.pend,
    } });
    if (!tso and f.order != .plain) {
        if (!store) try e.put(0xD50339BF) // dmb ishld
        else if (f.order == .seq_cst) try e.put(0xD5033BBF);
    }
    if (!store) {
        const W = i.ty.bits();
        if (f.signed and n * 8 < W) {
            if (W == 64) try e.sbfx64(rd, rd, n * 8) else {
                try e.sbfm(false, rd, rd, 0, n * 8 - 1);
                if (W < 32) try e.zx(rd, rd, W);
            }
        }
        try e.finish(idx, rd);
    }
}

// ---------------------------------------------------------------- tests

const testexec = @import("../testexec.zig");
const cases = @import("cases.zig");

/// Emits, runs natively, and compares with ir_eval.
pub fn runCase(gpa: std.mem.Allocator, env: *cases.Env, c: cases.Case, n: usize) !void {
    var r = try cases.parse(gpa, c);
    defer r.deinit(gpa);
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(gpa);
    const out = try emitRegion(gpa, &r, &code);
        const x = try testexec.load(code.items);
    defer x.deinit();
    const want = try env.evalCase(gpa, &r, c);
    const cx = env.reset(c);
    const got = env.result(@enumFromInt(x.entry(out.entry)(cx)));
    if (!cases.same(want, got)) {
        if (cases.can_print) dumpCode(code.items);
        return cases.expectSame(n, c, want, got);
    }
}

fn dumpCode(code: []const u8) void {
    std.debug.print("code ({d} bytes):\n", .{code.len});
    var k: usize = 0;
    while (k + 4 <= code.len) : (k += 4) std.debug.print("{x:0>4}: {x:0>8}\n", .{ k, std.mem.readInt(u32, code[k..][0..4], .little) });
}

test "emitted code matches ir_eval on the shared cases" {
    if (!testexec.supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const env = try gpa.create(cases.Env);
    defer gpa.destroy(env);
    for ([_]*const fn (std.mem.Allocator) anyerror![]cases.Case{ cases.generate, cases.generateExt }) |gen| {
        const all = try gen(gpa);
        defer cases.free(gpa, all);
        for (all, 0..) |c, n| try runCase(gpa, env, c, n);
    }
}


const fuzz = @import("fuzz.zig");

fn envInt(name: [*:0]const u8, default: u64) u64 {
    const getenv = @extern(*const fn ([*:0]const u8) callconv(.c) ?[*:0]const u8, .{ .name = "getenv" });
    const v = getenv(name) orelse return default;
    return std.fmt.parseInt(u64, std.mem.span(v), 0) catch default;
}

fn nowSeconds() u64 {
    const Timespec = extern struct { sec: i64, nsec: i64 };
    const clock_gettime = @extern(*const fn (c_int, *Timespec) callconv(.c) c_int, .{ .name = "clock_gettime" });
    var ts: Timespec = undefined;
    _ = clock_gettime(6, &ts); // CLOCK_MONOTONIC_RAW on macOS
    return @intCast(ts.sec);
}

/// Runs one random region natively and in ir_eval.
pub fn fuzzOne(gpa: std.mem.Allocator, env: *cases.Env, seed: u64) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rnd = prng.random();
    var r = try fuzz.generate(gpa, rnd, .{ .lazy_records = true });
    defer r.deinit(gpa);
    const c: cases.Case = .{ .text = "", .regs = fuzz.regs(rnd), .budget = fuzz.budget(rnd) };
    if (envInt("H9_FUZZ_VERBOSE", 0) > 1) {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        ir.print(&r, &aw.writer) catch {};
        std.debug.print("regs {any} budget {d}\n{s}\n", .{ c.regs, c.budget, aw.written() });
    }
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(gpa);
    const out = try emitRegion(gpa, &r, &code);
        const x = try testexec.load(code.items);
    defer x.deinit();
    const want = try env.evalCase(gpa, &r, c);
    if (envInt("H9_FUZZ_REDUCE", 0) != 0) {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        ir.print(&r, &aw.writer) catch {};
        if (!stillDiffers(gpa, env, aw.written(), c)) return;
        const small = try reduce(gpa, env, aw.written(), c);
        defer gpa.free(small);
        var r2 = try ir.parse(gpa, small);
        defer r2.deinit(gpa);
        var code2: std.ArrayList(u8) = .empty;
        defer code2.deinit(gpa);
        _ = try emitRegion(gpa, &r2, &code2);
                std.debug.print("seed 0x{x} reduced: regs {any} budget {d}\n{s}\n", .{ seed, c.regs, c.budget, small });
        dumpCode(code2.items);
        return error.TestExpectedEqual;
    }
    const cx = env.reset(c);
    const got = env.result(@enumFromInt(x.entry(out.entry)(cx)));
    if (cases.same(want, got)) return;
    if (cases.can_print) {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        ir.print(&r, &aw.writer) catch {};
        const small = try reduce(gpa, env, aw.written(), c);
        defer gpa.free(small);
        var r2 = try ir.parse(gpa, small);
        defer r2.deinit(gpa);
        var code2: std.ArrayList(u8) = .empty;
        defer code2.deinit(gpa);
        _ = try emitRegion(gpa, &r2, &code2);
                const want2 = try env.evalCase(gpa, &r2, c);
        const got2 = try runNative(gpa, env, &r2, c);
        std.debug.print("fuzz seed 0x{x} differs: regs {any} budget {d}\n want {any}\n got {any}\nreduced:\n{s}\n", .{ seed, c.regs, c.budget, want2, got2, small });
        dumpCode(code2.items);
    }
    return error.TestExpectedEqual;
}

fn runNative(gpa: std.mem.Allocator, env: *cases.Env, r: *const ir.Region, c: cases.Case) !cases.Result {
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(gpa);
    const out = try emitRegion(gpa, r, &code);
        const x = try testexec.load(code.items);
    defer x.deinit();
    const cx = env.reset(c);
    return env.result(@enumFromInt(x.entry(out.entry)(cx)));
}

/// Whether the region (as text) still runs differently natively. The
/// native run is in a child process with a 2-second alarm, so a hang
/// counts as differing (and a region that hangs in ir_eval is left alone).
fn stillDiffers(gpa: std.mem.Allocator, env: *cases.Env, text: []const u8, c: cases.Case) bool {
    var r = ir.parse(gpa, text) catch return false;
    defer r.deinit(gpa);
    if (ir.verify(&r) != null) return false;
    const fork = @extern(*const fn () callconv(.c) c_int, .{ .name = "fork" });
    const alarm = @extern(*const fn (c_uint) callconv(.c) c_uint, .{ .name = "alarm" });
    const exit = @extern(*const fn (c_int) callconv(.c) noreturn, .{ .name = "_exit" });
    const waitpid = @extern(*const fn (c_int, *c_int, c_int) callconv(.c) c_int, .{ .name = "waitpid" });
    // ir_eval must finish (a deleted loop counter can make it spin).
    if (hasBackEdge(&r)) {
        const pid = fork();
        if (pid == 0) {
            _ = alarm(1);
            _ = env.evalCase(gpa, &r, c) catch exit(1);
            exit(0);
        }
        var st: c_int = 0;
        _ = waitpid(pid, &st, 0);
        if (st != 0) return false;
    }
    const want = env.evalCase(gpa, &r, c) catch return false;
    const pid = fork();
    if (pid == 0) {
        _ = alarm(1);
        const got = runNative(gpa, env, &r, c) catch exit(2);
        exit(if (cases.same(want, got)) 0 else 1);
    }
    var status: c_int = 0;
    _ = waitpid(pid, &status, 0);
    return status != 0 and status != 2 << 8;
}

fn isTerminator(l: []const u8) bool {
    const t = std.mem.trim(u8, l, " ");
    return std.mem.startsWith(u8, t, "br") or std.mem.startsWith(u8, t, "exit.");
}

fn hasBackEdge(r: *const ir.Region) bool {
    for (r.blocks.items, 0..) |blk, bi| {
        const t = r.insts.items[blk.start + blk.len - 1];
        if ((t.op == .br or t.op == .brcond) and t.aux <= bi) return true;
        if (t.op == .brcond and t.aux2 <= bi) return true;
    }
    return false;
}

/// Deletes lines of a differing region while it keeps differing.
fn reduce(gpa: std.mem.Allocator, env: *cases.Env, text: []const u8, c: cases.Case) ![]u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| if (l.len != 0) try lines.append(gpa, l);
    // Delete runs of instruction lines, halving the run length.
    var chunk: usize = lines.items.len / 2;
    while (true) {
        var changed = false;
        var k: usize = lines.items.len;
        while (k > 0) {
            const start = k -| chunk;
            k = start;
            var keep: std.ArrayList([]const u8) = .empty;
            defer keep.deinit(gpa);
            var removed_any = false;
            for (lines.items, 0..) |l, j| {
                if (j >= start and j < start + chunk and l[0] == ' ' and !isTerminator(l)) {
                    removed_any = true;
                    continue;
                }
                try keep.append(gpa, l);
            }
            if (!removed_any) continue;
            const joined = try std.mem.join(gpa, "\n", keep.items);
            defer gpa.free(joined);
            if (stillDiffers(gpa, env, joined, c)) {
                std.mem.swap(std.ArrayList([]const u8), &lines, &keep);
                changed = true;
            }
        }
        if (!changed) {
            if (chunk <= 1) break;
            chunk /= 2;
        }
    }
    // Then terminators: a brcond becomes a br, an exit an exit.chain.
    return std.mem.join(gpa, "\n", lines.items);
}

test "random regions match ir_eval (H9_FUZZ_SECONDS, H9_FUZZ_SEED)" {
    if (!testexec.supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const env = try gpa.create(cases.Env);
    defer gpa.destroy(env);
    const seconds = envInt("H9_FUZZ_SECONDS", 0);
    var seed = envInt("H9_FUZZ_SEED", 0x5eed);
    const verbose = envInt("H9_FUZZ_VERBOSE", 0) != 0;
    const start = nowSeconds();
    var n: u64 = 0;
    while (if (seconds == 0) n < 3000 else nowSeconds() - start < seconds) : (n += 1) {
        if (verbose) std.debug.print("seed 0x{x}\n", .{seed});
        try fuzzOne(gpa, env, seed);
        seed +%= 1;
    }
    if (seconds != 0) std.debug.print("fuzz: {d} regions matched\n", .{n});
}

test "an IR file runs the same natively (H9_IR_FILE, H9_IR_REGS)" {
    if (!testexec.supported) return error.SkipZigTest;
    const getenv = @extern(*const fn ([*:0]const u8) callconv(.c) ?[*:0]const u8, .{ .name = "getenv" });
    const path = getenv("H9_IR_FILE") orelse return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, std.mem.span(path), gpa, .limited(1 << 20));
    defer gpa.free(text);
    var c: cases.Case = .{ .text = text, .regs = @splat(0) };
    if (getenv("H9_IR_REGS")) |rs| {
        var it = std.mem.tokenizeAny(u8, std.mem.span(rs), ", ");
        var k: usize = 0;
        while (it.next()) |t| : (k += 1) c.regs[k] = try std.fmt.parseInt(u64, t, 0);
    }
    const env = try gpa.create(cases.Env);
    defer gpa.destroy(env);
    var r = try cases.parse(gpa, c);
    defer r.deinit(gpa);
    if (getenv("H9_IR_EMIT_ONLY") != null) {
        var code: std.ArrayList(u8) = .empty;
        defer code.deinit(gpa);
        _ = try emitRegion(gpa, &r, &code);
        dumpCode(code.items);
        return;
    }
    const want = try env.evalCase(gpa, &r, c);
    const got = try runNative(gpa, env, &r, c);
    std.debug.print("want {any}\n got {any}\n", .{ want, got });
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(gpa);
    _ = try emitRegion(gpa, &r, &code);
    dumpCode(code.items);
}

test "chain sites link, and the jump cache finds a target inline" {
    if (!testexec.supported) return error.SkipZigTest;
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
        while (code.items.len % 16 != 0) try code.append(gpa, 0);
        starts[k] = @intCast(code.items.len);
        outs[k] = try emit(gpa, &r, &a, &code);
    }
    try std.testing.expectEqual(@as(u8, 1), outs[0].nchains);
    try std.testing.expectEqual(@as(u64, 0x2000), outs[0].chains[0].pc);
    const x = try testexec.load(code.items);
    defer x.deinit();
    var regs: [2]u64 = .{ 5, 0x2000 };
    var tlb: mem.Tlb = .{};
    var cx: ctx.Ctx = .{ .cpu = @intFromPtr(&regs), .tlb = @intFromPtr(&tlb) };

    // Unlinked: A leaves with .chain, naming its site.
    try std.testing.expectEqual(ctx.Exit.chain, @as(ctx.Exit, @enumFromInt(x.entry(starts[0])(&cx))));
    try std.testing.expectEqual(@as(u64, 0x2000), cx.exit_pc);
    const site = starts[0] + outs[0].chains[0].site;
    try std.testing.expectEqual(@intFromPtr(x.mem.ptr) + site, cx.exit_info);

    // Linked: A runs straight into B.
    const target = starts[1] + outs[1].chain_entry;
    const d: u32 = @bitCast(@as(i32, @intCast(@as(isize, target) - @as(isize, site))) >> 2);
    var patched = try gpa.dupe(u8, code.items);
    defer gpa.free(patched);
    std.mem.writeInt(u32, patched[site..][0..4], 0x14000000 | (d & 0x3ffffff), .little);
    const y = try testexec.load(patched);
    defer y.deinit();
    regs = .{ 5, 0x2000 };
    cx.retired = 0;
    try std.testing.expectEqual(ctx.Exit.svc, @as(ctx.Exit, @enumFromInt(y.entry(starts[0])(&cx))));
    try std.testing.expectEqual(@as(u64, 16), regs[0]);
    try std.testing.expectEqual(@as(u64, 2), cx.retired);

    // Indirect: a miss leaves; a jump-cache hit runs B.
    var jc: [ctx.jump_entries]ctx.JumpEntry = @splat(.{});
    cx.jump = @intFromPtr(&jc);
    regs = .{ 5, 0x2000 };
    try std.testing.expectEqual(ctx.Exit.indirect, @as(ctx.Exit, @enumFromInt(y.entry(starts[2])(&cx))));
    try std.testing.expectEqual(@as(u64, 0x2000), cx.exit_pc);
    jc[ctx.jumpIndex(0x2000)] = .{ .pc = 0x2000, .code = @intFromPtr(y.mem.ptr) + target };
    cx.retired = 0;
    try std.testing.expectEqual(ctx.Exit.svc, @as(ctx.Exit, @enumFromInt(y.entry(starts[2])(&cx))));
    try std.testing.expectEqual(@as(u64, 15), regs[0]);
    try std.testing.expectEqual(@as(u64, 3), cx.retired);
}

test "TSO loads are LDAPR where the host has LRCPC, else LDAR" {
    const gpa = std.testing.allocator;
    var r = try ir.parse(gpa, "region 0x0 tso\nb0:\n %0 = getreg:i64 #0x0\n %1 = load:i32 %0 #0x2 @0x0\n setreg %1 #0x8\n exit.chain #0x4\n");
    defer r.deinit(gpa);
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(gpa);
    _ = try emitRegion(gpa, &r, &code);
    var ldapr = false;
    var ldar = false;
    var k: usize = 0;
    while (k + 4 <= code.items.len) : (k += 4) {
        const w = std.mem.readInt(u32, code.items[k..][0..4], .little);
        if (w & 0x3FFFFC00 == 0x38BFC000) ldapr = true;
        if (w & 0x3FFFFC00 == 0x08DFFC00) ldar = true;
    }
    try std.testing.expect(ldapr == hasLrcpc() and ldar != ldapr);
    if (@import("builtin").os.tag == .macos and @import("builtin").cpu.arch == .aarch64) try std.testing.expect(hasLrcpc());
}

test "an unlinked chain site finds its target in the jump cache" {
    if (!testexec.supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const texts = [_][]const u8{
        "region 0x1000\nb0:\n %0 = getreg:i64 #0x0\n %1 = const:i64 #0x1\n %2 = add:i64 %0, %1\n setreg %2 #0x0\n retire #0x1\n exit.chain #0x2000\n",
        "region 0x2000\nb0:\n %0 = getreg:i64 #0x0\n %1 = const:i64 #0xa\n %2 = add:i64 %0, %1\n setreg %2 #0x0\n exit.svc #0x2004 !1\n",
    };
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(gpa);
    var outs: [2]emitter.Code = undefined;
    var starts: [2]u32 = undefined;
    for (texts, 0..) |t, k| {
        var r = try ir.parse(gpa, t);
        defer r.deinit(gpa);
        while (code.items.len % 16 != 0) try code.append(gpa, 0);
        starts[k] = @intCast(code.items.len);
        outs[k] = try emitRegion(gpa, &r, &code);
    }
    const x = try testexec.load(code.items);
    defer x.deinit();
    var regs: [2]u64 = .{ 5, 0 };
    var tlb: mem.Tlb = .{};
    var jc: [ctx.jump_entries]ctx.JumpEntry = @splat(.{});
    var cx: ctx.Ctx = .{ .cpu = @intFromPtr(&regs), .tlb = @intFromPtr(&tlb), .jump = @intFromPtr(&jc) };
    // A miss leaves as before.
    try std.testing.expectEqual(ctx.Exit.chain, @as(ctx.Exit, @enumFromInt(x.entry(starts[0])(&cx))));
    try std.testing.expectEqual(@as(u64, 6), regs[0]);
    // A hit runs B without leaving.
    jc[ctx.jumpIndex(0x2000)] = .{ .pc = 0x2000, .code = @intFromPtr(x.mem.ptr) + starts[1] + outs[1].chain_entry };
    regs = .{ 5, 0 };
    cx.retired = 0;
    try std.testing.expectEqual(ctx.Exit.svc, @as(ctx.Exit, @enumFromInt(x.entry(starts[0])(&cx))));
    try std.testing.expectEqual(@as(u64, 16), regs[0]);
    try std.testing.expectEqual(@as(u64, 2), cx.retired);
}
