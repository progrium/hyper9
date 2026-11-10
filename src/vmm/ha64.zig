//! ha64: h9's own CPU for arm64 binaries, as a Guest of vmm/zemu.zig
//! (-Demu=zig), which has the interface. Its CPU is in src/interp/a64/
//! (T0, the interpreter) and src/jit/a64/, with the shared JIT layer in
//! src/jit/ (src/vcpu.zig).

const std = @import("std");
const builtin = @import("builtin");
const vmm = @import("../vmm.zig");
const Ctx = @import("../jit/ctx.zig").Ctx;
const t0 = @import("../interp/a64/exec.zig");

pub const arch: vmm.Arch = .arm64;
pub const ready = true;

pub const Cpu = struct {
    t0: t0.Cpu = .{},
    cache: t0.Cache = .init(if (builtin.cpu.arch == .wasm32) std.heap.c_allocator else std.heap.smp_allocator),
    machine: t0.Machine = undefined,
    /// The ESR of the last exit, for the Ureg's `type`.
    esr: u64 = 0,
};

/// Frees the decode cache.
pub fn deinit(c: *Cpu) void {
    c.cache.deinit();
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
    // A spent budget (ctx.budget) gives `.interrupted`, as an exit request does.
    const budget: u64 = if (ctx.budget <= 0) 0 else @intCast(ctx.budget);
    const before = c.t0.retired;
    const e = t0.run(&c.machine, budget);
    if (ctx.budget != std.math.maxInt(i64)) ctx.budget -= @intCast(@min(c.t0.retired -% before, std.math.maxInt(i63)));
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
