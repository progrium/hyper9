//! IR to wasm, for the browser host (and Node).
//!
//! A batch of regions becomes one module. Each region is an exported
//! `ctx.EntryFn` ("r0", "r1", ...); h9-web.js's h9_jit_compile installs
//! them into h9.wasm's function table, so the runtime calls a region
//! through a plain function pointer and regions reach each other with
//! tail calls through the same table. A batch of one also exports "run".
//!
//! **Two layouts.** By default (`Layout.functions`) each region is a wasm
//! function of its own, exported directly; a chain to another region,
//! in this module or not, is a `return_call_indirect` through a chain cell
//! (below). With `Layout.br_table` every region's code is in one function,
//! entered through a `br_table` on the region's index, and the exports are
//! one-line wrappers that tail-call it; a chain to a region in the same
//! batch is then a branch back to that `br_table`, with no call at all.
//! The first is the default because V8 compiles and tiers up functions one
//! at a time: a hot loop in a 1,000-region br_table function runs at
//! baseline speed for most of a second while TurboFan compiles the lot
//! (tests/jit/bench.mjs). Anything without a linked chain returns to the
//! runtime.
//!
//! **Guest registers live in locals.** Every `getreg`/`setreg` offset the
//! function uses at one width, and that no other access overlaps, gets a local,
//! loaded from the Cpu on entry and written back on every way out: one
//! shared exit path, before `call.interp` and `call.helper` (which reload
//! all of them after). IR values don't each get a local: values used once
//! are computed where they're used (wasm expression trees), constants and
//! register reads are rematerialized, dead pure ops are dropped, and the
//! rest share a pool of locals by liveness within their block. Values of
//! types up to i32 are wasm i32s; i64 and flags are i64s.
//!
//! **Structured control flow.** A reducible region (which is every region
//! a lifter makes) lowers to nested `block`s and `loop`s by Ramsey's
//! algorithm ("Beyond Relooper", 2022): dominator tree, loop headers, merge
//! points. An irreducible one falls back to a dispatch loop around a
//! `br_table` on the block index.
//!
//! **Chain cells.** With `Options.cells`, each distinct `exit.chain` target
//! has a u32 cell in linear memory (`Batch.chains` says which PC each
//! is for): 0 means unlinked (the region leaves with `.chain`), otherwise
//! it's the table slot of the region to tail-call. The runtime writes and
//! clears cells as regions come and go. In the br_table layout, a cell
//! holding this module's own slot for a region in the batch takes the
//! in-function branch instead.
//!
//! Imports, all from "env", provided by the module that owns memory (h9.wasm
//! in the browser, tests/jit/wasm_runtime.zig under Node):
//!
//! | name | type | is |
//! | --- | --- | --- |
//! | memory | memory | linear memory with Ctx, the Cpu, the TLB, and guest RAM |
//! | eval | (i64 code, i64 a, i64 b, i64 c, i64 aux) -> i64 | ir_eval.evalOpC |
//! | slow_load | (i32 ctx, i64 va, i32 size_log2) -> i32 | mem.SlowLoadFn |
//! | slow_store | (i32 ctx, i64 va, i32 size_log2, i64 v) -> i32 | mem.SlowStoreFn |
//! | interp | (i32 ctx, i64 handle, i64 pc) -> i32 | ctx.InterpFn |
//! | helper | (i32 ctx, i64 index, i64 a, i64 b, i64 c) -> i64 | the helper table |
//! | slow_cas | (i32 ctx, i64 va, i32 size_log2, i64 expected, i64 new) -> i32 | mem.SlowCasFn |
//! | ext | (i32 ctx, i64 code, i32 io, i64 aux, i64 aux2) | ir_eval.evalExtC, for FP and vector ops |
//! | table | table funcref | the function table regions are installed in (with cells only) |
//! | base | global i32 | the table slot of "r0"; "rK" is at base + K (with cells only) |
//!
//! It uses wasm 2.0 and tail calls (Chrome 112, Firefox 121, Safari 18.2,
//! Node 20).

const std = @import("std");
const ir = @import("../ir.zig");
const ir_eval = @import("../ir_eval.zig");
const ctx = @import("../ctx.zig");
const mem = @import("../../interp/mem.zig");
const alloc_mod = @import("../alloc.zig");
const emitter = @import("../emitter.zig");
const Op = ir.Op;
const Type = ir.Type;
const Ref = ir.Ref;
const BlockId = ir.BlockId;
const EmitError = emitter.EmitError;
const Allocator = std.mem.Allocator;

pub const emitter_def: emitter.Emitter = .{ .name = "wasm", .lazy_eflags = true, .emit = emit };

pub const Options = struct {
    /// The address in linear memory of the batch's chain cells, a u32 per
    /// entry of `Batch.chains`. 0: no chaining, and the module imports no
    /// table.
    cells: u32 = 0,
    /// Keep guest registers in locals.
    promote: bool = true,
    /// Lower control flow to blocks and loops; false always uses the
    /// dispatch loop (for tests).
    structured: bool = true,
    layout: Layout = .functions,
    /// With cells: a chain whose cell is 0, and an indirect branch, look
    /// their target up in the vCPU's jump cache (ctx.jump, whose entries'
    /// `code` the runtime sets to a table slot) and tail-call it on a hit.
    jump: bool = false,
    /// The address of 48 bytes, 16-aligned, where an FP or vector op that
    /// isn't lowered stages its operands for `ext` (ir_eval.evalExtC). 0:
    /// such ops are unsupported.
    ext_io: u32 = 0,
    /// With cells: the address of the helper table (ctx.helpers), read
    /// while emitting, so a call.helper names its table slot as a
    /// constant. 0: the code reads it from ctx.helpers.
    helpers: u32 = 0,
};

pub const Layout = enum {
    /// A function per region. V8 compiles and tiers up each on its own,
    /// so a hot region doesn't drag its batch through the optimizing
    /// compiler. A chain within the batch is a tail call.
    functions,
    /// One function behind a br_table on the region's index, so a chain
    /// within the batch is a branch. Optimizing it costs superlinear time
    /// in its size (see tests/jit/bench.mjs).
    br_table,
};

pub const Batch = struct {
    /// Chain cell k's target guest PC.
    chains: std.ArrayList(u64) = .empty,
    /// How many regions lowered structured, and how many fell back to the
    /// dispatch loop.
    structured: u32 = 0,
    dispatched: u32 = 0,

    pub fn deinit(b: *Batch, gpa: Allocator) void {
        b.chains.deinit(gpa);
    }
};

/// One region as a module: the emitter.Emitter interface. Its export "run"
/// (and "r0") is the entry. The allocation is unused: wasm has its own.
pub fn emit(gpa: Allocator, r: *const ir.Region, _: *const alloc_mod.Allocation, out: *std.ArrayList(u8)) EmitError!emitter.Code {
    var b: Batch = .{};
    defer b.deinit(gpa);
    try emitBatch(gpa, &.{r}, .{}, out, &b);
    return .{ .entry = 0 };
}

// ---------------------------------------------------------------- encoding

const I32 = 0x7F;
const I64 = 0x7E;
const V128 = 0x7B;
const VOID = 0x40;

// Function indexes: the imports, then the body, then the wrappers.
const F_EVAL = 0;
const F_SLOW_LOAD = 1;
const F_SLOW_STORE = 2;
const F_INTERP = 3;
const F_HELPER = 4;
const F_SLOW_CAS = 5;
const F_EXT = 6;
const F_BODY = 7;

// Type indexes.
const T_ENTRY = 0;
const T_BODY = 6;
const T_HELPER = 9;

const W = struct {
    gpa: Allocator,
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
    fn i32c(w: *W, v: u32) !void {
        try w.byte(0x41);
        try w.sleb(@as(i32, @bitCast(v)));
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
    /// A SIMD instruction (the 0xFD prefix).
    fn simd(w: *W, op: u32) !void {
        try w.byte(0xFD);
        try w.uleb(op);
    }
    fn call(w: *W, f: u32) !void {
        try w.byte(0x10);
        try w.uleb(f);
    }
    fn section(w: *W, id: u8, body: []const u8) !void {
        try w.byte(id);
        try w.uleb(body.len);
        try w.bytes(body);
    }
    fn name(w: *W, s: []const u8) !void {
        try w.uleb(s.len);
        try w.bytes(s);
    }
};

/// The wasm type an IR type's values have, or null if it has none yet.
fn wt(t: Type) ?u8 {
    return switch (t) {
        .i1, .i8, .i16, .i32 => I32,
        .i64, .flags => I64,
        .v128 => V128,
        else => null,
    };
}

fn is64(t: Type) bool {
    return t == .i64 or t == .flags;
}

fn byteSize(t: Type) ?u32 {
    return switch (t) {
        .i8 => 1,
        .i16 => 2,
        .i32 => 4,
        .i64, .flags => 8,
        .v128 => 16,
        else => null,
    };
}

// i32 and i64 opcodes for the binary ops; the i32 ones are 0x12 lower.
fn binop64(op: Op) u8 {
    return switch (op) {
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
}

// eq ne lt_u le_u gt_u ge_u lt_s le_s gt_s ge_s, for i64; i32 is 0x0B lower.
const cmp64 = [_]u8{ 0x51, 0x52, 0x54, 0x58, 0x56, 0x5A, 0x53, 0x57, 0x55, 0x59 };

// ---------------------------------------------------------------- planning

/// How an instruction is emitted.
const Kind = enum(u8) {
    /// Not at all: a pure op or register read nothing uses.
    dead,
    /// At its position, its result (if used) in a pool local.
    root,
    /// Where its one use is, as part of that use's expression.
    inl,
    /// A constant, emitted at each use.
    konst,
    /// A read of a promoted register no write clobbers before its last
    /// use: `local.get` of the register at each use.
    alias,
};

const Plan = struct {
    kind: []Kind,
    /// Whether a root's result is used.
    used: []bool,
    /// For roots with a used result: the pool local, numbered within its
    /// wasm type's pool.
    loc: []u32,

    fn deinit(p: *Plan, gpa: Allocator) void {
        gpa.free(p.kind);
        gpa.free(p.used);
        gpa.free(p.loc);
    }
};

const Reg = struct {
    off: u32,
    ty: Type,
    /// The widest access's size in bytes.
    size: u32,
    local: u32 = 0,
    written: bool = false,
    bad: bool = false,
};

/// Whether instruction k can change guest register bytes [off, off+n),
/// as seen through a getreg.
fn clobbers(r: *const ir.Region, k: usize, off: u64, n: u64) bool {
    const i = r.insts.items[k];
    return switch (i.op) {
        .@"call.interp", .copy => true,
        .@"call.helper" => i.aux2 & ir.helper_no_regs == 0,
        .setreg => blk: {
            const m = byteSize(r.insts.items[i.a].ty) orelse 8;
            break :blk i.aux < off + n and off < i.aux + m;
        },
        // An FP op ORs the exceptions it raises into a u32 in the Cpu.
        else => i.op.isFp() and i.aux2 != 0 and i.aux2 - 1 < off + n and off < i.aux2 - 1 + 4,
    };
}

const Pools = struct {
    free32: std.ArrayList(u32) = .empty,
    free64: std.ArrayList(u32) = .empty,
    free128: std.ArrayList(u32) = .empty,
    n32: u32 = 0,
    n64: u32 = 0,
    n128: u32 = 0,

    fn list(p: *Pools, w: u8) *std.ArrayList(u32) {
        return switch (w) {
            I32 => &p.free32,
            I64 => &p.free64,
            else => &p.free128,
        };
    }
    fn count(p: *Pools, w: u8) *u32 {
        return switch (w) {
            I32 => &p.n32,
            I64 => &p.n64,
            else => &p.n128,
        };
    }
    fn take(p: *Pools, w: u8) u32 {
        if (p.list(w).pop()) |x| return x;
        const n = p.count(w);
        n.* += 1;
        return n.* - 1;
    }
    fn give(p: *Pools, gpa: Allocator, w: u8, x: u32) !void {
        try p.list(w).append(gpa, x);
    }
    fn deinit(p: *Pools, gpa: Allocator) void {
        p.free32.deinit(gpa);
        p.free64.deinit(gpa);
        p.free128.deinit(gpa);
    }
};

fn planRegion(gpa: Allocator, r: *const ir.Region, promoted: *const std.AutoHashMapUnmanaged(u32, u32), regs: []const Reg, pools: *Pools) !Plan {
    const n = r.insts.items.len;
    var p: Plan = .{ .kind = try gpa.alloc(Kind, n), .used = try gpa.alloc(bool, n), .loc = try gpa.alloc(u32, n) };
    errdefer p.deinit(gpa);
    @memset(p.kind, .root);
    @memset(p.used, false);
    @memset(p.loc, 0);
    const uses = try gpa.alloc(u32, n);
    defer gpa.free(uses);
    const root = try gpa.alloc(u32, n); // the position an instruction is emitted at
    defer gpa.free(root);
    const last = try gpa.alloc(u32, n); // where a value is last used
    defer gpa.free(last);
    const dies = try gpa.alloc(u32, n); // values whose last use is here, linked through next
    defer gpa.free(dies);
    const next = try gpa.alloc(u32, n);
    defer gpa.free(next);
    const nil = std.math.maxInt(u32);

    for (r.blocks.items) |blk| {
        const s = blk.start;
        const e = blk.start + blk.len;
        for (s..e) |k| {
            uses[k] = 0;
            last[k] = 0;
            dies[k] = nil;
        }
        for (r.insts.items[s..e]) |i| {
            for (i.operands()) |o| if (o != ir.none) {
                uses[o] += 1;
            };
            for (extraOps(r, i)) |o| if (o != ir.none) {
                uses[o] += 1;
            };
        }
        // Backward: what's dead, what's inlined where, and where each value
        // is last used.
        var k = e;
        while (k > s) {
            k -= 1;
            const i = r.insts.items[k];
            const has = i.ty != .none;
            if (p.kind[k] == .inl) {
                // root[k] was set by its user.
            } else if (has and uses[k] == 0 and (i.op.isPure() or i.op == .getreg)) {
                p.kind[k] = .dead;
                for (i.operands()) |o| if (o != ir.none) {
                    uses[o] -= 1;
                };
                continue;
            } else if (i.op == .@"const") {
                p.kind[k] = .konst;
                continue;
            } else if (i.op == .getreg and promoted.contains(@intCast(i.aux))) {
                p.kind[k] = .alias;
                const reg = regs[promoted.get(@intCast(i.aux)).?];
                for (k + 1..last[k]) |j| if (p.kind[j] == .root and clobbers(r, j, reg.off, reg.size)) {
                    p.kind[k] = .root;
                    break;
                };
                if (p.kind[k] == .alias) continue;
                root[k] = @intCast(k);
            } else root[k] = @intCast(k);
            const xs = extraOps(r, i);
            for (i.operands() ++ xs) |o| {
                if (o == ir.none) continue;
                last[o] = @max(last[o], root[k]);
                if (uses[o] != 1) continue;
                const d = r.insts.items[o];
                const ok = if (d.op == .@"const")
                    false
                else if (d.op.isPure())
                    true
                else if (d.op == .getreg and !promoted.contains(@intCast(d.aux))) blk: {
                    const sz = byteSize(d.ty).?;
                    for (o + 1..root[k]) |j| if (p.kind[j] == .root and clobbers(r, j, d.aux, sz)) break :blk false;
                    break :blk true;
                } else false;
                if (ok) {
                    p.kind[o] = .inl;
                    root[o] = root[k];
                }
            }
        }
        // Forward: pool locals for the roots' results.
        for (s..e) |j| if (p.kind[j] == .root and r.insts.items[j].ty != .none and uses[j] > 0) {
            next[j] = dies[last[j]];
            dies[last[j]] = @intCast(j);
        };
        for (s..e) |j| {
            if (p.kind[j] != .root) continue;
            var d = dies[j];
            while (d != nil) : (d = next[d]) try pools.give(gpa, wt(r.insts.items[d].ty).?, p.loc[d]);
            const i = r.insts.items[j];
            if (i.ty != .none and uses[j] > 0) {
                p.used[j] = true;
                p.loc[j] = pools.take(wt(i.ty) orelse return error.Unsupported);
            }
        }
    }
    return p;
}

// ---------------------------------------------------------------- control flow

const Cfg = struct {
    /// Blocks in reverse postorder, from block 0; unreachable ones are left out.
    order: []BlockId,
    /// A block's index in `order`, or `unreached`.
    rpo: []u32,
    idom: []BlockId,
    header: []bool,
    merge: []bool,
    /// Dominator-tree children, in reverse postorder: kids[kid_start[b]..kid_start[b+1]].
    kids: []BlockId,
    kid_start: []u32,
    reducible: bool,

    const unreached = std.math.maxInt(u32);

    fn deinit(c: *Cfg, gpa: Allocator) void {
        gpa.free(c.order);
        gpa.free(c.rpo);
        gpa.free(c.idom);
        gpa.free(c.header);
        gpa.free(c.merge);
        gpa.free(c.kids);
        gpa.free(c.kid_start);
    }
};

/// A block's successors: none, one, or two (a brcond to one block twice
/// is one).
fn succs(r: *const ir.Region, b: BlockId) struct { [2]BlockId, u32 } {
    const blk = r.blocks.items[b];
    const t = r.insts.items[blk.start + blk.len - 1];
    return switch (t.op) {
        .br => .{ .{ @intCast(t.aux), 0 }, 1 },
        .brcond => if (t.aux == t.aux2) .{ .{ @intCast(t.aux), 0 }, 1 } else .{ .{ @intCast(t.aux), @intCast(t.aux2) }, 2 },
        else => .{ .{ 0, 0 }, 0 },
    };
}

fn analyze(gpa: Allocator, r: *const ir.Region) !Cfg {
    const n = r.blocks.items.len;
    const rpo = try gpa.alloc(u32, n);
    errdefer gpa.free(rpo);
    @memset(rpo, Cfg.unreached);
    // Postorder by an explicit DFS.
    var post: std.ArrayList(BlockId) = .empty;
    defer post.deinit(gpa);
    {
        const seen = try gpa.alloc(bool, n);
        defer gpa.free(seen);
        @memset(seen, false);
        var stack: std.ArrayList(struct { BlockId, u32 }) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, .{ 0, 0 });
        seen[0] = true;
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const s = succs(r, top[0]);
            if (top[1] < s[1]) {
                const nb = s[0][top[1]];
                top[1] += 1;
                if (!seen[nb]) {
                    seen[nb] = true;
                    try stack.append(gpa, .{ nb, 0 });
                }
            } else {
                try post.append(gpa, top[0]);
                _ = stack.pop();
            }
        }
    }
    const m = post.items.len;
    const order = try gpa.alloc(BlockId, m);
    errdefer gpa.free(order);
    for (post.items, 0..) |b, i| {
        order[m - 1 - i] = b;
        rpo[b] = @intCast(m - 1 - i);
    }
    // Predecessors among reachable blocks.
    var preds: std.ArrayList(std.ArrayList(BlockId)) = .empty;
    defer {
        for (preds.items) |*l| l.deinit(gpa);
        preds.deinit(gpa);
    }
    try preds.appendNTimes(gpa, .empty, n);
    for (order) |b| {
        const s = succs(r, b);
        for (s[0][0..s[1]]) |t| try preds.items[t].append(gpa, b);
    }
    // Dominators (Cooper, Harvey, and Kennedy).
    const idom = try gpa.alloc(BlockId, n);
    errdefer gpa.free(idom);
    const undef = std.math.maxInt(BlockId);
    @memset(idom, undef);
    idom[0] = 0;
    var changed = true;
    while (changed) {
        changed = false;
        for (order[1..]) |b| {
            var new: BlockId = undef;
            for (preds.items[b].items) |p| {
                if (idom[p] == undef) continue;
                if (new == undef) {
                    new = p;
                    continue;
                }
                var f1 = p;
                var f2 = new;
                while (f1 != f2) {
                    while (rpo[f1] > rpo[f2]) f1 = idom[f1];
                    while (rpo[f2] > rpo[f1]) f2 = idom[f2];
                }
                new = f1;
            }
            if (idom[b] != new) {
                idom[b] = new;
                changed = true;
            }
        }
    }
    const header = try gpa.alloc(bool, n);
    errdefer gpa.free(header);
    const merge = try gpa.alloc(bool, n);
    errdefer gpa.free(merge);
    @memset(header, false);
    @memset(merge, false);
    var reducible = true;
    for (order) |b| {
        var fwd: u32 = 0;
        for (preds.items[b].items) |p| {
            if (rpo[p] >= rpo[b]) {
                header[b] = true;
                // A back edge must go to a block that dominates its source.
                var x = p;
                while (x != b and x != 0) x = idom[x];
                if (x != b) reducible = false;
            } else fwd += 1;
        }
        merge[b] = fwd >= 2;
    }
    // Dominator-tree children, in reverse postorder.
    const kid_start = try gpa.alloc(u32, n + 1);
    errdefer gpa.free(kid_start);
    @memset(kid_start, 0);
    for (order[1..]) |b| kid_start[idom[b] + 1] += 1;
    for (1..n + 1) |i| kid_start[i] += kid_start[i - 1];
    const kids = try gpa.alloc(BlockId, m -| 1);
    errdefer gpa.free(kids);
    const fill = try gpa.alloc(u32, n);
    defer gpa.free(fill);
    @memcpy(fill, kid_start[0..n]);
    for (order[1..]) |b| {
        kids[fill[idom[b]]] = b;
        fill[idom[b]] += 1;
    }
    return .{ .order = order, .rpo = rpo, .idom = idom, .header = header, .merge = merge, .kids = kids, .kid_start = kid_start, .reducible = reducible };
}

// ---------------------------------------------------------------- emitting

const Label = union(enum) {
    /// The shared way out: write the registers back and return.
    exit,
    /// The batch's entry dispatch; a branch here enters region `entry`.
    top,
    /// A block or if nothing branches to.
    other,
    /// A loop whose head is block b.
    loop: BlockId,
    /// A block followed by block b.
    block: BlockId,
    /// The fallback dispatch loop.
    dloop,
};

/// Fixed locals after the parameters, by wasm type.
const fixed32 = enum(u32) { code, cell, cpu, tlb, ent, blk, sv, s0, s1, s2, poff, va32 };
const fixed64 = enum(u32) { va, sv, s0, s1, s2, pa, pb, pc, pcode, rp };
const fixed128 = enum(u32) { v };

fn flushRetiredW(w: *W, rp: u32) !void {
    for ([_]struct { u32, u8 }{ .{ ctx.off.retired, 0x7C }, .{ ctx.off.budget, 0x7D } }) |f| {
        try w.get(0);
        try w.get(0);
        try w.memop(0x29, f[0]);
        try w.get(rp);
        try w.byte(f[1]);
        try w.memop(0x37, f[0]);
    }
    try w.i64c(0);
    try w.set(rp);
}

/// A `pending.flags` the block hasn't written yet. Lazy: an eflags op
/// whose operands are in the pa, pb, and pc locals, computed only when
/// written; otherwise pa holds the packed i32. The pcode local says the
/// same for the exit tail, which writes it on a way out from inside the
/// block (a fault, or a poll that leaves): 0 none, 1 packed in pa, or
/// ir_eval.fallbackCode of the lazy op. Writing merges into the slot:
/// old & ~mask | packed (pb holds the mask when pcode is 1).
const Pend = struct { op: ir.Op, ta: Type, off: u32, lazy: bool, mask: u32, rec: bool = false };

/// pcode for a lazy record (pending.flags aux2 = 2): this bit, with the
/// record's header word (kind, size, and cin) in the low 32 bits, and its
/// a, b, and res in pa, pb, and pc, for aux + 8, aux + 16, and aux + 24.
const pcode_rec: u64 = 1 << 63;

/// The pending.flags mask that tells kinds apart: 0 for a record.
fn pendMask(aux2: u64) u32 {
    return switch (aux2) {
        0 => 0xf000_0000,
        1 => @intCast(ir_eval.eflags_mask),
        else => 0,
    };
}

/// Values instruction `i` reads beyond its operands: a lazy-record
/// pending.flags reads its flags op's operands.
fn extraOps(r: *const ir.Region, i: ir.Inst) [3]Ref {
    if (i.op != .@"pending.flags" or i.aux2 != 2) return .{ ir.none, ir.none, ir.none };
    const f = r.insts.items[i.a];
    return .{ f.a, f.b, f.c };
}

const E = struct {
    gpa: Allocator,
    w: W,
    opts: Options,
    regions: []const *const ir.Region,
    labels: std.ArrayList(Label) = .empty,
    /// The batch index of regions[0].
    first: u32,
    regs: []Reg,
    /// Per promoted register: written to its local since the block began
    /// or since a call last flushed and reloaded it (flushDirty).
    dirty: []bool = &.{},
    promoted: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// The batch's chain targets: guest PC to cell index.
    cells: *const std.AutoHashMapUnmanaged(u64, u32),
    /// The batch's region entry PCs: to batch index.
    entries: *const std.AutoHashMapUnmanaged(u64, u32),
    nparams: u32,
    base32: u32 = 0,
    base64: u32 = 0,
    reg32: u32 = 0,
    reg64: u32 = 0,
    pool32: u32 = 0,
    pool64: u32 = 0,
    base128: u32 = 0,
    pool128: u32 = 0,
    // The region being emitted.
    r: *const ir.Region = undefined,
    plan: *const Plan = undefined,
    cfg: *const Cfg = undefined,
    /// The block's `pending.flags`, not yet written (pendingFlags).
    pend: ?Pend = null,
    /// Per block of the region: the flags pending on entry, left by
    /// every predecessor, and whether its own end leaves them so
    /// (flowPend).
    pin: []?Pend = &.{},
    keep: []bool = &.{},

    fn l32(e: *const E, f: fixed32) u32 {
        return e.base32 + @intFromEnum(f);
    }
    fn l64(e: *const E, f: fixed64) u32 {
        return e.base64 + @intFromEnum(f);
    }
    fn scratch(e: *const E, w: u8, k: u32) u32 {
        return if (w == I32) e.l32(.s0) + k else e.l64(.s0) + k;
    }
    fn poolLocal(e: *const E, w: u8, k: u32) u32 {
        return switch (w) {
            I32 => e.pool32 + k,
            I64 => e.pool64 + k,
            else => e.pool128 + k,
        };
    }
    fn l128(e: *const E, f: fixed128) u32 {
        return e.base128 + @intFromEnum(f);
    }

    fn push(e: *E, l: Label) !void {
        try e.labels.append(e.gpa, l);
    }
    fn pop(e: *E) void {
        _ = e.labels.pop();
    }
    fn depth(e: *const E, l: Label) u32 {
        var i = e.labels.items.len;
        while (i > 0) {
            i -= 1;
            if (std.meta.eql(e.labels.items[i], l)) return @intCast(e.labels.items.len - 1 - i);
        }
        unreachable;
    }
    fn br(e: *E, l: Label) !void {
        try e.w.byte(0x0C);
        try e.w.uleb(e.depth(l));
    }
    fn brIf(e: *E, l: Label) !void {
        try e.w.byte(0x0D);
        try e.w.uleb(e.depth(l));
    }
    fn open(e: *E, opcode: u8, l: Label) !void {
        try e.w.bytes(&.{ opcode, VOID });
        try e.push(l);
    }
    fn end(e: *E) !void {
        try e.w.byte(0x0B);
        e.pop();
    }

    // ---- guest registers

    fn regOf(e: *const E, off: u64) ?Reg {
        const k = e.promoted.get(@intCast(off)) orelse return null;
        return e.regs[k];
    }

    fn loadRegs(e: *E) !void {
        for (e.regs) |g| {
            if (g.bad) continue;
            try e.w.get(e.l32(.cpu));
            try e.w.memop(loadOp(g.ty), g.off);
            try e.w.set(g.local);
        }
    }

    /// Before a call out: the registers written since the last one (or
    /// the block's start) go back to the Cpu; after it, loadRegs and
    /// cleanRegs.
    fn flushDirty(e: *E) !void {
        for (e.regs, e.dirty) |g, d| {
            if (g.bad or !g.written or !d) continue;
            try e.w.get(e.l32(.cpu));
            try e.w.get(g.local);
            try e.w.memop(storeOp(g.ty), g.off);
        }
    }
    fn cleanRegs(e: *E) void {
        @memset(e.dirty, false);
    }

    fn flushRegs(e: *E) !void {
        for (e.regs) |g| {
            if (g.bad or !g.written) continue;
            try e.w.get(e.l32(.cpu));
            try e.w.get(g.local);
            try e.w.memop(storeOp(g.ty), g.off);
        }
    }

    // ---- leaving

    /// Leaves with `code`, exit_pc already set.
    fn leaveCode(e: *E, code: ctx.Exit) !void {
        try e.w.i32c(@intFromEnum(code));
        try e.w.set(e.l32(.code));
        try e.br(.exit);
    }

    /// On a path out: ctx.retired += n and ctx.budget -= n (the
    /// instructions the leaving op says completed).
    fn retireOn(e: *E, n: u32) !void {
        if (n == 0) return;
        try e.addRetired(n);
    }

    /// Adds n to the retire count pending in the rp local, which reaches
    /// ctx.retired and ctx.budget only at exits (the exit tail) and before
    /// calls out (flushRetired): ir.zig's contract.
    fn addRetired(e: *E, n: u64) !void {
        try e.w.get(e.l64(.rp));
        try e.w.i64c(n);
        try e.w.byte(0x7C);
        try e.w.set(e.l64(.rp));
    }

    /// ctx.retired += rp and ctx.budget -= rp, and rp = 0.
    fn flushRetired(e: *E) !void {
        try flushRetiredW(&e.w, e.l64(.rp));
    }

    /// Sets exit_pc to `pc` and leaves with `code`.
    fn leave(e: *E, code: ctx.Exit, pc: u64) !void {
        try e.w.get(0);
        try e.w.i64c(pc);
        try e.w.memop(0x37, ctx.off.exit_pc);
        try e.leaveCode(code);
    }

    /// An indirect branch in a function of several regions: if the jump
    /// cache names one of them (its table slot is base + its index), a
    /// branch to it, keeping the registers in locals. exit_pc is set.
    fn indirectHere(e: *E) !void {
        const w = &e.w;
        const pc = e.scratch(I64, 0);
        const ent = e.scratch(I32, 0);
        try w.get(0);
        try w.memop(0x29, ctx.off.exit_pc);
        try w.tee(pc);
        // ctx.jumpIndex: ((pc ^ pc >> 12) >> 2) & (jump_entries - 1)
        try w.get(pc);
        try w.i64c(12);
        try w.byte(0x88);
        try w.byte(0x85);
        try w.i64c(2);
        try w.byte(0x88);
        try w.byte(0xA7);
        try w.i32c(ctx.jump_entries - 1);
        try w.byte(0x71);
        try w.i32c(@sizeOf(ctx.JumpEntry));
        try w.byte(0x6C);
        try w.get(0);
        try w.memop(0x28, ctx.off.jump);
        try w.byte(0x6A);
        try w.tee(ent);
        try w.memop(0x29, 0);
        try w.get(pc);
        try w.byte(0x51); // i64.eq
        try e.open(0x04, .other);
        try w.get(ent);
        try w.memop(0x28, @offsetOf(ctx.JumpEntry, "code"));
        try w.byte(0x23); // global.get base
        try w.uleb(0);
        try w.byte(0x6B); // i32.sub
        try w.tee(ent);
        try w.i32c(@intCast(e.regions.len));
        try w.byte(0x49); // i32.lt_u
        try e.open(0x04, .other);
        try w.get(ent);
        try w.set(1);
        try e.br(.top);
        try e.end();
        try e.end();
    }

    fn chain(e: *E, pc: u64, retired: u32) !void {
        try e.retireOn(retired);
        if (e.opts.cells != 0) {
            const k = e.cells.get(pc).?;
            try e.w.i32c(e.opts.cells + 4 * k);
            try e.w.memop(0x28, 0);
            try e.w.set(e.l32(.cell));
            if (e.entries.get(pc)) |j| if (j >= e.first and j - e.first < e.regions.len) {
                // Linked to region j, in this function: branch to it.
                try e.w.get(e.l32(.cell));
                try e.w.byte(0x23); // global.get base
                try e.w.uleb(0);
                if (j != 0) {
                    try e.w.i32c(j);
                    try e.w.byte(0x6A);
                }
                try e.w.byte(0x46); // i32.eq
                try e.open(0x04, .other);
                if (e.regions.len > 1) {
                    try e.w.i32c(j - e.first);
                    try e.w.set(1);
                }
                try e.br(.top);
                try e.end();
            };
        }
        try e.leave(.chain, pc);
    }

    // ---- values

    /// Pushes value `ref`.
    fn val(e: *E, ref: Ref) EmitError!void {
        const i = e.r.insts.items[ref];
        switch (e.plan.kind[ref]) {
            .konst => if (is64(i.ty)) try e.w.i64c(i.aux) else try e.w.i32c(@truncate(i.aux)),
            .alias => try e.w.get(e.regOf(i.aux).?.local),
            .inl => try e.inst(ref),
            .root => try e.w.get(e.poolLocal(wt(i.ty).?, e.plan.loc[ref])),
            .dead => unreachable,
        }
    }

    /// Pushes value `ref` as an i64.
    fn val64(e: *E, ref: Ref) !void {
        if (ref == ir.none) return e.w.i64c(0);
        try e.val(ref);
        if (!is64(e.ty(ref))) try e.w.byte(0xAD); // i64.extend_i32_u
    }

    fn ty(e: *const E, ref: Ref) Type {
        return if (ref == ir.none) .none else e.r.insts.items[ref].ty;
    }

    /// Masks the i32 on the stack to type t, if t is narrower.
    fn mask(e: *E, t: Type) !void {
        if (t == .i32 or is64(t)) return;
        try e.w.i32c(@truncate(t.mask()));
        try e.w.byte(0x71);
    }

    /// Pushes a and b, then keeps them in scratch locals 0 and 1 of their
    /// wasm type.
    fn stash2(e: *E, a: Ref, b: Ref) !u8 {
        const w = wt(e.ty(a)).?;
        try e.val(a);
        try e.val(b);
        try e.w.set(e.scratch(w, 1));
        try e.w.set(e.scratch(w, 0));
        return w;
    }

    fn fallback(e: *E, i: ir.Inst) !void {
        try e.w.i64c(ir_eval.fallbackCode(i.op, i.ty, e.ty(i.a)));
        try e.val64(i.a);
        try e.val64(i.b);
        try e.val64(i.c);
        try e.w.i64c(i.aux);
        try e.w.call(F_EVAL);
        if (!is64(i.ty)) try e.w.byte(0xA7); // i32.wrap_i64
    }

    /// Emits instruction `idx`; one with a result leaves it on the stack.
    fn inst(e: *E, idx: usize) EmitError!void {
        const i = e.r.insts.items[idx];
        const t = i.ty;
        const ta = e.ty(i.a);
        const w = &e.w;
        switch (i.op) {
            .@"call.interp", .copy => {
                try e.flushPending();
                try e.flushRetired();
            },
            // A helper that touches none of the region's Cpu bytes
            // (ir.helper_no_regs, an x87 one) leaves the flags pending.
            // Nor does it read the retired count or the budget, which are
            // written on the way out if it traps.
            .@"call.helper" => if (i.aux2 & ir.helper_no_regs == 0) {
                try e.flushPending();
                try e.flushRetired();
            },
            .setreg => if (e.pend) |p| if (i.aux < p.off + 4 and p.off < i.aux + byteSize(ta).?) {
                // Overwritten: the pending flags are never written.
                e.pend = null;
                try w.i64c(0);
                try w.set(e.l64(.pcode));
            },
            else => {},
        }
        switch (i.op) {
            .@"pending.flags" => try e.pendingFlags(i),
            .@"const" => unreachable,
            .getreg => if (e.regOf(i.aux)) |g| {
                try w.get(g.local);
            } else if (t == .v128) {
                try w.get(e.l32(.cpu));
                try w.simd(0x00); // v128.load
                try w.bytes(&.{0});
                try w.uleb(i.aux);
            } else {
                try w.get(e.l32(.cpu));
                try w.memop(loadOp(t), i.aux);
            },
            .setreg => if (e.regOf(i.aux)) |g| {
                try e.val(i.a);
                try w.set(g.local);
                e.dirty[e.promoted.get(@intCast(i.aux)).?] = true;
            } else if (ta == .v128) {
                try w.get(e.l32(.cpu));
                try e.val(i.a);
                try w.simd(0x0B); // v128.store
                try w.bytes(&.{0});
                try w.uleb(i.aux);
            } else {
                try w.get(e.l32(.cpu));
                try e.val(i.a);
                try w.memop(storeOp(ta), i.aux);
            },
            .add, .sub, .mul, .@"and", .@"or", .xor, .andn, .shl, .lshr, .ashr, .ror, .rol => {
                const narrow = !is64(t) and t != .i32;
                if (narrow and (i.op == .ror or i.op == .rol)) return e.fallback(i);
                const d: u8 = if (is64(t)) 0 else 0x12;
                if (narrow and i.op == .ashr) {
                    try e.val(i.a);
                    try w.byte(if (t == .i8) 0xC0 else 0xC1); // i32.extend8_s, 16_s
                } else try e.val(i.a);
                try e.val(i.b);
                if (i.op == .andn) {
                    if (is64(t)) try w.i64c(std.math.maxInt(u64)) else try w.i32c(std.math.maxInt(u32));
                    try w.byte(0x85 - d);
                }
                if (narrow and (i.op == .shl or i.op == .lshr or i.op == .ashr)) {
                    try w.i32c(t.bits() - 1);
                    try w.byte(0x71);
                }
                try w.byte(binop64(i.op) - d);
                switch (i.op) {
                    .add, .sub, .mul, .shl, .ashr => try e.mask(t),
                    else => {},
                }
            },
            .neg, .not => {
                if (i.op == .neg) {
                    if (is64(t)) try w.i64c(0) else try w.i32c(0);
                }
                try e.val(i.a);
                if (i.op == .not) {
                    if (is64(t)) try w.i64c(std.math.maxInt(u64)) else try w.i32c(std.math.maxInt(u32));
                }
                try w.byte(if (i.op == .neg) (if (is64(t)) @as(u8, 0x7D) else 0x6B) else (if (is64(t)) @as(u8, 0x85) else 0x73));
                try e.mask(t);
            },
            .clz, .ctz, .popcnt => {
                try e.val(i.a);
                if (is64(t)) {
                    try w.byte(switch (i.op) {
                        .clz => 0x79,
                        .ctz => 0x7A,
                        else => 0x7B,
                    });
                } else if (t == .i32 or i.op == .popcnt) {
                    try w.byte(switch (i.op) {
                        .clz => 0x67,
                        .ctz => 0x68,
                        else => 0x69,
                    });
                } else if (i.op == .clz) {
                    try w.byte(0x67);
                    try w.i32c(32 - t.bits());
                    try w.byte(0x6B);
                } else {
                    try w.i32c(@as(u32, 1) << @intCast(t.bits()));
                    try w.byte(0x72);
                    try w.byte(0x68);
                }
            },
            .udiv, .urem => {
                const wty = try e.stash2(i.a, i.b);
                const d: u8 = if (wty == I64) 0 else 0x12;
                try w.get(e.scratch(wty, 1));
                try w.byte(if (wty == I64) 0x50 else 0x45); // eqz
                try w.bytes(&[_]u8{ 0x04, wty });
                if (i.op == .udiv) {
                    if (wty == I64) try w.i64c(0) else try w.i32c(0);
                } else try w.get(e.scratch(wty, 0));
                try w.byte(0x05);
                try w.get(e.scratch(wty, 0));
                try w.get(e.scratch(wty, 1));
                try w.byte((if (i.op == .udiv) @as(u8, 0x80) else 0x82) - d);
                try w.byte(0x0B);
            },
            .mulhu, .mulhs => {
                if (is64(t)) return e.fallback(i);
                const s = i.op == .mulhs;
                if (t == .i32) {
                    try e.val(i.a);
                    try w.byte(if (s) 0xAC else 0xAD);
                    try e.val(i.b);
                    try w.byte(if (s) 0xAC else 0xAD);
                    try w.byte(0x7E);
                    try w.i64c(32);
                    try w.byte(if (s) 0x87 else 0x88);
                    try w.byte(0xA7);
                } else {
                    const ext: u8 = if (t == .i8) 0xC0 else 0xC1;
                    try e.val(i.a);
                    if (s) try w.byte(ext);
                    try e.val(i.b);
                    if (s) try w.byte(ext);
                    try w.byte(0x6C);
                    try w.i32c(t.bits());
                    try w.byte(if (s) 0x75 else 0x76);
                    try e.mask(t);
                }
            },
            .zext => {
                try e.val(i.a);
                if (is64(t) and !is64(ta)) try w.byte(0xAD);
            },
            .sext => {
                if (ta == .i1) {
                    if (is64(t)) try w.i64c(0) else try w.i32c(0);
                    try e.val(i.a);
                    if (is64(t)) {
                        try w.byte(0xAD);
                        try w.byte(0x7D);
                    } else {
                        try w.byte(0x6B);
                        try e.mask(t);
                    }
                } else if (is64(t)) {
                    try e.val(i.a);
                    switch (ta) {
                        .i8 => try w.bytes(&.{ 0xAD, 0xC2 }),
                        .i16 => try w.bytes(&.{ 0xAD, 0xC3 }),
                        .i32 => try w.byte(0xAC),
                        else => {},
                    }
                } else {
                    try e.val(i.a);
                    switch (ta) {
                        .i8 => try w.byte(0xC0),
                        .i16 => try w.byte(0xC1),
                        else => {},
                    }
                    try e.mask(t);
                }
            },
            .trunc => {
                try e.val(i.a);
                if (!is64(t)) {
                    if (is64(ta)) try w.byte(0xA7);
                    try e.mask(t);
                }
            },
            .select => {
                try e.val(i.b);
                try e.val(i.c);
                try e.val(i.a);
                try w.byte(0x1B);
            },
            .icmp => {
                const pred: ir.Pred = @enumFromInt(i.aux);
                const signed = @intFromEnum(pred) >= @intFromEnum(ir.Pred.slt);
                if (signed and ta == .i1) return e.fallback(i);
                const ext: ?u8 = if (signed) switch (ta) {
                    .i8 => 0xC0,
                    .i16 => 0xC1,
                    else => null,
                } else null;
                try e.val(i.a);
                if (ext) |x| try w.byte(x);
                try e.val(i.b);
                if (ext) |x| try w.byte(x);
                const op = cmp64[@intCast(i.aux)];
                try w.byte(if (is64(ta)) op else op - 0x0B);
            },
            .@"nzcv.add", .@"nzcv.sub" => try e.nzcv(i),
            .@"eflags.add", .@"eflags.sub", .@"eflags.adc", .@"eflags.sbb", .@"eflags.inc", .@"eflags.dec", .@"eflags.logic", .@"eflags.shl", .@"eflags.shr", .@"eflags.mul" => try e.eflags(i),
            .@"eflags.cond" => try e.eflagsCond(i),
            .@"nzcv.logic" => {
                const wide = is64(ta);
                try e.val(i.a);
                try w.set(e.scratch(wt(ta).?, 0));
                // N
                try w.get(e.scratch(wt(ta).?, 0));
                if (wide) try w.bytes(&.{ 0x42, 32, 0x88, 0xA7 });
                try w.i32c(0x8000_0000);
                try w.byte(0x71);
                // Z
                try w.get(e.scratch(wt(ta).?, 0));
                try w.byte(if (wide) 0x50 else 0x45);
                try w.i32c(30);
                try w.byte(0x74);
                try w.byte(0x72);
                try w.byte(0xAD);
            },
            .@"nzcv.cond" => {
                const cc: u4 = @intCast(i.aux);
                if (cc >= 14) return w.i32c(1); // the operand is pure: nothing to drop
                const f = e.scratch(I32, 0);
                try e.val(i.a);
                try w.byte(0xA7);
                try w.set(f);
                const B = struct {
                    fn bit(ww: *W, l: u32, n: u32) !void {
                        try ww.get(l);
                        try ww.i32c(n);
                        try ww.byte(0x76); // shr_u
                    }
                };
                switch (cc >> 1) {
                    0 => try B.bit(w, f, 30),
                    1 => try B.bit(w, f, 29),
                    2 => try B.bit(w, f, 31),
                    3 => try B.bit(w, f, 28),
                    4 => { // C and not Z
                        try B.bit(w, f, 29);
                        try B.bit(w, f, 30);
                        try w.i32c(std.math.maxInt(u32));
                        try w.byte(0x73);
                        try w.byte(0x71);
                    },
                    5 => { // N == V
                        try B.bit(w, f, 31);
                        try B.bit(w, f, 28);
                        try w.byte(0x73);
                        try w.i32c(1);
                        try w.byte(0x73);
                    },
                    6 => { // not Z and N == V
                        try B.bit(w, f, 31);
                        try B.bit(w, f, 28);
                        try w.byte(0x73);
                        try B.bit(w, f, 30);
                        try w.byte(0x72);
                        try w.i32c(1);
                        try w.byte(0x73);
                    },
                    else => unreachable,
                }
                try w.i32c(1);
                try w.byte(0x71);
                if (cc & 1 == 1) {
                    try w.i32c(1);
                    try w.byte(0x73);
                }
            },
            .@"nzcv.pack", .@"eflags.pack" => {
                try e.val(i.a);
                try w.byte(0xA7);
                try w.i32c(if (i.op == .@"nzcv.pack") 0xf000_0000 else @intCast(ir_eval.eflags_mask));
                try w.byte(0x71);
            },
            .@"nzcv.unpack", .@"eflags.unpack" => {
                try e.val(i.a);
                try w.i32c(if (i.op == .@"nzcv.unpack") 0xf000_0000 else @intCast(ir_eval.eflags_mask));
                try w.byte(0x71);
                try w.byte(0xAD);
            },
            .load, .store => try e.memOp(i),
            .@"v.load", .@"v.store" => try e.vmemOp(i),
            .cas => {
                // Always the runtime's, as on arm64.
                const f: ir.MemFlags = @bitCast(i.aux);
                try w.get(0);
                try e.val64(i.a);
                try w.i32c(f.size);
                try e.val64(i.b);
                try e.val64(i.c);
                try w.call(F_SLOW_CAS);
                try w.tee(e.l32(.code));
                try e.open(0x04, .other);
                try e.retireOn(i.retired);
                try w.get(0);
                try w.i64c(i.aux2);
                try w.memop(0x37, ctx.off.exit_pc);
                try e.br(.exit);
                try e.end();
                try w.get(0);
                try w.memop(0x29, ctx.off.scratch);
                if (wt(t).? == I32) try w.byte(0xA7);
            },
            .fence => {}, // one thread per memory in the browser
            .@"call.interp" => {
                try e.flushDirty();
                try w.get(0);
                try w.i64c(e.r.handles.items[@intCast(i.aux)]);
                try w.i64c(i.aux2);
                try w.call(F_INTERP);
                try w.set(e.l32(.code));
                try e.loadRegs();
                e.cleanRegs();
                try w.get(e.l32(.code));
                if (i.retired == 0) {
                    try e.brIf(.exit);
                } else {
                    try e.open(0x04, .other);
                    try e.retireOn(i.retired);
                    try e.br(.exit);
                    try e.end();
                }
            },
            .copy => {
                // As call.interp on the guest word, at PC 0; it can't leave
                // (ir.zig, Op.copy).
                try e.flushDirty();
                try w.get(0);
                try w.i64c(i.aux & 0xffff_ffff);
                try w.i64c(0);
                try w.call(F_INTERP);
                try w.byte(0x1A); // drop
                try e.loadRegs();
                e.cleanRegs();
            },
            .@"call.helper" => {
                try w.get(0);
                if (e.opts.cells == 0) try w.i64c(i.aux);
                try e.val64(i.a);
                try e.val64(i.b);
                try e.val64(i.c);
                const regs = i.aux2 & ir.helper_no_regs == 0;
                if (regs) try e.flushDirty();
                if (e.opts.cells != 0) {
                    // Straight through h9's table, which the module has
                    // when chaining: ctx.helpers[aux] is a slot in it.
                    if (e.opts.helpers != 0) {
                        const hs: [*]const u32 = @ptrFromInt(e.opts.helpers);
                        try w.i32c(@bitCast(hs[@intCast(i.aux)]));
                    } else {
                        try w.get(0);
                        try w.memop(0x28, ctx.off.helpers);
                        try w.memop(0x28, i.aux * 4); // a wasm32 function pointer
                    }
                    try w.bytes(&.{ 0x11, T_HELPER, 0 }); // call_indirect
                } else try w.call(F_HELPER);
                if (t == .none) try w.byte(0x1A);
                if (regs) {
                    try e.loadRegs();
                    e.cleanRegs();
                }
            },
            .poll => {
                try w.get(0);
                try w.memop(0x28, ctx.off.exit_request);
                try w.get(0);
                try w.memop(0x29, ctx.off.budget);
                try w.get(e.l64(.rp));
                try w.byte(0x57); // i64.le_s: budget <= pending
                try w.byte(0x72); // i32.or
                try e.open(0x04, .other);
                try e.retireOn(i.retired);
                try e.leave(.interrupted, i.aux);
                try e.end();
            },
            .retire => try e.addRetired(i.aux),
            .@"exit.chain" => try e.chain(i.aux, i.retired),
            .@"exit.svc", .@"exit.brk", .@"exit.undef" => {
                try e.retireOn(i.retired);
                try e.leave(switch (i.op) {
                    .@"exit.svc" => .svc,
                    .@"exit.brk" => .brk,
                    else => .undef,
                }, i.aux);
            },
            .@"exit.indirect" => {
                try w.get(0);
                try e.val64(i.a);
                try w.memop(0x37, ctx.off.exit_pc);
                try e.retireOn(i.retired);
                if (e.opts.jump and e.nparams == 2) try e.indirectHere();
                try e.leaveCode(.indirect);
            },
            .br, .brcond => unreachable, // the control flow's
            else => if (i.op.isPure() and wt(t) != null)
                try e.fallback(i)
            else if (i.op.isExt())
                try e.extOp(i)
            else
                return error.Unsupported,
        }
    }

    /// An FP or vector op through `ext` (ir_eval.evalExtC): its operands
    /// staged at Options.ext_io, 16 bytes each, and its result read back.
    fn extOp(e: *E, i: ir.Inst) !void {
        const io = e.opts.ext_io;
        if (io == 0) return error.Unsupported;
        const w = &e.w;
        for (i.operands(), 0..) |o, k| {
            if (o == ir.none) continue;
            const at: u32 = io + 16 * @as(u32, @intCast(k));
            try w.i32c(at);
            if (e.ty(o) == .v128) {
                try e.val(o);
                try w.simd(0x0B);
                try w.bytes(&.{ 0, 0 });
            } else {
                try e.val64(o);
                try w.memop(0x37, 0);
                try w.i32c(at + 8);
                try w.i64c(0);
                try w.memop(0x37, 0);
            }
        }
        try w.get(0);
        try w.i64c(ir_eval.fallbackCode(i.op, i.ty, e.ty(i.a)));
        try w.i32c(io);
        try w.i64c(i.aux);
        try w.i64c(i.aux2);
        try w.call(F_EXT);
        switch (wt(i.ty) orelse return) {
            V128 => {
                try w.i32c(io);
                try w.simd(0x00);
                try w.bytes(&.{ 0, 0 });
            },
            I64 => {
                try w.i32c(io);
                try w.memop(0x29, 0);
            },
            else => {
                try w.i32c(io);
                try w.memop(0x28, 0);
            },
        }
    }

    /// v.load and v.store: 16 bytes through the TLB, or two 8-byte halves
    /// through the slow path (as x64.zig does).
    fn vmemOp(e: *E, i: ir.Inst) !void {
        const w = &e.w;
        const f: ir.MemFlags = @bitCast(i.aux);
        const store = i.op == .@"v.store";
        const va = e.l64(.va);
        const ent = e.l32(.ent);
        const v = e.l128(.v);
        try e.val64(i.a);
        if (store) {
            try e.val(i.b);
            try w.set(v);
        }
        try w.set(va);
        if (f.aligned) {
            try w.get(va);
            try w.i64c(15);
            try w.byte(0x83);
            try w.byte(0x50);
            try w.byte(0x45);
            try e.open(0x04, .other);
            try w.get(0);
            try w.get(va);
            try w.memop(0x37, ctx.off.exit_addr);
            try w.get(0);
            try w.i64c(@as(u64, @intFromEnum(if (store) mem.Access.write else mem.Access.read)) | (@as(u64, @intFromEnum(mem.FaultKind.alignment)) << 8));
            try w.memop(0x37, ctx.off.exit_info);
            try e.retireOn(i.retired);
            try e.leave(.fault, i.aux2);
            try e.end();
        }
        const table: u32 = if (store) mem.tlb_write_off else 0;
        try w.get(e.l32(.tlb));
        try w.get(va);
        try w.i64c(mem.page_shift);
        try w.byte(0x88);
        try w.byte(0xA7);
        try w.i32c(mem.entries - 1);
        try w.byte(0x71);
        try w.i32c(4);
        try w.byte(0x74);
        try w.byte(0x6A);
        try w.tee(ent);
        try w.memop(0x29, table);
        try w.get(va);
        try w.i64c(mem.page_shift);
        try w.byte(0x88);
        try w.byte(0x51);
        try w.get(va);
        try w.i64c(mem.page_size - 1);
        try w.byte(0x83);
        try w.i64c(mem.page_size - 16);
        try w.byte(0x58);
        try w.byte(0x71);
        try w.bytes(&.{ 0x04, VOID });
        try e.push(.other);
        try w.get(va);
        try w.get(ent);
        try w.memop(0x29, table + 8);
        try w.byte(0x7C);
        try w.byte(0xA7);
        if (store) {
            try w.get(v);
            try w.simd(0x0B);
            try w.bytes(&.{ 0, 0 });
        } else {
            try w.simd(0x00);
            try w.bytes(&.{ 0, 0 });
            try w.set(v);
        }
        try w.byte(0x05); // else: two halves through the slow path
        for (0..2) |half| {
            try w.get(0);
            try w.get(va);
            if (half == 1) {
                try w.i64c(8);
                try w.byte(0x7C);
            }
            try w.i32c(3);
            if (store) {
                try w.get(v);
                try w.simd(0x1D); // i64x2.extract_lane
                try w.byte(@intCast(half));
                try w.call(F_SLOW_STORE);
            } else try w.call(F_SLOW_LOAD);
            try w.tee(e.l32(.code));
            try e.open(0x04, .other);
            try e.retireOn(i.retired);
            try w.get(0);
            try w.i64c(i.aux2);
            try w.memop(0x37, ctx.off.exit_pc);
            try e.br(.exit);
            try e.end();
            if (!store) {
                if (half == 0) {
                    try w.get(0);
                    try w.memop(0x29, ctx.off.scratch);
                    try w.simd(0x12); // i64x2.splat
                    try w.set(v);
                } else {
                    try w.get(v);
                    try w.get(0);
                    try w.memop(0x29, ctx.off.scratch);
                    try w.simd(0x1E); // i64x2.replace_lane
                    try w.byte(1);
                    try w.set(v);
                }
            }
        }
        try e.end();
        if (!store) try w.get(v);
    }

    /// NZCV of a + b or a - b, eagerly, as ir_eval packs it.
    fn nzcv(e: *E, i: ir.Inst) !void {
        const w = &e.w;
        const ta = e.ty(i.a);
        const wide = is64(ta);
        const wty = try e.stash2(i.a, i.b);
        const d: u8 = if (wide) 0 else 0x12;
        const sub = i.op == .@"nzcv.sub";
        const a = e.scratch(wty, 0);
        const b = e.scratch(wty, 1);
        const r = e.scratch(wty, 2);
        // The top bit of the value on the stack, as an i32 in bit 31.
        const Top = struct {
            fn emit(ww: *W, wd: bool) !void {
                if (wd) try ww.bytes(&.{ 0x42, 32, 0x88, 0xA7 }); // i64.const 32, shr_u, wrap
            }
        };
        try w.get(a);
        try w.get(b);
        try w.byte((if (sub) @as(u8, 0x7D) else 0x7C) - d);
        try w.set(r);
        // N
        try w.get(r);
        try Top.emit(w, wide);
        try w.i32c(0x8000_0000);
        try w.byte(0x71);
        // Z
        try w.get(r);
        try w.byte(if (wide) 0x50 else 0x45);
        try w.i32c(30);
        try w.byte(0x74);
        try w.byte(0x72);
        // C: no borrow (a >= b), or a carry (r < a)
        if (sub) {
            try w.get(a);
            try w.get(b);
            try w.byte(0x5A - (if (wide) @as(u8, 0) else 0x0B)); // ge_u
        } else {
            try w.get(r);
            try w.get(a);
            try w.byte(0x54 - (if (wide) @as(u8, 0) else 0x0B)); // lt_u
        }
        try w.i32c(29);
        try w.byte(0x74);
        try w.byte(0x72);
        // V: sub ((a^b)&(a^r)), add ((a^r)&(b^r)), top bit
        try w.get(a);
        try w.get(if (sub) b else r);
        try w.byte(0x85 - d);
        try w.get(if (sub) a else b);
        try w.get(r);
        try w.byte(0x85 - d);
        try w.byte(0x83 - d);
        try Top.emit(w, wide);
        try w.i32c(3);
        try w.byte(0x76);
        try w.i32c(0x1000_0000);
        try w.byte(0x71);
        try w.byte(0x72);
        try w.byte(0xAD);
    }

    /// Pushes ref as an i64, zero-extended from type t.
    fn val64m(e: *E, ref: Ref, t: Type) !void {
        try e.val64(ref);
        if (t != .i64) {
            try e.w.i64c(t.mask());
            try e.w.byte(0x83);
        }
    }

    /// ORs (into the i64 on the stack) bit `to` set to bit `from` of l.
    fn orBit(e: *E, l: u32, from: u32, to: u32) !void {
        const w = &e.w;
        try w.get(l);
        if (from != 0) {
            try w.i64c(from);
            try w.byte(0x88); // shr_u
        }
        try w.i64c(1);
        try w.byte(0x83);
        if (to != 0) {
            try w.i64c(to);
            try w.byte(0x86); // shl
        }
        try w.byte(0x84);
    }

    /// ORs SF, ZF, and PF of the result in l (masked to `bits`) into the
    /// i64 on the stack.
    fn szp(e: *E, l: u32, bits: u32) !void {
        const w = &e.w;
        try w.get(l);
        try w.byte(0x50); // eqz
        try w.byte(0xAD);
        try w.i64c(6);
        try w.byte(0x86);
        try w.byte(0x84);
        try e.orBit(l, bits - 1, 7);
        try w.get(l);
        try w.i64c(0xff);
        try w.byte(0x83);
        try w.byte(0x7B); // popcnt
        try w.i64c(1);
        try w.byte(0x83);
        try w.i64c(1);
        try w.byte(0x85);
        try w.i64c(2);
        try w.byte(0x86);
        try w.byte(0x84);
    }

    /// x86 flags (ir_eval.evalPure's), computed in i64 on operands
    /// zero-extended from their width, so CF is bit `bits` of the sum or
    /// difference. Every operand is pushed before a scratch local is set,
    /// since pushing one can use them.
    fn eflags(e: *E, i: ir.Inst) !void {
        return e.eflagsOf(i.op, e.ty(i.a), i);
    }

    /// Operand k (0 a, 1 b, 2 c) of an eflags op, as an i64: from `src`'s
    /// operands, or, with no `src`, from the locals pendingFlags stashed
    /// them in. `m` masks it to ta (a source operand, not a flags value).
    fn eflagsArg(e: *E, src: ?ir.Inst, k: u2, ta: Type, m: bool) !void {
        if (src) |i| {
            const ref = switch (k) {
                0 => i.a,
                1 => i.b,
                else => i.c,
            };
            return if (m) e.val64m(ref, ta) else e.val64(ref);
        }
        try e.w.get(e.l64(switch (k) {
            0 => .pa,
            1 => .pb,
            else => .pc,
        }));
    }

    /// eflagsOf for `op` at width ta, with operands from `src` or the
    /// pending-flags locals (eflagsArg).
    fn eflagsOf(e: *E, op: ir.Op, ta: Type, src: ?ir.Inst) !void {
        const w = &e.w;
        const bits = ta.bits();
        if (bits == 64) {
            // Not lowered at 64 bits yet (a carry out of bit 63 needs
            // more than i64 sums): ir_eval's evalOpC.
            const incdec = op == .@"eflags.inc" or op == .@"eflags.dec";
            try w.i64c(ir_eval.fallbackCode(op, .flags, ta));
            try e.eflagsArg(src, 0, ta, true);
            if (op == .@"eflags.logic") try w.i64c(0) else try e.eflagsArg(src, 1, ta, !incdec);
            if (op == .@"eflags.adc" or op == .@"eflags.sbb") try e.eflagsArg(src, 2, ta, false) else try w.i64c(0);
            try w.i64c(0);
            try w.call(F_EVAL);
            return;
        }
        const a = e.scratch(I64, 0);
        const b = e.scratch(I64, 1);
        const r = e.scratch(I64, 2);
        switch (op) {
            .@"eflags.logic" => {
                try e.eflagsArg(src, 0, ta, true);
                try w.set(r);
                try w.i64c(0);
                try e.szp(r, bits);
            },
            .@"eflags.shl", .@"eflags.shr", .@"eflags.mul" => {
                try e.eflagsArg(src, 0, ta, true);
                try e.eflagsArg(src, 1, ta, true);
                try w.set(r);
                try w.set(a);
                if (op == .@"eflags.mul") {
                    try w.get(a);
                    try w.i64c(0);
                    try w.byte(0x52); // ne
                    try w.byte(0xAD);
                    try w.i64c(ir_eval.CF | ir_eval.OF);
                    try w.byte(0x7E); // mul
                } else {
                    // CF: msb(a) or a & 1; OF: msb(a ^ r)
                    try w.get(a);
                    if (op == .@"eflags.shl") {
                        try w.i64c(bits - 1);
                        try w.byte(0x88);
                    }
                    try w.i64c(1);
                    try w.byte(0x83);
                    try w.get(a);
                    try w.get(r);
                    try w.byte(0x85);
                    try w.set(a);
                    try e.orBit(a, bits - 1, 11);
                }
                try e.szp(r, bits);
            },
            else => {
                const sub = switch (op) {
                    .@"eflags.sub", .@"eflags.sbb", .@"eflags.dec" => true,
                    else => false,
                };
                const aop: u8 = if (sub) 0x7D else 0x7C;
                switch (op) {
                    .@"eflags.inc", .@"eflags.dec" => {
                        // CF is kept from flags b: it starts the result.
                        try e.eflagsArg(src, 1, ta, false);
                        try w.i64c(ir_eval.CF);
                        try w.byte(0x83);
                        try e.eflagsArg(src, 0, ta, true);
                        try w.set(a);
                        try w.i64c(1);
                        try w.set(b);
                        try w.get(a);
                        try w.get(b);
                        try w.byte(aop);
                        try w.set(r);
                    },
                    .@"eflags.adc", .@"eflags.sbb" => {
                        try e.eflagsArg(src, 0, ta, true);
                        try e.eflagsArg(src, 1, ta, true);
                        try e.eflagsArg(src, 2, ta, false);
                        try w.i64c(1);
                        try w.byte(0x83);
                        try w.set(r);
                        try w.set(b);
                        try w.set(a);
                        try w.get(a);
                        try w.get(b);
                        try w.byte(aop);
                        try w.get(r);
                        try w.byte(aop);
                        try w.set(r);
                    },
                    else => {
                        try e.eflagsArg(src, 0, ta, true);
                        try e.eflagsArg(src, 1, ta, true);
                        try w.set(b);
                        try w.tee(a);
                        try w.get(b);
                        try w.byte(aop);
                        try w.set(r);
                    },
                }
                if (op != .@"eflags.inc" and op != .@"eflags.dec") {
                    // CF: bit `bits` of r.
                    try w.get(r);
                    try w.i64c(bits);
                    try w.byte(0x88);
                    try w.i64c(1);
                    try w.byte(0x83);
                }
                try w.get(r);
                try w.i64c(ta.mask());
                try w.byte(0x83);
                try w.set(r);
                try e.szp(r, bits);
                // AF
                try w.get(a);
                try w.get(b);
                try w.byte(0x85);
                try w.get(r);
                try w.byte(0x85);
                try w.i64c(ir_eval.AF);
                try w.byte(0x83);
                try w.byte(0x84);
                // OF: add (a^r)&(b^r), sub (a^b)&(a^r), at the top bit.
                try w.get(a);
                try w.get(if (sub) b else r);
                try w.byte(0x85);
                try w.get(if (sub) a else b);
                try w.get(r);
                try w.byte(0x85);
                try w.byte(0x83);
                try w.set(a);
                try e.orBit(a, bits - 1, 11);
            },
        }
    }

    /// x86 condition aux of flags a, as an i32 0 or 1.
    fn eflagsCond(e: *E, i: ir.Inst) !void {
        const w = &e.w;
        const cc: u4 = @intCast(i.aux);
        const f = e.scratch(I32, 0);
        try e.val64(i.a);
        try w.byte(0xA7);
        try w.set(f);
        const B = struct {
            fn bit(ww: *W, l: u32, n: u32) !void {
                try ww.get(l);
                if (n != 0) {
                    try ww.i32c(n);
                    try ww.byte(0x76); // shr_u
                }
            }
        };
        switch (@as(u3, @intCast(cc >> 1))) {
            0 => try B.bit(w, f, 11),
            1 => try B.bit(w, f, 0),
            2 => try B.bit(w, f, 6),
            3 => {
                try w.get(f);
                try w.i32c(@intCast(ir_eval.CF | ir_eval.ZF));
                try w.byte(0x71);
                try w.i32c(0);
                try w.byte(0x47); // ne
            },
            4 => try B.bit(w, f, 7),
            5 => try B.bit(w, f, 2),
            6, 7 => {
                try B.bit(w, f, 7);
                try B.bit(w, f, 11);
                try w.byte(0x73);
                if (cc >> 1 == 7) {
                    try B.bit(w, f, 6);
                    try w.byte(0x72);
                }
            },
        }
        try w.i32c(1);
        try w.byte(0x71);
        if (cc & 1 == 1) {
            try w.i32c(1);
            try w.byte(0x73);
        }
    }

    fn memOp(e: *E, i: ir.Inst) !void {
        const w = &e.w;
        const f: ir.MemFlags = @bitCast(i.aux);
        const store = i.op == .store;
        const n = f.bytes();
        const va = e.l64(.va);
        const ent = e.l32(.ent);
        const vt: Type = if (store) e.ty(i.b) else i.ty;
        const vw = wt(vt).?;
        const sv = if (vw == I32) e.l32(.sv) else e.l64(.sv);
        // A 32-bit guest's address (a zext of an i32): the TLB index, the
        // page check, and the host address in i32, from va32.
        const ai = e.r.insts.items[i.a];
        const narrow = ai.op == .zext and e.plan.kind[i.a] != .konst and e.ty(ai.a) == .i32;
        const va32 = e.l32(.va32);
        if (narrow) {
            if (e.plan.kind[i.a] == .inl) try e.val(ai.a) else {
                try e.val(i.a);
                try w.byte(0xA7); // i32.wrap_i64
            }
        } else try e.val64(i.a);
        if (store) {
            try e.val(i.b);
            try w.set(sv);
        }
        if (narrow) {
            try w.tee(va32);
            try w.byte(0xAD); // i64.extend_i32_u
        }
        try w.set(va);
        if (f.aligned and n > 1) {
            try w.get(va);
            try w.i64c(n - 1);
            try w.byte(0x83);
            try w.byte(0x50);
            try w.byte(0x45); // i32.eqz: misaligned
            try e.open(0x04, .other);
            try w.get(0);
            try w.get(va);
            try w.memop(0x37, ctx.off.exit_addr);
            try w.get(0);
            try w.i64c(@as(u64, @intFromEnum(if (store) mem.Access.write else mem.Access.read)) | (@as(u64, @intFromEnum(mem.FaultKind.alignment)) << 8));
            try w.memop(0x37, ctx.off.exit_info);
            try e.retireOn(i.retired);
            try e.leave(.fault, i.aux2);
            try e.end();
        }
        // ent = tlb + ((va >> 12) & 255) * 16, in the read or write table
        try w.get(e.l32(.tlb));
        if (narrow) {
            try w.get(va32);
            try w.i32c(mem.page_shift);
            try w.byte(0x76); // i32.shr_u
        } else {
            try w.get(va);
            try w.i64c(mem.page_shift);
            try w.byte(0x88);
            try w.byte(0xA7);
        }
        try w.i32c(mem.entries - 1);
        try w.byte(0x71);
        try w.i32c(4);
        try w.byte(0x74);
        try w.byte(0x6A);
        try w.tee(ent);
        // hit = tag == va >> 12 && (va & 0xfff) <= page - n
        try w.memop(0x29, @as(u32, if (store) mem.tlb_write_off else 0));
        if (narrow) {
            try w.get(va32);
            try w.i32c(mem.page_shift);
            try w.byte(0x76);
            try w.byte(0xAD); // i64.extend_i32_u
            try w.byte(0x51);
            try w.get(va32);
            try w.i32c(mem.page_size - 1);
            try w.byte(0x71);
            try w.i32c(mem.page_size - n);
            try w.byte(0x4D); // i32.le_u
        } else {
            try w.get(va);
            try w.i64c(mem.page_shift);
            try w.byte(0x88);
            try w.byte(0x51);
            try w.get(va);
            try w.i64c(mem.page_size - 1);
            try w.byte(0x83);
            try w.i64c(mem.page_size - n);
            try w.byte(0x58); // le_u
        }
        try w.byte(0x71); // i32.and
        try w.bytes(&[_]u8{ 0x04, if (store) VOID else vw });
        try e.push(.other);
        // Fast path: host = (va + delta) as i32 (delta's low word, for a
        // narrow address).
        if (narrow) {
            try w.get(va32);
            try w.get(ent);
            try w.memop(0x28, @as(u32, if (store) mem.tlb_write_off else 0) + 8);
            try w.byte(0x6A);
        } else {
            try w.get(va);
            try w.get(ent);
            try w.memop(0x29, @as(u32, if (store) mem.tlb_write_off else 0) + 8);
            try w.byte(0x7C);
            try w.byte(0xA7);
        }
        if (store) {
            try w.get(sv);
            try w.memop(switch (f.size) {
                0 => if (vw == I32) @as(u8, 0x3A) else 0x3C,
                1 => if (vw == I32) @as(u8, 0x3B) else 0x3D,
                2 => if (vw == I32) @as(u8, 0x36) else 0x3E,
                else => 0x37,
            }, 0);
        } else {
            try w.memop(memLoadOp(vw, f.size, f.signed), 0);
        }
        try w.byte(0x05); // else: the slow path
        try w.get(0);
        try w.get(va);
        try w.i32c(f.size);
        if (store) {
            try w.get(sv);
            if (vw == I32) try w.byte(0xAD);
            try w.call(F_SLOW_STORE);
        } else try w.call(F_SLOW_LOAD);
        try w.tee(e.l32(.code));
        try e.open(0x04, .other);
        if (!store and f.rmw) {
            // Report the read-modify-write's fault as a write.
            try w.get(0);
            try w.get(0);
            try w.memop(0x29, ctx.off.exit_info);
            try w.i64c(~@as(u64, 0xff));
            try w.byte(0x83);
            try w.i64c(@intFromEnum(mem.Access.write));
            try w.byte(0x84);
            try w.memop(0x37, ctx.off.exit_info);
        }
        try e.retireOn(i.retired);
        try w.get(0);
        try w.i64c(i.aux2);
        try w.memop(0x37, ctx.off.exit_pc);
        try e.br(.exit);
        try e.end();
        if (!store) {
            try w.get(0);
            try w.memop(0x29, ctx.off.scratch);
            if (f.signed) try w.byte(switch (f.size) {
                0 => 0xC2,
                1 => 0xC3,
                2 => 0xC4,
                else => 0x01, // nop
            });
            if (vw == I32) try w.byte(0xA7);
        }
        try e.end(); // a load leaves its value
        if (!store and f.signed) {
            if (vw == I64) {
                if (vt != .i64) return error.Unsupported;
            } else try e.mask(vt);
        }
    }

    // ---- blocks

    /// A block's instructions but its terminator.
    fn body(e: *E, b: BlockId) !void {
        const blk = e.r.blocks.items[b];
        e.pend = e.pin[b];
        // What came before is unknown here.
        @memset(e.dirty, true);
        for (blk.start..blk.start + blk.len - 1) |idx| {
            if (e.plan.kind[idx] != .root) continue;
            const i = e.r.insts.items[idx];
            try e.inst(idx);
            if (i.ty != .none) {
                if (e.plan.used[idx]) try e.w.set(e.poolLocal(wt(i.ty).?, e.plan.loc[idx])) else try e.w.byte(0x1A);
            }
        }
        // Every terminator is a way out of the block, but a branch to
        // blocks that take the flags still pending.
        if (!e.keep[b]) try e.flushPending();
    }

    /// The Pend a `pending.flags` makes.
    fn pendOf(e: *const E, i: ir.Inst) Pend {
        const a = e.r.insts.items[i.a];
        const lazy = i.aux2 == 1 and e.plan.kind[i.a] == .inl and switch (a.op) {
            .@"eflags.add", .@"eflags.sub", .@"eflags.adc", .@"eflags.sbb", .@"eflags.inc", .@"eflags.dec", .@"eflags.logic", .@"eflags.shl", .@"eflags.shr", .@"eflags.mul" => true,
            else => false,
        };
        return .{ .op = a.op, .ta = e.ty(a.a), .off = @intCast(i.aux), .lazy = lazy, .mask = pendMask(i.aux2), .rec = i.aux2 == 2 };
    }

    /// A lazy record (ir.lazyRecord) into pa, pb, and pc, its a, b, and
    /// res, with its header word (kind, size, and cin) in pcode's low bits
    /// under pcode_rec. The flags op `f` itself isn't emitted: its operands
    /// are values the planner kept (extraOps).
    fn pendingRecord(e: *E, f: ir.Inst, ta: Type) !void {
        const w = &e.w;
        const kind = ir.lazyKind(f.op).?;
        const m = ta.mask();
        const pa = e.l64(.pa);
        const pb = e.l64(.pb);
        const pc = e.l64(.pc);
        const cin = e.scratch(I64, 0);
        const q = e.scratch(I64, 1);
        const incdec = kind == .inc or kind == .dec;
        const carry = f.op == .@"eflags.adc" or f.op == .@"eflags.sbb";
        try e.val64m(f.a, ta);
        try w.set(pa);
        if (f.b != ir.none) {
            if (incdec) try e.val64(f.b) else try e.val64m(f.b, ta);
            try w.set(pb);
        }
        if (carry) {
            try e.val64(f.c);
            try w.set(pc);
        }
        // cin
        if (carry or incdec) {
            try w.get(if (carry) pc else pb);
            try w.i64c(1);
            try w.byte(0x83);
        } else try w.i64c(0);
        try w.set(cin);
        // q = res
        switch (kind) {
            .add, .sub => {
                try w.get(pa);
                try w.get(pb);
                try w.byte(if (kind == .add) 0x7C else 0x7D);
                try w.get(cin);
                try w.byte(if (kind == .add) 0x7C else 0x7D);
                try w.i64c(m);
                try w.byte(0x83);
            },
            .inc, .dec => {
                try w.get(pa);
                try w.i64c(1);
                try w.byte(if (kind == .inc) 0x7C else 0x7D);
                try w.i64c(m);
                try w.byte(0x83);
            },
            .logic => try w.get(pa),
            .shl, .shr, .mul => try w.get(pb),
            .none => unreachable,
        }
        try w.set(q);
        // pc = res; pb = b (1 for inc and dec, 0 but for add and sub);
        // pa = a (CF and OF for mul, 0 for logic).
        try w.get(q);
        try w.set(pc);
        switch (kind) {
            .add, .sub => {},
            .inc, .dec => {
                try w.i64c(1);
                try w.set(pb);
            },
            else => {
                try w.i64c(0);
                try w.set(pb);
            },
        }
        switch (kind) {
            .logic => {
                try w.i64c(0);
                try w.set(pa);
            },
            .mul => {
                try w.get(pa);
                try w.i64c(1);
                try w.byte(0x83);
                try w.set(pa);
            },
            else => {},
        }
        // pcode = pcode_rec | kind | size << 8 | cin << 16
        try w.i64c(pcode_rec | @as(u64, @intFromEnum(kind)) | (@as(u64, ta.bits() / 8) << 8));
        try w.get(cin);
        try w.i64c(16);
        try w.byte(0x86); // i64.shl
        try w.byte(0x84); // i64.or
        try w.set(e.l64(.pcode));
    }

    /// Which blocks take pending flags from their predecessors instead
    /// of each predecessor writing them: a block whose predecessors all
    /// end with the same Pend (and that isn't the entry) starts with it,
    /// and a block whose successors all start with it leaves it pending.
    /// One pass in reverse postorder: a back edge's source isn't done
    /// yet, so a loop header starts with none.
    fn flowPend(e: *E) !void {
        const n = e.r.blocks.items.len;
        e.pin = try e.gpa.alloc(?Pend, n);
        @memset(e.pin, null);
        e.keep = try e.gpa.alloc(bool, n);
        @memset(e.keep, false);
        const out = try e.gpa.alloc(?Pend, n);
        defer e.gpa.free(out);
        const done = try e.gpa.alloc(bool, n);
        defer e.gpa.free(done);
        @memset(done, false);
        // Predecessor counts, to know when all have been seen.
        const npred = try e.gpa.alloc(u32, n);
        defer e.gpa.free(npred);
        @memset(npred, 0);
        for (e.cfg.order) |b| {
            const s = succs(e.r, b);
            for (s[0][0..s[1]]) |t| npred[t] += 1;
        }
        const seen = try e.gpa.alloc(u32, n);
        defer e.gpa.free(seen);
        @memset(seen, 0);
        const meet = try e.gpa.alloc(?Pend, n);
        defer e.gpa.free(meet);
        @memset(meet, null);
        const mixed = try e.gpa.alloc(bool, n);
        defer e.gpa.free(mixed);
        @memset(mixed, false);
        for (e.cfg.order) |b| {
            if (b != 0 and seen[b] == npred[b] and !mixed[b]) e.pin[b] = meet[b];
            var st = e.pin[b];
            const blk = e.r.blocks.items[b];
            for (blk.start..blk.start + blk.len - 1) |idx| {
                if (e.plan.kind[idx] != .root) continue;
                const i = e.r.insts.items[idx];
                switch (i.op) {
                    .@"pending.flags" => st = e.pendOf(i),
                    .setreg => if (st) |p| if (i.aux < p.off + 4 and p.off < i.aux + byteSize(e.ty(i.a)).?) {
                        st = null;
                    },
                    .@"call.interp", .copy => st = null,
                    .@"call.helper" => if (i.aux2 & ir.helper_no_regs == 0) {
                        st = null;
                    },
                    else => {},
                }
            }
            out[b] = st;
            done[b] = true;
            const s = succs(e.r, b);
            for (s[0][0..s[1]]) |t| {
                if (seen[t] == 0) meet[t] = st else if (!std.meta.eql(meet[t], st)) mixed[t] = true;
                if (st == null) mixed[t] = true;
                seen[t] += 1;
            }
        }
        for (e.cfg.order) |b| {
            if (out[b] == null) continue;
            const s = succs(e.r, b);
            if (s[1] == 0) continue;
            var all = true;
            for (s[0][0..s[1]]) |t| if (e.pin[t] == null) {
                all = false;
            };
            e.keep[b] = all;
        }
    }

    /// `pending.flags`: an eflags op used only here is kept as its
    /// operands, and computed only if the flags are written; anything else
    /// is packed now. Either way the Cpu slot is written only on a way out
    /// (flushPending, or the exit tail).
    fn pendingFlags(e: *E, i: ir.Inst) !void {
        const w = &e.w;
        if (e.pend) |p| if (p.off != i.aux or p.mask != pendMask(i.aux2)) try e.flushPending();
        const a = e.r.insts.items[i.a];
        const np = e.pendOf(i);
        if (np.rec) {
            try e.pendingRecord(a, np.ta);
            try w.i32c(@intCast(i.aux));
            try w.set(e.l32(.poff));
            e.pend = np;
            return;
        }
        const ta = np.ta;
        const lazy = np.lazy;
        if (lazy) {
            // As eflagsOf takes them: a and b masked to ta (but inc's and
            // dec's b, which is flags), c as it is.
            const incdec = a.op == .@"eflags.inc" or a.op == .@"eflags.dec";
            try e.val64m(a.a, ta);
            if (a.op != .@"eflags.logic") {
                if (incdec) try e.val64(a.b) else try e.val64m(a.b, ta);
            }
            if (a.op == .@"eflags.adc" or a.op == .@"eflags.sbb") try e.val64(a.c);
            if (a.op == .@"eflags.adc" or a.op == .@"eflags.sbb") try w.set(e.l64(.pc));
            if (a.op != .@"eflags.logic") try w.set(e.l64(.pb));
            try w.set(e.l64(.pa));
            try w.i64c(ir_eval.fallbackCode(a.op, .flags, ta));
        } else {
            try e.val64(i.a);
            try w.i64c(if (i.aux2 == 1) ir_eval.eflags_mask else 0xf000_0000);
            try w.byte(0x83);
            try w.set(e.l64(.pa));
            try w.i64c(if (i.aux2 == 1) ir_eval.eflags_mask else 0xf000_0000);
            try w.set(e.l64(.pb));
            try w.i64c(1);
        }
        try w.set(e.l64(.pcode));
        try w.i32c(@intCast(i.aux));
        try w.set(e.l32(.poff));
        e.pend = np;
    }

    /// Writes the block's pending flags, if any, and forgets them.
    fn flushPending(e: *E) !void {
        const p = e.pend orelse return;
        e.pend = null;
        const w = &e.w;
        if (p.rec) {
            try w.get(e.l32(.cpu));
            try w.get(e.l64(.pcode));
            try w.byte(0xA7); // i32.wrap_i64
            try w.memop(0x36, p.off + 4); // i32.store
            for ([_]fixed64{ .pa, .pb, .pc }, 0..) |l, k| {
                try w.get(e.l32(.cpu));
                try w.get(e.l64(l));
                try w.memop(0x37, p.off + 8 + 8 * k);
            }
            try w.i64c(0);
            try w.set(e.l64(.pcode));
            return;
        }
        try w.get(e.l32(.cpu));
        if (p.lazy) {
            try e.eflagsOf(p.op, p.ta, null);
            try w.i64c(ir_eval.eflags_mask);
            try w.byte(0x83);
        } else try w.get(e.l64(.pa));
        try w.byte(0xA7); // i32.wrap_i64
        // Merged: | (old & ~mask).
        try w.get(e.l32(.cpu));
        try w.memop(0x28, p.off); // i32.load
        try w.i32c(~p.mask);
        try w.byte(0x71); // i32.and
        try w.byte(0x72); // i32.or
        try w.memop(0x36, p.off); // i32.store
        try w.i64c(0);
        try w.set(e.l64(.pcode));
    }

    fn terminator(e: *E, b: BlockId) Ref {
        const blk = e.r.blocks.items[b];
        return blk.start + blk.len - 1;
    }

    /// Ramsey's doTree.
    fn tree(e: *E, x: BlockId) EmitError!void {
        const c = e.cfg;
        const kids = c.kids[c.kid_start[x]..c.kid_start[x + 1]];
        if (c.header[x]) try e.open(0x03, .{ .loop = x });
        try e.within(x, kids, kids.len);
        if (c.header[x]) try e.end();
    }

    /// Ramsey's nodeWithin: x with the merge children in kids[0..n] still
    /// to place, the last (latest in reverse postorder) outermost.
    fn within(e: *E, x: BlockId, kids: []const BlockId, n: usize) EmitError!void {
        var k = n;
        while (k > 0) {
            k -= 1;
            const y = kids[k];
            if (!e.cfg.merge[y]) continue;
            try e.open(0x02, .{ .block = y });
            try e.within(x, kids, k);
            try e.end();
            return e.tree(y);
        }
        try e.body(x);
        const t = e.r.insts.items[e.terminator(x)];
        switch (t.op) {
            .br => try e.branch(x, @intCast(t.aux)),
            .brcond => if (t.aux == t.aux2) {
                try e.branch(x, @intCast(t.aux));
            } else {
                try e.val(t.a);
                try e.open(0x04, .other);
                try e.branch(x, @intCast(t.aux));
                try e.w.byte(0x05);
                try e.branch(x, @intCast(t.aux2));
                try e.end();
            },
            else => try e.inst(e.terminator(x)),
        }
    }

    fn branch(e: *E, from: BlockId, to: BlockId) !void {
        const c = e.cfg;
        if (c.rpo[to] <= c.rpo[from]) return e.br(.{ .loop = to });
        if (c.merge[to]) return e.br(.{ .block = to });
        return e.tree(to);
    }

    /// The fallback: a loop around a br_table on the block index.
    fn dispatch(e: *E) !void {
        const n: u32 = @intCast(e.r.blocks.items.len);
        try e.w.i32c(0);
        try e.w.set(e.l32(.blk));
        try e.open(0x03, .dloop);
        for (0..n) |_| try e.open(0x02, .other);
        try e.w.get(e.l32(.blk));
        try e.w.byte(0x0E);
        try e.w.uleb(n);
        for (0..n) |k| try e.w.uleb(k);
        try e.w.uleb(n - 1);
        for (0..n) |k| {
            try e.end();
            const b: BlockId = @intCast(k);
            if (e.cfg.rpo[b] == Cfg.unreached) {
                try e.w.byte(0x00);
                continue;
            }
            try e.body(b);
            const t = e.r.insts.items[e.terminator(b)];
            switch (t.op) {
                .br => try e.w.i32c(@intCast(t.aux)),
                .brcond => {
                    try e.w.i32c(@intCast(t.aux));
                    try e.w.i32c(@intCast(t.aux2));
                    try e.val(t.a);
                    try e.w.byte(0x1B);
                },
                else => {
                    try e.inst(e.terminator(b));
                    continue;
                },
            }
            try e.w.set(e.l32(.blk));
            try e.br(.dloop);
        }
        try e.end();
    }
};

fn loadOp(t: Type) u8 {
    return switch (t) {
        .i8 => 0x2D, // i32.load8_u
        .i16 => 0x2F,
        .i32 => 0x28,
        else => 0x29,
    };
}

fn storeOp(t: Type) u8 {
    return switch (t) {
        .i8 => 0x3A, // i32.store8
        .i16 => 0x3B,
        .i32 => 0x36,
        else => 0x37,
    };
}

fn memLoadOp(vw: u8, size: u3, signed: bool) u8 {
    if (vw == I32) return switch (size) {
        0 => if (signed) 0x2C else 0x2D,
        1 => if (signed) 0x2E else 0x2F,
        else => 0x28,
    };
    return switch (size) {
        0 => if (signed) 0x30 else 0x31,
        1 => if (signed) 0x32 else 0x33,
        2 => if (signed) 0x34 else 0x35,
        else => 0x29,
    };
}

/// Emits `regions` (each verified) as one module, appended to `out`.
/// `batch` gets the chain cells it needs (empty without Options.cells).
pub fn emitBatch(gpa: Allocator, regions: []const *const ir.Region, opts: Options, out: *std.ArrayList(u8), batch: *Batch) EmitError!void {
    if (regions.len == 0) return error.Unsupported;
    var cells: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer cells.deinit(gpa);
    var entries: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer entries.deinit(gpa);
    for (regions, 0..) |r, ri| {
        if (!entries.contains(r.entry_pc)) try entries.put(gpa, r.entry_pc, @intCast(ri));
        if (opts.cells != 0) for (r.insts.items) |i| if (i.op == .@"exit.chain" and !cells.contains(i.aux)) {
            try cells.put(gpa, i.aux, @intCast(batch.chains.items.len));
            try batch.chains.append(gpa, i.aux);
        };
    }
    var bodies: std.ArrayList([]u8) = .empty;
    defer {
        for (bodies.items) |b| gpa.free(b);
        bodies.deinit(gpa);
    }
    if (opts.layout == .br_table or regions.len == 1) {
        try bodies.append(gpa, try function(gpa, regions, 0, opts, &cells, &entries, batch));
    } else for (0..regions.len) |k| {
        try bodies.append(gpa, try function(gpa, regions[k..][0..1], @intCast(k), opts, &cells, &entries, batch));
    }
    try module(gpa, bodies.items, regions.len, opts, out);
}

/// One function's body (its locals, then its code) for `regions`, which
/// are the batch's from index `first`. One region is a ctx.EntryFn; more
/// take their index as a second parameter.
fn function(
    gpa: Allocator,
    regions: []const *const ir.Region,
    first: u32,
    opts: Options,
    cells: *const std.AutoHashMapUnmanaged(u64, u32),
    entries: *const std.AutoHashMapUnmanaged(u64, u32),
    batch: *Batch,
) EmitError![]u8 {
    var e: E = .{
        .gpa = gpa,
        .w = .{ .gpa = gpa },
        .opts = opts,
        .regions = regions,
        .first = first,
        .cells = cells,
        .entries = entries,
        .regs = &.{},
        .nparams = if (regions.len == 1) 1 else 2,
    };
    defer {
        e.w.b.deinit(gpa);
        e.labels.deinit(gpa);
        e.promoted.deinit(gpa);
        gpa.free(e.regs);
        gpa.free(e.dirty);
    }

    // The guest registers the function uses.
    var regs: std.ArrayList(Reg) = .empty;
    defer regs.deinit(gpa);
    for (regions) |r| for (r.insts.items) |i| {
        if (i.op != .getreg and i.op != .setreg) continue;
        const t = if (i.op == .getreg) i.ty else r.insts.items[i.a].ty;
        if (wt(t) == null) return error.Unsupported;
        const gop = try e.promoted.getOrPut(gpa, @intCast(i.aux));
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(regs.items.len);
            try regs.append(gpa, .{ .off = @intCast(i.aux), .ty = t, .size = byteSize(t).? });
        }
        const g = &regs.items[gop.value_ptr.*];
        if (g.size != byteSize(t).? or t == .v128) g.bad = true;
        g.size = @max(g.size, byteSize(t).?);
        if (i.op == .setreg) g.written = true;
    };
    // A word an FP op ORs its exceptions into, and anything overlapping it,
    // stays in the Cpu, which the op writes.
    for (regions) |r| for (r.insts.items) |i| if (i.op.isFp() and i.aux2 != 0) {
        for (regs.items) |*g| if (g.off < i.aux2 - 1 + 4 and i.aux2 - 1 < g.off + g.size) {
            g.bad = true;
        };
    };
    // A slot flags are pending for is written in the exit tail, through
    // the Cpu, so it stays there, and so does a lazy record's (the kind
    // byte a front end clears, say), or flushRegs would write it over
    // the record.
    for (regions) |rg| for (rg.insts.items) |i| if (i.op == .@"pending.flags") {
        const end = i.aux + 4 + @as(u64, if (i.aux2 == 2) @sizeOf(ir.LazyRecord) else 0);
        for (regs.items) |*g| if (g.off < end and i.aux < g.off + g.size) {
            g.bad = true;
        };
    };
    // Overlapping accesses at different offsets: neither is promoted.
    std.mem.sort(Reg, regs.items, {}, struct {
        fn lt(_: void, a: Reg, b: Reg) bool {
            return a.off < b.off;
        }
    }.lt);
    for (regs.items, 0..) |*a, k| for (regs.items[k + 1 ..]) |*b| {
        if (a.off + a.size <= b.off) break;
        a.bad = true;
        b.bad = true;
    };
    e.promoted.clearRetainingCapacity();
    var keep: std.ArrayList(Reg) = .empty;
    defer keep.deinit(gpa);
    if (opts.promote) for (regs.items) |g| if (!g.bad) {
        try e.promoted.put(gpa, g.off, @intCast(keep.items.len));
        try keep.append(gpa, g);
    };
    e.regs = try keep.toOwnedSlice(gpa);
    e.dirty = try gpa.alloc(bool, e.regs.len);

    // Plans and control flow.
    var pools: Pools = .{};
    defer pools.deinit(gpa);
    const plans = try gpa.alloc(Plan, regions.len);
    var nplans: usize = 0;
    defer {
        for (plans[0..nplans]) |*p| p.deinit(gpa);
        gpa.free(plans);
    }
    const cfgs = try gpa.alloc(Cfg, regions.len);
    var ncfgs: usize = 0;
    defer {
        for (cfgs[0..ncfgs]) |*c| c.deinit(gpa);
        gpa.free(cfgs);
    }
    for (regions, 0..) |r, ri| {
        plans[ri] = try planRegion(gpa, r, &e.promoted, e.regs, &pools);
        nplans += 1;
        cfgs[ri] = try analyze(gpa, r);
        ncfgs += 1;
    }

    // Locals: the parameters, the fixed i32s, registers and pool i32s, then
    // the fixed i64s, registers and pool i64s.
    var nr32: u32 = 0;
    var nr64: u32 = 0;
    for (e.regs) |g| if (is64(g.ty)) {
        nr64 += 1;
    } else {
        nr32 += 1;
    };
    const nf32: u32 = @typeInfo(fixed32).@"enum".fields.len;
    const nf64: u32 = @typeInfo(fixed64).@"enum".fields.len;
    e.base32 = e.nparams;
    e.reg32 = e.base32 + nf32;
    e.pool32 = e.reg32 + nr32;
    e.base64 = e.pool32 + pools.n32;
    e.reg64 = e.base64 + nf64;
    e.pool64 = e.reg64 + nr64;
    const nf128: u32 = @typeInfo(fixed128).@"enum".fields.len;
    e.base128 = e.pool64 + pools.n64;
    e.pool128 = e.base128 + nf128;
    {
        var k32: u32 = 0;
        var k64: u32 = 0;
        for (e.regs) |*g| if (is64(g.ty)) {
            g.local = e.reg64 + k64;
            k64 += 1;
        } else {
            g.local = e.reg32 + k32;
            k32 += 1;
        };
    }
    const w = &e.w;
    try w.uleb(3);
    try w.uleb(nf32 + nr32 + pools.n32);
    try w.byte(I32);
    try w.uleb(nf64 + nr64 + pools.n64);
    try w.byte(I64);
    try w.uleb(nf128 + pools.n128);
    try w.byte(V128);

    // Entry: the Cpu and TLB pointers, and the registers.
    try w.get(0);
    try w.memop(0x28, ctx.off.cpu);
    try w.set(e.l32(.cpu));
    try w.get(0);
    try w.memop(0x28, ctx.off.tlb);
    try w.set(e.l32(.tlb));
    try e.loadRegs();

    try e.open(0x02, .exit);
    try e.open(0x03, .top);
    const n: u32 = @intCast(regions.len);
    if (n > 1) {
        for (0..n) |_| try e.open(0x02, .other);
        try w.get(1);
        try w.byte(0x0E);
        try w.uleb(n);
        for (0..n) |k| try w.uleb(k);
        try w.uleb(n - 1);
    }
    for (regions, 0..) |r, ri| {
        if (n > 1) try e.end();
        e.r = r;
        e.plan = &plans[ri];
        e.cfg = &cfgs[ri];
        try e.flowPend();
        defer {
            gpa.free(e.pin);
            gpa.free(e.keep);
            e.pin = &.{};
            e.keep = &.{};
        }
        if (opts.structured and cfgs[ri].reducible) {
            batch.structured += 1;
            try e.tree(0);
        } else {
            batch.dispatched += 1;
            try e.dispatch();
        }
    }
    try e.end(); // top
    try e.end(); // exit
    try flushRetiredW(w, e.l64(.rp));
    // Flags pending where the region left from inside a block: a lazy
    // record, or flags merged into their slot.
    try w.get(e.l64(.pcode));
    try w.i64c(0);
    try w.byte(0x53); // i64.lt_s: pcode_rec's bit
    try w.bytes(&.{ 0x04, VOID });
    try w.get(e.l32(.cpu));
    try w.get(e.l32(.poff));
    try w.byte(0x6A);
    try w.get(e.l64(.pcode));
    try w.byte(0xA7); // i32.wrap_i64
    try w.memop(0x36, 4); // i32.store
    for ([_]fixed64{ .pa, .pb, .pc }, 0..) |l, k| {
        try w.get(e.l32(.cpu));
        try w.get(e.l32(.poff));
        try w.byte(0x6A);
        try w.get(e.l64(l));
        try w.memop(0x37, 8 + 8 * k);
    }
    try w.byte(0x05); // else
    try w.get(e.l64(.pcode));
    try w.byte(0x50); // i64.eqz
    try w.byte(0x45); // i32.eqz
    try w.bytes(&.{ 0x04, VOID });
    try w.get(e.l32(.cpu));
    try w.get(e.l32(.poff));
    try w.byte(0x6A);
    try w.get(e.l64(.pcode));
    try w.i64c(1);
    try w.byte(0x51); // i64.eq
    try w.bytes(&.{ 0x04, I64 });
    try w.get(e.l64(.pa));
    try w.byte(0x05);
    try w.get(e.l64(.pcode));
    try w.get(e.l64(.pa));
    try w.get(e.l64(.pb));
    try w.get(e.l64(.pc));
    try w.i64c(0);
    try w.call(F_EVAL);
    try w.i64c(ir_eval.eflags_mask);
    try w.byte(0x83);
    try w.byte(0x0B);
    try w.byte(0xA7);
    // Merged into the slot: | (old & ~mask), mask in pb if pcode is 1.
    try w.get(e.l32(.cpu));
    try w.get(e.l32(.poff));
    try w.byte(0x6A);
    try w.memop(0x28, 0); // i32.load
    try w.get(e.l64(.pb));
    try w.i64c(ir_eval.eflags_mask);
    try w.get(e.l64(.pcode));
    try w.i64c(1);
    try w.byte(0x51); // i64.eq
    try w.byte(0x1B); // select
    try w.byte(0xA7);
    try w.i32c(std.math.maxInt(u32));
    try w.byte(0x73); // i32.xor
    try w.byte(0x71); // i32.and
    try w.byte(0x72); // i32.or
    try w.memop(0x36, 0);
    try w.byte(0x0B);
    try w.byte(0x0B);
    try e.flushRegs();
    if (opts.cells != 0) {
        // A chain to a linked region elsewhere: tail-call it.
        try w.get(e.l32(.cell));
        try w.i32c(0);
        try w.get(e.l32(.code));
        try w.i32c(@intFromEnum(ctx.Exit.chain));
        try w.byte(0x46);
        try w.byte(0x1B); // select
        try w.set(e.l32(.cell));
        if (opts.jump) {
            // Unlinked, or indirect: the jump cache may know the target.
            const pc = e.scratch(I64, 0);
            const ent = e.scratch(I32, 0);
            try w.get(e.l32(.cell));
            try w.byte(0x45); // i32.eqz
            try w.get(e.l32(.code));
            try w.i32c(@intFromEnum(ctx.Exit.chain));
            try w.byte(0x46);
            try w.get(e.l32(.code));
            try w.i32c(@intFromEnum(ctx.Exit.indirect));
            try w.byte(0x46);
            try w.byte(0x72); // i32.or
            try w.byte(0x71); // i32.and
            try w.bytes(&.{ 0x04, VOID });
            // ent = ctx.jump + jumpIndex(pc) * 24
            try w.get(0);
            try w.memop(0x29, ctx.off.exit_pc);
            try w.tee(pc);
            // ctx.jumpIndex: ((pc ^ pc >> 12) >> 2) & (jump_entries - 1)
            try w.get(pc);
            try w.i64c(12);
            try w.byte(0x88); // i64.shr_u
            try w.byte(0x85); // i64.xor
            try w.i64c(2);
            try w.byte(0x88); // i64.shr_u
            try w.byte(0xA7); // i32.wrap_i64
            try w.i32c(ctx.jump_entries - 1);
            try w.byte(0x71);
            try w.i32c(@sizeOf(ctx.JumpEntry));
            try w.byte(0x6C); // i32.mul
            try w.get(0);
            try w.memop(0x28, ctx.off.jump);
            try w.byte(0x6A);
            try w.tee(ent);
            try w.memop(0x29, 0);
            try w.get(pc);
            try w.byte(0x51); // i64.eq
            try w.bytes(&.{ 0x04, VOID });
            try w.get(ent);
            try w.memop(0x28, @offsetOf(ctx.JumpEntry, "code"));
            try w.set(e.l32(.cell));
            try w.byte(0x0B);
            try w.byte(0x0B);
        }
        try w.get(e.l32(.cell));
        try w.bytes(&.{ 0x04, VOID });
        try w.get(0);
        try w.get(e.l32(.cell));
        try w.bytes(&.{ 0x13, T_ENTRY, 0 }); // return_call_indirect
        try w.byte(0x0B);
    }
    try w.get(e.l32(.code));
    try w.byte(0x0B); // end function
    return e.w.b.toOwnedSlice(gpa);
}

/// The module around the function bodies: one per region, or one for all
/// `n` behind wrappers.
fn module(gpa: Allocator, bodies: []const []const u8, n: usize, opts: Options, out: *std.ArrayList(u8)) !void {
    const chaining = opts.cells != 0;
    const wrapped = bodies.len == 1 and n > 1;
    var m: W = .{ .gpa = gpa };
    defer m.b.deinit(gpa);
    try m.bytes(&.{ 0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00 });

    var sec: W = .{ .gpa = gpa };
    defer sec.b.deinit(gpa);
    const types = [_][]const u8{
        &.{ 1, I32, 1, I32 }, // entry
        &.{ 5, I64, I64, I64, I64, I64, 1, I64 }, // eval
        &.{ 3, I32, I64, I32, 1, I32 }, // slow_load
        &.{ 4, I32, I64, I32, I64, 1, I32 }, // slow_store
        &.{ 3, I32, I64, I64, 1, I32 }, // interp
        &.{ 5, I32, I64, I64, I64, I64, 1, I64 }, // helper
        &.{ 2, I32, I32, 1, I32 }, // body
        &.{ 5, I32, I64, I32, I64, I64, 1, I32 }, // slow_cas
        &.{ 5, I32, I64, I32, I64, I64, 0 }, // ext
        &.{ 4, I32, I64, I64, I64, 1, I64 }, // a HelperFn, through the table
    };
    try sec.uleb(types.len);
    for (types) |t| {
        try sec.byte(0x60);
        try sec.bytes(t);
    }
    try m.section(1, sec.b.items);

    sec.b.clearRetainingCapacity();
    const imports = [_]struct { []const u8, u32 }{ .{ "eval", 1 }, .{ "slow_load", 2 }, .{ "slow_store", 3 }, .{ "interp", 4 }, .{ "helper", 5 }, .{ "slow_cas", 7 }, .{ "ext", 8 } };
    try sec.uleb(imports.len + 1 + @as(u32, if (chaining) 2 else 0));
    for (imports) |imp| {
        try sec.name("env");
        try sec.name(imp[0]);
        try sec.byte(0x00);
        try sec.uleb(imp[1]);
    }
    try sec.name("env");
    try sec.name("memory");
    try sec.bytes(&.{ 0x02, 0x00, 0x00 }); // memory, min 0 pages
    if (chaining) {
        try sec.name("env");
        try sec.name("table");
        try sec.bytes(&.{ 0x01, 0x70, 0x00, 0x00 }); // funcref table, min 0
        try sec.name("env");
        try sec.name("base");
        try sec.bytes(&.{ 0x03, I32, 0x00 }); // immutable i32
    }
    try m.section(2, sec.b.items);

    // Functions: the bodies, then the wrappers if there are any.
    sec.b.clearRetainingCapacity();
    const nwrap: usize = if (wrapped) n else 0;
    try sec.uleb(bodies.len + nwrap);
    for (bodies) |_| try sec.uleb(if (wrapped) T_BODY else T_ENTRY);
    for (0..nwrap) |_| try sec.uleb(T_ENTRY);
    try m.section(3, sec.b.items);

    sec.b.clearRetainingCapacity();
    try sec.uleb(n + @as(u32, if (n == 1) 1 else 0));
    var nm: [16]u8 = undefined;
    for (0..n) |k| {
        try sec.name(std.fmt.bufPrint(&nm, "r{d}", .{k}) catch unreachable);
        try sec.byte(0x00);
        try sec.uleb(if (wrapped) F_BODY + 1 + k else F_BODY + k);
    }
    if (n == 1) {
        try sec.name("run");
        try sec.byte(0x00);
        try sec.uleb(F_BODY);
    }
    try m.section(7, sec.b.items);

    sec.b.clearRetainingCapacity();
    try sec.uleb(bodies.len + nwrap);
    for (bodies) |b| {
        try sec.uleb(b.len);
        try sec.bytes(b);
    }
    for (0..nwrap) |k| {
        var f: W = .{ .gpa = gpa };
        defer f.b.deinit(gpa);
        try f.uleb(0); // no locals
        try f.get(0);
        try f.i32c(@intCast(k));
        try f.byte(0x12); // return_call
        try f.uleb(F_BODY);
        try f.byte(0x0B);
        try sec.uleb(f.b.items.len);
        try sec.bytes(f.b.items);
    }
    try m.section(10, sec.b.items);
    try out.appendSlice(gpa, m.b.items);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "control flow: loops, merges, and irreducible regions" {
    const gpa = testing.allocator;
    // A diamond inside a loop: b1 heads the loop, b4 merges the diamond.
    var r = try ir.parse(gpa,
        \\b0:
        \\  br -> b1
        \\b1:
        \\  %0 = getreg:i64 #0x0
        \\  %1 = trunc:i1 %0
        \\  brcond %1 -> b2 b3
        \\b2:
        \\  br -> b4
        \\b3:
        \\  br -> b4
        \\b4:
        \\  %2 = getreg:i64 #0x8
        \\  %3 = trunc:i1 %2
        \\  brcond %3 -> b1 b5
        \\b5:
        \\  exit.chain #0x0
    );
    defer r.deinit(gpa);
    var c = try analyze(gpa, &r);
    defer c.deinit(gpa);
    try testing.expect(c.reducible);
    try testing.expect(c.header[1] and !c.header[4]);
    try testing.expect(c.merge[4] and !c.merge[2]);
    try testing.expectEqual(@as(BlockId, 1), c.idom[4]);

    // Two ways into a cycle: irreducible.
    var r2 = try ir.parse(gpa,
        \\b0:
        \\  %0 = const:i1 #0x1
        \\  brcond %0 -> b1 b2
        \\b1:
        \\  br -> b2
        \\b2:
        \\  %1 = const:i1 #0x0
        \\  brcond %1 -> b1 b3
        \\b3:
        \\  exit.chain #0x0
    );
    defer r2.deinit(gpa);
    var c2 = try analyze(gpa, &r2);
    defer c2.deinit(gpa);
    try testing.expect(!c2.reducible);
}

test "values: dead code, trees, and pooled locals" {
    const gpa = testing.allocator;
    var r = try ir.parse(gpa,
        \\b0:
        \\  %0 = getreg:i64 #0x0
        \\  %1 = getreg:i64 #0x8
        \\  %2 = add:i64 %0, %1
        \\  %3 = mul:i64 %2, %2
        \\  %4 = xor:i64 %0, %1
        \\  setreg %3 #0x10
        \\  %6 = const:i64 #0x7
        \\  %7 = sub:i64 %3, %6
        \\  setreg %7 #0x18
        \\  exit.chain #0x0
    );
    defer r.deinit(gpa);
    var regs = [_]Reg{ .{ .off = 0, .ty = .i64, .size = 8 }, .{ .off = 8, .ty = .i64, .size = 8 }, .{ .off = 16, .ty = .i64, .size = 8 }, .{ .off = 24, .ty = .i64, .size = 8 } };
    var promoted: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    defer promoted.deinit(gpa);
    for (regs, 0..) |g, k| try promoted.put(gpa, g.off, @intCast(k));
    var pools: Pools = .{};
    defer pools.deinit(gpa);
    var p = try planRegion(gpa, &r, &promoted, &regs, &pools);
    defer p.deinit(gpa);
    try testing.expectEqualSlices(Kind, &.{ .alias, .alias, .root, .root, .dead, .root, .konst, .inl, .root, .root }, p.kind);
    try testing.expectEqual(@as(u32, 1), pools.n64);
}
