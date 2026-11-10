//! h86's and hx64's decoder: prefixes, opcode, ModRM, SIB, displacement,
//! and immediates, up to the architectural limit of 15 bytes, into an
//! `Inst` (an `Inst64` in long mode, with REX and RIP-relative addressing)
//! that T0 executes and the lifter lowers. `effects` gives an
//! instruction's register, flag, and memory read and write sets, which
//! the lifter's liveness and flag analyses use.
//!
//! The decoder works on bytes the caller fetched. It never touches guest
//! memory itself, so an instruction that runs off the end of the bytes
//! it was given (the next page is unmapped) says so with `Truncated`, and
//! the caller faults at the right address.

const std = @import("std");
const table = @import("table.zig");
const flags = @import("flags.zig");

pub const Op = table.Op;
pub const Opd = table.Opd;
pub const Mode = table.Mode;

/// Segment registers, in encoding order (`Cpu.seg`).
pub const Seg = enum(u3) { es, cs, ss, ds, fs, gs };

pub const Rep = enum(u2) { none, rep, repne };

/// No register: a missing base or index.
pub const no_reg: u4 = 8;

/// The longest instruction the CPU accepts.
pub const max_len = 15;

pub const Inst = struct {
    op: Op,
    /// The table entry (table.entryAt).
    entry: u16,
    /// 0x00-0xFF, or 0x0F00-0x0FFF.
    opcode: u16,
    len: u8,
    /// Operand size in bytes: 1, 2, or 4.
    size: u8,
    /// A 0x66 prefix: 16-bit operands, or SSE's 66 form.
    opsize: bool = false,
    /// A 0x67 prefix: 16-bit addressing.
    addr16: bool = false,
    lock: bool = false,
    /// The last of F2 and F3.
    rep: Rep = .none,
    /// The segment of the memory operand: DS or SS by default, or an
    /// override. Only FS and GS have a base.
    seg: Seg = .ds,
    modrm: u8 = 0,
    /// The ModRM r/m operand (or a moffs) is memory.
    mem: bool = false,
    base: u4 = no_reg,
    index: u4 = no_reg,
    scale: u2 = 0,
    disp: u32 = 0,
    /// The immediate: sign-extended for imm8 forms that are, otherwise as
    /// encoded. A relative branch's displacement, sign-extended.
    imm: u32 = 0,
    /// ENTER's nesting level, or a far pointer's selector.
    imm2: u16 = 0,

    pub inline fn tableEntry(i: *const Inst) *const table.Entry {
        return table.entryAt(i.entry);
    }
    pub inline fn reg(i: *const Inst) u3 {
        return @truncate(i.modrm >> 3);
    }
    pub inline fn rm(i: *const Inst) u3 {
        return @truncate(i.modrm);
    }
    /// The condition of a Jcc, SETcc, or CMOVcc.
    pub inline fn cc(i: *const Inst) u4 {
        return @truncate(i.opcode);
    }
    /// The register an `.Z` operand names.
    pub inline fn zreg(i: *const Inst) u3 {
        return @truncate(i.opcode);
    }
};

/// A REX prefix's bits (0100WRXB), and whether there was one.
pub const Rex = packed struct(u8) {
    /// Extends ModRM.rm, SIB.base, or the opcode's register.
    b: u1 = 0,
    /// Extends SIB.index.
    x: u1 = 0,
    /// Extends ModRM.reg.
    r: u1 = 0,
    /// A 64-bit operand size.
    w: u1 = 0,
    /// A REX prefix came right before the opcode: byte registers 4-7 are
    /// then SPL, BPL, SIL, and DIL, not AH, CH, DH, and BH.
    present: bool = false,
    _: u3 = 0,

    pub fn of(byte: u8) Rex {
        return .{ .b = @truncate(byte), .x = @truncate(byte >> 1), .r = @truncate(byte >> 2), .w = @truncate(byte >> 3), .present = true };
    }
};

/// No register in long mode: a missing base or index (RIP-relative
/// addressing has neither, and sets `Inst64.rip_rel`).
pub const no_reg64: u5 = 16;

/// A decoded long-mode instruction (hx64): `Inst` with REX, 64-bit
/// operands, and RIP-relative addressing. The field meanings are Inst's
/// but where they say otherwise.
pub const Inst64 = struct {
    op: Op,
    entry: u16,
    opcode: u16,
    len: u8,
    /// Operand size in bytes: 1, 2, 4, or 8 (REX.W, or a d64 entry's
    /// default).
    size: u8,
    /// A 0x66 prefix: 16-bit operands, or SSE's 66 form.
    opsize: bool = false,
    /// A 0x67 prefix: 32-bit addressing (the effective address is
    /// computed in 32 bits and zero-extended).
    addr32: bool = false,
    lock: bool = false,
    rep: Rep = .none,
    /// FS or GS for their bases; ES, CS, SS, and DS overrides are
    /// accepted and ignored, as long mode ignores them.
    seg: Seg = .ds,
    rex: Rex = .{},
    modrm: u8 = 0,
    mem: bool = false,
    /// The address is the next instruction's RIP plus `disp` (ModRM mod 0,
    /// r/m 5, with no SIB).
    rip_rel: bool = false,
    /// Registers 0-15, or no_reg64.
    base: u5 = no_reg64,
    index: u5 = no_reg64,
    scale: u2 = 0,
    /// Sign-extended to 64 bits; a moffs (A0-A3) is 8 bytes, whole.
    disp: u64 = 0,
    /// As Inst.imm, extended to 64 bits; MOV r64, imm64's whole.
    imm: u64 = 0,
    /// ENTER's nesting level.
    imm2: u16 = 0,

    pub inline fn tableEntry(i: *const Inst64) *const table.Entry {
        return table.entryAt(i.entry);
    }
    /// ModRM.reg, with REX.R.
    pub inline fn reg(i: *const Inst64) u4 {
        return @as(u4, i.rex.r) << 3 | @as(u3, @truncate(i.modrm >> 3));
    }
    /// ModRM.rm as a register, with REX.B.
    pub inline fn rm(i: *const Inst64) u4 {
        return @as(u4, i.rex.b) << 3 | @as(u3, @truncate(i.modrm));
    }
    /// The condition of a Jcc, SETcc, or CMOVcc.
    pub inline fn cc(i: *const Inst64) u4 {
        return @truncate(i.opcode);
    }
    /// The register an `.Z` operand names, with REX.B.
    pub inline fn zreg(i: *const Inst64) u4 {
        return @as(u4, i.rex.b) << 3 | @as(u3, @truncate(i.opcode));
    }
};

/// The decoded instruction of `mode`.
pub fn InstOf(comptime mode: Mode) type {
    return switch (mode) {
        .legacy => Inst,
        .long => Inst64,
    };
}

pub const Error = error{
    /// The bytes ran out before the instruction did.
    Truncated,
    /// Longer than 15 bytes: #GP.
    TooLong,
};

/// Decodes the instruction at the start of `code`, which holds up to 15
/// bytes (fewer if the next page can't be read).
pub fn decode(code: []const u8) Error!Inst {
    var p: usize = 0;
    var opsize = false;
    var addr16 = false;
    var lock = false;
    var rep: Rep = .none;
    var seg: ?Seg = null;
    const n = @min(code.len, max_len);
    const b0 = while (true) {
        if (p >= n) return if (n == max_len) error.TooLong else error.Truncated;
        const b = code[p];
        switch (b) {
            0x26 => seg = .es,
            0x2e => seg = .cs,
            0x36 => seg = .ss,
            0x3e => seg = .ds,
            0x64 => seg = .fs,
            0x65 => seg = .gs,
            0x66 => opsize = true,
            0x67 => addr16 = true,
            0xf0 => lock = true,
            0xf2 => rep = .repne,
            0xf3 => rep = .rep,
            else => break b,
        }
        p += 1;
    };
    p += 1;
    var opcode: u16 = b0;
    if (b0 == 0x0f) {
        if (p >= n) return if (n == max_len) error.TooLong else error.Truncated;
        opcode = 0x0f00 | @as(u16, code[p]);
        p += 1;
    }
    const s = table.slot(opcode);
    var modrm: u8 = 0;
    if (s.modrm) {
        if (p >= n) return if (n == max_len) error.TooLong else error.Truncated;
        modrm = code[p];
        p += 1;
    }
    const e = table.entry(s, modrm);
    var i: Inst = .{
        .op = e.op,
        .entry = table.entryIndex(e),
        .opcode = opcode,
        .len = 0,
        .size = switch (e.size) {
            .b => 1,
            .v => if (opsize) 2 else 4,
            .w => 2,
            .d => 4,
        },
        .opsize = opsize,
        .addr16 = addr16,
        .lock = lock,
        .rep = rep,
        .modrm = modrm,
    };
    const R = struct {
        code: []const u8,
        n: usize,
        p: *usize,
        fn get(r: @This(), comptime T: type) Error!T {
            const k = @sizeOf(T);
            if (r.p.* + k > r.n) return if (r.n == max_len) error.TooLong else error.Truncated;
            const v = std.mem.readInt(T, r.code[r.p.*..][0..k], .little);
            r.p.* += k;
            return v;
        }
    };
    const rd: R = .{ .code = code, .n = n, .p = &p };
    var default_ss = false;
    if (s.modrm and modrm < 0xc0) {
        i.mem = true;
        const mod: u2 = @truncate(modrm >> 6);
        const rmf: u3 = @truncate(modrm);
        if (addr16) {
            const bases = [8]u4{ 3, 3, 5, 5, 6, 7, 5, 3 };
            const idxs = [8]u4{ 6, 7, 6, 7, no_reg, no_reg, no_reg, no_reg };
            i.base = bases[rmf];
            i.index = idxs[rmf];
            if (mod == 0 and rmf == 6) {
                i.base = no_reg;
                i.disp = try rd.get(u16);
            }
            default_ss = i.base == 5;
            switch (mod) {
                1 => i.disp = @bitCast(@as(i32, try rd.get(i8))),
                2 => i.disp = try rd.get(u16),
                else => {},
            }
        } else {
            if (rmf == 4) {
                const sib = try rd.get(u8);
                i.scale = @truncate(sib >> 6);
                const idx: u3 = @truncate(sib >> 3);
                const base: u3 = @truncate(sib);
                if (idx != 4) i.index = idx;
                if (base == 5 and mod == 0) {
                    i.disp = try rd.get(u32);
                } else i.base = base;
            } else if (rmf == 5 and mod == 0) {
                i.disp = try rd.get(u32);
            } else i.base = rmf;
            default_ss = i.base == 4 or i.base == 5;
            switch (mod) {
                1 => i.disp = @bitCast(@as(i32, try rd.get(i8))),
                2 => i.disp = try rd.get(u32),
                else => {},
            }
        }
    }
    if (e.src == .O or e.dst == .O) {
        i.mem = true;
        i.disp = if (addr16) try rd.get(u16) else try rd.get(u32);
    }
    i.seg = seg orelse if (default_ss) .ss else .ds;
    switch (e.imm) {
        .none => {},
        .b => i.imm = try rd.get(u8),
        .bs => i.imm = @bitCast(@as(i32, try rd.get(i8))),
        .v => i.imm = if (opsize) try rd.get(u16) else try rd.get(u32),
        .w => i.imm = try rd.get(u16),
        .wb => {
            i.imm = try rd.get(u16);
            i.imm2 = try rd.get(u8);
        },
        .ptr => {
            i.imm = if (opsize) try rd.get(u16) else try rd.get(u32);
            i.imm2 = try rd.get(u16);
        },
    }
    // A relative branch's 16-bit displacement is signed.
    if (e.imm == .v and opsize and (e.op == .jmp or e.op == .call or e.op == .jcc)) {
        i.imm = @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(i.imm))))));
    }
    i.len = @intCast(p);
    return i;
}

/// Decodes the instruction at the start of `code` in `mode`.
pub fn decodeIn(comptime mode: Mode, code: []const u8) Error!InstOf(mode) {
    return switch (mode) {
        .legacy => decode(code),
        .long => decode64(code),
    };
}

/// Whether `op` is a near branch: in long mode, always 64-bit.
fn nearBranch(op: Op) bool {
    return switch (op) {
        .jcc, .jmp, .jmp_ind, .call, .call_ind, .ret, .loop, .loope, .loopne, .jcxz => true,
        else => false,
    };
}

/// Decodes the long-mode instruction at the start of `code`, which holds
/// up to 15 bytes. As `decode`, with these differences:
///
/// - 40-4F are REX prefixes. A REX counts only right before the opcode:
///   a legacy prefix after it cancels it, and of several the last counts.
/// - REX.W makes the operand size 8, over 66. A `d64` entry's size is 8,
///   or 2 with 66; a near branch's is always 8, and its displacement
///   32 bits, as Intel's CPUs ignore 66 there. A `.d` entry (BSWAP,
///   CMPXCHG8B) is 8 under REX.W, so CMPXCHG16B is `.cmpxchg8b` with size
///   8, each half's.
/// - Addresses are 64 bits; 67 makes them 32 (`addr32`). ModRM mod 0 r/m
///   5 is RIP-relative (`rip_rel`), with or without SIB's base 5, and
///   REX.B doesn't change which forms take a SIB or a bare disp32.
/// - Only FS and GS overrides count, the last of them: ES, CS, SS, and
///   DS prefixes are ignored, even after FS or GS, as on Intel's CPUs.
/// - `imm` is sign-extended to 64 bits for an imm8s, at operand size 8,
///   and for a branch; otherwise it's as encoded. MOV r64, imm64 (B8+r
///   under REX.W) has all 8 bytes, and a moffs (A0-A3) is 8 bytes, or 4
///   under 67, in `disp`.
/// - 90 under REX.B is XCHG r8, rAX: the 91-97 entry, with opcode 0x90.
fn decode64(code: []const u8) Error!Inst64 {
    var p: usize = 0;
    var opsize = false;
    var addr32 = false;
    var lock = false;
    var rep: Rep = .none;
    var seg: Seg = .ds;
    var rex: Rex = .{};
    const n = @min(code.len, max_len);
    const short: Error = if (n == max_len) error.TooLong else error.Truncated;
    const b0 = while (true) {
        if (p >= n) return short;
        const b = code[p];
        p += 1;
        switch (b) {
            0x40...0x4f => {
                rex = Rex.of(b);
                continue;
            },
            0x26, 0x2e, 0x36, 0x3e => {},
            0x64 => seg = .fs,
            0x65 => seg = .gs,
            0x66 => opsize = true,
            0x67 => addr32 = true,
            0xf0 => lock = true,
            0xf2 => rep = .repne,
            0xf3 => rep = .rep,
            else => break b,
        }
        rex = .{};
    };
    var opcode: u16 = b0;
    if (b0 == 0x0f) {
        if (p >= n) return short;
        opcode = 0x0f00 | @as(u16, code[p]);
        p += 1;
    }
    const s = table.slotIn(.long, opcode);
    var modrm: u8 = 0;
    if (s.modrm) {
        if (p >= n) return short;
        modrm = code[p];
        p += 1;
    }
    var e = table.entry(s, modrm);
    if (opcode == 0x90 and rex.b == 1) e = table.entry(table.slotIn(.long, 0x91), 0);
    const w = rex.w == 1;
    const size: u8 = switch (e.size) {
        .b => 1,
        .v => if (nearBranch(e.op)) 8 else if (w) 8 else if (opsize) 2 else if (e.d64) 8 else 4,
        .w => 2,
        .d => if (w) 8 else 4,
    };
    var i: Inst64 = .{
        .op = e.op,
        .entry = table.entryIndex(e),
        .opcode = opcode,
        .len = 0,
        .size = size,
        .opsize = opsize,
        .addr32 = addr32,
        .lock = lock,
        .rep = rep,
        .seg = seg,
        .rex = rex,
        .modrm = modrm,
    };
    const R = struct {
        code: []const u8,
        n: usize,
        p: *usize,
        fn get(r: @This(), comptime T: type) Error!T {
            const k = @sizeOf(T);
            if (r.p.* + k > r.n) return if (r.n == max_len) error.TooLong else error.Truncated;
            const v = std.mem.readInt(T, r.code[r.p.*..][0..k], .little);
            r.p.* += k;
            return v;
        }
        fn sext(r: @This(), comptime T: type) Error!u64 {
            const S = std.meta.Int(.signed, @bitSizeOf(T));
            return @bitCast(@as(i64, @as(S, @bitCast(try r.get(T)))));
        }
    };
    const rd: R = .{ .code = code, .n = n, .p = &p };
    if (s.modrm and modrm < 0xc0) {
        i.mem = true;
        const mod: u2 = @truncate(modrm >> 6);
        const rmf: u3 = @truncate(modrm);
        if (rmf == 4) {
            const sib = try rd.get(u8);
            i.scale = @truncate(sib >> 6);
            const idx: u5 = @as(u5, rex.x) << 3 | @as(u3, @truncate(sib >> 3));
            const base: u3 = @truncate(sib);
            // Index 4 is none, but with REX.X it's R12.
            if (idx != 4) i.index = idx;
            if (base == 5 and mod == 0) {
                i.disp = try rd.sext(u32);
            } else i.base = @as(u5, rex.b) << 3 | base;
        } else if (rmf == 5 and mod == 0) {
            i.rip_rel = true;
            i.disp = try rd.sext(u32);
        } else i.base = @as(u5, rex.b) << 3 | rmf;
        switch (mod) {
            1 => i.disp = try rd.sext(u8),
            2 => i.disp = try rd.sext(u32),
            else => {},
        }
    }
    if (e.src == .O or e.dst == .O) {
        i.mem = true;
        i.disp = if (addr32) try rd.get(u32) else try rd.get(u64);
    }
    switch (e.imm) {
        .none => {},
        .b => i.imm = try rd.get(u8),
        .bs => i.imm = try rd.sext(u8),
        .v => i.imm = if (e.rexw and w and e.dst == .Z)
            try rd.get(u64)
        else switch (size) {
            2 => try rd.get(u16),
            8 => try rd.sext(u32),
            else => try rd.get(u32),
        },
        .w => i.imm = try rd.get(u16),
        .wb => {
            i.imm = try rd.get(u16);
            i.imm2 = try rd.get(u8);
        },
        // Far pointers are #UD in long mode (inv64), so never looked up.
        .ptr => unreachable,
    }
    i.len = @intCast(p);
    return i;
}

/// What an instruction of `mode` reads and writes.
pub fn EffectsOf(comptime mode: Mode) type {
    return struct {
        /// A set of general registers, as bits in encoding order
        /// (table.eax...): EAX to EDI, or RAX to R15 in long mode.
        pub const Regs = switch (mode) {
            .legacy => u8,
            .long => u16,
        };
        /// General registers. A write of part of a register (8 or 16
        /// bits) also reads it; in long mode a 32-bit write is whole, as
        /// it zero-extends.
        regs_read: Regs = 0,
        regs_written: Regs = 0,
        /// EFLAGS bits read, and written. A flag written only sometimes (a
        /// shift by CL, which may be 0) is in both.
        flags_read: u32 = 0,
        flags_written: u32 = 0,
        /// Flags the architecture leaves undefined, among those written.
        flags_undefined: u32 = 0,
        mem_read: bool = false,
        mem_write: bool = false,
        /// FS or GS: reads a segment base.
        seg_base: bool = false,
    };
}

/// What a 386 instruction reads and writes.
pub const Effects = EffectsOf(.legacy);

const RW = enum { none, r, w, rw };

/// How an operation treats its destination operand.
fn dstAccess(op: Op) RW {
    return switch (op) {
        .mov, .movzx, .movsx, .lea, .setcc, .pop, .lseg, .mov_from_sreg, .mov_sreg => .w,
        .cmp, .@"test", .bt, .bound => .r,
        .mul, .imul1, .div, .idiv, .push, .jmp_ind, .call_ind => .none,
        // CMOVcc writes its destination only when the condition holds.
        else => .rw,
    };
}

fn ModeOf(comptime I: type) Mode {
    return if (I == Inst64) .long else .legacy;
}

/// A register's bit, or none for no_reg (no_reg64).
fn regBit(comptime mode: Mode, r: anytype) EffectsOf(mode).Regs {
    const none = if (mode == .long) no_reg64 else no_reg;
    return if (r == none) 0 else @as(EffectsOf(mode).Regs, 1) << @intCast(r);
}

/// The register an operand of `size` bytes numbered `n` lives in: AH, CH,
/// DH, and BH are parts of EAX to EBX, but with a REX prefix registers 4
/// to 7 are SPL, BPL, SIL, and DIL.
fn sizedReg(i: anytype, n: anytype, size: u8) EffectsOf(ModeOf(@TypeOf(i.*))).Regs {
    const mode = comptime ModeOf(@TypeOf(i.*));
    const high = size == 1 and n >= 4 and n < 8 and (mode == .legacy or !i.rex.present);
    return regBit(mode, if (high) n & 3 else n);
}

/// The register, flag, and memory effects of `i`.
pub fn effects(i: *const Inst) Effects {
    return effectsIn(.legacy, i);
}

/// The register, flag, and memory effects of `i`, in `mode`.
pub fn effectsIn(comptime mode: Mode, i: *const InstOf(mode)) EffectsOf(mode) {
    const long = mode == .long;
    const Regs = EffectsOf(mode).Regs;
    const e = i.tableEntry();
    var x: EffectsOf(mode) = .{};
    x.regs_read = e.ir;
    x.regs_written = e.iw;
    const src_size: u8 = switch (i.op) {
        .movzx, .movsx => switch (e.src_size) {
            .b => 1,
            .w => 2,
            // MOVSXD: a 16- or 32-bit source, as the operand size.
            else => @min(i.size, 4),
        },
        else => i.size,
    };
    // Address registers.
    if (i.mem) {
        x.regs_read |= regBit(mode, i.base) | regBit(mode, i.index);
        x.seg_base = i.seg == .fs or i.seg == .gs;
    }
    const da = dstAccess(i.op);
    const opd = struct {
        fn reg(ii: *const InstOf(mode), o: Opd, size: u8) Regs {
            return switch (o) {
                .E => if (ii.mem) 0 else sizedReg(ii, ii.rm(), size),
                .G => sizedReg(ii, ii.reg(), size),
                .A => table.eax,
                .Z => sizedReg(ii, ii.zreg(), size),
                .CL => table.ecx,
                else => 0,
            };
        }
    };
    const dreg = opd.reg(i, e.dst, i.size);
    const sreg = opd.reg(i, e.src, src_size);
    if (i.op != .lea) x.regs_read |= sreg;
    if (i.op == .xchg or i.op == .xadd) x.regs_written |= sreg;
    if (i.op == .cmpxchg and !i.mem) x.regs_written |= table.eax;
    if (da == .r or da == .rw) x.regs_read |= dreg;
    if (da == .w or da == .rw) x.regs_written |= dreg;
    const dmem = (e.dst == .E or e.dst == .O) and i.mem;
    const smem = (e.src == .E or e.src == .O) and i.mem and i.op != .lea;
    if (dmem and (da == .r or da == .rw)) x.mem_read = true;
    if (dmem and (da == .w or da == .rw)) x.mem_write = true;
    if (smem) x.mem_read = true;
    // A partial register write merges with what was there. In long mode
    // a 32-bit write zero-extends, so only 8 and 16 bits are partial.
    if (long) {
        if (i.size < 4 or src_size < 4) x.regs_read |= x.regs_written & ~(if (i.size >= 4) dreg else 0);
    } else {
        if (i.size != 4 or src_size != 4) x.regs_read |= x.regs_written & ~(if (i.size == 4) dreg else 0);
    }
    switch (i.op) {
        .push, .push_sreg, .pusha, .pushf, .call, .call_ind => x.mem_write = true,
        .pop, .pop_sreg, .popa, .popf, .ret, .bound, .lseg, .xlat => x.mem_read = true,
        .leave => x.mem_read = true,
        .enter => {
            x.mem_write = true;
            if (i.imm2 & 31 > 1) x.mem_read = true;
        },
        .movs => {
            x.mem_read = true;
            x.mem_write = true;
        },
        .cmps, .lods, .scas => x.mem_read = true,
        .stos => x.mem_write = true,
        // The kernel may read any register, and SYSCALL keeps RFLAGS in
        // R11 and the return address in RCX.
        .syscall => if (long) {
            x.regs_read = ~@as(Regs, 0);
            x.regs_written |= 1 << 11;
            x.flags_read = flags.arith | flags.DF | flags.AC | flags.ID;
        },
        .cmpxchg8b => {
            x.mem_read = true;
            x.mem_write = true;
        },
        .loop, .loope, .loopne, .jcxz => {},
        else => {},
    }
    // String operations without REP leave ECX alone.
    switch (i.op) {
        .movs, .cmps, .stos, .lods, .scas => if (i.rep == .none) {
            x.regs_read &= ~@as(Regs, table.ecx);
            x.regs_written &= ~@as(Regs, table.ecx);
        },
        else => {},
    }
    // 16-bit string and loop forms use SI, DI, and CX: still partial
    // writes. (Long mode's 32-bit forms zero-extend.)
    if (!long and i.addr16) x.regs_read |= x.regs_written & (table.esi | table.edi | table.ecx);
    // A shift or rotate count is masked to 6 bits at 64, else to 5.
    const cmask: u64 = if (i.size == 8) 63 else 31;
    const A = flags.arith;
    const CF = flags.CF;
    switch (i.op) {
        .add, .@"or", .sub, .xor, .@"and", .cmp, .@"test", .neg, .cmpxchg, .xadd => x.flags_written = A,
        .adc, .sbb => {
            x.flags_written = A;
            x.flags_read = CF;
        },
        .inc, .dec => x.flags_written = A & ~CF,
        .mul, .imul1, .imul => {
            x.flags_written = A;
            x.flags_undefined = flags.SF | flags.ZF | flags.AF | flags.PF;
        },
        .shl, .shr, .sar, .shld, .shrd => {
            const count: u64 = if (e.src == .one) 1 else if (e.src == .I or e.imm == .b) i.imm & cmask else 0xff;
            if (count != 0) x.flags_written = A;
            if (count == 0xff) x.flags_read |= A;
            x.flags_undefined = flags.AF | (if (count != 1) flags.OF else 0);
        },
        .rol, .ror, .rcl, .rcr => {
            const count: u64 = if (e.src == .one) 1 else if (e.src == .I) i.imm & cmask else 0xff;
            if (count != 0) x.flags_written = CF | flags.OF;
            if (count == 0xff) x.flags_read |= CF | flags.OF;
            if (i.op == .rcl or i.op == .rcr) x.flags_read |= CF;
            if (count != 1) x.flags_undefined = flags.OF;
        },
        .bt, .bts, .btr, .btc => {
            x.flags_written = CF;
        },
        .bsf, .bsr => {
            x.flags_written = A;
            x.flags_undefined = A & ~flags.ZF;
        },
        .cmpxchg8b => x.flags_written = flags.ZF,
        .jcc, .setcc, .cmovcc => x.flags_read = flags.condReads(i.cc()),
        .loope, .loopne => x.flags_read = flags.ZF,
        .lahf => x.flags_read = A & ~flags.OF,
        .sahf => x.flags_written = A & ~flags.OF,
        .clc, .stc => x.flags_written = CF,
        .cmc => {
            x.flags_read = CF;
            x.flags_written = CF;
        },
        .salc => x.flags_read = CF,
        .into => x.flags_read = flags.OF,
        .cld, .std => x.flags_written = flags.DF,
        .pushf => x.flags_read = A | flags.DF | flags.AC | flags.ID,
        .popf => x.flags_written = A | flags.DF | flags.AC | flags.ID,
        .movs, .stos, .lods => x.flags_read = flags.DF,
        .cmps, .scas => {
            x.flags_read = flags.DF;
            x.flags_written = A;
        },
        .daa, .das => {
            x.flags_read = CF | flags.AF;
            x.flags_written = A;
            x.flags_undefined = flags.OF;
        },
        .aaa, .aas => {
            x.flags_read = flags.AF;
            x.flags_written = A;
            x.flags_undefined = flags.OF | flags.SF | flags.ZF | flags.PF;
        },
        .aam, .aad => {
            x.flags_written = A;
            x.flags_undefined = flags.OF | flags.AF | CF;
        },
        .x87 => {
            // FCMOVcc reads CF, ZF, and PF; FCOMI and FUCOMI (and their
            // popping forms) write ZF, PF, and CF and clear the rest.
            if (!i.mem) {
                const rg: u3 = @truncate(i.modrm >> 3);
                if ((i.opcode == 0xda or i.opcode == 0xdb) and rg <= 3) x.flags_read = CF | flags.ZF | flags.PF;
                if ((i.opcode == 0xdb or i.opcode == 0xdf) and (rg == 5 or rg == 6)) x.flags_written = A;
            }
            x87Effects(i, &x);
        },
        .sse => {
            // COMISS, UCOMISS, and their SD forms.
            if (i.opcode == 0x0f2e or i.opcode == 0x0f2f) x.flags_written = A;
            sseEffects(i, &x);
        },
        else => {},
    }
    return x;
}

/// x87 memory operands, and FNSTSW AX.
fn x87Effects(i: anytype, x: anytype) void {
    const rg: u3 = @truncate(i.modrm >> 3);
    if (!i.mem) {
        // FNSTSW AX: a 16-bit write, so it reads EAX too.
        if (i.opcode == 0xdf and i.modrm == 0xe0) {
            x.regs_read |= table.eax;
            x.regs_written |= table.eax;
        }
        return;
    }
    // Stores: FST, FSTP, FNSTENV, and FNSTCW (D9 /2 /3 /6 /7); FISTTP,
    // FIST, FISTP, and FSTP m80 (DB /1 /2 /3 /7); FISTTP, FST, FSTP,
    // FNSAVE, and FNSTSW (DD /1 /2 /3 /6 /7); FISTTP, FIST, FISTP,
    // FBSTP, and FISTP m64 (DF /1 /2 /3 /6 /7). The rest load.
    const store = switch (i.opcode) {
        0xd9 => rg == 2 or rg == 3 or rg >= 6,
        0xdb => rg >= 1 and rg <= 3 or rg == 7,
        0xdd, 0xdf => rg >= 1 and rg <= 3 or rg >= 6,
        else => false,
    };
    if (store) x.mem_write = true else x.mem_read = true;
}

/// MMX, SSE, and SSE2: the general registers some forms move to or from,
/// and their memory operands. F3 and F2 take precedence over 66, as in
/// sse.zig.
fn sseEffects(i: anytype, x: anytype) void {
    const mode = comptime ModeOf(@TypeOf(i.*));
    const Pfx = enum { none, p66, f3, f2 };
    const p: Pfx = switch (i.rep) {
        .rep => .f3,
        .repne => .f2,
        .none => if (i.opsize) .p66 else .none,
    };
    const rm_gpr = if (i.mem) 0 else regBit(mode, i.rm());
    const reg_gpr = regBit(mode, i.reg());
    const op: u8 = @truncate(i.opcode);
    switch (op) {
        // CVTSI2SS and CVTSI2SD.
        0x2a => if (p == .f3 or p == .f2) {
            x.regs_read |= rm_gpr;
        },
        // CVT(T)SS2SI and CVT(T)SD2SI.
        0x2c, 0x2d => if (p == .f3 or p == .f2) {
            x.regs_written |= reg_gpr;
        },
        // MOVMSKPS and MOVMSKPD, PEXTRW, and PMOVMSKB.
        0x50, 0xc5, 0xd7 => x.regs_written |= reg_gpr,
        // MOVD to MMX or XMM, and PINSRW.
        0x6e, 0xc4 => x.regs_read |= rm_gpr,
        // MOVD from MMX or XMM (F3 7E is MOVQ, XMM to XMM).
        0x7e => if (p != .f3) {
            x.regs_written |= rm_gpr;
        },
        // MOVNTI.
        0xc3 => x.regs_read |= reg_gpr,
        // MASKMOVQ and MASKMOVDQU: a store to EDI.
        0xf7 => {
            x.regs_read |= table.edi;
            x.mem_write = true;
            x.seg_base = i.seg == .fs or i.seg == .gs;
        },
        else => {},
    }
    if (!i.mem) return;
    const store = switch (op) {
        // MOVUPS/MOVSS and the rest at 11, MOVLPS, MOVHPS, MOVAPS,
        // MOVNTPS, MOVQ/MOVDQA/MOVDQU, MOVD, MOVNTI, MOVQ (66 D6),
        // MOVNTQ and MOVNTDQ.
        0x11, 0x13, 0x17, 0x29, 0x2b, 0x7f, 0xc3, 0xd6, 0xe7 => true,
        0x7e => p != .f3,
        // FXSAVE and STMXCSR.
        0xae => @as(u3, @truncate(i.modrm >> 3)) == 0 or @as(u3, @truncate(i.modrm >> 3)) == 3,
        else => false,
    };
    if (store) x.mem_write = true else x.mem_read = true;
}

test "Rex and Inst64's registers" {
    const r = Rex.of(0x4d);
    try std.testing.expect(r.present and r.w == 1 and r.r == 1 and r.x == 0 and r.b == 1);
    var j: Inst64 = .{ .op = .add, .entry = 0, .opcode = 0x01, .len = 3, .size = 8, .rex = r, .modrm = 0xc8 };
    try std.testing.expectEqual(@as(u4, 9), j.reg());
    try std.testing.expectEqual(@as(u4, 8), j.rm());
    j.opcode = 0xb9;
    try std.testing.expectEqual(@as(u4, 9), j.zreg());
    try std.testing.expectEqual(Op.add, (try decodeIn(.legacy, &.{ 0x01, 0xc0 })).op);
}

fn d64(bytes: []const u8) !Inst64 {
    return decodeIn(.long, bytes);
}

test "decode64: REX, operand sizes, and registers" {
    const t = std.testing;
    // addq %rcx, %rax (48 01 c8)
    var i = try d64(&.{ 0x48, 0x01, 0xc8 });
    try t.expectEqual(Op.add, i.op);
    try t.expectEqual(@as(u8, 8), i.size);
    try t.expectEqual(@as(u8, 3), i.len);
    try t.expectEqual(@as(u4, 1), i.reg());
    try t.expectEqual(@as(u4, 0), i.rm());
    // addl %r9d, %r8d (45 01 c8): REX.R and REX.B.
    i = try d64(&.{ 0x45, 0x01, 0xc8 });
    try t.expectEqual(@as(u8, 4), i.size);
    try t.expectEqual(@as(u4, 9), i.reg());
    try t.expectEqual(@as(u4, 8), i.rm());
    // 66 with REX.W: W wins (66 48 01 c8).
    i = try d64(&.{ 0x66, 0x48, 0x01, 0xc8 });
    try t.expectEqual(@as(u8, 8), i.size);
    // REX then a legacy prefix: the REX doesn't count (48 66 01 c8).
    i = try d64(&.{ 0x48, 0x66, 0x01, 0xc8 });
    try t.expectEqual(@as(u8, 2), i.size);
    try t.expect(!i.rex.present);
    // Of two REX, the last (48 41 b8 imm32): movl $imm, %r8d.
    i = try d64(&.{ 0x48, 0x41, 0xb8, 0x34, 0x12, 0x00, 0x00 });
    try t.expectEqual(@as(u8, 4), i.size);
    try t.expectEqual(@as(u8, 7), i.len);
    try t.expectEqual(@as(u4, 8), i.zreg());
    // movb %sil, %al (40 88 f0) vs movb %dh, %al (88 f0). A byte write
    // reads RAX too.
    i = try d64(&.{ 0x40, 0x88, 0xf0 });
    try t.expect(i.rex.present);
    try t.expectEqual(@as(u16, 1 << 6 | 1), effectsIn(.long, &i).regs_read);
    i = try d64(&.{ 0x88, 0xf0 });
    try t.expectEqual(@as(u16, 1 << 2), effectsIn(.long, &i).regs_read & ~@as(u16, 1));
    // movabsq $0x0807060504030201, %rax (48 b8 imm64).
    i = try d64(&.{ 0x48, 0xb8, 1, 2, 3, 4, 5, 6, 7, 8 });
    try t.expectEqual(@as(u8, 10), i.len);
    try t.expectEqual(@as(u64, 0x0807060504030201), i.imm);
    // movq $-1, %rax (48 c7 c0 ff ff ff ff): imm32 sign-extended.
    i = try d64(&.{ 0x48, 0xc7, 0xc0, 0xff, 0xff, 0xff, 0xff });
    try t.expectEqual(@as(u64, 0xffff_ffff_ffff_ffff), i.imm);
    try t.expectEqual(@as(u8, 7), i.len);
    // movl $-1, %eax (b8 ff ff ff ff): as encoded.
    i = try d64(&.{ 0xb8, 0xff, 0xff, 0xff, 0xff });
    try t.expectEqual(@as(u64, 0xffff_ffff), i.imm);
    // movslq %ecx, %rax (48 63 c1).
    i = try d64(&.{ 0x48, 0x63, 0xc1 });
    try t.expectEqual(Op.movsx, i.op);
    try t.expectEqual(@as(u8, 8), i.size);
    try t.expectEqual(table.Size.d, i.tableEntry().src_size);
    // bswapq %rax (48 0f c8), bswapl %eax (0f c8).
    try t.expectEqual(@as(u8, 8), (try d64(&.{ 0x48, 0x0f, 0xc8 })).size);
    try t.expectEqual(@as(u8, 4), (try d64(&.{ 0x0f, 0xc8 })).size);
    // xchg %eax, %r8d (41 90), nop (90), pause (f3 90).
    i = try d64(&.{ 0x41, 0x90 });
    try t.expectEqual(Op.xchg, i.op);
    try t.expectEqual(@as(u4, 8), i.zreg());
    try t.expectEqual(Op.nop, (try d64(&.{0x90})).op);
    try t.expectEqual(Op.nop, (try d64(&.{ 0xf3, 0x90 })).op);
}

test "decode64: d64, branches, and the stack" {
    const t = std.testing;
    // pushq %r12 (41 54); pushw %ax (66 50); popq %rbp (5d).
    var i = try d64(&.{ 0x41, 0x54 });
    try t.expectEqual(Op.push, i.op);
    try t.expectEqual(@as(u8, 8), i.size);
    try t.expectEqual(@as(u4, 12), i.zreg());
    try t.expectEqual(@as(u8, 2), (try d64(&.{ 0x66, 0x50 })).size);
    try t.expectEqual(@as(u8, 8), (try d64(&.{0x5d})).size);
    // pushq $-1 (6a ff); pushq $imm32 (68); pushw $imm16 (66 68).
    i = try d64(&.{ 0x6a, 0xff });
    try t.expectEqual(@as(u64, 0xffff_ffff_ffff_ffff), i.imm);
    i = try d64(&.{ 0x68, 0x00, 0x00, 0x00, 0x80 });
    try t.expectEqual(@as(u64, 0xffff_ffff_8000_0000), i.imm);
    i = try d64(&.{ 0x66, 0x68, 0x01, 0x02 });
    try t.expectEqual(@as(u8, 4), i.len);
    try t.expectEqual(@as(u8, 2), i.size);
    // callq rel32 with 66 is still rel32 and 64-bit, as on Intel.
    i = try d64(&.{ 0x66, 0xe8, 0xfc, 0xff, 0xff, 0xff });
    try t.expectEqual(Op.call, i.op);
    try t.expectEqual(@as(u8, 6), i.len);
    try t.expectEqual(@as(u8, 8), i.size);
    try t.expectEqual(@as(u64, 0xffff_ffff_ffff_fffc), i.imm);
    // je rel32, retq, callq *%rax, jmpq *(%rip).
    try t.expectEqual(@as(u8, 8), (try d64(&.{ 0x0f, 0x84, 0, 0, 0, 0 })).size);
    try t.expectEqual(@as(u8, 8), (try d64(&.{ 0x66, 0xc3 })).size);
    try t.expectEqual(@as(u8, 8), (try d64(&.{ 0xff, 0xd0 })).size);
    i = try d64(&.{ 0xff, 0x25, 0x10, 0, 0, 0 });
    try t.expectEqual(Op.jmp_ind, i.op);
    try t.expect(i.rip_rel);
    // jrcxz and jecxz (67 e3).
    try t.expect(!(try d64(&.{ 0xe3, 0x00 })).addr32);
    try t.expect((try d64(&.{ 0x67, 0xe3, 0x00 })).addr32);
    // leaveq, pushfq, and pushq %fs.
    try t.expectEqual(@as(u8, 8), (try d64(&.{0xc9})).size);
    try t.expectEqual(@as(u8, 8), (try d64(&.{0x9c})).size);
    try t.expectEqual(@as(u8, 8), (try d64(&.{ 0x0f, 0xa0 })).size);
}

test "decode64: addressing" {
    const t = std.testing;
    // movq 0x10(%rip), %rax (48 8b 05 10 00 00 00).
    var i = try d64(&.{ 0x48, 0x8b, 0x05, 0x10, 0, 0, 0 });
    try t.expect(i.mem and i.rip_rel);
    try t.expectEqual(no_reg64, i.base);
    try t.expectEqual(@as(u64, 0x10), i.disp);
    try t.expectEqual(@as(u8, 7), i.len);
    // movq -8(%r13), %rax: REX.B with r/m 5 and mod 1 is R13, not RIP.
    i = try d64(&.{ 0x49, 0x8b, 0x45, 0xf8 });
    try t.expect(!i.rip_rel);
    try t.expectEqual(@as(u5, 13), i.base);
    try t.expectEqual(@as(u64, 0xffff_ffff_ffff_fff8), i.disp);
    // mod 0 r/m 5 under REX.B is still RIP-relative (41 8b 05 disp32).
    i = try d64(&.{ 0x41, 0x8b, 0x05, 0, 0, 0, 0 });
    try t.expect(i.rip_rel);
    // movl (%r12), %eax (41 8b 04 24): REX.B with r/m 4 still takes a SIB.
    i = try d64(&.{ 0x41, 0x8b, 0x04, 0x24 });
    try t.expectEqual(@as(u5, 12), i.base);
    try t.expectEqual(no_reg64, i.index);
    try t.expectEqual(@as(u8, 4), i.len);
    // movl (%rax,%r12,8), %eax (42 8b 04 e0): REX.X makes index 4 R12.
    i = try d64(&.{ 0x42, 0x8b, 0x04, 0xe0 });
    try t.expectEqual(@as(u5, 0), i.base);
    try t.expectEqual(@as(u5, 12), i.index);
    try t.expectEqual(@as(u2, 3), i.scale);
    // movl 0x1000, %eax via SIB with no base or index (8b 04 25 disp32).
    i = try d64(&.{ 0x8b, 0x04, 0x25, 0x00, 0x10, 0, 0 });
    try t.expect(!i.rip_rel);
    try t.expectEqual(no_reg64, i.base);
    try t.expectEqual(no_reg64, i.index);
    try t.expectEqual(@as(u64, 0x1000), i.disp);
    // SIB base 5 with mod 0 under REX.B: still no base (41 8b 04 25 disp32).
    i = try d64(&.{ 0x41, 0x8b, 0x04, 0x25, 0, 0, 0, 0 });
    try t.expectEqual(no_reg64, i.base);
    try t.expectEqual(@as(u8, 8), i.len);
    // movl (%eax), %eax (67 8b 00): 32-bit addressing.
    i = try d64(&.{ 0x67, 0x8b, 0x00 });
    try t.expect(i.addr32);
    try t.expectEqual(@as(u5, 0), i.base);
    // movabsq 0x0807060504030201, %rax (48 a1 moffs64), and 67 a1 moffs32.
    i = try d64(&.{ 0x48, 0xa1, 1, 2, 3, 4, 5, 6, 7, 8 });
    try t.expect(i.mem);
    try t.expectEqual(@as(u64, 0x0807060504030201), i.disp);
    try t.expectEqual(@as(u8, 10), i.len);
    i = try d64(&.{ 0x67, 0xa1, 1, 2, 3, 4 });
    try t.expectEqual(@as(u64, 0x04030201), i.disp);
    try t.expectEqual(@as(u8, 6), i.len);
    // Segments: FS and GS count, the last of them; the rest are ignored.
    try t.expectEqual(Seg.fs, (try d64(&.{ 0x64, 0x8b, 0x00 })).seg);
    try t.expectEqual(Seg.fs, (try d64(&.{ 0x64, 0x2e, 0x8b, 0x00 })).seg);
    try t.expectEqual(Seg.gs, (try d64(&.{ 0x64, 0x65, 0x8b, 0x00 })).seg);
    try t.expectEqual(Seg.ds, (try d64(&.{ 0x36, 0x8b, 0x04, 0x24 })).seg);
    // Truncated and too long.
    try t.expectError(error.Truncated, d64(&.{ 0x48, 0xb8, 1, 2, 3, 4 }));
    try t.expectError(error.Truncated, d64(&.{0x48}));
    try t.expectError(error.TooLong, d64(&([_]u8{0x48} ** 15)));
}

test "decode64: long-mode-only and removed encodings" {
    const t = std.testing;
    // cmpxchg16b (%rsi) (48 0f c7 0e) and cmpxchg8b (%rsi).
    var i = try d64(&.{ 0x48, 0x0f, 0xc7, 0x0e });
    try t.expectEqual(Op.cmpxchg8b, i.op);
    try t.expectEqual(@as(u8, 8), i.size);
    try t.expectEqual(@as(u8, 4), (try d64(&.{ 0x0f, 0xc7, 0x0e })).size);
    // syscall (0f 05): long mode only.
    i = try d64(&.{ 0x0f, 0x05 });
    try t.expectEqual(Op.syscall, i.op);
    try t.expectEqual(@as(u8, 2), i.len);
    try t.expectEqual(Op.ud, (try d(&.{ 0x0f, 0x05 })).op);
    const x = effectsIn(.long, &i);
    try t.expectEqual(@as(u16, 0xffff), x.regs_read);
    try t.expectEqual(@as(u16, 1 | 2 | 1 << 11), x.regs_written);
    // Removed: push %es, daa, pusha, bound, 82, into, aam, salc, les,
    // lds, and far call and jmp.
    for ([_]u8{ 0x06, 0x07, 0x0e, 0x16, 0x17, 0x1e, 0x1f, 0x27, 0x2f, 0x37, 0x3f, 0x60, 0x61, 0x62, 0x82, 0x9a, 0xc4, 0xc5, 0xce, 0xd4, 0xd5, 0xd6, 0xea }) |o| {
        try t.expectEqual(Op.ud, (try d64(&.{ o, 0, 0, 0, 0, 0, 0 })).op);
    }
    // The legacy decoder is untouched: 40 is inc %eax there.
    try t.expectEqual(Op.inc, (try d(&.{0x40})).op);
    try t.expectEqual(Op.daa, (try d(&.{0x27})).op);
}

test "effectsIn(.long)" {
    const t = std.testing;
    // addq %r9, (%r12,%r13): reads R9, R12, R13.
    var x = effectsIn(.long, &try d64(&.{ 0x4f, 0x01, 0x0c, 0x2c }));
    try t.expectEqual(@as(u16, 1 << 9 | 1 << 12 | 1 << 13), x.regs_read);
    try t.expect(x.mem_read and x.mem_write);
    // movl %ecx, %r8d: a whole write, so no read of R8.
    x = effectsIn(.long, &try d64(&.{ 0x41, 0x89, 0xc8 }));
    try t.expectEqual(@as(u16, 1 << 1), x.regs_read);
    try t.expectEqual(@as(u16, 1 << 8), x.regs_written);
    // movw %cx, %r8w: partial, so it reads R8.
    x = effectsIn(.long, &try d64(&.{ 0x66, 0x41, 0x89, 0xc8 }));
    try t.expectEqual(@as(u16, 1 << 1 | 1 << 8), x.regs_read);
    // movb %r10b, %dil.
    x = effectsIn(.long, &try d64(&.{ 0x44, 0x88, 0xd7 }));
    try t.expectEqual(@as(u16, 1 << 10 | 1 << 7), x.regs_read);
    try t.expectEqual(@as(u16, 1 << 7), x.regs_written);
    // RIP-relative reads no register.
    x = effectsIn(.long, &try d64(&.{ 0x48, 0x8b, 0x05, 0, 0, 0, 0 }));
    try t.expectEqual(@as(u16, 0), x.regs_read);
    try t.expectEqual(@as(u16, 1), x.regs_written);
    // shlq $33, %rax writes the flags (count masked to 6 bits, not 5).
    x = effectsIn(.long, &try d64(&.{ 0x48, 0xc1, 0xe0, 33 }));
    try t.expectEqual(flags.arith, x.flags_written);
    // movq %rax, %xmm0 (66 48 0f 6e c0) reads RAX; movq %xmm0, %r9.
    x = effectsIn(.long, &try d64(&.{ 0x66, 0x48, 0x0f, 0x6e, 0xc0 }));
    try t.expectEqual(@as(u16, 1), x.regs_read);
    x = effectsIn(.long, &try d64(&.{ 0x66, 0x49, 0x0f, 0x7e, 0xc1 }));
    try t.expectEqual(@as(u16, 1 << 9), x.regs_written);
    // rep movsq with 67 writes ESI, EDI, and ECX whole.
    x = effectsIn(.long, &try d64(&.{ 0xf3, 0x67, 0x48, 0xa5 }));
    try t.expectEqual(@as(u16, table.esi | table.edi | table.ecx), x.regs_read);
}

test "decode64 against objdump" {
    var lines = std.mem.tokenizeScalar(u8, @embedFile("decode64-vectors.txt"), '\n');
    var buf: [15]u8 = undefined;
    var n: usize = 0;
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        const body = if (std.mem.indexOf(u8, line, "  #")) |k| line[0..k] else line;
        var f = std.mem.tokenizeScalar(u8, body, ' ');
        const hex = f.next().?;
        const code = try std.fmt.hexToBytes(&buf, hex);
        const i = decodeIn(.long, code) catch |e| {
            std.debug.print("{s}: {s}\n", .{ hex, @errorName(e) });
            return e;
        };
        errdefer std.debug.print("{s}: {any}\n", .{ hex, i });
        const len = f.next().?;
        const op = std.meta.stringToEnum(Op, f.next().?).?;
        try std.testing.expectEqual(op, i.op);
        n += 1;
        if (std.mem.eql(u8, len, "-")) continue;
        const num = struct {
            fn of(it: *std.mem.TokenIterator(u8, .scalar), base: u8) !u64 {
                return std.fmt.parseInt(u64, it.next().?, base);
            }
        };
        try std.testing.expectEqual(try std.fmt.parseInt(u8, len, 10), i.len);
        try std.testing.expectEqual(try num.of(&f, 10), i.size);
        try std.testing.expectEqual(try num.of(&f, 10) == 1, i.mem);
        try std.testing.expectEqual(try num.of(&f, 10) == 1, i.rip_rel);
        try std.testing.expectEqual(try num.of(&f, 10), i.base);
        try std.testing.expectEqual(try num.of(&f, 10), i.index);
        try std.testing.expectEqual(try num.of(&f, 10), i.scale);
        try std.testing.expectEqual(try num.of(&f, 16), i.disp);
        try std.testing.expectEqual(try num.of(&f, 16), i.imm);
    }
    try std.testing.expect(n > 1000);
}

fn d(bytes: []const u8) !Inst {
    return decode(bytes);
}

test "decode prefixes, ModRM, SIB, and immediates" {
    // addl $0x12345678, 0x10(%eax,%ecx,4)
    var i = try d(&.{ 0x81, 0x44, 0x88, 0x10, 0x78, 0x56, 0x34, 0x12 });
    try std.testing.expectEqual(Op.add, i.op);
    try std.testing.expectEqual(@as(u8, 8), i.len);
    try std.testing.expect(i.mem);
    try std.testing.expectEqual(@as(u4, 0), i.base);
    try std.testing.expectEqual(@as(u4, 1), i.index);
    try std.testing.expectEqual(@as(u2, 2), i.scale);
    try std.testing.expectEqual(@as(u32, 0x10), i.disp);
    try std.testing.expectEqual(@as(u32, 0x12345678), i.imm);
    // movl %gs:0x14, %eax
    i = try d(&.{ 0x65, 0xa1, 0x14, 0x00, 0x00, 0x00 });
    try std.testing.expectEqual(Op.mov, i.op);
    try std.testing.expectEqual(Seg.gs, i.seg);
    try std.testing.expectEqual(@as(u32, 0x14), i.disp);
    try std.testing.expectEqual(@as(u8, 6), i.len);
    // movw $1, (%esp) with 66: a 16-bit immediate, SS by default.
    i = try d(&.{ 0x66, 0xc7, 0x04, 0x24, 0x01, 0x00 });
    try std.testing.expectEqual(@as(u8, 2), i.size);
    try std.testing.expectEqual(@as(u8, 6), i.len);
    try std.testing.expectEqual(Seg.ss, i.seg);
    try std.testing.expectEqual(@as(u4, 4), i.base);
    try std.testing.expectEqual(no_reg, i.index);
    // jne -2
    i = try d(&.{ 0x0f, 0x85, 0xfa, 0xff, 0xff, 0xff });
    try std.testing.expectEqual(Op.jcc, i.op);
    try std.testing.expectEqual(@as(u32, 0xfffffffa), i.imm);
    try std.testing.expectEqual(@as(u4, 5), i.cc());
    // Disp32 with no base: movl 0x1000, %ecx (8b 0d).
    i = try d(&.{ 0x8b, 0x0d, 0x00, 0x10, 0x00, 0x00 });
    try std.testing.expectEqual(no_reg, i.base);
    try std.testing.expectEqual(@as(u32, 0x1000), i.disp);
    // 16-bit addressing: movl (%bp,%si), %eax (67 8b 02).
    i = try d(&.{ 0x67, 0x8b, 0x02 });
    try std.testing.expect(i.addr16);
    try std.testing.expectEqual(@as(u4, 5), i.base);
    try std.testing.expectEqual(@as(u4, 6), i.index);
    try std.testing.expectEqual(Seg.ss, i.seg);
    // Truncated and too long.
    try std.testing.expectError(error.Truncated, d(&.{ 0x81, 0x44 }));
    try std.testing.expectError(error.TooLong, d(&([_]u8{0x66} ** 15)));
    // gcc's long NOP: 66 2e 0f 1f 84 00 00 00 00 00.
    i = try d(&.{ 0x66, 0x2e, 0x0f, 0x1f, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00 });
    try std.testing.expectEqual(Op.nop, i.op);
    try std.testing.expectEqual(@as(u8, 10), i.len);
    // ENTER $16, $0.
    i = try d(&.{ 0xc8, 0x10, 0x00, 0x00 });
    try std.testing.expectEqual(@as(u32, 16), i.imm);
    try std.testing.expectEqual(@as(u8, 4), i.len);
    // SSE: pshufd $0x1b, %xmm1, %xmm0 (66 0f 70 c1 1b).
    i = try d(&.{ 0x66, 0x0f, 0x70, 0xc1, 0x1b });
    try std.testing.expectEqual(Op.sse, i.op);
    try std.testing.expectEqual(@as(u8, 5), i.len);
}

test "effects" {
    // addl %ecx, (%ebx,%esi): reads ECX, EBX, ESI; memory read and write.
    var x = effects(&try d(&.{ 0x01, 0x0c, 0x33 }));
    try std.testing.expectEqual(table.ecx | table.ebx | table.esi, x.regs_read);
    try std.testing.expectEqual(@as(u8, 0), x.regs_written);
    try std.testing.expect(x.mem_read and x.mem_write);
    try std.testing.expectEqual(flags.arith, x.flags_written);
    // movb %al, %ah: writes part of EAX, so reads it too.
    x = effects(&try d(&.{ 0x88, 0xc4 }));
    try std.testing.expectEqual(table.eax, x.regs_read);
    try std.testing.expectEqual(table.eax, x.regs_written);
    // movl %ecx, %edx: no read of EDX.
    x = effects(&try d(&.{ 0x89, 0xca }));
    try std.testing.expectEqual(table.ecx, x.regs_read);
    try std.testing.expectEqual(table.edx, x.regs_written);
    // ja: CF and ZF.
    x = effects(&try d(&.{ 0x77, 0x00 }));
    try std.testing.expectEqual(flags.CF | flags.ZF, x.flags_read);
    // rep movsl.
    x = effects(&try d(&.{ 0xf3, 0xa5 }));
    try std.testing.expectEqual(table.esi | table.edi | table.ecx, x.regs_written);
    try std.testing.expectEqual(flags.DF, x.flags_read);
    // movsl without rep leaves ECX.
    x = effects(&try d(&.{0xa5}));
    try std.testing.expectEqual(table.esi | table.edi, x.regs_written);
    // incl %eax keeps CF.
    x = effects(&try d(&.{0x40}));
    try std.testing.expectEqual(flags.arith & ~flags.CF, x.flags_written);
    // shll %cl, %eax may leave the flags.
    x = effects(&try d(&.{ 0xd3, 0xe0 }));
    try std.testing.expectEqual(flags.arith, x.flags_read & flags.arith);
    try std.testing.expectEqual(table.eax | table.ecx, x.regs_read);
    // pushl %ebx.
    x = effects(&try d(&.{0x53}));
    try std.testing.expectEqual(table.ebx | table.esp, x.regs_read);
    try std.testing.expectEqual(table.esp, x.regs_written);
    try std.testing.expect(x.mem_write);
    // leal 4(%eax), %eax: no memory.
    x = effects(&try d(&.{ 0x8d, 0x40, 0x04 }));
    try std.testing.expect(!x.mem_read and !x.mem_write);
    try std.testing.expectEqual(table.eax, x.regs_written);
}

test "effects of SSE and x87 forms" {
    // movd %xmm1, %eax
    var x = effects(&try d(&.{ 0x66, 0x0f, 0x7e, 0xc8 }));
    try std.testing.expectEqual(table.eax, x.regs_written);
    // cvtsi2sd %ecx, %xmm0
    x = effects(&try d(&.{ 0xf2, 0x0f, 0x2a, 0xc1 }));
    try std.testing.expectEqual(table.ecx, x.regs_read);
    // cvttsd2si (%esi), %edx
    x = effects(&try d(&.{ 0xf2, 0x0f, 0x2c, 0x16 }));
    try std.testing.expectEqual(table.esi, x.regs_read);
    try std.testing.expectEqual(table.edx, x.regs_written);
    try std.testing.expect(x.mem_read and !x.mem_write);
    // pmovmskb %mm1, %ebx
    x = effects(&try d(&.{ 0x0f, 0xd7, 0xd9 }));
    try std.testing.expectEqual(table.ebx, x.regs_written);
    // movdqa %xmm0, (%eax)
    x = effects(&try d(&.{ 0x66, 0x0f, 0x7f, 0x00 }));
    try std.testing.expect(x.mem_write and !x.mem_read);
    // fnstsw %ax
    x = effects(&try d(&.{ 0xdf, 0xe0 }));
    try std.testing.expectEqual(table.eax, x.regs_written);
    // fstpl (%ecx)
    x = effects(&try d(&.{ 0xdd, 0x19 }));
    try std.testing.expect(x.mem_write and !x.mem_read);
}
