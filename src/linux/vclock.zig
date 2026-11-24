//! The amd64 vDSO's clock: `clock_gettime`, `gettimeofday`, and
//! `time` that read the time without a syscall, as Linux's vDSO does, so
//! Go and glibc, which read the clock constantly, don't trap to h9 for
//! each read.
//!
//! A program gets two pages: the vDSO, an ELF shared object (elf.vdsoBuild)
//! whose functions are the code below, and the page before it, the clock
//! page (Linux's vvar), which h9 writes and the program can only read.
//! The clock page holds a line through the CPU's time stamp counter:
//! monotonic ns = mono_base + (tsc - tsc_base) * mult / 2^32, and real
//! time is that plus real_off, under a sequence count the functions retry
//! on, as Linux's vvar has. A clock the page doesn't cover (the CPU-time
//! ones), or a page not yet ready, falls back to the syscall.
//!
//! It needs a backend whose guest `rdtsc` reads the host's own count
//! (vmm.Backend.hostTsc), and a host whose count is invariant: then h9
//! reads the same count the program does. On other backends (the
//! emulators, whose `rdtsc` counts instructions) a program gets no vDSO,
//! as before.
//!
//! The line is h9's for its whole life, one for every program, and its
//! clock page is one per backend, mapped into each program's address
//! space (mm.Mm.insertFile). It's fitted to the host's clocks as Linux
//! programs make syscalls (`tick`): the rate is measured over all the
//! time since the first sample, and each fit starts where the last line
//! is, never going back, and slews toward the host's monotonic clock,
//! at most `max_slew` ns per s, so the line stays within a few
//! microseconds of it. The Linux layer's own clock calls read the same line (`monoNs`,
//! `wallNs`), so a program that mixes the vDSO and syscalls sees one
//! clock.

const std = @import("std");
const builtin = @import("builtin");
const kern = @import("../kern.zig");
const vmm = @import("../vmm.zig");
const mm = @import("mm.zig");
const elf = @import("elf.zig");
const web = @import("../web.zig");
const gpa = web.gpa;

const page = vmm.page_size;
const is_x86 = builtin.cpu.arch == .x86_64;

/// The clock page's layout. The vDSO's code reads it at these offsets.
pub const Vvar = extern struct {
    /// Odd while h9 is writing the rest.
    seq: u32 = 0,
    /// Zero until the first fit: the vDSO makes syscalls until then.
    ready: u32 = 0,
    tsc_base: u64 = 0,
    /// ns per count, times 2^32.
    mult: u64 = 0,
    mono_base: i64 = 0,
    /// Real time minus monotonic time.
    real_off: i64 = 0,
};

comptime {
    std.debug.assert(@offsetOf(Vvar, "tsc_base") == 8 and @offsetOf(Vvar, "mult") == 16 and
        @offsetOf(Vvar, "mono_base") == 24 and @offsetOf(Vvar, "real_off") == 32);
}

/// Where the code goes in the vDSO's page, and its functions there.
const code_off = 0x400;
const off_clock_gettime = 0x400;
const off_gettimeofday = 0x443;
const off_time = 0x480;

/// The vDSO's code, assembled as if at `code_off`; the clock page is the
/// page before. Leaf functions with the C ABI; `readns` uses r8-r11, which
/// it may clobber, and no stack beyond its return address.
const code = [_]u8{
    // clock_gettime, at 0x400
    0x83, 0xff, 0x1f, // cmp edi,0x1f
    0x77, 0x36, // ja 0x43b
    0x41, 0xb9, 0x21, 0x09, 0x00, 0x00, // mov r9d,0x921
    0x41, 0x0f, 0xa3, 0xf9, // bt r9d,edi
    0x41, 0x0f, 0x92, 0xc1, // setb r9b
    0xb8, 0xf3, 0x0b, 0x00, 0x00, // mov eax,0xbf3
    0x0f, 0xa3, 0xf8, // bt eax,edi
    0x73, 0x1e, // jae 0x43b
    0xe8, 0x86, 0x00, 0x00, 0x00, // call 0x4a8
    0x48, 0x85, 0xc0, // test rax,rax
    0x78, 0x14, // js 0x43b
    0x31, 0xd2, // xor edx,edx
    0xb9, 0x00, 0xca, 0x9a, 0x3b, // mov ecx,0x3b9aca00
    0x48, 0xf7, 0xf1, // div rcx
    0x48, 0x89, 0x06, // mov qword [rsi],rax
    0x48, 0x89, 0x56, 0x08, // mov qword [rsi+0x8],rdx
    0x31, 0xc0, // xor eax,eax
    0xc3, // ret
    0xb8, 0xe4, 0x00, 0x00, 0x00, // mov eax,0xe4
    0x0f, 0x05, // syscall
    0xc3, // ret
    // gettimeofday, at 0x443
    0x48, 0x85, 0xf6, // test rsi,rsi
    0x75, 0x30, // jne 0x478
    0x48, 0x85, 0xff, // test rdi,rdi
    0x74, 0x28, // je 0x475
    0x41, 0xb1, 0x01, // mov r9b,0x1
    0xe8, 0x53, 0x00, 0x00, 0x00, // call 0x4a8
    0x48, 0x85, 0xc0, // test rax,rax
    0x78, 0x1e, // js 0x478
    0x31, 0xd2, // xor edx,edx
    0xb9, 0xe8, 0x03, 0x00, 0x00, // mov ecx,0x3e8
    0x48, 0xf7, 0xf1, // div rcx
    0x31, 0xd2, // xor edx,edx
    0xb9, 0x40, 0x42, 0x0f, 0x00, // mov ecx,0xf4240
    0x48, 0xf7, 0xf1, // div rcx
    0x48, 0x89, 0x07, // mov qword [rdi],rax
    0x48, 0x89, 0x57, 0x08, // mov qword [rdi+0x8],rdx
    0x31, 0xc0, // xor eax,eax
    0xc3, // ret
    0xb8, 0x60, 0x00, 0x00, 0x00, // mov eax,0x60
    0x0f, 0x05, // syscall
    0xc3, // ret
    // time, at 0x480
    0x41, 0xb1, 0x01, // mov r9b,0x1
    0xe8, 0x20, 0x00, 0x00, 0x00, // call 0x4a8
    0x48, 0x85, 0xc0, // test rax,rax
    0x78, 0x13, // js 0x4a0
    0x31, 0xd2, // xor edx,edx
    0xb9, 0x00, 0xca, 0x9a, 0x3b, // mov ecx,0x3b9aca00
    0x48, 0xf7, 0xf1, // div rcx
    0x48, 0x85, 0xff, // test rdi,rdi
    0x74, 0x03, // je 0x49f
    0x48, 0x89, 0x07, // mov qword [rdi],rax
    0xc3, // ret
    0xb8, 0xc9, 0x00, 0x00, 0x00, // mov eax,0xc9
    0x0f, 0x05, // syscall
    0xc3, // ret
    // readns, at 0x4a8
    0x4c, 0x8d, 0x05, 0x51, 0xeb, 0xff, 0xff, // lea r8,[rip-0x14af] ; the page before
    0x45, 0x8b, 0x10, // mov r10d,dword [r8]
    0x41, 0xf7, 0xc2, 0x01, 0x00, 0x00, 0x00, // test r10d,0x1
    0x75, 0x38, // jne 0x4f3
    0x41, 0x8b, 0x40, 0x04, // mov eax,dword [r8+0x4]
    0x85, 0xc0, // test eax,eax
    0x74, 0x34, // je 0x4f7
    0x0f, 0xae, 0xe8, // lfence
    0x0f, 0x31, // rdtsc
    0x48, 0xc1, 0xe2, 0x20, // shl rdx,0x20
    0x48, 0x09, 0xd0, // or rax,rdx
    0x49, 0x2b, 0x40, 0x08, // sub rax,qword [r8+0x8]
    0x73, 0x02, // jae 0x4d7
    0x31, 0xc0, // xor eax,eax
    0x49, 0xf7, 0x60, 0x10, // mul qword [r8+0x10]
    0x48, 0x0f, 0xac, 0xd0, 0x20, // shrd rax,rdx,0x20
    0x49, 0x03, 0x40, 0x18, // add rax,qword [r8+0x18]
    0x45, 0x84, 0xc9, // test r9b,r9b
    0x74, 0x04, // je 0x4ed
    0x49, 0x03, 0x40, 0x20, // add rax,qword [r8+0x20]
    0x45, 0x3b, 0x10, // cmp r10d,dword [r8]
    0x75, 0xbd, // jne 0x4af
    0xc3, // ret
    0xf3, 0x90, // pause
    0xeb, 0xb8, // jmp 0x4af
    0x48, 0xc7, 0xc0, 0xff, 0xff, 0xff, 0xff, // mov rax,0xffffffffffffffff
    0xc3, // ret
};

/// The amd64 vDSO image, the symbols glibc, musl and Go look up, at
/// version LINUX_2.6.
pub fn image() [page]u8 {
    return elf.vdsoBuild(62, "LINUX_2.6", &.{
        .{ .name = "__vdso_clock_gettime", .off = off_clock_gettime, .size = off_gettimeofday - off_clock_gettime },
        .{ .name = "__vdso_gettimeofday", .off = off_gettimeofday, .size = off_time - off_gettimeofday },
        .{ .name = "__vdso_time", .off = off_time, .size = 0x28 },
    }, code_off, &code);
}

/// The most the line slews toward the host's clock, in ns per s: 500
/// ppm, as adjtime's.
const max_slew = 500_000;
/// How long the first fit measures the rate over, at least.
const first_fit_ns = 20 * std.time.ns_per_ms;
/// Fits after the first, about this far apart.
const fit_ns = std.time.ns_per_s / 2;

/// The line h9 itself reads, the same as every clock page's.
var line: Vvar = .{};
/// Held to fit and to add a clock page.
var lock: std.atomic.Mutex = .unlocked;
/// The count at which the next fit is due.
var next_fit: web.Atomic(u64) = .init(std.math.maxInt(u64));
/// The first sample, the rate's base.
var t0: u64 = 0;
var m0: i64 = 0;

const Page = struct { backend: usize, pages: *mm.Pages };
var clock_pages: std.ArrayListUnmanaged(Page) = .empty;

/// 0 not checked yet, 1 the host can, 2 it can't.
var host_ok: std.atomic.Value(u8) = .init(0);

fn rdtsc() u64 {
    return if (is_x86) rdtscX86() else 0;
}

fn rdtscX86() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("lfence; rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        :
        : .{ .memory = true });
    return @as(u64, hi) << 32 | lo;
}

/// Whether the host's count is invariant (CPUID.80000007H:EDX[8]): it
/// runs at one rate in every power state, on every CPU.
fn hostInvariant() bool {
    return is_x86 and hostInvariantX86();
}

fn hostInvariantX86() bool {
    const v = host_ok.load(.acquire);
    if (v != 0) return v == 1;
    const ok = cpuidEax(0x80000000) >= 0x80000007 and cpuidEdx(0x80000007) & (1 << 8) != 0;
    host_ok.store(if (ok) 1 else 2, .release);
    return ok;
}

fn cpuidEax(leaf: u32) u32 {
    return asm volatile ("cpuid"
        : [a] "={eax}" (-> u32),
        : [leaf] "{eax}" (leaf),
          [sub] "{ecx}" (@as(u32, 0)),
        : .{ .ebx = true, .ecx = true, .edx = true });
}

fn cpuidEdx(leaf: u32) u32 {
    return asm volatile ("cpuid"
        : [d] "={edx}" (-> u32),
        : [leaf] "{eax}" (leaf),
          [sub] "{ecx}" (@as(u32, 0)),
        : .{ .eax = true, .ebx = true, .ecx = true });
}

/// Whether programs on `backend` get the vDSO's clock.
pub fn supported(backend: vmm.Backend) bool {
    return backend.hostTsc() and hostInvariant();
}

fn backendId(b: vmm.Backend) usize {
    return switch (b) {
        inline else => |p| @intFromPtr(p),
    };
}

fn lockSpin() void {
    while (!lock.tryLock()) std.atomic.spinLoopHint();
}

/// The clock page's pages for `backend` (a chunk, the page at its start),
/// with a reference for the caller, for mm.Mm.insertFile.
pub fn pagesFor(backend: vmm.Backend, _: u64) mm.Error!*mm.Pages {
    lockSpin();
    defer lock.unlock();
    const id = backendId(backend);
    const p = for (clock_pages.items) |cp| {
        if (cp.backend == id) break cp.pages;
    } else blk: {
        const mem = backend.allocPages(mm.pages_per_chunk) catch return error.NoSpace;
        errdefer backend.freePages(mem);
        const p = try gpa.create(mm.Pages);
        errdefer gpa.destroy(p);
        // The list's reference, dropped with the backend (`forget`).
        p.* = .{ .mem = mem, .release = released };
        try clock_pages.append(gpa, .{ .backend = id, .pages = p });
        vvarOf(p).* = line;
        if (t0 == 0) {
            // The first sample. Fits are tried from 10^7 counts on, and
            // every 10^6 after, until first_fit_ns has passed.
            const first = sample();
            t0 = first.t;
            m0 = first.m;
            next_fit.store(t0 + 10_000_000, .release);
        }
        break :blk p;
    };
    _ = p.refs.fetchAdd(1, .acq_rel);
    return p;
}

/// mm.Pages.release: the list keeps its reference, so they stay.
fn released(p: *mm.Pages) void {
    _ = p.pending.fetchSub(1, .acq_rel);
}

fn vvarOf(p: *mm.Pages) *volatile Vvar {
    return @ptrCast(@alignCast(p.mem.ptr));
}

/// Fits the line, if a fit is due. Cheap otherwise: a count read.
pub fn tick() void {
    if (!is_x86) return;
    if (rdtsc() < next_fit.load(.acquire)) return;
    if (!lock.tryLock()) return;
    defer lock.unlock();
    if (rdtsc() < next_fit.load(.acquire)) return;
    fit();
}

/// The line at count `t`.
fn at(v: Vvar, t: u64) i64 {
    const d = t -| v.tsc_base;
    const ns: u64 = @truncate((@as(u128, d) * v.mult) >> 32);
    return v.mono_base +% @as(i64, @bitCast(ns));
}

const Sample = struct { t: u64, m: i64, w: i64 };

/// The host's clocks at a count: the count halfway between reads on
/// either side of them, the best of a few tries, so a thread preempted
/// between the reads doesn't skew the rate.
fn sample() Sample {
    var best: Sample = undefined;
    var best_gap: u64 = std.math.maxInt(u64);
    for (0..5) |_| {
        const ta = rdtsc();
        const m = kern.monoNs();
        const w = kern.wallNs();
        const gap = rdtsc() -% ta;
        if (gap < best_gap) {
            best_gap = gap;
            best = .{ .t = ta + gap / 2, .m = m, .w = w };
        }
    }
    return best;
}

fn fit() void {
    const s = sample();
    const dm = s.m - m0;
    if (dm < first_fit_ns) {
        next_fit.store(s.t + 1_000_000, .release);
        return;
    }
    // Counts per ns, over all the time since the first sample.
    const hz: f64 = @as(f64, @floatFromInt(s.t - t0)) / @as(f64, @floatFromInt(dm));
    var n = line;
    if (n.ready == 0) {
        n.mono_base = s.m;
        n.mult = @intFromFloat(4294967296.0 / hz);
    } else {
        // Start where the line is now, and slew toward the host's clock
        // by the next fit, at most max_slew.
        const was = at(n, s.t);
        const lim = max_slew * fit_ns / std.time.ns_per_s;
        const err = std.math.clamp(s.m - was, -lim, lim);
        // A host clock far ahead (the host slept) is stepped to.
        n.mono_base = if (s.m - was > std.time.ns_per_ms) s.m else was;
        const ratio = @as(f64, @floatFromInt(fit_ns + err)) / @as(f64, fit_ns);
        n.mult = @intFromFloat(ratio * 4294967296.0 / hz);
    }
    n.tsc_base = s.t;
    n.real_off = s.w - s.m;
    n.ready = 1;
    publish(n);
    next_fit.store(s.t + @as(u64, @intFromFloat(hz * fit_ns)), .release);
}

/// Writes `n` to h9's line and every clock page, under their counts.
fn publish(n: Vvar) void {
    const s = line.seq;
    @atomicStore(u32, &line.seq, s +% 1, .release);
    for (clock_pages.items) |cp| @atomicStore(u32, &vvarOf(cp.pages).seq, s +% 1, .release);
    var v = n;
    v.seq = s +% 1;
    // The fields with the count odd, then the count even again: x86
    // keeps stores in order, so a reader that sees the even count sees
    // the fields.
    writeFields(&line, v);
    for (clock_pages.items) |cp| writeFields(vvarOf(cp.pages), v);
    @atomicStore(u32, &line.seq, s +% 2, .release);
    for (clock_pages.items) |cp| @atomicStore(u32, &vvarOf(cp.pages).seq, s +% 2, .release);
}

fn writeFields(dst: anytype, v: Vvar) void {
    @atomicStore(u32, &dst.ready, v.ready, .release);
    @atomicStore(u64, &dst.tsc_base, v.tsc_base, .release);
    @atomicStore(u64, &dst.mult, v.mult, .release);
    @atomicStore(i64, &dst.mono_base, v.mono_base, .release);
    @atomicStore(i64, &dst.real_off, v.real_off, .release);
}

/// h9's line, once fitted, read as the vDSO reads it.
fn read(real: bool) ?i64 {
    if (!is_x86) return null;
    while (true) {
        const s = @atomicLoad(u32, &line.seq, .acquire);
        if (s & 1 != 0) {
            std.atomic.spinLoopHint();
            continue;
        }
        if (@atomicLoad(u32, &line.ready, .acquire) == 0) return null;
        const v: Vvar = .{
            .tsc_base = @atomicLoad(u64, &line.tsc_base, .acquire),
            .mult = @atomicLoad(u64, &line.mult, .acquire),
            .mono_base = @atomicLoad(i64, &line.mono_base, .acquire),
            .real_off = @atomicLoad(i64, &line.real_off, .acquire),
        };
        const ns = at(v, rdtsc()) + if (real) v.real_off else 0;
        if (@atomicLoad(u32, &line.seq, .acquire) == s) return ns;
    }
}

/// Monotonic time, as Linux programs see it: the line, once fitted, or
/// the kernel's.
pub fn monoNs() i64 {
    tick();
    return read(false) orelse kern.monoNs();
}

/// Real time, as Linux programs see it.
pub fn wallNs() i64 {
    tick();
    return read(true) orelse kern.wallNs();
}

/// Drops `backend`'s clock page, before the backend goes: no Mm maps it
/// any more.
pub fn forget(backend: vmm.Backend) void {
    lockSpin();
    defer lock.unlock();
    const id = backendId(backend);
    for (clock_pages.items, 0..) |cp, i| {
        if (cp.backend != id) continue;
        _ = clock_pages.swapRemove(i);
        backend.freePages(cp.pages.mem);
        gpa.destroy(cp.pages);
        return;
    }
}

/// A symbol's value in a vDSO image, by its DT_HASH, as Go's lookup
/// walks it.
fn lookup(img: []const u8, name: []const u8) ?u64 {
    const dyn_ph = img[64 + 56 ..][0..56];
    var d = std.mem.readInt(u64, dyn_ph[16..24], .little);
    var hash: usize = 0;
    var strtab: usize = 0;
    var symtab: usize = 0;
    while (true) : (d += 16) {
        const tag = std.mem.readInt(u64, img[d..][0..8], .little);
        const val: usize = @intCast(std.mem.readInt(u64, img[d + 8 ..][0..8], .little));
        switch (tag) {
            0 => break,
            4 => hash = val,
            5 => strtab = val,
            6 => symtab = val,
            else => {},
        }
    }
    const nbucket = std.mem.readInt(u32, img[hash..][0..4], .little);
    const h = elfHashOf(name);
    var i = std.mem.readInt(u32, img[hash + 8 + 4 * (h % nbucket) ..][0..4], .little);
    const chain = hash + 8 + 4 * nbucket;
    while (i != 0) : (i = std.mem.readInt(u32, img[chain + 4 * i ..][0..4], .little)) {
        const s = symtab + 24 * i;
        const n = std.mem.readInt(u32, img[s..][0..4], .little);
        if (std.mem.eql(u8, std.mem.sliceTo(img[strtab + n ..], 0), name)) return std.mem.readInt(u64, img[s + 8 ..][0..8], .little);
    }
    return null;
}

fn elfHashOf(name: []const u8) u32 {
    var h: u32 = 0;
    for (name) |ch| {
        h = (h << 4) +% ch;
        const g = h & 0xf0000000;
        if (g != 0) h ^= g >> 24;
        h &= ~g;
    }
    return h;
}

test "amd64 vDSO exports its clock" {
    const img = image();
    try std.testing.expectEqual(@as(?u64, off_clock_gettime), lookup(&img, "__vdso_clock_gettime"));
    try std.testing.expectEqual(@as(?u64, off_gettimeofday), lookup(&img, "__vdso_gettimeofday"));
    try std.testing.expectEqual(@as(?u64, off_time), lookup(&img, "__vdso_time"));
    try std.testing.expectEqual(@as(?u64, null), lookup(&img, "__vdso_getcpu"));
    // The functions start where the code says.
    try std.testing.expectEqual(@as(u8, 0x83), img[off_clock_gettime]); // cmp edi, 31
    try std.testing.expectEqual(@as(u8, 0x48), img[off_gettimeofday]); // test rsi, rsi
    try std.testing.expectEqual(@as(u8, 0x41), img[off_time]); // mov r9b, 1
}

test "the line at a count" {
    const v: Vvar = .{ .tsc_base = 1000, .mult = 1 << 31, .mono_base = 5 };
    try std.testing.expectEqual(@as(i64, 5), at(v, 1000));
    try std.testing.expectEqual(@as(i64, 505), at(v, 2000));
    // A count behind the base reads as the base.
    try std.testing.expectEqual(@as(i64, 5), at(v, 10));
    // A product past 64 bits.
    const big: Vvar = .{ .tsc_base = 0, .mult = 3 << 32, .mono_base = 0 };
    try std.testing.expectEqual(@as(i64, 3 << 40), at(big, 1 << 40));
}

test "amd64 vDSO code reads the clock page" {
    if (!is_x86 or builtin.os.tag != .linux) return error.SkipZigTest;
    const linux = std.os.linux;
    const mem = try std.posix.mmap(null, 2 * page, .{ .READ = true, .WRITE = true, .EXEC = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    defer std.posix.munmap(mem);
    const img = image();
    @memcpy(mem[page..][0..page], &img);
    const vv: *volatile Vvar = @ptrCast(@alignCast(mem.ptr));
    const Timespec = extern struct { sec: i64, nsec: i64 };
    const Timeval = extern struct { sec: i64, usec: i64 };
    const cg: *const fn (i32, *Timespec) callconv(.c) i64 = @ptrCast(mem.ptr + page + off_clock_gettime);
    const gtod: *const fn (?*Timeval, ?*anyopaque) callconv(.c) i64 = @ptrCast(mem.ptr + page + off_gettimeofday);
    const tm: *const fn (?*i64) callconv(.c) i64 = @ptrCast(mem.ptr + page + off_time);

    // Not ready: the syscall, which answers with the host's clock.
    var ts: Timespec = undefined;
    try std.testing.expectEqual(@as(i64, 0), cg(1, &ts));
    var hts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &hts);
    try std.testing.expect(@abs(hts.sec - ts.sec) <= 1);

    // Ready: a line one ns per count, from now, at 100 s monotonic, real
    // time 1000 s ahead.
    const now = rdtsc();
    vv.* = .{ .ready = 1, .tsc_base = now, .mult = 1 << 32, .mono_base = 100 * std.time.ns_per_s, .real_off = 1000 * std.time.ns_per_s };
    try std.testing.expectEqual(@as(i64, 0), cg(1, &ts)); // MONOTONIC
    const elapsed: i64 = @intCast(rdtsc() - now);
    const got = ts.sec * std.time.ns_per_s + ts.nsec;
    try std.testing.expect(got >= 100 * std.time.ns_per_s and got <= 100 * std.time.ns_per_s + elapsed);
    try std.testing.expectEqual(@as(i64, 0), cg(0, &ts)); // REALTIME
    try std.testing.expectEqual(@as(i64, 1100), ts.sec);
    try std.testing.expectEqual(@as(i64, 0), cg(7, &ts)); // BOOTTIME
    try std.testing.expectEqual(@as(i64, 100), ts.sec);
    try std.testing.expectEqual(@as(i64, 0), cg(5, &ts)); // REALTIME_COARSE
    try std.testing.expectEqual(@as(i64, 1100), ts.sec);
    // PROCESS_CPUTIME_ID isn't the line's: the syscall's, small.
    try std.testing.expectEqual(@as(i64, 0), cg(2, &ts));
    try std.testing.expect(ts.sec < 100);
    // An unknown clock: the syscall's EINVAL.
    try std.testing.expectEqual(@as(i64, -22), cg(99, &ts));
    // A negative id is a CPU clock or a clock fd. -1000 named pid 124's
    // CPU clock, which a host with many CPUs has (a kworker), so the
    // syscall answered 0. An fd clock on a closed fd is EINVAL anywhere.
    const closed_fd_clock: i32 = (~@as(i32, 999_999) << 3) | 3;
    try std.testing.expectEqual(@as(i64, -22), cg(closed_fd_clock, &ts));

    var tv: Timeval = undefined;
    try std.testing.expectEqual(@as(i64, 0), gtod(&tv, null));
    try std.testing.expectEqual(@as(i64, 1100), tv.sec);
    try std.testing.expect(tv.usec >= 0 and tv.usec < 1000000);
    try std.testing.expectEqual(@as(i64, 0), gtod(null, null));

    var t: i64 = 0;
    try std.testing.expectEqual(@as(i64, 1100), tm(&t));
    try std.testing.expectEqual(@as(i64, 1100), t);
    try std.testing.expectEqual(@as(i64, 1100), tm(null));

    // A line whose count is odd is being written: a reader waits, so
    // only check that an even one is read again after a change.
    vv.mono_base = 200 * std.time.ns_per_s;
    vv.seq = 2;
    try std.testing.expectEqual(@as(i64, 0), cg(1, &ts));
    try std.testing.expectEqual(@as(i64, 200), ts.sec);
}
