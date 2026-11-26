//! h9's side of the web host's one executor (src/kern/sched/web.zig,
//! design/scheduler.md), and `Thread`, which stands in for std.Thread
//! where h9 starts a host thread of its own: a task on the executor.

const std = @import("std");

pub const Task = opaque {};

extern fn h9_task_main(main: *const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque) void;
extern fn h9_task_self() ?*Task;
extern fn h9_task_spawn(name: [*:0]const u8, func: *const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque) ?*Task;
extern fn h9_task_park(ms: c_long) c_int;
extern fn h9_task_unpark(t: *Task) void;
extern fn h9_task_yield() void;
extern fn h9_task_sleep(ms: c_long) void;
extern fn h9_task_await(id: i32) i32;
extern fn h9_task_maxdepth() usize;

/// Runs f() as the executor's first task, and the executor until f
/// returns: main's body on the web host.
pub fn runMain(comptime f: fn () void) void {
    const S = struct {
        fn entry(_: ?*anyopaque) callconv(.c) void {
            f();
        }
    };
    h9_task_main(S.entry, null);
}

pub fn self() *Task {
    return h9_task_self().?;
}

/// Parks the calling task until `unpark`, or for at most `ms` when that
/// isn't negative. Returns false if the time ran out. An unpark before
/// the park makes it return at once.
pub fn park(ms: i64) bool {
    return h9_task_park(@intCast(@min(ms, std.math.maxInt(c_long)))) != 0;
}

pub fn unpark(t: *Task) void {
    h9_task_unpark(t);
}

/// Lets every other task, and now and then the page's events, run.
pub fn yield() void {
    h9_task_yield();
}

pub fn sleep(ms: i64) void {
    h9_task_sleep(@intCast(@max(0, @min(ms, std.math.maxInt(c_long)))));
}

/// Calls `f`, an import that starts a JS host op and returns its id, and
/// waits for the op's result, with the other tasks running meanwhile.
pub inline fn blocking(comptime f: anytype, args: anytype) i32 {
    const id: i32 = @call(.auto, f, args);
    return h9_task_await(id);
}

/// The deepest stack use of any task so far, seen at a park or a yield.
pub fn maxDepth() usize {
    return h9_task_maxdepth();
}

/// A task in place of a host thread, with std.Thread's spawn, join and
/// detach.
pub const Thread = struct {
    state: *State,

    const State = struct {
        done: bool = false,
        detached: bool = false,
        joiner: ?*Task = null,
        run: *const fn (*State) void,
        free: *const fn (*State) void,
    };

    pub const SpawnError = error{OutOfMemory};

    pub fn spawn(_: std.Thread.SpawnConfig, comptime f: anytype, args: anytype) SpawnError!Thread {
        const Args = @TypeOf(args);
        const Closure = struct {
            state: State,
            args: Args,

            fn run(s: *State) void {
                const cl: *@This() = @fieldParentPtr("state", s);
                _ = @call(.auto, f, cl.args);
            }
            fn free(s: *State) void {
                const cl: *@This() = @fieldParentPtr("state", s);
                std.heap.c_allocator.destroy(cl);
            }
        };
        const cl = try std.heap.c_allocator.create(Closure);
        cl.* = .{ .state = .{ .run = Closure.run, .free = Closure.free }, .args = args };
        if (h9_task_spawn("thread", entry, &cl.state) == null) {
            std.heap.c_allocator.destroy(cl);
            return error.OutOfMemory;
        }
        return .{ .state = &cl.state };
    }

    fn entry(p: ?*anyopaque) callconv(.c) void {
        const s: *State = @ptrCast(@alignCast(p.?));
        s.run(s);
        s.done = true;
        if (s.detached) return s.free(s);
        if (s.joiner) |j| unpark(j);
    }

    pub fn join(t: Thread) void {
        const s = t.state;
        while (!s.done) {
            s.joiner = self();
            _ = park(-1);
        }
        s.free(s);
    }

    pub fn detach(t: Thread) void {
        const s = t.state;
        if (s.done) return s.free(s);
        s.detached = true;
    }
};
