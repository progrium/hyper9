//! h86's encoding table: every 386 encoding a ring-3 program can use, as
//! a comptime array in the shape of v86's gen/x86_table.js. One table
//! gives the decoder (decode.zig), T0's dispatch (exec.zig), and the JIT's
//! lifter: each looks an opcode up here instead of having its own switch
//! over the opcode map, and there is no generator and no generated file.
//!
//! An entry says how the instruction is encoded (ModRM, immediates,
//! operand size), what it does (`op`), which operands it reads and writes,
//! which fixed registers it uses, and whether it ends a block. Encodings
//! not listed raise #UD. x87 (D8-DF) and MMX, SSE, and SSE2 (most of 0F)
//! are listed with enough to find their length, as `.x87` and `.sse`, and
//! their semantics live in x87.zig and sse.zig, keyed by opcode, prefix,
//! and ModRM.

const std = @import("std");

/// What an instruction does. ALU operations share one `op` per kind; the
/// operand fields say where the operands come from.
pub const Op = enum(u8) {
    ud,
    /// Privileged, I/O, far control transfer, and the like: #GP at ring 3.
    gp,
    nop,

    // Two-operand arithmetic: dst = dst op src, flags.
    add,
    @"or",
    adc,
    sbb,
    @"and",
    sub,
    xor,
    cmp,
    @"test",
    // One-operand arithmetic.
    inc,
    dec,
    not,
    neg,
    /// MUL and IMUL r/m: EDX:EAX = EAX * src.
    mul,
    imul1,
    /// IMUL r, r/m and IMUL r, r/m, imm.
    imul,
    div,
    idiv,
    // Shifts and rotates, by `src` (1, CL, or imm8).
    rol,
    ror,
    rcl,
    rcr,
    shl,
    shr,
    sar,
    shld,
    shrd,
    // Moves.
    mov,
    movzx,
    movsx,
    lea,
    xchg,
    cmpxchg,
    cmpxchg8b,
    xadd,
    bswap,
    cbw,
    cwd,
    xlat,
    // Stack.
    push,
    pop,
    pusha,
    popa,
    pushf,
    popf,
    enter,
    leave,
    // Segments.
    push_sreg,
    pop_sreg,
    mov_sreg,
    mov_from_sreg,
    /// LDS, LES, LFS, LGS, and LSS: `seg_reg` says which.
    lseg,
    // Control flow.
    jcc,
    jmp,
    /// JMP r/m.
    jmp_ind,
    call,
    call_ind,
    ret,
    loop,
    loope,
    loopne,
    jcxz,
    setcc,
    cmovcc,
    // Bits.
    bt,
    bts,
    btr,
    btc,
    bsf,
    bsr,
    // Flags.
    lahf,
    sahf,
    clc,
    stc,
    cmc,
    cld,
    std,
    salc,
    // Strings.
    movs,
    cmps,
    stos,
    lods,
    scas,
    // BCD.
    daa,
    das,
    aaa,
    aas,
    aam,
    aad,
    // Traps.
    int3,
    int,
    into,
    bound,
    // System.
    cpuid,
    rdtsc,
    /// LFENCE, MFENCE, and SFENCE.
    fence,
    /// FWAIT: checks for a pending unmasked x87 exception.
    fwait,
    /// x87 (D8-DF): x87.zig.
    x87,
    /// MMX, SSE, and SSE2, with FXSAVE, FXRSTOR, LDMXCSR, STMXCSR, and
    /// EMMS: sse.zig.
    sse,
};

/// Where an operand comes from.
pub const Opd = enum(u4) {
    none,
    /// ModRM r/m: a register or memory.
    E,
    /// ModRM reg: a register.
    G,
    /// The immediate.
    I,
    /// AL, AX, or EAX.
    A,
    /// The register in the opcode's low three bits.
    Z,
    /// The constant 1 (shifts).
    one,
    /// CL (shifts).
    CL,
    /// ModRM reg as a segment register.
    S,
    /// A memory offset in the instruction (MOV AL, moffs).
    O,
};

/// Operand size: a byte, the current operand size (16 or 32 bits, by the
/// 0x66 prefix), or a fixed word or doubleword.
pub const Size = enum(u2) { b, v, w, d };

/// Immediates after the ModRM byte, displacement, and SIB.
pub const Imm = enum(u3) {
    none,
    /// imm8, zero-extended.
    b,
    /// imm8, sign-extended to the operand size.
    bs,
    /// imm16 or imm32, by operand size.
    v,
    /// imm16.
    w,
    /// imm16 then imm8 (ENTER).
    wb,
    /// A far pointer: offset by operand size, then a selector.
    ptr,
};

/// Which ModRM forms an entry covers.
pub const Mod = enum(u2) { any, mem, reg };

/// Fixed registers, as bits in a register mask in encoding order.
pub const eax: u8 = 1 << 0;
pub const ecx: u8 = 1 << 1;
pub const edx: u8 = 1 << 2;
pub const ebx: u8 = 1 << 3;
pub const esp: u8 = 1 << 4;
pub const ebp: u8 = 1 << 5;
pub const esi: u8 = 1 << 6;
pub const edi: u8 = 1 << 7;

pub const Entry = struct {
    op: Op = .ud,
    modrm: bool = false,
    size: Size = .v,
    dst: Opd = .none,
    src: Opd = .none,
    imm: Imm = .none,
    /// Fixed registers read and written, beyond the operands.
    ir: u8 = 0,
    iw: u8 = 0,
    /// Ends a basic block: a control transfer, or a trap.
    end: bool = false,
    /// LOCK may prefix it (with a memory destination).
    lock: bool = false,
    /// The segment register LDS and friends load, or that PUSH and POP
    /// of a segment register name: an index in `Cpu.seg` (ES, CS, SS,
    /// DS, FS, GS).
    sreg: u3 = 0,
    /// MOVZX and MOVSX: the source's size.
    src_size: Size = .b,
};

/// One table row: an opcode (0x00-0xFF, or 0x0F00-0x0FFF for two-byte
/// ones), and for group opcodes the ModRM reg field (`/digit`) and form.
pub const Row = struct {
    opcode: u16,
    ext: ?u3 = null,
    mod: Mod = .any,
    e: Entry,
};

fn r(opcode: u16, e: Entry) Row {
    return .{ .opcode = opcode, .e = e };
}

fn g(opcode: u16, ext: u3, e: Entry) Row {
    var e2 = e;
    e2.modrm = true;
    return .{ .opcode = opcode, .ext = ext, .e = e2 };
}

fn gm(opcode: u16, ext: u3, mod: Mod, e: Entry) Row {
    var e2 = e;
    e2.modrm = true;
    return .{ .opcode = opcode, .ext = ext, .mod = mod, .e = e2 };
}

/// The six forms of an ALU operation at `base`: Eb,Gb; Ev,Gv; Gb,Eb;
/// Gv,Ev; AL,Ib; eAX,Iv.
fn alu(base: u16, op: Op) [6]Row {
    const lk = op != .cmp;
    return .{
        r(base + 0, .{ .op = op, .modrm = true, .size = .b, .dst = .E, .src = .G, .lock = lk }),
        r(base + 1, .{ .op = op, .modrm = true, .size = .v, .dst = .E, .src = .G, .lock = lk }),
        r(base + 2, .{ .op = op, .modrm = true, .size = .b, .dst = .G, .src = .E }),
        r(base + 3, .{ .op = op, .modrm = true, .size = .v, .dst = .G, .src = .E }),
        r(base + 4, .{ .op = op, .size = .b, .dst = .A, .src = .I, .imm = .b }),
        r(base + 5, .{ .op = op, .size = .v, .dst = .A, .src = .I, .imm = .v }),
    };
}

/// A group-1 opcode: ADD, OR, ADC, SBB, AND, SUB, XOR, and CMP of r/m and
/// an immediate.
fn grp1(opcode: u16, size: Size, imm: Imm) [8]Row {
    const ops = [8]Op{ .add, .@"or", .adc, .sbb, .@"and", .sub, .xor, .cmp };
    var rows: [8]Row = undefined;
    for (ops, 0..) |op, i| rows[i] = g(opcode, @intCast(i), .{ .op = op, .size = size, .dst = .E, .src = .I, .imm = imm, .lock = op != .cmp });
    return rows;
}

/// A group-2 opcode: rotates and shifts of r/m by `src`.
fn grp2(opcode: u16, size: Size, src: Opd, imm: Imm) [8]Row {
    const ops = [8]Op{ .rol, .ror, .rcl, .rcr, .shl, .shr, .shl, .sar };
    var rows: [8]Row = undefined;
    for (ops, 0..) |op, i| rows[i] = g(opcode, @intCast(i), .{ .op = op, .size = size, .dst = .E, .src = src, .imm = imm, .ir = if (src == .CL) ecx else 0 });
    return rows;
}

/// A group-3 opcode: TEST, NOT, NEG, MUL, IMUL, DIV, and IDIV of r/m.
fn grp3(opcode: u16, size: Size, imm: Imm) [8]Row {
    const ax_dx: u8 = if (size == .b) eax else eax | edx;
    return .{
        g(opcode, 0, .{ .op = .@"test", .size = size, .dst = .E, .src = .I, .imm = imm }),
        g(opcode, 1, .{ .op = .@"test", .size = size, .dst = .E, .src = .I, .imm = imm }),
        g(opcode, 2, .{ .op = .not, .size = size, .dst = .E, .lock = true }),
        g(opcode, 3, .{ .op = .neg, .size = size, .dst = .E, .lock = true }),
        g(opcode, 4, .{ .op = .mul, .size = size, .src = .E, .ir = eax, .iw = ax_dx }),
        g(opcode, 5, .{ .op = .imul1, .size = size, .src = .E, .ir = eax, .iw = ax_dx }),
        // DIV and IDIV trap on a zero divisor or an overflow.
        g(opcode, 6, .{ .op = .div, .size = size, .src = .E, .ir = ax_dx, .iw = ax_dx }),
        g(opcode, 7, .{ .op = .idiv, .size = size, .src = .E, .ir = ax_dx, .iw = ax_dx }),
    };
}

/// Sixteen opcodes from `base`, one per condition (Jcc, SETcc, CMOVcc).
fn cc16(base: u16, e: Entry) [16]Row {
    var rows: [16]Row = undefined;
    for (&rows, 0..) |*row, i| row.* = r(base + @as(u16, @intCast(i)), e);
    return rows;
}

/// Eight opcodes from `base`, one per register in the low bits.
fn reg8(base: u16, e: Entry) [8]Row {
    var rows: [8]Row = undefined;
    for (&rows, 0..) |*row, i| row.* = r(base + @as(u16, @intCast(i)), e);
    return rows;
}

/// Opcodes from `lo` to `hi` that take a ModRM byte and are handled
/// elsewhere (`op`), with an imm8 if `imm`.
fn span(comptime lo: u16, comptime hi: u16, op: Op, imm: Imm) [hi - lo + 1]Row {
    var out: [hi - lo + 1]Row = undefined;
    for (&out, 0..) |*row, i| row.* = r(lo + @as(u16, @intCast(i)), .{ .op = op, .modrm = true, .imm = imm });
    return out;
}

const str_ir: u8 = esi | edi | ecx;

/// The table, in opcode order.
pub const table: []const Row = blk: {
    @setEvalBranchQuota(100_000);
    const one = alu(0x00, .add) ++ [_]Row{
        r(0x06, .{ .op = .push_sreg, .sreg = 0, .ir = esp, .iw = esp }),
        r(0x07, .{ .op = .pop_sreg, .sreg = 0, .ir = esp, .iw = esp }),
    } ++ alu(0x08, .@"or") ++ [_]Row{
        r(0x0e, .{ .op = .push_sreg, .sreg = 1, .ir = esp, .iw = esp }),
    } ++ alu(0x10, .adc) ++ [_]Row{
        r(0x16, .{ .op = .push_sreg, .sreg = 2, .ir = esp, .iw = esp }),
        r(0x17, .{ .op = .pop_sreg, .sreg = 2, .ir = esp, .iw = esp }),
    } ++ alu(0x18, .sbb) ++ [_]Row{
        r(0x1e, .{ .op = .push_sreg, .sreg = 3, .ir = esp, .iw = esp }),
        r(0x1f, .{ .op = .pop_sreg, .sreg = 3, .ir = esp, .iw = esp }),
    } ++ alu(0x20, .@"and") ++ [_]Row{
        r(0x27, .{ .op = .daa, .ir = eax, .iw = eax }),
    } ++ alu(0x28, .sub) ++ [_]Row{
        r(0x2f, .{ .op = .das, .ir = eax, .iw = eax }),
    } ++ alu(0x30, .xor) ++ [_]Row{
        r(0x37, .{ .op = .aaa, .ir = eax, .iw = eax }),
    } ++ alu(0x38, .cmp) ++ [_]Row{
        r(0x3f, .{ .op = .aas, .ir = eax, .iw = eax }),
    } ++ reg8(0x40, .{ .op = .inc, .dst = .Z }) ++
        reg8(0x48, .{ .op = .dec, .dst = .Z }) ++
        reg8(0x50, .{ .op = .push, .src = .Z, .ir = esp, .iw = esp }) ++
        reg8(0x58, .{ .op = .pop, .dst = .Z, .ir = esp, .iw = esp }) ++ [_]Row{
        r(0x60, .{ .op = .pusha, .ir = 0xff, .iw = esp }),
        r(0x61, .{ .op = .popa, .ir = esp, .iw = 0xff }),
        gm(0x62, 0, .mem, .{ .op = .bound, .src = .G, .dst = .E, .end = true }),
        gm(0x62, 1, .mem, .{ .op = .bound, .src = .G, .dst = .E, .end = true }),
        gm(0x62, 2, .mem, .{ .op = .bound, .src = .G, .dst = .E, .end = true }),
        gm(0x62, 3, .mem, .{ .op = .bound, .src = .G, .dst = .E, .end = true }),
        gm(0x62, 4, .mem, .{ .op = .bound, .src = .G, .dst = .E, .end = true }),
        gm(0x62, 5, .mem, .{ .op = .bound, .src = .G, .dst = .E, .end = true }),
        gm(0x62, 6, .mem, .{ .op = .bound, .src = .G, .dst = .E, .end = true }),
        gm(0x62, 7, .mem, .{ .op = .bound, .src = .G, .dst = .E, .end = true }),
        r(0x68, .{ .op = .push, .src = .I, .imm = .v, .ir = esp, .iw = esp }),
        r(0x69, .{ .op = .imul, .modrm = true, .dst = .G, .src = .E, .imm = .v }),
        r(0x6a, .{ .op = .push, .src = .I, .imm = .bs, .ir = esp, .iw = esp }),
        r(0x6b, .{ .op = .imul, .modrm = true, .dst = .G, .src = .E, .imm = .bs }),
        r(0x6c, .{ .op = .gp, .end = true }),
        r(0x6d, .{ .op = .gp, .end = true }),
        r(0x6e, .{ .op = .gp, .end = true }),
        r(0x6f, .{ .op = .gp, .end = true }),
    } ++ cc16(0x70, .{ .op = .jcc, .imm = .bs, .end = true }) ++
        grp1(0x80, .b, .b) ++ grp1(0x81, .v, .v) ++ grp1(0x82, .b, .b) ++ grp1(0x83, .v, .bs) ++ [_]Row{
        r(0x84, .{ .op = .@"test", .modrm = true, .size = .b, .dst = .E, .src = .G }),
        r(0x85, .{ .op = .@"test", .modrm = true, .size = .v, .dst = .E, .src = .G }),
        // XCHG with memory is locked whether it says so or not.
        r(0x86, .{ .op = .xchg, .modrm = true, .size = .b, .dst = .E, .src = .G, .lock = true }),
        r(0x87, .{ .op = .xchg, .modrm = true, .size = .v, .dst = .E, .src = .G, .lock = true }),
        r(0x88, .{ .op = .mov, .modrm = true, .size = .b, .dst = .E, .src = .G }),
        r(0x89, .{ .op = .mov, .modrm = true, .size = .v, .dst = .E, .src = .G }),
        r(0x8a, .{ .op = .mov, .modrm = true, .size = .b, .dst = .G, .src = .E }),
        r(0x8b, .{ .op = .mov, .modrm = true, .size = .v, .dst = .G, .src = .E }),
        // MOV r/m, Sreg stores a word to memory, but writes a whole
        // register with the selector zero-extended under a 32-bit size.
        r(0x8c, .{ .op = .mov_from_sreg, .modrm = true, .size = .v, .dst = .E, .src = .S }),
        gm(0x8d, 0, .mem, .{ .op = .lea, .dst = .G, .src = .E }),
        gm(0x8d, 1, .mem, .{ .op = .lea, .dst = .G, .src = .E }),
        gm(0x8d, 2, .mem, .{ .op = .lea, .dst = .G, .src = .E }),
        gm(0x8d, 3, .mem, .{ .op = .lea, .dst = .G, .src = .E }),
        gm(0x8d, 4, .mem, .{ .op = .lea, .dst = .G, .src = .E }),
        gm(0x8d, 5, .mem, .{ .op = .lea, .dst = .G, .src = .E }),
        gm(0x8d, 6, .mem, .{ .op = .lea, .dst = .G, .src = .E }),
        gm(0x8d, 7, .mem, .{ .op = .lea, .dst = .G, .src = .E }),
        r(0x8e, .{ .op = .mov_sreg, .modrm = true, .size = .w, .dst = .S, .src = .E }),
        g(0x8f, 0, .{ .op = .pop, .dst = .E, .ir = esp, .iw = esp }),
        r(0x90, .{ .op = .nop }),
    } ++ [_]Row{
        r(0x91, .{ .op = .xchg, .dst = .Z, .src = .A }),
        r(0x92, .{ .op = .xchg, .dst = .Z, .src = .A }),
        r(0x93, .{ .op = .xchg, .dst = .Z, .src = .A }),
        r(0x94, .{ .op = .xchg, .dst = .Z, .src = .A }),
        r(0x95, .{ .op = .xchg, .dst = .Z, .src = .A }),
        r(0x96, .{ .op = .xchg, .dst = .Z, .src = .A }),
        r(0x97, .{ .op = .xchg, .dst = .Z, .src = .A }),
        r(0x98, .{ .op = .cbw, .ir = eax, .iw = eax }),
        r(0x99, .{ .op = .cwd, .ir = eax, .iw = edx }),
        r(0x9a, .{ .op = .gp, .imm = .ptr, .end = true }),
        r(0x9b, .{ .op = .fwait }),
        r(0x9c, .{ .op = .pushf, .ir = esp, .iw = esp }),
        r(0x9d, .{ .op = .popf, .ir = esp, .iw = esp }),
        r(0x9e, .{ .op = .sahf, .ir = eax }),
        r(0x9f, .{ .op = .lahf, .iw = eax }),
        r(0xa0, .{ .op = .mov, .size = .b, .dst = .A, .src = .O }),
        r(0xa1, .{ .op = .mov, .size = .v, .dst = .A, .src = .O }),
        r(0xa2, .{ .op = .mov, .size = .b, .dst = .O, .src = .A }),
        r(0xa3, .{ .op = .mov, .size = .v, .dst = .O, .src = .A }),
        r(0xa4, .{ .op = .movs, .size = .b, .ir = str_ir, .iw = str_ir }),
        r(0xa5, .{ .op = .movs, .size = .v, .ir = str_ir, .iw = str_ir }),
        r(0xa6, .{ .op = .cmps, .size = .b, .ir = str_ir, .iw = str_ir }),
        r(0xa7, .{ .op = .cmps, .size = .v, .ir = str_ir, .iw = str_ir }),
        r(0xa8, .{ .op = .@"test", .size = .b, .dst = .A, .src = .I, .imm = .b }),
        r(0xa9, .{ .op = .@"test", .size = .v, .dst = .A, .src = .I, .imm = .v }),
        r(0xaa, .{ .op = .stos, .size = .b, .ir = edi | ecx | eax, .iw = edi | ecx }),
        r(0xab, .{ .op = .stos, .size = .v, .ir = edi | ecx | eax, .iw = edi | ecx }),
        r(0xac, .{ .op = .lods, .size = .b, .ir = esi | ecx, .iw = esi | ecx | eax }),
        r(0xad, .{ .op = .lods, .size = .v, .ir = esi | ecx, .iw = esi | ecx | eax }),
        r(0xae, .{ .op = .scas, .size = .b, .ir = edi | ecx | eax, .iw = edi | ecx }),
        r(0xaf, .{ .op = .scas, .size = .v, .ir = edi | ecx | eax, .iw = edi | ecx }),
    } ++ reg8(0xb0, .{ .op = .mov, .size = .b, .dst = .Z, .src = .I, .imm = .b }) ++
        reg8(0xb8, .{ .op = .mov, .size = .v, .dst = .Z, .src = .I, .imm = .v }) ++
        grp2(0xc0, .b, .I, .b) ++ grp2(0xc1, .v, .I, .b) ++ [_]Row{
        r(0xc2, .{ .op = .ret, .imm = .w, .ir = esp, .iw = esp, .end = true }),
        r(0xc3, .{ .op = .ret, .ir = esp, .iw = esp, .end = true }),
        gm(0xc4, 0, .mem, .{ .op = .lseg, .sreg = 0, .dst = .G, .src = .E }),
        gm(0xc4, 1, .mem, .{ .op = .lseg, .sreg = 0, .dst = .G, .src = .E }),
        gm(0xc4, 2, .mem, .{ .op = .lseg, .sreg = 0, .dst = .G, .src = .E }),
        gm(0xc4, 3, .mem, .{ .op = .lseg, .sreg = 0, .dst = .G, .src = .E }),
        gm(0xc4, 4, .mem, .{ .op = .lseg, .sreg = 0, .dst = .G, .src = .E }),
        gm(0xc4, 5, .mem, .{ .op = .lseg, .sreg = 0, .dst = .G, .src = .E }),
        gm(0xc4, 6, .mem, .{ .op = .lseg, .sreg = 0, .dst = .G, .src = .E }),
        gm(0xc4, 7, .mem, .{ .op = .lseg, .sreg = 0, .dst = .G, .src = .E }),
        gm(0xc5, 0, .mem, .{ .op = .lseg, .sreg = 3, .dst = .G, .src = .E }),
        gm(0xc5, 1, .mem, .{ .op = .lseg, .sreg = 3, .dst = .G, .src = .E }),
        gm(0xc5, 2, .mem, .{ .op = .lseg, .sreg = 3, .dst = .G, .src = .E }),
        gm(0xc5, 3, .mem, .{ .op = .lseg, .sreg = 3, .dst = .G, .src = .E }),
        gm(0xc5, 4, .mem, .{ .op = .lseg, .sreg = 3, .dst = .G, .src = .E }),
        gm(0xc5, 5, .mem, .{ .op = .lseg, .sreg = 3, .dst = .G, .src = .E }),
        gm(0xc5, 6, .mem, .{ .op = .lseg, .sreg = 3, .dst = .G, .src = .E }),
        gm(0xc5, 7, .mem, .{ .op = .lseg, .sreg = 3, .dst = .G, .src = .E }),
        g(0xc6, 0, .{ .op = .mov, .size = .b, .dst = .E, .src = .I, .imm = .b }),
        g(0xc7, 0, .{ .op = .mov, .size = .v, .dst = .E, .src = .I, .imm = .v }),
        r(0xc8, .{ .op = .enter, .imm = .wb, .ir = esp | ebp, .iw = esp | ebp }),
        r(0xc9, .{ .op = .leave, .ir = esp | ebp, .iw = esp | ebp }),
        r(0xca, .{ .op = .gp, .imm = .w, .end = true }),
        r(0xcb, .{ .op = .gp, .end = true }),
        r(0xcc, .{ .op = .int3, .end = true }),
        r(0xcd, .{ .op = .int, .imm = .b, .end = true }),
        r(0xce, .{ .op = .into, .end = true }),
        r(0xcf, .{ .op = .gp, .end = true }),
    } ++ grp2(0xd0, .b, .one, .none) ++ grp2(0xd1, .v, .one, .none) ++
        grp2(0xd2, .b, .CL, .none) ++ grp2(0xd3, .v, .CL, .none) ++ [_]Row{
        r(0xd4, .{ .op = .aam, .imm = .b, .ir = eax, .iw = eax, .end = true }),
        r(0xd5, .{ .op = .aad, .imm = .b, .ir = eax, .iw = eax }),
        r(0xd6, .{ .op = .salc, .iw = eax }),
        r(0xd7, .{ .op = .xlat, .ir = eax | ebx, .iw = eax }),
    } ++ span(0xd8, 0xdf, .x87, .none) ++ [_]Row{
        r(0xe0, .{ .op = .loopne, .imm = .bs, .ir = ecx, .iw = ecx, .end = true }),
        r(0xe1, .{ .op = .loope, .imm = .bs, .ir = ecx, .iw = ecx, .end = true }),
        r(0xe2, .{ .op = .loop, .imm = .bs, .ir = ecx, .iw = ecx, .end = true }),
        r(0xe3, .{ .op = .jcxz, .imm = .bs, .ir = ecx, .end = true }),
        r(0xe4, .{ .op = .gp, .imm = .b, .end = true }),
        r(0xe5, .{ .op = .gp, .imm = .b, .end = true }),
        r(0xe6, .{ .op = .gp, .imm = .b, .end = true }),
        r(0xe7, .{ .op = .gp, .imm = .b, .end = true }),
        r(0xe8, .{ .op = .call, .imm = .v, .ir = esp, .iw = esp, .end = true }),
        r(0xe9, .{ .op = .jmp, .imm = .v, .end = true }),
        r(0xea, .{ .op = .gp, .imm = .ptr, .end = true }),
        r(0xeb, .{ .op = .jmp, .imm = .bs, .end = true }),
        r(0xec, .{ .op = .gp, .end = true }),
        r(0xed, .{ .op = .gp, .end = true }),
        r(0xee, .{ .op = .gp, .end = true }),
        r(0xef, .{ .op = .gp, .end = true }),
        r(0xf1, .{ .op = .gp, .end = true }),
        r(0xf4, .{ .op = .gp, .end = true }),
        r(0xf5, .{ .op = .cmc }),
    } ++ grp3(0xf6, .b, .b) ++ grp3(0xf7, .v, .v) ++ [_]Row{
        r(0xf8, .{ .op = .clc }),
        r(0xf9, .{ .op = .stc }),
        r(0xfa, .{ .op = .gp, .end = true }),
        r(0xfb, .{ .op = .gp, .end = true }),
        r(0xfc, .{ .op = .cld }),
        r(0xfd, .{ .op = .std }),
        g(0xfe, 0, .{ .op = .inc, .size = .b, .dst = .E, .lock = true }),
        g(0xfe, 1, .{ .op = .dec, .size = .b, .dst = .E, .lock = true }),
        g(0xff, 0, .{ .op = .inc, .size = .v, .dst = .E, .lock = true }),
        g(0xff, 1, .{ .op = .dec, .size = .v, .dst = .E, .lock = true }),
        g(0xff, 2, .{ .op = .call_ind, .src = .E, .ir = esp, .iw = esp, .end = true }),
        g(0xff, 3, .{ .op = .gp, .end = true }),
        g(0xff, 4, .{ .op = .jmp_ind, .src = .E, .end = true }),
        g(0xff, 5, .{ .op = .gp, .end = true }),
        g(0xff, 6, .{ .op = .push, .src = .E, .ir = esp, .iw = esp }),
    };

    const two = [_]Row{
        // SLDT, STR, LLDT, LTR, VERR, and VERW; SGDT and the rest.
        r(0x0f00, .{ .op = .gp, .modrm = true, .end = true }),
        r(0x0f01, .{ .op = .gp, .modrm = true, .end = true }),
        r(0x0f06, .{ .op = .gp, .end = true }),
        r(0x0f08, .{ .op = .gp, .end = true }),
        r(0x0f09, .{ .op = .gp, .end = true }),
        r(0x0f0b, .{ .op = .ud, .end = true }),
        // PREFETCH and PREFETCHW (0D), and the hint NOPs, which include
        // PREFETCHh (18), multi-byte NOP (1F), and ENDBR32 (F3 0F 1E FB).
    } ++ [_]Row{r(0x0f0d, .{ .op = .nop, .modrm = true })} ++
        span(0x0f10, 0x0f17, .sse, .none) ++
        span(0x0f18, 0x0f1f, .nop, .none) ++ [_]Row{
        r(0x0f20, .{ .op = .gp, .modrm = true, .end = true }),
        r(0x0f21, .{ .op = .gp, .modrm = true, .end = true }),
        r(0x0f22, .{ .op = .gp, .modrm = true, .end = true }),
        r(0x0f23, .{ .op = .gp, .modrm = true, .end = true }),
    } ++ span(0x0f28, 0x0f2f, .sse, .none) ++ [_]Row{
        r(0x0f30, .{ .op = .gp, .end = true }),
        r(0x0f31, .{ .op = .rdtsc, .iw = eax | edx }),
        r(0x0f32, .{ .op = .gp, .end = true }),
        r(0x0f33, .{ .op = .gp, .end = true }),
        r(0x0f34, .{ .op = .gp, .end = true }),
        r(0x0f35, .{ .op = .gp, .end = true }),
    } ++ cc16(0x0f40, .{ .op = .cmovcc, .modrm = true, .dst = .G, .src = .E }) ++
        span(0x0f50, 0x0f6f, .sse, .none) ++
        span(0x0f70, 0x0f73, .sse, .b) ++
        span(0x0f74, 0x0f76, .sse, .none) ++
        // EMMS, which has no ModRM byte.
        [_]Row{r(0x0f77, .{ .op = .sse })} ++
        span(0x0f7e, 0x0f7f, .sse, .none) ++
        cc16(0x0f80, .{ .op = .jcc, .imm = .v, .end = true }) ++
        cc16(0x0f90, .{ .op = .setcc, .modrm = true, .size = .b, .dst = .E }) ++ [_]Row{
        r(0x0fa0, .{ .op = .push_sreg, .sreg = 4, .ir = esp, .iw = esp }),
        r(0x0fa1, .{ .op = .pop_sreg, .sreg = 4, .ir = esp, .iw = esp }),
        r(0x0fa2, .{ .op = .cpuid, .ir = eax | ecx, .iw = eax | ecx | edx | ebx }),
        r(0x0fa3, .{ .op = .bt, .modrm = true, .dst = .E, .src = .G }),
        r(0x0fa4, .{ .op = .shld, .modrm = true, .dst = .E, .src = .G, .imm = .b }),
        r(0x0fa5, .{ .op = .shld, .modrm = true, .dst = .E, .src = .G, .ir = ecx }),
        r(0x0fa8, .{ .op = .push_sreg, .sreg = 5, .ir = esp, .iw = esp }),
        r(0x0fa9, .{ .op = .pop_sreg, .sreg = 5, .ir = esp, .iw = esp }),
        r(0x0fab, .{ .op = .bts, .modrm = true, .dst = .E, .src = .G, .lock = true }),
        r(0x0fac, .{ .op = .shrd, .modrm = true, .dst = .E, .src = .G, .imm = .b }),
        r(0x0fad, .{ .op = .shrd, .modrm = true, .dst = .E, .src = .G, .ir = ecx }),
        // FXSAVE, FXRSTOR, LDMXCSR, and STMXCSR; CLFLUSH; the fences.
        gm(0x0fae, 0, .mem, .{ .op = .sse }),
        gm(0x0fae, 1, .mem, .{ .op = .sse }),
        gm(0x0fae, 2, .mem, .{ .op = .sse }),
        gm(0x0fae, 3, .mem, .{ .op = .sse }),
        gm(0x0fae, 7, .mem, .{ .op = .nop }),
        gm(0x0fae, 5, .reg, .{ .op = .fence }),
        gm(0x0fae, 6, .reg, .{ .op = .fence }),
        gm(0x0fae, 7, .reg, .{ .op = .fence }),
        r(0x0faf, .{ .op = .imul, .modrm = true, .dst = .G, .src = .E }),
        r(0x0fb0, .{ .op = .cmpxchg, .modrm = true, .size = .b, .dst = .E, .src = .G, .ir = eax, .iw = eax, .lock = true }),
        r(0x0fb1, .{ .op = .cmpxchg, .modrm = true, .size = .v, .dst = .E, .src = .G, .ir = eax, .iw = eax, .lock = true }),
    } ++ lsegs(0x0fb2, 2) ++ [_]Row{
        r(0x0fb3, .{ .op = .btr, .modrm = true, .dst = .E, .src = .G, .lock = true }),
    } ++ lsegs(0x0fb4, 4) ++ lsegs(0x0fb5, 5) ++ [_]Row{
        r(0x0fb6, .{ .op = .movzx, .modrm = true, .dst = .G, .src = .E, .src_size = .b }),
        r(0x0fb7, .{ .op = .movzx, .modrm = true, .dst = .G, .src = .E, .src_size = .w }),
        r(0x0fb9, .{ .op = .ud, .modrm = true, .end = true }),
        g(0x0fba, 4, .{ .op = .bt, .dst = .E, .src = .I, .imm = .b }),
        g(0x0fba, 5, .{ .op = .bts, .dst = .E, .src = .I, .imm = .b, .lock = true }),
        g(0x0fba, 6, .{ .op = .btr, .dst = .E, .src = .I, .imm = .b, .lock = true }),
        g(0x0fba, 7, .{ .op = .btc, .dst = .E, .src = .I, .imm = .b, .lock = true }),
        r(0x0fbb, .{ .op = .btc, .modrm = true, .dst = .E, .src = .G, .lock = true }),
        // With F3, TZCNT and LZCNT on CPUs with BMI1 and ABM; this one
        // reports neither, so they run as BSF and BSR, as on older CPUs.
        r(0x0fbc, .{ .op = .bsf, .modrm = true, .dst = .G, .src = .E }),
        r(0x0fbd, .{ .op = .bsr, .modrm = true, .dst = .G, .src = .E }),
        r(0x0fbe, .{ .op = .movsx, .modrm = true, .dst = .G, .src = .E, .src_size = .b }),
        r(0x0fbf, .{ .op = .movsx, .modrm = true, .dst = .G, .src = .E, .src_size = .w }),
        r(0x0fc0, .{ .op = .xadd, .modrm = true, .size = .b, .dst = .E, .src = .G, .lock = true }),
        r(0x0fc1, .{ .op = .xadd, .modrm = true, .size = .v, .dst = .E, .src = .G, .lock = true }),
    } ++ span(0x0fc2, 0x0fc2, .sse, .b) ++ span(0x0fc3, 0x0fc3, .sse, .none) ++
        span(0x0fc4, 0x0fc6, .sse, .b) ++ [_]Row{
        gm(0x0fc7, 1, .mem, .{ .op = .cmpxchg8b, .dst = .E, .size = .d, .ir = eax | edx | ecx | ebx, .iw = eax | edx, .lock = true }),
    } ++ reg8(0x0fc8, .{ .op = .bswap, .size = .d, .dst = .Z }) ++
        span(0x0fd0, 0x0fff, .sse, .none);

    // 0F FF is UD0, which takes a ModRM byte; it stays #UD via sse.zig.
    break :blk &(one ++ two);
};

fn lsegs(opcode: u16, sreg: u3) [8]Row {
    var out: [8]Row = undefined;
    for (&out, 0..) |*row, i| row.* = gm(opcode, @intCast(i), .mem, .{ .op = .lseg, .sreg = sreg, .dst = .G, .src = .E });
    return out;
}

/// An opcode's place in the lookup: an index into `entries`, and whether
/// its entry depends on the ModRM byte (16 entries from there: one per
/// reg field and form, memory then register).
pub const Slot = packed struct(u16) {
    first: u14,
    grouped: bool,
    modrm: bool,
};

/// Opcode index: one-byte opcodes are 0-255, two-byte ones 256-511.
pub inline fn index(opcode: u16) u9 {
    return if (opcode >= 0x0f00) @intCast(256 + (opcode & 0xff)) else @intCast(opcode);
}

const Lookup = struct {
    slots: [512]Slot,
    entries: []const Entry,
};

const lookup: Lookup = blk: {
    @setEvalBranchQuota(1_000_000);
    var grouped: [512]bool = @splat(false);
    var modrm: [512]bool = @splat(false);
    var count: [512]u16 = @splat(0);
    for (table) |row| {
        const i = index(row.opcode);
        if (row.ext != null) grouped[i] = true;
        if (row.e.modrm) modrm[i] = true;
        count[i] += 1;
    }
    var slots: [512]Slot = @splat(.{ .first = 0, .grouped = false, .modrm = false });
    // Entry 0 is #UD, for opcodes not in the table.
    var entries: [2048]Entry = undefined;
    entries[0] = .{ .op = .ud, .end = true };
    var n: usize = 1;
    for (0..512) |i| {
        if (count[i] == 0) continue;
        if (grouped[i]) {
            if (!modrm[i]) @compileError("group without ModRM");
            slots[i] = .{ .first = @intCast(n), .grouped = true, .modrm = true };
            for (0..16) |k| entries[n + k] = .{ .op = .ud, .modrm = true, .end = true };
            n += 16;
        } else {
            if (count[i] != 1) @compileError("opcode listed twice");
            slots[i] = .{ .first = @intCast(n), .grouped = false, .modrm = modrm[i] };
            n += 1;
        }
    }
    for (table) |row| {
        const s = slots[index(row.opcode)];
        if (!s.grouped) {
            entries[s.first] = row.e;
            continue;
        }
        const ext = row.ext orelse @compileError("group row without /digit");
        if (row.mod != .reg) entries[s.first + 2 * @as(usize, ext)] = row.e;
        if (row.mod != .mem) entries[s.first + 2 * @as(usize, ext) + 1] = row.e;
    }
    const out = entries[0..n].*;
    break :blk .{ .slots = slots, .entries = &out };
};

/// The slot for `opcode`.
pub inline fn slot(opcode: u16) Slot {
    return lookup.slots[index(opcode)];
}

/// The entry for `opcode` with ModRM byte `modrm` (ignored unless the
/// slot is grouped).
pub inline fn entry(s: Slot, modrm: u8) *const Entry {
    if (!s.grouped) return &lookup.entries[s.first];
    const ext: u14 = (modrm >> 3) & 7;
    const reg: u14 = @intFromBool(modrm >= 0xc0);
    return &lookup.entries[s.first + 2 * ext + reg];
}

/// The entry index `entry` came from, for a decoded instruction to carry
/// as a small handle.
pub inline fn entryIndex(e: *const Entry) u16 {
    return @intCast(e - lookup.entries.ptr);
}

pub inline fn entryAt(i: u16) *const Entry {
    return &lookup.entries[i];
}

test "lookup" {
    const add = entry(slot(0x01), 0xc0);
    try std.testing.expectEqual(Op.add, add.op);
    try std.testing.expect(add.modrm and add.dst == .E and add.src == .G);
    try std.testing.expectEqual(Op.sub, entry(slot(0x83), 0xe8).op);
    try std.testing.expectEqual(Op.cmp, entry(slot(0x83), 0xf8).op);
    try std.testing.expectEqual(Op.ud, entry(slot(0x0f0b), 0).op);
    try std.testing.expectEqual(Op.ud, entry(slot(0x0f38), 0).op);
    // LEA needs a memory operand.
    try std.testing.expectEqual(Op.lea, entry(slot(0x8d), 0x00).op);
    try std.testing.expectEqual(Op.ud, entry(slot(0x8d), 0xc0).op);
    try std.testing.expectEqual(Op.fence, entry(slot(0x0fae), 0xf0).op);
    try std.testing.expectEqual(Op.idiv, entry(slot(0xf7), 0xf8).op);
}
