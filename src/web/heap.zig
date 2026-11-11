//! h9's allocator on the web host: std.heap.BrkAllocator (Zig's, MIT),
//! whose wasm memory comes in steps of at least `grow_step` instead of a
//! grow per run of 64 KiB pages. V8 runs a full GC on every memory.grow
//! once the memory is large (its old buffer is external memory until
//! then), a few ms each at a GiB: Claude Code's `--version` grew it about
//! 900 times. main.zig makes this std.heap.page_allocator on the web host,
//! and the vmm's allocations use it (`vmm.host_gpa`). wasi-libc's malloc
//! still takes std's.
const builtin = @import("builtin");

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const assert = std.debug.assert;
const math = std.math;

comptime {
    if (!builtin.single_threaded) @compileError("unsupported");
}

pub const allocator: Allocator = .{ .ptr = undefined, .vtable = &vtable };

/// Memory grown but not yet handed out, from `reserve` to `reserve_end`.
var reserve: usize = 0;
var reserve_end: usize = 0;
const grow_step = 32 << 20;

const State = struct {
    next_addrs: [size_class_count]usize = @splat(0),
    /// For each size class, points to the freed pointer.
    frees: [size_class_count]usize = @splat(0),
    /// For each big size class, points to the freed pointer.
    big_frees: [big_size_class_count]usize = @splat(0),
};

var global: State = .{};

pub const vtable: Allocator.VTable = .{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

pub const Error = Allocator.Error;

const max_usize = math.maxInt(usize);
const ushift = math.Log2Int(usize);
const bigpage_size: comptime_int = @max(64 * 1024, std.heap.page_size_max);
const bigpage_count = max_usize / bigpage_size;

/// Because of storing free list pointers, the minimum size class is 3.
const min_class = math.log2(math.ceilPowerOfTwoAssert(usize, 1 + @sizeOf(usize)));
const size_class_count = math.log2(bigpage_size) - min_class;
/// 0 - 1 bigpage
/// 1 - 2 bigpages
/// 2 - 4 bigpages
/// etc.
const big_size_class_count = math.log2(bigpage_count);

fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, return_address: usize) ?[*]u8 {
    _ = ctx;
    _ = return_address;
    // Make room for the freelist next pointer.
    const actual_len = @max(len +| @sizeOf(usize), alignment.toByteUnits());
    const slot_size = math.ceilPowerOfTwo(usize, actual_len) catch return null;
    const class = math.log2(slot_size) - min_class;
    if (class < size_class_count) {
        const addr = a: {
            const top_free_ptr = global.frees[class];
            if (top_free_ptr != 0) {
                const node: *usize = @ptrFromInt(top_free_ptr + (slot_size - @sizeOf(usize)));
                global.frees[class] = node.*;
                break :a top_free_ptr;
            }

            const next_addr = global.next_addrs[class];
            if (next_addr % bigpage_size == 0) {
                const addr = allocBigPages(1);
                if (addr == 0) return null;
                //std.debug.print("allocated fresh slot_size={d} class={d} addr=0x{x}\n", .{
                //    slot_size, class, addr,
                //});
                global.next_addrs[class] = addr + slot_size;
                break :a addr;
            } else {
                global.next_addrs[class] = next_addr + slot_size;
                break :a next_addr;
            }
        };
        return @ptrFromInt(addr);
    }
    const bigpages_needed = bigPagesNeeded(actual_len);
    return @ptrFromInt(allocBigPages(bigpages_needed));
}

fn resize(
    ctx: *anyopaque,
    buf: []u8,
    alignment: Alignment,
    new_len: usize,
    return_address: usize,
) bool {
    _ = ctx;
    _ = return_address;
    // We don't want to move anything from one size class to another, but we
    // can recover bytes in between powers of two.
    const buf_align = alignment.toByteUnits();
    const old_actual_len = @max(buf.len + @sizeOf(usize), buf_align);
    const new_actual_len = @max(new_len +| @sizeOf(usize), buf_align);
    const old_small_slot_size = math.ceilPowerOfTwoAssert(usize, old_actual_len);
    const old_small_class = math.log2(old_small_slot_size) - min_class;
    if (old_small_class < size_class_count) {
        const new_small_slot_size = math.ceilPowerOfTwo(usize, new_actual_len) catch return false;
        return old_small_slot_size == new_small_slot_size;
    } else {
        const old_bigpages_needed = bigPagesNeeded(old_actual_len);
        const old_big_slot_pages = math.ceilPowerOfTwoAssert(usize, old_bigpages_needed);
        const new_bigpages_needed = bigPagesNeeded(new_actual_len);
        const new_big_slot_pages = math.ceilPowerOfTwo(usize, new_bigpages_needed) catch return false;
        return old_big_slot_pages == new_big_slot_pages;
    }
}

fn remap(
    context: *anyopaque,
    memory: []u8,
    alignment: Alignment,
    new_len: usize,
    return_address: usize,
) ?[*]u8 {
    return if (resize(context, memory, alignment, new_len, return_address)) memory.ptr else null;
}

fn free(
    ctx: *anyopaque,
    buf: []u8,
    alignment: Alignment,
    return_address: usize,
) void {
    _ = ctx;
    _ = return_address;
    const buf_align = alignment.toByteUnits();
    const actual_len = @max(buf.len + @sizeOf(usize), buf_align);
    const slot_size = math.ceilPowerOfTwoAssert(usize, actual_len);
    const class = math.log2(slot_size) - min_class;
    const addr = @intFromPtr(buf.ptr);
    if (class < size_class_count) {
        const node: *usize = @ptrFromInt(addr + (slot_size - @sizeOf(usize)));
        node.* = global.frees[class];
        global.frees[class] = addr;
    } else {
        const bigpages_needed = bigPagesNeeded(actual_len);
        const pow2_pages = math.ceilPowerOfTwoAssert(usize, bigpages_needed);
        const big_slot_size_bytes = pow2_pages * bigpage_size;
        const node: *usize = @ptrFromInt(addr + (big_slot_size_bytes - @sizeOf(usize)));
        const big_class = math.log2(pow2_pages);
        node.* = global.big_frees[big_class];
        global.big_frees[big_class] = addr;
    }
}

inline fn bigPagesNeeded(byte_count: usize) usize {
    return (byte_count + (bigpage_size + (@sizeOf(usize) - 1))) / bigpage_size;
}

fn allocBigPages(n: usize) usize {
    const pow2_pages = math.ceilPowerOfTwoAssert(usize, n);
    const slot_size_bytes = pow2_pages * bigpage_size;
    const class = math.log2(pow2_pages);

    const top_free_ptr = global.big_frees[class];
    if (top_free_ptr != 0) {
        const node: *usize = @ptrFromInt(top_free_ptr + (slot_size_bytes - @sizeOf(usize)));
        global.big_frees[class] = node.*;
        return top_free_ptr;
    }

    const len = pow2_pages * bigpage_size;
    if (reserve_end - reserve < len) {
        const page_size = std.heap.page_size_max;
        const step = @max(len, grow_step);
        var got = step;
        var old = @wasmMemoryGrow(0, step / page_size);
        if (old == -1 and step != len) {
            got = len;
            old = @wasmMemoryGrow(0, len / page_size);
        }
        if (old == -1) return 0;
        const base = @as(usize, @intCast(old)) * page_size;
        // Past someone else's grow (the arena's), what was left goes.
        if (base != reserve_end) reserve = base;
        reserve_end = base + got;
    }
    const p = reserve;
    reserve += len;
    return p;
}
