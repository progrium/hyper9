//! Native engine (Linux x86_64): guest code runs on the host CPU in a
//! stub process, with no hypervisor and no emulator. See
//! design/epoch-0/native-backend.md.
//!
//! Guest memory is one shared memory file (memfd), mapped once in h9 and
//! handed out in pages by gphys.Ram, so `translate` and `copy` read guest
//! memory in place, as on the hypervisor engines. Each address space is
//! a stub process (sud_stub.zig) started from an embedded image on its
//! first run, which maps ranges of that file at the guest's addresses.
//! Map and unmap requests queue on the address space and the stub
//! carries them out before it next runs guest code.
//!
//! A vCPU is a view of a thread in its address space's stub: `run` takes
//! a stub thread (the one it ran on last, if it's free, so FP state
//! beyond what `Extra` carries, AVX's upper halves, stays with it), writes
//! the registers to that thread's control page, lets it return into guest
//! code, and waits for the next exit (a syscall, a CPU exception or a
//! kick), which the stub's signal handler reports there. A Linux
//! program's threads are vCPUs in one space, so they run in parallel on
//! the stub's threads. The stub's control thread starts the others and
//! carries out the queued requests for `shootdown`.
//!
//! Kicks send the stub thread SIGURG; it reports it as `interrupted` only
//! while `Ctl.kick` is set, so a signal that arrives after the run it was
//! meant for has ended just resumes the guest.

const std = @import("std");
const linux = std.os.linux;
const engine = @import("../engine.zig");
const gphys = @import("gphys.zig");
const amd64 = @import("../arch/amd64.zig");
const abi = @import("sud_abi.zig");

const stub_image = @embedFile("sud_stub");

/// pc/io.h VectorSYSCALL, which 9front puts in Ureg.type for syscalls.
const vector_syscall = 64;
const vector_bp = 3;
const vector_pf = 14;

const SIGURG = 23;
const SIGBUS = 7;
const SIGSEGV = 11;

/// Rounds h9 spins at most waiting for an exit before sleeping on the
/// futex. A guest syscall's round trip is a few microseconds when neither
/// side sleeps, and tens when a sleeping CPU has to be woken (see the
/// proposal's spike results). Spinning is also subject to `abi.Sched`.
const spin_rounds = 4000;

/// The spin budget every stub shares with h9 (`abi.Sched`): one page,
/// made on the first engine and kept for the life of h9.
var sched_lock: std.atomic.Mutex = .unlocked;
var sched_fd: i32 = -1;
var sched: ?*abi.Sched = null;

fn schedInit() engine.Error!void {
    while (!sched_lock.tryLock()) std.atomic.spinLoopHint();
    defer sched_lock.unlock();
    if (sched != null) return;
    const rc = linux.memfd_create("h9-sched", linux.MFD.CLOEXEC);
    if (failed(rc)) return error.HypervisorFailed;
    const fd: i32 = @intCast(rc);
    if (failed(linux.ftruncate(fd, abi.sched_size))) {
        closeFd(fd);
        return error.HypervisorFailed;
    }
    const map = std.posix.mmap(null, abi.sched_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0) catch {
        closeFd(fd);
        return error.HypervisorFailed;
    };
    const sh: *abi.Sched = @ptrCast(@alignCast(map.ptr));
    sh.* = .{ .ncpus = @intCast(hostCpus()) };
    sched_fd = fd;
    sched = sh;
}

/// The CPUs h9 may run on: its affinity, capped by a cgroup v2 CPU quota
/// (a container's --cpus), which affinity doesn't show.
fn hostCpus() u32 {
    var n: u32 = @intCast(@min(std.Thread.getCpuCount() catch 1, 1 << 16));
    var buf: [64]u8 = undefined;
    const fd_rc = linux.open("/sys/fs/cgroup/cpu.max", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (!failed(fd_rc)) {
        const fd: i32 = @intCast(fd_rc);
        defer closeFd(fd);
        const len = linux.read(fd, &buf, buf.len);
        if (!failed(len)) {
            // "max 100000", or "QUOTA PERIOD" in microseconds.
            var it = std.mem.tokenizeAny(u8, buf[0..len], " \n");
            const quota = std.fmt.parseInt(u64, it.next() orelse "", 10) catch 0;
            const period = std.fmt.parseInt(u64, it.next() orelse "", 10) catch 0;
            if (quota > 0 and period > 0) n = @min(n, @as(u32, @intCast(@max(1, @min((quota + period - 1) / period, 1 << 16)))));
        }
    }
    return @max(n, 1);
}

/// Counts an h9 thread about to spin for a stub in `busy`, if that still
/// leaves a CPU free for the h9 threads serving syscalls, which `busy`
/// doesn't count (measured: keeping one free is about 10% faster with
/// four guest threads on four CPUs, and the same with one). The caller
/// calls `unspin` after.
fn trySpin(sh: *abi.Sched) bool {
    const was = @atomicRmw(i32, &sh.busy, .Add, 1, .seq_cst);
    if (was + 1 < @atomicLoad(i32, &sh.ncpus, .monotonic)) return true;
    _ = @atomicRmw(i32, &sh.busy, .Sub, 1, .seq_cst);
    return false;
}

fn unspin(sh: *abi.Sched) void {
    _ = @atomicRmw(i32, &sh.busy, .Sub, 1, .seq_cst);
}

/// Takes one out of `busy` unless it's zero already.
fn unspinClamped(sh: *abi.Sched) void {
    var cur = @atomicLoad(i32, &sh.busy, .seq_cst);
    while (cur > 0) cur = @cmpxchgWeak(i32, &sh.busy, cur, cur - 1, .seq_cst, .seq_cst) orelse return;
}

/// Whether a spinning h9 thread, counted in `busy`, may go on: as
/// `trySpin`.
fn maySpin(sh: *abi.Sched) bool {
    return @atomicLoad(i32, &sh.busy, .monotonic) < @atomicLoad(i32, &sh.ncpus, .monotonic);
}

/// `abi.Sched.busy`, once an engine has made the page.
pub fn spinBusy() ?i32 {
    const sh = sched orelse return null;
    return @atomicLoad(i32, &sh.busy, .seq_cst);
}

fn failed(rc: usize) bool {
    return linux.errno(rc) != .SUCCESS;
}

fn closeFd(fd: i32) void {
    _ = linux.close(fd);
}

const PR_GET_SECCOMP = 21;
const PR_SET_SYSCALL_USER_DISPATCH = 59;
const PR_SYS_DISPATCH_OFF = 0;

/// Whether the stub runs and traps here: checked once per h9, by `probe`.
var probe_state: std.atomic.Value(u8) = .init(0); // 0 unknown, 1 ok, 2 not
var probe_reason: []const u8 = "";

/// Why the sud engine can't be used here, or null if it can (as far
/// as is known before `probe` has run).
pub fn whyUnavailable() ?[]const u8 {
    if (failed(linux.prctl(PR_SET_SYSCALL_USER_DISPATCH, PR_SYS_DISPATCH_OFF, 0, 0, 0)))
        return "the kernel has no Syscall User Dispatch (Linux 5.11 or later)";
    if (failed(linux.prctl(PR_GET_SECCOMP, 0, 0, 0, 0)))
        return "the kernel has no seccomp";
    if (probe_state.load(.acquire) == 2) return probe_reason;
    return null;
}

/// Values the probe puts in AX at a guest syscall. 9front ignores AX
/// there, so a guest can leave anything in it, and the host kernel
/// mustn't act on any of them: the spike found a kernel that runs 335
/// and 336 before seccomp sees them. Ordinary numbers too, and ones past
/// the table, for the x32 ABI, and with high bits set. None does harm if
/// it isn't trapped, with no file descriptors open but the stub's own.
const probe_ax = [_]u64{ 0, 39, 335, 336, 0x4000_0027, 0x7fff_ffff, 0x1_0000_0027, std.math.maxInt(u64), 60 };
/// The probe's syscall number (in BP), which no 9front call uses.
const probe_bp = 0x7f7f;
/// The probe: AX from the table, BP the marker, SYSCALL, next.
///   leaq table(%rip), %rsi; 1: movq (%rsi), %rax; movl $0x7f7f, %ebp;
///   syscall; addq $8, %rsi; jmp 1b; nop; table:
const probe_code = [_]u8{
    0x48, 0x8d, 0x35, 0x11, 0x00, 0x00, 0x00,
    0x48, 0x8b, 0x06,
    0xbd, 0x7f, 0x7f, 0x00, 0x00,
    0x0f, 0x05,
    0x48, 0x83, 0xc6, 0x08,
    0xeb, 0xf0,
    0x90,
};

pub const Engine = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    ram: gphys.Ram,
    ram_fd: i32,
    stub_fd: i32,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, opts: engine.Options) engine.CreateError!*Engine {
        if (opts.arch != .amd64) return error.WrongArch;
        if (whyUnavailable() != null) return error.HypervisorUnavailable;

        const size = opts.memory orelse engine.default_memory;
        if (size > engine.max_memory) return error.OutOfGuestMemory;
        const len = std.mem.alignForward(usize, @intCast(size), engine.page_size);
        if (len < 16 * engine.page_size) return error.OutOfGuestMemory;

        const ram_rc = linux.memfd_create("h9-ram", linux.MFD.CLOEXEC);
        if (failed(ram_rc)) return error.HypervisorFailed;
        const ram_fd: i32 = @intCast(ram_rc);
        errdefer closeFd(ram_fd);
        if (failed(linux.ftruncate(ram_fd, @intCast(len)))) return error.OutOfGuestMemory;
        const mem = std.posix.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, ram_fd, 0) catch
            return error.OutOfGuestMemory;
        errdefer std.posix.munmap(mem);

        try schedInit();
        const stub_fd = try stubFile();
        errdefer closeFd(stub_fd);

        const b = try gpa.create(Engine);
        b.* = .{
            .gpa = gpa,
            .io = io,
            .ram = .{ .gpa = gpa, .io = io, .base = 0, .mem = mem, .release = .{ .memfd = ram_fd } },
            .ram_fd = ram_fd,
            .stub_fd = stub_fd,
        };
        errdefer gpa.destroy(b);
        try b.probe();
        return b;
    }

    /// Runs a probe in a stub, once per h9, so a host where the stub
    /// can't start (a container whose seccomp profile refuses its filter,
    /// say) or where a guest syscall reaches the host kernel is found
    /// here, and auto moves on.
    fn probe(b: *Engine) engine.CreateError!void {
        switch (probe_state.load(.acquire)) {
            1 => return,
            2 => return error.HypervisorUnavailable,
            else => {},
        }
        if (b.runProbe()) |why| {
            probe_reason = why;
            probe_state.store(2, .release);
            return error.HypervisorUnavailable;
        }
        probe_state.store(1, .release);
    }

    /// Runs `probe_code`; returns what went wrong, or null.
    fn runProbe(b: *Engine) ?[]const u8 {
        const as = b.newAddressSpace() catch return "out of memory";
        defer as.destroy();
        const page = b.allocPages(1) catch return "out of memory";
        defer b.freePages(page);
        @memcpy(page[0..probe_code.len], &probe_code);
        for (probe_ax, 0..) |ax, i| std.mem.writeInt(u64, page[probe_code.len + 8 * i ..][0..8], ax, .little);
        const text = 0x200000;
        as.map(text, page, .{ .read = true, .exec = true }) catch return "out of memory";
        var v = b.createVcpu() catch return "out of memory";
        defer v.destroy();
        v.setAddressSpace(as) catch unreachable;
        v.s.ureg = .{ .pc = text, .flags = 0x202 };
        for (probe_ax) |ax| {
            const exit = v.run() catch |e| return switch (e) {
                error.HypervisorUnavailable => "the stub can't start (is seccomp or prctl refused here?)",
                else => "a guest syscall killed the stub instead of trapping",
            };
            if (exit != .syscall or v.s.ureg.bp != probe_bp or v.s.ureg.ax != ax)
                return "a guest syscall didn't trap to h9";
        }
        return null;
    }

    pub fn destroy(b: *Engine) void {
        closeFd(b.stub_fd);
        b.ram.deinit();
        closeFd(b.ram_fd);
        b.gpa.destroy(b);
    }

    /// No hardware limit: every process gets its own stub, as each gets
    /// its own engine on the emulator.
    pub fn maxVcpus(_: *Engine) engine.Error!u32 {
        return 1 << 16;
    }

    pub fn allocPages(b: *Engine, n: usize) engine.Error![]align(engine.page_size) u8 {
        return b.ram.allocPages(n);
    }

    pub fn freePages(b: *Engine, mem: []align(engine.page_size) u8) void {
        b.ram.freePages(mem);
    }

    pub fn newAddressSpace(b: *Engine) engine.CreateError!*AddressSpace {
        const as = try b.gpa.create(AddressSpace);
        as.* = .{ .engine = b };
        return as;
    }

    pub fn createVcpu(b: *Engine) engine.CreateError!Vcpu {
        const s = try b.gpa.create(State);
        s.* = .{ .engine = b };
        return .{ .s = s };
    }
};

/// The stub's image, in a memory file it's executed from.
fn stubFile() engine.Error!i32 {
    const MFD_EXEC = 0x0010;
    var rc = linux.memfd_create("h9-stub", linux.MFD.CLOEXEC | linux.MFD.ALLOW_SEALING | MFD_EXEC);
    // Kernels before 6.3 don't know MFD_EXEC.
    if (linux.errno(rc) == .INVAL) rc = linux.memfd_create("h9-stub", linux.MFD.CLOEXEC | linux.MFD.ALLOW_SEALING);
    if (failed(rc)) return error.HypervisorFailed;
    const fd: i32 = @intCast(rc);
    errdefer closeFd(fd);
    var off: usize = 0;
    while (off < stub_image.len) {
        const n = linux.write(fd, stub_image[off..].ptr, stub_image.len - off);
        if (failed(n) or n == 0) return error.HypervisorFailed;
        off += n;
    }
    // F_ADD_SEALS: SEAL_SEAL | SEAL_SHRINK | SEAL_GROW | SEAL_WRITE.
    _ = linux.fcntl(fd, 1033, 0x1 | 0x2 | 0x4 | 0x8);
    return fd;
}

const SpawnArgs = struct {
    stub: i32,
    ram: i32,
    ctl: i32,
    sched: i32,
};

/// The child half of starting a stub, on a borrowed stack in h9's memory
/// (CLONE_VM | CLONE_VFORK): sets up file descriptors 3, 4, and 5 and execs
/// the stub. Only raw syscalls here.
fn spawnChild(arg: usize) callconv(.c) u8 {
    const a: *const SpawnArgs = @ptrFromInt(arg);
    // Its own session, away from h9's terminal, so the terminal's signals
    // (Ctrl-C's SIGINT, SIGTSTP, SIGHUP) go to h9 and not to the stubs.
    _ = linux.syscall0(.setsid);
    const F_DUPFD = 0;
    const F_SETFD = 2;
    // Above every fd involved first, so the dup2s below can't clobber one.
    const r: i32 = @intCast(@as(isize, @bitCast(linux.fcntl(a.ram, F_DUPFD, 16))));
    const c: i32 = @intCast(@as(isize, @bitCast(linux.fcntl(a.ctl, F_DUPFD, 16))));
    const d: i32 = @intCast(@as(isize, @bitCast(linux.fcntl(a.sched, F_DUPFD, 16))));
    const s: i32 = @intCast(@as(isize, @bitCast(linux.fcntl(a.stub, F_DUPFD, 16))));
    _ = linux.dup2(r, abi.ram_fd);
    _ = linux.dup2(c, abi.ctl_fd);
    _ = linux.dup2(d, abi.sched_fd);
    const exe = abi.sched_fd + 1;
    _ = linux.dup2(s, exe);
    _ = linux.fcntl(exe, F_SETFD, 1); // FD_CLOEXEC: gone once the stub runs
    // Nothing else, not even h9's standard input and output.
    _ = linux.close_range(0, 2, .{ .UNSHARE = false, .CLOEXEC = false });
    _ = linux.close_range(exe + 1, std.math.maxInt(i32), .{ .UNSHARE = false, .CLOEXEC = false });
    const argv = [_:null]?[*:0]const u8{"h9-stub"};
    const envp = [_:null]?[*:0]const u8{};
    _ = linux.execveat(exe, "", &argv, &envp, .{ .SYMLINK_NOFOLLOW = false, .EMPTY_PATH = true });
    _ = linux.syscall1(.exit_group, 127);
    return 127;
}

/// One running stub, as h9 sees it.
const Stub = struct {
    pid: i32,
    ctls: *[abi.max_threads]abi.Ctl,

    /// Starts a stub and waits until its control thread is ready.
    fn start(b: *Engine) engine.Error!Stub {
        const ctl_rc = linux.memfd_create("h9-ctl", linux.MFD.CLOEXEC);
        if (failed(ctl_rc)) return error.HypervisorFailed;
        const ctl_fd: i32 = @intCast(ctl_rc);
        defer closeFd(ctl_fd);
        if (failed(linux.ftruncate(ctl_fd, abi.ctls_size))) return error.HypervisorFailed;
        const map = std.posix.mmap(null, abi.ctls_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, ctl_fd, 0) catch
            return error.HypervisorFailed;
        const ctls: *[abi.max_threads]abi.Ctl = @ptrCast(map.ptr);
        @atomicStore(u32, &ctls[0].state, @intFromEnum(abi.State.guest), .release);

        var args: SpawnArgs = .{ .stub = b.stub_fd, .ram = b.ram_fd, .ctl = ctl_fd, .sched = sched_fd };
        var stack: [16 * 1024]u8 align(16) = undefined;
        const SIGCHLD = 17;
        // Every signal blocked until the exec, which resets the handlers:
        // the child shares h9's memory, so one of h9's handlers running
        // there (Ctrl-C's, before setsid takes it out of the terminal's
        // process group) would count the signal twice. The stub sets its
        // own mask.
        const all: linux.sigset_t = linux.sigfillset();
        var old: linux.sigset_t = undefined;
        _ = linux.sigprocmask(linux.SIG.SETMASK, &all, &old);
        const rc = linux.clone(spawnChild, @intFromPtr(&stack) + stack.len, linux.CLONE.VM | linux.CLONE.VFORK | SIGCHLD, @intFromPtr(&args), null, 0, null);
        _ = linux.sigprocmask(linux.SIG.SETMASK, &old, null);
        if (failed(rc)) {
            std.posix.munmap(map);
            return error.HypervisorFailed;
        }
        // From here `stop` frees the control pages.
        var s: Stub = .{ .pid = @intCast(rc), .ctls = ctls };
        s.wait(0) catch {
            s.stop();
            // It never got as far as its control loop: the kernel refused
            // it something (dispatch, the filter, the exec).
            return error.HypervisorUnavailable;
        };
        if (ctls[0].why != .ready) {
            s.stop();
            return error.HypervisorFailed;
        }
        return s;
    }

    fn stop(s: *Stub) void {
        _ = linux.kill(s.pid, .KILL);
        var info: [128]u8 = undefined;
        const __WALL = 0x4000_0000;
        while (true) {
            const rc = linux.syscall5(.waitid, @intFromEnum(linux.P.PID), @intCast(s.pid), @intFromPtr(&info), linux.W.EXITED | __WALL, 0);
            if (linux.errno(rc) != .INTR) break;
        }
        // Its threads that were awake count in `busy` no longer. A thread
        // killed between its flag and the count (setAwake in
        // sud_stub.zig) is taken out though the count never had it, so
        // `busy` would drop one below the truth for good. It can't go
        // below zero, so that much of the error is clamped away: with no
        // other thread spinning, as when the last stub stops, the count
        // comes out exact.
        if (sched) |sh| for (s.ctls) |*c| {
            if (@atomicLoad(u32, &c.awake, .seq_cst) != 0) unspinClamped(sh);
        };
        std.posix.munmap(@as([*]align(std.heap.page_size_min) u8, @ptrCast(@alignCast(s.ctls)))[0..abi.ctls_size]);
    }

    /// Whether the stub process has ended (killed by its filter, say).
    fn dead(s: *Stub) bool {
        var info: [128]u8 = @splat(0);
        const __WALL = 0x4000_0000;
        const rc = linux.syscall5(.waitid, @intFromEnum(linux.P.PID), @intCast(s.pid), @intFromPtr(&info), linux.W.EXITED | linux.W.NOHANG | linux.W.NOWAIT | __WALL, 0);
        if (failed(rc)) return true;
        // si_pid, set only when the child has exited.
        return std.mem.readInt(i32, info[16..20], .little) != 0;
    }

    /// Hands thread `k` `state` (run or ops).
    fn go(s: *Stub, k: usize, state: abi.State) void {
        const ctl = &s.ctls[k];
        @atomicStore(u32, &ctl.state, @intFromEnum(state), .seq_cst);
        if (@atomicLoad(u32, &ctl.stub_waiting, .seq_cst) != 0)
            _ = linux.futex_3arg(&ctl.state, .{ .cmd = .WAKE, .private = false }, 1);
    }

    /// Waits for thread `k` to stop and report. Fails if the stub died.
    fn wait(s: *Stub, k: usize) engine.Error!void {
        const ctl = &s.ctls[k];
        const exited = @intFromEnum(abi.State.exited);
        if (@atomicLoad(u32, &ctl.state, .seq_cst) == exited) return;
        // Spin only while the stub's thread, this one, and the others
        // awake for guests leave a CPU free (`abi.Sched`).
        if (sched) |sh| if (trySpin(sh)) {
            defer unspin(sh);
            var i: usize = 0;
            while (i < spin_rounds and maySpin(sh)) : (i += 1) {
                if (@atomicLoad(u32, &ctl.state, .seq_cst) == exited) return;
                std.atomic.spinLoopHint();
            }
        };
        const ts: linux.timespec = .{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
        while (true) {
            @atomicStore(u32, &ctl.host_waiting, 1, .seq_cst);
            const cur = @atomicLoad(u32, &ctl.state, .seq_cst);
            if (cur == exited) break;
            const rc = linux.futex_4arg(&ctl.state, .{ .cmd = .WAIT, .private = false }, cur, &ts);
            if (linux.errno(rc) == .TIMEDOUT and s.dead()) {
                @atomicStore(u32, &ctl.host_waiting, 0, .seq_cst);
                return error.HypervisorFailed;
            }
        }
        @atomicStore(u32, &ctl.host_waiting, 0, .seq_cst);
    }
};

/// A lock held across round trips to the stub (microseconds) or its
/// start (an exec): spins briefly, then yields.
fn lockSlow(l: *std.atomic.Mutex) void {
    var i: usize = 0;
    while (!l.tryLock()) : (i += 1) {
        if (i < 1000) std.atomic.spinLoopHint() else _ = linux.sched_yield();
    }
}

pub const AddressSpace = struct {
    engine: *Engine,
    /// Guards `regions`, `ops` and `threads` against other threads.
    lock: std.atomic.Mutex = .unlocked,
    regions: std.ArrayList(Region) = .empty,
    /// Requests the stub hasn't carried out yet.
    ops: std.ArrayList(abi.Op) = .empty,
    /// Counts the requests ever queued, so `run` can tell whether the
    /// mappings changed while the guest ran.
    gen: u64 = 0,
    /// Requests taken off `ops` that a stub thread is carrying out now.
    /// They aren't in `ops`, but aren't done either.
    inflight: usize = 0,
    /// Held while starting the stub, and while a stub thread carries out
    /// requests, so they're carried out in order.
    ctl_lock: std.atomic.Mutex = .unlocked,
    /// Started on the first run; set once, under `ctl_lock`.
    stub: ?Stub = null,
    /// The stub's threads, by control page: 0 is the control thread, and
    /// [1, nthreads) have been started.
    threads: [abi.max_threads]Thread = @splat(.{}),
    nthreads: u32 = 1,

    const Region = struct { va: u64, mem: []align(engine.page_size) u8 };

    /// A stub thread: who ran it last, so a vCPU goes back to the same
    /// one and keeps the FP state `Extra` doesn't carry (AVX's upper
    /// halves), and whether it's running now.
    const Thread = struct {
        owner: ?*const State = null,
        busy: bool = false,
        /// Started and ready; false while starting, and for good if
        /// starting it failed.
        ready: bool = false,
    };

    fn lockSpin(as: *AddressSpace) void {
        while (!as.lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn prot(p: engine.Perms) u32 {
        var r: u32 = 0;
        if (p.read) r |= 1;
        if (p.write) r |= 2;
        if (p.exec) r |= 4;
        return r;
    }

    pub fn map(as: *AddressSpace, va: u64, mem: []align(engine.page_size) u8, perms: engine.Perms) engine.CreateError!void {
        if (va % engine.page_size != 0 or mem.len % engine.page_size != 0 or mem.len == 0) return error.BadAddress;
        if (va == 0 or va >= abi.user_top or mem.len > abi.user_top - va) return error.BadAddress;
        // The stub's own range.
        if (va < abi.stub_end and abi.stub_base < va + mem.len) return error.BadAddress;
        const ram = &as.engine.ram;
        const off = @intFromPtr(mem.ptr) -% @intFromPtr(ram.mem.ptr);
        if (off >= ram.mem.len or mem.len > ram.mem.len - off) return error.BadAddress;
        as.lockSpin();
        defer as.lock.unlock();
        for (as.regions.items) |r| {
            if (va < r.va + r.mem.len and r.va < va + mem.len) return error.BadAddress;
        }
        const gpa = as.engine.gpa;
        try as.regions.ensureUnusedCapacity(gpa, 1);
        try as.ops.append(gpa, .{ .va = va, .len = mem.len, .off = off, .prot = prot(perms), .kind = .map });
        as.regions.appendAssumeCapacity(.{ .va = va, .mem = mem });
        as.gen +%= 1;
    }

    pub fn unmap(as: *AddressSpace, va: u64) void {
        as.lockSpin();
        defer as.lock.unlock();
        for (as.regions.items, 0..) |r, i| if (r.va == va) {
            // On allocation failure the stub keeps the pages mapped until
            // it's gone, which only matters if they're reused; better
            // than leaving them reachable, so the region stays too.
            as.ops.append(as.engine.gpa, .{ .va = va, .len = r.mem.len, .off = 0, .prot = 0, .kind = .unmap }) catch return;
            _ = as.regions.swapRemove(i);
            as.gen +%= 1;
            return;
        };
    }

    pub fn translate(as: *AddressSpace, va: u64, len: u64) ?[]u8 {
        as.lockSpin();
        defer as.lock.unlock();
        return as.find(va, len);
    }

    fn find(as: *AddressSpace, va: u64, len: u64) ?[]u8 {
        for (as.regions.items) |r| {
            if (va >= r.va and va - r.va <= r.mem.len and len <= r.mem.len - (va - r.va)) {
                return r.mem[va - r.va ..][0..len];
            }
        }
        return null;
    }

    pub fn copy(as: *AddressSpace, va: u64, buf: []u8, write: bool) bool {
        as.lockSpin();
        defer as.lock.unlock();
        const mem = as.find(va, buf.len) orelse return false;
        if (write) @memcpy(mem, buf) else @memcpy(buf, mem);
        return true;
    }

    /// x86 keeps instruction fetches coherent with stores, and the stub
    /// maps the same pages h9 wrote, so there's nothing to drop.
    pub fn codeChanged(_: *AddressSpace, _: u64, _: u64) void {}

    /// Has the control thread carry out the queued requests now. Its
    /// munmap is the host kernel's, which shoots down the other stub
    /// threads' TLBs before it returns, so nothing more is needed for
    /// guest threads running meanwhile.
    pub fn shootdown(as: *AddressSpace) void {
        lockSlow(&as.ctl_lock);
        defer as.ctl_lock.unlock();
        // No stub, no mappings: the first run carries them all out.
        if (as.stub) |*s| as.flushOps(s, 0) catch {};
    }

    pub fn destroy(as: *AddressSpace) void {
        if (as.stub) |*s| s.stop();
        const gpa = as.engine.gpa;
        as.regions.deinit(gpa);
        as.ops.deinit(gpa);
        gpa.destroy(as);
    }

    fn startStub(as: *AddressSpace) engine.Error!*Stub {
        lockSlow(&as.ctl_lock);
        defer as.ctl_lock.unlock();
        if (as.stub == null) as.stub = try Stub.start(as.engine);
        return &as.stub.?;
    }

    /// Has thread `k` carry out the queued requests, in as many rounds as
    /// its control page needs. Called with `ctl_lock` held and the thread
    /// stopped.
    fn flushOps(as: *AddressSpace, s: *Stub, k: usize) engine.Error!void {
        const ctl = &s.ctls[k];
        while (true) {
            as.lockSpin();
            const n = @min(as.ops.items.len, abi.max_ops);
            @memcpy(ctl.ops[0..n], as.ops.items[0..n]);
            ctl.nops = @intCast(n);
            as.ops.replaceRangeAssumeCapacity(0, n, &.{});
            as.inflight += n;
            as.lock.unlock();
            if (n == 0) return;
            defer {
                as.lockSpin();
                as.inflight -= n;
                as.lock.unlock();
            }
            s.go(k, .ops);
            try s.wait(k);
        }
    }

    /// Whether requests are queued, or being carried out on another
    /// thread, so that guest code mustn't run until they're done.
    fn opsPending(as: *AddressSpace) bool {
        as.lockSpin();
        defer as.lock.unlock();
        return as.ops.items.len != 0 or as.inflight != 0;
    }

    fn genNow(as: *AddressSpace) u64 {
        as.lockSpin();
        defer as.lock.unlock();
        return as.gen;
    }

    /// The stub thread for vCPU `v` to run on: the one it ran last if
    /// that's free, else an unowned one, a new one, or any free one, in
    /// that order.
    fn takeThread(as: *AddressSpace, s: *Stub, v: *State) engine.Error!usize {
        as.lockSpin();
        const k = pick: {
            const last = v.thread;
            if (last > 0 and last < as.nthreads) {
                const t = &as.threads[last];
                if (t.owner == v and t.ready and !t.busy) break :pick last;
            }
            for (as.threads[1..as.nthreads], 1..) |t, i| {
                if (t.owner == null and t.ready) break :pick i;
            }
            if (as.nthreads < abi.max_threads) {
                const i = as.nthreads;
                as.nthreads += 1;
                as.threads[i] = .{ .owner = v, .busy = true };
                as.lock.unlock();
                try as.startThread(s, i);
                as.lockSpin();
                as.threads[i].ready = true;
                as.lock.unlock();
                v.thread = i;
                return i;
            }
            for (as.threads[1..as.nthreads], 1..) |t, i| {
                if (t.ready and !t.busy) break :pick i;
            }
            as.lock.unlock();
            return error.HypervisorFailed;
        };
        as.threads[k].owner = v;
        as.threads[k].busy = true;
        as.lock.unlock();
        v.thread = k;
        return k;
    }

    fn putThread(as: *AddressSpace, k: usize) void {
        as.lockSpin();
        defer as.lock.unlock();
        as.threads[k].busy = false;
    }

    /// Has the control thread start thread `k`, and waits until it's
    /// ready. On failure the slot stays busy, and unused.
    fn startThread(as: *AddressSpace, s: *Stub, k: usize) engine.Error!void {
        const ctl0 = &s.ctls[0];
        @atomicStore(u32, &s.ctls[k].state, @intFromEnum(abi.State.guest), .release);
        {
            lockSlow(&as.ctl_lock);
            defer as.ctl_lock.unlock();
            ctl0.ops[0] = .{ .va = k, .len = 0, .off = 0, .prot = 0, .kind = .thread };
            ctl0.nops = 1;
            s.go(0, .ops);
            try s.wait(0);
            if (failed(ctl0.err)) return error.HypervisorFailed;
        }
        try s.wait(k);
        if (s.ctls[k].why != .ready) return error.HypervisorFailed;
    }
};

const State = struct {
    engine: *Engine,
    as: ?*AddressSpace = null,
    ureg: amd64.Ureg = .{},
    extra: engine.X86Extra = .init,
    /// The stub thread it last ran on, in whichever space; 0 for none.
    thread: usize = 0,
    /// Guards `kicked` and `running` between `run` and `kick`.
    lock: std.atomic.Mutex = .unlocked,
    kicked: bool = false,
    /// The stub thread running guest code for this vCPU, for `kick`.
    running: ?Running = null,

    const Running = struct { pid: i32, tid: i32, ctl: *abi.Ctl };

    fn lockSpin(s: *State) void {
        while (!s.lock.tryLock()) std.atomic.spinLoopHint();
    }
};

pub const Vcpu = struct {
    s: *State,

    pub fn destroy(v: *Vcpu) void {
        v.s.engine.gpa.destroy(v.s);
    }

    pub fn setAddressSpace(v: *Vcpu, as: *AddressSpace) engine.Error!void {
        v.s.as = as;
    }

    pub fn getUreg(v: *Vcpu, u: *engine.Ureg) void {
        u.* = .{ .amd64 = v.s.ureg };
    }

    pub fn setUreg(v: *Vcpu, u: *const engine.Ureg) void {
        v.s.ureg = u.amd64;
    }

    pub fn getExtra(v: *Vcpu, x: *engine.Extra) engine.Error!void {
        x.* = .{ .amd64 = v.s.extra };
    }

    pub fn setExtra(v: *Vcpu, x: *const engine.Extra) engine.Error!void {
        v.s.extra = x.amd64;
    }

    /// Safe from any thread. A kick before `run` makes the next run return
    /// `.interrupted` at once.
    pub fn kick(v: *Vcpu) void {
        const s = v.s;
        s.lockSpin();
        defer s.lock.unlock();
        s.kicked = true;
        if (s.running) |r| {
            @atomicStore(u32, &r.ctl.kick, 1, .seq_cst);
            _ = linux.tgkill(r.pid, r.tid, @enumFromInt(SIGURG));
        }
    }

    pub fn run(v: *Vcpu) engine.Error!engine.Exit {
        const s = v.s;
        const as = s.as orelse return error.BadAddress;
        const stub = try as.startStub();
        const k = try as.takeThread(stub, s);
        defer as.putThread(k);
        const ctl = &stub.ctls[k];
        while (true) {
            // The requests queued by now are carried out before the guest
            // runs (below).
            const gen = as.genNow();
            const exit = try v.runOnce(as, stub, k, ctl);
            if (exit != .fault or as.genNow() == gen) return exit;
            // A fault while another thread changed the mappings may be on
            // a page the stub hadn't mapped yet: an RFMEM process (a
            // libthread proc) touching heap that another one's brk just
            // grew, while this one stayed in user mode, so its stub never
            // stopped to carry out the request. `runOnce` has read back
            // the registers as at the fault, so run it again, with the
            // requests carried out; a real fault faults again with no new
            // requests in between.
        }
    }

    fn runOnce(v: *Vcpu, as: *AddressSpace, stub: *Stub, k: usize, ctl: *abi.Ctl) engine.Error!engine.Exit {
        const s = v.s;
        // Another vCPU's flush may have taken this one's requests (a page
        // its last fault mapped) off the queue without carrying them out
        // yet. Waiting on `ctl_lock` waits for that flush, so the guest
        // doesn't run against the stub's old mappings and fault again on
        // a page h9 has already mapped, which is SIGSEGV.
        if (as.opsPending()) {
            lockSlow(&as.ctl_lock);
            defer as.ctl_lock.unlock();
            try as.flushOps(stub, k);
        }
        writeRegs(ctl, &s.ureg, &s.extra);
        {
            s.lockSpin();
            defer s.lock.unlock();
            if (s.kicked) {
                s.kicked = false;
                return .interrupted;
            }
            @atomicStore(u32, &ctl.kick, 0, .seq_cst);
            s.running = .{ .pid = stub.pid, .tid = @intCast(ctl.tid), .ctl = ctl };
        }
        stub.go(k, .run);
        const result = stub.wait(k);
        {
            s.lockSpin();
            defer s.lock.unlock();
            s.running = null;
            if (result) |_| {
                if (ctl.why == .interrupted) s.kicked = false;
            } else |_| {}
        }
        try result;
        readRegs(ctl, &s.ureg, &s.extra);
        return decode(ctl, &s.ureg);
    }
};

fn writeRegs(ctl: *abi.Ctl, u: *const amd64.Ureg, x: *const engine.X86Extra) void {
    const r = &ctl.regs;
    inline for (.{ "ax", "bx", "cx", "dx", "si", "di", "bp", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15", "pc", "sp", "flags" }) |f| {
        @field(r, f) = @field(u, f);
    }
    @memcpy(&ctl.fx, std.mem.asBytes(&x.fx)[0..abi.fx_len]);
    ctl.fs_base = x.tls;
    ctl.gs_base = x.gs;
}

fn readRegs(ctl: *const abi.Ctl, u: *amd64.Ureg, x: *engine.X86Extra) void {
    const r = &ctl.regs;
    inline for (.{ "ax", "bx", "cx", "dx", "si", "di", "bp", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15", "pc", "sp", "flags" }) |f| {
        @field(u, f) = @field(r, f);
    }
    const fx = &x.fx;
    @memcpy(std.mem.asBytes(fx)[0..abi.fx_len], &ctl.fx);
    // A component in its initial state may not be written out.
    const bv = ctl.xstate_bv;
    if (bv & 1 == 0) {
        const mxcsr = fx.mxcsr;
        const xmm = fx.xmm;
        fx.* = engine.X86Extra.init.fx;
        fx.mxcsr = mxcsr;
        fx.xmm = xmm;
    }
    if (bv & 2 == 0) fx.xmm = @splat(0);
    fx.mxcsr_mask = 0xffff;
    fx._r2 = @splat(0);
    x.tls = ctl.fs_base;
    x.gs = ctl.gs_base;
}

fn decode(ctl: *const abi.Ctl, u: *amd64.Ureg) engine.Exit {
    switch (ctl.why) {
        .syscall => {
            u.type = vector_syscall;
            return .syscall;
        },
        .interrupted => return .interrupted,
        .trap => {},
        else => return .{ .other = @intFromEnum(ctl.why) },
    }
    u.type = ctl.trapno;
    u.@"error" = ctl.err;
    if (ctl.signo == SIGSEGV and ctl.trapno == vector_pf) {
        const e = ctl.err;
        return .{ .fault = .{
            .addr = ctl.addr,
            .access = if (e & 0x10 != 0) .exec else if (e & 2 != 0) .write else .read,
            .syndrome = e,
        } };
    }
    if (ctl.signo == SIGBUS) return .{ .fault = .{ .addr = ctl.addr, .access = .read, .syndrome = ctl.trapno } };
    if (ctl.trapno == vector_bp) return .breakpoint;
    return .{ .fault = .{ .addr = u.pc, .access = .exec, .syndrome = ctl.trapno } };
}
