//! FP and AdvSIMD decoding for ha64: the stub until A2's real one lands.
//!
//! decode.zig sends here every word in the "data processing, SIMD and FP"
//! groups, and the SIMD structure loads and stores (LD1 and the rest).
//! Kinds are numbered from decode.simd_base; exec.zig dispatches them to
//! simd_exec.zig's handlers. Loads and stores of single FP/SIMD registers
//! (LDR, STR, LDP, STP, and LDUR of B, H, S, D, and Q) are decode.zig's.
//!
//! The contract with decode.zig:
//!   decode(w, pc) Op     an Op with k = .undef or a kind >= simd_base
//!   info(k) Info         for kinds >= simd_base
//!   regs(o) Regs         likewise
//! Operand fields are this file's to define; decode.Op's layout is fixed.

const std = @import("std");
const d = @import("decode.zig");

/// This file's kinds, as offsets from decode.simd_base.
pub const Kind = enum(u16) {
    _,
};

pub fn decode(w: u32, pc: u64) d.Op {
    _ = w;
    _ = pc;
    return .{};
}

pub fn info(k: d.Kind) d.Info {
    _ = k;
    return .{ .ctrl = .undef };
}

pub fn regs(o: d.Op) d.Regs {
    _ = o;
    return .{ .ctrl = .undef };
}
