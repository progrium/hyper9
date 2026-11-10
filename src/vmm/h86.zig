//! h86: h9's own CPU for 386 binaries, as a Guest of vmm/zemu.zig
//! (-Demu=zig), which has the interface. Its CPU is in src/interp/x86/ and
//! src/jit/x86/, with the shared JIT layer in src/jit/ (src/vcpu.zig).
//!
//! Not built yet: `ready` is false, so create fails and nothing else here
//! is reached.

const std = @import("std");
const vmm = @import("../vmm.zig");
const Ctx = @import("../jit/ctx.zig").Ctx;

pub const arch: vmm.Arch = .i386;
pub const ready = false;

pub const Cpu = struct {
    ureg: vmm.ia32.Ureg = .{},
    extra: vmm.X86Extra = .init,
};

pub fn getUreg(c: *const Cpu, u: *vmm.Ureg) void {
    u.* = .{ .i386 = c.ureg };
}

pub fn setUreg(c: *Cpu, u: *const vmm.Ureg) void {
    c.ureg = u.i386;
}

pub fn getExtra(c: *const Cpu, x: *vmm.Extra) vmm.Error!void {
    x.* = .{ .i386 = c.extra };
}

pub fn setExtra(c: *Cpu, x: *const vmm.Extra) vmm.Error!void {
    c.extra = x.i386;
}

pub fn run(_: *Cpu, _: *Ctx) vmm.Error!vmm.Exit {
    return error.NotImplemented;
}
