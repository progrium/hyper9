//! ha64's T0: the A64 interpreter, over decode.zig's micro-ops.
//!
//! Executable pages are decoded once, on first fetch, into 1024 ops and a
//! sentinel (`Cache`). Each kind has its own small handler function, found
//! through a table, so no one function holds the whole instruction set:
//! wasm engines reject a function with that many locals, and optimizing one
//! takes minutes.
//!
//! Guest memory goes through the per-vCPU software TLB in src/interp/mem.zig,
//! the same one generated code checks inline, and on a miss through
//! `mem.probe` over the View in ctx.space. The core uses no OS services:
//! the caller hands it the Ctx (TLB, address space, and exit-request word)
//! and the clock.

const std = @import("std");
const builtin = @import("builtin");
pub const dec = @import("decode.zig");
const mem = @import("../mem.zig");
const simd_exec = @import("simd_exec.zig");
const Ctx = @import("../../jit/ctx.zig").Ctx;

const Kind = dec.Kind;
const Op = dec.Op;
const ZR = dec.ZR;
const SP = dec.SP;
pub const page_size = mem.page_size;
const ops_per_page = page_size / 4;

// ---------------------------------------------------------------- state

pub const Monitor = struct {
    valid: bool = false,
    addr: u64 = 0,
    /// Bytes: 1, 2, 4, or 8, or 8 and 16 for the pairs.
    size: u8 = 0,
    lo: u64 = 0,
    hi: u64 = 0,
};

pub const Cpu = struct {
    /// See decode.zig: X0-X30, ZR (always 0), the ZR sink, and SP.
    r: [dec.nslots]u64 = @splat(0),
    pc: u64 = 0,
    /// N Z C V in bits 31..28, as PSTATE and the NZCV register have them.
    nzcv: u32 = 0,
    fpcr: u32 = 0,
    fpsr: u32 = 0,
    v: [32]u128 = @splat(0),
    tpidr: u64 = 0,
    tpidrro: u64 = 0,
    monitor: Monitor = .{},
    /// Instructions retired.
    retired: u64 = 0,
};

/// ESR exception classes, as the hardware reports them to EL1.
pub const EC_UNKNOWN = 0x00;
pub const EC_SVC64 = 0x15;
pub const EC_IABT_LOWER = 0x20;
pub const EC_PC_ALIGN = 0x22;
pub const EC_DABT_LOWER = 0x24;
pub const EC_BRK = 0x3c;
const ESR_IL = 1 << 25;
const FSC_TRANSLATION_L3 = 0x07;
const FSC_PERMISSION_L3 = 0x0f;
const FSC_ALIGNMENT = 0x21;

pub const Fault = struct {
    addr: u64,
    access: mem.Access,
    kind: mem.FaultKind,
    /// The ESR_EL1 the hardware would report.
    esr: u64,
};

pub const Exit = union(enum) {
    /// SVC: the PC is past it.
    syscall,
    /// BRK: the PC is at it.
    breakpoint,
    /// A kick, or the step limit: the PC is the next instruction to run.
    interrupted,
    /// A memory or alignment fault, or an undefined instruction (EC 0):
    /// the PC is at the instruction.
    fault: Fault,
};

/// CNTVCT_EL0's source: ticks at 24 MHz.
pub const Clock = struct {
    ctx: ?*anyopaque = null,
    now: *const fn (ctx: ?*anyopaque) u64,
};

/// One vCPU's T0: its registers, the Ctx it runs with, and its decode
/// cache.
pub const Machine = struct {
    cpu: *Cpu,
    /// tlb and space (a *mem.View) set; exit_request read, never cleared.
    ctx: *Ctx,
    cache: *Cache,
    /// Null derives CNTVCT_EL0 from `retired`, which makes runs
    /// deterministic.
    clock: ?Clock = null,
    /// Set by a handler that returns `.exit`.
    exit: Exit = .interrupted,

    pub fn init(cpu: *Cpu, ctx: *Ctx, cache: *Cache, clock: ?Clock) Machine {
        return .{ .cpu = cpu, .ctx = ctx, .cache = cache, .clock = clock };
    }

    inline fn tlb(m: *Machine) *mem.Tlb {
        return @ptrFromInt(@as(usize, @intCast(m.ctx.tlb)));
    }

    inline fn view(m: *Machine) *mem.View {
        return @ptrFromInt(@as(usize, @intCast(m.ctx.space)));
    }

    /// Whether someone asked T0 to leave (a kick, a shootdown, a flush).
    /// The vmm backend clears the request, not T0.
    inline fn requested(m: *Machine) bool {
        return @atomicLoad(u32, &m.ctx.exit_request, .monotonic) != 0;
    }
};

pub const Next = union(enum) {
    next,
    /// To this PC.
    jump: u64,
    /// See Machine.exit; the handler set cpu.pc.
    exit,
};

pub const Handler = *const fn (m: *Machine, o: *const Op, pc: u64) Next;

// ---------------------------------------------------------------- the decode cache

pub const Page = struct {
    ops: [ops_per_page + 1]Op,
    /// The host address of the text it was decoded from.
    host: usize = 0,
};

/// Decoded pages by virtual page number, each with the host page it was
/// decoded from. A lookup checks the page still maps there (a TLB hit, as
/// a mapping change flushes the TLB), and the whole cache goes when any
/// page's code is invalidated (CodePages.epoch moves: a store to code).
pub const Cache = struct {
    gpa: std.mem.Allocator,
    pages: std.AutoHashMapUnmanaged(u64, *Page) = .empty,
    last_vp: u64 = std.math.maxInt(u64),
    last: ?*Page = null,
    epoch: u64 = 0,

    pub fn init(gpa: std.mem.Allocator) Cache {
        return .{ .gpa = gpa };
    }

    pub fn deinit(c: *Cache) void {
        c.flush();
        c.pages.deinit(c.gpa);
    }

    pub fn flush(c: *Cache) void {
        var it = c.pages.valueIterator();
        while (it.next()) |p| c.gpa.destroy(p.*);
        c.pages.clearRetainingCapacity();
        c.last_vp = std.math.maxInt(u64);
        c.last = null;
    }

    /// Flushes the cache if code was invalidated since it last looked.
    inline fn check(c: *Cache, m: *Machine) void {
        const code = m.view().code orelse return;
        const e = code.epoch.load(.monotonic);
        if (e != c.epoch) {
            c.flush();
            c.epoch = e;
        }
    }

    /// The decoded page holding `va`, or null with m.exit set to the
    /// instruction abort.
    fn get(c: *Cache, m: *Machine, va: u64) ?*Page {
        const base = va & ~@as(u64, page_size - 1);
        const h = mem.fastExec(m.tlb(), base, 4) orelse blk: {
            const p = mem.probe(m.ctx, base, .exec) orelse {
                m.exit = .{ .fault = ctxFault(m, va, .exec) };
                return null;
            };
            break :blk @intFromPtr(p);
        };
        const vp = va >> mem.page_shift;
        if (vp == c.last_vp and c.last.?.host == h) return c.last;
        const gop = c.pages.getOrPut(c.gpa, vp) catch {
            m.exit = .{ .fault = fault(va, .exec, .unmapped) };
            return null;
        };
        if (!gop.found_existing or gop.value_ptr.*.host != h) {
            if (!gop.found_existing) {
                gop.value_ptr.* = c.gpa.create(Page) catch {
                    _ = c.pages.remove(vp);
                    m.exit = .{ .fault = fault(va, .exec, .unmapped) };
                    return null;
                };
            }
            const p = gop.value_ptr.*;
            p.host = h;
            decodePage(p, base, @ptrFromInt(h));
        }
        c.last_vp = vp;
        c.last = gop.value_ptr.*;
        return c.last;
    }
};

/// Decodes the text page at `va`. Data in text (literal pools, jump
/// tables) decodes to whatever it decodes to, and faults only if it runs.
pub fn decodePage(p: *Page, va: u64, text: *const [page_size]u8) void {
    for (0..ops_per_page) |i| {
        const word = std.mem.readInt(u32, text[i * 4 ..][0..4], .little);
        p.ops[i] = dec.decode(word, va + i * 4);
    }
    p.ops[ops_per_page] = .{ .k = .next_page, .imm = va +% page_size };
}

// ---------------------------------------------------------------- the loop

/// Runs until a syscall, a breakpoint, a fault, a kick, or `max_steps`
/// instructions (maxInt for no limit).
pub fn run(m: *Machine, max_steps: u64) Exit {
    const cpu = m.cpu;
    if (m.requested()) return .interrupted;
    m.cache.check(m);
    var page = m.cache.get(m, cpu.pc) orelse return m.exit;
    var base = cpu.pc & ~@as(u64, page_size - 1);
    var i: usize = @intCast((cpu.pc & (page_size - 1)) >> 2);
    var n: u64 = 0;
    defer cpu.retired +%= n;
    while (true) {
        const o = &page.ops[i];
        if (n == max_steps) {
            cpu.pc = base + i * 4;
            return .interrupted;
        }
        switch (dispatch(m, o, base + i * 4)) {
            .next => {
                i += 1;
                n += 1;
            },
            .jump => |t| {
                if (o.k != .next_page) n += 1;
                // Every guest loop has a taken branch or crosses a page, so
                // checking here bounds how long a kick waits.
                if (m.requested()) {
                    cpu.pc = t;
                    return .interrupted;
                }
                if (t & 3 != 0) {
                    cpu.pc = t;
                    return .{ .fault = .{ .addr = t, .access = .exec, .kind = .alignment, .esr = (EC_PC_ALIGN << 26) | ESR_IL } };
                }
                // A store to code, here or on another vCPU, drops what was
                // decoded from it: look the page up again.
                const epoch = m.cache.epoch;
                m.cache.check(m);
                if (t >> mem.page_shift != base >> mem.page_shift or epoch != m.cache.epoch) {
                    cpu.pc = t;
                    page = m.cache.get(m, t) orelse return m.exit;
                    base = t & ~@as(u64, page_size - 1);
                }
                i = @intCast((t & (page_size - 1)) >> 2);
            },
            .exit => {
                if (m.exit == .syscall) n += 1;
                return m.exit;
            },
        }
    }
}

/// Runs one decoded op at `pc`, for the JIT's call.interp. The caller
/// handles the result as `run` does, except that it moves the PC itself.
pub fn step(m: *Machine, o: *const Op, pc: u64) Next {
    return dispatch(m, o, pc);
}

inline fn dispatch(m: *Machine, o: *const Op, pc: u64) Next {
    const k = @intFromEnum(o.k);
    if (k < dec.simd_base) return handlers[k](m, o, pc);
    const s = k - dec.simd_base;
    if (s < simd_exec.handlers.len) return simd_exec.handlers[s](m, o, pc);
    return undef(m, pc);
}

const handlers: [dec.nkinds]Handler = blk: {
    @setEvalBranchQuota(100000);
    var h: [dec.nkinds]Handler = undefined;
    for (@typeInfo(Kind).@"enum".fields, 0..) |f, i| h[i] = handlerFor(@enumFromInt(f.value));
    break :blk h;
};

fn handlerFor(comptime k: Kind) Handler {
    return &struct {
        fn f(m: *Machine, o: *const Op, pc: u64) Next {
            return exec(k, m, o, pc);
        }
    }.f;
}

// ---------------------------------------------------------------- faults

fn fault(addr: u64, acc: mem.Access, kind: mem.FaultKind) Fault {
    const ec: u64 = if (acc == .exec) EC_IABT_LOWER else EC_DABT_LOWER;
    const wnr: u64 = if (acc == .write) 1 << 6 else 0;
    const fsc: u64 = switch (kind) {
        .unmapped => FSC_TRANSLATION_L3,
        // `code` reaches only the T1 dispatcher, which runs the store in T0.
        .permission, .code => FSC_PERMISSION_L3,
        .alignment => FSC_ALIGNMENT,
    };
    return .{ .addr = addr, .access = acc, .kind = kind, .esr = (ec << 26) | ESR_IL | wnr | fsc };
}

fn dataFault(m: *Machine, pc: u64, addr: u64, acc: mem.Access, kind: mem.FaultKind) Next {
    m.cpu.pc = pc;
    m.exit = .{ .fault = fault(addr, acc, kind) };
    return .exit;
}

pub fn undef(m: *Machine, pc: u64) Next {
    m.cpu.pc = pc;
    m.exit = .{ .fault = .{ .addr = pc, .access = .exec, .kind = .permission, .esr = (EC_UNKNOWN << 26) | ESR_IL } };
    return .exit;
}

// ---------------------------------------------------------------- memory

/// Zig allows atomics only up to pointer size, so wasm32 does 64-bit
/// accesses plainly; it runs one vCPU per instance.
const max_atomic = @sizeOf(usize);

/// A pending fault from an access helper.
const MemFault = struct { addr: u64, kind: mem.FaultKind };

/// The host address of an access of `n` bytes at `va` within one page.
inline fn host(m: *Machine, va: u64, n: u32, comptime acc: mem.Access, f: *MemFault) ?usize {
    if (mem.fast(m.tlb(), va, n, acc == .write)) |h| return h;
    const p = mem.probe(m.ctx, va, acc) orelse {
        f.* = .{ .addr = m.ctx.exit_addr, .kind = @enumFromInt(@as(u8, @truncate(m.ctx.exit_info >> 8))) };
        return null;
    };
    return @intFromPtr(p);
}

/// The fault mem.probe reported in the Ctx.
fn ctxFault(m: *Machine, va: u64, acc: mem.Access) Fault {
    _ = va;
    return fault(m.ctx.exit_addr, acc, @enumFromInt(@as(u8, @truncate(m.ctx.exit_info >> 8))));
}

inline fn rawLoad(comptime T: type, h: usize, va: u64) T {
    const n = @sizeOf(T);
    if (n == 1 or (n <= max_atomic and va % n == 0)) return @atomicLoad(T, @as(*const T, @ptrFromInt(h)), .monotonic);
    return std.mem.readInt(T, @as(*const [n]u8, @ptrFromInt(h)), .little);
}

inline fn rawStore(comptime T: type, h: usize, va: u64, v: T) void {
    const n = @sizeOf(T);
    if (n == 1 or (n <= max_atomic and va % n == 0)) return @atomicStore(T, @as(*T, @ptrFromInt(h)), v, .monotonic);
    std.mem.writeInt(T, @as(*[n]u8, @ptrFromInt(h)), v, .little);
}

/// Loads a T of up to 8 bytes; a page-crossing access goes a byte at a
/// time, faulting at the first byte it can't read.
fn load(m: *Machine, comptime T: type, va: u64, f: *MemFault) ?T {
    const n = @sizeOf(T);
    if ((va & (page_size - 1)) + n <= page_size) {
        const h = host(m, va, n, .read, f) orelse return null;
        return rawLoad(T, h, va);
    }
    var v: T = 0;
    for (0..n) |i| {
        const a = va +% i;
        const h = host(m, a, 1, .read, f) orelse return null;
        v |= @as(T, @as(*const u8, @ptrFromInt(h)).*) << @intCast(8 * i);
    }
    return v;
}

/// Stores a T of up to 8 bytes. A page-crossing store checks both pages
/// before it writes anything.
fn store(m: *Machine, comptime T: type, va: u64, v: T, f: *MemFault) bool {
    const n = @sizeOf(T);
    if ((va & (page_size - 1)) + n <= page_size) {
        const h = host(m, va, n, .write, f) orelse return false;
        rawStore(T, h, va, v);
        return true;
    }
    var hs: [n]usize = undefined;
    for (0..n) |i| hs[i] = host(m, va +% i, 1, .write, f) orelse return false;
    for (0..n) |i| @as(*u8, @ptrFromInt(hs[i])).* = @truncate(v >> @intCast(8 * i));
    return true;
}

/// A load of any size: 16 bytes as two 8-byte loads, as the hardware's
/// single-copy atomicity has it.
fn loadAny(m: *Machine, comptime T: type, va: u64, f: *MemFault) ?T {
    if (T != u128) return load(m, T, va, f);
    const lo = load(m, u64, va, f) orelse return null;
    const hi = load(m, u64, va +% 8, f) orelse return null;
    return @as(u128, hi) << 64 | lo;
}

fn storeAny(m: *Machine, comptime T: type, va: u64, v: T, f: *MemFault) bool {
    if (T != u128) return store(m, T, va, v, f);
    return store(m, u64, va, @truncate(v), f) and store(m, u64, va +% 8, @truncate(v >> 64), f);
}

// ---------------------------------------------------------------- helpers

inline fn w32(v: u64) u64 {
    return v & 0xffffffff;
}

pub fn cond(nzcv: u32, c: u8) bool {
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

/// AddWithCarry: the result and NZCV.
pub fn addFlags(comptime T: type, a: T, b: T, carry_in: u1) struct { T, u32 } {
    const S = std.meta.Int(.signed, @bitSizeOf(T));
    const r1 = @addWithOverflow(a, b);
    const r2 = @addWithOverflow(r1[0], @as(T, carry_in));
    const res = r2[0];
    const c: u32 = r1[1] | r2[1];
    const s1 = @addWithOverflow(@as(S, @bitCast(a)), @as(S, @bitCast(b)));
    const s2 = @addWithOverflow(s1[0], @as(S, carry_in));
    const v: u32 = s1[1] ^ s2[1];
    const n: u32 = @intCast(res >> (@bitSizeOf(T) - 1));
    const z: u32 = @intFromBool(res == 0);
    return .{ res, (n << 31) | (z << 30) | (c << 29) | (v << 28) };
}

fn logicFlags(comptime T: type, res: T) u32 {
    return (@as(u32, @intCast(res >> (@bitSizeOf(T) - 1))) << 31) | (@as(u32, @intFromBool(res == 0)) << 30);
}

fn shiftReg(comptime T: type, v: T, ty: u8, amt: u8) T {
    const S = std.meta.Int(.signed, @bitSizeOf(T));
    const a: std.math.Log2Int(T) = @intCast(amt);
    return switch (ty) {
        0 => v << a,
        1 => v >> a,
        2 => @bitCast(@as(S, @bitCast(v)) >> a),
        else => std.math.rotr(T, v, a),
    };
}

fn extendReg(v: u64, option: u8, amt: u8) u64 {
    const e: u64 = switch (option & 7) {
        0 => v & 0xff,
        1 => v & 0xffff,
        2 => v & 0xffffffff,
        3 => v,
        4 => dec.sext(v & 0xff, 8),
        5 => dec.sext(v & 0xffff, 16),
        6 => dec.sext(v & 0xffffffff, 32),
        else => v,
    };
    return e << @intCast(amt);
}

fn signExtend(comptime T: type, v: T, bits_: u8) T {
    const S = std.meta.Int(.signed, @bitSizeOf(T));
    const sh: std.math.Log2Int(T) = @intCast(@bitSizeOf(T) - @as(u32, bits_));
    return @bitCast(@as(S, @bitCast(v << sh)) >> sh);
}

fn onesT(comptime T: type, n: u8) T {
    return if (n >= @bitSizeOf(T)) std.math.maxInt(T) else (@as(T, 1) << @intCast(n)) - 1;
}

fn cls(comptime T: type, x: T) T {
    const v = ((x >> 1) ^ x) & (std.math.maxInt(T) >> 1);
    return @as(T, @clz(v)) - 1;
}

fn rev16(comptime T: type, x: T) T {
    const m: T = @truncate(0x00ff00ff00ff00ff);
    return ((x >> 8) & m) | ((x & m) << 8);
}

fn rev32(x: u64) u64 {
    return @as(u64, @byteSwap(@as(u32, @truncate(x >> 32)))) << 32 | @byteSwap(@as(u32, @truncate(x)));
}

/// The fixed EL0 ID values: 64-byte cache lines, and DC ZVA allowed on
/// 64-byte blocks, as Apple silicon reports them.
pub const ctr_el0: u64 = 0x8444c004;
pub const dczid_el0: u64 = 4;
pub const cntfrq: u64 = 24_000_000;

// ---------------------------------------------------------------- loads and stores

const LdSpec = struct { T: type, signed: bool = false, to32: bool = false, vreg: bool = false, store: bool = false };

fn ldSpec(comptime k: Kind) LdSpec {
    @setEvalBranchQuota(100000);
    const name = @tagName(k);
    const eq = std.mem.eql;
    const b = name[0 .. name.len - 2];
    if (eq(u8, b, "ldr_x")) return .{ .T = u64 };
    if (eq(u8, b, "ldr_w")) return .{ .T = u32 };
    if (eq(u8, b, "ldrb")) return .{ .T = u8 };
    if (eq(u8, b, "ldrh")) return .{ .T = u16 };
    if (eq(u8, b, "ldrsb_x")) return .{ .T = u8, .signed = true };
    if (eq(u8, b, "ldrsb_w")) return .{ .T = u8, .signed = true, .to32 = true };
    if (eq(u8, b, "ldrsh_x")) return .{ .T = u16, .signed = true };
    if (eq(u8, b, "ldrsh_w")) return .{ .T = u16, .signed = true, .to32 = true };
    if (eq(u8, b, "ldrsw")) return .{ .T = u32, .signed = true };
    if (eq(u8, b, "str_x")) return .{ .T = u64, .store = true };
    if (eq(u8, b, "str_w")) return .{ .T = u32, .store = true };
    if (eq(u8, b, "strb")) return .{ .T = u8, .store = true };
    if (eq(u8, b, "strh")) return .{ .T = u16, .store = true };
    if (eq(u8, b, "ldr_vb")) return .{ .T = u8, .vreg = true };
    if (eq(u8, b, "ldr_vh")) return .{ .T = u16, .vreg = true };
    if (eq(u8, b, "ldr_vs")) return .{ .T = u32, .vreg = true };
    if (eq(u8, b, "ldr_vd")) return .{ .T = u64, .vreg = true };
    if (eq(u8, b, "ldr_vq")) return .{ .T = u128, .vreg = true };
    if (eq(u8, b, "str_vb")) return .{ .T = u8, .vreg = true, .store = true };
    if (eq(u8, b, "str_vh")) return .{ .T = u16, .vreg = true, .store = true };
    if (eq(u8, b, "str_vs")) return .{ .T = u32, .vreg = true, .store = true };
    if (eq(u8, b, "str_vd")) return .{ .T = u64, .vreg = true, .store = true };
    if (eq(u8, b, "str_vq")) return .{ .T = u128, .vreg = true, .store = true };
    unreachable;
}

fn isSingle(comptime k: Kind) bool {
    @setEvalBranchQuota(100000);
    const name = @tagName(k);
    return (std.mem.endsWith(u8, name, "_o") or std.mem.endsWith(u8, name, "_m")) and
        (std.mem.startsWith(u8, name, "ldr") or std.mem.startsWith(u8, name, "str"));
}

/// The address and, for the writeback modes, the new base.
inline fn address(comptime modes: bool, o: *const Op, r: *[dec.nslots]u64) struct { u64, ?u64 } {
    if (!modes) return .{ r[o.n] +% o.imm, null };
    return switch (o.x) {
        1 => .{ r[o.n], r[o.n] +% o.imm },
        3 => .{ r[o.n] +% o.imm, r[o.n] +% o.imm },
        4 => .{ o.imm, null },
        5 => .{ r[o.n] +% extendReg(r[o.m], o.a, o.sh), null },
        else => .{ r[o.n] +% o.imm, null },
    };
}

inline fn single(comptime k: Kind, m: *Machine, o: *const Op, pc: u64) Next {
    const s = comptime ldSpec(k);
    const modes = comptime std.mem.endsWith(u8, @tagName(k), "_m");
    const cpu = m.cpu;
    const r = &cpu.r;
    const addr, const wb = address(modes, o, r);
    var f: MemFault = undefined;
    if (s.store) {
        const v: s.T = if (s.vreg) @truncate(cpu.v[o.d]) else @truncate(r[o.d]);
        if (!storeAny(m, s.T, addr, v, &f)) return dataFault(m, pc, f.addr, .write, f.kind);
    } else {
        const v = loadAny(m, s.T, addr, &f) orelse return dataFault(m, pc, f.addr, .read, f.kind);
        if (s.vreg) {
            cpu.v[o.d] = v;
        } else if (s.signed) {
            const S = std.meta.Int(.signed, @bitSizeOf(s.T));
            const e: u64 = @bitCast(@as(i64, @as(S, @bitCast(v))));
            r[o.d] = if (s.to32) w32(e) else e;
        } else r[o.d] = v;
    }
    if (wb) |b| r[o.n] = b;
    return .next;
}

const PairSpec = struct { T: type, signed: bool = false, vreg: bool = false, store: bool = false };

fn pairSpec(comptime k: Kind) PairSpec {
    return switch (k) {
        .ldp_x => .{ .T = u64 },
        .ldp_w => .{ .T = u32 },
        .ldpsw => .{ .T = u32, .signed = true },
        .stp_x => .{ .T = u64, .store = true },
        .stp_w => .{ .T = u32, .store = true },
        .ldp_vs => .{ .T = u32, .vreg = true },
        .ldp_vd => .{ .T = u64, .vreg = true },
        .ldp_vq => .{ .T = u128, .vreg = true },
        .stp_vs => .{ .T = u32, .vreg = true, .store = true },
        .stp_vd => .{ .T = u64, .vreg = true, .store = true },
        .stp_vq => .{ .T = u128, .vreg = true, .store = true },
        else => unreachable,
    };
}

inline fn pair(comptime k: Kind, m: *Machine, o: *const Op, pc: u64) Next {
    const s = comptime pairSpec(k);
    const n = @sizeOf(s.T);
    const cpu = m.cpu;
    const r = &cpu.r;
    const base = r[o.n];
    const addr = if (o.x == 1) base else base +% o.imm;
    var f: MemFault = undefined;
    if (s.store) {
        const v1: s.T = if (s.vreg) @truncate(cpu.v[o.d]) else @truncate(r[o.d]);
        const v2: s.T = if (s.vreg) @truncate(cpu.v[o.m]) else @truncate(r[o.m]);
        if (!storeAny(m, s.T, addr, v1, &f)) return dataFault(m, pc, f.addr, .write, f.kind);
        if (!storeAny(m, s.T, addr +% n, v2, &f)) return dataFault(m, pc, f.addr, .write, f.kind);
    } else {
        const v1 = loadAny(m, s.T, addr, &f) orelse return dataFault(m, pc, f.addr, .read, f.kind);
        const v2 = loadAny(m, s.T, addr +% n, &f) orelse return dataFault(m, pc, f.addr, .read, f.kind);
        if (s.vreg) {
            cpu.v[o.d] = v1;
            cpu.v[o.m] = v2;
        } else if (s.signed) {
            r[o.d] = @bitCast(@as(i64, @as(i32, @bitCast(@as(u32, @truncate(v1))))));
            r[o.m] = @bitCast(@as(i64, @as(i32, @bitCast(@as(u32, @truncate(v2))))));
        } else {
            r[o.d] = v1;
            r[o.m] = v2;
        }
    }
    if (o.x == 1 or o.x == 3) r[o.n] = base +% o.imm;
    return .next;
}

// ---------------------------------------------------------------- exclusives

/// A lock for the 16-byte store-exclusive on hosts without a 16-byte
/// compare-and-swap. It orders STXPs against each other only, which is all
/// the guests that use them (128-bit atomics) rely on.
var pair_lock: std.atomic.Value(u32) = .init(0);

const have_cas128 = builtin.cpu.arch == .aarch64 or
    (builtin.cpu.arch == .x86_64 and builtin.cpu.has(.x86, .cx16));

fn fence() void {
    // seq_cst: stronger than DMB needs, and simple.
    var x: u32 = 0;
    _ = @atomicRmw(u32, &x, .Add, 0, .seq_cst);
}

inline fn sizeOfX(x: u8) u8 {
    return @as(u8, 1) << @intCast(x);
}

fn alignmentFault(m: *Machine, pc: u64, addr: u64, acc: mem.Access) Next {
    return dataFault(m, pc, addr, acc, .alignment);
}

fn loadSized(m: *Machine, x: u8, va: u64, f: *MemFault) ?u64 {
    return switch (x) {
        0 => if (load(m, u8, va, f)) |v| v else null,
        1 => if (load(m, u16, va, f)) |v| v else null,
        2 => if (load(m, u32, va, f)) |v| v else null,
        else => load(m, u64, va, f),
    };
}

fn ldxr(m: *Machine, o: *const Op, pc: u64, comptime is_pair: bool) Next {
    const cpu = m.cpu;
    const addr = cpu.r[o.n];
    const size: u8 = if (is_pair) 2 * sizeOfX(o.x) else sizeOfX(o.x);
    if (addr % size != 0) return alignmentFault(m, pc, addr, .read);
    var f: MemFault = undefined;
    var lo: u64 = undefined;
    var hi: u64 = 0;
    if (is_pair and o.x == 3) {
        lo = load(m, u64, addr, &f) orelse return dataFault(m, pc, f.addr, .read, f.kind);
        hi = load(m, u64, addr + 8, &f) orelse return dataFault(m, pc, f.addr, .read, f.kind);
    } else if (is_pair) {
        const v = load(m, u64, addr, &f) orelse return dataFault(m, pc, f.addr, .read, f.kind);
        lo = v;
    } else {
        lo = loadSized(m, o.x, addr, &f) orelse return dataFault(m, pc, f.addr, .read, f.kind);
    }
    cpu.monitor = .{ .valid = true, .addr = addr, .size = size, .lo = lo, .hi = hi };
    if (is_pair) {
        if (o.x == 3) {
            cpu.r[o.d] = lo;
            cpu.r[o.a] = hi;
        } else {
            cpu.r[o.d] = w32(lo);
            cpu.r[o.a] = lo >> 32;
        }
    } else cpu.r[o.d] = lo;
    if (o.sh == 1) fence();
    return .next;
}

fn cas(comptime T: type, h: usize, old: T, new: T) bool {
    if (@sizeOf(T) > max_atomic) {
        const p: *T = @ptrFromInt(h);
        if (p.* != old) return false;
        p.* = new;
        return true;
    }
    return @cmpxchgStrong(T, @as(*T, @ptrFromInt(h)), old, new, .seq_cst, .monotonic) == null;
}

fn stxr(m: *Machine, o: *const Op, pc: u64, comptime is_pair: bool) Next {
    const cpu = m.cpu;
    const addr = cpu.r[o.n];
    const size: u8 = if (is_pair) 2 * sizeOfX(o.x) else sizeOfX(o.x);
    if (addr % size != 0) return alignmentFault(m, pc, addr, .write);
    const mon = cpu.monitor;
    cpu.monitor = .{};
    if (o.sh == 1) fence();
    if (!mon.valid or mon.addr != addr or mon.size != size) {
        cpu.r[o.d] = 1;
        return .next;
    }
    var f: MemFault = undefined;
    const h = host(m, addr, @min(size, 8), .write, &f) orelse return dataFault(m, pc, f.addr, .write, f.kind);
    const v = cpu.r[o.m];
    const ok = if (!is_pair) switch (o.x) {
        0 => cas(u8, h, @truncate(mon.lo), @truncate(v)),
        1 => cas(u16, h, @truncate(mon.lo), @truncate(v)),
        2 => cas(u32, h, @truncate(mon.lo), @truncate(v)),
        else => cas(u64, h, mon.lo, v),
    } else if (o.x == 2)
        cas(u64, h, mon.lo, w32(v) | cpu.r[o.a] << 32)
    else blk: {
        const h2 = host(m, addr + 8, 8, .write, &f) orelse return dataFault(m, pc, f.addr, .write, f.kind);
        const old = @as(u128, mon.hi) << 64 | mon.lo;
        const new = @as(u128, cpu.r[o.a]) << 64 | v;
        if (have_cas128 and h2 == h + 8) break :blk cas(u128, h, old, new);
        while (pair_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
        defer pair_lock.store(0, .release);
        const p1: *u64 = @ptrFromInt(h);
        const p2: *u64 = @ptrFromInt(h2);
        if (p1.* != mon.lo or p2.* != mon.hi) break :blk false;
        p1.* = @truncate(new);
        p2.* = @truncate(new >> 64);
        break :blk true;
    };
    cpu.r[o.d] = @intFromBool(!ok);
    return .next;
}

fn ldar(m: *Machine, o: *const Op, pc: u64) Next {
    const addr = m.cpu.r[o.n];
    if (addr % sizeOfX(o.x) != 0) return alignmentFault(m, pc, addr, .read);
    var f: MemFault = undefined;
    m.cpu.r[o.d] = loadSized(m, o.x, addr, &f) orelse return dataFault(m, pc, f.addr, .read, f.kind);
    fence();
    return .next;
}

fn stlr(m: *Machine, o: *const Op, pc: u64) Next {
    const addr = m.cpu.r[o.n];
    if (addr % sizeOfX(o.x) != 0) return alignmentFault(m, pc, addr, .write);
    fence();
    var f: MemFault = undefined;
    const v = m.cpu.r[o.m];
    const ok = switch (o.x) {
        0 => store(m, u8, addr, @truncate(v), &f),
        1 => store(m, u16, addr, @truncate(v), &f),
        2 => store(m, u32, addr, @truncate(v), &f),
        else => store(m, u64, addr, v, &f),
    };
    if (!ok) return dataFault(m, pc, f.addr, .write, f.kind);
    fence();
    return .next;
}

// ---------------------------------------------------------------- system

fn mrs(m: *Machine, o: *const Op) Next {
    const cpu = m.cpu;
    const sr = dec.sr;
    cpu.r[o.d] = switch (o.imm) {
        sr.nzcv => cpu.nzcv,
        sr.fpcr => cpu.fpcr,
        sr.fpsr => cpu.fpsr,
        sr.tpidr_el0 => cpu.tpidr,
        sr.tpidrro_el0 => cpu.tpidrro,
        sr.cntfrq_el0 => cntfrq,
        sr.cntvct_el0 => if (m.clock) |c| c.now(c.ctx) else cpu.retired,
        sr.ctr_el0 => ctr_el0,
        sr.dczid_el0 => dczid_el0,
        else => unreachable,
    };
    return .next;
}

/// FPCR bits Armv8.0 has: AHP, DN, FZ, and RMode. The trap enables read
/// as zero and ignore writes, as on Apple cores.
pub const fpcr_mask: u32 = 0x07c00000;
/// FPSR: NZCV (AArch32's), QC, and the cumulative exception flags.
pub const fpsr_mask: u32 = 0xf800009f;

fn msr(m: *Machine, o: *const Op) Next {
    const cpu = m.cpu;
    const sr = dec.sr;
    const v = cpu.r[o.n];
    switch (o.imm) {
        sr.nzcv => cpu.nzcv = @as(u32, @truncate(v)) & 0xf0000000,
        sr.fpcr => cpu.fpcr = @as(u32, @truncate(v)) & fpcr_mask,
        sr.fpsr => cpu.fpsr = @as(u32, @truncate(v)) & fpsr_mask,
        sr.tpidr_el0 => cpu.tpidr = v,
        else => unreachable,
    }
    return .next;
}

fn dcZva(m: *Machine, o: *const Op, pc: u64) Next {
    const addr = m.cpu.r[o.n] & ~@as(u64, 63);
    var f: MemFault = undefined;
    const h = host(m, addr, 64, .write, &f) orelse return dataFault(m, pc, f.addr, .write, f.kind);
    const p: *[64 / @sizeOf(usize)]usize = @ptrFromInt(h);
    for (p) |*q| @atomicStore(usize, q, 0, .monotonic);
    return .next;
}

// ---------------------------------------------------------------- the handlers

inline fn exec(comptime k: Kind, m: *Machine, o: *const Op, pc: u64) Next {
    if (comptime isSingle(k)) return single(k, m, o, pc);
    const cpu = m.cpu;
    const r = &cpu.r;
    switch (k) {
        .undef => return undef(m, pc),
        .next_page => return .{ .jump = o.imm },

        .movi => r[o.d] = o.imm,
        .movk_x => r[o.d] = (r[o.d] & ~(@as(u64, 0xffff) << @intCast(o.sh))) | (o.imm << @intCast(o.sh)),
        .movk_w => r[o.d] = w32((r[o.d] & ~(@as(u64, 0xffff) << @intCast(o.sh))) | (o.imm << @intCast(o.sh))),
        .add_imm_x => r[o.d] = r[o.n] +% o.imm,
        .add_imm_w => r[o.d] = w32(r[o.n] +% o.imm),
        .adds_imm_x, .subs_imm_x => {
            const b = if (k == .adds_imm_x) o.imm else ~o.imm;
            r[o.d], cpu.nzcv = addFlags(u64, r[o.n], b, @intFromBool(k == .subs_imm_x));
        },
        .adds_imm_w, .subs_imm_w => {
            const imm: u32 = @truncate(o.imm);
            const b = if (k == .adds_imm_w) imm else ~imm;
            const res, cpu.nzcv = addFlags(u32, @truncate(r[o.n]), b, @intFromBool(k == .subs_imm_w));
            r[o.d] = res;
        },
        .and_imm_x => r[o.d] = r[o.n] & o.imm,
        .and_imm_w => r[o.d] = w32(r[o.n] & o.imm),
        .orr_imm_x => r[o.d] = r[o.n] | o.imm,
        .orr_imm_w => r[o.d] = w32(r[o.n] | o.imm),
        .eor_imm_x => r[o.d] = r[o.n] ^ o.imm,
        .eor_imm_w => r[o.d] = w32(r[o.n] ^ o.imm),
        .ands_imm_x => {
            const res = r[o.n] & o.imm;
            r[o.d] = res;
            cpu.nzcv = logicFlags(u64, res);
        },
        .ands_imm_w => {
            const res: u32 = @truncate(r[o.n] & o.imm);
            r[o.d] = res;
            cpu.nzcv = logicFlags(u32, res);
        },
        .ubfx_x => r[o.d] = (r[o.n] >> @intCast(o.sh)) & onesT(u64, o.a),
        .ubfx_w => r[o.d] = (w32(r[o.n]) >> @intCast(o.sh)) & onesT(u64, o.a),
        .ubfiz_x => r[o.d] = (r[o.n] & onesT(u64, o.a)) << @intCast(o.sh),
        .ubfiz_w => r[o.d] = w32((r[o.n] & onesT(u64, o.a)) << @intCast(o.sh)),
        .sbfx_x => r[o.d] = signExtend(u64, (r[o.n] >> @intCast(o.sh)) & onesT(u64, o.a), o.a),
        .sbfx_w => r[o.d] = signExtend(u32, (@as(u32, @truncate(r[o.n])) >> @intCast(o.sh)) & onesT(u32, o.a), o.a),
        .sbfiz_x => r[o.d] = signExtend(u64, r[o.n] & onesT(u64, o.a), o.a) << @intCast(o.sh),
        .sbfiz_w => r[o.d] = signExtend(u32, @as(u32, @truncate(r[o.n])) & onesT(u32, o.a), o.a) << @intCast(o.sh),
        .bfxil_x => r[o.d] = (r[o.d] & ~onesT(u64, o.a)) | ((r[o.n] >> @intCast(o.sh)) & onesT(u64, o.a)),
        .bfxil_w => r[o.d] = w32((r[o.d] & ~onesT(u64, o.a)) | ((w32(r[o.n]) >> @intCast(o.sh)) & onesT(u64, o.a))),
        .bfi_x, .bfi_w => {
            const mask = onesT(u64, o.a) << @intCast(o.sh);
            const res = (r[o.d] & ~mask) | ((r[o.n] << @intCast(o.sh)) & mask);
            r[o.d] = if (k == .bfi_x) res else w32(res);
        },
        .extr_x => r[o.d] = if (o.sh == 0) r[o.m] else (r[o.m] >> @intCast(o.sh)) | (r[o.n] << @intCast(64 - @as(u7, @intCast(o.sh)))),
        .extr_w => {
            const lo: u32 = @truncate(r[o.m]);
            const hi: u32 = @truncate(r[o.n]);
            r[o.d] = if (o.sh == 0) lo else (lo >> @intCast(o.sh)) | (hi << @intCast(32 - @as(u6, @intCast(o.sh))));
        },

        .mov_x => r[o.d] = r[o.n],
        .mov_w => r[o.d] = w32(r[o.n]),
        .and_sreg_x, .and_sreg_w, .bic_sreg_x, .bic_sreg_w, .orr_sreg_x, .orr_sreg_w, .orn_sreg_x, .orn_sreg_w, .eor_sreg_x, .eor_sreg_w, .eon_sreg_x, .eon_sreg_w, .ands_sreg_x, .ands_sreg_w, .bics_sreg_x, .bics_sreg_w => {
            const idx = @intFromEnum(k) - @intFromEnum(Kind.and_sreg_x);
            const opcn = idx / 2;
            const T = if (idx % 2 == 0) u64 else u32;
            var b = shiftReg(T, @truncate(r[o.m]), o.x, o.sh);
            if (opcn & 1 == 1) b = ~b;
            const a: T = @truncate(r[o.n]);
            const res: T = switch (opcn >> 1) {
                0, 3 => a & b,
                1 => a | b,
                else => a ^ b,
            };
            r[o.d] = res;
            if (opcn >> 1 == 3) cpu.nzcv = logicFlags(T, res);
        },
        .add_sreg_x, .add_sreg_w, .adds_sreg_x, .adds_sreg_w, .sub_sreg_x, .sub_sreg_w, .subs_sreg_x, .subs_sreg_w => {
            const idx = @intFromEnum(k) - @intFromEnum(Kind.add_sreg_x);
            const T = if (idx % 2 == 0) u64 else u32;
            const b = shiftReg(T, @truncate(r[o.m]), o.x, o.sh);
            arith(T, cpu, o, idx / 2, @truncate(r[o.n]), b);
        },
        .add_ereg_x, .add_ereg_w, .adds_ereg_x, .adds_ereg_w, .sub_ereg_x, .sub_ereg_w, .subs_ereg_x, .subs_ereg_w => {
            const idx = @intFromEnum(k) - @intFromEnum(Kind.add_ereg_x);
            const T = if (idx % 2 == 0) u64 else u32;
            const b: T = @truncate(extendReg(r[o.m], o.x, o.sh));
            arith(T, cpu, o, idx / 2, @truncate(r[o.n]), b);
        },
        .add_reg_x => r[o.d] = r[o.n] +% r[o.m],
        .add_reg_w => r[o.d] = w32(r[o.n] +% r[o.m]),
        .sub_reg_x => r[o.d] = r[o.n] -% r[o.m],
        .sub_reg_w => r[o.d] = w32(r[o.n] -% r[o.m]),
        .adc_x, .adc_w, .adcs_x, .adcs_w, .sbc_x, .sbc_w, .sbcs_x, .sbcs_w => {
            const idx = @intFromEnum(k) - @intFromEnum(Kind.adc_x);
            const T = if (idx % 2 == 0) u64 else u32;
            const op = idx / 2; // 0 adc, 1 adcs, 2 sbc, 3 sbcs
            const b: T = if (op >= 2) ~@as(T, @truncate(r[o.m])) else @truncate(r[o.m]);
            const res, const f = addFlags(T, @truncate(r[o.n]), b, @intCast(cpu.nzcv >> 29 & 1));
            r[o.d] = res;
            if (op & 1 == 1) cpu.nzcv = f;
        },
        .ccmp_x, .ccmp_w => {
            const T = if (k == .ccmp_x) u64 else u32;
            if (cond(cpu.nzcv, o.x)) {
                const b: T = if (o.a & 1 == 1) @truncate(o.imm) else @truncate(r[o.m]);
                const ccmn = o.a & 2 != 0;
                _, cpu.nzcv = addFlags(T, @truncate(r[o.n]), if (ccmn) b else ~b, @intFromBool(!ccmn));
            } else cpu.nzcv = @as(u32, o.sh) << 28;
        },
        .csel_x, .csel_w => {
            const T = if (k == .csel_x) u64 else u32;
            const res: T = if (cond(cpu.nzcv, o.x)) @truncate(r[o.n]) else blk: {
                const b: T = @truncate(r[o.m]);
                break :blk switch (o.a) {
                    0 => b,
                    1 => b +% 1,
                    2 => ~b,
                    else => 0 -% b,
                };
            };
            r[o.d] = res;
        },
        .rbit_x => r[o.d] = @bitReverse(r[o.n]),
        .rbit_w => r[o.d] = @bitReverse(@as(u32, @truncate(r[o.n]))),
        .rev16_x => r[o.d] = rev16(u64, r[o.n]),
        .rev16_w => r[o.d] = rev16(u32, @truncate(r[o.n])),
        .rev32_x => r[o.d] = rev32(r[o.n]),
        .rev_x => r[o.d] = @byteSwap(r[o.n]),
        .rev_w => r[o.d] = @byteSwap(@as(u32, @truncate(r[o.n]))),
        .clz_x => r[o.d] = @clz(r[o.n]),
        .clz_w => r[o.d] = @clz(@as(u32, @truncate(r[o.n]))),
        .cls_x => r[o.d] = cls(u64, r[o.n]),
        .cls_w => r[o.d] = cls(u32, @truncate(r[o.n])),
        // Division by zero gives 0 and MIN / -1 gives MIN, where Zig's are
        // undefined behaviour.
        .udiv_x => r[o.d] = if (r[o.m] == 0) 0 else r[o.n] / r[o.m],
        .udiv_w => {
            const a: u32 = @truncate(r[o.n]);
            const b: u32 = @truncate(r[o.m]);
            r[o.d] = if (b == 0) 0 else a / b;
        },
        .sdiv_x => r[o.d] = @bitCast(sdiv(i64, @bitCast(r[o.n]), @bitCast(r[o.m]))),
        .sdiv_w => r[o.d] = @as(u32, @bitCast(sdiv(i32, @bitCast(@as(u32, @truncate(r[o.n]))), @bitCast(@as(u32, @truncate(r[o.m])))))),
        .lslv_x => r[o.d] = r[o.n] << @truncate(r[o.m]),
        .lslv_w => r[o.d] = @as(u32, @truncate(r[o.n])) << @truncate(r[o.m]),
        .lsrv_x => r[o.d] = r[o.n] >> @truncate(r[o.m]),
        .lsrv_w => r[o.d] = @as(u32, @truncate(r[o.n])) >> @truncate(r[o.m]),
        .asrv_x => r[o.d] = @bitCast(@as(i64, @bitCast(r[o.n])) >> @truncate(r[o.m])),
        .asrv_w => r[o.d] = @as(u32, @bitCast(@as(i32, @bitCast(@as(u32, @truncate(r[o.n])))) >> @truncate(r[o.m]))),
        .rorv_x => r[o.d] = std.math.rotr(u64, r[o.n], @as(u6, @truncate(r[o.m]))),
        .rorv_w => r[o.d] = std.math.rotr(u32, @as(u32, @truncate(r[o.n])), @as(u5, @truncate(r[o.m]))),
        .madd_x => r[o.d] = r[o.a] +% r[o.n] *% r[o.m],
        .madd_w => r[o.d] = w32(r[o.a] +% r[o.n] *% r[o.m]),
        .msub_x => r[o.d] = r[o.a] -% r[o.n] *% r[o.m],
        .msub_w => r[o.d] = w32(r[o.a] -% r[o.n] *% r[o.m]),
        .smaddl, .smsubl => {
            const p: u64 = @bitCast(@as(i64, @as(i32, @bitCast(@as(u32, @truncate(r[o.n]))))) *% @as(i64, @as(i32, @bitCast(@as(u32, @truncate(r[o.m]))))));
            r[o.d] = if (k == .smaddl) r[o.a] +% p else r[o.a] -% p;
        },
        .umaddl, .umsubl => {
            const p = w32(r[o.n]) * w32(r[o.m]);
            r[o.d] = if (k == .umaddl) r[o.a] +% p else r[o.a] -% p;
        },
        .smulh => {
            const p = @as(i128, @as(i64, @bitCast(r[o.n]))) * @as(i128, @as(i64, @bitCast(r[o.m])));
            r[o.d] = @truncate(@as(u128, @bitCast(p)) >> 64);
        },
        .umulh => r[o.d] = @truncate((@as(u128, r[o.n]) * r[o.m]) >> 64),

        .b => return .{ .jump = o.imm },
        .bl => {
            r[30] = pc + 4;
            return .{ .jump = o.imm };
        },
        .bcond => if (cond(cpu.nzcv, o.x)) return .{ .jump = o.imm },
        .cbz_x => if (r[o.n] == 0) return .{ .jump = o.imm },
        .cbz_w => if (w32(r[o.n]) == 0) return .{ .jump = o.imm },
        .cbnz_x => if (r[o.n] != 0) return .{ .jump = o.imm },
        .cbnz_w => if (w32(r[o.n]) != 0) return .{ .jump = o.imm },
        .tbz => if (r[o.n] >> @intCast(o.sh) & 1 == 0) return .{ .jump = o.imm },
        .tbnz => if (r[o.n] >> @intCast(o.sh) & 1 == 1) return .{ .jump = o.imm },
        .br, .ret => return .{ .jump = r[o.n] },
        .blr => {
            const t = r[o.n];
            r[30] = pc + 4;
            return .{ .jump = t };
        },
        .svc => {
            cpu.pc = pc + 4;
            cpu.monitor = .{};
            m.exit = .syscall;
            return .exit;
        },
        .brk => {
            cpu.pc = pc;
            m.exit = .breakpoint;
            return .exit;
        },

        .nop => {},
        .clrex => cpu.monitor = .{},
        .fence => fence(),
        .mrs => return mrs(m, o),
        .msr => return msr(m, o),
        .dc_zva => return dcZva(m, o, pc),

        .ldp_x, .ldp_w, .ldpsw, .stp_x, .stp_w, .ldp_vs, .ldp_vd, .ldp_vq, .stp_vs, .stp_vd, .stp_vq => return pair(k, m, o, pc),
        .ldxr => return ldxr(m, o, pc, false),
        .ldxp => return ldxr(m, o, pc, true),
        .stxr => return stxr(m, o, pc, false),
        .stxp => return stxr(m, o, pc, true),
        .ldar => return ldar(m, o, pc),
        .stlr => return stlr(m, o, pc),
        else => comptime unreachable,
    }
    return .next;
}

inline fn arith(comptime T: type, cpu: *Cpu, o: *const Op, op: u32, a: T, b: T) void {
    // op: 0 add, 1 adds, 2 sub, 3 subs
    switch (op) {
        0 => cpu.r[o.d] = a +% b,
        2 => cpu.r[o.d] = a -% b,
        1 => {
            const res, cpu.nzcv = addFlags(T, a, b, 0);
            cpu.r[o.d] = res;
        },
        else => {
            const res, cpu.nzcv = addFlags(T, a, ~b, 1);
            cpu.r[o.d] = res;
        },
    }
}

fn sdiv(comptime I: type, a: I, b: I) I {
    if (b == 0) return 0;
    if (b == -1) return 0 -% a;
    return @divTrunc(a, b);
}

test {
    _ = @import("oracle_test.zig");
}
