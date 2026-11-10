//! What a guest architecture's front end gives the shared JIT layer.
//!
//! A front end (ha64's in src/jit/a64/, h86's in src/jit/x86/) decodes
//! guest instructions, lifts them to IR, and runs any it doesn't lift
//! through its interpreter (`call.interp`). The rest of the JIT (allocation,
//! emitters, the code cache) knows nothing about the guest.

const std = @import("std");
const ir = @import("ir.zig");
const ctx = @import("ctx.zig");

/// Reads guest code for lifting: fills `buf` from guest address `va` and
/// returns how many bytes it could read (fewer at an unmapped or
/// non-executable page). Lifting stops before an instruction it can't
/// read whole; T0 then takes the fault at that instruction.
pub const Source = struct {
    ctx: *anyopaque,
    read: *const fn (ctx: *anyopaque, va: u64, buf: []u8) usize,

    pub fn readAll(s: Source, va: u64, buf: []u8) usize {
        return s.read(s.ctx, va, buf);
    }
};

pub const Limits = struct {
    /// Stop after this many guest instructions.
    max_insns: u32 = 512,
    /// Stop at the end of the second guest page.
    max_pages: u32 = 2,
};

pub const LiftError = error{ OutOfMemory, Unsupported };

pub const Frontend = struct {
    name: []const u8,
    /// The flag group the lifter produces.
    flags: ir.FlagGroup,
    /// Lifts the region starting at `pc` into `b` (blocks already empty).
    /// Block 0 is the entry. `call.interp` handles are whatever `interp`
    /// takes: an encoding, or a pointer into the front end's decode cache,
    /// valid until that cache is flushed (which also drops the region).
    lift: *const fn (b: *ir.Builder, src: Source, pc: u64, limits: Limits) LiftError!void,
    /// The handler generated code and `ir_eval` call for `call.interp`.
    interp: ctx.InterpFn,
};
