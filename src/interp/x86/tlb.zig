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
