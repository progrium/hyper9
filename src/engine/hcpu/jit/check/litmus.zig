//! Litmus tests: small programs run on host threads at once over shared
//! memory, many times, with a tally of what each run saw. They test the
//! tiers' memory model (fences, acquire and release, exclusives, atomics)
//! where the region check (check.zig) can't, since that runs one vCPU.
//!
//! A `Test` is a program per thread, each ending in the guest's system
//! call, with the data page's address in the guest's base register (an
//! `Arch` says which). Before each iteration the data page is zeroed and
//! each thread's Cpu reset; the threads wait on a spin barrier, start
//! together (with a little random skew, so more interleavings turn up),
//! and run to the system call. What a run saw (registers and memory words
//! the test names) is its outcome; the Tally counts outcomes, and flags
//! any the test forbids.
//!
//! A tier is T0, T1 under ir_eval, or T1 as this host's generated code.
//! T1 lifts each region once per thread and keeps it, so iterations after
//! the first run only the tier's code. The Arch is all that's guest
//! specific: `litmus_a64.zig` is ha64's; h86's goes beside it.

const std = @import("std");
const check = @import("../check.zig");
const ir = @import("../ir.zig");
const ir_eval = @import("../ir_eval.zig");
const ctx_mod = @import("../ctx.zig");
const mem = @import("../../interp/mem.zig");
const Native = @import("../emit/native.zig").Native;

const Ctx = ctx_mod.Ctx;
const Exit = ctx_mod.Exit;
const page_size = mem.page_size;

/// Where the programs live: thread i's code at code_va + i pages.
pub const code_va: u64 = 0x10000;
pub const data_va: u64 = 0x40000;
pub const max_threads = 4;
pub const max_observed = 8;

pub const Tier = enum { t0, ir_eval, native };

/// What a guest architecture provides.
pub const Arch = struct {
    /// The front end and the Cpu's layout, for T1.
    guest: *const check.Guest,
    /// Resets a Cpu (cpu_size bytes) to start at `entry` with the data
    /// page's address in the base register.
    init_cpu: *const fn (cpu: []u8, entry: u64, data: u64) void,
    /// Register `r` of a Cpu, for an outcome.
    reg: *const fn (cpu: []const u8, r: u8) u64,
    /// A thread's T0 over `map`, bound to `c` (whose cpu, tlb, and space
    /// are set): it sets c.frontend for T1's `call.interp` too.
    open: *const fn (gpa: std.mem.Allocator, c: *Ctx, map: *const mem.Map) anyerror!*anyopaque,
    close: *const fn (gpa: std.mem.Allocator, t0: *anyopaque) void,
    /// T0 from the Cpu's PC to the system call. Any other exit is an error:
    /// error.Undefined for an instruction T0 doesn't have.
    run_t0: *const fn (t0: *anyopaque) anyerror!void,
};

/// Something a run saw.
pub const Observe = union(enum) {
    /// A register of a thread, after its system call.
    reg: struct { thread: u8, reg: u8 },
    /// The u64 at this offset in the data page, after all threads finish.
    mem: u32,
};

pub const Outcome = [max_observed]u64;

pub const Test = struct {
    name: []const u8,
    /// Each thread's code, ending in the system call.
    threads: []const []const u8,
    observe: []const Observe,
    /// Outcomes the memory model rules out, in `observe`'s order.
    forbidden: []const []const u64 = &.{},
    /// If set, the only outcomes allowed (a counter's total, say).
    only: ?[]const []const u64 = null,

    fn allowed(t: *const Test, o: *const Outcome) bool {
        const n = t.observe.len;
        for (t.forbidden) |f| if (std.mem.eql(u64, f, o[0..n])) return false;
        if (t.only) |only| {
            for (only) |a| if (std.mem.eql(u64, a, o[0..n])) return true;
            return false;
        }
        return true;
    }
};

pub const Options = struct {
    iterations: u32 = 1000,
    tier: Tier = .t0,
    /// Up to this many spins after the barrier, at random per thread.
    skew: u32 = 64,
    seed: u64 = 0,
};

pub const Tally = struct {
    counts: std.AutoArrayHashMapUnmanaged(Outcome, u64) = .empty,
    /// Runs whose outcome the test forbids.
    forbidden: u64 = 0,
    iterations: u64 = 0,

    pub fn deinit(t: *Tally, gpa: std.mem.Allocator) void {
        t.counts.deinit(gpa);
    }

    pub fn count(t: *const Tally, o: []const u64) u64 {
        var key: Outcome = @splat(0);
        @memcpy(key[0..o.len], o);
        return t.counts.get(key) orelse 0;
    }

    pub fn print(t: *const Tally, test_: *const Test, tier: Tier, w: *std.Io.Writer) !void {
        try w.print("{s} ({t}): {d} runs{s}\n", .{ test_.name, tier, t.iterations, if (t.forbidden != 0) ", FORBIDDEN OUTCOMES SEEN" else "" });
        for (t.counts.keys(), t.counts.values()) |k, v| {
            try w.writeAll("  ");
            for (test_.observe, 0..) |ob, i| switch (ob) {
                .reg => |r| try w.print("{d}:r{d}={d} ", .{ r.thread, r.reg, k[i] }),
                .mem => |off| try w.print("[{x}]={d} ", .{ off, k[i] }),
            };
            try w.print("{d}{s}\n", .{ v, if (test_.allowed(&k)) "" else "  forbidden" });
        }
    }
};

/// Runs `t` `opts.iterations` times on `opts.tier`.
pub fn run(gpa: std.mem.Allocator, arch: *const Arch, t: *const Test, opts: Options) !Tally {
    std.debug.assert(t.threads.len >= 1 and t.threads.len <= max_threads);
    std.debug.assert(t.observe.len <= max_observed);
    const n = t.threads.len;
    const code = try gpa.alignedAlloc(u8, .fromByteUnits(page_size), n * page_size);
    defer gpa.free(code);
    const data = try gpa.alignedAlloc(u8, .fromByteUnits(page_size), page_size);
    defer gpa.free(data);
    @memset(code, 0);
    for (t.threads, 0..) |p, i| @memcpy(code[i * page_size ..][0..p.len], p);
    var regions = [_]mem.Region{
        .{ .va = code_va, .mem = code, .exec = true },
        .{ .va = data_va, .mem = data, .write = true },
    };
    const map: mem.Map = .{ .regions = &regions };

    var shared: Shared = .{};
    var workers: [max_threads]Worker = undefined;
    var started: usize = 0;
    defer {
        @atomicStore(u32, &shared.stop, 1, .release);
        @atomicStore(u32, &shared.gen, std.math.maxInt(u32), .release);
        for (workers[0..started]) |*w| {
            w.thread.join();
            w.deinit();
        }
    }
    for (0..n) |i| {
        workers[i] = try Worker.init(gpa, arch, &map, i, opts);
        workers[i].shared = &shared;
        workers[i].thread = std.Thread.spawn(.{}, Worker.loop, .{&workers[i]}) catch |e| {
            workers[i].deinit();
            return e;
        };
        started += 1;
    }

    var tally: Tally = .{};
    errdefer tally.deinit(gpa);
    var it: u32 = 0;
    while (it < opts.iterations) : (it += 1) {
        @memset(data, 0);
        @atomicStore(u32, &shared.done, 0, .release);
        _ = @atomicRmw(u32, &shared.gen, .Add, 1, .acq_rel);
        while (@atomicLoad(u32, &shared.done, .acquire) != n) std.atomic.spinLoopHint();
        for (workers[0..n]) |*w| if (w.err) |e| return e;
        var o: Outcome = @splat(0);
        for (t.observe, 0..) |ob, i| o[i] = switch (ob) {
            .reg => |r| arch.reg(workers[r.thread].cpu, r.reg),
            .mem => |off| std.mem.readInt(u64, data[off..][0..8], .little),
        };
        const g = try tally.counts.getOrPut(gpa, o);
        if (!g.found_existing) g.value_ptr.* = 0;
        g.value_ptr.* += 1;
        if (!t.allowed(&o)) tally.forbidden += 1;
        tally.iterations += 1;
    }
    return tally;
}

const Shared = struct {
    /// Bumped to start an iteration; maxInt with `stop` to end.
    gen: u32 = 0,
    done: u32 = 0,
    stop: u32 = 0,
};

/// A host thread running one guest thread, iteration after iteration.
const Worker = struct {
    gpa: std.mem.Allocator,
    arch: *const Arch,
    map: *const mem.Map,
    index: usize,
    opts: Options,
    shared: *Shared = undefined,
    thread: std.Thread = undefined,
    cpu: []align(16) u8,
    tlb: mem.Tlb = .{},
    ctx: Ctx,
    t0: ?*anyopaque = null,
    native: ?Native = null,
    /// T1's regions by PC, lifted on first use.
    regions: std.AutoHashMapUnmanaged(u64, Compiled) = .empty,
    err: ?anyerror = null,

    const Compiled = struct { reg: ir.Region, entry: ?ctx_mod.EntryFn };

    fn init(gpa: std.mem.Allocator, arch: *const Arch, map: *const mem.Map, index: usize, opts: Options) !Worker {
        const cpu = try gpa.alignedAlloc(u8, .@"16", arch.guest.cpu_size);
        errdefer gpa.free(cpu);
        @memset(cpu, 0);
        var w: Worker = .{ .gpa = gpa, .arch = arch, .map = map, .index = index, .opts = opts, .cpu = cpu, .ctx = .{} };
        if (opts.tier == .native) w.native = try Native.init();
        errdefer if (w.native) |*nt| nt.deinit();
        return w;
    }

    fn deinit(w: *Worker) void {
        var it = w.regions.valueIterator();
        while (it.next()) |c| c.reg.deinit(w.gpa);
        w.regions.deinit(w.gpa);
        if (w.native) |*nt| nt.deinit();
        if (w.t0) |t| w.arch.close(w.gpa, t);
        w.gpa.free(w.cpu);
    }

    fn loop(w: *Worker) void {
        // The Ctx and T0 point at this Worker, so they're set up here, in
        // its final place.
        w.ctx = .{
            .cpu = @intFromPtr(w.cpu.ptr),
            .tlb = @intFromPtr(&w.tlb),
            .space = @intFromPtr(w.map),
            .slow_load = @intFromPtr(&mem.mapSlowLoad),
            .slow_store = @intFromPtr(&mem.mapSlowStore),
            .slow_cas = @intFromPtr(&mem.mapSlowCas),
            .interp = @intFromPtr(w.arch.guest.frontend.interp),
        };
        w.t0 = w.arch.open(w.gpa, &w.ctx, w.map) catch @panic("litmus: out of memory");
        var prng = std.Random.DefaultPrng.init(w.opts.seed +% w.index *% 0x9e3779b97f4a7c15);
        const rand = prng.random();
        var seen: u32 = 0;
        while (true) {
            const skew = if (w.opts.skew == 0) 0 else rand.uintLessThan(u32, w.opts.skew);
            while (@atomicLoad(u32, &w.shared.gen, .acquire) == seen) std.atomic.spinLoopHint();
            if (@atomicLoad(u32, &w.shared.stop, .acquire) != 0) return;
            seen +%= 1;
            // Reset here, not after the last run: the main thread reads
            // this Cpu's registers for the outcome until it starts the next.
            w.arch.init_cpu(w.cpu, code_va + w.index * page_size, data_va);
            for (0..skew) |_| std.atomic.spinLoopHint();
            w.runOnce() catch |e| {
                w.err = e;
            };
            _ = @atomicRmw(u32, &w.shared.done, .Add, 1, .acq_rel);
        }
    }

    fn runOnce(w: *Worker) !void {
        if (w.opts.tier == .t0) return w.arch.run_t0(w.t0.?);
        const g = w.arch.guest;
        const pc_at = w.cpu[g.pc_off..];
        while (true) {
            const pc: u64 = if (g.pc_bytes == 4) std.mem.readInt(u32, pc_at[0..4], .little) else std.mem.readInt(u64, pc_at[0..8], .little);
            const c = try w.compiled(pc);
            w.ctx.budget = std.math.maxInt(i64);
            const e: Exit = if (c.entry) |f| @enumFromInt(f(&w.ctx)) else try ir_eval.run(w.gpa, &c.reg, &w.ctx);
            if (g.pc_bytes == 4) std.mem.writeInt(u32, pc_at[0..4], @truncate(w.ctx.exit_pc), .little) else std.mem.writeInt(u64, pc_at[0..8], w.ctx.exit_pc, .little);
            switch (e) {
                .chain, .indirect, .interrupted => {},
                .svc => return,
                .undef => return error.Undefined,
                else => return error.UnexpectedExit,
            }
        }
    }

    fn compiled(w: *Worker, pc: u64) !*Compiled {
        const g = try w.regions.getOrPut(w.gpa, pc);
        if (g.found_existing) return g.value_ptr;
        errdefer w.regions.removeByPtr(g.key_ptr);
        var backing = check.mapBacking(w.map);
        var reg = try check.liftAt(w.gpa, w.arch.guest, &backing, pc, .{});
        errdefer reg.deinit(w.gpa);
        const entry = if (w.native) |*nt| try nt.compile(w.gpa, &reg) else null;
        g.value_ptr.* = .{ .reg = reg, .entry = entry };
        return g.value_ptr;
    }
};

/// Code bytes from instruction words (arm64), at comptime.
pub inline fn words(comptime ws: []const u32) []const u8 {
    comptime {
        var b: [ws.len * 4]u8 = undefined;
        for (ws, 0..) |x, i| std.mem.writeInt(u32, b[i * 4 ..][0..4], x, .little);
        const out = b;
        return &out;
    }
}
