//! IR cases every emitter is checked against ir_eval with: the arm64
//! emitter's tests run them natively, and the wasm emitter's under Node
//! (tests/jit/). Each runs from a set register file and a 4 KiB data page
//! at 0x10000, so loads, stores, and the slow path take part.

const std = @import("std");
const builtin = @import("builtin");
/// Freestanding wasm has no stderr.
pub const can_print = builtin.os.tag != .freestanding;
const ir = @import("../ir.zig");
const ir_eval = @import("../ir_eval.zig");
const ctx = @import("../ctx.zig");
const mem = @import("../../interp/mem.zig");

pub const Case = struct { text: []const u8, regs: [8]u64 };

pub fn free(gpa: std.mem.Allocator, all: []Case) void {
    for (all) |c| gpa.free(c.text);
    gpa.free(all);
}

pub fn parse(gpa: std.mem.Allocator, c: Case) !ir.Region {
    var r = try ir.parse(gpa, c.text);
    errdefer r.deinit(gpa);
    if (ir.verify(&r)) |e| {
        if (can_print) std.debug.print("verify: {s} at %{d} in\n{s}\n", .{ e.msg, e.inst, c.text });
        return error.Invalid;
    }
    return r;
}

pub const Result = struct {
    exit: ctx.Exit,
    pc: u64,
    regs: [8]u64,
    page: u64, // a hash of the data page
    retired: u64,
};

pub const data_va = 0x10000;

/// The machine a case runs on. Allocate it (it holds a page).
pub const Env = struct {
    page: [mem.page_size]u8 align(mem.page_size) = undefined,
    regs: [8]u64 = undefined,
    tlb: mem.Tlb = .{},
    regions: [1]mem.Region = undefined,
    map: mem.Map = undefined,
    ctx: ctx.Ctx = .{},

    pub fn reset(e: *Env, c: Case) *ctx.Ctx {
        e.page = @splat(0x5a);
        e.regs = c.regs;
        e.tlb = .{};
        e.regions = .{.{ .va = data_va, .mem = &e.page, .write = true }};
        e.map = .{ .regions = &e.regions };
        e.ctx = .{
            .cpu = @intFromPtr(&e.regs),
            .tlb = @intFromPtr(&e.tlb),
            .space = @intFromPtr(&e.map),
            .slow_load = @intFromPtr(&mem.mapSlowLoad),
            .slow_store = @intFromPtr(&mem.mapSlowStore),
        };
        return &e.ctx;
    }

    pub fn result(e: *Env, exit: ctx.Exit) Result {
        return .{ .exit = exit, .pc = e.ctx.exit_pc, .regs = e.regs, .page = std.hash.Wyhash.hash(0, &e.page), .retired = e.ctx.retired };
    }

    pub fn evalCase(e: *Env, gpa: std.mem.Allocator, r: *const ir.Region, c: Case) !Result {
        const cx = e.reset(c);
        return e.result(try ir_eval.run(gpa, r, cx));
    }
};

pub fn same(want: Result, got: Result) bool {
    return want.exit == got.exit and want.pc == got.pc and std.mem.eql(u64, &want.regs, &got.regs) and want.page == got.page and want.retired == got.retired;
}

pub fn expectSame(n: usize, c: Case, want: Result, got: Result) !void {
    if (same(want, got)) return;
    if (can_print) std.debug.print("case {d} differs: want {any}\n got {any}\n{s}\n", .{ n, want, got, c.text });
    return error.TestExpectedEqual;
}

pub fn generate(gpa: std.mem.Allocator) ![]Case {
    var list: std.ArrayList(Case) = .empty;
    errdefer {
        for (list.items) |c| gpa.free(c.text);
        list.deinit(gpa);
    }
    // Binary integer ops at each width, with icmp.
    const ops = [_][]const u8{ "add", "sub", "mul", "udiv", "sdiv", "and", "or", "xor", "andn", "shl", "lshr", "ashr", "ror", "rol", "mulhu", "mulhs", "urem", "srem" };
    const tys = [_][]const u8{ "i64", "i32", "i16", "i8" };
    const vals = [_][2]u64{ .{ 7, 3 }, .{ 0xffff_ffff_ffff_fff9, 2 }, .{ 0x8000_0000, 0xffff_ffff }, .{ 5, 0 }, .{ 0x8000_0000_0000_0000, 0xffff_ffff_ffff_ffff }, .{ 0x1234_5678_9abc_def0, 67 } };
    for (ops) |op| for (tys) |ty| for (vals, 0..) |v, vi| {
        try list.append(gpa, .{ .regs = .{ v[0], v[1], 0, 0, 0, 0, 0, 0 }, .text = try std.fmt.allocPrint(gpa,
            \\b0:
            \\  %0 = getreg:i64 #0x0
            \\  %1 = getreg:i64 #0x8
            \\  %2 = trunc:{1s} %0
            \\  %3 = trunc:{1s} %1
            \\  %4 = {0s}:{1s} %2, %3
            \\  %5 = zext:i64 %4
            \\  setreg %5 #0x10
            \\  %6 = icmp:i1 %2, %3 #0x{2x}
            \\  %7 = zext:i64 %6
            \\  setreg %7 #0x18
            \\  exit.chain #0x40
        , .{ op, ty, vi % 10 }) });
    };
    // Unary ops, extensions, and select.
    const unary = [_][]const u8{ "neg", "not", "clz", "ctz", "popcnt", "rbit", "bswap" };
    for (unary) |op| for ([_][]const u8{ "i64", "i32", "i16" }) |ty| {
        try list.append(gpa, .{ .regs = .{ 0x0000_00f0_0000_0080, 0, 0, 0, 9, 0, 0, 0 }, .text = try std.fmt.allocPrint(gpa,
            \\b0:
            \\  %0 = getreg:{1s} #0x0
            \\  %1 = {0s}:{1s} %0
            \\  %2 = zext:i64 %1
            \\  setreg %2 #0x8
            \\  %3 = getreg:i8 #0x0
            \\  %4 = sext:{1s} %3
            \\  %5 = zext:i64 %4
            \\  setreg %5 #0x10
            \\  %6 = const:i1 #0x1
            \\  %7 = getreg:i64 #0x20
            \\  %8 = getreg:i64 #0x0
            \\  %9 = select:i64 %6, %7, %8
            \\  setreg %9 #0x28
            \\  exit.chain #0x0
        , .{ op, ty }) });
    };
    // Flags and conditions, both groups.
    const fvals = [_][2]u64{ .{ 0, 1 }, .{ 5, 5 }, .{ 0x7fff_ffff, 1 }, .{ 0xffff_ffff_ffff_ffff, 1 }, .{ 0x8000_0000_0000_0000, 1 } };
    for ([_][]const u8{ "i64", "i32" }) |ty| for (fvals) |v| for (0..16) |cc| {
        try list.append(gpa, .{ .regs = .{ v[0], v[1], 0, 0, 0, 0, 0, 0 }, .text = try std.fmt.allocPrint(gpa,
            \\b0:
            \\  %0 = getreg:{0s} #0x0
            \\  %1 = getreg:{0s} #0x8
            \\  %2 = nzcv.sub:flags %0, %1
            \\  %3 = nzcv.add:flags %0, %1
            \\  %4 = nzcv.logic:flags %0
            \\  %5 = nzcv.adc:flags %0, %1, %2
            \\  %6 = nzcv.sbc:flags %0, %1, %3
            \\  %7 = nzcv.pack:i32 %5
            \\  setreg %2 #0x10
            \\  setreg %3 #0x18
            \\  setreg %4 #0x20
            \\  setreg %7 #0x28
            \\  setreg %6 #0x30
            \\  %12 = getreg:i32 #0x0
            \\  %13 = getreg:i32 #0x8
            \\  %9 = eflags.sub:flags %12, %13
            \\  %14 = eflags.shl:flags %12, %13
            \\  %15 = eflags.shr:flags %13, %12
            \\  %16 = trunc:i8 %12
            \\  %17 = trunc:i8 %13
            \\  %18 = eflags.mul:flags %16, %17
            \\  %19 = eflags.pack:i32 %14
            \\  %20 = eflags.pack:i32 %15
            \\  %21 = eflags.pack:i32 %18
            \\  %22 = xor:i32 %19, %20
            \\  %23 = add:i32 %22, %21
            \\  setreg %23 #0x0
            \\  %10 = eflags.cond:i1 %9 #0x{1x}
            \\  %11 = zext:i64 %10
            \\  setreg %11 #0x38
            \\  %8 = nzcv.cond:i1 %2 #0x{1x}
            \\  brcond %8 -> b1 b2
            \\b1:
            \\  exit.chain #0x1
            \\b2:
            \\  exit.chain #0x2
        , .{ ty, cc }) });
    };
    // Memory, a loop, polls, retire, and faults.
    for ([_]u64{ data_va, data_va + 0xfec, data_va + 0x10000 }) |start| {
        try list.append(gpa, .{ .regs = .{ start, 0, 10, 0, 0, 0, 0, 0 }, .text = try gpa.dupe(u8,
            \\b0:
            \\  poll #0x100
            \\  br -> b1
            \\b1:
            \\  poll #0x104
            \\  %0 = getreg:i64 #0x0
            \\  %1 = getreg:i64 #0x8
            \\  %2 = load:i64 %0 #0x3 @0x108 !1
            \\  %3 = load:i32 %0 #0xa @0x10c !2
            \\  %4 = add:i64 %1, %2
            \\  %5 = sext:i64 %3
            \\  %6 = add:i64 %4, %5
            \\  setreg %6 #0x8
            \\  %7 = const:i64 #0x8
            \\  %8 = add:i64 %0, %7
            \\  %20 = trunc:i16 %6
            \\  store %8, %20 #0x1 @0x110 !3
            \\  setreg %8 #0x0
            \\  retire #0x5
            \\  %9 = getreg:i64 #0x10
            \\  %10 = const:i64 #0x1
            \\  %11 = sub:i64 %9, %10
            \\  setreg %11 #0x10
            \\  %12 = nzcv.sub:flags %9, %10
            \\  %13 = nzcv.cond:i1 %12 #0x1
            \\  brcond %13 -> b1 b2
            \\b2:
            \\  exit.svc #0x118 !1
        ) });
    }
    return list.toOwnedSlice(gpa);
}
