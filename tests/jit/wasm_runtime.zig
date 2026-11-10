//! The JIT's wasm side, for tests/jit/run.mjs under Node: this module
//! plays h9.wasm's part. It owns memory, exports the runtime functions
//! generated modules import (ir_eval's fallback, the slow paths, ha64's
//! call.interp), and builds the modules itself with the wasm emitter.
//! run.mjs compiles each one, as h9-web.js's h9_jit_compile will, runs it,
//! and asks this module whether it matched ir_eval (and, for the tracer,
//! T0).

const std = @import("std");
const vcpu = @import("vcpu");
const ir = vcpu.ir;
const cases = vcpu.emit.cases;
const tracer = vcpu.a64.tracer;
const Ctx = vcpu.ctx.Ctx;

const gpa = std.heap.wasm_allocator;

export fn jit_eval(code: u64, a: u64, b: u64, c: u64, aux: u64) u64 {
    return vcpu.ir_eval.evalOpC(code, a, b, c, aux);
}
// Whichever slow path the Ctx names: the emitter cases run over a mem.Map,
// the tracer over a mem.View.
export fn jit_slow_load(ctx: *Ctx, va: u64, size_log2: u32) u32 {
    const f: vcpu.mem.SlowLoadFn = @ptrFromInt(@as(usize, @intCast(ctx.slow_load)));
    return f(ctx, va, size_log2);
}
export fn jit_slow_store(ctx: *Ctx, va: u64, size_log2: u32, v: u64) u32 {
    const f: vcpu.mem.SlowStoreFn = @ptrFromInt(@as(usize, @intCast(ctx.slow_store)));
    return f(ctx, va, size_log2, v);
}
export fn jit_interp(ctx: *Ctx, handle: u64, pc: u64) u32 {
    return vcpu.a64.lift.interp(ctx, handle, pc);
}
export fn jit_helper(_: *Ctx, _: u64, _: u64, _: u64, _: u64) u64 {
    return 0;
}

var all: []cases.Case = &.{};
var env: *cases.Env = undefined;
var want: cases.Result = undefined;
var module: std.ArrayList(u8) = .empty;

fn emitModule(r: *const ir.Region) !u32 {
    var a = try vcpu.alloc.spillAll(gpa, r);
    defer a.deinit(gpa);
    module.clearRetainingCapacity();
    _ = try vcpu.emit.wasm.emit(gpa, r, &a, &module);
    return @intCast(module.items.len);
}

export fn case_count() u32 {
    if (all.len == 0) {
        all = cases.generate(gpa) catch return 0;
        env = gpa.create(cases.Env) catch return 0;
    }
    return @intCast(all.len);
}

/// Builds case i's module and its ir_eval result. Returns the module's
/// length (at module_ptr()), or 0 on failure.
export fn case_prepare(i: u32) u32 {
    var r = cases.parse(gpa, all[i]) catch return 0;
    defer r.deinit(gpa);
    want = env.evalCase(gpa, &r, all[i]) catch return 0;
    return emitModule(&r) catch 0;
}
export fn module_ptr() [*]const u8 {
    return module.items.ptr;
}
export fn case_reset(i: u32) *Ctx {
    return env.reset(all[i]);
}
export fn case_finish(code: u32) u32 {
    return @intFromBool(cases.same(want, env.result(@enumFromInt(code))));
}
export fn case_text(i: u32) [*]const u8 {
    return all[i].text.ptr;
}
export fn case_text_len(i: u32) u32 {
    return @intCast(all[i].text.len);
}

var ts: *tracer.State = undefined;
var t0_want: tracer.Snapshot = undefined;

/// Runs the tracer program on T0, lifts it, checks ir_eval against T0, and
/// builds its module. Returns the module's length, or 0.
export fn tracer_prepare() u32 {
    ts = gpa.create(tracer.State) catch return 0;
    t0_want = ts.runT0() catch return 0;
    var r = ts.liftRegion(gpa) catch return 0;
    defer r.deinit(gpa);
    const cx = ts.reset();
    if (!ts.check(vcpu.ir_eval.run(gpa, &r, cx) catch return 0, t0_want)) return 0;
    return emitModule(&r) catch 0;
}
export fn tracer_reset() *Ctx {
    return ts.reset();
}
export fn tracer_finish(code: u32) u32 {
    return @intFromBool(ts.check(@enumFromInt(code), t0_want));
}
export fn tracer_x(i: u32) u64 {
    return ts.cpu.r[i];
}

// ---------------------------------------------------------------- batches

/// Builds cases[first..first+count] as one module (no chaining), in the
/// br_table layout if `br_table`. Returns its length.
export fn batch_prepare(first: u32, count: u32, br_table: u32) u32 {
    return batchPrepare(first, count, br_table != 0) catch 0;
}
fn batchPrepare(first: u32, count: u32, br_table: bool) !u32 {
    const rs = try gpa.alloc(ir.Region, count);
    var n: usize = 0;
    defer {
        for (rs[0..n]) |*r| r.deinit(gpa);
        gpa.free(rs);
    }
    const ptrs = try gpa.alloc(*const ir.Region, count);
    defer gpa.free(ptrs);
    for (0..count) |k| {
        rs[k] = try cases.parse(gpa, all[first + k]);
        n += 1;
        ptrs[k] = &rs[k];
    }
    module.clearRetainingCapacity();
    var b: vcpu.emit.wasm.Batch = .{};
    defer b.deinit(gpa);
    try vcpu.emit.wasm.emitBatch(gpa, ptrs, .{ .layout = if (br_table) .br_table else .functions }, &module, &b);
    return @intCast(module.items.len);
}

/// Runs case i through the region installed at table slot `slot`, called
/// as a function pointer, and checks it against ir_eval.
export fn case_run(i: u32, slot: u32) u32 {
    var r = cases.parse(gpa, all[i]) catch return 0;
    defer r.deinit(gpa);
    const w = env.evalCase(gpa, &r, all[i]) catch return 0;
    const f: vcpu.ctx.EntryFn = @ptrFromInt(slot);
    const code = f(env.reset(all[i]));
    return @intFromBool(cases.same(w, env.result(@enumFromInt(code))));
}

// ---------------------------------------------------------------- fuzzing

const gen = @import("gen.zig");

/// A run of random regions: region k is at guest PC 0x1000 * (k + 1).
const Fuzz = struct {
    regions: std.ArrayList(ir.Region) = .empty,
    /// Table slot of each region, or 0 while it isn't installed.
    slots: std.ArrayList(u32) = .empty,
    batches: std.ArrayList(B) = .empty,
    text: std.Io.Writer.Allocating = undefined,

    const B = struct { first: u32, count: u32, cells: []u32, chains: []u64, chaining: bool, base: u32 = 0 };

    fn pc(k: usize) u64 {
        return 0x1000 * (k + 1);
    }
};
var fz: Fuzz = .{};
/// Counts, for checking the fuzzing reaches what it should: exits by code
/// (0..7), chains taken (8), and regions lowered structured (9) and by
/// the dispatch loop (10).
var stats: [11]u32 = @splat(0);
export fn fuzz_stat(k: u32) u32 {
    return stats[k];
}
/// Test knobs: 1 keeps registers out of locals.
var fz_opts: u32 = 0;
export fn fuzz_opts(o: u32) void {
    fz_opts = o;
}
var diag: std.Io.Writer.Allocating = undefined;
var diag_on = false;
/// What the last failing fuzz_run saw.
export fn fuzz_diag() [*]const u8 {
    return diag.written().ptr;
}
export fn fuzz_diag_len() u32 {
    return if (diag_on) @intCast(diag.written().len) else 0;
}

/// Starts a run of `count` random regions from `seed`.
export fn fuzz_reset(seed: u32, count: u32) u32 {
    fuzzReset(seed, count) catch return 0;
    return 1;
}
fn fuzzReset(seed: u32, count: u32) !void {
    if (all.len == 0) _ = case_count();
    for (fz.regions.items) |*r| r.deinit(gpa);
    fz.regions.clearRetainingCapacity();
    fz.slots.clearRetainingCapacity();
    for (fz.batches.items) |b| {
        gpa.free(b.cells);
        gpa.free(b.chains);
    }
    fz.batches.clearRetainingCapacity();
    var prng = std.Random.DefaultPrng.init(seed);
    const pcs = try gpa.alloc(u64, count);
    defer gpa.free(pcs);
    for (pcs, 0..) |*p, k| p.* = Fuzz.pc(k);
    for (0..count) |k| {
        var r = try gen.region(gpa, prng.random(), Fuzz.pc(k), pcs);
        if (ir.verify(&r)) |_| {
            r.deinit(gpa);
            return error.Invalid;
        }
        try fz.regions.append(gpa, r);
        try fz.slots.append(gpa, 0);
    }
}

/// Builds regions[first..first+count] as one module, with chain cells if
/// `chaining`. Flags: 1 forces dispatch loops, 2 the br_table layout.
/// Returns its length.
export fn fuzz_emit(first: u32, count: u32, chaining: u32, flags: u32) u32 {
    return fuzzEmit(first, count, chaining != 0, flags) catch 0;
}
fn fuzzEmit(first: u32, count: u32, chaining: bool, flags: u32) !u32 {
    const ptrs = try gpa.alloc(*const ir.Region, count);
    defer gpa.free(ptrs);
    for (ptrs, 0..) |*p, k| p.* = &fz.regions.items[first + k];
    var b: vcpu.emit.wasm.Batch = .{};
    defer b.deinit(gpa);
    // The cells' address goes into the code, so allocate them first, one
    // per chain target there could be.
    const cells = try gpa.alloc(u32, fz.regions.items.len + 1);
    @memset(cells, 0);
    module.clearRetainingCapacity();
    try vcpu.emit.wasm.emitBatch(gpa, ptrs, .{ .cells = if (chaining) @intFromPtr(cells.ptr) else 0, .structured = flags & 1 == 0, .layout = if (flags & 2 != 0) .br_table else .functions, .promote = fz_opts & 1 == 0 }, &module, &b);
    stats[9] += b.structured;
    stats[10] += b.dispatched;
    try fz.batches.append(gpa, .{ .first = first, .count = count, .cells = cells, .chains = try gpa.dupe(u64, b.chains.items), .chaining = chaining });
    return @intCast(module.items.len);
}

/// The last module built is installed at slots base.. .
export fn fuzz_installed(base: u32) void {
    const b = &fz.batches.items[fz.batches.items.len - 1];
    b.base = base;
    for (0..b.count) |k| fz.slots.items[b.first + k] = base + @as(u32, @intCast(k));
}

/// Batch k was dropped: its regions are gone.
export fn fuzz_dropped(k: u32) void {
    const b = fz.batches.items[k];
    for (0..b.count) |j| fz.slots.items[b.first + j] = 0;
}

/// Points every cell at the region now installed for its PC (or 0).
export fn fuzz_link() void {
    for (fz.batches.items) |b| for (b.chains, 0..) |p, k| {
        b.cells[k] = if (p % 0x1000 == 0 and p / 0x1000 - 1 < fz.slots.items.len) fz.slots.items[@intCast(p / 0x1000 - 1)] else 0;
    };
}

/// Runs from region `start` with registers from `seed` and the given
/// budget, through its installed code and through ir_eval, following
/// chains to installed regions the way linked cells do. 1 if they agree.
export fn fuzz_run(start: u32, seed: u32, budget: u32) u32 {
    return fuzzRun(start, seed, budget) catch 0;
}
fn fuzzRun(start: u32, seed: u32, budget: u32) !u32 {
    if (fz.slots.items[start] == 0) return 1; // dropped
    var prng = std.Random.DefaultPrng.init(seed);
    var c: cases.Case = .{ .text = "", .regs = undefined };
    for (&c.regs) |*x| x.* = prng.random().int(u64) >> @intCast(prng.random().uintLessThan(u32, 64));
    c.regs[gen.fuel_off / 8] = prng.random().intRangeAtMost(u64, 1, 300);

    // ir_eval, chaining like the linked cells.
    var cx = env.reset(c);
    cx.budget = budget;
    var k = start;
    const want_exit = while (true) {
        const e = try vcpu.ir_eval.run(gpa, &fz.regions.items[k], cx);
        if (e != .chain or !batchOf(k).chaining) break e;
        stats[8] += 1;
        const p = cx.exit_pc;
        if (p % 0x1000 != 0 or p / 0x1000 - 1 >= fz.slots.items.len or fz.slots.items[@intCast(p / 0x1000 - 1)] == 0) break e;
        k = @intCast(p / 0x1000 - 1);
    };
    const w = env.result(want_exit);
    const w_retired = cx.retired;

    cx = env.reset(c);
    cx.budget = budget;
    const f: vcpu.ctx.EntryFn = @ptrFromInt(fz.slots.items[start]);
    const code = f(cx);
    const got = env.result(@enumFromInt(code));
    if (code < 8) stats[code] += 1;
    const ok = cases.same(w, got) and cx.retired == w_retired;
    if (!ok) {
        if (!diag_on) diag = .init(gpa);
        diag_on = true;
        diag.clearRetainingCapacity();
        diag.writer.print("want {any} retired {d}\n got {any} retired {d}\n", .{ w, w_retired, got, cx.retired }) catch {};
    }
    return @intFromBool(ok);
}

fn batchOf(k: u32) Fuzz.B {
    for (fz.batches.items) |b| if (k >= b.first and k < b.first + b.count) return b;
    unreachable;
}

/// Region k's text, for a failure report.
export fn fuzz_text(k: u32) [*]const u8 {
    fz.text = .init(gpa);
    ir.print(&fz.regions.items[k], &fz.text.writer) catch {};
    return fz.text.written().ptr;
}
export fn fuzz_text_len() u32 {
    return @intCast(fz.text.written().len);
}

/// Runs the tracer through the region installed at `slot`.
export fn tracer_run(slot: u32) u32 {
    const f: vcpu.ctx.EntryFn = @ptrFromInt(slot);
    return tracer_finish(f(ts.reset()));
}

/// n status words for h9_jit_compile, zeroed.
export fn status_alloc(n: u32) ?[*]i32 {
    const s = gpa.alloc(i32, n) catch return null;
    @memset(s, 0);
    return s.ptr;
}

// ---------------------------------------------------------------- benches

/// A counted loop for tests/jit/bench.mjs: x0 += x1 and SUBS x1, x1, #1
/// with NZCV written back, until x1 is 0, then svc. Returns the module's
/// length.
const bench_text =
        \\region 0x1000
        \\b0:
        \\  poll #0x1000
        \\  br -> b1
        \\b1:
        \\  %0 = getreg:i64 #0x0
        \\  %1 = getreg:i64 #0x8
        \\  %2 = add:i64 %0, %1
        \\  setreg %2 #0x0
        \\  %3 = const:i64 #0x1
        \\  %4 = sub:i64 %1, %3
        \\  setreg %4 #0x8
        \\  %5 = nzcv.sub:flags %1, %3
        \\  %6 = nzcv.pack:i32 %5
        \\  setreg %6 #0x10
        \\  retire #0x3
        \\  %7 = nzcv.cond:i1 %5 #0x1
        \\  brcond %7 -> b1 b2
        \\b2:
    \\  exit.svc #0x100c
;

export fn bench_prepare() u32 {
    var r = ir.parse(gpa, bench_text) catch return 0;
    defer r.deinit(gpa);
    if (ir.verify(&r) != null) return 0;
    return emitModule(&r) catch 0;
}

/// The loop as region 0 of a batch of `n`, the rest random, in the
/// br_table layout if `br_table`. Returns the module's length.
export fn bench_batch(n: u32, br_table: u32) u32 {
    return benchBatch(n, br_table != 0) catch 0;
}
fn benchBatch(n: u32, br_table: bool) !u32 {
    try fuzzReset(n, n);
    var loop = try ir.parse(gpa, bench_text);
    defer loop.deinit(gpa);
    const ptrs = try gpa.alloc(*const ir.Region, n);
    defer gpa.free(ptrs);
    ptrs[0] = &loop;
    for (ptrs[1..], fz.regions.items[1..]) |*p, *r| p.* = r;
    module.clearRetainingCapacity();
    var b: vcpu.emit.wasm.Batch = .{};
    defer b.deinit(gpa);
    try vcpu.emit.wasm.emitBatch(gpa, ptrs, .{ .layout = if (br_table) .br_table else .functions }, &module, &b);
    return @intCast(module.items.len);
}

/// Runs the loop `iters` times through `slot`; 1 if x0 is right.
export fn bench_run(slot: u32, iters: u32) u32 {
    var c: cases.Case = .{ .text = "", .regs = @splat(0) };
    c.regs[1] = iters;
    const f: vcpu.ctx.EntryFn = @ptrFromInt(slot);
    const code = f(env.reset(c));
    const n: u64 = iters;
    return @intFromBool(code == @intFromEnum(vcpu.ctx.Exit.svc) and env.regs[0] == n * (n + 1) / 2);
}

/// A context to enter random regions with, for timing their first calls.
export fn bench_ctx() *Ctx {
    return env.reset(.{ .text = "", .regs = @splat(0) });
}
