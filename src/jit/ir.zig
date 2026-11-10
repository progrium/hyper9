//! The JIT's IR: a region of guest code as blocks of typed SSA values
//! (design: the a64-jit and x86-jit drafts, "The IR").
//!
//! This file is the contract between the front ends (ha64's and h86's
//! lifters) and the emitters (arm64, x86-64, and wasm). It has one owner;
//! other work asks for new operations rather than editing it.
//!
//! Rules that keep it stable while three emitters and two front ends are
//! built against it:
//!
//! - **Operations are only ever added.** `Op`'s values are explicit and
//!   grouped, and a value is never renumbered or reused. A new operation
//!   lands with its reference semantics in `ir_eval.zig`, so an emitter
//!   that hasn't lowered it yet calls that function instead (`pure` ops),
//!   and nothing breaks.
//! - **Values are block-local.** An operand must be defined earlier in the
//!   same block. Guest state crosses blocks, and the region's exits,
//!   through `getreg` and `setreg` on the guest's `Cpu` struct. Register
//!   allocation may keep guest slots in host registers across blocks; the
//!   IR doesn't need to say so.
//! - **Guest state is exact at every operation that can leave the region.**
//!   A front end writes each guest instruction's results with `setreg`
//!   before the next instruction's first load, store, helper call, or
//!   exit. An emitter that sinks those writes must write them back on every
//!   path out (side exits, slow paths, and helpers).
//! - **ctx.retired is exact at every exit, faults included.** An op that
//!   can leave the region (`Op.canLeave`) carries `retired`: the guest
//!   instructions completed since its block's last `retire`. Leaving through
//!   it adds that to ctx.retired (and takes it from the budget); otherwise
//!   it costs nothing. A front end's `call.interp` handler counts the
//!   instruction it ran itself, when it completes and then leaves.
//! - **ctx.retired and ctx.budget need be exact only where something
//!   outside the region sees them:** at every exit (chained ones too: a
//!   linked chain site and a jump-cache hit leave like any other), and
//!   across `call.interp`, `call.helper`, and `copy`, which may read and
//!   write both. In between, an emitter may keep `retire`'s counts in a
//!   register and add them to both fields there. A `poll` must still test
//!   the exact budget less what's pending (`<= 0`), so an interrupt lands
//!   on the instruction T0's count would; other threads interrupt through
//!   ctx.exit_request, never the budget.
//! - **Flags are values.** `nzcv.*` (arm64) and `eflags.*` (x86) produce a
//!   `flags` value, and `*.cond` reads a condition from one. The reference
//!   semantics compute the flags eagerly, packed as the guest packs them;
//!   emitters are free to keep them lazy or in host flags.
//!
//! Text form, for tests (`print` and `parse` round-trip it):
//!
//!     region 0x1000
//!     b0:
//!       %0 = getreg:i64 #0x8
//!       %1 = const:i64 #0x1
//!       %2 = sub:i64 %0, %1
//!       setreg %2 #0x8
//!       %4 = nzcv.sub:flags %0, %1
//!       %5 = nzcv.cond:i1 %4 #0x1
//!       brcond %5 -> b0 b1
//!     b1:
//!       exit.chain #0x1010
//!
//! `#` is `aux` and `@` is `aux2`, in hex; `!` is `retired`, in decimal;
//! `-> bN` names blocks.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Type = enum(u8) {
    none = 0,
    i1 = 1,
    i8 = 2,
    i16 = 3,
    i32 = 4,
    i64 = 5,
    v128 = 6,
    flags = 7,

    pub fn bits(t: Type) u32 {
        return switch (t) {
            .none => 0,
            .i1 => 1,
            .i8 => 8,
            .i16 => 16,
            .i32 => 32,
            .i64, .flags => 64,
            .v128 => 128,
        };
    }
    pub fn isInt(t: Type) bool {
        return switch (t) {
            .i1, .i8, .i16, .i32, .i64 => true,
            else => false,
        };
    }
    /// All bits set in the type's width, for integer types up to 64 bits.
    pub fn mask(t: Type) u64 {
        const n = t.bits();
        return if (n >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(n)) - 1;
    }
};

/// Integer comparisons, for `icmp`'s aux.
pub const Pred = enum(u8) { eq = 0, ne, ult, ule, ugt, uge, slt, sle, sgt, sge };

/// Memory access details, for the aux of `load` and `store`.
pub const MemFlags = packed struct(u64) {
    /// log2 of the access size in bytes: 0 to 3 (4 is reserved for v128).
    size: u3,
    /// `load` only: sign-extend to the result type.
    signed: bool = false,
    /// The access must be naturally aligned, or it faults.
    aligned: bool = false,
    order: Order = .plain,
    /// `load` only: the load is the first half of a read-modify-write
    /// (x86's `add [m], r`), so a fault reports a write access, as the
    /// guest's own fault would.
    rmw: bool = false,
    /// A hint: this access is on the same guest page as the `load` or
    /// `store` (the same op as this one) `same_page` instructions earlier
    /// in this block, so an emitter may reuse that access's TLB lookup.
    /// 0 is no hint. It never changes what happens: an emitter that uses it
    /// still checks the page number matches (one compare, no TLB load) and
    /// does the full check if it doesn't, so a wrong hint is only slow.
    /// ir_eval ignores it.
    same_page: u16 = 0,
    _: u39 = 0,

    pub const Order = enum(u3) { plain = 0, acquire, release, seq_cst };

    pub fn bytes(f: MemFlags) u32 {
        return @as(u32, 1) << f.size;
    }
};

/// The aux of the floating-point and vector ops (`fp.*` and `v.*`, the
/// ops `Op.isExt` covers): the FP environment an `fp.*` op runs in, as the
/// guest's FPCR or MXCSR sets it when the region is lifted, an immediate,
/// and a vector's lane size.
///
/// An `fp.*` op's aux2, when not 0, is 1 + the byte offset in the Cpu of
/// a u32 the op ORs the exceptions it raises into, in the guest's layout:
/// MXCSR's IE DE ZE OE UE PE (bits 0..5) for x86, FPSR's IOC DZC OFC UFC
/// IXC (bits 0..4) and IDC (bit 7) for Arm.
pub const ExtAux = packed struct(u64) {
    /// softfloat.Rounding: near_even, down, up, zero, near_away, odd.
    rounding: u3 = 0,
    /// Denormal inputs are zeros (MXCSR.DAZ; FPCR.FZ).
    daz: bool = false,
    /// Tiny results are zeros (MXCSR.FZ; FPCR.FZ).
    ftz: bool = false,
    /// softfloat.Nans: first (x86), signaling_first (Arm), default (FPCR.DN).
    nans: u2 = 0,
    /// Arm's rules: a positive default NaN, tininess before rounding, FZ
    /// without inexact, FMIN and FMAX's NaN handling, saturating
    /// conversions, and FPSR's flag layout. Otherwise x86's.
    arm: bool = false,
    /// `fp.cmp`: a quiet NaN raises invalid too (COMISS, FCMPE).
    /// `fp.round`: raise inexact (FRINTX; SSE4.1's ROUNDSS without bit 3).
    exact: bool = false,
    _r: u7 = 0,
    /// Per op: fixed-point fraction bits (conversions), a lane index, a
    /// shift count, a byte offset, a predicate, or a variant.
    imm: u16 = 0,
    /// A vector's lane size: 8 << esize bits. For `fp.*` on v128, 1 to 3
    /// (binary16, 32, 64).
    esize: u2 = 0,
    _: u30 = 0,

    pub fn of(aux: u64) ExtAux {
        return @bitCast(aux);
    }
    pub fn bits(x: ExtAux) u32 {
        return @as(u32, 8) << x.esize;
    }
    pub fn lanes(x: ExtAux) u32 {
        return @as(u32, 16) >> x.esize;
    }
};

/// The integer type of a lane of 8 << esize bits.
pub fn laneType(esize: u2) Type {
    return switch (esize) {
        0 => .i8,
        1 => .i16,
        2 => .i32,
        3 => .i64,
    };
}

/// Whether a scalar type holds an FP value's bits: i16 (binary16), i32
/// (binary32), or i64 (binary64).
pub fn isFloat(t: Type) bool {
    return t == .i16 or t == .i32 or t == .i64;
}

/// Which flag group a front end uses. The emitter lowers both; a front end
/// produces only its own.
pub const FlagGroup = enum(u8) { nzcv, eflags };

/// Every operation. Values are explicit and grouped; add new ones at the
/// end of their group (or in a new group), never renumber.
pub const Op = enum(u16) {
    // ---- values and guest state
    /// Result = aux, truncated to the type.
    @"const" = 0,
    /// Result = the guest Cpu field at byte offset aux, of the result type.
    getreg = 1,
    /// Cpu field at byte offset aux = a, of a's type. No result.
    setreg = 2,

    // ---- integer (pure). Two's complement, results truncated to the type.
    add = 16,
    sub = 17,
    mul = 18,
    /// High half of the unsigned and signed products.
    mulhu = 19,
    mulhs = 20,
    /// arm64's results: division by zero gives 0, and MIN / -1 gives MIN.
    /// A front end with other rules (x86's #DE) checks before dividing.
    udiv = 21,
    sdiv = 22,
    @"and" = 23,
    @"or" = 24,
    xor = 25,
    /// a & ~b
    andn = 26,
    /// Shifts and rotates take the amount modulo the type's width.
    shl = 27,
    lshr = 28,
    ashr = 29,
    ror = 30,
    neg = 31,
    not = 32,
    clz = 33,
    ctz = 34,
    popcnt = 35,
    rbit = 36,
    /// Byte reverse of the whole value.
    bswap = 37,
    /// Widen a to the result type.
    zext = 38,
    sext = 39,
    /// Narrow a to the result type.
    trunc = 40,
    /// a (i1) ? b : c
    select = 41,
    /// i1 = a <pred aux> b
    icmp = 42,
    /// Rotate left, the x86 way round. Same modulo rule as `ror`.
    rol = 43,
    urem = 44,
    srem = 45,

    // ---- arm64 flags (pure). A flags value is NZCV in bits 31..28.
    /// Flags of a + b (ADDS), at a's width.
    @"nzcv.add" = 64,
    /// Flags of a - b (SUBS, CMP).
    @"nzcv.sub" = 65,
    /// Flags of the logical result a (ANDS, TST): N and Z from a, C = V = 0.
    @"nzcv.logic" = 66,
    /// Flags of a + b + C, with C from flags c (ADCS).
    @"nzcv.adc" = 67,
    /// Flags of a - b - !C, with C from flags c (SBCS).
    @"nzcv.sbc" = 68,
    /// i1 = condition aux (arm64's 4-bit cond field) holds for flags a.
    @"nzcv.cond" = 69,
    /// i32 = NZCV in bits 31..28, as MRS NZCV reads it.
    @"nzcv.pack" = 70,
    /// flags = bits 31..28 of the i32 a, as MSR NZCV writes it.
    @"nzcv.unpack" = 71,

    // ---- x86 flags (pure). A flags value is EFLAGS' CF PF AF ZF SF OF
    // bits in their EFLAGS positions; other bits are 0.
    /// Flags of a + b, at a's width (8, 16, or 32 bits).
    @"eflags.add" = 96,
    @"eflags.sub" = 97,
    /// a + b + CF, a - b - CF, with CF from flags c.
    @"eflags.adc" = 98,
    @"eflags.sbb" = 99,
    /// Flags of the logical result a: SF ZF PF from it, CF = OF = 0, AF = 0.
    @"eflags.logic" = 100,
    /// Flags of a + 1 and a - 1; CF is kept from flags b.
    @"eflags.inc" = 101,
    @"eflags.dec" = 102,
    /// i1 = condition aux (x86's 4-bit cc, as in Jcc) holds for flags a.
    @"eflags.cond" = 103,
    /// i32 = the flags bits, as in EFLAGS.
    @"eflags.pack" = 104,
    /// flags = the flags bits of the i32 a.
    @"eflags.unpack" = 105,
    /// Flags of a left shift (SHL, SHLD): a is the source shifted by
    /// count - 1, b the result. CF = msb(a), OF = msb(a ^ b), AF = 0, and
    /// SF ZF PF from b. The undefined flags are QEMU's, so lockstep with
    /// Unicorn matches. A count of 0 never gets here: it keeps the flags.
    @"eflags.shl" = 106,
    /// Flags of a right shift (SHR, SAR, SHRD): a is the source shifted by
    /// count - 1, b the result. CF = a & 1, OF = msb(a ^ b), AF = 0, SF ZF
    /// PF from b.
    @"eflags.shr" = 107,
    /// Flags of MUL and IMUL: a is 1 if the result overflowed its low
    /// half, else 0; b is the low half. CF = OF = a, AF = 0, SF ZF PF from b.
    @"eflags.mul" = 108,

    // ---- memory. Guest addresses are a's value (i64; an i32 address is
    // zero-extended). aux is a MemFlags; aux2 is the guest PC to report
    // if the access faults.
    /// Result = the value at a.
    load = 128,
    /// Store b at a. No result.
    store = 129,
    /// A full barrier. aux: 0 full, 1 loads, 2 stores.
    fence = 130,
    /// Compare and swap: if the value at a equals b (at the access width),
    /// store c there; the result is the old value either way, of the
    /// result type, which is b's and c's. Atomic, sequentially consistent
    /// whatever `order` says. The access must be naturally aligned (else an
    /// alignment fault, whatever `aligned` says), and a fault of any kind
    /// reports a write. For STXR and STXP (as one wider access), LOCK
    /// CMPXCHG, and anything else that needs the host's atomics.
    cas = 131,

    // ---- calls. They see guest state in the Cpu, as written by setreg.
    /// Run the front end's interpreter on one decoded instruction:
    /// aux is an index into the region's `handles`, aux2 its guest PC. If
    /// the instruction leaves (a fault, an exception, a branch), the region
    /// exits with what the interpreter returned. No result.
    @"call.interp" = 160,
    /// Call the runtime helper numbered aux with a, b, c (i64s); the
    /// result, if any, is an i64. The helper table is the backend's.
    @"call.helper" = 161,
    /// A guest instruction run on the host as itself (ha64 on arm64 hosts,
    /// src/jit/a64/copy.zig), with its register fields rewritten to
    /// wherever the allocator put the guest registers. No result, and it
    /// can't leave: only register-only, non-PC-relative instructions that
    /// can't fault are copied.
    ///
    /// aux: the guest word in bits 31..0; bit 32, it reads NZCV; bit 33, it
    /// writes NZCV; bit 34, it's FP (runs under the guest FPCR, accumulates
    /// into FPSR, may set QC).
    /// aux2: four 16-bit field descriptors, for Rd (word bits 4..0), Rn
    /// (9..5), Rm (20..16), and Ra (14..10), in that order from bit 0. In
    /// each: bits 12..0 the guest Cpu offset, bit 13 read, bit 14 written,
    /// bit 15 a V register (16 bytes, else an 8-byte X register); 0 is a
    /// field that isn't a register.
    ///
    /// Elsewhere (ir_eval, other hosts) it runs as `call.interp` with the
    /// word as the handle and PC 0, which ha64's handler takes; it must
    /// return `.ok`.
    copy = 162,

    // ---- runtime
    /// Leave with `.interrupted` and resume PC aux if an exit is
    /// requested or the budget is spent. At region entry and loop heads.
    poll = 176,
    /// Count aux guest instructions as retired (and against the budget).
    retire = 177,
    /// Flags not yet written back: the guest's flags in the u32 at `aux` (a
    /// Cpu offset) are a's, but are written there only if needed. Writing
    /// merges into the slot: old & ~mask | pack, where pack and mask are
    /// `nzcv.pack` and 0xf000_0000 if aux2 is 0, or `eflags.pack` and
    /// ir_eval.eflags_mask (0x8d5) if aux2 is 1, so the slot's other bits
    /// (EFLAGS' DF, IF, and bit 1) are kept.
    /// They're written before any way out of the region (every exit, a
    /// fault, a poll that leaves) and before `call.interp`, `call.helper`,
    /// and `copy`. A `setreg` overlapping aux drops it; a new
    /// `pending.flags` writes the old one first if its offset differs.
    /// Pending flags stay pending across `br` and `brcond` to the blocks
    /// they name, so a loop needn't store them on each back edge: a block
    /// starts with them pending where its predecessors left them so (the
    /// emitter reconciles predecessors that disagree, on the edges). The
    /// verifier tracks where the slot may be pending, through the blocks,
    /// and nothing may `getreg` it there. No result.
    /// An emitter may simply write it at once: that's always correct.
    @"pending.flags" = 178,

    // ---- terminators: exactly one, last in each block.
    /// To block aux.
    br = 192,
    /// To block aux if a (i1), else to block aux2.
    brcond = 193,
    /// Leave for guest PC aux, which a chained jump may take directly.
    @"exit.chain" = 194,
    /// Leave for the guest PC in a.
    @"exit.indirect" = 195,
    /// A system call; resume at aux.
    @"exit.svc" = 196,
    /// A breakpoint instruction at aux.
    @"exit.brk" = 197,
    /// An undefined instruction at aux.
    @"exit.undef" = 198,

    // ---- floating point (224..255): IEEE binary16, 32, and 64 values as
    // i16, i32, and i64 bit patterns, or lane-wise on v128 by aux's esize.
    // aux is an ExtAux (the FP environment); aux2 names where exceptions
    // accumulate (see ExtAux). Results follow softfloat.zig with the
    // guest's rules, never the host's.
    @"fp.add" = 224,
    @"fp.sub" = 225,
    @"fp.mul" = 226,
    @"fp.div" = 227,
    @"fp.sqrt" = 228,
    /// a * b + c, rounded once. With Arm's rules, NaNs are picked in the
    /// order c, a, b, and inf * 0 + a quiet NaN is the default NaN.
    @"fp.fma" = 229,
    /// x86's MINSS (a < b ? a : b), or Arm's FMIN.
    @"fp.min" = 230,
    @"fp.max" = 231,
    /// Arm's FMINNM: a quiet NaN against a number gives the number.
    @"fp.minnm" = 232,
    @"fp.maxnm" = 233,
    /// Scalar: an i8 softfloat.Order (0 lt, 1 eq, 2 gt, 3 unordered).
    /// Vector: each lane all ones if its order is in the set imm (bit k
    /// for order k), else zero.
    @"fp.cmp" = 234,
    /// Between formats, a's to the result's. Vector: lanes of esize to
    /// lanes of imm & 3, widening the low half's (the high half's if imm
    /// bit 8 is set), or narrowing into the low half, the high half zero.
    @"fp.cvt" = 235,
    /// Integer a / 2^imm to FP. Vector: lane for lane, of one size.
    @"fp.fromsint" = 236,
    @"fp.fromuint" = 237,
    /// FP a * 2^imm to an integer, rounded by aux's rounding. A NaN or a
    /// value out of range is the integer indefinite (x86: the sign bit
    /// alone, or all ones unsigned), or saturates with NaN giving 0 (Arm).
    @"fp.tosint" = 238,
    @"fp.touint" = 239,
    /// To an integral value in a's format, by aux's rounding.
    @"fp.round" = 240,

    // ---- vectors (256..): v128 values; aux is an ExtAux for its esize and
    // imm. Lanes are numbered from the low end.
    /// v128 with a (i64) low and b (i64) high.
    @"v.make" = 256,
    /// Lane imm of a, of the result's type (laneType(esize)).
    @"v.lane" = 257,
    /// a with lane imm replaced by b.
    @"v.ins" = 258,
    /// Every lane a (of laneType(esize)).
    @"v.dup" = 259,
    @"v.add" = 260,
    @"v.sub" = 261,
    /// Low halves of the products; esize 0 to 2.
    @"v.mul" = 262,
    @"v.and" = 263,
    @"v.or" = 264,
    @"v.xor" = 265,
    /// a & ~b.
    @"v.andn" = 266,
    /// Each lane by imm; a count of the lane's width or more gives 0
    /// (shl, lshr) or the sign (ashr).
    @"v.shl" = 267,
    @"v.lshr" = 268,
    @"v.ashr" = 269,
    /// Each lane all ones if a's lane <imm, an ir.Pred> b's, else zero.
    @"v.cmp" = 270,
    /// imm bit 0: signed.
    @"v.min" = 271,
    @"v.max" = 272,
    /// Bytes imm..imm+15 of a (low) and b (high) together.
    @"v.ext" = 273,
    /// Arm's ZIP1, UZP1, and TRN1 of a and b, or with imm 1, ZIP2, UZP2,
    /// and TRN2.
    @"v.zip" = 274,
    @"v.uzp" = 275,
    @"v.trn" = 276,
    /// Byte i is a's byte b[i], or 0 where b[i] >= 16 (Arm's TBL; x86's
    /// PSHUFB with b masked by 0x8f).
    @"v.tbl" = 277,
    /// Lanes of esize (1 to 3) to half their width, in the low half, the
    /// high half zero. imm: 0 truncates; saturating, 1 signed to signed,
    /// 2 signed to unsigned, 3 unsigned to unsigned.
    @"v.narrow" = 278,
    /// The low half's lanes of esize (0 to 2), or the high half's with imm
    /// bit 1, to twice their width, sign-extended with imm bit 0.
    @"v.widen" = 279,
    /// 16 bytes at a; aux is MemFlags (size 4), aux2 the PC. As `load`.
    @"v.load" = 280,
    /// 16 bytes, b, to a; as `store`.
    @"v.store" = 281,

    pub fn name(op: Op) []const u8 {
        return @tagName(op);
    }

    /// Whether the op can leave the region: it takes `Inst.retired`.
    pub fn canLeave(op: Op) bool {
        return switch (op) {
            .load, .store, .cas, .@"call.interp", .poll, .@"v.load", .@"v.store" => true,
            .br, .brcond => false,
            else => op.isTerminator(),
        };
    }

    pub fn isTerminator(op: Op) bool {
        const v = @intFromEnum(op);
        return v >= 192 and v < 224;
    }

    /// The FP and vector ops (`fp.*`, `v.*`), whose aux is an ExtAux. They
    /// have their own fallback, ir_eval.evalExtC, since v128 values don't
    /// fit evalOpC and `fp.*` accumulate exceptions in the guest's Cpu.
    pub fn isExt(op: Op) bool {
        return @intFromEnum(op) >= 224;
    }

    /// Whether the op is an `fp.*` op.
    pub fn isFp(op: Op) bool {
        const v = @intFromEnum(op);
        return v >= 224 and v < 256;
    }

    /// No side effects, no memory, no guest state: an emitter may call
    /// `ir_eval`'s function for it instead of lowering it.
    pub fn isPure(op: Op) bool {
        const v = @intFromEnum(op);
        return op == .@"const" or (v >= 16 and v < 128);
    }

    /// Whether the operation defines a value (else its type is `.none`).
    pub fn hasResult(op: Op) bool {
        return switch (op) {
            .setreg, .store, .fence, .@"call.interp", .copy, .poll, .retire, .@"pending.flags", .@"v.store" => false,
            .@"call.helper" => true, // may be .none: see the instruction's type
            else => !op.isTerminator(),
        };
    }
};

pub const Ref = u32;
pub const none: Ref = std.math.maxInt(Ref);
pub const BlockId = u32;

pub const Inst = struct {
    op: Op,
    ty: Type = .none,
    a: Ref = none,
    b: Ref = none,
    c: Ref = none,
    aux: u64 = 0,
    aux2: u64 = 0,
    /// For ops that can leave: guest instructions completed since the
    /// block's last `retire`, added to ctx.retired if this op leaves.
    retired: u32 = 0,

    pub fn operands(i: *const Inst) [3]Ref {
        return .{ i.a, i.b, i.c };
    }
};

/// A block's instructions are `insts[start..start+len]`; the last is its
/// terminator.
pub const Block = struct { start: u32 = 0, len: u32 = 0, begun: bool = false };

pub const Region = struct {
    /// The guest PC the region starts at; block 0 is its entry.
    entry_pc: u64,
    /// The guest's memory model is TSO (x86): every plain load is an
    /// acquire and every plain store a release, which hosts with a weaker
    /// model (arm64) must honour. ir_eval and hosts that are TSO already
    /// (x86-64, single-threaded wasm) ignore it. Text form: `region PC tso`.
    tso: bool = false,
    insts: std.ArrayList(Inst) = .empty,
    blocks: std.ArrayList(Block) = .empty,
    /// The front end's decoded-instruction handles, for `call.interp`.
    handles: std.ArrayList(u64) = .empty,

    pub fn deinit(r: *Region, gpa: Allocator) void {
        r.insts.deinit(gpa);
        r.blocks.deinit(gpa);
        r.handles.deinit(gpa);
    }

    pub fn blockInsts(r: *const Region, b: BlockId) []const Inst {
        const blk = r.blocks.items[b];
        return r.insts.items[blk.start..][0..blk.len];
    }
};

/// Builds a region a block at a time: reserve block ids with `block`,
/// then `begin` each and fill it up to a terminator.
pub const Builder = struct {
    gpa: Allocator,
    r: *Region,
    cur: ?BlockId = null,
    /// Guest instructions completed since the current block's last
    /// `retire`. The lifter sets it before each guest instruction; `emit`
    /// stamps it on every op that can leave. `begin` and `retire` reset it.
    retired: u32 = 0,

    pub fn init(gpa: Allocator, r: *Region) Builder {
        return .{ .gpa = gpa, .r = r };
    }

    pub fn block(b: *Builder) Allocator.Error!BlockId {
        try b.r.blocks.append(b.gpa, .{});
        return @intCast(b.r.blocks.items.len - 1);
    }

    pub fn begin(b: *Builder, id: BlockId) void {
        std.debug.assert(b.cur == null);
        const blk = &b.r.blocks.items[id];
        std.debug.assert(!blk.begun);
        blk.* = .{ .start = @intCast(b.r.insts.items.len), .len = 0, .begun = true };
        b.cur = id;
        b.retired = 0;
    }

    pub fn emit(b: *Builder, inst: Inst) Allocator.Error!Ref {
        const id = b.cur.?;
        var i = inst;
        if (i.op.canLeave() and i.retired == 0) i.retired = b.retired;
        try b.r.insts.append(b.gpa, i);
        b.r.blocks.items[id].len += 1;
        if (i.op.isTerminator()) b.cur = null;
        return @intCast(b.r.insts.items.len - 1);
    }

    pub fn handle(b: *Builder, h: u64) Allocator.Error!u64 {
        try b.r.handles.append(b.gpa, h);
        return b.r.handles.items.len - 1;
    }

    // Shorthands.
    pub fn konst(b: *Builder, ty: Type, v: u64) !Ref {
        return b.emit(.{ .op = .@"const", .ty = ty, .aux = v & ty.mask() });
    }
    pub fn getreg(b: *Builder, ty: Type, off: u64) !Ref {
        return b.emit(.{ .op = .getreg, .ty = ty, .aux = off });
    }
    pub fn setreg(b: *Builder, off: u64, v: Ref) !void {
        _ = try b.emit(.{ .op = .setreg, .a = v, .aux = off });
    }
    pub fn un(b: *Builder, op: Op, ty: Type, a: Ref) !Ref {
        return b.emit(.{ .op = op, .ty = ty, .a = a });
    }
    pub fn bin(b: *Builder, op: Op, ty: Type, x: Ref, y: Ref) !Ref {
        return b.emit(.{ .op = op, .ty = ty, .a = x, .b = y });
    }
    pub fn icmp(b: *Builder, p: Pred, x: Ref, y: Ref) !Ref {
        return b.emit(.{ .op = .icmp, .ty = .i1, .a = x, .b = y, .aux = @intFromEnum(p) });
    }
    pub fn flags(b: *Builder, op: Op, x: Ref, y: Ref) !Ref {
        return b.emit(.{ .op = op, .ty = .flags, .a = x, .b = y });
    }
    pub fn cond(b: *Builder, op: Op, f: Ref, cc: u4) !Ref {
        return b.emit(.{ .op = op, .ty = .i1, .a = f, .aux = cc });
    }
    pub fn load(b: *Builder, ty: Type, addr: Ref, f: MemFlags, pc: u64) !Ref {
        return b.emit(.{ .op = .load, .ty = ty, .a = addr, .aux = @bitCast(f), .aux2 = pc });
    }
    pub fn cas(b: *Builder, ty: Type, addr: Ref, expected: Ref, new: Ref, f: MemFlags, pc: u64) !Ref {
        return b.emit(.{ .op = .cas, .ty = ty, .a = addr, .b = expected, .c = new, .aux = @bitCast(f), .aux2 = pc });
    }
    pub fn store(b: *Builder, addr: Ref, v: Ref, f: MemFlags, pc: u64) !void {
        _ = try b.emit(.{ .op = .store, .a = addr, .b = v, .aux = @bitCast(f), .aux2 = pc });
    }
    pub fn interp(b: *Builder, h: u64, pc: u64) !void {
        const idx = try b.handle(h);
        _ = try b.emit(.{ .op = .@"call.interp", .aux = idx, .aux2 = pc });
    }
    pub fn poll(b: *Builder, pc: u64) !void {
        _ = try b.emit(.{ .op = .poll, .aux = pc });
    }
    /// Retires n instructions; the count for later exits starts again at 0.
    pub fn pendingFlags(b: *Builder, f: Ref, off: u64, group: FlagGroup) !void {
        _ = try b.emit(.{ .op = .@"pending.flags", .a = f, .aux = off, .aux2 = @intFromEnum(group) });
    }
    pub fn retire(b: *Builder, n: u64) !void {
        if (n != 0) _ = try b.emit(.{ .op = .retire, .aux = n });
        b.retired = 0;
    }
    pub fn br(b: *Builder, to: BlockId) !void {
        _ = try b.emit(.{ .op = .br, .aux = to });
    }
    pub fn brcond(b: *Builder, c: Ref, then: BlockId, els: BlockId) !void {
        _ = try b.emit(.{ .op = .brcond, .a = c, .aux = then, .aux2 = els });
    }
    pub fn exit(b: *Builder, op: Op, pc: u64) !void {
        _ = try b.emit(.{ .op = op, .aux = pc });
    }
    pub fn exitIndirect(b: *Builder, target: Ref) !void {
        _ = try b.emit(.{ .op = .@"exit.indirect", .a = target });
    }
};

// ---------------------------------------------------------------- verifier

pub const VerifyError = struct {
    block: BlockId,
    inst: u32,
    msg: []const u8,
};

/// Where flags may be pending: up to two slots (a region's lifter uses
/// one), or any slot once more have been seen.
const MayPend = struct {
    slots: [2]?u64 = .{ null, null },
    any: bool = false,

    fn add(m: *MayPend, off: u64) void {
        for (&m.slots) |*s| {
            if (s.* == off) return;
            if (s.* == null) {
                s.* = off;
                return;
            }
        }
        m.any = true;
    }
    fn merge(m: *MayPend, o: MayPend) bool {
        const before = m.*;
        if (o.any) m.any = true;
        for (o.slots) |s| if (s) |x| m.add(x);
        return !std.meta.eql(before, m.*);
    }
    fn hits(m: MayPend, off: u64, len: u64) bool {
        if (m.any) return true;
        for (m.slots) |s| if (s) |x| if (overlaps(off, len, x, 4)) return true;
        return false;
    }
    fn drop(m: *MayPend, off: u64, len: u64) void {
        if (m.any) return;
        for (&m.slots) |*s| if (s.*) |x| if (overlaps(off, len, x, 4)) {
            s.* = null;
        };
    }
};

/// The slots each block may start with flags pending at: pending.flags
/// stays pending across br and brcond (Op.@"pending.flags").
fn pendingIn(r: *const Region, out: []MayPend) void {
    @memset(out, .{});
    var changed = true;
    while (changed) {
        changed = false;
        for (r.blocks.items, 0..) |blk, bi| {
            if (!blk.begun or blk.len == 0) continue;
            var m = out[bi];
            const end = blk.start + blk.len;
            for (r.insts.items[blk.start..end]) |i| switch (i.op) {
                .@"pending.flags" => m = .{ .slots = .{ i.aux, null } },
                .setreg => if (i.a < r.insts.items.len) m.drop(i.aux, byteLen(r.insts.items[i.a].ty)),
                .@"call.interp", .@"call.helper", .copy => m = .{},
                .br => if (i.aux < out.len) {
                    changed = out[@intCast(i.aux)].merge(m) or changed;
                },
                .brcond => {
                    if (i.aux < out.len) changed = out[@intCast(i.aux)].merge(m) or changed;
                    if (i.aux2 < out.len) changed = out[@intCast(i.aux2)].merge(m) or changed;
                },
                else => {},
            };
        }
    }
}

/// Checks the region's structure and types. Returns null if it's valid.
pub fn verify(r: *const Region) ?VerifyError {
    if (r.blocks.items.len == 0) return .{ .block = 0, .inst = 0, .msg = "no blocks" };
    var in_buf: [2048]MayPend = undefined;
    if (r.blocks.items.len > in_buf.len) return .{ .block = 0, .inst = 0, .msg = "too many blocks to verify" };
    const pend_in = in_buf[0..r.blocks.items.len];
    pendingIn(r, pend_in);
    for (r.blocks.items, 0..) |blk, bi| {
        const b: BlockId = @intCast(bi);
        if (!blk.begun) return .{ .block = b, .inst = 0, .msg = "block never begun" };
        if (blk.len == 0) return .{ .block = b, .inst = 0, .msg = "empty block" };
        const end = blk.start + blk.len;
        var pending = pend_in[bi]; // where flags may be pending
        for (blk.start..end) |ii| {
            const idx: u32 = @intCast(ii);
            const i = &r.insts.items[ii];
            const last = ii == end - 1;
            if (i.op.isTerminator() != last)
                return .{ .block = b, .inst = idx, .msg = if (last) "block doesn't end in a terminator" else "terminator before the end of its block" };
            for (i.operands()) |o| {
                if (o == none) continue;
                if (o < blk.start or o >= idx) return .{ .block = b, .inst = idx, .msg = "operand not defined earlier in this block" };
                if (r.insts.items[o].ty == .none) return .{ .block = b, .inst = idx, .msg = "operand has no value" };
            }
            if (checkInst(r, i)) |msg| return .{ .block = b, .inst = idx, .msg = msg };
            switch (i.op) {
                .@"pending.flags" => pending = .{ .slots = .{ i.aux, null } },
                .setreg => pending.drop(i.aux, byteLen(r.insts.items[i.a].ty)),
                .getreg => if (pending.hits(i.aux, byteLen(i.ty)))
                    return .{ .block = b, .inst = idx, .msg = "getreg of a slot with flags pending" },
                .@"call.interp", .@"call.helper", .copy => pending = .{},
                else => {},
            }
            if (i.op == .load or i.op == .store) {
                const f: MemFlags = @bitCast(i.aux);
                if (f.same_page != 0) {
                    if (f.same_page > idx - blk.start) return .{ .block = b, .inst = idx, .msg = "same_page reaches before the block" };
                    if (r.insts.items[idx - f.same_page].op != i.op) return .{ .block = b, .inst = idx, .msg = "same_page must name an earlier access of the same op" };
                }
            }
        }
    }
    return null;
}

fn overlaps(a: u64, an: u64, b: u64, bn: u64) bool {
    return a < b + bn and b < a + an;
}

fn byteLen(t: Type) u64 {
    return @max(1, t.bits() / 8);
}

fn checkInst(r: *const Region, i: *const Inst) ?[]const u8 {
    const T = struct {
        fn of(reg: *const Region, ref: Ref) Type {
            return if (ref == none) .none else reg.insts.items[ref].ty;
        }
    };
    const ta = T.of(r, i.a);
    const tb = T.of(r, i.b);
    const tc = T.of(r, i.c);
    const nblocks = r.blocks.items.len;
    switch (i.op) {
        .@"const" => if (!i.ty.isInt() and i.ty != .flags) return "const of a non-integer type",
        .getreg => if (i.ty == .none or i.ty == .i1) return "getreg needs a value type",
        .setreg => if (ta == .none or ta == .i1) return "setreg needs a value",
        .add, .sub, .mul, .mulhu, .mulhs, .udiv, .sdiv, .urem, .srem, .@"and", .@"or", .xor, .andn, .shl, .lshr, .ashr, .ror, .rol => {
            if (!i.ty.isInt() or i.ty == .i1 and i.op != .@"and" and i.op != .@"or" and i.op != .xor) return "integer op of a non-integer type";
            if (ta != i.ty or tb != i.ty) return "operand types differ from the result";
        },
        .neg, .not, .clz, .ctz, .popcnt, .rbit, .bswap => {
            if (!i.ty.isInt() or ta != i.ty) return "unary op type mismatch";
        },
        .zext, .sext => if (!i.ty.isInt() or !ta.isInt() or ta.bits() > i.ty.bits()) return "extension must widen an integer",
        .trunc => if (!i.ty.isInt() or !ta.isInt() or ta.bits() < i.ty.bits()) return "trunc must narrow an integer",
        .select => if (ta != .i1 or tb != i.ty or tc != i.ty) return "select needs i1, and two operands of its type",
        .icmp => {
            if (i.ty != .i1) return "icmp gives i1";
            if (!ta.isInt() or ta != tb) return "icmp operands must be integers of one type";
            if (i.aux > @intFromEnum(Pred.sge)) return "bad predicate";
        },
        .@"nzcv.add", .@"nzcv.sub" => {
            if (i.ty != .flags) return "flags op gives flags";
            if ((ta != .i32 and ta != .i64) or ta != tb) return "nzcv operands must be i32 or i64, of one type";
        },
        .@"nzcv.adc", .@"nzcv.sbc" => {
            if (i.ty != .flags) return "flags op gives flags";
            if ((ta != .i32 and ta != .i64) or ta != tb or tc != .flags) return "nzcv carry ops take two ints and flags";
        },
        .@"nzcv.logic" => if (i.ty != .flags or (ta != .i32 and ta != .i64)) return "nzcv.logic takes an i32 or i64",
        .@"eflags.add", .@"eflags.sub" => {
            if (i.ty != .flags) return "flags op gives flags";
            if ((ta != .i8 and ta != .i16 and ta != .i32) or ta != tb) return "eflags operands must be i8, i16, or i32, of one type";
        },
        .@"eflags.shl", .@"eflags.shr", .@"eflags.mul" => {
            if (i.ty != .flags) return "flags op gives flags";
            if ((ta != .i8 and ta != .i16 and ta != .i32) or ta != tb) return "eflags operands must be i8, i16, or i32, of one type";
        },
        .@"eflags.adc", .@"eflags.sbb" => {
            if (i.ty != .flags) return "flags op gives flags";
            if ((ta != .i8 and ta != .i16 and ta != .i32) or ta != tb or tc != .flags) return "eflags carry ops take two ints and flags";
        },
        .@"eflags.logic" => if (i.ty != .flags or (ta != .i8 and ta != .i16 and ta != .i32)) return "eflags.logic takes an i8, i16, or i32",
        .@"eflags.inc", .@"eflags.dec" => if (i.ty != .flags or (ta != .i8 and ta != .i16 and ta != .i32) or tb != .flags) return "eflags.inc and dec take an int and flags",
        .@"nzcv.cond", .@"eflags.cond" => {
            if (i.ty != .i1 or ta != .flags) return "cond takes flags and gives i1";
            if (i.aux > 15) return "bad condition";
        },
        .@"nzcv.pack", .@"eflags.pack" => if (i.ty != .i32 or ta != .flags) return "pack takes flags and gives i32",
        .@"nzcv.unpack", .@"eflags.unpack" => if (i.ty != .flags or ta != .i32) return "unpack takes i32 and gives flags",
        .load => {
            if (ta != .i64 and ta != .i32) return "address must be i64 or i32";
            const f: MemFlags = @bitCast(i.aux);
            if (!i.ty.isInt() or i.ty == .i1) return "load gives an integer";
            if (f.size > 3 or f.bytes() * 8 > i.ty.bits()) return "load size doesn't fit its type";
        },
        .store => {
            if (ta != .i64 and ta != .i32) return "address must be i64 or i32";
            const f: MemFlags = @bitCast(i.aux);
            if (!tb.isInt() or tb == .i1) return "store takes an integer";
            if (f.rmw) return "rmw is for loads";
            if (f.size > 3 or f.bytes() * 8 > tb.bits()) return "store size doesn't fit its value";
        },
        .fence => if (i.aux > 2) return "bad fence kind",
        .cas => {
            if (ta != .i64 and ta != .i32) return "address must be i64 or i32";
            const f: MemFlags = @bitCast(i.aux);
            if (!i.ty.isInt() or i.ty == .i1) return "cas gives an integer";
            if (tb != i.ty or tc != i.ty) return "cas's expected and new values must be of its type";
            if (f.size > 3 or f.bytes() * 8 > i.ty.bits()) return "cas size doesn't fit its type";
            if (f.signed or f.rmw) return "cas takes neither signed nor rmw";
        },
        .@"call.interp" => if (i.aux >= r.handles.items.len) return "call.interp handle out of range",
        .@"call.helper" => if (i.ty != .none and i.ty != .i64) return "call.helper gives i64 or nothing",
        .poll, .retire => {},
        .@"pending.flags" => {
            if (ta != .flags) return "pending.flags takes flags";
            if (i.aux2 > 1) return "pending.flags's group is 0 (nzcv) or 1 (eflags)";
        },
        .copy => {
            if (i.aux >> 35 != 0) return "copy's aux has bits above 34";
            var d = i.aux2;
            for (0..4) |_| {
                const f: u16 = @truncate(d);
                if (f != 0 and f & 0x6000 == 0) return "copy maps a field it neither reads nor writes";
                d >>= 16;
            }
        },
        .br => if (i.aux >= nblocks) return "branch to a block that doesn't exist",
        .brcond => {
            if (ta != .i1) return "brcond needs an i1";
            if (i.aux >= nblocks or i.aux2 >= nblocks) return "branch to a block that doesn't exist";
        },
        .@"exit.indirect" => if (ta != .i64 and ta != .i32) return "exit.indirect needs an address",
        .@"exit.chain", .@"exit.svc", .@"exit.brk", .@"exit.undef" => {},
        else => if (checkExt(i, ta, tb, tc)) |msg| return msg,
    }
    if (i.retired != 0 and !i.op.canLeave()) return "only an op that can leave carries a retired count";
    if (i.op.hasResult()) {
        if (i.ty == .none and i.op != .@"call.helper") return "operation must have a result type";
    } else if (i.ty != .none) return "operation has no result";
    return null;
}

/// The verifier's rules for the `fp.*` and `v.*` ops.
fn checkExt(i: *const Inst, ta: Type, tb: Type, tc: Type) ?[]const u8 {
    const x = ExtAux.of(i.aux);
    const vec = i.ty == .v128 or ta == .v128;
    if (i.op.isFp()) {
        if (i.aux2 != 0 and i.aux2 - 1 > std.math.maxInt(i32)) return "bad exception word offset";
        if (vec) {
            if (x.esize == 0) return "FP lanes are 16, 32, or 64 bits";
            switch (i.op) {
                .@"fp.cvt" => {
                    const to: u3 = @as(u2, @truncate(x.imm));
                    const from: u3 = x.esize;
                    if (to == 0 or (to != from + 1 and to + 1 != from)) return "fp.cvt on v128 widens or narrows one step";
                    if (x.imm & ~@as(u16, 0x103) != 0) return "bad fp.cvt immediate";
                },
                .@"fp.cmp" => if (x.imm > 15) return "fp.cmp's order set is 4 bits",
                .@"fp.fromsint", .@"fp.fromuint", .@"fp.tosint", .@"fp.touint" => if (x.imm > x.bits()) return "too many fraction bits",
                else => {},
            }
            if (i.ty != .v128 or ta != .v128) return "a vector FP op takes and gives v128";
            if (tb != .none and tb != .v128 or tc != .none and tc != .v128) return "a vector FP op takes v128";
        } else switch (i.op) {
            .@"fp.cmp" => if (i.ty != .i8 or !isFloat(ta) or tb != ta) return "fp.cmp compares two FP values of one type, giving i8",
            .@"fp.cvt" => if (!isFloat(i.ty) or !isFloat(ta) or ta == i.ty) return "fp.cvt converts between FP types",
            .@"fp.fromsint", .@"fp.fromuint" => {
                if (!isFloat(i.ty) or (ta != .i32 and ta != .i64)) return "fp.from*int takes an i32 or i64";
                if (x.imm > ta.bits()) return "too many fraction bits";
            },
            .@"fp.tosint", .@"fp.touint" => {
                if ((i.ty != .i32 and i.ty != .i64) or !isFloat(ta)) return "fp.to*int gives an i32 or i64";
                if (x.imm > i.ty.bits()) return "too many fraction bits";
            },
            else => {
                if (!isFloat(i.ty) or ta != i.ty) return "an FP op takes and gives i16, i32, or i64";
                if (tb != .none and tb != i.ty or tc != .none and tc != i.ty) return "FP operands of different types";
            },
        }
        const want: u8 = switch (i.op) {
            .@"fp.sqrt", .@"fp.cvt", .@"fp.fromsint", .@"fp.fromuint", .@"fp.tosint", .@"fp.touint", .@"fp.round" => 1,
            .@"fp.fma" => 3,
            else => 2,
        };
        const have: u8 = @as(u8, @intFromBool(ta != .none)) + @intFromBool(tb != .none) + @intFromBool(tc != .none);
        if (have != want) return "wrong number of operands";
        return null;
    }
    const lane = laneType(x.esize);
    switch (i.op) {
        .@"v.make" => if (i.ty != .v128 or ta != .i64 or tb != .i64) return "v.make takes two i64s",
        .@"v.lane" => {
            if (i.ty != lane or ta != .v128) return "v.lane gives a lane of a v128";
            if (x.imm >= x.lanes()) return "lane out of range";
        },
        .@"v.ins" => {
            if (i.ty != .v128 or ta != .v128 or tb != lane) return "v.ins puts a lane into a v128";
            if (x.imm >= x.lanes()) return "lane out of range";
        },
        .@"v.dup" => if (i.ty != .v128 or ta != lane) return "v.dup takes a lane",
        .@"v.shl", .@"v.lshr", .@"v.ashr" => if (i.ty != .v128 or ta != .v128 or tb != .none) return "a vector shift takes a v128 and a count in imm",
        .@"v.narrow", .@"v.widen" => {
            if (i.ty != .v128 or ta != .v128 or tb != .none) return "v.narrow and v.widen take a v128";
            if (x.imm > 3) return "bad variant";
            if (if (i.op == .@"v.narrow") x.esize == 0 else x.esize == 3) return "bad lane size";
        },
        .@"v.load" => {
            if (i.ty != .v128 or (ta != .i64 and ta != .i32)) return "v.load gives a v128 from an address";
            const f: MemFlags = @bitCast(i.aux);
            if (f.size != 4 or f.signed or f.rmw) return "v.load is 16 bytes";
        },
        .@"v.store" => {
            if ((ta != .i64 and ta != .i32) or tb != .v128) return "v.store takes an address and a v128";
            const f: MemFlags = @bitCast(i.aux);
            if (f.size != 4 or f.signed or f.rmw) return "v.store is 16 bytes";
        },
        else => {
            if (i.ty != .v128 or ta != .v128 or tb != .v128) return "a vector op takes two v128s";
            switch (i.op) {
                .@"v.mul" => if (x.esize == 3) return "v.mul's lanes are 8 to 32 bits",
                .@"v.cmp" => if (x.imm > @intFromEnum(Pred.sge)) return "bad predicate",
                .@"v.ext" => if (x.imm > 15) return "v.ext's offset is 0 to 15",
                .@"v.zip", .@"v.uzp", .@"v.trn", .@"v.min", .@"v.max" => if (x.imm > 1) return "bad variant",
                else => {},
            }
        },
    }
    return null;
}

// ---------------------------------------------------------------- text

fn hasBlocks(op: Op) u8 {
    return switch (op) {
        .br => 1,
        .brcond => 2,
        else => 0,
    };
}

pub fn print(r: *const Region, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("region 0x{x}{s}\n", .{ r.entry_pc, if (r.tso) " tso" else "" });
    for (r.handles.items) |h| try w.print("handle 0x{x}\n", .{h});
    for (r.blocks.items, 0..) |blk, bi| {
        try w.print("b{d}:\n", .{bi});
        for (blk.start..blk.start + blk.len) |ii| {
            const i = r.insts.items[ii];
            try w.writeAll("  ");
            if (i.ty != .none) try w.print("%{d} = ", .{ii});
            try w.writeAll(i.op.name());
            if (i.ty != .none) try w.print(":{s}", .{@tagName(i.ty)});
            var first = true;
            for (i.operands()) |o| {
                if (o == none) continue;
                try w.print("{s}%{d}", .{ if (first) " " else ", ", o });
                first = false;
            }
            switch (hasBlocks(i.op)) {
                1 => try w.print(" -> b{d}", .{i.aux}),
                2 => try w.print(" -> b{d} b{d}", .{ i.aux, i.aux2 }),
                else => {
                    if (i.aux != 0) try w.print(" #0x{x}", .{i.aux});
                    if (i.aux2 != 0) try w.print(" @0x{x}", .{i.aux2});
                },
            }
            if (i.retired != 0) try w.print(" !{d}", .{i.retired});
            try w.writeByte('\n');
        }
    }
}

pub const ParseError = error{ Syntax, OutOfMemory };

/// Parses `print`'s text form. Value numbers in the text are names: they
/// needn't match instruction indexes, but must be defined before use.
/// Blocks are numbered by their labels and must all appear.
pub fn parse(gpa: Allocator, text: []const u8) ParseError!Region {
    var r: Region = .{ .entry_pc = 0 };
    errdefer r.deinit(gpa);
    var names: std.AutoHashMapUnmanaged(u64, Ref) = .empty;
    defer names.deinit(gpa);
    var b = Builder.init(gpa, &r);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, stripComment(raw), " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "region ")) {
            var rest = std.mem.trim(u8, line["region ".len..], " ");
            if (std.mem.endsWith(u8, rest, " tso")) {
                r.tso = true;
                rest = std.mem.trimEnd(u8, rest[0 .. rest.len - 4], " ");
            }
            r.entry_pc = try num(rest);
            continue;
        }
        if (std.mem.startsWith(u8, line, "handle ")) {
            _ = try b.handle(try num(line["handle ".len..]));
            continue;
        }
        if (line[0] == 'b' and line[line.len - 1] == ':') {
            if (b.cur != null) return error.Syntax;
            const id = std.fmt.parseInt(u32, line[1 .. line.len - 1], 10) catch return error.Syntax;
            while (r.blocks.items.len <= id) _ = try b.block();
            if (r.blocks.items[id].begun) return error.Syntax;
            b.begin(id);
            continue;
        }
        if (b.cur == null) return error.Syntax;
        var rest = line;
        var result_name: ?u64 = null;
        if (rest[0] == '%') {
            const eq = std.mem.indexOf(u8, rest, "=") orelse return error.Syntax;
            result_name = try num(std.mem.trim(u8, rest[1..eq], " "));
            rest = std.mem.trimStart(u8, rest[eq + 1 ..], " ");
        }
        const sp = std.mem.indexOfAny(u8, rest, " ") orelse rest.len;
        const head = rest[0..sp];
        rest = std.mem.trim(u8, rest[sp..], " ");
        var inst: Inst = .{ .op = .@"const" };
        const colon = std.mem.indexOfScalar(u8, head, ':');
        inst.op = std.meta.stringToEnum(Op, if (colon) |c| head[0..c] else head) orelse return error.Syntax;
        if (colon) |c| inst.ty = std.meta.stringToEnum(Type, head[c + 1 ..]) orelse return error.Syntax;
        if ((result_name != null) != (inst.ty != .none)) return error.Syntax;
        // Operands, then #aux, @aux2, or -> blocks.
        var ops: [3]Ref = .{ none, none, none };
        var nops: usize = 0;
        var toks = std.mem.tokenizeAny(u8, rest, " ,");
        var blocks: [2]u64 = .{ 0, 0 };
        var nblocks: usize = 0;
        var arrow = false;
        while (toks.next()) |t| {
            if (arrow) {
                if (t[0] != 'b' or nblocks == 2) return error.Syntax;
                blocks[nblocks] = std.fmt.parseInt(u32, t[1..], 10) catch return error.Syntax;
                nblocks += 1;
            } else if (t[0] == '%') {
                if (nops == 3) return error.Syntax;
                ops[nops] = names.get(try num(t[1..])) orelse return error.Syntax;
                nops += 1;
            } else if (t[0] == '#') {
                inst.aux = try num(t[1..]);
            } else if (t[0] == '@') {
                inst.aux2 = try num(t[1..]);
            } else if (t[0] == '!') {
                inst.retired = std.fmt.parseInt(u32, t[1..], 10) catch return error.Syntax;
            } else if (std.mem.eql(u8, t, "->")) {
                arrow = true;
            } else return error.Syntax;
        }
        if (nblocks != hasBlocks(inst.op)) return error.Syntax;
        if (nblocks >= 1) inst.aux = blocks[0];
        if (nblocks == 2) inst.aux2 = blocks[1];
        inst.a = ops[0];
        inst.b = ops[1];
        inst.c = ops[2];
        const ref = try b.emit(inst);
        if (result_name) |n| try names.put(gpa, n, ref);
    }
    if (b.cur != null) return error.Syntax;
    for (r.blocks.items) |blk| if (!blk.begun) return error.Syntax;
    return r;
}

fn stripComment(s: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, s, ';')) |i| s[0..i] else s;
}

fn num(s: []const u8) ParseError!u64 {
    return std.fmt.parseInt(u64, s, 0) catch error.Syntax;
}

// ---------------------------------------------------------------- tests

const example =
    \\region 0x1000
    \\b0:
    \\  %0 = getreg:i64 #0x8
    \\  %1 = const:i64 #0x1
    \\  %2 = sub:i64 %0, %1
    \\  setreg %2 #0x8
    \\  %4 = nzcv.sub:flags %0, %1
    \\  %5 = nzcv.cond:i1 %4 #0x1
    \\  brcond %5 -> b0 b1
    \\b1:
    \\  %7 = getreg:i64 #0x10
    \\  %8 = load:i64 %7 #0x3 @0x1010 !2
    \\  exit.chain #0x1010 !3
    \\
;

test "text form round-trips" {
    const gpa = std.testing.allocator;
    var r = try parse(gpa, example);
    defer r.deinit(gpa);
    try std.testing.expect(verify(&r) == null);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try print(&r, &out.writer);
    try std.testing.expectEqualStrings(example, out.written());
}

test "parse renames values" {
    const gpa = std.testing.allocator;
    var r = try parse(gpa,
        \\region 0x0
        \\b0:
        \\  %7 = const:i32 #0x3 ; a comment
        \\  %9 = add:i32 %7, %7
        \\  exit.indirect %9
    );
    defer r.deinit(gpa);
    try std.testing.expect(verify(&r) == null);
    try std.testing.expectEqual(@as(Ref, 0), r.insts.items[1].a);
}

test "the verifier rejects bad regions" {
    const gpa = std.testing.allocator;
    const bad = [_][]const u8{
        // a value from another block
        "b0:\n %0 = const:i64 #0x1\n br -> b1\nb1:\n exit.indirect %0\n",
        // mismatched operand types
        "b0:\n %0 = const:i64 #0x1\n %1 = const:i32 #0x1\n %2 = add:i64 %0, %1\n exit.chain\n",
        // no terminator
        "b0:\n %0 = const:i64 #0x1\nb1:\n exit.chain\n",
        // a branch to nowhere
        "b0:\n br -> b5\n",
        // cond on a non-flags value
        "b0:\n %0 = const:i64 #0x1\n %1 = nzcv.cond:i1 %0 #0x0\n exit.chain\n",
        // load too wide for its type
        "b0:\n %0 = const:i64 #0x1\n %1 = load:i32 %0 #0x3\n exit.chain\n",
        // call.interp without a handle
        "b0:\n call.interp\n exit.chain\n",
    };
    for (bad) |text| {
        var r = parse(gpa, text) catch continue; // some fail to parse, which is fine
        defer r.deinit(gpa);
        try std.testing.expect(verify(&r) != null);
    }
}

test "pending flags cross br and brcond" {
    const gpa = std.testing.allocator;
    const head = "b0:\n %0 = const:i32 #0x1\n %1 = nzcv.logic:flags %0\n pending.flags %1 #0x30\n";
    const cases = [_]struct { text: []const u8, ok: bool }{
        // read in a successor while pending: rejected
        .{ .text = head ++ " br -> b1\nb1:\n %2 = getreg:i32 #0x30\n exit.indirect %2\n", .ok = false },
        // ...through a block that doesn't touch it, and around a loop
        .{ .text = head ++ " br -> b1\nb1:\n %2 = const:i1 #0x1\n brcond %2 -> b1 b2\nb2:\n %3 = getreg:i32 #0x30\n exit.indirect %3\n", .ok = false },
        // written exactly on one way in only: still may be pending
        .{ .text = head ++ " %2 = const:i1 #0x1\n brcond %2 -> b1 b2\nb1:\n %3 = const:i32 #0x0\n setreg %3 #0x30\n br -> b2\nb2:\n %4 = getreg:i32 #0x30\n exit.indirect %4\n", .ok = false },
        // a setreg in the successor, or a call, ends it
        .{ .text = head ++ " br -> b1\nb1:\n %2 = const:i32 #0x0\n setreg %2 #0x30\n %3 = getreg:i32 #0x30\n exit.indirect %3\n", .ok = true },
        // another slot is fine
        .{ .text = head ++ " br -> b1\nb1:\n %2 = getreg:i32 #0x40\n exit.indirect %2\n", .ok = true },
    };
    for (cases) |c| {
        var r = try parse(gpa, c.text);
        defer r.deinit(gpa);
        try std.testing.expectEqual(c.ok, verify(&r) == null);
    }
}

test "op numbers are stable" {
    // Ops are append-only: these must never change.
    try std.testing.expectEqual(@as(u16, 0), @intFromEnum(Op.@"const"));
    try std.testing.expectEqual(@as(u16, 16), @intFromEnum(Op.add));
    try std.testing.expectEqual(@as(u16, 64), @intFromEnum(Op.@"nzcv.add"));
    try std.testing.expectEqual(@as(u16, 96), @intFromEnum(Op.@"eflags.add"));
    try std.testing.expectEqual(@as(u16, 108), @intFromEnum(Op.@"eflags.mul"));
    try std.testing.expectEqual(@as(u16, 128), @intFromEnum(Op.load));
    try std.testing.expectEqual(@as(u16, 131), @intFromEnum(Op.cas));
    try std.testing.expectEqual(@as(u16, 162), @intFromEnum(Op.copy));
    try std.testing.expectEqual(@as(u16, 178), @intFromEnum(Op.@"pending.flags"));
    try std.testing.expectEqual(@as(u16, 160), @intFromEnum(Op.@"call.interp"));
    try std.testing.expectEqual(@as(u16, 192), @intFromEnum(Op.br));
    try std.testing.expectEqual(@as(u16, 224), @intFromEnum(Op.@"fp.add"));
    try std.testing.expectEqual(@as(u16, 240), @intFromEnum(Op.@"fp.round"));
    try std.testing.expectEqual(@as(u16, 256), @intFromEnum(Op.@"v.make"));
    try std.testing.expectEqual(@as(u16, 281), @intFromEnum(Op.@"v.store"));
}

test "tso round-trips" {
    const gpa = std.testing.allocator;
    const text = "region 0x10 tso\nb0:\n  exit.chain #0x10\n";
    var r = try parse(gpa, text);
    defer r.deinit(gpa);
    try std.testing.expect(r.tso);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try print(&r, &out.writer);
    try std.testing.expectEqualStrings(text, out.written());
}
