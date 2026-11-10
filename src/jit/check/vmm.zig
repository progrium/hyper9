//! Check mode in the vmm backend (-Djit-check): instead of running T0 or
//! compiled code, a Guest's T1 loop lifts each region and runs it through
//! `check.Checker`, which runs the region and T0 from the same state on
//! shadows, panics if they differ, and commits the agreed result. So
//!
//!     zig build integration -Demu=zig -Djit-check
//!
//! runs the integration suite with every region of every guest program
//! checked against T0. Each region is optimized (opt.zig) as dispatch.zig
//! does; with the T1 tier on (H9_EMU_TIER=t1) it runs as this host's
//! generated code, the tier's own, and otherwise in ir_eval. It's slow,
//! and single-threaded: one lock is held across each region, since another
//! vCPU's stores would race the shadows.
//!
//! `run` stands in for dispatch.run, with its results: ha64's and h86's
//! T1 loops (src/vmm/ha64.zig, h86.zig) call it in check mode and hand
//! `.t0` to T0 as they do for compiled code. Every exception goes that
//! way: the checked region leaves the Cpu exact at the instruction, and T0
//! raises it again with its architectural detail.

const std = @import("std");
const check = @import("../check.zig");
const ir = @import("../ir.zig");
const opt = @import("../opt.zig");
const ctx_mod = @import("../ctx.zig");
const dispatch = @import("../dispatch.zig");
const mem = @import("../../interp/mem.zig");
const Native = @import("../emit/native.zig").Native;

const Ctx = ctx_mod.Ctx;
const Exit = ctx_mod.Exit;

pub const a64_guest = &check.a64.guest;
pub const x86_guest = &check.x86.guest;

/// A Backing over the vmm's View: the address space a vCPU runs in.
pub fn viewBacking(v: *mem.View) check.Backing {
    return .{ .ctx = v, .page = viewPage };
}

fn viewPage(p: *anyopaque, vp: u64) ?check.Backing.Page {
    const v: *const mem.View = @ptrCast(@alignCast(p));
    const va = vp << mem.page_shift;
    const m = v.find(va) orelse return null;
    return .{ .host = @ptrFromInt(m.host + @as(usize, @intCast(va - m.va))), .read = m.perms.read, .write = m.perms.write, .exec = m.perms.exec };
}

var lock: std.atomic.Mutex = .unlocked;
/// Instructions a region may run before it comes back to look for kicks.
const slice = 1 << 16;

/// Per-vCPU check state, kept by the Guest's Cpu.
pub const State = struct {
    checker: ?check.Checker = null,
    view: ?*mem.View = null,
    native: ?Native = null,
    native_tried: bool = false,

    pub fn deinit(s: *State) void {
        if (s.checker) |*c| c.deinit();
        s.checker = null;
        if (s.native) |*n| n.deinit();
        s.native = null;
        s.native_tried = false;
    }
};

/// Checked regions from the PC (in `cpu`, the front end's Cpu) until one
/// leaves for the Guest, as dispatch.run would. With `native`, each region
/// runs as generated code where this host's emitter takes it.
pub fn run(s: *State, g: *const check.Guest, cpu: *anyopaque, ctx: *Ctx, native: bool) dispatch.Result {
    const gpa = std.heap.smp_allocator;
    const v: *mem.View = @ptrFromInt(@as(usize, @intCast(ctx.space)));
    if (s.view != v) {
        if (s.checker) |*c| c.deinit();
        s.checker = null;
        s.view = v;
    }
    if (s.checker == null) s.checker = check.Checker.init(gpa, g, viewBacking(v)) catch @panic("jit check: out of memory");
    if (native and !s.native_tried) {
        s.native_tried = true;
        s.native = Native.init() catch null;
    }
    const ck = &s.checker.?;
    const bytes: [*]u8 = @ptrCast(cpu);
    const pc_align: u64 = if (g.pc_bytes == 8) 4 else 1;
    while (true) {
        if (@atomicLoad(u32, &ctx.exit_request, .monotonic) != 0 or ctx.budget <= 0) return .interrupted;
        const pc = getPc(g, bytes);
        if (pc & (pc_align - 1) != 0) return .t0;
        var reg: ir.Region = .{ .entry_pc = pc };
        defer reg.deinit(gpa);
        var b = ir.Builder.init(gpa, &reg);
        // Nothing to lift (code it can't read, say): T0 takes the fault.
        g.frontend.lift(&b, v.source(), pc, .{}) catch return .t0;
        if (ir.verify(&reg)) |err| std.debug.panic("jit check: region at {x} doesn't verify: {s} at %{d}", .{ pc, err.msg, err.inst });
        opt.run(gpa, &reg) catch @panic("jit check: out of memory");
        if (ir.verify(&reg)) |err| std.debug.panic("jit check: region at {x} doesn't verify after opt: {s} at %{d}", .{ pc, err.msg, err.inst });
        const tier: check.Tier1 = blk: {
            if (s.native) |*n| if (n.compile(gpa, &reg) catch null) |f| break :blk .{ .entry = f };
            break :blk .{ .ir_eval = &reg };
        };

        var real = ctx.*;
        real.cpu = @intFromPtr(cpu);
        // The check's own Ctx doesn't see kicks: a slice of budget brings
        // a guest loop back here to look for them.
        real.budget = @min(ctx.budget, slice);
        while (!lock.tryLock()) std.atomic.spinLoopHint();
        const e = ck.run(tier, &real, .{}) catch |err| {
            lock.unlock();
            std.debug.panic("jit check: {t}", .{err});
        };
        lock.unlock();
        if (v.code) |code| invalidateWritten(code, &ck.r.shadow[check.Run.t1]);
        const n = real.retired -% ctx.retired;
        ctx.retired = real.retired;
        if (ctx.budget != std.math.maxInt(i64)) ctx.budget -%= @bitCast(n);
        setPc(g, bytes, real.exit_pc);
        switch (e) {
            .chain, .indirect, .interrupted => if (real.exit_pc == pc and n == 0) return .t0,
            .svc => return .svc,
            // The Cpu is at the instruction: T0 raises it again.
            .fault, .undef, .brk => return .t0,
            else => std.debug.panic("jit check: region left with {t}", .{e}),
        }
    }
}

fn getPc(g: *const check.Guest, b: [*]u8) u64 {
    return if (g.pc_bytes == 4) std.mem.readInt(u32, b[g.pc_off..][0..4], .little) else std.mem.readInt(u64, b[g.pc_off..][0..8], .little);
}

fn setPc(g: *const check.Guest, b: [*]u8, v: u64) void {
    if (g.pc_bytes == 4) std.mem.writeInt(u32, b[g.pc_off..][0..4], @truncate(v), .little) else std.mem.writeInt(u64, b[g.pc_off..][0..8], v, .little);
}

/// Committed stores bypass the slow path, so a page of code they changed
/// has to be invalidated here.
fn invalidateWritten(code: *mem.CodePages, s: *const check.Shadow) void {
    for (s.pages.values()) |c| {
        if (!c.write) continue;
        const host = @intFromPtr(c.orig);
        if (code.pageOf(host)) |pg| if (code.isCode(pg)) code.invalidate(pg);
    }
}
