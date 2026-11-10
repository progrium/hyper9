//! (Copied from the project's zig-interpreter spike, as ha64's stand-in T0
//! until src/interp/a64/ proper replaces it. `step` was added for the JIT's
//! call.interp.)
//!
//! Spike: an A64 EL0 interpreter core for 9front binaries
//! (design/0019-zig-interpreter.md). Predecoded 4 KiB pages of micro-ops,
//! dispatched with a labeled switch. Depends only on std.math/std.mem and
//! atomics: no OS services.

const std = @import("std");

pub const page_size = 4096;
const ops_per_page = page_size / 4;

// ---------------------------------------------------------------- state

/// Register file slots. 0-30 are X0-X30; reads of ZR use slot 31 (always
/// 0), writes to ZR go to slot 32 (a sink), and SP is slot 33. The decoder
/// resolves which one an encoding means, so handlers never test for 31.
const ZR = 31;
const SINK = 32;
const SP = 33;

pub const Monitor = struct { addr: u64, size: u8, value: u64 };

pub const Cpu = struct {
    r: [34]u64 = @splat(0),
    pc: u64 = 0,
    nzcv: u32 = 0, // N Z C V in bits 31..28, as PSTATE
    v: [32]u128 = @splat(0),
    fpcr: u32 = 0,
    fpsr: u32 = 0,
    tpidr: u64 = 0,
    monitor: ?Monitor = null,
    retired: u64 = 0,

    pub fn x(c: *Cpu, i: u5) u64 {
        return if (i == 31) 0 else c.r[i];
    }
};

pub const Access = enum(u8) { read = 1, write = 2, exec = 4 };

pub const Exit = union(enum) {
    syscall,
    fault: struct { addr: u64, access: Access, esr: u64 },
    interrupted,
};

// ESR classes, as the hardware reports them to EL1.
pub const EC_UNKNOWN = 0x00;
pub const EC_SVC64 = 0x15;
pub const EC_IABT_LOWER = 0x20;
pub const EC_DABT_LOWER = 0x24;
pub const EC_BRK = 0x3c;
const FSC_TRANSLATION_L3 = 0x07;
const FSC_PERMISSION_L3 = 0x0f;
const FSC_ALIGNMENT = 0x21;

// ---------------------------------------------------------------- memory

pub const Region = struct { va: u64, mem: []u8, perms: u8 };

const TlbEntry = struct { tag: u64 = std.math.maxInt(u64), base: [*]u8 = undefined, perms: u8 = 0 };

/// Guest memory: the regions of an address space and a 64-entry
/// direct-mapped software TLB over them.
pub const Mem = struct {
    regions: []const Region,
    tlb: [64]TlbEntry = @splat(.{}),

    pub fn flush(m: *Mem) void {
        m.tlb = @splat(.{});
    }

    fn fill(m: *Mem, vp: u64) ?*TlbEntry {
        const va = vp << 12;
        for (m.regions) |r| {
            if (va >= r.va and va - r.va < r.mem.len) {
                const e = &m.tlb[@intCast(vp & 63)];
                e.* = .{ .tag = vp, .base = r.mem.ptr + @as(usize, @intCast(va - r.va)), .perms = r.perms };
                return e;
            }
        }
        return null;
    }

    /// Host pointer for an access of `size` bytes that stays within one
    /// page, or null for a fault or a page-crossing access.
    inline fn ptr(m: *Mem, addr: u64, comptime size: u8, comptime acc: Access) ?[*]u8 {
        const vp = addr >> 12;
        var e = &m.tlb[@intCast(vp & 63)];
        if (e.tag != vp) e = m.fill(vp) orelse return null;
        if (e.perms & @intFromEnum(acc) == 0) return null;
        if ((addr & 0xfff) + size > page_size) return null;
        return e.base + @as(usize, @intCast(addr & 0xfff));
    }

    /// Bytewise slow path for page-crossing accesses.
    fn slow(m: *Mem, addr: u64, buf: []u8, comptime acc: Access) bool {
        for (buf, 0..) |*b, i| {
            const p = m.ptr(addr +% @as(u64, i), 1, acc) orelse return false;
            if (acc == .write) p[0] = b.* else b.* = p[0];
        }
        return true;
    }

    pub fn read(m: *Mem, comptime T: type, addr: u64) ?T {
        const n = @sizeOf(T);
        if (m.ptr(addr, n, .read)) |p| {
            // Naturally aligned accesses of up to 8 bytes are single-copy
            // atomic on arm64: other vCPUs may share this memory.
            if (n <= max_atomic and addr % n == 0) return @atomicLoad(T, @as(*T, @ptrCast(@alignCast(p))), .monotonic);
            return std.mem.readInt(T, p[0..n], .little);
        }
        var buf: [n]u8 = undefined;
        if (!m.slow(addr, &buf, .read)) return null;
        return std.mem.readInt(T, &buf, .little);
    }

    pub fn write(m: *Mem, comptime T: type, addr: u64, v: T) bool {
        const n = @sizeOf(T);
        if (m.ptr(addr, n, .write)) |p| {
            if (n <= max_atomic and addr % n == 0) {
                @atomicStore(T, @as(*T, @ptrCast(@alignCast(p))), v, .monotonic);
            } else std.mem.writeInt(T, p[0..n], v, .little);
            return true;
        }
        var buf: [n]u8 = undefined;
        std.mem.writeInt(T, &buf, v, .little);
        return m.slow(addr, &buf, .write);
    }

    pub fn fetch(m: *Mem, addr: u64) ?[*]const u8 {
        return m.ptr(addr, 4, .exec);
    }

    /// Faulting access kind: translation if no region maps it, else permission.
    fn fsc(m: *Mem, addr: u64) u64 {
        const va = addr & ~@as(u64, 0xfff);
        for (m.regions) |r| if (va >= r.va and va - r.va < r.mem.len) return FSC_PERMISSION_L3;
        return FSC_TRANSLATION_L3;
    }
};

// ---------------------------------------------------------------- micro-ops

pub const Kind = enum(u8) {
    undef,
    next_page, // sentinel after the last op of a page
    // data processing, immediate
    movi, // Rd = imm (MOVZ, MOVN, ADR, ADRP, ORR-imm with ZR)
    movk_x,
    movk_w,
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
    ubfx_x,
    ubfx_w,
    ubfiz_x,
    ubfiz_w,
    sbfx_x,
    sbfx_w,
    sbfiz_x,
    sbfiz_w,
    bfm_x,
    bfm_w,
    extr_x,
    extr_w,
    // data processing, register
    mov_x,
    mov_w,
    add_sreg_x,
    add_sreg_w,
    adds_sreg_x,
    adds_sreg_w,
    sub_sreg_x,
    sub_sreg_w,
    subs_sreg_x,
    subs_sreg_w,
    add_ereg_x,
    add_ereg_w,
    adds_ereg_x,
    adds_ereg_w,
    sub_ereg_x,
    sub_ereg_w,
    subs_ereg_x,
    subs_ereg_w,
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
    add_reg_x,
    add_reg_w,
    sub_reg_x,
    sub_reg_w,
    lslv_x,
    lslv_w,
    lsrv_x,
    lsrv_w,
    asrv_x,
    asrv_w,
    rorv_x,
    rorv_w,
    udiv_x,
    udiv_w,
    sdiv_x,
    sdiv_w,
    madd_x,
    madd_w,
    msub_x,
    msub_w,
    umaddl,
    smaddl,
    umsubl,
    smsubl,
    umulh,
    smulh,
    csel_x, // CSEL CSINC CSINV CSNEG; op in `a`, cond in `x`
    csel_w,
    // branches and exceptions
    b,
    bl,
    bcond_0,
    bcond_1,
    bcond_2,
    bcond_3,
    bcond_4,
    bcond_5,
    bcond_6,
    bcond_7,
    bcond_8,
    bcond_9,
    bcond_10,
    bcond_11,
    bcond_12,
    bcond_13,
    bcond_14,
    bcond_15,
    cbz_x,
    cbz_w,
    cbnz_x,
    cbnz_w,
    tbz,
    tbnz,
    br,
    blr,
    ret,
    svc,
    brk,
    // system
    nop,
    fence,
    mrs,
    msr,
    dc_zva,
    // loads and stores: _o is base+imm, _m the other modes (`x`)
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
    ldr_s_o,
    ldr_d_o,
    ldr_q_o,
    str_s_o,
    str_d_o,
    str_q_o,
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
    ldr_s_m,
    ldr_d_m,
    ldr_q_m,
    str_s_m,
    str_d_m,
    str_q_m,
    ldp_x,
    ldp_w,
    ldpsw,
    stp_x,
    stp_w,
    ldp_d,
    stp_d,
    ldp_q,
    stp_q,
    ldxr_x,
    ldxr_w,
    ldxr_h,
    ldxr_b,
    stxr_x,
    stxr_w,
    stxr_h,
    stxr_b,
    ldar_x,
    ldar_w,
    stlr_x,
    stlr_w,
    // floating point (scalar)
    fadd_s,
    fadd_d,
    fsub_s,
    fsub_d,
    fmul_s,
    fmul_d,
    fdiv_s,
    fdiv_d,
    fnmul_s,
    fnmul_d,
    fmov_s,
    fmov_d,
    fabs_s,
    fabs_d,
    fneg_s,
    fneg_d,
    fsqrt_s,
    fsqrt_d,
    fcvt_sd, // double from single
    fcvt_ds, // single from double
    frint_s, // rounding mode in `x`
    frint_d,
    fcmp_s, // compare with zero when `a` is 1
    fcmp_d,
    fmovi_s,
    fmovi_d,
    scvtf, // `x`: bit0 source is X, bit1 dest is D; ucvtf when `a` is 1
    fcvtz, // `x`: bit0 dest is X, bit1 source is D; unsigned when `a` is 1
    fmov_to_gp, // `x`: 1 is X from D
    fmov_from_gp,
    fcsel_s,
    fcsel_d,
    fmadd_s, // `a`: 0 fmadd 1 fmsub 2 fnmadd 3 fnmsub
    fmadd_d,
};

pub const Op = extern struct {
    k: Kind = .undef,
    d: u8 = 0,
    n: u8 = 0,
    m: u8 = 0,
    a: u8 = 0,
    x: u8 = 0,
    sh: u8 = 0,
    w: u8 = 0,
    imm: u64 = 0,
};

comptime {
    std.debug.assert(@sizeOf(Op) == 16);
}

pub const Page = struct {
    ops: [ops_per_page + 1]Op,
};

// ---------------------------------------------------------------- decoding

fn bits(w: u32, comptime hi: u5, comptime lo: u5) u32 {
    return (w >> lo) & ((@as(u32, 1) << (hi - lo + 1)) - 1);
}

fn sext(v: u64, comptime n: u7) u64 {
    const s: u7 = 64 - n;
    return @bitCast(@as(i64, @bitCast(v << @intCast(s))) >> @intCast(s));
}

/// Register operand: 31 as ZR (`zr`) or SP.
fn rz(r: u32) u8 {
    return @intCast(r);
}
fn rdz(r: u32) u8 {
    return if (r == 31) SINK else @intCast(r);
}
fn rsp(r: u32) u8 {
    return if (r == 31) SP else @intCast(r);
}

fn ones(n: u7) u64 {
    return if (n >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(n)) - 1;
}

fn ror(v: u64, r: u7, width: u7) u64 {
    if (r == 0) return v;
    const m = ones(width);
    return ((v >> @intCast(r)) | (v << @intCast(width - r))) & m;
}

/// DecodeBitMasks for logical immediates; null if reserved.
fn bitmask(n: u32, imms: u32, immr: u32, width: u7) ?u64 {
    const combined: u32 = (n << 6) | (~imms & 0x3f);
    if (combined == 0) return null;
    const len: u5 = @intCast(31 - @clz(combined));
    if (len < 1) return null;
    const esize: u7 = @as(u7, 1) << @intCast(len);
    const levels: u32 = esize - 1;
    const s = imms & levels;
    const r = immr & levels;
    if (s == levels) return null;
    const welem = ones(@intCast(s + 1));
    var elem = ror(welem, @intCast(r), esize);
    var res: u64 = 0;
    var i: u7 = 0;
    while (i < width) : (i += esize) {
        res |= elem << @intCast(i);
        elem = elem;
    }
    return res & ones(width);
}

fn vfp(word: u32) u8 {
    return @intCast(word & 31);
}

/// Decodes the instruction at `pc`. Anything outside the subset is `.undef`,
/// which faults with EC 0 if it's ever executed.
pub fn decode(w: u32, pc: u64) Op {
    const sf = bits(w, 31, 31) == 1;
    const rd = bits(w, 4, 0);
    const rn = bits(w, 9, 5);
    const rm = bits(w, 20, 16);
    const op0 = bits(w, 28, 25);

    // ---- data processing, immediate
    if (op0 & 0b1110 == 0b1000) {
        switch (bits(w, 25, 23)) {
            0b000, 0b001 => { // ADR, ADRP
                const imm = (bits(w, 23, 5) << 2) | bits(w, 30, 29);
                const off = sext(imm, 21);
                const t = if (sf) (pc & ~@as(u64, 0xfff)) +% (off << 12) else pc +% off;
                return .{ .k = .movi, .d = rdz(rd), .imm = t };
            },
            0b010 => { // add/sub immediate
                if (bits(w, 22, 22) == 1 and false) {}
                var imm: u64 = bits(w, 21, 10);
                if (bits(w, 22, 22) == 1) imm <<= 12;
                const op = bits(w, 30, 30);
                const s = bits(w, 29, 29);
                const d = if (s == 1) rdz(rd) else rsp(rd);
                const n = rsp(rn);
                if (op == 0 and s == 0) return .{ .k = if (sf) .add_imm_x else .add_imm_w, .d = d, .n = n, .imm = imm };
                if (op == 1 and s == 0) return .{ .k = if (sf) .add_imm_x else .add_imm_w, .d = d, .n = n, .imm = 0 -% imm };
                if (op == 0) return .{ .k = if (sf) .adds_imm_x else .adds_imm_w, .d = d, .n = n, .imm = imm };
                return .{ .k = if (sf) .subs_imm_x else .subs_imm_w, .d = d, .n = n, .imm = imm };
            },
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
                switch (bits(w, 30, 29)) {
                    0 => {
                        const v = ~(imm16 << sh);
                        return .{ .k = .movi, .d = rdz(rd), .imm = if (sf) v else v & 0xffffffff };
                    },
                    2 => return .{ .k = .movi, .d = rdz(rd), .imm = imm16 << sh },
                    3 => return .{ .k = if (sf) .movk_x else .movk_w, .d = rdz(rd), .sh = sh, .imm = imm16 },
                    else => return .{},
                }
            },
            0b110 => { // bitfield
                const nbit = bits(w, 22, 22);
                if (sf != (nbit == 1)) return .{};
                const width: u32 = if (sf) 64 else 32;
                const immr = bits(w, 21, 16);
                const imms = bits(w, 15, 10);
                if (!sf and (immr >= 32 or imms >= 32)) return .{};
                const opc = bits(w, 30, 29);
                const base: Op = .{ .d = rdz(rd), .n = rz(rn) };
                var o = base;
                switch (opc) {
                    0, 2 => {
                        const signed = opc == 0;
                        if (imms >= immr) { // xBFX: field [imms:immr] to bit 0
                            o.k = if (signed) (if (sf) Kind.sbfx_x else .sbfx_w) else (if (sf) Kind.ubfx_x else .ubfx_w);
                            o.sh = @intCast(immr);
                            o.a = @intCast(imms - immr + 1);
                        } else { // xBFIZ: low imms+1 bits to bit width-immr
                            o.k = if (signed) (if (sf) Kind.sbfiz_x else .sbfiz_w) else (if (sf) Kind.ubfiz_x else .ubfiz_w);
                            o.sh = @intCast(width - immr);
                            o.a = @intCast(imms + 1);
                        }
                    },
                    1 => {
                        o.k = if (sf) .bfm_x else .bfm_w;
                        o.d = rz(rd); // BFM reads Rd too
                        o.sh = @intCast(immr);
                        o.a = @intCast(imms);
                    },
                    else => return .{},
                }
                return o;
            },
            0b111 => { // EXTR
                if (bits(w, 30, 29) != 0 or bits(w, 21, 21) != 0) return .{};
                if (sf != (bits(w, 22, 22) == 1)) return .{};
                const lsb = bits(w, 15, 10);
                if (!sf and lsb >= 32) return .{};
                return .{ .k = if (sf) .extr_x else .extr_w, .d = rdz(rd), .n = rz(rn), .m = rz(rm), .sh = @intCast(lsb) };
            },
            else => return .{},
        }
    }

    // ---- branches, exceptions, system
    if (op0 & 0b1110 == 0b1010) {
        if (bits(w, 30, 26) == 0b00101) { // B, BL
            const t = pc +% (sext(bits(w, 25, 0), 26) << 2);
            return .{ .k = if (sf) .bl else .b, .imm = t };
        }
        if (bits(w, 31, 24) == 0x54 and bits(w, 4, 4) == 0) {
            const t = pc +% (sext(bits(w, 23, 5), 19) << 2);
            return .{ .k = @enumFromInt(@intFromEnum(Kind.bcond_0) + bits(w, 3, 0)), .x = @intCast(bits(w, 3, 0)), .imm = t };
        }
        if (bits(w, 30, 25) == 0b011010) { // CBZ, CBNZ
            const t = pc +% (sext(bits(w, 23, 5), 19) << 2);
            const nz = bits(w, 24, 24) == 1;
            const k: Kind = if (nz) (if (sf) .cbnz_x else .cbnz_w) else (if (sf) .cbz_x else .cbz_w);
            return .{ .k = k, .n = rz(rd), .imm = t };
        }
        if (bits(w, 30, 25) == 0b011011) { // TBZ, TBNZ
            const t = pc +% (sext(bits(w, 18, 5), 14) << 2);
            const bit = (bits(w, 31, 31) << 5) | bits(w, 23, 19);
            return .{ .k = if (bits(w, 24, 24) == 1) .tbnz else .tbz, .n = rz(rd), .sh = @intCast(bit), .imm = t };
        }
        if (w & 0xffe0001f == 0xd4000001) return .{ .k = .svc, .imm = bits(w, 20, 5) };
        if (w & 0xffe0001f == 0xd4200000) return .{ .k = .brk, .imm = bits(w, 20, 5) };
        if (w & 0xfffffc1f == 0xd61f0000) return .{ .k = .br, .n = rz(rn) };
        if (w & 0xfffffc1f == 0xd63f0000) return .{ .k = .blr, .n = rz(rn) };
        if (w & 0xfffffc1f == 0xd65f0000) return .{ .k = .ret, .n = rz(rn) };
        if (w & 0xfffff01f == 0xd503301f) { // CLREX, DSB, DMB, ISB
            const op2 = bits(w, 7, 5);
            return switch (op2) {
                2 => .{ .k = .nop, .a = 1 }, // CLREX: `a` clears the monitor
                4, 5 => .{ .k = .fence },
                6 => .{ .k = .nop },
                else => .{},
            };
        }
        if (w & 0xfffff01f == 0xd503201f) return .{ .k = .nop }; // hints (NOP, YIELD, ...)
        if (w & 0xfff80000 == 0xd5380000 or w & 0xfff80000 == 0xd5180000) { // MRS, MSR (register)
            const sysreg: u32 = bits(w, 20, 5); // o0:op1:CRn:CRm:op2
            const ok = switch (sysreg) {
                sr(3, 3, 4, 2, 0), sr(3, 3, 4, 4, 0), sr(3, 3, 4, 4, 1), sr(3, 3, 13, 0, 2) => true, // NZCV FPCR FPSR TPIDR_EL0
                sr(3, 3, 14, 0, 1), sr(3, 3, 14, 0, 0), sr(3, 3, 0, 0, 1), sr(3, 3, 0, 0, 7) => bits(w, 21, 21) == 1, // CNTVCT CNTFRQ CTR DCZID: read-only
                else => false,
            };
            if (!ok) return .{};
            return .{ .k = if (bits(w, 21, 21) == 1) .mrs else .msr, .d = rdz(rd), .n = rz(rd), .imm = sysreg };
        }
        if (w & 0xffffffe0 == 0xd50b7420) return .{ .k = .dc_zva, .n = rz(rd) };
        if (w & 0xffffffe0 == 0xd50b7520 or w & 0xffffffe0 == 0xd50b7b20 or w & 0xffffffe0 == 0xd50b7e20 or w & 0xffffffe0 == 0xd50b7a20 or w & 0xffffffe0 == 0xd50b7f20) return .{ .k = .nop }; // IC IVAU, DC CVAU/CVAC/CIVAC/CVAP
        return .{};
    }

    // ---- loads and stores
    if (op0 & 0b0101 == 0b0100) return decodeLdSt(w, pc);

    // ---- data processing, register
    if (op0 & 0b0111 == 0b0101) {
        const op1 = bits(w, 28, 28);
        const op2 = bits(w, 24, 21);
        if (op1 == 0 and op2 & 0b1000 == 0) { // logical (shifted register)
            const shift = bits(w, 23, 22);
            const amt = bits(w, 15, 10);
            if (!sf and amt >= 32) return .{};
            const opcn: u8 = @intCast((bits(w, 30, 29) << 1) | bits(w, 21, 21));
            if (opcn == 2 and rn == 31 and amt == 0) return .{ .k = if (sf) .mov_x else .mov_w, .d = rdz(rd), .n = rz(rm) };
            const lk: Kind = @enumFromInt(@intFromEnum(Kind.and_sreg_x) + 2 * @as(u8, opcn) + @intFromBool(!sf));
            return .{ .k = lk, .d = rdz(rd), .n = rz(rn), .m = rz(rm), .a = opcn, .x = @intCast(shift), .sh = @intCast(amt) };
        }
        if (op1 == 0 and op2 & 0b1001 == 0b1000) { // add/sub (shifted register)
            const shift = bits(w, 23, 22);
            if (shift == 3) return .{};
            const amt = bits(w, 15, 10);
            if (!sf and amt >= 32) return .{};
            const k: Kind = switch (bits(w, 30, 29)) {
                0 => if (sf) .add_sreg_x else .add_sreg_w,
                1 => if (sf) .adds_sreg_x else .adds_sreg_w,
                2 => if (sf) .sub_sreg_x else .sub_sreg_w,
                else => if (sf) .subs_sreg_x else .subs_sreg_w,
            };
            if (amt == 0 and (k == .add_sreg_x or k == .add_sreg_w or k == .sub_sreg_x or k == .sub_sreg_w)) {
                const fk: Kind = switch (k) {
                    .add_sreg_x => .add_reg_x,
                    .add_sreg_w => .add_reg_w,
                    .sub_sreg_x => .sub_reg_x,
                    else => .sub_reg_w,
                };
                return .{ .k = fk, .d = rdz(rd), .n = rz(rn), .m = rz(rm) };
            }
            return .{ .k = k, .d = rdz(rd), .n = rz(rn), .m = rz(rm), .x = @intCast(shift), .sh = @intCast(amt) };
        }
        if (op1 == 0 and op2 & 0b1001 == 0b1001) { // add/sub (extended register)
            if (bits(w, 23, 22) != 0) return .{};
            const amt = bits(w, 12, 10);
            if (amt > 4) return .{};
            const s = bits(w, 29, 29);
            const k: Kind = switch (bits(w, 30, 29)) {
                0 => if (sf) .add_ereg_x else .add_ereg_w,
                1 => if (sf) .adds_ereg_x else .adds_ereg_w,
                2 => if (sf) .sub_ereg_x else .sub_ereg_w,
                else => if (sf) .subs_ereg_x else .subs_ereg_w,
            };
            return .{ .k = k, .d = if (s == 1) rdz(rd) else rsp(rd), .n = rsp(rn), .m = rz(rm), .x = @intCast(bits(w, 15, 13)), .sh = @intCast(amt) };
        }
        if (op1 == 1 and op2 == 0b0100) { // conditional select
            if (bits(w, 29, 29) != 0 or bits(w, 11, 11) != 0) return .{};
            const op: u8 = @intCast((bits(w, 30, 30) << 1) | bits(w, 10, 10));
            return .{ .k = if (sf) .csel_x else .csel_w, .d = rdz(rd), .n = rz(rn), .m = rz(rm), .a = op, .x = @intCast(bits(w, 15, 12)) };
        }
        if (op1 == 1 and op2 == 0b0110 and bits(w, 30, 30) == 0) { // data processing (2 source)
            if (bits(w, 29, 29) != 0) return .{};
            const k: Kind = switch (bits(w, 15, 10)) {
                0b000010 => if (sf) .udiv_x else .udiv_w,
                0b000011 => if (sf) .sdiv_x else .sdiv_w,
                0b001000 => if (sf) .lslv_x else .lslv_w,
                0b001001 => if (sf) .lsrv_x else .lsrv_w,
                0b001010 => if (sf) .asrv_x else .asrv_w,
                0b001011 => if (sf) .rorv_x else .rorv_w,
                else => return .{},
            };
            return .{ .k = k, .d = rdz(rd), .n = rz(rn), .m = rz(rm) };
        }
        if (op1 == 1 and op2 & 0b1000 == 0b1000) { // data processing (3 source)
            if (bits(w, 30, 29) != 0) return .{};
            const ra = bits(w, 14, 10);
            const o0 = bits(w, 15, 15);
            const k: Kind = switch (bits(w, 23, 21)) {
                0b000 => if (o0 == 0) (if (sf) Kind.madd_x else .madd_w) else (if (sf) Kind.msub_x else .msub_w),
                0b001 => if (!sf) return .{} else if (o0 == 0) .smaddl else .smsubl,
                0b101 => if (!sf) return .{} else if (o0 == 0) .umaddl else .umsubl,
                0b010 => if (!sf or o0 == 1) return .{} else .smulh,
                0b110 => if (!sf or o0 == 1) return .{} else .umulh,
                else => return .{},
            };
            return .{ .k = k, .d = rdz(rd), .n = rz(rn), .m = rz(rm), .a = rz(ra) };
        }
        return .{};
    }

    // ---- scalar floating point
    if (op0 & 0b0111 == 0b0111) return decodeFp(w);
    return .{};
}

fn sr(o0: u32, op1: u32, crn: u32, crm: u32, op2: u32) u32 {
    return ((o0 - 2) << 14) | (1 << 15) | (op1 << 11) | (crn << 7) | (crm << 3) | op2;
}

const LdSt = struct { o: Kind, m: Kind, scale: u3 };

fn decodeLdSt(w: u32, pc: u64) Op {
    const rt = bits(w, 4, 0);
    const rn = bits(w, 9, 5);
    const size = bits(w, 31, 30);
    const v = bits(w, 26, 26) == 1;

    // load literal
    if (bits(w, 29, 27) == 0b011 and bits(w, 25, 24) == 0) {
        const t = pc +% (sext(bits(w, 23, 5), 19) << 2);
        const opc = bits(w, 31, 30);
        const k: Kind = if (v) switch (opc) {
            0 => .ldr_s_m,
            1 => .ldr_d_m,
            2 => .ldr_q_m,
            else => return .{},
        } else switch (opc) {
            0 => .ldr_w_m,
            1 => .ldr_x_m,
            2 => .ldrsw_m,
            else => return .{ .k = .nop }, // PRFM (literal)
        };
        return .{ .k = k, .d = if (v) vfp(w) else rdz(rt), .x = 4, .imm = t };
    }
    // exclusives and acquire/release
    if (bits(w, 29, 24) == 0b001000) {
        const o2 = bits(w, 23, 23);
        const l = bits(w, 22, 22);
        const o1 = bits(w, 21, 21);
        const rs = bits(w, 20, 16);
        if (o1 == 1) return .{}; // pairs
        if (o2 == 0) {
            const k: Kind = if (l == 1) switch (size) {
                0 => .ldxr_b,
                1 => .ldxr_h,
                2 => .ldxr_w,
                else => .ldxr_x,
            } else switch (size) {
                0 => .stxr_b,
                1 => .stxr_h,
                2 => .stxr_w,
                else => .stxr_x,
            };
            return .{ .k = k, .d = if (l == 1) rdz(rt) else rdz(rs), .m = rz(rt), .n = rsp(rn), .x = @intCast(size) };
        }
        if (bits(w, 15, 15) == 0) return .{}; // LDLAR/STLLR
        if (size < 2) return .{};
        const k: Kind = if (l == 1) (if (size == 3) .ldar_x else .ldar_w) else (if (size == 3) .stlr_x else .stlr_w);
        return .{ .k = k, .d = rdz(rt), .m = rz(rt), .n = rsp(rn), .x = @intCast(size) };
    }
    // pairs
    if (bits(w, 29, 27) == 0b101) {
        const mode = bits(w, 24, 23);
        if (mode == 0) return .{}; // non-temporal: not in the subset
        const l = bits(w, 22, 22) == 1;
        const opc = bits(w, 31, 30);
        const k: Kind, const scale: u6 = if (v) switch (opc) {
            1 => .{ if (l) .ldp_d else .stp_d, 3 },
            2 => .{ if (l) .ldp_q else .stp_q, 4 },
            else => return .{},
        } else switch (opc) {
            0 => .{ if (l) .ldp_w else .stp_w, 2 },
            1 => .{ if (l) .ldpsw else return .{}, 2 },
            2 => .{ if (l) .ldp_x else .stp_x, 3 },
            else => return .{},
        };
        const imm = sext(bits(w, 21, 15), 7) << scale;
        const rt2 = bits(w, 14, 10);
        // `x`: 1 post-index, 2 offset, 3 pre-index
        if (v) return .{ .k = k, .d = @intCast(rt), .m = @intCast(rt2), .n = rsp(rn), .x = @intCast(mode), .imm = imm };
        return .{ .k = k, .d = if (l) rdz(rt) else rz(rt), .m = if (l) rdz(rt2) else rz(rt2), .n = rsp(rn), .x = @intCast(mode), .imm = imm };
    }
    // single register
    if (bits(w, 29, 27) != 0b111) return .{};
    const opc = bits(w, 23, 22);
    const ls: LdSt = blk: {
        if (v) {
            const s = (opc & 2) << 1 | size; // size with opc<1> as bit 2
            const load = opc & 1 == 1;
            break :blk switch (s) {
                2 => if (load) .{ .o = .ldr_s_o, .m = .ldr_s_m, .scale = 2 } else .{ .o = .str_s_o, .m = .str_s_m, .scale = 2 },
                3 => if (load) .{ .o = .ldr_d_o, .m = .ldr_d_m, .scale = 3 } else .{ .o = .str_d_o, .m = .str_d_m, .scale = 3 },
                4 => if (load) .{ .o = .ldr_q_o, .m = .ldr_q_m, .scale = 4 } else .{ .o = .str_q_o, .m = .str_q_m, .scale = 4 },
                else => return .{},
            };
        }
        break :blk switch (size) {
            0 => switch (opc) {
                0 => .{ .o = .strb_o, .m = .strb_m, .scale = 0 },
                1 => .{ .o = .ldrb_o, .m = .ldrb_m, .scale = 0 },
                2 => .{ .o = .ldrsb_x_o, .m = .ldrsb_x_m, .scale = 0 },
                else => .{ .o = .ldrsb_w_o, .m = .ldrsb_w_m, .scale = 0 },
            },
            1 => switch (opc) {
                0 => .{ .o = .strh_o, .m = .strh_m, .scale = 1 },
                1 => .{ .o = .ldrh_o, .m = .ldrh_m, .scale = 1 },
                2 => .{ .o = .ldrsh_x_o, .m = .ldrsh_x_m, .scale = 1 },
                else => .{ .o = .ldrsh_w_o, .m = .ldrsh_w_m, .scale = 1 },
            },
            2 => switch (opc) {
                0 => .{ .o = .str_w_o, .m = .str_w_m, .scale = 2 },
                1 => .{ .o = .ldr_w_o, .m = .ldr_w_m, .scale = 2 },
                2 => .{ .o = .ldrsw_o, .m = .ldrsw_m, .scale = 2 },
                else => return .{},
            },
            else => switch (opc) {
                0 => .{ .o = .str_x_o, .m = .str_x_m, .scale = 3 },
                1 => .{ .o = .ldr_x_o, .m = .ldr_x_m, .scale = 3 },
                2 => return .{ .k = .nop }, // PRFM
                else => return .{},
            },
        };
    };
    const isload = switch (ls.o) {
        .str_x_o, .str_w_o, .strb_o, .strh_o, .str_s_o, .str_d_o, .str_q_o => false,
        else => true,
    };
    const t: u8 = if (v) @intCast(rt) else if (isload) rdz(rt) else rz(rt);
    if (bits(w, 25, 24) == 1) { // unsigned offset
        return .{ .k = ls.o, .d = t, .n = rsp(rn), .imm = @as(u64, bits(w, 21, 10)) << ls.scale };
    }
    if (bits(w, 25, 24) != 0) return .{};
    if (bits(w, 21, 21) == 0) {
        const imm = sext(bits(w, 20, 12), 9);
        return switch (bits(w, 11, 10)) {
            0 => .{ .k = ls.o, .d = t, .n = rsp(rn), .imm = imm }, // unscaled
            1 => .{ .k = ls.m, .d = t, .n = rsp(rn), .x = 1, .imm = imm }, // post-index
            3 => .{ .k = ls.m, .d = t, .n = rsp(rn), .x = 3, .imm = imm }, // pre-index
            else => .{}, // unprivileged
        };
    }
    if (bits(w, 11, 10) != 2) return .{};
    const option = bits(w, 15, 13);
    if (option & 2 == 0) return .{};
    const amt: u8 = if (bits(w, 12, 12) == 1) ls.scale else 0;
    // `x`: 5 register offset; `a`: extend option; `sh`: shift
    return .{ .k = ls.m, .d = t, .n = rsp(rn), .m = rz(bits(w, 20, 16)), .x = 5, .a = @intCast(option), .sh = amt };
}

fn decodeFp(w: u32) Op {
    if (bits(w, 31, 31) != 0 and bits(w, 30, 24) != 0b0011110) return .{};
    const rd = bits(w, 4, 0);
    const rn = bits(w, 9, 5);
    const rm = bits(w, 20, 16);
    // FMADD and friends
    if (bits(w, 31, 24) == 0x1f) {
        const ty = bits(w, 23, 22);
        if (ty > 1) return .{};
        const a: u8 = @intCast((bits(w, 21, 21) << 1) | bits(w, 15, 15));
        return .{ .k = if (ty == 1) .fmadd_d else .fmadd_s, .d = @intCast(rd), .n = @intCast(rn), .m = @intCast(rm), .x = @intCast(bits(w, 14, 10)), .a = a };
    }
    if (bits(w, 30, 24) != 0b0011110 or bits(w, 29, 29) != 0) return .{};
    const sf = bits(w, 31, 31) == 1;
    const ty = bits(w, 23, 22);
    const isd = ty == 1;
    if (ty > 1) return .{};
    if (bits(w, 21, 21) == 0) return .{}; // fixed-point conversions
    if (bits(w, 15, 10) == 0) { // conversions to and from integers
        const rmode = bits(w, 20, 19);
        const opc = bits(w, 18, 16);
        const xb: u8 = @intFromBool(sf);
        const db: u8 = @intFromBool(isd);
        if (rmode == 0 and (opc == 2 or opc == 3)) return .{ .k = .scvtf, .d = @intCast(rd), .n = rz(rn), .x = xb | (db << 1), .a = @intFromBool(opc == 3) };
        if (rmode == 3 and (opc == 0 or opc == 1)) return .{ .k = .fcvtz, .d = rdz(rd), .n = @intCast(rn), .x = xb | (db << 1), .a = @intCast(opc) };
        if (rmode == 0 and opc == 6 and sf == isd) return .{ .k = .fmov_to_gp, .d = rdz(rd), .n = @intCast(rn), .x = xb };
        if (rmode == 0 and opc == 7 and sf == isd) return .{ .k = .fmov_from_gp, .d = @intCast(rd), .n = rz(rn), .x = xb };
        return .{};
    }
    if (bits(w, 14, 10) == 0b10000) { // 1 source
        const opc = bits(w, 20, 15);
        const base: Op = .{ .d = @intCast(rd), .n = @intCast(rn) };
        var o = base;
        o.k = switch (opc) {
            0 => if (isd) .fmov_d else .fmov_s,
            1 => if (isd) .fabs_d else .fabs_s,
            2 => if (isd) .fneg_d else .fneg_s,
            3 => if (isd) .fsqrt_d else .fsqrt_s,
            4 => if (isd) .fcvt_ds else return .{}, // FCVT to single, from double
            5 => if (isd) return .{} else .fcvt_sd, // FCVT to double, from single
            8, 9, 10, 11, 12, 14, 15 => blk: {
                o.x = @intCast(opc & 7);
                break :blk if (isd) Kind.frint_d else .frint_s;
            },
            else => return .{},
        };
        return o;
    }
    if (bits(w, 13, 10) == 0b1000) { // compare
        if (bits(w, 15, 14) != 0 or bits(w, 2, 0) != 0) return .{};
        return .{ .k = if (isd) .fcmp_d else .fcmp_s, .n = @intCast(rn), .m = @intCast(rm), .a = @intCast(bits(w, 3, 3)) };
    }
    if (bits(w, 12, 10) == 0b100) { // immediate
        if (bits(w, 9, 5) != 0) return .{};
        const imm8 = bits(w, 20, 13);
        return .{ .k = if (isd) .fmovi_d else .fmovi_s, .d = @intCast(rd), .imm = vfpExpandImm(imm8, isd) };
    }
    if (bits(w, 11, 10) == 0b10) { // 2 source
        const k: Kind = switch (bits(w, 15, 12)) {
            0 => if (isd) .fmul_d else .fmul_s,
            1 => if (isd) .fdiv_d else .fdiv_s,
            2 => if (isd) .fadd_d else .fadd_s,
            3 => if (isd) .fsub_d else .fsub_s,
            8 => if (isd) .fnmul_d else .fnmul_s,
            else => return .{},
        };
        return .{ .k = k, .d = @intCast(rd), .n = @intCast(rn), .m = @intCast(rm) };
    }
    if (bits(w, 11, 10) == 0b11) { // conditional select
        return .{ .k = if (isd) .fcsel_d else .fcsel_s, .d = @intCast(rd), .n = @intCast(rn), .m = @intCast(rm), .x = @intCast(bits(w, 15, 12)) };
    }
    return .{};
}

fn vfpExpandImm(imm8: u32, d: bool) u64 {
    const sign: u64 = imm8 >> 7;
    const b6: u64 = (imm8 >> 6) & 1;
    const rest: u64 = imm8 & 0x3f;
    if (d) {
        const exp: u64 = ((b6 ^ 1) << 10) | (if (b6 == 1) @as(u64, 0xff) << 2 else 0) | ((imm8 >> 4) & 3);
        return (sign << 63) | (exp << 52) | ((rest & 0xf) << 48);
    }
    const exp: u64 = ((b6 ^ 1) << 7) | (if (b6 == 1) @as(u64, 0x1f) << 2 else 0) | ((imm8 >> 4) & 3);
    return (sign << 31) | (exp << 23) | ((rest & 0xf) << 19);
}

/// Decodes the text page at `va`. Words are read once; data in text
/// (literal pools, CASE tables) decodes to whatever it decodes to, and only
/// faults if it's executed.
pub fn decodePage(p: *Page, va: u64, text: *const [page_size]u8) void {
    for (0..ops_per_page) |i| {
        const word = std.mem.readInt(u32, text[i * 4 ..][0..4], .little);
        p.ops[i] = decode(word, va + i * 4);
    }
    p.ops[ops_per_page] = .{ .k = .next_page, .imm = va + page_size };
}

// ---------------------------------------------------------------- execution

fn cond(nzcv: u32, c: u8) bool {
    const n = nzcv >> 31 & 1 == 1;
    const z = nzcv >> 30 & 1 == 1;
    const cf = nzcv >> 29 & 1 == 1;
    const v = nzcv >> 28 & 1 == 1;
    const r = switch (c >> 1) {
        0 => z,
        1 => cf,
        2 => n,
        3 => v,
        4 => cf and !z,
        5 => n == v,
        6 => n == v and !z,
        else => true,
    };
    return if (c & 1 == 1 and c != 15) !r else r;
}

fn addFlags(comptime T: type, a: T, b: T, carry_in: u1) struct { T, u32 } {
    const S = std.meta.Int(.signed, @bitSizeOf(T));
    const r1 = @addWithOverflow(a, b);
    const r2 = @addWithOverflow(r1[0], @as(T, carry_in));
    const res = r2[0];
    const c: u32 = r1[1] | r2[1];
    const s1 = @addWithOverflow(@as(S, @bitCast(a)), @as(S, @bitCast(b)));
    const s2 = @addWithOverflow(s1[0], @as(S, carry_in));
    const v: u32 = s1[1] | s2[1];
    const n: u32 = @intCast(res >> (@bitSizeOf(T) - 1));
    const z: u32 = @intFromBool(res == 0);
    return .{ res, (n << 31) | (z << 30) | (c << 29) | (v << 28) };
}

fn shiftReg(comptime T: type, v: T, ty: u8, amt: u8) T {
    const S = std.meta.Int(.signed, @bitSizeOf(T));
    const A = std.math.Log2Int(T);
    const a: A = @intCast(amt);
    return switch (ty) {
        0 => v << a,
        1 => v >> a,
        2 => @bitCast(@as(S, @bitCast(v)) >> a),
        else => std.math.rotr(T, v, a),
    };
}

fn extendReg(v: u64, option: u8, amt: u8) u64 {
    const e: u64 = switch (option) {
        0 => v & 0xff,
        1 => v & 0xffff,
        2 => v & 0xffffffff,
        3 => v,
        4 => sext(v & 0xff, 8),
        5 => sext(v & 0xffff, 16),
        6 => sext(v & 0xffffffff, 32),
        else => v,
    };
    return e << @intCast(amt);
}

// FP: results that don't depend on the host. ARM's default NaN is
// positive; x86 generates a negative one, and the two pick different
// operands to propagate.
fn FBits(comptime F: type) type {
    return if (F == f32) u32 else u64;
}

fn isSnan(comptime F: type, b: FBits(F)) bool {
    const B = FBits(F);
    const quiet: B = if (F == f32) 0x00400000 else 0x0008000000000000;
    const exp: B = if (F == f32) 0x7f800000 else 0x7ff0000000000000;
    return b & exp == exp and b & ~(exp | (@as(B, 1) << (@bitSizeOf(B) - 1))) != 0 and b & quiet == 0;
}

fn defaultNan(comptime F: type) FBits(F) {
    return if (F == f32) 0x7fc00000 else 0x7ff8000000000000;
}

fn quieten(comptime F: type, b: FBits(F)) FBits(F) {
    return b | (if (F == f32) @as(FBits(F), 0x00400000) else 0x0008000000000000);
}

/// FPProcessNaNs: the NaN result for operands where at least one is NaN.
fn processNans(comptime F: type, cpu: *Cpu, a: FBits(F), b: FBits(F)) FBits(F) {
    const fa: F = @bitCast(a);
    const fb: F = @bitCast(b);
    if (isSnan(F, a) or isSnan(F, b)) cpu.fpsr |= 1; // IOC
    if (cpu.fpcr & (1 << 25) != 0) return defaultNan(F);
    if (isSnan(F, a)) return quieten(F, a);
    if (isSnan(F, b)) return quieten(F, b);
    if (std.math.isNan(fa)) return a;
    _ = fb;
    return b;
}

fn fop2(comptime F: type, cpu: *Cpu, a: FBits(F), b: FBits(F), comptime op: u8) FBits(F) {
    const fa: F = @bitCast(a);
    const fb: F = @bitCast(b);
    const r: F = switch (op) {
        '+' => fa + fb,
        '-' => fa - fb,
        '*' => fa * fb,
        '/' => fa / fb,
        else => unreachable,
    };
    if (r != r) { // NaN: from a NaN operand, or invalid
        if (fa != fa or fb != fb) return processNans(F, cpu, a, b);
        cpu.fpsr |= 1; // IOC
        return defaultNan(F);
    }
    if (op == '/' and fb == 0 and fa == fa and !std.math.isInf(fa) and fa != 0) cpu.fpsr |= 2; // DZC
    return @bitCast(r);
}

fn fsqrt(comptime F: type, cpu: *Cpu, a: FBits(F)) FBits(F) {
    const fa: F = @bitCast(a);
    const r = @sqrt(fa);
    if (r != r) {
        if (fa != fa) return processNans(F, cpu, a, a);
        cpu.fpsr |= 1;
        return defaultNan(F);
    }
    return @bitCast(r);
}

/// FCVTZS/FCVTZU: truncate, saturate, NaN gives 0.
fn fcvtz(comptime I: type, f: f64, cpu: *Cpu) I {
    if (f != f) {
        cpu.fpsr |= 1;
        return 0;
    }
    const t = @trunc(f);
    const lo: f64 = @floatFromInt(std.math.minInt(I));
    const hi: f64 = @floatFromInt(std.math.maxInt(I)); // rounds up to 2^n for 64-bit
    if (t < lo) {
        cpu.fpsr |= 1;
        return std.math.minInt(I);
    }
    if (t >= hi) {
        if (t > hi or @bitSizeOf(I) >= 53) {
            if (t >= hi and (@bitSizeOf(I) < 53 or t >= -lo * (if (@typeInfo(I).int.signedness == .signed) 1.0 else 2.0) or t > hi)) {
                cpu.fpsr |= 1;
                return std.math.maxInt(I);
            }
        }
        if (t == hi) return std.math.maxInt(I);
    }
    if (t != f) cpu.fpsr |= 0x10; // IXC
    return @intFromFloat(t);
}

fn frint(comptime F: type, f: F, mode: u8, fpcr: u32) F {
    if (f != f or std.math.isInf(f)) return f;
    const m: u8 = switch (mode) {
        0 => 0, // N: nearest, ties to even
        1 => 1, // P
        2 => 2, // M
        3 => 3, // Z
        4 => 4, // A: nearest, ties away
        6, 7 => @intCast((fpcr >> 22) & 3), // X, I: FPCR.RMode
        else => 0,
    };
    return switch (m) {
        0 => blk: {
            const r = @round(f);
            if (@abs(f - @trunc(f)) == 0.5) break :blk 2 * @round(f / 2);
            break :blk r;
        },
        1 => @ceil(f),
        2 => @floor(f),
        3 => @trunc(f),
        else => @round(f),
    };
}

fn fcmpFlags(comptime F: type, cpu: *Cpu, a: F, b: F, signal: bool) u32 {
    if (a != a or b != b) {
        if (signal or isSnan(F, @bitCast(a)) or isSnan(F, @bitCast(b))) cpu.fpsr |= 1;
        return 0x3 << 28; // C V
    }
    if (a == b) return 0x6 << 28; // Z C
    if (a < b) return 0x8 << 28; // N
    return 0x2 << 28; // C
}

pub const Clock = struct {
    ctx: *anyopaque,
    now: *const fn (*anyopaque) u64, // ticks at 24 MHz
};

pub const Machine = struct {
    cpu: *Cpu,
    mem: *Mem,
    cache: *Cache,
    kicked: *std.atomic.Value(bool),
    clock: ?Clock = null,
    deterministic: bool = false,
};

/// Decoded pages by virtual page number. Flushed with the TLB.
pub const Cache = struct {
    pages: std.AutoHashMapUnmanaged(u64, *Page) = .empty,
    gpa: std.mem.Allocator,
    last_vp: u64 = std.math.maxInt(u64),
    last: ?*Page = null,

    pub fn flush(c: *Cache) void {
        var it = c.pages.valueIterator();
        while (it.next()) |p| c.gpa.destroy(p.*);
        c.pages.clearRetainingCapacity();
        c.last_vp = std.math.maxInt(u64);
        c.last = null;
    }

    fn get(c: *Cache, mem: *Mem, va: u64) ?*Page {
        const vp = va >> 12;
        if (vp == c.last_vp) return c.last;
        const p = c.pages.get(vp) orelse blk: {
            const text = mem.fetch(vp << 12) orelse return null;
            const p = c.gpa.create(Page) catch return null;
            decodePage(p, vp << 12, text[0..page_size]);
            c.pages.put(c.gpa, vp, p) catch {
                c.gpa.destroy(p);
                return null;
            };
            break :blk p;
        };
        c.last_vp = vp;
        c.last = p;
        return p;
    }
};

var fence_word: u32 = 0;

/// Zig 0.16 allows atomics only up to pointer size, so wasm32 can't do
/// 64-bit ones; the spike falls back to plain accesses there.
const max_atomic = @sizeOf(usize);

/// Count every instruction in `retired` (costs a little; for measuring).
pub const count_all = false;

/// Runs until a syscall, fault or kick. `max` bounds the instructions run
/// (for stepping); pass maxInt for none.
pub fn run(mach: Machine, max_steps: u64) Exit {
    const cpu = mach.cpu;
    const mem = mach.mem;
    const r = &cpu.r;
    if (mach.kicked.swap(false, .acquire)) return .interrupted;
    cpu.r[ZR] = 0;
    var page = mach.cache.get(mem, cpu.pc) orelse
        return fault(cpu, mem, cpu.pc, .exec);
    var base = cpu.pc & ~@as(u64, 0xfff);
    var i: usize = @intCast((cpu.pc & 0xfff) >> 2);
    var budget = max_steps;
    const stepping = max_steps != std.math.maxInt(u64);

    dispatch: switch (page.ops[i].k) {
        .undef => {
            cpu.pc = base + i * 4;
            return .{ .fault = .{ .addr = cpu.pc, .access = .exec, .esr = (EC_UNKNOWN << 26) | (1 << 25) } };
        },
        .next_page => {
            const t = page.ops[i].imm;
            page = mach.cache.get(mem, t) orelse {
                cpu.pc = t;
                return fault(cpu, mem, t, .exec);
            };
            base = t;
            i = 0;
            if (mach.kicked.load(.monotonic)) {
                _ = mach.kicked.swap(false, .acquire);
                cpu.pc = t;
                return .interrupted;
            }
            continue :dispatch page.ops[i].k;
        },
        inline else => |k| {
            const o = &page.ops[i];
            if (count_all and !stepping) cpu.retired += 1;
            if (stepping) {
                if (budget == 0) {
                    cpu.pc = base + i * 4;
                    return .interrupted;
                }
                budget -= 1;
                cpu.retired += 1;
            }
            const res: Next = exec(k, o, cpu, mem, r, base + i * 4, mach);
            switch (res) {
                .next => {
                    i += 1;
                    continue :dispatch page.ops[i].k;
                },
                .jump => |t| {
                    if (t >> 12 != base >> 12) {
                        page = mach.cache.get(mem, t) orelse {
                            cpu.pc = t;
                            return fault(cpu, mem, t, .exec);
                        };
                        base = t & ~@as(u64, 0xfff);
                    }
                    i = @intCast((t & 0xfff) >> 2);
                    // Every guest loop has a taken branch, so checking here
                    // bounds how long a kick waits.
                    if (mach.kicked.load(.monotonic)) {
                        _ = mach.kicked.swap(false, .acquire);
                        cpu.pc = t;
                        return .interrupted;
                    }
                    if ((k == .br or k == .blr or k == .ret) and t & 3 != 0) {
                        cpu.pc = t;
                        return .{ .fault = .{ .addr = t, .access = .exec, .esr = (0x22 << 26) | (1 << 25) } }; // PC alignment
                    }
                    continue :dispatch page.ops[i].k;
                },
                .exit => |e| {
                    return e;
                },
            }
        },
    }
}

fn fault(cpu: *Cpu, mem: *Mem, addr: u64, acc: Access) Exit {
    _ = cpu;
    const ec: u64 = if (acc == .exec) EC_IABT_LOWER else EC_DABT_LOWER;
    const wnr: u64 = if (acc == .write) 1 << 6 else 0;
    return .{ .fault = .{ .addr = addr, .access = acc, .esr = (ec << 26) | (1 << 25) | wnr | mem.fsc(addr) } };
}

pub const Next = union(enum) { next, jump: u64, exit: Exit };

inline fn dataFault(cpu: *Cpu, mem: *Mem, pc: u64, addr: u64, acc: Access) Next {
    cpu.pc = pc;
    return .{ .exit = fault(cpu, mem, addr, acc) };
}

fn w32(v: u64) u64 {
    return v & 0xffffffff;
}

const LdSpec = struct { T: type, signed: bool = false, to32: bool = false, fp: bool = false, store: bool = false };

fn ldSpec(comptime k: Kind) LdSpec {
    @setEvalBranchQuota(100000);
    const name = @tagName(k);
    const base = name[0 .. name.len - 2];
    const eq = std.mem.eql;
    if (eq(u8, base, "ldr_x")) return .{ .T = u64 };
    if (eq(u8, base, "ldr_w")) return .{ .T = u32 };
    if (eq(u8, base, "ldrb")) return .{ .T = u8 };
    if (eq(u8, base, "ldrh")) return .{ .T = u16 };
    if (eq(u8, base, "ldrsb_x")) return .{ .T = u8, .signed = true };
    if (eq(u8, base, "ldrsb_w")) return .{ .T = u8, .signed = true, .to32 = true };
    if (eq(u8, base, "ldrsh_x")) return .{ .T = u16, .signed = true };
    if (eq(u8, base, "ldrsh_w")) return .{ .T = u16, .signed = true, .to32 = true };
    if (eq(u8, base, "ldrsw")) return .{ .T = u32, .signed = true };
    if (eq(u8, base, "str_x")) return .{ .T = u64, .store = true };
    if (eq(u8, base, "str_w")) return .{ .T = u32, .store = true };
    if (eq(u8, base, "strb")) return .{ .T = u8, .store = true };
    if (eq(u8, base, "strh")) return .{ .T = u16, .store = true };
    if (eq(u8, base, "ldr_s")) return .{ .T = u32, .fp = true };
    if (eq(u8, base, "ldr_d")) return .{ .T = u64, .fp = true };
    if (eq(u8, base, "ldr_q")) return .{ .T = u128, .fp = true };
    if (eq(u8, base, "str_s")) return .{ .T = u32, .fp = true, .store = true };
    if (eq(u8, base, "str_d")) return .{ .T = u64, .fp = true, .store = true };
    if (eq(u8, base, "str_q")) return .{ .T = u128, .fp = true, .store = true };
    unreachable;
}

fn isLdSt(comptime k: Kind) bool {
    @setEvalBranchQuota(100000);
    const name = @tagName(k);
    return (std.mem.endsWith(u8, name, "_o") or std.mem.endsWith(u8, name, "_m")) and
        (std.mem.startsWith(u8, name, "ldr") or std.mem.startsWith(u8, name, "str"));
}

inline fn loadStore(comptime k: Kind, o: *const Op, cpu: *Cpu, mem: *Mem, r: *[34]u64, pc: u64) Next {
    const s = comptime ldSpec(k);
    const modes = comptime std.mem.endsWith(u8, @tagName(k), "_m");
    var addr: u64 = undefined;
    var wb: ?u64 = null;
    if (!modes) {
        addr = r[o.n] +% o.imm;
    } else switch (o.x) {
        1 => { // post-index
            addr = r[o.n];
            wb = addr +% o.imm;
        },
        3 => { // pre-index
            addr = r[o.n] +% o.imm;
            wb = addr;
        },
        4 => addr = o.imm, // literal
        else => addr = r[o.n] +% extendReg(r[o.m], o.a, o.sh), // register offset
    }
    if (s.store) {
        const v: s.T = if (s.fp) @truncate(cpu.v[o.d]) else @truncate(r[o.d]);
        if (!mem.write(s.T, addr, v)) return dataFault(cpu, mem, pc, addr, .write);
    } else {
        const v = mem.read(s.T, addr) orelse return dataFault(cpu, mem, pc, addr, .read);
        if (s.fp) {
            cpu.v[o.d] = v;
        } else if (s.signed) {
            const S = std.meta.Int(.signed, @bitSizeOf(s.T));
            const e: i64 = @as(S, @bitCast(v));
            r[o.d] = if (s.to32) w32(@bitCast(e)) else @bitCast(e);
        } else r[o.d] = v;
    }
    if (wb) |b| r[o.n] = b;
    r[ZR] = 0;
    return .next;
}

inline fn exec(comptime k: Kind, o: *const Op, cpu: *Cpu, mem: *Mem, r: *[34]u64, pc: u64, mach: Machine) Next {
    if (comptime isLdSt(k)) return loadStore(k, o, cpu, mem, r, pc);
    switch (k) {
        .undef, .next_page => unreachable,
        .movi => r[o.d] = o.imm,
        .movk_x => r[o.d] = (r[o.d] & ~(@as(u64, 0xffff) << @intCast(o.sh))) | (o.imm << @intCast(o.sh)),
        .movk_w => r[o.d] = w32((r[o.d] & ~(@as(u64, 0xffff) << @intCast(o.sh))) | (o.imm << @intCast(o.sh))),
        .add_imm_x => r[o.d] = r[o.n] +% o.imm,
        .add_imm_w => r[o.d] = w32(r[o.n] +% o.imm),
        .adds_imm_x, .subs_imm_x => {
            const b = if (k == .adds_imm_x) o.imm else ~o.imm;
            const res, const f = addFlags(u64, r[o.n], b, @intFromBool(k == .subs_imm_x));
            r[o.d] = res;
            cpu.nzcv = f;
        },
        .adds_imm_w, .subs_imm_w => {
            const imm: u32 = @truncate(o.imm);
            const b = if (k == .adds_imm_w) imm else ~imm;
            const res, const f = addFlags(u32, @truncate(r[o.n]), b, @intFromBool(k == .subs_imm_w));
            r[o.d] = res;
            cpu.nzcv = f;
        },
        .and_imm_x => r[o.d] = r[o.n] & o.imm,
        .and_imm_w => r[o.d] = w32(r[o.n] & o.imm),
        .orr_imm_x => r[o.d] = r[o.n] | o.imm,
        .orr_imm_w => r[o.d] = w32(r[o.n] | o.imm),
        .eor_imm_x => r[o.d] = r[o.n] ^ o.imm,
        .eor_imm_w => r[o.d] = w32(r[o.n] ^ o.imm),
        .ands_imm_x, .ands_imm_w => {
            const res = if (k == .ands_imm_x) r[o.n] & o.imm else w32(r[o.n] & o.imm);
            r[o.d] = res;
            const top: u6 = if (k == .ands_imm_x) 63 else 31;
            cpu.nzcv = (@as(u32, @intCast((res >> top) & 1)) << 31) | (@as(u32, @intFromBool(res == 0)) << 30);
        },
        .ubfx_x => r[o.d] = (r[o.n] >> @intCast(o.sh)) & ones(@intCast(o.a)),
        .ubfx_w => r[o.d] = (w32(r[o.n]) >> @intCast(o.sh)) & ones(@intCast(o.a)),
        .ubfiz_x => r[o.d] = (r[o.n] & ones(@intCast(o.a))) << @intCast(o.sh),
        .ubfiz_w => r[o.d] = w32((r[o.n] & ones(@intCast(o.a))) << @intCast(o.sh)),
        .sbfx_x => {
            const top: u6 = @intCast(o.sh + o.a - 1);
            const v: i64 = @bitCast(r[o.n] << @intCast(63 - @as(u7, top)));
            r[o.d] = @bitCast(v >> @intCast(64 - @as(u7, @intCast(o.a))));
        },
        .sbfx_w => {
            const top: u5 = @intCast(o.sh + o.a - 1);
            const v: i32 = @bitCast(@as(u32, @truncate(r[o.n])) << @intCast(31 - @as(u6, top)));
            r[o.d] = @as(u32, @bitCast(v >> @intCast(32 - @as(u6, @intCast(o.a)))));
        },
        .sbfiz_x => {
            const v = sext(r[o.n] & ones(@intCast(o.a)), 64) ;
            const sx: i64 = @bitCast(v << @intCast(64 - @as(u7, @intCast(o.a))));
            r[o.d] = @as(u64, @bitCast(sx >> @intCast(64 - @as(u7, @intCast(o.a))))) << @intCast(o.sh);
        },
        .sbfiz_w => {
            const sx: i32 = @bitCast(@as(u32, @truncate(r[o.n])) << @intCast(32 - @as(u6, @intCast(o.a))));
            r[o.d] = w32(@as(u64, @as(u32, @bitCast(sx >> @intCast(32 - @as(u6, @intCast(o.a)))))) << @intCast(o.sh));
        },
        .bfm_x, .bfm_w => {
            const width: u7 = if (k == .bfm_x) 64 else 32;
            const immr: u7 = @intCast(o.sh);
            const imms: u7 = @intCast(o.a);
            const src = if (k == .bfm_x) r[o.n] else w32(r[o.n]);
            const dst = r[o.d];
            var res: u64 = undefined;
            if (imms >= immr) { // BFXIL
                const len = imms - immr + 1;
                const f = (src >> @intCast(immr)) & ones(len);
                res = (dst & ~ones(len)) | f;
            } else { // BFI
                const len = imms + 1;
                const lsb = width - immr;
                const m = ones(len) << @intCast(lsb);
                res = (dst & ~m) | ((src << @intCast(lsb)) & m);
            }
            r[o.d] = if (k == .bfm_x) res else w32(res);
        },
        .extr_x => r[o.d] = if (o.sh == 0) r[o.m] else (r[o.m] >> @intCast(o.sh)) | (r[o.n] << @intCast(64 - @as(u7, @intCast(o.sh)))),
        .extr_w => r[o.d] = if (o.sh == 0) w32(r[o.m]) else w32((w32(r[o.m]) >> @intCast(o.sh)) | (r[o.n] << @intCast(32 - @as(u7, @intCast(o.sh))))),
        .mov_x => r[o.d] = r[o.n],
        .mov_w => r[o.d] = w32(r[o.n]),
        .add_sreg_x, .sub_sreg_x, .adds_sreg_x, .subs_sreg_x => {
            const b = shiftReg(u64, r[o.m], o.x, o.sh);
            if (k == .add_sreg_x) r[o.d] = r[o.n] +% b else if (k == .sub_sreg_x) r[o.d] = r[o.n] -% b else {
                const res, const f = addFlags(u64, r[o.n], if (k == .adds_sreg_x) b else ~b, @intFromBool(k == .subs_sreg_x));
                r[o.d] = res;
                cpu.nzcv = f;
            }
        },
        .add_sreg_w, .sub_sreg_w, .adds_sreg_w, .subs_sreg_w => {
            const b = shiftReg(u32, @truncate(r[o.m]), o.x, o.sh);
            const a: u32 = @truncate(r[o.n]);
            if (k == .add_sreg_w) r[o.d] = a +% b else if (k == .sub_sreg_w) r[o.d] = a -% b else {
                const res, const f = addFlags(u32, a, if (k == .adds_sreg_w) b else ~b, @intFromBool(k == .subs_sreg_w));
                r[o.d] = res;
                cpu.nzcv = f;
            }
        },
        .add_ereg_x, .sub_ereg_x, .adds_ereg_x, .subs_ereg_x => {
            const b = extendReg(r[o.m], o.x, o.sh);
            if (k == .add_ereg_x) r[o.d] = r[o.n] +% b else if (k == .sub_ereg_x) r[o.d] = r[o.n] -% b else {
                const res, const f = addFlags(u64, r[o.n], if (k == .adds_ereg_x) b else ~b, @intFromBool(k == .subs_ereg_x));
                r[o.d] = res;
                cpu.nzcv = f;
            }
        },
        .add_ereg_w, .sub_ereg_w, .adds_ereg_w, .subs_ereg_w => {
            const b: u32 = @truncate(extendReg(r[o.m], o.x, o.sh));
            const a: u32 = @truncate(r[o.n]);
            if (k == .add_ereg_w) r[o.d] = a +% b else if (k == .sub_ereg_w) r[o.d] = a -% b else {
                const res, const f = addFlags(u32, a, if (k == .adds_ereg_w) b else ~b, @intFromBool(k == .subs_ereg_w));
                r[o.d] = res;
                cpu.nzcv = f;
            }
        },
        .add_reg_x => r[o.d] = r[o.n] +% r[o.m],
        .add_reg_w => r[o.d] = w32(r[o.n] +% r[o.m]),
        .sub_reg_x => r[o.d] = r[o.n] -% r[o.m],
        .sub_reg_w => r[o.d] = w32(r[o.n] -% r[o.m]),
        .and_sreg_x, .and_sreg_w, .bic_sreg_x, .bic_sreg_w, .orr_sreg_x, .orr_sreg_w, .orn_sreg_x, .orn_sreg_w, .eor_sreg_x, .eor_sreg_w, .eon_sreg_x, .eon_sreg_w, .ands_sreg_x, .ands_sreg_w, .bics_sreg_x, .bics_sreg_w => {
            const opcn = comptime (@intFromEnum(k) - @intFromEnum(Kind.and_sreg_x)) / 2;
            const T = if ((@intFromEnum(k) - @intFromEnum(Kind.and_sreg_x)) % 2 == 0) u64 else u32;
            var b = shiftReg(T, @truncate(r[o.m]), o.x, o.sh);
            if (opcn & 1 == 1) b = ~b;
            const a: T = @truncate(r[o.n]);
            const res: T = switch (opcn >> 1) {
                0, 3 => a & b,
                1 => a | b,
                else => a ^ b,
            };
            r[o.d] = res;
            if (opcn >> 1 == 3) cpu.nzcv = (@as(u32, @intCast(res >> (@bitSizeOf(T) - 1))) << 31) | (@as(u32, @intFromBool(res == 0)) << 30);
        },
        .lslv_x => r[o.d] = r[o.n] << @truncate(r[o.m]),
        .lslv_w => r[o.d] = @as(u32, @truncate(r[o.n])) << @truncate(r[o.m]),
        .lsrv_x => r[o.d] = r[o.n] >> @truncate(r[o.m]),
        .lsrv_w => r[o.d] = @as(u32, @truncate(r[o.n])) >> @truncate(r[o.m]),
        .asrv_x => r[o.d] = @bitCast(@as(i64, @bitCast(r[o.n])) >> @truncate(r[o.m])),
        .asrv_w => r[o.d] = @as(u32, @bitCast(@as(i32, @bitCast(@as(u32, @truncate(r[o.n])))) >> @truncate(r[o.m]))),
        .rorv_x => r[o.d] = std.math.rotr(u64, r[o.n], @as(u6, @truncate(r[o.m]))),
        .rorv_w => r[o.d] = std.math.rotr(u32, @as(u32, @truncate(r[o.n])), @as(u5, @truncate(r[o.m]))),
        // Division by zero gives 0 and MIN/-1 gives MIN, where Zig's are UB.
        .udiv_x => r[o.d] = if (r[o.m] == 0) 0 else r[o.n] / r[o.m],
        .udiv_w => {
            const a: u32 = @truncate(r[o.n]);
            const b: u32 = @truncate(r[o.m]);
            r[o.d] = if (b == 0) 0 else a / b;
        },
        .sdiv_x => {
            const a: i64 = @bitCast(r[o.n]);
            const b: i64 = @bitCast(r[o.m]);
            r[o.d] = if (b == 0) 0 else if (b == -1) @bitCast(0 -% a) else @bitCast(@divTrunc(a, b));
        },
        .sdiv_w => {
            const a: i32 = @bitCast(@as(u32, @truncate(r[o.n])));
            const b: i32 = @bitCast(@as(u32, @truncate(r[o.m])));
            r[o.d] = @as(u32, @bitCast(if (b == 0) 0 else if (b == -1) 0 -% a else @divTrunc(a, b)));
        },
        .madd_x => r[o.d] = r[o.a] +% r[o.n] *% r[o.m],
        .madd_w => r[o.d] = w32(r[o.a] +% r[o.n] *% r[o.m]),
        .msub_x => r[o.d] = r[o.a] -% r[o.n] *% r[o.m],
        .msub_w => r[o.d] = w32(r[o.a] -% r[o.n] *% r[o.m]),
        .umaddl => r[o.d] = r[o.a] +% w32(r[o.n]) * w32(r[o.m]),
        .umsubl => r[o.d] = r[o.a] -% w32(r[o.n]) * w32(r[o.m]),
        .smaddl, .smsubl => {
            const p: i64 = @as(i64, @as(i32, @bitCast(@as(u32, @truncate(r[o.n]))))) * @as(i32, @bitCast(@as(u32, @truncate(r[o.m]))));
            r[o.d] = if (k == .smaddl) r[o.a] +% @as(u64, @bitCast(p)) else r[o.a] -% @as(u64, @bitCast(p));
        },
        .umulh => r[o.d] = @truncate((@as(u128, r[o.n]) * r[o.m]) >> 64),
        .smulh => r[o.d] = @truncate(@as(u128, @bitCast((@as(i128, @as(i64, @bitCast(r[o.n]))) * @as(i64, @bitCast(r[o.m]))))) >> 64),
        .csel_x, .csel_w => {
            const c = cond(cpu.nzcv, o.x);
            var v: u64 = undefined;
            if (c) v = r[o.n] else {
                v = r[o.m];
                switch (o.a) {
                    1 => v +%= 1,
                    2 => v = ~v,
                    3 => v = 0 -% v,
                    else => {},
                }
            }
            r[o.d] = if (k == .csel_x) v else w32(v);
        },
        .b => return .{ .jump = o.imm },
        .bl => {
            r[30] = pc + 4;
            return .{ .jump = o.imm };
        },
        .bcond_0, .bcond_1, .bcond_2, .bcond_3, .bcond_4, .bcond_5, .bcond_6, .bcond_7, .bcond_8, .bcond_9, .bcond_10, .bcond_11, .bcond_12, .bcond_13, .bcond_14, .bcond_15 => if (cond(cpu.nzcv, comptime @intFromEnum(k) - @intFromEnum(Kind.bcond_0))) return .{ .jump = o.imm },
        .cbz_x => if (r[o.n] == 0) return .{ .jump = o.imm },
        .cbz_w => if (w32(r[o.n]) == 0) return .{ .jump = o.imm },
        .cbnz_x => if (r[o.n] != 0) return .{ .jump = o.imm },
        .cbnz_w => if (w32(r[o.n]) != 0) return .{ .jump = o.imm },
        .tbz => if ((r[o.n] >> @intCast(o.sh)) & 1 == 0) return .{ .jump = o.imm },
        .tbnz => if ((r[o.n] >> @intCast(o.sh)) & 1 == 1) return .{ .jump = o.imm },
        .br => return .{ .jump = r[o.n] },
        .blr => {
            const t = r[o.n];
            r[30] = pc + 4;
            return .{ .jump = t };
        },
        .ret => return .{ .jump = r[o.n] },
        .svc => {
            cpu.pc = pc + 4;
            cpu.monitor = null;
            return .{ .exit = .syscall };
        },
        .brk => {
            cpu.pc = pc;
            return .{ .exit = .{ .fault = .{ .addr = pc, .access = .exec, .esr = (EC_BRK << 26) | (1 << 25) | o.imm } } };
        },
        .nop => if (o.a == 1) {
            cpu.monitor = null;
        },
        .fence => _ = @atomicRmw(u32, &fence_word, .Add, 0, .seq_cst),
        .mrs => r[o.d] = switch (o.imm) {
            sr(3, 3, 4, 2, 0) => cpu.nzcv,
            sr(3, 3, 4, 4, 0) => cpu.fpcr,
            sr(3, 3, 4, 4, 1) => cpu.fpsr,
            sr(3, 3, 13, 0, 2) => cpu.tpidr,
            sr(3, 3, 14, 0, 0) => 24_000_000,
            sr(3, 3, 14, 0, 1) => if (mach.deterministic) cpu.retired else if (mach.clock) |c| c.now(c.ctx) else 0,
            sr(3, 3, 0, 0, 1) => 0x8444c004, // CTR_EL0: 64-byte lines
            sr(3, 3, 0, 0, 7) => 4, // DCZID_EL0: 64-byte blocks, DC ZVA allowed
            else => 0,
        },
        .msr => switch (o.imm) {
            sr(3, 3, 4, 2, 0) => cpu.nzcv = @truncate(r[o.n] & 0xf0000000),
            // FPCR: AHP DN FZ RMode; the trap enables are RAZ/WI, as on
            // cores without FP trapping (Apple's).
            sr(3, 3, 4, 4, 0) => cpu.fpcr = @truncate(r[o.n] & 0x07c00000),
            sr(3, 3, 4, 4, 1) => cpu.fpsr = @truncate(r[o.n] & 0xf800009f),
            sr(3, 3, 13, 0, 2) => cpu.tpidr = r[o.n],
            else => {},
        },
        .dc_zva => {
            const a = r[o.n] & ~@as(u64, 63);
            var j: u64 = 0;
            while (j < 64) : (j += 8) if (!mem.write(u64, a + j, 0)) return dataFault(cpu, mem, pc, a + j, .write);
        },
        .ldp_x, .ldp_w, .ldpsw, .stp_x, .stp_w, .ldp_d, .stp_d, .ldp_q, .stp_q => {
            const T = switch (k) {
                .ldp_x, .stp_x, .ldp_d, .stp_d => u64,
                .ldp_q, .stp_q => u128,
                else => u32,
            };
            const fp = k == .ldp_d or k == .stp_d or k == .ldp_q or k == .stp_q;
            const store = k == .stp_x or k == .stp_w or k == .stp_d or k == .stp_q;
            const n = @sizeOf(T);
            const addr = if (o.x == 1) r[o.n] else r[o.n] +% o.imm;
            if (store) {
                const v1: T = if (fp) @truncate(cpu.v[o.d]) else @truncate(r[o.d]);
                const v2: T = if (fp) @truncate(cpu.v[o.m]) else @truncate(r[o.m]);
                if (!mem.write(T, addr, v1)) return dataFault(cpu, mem, pc, addr, .write);
                if (!mem.write(T, addr + n, v2)) return dataFault(cpu, mem, pc, addr + n, .write);
            } else {
                const v1 = mem.read(T, addr) orelse return dataFault(cpu, mem, pc, addr, .read);
                const v2 = mem.read(T, addr + n) orelse return dataFault(cpu, mem, pc, addr + n, .read);
                if (fp) {
                    cpu.v[o.d] = v1;
                    cpu.v[o.m] = v2;
                } else if (k == .ldpsw) {
                    r[o.d] = @bitCast(@as(i64, @as(i32, @bitCast(@as(u32, @truncate(v1))))));
                    r[o.m] = @bitCast(@as(i64, @as(i32, @bitCast(@as(u32, @truncate(v2))))));
                } else {
                    r[o.d] = v1;
                    r[o.m] = v2;
                }
            }
            if (o.x != 2) r[o.n] = r[o.n] +% o.imm;
            r[ZR] = 0;
        },
        // Exclusives, as QEMU does them: LDXR records the address, size
        // and value; STXR succeeds only if they match, as a CAS of that
        // value. Admits ABA.
        .ldxr_x, .ldxr_w, .ldxr_h, .ldxr_b, .ldar_x, .ldar_w => {
            const T = switch (k) {
                .ldxr_x, .ldar_x => u64,
                .ldxr_w, .ldar_w => u32,
                .ldxr_h => u16,
                else => u8,
            };
            const addr = r[o.n];
            if (addr % @sizeOf(T) != 0) {
                cpu.pc = pc;
                return .{ .exit = .{ .fault = .{ .addr = addr, .access = .read, .esr = (EC_DABT_LOWER << 26) | (1 << 25) | FSC_ALIGNMENT } } };
            }
            const p = mem.ptr(addr, @sizeOf(T), .read) orelse return dataFault(cpu, mem, pc, addr, .read);
            const v = if (@sizeOf(T) <= max_atomic) @atomicLoad(T, @as(*T, @ptrCast(@alignCast(p))), .seq_cst) else std.mem.readInt(T, p[0..@sizeOf(T)], .little);
            if (k == .ldxr_x or k == .ldxr_w or k == .ldxr_h or k == .ldxr_b) cpu.monitor = .{ .addr = addr, .size = @sizeOf(T), .value = v };
            r[o.d] = v;
            r[ZR] = 0;
        },
        .stxr_x, .stxr_w, .stxr_h, .stxr_b => {
            const T = switch (k) {
                .stxr_x => u64,
                .stxr_w => u32,
                .stxr_h => u16,
                else => u8,
            };
            const addr = r[o.n];
            if (addr % @sizeOf(T) != 0) {
                cpu.pc = pc;
                return .{ .exit = .{ .fault = .{ .addr = addr, .access = .write, .esr = (EC_DABT_LOWER << 26) | (1 << 25) | (1 << 6) | FSC_ALIGNMENT } } };
            }
            const p = mem.ptr(addr, @sizeOf(T), .write) orelse return dataFault(cpu, mem, pc, addr, .write);
            var status: u64 = 1;
            if (cpu.monitor) |mon| {
                if (mon.addr == addr and mon.size == @sizeOf(T)) {
                    const old: T = @truncate(mon.value);
                    if (@sizeOf(T) <= max_atomic) {
                        if (@cmpxchgStrong(T, @as(*T, @ptrCast(@alignCast(p))), old, @truncate(r[o.m]), .seq_cst, .seq_cst) == null) status = 0;
                    } else if (std.mem.readInt(T, p[0..@sizeOf(T)], .little) == old) {
                        std.mem.writeInt(T, p[0..@sizeOf(T)], @truncate(r[o.m]), .little);
                        status = 0;
                    }
                }
            }
            cpu.monitor = null;
            r[o.d] = status;
            r[ZR] = 0;
        },
        .stlr_x, .stlr_w => {
            const addr = r[o.n];
            const T = if (k == .stlr_x) u64 else u32;
            if (addr % @sizeOf(T) != 0) return dataFault(cpu, mem, pc, addr, .write);
            const p = mem.ptr(addr, @sizeOf(T), .write) orelse return dataFault(cpu, mem, pc, addr, .write);
            if (@sizeOf(T) <= max_atomic) @atomicStore(T, @as(*T, @ptrCast(@alignCast(p))), @truncate(r[o.m]), .seq_cst) else std.mem.writeInt(T, p[0..@sizeOf(T)], @truncate(r[o.m]), .little);
        },
        .fadd_s, .fsub_s, .fmul_s, .fdiv_s, .fnmul_s => {
            const op = switch (k) {
                .fadd_s => '+',
                .fsub_s => '-',
                .fdiv_s => '/',
                else => '*',
            };
            var res = fop2(f32, cpu, @truncate(cpu.v[o.n]), @truncate(cpu.v[o.m]), op);
            if (k == .fnmul_s and !std.math.isNan(@as(f32, @bitCast(res)))) res ^= 0x80000000;
            cpu.v[o.d] = res;
        },
        .fadd_d, .fsub_d, .fmul_d, .fdiv_d, .fnmul_d => {
            const op = switch (k) {
                .fadd_d => '+',
                .fsub_d => '-',
                .fdiv_d => '/',
                else => '*',
            };
            var res = fop2(f64, cpu, @truncate(cpu.v[o.n]), @truncate(cpu.v[o.m]), op);
            if (k == .fnmul_d and !std.math.isNan(@as(f64, @bitCast(res)))) res ^= 0x8000000000000000;
            cpu.v[o.d] = res;
        },
        .fmov_s => cpu.v[o.d] = @as(u32, @truncate(cpu.v[o.n])),
        .fmov_d => cpu.v[o.d] = @as(u64, @truncate(cpu.v[o.n])),
        .fabs_s => cpu.v[o.d] = @as(u32, @truncate(cpu.v[o.n])) & 0x7fffffff,
        .fabs_d => cpu.v[o.d] = @as(u64, @truncate(cpu.v[o.n])) & 0x7fffffffffffffff,
        .fneg_s => cpu.v[o.d] = @as(u32, @truncate(cpu.v[o.n])) ^ 0x80000000,
        .fneg_d => cpu.v[o.d] = @as(u64, @truncate(cpu.v[o.n])) ^ 0x8000000000000000,
        .fsqrt_s => cpu.v[o.d] = fsqrt(f32, cpu, @truncate(cpu.v[o.n])),
        .fsqrt_d => cpu.v[o.d] = fsqrt(f64, cpu, @truncate(cpu.v[o.n])),
        .fcvt_sd => {
            const b: u32 = @truncate(cpu.v[o.n]);
            const f: f32 = @bitCast(b);
            if (f != f) {
                if (isSnan(f32, b)) cpu.fpsr |= 1;
                const sign: u64 = b >> 31;
                const payload: u64 = b & 0x003fffff;
                cpu.v[o.d] = if (cpu.fpcr & (1 << 25) != 0) defaultNan(f64) else (sign << 63) | 0x7ff8000000000000 | (payload << 29);
            } else cpu.v[o.d] = @as(u64, @bitCast(@as(f64, f)));
        },
        .fcvt_ds => {
            const b: u64 = @truncate(cpu.v[o.n]);
            const f: f64 = @bitCast(b);
            if (f != f) {
                if (isSnan(f64, b)) cpu.fpsr |= 1;
                const sign: u32 = @intCast(b >> 63);
                const payload: u32 = @intCast((b >> 29) & 0x003fffff);
                cpu.v[o.d] = if (cpu.fpcr & (1 << 25) != 0) defaultNan(f32) else (sign << 31) | 0x7fc00000 | payload;
            } else cpu.v[o.d] = @as(u32, @bitCast(@as(f32, @floatCast(f))));
        },
        .frint_s => cpu.v[o.d] = @as(u32, @bitCast(frint(f32, @bitCast(@as(u32, @truncate(cpu.v[o.n]))), o.x, cpu.fpcr))),
        .frint_d => cpu.v[o.d] = @as(u64, @bitCast(frint(f64, @bitCast(@as(u64, @truncate(cpu.v[o.n]))), o.x, cpu.fpcr))),
        .fcmp_s => {
            const a: f32 = @bitCast(@as(u32, @truncate(cpu.v[o.n])));
            const b: f32 = if (o.a == 1) 0 else @bitCast(@as(u32, @truncate(cpu.v[o.m])));
            cpu.nzcv = fcmpFlags(f32, cpu, a, b, false);
        },
        .fcmp_d => {
            const a: f64 = @bitCast(@as(u64, @truncate(cpu.v[o.n])));
            const b: f64 = if (o.a == 1) 0 else @bitCast(@as(u64, @truncate(cpu.v[o.m])));
            cpu.nzcv = fcmpFlags(f64, cpu, a, b, false);
        },
        .fmovi_s, .fmovi_d => cpu.v[o.d] = o.imm,
        .scvtf => {
            const src = r[o.n];
            const unsigned = o.a == 1;
            const from_x = o.x & 1 == 1;
            const to_d = o.x & 2 != 0;
            // Conversions round to nearest on both hosts; FPCR.RMode isn't
            // honoured (the inventory found no code that sets it).
            if (to_d) {
                const f: f64 = if (unsigned) (if (from_x) @floatFromInt(src) else @floatFromInt(w32(src))) else (if (from_x) @floatFromInt(@as(i64, @bitCast(src))) else @floatFromInt(@as(i32, @bitCast(@as(u32, @truncate(src))))));
                cpu.v[o.d] = @as(u64, @bitCast(f));
            } else {
                const f: f32 = if (unsigned) (if (from_x) @floatFromInt(src) else @floatFromInt(w32(src))) else (if (from_x) @floatFromInt(@as(i64, @bitCast(src))) else @floatFromInt(@as(i32, @bitCast(@as(u32, @truncate(src))))));
                cpu.v[o.d] = @as(u32, @bitCast(f));
            }
        },
        .fcvtz => {
            const to_x = o.x & 1 == 1;
            const from_d = o.x & 2 != 0;
            const f: f64 = if (from_d) @bitCast(@as(u64, @truncate(cpu.v[o.n]))) else @as(f32, @bitCast(@as(u32, @truncate(cpu.v[o.n]))));
            r[o.d] = if (o.a == 1)
                (if (to_x) fcvtz(u64, f, cpu) else fcvtz(u32, f, cpu))
            else if (to_x) @bitCast(fcvtz(i64, f, cpu)) else @as(u32, @bitCast(fcvtz(i32, f, cpu)));
        },
        .fmov_to_gp => r[o.d] = if (o.x == 1) @as(u64, @truncate(cpu.v[o.n])) else @as(u32, @truncate(cpu.v[o.n])),
        .fmov_from_gp => cpu.v[o.d] = if (o.x == 1) r[o.n] else w32(r[o.n]),
        .fcsel_s => cpu.v[o.d] = @as(u32, @truncate(if (cond(cpu.nzcv, o.x)) cpu.v[o.n] else cpu.v[o.m])),
        .fcsel_d => cpu.v[o.d] = @as(u64, @truncate(if (cond(cpu.nzcv, o.x)) cpu.v[o.n] else cpu.v[o.m])),
        .fmadd_s, .fmadd_d => {
            const F = if (k == .fmadd_d) f64 else f32;
            const B = FBits(F);
            const a: F = @bitCast(@as(B, @truncate(cpu.v[o.x])));
            const n: F = @bitCast(@as(B, @truncate(cpu.v[o.n])));
            const m: F = @bitCast(@as(B, @truncate(cpu.v[o.m])));
            // Fused, as the architecture requires; NaN handling is approximate in this spike.
            const res: F = switch (o.a) {
                0 => @mulAdd(F, n, m, a),
                1 => @mulAdd(F, -n, m, a),
                2 => @mulAdd(F, -n, m, -a),
                else => @mulAdd(F, n, m, -a),
            };
            cpu.v[o.d] = if (res != res) defaultNan(F) else @as(B, @bitCast(res));
        },
        else => unreachable,
    }
    r[ZR] = 0;
    return .next;
}

/// Runs one decoded instruction at `pc`, for the JIT's `call.interp`.
pub fn step(cpu: *Cpu, mem: *Mem, o: *const Op, pc: u64) Next {
    cpu.r[ZR] = 0;
    var kicked = std.atomic.Value(bool).init(false);
    var cache: Cache = .{ .gpa = undefined };
    const mach: Machine = .{ .cpu = cpu, .mem = mem, .cache = &cache, .kicked = &kicked };
    return switch (o.k) {
        .undef, .next_page => .{ .exit = .{ .fault = .{ .addr = pc, .access = .exec, .esr = (EC_UNKNOWN << 26) | (1 << 25) } } },
        inline else => |k| exec(k, o, cpu, mem, &cpu.r, pc, mach),
    };
}
