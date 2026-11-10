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

pub const Case = struct {
    text: []const u8,
    regs: [8]u64,
    /// Instructions until a poll leaves.
    budget: i64 = std.math.maxInt(i64),
};

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
    /// For a fault: the address and the kind.
    addr: u64,
    info: u64,
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
            .slow_cas = @intFromPtr(&mem.mapSlowCas),
            .interp = @intFromPtr(&testInterp),
            .helpers = @intFromPtr(&test_helpers),
            .budget = c.budget,
        };
        return &e.ctx;
    }

    pub fn result(e: *Env, exit: ctx.Exit) Result {
        const fault = exit == .fault;
        return .{
            .exit = exit,
            .pc = e.ctx.exit_pc,
            .regs = e.regs,
            .page = std.hash.Wyhash.hash(0, &e.page),
            .retired = e.ctx.retired,
            .addr = if (fault) e.ctx.exit_addr else 0,
            .info = if (fault) e.ctx.exit_info & 0xffff else 0,
        };
    }

    pub fn evalCase(e: *Env, gpa: std.mem.Allocator, r: *const ir.Region, c: Case) !Result {
        const cx = e.reset(c);
        return e.result(try ir_eval.run(gpa, r, cx));
    }
};

pub fn same(want: Result, got: Result) bool {
    return want.exit == got.exit and want.pc == got.pc and std.mem.eql(u64, &want.regs, &got.regs) and want.page == got.page and
        want.retired == got.retired and want.addr == got.addr and want.info == got.info;
}

/// The Env's call.interp handler: a pure function of the handle, the PC,
/// and the registers. A handle ending in 0xf is an undefined instruction;
/// any other adds to a register.
pub fn testInterp(c: *ctx.Ctx, handle: u64, pc: u64) callconv(.c) u32 {
    const regs: *[8]u64 = @ptrFromInt(@as(usize, @intCast(c.cpu)));
    if (handle & 0xf == 0xf) {
        c.exit_pc = pc;
        return @intFromEnum(ctx.Exit.undef);
    }
    const k: usize = @intCast((handle >> 8) % 7);
    regs[k] = regs[k] *% 3 +% handle +% pc;
    return 0;
}

/// The Env's helpers: 0 returns a value and changes a register; 1 just
/// changes a register.
fn helper0(c: *ctx.Ctx, a: u64, b: u64, x: u64) callconv(.c) u64 {
    const regs: *[8]u64 = @ptrFromInt(@as(usize, @intCast(c.cpu)));
    regs[5] ^= a;
    return a +% (b *% 7) ^ x;
}
fn helper1(c: *ctx.Ctx, a: u64, b: u64, x: u64) callconv(.c) u64 {
    const regs: *[8]u64 = @ptrFromInt(@as(usize, @intCast(c.cpu)));
    regs[@intCast(a % 7)] = b +% x;
    return 0xdead;
}
/// 2 touches no register, as an ir.helper_no_regs helper may not.
fn helper2(_: *ctx.Ctx, a: u64, b: u64, x: u64) callconv(.c) u64 {
    return (a ^ (b << 3)) +% x;
}
pub const test_helpers = [_]ctx.HelperFn{ &helper0, &helper1, &helper2 };

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
    // x86 flags at each width, every condition of each.
    const evals = [_][3]u64{
        .{ 0, 0, 0 },                                       .{ 0xff, 1, 1 },                                    .{ 0x7f, 1, 0 },
        .{ 0x80, 0xff, 1 },                                 .{ 0x7fff_ffff, 0xffff_ffff, 1 },                   .{ 0x8000, 0x7fff, 0 },
        .{ 0x1234_5678, 0x9abc_def0, 1 },                   .{ 3, 0x8000_0001, 0 },                             .{ 0xffff_ffff_ffff_ffff, 1, 1 },
        .{ 0x7fff_ffff_ffff_ffff, 1, 0 },                   .{ 0x8000_0000_0000_0000, 0x7fff_ffff_ffff_ffff, 1 }, .{ 0x1_0000_0000, 0xffff_ffff, 0 },
    };
    const eops = [_][]const u8{ "add", "sub", "shl", "shr", "mul" };
    for ([_][]const u8{ "i8", "i16", "i32", "i64" }) |ty| for (evals) |v| for (eops) |op| for (0..16) |cc| {
        try list.append(gpa, .{ .regs = .{ v[0], v[1], v[2], 0, 0, 0, 0, 0 }, .text = try std.fmt.allocPrint(gpa,
            \\b0:
            \\  %0 = getreg:{0s} #0x0
            \\  %1 = getreg:{0s} #0x8
            \\  %2 = getreg:i32 #0x10
            \\  %3 = eflags.unpack:flags %2
            \\  %4 = eflags.{1s}:flags %0, %1
            \\  %5 = eflags.adc:flags %0, %1, %3
            \\  %6 = eflags.sbb:flags %0, %1, %3
            \\  %7 = eflags.inc:flags %0, %3
            \\  %8 = eflags.dec:flags %0, %3
            \\  %9 = eflags.logic:flags %0
            \\  %10 = eflags.pack:i32 %4
            \\  %11 = zext:i64 %10
            \\  setreg %11 #0x18
            \\  setreg %5 #0x20
            \\  setreg %6 #0x28
            \\  setreg %7 #0x30
            \\  %12 = eflags.pack:i32 %8
            \\  %13 = eflags.pack:i32 %9
            \\  %14 = shl:i32 %13, %12
            \\  %15 = xor:i32 %14, %12
            \\  %16 = zext:i64 %15
            \\  setreg %16 #0x38
            \\  %17 = eflags.cond:i1 %4 #0x{2x}
            \\  %18 = eflags.cond:i1 %6 #0x{2x}
            \\  %19 = xor:i1 %17, %18
            \\  %20 = zext:i64 %19
            \\  setreg %20 #0x0
            \\  brcond %17 -> b1 b2
            \\b1:
            \\  exit.chain #0x1
            \\b2:
            \\  exit.chain #0x2
        , .{ ty, op, cc }) });
    };
    // Memory, a loop, polls, retire, and faults.
    // Each in both memory models (Region.tso), and misaligned too.
    for ([_]u64{ data_va, data_va + 0xfec, data_va + 0x10000, data_va + 1 }) |start| for ([_][]const u8{ "", " tso" }) |model| {
        try list.append(gpa, .{ .regs = .{ start, 0, 10, 0, 0, 0, 0, 0 }, .text = try std.fmt.allocPrint(gpa,
            \\region 0x0{s}
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
        , .{model}) });
    };
    // cas: success, failure, each width, misaligned, and unmapped; and an
    // rmw load's fault, reported as a write.
    for ([_][]const u8{ "i64", "i32", "i16", "i8" }, 0..) |ty, k| for ([_]u64{ data_va + 8, data_va + 9, data_va + 0x10000 }) |addr| for ([_]u64{ 0x5a5a_5a5a_5a5a_5a5a, 7 }) |expected| {
        try list.append(gpa, .{ .regs = .{ addr, expected, 0x1122_3344_5566_7788, 0, 0, 0, 0, 0 }, .text = try std.fmt.allocPrint(gpa,
            \\b0:
            \\  %0 = getreg:i64 #0x0
            \\  %1 = getreg:{0s} #0x8
            \\  %2 = getreg:{0s} #0x10
            \\  %3 = cas:{0s} %0, %1, %2 #0x{1x} @0x200 !2
            \\  %4 = zext:i64 %3
            \\  setreg %4 #0x18
            \\  %5 = load:i64 %0 #0x103 @0x204 !3
            \\  setreg %5 #0x20
            \\  exit.chain #0x208 !4
        , .{ ty, 3 - k }) });
    };
    // pending.flags: written on every way out (a fault, a terminator), a
    // second one at another slot writing the first, a setreg dropping one,
    // a call writing one first, and nzcv's.
    for ([_]u64{ data_va, data_va + 0x10000 }) |start| for ([_][]const u8{ "logic", "add", "dec" }) |op| {
        try list.append(gpa, .{ .regs = .{ start, 0x7f, 0x80, 0, 0, 0, 0xdead_beef, 0x1234 }, .text = try std.fmt.allocPrint(gpa,
            \\handle 0x123
            \\b0:
            \\  %0 = getreg:i64 #0x0
            \\  %1 = getreg:i32 #0x8
            \\  %2 = getreg:i32 #0x10
            \\  %3 = eflags.sub:flags %1, %2
            \\  pending.flags %3 #0x30 @0x1
            \\  %4 = load:i32 %0 #0x2 @0x100 !1
            \\  %5 = getreg:i32 #0x18
            \\  %6 = eflags.unpack:flags %5
            \\  %7 = eflags.{0s}:flags %4{1s}
            \\  pending.flags %7 #0x30 @0x1
            \\  %8 = trunc:i8 %4
            \\  %9 = trunc:i8 %2
            \\  %10 = eflags.add:flags %8, %9
            \\  pending.flags %10 #0x38 @0x1
            \\  store %0, %1 #0x2 @0x104 !2
            \\  %11 = eflags.cond:i1 %10 #0x4
            \\  brcond %11 -> b1 b2
            \\b1:
            \\  %12 = getreg:i64 #0x8
            \\  %13 = getreg:i64 #0x10
            \\  %14 = nzcv.sub:flags %12, %13
            \\  pending.flags %14 #0x20 @0x0
            \\  %15 = trunc:i32 %13
            \\  %16 = eflags.logic:flags %15
            \\  pending.flags %16 #0x28 @0x1
            \\  %17 = const:i32 #0x5
            \\  setreg %17 #0x28
            \\  %19 = getreg:i64 #0x0
            \\  %18 = load:i64 %19 #0x3 @0x108 !3
            \\  call.interp #0x0 @0x10c !4
            \\  exit.chain #0x200 !5
            \\b2:
            \\  %20 = getreg:i32 #0x8
            \\  %22 = getreg:i32 #0x18
            \\  %23 = eflags.unpack:flags %22
            \\  %21 = eflags.inc:flags %20, %23
            \\  pending.flags %21 #0x30 @0x1
            \\  %24 = getreg:i64 #0x0
            \\  exit.indirect %24 !4
        , .{ op, if (std.mem.eql(u8, op, "logic")) "" else if (std.mem.eql(u8, op, "add")) ", %1" else ", %6" }) });
    };
    // Flags left pending across a branch: written on a fault in the
    // block that takes them, replaced there, or written at its exit; a
    // join whose predecessors differ writes them in each.
    for ([_]u64{ data_va, data_va + 0x10000 }) |start| for ([_]u64{ 0x7f, 0x80 }) |x1| {
        try list.append(gpa, .{ .regs = .{ start, x1, 0x80, 0, 0, 0, 0xdead_beef, 0 }, .text = try gpa.dupe(u8,
            \\b0:
            \\  %0 = getreg:i32 #0x8
            \\  %1 = getreg:i32 #0x10
            \\  %2 = eflags.sub:flags %0, %1
            \\  pending.flags %2 #0x30 @0x1
            \\  %3 = eflags.cond:i1 %2 #0x4
            \\  brcond %3 -> b1 b2
            \\b1:
            \\  %4 = getreg:i64 #0x0
            \\  %5 = load:i32 %4 #0x2 @0x100 !1
            \\  %11 = getreg:i32 #0x8
            \\  %6 = eflags.add:flags %5, %11
            \\  pending.flags %6 #0x30 @0x1
            \\  br -> b3
            \\b2:
            \\  %7 = getreg:i64 #0x0
            \\  %8 = load:i64 %7 #0x3 @0x104 !1
            \\  setreg %8 #0x18
            \\  br -> b3
            \\b3:
            \\  %9 = getreg:i64 #0x0
            \\  %10 = load:i64 %9 #0x3 @0x108 !2
            \\  setreg %10 #0x20
            \\  exit.chain #0x200 !3
        ) });
    };
    // A 32-bit guest's addresses (zext of an i32): the TLB in i32, on a
    // page, at its end, across it, and unmapped.
    for ([_]u64{ data_va + 8, data_va + 0xffc, data_va + 0xffe, data_va + 0x10000 }) |start| {
        try list.append(gpa, .{ .regs = .{ start, 0x1122_3344_5566_7788, 0, 0, 0, 0, 0, 0 }, .text = try gpa.dupe(u8,
            \\b0:
            \\  %0 = getreg:i32 #0x0
            \\  %1 = zext:i64 %0
            \\  %2 = getreg:i32 #0x8
            \\  store %1, %2 #0x2 @0x100 !1
            \\  %3 = zext:i64 %0
            \\  %4 = load:i16 %3 #0x1 @0x104 !2
            \\  %5 = zext:i64 %4
            \\  setreg %5 #0x10
            \\  %6 = zext:i64 %0
            \\  %7 = load:i32 %6 #0x2 @0x108 !3
            \\  %8 = zext:i64 %7
            \\  setreg %8 #0x18
            \\  setreg %1 #0x20
            \\  exit.chain #0x200 !4
        ) });
    }
    // A helper_no_regs call between a register's writes and its reads,
    // and with flags pending: neither need be written first.
    for ([_]u64{ data_va, data_va + 0x10000 }) |start| {
        try list.append(gpa, .{ .regs = .{ start, 0x7f, 0x80, 3, 0, 0, 0, 0 }, .text = try gpa.dupe(u8,
            \\b0:
            \\  %0 = getreg:i64 #0x8
            \\  %1 = getreg:i64 #0x10
            \\  %2 = add:i64 %0, %1
            \\  setreg %2 #0x8
            \\  %3 = trunc:i32 %0
            \\  %4 = trunc:i32 %1
            \\  %5 = eflags.sub:flags %3, %4
            \\  pending.flags %5 #0x30 @0x1
            \\  %6 = call.helper:i64 %2, %1, %0 #0x2 @0x1
            \\  %7 = getreg:i64 #0x8
            \\  %8 = add:i64 %7, %6
            \\  setreg %8 #0x18
            \\  %9 = getreg:i64 #0x0
            \\  %10 = load:i64 %9 #0x3 @0x100 !1
            \\  %11 = call.helper:i64 %10, %8, %2 #0x2 @0x1
            \\  setreg %11 #0x20
            \\  exit.chain #0x200 !2
        ) });
    }
    // same_page hints, right and wrong (the second load's page differs
    // when x0 is near the end of the page); a wrong hint must still work.
    for ([_]u64{ data_va, data_va + 0xff8, data_va + 0xffc }) |start| {
        try list.append(gpa, .{ .regs = .{ start, 0, 0, 0, 0, 0, 0, 0 }, .text = try gpa.dupe(u8,
            \\b0:
            \\  %0 = getreg:i64 #0x0
            \\  %1 = load:i64 %0 #0x3 @0x300
            \\  %2 = const:i64 #0x8
            \\  %3 = add:i64 %0, %2
            \\  %4 = load:i32 %3 #0x602 @0x304 !1
            \\  %5 = zext:i64 %4
            \\  %6 = add:i64 %1, %5
            \\  setreg %6 #0x8
            \\  store %0, %6 #0x3 @0x308 !2
            \\  store %3, %4 #0x202 @0x30c !3
            \\  exit.chain #0x310 !4
        ) });
    }
    return list.toOwnedSlice(gpa);
}

/// Cases for the FP and vector ops (`Op.isExt`), for emitters that lower
/// them or call ir_eval.evalExtC. Registers 0..3 are inputs (v128s are
/// built from pairs with v.make), results go to 0x10 and 0x30 (a v128 at
/// 0x30..0x40), and `fp.*` ops accumulate exceptions at 0x28.
pub fn generateExt(gpa: std.mem.Allocator) ![]Case {
    var list: std.ArrayList(Case) = .empty;
    errdefer {
        for (list.items) |c| gpa.free(c.text);
        list.deinit(gpa);
    }
    const Aux = ir.ExtAux;
    const envs = [_]Aux{
        .{}, // x86, nearest
        .{ .arm = true, .nans = 1 }, // Arm
        .{ .arm = true, .nans = 2, .daz = true, .ftz = true }, // Arm, DN and FZ
        .{ .rounding = 2, .daz = true, .ftz = true }, // x86, up, DAZ and FZ
        .{ .rounding = 3, .arm = true, .nans = 1 }, // Arm, toward zero
    };
    // Interesting binary32 and binary64 values, by kind.
    const f32s = [_]u64{ 0x3fc0_0000, 0xc010_0000, 0x7fc0_0001, 0x7f80_0001, 0x7f80_0000, 0x8000_0000, 0x0000_0001, 0x3eaa_aaab, 0x7f7f_ffff, 0x0080_0000, 0xff80_0000, 0x4f80_0000 };
    const f64s = [_]u64{ 0x3ff8_0000_0000_0000, 0xc002_0000_0000_0000, 0x7ff8_0000_0000_0001, 0x7ff0_0000_0000_0001, 0x7ff0_0000_0000_0000, 0x8000_0000_0000_0000, 0x0000_0000_0000_0001, 0x3fd5_5555_5555_5555, 0x7fef_ffff_ffff_ffff, 0x0010_0000_0000_0000, 0xfff0_0000_0000_0000, 0x43f0_0000_0000_0000 };
    const pairs = [_][2]u8{ .{ 0, 1 }, .{ 2, 0 }, .{ 0, 3 }, .{ 4, 4 }, .{ 4, 10 }, .{ 5, 9 }, .{ 6, 9 }, .{ 7, 1 }, .{ 8, 8 }, .{ 9, 6 } };
    const bin = [_][]const u8{ "fp.add", "fp.sub", "fp.mul", "fp.div", "fp.min", "fp.max", "fp.minnm", "fp.maxnm", "fp.cmp" };
    for ([_][]const u8{ "i32", "i64" }, [_][]const u64{ &f32s, &f64s }) |ty, vals| for (bin) |op| for (envs) |env| for (pairs) |pr| {
        var x = env;
        x.exact = std.mem.eql(u8, op, "fp.cmp") and env.rounding == 3;
        const rty = if (std.mem.eql(u8, op, "fp.cmp")) "i8" else ty;
        try list.append(gpa, .{ .regs = .{ vals[pr[0]], vals[pr[1]], 0, 0, 0, 0, 0, 0 }, .text = try std.fmt.allocPrint(gpa,
            \\b0:
            \\  %0 = getreg:{0s} #0x0
            \\  %1 = getreg:{0s} #0x8
            \\  %2 = {1s}:{2s} %0, %1 #0x{3x} @0x29
            \\  %3 = zext:i64 %2
            \\  setreg %3 #0x10
            \\  exit.chain #0x0
        , .{ ty, op, rty, @as(u64, @bitCast(x)) }) });
    };
    // One operand: sqrt, round, and conversions.
    for ([_][]const u8{ "i32", "i64" }, [_][]const u64{ &f32s, &f64s }) |ty, vals| for (envs) |env| for (vals) |v| {
        const other = if (ty[1] == '3') "i64" else "i32";
        var exact = env;
        exact.exact = true;
        var fixed = env;
        fixed.imm = 3;
        const ops = [_]struct { []const u8, []const u8, Aux }{
            .{ "fp.sqrt", ty, env },
            .{ "fp.round", ty, env },
            .{ "fp.round", ty, exact },
            .{ "fp.cvt", other, env },
            .{ "fp.cvt", "i16", env },
            .{ "fp.tosint", "i32", env },
            .{ "fp.tosint", "i64", fixed },
            .{ "fp.tosint", "i64", env },
            .{ "fp.touint", "i32", fixed },
            .{ "fp.touint", "i64", env },
        };
        for (ops) |o| try list.append(gpa, .{ .regs = .{ v, 0, 0, 0, 0, 0, 0, 0 }, .text = try std.fmt.allocPrint(gpa,
            \\b0:
            \\  %0 = getreg:{0s} #0x0
            \\  %1 = {1s}:{2s} %0 #0x{3x} @0x29
            \\  %2 = zext:i64 %1
            \\  setreg %2 #0x10
            \\  exit.chain #0x0
        , .{ ty, o[0], o[1], @as(u64, @bitCast(o[2])) }) });
    };
    // Exception words over several ops: an inexact divide, then (a) the
    // guest clearing the word and an exact add, or (b) the divide not
    // reporting and the add reporting. The word must hold only the add's.
    for (envs[0..2]) |env| for ([_]bool{ false, true }) |unreported| {
        const x: u64 = @bitCast(env);
        try list.append(gpa, .{ .regs = .{ 0x3ff0_0000_0000_0000, 0x4008_0000_0000_0000, 0, 0, 0, 0, 0, 0 }, .text = try std.fmt.allocPrint(gpa,
            \\b0:
            \\  %0 = getreg:i64 #0x0
            \\  %1 = getreg:i64 #0x8
            \\  %2 = fp.div:i64 %0, %1 #0x{0x}{1s}
            \\  %3 = const:i32 #0x0
            \\  {2s}
            \\  %5 = fp.add:i64 %0, %0 #0x{0x} @0x29
            \\  setreg %2 #0x10
            \\  setreg %5 #0x18
            \\  exit.chain #0x0
        , .{ x, if (unreported) "" else " @0x29", if (unreported) "%4 = add:i32 %3, %3" else "setreg %3 #0x28" }) });
    };
    // Integers to FP.
    const ints = [_]u64{ 0, 1, 3, 0xffff_ffff_ffff_ffff, 0x7fff_ffff, 0x8000_0000, 0x1234_5678_9abc_def1, 0x8000_0000_0000_0001 };
    for ([_][]const u8{ "fp.fromsint", "fp.fromuint" }) |op| for ([_][]const u8{ "i32", "i64" }) |from| for ([_][]const u8{ "i16", "i32", "i64" }) |to| for (envs[0..4]) |env| for (ints) |v| for ([_]u16{ 0, 5 }) |fb| {
        var x = env;
        x.imm = fb;
        try list.append(gpa, .{ .regs = .{ v, 0, 0, 0, 0, 0, 0, 0 }, .text = try std.fmt.allocPrint(gpa,
            \\b0:
            \\  %0 = getreg:{0s} #0x0
            \\  %1 = {1s}:{2s} %0 #0x{3x} @0x29
            \\  %2 = zext:i64 %1
            \\  setreg %2 #0x10
            \\  exit.chain #0x0
        , .{ from, op, to, @as(u64, @bitCast(x)) }) });
    };
    // Fused multiply-add.
    const triples = [_][3]u8{ .{ 0, 1, 7 }, .{ 4, 5, 2 }, .{ 4, 5, 0 }, .{ 3, 0, 2 }, .{ 8, 8, 10 }, .{ 9, 7, 6 } };
    for ([_][]const u8{ "i32", "i64" }, [_][]const u64{ &f32s, &f64s }) |ty, vals| for (envs) |env| for (triples) |t| {
        try list.append(gpa, .{ .regs = .{ vals[t[0]], vals[t[1]], vals[t[2]], 0, 0, 0, 0, 0 }, .text = try std.fmt.allocPrint(gpa,
            \\b0:
            \\  %0 = getreg:{0s} #0x0
            \\  %1 = getreg:{0s} #0x8
            \\  %2 = getreg:{0s} #0x10
            \\  %3 = fp.fma:{0s} %0, %1, %2 #0x{1x} @0x29
            \\  setreg %3 #0x10
            \\  exit.chain #0x0
        , .{ ty, @as(u64, @bitCast(env)) }) });
    };

    // Vectors.
    const vregs = [_][4]u64{
        .{ 0x8000_7fff_ff01_0080, 0x0123_4567_89ab_cdef, 0x7f80_0001_00ff_8000, 0xfedc_ba98_7654_3210 },
        .{ 0x1f0f_0e03_0200_8010, 0x0001_0203_0405_0607, 0x0706_0504_0302_0100, 0x0f0e_0d0c_0b0a_0908 },
        .{ 0xffff_ffff_ffff_ffff, 0x8000_0000_0000_0000, 0x0000_0000_0000_0001, 0x7fff_ffff_ffff_ffff },
    };
    const V = struct { op: []const u8, imm: []const u16, es: []const u2 };
    const all: []const u2 = &.{ 0, 1, 2, 3 };
    const vops = [_]V{
        .{ .op = "v.add", .imm = &.{0}, .es = all },
        .{ .op = "v.sub", .imm = &.{0}, .es = all },
        .{ .op = "v.mul", .imm = &.{0}, .es = &.{ 0, 1, 2 } },
        .{ .op = "v.and", .imm = &.{0}, .es = &.{0} },
        .{ .op = "v.or", .imm = &.{0}, .es = &.{0} },
        .{ .op = "v.xor", .imm = &.{0}, .es = &.{0} },
        .{ .op = "v.andn", .imm = &.{0}, .es = &.{0} },
        .{ .op = "v.cmp", .imm = &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 }, .es = all },
        .{ .op = "v.min", .imm = &.{ 0, 1 }, .es = all },
        .{ .op = "v.max", .imm = &.{ 0, 1 }, .es = all },
        .{ .op = "v.zip", .imm = &.{ 0, 1 }, .es = all },
        .{ .op = "v.uzp", .imm = &.{ 0, 1 }, .es = all },
        .{ .op = "v.trn", .imm = &.{ 0, 1 }, .es = all },
        .{ .op = "v.ext", .imm = &.{ 0, 1, 5, 8, 15 }, .es = &.{0} },
        .{ .op = "v.tbl", .imm = &.{0}, .es = &.{0} },
    };
    for (vregs) |r| for (vops) |o| for (o.es) |es| for (o.imm) |imm| {
        const x: Aux = .{ .esize = es, .imm = imm };
        try list.append(gpa, .{ .regs = .{ r[0], r[1], r[2], r[3], 0, 0, 0, 0 }, .text = try std.fmt.allocPrint(gpa,
            \\b0:
            \\  %0 = getreg:i64 #0x0
            \\  %1 = getreg:i64 #0x8
            \\  %2 = getreg:i64 #0x10
            \\  %3 = getreg:i64 #0x18
            \\  %4 = v.make:v128 %0, %1
            \\  %5 = v.make:v128 %2, %3
            \\  %6 = {0s}:v128 %4, %5 #0x{1x}
            \\  setreg %6 #0x30
            \\  exit.chain #0x0
        , .{ o.op, @as(u64, @bitCast(x)) }) });
    };
    // One-operand vector ops, lanes, and dup.
    for (vregs) |r| for (all) |es| {
        const bits = @as(u16, 8) << es;
        var ops: std.ArrayList(struct { []const u8, Aux }) = .empty;
        defer ops.deinit(gpa);
        for ([_][]const u8{ "v.shl", "v.lshr", "v.ashr" }) |op| for ([_]u16{ 0, 3, bits - 1, bits, bits + 1 }) |imm|
            try ops.append(gpa, .{ op, .{ .esize = es, .imm = imm } });
        if (es != 0) for (0..4) |imm| try ops.append(gpa, .{ "v.narrow", .{ .esize = es, .imm = @intCast(imm) } });
        if (es != 3) for (0..4) |imm| try ops.append(gpa, .{ "v.widen", .{ .esize = es, .imm = @intCast(imm) } });
        for (ops.items) |o| try list.append(gpa, .{ .regs = .{ r[0], r[1], r[2], r[3], 0, 0, 0, 0 }, .text = try std.fmt.allocPrint(gpa,
            \\b0:
            \\  %0 = getreg:i64 #0x0
            \\  %1 = getreg:i64 #0x8
            \\  %4 = v.make:v128 %0, %1
            \\  %6 = {0s}:v128 %4 #0x{1x}
            \\  setreg %6 #0x30
            \\  exit.chain #0x0
        , .{ o[0], @as(u64, @bitCast(o[1])) }) });
        const lt = @tagName(ir.laneType(es));
        const lane: u16 = @intCast(@min(@as(u32, 16) >> es, 16) - 1);
        try list.append(gpa, .{ .regs = .{ r[0], r[1], r[2], r[3], 0, 0, 0, 0 }, .text = try std.fmt.allocPrint(gpa,
            \\b0:
            \\  %0 = getreg:i64 #0x0
            \\  %1 = getreg:i64 #0x8
            \\  %2 = getreg:{0s} #0x10
            \\  %4 = v.make:v128 %0, %1
            \\  %5 = v.lane:{0s} %4 #0x{1x}
            \\  %6 = zext:i64 %5
            \\  setreg %6 #0x10
            \\  %7 = v.lane:{0s} %4 #0x{2x}
            \\  %8 = zext:i64 %7
            \\  setreg %8 #0x18
            \\  %9 = v.ins:v128 %4, %2 #0x{1x}
            \\  %10 = v.ins:v128 %9, %2 #0x{2x}
            \\  setreg %10 #0x30
            \\  %11 = v.dup:v128 %2 #0x{3x}
            \\  %12 = v.xor:v128 %11, %10
            \\  setreg %12 #0x20
            \\  exit.chain #0x0
        , .{ lt, @as(u64, @bitCast(Aux{ .esize = es })), @as(u64, @bitCast(Aux{ .esize = es, .imm = lane })), @as(u64, @bitCast(Aux{ .esize = es, .imm = lane / 2 })) }) });
    };
    // FP lanes.
    const fvregs = [_][4]u64{
        .{ 0x3fc0_0000_c010_0000, 0x7fc0_0001_7f80_0001, 0x3fc0_0000_3eaa_aaab, 0x7f80_0000_8000_0000 },
        .{ f64s[0], f64s[2], f64s[1], f64s[3] },
        .{ f64s[4], f64s[5], f64s[10], f64s[9] },
        .{ 0x4f80_0000_cf00_0000, 0x0000_0001_7f7f_ffff, 0x4b80_0001_3f80_0000, 0xff80_0000_0080_0000 },
    };
    const fvops = [_][]const u8{ "fp.add", "fp.sub", "fp.mul", "fp.div", "fp.min", "fp.max", "fp.minnm", "fp.maxnm", "fp.cmp", "fp.sqrt", "fp.round", "fp.tosint", "fp.touint", "fp.fromsint", "fp.fromuint", "fp.fma" };
    for (fvregs) |r| for (fvops) |op| for ([_]u2{ 2, 3 }) |es| for (envs[0..3]) |env| {
        var x = env;
        x.esize = es;
        if (std.mem.eql(u8, op, "fp.cmp")) x.imm = 0b1011;
        const nops: usize = if (std.mem.eql(u8, op, "fp.fma")) 3 else if (std.mem.indexOf(u8, "fp.sqrt fp.round fp.tosint fp.touint fp.fromsint fp.fromuint", op) != null) 1 else 2;
        const args = switch (nops) {
            1 => "%4",
            2 => "%4, %5",
            else => "%4, %5, %4",
        };
        try list.append(gpa, .{ .regs = .{ r[0], r[1], r[2], r[3], 0, 0, 0, 0 }, .text = try std.fmt.allocPrint(gpa,
            \\b0:
            \\  %0 = getreg:i64 #0x0
            \\  %1 = getreg:i64 #0x8
            \\  %2 = getreg:i64 #0x10
            \\  %3 = getreg:i64 #0x18
            \\  %4 = v.make:v128 %0, %1
            \\  %5 = v.make:v128 %2, %3
            \\  %6 = {0s}:v128 {1s} #0x{2x} @0x29
            \\  setreg %6 #0x30
            \\  exit.chain #0x0
        , .{ op, args, @as(u64, @bitCast(x)) }) });
    };
    for (fvregs) |r| for ([_]Aux{ .{ .esize = 2, .imm = 3 }, .{ .esize = 2, .imm = 0x103 }, .{ .esize = 3, .imm = 2 }, .{ .esize = 2, .imm = 1 }, .{ .esize = 1, .imm = 2 } }) |cv| for (envs[0..3]) |env| {
        var x = env;
        x.esize = cv.esize;
        x.imm = cv.imm;
        try list.append(gpa, .{ .regs = .{ r[0], r[1], r[2], r[3], 0, 0, 0, 0 }, .text = try std.fmt.allocPrint(gpa,
            \\b0:
            \\  %0 = getreg:i64 #0x0
            \\  %1 = getreg:i64 #0x8
            \\  %4 = v.make:v128 %0, %1
            \\  %6 = fp.cvt:v128 %4 #0x{0x} @0x29
            \\  setreg %6 #0x30
            \\  exit.chain #0x0
        , .{@as(u64, @bitCast(x))}) });
    };
    // Tininess: a product just under the smallest normal that rounds up
    // to it. Arm sees underflow (tiny before rounding), x86 doesn't.
    for ([_][]const u8{ "i32", "i64" }, [_][2]u64{ .{ 0x3f7f_fffe, 0x0080_0001 }, .{ 0x3fef_ffff_ffff_fffe, 0x0010_0000_0000_0001 } }, [_]u2{ 2, 3 }) |ty, v, es| for (envs[0..2]) |env| {
        var x = env;
        try list.append(gpa, .{ .regs = .{ v[0], v[1], 0, 0, 0, 0, 0, 0 }, .text = try std.fmt.allocPrint(gpa,
            \\b0:
            \\  %0 = getreg:{0s} #0x0
            \\  %1 = getreg:{0s} #0x8
            \\  %2 = fp.mul:{0s} %0, %1 #0x{1x} @0x29
            \\  %3 = zext:i64 %2
            \\  setreg %3 #0x10
            \\  exit.chain #0x0
        , .{ ty, @as(u64, @bitCast(x)) }) });
        // The same in every lane.
        x.esize = es;
        const lo = if (es == 2) v[0] | v[0] << 32 else v[0];
        const hi = if (es == 2) v[1] | v[1] << 32 else v[1];
        try list.append(gpa, .{ .regs = .{ lo, lo, hi, hi, 0, 0, 0, 0 }, .text = try std.fmt.allocPrint(gpa,
            \\b0:
            \\  %0 = getreg:i64 #0x0
            \\  %1 = getreg:i64 #0x8
            \\  %2 = getreg:i64 #0x10
            \\  %3 = getreg:i64 #0x18
            \\  %4 = v.make:v128 %0, %1
            \\  %5 = v.make:v128 %2, %3
            \\  %6 = fp.mul:v128 %4, %5 #0x{0x} @0x29
            \\  setreg %6 #0x30
            \\  exit.chain #0x0
        , .{@as(u64, @bitCast(x))}) });
    };
    // 16-byte loads and stores: in a page, across its end, unmapped, and
    // misaligned where alignment is required.
    for ([_]u64{ data_va, data_va + 0x10, data_va + 0xff8, data_va + 0xfe0, data_va + 0x10000, data_va + 3 }) |addr| for ([_]u64{ 4, 0x14 }) |f| {
        try list.append(gpa, .{ .regs = .{ addr, 0, 0x0123_4567_89ab_cdef, 0xfedc_ba98_7654_3210, 0, 0, 0, 0 }, .text = try std.fmt.allocPrint(gpa,
            \\region 0x0
            \\b0:
            \\  %0 = getreg:i64 #0x0
            \\  %1 = v.load:v128 %0 #0x{0x} @0x300 !1
            \\  setreg %1 #0x30
            \\  %2 = const:i64 #0x10
            \\  %3 = add:i64 %0, %2
            \\  v.store %3, %1 #0x{0x} @0x304 !2
            \\  %5 = getreg:v128 #0x10
            \\  v.store %0, %5 #0x{0x} @0x308 !3
            \\  exit.chain #0x30c !4
        , .{f}) });
    };
    // same_page hints, right and wrong (the second load's page differs
    // when x0 is near the end of the page); a wrong hint must still work.
    for ([_]u64{ data_va, data_va + 0xff8, data_va + 0xffc }) |start| {
        try list.append(gpa, .{ .regs = .{ start, 0, 0, 0, 0, 0, 0, 0 }, .text = try gpa.dupe(u8,
            \\b0:
            \\  %0 = getreg:i64 #0x0
            \\  %1 = load:i64 %0 #0x3 @0x300
            \\  %2 = const:i64 #0x8
            \\  %3 = add:i64 %0, %2
            \\  %4 = load:i32 %3 #0x602 @0x304 !1
            \\  %5 = zext:i64 %4
            \\  %6 = add:i64 %1, %5
            \\  setreg %6 #0x8
            \\  store %0, %6 #0x3 @0x308 !2
            \\  store %3, %4 #0x202 @0x30c !3
            \\  exit.chain #0x310 !4
        ) });
    }
    return list.toOwnedSlice(gpa);
}

test "the FP and vector cases verify and run in ir_eval" {
    const gpa = std.testing.allocator;
    const all = try generateExt(gpa);
    defer free(gpa, all);
    const env = try gpa.create(Env);
    defer gpa.destroy(env);
    for (all) |c| {
        var r = try parse(gpa, c);
        defer r.deinit(gpa);
        _ = try env.evalCase(gpa, &r, c);
    }
}

/// Lazy records (pending.flags @0x2), for emitters that lower them.
pub fn generateLazyFlags(gpa: std.mem.Allocator) ![]Case {
    var list: std.ArrayList(Case) = .empty;
    errdefer {
        for (list.items) |c| gpa.free(c.text);
        list.deinit(gpa);
    }
    // Lazy records (pending.flags @0x2): from each kind of flags op, used
    // only there or also by a branch, written on a fault, at an exit,
    // replaced, and dropped by a setreg. b1 clears the record's kind byte
    // first, as the x86 lifter's settle does, so an emitter must keep
    // that byte in the Cpu, not in a register it writes back later.
    for ([_]u64{ data_va, data_va + 0x10000 }) |start| for ([_][]const u8{
        "eflags.add:flags %1, %2",       "eflags.sub:flags %1, %2",
        "eflags.adc:flags %1, %2, %4",   "eflags.sbb:flags %1, %2, %4",
        "eflags.logic:flags %1",         "eflags.inc:flags %1, %4",
        "eflags.dec:flags %1, %4",       "eflags.shl:flags %1, %2",
        "eflags.shr:flags %1, %2",       "eflags.mul:flags %1, %2",
    }) |op| for ([_][]const u8{ "i32", "i8", "i64" }) |ty| {
        // The bits word at 0x20 and the record after it, to the end of
        // the registers; i64 operands are the registers whole.
        const narrow = !std.mem.eql(u8, ty, "i64");
        const ops: []const u8 = if (narrow)
            try std.fmt.allocPrint(gpa, "  %9 = getreg:i32 #0x8\n  %1 = trunc:{0s} %9\n  %10 = getreg:i32 #0x10\n  %2 = trunc:{0s} %10\n", .{ty})
        else
            try gpa.dupe(u8, "  %1 = getreg:i64 #0x8\n  %2 = getreg:i64 #0x10\n");
        defer gpa.free(ops);
        try list.append(gpa, .{ .regs = .{ start, 0xffff_ff00_8000_00f7, 0x7fff_ff19, 1, 0x202, 0, 0, 0 }, .text = try std.fmt.allocPrint(gpa,
            \\b0:
            \\  %0 = getreg:i64 #0x0
            \\{2s}  %11 = getreg:i32 #0x18
            \\  %4 = eflags.unpack:flags %11
            \\  %5 = {0s}
            \\  pending.flags %5 #0x20 @0x2
            \\  %6 = load:i32 %0 #0x2 @0x100 !1
            \\  %7 = eflags.cond:i1 %5 #0x4
            \\  brcond %7 -> b1 b2
            \\b1:
            \\  %15 = const:i8
            \\  setreg %15 #0x24
            \\  %12 = getreg:{1s} #0x8
            \\  %13 = eflags.logic:flags %12
            \\  pending.flags %13 #0x20 @0x2
            \\  exit.chain #0x200 !2
            \\b2:
            \\  %14 = getreg:i64 #0x0
            \\  exit.indirect %14 !2
        , .{ op, if (narrow) "i32" else "i64", ops }) });
    };
    return list.toOwnedSlice(gpa);
}

/// pending.flags over a word a setreg just wrote (a chunk where the
/// emitter pins one), for both groups: for emitters that lower it.
pub fn generatePending(gpa: std.mem.Allocator) ![]Case {
    var list: std.ArrayList(Case) = .empty;
    errdefer {
        for (list.items) |c| gpa.free(c.text);
        list.deinit(gpa);
    }
    for ([_][]const u8{ "nzcv.sub", "eflags.sub" }, [_][]const u8{ "", " @0x1" }) |op, grp| for ([_][2]u64{ .{ 5, 7 }, .{ 7, 5 }, .{ 0x8000_0000, 1 } }) |v| {
        try list.append(gpa, .{ .regs = .{ v[0], v[1], 0xffff_fffe, 0, 0, 0, 0, 0 }, .text = try std.fmt.allocPrint(gpa,
            \\b0:
            \\  %0 = getreg:i32 #0x0
            \\  %1 = getreg:i32 #0x8
            \\  %2 = {0s}:flags %0, %1
            \\  %3 = getreg:i64 #0x10
            \\  %4 = zext:i64 %1
            \\  %5 = add:i64 %3, %4
            \\  setreg %5 #0x10
            \\  pending.flags %2 #0x10{1s}
            \\  exit.chain #0x0
        , .{ op, grp }) });
    };
    // Nothing reads the word (0x18, its other bits set), so an emitter
    // may keep it pending across the edge: written at the exit, at a poll
    // that leaves, or dropped by a setreg over it.
    const tails = [_][]const u8{
        "  br -> b1\nb1:\n  exit.chain #0x0\n",
        "  br -> b1\nb1:\n  poll #0x40\n  exit.chain #0x0\n",
        "  setreg %1 #0x18\n  br -> b1\nb1:\n  exit.chain #0x0\n",
    };
    for ([_][]const u8{ "nzcv.sub", "eflags.sub" }, [_][]const u8{ "", " @0x1" }) |op, grp| for (tails, 0..) |tail, t| {
        try list.append(gpa, .{ .regs = .{ 5, 7, 0, 0xdead_beef_ffff_ffff, 0, 0, 0, 0 }, .budget = if (t == 1) 0 else std.math.maxInt(i64), .text = try std.fmt.allocPrint(gpa,
            \\b0:
            \\  %0 = getreg:i32 #0x0
            \\  %1 = getreg:i32 #0x8
            \\  %2 = {0s}:flags %0, %1
            \\  pending.flags %2 #0x18{1s}
            \\  %4 = sub:i32 %0, %1
            \\  %5 = zext:i64 %4
            \\  setreg %5 #0x0
            \\{2s}
        , .{ op, grp, tail }) });
    };
    // A countdown loop (subs; b.ne): the compare, the flags, and the
    // branch may share the host's flags, and a poll may leave mid-loop.
    for ([_]i64{ std.math.maxInt(i64), 3 }) |budget| {
        try list.append(gpa, .{ .regs = .{ 5, 0, 0, 0xdead_beef_ffff_ffff, 0, 0, 0, 0 }, .budget = budget, .text = try gpa.dupe(u8,
            \\b0:
            \\  poll #0x40
            \\  %1 = getreg:i64 #0x0
            \\  %2 = const:i64 #0x1
            \\  %3 = sub:i64 %1, %2
            \\  %4 = nzcv.sub:flags %1, %2
            \\  setreg %3 #0x0
            \\  %6 = icmp:i1 %1, %2 #0x1
            \\  pending.flags %4 #0x18
            \\  retire #0x2
            \\  brcond %6 -> b0 b1
            \\b1:
            \\  exit.chain #0x0
        ) });
    }
    // Flags pending from an op that isn't kept in host flags (adc, and
    // an add with two uses) and from one that is.
    try list.append(gpa, .{ .regs = .{ 0xffff_ffff, 1, 0, 0xdead_beef_ffff_ffff, 0, 0, 0, 0 }, .text = try gpa.dupe(u8,
        \\b0:
        \\  %0 = getreg:i32 #0x0
        \\  %1 = getreg:i32 #0x8
        \\  %2 = nzcv.add:flags %0, %1
        \\  pending.flags %2 #0x18
        \\  %4 = nzcv.adc:flags %0, %1, %2
        \\  pending.flags %4 #0x18
        \\  br -> b1
        \\b1:
        \\  %7 = getreg:i32 #0x0
        \\  %8 = getreg:i32 #0x8
        \\  %9 = icmp:i1 %7, %8 #0x2
        \\  brcond %9 -> b2 b3
        \\b2:
        \\  %11 = getreg:i32 #0x8
        \\  %12 = nzcv.add:flags %11, %11
        \\  pending.flags %12 #0x18
        \\  exit.chain #0x0
        \\b3:
        \\  exit.chain #0x4
    ) });
    // Lazy eflags (aux2 = 2): the record of each kind's operands, at
    // each width, written at 0x1c over a word of other bits. The carry ops
    // take theirs from flags with CF set; the flags op has a second use
    // in half of them, so it's computed too.
    for ([_][]const u8{ "i8", "i16", "i32" }) |t| for ([_][]const u8{ "add", "sub", "adc", "sbb", "logic", "inc", "dec", "shl", "shr", "mul" }) |op| for (0..2) |twice| {
        const carry = std.mem.eql(u8, op, "adc") or std.mem.eql(u8, op, "sbb");
        const one = std.mem.eql(u8, op, "logic");
        const keeps = std.mem.eql(u8, op, "inc") or std.mem.eql(u8, op, "dec");
        const args = if (carry) "%0, %1, %3" else if (one) "%0" else if (keeps) "%0, %3" else "%1, %0";
        try list.append(gpa, .{ .regs = .{ 0xffff_ff85, 0x7f_ff93, 0, 0xdead_beef_ffff_ffff, 0x1111_2222_3333_4444, 0x5555_6666_7777_8888, 0, 0 }, .text = try std.fmt.allocPrint(gpa,
            \\b0:
            \\  %0 = getreg:{0s} #0x0
            \\  %1 = getreg:{0s} #0x8
            \\  %2 = const:i32 #0x8d5
            \\  %3 = eflags.unpack:flags %2
            \\  %4 = eflags.{1s}:flags {2s}
            \\  pending.flags %4 #0x18 @0x2
            \\  {3s}
            \\  exit.chain #0x0
        , .{ t, op, args, if (twice == 1) "%6 = eflags.pack:i32 %4\n  setreg %6 #0x10" else "%6 = const:i32 #0x0" }) });
    };
    return list.toOwnedSlice(gpa);
}
