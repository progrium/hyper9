//! Test-only: makes emitted code callable. The real executable memory
//! (W^X, dual mapping, the code cache) is codemem.zig's job; this is just
//! enough for the emitters' tests and the tracer, on macOS arm64.

const std = @import("std");
const builtin = @import("builtin");
const ctx = @import("ctx.zig");

pub const supported = builtin.os.tag == .macos and builtin.cpu.arch == .aarch64;

const MmapFn = *const fn (?*anyopaque, usize, c_int, c_int, c_int, i64) callconv(.c) ?*anyopaque;
const MunmapFn = *const fn (*anyopaque, usize) callconv(.c) c_int;

pub const Exec = struct {
    mem: []u8,

    pub fn entry(x: Exec, offset: u32) ctx.EntryFn {
        return @ptrCast(@alignCast(x.mem.ptr + offset));
    }

    pub fn deinit(x: Exec) void {
        const munmap = @extern(MunmapFn, .{ .name = "munmap" });
        _ = munmap(x.mem.ptr, x.mem.len);
    }
};

pub fn load(code: []const u8) !Exec {
    if (!supported) return error.SkipZigTest;
    const mmap = @extern(MmapFn, .{ .name = "mmap" });
    const protect = @extern(*const fn (c_int) callconv(.c) void, .{ .name = "pthread_jit_write_protect_np" });
    const invalidate = @extern(*const fn (*anyopaque, usize) callconv(.c) void, .{ .name = "sys_icache_invalidate" });
    const len = std.mem.alignForward(usize, code.len, 16384);
    const p = mmap(null, len, 7, 0x1000 | 0x2 | 0x800, -1, 0); // RWX, MAP_ANON | MAP_PRIVATE | MAP_JIT
    if (p == null or @intFromPtr(p) == std.math.maxInt(usize)) return error.MapFailed;
    const m: [*]u8 = @ptrCast(p.?);
    protect(0);
    @memcpy(m[0..code.len], code);
    protect(1);
    invalidate(m, code.len);
    return .{ .mem = m[0..len] };
}
