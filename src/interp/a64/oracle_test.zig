//! T0 against the host CPU, on an arm64 Mac: random data-processing
//! instructions (immediate and register classes) run natively in a small
//! harness and on T0 from the same registers and flags, and must leave the
//! same registers and flags. Other hosts skip it.

const std = @import("std");
const builtin = @import("builtin");
const dec = @import("decode.zig");
const exec = @import("exec.zig");
const mem = @import("../mem.zig");
const Ctx = @import("../../jit/ctx.zig").Ctx;

const supported = builtin.os.tag == .macos and builtin.cpu.arch == .aarch64;

const State = extern struct {
    x: [31]u64,
    nzcv: u64,
    v: [32]u128,
};

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

/// The harness: saves the callee-saved registers, loads x0-x30 and NZCV
/// from the State in x0, runs the instruction at `insn_index`, and stores
/// them back.
fn harness(buf: *std.ArrayList(u32), gpa: std.mem.Allocator) !usize {
    const a = struct {
        fn put(b: *std.ArrayList(u32), g: std.mem.Allocator, w: u32) !void {
            try b.append(g, w);
        }
    };
    try a.put(buf, gpa, 0xd10403ff); // sub sp, sp, #256
    var r: u32 = 19;
    while (r < 31) : (r += 2) try a.put(buf, gpa, stp(r, r + 1, SPR, (r - 19) * 8));
    try a.put(buf, gpa, str(0, SPR, 96));
    r = 8;
    while (r < 16) : (r += 2) try a.put(buf, gpa, dp(false, r, r + 1, SPR, 128 + (r - 8) * 8));
    r = 0;
    while (r < 32) : (r += 2) try a.put(buf, gpa, qp(true, r, r + 1, 0, 256 + r * 16));
    try a.put(buf, gpa, ldr(1, 0, 248));
    try a.put(buf, gpa, 0xd51b4201); // msr nzcv, x1
    r = 1;
    while (r < 31) : (r += 2) try a.put(buf, gpa, ldp(r, r + 1, 0, r * 8));
    try a.put(buf, gpa, ldr(0, 0, 0));
    const at = buf.items.len;
    try a.put(buf, gpa, 0xd503201f); // the instruction under test
    try a.put(buf, gpa, str(0, SPR, 104));
    try a.put(buf, gpa, ldr(0, SPR, 96));
    r = 1;
    while (r < 31) : (r += 2) try a.put(buf, gpa, stp(r, r + 1, 0, r * 8));
    try a.put(buf, gpa, ldr(1, SPR, 104));
    try a.put(buf, gpa, str(1, 0, 0));
    try a.put(buf, gpa, 0xd53b4201); // mrs x1, nzcv
    try a.put(buf, gpa, str(1, 0, 248));
    r = 0;
    while (r < 32) : (r += 2) try a.put(buf, gpa, qp(false, r, r + 1, 0, 256 + r * 16));
    r = 8;
    while (r < 16) : (r += 2) try a.put(buf, gpa, dp(true, r, r + 1, SPR, 128 + (r - 8) * 8));
    r = 19;
    while (r < 31) : (r += 2) try a.put(buf, gpa, ldp(r, r + 1, SPR, (r - 19) * 8));
    try a.put(buf, gpa, 0x910403ff); // add sp, sp, #256
    try a.put(buf, gpa, 0xd65f03c0); // ret
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


const interesting = [_]u64{
    0,                  1,                  2,                  0xffffffffffffffff,
    0x7fffffffffffffff, 0x8000000000000000, 0x00000000ffffffff, 0x0000000080000000,
    0x000000007fffffff, 0xffffffff80000000, 0x123456789abcdef0, 0xfedcba9876543210,
    63,                 64,                 31,                 32,
};

fn randomValue(rand: std.Random) u64 {
    return switch (rand.uintLessThan(u8, 4)) {
        0 => interesting[rand.uintLessThan(usize, interesting.len)],
        1 => rand.uintLessThan(u64, 256),
        else => rand.int(u64),
    };
}

/// A word in the data-processing groups whose op T0 runs without memory,
/// branches, system state, SP, or X18 (macOS reserves it).
fn candidate(rand: std.Random) ?u32 {
    var w = rand.int(u32);
    const op0: u32 = switch (rand.uintLessThan(u8, 5)) {
        0 => 0b1000,
        1 => 0b1001,
        2 => 0b0101,
        3 => 0b1101,
        // data processing (1 source), which random words rarely hit
        else => 0x5ac00000 >> 25,
    };
    w = (w & ~@as(u32, 0xf << 25)) | op0 << 25;
    if (op0 == 0x5ac00000 >> 25) w = (w & 0x800003ff) | 0x5ac00000 | @as(u32, rand.uintLessThan(u8, 6)) << 10;
    // MOV (register), which needs Rn = ZR and no shift
    if (rand.uintLessThan(u8, 64) == 0) w = (w & 0x801f001f) | 0x2a0003e0;
    if ((w >> 24) & 0x1f == 0x10) return null; // ADR and ADRP: the PCs differ
    const o = dec.decode(w, 0x10000);
    if (o.k == .undef) return null;
    const r = dec.regs(o);
    if (r.mem != .none or r.ctrl != .none or r.system) return null;
    const bad: u64 = 1 << 18 | 1 << dec.SP;
    if ((r.read | r.write) & bad != 0) return null;
    return w;
}

test "T0 matches the host CPU on random data-processing instructions" {
    if (!supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(gpa);
    const at = try harness(&words, gpa);
    var native = try Native.init(words.items, at);

    var prng: std.Random.DefaultPrng = .init(0x9e3779b97f4a7c15);
    const rand = prng.random();
    var cpu: exec.Cpu = .{};
    var tlb: mem.Tlb = .{};
    var cache: exec.Cache = .init(gpa);
    defer cache.deinit();
    var view: mem.View = .{ .tlb = &tlb };
    var ctx: Ctx = .{ .tlb = @intFromPtr(&tlb), .space = @intFromPtr(&view) };
    var m: exec.Machine = .init(&cpu, &ctx, &cache, null);

    var tried: usize = 0;
    var kinds: [dec.nkinds]u32 = @splat(0);
    while (tried < 200_000) {
        const w = candidate(rand) orelse continue;
        tried += 1;
        var s: State = undefined;
        for (&s.x) |*x| x.* = randomValue(rand);
        s.x[18] = 0;
        for (&s.v) |*v| v.* = @as(u128, rand.int(u64)) << 64 | rand.int(u64);
        s.nzcv = @as(u64, rand.int(u4)) << 28;
        cpu = .{};
        @memcpy(cpu.r[0..31], &s.x);
        cpu.nzcv = @truncate(s.nzcv);
        cpu.v = s.v;
        const before = s;
        native.run(w, &s);
        const o = dec.decode(w, 0x10000);
        kinds[@intFromEnum(o.k)] += 1;
        try std.testing.expectEqual(exec.Next.next, exec.step(&m, &o, 0x10000));
        const same = std.mem.eql(u64, cpu.r[0..31], &s.x) and cpu.nzcv == s.nzcv and std.mem.eql(u128, &cpu.v, &s.v);
        if (!same) {
            std.debug.print("{x:0>8} ({t}): differs\n", .{ w, o.k });
            for (0..31) |i| if (cpu.r[i] != s.x[i]) std.debug.print("  x{d}: in {x} host {x} t0 {x}\n", .{ i, before.x[i], s.x[i], cpu.r[i] });
            if (cpu.nzcv != s.nzcv) std.debug.print("  nzcv: in {x} host {x} t0 {x}\n", .{ before.nzcv, s.nzcv, cpu.nzcv });
            return error.TestUnexpectedResult;
        }
    }
    // Every data-processing kind got some coverage.
    var missing: usize = 0;
    inline for (@typeInfo(dec.Kind).@"enum".fields) |f| {
        const k: dec.Kind = @enumFromInt(f.value);
        const isdp = @intFromEnum(k) >= @intFromEnum(dec.Kind.movi) and @intFromEnum(k) <= @intFromEnum(dec.Kind.umulh);
        if (isdp and kinds[f.value] == 0) {
            std.debug.print("no coverage: {t}\n", .{k});
            missing += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), missing);
}

/// A word in the load/store groups that T0 runs as one plain load or store
/// through a base register: no literals, exclusives, SP, X18, or the
/// combinations the architecture leaves unpredictable (writeback onto a
/// transfer register, LDP into one register twice).
fn memCandidate(rand: std.Random) ?u32 {
    var w = rand.int(u32);
    const op0: u32 = switch (rand.uintLessThan(u8, 4)) {
        0 => 0b0100,
        1 => 0b0110,
        2 => 0b1100,
        else => 0b1110,
    };
    w = (w & ~@as(u32, 0xf << 25)) | op0 << 25;
    const o = dec.decode(w, 0x10000);
    const r = dec.regs(o);
    if (r.mem != .load and r.mem != .store) return null;
    if (r.system or r.ctrl != .none) return null;
    const bad: u64 = 1 << 18 | 1 << dec.SP;
    if ((r.read | r.write) & bad != 0) return null;
    const i = dec.info(o.k);
    if (!i.modes) return w;
    const pair = o.k == .ldp_x or o.k == .ldp_w or o.k == .ldpsw or o.k == .stp_x or o.k == .stp_w or
        o.k == .ldp_vs or o.k == .ldp_vd or o.k == .ldp_vq or o.k == .stp_vs or o.k == .stp_vd or o.k == .stp_vq;
    if (!pair and o.x == 4) return null;
    const wb = o.x == 1 or o.x == 3;
    if (wb and !i.vreg and (o.d == o.n or (pair and o.m == o.n))) return null;
    if (pair and r.mem == .load and o.d == o.m) return null;
    if (!pair and o.x == 5 and o.m == o.n) return null;
    return w;
}

test "T0 matches the host CPU on random loads and stores" {
    if (!supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var words: std.ArrayList(u32) = .empty;
    defer words.deinit(gpa);
    const at = try harness(&words, gpa);
    var native = try Native.init(words.items, at);

    const size = 128 * 1024;
    const host_buf = try gpa.alignedAlloc(u8, .fromByteUnits(mem.page_size), size);
    defer gpa.free(host_buf);
    const t0_buf = try gpa.alignedAlloc(u8, .fromByteUnits(mem.page_size), size);
    defer gpa.free(t0_buf);
    const va: u64 = @intFromPtr(host_buf.ptr);
    const maps = [_]mem.Mapping{.{ .va = va, .len = size, .host = @intFromPtr(t0_buf.ptr), .perms = .{ .write = true } }};

    var prng: std.Random.DefaultPrng = .init(0x243f6a8885a308d3);
    const rand = prng.random();
    rand.bytes(host_buf);
    @memcpy(t0_buf, host_buf);
    var cpu: exec.Cpu = .{};
    var tlb: mem.Tlb = .{};
    var cache: exec.Cache = .init(gpa);
    defer cache.deinit();
    var view: mem.View = .{ .maps = &maps, .tlb = &tlb };
    var ctx: Ctx = .{ .tlb = @intFromPtr(&tlb), .space = @intFromPtr(&view) };
    var m: exec.Machine = .init(&cpu, &ctx, &cache, null);

    var tried: usize = 0;
    var kinds: [dec.nkinds]u32 = @splat(0);
    while (tried < 100_000) {
        const w = memCandidate(rand) orelse continue;
        tried += 1;
        const o = dec.decode(w, 0x10000);
        var s: State = undefined;
        for (&s.x) |*x| x.* = randomValue(rand);
        for (&s.v) |*v| v.* = @as(u128, rand.int(u64)) << 64 | rand.int(u64);
        s.x[18] = 0;
        s.nzcv = 0;
        if (o.n < 31) s.x[o.n] = va + 4096 + rand.uintLessThan(u64, 64);
        if (dec.info(o.k).modes and o.x == 5 and o.m < 31) s.x[o.m] = rand.uintLessThan(u64, 256);
        cpu = .{};
        @memcpy(cpu.r[0..31], &s.x);
        cpu.v = s.v;
        const before = s;
        native.run(w, &s);
        kinds[@intFromEnum(o.k)] += 1;
        try std.testing.expectEqual(exec.Next.next, exec.step(&m, &o, 0x10000));
        const same = std.mem.eql(u64, cpu.r[0..31], &s.x) and std.mem.eql(u128, &cpu.v, &s.v) and
            std.mem.eql(u8, host_buf, t0_buf);
        if (!same) {
            std.debug.print("{x:0>8} ({t}): differs\n", .{ w, o.k });
            for (0..31) |i| if (cpu.r[i] != s.x[i]) std.debug.print("  x{d}: in {x} host {x} t0 {x}\n", .{ i, before.x[i], s.x[i], cpu.r[i] });
            for (0..32) |i| if (cpu.v[i] != s.v[i]) std.debug.print("  v{d}: host {x} t0 {x}\n", .{ i, s.v[i], cpu.v[i] });
            if (std.mem.indexOfDiff(u8, host_buf, t0_buf)) |d| std.debug.print("  memory differs at +{x}\n", .{d});
            return error.TestUnexpectedResult;
        }
    }
    var missing: usize = 0;
    inline for (@typeInfo(dec.Kind).@"enum".fields) |f| {
        const k: dec.Kind = @enumFromInt(f.value);
        const ldst = @intFromEnum(k) >= @intFromEnum(dec.Kind.ldr_x_o) and @intFromEnum(k) <= @intFromEnum(dec.Kind.stp_vq);
        if (ldst and kinds[f.value] == 0) {
            std.debug.print("no coverage: {t}\n", .{k});
            missing += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), missing);
}
