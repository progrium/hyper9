//! ha64's `check.Guest`: the lifter in src/jit/a64/ against T0
//! (src/interp/a64/exec.zig).
//!
//! T0 reads memory through mem.zig's TLB and its address space's `fill`,
//! so `bind` gives it a Space over the shadow: both tiers copy only the
//! pages a region touches.

const std = @import("std");
const check = @import("../check.zig");
const ctx_mod = @import("../ctx.zig");
const lift = @import("../a64/lift.zig");
const mem = @import("../../interp/mem.zig");
pub const t0 = @import("../../interp/a64/exec.zig");
const dec = t0.dec;

const Ctx = ctx_mod.Ctx;
const Exit = ctx_mod.Exit;
pub const Cpu = t0.Cpu;

pub const guest: check.Guest = .{
    .frontend = lift.frontend,
    .cpu_size = @sizeOf(Cpu),
    .pc_off = @offsetOf(Cpu, "pc"),
    .step = step,
    .diff = diff,
    .bind = bind,
    .unbind = unbind,
};

/// T0's machine over a shadow (or any Space), as ctx.frontend.
pub const Bound = struct {
    machine: t0.Machine,
    cache: t0.Cache,

    pub fn init(gpa: std.mem.Allocator, c: *Ctx, space: t0.Space) !*Bound {
        const b = try gpa.create(Bound);
        b.* = .{ .machine = undefined, .cache = t0.Cache.init(gpa) };
        b.machine = .init(c.cpuPtr(Cpu), c, &b.cache, null);
        b.machine.space = space;
        c.frontend = @intFromPtr(&b.machine);
        return b;
    }

    pub fn deinit(b: *Bound, gpa: std.mem.Allocator) void {
        b.cache.deinit();
        gpa.destroy(b);
    }
};

fn bind(gpa: std.mem.Allocator, c: *Ctx, s: *check.Shadow) anyerror!void {
    _ = try Bound.init(gpa, c, .{ .ctx = s, .fill = shadowFill });
}

fn unbind(gpa: std.mem.Allocator, c: *Ctx) void {
    const m: *t0.Machine = @ptrFromInt(@as(usize, @intCast(c.frontend)));
    const b: *Bound = @fieldParentPtr("machine", m);
    b.deinit(gpa);
}

/// T0's `fill` over a check.Shadow.
pub fn shadowFill(p: *anyopaque, tlb: *mem.Tlb, va: u64, acc: mem.Access) t0.Fill {
    const s: *check.Shadow = @ptrCast(@alignCast(p));
    const c = s.get(va >> mem.page_shift) orelse return .{ .fault = .unmapped };
    const ok = switch (acc) {
        .read => c.read,
        .write => c.write,
        .exec => c.exec,
    };
    if (!ok) return .{ .fault = .permission };
    if (acc != .exec) {
        const table = if (acc == .write) &tlb.write else &tlb.read;
        const vp = va >> mem.page_shift;
        table[@intCast(vp & (mem.entries - 1))] = .{ .tag = vp, .delta = @as(u64, @intFromPtr(&c.data)) -% (vp << mem.page_shift) };
    }
    return .{ .host = @intFromPtr(&c.data) + @as(usize, @intCast(va & (mem.page_size - 1))) };
}

/// One T0 instruction, with the conventions of `check.Guest.step`.
/// ctx.frontend is a *t0.Machine.
pub fn step(c: *Ctx) u32 {
    const m: *t0.Machine = @ptrFromInt(@as(usize, @intCast(c.frontend)));
    const cpu = m.cpu;
    const pc = cpu.pc;
    const f = m.space.?.fill(m.space.?.ctx, m.tlb(), pc, .exec);
    if (f.host == 0 or pc & 3 != 0) {
        c.exit_pc = pc;
        c.exit_addr = pc;
        const fsc: u64 = if (f.fault == .unmapped) 0x07 else 0x0f;
        const esr: u64 = (t0.EC_IABT_LOWER << 26) | (1 << 25) | fsc;
        c.exit_info = @intFromEnum(mem.Access.exec) | (@as(u64, @intFromEnum(f.fault)) << 8) | (esr << 16);
        return @intFromEnum(Exit.fault);
    }
    const word = std.mem.readInt(u32, @as(*const [4]u8, @ptrFromInt(f.host)), .little);
    const o = dec.decode(word, pc);
    switch (t0.step(m, &o, pc)) {
        .next => cpu.pc = pc + 4,
        .jump => |t| {
            if (t & 3 != 0) {
                // run() faults at the target, with the PC there.
                cpu.pc = t;
                c.exit_pc = t;
                c.exit_addr = t;
                c.exit_info = @intFromEnum(mem.Access.exec) | (@as(u64, @intFromEnum(mem.FaultKind.alignment)) << 8);
                return @intFromEnum(Exit.fault);
            }
            cpu.pc = t;
        },
        .exit => switch (m.exit) {
            .syscall => {
                c.exit_pc = cpu.pc;
                return @intFromEnum(Exit.svc);
            },
            .breakpoint => {
                c.exit_pc = pc;
                return @intFromEnum(Exit.brk);
            },
            .interrupted => {
                c.exit_pc = pc;
                return @intFromEnum(Exit.interrupted);
            },
            .fault => |flt| {
                cpu.pc = pc;
                c.exit_pc = pc;
                c.exit_addr = flt.addr;
                c.exit_info = @as(u64, @intFromEnum(flt.access)) | (@as(u64, @intFromEnum(flt.kind)) << 8) | (flt.esr << 16);
                return @intFromEnum(if (flt.esr >> 26 == t0.EC_UNKNOWN) Exit.undef else Exit.fault);
            },
        },
    }
    return 0;
}

fn diff(pa: *const anyopaque, pb: *const anyopaque, w: *std.Io.Writer) bool {
    const a: *const Cpu = @ptrCast(@alignCast(pa));
    const b: *const Cpu = @ptrCast(@alignCast(pb));
    var bad = false;
    for (0..31) |i| if (a.r[i] != b.r[i]) {
        w.print("x{d}: T1 {x}, T0 {x}\n", .{ i, a.r[i], b.r[i] }) catch {};
        bad = true;
    };
    const scalars = .{ .{ "sp", a.r[dec.SP], b.r[dec.SP] }, .{ "pc", a.pc, b.pc }, .{ "nzcv", a.nzcv, b.nzcv }, .{ "fpcr", a.fpcr, b.fpcr }, .{ "fpsr", a.fpsr, b.fpsr }, .{ "tpidr", a.tpidr, b.tpidr }, .{ "tpidrro", a.tpidrro, b.tpidrro } };
    inline for (scalars) |sc| if (sc[1] != sc[2]) {
        w.print("{s}: T1 {x}, T0 {x}\n", .{ sc[0], sc[1], sc[2] }) catch {};
        bad = true;
    };
    for (a.v, b.v, 0..) |x, y, i| if (x != y) {
        w.print("q{d}: T1 {x:0>32}, T0 {x:0>32}\n", .{ i, x, y }) catch {};
        bad = true;
    };
    const ma = a.monitor;
    const mb = b.monitor;
    if (ma.valid != mb.valid or (ma.valid and (ma.addr != mb.addr or ma.size != mb.size or ma.lo != mb.lo or ma.hi != mb.hi))) {
        w.print("monitor: T1 {any}, T0 {any}\n", .{ ma, mb }) catch {};
        bad = true;
    }
    return bad;
}

// ---------------------------------------------------------------- tests

const tracer = @import("../a64/tracer.zig");

test "check/a64: the tracer's loop agrees with T0, from the entry and mid-loop" {
    const gpa = std.testing.allocator;
    const s = try gpa.create(tracer.State);
    defer gpa.destroy(s);
    _ = s.reset();
    var backing = check.mapBacking(&s.map);
    const r = try check.Run.init(gpa, &guest, backing);
    defer r.deinit();
    var reg = try check.liftAt(gpa, &guest, &backing, tracer.code_va, .{});
    defer reg.deinit(gpa);
    const ok = try r.check(.{ .ir_eval = &reg }, std.mem.asBytes(&s.cpu), .{});
    if (!ok) std.debug.print("{s}\n", .{r.report.items});
    try std.testing.expect(ok);
    try std.testing.expectEqual(Exit.svc, r.out[check.Run.t1].exit);
    try std.testing.expectEqual(@as(u64, 3 + 7 * 100 + 1), r.out[check.Run.t0].retired);

    // Budget stops: the loop's poll leaves at its head, mid-count.
    for ([_]i64{ 0, 1, 50, 333 }) |budget| {
        try std.testing.expect(try r.check(.{ .ir_eval = &reg }, std.mem.asBytes(&s.cpu), .{ .budget = budget }));
        try std.testing.expectEqual(Exit.interrupted, r.out[check.Run.t1].exit);
    }
}
