//! fuzz-a64's checks on one program, without Unicorn: T1 against T0 a
//! region at a time (check.zig), from the entry to the SVC. The driver
//! (tests/jit/fuzz_a64.zig) adds lockstep against Unicorn when it's built
//! with -Demu=unicorn.

const std = @import("std");
const check = @import("../check.zig");
const a64 = @import("a64.zig");
const gen = @import("gen_a64.zig");
const mem = @import("../../interp/mem.zig");
const ctx_mod = @import("../ctx.zig");

pub const page_size = mem.page_size;

/// A program's address space: a code page and a data page.
pub const Space = struct {
    code: [page_size]u8 align(page_size) = @splat(0),
    data: [page_size]u8 align(page_size) = @splat(0),
    regions: [2]mem.Region = undefined,
    map: mem.Map = undefined,

    pub fn load(s: *Space, words: []const u32, data_seed: u64) void {
        s.code = @splat(0);
        for (words, 0..) |w, i| std.mem.writeInt(u32, s.code[i * 4 ..][0..4], w, .little);
        var prng = std.Random.DefaultPrng.init(data_seed);
        prng.random().bytes(&s.data);
        s.regions = .{
            .{ .va = gen.code_va, .mem = &s.code, .exec = true },
            .{ .va = gen.data_va, .mem = &s.data, .write = true },
        };
        s.map = .{ .regions = &s.regions };
    }

    pub fn cpu(_: *Space, r: std.Random) a64.Cpu {
        const regs = gen.registers(r);
        var c: a64.Cpu = .{ .pc = gen.code_va, .nzcv = regs.nzcv };
        @memcpy(c.r[0..31], &regs.x);
        c.r[a64.t0.dec.SP] = gen.data_va + page_size; // SP: unused, but valid
        return c;
    }
};

pub const Outcome = struct {
    /// Regions checked, and the guest instructions they retired.
    regions: u32 = 0,
    retired: u64 = 0,
    /// How the last region left.
    exit: ctx_mod.Exit = .ok,
    /// False on a divergence: the Run's report says what.
    ok: bool = true,
};

/// Checks a region at a time from `start` until a region leaves other
/// than to the next PC, committing each agreed region's memory to the
/// space. `r` holds the report of a divergence.
pub fn checkRegions(gpa: std.mem.Allocator, r: *check.Run, s: *Space, start: a64.Cpu, max_regions: u32) !Outcome {
    var out: Outcome = .{};
    var cpu = start;
    var backing = check.mapBacking(&s.map);
    while (out.regions < max_regions) {
        var reg = try check.liftAt(gpa, &a64.guest, &backing, cpu.pc, .{});
        defer reg.deinit(gpa);
        if (!try r.check(.{ .ir_eval = &reg }, std.mem.asBytes(&cpu), .{})) {
            out.ok = false;
            return out;
        }
        out.regions += 1;
        out.retired += r.out[check.Run.t1].retired;
        out.exit = r.out[check.Run.t1].exit;
        r.shadow[check.Run.t1].commit();
        cpu = std.mem.bytesToValue(a64.Cpu, r.cpu[check.Run.t1]);
        // An unlifted branch or call ends a region before it with nothing
        // retired; step it on T0 so the next region starts past it.
        if (r.out[check.Run.t1].retired == 0 and out.exit == .chain) {
            if (try stepT0(gpa, s, &cpu)) |e| {
                out.exit = e;
                return out;
            }
            out.retired += 1;
        }
        if (out.exit != .chain and out.exit != .indirect) return out;
    }
    return out;
}

/// One T0 instruction on the space's own memory; an exit, or null.
fn stepT0(gpa: std.mem.Allocator, s: *Space, cpu: *a64.Cpu) !?ctx_mod.Exit {
    var tlb: mem.Tlb = .{};
    var c: ctx_mod.Ctx = .{ .cpu = @intFromPtr(cpu), .tlb = @intFromPtr(&tlb) };
    const b = try a64.Bound.init(gpa, &c, a64.t0.mapSpace(&s.map));
    defer b.deinit(gpa);
    const e: ctx_mod.Exit = @enumFromInt(a64.step(&c));
    return if (e == .ok) null else e;
}

test "fuzz-a64: random programs agree region by region" {
    const gpa = std.testing.allocator;
    const s = try gpa.create(Space);
    defer gpa.destroy(s);
    s.load(&.{}, 0);
    const r = try check.Run.init(gpa, &a64.guest, check.mapBacking(&s.map));
    defer r.deinit();
    var prng = std.Random.DefaultPrng.init(0x5eed);
    var buf: [65]u32 = undefined;
    for (0..200) |i| {
        const words = gen.program(prng.random(), .{ .len = 48 }, &buf);
        s.load(words, i);
        const out = try checkRegions(gpa, r, s, s.cpu(prng.random()), 64);
        if (!out.ok) {
            std.debug.print("program {d} diverges:\n{s}\n", .{ i, r.report.items });
            return error.Diverged;
        }
    }
}
