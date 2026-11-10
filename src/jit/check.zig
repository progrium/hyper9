//! Region check mode: T1 against T0.
//!
//! A lifted region (run by `ir_eval` or by an emitter's code) and the front
//! end's T0 start from the same Cpu and the same memory, each on its own
//! copy of the pages, and must end the same way: the same exit, exit PC,
//! fault address and access, instructions retired, registers and flags
//! (the whole Cpu, as the front end's `diff` sees it), and memory.
//!
//! It's generic over the front end: everything guest-specific is in a
//! `Guest` (a `Frontend` plus T0's single step, the Cpu's size and PC, and
//! a register diff). `check/a64.zig` is ha64's; h86's goes in
//! `check/x86.zig` when its T0 lands.
//!
//! Memory is a `Shadow` per tier: a copy-on-touch view of a `Backing`
//! address space. Pages are copied on first access, so a check costs the
//! pages the region touches, not the address space. That makes the same
//! code usable from unit tests, the fuzzers, and the runtime: with
//! `-Djit-check` the runtime runs every region through `Checker`, which
//! commits the agreed memory and Cpu, so `zig build integration -Demu=zig
//! -Djit-check` runs the integration suite with every region checked.
//!
//! The rules both tiers are held to (they're also the lifters'):
//!
//! - An instruction that completes is retired, and so is SVC (resume at
//!   the next PC). A faulting, undefined, or breakpoint instruction isn't.
//! - At `chain`, `indirect`, and `interrupted`, T0 must have retired the
//!   same number of instructions with no exit, and be at the exit PC.
//! - At `svc`, `brk`, `undef`, and `fault`, T0 must take the same exit at
//!   the same PC after the same number of instructions.

const std = @import("std");
const builtin = @import("builtin");
const ir = @import("ir.zig");
const ir_eval = @import("ir_eval.zig");
const ctx_mod = @import("ctx.zig");
const fe = @import("frontend.zig");
const mem = @import("../interp/mem.zig");

const Ctx = ctx_mod.Ctx;
const Exit = ctx_mod.Exit;
const page_size = mem.page_size;

/// ha64's Guest, and fuzz-a64's generator and checks.
pub const a64 = @import("check/a64.zig");
pub const gen_a64 = @import("check/gen_a64.zig");
pub const fuzz_a64 = @import("check/fuzz_a64.zig");

/// What check mode needs from a guest architecture, beyond its `Frontend`.
pub const Guest = struct {
    frontend: fe.Frontend,
    /// The size of the front end's Cpu (aligned to at most 16), for copies.
    cpu_size: usize,
    /// Byte offset of the guest PC (a u64) in the Cpu.
    pc_off: usize,
    /// Runs one T0 instruction at the Cpu's PC, with ctx's memory (TLB and
    /// slow paths, and ctx.frontend as `bind` left it). Returns `.ok` when
    /// the instruction retired and the Cpu's PC is the next one, or an
    /// exit with ctx.exit_pc (and the fault fields) set, as `InterpFn`
    /// does. `.svc` counts as retired.
    step: *const fn (c: *Ctx) u32,
    /// Writes each difference between Cpus `a` (T1) and `b` (T0) to `w`;
    /// returns whether there were any. The PC is compared separately.
    diff: *const fn (a: *const anyopaque, b: *const anyopaque, w: *std.Io.Writer) bool,
    /// Sets up ctx.frontend (and anything else T0 or `call.interp` needs)
    /// over the shadow memory; `unbind` frees it.
    bind: ?*const fn (gpa: std.mem.Allocator, c: *Ctx, s: *Shadow) anyerror!void = null,
    unbind: ?*const fn (gpa: std.mem.Allocator, c: *Ctx) void = null,
    /// The bits of exit_info both tiers must agree on for a fault.
    info_mask: u64 = 0xff,
    /// Whether T1's retired count is exact at a fault. A lifter that
    /// retires a block's count at its end leaves it short when a load or
    /// store in the block faults; with this false, T0 runs to its own exit
    /// at a fault and the counts aren't compared.
    fault_retired_exact: bool = true,
    /// A disassembler for reports, if the front end has one.
    disasm: ?*const fn (src: fe.Source, pc: u64, w: *std.Io.Writer) void = null,
};

// ---------------------------------------------------------------- memory

/// The address space both tiers' shadows copy from.
pub const Backing = struct {
    ctx: *anyopaque,
    /// Guest page `vp` (va >> 12): its host bytes and permissions, or null
    /// if it's unmapped.
    page: *const fn (ctx: *anyopaque, vp: u64) ?Page,
    /// Every mapped page, for front ends whose T0 needs all its memory up
    /// front (`Shadow.materialize`). Optional.
    each: ?*const fn (ctx: *anyopaque, f: *const fn (data: *anyopaque, vp: u64) void, data: *anyopaque) void = null,

    pub const Page = struct { host: [*]u8, read: bool, write: bool, exec: bool };

    /// Reads code for lifting.
    pub fn source(b: *const Backing) fe.Source {
        return .{ .ctx = @constCast(b), .read = readCode };
    }

    fn readCode(p: *anyopaque, va: u64, buf: []u8) usize {
        const b: *const Backing = @ptrCast(@alignCast(p));
        for (buf, 0..) |*o, i| {
            const a = va +% i;
            const pg = b.page(b.ctx, a >> mem.page_shift) orelse return i;
            if (!pg.exec) return i;
            o.* = pg.host[@intCast(a & (page_size - 1))];
        }
        return buf.len;
    }
};

/// A Backing over the stand-in `mem.Map`.
pub fn mapBacking(m: *const mem.Map) Backing {
    return .{ .ctx = @constCast(m), .page = mapPage, .each = mapEach };
}

fn mapPage(p: *anyopaque, vp: u64) ?Backing.Page {
    const m: *const mem.Map = @ptrCast(@alignCast(p));
    const va = vp << mem.page_shift;
    for (m.regions) |r| {
        if (va >= r.va and va - r.va < r.mem.len) {
            std.debug.assert(r.va % page_size == 0 and r.mem.len % page_size == 0);
            return .{ .host = r.mem.ptr + @as(usize, @intCast(va - r.va)), .read = r.read, .write = r.write, .exec = r.exec };
        }
    }
    return null;
}

fn mapEach(p: *anyopaque, f: *const fn (*anyopaque, u64) void, data: *anyopaque) void {
    const m: *const mem.Map = @ptrCast(@alignCast(p));
    for (m.regions) |r| {
        var off: usize = 0;
        while (off < r.mem.len) : (off += page_size) f(data, (r.va + off) >> mem.page_shift);
    }
}

/// One tier's view of memory: pages copied from the backing on first
/// touch. ctx.space points at it, and its slow paths are `slowLoad` and
/// `slowStore`; the TLB is filled with the copies' addresses, so inline
/// accesses hit the copies too.
pub const Shadow = struct {
    gpa: std.mem.Allocator,
    backing: Backing,
    pages: std.AutoArrayHashMapUnmanaged(u64, *Copy) = .empty,
    /// Set when a page couldn't be copied (out of memory): the check is void.
    oom: bool = false,

    pub const Copy = struct {
        data: [page_size]u8 align(page_size),
        orig: [*]u8,
        read: bool,
        write: bool,
        exec: bool,
    };

    pub fn init(gpa: std.mem.Allocator, backing: Backing) Shadow {
        return .{ .gpa = gpa, .backing = backing };
    }

    pub fn deinit(s: *Shadow) void {
        for (s.pages.values()) |c| s.gpa.destroy(c);
        s.pages.deinit(s.gpa);
    }

    /// The copy of page vp, made now if it wasn't yet; null if unmapped.
    pub fn get(s: *Shadow, vp: u64) ?*Copy {
        if (s.pages.get(vp)) |c| return c;
        const pg = s.backing.page(s.backing.ctx, vp) orelse return null;
        const c = s.gpa.create(Copy) catch {
            s.oom = true;
            return null;
        };
        c.* = .{ .data = undefined, .orig = pg.host, .read = pg.read, .write = pg.write, .exec = pg.exec };
        @memcpy(&c.data, pg.host[0..page_size]);
        s.pages.put(s.gpa, vp, c) catch {
            s.gpa.destroy(c);
            s.oom = true;
            return null;
        };
        return c;
    }

    /// Copies every mapped page now (needs `Backing.each`).
    pub fn materialize(s: *Shadow) void {
        const each = s.backing.each orelse return;
        each(s.backing.ctx, struct {
            fn f(d: *anyopaque, vp: u64) void {
                const sh: *Shadow = @ptrCast(@alignCast(d));
                _ = sh.get(vp);
            }
        }.f, s);
    }

    /// The bytes of page vp as this tier left them.
    pub fn view(s: *const Shadow, vp: u64) ?*const [page_size]u8 {
        if (s.pages.get(vp)) |c| return &c.data;
        const pg = s.backing.page(s.backing.ctx, vp) orelse return null;
        return pg.host[0..page_size];
    }

    /// Writes this tier's copies of writable pages back to the backing.
    pub fn commit(s: *const Shadow) void {
        var it = s.pages.iterator();
        while (it.next()) |e| {
            const c = e.value_ptr.*;
            if (c.write and !std.mem.eql(u8, &c.data, c.orig[0..page_size])) @memcpy(c.orig[0..page_size], &c.data);
        }
    }

    fn byte(s: *Shadow, tlb: *mem.Tlb, va: u64, acc: mem.Access) union(enum) { ok: *u8, fault: mem.FaultKind } {
        const vp = va >> mem.page_shift;
        const c = s.get(vp) orelse return .{ .fault = .unmapped };
        const allowed = switch (acc) {
            .read => c.read,
            .write => c.write,
            .exec => c.exec,
        };
        if (!allowed) return .{ .fault = .permission };
        const host: usize = @intFromPtr(&c.data) + @as(usize, @intCast(va & (page_size - 1)));
        if (acc != .exec) {
            const table = if (acc == .write) &tlb.write else &tlb.read;
            table[@intCast(vp & (mem.entries - 1))] = .{ .tag = vp, .delta = @as(u64, @intFromPtr(&c.data)) -% (vp << mem.page_shift) };
        }
        return .{ .ok = @ptrFromInt(host) };
    }

    fn fault(c: *Ctx, va: u64, acc: mem.Access, k: mem.FaultKind) u32 {
        c.exit_addr = va;
        c.exit_info = @as(u64, @intFromEnum(acc)) | (@as(u64, @intFromEnum(k)) << 8);
        return @intFromEnum(Exit.fault);
    }

    /// mem.SlowLoadFn over the Shadow in ctx.space.
    pub fn slowLoad(c: *Ctx, va: u64, size_log2: u32) callconv(.c) u32 {
        const s: *Shadow = @ptrFromInt(@as(usize, @intCast(c.space)));
        const tlb: *mem.Tlb = @ptrFromInt(@as(usize, @intCast(c.tlb)));
        const n = @as(u32, 1) << @intCast(size_log2);
        var v: u64 = 0;
        for (0..n) |i| {
            const a = va +% i;
            switch (s.byte(tlb, a, .read)) {
                .ok => |p| v |= @as(u64, p.*) << @intCast(8 * i),
                .fault => |k| return fault(c, a, .read, k),
            }
        }
        c.scratch = v;
        return 0;
    }

    /// mem.SlowStoreFn over the Shadow in ctx.space. Checks every byte
    /// before writing any.
    pub fn slowStore(c: *Ctx, va: u64, size_log2: u32, value: u64) callconv(.c) u32 {
        const s: *Shadow = @ptrFromInt(@as(usize, @intCast(c.space)));
        const tlb: *mem.Tlb = @ptrFromInt(@as(usize, @intCast(c.tlb)));
        const n = @as(u32, 1) << @intCast(size_log2);
        var ptrs: [8]*u8 = undefined;
        for (0..n) |i| {
            const a = va +% i;
            switch (s.byte(tlb, a, .write)) {
                .ok => |p| ptrs[i] = p,
                .fault => |k| return fault(c, a, .write, k),
            }
        }
        for (0..n) |i| ptrs[i].* = @truncate(value >> @intCast(8 * i));
        return 0;
    }
};

// ---------------------------------------------------------------- checking

/// How T1 runs the region.
pub const Tier1 = union(enum) {
    /// The reference interpreter.
    ir_eval: *const ir.Region,
    /// Generated code, already loaded.
    entry: ctx_mod.EntryFn,
};

pub const Options = struct {
    /// T1's budget (T0 has none: it follows T1's retired count).
    budget: i64 = std.math.maxInt(i64),
    /// The backend's helper table, for `call.helper`.
    helpers: u64 = 0,
    /// T0 gives up after this many instructions past T1's count.
    max_t0: u64 = 1 << 24,
};

/// How a tier left.
pub const Outcome = struct {
    exit: Exit,
    pc: u64,
    addr: u64 = 0,
    info: u64 = 0,
    retired: u64,

    pub fn format(o: Outcome, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{t} at {x} after {d}", .{ o.exit, o.pc, o.retired });
        if (o.exit == .fault) try w.print(" (addr {x}, info {x})", .{ o.addr, o.info });
    }
};

fn continues(e: Exit) bool {
    return e == .chain or e == .indirect or e == .interrupted;
}

/// One check's state: a Cpu and a shadow per tier. Reusable.
pub const Run = struct {
    gpa: std.mem.Allocator,
    g: *const Guest,
    start: []align(16) u8,
    cpu: [2][]align(16) u8,
    shadow: [2]Shadow,
    tlb: [2]mem.Tlb = .{ .{}, .{} },
    ctx: [2]Ctx = .{ .{}, .{} },
    out: [2]Outcome = undefined,
    /// The report of the last divergence.
    report: std.ArrayList(u8) = .empty,

    pub const t1 = 0;
    pub const t0 = 1;

    pub fn init(gpa: std.mem.Allocator, g: *const Guest, backing: Backing) !*Run {
        const r = try gpa.create(Run);
        errdefer gpa.destroy(r);
        r.* = .{ .gpa = gpa, .g = g, .start = undefined, .cpu = undefined, .shadow = .{ Shadow.init(gpa, backing), Shadow.init(gpa, backing) } };
        r.start = try gpa.alignedAlloc(u8, .@"16", g.cpu_size);
        r.cpu[0] = try gpa.alignedAlloc(u8, .@"16", g.cpu_size);
        r.cpu[1] = try gpa.alignedAlloc(u8, .@"16", g.cpu_size);
        return r;
    }

    pub fn deinit(r: *Run) void {
        r.reset();
        r.shadow[0].deinit();
        r.shadow[1].deinit();
        for ([_][]align(16) u8{ r.start, r.cpu[0], r.cpu[1] }) |b| r.gpa.free(b);
        r.report.deinit(r.gpa);
        r.gpa.destroy(r);
    }

    /// Drops both shadows' copies, for the next check.
    pub fn reset(r: *Run) void {
        for (&r.shadow, 0..) |*s, i| {
            if (r.ctx[i].frontend != 0) if (r.g.unbind) |u| u(r.gpa, &r.ctx[i]);
            r.ctx[i].frontend = 0;
            for (s.pages.values()) |c| s.gpa.destroy(c);
            s.pages.clearRetainingCapacity();
            s.oom = false;
        }
    }

    fn setup(r: *Run, i: usize, o: Options) !void {
        @memcpy(r.cpu[i], r.start);
        r.tlb[i] = .{};
        r.ctx[i] = .{
            .cpu = @intFromPtr(r.cpu[i].ptr),
            .tlb = @intFromPtr(&r.tlb[i]),
            .space = @intFromPtr(&r.shadow[i]),
            .slow_load = @intFromPtr(&Shadow.slowLoad),
            .slow_store = @intFromPtr(&Shadow.slowStore),
            .interp = @intFromPtr(r.g.frontend.interp),
            .helpers = o.helpers,
            .budget = if (i == t1) o.budget else std.math.maxInt(i64),
        };
        if (r.g.bind) |b| try b(r.gpa, &r.ctx[i], &r.shadow[i]);
    }

    fn pcOf(r: *Run, i: usize) *align(1) u64 {
        return @ptrCast(r.cpu[i][r.g.pc_off..][0..8]);
    }

    /// Checks one region from Cpu `start` (the front end's Cpu, as bytes).
    /// Returns true if the tiers agree; otherwise `report` says how they
    /// don't. Either way the tiers' Cpus and shadows are left for the
    /// caller (`cpu[t1]`, `shadow[t1]`, ...).
    pub fn check(r: *Run, tier: Tier1, start: []const u8, o: Options) !bool {
        r.reset();
        r.report.clearRetainingCapacity();
        @memcpy(r.start, start);

        // T1.
        try r.setup(t1, o);
        const c1 = &r.ctx[t1];
        const e1: Exit = switch (tier) {
            .ir_eval => |reg| try ir_eval.run(r.gpa, reg, c1),
            .entry => |f| @enumFromInt(f(c1)),
        };
        r.out[t1] = .{ .exit = e1, .pc = c1.exit_pc, .addr = c1.exit_addr, .info = c1.exit_info, .retired = c1.retired };
        // Generated code leaves the PC in exit_pc, not the Cpu.
        r.pcOf(t1).* = c1.exit_pc;

        // T0, an instruction at a time, to T1's count.
        try r.setup(t0, o);
        const c0 = &r.ctx[t0];
        const want = r.out[t1].retired;
        const loose = e1 == .fault and !r.g.fault_retired_exact;
        if (loose) r.out[t1].retired = 0;
        var n: u64 = 0;
        const out0: Outcome = while (true) {
            if (n == want and continues(e1)) break .{ .exit = e1, .pc = r.pcOf(t0).*, .retired = n };
            if (n > want + o.max_t0) break .{ .exit = .interrupted, .pc = r.pcOf(t0).*, .retired = n };
            const e: Exit = @enumFromInt(r.g.step(c0));
            if (e == .ok) {
                n += 1;
                // Past T1's count with no exit: T1 left early, or T0 is
                // running away; either way they differ.
                if (n > want and !loose) break .{ .exit = .ok, .pc = r.pcOf(t0).*, .retired = n };
                continue;
            }
            if (e == .svc) n += 1;
            break .{ .exit = e, .pc = c0.exit_pc, .addr = c0.exit_addr, .info = c0.exit_info, .retired = n };
        };
        r.out[t0] = out0;
        if (loose) r.out[t0].retired = 0;
        if (!continues(out0.exit) and out0.exit != .ok) r.pcOf(t0).* = out0.pc;

        if (r.shadow[t1].oom or r.shadow[t0].oom) return error.OutOfMemory;
        return r.compare(tier);
    }

    fn compare(r: *Run, tier: Tier1) !bool {
        var aw: std.Io.Writer.Allocating = .fromArrayList(r.gpa, &r.report);
        defer r.report = aw.toArrayList();
        const w = &aw.writer;
        const a = r.out[t1];
        const b = r.out[t0];
        var bad = false;
        if (a.exit != b.exit or a.pc != b.pc or a.retired != b.retired or
            (a.exit == .fault and (a.addr != b.addr or (a.info & r.g.info_mask) != (b.info & r.g.info_mask))))
        {
            try w.print("exit: T1 {f}, T0 {f}\n", .{ a, b });
            bad = true;
        }
        if (r.g.diff(r.cpu[t1].ptr, r.cpu[t0].ptr, w)) bad = true;
        if (try r.compareMemory(w)) bad = true;
        if (bad) {
            try w.print("{s} region at {x}", .{ r.g.frontend.name, std.mem.readInt(u64, r.start[r.g.pc_off..][0..8], .little) });
            switch (tier) {
                .ir_eval => |reg| {
                    try w.writeAll(":\n");
                    ir.print(reg, w) catch {};
                },
                .entry => try w.writeAll(" (generated code)\n"),
            }
        }
        return !bad;
    }

    /// Every page either tier touched must hold the same bytes in both.
    fn compareMemory(r: *Run, w: *std.Io.Writer) !bool {
        var bad = false;
        var shown: u32 = 0;
        for ([_]usize{ t1, t0 }) |i| {
            for (r.shadow[i].pages.keys()) |vp| {
                if (i == t0 and r.shadow[t1].pages.contains(vp)) continue;
                const pa = r.shadow[t1].view(vp) orelse continue;
                const pb = r.shadow[t0].view(vp) orelse continue;
                if (std.mem.eql(u8, pa, pb)) continue;
                bad = true;
                for (pa, pb, 0..) |x, y, off| {
                    if (x == y) continue;
                    if (shown < 16) try w.print("mem {x}: T1 {x:0>2}, T0 {x:0>2}\n", .{ (vp << mem.page_shift) + off, x, y });
                    shown += 1;
                }
            }
        }
        if (shown > 16) try w.print("... and {d} more bytes\n", .{shown - 16});
        return bad;
    }
};

/// Lifts the region at the PC in `start` with the guest's front end, from
/// the backing's code.
pub fn liftAt(gpa: std.mem.Allocator, g: *const Guest, backing: *const Backing, pc: u64, limits: fe.Limits) !ir.Region {
    var reg: ir.Region = .{ .entry_pc = pc };
    errdefer reg.deinit(gpa);
    var b = ir.Builder.init(gpa, &reg);
    try g.frontend.lift(&b, backing.source(), pc, limits);
    if (ir.verify(&reg)) |e| {
        if (builtin.os.tag != .freestanding) std.debug.print("{s}: lifted region at {x} doesn't verify: {s} at %{d}\n", .{ g.frontend.name, pc, e.msg, e.inst });
        return error.Invalid;
    }
    return reg;
}

/// What the runtime calls in check mode (`-Djit-check`) instead of
/// entering a region: both tiers run on shadows; if they agree, T1's
/// memory is committed and its Cpu and exit fields are copied to the
/// real ones, so the guest goes on as if the region had run; if not, it
/// panics with the report. Check mode is single-threaded: the caller holds
/// a lock across `run`, since other vCPUs' stores would race the shadows.
pub const Checker = struct {
    r: *Run,
    backing: Backing,

    pub fn init(gpa: std.mem.Allocator, g: *const Guest, backing: Backing) !Checker {
        return .{ .r = try Run.init(gpa, g, backing), .backing = backing };
    }

    pub fn deinit(c: *Checker) void {
        c.r.deinit();
    }

    pub fn run(c: *Checker, tier: Tier1, real: *Ctx, o: Options) !Exit {
        const r = c.r;
        const cpu: [*]u8 = @ptrFromInt(@as(usize, @intCast(real.cpu)));
        var opts = o;
        opts.budget = real.budget;
        opts.helpers = real.helpers;
        if (!try r.check(tier, cpu[0..r.g.cpu_size], opts)) {
            if (builtin.os.tag != .freestanding) std.debug.print("jit check: T1 and T0 diverge\n{s}\n", .{r.report.items});
            @panic("jit check: T1 and T0 diverge");
        }
        r.shadow[Run.t1].commit();
        @memcpy(cpu[0..r.g.cpu_size], r.cpu[Run.t1]);
        const c1 = &r.ctx[Run.t1];
        real.exit_pc = c1.exit_pc;
        real.exit_addr = c1.exit_addr;
        real.exit_info = c1.exit_info;
        real.retired +%= c1.retired;
        real.budget -%= @bitCast(c1.retired);
        return r.out[Run.t1].exit;
    }
};

// ---------------------------------------------------------------- tests

/// A toy guest for testing the harness itself: a 3-register machine whose
/// instructions are 4 bytes [op, a, b, imm8], with a T0 that uses mem.zig
/// like a real one, and a lifter with a switch to plant bugs.
const toy = struct {
    const Cpu = extern struct { r: [4]u64 = @splat(0), pc: u64 = 0 };
    const Opc = enum(u8) { movi = 1, add = 2, ld = 3, st = 4, bnz = 5, svc = 6, dec = 7 };
    var bug: enum { none, add_is_sub, skip_store, wrong_retire } = .none;

    fn rd(c: *Ctx, va: u64, size_log2: u32) ?u64 {
        const tlb: *mem.Tlb = @ptrFromInt(@as(usize, @intCast(c.tlb)));
        if (mem.fast(tlb, va, @as(u32, 1) << @intCast(size_log2), false)) |h| {
            var v: u64 = 0;
            @memcpy(std.mem.asBytes(&v)[0..(@as(usize, 1) << @intCast(size_log2))], @as([*]const u8, @ptrFromInt(h)));
            return v;
        }
        const slow: mem.SlowLoadFn = @ptrFromInt(@as(usize, @intCast(c.slow_load)));
        if (slow(c, va, size_log2) != 0) return null;
        return c.scratch;
    }

    fn step(c: *Ctx) u32 {
        const cpu = c.cpuPtr(Cpu);
        const pc = cpu.pc;
        const s: *Shadow = @ptrFromInt(@as(usize, @intCast(c.space)));
        const pg = s.get(pc >> 12) orelse {
            c.exit_pc = pc;
            c.exit_addr = pc;
            c.exit_info = 2;
            return @intFromEnum(Exit.fault);
        };
        const i = pg.data[@intCast(pc & 0xfff)..][0..4];
        const a = i[1] & 3;
        const b = i[2] & 3;
        switch (@as(Opc, @enumFromInt(i[0]))) {
            .movi => cpu.r[a] = i[3],
            .add => cpu.r[a] +%= cpu.r[b],
            .dec => cpu.r[a] -%= 1,
            .ld => cpu.r[a] = rd(c, cpu.r[b], 3) orelse {
                c.exit_pc = pc;
                return @intFromEnum(Exit.fault);
            },
            .st => {
                const slow: mem.SlowStoreFn = @ptrFromInt(@as(usize, @intCast(c.slow_store)));
                if (slow(c, cpu.r[b], 3, cpu.r[a]) != 0) {
                    c.exit_pc = pc;
                    return @intFromEnum(Exit.fault);
                }
            },
            .bnz => if (cpu.r[a] != 0) {
                cpu.pc = pc +% @as(u64, @bitCast(@as(i64, @as(i8, @bitCast(i[3]))) * 4));
                return 0;
            },
            .svc => {
                cpu.pc = pc + 4;
                c.exit_pc = pc + 4;
                return @intFromEnum(Exit.svc);
            },
        }
        cpu.pc = pc + 4;
        return 0;
    }

    fn interp(c: *Ctx, _: u64, _: u64) callconv(.c) u32 {
        return step(c);
    }

    fn off(n: u8) u64 {
        return @offsetOf(Cpu, "r") + @as(u64, n & 3) * 8;
    }

    /// One block per instruction, straight-line, with bnz as a two-way
    /// exit and svc ending the region.
    fn lift(b: *ir.Builder, src: fe.Source, pc: u64, limits: fe.Limits) fe.LiftError!void {
        var p = pc;
        var n: u32 = 0;
        var done: u32 = 0; // retired so far: exact before anything that can fault
        _ = try b.block();
        b.begin(0);
        try b.poll(pc);
        while (n < limits.max_insns) : (n += 1) {
            var i: [4]u8 = undefined;
            if (src.readAll(p, &i) != 4) break;
            const a = i[1];
            switch (@as(Opc, @enumFromInt(i[0]))) {
                .movi => try b.setreg(off(a), try b.konst(.i64, i[3])),
                .add => {
                    const x = try b.getreg(.i64, off(a));
                    const y = try b.getreg(.i64, off(i[2]));
                    try b.setreg(off(a), try b.bin(if (bug == .add_is_sub) .sub else .add, .i64, x, y));
                },
                .dec => try b.setreg(off(a), try b.bin(.sub, .i64, try b.getreg(.i64, off(a)), try b.konst(.i64, 1))),
                .ld => {
                    try b.retire(n - done);
                    done = n;
                    try b.setreg(off(a), try b.load(.i64, try b.getreg(.i64, off(i[2])), .{ .size = 3 }, p));
                },
                .st => if (bug != .skip_store) {
                    try b.retire(n - done);
                    done = n;
                    try b.store(try b.getreg(.i64, off(i[2])), try b.getreg(.i64, off(a)), .{ .size = 3 }, p);
                },
                .bnz => {
                    try b.retire(n + 1 - done);
                    const c = try b.icmp(.ne, try b.getreg(.i64, off(a)), try b.konst(.i64, 0));
                    const t = try b.block();
                    const f = try b.block();
                    try b.brcond(c, t, f);
                    b.begin(t);
                    try b.exit(.@"exit.chain", p +% @as(u64, @bitCast(@as(i64, @as(i8, @bitCast(i[3]))) * 4)));
                    b.begin(f);
                    try b.exit(.@"exit.chain", p + 4);
                    return;
                },
                .svc => {
                    try b.retire(n + 1 - done + @intFromBool(bug == .wrong_retire));
                    try b.exit(.@"exit.svc", p + 4);
                    return;
                },
            }
            p += 4;
        }
        try b.retire(if (bug == .wrong_retire) n + 1 - done else n - done);
        try b.exit(.@"exit.chain", p);
    }

    fn diff(pa: *const anyopaque, pb: *const anyopaque, w: *std.Io.Writer) bool {
        const a: *const Cpu = @ptrCast(@alignCast(pa));
        const b: *const Cpu = @ptrCast(@alignCast(pb));
        var bad = false;
        for (a.r, b.r, 0..) |x, y, i| if (x != y) {
            w.print("r{d}: T1 {x}, T0 {x}\n", .{ i, x, y }) catch {};
            bad = true;
        };
        if (a.pc != b.pc) {
            w.print("pc: T1 {x}, T0 {x}\n", .{ a.pc, b.pc }) catch {};
            bad = true;
        }
        return bad;
    }

    const guest: Guest = .{
        .frontend = .{ .name = "toy", .flags = .nzcv, .lift = lift, .interp = interp },
        .cpu_size = @sizeOf(Cpu),
        .pc_off = @offsetOf(Cpu, "pc"),
        .step = step,
        .diff = diff,
    };
};

fn toyProgram(code: []u8, insns: []const [4]u8) void {
    @memset(code, 0);
    for (insns, 0..) |i, n| @memcpy(code[n * 4 ..][0..4], &i);
}

test "check: the tiers agree on a toy region, and planted bugs are caught" {
    const gpa = std.testing.allocator;
    var code: [page_size]u8 align(page_size) = undefined;
    var data: [page_size]u8 align(page_size) = @splat(0);
    toyProgram(&code, &.{
        .{ 1, 0, 0, 0x10 }, // movi r0, 0x10   (data at 0x10000 via r1)
        .{ 1, 2, 0, 7 }, // movi r2, 7
        .{ 2, 0, 2, 0 }, // add r0, r2
        .{ 4, 0, 1, 0 }, // st r0, [r1]
        .{ 3, 3, 1, 0 }, // ld r3, [r1]
        .{ 6, 0, 0, 0 }, // svc
    });
    const regions = [_]mem.Region{
        .{ .va = 0x1000, .mem = &code, .exec = true },
        .{ .va = 0x10000, .mem = &data, .write = true },
    };
    const map: mem.Map = .{ .regions = &regions };
    var backing = mapBacking(&map);
    const r = try Run.init(gpa, &toy.guest, backing);
    defer r.deinit();
    const start: toy.Cpu = .{ .r = .{ 0, 0x10000, 0, 0 }, .pc = 0x1000 };

    for ([_]@TypeOf(toy.bug){ .none, .add_is_sub, .skip_store, .wrong_retire }) |bug| {
        toy.bug = bug;
        defer toy.bug = .none;
        var reg = try liftAt(gpa, &toy.guest, &backing, 0x1000, .{});
        defer reg.deinit(gpa);
        const ok = try r.check(.{ .ir_eval = &reg }, std.mem.asBytes(&start), .{});
        try std.testing.expectEqual(bug == .none, ok);
    }
    // Nothing reached the real memory.
    try std.testing.expectEqual(@as(u8, 0), data[0]);

    // A fault: the store's address is unmapped. Both stop at it, unretired.
    var reg = try liftAt(gpa, &toy.guest, &backing, 0x1000, .{});
    defer reg.deinit(gpa);
    var bad = start;
    bad.r[1] = 0x50000;
    try std.testing.expect(try r.check(.{ .ir_eval = &reg }, std.mem.asBytes(&bad), .{}));
    try std.testing.expectEqual(Exit.fault, r.out[Run.t1].exit);
    try std.testing.expectEqual(@as(u64, 0x100c), r.out[Run.t1].pc);
    try std.testing.expectEqual(@as(u64, 3), r.out[Run.t1].retired);
}

test "check: a budget stop and a loop exit line up with T0's count" {
    const gpa = std.testing.allocator;
    var code: [page_size]u8 align(page_size) = undefined;
    toyProgram(&code, &.{
        .{ 1, 0, 0, 5 }, // movi r0, 5
        .{ 7, 0, 0, 0 }, // loop: dec r0
        .{ 5, 0, 0, 0xff }, // bnz r0, loop
        .{ 6, 0, 0, 0 },
    });
    const regions = [_]mem.Region{.{ .va = 0x1000, .mem = &code, .exec = true }};
    const map: mem.Map = .{ .regions = &regions };
    var backing = mapBacking(&map);
    const r = try Run.init(gpa, &toy.guest, backing);
    defer r.deinit();
    var reg = try liftAt(gpa, &toy.guest, &backing, 0x1000, .{});
    defer reg.deinit(gpa);
    const start: toy.Cpu = .{ .pc = 0x1000 };
    try std.testing.expect(try r.check(.{ .ir_eval = &reg }, std.mem.asBytes(&start), .{}));
    try std.testing.expectEqual(Exit.chain, r.out[Run.t1].exit);
    try std.testing.expectEqual(@as(u64, 0x1004), r.out[Run.t1].pc);
    // A spent budget stops at the entry poll, with nothing retired.
    try std.testing.expect(try r.check(.{ .ir_eval = &reg }, std.mem.asBytes(&start), .{ .budget = 0 }));
    try std.testing.expectEqual(Exit.interrupted, r.out[Run.t1].exit);
    try std.testing.expectEqual(@as(u64, 0), r.out[Run.t0].retired);
}

test "check: Checker commits the agreed memory and Cpu" {
    const gpa = std.testing.allocator;
    var code: [page_size]u8 align(page_size) = undefined;
    var data: [page_size]u8 align(page_size) = @splat(0);
    toyProgram(&code, &.{
        .{ 1, 0, 0, 0x2a }, // movi r0, 42
        .{ 4, 0, 1, 0 }, // st r0, [r1]
        .{ 6, 0, 0, 0 },
    });
    const regions = [_]mem.Region{
        .{ .va = 0x1000, .mem = &code, .exec = true },
        .{ .va = 0x10000, .mem = &data, .write = true },
    };
    const map: mem.Map = .{ .regions = &regions };
    var backing = mapBacking(&map);
    var ck = try Checker.init(gpa, &toy.guest, backing);
    defer ck.deinit();
    var reg = try liftAt(gpa, &toy.guest, &backing, 0x1000, .{});
    defer reg.deinit(gpa);
    var cpu: toy.Cpu = .{ .r = .{ 0, 0x10000, 0, 0 }, .pc = 0x1000 };
    var real: Ctx = .{ .cpu = @intFromPtr(&cpu) };
    try std.testing.expectEqual(Exit.svc, try ck.run(.{ .ir_eval = &reg }, &real, .{}));
    try std.testing.expectEqual(@as(u8, 42), data[0]);
    try std.testing.expectEqual(@as(u64, 42), cpu.r[0]);
    try std.testing.expectEqual(@as(u64, 0x100c), real.exit_pc);
    try std.testing.expectEqual(@as(u64, 3), real.retired);
}
