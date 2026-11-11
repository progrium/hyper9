//! Checks h86's T0 against the host CPU: random instructions, each run
//! once by oracle.c on the real CPU in 32-bit mode and once by T0, from
//! the same registers, flags, memory, and x87/SSE state. Registers, the
//! flags the architecture defines, memory, the x87/MMX/SSE state, and
//! exceptions must match.
//!
//!     x86check gen <n> <seed> <cases> [int|x87|sse]   write n cases
//!     x86check cmp <cases> <answers>                  compare T0 with the oracle
//!     x86check gen64 <n> <seed> <cases> [int|x87|sse] the same in long mode,
//!     x86check cmp64 <cases> <answers>                for hx64 and oracle64.c
//!
//! `int` (the default) draws integer instructions; `x87` draws D8-DF and
//! FWAIT, and `sse` MMX, SSE, and SSE2, each from random x87 stacks,
//! control and status words, XMM registers, and MXCSRs full of the values
//! floating point breaks on (zeros, denormals, infinities, NaNs, and
//! unsupported x87 encodings). The transcendentals (FSIN, FYL2X...) are
//! the x87's own approximations, so their results may differ in the last
//! few bits; RCPPS and RSQRTPS likewise, within their 12 bits.
//!
//! scripts/x86check.sh builds both and runs them (x86-64 Linux only), and
//! `zig build x64check` does the same for long mode (see "long mode",
//! below).

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
    } else if (std.mem.eql(u8, cmd, "gen64")) {
        const n = std.fmt.parseInt(u32, args.next() orelse die("n"), 10) catch die("n");
        const seed = std.fmt.parseInt(u64, args.next() orelse die("seed"), 10) catch die("seed");
        const out = open(args.next() orelse die("cases"), "wb");
        const mode = std.meta.stringToEnum(Mode, args.next() orelse "int") orelse die("mode");
        gen64(n, seed, out, mode);
        _ = c.fclose(out);
    } else if (std.mem.eql(u8, cmd, "cmp64")) {
        const cf = open(args.next() orelse die("cases"), "rb");
        const af = open(args.next() orelse die("answers"), "rb");
        const bad = cmp64(cf, af);
        if (bad != 0) std.process.exit(1);
    } else die("usage: x86check gen|cmp|gen64|cmp64 ...");
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
        if (mode == .sse and beyondSse2(cs.code[0], row.opcode)) continue;
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
        // MASKMOVQ and MASKMOVDQU store to EDI, which may fault on a zero
        // mask or not, as the CPU likes; keep it in the window.
        if (mode == .sse and row.opcode == 0x0ff7) cs.r[7] = win_va + r.uintLessThan(u32, 0x200);
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
        fillFp(r, &cs.fx, &cs.win, mode, if (inst.mem) targetOf(&cs, &inst) -% win_va else null, 8);
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
        if (undefinedResult(&cs.fx, Shape.of(&inst))) continue;
        if (an.sig != 0) {
            const got: ?u32 = if (exit) |x| switch (x) {
                .exception => |v| v,
                .fault => 14,
                else => null,
            } else null;
            if (got == null or got.? != an.trap) {
                ok = false;
                why = "exception";
            } else if (fxDiffers(t0fx, &an.fx, Shape.of(&inst), 8)) |w| {
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
            } else if (fxDiffers(t0fx, &an.fx, Shape.of(&inst), 8)) |w| {
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

/// The x87 and SSE state of a case (`nxmm` XMM registers), and an
/// interesting value at its memory operand, `off` bytes into the window.
fn fillFp(r: std.Random, fx: *[512]u8, win: *[win_len]u8, mode: Mode, off: ?u64, nxmm: usize) void {
    @memset(fx, 0);
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
    for (0..nxmm) |k| std.mem.writeInt(u128, fx[160 + 16 * k ..][0..16], vecVal(r), .little);
    // An interesting value at the operand.
    if (off) |o| {
        if (o < win_len - 16) {
            const w = win[@intCast(o)..];
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

/// What the comparison needs to know of an instruction, in either mode.
const Shape = struct {
    op: table.Op,
    mem: bool,
    opcode: u16,
    modrm: u8,

    fn of(i: *const dec.Inst) Shape {
        return .{ .op = i.op, .mem = i.mem, .opcode = i.opcode, .modrm = i.modrm };
    }
};

/// D9 F0-FF's approximations, and FYL2X's kin: compared to a few ulps.
fn approximate(inst: Shape) bool {
    if (inst.op != .x87 or inst.mem or inst.opcode != 0xd9) return false;
    return switch (inst.modrm) {
        0xf0, 0xf1, 0xf2, 0xf3, 0xf9, 0xfb, 0xfe, 0xff => true,
        else => false,
    };
}

/// RCPPS, RCPSS, RSQRTPS, and RSQRTSS.
fn approximateSse(inst: Shape) bool {
    return inst.op == .sse and (inst.opcode == 0x0f52 or inst.opcode == 0x0f53);
}

fn close80(a: []const u8, b: []const u8) bool {
    var x = std.mem.readInt(u80, a[0..10], .little);
    var y = std.mem.readInt(u80, b[0..10], .little);
    if (x == y) return true;
    if ((x >> 79) != (y >> 79)) return false;
    // Without the explicit integer bit, the bits count in ulps across
    // a change of exponent.
    x = (x >> 64 & 0x7fff) << 63 | (x & 0x7fff_ffff_ffff_ffff);
    y = (y >> 64 & 0x7fff) << 63 | (y & 0x7fff_ffff_ffff_ffff);
    const d = if (x > y) x - y else y - x;
    return d <= 64;
}

fn close32(a: u32, b: u32) bool {
    if ((a >> 31) != (b >> 31)) return false;
    const d = if (a > b) a - b else b - a;
    // Intel's bound: a relative error of 1.5 * 2^-12.
    return d <= 3 << 11;
}

/// What differs between T0's FXSAVE image and the CPU's, if anything:
/// not FOP, FIP, or FDP, which this CPU may not keep, nor MXCSR_MASK.
fn fxDiffers(t: *const [512]u8, h: *const [512]u8, inst: Shape, nxmm: usize) ?[]const u8 {
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
        for (0..4 * nxmm) |k| {
            const a = std.mem.readInt(u32, t[160 + 4 * k ..][0..4], .little);
            const b = std.mem.readInt(u32, h[160 + 4 * k ..][0..4], .little);
            if (!close32(a, b)) return "xmm";
        }
    } else if (!std.mem.eql(u8, t[160..][0 .. 16 * nxmm], h[160..][0 .. 16 * nxmm])) return "xmm";
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
/// SSE3 and later forms the host runs but h86's CPUID leaves out, which
/// it raises #UD for: MOVDDUP, MOVSLDUP, MOVSHDUP, HADD, HSUB, ADDSUB,
/// LDDQU, and 66 0F AE's CLWB and CLFLUSHOPT.
fn beyondSse2(pfx: u8, opcode: u16) bool {
    return switch (opcode) {
        0x0f12 => pfx == 0xf2 or pfx == 0xf3,
        0x0f16 => pfx == 0xf3,
        0x0f7c, 0x0f7d, 0x0fd0 => pfx == 0x66 or pfx == 0xf2,
        0x0ff0 => pfx == 0xf2,
        0x0fae => pfx == 0x66,
        else => false,
    };
}

fn undefinedResult(fx: *const [512]u8, inst: Shape) bool {
    if (inst.op != .x87 or inst.mem or inst.opcode != 0xd9 or inst.modrm != 0xf9) return false;
    const v = std.mem.readInt(u80, fx[32..42], .little);
    const e: u16 = @truncate((v >> 64) & 0x7fff);
    return e >= 0x3ffd and e != 0x7fff;
}

// ---------------------------------------------------------------- long mode

// hx64's T0 against the host in 64-bit mode (oracle64.c). The generator
// encodes each case itself, from the 386 table's rows with long mode's
// encoding on top, so it doesn't lean on the long-mode decoder it checks:
// REX (W, and R, X, and B over every register field, and a bare 0x40 for
// SPL..DIL), 64-bit and 16-bit operands, RIP-relative and absolute disp32
// addressing, 67's 32-bit addressing (with garbage above the 32 bits it
// uses), moffs64, MOV r64 imm64, MOVSXD, CMPXCHG16B, GS overrides with a
// base, ignored DS, ES, CS, and SS overrides, and the opcodes long mode
// removes, which must raise #UD. FS isn't used: the oracle runs on the
// host's FS (its TLS).

const Notes = extern struct {
    /// The RFLAGS bits the instruction leaves undefined.
    undef: u32,
    /// The table row, or 0xffff for MOVSXD.
    row: u16,
    modrm: u8,
    mem: u8,
    _pad: [8]u8 = @splat(0),
};

const Case64 = extern struct {
    code: [16]u8,
    r: [16]u64,
    fl: u64,
    gs_base: u64,
    win: [win_len]u8,
    fx: [512]u8,
    notes: Notes,
};

const Answer64 = extern struct {
    sig: u32,
    trap: u32,
    r: [16]u64,
    fl: u64,
    win: [win_len]u8,
    fx: [512]u8,
};

comptime {
    std.debug.assert(@sizeOf(Case64) == 16 + 128 + 16 + win_len + 512 + 16);
    std.debug.assert(@sizeOf(Answer64) == 8 + 128 + 8 + win_len + 512);
}

const Cpu64 = x86.cpu.Cpu64;

const Mem64 = struct {
    code: *[4096]u8,
    data: *[8192]u8,

    pub fn translate(m: *Mem64, va: u64, access: x86.cpu.Access) ?[*]u8 {
        if (va >= code_va and va < code_va + 4096) return if (access == .write) null else @ptrCast(&m.code[va - code_va]);
        if (va >= data_va and va < data_va + 8192) return if (access == .exec) null else @ptrCast(&m.data[va - data_va]);
        return null;
    }
};

/// Opcodes long mode removes: #UD there.
fn removed64(opcode: u16) bool {
    return switch (opcode) {
        0x06, 0x07, 0x0e, 0x16, 0x17, 0x1e, 0x1f, 0x27, 0x2f, 0x37, 0x3f => true,
        0x60, 0x61, 0x62, 0x9a, 0xc4, 0xc5, 0xce, 0xd4, 0xd5, 0xd6, 0xea => true,
        else => false,
    };
}

/// The rows long mode draws from: the 386's, but INC and DEC's 40-4F
/// (REX there) and far pointers.
fn rows64(mode: Mode) []const table.Row {
    const S = struct {
        var buf: [table.table.len]table.Row = undefined;
        var n: [3]usize = .{ 0, 0, 0 };
        var done: [3]bool = .{ false, false, false };
    };
    const m = @intFromEnum(mode);
    if (!S.done[m]) {
        S.done[m] = true;
        for (rows(mode)) |row| {
            if (row.opcode >= 0x40 and row.opcode <= 0x4f) continue;
            if (row.e.imm == .ptr) continue;
            S.buf[S.n[m]] = row;
            S.n[m] += 1;
        }
    }
    return S.buf[0..S.n[m]];
}

fn edge64(r: std.Random) u64 {
    return switch (r.uintLessThan(u8, 12)) {
        0 => 0,
        1 => 0xffff_ffff_ffff_ffff,
        2 => 0x8000_0000_0000_0000,
        3 => 0x7fff_ffff_ffff_ffff,
        4 => r.uintLessThan(u64, 64),
        5 => 0x80 + r.uintLessThan(u64, 3) -% 1,
        6 => 0x8000 + r.uintLessThan(u64, 3) -% 1,
        7 => 0x8000_0000 + r.uintLessThan(u64, 3) -% 1,
        8 => 0xffff_ffff,
        9 => @as(u64, r.int(u32)),
        10 => @as(u64, r.int(u32)) << 32,
        else => r.int(u64),
    };
}

/// Random bits above the low 32, for registers 67's addressing reads
/// only the low half of.
fn garbage(r: std.Random, v: u64) u64 {
    return (v & 0xffff_ffff) | (if (r.boolean()) @as(u64, r.int(u32)) << 32 else 0);
}

/// The flags `op` leaves undefined, given its operand size and count.
fn undefFlags64(op: table.Op, size: u8, count: ?u64) u32 {
    const A = flags.arith;
    return switch (op) {
        .mul, .imul1, .imul => flags.SF | flags.ZF | flags.AF | flags.PF,
        .shl, .shr, .sar, .shld, .shrd => blk: {
            const n = (count orelse 0xff) & @as(u64, if (size == 8) 63 else 31);
            if (n == 0) break :blk 0;
            break :blk flags.AF | (if (n != 1) flags.OF else 0);
        },
        .rol, .ror, .rcl, .rcr => blk: {
            const n = (count orelse 0xff) & @as(u64, if (size == 8) 63 else 31);
            break :blk if (n != 1) flags.OF else 0;
        },
        .bsf, .bsr => A & ~flags.ZF,
        .div, .idiv => A,
        .bt, .bts, .btr, .btc => A & ~flags.CF,
        else => 0,
    };
}

fn gen64(n: u32, seed: u64, out: *c.FILE, mode: Mode) void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const r = prng.random();
    const rs = rows64(mode);
    const movsxd: table.Row = .{ .opcode = 0x63, .e = .{ .op = .movsx, .modrm = true, .size = .v, .dst = .G, .src = .E } };
    var made: u32 = 0;
    while (made < n) {
        var row_ix: u16 = @intCast(r.uintLessThan(usize, rs.len));
        var row = rs[row_ix];
        if (mode == .int and r.uintLessThan(u8, 40) == 0) {
            row = movsxd;
            row_ix = 0xffff;
        }
        const e = row.e;
        var cs: Case64 = undefined;
        @memset(&cs.code, 0x90);
        const string = switch (e.op) {
            .movs, .cmps, .stos, .lods, .scas => true,
            else => false,
        };
        // Prefixes, in a random order but the mandatory one last.
        var pfx: [6]u8 = undefined;
        var np: usize = 0;
        var o16 = false;
        var mandatory: u8 = 0;
        if (mode == .sse) {
            mandatory = switch (r.uintLessThan(u8, 4)) {
                0 => 0,
                1 => 0x66,
                2 => 0xf3,
                else => 0xf2,
            };
            o16 = mandatory == 0x66;
        } else if (r.uintLessThan(u8, if (mode == .x87) 8 else 4) == 0 and e.op != .bswap) {
            pfx[np] = 0x66;
            np += 1;
            o16 = true;
        }
        if (string and r.boolean()) {
            pfx[np] = if (r.boolean()) 0xf3 else 0xf2;
            np += 1;
        }
        if (e.lock and r.uintLessThan(u8, 4) == 0) {
            pfx[np] = 0xf0;
            np += 1;
        }
        const a32 = r.uintLessThan(u8, 8) == 0;
        if (a32) {
            pfx[np] = 0x67;
            np += 1;
        }
        const gs = r.uintLessThan(u8, 6) == 0;
        if (gs) {
            pfx[np] = 0x65;
            np += 1;
        } else if (r.uintLessThan(u8, 16) == 0) {
            const ignored = [_]u8{ 0x26, 0x2e, 0x36, 0x3e };
            pfx[np] = ignored[r.uintLessThan(usize, 4)];
            np += 1;
        }
        r.shuffle(u8, pfx[0..np]);
        if (mandatory != 0) {
            pfx[np] = mandatory;
            np += 1;
        }
        // REX: W, then R, X, and B as the fields need.
        var w = switch (mode) {
            .int => r.boolean(),
            .sse => r.uintLessThan(u8, 4) == 0,
            .x87 => r.uintLessThan(u8, 8) == 0,
        };
        if (row_ix == 0xffff) w = r.uintLessThan(u8, 8) != 0;
        var rex_r: u8 = r.int(u1);
        var rex_x: u8 = r.int(u1);
        var rex_b: u8 = r.int(u1);
        if (r.uintLessThan(u8, 4) == 0) {
            rex_r = 0;
            rex_x = 0;
            rex_b = 0;
        }
        const bare = r.uintLessThan(u8, 4) == 0;
        // Operand size: 8 with REX.W, 2 with 66, else 4; a byte form's 1.
        var size: u8 = if (w) 8 else if (o16) 2 else 4;
        if (e.size == .b) size = 1;
        if (e.size == .w) size = 2;
        if (e.d64 or e.op == .push or e.op == .pop or e.op == .pushf) size = if (o16) 2 else 8;
        // Opcode, ModRM, SIB, displacement.
        var body: [16]u8 = undefined;
        var nb: usize = 0;
        if (row.opcode >= 0x0f00) {
            body[nb] = 0x0f;
            nb += 1;
        }
        body[nb] = @truncate(row.opcode);
        // B8+r, 50+r, ...: the register is in the opcode, extended by B.
        nb += 1;
        var mem = false;
        var rip_rel = false;
        var base: ?u4 = null;
        var index: ?u4 = null;
        var scale: u2 = 0;
        var disp_at: usize = 0;
        var disp_len: usize = 0;
        var modrm: u8 = 0;
        var reg_field: u4 = 0;
        var rm_field: u4 = 0;
        if (e.modrm) {
            const reg: u8 = if (row.ext) |x| x else r.uintLessThan(u8, 8);
            var mod: u8 = r.uintLessThan(u8, 4);
            if (row.mod == .mem and mod == 3) mod = r.uintLessThan(u8, 2) + 1;
            if (row.mod == .reg) mod = 3;
            const rm: u8 = r.uintLessThan(u8, 8);
            modrm = (mod << 6) | (reg << 3) | rm;
            body[nb] = modrm;
            nb += 1;
            reg_field = @intCast(reg | (rex_r << 3));
            rm_field = @intCast(rm | (rex_b << 3));
            if (mod != 3) {
                mem = true;
                if (rm == 4) {
                    var sbase: u8 = r.uintLessThan(u8, 8);
                    const sidx: u8 = r.uintLessThan(u8, 8);
                    scale = r.int(u2);
                    if (sbase == 5 and mod == 0 and r.boolean()) sbase = 3;
                    body[nb] = (@as(u8, scale) << 6) | (sidx << 3) | sbase;
                    nb += 1;
                    if (!(sbase == 5 and mod == 0)) base = @intCast(sbase | (rex_b << 3));
                    if (!(sidx == 4 and rex_x == 0)) index = @intCast(sidx | (rex_x << 3));
                    if (sbase == 5 and mod == 0) disp_len = 4;
                } else if (rm == 5 and mod == 0) {
                    rip_rel = true;
                    disp_len = 4;
                } else base = rm_field;
                if (mod == 1) disp_len = 1;
                if (mod == 2) disp_len = 4;
                disp_at = nb;
                var k: usize = 0;
                while (k < disp_len) : (k += 1) {
                    body[nb] = r.int(u8);
                    nb += 1;
                }
            }
        } else if (row.opcode < 0x100 and (e.dst == .Z or e.src == .Z)) {
            rm_field = @intCast((row.opcode & 7) | (@as(u16, rex_b) << 3));
        }
        // The immediate (or moffs).
        const moffs = e.dst == .O or e.src == .O;
        var imm_at = nb;
        var imm_len: usize = switch (e.imm) {
            .none => 0,
            .b, .bs => 1,
            .w => 2,
            .wb => 3,
            .v => if (o16) 2 else if (w and row.opcode >= 0xb8 and row.opcode <= 0xbf) @as(usize, 8) else 4,
            .ptr => unreachable,
        };
        if (moffs) {
            mem = true;
            imm_len = if (a32) 4 else 8;
        }
        imm_at = nb;
        {
            var k: usize = 0;
            while (k < imm_len) : (k += 1) {
                body[nb] = r.int(u8);
                nb += 1;
            }
        }
        const need_rex = w or rex_r != 0 or rex_x != 0 or rex_b != 0 or bare;
        const total = np + @intFromBool(need_rex) + nb;
        if (total > 15) continue;
        var p: usize = 0;
        @memcpy(cs.code[0..np], pfx[0..np]);
        p = np;
        if (need_rex) {
            cs.code[p] = 0x40 | (@as(u8, @intFromBool(w)) << 3) | (rex_r << 2) | (rex_x << 1) | rex_b;
            p += 1;
        }
        const body_at = p;
        @memcpy(cs.code[p..][0..nb], body[0..nb]);
        p += nb;
        const len = p;
        if (mode == .sse and beyondSse2(mandatory, row.opcode)) continue;
        // RDFSBASE and friends (F3 0F AE /0-/3 with a register) would
        // move the oracle's own FS.
        if (row.opcode == 0x0fae and mandatory == 0xf3) continue;
        for (&cs.r) |*v| v.* = edge64(r);
        cs.r[4] = win_va + 0x200;
        cs.fl = (r.int(u32) & (flags.arith | flags.DF)) | flags.res1;
        cs.gs_base = 0;
        if (string) {
            cs.r[6] = win_va + 0x100 + r.uintLessThan(u32, 0x200);
            cs.r[7] = win_va + 0x100 + r.uintLessThan(u32, 0x200);
            cs.r[1] = r.uintLessThan(u32, 9);
            if (a32) for ([_]usize{ 1, 6, 7 }) |k| {
                cs.r[k] = garbage(r, cs.r[k]);
            };
        }
        if (e.op == .xlat) {
            cs.r[3] = win_va + r.uintLessThan(u32, 0x200);
            if (a32) cs.r[3] = garbage(r, cs.r[3]);
        }
        if (mode == .sse and row.opcode == 0x0ff7) {
            cs.r[7] = win_va + r.uintLessThan(u32, 0x200);
            if (a32) cs.r[7] = garbage(r, cs.r[7]);
        }
        var target: ?u64 = null;
        if (mem and e.op != .lea) {
            var t = win_va + 0x80 + r.uintLessThan(u32, win_len - 0x100);
            if (mode == .sse and r.uintLessThan(u8, 4) != 0) t &= ~@as(u32, 15);
            if (e.op == .cmpxchg8b and w and r.uintLessThan(u8, 4) != 0) t &= ~@as(u32, 15);
            if (mode != .int and t > win_va + win_len - 0x200 and r.boolean()) t -= 0x180;
            target = t;
            // The address before the segment base.
            var ea: u64 = t;
            if (gs) {
                // A user address (arch_prctl refuses others): small, or
                // anywhere below the top of the lower half.
                cs.gs_base = if (a32 or r.boolean()) r.uintLessThan(u64, 0x1000) * 16 else r.uintLessThan(u64, 0x7fff_ffff_f000);
                ea = @as(u64, t) -% cs.gs_base;
            }
            if (a32 and ea > 0xffff_ffff) continue;
            if (moffs) {
                var b: [8]u8 = undefined;
                std.mem.writeInt(u64, &b, ea, .little);
                @memcpy(cs.code[body_at + imm_at ..][0..imm_len], b[0..imm_len]);
            } else {
                var idx: u64 = 0;
                if (index) |x| {
                    cs.r[x] = r.uintLessThan(u64, 16);
                    if (a32) cs.r[x] = garbage(r, cs.r[x]);
                    idx = (cs.r[x] & (if (a32) @as(u64, 0xffff_ffff) else ~@as(u64, 0))) << scale;
                }
                if (rip_rel) {
                    const next: u64 = code_va + len;
                    const d: i64 = @bitCast(ea -% next);
                    if (d < std.math.minInt(i32) or d > std.math.maxInt(i32)) continue;
                    std.mem.writeInt(i32, cs.code[body_at + disp_at ..][0..4], @intCast(d), .little);
                } else if (base) |b| {
                    if (index != null and index.? == b) continue;
                    const disp: u64 = switch (disp_len) {
                        0 => 0,
                        1 => @bitCast(@as(i64, @as(i8, @bitCast(cs.code[body_at + disp_at])))),
                        else => @bitCast(@as(i64, std.mem.readInt(i32, cs.code[body_at + disp_at ..][0..4], .little))),
                    };
                    cs.r[b] = ea -% disp -% idx;
                    if (a32) cs.r[b] = garbage(r, cs.r[b]);
                    if (b == 4 and (e.op == .push or e.op == .pop or e.op == .pusha or e.op == .popa or e.op == .pushf)) continue;
                } else {
                    // disp32 alone (SIB with no base), sign-extended.
                    const d: i64 = @bitCast(ea -% idx);
                    if (a32) {
                        std.mem.writeInt(u32, cs.code[body_at + disp_at ..][0..4], @truncate(ea -% idx), .little);
                    } else {
                        if (d < std.math.minInt(i32) or d > std.math.maxInt(i32)) continue;
                        std.mem.writeInt(i32, cs.code[body_at + disp_at ..][0..4], @intCast(d), .little);
                    }
                }
            }
            switch (e.op) {
                .bt, .bts, .btr, .btc => if (e.src == .G) {
                    if ((base != null and reg_field == base.?) or (index != null and reg_field == index.?)) continue;
                    cs.r[reg_field] = r.uintLessThan(u64, 512) -% 256;
                },
                else => {},
            }
        }
        // Shift counts, for SHLD and SHRD's undefined 16-bit cases and the
        // undefined flags.
        var count: ?u64 = null;
        switch (e.op) {
            .shl, .shr, .sar, .shld, .shrd, .rol, .ror, .rcl, .rcr => {
                if (e.src == .one) count = 1 else if (e.imm == .b) count = cs.code[len - 1] else if (e.src == .CL or e.op == .shld or e.op == .shrd) count = cs.r[1] & 0xff;
            },
            else => {},
        }
        if ((e.op == .shld or e.op == .shrd) and size == 2) {
            if ((count orelse 0) & 31 > 16) continue;
        }
        r.bytes(&cs.win);
        fillFp(r, &cs.fx, &cs.win, mode, if (target) |t| t - win_va else null, 16);
        cs.notes = .{ .undef = undefFlags64(e.op, size, count), .row = row_ix, .modrm = modrm, .mem = @intFromBool(mem) };
        if (c.fwrite(@ptrCast(&cs), @sizeOf(Case64), 1, out) != 1) die("write");
        made += 1;
    }
}

/// The FXSAVE64 image's x87, MMX, and SSE state into hx64's Cpu, and
/// back: Cpu.setExtra's and getExtra's, with 16 XMM registers.
fn setFx64(cpu: *Cpu64, fx: *const [512]u8) void {
    const p = &cpu.fpu;
    p.cw = std.mem.readInt(u16, fx[0..2], .little);
    const sw = std.mem.readInt(u16, fx[2..4], .little);
    p.top = @truncate(sw >> 11);
    p.sw = sw & ~@as(u16, 0x3800);
    p.tag = fx[4];
    p.fop = std.mem.readInt(u16, fx[6..8], .little);
    p.fip = @truncate(std.mem.readInt(u64, fx[8..16], .little));
    p.fdp = @truncate(std.mem.readInt(u64, fx[16..24], .little));
    cpu.mxcsr = std.mem.readInt(u32, fx[24..28], .little) & 0xffff;
    for (0..8) |i| p.st[(@as(usize, p.top) + i) & 7] = .{
        .signif = std.mem.readInt(u64, fx[32 + 16 * i ..][0..8], .little),
        .sign_exp = std.mem.readInt(u16, fx[40 + 16 * i ..][0..2], .little),
    };
    for (0..16) |i| cpu.xmm[i] = std.mem.readInt(u128, fx[160 + 16 * i ..][0..16], .little);
}

fn getFx64(cpu: *const Cpu64, fx: *[512]u8) void {
    @memset(fx, 0);
    const p = &cpu.fpu;
    put16(fx[0..], p.cw);
    put16(fx[2..], (p.sw & ~@as(u16, 0x3800)) | (@as(u16, p.top) << 11));
    fx[4] = p.tag;
    put16(fx[6..], p.fop);
    std.mem.writeInt(u64, fx[8..16], p.fip, .little);
    std.mem.writeInt(u64, fx[16..24], p.fdp, .little);
    put32(fx[24..], cpu.mxcsr);
    put32(fx[28..], 0xffff);
    for (0..8) |i| {
        const v = p.st[(@as(usize, p.top) + i) & 7];
        std.mem.writeInt(u64, fx[32 + 16 * i ..][0..8], v.signif, .little);
        std.mem.writeInt(u16, fx[40 + 16 * i ..][0..2], v.sign_exp, .little);
    }
    for (0..16) |i| std.mem.writeInt(u128, fx[160 + 16 * i ..][0..16], cpu.xmm[i], .little);
}

/// The row a case's notes name: an index in the mode's rows64, which
/// cmp64 takes from X86CHECK_MODE, as gen64 was given it.
fn shape64(n: *const Notes) Shape {
    if (n.row == 0xffff or n.row >= row_cache.len) return .{ .op = .movsx, .mem = n.mem != 0, .opcode = 0x63, .modrm = n.modrm };
    const row = row_cache[n.row];
    return .{ .op = row.e.op, .mem = n.mem != 0, .opcode = row.opcode, .modrm = n.modrm };
}

var row_cache: []const table.Row = &.{};

fn cmp64(cf: *c.FILE, af: *c.FILE) u32 {
    const brief = c.getenv("X86CHECK_BRIEF") != null;
    var bad: u32 = 0;
    var total: u32 = 0;
    var by_why: [16]struct { why: []const u8, n: u32 } = undefined;
    var nwhy: usize = 0;
    var code: [4096]u8 align(4096) = undefined;
    var data: [8192]u8 align(4096) = undefined;
    var cs: Case64 = undefined;
    var an: Answer64 = undefined;
    var t0fx: [512]u8 = undefined;
    // The mode is whatever rows the notes index; take it from the env, as
    // gen64 had it (the default int).
    const mode = std.meta.stringToEnum(Mode, std.mem.span(c.getenv("X86CHECK_MODE") orelse "int")) orelse .int;
    row_cache = rows64(mode);
    while (c.fread(@ptrCast(&cs), @sizeOf(Case64), 1, cf) == 1) {
        if (c.fread(@ptrCast(&an), @sizeOf(Answer64), 1, af) != 1) die("short answers");
        total += 1;
        @memset(&code, 0x90);
        @memcpy(code[0..16], &cs.code);
        code[16] = 0xcc;
        @memset(&data, 0);
        @memcpy(data[win_va - data_va ..][0..win_len], &cs.win);
        var m: Mem64 = .{ .code = &code, .data = &data };
        var cpu: Cpu64 = .{};
        cpu.r = cs.r;
        cpu.rip = code_va;
        cpu.fl.set(@as(u32, @truncate(cs.fl)) | flags.IF);
        cpu.gs_base = cs.gs_base;
        setFx64(&cpu, &cs.fx);
        const sh = shape64(&cs.notes);
        if (undefinedResult(&cs.fx, sh)) continue;
        const exit = x86.exec.stepIn(.long, &cpu, &m);
        getFx64(&cpu, &t0fx);
        const mask: u32 = (flags.arith | flags.DF) & ~cs.notes.undef;
        var ok = true;
        var why: []const u8 = "";
        if (an.sig != 0) {
            const got: ?u32 = if (exit) |x| switch (x) {
                .exception => |v| v,
                .fault => 14,
                else => null,
            } else null;
            if (got == null or got.? != an.trap) {
                ok = false;
                why = "exception";
            } else if (fxDiffers(&t0fx, &an.fx, sh, 16)) |w| {
                ok = false;
                why = w;
            }
        } else if (exit != null) {
            ok = false;
            why = "unexpected exit";
        } else {
            if (!std.mem.eql(u64, &cpu.r, &an.r)) {
                ok = false;
                why = "registers";
            } else if ((cpu.fl.get() ^ @as(u32, @truncate(an.fl))) & mask != 0) {
                ok = false;
                why = "flags";
            } else if (!std.mem.eql(u8, data[win_va - data_va ..][0..win_len], &an.win)) {
                ok = false;
                why = "memory";
            } else if (fxDiffers(&t0fx, &an.fx, sh, 16)) |w| {
                ok = false;
                why = w;
            }
        }
        if (ok) continue;
        bad += 1;
        var found = false;
        for (by_why[0..nwhy]) |*b| if (std.mem.eql(u8, b.why, why)) {
            b.n += 1;
            found = true;
        };
        if (!found and nwhy < by_why.len) {
            by_why[nwhy] = .{ .why = why, .n = 1 };
            nwhy += 1;
        }
        const len = std.mem.indexOfScalar(u8, &cs.code, 0x90) orelse 16;
        if (brief) {
            std.debug.print("{s}: {t} {x}\n", .{ why, sh.op, cs.code[0..len] });
        } else if (bad <= 40) {
            std.debug.print("{s}: {t} {x}", .{ why, sh.op, cs.code[0..len] });
            std.debug.print(" exit={any} sig={d} trap={d} gs={x}\n", .{ exit, an.sig, an.trap, cs.gs_base });
            dump64("in ", &cs.r, cs.fl);
            dump64("t0 ", &cpu.r, cpu.fl.get() & mask);
            dump64("cpu", &an.r, an.fl & mask);
            if (sh.op == .x87 or sh.op == .sse or sh.op == .fwait) {
                dumpFx("in ", &cs.fx);
                dumpFx("t0 ", &t0fx);
                dumpFx("cpu", &an.fx);
            }
        }
    }
    std.debug.print("x86check: {d} long-mode cases, {d} differ\n", .{ total, bad });
    for (by_why[0..nwhy]) |b| std.debug.print("  {d:>8}  {s}\n", .{ b.n, b.why });
    return bad;
}

fn dump64(what: []const u8, r: *const [16]u64, fl: u64) void {
    std.debug.print("  {s}", .{what});
    for (r, 0..) |v, i| {
        if (i == 8) std.debug.print("\n     ", .{});
        std.debug.print(" {x:0>16}", .{v});
    }
    std.debug.print(" fl={x}\n", .{fl});
}
