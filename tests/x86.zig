//! zig build vcpu (and x86-jit): the 386 JIT plan's [x86-jit] cases, each
//! run on T0 alone and on T1 through dispatch, with ir_eval and with this
//! host's emitter. The machine is src/jit/x86/t1.zig's: code at 0x1000
//! (two pages, writable), data at 0x20000, stack at 0x21000, and nothing
//! mapped at 0x3000 or 0x22000.
//!
//! A LOCK XADD counter on four threads is here for T0; on compiled code
//! it's tests/jit/litmus_x86.zig's counter test.

const std = @import("std");
const builtin = @import("builtin");
const vcpu = @import("vcpu");
const t1 = vcpu.x86jit.t1;
const cpu_mod = vcpu.x86.cpu;
const exec = vcpu.x86.exec;
const Exit = cpu_mod.Exit;
const Machine = t1.Machine;
const testing = std.testing;

const code_va: u32 = 0x1000;
const data_va: u32 = 0x20000;

/// The tiers a case runs on.
const Tier = enum { t0, t1_eval, t1_native };

fn emitterOf(t: Tier) ?vcpu.emitter.Emitter {
    return switch (t) {
        .t0 => null,
        .t1_eval => vcpu.emit.eval.emitter_def,
        .t1_native => if (builtin.cpu.arch == .x86_64) vcpu.emit.x64.emitter_def else null,
    };
}

/// One machine on one tier, for a case.
const Run = struct {
    m: *Machine,
    cache: ?*vcpu.cache.Cache,

    fn init(t: Tier) !?Run {
        var cache: ?*vcpu.cache.Cache = null;
        if (t != .t0) {
            const em = emitterOf(t) orelse return null;
            cache = t1.testCache(1 << 20) catch |e| switch (e) {
                error.SkipZigTest => return null,
                else => return e,
            };
            const m = try testing.allocator.create(Machine);
            m.* = .{};
            try m.init(cache);
            m.em = em;
            return .{ .m = m, .cache = cache };
        }
        const m = try testing.allocator.create(Machine);
        m.* = .{};
        try m.init(null);
        return .{ .m = m, .cache = null };
    }

    fn deinit(r: Run) void {
        r.m.deinit();
        testing.allocator.destroy(r.m);
        if (r.cache) |c| t1.freeCache(c);
    }

    fn data(r: Run, off: usize) *align(1) u32 {
        return @ptrCast(r.m.pages[2 * vcpu.mem.page_size + off ..][0..4]);
    }
};

/// Runs `prog` on each tier with `regs` and calls `check` with the exit.
fn onEachTier(prog: []const u8, regs: [8]u32, check: *const fn (t: Tier, r: Run, e: Exit) anyerror!void) !void {
    for (std.enums.values(Tier)) |t| {
        const r = try Run.init(t) orelse continue;
        defer r.deinit();
        r.m.load(prog, regs, 0x202, 1);
        const e = try r.m.run();
        check(t, r, e) catch |err| {
            std.debug.print("on {t}: exit {any}, eip {x}, eax {x}\n", .{ t, e, r.m.cpu.eip, r.m.cpu.r[0] });
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

test "[x86-jit] a DIV by zero gives vector 0 at the DIV" {
    const prog = [_]u8{
        0x31, 0xc9, // xorl %ecx, %ecx
        0xf7, 0xf1, // divl %ecx (at 0x1002)
        0xcd, 0x80,
    };
    try onEachTier(&prog, .{ 7, 0, 0, 0, 0, 0, 0, 0 }, struct {
        fn f(_: Tier, r: Run, e: Exit) !void {
            try expectException(e, cpu_mod.vec_de);
            try testing.expectEqual(code_va + 2, r.m.cpu.eip);
            // Nothing changed: EAX and EDX are as they were.
            try testing.expectEqual(@as(u32, 7), r.m.cpu.r[0]);
        }
    }.f);
}

test "[x86-jit] fistp truncates under RC=chop" {
    const prog = [_]u8{
        0xc7, 0x05, 0x00, 0x00, 0x02, 0x00, 0xcd, 0xcc, 0x2c, 0x40, // movl $2.7f, 0x20000
        0xc7, 0x05, 0x04, 0x00, 0x02, 0x00, 0x7f, 0x0f, 0x00, 0x00, // movl $0xf7f, 0x20004
        0xd9, 0x05, 0x00, 0x00, 0x02, 0x00, // flds 0x20000
        0xdb, 0x1d, 0x10, 0x00, 0x02, 0x00, // fistpl 0x20010: nearest, 3
        0xd9, 0x2d, 0x04, 0x00, 0x02, 0x00, // fldcw 0x20004: RC=11, chop
        0xd9, 0x05, 0x00, 0x00, 0x02, 0x00, // flds 0x20000
        0xdb, 0x1d, 0x08, 0x00, 0x02, 0x00, // fistpl 0x20008: 2
        0xd9, 0x05, 0x00, 0x00, 0x02, 0x00, // flds 0x20000
        0xd9, 0xe0, // fchs
        0xdb, 0x1d, 0x0c, 0x00, 0x02, 0x00, // fistpl 0x2000c: -2
        0xcd, 0x80,
    };
    try onEachTier(&prog, @splat(0), struct {
        fn f(_: Tier, r: Run, e: Exit) !void {
            try expectSyscall(e);
            try testing.expectEqual(@as(u32, 3), r.data(0x10).*);
            try testing.expectEqual(@as(u32, 2), r.data(0x08).*);
            try testing.expectEqual(@as(u32, @bitCast(@as(i32, -2))), r.data(0x0c).*);
        }
    }.f);
}

test "[x86-jit] x87 results are the same bits on every host" {
    const prog = [_]u8{
        0xd9, 0xe8, // fld1
        0xd9, 0xe8, // fld1
        0xde, 0xc1, // faddp
        0xd9, 0xfa, // fsqrt
        0xdb, 0x3d, 0x10, 0x00, 0x02, 0x00, // fstpt 0x20010
        0xc7, 0x05, 0x00, 0x00, 0x02, 0x00, 0x03, 0x00, 0x00, 0x00, // movl $3, 0x20000
        0xd9, 0xe8, // fld1
        0xda, 0x35, 0x00, 0x00, 0x02, 0x00, // fidivl 0x20000
        0xdb, 0x3d, 0x20, 0x00, 0x02, 0x00, // fstpt 0x20020
        0xcd, 0x80,
    };
    try onEachTier(&prog, @splat(0), struct {
        fn f(_: Tier, r: Run, e: Exit) !void {
            try expectSyscall(e);
            const d = r.m.pages[2 * vcpu.mem.page_size ..];
            // sqrt(2) and 1/3, rounded to nearest in 64 bits, as an x87 has
            // them.
            try testing.expectEqual(@as(u64, 0xb504f333f9de6484), std.mem.readInt(u64, d[0x10..0x18], .little));
            try testing.expectEqual(@as(u16, 0x3fff), std.mem.readInt(u16, d[0x18..0x1a], .little));
            try testing.expectEqual(@as(u64, 0xaaaaaaaaaaaaaaab), std.mem.readInt(u64, d[0x20..0x28], .little));
            try testing.expectEqual(@as(u16, 0x3ffd), std.mem.readInt(u16, d[0x28..0x2a], .little));
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
    0xcd, 0x80,
};

test "[x86-jit] a REP MOVSB stopped by a fault is exact, and resumes" {
    try onEachTier(&rep_prog, @splat(0), struct {
        fn f(_: Tier, r: Run, e: Exit) !void {
            switch (e) {
                .fault => |pf| {
                    try testing.expectEqual(@as(u32, 0x22000), pf.addr);
                    try testing.expectEqual(cpu_mod.Access.write, pf.access);
                },
                else => return error.WrongExit,
            }
            const c = &r.m.cpu;
            try testing.expectEqual(code_va + 15, c.eip);
            try testing.expectEqual(@as(u32, 0x100), c.r[1]);
            try testing.expectEqual(@as(u32, 0x20100), c.r[6]);
            try testing.expectEqual(@as(u32, 0x22000), c.r[7]);
            const d = r.m.pages[2 * vcpu.mem.page_size ..];
            try testing.expectEqualSlices(u8, d[0..0x100], d[0x1f00..0x2000]);
            // Resuming with a count that fits finishes the copy.
            c.r[1] = 0;
            try expectSyscall(try r.m.run());
        }
    }.f);
}

test "[x86-jit] a REP stopped between iterations on T0 resumes exactly" {
    // The stop word is guest memory the program sets: T0 sees it between
    // REP iterations (every 4096), so the REP stops part way, at itself.
    const prog = [_]u8{
        0xc7, 0x05, 0xfc, 0x1f, 0x02, 0x00, 0x01, 0x00, 0x00, 0x00, // movl $1, 0x21ffc
        0xbe, 0x00, 0x00, 0x02, 0x00, // movl $0x20000, %esi
        0xb9, 0x00, 0x20, 0x00, 0x00, // movl $0x2000, %ecx
        0xf3, 0xac, // rep lodsb (at 0x1014)
        0xcd, 0x80,
    };
    const ref = (try Run.init(.t0)).?;
    defer ref.deinit();
    ref.m.load(&prog, @splat(0), 0x202, 1);
    try expectSyscall(try ref.m.run());

    const r = (try Run.init(.t0)).?;
    defer r.deinit();
    r.m.load(&prog, @splat(0), 0x202, 1);
    const word: *std.atomic.Value(u32) = @ptrCast(@alignCast(r.data(0x1ffc)));
    word.store(0, .monotonic);
    const c = &r.m.cpu;
    try testing.expectEqual(Exit.stopped, exec.run(c, &r.m.pm, .{ .stop = word }));
    try testing.expectEqual(code_va + 0x14, c.eip);
    try testing.expectEqual(@as(u32, 0x2000 - 4095), c.r[1]);
    try testing.expectEqual(@as(u32, 0x20000 + 4095), c.r[6]);
    try testing.expectEqual(@as(u32, r.m.pages[2 * vcpu.mem.page_size + 4094]), c.r[0] & 0xff);
    word.store(0, .monotonic);
    try expectSyscall(exec.run(c, &r.m.pm, .{ .stop = word }));
    // The flag word differs: the reference left it set.
    r.data(0x1ffc).* = 1;
    try testing.expectEqualSlices(u32, &ref.m.cpu.r, &c.r);
    try testing.expectEqual(ref.m.cpu.eip, c.eip);
    try testing.expectEqualSlices(u8, &ref.m.pages, &r.m.pages);
}

test "[x86-jit] a store into the executing page takes effect at the next instruction" {
    const prog = [_]u8{
        0xc6, 0x05, 0x08, 0x10, 0x00, 0x00, 0x2a, // movb $0x2a, 0x1008
        0xb8, 0x01, 0x00, 0x00, 0x00, // movl $1, %eax (0x1007; its immediate at 0x1008)
        0xcd, 0x80,
    };
    try onEachTier(&prog, @splat(0), struct {
        fn f(_: Tier, r: Run, e: Exit) !void {
            try expectSyscall(e);
            try testing.expectEqual(@as(u32, 0x2a), r.m.cpu.r[0]);
        }
    }.f);
}

test "[x86-jit] an instruction crossing into an unmapped page faults at its first byte" {
    // jmp to 0x2ffe, where movl $imm, %eax runs into 0x3000.
    var prog: [0x1fff]u8 = @splat(0x90);
    prog[0] = 0xe9;
    std.mem.writeInt(u32, prog[1..5], 0x2ffe - (code_va + 5), .little);
    prog[0x1ffe] = 0xb8;
    try onEachTier(&prog, .{ 5, 0, 0, 0, 0, 0, 0, 0 }, struct {
        fn f(_: Tier, r: Run, e: Exit) !void {
            switch (e) {
                .fault => |pf| {
                    try testing.expectEqual(@as(u32, 0x3000), pf.addr);
                    try testing.expectEqual(cpu_mod.Access.exec, pf.access);
                },
                else => return error.WrongExit,
            }
            try testing.expectEqual(@as(u32, 0x2ffe), r.m.cpu.eip);
            try testing.expectEqual(@as(u32, 5), r.m.cpu.r[0]);
        }
    }.f);
}

test "[x86-jit] an unknown GS selector raises #GP" {
    const prog = [_]u8{
        0x66, 0xb8, 0x2b, 0x00, // movw $0x2b, %ax
        0x8e, 0xe8, // movw %ax, %gs (at 0x1004)
        0xcd, 0x80,
    };
    try onEachTier(&prog, @splat(0), struct {
        fn f(_: Tier, r: Run, e: Exit) !void {
            try expectException(e, cpu_mod.vec_gp);
            try testing.expectEqual(code_va + 4, r.m.cpu.eip);
        }
    }.f);
    // And the null selector GS starts with faults on use.
    const use = [_]u8{
        0x65, 0xa1, 0x00, 0x00, 0x00, 0x00, // movl %gs:0, %eax
        0xcd, 0x80,
    };
    try onEachTier(&use, @splat(0), struct {
        fn f(_: Tier, r: Run, e: Exit) !void {
            try expectException(e, cpu_mod.vec_gp);
            try testing.expectEqual(code_va, r.m.cpu.eip);
        }
    }.f);
}

test "[x86-jit] CPUID reports SSE2 and no AVX" {
    const prog = [_]u8{
        0xb8, 0x01, 0x00, 0x00, 0x00, // movl $1, %eax
        0x0f, 0xa2, // cpuid
        0xcd, 0x80,
    };
    try onEachTier(&prog, @splat(0), struct {
        fn f(_: Tier, r: Run, e: Exit) !void {
            try expectSyscall(e);
            const ecx = r.m.cpu.r[1];
            const edx = r.m.cpu.r[2];
            try testing.expect(edx & (1 << 25) != 0); // SSE
            try testing.expect(edx & (1 << 26) != 0); // SSE2
            try testing.expect(ecx & (1 << 28) == 0); // AVX
            try testing.expect(ecx & (1 << 27) == 0); // OSXSAVE
            try testing.expect(ecx & (1 << 26) == 0); // XSAVE
        }
    }.f);
}

/// Four T0 vCPUs on host threads, over one code page and one data page.
const Shared = struct {
    code: [vcpu.mem.page_size]u8 align(vcpu.mem.page_size) = @splat(0xcc),
    data: [vcpu.mem.page_size]u8 align(vcpu.mem.page_size) = @splat(0),

    pub fn translate(s: *Shared, va: u32, access: cpu_mod.Access) ?[*]u8 {
        const page = va & ~@as(u32, vcpu.mem.page_size - 1);
        const off = va - page;
        if (page == code_va and access != .write) return s.code[off..].ptr;
        if (page == data_va) return s.data[off..].ptr;
        return null;
    }
};

test "[x86-jit] four LOCK XADD threads on T0 lose nothing" {
    const n = 200_000;
    const s = try testing.allocator.create(Shared);
    defer testing.allocator.destroy(s);
    s.* = .{};
    const prog = [_]u8{
        0xbe, 0x40, 0x0d, 0x03, 0x00, // movl $200000, %esi
        0xb9, 0x01, 0x00, 0x00, 0x00, // loop (0x1005): movl $1, %ecx
        0xf0, 0x0f, 0xc1, 0x0d, 0x00, 0x00, 0x02, 0x00, // lock xaddl %ecx, 0x20000
        0x4e, // decl %esi
        0x75, 0xf0, // jnz loop
        0xcd, 0x80,
    };
    comptime std.debug.assert(n == 0x30d40);
    @memcpy(s.code[0..prog.len], &prog);
    const Worker = struct {
        fn run(sh: *Shared, out: *Exit) void {
            var c: cpu_mod.Cpu = .{};
            c.eip = code_va;
            out.* = exec.run(&c, sh, .{});
        }
    };
    var exits: [4]Exit = undefined;
    var threads: [4]std.Thread = undefined;
    for (&threads, &exits) |*t, *e| t.* = try std.Thread.spawn(.{}, Worker.run, .{ s, e });
    for (threads) |t| t.join();
    for (exits) |e| try expectSyscall(e);
    try testing.expectEqual(@as(u32, 4 * n), std.mem.readInt(u32, s.data[0..4], .little));
}
