//! vCPUs for a machine's processes. See DESIGN.md, "vCPU limits".
//!
//! A process normally owns a vCPU, created on its own thread, as HVF
//! requires. HVF allows only 64 live vCPUs per VM (KVM a few hundred, or
//! fewer with few file descriptors), so once all but a small
//! reserve are owned, further processes run guest code on a shared pool
//! of `reserve` vCPUs instead: the process thread hands its registers to a
//! pool thread, which runs the guest until the next exit and hands them
//! back. Pool threads only run guest code, never kernel calls, so a
//! process blocked in the kernel never holds a pooled vCPU, and the pool
//! always makes progress.
//!
//! `--cpus` caps how many vCPUs run guest code at the same moment, owned
//! or pooled, on every backend: a process waits for a slot before each run.
//!
//! On the emulator there's no vCPU limit (each engine is host memory), so
//! every process owns one.

const std = @import("std");
const vmm = @import("vmm.zig");

/// Pooled vCPUs kept back from the backend's limit for processes that
/// can't own one.
pub const reserve: u32 = 8;

pub const Pool = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    backend: vmm.Backend,
    /// How many vCPUs processes may own; the rest of the backend's limit is
    /// the pool. Null means unlimited (no pool).
    own_limit: ?u32,
    /// Guards the counts and the queue below.
    lock: std.atomic.Mutex = .unlocked,
    owned: u32 = 0,
    /// Cap on vCPUs running guest code at once (`--cpus`), and how many do.
    cpus: ?u32,
    running: u32 = 0,
    /// Bumped on every release of a running slot, to wake waiters.
    run_seq: std.atomic.Value(u32) = .init(0),
    /// Work for pool threads; `work_seq` is bumped on each push.
    queue: std.ArrayList(*Lease) = .empty,
    work_seq: std.atomic.Value(u32) = .init(0),
    workers: std.ArrayList(std.Thread) = .empty,
    worker_count: u32 = 0,
    stopping: std.atomic.Value(bool) = .init(false),

    /// `own_limit`, if given, overrides how many vCPUs processes may own
    /// (for tests of the pool).
    pub fn init(gpa: std.mem.Allocator, io: std.Io, backend: vmm.Backend, cpus: ?u32, own_limit_override: ?u32) vmm.Error!Pool {
        const own_limit: ?u32 = switch (backend.kind()) {
            .emu => null,
            .hvf, .kvm => blk: {
                const max = try backend.maxVcpus();
                break :blk if (max > reserve) max - reserve else 1;
            },
        };
        return .{ .gpa = gpa, .io = io, .backend = backend, .own_limit = own_limit_override orelse own_limit, .cpus = cpus };
    }

    /// Stops the pool threads. Every process must be done with the pool.
    pub fn deinit(p: *Pool) void {
        p.stopping.store(true, .release);
        _ = p.work_seq.fetchAdd(1, .release);
        p.io.futexWake(u32, &p.work_seq.raw, std.math.maxInt(u32));
        for (p.workers.items) |t| t.join();
        p.workers.deinit(p.gpa);
        p.queue.deinit(p.gpa);
    }

    fn lockSpin(p: *Pool) void {
        while (!p.lock.tryLock()) std.atomic.spinLoopHint();
    }

    /// Gets a process a way to run: its own vCPU if one is free, or a lease
    /// on the pool. Call on the process's thread.
    pub fn acquire(p: *Pool, l: *Lease) vmm.CreateError!void {
        l.* = .{ .pool = p };
        const own = blk: {
            p.lockSpin();
            defer p.lock.unlock();
            if (p.own_limit) |lim| if (p.owned >= lim) break :blk false;
            p.owned += 1;
            break :blk true;
        };
        if (own) {
            l.vcpu = p.backend.createVcpu() catch |e| {
                p.lockSpin();
                p.owned -= 1;
                p.lock.unlock();
                // Another machine in this process may hold vCPUs too.
                if (e == error.HypervisorFailed) return p.startPooled(l);
                return e;
            };
            l.owned = true;
            return;
        }
        return p.startPooled(l);
    }

    fn startPooled(p: *Pool, l: *Lease) vmm.CreateError!void {
        l.owned = false;
        p.lockSpin();
        defer p.lock.unlock();
        if (p.worker_count < reserve) {
            const t = std.Thread.spawn(.{}, worker, .{p}) catch return error.OutOfMemory;
            p.workers.append(p.gpa, t) catch {
                p.stopping.store(true, .release);
                t.detach();
                return error.OutOfMemory;
            };
            p.worker_count += 1;
        }
    }

    /// Waits for a running slot under `--cpus`.
    fn enter(p: *Pool) void {
        const cap = p.cpus orelse return;
        while (true) {
            const seq = p.run_seq.load(.acquire);
            p.lockSpin();
            if (p.running < cap) {
                p.running += 1;
                p.lock.unlock();
                return;
            }
            p.lock.unlock();
            p.io.futexWaitUncancelable(u32, &p.run_seq.raw, seq);
        }
    }

    fn leave(p: *Pool) void {
        if (p.cpus == null) return;
        p.lockSpin();
        p.running -= 1;
        p.lock.unlock();
        _ = p.run_seq.fetchAdd(1, .release);
        p.io.futexWake(u32, &p.run_seq.raw, 1);
    }

    fn worker(p: *Pool) void {
        var vcpu = p.backend.createVcpu() catch {
            p.failQueued();
            return;
        };
        defer vcpu.destroy();
        while (true) {
            const seq = p.work_seq.load(.acquire);
            const l = blk: {
                p.lockSpin();
                defer p.lock.unlock();
                if (p.queue.items.len == 0) break :blk null;
                break :blk p.queue.orderedRemove(0);
            } orelse {
                if (p.stopping.load(.acquire)) return;
                p.io.futexWaitUncancelable(u32, &p.work_seq.raw, seq);
                continue;
            };
            l.serve(&vcpu);
        }
    }

    /// With no vCPU for the pool, queued and future work fails.
    fn failQueued(p: *Pool) void {
        p.lockSpin();
        const items = p.queue.items;
        p.queue = .empty;
        p.worker_count -= 1;
        p.lock.unlock();
        for (items) |l| l.finish(error.HypervisorFailed);
    }
};

/// How one process runs guest code: on its own vCPU, or through the pool.
/// It holds the process's registers between runs.
pub const Lease = struct {
    pool: *Pool,
    owned: bool = false,
    vcpu: vmm.Vcpu = undefined,
    as: ?vmm.AddressSpace = null,
    /// Registers to run from, and after a run, as it left them.
    ureg: vmm.Ureg = undefined,
    extra: vmm.Extra = .{ .arm64 = .{} },
    extra_dirty: bool = true,
    /// A pooled run's result, handed back by the pool thread.
    result: vmm.Error!vmm.Exit = .interrupted,
    done: std.atomic.Value(u32) = .init(0),
    /// The pool vCPU running this lease, for `kick`. Guarded by `kick_lock`.
    running_on: ?*vmm.Vcpu = null,
    kicked: bool = false,
    kick_lock: std.atomic.Mutex = .unlocked,

    fn lockKick(l: *Lease) void {
        while (!l.kick_lock.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn release(l: *Lease) void {
        if (!l.owned) return;
        const p = l.pool;
        l.lockKick();
        l.owned = false;
        l.kick_lock.unlock();
        l.vcpu.destroy();
        p.lockSpin();
        p.owned -= 1;
        p.lock.unlock();
    }

    pub fn setAddressSpace(l: *Lease, as: vmm.AddressSpace) vmm.Error!void {
        l.as = as;
        if (l.owned) try l.vcpu.setAddressSpace(as);
    }

    pub fn setUreg(l: *Lease, u: *const vmm.Ureg) void {
        l.ureg = u.*;
    }

    pub fn getUreg(l: *Lease, u: *vmm.Ureg) void {
        u.* = l.ureg;
    }

    /// The FP/SIMD registers and thread pointer, as of the last exit.
    pub fn getExtra(l: *Lease, x: *vmm.Extra) vmm.Error!void {
        if (l.owned and !l.extra_dirty) try l.vcpu.getExtra(&l.extra);
        x.* = l.extra;
    }

    pub fn setExtra(l: *Lease, x: *const vmm.Extra) void {
        l.extra = x.*;
        l.extra_dirty = true;
    }

    /// Runs the guest until its next exit.
    pub fn run(l: *Lease) vmm.Error!vmm.Exit {
        const p = l.pool;
        p.enter();
        defer p.leave();
        if (l.owned) {
            if (l.extra_dirty) {
                try l.vcpu.setExtra(&l.extra);
                l.extra_dirty = false;
            }
            l.vcpu.setUreg(&l.ureg);
            const exit = try l.vcpu.run();
            l.vcpu.getUreg(&l.ureg);
            return exit;
        }
        // Hand off to a pool thread and wait for the exit.
        l.done.store(0, .release);
        {
            p.lockSpin();
            defer p.lock.unlock();
            if (p.worker_count == 0) return error.HypervisorFailed;
            p.queue.append(p.gpa, l) catch return error.OutOfGuestMemory;
        }
        _ = p.work_seq.fetchAdd(1, .release);
        p.io.futexWake(u32, &p.work_seq.raw, 1);
        while (l.done.load(.acquire) == 0) p.io.futexWaitUncancelable(u32, &l.done.raw, 0);
        return l.result;
    }

    /// On a pool thread: runs the lease's guest code once on `v`.
    fn serve(l: *Lease, v: *vmm.Vcpu) void {
        l.finish(l.runOn(v));
    }

    fn runOn(l: *Lease, v: *vmm.Vcpu) vmm.Error!vmm.Exit {
        try v.setAddressSpace(l.as orelse return error.BadAddress);
        // Pool vCPUs pass from process to process, so the whole user state
        // goes with each run.
        try v.setExtra(&l.extra);
        v.setUreg(&l.ureg);
        l.lockKick();
        const kicked = l.kicked;
        l.kicked = false;
        l.running_on = if (kicked) null else v;
        l.kick_lock.unlock();
        if (kicked) return .interrupted;
        const exit = v.run();
        l.lockKick();
        l.running_on = null;
        l.kick_lock.unlock();
        v.getUreg(&l.ureg);
        try v.getExtra(&l.extra);
        l.extra_dirty = true;
        return exit;
    }

    fn finish(l: *Lease, r: vmm.Error!vmm.Exit) void {
        l.result = r;
        l.done.store(1, .release);
        l.pool.io.futexWake(u32, &l.done.raw, 1);
    }

    /// Makes the current or next run return `.interrupted` soon. Safe from
    /// any thread.
    pub fn kick(l: *Lease) void {
        l.lockKick();
        defer l.kick_lock.unlock();
        if (l.owned) {
            l.vcpu.kick();
        } else if (l.running_on) |v| {
            v.kick();
        } else l.kicked = true;
    }
};
