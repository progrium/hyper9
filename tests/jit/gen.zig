//! Random regions for the wasm emitter's tests (wasm_runtime.zig): any
//! control flow (loops, merges, and irreducible cycles), guest registers
//! read and written at mixed and overlapping widths, loads and stores that
//! take the slow path and fault, and chains between regions.
//!
//! The fuel register bounds every run: each block spends one unit, and an
//! empty tank leaves with `exit.svc #out_of_fuel`.

const std = @import("std");
const hcpu = @import("hcpu");
const ir = hcpu.ir;
const data_va = hcpu.emit.cases.data_va;

/// Register 7 of cases.Env's eight.
pub const fuel_off = 56;
pub const out_of_fuel = 0xf0e1;

const Val = struct { ref: ir.Ref, ty: ir.Type };

/// A region at `entry_pc` whose chains go to `pcs`.
pub fn region(gpa: std.mem.Allocator, rng: std.Random, entry_pc: u64, pcs: []const u64) !ir.Region {
    var r: ir.Region = .{ .entry_pc = entry_pc };
    errdefer r.deinit(gpa);
    var b = ir.Builder.init(gpa, &r);
    // Each step is a fuel check (block 2k) and a body (2k+1); the last
    // block leaves when the fuel's out.
    const n = rng.intRangeAtMost(u32, 1, 9);
    for (0..2 * n + 1) |_| _ = try b.block();
    const out: ir.BlockId = 2 * n;
    for (0..n) |k| {
        const check: ir.BlockId = @intCast(2 * k);
        b.begin(check);
        if (k == 0) try b.poll(entry_pc);
        const f = try b.getreg(.i64, fuel_off);
        try b.setreg(fuel_off, try b.bin(.sub, .i64, f, try b.konst(.i64, 1)));
        try b.brcond(try b.icmp(.eq, f, try b.konst(.i64, 0)), out, check + 1);

        b.begin(check + 1);
        var vals: std.ArrayList(Val) = .empty;
        defer vals.deinit(gpa);
        for (0..rng.intRangeAtMost(u32, 0, 10)) |_| try op(gpa, &b, rng, &vals);
        try b.retire(rng.intRangeAtMost(u64, 0, 3));
        const step = struct {
            fn pick(rr: std.Random, nn: u32) ir.BlockId {
                return @intCast(2 * rr.uintLessThan(u32, nn));
            }
        };
        switch (rng.uintLessThan(u32, 10)) {
            0...2 => try b.br(step.pick(rng, n)),
            3...6 => try b.brcond(try cond(gpa, &b, rng, &vals), step.pick(rng, n), step.pick(rng, n)),
            7, 8 => try b.exit(.@"exit.chain", if (pcs.len > 0 and rng.uintLessThan(u32, 8) != 0) pcs[rng.uintLessThan(u32, @intCast(pcs.len))] else 0xbad0),
            else => switch (rng.uintLessThan(u32, 3)) {
                0 => try b.exit(.@"exit.svc", entry_pc + 4 * k),
                1 => try b.exit(.@"exit.undef", entry_pc + 4 * k),
                else => try b.exitIndirect(try value(gpa, &b, rng, &vals, .i64)),
            },
        }
    }
    b.begin(out);
    try b.exit(.@"exit.svc", out_of_fuel);
    return r;
}

/// A register: its offset and the type it's read and written at. Register
/// 5 is also read a byte at a time, and register 6 in 32-bit halves, so
/// some batches can't keep them in locals.
fn reg(rng: std.Random) struct { u64, ir.Type } {
    return switch (rng.uintLessThan(u32, 10)) {
        0...5 => |k| .{ 8 * @as(u64, k), .i64 },
        6 => .{ 40, .i8 },
        7 => .{ 48, .i32 },
        8 => .{ 52, .i32 },
        else => .{ 48, .i64 },
    };
}

/// A value of type `ty`: one of `vals` or a new one.
fn value(gpa: std.mem.Allocator, b: *ir.Builder, rng: std.Random, vals: *std.ArrayList(Val), ty: ir.Type) !ir.Ref {
    if (rng.boolean()) {
        var k = vals.items.len;
        while (k > 0) {
            k -= 1;
            if (vals.items[k].ty == ty and rng.boolean()) return vals.items[k].ref;
        }
    }
    const v = switch (rng.uintLessThan(u32, 3)) {
        0 => try b.konst(ty, rng.int(u64) >> @intCast(rng.uintLessThan(u32, 64))),
        else => blk: {
            const g = reg(rng);
            const x = try b.getreg(g[1], g[0]);
            break :blk if (g[1] == ty) x else if (g[1].bits() > ty.bits()) try b.un(.trunc, ty, x) else try b.un(if (rng.boolean()) .zext else .sext, ty, x);
        },
    };
    try vals.append(gpa, .{ .ref = v, .ty = ty });
    return v;
}

fn cond(gpa: std.mem.Allocator, b: *ir.Builder, rng: std.Random, vals: *std.ArrayList(Val)) !ir.Ref {
    const ty: ir.Type = if (rng.boolean()) .i64 else .i32;
    const x = try value(gpa, b, rng, vals, ty);
    const y = try value(gpa, b, rng, vals, ty);
    return switch (rng.uintLessThan(u32, 3)) {
        0 => b.cond(.@"nzcv.cond", try b.flags(if (rng.boolean()) .@"nzcv.sub" else .@"nzcv.add", x, y), rng.int(u4)),
        1 => b.cond(.@"eflags.cond", try b.flags(.@"eflags.sub", try b.un(.trunc, .i32, x), try b.un(.trunc, .i32, y)), rng.int(u4)),
        else => b.icmp(@enumFromInt(rng.uintLessThan(u8, 10)), x, y),
    };
}

fn op(gpa: std.mem.Allocator, b: *ir.Builder, rng: std.Random, vals: *std.ArrayList(Val)) !void {
    const tys = [_]ir.Type{ .i64, .i32, .i16, .i8 };
    switch (rng.uintLessThan(u32, 12)) {
        0...3 => {
            const ty = tys[rng.uintLessThan(u32, tys.len)];
            const ops = [_]ir.Op{ .add, .sub, .mul, .@"and", .@"or", .xor, .andn, .shl, .lshr, .ashr, .ror, .rol, .udiv, .urem, .sdiv, .mulhu, .mulhs };
            const v = try b.bin(ops[rng.uintLessThan(u32, ops.len)], ty, try value(gpa, b, rng, vals, ty), try value(gpa, b, rng, vals, ty));
            try vals.append(gpa, .{ .ref = v, .ty = ty });
        },
        4 => {
            const ty = tys[rng.uintLessThan(u32, tys.len)];
            const ops = [_]ir.Op{ .neg, .not, .clz, .ctz, .popcnt, .bswap };
            const v = try b.un(ops[rng.uintLessThan(u32, ops.len)], ty, try value(gpa, b, rng, vals, ty));
            try vals.append(gpa, .{ .ref = v, .ty = ty });
        },
        5 => {
            const c = try cond(gpa, b, rng, vals);
            const v = try b.emit(.{ .op = .select, .ty = .i64, .a = c, .b = try value(gpa, b, rng, vals, .i64), .c = try value(gpa, b, rng, vals, .i64) });
            try vals.append(gpa, .{ .ref = v, .ty = .i64 });
        },
        6...8 => {
            const g = reg(rng);
            try b.setreg(g[0], try value(gpa, b, rng, vals, g[1]));
        },
        9, 10 => {
            // An address in the data page, now and then at its end, where
            // a wide access crosses into the unmapped page and faults.
            const base = try b.konst(.i64, data_va);
            const off = try b.bin(.@"and", .i64, try value(gpa, b, rng, vals, .i64), try b.konst(.i64, if (rng.uintLessThan(u32, 6) == 0) 0xfff else 0xff8));
            const addr = try b.bin(.add, .i64, base, off);
            const size: u3 = rng.uintLessThan(u3, 4);
            const ty: ir.Type = if (size == 3 or rng.boolean()) .i64 else .i32;
            const f: ir.MemFlags = .{ .size = size, .signed = rng.boolean(), .aligned = rng.uintLessThan(u32, 4) == 0 };
            if (rng.boolean()) {
                const v = try b.load(ty, addr, f, 0x5000 + rng.uintLessThan(u64, 64));
                try vals.append(gpa, .{ .ref = v, .ty = ty });
            } else {
                var g = f;
                g.signed = false;
                try b.store(addr, try value(gpa, b, rng, vals, ty), g, 0x6000 + rng.uintLessThan(u64, 64));
            }
        },
        else => try b.retire(1),
    }
}
