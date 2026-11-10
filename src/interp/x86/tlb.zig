//! T0's view of guest memory in the vmm backend (src/vmm/h86.zig): the
//! vCPU's TLB, and mem.probe on a miss. `run` is T0 over it, instantiated
//! here so it builds with this module's optimization (src/vcpu.zig), not
//! that of the module calling it.

const std = @import("std");
const Ctx = @import("../../jit/ctx.zig").Ctx;
const mem = @import("../mem.zig");
const cpu_mod = @import("cpu.zig");
const exec = @import("exec.zig");

pub const TlbMem = struct {
    ctx: *Ctx,
    tlb: *const mem.Tlb,
    /// The View's code pages, if anything tracks code.
    code: ?*const mem.CodePages = null,

    /// Over ctx's TLB and View (ctx.tlb and ctx.space).
    pub fn init(ctx: *Ctx) TlbMem {
        const view: ?*const mem.View = if (ctx.space == 0) null else @ptrFromInt(@as(usize, @intCast(ctx.space)));
        return .{
            .ctx = ctx,
            .tlb = @ptrFromInt(@as(usize, @intCast(ctx.tlb))),
            .code = if (view) |v| v.code else null,
        };
    }

    pub fn translate(m: *TlbMem, va: u32, access: cpu_mod.Access) ?[*]u8 {
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

    /// The code epoch of the View in ctx.space, for T0's decode cache, or
    /// null if nothing tracks code there.
    pub inline fn codeEpoch(m: *TlbMem) ?usize {
        const code = m.code orelse return null;
        return code.epoch.load(.monotonic);
    }

    /// `translate` for a lift.Mem.
    pub fn translateFn(p: *anyopaque, va: u32, access: cpu_mod.Access) ?[*]u8 {
        const m: *TlbMem = @ptrCast(@alignCast(p));
        return m.translate(va, access);
    }
};

/// exec.run over a TlbMem.
pub fn run(c: *cpu_mod.Cpu, m: *TlbMem, opts: exec.Options) cpu_mod.Exit {
    return exec.run(c, m, opts);
}
