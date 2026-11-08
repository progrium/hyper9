//! Runs the same programs on every backend built into this h9 and checks
//! that each one produces the expected output and syscall trace. Backends
//! that can't run here (no hypervisor, not built, wrong architecture) are
//! skipped; the test fails if none can.

const std = @import("std");
const builtin = @import("builtin");
const h9 = @import("h9");
const hello = @import("hello");
const vmm = h9.vmm;
const aout = h9.aout;

const Result = struct {
    status: []const u8,
    out: []const u8,
    trace: []const u8,
};

/// Runs `bytes` on backend `kind`, or returns null if that backend can't run
/// `arch` binaries on this host.
fn runOn(gpa: std.mem.Allocator, kind: vmm.BackendKind, arch: aout.Arch, bytes: []const u8) !?Result {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(gpa);
    defer err.deinit();
    var trace: std.Io.Writer.Allocating = .init(gpa);
    defer trace.deinit();

    var m = h9.Machine.init(gpa, std.testing.io, .{
        .backend = kind,
        .arch = arch,
        .trace = &trace.writer,
        .stdio = .{ .out = &out.writer, .err = &err.writer },
    }) catch |e| switch (e) {
        error.HypervisorUnavailable, error.BackendNotBuilt, error.WrongArch => return null,
        else => return e,
    };
    defer m.deinit();

    const status = try m.run(.{ .bytes = bytes }, &.{"hello"});
    const s = switch (status) {
        .exited => |msg| try std.fmt.allocPrint(gpa, "exited \"{s}\"", .{msg}),
        .killed => |msg| try std.fmt.allocPrint(gpa, "killed \"{s}\"", .{msg}),
    };
    return .{ .status = s, .out = try out.toOwnedSlice(), .trace = try trace.toOwnedSlice() };
}

fn image(gpa: std.mem.Allocator, arch: aout.Arch, text: []const u8) ![]u8 {
    const hsize = arch.headerSize();
    const buf = try gpa.alloc(u8, hsize + text.len);
    aout.writeTextHeader(buf[0..hsize], arch, text.len);
    @memcpy(buf[hsize..], text);
    return buf;
}

/// Little-endian bytes of arm64 instruction words.
fn words(comptime code: []const u32) [code.len * 4]u8 {
    var out: [code.len * 4]u8 = undefined;
    for (code, 0..) |w, i| std.mem.writeInt(u32, out[i * 4 ..][0..4], w, .little);
    return out;
}

fn expectAll(arch: aout.Arch, bytes: []const u8, want: Result) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var ran: usize = 0;
    for ([_]vmm.BackendKind{ .hvf, .kvm, .whp, .native, .emu }) |kind| {
        const got = try runOn(gpa, kind, arch, bytes) orelse continue;
        ran += 1;
        errdefer std.debug.print("backend {t}, {t} binary\n", .{ kind, arch });
        try std.testing.expectEqualStrings(want.status, got.status);
        try std.testing.expectEqualStrings(want.out, got.out);
        try std.testing.expectEqualStrings(want.trace, got.trace);
    }
    if (ran == 0) return error.SkipZigTest;
}

const hello_result: Result = .{
    .status = "exited \"\"",
    .out = hello.msg,
    .trace = "1 pwrite 1 6 = 6\n1 exits \"\"\n",
};

test "hello arm64" {
    const bytes = try image(std.testing.allocator, .arm64, &hello.arm64_text);
    defer std.testing.allocator.free(bytes);
    try expectAll(.arm64, bytes, hello_result);
}

test "hello amd64" {
    const bytes = try image(std.testing.allocator, .amd64, &hello.amd64_text);
    defer std.testing.allocator.free(bytes);
    try expectAll(.amd64, bytes, hello_result);
}

test "hello 386 [9]" {
    const bytes = try image(std.testing.allocator, .i386, &hello.i386_text);
    defer std.testing.allocator.free(bytes);
    try expectAll(.i386, bytes, hello_result);
}

const exits_msg = "failed\x00";
const exits_result: Result = .{ .status = "exited \"failed\"", .out = "", .trace = "1 exits \"failed\"\n" };

test "exits with a message arm64" {
    // exits(msg). The message follows the code.
    const code = [_]u32{
        0xd10083ff, // sub  sp, sp, #32
        0x10000081, // adr  x1, msg (16 bytes ahead)
        0xf90007e1, // str  x1, [sp, #8]
        0xd2800100, // mov  x0, #8   EXITS
        0xd4000001, // svc  #0
    };
    const bytes = try image(std.testing.allocator, .arm64, &(words(&code) ++ exits_msg.*));
    defer std.testing.allocator.free(bytes);
    try expectAll(.arm64, bytes, exits_result);
}

test "exits with a message amd64" {
    const code = [_]u8{
        0x48, 0x83, 0xec, 0x20, // subq  $0x20, %rsp
        0x48, 0x8d, 0x05, 0x0e, 0x00, 0x00, 0x00, // leaq  msg(%rip), %rax
        0x48, 0x89, 0x44, 0x24, 0x08, // movq  %rax, 8(%rsp)
        0xbd, 0x08, 0x00, 0x00, 0x00, // movl  $8, %ebp   EXITS
        0x0f, 0x05, // syscall
        0xeb, 0xfe, // jmp   .
    };
    const bytes = try image(std.testing.allocator, .amd64, &(code ++ exits_msg.*));
    defer std.testing.allocator.free(bytes);
    try expectAll(.amd64, bytes, exits_result);
}

test "a guest syscall with any value in AX traps to h9 [native-backend]" {
    // 9front takes the number from BP and ignores AX, so a guest may leave
    // anything there; on native, the host kernel mustn't act on any of
    // them (a patched kernel ran 335 and 336 before seccomp saw them).
    // Each value goes in AX for a pwrite of one byte.
    const ax = [_]u64{ 0, 39, 60, 231, 335, 336, 0x4000_0027, 0x7fff_ffff, 0x1_0000_0027, std.math.maxInt(u64) };
    const code = [_]u8{
        0x48, 0x83, 0xec, 0x30, // subq  $0x30, %rsp
        0x48, 0xc7, 0x44, 0x24, 0x08, 0x01, 0x00, 0x00, 0x00, // movq  $1, 8(%rsp)       fd
        0x48, 0x8d, 0x05, 0x4c, 0x00, 0x00, 0x00, // leaq  msg(%rip), %rax
        0x48, 0x89, 0x44, 0x24, 0x10, // movq  %rax, 16(%rsp)     buf
        0x48, 0xc7, 0x44, 0x24, 0x18, 0x01, 0x00, 0x00, 0x00, // movq  $1, 24(%rsp)      n
        0x48, 0xc7, 0x44, 0x24, 0x20, 0xff, 0xff, 0xff, 0xff, // movq  $-1, 32(%rsp)     offset
        0x48, 0x8d, 0x1d, 0x36, 0x00, 0x00, 0x00, // leaq  table(%rip), %rbx
        0x41, 0xbc, 0x0a, 0x00, 0x00, 0x00, // movl  $10, %r12d
        0x48, 0x8b, 0x03, // 1: movq  (%rbx), %rax     AX from the table
        0xbd, 0x33, 0x00, 0x00, 0x00, // movl  $51, %ebp          PWRITE
        0x0f, 0x05, // syscall
        0x48, 0x83, 0xc3, 0x08, // addq  $8, %rbx
        0x41, 0xff, 0xcc, // decl  %r12d
        0x75, 0xed, // jnz   1b
        0x48, 0xc7, 0x44, 0x24, 0x08, 0x00, 0x00, 0x00, 0x00, // movq  $0, 8(%rsp)       nil
        0xbd, 0x08, 0x00, 0x00, 0x00, // movl  $8, %ebp           EXITS
        0x0f, 0x05, // syscall
        0xeb, 0xfe, // jmp   .
        0x90, 0x90, 0x90, // to msg, 8-aligned
    };
    comptime std.debug.assert(code.len == 96);
    var text: [code.len + 8 + 8 * ax.len]u8 = undefined;
    @memcpy(text[0..code.len], &code);
    @memcpy(text[code.len..][0..8], "x" ++ "\x00" ** 7);
    for (ax, 0..) |v, i| std.mem.writeInt(u64, text[code.len + 8 + 8 * i ..][0..8], v, .little);
    const bytes = try image(std.testing.allocator, .amd64, &text);
    defer std.testing.allocator.free(bytes);
    try expectAll(.amd64, bytes, .{
        .status = "exited \"\"",
        .out = "x" ** ax.len,
        .trace = "1 pwrite 1 1 = 1\n" ** ax.len ++ "1 exits \"\"\n",
    });
}

test "a guest that jumps into the stub can't open a host file [native-backend]" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var b = vmm.create(gpa, io, .native, .{ .arch = .amd64 }) catch |e| switch (e) {
        error.HypervisorUnavailable, error.BackendNotBuilt, error.WrongArch => return error.SkipZigTest,
        else => return e,
    };
    defer b.destroy();
    // Finds a SYSCALL in the stub's code (linked at 0x600000000000,
    // vmm/native_abi.zig) and jumps to it to create `path`. The stub's
    // seccomp filter must kill it there.
    const code = [_]u8{
        0x48, 0xbf, 0x00, 0x10, 0x00, 0x00, 0x00, 0x60, 0x00, 0x00, // movabsq $0x600000001000, %rdi
        0x66, 0x81, 0x3f, 0x0f, 0x05, // 1: cmpw  $0x050f, (%rdi)
        0x74, 0x05, // je    2f
        0x48, 0xff, 0xc7, // incq  %rdi
        0xeb, 0xf4, // jmp   1b
        0x49, 0x89, 0xfb, // 2: movq  %rdi, %r11
        0x48, 0x8d, 0x35, 0x1a, 0x00, 0x00, 0x00, // leaq  path(%rip), %rsi
        0x48, 0xc7, 0xc7, 0x9c, 0xff, 0xff, 0xff, // movq  $-100, %rdi        AT_FDCWD
        0xba, 0x41, 0x00, 0x00, 0x00, // movl  $0x41, %edx        O_WRONLY|O_CREAT
        0x41, 0xba, 0xa4, 0x01, 0x00, 0x00, // movl  $0644, %r10d
        0xb8, 0x01, 0x01, 0x00, 0x00, // movl  $257, %eax         openat
        0x41, 0xff, 0xe3, // jmp   *%r11
    };
    comptime std.debug.assert(code.len == 58);
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/h9-native-escape-{d}", .{std.os.linux.getpid()});
    const page = try b.allocPages(1);
    defer b.freePages(page);
    @memcpy(page[0..code.len], &code);
    @memcpy(page[code.len..][0..path.len], path);
    page[code.len + path.len] = 0;
    const as = try b.newAddressSpace();
    defer as.destroy();
    try as.map(0x200000, page, .{ .exec = true });
    defer as.unmap(0x200000);
    var v = try b.createVcpu();
    defer v.destroy();
    try v.setAddressSpace(as);
    const u: vmm.Ureg = .{ .amd64 = .{ .pc = 0x200000, .flags = 0x202 } };
    v.setUreg(&u);
    try std.testing.expectError(error.HypervisorFailed, v.run());
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, path, .{}));
}

test "exits with a message 386 [9]" {
    // The syscall number in AX, arguments from SP+4; call/pop finds msg.
    const code = [_]u8{
        0x83, 0xec, 0x10, // subl  $0x10, %esp
        0xe8, 0x00, 0x00, 0x00, 0x00, // call  1f
        0x58, // 1: popl  %eax
        0x05, 0x13, 0x00, 0x00, 0x00, // addl  $(msg-1b), %eax
        0x89, 0x44, 0x24, 0x04, // movl  %eax, 4(%esp)
        0xb8, 0x08, 0x00, 0x00, 0x00, // movl  $8, %eax   EXITS
        0xcd, 0x40, // int   $64
        0xeb, 0xfe, // jmp   .
    };
    comptime std.debug.assert(code.len == 8 + 0x13);
    const bytes = try image(std.testing.allocator, .i386, &(code ++ exits_msg.*));
    defer std.testing.allocator.free(bytes);
    try expectAll(.i386, bytes, exits_result);
}

fn expectFault(arch: aout.Arch, text: []const u8, pc_off: u64) !void {
    const bytes = try image(std.testing.allocator, arch, text);
    defer std.testing.allocator.free(bytes);
    var buf: [128]u8 = undefined;
    const pc = aout.layout(arch).utzero + arch.headerSize() + pc_off;
    try expectAll(arch, bytes, .{
        .status = try std.fmt.bufPrint(&buf, "killed \"sys: trap: fault read addr=0x0 pc=0x{x}\"", .{pc}),
        .out = "",
        .trace = "",
    });
}

test "fault on unmapped memory arm64" {
    try expectFault(.arm64, &words(&.{
        0xd2800001, // mov  x1, #0
        0xf9400022, // ldr  x2, [x1]
    }), 4);
}

test "fault on unmapped memory amd64" {
    try expectFault(.amd64, &[_]u8{
        0x31, 0xc9, // xorl  %ecx, %ecx
        0x48, 0x8b, 0x01, // movq  (%rcx), %rax
    }, 2);
}

test "fault on unmapped memory 386 [9]" {
    try expectFault(.i386, &[_]u8{
        0x31, 0xc9, // xorl  %ecx, %ecx
        0x8b, 0x01, // movl  (%ecx), %eax
    }, 2);
}

/// Runs `text`, which ends in a breakpoint instruction at `bp_off`: the
/// vCPU exits with `.breakpoint`, the PC left at a BRK and past an INT3
/// (`pc_off`), and a process with no debugger or note handler dies with
/// `sys: breakpoint` (design/0010-self-host.md).
fn expectBreakpoint(arch: aout.Arch, text: []const u8, pc_off: u64) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const bytes = try image(gpa, arch, text);
    defer gpa.free(bytes);
    const pc = aout.layout(arch).utzero + arch.headerSize() + pc_off;
    var ran: usize = 0;
    for ([_]vmm.BackendKind{ .hvf, .native, .emu }) |kind| {
        var b = vmm.create(gpa, io, kind, .{ .arch = arch }) catch |e| switch (e) {
            error.HypervisorUnavailable, error.BackendNotBuilt, error.WrongArch => continue,
            else => return e,
        };
        defer b.destroy();
        const as = try b.newAddressSpace();
        defer as.destroy();
        var img = try h9.loader.load(gpa, b, as, bytes, &.{"brk"}, 1);
        defer img.segs.release(as);
        var v = try b.createVcpu();
        defer v.destroy();
        try v.setAddressSpace(as);
        var u: vmm.Ureg = .initExec(arch, img.entry, img.sp, img.tos);
        v.setUreg(&u);
        errdefer std.debug.print("backend {t}, {t} binary\n", .{ kind, arch });
        try std.testing.expectEqual(vmm.Exit.breakpoint, try v.run());
        v.getUreg(&u);
        try std.testing.expectEqual(pc, u.pc());
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
    var buf: [128]u8 = undefined;
    try expectAll(arch, bytes, .{
        .status = try std.fmt.bufPrint(&buf, "killed \"sys: breakpoint pc=0x{x}\"", .{pc}),
        .out = "",
        .trace = "",
    });
}

test "BRK exits as a breakpoint on every backend [10]" {
    try expectBreakpoint(.arm64, &words(&.{
        0xd503201f, // nop
        0xd4200000, // brk  #0 (libmach's bpinst64)
    }), 4);
    try expectBreakpoint(.amd64, &[_]u8{
        0x90, // nop
        0xcc, // int3
        0xeb, 0xfe, // jmp  .
    }, 2);
    try expectBreakpoint(.i386, &[_]u8{
        0x90, // nop
        0xcc, // int3
        0xeb, 0xfe, // jmp  .
    }, 2);
}

/// Loops until kicked from another thread; `run` must return `.interrupted`.
fn expectKick(arch: aout.Arch, text: []const u8) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const bytes = try image(gpa, arch, text);
    defer gpa.free(bytes);
    var ran: usize = 0;
    for ([_]vmm.BackendKind{ .hvf, .kvm, .whp, .native, .emu }) |kind| {
        var b = vmm.create(gpa, io, kind, .{ .arch = arch }) catch |e| switch (e) {
            error.HypervisorUnavailable, error.BackendNotBuilt, error.WrongArch => continue,
            else => return e,
        };
        defer b.destroy();
        const as = try b.newAddressSpace();
        defer as.destroy();
        var img = try h9.loader.load(gpa, b, as, bytes, &.{"spin"}, 1);
        defer img.segs.release(as);
        var v = try b.createVcpu();
        defer v.destroy();
        try v.setAddressSpace(as);
        var u: vmm.Ureg = .initExec(arch, img.entry, img.sp, img.tos);
        v.setUreg(&u);

        const Kicker = struct {
            fn run(vc: *vmm.Vcpu, i: std.Io) void {
                std.Io.sleep(i, .fromMilliseconds(50), .awake) catch {};
                vc.kick();
            }
        };
        const t = try std.Thread.spawn(.{}, Kicker.run, .{ &v, io });
        const exit = v.run();
        t.join();
        errdefer std.debug.print("backend {t}, {t} binary\n", .{ kind, arch });
        try std.testing.expectEqual(vmm.Exit.interrupted, try exit);
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

test "kick interrupts a running vcpu arm64" {
    try expectKick(.arm64, &words(&.{0x14000000})); // b .
}

test "kick interrupts a running vcpu amd64" {
    try expectKick(.amd64, &[_]u8{ 0xeb, 0xfe }); // jmp .
}

test "kick interrupts a running vcpu 386 [9]" {
    try expectKick(.i386, &[_]u8{ 0xeb, 0xfe }); // jmp .
}

/// Kicks with no delay, many times over, so some kicks land while `run` is
/// starting. Every run must still return `.interrupted`; a lost kick hangs.
fn expectKickRace(arch: aout.Arch, text: []const u8) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const bytes = try image(gpa, arch, text);
    defer gpa.free(bytes);
    var ran: usize = 0;
    for ([_]vmm.BackendKind{ .hvf, .kvm, .whp, .native, .emu }) |kind| {
        var b = vmm.create(gpa, io, kind, .{ .arch = arch }) catch |e| switch (e) {
            error.HypervisorUnavailable, error.BackendNotBuilt, error.WrongArch => continue,
            else => return e,
        };
        defer b.destroy();
        const as = try b.newAddressSpace();
        defer as.destroy();
        var img = try h9.loader.load(gpa, b, as, bytes, &.{"spin"}, 1);
        defer img.segs.release(as);
        var v = try b.createVcpu();
        defer v.destroy();
        try v.setAddressSpace(as);
        const u: vmm.Ureg = .initExec(arch, img.entry, img.sp, img.tos);

        const Kicker = struct {
            fn run(vc: *vmm.Vcpu, go: *std.atomic.Value(u32), n: u32) void {
                for (0..n) |i| {
                    while (go.load(.acquire) <= i) std.atomic.spinLoopHint();
                    vc.kick();
                }
            }
        };
        const rounds = 200;
        var go: std.atomic.Value(u32) = .init(0);
        const t = try std.Thread.spawn(.{}, Kicker.run, .{ &v, &go, rounds });
        defer t.join();
        errdefer std.debug.print("backend {t}, {t} binary\n", .{ kind, arch });
        for (0..rounds) |_| {
            v.setUreg(&u);
            _ = go.fetchAdd(1, .release);
            try std.testing.expectEqual(vmm.Exit.interrupted, try v.run());
        }
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

test "a kick racing the start of a run isn't lost arm64" {
    try expectKickRace(.arm64, &words(&.{0x14000000})); // b .
}

test "a kick racing the start of a run isn't lost amd64" {
    try expectKickRace(.amd64, &[_]u8{ 0xeb, 0xfe }); // jmp .
}

test "a kick racing the start of a run isn't lost 386 [9]" {
    try expectKickRace(.i386, &[_]u8{ 0xeb, 0xfe }); // jmp .
}

/// Runs `bytes` as a machine with `pol` on every backend that can, and
/// returns the statuses.
fn runPolicy(arch: aout.Arch, bytes: []const u8, pol: h9.Policy, want: []const u8) !void {
    const gpa = std.testing.allocator;
    var ran: usize = 0;
    for ([_]vmm.BackendKind{ .hvf, .kvm, .whp, .native, .emu }) |kind| {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var m = h9.Machine.init(gpa, std.testing.io, .{
            .backend = kind,
            .arch = arch,
            .policy = pol,
            .stdio = .{ .out = &out.writer, .err = &out.writer },
        }) catch |e| switch (e) {
            error.HypervisorUnavailable, error.BackendNotBuilt, error.WrongArch => continue,
            else => return e,
        };
        defer m.deinit();
        const status = try m.run(.{ .bytes = bytes }, &.{"t"});
        errdefer std.debug.print("backend {t}, {t} binary\n", .{ kind, arch });
        try std.testing.expectEqualStrings(want, switch (status) {
            .exited => |s| s,
            .killed => |s| s,
        });
        try std.testing.expect(!m.stuck);
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

test "a timeout stops a spinning process arm64" {
    const bytes = try image(std.testing.allocator, .arm64, &words(&.{0x14000000})); // b .
    defer std.testing.allocator.free(bytes);
    try runPolicy(.arm64, bytes, .{ .timeout_ns = 100 * std.time.ns_per_ms }, "h9: timeout");
}

test "a timeout stops a spinning process amd64" {
    const bytes = try image(std.testing.allocator, .amd64, &[_]u8{ 0xeb, 0xfe }); // jmp .
    defer std.testing.allocator.free(bytes);
    try runPolicy(.amd64, bytes, .{ .timeout_ns = 100 * std.time.ns_per_ms }, "h9: timeout");
}

test "a timeout interrupts sleep arm64" {
    // sleep(100000), then spin.
    const code = words(&.{
        0xd10083ff, // sub  sp, sp, #32
        0xd290d401, // mov  x1, #0x86a0
        0xf2a00021, // movk x1, #1, lsl #16
        0xf90007e1, // str  x1, [sp, #8]
        0xd2800220, // mov  x0, #17   SLEEP
        0xd4000001, // svc  #0
        0x14000000, // b    .
    });
    const img = try image(std.testing.allocator, .arm64, &code);
    defer std.testing.allocator.free(img);
    try runPolicy(.arm64, img, .{ .timeout_ns = 100 * std.time.ns_per_ms }, "h9: timeout");
}

/// Runs `bytes` on every backend that can, with an owned and a pooled
/// vCPU, and checks the status (prefix) and output.
fn expectNotes(arch: aout.Arch, bytes: []const u8, want_status: []const u8, want_out: []const u8) !void {
    const gpa = std.testing.allocator;
    var ran: usize = 0;
    for ([_]vmm.BackendKind{ .hvf, .kvm, .whp, .native, .emu }) |kind| for ([_]?u32{ null, 0 }) |own| {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var err: std.Io.Writer.Allocating = .init(gpa);
        defer err.deinit();
        var m = h9.Machine.init(gpa, std.testing.io, .{
            .backend = kind,
            .arch = arch,
            .policy = .{ .timeout_ns = 10 * std.time.ns_per_s },
            .owned_vcpus = own,
            .stdio = .{ .out = &out.writer, .err = &err.writer },
        }) catch |e| switch (e) {
            error.HypervisorUnavailable, error.BackendNotBuilt, error.WrongArch => continue,
            else => return e,
        };
        defer m.deinit();
        const status = try m.run(.{ .bytes = bytes }, &.{"t"});
        errdefer std.debug.print("backend {t}, {t} binary, owned_vcpus {?d}\n", .{ kind, arch, own });
        var sb: [300]u8 = undefined;
        const got = switch (status) {
            .exited => |t| try std.fmt.bufPrint(&sb, "exited {s}", .{t}),
            .killed => |t| try std.fmt.bufPrint(&sb, "killed {s}", .{t}),
        };
        if (!std.mem.startsWith(u8, got, want_status)) {
            std.debug.print("status: want prefix \"{s}\", got \"{s}\"\n", .{ want_status, got });
            return error.TestUnexpectedResult;
        }
        try std.testing.expectEqualStrings(want_out, out.written());
        ran += 1;
    };
    if (ran == 0) return error.SkipZigTest;
}

/// notify(handler); a bad syscall, whose note the handler catches: it
/// writes the note's first 17 bytes to fd 1 and calls noted(NCONT), and
/// the program carries on after the syscall to exits(nil). With
/// `with_handler` false, the notify is skipped (its svc becomes a nop).
fn noteProgramArm64(comptime with_handler: bool) [26 * 4]u8 {
    return words(&.{
        0xd100c3ff, // sub  sp, sp, #48
        0x10000141, // adr  x1, handler
        0xf90007e1, // str  x1, [sp, #8]
        0xd2800380, // mov  x0, #28           NOTIFY
        if (with_handler) 0xd4000001 else 0xd503201f, // svc #0 (or nop)
        0xd2800c60, // mov  x0, #99           no such call
        0xd4000001, // svc  #0
        0xf90007ff, // str  xzr, [sp, #8]     exits(nil)
        0xd2800100, // mov  x0, #8            EXITS
        0xd4000001, // svc  #0
        0x14000000, // b    .
        // handler(ureg, msg): msg is at sp+16.
        0xf9400be2, // ldr  x2, [sp, #16]
        0xd100c3ff, // sub  sp, sp, #48
        0xd2800021, // mov  x1, #1
        0xf90007e1, // str  x1, [sp, #8]      fd 1
        0xf9000be2, // str  x2, [sp, #16]     buf = msg
        0xd2800223, // mov  x3, #17
        0xf9000fe3, // str  x3, [sp, #24]     len
        0x92800004, // mov  x4, #-1
        0xf90013e4, // str  x4, [sp, #32]     offset
        0xd2800660, // mov  x0, #51           PWRITE
        0xd4000001, // svc  #0
        0xf90007ff, // str  xzr, [sp, #8]     NCONT
        0xd28003a0, // mov  x0, #29           NOTED
        0xd4000001, // svc  #0
        0x14000000, // b    .
    });
}

test "a note handler catches a note and noted(NCONT) resumes arm64" {
    const img = try image(std.testing.allocator, .arm64, &noteProgramArm64(true));
    defer std.testing.allocator.free(img);
    try expectNotes(.arm64, img, "exited ", "sys: bad sys call");
}

test "an unhandled note kills the process with the note and pc arm64" {
    const img = try image(std.testing.allocator, .arm64, &noteProgramArm64(false));
    defer std.testing.allocator.free(img);
    try expectNotes(.arm64, img, "killed sys: bad sys call pc=0x", "");
}

test "a note handler catches a note and noted(NCONT) resumes amd64" {
    // As noteProgramArm64; the handler's msg is at sp+16, its Ureg in BP.
    const code = [_]u8{
        0x48, 0x83, 0xec, 0x30, // subq  $0x30, %rsp
        0x48, 0x8d, 0x05, 0x25, 0x00, 0x00, 0x00, // leaq  handler(%rip), %rax
        0x48, 0x89, 0x44, 0x24, 0x08, // movq  %rax, 8(%rsp)
        0xbd, 0x1c, 0x00, 0x00, 0x00, // movl  $28, %ebp          NOTIFY
        0x0f, 0x05, // syscall
        0xbd, 0x63, 0x00, 0x00, 0x00, // movl  $99, %ebp          no such call
        0x0f, 0x05, // syscall
        0x48, 0xc7, 0x44, 0x24, 0x08, 0x00, 0x00, 0x00, 0x00, // movq  $0, 8(%rsp)
        0xbd, 0x08, 0x00, 0x00, 0x00, // movl  $8, %ebp           EXITS
        0x0f, 0x05, // syscall
        0xeb, 0xfe, // jmp   .
        // handler:
        0x48, 0x8b, 0x54, 0x24, 0x10, // movq  16(%rsp), %rdx     msg
        0x48, 0x83, 0xec, 0x30, // subq  $0x30, %rsp
        0x48, 0xc7, 0x44, 0x24, 0x08, 0x01, 0x00, 0x00, 0x00, // movq  $1, 8(%rsp)
        0x48, 0x89, 0x54, 0x24, 0x10, // movq  %rdx, 16(%rsp)
        0x48, 0xc7, 0x44, 0x24, 0x18, 0x11, 0x00, 0x00, 0x00, // movq  $17, 24(%rsp)
        0x48, 0xc7, 0x44, 0x24, 0x20, 0xff, 0xff, 0xff, 0xff, // movq  $-1, 32(%rsp)
        0xbd, 0x33, 0x00, 0x00, 0x00, // movl  $51, %ebp          PWRITE
        0x0f, 0x05, // syscall
        0x48, 0xc7, 0x44, 0x24, 0x08, 0x00, 0x00, 0x00, 0x00, // movq  $0, 8(%rsp)  NCONT
        0xbd, 0x1d, 0x00, 0x00, 0x00, // movl  $29, %ebp          NOTED
        0x0f, 0x05, // syscall
        0xeb, 0xfe, // jmp   .
    };
    comptime std.debug.assert(code[48] == 0x48 and code[49] == 0x8b); // handler at 0x30
    const img = try image(std.testing.allocator, .amd64, &code);
    defer std.testing.allocator.free(img);
    try expectNotes(.amd64, img, "exited ", "sys: bad sys call");
}

/// As noteProgramArm64, for 386: the handler finds its Ureg at SP+4 and
/// the note at SP+8, with no register carrying either.
fn noteProgramI386(comptime with_handler: bool) [0x74]u8 {
    return .{
        0x83, 0xec, 0x20, // subl  $0x20, %esp
        0xe8, 0x00, 0x00, 0x00, 0x00, // call  1f
        0x58, // 1: popl  %eax
        0x05, 0x29, 0x00, 0x00, 0x00, // addl  $(handler-1b), %eax
        0x89, 0x44, 0x24, 0x04, // movl  %eax, 4(%esp)
        0xb8, 0x1c, 0x00, 0x00, 0x00, // movl  $28, %eax          NOTIFY
    } ++ (if (with_handler) [2]u8{ 0xcd, 0x40 } else [2]u8{ 0x90, 0x90 }) ++ .{ // int $64 (or nops)
        0xb8, 0x63, 0x00, 0x00, 0x00, // movl  $99, %eax          no such call
        0xcd, 0x40, // int   $64
        0xc7, 0x44, 0x24, 0x04, 0x00, 0x00, 0x00, 0x00, // movl  $0, 4(%esp)        exits(nil)
        0xb8, 0x08, 0x00, 0x00, 0x00, // movl  $8, %eax           EXITS
        0xcd, 0x40, // int   $64
        0xeb, 0xfe, // jmp   .
        // handler (0x31):
        0x8b, 0x54, 0x24, 0x08, // movl  8(%esp), %edx       msg
        0x83, 0xec, 0x20, // subl  $0x20, %esp
        0xc7, 0x44, 0x24, 0x04, 0x01, 0x00, 0x00, 0x00, // movl  $1, 4(%esp)        fd 1
        0x89, 0x54, 0x24, 0x08, // movl  %edx, 8(%esp)      buf = msg
        0xc7, 0x44, 0x24, 0x0c, 0x11, 0x00, 0x00, 0x00, // movl  $17, 12(%esp)      len
        0xc7, 0x44, 0x24, 0x10, 0xff, 0xff, 0xff, 0xff, // movl  $-1, 16(%esp)      offset (low)
        0xc7, 0x44, 0x24, 0x14, 0xff, 0xff, 0xff, 0xff, // movl  $-1, 20(%esp)      offset (high)
        0xb8, 0x33, 0x00, 0x00, 0x00, // movl  $51, %eax          PWRITE
        0xcd, 0x40, // int   $64
        0xc7, 0x44, 0x24, 0x04, 0x00, 0x00, 0x00, 0x00, // movl  $0, 4(%esp)        NCONT
        0xb8, 0x1d, 0x00, 0x00, 0x00, // movl  $29, %eax          NOTED
        0xcd, 0x40, // int   $64
        0xeb, 0xfe, // jmp   .
    };
}

test "a note handler catches a note and noted(NCONT) resumes 386 [9]" {
    const img = try image(std.testing.allocator, .i386, &noteProgramI386(true));
    defer std.testing.allocator.free(img);
    try expectNotes(.i386, img, "exited ", "sys: bad sys call");
}

test "an unhandled note kills the process with the note and pc 386 [9]" {
    const img = try image(std.testing.allocator, .i386, &noteProgramI386(false));
    defer std.testing.allocator.free(img);
    try expectNotes(.i386, img, "killed sys: bad sys call pc=0x", "");
}

test "noted outside a handler fails, and a fault's note reaches the handler arm64" {
    // noted(NCONT) with no note fails and returns -1; then a fault on
    // address 0, which the handler from notify ends with noted(NDFLT).
    const code = words(&.{
        0xd100c3ff, // sub  sp, sp, #48
        0xf90007ff, // str  xzr, [sp, #8]     NCONT
        0xd28003a0, // mov  x0, #29           NOTED
        0xd4000001, // svc  #0
        0xb100041f, // cmn  x0, #1
        0x54000040, // b.eq +8
        0x14000000, // b    .                 (noted didn't fail)
        0x100000c1, // adr  x1, handler (+24)
        0xf90007e1, // str  x1, [sp, #8]
        0xd2800380, // mov  x0, #28           NOTIFY
        0xd4000001, // svc  #0
        0xf940001f, // ldr  xzr, [x0]         fault (x0 = 0)
        0x14000000, // b    .
        // handler: noted(NDFLT)
        0xd100c3ff, // sub  sp, sp, #48
        0xd2800021, // mov  x1, #1
        0xf90007e1, // str  x1, [sp, #8]      NDFLT
        0xd28003a0, // mov  x0, #29           NOTED
        0xd4000001, // svc  #0
        0x14000000, // b    .
    });
    const img = try image(std.testing.allocator, .arm64, &code);
    defer std.testing.allocator.free(img);
    try expectNotes(.arm64, img, "killed sys: trap: fault read addr=0x0 pc=0x", "");
}

/// A console input that blocks until cancelled, then gives `after` once.
const BlockingInput = struct {
    io: std.Io,
    after: []const u8,
    cancelled: std.atomic.Value(u32) = .init(0),
    served: bool = false,
    reads: std.atomic.Value(u32) = .init(0),
    interface: std.Io.Reader,

    fn init(b: *BlockingInput, io: std.Io, after: []const u8, buf: []u8) void {
        b.* = .{ .io = io, .after = after, .interface = .{ .vtable = &.{ .stream = stream }, .buffer = buf, .seek = 0, .end = 0 } };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const b: *BlockingInput = @alignCast(@fieldParentPtr("interface", r));
        _ = b.reads.fetchAdd(1, .release);
        if (b.cancelled.load(.acquire) != 0) {
            if (b.served) return error.EndOfStream;
            b.served = true;
            return w.write(limit.sliceConst(b.after)) catch error.WriteFailed;
        }
        b.io.futexWaitUncancelable(u32, &b.cancelled.raw, 0);
        return error.ReadFailed;
    }

    fn cancel(ctx: *anyopaque, _: std.Thread) void {
        const b: *BlockingInput = @ptrCast(@alignCast(ctx));
        b.cancelled.store(1, .release);
        b.io.futexWake(u32, &b.cancelled.raw, 1);
    }

    fn reset(_: *anyopaque) void {}
};

/// pread(0, buf, 16, -1), then write what it read to fd 1 and exit.
const read_echo_arm64 = words(&.{
    0xd10103ff, // sub  sp, sp, #64
    0xf90007ff, // str  xzr, [sp, #8]     fd 0
    0x9100c3e1, // add  x1, sp, #48
    0xf9000be1, // str  x1, [sp, #16]     buf
    0xd2800202, // mov  x2, #16
    0xf9000fe2, // str  x2, [sp, #24]     len
    0x92800003, // mov  x3, #-1
    0xf90013e3, // str  x3, [sp, #32]     offset
    0xd2800640, // mov  x0, #50           PREAD
    0xd4000001, // svc  #0
    0xf9000fe0, // str  x0, [sp, #24]     len = bytes read
    0xd2800021, // mov  x1, #1
    0xf90007e1, // str  x1, [sp, #8]      fd 1
    0xd2800660, // mov  x0, #51           PWRITE
    0xd4000001, // svc  #0
    0xf90007ff, // str  xzr, [sp, #8]     exits(nil)
    0xd2800100, // mov  x0, #8            EXITS
    0xd4000001, // svc  #0
    0x14000000, // b    .
});

test "a timeout interrupts a console read, and its reader thread is cancelled" {
    const gpa = std.testing.allocator;
    const img = try image(gpa, .arm64, &read_echo_arm64);
    defer gpa.free(img);
    var ran: usize = 0;
    for ([_]vmm.BackendKind{ .hvf, .kvm, .whp, .native, .emu }) |kind| {
        var in_buf: [64]u8 = undefined;
        var in: BlockingInput = undefined;
        in.init(std.testing.io, "", &in_buf);
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var m = h9.Machine.init(gpa, std.testing.io, .{
            .backend = kind,
            .arch = .arm64,
            .policy = .{ .timeout_ns = 100 * std.time.ns_per_ms },
            .stdio = .{
                .in = &in.interface,
                .in_cancel = .{ .ctx = &in, .func = BlockingInput.cancel, .reset = BlockingInput.reset },
                .out = &out.writer,
                .err = &out.writer,
            },
        }) catch |e| switch (e) {
            error.HypervisorUnavailable, error.BackendNotBuilt, error.WrongArch => continue,
            else => return e,
        };
        defer m.deinit();
        errdefer std.debug.print("backend {t}\n", .{kind});
        const status = try m.run(.{ .bytes = img }, &.{"t"});
        try std.testing.expectEqualStrings("h9: timeout", status.killed);
        try std.testing.expect(!m.stuck);
        try std.testing.expect(in.reads.load(.acquire) >= 1);
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

test "a console read returns input from the reader thread, and a later run sees EOF" {
    const gpa = std.testing.allocator;
    const img = try image(gpa, .arm64, &read_echo_arm64);
    defer gpa.free(img);
    var ran: usize = 0;
    for ([_]vmm.BackendKind{ .hvf, .kvm, .whp, .native, .emu }) |kind| {
        var src: std.Io.Reader = .fixed("one\ntwo\n");
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var m = h9.Machine.init(gpa, std.testing.io, .{
            .backend = kind,
            .arch = .arm64,
            .stdio = .{ .in = &src, .out = &out.writer, .err = &out.writer },
        }) catch |e| switch (e) {
            error.HypervisorUnavailable, error.BackendNotBuilt, error.WrongArch => continue,
            else => return e,
        };
        defer m.deinit();
        errdefer std.debug.print("backend {t}\n", .{kind});
        // A fixed reader gives everything in one read; the guest reads 16
        // bytes, so a second run gets EOF and writes nothing.
        _ = try m.run(.{ .bytes = img }, &.{"t"});
        try std.testing.expectEqualStrings("one\ntwo\n", out.written());
        _ = try m.run(.{ .bytes = img }, &.{"t"});
        try std.testing.expectEqualStrings("one\ntwo\n", out.written());
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

test "the memory cap is exact" {
    const bytes = try image(std.testing.allocator, .arm64, &hello.arm64_text);
    defer std.testing.allocator.free(bytes);
    // The text page and the stack's first 68 KiB don't fit in 64 KiB (on
    // HVF, the kernel's page tables count too).
    const gpa = std.testing.allocator;
    var ran: usize = 0;
    for ([_]vmm.BackendKind{ .hvf, .kvm, .whp, .native, .emu }) |kind| {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var m = h9.Machine.init(gpa, std.testing.io, .{
            .backend = kind,
            .arch = .arm64,
            .policy = .{ .memory = 64 << 10 },
            .stdio = .{ .out = &out.writer, .err = &out.writer },
        }) catch |e| switch (e) {
            error.HypervisorUnavailable, error.BackendNotBuilt, error.WrongArch => continue,
            else => return e,
        };
        defer m.deinit();
        try std.testing.expectError(error.OutOfGuestMemory, m.run(.{ .bytes = bytes }, &.{"hello"}));
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

/// Runs `f(backend)` on each backend that can run arm64 here.
fn eachBackend(comptime f: fn (vmm.Backend) anyerror!void) !void {
    var ran: usize = 0;
    for ([_]vmm.BackendKind{ .hvf, .kvm, .whp, .native, .emu }) |kind| {
        var b = vmm.create(std.testing.allocator, std.testing.io, kind, .{ .arch = .arm64, .memory = 64 << 20 }) catch |e| switch (e) {
            error.HypervisorUnavailable, error.BackendNotBuilt, error.WrongArch => continue,
            else => return e,
        };
        defer b.destroy();
        errdefer std.debug.print("backend {t}\n", .{kind});
        try f(b);
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

fn byteAt(as: vmm.AddressSpace, va: u64) ?u8 {
    const s = as.translate(va, 1) orelse return null;
    return s[0];
}

fn setByte(as: vmm.AddressSpace, va: u64, v: u8) void {
    as.translate(va, 1).?[0] = v;
}

test "segments: fork shares text, copies the stack, and shares data only with RFMEM" {
    try eachBackend(struct {
        fn f(b: vmm.Backend) !void {
            const gpa = std.testing.allocator;
            const bytes = try image(gpa, .arm64, &hello.arm64_text);
            defer gpa.free(bytes);
            const as = try b.newAddressSpace();
            defer as.destroy();
            var img = try h9.loader.load(gpa, b, as, bytes, &.{"hello"}, 1);
            defer img.segs.release(as);
            // hello has no data or bss, so give it some.
            const data = img.segs.data.?.base;
            try img.segs.brk(data + vmm.page_size);
            const sp = img.sp;
            setByte(as, data, 1);
            setByte(as, sp, 1);

            for ([_]bool{ false, true }) |share| {
                const cas = try b.newAddressSpace();
                defer cas.destroy();
                var c = try img.segs.fork(cas, share);
                defer c.release(cas);
                try std.testing.expectEqual(img.segs.text.?, c.text.?);
                try std.testing.expectEqual(share, img.segs.data.? == c.data.?);
                try std.testing.expect(img.segs.stack.? != c.stack.?);
                // The child sees the parent's memory at fork time...
                try std.testing.expectEqual(@as(?u8, 1), byteAt(cas, data));
                try std.testing.expectEqual(@as(?u8, 1), byteAt(cas, sp));
                // ...and then only shared segments follow each other.
                setByte(cas, data, 2);
                setByte(cas, sp, 2);
                try std.testing.expectEqual(@as(?u8, if (share) 2 else 1), byteAt(as, data));
                try std.testing.expectEqual(@as(?u8, 1), byteAt(as, sp));
                setByte(as, data, 1);
                // Growing a shared break maps the pages into both spaces
                // (past the headroom the parent's mapping already has).
                const top = img.segs.brkTop();
                const far = top + (1 << 20);
                try c.brk(far + 1);
                try std.testing.expectEqual(share, byteAt(as, far) != null);
                try std.testing.expectEqual(@as(?u8, 0), byteAt(cas, far));
                // 9front won't shrink a segment others share.
                if (share) try std.testing.expectError(error.InUse, c.brk(top)) else try c.brk(top);
            }
        }
    }.f);
}

test "segments: brk grows and shrinks, and memory above the break is zeroed" {
    try eachBackend(struct {
        fn f(b: vmm.Backend) !void {
            const gpa = std.testing.allocator;
            const bytes = try image(gpa, .arm64, &hello.arm64_text);
            defer gpa.free(bytes);
            const as = try b.newAddressSpace();
            defer as.destroy();
            var img = try h9.loader.load(gpa, b, as, bytes, &.{"hello"}, 1);
            defer img.segs.release(as);
            const s = &img.segs;
            const base = s.brkTop();
            try std.testing.expectEqual(@as(?u8, null), byteAt(as, base));

            // Small steps don't each add a mapping (hello's data starts empty).
            for (1..9) |i| try s.brk(base + i * 100);
            try std.testing.expectEqual(base + vmm.page_size, s.brkTop());
            for (1..9) |i| try s.brk(base + i * vmm.page_size);
            try std.testing.expectEqual(@as(usize, 1), s.data.?.chunks.items.len);

            try s.brk(base + (1 << 20) + 1);
            try std.testing.expectEqual(base + (1 << 20) + vmm.page_size, s.brkTop());
            setByte(as, base + 10, 7);
            setByte(as, base + (1 << 20), 7);

            try s.brk(base);
            try std.testing.expectEqual(base, s.brkTop());
            try s.brk(base + (1 << 20) + 1);
            try std.testing.expectEqual(@as(?u8, 0), byteAt(as, base + 10));
            try std.testing.expectEqual(@as(?u8, 0), byteAt(as, base + (1 << 20)));

            try std.testing.expectError(error.NoVmem, s.brk(s.data.?.base - 1));
            try std.testing.expectError(error.NoVmem, s.brk(s.stack_floor + 1));
            try std.testing.expectError(error.NoVmem, s.brk(std.math.maxInt(u64)));
            // More than --memory.
            try std.testing.expectError(error.NoVmem, s.brk(base + (128 << 20)));
        }
    }.f);
}

test "segments: the stack grows down to its 16 MiB limit" {
    try eachBackend(struct {
        fn f(b: vmm.Backend) !void {
            const gpa = std.testing.allocator;
            const bytes = try image(gpa, .arm64, &hello.arm64_text);
            defer gpa.free(bytes);
            const as = try b.newAddressSpace();
            defer as.destroy();
            var img = try h9.loader.load(gpa, b, as, bytes, &.{"hello"}, 1);
            defer img.segs.release(as);
            const s = &img.segs;
            const l = aout.layout(.arm64);
            try std.testing.expect(s.stack.?.base > s.stack_floor);
            const deep = l.ustktop - (8 << 20);
            try std.testing.expectEqual(@as(?u8, null), byteAt(as, deep));
            try std.testing.expect(s.growStack(deep));
            try std.testing.expectEqual(@as(?u8, 0), byteAt(as, deep));
            try std.testing.expect(s.growStack(s.stack_floor));
            try std.testing.expectEqual(s.stack_floor, s.stack.?.base);
            try std.testing.expect(!s.growStack(s.stack_floor - 1));
            try std.testing.expect(!s.growStack(l.ustktop));
        }
    }.f);
}

test "segments: releasing a process's segments frees its memory" {
    try eachBackend(struct {
        fn f(b: vmm.Backend) !void {
            const gpa = std.testing.allocator;
            const bytes = try image(gpa, .arm64, &hello.arm64_text);
            defer gpa.free(bytes);
            // 64 MiB of guest memory, so 200 processes' worth only fits if
            // each one's pages come back.
            for (0..200) |_| {
                const as = try b.newAddressSpace();
                defer as.destroy();
                var img = try h9.loader.load(gpa, b, as, bytes, &.{"hello"}, 1);
                defer img.segs.release(as);
                try img.segs.brk(img.segs.brkTop() + (1 << 20));
                _ = img.segs.growStack(img.sp - (1 << 20));
                const cas = try b.newAddressSpace();
                defer cas.destroy();
                var c = try img.segs.fork(cas, false);
                c.release(cas);
            }
        }
    }.f);
}

test "pooled vCPUs carry FP state, the thread pointer and fork across processes arm64" {
    // Forks four times (16 processes), then each sets d8 and TPIDR_EL0 from
    // its Tos pid and makes 2000 syscalls, each one a fresh trip through
    // the shared pool when no vCPUs can be owned, so processes keep landing
    // on vCPUs others last used. Each checks both registers at the end, and
    // faults if either is wrong.
    const code = words(&.{
        0xaa0003f7, // mov  x23, x0            Tos
        0xd10083ff, // sub  sp, sp, #32
        0xd2800098, // mov  x24, #4
        // fork:
        0xd2800281, // mov  x1, #0x14          RFPROC|RFFDG
        0xf90007e1, // str  x1, [sp, #8]
        0xd2800260, // mov  x0, #19            RFORK
        0xd4000001, // svc  #0
        0xf1000718, // subs x24, x24, #1
        0x54ffff61, // b.ne fork
        0xb94042f4, // ldr  w20, [x23, #64]    Tos.pid
        0x91019294, // add  x20, x20, #100
        0x9e670288, // fmov d8, x20
        0xd51bd054, // msr  tpidr_el0, x20
        0xd280fa15, // mov  x21, #2000
        // loop:
        0xf90007ff, // str  xzr, [sp, #8]
        0xd2800220, // mov  x0, #17            SLEEP(0)
        0xd4000001, // svc  #0
        0xf10006b5, // subs x21, x21, #1
        0x54ffff81, // b.ne loop
        0x9e660116, // fmov x22, d8
        0xeb1402df, // cmp  x22, x20
        0x540000c1, // b.ne bad
        0xd53bd056, // mrs  x22, tpidr_el0
        0xeb1402df, // cmp  x22, x20
        0x54000061, // b.ne bad
        0xf90007ff, // str  xzr, [sp, #8]      exits(nil)
        0x14000002, // b    exit
        // bad:
        0xf9400000, // ldr  x0, [x0]           x0 is 0: a fault kills it
        // exit:
        0xd2800100, // mov  x0, #8             EXITS
        0xd4000001, // svc  #0
    });
    try expectPooled(.arm64, &code);
}

test "pooled vCPUs carry FP state and fork across processes amd64" {
    // As the arm64 test, with xmm8, MXCSR, the x87 control word and ST0
    // (FS base isn't used by 9front binaries, and Unicorn's user mode
    // can't write it without a GDT).
    const code = [_]u8{
        0x49, 0x89, 0xc4, // movq  %rax, %r12          Tos
        0x48, 0x83, 0xec, 0x20, // subq  $0x20, %rsp
        0x49, 0xc7, 0xc5, 0x04, 0x00, 0x00, 0x00, // movq  $4, %r13
        // fork:
        0x48, 0xc7, 0x44, 0x24, 0x08, 0x14, 0x00, 0x00, 0x00, // movq $0x14, 8(%rsp)  RFPROC|RFFDG
        0xbd, 0x13, 0x00, 0x00, 0x00, // movl  $19, %ebp          RFORK
        0x0f, 0x05, // syscall
        0x49, 0xff, 0xcd, // decq  %r13
        0x75, 0xeb, // jne   fork
        0x41, 0x8b, 0x5c, 0x24, 0x40, // movl  64(%r12), %ebx     Tos.pid
        0x48, 0x83, 0xc3, 0x64, // addq  $100, %rbx
        0x66, 0x4c, 0x0f, 0x6e, 0xc3, // movq  %rbx, %xmm8
        0xc7, 0x44, 0x24, 0x10, 0x80, 0x7f, 0x00, 0x00, // movl $0x7f80, 16(%rsp)
        0x0f, 0xae, 0x54, 0x24, 0x10, // ldmxcsr 16(%rsp)          round down
        0x48, 0x89, 0x5c, 0x24, 0x18, // movq  %rbx, 24(%rsp)
        0xdf, 0x6c, 0x24, 0x18, // fildq 24(%rsp)           ST0 = pid+100
        0x66, 0xc7, 0x44, 0x24, 0x18, 0x7f, 0x0f, // movw  $0x0f7f, 24(%rsp)
        0xd9, 0x6c, 0x24, 0x18, // fldcw 24(%rsp)           truncate, extended
        0x49, 0xc7, 0xc6, 0xd0, 0x07, 0x00, 0x00, // movq  $2000, %r14
        // loop:
        0x48, 0xc7, 0x44, 0x24, 0x08, 0x00, 0x00, 0x00, 0x00, // movq $0, 8(%rsp)
        0xbd, 0x11, 0x00, 0x00, 0x00, // movl  $17, %ebp          SLEEP(0)
        0x0f, 0x05, // syscall
        0x49, 0xff, 0xce, // decq  %r14
        0x75, 0xeb, // jne   loop
        0x66, 0x4c, 0x0f, 0x7e, 0xc1, // movq  %xmm8, %rcx
        0x48, 0x39, 0xd9, // cmpq  %rbx, %rcx
        0x75, 0x32, // jne   bad
        0x0f, 0xae, 0x5c, 0x24, 0x10, // stmxcsr 16(%rsp)
        0x81, 0x7c, 0x24, 0x10, 0x80, 0x7f, 0x00, 0x00, // cmpl $0x7f80, 16(%rsp)
        0x75, 0x23, // jne   bad
        0xd9, 0x7c, 0x24, 0x18, // fnstcw 24(%rsp)
        0x66, 0x81, 0x7c, 0x24, 0x18, 0x7f, 0x0f, // cmpw  $0x0f7f, 24(%rsp)
        0x75, 0x16, // jne   bad
        0xdf, 0x7c, 0x24, 0x18, // fistpq 24(%rsp)
        0x48, 0x39, 0x5c, 0x24, 0x18, // cmpq  %rbx, 24(%rsp)
        0x75, 0x0b, // jne   bad
        0x48, 0xc7, 0x44, 0x24, 0x08, 0x00, 0x00, 0x00, 0x00, // movq $0, 8(%rsp)  exits(nil)
        0xeb, 0x05, // jmp   exit
        // bad:
        0x31, 0xc0, // xorl  %eax, %eax
        0x48, 0x8b, 0x00, // movq  (%rax), %rax       a fault kills it
        // exit:
        0xbd, 0x08, 0x00, 0x00, 0x00, // movl  $8, %ebp           EXITS
        0x0f, 0x05, // syscall
    };
    try expectPooled(.amd64, &code);
}

test "pooled vCPUs carry FP state and fork across processes 386 [9]" {
    // As the amd64 test, with xmm3, MXCSR, the x87 control word and ST0.
    // The Tos comes in AX, and its pid is at 48 with 4-byte pointers.
    const code = [_]u8{
        0x89, 0xc7, // movl  %eax, %edi          Tos
        0x83, 0xec, 0x20, // subl  $0x20, %esp
        0xbe, 0x04, 0x00, 0x00, 0x00, // movl  $4, %esi
        // fork:
        0xc7, 0x44, 0x24, 0x04, 0x14, 0x00, 0x00, 0x00, // movl  $0x14, 4(%esp)     RFPROC|RFFDG
        0xb8, 0x13, 0x00, 0x00, 0x00, // movl  $19, %eax          RFORK
        0xcd, 0x40, // int   $64
        0x4e, // decl  %esi
        0x75, 0xee, // jne   fork
        0x8b, 0x5f, 0x30, // movl  48(%edi), %ebx      Tos.pid
        0x83, 0xc3, 0x64, // addl  $100, %ebx
        0x89, 0x5c, 0x24, 0x10, // movl  %ebx, 16(%esp)
        0xdb, 0x44, 0x24, 0x10, // fildl 16(%esp)           ST0 = pid+100
        0x66, 0x0f, 0x6e, 0xdb, // movd  %ebx, %xmm3
        0xc7, 0x44, 0x24, 0x10, 0x80, 0x7f, 0x00, 0x00, // movl  $0x7f80, 16(%esp)
        0x0f, 0xae, 0x54, 0x24, 0x10, // ldmxcsr 16(%esp)          round down
        0x66, 0xc7, 0x44, 0x24, 0x10, 0x7f, 0x0f, // movw  $0x0f7f, 16(%esp)
        0xd9, 0x6c, 0x24, 0x10, // fldcw 16(%esp)           truncate, extended
        0xbd, 0xd0, 0x07, 0x00, 0x00, // movl  $2000, %ebp
        // loop:
        0xc7, 0x44, 0x24, 0x04, 0x00, 0x00, 0x00, 0x00, // movl  $0, 4(%esp)
        0xb8, 0x11, 0x00, 0x00, 0x00, // movl  $17, %eax          SLEEP(0)
        0xcd, 0x40, // int   $64
        0x4d, // decl  %ebp
        0x75, 0xee, // jne   loop
        0x66, 0x0f, 0x7e, 0xd9, // movd  %xmm3, %ecx
        0x39, 0xd9, // cmpl  %ebx, %ecx
        0x75, 0x30, // jne   bad
        0x0f, 0xae, 0x5c, 0x24, 0x10, // stmxcsr 16(%esp)
        0x81, 0x7c, 0x24, 0x10, 0x80, 0x7f, 0x00, 0x00, // cmpl  $0x7f80, 16(%esp)
        0x75, 0x21, // jne   bad
        0xd9, 0x7c, 0x24, 0x10, // fnstcw 16(%esp)
        0x66, 0x81, 0x7c, 0x24, 0x10, 0x7f, 0x0f, // cmpw  $0x0f7f, 16(%esp)
        0x75, 0x14, // jne   bad
        0xdb, 0x5c, 0x24, 0x10, // fistpl 16(%esp)
        0x39, 0x5c, 0x24, 0x10, // cmpl  %ebx, 16(%esp)
        0x75, 0x0a, // jne   bad
        0xc7, 0x44, 0x24, 0x04, 0x00, 0x00, 0x00, 0x00, // movl  $0, 4(%esp)        exits(nil)
        0xeb, 0x04, // jmp   exit
        // bad:
        0x31, 0xc0, // xorl  %eax, %eax
        0x8b, 0x00, // movl  (%eax), %eax       a fault kills it
        // exit:
        0xb8, 0x08, 0x00, 0x00, 0x00, // movl  $8, %eax           EXITS
        0xcd, 0x40, // int   $64
    };
    try expectPooled(.i386, &code);
}

/// Runs `code` with the pool forced on (no owned vCPUs) and off, on every
/// backend that can, and expects a clean exit.
fn expectPooled(arch: aout.Arch, code: []const u8) !void {
    const gpa = std.testing.allocator;
    const bytes = try image(gpa, arch, code);
    defer gpa.free(bytes);
    var ran: usize = 0;
    for ([_]vmm.BackendKind{ .hvf, .kvm, .whp, .native, .emu }) |kind| for ([_]u32{ 0, 1 }) |own| {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var m = h9.Machine.init(gpa, std.testing.io, .{
            .backend = kind,
            .arch = arch,
            .owned_vcpus = own,
            .stdio = .{ .out = &out.writer, .err = &out.writer },
        }) catch |e| switch (e) {
            error.HypervisorUnavailable, error.BackendNotBuilt, error.WrongArch => continue,
            else => return e,
        };
        defer m.deinit();
        const status = try m.run(.{ .bytes = bytes }, &.{"t"});
        errdefer std.debug.print("backend {t}, {t}, owned_vcpus {d}\n", .{ kind, arch, own });
        var sb: [300]u8 = undefined;
        try std.testing.expectEqualStrings("exited ", switch (status) {
            .exited => |t| try std.fmt.bufPrint(&sb, "exited {s}", .{t}),
            .killed => |t| try std.fmt.bufPrint(&sb, "killed {s}", .{t}),
        });
        ran += 1;
    };
    if (ran == 0) return error.SkipZigTest;
}

/// Runs segattach fixture `text` (tests/fixtures/segattach) on every
/// backend that can, and checks its status and output. A `want_status`
/// ending in "pc=" is a fault note, matched up to the pc. `root`, if
/// given, is the guest's /.
fn expectSeg(text: []const u8, root: ?[]const u8, want_status: []const u8, want_out: []const u8) !void {
    return expectRun(text, root, 10 * std.time.ns_per_s, want_status, want_out);
}

/// `expectSeg`, with the machine's timeout.
fn expectRun(text: []const u8, root: ?[]const u8, timeout_ns: u64, want_status: []const u8, want_out: []const u8) !void {
    const gpa = std.testing.allocator;
    const bytes = try image(gpa, .arm64, text);
    defer gpa.free(bytes);
    var ran: usize = 0;
    for ([_]vmm.BackendKind{ .hvf, .kvm, .whp, .native, .emu }) |kind| {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var err: std.Io.Writer.Allocating = .init(gpa);
        defer err.deinit();
        var m = h9.Machine.init(gpa, std.testing.io, .{
            .backend = kind,
            .arch = .arm64,
            .root = if (root) |d| .{ .dir = d } else null,
            .policy = .{ .timeout_ns = timeout_ns },
            .stdio = .{ .out = &out.writer, .err = &err.writer },
        }) catch |e| switch (e) {
            error.HypervisorUnavailable, error.BackendNotBuilt, error.WrongArch => continue,
            else => return e,
        };
        defer m.deinit();
        const status = try m.run(.{ .bytes = bytes }, &.{"t"});
        errdefer std.debug.print("backend {t}\n", .{kind});
        var sb: [300]u8 = undefined;
        const got = switch (status) {
            .exited => |t| try std.fmt.bufPrint(&sb, "exited {s}", .{t}),
            .killed => |t| try std.fmt.bufPrint(&sb, "killed {s}", .{t}),
        };
        if (std.mem.endsWith(u8, want_status, "pc=")) {
            if (!std.mem.startsWith(u8, got, want_status)) {
                std.debug.print("status: want prefix \"{s}\", got \"{s}\"\n", .{ want_status, got });
                return error.TestUnexpectedResult;
            }
        } else try std.testing.expectEqualStrings(want_status, got);
        try std.testing.expectEqualStrings(want_out, out.written());
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

/// Where segattach with va 0 puts the first segment on arm64: just below
/// the stack's 16 MiB.
const seg_low = "0x7fefef000";

test "a shared segment is the same pages in an rfork child [4]" {
    try expectSeg(@embedFile("seg_shared_rfork"), null, "exited ", "");
}

test "a memory segment is copied by rfork and shared with RFMEM [4]" {
    try expectSeg(@embedFile("seg_memory_rfork"), null, "exited ", "");
}

test "segattach at 0 goes below the stack, and an overlap fails [4]" {
    try expectSeg(@embedFile("seg_place"), null, "exited segments overlap", "");
}

test "a sixth segment fails with virtual memory allocation failed [4]" {
    try expectSeg(@embedFile("seg_sixth"), null, "exited virtual memory allocation failed", "");
}

test "segdetach unmaps, and the stack can't be detached [4]" {
    try expectSeg(@embedFile("seg_detach"), null, "killed sys: trap: fault read addr=" ++ seg_low ++ " pc=", "");
}

test "segbrk grows and shrinks, and won't shrink a shared segment [4]" {
    try expectSeg(@embedFile("seg_segbrk"), null, "exited device or object already in use", "");
}

test "segfree zeroes the span [4]" {
    try expectSeg(@embedFile("seg_segfree"), null, "exited ", "");
}

test "a write to an SG_RONLY segment faults [4]" {
    try expectSeg(@embedFile("seg_ronly"), null, "killed sys: trap: fault write addr=" ++ seg_low ++ " pc=", "");
}

test "executing from an attached segment posts an exec fault [4]" {
    try expectSeg(@embedFile("seg_execfault"), null, "killed sys: trap: fault exec addr=" ++ seg_low ++ " pc=", "");
}

test "segattach just above the break trims the headroom, and the data survives [4]" {
    try expectSeg(@embedFile("seg_headroom"), null, "exited ", "");
}

test "exec keeps segments and drops SG_CEXEC ones [4]" {
    // exec_a execs /b, which is exec_b.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "dev");
    const b = try image(gpa, .arm64, @embedFile("seg_exec_b"));
    defer gpa.free(b);
    try tmp.dir.writeFile(io, .{ .sub_path = "b", .data = b });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    var root_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    try expectSeg(@embedFile("seg_exec_a"), kernPath(&root_buf, buf[0..n]), "killed sys: trap: fault read addr=0x100100000 pc=", "");
}

/// A resolved host path in the form Options.root takes, as the CLI's
/// kernPath makes it: unchanged on Unix, `/C:/a/b` for `C:\a\b` on Windows.
fn kernPath(out: []u8, p: []const u8) []const u8 {
    if (@import("builtin").os.tag != .windows) return p;
    out[0] = '/';
    for (p, out[1 .. p.len + 1]) |c, *o| o.* = if (c == '\\') '/' else c;
    if (p.len >= 2 and p[1] == ':') out[1] = std.ascii.toUpper(out[1]);
    return out[0 .. p.len + 1];
}

test "brk stops below an attached segment [4]" {
    try expectSeg(@embedFile("seg_brkstop"), null, "exited segments overlap", "");
}

test "a detached shared segment stays mapped in a sibling [4]" {
    try expectSeg(@embedFile("seg_sibling"), null, "killed sys: trap: fault read addr=" ++ seg_low ++ " pc=", "ok");
}

test "/proc/n/segment lists every segment [4]" {
    try expectSeg(@embedFile("seg_procseg"), null, "exited ",
        \\Stack     7feff0000 7ffff0000    1
        \\Text   R     10000    11000    1
        \\Data         20000    20000    1
        \\Shared    7fefef000 7feff0000    1
        \\
    );
}

/// Loads hello into `as`, for the segment tests below.
fn loadHello(b: vmm.Backend, as: vmm.AddressSpace) !h9.loader.Image {
    const gpa = std.testing.allocator;
    const bytes = try image(gpa, .arm64, &hello.arm64_text);
    defer gpa.free(bytes);
    return h9.loader.load(gpa, b, as, bytes, &.{"hello"}, 1);
}

const segment = h9.segment;

test "segments: segattach trims the data headroom, splitting a chunk, and won't for a shared data segment" {
    try eachBackend(struct {
        fn f(b: vmm.Backend) !void {
            const gpa = std.testing.allocator;
            const as = try b.newAddressSpace();
            defer as.destroy();
            var img = try loadHello(b, as);
            defer img.segs.release(as);
            const s = &img.segs;
            const d = s.data.?;
            // One chunk mapped well past a break that ends mid-chunk.
            try s.brk(d.base + 3 * vmm.page_size);
            try std.testing.expect(d.top > d.base + 4 * vmm.page_size);
            try std.testing.expectEqual(@as(usize, 1), d.chunks.items.len);
            setByte(as, d.base + 2 * vmm.page_size, 9);
            const above = d.base + 3 * vmm.page_size;

            // An RFMEM sibling shares the data, so its headroom can't be cut.
            const cas = try b.newAddressSpace();
            defer cas.destroy();
            var c = try s.fork(cas, true);
            try std.testing.expectError(error.Overlap, s.segattach(gpa, b, as, .memory, 0, above, vmm.page_size));
            c.release(cas);

            const va = try s.segattach(gpa, b, as, .memory, 0, above, vmm.page_size);
            try std.testing.expectEqual(above, va);
            try std.testing.expectEqual(above, d.top);
            try std.testing.expectEqual(@as(?u8, 9), byteAt(as, d.base + 2 * vmm.page_size));
            try std.testing.expectEqual(@as(?u8, 0), byteAt(as, above));
            // The break can't grow into it now.
            try std.testing.expectError(error.Overlap, s.brk(above + 1));
            try s.segdetach(as, va);
            try s.brk(above + 1);
        }
    }.f);
}

test "segments: segbrk stops at the next segment and the stack, and frees what it shrinks" {
    try eachBackend(struct {
        fn f(b: vmm.Backend) !void {
            const gpa = std.testing.allocator;
            const as = try b.newAddressSpace();
            defer as.destroy();
            var img = try loadHello(b, as);
            defer img.segs.release(as);
            const s = &img.segs;
            const lo = try s.segattach(gpa, b, as, .memory, 0, 1 << 32, vmm.page_size);
            const hi = try s.segattach(gpa, b, as, .shared, 0, (1 << 32) + 4 * vmm.page_size, vmm.page_size);
            try std.testing.expectEqual(lo, try s.segbrk(lo, 0));
            try std.testing.expectEqual(@as(u64, 0), try s.segbrk(lo, hi));
            try std.testing.expectError(error.Overlap, s.segbrk(lo, hi + 1));
            try std.testing.expectError(error.Overlap, s.segbrk(hi, s.ustktop + 1));
            try std.testing.expectError(error.Overlap, s.segbrk(hi, s.stack_floor + 1));
            try std.testing.expectError(error.NoVmem, s.segbrk(lo, lo - 1));
            try std.testing.expectError(error.BadArg, s.segbrk(s.text.?.base, s.text.?.top));
            try std.testing.expectError(error.BadArg, s.segbrk(s.brkTop() - 1, s.brkTop()));
            try std.testing.expectEqual(@as(u64, 0), try s.segbrk(lo, lo + 1));
            try std.testing.expectEqual(@as(?u8, null), byteAt(as, lo + vmm.page_size));
            // More than --memory, with nothing in the way.
            try s.segdetach(as, hi);
            try std.testing.expectError(error.NoVmem, s.segbrk(lo, lo + (128 << 20)));
            try std.testing.expectError(error.NoVmem, s.segattach(gpa, b, as, .memory, 0, 0, 128 << 20));
            // Bigger than SEGMAXSIZE, wherever it'd go.
            try std.testing.expectError(error.NoVmem, s.segattach(gpa, b, as, .memory, 0, 0, 9 << 30));
        }
    }.f);
}

test "segments: fork shares shared segments and copies memory ones, and exec keeps those without SG_CEXEC" {
    try eachBackend(struct {
        fn f(b: vmm.Backend) !void {
            const gpa = std.testing.allocator;
            const as = try b.newAddressSpace();
            defer as.destroy();
            var img = try loadHello(b, as);
            defer img.segs.release(as);
            const s = &img.segs;
            const sh = try s.segattach(gpa, b, as, .shared, 0, 0, vmm.page_size);
            const mem = try s.segattach(gpa, b, as, .memory, 0, 0, vmm.page_size);
            const cx = try s.segattach(gpa, b, as, .memory, segment.SG_CEXEC, 0, vmm.page_size);
            // A gap in the slots is kept by fork.
            try s.segdetach(as, mem);
            const mem2 = try s.segattach(gpa, b, as, .memory, 0, 0, vmm.page_size);
            try std.testing.expectEqual(mem, mem2);

            for ([_]bool{ false, true }) |share| {
                const cas = try b.newAddressSpace();
                defer cas.destroy();
                var c = try s.fork(cas, share);
                defer c.release(cas);
                for (s.extra, c.extra) |p, q| try std.testing.expectEqual(p == null, q == null);
                setByte(cas, sh, 1);
                setByte(cas, mem, 1);
                try std.testing.expectEqual(@as(?u8, 1), byteAt(as, sh));
                try std.testing.expectEqual(@as(?u8, if (share) 1 else 0), byteAt(as, mem));
                setByte(as, sh, 0);
                setByte(as, mem, 0);
            }

            // exec: a new image, and the old segments carried into it.
            const nas = try b.newAddressSpace();
            defer nas.destroy();
            var n = try loadHello(b, nas);
            defer n.segs.release(nas);
            try n.segs.inherit(s, nas);
            try std.testing.expect(byteAt(nas, sh) != null);
            try std.testing.expect(byteAt(nas, mem) != null);
            try std.testing.expectEqual(@as(?u8, null), byteAt(nas, cx));
        }
    }.f);
}

test "segments: /proc/n/segment's text" {
    try eachBackend(struct {
        fn f(b: vmm.Backend) !void {
            const gpa = std.testing.allocator;
            const as = try b.newAddressSpace();
            defer as.destroy();
            var img = try loadHello(b, as);
            defer img.segs.release(as);
            const s = &img.segs;
            _ = try s.segattach(gpa, b, as, .memory, segment.SG_RONLY, 0, vmm.page_size);
            var buf: [512]u8 = undefined;
            try std.testing.expectEqualStrings(
                \\Stack     7feff0000 7ffff0000    1
                \\Text   R     10000    11000    1
                \\Data         20000    20000    1
                \\Bss    R  7fefef000 7feff0000    1
                \\
            , buf[0..s.segmentText(&buf)]);
        }
    }.f);
}

// rendezvous and semaphores (design/0003-semaphores.md), from the programs
// in tests/fixtures/sema.

test "rendezvous swaps values between an rfork child and its parent [3]" {
    try expectRun(@embedFile("sema_rendezvous"), null, 10 * std.time.ns_per_s, "exited ", "cp");
}

test "semacquire waits for an RFMEM child's semrelease, and the non-blocking and timed forms [3]" {
    try expectRun(@embedFile("sema_semacquire"), null, 10 * std.time.ns_per_s, "exited ", "");
}

test "a semaphore keeps a shared counter exact under contention [3]" {
    try expectRun(@embedFile("sema_count"), null, 60 * std.time.ns_per_s, "exited ", "");
}

test "semaphores in text, negative values and negative counts are bad args [3]" {
    try expectRun(@embedFile("sema_badarg"), null, 10 * std.time.ns_per_s, "exited bad arg in system call", "");
}

test "an odd semaphore address posts sys: odd address [3]" {
    try expectRun(@embedFile("sema_odd"), null, 10 * std.time.ns_per_s, "killed sys: odd address pc=", "");
}

test "an unmapped semaphore address is a bad address [3]" {
    try expectRun(@embedFile("sema_unmapped"), null, 10 * std.time.ns_per_s, "killed sys: bad address in syscall pc=", "");
}

test "a note interrupts rendezvous and semacquire, and the handler runs [3]" {
    try expectRun(@embedFile("sema_interrupt"), null, 300 * std.time.ns_per_ms, "killed h9: timeout", "hhrinterrupted");
}

/// Runs net fixture `text` (tests/fixtures/net) with `argv` and `pol` on
/// every backend that can, and checks its exit status. The machine has
/// no root tree; the fixtures name `#I` directly.
fn expectNet(text: []const u8, argv: []const []const u8, pol: h9.Policy, want_status: []const u8) !void {
    const gpa = std.testing.allocator;
    const bytes = try image(gpa, .arm64, text);
    defer gpa.free(bytes);
    var p = pol;
    p.timeout_ns = 10 * std.time.ns_per_s;
    var ran: usize = 0;
    for ([_]vmm.BackendKind{ .hvf, .kvm, .whp, .native, .emu }) |kind| {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var m = h9.Machine.init(gpa, std.testing.io, .{
            .backend = kind,
            .arch = .arm64,
            .policy = p,
            .stdio = .{ .out = &out.writer, .err = &out.writer },
        }) catch |e| switch (e) {
            error.HypervisorUnavailable, error.BackendNotBuilt, error.WrongArch => continue,
            else => return e,
        };
        defer m.deinit();
        const status = try m.run(.{ .bytes = bytes }, argv);
        errdefer std.debug.print("backend {t}\n", .{kind});
        var sb: [300]u8 = undefined;
        try std.testing.expectEqualStrings(want_status, switch (status) {
            .exited => |t| try std.fmt.bufPrint(&sb, "exited {s}", .{t}),
            .killed => |t| try std.fmt.bufPrint(&sb, "killed {s}", .{t}),
        });
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

const net_ctl = @embedFile("net_ctl");
const net_cs = @embedFile("net_cs");
const denied = "exited permission denied";
/// What the host says for a connect to a closed loopback port: the
/// policy let it through.
const refused = "exited Connection refused";

// devip binds only for a nonzero port, so the announces name one.
test "the default profile refuses announce, and enable allows it [5]" {
    try expectNet(net_ctl, &.{ "t", "#I/tcp/clone", "announce 127.0.0.1!39517" }, .{}, denied);
    try expectNet(net_ctl, &.{ "t", "#I/tcp/clone", "announce 127.0.0.1!39517" }, .{ .net = .enable }, "exited ");
}

test "a UDP announce is refused under outbound [5]" {
    try expectNet(net_ctl, &.{ "t", "#I/udp/clone", "announce 127.0.0.1!39517" }, .{}, denied);
}

test "outbound allows connect, except to link-local [5]" {
    try expectNet(net_ctl, &.{ "t", "#I/tcp/clone", "connect 127.0.0.1!1" }, .{}, refused);
    try expectNet(net_ctl, &.{ "t", "#I/tcp/clone", "connect 169.254.169.254!80" }, .{}, denied);
    try expectNet(net_ctl, &.{ "t", "#I/tcp/clone", "connect 169.254.169.254!80" }, .{ .net = .enable }, denied);
    try expectNet(net_ctl, &.{ "t", "#I/tcp/clone", "connect ::ffff:169.254.169.254!80" }, .{}, denied);
    try expectNet(net_ctl, &.{ "t", "#I/udp/clone", "connect fe80::1!53" }, .{}, denied);
}

test "--net-allow allows a matching CIDR and port, and refuses the rest [5]" {
    const pol: h9.Policy = .{ .net_allow = &.{"tcp!127.0.0.0/8!1-2"} };
    try expectNet(net_ctl, &.{ "t", "#I/tcp/clone", "connect 127.0.0.1!1" }, pol, refused);
    try expectNet(net_ctl, &.{ "t", "#I/tcp/clone", "connect 127.0.0.1!3" }, pol, denied);
    try expectNet(net_ctl, &.{ "t", "#I/udp/clone", "connect 127.0.0.1!1" }, pol, denied);
    // A refused connect binds nothing first.
    try expectNet(net_ctl, &.{ "t", "#I/tcp/clone", "connect 127.0.0.1!3 4000" }, pol, denied);
}

test "a name outside --net-allow isn't resolved [5]" {
    try expectNet(net_ctl, &.{ "t", "#I/cs", "tcp!localhost!1" }, .{ .net_allow = &.{"tcp!127.0.0.1!1"} }, "exited no translation for host found");
    try expectNet(net_ctl, &.{ "t", "#I/cs", "tcp!127.0.0.1!1" }, .{ .net_allow = &.{"tcp!127.0.0.1!1"} }, "exited ");
}

test "a name pattern allows a connect through cs, and only through cs [5]" {
    const pol: h9.Policy = .{ .net_allow = &.{"tcp!localhost!1"} };
    try expectNet(net_cs, &.{ "t", "tcp!localhost!1" }, pol, refused);
    try expectNet(net_ctl, &.{ "t", "#I/tcp/clone", "connect 127.0.0.1!1" }, pol, denied);
    try expectNet(net_cs, &.{ "t", "tcp!localhost!2" }, pol, "exited no translation for host found");
}

// Overlays (design/0006-ephemeral-writes.md).

/// A host root tree with the mount points the namespace builder needs.
const OverlayRoot = struct {
    tmp: std.testing.TmpDir,
    buf: [std.fs.max_path_bytes]u8 = undefined,
    path: []const u8 = "",
    cwd_buf: [std.fs.max_path_bytes]u8 = undefined,
    cwd: []const u8 = "",

    fn init(r: *OverlayRoot) !void {
        const io = std.testing.io;
        r.tmp = std.testing.tmpDir(.{});
        for ([_][]const u8{ "dev", "tmp", "srv", "bin", "mnt/term/cwd", "cwd" }) |d| try r.tmp.dir.createDirPath(io, d);
        r.path = r.buf[0..try r.tmp.dir.realPath(io, &r.buf)];
        r.cwd = try std.fmt.bufPrint(&r.cwd_buf, "{s}/cwd", .{r.path});
    }
    fn deinit(r: *OverlayRoot) void {
        r.tmp.cleanup();
    }
    fn exists(r: *OverlayRoot, name: []const u8) bool {
        r.tmp.dir.access(std.testing.io, name, .{}) catch return false;
        return true;
    }
};

/// Runs fixture `text` on backend `kind` with the root and cwd of `r`;
/// null if the backend can't run here. The status goes in `sb`.
fn runOverlay(kind: vmm.BackendKind, r: *OverlayRoot, text: []const u8, pol: h9.Policy, sb: []u8) !?[]const u8 {
    return runOverlayTools(kind, r, text, pol, true, sb, null);
}

/// `runOverlay`, with `guest_tools` (design/0032-guest-tools.md) as given,
/// and the run's root changes (design/0011-overlay.md) in `changes`.
fn runOverlayTools(kind: vmm.BackendKind, r: *OverlayRoot, text: []const u8, pol: h9.Policy, guest_tools: bool, sb: []u8, changes: ?*h9.RootChanges) !?[]const u8 {
    const gpa = std.testing.allocator;
    const bytes = try image(gpa, .arm64, text);
    defer gpa.free(bytes);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(gpa);
    defer err.deinit();
    var p = pol;
    p.timeout_ns = 20 * std.time.ns_per_s;
    var m = h9.Machine.init(gpa, std.testing.io, .{
        .backend = kind,
        .arch = .arm64,
        .root = .{ .dir = r.path },
        .cwd = r.cwd,
        .policy = p,
        .guest_tools = guest_tools,
        .stdio = .{ .out = &out.writer, .err = &err.writer },
    }) catch |e| switch (e) {
        error.HypervisorUnavailable, error.BackendNotBuilt, error.WrongArch => return null,
        else => return e,
    };
    defer m.deinit();
    const status = try m.run(.{ .bytes = bytes }, &.{"t"});
    if (changes) |c| c.* = m.root_changes;
    return switch (status) {
        .exited => |t| try std.fmt.bufPrint(sb, "exited {s}", .{t}),
        .killed => |t| try std.fmt.bufPrint(sb, "killed {s}", .{t}),
    };
}

test "two machines in one host process each get their own /tmp [6]" {
    // HVF allows one VM per host process, so its second machine is the
    // emulator. KVM allows several.
    var ran: usize = 0;
    for ([_][2]vmm.BackendKind{ .{ .hvf, .emu }, .{ .kvm, .kvm }, .{ .whp, .emu }, .{ .native, .native }, .{ .emu, .emu } }) |kinds| {
        var r: OverlayRoot = .{ .tmp = undefined };
        try r.init();
        defer r.deinit();
        // A writes /tmp/f and holds it for 3 s; B looks for it meanwhile.
        const A = struct {
            r: *OverlayRoot,
            kind: vmm.BackendKind,
            sb: [300]u8 = undefined,
            got: anyerror!?[]const u8 = null,
            fn run(a: *@This()) void {
                a.got = runOverlay(a.kind, a.r, @embedFile("ov_tmp_own"), .{}, &a.sb);
            }
        };
        var a: A = .{ .r = &r, .kind = kinds[0] };
        const th = try std.Thread.spawn(.{}, A.run, .{&a});
        std.Io.sleep(std.testing.io, .fromMilliseconds(1000), .awake) catch {};
        var sb: [300]u8 = undefined;
        const b = runOverlay(kinds[1], &r, @embedFile("ov_tmp_absent"), .{}, &sb);
        th.join();
        errdefer std.debug.print("backends {t} and {t}\n", .{ kinds[0], kinds[1] });
        const got_a = try a.got orelse continue;
        const got_b = try b orelse continue;
        try std.testing.expectEqualStrings("exited ", got_a);
        try std.testing.expect(std.mem.startsWith(u8, got_b, "exited "));
        try std.testing.expect(std.mem.indexOf(u8, got_b, "does not exist") != null);
        try std.testing.expect(!r.exists("tmp/f"));
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

test "two machines in one host process each see only their own root changes [11]" {
    // HVF allows one VM per host process, so its second machine is the
    // emulator. KVM allows several.
    var ran: usize = 0;
    for ([_][2]vmm.BackendKind{ .{ .hvf, .emu }, .{ .kvm, .kvm }, .{ .whp, .emu }, .{ .native, .native }, .{ .emu, .emu } }) |kinds| {
        var r: OverlayRoot = .{ .tmp = undefined };
        try r.init();
        defer r.deinit();
        // A writes /f and holds it for 3 s; B looks for it meanwhile.
        const A = struct {
            r: *OverlayRoot,
            kind: vmm.BackendKind,
            sb: [300]u8 = undefined,
            changes: h9.RootChanges = .{},
            got: anyerror!?[]const u8 = null,
            fn run(a: *@This()) void {
                a.got = runOverlayTools(a.kind, a.r, @embedFile("ov_root_own"), .{}, true, &a.sb, &a.changes);
            }
        };
        var a: A = .{ .r = &r, .kind = kinds[0] };
        const th = try std.Thread.spawn(.{}, A.run, .{&a});
        std.Io.sleep(std.testing.io, .fromMilliseconds(1000), .awake) catch {};
        var sb: [300]u8 = undefined;
        var b_changes: h9.RootChanges = .{};
        const b = runOverlayTools(kinds[1], &r, @embedFile("ov_root_absent"), .{}, true, &sb, &b_changes);
        th.join();
        errdefer std.debug.print("backends {t} and {t}\n", .{ kinds[0], kinds[1] });
        const got_a = try a.got orelse continue;
        const got_b = try b orelse continue;
        try std.testing.expectEqualStrings("exited ", got_a);
        try std.testing.expect(std.mem.startsWith(u8, got_b, "exited "));
        try std.testing.expect(std.mem.indexOf(u8, got_b, "does not exist") != null);
        try std.testing.expect(!r.exists("f"));
        // Each machine's summary has only its own changes.
        try std.testing.expect(a.changes.changed);
        try std.testing.expectEqual(@as(usize, 1), a.changes.dirs().len);
        try std.testing.expectEqualStrings("f", a.changes.dirs()[0].slice());
        try std.testing.expect(!b_changes.changed);
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

test "a copy-up while another process has the lower file open leaves that reader on the old contents [6]" {
    var ran: usize = 0;
    for ([_]vmm.BackendKind{ .hvf, .kvm, .whp, .native, .emu }) |kind| {
        var r: OverlayRoot = .{ .tmp = undefined };
        try r.init();
        defer r.deinit();
        try r.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "cwd/f", .data = "old" });
        var sb: [300]u8 = undefined;
        const got = try runOverlay(kind, &r, @embedFile("ov_copyup_reader"), .{ .write = .ephemeral }, &sb) orelse continue;
        errdefer std.debug.print("backend {t}\n", .{kind});
        try std.testing.expectEqualStrings("exited ", got);
        var hb: [8]u8 = undefined;
        try std.testing.expectEqualStrings("old", try r.tmp.dir.readFile(std.testing.io, "cwd/f", &hb));
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

test "posting, opening and removing in /srv, and clone boards [8]" {
    var ran: usize = 0;
    for ([_]vmm.BackendKind{ .hvf, .kvm, .whp, .native, .emu }) |kind| {
        var r: OverlayRoot = .{ .tmp = undefined };
        try r.init();
        defer r.deinit();
        var sb: [300]u8 = undefined;
        const got = try runOverlay(kind, &r, @embedFile("srv_board"), .{}, &sb) orelse continue;
        errdefer std.debug.print("backend {t}\n", .{kind});
        try std.testing.expectEqualStrings("exited ", got);
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

test "two machines in one process have separate /srv [8]" {
    // HVF allows one VM per host process, so its second machine is the
    // emulator. KVM allows several.
    var ran: usize = 0;
    for ([_][2]vmm.BackendKind{ .{ .hvf, .emu }, .{ .kvm, .kvm }, .{ .whp, .emu }, .{ .native, .native }, .{ .emu, .emu } }) |kinds| {
        var r: OverlayRoot = .{ .tmp = undefined };
        try r.init();
        defer r.deinit();
        // A posts /srv/m and holds it for 3 s; B looks for it meanwhile.
        const A = struct {
            r: *OverlayRoot,
            kind: vmm.BackendKind,
            sb: [300]u8 = undefined,
            got: anyerror!?[]const u8 = null,
            fn run(a: *@This()) void {
                a.got = runOverlay(a.kind, a.r, @embedFile("srv_hold"), .{}, &a.sb);
            }
        };
        var a: A = .{ .r = &r, .kind = kinds[0] };
        const th = try std.Thread.spawn(.{}, A.run, .{&a});
        std.Io.sleep(std.testing.io, .fromMilliseconds(1000), .awake) catch {};
        var sb: [300]u8 = undefined;
        const b = runOverlay(kinds[1], &r, @embedFile("srv_absent"), .{}, &sb);
        th.join();
        errdefer std.debug.print("backends {t} and {t}\n", .{ kinds[0], kinds[1] });
        const got_a = try a.got orelse continue;
        const got_b = try b orelse continue;
        try std.testing.expectEqualStrings("exited ", got_a);
        try std.testing.expect(std.mem.startsWith(u8, got_b, "exited "));
        try std.testing.expect(std.mem.indexOf(u8, got_b, "does not exist") != null);
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

test "a machine's posted channels are closed when it ends [8]" {
    var ran: usize = 0;
    for ([_]vmm.BackendKind{ .hvf, .kvm, .whp, .native, .emu }) |kind| {
        var r: OverlayRoot = .{ .tmp = undefined };
        try r.init();
        defer r.deinit();
        var sb: [300]u8 = undefined;
        const got = try runOverlay(kind, &r, @embedFile("srv_orclose"), .{}, &sb) orelse continue;
        errdefer std.debug.print("backend {t}\n", .{kind});
        try std.testing.expectEqualStrings("exited ", got);
        // The posted chan was opened ORCLOSE: closing it removed the file.
        try std.testing.expect(!r.exists("cwd/f"));
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

// #H (design/0032-guest-tools.md), with the test-only script that Debug
// builds serve from tests/fixtures/guest.

test "#H/bin is on /bin, reads back, and refuses every change [32]" {
    var ran: usize = 0;
    for ([_]vmm.BackendKind{ .hvf, .kvm, .whp, .native, .emu }) |kind| {
        var r: OverlayRoot = .{ .tmp = undefined };
        try r.init();
        defer r.deinit();
        var sb: [300]u8 = undefined;
        const got = try runOverlay(kind, &r, @embedFile("htools_tree"), .{}, &sb) orelse continue;
        errdefer std.debug.print("backend {t}\n", .{kind});
        try std.testing.expectEqualStrings("exited ", got);
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

test "guest_tools = false leaves #H/bin off /bin and masks #H [32]" {
    var ran: usize = 0;
    for ([_]vmm.BackendKind{ .hvf, .kvm, .whp, .native, .emu }) |kind| {
        var r: OverlayRoot = .{ .tmp = undefined };
        try r.init();
        defer r.deinit();
        var sb: [300]u8 = undefined;
        const got = try runOverlayTools(kind, &r, @embedFile("htools_masked"), .{}, false, &sb, null) orelse continue;
        errdefer std.debug.print("backend {t}: {s}\n", .{ kind, got });
        try std.testing.expect(std.mem.startsWith(u8, got, "exited "));
        try std.testing.expect(got.len > "exited ".len);
        try std.testing.expect(!std.mem.eql(u8, got, "exited a"));
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

test "KVM reuses destroyed vCPUs past its limit, with none of the last user's state [16]" {
    const gpa = std.testing.allocator;
    const arch = vmm.host_arch orelse return error.SkipZigTest;
    var b = vmm.create(gpa, std.testing.io, .kvm, .{ .arch = arch }) catch |e| switch (e) {
        error.HypervisorUnavailable, error.BackendNotBuilt, error.WrongArch => return error.SkipZigTest,
        else => return e,
    };
    defer b.destroy();
    const max = try b.maxVcpus();
    // KVM counts every vCPU a VM ever created against its limit.
    var i: u32 = 0;
    while (i < max + 4) : (i += 1) {
        var v = try b.createVcpu();
        defer v.destroy();
        var x: vmm.Extra = undefined;
        try v.getExtra(&x);
        const init: vmm.Extra = .initExec(arch);
        var u: vmm.Ureg = undefined;
        v.getUreg(&u);
        switch (x) {
            .arm64 => |*a| {
                try std.testing.expectEqualDeep(init.arm64, a.*);
                try std.testing.expectEqualDeep(arm64Zero(), u.arm64);
                a.v[3] = 0x1234;
                a.fpcr = 1 << 24;
                a.tls = 0xdead0000;
                u.arm64.r[5] = 77;
            },
            .amd64 => |*a| {
                try std.testing.expectEqual(init.amd64.fx.fcw, a.fx.fcw);
                try std.testing.expectEqual(init.amd64.fx.mxcsr, a.fx.mxcsr);
                try std.testing.expectEqualDeep(init.amd64.fx.xmm, a.fx.xmm);
                try std.testing.expectEqual(@as(u64, 0), a.tls);
                try std.testing.expectEqual(@as(u64, 0), u.amd64.bx);
                a.fx.xmm[3] = 0x1234;
                a.fx.fcw = 0x027f;
                a.tls = 0xdead0000;
                u.amd64.bx = 77;
            },
            .i386 => unreachable,
        }
        try v.setExtra(&x);
        v.setUreg(&u);
    }
}

fn arm64Zero() vmm.arm64.Ureg {
    return .{};
}

// Graphics (design/0015-gfx.md), on the headless backend: a screen in
// memory that the test acts on as a window system would.

const gfx = h9.gfx;

/// A run with a window, on a thread of its own, while the test acts on
/// the window. Pinned: the machine writes to `out` and `err`.
const GfxRun = struct {
    out: std.Io.Writer.Allocating = .init(std.testing.allocator),
    err: std.Io.Writer.Allocating = .init(std.testing.allocator),
    m: h9.Machine = undefined,
    bytes: ?[]u8 = null,
    prog: h9.Program = undefined,
    argv: []const []const u8 = &.{"t"},
    sb: [300]u8 = undefined,
    status: anyerror![]const u8 = error.NotRun,
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    started: bool = false,

    const Opts = struct {
        /// An arm64 fixture's text, or else a guest program from `root`.
        text: ?[]const u8 = null,
        guest: ?[]const u8 = null,
        argv: []const []const u8 = &.{"t"},
        root: ?[]const u8 = null,
        clipboard: bool = true,
        timeout_s: u64 = 20,
    };

    /// Starts the run; false if backend `kind` can't run here.
    fn start(g: *GfxRun, kind: vmm.BackendKind, o: Opts) !bool {
        const gpa = std.testing.allocator;
        if (o.text) |t| {
            g.bytes = try image(gpa, .arm64, t);
            g.prog = .{ .bytes = g.bytes.? };
        } else g.prog = .{ .guest = o.guest.? };
        g.argv = o.argv;
        g.m = h9.Machine.init(gpa, std.testing.io, .{
            .backend = kind,
            .arch = .arm64,
            .root = if (o.root) |r| .{ .dir = r } else null,
            .policy = .{ .timeout_ns = o.timeout_s * std.time.ns_per_s },
            .gfx = .{ .clipboard = o.clipboard },
            .stdio = .{ .out = &g.out.writer, .err = &g.err.writer },
        }) catch |e| switch (e) {
            error.HypervisorUnavailable, error.BackendNotBuilt, error.WrongArch => return false,
            else => return e,
        };
        g.started = true;
        g.thread = try std.Thread.spawn(.{}, run, .{g});
        return true;
    }

    fn run(g: *GfxRun) void {
        g.status = if (g.m.run(g.prog, g.argv)) |st| switch (st) {
            .exited => |t| std.fmt.bufPrint(&g.sb, "exited {s}", .{t}),
            .killed => |t| std.fmt.bufPrint(&g.sb, "killed {s}", .{t}),
        } else |e| e;
        g.done.store(true, .release);
    }

    fn running(g: *GfxRun) bool {
        return !g.done.load(.acquire);
    }

    /// Waits for the run to end, and returns its status.
    fn wait(g: *GfxRun) ![]const u8 {
        if (g.thread) |t| t.join();
        g.thread = null;
        return g.status;
    }

    fn deinit(g: *GfxRun) void {
        if (g.thread) |t| t.join();
        if (g.started) g.m.deinit();
        if (g.bytes) |b| std.testing.allocator.free(b);
        g.out.deinit();
        g.err.deinit();
    }
};

fn sleepMs(ms: u64) void {
    std.Io.sleep(std.testing.io, .fromMilliseconds(@intCast(ms)), .awake) catch {};
}

/// Runs gfx fixture `text` on each backend that can, calling `act`
/// every 20 ms while it runs, and checks it exits cleanly; `check` then
/// looks at its output.
fn expectGfx(text: []const u8, clipboard: bool, act: ?*const fn () void, check: *const fn (out: []const u8) anyerror!void) !void {
    var ran: usize = 0;
    for ([_]vmm.BackendKind{ .hvf, .native, .emu }) |kind| {
        var g: GfxRun = .{};
        defer g.deinit();
        if (!try g.start(kind, .{ .text = text, .clipboard = clipboard })) continue;
        if (act) |f| while (g.running()) {
            f();
            sleepMs(20);
        };
        const st = try g.wait();
        errdefer std.debug.print("backend {t}: {s}\nstderr: {s}\n", .{ kind, st, g.err.written() });
        try std.testing.expectEqualStrings("exited ", st);
        try check(g.out.written());
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

fn noCheck(_: []const u8) anyerror!void {}

test "--gfx binds /dev/draw, /dev/mouse, /dev/cursor and /dev/kbd [15]" {
    try expectGfx(@embedFile("gfx_binds"), true, null, noCheck);
}

test "reading /dev/draw/new reports the screen's size [15]" {
    try expectGfx(@embedFile("gfx_drawnew"), true, null, struct {
        fn check(out: []const u8) !void {
            // Twelve fields of 12 bytes: client, image id, chan, repl,
            // the rectangle and the clip rectangle.
            try std.testing.expectEqual(144, out.len);
            var f: [12][]const u8 = undefined;
            for (&f, 0..) |*x, i| x.* = std.mem.trim(u8, out[i * 12 ..][0..12], " ");
            const sz = gfx.headless.size().?;
            try std.testing.expectEqualStrings("0", f[1]);
            try std.testing.expectEqualStrings("x8r8g8b8", f[2]);
            for ([_]usize{ 4, 5 }) |i| try std.testing.expectEqualStrings("0", f[i]);
            try std.testing.expectEqual(sz.dx, try std.fmt.parseInt(u32, f[6], 10));
            try std.testing.expectEqual(sz.dy, try std.fmt.parseInt(u32, f[7], 10));
        }
    }.check);
}

/// The screen's pixel at x, y, as 0xRRGGBB.
fn pixelAt(px: []const u8, dx: u32, x: u32, y: u32) u32 {
    return std.mem.readInt(u32, px[(y * dx + x) * 4 ..][0..4], .little) & 0xFFFFFF;
}

test "a draw client's image reaches the screen [15]" {
    try expectGfx(@embedFile("gfx_draw"), true, null, struct {
        fn check(_: []const u8) !void {
            const sz = gfx.headless.size().?;
            const px = try std.testing.allocator.alloc(u8, sz.dx * sz.dy * 4);
            defer std.testing.allocator.free(px);
            try std.testing.expect(gfx.headless.pixels(px));
            // Red inside (10,10)-(60,60), the background around it.
            try std.testing.expectEqual(0xFF0000, pixelAt(px, sz.dx, 10, 10));
            try std.testing.expectEqual(0xFF0000, pixelAt(px, sz.dx, 59, 59));
            try std.testing.expect(pixelAt(px, sz.dx, 5, 5) != 0xFF0000);
            try std.testing.expect(pixelAt(px, sz.dx, 60, 60) != 0xFF0000);
        }
    }.check);
}

test "a key injected into the window reaches /dev/kbd [15]" {
    try expectGfx(@embedFile("gfx_kbd"), true, struct {
        fn act() void {
            gfx.headless.key('a');
        }
    }.act, struct {
        fn check(out: []const u8) !void {
            // kbdfs's format: 'k' and the keys held for a press, 'c' and
            // the character typed, 'K' and the keys still held for a
            // release, each ending in a NUL.
            errdefer std.debug.print("kbd: {any}\n", .{out});
            try std.testing.expectEqualStrings("ka\x00", out);
        }
    }.check);
}

test "a mouse event injected into the window reaches /dev/mouse [15]" {
    try expectGfx(@embedFile("gfx_mouse"), true, struct {
        fn act() void {
            gfx.headless.mouse(100, 200, 1);
        }
    }.act, struct {
        fn check(out: []const u8) !void {
            errdefer std.debug.print("mouse: {s}\n", .{out});
            try std.testing.expectEqual(49, out.len);
            try std.testing.expectEqual('m', out[0]);
            var it = std.mem.tokenizeScalar(u8, out[1..], ' ');
            try std.testing.expectEqualStrings("100", it.next().?);
            try std.testing.expectEqualStrings("200", it.next().?);
            try std.testing.expectEqualStrings("1", it.next().?);
        }
    }.check);
}

test "/dev/snarf reads and writes the host clipboard [15]" {
    gfx.headless.setClipboard("host");
    try expectGfx(@embedFile("gfx_snarf"), true, null, struct {
        fn check(out: []const u8) !void {
            var buf: [64]u8 = undefined;
            try std.testing.expectEqualStrings("guest", gfx.headless.clipboard(&buf));
            try std.testing.expectEqualStrings("host|guest", out);
            gfx.headless.setClipboard("host");
        }
    }.check);
}

test "with --gfx=noclip, /dev/snarf keeps its text but leaves the host clipboard alone [15]" {
    gfx.headless.setClipboard("host");
    try expectGfx(@embedFile("gfx_snarf"), false, null, struct {
        fn check(out: []const u8) !void {
            var buf: [64]u8 = undefined;
            try std.testing.expectEqualStrings("host", gfx.headless.clipboard(&buf));
            // The private buffer starts empty, and holds what's written;
            // a second backend's run sees the first's.
            try std.testing.expect(std.mem.eql(u8, "|guest", out) or std.mem.eql(u8, "guest|guest", out));
        }
    }.check);
}

test "closing the window posts hangup and ends the run [15]" {
    var ran: usize = 0;
    for ([_]vmm.BackendKind{ .hvf, .native, .emu }) |kind| {
        var g: GfxRun = .{};
        defer g.deinit();
        if (!try g.start(kind, .{ .text = @embedFile("gfx_sleep"), .timeout_s = 50 })) continue;
        sleepMs(500);
        try std.testing.expect(g.running());
        gfx.headless.close();
        const st = try g.wait();
        errdefer std.debug.print("backend {t}: {s}\n", .{ kind, st });
        try std.testing.expectEqualStrings("killed hangup", st);
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

test "a second machine in the process gets GfxInUse [15]" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const opts: h9.Machine.Options = .{ .backend = .emu, .arch = .arm64, .gfx = .{}, .stdio = .{ .out = &out.writer, .err = &out.writer } };
    var a = h9.Machine.init(gpa, std.testing.io, opts) catch |e| switch (e) {
        error.BackendNotBuilt, error.WrongArch => return error.SkipZigTest,
        else => return e,
    };
    try std.testing.expectError(error.GfxInUse, h9.Machine.init(gpa, std.testing.io, opts));
    // A machine without a window is fine alongside it.
    var plain = try h9.Machine.init(gpa, std.testing.io, .{ .backend = .emu, .arch = .arm64, .stdio = opts.stdio });
    plain.deinit();
    a.deinit();
    var b = try h9.Machine.init(gpa, std.testing.io, opts);
    b.deinit();
}

/// The root tree for the cases that run rio and acme, from
/// H9_TEST_ROOT (zig build test sets it), or null to skip them.
fn gfxRoot(buf: []u8) ?[]const u8 {
    var map = std.testing.environ.createMap(std.testing.allocator) catch return null;
    defer map.deinit();
    const v = map.get("H9_TEST_ROOT") orelse return null;
    const path = std.Io.Dir.cwd().realPathFile(std.testing.io, v, buf) catch return null;
    const p = buf[0..path];
    var lb: [std.fs.max_path_bytes + 32]u8 = undefined;
    const rio = std.fmt.bufPrint(&lb, "{s}/arm64/bin/rio", .{p}) catch return null;
    std.Io.Dir.cwd().access(std.testing.io, rio, .{}) catch return null;
    return p;
}

test "rio starts, and a window's rc runs a command typed into it [15]" {
    var rb: [std.fs.max_path_bytes]u8 = undefined;
    const root = gfxRoot(&rb) orelse return error.SkipZigTest;
    var ran: usize = 0;
    for ([_]vmm.BackendKind{ .hvf, .native, .emu }) |kind| {
        gfx.headless.setClipboard("");
        var g: GfxRun = .{};
        defer g.deinit();
        if (!try g.start(kind, .{ .guest = "/bin/rio", .argv = &.{ "rio", "-i", "window rc" }, .root = root, .timeout_s = 120 })) continue;
        // Keys typed before rio reads /dev/kbd are dropped, so the line
        // is typed again until the clipboard has what it writes.
        var buf: [64]u8 = undefined;
        var waited: u32 = 0;
        while (g.running() and waited < 90_000) : (waited += 100) {
            if (waited % 3000 == 0) for ("echo hi > /dev/snarf\n") |ch| gfx.headless.key(ch);
            if (std.mem.eql(u8, gfx.headless.clipboard(&buf), "hi\n")) break;
            sleepMs(100);
        }
        errdefer std.debug.print("backend {t}: stderr: {s}\n", .{ kind, g.err.written() });
        try std.testing.expectEqualStrings("hi\n", gfx.headless.clipboard(&buf));
        gfx.headless.close();
        _ = try g.wait();
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

test "acme starts inside rio [15]" {
    var rb: [std.fs.max_path_bytes]u8 = undefined;
    const root = gfxRoot(&rb) orelse return error.SkipZigTest;
    var ran: usize = 0;
    for ([_]vmm.BackendKind{ .hvf, .native, .emu }) |kind| {
        var g: GfxRun = .{};
        defer g.deinit();
        if (!try g.start(kind, .{ .guest = "/bin/rio", .argv = &.{ "rio", "-i", "window -r 0 0 640 480 acme" }, .root = root, .timeout_s = 120 })) continue;
        // acme's body is pale yellow, a color nothing else here draws.
        const sz_wait = 90_000;
        var waited: u32 = 0;
        var yellow: usize = 0;
        while (g.running() and waited < sz_wait) : (waited += 500) {
            sleepMs(500);
            const sz = gfx.headless.size() orelse continue;
            const px = try std.testing.allocator.alloc(u8, sz.dx * sz.dy * 4);
            defer std.testing.allocator.free(px);
            if (!gfx.headless.pixels(px)) continue;
            yellow = 0;
            var i: usize = 0;
            while (i < px.len) : (i += 4) {
                if (std.mem.readInt(u32, px[i..][0..4], .little) & 0xFFFFFF == 0xFFFFEA) yellow += 1;
            }
            if (yellow > 10_000) break;
        }
        errdefer std.debug.print("backend {t}: {d} acme-yellow pixels; stderr: {s}\n", .{ kind, yellow, g.err.written() });
        try std.testing.expect(yellow > 10_000);
        gfx.headless.close();
        _ = try g.wait();
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}
