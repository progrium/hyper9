//! h86: the emulator backend for 386 binaries on h9's own CPU, through
//! vmm/zemu.zig (-Demu=zig). Its CPU is in src/interp/x86/ and src/jit/x86/ with the
//! shared JIT layer in src/jit/ (src/vcpu.zig).
//!
//! Not built yet: create fails, so nothing else here is reached.

const std = @import("std");
const vmm = @import("../vmm.zig");
const zemu = @import("zemu.zig");

pub fn create(_: std.mem.Allocator, _: std.Io, _: vmm.Options) vmm.CreateError!*zemu.Backend {
    return error.NotImplemented;
}
