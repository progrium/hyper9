//! Linear-scan register allocation for the native emitters (arm64 now,
//! x86-64 later). It knows nothing about the host but the registers it's
//! given, so each emitter describes its registers in a `Host` and lowers
//! from the `Plan` this returns.
//!
//! Two things get registers:
//!
//! - **Guest state.** The region's most used guest register-file fields
//!   ("chunks") are pinned to host registers for the whole region: loaded
//!   once at entry, read and written in place by getreg and setreg, and
//!   written back only where guest state must be exact in memory, and only
//!   if dirty. That's at exits, before calls (call.interp and call.helper,
//!   which read the Cpu, and after which the emitter reloads every chunk),
//!   and on a slow path's fault exit. `dirty_in` gives each block's dirty
//!   set at entry; the emitter follows it through the block.
//! - **Values.** Values are block-local, so each value's live range is an
//!   interval in one block, from its definition to its last use, and
//!   classic linear scan (Poletto and Sarkar) gives each a register or, when
//!   they run out, a frame slot for its whole life. A value never shares a
//!   register with an operand of the instruction that defines it, so a
//!   lowering may write its result before it's done reading operands.
//!
//! A chunk is the smallest naturally aligned field (1, 2, 4, or 8 bytes)
//! covering every getreg and setreg the region makes inside one aligned
//! 8-byte word of the Cpu, and only those bytes, so a write-back never
//! touches a byte the region didn't access. Narrower accesses inside a
//! chunk (x86's AL and AH in EAX) are bitfield reads and inserts.

const std = @import("std");
const ir = @import("ir.zig");
const alloc = @import("alloc.zig");
const Loc = alloc.Loc;

pub const Host = struct {
    /// Registers values may use, in order of preference.
    regs: []const u8,
    /// Registers chunks may be pinned to, in order of preference. A
    /// register a chunk takes isn't given to values.
    pin_regs: []const u8,
    /// At most this many chunks (and at most 32).
    max_pinned: u8,
    /// Bit n set: host register n survives a call. Values live across a
    /// call.interp or call.helper prefer these.
    callee_saved: u64,
    /// The front end's NZCV word in the Cpu, which `copy` ops read and
    /// write (ha64's Cpu.nzcv), if the host runs copy ops natively.
    guest_nzcv: ?u32 = null,
    /// And the FPCR and FPSR words an FP copy runs under and accumulates into.
    guest_fpcr: ?u32 = null,
    guest_fpsr: ?u32 = null,
};

/// A `copy` op's register field (ir.zig, Op.copy).
pub const CopyField = struct {
    off: u32,
    read: bool,
    write: bool,
    /// A 16-byte V register, else an 8-byte X register.
    vec: bool,
};

/// The fields of a copy op's aux2, in Rd, Rn, Rm, Ra order; null where a
/// field isn't a register.
pub fn copyFields(aux2: u64) [4]?CopyField {
    var out: [4]?CopyField = undefined;
    for (&out, 0..) |*f, k| {
        const d: u16 = @truncate(aux2 >> @intCast(16 * k));
        f.* = if (d == 0) null else .{ .off = d & 0x1fff, .read = d & 0x2000 != 0, .write = d & 0x4000 != 0, .vec = d & 0x8000 != 0 };
    }
    return out;
}

pub const copy_reads_nzcv: u64 = 1 << 32;
pub const copy_writes_nzcv: u64 = 1 << 33;
/// FP or saturating: it runs under the guest's FPCR and accumulates into
/// its FPSR.
pub const copy_fp: u64 = 1 << 34;

/// Whether the op calls out of generated code (and so reads and writes the
/// Cpu): call.interp, call.helper, and copy ops run through the interpreter.
pub fn isCall(i: ir.Inst) bool {
    return i.op == .@"call.interp" or i.op == .@"call.helper" or (i.op == .copy and copyByInterp(i.aux));
}

/// Whether a copy op runs through the interpreter: TBL and TBX with a
/// list of more than one register (its registers must be consecutive,
/// which field rewriting can't keep; copy.zig doesn't make them).
/// Likewise a by-element op with H lanes and its index's M bit (bit 20)
/// set, whose 4-bit Rm a 5-bit descriptor misnames.
pub fn copyByInterp(aux: u64) bool {
    const w: u32 = @truncate(aux);
    const tbl_list = w & 0xbf208c00 == 0x0e000000 and (w >> 13) & 3 != 0;
    return tbl_list or (byElementH(w) and (w >> 20) & 1 != 0);
}

/// AdvSIMD by-element (vector or scalar) with H lanes (size 01), whose Rm
/// is 4 bits with M in bit 20.
pub fn byElementH(w: u32) bool {
    const vec = w & 0x9f000400 == 0x0f000000;
    const scalar = w & 0xdf000400 == 0x5f000000;
    return (vec or scalar) and (w >> 22) & 3 == 1;
}

pub const Chunk = struct {
    /// Byte offset in the Cpu.
    off: u32,
    /// 1, 2, 4, or 8.
    bytes: u8,
    /// The host register it's pinned to.
    reg: u8,
    /// getregs and setregs of it in the region.
    uses: u32,
};

pub const no_chunk: u8 = 0xff;

/// A set of chunks, by index.
pub const ChunkSet = u32;

pub const Plan = struct {
    /// Where each value lives (`.none` for no value, or a virtual one).
    locs: []Loc,
    /// Frame slots the spilled values use.
    slots: u32,
    chunks: []Chunk,
    /// For each getreg and setreg, the chunk it reads or writes, or no_chunk.
    chunk_of: []u8,
    /// For each value, the index of its last use (its own index if none).
    end: []u32,
    /// For each value, how many operands name it.
    uses: []u32,
    /// For each block, the chunks that may be dirty when it's entered.
    dirty_in: []ChunkSet,
    /// Host registers some value is ever given (bit per register number).
    used_regs: u64,

    pub fn deinit(p: *Plan, gpa: std.mem.Allocator) void {
        gpa.free(p.locs);
        gpa.free(p.chunks);
        gpa.free(p.chunk_of);
        gpa.free(p.end);
        gpa.free(p.uses);
        gpa.free(p.dirty_in);
    }

    /// The chunks' registers, as a register mask.
    pub fn pinnedRegs(p: *const Plan) u64 {
        var m: u64 = 0;
        for (p.chunks) |c| m |= @as(u64, 1) << @intCast(c.reg);
        return m;
    }

    /// Registers holding values that are live across instruction `idx`:
    /// defined before it and used after it. These are what a call at `idx`
    /// must preserve (with the pinned chunks, which the caller adds).
    pub fn liveAcross(p: *const Plan, r: *const ir.Region, block: ir.BlockId, idx: usize) u64 {
        const blk = r.blocks.items[block];
        var m: u64 = 0;
        for (blk.start..idx) |v| {
            if (p.end[v] > idx) switch (p.locs[v]) {
                .reg => |x| m |= @as(u64, 1) << @intCast(x),
                else => {},
            };
        }
        return m;
    }

    /// The chunk holding all of the `bytes` bytes at Cpu offset `off`.
    pub fn chunkAt(p: *const Plan, off: u64, bytes: u64) ?u8 {
        for (p.chunks, 0..) |c, k| {
            if (off >= c.off and off + bytes <= c.off + c.bytes) return @intCast(k);
        }
        return null;
    }

    /// The value's register, or null for a slot or none.
    pub fn reg(p: *const Plan, v: ir.Ref) ?u8 {
        return switch (p.locs[v]) {
            .reg => |x| x,
            else => null,
        };
    }
};

pub const Error = error{ OutOfMemory, TooLarge };

fn accessBytes(r: *const ir.Region, i: ir.Inst) ?u32 {
    const t = if (i.op == .getreg) i.ty else r.insts.items[i.a].ty;
    return switch (t) {
        .i8 => 1,
        .i16 => 2,
        .i32 => 4,
        .i64, .flags => 8,
        .v128 => 16,
        else => null,
    };
}

/// Counts an access of `bytes` bytes at Cpu offset `off`.
fn access(gpa: std.mem.Allocator, words: *std.AutoArrayHashMapUnmanaged(u64, WordInfo), off: u64, bytes: u32) !void {
    const lo: u32 = @intCast(off % 8);
    if (lo + bytes > 8) return markBad(gpa, words, off, bytes);
    const gop = try words.getOrPut(gpa, off / 8);
    if (!gop.found_existing) gop.value_ptr.* = .{};
    gop.value_ptr.span |= @truncate(((@as(u32, 1) << @intCast(bytes)) - 1) << @intCast(lo));
    gop.value_ptr.uses += 1;
}

/// Marks the words a `bytes`-byte access at `off` touches as unpinnable.
fn markBad(gpa: std.mem.Allocator, words: *std.AutoArrayHashMapUnmanaged(u64, WordInfo), off: u64, bytes: u64) !void {
    var q = off / 8;
    while (q * 8 < off + bytes) : (q += 1) {
        const g = try words.getOrPut(gpa, q);
        if (!g.found_existing) g.value_ptr.* = .{};
        g.value_ptr.bad = true;
    }
}

const WordInfo = struct {
    bad: bool = false,
    span: u8 = 0, // byte mask within the word
    uses: u32 = 0,
};

/// Plans the region. `virtual`, if given, marks values the emitter
/// doesn't keep anywhere (flags it keeps in host flags, conditions it fuses
/// into branches): they get `.none`.
pub fn plan(gpa: std.mem.Allocator, r: *const ir.Region, host: Host, virtual: ?[]const bool) Error!Plan {
    const n = r.insts.items.len;
    var p: Plan = .{
        .locs = try gpa.alloc(Loc, n),
        .slots = 0,
        .chunks = &.{},
        .chunk_of = &.{},
        .end = &.{},
        .uses = &.{},
        .dirty_in = &.{},
        .used_regs = 0,
    };
    errdefer gpa.free(p.locs);
    p.chunk_of = try gpa.alloc(u8, n);
    errdefer gpa.free(p.chunk_of);
    p.end = try gpa.alloc(u32, n);
    errdefer gpa.free(p.end);
    p.uses = try gpa.alloc(u32, n);
    errdefer gpa.free(p.uses);
    p.dirty_in = try gpa.alloc(ChunkSet, r.blocks.items.len);
    errdefer gpa.free(p.dirty_in);

    // Last uses and use counts.
    for (0..n) |i| {
        p.end[i] = @intCast(i);
        p.uses[i] = 0;
        p.chunk_of[i] = no_chunk;
    }
    for (r.insts.items, 0..) |i, idx| for (i.operands()) |o| {
        if (o == ir.none) continue;
        p.end[o] = @intCast(idx);
        p.uses[o] += 1;
    };

    // Chunks.
    var words: std.AutoArrayHashMapUnmanaged(u64, WordInfo) = .empty;
    defer words.deinit(gpa);
    for (r.insts.items) |i| {
        // An fp op ORs its exceptions into the 4-byte word at aux2 - 1,
        // which a chunk mustn't hold.
        if (i.op.isFp() and i.aux2 != 0) try markBad(gpa, &words, i.aux2 - 1, 4);
        if (i.op == .copy and !copyByInterp(i.aux)) {
            // A copied instruction's X registers are 8-byte accesses (it
            // wants them in host registers), its V registers aren't
            // pinned, and its NZCV is the guest's word.
            for (copyFields(i.aux2)) |f| if (f) |x| {
                if (x.vec) try markBad(gpa, &words, x.off, 16) else try access(gpa, &words, x.off, 8);
            };
            if (host.guest_nzcv) |nz| if (i.aux & (copy_reads_nzcv | copy_writes_nzcv) != 0) try access(gpa, &words, nz, 4);
            // FPCR and FPSR stay in the Cpu: the emitter keeps the guest's
            // in the host's registers across the region.
            if (i.aux & copy_fp != 0) for ([2]?u32{ host.guest_fpcr, host.guest_fpsr }) |w| if (w) |o| try markBad(gpa, &words, o, 4);
            continue;
        }
        if (i.op != .getreg and i.op != .setreg) continue;
        if (accessBytes(r, i)) |size| try access(gpa, &words, i.aux, size) else try markBad(gpa, &words, i.aux, 8);
    }
    var cands: std.ArrayList(Chunk) = .empty;
    defer cands.deinit(gpa);
    for (words.keys(), words.values()) |q, w| {
        if (w.bad or w.uses < 2 or w.span == 0) continue;
        const lo: u32 = @ctz(w.span);
        const hi: u32 = 8 - @clz(w.span); // one past
        const size = hi - lo;
        if (!std.math.isPowerOfTwo(size) or lo % size != 0) continue;
        try cands.append(gpa, .{ .off = @intCast(q * 8 + lo), .bytes = @intCast(size), .reg = 0, .uses = w.uses });
    }
    std.mem.sort(Chunk, cands.items, {}, struct {
        fn lt(_: void, a: Chunk, b: Chunk) bool {
            return if (a.uses != b.uses) a.uses > b.uses else a.off < b.off;
        }
    }.lt);
    const npin = @min(cands.items.len, host.max_pinned, host.pin_regs.len, 32);
    p.chunks = try gpa.alloc(Chunk, npin);
    errdefer gpa.free(p.chunks);
    var pinned_mask: u64 = 0;
    for (p.chunks, cands.items[0..npin], 0..) |*c, cand, k| {
        c.* = cand;
        c.reg = host.pin_regs[k];
        pinned_mask |= @as(u64, 1) << @intCast(c.reg);
    }
    for (r.insts.items, 0..) |i, idx| {
        if (i.op != .getreg and i.op != .setreg) continue;
        if (p.chunkAt(i.aux, 1)) |k| p.chunk_of[idx] = k;
    }

    // Values: linear scan in each block.
    var free_slots: std.ArrayList(u32) = .empty;
    defer free_slots.deinit(gpa);
    const Active = struct { end: u32, v: u32 };
    var active: std.ArrayList(Active) = .empty;
    defer active.deinit(gpa);
    var calls: std.ArrayList(u32) = .empty;
    defer calls.deinit(gpa);
    var value_regs: u64 = 0;
    for (host.regs) |x| value_regs |= @as(u64, 1) << @intCast(x);
    value_regs &= ~pinned_mask;

    for (r.blocks.items) |blk| {
        active.clearRetainingCapacity();
        calls.clearRetainingCapacity();
        var free = value_regs;
        for (blk.start..blk.start + blk.len) |idx| {
            if (isCall(r.insts.items[idx])) try calls.append(gpa, @intCast(idx));
        }
        for (blk.start..blk.start + blk.len) |idx| {
            const i = r.insts.items[idx];
            // Expire intervals that ended before this instruction.
            var k: usize = 0;
            while (k < active.items.len) {
                const a = active.items[k];
                if (a.end < idx) {
                    switch (p.locs[a.v]) {
                        .reg => |x| free |= @as(u64, 1) << @intCast(x),
                        .slot => |s| try free_slots.append(gpa, s),
                        .none => {},
                    }
                    _ = active.swapRemove(k);
                } else k += 1;
            }
            if (i.ty == .none or (virtual != null and virtual.?[idx])) {
                p.locs[idx] = .none;
                continue;
            }
            const end = p.end[idx];
            var crosses = false;
            for (calls.items) |c| if (c > idx and c < end) {
                crosses = true;
            };
            if (i.ty == .v128) {
                // Vectors live in a pair of slots of their own.
                if (p.slots + 2 > 4000) return error.TooLarge;
                p.locs[idx] = .{ .slot = p.slots };
                p.slots += 2;
                continue;
            }
            if (pickReg(host, free, crosses)) |x| {
                free &= ~(@as(u64, 1) << @intCast(x));
                p.locs[idx] = .{ .reg = x };
                p.used_regs |= @as(u64, 1) << @intCast(x);
            } else {
                // Spill whichever lives longest: the new value or an active one.
                var far: ?usize = null;
                for (active.items, 0..) |a, ai| {
                    if (p.locs[a.v] != .reg) continue;
                    if (far == null or a.end > active.items[far.?].end) far = ai;
                }
                if (far != null and active.items[far.?].end > end) {
                    const victim = active.items[far.?].v;
                    p.locs[idx] = p.locs[victim];
                    // A fresh slot: a reused one may have held a value
                    // during the victim's life so far.
                    if (p.slots >= 4000) return error.TooLarge;
                    p.locs[victim] = .{ .slot = p.slots };
                    p.slots += 1;
                } else {
                    p.locs[idx] = .{ .slot = try newSlot(gpa, &p, &free_slots) };
                }
            }
            try active.append(gpa, .{ .end = end, .v = @intCast(idx) });
        }
        // Slots are block-local too.
        for (active.items) |a| switch (p.locs[a.v]) {
            .slot => |s| try free_slots.append(gpa, s),
            else => {},
        };
    }

    // Dirty chunks at each block's entry: a forward union to a fixpoint.
    @memset(p.dirty_in, 0);
    if (p.chunks.len != 0) {
        var changed = true;
        while (changed) {
            changed = false;
            for (r.blocks.items, 0..) |blk, bi| {
                var d = p.dirty_in[bi];
                for (blk.start..blk.start + blk.len) |idx| {
                    const i = r.insts.items[idx];
                    switch (i.op) {
                        .setreg => if (p.chunk_of[idx] != no_chunk) {
                            d |= @as(ChunkSet, 1) << @intCast(p.chunk_of[idx]);
                        },
                        .@"call.interp", .@"call.helper" => d = 0,
                        .copy => if (isCall(i)) {
                            d = 0;
                        } else {
                            for (copyFields(i.aux2)) |f| if (f) |x| if (x.write and !x.vec) {
                                if (p.chunkAt(x.off, 8)) |k| d |= @as(ChunkSet, 1) << @intCast(k);
                            };
                            if (i.aux & copy_writes_nzcv != 0) if (host.guest_nzcv) |nz| if (p.chunkAt(nz, 4)) |k| {
                                d |= @as(ChunkSet, 1) << @intCast(k);
                            };
                        },
                        .br => {
                            if (p.dirty_in[i.aux] | d != p.dirty_in[i.aux]) changed = true;
                            p.dirty_in[i.aux] |= d;
                        },
                        .brcond => for ([2]u64{ i.aux, i.aux2 }) |t| {
                            if (p.dirty_in[t] | d != p.dirty_in[t]) changed = true;
                            p.dirty_in[t] |= d;
                        },
                        else => {},
                    }
                }
            }
        }
    }
    return p;
}

fn newSlot(gpa: std.mem.Allocator, p: *Plan, free_slots: *std.ArrayList(u32)) Error!u32 {
    if (free_slots.pop()) |s| return s;
    if (p.slots >= 4000) return error.TooLarge;
    p.slots += 1;
    try free_slots.ensureUnusedCapacity(gpa, 1);
    return p.slots - 1;
}

fn pickReg(host: Host, free: u64, crosses: bool) ?u8 {
    // A value live across a call takes a callee-saved register if it can;
    // others leave those for it.
    var fallback: ?u8 = null;
    for (host.regs) |x| {
        if (free & (@as(u64, 1) << @intCast(x)) == 0) continue;
        const saved = host.callee_saved & (@as(u64, 1) << @intCast(x)) != 0;
        if (saved == crosses) return x;
        if (fallback == null) fallback = x;
    }
    return fallback;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const test_host: Host = .{
    .regs = &.{ 0, 1, 2, 3, 20, 21 },
    .pin_regs = &.{ 21, 20, 3 },
    .max_pinned = 2,
    .callee_saved = (1 << 20) | (1 << 21),
};

test "chunks cover overlapping accesses and take the most used words" {
    const gpa = testing.allocator;
    var r = try ir.parse(gpa,
        \\b0:
        \\  %0 = getreg:i32 #0x0
        \\  %1 = getreg:i8 #0x1
        \\  %2 = zext:i32 %1
        \\  %3 = add:i32 %0, %2
        \\  setreg %3 #0x0
        \\  %5 = getreg:i64 #0x8
        \\  setreg %5 #0x8
        \\  %7 = getreg:i64 #0x10
        \\  %8 = getreg:i64 #0x10
        \\  %9 = getreg:i64 #0x10
        \\  %10 = getreg:i32 #0x1c
        \\  %11 = getreg:i32 #0x1c
        \\  %12 = getreg:i64 #0x24
        \\  %13 = getreg:i64 #0x24
        \\  exit.chain #0x0
    );
    defer r.deinit(gpa);
    try testing.expect(ir.verify(&r) == null);
    var p = try plan(gpa, &r, test_host, null);
    defer p.deinit(gpa);
    // Word 0 (3 uses, bytes 0..3) and word 2 (3 uses) beat word 1 (2);
    // 0x1c is a 4-byte chunk but unused here; 0x24 straddles words.
    try testing.expectEqual(@as(usize, 2), p.chunks.len);
    try testing.expectEqual(Chunk{ .off = 0, .bytes = 4, .reg = 21, .uses = 3 }, p.chunks[0]);
    try testing.expectEqual(@as(u32, 0x10), p.chunks[1].off);
    try testing.expectEqual(@as(u8, 0), p.chunk_of[1]);
    try testing.expectEqual(no_chunk, p.chunk_of[5]);
    try testing.expectEqual(no_chunk, p.chunk_of[12]);
    // Values don't get pinned registers.
    for (p.locs) |l| switch (l) {
        .reg => |x| try testing.expect(x != 21 and x != 20),
        else => {},
    };
}

test "linear scan spills the longest-lived value" {
    const gpa = testing.allocator;
    var r = try ir.parse(gpa,
        \\b0:
        \\  %0 = const:i64 #0x1
        \\  %1 = const:i64 #0x2
        \\  %2 = const:i64 #0x3
        \\  %3 = const:i64 #0x4
        \\  %4 = const:i64 #0x5
        \\  %5 = add:i64 %1, %2
        \\  %6 = add:i64 %3, %4
        \\  %7 = add:i64 %5, %6
        \\  %8 = add:i64 %7, %0
        \\  exit.indirect %8
    );
    defer r.deinit(gpa);
    const host: Host = .{ .regs = &.{ 0, 1, 2, 3, 4 }, .pin_regs = &.{}, .max_pinned = 0, .callee_saved = 0 };
    var p = try plan(gpa, &r, host, null);
    defer p.deinit(gpa);
    // %0 lives longest, so it's the one in a slot.
    try testing.expect(p.locs[0] == .slot);
    for (1..9) |v| try testing.expect(p.locs[v] == .reg);
    // A result never shares a register with its operands.
    for (r.insts.items, 0..) |i, idx| for (i.operands()) |o| {
        if (o == ir.none or p.locs[idx] != .reg or p.locs[o] != .reg) continue;
        try testing.expect(p.locs[idx].reg != p.locs[o].reg);
    };
}

test "dirty chunks flow along edges, and calls clean them" {
    const gpa = testing.allocator;
    var r = try ir.parse(gpa,
        \\handle 0x0
        \\b0:
        \\  %0 = getreg:i64 #0x0
        \\  setreg %0 #0x0
        \\  %2 = const:i1 #0x1
        \\  brcond %2 -> b1 b2
        \\b1:
        \\  call.interp #0x0
        \\  %4 = getreg:i64 #0x8
        \\  setreg %4 #0x8
        \\  br -> b2
        \\b2:
        \\  exit.chain #0x0
    );
    defer r.deinit(gpa);
    try testing.expect(ir.verify(&r) == null);
    var p = try plan(gpa, &r, test_host, null);
    defer p.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), p.chunks.len);
    const c0 = p.chunk_of[0];
    const c8 = p.chunk_of[5];
    try testing.expectEqual(@as(ChunkSet, 0), p.dirty_in[0]);
    try testing.expectEqual(@as(ChunkSet, 1) << @intCast(c0), p.dirty_in[1]);
    try testing.expectEqual((@as(ChunkSet, 1) << @intCast(c0)) | (@as(ChunkSet, 1) << @intCast(c8)), p.dirty_in[2]);
}

test "values live across a call prefer callee-saved registers" {
    const gpa = testing.allocator;
    var r = try ir.parse(gpa,
        \\handle 0x0
        \\b0:
        \\  %0 = const:i64 #0x1
        \\  %1 = const:i64 #0x2
        \\  call.interp #0x0
        \\  %3 = add:i64 %0, %0
        \\  exit.indirect %3
    );
    defer r.deinit(gpa);
    const host: Host = .{ .regs = &.{ 0, 1, 20 }, .pin_regs = &.{}, .max_pinned = 0, .callee_saved = 1 << 20 };
    var p = try plan(gpa, &r, host, null);
    defer p.deinit(gpa);
    try testing.expectEqual(Loc{ .reg = 20 }, p.locs[0]);
    try testing.expectEqual(Loc{ .reg = 0 }, p.locs[1]);
}
