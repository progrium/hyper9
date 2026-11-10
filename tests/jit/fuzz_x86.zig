//! zig build fuzz-x86 [-- options]: random 386 programs (src/jit/check/
//! gen_x86.zig) run on h86's T0 and, with -Demu=unicorn, checked against
//! Unicorn an instruction at a time: registers, EIP, the EFLAGS bits the
//! instruction defines, memory, and the exit; and, region by region, the
//! lifter in ir_eval against T0 (check.zig's region check).
//!
//! Options: see fuzz_common.zig (`--without` takes gen_x86.Class names).
//! A divergence prints the seed, the program, and the report; rerun one
//! with --seed S --iters 1.

const std = @import("std");
const options = @import("fuzz_options");
const vcpu = @import("vcpu");
const check = vcpu.check;
const gen = check.gen_x86;
const x86 = check.x86;
const mem = vcpu.mem;
const common = @import("fuzz_common.zig");
const lockstep = if (options.unicorn) @import("lockstep") else struct {};

const page_size = mem.page_size;

const Space = struct {
    code: [page_size]u8 align(page_size) = @splat(0),
    data: [page_size]u8 align(page_size) = @splat(0),
    stack: [page_size]u8 align(page_size) = @splat(0),
    regions: [3]mem.Region = undefined,
    map: mem.Map = undefined,

    fn load(s: *Space, code: []const u8, seed: u64) void {
        s.code = @splat(0xCC); // int3 past the end
        @memcpy(s.code[0..code.len], code);
        var prng = std.Random.DefaultPrng.init(seed);
        prng.random().bytes(&s.data);
        prng.random().bytes(&s.stack);
        s.regions = .{
            .{ .va = gen.code_va, .mem = &s.code, .exec = true },
            .{ .va = gen.data_va, .mem = &s.data, .write = true },
            .{ .va = gen.stack_va, .mem = &s.stack, .write = true },
        };
        s.map = .{ .regions = &s.regions };
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args = try common.Args(gen.Class).parse("fuzz-x86", init);
    if (!options.unicorn) args.lockstep = false;
    std.debug.print("fuzz-x86: seed {d}, {d} programs of {d}; region check {s}, lockstep {s}\n", .{ args.seed, args.iters, args.len, if (args.check) "on" else "off", if (args.lockstep) "on" else if (options.unicorn) "off" else "off (needs -Demu=unicorn)" });
    if (!args.lockstep and !args.check) {
        std.debug.print("fuzz-x86: nothing to compare T0 with; running T0 alone for crashes\n", .{});
    }

    const s = try gpa.create(Space);
    defer gpa.destroy(s);
    var native: ?vcpu.emit.native.Native = if (args.native) vcpu.emit.native.Native.init() catch |e| {
        std.debug.print("--native: no {s} emitter here ({t})\n", .{ vcpu.emit.native.name, e });
        std.process.exit(2);
    } else null;
    defer if (native) |*n| n.deinit();
    var tally: common.Tally = .{};
    defer tally.deinit(gpa);
    var report: std.Io.Writer.Allocating = .init(gpa);
    defer report.deinit();
    var buf: [page_size - 16]u8 = undefined;
    var failed: u64 = 0;
    var steps: u64 = 0;
    var checked: u64 = 0;
    s.load(&.{}, 0);
    const run = try check.Run.init(gpa, &x86.guest, check.mapBacking(&s.map));
    defer run.deinit();
    var i: u64 = 0;
    while (i < args.iters) : (i += 1) {
        const seed = args.seed +% i;
        var prng = std.Random.DefaultPrng.init(seed);
        const code = gen.program(prng.random(), .{ .len = @min(args.len, 1024), .classes = args.classes() }, &buf);
        const regs = gen.registers(prng.random());
        if (args.trace) std.debug.print("seed {d}: {x}\n", .{ seed, code });
        s.load(code, seed);
        report.clearRetainingCapacity();
        var bad = false;
        if (args.check) {
            var cpu: x86.Cpu = .{};
            cpu.r = regs.r;
            cpu.eip = gen.code_va;
            cpu.fl.set(regs.eflags);
            const out = vcpu.x86jit.check.checkRegions(gpa, run, &s.map, cpu, std.math.maxInt(i64), 4096, if (native) |*n| n else null) catch |e| blk: {
                try report.writer.print("region check: {t}\n", .{e});
                break :blk vcpu.x86jit.check.Result{ .exit = .chain, .pc = 0, .regions = 0, .retired = 0, .ok = false };
            };
            checked += out.retired;
            if (!out.ok) {
                bad = true;
                try report.writer.print("region check:\n{s}", .{run.report.items});
            }
            s.load(code, seed);
        }
        if (!bad) bad = try runProgram(gpa, s, regs.r, regs.eflags, args.lockstep, &report.writer, &steps);
        if (!bad) continue;
        failed += 1;
        if (args.keep_going) {
            try tally.add(gpa, report.written());
            continue;
        }
        std.debug.print("seed {d}: program {x}\n{s}\n", .{ seed, code, report.written() });
        std.process.exit(1);
    }
    std.debug.print("fuzz-x86: {d} programs, {d} diverged; {d} instructions stepped, {d} region-checked\n", .{ args.iters, failed, steps, checked });
    if (native) |n| std.debug.print("  {s} code: {d} regions run natively, {d} the emitter declined\n", .{ vcpu.emit.native.name, n.compiled, n.unsupported });
    tally.print();
    if (failed != 0) std.process.exit(1);
}

/// T0 on a shadow, and Unicorn on a mirror, an instruction at a time, to
/// the INT $64 or the first exit. Returns whether they diverged.
fn runProgram(gpa: std.mem.Allocator, s: *Space, r: [8]u32, eflags: u32, with_unicorn: bool, w: *std.Io.Writer, steps: *u64) !bool {
    var cpu: x86.Cpu = .{};
    cpu.r = r;
    cpu.eip = gen.code_va;
    cpu.fl.set(eflags);
    var shadow = check.Shadow.init(gpa, check.mapBacking(&s.map));
    defer shadow.deinit();
    // T0 runs on the space's pages themselves (the shadow over them is
    // committed after each step), so Unicorn's mirror compares with them.
    var c: vcpu.ctx.Ctx = .{ .cpu = @intFromPtr(&cpu), .space = @intFromPtr(&shadow) };
    if (with_unicorn) {
        if (options.unicorn) return lockstepRun(gpa, s, &cpu, &c, &shadow, w, steps);
    }
    var n: u32 = 0;
    while (n < 1 << 16) : (n += 1) {
        steps.* += 1;
        if (x86.step(&c) != 0) return false;
    }
    try w.print("T0 ran 65536 instructions without an exit\n", .{});
    return true;
}

fn lockstepRun(gpa: std.mem.Allocator, s: *Space, cpu: *x86.Cpu, c: *vcpu.ctx.Ctx, shadow: *check.Shadow, w: *std.Io.Writer, steps: *u64) !bool {
    const E = lockstep.Engine(.i386);
    const e = try E.init(gpa, &.{
        .{ .va = gen.code_va, .mem = &s.code, .exec = true },
        .{ .va = gen.data_va, .mem = &s.data, .write = true },
        .{ .va = gen.stack_va, .mem = &s.stack, .write = true },
    });
    defer e.deinit();
    try e.setState(canon(cpu));
    var n: u32 = 0;
    while (n < 1 << 16) : (n += 1) {
        steps.* += 1;
        const pc = cpu.eip;
        const off = pc -% gen.code_va;
        const bytes = s.code[@min(off, page_size - 1)..@min(page_size, off + 15)];
        const inst = vcpu.x86.decode.decode(bytes) catch null;
        const fx = if (inst) |in| vcpu.x86.decode.effects(&in) else vcpu.x86.decode.Effects{};
        const r0 = x86.step(c);
        shadow.commit();
        const e0: vcpu.ctx.Exit = @enumFromInt(r0);
        const st = try e.step();
        const same = switch (st) {
            .next => e0 == .ok,
            .syscall => e0 == .svc,
            .breakpoint => e0 == .brk,
            .undef => e0 == .undef,
            .fault => |f| e0 == .fault and f.addr == c.exit_addr,
            .exception => |v| e0 == .fault and c.exit_info >> 8 == v,
        };
        var bad = !same;
        if (!same) try w.print("exit at {x} ({x}): T0 {t} (info {x}), unicorn {any}\n", .{ pc, bytes[0..@min(bytes.len, if (inst) |in| in.len else 8)], e0, c.exit_info, st });
        // At an exit only the PC and the registers are compared: a
        // faulting instruction's partial effects are its own business.
        const mask: u32 = if (e0 == .ok) lockstep.x86_status_flags & ~fx.flags_undefined else 0;
        var ust = e.getState();
        if (e0 != .ok and same) ust.eip = canon(cpu).eip;
        if (lockstep.diff(.i386, canon(cpu), ust, mask, w)) bad = true;
        if (e.diffMemory(w)) bad = true;
        // Flags the instruction leaves undefined go on from Unicorn's, so
        // a difference there isn't reported at the next instruction.
        if (e0 == .ok and fx.flags_undefined != 0) cpu.fl.setMasked(fx.flags_undefined, ust.eflags);
        if (bad) {
            try w.print("at {x} ({x})\n", .{ pc, bytes[0..@min(bytes.len, if (inst) |in| in.len else 8)] });
            return true;
        }
        if (e0 != .ok) return false;
    }
    return false;
}

fn canon(c: *const x86.Cpu) lockstep.X86 {
    return .{ .r = c.r, .eip = c.eip, .eflags = c.fl.get() };
}
