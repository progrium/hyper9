//! Checks f80.zig against Berkeley TestFloat's vectors, the output of
//! `testfloat_gen`: one case per line, operands then the expected result
//! and SoftFloat's exception flags, all in hex.
//!
//! As a test, f80.zig runs the sample in f80-vectors.txt, whose sections
//! start with a line naming the function and environment:
//!
//!     = extF80_add near_even 80 notexact
//!
//! As a program, scripts/testfloat.sh pipes testfloat_gen into it:
//!
//!     testfloat_gen -rmin -precision64 extF80_add | f80_vectors extF80_add min 64 notexact

const std = @import("std");
const sf = @import("f80.zig");
const F80 = sf.F80;
const Env = sf.Env;

pub const Section = struct {
    func: Func,
    rounding: sf.Rounding,
    precision: sf.Precision,
    exact: bool,

    pub fn parse(func: []const u8, rounding: []const u8, precision: []const u8, exact: []const u8) !Section {
        return .{
            .func = std.meta.stringToEnum(Func, func) orelse return error.UnknownFunction,
            .rounding = std.meta.stringToEnum(sf.Rounding, rounding) orelse return error.UnknownRounding,
            .precision = if (std.mem.eql(u8, precision, "32")) .p32 else if (std.mem.eql(u8, precision, "64")) .p64 else if (std.mem.eql(u8, precision, "80")) .p80 else return error.UnknownPrecision,
            .exact = if (std.mem.eql(u8, exact, "exact")) true else if (std.mem.eql(u8, exact, "notexact")) false else return error.UnknownExact,
        };
    }
};

/// The functions TestFloat names, as testfloat_gen spells them.
pub const Func = enum {
    extF80_add,
    extF80_sub,
    extF80_mul,
    extF80_div,
    extF80_rem,
    extF80_sqrt,
    extF80_roundToInt,
    extF80_eq,
    extF80_le,
    extF80_lt,
    extF80_eq_signaling,
    extF80_le_quiet,
    extF80_lt_quiet,
    extF80_to_i32,
    extF80_to_i64,
    extF80_to_i32_r_minMag,
    extF80_to_i64_r_minMag,
    extF80_to_f32,
    extF80_to_f64,
    i32_to_extF80,
    i64_to_extF80,
    f32_to_extF80,
    f64_to_extF80,
};

fn hex(comptime T: type, s: []const u8) !T {
    return std.fmt.parseUnsigned(T, s, 16);
}

fn ext(s: []const u8) !F80 {
    if (s.len != 20) return error.BadOperand;
    return F80.fromBits(try hex(u80, s));
}

/// Checks one case. Returns false, with a message on stderr, if f80.zig's
/// result or flags differ.
pub fn check(sec: Section, line: []const u8) !bool {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    var fields: [4][]const u8 = undefined;
    var n: usize = 0;
    while (it.next()) |t| {
        if (n == fields.len) return error.BadLine;
        fields[n] = t;
        n += 1;
    }
    if (n < 3) return error.BadLine;
    const want_flags = try hex(u8, fields[n - 1]);
    const want = fields[n - 2];
    var env: Env = .{ .rounding = sec.rounding, .precision = sec.precision };
    const r = sec.rounding;
    var got_buf: [24]u8 = undefined;
    const got: []const u8 = switch (sec.func) {
        .extF80_add, .extF80_sub, .extF80_mul, .extF80_div, .extF80_rem => blk: {
            const a = try ext(fields[0]);
            const b = try ext(fields[1]);
            const z = switch (sec.func) {
                .extF80_add => env.add(a, b),
                .extF80_sub => env.sub(a, b),
                .extF80_mul => env.mul(a, b),
                .extF80_div => env.div(a, b),
                .extF80_rem => env.rem(a, b),
                else => unreachable,
            };
            break :blk try std.fmt.bufPrint(&got_buf, "{X:0>20}", .{z.toBits()});
        },
        .extF80_sqrt => try std.fmt.bufPrint(&got_buf, "{X:0>20}", .{env.sqrt(try ext(fields[0])).toBits()}),
        .extF80_roundToInt => try std.fmt.bufPrint(&got_buf, "{X:0>20}", .{env.roundToInt(try ext(fields[0]), r, sec.exact).toBits()}),
        .extF80_eq, .extF80_le, .extF80_lt, .extF80_eq_signaling, .extF80_le_quiet, .extF80_lt_quiet => blk: {
            const a = try ext(fields[0]);
            const b = try ext(fields[1]);
            const z = switch (sec.func) {
                .extF80_eq => env.eq(a, b),
                .extF80_le => env.le(a, b),
                .extF80_lt => env.lt(a, b),
                .extF80_eq_signaling => env.eqSignaling(a, b),
                .extF80_le_quiet => env.leQuiet(a, b),
                .extF80_lt_quiet => env.ltQuiet(a, b),
                else => unreachable,
            };
            break :blk if (z) "1" else "0";
        },
        .extF80_to_i32 => try std.fmt.bufPrint(&got_buf, "{X:0>8}", .{@as(u32, @bitCast(env.toI32(try ext(fields[0]), r, sec.exact)))}),
        .extF80_to_i64 => try std.fmt.bufPrint(&got_buf, "{X:0>16}", .{@as(u64, @bitCast(env.toI64(try ext(fields[0]), r, sec.exact)))}),
        .extF80_to_i32_r_minMag => try std.fmt.bufPrint(&got_buf, "{X:0>8}", .{@as(u32, @bitCast(env.toI32MinMag(try ext(fields[0]), sec.exact)))}),
        .extF80_to_i64_r_minMag => try std.fmt.bufPrint(&got_buf, "{X:0>16}", .{@as(u64, @bitCast(env.toI64MinMag(try ext(fields[0]), sec.exact)))}),
        .extF80_to_f32 => try std.fmt.bufPrint(&got_buf, "{X:0>8}", .{env.toF32(try ext(fields[0]))}),
        .extF80_to_f64 => try std.fmt.bufPrint(&got_buf, "{X:0>16}", .{env.toF64(try ext(fields[0]))}),
        .i32_to_extF80 => try std.fmt.bufPrint(&got_buf, "{X:0>20}", .{sf.fromI32(@bitCast(try hex(u32, fields[0]))).toBits()}),
        .i64_to_extF80 => try std.fmt.bufPrint(&got_buf, "{X:0>20}", .{sf.fromI64(@bitCast(try hex(u64, fields[0]))).toBits()}),
        .f32_to_extF80 => try std.fmt.bufPrint(&got_buf, "{X:0>20}", .{env.fromF32(try hex(u32, fields[0])).toBits()}),
        .f64_to_extF80 => try std.fmt.bufPrint(&got_buf, "{X:0>20}", .{env.fromF64(try hex(u64, fields[0])).toBits()}),
    };
    const got_flags: u8 = @bitCast(env.flags);
    if (std.ascii.eqlIgnoreCase(got, want) and got_flags == want_flags) return true;
    std.debug.print("{s} {s} {s} {s}: {s} gave {s} {X:0>2}\n", .{
        @tagName(sec.func), @tagName(sec.rounding), @tagName(sec.precision), if (sec.exact) "exact" else "notexact",
        line,               got,                    got_flags,
    });
    return false;
}

/// Runs a sectioned vector file; fails if any case does.
pub fn run(text: []const u8) !void {
    var sec: ?Section = null;
    var cases: usize = 0;
    var failed: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '=') {
            var it = std.mem.tokenizeScalar(u8, line[1..], ' ');
            const func = it.next() orelse return error.BadSection;
            const rounding = it.next() orelse return error.BadSection;
            const precision = it.next() orelse return error.BadSection;
            const exact = it.next() orelse return error.BadSection;
            sec = try Section.parse(func, rounding, precision, exact);
            continue;
        }
        cases += 1;
        if (!try check(sec orelse return error.NoSection, line)) failed += 1;
    }
    if (failed != 0) {
        std.debug.print("f80: {d} of {d} TestFloat cases failed\n", .{ failed, cases });
        return error.TestFloatMismatch;
    }
}

/// f80_vectors <function> <rounding> <precision> <exact|notexact>, with
/// testfloat_gen's output for that function and environment on stdin.
pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len != 5) {
        std.debug.print("usage: f80_vectors <function> <rounding> <32|64|80> <exact|notexact> <vectors\n", .{});
        return 2;
    }
    const sec = try Section.parse(argv[1], argv[2], argv[3], argv[4]);
    var buf: [4096]u8 = undefined;
    var rd = std.Io.File.stdin().readerStreaming(io, &buf);
    var cases: usize = 0;
    var failed: usize = 0;
    while (try rd.interface.takeDelimiter('\n')) |line| {
        if (line.len == 0) continue;
        cases += 1;
        if (!try check(sec, line)) {
            failed += 1;
            if (failed == 20) {
                std.debug.print("(stopping after 20 failures)\n", .{});
                break;
            }
        }
    }
    std.debug.print("{s} {s} {s} {s}: {d} cases, {d} failed\n", .{ argv[1], argv[2], argv[3], argv[4], cases, failed });
    return if (failed == 0) 0 else 1;
}
