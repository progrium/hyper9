---
slug: kernel-port
title: Port the kernel core to Zig, as an instance
status: draft
created: 2026-11-21
authors: [progrium]
depends: [baseline-1, namespace-kernel, kernel-serve]
areas: [kern, build, tests]
branch: [dev]
---

# Proposal: Port the kernel core to Zig, as an instance

Nov 25, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

h9's kernel is drawterm's `kern/`, about 7,000 lines of C that h9 vendors, with about 17,000 lines of h9's own C around it. This proposal ports the namespace core (channels, mount tables, the device switch, devmnt, queues, pipes, and the file system calls) to Zig, one file at a time, with the same behaviour. Errors become Zig error unions in place of `waserror` and `longjmp`. drawterm's Proc and h9's own process record become one. And a kernel becomes a value: `Kernel.init` makes one, a machine owns one, and nothing in it is process-global. drawterm stays in `third_party/` for what h9 doesn't port: devdraw, libmemdraw, the GUI backends, libsec, and the auth code. Nothing a guest can observe changes.

## Background

Borrowing drawterm's kernel was the fastest way to get exact Plan 9 namespace semantics, and it still gives them. What h9 has built on it since shows where it no longer fits.

- **`waserror` at the seam.** The kernel's error model is `setjmp` and `longjmp`, which can't unwind through Zig frames. [spec/kernel.md](../spec/kernel.md) has seven rules for the seam between the two, calls into Zig from C are leaves only, and every system call goes through a `sys*` wrapper layer that exists to catch errors on the C side.
- **Two process records.** drawterm's Proc has no parent, notes, segments, or environment group, because drawterm is a terminal. h9 keeps a second record (`src/kern/proc.c`, 1,800 lines) in step with it by hand, and notes live on h9's side because drawterm's `postnote` drops them.
- **One kernel per host process.** Every machine in a process shares one booted kernel. devsrv, the console, the clock, and the locks table each needed a per-machine table hung off `Hmach` to keep machines apart, and [host-cmd](host-cmd.md) found devcmd's conversation table shared between them. [child-machines](child-machines.md) and [namespace-kernel](epoch-0/namespace-kernel.md) each design around it.
- **No address checks, and a 32-bit `long`.** drawterm's `validaddr` does nothing, and offsets and counts pass through `long` in places where a guest's are 64 bits.
- **Patches to vendored code.** h9's changes to `third_party/drawterm/kern/` (policy hooks, the `#λ` exemption in `chan.c`, the readiness hook and the interruptible reader and writer locks in `qio.c`) have to be carried across every merge from upstream.

[namespace-kernel](epoch-0/namespace-kernel.md) and [kernel-serve](epoch-0/kernel-serve.md) come first because they make the kernel stand alone: a build with no engine, loaders, system call tables, or devproc, driven only over 9P. That build is the line this port works behind, and its suite is a second check on it.

## Proposal

### What's ported

| drawterm file | Becomes | Notes |
| --- | --- | --- |
| `chan.c` | `src/kern/chan.zig` | `namec`, `walk`, `cclose`, mount point crossing, and union lookups |
| `pgrp.c` | `src/kern/pgrp.zig` | Pgrp, Fgrp, Rgrp, and the mount table |
| `dev.c`, `devtab.c` | `src/kern/dev.zig` | The device switch and `devgen` helpers |
| `devmnt.c` | `src/kern/devmnt.zig` | The 9P client |
| `qio.c`, `allocb.c` | `src/kern/qio.zig` | Queues and blocks |
| `devpipe.c`, `devroot.c` | `src/kern/dev/` | With h9's own devices, as each is ported |
| `sysfile.c` | `src/kern/sysfile.zig` | The file system calls, with no wrapper layer |
| `qlock.c`, `rwlock.c`, `sleep.c` | `src/kern/sync.zig` | Over the host's primitives, as now |

Each is a close translation: the same functions, in the same order, with the same names where Zig allows, so a diff against 9front's `port/` still reads. h9's own C in `src/kern/` (`proc.c`, `linux.c`, `linuxnet.c`, and the devices) is ported after the core, a file at a time, and isn't required for this proposal to be done.

### Errors

A kernel function that can fail returns an error union. The error set is small (`error.Kernel` and `error.Interrupted`), and the Plan 9 error string is stored on the process, as `up->errstr` is now. `waserror` blocks become `errdefer` and `defer`. The seam rules, the leaf-only restriction, and the `sys*` wrappers go.

C that stays (devdraw and the GUI backends) calls into the kernel through a small exported API that returns an error code, and never runs under a `waserror` of the kernel's.

### One process record

`Proc` is one Zig struct with what both records have now: the Plan 9 fields (Pgrp, Fgrp, Egrp, Rgrp, notes, and wait queue), the parent and children, the segments or `Mm`, and the ABI's state. `src/kern/proc.c`'s bookkeeping to keep two records in step is deleted.

### A kernel is a value

`Kernel.init(gpa, host)` returns a kernel with its own process table, device instances, `#s` board, console, clock, and locks table. `Machine` owns one. Nothing in `src/kern/` is a global, and `Hmach`'s per-machine tables fold into the instance. Two machines in a process share nothing unless one is handed a channel into the other.

### Address checks and widths

Every pointer from a guest is checked against its address space before the kernel reads or writes through it, in one place. Offsets and counts are `u64` and `usize` throughout.

### What stays C

devdraw, libmemdraw, libmemlayer, the GUI backends, libsec, libauthsrv, and devtls and devssl stay drawterm's, built as a library and reached through the device switch. h9 stops patching `third_party/drawterm/kern/` for the files it ports, and stops compiling them.

## Rationale

**Why port and not wrap.** Each seam rule and each `Hmach` table is a wrapper, and each new feature has added more. The core is small, it's stable upstream, and h9 already owns more kernel C than it borrows.

**Why a close translation.** The value of drawterm's kernel is that it's 9front's code, so its behaviour at the edges (union directories, `..` across mounts, `ORCLOSE`, and flush) is right without anyone having to know why. A redesign during the port would lose that. Anything that changes behaviour is a later proposal: [scheduler](scheduler.md), [file-interface](file-interface.md), and [host-handles](host-handles.md) each depend on this one for that reason.

**Why Zig and not cleaner C.** The trouble is the error model, and C has no other. Zig's error unions and `defer` express the same cleanup without `longjmp`, the rest of h9 is Zig, and one language removes the seam instead of moving it.

**Why not track upstream.** 9front's `port/chan.c` and `devmnt.c` change rarely. A close translation keeps those changes portable by hand, and the pinned release in SPEC.md's decisions table already says which 9front h9 matches.

**Why after namespace-kernel.** It gives the port a build with only the core in it, and a client (Wanix) that exercises namespaces without an engine. Porting first would mean drawing that line twice.

## Compatibility

- **CLI, exit codes, sandbox defaults, and the root tree.** Unchanged.
- **`Machine` API.** `Machine.init` makes a kernel; there's no separate boot. Embedders that ran several machines in a process see no change except that they no longer share `#s` through a table.
- **Error strings.** The same strings, from the same places.
- **`third_party/`.** drawterm's ported files are no longer compiled or patched. They stay in the tree for reference and for merges.
- **[namespace-kernel](epoch-0/namespace-kernel.md)'s C API and `h9ns.js`.** Unchanged; the library behind them is Zig.

## Security

No new reach for a guest. Real address checks close a class of bug where a guest pointer was trusted. A kernel per machine removes shared tables that have already leaked state between machines once. The port is new code in the trusted base, so each ported file lands with its tests and with fuzzing of the paths that parse guest or 9P input (devmnt's replies, and `namec`'s paths).

## Done criteria

- [ ] `zig build test`, `zig build integration` on every engine, `zig build integration -Dweb`, and `zig build web-test` pass with no case removed or newly skipped.
- [ ] [namespace-kernel](epoch-0/namespace-kernel.md)'s cases pass against the ported core.
- [x] `zig build conformance` runs a script of namespace operations (binds, unions, mounts, `..` across mounts, creates in unions, `ORCLOSE`, and flush) on h9 and on a 9front kernel under QEMU, and the transcripts match.
- [ ] `git grep -l waserror src/` finds nothing, and the build compiles none of `chan.c`, `pgrp.c`, `dev.c`, `devmnt.c`, `qio.c`, `devpipe.c`, `devroot.c`, or `sysfile.c` from `third_party/drawterm/kern/`.
- [ ] `test "two machines don't share /srv [kernel-port]"` and `test "two machines don't share devcmd conversations [kernel-port]"` pass with two machines in one process.
- [ ] `test "a bad guest pointer is a fault, not a host crash [kernel-port]"` passes for read, write, and stat buffers.
- [ ] `zig build bench` shows system call round trips within 5% of before the port.
- [ ] [spec/kernel.md](../spec/kernel.md) describes the kernel as built, with no seam rules.

## Implementation

1. The conformance script and its 9front oracle, run against today's kernel, so the port has a target before it starts.
2. `qio` and `sync`, which have no dependents among the rest.
3. `dev` and the device switch, with C devices adapted through a shim that catches their errors.
4. `pgrp`, then `chan`, then `sysfile`.
5. `devmnt`, with fuzzing of its reply parser.
6. `devpipe` and `devroot`.
7. One `Proc`, and the removal of the second record.
8. `Kernel` as a value, and the removal of `Hmach`'s tables.
9. Address checks and widths.
10. The spec, and the end of the patches to `third_party/drawterm/kern/`.

## Open issues

- Whether the C devices h9 wrote (devoverlay, devdotl, devlinux, and the rest) are ported under this proposal or after it. As written, they're adapted through the shim in step 3 and ported later without a proposal, as internal refactors.
- Whether the 9front oracle runs in CI or only by hand. It needs QEMU and a 9front image, which `zig build mkroot` already uses.

## Updates

**2026-11-26, the conformance check.** `zig build conformance` runs [tests/conformance/ns.rc](../tests/conformance/ns.rc) on h9 and compares it with a transcript recorded on 9front, [tests/conformance/9front.out](../tests/conformance/9front.out), so it runs in CI and anywhere else with no QEMU, which settles the second open issue. `zig build conformance -- --oracle` records the transcript again: it boots the arm64 image that `zig build mkroot` boots, under QEMU (TCG is fine, and takes under a minute), and runs the script there. The script compiles a small C helper in the guest for `ORCLOSE`, which rc can't ask for, and tests flush by interrupting a read blocked in exportfs, through `srvfs`. Today's C kernel matches 9front's transcript on sud and hcpu, with no differences to note.

**2026-11-26, qio and sync.** `src/kern/qio.zig` (from `qio.c` and `allocb.c`) and `src/kern/sync.zig` (from `qlock.c`, `rwlock.c`, and `sleep.c`) are built in place of the C, under `src/kern/port.zig`, the root of the kernel's Zig, which the kern library and the namespace kernel compile. Some things the port found:

- **The C kernel's types come from translate-c.** `src/kern/port.h` is translated with the kernel's own `-D` flags, so `Lock` (a pthread mutex with `PTHREAD`), `Proc`, and `Label` have the C compiler's layout on every target. It reads `char Eintr[]` as a pointer, so error.c's strings are declared by hand, and on the web it needs `__wasm_exception_handling__` defined for wasi-libc's `setjmp.h`.
- **`lib.h` renames `sleep` and `wakeup`** to `ksleep` and `kwakeup`, which are the symbols C calls, and a `Proc`'s `sleep` field is `ksleep` too.
- **drawterm's `malloc` clears** (`kern/alloc.c`), so a `Queue` starts zeroed, locks included; the port allocates it with `mallocz(n, 1)`.
- **`tsleep` gains a form that returns.** qio's interruptible reader and writer locks wait in `tsleep`, so `src/kern/tsleep.c` has `h9_tsleepintr`, which returns -1 on a note, built on `h9_sleepintr`, the Zig sleep's form for C that returns, and `tsleep` raises from it. That removes a `waserror` from tsleep.c.
- **The `waserror` around `qread`'s and `qwrite`'s copies goes**: in 9front it catches a fault on a user buffer, and h9 copies guest memory outside the kernel.
- **Kick and bypass functions mustn't raise**, since they're called from the Zig. No caller in h9 sets either.
- **The blocking points** are `park` and `unpark` in `sync.zig` (posix.c's `procsleep` and `procwakeup`): qlock's queue, sleep, and so `qwait`, `qflow`, and `qlockintr` in qio, which each wait in one small function. [scheduler](scheduler.md) changes those two.

**2026-11-26, dev and the device switch.** `src/kern/dev.zig` is `dev.c`: the helpers, exported under their C names, and the switch the Zig calls devices through. Devices stay C `Dev`s in h9's own tables (`src/kern/devtab.c` and `nstab.c`, which stand for drawterm's `devtab.c`), so the switch calls a C device, or a C `Devgen` handed to `devwalk` and the rest, through `src/kern/devshim.c`: one small C function per `Dev` member, which runs the call under `waserror` and returns -1 with the error string on the process. Those are the only `waserror`s the Zig runs under. Some things the port found:

- **drawterm's `long` is `int`.** `lib.h` defines it so, and its `ulong` is `unsigned int`, so `qio.zig` had `qread`'s, `qbwrite`'s, and `readblist`'s counts as 64 bits where C passes 32; a C caller's count reached `readblist` with its upper half undefined. They're `c_int` now, and so is every `long` in the Zig.
- **`lib.h` renames `clone`** to `libclone`, so a `Walkqid`'s clone is `libclone` in the Zig.
- **`devwalk` raises only before its walk**: `isdir` comes before its `waserror`, so a walk from a file is an error, and a walk that fails at its first name is nil with the error string set. The Zig returns `Error!?*Walkqid` to say both.

**2026-11-26, pgrp, chan, and sysfile.** `src/kern/pgrp.zig`, `src/kern/chan.zig`, and `src/kern/sysfile.zig` are built in place of `pgrp.c`, `chan.c`, and `sysfile.c`. The file system calls have no wrapper layer: `sysfile.zig`'s functions return error unions, and the C names (`sysopen` and the rest) are adapters for the C that still calls them, which keep drawterm's `starterror`, `syserror`, and `enderror` contract (-1, the error in `syserrstr`, and `notepending` cleared on success). Their cases, and a fuzz case that hands `namec` any path, run in `zig build kern-test`. Some things the port found:

- **Zig's `c.malloc` doesn't clear.** drawterm's `malloc` (`kern/alloc.c`) does, and `chan.c` and `pgrp.c` count on it; a `Rgrp` with a stale lock word hung boot. The Zig allocates with `port.malloc`, which is `mallocz(n, 1)`.
- **`werrstr` stays C** (`src/kern/werrstr.c`), since it's variadic. Inside a Zig call `nerrlab` is 0, where drawterm's `sys*` had pushed a label, so `werrstr` and `%r` in C the Zig calls see `syserrstr`, not `errstr`. Nothing in the conformance or integration runs depends on it.
- **h9's hooks into `namec` and `walk` can raise**: the devfs policy's anchor check and `chanreadlink`, and so can `mntattach` until `devmnt.zig`. They're called through `devshim.c`, like the device switch.
- **Blocking**: `sysrendezvous` waits with `sync.zig`'s `park` and `unpark`, so the only blocking points are still those two.

**2026-11-26, devmnt.** `src/kern/devmnt.zig` is `devmnt.c`, built in its place, and the first native device: `dev.Native` makes a C `Dev` from a device's Zig functions (each wrapped to raise, for C that calls the table), and the switch calls the Zig functions directly, so a 9P call from the Zig runs under no `waserror`. `sysfile.zig` calls `mntattach` directly, and its shim is gone. Its cases mount a small 9P server on a pipe, and two fuzz cases cover the Security section's server replies: `mntrpcread` takes any bytes from a server, and `mntdirsfix` any directory read. Some things the port found:

- **A short `Rread` crashed the reader.** drawterm's `mntrpcread` pulls up an `Rread`'s 11-byte header before checking that the message is that long, and `pullupqueue` frees what's queued and returns nil when the queue is shorter than that, so a 7- to 10-byte `Rread` that ends a server's stream was a nil dereference. The Zig pulls up no more than the message, which `convM2S` then rejects.
- **`mntwalk` keeps its two kinds of failure**: too many names is an error, and anything after (the server's error, a note, a bad reply) is nil with the error string set, as its `waserror` returned.
- **Blocking**: a reply is waited for in `sync.zig`'s `sleep`, so it parks; `mountio`'s loop of flushes after a note is a loop over the attempt, without labels.

**2026-11-26, devpipe and devroot.** `src/kern/dev/pipe.zig` and `src/kern/dev/root.zig` are `devpipe.c` and `devroot.c`, native devices, so the build compiles none of the eight files the Done list names from `third_party/drawterm/kern/`. The `-Dpostnote=h9_postnote` build of `devpipe.c` is gone: the Zig calls `h9_postnote` itself. A native device's own `Devgen` doesn't raise, and the switch calls it without the shim. Some things the port found:

- **`pipeopen` checks its mode before it counts the open.** drawterm's calls `openmode` (which can raise `Ebadarg`) inside the pipe's lock, after `qref` is counted; the Zig calls it first, so a bad mode leaves no lock held and no open counted.
- **`#/boot` isn't `/boot`**: `namec` reads `boot` there as the root device's spec, as Plan 9 does. The root device's cases reach its boot files through `/boot`.
- **The Windows build**: `kern-test` links the namespace kernel, which built only for POSIX, so `zig build test` failed on Windows from step 2 on. The namespace kernel now builds for Windows as the kern library does, without its host descriptor features (`fd!` dials, `h9ns_serve`, and `h9ns_addfd`), which are POSIX's.


**2026-11-26, one Proc.** A process is one record: `Proc`, defined by h9 in `src/kern/h9proc.h`, which `dat.h` includes in place of drawterm's (a one-line patch, until step 10 ends them). It has drawterm's fields, then what was `Hproc`'s, and `proc.c`'s table, `lookup`, and `newhproc` are gone: `up` is the record, and each machine keeps a list of its processes (`Hmach.procs`) for pid lookups, `/proc`, and note groups. drawterm's `procinit.c` (`newproc`, `kproc`, and `pexit`) moved into `proc.c` and isn't built from drawterm. Some things the port found:

- **The record outlives its thread.** A parent's wait records, `/proc` readers, and an interval timer's `selfref` all hold the process after it exits, so `Proc` is counted, and `pexit` drops the thread's reference instead of freeing it. What was `h->p == nil` (the thread is gone) is `exited`, set under `debug` and `nlk`, so a note or a `ctl kill` to an exited process is dropped as before.
- **`pid` is the machine-local pid.** drawterm's was a host-wide counter that only diagnostics printed; a kproc's is 0. `text` is the longer of the two (64 bytes).
- **drawterm's `mach` field is gone.** Only `sysrendezvous` read it, spinning until the woken process left its CPU, which a Proc with its own thread never occupies; `sync.zig`'s `unpark` copes with a process that hasn't parked yet.
- **What the scheduler needs.** `Proc.cont` is reserved for [scheduler](scheduler.md)'s continuation; `up` is still the host thread's (posix.c's `_setproc`).
- **The address space stays on the ABI's record.** A 9front process's two Mms (`segment.Space`, shared and stack) and a Linux process's one are reached through `Proc.aux`, `src/machine.zig`'s Proc, which the kernel's C never reads. Moving them onto `Proc` waits for `proc.c` to be Zig.


**2026-11-26, a kernel is a value.** `kern.Kernel` (`src/kern.zig`) is made with `Kernel.init(gpa, host)`, which takes the machine's `Host` ([host-handles](host-handles.md)) and only holds it until host-handles' later steps move devices onto it, and processes are started in it with `Kernel.spawn`. Its C half is the `Hmach` it makes, which already held the `#s` board and now holds the process list (step 7), and the settings `#ℓ`, `#ι`, and host streams' redials looked up in three host-wide tables keyed by machine are fields of the `Kernel`. `test "two machines don't share /srv [kernel-port]"` runs two kernels in one process. Some things the port found:

- **A kernel lives for a run, not for the `Machine`.** The Compatibility section has `Machine.init` make it, but a `Machine` can run several programs, and what a kernel holds (the `#s` board, the host streams) must go when a run's processes do, while the run's pages are still there to free what they hold. `Machine.run` makes one and deinits it after its processes have ended. Moving it to `Machine.init` needs those per-run resources to belong to the run instead.
- **The per-machine tables had 64 slots.** A host process's 65th concurrent machine got no `#ℓ` user, no `#ι` cache, and no redial options, silently. On the `Kernel`, there's no limit.
- **The `Kernel` can go before its processes.** The `Hmach` is counted (one for the `Kernel`, one per process), and `deinit` clears its pointer to the `Kernel` under its lock, so a lookup after `deinit` finds no settings. A lookup that started before it could still read the freed `Kernel`, so `Machine.run` deinits only once its processes have ended.
- **Kernel threads that aren't a machine's** (the interval timers' process) get a kernel of their own with no host, through `kern.spawnAlone`, as they had an `Hmach` of their own before. The namespace kernel makes one `Kernel` for the host process.
- **Not yet per kernel**: the boot Proc, the device table, the timer kproc, and the semaphore table, which are the host process's, and the C devices' fixed tables that every machine's entries share: `#ℓ`'s, `#ι`'s, and `#ℓ` streams' conversations, `#y`'s consoles (which its attach spec names by number), the ptys, and the Linux futex waits. A busy machine can use up another's share of those, and `#y` is reached by number rather than through the kernel. They move onto the `Kernel` as each device is ported.
- **devcmd isn't built.** Host commands live on the `host-cmd` branch while [host-cmd](host-cmd.md) is rethought, so `test "two machines don't share devcmd conversations [kernel-port]"` waits for devcmd to be built again, and that Done item stays open.

**2026-11-26, proc, devproc, glue, and ns.** h9's `proc.c`, `devproc.c`, `glue.c`, and `ns.c` are Zig: `src/kern/proc.zig`, `src/kern/dev/proc.zig` (a native device), `src/kern/glue.zig`, and `pgrpcpy` in `src/kern/pgrp.zig`, where 9front keeps it. Each C name is exported with the C's contract, so `h9_kern_rfork`, `h9_kern_fork`, `h9_kern_await`, `h9_fd2path`, and `h9_fauth` still return -1 with the error on `syserrstr`, and `h9_uphproc` and `h9_upegrp` still raise for their C callers. Some things the port found:

- **Three calls into C that can raise stay behind a shim**, `src/kern/procshim.c`, until their files are Zig: devenv's `h9_egrpnew` and `h9_egrpcopy` (Enomem), and the function `h9_kern_isolated` runs (gfx.c's screen setup), whose error is raised again once the Proc's own groups are back.
- **devproc's Devgen raises** when the caller isn't a guest process, as the C's did, so it isn't among the device's own Devgens that the switch calls directly; it goes through `devshim.c` as a C device's does. Its ctl messages use drawterm's `parsecmd`, which doesn't raise, and a Zig `lookupcmd`.
- **A failed device reset or init at boot is a panic** with its error string, where `h9_kern_boot` raised with no label to catch it.
- **`port.nskernel`** says whether the build is the namespace kernel, which has no devproc, so the switch lists `dev/proc.zig` only in the full kernel.

**2026-11-26, h9's own C: tsleep, sema, devhcons, fifo, rootdial, devenv, devhstream, and devhidx.** Toward the Done item that `git grep -l waserror src/` finds nothing, these eight are Zig, each built in place of its C: `src/kern/tsleep.zig`, `sema.zig`, `fifo.zig`, and `rootdial.zig`, and the native devices `src/kern/dev/hcons.zig`, `env.zig`, `hstream.zig`, and `hidx.zig`. Their C callers keep the exported names. Some things the port found:

- **The calls into h9's Zig took 64-bit counts and ids.** `src/kern.zig`'s console calls, `src/hstream.zig`'s, and `src/rootindex/kern.zig`'s take `c_long` and `c_ulong`, where devhcons.c, devhstream.c, and devhidx.c declared them with drawterm's `long` and `ulong`, which are 32 bits, so a count reached the Zig with its upper half undefined, as `qio.zig` found for its own. Called from the Zig, the types agree.
- **The namespace kernel is `port.nskernel`**, from `H9_NSKERNEL` through translate-c. #y, #e, and #ι aren't in its device table, and nstab.c stubs what they export, so they're natives and exported only outside it; their cases run in `kern-test` on a fake console, a group of their own, and chans made by hand.
- **A native Devgen can't raise, but #e's, #ℏ's, and #ι's read the caller's group or machine**, which proc.c raises without. Their walk, stat, and directory read look first, so the error is there, and the Devgen reads it again without failing. A walk that never reaches such a directory doesn't look, as the C didn't.
- **C that the Zig calls and that can raise**, the overlay's `h9_overlay_lower`, goes through a new shim in `devshim.c`. With proc, devproc, fscheck, and devenv all Zig, #e asks `proc.zig` for the caller's group, `fifo.zig` asks `fscheck.zig` whether a chan is a FIFO's, and `proc.zig` makes, copies, and drops groups through `dev/env.zig`, each directly; `procshim.c` keeps only the call that `h9_kern_isolated` makes for gfx.c.
- **`h9_hidx_convstatus` raised outside a label** for a process with no machine (its `lookup` called proc.c's `uphproc`), from `src/kern.zig`, which calls it with no `waserror`. It returns -1 now.
- **Zig has no thread fence**, so sema.c's `coherence()` calls are comments: what they ordered (the semaphore word, `Sema.waiting`, and in `rendezvous` the process's state and `notepending`) is read and written as sequentially consistent atomics.
- **A kproc ends by returning**: every host's trampoline (`posix.c`, `win32.c`, and `os-wasm.c`) calls `pexit` after its function, so #ι's reader doesn't call it from Zig frames.
- **`dev.Native` takes the device's character as a `c_int`**, `Dev.dc`'s type: ℏ and ι don't fit a byte.


**2026-11-26, devsrv, devlinux, linux.c, and kserve.** `src/kern/dev/srv.zig`, `src/kern/dev/linux.zig`, `src/kern/linux.zig`, and `src/kern/kserve.zig` are built in place of `devsrv.c`, `devlinux.c`, `linux.c`, and `kserve.c`, so none of h9's four uses `waserror`. devsrv and devlinux are native devices; kserve is built in both kernels, and devlinux and linux.zig only in the kern library (`port.nskernel` says which), since the namespace kernel has no Linux view and `src/kern/nstab.c` stands in for linux.c's hooks there. Some things the port found:

- **A native device's Devgen can fail.** srvgen checks permission when a walk steps into a board, and devlinux's Devgen finds the caller's machine, which fails for a process that isn't h9's (`h9_uphproc` raised). `dev.zig`'s `Ops` has `egens`, Devgens whose Zig returns an error union, which `callgen` calls directly; their C form raises. `port.uphproc` is `h9_uphproc` for Zig, and `port.h` includes `hproc.h`, so the Zig sees `Hmach`.
- **devfs's syncs still raise** (`h9_fs_syncfs` and `h9_fs_sync`), so `h9_linux_syncfs` and `h9_linux_sync` call them as a C Devgen is called, through `callgen` and the shim's `waserror`, until devfs is ported.
- **The Linux ABI declared drawterm's `long`s as 64 bits.** `src/abi/linux/kc.zig` had `h9_linux_ppid`'s result, `h9_linux_chanpread`'s count and result, `h9_linux_await`'s `want`, and `h9_linux_setcputime`'s arguments as `c_long` and `c_ulong`, where C has 32 bits; they're `c_int` and `c_uint` now. Its `Gen`, devlinux's text hook, still takes the pid as `c_ulong`.
- **kserve leaked a channel on two error paths**: a failed clone after `Tcreate`'s create, and a failed `cunique` in `Tremove`. The Zig closes it.
- **Not yet per kernel**: the futex queues, as before.

**2026-11-26, devoverlay.** `src/kern/dev/overlay.zig` is h9's `devoverlay.c`, built in its place, and a native device: the switch calls its walk, open, read, and the rest directly, and the device's optional operations, `readlink`, `symlink`, `getattr`, and `rename`, are optional fields of `dev.Ops` in place of its `Devx` entry, so `overlaydevx` is gone from both device tables. Its 78 `waserror`s are error unions, and the `h9_overlay_*` functions called by those names (from `src/kern.zig`, `chan.zig`, and the devns and devproc ports) raise at that boundary where the C did, or keep their error-string contract. `fifo.zig` and `fscheck.zig` call its `lowerof`, `mkfifo`, and `isfifo` directly, so `devshim.c` loses `h9_shim_overlay_lower` and `h9_shim_overlay_mkfifo`, and `h9_overlay_lower`, `h9_overlay_mkfifo`, and `h9_overlay_isfifo` aren't exported. Its cases build a copy-on-write tree over an in-memory instance, a union with a whiteout, and a union with an up layer. Some things the port found:

- **A FIFO in a host layer** is made through `devshim.c`'s `h9_shim_fs_mkfifo`, as `fscheck.zig` makes one, since devfs's `h9_fs_mkfifo` raises. A union's `isfifo` asks `fscheck.zig`'s `chanisfifo` about the member that holds the name, an error union where the C raised.
- **A failed union attach dropped its instance twice.** When `untop` failed, `unattach`'s `waserror` closed the `Unc`, which dropped the instance, and then dropped it again. The Zig frees the `Unc` without the second drop.
- **`isunion` read a control chan's aux as an `Unc`.** A chan on the clone tree has no union state, so a walk or stat that asked was reading a `Ctl`. It's false for those now.
- **Errors that left a lock held or a copy behind.** Several C paths raised from inside the instance's `QLock` and relied on an outer `waserror` that didn't unlock, or leaked a half-made node or a cloned member chan; with `defer` and `errdefer` each is released on the way out. `unaddmember` clones its member before taking the lock.

**2026-11-26, devdotl.** `src/kern/dev/dotl.zig` is h9's `devdotl.c`, `#ℓ`, built in its place as a native device, so it raises nothing and has no `waserror`. Its reader kproc is Zig too, and reads and writes the server connection through the switch. Its cases make a conversation and check its ctl's messages, and mount devmnt's 9P2000 test server through one, which the translator passes through. Some things the port found:

- **Its dials call the Zig directly**: `rootdial.zig`'s unix socket dial for a root's `unix!` and `dev/hstream.zig`'s WebSocket dial for a redial.
- **A conversation was made under two locks that an error left held.** `newconv` looked up the caller's machine under `convlk` and the conversation's lock, and that lookup raises "not an h9 process" for a process with no machine. The Zig looks it up first. For such a process, a listing of `dotl` is now empty and a walk to a conversation fails with "does not exist", where the C raised; it can't make a conversation, so it never has one to see.
- **An open with a bad mode leaked a conversation.** `dotlopen` counted the open (or made the conversation, for `clone`) before `openmode` could fail, and a failed open isn't closed. The Zig checks the mode first, as `pipeopen` does. The directories and `status` still fail a write open with `Eperm` before the mode is checked.
- **The translator's leaves take 64-bit counts** (`c_long` in `src/dotl/kern.zig`), where C passed drawterm's `long`, a C `int`, so their upper halves, and a `user` uid's, were undefined. The Zig passes them whole; the uid is still cut to 32 bits, as C's `strtol` into a `long` cut it.
- **Not yet per kernel**: the 256 conversations are still the host process's, shared by its machines, as the Kernel note above lists.
