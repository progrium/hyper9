//! Verbatim copies for ha64 on arm64 hosts: a guest instruction that
//! touches only registers runs on the host as itself, as an IR `copy` op
//! whose register fields the emitter rewrites to the host registers the
//! allocator pinned the guest's to (ir.zig, Op.copy).
//!
//! `plan` decides whether an instruction qualifies and builds the op's
//! field descriptors. It qualifies if it doesn't touch memory, branch,
//! read the PC (ADR, ADRP), or touch system state, and if every register
//! its read and write sets name comes from one of the four register
//! fields (Rd, Rn, Rm, Ra): no register lists, no implicit registers.
//!
//! Which fields are registers is found by probing the decoder: a field is
//! a register field if putting an unused register number in it puts that
//! register in the read or write set, which also gives its role (read,
//! written, general or vector). Register 31 in a general field is SP if
//! the instruction's sets name SP, else ZR, which needs no mapping: the
//! host's 31 is its own ZR.
//!
//! The emitter side: on arm64 hosts only (`enabled`); ir_eval runs a copy
//! as call.interp on the word, so the region check covers it everywhere.

const std = @import("std");
const builtin = @import("builtin");
const ir = @import("../ir.zig");
const lift = @import("lift.zig");
const dec = @import("../../interp/a64/decode.zig");
const sd = @import("../../interp/a64/simd_decode.zig");
const t0 = @import("../../interp/a64/exec.zig");

const Cpu = t0.Cpu;
const L = lift.L;

/// Whether the lifter emits copies: on arm64 hosts, whose emitter runs
/// them natively. Elsewhere a copy is a call into T0, slower than the
/// lifted ops, so it stays off; fuzz-a64 turns it on (H9_FUZZ_COPY=1) to
/// check the plans on ir_eval.
pub var enabled: bool = builtin.cpu.arch == .aarch64;

/// Whether FP and saturating instructions (aux bit 34) are copied. The
/// arm64 emitter runs those through T0 until it carries the guest's FPCR
/// and FPSR natively, so until then lift_simd.zig's ops serve them better.
pub var fp: bool = false;

pub const Plan = struct {
    aux: u64,
    aux2: u64,
    /// The general register slots it writes.
    gp_written: u64,
};

/// The word bit each field starts at: Rd, Rn, Rm, Ra.
const field_lo = [4]u5{ 0, 5, 16, 10 };

const reads_nzcv: u64 = 1 << 32;
const writes_nzcv: u64 = 1 << 33;
const fp_bit: u64 = 1 << 34;

const D_READ: u16 = 1 << 13;
const D_WRITE: u16 = 1 << 14;
const D_V: u16 = 1 << 15;

fn fieldOf(w: u32, f: usize) u32 {
    return (w >> field_lo[f]) & 31;
}

fn withField(w: u32, f: usize, v: u32) u32 {
    return (w & ~(@as(u32, 31) << field_lo[f])) | v << field_lo[f];
}

fn gpOff(slot: u8) u16 {
    return @intCast(@offsetOf(Cpu, "r") + @as(usize, slot) * 8);
}

fn vOff(n: u32) u16 {
    return @intCast(@offsetOf(Cpu, "v") + @as(usize, n) * 16);
}

/// Whether a FP/SIMD kind runs under FPCR or writes FPSR (its exceptions,
/// or QC).
fn touchesFp(k: sd.Kind) bool {
    const name = @tagName(k);
    if (std.mem.startsWith(u8, name, "f_") or std.mem.startsWith(u8, name, "vf_")) {
        return switch (k) {
            // Bit moves: no FPCR, no exceptions.
            .f_mov, .f_abs, .f_neg, .f_mov_i, .f_mov_tog, .f_mov_fromg, .f_csel, .vf_abs, .vf_neg => false,
            else => true,
        };
    }
    return std.mem.startsWith(u8, name, "sq") or std.mem.startsWith(u8, name, "uq") or k == .suqadd or k == .usqadd;
}

/// The copy op for instruction `w`, or null if it doesn't qualify.
pub fn plan(w: u32, o: dec.Op) ?Plan {
    if (o.k == .undef or o.k == .next_page) return null;
    if (w & 0x1f00_0000 == 0x1000_0000) return null; // ADR, ADRP
    // TBL and TBX of more than one register: the list must be consecutive
    // registers, which a field rewrite can't keep.
    if (o.k.isSimd()) switch (sd.ofKind(o.k)) {
        .tbl, .tbx => if (o.a != 0) return null,
        else => {},
    };
    const r = dec.regs(o);
    if (r.mem != .none or r.ctrl != .none or r.system) return null;
    const sp_bit: u64 = 1 << dec.SP;
    const gp_mask: u64 = (1 << 31) - 1;

    // A probe value no field holds and no set names.
    var used: u64 = r.read | r.write | r.vread | r.vwrite;
    for (0..4) |f| used |= @as(u64, 1) << @intCast(fieldOf(w, f));
    var t: u32 = 0;
    while (t < 31 and (used >> @intCast(t)) & 1 == 1) t += 1;
    if (t >= 31) return null;
    const tb: u64 = @as(u64, 1) << @intCast(t);

    var desc: [4]u16 = @splat(0);
    var got_read: u64 = 0;
    var got_write: u64 = 0;
    var got_vread: u32 = 0;
    var got_vwrite: u32 = 0;
    var sp_fields: u32 = 0;
    for (0..4) |f| {
        const p = dec.decode(withField(w, f, t), 0);
        if (p.k == .undef) continue;
        const pr = dec.regs(p);
        const gr = pr.read & tb != 0;
        const gw = pr.write & tb != 0;
        const vr = pr.vread & @as(u32, @truncate(tb)) != 0;
        const vw = pr.vwrite & @as(u32, @truncate(tb)) != 0;
        if (!(gr or gw or vr or vw)) continue;
        if ((gr or gw) and (vr or vw)) return null;
        const rv = fieldOf(w, f);
        if (vr or vw) {
            desc[f] = vOff(rv) | D_V | (if (vr) D_READ else 0) | (if (vw) D_WRITE else 0);
            if (vr) got_vread |= @as(u32, 1) << @intCast(rv);
            if (vw) got_vwrite |= @as(u32, 1) << @intCast(rv);
            continue;
        }
        var slot: u8 = @intCast(rv);
        if (rv == 31) {
            if ((r.read | r.write) & sp_bit == 0) continue; // ZR: the host's own
            slot = dec.SP;
            sp_fields += 1;
        }
        desc[f] = gpOff(slot) | (if (gr) D_READ else 0) | (if (gw) D_WRITE else 0);
        if (gr) got_read |= @as(u64, 1) << @intCast(slot);
        if (gw) got_write |= @as(u64, 1) << @intCast(slot);
    }
    // Two fields of 31 when one is SP: which is which is the encoding's.
    if (sp_fields > 1) return null;
    // Every register the instruction names came from a field.
    if (r.read & (gp_mask | sp_bit) != got_read or r.write & (gp_mask | sp_bit) != got_write) return null;
    if (r.vread != got_vread or r.vwrite != got_vwrite) return null;

    var aux: u64 = w;
    if (r.flags == .r or r.flags == .rw) aux |= reads_nzcv;
    if (r.flags == .w or r.flags == .rw) aux |= writes_nzcv;
    if (o.k.isSimd() and touchesFp(sd.ofKind(o.k))) {
        if (!fp) return null;
        aux |= fp_bit;
    }
    var aux2: u64 = 0;
    for (desc, 0..) |d, f| aux2 |= @as(u64, d) << @intCast(16 * f);
    return .{ .aux = aux, .aux2 = aux2, .gp_written = got_write };
}

/// Emits the copy into l's block, keeping l's register and flag caches
/// right around it.
pub fn emit(l: *L, p: Plan) !void {
    const b = l.b;
    if (p.aux & (reads_nzcv | writes_nzcv) != 0) try l.flags.sync(b);
    _ = try b.emit(.{ .op = .copy, .aux = p.aux, .aux2 = p.aux2 });
    if (p.aux & writes_nzcv != 0) l.flags.clobber();
    for (0..dec.nslots) |s| {
        if (p.gp_written >> @intCast(s) & 1 == 1) l.regs[s] = null;
    }
}

const testing = std.testing;

test "plans: fields, ZR, SP, and what doesn't qualify" {
    // add x1, x2, x3
    const p = plan(0x8b030041, dec.decode(0x8b030041, 0)).?;
    try testing.expectEqual(@as(u64, 0x8b030041), p.aux);
    try testing.expectEqual(gpOff(1) | D_WRITE, @as(u16, @truncate(p.aux2)));
    try testing.expectEqual(gpOff(2) | D_READ, @as(u16, @truncate(p.aux2 >> 16)));
    try testing.expectEqual(gpOff(3) | D_READ, @as(u16, @truncate(p.aux2 >> 32)));
    try testing.expectEqual(@as(u16, 0), @as(u16, @truncate(p.aux2 >> 48)));
    // mov x0, x1 (orr x0, xzr, x1): ZR's field unmapped
    const m = plan(0xaa0103e0, dec.decode(0xaa0103e0, 0)).?;
    try testing.expectEqual(@as(u16, 0), @as(u16, @truncate(m.aux2 >> 16)));
    // add sp, sp, #16: both fields SP? Rd and Rn are both 31: bail.
    try testing.expectEqual(@as(?Plan, null), plan(0x910043ff, dec.decode(0x910043ff, 0)));
    // add x0, sp, #16: Rn is SP
    const s = plan(0x910043e0, dec.decode(0x910043e0, 0)).?;
    try testing.expectEqual(gpOff(dec.SP) | D_READ, @as(u16, @truncate(s.aux2 >> 16)));
    // subs x0, x1, x2: writes NZCV
    try testing.expect(plan(0xeb020020, dec.decode(0xeb020020, 0)).?.aux & writes_nzcv != 0);
    // ldr x0, [x1], adr x0, ., and b .: no
    try testing.expectEqual(@as(?Plan, null), plan(0xf9400020, dec.decode(0xf9400020, 0)));
    try testing.expectEqual(@as(?Plan, null), plan(0x10000000, dec.decode(0x10000000, 0x1000)));
    try testing.expectEqual(@as(?Plan, null), plan(0x14000000, dec.decode(0x14000000, 0)));
    // fadd d0, d1, d2: V fields and FP, when FP is copied
    const fp_was = fp;
    defer fp = fp_was;
    fp = true;
    const fa = plan(0x1e622820, dec.decode(0x1e622820, 0)).?;
    try testing.expect(fa.aux & fp_bit != 0);
    try testing.expectEqual(vOff(0) | D_V | D_WRITE, @as(u16, @truncate(fa.aux2)));
    // madd x0, x1, x2, x3: Ra mapped
    const ma = plan(0x9b020c20, dec.decode(0x9b020c20, 0)).?;
    try testing.expectEqual(gpOff(3) | D_READ, @as(u16, @truncate(ma.aux2 >> 48)));
    // tbl v0.16b, {v1.16b, v2.16b}, v3.16b: a register list, no
    try testing.expectEqual(@as(?Plan, null), plan(0x4e032020, dec.decode(0x4e032020, 0)));
    // tbx v0.16b, {v31.16b, v0.16b}, v2.16b: no, though the list wraps
    // onto the fields' registers
    try testing.expectEqual(@as(?Plan, null), plan(0x4e0233e0, dec.decode(0x4e0233e0, 0)));
    // mul v0.8h, v1.8h, v2.h[0] and h[1]: Rm is 4 bits with M an index bit; copied
    // only with M clear, so the 5-bit field is the register
    try testing.expect(plan(0x4f428020, dec.decode(0x4f428020, 0)) != null);
    try testing.expectEqual(@as(?Plan, null), plan(0x4f528020, dec.decode(0x4f528020, 0)));
}
