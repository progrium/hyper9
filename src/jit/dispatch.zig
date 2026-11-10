//! T1's run loop, shared by both guests: find or compile the translation
//! for the PC, run it, and follow its exits until something needs the
//! Guest (a system call, an exception, a kick).
//!
//! A Guest's `run` calls `run` when its Runtime has a code cache, and
//! handles what comes back:
//!
//! - `.svc`: the Cpu's PC is past the system call.
//! - `.interrupted`: an exit request (a kick, a shootdown, a flush, or a
//!   full cache, which `run` has asked to flush); the PC is where to go on.
//! - `.t0`: run the instruction at the Cpu's PC in T0, then call `run`
//!   again. This is how every exception reaches the Guest (a fault, BRK,
//!   an undefined instruction, a fetch that fails): guest state is exact
//!   at each, so T0 raises it again with all its architectural detail. It's
//!   also how a store to a page holding code finishes (FaultKind.code),
//!   which T0 does after dropping the page's translations.
//!
//! Translations are keyed by PC and arena page (cache.zig). The Source the
//! front end reads through records the pages it read, so a translation
//! that runs into a second page records that page too.

const std = @import("std");
const ir = @import("ir.zig");
const ctx_mod = @import("ctx.zig");
const fe = @import("frontend.zig");
const emitter_mod = @import("emitter.zig");
const alloc_mod = @import("alloc.zig");
const cache_mod = @import("cache.zig");
const mem = @import("../interp/mem.zig");
const opt = @import("opt.zig");

const Ctx = ctx_mod.Ctx;
const Exit = ctx_mod.Exit;
const Runtime = cache_mod.Runtime;
const Tb = cache_mod.Tb;

pub const Config = struct {
    frontend: fe.Frontend,
    emitter: emitter_mod.Emitter,
    limits: fe.Limits = .{},
    /// Byte offset of the guest PC in the front end's Cpu, and its size:
    /// 8 (a u64), or 4 (a u32, as h86's EIP).
    pc_off: usize,
    pc_bytes: u8 = 8,
    /// Instruction alignment: a PC off it goes to T0 (arm64's PC alignment
    /// fault). 1 for x86.
    pc_align: u8 = 4,
    /// Run opt.zig's passes on each region.
    optimize: bool = true,
};

pub const Result = enum { svc, interrupted, t0 };

/// Counts, for tests and stats.
pub const Stats = struct {
    compiled: u64 = 0,
    entries: u64 = 0,
    linked: u64 = 0,
    t0: u64 = 0,
};

/// Runs compiled code from the Cpu's PC. The Runtime's cache must be set.
pub fn run(gpa: std.mem.Allocator, cx: *Ctx, cfg: Config, stats: ?*Stats) Result {
    const rt = Runtime.of(cx);
    const c = rt.cache.?;
    const view = rt.view();
    const pc_addr = @as(usize, @intCast(cx.cpu)) + cfg.pc_off;
    const pcp: Pc = .{ .addr = pc_addr, .wide = cfg.pc_bytes == 8 };
    var st: Stats = .{};
    defer if (stats) |s| {
        s.compiled += st.compiled;
        s.entries += st.entries;
        s.linked += st.linked;
        s.t0 += st.t0;
    };
    // Compiled code can't store to the code it came from: such a store
    // leaves, and T0 does it.
    view.code_stores = .exit;
    defer view.code_stores = .store;
    var from: ?struct { tb: *Tb, site: u64 } = null;
    while (true) {
        const pc = pcp.get();
        if (@atomicLoad(u32, &cx.exit_request, .seq_cst) != 0) return .interrupted;
        const page = codePage(view, pc, cfg.pc_align) orelse {
            st.t0 += 1;
            return .t0;
        };
        const tb = c.lookup(&rt.jump, pc, page, view) orelse compile(gpa, c, view, pc, page, cfg, &st) catch |e| switch (e) {
            error.Full => {
                rt.requestFlush();
                return .interrupted;
            },
            // Nothing to run (it can't be lifted or emitted): T0 runs it.
            else => {
                st.t0 += 1;
                return .t0;
            },
        };
        if (from) |f| {
            if (c.link(f.tb, f.site, tb)) st.linked += 1;
        }
        from = null;
        st.entries += 1;
        const e: Exit = @enumFromInt(tb.entry(cx));
        pcp.set(cx.exit_pc);
        switch (e) {
            .chain => if (c.tbAt(cx.exit_info)) |t| {
                from = .{ .tb = t, .site = cx.exit_info };
            },
            .indirect => {},
            .svc => return .svc,
            .interrupted => return .interrupted,
            .fault, .brk, .undef => {
                st.t0 += 1;
                return .t0;
            },
            else => {
                st.t0 += 1;
                return .t0;
            },
        }
    }
}

/// The guest PC in the Cpu, a u64 or a u32.
const Pc = struct {
    addr: usize,
    wide: bool,

    fn get(p: Pc) u64 {
        if (p.wide) return @as(*const u64, @ptrFromInt(p.addr)).*;
        return @as(*const u32, @ptrFromInt(p.addr)).*;
    }
    fn set(p: Pc, v: u64) void {
        if (p.wide) @as(*u64, @ptrFromInt(p.addr)).* = v else @as(*u32, @ptrFromInt(p.addr)).* = @truncate(v);
    }
};

/// The arena page holding the instruction at `pc`, if it's executable
/// and aligned to `pc_align`.
fn codePage(view: *mem.View, pc: u64, pc_align: u8) ?u64 {
    if (pc & (pc_align - 1) != 0) return null;
    const code = view.code orelse return null;
    const host = view.translate(pc, 1, .exec) orelse return null;
    return code.pageOf(@intFromPtr(host.ptr));
}

/// A Source over the view that notes the guest pages it read from.
const Reader = struct {
    view: *mem.View,
    first: u64,
    second: u64 = cache_mod.no_page,

    fn read(p: *anyopaque, va: u64, buf: []u8) usize {
        const r: *Reader = @ptrCast(@alignCast(p));
        const n = r.view.fetch(va, buf);
        if (n > 0) {
            const last = (va + n - 1) >> mem.page_shift;
            if (last != r.first) r.second = last;
        }
        return n;
    }
};

pub const CompileError = error{ Full, OutOfMemory, Unsupported, TooLarge, Invalid };

fn compile(gpa: std.mem.Allocator, c: *cache_mod.Cache, view: *mem.View, pc: u64, page: u64, cfg: Config, st: *Stats) CompileError!*Tb {
    var r: ir.Region = .{ .entry_pc = pc };
    defer r.deinit(gpa);
    var b = ir.Builder.init(gpa, &r);
    var rd: Reader = .{ .view = view, .first = pc >> mem.page_shift };
    // Two pages at most, so a second page is the one after.
    var limits = cfg.limits;
    limits.max_pages = @min(limits.max_pages, 2);
    try cfg.frontend.lift(&b, .{ .ctx = &rd, .read = Reader.read }, pc, limits);
    if (std.debug.runtime_safety) if (ir.verify(&r) != null) return error.Invalid;
    if (cfg.optimize) {
        try opt.run(gpa, &r);
        if (std.debug.runtime_safety) if (ir.verify(&r) != null) return error.Invalid;
    }
    var a = try alloc_mod.spillAll(gpa, &r);
    defer a.deinit(gpa);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const code = try cfg.emitter.emit(gpa, &r, &a, &out);
    var n: cache_mod.Cache.New = .{ .pc = pc, .page = page, .entry = code.entry, .chain_entry = code.chain_entry };
    if (rd.second != cache_mod.no_page) {
        const va2 = rd.second << mem.page_shift;
        n.va2 = va2;
        n.page2 = codePage(view, va2, 1) orelse return error.Unsupported;
    }
    var chains: [cache_mod.max_chains]cache_mod.Chain = undefined;
    const sites = code.chainSites();
    const nc = @min(sites.len, chains.len);
    for (sites[0..nc], chains[0..nc]) |s, *d| d.* = .{ .site = s.site, .pc = s.pc };
    n.chains = chains[0..nc];
    const tb = try c.insert(out.items, n, view.code);
    st.compiled += 1;
    return tb;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const builtin = @import("builtin");
const codemem = @import("codemem.zig");
const eval_emit = @import("emit/eval.zig");
const a64 = struct {
    const lift = @import("a64/lift.zig");
    const t0 = @import("../interp/a64/exec.zig");
    const gen = @import("check/gen_a64.zig");
};

/// A one-vCPU arm64 machine over a View: code at 0x1000 (two pages, code
/// and writable, so programs can store to their own text), data at
/// 0x20000, run by T0 alone or by T1 with T0 for exceptions.
const Machine = struct {
    pages: [3 * mem.page_size]u8 align(mem.page_size) = @splat(0),
    maps: [2]mem.Mapping = undefined,
    code: mem.CodePages = undefined,
    tlb: mem.Tlb = .{},
    view: mem.View = undefined,
    rt: Runtime = .{},
    jit: ?*cache_mod.Cache = null,
    cpu: a64.t0.Cpu = .{},
    dcache: a64.t0.Cache = undefined,
    machine: a64.t0.Machine = undefined,
    stats: Stats = .{},
    em: emitter_mod.Emitter = eval_emit.emitter_def,

    const code_va = 0x1000;
    const data_va = 0x20000;

    fn init(m: *Machine, jit: ?*cache_mod.Cache) !void {
        const base = @intFromPtr(&m.pages);
        m.maps = .{
            .{ .va = code_va, .len = 2 * mem.page_size, .host = base, .perms = .{ .exec = true, .write = true } },
            .{ .va = data_va, .len = mem.page_size, .host = base + 2 * mem.page_size, .perms = .{ .write = true } },
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
        cx.interp = @intFromPtr(&a64.lift.interp);
        m.dcache = .init(testing.allocator);
        m.machine = .init(&m.cpu, cx, &m.dcache, null);
        cx.frontend = @intFromPtr(&m.machine);
    }

    fn deinit(m: *Machine) void {
        if (m.jit) |c| c.removeJumpCache(&m.rt.jump);
        m.dcache.deinit();
        m.code.deinit(testing.allocator);
    }

    fn dropHook(p: *anyopaque, host: usize, table: mem.Table) void {
        const m: *Machine = @ptrCast(@alignCast(p));
        mem.dropEntries(&m.tlb, host, table);
    }
    fn invHook(p: *anyopaque, page: u64) void {
        const m: *Machine = @ptrCast(@alignCast(p));
        if (m.jit) |c| c.invalidatePage(page);
    }

    fn load(m: *Machine, prog: []const u32, x: []const u64, nzcv: u32) void {
        // New text, as the host writing it would: what was decoded or
        // compiled from it goes.
        var same_text = true;
        for (prog, 0..) |w, i| same_text = same_text and std.mem.readInt(u32, m.pages[i * 4 ..][0..4], .little) == w;
        if (!same_text) {
            m.code.invalidateRange(@intFromPtr(&m.pages), m.pages.len);
            @memset(m.pages[0 .. 2 * mem.page_size], 0);
            for (prog, 0..) |w, i| std.mem.writeInt(u32, m.pages[i * 4 ..][0..4], w, .little);
        }
        @memset(m.pages[2 * mem.page_size ..], 0);
        for (0..64) |i| std.mem.writeInt(u64, m.pages[2 * mem.page_size + i * 8 ..][0..8], 0x1000 + i * 37, .little);
        m.cpu = .{ .pc = code_va, .nzcv = nzcv };
        @memcpy(m.cpu.r[0..x.len], x);
        m.tlb.flush();
        m.rt.jump.clear();
        m.rt.ctx.retired = 0;
    }

    /// Runs to the first SVC or exception (or `max` T0 steps' worth).
    fn run(m: *Machine) !a64.t0.Exit {
        if (m.jit == null) {
            const e = a64.t0.run(&m.machine, 1_000_000);
            m.rt.ctx.retired = m.cpu.retired;
            return e;
        }
        const cfg: Config = .{ .frontend = a64.lift.frontend, .emitter = m.em, .pc_off = @offsetOf(a64.t0.Cpu, "pc") };
        var rounds: u32 = 0;
        while (rounds < 100_000) : (rounds += 1) {
            switch (run_(m, cfg)) {
                .svc => return .syscall,
                .interrupted => {
                    // A full cache: flush, as the vmm layer would.
                    _ = @atomicRmw(u32, &m.rt.ctx.exit_request, .And, 0, .seq_cst);
                    m.jit.?.reset();
                },
                .t0 => {
                    const before = m.cpu.retired;
                    const e = a64.t0.run(&m.machine, 1);
                    m.rt.ctx.retired += m.cpu.retired - before;
                    if (e != .interrupted) return e;
                },
            }
        }
        return error.TooLong;
    }

    fn run_(m: *Machine, cfg: Config) Result {
        return dispatch_run(testing.allocator, &m.rt.ctx, cfg, &m.stats);
    }

    fn same(a: *const Machine, b: *const Machine) bool {
        return std.mem.eql(u64, &a.cpu.r, &b.cpu.r) and a.cpu.pc == b.cpu.pc and a.cpu.nzcv == b.cpu.nzcv and
            std.mem.eql(u128, &a.cpu.v, &b.cpu.v) and std.mem.eql(u8, &a.pages, &b.pages) and
            a.rt.ctx.retired == b.rt.ctx.retired and a.cpu.monitor.valid == b.cpu.monitor.valid;
    }
};

const dispatch_run = run;

fn sameExit(a: a64.t0.Exit, b: a64.t0.Exit) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .fault => |f| f.addr == b.fault.addr and f.esr == b.fault.esr,
        else => true,
    };
}

fn testCache(size: usize) !*cache_mod.Cache {
    if (!eval_emit.supported or !codemem.available()) return error.SkipZigTest;
    const c = try testing.allocator.create(cache_mod.Cache);
    errdefer testing.allocator.destroy(c);
    c.* = try cache_mod.Cache.init(testing.allocator, size);
    return c;
}

fn freeCache(c: *cache_mod.Cache) void {
    c.deinit();
    testing.allocator.destroy(c);
    eval_emit.reset();
}

/// Runs `prog` on T0 and on T1 and expects the same end.
fn expectSame(t1: *Machine, t0m: *Machine, prog: []const u32, x: []const u64, nzcv: u32) !void {
    t0m.load(prog, x, nzcv);
    t1.load(prog, x, nzcv);
    const e0 = try t0m.run();
    const e1 = try t1.run();
    if (!sameExit(e0, e1) or !Machine.same(t0m, t1)) {
        std.debug.print("T1 and T0 differ: exits {any} / {any}, pc {x} / {x}, retired {d} / {d}\n", .{ e1, e0, t1.cpu.pc, t0m.cpu.pc, t1.rt.ctx.retired, t0m.rt.ctx.retired });
        for (0..31) |i| if (t1.cpu.r[i] != t0m.cpu.r[i]) std.debug.print("  x{d}: {x} / {x}\n", .{ i, t1.cpu.r[i], t0m.cpu.r[i] });
        return error.Diverged;
    }
}

test "dispatch: T1 runs the tracer loop as T0 does, chained and from the cache" {
    const c = try testCache(1 << 20);
    defer freeCache(c);
    const t1 = try testing.allocator.create(Machine);
    defer testing.allocator.destroy(t1);
    const t0m = try testing.allocator.create(Machine);
    defer testing.allocator.destroy(t0m);
    t1.* = .{};
    t0m.* = .{};
    try t1.init(c);
    defer t1.deinit();
    try t0m.init(null);
    defer t0m.deinit();
    // The tracer's loop, with its data at 0x20000.
    const prog = @import("a64/tracer.zig").program;
    try expectSame(t1, t0m, &prog, &.{}, 0);
    try testing.expectEqual(@as(u64, 5050), t1.cpu.r[0]);
    const compiled = t1.stats.compiled;
    // Again: nothing new to compile.
    try expectSame(t1, t0m, &prog, &.{}, 0);
    try testing.expectEqual(compiled, t1.stats.compiled);
}

test "dispatch: random programs agree with T0, with chaining, faults, and flushes" {
    try randomPrograms(eval_emit.emitter_def);
}

test "dispatch: the same through this host's emitter" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    try randomPrograms(@import("emit/x64.zig").emitter_def);
}

fn randomPrograms(em: emitter_mod.Emitter) !void {
    // A small cache, so it fills and flushes now and then.
    const c = try testCache(codemem.granule);
    defer freeCache(c);
    const t1 = try testing.allocator.create(Machine);
    defer testing.allocator.destroy(t1);
    const t0m = try testing.allocator.create(Machine);
    defer testing.allocator.destroy(t0m);
    t1.* = .{};
    t0m.* = .{};
    try t1.init(c);
    defer t1.deinit();
    t1.em = em;
    try t0m.init(null);
    defer t0m.deinit();
    var prng = std.Random.DefaultPrng.init(0x7d15);
    var buf: [65]u32 = undefined;
    for (0..2000) |i| {
        const r = prng.random();
        const prog = a64.gen.program(r, .{ .len = 32 }, &buf);
        const regs = a64.gen.registers(r);
        // The generator's data page is at 0x20000 too.
        expectSame(t1, t0m, prog, &regs.x, regs.nzcv) catch |e| {
            std.debug.print("program {d}\n", .{i});
            return e;
        };
    }
    try testing.expect(t1.stats.linked > 0);
    try testing.expect(c.flushes > 0);
}

test "dispatch: a store to the code being run finishes in T0 and retranslates" {
    const c = try testCache(1 << 20);
    defer freeCache(c);
    const t1 = try testing.allocator.create(Machine);
    defer testing.allocator.destroy(t1);
    const t0m = try testing.allocator.create(Machine);
    defer testing.allocator.destroy(t0m);
    t1.* = .{};
    t0m.* = .{};
    try t1.init(c);
    defer t1.deinit();
    try t0m.init(null);
    defer t0m.deinit();
    // Loop 3 times: on the first pass, rewrite `add x0, x0, #1` (at
    // 0x1010) to `add x0, x0, #2`, so the passes add 1, 2, 2.
    const prog = [_]u32{
        0xD2800000, // movz x0, #0
        0xD2800061, // movz x1, #3
        0xD2820002, // movz x2, #0x1000
        0x18000143, // ldr w3, lit (the new word, at 0x1034)
        0x91000400, // loop: add x0, x0, #1          (0x1010)
        0xB9001043, //   str w3, [x2, #16]           (rewrites 0x1010)
        0xF1000421, //   subs x1, x1, #1
        0x54FFFFA1, //   b.ne loop (0x1010)
        0xD4000001, // svc #0
        0xD503201F, // nop
        0xD503201F, // nop
        0xD503201F, // nop
        0x8B000000, // (unused)
        0x91000800, // the new word: add x0, x0, #2  (0x1034)
    };
    try expectSame(t1, t0m, &prog, &.{}, 0);
    try testing.expectEqual(@as(u64, 5), t1.cpu.r[0]);
}
