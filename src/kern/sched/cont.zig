//! Kernel continuations, and park and resume (design/scheduler.md).
//!
//! A `Cont` is a process's kernel continuation: the kernel code a process
//! runs on its behalf (a system call), on a kernel stack of its own, so
//! that it can stop in the middle (`park`) and go on later, on any
//! executor (`Executor.resume`). An `Executor` runs continuations: in the
//! scheduler, there's one per host thread (per core), whose loop calls
//! `call` and `resume`; in the cases here, a test calls them.
//!
//! The protocol is posix.c's procsleep and procwakeup, which sync.zig's
//! `park` and `unpark` wrap today, with the host thread taken out:
//!
//! - `park()`, on a continuation, returns once it has an unpark it hasn't
//!   used. An unpark that comes first is kept, and the park returns at
//!   once, as with procsleep's counts, so a wakeup that comes after a
//!   caller lets go of its lock or Rendez and before it parks isn't lost.
//! - `unpark(k)`, from any thread, gives `k` an unpark, and if `k` is
//!   parked, makes it runnable: it calls `k.ready(k)`, the scheduler's
//!   hook to put it on a run queue, from which an executor resumes it.
//!
//! A parked continuation is committed as parked only once it's off its
//! stack: `park` switches to its executor, and the executor, running on
//! its own stack, then sets the parked bit, unless an unpark arrived in
//! between, in which case it switches straight back. So `ready` never
//! sees a continuation that is still running on some executor's thread.
//!
//! Stacks: an executor keeps a spare stack. `call` runs a continuation on
//! it; if the call returns without parking, the stack stays with the
//! executor, and if it parks, the continuation takes it and the executor
//! takes another from the pool for its next call. When a parked call
//! returns, its stack goes back to the executor or the pool. So a process
//! that never blocks never owns a kernel stack, a blocked one owns exactly
//! one, and the switch into and out of a call that doesn't block is two
//! register saves and no allocation.
//!
//! ## The switch, per architecture
//!
//! - **x86_64** (System V: Linux and macOS): `h9_sched_switch` pushes the
//!   callee-saved registers (rbp, rbx, r12 to r15) on the current stack,
//!   stores the stack pointer, loads the other one, and pops and returns
//!   into it. The x87 control word and MXCSR, which the ABI also calls
//!   callee-saved, aren't saved: the kernel never changes them, and guest
//!   floating point state lives in the vCPU, not on these stacks.
//! - **x86_64 Windows**: as System V, plus rdi, rsi, and xmm6 to xmm15,
//!   which the Microsoft ABI makes callee-saved, and the stack bounds in
//!   the thread's TEB (StackBase, StackLimit, and DeallocationStack, at
//!   gs:0x8, gs:0x10, and gs:0x1478), which the unwinder and longjmp check
//!   a stack pointer against.
//! - **aarch64** (AAPCS64: Linux and macOS): stores x19 to x28, the frame
//!   pointer and link register, and d8 to d15 in a 160-byte frame, swaps
//!   sp, loads the other frame, and returns through x30. x18, the platform
//!   register on macOS, is left alone.
//! - **wasm32**: wasm can't switch call stacks from inside a module (the
//!   stack-switching proposal isn't shipped), and the web host's JSPI
//!   suspends the executor, not a process. So a continuation switches with
//!   Binaryen's Asyncify, which the web build runs on h9.wasm: `park`
//!   unwinds the continuation's wasm frames into its Asyncify buffer (at
//!   its stack's low end, stack.zig) back to `h9_sched_wasm_enter`, and
//!   `resume` rewinds them. The C and Zig shadow stack, which lives in
//!   linear memory, is the kernel stack, and its pointer, a wasm global,
//!   is saved and set around each switch. A module that hasn't been
//!   through Asyncify doesn't instantiate, since it imports Asyncify's
//!   functions. The same API maps onto the stack-switching proposal's
//!   `cont.new`, `resume`, and `suspend` once engines ship it.
//!
//! The initial frame of a new continuation returns into `h9_sched_boot`,
//! which calls `start(k)` with the stack aligned as at a call, and never
//! returns: `start` switches out for the last time when the call returns.
//!
//! Thread-local state: a continuation may resume on another host thread,
//! so code on it must not keep a threadlocal's address across a park (LLVM
//! may cache a TLS address within a function). `current` reads the
//! executor's threadlocal through a function that isn't inlined.

const std = @import("std");
const builtin = @import("builtin");
const stack = @import("stack.zig");
const Stack = stack.Stack;
const Pool = stack.Pool;

const arch = builtin.cpu.arch;
const is_wasm = arch.isWasm();
const is_windows = builtin.os.tag == .windows;

comptime {
    if (!is_wasm and arch != .x86_64 and arch != .aarch64)
        @compileError("no kernel stack switch for " ++ @tagName(arch));
    if (is_windows and arch != .x86_64)
        @compileError("no kernel stack switch for Windows on " ++ @tagName(arch));
}

/// What `Executor.call` and `Executor.resume` report.
pub const Outcome = enum {
    /// The call ran to its end. The continuation holds no stack.
    returned,
    /// It parked, and holds its stack until it's resumed and returns.
    parked,
    /// It gave the executor up (`yield`) and is runnable: it holds its
    /// stack, and the scheduler queues it again to be resumed.
    yielded,
};

/// A kernel continuation. Embed it in the process; it holds no memory
/// between calls except while parked.
pub const Cont = struct {
    /// The scheduler's hook: `k` was parked, and an unpark made it
    /// runnable. Called once per park, from the unparking thread, with
    /// `k` off every executor.
    ready: *const fn (k: *Cont) void,

    /// The stack it runs on, between `call` and the call's return.
    stack: ?Stack = null,
    /// The saved stack pointer while it's switched out (native), or the
    /// shadow stack pointer at its park (wasm).
    sp: usize = 0,
    /// The call `call` started.
    func: *const fn (arg: ?*anyopaque) void = undefined,
    arg: ?*anyopaque = null,
    /// Bit 31: parked (committed, off its stack, waiting for an unpark).
    /// The rest: unparks not yet consumed by a park.
    word: std.atomic.Value(u32) = .init(0),
    /// On wasm, whether its frames are in its Asyncify buffer.
    unwound: bool = false,
    /// Its link on a run queue (runq.zig), while it's on one.
    next: ?*Cont = null,

    const parked_bit: u32 = 1 << 31;

    /// Whether it's parked: off its stack until an unpark.
    pub fn isParked(k: *const Cont) bool {
        return k.word.load(.acquire) & parked_bit != 0;
    }

    /// Takes a kept unpark, if there is one.
    fn consume(k: *Cont) bool {
        var w = k.word.load(.acquire);
        while (w & ~parked_bit != 0) {
            w = k.word.cmpxchgWeak(w, w - 1, .acq_rel, .acquire) orelse return true;
        }
        return false;
    }

    /// The executor's side of a park, once k is off its stack: commits
    /// the park, or takes an unpark that came in the meantime. Returns
    /// false if k is to go straight on.
    fn commit(k: *Cont) bool {
        var w = k.word.load(.acquire);
        while (true) {
            std.debug.assert(w & parked_bit == 0);
            const next = if (w != 0) w - 1 else parked_bit;
            w = k.word.cmpxchgWeak(w, next, .acq_rel, .acquire) orelse return next == parked_bit;
        }
    }
};

/// Lets k go on: wakes it if it's parked, and otherwise keeps the unpark
/// for its next park. Safe from any thread, and from code running on a
/// continuation (k's own, or another's).
pub fn unpark(k: *Cont) void {
    var w = k.word.load(.acquire);
    while (true) {
        if (w & Cont.parked_bit != 0) {
            std.debug.assert(w == Cont.parked_bit);
            w = k.word.cmpxchgWeak(w, 0, .acq_rel, .acquire) orelse return k.ready(k);
        } else {
            w = k.word.cmpxchgWeak(w, w + 1, .acq_rel, .acquire) orelse return;
        }
    }
}

/// Parks the continuation running on this thread until it's unparked,
/// and returns on whichever executor resumes it. Only on a continuation.
pub fn park() void {
    const ex = current().?;
    const k = ex.cur.?;
    if (k.consume()) return;
    if (ex.out_hook) |h| h(ex, k);
    ex.why = .park;
    switchOut(ex, k);
}

/// Gives the executor up for now, with k runnable: the executor's call
/// or resume reports `yielded`, and the scheduler resumes it later. Only
/// on a continuation. Its time slice is up, for one.
pub fn yield() void {
    const ex = current().?;
    const k = ex.cur.?;
    if (ex.out_hook) |h| h(ex, k);
    ex.why = .yield;
    switchOut(ex, k);
}

/// Ends the call running on this thread now, as if its function had
/// returned: what's on its stack is abandoned, so nothing it holds may
/// need its frames after. A process that exits does this.
pub fn exit() noreturn {
    const ex = current().?;
    const k = ex.cur.?;
    ex.why = .ret;
    // On wasm the unwind is abandoned: nothing rewinds it.
    switchOut(ex, k);
    unreachable;
}

/// The stack pointer: on wasm the shadow stack's, a global.
pub fn stackPointer() usize {
    if (is_wasm) return wasm.h9_sched_get_sp();
    return @frameAddress();
}

/// The continuation running on this thread, if any.
pub fn self() ?*Cont {
    const ex = current() orelse return null;
    return ex.cur;
}

threadlocal var tls_executor: ?*Executor = null;

/// The executor on this thread. Not inlined, so a continuation that has
/// moved to another thread reads that thread's.
pub noinline fn current() ?*Executor {
    return @as(*volatile ?*Executor, &tls_executor).*;
}

noinline fn setCurrent(ex: ?*Executor) void {
    @as(*volatile ?*Executor, &tls_executor).* = ex;
}

/// Runs continuations, one at a time, on the calling thread.
pub const Executor = struct {
    pool: *Pool,
    /// The stack the next call runs on.
    spare: ?Stack = null,
    /// The continuation running, between a switch in and out.
    cur: ?*Cont = null,
    /// The executor's own saved stack pointer while a continuation runs.
    sp: usize = 0,
    /// Why the continuation switched out.
    why: enum { park, yield, ret } = .ret,
    /// Called on the continuation as it parks or yields, before it
    /// switches out: while nothing can resume it yet, so what it leaves
    /// on the executor (a vCPU's registers) can be saved for another to
    /// load.
    out_hook: ?*const fn (ex: *Executor, k: *Cont) void = null,
    /// The scheduler's, for its hooks.
    ctx: ?*anyopaque = null,

    pub fn init(pool: *Pool) Executor {
        return .{ .pool = pool };
    }

    pub fn deinit(ex: *Executor) void {
        std.debug.assert(ex.cur == null);
        if (ex.spare) |s| ex.pool.put(s);
        ex.spare = null;
    }

    /// Runs func(arg) as k's kernel call, until it returns or parks.
    /// k must hold no call already. An error only if no stack could be
    /// mapped.
    pub fn call(ex: *Executor, k: *Cont, func: *const fn (?*anyopaque) void, arg: ?*anyopaque) stack.Error!Outcome {
        std.debug.assert(k.stack == null and !k.isParked());
        const s = ex.spare orelse try ex.pool.get();
        ex.spare = null;
        k.stack = s;
        k.func = func;
        k.arg = arg;
        k.unwound = false;
        k.sp = initFrame(s, k);
        return ex.run(k);
    }

    /// Goes on with k, parked, after an unpark made it runnable (its
    /// `ready` hook). Returns when it parks again or its call returns.
    pub fn @"resume"(ex: *Executor, k: *Cont) Outcome {
        std.debug.assert(k.stack != null and !k.isParked());
        return ex.run(k);
    }

    fn run(ex: *Executor, k: *Cont) Outcome {
        const prev = current();
        setCurrent(ex);
        defer setCurrent(prev);
        ex.cur = k;
        defer ex.cur = null;
        while (true) {
            switchIn(ex, k);
            switch (ex.why) {
                .ret => {
                    const s = k.stack.?;
                    k.stack = null;
                    if (ex.spare == null) ex.spare = s else ex.pool.put(s);
                    return .returned;
                },
                .park => {
                    if (!k.stack.?.holds(k.sp)) @panic("kernel stack overflow");
                    if (k.commit()) return .parked;
                    // An unpark came while it was switching out: go on.
                },
                .yield => {
                    if (!k.stack.?.holds(k.sp)) @panic("kernel stack overflow");
                    return .yielded;
                },
            }
        }
    }
};

/// Runs on k's stack, for its whole call. Never inlined: on wasm,
/// Asyncify must instrument it apart from h9_sched_wasm_enter.
noinline fn start(k: *Cont) callconv(.c) void {
    k.func(k.arg);
    const ex = current().?;
    ex.why = .ret;
    if (is_wasm) return; // h9_sched_wasm_enter returns to the executor.
    switchOut(ex, k);
    unreachable;
}

// The switch.

fn switchIn(ex: *Executor, k: *Cont) void {
    if (is_wasm) return wasm.switchIn(ex, k);
    h9_sched_switch(&ex.sp, k.sp);
}

fn switchOut(ex: *Executor, k: *Cont) void {
    if (is_wasm) return wasm.switchOut(ex, k);
    h9_sched_switch(&k.sp, ex.sp);
}

// h9_sched_switch saves the callee-saved registers on the current
// stack, stores its pointer in *from, and switches to the stack at `to`,
// popping its registers and returning into it. It and h9_sched_boot are
// below.

/// Lays out a new stack as if h9_sched_switch had switched off it, about
/// to return into h9_sched_boot, which calls start(k). Returns its sp.
fn initFrame(s: Stack, k: *Cont) usize {
    if (is_wasm) return s.hi();
    const top = s.hi();
    const boot = @intFromPtr(h9_sched_boot);
    const entry = @intFromPtr(&start);
    const kp = @intFromPtr(k);
    // In the order h9_sched_switch pops them, lowest address first.
    var buf: [32]usize = @splat(0);
    const words: []const usize = switch (arch) {
        .x86_64 => if (is_windows) blk: {
            // xmm6 to xmm15 (20 words of zeros), the TEB's StackBase,
            // StackLimit, and DeallocationStack, then r15, r14, r13, r12,
            // rsi, rdi, rbx, rbp, and the return address.
            buf[20] = top;
            buf[21] = s.lo();
            buf[22] = @intFromPtr(s.mem.ptr);
            buf[25] = entry; // r13
            buf[26] = kp; // r12
            buf[31] = boot;
            break :blk buf[0..32];
        } else blk: {
            // r15, r14, r13, r12, rbx, rbp, and the return address.
            buf[2] = entry; // r13
            buf[3] = kp; // r12
            buf[6] = boot;
            break :blk buf[0..7];
        },
        .aarch64 => blk: {
            // x19 to x28, x29, x30, then d8 to d15.
            buf[0] = kp; // x19
            buf[1] = entry; // x20
            buf[11] = boot; // x30
            break :blk buf[0..20];
        },
        else => unreachable,
    };
    // h9_sched_switch's pops and return leave sp just above these words.
    // aarch64 needs it 16-byte aligned there (20 words); x86_64's boot
    // aligns it itself before its call.
    const sp = std.mem.alignBackward(usize, top - words.len * @sizeOf(usize), 16);
    const frame: [*]usize = @ptrFromInt(sp);
    for (words, 0..) |w, i| frame[i] = w;
    return sp;
}

/// h9_sched_switch's body, for this architecture and ABI.
const switch_body = switch (arch) {
    .x86_64 => if (is_windows)
        \\pushq %%rbp
        \\pushq %%rbx
        \\pushq %%rdi
        \\pushq %%rsi
        \\pushq %%r12
        \\pushq %%r13
        \\pushq %%r14
        \\pushq %%r15
        \\pushq %%gs:0x1478
        \\pushq %%gs:0x10
        \\pushq %%gs:0x8
        \\subq $160, %%rsp
        \\movups %%xmm6, 0(%%rsp)
        \\movups %%xmm7, 16(%%rsp)
        \\movups %%xmm8, 32(%%rsp)
        \\movups %%xmm9, 48(%%rsp)
        \\movups %%xmm10, 64(%%rsp)
        \\movups %%xmm11, 80(%%rsp)
        \\movups %%xmm12, 96(%%rsp)
        \\movups %%xmm13, 112(%%rsp)
        \\movups %%xmm14, 128(%%rsp)
        \\movups %%xmm15, 144(%%rsp)
        \\movq %%rsp, (%%rcx)
        \\movq %%rdx, %%rsp
        \\movups 0(%%rsp), %%xmm6
        \\movups 16(%%rsp), %%xmm7
        \\movups 32(%%rsp), %%xmm8
        \\movups 48(%%rsp), %%xmm9
        \\movups 64(%%rsp), %%xmm10
        \\movups 80(%%rsp), %%xmm11
        \\movups 96(%%rsp), %%xmm12
        \\movups 112(%%rsp), %%xmm13
        \\movups 128(%%rsp), %%xmm14
        \\movups 144(%%rsp), %%xmm15
        \\addq $160, %%rsp
        \\popq %%gs:0x8
        \\popq %%gs:0x10
        \\popq %%gs:0x1478
        \\popq %%r15
        \\popq %%r14
        \\popq %%r13
        \\popq %%r12
        \\popq %%rsi
        \\popq %%rdi
        \\popq %%rbx
        \\popq %%rbp
        \\retq
    else
        \\pushq %%rbp
        \\pushq %%rbx
        \\pushq %%r12
        \\pushq %%r13
        \\pushq %%r14
        \\pushq %%r15
        \\movq %%rsp, (%%rdi)
        \\movq %%rsi, %%rsp
        \\popq %%r15
        \\popq %%r14
        \\popq %%r13
        \\popq %%r12
        \\popq %%rbx
        \\popq %%rbp
        \\retq
    ,
    .aarch64 =>
    \\sub sp, sp, #160
    \\stp x19, x20, [sp, #0]
    \\stp x21, x22, [sp, #16]
    \\stp x23, x24, [sp, #32]
    \\stp x25, x26, [sp, #48]
    \\stp x27, x28, [sp, #64]
    \\stp x29, x30, [sp, #80]
    \\stp d8, d9, [sp, #96]
    \\stp d10, d11, [sp, #112]
    \\stp d12, d13, [sp, #128]
    \\stp d14, d15, [sp, #144]
    \\mov x9, sp
    \\str x9, [x0]
    \\mov sp, x1
    \\ldp x19, x20, [sp, #0]
    \\ldp x21, x22, [sp, #16]
    \\ldp x23, x24, [sp, #32]
    \\ldp x25, x26, [sp, #48]
    \\ldp x27, x28, [sp, #64]
    \\ldp x29, x30, [sp, #80]
    \\ldp d8, d9, [sp, #96]
    \\ldp d10, d11, [sp, #112]
    \\ldp d12, d13, [sp, #128]
    \\ldp d14, d15, [sp, #144]
    \\add sp, sp, #160
    \\ret
    ,
    else => "",
};

/// h9_sched_boot's body: calls start(k), with k and start in the
/// registers the initial frame loaded, and the stack aligned as a call
/// needs.
const boot_body = switch (arch) {
    .x86_64 => if (is_windows)
        \\movq %%r12, %%rcx
        \\andq $-16, %%rsp
        \\subq $32, %%rsp
        \\callq *%%r13
        \\ud2
    else
        \\movq %%r12, %%rdi
        \\andq $-16, %%rsp
        \\callq *%%r13
        \\ud2
    ,
    .aarch64 =>
    \\mov x0, x19
    \\blr x20
    \\brk #1
    ,
    else => "",
};

// Naked, so they have no prologue, and called through pointers, since
// Zig doesn't call a naked function directly. (Global assembly would do
// as well, but Zig's own x86_64 backend leaves it out.)
fn switchNaked() callconv(.naked) void {
    // memory: the continuation it switches to reads and writes what the
    // caller thinks is its own (the executor's fields, for one), so LLVM
    // mustn't take the call for one that touches no memory.
    asm volatile (switch_body ::: .{ .memory = true });
}

fn bootNaked() callconv(.naked) noreturn {
    asm volatile (boot_body ::: .{ .memory = true });
}

const h9_sched_switch: *const fn (from: *usize, to: usize) callconv(.c) void = @ptrCast(&switchNaked);
const h9_sched_boot = &bootNaked;

// wasm32: Asyncify (see the top of the file).
const wasm = if (is_wasm) struct {
    // Binaryen's Asyncify pass replaces these imports with its own
    // functions. The buffer is { current, end } and then the data.
    extern "asyncify" fn start_unwind(buf: *AsyncBuf) void;
    extern "asyncify" fn stop_unwind() void;
    extern "asyncify" fn start_rewind(buf: *AsyncBuf) void;
    extern "asyncify" fn stop_rewind() void;

    const AsyncBuf = extern struct { cur: usize, end: usize };

    extern fn h9_sched_get_sp() usize;
    extern fn h9_sched_set_sp(sp: usize) void;

    comptime {
        asm (
            \\.globaltype __stack_pointer, i32
            \\.globl h9_sched_get_sp
            \\.type h9_sched_get_sp,@function
            \\h9_sched_get_sp:
            \\  .functype h9_sched_get_sp () -> (i32)
            \\  global.get __stack_pointer
            \\  end_function
            \\.globl h9_sched_set_sp
            \\.type h9_sched_set_sp,@function
            \\h9_sched_set_sp:
            \\  .functype h9_sched_set_sp (i32) -> ()
            \\  local.get 0
            \\  global.set __stack_pointer
            \\  end_function
        );
    }

    fn buf(k: *Cont) *AsyncBuf {
        return @ptrCast(@alignCast(k.stack.?.asyncBuf().ptr));
    }

    /// The bottom of every continuation's wasm frames. It calls
    /// start_rewind and stop_unwind, so Asyncify leaves it alone and an
    /// unwind stops here; switchOut calls start_unwind and stop_rewind, so
    /// it's left alone too, and its callers are instrumented. Neither may
    /// be inlined into a function that must be instrumented.
    noinline fn h9_sched_wasm_enter(k: *Cont) void {
        const sp = h9_sched_get_sp();
        h9_sched_set_sp(k.sp);
        if (k.unwound) start_rewind(buf(k));
        start(k);
        // An unwind (a park) or the call's end.
        if (k.unwound) stop_unwind();
        h9_sched_set_sp(sp);
    }

    fn switchIn(_: *Executor, k: *Cont) void {
        h9_sched_wasm_enter(k);
    }

    /// On k's stack: unwinds to h9_sched_wasm_enter, and returns here when
    /// it's rewound. The rewind calls this again, with k.unwound set.
    noinline fn switchOut(_: *Executor, k: *Cont) void {
        if (k.unwound) {
            k.unwound = false;
            stop_rewind();
            return;
        }
        k.sp = h9_sched_get_sp();
        const b = buf(k);
        const data = k.stack.?.asyncBuf();
        b.cur = @intFromPtr(data.ptr) + @sizeOf(AsyncBuf);
        b.end = @intFromPtr(data.ptr) + data.len;
        k.unwound = true;
        start_unwind(b);
    }
} else struct {
    fn switchIn(_: *Executor, _: *Cont) void {}
    fn switchOut(_: *Executor, _: *Cont) void {}
};
