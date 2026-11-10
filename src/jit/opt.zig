//! Optimizations on a lifted region, before allocation and emission. All
//! work within a block (values are block-local) and keep the IR's rules
//! (README.md): guest state exact at every operation that can leave, and
//! ctx.retired exact at every exit (the counts ride on the leaving ops,
//! which no pass moves or drops).
//!
//! - **Register forwarding.** A `getreg` of a Cpu slot the block already
//!   read or wrote at the same width takes that value instead. A call out
//!   (`call.interp`, `call.helper`) or a `copy` may change the Cpu, and
//!   forgets them.
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
//! - **Same-page hints.** A load or store whose address is an earlier
//!   load's or store's (the same op) plus or minus less than a page gets
//!   MemFlags.same_page pointing at it, so an emitter can reuse that
//!   access's TLB lookup after one compare. It's only a hint: the emitter
//!   checks the page and does the full lookup if it differs.

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
    samePage(r);
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
            // A copy reads and writes Cpu slots (its fields, NZCV, FPSR).
            .@"call.interp", .@"call.helper", .copy => nk = 0,
            .brcond => if (constOf(insts, i.a)) |c| {
                i.* = .{ .op = .br, .aux = if (c & 1 == 1) i.aux else i.aux2 };
            },
            else => if (i.op.isPure()) {
                fold(insts, blk.start, idx, repl);
            } else if (excWord(i.*)) |w| forget(&known, &nk, w, 4),
        }
    }
}

fn constOf(insts: []const Inst, x: Ref) ?u64 {
    if (x == none) return null;
    const d = insts[x];
    return if (d.op == .@"const") d.aux else null;
}

fn fold(insts: []Inst, start: usize, idx: usize, repl: []Ref) void {
    const i = &insts[idx];
    if (i.op == .@"const") return;
    const ca = constOf(insts, i.a);
    const cb = constOf(insts, i.b);
    const cc = constOf(insts, i.c);
    const all = (i.a == none or ca != null) and (i.b == none or cb != null) and (i.c == none or cc != null);
    if (all and !lazyRecorded(insts, idx)) {
        const ta: ir.Type = if (i.a != none) insts[i.a].ty else .none;
        const v = ir_eval.evalPure(i.op, i.ty, ta, ca orelse 0, cb orelse 0, cc orelse 0, i.aux);
        i.* = .{ .op = .@"const", .ty = i.ty, .aux = if (i.ty == .flags) v else v & i.ty.mask() };
        return;
    }
    switch (i.op) {
        .@"nzcv.cond", .@"eflags.cond" => if (compareOf(insts, start, idx)) |cmp| {
            i.* = .{ .op = .icmp, .ty = .i1, .a = cmp.a, .b = cmp.b, .aux = @intFromEnum(cmp.pred) };
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

/// Whether a lazy pending.flags (aux2 = 2) in the block takes flags op
/// idx: its record needs the op's operands, so it stays an op.
fn lazyRecorded(insts: []const Inst, idx: usize) bool {
    if (insts[idx].ty != .flags or ir.lazyKind(insts[idx].op) == null) return false;
    for (insts[idx + 1 ..]) |x| {
        if (x.op == .@"pending.flags" and x.aux2 == 2 and x.a == idx) return true;
        if (x.op.isTerminator()) break;
    }
    return false;
}

const Compare = struct { pred: ir.Pred, a: Ref, b: Ref };

/// The comparison a condition on flags (`insts[idx]`, an `nzcv.cond` or
/// `eflags.cond`) makes, if it's one: of a subtract's operands; of a
/// decrement's operand and 1; or of a logic result and 0. The constant is
/// one the block already has before `idx` (the lifters make the 1 for
/// the decrement itself).
fn compareOf(insts: []const Inst, start: usize, idx: usize) ?Compare {
    const i = insts[idx];
    const f = insts[i.a];
    const x86 = i.op == .@"eflags.cond";
    // A condition only means a comparison on its own group's flags: an
    // eflags.cond of an nzcv value reads bits nzcv never sets.
    const f_x86 = switch (f.op) {
        .@"eflags.sub", .@"eflags.dec", .@"eflags.logic" => true,
        else => false,
    };
    if (f_x86 != x86) return null;
    switch (f.op) {
        .@"nzcv.sub", .@"eflags.sub" => {
            const p = (if (x86) subPredX86(i.aux) else subPredA64(i.aux)) orelse return null;
            return .{ .pred = p, .a = f.a, .b = f.b };
        },
        .@"eflags.dec" => {
            // a - 1, with OF at the most negative a: the signed conditions
            // compare a with 1 exactly; S and NS don't.
            const p: ir.Pred = switch (i.aux) {
                4 => .eq,
                5 => .ne,
                12 => .slt,
                13 => .sge,
                14 => .sle,
                15 => .sgt,
                else => return null,
            };
            const one = findConst(insts, start, idx, insts[f.a].ty, 1) orelse return null;
            return .{ .pred = p, .a = f.a, .b = one };
        },
        .@"nzcv.logic", .@"eflags.logic" => {
            // N and Z from the result; C and V clear.
            const p: ir.Pred = if (x86) switch (i.aux) {
                4, 6 => .eq, // E, BE
                5, 7 => .ne, // NE, A
                8, 12 => .slt, // S, L
                9, 13 => .sge, // NS, GE
                14 => .sle,
                15 => .sgt,
                else => return null,
            } else switch (i.aux) {
                0 => .eq,
                1 => .ne,
                4, 11 => .slt, // MI, LT
                5, 10 => .sge, // PL, GE
                12 => .sgt,
                13 => .sle,
                else => return null,
            };
            const zero = findConst(insts, start, idx, insts[f.a].ty, 0) orelse return null;
            return .{ .pred = p, .a = f.a, .b = zero };
        },
        else => return null,
    }
}

/// A `const` of type `ty` and value `v` in [start, idx), if there's one.
fn findConst(insts: []const Inst, start: usize, idx: usize, ty: ir.Type, v: u64) ?Ref {
    var j = idx;
    while (j > start) {
        j -= 1;
        const c = insts[j];
        if (c.op == .@"const" and c.ty == ty and c.aux == v) return @intCast(j);
    }
    return null;
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

/// Marks `setreg`s and `pending.flags` a later write in the block makes
/// unobservable before anything can see the slot.
///
/// A `setreg` overwrites its bytes. A `pending.flags` of kind 0 or 1 only
/// merges its mask into the word at aux, keeping the other bits, so it
/// covers nothing but an earlier pending.flags of the same kind at the same
/// offset (one of another kind is written first). Kind 2 overwrites the
/// 16-byte record at aux + 4, so it covers writes inside that, and an
/// earlier kind 2 at the same offset.
fn deadWrites(r: *ir.Region, blk: ir.Block, dead: []bool) void {
    const W = struct {
        off: u64,
        size: u32,
        /// A full overwrite of [off, off+size), or a pending.flags merge
        /// of this kind at off.
        merge: ?u64,
    };
    // Writes later in the block, with no barrier since.
    var later: [64]W = undefined;
    var nl: usize = 0;
    const insts = r.insts.items;
    var idx = blk.start + blk.len;
    while (idx > blk.start) {
        idx -= 1;
        const i = insts[idx];
        if (i.op.canLeave() or i.op == .@"call.interp" or i.op == .@"call.helper" or i.op == .copy or i.op.isTerminator()) {
            nl = 0;
            continue;
        }
        // What this write does, as a W.
        const w: ?W = switch (i.op) {
            .setreg => .{ .off = i.aux, .size = sizeOf(insts[i.a].ty), .merge = null },
            .@"pending.flags" => if (i.aux2 == 2)
                .{ .off = i.aux + 4, .size = 16, .merge = null }
            else
                .{ .off = i.aux, .size = 4, .merge = i.aux2 },
            else => null,
        };
        if (w) |me| {
            const covered = for (later[0..nl]) |k| {
                if (k.merge) |km| {
                    // A merge covers only the same merge.
                    if (me.merge != null and me.merge.? == km and me.off == k.off) break true;
                } else if (k.off <= me.off and me.off + me.size <= k.off + k.size) {
                    // A full overwrite covers what's inside it, merge or not.
                    break true;
                }
            } else false;
            if (covered) {
                dead[idx] = true;
            } else if (nl < later.len) {
                later[nl] = me;
                nl += 1;
            }
            continue;
        }
        switch (i.op) {
            .getreg => forgetW(W, &later, &nl, i.aux, sizeOf(i.ty)),
            else => if (excWord(i)) |x| forgetW(W, &later, &nl, x, 4),
        }
    }
}

fn forgetW(comptime W: type, list: []W, n: *usize, off: u64, size: u32) void {
    var j: usize = 0;
    while (j < n.*) {
        if (overlaps(list[j].off, list[j].size, off, size)) {
            list[j] = list[n.* - 1];
            n.* -= 1;
        } else j += 1;
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

/// An address as a root value plus a constant: through `add` and `sub`
/// of constants, a few deep.
const Addr = struct { root: Ref, off: i64 };

fn addrOf(insts: []const Inst, a: Ref) Addr {
    var v = a;
    var off: i64 = 0;
    for (0..4) |_| {
        const d = insts[v];
        if (d.op != .add and d.op != .sub) break;
        const c = constOf(insts, d.b) orelse break;
        const k: i64 = @bitCast(c);
        off = if (d.op == .add) off +% k else off -% k;
        v = d.a;
    }
    return .{ .root = v, .off = off };
}

/// Sets MemFlags.same_page on each load and store whose address is within
/// a page of an earlier one's in the block, from the same root. Runs
/// after `compact`, since the hint is a distance in instructions.
fn samePage(r: *ir.Region) void {
    const insts = r.insts.items;
    for (r.blocks.items) |blk| {
        const end = blk.start + blk.len;
        for (blk.start..end) |idx| {
            const i = &insts[idx];
            if (i.op != .load and i.op != .store) continue;
            var f: ir.MemFlags = @bitCast(i.aux);
            if (f.same_page != 0) continue;
            const me = addrOf(insts, i.a);
            var j = idx;
            while (j > blk.start and idx - j < std.math.maxInt(u16)) {
                j -= 1;
                const p = insts[j];
                if (p.op != i.op) continue;
                const them = addrOf(insts, p.a);
                if (them.root != me.root) continue;
                const d = me.off -% them.off;
                if (d > -4096 and d < 4096) {
                    f.same_page = @intCast(idx - j);
                    i.aux = @bitCast(f);
                }
                break;
            }
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

test "opt: a copy reads and writes the Cpu, so it forgets and keeps writes" {
    // add x2, x1, ... as a copy: it reads 0x8 and writes 0x10.
    const text =
        \\region 0x1000
        \\b0:
        \\  %0 = const:i64 #0x5
        \\  setreg %0 #0x8
        \\  setreg %0 #0x10
        \\  copy #0x8b000020 @0x20084010
        \\  %4 = getreg:i64 #0x10
        \\  setreg %4 #0x18
        \\  setreg %0 #0x8
        \\  exit.chain #0x1008
        \\
    ;
    const got = try optimized(text);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(text, got);
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

test "opt: conditions on a subtract's, a decrement's, or a logic op's flags become comparisons" {
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

test "opt: decrement and logic conditions agree with the flags" {
    const vals = [_]u64{ 0, 1, 2, 0x7f, 0x80, 0xff, 0x7fff_ffff, 0x8000_0000, 0xffff_ffff, 0x7fff_ffff_ffff_ffff, 0x8000_0000_0000_0000, 0xffff_ffff_ffff_ffff };
    const Case = struct { fop: ir.Op, cop: ir.Op, c: u64, ccs: []const u8, tys: []const ir.Type };
    const cases = [_]Case{
        .{ .fop = .@"eflags.dec", .cop = .@"eflags.cond", .c = 1, .ccs = &.{ 4, 5, 12, 13, 14, 15 }, .tys = &.{ .i8, .i16, .i32 } },
        .{ .fop = .@"eflags.logic", .cop = .@"eflags.cond", .c = 0, .ccs = &.{ 4, 5, 6, 7, 8, 9, 12, 13, 14, 15 }, .tys = &.{ .i8, .i16, .i32 } },
        .{ .fop = .@"nzcv.logic", .cop = .@"nzcv.cond", .c = 0, .ccs = &.{ 0, 1, 4, 5, 10, 11, 12, 13 }, .tys = &.{ .i32, .i64 } },
    };
    var insts: [4]Inst = undefined;
    for (cases) |cs| for (cs.tys) |ty| for (cs.ccs) |cc| {
        insts[0] = .{ .op = .getreg, .ty = ty };
        insts[1] = .{ .op = .@"const", .ty = ty, .aux = cs.c };
        insts[2] = .{ .op = cs.fop, .ty = .flags, .a = 0, .b = if (cs.fop == .@"eflags.dec") 1 else none };
        insts[3] = .{ .op = cs.cop, .ty = .i1, .a = 2, .aux = cc };
        const cmp = compareOf(&insts, 0, 3).?;
        try testing.expectEqual(@as(Ref, 0), cmp.a);
        try testing.expectEqual(@as(Ref, 1), cmp.b);
        for (vals) |a| {
            const x = a & ty.mask();
            // The incoming flags for dec: carry set, which dec keeps.
            const f = ir_eval.evalPure(cs.fop, .flags, ty, x, ir_eval.CF, 0, 0);
            const want = ir_eval.evalPure(cs.cop, .i1, .flags, f, 0, 0, cc);
            const got = ir_eval.evalPure(.icmp, .i1, ty, x, cs.c, 0, @intFromEnum(cmp.pred));
            testing.expectEqual(want, got) catch |e| {
                std.debug.print("{t} {t} cc {d} a {x}\n", .{ cs.fop, ty, cc, x });
                return e;
            };
        }
    };
}

test "opt: same-page hints for nearby accesses from one base" {
    const got = try optimized(
        \\region 0x1000
        \\handle 0x0
        \\b0:
        \\  %0 = getreg:i64 #0x8
        \\  %1 = load:i64 %0 #0x3 @0x1000
        \\  %2 = const:i64 #0x8
        \\  %3 = add:i64 %0, %2
        \\  %4 = load:i64 %3 #0x3 @0x1004
        \\  %5 = const:i64 #0x2000
        \\  %6 = add:i64 %0, %5
        \\  %7 = load:i64 %6 #0x3 @0x1008
        \\  store %3, %4 #0x3 @0x100c
        \\  store %0, %7 #0x3 @0x1010
        \\  setreg %1 #0x10
        \\  exit.chain #0x1014
        \\
    );
    defer testing.allocator.free(got);
    var r = try ir.parse(testing.allocator, got);
    defer r.deinit(testing.allocator);
    var hints: [5]u16 = undefined;
    var n: usize = 0;
    for (r.insts.items) |i| if (i.op == .load or i.op == .store) {
        hints[n] = @as(ir.MemFlags, @bitCast(i.aux)).same_page;
        n += 1;
    };
    // The second load is 3 back from the first; the third is a page off;
    // the second store names the first, one back.
    try testing.expectEqualSlices(u16, &.{ 0, 3, 0, 0, 1 }, hints[0..n]);
}

test "opt: a pending.flags a later write covers goes, and covers an earlier setreg" {
    const got = try optimized(
        \\region 0x1000
        \\b0:
        \\  %0 = getreg:i64 #0x8
        \\  %1 = const:i64 #0x1
        \\  %2 = nzcv.sub:flags %0, %1
        \\  %3 = const:i32
        \\  setreg %3 #0x350
        \\  pending.flags %2 #0x350
        \\  %4 = nzcv.pack:i32 %2
        \\  setreg %4 #0x350
        \\  exit.chain #0x1004
        \\
    );
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\region 0x1000
        \\b0:
        \\  %0 = getreg:i64 #0x8
        \\  %1 = const:i64 #0x1
        \\  %2 = nzcv.sub:flags %0, %1
        \\  %3 = nzcv.pack:i32 %2
        \\  setreg %3 #0x350
        \\  exit.chain #0x1004
        \\
    , got);
}

test "opt: a lazy pending.flags keeps its flags op, constant operands and all" {
    const gpa = std.testing.allocator;
    var r = try ir.parse(gpa,
        \\b0:
        \\  %0 = const:i32 #0x5
        \\  %1 = const:i32 #0x7
        \\  %2 = eflags.sub:flags %0, %1
        \\  pending.flags %2 #0x10 @0x2
        \\  exit.chain #0x0
    );
    defer r.deinit(gpa);
    try run(gpa, &r);
    try std.testing.expect(ir.verify(&r) == null);
    const p = for (r.insts.items) |x| {
        if (x.op == .@"pending.flags") break x;
    } else unreachable;
    try std.testing.expectEqual(ir.Op.@"eflags.sub", r.insts.items[p.a].op);
}

test "opt: pending.flags of another kind at one word isn't covered" {
    // eflags then nzcv at 0x30: both merges stay (ir_eval writes both).
    const got = try optimized(
        \\region 0x1000
        \\b0:
        \\  %0 = getreg:i32 #0x8
        \\  %1 = eflags.logic:flags %0
        \\  pending.flags %1 #0x30 @0x1
        \\  %3 = nzcv.logic:flags %0
        \\  pending.flags %3 #0x30
        \\  exit.chain #0x1004
        \\
    );
    defer testing.allocator.free(got);
    try testing.expect(std.mem.count(u8, got, "pending.flags") == 2);
}

test "opt: a pending.flags merge doesn't cover an earlier setreg" {
    const got = try optimized(
        \\region 0x1000
        \\b0:
        \\  %0 = const:i32 #0x202
        \\  setreg %0 #0x30
        \\  %2 = getreg:i32 #0x8
        \\  %3 = eflags.logic:flags %2
        \\  pending.flags %3 #0x30 @0x1
        \\  exit.chain #0x1004
        \\
    );
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "setreg") != null);
}

test "opt: a condition on the other group's flags isn't folded" {
    const got = try optimized(
        \\region 0x1000
        \\b0:
        \\  %0 = getreg:i64 #0x8
        \\  %1 = nzcv.sub:flags %0, %0
        \\  %2 = eflags.cond:i1 %1 #0x4
        \\  brcond %2 -> b1 b2
        \\b1:
        \\  exit.chain #0x1
        \\b2:
        \\  exit.chain #0x2
        \\
    );
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "icmp") == null);
}
