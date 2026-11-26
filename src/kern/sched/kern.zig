//! The scheduler's side in the kernel, for h9's executors
//! (src/executor.zig, design/scheduler.md), as C: h9 is built apart from
//! the kernel's Zig, so it reaches continuations through these calls,
//! and every continuation's state (the executor on a host thread, `up`)
//! stays in one copy of this code.
//!
//! A task is a process the scheduler runs: its continuation, and the
//! hook its unpark calls to queue it. An executor runs tasks' kernel
//! calls on the calling host thread; its first call for a task runs the
//! process from its start (as posix.c's tramp does) to its exit, which
//! ends the continuation. Each call reports how the task left the
//! executor: 0, it returned (the process exited); 1, it parked; 2, it
//! yielded and is runnable; -1, no stack could be had.

const std = @import("std");
const port = @import("../port.zig");
const sync = @import("../sync.zig");
const sched = @import("sched.zig");
const c = port.c;

const Ready = *const fn (ctx: ?*anyopaque) callconv(.c) void;
const Hook = *const fn (exctx: ?*anyopaque, taskctx: ?*anyopaque) callconv(.c) void;

const Task = struct {
    k: sched.Cont = .{ .ready = ready },
    p: *c.Proc,
    readyf: Ready,
    ctx: ?*anyopaque,

    fn ready(k: *sched.Cont) void {
        const t: *Task = @fieldParentPtr("k", k);
        t.readyf(t.ctx);
    }
};

const Exec = struct {
    kx: sync.Kexec,
    hook: ?Hook,

    fn outHook(ex: *sched.Executor, k: *sched.Cont) void {
        const kx: *sync.Kexec = @fieldParentPtr("ex", ex);
        const e: *Exec = @fieldParentPtr("kx", kx);
        const t: *Task = @fieldParentPtr("k", k);
        if (e.hook) |h| h(ex.ctx, t.ctx);
    }
};

const gpa = std.heap.page_allocator;

fn h9_sched_pool_new(size: usize) callconv(.c) ?*sched.Pool {
    const p = gpa.create(sched.Pool) catch return null;
    p.* = .{};
    if (size != 0) p.size = size;
    return p;
}

fn h9_sched_pool_free(p: *sched.Pool) callconv(.c) void {
    p.deinit();
    gpa.destroy(p);
}

/// Stacks mapped and not yet unmapped, for the cases.
fn h9_sched_pool_mapped(p: *sched.Pool) callconv(.c) usize {
    return p.mapped;
}

/// Makes p a process the scheduler runs. ready(ctx) is called, from
/// whatever thread unparks it, each time it's made runnable.
fn h9_sched_task_new(p: *c.Proc, readyf: Ready, ctx: ?*anyopaque) callconv(.c) ?*Task {
    const t = gpa.create(Task) catch return null;
    t.* = .{ .p = p, .readyf = readyf, .ctx = ctx };
    p.cont = &t.k;
    return t;
}

/// Frees a task whose process has exited (its call returned), or that
/// never ran.
fn h9_sched_task_free(t: *Task) callconv(.c) void {
    gpa.destroy(t);
}

fn h9_sched_exec_new(pool: *sched.Pool, ctx: ?*anyopaque, hook: ?Hook) callconv(.c) ?*Exec {
    const e = gpa.create(Exec) catch return null;
    e.* = .{ .kx = .init(pool, null), .hook = hook };
    e.kx.ex.ctx = ctx;
    e.kx.ex.out_hook = Exec.outHook;
    return e;
}

fn h9_sched_exec_free(e: *Exec) callconv(.c) void {
    e.kx.deinit();
    gpa.destroy(e);
}

fn code(o: sched.Outcome) c_int {
    return switch (o) {
        .returned => 0,
        .parked => 1,
        .yielded => 2,
    };
}

/// The process's life, on its continuation: as posix.c's tramp.
fn procmain(v: ?*anyopaque) void {
    const t: *Task = @ptrCast(@alignCast(v.?));
    const p = t.p;
    p.@"fn".?(p.arg);
    c.pexit(@constCast(""), 0);
    unreachable;
}

fn h9_sched_exec_start(e: *Exec, t: *Task) callconv(.c) c_int {
    const o = e.kx.call(t.p, procmain, t) catch return -1;
    return code(o);
}

fn h9_sched_exec_resume(e: *Exec, t: *Task) callconv(.c) c_int {
    const k = &t.k;
    c._setproc(t.p);
    defer c._setproc(e.kx.home);
    return code(e.kx.ex.@"resume"(k));
}

/// The ctx of the executor on this thread, or null.
fn h9_sched_exec_current() callconv(.c) ?*anyopaque {
    const ex = sched.cont.current() orelse return null;
    return ex.ctx;
}

/// The ctx of the task running on this thread, or null.
fn h9_sched_task_current() callconv(.c) ?*anyopaque {
    const k = sched.cont.self() orelse return null;
    const t: *Task = @fieldParentPtr("k", k);
    return t.ctx;
}

/// Parks the calling task until h9_sched_unpark; an unpark that came
/// first is kept, and it returns at once.
fn h9_sched_park() callconv(.c) void {
    sync.park();
}

fn h9_sched_unpark(t: *Task) callconv(.c) void {
    sched.unpark(&t.k);
}

/// Gives the executor up, runnable: its call reports 2.
fn h9_sched_yield() callconv(.c) void {
    const p = port.up();
    sched.cont.yield();
    c._setproc(p);
}

pub fn exportC() void {
    if (!sync.can_park) return;
    @export(&h9_sched_pool_new, .{ .name = "h9_sched_pool_new" });
    @export(&h9_sched_pool_free, .{ .name = "h9_sched_pool_free" });
    @export(&h9_sched_pool_mapped, .{ .name = "h9_sched_pool_mapped" });
    @export(&h9_sched_task_new, .{ .name = "h9_sched_task_new" });
    @export(&h9_sched_task_free, .{ .name = "h9_sched_task_free" });
    @export(&h9_sched_exec_new, .{ .name = "h9_sched_exec_new" });
    @export(&h9_sched_exec_free, .{ .name = "h9_sched_exec_free" });
    @export(&h9_sched_exec_start, .{ .name = "h9_sched_exec_start" });
    @export(&h9_sched_exec_resume, .{ .name = "h9_sched_exec_resume" });
    @export(&h9_sched_exec_current, .{ .name = "h9_sched_exec_current" });
    @export(&h9_sched_task_current, .{ .name = "h9_sched_task_current" });
    @export(&h9_sched_yield, .{ .name = "h9_sched_yield" });
    @export(&h9_sched_park, .{ .name = "h9_sched_park" });
    @export(&h9_sched_unpark, .{ .name = "h9_sched_unpark" });
}
