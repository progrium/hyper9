//! hx64: h9's own CPU for amd64 binaries, as a Guest of vmm/zemu.zig
//! (-Demu=zig), which has the interface. It's h86 in long mode
//! (design/hcpu.md, hx64): the same decoder, T0, and lifter in
//! src/interp/x86/ and src/jit/x86/, instantiated with `.long`.
//!
//! Guest code runs on T0 (tlb.runIn(.long)), with h86's decode caches.
//! The lifter doesn't do long mode yet, so there's no T1 here.

const std = @import("std");
const builtin = @import("builtin");
const vmm = @import("../vmm.zig");
const amd64 = @import("../arch/amd64.zig");
const Ctx = @import("vcpu").ctx.Ctx;
const x86cpu = @import("vcpu").x86.cpu;
const tlb = @import("vcpu").x86.tlb;
const exec = @import("vcpu").x86.exec;
const dispatch = @import("vcpu").dispatch;

/// Which tier runs guest code. T1 isn't wired in yet, so both run T0.
/// H9_EMU_TIER picks either (zemu.applyTier).
pub const Tier = enum { t0, t1 };
pub var tier: Tier = .t0;
pub var t1_stats: dispatch.Stats = .{};

pub const arch: vmm.Arch = .amd64;
pub const ready = true;

pub const Cpu = struct {
    c: x86cpu.CpuOf(.long) = .{},
    /// T0's decoded instructions, by address and by page, which `run`
    /// allocates on first use and points `c` at.
    icache: ?*exec.ICacheOf(.long) = null,
    pages: ?*exec.PageCacheOf(.long) = null,
};

/// What the decode caches come from: the web host has no threads, so no
/// SmpAllocator.
const icache_gpa = if (builtin.cpu.arch == .wasm32) std.heap.c_allocator else std.heap.smp_allocator;

/// Frees the decode caches.
pub fn deinit(cpu: *Cpu) void {
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
    const budget: u64 = if (ctx.budget <= 0) 0 else @intCast(ctx.budget);
    const before = c.retired;
    const e = tlb.runIn(.long, c, &m, .{ .budget = budget, .stop = stop });
    const ran = c.retired - before;
    ctx.retired +%= ran;
    if (ctx.budget != std.math.maxInt(i64)) ctx.budget -= @intCast(@min(ran, std.math.maxInt(i63)));
    return exitOf(c, ctx, e);
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
