//! The scheduler's primitives (design/scheduler.md): kernel stacks and
//! their pool (stack.zig), and kernel continuations with park and resume
//! (cont.zig). Nothing here knows of a process, an engine, or the C
//! kernel; sync.zig's `park` and `unpark` are what will call them.

const std = @import("std");
const builtin = @import("builtin");

pub const stack = @import("stack.zig");
pub const cont = @import("cont.zig");

pub const Stack = stack.Stack;
pub const Pool = stack.Pool;
pub const Cont = cont.Cont;
pub const Executor = cont.Executor;
pub const Outcome = cont.Outcome;
pub const park = cont.park;
pub const unpark = cont.unpark;

test {
    _ = stack;
    _ = cont;
    _ = @import("test.zig");
}
