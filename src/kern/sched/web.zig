//! The web host's executor (design/scheduler.md, "The web host"): the
//! one executor of the scheduler's design, on the page's one thread.
//! Every kernel process and every task h9 would give a host thread
//! natively (the boot Proc, the console reader, a stream's reader) is a
//! task here: a continuation (cont.zig, switched with Asyncify) that the
//! executor's loop runs until it parks, yields, or returns.
//!
//! The loop is at the bottom of the module's only JSPI stack, `_start`'s.
//! When nothing is runnable it calls `idle`, the one Suspending import,
//! which suspends the whole module until a timer is due or the JS host
//! finishes an op. An op is the JS host's half of a call that waits on
//! JavaScript (a WebSocket's next message, console input, a signal): the
//! import starts it and returns its id at once, and the task parks in
//! `h9_task_await` until `idle` comes back with it done, so only that
//! task waits. A long run of tasks with no idle still calls it now and
//! then, so the page's own events are seen.
//!
//! wasm globals aren't per stack, so a switch saves what's per thread on
//! native hosts: errno, h9's Zig threadlocals (`h9_web_locals`), and
//! drawterm's `up`, which is the task's. The shadow stack pointer is the
//! continuation's (cont.zig). A longjmp stays within one task, since
//! kern's error labels never cross a process. Asyncify unwinds through
//! the wasm exception handling that setjmp uses, since a park is always
//! in a `try` body, never in a handler: LLVM's lowering runs the code
//! after a longjmp lands outside the `catch`.
//!
//! C (os-wasm.c, gfx-web.c) and h9's Zig (src/web/task.zig) reach it
//! through the calls exported below, so there's one copy of its state.

const std = @import("std");
const builtin = @import("builtin");
const sched = @import("sched.zig");
const stack = @import("stack.zig");

const js = struct {
    extern "h9" fn idle(ms: i32) i32;
    extern "h9" fn ops_done(p: [*]i32, n: i32) i32;
    extern "h9" fn mono_ms() f64;
    extern "h9" fn panic(p: [*]const u8, n: usize) void;
};

extern fn h9_web_locals(save: c_int, slots: *[4]usize) void;
extern threadlocal var errno: c_int;

const gpa = std.heap.c_allocator;

/// A task: a continuation and what's per thread while it's switched out.
pub const Task = struct {
    k: sched.Cont = .{ .ready = ready },
    name: [32]u8 = @splat(0),
    func: *const fn (?*anyopaque) callconv(.c) void,
    arg: ?*anyopaque,
    started: bool = false,
    /// drawterm's `up`, while it runs on this task.
    proc: ?*anyopaque = null,
    err: c_int = 0,
    zls: [4]usize = @splat(0),
    /// A timed park's deadline (ms, monotonic), while it's on `timers`.
    deadline: f64 = 0,
    timed: bool = false,
    timed_out: bool = false,
    tnext: ?*Task = null,
    /// The op it awaits, and its result once done.
    op: i32 = 0,
    op_done: bool = false,
    op_result: i32 = 0,
    onext: ?*Task = null,

    fn ready(k: *sched.Cont) void {
        const t: *Task = @alignCast(@fieldParentPtr("k", k));
        runq.push(&t.k);
    }

    fn of(k: *sched.Cont) *Task {
        return @alignCast(@fieldParentPtr("k", k));
    }
};

var pool: sched.Pool = .{ .size = kstack };
var main_pool: sched.Pool = .{ .size = main_stack };
var ex: sched.Executor = undefined;
var runq: sched.RunQueue = .{};
var cur: ?*Task = null;
/// The task running main, and h9's own state while no task runs.
var main_task: ?*Task = null;
var timers: ?*Task = null;
var awaiting: ?*Task = null;
var last_idle: f64 = 0;
var maxdepth: usize = 0;

/// A kernel process's stack: the integration suite's deepest use at a
/// park (149 KiB, in a guest process's syscall path, Debug build),
/// doubled and rounded up. H9_TEST_KSTACK sets it for the overflow case.
const kstack = 320 * 1024;
/// main's, which the linker's stack was.
const main_stack = 1 << 20;
/// How long tasks run with no idle before the page's events are seen.
const turn_ms = 10;

fn now() f64 {
    return js.mono_ms();
}

fn fatal(msg: []const u8) noreturn {
    js.panic(msg.ptr, msg.len);
    unreachable;
}

fn overflow(t: *Task) noreturn {
    var buf: [96]u8 = undefined;
    fatal(std.fmt.bufPrint(&buf, "kernel stack overflow in {s}", .{std.mem.sliceTo(&t.name, 0)}) catch "kernel stack overflow");
}

fn outHook(_: *sched.Executor, k: *sched.Cont) void {
    const t = Task.of(k);
    const sp = sched.cont.stackPointer();
    const hi = k.stack.?.hi();
    if (hi > sp and hi - sp > maxdepth) maxdepth = hi - sp;
    // wasm has no guard pages: the canary or the pointer gives it away.
    if (!k.stack.?.holds(sp)) overflow(t);
    t.err = errno;
    h9_web_locals(1, &t.zls);
}

fn switchIn(t: *Task) void {
    cur = t;
    h9_web_locals(0, &t.zls);
    errno = t.err;
}

fn entry(arg: ?*anyopaque) void {
    const t: *Task = @ptrCast(@alignCast(arg.?));
    t.func(t.arg);
}

/// Runs t until it parks, yields, or returns.
fn step(t: *Task) void {
    switchIn(t);
    const out = if (!t.started) blk: {
        t.started = true;
        if (t != main_task) break :blk ex.call(&t.k, entry, t) catch fatal("h9: no memory for a kernel stack");
        // main's stack is bigger, from a pool of its own.
        const spare = ex.spare;
        ex.spare = null;
        ex.pool = &main_pool;
        defer {
            ex.pool = &pool;
            ex.spare = spare;
        }
        break :blk ex.call(&t.k, entry, t) catch fatal("h9: no memory for main's stack");
    } else ex.@"resume"(&t.k);
    cur = null;
    switch (out) {
        .returned => {
            if (t == main_task) return;
            gpa.destroy(t);
        },
        .parked => {},
        .yielded => runq.push(&t.k),
    }
}

/// Unparks the timed parks that are due.
fn fireTimers() void {
    const n = now();
    var l = &timers;
    while (l.*) |t| {
        if (t.deadline <= n) {
            l.* = t.tnext;
            t.tnext = null;
            t.timed = false;
            if (t.k.isParked()) {
                t.timed_out = true;
                sched.unpark(&t.k);
            }
        } else l = &t.tnext;
    }
}

/// Lets the JS host run, for at most `ms` (or until an op is done), and
/// unparks the tasks awaiting the ops it finished.
fn idle(ms: i32) void {
    _ = js.idle(ms);
    last_idle = now();
    var buf: [64]i32 = undefined;
    while (true) {
        const n: usize = @intCast(js.ops_done(&buf, buf.len / 2));
        for (0..n) |i| {
            const id = buf[2 * i];
            var l = &awaiting;
            while (l.*) |t| : (l = &t.onext) if (t.op == id) {
                l.* = t.onext;
                t.onext = null;
                t.op_result = buf[2 * i + 1];
                t.op_done = true;
                sched.unpark(&t.k);
                break;
            };
        }
        if (n < buf.len / 2) break;
    }
}

/// Runs main(arg) as the first task, and every task until it returns.
fn h9_task_main(main: *const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque) callconv(.c) void {
    if (std.c.getenv("H9_TEST_KSTACK")) |s| {
        const n = std.fmt.parseInt(usize, std.mem.span(s), 0) catch 0;
        if (n >= 4096) pool.size = n;
    }
    ex = sched.Executor.init(&pool);
    ex.out_hook = outHook;
    const t = gpa.create(Task) catch fatal("h9: no memory");
    t.* = .{ .func = main, .arg = arg };
    @memcpy(t.name[0..4], "main");
    main_task = t;
    last_idle = now();
    runq.push(&t.k);
    while (true) {
        fireTimers();
        if (runq.pop()) |k| {
            step(Task.of(k));
            if (t.started and t.k.stack == null) break; // main returned
            if (now() - last_idle >= turn_ms) idle(0);
            continue;
        }
        var wait: i32 = -1;
        var it = timers;
        const n = now();
        while (it) |x| : (it = x.tnext) {
            const d: i32 = @intFromFloat(@max(0, @min(std.math.maxInt(i31), @ceil(x.deadline - n))));
            if (wait < 0 or d < wait) wait = d;
        }
        idle(wait);
    }
    main_task = null;
    gpa.destroy(t);
}

fn self() *Task {
    return cur orelse fatal("h9: not on a task");
}

fn h9_task_self() callconv(.c) ?*Task {
    return cur;
}

/// Starts func(arg) as a task, which runs once the caller parks or
/// yields.
fn h9_task_spawn(name: [*:0]const u8, func: *const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque) callconv(.c) ?*Task {
    const t = gpa.create(Task) catch return null;
    t.* = .{ .func = func, .arg = arg };
    const n = std.mem.span(name);
    const l = @min(n.len, t.name.len - 1);
    @memcpy(t.name[0..l], n[0..l]);
    runq.push(&t.k);
    return t;
}

/// Parks the calling task until an unpark, or for at most ms when that
/// isn't negative. 1 if it was unparked, 0 if the time ran out. An
/// unpark before the park makes it return at once.
fn h9_task_park(ms: c_long) callconv(.c) c_int {
    const t = self();
    t.timed_out = false;
    if (ms >= 0) {
        t.deadline = now() + @as(f64, @floatFromInt(ms));
        t.timed = true;
        t.tnext = timers;
        timers = t;
    }
    sched.park();
    if (t.timed) {
        var l = &timers;
        while (l.*) |x| : (l = &x.tnext) if (x == t) {
            l.* = t.tnext;
            break;
        };
        t.tnext = null;
        t.timed = false;
    }
    return @intFromBool(!t.timed_out);
}

fn h9_task_unpark(t: *Task) callconv(.c) void {
    sched.unpark(&t.k);
}

/// Lets every other runnable task run, and the page's events now and
/// then.
fn h9_task_yield() callconv(.c) void {
    _ = self();
    sched.cont.yield();
}

/// Waits ms milliseconds, unparks or not.
fn h9_task_sleep(ms: c_long) callconv(.c) void {
    const end = now() + @as(f64, @floatFromInt(@max(ms, 0)));
    while (true) {
        const left = end - now();
        if (left <= 0) break;
        _ = h9_task_park(@intFromFloat(@ceil(left)));
    }
}

/// Ends the calling task now, from any depth.
fn h9_task_exit() callconv(.c) noreturn {
    if (self() == main_task) fatal("h9: main can't exit as a task");
    sched.cont.exit();
}

/// Waits for the JS host's op `id`, which an import just started, and
/// returns its result.
fn h9_task_await(id: i32) callconv(.c) i32 {
    const t = self();
    t.op = id;
    t.op_done = false;
    t.onext = awaiting;
    awaiting = t;
    while (!t.op_done) _ = h9_task_park(-1);
    t.op = 0;
    return t.op_result;
}

fn h9_task_getproc() callconv(.c) ?*anyopaque {
    return if (cur) |t| t.proc else null;
}

fn h9_task_setproc(p: ?*anyopaque) callconv(.c) void {
    self().proc = p;
}

fn h9_task_name(t: *Task) callconv(.c) [*:0]const u8 {
    return @ptrCast(&t.name);
}

/// The deepest stack use of any task so far, at a park or a yield.
fn h9_task_maxdepth() callconv(.c) usize {
    return maxdepth;
}

pub fn exportC() void {
    @export(&h9_task_main, .{ .name = "h9_task_main" });
    @export(&h9_task_self, .{ .name = "h9_task_self" });
    @export(&h9_task_spawn, .{ .name = "h9_task_spawn" });
    @export(&h9_task_park, .{ .name = "h9_task_park" });
    @export(&h9_task_unpark, .{ .name = "h9_task_unpark" });
    @export(&h9_task_yield, .{ .name = "h9_task_yield" });
    @export(&h9_task_sleep, .{ .name = "h9_task_sleep" });
    @export(&h9_task_exit, .{ .name = "h9_task_exit" });
    @export(&h9_task_await, .{ .name = "h9_task_await" });
    @export(&h9_task_getproc, .{ .name = "h9_task_getproc" });
    @export(&h9_task_setproc, .{ .name = "h9_task_setproc" });
    @export(&h9_task_name, .{ .name = "h9_task_name" });
    @export(&h9_task_maxdepth, .{ .name = "h9_task_maxdepth" });
}
