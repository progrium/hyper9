//! ha64's decoder: an A64 instruction word to a micro-op (`Op`), and each
//! micro-op's register read and write sets (`regs`), for all of Armv8.0 at
//! EL0. T0 (exec.zig), the lifter (src/jit/a64/lift.zig), and the inventory
//! tool (tools/a64inv.zig) share it.
//!
//! The integer, branch, system, and load/store classes are here, including
//! loads and stores of the FP/SIMD registers. FP and AdvSIMD data
//! processing, and the SIMD structure loads and stores, go to
//! simd_decode.zig, whose kinds start at `simd_base`. Anything neither
//! implements decodes to `.undef`, which faults with EC 0 if it runs.
//!
//! Operand fields, by convention (each kind's comment says where it
//! differs):
//!
//!   d   the destination (Rd, Rt), or the status register of STXR
//!   n   the first source or the base register (Rn)
//!   m   the second source (Rm), the data register of a store-exclusive,
//!       or Rt2 of a pair
//!   a   the third source (Ra), or a sub-operation
//!   x   an addressing mode, a condition, a shift type, or a size
//!   sh  a shift amount, a bit position, or a field's low bit
//!   imm an immediate, an address, or a branch target (already PC-relative
//!       resolved: decoding takes the PC)
//!
//! General registers are slots in Cpu.r: 0-30 are X0-X30, reads of ZR use
//! slot 31 (always 0), writes to ZR go to slot 32 (a sink), and SP is slot
//! 33. The decoder resolves which an encoding means, so handlers never test
//! for register 31. FP/SIMD registers are 0-31 in Cpu.v.

const std = @import("std");
const simd = @import("simd_decode.zig");
const ext = @import("ext.zig");

pub const ZR = 31;
pub const SINK = 32;
pub const SP = 33;
pub const nslots = 34;

/// Kinds at and above this are simd_decode.zig's.
pub const simd_base: u16 = 0x100;
/// Kinds at and above this are ext.zig's: the optional extensions (CRC32,
/// and the cryptographic ones).
pub const ext_base: u16 = 0x400;

comptime {
    std.debug.assert(@typeInfo(simd.Kind).@"enum".fields.len <= ext_base - simd_base);
}

pub const Kind = enum(u16) {
    /// Not implemented, or unallocated: faults with EC 0.
    undef,
    /// The sentinel after a decoded page's last op: imm is the next page.
    next_page,

    // ---- data processing, immediate
    /// Rd = imm: MOVZ, MOVN, ADR, ADRP, and ORR (immediate) from ZR.
    movi,
    /// MOVK: imm is the 16 bits, sh their position.
    movk_x,
    movk_w,
    /// ADD and SUB (immediate) without flags: SUB's imm is negated.
    add_imm_x,
    add_imm_w,
    adds_imm_x,
    adds_imm_w,
    subs_imm_x,
    subs_imm_w,
    and_imm_x,
    and_imm_w,
    orr_imm_x,
    orr_imm_w,
    eor_imm_x,
    eor_imm_w,
    ands_imm_x,
    ands_imm_w,
    /// Bitfield moves, as their aliases: sh is the field's low bit, a its
    /// width. UBFX and SBFX extract to bit 0; UBFIZ and SBFIZ insert at sh
    /// with the rest zero; BFXIL and BFI keep the rest of Rd.
    ubfx_x,
    ubfx_w,
    ubfiz_x,
    ubfiz_w,
    sbfx_x,
    sbfx_w,
    sbfiz_x,
    sbfiz_w,
    bfxil_x,
    bfxil_w,
    bfi_x,
    bfi_w,
    /// EXTR: sh is lsb.
    extr_x,
    extr_w,

    // ---- data processing, register
    /// ORR Rd, ZR, Rm.
    mov_x,
    mov_w,
    /// Logical (shifted register), in opc:N order, X then W: x is the shift
    /// type, sh the amount.
    and_sreg_x,
    and_sreg_w,
    bic_sreg_x,
    bic_sreg_w,
    orr_sreg_x,
    orr_sreg_w,
    orn_sreg_x,
    orn_sreg_w,
    eor_sreg_x,
    eor_sreg_w,
    eon_sreg_x,
    eon_sreg_w,
    ands_sreg_x,
    ands_sreg_w,
    bics_sreg_x,
    bics_sreg_w,
    /// Add and subtract (shifted register): x is the shift type, sh the
    /// amount.
    add_sreg_x,
    add_sreg_w,
    adds_sreg_x,
    adds_sreg_w,
    sub_sreg_x,
    sub_sreg_w,
    subs_sreg_x,
    subs_sreg_w,
    /// ADD and SUB (shifted register) with no shift.
    add_reg_x,
    add_reg_w,
    sub_reg_x,
    sub_reg_w,
    /// Add and subtract (extended register): x is the extend option, sh
    /// the left shift.
    add_ereg_x,
    add_ereg_w,
    adds_ereg_x,
    adds_ereg_w,
    sub_ereg_x,
    sub_ereg_w,
    subs_ereg_x,
    subs_ereg_w,
    adc_x,
    adc_w,
    adcs_x,
    adcs_w,
    sbc_x,
    sbc_w,
    sbcs_x,
    sbcs_w,
    /// CCMP and CCMN: x is the condition, sh the NZCV to set when it
    /// fails; a bit 0 is the immediate form (imm), a bit 1 is CCMN.
    ccmp_x,
    ccmp_w,
    /// CSEL, CSINC, CSINV, CSNEG by a (0-3): x is the condition.
    csel_x,
    csel_w,
    rbit_x,
    rbit_w,
    rev16_x,
    rev16_w,
    rev32_x,
    rev_x,
    rev_w,
    clz_x,
    clz_w,
    cls_x,
    cls_w,
    udiv_x,
    udiv_w,
    sdiv_x,
    sdiv_w,
    lslv_x,
    lslv_w,
    lsrv_x,
    lsrv_w,
    asrv_x,
    asrv_w,
    rorv_x,
    rorv_w,
    madd_x,
    madd_w,
    msub_x,
    msub_w,
    smaddl,
    smsubl,
    umaddl,
    umsubl,
    smulh,
    umulh,

    // ---- branches and exceptions
    /// imm is the target.
    b,
    bl,
    /// x is the condition, imm the target.
    bcond,
    cbz_x,
    cbz_w,
    cbnz_x,
    cbnz_w,
    /// sh is the bit, imm the target.
    tbz,
    tbnz,
    br,
    blr,
    ret,
    /// imm is the 16-bit immediate.
    svc,
    brk,

    // ---- system
    /// Hints (NOP, YIELD, WFE, WFI, SEV, SEVL, and the hint space later
    /// architectures use, such as BTI and PACIASP), and the EL0 cache
    /// maintenance that has no effect here (DC CVAU, CVAC, CIVAC, IC IVAU).
    nop,
    clrex,
    /// DMB and DSB.
    fence,
    /// imm is the system register (`sysreg`): MRS into d, MSR from n.
    mrs,
    msr,
    /// DC ZVA: n holds the address.
    dc_zva,

    // ---- loads and stores of one register
    // _o is base + imm (unsigned offset, unscaled, and unprivileged); _m is
    // the other modes, by x: 1 post-index, 3 pre-index (imm the offset),
    // 4 literal (imm the address), 5 register offset (m extended by option
    // a and shifted left by sh). The _v kinds load and store FP/SIMD
    // registers: d is a V register.
    ldr_x_o,
    ldr_w_o,
    ldrb_o,
    ldrh_o,
    ldrsb_x_o,
    ldrsb_w_o,
    ldrsh_x_o,
    ldrsh_w_o,
    ldrsw_o,
    str_x_o,
    str_w_o,
    strb_o,
    strh_o,
    ldr_vb_o,
    ldr_vh_o,
    ldr_vs_o,
    ldr_vd_o,
    ldr_vq_o,
    str_vb_o,
    str_vh_o,
    str_vs_o,
    str_vd_o,
    str_vq_o,
    ldr_x_m,
    ldr_w_m,
    ldrb_m,
    ldrh_m,
    ldrsb_x_m,
    ldrsb_w_m,
    ldrsh_x_m,
    ldrsh_w_m,
    ldrsw_m,
    str_x_m,
    str_w_m,
    strb_m,
    strh_m,
    ldr_vb_m,
    ldr_vh_m,
    ldr_vs_m,
    ldr_vd_m,
    ldr_vq_m,
    str_vb_m,
    str_vh_m,
    str_vs_m,
    str_vd_m,
    str_vq_m,

    // ---- pairs: d is Rt, m is Rt2, imm the scaled offset; x is the mode
    // (1 post-index, 2 offset, 3 pre-index; LDNP and STNP are offsets).
    ldp_x,
    ldp_w,
    ldpsw,
    stp_x,
    stp_w,
    ldp_vs,
    ldp_vd,
    ldp_vq,
    stp_vs,
    stp_vd,
    stp_vq,

    // ---- exclusives and acquire/release: x is log2 of the size, sh is 1
    // for the acquire or release forms. Loads: d is Rt (a is Rt2 for
    // pairs). Stores: d is the status register Rs, m is Rt (a is Rt2).
    ldxr,
    stxr,
    ldxp,
    stxp,
    ldar,
    stlr,

    // ---- LSE atomics (Armv8.1): x is log2 of the size, sh bit 0 acquire
    // and bit 1 release; n is the base.
    /// LDADD, LDCLR, LDEOR, LDSET, LDSMAX, LDSMIN, LDUMAX, LDUMIN, and SWP by
    /// a (0-8), and their ST aliases (d is ZR): d gets the old value, m is
    /// the operand.
    ldop,
    /// CAS: d is Rs, compared and then given the old value; m is Rt, the
    /// new value.
    cas,
    /// CASP: as CAS on the register pairs d, d+1 and m, m+1 (x is 2 or 3).
    casp,

    /// ISB: later instructions are fetched again (a store to code before
    /// it is seen).
    isb,

    /// simd_decode.zig's kinds, from `simd_base` up.
    _,

    pub fn isSimd(k: Kind) bool {
        return @intFromEnum(k) >= simd_base and @intFromEnum(k) < ext_base;
    }

    pub fn isExt(k: Kind) bool {
        return @intFromEnum(k) >= ext_base;
    }
};

/// How many kinds decode.zig has (the handler table's size).
pub const nkinds = blk: {
    const fields = @typeInfo(Kind).@"enum".fields;
    std.debug.assert(fields.len < simd_base);
    break :blk fields.len;
};

pub const Op = extern struct {
    k: Kind = .undef,
    d: u8 = 0,
    n: u8 = 0,
    m: u8 = 0,
    a: u8 = 0,
    x: u8 = 0,
    sh: u8 = 0,
    imm: u64 = 0,
};

comptime {
    std.debug.assert(@sizeOf(Op) == 16);
}

/// A system register as MRS and MSR encode it: op0:op1:CRn:CRm:op2.
pub fn sysreg(op0: u2, op1: u3, crn: u4, crm: u4, op2: u3) u16 {
    return @as(u16, op0) << 14 | @as(u16, op1) << 11 | @as(u16, crn) << 7 | @as(u16, crm) << 3 | op2;
}

pub const sr = struct {
    pub const nzcv = sysreg(3, 3, 4, 2, 0);
    pub const fpcr = sysreg(3, 3, 4, 4, 0);
    pub const fpsr = sysreg(3, 3, 4, 4, 1);
    pub const tpidr_el0 = sysreg(3, 3, 13, 0, 2);
    pub const tpidrro_el0 = sysreg(3, 3, 13, 0, 3);
    pub const cntfrq_el0 = sysreg(3, 3, 14, 0, 0);
    pub const cntvct_el0 = sysreg(3, 3, 14, 0, 2);
    pub const ctr_el0 = sysreg(3, 3, 0, 0, 1);
    pub const dczid_el0 = sysreg(3, 3, 0, 0, 7);
};

// ---------------------------------------------------------------- read and write sets

pub const Use = enum(u2) { none, r, w, rw };

pub const MemUse = enum(u3) {
    none,
    load,
    store,
    /// Load-exclusive: sets the monitor.
    load_exclusive,
    /// Store-exclusive: checks the monitor and writes a status.
    store_exclusive,
    /// An atomic read-modify-write (LSE).
    rmw,
};

pub const Ctrl = enum(u4) {
    /// Falls through to the next instruction.
    none,
    /// B: always to imm.
    jump,
    /// B.cond, CBZ, CBNZ, TBZ, TBNZ: to imm or the next instruction.
    cond,
    /// BL: to imm, writing X30.
    call,
    /// BR: to a register.
    indirect,
    /// BLR: to a register, writing X30.
    call_indirect,
    /// RET: to a register.
    ret,
    /// SVC: a system call exit.
    svc,
    /// BRK: a breakpoint exit.
    brk,
    /// Faults: unimplemented or unallocated.
    undef,
    /// The decoded-page sentinel.
    page_end,
};

/// What a kind does with its operand fields, independent of their values.
pub const Info = struct {
    d: Use = .none,
    n: Use = .none,
    m: Use = .none,
    a: Use = .none,
    /// d (and m, a of pairs and exclusives) name FP/SIMD registers.
    vreg: bool = false,
    flags: Use = .none,
    mem: MemUse = .none,
    ctrl: Ctrl = .none,
    /// Reads or writes state outside the register file and flags (MRS,
    /// MSR, barriers, CLREX, DC ZVA): a copier must not reorder or elide it.
    system: bool = false,
    /// n and m depend on x (the addressing modes of the _m kinds and pairs).
    modes: bool = false,
};

/// Registers one op reads and writes. Bits 0-30 of `read` and `write` are
/// X0-X30 and bit 33 is SP; ZR never appears. `vread` and `vwrite` are the
/// FP/SIMD registers.
pub const Regs = struct {
    read: u64 = 0,
    write: u64 = 0,
    vread: u32 = 0,
    vwrite: u32 = 0,
    flags: Use = .none,
    mem: MemUse = .none,
    ctrl: Ctrl = .none,
    system: bool = false,

    fn slot(set: *u64, s: u8) void {
        if (s != ZR and s != SINK) set.* |= @as(u64, 1) << @intCast(s);
    }
    fn use(r: *Regs, u: Use, s: u8, v: bool) void {
        if (v) {
            const bit = @as(u32, 1) << @intCast(s & 31);
            if (u == .r or u == .rw) r.vread |= bit;
            if (u == .w or u == .rw) r.vwrite |= bit;
            return;
        }
        if (u == .r or u == .rw) slot(&r.read, s);
        if (u == .w or u == .rw) slot(&r.write, s);
    }
};

pub fn info(k: Kind) Info {
    if (k.isSimd()) return simd.info(k);
    if (k.isExt()) return ext.info(k);
    return switch (k) {
        .undef => .{ .ctrl = .undef },
        .next_page => .{ .ctrl = .page_end },
        .movi => .{ .d = .w },
        .movk_x, .movk_w, .bfxil_x, .bfxil_w, .bfi_x, .bfi_w => .{ .d = .rw, .n = if (k == .movk_x or k == .movk_w) .none else .r },
        .add_imm_x, .add_imm_w, .and_imm_x, .and_imm_w, .orr_imm_x, .orr_imm_w, .eor_imm_x, .eor_imm_w => .{ .d = .w, .n = .r },
        .ubfx_x, .ubfx_w, .ubfiz_x, .ubfiz_w, .sbfx_x, .sbfx_w, .sbfiz_x, .sbfiz_w => .{ .d = .w, .n = .r },
        .rbit_x, .rbit_w, .rev16_x, .rev16_w, .rev32_x, .rev_x, .rev_w, .clz_x, .clz_w, .cls_x, .cls_w => .{ .d = .w, .n = .r },
        .mov_x, .mov_w => .{ .d = .w, .n = .r },
        .adds_imm_x, .adds_imm_w, .subs_imm_x, .subs_imm_w, .ands_imm_x, .ands_imm_w => .{ .d = .w, .n = .r, .flags = .w },
        .extr_x, .extr_w => .{ .d = .w, .n = .r, .m = .r },
        .and_sreg_x, .and_sreg_w, .bic_sreg_x, .bic_sreg_w, .orr_sreg_x, .orr_sreg_w, .orn_sreg_x, .orn_sreg_w, .eor_sreg_x, .eor_sreg_w, .eon_sreg_x, .eon_sreg_w => .{ .d = .w, .n = .r, .m = .r },
        .add_sreg_x, .add_sreg_w, .sub_sreg_x, .sub_sreg_w, .add_reg_x, .add_reg_w, .sub_reg_x, .sub_reg_w, .add_ereg_x, .add_ereg_w, .sub_ereg_x, .sub_ereg_w => .{ .d = .w, .n = .r, .m = .r },
        .udiv_x, .udiv_w, .sdiv_x, .sdiv_w, .lslv_x, .lslv_w, .lsrv_x, .lsrv_w, .asrv_x, .asrv_w, .rorv_x, .rorv_w, .smulh, .umulh => .{ .d = .w, .n = .r, .m = .r },
        .ands_sreg_x, .ands_sreg_w, .bics_sreg_x, .bics_sreg_w, .adds_sreg_x, .adds_sreg_w, .subs_sreg_x, .subs_sreg_w, .adds_ereg_x, .adds_ereg_w, .subs_ereg_x, .subs_ereg_w => .{ .d = .w, .n = .r, .m = .r, .flags = .w },
        .adc_x, .adc_w, .sbc_x, .sbc_w => .{ .d = .w, .n = .r, .m = .r, .flags = .r },
        .adcs_x, .adcs_w, .sbcs_x, .sbcs_w => .{ .d = .w, .n = .r, .m = .r, .flags = .rw },
        // m is unused in the immediate form, where decode leaves it ZR.
        .ccmp_x, .ccmp_w => .{ .n = .r, .m = .r, .flags = .rw },
        .csel_x, .csel_w => .{ .d = .w, .n = .r, .m = .r, .flags = .r },
        .madd_x, .madd_w, .msub_x, .msub_w, .smaddl, .smsubl, .umaddl, .umsubl => .{ .d = .w, .n = .r, .m = .r, .a = .r },
        .b => .{ .ctrl = .jump },
        .bl => .{ .ctrl = .call },
        .bcond => .{ .ctrl = .cond, .flags = .r },
        .cbz_x, .cbz_w, .cbnz_x, .cbnz_w, .tbz, .tbnz => .{ .n = .r, .ctrl = .cond },
        .br => .{ .n = .r, .ctrl = .indirect },
        .blr => .{ .n = .r, .ctrl = .call_indirect },
        .ret => .{ .n = .r, .ctrl = .ret },
        .svc => .{ .ctrl = .svc },
        .brk => .{ .ctrl = .brk },
        .nop => .{},
        .isb => .{ .system = true },
        .clrex, .fence => .{ .system = true },
        // NZCV through MRS and MSR shows in `regs`, which sees imm.
        .mrs => .{ .d = .w, .system = true },
        .msr => .{ .n = .r, .system = true },
        .dc_zva => .{ .n = .r, .mem = .store, .system = true },
        .ldr_x_o, .ldr_w_o, .ldrb_o, .ldrh_o, .ldrsb_x_o, .ldrsb_w_o, .ldrsh_x_o, .ldrsh_w_o, .ldrsw_o => .{ .d = .w, .n = .r, .mem = .load },
        .str_x_o, .str_w_o, .strb_o, .strh_o => .{ .d = .r, .n = .r, .mem = .store },
        .ldr_vb_o, .ldr_vh_o, .ldr_vs_o, .ldr_vd_o, .ldr_vq_o => .{ .d = .w, .n = .r, .vreg = true, .mem = .load },
        .str_vb_o, .str_vh_o, .str_vs_o, .str_vd_o, .str_vq_o => .{ .d = .r, .n = .r, .vreg = true, .mem = .store },
        .ldr_x_m, .ldr_w_m, .ldrb_m, .ldrh_m, .ldrsb_x_m, .ldrsb_w_m, .ldrsh_x_m, .ldrsh_w_m, .ldrsw_m => .{ .d = .w, .mem = .load, .modes = true },
        .str_x_m, .str_w_m, .strb_m, .strh_m => .{ .d = .r, .mem = .store, .modes = true },
        .ldr_vb_m, .ldr_vh_m, .ldr_vs_m, .ldr_vd_m, .ldr_vq_m => .{ .d = .w, .vreg = true, .mem = .load, .modes = true },
        .str_vb_m, .str_vh_m, .str_vs_m, .str_vd_m, .str_vq_m => .{ .d = .r, .vreg = true, .mem = .store, .modes = true },
        .ldp_x, .ldp_w, .ldpsw => .{ .d = .w, .m = .w, .mem = .load, .modes = true },
        .stp_x, .stp_w => .{ .d = .r, .m = .r, .mem = .store, .modes = true },
        .ldp_vs, .ldp_vd, .ldp_vq => .{ .d = .w, .m = .w, .vreg = true, .mem = .load, .modes = true },
        .stp_vs, .stp_vd, .stp_vq => .{ .d = .r, .m = .r, .vreg = true, .mem = .store, .modes = true },
        // a (Rt2) only for the pair forms: `regs` checks the kind.
        .ldxr, .ldxp => .{ .d = .w, .n = .r, .mem = .load_exclusive, .system = true },
        .stxr, .stxp => .{ .d = .w, .n = .r, .m = .r, .mem = .store_exclusive, .system = true },
        .ldar => .{ .d = .w, .n = .r, .mem = .load, .system = true },
        .stlr => .{ .m = .r, .n = .r, .mem = .store, .system = true },
        .ldop => .{ .d = .w, .m = .r, .n = .r, .mem = .rmw, .system = true },
        .cas, .casp => .{ .d = .rw, .m = .r, .n = .r, .mem = .rmw, .system = true },
        _ => unreachable,
    };
}

/// The registers, flags, memory, and control flow of one decoded op.
pub fn regs(o: Op) Regs {
    if (o.k.isSimd()) return simd.regs(o);
    if (o.k.isExt()) return ext.regs(o);
    const i = info(o.k);
    var r: Regs = .{ .flags = i.flags, .mem = i.mem, .ctrl = i.ctrl, .system = i.system };
    const pair = switch (o.k) {
        .ldp_x, .ldp_w, .ldpsw, .stp_x, .stp_w, .ldp_vs, .ldp_vd, .ldp_vq, .stp_vs, .stp_vd, .stp_vq => true,
        else => false,
    };
    r.use(i.d, o.d, i.vreg);
    if (i.modes) {
        // Pairs: n is the base, m Rt2. Single registers: by mode.
        const wb = o.x == 1 or o.x == 3;
        if (pair) {
            r.use(if (wb) .rw else .r, o.n, false);
            r.use(i.m, o.m, i.vreg);
        } else switch (o.x) {
            1, 3 => r.use(.rw, o.n, false),
            4 => {},
            5 => {
                r.use(.r, o.n, false);
                r.use(.r, o.m, false);
            },
            else => r.use(.r, o.n, false),
        }
    } else {
        r.use(i.n, o.n, false);
        r.use(i.m, o.m, false);
        r.use(i.a, o.a, false);
    }
    switch (o.k) {
        .bl, .blr => Regs.slot(&r.write, 30),
        .ldxp => r.use(.w, o.a, false),
        .stxp => r.use(.r, o.a, false),
        .casp => {
            r.use(.rw, o.d + 1, false);
            r.use(.r, o.m + 1, false);
        },
        .mrs => if (o.imm == sr.nzcv) {
            r.flags = .r;
        },
        .msr => if (o.imm == sr.nzcv) {
            r.flags = .w;
        },
        else => {},
    }
    return r;
}

// ---------------------------------------------------------------- decoding

inline fn bits(w: u32, comptime hi: u5, comptime lo: u5) u32 {
    return (w >> lo) & ((@as(u32, 1) << (hi - lo + 1)) - 1);
}

pub fn sext(v: u64, comptime n: u7) u64 {
    const s: u7 = 64 - n;
    return @bitCast(@as(i64, @bitCast(v << @intCast(s))) >> @intCast(s));
}

/// Register 31 as ZR, for a read.
fn rz(r: u32) u8 {
    return @intCast(r);
}
/// Register 31 as ZR, for a write.
fn rdz(r: u32) u8 {
    return if (r == 31) SINK else @intCast(r);
}
/// Register 31 as SP.
fn rsp(r: u32) u8 {
    return if (r == 31) SP else @intCast(r);
}

pub fn ones(n: u7) u64 {
    return if (n >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(n)) - 1;
}

fn ror(v: u64, r: u7, width: u7) u64 {
    if (r == 0) return v;
    return ((v >> @intCast(r)) | (v << @intCast(width - r))) & ones(width);
}

/// DecodeBitMasks's wmask, for logical immediates; null if reserved.
pub fn bitmask(n: u32, imms: u32, immr: u32, width: u7) ?u64 {
    const combined: u32 = (n << 6) | (~imms & 0x3f);
    if (combined == 0) return null;
    const len: u5 = @intCast(31 - @clz(combined));
    if (len < 1) return null;
    const esize: u7 = @as(u7, 1) << @intCast(len);
    if (esize > width) return null;
    const levels: u32 = esize - 1;
    const s = imms & levels;
    const r = immr & levels;
    if (s == levels) return null;
    const elem = ror(ones(@intCast(s + 1)), @intCast(r), esize);
    var res: u64 = 0;
    var i: u7 = 0;
    while (i < width) : (i += esize) res |= elem << @intCast(i);
    return res & ones(width);
}

/// Decodes the instruction word `w` at `pc`.
pub fn decode(w: u32, pc: u64) Op {
    const op0 = bits(w, 28, 25);
    return switch (op0) {
        0b1000, 0b1001 => dpImm(w, pc),
        0b1010, 0b1011 => branchSys(w, pc),
        0b0100, 0b0110, 0b1100, 0b1110 => ldSt(w, pc),
        0b0101, 0b1101 => dpReg(w),
        0b0111, 0b1111 => simd.decode(w, pc),
        else => .{}, // UDF, SVE, and unallocated
    };
}

fn dpImm(w: u32, pc: u64) Op {
    const sf = bits(w, 31, 31) == 1;
    const rd = bits(w, 4, 0);
    const rn = bits(w, 9, 5);
    switch (@as(u3, @intCast(bits(w, 25, 23)))) {
        0b000, 0b001 => { // ADR, ADRP
            const imm = (bits(w, 23, 5) << 2) | bits(w, 30, 29);
            const off = sext(imm, 21);
            const t = if (sf) (pc & ~@as(u64, 0xfff)) +% (off << 12) else pc +% off;
            return .{ .k = .movi, .d = rdz(rd), .imm = t };
        },
        0b010 => { // add/sub immediate
            var imm: u64 = bits(w, 21, 10);
            if (bits(w, 22, 22) == 1) imm <<= 12;
            const op = bits(w, 30, 30);
            const s = bits(w, 29, 29) == 1;
            const d = if (s) rdz(rd) else rsp(rd);
            const n = rsp(rn);
            if (!s) return .{ .k = if (sf) .add_imm_x else .add_imm_w, .d = d, .n = n, .imm = if (op == 1) 0 -% imm else imm };
            if (op == 0) return .{ .k = if (sf) .adds_imm_x else .adds_imm_w, .d = d, .n = n, .imm = imm };
            return .{ .k = if (sf) .subs_imm_x else .subs_imm_w, .d = d, .n = n, .imm = imm };
        },
        0b011 => return .{}, // add/sub immediate with tags (MTE)
        0b100 => { // logical immediate
            const nbit = bits(w, 22, 22);
            if (!sf and nbit == 1) return .{};
            const imm = bitmask(nbit, bits(w, 15, 10), bits(w, 21, 16), if (sf) 64 else 32) orelse return .{};
            const opc = bits(w, 30, 29);
            const d = if (opc == 3) rdz(rd) else rsp(rd);
            if (opc == 1 and rn == 31) return .{ .k = .movi, .d = d, .imm = imm };
            const k: Kind = switch (opc) {
                0 => if (sf) .and_imm_x else .and_imm_w,
                1 => if (sf) .orr_imm_x else .orr_imm_w,
                2 => if (sf) .eor_imm_x else .eor_imm_w,
                else => if (sf) .ands_imm_x else .ands_imm_w,
            };
            return .{ .k = k, .d = d, .n = rz(rn), .imm = imm };
        },
        0b101 => { // move wide
            const hw = bits(w, 22, 21);
            if (!sf and hw >= 2) return .{};
            const sh: u6 = @intCast(hw * 16);
            const imm16: u64 = bits(w, 20, 5);
            return switch (bits(w, 30, 29)) {
                0 => blk: {
                    const v = ~(imm16 << sh);
                    break :blk .{ .k = .movi, .d = rdz(rd), .imm = if (sf) v else v & 0xffffffff };
                },
                2 => .{ .k = .movi, .d = rdz(rd), .imm = imm16 << sh },
                3 => .{ .k = if (sf) .movk_x else .movk_w, .d = rdz(rd), .sh = sh, .imm = imm16 },
                else => .{},
            };
        },
        0b110 => { // bitfield
            const nbit = bits(w, 22, 22);
            if (sf != (nbit == 1)) return .{};
            const width: u32 = if (sf) 64 else 32;
            const immr = bits(w, 21, 16);
            const imms = bits(w, 15, 10);
            if (!sf and (immr >= 32 or imms >= 32)) return .{};
            const opc = bits(w, 30, 29);
            if (opc == 3) return .{};
            var o: Op = .{ .d = rdz(rd), .n = rz(rn) };
            const extract = imms >= immr;
            if (extract) { // field [imms:immr] to bit 0
                o.sh = @intCast(immr);
                o.a = @intCast(imms - immr + 1);
            } else { // low imms+1 bits to bit width-immr
                o.sh = @intCast(width - immr);
                o.a = @intCast(imms + 1);
            }
            o.k = switch (opc) {
                0 => if (extract) (if (sf) Kind.sbfx_x else .sbfx_w) else (if (sf) Kind.sbfiz_x else .sbfiz_w),
                1 => if (extract) (if (sf) Kind.bfxil_x else .bfxil_w) else (if (sf) Kind.bfi_x else .bfi_w),
                else => if (extract) (if (sf) Kind.ubfx_x else .ubfx_w) else (if (sf) Kind.ubfiz_x else .ubfiz_w),
            };
            return o;
        },
        0b111 => { // EXTR
            if (bits(w, 30, 29) != 0 or bits(w, 21, 21) != 0) return .{};
            if (sf != (bits(w, 22, 22) == 1)) return .{};
            const lsb = bits(w, 15, 10);
            if (!sf and lsb >= 32) return .{};
            return .{ .k = if (sf) .extr_x else .extr_w, .d = rdz(rd), .n = rz(rn), .m = rz(bits(w, 20, 16)), .sh = @intCast(lsb) };
        },
    }
}

fn branchSys(w: u32, pc: u64) Op {
    const rn = bits(w, 9, 5);
    const rt = bits(w, 4, 0);
    if (bits(w, 30, 26) == 0b00101) { // B, BL
        const t = pc +% (sext(bits(w, 25, 0), 26) << 2);
        return .{ .k = if (bits(w, 31, 31) == 1) .bl else .b, .imm = t };
    }
    if (bits(w, 31, 24) == 0x54) { // B.cond (BC.cond, bit 4, is Armv8.8)
        if (bits(w, 4, 4) != 0) return .{};
        return .{ .k = .bcond, .x = @intCast(bits(w, 3, 0)), .imm = pc +% (sext(bits(w, 23, 5), 19) << 2) };
    }
    if (bits(w, 30, 25) == 0b011010) { // CBZ, CBNZ
        const sf = bits(w, 31, 31) == 1;
        const t = pc +% (sext(bits(w, 23, 5), 19) << 2);
        const k: Kind = if (bits(w, 24, 24) == 1) (if (sf) .cbnz_x else .cbnz_w) else (if (sf) .cbz_x else .cbz_w);
        return .{ .k = k, .n = rz(rt), .imm = t };
    }
    if (bits(w, 30, 25) == 0b011011) { // TBZ, TBNZ
        const t = pc +% (sext(bits(w, 18, 5), 14) << 2);
        const bit = (bits(w, 31, 31) << 5) | bits(w, 23, 19);
        return .{ .k = if (bits(w, 24, 24) == 1) .tbnz else .tbz, .n = rz(rt), .sh = @intCast(bit), .imm = t };
    }
    if (bits(w, 31, 24) == 0xd4) { // exception generation
        const opc = bits(w, 23, 21);
        const ll = bits(w, 1, 0);
        if (bits(w, 4, 2) != 0) return .{};
        if (opc == 0 and ll == 1) return .{ .k = .svc, .imm = bits(w, 20, 5) };
        if (opc == 1 and ll == 0) return .{ .k = .brk, .imm = bits(w, 20, 5) };
        return .{}; // HVC, SMC, HLT, DCPS: undefined at EL0
    }
    if (bits(w, 31, 25) == 0b1101011) { // unconditional branch (register)
        // Only BR, BLR, RET with op2 = 31 and op3, op4 zero; the rest
        // (ERET, DRPS, the pointer-authenticating forms) are undefined.
        if (bits(w, 20, 16) != 31 or bits(w, 15, 10) != 0 or rt != 0) return .{};
        return switch (bits(w, 24, 21)) {
            0 => .{ .k = .br, .n = rz(rn) },
            1 => .{ .k = .blr, .n = rz(rn) },
            2 => .{ .k = .ret, .n = rz(rn) },
            else => .{},
        };
    }
    if (bits(w, 31, 22) == 0b1101010100) return system(w);
    return .{};
}

fn system(w: u32) Op {
    const l = bits(w, 21, 21);
    const op0 = bits(w, 20, 19);
    const op1 = bits(w, 18, 16);
    const crn = bits(w, 15, 12);
    const crm = bits(w, 11, 8);
    const op2 = bits(w, 7, 5);
    const rt = bits(w, 4, 0);
    if (op0 == 0) {
        // Hints, barriers, and PSTATE: L is 0, and Rt is 31.
        if (l != 0 or rt != 31) return .{};
        if (op1 == 3 and crn == 2) return .{ .k = .nop }; // hints
        if (op1 == 3 and crn == 3) return switch (op2) {
            2 => .{ .k = .clrex },
            4, 5 => .{ .k = .fence }, // DSB, DMB
            6 => .{ .k = .isb },
            else => .{},
        };
        return .{}; // MSR (immediate): no PSTATE field EL0 can write here
    }
    if (op0 == 1) { // SYS, SYSL
        if (l == 1 or op1 != 3) return .{};
        if (crn == 7 and crm == 4 and op2 == 1) return .{ .k = .dc_zva, .n = rz(rt) };
        if (crn == 7 and op2 == 1 and (crm == 5 or crm == 10 or crm == 11 or crm == 14)) return .{ .k = .nop }; // IC IVAU, DC CVAC, CVAU, CIVAC
        return .{};
    }
    const reg: u16 = @intCast(bits(w, 20, 5));
    if (l == 1) {
        switch (reg) {
            sr.nzcv, sr.fpcr, sr.fpsr, sr.tpidr_el0, sr.tpidrro_el0, sr.cntfrq_el0, sr.cntvct_el0, sr.ctr_el0, sr.dczid_el0 => {},
            else => return .{},
        }
        return .{ .k = .mrs, .d = rdz(rt), .imm = reg };
    }
    switch (reg) {
        sr.nzcv, sr.fpcr, sr.fpsr, sr.tpidr_el0 => {},
        else => return .{},
    }
    return .{ .k = .msr, .n = rz(rt), .imm = reg };
}

fn dpReg(w: u32) Op {
    const sf = bits(w, 31, 31) == 1;
    const rd = bits(w, 4, 0);
    const rn = bits(w, 9, 5);
    const rm = bits(w, 20, 16);
    const op1 = bits(w, 28, 28);
    const op2 = bits(w, 24, 21);
    if (op1 == 0) {
        if (op2 & 0b1000 == 0) { // logical (shifted register)
            const amt = bits(w, 15, 10);
            if (!sf and amt >= 32) return .{};
            const opcn: u8 = @intCast((bits(w, 30, 29) << 1) | bits(w, 21, 21));
            if (opcn == 2 and rn == 31 and amt == 0) return .{ .k = if (sf) .mov_x else .mov_w, .d = rdz(rd), .n = rz(rm) };
            const k: Kind = @enumFromInt(@intFromEnum(Kind.and_sreg_x) + 2 * @as(u16, opcn) + @intFromBool(!sf));
            return .{ .k = k, .d = rdz(rd), .n = rz(rn), .m = rz(rm), .x = @intCast(bits(w, 23, 22)), .sh = @intCast(amt) };
        }
        if (op2 & 0b1001 == 0b1000) { // add/sub (shifted register)
            const shift = bits(w, 23, 22);
            if (shift == 3) return .{};
            const amt = bits(w, 15, 10);
            if (!sf and amt >= 32) return .{};
            const opc = bits(w, 30, 29);
            if (amt == 0 and opc & 1 == 0) {
                const k: Kind = if (opc == 0) (if (sf) .add_reg_x else .add_reg_w) else (if (sf) .sub_reg_x else .sub_reg_w);
                return .{ .k = k, .d = rdz(rd), .n = rz(rn), .m = rz(rm) };
            }
            const k: Kind = @enumFromInt(@intFromEnum(Kind.add_sreg_x) + 2 * @as(u16, @intCast(opc)) + @intFromBool(!sf));
            return .{ .k = k, .d = rdz(rd), .n = rz(rn), .m = rz(rm), .x = @intCast(shift), .sh = @intCast(amt) };
        }
        // add/sub (extended register)
        if (bits(w, 23, 22) != 0) return .{};
        const amt = bits(w, 12, 10);
        if (amt > 4) return .{};
        const opc = bits(w, 30, 29);
        const s = opc & 1 == 1;
        const k: Kind = @enumFromInt(@intFromEnum(Kind.add_ereg_x) + 2 * @as(u16, @intCast(opc)) + @intFromBool(!sf));
        return .{ .k = k, .d = if (s) rdz(rd) else rsp(rd), .n = rsp(rn), .m = rz(rm), .x = @intCast(bits(w, 15, 13)), .sh = @intCast(amt) };
    }
    switch (op2) {
        0b0000 => { // add/subtract with carry
            if (bits(w, 15, 10) != 0) return .{}; // RMIF, SETF (Armv8.4)
            const k: Kind = @enumFromInt(@intFromEnum(Kind.adc_x) + 2 * @as(u16, @intCast(bits(w, 30, 29))) + @intFromBool(!sf));
            return .{ .k = k, .d = rdz(rd), .n = rz(rn), .m = rz(rm) };
        },
        0b0010 => { // conditional compare
            if (bits(w, 29, 29) != 1 or bits(w, 10, 10) != 0 or bits(w, 4, 4) != 0) return .{};
            const imm_form = bits(w, 11, 11) == 1;
            const ccmn = bits(w, 30, 30) == 0;
            return .{
                .k = if (sf) .ccmp_x else .ccmp_w,
                .n = rz(rn),
                .m = if (imm_form) ZR else rz(rm),
                .imm = if (imm_form) rm else 0,
                .a = @as(u8, @intFromBool(imm_form)) | (@as(u8, @intFromBool(ccmn)) << 1),
                .x = @intCast(bits(w, 15, 12)),
                .sh = @intCast(bits(w, 3, 0)),
            };
        },
        0b0100 => { // conditional select
            if (bits(w, 29, 29) != 0 or bits(w, 11, 11) != 0) return .{};
            const op: u8 = @intCast((bits(w, 30, 30) << 1) | bits(w, 10, 10));
            return .{ .k = if (sf) .csel_x else .csel_w, .d = rdz(rd), .n = rz(rn), .m = rz(rm), .a = op, .x = @intCast(bits(w, 15, 12)) };
        },
        0b0110 => {
            if (bits(w, 29, 29) != 0) return .{};
            if (bits(w, 30, 30) == 1) { // data processing (1 source)
                if (rm != 0) return .{};
                const k: Kind = switch (bits(w, 15, 10)) {
                    0 => if (sf) .rbit_x else .rbit_w,
                    1 => if (sf) .rev16_x else .rev16_w,
                    2 => if (sf) .rev32_x else .rev_w,
                    3 => if (sf) .rev_x else return .{},
                    4 => if (sf) .clz_x else .clz_w,
                    5 => if (sf) .cls_x else .cls_w,
                    else => return .{},
                };
                return .{ .k = k, .d = rdz(rd), .n = rz(rn) };
            }
            // data processing (2 source); CRC32 is an extension, in ext.zig
            const k: Kind = switch (bits(w, 15, 10)) {
                0b000010 => if (sf) .udiv_x else .udiv_w,
                0b000011 => if (sf) .sdiv_x else .sdiv_w,
                0b001000 => if (sf) .lslv_x else .lslv_w,
                0b001001 => if (sf) .lsrv_x else .lsrv_w,
                0b001010 => if (sf) .asrv_x else .asrv_w,
                0b001011 => if (sf) .rorv_x else .rorv_w,
                else => return ext.decodeDp2(w) orelse .{},
            };
            return .{ .k = k, .d = rdz(rd), .n = rz(rn), .m = rz(rm) };
        },
        0b1000...0b1111 => { // data processing (3 source)
            if (bits(w, 30, 29) != 0) return .{};
            const o0 = bits(w, 15, 15);
            const k: Kind = switch (bits(w, 23, 21)) {
                0b000 => if (o0 == 0) (if (sf) Kind.madd_x else .madd_w) else (if (sf) Kind.msub_x else .msub_w),
                0b001 => if (!sf) return .{} else if (o0 == 0) .smaddl else .smsubl,
                0b101 => if (!sf) return .{} else if (o0 == 0) .umaddl else .umsubl,
                0b010 => if (!sf or o0 == 1) return .{} else .smulh,
                0b110 => if (!sf or o0 == 1) return .{} else .umulh,
                else => return .{},
            };
            // SMULH and UMULH ignore Ra (it's 31).
            return .{ .k = k, .d = rdz(rd), .n = rz(rn), .m = rz(rm), .a = rz(bits(w, 14, 10)) };
        },
        else => return .{},
    }
}

const Single = struct { o: Kind, m: Kind, scale: u3, store: bool, v: bool };

fn single(size: u32, opc: u32, v: bool) ?Single {
    const S = Single;
    if (v) {
        return switch ((opc & 2) << 1 | size) { // size, with opc<1> as bit 2
            0 => if (opc & 1 == 1) S{ .o = .ldr_vb_o, .m = .ldr_vb_m, .scale = 0, .store = false, .v = true } else S{ .o = .str_vb_o, .m = .str_vb_m, .scale = 0, .store = true, .v = true },
            1 => if (opc & 1 == 1) S{ .o = .ldr_vh_o, .m = .ldr_vh_m, .scale = 1, .store = false, .v = true } else S{ .o = .str_vh_o, .m = .str_vh_m, .scale = 1, .store = true, .v = true },
            2 => if (opc & 1 == 1) S{ .o = .ldr_vs_o, .m = .ldr_vs_m, .scale = 2, .store = false, .v = true } else S{ .o = .str_vs_o, .m = .str_vs_m, .scale = 2, .store = true, .v = true },
            3 => if (opc & 1 == 1) S{ .o = .ldr_vd_o, .m = .ldr_vd_m, .scale = 3, .store = false, .v = true } else S{ .o = .str_vd_o, .m = .str_vd_m, .scale = 3, .store = true, .v = true },
            4 => if (opc & 1 == 1) S{ .o = .ldr_vq_o, .m = .ldr_vq_m, .scale = 4, .store = false, .v = true } else S{ .o = .str_vq_o, .m = .str_vq_m, .scale = 4, .store = true, .v = true },
            else => null,
        };
    }
    const f = false;
    return switch (size) {
        0 => switch (opc) {
            0 => S{ .o = .strb_o, .m = .strb_m, .scale = 0, .store = true, .v = f },
            1 => S{ .o = .ldrb_o, .m = .ldrb_m, .scale = 0, .store = f, .v = f },
            2 => S{ .o = .ldrsb_x_o, .m = .ldrsb_x_m, .scale = 0, .store = f, .v = f },
            else => S{ .o = .ldrsb_w_o, .m = .ldrsb_w_m, .scale = 0, .store = f, .v = f },
        },
        1 => switch (opc) {
            0 => S{ .o = .strh_o, .m = .strh_m, .scale = 1, .store = true, .v = f },
            1 => S{ .o = .ldrh_o, .m = .ldrh_m, .scale = 1, .store = f, .v = f },
            2 => S{ .o = .ldrsh_x_o, .m = .ldrsh_x_m, .scale = 1, .store = f, .v = f },
            else => S{ .o = .ldrsh_w_o, .m = .ldrsh_w_m, .scale = 1, .store = f, .v = f },
        },
        2 => switch (opc) {
            0 => S{ .o = .str_w_o, .m = .str_w_m, .scale = 2, .store = true, .v = f },
            1 => S{ .o = .ldr_w_o, .m = .ldr_w_m, .scale = 2, .store = f, .v = f },
            2 => S{ .o = .ldrsw_o, .m = .ldrsw_m, .scale = 2, .store = f, .v = f },
            else => null,
        },
        else => switch (opc) {
            0 => S{ .o = .str_x_o, .m = .str_x_m, .scale = 3, .store = true, .v = f },
            1 => S{ .o = .ldr_x_o, .m = .ldr_x_m, .scale = 3, .store = f, .v = f },
            else => null, // PRFM, handled by the caller; 3 is unallocated
        },
    };
}

fn ldSt(w: u32, pc: u64) Op {
    const rt = bits(w, 4, 0);
    const rn = bits(w, 9, 5);
    const size = bits(w, 31, 30);
    const v = bits(w, 26, 26) == 1;
    const op1 = bits(w, 29, 28);

    if (op1 == 0) {
        if (v) return simd.decode(w, pc); // structure loads and stores
        if (bits(w, 27, 24) != 0b1000) return .{};
        return exclusive(w);
    }
    if (op1 == 1) { // load literal
        if (bits(w, 24, 24) != 0) return .{};
        const t = pc +% (sext(bits(w, 23, 5), 19) << 2);
        const k: Kind = if (v) switch (size) {
            0 => .ldr_vs_m,
            1 => .ldr_vd_m,
            2 => .ldr_vq_m,
            else => return .{},
        } else switch (size) {
            0 => .ldr_w_m,
            1 => .ldr_x_m,
            2 => .ldrsw_m,
            else => return .{ .k = .nop }, // PRFM (literal)
        };
        return .{ .k = k, .d = if (v) @intCast(rt) else rdz(rt), .x = 4, .imm = t };
    }
    if (op1 == 2) { // pairs
        const mode = bits(w, 24, 23);
        const l = bits(w, 22, 22) == 1;
        const k: Kind, const scale: u6 = if (v) switch (size) {
            0 => .{ if (l) .ldp_vs else .stp_vs, 2 },
            1 => .{ if (l) .ldp_vd else .stp_vd, 3 },
            2 => .{ if (l) .ldp_vq else .stp_vq, 4 },
            else => return .{},
        } else switch (size) {
            0 => .{ if (l) .ldp_w else .stp_w, 2 },
            1 => if (l and mode != 0) .{ .ldpsw, 2 } else return .{}, // STGP is MTE
            2 => .{ if (l) .ldp_x else .stp_x, 3 },
            else => return .{},
        };
        const imm = sext(bits(w, 21, 15), 7) << scale;
        const rt2 = bits(w, 14, 10);
        const x: u8 = if (mode == 0) 2 else @intCast(mode);
        if (v) return .{ .k = k, .d = @intCast(rt), .m = @intCast(rt2), .n = rsp(rn), .x = x, .imm = imm };
        return .{ .k = k, .d = if (l) rdz(rt) else rz(rt), .m = if (l) rdz(rt2) else rz(rt2), .n = rsp(rn), .x = x, .imm = imm };
    }
    // LSE atomic memory operations
    if (!v and bits(w, 24, 24) == 0 and bits(w, 21, 21) == 1 and bits(w, 11, 10) == 0) {
        const o3 = bits(w, 15, 15);
        const opc = bits(w, 14, 12);
        if (o3 == 1 and opc != 0) return .{}; // LDAPR (Armv8.3) and unallocated
        const order: u8 = @intCast(bits(w, 23, 22) >> 1 | (bits(w, 22, 22) & 1) << 1);
        return .{ .k = .ldop, .d = rdz(rt), .m = rz(bits(w, 20, 16)), .n = rsp(rn), .x = @intCast(size), .a = if (o3 == 1) 8 else @intCast(opc), .sh = order };
    }
    // single register
    const opc = bits(w, 23, 22);
    const prfm = !v and size == 3 and opc == 2;
    const s = single(size, opc, v) orelse if (prfm) Single{ .o = .nop, .m = .nop, .scale = 3, .store = false, .v = false } else return .{};
    const t: u8 = if (v) @intCast(rt) else if (s.store) rz(rt) else rdz(rt);
    if (bits(w, 24, 24) == 1) { // unsigned offset
        if (prfm) return .{ .k = .nop };
        return .{ .k = s.o, .d = t, .n = rsp(rn), .imm = @as(u64, bits(w, 21, 10)) << s.scale };
    }
    if (bits(w, 21, 21) == 0) {
        const imm = sext(bits(w, 20, 12), 9);
        switch (bits(w, 11, 10)) {
            // unscaled, and unprivileged, which is the same at EL0 (PRFUM
            // is a prefetch; LDTR has no FP form)
            0, 2 => {
                if (prfm) return if (bits(w, 11, 10) == 0) .{ .k = .nop } else .{};
                if (v and bits(w, 11, 10) == 2) return .{};
                return .{ .k = s.o, .d = t, .n = rsp(rn), .imm = imm };
            },
            1, 3 => |mode| { // post-index, pre-index
                if (prfm) return .{};
                return .{ .k = s.m, .d = t, .n = rsp(rn), .x = @intCast(mode), .imm = imm };
            },
            else => unreachable,
        }
    }
    if (bits(w, 11, 10) != 2) return .{}; // atomic memory operations (LSE), PAC loads
    const option = bits(w, 15, 13);
    if (option & 2 == 0) return .{};
    if (prfm) return .{ .k = .nop };
    const amt: u8 = if (bits(w, 12, 12) == 1) s.scale else 0;
    return .{ .k = s.m, .d = t, .n = rsp(rn), .m = rz(bits(w, 20, 16)), .x = 5, .a = @intCast(option), .sh = amt };
}

fn exclusive(w: u32) Op {
    const size = bits(w, 31, 30);
    const o2 = bits(w, 23, 23);
    const l = bits(w, 22, 22) == 1;
    const o1 = bits(w, 21, 21);
    const rs = bits(w, 20, 16);
    const o0: u8 = @intCast(bits(w, 15, 15));
    const rt2 = bits(w, 14, 10);
    const rn = bits(w, 9, 5);
    const rt = bits(w, 4, 0);
    const x: u8 = @intCast(size);
    if (o2 == 0 and o1 == 0) {
        if (l) return .{ .k = .ldxr, .d = rdz(rt), .n = rsp(rn), .x = x, .sh = o0 };
        return .{ .k = .stxr, .d = rdz(rs), .m = rz(rt), .n = rsp(rn), .x = x, .sh = o0 };
    }
    if (o2 == 0 and o1 == 1) {
        if (size < 2) { // CASP (LSE)
            if (rt2 != 31 or rs & 1 != 0 or rt & 1 != 0) return .{};
            return .{ .k = .casp, .d = @intCast(rs), .m = @intCast(rt), .n = rsp(rn), .x = @intCast(size + 2), .sh = @as(u8, @intFromBool(l)) | o0 << 1 };
        }
        if (l) return .{ .k = .ldxp, .d = rdz(rt), .a = rdz(rt2), .n = rsp(rn), .x = x, .sh = o0 };
        return .{ .k = .stxp, .d = rdz(rs), .m = rz(rt), .a = rz(rt2), .n = rsp(rn), .x = x, .sh = o0 };
    }
    if (o2 == 1 and o1 == 0) {
        if (o0 == 0) return .{}; // LDLAR, STLLR (LORegions)
        if (l) return .{ .k = .ldar, .d = rdz(rt), .n = rsp(rn), .x = x, .sh = 1 };
        return .{ .k = .stlr, .m = rz(rt), .n = rsp(rn), .x = x, .sh = 1 };
    }
    // CAS (LSE)
    if (rt2 != 31) return .{};
    return .{ .k = .cas, .d = rz(rs), .m = rz(rt), .n = rsp(rn), .x = x, .sh = @as(u8, @intFromBool(l)) | o0 << 1 };
}

// ---------------------------------------------------------------- tests

test "decode: a few encodings and their read and write sets" {
    const t = std.testing;
    // add x1, x2, #3
    var o = decode(0x91000c41, 0);
    try t.expectEqual(Kind.add_imm_x, o.k);
    var r = regs(o);
    try t.expectEqual(@as(u64, 1 << 2), r.read);
    try t.expectEqual(@as(u64, 1 << 1), r.write);
    // subs xzr, x1, #1 (cmp): writes nothing but flags
    o = decode(0xf100043f, 0);
    try t.expectEqual(Kind.subs_imm_x, o.k);
    r = regs(o);
    try t.expectEqual(@as(u64, 0), r.write);
    try t.expectEqual(Use.w, r.flags);
    // stp x29, x30, [sp, #-16]!
    o = decode(0xa9bf7bfd, 0);
    try t.expectEqual(Kind.stp_x, o.k);
    r = regs(o);
    try t.expectEqual(@as(u64, 1 << 29 | 1 << 30 | 1 << SP), r.read);
    try t.expectEqual(@as(u64, 1 << SP), r.write);
    try t.expectEqual(MemUse.store, r.mem);
    // bl: writes x30
    o = decode(0x94000010, 0x1000);
    try t.expectEqual(Kind.bl, o.k);
    try t.expectEqual(@as(u64, 0x1040), o.imm);
    try t.expectEqual(@as(u64, 1 << 30), regs(o).write);
    // ldaxr w0, [x1]; stlxr w2, w3, [x1]
    o = decode(0x885ffc20, 0);
    try t.expectEqual(Kind.ldxr, o.k);
    try t.expectEqual(MemUse.load_exclusive, regs(o).mem);
    o = decode(0x8802fc23, 0);
    try t.expectEqual(Kind.stxr, o.k);
    r = regs(o);
    try t.expectEqual(@as(u64, 1 << 1 | 1 << 3), r.read);
    try t.expectEqual(@as(u64, 1 << 2), r.write);
    // mrs x0, nzcv
    o = decode(0xd53b4200, 0);
    try t.expectEqual(Kind.mrs, o.k);
    try t.expectEqual(Use.r, regs(o).flags);
    // paciasp is a hint: a NOP on Armv8.0
    try t.expectEqual(Kind.nop, decode(0xd503233f, 0).k);
    // udf #0, and an AdvSIMD add (simd_decode's) until it lands
    try t.expectEqual(Kind.undef, decode(0x00000000, 0).k);
    try t.expectEqual(Ctrl.undef, regs(decode(0x00000000, 0)).ctrl);
    // ldr q0, [x1, #16]
    o = decode(0x3dc00420, 0);
    try t.expectEqual(Kind.ldr_vq_o, o.k);
    try t.expectEqual(@as(u32, 1), regs(o).vwrite);
    // ccmp x1, #2, #0, ne: reads x1 only
    o = decode(0xfa421820, 0);
    try t.expectEqual(Kind.ccmp_x, o.k);
    try t.expectEqual(@as(u64, 1 << 1), regs(o).read);
}

test "decode: every word decodes without tripping a safety check" {
    // A sweep with a stride that touches every top-level group and field.
    var w: u64 = 0;
    while (w <= 0xffffffff) : (w += 0x10001) {
        const o = decode(@intCast(w), 0x400000);
        _ = regs(o);
    }
}
