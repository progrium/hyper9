//! h86 on T1 as vmm/h86.zig runs it: dispatch.zig's loop over a View and
//! a code cache, with `call.interp` reaching T0's memory through a
//! lift.Mem, the PC a u32 (pc_bytes 4) at any byte (pc_align 1), and T0
//! for each instruction dispatch hands back. Tested against T0 alone.

const std = @import("std");
const builtin = @import("builtin");
const ctx_mod = @import("../ctx.zig");
const mem = @import("../../interp/mem.zig");
const cache_mod = @import("../cache.zig");
const dispatch = @import("../dispatch.zig");
const emitter_mod = @import("../emitter.zig");
const codemem = @import("../codemem.zig");
const eval_emit = @import("../emit/eval.zig");
const lift = @import("lift.zig");
const cpu_mod = @import("../../interp/x86/cpu.zig");
const exec = @import("../../interp/x86/exec.zig");
const gen = @import("../check/gen_x86.zig");

const Cpu = cpu_mod.Cpu;
const Ctx = ctx_mod.Ctx;
const testing = std.testing;

/// T0's memory over the View in ctx.space, as h86.zig's TlbMem.
pub const ProbeMem = struct {
    ctx: *Ctx,

    pub fn translate(m: *ProbeMem, va: u32, access: cpu_mod.Access) ?[*]u8 {
        return mem.probe(m.ctx, va, switch (access) {
            .read => .read,
            .write => .write,
            .exec => .exec,
        });
    }

    pub fn translateFn(p: *anyopaque, va: u32, access: cpu_mod.Access) ?[*]u8 {
        const m: *ProbeMem = @ptrCast(@alignCast(p));
        return m.translate(va, access);
    }
};

pub fn config(em: emitter_mod.Emitter) dispatch.Config {
    return .{
        .frontend = lift.frontend,
        .emitter = em,
        .pc_off = @offsetOf(Cpu, "eip"),
        .pc_bytes = 4,
        .pc_align = 1,
    };
}

/// A one-vCPU 386 machine over a View, at gen_x86's addresses: code (two
/// pages, writable, so programs can store to their own text), data, and
/// stack. tests/x86.zig runs its cases on it too.
pub const Machine = struct {
    pages: [4 * mem.page_size]u8 align(mem.page_size) = @splat(0),
    maps: [2]mem.Mapping = undefined,
    code: mem.CodePages = undefined,
    tlb: mem.Tlb = .{},
    view: mem.View = undefined,
    rt: cache_mod.Runtime = .{},
    jit: ?*cache_mod.Cache = null,
    cpu: Cpu = .{},
    icache: exec.ICache = .{},
    pm: ProbeMem = undefined,
    lm: lift.Mem = undefined,
    stats: dispatch.Stats = .{},
    em: emitter_mod.Emitter = eval_emit.emitter_def,

    const code_pages = 2;

    pub fn init(m: *Machine, jit: ?*cache_mod.Cache) !void {
        comptime std.debug.assert(gen.data_va + mem.page_size == gen.stack_va);
        const base = @intFromPtr(&m.pages);
        m.maps = .{
            .{ .va = gen.code_va, .len = code_pages * mem.page_size, .host = base, .perms = .{ .exec = true, .write = true } },
            .{ .va = gen.data_va, .len = 2 * mem.page_size, .host = base + code_pages * mem.page_size, .perms = .{ .write = true } },
        };
        m.code = try .init(testing.allocator, base, m.pages.len, .{ .owner = m, .drop = dropHook, .invalidate = invHook });
        m.view = .{ .maps = &m.maps, .code = &m.code, .tlb = &m.tlb };
        m.jit = jit;
        m.rt = .{ .cache = jit };
        m.rt.bind();
        if (jit) |c| try c.addJumpCache(&m.rt.jump);
        const cx = &m.rt.ctx;
        cx.cpu = @intFromPtr(&m.cpu);
        cx.tlb = @intFromPtr(&m.tlb);
        cx.space = @intFromPtr(&m.view);
        cx.slow_load = @intFromPtr(&mem.slowLoad);
        cx.slow_store = @intFromPtr(&mem.slowStore);
        cx.slow_cas = @intFromPtr(&mem.slowCas);
        cx.interp = @intFromPtr(&lift.interp);
        cx.helpers = @import("helpers.zig").tableAddr();
        m.pm = .{ .ctx = cx };
        m.lm = .{ .ctx = &m.pm, .translateFn = ProbeMem.translateFn };
        cx.frontend = @intFromPtr(&m.lm);
    }

    pub fn deinit(m: *Machine) void {
        if (m.jit) |c| c.removeJumpCache(&m.rt.jump);
        m.code.deinit(testing.allocator);
    }

    fn dropHook(p: *anyopaque, host: usize, table: mem.Table) void {
        const m: *Machine = @ptrCast(@alignCast(p));
        mem.dropEntries(&m.tlb, host, table);
    }
    fn invHook(p: *anyopaque, page: u64) void {
        const m: *Machine = @ptrCast(@alignCast(p));
        if (m.jit) |c| c.invalidatePage(page);
        m.icache.clear();
    }

    pub fn load(m: *Machine, prog: []const u8, regs: [8]u32, eflags: u32, seed: u64) void {
        const text = m.pages[0 .. code_pages * mem.page_size];
        if (!std.mem.eql(u8, text[0..prog.len], prog) or text[prog.len] != 0xCC) {
            m.code.invalidateRange(@intFromPtr(&m.pages), text.len);
            @memset(text, 0xCC); // int3 past the end
            @memcpy(text[0..prog.len], prog);
        }
        var prng = std.Random.DefaultPrng.init(seed);
        prng.random().bytes(m.pages[code_pages * mem.page_size ..]);
        m.cpu = .{};
        m.cpu.r = regs;
        m.cpu.eip = gen.code_va;
        m.cpu.fl.set(eflags);
        m.icache.clear();
        m.cpu.icache = &m.icache;
        m.tlb.flush();
        m.rt.jump.clear();
        m.rt.ctx.retired = 0;
    }

    pub fn runT0(m: *Machine, budget: u64) cpu_mod.Exit {
        const before = m.cpu.retired;
        const e = exec.run(&m.cpu, &m.pm, .{ .budget = budget });
        m.rt.ctx.retired += m.cpu.retired - before;
        return e;
    }

    /// Runs to the first exit but a stop, as h86.zig's runT1 does.
    pub fn run(m: *Machine) !cpu_mod.Exit {
        if (m.jit == null) return m.runT0(100_000);
        const cfg = config(m.em);
        var rounds: u32 = 0;
        while (rounds < 100_000) : (rounds += 1) {
            const c_before = m.cpu.retired;
            const before = m.rt.ctx.retired;
            const r = dispatch.run(testing.allocator, &m.rt.ctx, cfg, &m.stats);
            m.cpu.retired = c_before +% (m.rt.ctx.retired -% before);
            switch (r) {
                .svc => return .{ .syscall = 0x80 },
                .interrupted => {
                    // A full cache: flush, as the vmm layer would.
                    _ = cache_mod.clearRequest(&m.rt.ctx, ~@as(u32, 0));
                    m.jit.?.reset();
                },
                .t0 => {
                    const e = m.runT0(1);
                    if (e != .stopped) return e;
                },
            }
        }
        return error.TooLong;
    }
};

fn sameExit(a: cpu_mod.Exit, b: cpu_mod.Exit) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .fault => |f| f.addr == b.fault.addr and f.access == b.fault.access,
        .exception => |v| v == b.exception,
        else => true,
    };
}

fn expectSame(t1: *Machine, t0m: *Machine, prog: []const u8, regs: [8]u32, eflags: u32, seed: u64) !void {
    t0m.load(prog, regs, eflags, seed);
    t1.load(prog, regs, eflags, seed);
    const e0 = try t0m.run();
    const e1 = try t1.run();
    const same = sameExit(e0, e1) and std.mem.eql(u32, &t0m.cpu.r, &t1.cpu.r) and t0m.cpu.eip == t1.cpu.eip and
        t0m.cpu.fl.get() == t1.cpu.fl.get() and std.mem.eql(u8, &t0m.pages, &t1.pages) and
        std.mem.eql(u128, &t0m.cpu.xmm, &t1.cpu.xmm) and t0m.cpu.mxcsr == t1.cpu.mxcsr and std.meta.eql(t0m.cpu.fpu, t1.cpu.fpu) and
        t0m.rt.ctx.retired == t1.rt.ctx.retired and t0m.cpu.retired == t1.cpu.retired;
    if (!same) {
        std.debug.print("T1 and T0 differ: exits {any} / {any}, eip {x} / {x}, eflags {x} / {x}, retired {d} / {d} (Cpu {d} / {d})\n", .{ e1, e0, t1.cpu.eip, t0m.cpu.eip, t1.cpu.fl.get(), t0m.cpu.fl.get(), t1.rt.ctx.retired, t0m.rt.ctx.retired, t1.cpu.retired, t0m.cpu.retired });
        for (0..8) |i| if (t1.cpu.r[i] != t0m.cpu.r[i]) std.debug.print("  r{d}: {x} / {x}\n", .{ i, t1.cpu.r[i], t0m.cpu.r[i] });
        std.debug.print("program {x}\n", .{prog});
        return error.Diverged;
    }
}

/// This host's emitter, if it has one.
const host_emitter: ?emitter_mod.Emitter = switch (builtin.cpu.arch) {
    .x86_64 => @import("../emit/x64.zig").emitter_def,
    .aarch64 => @import("../emit/arm64.zig").emitter_def,
    else => null,
};

pub fn testCache(size: usize) !*cache_mod.Cache {
    if (!eval_emit.supported or !codemem.available()) return error.SkipZigTest;
    return newCache(size);
}

/// A cache for generated code alone (no eval_emit stubs).
fn hostCache(size: usize) !*cache_mod.Cache {
    if (host_emitter == null or !codemem.available()) return error.SkipZigTest;
    return newCache(size);
}

fn newCache(size: usize) !*cache_mod.Cache {
    const c = try testing.allocator.create(cache_mod.Cache);
    errdefer testing.allocator.destroy(c);
    c.* = try cache_mod.Cache.init(testing.allocator, size);
    return c;
}

pub fn freeCache(c: *cache_mod.Cache) void {
    c.deinit();
    testing.allocator.destroy(c);
    eval_emit.reset();
}

const Pair = struct {
    t1: *Machine,
    t0: *Machine,

    fn init(c: *cache_mod.Cache, em: emitter_mod.Emitter) !Pair {
        const p: Pair = .{ .t1 = try testing.allocator.create(Machine), .t0 = try testing.allocator.create(Machine) };
        p.t1.* = .{};
        p.t0.* = .{};
        try p.t1.init(c);
        p.t1.em = em;
        try p.t0.init(null);
        return p;
    }

    fn deinit(p: Pair) void {
        p.t1.deinit();
        p.t0.deinit();
        testing.allocator.destroy(p.t1);
        testing.allocator.destroy(p.t0);
    }
};

fn randomPrograms(em: emitter_mod.Emitter, n: usize) !void {
    // A small cache, so it fills and flushes now and then.
    const c = try (if (std.mem.eql(u8, em.name, eval_emit.emitter_def.name)) testCache(codemem.granule) else hostCache(codemem.granule));
    defer freeCache(c);
    const p = try Pair.init(c, em);
    defer p.deinit();
    var prng = std.Random.DefaultPrng.init(0x86d1);
    var buf: [mem.page_size - 16]u8 = undefined;
    for (0..n) |i| {
        const r = prng.random();
        const prog = gen.program(r, .{ .len = 48 }, &buf);
        const regs = gen.registers(r);
        expectSame(p.t1, p.t0, prog, regs.r, regs.eflags, i) catch |e| {
            std.debug.print("program {d}\n", .{i});
            return e;
        };
    }
    try testing.expect(p.t1.stats.compiled > 0);
    try testing.expect(c.flushes > 0);
}

test "h86 T1: random programs agree with T0 through dispatch, with flushes" {
    try randomPrograms(eval_emit.emitter_def, 1000);
}

test "h86 T1: the same through this host's emitter" {
    try randomPrograms(host_emitter orelse return error.SkipZigTest, 1000);
}

test "h86 T1: a counted loop chains, and a store to its own code retranslates" {
    const c = try testCache(1 << 20);
    defer freeCache(c);
    const p = try Pair.init(c, eval_emit.emitter_def);
    defer p.deinit();
    // Loop 3 times; on each pass rewrite the `addl $1, %eax` immediate
    // at 0x1009 to 2, so the passes add 1, 2, 2.
    const prog = [_]u8{
        0x31, 0xc0, // xorl %eax, %eax
        0xb9, 0x03, 0x00, 0x00, 0x00, // movl $3, %ecx
        0x83, 0xc0, 0x01, // loop (0x1007): addl $1, %eax
        0xc6, 0x05, 0x09, 0x10, 0x00, 0x00, 0x02, // movb $2, 0x1009
        0x49, // decl %ecx
        0x75, 0xf3, // jnz loop
        0xcd, 0x80, // int $0x80
    };
    try expectSame(p.t1, p.t0, &prog, @splat(0), 0x2, 0);
    try testing.expectEqual(@as(u32, 5), p.t1.cpu.r[0]);
    try testing.expect(p.t1.stats.compiled > 1);
}

test "h86 T1: a PIC thunk on the next page is one of the region's pages" {
    const c = try testCache(1 << 20);
    defer freeCache(c);
    const p = try Pair.init(c, eval_emit.emitter_def);
    defer p.deinit();
    // Loop 3 times calling the thunk at 0x2000 (movl (%esp), %ebx; ret);
    // the first pass rewrites it to load EDX, so the later passes leave
    // EBX at 0 and only the first adds the return address to EAX.
    var prog: [0x1004]u8 = @splat(0x90);
    const head = [_]u8{
        0x31, 0xc0, // xorl %eax, %eax
        0xb9, 0x03, 0x00, 0x00, 0x00, // movl $3, %ecx
        0x31, 0xdb, // loop (0x1007): xorl %ebx, %ebx
        0xe8, 0xf2, 0x0f, 0x00, 0x00, // call 0x2000
        0x01, 0xd8, // addl %ebx, %eax
        0xc6, 0x05, 0x01, 0x20, 0x00, 0x00, 0x14, // movb $0x14, 0x2001
        0x49, // decl %ecx
        0x75, 0xed, // jnz loop
        0xcd, 0x80, // int $0x80
    };
    @memcpy(prog[0..head.len], &head);
    @memcpy(prog[0x1000..], &[_]u8{ 0x8b, 0x1c, 0x24, 0xc3 });
    var regs: [8]u32 = @splat(0);
    regs[4] = gen.stack_va + 0x800;
    try expectSame(p.t1, p.t0, &prog, regs, 0x2, 0);
    try testing.expectEqual(@as(u32, 0x100e), p.t1.cpu.r[0]);
    try testing.expectEqual(@as(u32, 0x100e), p.t1.cpu.r[2]);
    try testing.expect(p.t1.stats.compiled > 1);
}

test "h86 T1: INT3 and INTO's #OF come back with EIP past them, as on T0" {
    const c = try testCache(1 << 20);
    defer freeCache(c);
    const p = try Pair.init(c, eval_emit.emitter_def);
    defer p.deinit();
    // movl %eax, 0 after each: running on past the trap would fault.
    const brk = [_]u8{ 0x40, 0xcc, 0xa3, 0, 0, 0, 0 }; // incl %eax; int3; movl %eax, 0
    try expectSame(p.t1, p.t0, &brk, @splat(0), 0x2, 0);
    try testing.expectEqual(@as(u32, gen.code_va + 2), p.t1.cpu.eip);
    const into = [_]u8{ 0xb8, 0xff, 0xff, 0xff, 0x7f, 0x40, 0xce, 0xa3, 0, 0, 0, 0 }; // movl $0x7fffffff, %eax; incl %eax; into; movl %eax, 0
    try expectSame(p.t1, p.t0, &into, @splat(0), 0x2, 0);
    try testing.expectEqual(@as(u32, gen.code_va + 7), p.t1.cpu.eip);
}

fn fpPrograms(em: emitter_mod.Emitter) !void {
    const c = try (if (std.mem.eql(u8, em.name, eval_emit.emitter_def.name)) testCache(1 << 20) else hostCache(1 << 20));
    defer freeCache(c);
    const p = try Pair.init(c, em);
    defer p.deinit();
    // SSE2 scalar double and x87 over random data at EBX.
    const prog = [_]u8{
        0xf2, 0x0f, 0x10, 0x03, // movsd (%ebx), %xmm0
        0xf2, 0x0f, 0x10, 0x4b, 0x08, // movsd 8(%ebx), %xmm1
        0xf2, 0x0f, 0x58, 0xc1, // addsd %xmm1, %xmm0
        0xf2, 0x0f, 0x59, 0x43, 0x10, // mulsd 16(%ebx), %xmm0
        0xf2, 0x0f, 0x51, 0xd0, // sqrtsd %xmm0, %xmm2
        0xf2, 0x0f, 0x2c, 0xc2, // cvttsd2si %xmm2, %eax
        0xf2, 0x0f, 0x2a, 0xd9, // cvtsi2sd %ecx, %xmm3
        0x66, 0x0f, 0x2e, 0xc3, // ucomisd %xmm3, %xmm0
        0x0f, 0x92, 0xc2, // setb %dl
        0x66, 0x0f, 0x57, 0xe4, // xorpd %xmm4, %xmm4
        0x66, 0x0f, 0x28, 0x6b, 0x20, // movapd 32(%ebx), %xmm5
        0x66, 0x0f, 0x54, 0xcd, // andpd %xmm5, %xmm1
        0xf2, 0x0f, 0x11, 0x4b, 0x30, // movsd %xmm1, 48(%ebx)
        0xf2, 0x0f, 0x5a, 0xf0, // cvtsd2ss %xmm0, %xmm6
        0xf3, 0x0f, 0x11, 0x73, 0x38, // movss %xmm6, 56(%ebx)
        0xdd, 0x03, // fldl (%ebx)
        0xdc, 0x43, 0x08, // faddl 8(%ebx)
        0xdd, 0x5b, 0x40, // fstpl 64(%ebx)
        0xd9, 0xe8, 0xd9, 0xee, // fld1; fldz
        0xdf, 0xf1, // fcomip %st(1), %st
        0xdd, 0xd8, // fstp %st(0)
        0xcd, 0x80,
    };
    var prng = std.Random.DefaultPrng.init(0xf9);
    for (0..300) |i| {
        const regs = gen.registers(prng.random());
        expectSame(p.t1, p.t0, &prog, regs.r, regs.eflags, i) catch |e| {
            std.debug.print("seed {d}\n", .{i});
            return e;
        };
    }
}

test "h86 T1: SSE2 and x87 through dispatch agree with T0" {
    try fpPrograms(eval_emit.emitter_def);
}

test "h86 T1: SSE2 and x87 as this host's code" {
    try fpPrograms(host_emitter orelse return error.SkipZigTest);
}

// ---------------------------------------------------------------- hx64

/// T0's memory over the View in ctx.space, for hx64 (64-bit addresses).
pub const ProbeMem64 = struct {
    ctx: *Ctx,

    pub fn translate(m: *ProbeMem64, va: u64, access: cpu_mod.Access) ?[*]u8 {
        return mem.probe(m.ctx, va, switch (access) {
            .read => .read,
            .write => .write,
            .exec => .exec,
        });
    }

    pub fn translateFn(p: *anyopaque, va: u64, access: cpu_mod.Access) ?[*]u8 {
        const m: *ProbeMem64 = @ptrCast(@alignCast(p));
        return m.translate(va, access);
    }
};

pub fn config64(em: emitter_mod.Emitter) dispatch.Config {
    return .{
        .frontend = lift.frontendFor(.long),
        .emitter = em,
        .pc_off = @offsetOf(Cpu64, "rip"),
        .pc_bytes = 8,
        .pc_align = 1,
    };
}

const Cpu64 = cpu_mod.Cpu64;

/// A one-vCPU amd64 machine over a View: code (two pages, writable),
/// data, and a stack page, above 4 GiB so that 32-bit truncation shows.
pub const Machine64 = struct {
    pub const code_va: u64 = 0x1_0040_0000;
    pub const data_va: u64 = 0x1_0060_0000;
    pub const stack_va: u64 = data_va + mem.page_size;

    pages: [4 * mem.page_size]u8 align(mem.page_size) = @splat(0),
    maps: [2]mem.Mapping = undefined,
    code: mem.CodePages = undefined,
    tlb: mem.Tlb = .{},
    view: mem.View = undefined,
    rt: cache_mod.Runtime = .{},
    jit: ?*cache_mod.Cache = null,
    cpu: Cpu64 = .{},
    pm: ProbeMem64 = undefined,
    lm: lift.Mem64 = undefined,
    stats: dispatch.Stats = .{},
    em: emitter_mod.Emitter = eval_emit.emitter_def,

    const code_pages = 2;

    pub fn init(m: *Machine64, jit: ?*cache_mod.Cache) !void {
        const base = @intFromPtr(&m.pages);
        m.maps = .{
            .{ .va = code_va, .len = code_pages * mem.page_size, .host = base, .perms = .{ .exec = true, .write = true } },
            .{ .va = data_va, .len = 2 * mem.page_size, .host = base + code_pages * mem.page_size, .perms = .{ .write = true } },
        };
        m.code = try .init(testing.allocator, base, m.pages.len, .{ .owner = m, .drop = dropHook, .invalidate = invHook });
        m.view = .{ .maps = &m.maps, .code = &m.code, .tlb = &m.tlb };
        m.jit = jit;
        m.rt = .{ .cache = jit };
        m.rt.bind();
        if (jit) |c| try c.addJumpCache(&m.rt.jump);
        const cx = &m.rt.ctx;
        cx.cpu = @intFromPtr(&m.cpu);
        cx.tlb = @intFromPtr(&m.tlb);
        cx.space = @intFromPtr(&m.view);
        cx.slow_load = @intFromPtr(&mem.slowLoad);
        cx.slow_store = @intFromPtr(&mem.slowStore);
        cx.slow_cas = @intFromPtr(&mem.slowCas);
        cx.interp = @intFromPtr(&lift.interpLong);
        m.pm = .{ .ctx = cx };
        m.lm = .{ .ctx = &m.pm, .translateFn = ProbeMem64.translateFn };
        cx.frontend = @intFromPtr(&m.lm);
    }

    pub fn deinit(m: *Machine64) void {
        if (m.jit) |c| c.removeJumpCache(&m.rt.jump);
        m.code.deinit(testing.allocator);
    }

    fn dropHook(p: *anyopaque, host: usize, table: mem.Table) void {
        const m: *Machine64 = @ptrCast(@alignCast(p));
        mem.dropEntries(&m.tlb, host, table);
    }
    fn invHook(p: *anyopaque, page: u64) void {
        const m: *Machine64 = @ptrCast(@alignCast(p));
        if (m.jit) |c| c.invalidatePage(page);
    }

    pub fn load(m: *Machine64, prog: []const u8, regs: [16]u64, rflags: u32, seed: u64) void {
        const text = m.pages[0 .. code_pages * mem.page_size];
        if (!std.mem.eql(u8, text[0..prog.len], prog) or text[prog.len] != 0xCC) {
            m.code.invalidateRange(@intFromPtr(&m.pages), text.len);
            @memset(text, 0xCC); // int3 past the end
            @memcpy(text[0..prog.len], prog);
        }
        var prng = std.Random.DefaultPrng.init(seed);
        prng.random().bytes(m.pages[code_pages * mem.page_size ..]);
        m.cpu = .{};
        m.cpu.r = regs;
        m.cpu.rip = code_va;
        m.cpu.fl.set(rflags);
        m.tlb.flush();
        m.rt.jump.clear();
        m.rt.ctx.retired = 0;
    }

    pub fn runT0(m: *Machine64, budget: u64) cpu_mod.Exit64 {
        const before = m.cpu.retired;
        const e = exec.runIn(.long, &m.cpu, &m.pm, .{ .budget = budget });
        m.rt.ctx.retired += m.cpu.retired - before;
        return e;
    }

    /// Runs to the first exit but a stop.
    pub fn run(m: *Machine64) !cpu_mod.Exit64 {
        if (m.jit == null) return m.runT0(100_000);
        const cfg = config64(m.em);
        var rounds: u32 = 0;
        while (rounds < 100_000) : (rounds += 1) {
            const c_before = m.cpu.retired;
            const before = m.rt.ctx.retired;
            const r = dispatch.run(testing.allocator, &m.rt.ctx, cfg, &m.stats);
            m.cpu.retired = c_before +% (m.rt.ctx.retired -% before);
            switch (r) {
                .svc => return .syscall,
                .interrupted => {
                    _ = cache_mod.clearRequest(&m.rt.ctx, ~@as(u32, 0));
                    m.jit.?.reset();
                },
                .t0 => {
                    const e = m.runT0(1);
                    if (e != .stopped) return e;
                },
            }
        }
        return error.TooLong;
    }
};

fn sameExit64(a: cpu_mod.Exit64, b: cpu_mod.Exit64) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .fault => |f| f.addr == b.fault.addr and f.access == b.fault.access,
        .exception => |v| v == b.exception,
        else => true,
    };
}

pub fn expectSame64(t1: *Machine64, t0m: *Machine64, prog: []const u8, regs: [16]u64, rflags: u32, seed: u64) !void {
    t0m.load(prog, regs, rflags, seed);
    t1.load(prog, regs, rflags, seed);
    const e0 = try t0m.run();
    const e1 = try t1.run();
    const same = sameExit64(e0, e1) and std.mem.eql(u64, &t0m.cpu.r, &t1.cpu.r) and t0m.cpu.rip == t1.cpu.rip and
        t0m.cpu.fl.get() == t1.cpu.fl.get() and std.mem.eql(u8, &t0m.pages, &t1.pages) and
        std.mem.eql(u128, &t0m.cpu.xmm, &t1.cpu.xmm) and t0m.cpu.mxcsr == t1.cpu.mxcsr and std.meta.eql(t0m.cpu.fpu, t1.cpu.fpu) and
        t0m.cpu.fs_base == t1.cpu.fs_base and t0m.cpu.gs_base == t1.cpu.gs_base and
        t0m.rt.ctx.retired == t1.rt.ctx.retired and t0m.cpu.retired == t1.cpu.retired;
    if (!same) {
        std.debug.print("hx64 T1 and T0 differ: exits {any} / {any}, rip {x} / {x}, rflags {x} / {x}, retired {d} / {d} (Cpu {d} / {d})\n", .{ e1, e0, t1.cpu.rip, t0m.cpu.rip, t1.cpu.fl.get(), t0m.cpu.fl.get(), t1.rt.ctx.retired, t0m.rt.ctx.retired, t1.cpu.retired, t0m.cpu.retired });
        for (0..16) |i| if (t1.cpu.r[i] != t0m.cpu.r[i]) std.debug.print("  r{d}: {x} / {x}\n", .{ i, t1.cpu.r[i], t0m.cpu.r[i] });
        if (!std.mem.eql(u8, &t0m.pages, &t1.pages)) std.debug.print("  memory differs\n", .{});
        std.debug.print("program {x}\n", .{prog});
        return error.Diverged;
    }
}

const Pair64 = struct {
    t1: *Machine64,
    t0: *Machine64,

    fn init(c: *cache_mod.Cache, em: emitter_mod.Emitter) !Pair64 {
        const p: Pair64 = .{ .t1 = try testing.allocator.create(Machine64), .t0 = try testing.allocator.create(Machine64) };
        p.t1.* = .{};
        p.t0.* = .{};
        try p.t1.init(c);
        p.t1.em = em;
        try p.t0.init(null);
        return p;
    }

    fn deinit(p: Pair64) void {
        p.t1.deinit();
        p.t0.deinit();
        testing.allocator.destroy(p.t1);
        testing.allocator.destroy(p.t0);
    }
};

/// Random long-mode integer programs: register and [RBX+disp8] forms
/// over all 16 registers (RBX and RSP aren't written), forward branches,
/// and a SYSCALL at the end. A stand-in for check/gen_x86's long mode.
pub const Gen64 = struct {
    r: std.Random,
    out: std.ArrayList(u8) = .empty,

    fn byte(g: *Gen64, v: u8) !void {
        try g.out.append(testing.allocator, v);
    }

    /// A destination register: not RBX (the data pointer) or RSP.
    fn dst(g: *Gen64) u4 {
        while (true) {
            const v = g.r.int(u4);
            if (v != 3 and v != 4) return v;
        }
    }

    /// REX, then the opcode bytes, then a ModRM naming reg and either a
    /// register rm or [RBX+disp8] (memory), then imm bytes.
    fn modrm(g: *Gen64, w: bool, opc: []const u8, reg: u4, rm: u4, memop: bool, force_rex: bool, imm0: usize) !void {
        var imm = imm0;
        // Now and then 16-bit operands (66), but for byte operations.
        const byte_op = opc[0] < 0x40 and opc[0] & 1 == 0 or (opc.len == 2 and opc[0] == 0x0f and opc[1] >= 0x90 and opc[1] < 0xa0);
        if (!w and !byte_op and g.r.uintLessThan(u8, 5) == 0) {
            try g.byte(0x66);
            if (imm == 4) imm = 2;
        }
        const rex: u8 = 0x40 | (@as(u8, @intFromBool(w)) << 3) | (@as(u8, reg >> 3) << 2) | (if (memop) 0 else @as(u8, rm >> 3));
        if (rex != 0x40 or force_rex) try g.byte(rex);
        for (opc) |o| try g.byte(o);
        if (memop) {
            try g.byte(0x43 | (@as(u8, reg & 7) << 3)); // [rbx+disp8]
            try g.byte(g.r.int(u8) & 0xf8);
        } else try g.byte(0xc0 | (@as(u8, reg & 7) << 3) | (rm & 7));
        for (0..imm) |_| try g.byte(g.r.int(u8));
    }

    pub fn insn(g: *Gen64) !void {
        const w = g.r.boolean();
        const memop = g.r.uintLessThan(u8, 4) == 0;
        const d = g.dst();
        const s = g.r.int(u4);
        switch (g.r.uintLessThan(u8, 24)) {
            // ALU r/m, r (stores to memory are fine: RBX points at data).
            0 => try g.modrm(w, &.{0x01 + 8 * g.r.uintLessThan(u8, 8)}, s, d, memop, false, 0),
            1 => try g.modrm(w, &.{0x03 + 8 * g.r.uintLessThan(u8, 8)}, d, s, memop, false, 0),
            // ALU r/m, imm8 and imm32.
            2 => try g.modrm(w, &.{0x83}, @intCast(g.r.uintLessThan(u8, 8)), d, memop, false, 1),
            3 => try g.modrm(w, &.{0x81}, @intCast(g.r.uintLessThan(u8, 8)), d, memop, false, 4),
            // 8-bit ALU, with and without REX (SPL..DIL against AH..BH).
            4 => {
                const rx = g.r.boolean();
                const reg: u4 = if (rx) g.dst() else g.r.uintLessThan(u4, 8);
                const rm: u4 = if (rx) g.dst() else g.r.uintLessThan(u4, 8);
                // Without REX, rm 4-7 are AH-BH: write AH..BH, not SPL.
                if (!rx and (rm & 3) == 3) return; // BL/BH: part of RBX
                try g.modrm(false, &.{0x00 + 8 * g.r.uintLessThan(u8, 8)}, reg, rm, false, rx, 0);
            },
            // Shifts by an immediate, 1, and CL.
            5 => try g.modrm(w, &.{0xc1}, @intCast(g.r.uintLessThan(u8, 8)), d, memop, false, 1),
            6 => try g.modrm(w, &.{0xd3}, @intCast(g.r.uintLessThan(u8, 8)), d, false, false, 0),
            7 => try g.modrm(w, &.{0xd1}, @intCast(g.r.uintLessThan(u8, 8)), d, memop, false, 0),
            // INC, DEC; NOT, NEG; MUL, IMUL (one operand).
            8 => try g.modrm(w, &.{0xff}, g.r.uintLessThan(u4, 2), d, memop, false, 0),
            9 => try g.modrm(w, &.{0xf7}, 2 + g.r.uintLessThan(u4, 4), s, false, false, 0),
            // IMUL r, r/m; with imm8.
            10 => try g.modrm(w, &.{ 0x0f, 0xaf }, d, s, memop, false, 0),
            11 => try g.modrm(w, &.{0x6b}, d, s, memop, false, 1),
            // MOV both ways, and imm32 to r/m.
            12 => try g.modrm(w, &.{0x89}, s, d, memop, false, 0),
            13 => try g.modrm(w, &.{0x8b}, d, s, memop, false, 0),
            14 => try g.modrm(w, &.{0xc7}, 0, d, memop, false, 4),
            // MOV r, imm32 / imm64.
            15 => {
                try g.byte(0x40 | (@as(u8, @intFromBool(w)) << 3) | (d >> 3));
                try g.byte(0xb8 + @as(u8, d & 7));
                for (0..@as(usize, if (w) 8 else 4)) |_| try g.byte(g.r.int(u8));
            },
            // MOVZX, MOVSX, MOVSXD.
            16 => try g.modrm(w, &.{ 0x0f, 0xb6 + 8 * g.r.uintLessThan(u8, 2) + g.r.uintLessThan(u8, 2) }, d, s, memop, false, 0),
            17 => try g.modrm(true, &.{0x63}, d, s, memop, false, 0),
            // LEA with a SIB: [base + index*scale + disp8].
            18 => {
                const base = g.r.int(u4);
                var index = g.r.int(u4);
                if (index == 4) index = 0;
                try g.byte(0x48 | (@as(u8, d >> 3) << 2) | (@as(u8, index >> 3) << 1) | (base >> 3));
                try g.byte(0x8d);
                try g.byte(0x44 | (@as(u8, d & 7) << 3));
                try g.byte(@as(u8, g.r.int(u2)) << 6 | (@as(u8, index & 7) << 3) | (base & 7));
                try g.byte(g.r.int(u8));
            },
            // TEST, XCHG, CMOVcc, SETcc.
            19 => try g.modrm(w, &.{0x85}, s, d, memop, false, 0),
            20 => try g.modrm(w, &.{0x87}, d, g.dst(), false, false, 0),
            21 => try g.modrm(w, &.{ 0x0f, 0x40 + g.r.uintLessThan(u8, 16) }, d, s, memop, false, 0),
            22 => try g.modrm(false, &.{ 0x0f, 0x90 + g.r.uintLessThan(u8, 16) }, 0, d, memop, true, 0),
            // CDQE/CQO, BSWAP, a short Jcc forward over the next bytes.
            else => switch (g.r.uintLessThan(u8, 3)) {
                0 => {
                    if (w) try g.byte(0x48);
                    try g.byte(0x98 + g.r.uintLessThan(u8, 2));
                },
                1 => {
                    try g.byte(0x40 | (@as(u8, @intFromBool(w)) << 3) | (d >> 3));
                    try g.byte(0x0f);
                    try g.byte(0xc8 + @as(u8, d & 7));
                },
                else => {
                    try g.byte(0x70 + g.r.uintLessThan(u8, 16));
                    try g.byte(g.r.uintLessThan(u8, 8));
                    // What it skips: NOPs.
                    for (0..8) |_| try g.byte(0x90);
                },
            },
        }
    }

    pub fn program(g: *Gen64, n: usize) ![]const u8 {
        g.out.clearRetainingCapacity();
        for (0..n) |_| try g.insn();
        try g.byte(0x0f);
        try g.byte(0x05); // syscall
        return g.out.items;
    }

    pub fn deinit(g: *Gen64) void {
        g.out.deinit(testing.allocator);
    }
};

pub fn randomRegs64(r: std.Random) [16]u64 {
    var regs: [16]u64 = undefined;
    for (&regs) |*x| x.* = switch (r.uintLessThan(u8, 4)) {
        0 => r.int(u64),
        1 => r.int(u32),
        2 => @bitCast(@as(i64, r.int(i8))),
        else => r.int(u8),
    };
    regs[3] = Machine64.data_va + 0x400;
    regs[4] = Machine64.stack_va + 0x800;
    return regs;
}

fn randomPrograms64(em: emitter_mod.Emitter, n: usize) !void {
    const c = try (if (std.mem.eql(u8, em.name, eval_emit.emitter_def.name)) testCache(codemem.granule) else hostCache(codemem.granule));
    defer freeCache(c);
    const p = try Pair64.init(c, em);
    defer p.deinit();
    var prng = std.Random.DefaultPrng.init(0x64d1);
    var g: Gen64 = .{ .r = prng.random() };
    defer g.deinit();
    for (0..n) |i| {
        const prog = try g.program(40);
        const regs = randomRegs64(prng.random());
        expectSame64(p.t1, p.t0, prog, regs, 0x2 | (prng.random().int(u32) & 0x8d5), i) catch |e| {
            std.debug.print("program {d}\n", .{i});
            return e;
        };
    }
    try testing.expect(p.t1.stats.compiled > 0);
}

test "hx64 T1: random integer programs agree with T0 through dispatch" {
    try randomPrograms64(eval_emit.emitter_def, 1000);
}

test "hx64 T1: the same through this host's emitter" {
    try randomPrograms64(host_emitter orelse return error.SkipZigTest, 1000);
}

test "hx64 T1: a counted loop, a call and a return, and RIP-relative data" {
    const c = try testCache(1 << 20);
    defer freeCache(c);
    const p = try Pair64.init(c, eval_emit.emitter_def);
    defer p.deinit();
    const prog = [_]u8{
        0x31, 0xc0, // xor eax, eax
        0xb9, 0x05, 0x00, 0x00, 0x00, // mov ecx, 5
        0x48, 0x03, 0x05, 0x16, 0x00, 0x00, 0x00, // loop (+7): add rax, [rip+0x16] (the qword at +0x24)
        0xe8, 0x08, 0x00, 0x00, 0x00, // call +0x1b
        0xff, 0xc9, // dec ecx
        0x75, 0xf0, // jnz loop
        0x0f, 0x05, // syscall
        0x90, 0x90, // (+0x19)
        0x48, 0xff, 0xc2, // fn (+0x1b): inc rdx
        0xc3, // ret
        0x90, 0x90, 0x90, 0x90, 0x90, // pad to +0x24
        0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, // the qword 0x1_0000_0001
    };
    var regs: [16]u64 = @splat(0);
    regs[4] = Machine64.stack_va + 0x800;
    try expectSame64(p.t1, p.t0, &prog, regs, 0x2, 0);
    try testing.expectEqual(@as(u64, 5 * 0x1_0000_0001), p.t1.cpu.r[0]);
    try testing.expectEqual(@as(u64, 5), p.t1.cpu.r[2]);
    try testing.expect(p.t1.stats.compiled > 1);
}
