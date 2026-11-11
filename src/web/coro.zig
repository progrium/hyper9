//! Zig's side of the web host's coroutines (coro.c,
//! design/browser-host.md), and `Thread`, which stands in for
//! std.Thread where h9 starts a host thread of its own.

const std = @import("std");

pub const Coro = opaque {};

extern fn h9_coro_self() *Coro;
extern fn h9_coro_spawn(name: [*:0]const u8, func: *const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque, stk: c_ulong) ?*Coro;
extern fn h9_coro_park(ms: c_long) c_int;
extern fn h9_coro_unpark(c: *Coro) void;
extern fn h9_coro_yield() void;
extern fn h9_coro_sleep(ms: c_long) void;
extern fn h9_coro_maxdepth() c_ulong;
extern fn h9_coro_save(c: *Coro) void;
extern fn h9_coro_restore(c: *Coro) void;
extern fn h9_get_sp() usize;
extern fn h9_set_sp(sp: usize) void;

/// The stack for h9's own coroutines: the boot Proc, the console reader.
/// The same as a kernel process's (os-wasm.c's KSTACK).
pub const stack_size = 320 * 1024;

pub fn self() *Coro {
    return h9_coro_self();
}

/// Parks the calling coroutine until `unpark`, or for at most `ms` when
/// that isn't negative. Returns false if the time ran out. An unpark
/// before the park makes it return at once.
pub fn park(ms: i64) bool {
    return h9_coro_park(@intCast(@min(ms, std.math.maxInt(c_long)))) != 0;
}

pub fn unpark(c: *Coro) void {
    h9_coro_unpark(c);
}

/// Lets every other coroutine and the event loop run.
pub fn yield() void {
    h9_coro_yield();
}

pub fn sleep(ms: i64) void {
    h9_coro_sleep(@intCast(@max(0, @min(ms, std.math.maxInt(c_long)))));
}

/// Calls `f`, a Suspending JS import, as a park: other coroutines run
/// while it waits, so what's per thread is saved around it.
pub inline fn blocking(comptime f: anytype, args: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
    const me = h9_coro_self();
    h9_coro_save(me);
    const sp = h9_get_sp();
    const r = @call(.auto, f, args);
    h9_set_sp(sp);
    h9_coro_restore(me);
    return r;
}

/// The deepest shadow-stack use of any coroutine so far, seen at a park.
pub fn maxDepth() usize {
    return h9_coro_maxdepth();
}

/// A coroutine in place of a host thread, with std.Thread's spawn, join
/// and detach.
pub const Thread = struct {
    state: *State,

    const State = struct {
        done: bool = false,
        detached: bool = false,
        joiner: ?*Coro = null,
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
        if (h9_coro_spawn("thread", entry, &cl.state, stack_size) == null) {
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
