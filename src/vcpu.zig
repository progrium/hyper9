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
/// W^X executable memory for the code cache.
pub const codemem = @import("jit/codemem.zig");
/// Test infrastructure: T1-against-T0 region checks and the fuzzers' parts.
pub const check = @import("jit/check.zig");
/// The code cache: translations, chaining, the jump cache, invalidation.
pub const cache = @import("jit/cache.zig");
pub const a64 = struct {
    pub const decode = @import("interp/a64/decode.zig");
    pub const exec = @import("interp/a64/exec.zig");
    pub const lift = @import("jit/a64/lift.zig");
    pub const flags = @import("jit/a64/flags.zig");
    pub const tracer = @import("jit/a64/tracer.zig");
};
/// h86's interpreter (T0).
pub const x86 = struct {
    pub const table = @import("interp/x86/table.zig");
    pub const decode = @import("interp/x86/decode.zig");
    pub const flags = @import("interp/x86/flags.zig");
    pub const cpu = @import("interp/x86/cpu.zig");
    pub const exec = @import("interp/x86/exec.zig");
    pub const softfloat = @import("interp/x86/f80.zig");
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
    @import("std").testing.refAllDecls(x86);
    @import("std").testing.refAllDecls(check);
}
