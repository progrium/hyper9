//! Checks h86's T0 against the host CPU: random instructions, each run
//! once by oracle.c on the real CPU in 32-bit mode and once by T0, from
//! the same registers, flags, memory, and x87/SSE state. Registers, the
//! flags the architecture defines, memory, the x87/MMX/SSE state, and
//! exceptions must match.
//!
//!     x86check gen <n> <seed> <cases> [int|x87|sse]   write n cases
//!     x86check cmp <cases> <answers>                  compare T0 with the oracle
//!
//! `int` (the default) draws integer instructions; `x87` draws D8-DF and
//! FWAIT, and `sse` MMX, SSE, and SSE2, each from random x87 stacks,
//! control and status words, XMM registers, and MXCSRs full of the values
//! floating point breaks on (zeros, denormals, infinities, NaNs, and
//! unsupported x87 encodings). The transcendentals (FSIN, FYL2X...) are
//! the x87's own approximations, so their results may differ in the last
//! few bits; RCPPS and RSQRTPS likewise, within their 12 bits.
//!
//! scripts/x86check.sh builds both and runs them (x86-64 Linux only).

const std = @import("std");
const vcpu = @import("vcpu");
const x86 = vcpu.x86;
const table = x86.table;
const dec = x86.decode;
const flags = x86.flags;
const Cpu = x86.cpu.Cpu;
const c = std.c;

const code_va: u32 = 0x4000_0000;
const data_va: u32 = 0x5000_0000;
const win_va: u32 = 0x5000_0e00;
const win_len = 1024;

const Case = extern struct {
    code: [16]u8,
    r: [8]u32,
    fl: u32,
    win: [win_len]u8,
    fx: [512]u8,
};

const Answer = extern struct {
    sig: u32,
    r: [8]u32,
    fl: u32,
    win: [win_len]u8,
    /// The exception's vector, when sig isn't 0.
    trap: u32,
    fx: [512]u8,
};

/// vmm.X86Extra's shape, which Cpu.getExtra and setExtra take: an FXSAVE
/// image (32-bit mode keeps FCS and FDS above FIP and FDP).
const Extra = struct {
    fx: extern struct {
        fcw: u16 = 0,
        fsw: u16 = 0,
        ftw: u8 = 0,
        _r1: u8 = 0,
        fop: u16 = 0,
        fip: u64 = 0,
        fdp: u64 = 0,
        mxcsr: u32 = 0,
        mxcsr_mask: u32 = 0,
        st: [8][16]u8 = @splat(@splat(0)),
        xmm: [16]u128 = @splat(0),
        _r2: [96]u8 = @splat(0),
    } = .{},
    tls: u64 = 0,
    gs: u64 = 0,
};

const Mode = enum { int, x87, sse };

fn allowed(op: table.Op, mode: Mode) bool {
    switch (mode) {
        .int => {},
        .x87 => return op == .x87 or op == .fwait,
        .sse => return op == .sse,
    }
    return switch (op) {
        .add, .@"or", .adc, .sbb, .@"and", .sub, .xor, .cmp, .@"test" => true,
        .inc, .dec, .not, .neg, .mul, .imul1, .imul, .div, .idiv => true,
        .rol, .ror, .rcl, .rcr, .shl, .shr, .sar, .shld, .shrd => true,
        .mov, .movzx, .movsx, .lea, .xchg, .cmpxchg, .cmpxchg8b, .xadd, .bswap, .cbw, .cwd, .xlat => true,
        .push, .pop, .pusha, .popa, .pushf => true,
        .setcc, .cmovcc, .bt, .bts, .btr, .btc, .bsf, .bsr => true,
        .lahf, .sahf, .clc, .stc, .cmc, .cld, .std, .salc => true,
        .movs, .cmps, .stos, .lods, .scas => true,
        .daa, .das, .aaa, .aas, .aam, .aad => true,
        else => false,
    };
}

const Mem = struct {
    code: *[4096]u8,
    data: *[8192]u8,

    pub fn translate(m: *Mem, va: u32, access: x86.cpu.Access) ?[*]u8 {
        if (va >= code_va and va < code_va + 4096) return if (access == .write) null else @ptrCast(&m.code[va - code_va]);
        if (va >= data_va and va < data_va + 8192) return if (access == .exec) null else @ptrCast(&m.data[va - data_va]);
        return null;
    }
};

fn die(msg: []const u8) noreturn {
    std.debug.print("x86check: {s}\n", .{msg});
    std.process.exit(2);
}

fn open(path: [*:0]const u8, mode: [*:0]const u8) *c.FILE {
    return c.fopen(path, mode) orelse die("can't open a file");
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = init.args.iterate();
    _ = args.next();
    const cmd = args.next() orelse die("usage: x86check gen|cmp ...");
    if (std.mem.eql(u8, cmd, "gen")) {
        const n = std.fmt.parseInt(u32, args.next() orelse die("n"), 10) catch die("n");
        const seed = std.fmt.parseInt(u64, args.next() orelse die("seed"), 10) catch die("seed");
        const out = open(args.next() orelse die("cases"), "wb");
        const mode = std.meta.stringToEnum(Mode, args.next() orelse "int") orelse die("mode");
        try gen(n, seed, out, mode);
        _ = c.fclose(out);
    } else if (std.mem.eql(u8, cmd, "cmp")) {
        const cf = open(args.next() orelse die("cases"), "rb");
        const af = open(args.next() orelse die("answers"), "rb");
        const bad = cmp(cf, af);
        if (bad != 0) std.process.exit(1);
    } else die("usage: x86check gen|cmp ...");
}

/// The table rows to draw from.
fn rows(mode: Mode) []const table.Row {
    const S = struct {
        var buf: [table.table.len]table.Row = undefined;
        var n: usize = 0;
    };
    if (S.n == 0) {
        for (table.table) |row| {
            if (allowed(row.e.op, mode)) {
                S.buf[S.n] = row;
                S.n += 1;
            }
        }
    }
    return S.buf[0..S.n];
}

fn edge(r: std.Random) u32 {
    return switch (r.uintLessThan(u8, 8)) {
        0 => 0,
        1 => 0xffff_ffff,
        2 => 0x8000_0000,
        3 => 0x7fff_ffff,
        4 => r.uintLessThan(u32, 64),
        5 => 0x80 + r.uintLessThan(u32, 3) -% 1,
        6 => 0x8000 + r.uintLessThan(u32, 3) -% 1,
        else => r.int(u32),
    };
}

fn gen(n: u32, seed: u64, out: *c.FILE, mode: Mode) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const r = prng.random();
    const rs = rows(mode);
    var made: u32 = 0;
    while (made < n) {
        const row = rs[r.uintLessThan(usize, rs.len)];
        var cs: Case = undefined;
        @memset(&cs.code, 0x90);
        var p: usize = 0;
        const e = row.e;
        const string = switch (e.op) {
            .movs, .cmps, .stos, .lods, .scas => true,
            else => false,
        };
        if (mode == .sse) {
            // The mandatory prefix: none, 66, F3, or F2.
            switch (r.uintLessThan(u8, 4)) {
                0 => {},
                1 => {
                    cs.code[p] = 0x66;
                    p += 1;
                },
                2 => {
                    cs.code[p] = 0xf3;
                    p += 1;
                },
                else => {
                    cs.code[p] = 0xf2;
                    p += 1;
                },
            }
        } else if (r.uintLessThan(u8, if (mode == .x87) 8 else 4) == 0 and e.op != .bswap) {
            cs.code[p] = 0x66;
            p += 1;
        }
        if (string and r.boolean()) {
            cs.code[p] = if (r.boolean()) 0xf3 else 0xf2;
            p += 1;
        }
        if (e.lock and r.uintLessThan(u8, 4) == 0) {
            cs.code[p] = 0xf0;
            p += 1;
        }
        if (row.opcode >= 0x0f00) {
            cs.code[p] = 0x0f;
            p += 1;
        }
        cs.code[p] = @truncate(row.opcode);
        p += 1;
        if (e.modrm) {
            const reg: u8 = if (row.ext) |x| x else r.uintLessThan(u8, 8);
            var mod: u8 = r.uintLessThan(u8, 4);
            if (row.mod == .mem and mod == 3) mod = r.uintLessThan(u8, 2) + 1;
            if (row.mod == .reg) mod = 3;
            const rm: u8 = r.uintLessThan(u8, 8);
            // No disp32-only forms: their address can't be steered.
            if (mod == 0 and rm == 5) mod = 1;
            cs.code[p] = (mod << 6) | (reg << 3) | rm;
            p += 1;
            if (mod != 3 and rm == 4) {
                var base: u8 = r.uintLessThan(u8, 8);
                if (base == 5 and mod == 0) base = 3;
                cs.code[p] = (r.uintLessThan(u8, 4) << 6) | (r.uintLessThan(u8, 8) << 3) | base;
                p += 1;
            }
        }
        // Displacement and immediates: random bytes.
        while (p < 16) : (p += 1) cs.code[p] = r.int(u8);
        var inst = dec.decode(&cs.code) catch continue;
        // Pad after the instruction.
        @memset(cs.code[inst.len..], 0x90);
        const disp_small = true;
        _ = disp_small;
        for (&cs.r) |*v| v.* = edge(r);
        cs.r[4] = win_va + 0x200;
        cs.fl = (r.int(u32) & (flags.arith | flags.DF)) | flags.res1;
        if (string) {
            cs.r[6] = win_va + 0x100 + r.uintLessThan(u32, 0x200);
            cs.r[7] = win_va + 0x100 + r.uintLessThan(u32, 0x200);
            cs.r[1] = r.uintLessThan(u32, 9);
        }
        if (e.op == .xlat) cs.r[3] = win_va + r.uintLessThan(u32, 0x200);
        if (inst.mem and e.op != .lea) {
            // Steer the address into the window: base = target - disp - index.
            var target = win_va + 0x80 + r.uintLessThan(u32, win_len - 0x100);
            // SSE's aligned forms (and FXSAVE) need 16, mostly.
            if (mode == .sse and r.uintLessThan(u8, 4) != 0) target &= ~@as(u32, 15);
            // FXSAVE and FSAVE images reach past the operand.
            if (mode != .int and target > win_va + win_len - 0x200 and r.boolean()) target -= 0x180;
            if (inst.index != dec.no_reg) cs.r[inst.index] = r.uintLessThan(u32, 16);
            if (inst.base == dec.no_reg) continue;
            if (inst.index == inst.base) continue;
            var idx: u32 = 0;
            if (inst.index != dec.no_reg) idx = cs.r[inst.index] << inst.scale;
            cs.r[inst.base] = target -% inst.disp -% idx;
            if (inst.base == 4 and (e.op == .push or e.op == .pop or e.op == .pusha or e.op == .popa or e.op == .pushf)) continue;
            // A BT with a register offset reaches beyond the operand.
            switch (e.op) {
                .bt, .bts, .btr, .btc => if (e.src == .G) {
                    if (inst.reg() == inst.base or inst.reg() == inst.index) continue;
                    cs.r[inst.reg()] = r.uintLessThan(u32, 512) -% 256;
                },
                else => {},
            }
        }
        // SHLD and SHRD of 16 bits by more than 16 are undefined.
        if ((e.op == .shld or e.op == .shrd) and inst.size == 2) {
            const count = (if (e.imm == .b) inst.imm else cs.r[1]) & 31;
            if (count > 16) continue;
        }
        r.bytes(&cs.win);
        fillFp(r, &cs, mode, &inst);
        if (c.fwrite(@ptrCast(&cs), @sizeOf(Case), 1, out) != 1) die("write");
        made += 1;
    }
}

fn cmp(cf: *c.FILE, af: *c.FILE) u32 {
    // X86CHECK_BRIEF=1: one line per difference, for sorting.
    const brief = c.getenv("X86CHECK_BRIEF") != null;
    var bad: u32 = 0;
    var total: u32 = 0;
    var code: [4096]u8 align(4096) = undefined;
    var data: [8192]u8 align(4096) = undefined;
    var cs: Case = undefined;
    var an: Answer = undefined;
    while (c.fread(@ptrCast(&cs), @sizeOf(Case), 1, cf) == 1) {
        if (c.fread(@ptrCast(&an), @sizeOf(Answer), 1, af) != 1) die("short answers");
        total += 1;
        @memset(&code, 0x90);
        @memcpy(code[0..16], &cs.code);
        code[16] = 0xcc; // int3 after the padding
        @memset(&data, 0);
        @memcpy(data[win_va - data_va ..][0..win_len], &cs.win);
        var m: Mem = .{ .code = &code, .data = &data };
        var cpu: Cpu = .{};
        cpu.r = cs.r;
        cpu.eip = code_va;
        cpu.fl.set(cs.fl | flags.IF);
        var ex: Extra = .{};
        @memcpy(std.mem.asBytes(&ex.fx), &cs.fx);
        cpu.setExtra(&ex);
        const inst = dec.decode(&cs.code) catch unreachable;
        const exit = x86.exec.step(&cpu, &m);
        cpu.getExtra(&ex);
        const t0fx: *const [512]u8 = std.mem.asBytes(&ex.fx);
        const fx = dec.effects(&inst);
        var mask: u32 = flags.arith | flags.DF;
        mask &= ~fx.flags_undefined;
        if (inst.op == .div or inst.op == .idiv) mask &= ~flags.arith;
        if (inst.op == .bt or inst.op == .bts or inst.op == .btr or inst.op == .btc) mask &= ~(flags.arith & ~flags.CF);
        var ok = true;
        var why: []const u8 = "";
        if (undefinedResult(&cs, &inst)) continue;
        if (an.sig != 0) {
            const got: ?u32 = if (exit) |x| switch (x) {
                .exception => |v| v,
                .fault => 14,
                else => null,
            } else null;
            if (got == null or got.? != an.trap) {
                ok = false;
                why = "exception";
            } else if (fxDiffers(t0fx, &an.fx, &inst)) |w| {
                ok = false;
                why = w;
            }
        } else if (exit != null) {
            ok = false;
            why = "unexpected exit";
        } else {
            if (!std.mem.eql(u32, &cpu.r, &an.r)) {
                ok = false;
                why = "registers";
            } else if ((cpu.fl.get() ^ an.fl) & mask != 0) {
                ok = false;
                why = "flags";
            } else if (!std.mem.eql(u8, data[win_va - data_va ..][0..win_len], &an.win)) {
                ok = false;
                why = "memory";
            } else if (fxDiffers(t0fx, &an.fx, &inst)) |w| {
                ok = false;
                why = w;
            }
        }
        if (!ok) {
            bad += 1;
            if (brief) {
                const sw = struct {
                    fn f(img: *const [512]u8) u16 {
                        return std.mem.readInt(u16, img[2..4], .little);
                    }
                };
                std.debug.print("{s}: {x} sw {x:0>4} {x:0>4} {x:0>4} cw {x:0>4} ftw {x:0>2}\n", .{ why, cs.code[0..inst.len], sw.f(&cs.fx), sw.f(t0fx), sw.f(&an.fx), std.mem.readInt(u16, cs.fx[0..2], .little), cs.fx[4] });
            } else if (bad <= 40) {
                std.debug.print("{s}: {t} {x}", .{ why, inst.op, cs.code[0..inst.len] });
                std.debug.print(" exit={any} sig={d} trap={d}\n", .{ exit, an.sig, an.trap });
                dump("in ", cs.r, cs.fl);
                dump("t0 ", cpu.r, cpu.fl.get() & mask);
                dump("cpu", an.r, an.fl & mask);
                if (inst.op == .x87 or inst.op == .sse or inst.op == .fwait) {
                    dumpFx("in ", &cs.fx);
                    dumpFx("t0 ", t0fx);
                    dumpFx("cpu", &an.fx);
                }
            }
        }
    }
    std.debug.print("x86check: {d} cases, {d} differ\n", .{ total, bad });
    return bad;
}

fn dump(what: []const u8, r: [8]u32, fl: u32) void {
    std.debug.print("  {s}", .{what});
    for (r) |v| std.debug.print(" {x:0>8}", .{v});
    std.debug.print(" fl={x}\n", .{fl});
}

// ---------------------------------------------------------------- x87 and SSE

fn put16(b: []u8, v: u16) void {
    std.mem.writeInt(u16, b[0..2], v, .little);
}

fn put32(b: []u8, v: u32) void {
    std.mem.writeInt(u32, b[0..4], v, .little);
}

/// An 80-bit value floating point trips on.
fn f80Val(r: std.Random) u80 {
    const sign: u80 = @as(u80, @intFromBool(r.boolean())) << 79;
    const top: u64 = 1 << 63;
    const v: u80 = switch (r.uintLessThan(u8, 20)) {
        0 => 0,
        1 => @as(u80, 0x3fff) << 64 | top,
        2 => @as(u80, 0x7fff) << 64 | top, // inf
        3 => @as(u80, 0x7fff) << 64 | top | (1 << 62) | (r.int(u64) >> 2), // QNaN
        4 => @as(u80, 0x7fff) << 64 | top | ((r.int(u64) >> 2) | 1), // SNaN
        5 => @as(u80, 0xffff) << 64 | top | (1 << 62), // indefinite
        6 => r.int(u64) >> 1, // denormal
        7 => @as(u80, 0x3fff - 70 + r.uintLessThan(u64, 140)) << 64 | top | (r.int(u64) >> 1),
        8, 9, 10 => @as(u80, 0x3fff - 8 + r.uintLessThan(u64, 24)) << 64 | top | (r.int(u64) >> 1),
        11 => @as(u80, 1 + r.uintLessThan(u64, 0x7ffe)) << 64 | top | (r.int(u64) >> 1),
        12 => blk: { // a small integer
            const k = r.uintLessThan(u64, 1000) + 1;
            const z: u6 = @intCast(@clz(k));
            break :blk @as(u80, 0x3fff + 63 - @as(u64, z)) << 64 | (k << z);
        },
        13 => @as(u80, 0x3fff + 50 + r.uintLessThan(u64, 20)) << 64 | top | (r.int(u64) >> 1),
        14 => @as(u80, 0x7ffe) << 64 | ~@as(u64, 0), // max
        15 => @as(u80, 1) << 64 | top | (r.int(u64) >> 40), // near the smallest normal
        16 => if (r.uintLessThan(u8, 4) == 0) @as(u80, 0x3fff) << 64 | (r.int(u64) >> 1) else @as(u80, 0x4000) << 64 | top, // unnormal, rarely
        17 => @as(u80, 0x4000) << 64 | 0xc90f_daa2_2168_c235, // pi
        18 => @as(u80, 0x3fff - 30 + r.uintLessThan(u64, 60)) << 64 | top | (r.int(u64) >> 1),
        else => @as(u80, 0x3ffe + r.uintLessThan(u64, 4)) << 64 | top | (r.int(u64) >> 1),
    };
    return v | sign;
}

fn f32Val(r: std.Random) u32 {
    const sign: u32 = @as(u32, @intFromBool(r.boolean())) << 31;
    const v: u32 = switch (r.uintLessThan(u8, 14)) {
        0 => 0,
        1 => 0x3f80_0000,
        2 => 0x7f80_0000,
        3 => 0x7fc0_0000 | (r.int(u32) & 0x3f_ffff),
        4 => 0x7f80_0000 | ((r.int(u32) & 0x3f_ffff) | 1),
        5 => r.int(u32) & 0x7f_ffff,
        6 => 0x7f7f_ffff,
        7 => 0x0080_0000 | (r.int(u32) & 0xff),
        8 => @bitCast(@as(f32, @floatFromInt(r.intRangeAtMost(i32, -100000, 100000)))),
        9 => @as(u32, 0x3f00_0000 + r.uintLessThan(u32, 0x0300_0000)) | (r.int(u32) & 0x7f_ffff),
        10 => @as(u32, 0x4e80_0000 + r.uintLessThan(u32, 0x0200_0000)), // near 2^31
        11 => (@as(u32, 1 + r.uintLessThan(u32, 0x30)) << 23) | (r.int(u32) & 0x7f_ffff), // small
        else => r.int(u32) & 0x7fff_ffff,
    };
    return v | sign;
}

fn f64Val(r: std.Random) u64 {
    const sign: u64 = @as(u64, @intFromBool(r.boolean())) << 63;
    const frac = r.int(u64) & 0xf_ffff_ffff_ffff;
    const v: u64 = switch (r.uintLessThan(u8, 14)) {
        0 => 0,
        1 => 0x3ff0_0000_0000_0000,
        2 => 0x7ff0_0000_0000_0000,
        3 => 0x7ff8_0000_0000_0000 | (frac >> 1),
        4 => 0x7ff0_0000_0000_0000 | ((frac >> 1) | 1),
        5 => frac,
        6 => 0x7fef_ffff_ffff_ffff,
        7 => 0x0010_0000_0000_0000 | (frac & 0xff),
        8 => @bitCast(@as(f64, @floatFromInt(r.intRangeAtMost(i32, -100000, 100000)))),
        9 => (@as(u64, 0x3f0 + r.uintLessThan(u64, 0x30)) << 52) | frac,
        10 => (@as(u64, 0x41d + r.uintLessThan(u64, 3)) << 52) | frac, // near 2^31
        11 => (@as(u64, 1 + r.uintLessThan(u64, 0x40)) << 52) | frac,
        12 => (@as(u64, 0x380 + r.uintLessThan(u64, 0x10)) << 52) | frac, // f32's edges
        else => r.int(u64) & 0x7fff_ffff_ffff_ffff,
    };
    return v | sign;
}

/// A random XMM (or MMX) value: lanes of binary32, binary64, or bits.
fn vecVal(r: std.Random) u128 {
    var v: u128 = 0;
    switch (r.uintLessThan(u8, 4)) {
        0 => for (0..4) |k| {
            v |= @as(u128, f32Val(r)) << @intCast(32 * k);
        },
        1 => for (0..2) |k| {
            v |= @as(u128, f64Val(r)) << @intCast(64 * k);
        },
        2 => for (0..8) |k| {
            const lane: u16 = switch (r.uintLessThan(u8, 6)) {
                0 => 0,
                1 => 0xffff,
                2 => 0x8000,
                3 => 0x7fff,
                4 => 0x80 + r.uintLessThan(u16, 3) -% 1,
                else => r.int(u16),
            };
            v |= @as(u128, lane) << @intCast(16 * k);
        },
        else => v = r.int(u128),
    }
    return v;
}

/// The x87 and SSE state of a case, and an interesting value at its
/// memory operand.
fn fillFp(r: std.Random, cs: *Case, mode: Mode, inst: *const dec.Inst) void {
    @memset(&cs.fx, 0);
    const fx = &cs.fx;
    put16(fx[0..], 0x037f);
    put32(fx[24..], 0x1f80);
    if (mode == .int) return;
    // The control word: rounding, precision, and now and then IM, DM,
    // ZM, or PM unmasked. (Unmasked OE and UE get no exponent wrap here.)
    var cw: u16 = 0x0040 | 0x3f;
    cw |= @as(u16, r.uintLessThan(u16, 4)) << 10;
    cw |= @as(u16, switch (r.uintLessThan(u8, 4)) {
        0 => 0,
        1 => 2,
        else => 3,
    }) << 8;
    if (r.uintLessThan(u8, 6) == 0) cw &= ~(r.int(u16) & 0x27);
    var sw: u16 = 0;
    if (r.uintLessThan(u8, 4) == 0) sw |= r.int(u16) & 0x3f;
    sw |= r.int(u16) & 0x4700; // C0-C3
    if (sw & ~cw & 0x3f != 0) sw |= 0x8080 else if (r.uintLessThan(u8, 3) != 0) sw &= ~@as(u16, 0x3f & ~cw);
    if (sw & ~cw & 0x3f != 0) sw |= 0x8080;
    const top: u16 = r.uintLessThan(u16, 8);
    sw |= top << 11;
    put16(fx[0..], cw);
    put16(fx[2..], sw);
    // Tags: mostly full, or a few registers in use.
    fx[4] = switch (r.uintLessThan(u8, 4)) {
        0 => 0xff,
        1 => r.int(u8),
        2 => blk: {
            // ST(0)..ST(k-1) in use.
            const k = r.uintLessThan(u4, 9);
            var t: u8 = 0;
            for (0..k) |j| t |= @as(u8, 1) << @intCast((top + j) & 7);
            break :blk t;
        },
        else => ~(@as(u8, 1) << @intCast((top + 7) & 7)),
    };
    for (0..8) |k| std.mem.writeInt(u80, fx[32 + 16 * k ..][0..10], f80Val(r), .little);
    // MXCSR: rounding, DAZ, FTZ, sticky flags, and now and then unmasked
    // exceptions.
    var mx: u32 = 0x1f80;
    mx |= @as(u32, r.uintLessThan(u32, 4)) << 13;
    if (r.uintLessThan(u8, 4) == 0) mx |= 1 << 6;
    if (r.uintLessThan(u8, 4) == 0) mx |= 1 << 15;
    if (r.uintLessThan(u8, 4) == 0) mx |= r.int(u32) & 0x3f;
    if (r.uintLessThan(u8, 6) == 0) mx &= ~((r.int(u32) & 0x3f) << 7);
    put32(fx[24..], mx);
    for (0..8) |k| std.mem.writeInt(u128, fx[160 + 16 * k ..][0..16], vecVal(r), .little);
    // An interesting value at the operand.
    if (inst.mem) {
        const off = targetOf(cs, inst) -% win_va;
        if (off < win_len - 16) {
            const w = cs.win[off..];
            switch (r.uintLessThan(u8, 5)) {
                0 => put32(w, f32Val(r)),
                1 => std.mem.writeInt(u64, w[0..8], f64Val(r), .little),
                2 => std.mem.writeInt(u80, w[0..10], f80Val(r), .little),
                3 => std.mem.writeInt(u128, w[0..16], vecVal(r), .little),
                else => {},
            }
        }
    }
}

fn targetOf(cs: *const Case, inst: *const dec.Inst) u32 {
    var a = inst.disp;
    if (inst.base != dec.no_reg) a +%= cs.r[inst.base];
    if (inst.index != dec.no_reg) a +%= cs.r[inst.index] << inst.scale;
    return a;
}

/// D9 F0-FF's approximations, and FYL2X's kin: compared to a few ulps.
fn approximate(inst: *const dec.Inst) bool {
    if (inst.op != .x87 or inst.mem or inst.opcode != 0xd9) return false;
    return switch (inst.modrm) {
        0xf0, 0xf1, 0xf2, 0xf3, 0xf9, 0xfb, 0xfe, 0xff => true,
        else => false,
    };
}

/// RCPPS, RCPSS, RSQRTPS, and RSQRTSS.
fn approximateSse(inst: *const dec.Inst) bool {
    return inst.op == .sse and (inst.opcode == 0x0f52 or inst.opcode == 0x0f53);
}

fn close80(a: []const u8, b: []const u8) bool {
    const x = std.mem.readInt(u80, a[0..10], .little);
    const y = std.mem.readInt(u80, b[0..10], .little);
    if (x == y) return true;
    if ((x >> 79) != (y >> 79)) return false;
    const d = if (x > y) x - y else y - x;
    return d <= 64;
}

fn close32(a: u32, b: u32) bool {
    if ((a >> 31) != (b >> 31)) return false;
    const d = if (a > b) a - b else b - a;
    return d <= 1 << 12;
}

/// What differs between T0's FXSAVE image and the CPU's, if anything:
/// not FOP, FIP, or FDP, which this CPU may not keep, nor MXCSR_MASK.
fn fxDiffers(t: *const [512]u8, h: *const [512]u8, inst: *const dec.Inst) ?[]const u8 {
    const approx = approximate(inst);
    var sw_mask: u16 = 0xffff;
    if (approx) sw_mask &= ~@as(u16, 0x0230); // C1, UE, PE
    const ts = std.mem.readInt(u16, t[2..4], .little);
    const hs = std.mem.readInt(u16, h[2..4], .little);
    if (!std.mem.eql(u8, t[0..2], h[0..2])) return "fcw";
    if ((ts ^ hs) & sw_mask != 0) return "fsw";
    if (t[4] != h[4]) return "ftw";
    if (!std.mem.eql(u8, t[24..28], h[24..28])) return "mxcsr";
    for (0..8) |k| {
        const a = t[32 + 16 * k ..][0..10];
        const b = h[32 + 16 * k ..][0..10];
        if (approx) {
            if (!close80(a, b)) return "st";
        } else if (!std.mem.eql(u8, a, b)) return "st";
    }
    if (approximateSse(inst)) {
        for (0..32) |k| {
            const a = std.mem.readInt(u32, t[160 + 4 * k ..][0..4], .little);
            const b = std.mem.readInt(u32, h[160 + 4 * k ..][0..4], .little);
            if (!close32(a, b)) return "xmm";
        }
    } else if (!std.mem.eql(u8, t[160..288], h[160..288])) return "xmm";
    return null;
}

fn dumpFx(what: []const u8, fx: *const [512]u8) void {
    std.debug.print("  {s} fcw={x:0>4} fsw={x:0>4} ftw={x:0>2} mxcsr={x:0>8}\n", .{
        what,
        std.mem.readInt(u16, fx[0..2], .little),
        std.mem.readInt(u16, fx[2..4], .little),
        fx[4],
        std.mem.readInt(u32, fx[24..28], .little),
    });
    std.debug.print("     ", .{});
    for (0..8) |k| std.debug.print(" {x:0>20}", .{std.mem.readInt(u80, fx[32 + 16 * k ..][0..10], .little)});
    std.debug.print("\n     ", .{});
    for (0..8) |k| std.debug.print(" {x:0>32}", .{std.mem.readInt(u128, fx[160 + 16 * k ..][0..16], .little)});
    std.debug.print("\n", .{});
}

/// FYL2XP1 outside |x| < 1 - sqrt(2)/2, where the x87 defines no result.
fn undefinedResult(cs: *const Case, inst: *const dec.Inst) bool {
    if (inst.op != .x87 or inst.mem or inst.opcode != 0xd9 or inst.modrm != 0xf9) return false;
    const top: u16 = (std.mem.readInt(u16, cs.fx[2..4], .little) >> 11) & 7;
    _ = top;
    const v = std.mem.readInt(u80, cs.fx[32..42], .little);
    const e: u16 = @truncate((v >> 64) & 0x7fff);
    return e >= 0x3ffd and e != 0x7fff;
}
