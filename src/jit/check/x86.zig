//! h86's `check.Guest`: a lifted 386 region against T0
//! (src/interp/x86/exec.zig); and hx64's, `guest64`, the same in long
//! mode (below).
//!
//! T0 reads memory through its `translate`, which `ShadowMem` serves from
//! the check's shadow, so only the pages a region touches are copied. The
//! lifter's `call.interp` runs T0 through a `lift.Mem` over the same
//! shadow, which `bind` puts in ctx.frontend.

const std = @import("std");
const check = @import("../check.zig");
const ctx_mod = @import("../ctx.zig");
const ir = @import("../ir.zig");
const fe = @import("../frontend.zig");
const mem = @import("../../interp/mem.zig");
pub const t0 = @import("../../interp/x86/exec.zig");
pub const decode = @import("../../interp/x86/decode.zig");
const cpu_mod = @import("../../interp/x86/cpu.zig");

const Ctx = ctx_mod.Ctx;
const Exit = ctx_mod.Exit;
pub const Cpu = t0.Cpu;

pub const helpers = @import("../x86/helpers.zig");
const lift = @import("../x86/lift.zig");
pub const frontend = lift.frontend;

pub const guest: check.Guest = .{
    .frontend = frontend,
    .cpu_size = @sizeOf(Cpu),
    .pc_off = @offsetOf(Cpu, "eip"),
    .pc_bytes = 4,
    .step = step,
    .diff = diff,
    .bind = bind,
    .unbind = unbind,
};

/// `call.interp`'s memory over the shadow (ctx.frontend).
const Bound = struct { m: lift.Mem };

fn bind(gpa: std.mem.Allocator, c: *Ctx, s: *check.Shadow) anyerror!void {
    const b = try gpa.create(Bound);
    b.* = .{ .m = .{ .ctx = s, .translateFn = shadowTranslate } };
    c.frontend = @intFromPtr(&b.m);
    c.helpers = helpers.tableAddr();
}

fn unbind(gpa: std.mem.Allocator, c: *Ctx) void {
    const m: *lift.Mem = @ptrFromInt(@as(usize, @intCast(c.frontend)));
    gpa.destroy(@as(*Bound, @fieldParentPtr("m", m)));
}

fn shadowTranslate(p: *anyopaque, va: u32, access: cpu_mod.Access) ?[*]u8 {
    return (ShadowMem{ .s = @ptrCast(@alignCast(p)) }).translate(va, access);
}

/// T0's memory over a check.Shadow (ctx.space), or any `translate`.
pub const ShadowMem = struct {
    s: *check.Shadow,

    pub fn translate(m: ShadowMem, va: u32, access: cpu_mod.Access) ?[*]u8 {
        const c = m.s.get(va >> mem.page_shift) orelse return null;
        const ok = switch (access) {
            .read => c.read,
            .write => c.write,
            .exec => c.exec,
        };
        if (!ok) return null;
        return @as([*]u8, &c.data) + (va & (mem.page_size - 1));
    }
};

/// Converts T0's exit to ctx's, as `call.interp` does (check.Guest.step's
/// conventions).
pub fn exitOf(c: *Ctx, cpu: *Cpu, e: cpu_mod.Exit, pc: u32) u32 {
    return lift.exitFor(c, cpu, e, pc);
}

/// One T0 instruction. ctx.space is the check's Shadow.
pub fn step(c: *Ctx) u32 {
    const cpu = c.cpuPtr(Cpu);
    const s: *check.Shadow = @ptrFromInt(@as(usize, @intCast(c.space)));
    const pc = cpu.eip;
    const e = t0.step(cpu, ShadowMem{ .s = s }) orelse return 0;
    return exitOf(c, cpu, e, pc);
}

fn diff(pa: *const anyopaque, pb: *const anyopaque, w: *std.Io.Writer) bool {
    const a: *const Cpu = @ptrCast(@alignCast(pa));
    const b: *const Cpu = @ptrCast(@alignCast(pb));
    var bad = false;
    const names = [8][]const u8{ "eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi" };
    for (a.r, b.r, names) |x, y, n| if (x != y) {
        w.print("{s}: T1 {x}, T0 {x}\n", .{ n, x, y }) catch {};
        bad = true;
    };
    if (a.eip != b.eip) {
        w.print("eip: T1 {x}, T0 {x}\n", .{ a.eip, b.eip }) catch {};
        bad = true;
    }
    if (a.fl.get() != b.fl.get()) {
        w.print("eflags: T1 {x}, T0 {x}\n", .{ a.fl.get(), b.fl.get() }) catch {};
        bad = true;
    }
    for (a.seg, b.seg, a.seg_base, b.seg_base, 0..) |x, y, bx, by, i| if (x != y or bx != by) {
        w.print("seg {d}: T1 {x} base {x}, T0 {x} base {x}\n", .{ i, x, bx, y, by }) catch {};
        bad = true;
    };
    for (a.xmm, b.xmm, 0..) |x, y, i| if (x != y) {
        w.print("xmm{d}: T1 {x:0>32}, T0 {x:0>32}\n", .{ i, x, y }) catch {};
        bad = true;
    };
    if (a.mxcsr != b.mxcsr) {
        w.print("mxcsr: T1 {x}, T0 {x}\n", .{ a.mxcsr, b.mxcsr }) catch {};
        bad = true;
    }
    if (!std.meta.eql(a.fpu, b.fpu)) {
        const f = a.fpu;
        const g = b.fpu;
        w.print("x87 state differs: T1 top {d} tag {x} sw {x} cw {x} fop {x} fip {x} fdp {x}; T0 top {d} tag {x} sw {x} cw {x} fop {x} fip {x} fdp {x}\n", .{ f.top, f.tag, f.sw, f.cw, f.fop, f.fip, f.fdp, g.top, g.tag, g.sw, g.cw, g.fop, g.fip, g.fdp }) catch {};
        for (f.st, g.st, 0..) |x, y, i| if (x.signif != y.signif or x.sign_exp != y.sign_exp) {
            w.print("  st[{d}]: T1 {x:0>4} {x:0>16}, T0 {x:0>4} {x:0>16}\n", .{ i, x.sign_exp, x.signif, y.sign_exp, y.signif }) catch {};
        };
        bad = true;
    }
    return bad;
}

// ---------------------------------------------------------------- long mode

/// hx64's register file.
pub const Cpu64 = cpu_mod.Cpu64;

/// hx64's `check.Guest`: a long-mode region against T0's `stepIn(.long)`.
/// `call.interp` reaches memory through `lift.Mem64` when the lifter
/// defines one (workstream F), with lift.Mem's shape and 64-bit
/// addresses; until then long mode lifts nothing, and the check runs T0.
pub const guest64: check.Guest = .{
    .frontend = lift.frontendFor(.long),
    .cpu_size = @sizeOf(Cpu64),
    .pc_off = @offsetOf(Cpu64, "rip"),
    .pc_bytes = 8,
    .step = step64,
    .diff = diff64,
    .bind = bind64,
    .unbind = unbind64,
};

const has_mem64 = @hasDecl(lift, "Mem64");
const Bound64 = if (has_mem64) struct { m: lift.Mem64 } else struct {};

fn bind64(gpa: std.mem.Allocator, c: *Ctx, s: *check.Shadow) anyerror!void {
    c.helpers = helpers.tableAddr();
    if (!has_mem64) return;
    const b = try gpa.create(Bound64);
    b.* = .{ .m = .{ .ctx = s, .translateFn = shadowTranslate64 } };
    c.frontend = @intFromPtr(&b.m);
}

fn unbind64(gpa: std.mem.Allocator, c: *Ctx) void {
    if (!has_mem64) return;
    const m: *lift.Mem64 = @ptrFromInt(@as(usize, @intCast(c.frontend)));
    gpa.destroy(@as(*Bound64, @fieldParentPtr("m", m)));
}

fn shadowTranslate64(p: *anyopaque, va: u64, access: cpu_mod.Access) ?[*]u8 {
    return (ShadowMem64{ .s = @ptrCast(@alignCast(p)) }).translate(va, access);
}

/// T0's long-mode memory over a check.Shadow: 64-bit addresses.
pub const ShadowMem64 = struct {
    s: *check.Shadow,

    pub fn translate(m: ShadowMem64, va: u64, access: cpu_mod.Access) ?[*]u8 {
        const c = m.s.get(va >> mem.page_shift) orelse return null;
        const ok = switch (access) {
            .read => c.read,
            .write => c.write,
            .exec => c.exec,
        };
        if (!ok) return null;
        return @as([*]u8, &c.data) + (va & (mem.page_size - 1));
    }
};

/// Converts T0's long-mode exit to ctx's, as lift.exitFor does h86's: a
/// SYSCALL retires and is `.svc`; INT3 is `.brk` at itself, not retired;
/// a fault and any other exception leave RIP at the instruction, the
/// exception as `exception_kind` in exit_info with its vector above.
pub fn exitOf64(c: *Ctx, cpu: *Cpu64, e: cpu_mod.Exit64, pc: u64) u32 {
    c.exit_pc = cpu.rip;
    switch (e) {
        .syscall => {
            c.retired +%= 1;
            c.budget -%= 1;
            return @intFromEnum(Exit.svc);
        },
        .breakpoint => {
            cpu.rip = pc;
            c.exit_pc = pc;
            return @intFromEnum(Exit.brk);
        },
        .fault => |f| {
            c.exit_pc = pc;
            c.exit_addr = f.addr;
            c.exit_info = @intFromEnum(f.access);
            return @intFromEnum(Exit.fault);
        },
        .exception => |v| {
            if (v == cpu_mod.vec_ud) {
                c.exit_pc = pc;
                return @intFromEnum(Exit.undef);
            }
            cpu.rip = pc;
            c.exit_pc = pc;
            c.exit_addr = 0;
            c.exit_info = (lift.exception_kind << 8) | (@as(u64, v) << 16);
            return @intFromEnum(Exit.fault);
        },
        .stopped => return @intFromEnum(Exit.interrupted),
    }
}

/// One long-mode T0 instruction. ctx.space is the check's Shadow.
pub fn step64(c: *Ctx) u32 {
    const cpu = c.cpuPtr(Cpu64);
    const s: *check.Shadow = @ptrFromInt(@as(usize, @intCast(c.space)));
    const pc = cpu.rip;
    const e = t0.stepIn(.long, cpu, ShadowMem64{ .s = s }) orelse return 0;
    return exitOf64(c, cpu, e, pc);
}

fn diff64(pa: *const anyopaque, pb: *const anyopaque, w: *std.Io.Writer) bool {
    const a: *const Cpu64 = @ptrCast(@alignCast(pa));
    const b: *const Cpu64 = @ptrCast(@alignCast(pb));
    var bad = false;
    const names = [16][]const u8{ "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15" };
    for (a.r, b.r, names) |x, y, n| if (x != y) {
        w.print("{s}: T1 {x}, T0 {x}\n", .{ n, x, y }) catch {};
        bad = true;
    };
    if (a.rip != b.rip) {
        w.print("rip: T1 {x}, T0 {x}\n", .{ a.rip, b.rip }) catch {};
        bad = true;
    }
    if (a.fl.get() != b.fl.get()) {
        w.print("rflags: T1 {x}, T0 {x}\n", .{ a.fl.get(), b.fl.get() }) catch {};
        bad = true;
    }
    if (a.fs_base != b.fs_base or a.gs_base != b.gs_base) {
        w.print("fs/gs base: T1 {x} {x}, T0 {x} {x}\n", .{ a.fs_base, a.gs_base, b.fs_base, b.gs_base }) catch {};
        bad = true;
    }
    for (a.xmm, b.xmm, 0..) |x, y, i| if (x != y) {
        w.print("xmm{d}: T1 {x:0>32}, T0 {x:0>32}\n", .{ i, x, y }) catch {};
        bad = true;
    };
    if (a.mxcsr != b.mxcsr) {
        w.print("mxcsr: T1 {x}, T0 {x}\n", .{ a.mxcsr, b.mxcsr }) catch {};
        bad = true;
    }
    if (!std.meta.eql(a.fpu, b.fpu)) {
        const f = a.fpu;
        const g = b.fpu;
        w.print("x87 state differs: T1 top {d} tag {x} sw {x} cw {x}; T0 top {d} tag {x} sw {x} cw {x}\n", .{ f.top, f.tag, f.sw, f.cw, g.top, g.tag, g.sw, g.cw }) catch {};
        for (f.st, g.st, 0..) |x, y, i| if (x.signif != y.signif or x.sign_exp != y.sign_exp) {
            w.print("  st[{d}]: T1 {x:0>4} {x:0>16}, T0 {x:0>4} {x:0>16}\n", .{ i, x.sign_exp, x.signif, y.sign_exp, y.signif }) catch {};
        };
        bad = true;
    }
    return bad;
}

/// Whether long-mode T0 runs yet (workstreams A and B): a NOP retires.
pub fn longRuns() bool {
    var cpu: Cpu64 = .{ .rip = 0x1000 };
    const M = struct {
        page: [mem.page_size]u8 align(mem.page_size) = @splat(0x90),
        pub fn translate(m: *@This(), va: u64, _: cpu_mod.Access) ?[*]u8 {
            if (va >> mem.page_shift != 1) return null;
            return @as([*]u8, &m.page) + (va & (mem.page_size - 1));
        }
    };
    var m: M = .{};
    return t0.stepIn(.long, &cpu, &m) == null and cpu.rip == 0x1001;
}

test "check/x86: long-mode T0 steps on a shadow" {
    if (!longRuns()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var code: [mem.page_size]u8 align(mem.page_size) = @splat(0);
    var data: [mem.page_size]u8 align(mem.page_size) = @splat(0);
    // mov rax, 0x1122334455667788; mov [rbx], rax; mov r9d, [rip+0x...]: data; syscall
    const prog = [_]u8{
        0x48, 0xb8, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,
        0x48, 0x89, 0x03,
        0x44, 0x8b, 0x0d, 0xed, 0xef, 0x01, 0x00, // r9d = [0x1014 + 0x1efed] = [0x20001]
        0x0f, 0x05,
    };
    @memcpy(code[0..prog.len], &prog);
    const regions = [_]mem.Region{
        .{ .va = 0x1000, .mem = &code, .exec = true },
        .{ .va = 0x20000, .mem = &data, .write = true },
    };
    const map: mem.Map = .{ .regions = &regions };
    var s = check.Shadow.init(gpa, check.mapBacking(&map));
    defer s.deinit();
    var cpu: Cpu64 = .{};
    cpu.rip = 0x1000;
    cpu.r[3] = 0x20000;
    cpu.r[9] = 0xffff_ffff_ffff_ffff;
    var c: Ctx = .{ .cpu = @intFromPtr(&cpu), .space = @intFromPtr(&s) };
    try std.testing.expectEqual(@as(u32, 0), step64(&c));
    try std.testing.expectEqual(@as(u32, 0), step64(&c));
    try std.testing.expectEqual(@as(u32, 0), step64(&c));
    // A 32-bit load zero-extends.
    try std.testing.expectEqual(@as(u64, 0x4455_6677), cpu.r[9]);
    try std.testing.expectEqual(@intFromEnum(Exit.svc), step64(&c));
    try std.testing.expectEqual(@as(u64, 0x1016), c.exit_pc);
    try std.testing.expectEqual(@as(u8, 0x88), s.view(0x20).?[0]);
    try std.testing.expectEqual(@as(u8, 0), data[0]);
}

test "check/x86: long mode's guest, before T0 runs it, says #UD" {
    var code: [mem.page_size]u8 align(mem.page_size) = @splat(0x90);
    const regions = [_]mem.Region{.{ .va = 0x1000, .mem = &code, .exec = true }};
    const map: mem.Map = .{ .regions = &regions };
    var s = check.Shadow.init(std.testing.allocator, check.mapBacking(&map));
    defer s.deinit();
    var cpu: Cpu64 = .{ .rip = 0x1000 };
    var c: Ctx = .{ .cpu = @intFromPtr(&cpu), .space = @intFromPtr(&s) };
    const e = step64(&c);
    if (longRuns()) {
        try std.testing.expectEqual(@as(u32, 0), e);
        try std.testing.expectEqual(@as(u64, 0x1001), cpu.rip);
    } else {
        try std.testing.expectEqual(@intFromEnum(Exit.undef), e);
        try std.testing.expectEqual(@as(u64, 0x1000), c.exit_pc);
    }
}

test "check/x86: T0 steps on a shadow, and the shadow keeps the backing clean" {
    const gpa = std.testing.allocator;
    var code: [mem.page_size]u8 align(mem.page_size) = @splat(0);
    var data: [mem.page_size]u8 align(mem.page_size) = @splat(0);
    // mov eax, 42; mov [ebx], eax; int $64
    const prog = [_]u8{ 0xb8, 42, 0, 0, 0, 0x89, 0x03, 0xcd, 0x40 };
    @memcpy(code[0..prog.len], &prog);
    const regions = [_]mem.Region{
        .{ .va = 0x1000, .mem = &code, .exec = true },
        .{ .va = 0x20000, .mem = &data, .write = true },
    };
    const map: mem.Map = .{ .regions = &regions };
    var s = check.Shadow.init(gpa, check.mapBacking(&map));
    defer s.deinit();
    var cpu: Cpu = .{};
    cpu.eip = 0x1000;
    cpu.r[3] = 0x20000;
    var c: Ctx = .{ .cpu = @intFromPtr(&cpu), .space = @intFromPtr(&s) };
    try std.testing.expectEqual(@as(u32, 0), step(&c));
    try std.testing.expectEqual(@as(u32, 0), step(&c));
    try std.testing.expectEqual(@intFromEnum(Exit.svc), step(&c));
    try std.testing.expectEqual(@as(u64, 0x1009), c.exit_pc);
    try std.testing.expectEqual(@as(u8, 42), s.view(0x20).?[0]);
    try std.testing.expectEqual(@as(u8, 0), data[0]);
}
