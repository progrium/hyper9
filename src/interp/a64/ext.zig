//! ha64's Armv8.0 optional extensions on T0: CRC32 (FEAT_CRC32), with the
//! cryptographic ones (AES, SHA1, SHA2, PMULL) to follow. Linux programs
//! use them only when AT_HWCAP says so, and h9 says so on the emulator
//! (vmm.Backend.hwcaps) for each one both tiers run: CRC32 so far.
//!
//! decode.zig hands the encodings here (`decodeDp2`), and its kinds from
//! `dec.ext_base` up are this file's: exec.zig dispatches them to
//! `handlers`, and decode.zig's `info` asks `info` here. T1 runs them
//! through call.interp.

const std = @import("std");
const dec = @import("decode.zig");
const exec = @import("exec.zig");

const Op = dec.Op;
const Machine = exec.Machine;
const Next = exec.Next;

pub const Kind = enum(u16) {
    /// CRC32B, H, W, and X, and CRC32CB, CH, CW, and CX: d = the CRC of
    /// the low 1, 2, 4, or 8 bytes of m, from the accumulator n (W
    /// registers but for X's m). x is log2 of the size.
    crc32,
    crc32c,
};

pub fn kind(k: Kind) dec.Kind {
    return @enumFromInt(dec.ext_base + @intFromEnum(k));
}

pub fn of(k: dec.Kind) ?Kind {
    const v = @intFromEnum(k);
    if (v < dec.ext_base) return null;
    return std.enums.fromInt(Kind, v - dec.ext_base);
}

inline fn bits(w: u32, comptime hi: u5, comptime lo: u5) u32 {
    return (w >> lo) & ((@as(u32, 1) << (hi - lo + 1)) - 1);
}

/// Data processing (2 source) opcodes 010xxx: CRC32 and CRC32C. Null for
/// anything else, which stays unallocated.
pub fn decodeDp2(w: u32) ?Op {
    const opcode = bits(w, 15, 10);
    if (opcode >> 3 != 0b010) return null;
    const sf = bits(w, 31, 31) == 1;
    const sz: u8 = @intCast(opcode & 3);
    // Only the X form takes sf.
    if (sf != (sz == 3)) return null;
    const rd = bits(w, 4, 0);
    return .{
        .k = kind(if (opcode & 4 != 0) .crc32c else .crc32),
        .d = if (rd == 31) dec.SINK else @intCast(rd),
        .n = @intCast(bits(w, 9, 5)),
        .m = @intCast(bits(w, 20, 16)),
        .x = sz,
    };
}

pub fn info(k: dec.Kind) dec.Info {
    return switch (of(k) orelse return .{ .ctrl = .undef }) {
        .crc32, .crc32c => .{ .d = .w, .n = .r, .m = .r },
    };
}

// ---------------------------------------------------------------- CRC32

/// The reflected polynomials: CRC-32 (ISO-HDLC) and CRC-32C (Castagnoli).
const poly_crc32: u32 = 0xedb8_8320;
const poly_crc32c: u32 = 0x82f6_3b78;

fn crcTable(comptime poly: u32) [256]u32 {
    @setEvalBranchQuota(10000);
    var t: [256]u32 = undefined;
    for (&t, 0..) |*e, i| {
        var c: u32 = @intCast(i);
        for (0..8) |_| c = if (c & 1 != 0) (c >> 1) ^ poly else c >> 1;
        e.* = c;
    }
    return t;
}

const table_crc32 = crcTable(poly_crc32);
const table_crc32c = crcTable(poly_crc32c);

/// The architecture's CRC32 step: no inversion on the way in or out,
/// bytes least significant first.
pub fn crc(comptime c: bool, acc: u32, data: u64, size: u4) u32 {
    const t = if (c) &table_crc32c else &table_crc32;
    var v = acc;
    var d = data;
    for (0..size) |_| {
        v = (v >> 8) ^ t[@as(u8, @truncate(v ^ @as(u32, @truncate(d))))];
        d >>= 8;
    }
    return v;
}

// ---------------------------------------------------------------- handlers

pub const handlers = blk: {
    const fields = @typeInfo(Kind).@"enum".fields;
    var h: [fields.len]exec.Handler = undefined;
    for (fields, 0..) |f, i| {
        std.debug.assert(f.value == i);
        h[i] = handlerFor(@enumFromInt(f.value));
    }
    break :blk h;
};

fn handlerFor(comptime k: Kind) exec.Handler {
    return &struct {
        fn f(m: *Machine, o: *const Op, pc: u64) Next {
            _ = pc;
            const r = &m.cpu.r;
            switch (k) {
                .crc32, .crc32c => {
                    const size = @as(u4, 1) << @intCast(o.x);
                    r[o.d] = crc(k == .crc32c, @truncate(r[o.n]), r[o.m], size);
                },
            }
            return .next;
        }
    }.f;
}

// ---------------------------------------------------------------- tests

test "CRC32 and CRC32C check values" {
    // The standard check: the CRC of "123456789", with the usual
    // inversion around the architecture's step.
    const s = "123456789";
    var a: u32 = 0xffff_ffff;
    var b: u32 = 0xffff_ffff;
    for (s) |ch| {
        a = crc(false, a, ch, 1);
        b = crc(true, b, ch, 1);
    }
    try std.testing.expectEqual(@as(u32, 0xcbf4_3926), ~a);
    try std.testing.expectEqual(@as(u32, 0xe306_9283), ~b);
    // Wider steps agree with bytewise ones.
    const x: u64 = 0x0807_0605_0403_0201;
    var bytewise: u32 = 0x1234_5678;
    for (0..8) |i| bytewise = crc(true, bytewise, x >> @intCast(8 * i), 1);
    try std.testing.expectEqual(bytewise, crc(true, 0x1234_5678, x, 8));
}

test "decode CRC32 forms" {
    // crc32b w0, w1, w2
    const o = decodeDp2(0x1ac24020).?;
    try std.testing.expectEqual(kind(.crc32), o.k);
    try std.testing.expectEqual(@as(u8, 0), o.x);
    // crc32cx w3, w4, x5
    const c = decodeDp2(0x9ac55c83).?;
    try std.testing.expectEqual(kind(.crc32c), c.k);
    try std.testing.expectEqual(@as(u8, 3), c.x);
    // crc32x with sf clear, and crc32w with sf set, are unallocated.
    try std.testing.expect(decodeDp2(0x1ac54c83) == null);
    try std.testing.expect(decodeDp2(0x9ac54883) == null);
}
