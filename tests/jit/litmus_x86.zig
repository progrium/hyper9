//! zig build hcpu (and litmus-x86): h86's memory-model litmus tests, on
//! real host threads running compiled h86 regions (this host's emitter,
//! through emit/native.zig) over one shared data page.
//!
//! x86 is TSO, which a 386 program may rely on. What these check:
//!
//! - SB (store buffering) with a locked instruction between each thread's
//!   store and load: never both loads 0. Without one, TSO allows both 0,
//!   so the plain SB case only tallies.
//! - MP (message passing): a reader that sees the flag sees the data.
//! - A LOCK XADD counter on four threads loses no increments.
//!
//! On an x86-64 host the emitter's plain moves are TSO already; on arm64
//! the regions' `tso` flag makes them LDAR and STLR, which is what MP
//! checks. Each test is a program per thread at its own code page, run
//! from a spin barrier, many times. D3's shared harness
//! (src/jit/check/litmus.zig) is the place to fold these into later.

const std = @import("std");
const hcpu = @import("hcpu");
const mem = hcpu.mem;
const ir = hcpu.ir;
const Ctx = hcpu.ctx.Ctx;
const Exit = hcpu.ctx.Exit;
const native = hcpu.emit.native;
const lift = hcpu.x86jit.lift;
const cpu_mod = hcpu.x86.cpu;
const Cpu = cpu_mod.Cpu;
const testing = std.testing;

const page_size = mem.page_size;
const code_va: u32 = 0x10000;
const data_va: u32 = 0x40000;
const max_threads = 4;
/// Print every test's tally of outcomes.
const verbose = false;

// Data addresses, a cache line apart.
const x_va = data_va;
const y_va = data_va + 0x40;
const z_va = data_va + 0x80;
const flag_va = data_va + 0xc0;
const cnt_va = data_va + 0x100;

/// One test: a program per thread, and a check of the outcome.
const Test = struct {
    name: []const u8,
    programs: []const []const u8,
    /// Whether an outcome is allowed. It sees each thread's registers
    /// and the data page.
    allowed: *const fn (r: []const [8]u32, data: []const u8) bool,
    /// The outcome's key for the tally.
    key: *const fn (r: []const [8]u32, data: []const u8) u32,
};

// ---------------------------------------------------------------- encodings

fn le(v: u32) [4]u8 {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    return b;
}

/// movl $imm, addr
fn movStore(addr: u32, imm: u32) [10]u8 {
    return [_]u8{ 0xc7, 0x05 } ++ le(addr) ++ le(imm);
}
/// movl addr, %eax
fn loadEax(addr: u32) [5]u8 {
    return [_]u8{0xa1} ++ le(addr);
}
/// movl addr, %ebx
fn loadEbx(addr: u32) [6]u8 {
    return [_]u8{ 0x8b, 0x1d } ++ le(addr);
}
/// movl $1, %ecx; xchgl %ecx, addr
fn xchgStore(addr: u32) [11]u8 {
    return [_]u8{ 0xb9, 1, 0, 0, 0, 0x87, 0x0d } ++ le(addr);
}
/// lock orl $0, addr: a full barrier on x86.
fn lockFence(addr: u32) [8]u8 {
    return [_]u8{ 0xf0, 0x83, 0x0d } ++ le(addr) ++ [_]u8{0};
}
const int80 = [_]u8{ 0xcd, 0x80 };

// ---------------------------------------------------------------- tests

const sb_plain = [_][]const u8{
    &(movStore(x_va, 1) ++ loadEax(y_va) ++ int80),
    &(movStore(y_va, 1) ++ loadEax(x_va) ++ int80),
};
const sb_xchg = [_][]const u8{
    &(xchgStore(x_va) ++ loadEax(y_va) ++ int80),
    &(xchgStore(y_va) ++ loadEax(x_va) ++ int80),
};
const sb_fence = [_][]const u8{
    &(movStore(x_va, 1) ++ lockFence(z_va) ++ loadEax(y_va) ++ int80),
    &(movStore(y_va, 1) ++ lockFence(z_va) ++ loadEax(x_va) ++ int80),
};
const mp = [_][]const u8{
    &(movStore(x_va, 1) ++ movStore(flag_va, 1) ++ int80),
    &(loadEax(flag_va) ++ loadEbx(x_va) ++ int80),
};

const iters_per_thread = 2000;
/// movl $1, %ecx; movl $N, %esi; loop: lock xaddl %ecx, cnt; movl $1,
/// %ecx; decl %esi; jnz loop; int $0x80
const counter_prog = [_]u8{ 0xbe } ++ le(iters_per_thread) ++
    [_]u8{ 0xf0, 0x0f, 0xc1, 0x0d } ++ le(cnt_va) ++
    [_]u8{ 0xb9, 1, 0, 0, 0, 0x4e, 0x75, 0xf0 } ++ int80;
const counter = [_][]const u8{ &([_]u8{ 0xb9, 1, 0, 0, 0 } ++ counter_prog), &([_]u8{ 0xb9, 1, 0, 0, 0 } ++ counter_prog), &([_]u8{ 0xb9, 1, 0, 0, 0 } ++ counter_prog), &([_]u8{ 0xb9, 1, 0, 0, 0 } ++ counter_prog) };

fn sbKey(r: []const [8]u32, _: []const u8) u32 {
    return r[0][0] << 1 | r[1][0];
}
fn sbAny(_: []const [8]u32, _: []const u8) bool {
    return true;
}
fn sbFenced(r: []const [8]u32, _: []const u8) bool {
    return !(r[0][0] == 0 and r[1][0] == 0);
}
fn mpKey(r: []const [8]u32, _: []const u8) u32 {
    return r[1][0] << 1 | r[1][3];
}
fn mpAllowed(r: []const [8]u32, _: []const u8) bool {
    return !(r[1][0] == 1 and r[1][3] == 0);
}
fn counterValue(data: []const u8) u32 {
    return std.mem.readInt(u32, data[cnt_va - data_va ..][0..4], .little);
}
fn counterKey(_: []const [8]u32, data: []const u8) u32 {
    return counterValue(data);
}
fn counterAllowed(_: []const [8]u32, data: []const u8) bool {
    return counterValue(data) == max_threads * iters_per_thread;
}

const tests = [_]Test{
    .{ .name = "SB (plain, 0/0 allowed)", .programs = &sb_plain, .allowed = sbAny, .key = sbKey },
    .{ .name = "SB+xchg", .programs = &sb_xchg, .allowed = sbFenced, .key = sbKey },
    .{ .name = "SB+lock-or", .programs = &sb_fence, .allowed = sbFenced, .key = sbKey },
    .{ .name = "MP", .programs = &mp, .allowed = mpAllowed, .key = mpKey },
    .{ .name = "LOCK XADD counter", .programs = &counter, .allowed = counterAllowed, .key = counterKey },
};

// ---------------------------------------------------------------- machine

/// The shared address space: a code page per thread and a data page.
const Space = struct {
    code: [max_threads * page_size]u8 align(page_size) = @splat(0xcc),
    data: [page_size]u8 align(page_size) = @splat(0),
    regions: [2]mem.Region = undefined,
    map: mem.Map = undefined,
    /// Compiled regions by PC, filled on first use under `lock`.
    lock: std.atomic.Value(bool) = .init(false),
    entries: std.AutoHashMapUnmanaged(u32, hcpu.ctx.EntryFn) = .empty,
    jit: native.Native,
    gpa: std.mem.Allocator,

    fn init(s: *Space, gpa: std.mem.Allocator) !void {
        s.* = .{ .jit = try native.Native.init(), .gpa = gpa };
        s.regions = .{
            .{ .va = code_va, .mem = &s.code, .exec = true },
            .{ .va = data_va, .mem = &s.data, .write = true },
        };
        s.map = .{ .regions = &s.regions };
    }

    fn deinit(s: *Space) void {
        s.entries.deinit(s.gpa);
        s.jit.deinit();
    }

    fn load(s: *Space, programs: []const []const u8) void {
        s.code = @splat(0xcc);
        for (programs, 0..) |p, t| @memcpy(s.code[t * page_size ..][0..p.len], p);
        s.entries.clearRetainingCapacity();
        s.jit.code.reset();
    }

    fn entry(s: *Space, pc: u32) !hcpu.ctx.EntryFn {
        while (s.lock.swap(true, .acquire)) std.atomic.spinLoopHint();
        defer s.lock.store(false, .release);
        if (s.entries.get(pc)) |e| return e;
        const backing = hcpu.check.mapBacking(&s.map);
        var reg = try hcpu.check.liftAt(s.gpa, &hcpu.check.x86.guest, &backing, pc, .{});
        defer reg.deinit(s.gpa);
        if (!reg.tso) return error.NotTso;
        const e = try s.jit.compile(s.gpa, &reg) orelse return error.Unsupported;
        try s.entries.put(s.gpa, pc, e);
        return e;
    }
};

/// T0's memory over the shared Map, for `call.interp`.
fn mapTranslate(p: *anyopaque, va: u32, access: cpu_mod.Access) ?[*]u8 {
    const m: *const mem.Map = @ptrCast(@alignCast(p));
    for (m.regions) |r| if (va >= r.va and va - r.va < r.mem.len) {
        const ok = switch (access) {
            .read => r.read,
            .write => r.write,
            .exec => r.exec,
        };
        return if (ok) r.mem.ptr + (va - r.va) else null;
    };
    return null;
}

const Vcpu = struct {
    cpu: Cpu = .{},
    tlb: mem.Tlb = .{},
    ctx: Ctx = .{},
    lm: lift.Mem = undefined,

    fn init(v: *Vcpu, s: *Space) void {
        v.lm = .{ .ctx = &s.map, .translateFn = mapTranslate };
        v.ctx = .{
            .cpu = @intFromPtr(&v.cpu),
            .tlb = @intFromPtr(&v.tlb),
            .space = @intFromPtr(&s.map),
            .slow_load = @intFromPtr(&mem.mapSlowLoad),
            .slow_store = @intFromPtr(&mem.mapSlowStore),
            .slow_cas = @intFromPtr(&mem.mapSlowCas),
            .interp = @intFromPtr(&lift.interp),
            .frontend = @intFromPtr(&v.lm),
            .helpers = hcpu.x86jit.helpers.tableAddr(),
        };
    }

    /// Runs compiled code from `pc` to the INT $0x80.
    fn run(v: *Vcpu, s: *Space, pc: u32) !void {
        v.cpu = .{};
        v.cpu.eip = pc;
        var n: u32 = 0;
        while (n < 1 << 20) : (n += 1) {
            const f = try s.entry(v.cpu.eip);
            const e: Exit = @enumFromInt(f(&v.ctx));
            v.cpu.eip = @truncate(v.ctx.exit_pc);
            switch (e) {
                .chain, .indirect => {},
                .svc => return,
                else => {
                    std.debug.print("litmus: exit {t} at {x}\n", .{ e, v.cpu.eip });
                    return error.UnexpectedExit;
                },
            }
        }
        return error.TooLong;
    }
};

// ---------------------------------------------------------------- harness

const Harness = struct {
    space: *Space,
    vcpus: [max_threads]Vcpu = undefined,
    threads: usize = 0,
    /// Bumped by the main thread to start a round; the workers count
    /// `done` up when they finish it.
    round: std.atomic.Value(u32) = .init(0),
    done: std.atomic.Value(u32) = .init(0),
    quit: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),

    fn worker(h: *Harness, t: usize) void {
        var seen: u32 = 0;
        while (true) {
            var r = h.round.load(.acquire);
            while (r == seen) : (r = h.round.load(.acquire)) {
                if (h.quit.load(.acquire)) return;
                std.atomic.spinLoopHint();
            }
            seen = r;
            h.vcpus[t].run(h.space, code_va + @as(u32, @intCast(t)) * page_size) catch |e| {
                std.debug.print("litmus: thread {d}: {t}\n", .{ t, e });
                h.failed.store(true, .release);
            };
            _ = h.done.fetchAdd(1, .acq_rel);
        }
    }
};

fn runTest(gpa: std.mem.Allocator, s: *Space, t: Test, rounds: u32) !bool {
    s.load(t.programs);
    const h = try gpa.create(Harness);
    defer gpa.destroy(h);
    h.* = .{ .space = s, .threads = t.programs.len };
    for (h.vcpus[0..h.threads]) |*v| v.init(s);
    // Compile once on this thread, so the rounds race only on data.
    for (0..h.threads) |i| try h.vcpus[i].run(s, code_va + @as(u32, @intCast(i)) * page_size);

    var threads: [max_threads]std.Thread = undefined;
    for (0..h.threads) |i| threads[i] = try std.Thread.spawn(.{}, Harness.worker, .{ h, i });
    var tally: std.AutoArrayHashMapUnmanaged(u32, u32) = .empty;
    defer tally.deinit(gpa);
    var bad: u32 = 0;
    var regs: [max_threads][8]u32 = undefined;
    var r: u32 = 0;
    while (r < rounds) : (r += 1) {
        s.data = @splat(0);
        h.done.store(0, .release);
        _ = h.round.fetchAdd(1, .acq_rel);
        while (h.done.load(.acquire) != h.threads) std.atomic.spinLoopHint();
        if (h.failed.load(.acquire)) break;
        for (0..h.threads) |i| regs[i] = h.vcpus[i].cpu.r;
        const key = t.key(regs[0..h.threads], &s.data);
        const g = try tally.getOrPut(gpa, key);
        g.value_ptr.* = if (g.found_existing) g.value_ptr.* + 1 else 1;
        if (!t.allowed(regs[0..h.threads], &s.data)) bad += 1;
    }
    h.quit.store(true, .release);
    for (threads[0..h.threads]) |th| th.join();
    if (h.failed.load(.acquire)) return false;

    // The build runner fails a test that writes to stderr, so the tally
    // shows only with a forbidden outcome (or set `verbose`).
    if (bad != 0 or verbose) {
        std.debug.print("litmus-x86 ({s}): {s}: {d} rounds,", .{ native.name, t.name, rounds });
        for (tally.keys(), tally.values()) |k, v| std.debug.print(" {x}:{d}", .{ k, v });
        std.debug.print("{s}\n", .{if (bad != 0) "  FORBIDDEN OUTCOMES" else ""});
    }
    return bad == 0;
}

test "litmus-x86: TSO on compiled h86 code, across host threads" {
    if (!native.available()) return error.SkipZigTest;
    const gpa = testing.allocator;
    const s = try gpa.create(Space);
    defer gpa.destroy(s);
    try s.init(gpa);
    defer s.deinit();
    var ok = true;
    for (tests) |t| {
        const rounds: u32 = if (t.programs.len > 2) 200 else 20000;
        if (!try runTest(gpa, s, t, rounds)) ok = false;
    }
    try testing.expect(ok);
}
