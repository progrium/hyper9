//! h86: h9's own CPU for 386 binaries, as a Guest of vmm/zemu.zig
//! (-Demu=zig), which has the interface. Its CPU is in src/interp/x86/ and
//! src/jit/x86/, with the shared JIT layer in src/jit/ (src/vcpu.zig).
//!
//! T0, the interpreter (interp/x86/exec.zig), reaches guest memory through
//! the vCPU's TLB: mem.fast and mem.fastExec on a hit, and mem.probe, which
//! fills the entry, on a miss. With `tier` at .t1 and a code cache, compiled
//! code runs (src/jit/dispatch.zig), and T0 runs what it hands back. On the
//! web host T1 is src/jit/wasm_t1.zig's, compiling hot blocks to wasm.

const std = @import("std");
const builtin = @import("builtin");
const vmm = @import("../vmm.zig");
const Ctx = @import("vcpu").ctx.Ctx;
const mem = @import("vcpu").mem;
const x86cpu = @import("vcpu").x86.cpu;
const exec = @import("vcpu").x86.exec;
const tlb = @import("vcpu").x86.tlb;
const cache = @import("vcpu").cache;
const dispatch = @import("vcpu").dispatch;
const emitter = @import("vcpu").emitter;
const lift = @import("vcpu").x86jit.lift;
const helpers = @import("vcpu").x86jit.helpers;
const wasm_t1 = @import("vcpu").wasm_t1;
const build_options = @import("build_options");
const vmm_check = @import("vcpu").x86jit.vmm_check;

/// Which tier runs guest code: T0 alone, or T1 (src/jit/dispatch.zig)
/// when the backend has a code cache and this host an emitter. T1 is the
/// default on x86-64 hosts, where the 386 suite passes on it; arm64 and
/// the web stay on T0 until their emitters pass it for h86. H9_EMU_TIER
/// picks either (zemu.applyTier).
pub const Tier = enum { t0, t1 };
pub var tier: Tier = if (builtin.cpu.arch == .x86_64) .t1 else .t0;
/// T1's emitter; null where this host has none yet.
pub var t1_emitter: ?emitter.Emitter = switch (builtin.cpu.arch) {
    .aarch64 => @import("vcpu").emit.arm64.emitter_def,
    .x86_64 => @import("vcpu").emit.x64.emitter_def,
    else => null,
};
pub var t1_stats: dispatch.Stats = .{};

pub const arch: vmm.Arch = .i386;
pub const ready = true;

pub const Cpu = struct {
    c: x86cpu.Cpu = .{},
    /// T0's decoded instructions, which `run` points `c` at.
    icache: exec.ICache = .{},
    /// -Djit-check's state (src/jit/x86/vmm_check.zig).
    check: vmm_check.State = .{},
};

/// Frees -Djit-check's state.
pub fn deinit(c: *Cpu) void {
    c.check.deinit();
}

pub fn getUreg(c: *const Cpu, u: *vmm.Ureg) void {
    u.* = .{ .i386 = .{} };
    c.c.getUreg(&u.i386);
}

pub fn setUreg(c: *Cpu, u: *const vmm.Ureg) void {
    c.c.setUreg(&u.i386);
}

pub fn getExtra(c: *const Cpu, x: *vmm.Extra) vmm.Error!void {
    x.* = .{ .i386 = .{} };
    c.c.getExtra(&x.i386);
}

pub fn setExtra(c: *Cpu, x: *const vmm.Extra) vmm.Error!void {
    c.c.setExtra(&x.i386);
}

const TlbMem = tlb.TlbMem;

/// Runs T0 until an exit. An exit request (ctx.exit_request, which zemu
/// clears) or a spent ctx.budget gives `.interrupted`.
pub fn run(cpu: *Cpu, ctx: *Ctx) vmm.Error!vmm.Exit {
    const c = &cpu.c;
    c.icache = &cpu.icache;
    var m: TlbMem = .{ .ctx = ctx, .tlb = @ptrFromInt(@as(usize, @intCast(ctx.tlb))) };
    const stop: *const std.atomic.Value(u32) = @ptrCast(&ctx.exit_request);
    if (stop.load(.acquire) != 0) return .interrupted;
    // The lifter's call.helper table (x87).
    ctx.helpers = helpers.tableAddr();
    // -Djit-check: every region lifted and checked against T0.
    if (build_options.jit_check) return exitOf(c, ctx, vmm_check.run(&cpu.check, c, ctx, &m));
    if (tier == .t1 and builtin.cpu.arch == .wasm32 and wasm_t1.available()) return runWasmT1(c, ctx, &m);
    if (tier == .t1) if (t1_emitter) |em| if (cache.Runtime.of(ctx).cache != null) return runT1(c, ctx, &m, em);
    const budget: u64 = if (ctx.budget <= 0) 0 else @intCast(ctx.budget);
    return exitOf(c, ctx, runT0(c, ctx, &m, budget));
}

/// T0 for up to `budget` instructions, counting them in ctx.
fn runT0(c: *x86cpu.Cpu, ctx: *Ctx, m: *TlbMem, budget: u64) x86cpu.Exit {
    return runT0Opts(c, ctx, m, budget, 0);
}

/// T0, stopping after `branches` taken branches if that's nonzero.
fn runT0Opts(c: *x86cpu.Cpu, ctx: *Ctx, m: *TlbMem, budget: u64, branches: u32) x86cpu.Exit {
    const stop: *const std.atomic.Value(u32) = @ptrCast(&ctx.exit_request);
    const before = c.retired;
    const exit = tlb.run(c, m, .{ .budget = budget, .stop = stop, .branches = branches });
    const ran = c.retired - before;
    ctx.retired +%= ran;
    if (ctx.budget != std.math.maxInt(i64)) ctx.budget -= @intCast(@min(ran, std.math.maxInt(i63)));
    return exit;
}

/// T1: compiled code, with T0 for each instruction that raises an
/// exception or stores to code. Compiled code spends ctx.budget and counts
/// ctx.retired itself; the lifter's `call.interp` reaches T0's memory
/// through a lift.Mem in ctx.frontend.
fn runT1(c: *x86cpu.Cpu, ctx: *Ctx, m: *TlbMem, em: emitter.Emitter) vmm.Error!vmm.Exit {
    var lm: lift.Mem = .{ .ctx = m, .translateFn = TlbMem.translateFn };
    ctx.frontend = @intFromPtr(&lm);
    // The lifter's getreg and setreg offsets are into x86cpu.Cpu.
    const outer = ctx.cpu;
    ctx.cpu = @intFromPtr(c);
    defer ctx.cpu = outer;
    ctx.interp = @intFromPtr(&lift.interp);
    const cfg: dispatch.Config = .{
        .frontend = lift.frontend,
        .emitter = em,
        .pc_off = @offsetOf(x86cpu.Cpu, "eip"),
        .pc_bytes = 4,
        .pc_align = 1,
    };
    while (true) {
        // T0 counts Cpu.retired again in each `call.interp`: ctx's count is
        // the one that holds.
        const before = ctx.retired;
        const c_before = c.retired;
        const r = dispatch.run(if (builtin.cpu.arch == .wasm32) std.heap.c_allocator else std.heap.smp_allocator, ctx, cfg, &t1_stats);
        c.retired = c_before +% (ctx.retired -% before);
        switch (r) {
            // Compiled code leaves Cpu.fl's bits current (lift.zig).
            .svc => return .syscall,
            .interrupted => return .interrupted,
            .t0 => {
                if (ctx.budget <= 0) return .interrupted;
                const e = runT0(c, ctx, m, 1);
                if (e != .stopped) return exitOf(c, ctx, e);
                if (@atomicLoad(u32, &ctx.exit_request, .seq_cst) != 0) return .interrupted;
            },
        }
    }
}

/// T1 on the web host (src/jit/wasm_t1.zig): compiled code for hot
/// blocks, T0 to the next taken branch for cold ones, so their heads come
/// back to be counted.
fn runWasmT1(c: *x86cpu.Cpu, ctx: *Ctx, m: *TlbMem) vmm.Error!vmm.Exit {
    var lm: lift.Mem = .{ .ctx = m, .translateFn = TlbMem.translateFn };
    ctx.frontend = @intFromPtr(&lm);
    const outer = ctx.cpu;
    ctx.cpu = @intFromPtr(c);
    defer ctx.cpu = outer;
    ctx.interp = @intFromPtr(&lift.interp);
    const cfg: wasm_t1.Config = .{
        .frontend = lift.frontend,
        .pc_off = @offsetOf(x86cpu.Cpu, "eip"),
        .pc_bytes = 4,
        .pc_align = 1,
    };
    while (true) {
        const before = ctx.retired;
        const c_before = c.retired;
        const r = wasm_t1.run(std.heap.c_allocator, ctx, cfg);
        c.retired = c_before +% (ctx.retired -% before);
        switch (r) {
            .svc => return .syscall,
            .interrupted => return .interrupted,
            .t0, .cold => {
                if (ctx.budget <= 0) return .interrupted;
                const budget: u64 = if (r == .t0) 1 else @intCast(ctx.budget);
                const e = runT0Opts(c, ctx, m, budget, if (r == .cold) wasm_t1.cold_branches else 0);
                if (e != .stopped) return exitOf(c, ctx, e);
                if (@atomicLoad(u32, &ctx.exit_request, .seq_cst) != 0) return .interrupted;
            },
        }
    }
}

fn exitOf(c: *x86cpu.Cpu, ctx: *Ctx, exit: x86cpu.Exit) vmm.Exit {
    return switch (exit) {
        .syscall => .syscall,
        .breakpoint => .breakpoint,
        .fault => |f| .{ .fault = .{
            .addr = f.addr,
            .access = switch (f.access) {
                .read => .read,
                .write => .write,
                .exec => .exec,
            },
            .syndrome = ctx.exit_info,
        } },
        // As the emulator backend reports CPU exceptions: at the PC, with
        // the vector in the syndrome and Ureg.trap.
        .exception => |v| .{ .fault = .{ .addr = c.eip, .access = .exec, .syndrome = v } },
        .stopped => .interrupted,
    };
}
