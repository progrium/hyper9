//! zig build a64-jit (and test, with -Demu=zig): the arm64 JIT plan's
//! [a64-jit] cases, each run through the vmm interface on h9's own
//! emulator (zemu and ha64), on T0 and on T1 (H9_EMU_TIER at create).
//! Not in zig build test yet: two cases fail on T0 (a store into the
//! running page isn't seen until the next branch, even after an ISB, and
//! CNTVCT_EL0 in deterministic mode reads `retired` as of the run's start).
//!
//! T1 is this host's emitter: the x86-64 one here, the arm64 one on an
//! arm64 Mac. Without -Demu=zig they skip.
//!
//! The machine: code at 0x10000 (two pages, read, write, and execute), data
//! at 0x20000 (a page), with x0 holding the data page's address, and
//! nothing mapped at 0x50000.

const std = @import("std");
const h9 = @import("h9");
const vmm = h9.vmm;
const testing = std.testing;

const code_va: u64 = 0x10000;
const data_va: u64 = 0x20000;
const bad_va: u64 = 0x50000;
const page = vmm.page_size;

const Tier = enum { t0, t1 };

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// Settings read when a backend is created.
const Env = struct {
    cache: ?[:0]const u8 = null,
    deterministic: bool = false,
};

/// A backend on one tier with the code and data pages mapped.
const M = struct {
    b: vmm.Backend,
    as: vmm.AddressSpace,
    code: []align(page) u8,
    data: []align(page) u8,

    /// Null where there's no zemu with a JIT to test.
    fn init(t: Tier, prog: []const u32, env: Env) !?M {
        var buf: [32]u8 = undefined;
        const v = vmm.emuVersion(&buf) orelse return null;
        if (!std.mem.eql(u8, v, "zig (jit)")) return null;
        _ = setenv("H9_EMU_TIER", @tagName(t), 1);
        if (env.cache) |c| _ = setenv("H9_EMU_CACHE", c, 1);
        if (env.deterministic) _ = setenv("H9_EMU_DETERMINISTIC", "1", 1);
        defer {
            _ = unsetenv("H9_EMU_TIER");
            _ = unsetenv("H9_EMU_CACHE");
            _ = unsetenv("H9_EMU_DETERMINISTIC");
        }
        const b = try vmm.create(testing.allocator, testing.io, .emu, .{ .arch = .arm64, .memory = 64 << 20 });
        errdefer b.destroy();
        const as = try b.newAddressSpace();
        errdefer as.destroy();
        const code = try b.allocPages(2);
        const data = try b.allocPages(1);
        @memset(code, 0);
        @memset(data, 0);
        for (prog, 0..) |w, i| std.mem.writeInt(u32, code[i * 4 ..][0..4], w, .little);
        try as.map(code_va, code[0..page], .{ .write = true, .exec = true });
        try as.map(code_va + page, code[page..], .{ .write = true, .exec = true });
        try as.map(data_va, data, .{ .write = true });
        return .{ .b = b, .as = as, .code = code, .data = data };
    }

    fn deinit(m: *M) void {
        m.as.destroy();
        m.b.freePages(m.code);
        m.b.freePages(m.data);
        m.b.destroy();
    }

    /// A vCPU at the start of the code, x0 the data page, and `regs` in
    /// x1 on.
    fn vcpu(m: *M, regs: []const u64) !vmm.Vcpu {
        var v = try m.b.createVcpu();
        errdefer v.destroy();
        try v.setAddressSpace(m.as);
        var u: vmm.arm64.Ureg = .{ .pc = code_va, .sp = data_va + page };
        u.r[0] = data_va;
        for (regs, 1..) |r, i| u.r[i] = r;
        v.setUreg(&.{ .arm64 = u });
        return v;
    }

    fn word(m: *M, off: usize) *u64 {
        return @ptrCast(@alignCast(m.data[off..][0..8]));
    }
};

fn uregOf(v: *vmm.Vcpu) vmm.arm64.Ureg {
    var u: vmm.Ureg = undefined;
    v.getUreg(&u);
    return u.arm64;
}

fn setPc(v: *vmm.Vcpu, pc: u64, regs: []const u64) void {
    var u = uregOf(v);
    u.pc = pc;
    for (regs, 1..) |r, i| u.r[i] = r;
    v.setUreg(&.{ .arm64 = u });
}

// ---------------------------------------------------------------- encodings

const svc: u32 = 0xd4000001;
const nop: u32 = 0xd503201f;
const isb: u32 = 0xd5033fdf;

fn movz(rd: u32, imm: u32) u32 {
    return 0xd2800000 | imm << 5 | rd;
}
fn movk16(rd: u32, imm: u32) u32 {
    return 0xf2a00000 | imm << 5 | rd;
}
fn ldr(rt: u32, rn: u32, off: u32) u32 {
    return 0xf9400000 | (off / 8) << 10 | rn << 5 | rt;
}
fn str(rt: u32, rn: u32, off: u32) u32 {
    return 0xf9000000 | (off / 8) << 10 | rn << 5 | rt;
}
fn strw(rt: u32, rn: u32) u32 {
    return 0xb9000000 | rn << 5 | rt;
}
fn strd(rt: u32, rn: u32, off: u32) u32 {
    return 0xfd000000 | (off / 8) << 10 | rn << 5 | rt;
}
fn addi(rd: u32, rn: u32, imm: u32) u32 {
    return 0x91000000 | imm << 10 | rn << 5 | rd;
}
fn subsi(rd: u32, rn: u32, imm: u32) u32 {
    return 0xf1000000 | imm << 10 | rn << 5 | rd;
}
fn adr(rd: u32, by: u32) u32 {
    return 0x10000000 | (by & 3) << 29 | (by >> 2) << 5 | rd;
}
fn br(by: i32) u32 {
    return 0x14000000 | (@as(u32, @bitCast(by)) & 0x3ffffff);
}
fn bne(by: i32) u32 {
    return 0x54000001 | (@as(u32, @bitCast(by)) & 0x7ffff) << 5;
}
fn cbnzw(rt: u32, by: i32) u32 {
    return 0x35000000 | (@as(u32, @bitCast(by)) & 0x7ffff) << 5 | rt;
}
fn ldxr(rt: u32, rn: u32) u32 {
    return 0xc85f7c00 | rn << 5 | rt;
}
fn stxr(rs: u32, rt: u32, rn: u32) u32 {
    return 0xc8007c00 | rs << 16 | rn << 5 | rt;
}
fn ldadd(rs: u32, rt: u32, rn: u32) u32 {
    return 0xf8200000 | rs << 16 | rn << 5 | rt;
}
fn fmovdx(rd: u32, rn: u32) u32 {
    return 0x9e670000 | rn << 5 | rd;
}
fn fp3(base: u32, rd: u32, rn: u32, rm: u32) u32 {
    return base | rm << 16 | rn << 5 | rd;
}
const fadd: u32 = 0x1e602800;
const fsub: u32 = 0x1e603800;
const fmul: u32 = 0x1e600800;
const fdiv: u32 = 0x1e601800;
fn fsqrt(rd: u32, rn: u32) u32 {
    return 0x1e61c000 | rn << 5 | rd;
}
fn fmadd(rd: u32, rn: u32, rm: u32, ra: u32) u32 {
    return 0x1f400000 | rm << 16 | ra << 10 | rn << 5 | rd;
}
fn mrsFpsr(rt: u32) u32 {
    return 0xd53b4420 | rt;
}
fn mrsCntvct(rt: u32) u32 {
    return 0xd53be040 | rt;
}

fn expectFault(e: vmm.Exit, addr: u64) !void {
    switch (e) {
        .fault => |f| try testing.expectEqual(addr, f.addr),
        else => {
            std.debug.print("exit {any}, want a fault at {x}\n", .{ e, addr });
            return error.WrongExit;
        },
    }
}

// ---------------------------------------------------------------- cases

test "[a64-jit] a store to a page of compiled code takes effect at the next instruction" {
    // x1 is an instruction, stored over `movz x2, #1` and then run: each
    // run's region was compiled with the last run's word there.
    const prog = [_]u32{
        adr(3, 16), // 0x00: x3 = 0x10010
        strw(1, 3), // 0x04
        isb, // 0x08
        nop, // 0x0c
        movz(2, 1), // 0x10: overwritten
        svc,
    };
    for (std.enums.values(Tier)) |t| {
        var m = try M.init(t, &prog, .{}) orelse return error.SkipZigTest;
        defer m.deinit();
        errdefer std.debug.print("on {t}\n", .{t});
        var v = try m.vcpu(&.{movz(2, 2)});
        defer v.destroy();
        for (2..6) |n| {
            setPc(&v, code_va, &.{movz(2, @intCast(n))});
            try testing.expectEqual(vmm.Exit.syscall, try v.run());
            try testing.expectEqual(@as(u64, n), uregOf(&v).r[2]);
        }
    }
}

test "[a64-jit] a fault in a compiled region reports the exact PC and registers" {
    const prog = [_]u32{
        movz(1, 5), // 0x00
        addi(2, 1, 1), // 0x04
        ldr(3, 4, 0), // 0x08: x4 is unmapped
        addi(1, 1, 100),
        svc,
    };
    for (std.enums.values(Tier)) |t| {
        var m = try M.init(t, &prog, .{}) orelse return error.SkipZigTest;
        defer m.deinit();
        var v = try m.vcpu(&.{ 0, 0, 77, bad_va });
        defer v.destroy();
        // Twice: the second runs the region compiled by the first.
        for (0..2) |_| {
            setPc(&v, code_va, &.{ 0, 0, 77, bad_va });
            try expectFault(try v.run(), bad_va);
            const u = uregOf(&v);
            try testing.expectEqual(code_va + 8, u.pc);
            try testing.expectEqual(@as(u64, 5), u.r[1]);
            try testing.expectEqual(@as(u64, 6), u.r[2]);
            try testing.expectEqual(@as(u64, 77), u.r[3]);
        }
    }
}

const Runner = struct {
    v: vmm.Vcpu,
    exit: vmm.Exit = .halted,
    interrupts: u32 = 0,
    stop: std.atomic.Value(bool) = .init(false),

    fn main(r: *Runner) void {
        while (true) {
            const e = r.v.run() catch |err| std.debug.panic("run: {t}", .{err});
            if (e == .interrupted) {
                r.interrupts += 1;
                if (r.stop.load(.acquire)) return;
                continue;
            }
            r.exit = e;
            return;
        }
    }
};

test "[a64-jit] a kick stops a compiled loop that makes no system calls" {
    const prog = [_]u32{
        addi(5, 5, 1), // loop
        str(5, 0, 0),
        br(-2),
    };
    for (std.enums.values(Tier)) |t| {
        var m = try M.init(t, &prog, .{}) orelse return error.SkipZigTest;
        defer m.deinit();
        var r: Runner = .{ .v = try m.vcpu(&.{}) };
        defer r.v.destroy();
        r.stop.store(true, .release);
        const th = try std.Thread.spawn(.{}, Runner.main, .{&r});
        while (@atomicLoad(u64, m.word(0), .monotonic) < 100_000) std.atomic.spinLoopHint();
        r.v.kick();
        th.join();
        try testing.expectEqual(@as(u32, 1), r.interrupts);
        // Stopped where the loop was: x5 is what it stored.
        const u = uregOf(&r.v);
        try testing.expect(u.pc >= code_va and u.pc < code_va + 12);
        try testing.expect(u.r[5] >= 100_000);
    }
}

const counter_n = 100_000;

fn counterTest(prog: []const u32) !void {
    for (std.enums.values(Tier)) |t| {
        var m = try M.init(t, prog, .{}) orelse return error.SkipZigTest;
        defer m.deinit();
        var runners: [4]Runner = undefined;
        for (&runners) |*r| r.* = .{ .v = try m.vcpu(&.{}) };
        defer for (&runners) |*r| r.v.destroy();
        var threads: [4]std.Thread = undefined;
        for (&threads, &runners) |*th, *r| th.* = try std.Thread.spawn(.{}, Runner.main, .{r});
        for (threads) |th| th.join();
        for (runners) |r| try testing.expectEqual(vmm.Exit.syscall, r.exit);
        try testing.expectEqual(@as(u64, 4 * counter_n), m.word(0).*);
    }
}

test "[a64-jit] four LDXR/STXR threads lose no increments" {
    try counterTest(&.{
        movz(5, counter_n & 0xffff),
        movk16(5, counter_n >> 16),
        ldxr(1, 0), // loop
        addi(1, 1, 1),
        stxr(2, 1, 0),
        cbnzw(2, -3),
        subsi(5, 5, 1),
        bne(-5),
        svc,
    });
}

test "[a64-jit] four LDADD threads lose no increments" {
    try counterTest(&.{
        movz(1, 1),
        movz(5, counter_n & 0xffff),
        movk16(5, counter_n >> 16),
        ldadd(1, 2, 0), // loop
        subsi(5, 5, 1),
        bne(-2),
        svc,
    });
}

test "[a64-jit] unmapping a page another vCPU has cached faults its next access" {
    // Each vCPU counts in its own word, forever.
    const prog = [_]u32{
        ldr(1, 0, 0), // loop
        addi(1, 1, 1),
        str(1, 0, 0),
        br(-3),
    };
    for (std.enums.values(Tier)) |t| {
        var m = try M.init(t, &prog, .{}) orelse return error.SkipZigTest;
        defer m.deinit();
        var runners: [4]Runner = undefined;
        for (&runners, 0..) |*r, i| {
            r.* = .{ .v = try m.vcpu(&.{}) };
            var u = uregOf(&r.v);
            u.r[0] = data_va + 8 * i;
            r.v.setUreg(&.{ .arm64 = u });
        }
        defer for (&runners) |*r| r.v.destroy();
        var threads: [4]std.Thread = undefined;
        for (&threads, &runners) |*th, *r| th.* = try std.Thread.spawn(.{}, Runner.main, .{r});
        for (0..4) |i| while (@atomicLoad(u64, m.word(8 * i), .monotonic) < 1000) std.atomic.spinLoopHint();
        m.as.unmap(data_va);
        m.as.shootdown();
        var after: [4]u64 = undefined;
        for (0..4) |i| after[i] = @atomicLoad(u64, m.word(8 * i), .monotonic);
        for (threads) |th| th.join();
        for (runners, 0..) |r, i| {
            try expectFault(r.exit, data_va + 8 * i);
            try testing.expectEqual(after[i], m.word(8 * i).*);
        }
    }
}

test "[a64-jit] a full code cache flushes while other vCPUs run" {
    // Four vCPUs count; a fifth runs 1000 regions over and over, through a
    // cache too small for them, so it fills and flushes again and again.
    var prog: [2 * page / 4]u32 = undefined;
    prog[0] = ldr(1, 0, 0); // counters: loop
    prog[1] = addi(1, 1, 1);
    prog[2] = str(1, 0, 0);
    prog[3] = br(-3);
    // The fifth, from 0x10010: x6 rounds of add, b .+4 pairs.
    const start = 4;
    const pairs = (prog.len - start - 4) / 2;
    for (0..pairs) |i| {
        prog[start + 2 * i] = addi(7, 7, 1);
        prog[start + 2 * i + 1] = br(1);
    }
    const end = start + 2 * pairs;
    prog[end] = subsi(6, 6, 1);
    prog[end + 1] = bne(-@as(i32, @intCast(end + 1 - start)));
    prog[end + 2] = svc;
    prog[end + 3] = svc;
    const rounds = 20;
    for (std.enums.values(Tier)) |t| {
        var m = try M.init(t, &prog, .{ .cache = "0x10000" }) orelse return error.SkipZigTest;
        defer m.deinit();
        var runners: [4]Runner = undefined;
        for (&runners, 0..) |*r, i| {
            r.* = .{ .v = try m.vcpu(&.{}) };
            var u = uregOf(&r.v);
            u.r[0] = data_va + 8 * i;
            r.v.setUreg(&.{ .arm64 = u });
        }
        defer for (&runners) |*r| r.v.destroy();
        var threads: [4]std.Thread = undefined;
        for (&threads, &runners) |*th, *r| th.* = try std.Thread.spawn(.{}, Runner.main, .{r});
        for (0..4) |i| while (@atomicLoad(u64, m.word(8 * i), .monotonic) < 100) std.atomic.spinLoopHint();
        var v = try m.vcpu(&.{ 0, 0, 0, 0, 0, rounds, 0 });
        defer v.destroy();
        setPc(&v, code_va + 4 * start, &.{ 0, 0, 0, 0, 0, rounds, 0 });
        while (true) {
            const e = try v.run();
            if (e == .interrupted) continue;
            try testing.expectEqual(vmm.Exit.syscall, e);
            break;
        }
        try testing.expectEqual(@as(u64, rounds * pairs), uregOf(&v).r[7]);
        // Everyone is still counting.
        var before: [4]u64 = undefined;
        for (0..4) |i| before[i] = @atomicLoad(u64, m.word(8 * i), .monotonic);
        for (0..4) |i| while (@atomicLoad(u64, m.word(8 * i), .monotonic) == before[i]) std.atomic.spinLoopHint();
        for (&runners) |*r| {
            r.stop.store(true, .release);
            r.v.kick();
        }
        for (threads) |th| th.join();
    }
}

test "[a64-jit] FP results and FPSR are the same bits on T0 and T1" {
    const prog = [_]u32{
        fmovdx(0, 1),
        fmovdx(1, 2),
        fp3(fadd, 2, 0, 1),
        fp3(fsub, 3, 0, 1),
        fp3(fmul, 4, 0, 1),
        fp3(fdiv, 5, 0, 1),
        fsqrt(6, 0),
        fmadd(7, 0, 1, 2),
        strd(2, 0, 0),
        strd(3, 0, 8),
        strd(4, 0, 16),
        strd(5, 0, 24),
        strd(6, 0, 32),
        strd(7, 0, 40),
        mrsFpsr(8),
        str(8, 0, 48),
        svc,
    };
    const inputs = [_][2]f64{
        .{ 1.0 / 3.0, std.math.pi },
        .{ 2.0, 3.0 },
        .{ 1e308, 1e308 },
        .{ 5e-324, 0.5 },
        .{ -0.0, 0.0 },
        .{ 1.0, 0.0 },
        .{ -1.0, 3.0 },
        .{ std.math.nan(f64), 1.0 },
        .{ 0x1.fffffffffffffp-1022, 0x1p-52 },
    };
    var out: [2][inputs.len][7]u64 = undefined;
    for (std.enums.values(Tier), 0..) |t, ti| {
        var m = try M.init(t, &prog, .{}) orelse return error.SkipZigTest;
        defer m.deinit();
        var v = try m.vcpu(&.{});
        defer v.destroy();
        for (inputs, 0..) |in, k| {
            setPc(&v, code_va, &.{ @bitCast(in[0]), @bitCast(in[1]) });
            // FPSR's sticky bits start clear each time.
            var x: vmm.Extra = .{ .arm64 = .{} };
            try v.setExtra(&x);
            try testing.expectEqual(vmm.Exit.syscall, try v.run());
            for (0..7) |j| out[ti][k][j] = m.word(8 * j).*;
        }
    }
    for (inputs, 0..) |in, k| {
        const a = in[0];
        const c = in[1];
        const want = [_]f64{ a + c, a - c, a * c, a / c, @sqrt(a), @mulAdd(f64, a, c, a + c) };
        for (want, 0..) |w, j| {
            if (std.math.isNan(w)) continue;
            try testing.expectEqual(@as(u64, @bitCast(w)), out[0][k][j]);
        }
        if (!std.mem.eql(u64, &out[0][k], &out[1][k])) {
            std.debug.print("inputs {any}: T0 {any}, T1 {any}\n", .{ in, out[0][k], out[1][k] });
            return error.TiersDiffer;
        }
    }
}

test "[a64-jit] deterministic mode counts the same instructions on T0 and T1" {
    // CNTVCT_EL0 is instructions retired: read after a loop, it's the
    // count so far, which must not depend on the tier.
    const prog = [_]u32{
        movz(5, 1000),
        addi(6, 6, 3), // loop
        str(6, 0, 0),
        subsi(5, 5, 1),
        bne(-3),
        mrsCntvct(9),
        svc,
    };
    var got: [2]u64 = undefined;
    for (std.enums.values(Tier), 0..) |t, ti| {
        var m = try M.init(t, &prog, .{ .deterministic = true }) orelse return error.SkipZigTest;
        defer m.deinit();
        var v = try m.vcpu(&.{});
        defer v.destroy();
        try testing.expectEqual(vmm.Exit.syscall, try v.run());
        got[ti] = uregOf(&v).r[9];
    }
    try testing.expectEqual(got[0], got[1]);
    // movz and 1000 rounds of four, before the MRS.
    try testing.expectEqual(@as(u64, 1 + 4 * 1000), got[0]);
}
