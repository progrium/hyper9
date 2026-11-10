//! Where each IR value lives in generated code. An emitter takes a region
//! and an `Allocation` and needn't decide anything about registers itself.
//!
//! `spillAll` is the trivial allocator, so emitters can be written and
//! tested before linear scan (regalloc.zig) exists: every value gets its
//! own 8-byte frame slot (two for a v128), and the emitter loads operands into scratch
//! registers around each operation.

const std = @import("std");
const ir = @import("ir.zig");

pub const Loc = union(enum) {
    /// No value (the instruction has no result).
    none,
    /// A host register, numbered as the emitter numbers them.
    reg: u8,
    /// An 8-byte frame slot: byte offset slot*8 from the frame base. A
    /// wasm emitter uses it as a local's index.
    slot: u32,
};

pub const Allocation = struct {
    locs: []Loc,
    /// Frame slots used.
    slots: u32,

    pub fn deinit(a: *Allocation, gpa: std.mem.Allocator) void {
        gpa.free(a.locs);
    }
};

pub fn spillAll(gpa: std.mem.Allocator, r: *const ir.Region) !Allocation {
    const locs = try gpa.alloc(Loc, r.insts.items.len);
    var n: u32 = 0;
    for (r.insts.items, locs) |i, *l| {
        if (i.ty == .none) {
            l.* = .none;
        } else {
            l.* = .{ .slot = n };
            // A v128 takes two slots: 16 bytes at slot*8.
            n += if (i.ty == .v128) 2 else 1;
        }
    }
    return .{ .locs = locs, .slots = n };
}

test spillAll {
    const gpa = std.testing.allocator;
    var r = try ir.parse(gpa, "b0:\n %0 = const:i64 #0x1\n setreg %0 #0x0\n %2 = const:i32 #0x2\n exit.chain\n");
    defer r.deinit(gpa);
    var a = try spillAll(gpa, &r);
    defer a.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2), a.slots);
    try std.testing.expectEqual(Loc{ .slot = 1 }, a.locs[2]);
    try std.testing.expectEqual(Loc.none, a.locs[1]);
}
