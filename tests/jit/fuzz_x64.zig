//! zig build fuzz-x64 [-- options]: random long-mode programs (src/jit/
//! check/gen_x86.zig's `program64`) run on hx64's T0 and, with
//! -Demu=unicorn, checked against Unicorn an instruction at a time:
//! registers, RIP, the RFLAGS bits the instruction defines, the FS and GS
//! bases, SSE's registers, memory, and the exit; and, region by region,
//! the lifter in ir_eval (and with --native, this host's code) against T0
//! (check.zig's region check), for the regions long mode lifts.
//!
//! Until long-mode T0 runs (workstreams A and B), the programs run on
//! Unicorn alone, which checks the generator: each must reach its
//! SYSCALL, the page fault or #GP its bad_mem instruction asks for, or a
//! DIV's #DE.
//!
//! Options: see fuzz_common.zig (`--without` takes gen_x86.Class64
//! names). A divergence prints the seed, the program, and the report;
//! rerun one with --seed S --iters 1.

const std = @import("std");
const options = @import("fuzz_options");
const hcpu = @import("hcpu");
const check = hcpu.check;
const gen = check.gen_x86;
const x86 = check.x86;
const mem = hcpu.mem;
const ctx_mod = hcpu.ctx;
const common = @import("fuzz_common.zig");
const lockstep = if (options.unicorn) @import("lockstep") else struct {};

const page_size = mem.page_size;
const Cpu64 = x86.Cpu64;

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
    var args = try common.Args(gen.Class64).parse("fuzz-x64", init);
    if (!options.unicorn) args.lockstep = false;
    const t0 = x86.longRuns();
    std.debug.print("fuzz-x64: seed {d}, {d} programs of {d}; region check {s}, lockstep {s}\n", .{ args.seed, args.iters, args.len, if (args.check and t0) "on" else "off", if (args.lockstep) "on" else if (options.unicorn) "off" else "off (needs -Demu=unicorn)" });
    if (!t0) {
        if (!args.lockstep) {
            std.debug.print("fuzz-x64: long-mode T0 doesn't run yet, and without Unicorn there's nothing to run\n", .{});
            std.process.exit(2);
        }
        std.debug.print("fuzz-x64: long-mode T0 doesn't run yet: running the programs on Unicorn alone, to check the generator\n", .{});
    }

    const s = try gpa.create(Space);
    defer gpa.destroy(s);
    var native: ?hcpu.emit.native.Native = if (args.native) hcpu.emit.native.Native.init() catch |e| {
        std.debug.print("--native: no {s} emitter here ({t})\n", .{ hcpu.emit.native.name, e });
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
    var regions: u64 = 0;
    s.load(&.{}, 0);
    const run = try check.Run.init(gpa, &x86.guest64, check.mapBacking(&s.map));
    defer run.deinit();
    var i: u64 = 0;
    while (args.more(i, init.io)) : (i += 1) {
        const seed = args.seed +% i;
        var prng = std.Random.DefaultPrng.init(seed);
        const code = gen.program64(prng.random(), .{ .len = @min(args.len, 1024), .classes = args.classes() }, &buf);
        const regs = gen.registers64(prng.random());
        if (args.trace) std.debug.print("seed {d}: {x}\n", .{ seed, code });
        s.load(code, seed);
        report.clearRetainingCapacity();
        var bad = false;
        if (!t0) {
            if (options.unicorn) bad = try unicornAlone(gpa, s, regs.r, regs.rflags, &report.writer, &steps);
        } else {
            if (args.check) {
                var cpu: Cpu64 = .{};
                cpu.r = regs.r;
                cpu.rip = gen.code_va;
                cpu.fl.set(@truncate(regs.rflags));
                const out = checkRegions(gpa, run, &s.map, cpu, if (native) |*n| n else null) catch |e| blk: {
                    try report.writer.print("region check: {t}\n", .{e});
                    break :blk Checked{ .ok = false };
                };
                checked += out.retired;
                regions += out.regions;
                if (!out.ok) {
                    bad = true;
                    try report.writer.print("region check:\n{s}", .{run.report.items});
                }
                s.load(code, seed);
            }
            if (!bad) bad = try runProgram(gpa, s, regs.r, regs.rflags, args.lockstep, &report.writer, &steps);
        }
        if (!bad) continue;
        failed += 1;
        if (args.keep_going) {
            try tally.add(gpa, report.written());
            continue;
        }
        std.debug.print("seed {d}: program {x}\n{s}\n", .{ seed, code, report.written() });
        std.process.exit(1);
    }
    std.debug.print("fuzz-x64: {d} programs, {d} diverged; {d} instructions stepped, {d} region-checked in {d} regions\n", .{ i, failed, steps, checked, regions });
    if (native) |n| {
        std.debug.print("  {s} code: {d} regions run natively, {d} the emitter declined\n", .{ hcpu.emit.native.name, n.compiled, n.unsupported });
        hcpu.emit.native.printFallbacks();
    }
    tally.print();
    if (failed != 0) std.process.exit(1);
}

const Checked = struct { ok: bool = true, retired: u64 = 0, regions: u64 = 0 };

/// The region check over a whole program: each region the long-mode
/// lifter takes runs in ir_eval (and natively) against T0; where it lifts
/// nothing, T0 steps one instruction and the check goes on from there.
fn checkRegions(gpa: std.mem.Allocator, r: *check.Run, map: *const mem.Map, start: Cpu64, native: ?*hcpu.emit.native.Native) !Checked {
    const backing = check.mapBacking(map);
    var cpu = start;
    var res: Checked = .{};
    var n: u32 = 0;
    while (n < 4096) : (n += 1) {
        var reg = check.liftOpt(gpa, &x86.guest64, &backing, cpu.rip, .{ .lazy_eflags = native == null or hcpu.emit.native.lazy_eflags }) catch |e| switch (e) {
            error.Unsupported => {
                var sh = check.Shadow.init(gpa, backing);
                defer sh.deinit();
                var c: ctx_mod.Ctx = .{ .cpu = @intFromPtr(&cpu), .space = @intFromPtr(&sh) };
                const x: ctx_mod.Exit = @enumFromInt(x86.step64(&c));
                sh.commit();
                if (x != .ok) return res;
                continue;
            },
            else => return e,
        };
        defer reg.deinit(gpa);
        if (!try r.check(.{ .ir_eval = &reg }, std.mem.asBytes(&cpu), .{ .budget = std.math.maxInt(i64) })) {
            res.ok = false;
            return res;
        }
        if (native) |nt| if (try nt.compile(gpa, &reg)) |f| {
            if (!try r.check(.{ .entry = f }, std.mem.asBytes(&cpu), .{ .budget = std.math.maxInt(i64) })) {
                res.ok = false;
                return res;
            }
        };
        res.regions += 1;
        const o = r.out[check.Run.t1];
        res.retired += o.retired;
        r.shadow[check.Run.t1].commit();
        @memcpy(std.mem.asBytes(&cpu), r.cpu[check.Run.t1]);
        switch (o.exit) {
            .chain, .indirect => {},
            else => return res,
        }
    }
    return res;
}

/// T0 on a shadow, and Unicorn on a mirror, an instruction at a time, to
/// the SYSCALL or the first exit. Returns whether they diverged.
fn runProgram(gpa: std.mem.Allocator, s: *Space, r: [16]u64, rflags: u64, with_unicorn: bool, w: *std.Io.Writer, steps: *u64) !bool {
    var cpu: Cpu64 = .{};
    cpu.r = r;
    cpu.rip = gen.code_va;
    cpu.fl.set(@truncate(rflags));
    var shadow = check.Shadow.init(gpa, check.mapBacking(&s.map));
    defer shadow.deinit();
    var c: ctx_mod.Ctx = .{ .cpu = @intFromPtr(&cpu), .space = @intFromPtr(&shadow) };
    if (with_unicorn) {
        if (options.unicorn) return lockstepRun(gpa, s, &cpu, &c, &shadow, w, steps);
    }
    var n: u32 = 0;
    while (n < 1 << 16) : (n += 1) {
        steps.* += 1;
        if (x86.step64(&c) != 0) return false;
    }
    try w.print("T0 ran 65536 instructions without an exit\n", .{});
    return true;
}

const regions_of = struct {
    fn of(s: *Space) [3]if (options.unicorn) lockstep.Region else void {
        return .{
            .{ .va = gen.code_va, .mem = &s.code, .exec = true },
            .{ .va = gen.data_va, .mem = &s.data, .write = true },
            .{ .va = gen.stack_va, .mem = &s.stack, .write = true },
        };
    }
}.of;

/// A program on Unicorn alone: it must end at its SYSCALL, at the page
/// fault or #GP a bad_mem instruction asks for, at a #DE, or before an
/// instruction Unicorn is known to get wrong.
fn unicornAlone(gpa: std.mem.Allocator, s: *Space, r: [16]u64, rflags: u64, w: *std.Io.Writer, steps: *u64) !bool {
    const E = lockstep.Engine(.amd64);
    const e = try E.init(gpa, &regions_of(s));
    defer e.deinit();
    try e.setState(.{ .r = r, .rip = gen.code_va, .rflags = rflags });
    var n: u32 = 0;
    while (n < 1 << 16) : (n += 1) {
        steps.* += 1;
        const pc = e.pc();
        const ust = e.getState();
        const bytes = s.code[pc - gen.code_va ..][0..15];
        if (unicornIdivCrash(bytes, ust.r[0], ust.r[2])) return false;
        // Unicorn's own mistakes end the program.
        if (lockstep.knownX64Insn(bytes) != null) return false;
        const st = try e.step();
        switch (st) {
            .next => continue,
            .syscall => {
                if (s.code[pc - gen.code_va] == 0x0F and s.code[pc - gen.code_va + 1] == 0x05) return false;
            },
            .fault => |f| if (f.addr >= gen.bad_va and f.addr < gen.bad_va + 4096) return false else if (lockstep.knownX64(true, st) != null) return false,
            // #DE from a DIV or IDIV, or #GP from a non-canonical moffs.
            .exception => |v| if (v == 0 or v == 13) return false,
            else => {},
        }
        try w.print("unicorn: {any} at {x} ({x})\n", .{ st, pc, s.code[pc - gen.code_va ..][0..15] });
        return true;
    }
    try w.print("unicorn ran 65536 instructions without an exit\n", .{});
    return true;
}

fn lockstepRun(gpa: std.mem.Allocator, s: *Space, cpu: *Cpu64, c: *ctx_mod.Ctx, shadow: *check.Shadow, w: *std.Io.Writer, steps: *u64) !bool {
    const E = lockstep.Engine(.amd64);
    const e = try E.init(gpa, &regions_of(s));
    defer e.deinit();
    try e.setState(canon(cpu));
    var n: u32 = 0;
    while (n < 1 << 16) : (n += 1) {
        steps.* += 1;
        const pc = cpu.rip;
        const off = pc -% gen.code_va;
        const bytes = s.code[@min(off, page_size - 1)..@min(page_size, off + 15)];
        const undef = undefinedFlags(bytes);
        const crash = unicornIdivCrash(bytes, cpu.r[0], cpu.r[2]);
        const r0 = x86.step64(c);
        shadow.commit();
        const e0: ctx_mod.Exit = @enumFromInt(r0);
        // T0 raises #DE there; the program ends without asking Unicorn.
        if (crash and exceptionOf(c, e0) == 0) return false;
        const st = try e.step();
        const same = switch (st) {
            .next => e0 == .ok,
            .syscall => e0 == .svc,
            .breakpoint => e0 == .brk,
            .undef => e0 == .undef,
            .fault => |f| e0 == .fault and f.addr == c.exit_addr,
            .exception => |v| exceptionOf(c, e0) == v,
        };
        // Known: a non-canonical access is #GP on T0, and a page fault on
        // Unicorn. The program ends there.
        if (!same and lockstep.knownX64(exceptionOf(c, e0) == 13, st) != null) return false;
        var bad = !same;
        if (lockstep.knownX64Insn(bytes) != null) return false;
        // Known: a 32-bit CMPXCHG, where Unicorn zero-extends both EAX
        // and the destination. The program ends there if they differ.
        if (same and e0 == .ok and lockstep.knownX64Result(bytes) != null) {
            var probe: std.Io.Writer.Discarding = .init(&.{});
            if (lockstep.diff(.amd64, canon(cpu), e.getState(), 0, &probe.writer)) return false;
        }
        if (!same) try w.print("exit: at {x} ({x}) T0 {t} (info {x}), unicorn {any}\n", .{ pc, bytes, e0, c.exit_info, st });
        const mask: u32 = if (e0 == .ok) lockstep.x86_status_flags & ~undef else 0;
        var ust = e.getState();
        if (e0 != .ok and same) ust.rip = canon(cpu).rip;
        if (lockstep.diff(.amd64, canon(cpu), ust, mask, w)) bad = true;
        if (e.diffMemory(w)) bad = true;
        // Flags the instruction leaves undefined go on from Unicorn's.
        if (e0 == .ok and undef != 0) cpu.fl.setMasked(undef, @truncate(ust.rflags));
        if (bad) {
            try w.print("at {x} ({x})\n", .{ pc, bytes });
            return true;
        }
        if (e0 != .ok) return false;
    }
    return false;
}

/// Whether the instruction at `bytes` is an IDIV that would kill the host
/// in Unicorn: QEMU's helper divides EDX:EAX = 2^63 (or DX:AX = 2^31) by
/// -1 in a host IDIV, which raises SIGFPE, whatever the divisor turns out
/// to be. Taken as the start of a #DE.
fn unicornIdivCrash(bytes: []const u8, rax: u64, rdx: u64) bool {
    var k: usize = 0;
    while (k < bytes.len) : (k += 1) switch (bytes[k]) {
        0x66, 0x67, 0xF0, 0xF2, 0xF3, 0x2E, 0x36, 0x3E, 0x26, 0x64, 0x65 => {},
        else => break,
    };
    if (k < bytes.len and bytes[k] & 0xF0 == 0x40) k += 1;
    if (k + 1 >= bytes.len or bytes[k] != 0xF7 or (bytes[k + 1] >> 3) & 7 != 7) return false;
    const eax: u32 = @truncate(rax);
    const edx: u32 = @truncate(rdx);
    return (edx == 0x8000_0000 and eax == 0) or (edx & 0xffff == 0x8000 and eax & 0xffff == 0);
}

/// The RFLAGS bits the instruction at `bytes` leaves undefined, as the
/// decoder's effects have them; DIV and IDIV leave all six.
fn undefinedFlags(bytes: []const u8) u32 {
    const dec = hcpu.x86.decode;
    const i = dec.decodeIn(.long, bytes) catch return 0;
    if (i.op == .div or i.op == .idiv) return hcpu.x86.flags.arith;
    return dec.effectsIn(.long, &i).flags_undefined;
}

/// The vector of the exception T0 raised, if it raised one.
fn exceptionOf(c: *const ctx_mod.Ctx, e: ctx_mod.Exit) ?u64 {
    if (e != .fault or (c.exit_info >> 8) & 0xff != hcpu.x86jit.lift.exception_kind) return null;
    return c.exit_info >> 16;
}

fn canon(c: *const Cpu64) lockstep.X64 {
    return .{ .r = c.r, .rip = c.rip, .rflags = c.fl.get(), .fs_base = c.fs_base, .gs_base = c.gs_base, .xmm = c.xmm, .mxcsr = c.mxcsr };
}
