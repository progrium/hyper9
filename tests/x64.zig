//! zig build x64-jit (and vcpu): hx64's cases, tagged [hcpu], each to run
//! on T0 alone and on T1 through dispatch, with ir_eval and with this
//! host's emitter, as tests/x86.zig runs h86's. design/hcpu.md's Done
//! when lists them:
//!
//! - a 32-bit write zeroes the upper half of a 64-bit register
//! - a RIP-relative load reads past the instruction
//! - INT 0x80 in long mode raises #GP
//! - four CMPXCHG16B threads lose no increments
//! - arch_prctl's FS base reaches FS-relative loads on T0 and T1
//!
//! and h86's, in long mode: a DIV by zero, a REP MOVSB stopped by a fault,
//! a store into the executing page, an instruction crossing into an
//! unmapped page, and CPUID reporting SSE2 and no AVX.
//!
//! None is here yet: T0 runs long mode once its decoder and integer
//! workstreams land. Name each `test "... [hcpu]"`, with the tag last.

const std = @import("std");
const vcpu = @import("vcpu");

comptime {
    // The long-mode types the cases will run on.
    _ = vcpu.x86.cpu.CpuOf(.long);
    _ = vcpu.x86.decode.InstOf(.long);
    _ = vcpu.x86jit.lift.frontendFor(.long);
}
