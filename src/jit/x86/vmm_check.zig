//! h86 in check mode (-Djit-check): vmm/h86.zig's run loop lifts each
//! region and runs it through `check.Checker` against T0, as
//! src/jit/check/vmm.zig does for ha64, so
//!
//!     zig build integration -Demu=zig -Djit-check -Darch=386
//!
//! checks every region of every 386 program. Slow, and one region at a
//! time across vCPUs (a lock), since another vCPU's stores would race the
//! shadows.

const std = @import("std");
const check = @import("../check.zig");
const check_vmm = @import("../check/vmm.zig");
const x86 = @import("../check/x86.zig");
const ir = @import("../ir.zig");
const ctx_mod = @import("../ctx.zig");
const mem = @import("../../interp/mem.zig");
const cpu_mod = @import("../../interp/x86/cpu.zig");
const exec = @import("../../interp/x86/exec.zig");
const lift = @import("lift.zig");

const Ctx = ctx_mod.Ctx;
const Exit = ctx_mod.Exit;
const Cpu = cpu_mod.Cpu;

var lock: std.atomic.Mutex = .unlocked;
/// Instructions a region may run before it comes back to look for kicks.
const slice = 1 << 16;

/// Per-vCPU check state, kept by h86's Cpu.
pub const State = struct {
    checker: ?check.Checker = null,
    view: ?*mem.View = null,

    pub fn deinit(s: *State) void {
        if (s.checker) |*c| c.deinit();
        s.checker = null;
    }
};

/// h86's run loop in check mode: regions until something leaves. The
/// result is what `exec.run` would have returned. `m` is T0's memory
/// (anything with `translate`), for an instruction no region can hold.
pub fn run(s: *State, cpu: *Cpu, ctx: *Ctx, m: anytype) cpu_mod.Exit {
    const gpa = std.heap.smp_allocator;
    const v: *mem.View = @ptrFromInt(@as(usize, @intCast(ctx.space)));
    if (s.view != v) {
        s.deinit();
        s.view = v;
    }
    if (s.checker == null) s.checker = check.Checker.init(gpa, &x86.guest, check_vmm.viewBacking(v)) catch @panic("jit check: out of memory");
    const ck = &s.checker.?;
    while (true) {
        if (@atomicLoad(u32, &ctx.exit_request, .monotonic) != 0) return .stopped;
        var reg: ir.Region = .{ .entry_pc = cpu.eip };
        defer reg.deinit(gpa);
        var b = ir.Builder.init(gpa, &reg);
        lift.frontend.lift(&b, v.source(), cpu.eip, .{}) catch |e| std.debug.panic("jit check: lifting at {x}: {t}", .{ cpu.eip, e });
        if (ir.verify(&reg)) |err| std.debug.panic("jit check: region at {x} doesn't verify: {s} at %{d}", .{ cpu.eip, err.msg, err.inst });

        var real = ctx.*;
        real.cpu = @intFromPtr(cpu);
        real.budget = slice;
        while (!lock.tryLock()) std.atomic.spinLoopHint();
        const e = ck.run(.{ .ir_eval = &reg }, &real, .{}) catch |err| {
            lock.unlock();
            std.debug.panic("jit check: {t}", .{err});
        };
        lock.unlock();
        if (v.code) |code| invalidateWritten(code, &ck.r.shadow[check.Run.t1]);
        ctx.retired = real.retired;
        switch (e) {
            .chain, .indirect => {
                if (real.exit_pc == cpu.eip and ck.r.out[check.Run.t1].retired == 0) {
                    // Nothing lifted here (code it can't read): one
                    // instruction on T0 itself, which takes the fault.
                    const before = cpu.retired;
                    const x = exec.run(cpu, m, .{ .budget = 1 });
                    ctx.retired +%= cpu.retired - before;
                    if (x == .stopped and @atomicLoad(u32, &ctx.exit_request, .monotonic) == 0) continue;
                    return x;
                }
                cpu.eip = @truncate(real.exit_pc);
                continue;
            },
            .interrupted => {
                cpu.eip = @truncate(real.exit_pc);
                if (@atomicLoad(u32, &ctx.exit_request, .monotonic) == 0) continue;
                return .stopped;
            },
            .svc => return .{ .syscall = 0x80 },
            // Left at the instruction (lift.exitFor): T0 runs it again on
            // the real state and raises it with all its detail.
            .brk, .fault, .undef => {
                const before = cpu.retired;
                const x = exec.run(cpu, m, .{ .budget = 1 });
                ctx.retired +%= cpu.retired - before;
                if (x == .stopped) std.debug.panic("jit check: {t} at {x}, but T0 ran it", .{ e, cpu.eip });
                return x;
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
