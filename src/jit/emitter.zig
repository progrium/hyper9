//! What an emitter gives the shared JIT layer. Each host (arm64, x86-64,
//! wasm) has one, in src/jit/emit/.

const std = @import("std");
const ir = @import("ir.zig");
const alloc = @import("alloc.zig");

pub const EmitError = error{ OutOfMemory, Unsupported, TooLarge };

/// What `emit` produced. Native code is position-independent apart from
/// absolute addresses of runtime functions it embeds, so the cache can
/// copy it anywhere; `entry` is the offset of its `ctx.EntryFn`. For wasm,
/// `code` is a whole module whose export "run" is the entry.
pub const Code = struct {
    entry: u32 = 0,
};

pub const Emitter = struct {
    name: []const u8,
    /// Appends the region's code to `out`. The region must verify.
    emit: *const fn (gpa: std.mem.Allocator, r: *const ir.Region, a: *const alloc.Allocation, out: *std.ArrayList(u8)) EmitError!Code,
};
