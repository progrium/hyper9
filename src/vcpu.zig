//! The emulator's own CPUs (ha64 for arm64 guests, h86 for 386 guests):
//! the shared JIT layer and the interpreter pieces both tiers use. The vmm
//! backends in src/vmm/ha64.zig and h86.zig build on this.

pub const ir = @import("jit/ir.zig");
pub const ir_eval = @import("jit/ir_eval.zig");
pub const ctx = @import("jit/ctx.zig");
pub const mem = @import("interp/mem.zig");
pub const alloc = @import("jit/alloc.zig");
pub const frontend = @import("jit/frontend.zig");
pub const emitter = @import("jit/emitter.zig");
pub const a64 = struct {
    pub const lift = @import("jit/a64/lift.zig");
    pub const tracer = @import("jit/a64/tracer.zig");
};
pub const emit = struct {
    pub const arm64 = @import("jit/emit/arm64.zig");
    pub const wasm = @import("jit/emit/wasm.zig");
    pub const cases = @import("jit/emit/cases.zig");
};

test {
    @import("std").testing.refAllDecls(@This());
    @import("std").testing.refAllDecls(emit);
    @import("std").testing.refAllDecls(a64);
}
