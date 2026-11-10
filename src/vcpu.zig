//! The emulator's own CPUs (ha64 for arm64 guests, h86 for 386 guests):
//! the shared JIT layer and the interpreter pieces both tiers use. The vmm
//! backends in src/vmm/ha64.zig and h86.zig build on this.

pub const ir = @import("jit/ir.zig");
pub const ir_eval = @import("jit/ir_eval.zig");
pub const ctx = @import("jit/ctx.zig");
pub const mem = @import("interp/mem.zig");
/// IEEE binary16, 32, and 64 in software: h86's SSE and ha64's FP share it.
pub const softfloat = @import("interp/softfloat.zig");
pub const alloc = @import("jit/alloc.zig");
pub const frontend = @import("jit/frontend.zig");
pub const emitter = @import("jit/emitter.zig");
/// W^X executable memory for the code cache.
pub const codemem = @import("jit/codemem.zig");
/// Test infrastructure: T1-against-T0 region checks and the fuzzers' parts.
pub const check = @import("jit/check.zig");
/// The code cache: translations, chaining, the jump cache, invalidation.
pub const cache = @import("jit/cache.zig");
/// T1's run loop, and the passes it runs on each region.
pub const dispatch = @import("jit/dispatch.zig");
pub const opt = @import("jit/opt.zig");
pub const a64 = struct {
    pub const decode = @import("interp/a64/decode.zig");
    pub const exec = @import("interp/a64/exec.zig");
    pub const simd_decode = @import("interp/a64/simd_decode.zig");
    pub const simd_exec = @import("interp/a64/simd_exec.zig");
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
    pub const fp = @import("interp/x86/fp.zig");
    pub const x87 = @import("interp/x86/x87.zig");
    pub const x87math = @import("interp/x86/x87math.zig");
    pub const sse = @import("interp/x86/sse.zig");
};
/// h86's front end: the lifter to the JIT IR.
pub const x86jit = struct {
    pub const lift = @import("jit/x86/lift.zig");
    pub const flags = @import("jit/x86/flags.zig");
    pub const check = @import("jit/x86/check.zig");
};
pub const emit = struct {
    pub const arm64 = @import("jit/emit/arm64.zig");
    pub const wasm = @import("jit/emit/wasm.zig");
    pub const x64 = @import("jit/emit/x64.zig");
    pub const cases = @import("jit/emit/cases.zig");
    pub const native = @import("jit/emit/native.zig");
    pub const eval = @import("jit/emit/eval.zig");
};

test {
    @import("std").testing.refAllDecls(@This());
    @import("std").testing.refAllDecls(emit);
    @import("std").testing.refAllDecls(a64);
    @import("std").testing.refAllDecls(x86);
    @import("std").testing.refAllDecls(check);
    @import("std").testing.refAllDecls(x86jit);
}
