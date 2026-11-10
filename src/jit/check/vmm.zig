//! Check mode in the vmm backend (-Djit-check): instead of running T0 or
//! compiled code, a Guest's run loop lifts each region and runs it through
//! `check.Checker`, which runs the region (in ir_eval, or generated code
//! once the runtime hands it over) and T0 from the same state on shadows,
//! panics if they differ, and commits the agreed result. So
//!
//!     zig build integration -Demu=zig -Djit-check
//!
//! runs the integration suite with every region of every guest program
//! checked against T0. It's slow, and single-threaded: one lock is held
//! across each region, since another vCPU's stores would race the shadows.
//!
//! The hook is in ha64's `run` (src/vmm/ha64.zig), which keeps a `State`
//! in its Cpu and has set ctx.frontend to its T0 Machine.

const std = @import("std");
const check = @import("../check.zig");
const a64 = @import("a64.zig");
const ir = @import("../ir.zig");
const ctx_mod = @import("../ctx.zig");
const mem = @import("../../interp/mem.zig");
const t0 = a64.t0;

const Ctx = ctx_mod.Ctx;
const Exit = ctx_mod.Exit;

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

    pub fn deinit(s: *State) void {
        if (s.checker) |*c| c.deinit();
        s.checker = null;
    }
};

/// ha64's run loop in check mode: regions until something leaves. The
/// result is what `t0.run` would have returned.
pub fn runA64(s: *State, cpu: *t0.Cpu, ctx: *Ctx) t0.Exit {
    const gpa = std.heap.smp_allocator;
    const v: *mem.View = @ptrFromInt(@as(usize, @intCast(ctx.space)));
    if (s.view != v) {
        s.deinit();
        s.view = v;
    }
    if (s.checker == null) s.checker = check.Checker.init(gpa, &a64.guest, viewBacking(v)) catch @panic("jit check: out of memory");
    const ck = &s.checker.?;
    while (true) {
        if (@atomicLoad(u32, &ctx.exit_request, .monotonic) != 0) return .interrupted;
        var reg: ir.Region = .{ .entry_pc = cpu.pc };
        defer reg.deinit(gpa);
        var b = ir.Builder.init(gpa, &reg);
        a64.guest.frontend.lift(&b, v.source(), cpu.pc, .{}) catch |e| std.debug.panic("jit check: lifting at {x}: {t}", .{ cpu.pc, e });
        if (ir.verify(&reg)) |err| std.debug.panic("jit check: region at {x} doesn't verify: {s} at %{d}", .{ cpu.pc, err.msg, err.inst });

        var real = ctx.*;
        real.cpu = @intFromPtr(cpu);
        // The check's own Ctx doesn't see kicks: a slice of budget brings
        // a guest loop back here to look for them.
        real.budget = slice;
        while (!lock.tryLock()) std.atomic.spinLoopHint();
        const e = ck.run(.{ .ir_eval = &reg }, &real, .{}) catch |err| {
            lock.unlock();
            std.debug.panic("jit check: {t}", .{err});
        };
        lock.unlock();
        if (v.code) |code| invalidateWritten(code, &ck.r.shadow[check.Run.t1]);
        ctx.retired = real.retired;
        const t0c = &ck.r.ctx[check.Run.t0];
        switch (e) {
            .chain, .indirect => {
                if (real.exit_pc == cpu.pc and ck.r.out[check.Run.t1].retired == 0) {
                    // Nothing to lift here (code it can't read, such as a
                    // page without exec): one instruction on T0 itself,
                    // which takes the fault.
                    const m: *t0.Machine = @ptrFromInt(@as(usize, @intCast(ctx.frontend)));
                    const x = t0.run(m, 1);
                    if (x == .interrupted and @atomicLoad(u32, &ctx.exit_request, .monotonic) == 0) continue;
                    return x;
                }
                cpu.pc = real.exit_pc;
                continue;
            },
            .interrupted => {
                cpu.pc = real.exit_pc;
                if (@atomicLoad(u32, &ctx.exit_request, .monotonic) == 0) continue;
                return .interrupted;
            },
            .svc => return .syscall,
            .brk => return .breakpoint,
            .fault, .undef => {
                const info = t0c.exit_info;
                return .{ .fault = .{
                    .addr = t0c.exit_addr,
                    .access = @enumFromInt(@as(u8, @truncate(info))),
                    .kind = @enumFromInt(@as(u8, @truncate(info >> 8))),
                    .esr = info >> 16,
                } };
            },
            else => std.debug.panic("jit check: region left with {t}", .{e}),
        }
    }
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
