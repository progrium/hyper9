---
slug: scheduler
title: A scheduler, with processes on per-core executors
status: draft
created: 2026-11-21
authors: [progrium]
depends: [kernel-port]
areas: [kern, engine, web, tests]
branch: [dev, scheduler]
---

# Proposal: A scheduler, with processes on per-core executors

Nov 25, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

Today each guest process is a host thread that owns a vCPU. This proposal makes a process a kernel object and runs processes on executors: one host thread per core, each with one vCPU. A process runs on an executor until it blocks in the kernel or its time slice ends, then parks as a continuation, and the executor takes the next runnable process. It removes the cap on processes that the hypervisors' vCPU limits impose, it removes `src/cpupool.zig`, and it makes the web host the same design with one executor instead of a second implementation on coroutines.

## Background

- **vCPU limits cap processes.** Hypervisor.framework allows 64 live vCPUs. From the 57th process on, h9 shares vCPUs through `src/cpupool.zig`, at two thread wake-ups per system call. KVM can't destroy a vCPU, so h9 parks and resets them.
- **A thread per process costs memory and start-up time.** Each has a host stack and a kernel stack, and `fork` in a shell loop pays for a host thread each time.
- **The web host is a second implementation.** It has no threads, so it fakes them with JSPI coroutines on 320 KiB stacks, with a canary check and its own `os-wasm.c`. Bugs there don't reproduce natively, and the reverse.
- **`--cpus` is already a scheduler.** It's a ticket queue in front of guest entry, and the Unicorn engine had a time-sliced lock for the same purpose. Both decide who runs, without being able to park who doesn't.

[kernel-port](kernel-port.md) comes first because parking a process inside the kernel needs the kernel's blocking points to be h9's own code, with no `longjmp` across them.

## Proposal

### Executors

A machine has N executors, where N is `--cpus`, or the host's core count capped by the engine's vCPU limit. Each is a host thread that owns one vCPU for its life. An executor's loop takes a runnable process, loads its registers and address space into the vCPU, runs it until an exit, and handles the exit.

### Processes park

A system call that would block (a read on an empty pipe, `rendezvous`, `sleep`, a 9P request in flight, or a lock) saves the process's kernel continuation and returns the executor to its loop. When the event arrives, the process is made runnable, and any executor can resume it.

Continuations are stackful: each process has a kernel stack, allocated when it first blocks and returned to a pool when it exits. A process that never blocks never has one.

### Run queues and fairness

Each executor has a run queue, and idle executors steal. A process runs for a 10 ms slice, enforced by the engine's existing preemption (a timer kick on the hypervisors and sud, and the instruction budget on hcpu). Priority is one level. Linux `sched_setaffinity` and `nice` are recorded and reported back, and don't change scheduling.

### Address space switches

Switching an executor between processes of different address spaces costs what the engine charges: a page table root on the hypervisors, a stub process switch on sud, and a pointer on hcpu. The run queue prefers to resume a process on the executor that last ran its address space.

### Host calls that block

A call that blocks in the host (a host file read, a DNS lookup, or a GUI event) runs on a small pool of helper threads, and its process parks until it returns. Executors never block in the host.

### The web host

The web host is this design with one executor. JSPI suspends the executor, not a process, when the kernel is idle or waiting on JavaScript. The coroutine layer, its stacks, and `os-wasm.c`'s thread emulation go.

### What's removed

`src/cpupool.zig`, the vCPU park-and-reset paths, the per-process host thread, and the web host's coroutines.

## Rationale

**Why per-core executors and not a thread per process with a bigger pool.** The pool is the cost: it exists because vCPUs are scarce, and it adds wake-ups to every system call past the limit. With executors, vCPUs are exactly as many as can run at once.

**Why stackful continuations.** The kernel blocks deep in call chains (devmnt inside `namec` inside `open`). Rewriting those as state machines would abandon the close translation that [kernel-port](kernel-port.md) keeps. A stack per blocked process is the cost, and it's smaller than today's stack per process.

**Why not async Zig.** The kernel's blocking points are few and well known, and explicit stack switching is the same mechanism on every host, including wasm.

**Why one priority level.** Plan 9's scheduler has more, and Linux's far more. Nothing h9 runs has needed them, and a second level can be added without changing the structure.

## Compatibility

- **CLI.** `--cpus N` means N executors, which is what it has effectively meant. `--pids` no longer has a hidden interaction with the engine's vCPU limit.
- **`Machine.Options`.** Unchanged.
- **Timing.** Programs that depended on every process having its own host thread, such as busy-wait spin locks across more processes than cores, run slower. Linux programs see the same thing on a host with N cores.
- **`/proc` and `ps`.** Unchanged.

## Security

None for the guest's reach. The scheduler is new code in the trusted base, and a bug in it is a cross-process bug: a process resumed with another's registers or address space. The register and address space load is one function, checked by a test that runs many processes on one executor and has each verify its own state.

## Done criteria

- [ ] `h9 --rc 'for(i in `{seq 1 500}) sleep 5 & wait'` runs 500 processes at once on HVF and KVM, with no pool and no slowdown past the 56th.
- [x] `test "1000 blocked processes use 8 host threads [scheduler]"` passes.
- [ ] `test "processes keep their own registers across executor switches [scheduler]"` passes on every engine.
- [ ] `zig build integration`, `zig build integration -Dweb`, and `zig build web-test` pass, with the web host on one executor and no coroutine layer.
- [ ] `zig build bench` shows a system call round trip no slower than before, and a `fork` and `exit` loop faster.
- [x] `src/cpupool.zig`, `src/web/coro.zig`, `src/web/coro.c`, and `src/kern/os-wasm.c`'s thread emulation are deleted.
- [x] [spec/kernel.md](../spec/kernel.md)'s process model describes executors, parking, and slices.

## Implementation

1. Kernel stacks and the park and resume primitive, tested without an engine.
2. Blocking points in `qio`, `sync`, and devmnt park instead of blocking the host thread.
3. Executors and run queues on hcpu, where a vCPU is cheapest.
4. HVF, KVM, WHP, and sud.
5. The helper pool for blocking host calls.
6. The web host on one executor.
7. Remove the pool, the per-process threads, and the coroutines.

## Open issues

- The slice length, and whether interactive processes need a boost. 10 ms is a starting point.
- Whether guest threads of one Linux process should prefer one executor's cache or spread across executors. As written, they spread.
- How `--gfx`'s host event loop, which must own the main thread on macOS, fits beside the executors.

## Updates

**2026-11-26, kernel stacks and park and resume.** `src/kern/sched/` has the primitive, tested with no kernel or engine by `zig build sched-test`. Some things building it found:

- **A process owns a kernel stack only while it's parked.** An executor keeps a spare stack and runs each kernel call on it. A call that returns leaves it with the executor, and one that parks takes it, so the executor takes another from the pool. The stack goes back when the parked call returns, as well as at exit. A process that never blocks never has one, as proposed, and one that blocked once doesn't keep one.
- **A park commits on the executor's stack.** An unpark can come before the park, or while the parking process is still switching out, as with posix.c's counts. The executor marks the process parked only once it's off its stack, and goes straight back into it if an unpark came in the meantime, so the scheduler's hook that queues a runnable process never sees one still running.
- **On wasm, a continuation switches with Binaryen's Asyncify.** wasm can't switch call stacks from inside a module, and the stack-switching proposal hasn't shipped, so `park` unwinds the process's wasm frames into a buffer at its stack's low end and `resume` rewinds them. JSPI is left for the executor, as proposed. This makes `wasm-opt` a dependency of the web build from step 6 on. A module with a park in it doesn't instantiate until Asyncify has run on it, since it imports Asyncify's functions. Emscripten doesn't combine Asyncify with wasm exception handling, which the C kernel's `setjmp` and `longjmp` use on the web, so step 6 must check that `wasm-opt` accepts h9.wasm, or keep parks off paths through C that catches.
- **Thread-locals.** A continuation can resume on another host thread, so `up` can't be a host thread's: step 2 has to set it from the continuation on every switch in.

**2026-11-26, the kernel's blocking points park.** sync.zig's `park` and `unpark` are the only places a process waits and is let go, and qio, devmnt, tsleep, rendezvous, and the semaphores all wait through them, so step 2 is those two. A process with a continuation in `Proc.cont` parks on it, and one without (a kproc, or a process on a host thread of its own) waits in posix.c's procsleep, as before; which a process is is fixed for its life, so a wakeup can't take the wrong path. `park` sets `up` again when it's resumed, and `sync.Kexec` runs calls on an executor with `up` set to the process for the call and back to the thread's own afterwards. kern-test runs a hundred processes in qlock and tsleep on one host thread, a read that one thread readies and another resumes, and a 9P client and its server, both parked in devmnt and qio, on one thread. The web host keeps os-wasm.c's waits until step 6 runs Asyncify on h9.wasm. The kernel's own threadlocals (`fs_plan`, `fs_pages`, and `cons_ncpu` in src/kern.zig) are per host thread, and step 3 must move them to the process or set them on each switch in.

**2026-11-26, executors on every native engine.** Steps 3 to 5 are in: `src/executor.zig` gives a machine `--cpus` executors, each a host thread with a vCPU, with a run queue each, a machine-wide queue, and stealing, and `h9_kern_spawn` and `rfork` hand new processes to them instead of starting threads. Some things building it found:

- **The pool's lease is the process's state for now.** cpupool's `Lease` already kept a process's Ureg, FP state, and address space apart from its vCPU, so an executor loads them from it when another process ran on its vCPU last, and step 7 moves it into the executor.
- **sud processes keep a vCPU of their own.** A sud vCPU is a thread in the stub process, and its FP state is wider than `Extra` (AVX's upper halves), so each process keeps its stub thread and an executor runs it. The 1000 blocked processes use no more than 8 of h9's host threads on sud, as on hcpu, but the stub has a thread for each.
- **The helper pool is the executors.** Rather than route each blocking host call to helpers, the monitor thread that kicks runs past their slice also hands off an executor that has been in one kernel call for 20 ms: it starts another executor in its place, and the blocked one retires when its call returns, as Go's runtime does with a thread in a syscall. Nothing has to know which host calls block, and the loops that poll (`#y` and `#ℏ` taking turns, the kernel's `sleep`) park with `sync.msleep` instead.
- **Some processes keep host threads.** h9's own 9P and pty servers are forked with `RFHOSTTHREAD`, since they block in host reads with the machine's executors possibly all busy, as does every process on the web host until step 6. The kernel's threadlocals are set once on each executor's thread, since an executor serves one machine.
- **CPU time is the process's.** `getrusage` and `/proc/n/status` count a thread's time across executors, through `cputime.task_hook`.

Steps 6 and 7 are left. The web build needs Binaryen's `wasm-opt` for Asyncify, and the pool, the per-process threads, and the coroutines go only once the web host runs on an executor.

**2026-11-26, no clock reads per run.** On the `syscall-perf` branch, an executor no longer reads the monotonic clock in `leaseRun` and as it enters and leaves guest code, which made a `pwrite` round trip on hcpu about 20% slower on this Linux host. It counts its state changes and task switches, and the monitor times them from when it first sees each, so it may see a run or a call up to a tick short, never long; when a task has had its slice and another waits, it sets `yield_due`, which `leaseRun` checks. `nsec` round trips are still about 15% over main's here, from the rest of the executor's work per run.

**2026-11-26, the web host on one executor.** `src/kern/sched/web.zig` is the web host's executor: every kernel process and every one of h9's own threads is a task on it, a continuation switched with Asyncify, and `src/web/coro.c`, `coro.zig`, and `stack.S` are gone. Some things building it found:

- **Asyncify and wasm exception handling work together.** `wasm-opt --enable-exception-handling --asyncify` accepts h9.wasm, and a C test of a park inside a `setjmp`'s body, a `longjmp` after the resume, and a park after the `longjmp` lands gives the right answers at `-O0` and `-O2`. Asyncify can't unwind through a `catch` handler, but no task parks inside one: LLVM's lowering uses the handler only to note which `setjmp` was jumped to and branch out, so the code after a `setjmp` returns 1 runs outside it. So the C kernel keeps wasm EH for `setjmp` and `longjmp`.
- **One JSPI stack.** Only `_start` is `promising`, and the one `Suspending` import is `idle(ms)`, which the executor calls when nothing is runnable, and every 10 ms otherwise so the page's events are seen. The other imports that wait on JavaScript (console input, the signal wait, `gfx_wait`, and the WebSocket and port waits) are ops: they return an id at once, the task parks in `h9_task_await`, and `idle` hands back the finished ops' results.
- **Asyncify leaves the CPUs and the JIT alone.** A task parks or yields only between runs of guest code, so `asyncify-removelist` skips the interpreters, h86, ha64, hx64, and the JIT's compilers. Instrumented, they were half the module, and V8's optimizing compiler took a minute on them before `ls` ran. Debug builds also run `wasm-opt -O1` after the pass, which takes the module from 83 MB to 35 MB; `ls /bin` is now 0.7 s under Node, against 1.0 s before the executor.
- **Per-task state.** A switch saves and restores `errno`, the kernel's Zig threadlocals, and drawterm's `up`, as coro.c did around its parks. `H9_TEST_KSTACK` sets task stacks' size, rounded to 16 bytes rather than wasm's 64 KiB pages.

`zig build web-test` needs Chromium and Playwright, which this step's checks didn't have.

**2026-11-26, the pool and the coroutines removed.** `src/cpupool.zig` is gone: its `Lease`, a process's registers, FP state, and address space between runs, is `executor.Lease`, and the pool threads, the owned-vCPU limit, and the `--cpus` run slots went with it, since executors already did all three. Where a process keeps a vCPU of its own (sud, and the web host), the lease makes it on the first run. Machine.Options' `owned_vcpus` went too, and the pooled-vCPU engine cases run on one executor and on two instead. Some things stay:

- **Three processes keep host threads.** h9's 9P server, pty server, and each pty's control process (`RFHOSTTHREAD`) wait in host calls for the machine's whole life (an accept, the host's pty queue), so on an executor they'd hold its thread anyway, after the monitor had started another in its place.
- **KVM's vCPU recycling.** An executor that's taken for blocked in the host is replaced, and KVM can't destroy a vCPU, so the engine's free list of parked vCPUs is what keeps the count bounded.
- **A child machine's CPUs.** A child machine (design/child-machines.md) has executors of its own, `--cpus` of them, so its runs aren't under its parent's `--cpus` as that proposal says; running a child's processes on its parent's executors is left.

