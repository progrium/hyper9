//! Random FP and AdvSIMD instruction words and register values, for
//! simd_oracle_test.zig's check against the host CPU and for fuzz-a64's
//! lockstep against Unicorn (src/jit/check/gen_a64.zig).

const std = @import("std");
const dec = @import("decode.zig");

pub const f16s = [_]u16{ 0, 0x8000, 0x3c00, 0xbc00, 0x7c00, 0xfc00, 0x7e00, 0x7e55, 0x7c01, 0xfd23, 0x0400, 0x0001, 0x03ff, 0x7bff, 0x3800, 0x3e00, 0x4100, 0x3c01 };
pub const f32s = [_]u32{
    0,          0x80000000, 0x3f800000, 0xbf800000, 0x7f800000, 0xff800000, 0x7fc00000, 0x7fc12345,
    0x7f800001, 0xff812345, 0x00800000, 0x00000001, 0x007fffff, 0x807fffff, 0x7f7fffff, 0xff7fffff,
    0x3f000000, 0x3fc00000, 0x40200000, 0xc0200000, 0x4f000000, 0xcf000000, 0x4f800000, 0x5f000000,
    0xdf000000, 0x5f800000, 0x3f800001, 0x3effffff, 0x4effffff, 0x33800000, 0x00ffffff, 0x0f800000,
};
pub const f64s = [_]u64{
    0,                  0x8000000000000000, 0x3ff0000000000000, 0xbff0000000000000,
    0x7ff0000000000000, 0xfff0000000000000, 0x7ff8000000000000, 0x7ff8000012345678,
    0x7ff0000000000001, 0xfff0000000012345, 0x0010000000000000, 0x0000000000000001,
    0x000fffffffffffff, 0x800fffffffffffff, 0x7fefffffffffffff, 0x3fe0000000000000,
    0x3ff8000000000000, 0x4004000000000000, 0xc004000000000000, 0x41e0000000000000,
    0xc1e0000000000000, 0x41f0000000000000, 0x43e0000000000000, 0xc3e0000000000000,
    0x43f0000000000000, 0x3ff0000000000001, 0x380fffffe0000000, 0x47efffffe0000000,
    0x36a0000000000000, 0x3810000000000000, 0x41dfffffffc00000, 0x7e37e43c8800759c,
};

/// A V register value: random, or with lanes of FP edge values.
pub fn vValue(rand: std.Random) u128 {
    var v: u128 = @as(u128, rand.int(u64)) << 64 | rand.int(u64);
    switch (rand.uintLessThan(u8, 6)) {
        0 => for (0..8) |i| {
            if (rand.boolean()) v = (v & ~(@as(u128, 0xffff) << @intCast(16 * i))) | @as(u128, f16s[rand.uintLessThan(usize, f16s.len)]) << @intCast(16 * i);
        },
        1, 2 => for (0..4) |i| {
            if (rand.uintLessThan(u8, 4) != 0) v = (v & ~(@as(u128, 0xffffffff) << @intCast(32 * i))) | @as(u128, f32s[rand.uintLessThan(usize, f32s.len)]) << @intCast(32 * i);
        },
        3, 4 => for (0..2) |i| {
            if (rand.uintLessThan(u8, 4) != 0) v = (v & ~(@as(u128, std.math.maxInt(u64)) << @intCast(64 * i))) | @as(u128, f64s[rand.uintLessThan(usize, f64s.len)]) << @intCast(64 * i);
        },
        else => {},
    }
    return v;
}

pub const Class = struct { name: []const u8, mask: u32, val: u32 };

/// The FP and AdvSIMD data-processing encoding classes, as the bits that
/// must match.
pub const classes = [_]Class{
    .{ .name = "three same", .mask = 0x9f200400, .val = 0x0e200400 },
    .{ .name = "scalar three same", .mask = 0xdf200400, .val = 0x5e200400 },
    .{ .name = "three different", .mask = 0x9f200c00, .val = 0x0e200000 },
    .{ .name = "scalar three different", .mask = 0xdf200c00, .val = 0x5e200000 },
    .{ .name = "two-reg misc", .mask = 0x9f3e0c00, .val = 0x0e200800 },
    .{ .name = "scalar two-reg misc", .mask = 0xdf3e0c00, .val = 0x5e200800 },
    .{ .name = "across lanes", .mask = 0x9f3e0c00, .val = 0x0e300800 },
    .{ .name = "scalar pairwise", .mask = 0xdf3e0c00, .val = 0x5e300800 },
    .{ .name = "copy", .mask = 0x9fe08400, .val = 0x0e000400 },
    .{ .name = "scalar copy", .mask = 0xdfe08400, .val = 0x5e000400 },
    .{ .name = "modified immediate", .mask = 0x9ff80400, .val = 0x0f000400 },
    .{ .name = "shift by immediate", .mask = 0x9f800400, .val = 0x0f000400 },
    .{ .name = "scalar shift by immediate", .mask = 0xdf800400, .val = 0x5f000400 },
    .{ .name = "by element", .mask = 0x9f000400, .val = 0x0f000000 },
    .{ .name = "scalar by element", .mask = 0xdf000400, .val = 0x5f000000 },
    .{ .name = "table lookup", .mask = 0xbfe08c00, .val = 0x0e000000 },
    .{ .name = "permute", .mask = 0xbf208c00, .val = 0x0e000800 },
    .{ .name = "extract", .mask = 0xbfe08400, .val = 0x2e000000 },
    .{ .name = "FP and fixed point", .mask = 0x7f200000, .val = 0x1e000000 },
    .{ .name = "FP and integer", .mask = 0x7f20fc00, .val = 0x1e200000 },
    .{ .name = "FP one source", .mask = 0xff207c00, .val = 0x1e204000 },
    .{ .name = "FP compare", .mask = 0xff203c00, .val = 0x1e202000 },
    .{ .name = "FP immediate", .mask = 0xff201c00, .val = 0x1e201000 },
    .{ .name = "FP conditional compare", .mask = 0xff200c00, .val = 0x1e200400 },
    .{ .name = "FP two source", .mask = 0xff200c00, .val = 0x1e200800 },
    .{ .name = "FP conditional select", .mask = 0xff200c00, .val = 0x1e200c00 },
    .{ .name = "FP three source", .mask = 0xff000000, .val = 0x1f000000 },
};

/// A random word from `classes` that simd_decode.zig implements, reading
/// and writing no general register above x15 and not SP; null (try again)
/// for one that doesn't qualify. For fuzz-a64's programs.
pub fn word(r: std.Random) ?u32 {
    const c = classes[r.uintLessThan(usize, classes.len)];
    const w = (r.int(u32) & ~c.mask) | c.val;
    const o = dec.decode(w, 0x1000);
    if (!o.k.isSimd()) return null;
    const rs = dec.regs(o);
    if (rs.mem != .none) return null;
    const high: u64 = ~@as(u64, 0xffff);
    if (rs.write & high != 0 or rs.read & (1 << 18 | 1 << dec.SP) != 0) return null;
    return w;
}

/// A random FPCR: RMode, FZ, and DN, nearest and neither most often.
pub fn fpcr(r: std.Random) u32 {
    const rmode: u32 = if (r.boolean()) 0 else r.int(u2);
    const fz: u32 = @intFromBool(r.uintLessThan(u8, 4) == 0);
    const dn: u32 = @intFromBool(r.uintLessThan(u8, 4) == 0);
    return rmode << 22 | fz << 24 | dn << 25;
}

test "word gives implemented FP and AdvSIMD words" {
    var prng: std.Random.DefaultPrng = .init(1);
    var n: usize = 0;
    for (0..10000) |_| {
        if (word(prng.random())) |w| {
            try std.testing.expect(dec.decode(w, 0).k.isSimd());
            n += 1;
        }
    }
    try std.testing.expect(n > 1000);
}
