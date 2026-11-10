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
export fn jit_slow_load(ctx: *Ctx, va: u64, size_log2: u32) u32 {
    return vcpu.mem.mapSlowLoad(ctx, va, size_log2);
}
export fn jit_slow_store(ctx: *Ctx, va: u64, size_log2: u32, v: u64) u32 {
    return vcpu.mem.mapSlowStore(ctx, va, size_log2, v);
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
