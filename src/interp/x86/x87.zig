//! h86's x87: a stub until the x87 workstream fills it in. T0's exec.zig
//! sends every D8-DF instruction here, and FWAIT; see exec.zig's header
//! for what an `Exec` offers (`x.i`, `x.c.fpu`, `x.addr`, `x.load`...).

const cpu = @import("cpu.zig");

/// Runs a D8-DF instruction. Not implemented yet: #UD.
pub fn exec(x: anytype) !void {
    return x.exc(cpu.vec_ud);
}

/// FWAIT: raises #MF for a pending unmasked exception. None are raised
/// yet, so it does nothing.
pub fn fwait(x: anytype) !void {
    _ = x;
}
