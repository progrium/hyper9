---
id: 49
slug: linux-threads
title: Linux threads
status: implemented
created: 2026-11-05
authors: [progrium]
depends: [linux-personality, linux-net]
areas: [kern, vmm]
branch: [main]
---

# Proposal: Linux threads

Nov 6, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

Linux processes under the [Linux personality](linux-personality.md) can create threads with `clone(CLONE_VM | CLONE_THREAD | …)`, wait on and wake futexes, and be signalled per thread. Threads of one process run on several vCPUs at once, sharing one address space, so a change that narrows the address space is shot down on every vCPU running it before the host reuses the pages. This brings pthreads programs and Go's `linux/arm64` and `linux/amd64` binaries to h9.

## Background

The Linux personality runs one vCPU per address space at a time: a `vfork` parent waits for its child. Its VMA layer, and the vmm's range `unmap` and `protect`, take effect on a vCPU at its next run, through the HVF backend's epoch check and the emulator's per-engine sync.

That's not enough once two vCPUs run in one address space. A thread that calls `munmap` while another thread is in guest code leaves the other vCPU with stale TLB entries. If the host frees those pages and reuses them for another process, the running thread reads and writes that process's memory.

On the emulator, threads can't run at once at all. Unicorn generates code for a single-threaded context, so guest atomics are plain loads and stores, and `emu.zig` already runs guest code on one engine at a time under its GuestLock (SPEC.md, Atomics). A prototype confirmed it for Linux threads: four engines incrementing one counter with arm64 `ldaxr`/`stlxr` lost 69% of 8,000,000 increments, and with amd64 `lock incl` lost 72%.

That lock passes only at exits, so a thread that loops without making a syscall holds every other thread off forever. 9front programs get away with it, since their runtimes make calls between short spins. Linux programs don't: a pthread spinning on a flag, or a Go goroutine in a call-free loop while the GC waits to stop the world, hangs the process.

Other pieces already fit:

- `vmm.Extra.tls` carries the thread pointer, so `CLONE_SETTLS` is a store.
- drawterm's sleep and wakeup, with notes, already interrupt any blocking call, so a futex wait is interruptible for free.
- `cpupool` already handles more live processes than the hypervisor's vCPU cap, and threads are processes there.

## Proposal

### clone

- **`clone(CLONE_VM | CLONE_THREAD | CLONE_SIGHAND | …)`** creates a process that shares the whole address space, stack included, and the VMA list. That's unlike `RFMEM`, which copies the stack. The child gets the new stack pointer, and with `CLONE_SETTLS` its thread pointer in `vmm.Extra.tls`. `CLONE_FILES`, `CLONE_FS`, and `CLONE_SIGHAND` share the fd group, the namespace, and dot, and the signal actions; without them they're copied, as `rfork` does.
- **`CLONE_PARENT_SETTID`, `CLONE_CHILD_SETTID`, `CLONE_CHILD_CLEARTID`:** the tid is written where asked. At thread exit, the clear-tid word is zeroed and its futex woken.
- **`clone3`** with the same flags.
- **Thread groups:** a thread group is the processes created with `CLONE_THREAD` from one leader. `getpid` is the leader's pid, `gettid` the thread's own. `/proc/<pid>/task/<tid>` lists the group.
- **`exit_group`** and a fatal signal kill every thread in the group, and the group's exit status is the leader's wait record. **`execve`** from any thread kills the others first, and the new image runs with the leader's pid.

### futex

`futex` wait and wake are host-side queues keyed on the address space and the guest address, built on drawterm's sleep and wakeup, so notes and timeouts interrupt them like any other wait. `FUTEX_WAIT`, `FUTEX_WAKE`, `FUTEX_WAIT_BITSET`, `FUTEX_WAKE_BITSET`, `FUTEX_REQUEUE`, and `FUTEX_CMP_REQUEUE` are served, with and without `FUTEX_PRIVATE_FLAG`. Shared futexes across `fork` key on the shared segment and offset instead. PI futexes are `-ENOSYS`. `set_robust_list` records the list, and thread exit walks it, marking each held lock's owner died and waking a waiter.

### TLB shootdown

The vmm gains a shootdown for address spaces with several vCPUs:

- Every `unmap` or `protect` that removes or narrows access, in an address space with other running vCPUs, kicks each of them and waits until each has acknowledged it'll flush before its next guest instruction. Only then does `munmap` return and the host free the pages.
- On HVF, a kicked vCPU exits, sees the changed epoch at its next run, and has the shim flush, as today; the waiter only needs to know it has exited. On the emulator no other engine is in guest code while the change is made, since one engine runs at a time, so there's nothing to wait for: each engine applies the change at its next run.
- Widening changes (`mmap` of new pages, `mprotect` that adds access) need no shootdown; a stale TLB entry for an unmapped page faults, and the fault handler retries after checking the VMA.
- Pages freed by a shootdown that hasn't finished are never reused.

### Time-slicing on the emulator

The emulator's GuestLock passes on a timer as well as at exits, so a thread spinning in guest code is preempted and others run. A preemption is a request the engine acts on itself: the kicker sets a flag on the vCPU, and a `UC_HOOK_BLOCK` hook on the engine's own thread sees it at the next block and calls `uc_emu_stop`, which leaves the PC exact. A kick never calls `uc_emu_stop` from another thread. SPEC.md already warns that a cross-thread stop can report an earlier block's PC, and the prototype confirmed it: Go crashed with wild reads in 6 of 6 runs at 1 ms slices that way, with signals off, and ran cleanly in 11 of 11 with the in-engine stop.

The slice is a few milliseconds, and the timer only fires while another vCPU is waiting for the lock or the running one has a signal pending. `tgkill`'s kick of a running thread is the same flag. [zig-interpreter](zig-interpreter.md) can test the flag between blocks at no cost.

This also fixes 9front programs on the emulator that spin without syscalls today.

### Signals per thread

- Each thread has its own signal mask and pending set; the group has a shared pending set.
- **`tgkill` and `tkill`** target a thread. A thread running guest code is kicked so it takes the signal at its next exit, as a note does today. Go's preemption sends `SIGURG` this way, often: 38 times in the prototype's run of a small `net/http` program. On arm64 Go's handlers return through the vDSO's `__kernel_rt_sigreturn` ([linux-personality](linux-personality.md)), since Go sets no restorer there.
- **A new thread starts with its creator's signal mask,** as on Linux. musl blocks every signal around `clone` and the child restores its own.
- **A fault no handler catches kills the whole group,** not just the faulting thread.
- **`kill`** to a group picks any thread that doesn't block the signal.
- **`rt_sigtimedwait`** and `sigwaitinfo` take a pending signal without running a handler.

### Scheduling

- `sched_getaffinity` reports `--cpus`. `sched_setaffinity` is accepted and ignored.
- Threads count toward the vCPU cap and the pool, like processes. A Go program with many Ms is many processes past the cap, so it runs through the pool, as `mk -j` does today.

## Rationale

**Threads as processes.** Linux itself models threads as tasks sharing an address space, and h9's process record already has everything a task needs: its own vCPU lease, Ureg, Extra, and kernel Proc. A second kind of record would duplicate all of that.

**Go needs [linux-net](linux-net.md).** Go's runtime opens an epoll fd and an eventfd at its first timer, before any networking, and dies with `netpollinit failed` without them. So this proposal's Go cases depend on linux-net's epoll and eventfd, even though nothing else here does. Moving those two calls for non-socket fds into this proposal was the alternative; it would split epoll across two proposals.

**Time-slicing with an in-engine stop.** A stop from another thread is simpler, and a tight loop test (1,233 stops) showed no replayed instructions, but Go's runtime failed under cross-thread stops every time. A block hook costs a callback per translated block; the alternative of counting instructions (`uc_emu_start`'s `count`) installs a per-instruction hook, which costs more.

**Shootdown by kick, not by IPI.** h9 has no guest kernel to send IPIs to, and HVF has no API to flush another vCPU's TLB. A kick makes the vCPU exit, after which the host controls when it runs again. It costs an exit per running thread on each narrowing change, which Linux pays too in IPIs.

**Copy-on-write fork** would help Go and Python, which fork little, less than shells, which fork a lot but are single-threaded. It stays later performance work.

## Compatibility

- **vmm interface:** a shootdown call (`AddressSpace.shootdown`, or a flag on `unmap` and `protect`), and the HVF and emulator backends track which vCPUs are running each address space.
- No CLI flags or exit codes change.

## Security

- **Freed pages are never visible to a stale TLB.** The shootdown completes before any page leaves the address space's ownership. This gets its own stress test: threads read a page in a loop while another unmaps and the host reuses it, and no read sees the new owner's data.
- **futex keys** include the address space, so one machine's or process's futexes can't wake another's.
- **Thread-group kills** go through the same note delivery as today, so `kill` from `/proc/n/ctl` still kills a thread that blocks every signal.

## Done criteria

Integration cases tagged `[linux-threads]`:

- [x] `test "pthreads program with 8 threads and a mutex [linux-threads]"`
- [x] `test "Go linux binary starts goroutines and sleeps [linux-threads]"`
- [x] `test "munmap while another thread reads: no stale access after return [linux-threads]"`
- [x] `test "exit_group kills every thread [linux-threads]"`
- [x] `test "execve from a non-leader thread [linux-threads]"`
- [x] `test "tgkill interrupts a thread in a busy loop [linux-threads]"`
- [x] `test "CLONE_CHILD_CLEARTID wakes pthread_join [linux-threads]"`
- [x] `test "a thread spinning without syscalls doesn't starve the others on the emulator [linux-threads]"`
- [x] `test "Go GC with a goroutine in a call-free loop, at 1 ms slices [linux-threads]"`

Demo: a Go program built with `GOOS=linux GOARCH=arm64` runs natively on HVF.

## Implementation

1. Thread groups, `clone` with `CLONE_VM`, TLS, the tid words, `exit_group`. A pthreads hello.
2. futex, robust lists. pthreads with mutexes and condition variables.
3. The shootdown in both backends, and its stress test. Time-slicing on the emulator, with the in-engine stop.
4. Per-thread signals and `tgkill`. Go, once linux-net's epoll and eventfd are built.
5. SPEC.md's Linux personality section gains threads.

## Open issues

- **The block hook's cost.** A hook on every translated block made CPython 3.5 times slower in the Python prototype, where the hook was a Python callback. In Zig it's a flag test, but it should be measured on a compute benchmark, and installed only while a process has more than one thread if it matters.

- **Per-thread CPU time** for `CLOCK_THREAD_CPUTIME_ID`, which Go's profiler reads.
- **The vCPU cap.** A Go program can have more threads than HVF has vCPUs. The pool handles it, at the cost of two thread wake-ups per syscall for threads past the cap; whether that matters for Go's scheduler needs measuring.

## Updates

- 2026-11-07: Choices made in the first implementation, on the emulator (arm64 and amd64):
  - A thread group is a Linux-layer object (`lsys.Group`), not a kernel one. The kernel sees each thread as an `RFNOWAIT` process; the group holds the tgid, the members, the signal actions and the fd-side state Linux keeps per process (fd flags, directory buffers, sockets and epoll sets). Without `CLONE_FILES` the thread gets `RFFDG`.
  - `CLONE_FS` is accepted but dot isn't shared; each thread keeps its own.
  - Futex queues are in C (`src/kern/linux.c`), 64 buckets keyed by the `Mm` and the address, using `sleep` and `tsleep`, so notes interrupt a wait. Shared futexes across `fork` key on the `Mm` too, not the segment and offset, so they don't work across processes yet. `FUTEX_WAKE_OP` is `ENOSYS` with the PI ops; neither musl nor Go needs it.
  - The shootdown is a vmm call, `AddressSpace.shootdown`. On the emulator it takes and passes on the guest lock, and engines copy the regions after taking it. On HVF it kicks each vCPU running in that address space (`hv_vcpus_exit`) and waits for each to finish its run. `Mm` keeps the pages a narrowing change drops on a list and frees them only after the shootdown, and only shoots down when other threads share the `Mm`. Memory syscalls are serialised per `Mm`.
  - Time-slicing: the waiter for the guest lock asks the holder to stop after 1 ms, only while it waits. `tgkill`'s kick and every other kick are the same in-engine stop request.
  - `exit_group` and fatal signals set the group's end and post a kill note to the others; the leader returns the group's status once it's alone. `execve` from a non-leader kills the others and passes the exec to the leader by a note; an exec after the leader has called `pthread_exit` isn't handled.
  - A process-directed signal blocked by the receiving thread is redirected to a member that doesn't block it, as a note naming the signal. `kill` to a tid that isn't a leader reaches nothing, as `kill -1` skips the caller's own group.
  - arm64 Go needed two things the personality lacked: version tables in the vDSO (`LINUX_2.6.39`), and `CNTKCTL_EL1` set so EL0 can read `CNTVCT` and `CNTFRQ` (Go's `procyield` reads both), on the emulator and HVF.
  - `/proc/<pid>/status` shows `Tgid` and `Threads`, and `stat` the thread count. `/proc/<pid>/task` and hiding non-leader threads from `/proc` are still to do, as is `CLOCK_THREAD_CPUTIME_ID`.
  - A thread's children are its own for `wait`, not the group's.
  - The HVF shootdown and `CNTKCTL_EL1` are built but haven't run on a Mac yet, nor has the native Go demo.
  - The block hook is always installed. A busybox `sh` loop counting to 300,000 on arm64 took 96–102 s with it and 83–86 s without, about 15% slower; installing it only while a process has more than one thread is the follow-up named in Open issues.
  - The 9front Go case that spins four goroutines on `--cpus 1` is slow on the emulator before and after this work (13–50 s here against its 30 s limit): the `--cpus` slot, unlike the guest lock, isn't time-sliced, so a spinner holds it until its next syscall.
- 2026-11-08: A thread's children are now the group's, as on Linux. Go's `os/exec` forks on one thread and waits on whichever thread the goroutine runs on next, so `go build` failed with "waitid: no child processes". A thread is forked with `RFLXTHREAD` (an h9 flag beside `RFNOWAIT`), which gives it the leader as its waiter: its forks are the leader's children, with the leader's pid as their parent, and its Linux waits read the leader's wait records. Several threads can wait at once, each sleeping on its own `Rendez` on the leader's list and woken whenever a record or child count changes, and each takes only a record that matches its pid (`h9_linux_await` in `src/kern/linux.c`). `waitid` takes `WNOWAIT`, which leaves the record for the `wait4` Go makes next. A process-group wait still keeps a record it doesn't want in its own thread's list. A thread joins its group before its kernel process exists, so an `exit_group` in that window posted its kill note to nothing, and on HVF the new thread ran on and its group never ended; a new thread now checks whether its group is ending before it first runs. If the leader ends with `pthread_exit` while other threads go on, their children's records are lost, since the leader's kernel process is gone.
