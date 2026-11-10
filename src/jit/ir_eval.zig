//! The IR's reference semantics: a plain interpreter of a region.
//!
//! It's the definition every emitter is tested against (random IR, run
//! natively and here, compared), and what a lifter is tested with before
//! any emitter exists (lift, run here, compare with T0).
//!
//! It's also every emitter's fallback: an emitter that hasn't lowered a
//! pure operation yet calls `evalOpC` for it, so adding an op never breaks
//! an emitter.
//!
//! Values are u64s holding the type's bits, zero-extended: i1 is 0 or 1,
//! and a flags value is the guest's packed flags (see ir.zig). v128 has no
//! pure operations yet; when it does, they get their own fallback ABI.

const std = @import("std");
const ir = @import("ir.zig");
const ctx_mod = @import("ctx.zig");
const mem = @import("../interp/mem.zig");
const Ctx = ctx_mod.Ctx;
const Exit = ctx_mod.Exit;
const Op = ir.Op;
const Type = ir.Type;

fn msb(v: u64, bits: u32) u1 {
    return @truncate(v >> @intCast(bits - 1));
}

fn sx(v: u64, bits: u32) i64 {
    if (bits >= 64) return @bitCast(v);
    const s: u6 = @intCast(64 - bits);
    return @as(i64, @bitCast(v << s)) >> s;
}

/// arm64's AddWithCarry: the result and NZCV (in bits 31..28).
fn addWithCarry(a: u64, b: u64, cin: u1, bits: u32) struct { u64, u64 } {
    const m = maskOf(bits);
    const wide: u128 = @as(u128, a & m) + @as(u128, b & m) + cin;
    const res: u64 = @as(u64, @truncate(wide)) & m;
    const n = msb(res, bits);
    const z: u1 = @intFromBool(res == 0);
    const c: u1 = @intFromBool(wide > m);
    const v = msb((a ^ res) & (b ^ res), bits);
    return .{ res, (@as(u64, n) << 31) | (@as(u64, z) << 30) | (@as(u64, c) << 29) | (@as(u64, v) << 28) };
}

fn maskOf(bits: u32) u64 {
    return if (bits >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(bits)) - 1;
}

pub fn nzcvCond(f: u64, cc: u64) bool {
    const n = (f >> 31) & 1 == 1;
    const z = (f >> 30) & 1 == 1;
    const c = (f >> 29) & 1 == 1;
    const v = (f >> 28) & 1 == 1;
    const r = switch (cc >> 1) {
        0 => z,
        1 => c,
        2 => n,
        3 => v,
        4 => c and !z,
        5 => n == v,
        6 => !z and n == v,
        else => true,
    };
    // The odd codes negate, except 15 (NV), which is always true too.
    return if (cc & 1 == 1 and cc != 15) !r else r;
}

// EFLAGS bits.
pub const CF: u64 = 1 << 0;
pub const PF: u64 = 1 << 2;
pub const AF: u64 = 1 << 4;
pub const ZF: u64 = 1 << 6;
pub const SF: u64 = 1 << 7;
pub const OF: u64 = 1 << 11;
pub const eflags_mask = CF | PF | AF | ZF | SF | OF;

fn szp(res: u64, bits: u32) u64 {
    var f: u64 = 0;
    if (res == 0) f |= ZF;
    if (msb(res, bits) == 1) f |= SF;
    if (@popCount(@as(u8, @truncate(res))) % 2 == 0) f |= PF;
    return f;
}

fn eflagsAdd(a: u64, b: u64, cin: u1, bits: u32) u64 {
    const m = maskOf(bits);
    const wide: u128 = @as(u128, a) + b + cin;
    const res = @as(u64, @truncate(wide)) & m;
    var f = szp(res, bits) | ((a ^ b ^ res) & AF);
    if (wide > m) f |= CF;
    if (msb((a ^ res) & (b ^ res), bits) == 1) f |= OF;
    return f;
}

fn eflagsSub(a: u64, b: u64, cin: u1, bits: u32) u64 {
    const m = maskOf(bits);
    const res = (a -% b -% cin) & m;
    var f = szp(res, bits) | ((a ^ b ^ res) & AF);
    if (@as(u128, a) < @as(u128, b) + cin) f |= CF;
    if (msb((a ^ b) & (a ^ res), bits) == 1) f |= OF;
    return f;
}

pub fn eflagsCond(f: u64, cc: u64) bool {
    const of = f & OF != 0;
    const sf = f & SF != 0;
    const r = switch (cc >> 1) {
        0 => of,
        1 => f & CF != 0,
        2 => f & ZF != 0,
        3 => f & (CF | ZF) != 0,
        4 => sf,
        5 => f & PF != 0,
        6 => sf != of,
        else => f & ZF != 0 or sf != of,
    };
    return if (cc & 1 == 1) !r else r;
}

/// A pure operation's result. `ta` is operand a's type, which sets the
/// width of flags operations and extensions.
pub fn evalPure(op: Op, ty: Type, ta: Type, a: u64, b: u64, c: u64, aux: u64) u64 {
    const bits = ty.bits();
    const m = ty.mask();
    const abits = ta.bits();
    const r: u64 = switch (op) {
        .@"const" => aux,
        .add => a +% b,
        .sub => a -% b,
        .mul => a *% b,
        .mulhu => @truncate((@as(u128, a & m) * (b & m)) >> @intCast(bits)),
        .mulhs => @bitCast(@as(i64, @truncate((@as(i128, sx(a, bits)) * sx(b, bits)) >> @intCast(bits)))),
        .udiv => if (b & m == 0) 0 else (a & m) / (b & m),
        .sdiv => blk: {
            const x = sx(a, bits);
            const y = sx(b, bits);
            if (y == 0) break :blk 0;
            if (y == -1) break :blk @bitCast(-%x);
            break :blk @bitCast(@divTrunc(x, y));
        },
        .urem => if (b & m == 0) a else (a & m) % (b & m),
        .srem => blk: {
            const x = sx(a, bits);
            const y = sx(b, bits);
            if (y == 0) break :blk a;
            if (y == -1) break :blk 0;
            break :blk @bitCast(@rem(x, y));
        },
        .@"and" => a & b,
        .@"or" => a | b,
        .xor => a ^ b,
        .andn => a & ~b,
        .shl => (a & m) << @intCast(b % bits),
        .lshr => (a & m) >> @intCast(b % bits),
        .ashr => @bitCast(sx(a, bits) >> @intCast(b % bits)),
        .ror, .rol => blk: {
            const n0: u32 = @intCast(b % bits);
            const n = if (op == .rol) (bits - n0) % bits else n0;
            if (n == 0) break :blk a;
            break :blk ((a & m) >> @intCast(n)) | ((a & m) << @intCast(bits - n));
        },
        .neg => 0 -% a,
        .not => ~a,
        .clz => @clz(a & m) - (64 - bits),
        .ctz => if (a & m == 0) bits else @ctz(a),
        .popcnt => @popCount(a & m),
        .rbit => @bitReverse(a & m) >> @intCast(64 - bits),
        .bswap => @byteSwap(a & m) >> @intCast(64 - bits),
        .zext => a & ta.mask(),
        .sext => @bitCast(sx(a, abits)),
        .trunc => a,
        .select => if (a & 1 == 1) b else c,
        .icmp => @intFromBool(switch (@as(ir.Pred, @enumFromInt(aux))) {
            .eq => a & ta.mask() == b & ta.mask(),
            .ne => a & ta.mask() != b & ta.mask(),
            .ult => a & ta.mask() < b & ta.mask(),
            .ule => a & ta.mask() <= b & ta.mask(),
            .ugt => a & ta.mask() > b & ta.mask(),
            .uge => a & ta.mask() >= b & ta.mask(),
            .slt => sx(a, abits) < sx(b, abits),
            .sle => sx(a, abits) <= sx(b, abits),
            .sgt => sx(a, abits) > sx(b, abits),
            .sge => sx(a, abits) >= sx(b, abits),
        }),
        .@"nzcv.add" => addWithCarry(a, b, 0, abits)[1],
        .@"nzcv.sub" => addWithCarry(a, ~b, 1, abits)[1],
        .@"nzcv.adc" => addWithCarry(a, b, @truncate(c >> 29), abits)[1],
        .@"nzcv.sbc" => addWithCarry(a, ~b, @truncate(c >> 29), abits)[1],
        .@"nzcv.logic" => (@as(u64, msb(a & ta.mask(), abits)) << 31) | (@as(u64, @intFromBool(a & ta.mask() == 0)) << 30),
        .@"nzcv.cond" => @intFromBool(nzcvCond(a, aux)),
        .@"nzcv.pack", .@"nzcv.unpack" => a & 0xf000_0000,
        .@"eflags.add" => eflagsAdd(a & ta.mask(), b & ta.mask(), 0, abits),
        .@"eflags.sub" => eflagsSub(a & ta.mask(), b & ta.mask(), 0, abits),
        .@"eflags.adc" => eflagsAdd(a & ta.mask(), b & ta.mask(), @truncate(c & CF), abits),
        .@"eflags.sbb" => eflagsSub(a & ta.mask(), b & ta.mask(), @truncate(c & CF), abits),
        .@"eflags.logic" => szp(a & ta.mask(), abits),
        .@"eflags.inc" => (eflagsAdd(a & ta.mask(), 1, 0, abits) & ~CF) | (b & CF),
        .@"eflags.dec" => (eflagsSub(a & ta.mask(), 1, 0, abits) & ~CF) | (b & CF),
        .@"eflags.cond" => @intFromBool(eflagsCond(a, aux)),
        .@"eflags.pack", .@"eflags.unpack" => a & eflags_mask,
        else => unreachable, // not pure
    };
    return if (ty == .flags) r else r & m;
}

/// The fallback emitters call for a pure op they don't lower: `code` is
/// `fallbackCode(op, ty, ta)`.
pub fn evalOpC(code: u64, a: u64, b: u64, c: u64, aux: u64) callconv(.c) u64 {
    const op: Op = @enumFromInt(@as(u16, @truncate(code)));
    const ty: Type = @enumFromInt(@as(u8, @truncate(code >> 16)));
    const ta: Type = @enumFromInt(@as(u8, @truncate(code >> 24)));
    return evalPure(op, ty, ta, a, b, c, aux);
}

pub fn fallbackCode(op: Op, ty: Type, ta: Type) u64 {
    return @as(u64, @intFromEnum(op)) | (@as(u64, @intFromEnum(ty)) << 16) | (@as(u64, @intFromEnum(ta)) << 24);
}

// ---------------------------------------------------------------- regions

pub const Error = error{ OutOfMemory, Unsupported };

fn byteSize(t: Type) Error!usize {
    return switch (t) {
        .i8 => 1,
        .i16 => 2,
        .i32 => 4,
        .i64, .flags => 8,
        else => error.Unsupported,
    };
}

/// Runs a verified region with ctx's Cpu, TLB, and slow paths, and
/// returns how it left, as generated code would.
pub fn run(gpa: std.mem.Allocator, r: *const ir.Region, ctx: *Ctx) Error!Exit {
    const vals = try gpa.alloc(u64, r.insts.items.len);
    defer gpa.free(vals);
    const cpu: [*]u8 = @ptrFromInt(@as(usize, @intCast(ctx.cpu)));
    const tlb: *mem.Tlb = @ptrFromInt(@as(usize, @intCast(ctx.tlb)));
    var blk: ir.BlockId = 0;
    while (true) {
        const b = r.blocks.items[blk];
        for (b.start..b.start + b.len) |idx| {
            const i = r.insts.items[idx];
            const a = if (i.a != ir.none) vals[i.a] else 0;
            const bv = if (i.b != ir.none) vals[i.b] else 0;
            const cv = if (i.c != ir.none) vals[i.c] else 0;
            const ta: Type = if (i.a != ir.none) r.insts.items[i.a].ty else .none;
            if (i.op.isPure()) {
                vals[idx] = evalPure(i.op, i.ty, ta, a, bv, cv, i.aux);
                continue;
            }
            switch (i.op) {
                .getreg => {
                    var v: u64 = 0;
                    @memcpy(std.mem.asBytes(&v)[0..try byteSize(i.ty)], cpu[@intCast(i.aux)..][0..try byteSize(i.ty)]);
                    vals[idx] = v;
                },
                .setreg => @memcpy(cpu[@intCast(i.aux)..][0..try byteSize(ta)], std.mem.asBytes(&a)[0..try byteSize(ta)]),
                .load => {
                    const f: ir.MemFlags = @bitCast(i.aux);
                    const n = f.bytes();
                    var v: u64 = 0;
                    if (f.aligned and a % n != 0) return alignFault(ctx, a, .read, i.aux2);
                    if (mem.fast(tlb, a, n, false)) |host| {
                        @memcpy(std.mem.asBytes(&v)[0..n], @as([*]const u8, @ptrFromInt(host))[0..n]);
                    } else {
                        const slow: mem.SlowLoadFn = @ptrFromInt(@as(usize, @intCast(ctx.slow_load)));
                        if (slow(ctx, a, f.size) != 0) {
                            ctx.exit_pc = i.aux2;
                            return .fault;
                        }
                        v = ctx.scratch;
                    }
                    if (f.signed) v = @bitCast(sx(v, n * 8));
                    vals[idx] = v & i.ty.mask();
                },
                .store => {
                    const f: ir.MemFlags = @bitCast(i.aux);
                    const n = f.bytes();
                    if (f.aligned and a % n != 0) return alignFault(ctx, a, .write, i.aux2);
                    if (mem.fast(tlb, a, n, true)) |host| {
                        @memcpy(@as([*]u8, @ptrFromInt(host))[0..n], std.mem.asBytes(&bv)[0..n]);
                    } else {
                        const slow: mem.SlowStoreFn = @ptrFromInt(@as(usize, @intCast(ctx.slow_store)));
                        if (slow(ctx, a, f.size, bv) != 0) {
                            ctx.exit_pc = i.aux2;
                            return .fault;
                        }
                    }
                },
                .fence => _ = @atomicRmw(u32, &fence_word, .Add, 0, .seq_cst),
                .@"call.interp" => {
                    const f: ctx_mod.InterpFn = @ptrFromInt(@as(usize, @intCast(ctx.interp)));
                    const res = f(ctx, r.handles.items[@intCast(i.aux)], i.aux2);
                    if (res != 0) return @enumFromInt(res);
                },
                .@"call.helper" => {
                    const table: [*]const ctx_mod.HelperFn = @ptrFromInt(@as(usize, @intCast(ctx.helpers)));
                    vals[idx] = table[@intCast(i.aux)](ctx, a, bv, cv);
                },
                .poll => if (@atomicLoad(u32, &ctx.exit_request, .monotonic) != 0 or ctx.budget <= 0) {
                    ctx.exit_pc = i.aux;
                    return .interrupted;
                },
                .retire => {
                    ctx.retired +%= i.aux;
                    ctx.budget -%= @bitCast(i.aux);
                },
                .br => blk = @intCast(i.aux),
                .brcond => blk = @intCast(if (a & 1 == 1) i.aux else i.aux2),
                .@"exit.chain" => return exitAt(ctx, .chain, i.aux),
                .@"exit.indirect" => return exitAt(ctx, .indirect, a),
                .@"exit.svc" => return exitAt(ctx, .svc, i.aux),
                .@"exit.brk" => return exitAt(ctx, .brk, i.aux),
                .@"exit.undef" => return exitAt(ctx, .undef, i.aux),
                else => unreachable,
            }
        }
    }
}

/// A seq_cst read-modify-write is a full barrier on every host.
var fence_word: u32 = 0;

fn exitAt(ctx: *Ctx, e: Exit, pc: u64) Exit {
    ctx.exit_pc = pc;
    return e;
}

fn alignFault(ctx: *Ctx, addr: u64, acc: mem.Access, pc: u64) Exit {
    ctx.exit_pc = pc;
    ctx.exit_addr = addr;
    ctx.exit_info = @as(u64, @intFromEnum(acc)) | (@as(u64, @intFromEnum(mem.FaultKind.alignment)) << 8);
    return .fault;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn pure(op: Op, ty: Type, a: u64, b: u64) u64 {
    return evalPure(op, ty, ty, a, b, 0, 0);
}

test "integer semantics at each width" {
    try testing.expectEqual(@as(u64, 0xff), pure(.sub, .i8, 0, 1));
    try testing.expectEqual(@as(u64, 0xffff_fffe), pure(.shl, .i32, 0xffff_ffff, 33));
    try testing.expectEqual(@as(u64, 0xc000_0000), pure(.ashr, .i32, 0x8000_0000, 1));
    try testing.expectEqual(@as(u64, 0x8000_0001), pure(.ror, .i32, 0x3, 1));
    try testing.expectEqual(@as(u64, 0x8000_0001), pure(.rol, .i32, 0xc000_0000, 1));
    try testing.expectEqual(@as(u64, 0), pure(.udiv, .i64, 5, 0));
    try testing.expectEqual(@as(u64, 0x8000_0000), pure(.sdiv, .i32, 0x8000_0000, 0xffff_ffff));
    try testing.expectEqual(@as(u64, 0xffff_fffe), pure(.sdiv, .i32, 0xffff_fffa, 3));
    try testing.expectEqual(@as(u64, 1), pure(.mulhu, .i64, 1 << 63, 2));
    try testing.expectEqual(@as(u64, 0xffff_ffff_ffff_ffff), pure(.mulhs, .i64, @bitCast(@as(i64, -1)), 1));
    try testing.expectEqual(@as(u64, 31), evalPure(.clz, .i32, .i32, 1, 0, 0, 0));
    try testing.expectEqual(@as(u64, 0x8000_0000), evalPure(.rbit, .i32, .i32, 1, 0, 0, 0));
    try testing.expectEqual(@as(u64, 0x0403_0201), evalPure(.bswap, .i32, .i32, 0x0102_0304, 0, 0, 0));
    try testing.expectEqual(@as(u64, 0xffff_ffff_ffff_ff80), evalPure(.sext, .i64, .i8, 0x80, 0, 0, 0));
    try testing.expectEqual(@as(u64, 1), evalPure(.icmp, .i1, .i32, 0xffff_ffff, 0, 0, @intFromEnum(ir.Pred.slt)));
}

test "NZCV matches arm64's AddWithCarry" {
    // CMP 0, 1: N, no carry (a borrow).
    try testing.expectEqual(@as(u64, 0x8000_0000), pure(.@"nzcv.sub", .flags, 0, 1) & 0xf000_0000);
    try testing.expectEqual(@as(u64, 0x8000_0000), evalPure(.@"nzcv.sub", .flags, .i64, 0, 1, 0, 0));
    // CMP 5, 5: Z and C.
    try testing.expectEqual(@as(u64, 0x6000_0000), evalPure(.@"nzcv.sub", .flags, .i32, 5, 5, 0, 0));
    // ADDS 0x7fffffff + 1 at 32 bits: N and V.
    try testing.expectEqual(@as(u64, 0x9000_0000), evalPure(.@"nzcv.add", .flags, .i32, 0x7fff_ffff, 1, 0, 0));
    // Conditions: EQ, NE, GE, LT, HI.
    try testing.expect(nzcvCond(0x4000_0000, 0));
    try testing.expect(!nzcvCond(0x4000_0000, 1));
    try testing.expect(nzcvCond(0x9000_0000, 10)); // N == V
    try testing.expect(nzcvCond(0x2000_0000, 8)); // C and !Z
    try testing.expect(nzcvCond(0, 15));
}

test "EFLAGS for add, sub, inc, and logic" {
    // 0xff + 1 at 8 bits: CF ZF PF AF.
    try testing.expectEqual(CF | ZF | PF | AF, evalPure(.@"eflags.add", .flags, .i8, 0xff, 1, 0, 0));
    // 0x7f + 1: OF SF AF.
    try testing.expectEqual(OF | SF | AF, evalPure(.@"eflags.add", .flags, .i8, 0x7f, 1, 0, 0));
    // 0 - 1 at 32 bits: CF SF PF AF.
    try testing.expectEqual(CF | SF | PF | AF, evalPure(.@"eflags.sub", .flags, .i32, 0, 1, 0, 0));
    // INC keeps CF.
    try testing.expectEqual(CF | ZF | PF | AF, evalPure(.@"eflags.inc", .flags, .i8, 0xff, CF, 0, 0));
    try testing.expectEqual(ZF | PF | AF, evalPure(.@"eflags.inc", .flags, .i8, 0xff, 0, 0, 0));
    try testing.expectEqual(ZF | PF, evalPure(.@"eflags.logic", .flags, .i32, 0, 0, 0, 0));
    // JL after CMP -1, 0; JBE after CMP 0, 0.
    try testing.expect(eflagsCond(evalPure(.@"eflags.sub", .flags, .i32, 0xffff_ffff, 0, 0, 0), 12));
    try testing.expect(eflagsCond(evalPure(.@"eflags.sub", .flags, .i32, 0, 0, 0, 0), 6));
}

test "a counted loop runs to its exit" {
    const gpa = testing.allocator;
    var region = try ir.parse(gpa,
        \\region 0x1000
        \\b0:
        \\  poll #0x1000
        \\  %0 = getreg:i64 #0x0
        \\  %1 = getreg:i64 #0x8
        \\  %2 = add:i64 %0, %1
        \\  setreg %2 #0x0
        \\  %3 = const:i64 #0x1
        \\  %4 = sub:i64 %1, %3
        \\  setreg %4 #0x8
        \\  %5 = nzcv.sub:flags %1, %3
        \\  retire #0x3
        \\  %6 = nzcv.cond:i1 %5 #0x1
        \\  brcond %6 -> b0 b1
        \\b1:
        \\  exit.svc #0x1010
    );
    defer region.deinit(gpa);
    try testing.expect(ir.verify(&region) == null);
    var regs: [2]u64 = .{ 0, 10 };
    var tlb: mem.Tlb = .{};
    var c: Ctx = .{ .cpu = @intFromPtr(&regs), .tlb = @intFromPtr(&tlb) };
    try testing.expectEqual(Exit.svc, try run(gpa, &region, &c));
    try testing.expectEqual(@as(u64, 55), regs[0]);
    try testing.expectEqual(@as(u64, 0x1010), c.exit_pc);
    try testing.expectEqual(@as(u64, 30), c.retired);
    // A budget stops it at the loop head.
    regs = .{ 0, 10 };
    c.budget = 7;
    try testing.expectEqual(Exit.interrupted, try run(gpa, &region, &c));
    try testing.expectEqual(@as(u64, 10 + 9 + 8), regs[0]); // 3 iterations of 3 spend 7
}

test "loads and stores take the slow path and fault exactly" {
    const gpa = testing.allocator;
    var region = try ir.parse(gpa,
        \\region 0x0
        \\b0:
        \\  %0 = getreg:i64 #0x0
        \\  %1 = const:i32 #0xfffffff0
        \\  store %0, %1 #0x2 @0x100
        \\  %2 = load:i64 %0 #0x8 @0x104
        \\  setreg %2 #0x8
        \\  %3 = const:i64 #0x8
        \\  %4 = add:i64 %0, %3
        \\  %5 = load:i64 %4 #0x3 @0x108
        \\  exit.chain #0x10c
    );
    defer region.deinit(gpa);
    try testing.expect(ir.verify(&region) == null);
    var page: [mem.page_size]u8 align(mem.page_size) = @splat(0);
    const regions = [_]mem.Region{.{ .va = 0x4000, .mem = &page, .write = true }};
    var map: mem.Map = .{ .regions = &regions };
    var tlb: mem.Tlb = .{};
    var regs: [2]u64 = .{ 0x4ffc, 0 };
    var c: Ctx = .{
        .cpu = @intFromPtr(&regs),
        .tlb = @intFromPtr(&tlb),
        .space = @intFromPtr(&map),
        .slow_load = @intFromPtr(&mem.mapSlowLoad),
        .slow_store = @intFromPtr(&mem.mapSlowStore),
    };
    // The store and the signed byte load fit; the 8-byte load 8 bytes on
    // is in the unmapped page. State before it is already written.
    try testing.expectEqual(Exit.fault, try run(gpa, &region, &c));
    try testing.expectEqual(@as(u64, 0x108), c.exit_pc);
    try testing.expectEqual(@as(u64, 0x5004), c.exit_addr);
    try testing.expectEqual(@as(u64, 0xffff_ffff_ffff_fff0), regs[1]);
    regs = .{ 0x4ff0, 0 };
    try testing.expectEqual(Exit.chain, try run(gpa, &region, &c));
    try testing.expectEqual(@as(u64, 0x10c), c.exit_pc);
}
