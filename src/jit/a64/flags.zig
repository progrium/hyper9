//! NZCV in ha64's lifter: the flags as an IR `flags` value within a block,
//! written to Cpu.nzcv only when something outside the block could see
//! them.
//!
//! Within a block the lifter keeps the latest flags value (`cur`): a
//! condition reads it directly, with no round trip through the Cpu. The
//! value goes back to Cpu.nzcv (`sync`, as a `pending.flags` the emitter
//! writes only on the way out) before anything that can leave the region
//! or look at the Cpu (a load, a store, `call.interp`, and the block's
//! terminator), so guest state is exact there, as the IR's rules ask. `dead` uses decode.zig's read and write sets to skip computing
//! flags that the next instruction to touch them overwrites first.

const std = @import("std");
const ir = @import("../ir.zig");
const dec = @import("../../interp/a64/decode.zig");
const t0 = @import("../../interp/a64/exec.zig");

pub const off = @offsetOf(t0.Cpu, "nzcv");

pub const Flags = struct {
    /// The flags as of the last instruction lifted, if this block has
    /// them as a value.
    cur: ?ir.Ref = null,
    /// `cur` differs from Cpu.nzcv.
    dirty: bool = false,

    /// At the start of a block: values don't cross blocks.
    pub fn reset(f: *Flags) void {
        f.* = .{};
    }

    /// The current flags, read from the Cpu if this block hasn't made them.
    pub fn get(f: *Flags, b: *ir.Builder) !ir.Ref {
        if (f.cur) |c| return c;
        const v = try b.un(.@"nzcv.unpack", .flags, try b.getreg(.i32, off));
        f.cur = v;
        return v;
    }

    /// The instruction just lifted set the flags to `v`.
    pub fn set(f: *Flags, v: ir.Ref) void {
        f.cur = v;
        f.dirty = true;
    }

    /// Makes the flags the Cpu's if they're newer there, as a
    /// `pending.flags`: written before anything outside the block can see
    /// the slot (an exit, a fault, a call), so a load or store between
    /// costs nothing on its way through.
    pub fn sync(f: *Flags, b: *ir.Builder) !void {
        if (!f.dirty) return;
        try b.pendingFlags(f.cur.?, off, .nzcv);
        f.dirty = false;
    }

    /// After something outside the IR (`call.interp`) may have changed the
    /// Cpu's flags: sync first, then forget.
    pub fn clobber(f: *Flags) void {
        std.debug.assert(!f.dirty);
        f.cur = null;
    }

    /// The flags' i32 packing (bits 31..28), as MRS NZCV reads them.
    pub fn packed32(f: *Flags, b: *ir.Builder) !ir.Ref {
        return b.un(.@"nzcv.pack", .i32, try f.get(b));
    }

    /// The C flag as an integer of type `ty` (0 or 1).
    pub fn carry(f: *Flags, b: *ir.Builder, ty: ir.Type) !ir.Ref {
        const p = try f.packed32(b);
        const c = try b.bin(.@"and", .i32, try b.bin(.lshr, .i32, p, try b.konst(.i32, 29)), try b.konst(.i32, 1));
        return if (ty == .i64) b.un(.zext, .i64, c) else c;
    }

    /// i1: condition `cc` (arm64's 4-bit field) holds.
    pub fn cond(f: *Flags, b: *ir.Builder, cc: u4) !ir.Ref {
        return b.cond(.@"nzcv.cond", try f.get(b), cc);
    }
};

/// Whether the flags an instruction writes are overwritten before anything
/// can see them: `ops` are the instructions after it in the same block, up
/// to (not including) the block's terminator or the next block. A load, a
/// store, an instruction run by the interpreter, or a branch can see them
/// (it can leave the region, where guest state must be exact); so can the
/// end of the block.
pub fn dead(ops: []const dec.Op, interp: []const bool) bool {
    for (ops, interp) |o, by_interp| {
        const r = dec.regs(o);
        if (by_interp or r.mem != .none or r.ctrl != .none) return false;
        switch (r.flags) {
            .r, .rw => return false,
            .w => return true,
            .none => {},
        }
    }
    return false;
}

test "dead flags: overwritten before they're read" {
    // adds x0, x0, #1; subs x1, x1, #1: the first's flags are dead.
    const ops = [_]dec.Op{dec.decode(0xf1000421, 0)};
    try std.testing.expect(dead(&ops, &.{false}));
    // ...but not across a load (ldr x2, [x3]) or a b.ne.
    const ops2 = [_]dec.Op{ dec.decode(0xf9400062, 0), dec.decode(0xf1000421, 0) };
    try std.testing.expect(!dead(&ops2, &.{ false, false }));
    // csel reads them.
    const ops3 = [_]dec.Op{dec.decode(0x9a821020, 0)};
    try std.testing.expect(!dead(&ops3, &.{false}));
    // The end of the block keeps them.
    try std.testing.expect(!dead(&.{}, &.{}));
}
