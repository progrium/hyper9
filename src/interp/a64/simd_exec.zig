//! FP and AdvSIMD execution for ha64: the stub until A2's real one lands.
//!
//! `handlers[i]` runs simd_decode.zig's kind `decode.simd_base + i`, with
//! the same signature as exec.zig's handlers. Its state is exec.Cpu's `v`,
//! `fpcr`, and `fpsr`; exec.undef faults an instruction with EC 0.

const exec = @import("exec.zig");

pub const handlers = [_]exec.Handler{};
