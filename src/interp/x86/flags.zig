//! Lazy EFLAGS for h86, as v86 and QEMU keep them: a flag-setting
//! instruction records what it did (its kind, operand size, operands, and
//! result), and a flag is computed only when something reads it. Most
//! flag results are overwritten unread, so most are never computed.
//!
//! `Flags.bits` holds the materialized EFLAGS. While `lazy.kind` isn't
//! `.none`, its arithmetic bits (CF, PF, AF, ZF, SF, and OF) are stale and
//! `lazy` says what they are; DF and the rest are always in `bits`.
//!
//! Undefined flags follow QEMU (and so Unicorn), so lockstep against it
//! compares all six: AF is 0 after logic operations, shifts, and
//! multiplies; SF, ZF, and PF after a multiply come from the low half of
//! the result; and OF after a shift of more than one bit is computed as
//! for one bit.

const std = @import("std");

pub const CF: u32 = 1 << 0;
pub const PF: u32 = 1 << 2;
pub const AF: u32 = 1 << 4;
pub const ZF: u32 = 1 << 6;
pub const SF: u32 = 1 << 7;
pub const TF: u32 = 1 << 8;
pub const IF: u32 = 1 << 9;
pub const DF: u32 = 1 << 10;
pub const OF: u32 = 1 << 11;
pub const AC: u32 = 1 << 18;
pub const ID: u32 = 1 << 21;
/// Bit 1, which reads as one.
pub const res1: u32 = 1 << 1;

/// The six arithmetic flags.
pub const arith: u32 = CF | PF | AF | ZF | SF | OF;
/// What POPF may change at ring 3 with IOPL 0: the arithmetic flags, DF,
/// AC (a 486 test toggles it), and ID (CPUID's test toggles it). TF, IF,
/// and IOPL stay as they were.
pub const popf_mask: u32 = arith | DF | AC | ID;

/// What the last flag-setting instruction was.
pub const Kind = enum(u8) {
    /// `bits` is current.
    none,
    /// res = a + b + cin.
    add,
    /// res = a - b - cin (also CMP, NEG, and SBB).
    sub,
    /// AND, OR, XOR, and TEST: CF, OF, and AF clear.
    logic,
    /// INC and DEC: as add and sub of 1, with CF kept in `cin`.
    inc,
    dec,
    /// Shifts by a nonzero count: `a` is the source shifted by one less
    /// than the count, so CF and OF come from it.
    shl,
    /// SHR and SAR.
    shr,
    /// MUL and IMUL: `a` is CF and OF (0 or 1), `res` the low half.
    mul,
};

pub const Lazy = struct {
    kind: Kind = .none,
    /// Operand size in bytes: 1, 2, or 4.
    size: u8 = 4,
    /// Carry in (ADC, SBB), or the CF that INC and DEC keep.
    cin: u1 = 0,
    a: u32 = 0,
    b: u32 = 0,
    res: u32 = 0,
};

pub inline fn signBit(size: u8) u32 {
    return @as(u32, 1) << @intCast(size * 8 - 1);
}

pub inline fn sizeMask(size: u8) u32 {
    return if (size == 4) 0xffff_ffff else (@as(u32, 1) << @intCast(size * 8)) - 1;
}

/// PF: set when the low byte of the result has an even number of ones.
pub inline fn parity(v: u32) bool {
    return @popCount(@as(u8, @truncate(v))) & 1 == 0;
}

/// The sixteen conditions of Jcc, SETcc, and CMOVcc, by their encoding.
pub const Cond = enum(u4) { o, no, b, ae, e, ne, be, a, s, ns, p, np, l, ge, le, g };

/// Flags each condition reads.
pub fn condReads(cc: u4) u32 {
    return switch (@as(Cond, @enumFromInt(cc))) {
        .o, .no => OF,
        .b, .ae => CF,
        .e, .ne => ZF,
        .be, .a => CF | ZF,
        .s, .ns => SF,
        .p, .np => PF,
        .l, .ge => SF | OF,
        .le, .g => ZF | SF | OF,
    };
}

pub const Flags = struct {
    bits: u32 = res1,
    lazy: Lazy = .{},

    /// EFLAGS, with every bit computed.
    pub fn get(f: *const Flags) u32 {
        if (f.lazy.kind == .none) return f.bits;
        var v = f.bits & ~arith;
        if (f.cf()) v |= CF;
        if (f.pf()) v |= PF;
        if (f.af()) v |= AF;
        if (f.zf()) v |= ZF;
        if (f.sf()) v |= SF;
        if (f.of()) v |= OF;
        return v;
    }

    /// Makes `bits` current.
    pub fn materialize(f: *Flags) void {
        if (f.lazy.kind == .none) return;
        f.bits = f.get();
        f.lazy.kind = .none;
    }

    /// Sets EFLAGS outright.
    pub fn set(f: *Flags, v: u32) void {
        f.bits = (v & ~@as(u32, 0x8028)) | res1; // bits 3, 5, and 15 read as zero
        f.lazy.kind = .none;
    }

    /// Sets the flags in `mask` to `v`'s, leaving the rest.
    pub fn setMasked(f: *Flags, mask: u32, v: u32) void {
        f.materialize();
        f.bits = (f.bits & ~mask) | (v & mask);
    }

    /// Records an arithmetic result; see `Kind`.
    pub inline fn record(f: *Flags, kind: Kind, size: u8, a: u32, b: u32, res: u32, cin: u1) void {
        f.lazy = .{ .kind = kind, .size = size, .a = a, .b = b, .res = res, .cin = cin };
    }

    /// INC and DEC keep CF, which goes into `cin` first.
    pub inline fn recordIncDec(f: *Flags, kind: Kind, size: u8, a: u32, res: u32) void {
        const c: u1 = @intFromBool(f.cf());
        f.lazy = .{ .kind = kind, .size = size, .a = a, .b = 1, .res = res, .cin = c };
    }

    pub fn df(f: *const Flags) bool {
        return f.bits & DF != 0;
    }

    pub fn cf(f: *const Flags) bool {
        const l = &f.lazy;
        const m = sizeMask(l.size);
        return switch (l.kind) {
            .none => f.bits & CF != 0,
            .add => blk: {
                const a = l.a & m;
                const r = l.res & m;
                break :blk r < a or (l.cin == 1 and r == a);
            },
            .sub => blk: {
                const a = l.a & m;
                const b = l.b & m;
                break :blk a < b or (l.cin == 1 and a == b);
            },
            .logic => false,
            .inc, .dec => l.cin == 1,
            .shl => l.a & signBit(l.size) != 0,
            .shr => l.a & 1 != 0,
            .mul => l.a != 0,
        };
    }

    pub fn of(f: *const Flags) bool {
        const l = &f.lazy;
        const sb = signBit(l.size);
        const m = sizeMask(l.size);
        return switch (l.kind) {
            .none => f.bits & OF != 0,
            .add => (l.a ^ l.res) & (l.b ^ l.res) & sb != 0,
            .sub => (l.a ^ l.b) & (l.a ^ l.res) & sb != 0,
            .logic => false,
            .inc => l.res & m == sb,
            .dec => l.res & m == sb - 1,
            .shl, .shr => (l.res ^ l.a) & sb != 0,
            .mul => l.a != 0,
        };
    }

    pub fn af(f: *const Flags) bool {
        const l = &f.lazy;
        return switch (l.kind) {
            .none => f.bits & AF != 0,
            .add, .sub, .inc, .dec => (l.a ^ l.b ^ l.res) & 0x10 != 0,
            .logic, .shl, .shr, .mul => false,
        };
    }

    pub fn zf(f: *const Flags) bool {
        if (f.lazy.kind == .none) return f.bits & ZF != 0;
        return f.lazy.res & sizeMask(f.lazy.size) == 0;
    }

    pub fn sf(f: *const Flags) bool {
        if (f.lazy.kind == .none) return f.bits & SF != 0;
        return f.lazy.res & signBit(f.lazy.size) != 0;
    }

    pub fn pf(f: *const Flags) bool {
        if (f.lazy.kind == .none) return f.bits & PF != 0;
        return parity(f.lazy.res);
    }

    /// Whether condition `cc` holds. A compare's conditions come straight
    /// from its operands.
    pub fn cond(f: *const Flags, cc: u4) bool {
        const l = &f.lazy;
        if (l.kind == .sub and l.cin == 0) {
            const m = sizeMask(l.size);
            const a = l.a & m;
            const b = l.b & m;
            const sh: u5 = @intCast(32 - @as(u32, l.size) * 8);
            const sa: i32 = @as(i32, @bitCast(a << sh)) >> sh;
            const sbv: i32 = @as(i32, @bitCast(b << sh)) >> sh;
            switch (@as(Cond, @enumFromInt(cc))) {
                .b => return a < b,
                .ae => return a >= b,
                .e => return a == b,
                .ne => return a != b,
                .be => return a <= b,
                .a => return a > b,
                .l => return sa < sbv,
                .ge => return sa >= sbv,
                .le => return sa <= sbv,
                .g => return sa > sbv,
                else => {},
            }
        }
        const r = switch (@as(Cond, @enumFromInt(cc & 0xe))) {
            .o => f.of(),
            .b => f.cf(),
            .e => f.zf(),
            .be => f.cf() or f.zf(),
            .s => f.sf(),
            .p => f.pf(),
            .l => f.sf() != f.of(),
            .le => f.zf() or (f.sf() != f.of()),
            else => unreachable,
        };
        return r != (cc & 1 != 0);
    }
};

test "add and sub flags" {
    var f: Flags = .{};
    // 0x7f + 1 in a byte: OF, SF, AF; no CF, no ZF.
    f.record(.add, 1, 0x7f, 1, 0x80, 0);
    try std.testing.expectEqual(OF | SF | AF | res1, f.get());
    // 0xff + 1: CF, ZF, AF, PF.
    f.record(.add, 1, 0xff, 1, 0x100, 0);
    try std.testing.expectEqual(CF | ZF | AF | PF | res1, f.get());
    // adc 0xffffffff + 0xffffffff + 1 = 0xffffffff, carry.
    f.record(.add, 4, 0xffff_ffff, 0xffff_ffff, 0xffff_ffff, 1);
    try std.testing.expect(f.cf());
    // cmp 1, 2: borrow, sign, and the signed and unsigned conditions.
    f.record(.sub, 4, 1, 2, 0xffff_ffff, 0);
    try std.testing.expect(f.cf() and f.sf() and !f.zf() and !f.of());
    try std.testing.expect(f.cond(@intFromEnum(Cond.b)) and f.cond(@intFromEnum(Cond.l)) and !f.cond(@intFromEnum(Cond.g)));
    // cmp 0x80000000, 1 overflows.
    f.record(.sub, 4, 0x8000_0000, 1, 0x7fff_ffff, 0);
    try std.testing.expect(f.of() and !f.sf());
    try std.testing.expect(f.cond(@intFromEnum(Cond.l)));
    // The general path agrees with the compare fast path.
    for (0..16) |cc| {
        var g = f;
        g.materialize();
        try std.testing.expectEqual(f.cond(@intCast(cc)), g.cond(@intCast(cc)));
    }
}

test "inc keeps CF" {
    var f: Flags = .{};
    f.set(CF | res1);
    f.recordIncDec(.inc, 4, 0x7fff_ffff, 0x8000_0000);
    try std.testing.expect(f.cf() and f.of() and f.sf());
    f.recordIncDec(.dec, 2, 0x8000, 0x7fff);
    try std.testing.expect(f.cf() and f.of() and !f.sf());
}
