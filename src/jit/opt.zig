//! Optimizations on a lifted region, before allocation and emission. All
//! work within a block (values are block-local) and keep the IR's rules
//! (README.md): guest state exact at every operation that can leave, and
//! ctx.retired exact at every exit (the counts ride on the leaving ops,
//! which no pass moves or drops).
//!
//! - **Register forwarding.** A `getreg` of a Cpu slot the block already
//!   read or wrote at the same width takes that value instead. A call out
//!   (`call.interp`, `call.helper`) may change the Cpu, and forgets them.
//! - **Constant folding.** A pure op whose operands are all constants
//!   becomes a constant; `select` on a constant condition becomes its arm;
//!   `brcond` on one becomes `br`; adding, subtracting, or-ing, or xor-ing
//!   0, and shifting by 0, become the operand.
//! - **Compare and branch.** A condition on the flags of a subtract
//!   (`nzcv.sub`, `eflags.sub`) that is a plain comparison of its operands
//!   becomes an `icmp` of them, so the flags are computed only where
//!   something stores them.
//! - **Dead register writes.** A `setreg` that a later `setreg` in the
//!   block overwrites, with nothing between that can leave, call out, or
//!   read the slot, goes. This is where flag liveness lands: the lifter
//!   writes NZCV back only where something could see it, and a write that
//!   still dies here goes.
//! - **Dead code.** Pure ops and `getreg`s nothing uses go.
//!
//! An `fp.*` op with an aux2 ORs its exceptions into a Cpu word (FPSR or
//! MXCSR): both passes treat it as a read and a write of that word.
//!
//! Redundant TLB checks (two accesses to one page in a block) need the IR
//! to say a load or store may skip its check; that waits for an op flag.

const std = @import("std");
const ir = @import("ir.zig");
const ir_eval = @import("ir_eval.zig");

const Inst = ir.Inst;
const Ref = ir.Ref;
const none = ir.none;

pub fn run(gpa: std.mem.Allocator, r: *ir.Region) !void {
    const n = r.insts.items.len;
    if (n == 0) return;
    const repl = try gpa.alloc(Ref, n);
    defer gpa.free(repl);
    for (repl, 0..) |*x, i| x.* = @intCast(i);
    const dead = try gpa.alloc(bool, n);
    defer gpa.free(dead);
    @memset(dead, false);
    for (r.blocks.items) |blk| {
        try forward(r, blk, repl);
        deadWrites(r, blk, dead);
    }
    const live = try gpa.alloc(bool, n);
    defer gpa.free(live);
    deadCode(r, dead, live);
    try compact(gpa, r, dead);
}

fn resolve(repl: []const Ref, x: Ref) Ref {
    var v = x;
    while (v != none and repl[v] != v) v = repl[v];
    return v;
}

/// A Cpu slot's known value: [off, off+size) holds `ref`.
const Known = struct { off: u64, size: u32, ref: Ref };

fn sizeOf(t: ir.Type) u32 {
    return switch (t) {
        .i8 => 1,
        .i16 => 2,
        .i32 => 4,
        .i64, .flags => 8,
        .v128 => 16,
        else => 0,
    };
}

/// The Cpu word an `fp.*` op ORs its exceptions into, if any, as an offset.
fn excWord(i: Inst) ?u64 {
    return if (i.op.isFp() and i.aux2 != 0) i.aux2 - 1 else null;
}

/// Drops the entries that overlap [off, off+size).
fn forget(list: []Known, n: *usize, off: u64, size: u32) void {
    var j: usize = 0;
    while (j < n.*) {
        if (overlaps(list[j].off, list[j].size, off, size)) {
            list[j] = list[n.* - 1];
            n.* -= 1;
        } else j += 1;
    }
}

fn overlaps(a_off: u64, a_size: u32, b_off: u64, b_size: u32) bool {
    return a_off < b_off + b_size and b_off < a_off + a_size;
}

/// Register forwarding and constant folding, in one pass over the block.
fn forward(r: *ir.Region, blk: ir.Block, repl: []Ref) !void {
    var known: [64]Known = undefined;
    var nk: usize = 0;
    const insts = r.insts.items;
    for (blk.start..blk.start + blk.len) |idx| {
        const i = &insts[idx];
        i.a = resolve(repl, i.a);
        i.b = resolve(repl, i.b);
        i.c = resolve(repl, i.c);
        switch (i.op) {
            .getreg => {
                const sz = sizeOf(i.ty);
                const hit = for (known[0..nk]) |k| {
                    if (k.off == i.aux and k.size == sz and insts[k.ref].ty == i.ty) break k.ref;
                } else null;
                if (hit) |h| {
                    repl[idx] = h;
                } else if (nk < known.len) {
                    known[nk] = .{ .off = i.aux, .size = sz, .ref = @intCast(idx) };
                    nk += 1;
                }
            },
            .setreg => {
                const sz = sizeOf(insts[i.a].ty);
                forget(&known, &nk, i.aux, sz);
                if (nk < known.len) {
                    known[nk] = .{ .off = i.aux, .size = sz, .ref = i.a };
                    nk += 1;
                }
            },
            .@"call.interp", .@"call.helper" => nk = 0,
            .brcond => if (constOf(insts, i.a)) |c| {
                i.* = .{ .op = .br, .aux = if (c & 1 == 1) i.aux else i.aux2 };
            },
            else => if (i.op.isPure()) {
                fold(insts, idx, repl);
            } else if (excWord(i.*)) |w| forget(&known, &nk, w, 4),
        }
    }
}

fn constOf(insts: []const Inst, x: Ref) ?u64 {
    if (x == none) return null;
    const d = insts[x];
    return if (d.op == .@"const") d.aux else null;
}

fn fold(insts: []Inst, idx: usize, repl: []Ref) void {
    const i = &insts[idx];
    if (i.op == .@"const") return;
    const ca = constOf(insts, i.a);
    const cb = constOf(insts, i.b);
    const cc = constOf(insts, i.c);
    const all = (i.a == none or ca != null) and (i.b == none or cb != null) and (i.c == none or cc != null);
    if (all) {
        const ta: ir.Type = if (i.a != none) insts[i.a].ty else .none;
        const v = ir_eval.evalPure(i.op, i.ty, ta, ca orelse 0, cb orelse 0, cc orelse 0, i.aux);
        i.* = .{ .op = .@"const", .ty = i.ty, .aux = if (i.ty == .flags) v else v & i.ty.mask() };
        return;
    }
    switch (i.op) {
        .@"nzcv.cond", .@"eflags.cond" => {
            const f = insts[i.a];
            const p = if (i.op == .@"nzcv.cond" and f.op == .@"nzcv.sub")
                subPredA64(i.aux)
            else if (i.op == .@"eflags.cond" and f.op == .@"eflags.sub")
                subPredX86(i.aux)
            else
                null;
            if (p) |pred| i.* = .{ .op = .icmp, .ty = .i1, .a = f.a, .b = f.b, .aux = @intFromEnum(pred) };
        },
        .select => if (ca) |c| {
            repl[idx] = if (c & 1 == 1) i.b else i.c;
        },
        .add, .sub, .@"or", .xor, .shl, .lshr, .ashr, .ror, .rol => if (cb) |c| {
            if (c & i.ty.mask() == 0) repl[idx] = i.a;
        },
        else => {},
    }
}

/// The comparison arm64's condition `cc` makes of `a - b`'s flags, if
/// it's one (MI, PL, VS, and VC aren't).
fn subPredA64(cc: u64) ?ir.Pred {
    return switch (cc) {
        0 => .eq,
        1 => .ne,
        2 => .uge, // CS
        3 => .ult, // CC
        8 => .ugt, // HI
        9 => .ule, // LS
        10 => .sge,
        11 => .slt,
        12 => .sgt,
        13 => .sle,
        else => null,
    };
}

/// The same for x86's condition codes (O, NO, S, NS, P, and NP aren't).
fn subPredX86(cc: u64) ?ir.Pred {
    return switch (cc) {
        2 => .ult, // B
        3 => .uge, // AE
        4 => .eq,
        5 => .ne,
        6 => .ule, // BE
        7 => .ugt, // A
        12 => .slt, // L
        13 => .sge, // GE
        14 => .sle, // LE
        15 => .sgt, // G
        else => null,
    };
}

/// Marks `setreg`s a later one in the block overwrites before anything can
/// see the slot.
fn deadWrites(r: *ir.Region, blk: ir.Block, dead: []bool) void {
    // Slots written later in the block, with no barrier since.
    var later: [64]Known = undefined;
    var nl: usize = 0;
    const insts = r.insts.items;
    var idx = blk.start + blk.len;
    while (idx > blk.start) {
        idx -= 1;
        const i = insts[idx];
        if (i.op.canLeave() or i.op == .@"call.interp" or i.op == .@"call.helper" or i.op.isTerminator()) {
            nl = 0;
            continue;
        }
        switch (i.op) {
            .getreg => forget(&later, &nl, i.aux, sizeOf(i.ty)),
            .setreg => {
                const sz = sizeOf(insts[i.a].ty);
                const covered = for (later[0..nl]) |k| {
                    if (k.off <= i.aux and i.aux + sz <= k.off + k.size) break true;
                } else false;
                if (covered) {
                    dead[idx] = true;
                } else if (nl < later.len) {
                    later[nl] = .{ .off = i.aux, .size = sz, .ref = none };
                    nl += 1;
                }
            },
            else => if (excWord(i)) |w| forget(&later, &nl, w, 4),
        }
    }
}

/// Marks pure ops and getregs that nothing live uses. Operands are earlier
/// in the same block, so one backward sweep per block sees every use first.
fn deadCode(r: *ir.Region, dead: []bool, live: []bool) void {
    const insts = r.insts.items;
    @memset(live, false);
    for (r.blocks.items) |blk| {
        var idx = blk.start + blk.len;
        while (idx > blk.start) {
            idx -= 1;
            const i = insts[idx];
            const removable = i.op.isPure() or i.op == .getreg;
            const keep = if (dead[idx]) false else if (removable) live[idx] else true;
            if (!keep) {
                dead[idx] = true;
                continue;
            }
            for (i.operands()) |o| if (o != none) {
                live[o] = true;
            };
        }
    }
}

/// Drops the dead instructions and renumbers the rest.
fn compact(gpa: std.mem.Allocator, r: *ir.Region, dead: []const bool) !void {
    // Blocks needn't be stored in order (a lifter fills exit blocks
    // late), so build the new list apart from the old.
    const old = r.insts.items;
    const map = try gpa.alloc(Ref, old.len);
    defer gpa.free(map);
    var out: std.ArrayList(Inst) = try .initCapacity(gpa, old.len);
    errdefer out.deinit(gpa);
    for (r.blocks.items) |*blk| {
        const start = out.items.len;
        for (blk.start..blk.start + blk.len) |idx| {
            if (dead[idx]) continue;
            var i = old[idx];
            if (i.a != none) i.a = map[i.a];
            if (i.b != none) i.b = map[i.b];
            if (i.c != none) i.c = map[i.c];
            map[idx] = @intCast(out.items.len);
            out.appendAssumeCapacity(i);
        }
        blk.start = @intCast(start);
        blk.len = @intCast(out.items.len - start);
    }
    r.insts.deinit(gpa);
    r.insts = out;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn optimized(text: []const u8) ![]u8 {
    const gpa = testing.allocator;
    var r = try ir.parse(gpa, text);
    defer r.deinit(gpa);
    try testing.expect(ir.verify(&r) == null);
    try run(gpa, &r);
    if (ir.verify(&r)) |e| {
        std.debug.print("{s} at %{d}\n", .{ e.msg, e.inst });
        return error.Invalid;
    }
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try ir.print(&r, &out.writer);
    return out.toOwnedSlice();
}

test "opt: forwarding, folding, dead writes, and dead code" {
    const got = try optimized(
        \\region 0x1000
        \\b0:
        \\  %0 = getreg:i64 #0x8
        \\  %1 = const:i64 #0x2
        \\  %2 = const:i64 #0x3
        \\  %3 = add:i64 %1, %2
        \\  %4 = add:i64 %0, %3
        \\  setreg %4 #0x10
        \\  %5 = getreg:i64 #0x10
        \\  %6 = const:i64 #0x0
        \\  %7 = add:i64 %5, %6
        \\  setreg %7 #0x18
        \\  %8 = getreg:i64 #0x8
        \\  setreg %8 #0x18
        \\  %9 = const:i1 #0x1
        \\  brcond %9 -> b1 b1
        \\b1:
        \\  exit.chain #0x2000
        \\
    );
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\region 0x1000
        \\b0:
        \\  %0 = getreg:i64 #0x8
        \\  %1 = const:i64 #0x5
        \\  %2 = add:i64 %0, %1
        \\  setreg %2 #0x10
        \\  setreg %0 #0x18
        \\  br -> b1
        \\b1:
        \\  exit.chain #0x2000
        \\
    , got);
}

test "opt: a write before anything that can leave stays, and calls forget" {
    const got = try optimized(
        \\region 0x1000
        \\handle 0x0
        \\b0:
        \\  %0 = getreg:i64 #0x8
        \\  setreg %0 #0x10
        \\  %1 = load:i64 %0 #0x3 @0x1000
        \\  setreg %1 #0x10
        \\  call.interp @0x1004
        \\  %2 = getreg:i64 #0x8
        \\  setreg %2 #0x18
        \\  setreg %1 #0x18
        \\  exit.chain #0x1008
        \\
    );
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\region 0x1000
        \\handle 0x0
        \\b0:
        \\  %0 = getreg:i64 #0x8
        \\  setreg %0 #0x10
        \\  %2 = load:i64 %0 #0x3 @0x1000
        \\  setreg %2 #0x10
        \\  call.interp @0x1004
        \\  setreg %2 #0x18
        \\  exit.chain #0x1008
        \\
    , got);
}

test "opt: an fp op that ORs into FPSR reads and writes it" {
    // FPSR at 0x40: the fp.add's aux2 is 0x41.
    const got = try optimized(
        \\region 0x1000
        \\b0:
        \\  %0 = getreg:i64 #0x8
        \\  %1 = const:i32
        \\  setreg %1 #0x40
        \\  %2 = fp.add:i64 %0, %0 @0x41
        \\  %3 = getreg:i32 #0x40
        \\  setreg %3 #0x48
        \\  setreg %2 #0x8
        \\  setreg %1 #0x40
        \\  exit.chain #0x1004
        \\
    );
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\region 0x1000
        \\b0:
        \\  %0 = getreg:i64 #0x8
        \\  %1 = const:i32
        \\  setreg %1 #0x40
        \\  %3 = fp.add:i64 %0, %0 @0x41
        \\  %4 = getreg:i32 #0x40
        \\  setreg %4 #0x48
        \\  setreg %3 #0x8
        \\  setreg %1 #0x40
        \\  exit.chain #0x1004
        \\
    , got);
}

test "opt: conditions on a subtract's flags become comparisons" {
    const preds = [_]struct { cc: u8, x86: bool }{
        .{ .cc = 0, .x86 = false },  .{ .cc = 1, .x86 = false },  .{ .cc = 2, .x86 = false },  .{ .cc = 3, .x86 = false },
        .{ .cc = 8, .x86 = false },  .{ .cc = 9, .x86 = false },  .{ .cc = 10, .x86 = false }, .{ .cc = 11, .x86 = false },
        .{ .cc = 12, .x86 = false }, .{ .cc = 13, .x86 = false }, .{ .cc = 2, .x86 = true },   .{ .cc = 3, .x86 = true },
        .{ .cc = 4, .x86 = true },   .{ .cc = 5, .x86 = true },   .{ .cc = 6, .x86 = true },   .{ .cc = 7, .x86 = true },
        .{ .cc = 12, .x86 = true },  .{ .cc = 13, .x86 = true },  .{ .cc = 14, .x86 = true },  .{ .cc = 15, .x86 = true },
    };
    // Each mapping agrees with the flags' own condition on edge values.
    const vals = [_]u64{ 0, 1, 2, 0x7f, 0x80, 0xff, 0x7fff_ffff, 0x8000_0000, 0xffff_ffff, 0x7fff_ffff_ffff_ffff, 0x8000_0000_0000_0000, 0xffff_ffff_ffff_ffff };
    for (preds) |pc| for ([_]ir.Type{ .i8, .i32, .i64 }) |ty| {
        if (!pc.x86 and ty == .i8) continue;
        if (pc.x86 and ty == .i64) continue;
        const pred = (if (pc.x86) subPredX86(pc.cc) else subPredA64(pc.cc)).?;
        for (vals) |a| for (vals) |b| {
            const x = a & ty.mask();
            const y = b & ty.mask();
            const fop: ir.Op = if (pc.x86) .@"eflags.sub" else .@"nzcv.sub";
            const cop: ir.Op = if (pc.x86) .@"eflags.cond" else .@"nzcv.cond";
            const f = ir_eval.evalPure(fop, .flags, ty, x, y, 0, 0);
            const want = ir_eval.evalPure(cop, .i1, .flags, f, 0, 0, pc.cc);
            const got = ir_eval.evalPure(.icmp, .i1, ty, x, y, 0, @intFromEnum(pred));
            try testing.expectEqual(want, got);
        };
    };
}
