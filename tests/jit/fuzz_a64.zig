//! zig build fuzz-a64 [-- options]: random arm64 programs (src/jit/check/
//! gen_a64.zig), each checked T1 against T0 a region at a time and, when
//! built with -Demu=unicorn, T0 against Unicorn an instruction at a time.
//!
//!   --seed N       first seed (default: from the clock); program i uses seed+i
//!   --iters N      programs to run (default 1000)
//!   --len N        instructions per program (default 32)
//!   --no-check     skip the region check
//!   --no-lockstep  skip lockstep
//!   --keep-going   count divergences by their first lines instead of stopping
//!   --trace        print each seed and program before running it
//!   --without C,.. leave out instruction classes (gen_a64.Class: branch, exclusive, ...)
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

const Args = struct {
    seed: u64,
    iters: u64 = 1000,
    len: u32 = 32,
    check: bool = true,
    lockstep: bool = options.unicorn,
    keep_going: bool = false,
    /// Print each seed before running it (to find one that crashes).
    trace: bool = false,
    without: std.EnumSet(gen.Class) = .initEmpty(),
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args: Args = .{ .seed = @truncate(@as(u128, @bitCast(@as(i128, std.Io.Timestamp.now(init.io, .real).nanoseconds)))) };
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    var i_arg: usize = 1;
    while (i_arg < argv.len) : (i_arg += 1) {
        const a = argv[i_arg];
        const next = if (i_arg + 1 < argv.len) argv[i_arg + 1] else "";
        if (std.mem.eql(u8, a, "--seed")) {
            args.seed = try std.fmt.parseInt(u64, next, 0);
            i_arg += 1;
        } else if (std.mem.eql(u8, a, "--iters")) {
            args.iters = try std.fmt.parseInt(u64, next, 0);
            i_arg += 1;
        } else if (std.mem.eql(u8, a, "--len")) {
            args.len = try std.fmt.parseInt(u32, next, 0);
            i_arg += 1;
        } else if (std.mem.eql(u8, a, "--no-check")) {
            args.check = false;
        } else if (std.mem.eql(u8, a, "--no-lockstep")) {
            args.lockstep = false;
        } else if (std.mem.eql(u8, a, "--keep-going")) {
            args.keep_going = true;
        } else if (std.mem.eql(u8, a, "--without")) {
            var it = std.mem.tokenizeScalar(u8, next, ',');
            while (it.next()) |name| {
                const c = std.meta.stringToEnum(gen.Class, name) orelse {
                    std.debug.print("fuzz-a64: no class {s}\n", .{name});
                    return error.Usage;
                };
                args.without.insert(c);
            }
            i_arg += 1;
        } else if (std.mem.eql(u8, a, "--trace")) {
            args.trace = true;
        } else {
            std.debug.print("fuzz-a64: unknown option {s}\n", .{a});
            return error.Usage;
        }
    }
    if (!options.unicorn and args.lockstep) args.lockstep = false;
    std.debug.print("fuzz-a64: seed {d}, {d} programs of {d}; region check {s}, lockstep {s}\n", .{ args.seed, args.iters, args.len, if (args.check) "on" else "off", if (args.lockstep) "on" else if (options.unicorn) "off" else "off (needs -Demu=unicorn)" });

    const s = try gpa.create(fuzz.Space);
    defer gpa.destroy(s);
    s.load(&.{}, 0);
    const run = try check.Run.init(gpa, &a64.guest, check.mapBacking(&s.map));
    defer run.deinit();

    var tally: std.StringArrayHashMapUnmanaged(u64) = .empty;
    defer {
        for (tally.keys()) |k| gpa.free(k);
        tally.deinit(gpa);
    }
    var report: std.Io.Writer.Allocating = .init(gpa);
    defer report.deinit();
    var buf: [1025]u32 = undefined;
    var classes_buf: [std.enums.values(gen.Class).len]gen.Class = undefined;
    var nclasses: usize = 0;
    for (std.enums.values(gen.Class)) |c| if (!args.without.contains(c)) {
        classes_buf[nclasses] = c;
        nclasses += 1;
    };
    if (nclasses == 0) return error.Usage;
    var failed: u64 = 0;
    var retired: u64 = 0;
    var i: u64 = 0;
    while (i < args.iters) : (i += 1) {
        const seed = args.seed +% i;
        var prng = std.Random.DefaultPrng.init(seed);
        const words = gen.program(prng.random(), .{ .len = @min(args.len, 1024), .classes = classes_buf[0..nclasses] }, &buf);
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
            const out = fuzz.checkRegions(gpa, run, s, start, 4096) catch |e| blk: {
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
            // Tally by what differs (the field names), not by the values.
            const key = try tallyKey(gpa, report.written());
            const g = try tally.getOrPut(gpa, key);
            if (g.found_existing) {
                gpa.free(key);
                g.value_ptr.* += 1;
            } else g.value_ptr.* = 1;
            continue;
        }
        std.debug.print("seed {d}: program:\n", .{seed});
        for (words, 0..) |w, n| std.debug.print("  {x:0>4}: {x:0>8}\n", .{ gen.code_va + 4 * n, w });
        std.debug.print("{s}\n", .{report.written()});
        std.process.exit(1);
    }
    std.debug.print("fuzz-a64: {d} programs, {d} diverged; {d} instructions region-checked\n", .{ args.iters, failed, retired });
    for (tally.keys(), tally.values()) |k, v| std.debug.print("  {d:>6}  {s}\n", .{ v, k });
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

/// "region check: x3 nzcv" from a report: each line's text up to its colon.
fn tallyKey(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.mem.startsWith(u8, line, "ha64 region")) break;
        if (n > 0) try out.append(gpa, ' ');
        try out.appendSlice(gpa, line[0..colon]);
        n += 1;
        if (n == 6) break;
    }
    return out.toOwnedSlice(gpa);
}
