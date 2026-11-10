//! Checks softfloat.zig against Berkeley TestFloat's vectors, the output
//! of `testfloat_gen`: one case per line, operands then the expected
//! result and SoftFloat's exception flags, all in hex.
//!
//! As a test, softfloat.zig runs the sample in softfloat-vectors.txt,
//! whose sections start with a line naming the function and environment:
//!
//!     = f32_add near_even after notexact
//!
//! As a program, scripts/softfloat-test.sh pipes testfloat_gen into it:
//!
//!     testfloat_gen -rmin -tininessbefore f32_add | softfloat_vectors f32_add min before notexact
//!
//! A NaN result matches any NaN: which NaN is each caller's policy, and
//! SoftFloat's is x86's.

const std = @import("std");
const sf = @import("softfloat.zig");

const Fmt = enum { f16, f32, f64 };
const IntT = enum { i32, i64, ui32, ui64 };

const Op = union(enum) {
    add: Fmt,
    sub: Fmt,
    mul: Fmt,
    div: Fmt,
    sqrt: Fmt,
    mulAdd: Fmt,
    roundToInt: Fmt,
    /// The comparison, and whether it signals on a quiet NaN.
    cmp: struct { f: Fmt, rel: enum { eq, le, lt }, signaling: bool },
    to_int: struct { f: Fmt, i: IntT },
    from_int: struct { i: IntT, f: Fmt },
    to_fmt: struct { from: Fmt, to: Fmt },

    fn parse(name: []const u8) !Op {
        var it = std.mem.splitScalar(u8, name, '_');
        const a = it.next() orelse return error.UnknownFunction;
        const b = it.next() orelse return error.UnknownFunction;
        const rest = it.rest();
        if (std.meta.stringToEnum(Fmt, a)) |f| {
            if (std.mem.eql(u8, b, "to")) {
                if (std.meta.stringToEnum(Fmt, rest)) |t| return .{ .to_fmt = .{ .from = f, .to = t } };
                if (std.meta.stringToEnum(IntT, rest)) |i| return .{ .to_int = .{ .f = f, .i = i } };
                return error.UnknownFunction;
            }
            const sig = std.mem.eql(u8, rest, "signaling");
            const q = std.mem.eql(u8, rest, "quiet");
            if (std.mem.eql(u8, b, "eq")) return .{ .cmp = .{ .f = f, .rel = .eq, .signaling = sig } };
            if (std.mem.eql(u8, b, "le")) return .{ .cmp = .{ .f = f, .rel = .le, .signaling = !q } };
            if (std.mem.eql(u8, b, "lt")) return .{ .cmp = .{ .f = f, .rel = .lt, .signaling = !q } };
            inline for (.{ "add", "sub", "mul", "div", "sqrt", "mulAdd", "roundToInt" }) |n| {
                if (std.mem.eql(u8, b, n)) return @unionInit(Op, n, f);
            }
            return error.UnknownFunction;
        }
        if (std.meta.stringToEnum(IntT, a)) |i| {
            if (!std.mem.eql(u8, b, "to")) return error.UnknownFunction;
            const f = std.meta.stringToEnum(Fmt, rest) orelse return error.UnknownFunction;
            return .{ .from_int = .{ .i = i, .f = f } };
        }
        return error.UnknownFunction;
    }

    fn operands(o: Op) usize {
        return switch (o) {
            .add, .sub, .mul, .div, .cmp => 2,
            .mulAdd => 3,
            else => 1,
        };
    }
};

pub const Section = struct {
    op: Op,
    rounding: sf.Rounding,
    tininess: sf.Tininess,
    exact: bool,

    pub fn parse(func: []const u8, rounding: []const u8, tininess: []const u8, exact: []const u8) !Section {
        const r: sf.Rounding = if (std.mem.eql(u8, rounding, "near_even")) .near_even else if (std.mem.eql(u8, rounding, "min_mag")) .zero else if (std.mem.eql(u8, rounding, "min")) .down else if (std.mem.eql(u8, rounding, "max")) .up else if (std.mem.eql(u8, rounding, "near_max_mag")) .near_away else if (std.mem.eql(u8, rounding, "odd")) .odd else return error.UnknownRounding;
        return .{
            .op = try Op.parse(func),
            .rounding = r,
            .tininess = if (std.mem.eql(u8, tininess, "before")) .before_rounding else if (std.mem.eql(u8, tininess, "after")) .after_rounding else return error.UnknownTininess,
            .exact = if (std.mem.eql(u8, exact, "exact")) true else if (std.mem.eql(u8, exact, "notexact")) false else return error.UnknownExact,
        };
    }
};

fn Bits(comptime f: Fmt) type {
    return switch (f) {
        .f16 => u16,
        .f32 => u32,
        .f64 => u64,
    };
}

fn Int(comptime i: IntT) type {
    return switch (i) {
        .i32 => i32,
        .i64 => i64,
        .ui32 => u32,
        .ui64 => u64,
    };
}

/// SoftFloat's flags, from ours.
fn tfFlags(f: u8) u8 {
    return @as(u8, @intFromBool(f & sf.PE != 0)) |
        @as(u8, @intFromBool(f & sf.UE != 0)) << 1 |
        @as(u8, @intFromBool(f & sf.OE != 0)) << 2 |
        @as(u8, @intFromBool(f & sf.ZE != 0)) << 3 |
        @as(u8, @intFromBool(f & sf.IE != 0)) << 4;
}

const Result = struct { v: u64, flags: u8, nan: bool = false, any: bool = false };

fn run(s: Section, in: []const u64) Result {
    var env: sf.Env = .{ .rounding = s.rounding, .tininess = s.tininess };
    switch (s.op) {
        .add, .sub, .mul, .div, .sqrt, .mulAdd, .roundToInt => |fr| switch (fr) {
            inline else => |f| {
                const T = Bits(f);
                const r: T = switch (s.op) {
                    .add => sf.add(T, &env, @intCast(in[0]), @intCast(in[1])),
                    .sub => sf.sub(T, &env, @intCast(in[0]), @intCast(in[1])),
                    .mul => sf.mul(T, &env, @intCast(in[0]), @intCast(in[1])),
                    .div => sf.div(T, &env, @intCast(in[0]), @intCast(in[1])),
                    .mulAdd => sf.mulAdd(T, &env, @intCast(in[0]), @intCast(in[1]), @intCast(in[2])),
                    .sqrt => sf.sqrt(T, &env, @intCast(in[0])),
                    .roundToInt => sf.roundToInt(T, &env, @intCast(in[0]), s.rounding, s.exact),
                    else => unreachable,
                };
                return .{ .v = r, .flags = env.flags, .nan = sf.isNan(T, r) };
            },
        },
        .cmp => |c| switch (c.f) {
            inline else => |f| {
                const T = Bits(f);
                const o = sf.compare(T, &env, @intCast(in[0]), @intCast(in[1]), c.signaling);
                const t = switch (c.rel) {
                    .eq => o == .eq,
                    .le => o == .eq or o == .lt,
                    .lt => o == .lt,
                };
                return .{ .v = @intFromBool(t), .flags = env.flags };
            },
        },
        .to_int => |c| switch (c.f) {
            inline else => |f| switch (c.i) {
                inline else => |i| {
                    const T = Bits(f);
                    const I = Int(i);
                    const r = sf.toInt(T, I, &env, @intCast(in[0]), s.rounding);
                    if (!s.exact) env.flags &= ~sf.PE;
                    const U = std.meta.Int(.unsigned, @bitSizeOf(I));
                    // Out of range, the value is each caller's.
                    return .{ .v = if (r) |v| @as(U, @bitCast(v)) else 0, .flags = env.flags, .any = r == null };
                },
            },
        },
        .from_int => |c| switch (c.f) {
            inline else => |f| switch (c.i) {
                inline else => |i| {
                    const T = Bits(f);
                    const I = Int(i);
                    const U = std.meta.Int(.unsigned, @bitSizeOf(I));
                    const r = sf.fromInt(T, I, &env, @bitCast(@as(U, @intCast(in[0]))));
                    return .{ .v = r, .flags = env.flags };
                },
            },
        },
        .to_fmt => |c| switch (c.from) {
            inline else => |f| switch (c.to) {
                inline else => |t| {
                    if (f == t) unreachable;
                    const r = sf.convert(Bits(t), Bits(f), &env, @intCast(in[0]));
                    return .{ .v = r, .flags = env.flags, .nan = sf.isNan(Bits(t), r) };
                },
            },
        },
    }
}

/// Checks one vector line; returns whether it passed.
pub fn check(s: Section, line: []const u8, w: ?*std.Io.Writer) !bool {
    var vals: [5]u64 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, line, " \t\r");
    while (it.next()) |t| {
        if (n == vals.len) return error.BadLine;
        vals[n] = try std.fmt.parseUnsigned(u64, t, 16);
        n += 1;
    }
    const k = s.op.operands();
    if (n != k + 2) return error.BadLine;
    const want_v = vals[k];
    const want_f: u8 = @intCast(vals[k + 1]);
    const got = run(s, vals[0..k]);
    const nan_want = switch (s.op) {
        .add, .sub, .mul, .div, .sqrt, .mulAdd, .roundToInt => |fr| switch (fr) {
            inline else => |f| sf.isNan(Bits(f), @intCast(want_v)),
        },
        .to_fmt => |c| switch (c.to) {
            inline else => |t| sf.isNan(Bits(t), @intCast(want_v)),
        },
        else => false,
    };
    const ok_v = got.any or (if (nan_want) got.nan else got.v == want_v);
    const ok = ok_v and tfFlags(got.flags) == want_f;
    if (!ok) if (w) |out| try out.print("FAIL {s}: got {x} {x:0>2}\n", .{ line, got.v, tfFlags(got.flags) });
    return ok;
}

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 5) {
        std.debug.print("usage: softfloat_vectors func rounding tininess exact < vectors\n", .{});
        return 2;
    }
    const s = try Section.parse(args[1], args[2], args[3], args[4]);
    var inbuf: [1 << 16]u8 = undefined;
    var outbuf: [4096]u8 = undefined;
    var in = std.Io.File.stdin().readerStreaming(init.io, &inbuf);
    var out = std.Io.File.stdout().writerStreaming(init.io, &outbuf);
    var total: u64 = 0;
    var bad: u64 = 0;
    while (try in.interface.takeDelimiter('\n')) |line| {
        if (line.len == 0) continue;
        total += 1;
        if (!try check(s, line, &out.interface)) {
            bad += 1;
            if (bad > 20) break;
        }
    }
    try out.interface.print("{s} {s} {s} {s}: {d} cases, {d} failed\n", .{ args[1], args[2], args[3], args[4], total, bad });
    try out.interface.flush();
    return if (bad == 0) 0 else 1;
}

test "softfloat.zig matches TestFloat's sample" {
    const text = @embedFile("softfloat-vectors.txt");
    var lines = std.mem.splitScalar(u8, text, '\n');
    var s: ?Section = null;
    var bad: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '=') {
            var it = std.mem.tokenizeScalar(u8, line[1..], ' ');
            s = try Section.parse(it.next().?, it.next().?, it.next().?, it.next().?);
            continue;
        }
        if (!try check(s.?, line, null)) {
            std.debug.print("softfloat: FAIL {s}\n", .{line});
            bad += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), bad);
}
