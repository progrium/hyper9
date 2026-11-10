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
        m.icache = .{};
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
        m.icache = .{};
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
                    _ = @atomicRmw(u32, &m.rt.ctx.exit_request, .And, 0, .seq_cst);
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
        t0m.rt.ctx.retired == t1.rt.ctx.retired and t0m.cpu.retired == t1.cpu.retired;
    if (!same) {
        std.debug.print("T1 and T0 differ: exits {any} / {any}, eip {x} / {x}, eflags {x} / {x}, retired {d} / {d} (Cpu {d} / {d})\n", .{ e1, e0, t1.cpu.eip, t0m.cpu.eip, t1.cpu.fl.get(), t0m.cpu.fl.get(), t1.rt.ctx.retired, t0m.rt.ctx.retired, t1.cpu.retired, t0m.cpu.retired });
        for (0..8) |i| if (t1.cpu.r[i] != t0m.cpu.r[i]) std.debug.print("  r{d}: {x} / {x}\n", .{ i, t1.cpu.r[i], t0m.cpu.r[i] });
        std.debug.print("program {x}\n", .{prog});
        return error.Diverged;
    }
}

pub fn testCache(size: usize) !*cache_mod.Cache {
    if (!eval_emit.supported or !codemem.available()) return error.SkipZigTest;
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
    const c = try testCache(codemem.granule);
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
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    try randomPrograms(@import("../emit/x64.zig").emitter_def, 1000);
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
