//! The web host (design/epoch-0/browser-host.md): h9 on wasm32-wasi, in a
//! Web Worker or under Node, with h9's own 386 CPU (h86) as its engine.

const std = @import("std");
const builtin = @import("builtin");

/// Whether this is a web build.
pub const enabled = builtin.os.tag == .wasi;

/// The web host's one executor (src/kern/sched/web.zig).
pub const task = @import("web/task.zig");

/// The web host's allocator (std.heap.page_allocator there, and the engine's).
pub const heap = @import("web/heap.zig");

/// A host thread: a task on the web host's executor.
pub const Thread = if (enabled) task.Thread else std.Thread;

/// The web host's Io, whose blocking parks the calling task.
pub const io = @import("web/io.zig").io;

/// Lets other threads, or tasks, run.
pub fn yield() void {
    if (enabled) task.yield() else std.Thread.yield() catch {};
}

/// std.atomic.Value, or on the web host, where everything runs on one
/// thread and wasm32 has no 64-bit atomics, a plain value with its API.
pub fn Atomic(comptime T: type) type {
    if (!enabled) return std.atomic.Value(T);
    return struct {
        raw: T,

        const Self = @This();
        pub fn init(v: T) Self {
            return .{ .raw = v };
        }
        pub fn load(s: *const Self, comptime _: std.builtin.AtomicOrder) T {
            return s.raw;
        }
        pub fn store(s: *Self, v: T, comptime _: std.builtin.AtomicOrder) void {
            s.raw = v;
        }
        pub fn swap(s: *Self, v: T, comptime _: std.builtin.AtomicOrder) T {
            const old = s.raw;
            s.raw = v;
            return old;
        }
        pub fn fetchAdd(s: *Self, v: T, comptime _: std.builtin.AtomicOrder) T {
            const old = s.raw;
            s.raw +%= v;
            return old;
        }
        pub fn fetchSub(s: *Self, v: T, comptime _: std.builtin.AtomicOrder) T {
            const old = s.raw;
            s.raw -%= v;
            return old;
        }
        pub fn cmpxchgStrong(s: *Self, expected: T, new: T, comptime _: std.builtin.AtomicOrder, comptime _: std.builtin.AtomicOrder) ?T {
            if (s.raw != expected) return s.raw;
            s.raw = new;
            return null;
        }
    };
}

/// The allocator for h9's own long-lived state: libc's malloc on the web
/// host, which is single-threaded.
pub const gpa: std.mem.Allocator = if (enabled) std.heap.c_allocator else std.heap.smp_allocator;
