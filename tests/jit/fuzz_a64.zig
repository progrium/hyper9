//! zig build fuzz-a64 [-- options]: random arm64 programs (src/jit/check/
//! gen_a64.zig), each checked T1 against T0 a region at a time and, when
//! built with -Demu=unicorn, T0 against Unicorn an instruction at a time.
//!
//! Options: see fuzz_common.zig (`--without` takes gen_a64.Class names).
//!
//! A divergence prints the seed, the program, and the report; rerun one
//! with --seed S --iters 1.

const std = @import("std");
const options = @import("fuzz_options");
const vcpu = @import("vcpu");
const check = vcpu.check;
const gen = check.gen_a64;
const fuzz = check.fuzz_a64;
const a64 = check.a64;
const lockstep = if (options.unicorn) @import("lockstep") else struct {};

const common = @import("fuzz_common.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = try common.Args(gen.Class).parse("fuzz-a64", init);
    if (!options.unicorn and args.lockstep) args.lockstep = false;
    std.debug.print("fuzz-a64: seed {d}, {d} programs of {d}; region check {s}, lockstep {s}\n", .{ args.seed, args.iters, args.len, if (args.check) "on" else "off", if (args.lockstep) "on" else if (options.unicorn) "off" else "off (needs -Demu=unicorn)" });

    const s = try gpa.create(fuzz.Space);
    defer gpa.destroy(s);
    s.load(&.{}, 0);
    const run = try check.Run.init(gpa, &a64.guest, check.mapBacking(&s.map));
    defer run.deinit();

    var native: ?vcpu.emit.native.Native = if (args.native) vcpu.emit.native.Native.init() catch |e| {
        std.debug.print("--native: no {s} emitter here ({t})\n", .{ vcpu.emit.native.name, e });
        std.process.exit(2);
    } else null;
    defer if (native) |*n| n.deinit();
    var tally: common.Tally = .{};
    defer tally.deinit(gpa);
    var report: std.Io.Writer.Allocating = .init(gpa);
    defer report.deinit();
    var buf: [1025]u32 = undefined;
    var failed: u64 = 0;
    var retired: u64 = 0;
    var i: u64 = 0;
    while (i < args.iters) : (i += 1) {
        const seed = args.seed +% i;
        var prng = std.Random.DefaultPrng.init(seed);
        const words = gen.program(prng.random(), .{ .len = @min(args.len, 1024), .classes = args.classes() }, &buf);
        if (args.trace) {
            std.debug.print("seed {d}:", .{seed});
            for (words) |w| std.debug.print(" {x:0>8}", .{w});
            std.debug.print("\n", .{});
        }
        const start = s.cpu(prng.random());
        report.clearRetainingCapacity();
        var bad = false;
        if (args.check) {
            s.load(words, seed);
            const out = fuzz.checkRegions(gpa, run, s, start, 4096, if (native) |*n| n else null) catch |e| blk: {
                try report.writer.print("region check: {t}\n", .{e});
                break :blk fuzz.Outcome{ .ok = false };
            };
            retired += out.retired;
            if (!out.ok) {
                bad = true;
                try report.writer.print("region check:\n{s}", .{run.report.items});
            }
        }
        if (args.lockstep and !bad) {
            s.load(words, seed);
            if (try lockstepProgram(gpa, s, start, &report.writer)) bad = true;
        }
        if (!bad) continue;
        failed += 1;
        if (args.keep_going) {
            try tally.add(gpa, report.written());
            continue;
        }
        std.debug.print("seed {d}: program:\n", .{seed});
        for (words, 0..) |w, n| std.debug.print("  {x:0>4}: {x:0>8}\n", .{ gen.code_va + 4 * n, w });
        std.debug.print("{s}\n", .{report.written()});
        std.process.exit(1);
    }
    std.debug.print("fuzz-a64: {d} programs, {d} diverged; {d} instructions region-checked\n", .{ args.iters, failed, retired });
    if (native) |n| std.debug.print("  {s} code: {d} regions run natively, {d} the emitter declined\n", .{ vcpu.emit.native.name, n.compiled, n.unsupported });
    tally.print();
    if (failed != 0) std.process.exit(1);
}

/// T0 against Unicorn, an instruction at a time, to the SVC. Returns
/// whether they diverged (and writes how to `w`).
fn lockstepProgram(gpa: std.mem.Allocator, s: *fuzz.Space, start: a64.Cpu, w: *std.Io.Writer) !bool {
    if (options.unicorn) return lockstepUnicorn(gpa, s, start, w);
    return false;
}

fn lockstepUnicorn(gpa: std.mem.Allocator, s: *fuzz.Space, start: a64.Cpu, w: *std.Io.Writer) !bool {
    const E = lockstep.Engine(.arm64);
    const e = try E.init(gpa, &.{
        .{ .va = gen.code_va, .mem = &s.code, .exec = true },
        .{ .va = gen.data_va, .mem = &s.data, .write = true },
    });
    defer e.deinit();
    var cpu = start;
    try e.setState(canon(&cpu));
    var tlb: vcpu.mem.Tlb = .{};
    var c: vcpu.ctx.Ctx = .{ .cpu = @intFromPtr(&cpu), .tlb = @intFromPtr(&tlb) };
    const bound = try a64.Bound.init(gpa, &c, a64.t0.mapSpace(&s.map));
    defer bound.deinit(gpa);
    var n: u64 = 0;
    while (n < 1 << 16) : (n += 1) {
        const pc = cpu.pc;
        const word = std.mem.readInt(u32, s.code[@intCast(pc - gen.code_va)..][0..4], .little);
        const e0: vcpu.ctx.Exit = @enumFromInt(a64.step(&c));
        const e1 = try e.step();
        const same_exit = switch (e1) {
            .next => e0 == .ok,
            .syscall => e0 == .svc,
            .breakpoint => e0 == .brk,
            .undef => e0 == .undef,
            .fault => |f| e0 == .fault and f.addr == c.exit_addr,
            .exception => false,
        };
        var bad = !same_exit;
        if (!same_exit) try w.print("exit at {x} ({x:0>8}): T0 {t}, unicorn {any}\n", .{ pc, word, e0, e1 });
        if (lockstep.diff(.arm64, canon(&cpu), e.getState(), 0, w)) bad = true;
        if (e.diffMemory(w)) bad = true;
        if (bad) {
            if (same_exit) try w.print("after {x} ({x:0>8})\n", .{ pc, word });
            return true;
        }
        if (e0 != .ok) return false;
    }
    return false;
}

fn canon(c: *const a64.Cpu) lockstep.A64 {
    var st: lockstep.A64 = .{ .sp = c.r[a64.t0.dec.SP], .pc = c.pc, .nzcv = c.nzcv, .v = c.v, .fpcr = c.fpcr, .fpsr = c.fpsr, .tpidr = c.tpidr };
    @memcpy(&st.x, c.r[0..31]);
    return st;
}
