//! h86's `check.Guest`: a lifted 386 region against T0
//! (src/interp/x86/exec.zig).
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
        w.print("x87 state differs\n", .{}) catch {};
        bad = true;
    }
    return bad;
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
