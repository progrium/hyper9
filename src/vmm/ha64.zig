//! ha64: h9's own CPU for arm64 binaries, as a Guest of vmm/zemu.zig
//! (-Demu=zig), which has the interface. Its CPU is in src/interp/a64/
//! (T0, the interpreter) and src/jit/a64/, with the shared JIT layer in
//! src/jit/ (src/vcpu.zig).

const std = @import("std");
const builtin = @import("builtin");
const vmm = @import("../vmm.zig");
const Ctx = @import("../jit/ctx.zig").Ctx;
const t0 = @import("../interp/a64/exec.zig");
const cache = @import("../jit/cache.zig");
const dispatch = @import("../jit/dispatch.zig");
const emitter = @import("../jit/emitter.zig");
const lift = @import("../jit/a64/lift.zig");
const build_options = @import("build_options");
const check_vmm = @import("../jit/check/vmm.zig");

/// Which tier runs guest code: T0 alone, or T1 (src/jit/dispatch.zig)
/// when the backend has a code cache and this host an emitter.
pub const Tier = enum { t0, t1 };
pub var tier: Tier = .t0;
/// T1's emitter; null where this host has none yet.
pub var t1_emitter: ?emitter.Emitter = switch (builtin.cpu.arch) {
    .aarch64 => @import("../jit/emit/arm64.zig").emitter_def,
    .x86_64 => @import("../jit/emit/x64.zig").emitter_def,
    else => null,
};
pub var t1_stats: dispatch.Stats = .{};

pub const arch: vmm.Arch = .arm64;
pub const ready = true;

pub const Cpu = struct {
    t0: t0.Cpu = .{},
    cache: t0.Cache = .init(if (builtin.cpu.arch == .wasm32) std.heap.c_allocator else std.heap.smp_allocator),
    machine: t0.Machine = undefined,
    /// The ESR of the last exit, for the Ureg's `type`.
    esr: u64 = 0,
    /// -Djit-check's state.
    check: check_vmm.State = .{},
};

/// Frees the decode cache.
pub fn deinit(c: *Cpu) void {
    c.cache.deinit();
    c.check.deinit();
}

pub fn getUreg(c: *const Cpu, u: *vmm.Ureg) void {
    var r: vmm.arm64.Ureg = .{
        .sp = c.t0.r[t0.dec.SP],
        .pc = c.t0.pc,
        .psr = c.t0.nzcv,
        .type = c.esr,
    };
    @memcpy(&r.r, c.t0.r[0..31]);
    u.* = .{ .arm64 = r };
}

pub fn setUreg(c: *Cpu, u: *const vmm.Ureg) void {
    const r = u.arm64;
    @memcpy(c.t0.r[0..31], &r.r);
    c.t0.r[t0.dec.ZR] = 0;
    c.t0.r[t0.dec.SP] = r.sp;
    c.t0.pc = r.pc;
    c.t0.nzcv = @as(u32, @truncate(r.psr)) & 0xf0000000;
    c.esr = r.type;
    // A context switch clears the exclusive monitor.
    c.t0.monitor = .{};
}

pub fn getExtra(c: *const Cpu, x: *vmm.Extra) vmm.Error!void {
    x.* = .{ .arm64 = .{ .v = c.t0.v, .fpcr = c.t0.fpcr, .fpsr = c.t0.fpsr, .tls = c.t0.tpidr } };
}

pub fn setExtra(c: *Cpu, x: *const vmm.Extra) vmm.Error!void {
    const e = x.arm64;
    c.t0.v = e.v;
    c.t0.fpcr = @as(u32, @truncate(e.fpcr)) & t0.fpcr_mask;
    c.t0.fpsr = @as(u32, @truncate(e.fpsr)) & t0.fpsr_mask;
    c.t0.tpidr = e.tls;
}

pub fn run(c: *Cpu, ctx: *Ctx) vmm.Error!vmm.Exit {
    c.machine = .init(&c.t0, ctx, &c.cache, clock);
    ctx.frontend = @intFromPtr(&c.machine);
    // -Djit-check: every region lifted and checked against T0 (src/jit/check/vmm.zig).
    if (build_options.jit_check) return exitOf(c, check_vmm.runA64(&c.check, &c.t0, ctx));
    if (tier == .t1) if (t1_emitter) |em| if (cache.Runtime.of(ctx).cache != null) return runT1(c, ctx, em);
    // A spent budget (ctx.budget) gives `.interrupted`, as an exit request does.
    const budget: u64 = if (ctx.budget <= 0) 0 else @intCast(ctx.budget);
    const before = c.t0.retired;
    const e = t0.run(&c.machine, budget);
    if (ctx.budget != std.math.maxInt(i64)) ctx.budget -= @intCast(@min(c.t0.retired -% before, std.math.maxInt(i63)));
    return exitOf(c, e);
}

/// T1: compiled code, with T0 for each instruction that raises an
/// exception or stores to code. Compiled code spends ctx.budget itself.
fn runT1(c: *Cpu, ctx: *Ctx, em: emitter.Emitter) vmm.Error!vmm.Exit {
    ctx.interp = @intFromPtr(&lift.interp);
    const cfg: dispatch.Config = .{ .frontend = lift.frontend, .emitter = em, .pc_off = @offsetOf(t0.Cpu, "pc") };
    while (true) {
        const before = ctx.retired;
        const r = dispatch.run(if (builtin.cpu.arch == .wasm32) std.heap.c_allocator else std.heap.smp_allocator, ctx, cfg, &t1_stats);
        c.t0.retired +%= ctx.retired -% before;
        switch (r) {
            .svc => return exitOf(c, .syscall),
            .interrupted => return .interrupted,
            .t0 => {
                if (ctx.budget <= 0) return .interrupted;
                const t0_before = c.t0.retired;
                const e = t0.run(&c.machine, 1);
                if (ctx.budget != std.math.maxInt(i64)) ctx.budget -= @intCast(c.t0.retired -% t0_before);
                if (e != .interrupted) return exitOf(c, e);
                if (@atomicLoad(u32, &ctx.exit_request, .seq_cst) != 0) return .interrupted;
            },
        }
    }
}

fn exitOf(c: *Cpu, e: t0.Exit) vmm.Exit {
    switch (e) {
        .syscall => {
            c.esr = t0.EC_SVC64 << 26;
            return .syscall;
        },
        .breakpoint => {
            c.esr = t0.EC_BRK << 26;
            return .breakpoint;
        },
        .interrupted => return .interrupted,
        .fault => |f| {
            c.esr = f.esr;
            return .{ .fault = .{
                .addr = f.addr,
                .access = switch (f.access) {
                    .read => .read,
                    .write => .write,
                    .exec => .exec,
                },
                .syndrome = f.esr,
            } };
        },
    }
}

/// CNTVCT_EL0 at 24 MHz, from the host's counter where it has one.
const clock: ?t0.Clock = switch (builtin.cpu.arch) {
    .aarch64 => .{ .now = hostCounter },
    else => if (builtin.os.tag == .linux) .{ .now = linuxMonotonic } else null,
};

fn hostCounter(_: ?*anyopaque) u64 {
    const cnt = asm volatile ("mrs %[r], cntvct_el0"
        : [r] "=r" (-> u64),
    );
    const frq = asm ("mrs %[r], cntfrq_el0"
        : [r] "=r" (-> u64),
    );
    if (frq == t0.cntfrq or frq == 0) return cnt;
    return @truncate(@as(u128, cnt) * t0.cntfrq / frq);
}

fn linuxMonotonic(_: ?*anyopaque) u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    const ns: u128 = @as(u128, @intCast(ts.sec)) * std.time.ns_per_s + @as(u128, @intCast(ts.nsec));
    return @truncate(ns * t0.cntfrq / std.time.ns_per_s);
}
