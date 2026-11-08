//! The emulator speed benchmark behind DESIGN.md's "Limits and selection":
//! a 2-instruction loop of 10⁹ iterations, and 10⁶ one-byte pwrite round
//! trips, for arm64 and amd64 on every backend built in that can run them.
//! zig build bench builds it with ReleaseFast and runs it.

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

const Case = struct {
    name: []const u8,
    arch: aout.Arch,
    text: []const u8,
};

const cases = [_]Case{
    .{ .name = "loop", .arch = .arm64, .text = &loop_arm64 },
    .{ .name = "loop", .arch = .amd64, .text = &loop_amd64 },
    .{ .name = "pwrite", .arch = .arm64, .text = &syscall_arm64 },
    .{ .name = "pwrite", .arch = .amd64, .text = &syscall_amd64 },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    const w = &stdout.interface;

    try w.print("{s: <7} {s: <6} {s: <4} {s: >8}  {s}\n", .{ "case", "arch", "vmm", "time", "rate" });
    for (cases) |c| for ([_]vmm.BackendKind{ .hvf, .kvm, .native, .emu }) |kind| {
        const ns = try runOne(gpa, io, kind, c) orelse continue;
        const s = @as(f64, @floatFromInt(ns)) / 1e9;
        try w.print("{s: <7} {t: <6} {t: <4} {d: >7.2}s  ", .{ c.name, c.arch, kind, s });
        if (std.mem.eql(u8, c.name, "loop")) {
            try w.print("{d:.2} G instructions/s\n", .{2 * loop_iters / s / 1e9});
        } else {
            try w.print("{d:.2} µs per round trip\n", .{s * 1e6 / syscall_iters});
        }
        try w.flush();
    };
    try w.flush();
}

/// The wall time of one run of `c` on `kind`, including machine setup, or
/// null if `kind` can't run `c.arch` here.
fn runOne(gpa: std.mem.Allocator, io: std.Io, kind: vmm.BackendKind, c: Case) !?i96 {
    const bytes = try gpa.alloc(u8, aout.header_size + c.text.len);
    defer gpa.free(bytes);
    aout.writeTextHeader(bytes[0..aout.header_size], c.arch, c.text.len);
    @memcpy(bytes[aout.header_size..], c.text);

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
