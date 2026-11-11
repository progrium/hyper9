//! Executable memory for the JIT, W^X on every host.
//!
//! A `Region` is one block of code memory with two views: `rw` for the
//! emitter to write through and `rx` for the host to run. They are the same
//! physical pages, so a write through `rw` shows up at the same offset in
//! `rx` once `commit` has made it visible to instruction fetch.
//!
//! - macOS: one MAP_JIT mapping, so `rw` and `rx` are the same address. On
//!   arm64 writing is switched per thread with pthread_jit_write_protect_np
//!   (`beginWrite` turns writes on for the calling thread only, `commit`
//!   turns them off), then sys_icache_invalidate.
//! - Linux: a memfd mapped twice, RW and RX, so no page is ever writable and
//!   executable at the same address. arm64 cleans and invalidates the caches
//!   by hand (`dc cvau` / `ic ivau`, as unicorn.zig's clearCache does).
//!   Under a binary translator that misses writes through the other view
//!   (Rosetta or QEMU running x86_64 Linux on arm64), and only there, it
//!   falls back to one RWX mapping, which those translators watch. Native
//!   x86_64 is always dual; if the dual probe ever fails there, it's T0.
//! - Windows: a pagefile-backed section mapped twice, then
//!   FlushInstructionCache.
//!
//! Where none of this works (wasm, iOS without a debugger, a hardened macOS
//! build without the allow-jit entitlement, SELinux execmem denials, ACG on
//! Windows), `Region.init` fails with `error.JitUnavailable` and `available`
//! returns false, so the backend runs on T0 instead.
//!
//! The code cache bump-allocates from a region with `alloc` and throws
//! everything away with `reset`. Writing code is:
//!
//!     const off = region.alloc(code.len, 16) orelse ...; // full: reset
//!     region.beginWrite();
//!     @memcpy(region.writable(off, code.len), code);
//!     region.commit(off, code.len);
//!     const f: ctx.EntryFn = region.entry(off);
//!
//! `beginWrite`/`commit` pairs are per thread and must not nest. Rewriting
//! code that another thread may be running (patching a chain) is the code
//! cache's problem: the region only guarantees that the writing thread sees
//! its own writes after `commit`, and that other threads see them after
//! their next context synchronization (on arm64, the `isb` an exit to the
//! dispatcher does; on x86 it's coherent).

const std = @import("std");
const builtin = @import("builtin");
const ctx = @import("ctx.zig");

const os = builtin.os.tag;
const arch = builtin.cpu.arch;

pub const Error = error{ JitUnavailable, OutOfMemory };

/// Whether this target can generate code at all, before asking the OS.
pub const possible = switch (os) {
    .macos, .linux, .windows => arch == .aarch64 or arch == .x86_64,
    // iOS and friends only allow MAP_JIT under a debugger or with a private
    // entitlement; probing works there, so try.
    .ios, .tvos, .visionos => arch == .aarch64,
    else => false,
};

/// Regions are a multiple of this (Windows' allocation granularity, and a
/// multiple of every page size we run on).
pub const granule = 64 * 1024;

pub const Region = struct {
    /// Where code is written. Same as `rx` on macOS.
    rw: [*]u8,
    /// Where code runs.
    rx: [*]u8,
    len: usize,
    /// Bump pointer: bytes handed out by `alloc`.
    used: usize = 0,
    os_handle: Handle,
    /// Windows: the function table `addUnwind` registered, at the end of
    /// the mapping (beyond `len`), to remove at deinit.
    unwind: ?*const anyopaque = null,

    /// Maps `len` bytes (rounded up to `granule`) of code memory.
    pub fn init(len: usize) Error!Region {
        if (!available()) return error.JitUnavailable;
        const n = std.mem.alignForward(usize, @max(len, 1), granule);
        return host.map(n);
    }

    pub fn deinit(r: *Region) void {
        if (os == .windows) if (r.unwind) |t| {
            _ = windows.RtlDeleteFunctionTable(t);
        };
        host.unmap(r);
        r.* = undefined;
    }

    /// Windows x64: describes every function in the region to the OS
    /// unwinder (stack walks, and exceptions passing through generated
    /// code) with one UNWIND_INFO, `info`, that holds for all of them.
    /// It and the function table take the region's last 64 bytes, which
    /// `alloc` then never hands out. Call it once, before any `alloc`.
    /// Elsewhere it does nothing: other hosts walk frame pointers.
    pub fn addUnwind(r: *Region, info: []const u8) void {
        if (os != .windows or arch != .x86_64) return;
        std.debug.assert(r.used == 0 and info.len <= 48 and r.len > 64);
        const tail: u32 = @intCast(r.len - 64);
        // RUNTIME_FUNCTION: begin, end, and the UNWIND_INFO's address, as
        // offsets from the region's executable start.
        const table = [3]u32{ 0, tail, tail + 16 };
        r.beginWrite();
        @memcpy(r.rw[tail..][0..12], std.mem.sliceAsBytes(&table));
        @memcpy(r.rw[tail + 16 ..][0..info.len], info);
        r.commit(tail, 64);
        r.len = tail;
        const t: *const anyopaque = @ptrCast(r.rx + tail);
        if (windows.RtlAddFunctionTable(t, 1, @intFromPtr(r.rx)) != 0) r.unwind = t;
    }

    /// Reserves `size` bytes aligned to `alignment` (a power of two), or
    /// returns null when the region is full.
    pub fn alloc(r: *Region, size: usize, alignment: usize) ?u32 {
        const off = std.mem.alignForward(usize, r.used, alignment);
        if (off > r.len or size > r.len - off) return null;
        r.used = off + size;
        return @intCast(off);
    }

    /// Bytes left for `alloc`.
    pub fn free(r: *const Region) usize {
        return r.len - r.used;
    }

    /// Forgets every allocation. The caller makes sure no thread is running
    /// code from the region and nothing still points into it.
    pub fn reset(r: *Region) void {
        r.used = 0;
    }

    /// Makes the region writable from the calling thread. Pair with
    /// `commit` on the same thread.
    pub fn beginWrite(r: *Region) void {
        _ = r;
        host.writeEnable(true);
    }

    /// The writable view of `[off, off+len)`. Valid between `beginWrite` and
    /// `commit` (on Linux and Windows it's always writable, but code that
    /// skips `beginWrite` breaks on macOS).
    pub fn writable(r: *Region, off: u32, len: usize) []u8 {
        std.debug.assert(off + len <= r.len);
        return r.rw[off..][0..len];
    }

    /// Ends a write and makes `[off, off+len)` safe to execute on the
    /// calling thread. Cache maintenance covers only that range, so call it
    /// once per contiguous write (or once over the whole span written).
    pub fn commit(r: *Region, off: u32, len: usize) void {
        host.writeEnable(false);
        if (len == 0) return;
        std.debug.assert(off + len <= r.len);
        host.flush(r.rw + off, r.rx + off, len);
    }

    /// Writes `code` at `off` and commits it, for one-shot writes.
    pub fn write(r: *Region, off: u32, code: []const u8) void {
        r.beginWrite();
        @memcpy(r.writable(off, code.len), code);
        r.commit(off, code.len);
    }

    /// The executable address of `off`.
    pub fn exec(r: *const Region, off: u32) [*]const u8 {
        return r.rx + off;
    }

    /// `off` as a JIT entry point.
    pub fn entry(r: *const Region, off: u32) ctx.EntryFn {
        return @ptrCast(@alignCast(r.rx + off));
    }
};

/// Whether code generation works in this process: maps, writes, and runs a
/// tiny function once, then caches the answer. False means use T0.
pub fn available() bool {
    if (!possible) return false;
    const state = struct {
        var v = std.atomic.Value(u8).init(0); // 0 unknown, 1 no, 2 yes
    };
    switch (state.v.load(.acquire)) {
        1 => return false,
        2 => return true,
        else => {},
    }
    // Racing probes are harmless: they reach the same answer.
    const ok = host.detect();
    state.v.store(if (ok) 2 else 1, .release);
    return ok;
}

/// Maps a region straight from the host and checks that code written to it
/// runs, and that rewritten code runs rewritten.
fn probe() bool {
    var r = host.map(granule) catch return false;
    defer host.unmap(&r);
    const off = r.alloc(ret_const.len, 16) orelse return false;
    const f: *const fn () callconv(.c) u32 = @ptrCast(@alignCast(r.exec(off)));
    r.write(off, &retConst(0x5a));
    if (f() != 0x5a) return false;
    r.write(off, &retConst(0xa5));
    return f() == 0xa5;
}

/// A function returning `v` (16-bit) in the C return register.
const ret_const = retConst(0);
fn retConst(v: u16) [8]u8 {
    var b: [8]u8 = undefined;
    switch (arch) {
        .aarch64 => {
            std.mem.writeInt(u32, b[0..4], 0x52800000 | (@as(u32, v) << 5), .little); // movz w0, #v
            std.mem.writeInt(u32, b[4..8], 0xd65f03c0, .little); // ret
        },
        .x86_64 => {
            b[0] = 0xb8; // mov eax, imm32
            std.mem.writeInt(u32, b[1..5], v, .little);
            b[5] = 0xc3; // ret
            b[6] = 0xcc;
            b[7] = 0xcc;
        },
        else => @memset(&b, 0),
    }
    return b;
}

// ---------------------------------------------------------------------------
// Hosts

const Handle = switch (os) {
    .linux => i32, // the memfd
    .windows => ?*anyopaque, // the section
    else => void,
};

const host = if (!possible) unsupported else switch (os) {
    .linux => linux,
    .windows => windows,
    else => darwin,
};

const unsupported = struct {
    fn detect() bool {
        return false;
    }
    fn map(_: usize) Error!Region {
        return error.JitUnavailable;
    }
    fn unmap(_: *Region) void {}
    fn writeEnable(_: bool) void {}
    fn flush(_: [*]u8, _: [*]u8, _: usize) void {}
};

const darwin = struct {
    const MmapFn = fn (?*anyopaque, usize, c_int, c_int, c_int, i64) callconv(.c) ?*anyopaque;
    const prot_rwx = 7;
    const map_private = 0x2;
    const map_anon = 0x1000;
    const map_jit = 0x800;
    /// arm64 is the only Darwin arch with per-thread JIT write protection.
    const toggles = arch == .aarch64;

    extern "c" fn mmap(?*anyopaque, usize, c_int, c_int, c_int, i64) ?*anyopaque;
    extern "c" fn munmap(*anyopaque, usize) c_int;
    extern "c" fn pthread_jit_write_protect_np(c_int) void;
    extern "c" fn pthread_jit_write_protect_supported_np() c_int;
    extern "c" fn sys_icache_invalidate(*anyopaque, usize) void;

    const detect = probe;

    fn map(n: usize) Error!Region {
        if (toggles and pthread_jit_write_protect_supported_np() == 0) return error.JitUnavailable;
        // Without the allow-jit entitlement under the hardened runtime (or
        // on iOS without a debugger) this fails with EPERM.
        const p = mmap(null, n, prot_rwx, map_private | map_anon | map_jit, -1, 0);
        if (p == null or @intFromPtr(p) == std.math.maxInt(usize)) return error.JitUnavailable;
        const m: [*]u8 = @ptrCast(p.?);
        return .{ .rw = m, .rx = m, .len = n, .os_handle = {} };
    }

    fn unmap(r: *Region) void {
        _ = munmap(r.rx, r.len);
    }

    fn writeEnable(on: bool) void {
        if (toggles) pthread_jit_write_protect_np(if (on) 0 else 1);
    }

    fn flush(_: [*]u8, rx: [*]u8, len: usize) void {
        if (arch == .aarch64) sys_icache_invalidate(rx, len);
    }
};

const linux = struct {
    const L = std.os.linux;
    /// MFD_EXEC (Linux 6.3): asks for an executable memfd where
    /// vm.memfd_noexec would otherwise make it MFD_NOEXEC_SEAL. Older
    /// kernels reject it with EINVAL, so we retry without it.
    const mfd_exec = 0x0010;

    const Mode = enum { dual, rwx };
    /// Set by `detect` before any region is mapped through `Region.init`.
    var mode: Mode = .dual;

    /// Prefers the dual mapping. Binary translators that find self-modified
    /// code by write-protecting the pages they translated (Rosetta running
    /// x86_64 Linux in Docker on a Mac, QEMU user mode) don't see writes
    /// through the other view and keep running stale code, which the probe
    /// catches; there we fall back to one RWX mapping, which they handle.
    /// The fallback needs both the failed probe and a translated process,
    /// so native x86_64 never ends up RWX: a dual probe failing there is
    /// something else (a noexec memfd, SELinux), and T0 is the answer.
    fn detect() bool {
        mode = .dual;
        if (probe()) return true;
        if (!translated()) return false;
        mode = .rwx;
        return probe();
    }

    /// Whether this x86_64 process is running under a binary translator on
    /// an arm64 kernel. Rosetta and QEMU user mode both pass the host's
    /// /proc/cpuinfo through, and an arm64 kernel's has "CPU implementer"
    /// where an x86 one has "vendor_id" (hypervisors and gVisor keep
    /// "vendor_id"). The first processor's block is enough, so this reads
    /// 4 KiB. An unreadable /proc counts as native: W^X or T0, never RWX.
    fn translated() bool {
        const rc = L.open("/proc/cpuinfo", .{ .CLOEXEC = true }, 0);
        if (L.errno(rc) != .SUCCESS) return false;
        const fd: i32 = @intCast(rc);
        defer _ = L.close(fd);
        var buf: [4096]u8 = undefined;
        var n: usize = 0;
        while (n < buf.len) {
            const got = L.read(fd, buf[n..].ptr, buf.len - n);
            if (L.errno(got) != .SUCCESS or got == 0) break;
            n += got;
        }
        // arm64 under QEMU user mode on an x86 kernel (testing the arm64
        // emitter there) is the other way round.
        return if (arch == .x86_64) isArmCpuinfo(buf[0..n]) else isX86Cpuinfo(buf[0..n]);
    }

    fn map(n: usize) Error!Region {
        if (mode == .rwx) {
            const p = L.mmap(null, n, .{ .READ = true, .WRITE = true, .EXEC = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
            return switch (L.errno(p)) {
                .SUCCESS => .{ .rw = @ptrFromInt(p), .rx = @ptrFromInt(p), .len = n, .os_handle = -1 },
                .NOMEM => error.OutOfMemory,
                else => error.JitUnavailable,
            };
        }
        var rc = L.memfd_create("h9-jit", L.MFD.CLOEXEC | mfd_exec);
        if (L.errno(rc) == .INVAL) rc = L.memfd_create("h9-jit", L.MFD.CLOEXEC);
        if (L.errno(rc) != .SUCCESS) return error.JitUnavailable;
        const fd: i32 = @intCast(rc);
        errdefer _ = L.close(fd);
        switch (L.errno(L.ftruncate(fd, @intCast(n)))) {
            .SUCCESS => {},
            .NOMEM, .NOSPC, .FBIG => return error.OutOfMemory,
            else => return error.JitUnavailable,
        }
        const rw = L.mmap(null, n, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
        switch (L.errno(rw)) {
            .SUCCESS => {},
            .NOMEM => return error.OutOfMemory,
            else => return error.JitUnavailable,
        }
        errdefer _ = L.munmap(@ptrFromInt(rw), n);
        // SELinux's execmem/execmod or a noexec memfd fail here.
        const rx = L.mmap(null, n, .{ .READ = true, .EXEC = true }, .{ .TYPE = .SHARED }, fd, 0);
        switch (L.errno(rx)) {
            .SUCCESS => {},
            .NOMEM => return error.OutOfMemory,
            else => return error.JitUnavailable,
        }
        return .{ .rw = @ptrFromInt(rw), .rx = @ptrFromInt(rx), .len = n, .os_handle = fd };
    }

    fn unmap(r: *Region) void {
        _ = L.munmap(r.rx, r.len);
        if (r.rw == r.rx) return;
        _ = L.munmap(r.rw, r.len);
        _ = L.close(r.os_handle);
    }

    fn writeEnable(_: bool) void {}

    fn flush(rw: [*]u8, rx: [*]u8, len: usize) void {
        if (arch == .aarch64) clearCache(@intFromPtr(rw), @intFromPtr(rx), len);
    }

    /// Cleans the data cache by the written view and invalidates the
    /// instruction cache by the executed one (the I-cache may be indexed
    /// by virtual address, so it has to be the address that runs). Same
    /// sequence as unicorn.zig's clearCache, with its `dsb ish` after `ic ivau`.
    fn clearCache(rw: usize, rx: usize, len: usize) void {
        const ctr = asm volatile ("mrs %[ctr], ctr_el0"
            : [ctr] "=r" (-> u64),
        );
        // CTR_EL0.IDC: no clean to the point of unification needed.
        if ((ctr >> 28) & 1 == 0) {
            const line = @as(usize, 4) << @intCast((ctr >> 16) & 15);
            var a = rw & ~(line - 1);
            while (a < rw + len) : (a += line) asm volatile ("dc cvau, %[a]"
                :
                : [a] "r" (a),
                : .{ .memory = true });
        }
        asm volatile ("dsb ish" ::: .{ .memory = true });
        // CTR_EL0.DIC: no invalidation to the point of unification needed.
        if ((ctr >> 29) & 1 == 0) {
            const line = @as(usize, 4) << @intCast(ctr & 15);
            var a = rx & ~(line - 1);
            while (a < rx + len) : (a += line) asm volatile ("ic ivau, %[a]"
                :
                : [a] "r" (a),
                : .{ .memory = true });
            asm volatile ("dsb ish" ::: .{ .memory = true });
        }
        asm volatile ("isb sy" ::: .{ .memory = true });
    }
};

const windows = struct {
    const HANDLE = ?*anyopaque;
    const BOOL = c_int;
    const page_execute_readwrite = 0x40;
    const sec_commit = 0x8000000;
    const file_map_write = 0x2;
    const file_map_read = 0x4;
    const file_map_execute = 0x20;
    const invalid_handle: HANDLE = @ptrFromInt(std.math.maxInt(usize));

    extern "kernel32" fn CreateFileMappingW(HANDLE, ?*anyopaque, u32, u32, u32, ?[*:0]const u16) callconv(.winapi) HANDLE;
    extern "kernel32" fn MapViewOfFile(HANDLE, u32, u32, u32, usize) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn UnmapViewOfFile(?*const anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn CloseHandle(HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
    extern "kernel32" fn FlushInstructionCache(HANDLE, ?*const anyopaque, usize) callconv(.winapi) BOOL;
    extern "kernel32" fn RtlAddFunctionTable(?*const anyopaque, u32, u64) callconv(.winapi) u8;
    extern "kernel32" fn RtlDeleteFunctionTable(?*const anyopaque) callconv(.winapi) u8;

    fn map(n: usize) Error!Region {
        // The section's maximum protection has to allow execute so one view
        // can be RX; each view then asks for only what it needs, so no
        // address is ever both writable and executable. (MapViewOfFile3 is
        // only needed to place views; we don't care where they land.)
        const sec = CreateFileMappingW(invalid_handle, null, page_execute_readwrite | sec_commit, @intCast(n >> 32), @truncate(n), null) orelse
            return error.OutOfMemory;
        errdefer _ = CloseHandle(sec);
        const rw = MapViewOfFile(sec, file_map_read | file_map_write, 0, 0, n) orelse return error.OutOfMemory;
        errdefer _ = UnmapViewOfFile(rw);
        // Arbitrary Code Guard (dynamic code prohibited) fails here.
        const rx = MapViewOfFile(sec, file_map_read | file_map_execute, 0, 0, n) orelse return error.JitUnavailable;
        return .{ .rw = @ptrCast(rw), .rx = @ptrCast(rx), .len = n, .os_handle = sec };
    }

    fn unmap(r: *Region) void {
        _ = UnmapViewOfFile(r.rx);
        _ = UnmapViewOfFile(r.rw);
        _ = CloseHandle(r.os_handle);
    }

    const detect = probe;

    fn writeEnable(_: bool) void {}

    fn flush(_: [*]u8, rx: [*]u8, len: usize) void {
        _ = FlushInstructionCache(GetCurrentProcess(), rx, len);
    }
};

// ---------------------------------------------------------------------------
// Tests

const RetFn = *const fn () callconv(.c) u32;

fn call(r: *const Region, off: u32) u32 {
    const f: RetFn = @ptrCast(@alignCast(r.exec(off)));
    return f();
}

test "write, run, rewrite, and rerun" {
    if (!available()) return error.SkipZigTest;
    var r = try Region.init(1);
    defer r.deinit();
    try std.testing.expectEqual(@as(usize, granule), r.len);

    const a = r.alloc(ret_const.len, 16).?;
    const b = r.alloc(ret_const.len, 16).?;
    try std.testing.expect(b >= a + ret_const.len and b % 16 == 0);
    r.write(a, &retConst(42));
    r.write(b, &retConst(7));
    try std.testing.expectEqual(@as(u32, 42), call(&r, a));
    try std.testing.expectEqual(@as(u32, 7), call(&r, b));

    // Rewrite in place, run again: the stale instruction must not survive.
    var i: u16 = 0;
    while (i < 1000) : (i += 1) {
        r.write(a, &retConst(i));
        try std.testing.expectEqual(@as(u32, i), call(&r, a));
    }
    try std.testing.expectEqual(@as(u32, 7), call(&r, b));
}

test "W^X: the executable view isn't writable at the same address" {
    if (!available()) return error.SkipZigTest;
    var r = try Region.init(granule);
    defer r.deinit();
    switch (os) {
        // Two views of the same pages (unless Linux fell back to RWX under a
        // binary translator).
        .linux, .windows => if (os == .windows or linux.mode == .dual) {
            try std.testing.expect(r.rw != r.rx);
            r.write(0, &retConst(3));
            try std.testing.expectEqualSlices(u8, r.rw[0..8], r.rx[0..8]);
        },
        // One view, toggled per thread.
        else => try std.testing.expect(r.rw == r.rx),
    }
}

test "bump allocation fills the region, and reset empties it" {
    if (!available()) return error.SkipZigTest;
    var r = try Region.init(granule);
    defer r.deinit();
    try std.testing.expectEqual(@as(?u32, 0), r.alloc(3, 1));
    try std.testing.expectEqual(@as(?u32, 64), r.alloc(100, 64));
    try std.testing.expectEqual(@as(usize, granule - 164), r.free());
    try std.testing.expectEqual(@as(?u32, null), r.alloc(granule, 1));
    try std.testing.expect(r.alloc(granule - 164, 1) != null);
    try std.testing.expectEqual(@as(?u32, null), r.alloc(1, 1));
    r.reset();
    try std.testing.expectEqual(@as(?u32, 0), r.alloc(granule, 16));
}

test "fill a region with distinct functions, run all, reset, refill" {
    if (!available()) return error.SkipZigTest;
    var r = try Region.init(granule);
    defer r.deinit();
    for (0..2) |round| {
        r.reset();
        var n: u16 = 0;
        // One beginWrite/commit over the whole span, as a block batch would.
        r.beginWrite();
        while (r.alloc(ret_const.len, 8)) |off| : (n += 1)
            @memcpy(r.writable(off, ret_const.len), &retConst(n *% 3 +% @as(u16, @intCast(round))));
        r.commit(0, r.used);
        try std.testing.expectEqual(@as(u16, granule / 8), n);
        var i: u16 = 0;
        while (i < n) : (i += 1)
            try std.testing.expectEqual(@as(u32, i *% 3 +% @as(u16, @intCast(round))), call(&r, @as(u32, i) * 8));
    }
}

test "code written on one thread runs on another" {
    if (builtin.single_threaded or !available()) return error.SkipZigTest;
    var r = try Region.init(granule);
    defer r.deinit();
    const off = r.alloc(ret_const.len, 16).?;
    for (0..20) |k| {
        const T = struct {
            fn writer(reg: *Region, o: u32, v: u16) void {
                reg.write(o, &retConst(v));
            }
            fn runner(reg: *Region, o: u32, out: *u32) void {
                // The `isb` a real exit to the dispatcher does; thread start
                // already synchronizes, but be explicit like the runtime.
                if (arch == .aarch64) asm volatile ("isb sy" ::: .{ .memory = true });
                out.* = call(reg, o);
            }
        };
        const v: u16 = @intCast(100 + k);
        (try std.Thread.spawn(.{}, T.writer, .{ &r, off, v })).join();
        var got: u32 = 0;
        (try std.Thread.spawn(.{}, T.runner, .{ &r, off, &got })).join();
        try std.testing.expectEqual(@as(u32, v), got);
    }
}

/// Whether a /proc/cpuinfo prefix comes from an arm64 kernel.
fn isArmCpuinfo(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "CPU implementer") != null and
        std.mem.indexOf(u8, text, "vendor_id") == null;
}

fn isX86Cpuinfo(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "vendor_id") != null;
}

test "cpuinfo: arm64 kernels are translated hosts, x86 ones aren't" {
    try std.testing.expect(isArmCpuinfo("processor\t: 0\nBogoMIPS\t: 48.00\nFeatures\t: fp asimd\nCPU implementer\t: 0x61\n"));
    try std.testing.expect(!isArmCpuinfo("processor\t: 0\nvendor_id\t: GenuineIntel\nflags\t: fpu sse2\n"));
    try std.testing.expect(!isArmCpuinfo(""));
}

test "native x86_64 Linux uses the dual mapping" {
    if (os != .linux or arch != .x86_64 or !available()) return error.SkipZigTest;
    if (linux.translated()) return error.SkipZigTest;
    try std.testing.expectEqual(linux.Mode.dual, linux.mode);
}

test "the probe agrees with init" {
    if (!possible) {
        try std.testing.expect(!available());
        try std.testing.expectError(error.JitUnavailable, Region.init(granule));
        return;
    }
    if (available()) {
        var r = try Region.init(granule);
        r.deinit();
    }
}
