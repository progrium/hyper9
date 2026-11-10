//! h86: h9's own CPU for 386 binaries, as a Guest of vmm/zemu.zig
//! (-Demu=zig), which has the interface. Its CPU is in src/interp/x86/ and
//! src/jit/x86/, with the shared JIT layer in src/jit/ (src/vcpu.zig).
//!
//! For now it runs everything on T0, the interpreter (interp/x86/exec.zig),
//! which reaches guest memory through the vCPU's TLB: mem.fast and
//! mem.fastExec on a hit, and mem.probe, which fills the entry, on a miss.

const std = @import("std");
const vmm = @import("../vmm.zig");
const Ctx = @import("../jit/ctx.zig").Ctx;
const mem = @import("../interp/mem.zig");
const x86cpu = @import("../interp/x86/cpu.zig");
const exec = @import("../interp/x86/exec.zig");

pub const arch: vmm.Arch = .i386;
pub const ready = true;

pub const Cpu = struct {
    c: x86cpu.Cpu = .{},
    /// T0's decoded instructions, which `run` points `c` at.
    icache: exec.ICache = .{},
};

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

/// T0's view of guest memory: the TLB, and mem.probe on a miss.
const TlbMem = struct {
    ctx: *Ctx,
    tlb: *const mem.Tlb,

    pub fn translate(m: *TlbMem, va: u32, access: x86cpu.Access) ?[*]u8 {
        const hit = switch (access) {
            .read => mem.fast(m.tlb, va, 1, false),
            .write => mem.fast(m.tlb, va, 1, true),
            .exec => mem.fastExec(m.tlb, va, 1),
        };
        if (hit) |h| return @ptrFromInt(h);
        return mem.probe(m.ctx, va, switch (access) {
            .read => .read,
            .write => .write,
            .exec => .exec,
        });
    }
};

/// Runs T0 until an exit. An exit request (ctx.exit_request, which zemu
/// clears) or a spent ctx.budget gives `.interrupted`.
pub fn run(cpu: *Cpu, ctx: *Ctx) vmm.Error!vmm.Exit {
    const c = &cpu.c;
    c.icache = &cpu.icache;
    var m: TlbMem = .{ .ctx = ctx, .tlb = @ptrFromInt(@as(usize, @intCast(ctx.tlb))) };
    const before = c.retired;
    const budget: u64 = if (ctx.budget <= 0) 0 else @intCast(ctx.budget);
    const stop: *const std.atomic.Value(u32) = @ptrCast(&ctx.exit_request);
    if (stop.load(.acquire) != 0) return .interrupted;
    const exit = exec.run(c, &m, .{ .budget = budget, .stop = stop });
    const ran = c.retired - before;
    ctx.retired +%= ran;
    if (ctx.budget != std.math.maxInt(i64)) ctx.budget -= @intCast(@min(ran, std.math.maxInt(i63)));
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
