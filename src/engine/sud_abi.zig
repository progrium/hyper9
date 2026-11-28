//! What the sud engine (native.zig) and its stub process
//! (sud_stub.zig) share: where the stub sits, the file descriptors it
//! inherits, and the control page they talk through. See
//! design/epoch-0/native-backend.md.

/// The stub's image is linked here, and it keeps [stub_base, stub_end)
/// for itself: its code and data, and the control page. Everything else
/// below `user_top` is the guest's. It's far above anything 9front's
/// amd64 layout uses (text at 0x200000 and data after it, segattach's
/// segments just below the stack, the stack below USTKTOP), so a guest
/// map can only reach it by asking for that address.
pub const stub_base: u64 = 0x6000_0000_0000;
pub const stub_end: u64 = stub_base + (1 << 32);
/// The control pages' address in the stub: one per stub thread.
pub const ctl_addr: u64 = stub_base + 0xC000_0000;
/// The top of Linux's x86_64 user address space (TASK_SIZE), which is
/// also 9front's amd64 USTKTOP.
pub const user_top: u64 = 0x7FFF_FFFF_F000;

/// The stub's file descriptors: the machine's guest RAM, which map
/// requests name offsets in, its control pages, and the spin budget.
pub const ram_fd = 3;
pub const ctl_fd = 4;
pub const sched_fd = 5;
/// The spin budget's page in the stub, just below the control pages.
pub const sched_addr: u64 = ctl_addr - sched_size;
pub const sched_size = 4096;

/// What every stub and h9 share to decide whether waiting for the other
/// side may spin. A guest syscall is a handoff between a stub thread and
/// an h9 thread, and spinning for the answer saves the futex round trip
/// (tens of microseconds on a cloud VM) but holds a CPU. That pays only
/// while there are CPUs to spare: with more guest threads than CPUs, the
/// spinners take the CPUs the guest and h9 need, and a multithreaded
/// guest gets slower the more threads it has.
pub const Sched = extern struct {
    /// Threads on a CPU for guests: stub threads not asleep (running
    /// guest code, or spinning for h9) and h9 threads spinning for a
    /// stub. h9 threads serving a syscall aren't counted, since they may
    /// be blocked in the kernel. Signed, since a stub killed between
    /// counting itself and setting `Ctl.awake` can leave it one short.
    busy: i32 = 0,
    /// The CPUs h9 may use: its affinity, capped by a cgroup CPU quota.
    ncpus: i32 = 1,
};

/// `Ctl.state`: who has the stub. The host writes `run` or `ops`; the
/// stub writes `guest` when it returns to guest code and `exited` when it
/// stops and waits.
pub const State = enum(u32) { guest = 0, exited = 1, run = 2, ops = 3 };

/// `Ctl.why`, for `exited`.
pub const Why = enum(u32) {
    /// The stub has started and waits for its first run.
    ready = 0,
    /// A guest syscall (SIGSYS from Syscall User Dispatch).
    syscall = 1,
    /// A CPU exception: `signo`, `trapno`, `err` and `addr` say which.
    trap = 2,
    /// A kick (SIGURG) stopped the guest.
    interrupted = 3,
    /// The stub carried out the queued requests (`State.ops`).
    ops_done = 4,
};

/// Threads in a stub, the first of which (the control thread) never runs
/// guest code: it starts the others and carries out requests for a TLB
/// shootdown. Each of the rest runs one vCPU's guest code at a time.
pub const max_threads = 256;

pub const OpKind = enum(u32) { map = 1, unmap = 2, thread = 3, _ };

/// A request the stub carries out before it next runs guest code: map
/// [off, off+len) of the RAM file at `va` with `prot` (PROT_* bits),
/// unmap [va, va+len), or (on the control thread) start thread `va`,
/// which reports `ready` on its own control page.
pub const Op = extern struct {
    va: u64,
    len: u64,
    off: u64,
    prot: u32,
    kind: OpKind,
};

pub const ctl_size = 8192;
/// All the threads' control pages, thread i's at `ctl_addr + i * ctl_size`.
pub const ctls_size = max_threads * ctl_size;

/// A thread's control page, mapped shared in h9.
pub const Ctl = extern struct {
    state: u32 = 0,
    /// Set by a kick: the stub reports a SIGURG as `interrupted` only if
    /// it can take this, so a stale signal resumes the guest.
    kick: u32 = 0,
    /// Set by whichever side is about to sleep on `state`, so the other
    /// wakes it only then.
    host_waiting: u32 = 0,
    stub_waiting: u32 = 0,
    why: Why = .ready,
    signo: u32 = 0,
    /// Set while the thread counts itself in `Sched.busy`, so h9 can
    /// take a killed stub's threads back out.
    awake: u32 = 0,
    _pad: u32 = 0,
    trapno: u64 = 0,
    err: u64 = 0,
    addr: u64 = 0,
    /// The guest's registers: written by the stub at each exit, read back
    /// when it resumes.
    regs: Regs = .{},
    /// FS base: the stub reports it at each exit and sets it on resume
    /// when it differs.
    fs_base: u64 = 0,
    /// GS base, as FS base (ARCH_SET_GS; Wine keeps the TEB there).
    gs_base: u64 = 0,
    /// The signal frame's XSTATE_BV, for `fx`: bits 0 and 1 clear mean
    /// the x87 and SSE state was in its initial state and isn't in `fx`.
    xstate_bv: u64 = 0,
    nops: u32 = 0,
    /// The stub thread's id, for kicks: set before it reports `ready`.
    tid: u32 = 0,
    /// The FXSAVE image's first 416 bytes (through XMM15). The rest of
    /// the 512 is software's, where the kernel keeps its XSAVE marker.
    fx: [fx_len]u8 align(16) = @splat(0),
    /// The signal frame's XSAVE features and how many bytes of its state
    /// past the FXSAVE image are in `xs` (0 if the frame had none).
    xfeatures: u64 = 0,
    xlen: u32 = 0,
    _pad2: u32 = 0,
    /// The XSAVE header and components after the FXSAVE image (AVX's
    /// upper halves, AVX-512's registers), so they go with the vCPU, not
    /// the stub thread, and a signal handler's frame can hold them.
    xs: [xs_max]u8 align(64) = @splat(0),
    ops: [max_ops]Op = undefined,
};

pub const fx_len = 416;
/// As engine.zig's: XSAVE's state past FXSAVE's, up to AVX-512, PKRU and AMX's tile configuration.
pub const xs_max = 2816 - 512;

pub const Regs = extern struct {
    ax: u64 = 0,
    bx: u64 = 0,
    cx: u64 = 0,
    dx: u64 = 0,
    si: u64 = 0,
    di: u64 = 0,
    bp: u64 = 0,
    r8: u64 = 0,
    r9: u64 = 0,
    r10: u64 = 0,
    r11: u64 = 0,
    r12: u64 = 0,
    r13: u64 = 0,
    r14: u64 = 0,
    r15: u64 = 0,
    pc: u64 = 0,
    sp: u64 = 0,
    flags: u64 = 0,
};

const ctl_head = (72 + @sizeOf(Regs) + 24 + fx_len + 16 + 63) / 64 * 64 + xs_max;
pub const max_ops = (ctl_size - ctl_head) / @sizeOf(Op);

comptime {
    if (@sizeOf(Ctl) > ctl_size) @compileError("Ctl doesn't fit");
    if (ctl_addr + ctls_size > stub_end) @compileError("control pages outside the stub's range");
    if (@sizeOf(Sched) > sched_size) @compileError("Sched doesn't fit");
}
