//! A reserved range of host memory that the emulator hands out guest pages
//! from, so one Unicorn region covers them all (design/0018-linux-
//! personality.md, "The emulator in virtual-TLB mode"). Pages are zero when
//! handed out: never-used ones always are, and freed ones are given back
//! to the host, which zeroes them on their next touch, so neither an
//! allocation nor a free touches the pages themselves.
//!
//! Allocation is first fit from a sorted free list below a bump pointer,
//! as hvf.zig's guest RAM. Callers lock.

const std = @import("std");
const builtin = @import("builtin");
const page_size = @import("../vmm.zig").page_size;

const windows = builtin.os.tag == .windows;
const host_min = std.heap.page_size_min;

mem: []align(host_min) u8,
/// Everything at or above this offset has never been handed out.
next: usize = 0,
/// Freed ranges below `next`, sorted by offset and coalesced.
free: std.ArrayList(Range) = .empty,

const Arena = @This();
const Range = struct { off: usize, len: usize };

/// Reserves `size` bytes of address space, which costs no memory until
/// pages are handed out and touched.
pub fn init(size: usize) error{OutOfMemory}!Arena {
    return .{ .mem = try reserve(size) };
}

pub fn deinit(a: *Arena, gpa: std.mem.Allocator) void {
    release(a.mem);
    a.free.deinit(gpa);
}

/// Hands out `len` bytes (a whole number of pages) of zeroed memory.
/// `gpa` holds the free list.
pub fn alloc(a: *Arena, gpa: std.mem.Allocator, len: usize) error{OutOfMemory}![]align(page_size) u8 {
    std.debug.assert(len > 0 and len % page_size == 0);
    const off = blk: {
        for (a.free.items, 0..) |*r, i| if (r.len >= len) {
            const off = r.off;
            r.off += len;
            r.len -= len;
            if (r.len == 0) _ = a.free.orderedRemove(i);
            break :blk off;
        };
        if (a.mem.len - a.next < len) return error.OutOfMemory;
        a.next += len;
        break :blk a.next - len;
    };
    const m: []align(page_size) u8 = @alignCast(a.mem[off..][0..len]);
    commit(m) catch {
        a.giveBack(gpa, off, len);
        return error.OutOfMemory;
    };
    return m;
}

/// Takes back pages from `alloc`, all or any page-aligned part of them.
/// `gpa` holds the free list; if it can't grow, the range is only leaked.
pub fn freePages(a: *Arena, gpa: std.mem.Allocator, m: []align(page_size) u8) void {
    if (m.len == 0) return;
    decommit(m);
    a.giveBack(gpa, @intFromPtr(m.ptr) - @intFromPtr(a.mem.ptr), m.len);
}

/// The offset of `ptr`, which must be in the arena.
pub fn offsetOf(a: *const Arena, ptr: [*]const u8) usize {
    return @intFromPtr(ptr) - @intFromPtr(a.mem.ptr);
}

fn giveBack(a: *Arena, gpa: std.mem.Allocator, off: usize, len: usize) void {
    var i: usize = 0;
    while (i < a.free.items.len and a.free.items[i].off < off) i += 1;
    var r: Range = .{ .off = off, .len = len };
    if (i < a.free.items.len and r.off + r.len == a.free.items[i].off) {
        r.len += a.free.items[i].len;
        _ = a.free.orderedRemove(i);
    }
    if (i > 0 and a.free.items[i - 1].off + a.free.items[i - 1].len == r.off) {
        i -= 1;
        r.off = a.free.items[i].off;
        r.len += a.free.items[i].len;
        _ = a.free.orderedRemove(i);
    }
    if (r.off + r.len == a.next) {
        a.next = r.off;
        return;
    }
    a.free.insert(gpa, i, r) catch {};
}

// The host side. POSIX maps the whole range read-write up front (without
// reserving swap for it on Linux) and frees by mapping fresh zero pages
// over a range; Windows reserves, then commits and decommits.

fn reserve(size: usize) error{OutOfMemory}![]align(host_min) u8 {
    if (windows) {
        const w = std.os.windows;
        var base: ?*anyopaque = null;
        var n: w.SIZE_T = size;
        const st = w.ntdll.NtAllocateVirtualMemory(w.GetCurrentProcess(), @ptrCast(&base), 0, &n, .{ .RESERVE = true }, .{ .NOACCESS = true });
        if (st != .SUCCESS) return error.OutOfMemory;
        return @as([*]align(host_min) u8, @ptrCast(@alignCast(base)))[0..size];
    }
    return std.posix.mmap(null, size, .{ .READ = true, .WRITE = true }, mapFlags(false), -1, 0) catch error.OutOfMemory;
}

fn release(m: []align(host_min) u8) void {
    if (windows) {
        const w = std.os.windows;
        var base: ?*anyopaque = m.ptr;
        var n: w.SIZE_T = 0;
        _ = w.ntdll.NtFreeVirtualMemory(w.GetCurrentProcess(), @ptrCast(&base), &n, .{ .RELEASE = true });
        return;
    }
    std.posix.munmap(m);
}

fn commit(m: []align(page_size) u8) error{OutOfMemory}!void {
    if (!windows) return;
    const w = std.os.windows;
    var base: ?*anyopaque = m.ptr;
    var n: w.SIZE_T = m.len;
    const st = w.ntdll.NtAllocateVirtualMemory(w.GetCurrentProcess(), @ptrCast(&base), 0, &n, .{ .COMMIT = true }, .{ .READWRITE = true });
    if (st != .SUCCESS) return error.OutOfMemory;
}

/// Gives the pages back to the host; their next use sees zeroes.
fn decommit(m: []align(page_size) u8) void {
    if (windows) {
        const w = std.os.windows;
        var base: ?*anyopaque = m.ptr;
        var n: w.SIZE_T = m.len;
        _ = w.ntdll.NtFreeVirtualMemory(w.GetCurrentProcess(), @ptrCast(&base), &n, .{ .DECOMMIT = true });
        return;
    }
    // Mapping over the range replaces its pages at once. The host's pages
    // may be larger than the guest's (16 KiB on Apple silicon), so the
    // parts of host pages at either end are cleared by hand, as is the
    // whole range if the map fails.
    const hp = std.heap.pageSize();
    const start = std.mem.alignForward(usize, @intFromPtr(m.ptr), hp);
    const end = std.mem.alignBackward(usize, @intFromPtr(m.ptr) + m.len, hp);
    if (end <= start) return @memset(m, 0);
    const head = start - @intFromPtr(m.ptr);
    const tail = @intFromPtr(m.ptr) + m.len - end;
    @memset(m[0..head], 0);
    @memset(m[m.len - tail ..], 0);
    const r = std.c.mmap(@ptrFromInt(start), end - start, .{ .READ = true, .WRITE = true }, mapFlags(true), -1, 0);
    if (r == std.c.MAP_FAILED) @memset(m[head .. m.len - tail], 0);
}

fn mapFlags(fixed: bool) std.posix.MAP {
    var f: std.posix.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED = fixed };
    if (@hasField(std.posix.MAP, "NORESERVE")) f.NORESERVE = true;
    return f;
}

test "arena: first fit, coalescing and zeroed reuse" {
    const gpa = std.testing.allocator;
    var a: Arena = try .init(64 * page_size);
    defer a.deinit(gpa);
    const x = try a.alloc(gpa, 2 * page_size);
    const y = try a.alloc(gpa, page_size);
    const z = try a.alloc(gpa, page_size);
    @memset(x, 0xaa);
    @memset(y, 0xbb);
    a.freePages(gpa, x);
    a.freePages(gpa, y);
    try std.testing.expectEqual(1, a.free.items.len);
    try std.testing.expectEqual(3 * page_size, a.free.items[0].len);
    const w = try a.alloc(gpa, 3 * page_size);
    try std.testing.expectEqual(x.ptr, w.ptr);
    for (w) |b| try std.testing.expectEqual(0, b);
    a.freePages(gpa, z);
    a.freePages(gpa, w);
    try std.testing.expectEqual(0, a.next);
    try std.testing.expectEqual(0, a.free.items.len);
    try std.testing.expectError(error.OutOfMemory, a.alloc(gpa, 65 * page_size));
}
