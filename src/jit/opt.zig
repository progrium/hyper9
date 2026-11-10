//! Optimizations on a lifted region, before allocation and emission.
//! Every pass keeps the IR's rules (README.md): guest state exact at every
//! operation that can leave, and ctx.retired exact at every exit.

const std = @import("std");
const ir = @import("ir.zig");

pub fn run(gpa: std.mem.Allocator, r: *ir.Region) !void {
    _ = gpa;
    _ = r;
}
