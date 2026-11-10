//! h86's front end: 386 instructions to IR.
//!
//! Lifted: moves, the ALU and its flags (as `eflags.*` values, see
//! flags.zig), shifts by a constant or CL, the multiplies, DIV and IDIV
//! of a register (with the #DE checks inline), the stack (PUSH, POP,
//! LEAVE, CALL, RET), direct and indirect branches, LOOP and JECXZ,
//! SETcc, CMOVcc, and REP string instructions (a page at a time, through
//! `call.interp`, with a poll between pages). Everything else runs
//! through `call.interp`, which hands the instruction to T0.
//!
//! Regions: a linear scan from the entry that goes on through
//! conditional branches and `call` to the next instruction (the
//! call-next-pop idiom of 386 position-independent code; a following
//! `pop` fuses with it), and stops after any other unconditional
//! transfer, after an instruction only T0 can end (INT, a far or
//! 16-bit transfer, anything that traps), or at the limits. Branch
//! targets inside the scanned range start blocks; a backward one is a
//! loop, with a `poll` at its head.
//!
//! Guest state is exact wherever the region can leave: every lifted
//! instruction does its loads and stores before it writes a register or
//! the flags, the flags are written back before every load, store, call,
//! and exit, and each of those carries the count of instructions done
//! before it in its block (the IR's `retired`). A read-modify-write's
//! load is marked `rmw`, so it faults as the write it is.
//!
//! The runtime's side: `ctx.frontend` is a `*Mem`, the address space as
//! T0 sees it, which `interp` runs T0 on. A fault T0 takes inside
//! `call.interp` leaves `Cpu.trap` and `Cpu.ecode` set as T0 sets them;
//! one a lifted load or store takes leaves only the exit fields.

const std = @import("std");
const ir = @import("../ir.zig");
const ctx_mod = @import("../ctx.zig");
const fe = @import("../frontend.zig");
const xf = @import("flags.zig");
const dec = @import("../../interp/x86/decode.zig");
const table = @import("../../interp/x86/table.zig");
const exec = @import("../../interp/x86/exec.zig");
const cpu_mod = @import("../../interp/x86/cpu.zig");

const Cpu = cpu_mod.Cpu;
const Inst = dec.Inst;
const Ref = ir.Ref;
const Type = ir.Type;
const Builder = ir.Builder;
const Ctx = ctx_mod.Ctx;
const Exit = ctx_mod.Exit;

pub const frontend: fe.Frontend = .{ .name = "h86", .flags = .eflags, .lift = lift, .interp = interp };

const page_size = 4096;

/// Guest memory as T0 reaches it: `ctx.frontend` points at one. See
/// exec.zig for what `translate` gives.
pub const Mem = struct {
    ctx: *anyopaque,
    translateFn: *const fn (ctx: *anyopaque, va: u32, access: cpu_mod.Access) ?[*]u8,

    pub fn translate(m: *Mem, va: u32, access: cpu_mod.Access) ?[*]u8 {
        return m.translateFn(m.ctx, va, access);
    }
};

// ---------------------------------------------------------------- handles

/// What a `call.interp` handle asks `interp` for. A handle is
/// `len | kind << 8 | arg << 16`: `interp` fetches and decodes the
/// instruction again at the PC it's given, so the handle needs no decode
/// cache.
pub const Kind = enum(u8) {
    /// Run the instruction (`len` bytes) on T0.
    step = 0,
    /// Run up to a page's worth of a REP string instruction's iterations
    /// (`arg` is the element size), leaving ECX, ESI, and EDI exact. Returns
    /// ok with the instruction unfinished if ECX hasn't run out (and the
    /// REPE or REPNE condition hasn't ended it); the region checks and
    /// loops.
    rep_chunk = 1,
    /// Make `Cpu.fl.bits` current (see flags.zig).
    materialize = 2,
};

pub fn handle(kind: Kind, len: u8, arg: u8) u64 {
    return @as(u64, len) | (@as(u64, @intFromEnum(kind)) << 8) | (@as(u64, arg) << 16);
}

/// `exit_info` for an exception T0 raised inside `call.interp` (other than
/// #UD, which is `.undef`, and #PF, which is a memory fault): this in bits
/// 8..15 where a memory fault has its kind, and the vector in bits 16..23.
pub const exception_kind: u64 = 0x80;

/// Exits and the retired count: an instruction that completes inside
/// `call.interp` and leaves (a transfer, or INT) is counted here; one
/// that returns `.ok` is counted by the region's `retire`.
///
/// h86's `call.interp`: runs one instruction (or a REP chunk) on T0, with
/// `ctx.frontend` as its memory.
pub fn interp(c: *Ctx, h: u64, pc64: u64) callconv(.c) u32 {
    const cpu = c.cpuPtr(Cpu);
    const kind: Kind = @enumFromInt(@as(u8, @truncate(h >> 8)));
    if (kind == .materialize) {
        cpu.fl.materialize();
        return 0;
    }
    const m: *Mem = @ptrFromInt(@as(usize, @intCast(c.frontend)));
    const pc: u32 = @truncate(pc64);
    const len: u32 = @truncate(h & 0xff);
    const next = pc +% len;
    cpu.eip = pc;
    if (kind == .step) {
        const r = exec.step(cpu, m);
        cpu.fl.materialize();
        if (r) |e| return exitFor(c, cpu, e, pc);
        if (cpu.eip != next) {
            // A control transfer: it completed, so it counts here.
            count(c);
            c.exit_pc = cpu.eip;
            return @intFromEnum(Exit.indirect);
        }
        return 0;
    }
    // A REP chunk: let T0 see at most `n` iterations' worth of ECX.
    const size: u32 = @truncate((h >> 16) & 0xff);
    const ecx = cpu.r[1];
    const n = @min(ecx, page_size / size);
    cpu.r[1] = n;
    const r = exec.step(cpu, m);
    const done_iters = n - cpu.r[1];
    cpu.r[1] = ecx - done_iters;
    cpu.fl.materialize();
    if (r) |e| return exitFor(c, cpu, e, pc);
    // T0 retired it; the region retires the instruction once, at the end.
    cpu.retired -%= 1;
    cpu.eip = pc;
    return 0;
}

fn count(c: *Ctx) void {
    c.retired +%= 1;
    c.budget -%= 1;
}

pub fn exitFor(c: *Ctx, cpu: *Cpu, e: cpu_mod.Exit, pc: u32) u32 {
    c.exit_pc = cpu.eip;
    switch (e) {
        .syscall => {
            count(c);
            return @intFromEnum(Exit.svc);
        },
        // Not retired, as check.zig's rules have it (T0 counts it in
        // Cpu.retired); EIP is past it.
        .breakpoint => return @intFromEnum(Exit.brk),
        .fault => |f| {
            c.exit_pc = pc;
            c.exit_addr = f.addr;
            c.exit_info = @intFromEnum(f.access);
            return @intFromEnum(Exit.fault);
        },
        .exception => |v| {
            if (v == cpu_mod.vec_ud) return @intFromEnum(Exit.undef);
            // INTO's #OF leaves EIP past it, as T0 does, but like any
            // exit at a fault it isn't counted here.
            c.exit_addr = 0;
            c.exit_info = (exception_kind << 8) | (@as(u64, v) << 16);
            return @intFromEnum(Exit.fault);
        },
        .stopped => return @intFromEnum(Exit.interrupted),
    }
}

// ---------------------------------------------------------------- Cpu

fn regOff(n: u3) u64 {
    return @offsetOf(Cpu, "r") + @as(u64, n) * 4;
}

/// AL, CL, DL, BL, then AH, CH, DH, BH: bytes of EAX to EBX (little-endian
/// hosts only, which all of h9's are).
fn byteOff(n: u3) u64 {
    return if (n < 4) regOff(n) else regOff(n - 4) + 1;
}

const seg_base_off = @offsetOf(Cpu, "seg_base");
const seg_null_off = @offsetOf(Cpu, "seg_null");

const ESP = 4;

fn tyOf(size: u8) Type {
    return switch (size) {
        1 => .i8,
        2 => .i16,
        else => .i32,
    };
}

fn wideOf(size: u8) Type {
    return switch (size) {
        1 => .i16,
        2 => .i32,
        else => .i64,
    };
}

fn log2(size: u8) u3 {
    return switch (size) {
        1 => 0,
        2 => 1,
        else => 2,
    };
}

fn mask(size: u8) u64 {
    return if (size == 4) 0xffff_ffff else (@as(u64, 1) << @intCast(size * 8)) - 1;
}

// ---------------------------------------------------------------- scan

const Class = enum {
    /// Lifted, and falls through.
    lifted,
    /// Through `call.interp`, and falls through.
    interp,
    /// Jcc, LOOP, LOOPE, LOOPNE, JECXZ: the region goes on.
    cond,
    /// JMP rel: the region stops.
    jump,
    /// CALL rel: the region stops, unless it calls the next instruction.
    call,
    /// RET, JMP r/m, CALL r/m: an indirect exit, and the region stops.
    indirect,
    /// Through `call.interp`, then the region stops.
    stop,
};

/// A memory read-modify-write that must be atomic: LOCK-prefixed, or
/// XCHG, CMPXCHG, and CMPXCHG8B with memory. Lifted with `cas`.
fn isAtomic(i: *const Inst) bool {
    if (!i.mem) return false;
    return switch (i.op) {
        .add, .@"or", .adc, .sbb, .@"and", .sub, .xor, .inc, .dec, .not, .neg => i.lock,
        // XADD and CMPXCHG without LOCK needn't be atomic, but may be.
        .xchg, .xadd, .cmpxchg, .cmpxchg8b => true,
        else => false,
    };
}

/// Atomics that retry: a load, the new value, and a `cas` that must find
/// the loaded value. CMPXCHG and CMPXCHG8B are a single `cas`.
fn retries(i: *const Inst) bool {
    return i.op != .cmpxchg and i.op != .cmpxchg8b;
}

fn isString(op: table.Op) bool {
    return switch (op) {
        .movs, .cmps, .stos, .lods, .scas => true,
        else => false,
    };
}

fn classify(i: *const Inst) Class {
    const e = i.tableEntry();
    // LOCK where it isn't allowed raises #UD, in T0.
    if (i.lock and (!e.lock or !i.mem)) return if (e.end) .stop else .interp;
    if (isAtomic(i)) return .lifted;
    const near32 = i.size == 4;
    return switch (i.op) {
        .nop, .fence, .add, .@"or", .adc, .sbb, .@"and", .sub, .xor, .cmp, .@"test" => .lifted,
        .inc, .dec, .not, .neg, .mul, .imul1, .imul => .lifted,
        // A memory divisor would have to be loaded twice (the check and
        // the division are in different blocks): T0 runs it.
        .div, .idiv => if (i.mem) .interp else .lifted,
        .shl, .shr, .sar, .rol, .ror, .shld, .shrd => blk: {
            const cl = e.src == .CL or ((i.op == .shld or i.op == .shrd) and e.imm != .b);
            if (cl) break :blk if (i.mem) .interp else .lifted;
            const n = if (e.src == .one) 1 else i.imm & 31;
            // A count of 0 still checks that memory is writable.
            break :blk if (n == 0 and i.mem) .interp else .lifted;
        },
        .bt, .bts, .btr, .btc => if (i.lock) .interp else .lifted,
        .bsf, .bsr => .lifted,
        .mov, .movzx, .movsx, .lea, .bswap, .cbw, .cwd, .setcc, .cmovcc => .lifted,
        .xchg, .xadd, .cmpxchg => .lifted,
        .push, .leave => .lifted,
        // POP to memory addresses with ESP after the pop (FS and GS go
        // to T0).
        .pop => if (i.mem and @intFromEnum(i.seg) >= 4) .interp else .lifted,
        .clc, .stc, .cmc, .cld, .std => .lifted,
        // Without REP, a source through FS or GS goes to T0.
        .movs, .cmps, .stos, .lods, .scas => if (i.addr16) .interp else if (i.rep != .none) .lifted else if (@intFromEnum(i.seg) >= 4 and i.op != .stos and i.op != .scas) .interp else .lifted,
        .jcc => if (near32) .cond else .stop,
        .loop, .loope, .loopne, .jcxz => if (near32 and !i.addr16) .cond else .stop,
        .jmp => if (near32) .jump else .stop,
        .call => if (near32) .call else .stop,
        .ret, .jmp_ind, .call_ind => if (near32) .indirect else .stop,
        else => if (e.end) .stop else .interp,
    };
}

/// Whether `i` is lifted inline (as opposed to `call.interp`).
fn inline_(c: Class) bool {
    return switch (c) {
        .lifted, .cond, .jump, .call, .indirect => true,
        .interp, .stop => false,
    };
}

const Insn = struct {
    pc: u32,
    i: Inst,
    class: Class,
};

pub fn lift(b: *Builder, src: fe.Source, pc: u64, limits: fe.Limits) fe.LiftError!void {
    const gpa = b.gpa;
    // x86 is TSO: a weaker host orders this region's loads and stores.
    b.r.tso = true;
    const max: usize = @max(1, limits.max_insns);
    var insns: std.ArrayList(Insn) = .empty;
    defer insns.deinit(gpa);
    const last_page = (pc >> 12) + @max(1, limits.max_pages) - 1;
    var p: u32 = @truncate(pc);
    scan: while (insns.items.len < max and p >> 12 <= last_page) {
        var buf: [dec.max_len]u8 = undefined;
        const got = src.readAll(p, &buf);
        const i = dec.decode(buf[0..got]) catch break;
        const c = classify(&i);
        try insns.append(gpa, .{ .pc = p, .i = i, .class = c });
        switch (c) {
            .jump, .indirect, .stop => break :scan,
            .call => if (i.imm != 0) break :scan,
            else => {},
        }
        p +%= i.len;
    }
    if (insns.items.len == 0) return error.Unsupported;

    var l: Lifter = .{ .b = b, .insns = insns.items };
    try l.run();
}

// ---------------------------------------------------------------- lifter

const Lifter = struct {
    b: *Builder,
    insns: []const Insn,
    fl: xf.State = .{},
    /// Instructions done since the last `retire`.
    count: u64 = 0,
    /// FS and GS (bits 4 and 5) checked non-null in this block.
    seg_ok: u8 = 0,
    leader: []bool = &.{},
    loop_head: []bool = &.{},
    block_of: []ir.BlockId = &.{},
    live_out: []u32 = &.{},
    /// The PC after the last instruction.
    end: u32 = 0,
    /// Exit blocks for branches out of the region, to fill.
    pending_exits: std.ArrayList(ExitBlock) = .empty,

    const ExitBlock = struct { id: ir.BlockId, pc: u32 };

    fn next(l: *const Lifter, k: usize) u32 {
        return l.insns[k].pc +% l.insns[k].i.len;
    }

    fn target(l: *const Lifter, k: usize) u32 {
        return l.next(k) +% l.insns[k].i.imm;
    }

    /// The instruction starting at guest PC t, if the region has one.
    fn indexOf(l: *const Lifter, t: u32) ?usize {
        const first = l.insns[0].pc;
        if (t -% first >= l.end -% first) return null;
        var lo: usize = 0;
        var hi: usize = l.insns.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const v = l.insns[mid].pc -% first;
            if (v == t -% first) return mid;
            if (v < t -% first) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    fn hasTarget(c: Class, i: *const Inst) bool {
        return switch (c) {
            .cond, .jump => true,
            .call => i.imm != 0,
            else => false,
        };
    }

    fn run(l: *Lifter) !void {
        const gpa = l.b.gpa;
        const n = l.insns.len;
        l.end = l.next(n - 1);
        l.leader = try gpa.alloc(bool, n + 1);
        defer gpa.free(l.leader);
        l.loop_head = try gpa.alloc(bool, n + 1);
        defer gpa.free(l.loop_head);
        l.block_of = try gpa.alloc(ir.BlockId, n + 1);
        defer gpa.free(l.block_of);
        l.live_out = try gpa.alloc(u32, n);
        defer gpa.free(l.live_out);
        defer l.pending_exits.deinit(gpa);
        @memset(l.leader, false);
        @memset(l.loop_head, false);
        l.leader[0] = true;
        l.leader[n] = true;
        var touches_flags = false;
        for (l.insns, 0..) |*in, k| {
            if (hasTarget(in.class, &in.i)) {
                if (l.indexOf(l.target(k))) |t| {
                    l.leader[t] = true;
                    if (t <= k) l.loop_head[t] = true;
                }
            }
            if (in.class == .cond) l.leader[k + 1] = true;
            if (inline_(in.class)) {
                const x = dec.effects(&in.i);
                if ((x.flags_read | x.flags_written) & xf.arith != 0) touches_flags = true;
            }
        }

        // Flag liveness over the instructions in order.
        const uses = try gpa.alloc(xf.Use, n);
        defer gpa.free(uses);
        const ends = try gpa.alloc(bool, n);
        defer gpa.free(ends);
        for (l.insns, 0..) |*in, k| {
            const x = dec.effects(&in.i);
            uses[k] = .{
                .read = x.flags_read & xf.arith,
                .written = x.flags_written & xf.arith,
                .barrier = !inline_(in.class) or x.mem_read or x.mem_write or in.i.mem and in.i.op != .lea and in.i.op != .nop or
                    in.i.op == .div or in.i.op == .idiv or isString(in.i.op) or isAtomic(&in.i),
            };
            ends[k] = l.leader[k + 1] or switch (in.class) {
                .lifted, .interp => isString(in.i.op) or isAtomic(&in.i),
                else => true,
            };
        }
        xf.liveness(uses, ends, l.live_out);

        // Block 0 is the prologue; then one block per leader.
        const b = l.b;
        const prologue = try b.block();
        for (0..n + 1) |k| {
            if (l.leader[k]) l.block_of[k] = try b.block();
        }
        b.begin(prologue);
        const entry: u32 = l.insns[0].pc;
        try b.poll(entry);
        if (touches_flags) {
            const kind = try b.getreg(.i8, xf.kind_off);
            const lazy = try b.icmp(.ne, kind, try b.konst(.i8, 0));
            const mat = try b.block();
            try b.brcond(lazy, mat, l.block_of[0]);
            b.begin(mat);
            try b.interp(handle(.materialize, 0, 0), entry);
            try b.br(l.block_of[0]);
        } else {
            try b.br(l.block_of[0]);
        }

        var k: usize = 0;
        while (k < n) {
            if (l.leader[k]) {
                if (b.cur != null) try l.endBlock(.{ .br = l.block_of[k] });
                l.startBlock(l.block_of[k]);
                if (l.loop_head[k]) try b.poll(l.insns[k].pc);
            } else if (b.cur == null) {
                // Unreachable code after a terminator: the scan stops
                // there, so this doesn't happen.
                unreachable;
            }
            k += try l.one(k);
        }
        // The fall-out block.
        if (b.cur != null) try l.endBlock(.{ .br = l.block_of[n] });
        l.startBlock(l.block_of[n]);
        try b.exit(.@"exit.chain", l.end);
    }

    fn startBlock(l: *Lifter, id: ir.BlockId) void {
        l.b.begin(id);
        l.fl.forget();
        l.seg_ok = 0;
    }

    /// Writes the flags back, and stamps what's done on the ops that can
    /// leave (the IR's `retired`): before anything that can leave.
    fn leave(l: *Lifter) !void {
        try l.fl.flush(l.b);
        l.b.retired = @intCast(l.count);
    }

    /// Retires what's done, before a branch to another block.
    fn retireAll(l: *Lifter) !void {
        try l.b.retire(l.count);
        l.count = 0;
    }

    const End = union(enum) {
        br: ir.BlockId,
        brcond: struct { c: Ref, t: ir.BlockId, f: ir.BlockId },
        chain: u32,
        indirect: Ref,
    };

    fn endBlock(l: *Lifter, e: End) !void {
        try l.leave();
        switch (e) {
            .br, .brcond => try l.retireAll(),
            // An exit carries the count.
            else => l.count = 0,
        }
        switch (e) {
            .br => |id| try l.b.br(id),
            .brcond => |c| try l.b.brcond(c.c, c.t, c.f),
            .chain => |t| try l.b.exit(.@"exit.chain", t),
            .indirect => |t| try l.b.exitIndirect(t),
        }
    }

    /// The block for a jump to guest PC t: its block if the region has
    /// the instruction, else a new block that leaves for it.
    fn jumpBlock(l: *Lifter, t: u32) !ir.BlockId {
        if (l.indexOf(t)) |k| return l.block_of[k];
        const id = try l.b.block();
        try l.pending_exits.append(l.b.gpa, .{ .id = id, .pc = t });
        return id;
    }

    fn fillExits(l: *Lifter) !void {
        for (l.pending_exits.items) |x| {
            l.b.begin(x.id);
            try l.b.exit(.@"exit.chain", x.pc);
        }
        l.pending_exits.clearRetainingCapacity();
    }

    /// Ends the block on a branch to `t` (direct jumps).
    fn jumpTo(l: *Lifter, t: u32) !void {
        if (l.indexOf(t)) |k| return l.endBlock(.{ .br = l.block_of[k] });
        try l.endBlock(.{ .chain = t });
    }

    /// Runs instruction k through T0 if `c` (or not `c`, if `slow_if`
    /// is false) holds, and goes on in a new block otherwise. Nothing of
    /// instruction k may have been written yet, and values from before
    /// the guard can't be used after it.
    fn guard(l: *Lifter, k: usize, c: Ref, slow_if: bool) !void {
        const b = l.b;
        try l.leave();
        try l.retireAll();
        const slow = try b.block();
        const cont = try b.block();
        if (slow_if) try b.brcond(c, slow, cont) else try b.brcond(c, cont, slow);
        b.begin(slow);
        try b.interp(handle(.step, l.insns[k].i.len, 0), l.insns[k].pc);
        b.retired = 1;
        try b.exit(.@"exit.chain", l.next(k));
        const ok = l.seg_ok;
        l.startBlock(cont);
        l.seg_ok = ok;
    }

    fn callInterp(l: *Lifter, k: usize) !void {
        try l.leave();
        try l.b.interp(handle(.step, l.insns[k].i.len, 0), l.insns[k].pc);
        l.fl.forget();
        l.seg_ok = 0;
    }

    // ------------------------------------------------------ operands

    fn getR(l: *Lifter, n: u3, size: u8) !Ref {
        return switch (size) {
            1 => l.b.getreg(.i8, byteOff(n)),
            2 => l.b.getreg(.i16, regOff(n)),
            else => l.b.getreg(.i32, regOff(n)),
        };
    }

    fn setR(l: *Lifter, n: u3, size: u8, v: Ref) !void {
        try l.b.setreg(if (size == 1) byteOff(n) else regOff(n), v);
    }

    fn k32(l: *Lifter, v: u64) !Ref {
        return l.b.konst(.i32, v);
    }

    /// The memory operand's offset, before the segment base.
    fn effAddr(l: *Lifter, i: *const Inst) !Ref {
        return l.effAddrEsp(i, null);
    }

    /// `effAddr`, with ESP's value given (POP to memory addresses with
    /// ESP after the pop).
    fn effAddrEsp(l: *Lifter, i: *const Inst, esp: ?Ref) !Ref {
        const b = l.b;
        const R = struct {
            fn get(ll: *Lifter, n: u4, e: ?Ref) !Ref {
                if (n == ESP) if (e) |v| return v;
                return ll.b.getreg(.i32, regOff(@intCast(n)));
            }
        };
        var a: ?Ref = null;
        if (i.base != dec.no_reg) a = try R.get(l, i.base, esp);
        if (i.index != dec.no_reg) {
            var x = try R.get(l, i.index, esp);
            if (i.scale != 0) x = try b.bin(.shl, .i32, x, try l.k32(i.scale));
            a = if (a) |y| try b.bin(.add, .i32, y, x) else x;
        }
        if (a == null) {
            a = try l.k32(i.disp);
        } else if (i.disp != 0) {
            a = try b.bin(.add, .i32, a.?, try l.k32(i.disp));
        }
        if (i.addr16) a = try b.bin(.@"and", .i32, a.?, try l.k32(0xffff));
        return a.?;
    }

    /// The memory operand's linear address. Through a null FS or GS, T0
    /// raises #GP: a guard, once per block.
    fn linear(l: *Lifter, k: usize) !Ref {
        const i = &l.insns[k].i;
        const s = @intFromEnum(i.seg);
        if (s >= 4) {
            const sbit = @as(u8, 1) << @intCast(s);
            if (l.seg_ok & sbit == 0) {
                const b = l.b;
                const nulls = try b.getreg(.i8, seg_null_off);
                const t = try b.bin(.@"and", .i8, nulls, try b.konst(.i8, sbit));
                try l.guard(k, try b.icmp(.ne, t, try b.konst(.i8, 0)), true);
                l.seg_ok |= sbit;
            }
            const off = try l.effAddr(i);
            const base = try l.b.getreg(.i32, seg_base_off + @as(u64, s) * 4);
            return l.b.bin(.add, .i32, off, base);
        }
        return l.effAddr(i);
    }

    fn load(l: *Lifter, k: usize, size: u8, addr: Ref) !Ref {
        return l.loadF(k, size, addr, false);
    }

    /// `rmw`: the first half of a read-modify-write, which faults as a
    /// write.
    fn loadF(l: *Lifter, k: usize, size: u8, addr: Ref, rmw: bool) !Ref {
        try l.leave();
        return l.b.load(tyOf(size), addr, .{ .size = log2(size), .rmw = rmw }, l.insns[k].pc);
    }

    fn store(l: *Lifter, k: usize, addr: Ref, v: Ref) !void {
        try l.leave();
        const ty = l.b.r.insts.items[v].ty;
        try l.b.store(addr, v, .{ .size = log2(@intCast(ty.bits() / 8)) }, l.insns[k].pc);
    }

    /// The register an operand names.
    fn regOf(i: *const Inst, o: table.Opd) u3 {
        return switch (o) {
            .E => i.rm(),
            .G => i.reg(),
            .Z => i.zreg(),
            else => 0, // .A
        };
    }

    fn isMem(i: *const Inst, o: table.Opd) bool {
        return (o == .E and i.mem) or o == .O;
    }

    /// Reads operand `o`; `addr` is the memory operand's address.
    fn get(l: *Lifter, k: usize, addr: ?Ref, o: table.Opd, size: u8) !Ref {
        const i = &l.insns[k].i;
        if (isMem(i, o)) return l.load(k, size, addr.?);
        return switch (o) {
            .E, .G, .A, .Z => l.getR(regOf(i, o), size),
            .I => l.b.konst(tyOf(size), i.imm & mask(size)),
            .one => l.b.konst(tyOf(size), 1),
            .CL => l.b.getreg(.i8, regOff(1)),
            else => unreachable,
        };
    }

    /// Reads a destination operand that the instruction then writes.
    fn getDst(l: *Lifter, k: usize, addr: ?Ref, o: table.Opd, size: u8) !Ref {
        const i = &l.insns[k].i;
        if (isMem(i, o)) return l.loadF(k, size, addr.?, true);
        return l.get(k, addr, o, size);
    }

    fn put(l: *Lifter, k: usize, addr: ?Ref, o: table.Opd, size: u8, v: Ref) !void {
        const i = &l.insns[k].i;
        if (isMem(i, o)) return l.store(k, addr.?, v);
        try l.setR(regOf(i, o), size, v);
    }

    fn needFlags(l: *const Lifter, k: usize) bool {
        const x = dec.effects(&l.insns[k].i);
        return l.live_out[k] & x.flags_written != 0;
    }

    fn setFlags(l: *Lifter, op: ir.Op, x: Ref, y: Ref) !void {
        l.fl.set(try l.b.flags(op, x, y));
    }

    fn setFlags3(l: *Lifter, op: ir.Op, x: Ref, y: Ref, f: Ref) !void {
        l.fl.set(try l.b.emit(.{ .op = op, .ty = .flags, .a = x, .b = y, .c = f }));
    }

    fn sel(l: *Lifter, ty: Type, c: Ref, x: Ref, y: Ref) !Ref {
        return l.b.emit(.{ .op = .select, .ty = ty, .a = c, .b = x, .c = y });
    }

    /// i1 to an integer of `ty`.
    fn widen(l: *Lifter, ty: Type, c: Ref) !Ref {
        return l.b.un(.zext, ty, c);
    }

    // ------------------------------------------------------ instructions

    /// Lifts instruction k (and k+1, for call-next-pop); returns how many.
    fn one(l: *Lifter, k: usize) !usize {
        const in = &l.insns[k];
        const i = &in.i;
        const e = i.tableEntry();
        const b = l.b;
        switch (in.class) {
            .interp => {
                try l.callInterp(k);
                l.count += 1;
                return 1;
            },
            .stop => {
                try l.callInterp(k);
                l.count += 1;
                try l.endBlock(.{ .chain = l.next(k) });
                return 1;
            },
            else => {},
        }
        if (isAtomic(i)) {
            try l.atomic(k);
            return 1;
        }
        if (isString(i.op)) {
            if (i.rep != .none) try l.repString(k) else try l.string(k);
            return 1;
        }
        if (i.op == .pop and i.mem) {
            try l.popMem(k);
            return 1;
        }
        // The memory operand's address comes first: its guard has to
        // run before anything else of the instruction.
        const addr: ?Ref = if (i.mem and i.op != .lea and i.op != .nop) try l.linear(k) else null;
        const size = i.size;
        const T = tyOf(size);
        var consumed: usize = 1;
        switch (i.op) {
            .nop => {},
            .fence => _ = try b.emit(.{ .op = .fence, .aux = 0 }),
            .add, .@"or", .adc, .sbb, .@"and", .sub, .xor, .cmp, .@"test" => {
                const y = try l.get(k, addr, e.src, size);
                const rmw = i.op != .cmp and i.op != .@"test";
                const x = if (rmw) try l.getDst(k, addr, e.dst, size) else try l.get(k, addr, e.dst, size);
                const need = l.needFlags(k);
                switch (i.op) {
                    .add, .sub, .cmp => {
                        const sub = i.op != .add;
                        if (i.op != .cmp) try l.put(k, addr, e.dst, size, try b.bin(if (sub) .sub else .add, T, x, y));
                        if (need) try l.setFlags(if (sub) .@"eflags.sub" else .@"eflags.add", x, y);
                    },
                    .adc, .sbb => {
                        const f = try l.fl.get(b);
                        const cin = try l.widen(T, try l.fl.cond(b, xf.cc_b));
                        const adc = i.op == .adc;
                        const op: ir.Op = if (adc) .add else .sub;
                        const res = try b.bin(op, T, try b.bin(op, T, x, y), cin);
                        try l.put(k, addr, e.dst, size, res);
                        if (need) try l.setFlags3(if (adc) .@"eflags.adc" else .@"eflags.sbb", x, y, f);
                    },
                    else => {
                        const op: ir.Op = switch (i.op) {
                            .@"or" => .@"or",
                            .xor => .xor,
                            else => .@"and",
                        };
                        const res = try b.bin(op, T, x, y);
                        if (i.op != .@"test") try l.put(k, addr, e.dst, size, res);
                        if (need) l.fl.set(try b.un(.@"eflags.logic", .flags, res));
                    },
                }
            },
            .inc, .dec => {
                const x = try l.getDst(k, addr, e.dst, size);
                const one_ = try b.konst(T, 1);
                const inc = i.op == .inc;
                // The flags before the store: a store can leave, and
                // these come from what's current now.
                const res = try b.bin(if (inc) .add else .sub, T, x, one_);
                if (l.needFlags(k)) {
                    const f = try l.fl.get(b);
                    try l.put(k, addr, e.dst, size, res);
                    l.fl.set(try b.emit(.{ .op = if (inc) .@"eflags.inc" else .@"eflags.dec", .ty = .flags, .a = x, .b = f }));
                } else try l.put(k, addr, e.dst, size, res);
            },
            .not => {
                const x = try l.getDst(k, addr, e.dst, size);
                try l.put(k, addr, e.dst, size, try b.un(.not, T, x));
            },
            .neg => {
                const x = try l.getDst(k, addr, e.dst, size);
                const zero = try b.konst(T, 0);
                try l.put(k, addr, e.dst, size, try b.bin(.sub, T, zero, x));
                if (l.needFlags(k)) try l.setFlags(.@"eflags.sub", zero, x);
            },
            .shl, .shr, .sar => try l.shift(k, addr),
            .rol, .ror => try l.rotate(k, addr),
            .shld, .shrd => try l.shiftDouble(k, addr),
            .bt, .bts, .btr, .btc => try l.bitTest(k, addr),
            .bsf, .bsr => {
                const v = try l.get(k, addr, e.src, size);
                const v32 = if (T == .i32) v else try b.un(.zext, .i32, v);
                const idx = if (i.op == .bsf)
                    try b.un(.ctz, .i32, v32)
                else
                    try b.bin(.sub, .i32, try l.k32(31), try b.un(.clz, .i32, v32));
                const res = if (T == .i32) idx else try b.un(.trunc, T, idx);
                const zero = try b.icmp(.eq, v, try b.konst(T, 0));
                // The destination is written only for a nonzero source.
                try l.setR(i.reg(), size, try l.sel(T, zero, try l.getR(i.reg(), size), res));
                if (l.needFlags(k)) l.fl.set(try b.un(.@"eflags.logic", .flags, v));
            },
            .mul, .imul1 => {
                const y = try l.get(k, addr, e.src, size);
                const x = try l.getR(0, size);
                const signed = i.op == .imul1;
                const lo = try b.bin(.mul, T, x, y);
                const hi = try b.bin(if (signed) .mulhs else .mulhu, T, x, y);
                switch (size) {
                    1 => {
                        try l.setR(0, 1, lo);
                        try l.setR(4, 1, hi); // AH
                    },
                    else => {
                        try l.setR(0, size, lo);
                        try l.setR(2, size, hi);
                    },
                }
                if (l.needFlags(k)) try l.mulFlags(T, lo, hi, signed);
            },
            .imul => {
                const x = try l.get(k, addr, e.src, size);
                const y = if (e.imm != .none) try b.konst(T, i.imm & mask(size)) else try l.getR(i.reg(), size);
                const lo = try b.bin(.mul, T, x, y);
                const hi = try b.bin(.mulhs, T, x, y);
                try l.setR(i.reg(), size, lo);
                if (l.needFlags(k)) try l.mulFlags(T, lo, hi, true);
            },
            .div, .idiv => try l.divide(k),
            .mov => try l.put(k, addr, e.dst, size, try l.get(k, addr, e.src, size)),
            .movzx, .movsx => {
                const ss: u8 = if (e.src_size == .b) 1 else 2;
                const v = try l.get(k, addr, e.src, ss);
                try l.setR(i.reg(), size, if (ss == size) v else try b.un(if (i.op == .movzx) .zext else .sext, T, v));
            },
            .lea => {
                const a = try l.effAddr(i);
                try l.setR(i.reg(), size, if (size == 4) a else try b.un(.trunc, T, a));
            },
            .xchg => {
                const x = try l.getDst(k, addr, e.dst, size);
                const y = try l.get(k, addr, e.src, size);
                try l.put(k, addr, e.dst, size, y);
                try l.put(k, addr, e.src, size, x);
            },
            .xadd => {
                // The destination is written last, so XADD of a register
                // with itself leaves the sum.
                const y = try l.getR(i.reg(), size);
                const x = try l.getR(i.rm(), size);
                try l.setR(i.reg(), size, x);
                try l.setR(i.rm(), size, try b.bin(.add, T, x, y));
                if (l.needFlags(k)) try l.setFlags(.@"eflags.add", x, y);
            },
            .cmpxchg => {
                const acc = try l.getR(0, size);
                const src_ = try l.getR(i.reg(), size);
                const old = try l.getR(i.rm(), size);
                const eq = try b.icmp(.eq, old, acc);
                try l.setR(i.rm(), size, try l.sel(T, eq, src_, old));
                const now = try l.getR(0, size);
                try l.setR(0, size, try l.sel(T, eq, now, old));
                if (l.needFlags(k)) try l.setFlags(.@"eflags.sub", acc, old);
            },
            .bswap => {
                const r = i.zreg();
                try l.setR(r, 4, try b.un(.bswap, .i32, try l.getR(r, 4)));
            },
            .cbw => if (size == 2) {
                try l.setR(0, 2, try b.un(.sext, .i16, try l.getR(0, 1)));
            } else {
                try l.setR(0, 4, try b.un(.sext, .i32, try l.getR(0, 2)));
            },
            .cwd => {
                const ax = try l.getR(0, size);
                const bits: u64 = @as(u64, size) * 8 - 1;
                try l.setR(2, size, try b.bin(.ashr, T, ax, try b.konst(T, bits)));
            },
            .push => {
                const v = try l.get(k, addr, e.src, size);
                const sp = try l.getR(ESP, 4);
                const nsp = try b.bin(.sub, .i32, sp, try l.k32(size));
                try l.store(k, nsp, v);
                try l.setR(ESP, 4, nsp);
            },
            .pop => {
                const sp = try l.getR(ESP, 4);
                const v = try l.load(k, size, sp);
                try l.setR(ESP, 4, try b.bin(.add, .i32, sp, try l.k32(size)));
                try l.setR(regOf(i, e.dst), size, v);
            },
            .leave => {
                const bp = try l.getR(5, 4);
                const v = try l.load(k, size, bp);
                try l.setR(ESP, 4, try b.bin(.add, .i32, bp, try l.k32(size)));
                try l.setR(5, size, v);
            },
            .setcc => {
                const c = try l.fl.cond(b, i.cc());
                try l.put(k, addr, e.dst, 1, try l.widen(.i8, c));
            },
            .cmovcc => {
                const v = try l.get(k, addr, e.src, size);
                const c = try l.fl.cond(b, i.cc());
                const old = try l.getR(i.reg(), size);
                try l.setR(i.reg(), size, try b.emit(.{ .op = .select, .ty = T, .a = c, .b = v, .c = old }));
            },
            .clc => try l.fl.modify(b, .@"and", ~xf.CF),
            .stc => try l.fl.modify(b, .@"or", xf.CF),
            .cmc => try l.fl.modify(b, .xor, xf.CF),
            .cld, .std => {
                const old = try b.getreg(.i32, xf.bits_off);
                const v = if (i.op == .cld)
                    try b.bin(.@"and", .i32, old, try l.k32(~xf.DF))
                else
                    try b.bin(.@"or", .i32, old, try l.k32(xf.DF));
                try b.setreg(xf.bits_off, v);
            },
            .jcc, .loop, .loope, .loopne, .jcxz => {
                const c = try l.branchCond(k);
                l.count += 1;
                const taken = try l.jumpBlock(l.target(k));
                try l.endBlock(.{ .brcond = .{ .c = c, .t = taken, .f = l.block_of[k + 1] } });
                try l.fillExits();
                return 1;
            },
            .jmp => {
                l.count += 1;
                try l.jumpTo(l.target(k));
                return 1;
            },
            .call => {
                const nx = l.next(k);
                const sp = try l.getR(ESP, 4);
                const nsp = try b.bin(.sub, .i32, sp, try l.k32(4));
                try l.store(k, nsp, try l.k32(nx));
                if (i.imm == 0 and l.fusesPop(k)) {
                    // call next; pop r: r = next, and ESP is as it was.
                    try l.setR(l.insns[k + 1].i.zreg(), 4, try l.k32(nx));
                    consumed = 2;
                } else {
                    try l.setR(ESP, 4, nsp);
                }
                l.count += consumed;
                if (i.imm != 0) {
                    try l.jumpTo(l.target(k));
                }
                return consumed;
            },
            .ret => {
                const sp = try l.getR(ESP, 4);
                const t = try l.load(k, 4, sp);
                try l.setR(ESP, 4, try b.bin(.add, .i32, sp, try l.k32(4 + (i.imm & 0xffff))));
                l.count += 1;
                try l.endBlock(.{ .indirect = t });
                return 1;
            },
            .jmp_ind => {
                const t = try l.get(k, addr, e.src, 4);
                l.count += 1;
                try l.endBlock(.{ .indirect = t });
                return 1;
            },
            .call_ind => {
                const t = try l.get(k, addr, e.src, 4);
                const sp = try l.getR(ESP, 4);
                const nsp = try b.bin(.sub, .i32, sp, try l.k32(4));
                try l.store(k, nsp, try l.k32(l.next(k)));
                try l.setR(ESP, 4, nsp);
                l.count += 1;
                try l.endBlock(.{ .indirect = t });
                return 1;
            },
            else => unreachable,
        }
        l.count += consumed;
        return consumed;
    }

    /// `call next` followed by `pop r` (not ESP), with nothing jumping to
    /// the pop.
    fn fusesPop(l: *const Lifter, k: usize) bool {
        if (k + 1 >= l.insns.len or l.leader[k + 1]) return false;
        const p = &l.insns[k + 1];
        return p.class == .lifted and p.i.op == .pop and p.i.opcode >= 0x58 and p.i.opcode <= 0x5f and
            p.i.size == 4 and p.i.zreg() != ESP;
    }

    fn branchCond(l: *Lifter, k: usize) !Ref {
        const i = &l.insns[k].i;
        const b = l.b;
        switch (i.op) {
            .jcc => return l.fl.cond(b, i.cc()),
            .jcxz => return b.icmp(.eq, try l.getR(1, 4), try l.k32(0)),
            else => {
                const cx = try b.bin(.sub, .i32, try l.getR(1, 4), try l.k32(1));
                try l.setR(1, 4, cx);
                const nz = try b.icmp(.ne, cx, try l.k32(0));
                if (i.op == .loop) return nz;
                const z = try l.fl.cond(b, if (i.op == .loope) xf.cc_e else xf.cc_ne);
                return b.bin(.@"and", .i1, nz, z);
            },
        }
    }

    /// CF = OF = whether the high half isn't the low half's extension.
    fn mulFlags(l: *Lifter, T: Type, lo: Ref, hi: Ref, signed: bool) !void {
        const b = l.b;
        const ext = if (signed)
            try b.bin(.ashr, T, lo, try b.konst(T, T.bits() - 1))
        else
            try b.konst(T, 0);
        const ovf = try l.widen(T, try b.icmp(.ne, hi, ext));
        try l.setFlags(.@"eflags.mul", ovf, lo);
    }

    /// SHL, SHR, and SAR by a constant, or by CL into a register. The
    /// work is at 32 bits, so counts past an 8- or 16-bit operand's width
    /// shift everything out, as on the CPU.
    fn shift(l: *Lifter, k: usize, addr: ?Ref) !void {
        const i = &l.insns[k].i;
        const e = i.tableEntry();
        const b = l.b;
        const size = i.size;
        const T = tyOf(size);
        const op: ir.Op = switch (i.op) {
            .shl => .shl,
            .shr => .lshr,
            else => .ashr,
        };
        const x = try l.getDst(k, addr, e.dst, size);
        const x32 = if (T == .i32) x else try b.un(if (i.op == .sar) .sext else .zext, .i32, x);
        const narrow = struct {
            fn f(bb: *Builder, t: Type, v: Ref) !Ref {
                return if (t == .i32) v else bb.un(.trunc, t, v);
            }
        }.f;
        if (e.src != .CL) {
            const n: u32 = if (e.src == .one) 1 else i.imm & 31;
            if (n == 0) return;
            const res = try narrow(b, T, try b.bin(op, .i32, x32, try l.k32(n)));
            try l.put(k, addr, e.dst, size, res);
            if (l.needFlags(k)) {
                const pre = try narrow(b, T, try b.bin(op, .i32, x32, try l.k32(n - 1)));
                try l.setFlags(if (i.op == .shl) .@"eflags.shl" else .@"eflags.shr", pre, res);
            }
            return;
        }
        // By CL, into a register: a count of 0 changes nothing.
        const cnt = try b.bin(.@"and", .i32, try b.un(.zext, .i32, try l.getR(1, 1)), try l.k32(31));
        const zero = try b.icmp(.eq, cnt, try l.k32(0));
        const res = try narrow(b, T, try b.bin(op, .i32, x32, cnt));
        try l.put(k, addr, e.dst, size, try b.emit(.{ .op = .select, .ty = T, .a = zero, .b = x, .c = res }));
        if (l.needFlags(k)) {
            const old = try l.fl.get(b);
            const pre = try narrow(b, T, try b.bin(op, .i32, x32, try b.bin(.sub, .i32, cnt, try l.k32(1))));
            const f = try b.flags(if (i.op == .shl) .@"eflags.shl" else .@"eflags.shr", pre, res);
            l.fl.set(try b.emit(.{ .op = .select, .ty = .flags, .a = zero, .b = old, .c = f }));
        }
    }

    /// DIV and IDIV of a register. #DE (a zero divisor, or a quotient
    /// too big) goes to T0 through a guard; the division runs at twice
    /// the width.
    fn divide(l: *Lifter, k: usize) !void {
        const ok = try l.divide1(k, false);
        try l.guard(k, ok, false);
        _ = try l.divide1(k, true);
    }

    /// Computes the division; returns whether it's free of #DE, and
    /// writes the results if `write`.
    fn divide1(l: *Lifter, k: usize, write: bool) !Ref {
        const i = &l.insns[k].i;
        const b = l.b;
        const size = i.size;
        const T = tyOf(size);
        const W = wideOf(size);
        const bits: u64 = @as(u64, size) * 8;
        const d = try l.getR(i.rm(), size);
        // The dividend: AX, DX:AX, or EDX:EAX.
        const n = if (size == 1) try l.getR(0, 2) else blk: {
            const lo = try b.un(.zext, W, try l.getR(0, size));
            const hi = try b.un(.zext, W, try l.getR(2, size));
            break :blk try b.bin(.@"or", W, try b.bin(.shl, W, hi, try b.konst(W, bits)), lo);
        };
        const signed = i.op == .idiv;
        const dw = try b.un(if (signed) .sext else .zext, W, d);
        const q = try b.bin(if (signed) .sdiv else .udiv, W, n, dw);
        const r = try b.bin(if (signed) .srem else .urem, W, n, dw);
        const qn = try b.un(.trunc, T, q);
        const rn = try b.un(.trunc, T, r);
        if (write) {
            if (size == 1) {
                try l.setR(0, 1, qn);
                try l.setR(4, 1, rn); // AH
            } else {
                try l.setR(0, size, qn);
                try l.setR(2, size, rn);
            }
            return d;
        }
        const nz = try b.icmp(.ne, d, try b.konst(T, 0));
        const back = try b.un(if (signed) .sext else .zext, W, qn);
        const fits = try b.icmp(.eq, back, q);
        return b.bin(.@"and", .i1, nz, fits);
    }

    /// Sets CF and OF in the flags, from i32 0-or-1 values.
    fn setCfOf(l: *Lifter, cf: Ref, of: Ref) !void {
        const b = l.b;
        const p = try b.un(.@"eflags.pack", .i32, try l.fl.get(b));
        const keep = try b.bin(.@"and", .i32, p, try l.k32(~(xf.CF | xf.OF)));
        const o = try b.bin(.shl, .i32, of, try l.k32(11));
        l.fl.set(try b.un(.@"eflags.unpack", .flags, try b.bin(.@"or", .i32, keep, try b.bin(.@"or", .i32, cf, o))));
    }

    /// Bit n of the i32 v, as an i32 0 or 1.
    fn bit(l: *Lifter, v: Ref, n: u32) !Ref {
        const b = l.b;
        return b.bin(.@"and", .i32, try b.bin(.lshr, .i32, v, try l.k32(n)), try l.k32(1));
    }

    /// ROL and ROR by a constant, or by CL into a register. CF and OF
    /// only, as T0 computes them (for any count but 0, OF as for 1).
    fn rotate(l: *Lifter, k: usize, addr: ?Ref) !void {
        const i = &l.insns[k].i;
        const e = i.tableEntry();
        const b = l.b;
        const size = i.size;
        const T = tyOf(size);
        const bits: u32 = @as(u32, size) * 8;
        const op: ir.Op = if (i.op == .rol) .rol else .ror;
        const x = try l.getDst(k, addr, e.dst, size);
        var cnt: Ref = undefined;
        var zero: ?Ref = null;
        if (e.src == .CL) {
            const raw = try b.bin(.@"and", .i8, try l.getR(1, 1), try b.konst(.i8, 31));
            zero = try b.icmp(.eq, raw, try b.konst(.i8, 0));
            cnt = if (T == .i8) raw else try b.un(.zext, T, raw);
        } else {
            const n: u32 = if (e.src == .one) 1 else i.imm & 31;
            if (n == 0) return;
            cnt = try b.konst(T, n);
        }
        const r = try b.bin(op, T, x, cnt);
        const res = if (zero) |z| try l.sel(T, z, x, r) else r;
        try l.put(k, addr, e.dst, size, res);
        if (!l.needFlags(k)) return;
        const r32 = if (T == .i32) r else try b.un(.zext, .i32, r);
        const top = try l.bit(r32, bits - 1);
        var cf: Ref = undefined;
        var of: Ref = undefined;
        if (i.op == .rol) {
            cf = try b.bin(.@"and", .i32, r32, try l.k32(1));
            of = try b.bin(.xor, .i32, top, cf);
        } else {
            cf = top;
            of = try b.bin(.xor, .i32, top, try l.bit(r32, bits - 2));
        }
        const old = try l.fl.get(b);
        try l.setCfOf(cf, of);
        if (zero) |z| l.fl.set(try l.sel(.flags, z, old, l.fl.cur.?));
    }

    /// SHLD and SHRD, by a constant, or by CL into a register: at 64
    /// bits, the destination and the source side by side.
    fn shiftDouble(l: *Lifter, k: usize, addr: ?Ref) !void {
        const i = &l.insns[k].i;
        const e = i.tableEntry();
        const b = l.b;
        const size = i.size;
        const T = tyOf(size);
        const bits: u64 = @as(u64, size) * 8;
        const left = i.op == .shld;
        const x = try l.getDst(k, addr, e.dst, size);
        const y = try l.getR(i.reg(), size);
        const x64 = try b.un(.zext, .i64, x);
        const y64 = try b.un(.zext, .i64, y);
        const sh = try b.konst(.i64, bits);
        const v = if (left)
            try b.bin(.@"or", .i64, try b.bin(.shl, .i64, x64, sh), y64)
        else
            try b.bin(.@"or", .i64, try b.bin(.shl, .i64, y64, sh), x64);
        var cnt: Ref = undefined;
        var zero: ?Ref = null;
        if (e.imm != .b) {
            cnt = try b.bin(.@"and", .i64, try b.un(.zext, .i64, try l.getR(1, 1)), try b.konst(.i64, 31));
            zero = try b.icmp(.eq, cnt, try b.konst(.i64, 0));
        } else {
            const n: u64 = i.imm & 31;
            if (n == 0) return;
            cnt = try b.konst(.i64, n);
        }
        const S = struct {
            fn at(bb: *Builder, t: Type, lft: bool, vv: Ref, c: Ref, s: Ref) !Ref {
                const w = if (lft)
                    try bb.bin(.lshr, .i64, try bb.bin(.shl, .i64, vv, c), s)
                else
                    try bb.bin(.lshr, .i64, vv, c);
                return bb.un(.trunc, t, w);
            }
        };
        const r = try S.at(b, T, left, v, cnt, sh);
        const res = if (zero) |z| try l.sel(T, z, x, r) else r;
        try l.put(k, addr, e.dst, size, res);
        if (!l.needFlags(k)) return;
        const pre = try S.at(b, T, left, v, try b.bin(.sub, .i64, cnt, try b.konst(.i64, 1)), sh);
        const f = try b.flags(if (left) .@"eflags.shl" else .@"eflags.shr", pre, r);
        if (zero) |z| {
            const old = try l.fl.get(b);
            l.fl.set(try l.sel(.flags, z, old, f));
        } else l.fl.set(f);
    }

    /// BT, BTS, BTR, and BTC (without LOCK). A register bit offset reaches
    /// outside a memory operand, by whole operands.
    fn bitTest(l: *Lifter, k: usize, addr0: ?Ref) !void {
        const i = &l.insns[k].i;
        const e = i.tableEntry();
        const b = l.b;
        const size = i.size;
        const T = tyOf(size);
        const bits: u32 = @as(u32, size) * 8;
        var addr = addr0;
        var n: Ref = undefined;
        if (e.src == .I) {
            n = try b.konst(T, i.imm & (bits - 1));
        } else {
            const off = try l.getR(i.reg(), size);
            n = try b.bin(.@"and", T, off, try b.konst(T, bits - 1));
            if (i.mem) {
                const so = if (T == .i32) off else try b.un(.sext, .i32, off);
                const words = try b.bin(.ashr, .i32, so, try l.k32(@ctz(bits)));
                const delta = try b.bin(.mul, .i32, words, try l.k32(size));
                addr = try b.bin(.add, .i32, addr.?, delta);
            }
        }
        const one_ = try b.konst(T, 1);
        const m = try b.bin(.shl, T, one_, n);
        const old = if (i.op == .bt) try l.get(k, addr, e.dst, size) else try l.getDst(k, addr, e.dst, size);
        if (i.op != .bt) {
            const new = switch (i.op) {
                .bts => try b.bin(.@"or", T, old, m),
                .btr => try b.bin(.andn, T, old, m),
                else => try b.bin(.xor, T, old, m),
            };
            try l.put(k, addr, e.dst, size, new);
        }
        if (!l.needFlags(k)) return;
        const bv = try b.bin(.@"and", T, try b.bin(.lshr, T, old, n), one_);
        const cf = if (T == .i32) bv else try b.un(.zext, .i32, bv);
        const p = try b.un(.@"eflags.pack", .i32, try l.fl.get(b));
        const keep = try b.bin(.@"and", .i32, p, try l.k32(~xf.CF));
        l.fl.set(try b.un(.@"eflags.unpack", .flags, try b.bin(.@"or", .i32, keep, cf)));
    }

    /// POP to memory: the address uses ESP after the pop, and a fault
    /// storing leaves ESP as it was.
    fn popMem(l: *Lifter, k: usize) !void {
        const i = &l.insns[k].i;
        const b = l.b;
        const size = i.size;
        const sp = try l.getR(ESP, 4);
        const v = try l.load(k, size, sp);
        const nsp = try b.bin(.add, .i32, sp, try l.k32(size));
        const a = try l.effAddrEsp(i, nsp);
        try l.store(k, a, v);
        try l.setR(ESP, 4, nsp);
        l.count += 1;
    }

    /// MOVS, STOS, LODS, CMPS, and SCAS without REP: one iteration, ESI
    /// and EDI stepping by DF.
    fn string(l: *Lifter, k: usize) !void {
        const i = &l.insns[k].i;
        const b = l.b;
        const size = i.size;
        const T = tyOf(size);
        const df = try b.bin(.@"and", .i32, try b.getreg(.i32, xf.bits_off), try l.k32(xf.DF));
        const back = try b.icmp(.ne, df, try l.k32(0));
        const d = try l.sel(.i32, back, try l.k32(@as(u32, 0) -% size), try l.k32(size));
        const si = try l.getR(6, 4);
        const di = try l.getR(7, 4);
        const src_addr = if (@intFromEnum(i.seg) >= 4)
            try b.bin(.add, .i32, si, try b.getreg(.i32, seg_base_off + @as(u64, @intFromEnum(i.seg)) * 4))
        else
            si;
        switch (i.op) {
            .movs => {
                const v = try l.load(k, size, src_addr);
                try l.store(k, di, v);
                try l.setR(6, 4, try b.bin(.add, .i32, si, d));
                try l.setR(7, 4, try b.bin(.add, .i32, di, d));
            },
            .stos => {
                try l.store(k, di, try l.getR(0, size));
                try l.setR(7, 4, try b.bin(.add, .i32, di, d));
            },
            .lods => {
                const v = try l.load(k, size, src_addr);
                try l.setR(0, size, v);
                try l.setR(6, 4, try b.bin(.add, .i32, si, d));
            },
            .cmps => {
                const x = try l.load(k, size, src_addr);
                const y = try l.load(k, size, di);
                try l.setR(6, 4, try b.bin(.add, .i32, si, d));
                try l.setR(7, 4, try b.bin(.add, .i32, di, d));
                if (l.needFlags(k)) try l.setFlags(.@"eflags.sub", x, y);
            },
            .scas => {
                const x = try l.getR(0, size);
                const y = try l.load(k, size, di);
                try l.setR(7, 4, try b.bin(.add, .i32, di, d));
                if (l.needFlags(k)) try l.setFlags(.@"eflags.sub", x, y);
            },
            else => unreachable,
        }
        _ = T;
        l.count += 1;
    }

    /// An atomic read-modify-write (see `isAtomic`). An access that isn't
    /// naturally aligned (a split lock) goes to T0, which serializes it
    /// under its own lock. The retrying ones are a block of their own: a
    /// load, the new value, and a `cas`; if the `cas` finds another value,
    /// nothing has been written (registers and flags are written through
    /// selects that keep the old values) and the block runs again.
    fn atomic(l: *Lifter, k: usize) !void {
        const i = &l.insns[k].i;
        const b = l.b;
        const pc = l.insns[k].pc;
        const e = i.tableEntry();
        const size: u8 = if (i.op == .cmpxchg8b) 8 else i.size;
        const T: Type = if (size == 8) .i64 else tyOf(size);
        const retry = retries(i);
        const loop = if (retry) try b.block() else undefined;
        if (retry) {
            try l.endBlock(.{ .br = loop });
            l.startBlock(loop);
        }
        const addr = try l.linear(k);
        if (size > 1) {
            const mis = try b.bin(.@"and", .i32, addr, try l.k32(size - 1));
            try l.guard(k, try b.icmp(.ne, mis, try l.k32(0)), true);
        }
        // Values from before the guard are gone: recompute the address.
        const a = try l.linearAgain(k);
        try l.leave();
        const f: ir.MemFlags = .{ .size = switch (size) {
            1 => 0,
            2 => 1,
            4 => 2,
            else => 3,
        } };
        if (!retry) {
            if (i.op == .cmpxchg8b) {
                const lo = try b.un(.zext, .i64, try l.getR(0, 4));
                const hi = try b.un(.zext, .i64, try l.getR(2, 4));
                const want = try b.bin(.@"or", .i64, try b.bin(.shl, .i64, hi, try b.konst(.i64, 32)), lo);
                const nlo = try b.un(.zext, .i64, try l.getR(3, 4));
                const nhi = try b.un(.zext, .i64, try l.getR(1, 4));
                const new = try b.bin(.@"or", .i64, try b.bin(.shl, .i64, nhi, try b.konst(.i64, 32)), nlo);
                const got = try b.cas(.i64, a, want, new, f, pc);
                const eq = try b.icmp(.eq, got, want);
                const glo = try b.un(.trunc, .i32, got);
                const ghi = try b.un(.trunc, .i32, try b.bin(.lshr, .i64, got, try b.konst(.i64, 32)));
                try l.setR(0, 4, try l.sel(.i32, eq, try l.getR(0, 4), glo));
                try l.setR(2, 4, try l.sel(.i32, eq, try l.getR(2, 4), ghi));
                const p = try b.un(.@"eflags.pack", .i32, try l.fl.get(b));
                const cleared = try b.bin(.@"and", .i32, p, try l.k32(~xf.ZF));
                const z = try b.bin(.shl, .i32, try b.un(.zext, .i32, eq), try l.k32(6));
                l.fl.set(try b.un(.@"eflags.unpack", .flags, try b.bin(.@"or", .i32, cleared, z)));
            } else {
                // CMPXCHG: the old value either way, in one cas.
                const acc = try l.getR(0, size);
                const src_ = try l.getR(i.reg(), size);
                const got = try b.cas(T, a, acc, src_, f, pc);
                const eq = try b.icmp(.eq, got, acc);
                try l.setR(0, size, try l.sel(T, eq, acc, got));
                if (l.needFlags(k)) try l.setFlags(.@"eflags.sub", acc, got);
            }
            l.count += 1;
            return;
        }
        const old = try b.load(T, a, .{ .size = f.size, .rmw = true }, pc);
        var new: Ref = undefined;
        var flags: ?Ref = null;
        const need = l.needFlags(k);
        switch (i.op) {
            .xchg => new = try l.getR(i.reg(), size),
            .xadd => {
                const y = try l.getR(i.reg(), size);
                new = try b.bin(.add, T, old, y);
                if (need) flags = try b.flags(.@"eflags.add", old, y);
            },
            .not => new = try b.un(.not, T, old),
            .neg => {
                const zero = try b.konst(T, 0);
                new = try b.bin(.sub, T, zero, old);
                if (need) flags = try b.flags(.@"eflags.sub", zero, old);
            },
            .inc, .dec => {
                const inc = i.op == .inc;
                new = try b.bin(if (inc) .add else .sub, T, old, try b.konst(T, 1));
                if (need) flags = try b.emit(.{ .op = if (inc) .@"eflags.inc" else .@"eflags.dec", .ty = .flags, .a = old, .b = try l.fl.get(b) });
            },
            else => {
                const y = try l.get(k, null, e.src, size);
                switch (i.op) {
                    .add, .sub => {
                        new = try b.bin(if (i.op == .add) .add else .sub, T, old, y);
                        if (need) flags = try b.flags(if (i.op == .add) .@"eflags.add" else .@"eflags.sub", old, y);
                    },
                    .adc, .sbb => {
                        const fo = try l.fl.get(b);
                        const cin = try l.widen(T, try l.fl.cond(b, xf.cc_b));
                        const op: ir.Op = if (i.op == .adc) .add else .sub;
                        new = try b.bin(op, T, try b.bin(op, T, old, y), cin);
                        if (need) flags = try b.emit(.{ .op = if (i.op == .adc) .@"eflags.adc" else .@"eflags.sbb", .ty = .flags, .a = old, .b = y, .c = fo });
                    },
                    else => {
                        const op: ir.Op = switch (i.op) {
                            .@"or" => .@"or",
                            .xor => .xor,
                            else => .@"and",
                        };
                        new = try b.bin(op, T, old, y);
                        if (need) flags = try b.un(.@"eflags.logic", .flags, new);
                    },
                }
            },
        }
        const got = try b.cas(T, a, old, new, f, pc);
        const ok = try b.icmp(.eq, got, old);
        // The register results, kept on a retry.
        if (i.op == .xchg or i.op == .xadd) {
            const r = i.reg();
            try l.setR(r, size, try l.sel(T, ok, old, try l.getR(r, size)));
        }
        if (flags) |nf| {
            const cur = try l.fl.get(b);
            l.fl.set(try l.sel(.flags, ok, nf, cur));
        }
        const cont = try b.block();
        try l.endBlock(.{ .brcond = .{ .c = ok, .t = cont, .f = loop } });
        l.startBlock(cont);
        l.count = 1;
    }

    /// The memory operand's linear address, after `linear` has guarded it.
    fn linearAgain(l: *Lifter, k: usize) !Ref {
        return l.linear(k);
    }

    /// REP MOVS, STOS, LODS, CMPS, and SCAS: a loop of T0 chunks of up
    /// to a page each, polling between them, so a long copy can be
    /// interrupted with ECX, ESI, and EDI exact.
    fn repString(l: *Lifter, k: usize) !void {
        const i = &l.insns[k].i;
        const b = l.b;
        const pc = l.insns[k].pc;
        const loop = try b.block();
        const done = try b.block();
        try l.endBlock(.{ .br = loop });
        l.startBlock(loop);
        try b.poll(pc);
        try b.interp(handle(.rep_chunk, i.len, i.size), pc);
        const ecx = try l.getR(1, 4);
        var fin = try b.icmp(.eq, ecx, try l.k32(0));
        if (i.op == .cmps or i.op == .scas) {
            const z = try b.bin(.@"and", .i32, try b.getreg(.i32, xf.bits_off), try l.k32(xf.ZF));
            // REPE stops on ZF clear, REPNE on ZF set.
            const stop = try b.icmp(if (i.rep == .rep) .eq else .ne, z, try l.k32(0));
            fin = try b.bin(.@"or", .i1, fin, stop);
        }
        try b.brcond(fin, done, loop);
        l.startBlock(done);
        l.count = 1;
    }
};
