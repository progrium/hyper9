//! h86's `call.helper` table: what lifted code calls for instructions it
//! runs in Zig rather than IR, without leaving the region.
//!
//! x87: every D8-DF instruction runs x87.zig, T0's own, on the Cpu, with
//! the operand's linear address worked out in the IR (so a null FS or GS
//! has faulted there) and memory through the lift.Mem in ctx.frontend.
//! If it traps (#MF for a pending exception, #UD, a page fault), the
//! helper puts back everything it changed and returns nonzero, and the
//! region's guard runs the instruction on T0 through `call.interp`, which
//! raises it with all its detail. A memory operand is translated (both
//! pages if it crosses) before anything is written, so a fault leaves
//! memory as it was too.
//!
//! The table goes in ctx.helpers wherever h86's lifted code runs:
//! vmm/h86.zig, the region check's bind (check/x86.zig), and the tests.

const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const lift = @import("lift.zig");
const cpu_mod = @import("../../interp/x86/cpu.zig");
const exec = @import("../../interp/x86/exec.zig");
const x87 = @import("../../interp/x86/x87.zig");
const dec = @import("../../interp/x86/decode.zig");

const Ctx = ctx_mod.Ctx;
const Cpu = cpu_mod.Cpu;

pub const Index = enum(u8) { x87 = 0 };

pub const table = [_]ctx_mod.HelperFn{x87Helper};

/// The pointer for ctx.helpers.
pub fn tableAddr() u64 {
    return @intFromPtr(&table);
}

/// x87's first argument: what the helper needs of the instruction.
pub const X87Arg = packed struct(u64) {
    pc: u32,
    /// The opcode's low 3 bits (D8-DF).
    op: u3,
    modrm: u8,
    mem: bool,
    seg: u3,
    opsize: bool,
    _: u16 = 0,
};

fn x87Helper(c: *Ctx, a: u64, addr: u64, _: u64) callconv(.c) u64 {
    const cpu = c.cpuPtr(Cpu);
    const m: *lift.Mem = @ptrFromInt(@as(usize, @intCast(c.frontend)));
    const arg: X87Arg = @bitCast(a);
    // What x87.zig may change: the FPU, EAX (FNSTSW AX), EFLAGS (FCOMI),
    // and, on a trap, trap and ecode. EIP is the instruction's while it
    // runs (the last-instruction pointer).
    const fpu = cpu.fpu;
    const eax = cpu.r[0];
    const fl = cpu.fl;
    const eip = cpu.eip;
    const trap = cpu.trap;
    const ecode = cpu.ecode;
    cpu.eip = arg.pc;
    var x: exec.Exec(*lift.Mem) = .{ .c = cpu, .m = m, .opts = .{}, .addr = @truncate(addr) };
    x.i = .{
        .op = .x87,
        .entry = 0,
        .opcode = 0xd8 | @as(u16, arg.op),
        .len = 0,
        .size = 4,
        .opsize = arg.opsize,
        .seg = @enumFromInt(arg.seg),
        .modrm = arg.modrm,
        .mem = arg.mem,
    };
    x87.exec(&x) catch {
        cpu.fpu = fpu;
        cpu.r[0] = eax;
        cpu.fl = fl;
        cpu.eip = eip;
        cpu.trap = trap;
        cpu.ecode = ecode;
        return 1;
    };
    cpu.eip = eip;
    return 0;
}
