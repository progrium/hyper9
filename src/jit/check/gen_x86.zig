//! Random valid 386 instruction sequences, for fuzz-x86.
//!
//! A program is `len` instructions from the classes below and an INT $64.
//! It runs from 0x1000 with a data page at 0x20000, which EBX points at
//! and no instruction writes, and a stack page above it, with ESP in its
//! middle; only PUSH and POP move ESP. Memory operands are [EBX+disp8]
//! (or now and then an absolute unmapped address). Jumps only go forward,
//! so every program ends.

const std = @import("std");

pub const code_va: u32 = 0x1000;
pub const data_va: u32 = 0x20000;
pub const stack_va: u32 = 0x21000;
pub const bad_va: u32 = 0x7000_0000;
const ebx = 3;
const esp = 4;

pub const Class = enum {
    alu,
    alu_imm,
    incdec,
    mov,
    movx,
    lea,
    shift,
    shld,
    muldiv,
    imul,
    unary,
    xchg,
    cmov_set,
    bt,
    bswap,
    pushpop,
    cdq,
    xadd_cmpxchg,
    bad_mem,
    jcc,
};

pub const Options = struct {
    len: u32 = 32,
    classes: []const Class = std.enums.values(Class),
};

const Insn = struct {
    bytes: [16]u8 = undefined,
    len: u8 = 0,
    /// A forward jump: skip this many following instructions.
    skip: u8 = 0,

    fn add(i: *Insn, b: []const u8) void {
        @memcpy(i.bytes[i.len..][0..b.len], b);
        i.len += @intCast(b.len);
    }
};

/// A destination register: not EBX (the data base) or ESP.
fn dst(r: std.Random) u8 {
    const regs = [_]u8{ 0, 1, 2, 5, 6, 7 };
    return regs[r.uintLessThan(usize, regs.len)];
}

/// An 8-bit destination: AL CL DL AH CH DH (not BL or BH).
fn dst8(r: std.Random) u8 {
    const regs = [_]u8{ 0, 1, 2, 4, 5, 6 };
    return regs[r.uintLessThan(usize, regs.len)];
}

fn src(r: std.Random) u8 {
    return r.uintLessThan(u8, 8);
}

/// A ModRM with `reg` and an r/m operand: a register `rm`, or [EBX+disp8].
fn modrm(r: std.Random, i: *Insn, reg: u8, rm: u8, mem_ok: bool) void {
    if (mem_ok and r.uintLessThan(u32, 3) == 0) {
        i.add(&.{ 0x40 | (reg << 3) | ebx, r.uintLessThan(u8, 128) });
    } else i.add(&.{ 0xC0 | (reg << 3) | rm });
}

fn imm32(r: std.Random, i: *Insn) void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, value(r), .little);
    i.add(&b);
}

pub fn one(r: std.Random, c: Class) Insn {
    var i: Insn = .{};
    // Now and then a 16-bit operand size, for the classes that have one.
    const o16 = r.uintLessThan(u32, 6) == 0;
    switch (c) {
        // ADD OR ADC SBB AND SUB XOR CMP: r/m,r and r,r/m, at 8 and 32 bits
        .alu => {
            const op = r.uintLessThan(u8, 8) << 3;
            const byte = r.boolean();
            const to_reg = r.boolean();
            if (o16 and !byte) i.add(&.{0x66});
            i.add(&.{op | (if (to_reg) @as(u8, 2) else 0) | (if (byte) @as(u8, 0) else 1)});
            if (to_reg) modrm(r, &i, if (byte) dst8(r) else dst(r), src(r), true) else modrm(r, &i, src(r), if (byte) dst8(r) else dst(r), true);
        },
        // 80, 81, 83 /op
        .alu_imm => {
            const op = r.uintLessThan(u8, 8);
            switch (r.uintLessThan(u32, 3)) {
                0 => {
                    i.add(&.{0x80});
                    modrm(r, &i, op, dst8(r), true);
                    i.add(&.{r.int(u8)});
                },
                1 => {
                    if (o16) i.add(&.{0x66});
                    i.add(&.{0x81});
                    modrm(r, &i, op, dst(r), true);
                    if (o16) i.add(&.{ r.int(u8), r.int(u8) }) else imm32(r, &i);
                },
                else => {
                    i.add(&.{0x83});
                    modrm(r, &i, op, dst(r), true);
                    i.add(&.{r.int(u8)});
                },
            }
        },
        .incdec => i.add(&.{(if (r.boolean()) @as(u8, 0x40) else 0x48) + dst(r)}),
        // 88 89 8A 8B, B8+r, C7 /0
        .mov => switch (r.uintLessThan(u32, 3)) {
            0 => {
                const byte = r.boolean();
                const to_reg = r.boolean();
                i.add(&.{0x88 | (if (to_reg) @as(u8, 2) else 0) | (if (byte) @as(u8, 0) else 1)});
                if (to_reg) modrm(r, &i, if (byte) dst8(r) else dst(r), src(r), true) else modrm(r, &i, src(r), if (byte) dst8(r) else dst(r), true);
            },
            1 => {
                i.add(&.{0xB8 + dst(r)});
                imm32(r, &i);
            },
            else => {
                i.add(&.{0xC7});
                modrm(r, &i, 0, dst(r), true);
                imm32(r, &i);
            },
        },
        // MOVZX MOVSX r32, r/m8 or r/m16
        .movx => {
            const ops = [_]u8{ 0xB6, 0xB7, 0xBE, 0xBF };
            i.add(&.{ 0x0F, ops[r.uintLessThan(usize, 4)] });
            modrm(r, &i, dst(r), src(r), true);
        },
        // LEA r32, [base + index*scale + disp8]
        .lea => {
            var idx = src(r);
            if (idx == esp) idx = 0;
            i.add(&.{ 0x8D, 0x44 | (dst(r) << 3), (r.uintLessThan(u8, 4) << 6) | (idx << 3) | src(r), r.int(u8) });
        },
        // C0/C1 imm8, D0/D1 by 1, D2/D3 by CL; ROL ROR RCL RCR SHL SHR SAR
        .shift => {
            const ops = [_]u8{ 0, 1, 2, 3, 4, 5, 7 };
            const op = ops[r.uintLessThan(usize, ops.len)];
            const byte = r.boolean();
            const form = r.uintLessThan(u8, 3);
            if (o16 and !byte) i.add(&.{0x66});
            i.add(&.{(switch (form) {
                0 => @as(u8, 0xC0),
                1 => 0xD0,
                else => 0xD2,
            }) | (if (byte) @as(u8, 0) else 1)});
            modrm(r, &i, op, if (byte) dst8(r) else dst(r), true);
            if (form == 0) i.add(&.{r.uintLessThan(u8, 40)});
        },
        // SHLD SHRD by imm8 or CL
        .shld => {
            const ops = [_]u8{ 0xA4, 0xA5, 0xAC, 0xAD };
            const op = ops[r.uintLessThan(usize, 4)];
            i.add(&.{ 0x0F, op });
            modrm(r, &i, src(r), dst(r), true);
            if (op & 1 == 0) i.add(&.{r.uintLessThan(u8, 32)});
        },
        // MUL IMUL DIV IDIV r/m (F6 and F7 /4-/7): #DE on a zero divisor
        // or an overflowing quotient, which both sides must take.
        .muldiv => {
            i.add(&.{if (r.boolean()) @as(u8, 0xF6) else 0xF7});
            modrm(r, &i, 4 + r.uintLessThan(u8, 4), src(r), true);
        },
        // IMUL r, r/m; IMUL r, r/m, imm32 or imm8
        .imul => switch (r.uintLessThan(u32, 3)) {
            0 => {
                i.add(&.{ 0x0F, 0xAF });
                modrm(r, &i, dst(r), src(r), true);
            },
            1 => {
                i.add(&.{0x69});
                modrm(r, &i, dst(r), src(r), true);
                imm32(r, &i);
            },
            else => {
                i.add(&.{0x6B});
                modrm(r, &i, dst(r), src(r), true);
                i.add(&.{r.int(u8)});
            },
        },
        // NOT NEG (F6/F7 /2 /3), TEST (84 85, F7 /0)
        .unary => switch (r.uintLessThan(u32, 3)) {
            0 => {
                i.add(&.{if (r.boolean()) @as(u8, 0xF6) else 0xF7});
                modrm(r, &i, 2 + r.uintLessThan(u8, 2), dst(r), true);
            },
            1 => {
                i.add(&.{0x85});
                modrm(r, &i, src(r), src(r), true);
            },
            else => {
                i.add(&.{0xF7});
                modrm(r, &i, 0, src(r), true);
                imm32(r, &i);
            },
        },
        .xchg => if (r.boolean()) i.add(&.{0x90 + dst(r)}) else {
            i.add(&.{0x87});
            modrm(r, &i, dst(r), dst(r), true);
        },
        // CMOVcc r, r/m; SETcc r/m8
        .cmov_set => if (r.boolean()) {
            i.add(&.{ 0x0F, 0x40 + r.uintLessThan(u8, 16) });
            modrm(r, &i, dst(r), src(r), true);
        } else {
            i.add(&.{ 0x0F, 0x90 + r.uintLessThan(u8, 16) });
            modrm(r, &i, 0, dst8(r), true);
        },
        // BT BTS BTR BTC r/m, r (register forms: a memory form's bit
        // offset can reach any address) and r/m, imm8
        .bt => if (r.boolean()) {
            const ops = [_]u8{ 0xA3, 0xAB, 0xB3, 0xBB };
            i.add(&.{ 0x0F, ops[r.uintLessThan(usize, 4)] });
            modrm(r, &i, src(r), dst(r), false);
        } else {
            i.add(&.{ 0x0F, 0xBA });
            modrm(r, &i, 4 + r.uintLessThan(u8, 4), dst(r), true);
            i.add(&.{r.int(u8)});
        },
        .bswap => i.add(&.{ 0x0F, 0xC8 + dst(r) }),
        .pushpop => i.add(&.{if (r.boolean()) @as(u8, 0x50) + src(r) else 0x58 + dst(r)}),
        // CWDE CDQ, CBW CWD (with 66)
        .cdq => {
            if (o16) i.add(&.{0x66});
            i.add(&.{if (r.boolean()) @as(u8, 0x98) else 0x99});
        },
        // [LOCK] XADD, CMPXCHG on memory or registers
        .xadd_cmpxchg => {
            const lock = r.boolean();
            if (lock) i.add(&.{0xF0});
            i.add(&.{ 0x0F, if (r.boolean()) @as(u8, 0xC1) else 0xB1 });
            // LOCK needs a memory operand.
            if (lock) i.add(&.{ 0x40 | (dst(r) << 3) | ebx, r.uintLessThan(u8, 32) * 4 }) else modrm(r, &i, dst(r), dst(r), true);
        },
        // MOV EAX, [bad_va]: a page fault.
        .bad_mem => {
            i.add(&.{0xA1});
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, bad_va + r.uintLessThan(u32, 4096), .little);
            i.add(&b);
        },
        // Jcc rel8 and JMP rel8, forward; patched in `program`.
        .jcc => {
            i.add(&.{ if (r.uintLessThan(u32, 8) == 0) @as(u8, 0xEB) else 0x70 + r.uintLessThan(u8, 16), 0 });
            i.skip = 1 + r.uintLessThan(u8, 6);
        },
    }
    return i;
}

/// Writes a program into `out`; returns its bytes.
pub fn program(r: std.Random, opts: Options, out: []u8) []u8 {
    var insns: [1024]Insn = undefined;
    const n = @min(opts.len, insns.len);
    for (0..n) |k| {
        var c = opts.classes[r.uintLessThan(usize, opts.classes.len)];
        if (c == .bad_mem and r.uintLessThan(u32, 8) != 0) c = opts.classes[r.uintLessThan(usize, opts.classes.len)];
        insns[k] = one(r, c);
    }
    // Offsets, then patch each jump to land on an instruction start (or
    // the INT $64 after the last).
    var off: [1025]usize = undefined;
    off[0] = 0;
    for (0..n) |k| off[k + 1] = off[k] + insns[k].len;
    for (0..n) |k| {
        const in = &insns[k];
        if (in.skip == 0) continue;
        const to = @min(k + 1 + in.skip, n);
        in.bytes[1] = @intCast(@min(127, off[to] - off[k + 1]));
        if (off[to] - off[k + 1] > 127) in.bytes[1] = 0;
    }
    var len: usize = 0;
    for (insns[0..n]) |in| {
        if (len + in.len + 2 > out.len) break;
        @memcpy(out[len..][0..in.len], in.bytes[0..in.len]);
        len += in.len;
    }
    out[len] = 0xCD; // int $64
    out[len + 1] = 0x40;
    return out[0 .. len + 2];
}

pub fn value(r: std.Random) u32 {
    return switch (r.uintLessThan(u32, 8)) {
        0 => 0,
        1 => 0xffffffff,
        2 => 0x80000000,
        3 => 0x7fffffff,
        4 => r.uintLessThan(u32, 256),
        5 => 0 -% r.uintLessThan(u32, 256),
        6 => 1,
        else => r.int(u32),
    };
}

/// Starting registers: random, but EBX at the data page and ESP in the
/// middle of the stack page; random arithmetic flags.
pub fn registers(r: std.Random) struct { r: [8]u32, eflags: u32 } {
    var regs: [8]u32 = undefined;
    for (&regs) |*x| x.* = value(r);
    regs[ebx] = data_va;
    regs[esp] = stack_va + 2048;
    return .{ .r = regs, .eflags = 0x202 | (r.int(u32) & 0x8d5) };
}

test "gen_x86: programs decode whole and end in INT $64" {
    const dec = @import("../../interp/x86/decode.zig");
    var prng = std.Random.DefaultPrng.init(3);
    var buf: [4096]u8 = undefined;
    for (0..200) |_| {
        const p = program(prng.random(), .{ .len = 40 }, &buf);
        var o: usize = 0;
        while (o < p.len) {
            const i = dec.decode(p[o..@min(p.len, o + dec.max_len)]) catch |e| {
                std.debug.print("decode {t} at {d}: {x}\n", .{ e, o, p[o..@min(p.len, o + 8)] });
                return e;
            };
            o += i.len;
        }
        try std.testing.expectEqual(p.len, o);
        try std.testing.expectEqualSlices(u8, &.{ 0xCD, 0x40 }, p[p.len - 2 ..]);
    }
}
