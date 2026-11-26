//! Kernel stacks for parked processes (design/scheduler.md), and the pool
//! they come from and go back to.
//!
//! A kernel stack is what a process's kernel continuation runs on
//! (cont.zig). An executor holds one spare; a process takes it when it
//! enters the kernel and keeps it only if it parks there, so a process
//! that never blocks never owns one, and a blocked process owns exactly
//! one. Stacks go back to the pool when a kernel call returns or a process
//! exits, and the pool hands them out again: mapping a stack costs system
//! calls, and on the web host wasm memory never shrinks anyway.
//!
//! The overflow check is per host:
//!
//! - **Native hosts** (x86_64 and aarch64; Linux, macOS, and Windows): the
//!   stack is its own mapping, and its lowest page (`guard_size`) is
//!   inaccessible, so running off the end is a fault at the guard page,
//!   never a write into whatever is mapped below. Pages above it are
//!   committed only as they're touched, so a large stack costs what it
//!   uses.
//! - **wasm32**: wasm has no guard pages. A stack is a block of linear
//!   memory with a canary word at its low end, which the continuation
//!   checks at every switch (as src/web/coro.c does today), so an overflow
//!   is a panic at the next park rather than silent corruption. Below the
//!   canary is the continuation's Asyncify buffer (cont.zig), which
//!   Asyncify bounds itself.

const std = @import("std");
const builtin = @import("builtin");

const is_wasm = builtin.cpu.arch.isWasm();
const is_windows = builtin.os.tag == .windows;
const page_size = std.heap.page_size_min;

/// Bytes a stack is, by default, not counting the guard page. A process's
/// whole exit loop runs on it, so natively it's a host thread's 8 MiB: a
/// Debug build's Linux clone alone takes 170 KiB, and the debug allocator
/// unwinds the stack on each allocation. Only what's touched is resident.
/// On wasm it's the size of today's coroutine stacks (src/web/coro.zig).
pub const default_size: usize = if (is_wasm) 320 * 1024 else 8 * 1024 * 1024;

/// The inaccessible region below a native stack.
pub const guard_size: usize = if (is_wasm) 0 else page_size;

/// On wasm, the bytes at a stack's low end for the Asyncify buffer.
pub const async_size: usize = if (is_wasm) 32 * 1024 else 0;

/// The canary at the low end of a wasm stack's usable region.
pub const canary: u32 = 0xC0DEC0DE;

pub const Error = error{OutOfMemory};

/// One kernel stack. `lo` to `hi` is the usable region; the stack grows
/// down from `hi`.
pub const Stack = struct {
    /// The whole allocation: the guard page, or the Asyncify buffer, and
    /// the usable region above it.
    mem: []align(page_size) u8,

    /// The lowest usable address, just above the guard page or the
    /// canary.
    pub fn lo(s: Stack) usize {
        return @intFromPtr(s.mem.ptr) + guard_size + async_size + if (is_wasm) @sizeOf(u32) else 0;
    }

    /// The top, 16-byte aligned, where the stack starts.
    pub fn hi(s: Stack) usize {
        return std.mem.alignBackward(usize, @intFromPtr(s.mem.ptr) + s.mem.len, 16);
    }

    /// On wasm, the Asyncify buffer at the stack's low end.
    pub fn asyncBuf(s: Stack) []u8 {
        return s.mem[0..async_size];
    }

    /// Whether sp is inside the usable region, and on wasm, whether the
    /// canary is intact. A native overflow faults at the guard page before
    /// this could be false.
    pub fn holds(s: Stack, sp: usize) bool {
        if (is_wasm and s.canaryPtr().* != canary) return false;
        return sp >= s.lo() and sp <= s.hi();
    }

    fn canaryPtr(s: Stack) *u32 {
        return @ptrFromInt(@intFromPtr(s.mem.ptr) + async_size);
    }

    /// Maps a stack of `size` usable bytes, with its guard page.
    pub fn map(size: usize) Error!Stack {
        const len = std.mem.alignForward(usize, size, page_size) + guard_size + async_size;
        if (is_wasm) {
            const mem = std.heap.wasm_allocator.alignedAlloc(u8, .fromByteUnits(page_size), len) catch return error.OutOfMemory;
            const s: Stack = .{ .mem = mem };
            s.canaryPtr().* = canary;
            return s;
        }
        if (is_windows) {
            const w = std.os.windows;
            // rawAlloc, not alignedAlloc, which would fill (and so commit)
            // every page with undefined in safe builds.
            const p = std.heap.page_allocator.rawAlloc(len, .fromByteUnits(page_size), @returnAddress()) orelse return error.OutOfMemory;
            const mem: []align(page_size) u8 = @as([*]align(page_size) u8, @alignCast(p))[0..len];
            var base: ?w.PVOID = mem.ptr;
            var n: w.SIZE_T = guard_size;
            var old: w.PAGE = undefined;
            if (w.ntdll.NtProtectVirtualMemory(w.GetCurrentProcess(), &base, &n, .{ .NOACCESS = true }, &old) != .SUCCESS) {
                std.heap.page_allocator.rawFree(mem, .fromByteUnits(page_size), @returnAddress());
                return error.OutOfMemory;
            }
            return .{ .mem = mem };
        }
        const mem = std.posix.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0) catch
            return error.OutOfMemory;
        if (std.c.mprotect(@ptrCast(mem.ptr), guard_size, .{}) != 0) {
            std.posix.munmap(mem);
            return error.OutOfMemory;
        }
        return .{ .mem = mem };
    }

    pub fn unmap(s: Stack) void {
        if (is_wasm)
            std.heap.wasm_allocator.free(s.mem)
        else if (is_windows)
            std.heap.page_allocator.rawFree(s.mem, .fromByteUnits(page_size), @returnAddress())
        else
            std.posix.munmap(s.mem);
    }
};

/// Stacks not in use, shared by a machine's executors. While a stack is
/// in the pool, its top holds the free list's link.
pub const Pool = struct {
    /// Usable bytes of each stack.
    size: usize = default_size,
    /// The most stacks the pool keeps; more are unmapped when they come
    /// back. wasm memory never shrinks, so there it keeps them all.
    keep: usize = if (is_wasm) std.math.maxInt(usize) else 256,

    lock: std.atomic.Mutex = .unlocked,
    free: ?*Node = null,
    nfree: usize = 0,
    /// Stacks mapped and not yet unmapped, in the pool or out of it.
    mapped: usize = 0,

    const Node = struct {
        next: ?*Node,
        mem: []align(page_size) u8,
    };

    fn acquire(p: *Pool) void {
        while (!p.lock.tryLock()) std.atomic.spinLoopHint();
    }

    /// A stack, from the free list or newly mapped.
    pub fn get(p: *Pool) Error!Stack {
        p.acquire();
        if (p.free) |n| {
            p.free = n.next;
            p.nfree -= 1;
            const s: Stack = .{ .mem = n.mem };
            p.lock.unlock();
            return s;
        }
        p.mapped += 1;
        p.lock.unlock();
        return Stack.map(p.size) catch |err| {
            p.acquire();
            p.mapped -= 1;
            p.lock.unlock();
            return err;
        };
    }

    /// Gives a stack back. Nothing may be running on it.
    pub fn put(p: *Pool, s: Stack) void {
        p.acquire();
        if (p.nfree >= p.keep) {
            p.mapped -= 1;
            p.lock.unlock();
            return s.unmap();
        }
        const n: *Node = @ptrFromInt(std.mem.alignBackward(usize, s.hi() - @sizeOf(Node), @alignOf(Node)));
        n.* = .{ .next = p.free, .mem = s.mem };
        p.free = n;
        p.nfree += 1;
        p.lock.unlock();
    }

    /// Unmaps the free stacks. Stacks still out are the holders' to give
    /// back first.
    pub fn deinit(p: *Pool) void {
        p.acquire();
        while (p.free) |n| {
            p.free = n.next;
            p.mapped -= 1;
            (Stack{ .mem = n.mem }).unmap();
        }
        p.nfree = 0;
        p.lock.unlock();
    }
};

test "a stack given back to the pool is the next one handed out [scheduler]" {
    var pool: Pool = .{ .size = 64 * 1024 };
    defer pool.deinit();
    const a = try pool.get();
    const b = try pool.get();
    try std.testing.expectEqual(@as(usize, 2), pool.mapped);
    try std.testing.expect(a.mem.ptr != b.mem.ptr);
    try std.testing.expect(a.hi() - a.lo() >= 64 * 1024 - 16);
    pool.put(a);
    const c = try pool.get();
    try std.testing.expectEqual(a.mem.ptr, c.mem.ptr);
    try std.testing.expectEqual(@as(usize, 2), pool.mapped);
    pool.put(b);
    pool.put(c);
    try std.testing.expectEqual(@as(usize, 2), pool.nfree);
}

test "a pool keeps at most keep stacks [scheduler]" {
    var pool: Pool = .{ .size = 16 * 1024, .keep = 1 };
    defer pool.deinit();
    const a = try pool.get();
    const b = try pool.get();
    pool.put(a);
    pool.put(b);
    try std.testing.expectEqual(@as(usize, 1), pool.nfree);
    try std.testing.expectEqual(@as(usize, 1), pool.mapped);
}
