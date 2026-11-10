//! h86's register file: the general registers, EIP, EFLAGS (lazy), the
//! segment selectors with their bases, and the x87, MMX, and SSE state,
//! with conversions to and from the vmm layer's Ureg and FXSAVE image.
//!
//! Segments are flat. CS, DS, ES, and SS have base 0 whatever they hold.
//! FS and GS have a base from the selector table (`segBase`), which holds
//! the null selector, 9front's user selectors, and Linux's three TLS
//! entries, 6 to 8, whose bases set_thread_area sets (`tls`).

const std = @import("std");
const flags = @import("flags.zig");
const sf = @import("f80.zig");

pub const Seg = @import("decode.zig").Seg;

/// 9front's user code and data selectors (pc/mem.h UESEL and UDSEL), as
/// src/arch/i386.zig has them. This module doesn't import that file, so
/// it builds as a module of its own (src/vcpu.zig).
pub const uesel: u16 = (4 << 3) | 3;
pub const udsel: u16 = (3 << 3) | 3;

/// Linux's first TLS selector: GDT entry 6, RPL 3, which libc takes for
/// %gs. Entries 7 and 8 follow it; 32-bit Wine takes one for %fs.
pub const tls_entry = 6;
pub const tls_entries = 3;
pub const tls_sel: u16 = (tls_entry << 3) | 3;

/// The x87 FPU, by physical register: ST(i) is `st[(top + i) & 7]`.
pub const Fpu = struct {
    st: [8]sf.F80 = @splat(sf.F80.zero),
    top: u3 = 0,
    /// Control word: FNINIT's 0x037F, everything masked, extended
    /// precision, round to nearest.
    cw: u16 = 0x037f,
    /// Status word, without TOP (bits 11-13), which is `top`.
    sw: u16 = 0,
    /// Abridged tag word, as FXSAVE keeps it: bit i set when physical
    /// register i isn't empty.
    tag: u8 = 0,
    /// The last non-control instruction's opcode (11 bits) and its
    /// instruction and operand pointers, as FXSAVE stores them.
    fop: u16 = 0,
    fip: u64 = 0,
    fdp: u64 = 0,
};

/// Why `exec.run` returned.
pub const Exit = union(enum) {
    /// INT $64 or INT 0x80, with the vector; EIP is past it.
    syscall: u8,
    /// INT3; EIP is past it.
    breakpoint,
    /// A page fault: EIP is at the instruction, which can be restarted.
    fault: struct { addr: u32, access: Access },
    /// Any other exception, by vector (#DE 0, #OF 4, #BR 5, #UD 6, #GP 13,
    /// #MF 16, #XM 19). EIP is at the instruction, but for #OF (INTO),
    /// which is a trap and leaves it past.
    exception: u8,
    /// A stop request or the end of the budget, between instructions.
    stopped,
};

pub const Access = enum(u8) { read = 0, write = 1, exec = 2 };

/// Exception vectors.
pub const vec_de = 0;
pub const vec_bp = 3;
pub const vec_of = 4;
pub const vec_br = 5;
pub const vec_ud = 6;
pub const vec_gp = 13;
pub const vec_pf = 14;
pub const vec_mf = 16;
pub const vec_xm = 19;

pub const Cpu = struct {
    /// EAX, ECX, EDX, EBX, ESP, EBP, ESI, EDI, in encoding order.
    r: [8]u32 = @splat(0),
    eip: u32 = 0,
    fl: flags.Flags = .{},
    /// ES, CS, SS, DS, FS, GS.
    seg: [6]u16 = .{ udsel, uesel, udsel, udsel, 0, 0 },
    /// Each segment's base, from the selector table: zero but for FS and
    /// GS holding a TLS selector.
    seg_base: [6]u32 = @splat(0),
    /// Segments holding the null selector, which fault on use.
    seg_null: u8 = (1 << 4) | (1 << 5),
    /// The bases of Linux's TLS entries 6 to 8 (X86Extra.tls and
    /// X86Extra.tls_more).
    tls: [tls_entries]u32 = @splat(0),
    /// Which TLS entries set_thread_area has given out (X86Extra.tls_used).
    tls_used: u8 = 0,
    fpu: Fpu = .{},
    xmm: [8]u128 = @splat(0),
    mxcsr: u32 = 0x1f80,
    /// Ureg.trap and Ureg.ecode, as the last exit left them.
    trap: u32 = 0,
    ecode: u32 = 0,
    /// Lifted code's scratch word, for a value that must cross one of its
    /// guards (blocks share no values): nothing else reads it.
    jit_tmp: u32 = 0,
    /// Guest instructions retired.
    retired: u64 = 0,
    /// T0's decoded-instruction cache, which the owner allocates.
    icache: ?*@import("exec.zig").ICache = null,
    /// T0's decode cache by page, used where memory tracks code, which the
    /// owner allocates.
    pages: ?*@import("exec.zig").PageCache = null,

    pub inline fn esp(c: *const Cpu) u32 {
        return c.r[4];
    }

    /// The registers as a 9front Ureg: `u` is a *arch/i386.zig Ureg (taken
    /// as anytype, as getExtra's is).
    pub fn getUreg(c: *const Cpu, u: anytype) void {
        u.ax = c.r[0];
        u.cx = c.r[1];
        u.dx = c.r[2];
        u.bx = c.r[3];
        u.sp = c.r[4];
        u.bp = c.r[5];
        u.si = c.r[6];
        u.di = c.r[7];
        u.pc = c.eip;
        u.flags = c.fl.get();
        u.es = c.seg[0];
        u.cs = c.seg[1];
        u.ss = c.seg[2];
        u.ds = c.seg[3];
        u.fs = c.seg[4];
        u.gs = c.seg[5];
        u.trap = c.trap;
        u.ecode = c.ecode;
    }

    /// Loads the registers from a Ureg. A selector the table doesn't hold
    /// becomes null, as the emulator backend does with GS.
    pub fn setUreg(c: *Cpu, u: anytype) void {
        c.r = .{ u.ax, u.cx, u.dx, u.bx, u.sp, u.bp, u.si, u.di };
        c.eip = u.pc;
        c.fl.set(u.flags);
        c.trap = u.trap;
        c.ecode = u.ecode;
        const sels = [6]u32{ u.es, u.cs, u.ss, u.ds, u.fs, u.gs };
        for (sels, 0..) |s, i| {
            const seg: Seg = @enumFromInt(i);
            const sel: u16 = @truncate(s);
            if (seg == .cs or seg == .ss) {
                c.seg[i] = sel;
                continue;
            }
            if (c.loadSeg(seg, sel)) |_| {} else |_| _ = c.loadSeg(seg, 0) catch unreachable;
        }
    }

    /// The x87, MMX, and SSE state as an FXSAVE image, and the TLS base:
    /// `x` is a *vmm.X86Extra (taken as anytype so the interpreter builds
    /// without the vmm layer, as src/vcpu.zig does).
    pub fn getExtra(c: *const Cpu, x: anytype) void {
        x.* = .{};
        const fx = &x.fx;
        const p = &c.fpu;
        fx.fcw = p.cw;
        fx.fsw = (p.sw & ~@as(u16, 0x3800)) | (@as(u16, p.top) << 11);
        fx.ftw = p.tag;
        fx.fop = p.fop;
        fx.fip = p.fip;
        fx.fdp = p.fdp;
        fx.mxcsr = c.mxcsr;
        fx.mxcsr_mask = 0xffff;
        for (&fx.st, 0..) |*st, i| {
            const v = p.st[(@as(usize, p.top) + i) & 7];
            std.mem.writeInt(u64, st[0..8], v.signif, .little);
            std.mem.writeInt(u16, st[8..10], v.sign_exp, .little);
        }
        @memcpy(fx.xmm[0..8], &c.xmm);
        x.tls = c.tls[0];
        for (&x.tls_more, c.tls[1..]) |*d, b| d.* = b;
        x.tls_used = c.tls_used;
    }

    pub fn setExtra(c: *Cpu, x: anytype) void {
        const fx = &x.fx;
        const p = &c.fpu;
        p.cw = fx.fcw;
        p.top = @truncate(fx.fsw >> 11);
        p.sw = fx.fsw & ~@as(u16, 0x3800);
        p.tag = fx.ftw;
        p.fop = fx.fop;
        p.fip = fx.fip;
        p.fdp = fx.fdp;
        // MXCSR's reserved bits would fault FXRSTOR; keep them clear.
        c.mxcsr = fx.mxcsr & 0xffff;
        for (&fx.st, 0..) |*st, i| {
            p.st[(@as(usize, p.top) + i) & 7] = .{
                .signif = std.mem.readInt(u64, st[0..8], .little),
                .sign_exp = std.mem.readInt(u16, st[8..10], .little),
            };
        }
        @memcpy(&c.xmm, fx.xmm[0..8]);
        c.setTls(@truncate(x.tls));
        for (x.tls_more, 1..) |b, i| c.setTlsEntry(i, @truncate(b));
        c.tls_used = x.tls_used;
    }

    /// Sets the first TLS entry's base (entry 6).
    pub fn setTls(c: *Cpu, base: u32) void {
        c.setTlsEntry(0, base);
    }

    /// Sets TLS entry `tls_entry + i`'s base, and the base of FS or GS if
    /// either holds its selector.
    pub fn setTlsEntry(c: *Cpu, i: usize, base: u32) void {
        c.tls[i] = base;
        const idx = tls_entry + i;
        for ([_]Seg{ .fs, .gs }) |s| {
            if (c.seg[@intFromEnum(s)] >> 3 == idx and c.seg[@intFromEnum(s)] & 4 == 0) c.seg_base[@intFromEnum(s)] = base;
        }
    }

    /// What loading `sel` into a data segment register gives: its base,
    /// or null for the null selector. Anything the table doesn't hold is
    /// a protection fault.
    fn segBase(c: *const Cpu, seg: Seg, sel: u16) error{GP}!?u32 {
        const idx = sel >> 3;
        // The LDT, and descriptors more privileged than the selector's RPL
        // allows, aren't there.
        if (sel & 4 != 0) return error.GP;
        if (idx == 0) return if (seg == .ss) error.GP else null;
        if (idx == udsel >> 3) return 0;
        if (idx >= tls_entry and idx < tls_entry + tls_entries and seg != .ss) return c.tls[idx - tls_entry];
        return error.GP;
    }

    /// MOV, POP, or LDS-style load of a data segment register.
    pub fn loadSeg(c: *Cpu, seg: Seg, sel: u16) error{GP}!void {
        if (seg == .cs) return error.GP;
        // SS needs RPL 3, as CPL is.
        if (seg == .ss and sel & 3 != 3) return error.GP;
        const base = try c.segBase(seg, sel);
        const i = @intFromEnum(seg);
        c.seg[i] = sel;
        c.seg_base[i] = base orelse 0;
        const bit = @as(u8, 1) << @intCast(i);
        if (base == null) c.seg_null |= bit else c.seg_null &= ~bit;
    }
};

/// arch/i386.zig's Ureg's fields, for the tests.
const TestUreg = struct {
    di: u32 = 0,
    si: u32 = 0,
    bp: u32 = 0,
    nsp: u32 = 0,
    bx: u32 = 0,
    dx: u32 = 0,
    cx: u32 = 0,
    ax: u32 = 0,
    gs: u32 = 0,
    fs: u32 = 0,
    es: u32 = 0,
    ds: u32 = 0,
    trap: u32 = 0,
    ecode: u32 = 0,
    pc: u32 = 0,
    cs: u32 = 0,
    flags: u32 = 0,
    sp: u32 = 0,
    ss: u32 = 0,
};

test "Ureg round trip" {
    var c: Cpu = .{};
    var u: TestUreg = .{ .pc = 0x1020, .sp = 0xdfffef00, .ax = 0xdffffe00, .cs = uesel, .ss = udsel, .ds = udsel, .es = udsel };
    u.bx = 7;
    u.flags = 0x246;
    c.setUreg(&u);
    try std.testing.expectEqual(@as(u32, 0xdffffe00), c.r[0]);
    var v: TestUreg = .{};
    c.getUreg(&v);
    try std.testing.expectEqual(u, v);
}

test "the TLS selector gives GS its base" {
    var c: Cpu = .{};
    c.setTls(0x1000);
    try c.loadSeg(.gs, tls_sel);
    try std.testing.expectEqual(@as(u32, 0x1000), c.seg_base[5]);
    c.setTls(0x2000);
    try std.testing.expectEqual(@as(u32, 0x2000), c.seg_base[5]);
    try std.testing.expectError(error.GP, c.loadSeg(.gs, 0x2b));
    try std.testing.expectError(error.GP, c.loadSeg(.gs, (9 << 3) | 3));
    try std.testing.expectError(error.GP, c.loadSeg(.ss, 0));
    try c.loadSeg(.gs, 0);
    try std.testing.expect(c.seg_null & (1 << 5) != 0);
}

/// vmm.X86Extra's shape, for the test.
const TestExtra = struct {
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
    tls_more: [2]u64 = @splat(0),
    tls_used: u8 = 0,
};

test "FXSAVE image round trip" {
    var c: Cpu = .{};
    var x: TestExtra = .{ .fx = .{ .fcw = 0x37f } };
    x.fx.fsw = 5 << 11;
    x.fx.st[0] = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 0, 0, 0, 0, 0, 0 };
    x.fx.ftw = 0x20;
    x.fx.xmm[3] = 0x1234;
    x.fx.mxcsr = 0x7f80;
    x.tls = 0x5000;
    x.tls_more = .{ 0x6000, 0x7000 };
    x.tls_used = 3;
    c.setExtra(&x);
    try std.testing.expectEqual(@as(u3, 5), c.fpu.top);
    try std.testing.expectEqual(@as(u64, 0x0807060504030201), c.fpu.st[5].signif);
    var y: TestExtra = .{};
    c.getExtra(&y);
    x.fx.mxcsr_mask = 0xffff;
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&x.fx), std.mem.asBytes(&y.fx));
    try std.testing.expectEqual(x.tls, y.tls);
    try std.testing.expectEqual(x.tls_more, y.tls_more);
    try std.testing.expectEqual(x.tls_used, y.tls_used);
}

test "each TLS entry has its own base, as 32-bit Wine's %fs and libc's %gs" {
    var c: Cpu = .{};
    c.setTls(0x1000);
    c.setTlsEntry(1, 0x2000);
    try c.loadSeg(.gs, tls_sel);
    try c.loadSeg(.fs, tls_sel + 8);
    try std.testing.expectEqual(@as(u32, 0x1000), c.seg_base[5]);
    try std.testing.expectEqual(@as(u32, 0x2000), c.seg_base[4]);
    c.setTlsEntry(1, 0x3000);
    try std.testing.expectEqual(@as(u32, 0x3000), c.seg_base[4]);
    try std.testing.expectEqual(@as(u32, 0x1000), c.seg_base[5]);
    try c.loadSeg(.fs, tls_sel + 16);
    try std.testing.expectEqual(@as(u32, 0), c.seg_base[4]);
}
