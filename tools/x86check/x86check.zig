//! Checks h86's T0 against the host CPU: random integer instructions,
//! each run once by oracle.c on the real CPU in 32-bit mode and once by
//! T0, from the same registers, flags, and memory. Registers, the flags
//! the architecture defines, memory, and exceptions must match.
//!
//!     x86check gen <n> <seed> <cases>     write n cases
//!     x86check cmp <cases> <answers>      compare T0 with the oracle
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
};

const Answer = extern struct {
    sig: u32,
    r: [8]u32,
    fl: u32,
    win: [win_len]u8,
};

fn allowed(op: table.Op) bool {
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
        try gen(n, seed, out);
        _ = c.fclose(out);
    } else if (std.mem.eql(u8, cmd, "cmp")) {
        const cf = open(args.next() orelse die("cases"), "rb");
        const af = open(args.next() orelse die("answers"), "rb");
        const bad = cmp(cf, af);
        if (bad != 0) std.process.exit(1);
    } else die("usage: x86check gen|cmp ...");
}

/// The table rows to draw from.
fn rows() []const table.Row {
    const S = struct {
        var buf: [table.table.len]table.Row = undefined;
        var n: usize = 0;
    };
    if (S.n == 0) {
        for (table.table) |row| {
            if (allowed(row.e.op)) {
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

fn gen(n: u32, seed: u64, out: *c.FILE) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const r = prng.random();
    const rs = rows();
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
        if (r.uintLessThan(u8, 4) == 0 and e.op != .bswap) {
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
            const target = win_va + 0x80 + r.uintLessThan(u32, win_len - 0x100);
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
        if (c.fwrite(@ptrCast(&cs), @sizeOf(Case), 1, out) != 1) die("write");
        made += 1;
    }
}

fn cmp(cf: *c.FILE, af: *c.FILE) u32 {
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
        const inst = dec.decode(&cs.code) catch unreachable;
        const exit = x86.exec.step(&cpu, &m);
        const fx = dec.effects(&inst);
        var mask: u32 = flags.arith | flags.DF;
        mask &= ~fx.flags_undefined;
        if (inst.op == .div or inst.op == .idiv) mask &= ~flags.arith;
        if (inst.op == .bt or inst.op == .bts or inst.op == .btr or inst.op == .btc) mask &= ~(flags.arith & ~flags.CF);
        var ok = true;
        var why: []const u8 = "";
        if (an.sig != 0) {
            const want: u8 = switch (an.sig) {
                8 => 0, // SIGFPE: #DE
                4 => 6, // SIGILL: #UD
                else => 13,
            };
            if (exit == null or exit.? != .exception or exit.?.exception != want) {
                ok = false;
                why = "exception";
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
            }
        }
        if (!ok) {
            bad += 1;
            if (bad <= 40) {
                std.debug.print("{s}: {t} {x}", .{ why, inst.op, cs.code[0..inst.len] });
                std.debug.print(" exit={any} sig={d}\n", .{ exit, an.sig });
                dump("in ", cs.r, cs.fl);
                dump("t0 ", cpu.r, cpu.fl.get() & mask);
                dump("cpu", an.r, an.fl & mask);
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
