//! The runtime ABI between generated code and the rest of the emulator:
//! the context every region runs with, how it's passed, and how a region
//! says why it stopped.
//!
//! Every field is 64 bits, pointers included, so the layout is the same
//! on 64-bit hosts and in wasm32, where a generated module reads it from
//! linear memory at the same offsets.
//!
//! Generated code is entered as `EntryFn`: one argument, the context, and
//! an `Exit` code as the result. Inside generated code the context lives in
//! a fixed register (`arm64_ctx_reg`, `x64_ctx_reg`; in wasm it's local 0).
//! Calls out of generated code (the slow path, `call.interp`, helpers, and
//! `ir_eval` fallbacks) are plain C calls that take the context first.

const std = @import("std");

pub const Ctx = extern struct {
    /// *Cpu: the front end's guest register file. getreg and setreg offsets
    /// are into it.
    cpu: u64 = 0,
    /// *mem.Tlb: this vCPU's software TLB.
    tlb: u64 = 0,
    /// Nonzero asks generated code to leave at its next `poll`. Written by
    /// other threads (kick, shootdown), so read it with an atomic load.
    exit_request: u32 = 0,
    _pad0: u32 = 0,
    /// Instructions left before `poll` leaves with `.interrupted`. The
    /// browser host preempts with it; native hosts set it to maxInt.
    budget: i64 = std.math.maxInt(i64),
    /// Guest instructions retired, counted by `retire`.
    retired: u64 = 0,
    /// Why the region left: the guest PC to resume at for every exit but a
    /// fault, where it's the faulting instruction's PC.
    exit_pc: u64 = 0,
    /// For `.fault`: the faulting address.
    exit_addr: u64 = 0,
    /// For `.fault`: a `mem.Access` in bits 0..7, and front-end detail
    /// (such as arm64's syndrome) above.
    exit_info: u64 = 0,
    /// The slow path's loaded value.
    scratch: u64 = 0,
    /// Opaque: the address space the slow path fills the TLB from.
    space: u64 = 0,
    /// Opaque: the front end's own state (its decode cache, its T0 memory).
    frontend: u64 = 0,
    /// mem.SlowLoadFn and mem.SlowStoreFn.
    slow_load: u64 = 0,
    slow_store: u64 = 0,
    /// InterpFn: the front end's `call.interp` handler.
    interp: u64 = 0,
    /// *const [n]HelperFn: the backend's helpers, for `call.helper`.
    helpers: u64 = 0,
    /// mem.SlowCasFn: `cas` (every emitter's path today, and ir_eval's).
    slow_cas: u64 = 0,
    /// *[jump_entries]JumpEntry: this vCPU's jump cache (cache.JumpCache),
    /// for `exit.indirect` to look up inline. 0 when there's none.
    jump: u64 = 0,

    pub fn cpuPtr(c: *Ctx, comptime T: type) *T {
        return @ptrFromInt(@as(usize, @intCast(c.cpu)));
    }
};

/// Byte offsets of Ctx's fields, for emitters.
pub const off = struct {
    pub const cpu = @offsetOf(Ctx, "cpu");
    pub const tlb = @offsetOf(Ctx, "tlb");
    pub const exit_request = @offsetOf(Ctx, "exit_request");
    pub const budget = @offsetOf(Ctx, "budget");
    pub const retired = @offsetOf(Ctx, "retired");
    pub const exit_pc = @offsetOf(Ctx, "exit_pc");
    pub const exit_addr = @offsetOf(Ctx, "exit_addr");
    pub const exit_info = @offsetOf(Ctx, "exit_info");
    pub const scratch = @offsetOf(Ctx, "scratch");
    pub const space = @offsetOf(Ctx, "space");
    pub const frontend = @offsetOf(Ctx, "frontend");
    pub const slow_load = @offsetOf(Ctx, "slow_load");
    pub const slow_store = @offsetOf(Ctx, "slow_store");
    pub const interp = @offsetOf(Ctx, "interp");
    pub const helpers = @offsetOf(Ctx, "helpers");
    pub const slow_cas = @offsetOf(Ctx, "slow_cas");
    pub const jump = @offsetOf(Ctx, "jump");
};

comptime {
    // The layout is part of the ABI: wasm modules hard-code these.
    std.debug.assert(off.cpu == 0 and off.tlb == 8 and off.exit_request == 16 and off.budget == 24);
    std.debug.assert(off.exit_pc == 40 and off.scratch == 64 and off.interp == 104 and off.slow_cas == 120 and off.jump == 128 and @sizeOf(Ctx) == 136);
}

/// The jump cache's layout, for generated code's inline lookup at
/// `exit.indirect`: entry `jumpIndex(pc)` of the table at ctx.jump hits if
/// its `pc` is the target. `code` is then the target translation's chain
/// entry, to jump to with the context register and stack as at a chain
/// site. (cache.JumpCache owns the table; any thread may invalidate an
/// entry by writing its `pc`, and only its vCPU fills it.)
pub const jump_entries = 1024;
pub const JumpEntry = extern struct {
    pc: u64 = std.math.maxInt(u64),
    /// The *cache.Tb, for the runtime.
    tb: u64 = 0,
    /// The executable address of the translation's chain entry.
    code: u64 = 0,
};
pub fn jumpIndex(pc: u64) usize {
    return @intCast((pc ^ (pc >> 10)) & (jump_entries - 1));
}

comptime {
    std.debug.assert(@sizeOf(JumpEntry) == 24 and @offsetOf(JumpEntry, "code") == 16);
}

/// Why generated code returned. At `.chain`, exit_info is the executable
/// address of the chain site the region left through (cache.zig links it),
/// or 0 where there's none (ir_eval, wasm). 0 is never returned: it means "carry on"
/// where a call out of generated code reports success.
pub const Exit = enum(u32) {
    /// Not an exit: the call succeeded.
    ok = 0,
    /// To the guest PC in exit_pc, which may have a region to chain to.
    chain = 1,
    /// To the guest PC in exit_pc, computed at run time.
    indirect = 2,
    /// A system call; resume at exit_pc.
    svc = 3,
    /// A breakpoint instruction at exit_pc.
    brk = 4,
    /// A memory fault: see exit_addr and exit_info. exit_pc is the faulting
    /// instruction.
    fault = 5,
    /// An undefined instruction at exit_pc.
    undef = 6,
    /// An exit request or a spent budget; resume at exit_pc.
    interrupted = 7,
    _,
};

pub const EntryFn = *const fn (ctx: *Ctx) callconv(.c) u32;

/// Runs one decoded instruction (`handle`, from the region's handles) at
/// guest PC `pc`, on the Cpu. Returns `.ok` to go on to the next
/// instruction, or an exit with exit_pc (and the fault fields) set. If the
/// instruction completed and then leaves (an SVC, a branch), the handler
/// adds 1 to ctx.retired and takes 1 from the budget itself; the region
/// adds the instructions before it (ir.Inst.retired).
pub const InterpFn = *const fn (ctx: *Ctx, handle: u64, pc: u64) callconv(.c) u32;

/// A runtime helper for `call.helper`.
pub const HelperFn = *const fn (ctx: *Ctx, a: u64, b: u64, c: u64) callconv(.c) u64;

/// The host register that holds the context inside generated code.
pub const arm64_ctx_reg = 19; // x19, callee-saved
pub const x64_ctx_reg = 3; // rbx, callee-saved in SysV and Win64
