//! The tracer bullet: a counted arm64 loop, run on T0, lifted to IR and run in ir_eval, and emitted to arm64 and
//! wasm. Every path has to end in the same machine state. The native run
//! is a test here; the wasm run is tests/jit/run.mjs under Node.

const std = @import("std");
const ir = @import("../ir.zig");
const ir_eval = @import("../ir_eval.zig");
const ctx_mod = @import("../ctx.zig");
const mem = @import("../../interp/mem.zig");
const fe = @import("../frontend.zig");
const lift = @import("lift.zig");
const t0 = @import("../../interp/a64/exec.zig");

pub const code_va = 0x1000;
pub const data_va = 0x20000;

/// x0 = sum of 1..100, x4 = sum of squares, and the data word
/// accumulates too.
pub const program = [_]u32{
    0xD2800000, // movz x0, #0
    0xD2800C81, // movz x1, #100
    0xD2A00042, // movz x2, #2, lsl #16      (x2 = data_va)
    0xF9400043, // loop: ldr x3, [x2]
    0x8B010063, //   add x3, x3, x1
    0xF9000043, //   str x3, [x2]
    0x8B010000, //   add x0, x0, x1
    0x9B011024, //   madd x4, x1, x1, x4
    0xF1000421, //   subs x1, x1, #1
    0x54FFFF41, //   b.ne loop
    0xD4000001, // svc #0
};
pub const svc_return = code_va + 4 * program.len;

pub const Snapshot = struct {
    x: [31]u64,
    nzcv: u32,
    word: u64,
    retired: u64,

    pub fn eql(a: Snapshot, b: Snapshot) bool {
        return std.mem.eql(u64, &a.x, &b.x) and a.nzcv == b.nzcv and a.word == b.word;
    }
};

pub const State = struct {
    code: [mem.page_size]u8 align(mem.page_size) = undefined,
    data: [mem.page_size]u8 align(mem.page_size) = undefined,
    cpu: t0.Cpu = .{},
    tlb: mem.Tlb = .{},
    maps: [2]mem.Mapping = undefined,
    /// The same mappings as a mem.Map, for src/jit/check/.
    regions: [2]mem.Region = undefined,
    map: mem.Map = undefined,
    view: mem.View = undefined,
    cache: t0.Cache = undefined,
    machine: t0.Machine = undefined,
    ctx: ctx_mod.Ctx = .{},

    pub fn reset(s: *State) *ctx_mod.Ctx {
        s.code = @splat(0);
        for (program, 0..) |w, i| std.mem.writeInt(u32, s.code[i * 4 ..][0..4], w, .little);
        s.data = @splat(0);
        std.mem.writeInt(u64, s.data[0..8], 1000, .little);
        s.cpu = .{ .pc = code_va };
        s.tlb = .{};
        s.maps = .{
            .{ .va = code_va, .len = mem.page_size, .host = @intFromPtr(&s.code), .perms = .{ .exec = true } },
            .{ .va = data_va, .len = mem.page_size, .host = @intFromPtr(&s.data), .perms = .{ .write = true } },
        };
        s.view = .{ .maps = &s.maps, .tlb = &s.tlb };
        s.regions = .{
            .{ .va = code_va, .mem = &s.code, .exec = true },
            .{ .va = data_va, .mem = &s.data, .write = true },
        };
        s.map = .{ .regions = &s.regions };
        // Stepping decodes as it goes, so the page cache stays empty.
        s.cache = .init(std.heap.page_allocator);
        s.ctx = .{
            .cpu = @intFromPtr(&s.cpu),
            .tlb = @intFromPtr(&s.tlb),
            .space = @intFromPtr(&s.view),
            .frontend = @intFromPtr(&s.machine),
            .slow_load = @intFromPtr(&mem.slowLoad),
            .slow_store = @intFromPtr(&mem.slowStore),
            .interp = @intFromPtr(&lift.interp),
        };
        s.machine = .init(&s.cpu, &s.ctx, &s.cache, null);
        return &s.ctx;
    }

    pub fn snapshot(s: *State) Snapshot {
        return .{
            .x = s.cpu.r[0..31].*,
            .nzcv = s.cpu.nzcv,
            .word = std.mem.readInt(u64, s.data[0..8], .little),
            .retired = s.ctx.retired,
        };
    }

    /// Runs T0 from a reset, to the SVC, an instruction at a time (the
    /// whole-page dispatch loop is too big a function for wasm engines in
    /// Debug builds).
    pub fn runT0(s: *State) !Snapshot {
        _ = s.reset();
        return s.stepT0();
    }

    /// Runs T0 from the current state to the SVC.
    pub fn stepT0(s: *State) !Snapshot {
        var n: usize = 0;
        while (n < 100_000) : (n += 1) {
            const pc = s.cpu.pc;
            var word: [4]u8 = undefined;
            if (pc < code_va or pc + 4 > code_va + mem.page_size) return error.T0DidNotFinish;
            @memcpy(&word, s.code[@intCast(pc - code_va)..][0..4]);
            const o = t0.dec.decode(std.mem.readInt(u32, &word, .little), pc);
            switch (t0.step(&s.machine, &o, pc)) {
                .next => s.cpu.pc = pc + 4,
                .jump => |t| s.cpu.pc = t,
                .exit => {
                    if (s.machine.exit != .syscall or s.cpu.pc != svc_return) return error.T0DidNotFinish;
                    return s.snapshot();
                },
            }
        }
        return error.T0DidNotFinish;
    }

    fn readCode(p: *anyopaque, va: u64, buf: []u8) usize {
        const s: *State = @ptrCast(@alignCast(p));
        for (buf, 0..) |*b, i| {
            const a = va + i;
            if (a < code_va or a >= code_va + mem.page_size) return i;
            b.* = s.code[@intCast(a - code_va)];
        }
        return buf.len;
    }

    pub fn liftRegion(s: *State, gpa: std.mem.Allocator) !ir.Region {
        _ = s.reset();
        var r: ir.Region = .{ .entry_pc = code_va };
        errdefer r.deinit(gpa);
        var b = ir.Builder.init(gpa, &r);
        try lift.frontend.lift(&b, .{ .ctx = s, .read = readCode }, code_va, .{});
        if (ir.verify(&r)) |e| {
            if (@import("builtin").os.tag != .freestanding) std.debug.print("lifted region doesn't verify: {s} at %{d}\n", .{ e.msg, e.inst });
            return error.Invalid;
        }
        return r;
    }

    /// Checks the run just finished against T0's result.
    pub fn check(s: *State, exit: ctx_mod.Exit, want: Snapshot) bool {
        return exit == .svc and s.ctx.exit_pc == svc_return and s.snapshot().eql(want) and s.ctx.retired == 3 + 7 * 100 + 1;
    }
};

const testexec = @import("../testexec.zig");
const arm64 = @import("../emit/arm64.zig");
const wasm = @import("../emit/wasm.zig");
const alloc_mod = @import("../alloc.zig");

test "tracer bullet: T0, ir_eval, and native arm64 agree on a counted loop" {
    const gpa = std.testing.allocator;
    const s = try gpa.create(State);
    defer gpa.destroy(s);

    const want = try s.runT0();
    try std.testing.expectEqual(@as(u64, 5050), want.x[0]);
    try std.testing.expectEqual(@as(u64, 338350), want.x[4]);
    try std.testing.expectEqual(@as(u64, 1000 + 5050), want.word);

    var r = try s.liftRegion(gpa);
    defer r.deinit(gpa);
    // Three blocks (setup, loop, svc) and the unused fall-out.
    try std.testing.expectEqual(@as(usize, 4), r.blocks.items.len);

    const cx = s.reset();
    try std.testing.expect(s.check(try ir_eval.run(gpa, &r, cx), want));

    var a = try alloc_mod.spillAll(gpa, &r);
    defer a.deinit(gpa);
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(gpa);
    const out = try arm64.emit(gpa, &r, &a, &code);
    var module: std.ArrayList(u8) = .empty;
    defer module.deinit(gpa);
    _ = try wasm.emit(gpa, &r, &a, &module);
    try std.testing.expect(std.mem.startsWith(u8, module.items, "\x00asm"));

    if (!testexec.supported) return;
    const x = try testexec.load(code.items);
    defer x.deinit();
    const cx2 = s.reset();
    const exit: ctx_mod.Exit = @enumFromInt(x.entry(out.entry)(cx2));
    try std.testing.expect(s.check(exit, want));

    // A kick stops the compiled loop at its head, and it resumes from there
    // on T0 to the same result.
    const cx3 = s.reset();
    cx3.budget = 50;
    try std.testing.expectEqual(ctx_mod.Exit.interrupted, @as(ctx_mod.Exit, @enumFromInt(x.entry(out.entry)(cx3))));
    try std.testing.expectEqual(@as(u64, code_va + 12), cx3.exit_pc);
    s.cpu.pc = cx3.exit_pc;
    _ = try s.stepT0();
    var got = s.snapshot();
    got.retired = want.retired;
    try std.testing.expect(got.eql(want));
}
