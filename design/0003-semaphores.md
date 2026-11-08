---
id: 3
slug: semaphores
title: rendezvous and semaphores
status: implemented
created: 2026-11-03
authors: [progrium]
depends: []
areas: [kern]
---

# Proposal: rendezvous and semaphores

Nov 3, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

Serve `rendezvous`, `semacquire`, `tsemacquire`, and `semrelease` with host kernel primitives built on drawterm's sleep/wakeup, so guest programs can synchronize. Go's runtime parks every lock on them.

## Background

This was part of milestone M5 ("servers") in DESIGN.md, before milestones became proposals ([#1](0001-proposals.md)).

From DESIGN.md's process model table:

| Plan 9 call | Implementation |
| --- | --- |
| `rendezvous` / `semacquire` / `tsemacquire` / `semrelease` | Host kernel primitives built on drawterm's sleep/wakeup |

Today all four post "sys: bad sys call", so a program that calls one dies. 9front's libc `qlock` and `rwlock` park on `rendezvous` when a lock is contended, and libthread parks procs on it; in the pinned arm64 root, 325 of 704 binaries reference it, including `ls`, `acme`, `plumber`, and `factotum`. They work today only as long as no lock is contended. `semacquire` and `semrelease` are used by `gefs` and `cwfs64x` (wanted by [image-roots](0014-image-roots.md)) and by Go's `semasleep`/`semawakeup`, and Go's timed parks use `tsemacquire` ([go-compat](0007-go-compat.md)).

The numbers are `RENDEZVOUS` 34, `SEMACQUIRE` 37, `SEMRELEASE` 38, and `TSEMACQUIRE` 52 (`libc/9syscall/sys.h`). The semantics are in 9front's `port/sysproc.c` and the `rendezvous(2)` and `semacquire(2)` manual pages:

- `rendezvous(tag, val)` blocks until another process in the same rendezvous group calls it with the same tag, then each returns the other's value. An interrupted call returns `~0`.
- `semacquire(addr, block)` atomically decrements `*addr` if it's positive and returns 1. Otherwise it returns 0 if `block` is 0, or waits for a `semrelease` on `addr`. An interrupted wait returns -1 with "interrupted".
- `tsemacquire(addr, ms)` is the same, waiting at most `ms` milliseconds and returning 0 on a timeout; `ms` 0 doesn't wait.
- `semrelease(addr, count)` atomically adds `count` to `*addr`, wakes up to `count` waiters, and returns the new value.
- `addr` points at a `long`, which is 32 bits on every Plan 9 architecture. It must be 4-byte aligned (otherwise the process gets the note "sys: odd address" and the call fails with "bad arg in system call"), lie in a writable segment, and hold a value that isn't negative; `count` mustn't be negative either. 9front keeps each segment's waiters on a list in the segment, keyed by address.

drawterm already has a `sysrendezvous` wrapper in `kern/sysfile.c`, and its Proc already has a rendezvous group (`rgrp`), which h9's `rfork` shares or replaces with `RFREND` (`src/kern/proc.c`). A note's `procinterrupt` pulls a process out of a rendezvous or a sleep. drawterm has no semaphores and no `tsleep`: its `sleep` has no timeout, which is why h9's `sleep` call is served in 20 ms slices (`h9_kern_sleep` in `src/kern/glue.c`).

## Proposal

**rendezvous.** `src/syscall.zig` decodes the tag and value as 64-bit words and calls drawterm's `sysrendezvous` as it is. Groups are already per Proc tree and per machine, since each machine's first Proc gets a fresh `Rgrp`.

**Semaphores.** A new `src/kern/sema.c` ports 9front's `semqueue`, `semdequeue`, `semwakeup`, `semrelease`, `canacquire`, `semacquire`, and `tsemacquire` closely, races and comments included, since that code was checked with spin. It differs from 9front in two ways:

- The waiter lists live in a kernel-wide hash table of 64 buckets, each with its own lock, rather than in the segment. They're keyed by the host address of the semaphore word. Every address space that shares a segment maps the same host pages, and a segment's pages never move once allocated (`src/segment.zig` grows in chunks without copying), so the host address names the same semaphore in every sharer, as 9front's (segment, address) pair does. Machines never share guest pages, so one table serves every machine in the host process.
- The value is changed with host atomics (`__atomic` compare-and-swap with sequentially consistent ordering) on the host memory that backs the guest word. That memory is what the guest's own loads, stores, and exclusives see.

Each call gets a `sys*`-style wrapper (`h9_semacquire`, `h9_tsemacquire`, `h9_semrelease`): it runs `waserror`, and on an error stores the string for `errstr` and returns -1, as DESIGN.md's seam rules require. The wrappers take a host pointer that the Zig side has already checked.

**Checking the address.** `src/syscall.zig` checks `addr` before calling into the kernel, so seam rule 7 holds:

1. If `addr` isn't 4-byte aligned, it posts "sys: odd address" to the process and fails the call with "bad arg in system call", as 9front's `evenaddr` does.
2. An unmapped `addr` posts "sys: bad address in syscall", like any bad guest pointer.
3. If the word isn't in the data or stack segment (`Segs.writable`), the call fails with "bad arg in system call".
4. Otherwise `guestmem.contiguous` gives the host pointer; an aligned 4-byte word never crosses a page.

The C side then checks for negative values and a negative count. The pointer stays valid for the whole call, because the caller's own address space keeps the segment attached while the caller is blocked. An `rfork(RFMEM)` sibling that execs or exits only detaches its own reference, and a shared data segment can't shrink (`Segs.brk` refuses).

**tsleep.** `tsemacquire` needs a sleep with a timeout. A new `src/kern/tsleep.c` provides `tsleep(Rendez *r, int (*fn)(void*), void *arg, ulong ms)` with 9front's contract, built only on drawterm's public `sleep` and `wakeup`, as 9front builds its own on its timers:

- One timer kproc per kernel, started from `h9_proc_boot`, keeps a list of deadlines sorted by host monotonic time. It waits on a host condition variable until the earliest deadline or until an earlier one is added. This uses `pthread_cond_timedwait` in `glue.c` and `SleepConditionVariableCS` in `glue-win32.c`.
- `tsleep` puts a timer on its own stack into the list, then calls `sleep(r, tfn, arg)`, where `tfn` is true once the timer has fired or `fn` is true. At the deadline the timer kproc clears the timer's Rendez and calls `wakeup` on it, as 9front's `twakeup` does.
- The timer is always removed before `tsleep` returns, including on the error path when a note interrupts it. Removal takes the list lock, which the timer kproc holds while it calls `wakeup`, so no timer is touched after its stack frame is gone.

`tsemacquire` takes the deadline from the monotonic clock once and loops until it passes, so spurious wakeups don't stretch the timeout.

**Blocking and the rest of the process model.** A process blocked in any of these calls is in the kernel on its own thread. It holds no pooled vCPU and no `--cpus` slot (`cpupool.Lease.run` takes the slot only around guest code), so a waiter never starves the process that would release it, even with `--cpus 1`. Notes, `/proc/n/ctl kill`, and `--timeout` reach it through `procinterrupt`, which already handles both `Rendezvous` and `Wakeme`. `/proc/n/status` shows the call's capitalized name (`Rendezvous`, `Semacquire`, `Tsemacquire`, `Semrelease`), as it does for other calls. `--trace` prints the tag and value or the address in hex, then the count, flag, or timeout.

## Rationale

**Building on drawterm's sleep/wakeup, not host futexes.** A Zig implementation could wait on the guest word directly with `std.Io` futexes (futex, `__ulock_wait`, `WaitOnAddress`), with no wait list at all. It was rejected because notes, `/proc/n/ctl kill`, and the `--timeout` teardown interrupt a blocked process through drawterm's `procinterrupt`, which only knows Rendez sleeps and rendezvous. A second kind of wait would need its own interrupt path in every place that posts a note. It would also put Zig waits on the process's kernel thread outside drawterm's `up`/error discipline (seam rules 1 and 4). The 9front port also keeps the semantics exactly 9front's, including handing on a wakeup that an interrupted waiter can't use.

**A real tsleep, not slices.** `tsemacquire` could poll as `sleep` does: `osmsleep` in 20 ms slices, checking the value in between. A `semrelease` would then take up to 20 ms to be seen, and Go's scheduler parks with timeouts all the time (`notetsleep`), so every timed park would cost up to 20 ms. Polling more often trades that for idle CPU. The timer kproc gives millisecond deadlines and immediate wakeups for one host thread per host process. `sleep` (the call) could later use `tsleep` too and drop its slices; that's a separate change that doesn't alter behaviour, so it isn't part of this proposal.

**tsleep in project code, not in the vendored tree.** Adding `tsleep` to drawterm's `kern/sleep.c` would be the shortest path. But it needs per-Proc timer fields in `kern/dat.h`, and AGENTS.md asks that the vendored tree stay as close to upstream as possible. Putting the timer on `tsleep`'s stack needs no Proc fields, so `src/kern/tsleep.c` stays project-owned and uses only public drawterm calls.

**Keying waiters by host address, not by segment.** 9front keeps a list per segment. h9's segments are Zig objects (`src/segment.zig`), so following 9front would mean C reaching into Zig objects for lists guarded by kernel locks, or Zig holding kernel locks, and both cross the seam the wrong way. The host address identifies the same word across every sharer for as long as any of them is blocked on it. If segments ever move pages, for example with copy-on-write or compaction, the key would have to change. This proposal records that assumption in `src/segment.zig`.

**One global table, not one per machine.** Machines in one host process never share guest pages, so their keys never collide. A per-machine table would add a lookup for no isolation gain. 64 buckets with a lock each keep unrelated semaphores from contending; `--pids` bounds the number of waiters.

**Checking the address in Zig.** drawterm's `validaddr` is a no-op, and h9's translation is the only check between a guest pointer and host memory (seam rule 7). The alignment and writability checks sit next to that translation, and the C side only ever sees a host pointer to one valid, aligned word.

## Compatibility

There are no new CLI flags, exit codes, `Machine.Options`, or sandbox capabilities, and the root tree is unchanged. `third_party/` is unchanged: `sysrendezvous` is used as it is, and `sema.c` and `tsleep.c` are new files in `src/kern/`.

Programs that died with "sys: bad sys call" when a lock was contended, or as soon as they used a semaphore, now behave as on 9front. Programs that don't use these calls see no change.

One kernel thread is added per host process, for the timer kproc. It's started at boot and idles on a condition variable.

On the Unicorn emulator, the kernel's compare-and-swap is atomic on the host. Guest exclusives on a word that another process's engine is also using are only as atomic as Unicorn makes them, which is already true of `_tas` locks between `RFMEM` processes there; [zig-interpreter](0019-zig-interpreter.md) makes guest atomics hold across engines. HVF runs the guest on the host's own cores, so host and guest atomics on the same memory are coherent.

## Security

The guest gains no host reach.

- A semaphore address is a guest address, translated and checked like every other guest pointer. It must be an aligned word in a writable segment of the caller's own address space, which can't cross a page. The kernel touches only that word, with atomics.
- The host pointer can't dangle, because the caller's address space keeps the segment attached while the caller is blocked.
- Wait lists are keyed by host addresses of the caller's own guest memory, and rendezvous groups are per Proc tree, so a process can't wake or block processes in another machine.
- Blocking costs a kernel thread that's already counted against `--pids`, as `sleep` or a pipe read already does. Waiter records and timers live on the blocked thread's stack, so the guest can't make the kernel allocate without bound.
- Every blocked call can be interrupted, so `--timeout`, hangup, and `/proc/n/ctl kill` still stop the machine.

## Done when

Each case runs on every backend in `H9_TEST_BACKENDS` with the same output. The test programs are C sources in `tests/fixtures/`, built inside the guest with `7c` and `7l` from the root tree into a scratch directory given with `--sandbox`.

- `test "rendezvous swaps values between two processes [semaphores]"`
- `test "contended qlock parks and wakes through rendezvous [semaphores]"`: several `RFMEM` processes increment a shared counter under a `QLock`, and the total is exact.
- `test "semacquire waits for semrelease across RFMEM processes [semaphores]"`
- `test "semaphores keep a shared counter exact under contention [semaphores]"`, also with `--cpus 1`
- `test "semacquire without block and tsemacquire with 0 ms don't wait [semaphores]"`
- `test "tsemacquire times out, or returns early on semrelease [semaphores]"`: a 100 ms timeout returns 0 after at least 100 ms and well under a second, and a release after 50 ms returns 1 before the timeout.
- `test "a note interrupts rendezvous and semacquire, and the handler runs [semaphores]"`: they return `~0` and -1 with "interrupted", respectively.
- `test "bad semaphore addresses and values fail as on 9front [semaphores]"`: an odd address gets "sys: odd address", a text address and a negative value or count get "bad arg in system call", and an unmapped address gets "sys: bad address in syscall".
- `test "ps shows processes blocked in Rendezvous and Semacquire [semaphores]"`
- `test "--timeout stops processes blocked in rendezvous and semacquire [semaphores]"`
- A unit test in `src/kern.zig`: `tsleep` returns at its deadline, returns early on `wakeup`, and fails with "interrupted" on a note, leaving no timer behind.

## Implementation

1. `src/kern/tsleep.c`: the timer list, the timer kproc started from `h9_proc_boot`, the condition-variable wait in `glue.c` and `glue-win32.c`, and `tsleep`. Add the unit test.
2. `src/kern/sema.c`: the port of 9front's semaphore code with the hashed wait lists, and the `h9_semacquire`, `h9_tsemacquire`, and `h9_semrelease` wrappers. Add both files to the kern sources in `build.zig`.
3. `src/kern.zig`: bindings for the three wrappers and for `sysrendezvous`, with the stubs for builds without kern.
4. `src/syscall.zig`: add `rendezvous`, `semacquire`, `semrelease`, and `tsemacquire` to `Nr`, decode them, check addresses as above, and format them for `--trace`. Note in `src/segment.zig` that semaphore wait lists rely on pages not moving.
5. The test fixtures and the integration cases.
6. Update README.md's syscall list, and DESIGN.md: the process model table, `tsleep.c`, and `sema.c` in the kernel's "Added by us" table, and the timer kproc under Threads. Mark the proposal implemented.

## Open issues

- Whether Unicorn performs guest `LDXR`/`STXR` as host compare-and-swaps. If it doesn't, cases that mix guest atomics with kernel semaphores between `RFMEM` processes may be flaky on the emulator until [zig-interpreter](0019-zig-interpreter.md) lands.

## Updates

**Nov 5, 2026.** `rendezvous` is 9front's `sysrendezvous` ported into `src/kern/sema.c`, on drawterm's Rgrp and Proc fields, rather than drawterm's `sysrendezvous` called as it is. drawterm's sleeps without checking for a pending note, so a note posted after the call starts but before the process is on the rendezvous hash list sets `notepending` without waking it, and the process stays blocked until another note. The port sets the state, fences, and checks `notepending` under the group's lock, so either `procinterrupt` finds the process on the list or the process sees the note and returns `~0`. `procinterrupt` is unchanged and `third_party/` is still untouched.

The backend tests in `tests/backends.zig` also run hand-assembled arm64 programs (`tests/fixtures/sema/`) for rendezvous, semacquire, the timed and non-blocking forms, a contended counter, the bad-argument cases, and note interruption, so the calls are covered on hosts without the root tree, such as the emulator on x86\_64 Linux.
