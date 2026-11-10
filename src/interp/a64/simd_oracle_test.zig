//! simd_exec.zig against the host CPU, on an arm64 Mac: random words from
//! every FP and AdvSIMD encoding class that simd_decode.zig implements run
//! natively in a small harness and on T0, from the same registers, flags,
//! FPCR (RMode, FZ, and DN), and FPSR, and must leave the same general and
//! vector registers, flags, and FPSR. Other hosts skip it.
//!
//! H9_SIMD_ORACLE=<count>[:<seed>] runs more cases, from another seed.

const std = @import("std");
const builtin = @import("builtin");
const dec = @import("decode.zig");
const exec = @import("exec.zig");
const sd = @import("simd_decode.zig");
const mem = @import("../mem.zig");
const Ctx = @import("../../jit/ctx.zig").Ctx;

const supported = builtin.os.tag == .macos and builtin.cpu.arch == .aarch64;

const State = extern struct {
    x: [31]u64,
    nzcv: u64,
    v: [32]u128,
    fpcr: u64,
    fpsr: u64,
};

comptime {
    std.debug.assert(@offsetOf(State, "v") == 256);
    std.debug.assert(@offsetOf(State, "fpcr") == 768);
}

fn stp(t1: u32, t2: u32, n: u32, imm: u32) u32 {
    return 0xa9000000 | ((imm / 8) & 0x7f) << 15 | t2 << 10 | n << 5 | t1;
}
fn ldp(t1: u32, t2: u32, n: u32, imm: u32) u32 {
    return 0xa9400000 | ((imm / 8) & 0x7f) << 15 | t2 << 10 | n << 5 | t1;
}
fn str(t: u32, n: u32, imm: u32) u32 {
    return 0xf9000000 | (imm / 8) << 10 | n << 5 | t;
}
fn ldr(t: u32, n: u32, imm: u32) u32 {
    return 0xf9400000 | (imm / 8) << 10 | n << 5 | t;
}
fn qp(load: bool, t1: u32, t2: u32, n: u32, imm: u32) u32 {
    return @as(u32, if (load) 0xad400000 else 0xad000000) | ((imm / 16) & 0x7f) << 15 | t2 << 10 | n << 5 | t1;
}
fn dp(load: bool, t1: u32, t2: u32, n: u32, imm: u32) u32 {
    return @as(u32, if (load) 0x6d400000 else 0x6d000000) | ((imm / 8) & 0x7f) << 15 | t2 << 10 | n << 5 | t1;
}
const SPR = 31;
const msr_fpcr_x1 = 0xd51b4401;
const mrs_x1_fpcr = 0xd53b4401;
const msr_fpsr_x1 = 0xd51b4421;
const mrs_x1_fpsr = 0xd53b4421;
const msr_fpcr_xzr = 0xd51b441f;
const msr_fpsr_xzr = 0xd51b443f;

/// The harness: saves the callee-saved registers, loads x0-x30, NZCV,
/// V0-V31, FPCR, and FPSR from the State in x0, runs the instruction at
/// the returned index, stores them back, and resets FPCR and FPSR.
fn harness(buf: *std.ArrayList(u32), gpa: std.mem.Allocator) !usize {
    const put = struct {
        fn f(b: *std.ArrayList(u32), g: std.mem.Allocator, w: u32) !void {
            try b.append(g, w);
        }
    }.f;
    try put(buf, gpa, 0xd10403ff); // sub sp, sp, #256
    var r: u32 = 19;
    while (r < 31) : (r += 2) try put(buf, gpa, stp(r, r + 1, SPR, (r - 19) * 8));
    try put(buf, gpa, str(0, SPR, 96));
    r = 8;
    while (r < 16) : (r += 2) try put(buf, gpa, dp(false, r, r + 1, SPR, 128 + (r - 8) * 8));
    r = 0;
    while (r < 32) : (r += 2) try put(buf, gpa, qp(true, r, r + 1, 0, 256 + r * 16));
    try put(buf, gpa, ldr(1, 0, 768));
    try put(buf, gpa, msr_fpcr_x1);
    try put(buf, gpa, ldr(1, 0, 776));
    try put(buf, gpa, msr_fpsr_x1);
    try put(buf, gpa, ldr(1, 0, 248));
    try put(buf, gpa, 0xd51b4201); // msr nzcv, x1
    r = 1;
    while (r < 31) : (r += 2) try put(buf, gpa, ldp(r, r + 1, 0, r * 8));
    try put(buf, gpa, ldr(0, 0, 0));
    const at = buf.items.len;
    try put(buf, gpa, 0xd503201f); // the instruction under test
    try put(buf, gpa, str(0, SPR, 104));
    try put(buf, gpa, ldr(0, SPR, 96));
    r = 1;
    while (r < 31) : (r += 2) try put(buf, gpa, stp(r, r + 1, 0, r * 8));
    try put(buf, gpa, ldr(1, SPR, 104));
    try put(buf, gpa, str(1, 0, 0));
    try put(buf, gpa, 0xd53b4201); // mrs x1, nzcv
    try put(buf, gpa, str(1, 0, 248));
    try put(buf, gpa, mrs_x1_fpcr);
    try put(buf, gpa, str(1, 0, 768));
    try put(buf, gpa, mrs_x1_fpsr);
    try put(buf, gpa, str(1, 0, 776));
    try put(buf, gpa, msr_fpcr_xzr);
    try put(buf, gpa, msr_fpsr_xzr);
    r = 0;
    while (r < 32) : (r += 2) try put(buf, gpa, qp(false, r, r + 1, 0, 256 + r * 16));
    r = 8;
    while (r < 16) : (r += 2) try put(buf, gpa, dp(true, r, r + 1, SPR, 128 + (r - 8) * 8));
    r = 19;
    while (r < 31) : (r += 2) try put(buf, gpa, ldp(r, r + 1, SPR, (r - 19) * 8));
    try put(buf, gpa, 0x910403ff); // add sp, sp, #256
    try put(buf, gpa, 0xd65f03c0); // ret
    return at;
}

const MmapFn = *const fn (?*anyopaque, usize, c_int, c_int, c_int, i64) callconv(.c) ?*anyopaque;

const Native = struct {
    code: [*]u32,
    at: usize,
    protect: *const fn (c_int) callconv(.c) void,
    invalidate: *const fn (*anyopaque, usize) callconv(.c) void,

    fn init(words: []const u32, at: usize) !Native {
        const mmap = @extern(MmapFn, .{ .name = "mmap" });
        const p = mmap(null, 16384, 7, 0x1000 | 0x2 | 0x800, -1, 0); // RWX, MAP_ANON | MAP_PRIVATE | MAP_JIT
        if (p == null or @intFromPtr(p) == std.math.maxInt(usize)) return error.MapFailed;
        var n: Native = .{
            .code = @ptrCast(@alignCast(p.?)),
            .at = at,
            .protect = @extern(*const fn (c_int) callconv(.c) void, .{ .name = "pthread_jit_write_protect_np" }),
            .invalidate = @extern(*const fn (*anyopaque, usize) callconv(.c) void, .{ .name = "sys_icache_invalidate" }),
        };
        n.protect(0);
        @memcpy(n.code[0..words.len], words);
        n.protect(1);
        n.invalidate(n.code, words.len * 4);
        return n;
    }

    fn run(n: *Native, insn: u32, s: *State) void {
        n.protect(0);
        n.code[n.at] = insn;
        n.protect(1);
        n.invalidate(&n.code[n.at], 4);
        const f: *const fn (*State) callconv(.c) void = @ptrCast(n.code);
        f(s);
    }
};

// ---------------------------------------------------------------- inputs

const gp_interesting = [_]u64{
    0,                  1,                  2,                  0xffffffffffffffff,
    0x7fffffffffffffff, 0x8000000000000000, 0x00000000ffffffff, 0x0000000080000000,
    0x000000007fffffff, 0xffffffff80000000, 0x123456789abcdef0, 0xfedcba9876543210,
    63,                 64,                 31,                 32,
};

const f16s = [_]u16{ 0, 0x8000, 0x3c00, 0xbc00, 0x7c00, 0xfc00, 0x7e00, 0x7e55, 0x7c01, 0xfd23, 0x0400, 0x0001, 0x03ff, 0x7bff, 0x3800, 0x3e00, 0x4100, 0x3c01 };
const f32s = [_]u32{
    0,          0x80000000, 0x3f800000, 0xbf800000, 0x7f800000, 0xff800000, 0x7fc00000, 0x7fc12345,
    0x7f800001, 0xff812345, 0x00800000, 0x00000001, 0x007fffff, 0x807fffff, 0x7f7fffff, 0xff7fffff,
    0x3f000000, 0x3fc00000, 0x40200000, 0xc0200000, 0x4f000000, 0xcf000000, 0x4f800000, 0x5f000000,
    0xdf000000, 0x5f800000, 0x3f800001, 0x3effffff, 0x4effffff, 0x33800000, 0x00ffffff, 0x0f800000,
};
const f64s = [_]u64{
    0,                  0x8000000000000000, 0x3ff0000000000000, 0xbff0000000000000,
    0x7ff0000000000000, 0xfff0000000000000, 0x7ff8000000000000, 0x7ff8000012345678,
    0x7ff0000000000001, 0xfff0000000012345, 0x0010000000000000, 0x0000000000000001,
    0x000fffffffffffff, 0x800fffffffffffff, 0x7fefffffffffffff, 0x3fe0000000000000,
    0x3ff8000000000000, 0x4004000000000000, 0xc004000000000000, 0x41e0000000000000,
    0xc1e0000000000000, 0x41f0000000000000, 0x43e0000000000000, 0xc3e0000000000000,
    0x43f0000000000000, 0x3ff0000000000001, 0x380fffffe0000000, 0x47efffffe0000000,
    0x36a0000000000000, 0x3810000000000000, 0x41dfffffffc00000, 0x7e37e43c8800759c,
};

fn gpValue(rand: std.Random) u64 {
    return switch (rand.uintLessThan(u8, 4)) {
        0 => gp_interesting[rand.uintLessThan(usize, gp_interesting.len)],
        1 => rand.uintLessThan(u64, 256),
        else => rand.int(u64),
    };
}

fn vValue(rand: std.Random) u128 {
    var v: u128 = @as(u128, rand.int(u64)) << 64 | rand.int(u64);
    switch (rand.uintLessThan(u8, 6)) {
        0 => for (0..8) |i| {
            if (rand.boolean()) v = (v & ~(@as(u128, 0xffff) << @intCast(16 * i))) | @as(u128, f16s[rand.uintLessThan(usize, f16s.len)]) << @intCast(16 * i);
        },
        1, 2 => for (0..4) |i| {
            if (rand.uintLessThan(u8, 4) != 0) v = (v & ~(@as(u128, 0xffffffff) << @intCast(32 * i))) | @as(u128, f32s[rand.uintLessThan(usize, f32s.len)]) << @intCast(32 * i);
        },
        3, 4 => for (0..2) |i| {
            if (rand.uintLessThan(u8, 4) != 0) v = (v & ~(@as(u128, std.math.maxInt(u64)) << @intCast(64 * i))) | @as(u128, f64s[rand.uintLessThan(usize, f64s.len)]) << @intCast(64 * i);
        },
        else => {},
    }
    return v;
}

const Class = struct { name: []const u8, mask: u32, val: u32 };

/// The FP and AdvSIMD encoding classes, as bits that must match.
pub const classes = [_]Class{
    .{ .name = "three same", .mask = 0x9f200400, .val = 0x0e200400 },
    .{ .name = "scalar three same", .mask = 0xdf200400, .val = 0x5e200400 },
    .{ .name = "three different", .mask = 0x9f200c00, .val = 0x0e200000 },
    .{ .name = "scalar three different", .mask = 0xdf200c00, .val = 0x5e200000 },
    .{ .name = "two-reg misc", .mask = 0x9f3e0c00, .val = 0x0e200800 },
    .{ .name = "scalar two-reg misc", .mask = 0xdf3e0c00, .val = 0x5e200800 },
    .{ .name = "across lanes", .mask = 0x9f3e0c00, .val = 0x0e300800 },
    .{ .name = "scalar pairwise", .mask = 0xdf3e0c00, .val = 0x5e300800 },
    .{ .name = "copy", .mask = 0x9fe08400, .val = 0x0e000400 },
    .{ .name = "scalar copy", .mask = 0xdfe08400, .val = 0x5e000400 },
    .{ .name = "modified immediate", .mask = 0x9ff80400, .val = 0x0f000400 },
    .{ .name = "shift by immediate", .mask = 0x9f800400, .val = 0x0f000400 },
    .{ .name = "scalar shift by immediate", .mask = 0xdf800400, .val = 0x5f000400 },
    .{ .name = "by element", .mask = 0x9f000400, .val = 0x0f000000 },
    .{ .name = "scalar by element", .mask = 0xdf000400, .val = 0x5f000000 },
    .{ .name = "table lookup", .mask = 0xbfe08c00, .val = 0x0e000000 },
    .{ .name = "permute", .mask = 0xbf208c00, .val = 0x0e000800 },
    .{ .name = "extract", .mask = 0xbfe08400, .val = 0x2e000000 },
    .{ .name = "FP and fixed point", .mask = 0x7f200000, .val = 0x1e000000 },
    .{ .name = "FP and integer", .mask = 0x7f20fc00, .val = 0x1e200000 },
    .{ .name = "FP one source", .mask = 0xff207c00, .val = 0x1e204000 },
    .{ .name = "FP compare", .mask = 0xff203c00, .val = 0x1e202000 },
    .{ .name = "FP immediate", .mask = 0xff201c00, .val = 0x1e201000 },
    .{ .name = "FP conditional compare", .mask = 0xff200c00, .val = 0x1e200400 },
    .{ .name = "FP two source", .mask = 0xff200c00, .val = 0x1e200800 },
    .{ .name = "FP conditional select", .mask = 0xff200c00, .val = 0x1e200c00 },
    .{ .name = "FP three source", .mask = 0xff000000, .val = 0x1f000000 },
};

/// A word of class `c` that simd_decode.zig implements and that touches
/// neither SP nor X18 (macOS reserves it).
fn candidate(rand: std.Random, c: Class) ?u32 {
    const w = (rand.int(u32) & ~c.mask) | c.val;
    const o = dec.decode(w, 0x10000);
    if (!o.k.isSimd()) return null;
    const r = dec.regs(o);
    if (r.mem != .none) return null;
    const bad: u64 = 1 << 18 | 1 << dec.SP;
    if ((r.read | r.write) & bad != 0) return null;
    return w;
}

/// FPSR's bits T0 models: the cumulative exception flags and QC.
const fpsr_mask: u64 = 0x0800_009f;

fn config() struct { n: usize, seed: u64 } {
    const n: usize = 300_000;
    const seed: u64 = 0x5851f42d4c957f2d;
    const v = std.c.getenv("H9_SIMD_ORACLE") orelse return .{ .n = n, .seed = seed };
    const s = std.mem.span(v);
    var it = std.mem.splitScalar(u8, s, ':');
    const cn = std.fmt.parseUnsigned(usize, it.next().?, 10) catch n;
    const cs = if (it.next()) |x| std.fmt.parseUnsigned(u64, x, 0) catch seed else seed;
    return .{ .n = cn, .seed = cs };
}

test "T0 matches the host CPU on random FP and AdvSIMD instructions" {
    if (!supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(gpa);
    const at = try harness(&words, gpa);
    var native = try Native.init(words.items, at);

    const cfg = config();
    var prng: std.Random.DefaultPrng = .init(cfg.seed);
    const rand = prng.random();
    var cpu: exec.Cpu = .{};
    var tlb: mem.Tlb = .{};
    var cache: exec.Cache = .init(gpa);
    defer cache.deinit();
    var view: mem.View = .{ .tlb = &tlb };
    var ctx: Ctx = .{ .tlb = @intFromPtr(&tlb), .space = @intFromPtr(&view) };
    var m: exec.Machine = .init(&cpu, &ctx, &cache, null);

    const nk = @typeInfo(sd.Kind).@"enum".fields.len;
    var kinds: [nk]u32 = @splat(0);
    var per_class: [classes.len]u32 = @splat(0);
    var tried: usize = 0;
    var failures: usize = 0;
    while (tried < cfg.n) {
        const ci = rand.uintLessThan(usize, classes.len);
        const w = candidate(rand, classes[ci]) orelse continue;
        tried += 1;
        per_class[ci] += 1;
        var s: State = undefined;
        for (&s.x) |*x| x.* = gpValue(rand);
        s.x[18] = 0;
        for (&s.v) |*v| v.* = vValue(rand);
        s.nzcv = @as(u64, rand.int(u4)) << 28;
        const rmode: u64 = if (rand.boolean()) 0 else rand.int(u2);
        const fz: u64 = @intFromBool(rand.uintLessThan(u8, 4) == 0);
        const dn: u64 = @intFromBool(rand.uintLessThan(u8, 4) == 0);
        s.fpcr = rmode << 22 | fz << 24 | dn << 25;
        s.fpsr = 0;
        cpu = .{};
        @memcpy(cpu.r[0..31], &s.x);
        cpu.nzcv = @truncate(s.nzcv);
        cpu.v = s.v;
        cpu.fpcr = @truncate(s.fpcr);
        cpu.fpsr = 0;
        const before = s;
        native.run(w, &s);
        const o = dec.decode(w, 0x10000);
        kinds[@intFromEnum(sd.ofKind(o.k))] += 1;
        try std.testing.expectEqual(exec.Next.next, exec.step(&m, &o, 0x10000));
        const same = std.mem.eql(u64, cpu.r[0..31], &s.x) and cpu.nzcv == s.nzcv and
            std.mem.eql(u128, &cpu.v, &s.v) and cpu.fpsr == s.fpsr & fpsr_mask;
        if (!same) {
            failures += 1;
            if (failures <= 12) {
                std.debug.print("{x:0>8} ({t}, x {d} sh {d} imm {x}) fpcr {x}: differs\n", .{ w, sd.ofKind(o.k), o.x, o.sh, o.imm, s.fpcr });
                for (0..31) |i| if (cpu.r[i] != s.x[i]) std.debug.print("  x{d}: in {x} host {x} t0 {x}\n", .{ i, before.x[i], s.x[i], cpu.r[i] });
                for (0..32) |i| if (cpu.v[i] != s.v[i]) std.debug.print("  v{d}: host {x:0>32} t0 {x:0>32}\n", .{ i, s.v[i], cpu.v[i] });
                std.debug.print("  n v{d}: {x:0>32}  m v{d}: {x:0>32}  d before {x:0>32}\n", .{ o.n, before.v[o.n & 31], o.m, before.v[o.m & 31], before.v[o.d & 31] });
                if (cpu.nzcv != s.nzcv) std.debug.print("  nzcv: in {x} host {x} t0 {x}\n", .{ before.nzcv, s.nzcv, cpu.nzcv });
                if (cpu.fpsr != s.fpsr & fpsr_mask) std.debug.print("  fpsr: host {x} t0 {x}\n", .{ s.fpsr, cpu.fpsr });
            }
        }
    }
    if (failures > 0) std.debug.print("{d} of {d} differ\n", .{ failures, tried });
    for (classes, per_class) |c, n| if (n == 0) std.debug.print("no coverage: class {s}\n", .{c.name});
    var missing: usize = 0;
    inline for (@typeInfo(sd.Kind).@"enum".fields) |f| {
        if (kinds[f.value] == 0) {
            std.debug.print("no coverage: {s}\n", .{f.name});
            missing += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
    try std.testing.expectEqual(@as(usize, 0), missing);
}
