//! EFLAGS in h86's lifter: flags are `eflags.*` values in the IR, and
//! the guest's EFLAGS live in `Cpu.fl.bits`.
//!
//! T0 keeps EFLAGS lazily (`Cpu.fl.lazy`). Lifted code doesn't: a region
//! that touches the arithmetic flags first makes `bits` current (its
//! prologue checks `lazy.kind` and materializes through `call.interp`),
//! and from then on every writer keeps `lazy.kind` at `.none`. Lifted
//! instructions write `bits` directly, and `call.interp` materializes
//! after each instruction it runs, so the invariant holds to the region's
//! exit, and T0 reads the right flags after it.
//!
//! Within a block the lifter holds the current flags as an IR value
//! (`State.cur`) and writes it back only before something that can leave
//! the region (a load, a store, a call, or an exit) or the end of the
//! block. Flags that nothing reads before the next writer are never
//! computed at all: `liveness` finds them from decode.zig's `effects`.

const std = @import("std");
const ir = @import("../ir.zig");
const t0 = @import("../../interp/x86/flags.zig");
const cpu_mod = @import("../../interp/x86/cpu.zig");

const Ref = ir.Ref;
const Cpu = cpu_mod.Cpu;

pub const arith = t0.arith;
pub const CF = t0.CF;
pub const ZF = t0.ZF;
pub const DF = t0.DF;
pub const OF = t0.OF;

/// Byte offsets in Cpu: the materialized EFLAGS, and the lazy kind
/// (an enum(u8), `.none` = 0).
pub const bits_off = @offsetOf(Cpu, "fl") + @offsetOf(t0.Flags, "bits");
pub const kind_off = @offsetOf(Cpu, "fl") + @offsetOf(t0.Flags, "lazy") + @offsetOf(t0.Lazy, "kind");

comptime {
    std.debug.assert(@intFromEnum(t0.Kind.none) == 0);
    std.debug.assert(@sizeOf(t0.Kind) == 1);
}

/// x86 condition codes, as `eflags.cond` takes them.
pub const cc_b: u4 = 2; // CF
pub const cc_e: u4 = 4; // ZF
pub const cc_ne: u4 = 5;

/// The flags as the lifter tracks them within one block.
pub const State = struct {
    /// The current arithmetic flags, as a value in this block, if known.
    cur: ?Ref = null,
    /// `cur` hasn't been written to `Cpu.fl.bits` yet.
    dirty: bool = false,

    /// The current flags as a value.
    pub fn get(s: *State, b: *ir.Builder) !Ref {
        if (s.cur) |f| return f;
        const v = try b.getreg(.i32, bits_off);
        const f = try b.un(.@"eflags.unpack", .flags, v);
        s.cur = f;
        s.dirty = false;
        return f;
    }

    /// An instruction's new flags.
    pub fn set(s: *State, f: Ref) void {
        s.cur = f;
        s.dirty = true;
    }

    /// Whether condition `cc` holds.
    pub fn cond(s: *State, b: *ir.Builder, cc: u4) !Ref {
        return b.cond(.@"eflags.cond", try s.get(b), cc);
    }

    /// Writes the flags back, keeping the bits of EFLAGS that aren't
    /// arithmetic (DF and the rest).
    pub fn flush(s: *State, b: *ir.Builder) !void {
        if (!s.dirty) return;
        const p = try b.un(.@"eflags.pack", .i32, s.cur.?);
        const old = try b.getreg(.i32, bits_off);
        const keep = try b.bin(.@"and", .i32, old, try b.konst(.i32, ~@as(u64, arith)));
        try b.setreg(bits_off, try b.bin(.@"or", .i32, keep, p));
        s.dirty = false;
    }

    /// A new block, or after something (`call.interp`) that may have
    /// changed the flags in Cpu. Flush first.
    pub fn forget(s: *State) void {
        std.debug.assert(!s.dirty);
        s.cur = null;
    }

    /// Changes the flags in `mask` with `op` (and, or, xor) and `v`, as
    /// CLC, STC, and CMC do.
    pub fn modify(s: *State, b: *ir.Builder, op: ir.Op, v: u32) !void {
        const p = try b.un(.@"eflags.pack", .i32, try s.get(b));
        const q = try b.bin(op, .i32, p, try b.konst(.i32, v));
        s.set(try b.un(.@"eflags.unpack", .flags, q));
    }
};

/// What one instruction does to the flags, for `liveness`.
pub const Use = struct {
    /// Arithmetic flags read, and written. A flag written only sometimes
    /// is in both, as decode.zig's `effects` gives it.
    read: u32 = 0,
    written: u32 = 0,
    /// All flags must be exact when the instruction starts: it may leave
    /// the region before writing anything (a memory access, a guard, or
    /// `call.interp`).
    barrier: bool = false,
};

/// Which arithmetic flags are live after each instruction of a linear
/// run: `out[i]` for `uses[i]`. `ends[i]` says a block ends after
/// instruction i, where every flag is live (blocks don't share values,
/// and the flags are written back at every block's end).
pub fn liveness(uses: []const Use, ends: []const bool, out: []u32) void {
    var live: u32 = arith;
    var i = uses.len;
    while (i > 0) {
        i -= 1;
        if (ends[i]) live = arith;
        out[i] = live;
        const u = uses[i];
        if (u.barrier) {
            live = arith;
        } else {
            const kill = u.written & ~u.read;
            live = ((live & ~kill) | u.read) & arith;
        }
    }
}

test "liveness drops flags overwritten before a read" {
    // add; add; jcc: the first add's flags are dead (the second's are
    // live at the block's end).
    const uses = [_]Use{
        .{ .written = arith },
        .{ .written = arith },
        .{ .read = t0.ZF },
    };
    const ends = [_]bool{ false, false, true };
    var out: [3]u32 = undefined;
    liveness(&uses, &ends, &out);
    try std.testing.expectEqual(@as(u32, 0), out[0] & arith);
    try std.testing.expectEqual(arith, out[1]);
    // inc keeps CF, so an add before it keeps CF live.
    const uses2 = [_]Use{
        .{ .written = arith },
        .{ .written = arith & ~CF },
        .{ .read = CF },
    };
    liveness(&uses2, &ends, &out);
    try std.testing.expectEqual(CF, out[0]);
    // A memory access makes everything live before it.
    const uses3 = [_]Use{
        .{ .written = arith },
        .{ .written = arith, .barrier = true },
        .{ .read = 0 },
    };
    liveness(&uses3, &ends, &out);
    try std.testing.expectEqual(arith, out[0]);
}
