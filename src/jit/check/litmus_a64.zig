//! ha64's litmus tests (litmus.zig): store buffering, message passing,
//! and counters, on T0 and T1. x0 holds the data page's address; the data
//! word is at [x0], the flag at [x0, #8].

const std = @import("std");
const check = @import("../check.zig");
const litmus = @import("litmus.zig");
const a64 = @import("a64.zig");
const mem = @import("../../interp/mem.zig");
const ctx_mod = @import("../ctx.zig");
const t0 = a64.t0;

const Cpu = a64.Cpu;

pub const arch: litmus.Arch = .{
    .guest = &a64.guest,
    .init_cpu = initCpu,
    .reg = reg,
    .open = open,
    .close = close,
    .run_t0 = runT0,
};

fn cpuOf(b: []u8) *Cpu {
    return @ptrCast(@alignCast(b.ptr));
}

fn initCpu(b: []u8, entry: u64, data: u64) void {
    const c = cpuOf(b);
    c.* = .{ .pc = entry };
    c.r[0] = data;
}

fn reg(b: []const u8, r: u8) u64 {
    const c: *const Cpu = @ptrCast(@alignCast(b.ptr));
    return c.r[r];
}

fn open(gpa: std.mem.Allocator, c: *ctx_mod.Ctx, map: *const mem.Map) anyerror!*anyopaque {
    return try a64.Bound.init(gpa, c, t0.mapSpace(map));
}

fn close(gpa: std.mem.Allocator, p: *anyopaque) void {
    const b: *a64.Bound = @ptrCast(@alignCast(p));
    b.deinit(gpa);
}

fn runT0(p: *anyopaque) anyerror!void {
    const b: *a64.Bound = @ptrCast(@alignCast(p));
    while (true) switch (t0.run(&b.machine, std.math.maxInt(u64))) {
        .syscall => return,
        .interrupted => {},
        .breakpoint => return error.UnexpectedExit,
        .fault => |f| return if (f.esr >> 26 == t0.EC_UNKNOWN) error.Undefined else error.UnexpectedExit,
    };
}

// ---------------------------------------------------------------- encodings

const svc: u32 = 0xd4000001;
const dmb_ish: u32 = 0xd5033bbf;

fn movz(rd: u32, imm: u32) u32 {
    return 0xd2800000 | imm << 5 | rd;
}
fn ldr(rt: u32, rn: u32, off: u32) u32 {
    return 0xf9400000 | (off / 8) << 10 | rn << 5 | rt;
}
fn str(rt: u32, rn: u32, off: u32) u32 {
    return 0xf9000000 | (off / 8) << 10 | rn << 5 | rt;
}
fn addi(rd: u32, rn: u32, imm: u32) u32 {
    return 0x91000000 | imm << 10 | rn << 5 | rd;
}
fn subsi(rd: u32, rn: u32, imm: u32) u32 {
    return 0xf1000000 | imm << 10 | rn << 5 | rd;
}
fn ldar(rt: u32, rn: u32) u32 {
    return 0xc8dffc00 | rn << 5 | rt;
}
fn stlr(rt: u32, rn: u32) u32 {
    return 0xc89ffc00 | rn << 5 | rt;
}
fn ldxr(rt: u32, rn: u32) u32 {
    return 0xc85f7c00 | rn << 5 | rt;
}
fn stxr(rs: u32, rt: u32, rn: u32) u32 {
    return 0xc8007c00 | rs << 16 | rn << 5 | rt;
}
fn ldaxr(rt: u32, rn: u32) u32 {
    return 0xc85ffc00 | rn << 5 | rt;
}
fn stlxr(rs: u32, rt: u32, rn: u32) u32 {
    return 0xc800fc00 | rs << 16 | rn << 5 | rt;
}
fn ldadd(rs: u32, rt: u32, rn: u32) u32 {
    return 0xf8200000 | rs << 16 | rn << 5 | rt;
}
/// CBNZ Wt and B.NE, `by` instructions from the branch (negative: back).
fn cbnzw(rt: u32, by: i32) u32 {
    return 0x35000000 | (@as(u32, @bitCast(by)) & 0x7ffff) << 5 | rt;
}
fn bne(by: i32) u32 {
    return 0x54000001 | (@as(u32, @bitCast(by)) & 0x7ffff) << 5;
}

const w = litmus.words;

// ---------------------------------------------------------------- tests

/// SB: each thread stores to one word and loads the other. Both loads
/// seeing 0 is allowed (and happens on hardware, a TSO host included).
pub const sb: litmus.Test = .{
    .name = "SB",
    .threads = &.{
        w(&.{ movz(1, 1), str(1, 0, 0), ldr(2, 0, 8), svc }),
        w(&.{ movz(1, 1), str(1, 0, 8), ldr(2, 0, 0), svc }),
    },
    .observe = &.{ .{ .reg = .{ .thread = 0, .reg = 2 } }, .{ .reg = .{ .thread = 1, .reg = 2 } } },
};

/// SB+DMBs: a DMB between the store and the load forbids 0, 0.
pub const sb_dmb: litmus.Test = .{
    .name = "SB+dmb.ish",
    .threads = &.{
        w(&.{ movz(1, 1), str(1, 0, 0), dmb_ish, ldr(2, 0, 8), svc }),
        w(&.{ movz(1, 1), str(1, 0, 8), dmb_ish, ldr(2, 0, 0), svc }),
    },
    .observe = sb.observe,
    .forbidden = &.{&.{ 0, 0 }},
};

/// MP: data then flag, flag then data. Without barriers the reader may
/// see the flag and old data (a TSO host won't show it).
pub const mp: litmus.Test = .{
    .name = "MP",
    .threads = &.{
        w(&.{ movz(1, 1), str(1, 0, 0), str(1, 0, 8), svc }),
        w(&.{ ldr(2, 0, 8), ldr(3, 0, 0), svc }),
    },
    .observe = &.{ .{ .reg = .{ .thread = 1, .reg = 2 } }, .{ .reg = .{ .thread = 1, .reg = 3 } } },
};

/// MP+DMBs: the flag set and the data old is forbidden.
pub const mp_dmb: litmus.Test = .{
    .name = "MP+dmb.ish",
    .threads = &.{
        w(&.{ movz(1, 1), str(1, 0, 0), dmb_ish, str(1, 0, 8), svc }),
        w(&.{ ldr(2, 0, 8), dmb_ish, ldr(3, 0, 0), svc }),
    },
    .observe = mp.observe,
    .forbidden = &.{&.{ 1, 0 }},
};

/// MP with STLR and LDAR on the flag: forbidden the same way.
pub const mp_rel_acq: litmus.Test = .{
    .name = "MP+stlr+ldar",
    .threads = &.{
        w(&.{ movz(1, 1), addi(4, 0, 8), str(1, 0, 0), stlr(1, 4), svc }),
        w(&.{ addi(4, 0, 8), ldar(2, 4), ldr(3, 0, 0), svc }),
    },
    .observe = mp.observe,
    .forbidden = &.{&.{ 1, 0 }},
};

pub const counter_iterations = 500;

/// LDXR/STXR increments of one word, `counter_iterations` per thread:
/// none may be lost.
pub const counter_exclusive: litmus.Test = .{
    .name = "counter ldxr/stxr",
    .threads = &.{ counterExclusive(false), counterExclusive(false), counterExclusive(true), counterExclusive(true) },
    .observe = &.{.{ .mem = 0 }},
    .only = &.{&.{4 * counter_iterations}},
};

fn counterExclusive(comptime acq_rel: bool) []const u8 {
    return w(&.{
        movz(5, counter_iterations),
        if (acq_rel) ldaxr(1, 0) else ldxr(1, 0), // loop:
        addi(1, 1, 1),
        if (acq_rel) stlxr(2, 1, 0) else stxr(2, 1, 0),
        cbnzw(2, -3),
        subsi(5, 5, 1),
        bne(-5),
        svc,
    });
}

/// LDADD (LSE) increments: none may be lost.
pub const counter_ldadd: litmus.Test = .{
    .name = "counter ldadd",
    .threads = &.{ counterLdadd(), counterLdadd(), counterLdadd(), counterLdadd() },
    .observe = &.{.{ .mem = 0 }},
    .only = &.{&.{4 * counter_iterations}},
};

fn counterLdadd() []const u8 {
    return w(&.{ movz(1, 1), movz(5, counter_iterations), ldadd(1, 2, 0), subsi(5, 5, 1), bne(-2), svc });
}

pub const all = [_]*const litmus.Test{ &sb, &sb_dmb, &mp, &mp_dmb, &mp_rel_acq, &counter_exclusive, &counter_ldadd };

test "litmus/a64: nothing forbidden on any tier" {
    const gpa = std.testing.allocator;
    for ([_]litmus.Tier{ .t0, .ir_eval, .native }) |tier| {
        if (tier == .native and !@import("../emit/native.zig").available()) continue;
        for (all) |t| {
            var tally = litmus.run(gpa, &arch, t, .{ .iterations = 200, .tier = tier }) catch |e| switch (e) {
                // LSE atomics aren't in T0's decoder yet.
                error.Undefined => if (t == &counter_ldadd) continue else return e,
                else => return e,
            };
            defer tally.deinit(gpa);
            if (tally.forbidden != 0) {
                var buf: [4096]u8 = undefined;
                var fw = std.Io.Writer.fixed(&buf);
                tally.print(t, tier, &fw) catch {};
                std.debug.print("{s}", .{fw.buffered()});
                return error.ForbiddenOutcome;
            }
            try std.testing.expectEqual(@as(u64, 200), tally.iterations);
        }
    }
}
