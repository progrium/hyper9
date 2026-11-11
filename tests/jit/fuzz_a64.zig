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
const hcpu = @import("hcpu");
const check = hcpu.check;
const gen = check.gen_a64;
const fuzz = check.fuzz_a64;
const a64 = check.a64;
const lockstep = if (options.unicorn) @import("lockstep") else struct {};

const common = @import("fuzz_common.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = try common.Args(gen.Class).parse("fuzz-a64", init);
    if (!options.unicorn and args.lockstep) args.lockstep = false;
    // Check FP and SIMD lifting whatever this host's emitter takes.
    hcpu.a64.lift_simd.enabled = true;
    // H9_FUZZ_COPY=1: copy register-only instructions (copy.zig), checked
    // on ir_eval and, with --native, by the arm64 emitter's lowering.
    if (init.environ_map.get("H9_FUZZ_COPY")) |v| hcpu.a64.copy.enabled = v.len > 0 and v[0] == '1';
    std.debug.print("fuzz-a64: seed {d}, {d} programs of {d}; region check {s}, lockstep {s}\n", .{ args.seed, args.iters, args.len, if (args.check) "on" else "off", if (args.lockstep) "on" else if (options.unicorn) "off" else "off (needs -Demu=unicorn)" });

    const s = try gpa.create(fuzz.Space);
    defer gpa.destroy(s);
    s.load(&.{}, 0);
    const run = try check.Run.init(gpa, &a64.guest, check.mapBacking(&s.map));
    defer run.deinit();

    var native: ?hcpu.emit.native.Native = if (args.native) hcpu.emit.native.Native.init() catch |e| {
        std.debug.print("--native: no {s} emitter here ({t})\n", .{ hcpu.emit.native.name, e });
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
    var known: KnownCounts = .initFill(0);
    var i: u64 = 0;
    while (args.more(i, init.io)) : (i += 1) {
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
            switch (try lockstepProgram(gpa, s, start, &report.writer)) {
                .agree => {},
                .diverged => bad = true,
                .known => |k| known.getPtr(k).* += 1,
            }
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
    std.debug.print("fuzz-a64: {d} programs, {d} diverged; {d} instructions region-checked\n", .{ i, failed, retired });
    if (native) |n| {
        std.debug.print("  {s} code: {d} regions run natively, {d} the emitter declined\n", .{ hcpu.emit.native.name, n.compiled, n.unsupported });
        hcpu.emit.native.printFallbacks();
    }
    tally.print();
    if (options.unicorn) for (std.enums.values(lockstep.Known)) |k| if (known.get(k) != 0)
        std.debug.print("  known divergence {t}: {d} (T0 is architectural)\n", .{ k, known.get(k) });
    if (failed != 0) std.process.exit(1);
}

const NoKnown = enum { none };
const KnownCounts = if (options.unicorn) std.EnumArray(lockstep.Known, u64) else std.EnumArray(NoKnown, u64);
const Lockstep = union(enum) { agree, diverged, known: if (options.unicorn) lockstep.Known else NoKnown };

/// T0 against Unicorn, an instruction at a time, to the SVC. Writes how
/// they diverged to `w`.
fn lockstepProgram(gpa: std.mem.Allocator, s: *fuzz.Space, start: a64.Cpu, w: *std.Io.Writer) !Lockstep {
    if (options.unicorn) return lockstepUnicorn(gpa, s, start, w);
    return .agree;
}

fn lockstepUnicorn(gpa: std.mem.Allocator, s: *fuzz.Space, start: a64.Cpu, w: *std.Io.Writer) !Lockstep {
    const E = lockstep.Engine(.arm64);
    const e = try E.init(gpa, &.{
        .{ .va = gen.code_va, .mem = &s.code, .exec = true },
        .{ .va = gen.data_va, .mem = &s.data, .write = true },
    });
    defer e.deinit();
    var cpu = start;
    try e.setState(canon(&cpu));
    var tlb: hcpu.mem.Tlb = .{};
    var c: hcpu.ctx.Ctx = .{ .cpu = @intFromPtr(&cpu), .tlb = @intFromPtr(&tlb) };
    const bound = try a64.Bound.init(gpa, &c, a64.t0.mapSpace(&s.map));
    defer bound.deinit(gpa);
    // The size of the last load exclusive, for knownA64Exclusive.
    var load_bytes: u8 = 0;
    var n: u64 = 0;
    while (n < 1 << 16) : (n += 1) {
        const pc = cpu.pc;
        const word = std.mem.readInt(u32, s.code[@intCast(pc - gen.code_va)..][0..4], .little);
        const e0: hcpu.ctx.Exit = @enumFromInt(a64.step(&c));
        const e1 = try e.step();
        const alignment = e0 == .fault and (c.exit_info >> 8) & 0xff == @intFromEnum(hcpu.mem.FaultKind.alignment);
        if (lockstep.knownA64(word, alignment, e1)) |k| return .{ .known = k };
        const same_exit = switch (e1) {
            .next => e0 == .ok,
            .syscall => e0 == .svc,
            .breakpoint => e0 == .brk,
            .undef => e0 == .undef,
            .fault => |f| e0 == .fault and f.addr == c.exit_addr,
            // QEMU raises some data aborts (a misaligned LDXR) itself,
            // without the address.
            .exception => |v| v == 4 and e0 == .fault,
        };
        var bad = !same_exit;
        if (!same_exit) try w.print("exit: at {x} ({x:0>8}) T0 {t} (addr {x}, info {x}), unicorn {any}\n", .{ pc, word, e0, c.exit_addr, c.exit_info, e1 });
        const regs_bad = lockstep.diff(.arm64, canon(&cpu), e.getState(), 0, w);
        if (regs_bad) bad = true;
        const mem_bad = e.diffMemory(w);
        if (mem_bad) bad = true;
        // A store faulting on its second page, which Unicorn has partly
        // written: only the 16 bytes below the page boundary differ.
        if (same_exit and e0 == .fault and !regs_bad and mem_bad and c.exit_addr % 4096 == 0 and
            e.memDiffsWithin(c.exit_addr - 16, c.exit_addr)) return .{ .known = .partial_page_cross_store };
        if (bad) {
            if (same_exit) if (lockstep.knownA64Result(word)) |k| return .{ .known = k };
            if (same_exit) if (lockstep.knownA64Exclusive(word, load_bytes)) |k| return .{ .known = k };
            if (same_exit) try w.print("after {x} ({x:0>8})\n", .{ pc, word });
            return .diverged;
        }
        if (lockstep.exclusiveA64(word)) |x| if (x.load) {
            load_bytes = x.bytes;
        };
        if (e0 != .ok) return .agree;
    }
    return .agree;
}

fn canon(c: *const a64.Cpu) lockstep.A64 {
    var st: lockstep.A64 = .{ .sp = c.r[a64.t0.dec.SP], .pc = c.pc, .nzcv = c.nzcv, .v = c.v, .fpcr = c.fpcr, .fpsr = c.fpsr, .tpidr = c.tpidr };
    @memcpy(&st.x, c.r[0..31]);
    return st;
}
