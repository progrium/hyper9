//! h86's `check.Guest`: a lifted 386 region against T0
//! (src/interp/x86/exec.zig).
//!
//! T0 reads memory through its `translate`, which `ShadowMem` serves from
//! the check's shadow, so only the pages a region touches are copied.
//! h86's lifter (E2) doesn't exist yet: `frontend` stands in for it until
//! src/jit/x86/lift.zig does, and its `lift` says so, so the region check
//! for h86 waits on E2 while lockstep (fuzz-x86) runs now.

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

/// Stands in for h86's front end until E2's lifter lands.
pub const frontend: fe.Frontend = .{ .name = "h86", .flags = .eflags, .lift = noLifter, .interp = interp };

fn noLifter(_: *ir.Builder, _: fe.Source, _: u64, _: fe.Limits) fe.LiftError!void {
    return error.Unsupported;
}

pub const guest: check.Guest = .{
    .frontend = frontend,
    .cpu_size = @sizeOf(Cpu),
    .pc_off = @offsetOf(Cpu, "eip"),
    .pc_bytes = 4,
    .step = step,
    .diff = diff,
};

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

/// Converts T0's exit to ctx's, with the conventions of check.Guest.step.
pub fn exitOf(c: *Ctx, cpu: *const Cpu, e: cpu_mod.Exit, pc: u32) u32 {
    switch (e) {
        .syscall => {
            c.exit_pc = cpu.eip;
            return @intFromEnum(Exit.svc);
        },
        .breakpoint => {
            c.exit_pc = cpu.eip;
            return @intFromEnum(Exit.brk);
        },
        .stopped => {
            c.exit_pc = pc;
            return @intFromEnum(Exit.interrupted);
        },
        .fault => |f| {
            c.exit_pc = pc;
            c.exit_addr = f.addr;
            c.exit_info = @intFromEnum(f.access);
            return @intFromEnum(Exit.fault);
        },
        .exception => |v| {
            c.exit_pc = cpu.eip;
            c.exit_addr = 0;
            // The vector, where a fault's access goes.
            c.exit_info = @as(u64, v) << 8;
            return @intFromEnum(if (v == cpu_mod.vec_ud) Exit.undef else Exit.fault);
        },
    }
}

/// One T0 instruction. ctx.space is the check's Shadow.
pub fn step(c: *Ctx) u32 {
    const cpu = c.cpuPtr(Cpu);
    const s: *check.Shadow = @ptrFromInt(@as(usize, @intCast(c.space)));
    const pc = cpu.eip;
    const e = t0.step(cpu, ShadowMem{ .s = s }) orelse return 0;
    return exitOf(c, cpu, e, pc);
}

/// A stand-in `call.interp` until E2's: runs the instruction at `pc` (the
/// handle is unused), with ctx.space a check Shadow.
pub fn interp(c: *Ctx, _: u64, pc: u64) callconv(.c) u32 {
    c.cpuPtr(Cpu).eip = @truncate(pc);
    return step(c);
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
