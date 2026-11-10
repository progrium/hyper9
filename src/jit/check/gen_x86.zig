//! Random valid 386 instruction sequences, for fuzz-x86, and long-mode
//! (amd64) ones for fuzz-x64 (`program64`, below).
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

pub const Insn = struct {
    bytes: [16]u8 = undefined,
    len: u8 = 0,
    /// A forward jump: skip this many following instructions.
    skip: u8 = 0,
    /// Long mode: where a RIP-relative disp32 is (0 if none), patched in
    /// `program64` to reach `rip_target`, an offset in the data page.
    rip_disp_at: u8 = 0,
    rip_target: u16 = 0,

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
    } else i.add(&.{0xC0 | (reg << 3) | rm});
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

// ---------------------------------------------------------------- long mode

// Random valid amd64 (long mode) sequences, for fuzz-x64 and hx64's
// checks. The machine is the 386's: code at 0x1000, data at 0x20000 (RBX
// points at it, and no instruction writes RBX), a stack page above it
// with RSP in its middle (only PUSH and POP move RSP). Each instruction
// may carry REX: W for 64-bit operands, and R, X, and B to reach R8-R15,
// so a destination is any register but RBX and RSP (R11 and R12 are
// fine). Memory operands are [RBX+disp8], or RIP-relative into the data
// page; LEA takes any base and index, now and then with 67's 32-bit
// addressing. A program ends in SYSCALL, with INT3 after it.

const rbx = 3;
const rsp = 4;

pub const Class64 = enum {
    alu,
    alu_imm,
    incdec,
    mov,
    mov_imm64,
    movx,
    movsxd,
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
    cmpxchg16b,
    rip_rel,
    bad_mem,
    jcc,
};

pub const Options64 = struct {
    len: u32 = 32,
    classes: []const Class64 = std.enums.values(Class64),
};

/// An r/m operand: a register, [RBX+disp8], RIP-relative to an offset in
/// the data page, or (LEA only) [base + index*scale + disp8].
const Rm = union(enum) {
    reg: u4,
    rbx: u8,
    rip: u16,
    sib: struct { base: u4, index: u4, scale: u2, disp: u8 },
};

/// What goes before the opcode.
const Pfx = struct {
    o16: bool = false,
    a32: bool = false,
    lock: bool = false,
    rep: u8 = 0,
    w: bool = false,
    /// A REX byte even when it has no bits set: byte registers 4-7 are
    /// then SPL, BPL, SIL, and DIL.
    rex: bool = false,
};

/// Encodes prefixes, REX, `op` (one or two bytes), and a ModRM with
/// `reg` and `rm` (when `rm` isn't null).
fn enc(i: *Insn, p: Pfx, op: []const u8, reg: u4, rm: ?Rm) void {
    if (p.lock) i.add(&.{0xF0});
    if (p.rep != 0) i.add(&.{p.rep});
    if (p.o16) i.add(&.{0x66});
    if (p.a32) i.add(&.{0x67});
    var rex: u8 = 0x40;
    if (p.w) rex |= 8;
    if (reg >= 8) rex |= 4;
    if (rm) |m| switch (m) {
        .reg => |r| if (r >= 8) {
            rex |= 1;
        },
        .sib => |s| {
            if (s.base >= 8) rex |= 1;
            if (s.index >= 8) rex |= 2;
        },
        else => {},
    };
    if (rex != 0x40 or p.rex) i.add(&.{rex});
    i.add(op);
    const r3: u8 = reg & 7;
    const m = rm orelse return;
    switch (m) {
        .reg => |r| i.add(&.{0xC0 | (r3 << 3) | (r & 7)}),
        .rbx => |d| i.add(&.{ 0x40 | (r3 << 3) | rbx, d }),
        .rip => |t| {
            i.add(&.{0x05 | (r3 << 3)});
            i.rip_disp_at = i.len;
            i.rip_target = t;
            i.add(&.{ 0, 0, 0, 0 });
        },
        .sib => |s| i.add(&.{ 0x44 | (r3 << 3), (@as(u8, s.scale) << 6) | (@as(u8, s.index & 7) << 3) | (s.base & 7), s.disp }),
    }
}

/// A 64-bit, 32-bit, or 16-bit operand size: REX.W, none, or 66.
const Width = enum { q, d, w };

fn width(r: std.Random) Width {
    return switch (r.uintLessThan(u32, 8)) {
        0...3 => .q,
        4...6 => .d,
        else => .w,
    };
}

fn pfxOf(w: Width) Pfx {
    return .{ .w = w == .q, .o16 = w == .w };
}

/// A destination register: any but RBX (the data base) and RSP.
fn dst64(r: std.Random) u4 {
    while (true) {
        const x = r.int(u4);
        if (x != rbx and x != rsp) return x;
    }
}

/// A byte destination, and whether it needs a REX byte: without REX, AL
/// CL DL AH CH DH (not BL or BH); with one, any but BL and SPL.
fn dst8x(r: std.Random, rex: bool) u4 {
    if (!rex) return @intCast(dst8(r));
    while (true) {
        const x = r.int(u4);
        if (x != rbx and x != rsp) return x;
    }
}

fn src64(r: std.Random) u4 {
    return r.int(u4);
}

/// A register, or now and then memory: [RBX+disp8], or RIP-relative.
fn rmOf(r: std.Random, reg: u4, mem_ok: bool) Rm {
    if (mem_ok and r.uintLessThan(u32, 3) == 0) {
        if (r.uintLessThan(u32, 4) == 0) return .{ .rip = r.uintLessThan(u16, 128) };
        return .{ .rbx = r.uintLessThan(u8, 128) };
    }
    return .{ .reg = reg };
}

fn immN(r: std.Random, i: *Insn, n: usize) void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, value64(r), .little);
    i.add(b[0..n]);
}

/// The immediate of an operand size: 2 bytes for 16 bits, else 4 (a
/// 64-bit operation sign-extends imm32).
fn immW(r: std.Random, i: *Insn, w: Width) void {
    immN(r, i, if (w == .w) 2 else 4);
}

pub fn one64(r: std.Random, c: Class64) Insn {
    var i: Insn = .{};
    const w = width(r);
    const p = pfxOf(w);
    // A REX byte with no bits now and then, for SPL..DIL.
    const rex_b = r.uintLessThan(u32, 3) == 0;
    switch (c) {
        // ADD OR ADC SBB AND SUB XOR CMP: r/m,r and r,r/m, at 8 to 64 bits
        .alu => {
            const op = r.uintLessThan(u8, 8) << 3;
            const byte = r.uintLessThan(u32, 4) == 0;
            const to_reg = r.boolean();
            const opc = op | (if (to_reg) @as(u8, 2) else 0) | (if (byte) @as(u8, 0) else 1);
            const bp: Pfx = if (byte) .{ .rex = rex_b } else p;
            const d = if (byte) dst8x(r, rex_b) else dst64(r);
            const s = if (byte) dst8x(r, rex_b) else src64(r);
            if (to_reg) enc(&i, bp, &.{opc}, d, rmOf(r, s, true)) else enc(&i, bp, &.{opc}, s, rmOf(r, d, true));
        },
        // 80, 81, 83 /op
        .alu_imm => {
            const op = r.int(u3);
            switch (r.uintLessThan(u32, 3)) {
                0 => {
                    enc(&i, .{ .rex = rex_b }, &.{0x80}, op, rmOf(r, dst8x(r, rex_b), true));
                    i.add(&.{r.int(u8)});
                },
                1 => {
                    enc(&i, p, &.{0x81}, op, rmOf(r, dst64(r), true));
                    immW(r, &i, w);
                },
                else => {
                    enc(&i, p, &.{0x83}, op, rmOf(r, dst64(r), true));
                    i.add(&.{r.int(u8)});
                },
            }
        },
        // INC DEC r/m (FE and FF /0 /1): 40-4F are REX in long mode
        .incdec => if (r.uintLessThan(u32, 4) == 0)
            enc(&i, .{ .rex = rex_b }, &.{0xFE}, r.uintLessThan(u4, 2), rmOf(r, dst8x(r, rex_b), true))
        else
            enc(&i, p, &.{0xFF}, r.uintLessThan(u4, 2), rmOf(r, dst64(r), true)),
        // 88 89 8A 8B, B8+r imm32 (zero-extended), C7 /0 imm32
        .mov => switch (r.uintLessThan(u32, 3)) {
            0 => {
                const byte = r.uintLessThan(u32, 4) == 0;
                const to_reg = r.boolean();
                const opc = 0x88 | (if (to_reg) @as(u8, 2) else 0) | (if (byte) @as(u8, 0) else 1);
                const bp: Pfx = if (byte) .{ .rex = rex_b } else p;
                const d = if (byte) dst8x(r, rex_b) else dst64(r);
                const s = if (byte) dst8x(r, rex_b) else src64(r);
                if (to_reg) enc(&i, bp, &.{opc}, d, rmOf(r, s, true)) else enc(&i, bp, &.{opc}, s, rmOf(r, d, true));
            },
            1 => {
                const d = dst64(r);
                const pp: Pfx = .{ .o16 = w == .w };
                enc(&i, if (d >= 8) Pfx{ .o16 = pp.o16, .rex = true } else pp, &.{0xB8 + @as(u8, d & 7)}, 0, null);
                if (d >= 8) i.bytes[i.len - 2] |= 1; // REX.B
                immW(r, &i, if (w == .q) .d else w);
            },
            else => {
                enc(&i, p, &.{0xC7}, 0, rmOf(r, dst64(r), true));
                immW(r, &i, w);
            },
        },
        // MOV r64, imm64 (REX.W B8+r)
        .mov_imm64 => {
            const d = dst64(r);
            i.add(&.{ 0x48 | @as(u8, d >> 3), 0xB8 + @as(u8, d & 7) });
            immN(r, &i, 8);
        },
        // MOVZX MOVSX r, r/m8 or r/m16
        .movx => {
            const ops = [_]u8{ 0xB6, 0xB7, 0xBE, 0xBF };
            const k = r.uintLessThan(usize, 4);
            // A byte source register needs care: no BH without REX.
            const pp: Pfx = .{ .w = w == .q, .o16 = w == .w, .rex = rex_b };
            enc(&i, pp, &.{ 0x0F, ops[k] }, dst64(r), rmOf(r, if (k & 1 == 0) dst8x(r, rex_b or w == .q) else src64(r), true));
        },
        // MOVSXD r64, r/m32 (REX.W 63), and 63 without W, which is a
        // 32-bit move
        .movsxd => enc(&i, .{ .w = r.uintLessThan(u32, 8) != 0 }, &.{0x63}, dst64(r), rmOf(r, src64(r), true)),
        // LEA r, [base + index*scale + disp8], with 67 now and then
        .lea => {
            var idx = src64(r);
            if (idx == rsp) idx = 0;
            const pp: Pfx = .{ .w = w == .q, .o16 = w == .w, .a32 = r.uintLessThan(u32, 4) == 0 };
            if (r.uintLessThan(u32, 6) == 0)
                enc(&i, pp, &.{0x8D}, dst64(r), .{ .rip = r.uintLessThan(u16, 128) })
            else
                enc(&i, pp, &.{0x8D}, dst64(r), .{ .sib = .{ .base = src64(r), .index = idx, .scale = r.int(u2), .disp = r.int(u8) } });
        },
        // C0/C1 imm8, D0/D1 by 1, D2/D3 by CL; ROL ROR RCL RCR SHL SHR SAR
        .shift => {
            const ops = [_]u4{ 0, 1, 2, 3, 4, 5, 7 };
            const op = ops[r.uintLessThan(usize, ops.len)];
            const byte = r.uintLessThan(u32, 4) == 0;
            const form = r.uintLessThan(u8, 3);
            const opc = (switch (form) {
                0 => @as(u8, 0xC0),
                1 => 0xD0,
                else => 0xD2,
            }) | (if (byte) @as(u8, 0) else 1);
            if (byte) enc(&i, .{ .rex = rex_b }, &.{opc}, op, rmOf(r, dst8x(r, rex_b), true)) else enc(&i, p, &.{opc}, op, rmOf(r, dst64(r), true));
            if (form == 0) i.add(&.{r.uintLessThan(u8, 72)});
        },
        // SHLD SHRD by imm8 or CL (not 16 bits: over 16, undefined)
        .shld => {
            const ops = [_]u8{ 0xA4, 0xA5, 0xAC, 0xAD };
            const op = ops[r.uintLessThan(usize, 4)];
            enc(&i, .{ .w = r.boolean() }, &.{ 0x0F, op }, src64(r), rmOf(r, dst64(r), true));
            if (op & 1 == 0) i.add(&.{r.uintLessThan(u8, 64)});
        },
        // MUL IMUL DIV IDIV r/m (F6 and F7 /4-/7)
        .muldiv => if (r.uintLessThan(u32, 4) == 0)
            enc(&i, .{ .rex = rex_b }, &.{0xF6}, 4 + r.uintLessThan(u4, 4), rmOf(r, dst8x(r, rex_b), true))
        else
            enc(&i, p, &.{0xF7}, 4 + r.uintLessThan(u4, 4), rmOf(r, src64(r), true)),
        // IMUL r, r/m; IMUL r, r/m, imm32 or imm8
        .imul => switch (r.uintLessThan(u32, 3)) {
            0 => enc(&i, p, &.{ 0x0F, 0xAF }, dst64(r), rmOf(r, src64(r), true)),
            1 => {
                enc(&i, p, &.{0x69}, dst64(r), rmOf(r, src64(r), true));
                immW(r, &i, w);
            },
            else => {
                enc(&i, p, &.{0x6B}, dst64(r), rmOf(r, src64(r), true));
                i.add(&.{r.int(u8)});
            },
        },
        // NOT NEG (F7 /2 /3), TEST (85, F7 /0)
        .unary => switch (r.uintLessThan(u32, 3)) {
            0 => enc(&i, p, &.{0xF7}, 2 + r.uintLessThan(u4, 2), rmOf(r, dst64(r), true)),
            1 => enc(&i, p, &.{0x85}, src64(r), rmOf(r, src64(r), true)),
            else => {
                enc(&i, p, &.{0xF7}, 0, rmOf(r, src64(r), true));
                immW(r, &i, w);
            },
        },
        // XCHG rAX, r (90+r: 90 alone is NOP, and REX.B 90 is XCHG R8);
        // XCHG r/m, r
        .xchg => if (r.boolean()) {
            const d = dst64(r);
            if (d == 0) {
                i.add(&.{0x90});
            } else {
                enc(&i, if (d >= 8) Pfx{ .w = p.w, .o16 = p.o16, .rex = true } else p, &.{0x90 + @as(u8, d & 7)}, 0, null);
                if (d >= 8) i.bytes[i.len - 2] |= 1;
            }
        } else enc(&i, p, &.{0x87}, dst64(r), rmOf(r, dst64(r), true)),
        // CMOVcc r, r/m; SETcc r/m8
        .cmov_set => if (r.boolean())
            enc(&i, p, &.{ 0x0F, 0x40 + r.uintLessThan(u8, 16) }, dst64(r), rmOf(r, src64(r), true))
        else
            enc(&i, .{ .rex = rex_b }, &.{ 0x0F, 0x90 + r.uintLessThan(u8, 16) }, 0, rmOf(r, dst8x(r, rex_b), true)),
        // BT BTS BTR BTC r, r (registers only: a memory form's bit offset
        // can reach any address) and r/m, imm8
        .bt => if (r.boolean()) {
            const ops = [_]u8{ 0xA3, 0xAB, 0xB3, 0xBB };
            enc(&i, p, &.{ 0x0F, ops[r.uintLessThan(usize, 4)] }, src64(r), .{ .reg = dst64(r) });
        } else {
            enc(&i, p, &.{ 0x0F, 0xBA }, 4 + r.uintLessThan(u4, 4), rmOf(r, dst64(r), true));
            i.add(&.{r.int(u8)});
        },
        // BSWAP r32 or r64
        .bswap => {
            const d = dst64(r);
            i.add(&.{ 0x40 | (if (r.boolean()) @as(u8, 8) else 0) | @as(u8, d >> 3), 0x0F, 0xC8 + @as(u8, d & 7) });
        },
        // PUSH and POP r64 (50+r, 58+r), and PUSH r/m and POP r/m
        // (FF /6, 8F /0) to the data page
        .pushpop => switch (r.uintLessThan(u32, 4)) {
            0 => {
                const s = src64(r);
                if (s >= 8) i.add(&.{0x41});
                i.add(&.{0x50 + @as(u8, s & 7)});
            },
            1 => {
                const d = dst64(r);
                if (d >= 8) i.add(&.{0x41});
                i.add(&.{0x58 + @as(u8, d & 7)});
            },
            2 => enc(&i, .{}, &.{0xFF}, 6, .{ .rbx = r.uintLessThan(u8, 120) }),
            else => enc(&i, .{}, &.{0x8F}, 0, .{ .rbx = r.uintLessThan(u8, 120) }),
        },
        // CBW CWDE CDQE, CWD CDQ CQO
        .cdq => enc(&i, p, &.{if (r.boolean()) @as(u8, 0x98) else 0x99}, 0, null),
        // [LOCK] XADD, CMPXCHG on memory or registers
        .xadd_cmpxchg => {
            const lock = r.boolean();
            const pp: Pfx = .{ .w = p.w, .o16 = p.o16, .lock = lock };
            const op: []const u8 = &.{ 0x0F, if (r.boolean()) @as(u8, 0xC1) else 0xB1 };
            if (lock) enc(&i, pp, op, dst64(r), .{ .rbx = r.uintLessThan(u8, 15) * 8 }) else enc(&i, pp, op, dst64(r), rmOf(r, dst64(r), true));
        },
        // [LOCK] CMPXCHG16B m128 (REX.W 0F C7 /1), aligned, or CMPXCHG8B
        .cmpxchg16b => enc(&i, .{ .w = r.uintLessThan(u32, 4) != 0, .lock = r.boolean() }, &.{ 0x0F, 0xC7 }, 1, .{ .rbx = r.uintLessThan(u8, 7) * 16 }),
        // Loads and ALU ops from RIP-relative operands
        .rip_rel => {
            const ops = [_]u8{ 0x8B, 0x03, 0x2B, 0x3B, 0x23, 0x0B, 0x33, 0x85 };
            enc(&i, p, &.{ops[r.uintLessThan(usize, ops.len)]}, dst64(r), .{ .rip = r.uintLessThan(u16, 120) });
        },
        // MOV RAX, [moffs64] at an unmapped address (a page fault), or
        // a load from a non-canonical address (#GP)
        .bad_mem => if (r.boolean()) {
            i.add(&.{ 0x48, 0xA1 });
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, @as(u64, bad_va) + r.uintLessThan(u64, 4096), .little);
            i.add(&b);
        } else {
            i.add(&.{ 0x48, 0xA1 });
            var b: [8]u8 = undefined;
            std.mem.writeInt(u64, &b, 0x0000_8000_0000_0000 + r.uintLessThan(u64, 4096), .little);
            i.add(&b);
        },
        // Jcc rel8 and JMP rel8, forward; patched in `program64`.
        .jcc => {
            i.add(&.{ if (r.uintLessThan(u32, 8) == 0) @as(u8, 0xEB) else 0x70 + r.uintLessThan(u8, 16), 0 });
            i.skip = 1 + r.uintLessThan(u8, 6);
        },
    }
    return i;
}

/// Writes a long-mode program into `out`; returns its bytes, ending in
/// SYSCALL.
pub fn program64(r: std.Random, opts: Options64, out: []u8) []u8 {
    var insns: [1024]Insn = undefined;
    const n = @min(opts.len, insns.len);
    for (0..n) |k| {
        var c = opts.classes[r.uintLessThan(usize, opts.classes.len)];
        if (c == .bad_mem and r.uintLessThan(u32, 8) != 0) c = opts.classes[r.uintLessThan(usize, opts.classes.len)];
        insns[k] = one64(r, c);
    }
    var off: [1025]usize = undefined;
    off[0] = 0;
    for (0..n) |k| off[k + 1] = off[k] + insns[k].len;
    for (0..n) |k| {
        const in = &insns[k];
        if (in.rip_disp_at != 0) {
            const next: i64 = @intCast(code_va + off[k + 1]);
            const d: i32 = @intCast(@as(i64, data_va + in.rip_target) - next);
            std.mem.writeInt(i32, in.bytes[in.rip_disp_at..][0..4], d, .little);
        }
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
    out[len] = 0x0F; // syscall
    out[len + 1] = 0x05;
    return out[0 .. len + 2];
}

pub fn value64(r: std.Random) u64 {
    return switch (r.uintLessThan(u32, 12)) {
        0 => 0,
        1 => 0xffff_ffff_ffff_ffff,
        2 => 0x8000_0000_0000_0000,
        3 => 0x7fff_ffff_ffff_ffff,
        4 => r.uintLessThan(u64, 256),
        5 => 0 -% r.uintLessThan(u64, 256),
        6 => 1,
        7 => 0xffff_ffff,
        8 => 0x8000_0000,
        9 => r.int(u32),
        10 => @as(u64, r.int(u32)) << 32,
        else => r.int(u64),
    };
}

/// Starting registers: random, but RBX at the data page and RSP in the
/// middle of the stack page; random arithmetic flags.
pub fn registers64(r: std.Random) struct { r: [16]u64, rflags: u64 } {
    var regs: [16]u64 = undefined;
    for (&regs) |*x| x.* = value64(r);
    regs[rbx] = data_va;
    regs[rsp] = stack_va + 2048;
    return .{ .r = regs, .rflags = 0x202 | (r.int(u64) & 0x8d5) };
}

/// Whether long mode decodes yet (workstream A): until it does, the
/// decoder-backed tests below skip.
fn longDecodes() bool {
    const dec = @import("../../interp/x86/decode.zig");
    const i = dec.decodeIn(.long, &.{ 0x48, 0x01, 0xc8 }) catch return false;
    return i.op != .ud;
}

test "gen_x86: long-mode programs decode whole and end in SYSCALL" {
    if (!longDecodes()) return error.SkipZigTest;
    const dec = @import("../../interp/x86/decode.zig");
    var prng = std.Random.DefaultPrng.init(3);
    var buf: [4096]u8 = undefined;
    for (0..200) |_| {
        const p = program64(prng.random(), .{ .len = 40 }, &buf);
        var o: usize = 0;
        while (o < p.len) {
            const i = dec.decodeIn(.long, p[o..@min(p.len, o + dec.max_len)]) catch |e| {
                std.debug.print("decode {t} at {d}: {x}\n", .{ e, o, p[o..@min(p.len, o + 8)] });
                return e;
            };
            if (i.op == .ud) {
                std.debug.print("#UD at {d}: {x}\n", .{ o, p[o..@min(p.len, o + 8)] });
                return error.Undefined;
            }
            o += i.len;
        }
        try std.testing.expectEqual(p.len, o);
        try std.testing.expectEqualSlices(u8, &.{ 0x0F, 0x05 }, p[p.len - 2 ..]);
    }
}

test "gen_x86: every long-mode class encodes, and RIP-relative operands reach the data page" {
    var prng = std.Random.DefaultPrng.init(5);
    var buf: [4096]u8 = undefined;
    for (std.enums.values(Class64)) |c| {
        for (0..50) |_| {
            const in = one64(prng.random(), c);
            try std.testing.expect(in.len > 0 and in.len <= 15);
        }
    }
    // A single RIP-relative load: its target is data_va + rip_target.
    for (0..50) |_| {
        const p = program64(prng.random(), .{ .len = 1, .classes = &.{.rip_rel} }, &buf);
        const ilen = p.len - 2;
        const d = std.mem.readInt(i32, p[ilen - 4 ..][0..4], .little);
        const target = @as(i64, @intCast(code_va + ilen)) + d;
        try std.testing.expect(target >= data_va and target < data_va + 128);
    }
}
