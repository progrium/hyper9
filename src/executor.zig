//! A machine's executors (design/scheduler.md): host threads, one per
//! core, each with one vCPU for its life, that run the machine's
//! processes. A process is a task, a kernel continuation
//! (src/kern/sched/), not a host thread: it runs on an executor until it
//! blocks in the kernel or its time slice ends, then parks or yields, and
//! the executor takes the next runnable task. When an unpark makes it
//! runnable, any executor can resume it.
//!
//! - **Run queues.** Each executor has one, and a task an unpark makes
//!   runnable goes back on the queue of the executor that last ran it
//!   (whose vCPU still holds its address space and registers). An idle
//!   executor takes from the machine's queue, where new and yielded tasks
//!   go, and steals from the others'.
//! - **The vCPU.** A process's registers, FP/SIMD state, and address space
//!   are its lease's (cpupool.Lease, scheduled), and are loaded into the
//!   executor's vCPU when it runs there and another ran since. As a task
//!   parks or yields, before it switches out, the FP/SIMD state is saved
//!   back to its lease (`outHook`), so whichever executor resumes it
//!   loads what it left.
//! - **Slices.** A process runs for `slice_ns` while others wait. The
//!   monitor thread kicks a vCPU that has run guest code longer than that
//!   with work queued, and the run's exit, `interrupted`, yields at the
//!   next run (`Lease.run`). Guest code that makes no kernel calls can't
//!   keep the others out.
//! - **Host calls that block.** An executor that stays in the kernel for
//!   `block_ns` without parking is in a host call that blocks (a host
//!   file or socket read in a C device, say). The monitor hands its queue
//!   to the machine's and starts an executor in its place, and the old
//!   one ends once its call returns and its task leaves it: the machine
//!   keeps N executors that can run, and none waits on another's blocked
//!   host call. These are the helper threads of step 5, started only as
//!   they're needed.
//!
//! Processes that wait in the host on purpose (the pty and 9P servers'
//! helpers) keep host threads of their own (kern.RF.HOSTTHREAD).

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine.zig");
const kern = @import("kern.zig");
const web = @import("web.zig");
const cpupool = @import("cpupool.zig");
const cputime = @import("abi/linux/cputime.zig");

/// How long a process runs while others wait.
pub const slice_ns: i64 = 10 * std.time.ns_per_ms;
/// How long an executor may stay in one kernel call, without parking,
/// before the monitor takes it for blocked in the host.
pub const block_ns: i64 = 20 * std.time.ns_per_ms;
/// How often the monitor looks.
const tick_ns: i64 = 2 * std.time.ns_per_ms;

/// Whether this build has executors: not the web host until step 6
/// (design/scheduler.md), nor a build without the kernel.
pub const enabled = kern.available and !web.enabled;

/// Whether a machine on this engine runs its processes on executors.
/// The rest give each process a host thread and a vCPU (src/cpupool.zig).
pub fn usable(kind: engine.Kind) bool {
    if (comptime !enabled) return false;
    return switch (kind) {
        .hcpu, .sud, .hvf, .kvm, .whp => true,
    };
}

/// Whether a process on `kind`'s executors keeps a vCPU of its own, which
/// whichever executor it's on runs: on sud a vCPU is only a view of a
/// thread in its address space's stub process, which keeps FP state
/// beyond what `Extra` carries (AVX's upper halves), so it's the
/// process's. Elsewhere the executor's one vCPU takes each process's
/// state in turn.
pub fn ownsVcpu(kind: engine.Kind) bool {
    return kind == .sud;
}

// The kernel's side (src/kern/sched/kern.zig).
const c = struct {
    const Ready = *const fn (ctx: ?*anyopaque) callconv(.c) void;
    const Hook = *const fn (exctx: ?*anyopaque, taskctx: ?*anyopaque) callconv(.c) void;
    extern fn h9_sched_pool_new(size: usize) ?*anyopaque;
    extern fn h9_sched_pool_free(p: *anyopaque) void;
    extern fn h9_sched_pool_mapped(p: *anyopaque) usize;
    extern fn h9_sched_task_new(proc: *anyopaque, ready: Ready, ctx: ?*anyopaque) ?*anyopaque;
    extern fn h9_sched_task_free(t: *anyopaque) void;
    extern fn h9_sched_exec_new(pool: *anyopaque, ctx: ?*anyopaque, hook: ?Hook) ?*anyopaque;
    extern fn h9_sched_exec_free(e: *anyopaque) void;
    extern fn h9_sched_exec_start(e: *anyopaque, t: *anyopaque) c_int;
    extern fn h9_sched_exec_resume(e: *anyopaque, t: *anyopaque) c_int;
    extern fn h9_sched_exec_current() ?*anyopaque;
    extern fn h9_sched_task_current() ?*anyopaque;
    extern fn h9_sched_yield() void;
    extern fn h9_sched_park() void;
    extern fn h9_sched_unpark(t: *anyopaque) void;
    extern fn h9_kern_locals(save: c_int, slots: *[4]usize) void;
};

/// A one-shot event that a task waits for by parking, and anything else
/// on a host futex: std.Io.Event's, for the waits in the run loop (a
/// vfork parent's, an execve handed to a thread's leader) that would
/// otherwise hold an executor's host thread.
pub const Event = if (enabled) ParkEvent else IoEvent;

/// std.Io.Event, where there are no executors.
const IoEvent = struct {
    ev: std.Io.Event = .unset,

    pub fn set(e: *IoEvent, io: std.Io) void {
        e.ev.set(io);
    }

    pub fn isSet(e: *const IoEvent) bool {
        return e.ev.isSet();
    }

    pub fn wait(e: *IoEvent, io: std.Io) void {
        e.ev.waitUncancelable(io);
    }
};

const ParkEvent = struct {
    state: std.atomic.Value(u32) = .init(0),
    waiter: std.atomic.Value(?*Task) = .init(null),

    pub fn set(ev: *ParkEvent, io: std.Io) void {
        ev.state.store(1, .seq_cst);
        io.futexWake(u32, &ev.state.raw, std.math.maxInt(u32));
        if (ev.waiter.swap(null, .seq_cst)) |t| c.h9_sched_unpark(t.kt);
    }

    pub fn isSet(ev: *const ParkEvent) bool {
        return ev.state.load(.acquire) != 0;
    }

    pub fn wait(ev: *ParkEvent, io: std.Io) void {
        if (currentTask()) |t| {
            while (ev.state.load(.seq_cst) == 0) {
                ev.waiter.store(t, .seq_cst);
                if (ev.state.load(.seq_cst) != 0) {
                    // Set meanwhile. If set took the waiter, its unpark is
                    // on the way: take it, so no later park sees it.
                    if (ev.waiter.cmpxchgStrong(t, null, .seq_cst, .seq_cst) != null) c.h9_sched_park();
                    return;
                }
                c.h9_sched_park();
            }
            return;
        }
        while (ev.state.load(.acquire) == 0) io.futexWaitUncancelable(u32, &ev.state.raw, 0);
    }
};

/// A queue of tasks, intrusive on `Task.next`.
const Queue = struct {
    lock: std.atomic.Mutex = .unlocked,
    head: ?*Task = null,
    tail: ?*Task = null,
    len: std.atomic.Value(u32) = .init(0),

    fn acquire(q: *Queue) void {
        while (!q.lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn push(q: *Queue, t: *Task) void {
        t.next = null;
        q.acquire();
        if (q.tail) |l| l.next = t else q.head = t;
        q.tail = t;
        _ = q.len.fetchAdd(1, .release);
        q.lock.unlock();
    }

    fn pop(q: *Queue) ?*Task {
        if (q.len.load(.acquire) == 0) return null;
        q.acquire();
        defer q.lock.unlock();
        const t = q.head orelse return null;
        q.head = t.next;
        if (q.head == null) q.tail = null;
        t.next = null;
        _ = q.len.fetchSub(1, .release);
        return t;
    }

    fn isEmpty(q: *const Queue) bool {
        return q.len.load(.acquire) == 0;
    }
};

/// A process the executors run.
const Task = struct {
    s: *Sched,
    kt: *anyopaque,
    next: ?*Task = null,
    /// The executor that last ran it, whose queue an unpark puts it on.
    last: ?*Exec = null,
    started: bool = false,
    /// Its lease, once it has run guest code.
    lease: ?*cpupool.Lease = null,
    /// Host CPU time it has used, and the host thread's reading when it
    /// last went on an executor.
    cpu: cputime.Times = .{},
    mark: cputime.Times = .{},
    /// The kernel's threadlocals (the plan, pages, and CPUs that devfs
    /// and #c go by) as it left them, set again when it's switched in,
    /// since a process changes them for a while (h9's own dials go
    /// without a plan) and can park meanwhile.
    locals: [4]usize = @splat(0),

    fn readyC(ctx: ?*anyopaque) callconv(.c) void {
        const t: *Task = @ptrCast(@alignCast(ctx.?));
        t.s.enqueue(t);
    }
};

const State = enum(u8) { idle, kernel, guest };

pub const Exec = struct {
    s: *Sched,
    kx: *anyopaque,
    /// Its vCPU, unless processes keep their own (`Sched.own`).
    vcpu: engine.Vcpu = undefined,
    /// Whether `vcpu` is made yet: on the executor's first guest run, so
    /// an executor that never runs guest code costs no vCPU (on HVF, a
    /// vCPU's kernel pages come out of the machine's memory cap).
    has_vcpu: bool = false,
    /// The vCPU running guest code, for the monitor's kick; under
    /// `run_lock`.
    running: ?*engine.Vcpu = null,
    run_lock: std.atomic.Mutex = .unlocked,
    q: Queue = .{},
    thread: std.Thread = undefined,
    /// The lease whose state the vCPU holds, if it's still there.
    owner: std.atomic.Value(?*cpupool.Lease) = .init(null),
    state: std.atomic.Value(State) = .init(.idle),
    /// When `state` last changed, in the machine's monotonic ns.
    since: std.atomic.Value(i64) = .init(0),
    /// When the running task went on it.
    slice_start: i64 = 0,
    /// Replaced by the monitor: it ends once its task leaves it.
    retiring: std.atomic.Value(bool) = .init(false),
    /// 1 once its vCPU is made, 2 if it couldn't be.
    up: std.atomic.Value(u32) = .init(0),
    cur: ?*Task = null,

    fn lockRun(e: *Exec) void {
        while (!e.run_lock.tryLock()) std.atomic.spinLoopHint();
    }

    /// Ends the guest code running on it, if any, with `interrupted`.
    fn kick(e: *Exec) void {
        e.lockRun();
        defer e.run_lock.unlock();
        if (e.running) |v| v.kick();
    }

    /// Runs v, which is its own or the running process's, to its next
    /// exit.
    fn runGuest(e: *Exec, v: *engine.Vcpu) engine.Error!engine.Exit {
        e.lockRun();
        e.running = v;
        e.run_lock.unlock();
        e.setState(.guest);
        defer {
            e.setState(.kernel);
            e.lockRun();
            e.running = null;
            e.run_lock.unlock();
        }
        return v.run();
    }

    fn setState(e: *Exec, st: State) void {
        e.since.store(now(), .release);
        e.state.store(st, .release);
    }

    /// Whether the running task's slice is up and another waits.
    fn shouldYield(e: *Exec) bool {
        return now() - e.slice_start >= slice_ns and e.s.hasWork(e);
    }

    fn main(e: *Exec) void {
        const s = e.s;
        if (s.thread_init) |f| f(s.init_ctx);
        e.up.store(1, .release);
        s.io.futexWake(u32, &e.up.raw, 1);
        while (true) {
            if (e.retiring.load(.acquire)) break;
            const seq = s.seq.load(.acquire);
            const t = e.q.pop() orelse s.global.pop() orelse s.steal(e) orelse {
                if (s.stopping.load(.acquire) and s.tasks.load(.acquire) == 0) break;
                _ = s.nidle.fetchAdd(1, .acq_rel);
                s.io.futexWaitTimeout(u32, &s.seq.raw, seq, .{ .duration = .{ .raw = .fromMilliseconds(10), .clock = .awake } }) catch {};
                _ = s.nidle.fetchSub(1, .acq_rel);
                continue;
            };
            e.runTask(t);
        }
        // What's queued here goes to the machine's queue.
        while (e.q.pop()) |t| s.global.push(t);
        s.wake();
        e.owner.store(null, .release);
        if (e.has_vcpu) e.vcpu.destroy();
        s.execEnded(e);
    }

    fn runTask(e: *Exec, t: *Task) void {
        const s = e.s;
        e.cur = t;
        t.last = e;
        e.slice_start = now();
        e.setState(.kernel);
        t.mark = cputime.hostThread();
        c.h9_kern_locals(0, &t.locals);
        const rc = if (!t.started) blk: {
            t.started = true;
            break :blk c.h9_sched_exec_start(e.kx, t.kt);
        } else c.h9_sched_exec_resume(e.kx, t.kt);
        e.setState(.idle);
        e.cur = null;
        switch (rc) {
            0 => {
                // The process exited.
                c.h9_sched_task_free(t.kt);
                s.gpa.destroy(t);
                if (s.tasks.fetchSub(1, .acq_rel) == 1) s.wakeAll();
            },
            1 => {},
            2 => {
                s.global.push(t);
                s.wake();
            },
            else => {
                // No kernel stack for it: try again in a while.
                t.started = false;
                s.io.sleep(.fromMilliseconds(1), .awake) catch {};
                s.global.push(t);
                s.wake();
            },
        }
    }

    /// On the task, as it parks or yields: its FP/SIMD state goes back to
    /// its lease, for whichever executor resumes it.
    fn outHook(exctx: ?*anyopaque, taskctx: ?*anyopaque) callconv(.c) void {
        const e: *Exec = @ptrCast(@alignCast(exctx.?));
        const t: *Task = @ptrCast(@alignCast(taskctx.?));
        t.cpu = t.cpu.add(cputime.hostThread().since(t.mark));
        c.h9_kern_locals(1, &t.locals);
        const l = t.lease orelse return;
        if (e.owner.load(.acquire) != l or l.home != @as(?*anyopaque, e)) return;
        if (!l.extra_dirty and e.has_vcpu) e.vcpu.getExtra(&l.extra) catch {};
    }
};

fn now() i64 {
    return kern.monoNs();
}

/// A machine's executors and what they share.
pub const Sched = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    eng: engine.Engine,
    /// How many executors run at once, the retiring aside.
    n: u32,
    /// Processes keep vCPUs of their own (ownsVcpu).
    own: bool,
    pool: *anyopaque,
    /// Sets up the host thread for the machine (its kernel threadlocals).
    thread_init: ?*const fn (ctx: ?*anyopaque) void,
    init_ctx: ?*anyopaque,

    lock: std.atomic.Mutex = .unlocked,
    /// Executors running, under `lock`.
    execs: std.ArrayList(*Exec) = .empty,
    /// Every executor made, to join and free at the end; under `lock`.
    all: std.ArrayList(*Exec) = .empty,
    /// New, yielded, and orphaned tasks.
    global: Queue = .{},
    /// Bumped when a task is queued, for idle executors to wait on.
    seq: std.atomic.Value(u32) = .init(0),
    nidle: std.atomic.Value(u32) = .init(0),
    /// Tasks not yet exited.
    tasks: std.atomic.Value(u32) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),
    monitor: ?std.Thread = null,
    /// Executors started in place of blocked ones, for the cases.
    handoffs: std.atomic.Value(u32) = .init(0),

    pub const Options = struct {
        thread_init: ?*const fn (ctx: ?*anyopaque) void = null,
        init_ctx: ?*anyopaque = null,
    };

    /// N executors on `eng`, each with a vCPU of its own.
    pub fn create(gpa: std.mem.Allocator, io: std.Io, eng: engine.Engine, n: u32, opts: Options) !*Sched {
        const pool = c.h9_sched_pool_new(0) orelse return error.OutOfMemory;
        const s = gpa.create(Sched) catch {
            c.h9_sched_pool_free(pool);
            return error.OutOfMemory;
        };
        s.* = .{ .gpa = gpa, .io = io, .eng = eng, .n = @max(n, 1), .own = ownsVcpu(eng.kind()), .pool = pool, .thread_init = opts.thread_init, .init_ctx = opts.init_ctx };
        cputime.task_hook = taskCpu;
        var i: u32 = 0;
        while (i < s.n) : (i += 1) {
            const e = s.spawnExec() catch |err| {
                s.stop();
                return err;
            };
            while (e.up.load(.acquire) == 0) io.futexWaitUncancelable(u32, &e.up.raw, 0);
            if (e.up.load(.acquire) == 2) {
                s.stop();
                return error.HypervisorFailed;
            }
        }
        s.monitor = std.Thread.spawn(.{}, monitorMain, .{s}) catch {
            s.stop();
            return error.OutOfMemory;
        };
        return s;
    }

    fn spawnExec(s: *Sched) !*Exec {
        const e = try s.gpa.create(Exec);
        e.* = .{ .s = s, .kx = undefined };
        e.kx = c.h9_sched_exec_new(s.pool, e, Exec.outHook) orelse {
            s.gpa.destroy(e);
            return error.OutOfMemory;
        };
        s.acquire();
        defer s.lock.unlock();
        s.all.append(s.gpa, e) catch {
            c.h9_sched_exec_free(e.kx);
            s.gpa.destroy(e);
            return error.OutOfMemory;
        };
        s.execs.append(s.gpa, e) catch {
            _ = s.all.pop();
            c.h9_sched_exec_free(e.kx);
            s.gpa.destroy(e);
            return error.OutOfMemory;
        };
        e.thread = std.Thread.spawn(.{}, Exec.main, .{e}) catch {
            _ = s.all.pop();
            _ = s.execs.pop();
            c.h9_sched_exec_free(e.kx);
            s.gpa.destroy(e);
            return error.OutOfMemory;
        };
        return e;
    }

    fn execEnded(s: *Sched, e: *Exec) void {
        s.acquire();
        defer s.lock.unlock();
        for (s.execs.items, 0..) |x, i| if (x == e) {
            _ = s.execs.swapRemove(i);
            break;
        };
    }

    fn acquire(s: *Sched) void {
        while (!s.lock.tryLock()) std.atomic.spinLoopHint();
    }

    /// The kernel's hook (Kernel.setScheduler): takes a new process.
    pub fn startC(ctx: ?*anyopaque, proc: ?*anyopaque) callconv(.c) c_int {
        const s: *Sched = @ptrCast(@alignCast(ctx.?));
        if (s.stopping.load(.acquire)) return -1;
        const t = s.gpa.create(Task) catch return -1;
        t.* = .{ .s = s, .kt = undefined };
        // It starts with its starter's, until its first call sets them.
        c.h9_kern_locals(1, &t.locals);
        t.kt = c.h9_sched_task_new(proc.?, Task.readyC, t) orelse {
            s.gpa.destroy(t);
            return -1;
        };
        _ = s.tasks.fetchAdd(1, .acq_rel);
        s.global.push(t);
        s.wake();
        return 0;
    }

    fn enqueue(s: *Sched, t: *Task) void {
        if (t.last) |e| if (!e.retiring.load(.acquire)) {
            e.q.push(t);
            s.wake();
            return;
        };
        s.global.push(t);
        s.wake();
    }

    fn wake(s: *Sched) void {
        _ = s.seq.fetchAdd(1, .release);
        if (s.nidle.load(.acquire) > 0) s.io.futexWake(u32, &s.seq.raw, 1);
    }

    fn wakeAll(s: *Sched) void {
        _ = s.seq.fetchAdd(1, .release);
        s.io.futexWake(u32, &s.seq.raw, std.math.maxInt(u32));
    }

    fn hasWork(s: *Sched, e: *Exec) bool {
        if (!s.global.isEmpty() or !e.q.isEmpty()) return true;
        s.acquire();
        defer s.lock.unlock();
        for (s.execs.items) |x| if (!x.q.isEmpty()) return true;
        return false;
    }

    fn steal(s: *Sched, e: *Exec) ?*Task {
        s.acquire();
        defer s.lock.unlock();
        for (s.execs.items) |x| if (x != e) if (x.q.pop()) |t| return t;
        return null;
    }

    fn monitorMain(s: *Sched) void {
        while (true) {
            s.io.sleep(.fromNanoseconds(tick_ns), .awake) catch {};
            const t = now();
            s.acquire();
            if (s.execs.items.len == 0 and s.stopping.load(.acquire)) {
                s.lock.unlock();
                return;
            }
            var replace: u32 = 0;
            var work: ?bool = null;
            for (s.execs.items) |e| {
                const since = e.since.load(.acquire);
                switch (e.state.load(.acquire)) {
                    .idle => {},
                    .guest => if (t - since >= slice_ns) {
                        if (work == null) work = s.anyQueuedLocked();
                        if (work.?) {
                            e.since.store(t, .release);
                            e.kick();
                        }
                    },
                    .kernel => if (t - since >= block_ns and !e.retiring.load(.acquire)) {
                        // In a host call that blocks: another runs in its
                        // place, and it ends when it's back.
                        e.retiring.store(true, .release);
                        replace += 1;
                    },
                }
            }
            s.lock.unlock();
            while (replace > 0) : (replace -= 1) {
                _ = s.spawnExec() catch break;
                _ = s.handoffs.fetchAdd(1, .monotonic);
            }
            // A retiring executor's queue goes to the others.
            if (replace == 0) s.drainRetiring();
        }
    }

    fn anyQueuedLocked(s: *Sched) bool {
        if (!s.global.isEmpty()) return true;
        for (s.execs.items) |x| if (!x.q.isEmpty()) return true;
        return false;
    }

    fn drainRetiring(s: *Sched) void {
        s.acquire();
        defer s.lock.unlock();
        var moved = false;
        for (s.execs.items) |e| if (e.retiring.load(.acquire)) {
            while (e.q.pop()) |t| {
                s.global.push(t);
                moved = true;
            }
        };
        if (moved) s.wake();
    }

    /// Ends the executors once every task has exited, waiting up to
    /// `grace_ms` for the last to leave them, and frees them. Returns
    /// false, and frees nothing, if a task is still there (a process
    /// stuck in the host), so what it may touch stays.
    pub fn shutdown(s: *Sched, grace_ms: u32) bool {
        if (comptime !enabled) return true;
        s.stopping.store(true, .release);
        s.wakeAll();
        var waited: u32 = 0;
        while (s.tasks.load(.acquire) != 0) : (waited += 1) {
            if (waited >= grace_ms) return false;
            s.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
        s.stop();
        return true;
    }

    fn stop(s: *Sched) void {
        s.stopping.store(true, .release);
        s.wakeAll();
        if (s.monitor) |m| m.join();
        s.acquire();
        const all = s.all.toOwnedSlice(s.gpa) catch unreachable;
        s.lock.unlock();
        for (all) |e| {
            e.retiring.store(true, .release);
        }
        s.wakeAll();
        for (all) |e| {
            e.thread.join();
            c.h9_sched_exec_free(e.kx);
            s.gpa.destroy(e);
        }
        s.gpa.free(all);
        s.execs.deinit(s.gpa);
        s.all.deinit(s.gpa);
        c.h9_sched_pool_free(s.pool);
        s.gpa.destroy(s);
    }

    /// Kernel stacks mapped, for the cases.
    pub fn stacks(s: *Sched) usize {
        return c.h9_sched_pool_mapped(s.pool);
    }

    /// Host threads it runs on: its executors and the monitor.
    pub fn threads(s: *Sched) usize {
        s.acquire();
        defer s.lock.unlock();
        return s.execs.items.len + 1;
    }
};

/// The executor running on this thread, if any.
fn current() ?*Exec {
    if (comptime !enabled) return null;
    return @ptrCast(@alignCast(c.h9_sched_exec_current()));
}

fn currentTask() ?*Task {
    if (comptime !enabled) return null;
    return @ptrCast(@alignCast(c.h9_sched_task_current()));
}

/// The calling task's host CPU time so far, if it's a task: what
/// cputime.thread() reads for a process on an executor.
pub fn taskCpu() ?cputime.Times {
    if (comptime !enabled) return null;
    const t = currentTask() orelse return null;
    return t.cpu.add(cputime.hostThread().since(t.mark));
}

// A scheduled lease (cpupool.Lease with `scheduled`): the process's state
// is the lease's, and goes into whichever executor's vCPU runs it.

/// Runs the lease's guest code to its next exit, on the executor the
/// calling task is on.
pub fn leaseRun(l: *cpupool.Lease) engine.Error!engine.Exit {
    var e = current() orelse return error.HypervisorFailed;
    if (e.shouldYield()) {
        c.h9_sched_yield();
        e = current() orelse return error.HypervisorFailed;
    }
    const t = currentTask() orelse return error.HypervisorFailed;
    t.lease = l;
    if (e.s.own) return runOwn(e, l);
    if (!e.has_vcpu) {
        // HVF binds a vCPU to the thread that makes it: this one.
        e.vcpu = e.s.eng.createVcpu() catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfGuestMemory,
            else => |x| x,
        };
        e.has_vcpu = true;
    }
    const v = &e.vcpu;
    if (e.owner.load(.acquire) != l or l.home != @as(?*anyopaque, e)) {
        // Another ran here since, or it last ran elsewhere: its whole
        // state goes in.
        try v.setAddressSpace(l.as orelse return error.BadAddress);
        try v.setExtra(&l.extra);
        l.extra_dirty = false;
        l.as_dirty = false;
        l.home = e;
        e.owner.store(l, .release);
    } else {
        if (l.as_dirty) {
            try v.setAddressSpace(l.as orelse return error.BadAddress);
            l.as_dirty = false;
        }
        if (l.extra_dirty) {
            try v.setExtra(&l.extra);
            l.extra_dirty = false;
        }
    }
    v.setUreg(&l.ureg);
    l.lockKick();
    const kicked = l.kicked;
    l.kicked = false;
    l.running_on = if (kicked) null else v;
    l.kick_lock.unlock();
    if (kicked) return .interrupted;
    const exit = e.runGuest(v);
    l.lockKick();
    l.running_on = null;
    l.kick_lock.unlock();
    v.getUreg(&l.ureg);
    return exit;
}

/// leaseRun where the process keeps a vCPU of its own, made on its first
/// run: only the host thread is the executor's.
fn runOwn(e: *Exec, l: *cpupool.Lease) engine.Error!engine.Exit {
    if (!l.owned) {
        const v = e.s.eng.createVcpu() catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfGuestMemory,
            else => |x| x,
        };
        l.lockKick();
        l.vcpu = v;
        l.owned = true;
        l.kick_lock.unlock();
        l.as_dirty = true;
        l.extra_dirty = true;
    }
    if (l.as_dirty) {
        try l.vcpu.setAddressSpace(l.as orelse return error.BadAddress);
        l.as_dirty = false;
    }
    if (l.extra_dirty) {
        try l.vcpu.setExtra(&l.extra);
        l.extra_dirty = false;
    }
    l.vcpu.setUreg(&l.ureg);
    const exit = try e.runGuest(&l.vcpu);
    l.vcpu.getUreg(&l.ureg);
    return exit;
}

/// The FP/SIMD registers and thread pointer, as of the last exit.
pub fn leaseGetExtra(l: *cpupool.Lease, x: *engine.Extra) engine.Error!void {
    if (l.owned) {
        if (!l.extra_dirty) try l.vcpu.getExtra(&l.extra);
    } else if (current()) |e| {
        if (e.owner.load(.acquire) == l and l.home == @as(?*anyopaque, e) and !l.extra_dirty)
            try e.vcpu.getExtra(&l.extra);
    }
    x.* = l.extra;
}

/// The process is done with its lease: no executor keeps it as its
/// vCPU's owner.
pub fn leaseRelease(l: *cpupool.Lease) void {
    if (l.owned) {
        l.lockKick();
        l.owned = false;
        l.kick_lock.unlock();
        l.vcpu.destroy();
    }
    if (l.home) |h| {
        const e: *Exec = @ptrCast(@alignCast(h));
        _ = e.owner.cmpxchgStrong(l, null, .acq_rel, .acquire);
    }
    l.home = null;
}
