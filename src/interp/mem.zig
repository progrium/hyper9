//! Guest memory for both tiers: the per-vCPU software TLB that generated
//! code checks inline, and the slow path it calls on a miss.
//!
//! The TLB entry layout and the slow-path signatures are final: T0s and
//! every emitter code against them. The address space behind the slow path
//! (`Map` here) is a stand-in until the JIT runtime replaces it.
//!
//! The inline check, on any host:
//!
//!     e = tlb.read[(va >> 12) & (entries - 1)]   // tlb.write for stores
//!     if (e.tag == va >> 12 and (va & 0xfff) <= page_size - size)
//!         host = va +% e.delta                    // the access
//!     else
//!         slow path
//!
//! An entry is only filled for a page the access is allowed on, so the
//! tag compare is also the permission check. A page with compiled code
//! never gets a write entry, so stores to it reach the slow path.

const std = @import("std");
const ctx_mod = @import("../jit/ctx.zig");
const Ctx = ctx_mod.Ctx;

pub const page_size = 4096;
pub const page_shift = 12;
pub const entries = 256;

pub const TlbEntry = extern struct {
    /// The guest virtual page number (va >> 12), or `invalid`.
    tag: u64 = invalid,
    /// host address - guest address, wrapping, for any address in the page.
    delta: u64 = 0,

    pub const invalid: u64 = std.math.maxInt(u64);
};

pub const Tlb = extern struct {
    read: [entries]TlbEntry = @splat(.{}),
    write: [entries]TlbEntry = @splat(.{}),

    pub fn flush(t: *Tlb) void {
        t.* = .{};
    }
};

/// Byte offsets for emitters.
pub const tlb_read_off = @offsetOf(Tlb, "read");
pub const tlb_write_off = @offsetOf(Tlb, "write");
pub const entry_size = @sizeOf(TlbEntry);

comptime {
    std.debug.assert(entry_size == 16 and tlb_read_off == 0 and tlb_write_off == entries * 16);
}

pub const Access = enum(u8) { read = 0, write = 1, exec = 2 };

/// Fault kinds, in Ctx.exit_info bits 8..15.
pub const FaultKind = enum(u8) { unmapped = 0, permission = 1, alignment = 2 };

/// The slow path for loads: called on a TLB miss or a page-crossing access
/// of 2^size_log2 bytes at `va`. On success it returns `.ok` with the value,
/// zero-extended, in ctx.scratch, and may have filled the TLB. On a fault it
/// returns `.fault` with ctx.exit_addr and exit_info set; the caller sets
/// exit_pc.
pub const SlowLoadFn = *const fn (ctx: *Ctx, va: u64, size_log2: u32) callconv(.c) u32;
/// The slow path for stores, likewise. Nothing is written if it faults.
pub const SlowStoreFn = *const fn (ctx: *Ctx, va: u64, size_log2: u32, value: u64) callconv(.c) u32;

// ---------------------------------------------------------------- stand-in

/// A guest mapping.
pub const Region = struct {
    va: u64,
    mem: []u8,
    read: bool = true,
    write: bool = false,
    exec: bool = false,
};

/// A stand-in address space: a list of mappings, for tests and the tracer.
/// ctx.space points at one.
pub const Map = struct {
    regions: []const Region,

    fn find(m: *const Map, va: u64) ?*const Region {
        for (m.regions) |*r| if (va >= r.va and va - r.va < r.mem.len) return r;
        return null;
    }

    /// Host bytes for one byte at va, filling the TLB, or a fault kind.
    fn byte(m: *const Map, tlb: *Tlb, va: u64, acc: Access) union(enum) { ok: *u8, fault: FaultKind } {
        const r = m.find(va) orelse return .{ .fault = .unmapped };
        const allowed = switch (acc) {
            .read => r.read,
            .write => r.write,
            .exec => r.exec,
        };
        if (!allowed) return .{ .fault = .permission };
        const host: usize = @intFromPtr(r.mem.ptr) + @as(usize, @intCast(va - r.va));
        // Fill the entry if the whole page is in this mapping.
        const page = va & ~@as(u64, page_size - 1);
        if (acc != .exec and page >= r.va and page + page_size <= r.va + r.mem.len) {
            const table = if (acc == .write) &tlb.write else &tlb.read;
            table[@intCast((va >> page_shift) & (entries - 1))] = .{ .tag = va >> page_shift, .delta = @as(u64, host) -% va };
        }
        return .{ .ok = @ptrFromInt(host) };
    }
};

fn fault(ctx: *Ctx, va: u64, acc: Access, k: FaultKind) u32 {
    ctx.exit_addr = va;
    ctx.exit_info = @as(u64, @intFromEnum(acc)) | (@as(u64, @intFromEnum(k)) << 8);
    return @intFromEnum(ctx_mod.Exit.fault);
}

/// The stand-in slow load, over the `Map` in ctx.space. Bytewise, so a
/// page-crossing access checks both pages before it returns anything.
pub fn mapSlowLoad(ctx: *Ctx, va: u64, size_log2: u32) callconv(.c) u32 {
    const m: *const Map = @ptrFromInt(@as(usize, @intCast(ctx.space)));
    const tlb: *Tlb = @ptrFromInt(@as(usize, @intCast(ctx.tlb)));
    const n = @as(u32, 1) << @intCast(size_log2);
    var v: u64 = 0;
    for (0..n) |i| {
        const a = va +% i;
        switch (m.byte(tlb, a, .read)) {
            .ok => |p| v |= @as(u64, p.*) << @intCast(8 * i),
            .fault => |k| return fault(ctx, a, .read, k),
        }
    }
    ctx.scratch = v;
    return 0;
}

/// The stand-in slow store. Checks every byte before writing any.
pub fn mapSlowStore(ctx: *Ctx, va: u64, size_log2: u32, value: u64) callconv(.c) u32 {
    const m: *const Map = @ptrFromInt(@as(usize, @intCast(ctx.space)));
    const tlb: *Tlb = @ptrFromInt(@as(usize, @intCast(ctx.tlb)));
    const n = @as(u32, 1) << @intCast(size_log2);
    var ptrs: [8]*u8 = undefined;
    for (0..n) |i| {
        const a = va +% i;
        switch (m.byte(tlb, a, .write)) {
            .ok => |p| ptrs[i] = p,
            .fault => |k| return fault(ctx, a, .write, k),
        }
    }
    for (0..n) |i| ptrs[i].* = @truncate(value >> @intCast(8 * i));
    return 0;
}

/// The inline fast path, in Zig, for T0 and `ir_eval`: the same check the
/// emitters generate.
pub inline fn fast(tlb: *const Tlb, va: u64, size: u32, comptime write: bool) ?usize {
    const table = if (write) &tlb.write else &tlb.read;
    const e = table[@intCast((va >> page_shift) & (entries - 1))];
    if (e.tag != va >> page_shift or (va & (page_size - 1)) > page_size - size) return null;
    return @intCast(va +% e.delta);
}

test "slow path fills the TLB, and faults name the address" {
    var page: [2 * page_size]u8 align(page_size) = @splat(0);
    const regions = [_]Region{.{ .va = 0x10000, .mem = page[0..page_size], .write = true }};
    var map: Map = .{ .regions = &regions };
    var tlb: Tlb = .{};
    var c: Ctx = .{ .tlb = @intFromPtr(&tlb), .space = @intFromPtr(&map) };
    try std.testing.expectEqual(@as(u32, 0), mapSlowStore(&c, 0x10008, 3, 0x1122334455667788));
    try std.testing.expect(fast(&tlb, 0x10010, 8, true) != null);
    try std.testing.expectEqual(@as(u32, 0), mapSlowLoad(&c, 0x10008, 2));
    try std.testing.expectEqual(@as(u64, 0x55667788), c.scratch);
    // Crossing into an unmapped page faults at its first byte there.
    try std.testing.expectEqual(@as(u32, 5), mapSlowLoad(&c, 0x10ffc, 3));
    try std.testing.expectEqual(@as(u64, 0x11000), c.exit_addr);
    // A store that would fault writes nothing.
    try std.testing.expectEqual(@as(u32, 5), mapSlowStore(&c, 0x10ffe, 2, 0xffffffff));
    try std.testing.expectEqual(@as(u8, 0), page[page_size - 2]);
}
