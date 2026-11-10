//! h86's MMX, SSE, and SSE2: a stub until the SSE workstream fills it in.
//! T0's exec.zig sends every `.sse` table entry here (0F 10-17, 28-2F,
//! 50-7F, C2-C6, D0-FF, and 0F AE's FXSAVE, FXRSTOR, LDMXCSR, and
//! STMXCSR). The mandatory prefix is in `x.i.opsize` (66) and `x.i.rep`
//! (F3, F2).

const cpu = @import("cpu.zig");

/// Not implemented yet: #UD.
pub fn exec(x: anytype) !void {
    return x.exc(cpu.vec_ud);
}
