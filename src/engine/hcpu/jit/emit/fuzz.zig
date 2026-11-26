//! Random IR for checking emitters against ir_eval: regions of a few
//! blocks, with every op at every width, flags of both groups feeding
//! conditions, branches, and selects, loads and stores that hit, miss, cross
//! pages, and fault, guest registers read and written at overlapping
//! widths, bounded loops, polls under a budget, and (for native emitters)
//! calls to the interpreter and helpers that read and write guest state.
//!
//! A region runs on cases.Env: eight guest registers, the last of them a
//! loop counter the generator keeps for itself, and a data page.
//!
//! The arm64 emitter's test runs a few thousand; `H9_FUZZ_SECONDS` runs it
//! for longer (see arm64.zig).

const std = @import("std");
const ir = @import("../ir.zig");
const cases = @import("cases.zig");
const Type = ir.Type;
const Op = ir.Op;
const Ref = ir.Ref;

pub const Options = struct {
    /// call.interp and call.helper (the Env's handlers).
    calls: bool = true,
    max_blocks: u32 = 6,
    max_insts: u32 = 40,
    /// Lazy eflags records (pending.flags aux2 2), for emitters that lower
    /// them.
    lazy_records: bool = false,
};

/// The loop counter's Cpu offset.
const fuel_off = 56;
/// pending.flags writes 48 or 52, which nothing else reads or writes.
const pending_off = 48;
/// A lazy pending.flags (aux2 2) at 24 has its record (ir.LazyRecord) at
/// 28..55, short of the loop counter.
const lazy_off = 24;

comptime {
    std.debug.assert(lazy_off + 4 + @sizeOf(ir.LazyRecord) <= fuel_off);
}

const int_tys = [_]Type{ .i8, .i16, .i32, .i64 };

const G = struct {
    gpa: std.mem.Allocator,
    rnd: std.Random,
    b: ir.Builder,
    opts: Options,
    uniform_pend: bool = false,
    pend_kind: u64 = 0,
    /// This block's values, by type.
    pool: std.EnumArray(Type, std.ArrayList(Ref)),

    fn deinit(g: *G) void {
        for (&g.pool.values) |*l| l.deinit(g.gpa);
    }
    fn chance(g: *G, percent: u32) bool {
        return g.rnd.uintLessThan(u32, 100) < percent;
    }
    fn pick(g: *G, comptime T: type, xs: []const T) T {
        return xs[g.rnd.uintLessThan(usize, xs.len)];
    }
    fn add(g: *G, ty: Type, ref: Ref) !Ref {
        try g.pool.getPtr(ty).append(g.gpa, ref);
        return ref;
    }
    fn emit(g: *G, i: ir.Inst) !Ref {
        const ref = try g.b.emit(i);
        if (i.ty != .none) _ = try g.add(i.ty, ref);
        return ref;
    }

    fn interesting(g: *G, ty: Type) u64 {
        const bits = ty.bits();
        const m = ty.mask();
        const v: u64 = switch (g.rnd.uintLessThan(u32, 12)) {
            0 => 0,
            1 => 1,
            2 => m,
            3 => @as(u64, 1) << @intCast(bits - 1),
            4 => (@as(u64, 1) << @intCast(bits - 1)) - 1,
            5 => g.rnd.uintLessThan(u64, 70),
            6 => m - g.rnd.uintLessThan(u64, 3),
            7 => @as(u64, 1) << @intCast(g.rnd.uintLessThan(u32, bits)),
            else => g.rnd.int(u64),
        };
        return v & m;
    }

    /// A value of type `ty`: one already in the block, or a new one.
    fn val(g: *G, ty: Type) anyerror!Ref {
        const l = g.pool.getPtr(ty);
        if (l.items.len != 0 and g.chance(80)) return g.pick(Ref, l.items);
        return g.fresh(ty);
    }

    fn fresh(g: *G, ty: Type) anyerror!Ref {
        switch (ty) {
            .i1 => {
                if (g.chance(30)) return g.emit(.{ .op = .@"const", .ty = .i1, .aux = g.rnd.uintLessThan(u64, 2) });
                return g.cond();
            },
            .flags => return g.flags(),
            else => {
                if (g.chance(40)) return g.getreg(ty);
                return g.emit(.{ .op = .@"const", .ty = ty, .aux = g.interesting(ty) });
            },
        }
    }

    fn getreg(g: *G, ty: Type) !Ref {
        const n: u32 = @intCast(ty.bits() / 8);
        // Mostly aligned, sometimes not; anywhere in the 64 bytes.
        if (g.chance(5)) return g.emit(.{ .op = .getreg, .ty = ty, .aux = fuel_off + 8 - n });
        var off = g.rnd.uintLessThan(u32, g.regLimit() - n + 1);
        if (g.chance(75)) off -= off % n;
        return g.emit(.{ .op = .getreg, .ty = ty, .aux = off });
    }

    fn setreg(g: *G) !void {
        const ty = g.pick(Type, &.{ .i8, .i16, .i32, .i64, .i64, .i64, .flags });
        const n: u32 = @intCast(ty.bits() / 8);
        var off = g.rnd.uintLessThan(u32, g.regLimit() - n + 1);
        if (g.chance(75)) off -= off % n;
        _ = try g.b.emit(.{ .op = .setreg, .a = try g.val(ty), .aux = off });
    }

    fn flags(g: *G) !Ref {
        if (g.chance(50)) {
            const ty = g.pick(Type, &.{ .i32, .i64 });
            const op = g.pick(Op, &.{ .@"nzcv.add", .@"nzcv.sub", .@"nzcv.sub", .@"nzcv.logic", .@"nzcv.adc", .@"nzcv.sbc" });
            const a = try g.val(ty);
            return switch (op) {
                .@"nzcv.logic" => g.emit(.{ .op = op, .ty = .flags, .a = a }),
                .@"nzcv.adc", .@"nzcv.sbc" => g.emit(.{ .op = op, .ty = .flags, .a = a, .b = try g.val(ty), .c = try g.val(.flags) }),
                else => g.emit(.{ .op = op, .ty = .flags, .a = a, .b = try g.val(ty) }),
            };
        }
        if (g.chance(10)) {
            if (g.chance(50)) return g.emit(.{ .op = .@"nzcv.unpack", .ty = .flags, .a = try g.val(.i32) });
            return g.emit(.{ .op = .@"eflags.unpack", .ty = .flags, .a = try g.val(.i32) });
        }
        const ty = g.pick(Type, &.{ .i8, .i16, .i32, .i32, .i64 });
        const op = g.pick(Op, &.{ .@"eflags.add", .@"eflags.sub", .@"eflags.sub", .@"eflags.logic", .@"eflags.adc", .@"eflags.sbb", .@"eflags.inc", .@"eflags.dec", .@"eflags.shl", .@"eflags.shr", .@"eflags.mul" });
        const a = try g.val(ty);
        return switch (op) {
            .@"eflags.logic" => g.emit(.{ .op = op, .ty = .flags, .a = a }),
            .@"eflags.inc", .@"eflags.dec" => g.emit(.{ .op = op, .ty = .flags, .a = a, .b = try g.val(.flags) }),
            .@"eflags.adc", .@"eflags.sbb" => g.emit(.{ .op = op, .ty = .flags, .a = a, .b = try g.val(ty), .c = try g.val(.flags) }),
            else => g.emit(.{ .op = op, .ty = .flags, .a = a, .b = try g.val(ty) }),
        };
    }

    /// Guest registers below this are the region's to read and write: the
    /// rest hold pending flags (and a lazy record), and the loop counter.
    fn regLimit(g: *G) u32 {
        return if (g.uniform_pend and g.pend_kind == 2) lazy_off else pending_off;
    }

    fn eflagsProducer(g: *G) !Ref {
        const ty = g.pick(Type, &.{ .i8, .i16, .i32, .i32, .i64 });
        const op = g.pick(Op, &.{ .@"eflags.add", .@"eflags.sub", .@"eflags.logic", .@"eflags.adc", .@"eflags.sbb", .@"eflags.inc", .@"eflags.dec", .@"eflags.shl", .@"eflags.shr", .@"eflags.mul" });
        const a = try g.val(ty);
        return switch (op) {
            .@"eflags.logic" => g.emit(.{ .op = op, .ty = .flags, .a = a }),
            .@"eflags.inc", .@"eflags.dec" => g.emit(.{ .op = op, .ty = .flags, .a = a, .b = try g.val(.flags) }),
            .@"eflags.adc", .@"eflags.sbb" => g.emit(.{ .op = op, .ty = .flags, .a = a, .b = try g.val(ty), .c = try g.val(.flags) }),
            else => g.emit(.{ .op = op, .ty = .flags, .a = a, .b = try g.val(ty) }),
        };
    }

    fn cond(g: *G) !Ref {
        switch (g.rnd.uintLessThan(u32, 3)) {
            0 => {
                const ty = g.pick(Type, &.{ .i1, .i8, .i16, .i32, .i64, .i64 });
                return g.emit(.{ .op = .icmp, .ty = .i1, .a = try g.val(ty), .b = try g.val(ty), .aux = g.rnd.uintLessThan(u64, 10) });
            },
            1 => {
                // A fresh flags value, so it's often still in NZCV.
                const f = if (g.chance(70)) try g.flags() else try g.val(.flags);
                return g.emit(.{ .op = .@"nzcv.cond", .ty = .i1, .a = f, .aux = g.rnd.uintLessThan(u64, 16) });
            },
            else => {
                const f = if (g.chance(70)) try g.flags() else try g.val(.flags);
                return g.emit(.{ .op = .@"eflags.cond", .ty = .i1, .a = f, .aux = g.rnd.uintLessThan(u64, 16) });
            },
        }
    }

    fn address(g: *G) !Ref {
        const r = g.rnd.uintLessThan(u32, 100);
        if (r < 2) return g.emit(.{ .op = .@"const", .ty = .i64, .aux = g.rnd.int(u64) }); // anywhere
        var off: u64 = g.rnd.uintLessThan(u64, 4096 - 8);
        if (r < 6) off = 4096 - g.rnd.uintLessThan(u64, 8); // near the end: crossing faults
        if (r < 40) {
            // From a register's low bits, so it varies at run time.
            const v = try g.val(.i64);
            const mask = try g.emit(.{ .op = .@"const", .ty = .i64, .aux = 0xff8 });
            const lo = try g.emit(.{ .op = .@"and", .ty = .i64, .a = v, .b = mask });
            const base = try g.emit(.{ .op = .@"const", .ty = .i64, .aux = cases.data_va });
            return g.emit(.{ .op = .add, .ty = .i64, .a = lo, .b = base });
        }
        if (g.chance(20)) return g.emit(.{ .op = .@"const", .ty = .i32, .aux = cases.data_va + off });
        return g.emit(.{ .op = .@"const", .ty = .i64, .aux = cases.data_va + off });
    }

    fn memFlags(g: *G, max_bytes: u32) ir.MemFlags {
        const max_size: u3 = @intCast(std.math.log2_int(u32, max_bytes));
        return .{
            .size = g.rnd.uintAtMost(u3, max_size),
            .signed = g.chance(40),
            .aligned = g.chance(10),
            .order = if (g.chance(90)) .plain else g.pick(ir.MemFlags.Order, &.{ .acquire, .release, .seq_cst }),
        };
    }

    fn inst(g: *G, pc: u64) !void {
        const k = g.rnd.uintLessThan(u32, 100);
        if (k < 30) {
            const ty = g.pick(Type, &int_tys);
            const op = g.pick(Op, &.{ .add, .sub, .mul, .mulhu, .mulhs, .udiv, .sdiv, .urem, .srem, .@"and", .@"or", .xor, .andn, .shl, .lshr, .ashr, .ror, .rol });
            if (g.chance(5) and (op == .@"and" or op == .@"or" or op == .xor)) {
                _ = try g.emit(.{ .op = op, .ty = .i1, .a = try g.val(.i1), .b = try g.val(.i1) });
                return;
            }
            _ = try g.emit(.{ .op = op, .ty = ty, .a = try g.val(ty), .b = try g.val(ty) });
        } else if (k < 38) {
            const ty = g.pick(Type, &.{ .i1, .i8, .i16, .i32, .i64, .i64 });
            // bswap:i1 is ir_eval's byte swap of a 1-bit value, always 0
            // (asked of the IR owner); it isn't generated.
            const op = if (ty == .i1) g.pick(Op, &.{ .neg, .not, .clz, .ctz, .popcnt, .rbit }) else g.pick(Op, &.{ .neg, .not, .clz, .ctz, .popcnt, .rbit, .bswap });
            _ = try g.emit(.{ .op = op, .ty = ty, .a = try g.val(ty) });
        } else if (k < 46) {
            const all = [_]Type{ .i1, .i8, .i16, .i32, .i64 };
            const x = g.rnd.uintLessThan(usize, all.len);
            const y = g.rnd.uintLessThan(usize, all.len);
            const lo = all[@min(x, y)];
            const hi = all[@max(x, y)];
            switch (g.rnd.uintLessThan(u32, 3)) {
                0 => _ = try g.emit(.{ .op = .zext, .ty = hi, .a = try g.val(lo) }),
                1 => _ = try g.emit(.{ .op = .sext, .ty = hi, .a = try g.val(lo) }),
                else => _ = try g.emit(.{ .op = .trunc, .ty = lo, .a = try g.val(hi) }),
            }
        } else if (k < 50) {
            const ty = g.pick(Type, &.{ .i8, .i16, .i32, .i64, .i64, .flags });
            _ = try g.emit(.{ .op = .select, .ty = ty, .a = try g.cond(), .b = try g.val(ty), .c = try g.val(ty) });
        } else if (k < 58) {
            _ = try g.cond();
        } else if (k < 62) {
            _ = try g.flags();
        } else if (k < 65) {
            const op = g.pick(Op, &.{ .@"nzcv.pack", .@"eflags.pack" });
            _ = try g.emit(.{ .op = op, .ty = .i32, .a = try g.val(.flags) });
        } else if (k < 73) {
            const ty = g.pick(Type, &int_tys);
            const f = g.memFlags(ty.bits() / 8);
            _ = try g.emit(.{ .op = .load, .ty = ty, .a = try g.address(), .aux = @bitCast(f), .aux2 = pc });
        } else if (k < 79) {
            const ty = g.pick(Type, &int_tys);
            var f = g.memFlags(ty.bits() / 8);
            f.signed = false;
            const a = try g.address();
            _ = try g.b.emit(.{ .op = .store, .a = a, .b = try g.val(ty), .aux = @bitCast(f), .aux2 = pc });
        } else if (k < 90) {
            try g.setreg();
        } else if (k < 93) {
            if (g.chance(40)) {
                // Mostly one slot and kind per region, as lifters make them
                // (and as arm64's lazy flags want).
                const one = g.uniform_pend;
                const off: u64 = if (one and g.pend_kind == 2) lazy_off else if (one) pending_off else pending_off + 4 * g.rnd.uintLessThan(u64, 2);
                const kind = if (one) g.pend_kind else g.rnd.uintLessThan(u64, 2);
                // A lazy record (aux2 2) takes an eflags producer's operands.
                const f = if (kind == 2) try g.eflagsProducer() else try g.flags();
                _ = try g.b.emit(.{ .op = .@"pending.flags", .a = f, .aux = off, .aux2 = kind });
                return;
            }
            _ = try g.getreg(g.pick(Type, &.{ .i8, .i16, .i32, .i64, .flags }));
        } else if (k < 95) {
            try g.b.retire(1 + g.rnd.uintLessThan(u64, 5));
        } else if (k < 96) {
            _ = try g.b.emit(.{ .op = .fence, .aux = g.rnd.uintLessThan(u64, 3) });
        } else if (g.opts.calls and k < 98) {
            const h = g.rnd.int(u64) & ~@as(u64, 0xf) | (if (g.chance(10)) @as(u64, 0xf) else g.rnd.uintLessThan(u64, 15));
            try g.b.interp(h, pc);
        } else if (g.opts.calls) {
            const ret = g.chance(70);
            const nargs = g.rnd.uintAtMost(u32, 3);
            var args: [3]Ref = .{ ir.none, ir.none, ir.none };
            for (args[0..nargs]) |*a| a.* = try g.val(.i64);
            if (g.chance(40)) {
                // Helper 2 touches no register: ir.helper_no_regs.
                _ = try g.emit(.{ .op = .@"call.helper", .ty = .i64, .a = args[0], .b = args[1], .c = args[2], .aux = 2, .aux2 = ir.helper_no_regs });
                return;
            }
            _ = try g.emit(.{ .op = .@"call.helper", .ty = if (ret) .i64 else .none, .a = args[0], .b = args[1], .c = args[2], .aux = if (ret) 0 else 1 });
        } else {
            _ = try g.cond();
        }
    }

    fn exit(g: *G, pc: u64) !void {
        switch (g.rnd.uintLessThan(u32, 6)) {
            0, 1 => try g.b.exit(.@"exit.chain", pc),
            2 => try g.b.exit(.@"exit.svc", pc),
            3 => try g.b.exit(g.pick(Op, &.{ .@"exit.brk", .@"exit.undef" }), pc),
            else => try g.b.exitIndirect(try g.val(g.pick(Type, &.{ .i32, .i64 }))),
        }
    }

    /// The loop counter: decrement it unless it's 0, and branch back while
    /// it wasn't.
    fn backEdge(g: *G, back: ir.BlockId, fwd: ir.BlockId) !void {
        const f = try g.b.getreg(.i64, fuel_off);
        const one = try g.b.konst(.i64, 1);
        const f2 = try g.b.bin(.sub, .i64, f, one);
        var c: Ref = undefined;
        switch (g.rnd.uintLessThan(u32, 3)) {
            0 => c = try g.b.icmp(.ult, f2, f),
            1 => {
                const fl = try g.b.flags(.@"nzcv.sub", f, one);
                c = try g.b.cond(.@"nzcv.cond", fl, 2); // CS: no borrow, so f >= 1
            },
            else => {
                const z = try g.b.konst(.i64, 0);
                const fl = try g.b.flags(.@"nzcv.sub", f, z);
                c = try g.b.cond(.@"nzcv.cond", fl, 1); // NE
            },
        }
        const nf = try g.b.emit(.{ .op = .select, .ty = .i64, .a = c, .b = f2, .c = f });
        try g.b.setreg(fuel_off, nf);
        try g.b.brcond(c, back, fwd);
    }
};

/// Generates a verified region. The caller deinits it.
pub fn generate(gpa: std.mem.Allocator, rnd: std.Random, opts: Options) !ir.Region {
    var r: ir.Region = .{ .entry_pc = 0x1000 };
    errdefer r.deinit(gpa);
    var g: G = .{ .gpa = gpa, .rnd = rnd, .b = ir.Builder.init(gpa, &r), .opts = opts, .pool = .initFill(.empty) };
    defer g.deinit();
    const nb = 1 + rnd.uintLessThan(u32, opts.max_blocks);
    g.uniform_pend = g.chance(70);
    g.pend_kind = rnd.uintLessThan(u64, if (opts.lazy_records) 3 else 2);
    for (0..nb) |_| _ = try g.b.block();
    for (0..nb) |bi| {
        const blk: ir.BlockId = @intCast(bi);
        g.b.begin(blk);
        for (&g.pool.values) |*l| l.clearRetainingCapacity();
        const pc: u64 = 0x1000 + 0x100 * bi;
        if (g.chance(40)) try g.b.poll(pc);
        // Some blocks are long, as lifted ones are, for register pressure.
        const n = rnd.uintLessThan(u32, if (g.chance(15)) opts.max_insts * 6 else opts.max_insts + 1);
        for (0..n) |k| try g.inst(pc + 4 * k);
        const last = bi + 1 == nb;
        const t = rnd.uintLessThan(u32, 100);
        if (last or t < 15) {
            try g.exit(pc + 0x80);
        } else if (t < 35) {
            try g.b.br(@intCast(bi + 1 + rnd.uintLessThan(usize, nb - bi - 1)));
        } else if (t < 70) {
            const c = if (g.chance(60)) try g.cond() else try g.val(.i1);
            try g.b.brcond(c, @intCast(bi + 1 + rnd.uintLessThan(usize, nb - bi - 1)), @intCast(bi + 1 + rnd.uintLessThan(usize, nb - bi - 1)));
        } else {
            try g.backEdge(@intCast(rnd.uintAtMost(usize, bi)), @intCast(bi + 1 + rnd.uintLessThan(usize, nb - bi - 1)));
        }
    }
    if (ir.verify(&r)) |e| {
        if (cases.can_print) {
            var buf: [1 << 16]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            ir.print(&r, &w) catch {};
            std.debug.print("fuzz made an invalid region: {s} at %{d}\n{s}\n", .{ e.msg, e.inst, w.buffered() });
        }
        return error.Invalid;
    }
    return r;
}

/// The region as emitters get it: a copy run through jit/opt, verified.
/// A verify error after opt is opt's bug, and fails loudly.
pub fn optimized(gpa: std.mem.Allocator, r: *const ir.Region) !ir.Region {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try ir.print(r, &aw.writer);
    var o = try ir.parse(gpa, aw.written());
    errdefer o.deinit(gpa);
    try @import("../opt.zig").run(gpa, &o);
    if (ir.verify(&o)) |e| {
        if (cases.can_print) {
            var bw: std.Io.Writer.Allocating = .init(gpa);
            defer bw.deinit();
            ir.print(&o, &bw.writer) catch {};
            std.debug.print("opt made an invalid region: {s} at %{d}\nfrom:\n{s}\nto:\n{s}\n", .{ e.msg, e.inst, aw.written(), bw.written() });
        }
        return error.Invalid;
    }
    return o;
}

/// Random starting registers: interesting values, a data-page address or
/// two, and the loop counter.
pub fn regs(rnd: std.Random) [8]u64 {
    var x: [8]u64 = undefined;
    for (x[0..7]) |*v| v.* = switch (rnd.uintLessThan(u32, 6)) {
        0 => rnd.uintLessThan(u64, 16),
        1 => cases.data_va + rnd.uintLessThan(u64, 4096),
        2 => @bitCast(-@as(i64, rnd.uintLessThan(u32, 16))),
        else => rnd.int(u64),
    };
    x[7] = rnd.uintLessThan(u64, 12);
    return x;
}

/// A budget that's sometimes small enough to stop a loop at a poll.
pub fn budget(rnd: std.Random) i64 {
    return if (rnd.uintLessThan(u32, 4) == 0) @as(i64, rnd.uintLessThan(u32, 40)) else std.math.maxInt(i64);
}

test "generated regions verify and run in ir_eval" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(1);
    const env = try gpa.create(cases.Env);
    defer gpa.destroy(env);
    for (0..300) |_| {
        var r = try generate(gpa, prng.random(), .{});
        defer r.deinit(gpa);
        const c: cases.Case = .{ .text = "", .regs = regs(prng.random()), .budget = budget(prng.random()) };
        _ = try env.evalCase(gpa, &r, c);
    }
}

test "regalloc never gives one place to two live values" {
    const regalloc = @import("../regalloc.zig");
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(2);
    const host: regalloc.Host = .{ .regs = &.{ 0, 1, 2, 3, 23, 24 }, .pin_regs = &.{ 24, 23 }, .max_pinned = 1, .callee_saved = 3 << 23 };
    for (0..300) |_| {
        var r = try generate(gpa, prng.random(), .{ .max_insts = 80 });
        defer r.deinit(gpa);
        var p = try regalloc.plan(gpa, &r, host, null);
        defer p.deinit(gpa);
        for (r.blocks.items) |blk| {
            for (blk.start..blk.start + blk.len) |x| for (x + 1..blk.start + blk.len) |y| {
                if (p.end[x] <= y) continue; // x is dead by y's definition
                const same = switch (p.locs[x]) {
                    .reg => |a| p.locs[y] == .reg and p.locs[y].reg == a,
                    .slot => |a| p.locs[y] == .slot and (p.locs[y].slot == a or
                        (r.insts.items[x].ty == .v128 and p.locs[y].slot == a + 1) or
                        (r.insts.items[y].ty == .v128 and p.locs[y].slot + 1 == a)),
                    .none => false,
                };
                if (same) {
                    std.debug.print("%{d} and %{d} share {any}\n", .{ x, y, p.locs[x] });
                    return error.TestExpectedEqual;
                }
            };
        }
    }
}
