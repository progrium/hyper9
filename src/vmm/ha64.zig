//! ha64: h9's own CPU for arm64 binaries, as a Guest of vmm/zemu.zig
//! (-Demu=zig), which has the interface. Its CPU is in src/interp/a64/ and
//! src/jit/a64/, with the shared JIT layer in src/jit/ (src/vcpu.zig).
//!
//! Not built yet: `ready` is false, so create fails and nothing else here
//! is reached.

const std = @import("std");
const vmm = @import("../vmm.zig");
const Ctx = @import("../jit/ctx.zig").Ctx;

pub const arch: vmm.Arch = .arm64;
pub const ready = false;

pub const Cpu = struct {
    ureg: vmm.arm64.Ureg = .{},
    extra: vmm.Arm64Extra = .{},
};

pub fn getUreg(c: *const Cpu, u: *vmm.Ureg) void {
    u.* = .{ .arm64 = c.ureg };
}

pub fn setUreg(c: *Cpu, u: *const vmm.Ureg) void {
    c.ureg = u.arm64;
}

pub fn getExtra(c: *const Cpu, x: *vmm.Extra) vmm.Error!void {
    x.* = .{ .arm64 = c.extra };
}

pub fn setExtra(c: *Cpu, x: *const vmm.Extra) vmm.Error!void {
    c.extra = x.arm64;
}

pub fn run(_: *Cpu, _: *Ctx) vmm.Error!vmm.Exit {
    return error.NotImplemented;
}
