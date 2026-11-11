//! hx64: h9's own CPU for amd64 binaries, as a Guest of vmm/zemu.zig
//! (-Demu=zig), which has the interface. It's h86 in long mode
//! (design/hcpu.md, hx64): the same decoder, T0, and lifter in
//! src/interp/x86/ and src/jit/x86/, instantiated with `.long`.
//!
//! Guest code runs on T1 (the lifter's LifterOf(.long), through
//! dispatch.zig natively and wasm_t1.zig on the web) or on T0
//! (tlb.runIn(.long)), with h86's decode caches. spec/hx64.md has the rest.

const std = @import("std");
const builtin = @import("builtin");
const vmm = @import("../vmm.zig");
const amd64 = @import("../arch/amd64.zig");
const Ctx = @import("vcpu").ctx.Ctx;
const x86cpu = @import("vcpu").x86.cpu;
const tlb = @import("vcpu").x86.tlb;
const exec = @import("vcpu").x86.exec;
const dispatch = @import("vcpu").dispatch;
const wasm_t1 = @import("vcpu").wasm_t1;
const cache = @import("vcpu").cache;
const emitter = @import("vcpu").emitter;
const lift = @import("vcpu").x86jit.lift;
const helpers = @import("vcpu").x86jit.helpers;
const check_vmm = @import("vcpu").check_vmm;
const build_options = @import("build_options");

/// Which tier runs guest code: T0 alone, or T1 (src/jit/dispatch.zig)
/// when the backend has a code cache and this host an emitter, as for
/// h86, and on the web host its own (wasm_t1.zig, runWasmT1). T1 is the
/// default on x86-64, arm64, and the web. H9_EMU_TIER picks either
/// (zemu.applyTier).
pub const Tier = enum { t0, t1 };
pub var tier: Tier = if (!build_options.jit) .t0 else switch (builtin.cpu.arch) {
    .x86_64, .aarch64, .wasm32 => .t1,
    else => .t0,
};
/// T1's emitter; null where this host has none, or in a -Dno-jit build.
pub var t1_emitter: ?emitter.Emitter = if (!build_options.jit) null else switch (builtin.cpu.arch) {
    .aarch64 => @import("vcpu").emit.arm64.emitter_def,
    .x86_64 => @import("vcpu").emit.x64.emitter_def,
    else => null,
};
pub var t1_stats: dispatch.Stats = .{};

pub const arch: vmm.Arch = .amd64;
pub const ready = true;

pub const Cpu = struct {
    c: x86cpu.CpuOf(.long) = .{},
    /// T0's decoded instructions, by address and by page, which `run`
    /// allocates on first use and points `c` at.
    icache: ?*exec.ICacheOf(.long) = null,
    pages: ?*exec.PageCacheOf(.long) = null,
    /// -Djit-check's state (src/jit/check/vmm.zig).
    check: check_vmm.State = .{},
};

/// What the decode caches come from.
const icache_gpa = vmm.host_gpa;

/// Frees -Djit-check's state and the decode caches.
pub fn deinit(cpu: *Cpu) void {
    if (build_options.jit_check) cpu.check.deinit();
    if (cpu.icache) |ic| icache_gpa.destroy(ic);
    cpu.icache = null;
    if (cpu.pages) |pc| {
        pc.deinit();
        icache_gpa.destroy(pc);
    }
    cpu.pages = null;
    cpu.c.icache = null;
    cpu.c.pages = null;
}

pub fn getUreg(cpu: *const Cpu, u: *vmm.Ureg) void {
    const c = &cpu.c;
    u.* = .{ .amd64 = .{
        .ax = c.r[0],
        .cx = c.r[1],
        .dx = c.r[2],
        .bx = c.r[3],
        .sp = c.r[4],
        .bp = c.r[5],
        .si = c.r[6],
        .di = c.r[7],
        .r8 = c.r[8],
        .r9 = c.r[9],
        .r10 = c.r[10],
        .r11 = c.r[11],
        .r12 = c.r[12],
        .r13 = c.r[13],
        .r14 = c.r[14],
        .r15 = c.r[15],
        .pc = c.rip,
        .flags = c.fl.get(),
        .cs = amd64.UESEL,
        .ss = amd64.UDSEL,
        .type = c.trap,
        .@"error" = c.ecode,
    } };
}

pub fn setUreg(cpu: *Cpu, u: *const vmm.Ureg) void {
    const c = &cpu.c;
    const a = &u.amd64;
    c.r = .{ a.ax, a.cx, a.dx, a.bx, a.sp, a.bp, a.si, a.di, a.r8, a.r9, a.r10, a.r11, a.r12, a.r13, a.r14, a.r15 };
    c.rip = a.pc;
    c.fl.set(@truncate(a.flags));
    c.trap = a.type;
    c.ecode = a.@"error";
}

/// The x87, MMX, and SSE state as the 64-bit FXSAVE image, and the FS and
/// GS bases.
pub fn getExtra(cpu: *const Cpu, x: *vmm.Extra) vmm.Error!void {
    const c = &cpu.c;
    x.* = .{ .amd64 = .{} };
    const t = &x.amd64;
    const fx = &t.fx;
    const p = &c.fpu;
    fx.fcw = p.cw;
    fx.fsw = (p.sw & ~@as(u16, 0x3800)) | (@as(u16, p.top) << 11);
    fx.ftw = p.tag;
    fx.fop = p.fop;
    fx.fip = p.fip;
    fx.fdp = p.fdp;
    fx.mxcsr = c.mxcsr;
    fx.mxcsr_mask = 0xffff;
    for (&fx.st, 0..) |*st, i| {
        const v = p.st[(@as(usize, p.top) + i) & 7];
        std.mem.writeInt(u64, st[0..8], v.signif, .little);
        std.mem.writeInt(u16, st[8..10], v.sign_exp, .little);
    }
    @memcpy(fx.xmm[0..16], &c.xmm);
    t.tls = c.fs_base;
    t.gs = c.gs_base;
}

pub fn setExtra(cpu: *Cpu, x: *const vmm.Extra) vmm.Error!void {
    const c = &cpu.c;
    const t = &x.amd64;
    const fx = &t.fx;
    const p = &c.fpu;
    p.cw = fx.fcw;
    p.top = @truncate(fx.fsw >> 11);
    p.sw = fx.fsw & ~@as(u16, 0x3800);
    p.tag = fx.ftw;
    p.fop = fx.fop;
    p.fip = fx.fip;
    p.fdp = fx.fdp;
    // MXCSR's reserved bits would fault FXRSTOR; keep them clear.
    c.mxcsr = fx.mxcsr & 0xffff;
    for (&fx.st, 0..) |*st, i| {
        p.st[(@as(usize, p.top) + i) & 7] = .{
            .signif = std.mem.readInt(u64, st[0..8], .little),
            .sign_exp = std.mem.readInt(u16, st[8..10], .little),
        };
    }
    @memcpy(&c.xmm, fx.xmm[0..16]);
    c.fs_base = t.tls;
    c.gs_base = t.gs;
}

/// Instructions retired, for zemu.retired_total.
pub fn retired(cpu: *const Cpu) u64 {
    return cpu.c.retired;
}

/// Runs T0 until an exit. An exit request (ctx.exit_request, which zemu
/// clears) or a spent ctx.budget gives `.interrupted`.
pub fn run(cpu: *Cpu, ctx: *Ctx) vmm.Error!vmm.Exit {
    const c = &cpu.c;
    if (cpu.icache == null) {
        // Without one T0 runs, decoding every instruction.
        if (icache_gpa.create(exec.ICacheOf(.long))) |ic| {
            ic.init();
            cpu.icache = ic;
        } else |_| {}
    }
    if (cpu.pages == null) {
        if (icache_gpa.create(exec.PageCacheOf(.long))) |pc| {
            pc.init(icache_gpa);
            cpu.pages = pc;
        } else |_| {}
    }
    c.icache = cpu.icache;
    c.pages = cpu.pages;
    var m: tlb.TlbMem = .init(ctx);
    const stop: *const std.atomic.Value(u32) = @ptrCast(&ctx.exit_request);
    if (stop.load(.acquire) != 0) return .interrupted;
    // The lifter's call.helper table (x87).
    if (build_options.jit) ctx.helpers = helpers.tableAddr();
    // -Djit-check: every region lifted and checked against T0, in T1's loop.
    if (build_options.jit_check) return runT1(cpu, ctx, &m, t1_emitter orelse undefined);
    if (build_options.jit and tier == .t1 and builtin.cpu.arch == .wasm32 and wasm_t1.available()) return runWasmT1(c, ctx, &m);
    if (build_options.jit and builtin.cpu.arch != .wasm32 and tier == .t1) if (t1_emitter) |em| if (cache.Runtime.of(ctx).cache != null) return runT1(cpu, ctx, &m, em);
    const left = loadBudget(ctx);
    const budget: u64 = if (left <= 0) 0 else @intCast(left);
    return exitOf(c, ctx, runT0(c, ctx, &m, budget));
}

/// ctx.budget, read once: a kick stores to it from another thread
/// (cache.requestExit). The web host has one thread and no 64-bit atomics.
fn loadBudget(ctx: *Ctx) i64 {
    return if (builtin.cpu.arch == .wasm32) ctx.budget else @atomicLoad(i64, &ctx.budget, .monotonic);
}

/// T0 for up to `budget` instructions, counting them in ctx.
fn runT0(c: *x86cpu.Cpu64, ctx: *Ctx, m: *tlb.TlbMem, budget: u64) x86cpu.Exit64 {
    return runT0Opts(c, ctx, m, budget, 0);
}

/// runT0, stopping after `branches` taken branches when it isn't 0.
fn runT0Opts(c: *x86cpu.Cpu64, ctx: *Ctx, m: *tlb.TlbMem, budget: u64, branches: u32) x86cpu.Exit64 {
    const stop: *const std.atomic.Value(u32) = @ptrCast(&ctx.exit_request);
    const before = c.retired;
    const e = tlb.runIn(.long, c, m, .{ .budget = budget, .stop = stop, .branches = branches });
    const ran = c.retired - before;
    ctx.retired +%= ran;
    if (ctx.budget != std.math.maxInt(i64)) ctx.budget -= @intCast(@min(ran, std.math.maxInt(i63)));
    return e;
}

/// `TlbMem.translate` for a lift.Mem64.
fn translate64(p: *anyopaque, va: u64, access: x86cpu.Access) ?[*]u8 {
    const m: *tlb.TlbMem = @ptrCast(@alignCast(p));
    return m.translate(va, access);
}

/// T1: compiled code, with T0 for each instruction that raises an
/// exception or stores to code, as h86's runT1. Compiled code spends
/// ctx.budget and counts ctx.retired itself; `call.interp` reaches T0's
/// memory through a lift.Mem64 in ctx.frontend.
fn runT1(cpu: *Cpu, ctx: *Ctx, m: *tlb.TlbMem, em: emitter.Emitter) vmm.Error!vmm.Exit {
    const c = &cpu.c;
    var lm: lift.Mem64 = .{ .ctx = m, .translateFn = translate64 };
    ctx.frontend = @intFromPtr(&lm);
    // The lifter's getreg and setreg offsets are into x86cpu.Cpu64.
    const outer = ctx.cpu;
    ctx.cpu = @intFromPtr(c);
    defer ctx.cpu = outer;
    ctx.interp = @intFromPtr(&lift.interpLong);
    const cfg: dispatch.Config = .{
        .frontend = lift.frontendFor(.long),
        .emitter = em,
        .pc_off = @offsetOf(x86cpu.Cpu64, "rip"),
        .pc_bytes = 8,
        .pc_align = 1,
        .hot = dispatch.hot,
    };
    while (true) {
        // T0 counts Cpu64.retired again in each `call.interp`: ctx's count
        // is the one that holds.
        // ctx.retired runs on from Cpu64.retired, so lift.interp can read the
        // count mid-region (RDTSC).
        ctx.retired = c.retired;
        const before = ctx.retired;
        const c_before = c.retired;
        const r = if (build_options.jit_check)
            check_vmm.run(&cpu.check, &@import("vcpu").check.x86.guest64, c, ctx, tier == .t1)
        else
            dispatch.run(icache_gpa, ctx, cfg, &t1_stats);
        c.retired = c_before +% (ctx.retired -% before);
        switch (r) {
            // Compiled code leaves Cpu64.fl's bits current, and RIP past
            // the SYSCALL.
            .svc => return exitOf(c, ctx, .syscall),
            .interrupted => return .interrupted,
            // .cold: a block that isn't hot yet runs on T0 to a later
            // taken branch, so that block's head comes back to be counted.
            .t0, .cold => {
                // A kick zeroes the budget from another thread, so it's
                // read once.
                const left = loadBudget(ctx);
                if (left <= 0) return .interrupted;
                const e = if (r == .t0) runT0(c, ctx, m, 1) else runT0Opts(c, ctx, m, @intCast(left), dispatch.cold_branches);
                if (e != .stopped) return exitOf(c, ctx, e);
                if (@atomicLoad(u32, &ctx.exit_request, .seq_cst) != 0) return .interrupted;
            },
        }
    }
}

/// T1 on the web host (src/jit/wasm_t1.zig), as h86's runWasmT1:
/// compiled code for hot blocks, T0 to the next taken branch for cold
/// ones, so their heads come back to be counted.
fn runWasmT1(c: *x86cpu.Cpu64, ctx: *Ctx, m: *tlb.TlbMem) vmm.Error!vmm.Exit {
    var lm: lift.Mem64 = .{ .ctx = m, .translateFn = translate64 };
    ctx.frontend = @intFromPtr(&lm);
    const outer = ctx.cpu;
    ctx.cpu = @intFromPtr(c);
    defer ctx.cpu = outer;
    ctx.interp = @intFromPtr(&lift.interpLong);
    const cfg: wasm_t1.Config = .{
        .frontend = lift.frontendFor(.long),
        .pc_off = @offsetOf(x86cpu.Cpu64, "rip"),
        .pc_bytes = 8,
        .pc_align = 1,
    };
    while (true) {
        // ctx.retired runs on from Cpu64.retired, so lift.interp can read
        // the count mid-region (RDTSC).
        ctx.retired = c.retired;
        const before = ctx.retired;
        const c_before = c.retired;
        const r = wasm_t1.run(vmm.host_gpa, ctx, cfg);
        c.retired = c_before +% (ctx.retired -% before);
        switch (r) {
            .svc => return exitOf(c, ctx, .syscall),
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

/// 9front's VectorSYSCALL (pc/io.h), which its amd64 kernel puts in
/// Ureg.type for a system call, as emu.zig does.
const vector_syscall = 64;

/// The vmm exit for T0's, leaving Ureg.type and the registers as the real
/// kernel would see them.
fn exitOf(c: *x86cpu.Cpu64, ctx: *Ctx, exit: x86cpu.Exit64) vmm.Exit {
    switch (exit) {
        // SYSCALL leaves the return RIP in RCX and RFLAGS in R11, which
        // 9front's and Linux's entry code save and SYSRET restores, so a
        // program sees them clobbered as on hardware.
        .syscall => {
            c.r[1] = c.rip;
            c.r[11] = c.fl.get();
            c.trap = vector_syscall;
            c.ecode = 0;
        },
        .breakpoint => c.trap = x86cpu.vec_bp,
        .exception => |v| c.trap = v,
        .fault => c.trap = x86cpu.vec_pf,
        .stopped => {},
    }
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
        // the vector in the syndrome and Ureg.type.
        .exception => |v| .{ .fault = .{ .addr = c.rip, .access = .exec, .syndrome = v } },
        .stopped => .interrupted,
    };
}

test "Ureg and FXSAVE round trips" {
    var cpu: Cpu = .{};
    var u: vmm.Ureg = .{ .amd64 = .{ .ax = 1, .r15 = 0xffff_ffff_0000_0001, .pc = 0x20_0000, .sp = 0x7fff_0000, .flags = 0x246, .cs = amd64.UESEL, .ss = amd64.UDSEL } };
    setUreg(&cpu, &u);
    try std.testing.expectEqual(@as(u64, 0xffff_ffff_0000_0001), cpu.c.r[15]);
    var v: vmm.Ureg = undefined;
    getUreg(&cpu, &v);
    try std.testing.expectEqualDeep(u, v);
    var x: vmm.Extra = .{ .amd64 = vmm.X86Extra.init };
    x.amd64.fx.xmm[15] = 0x1234;
    x.amd64.tls = 0x5000;
    x.amd64.gs = 0x6000;
    try setExtra(&cpu, &x);
    try std.testing.expectEqual(@as(u128, 0x1234), cpu.c.xmm[15]);
    var y: vmm.Extra = undefined;
    try getExtra(&cpu, &y);
    x.amd64.fx.mxcsr_mask = 0xffff;
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&x.amd64.fx), std.mem.asBytes(&y.amd64.fx));
    try std.testing.expectEqual(@as(u64, 0x5000), y.amd64.tls);
    try std.testing.expectEqual(@as(u64, 0x6000), y.amd64.gs);
}


test "a SYSCALL exit leaves RCX, R11, and Ureg.type as the kernel sees them" {
    var cpu: Cpu = .{};
    var ctx: Ctx = undefined;
    cpu.c.rip = 0x20_0010;
    cpu.c.fl.set(0x246);
    cpu.c.r[1] = 0xdead;
    cpu.c.r[11] = 0xbeef;
    try std.testing.expectEqual(vmm.Exit.syscall, exitOf(&cpu.c, &ctx, .syscall));
    var u: vmm.Ureg = undefined;
    getUreg(&cpu, &u);
    try std.testing.expectEqual(@as(u64, 0x20_0010), u.amd64.cx);
    try std.testing.expectEqual(@as(u64, 0x246), u.amd64.r11);
    try std.testing.expectEqual(@as(u64, vector_syscall), u.amd64.type);
    try std.testing.expectEqual(@as(u64, 0x20_0010), u.amd64.pc);
}

test "an exception exits as a fault at RIP with the vector in Ureg.type" {
    var cpu: Cpu = .{};
    var ctx: Ctx = undefined;
    cpu.c.rip = 0x20_0004;
    const e = exitOf(&cpu.c, &ctx, .{ .exception = x86cpu.vec_de });
    try std.testing.expectEqual(@as(u64, 0x20_0004), e.fault.addr);
    try std.testing.expectEqual(@as(u64, x86cpu.vec_de), e.fault.syndrome);
    try std.testing.expectEqual(@as(u64, x86cpu.vec_de), cpu.c.trap);
}
