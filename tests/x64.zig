//! zig build x64-jit (and vcpu): hx64's cases, tagged [hcpu], each to run
//! on T0 alone and on T1 through dispatch, as tests/x86.zig runs h86's.
//! design/hcpu.md's Done when lists them: the long-mode ones,
//!
//! - a 32-bit write zeroes the upper half of a 64-bit register
//! - a RIP-relative load reads past the instruction
//! - INT 0x80 in long mode raises #GP
//! - four CMPXCHG16B threads lose no increments
//! - arch_prctl's FS base reaches FS-relative loads on T0 and T1
//!
//! and h86's, in long mode: a DIV by zero, a REP MOVSB stopped by a fault,
//! a REP stopped between iterations, a store into the executing page, an
//! instruction crossing into an unmapped page, CPUID reporting SSE2 and no
//! AVX, and LOCK XADD on four threads.
//!
//! The machine is tests/x86.zig's: code at 0x1000 (two pages, writable),
//! data at 0x20000, stack at 0x21000, and nothing mapped at 0x3000 or
//! 0x22000. The cases run on T0 (exec.runIn(.long)); T1 joins each when
//! src/jit/x86/t1.zig runs long mode (workstream F). Until long-mode T0
//! runs (workstreams A and B), they skip.

const std = @import("std");
const vcpu = @import("vcpu");
const cpu_mod = vcpu.x86.cpu;
const exec = vcpu.x86.exec;
const Cpu = cpu_mod.Cpu64;
const Exit = cpu_mod.Exit64;
const testing = std.testing;
const page_size = vcpu.mem.page_size;

comptime {
    // The long-mode types the cases run on.
    _ = vcpu.x86.decode.InstOf(.long);
    _ = vcpu.x86jit.lift.frontendFor(.long);
}

const code_va: u64 = 0x1000;
const data_va: u64 = 0x20000;

/// The tiers a case runs on: T0 alone so far.
const Tier = enum { t0 };

/// Code pages at 0x1000 and 0x2000, data and stack at 0x20000 and
/// 0x21000.
const Machine = struct {
    code: [2 * page_size]u8 align(page_size) = @splat(0xcc),
    data: [2 * page_size]u8 align(page_size) = @splat(0),
    cpu: Cpu = .{},

    pub fn translate(m: *Machine, va: u64, access: cpu_mod.Access) ?[*]u8 {
        if (va >= code_va and va - code_va < m.code.len) return m.code[@intCast(va - code_va)..].ptr;
        if (va >= data_va and va - data_va < m.data.len) return if (access == .exec) null else m.data[@intCast(va - data_va)..].ptr;
        return null;
    }

    fn load(m: *Machine, prog: []const u8, regs: [16]u64) void {
        @memcpy(m.code[0..prog.len], prog);
        m.cpu = .{};
        m.cpu.r = regs;
        if (m.cpu.r[4] == 0) m.cpu.r[4] = data_va + page_size + page_size / 2;
        m.cpu.rip = code_va;
        m.cpu.fl.set(0x202);
    }

    fn run(m: *Machine) Exit {
        return exec.runIn(.long, &m.cpu, m, .{});
    }

    fn word(m: *Machine, off: usize) *align(1) u64 {
        return @ptrCast(m.data[off..][0..8]);
    }
};

fn longRuns() bool {
    return vcpu.check.x86.longRuns();
}

/// Runs `prog` on each tier with `regs` and calls `check` with the exit.
fn onEachTier(prog: []const u8, regs: [16]u64, check: *const fn (t: Tier, m: *Machine, e: Exit) anyerror!void) !void {
    if (!longRuns()) return error.SkipZigTest;
    for (std.enums.values(Tier)) |t| {
        const m = try testing.allocator.create(Machine);
        defer testing.allocator.destroy(m);
        m.* = .{};
        m.load(prog, regs);
        const e = m.run();
        check(t, m, e) catch |err| {
            std.debug.print("on {t}: exit {any}, rip {x}, rax {x}\n", .{ t, e, m.cpu.rip, m.cpu.r[0] });
            return err;
        };
    }
}

fn expectException(e: Exit, vector: u8) !void {
    switch (e) {
        .exception => |v| try testing.expectEqual(vector, v),
        else => return error.WrongExit,
    }
}

fn expectSyscall(e: Exit) !void {
    if (e != .syscall) return error.WrongExit;
}

const syscall = [_]u8{ 0x0f, 0x05 };

test "a 32-bit write zeroes the upper half of a 64-bit register [hcpu]" {
    const prog = [_]u8{
        0x48, 0xc7, 0xc0, 0xff, 0xff, 0xff, 0xff, // movq $-1, %rax
        0x90, // nop (xchg %eax, %eax, which doesn't zero-extend)
        0x48, 0x89, 0xc3, // movq %rax, %rbx
        0xb8, 0x01, 0x00, 0x00, 0x00, // movl $1, %eax
        0x48, 0xc7, 0xc1, 0xff, 0xff, 0xff, 0xff, // movq $-1, %rcx
        0x83, 0xc1, 0x01, // addl $1, %ecx
        0x49, 0xc7, 0xc1, 0xff, 0xff, 0xff, 0xff, // movq $-1, %r9
        0x45, 0x31, 0xc9, // xorl %r9d, %r9d
        0x48, 0xc7, 0xc2, 0xff, 0xff, 0xff, 0xff, // movq $-1, %rdx
        0x66, 0xba, 0x34, 0x12, // movw $0x1234, %dx: 16 bits merge
        0xb2, 0x56, // movb $0x56, %dl: and 8
        0x48, 0xc7, 0xc7, 0xff, 0xff, 0xff, 0xff, // movq $-1, %rdi
        0x85, 0xc0, // testl %eax, %eax: ZF clear
        0x0f, 0x44, 0xf9, // cmovel %ecx, %edi: not taken, and still zero-extends
    } ++ syscall;
    try onEachTier(&prog, @splat(0), struct {
        fn f(_: Tier, m: *Machine, e: Exit) !void {
            try expectSyscall(e);
            const r = &m.cpu.r;
            try testing.expectEqual(@as(u64, 1), r[0]);
            try testing.expectEqual(~@as(u64, 0), r[3]);
            try testing.expectEqual(@as(u64, 0), r[1]);
            try testing.expectEqual(@as(u64, 0), r[9]);
            try testing.expectEqual(@as(u64, 0xffff_ffff_ffff_1256), r[2]);
            try testing.expectEqual(@as(u64, 0xffff_ffff), r[7]);
        }
    }.f);
}

test "a RIP-relative load reads past the instruction [hcpu]" {
    const prog = [_]u8{
        0x48, 0x8d, 0x0d, 0xf9, 0xff, 0xff, 0xff, // leaq -7(%rip), %rcx: itself, 0x1000
        0x48, 0x8b, 0x05, 0x02, 0x00, 0x00, 0x00, // movq 2(%rip), %rax: 0x1010
        0x0f, 0x05, // syscall (0x100e)
        0x88, 0x77,
        0x66, 0x55,
        0x44, 0x33,
        0x22, 0x11,
    };
    try onEachTier(&prog, @splat(0), struct {
        fn f(_: Tier, m: *Machine, e: Exit) !void {
            try expectSyscall(e);
            try testing.expectEqual(code_va, m.cpu.r[1]);
            try testing.expectEqual(@as(u64, 0x1122_3344_5566_7788), m.cpu.r[0]);
            try testing.expectEqual(code_va + 0x10, m.cpu.rip);
        }
    }.f);
}

test "INT 0x80 in long mode raises #GP [hcpu]" {
    // At the INT, with nothing done; INT $64 likewise.
    for ([_]u8{ 0x80, 0x40 }) |v| {
        const prog = [_]u8{ 0x90, 0xcd, v } ++ syscall;
        try onEachTier(&prog, @splat(0), struct {
            fn f(_: Tier, m: *Machine, e: Exit) !void {
                try expectException(e, cpu_mod.vec_gp);
                try testing.expectEqual(code_va + 1, m.cpu.rip);
            }
        }.f);
    }
}

/// Four T0 vCPUs on host threads, over one code page and one data page.
const Shared = struct {
    code: [page_size]u8 align(page_size) = @splat(0xcc),
    data: [page_size]u8 align(page_size) = @splat(0),

    pub fn translate(s: *Shared, va: u64, access: cpu_mod.Access) ?[*]u8 {
        const page = va & ~@as(u64, page_size - 1);
        const off: usize = @intCast(va - page);
        if (page == code_va and access != .write) return s.code[off..].ptr;
        if (page == data_va) return s.data[off..].ptr;
        return null;
    }
};

/// Runs `prog` on four T0 threads; returns the u64 at the data page.
fn fourThreads(prog: []const u8) !u64 {
    const s = try testing.allocator.create(Shared);
    defer testing.allocator.destroy(s);
    s.* = .{};
    @memcpy(s.code[0..prog.len], prog);
    const Worker = struct {
        fn run(sh: *Shared, out: *Exit) void {
            var c: Cpu = .{};
            c.rip = code_va;
            while (true) {
                out.* = exec.runIn(.long, &c, sh, .{});
                if (out.* != .stopped) return;
            }
        }
    };
    var exits: [4]Exit = undefined;
    var threads: [4]std.Thread = undefined;
    for (&threads, &exits) |*t, *e| t.* = try std.Thread.spawn(.{}, Worker.run, .{ s, e });
    for (threads) |t| t.join();
    for (exits) |e| try expectSyscall(e);
    return std.mem.readInt(u64, s.data[0..8], .little);
}

test "four CMPXCHG16B threads lose no increments [hcpu]" {
    if (!longRuns()) return error.SkipZigTest;
    const n = 50_000;
    comptime std.debug.assert(n == 0xc350);
    const prog = [_]u8{
        0xbf, 0x00, 0x00, 0x02, 0x00, // movl $0x20000, %edi
        0xbe, 0x50, 0xc3, 0x00, 0x00, // movl $50000, %esi
        0x48, 0x8b, 0x07, // loop: movq (%rdi), %rax
        0x48, 0x8b, 0x57, 0x08, // movq 8(%rdi), %rdx
        0x48, 0x8d, 0x58, 0x01, // retry: leaq 1(%rax), %rbx
        0x48, 0x89, 0xd1, // movq %rdx, %rcx
        0xf0, 0x48, 0x0f, 0xc7, 0x0f, // lock cmpxchg16b (%rdi)
        0x75, 0xf2, // jnz retry
        0xff, 0xce, // decl %esi
        0x75, 0xe7, // jnz loop
    } ++ syscall;
    try testing.expectEqual(@as(u64, 4 * n), try fourThreads(&prog));
}

test "four LOCK XADD threads on T0 lose nothing [hcpu]" {
    if (!longRuns()) return error.SkipZigTest;
    const n = 200_000;
    comptime std.debug.assert(n == 0x30d40);
    const prog = [_]u8{
        0xbe, 0x40, 0x0d, 0x03, 0x00, // movl $200000, %esi
        0xb9, 0x01, 0x00, 0x00, 0x00, // loop: movl $1, %ecx
        0xf0, 0x48, 0x0f, 0xc1, 0x0c, 0x25, 0x00, 0x00, 0x02, 0x00, // lock xaddq %rcx, 0x20000
        0xff, 0xce, // decl %esi
        0x75, 0xed, // jnz loop
    } ++ syscall;
    try testing.expectEqual(@as(u64, 4 * n), try fourThreads(&prog));
}

test "arch_prctl's FS base reaches FS-relative loads on T0 and T1 [hcpu]" {
    // The base as arch_prctl(ARCH_SET_FS) leaves it in the Cpu.
    const prog = [_]u8{
        0x64, 0x48, 0x8b, 0x04, 0x25, 0x10, 0x00, 0x00, 0x00, // movq %fs:0x10, %rax
        0x64, 0x48, 0x8b, 0x0b, // movq %fs:(%rbx), %rcx
        0x64, 0x48, 0x89, 0x04, 0x25, 0x18, 0x00, 0x00, 0x00, // movq %rax, %fs:0x18
        0x48, 0x8b, 0x14, 0x25, 0x10, 0x01, 0x02, 0x00, // movq 0x20110, %rdx: no base
    } ++ syscall;
    if (!longRuns()) return error.SkipZigTest;
    const m = try testing.allocator.create(Machine);
    defer testing.allocator.destroy(m);
    m.* = .{};
    var regs: [16]u64 = @splat(0);
    regs[3] = 0x20;
    m.load(&prog, regs);
    m.cpu.fs_base = data_va + 0x100;
    m.word(0x110).* = 0xdead_beef_cafe_f00d;
    m.word(0x120).* = 0x0123_4567_89ab_cdef;
    try expectSyscall(m.run());
    try testing.expectEqual(@as(u64, 0xdead_beef_cafe_f00d), m.cpu.r[0]);
    try testing.expectEqual(@as(u64, 0x0123_4567_89ab_cdef), m.cpu.r[1]);
    try testing.expectEqual(@as(u64, 0xdead_beef_cafe_f00d), m.word(0x118).*);
    try testing.expectEqual(@as(u64, 0xdead_beef_cafe_f00d), m.cpu.r[2]);
}

test "a DIV by zero gives vector 0 at the DIV [hcpu]" {
    const prog = [_]u8{
        0x31, 0xc9, // xorl %ecx, %ecx
        0x48, 0xf7, 0xf1, // divq %rcx (at 0x1002)
    } ++ syscall;
    var regs: [16]u64 = @splat(0);
    regs[0] = 7;
    try onEachTier(&prog, regs, struct {
        fn f(_: Tier, m: *Machine, e: Exit) !void {
            try expectException(e, cpu_mod.vec_de);
            try testing.expectEqual(code_va + 2, m.cpu.rip);
            try testing.expectEqual(@as(u64, 7), m.cpu.r[0]);
        }
    }.f);
    // A quotient past 64 bits: RDX:RAX = 2^64, divided by 1.
    const big = [_]u8{
        0xb9, 0x01, 0x00, 0x00, 0x00, // movl $1, %ecx
        0x48, 0xf7, 0xf1, // divq %rcx (at 0x1005)
    } ++ syscall;
    regs[2] = 1;
    regs[0] = 0;
    try onEachTier(&big, regs, struct {
        fn f(_: Tier, m: *Machine, e: Exit) !void {
            try expectException(e, cpu_mod.vec_de);
            try testing.expectEqual(code_va + 5, m.cpu.rip);
            try testing.expectEqual(@as(u64, 1), m.cpu.r[2]);
        }
    }.f);
}

/// movsb from 0x20000 to 0x21f00, 0x200 bytes: the 0x101st store is to
/// 0x22000, which isn't mapped.
const rep_prog = [_]u8{
    0xbe, 0x00, 0x00, 0x02, 0x00, // movl $0x20000, %esi
    0xbf, 0x00, 0x1f, 0x02, 0x00, // movl $0x21f00, %edi
    0xb9, 0x00, 0x02, 0x00, 0x00, // movl $0x200, %ecx
    0xf3, 0xa4, // rep movsb (at 0x100f)
} ++ syscall;

test "a REP MOVSB stopped by a fault is exact, and resumes [hcpu]" {
    var regs: [16]u64 = @splat(0);
    // The 32-bit moves zero these.
    regs[1] = 0xffff_ffff_0000_0000;
    regs[6] = 0xffff_ffff_0000_0000;
    try onEachTier(&rep_prog, regs, struct {
        fn f(_: Tier, m: *Machine, e: Exit) !void {
            switch (e) {
                .fault => |pf| {
                    try testing.expectEqual(@as(u64, 0x22000), pf.addr);
                    try testing.expectEqual(cpu_mod.Access.write, pf.access);
                },
                else => return error.WrongExit,
            }
            const c = &m.cpu;
            try testing.expectEqual(code_va + 15, c.rip);
            try testing.expectEqual(@as(u64, 0x100), c.r[1]);
            try testing.expectEqual(@as(u64, 0x20100), c.r[6]);
            try testing.expectEqual(@as(u64, 0x22000), c.r[7]);
            try testing.expectEqualSlices(u8, m.data[0..0x100], m.data[0x1f00..0x2000]);
            c.r[1] = 0;
            try expectSyscall(m.run());
        }
    }.f);
}

test "a REP stopped between iterations on T0 resumes exactly [hcpu]" {
    if (!longRuns()) return error.SkipZigTest;
    // The stop word is guest memory the program sets: T0 sees it between
    // REP iterations (every 4096), so the REP stops part way, at itself.
    const prog = [_]u8{
        0xc7, 0x04, 0x25, 0xfc, 0x1f, 0x02, 0x00, 0x01, 0x00, 0x00, 0x00, // movl $1, 0x21ffc
        0xbe, 0x00, 0x00, 0x02, 0x00, // movl $0x20000, %esi
        0xb9, 0x00, 0x20, 0x00, 0x00, // movl $0x2000, %ecx
        0xf3, 0xac, // rep lodsb (at 0x1015)
    } ++ syscall;
    const ref = try testing.allocator.create(Machine);
    defer testing.allocator.destroy(ref);
    ref.* = .{};
    ref.load(&prog, @splat(0));
    try expectSyscall(ref.run());

    const m = try testing.allocator.create(Machine);
    defer testing.allocator.destroy(m);
    m.* = .{};
    m.load(&prog, @splat(0));
    const word: *std.atomic.Value(u32) = @ptrCast(@alignCast(m.data[0x1ffc..][0..4]));
    word.store(0, .monotonic);
    const c = &m.cpu;
    try testing.expectEqual(Exit.stopped, exec.runIn(.long, c, m, .{ .stop = word }));
    try testing.expectEqual(code_va + 0x15, c.rip);
    try testing.expectEqual(@as(u64, 0x2000 - 4095), c.r[1]);
    try testing.expectEqual(@as(u64, 0x20000 + 4095), c.r[6]);
    word.store(0, .monotonic);
    try expectSyscall(exec.runIn(.long, c, m, .{ .stop = word }));
    m.data[0x1ffc] = 1;
    try testing.expectEqualSlices(u64, &ref.cpu.r, &c.r);
    try testing.expectEqual(ref.cpu.rip, c.rip);
    try testing.expectEqualSlices(u8, &ref.data, &m.data);
}

test "a store into the executing page takes effect at the next instruction [hcpu]" {
    const prog = [_]u8{
        0xc6, 0x05, 0x01, 0x00, 0x00, 0x00, 0x2a, // movb $0x2a, 1(%rip): 0x1008
        0xb8, 0x01, 0x00, 0x00, 0x00, // movl $1, %eax (0x1007; its immediate at 0x1008)
    } ++ syscall;
    try onEachTier(&prog, @splat(0), struct {
        fn f(_: Tier, m: *Machine, e: Exit) !void {
            try expectSyscall(e);
            try testing.expectEqual(@as(u64, 0x2a), m.cpu.r[0]);
        }
    }.f);
}

test "an instruction crossing into an unmapped page faults at its first byte [hcpu]" {
    // jmp to 0x2ffe, where movabs $imm, %rax runs into 0x3000.
    var prog: [0x2000]u8 = @splat(0x90);
    prog[0] = 0xe9;
    std.mem.writeInt(u32, prog[1..5], 0x2ffe - (code_va + 5), .little);
    prog[0x1ffe] = 0x48;
    prog[0x1fff] = 0xb8;
    var regs: [16]u64 = @splat(0);
    regs[0] = 5;
    try onEachTier(&prog, regs, struct {
        fn f(_: Tier, m: *Machine, e: Exit) !void {
            switch (e) {
                .fault => |pf| {
                    try testing.expectEqual(@as(u64, 0x3000), pf.addr);
                    try testing.expectEqual(cpu_mod.Access.exec, pf.access);
                },
                else => return error.WrongExit,
            }
            try testing.expectEqual(@as(u64, 0x2ffe), m.cpu.rip);
            try testing.expectEqual(@as(u64, 5), m.cpu.r[0]);
        }
    }.f);
}

test "CPUID reports SSE2 and no AVX [hcpu]" {
    const prog = [_]u8{
        0xb8, 0x01, 0x00, 0x00, 0x00, // movl $1, %eax
        0x0f, 0xa2, // cpuid
        0x49, 0x89, 0xc8, // movq %rcx, %r8
        0x49, 0x89, 0xd1, // movq %rdx, %r9
        0xb8, 0x01, 0x00, 0x00, 0x80, // movl $0x80000001, %eax
        0x0f, 0xa2, // cpuid
    } ++ syscall;
    var regs: [16]u64 = @splat(0);
    regs[1] = 0xffff_ffff_ffff_ffff;
    try onEachTier(&prog, regs, struct {
        fn f(_: Tier, m: *Machine, e: Exit) !void {
            try expectSyscall(e);
            const ecx = m.cpu.r[8];
            const edx = m.cpu.r[9];
            // CPUID writes 32 bits, zero-extended.
            try testing.expect(ecx >> 32 == 0 and edx >> 32 == 0);
            try testing.expect(edx & (1 << 25) != 0); // SSE
            try testing.expect(edx & (1 << 26) != 0); // SSE2
            try testing.expect(ecx & (1 << 13) != 0); // CMPXCHG16B
            try testing.expect(ecx & (1 << 28) == 0); // AVX
            try testing.expect(ecx & (1 << 27) == 0); // OSXSAVE
            try testing.expect(ecx & (1 << 26) == 0); // XSAVE
            try testing.expect(ecx & (1 << 0) == 0); // SSE3
            // Extended: long mode, and LAHF and SAHF in it.
            try testing.expect(m.cpu.r[2] & (1 << 29) != 0); // LM
            try testing.expect(m.cpu.r[1] & (1 << 0) != 0); // LAHF-SAHF
        }
    }.f);
}
