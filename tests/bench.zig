//! The emulator speed benchmark behind SPEC.md's "Limits and selection":
//! a 2-instruction loop of 10⁹ iterations, 10⁶ one-byte pwrite round
//! trips, and 10⁶ _nsec calls (the cost of a system call itself), for
//! arm64 and amd64, and 10⁷ bare arm64 vCPU exits and re-entries (an SVC
//! that run returns, with no system call served) on every backend built in that can run them.
//! zig build bench builds it with ReleaseFast and runs it.
//!
//! Then the compute benchmarks (tests/bench/*.c: fib, sieve, md5, qsort,
//! and a double-precision loop), built as arm64 and 386 text by build.zig,
//! on every backend that runs them, and on the emulator once per tier (T0
//! and T1, through H9_EMU_TIER, with -Demu=zig). Each run's exit message is
//! its checksum, which must match the same C run natively.

const std = @import("std");
const h9 = @import("h9");
const vmm = h9.vmm;
const aout = h9.aout;

const loop_iters = 1_000_000_000;
const syscall_iters = 1_000_000;

/// Counts x0 down from 10⁹, then exits(nil).
const loop_arm64 = words(&.{
    0xd2994000, // mov  x0, #0xca00
    0xf2a77340, // movk x0, #0x3b9a, lsl #16
    0xf1000400, // subs x0, x0, #1
    0x54ffffe1, // b.ne .-4
    0xd10083ff, // sub  sp, sp, #32
    0xf90007ff, // str  xzr, [sp, #8]      nil
    0xd2800100, // mov  x0, #8             EXITS
    0xd4000001, // svc  #0
});

const loop_amd64 = [_]u8{
    0xb9, 0x00, 0xca, 0x9a, 0x3b, // movl  $1000000000, %ecx
    0x48, 0xff, 0xc9, // decq  %rcx
    0x75, 0xfb, // jne   .-3
    0x48, 0x83, 0xec, 0x20, // subq  $0x20, %rsp
    0x48, 0xc7, 0x44, 0x24, 0x08, 0x00, 0x00, 0x00, 0x00, // movq  $0, 8(%rsp)       nil
    0xbd, 0x08, 0x00, 0x00, 0x00, // movl  $8, %ebp           EXITS
    0x0f, 0x05, // syscall
};

/// pwrite(1, "x", 1, -1) 10⁶ times, then exits(nil).
const syscall_arm64 = words(&.{
    0xd100c3ff, // sub  sp, sp, #48
    0xd2884813, // mov  x19, #0x4240
    0xf2a001f3, // movk x19, #0xf, lsl #16
    // loop:
    0xd2800021, // mov  x1, #1
    0xf90007e1, // str  x1, [sp, #8]       fd
    0x100001a2, // adr  x2, msg
    0xf9000be2, // str  x2, [sp, #16]      buf
    0xd2800023, // mov  x3, #1
    0xf9000fe3, // str  x3, [sp, #24]      n
    0x92800004, // mov  x4, #-1
    0xf90013e4, // str  x4, [sp, #32]      offset
    0xd2800660, // mov  x0, #51            PWRITE
    0xd4000001, // svc  #0
    0xf1000673, // subs x19, x19, #1
    0x54fffea1, // b.ne loop
    0xf90007ff, // str  xzr, [sp, #8]      nil
    0xd2800100, // mov  x0, #8             EXITS
    0xd4000001, // svc  #0
}) ++ "x".*;

const syscall_amd64 = [_]u8{
    0x48, 0x83, 0xec, 0x30, // subq  $0x30, %rsp
    0x41, 0xbc, 0x40, 0x42, 0x0f, 0x00, // movl  $1000000, %r12d
    // loop:
    0x48, 0xc7, 0x44, 0x24, 0x08, 0x01, 0x00, 0x00, 0x00, // movq  $1, 8(%rsp)       fd
    0x48, 0x8d, 0x05, 0x33, 0x00, 0x00, 0x00, // leaq  msg(%rip), %rax
    0x48, 0x89, 0x44, 0x24, 0x10, // movq  %rax, 16(%rsp)     buf
    0x48, 0xc7, 0x44, 0x24, 0x18, 0x01, 0x00, 0x00, 0x00, // movq  $1, 24(%rsp)      n
    0x48, 0xc7, 0x44, 0x24, 0x20, 0xff, 0xff, 0xff, 0xff, // movq  $-1, 32(%rsp)     offset
    0xbd, 0x33, 0x00, 0x00, 0x00, // movl  $51, %ebp          PWRITE
    0x0f, 0x05, // syscall
    0x49, 0xff, 0xcc, // decq  %r12
    0x75, 0xcd, // jne   loop
    0x48, 0xc7, 0x44, 0x24, 0x08, 0x00, 0x00, 0x00, 0x00, // movq  $0, 8(%rsp)       nil
    0xbd, 0x08, 0x00, 0x00, 0x00, // movl  $8, %ebp           EXITS
    0x0f, 0x05, // syscall
    'x',
};

/// _nsec() 10⁶ times, then exits(nil): a system call that doesn't touch
/// the host beyond reading its clock, so the time is the emulator's exit
/// and re-entry.
const nsec_arm64 = words(&.{
    0xd100c3ff, // sub  sp, sp, #48
    0xd2884813, // mov  x19, #0x4240
    0xf2a001f3, // movk x19, #0xf, lsl #16
    // loop:
    0xd28006a0, // mov  x0, #53            _NSEC
    0xd4000001, // svc  #0
    0xf1000673, // subs x19, x19, #1
    0x54ffffa1, // b.ne loop
    0xf90007ff, // str  xzr, [sp, #8]      nil
    0xd2800100, // mov  x0, #8             EXITS
    0xd4000001, // svc  #0
});

const nsec_amd64 = [_]u8{
    0x48, 0x83, 0xec, 0x30, // subq  $0x30, %rsp
    0x41, 0xbc, 0x40, 0x42, 0x0f, 0x00, // movl  $1000000, %r12d
    // loop:
    0xbd, 0x35, 0x00, 0x00, 0x00, // movl  $53, %ebp          _NSEC
    0x0f, 0x05, // syscall
    0x49, 0xff, 0xcc, // decq  %r12
    0x75, 0xf4, // jne   loop
    0x48, 0xc7, 0x44, 0x24, 0x08, 0x00, 0x00, 0x00, 0x00, // movq  $0, 8(%rsp)       nil
    0xbd, 0x08, 0x00, 0x00, 0x00, // movl  $8, %ebp           EXITS
    0x0f, 0x05, // syscall
};

comptime {
    // adr's and leaq's displacements point at the trailing "x".
    // adr is at 0x14 with a +0x34 offset; leaq ends at 0x1a with +0x33.
    std.debug.assert(syscall_arm64.len == 0x14 + 0x34 + 1);
    std.debug.assert(syscall_amd64.len == 0x1a + 0x33 + 1);
}

fn words(comptime code: []const u32) [code.len * 4]u8 {
    var out: [code.len * 4]u8 = undefined;
    for (code, 0..) |w, i| std.mem.writeInt(u32, out[i * 4 ..][0..4], w, .little);
    return out;
}

extern "c" fn bench_fib() u32;
extern "c" fn bench_sieve() u32;
extern "c" fn bench_md5() u32;
extern "c" fn bench_qsort() u32;
extern "c" fn bench_fp() u32;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const Compute = struct {
    name: []const u8,
    native: *const fn () callconv(.c) u32,
    arm64: []const u8,
    i386: []const u8,
};

const computes = [_]Compute{
    .{ .name = "fib", .native = bench_fib, .arm64 = @embedFile("bench_fib_arm64"), .i386 = @embedFile("bench_fib_386") },
    .{ .name = "sieve", .native = bench_sieve, .arm64 = @embedFile("bench_sieve_arm64"), .i386 = @embedFile("bench_sieve_386") },
    .{ .name = "md5", .native = bench_md5, .arm64 = @embedFile("bench_md5_arm64"), .i386 = @embedFile("bench_md5_386") },
    .{ .name = "qsort", .native = bench_qsort, .arm64 = @embedFile("bench_qsort_arm64"), .i386 = @embedFile("bench_qsort_386") },
    .{ .name = "fp", .native = bench_fp, .arm64 = @embedFile("bench_fp_arm64"), .i386 = @embedFile("bench_fp_386") },
};

/// Counts ECX down from 10⁹, then exits(nil).
const loop_386 = [_]u8{
    0xb9, 0x00, 0xca, 0x9a, 0x3b, // movl  $1000000000, %ecx
    0x49, // decl  %ecx
    0x75, 0xfd, // jne   .-1
    0x83, 0xec, 0x10, // subl  $16, %esp
    0xc7, 0x44, 0x24, 0x04, 0x00, 0x00, 0x00, 0x00, // movl  $0, 4(%esp)        nil
    0xb8, 0x08, 0x00, 0x00, 0x00, // movl  $8, %eax           EXITS
    0xcd, 0x40, // int   $64
};

const Case = struct {
    name: []const u8,
    arch: aout.Arch,
    text: []const u8,
};

const cases = [_]Case{
    .{ .name = "loop", .arch = .arm64, .text = &loop_arm64 },
    .{ .name = "loop", .arch = .amd64, .text = &loop_amd64 },
    .{ .name = "loop", .arch = .i386, .text = &loop_386 },
    .{ .name = "pwrite", .arch = .arm64, .text = &syscall_arm64 },
    .{ .name = "pwrite", .arch = .amd64, .text = &syscall_amd64 },
    .{ .name = "nsec", .arch = .arm64, .text = &nsec_arm64 },
    .{ .name = "nsec", .arch = .amd64, .text = &nsec_amd64 },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    const w = &stdout.interface;

    var bad = false;
    // zig build bench -- compute: the compute benchmarks only.
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const compute_only = argv.len > 1 and std.mem.eql(u8, argv[1], "compute");
    if (!compute_only) try w.print("{s: <7} {s: <6} {s: <7} {s: >8}  {s}\n", .{ "case", "arch", "vmm", "time", "rate" });
    if (!compute_only) for (cases) |c| for ([_]vmm.BackendKind{ .hvf, .kvm, .native, .emu }) |kind| for (tiersOf(kind)) |tier| {
        if (tier) |t| _ = setenv("H9_EMU_TIER", t, 1) else _ = unsetenv("H9_EMU_TIER");
        defer _ = unsetenv("H9_EMU_TIER");
        const ns = try runOne(gpa, io, kind, c) orelse continue;
        const s = @as(f64, @floatFromInt(ns)) / 1e9;
        var lb: [16]u8 = undefined;
        try w.print("{s: <7} {t: <6} {s: <7} {d: >7.2}s  ", .{ c.name, c.arch, tierLabel(&lb, kind, tier), s });
        if (std.mem.eql(u8, c.name, "loop")) {
            try w.print("{d:.2} G instructions/s\n", .{2 * loop_iters / s / 1e9});
        } else if (std.mem.eql(u8, c.name, "nsec")) {
            try w.print("{d:.0} ns per system call\n", .{s * 1e9 / syscall_iters});
        } else {
            try w.print("{d:.2} µs per round trip\n", .{s * 1e6 / syscall_iters});
        }
        try w.flush();
    };
    try w.flush();

    // The bare vCPU round trip: run returning .syscall and run again,
    // with no system call served (SVC; B back to it).
    if (!compute_only) for ([_]vmm.BackendKind{ .hvf, .emu }) |kind| for (tiersOf(kind)) |tier| {
        if (tier) |t| _ = setenv("H9_EMU_TIER", t, 1) else _ = unsetenv("H9_EMU_TIER");
        defer _ = unsetenv("H9_EMU_TIER");
        const ns = try bareRoundTrip(gpa, io, kind) orelse continue;
        var lb: [16]u8 = undefined;
        try w.print("{s: <7} {s: <6} {s: <7} {d: >7.2}s  {d:.0} ns per exit and re-entry\n", .{ "bare", "arm64", tierLabel(&lb, kind, tier), @as(f64, @floatFromInt(ns)) / 1e9, @as(f64, @floatFromInt(ns)) / bare_iters });
        try w.flush();
    };

    try w.print("\n{s: <7} {s: <6} {s: <7} {s: >8}  {s: <10} {s}\n", .{ "compute", "arch", "vmm", "time", "vs native", "rate (where the emulator counts)" });
    for (computes) |c| {
        const t0 = std.Io.Timestamp.now(io, .awake);
        const want = c.native();
        const native_ns = t0.untilNow(io, .awake).toNanoseconds();
        try w.print("{s: <7} {s: <6} {s: <7} {d: >7.3}s\n", .{ c.name, "host", "native", @as(f64, @floatFromInt(native_ns)) / 1e9 });
        var hex: [8]u8 = undefined;
        _ = std.fmt.bufPrint(&hex, "{x:0>8}", .{want}) catch unreachable;
        for ([_]aout.Arch{ .arm64, .i386 }) |arch| {
            const text = if (arch == .arm64) c.arm64 else c.i386;
            for ([_]vmm.BackendKind{ .hvf, .kvm, .native, .emu }) |kind| {
                for (tiersOf(kind)) |tier| {
                    if (tier) |t| _ = setenv("H9_EMU_TIER", t, 1) else _ = unsetenv("H9_EMU_TIER");
                    defer _ = unsetenv("H9_EMU_TIER");
                    const before = vmm.emuRetired();
                    const r = try runText(gpa, io, kind, arch, text) orelse continue;
                    const insns: ?u64 = if (kind == .emu) if (vmm.emuRetired()) |n| n - before.? else null else null;
                    const s = @as(f64, @floatFromInt(r.ns)) / 1e9;
                    const label = if (tier) |t| try std.fmt.allocPrint(gpa, "emu/{s}", .{t}) else try std.fmt.allocPrint(gpa, "{t}", .{kind});
                    defer gpa.free(label);
                    try w.print("{s: <7} {t: <6} {s: <7} {d: >7.3}s  {d: <10.1}", .{ c.name, arch, label, s, s / (@as(f64, @floatFromInt(native_ns)) / 1e9) });
                    if (insns) |n| try w.print(" {d:.2} G instructions/s ({d} M)", .{ @as(f64, @floatFromInt(n)) / s / 1e9, n / 1_000_000 });
                    if (!std.mem.eql(u8, r.msg[0..@min(r.msg.len, 8)], &hex) or r.msg.len != 8) {
                        try w.print("  WRONG: exited \"{s}\", want {s}\n", .{ r.msg, &hex });
                        bad = true;
                    } else try w.writeAll("\n");
                    try w.flush();
                }
            }
        }
    }
    try w.flush();
    if (bad) std.process.exit(1);
}

/// The emulator once per tier (H9_EMU_TIER) where it has tiers
/// (-Demu=zig); every other backend once.
fn tiersOf(kind: vmm.BackendKind) []const ?[:0]const u8 {
    return if (kind == .emu and vmm.zemu != null) &.{ "t0", "t1" } else &.{null};
}

fn tierLabel(buf: []u8, kind: vmm.BackendKind, tier: ?[]const u8) []const u8 {
    const t = tier orelse return @tagName(kind);
    return std.fmt.bufPrint(buf, "{t}/{s}", .{ kind, t }) catch @tagName(kind);
}

var msg_buf: [64]u8 = undefined;

/// One run of a compute text segment: its wall time and exit message.
const bare_iters = 10_000_000;

/// The time of `bare_iters` exits and re-entries of an arm64 vCPU on
/// `kind`: SVC, then B back to it, at 0x10000.
fn bareRoundTrip(gpa: std.mem.Allocator, io: std.Io, kind: vmm.BackendKind) !?i96 {
    var b = vmm.create(gpa, io, kind, .{ .arch = .arm64 }) catch |e| switch (e) {
        error.HypervisorUnavailable, error.BackendNotBuilt, error.WrongArch => return null,
        else => return e,
    };
    defer b.destroy();
    const page = try b.allocPages(1);
    defer b.freePages(page);
    std.mem.writeInt(u32, page[0..4], 0xd4000001, .little); // svc #0
    std.mem.writeInt(u32, page[4..8], 0x17ffffff, .little); // b .-4
    const as = try b.newAddressSpace();
    defer as.destroy();
    try as.map(0x10000, page, .{ .exec = true });
    defer as.unmap(0x10000);
    var v = try b.createVcpu();
    defer v.destroy();
    try v.setAddressSpace(as);
    var u: vmm.Ureg = .initExec(.arm64, 0x10000, 0, 0);
    v.setUreg(&u);
    const start: std.Io.Timestamp = .now(io, .awake);
    for (0..bare_iters) |_| {
        if (try v.run() != .syscall) return error.BenchFailed;
    }
    return start.untilNow(io, .awake).toNanoseconds();
}

fn runText(gpa: std.mem.Allocator, io: std.Io, kind: vmm.BackendKind, arch: aout.Arch, text: []const u8) !?struct { ns: i96, msg: []const u8 } {
    const bytes = try gpa.alloc(u8, aout.header_size + text.len);
    defer gpa.free(bytes);
    const hs = arch.headerSize();
    aout.writeTextHeader(bytes[0..hs], arch, text.len);
    @memcpy(bytes[hs..][0..text.len], text);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    const start: std.Io.Timestamp = .now(io, .awake);
    var m = h9.Machine.init(gpa, io, .{
        .backend = kind,
        .arch = arch,
        .stdio = .{ .out = &discard.writer, .err = &discard.writer },
    }) catch |e| switch (e) {
        error.HypervisorUnavailable, error.BackendNotBuilt, error.WrongArch => return null,
        else => return e,
    };
    defer m.deinit();
    const status = try m.run(.{ .bytes = bytes[0 .. hs + text.len] }, &.{"bench"});
    const ns = start.untilNow(io, .awake).toNanoseconds();
    const msg = switch (status) {
        .exited => |x| x,
        .killed => "killed",
    };
    const n = @min(msg.len, msg_buf.len);
    @memcpy(msg_buf[0..n], msg[0..n]);
    return .{ .ns = ns, .msg = msg_buf[0..n] };
}

/// The wall time of one run of `c` on `kind`, including machine setup, or
/// null if `kind` can't run `c.arch` here.
fn runOne(gpa: std.mem.Allocator, io: std.Io, kind: vmm.BackendKind, c: Case) !?i96 {
    const hs = c.arch.headerSize();
    const bytes = try gpa.alloc(u8, hs + c.text.len);
    defer gpa.free(bytes);
    aout.writeTextHeader(bytes[0..hs], c.arch, c.text.len);
    @memcpy(bytes[hs..], c.text);

    var discard: std.Io.Writer.Discarding = .init(&.{});
    const start: std.Io.Timestamp = .now(io, .awake);
    var m = h9.Machine.init(gpa, io, .{
        .backend = kind,
        .arch = c.arch,
        .stdio = .{ .out = &discard.writer, .err = &discard.writer },
    }) catch |e| switch (e) {
        error.HypervisorUnavailable, error.BackendNotBuilt, error.WrongArch => return null,
        else => return e,
    };
    defer m.deinit();
    const status = try m.run(.{ .bytes = bytes }, &.{"bench"});
    const ns = start.untilNow(io, .awake).toNanoseconds();
    switch (status) {
        .exited => |msg| if (msg.len != 0) return error.BenchFailed,
        .killed => return error.BenchFailed,
    }
    return ns;
}
