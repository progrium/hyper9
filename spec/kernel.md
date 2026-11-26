# The kernel and the process model

This describes, as built, how Plan 9 processes are run and what h9's kernel is: Zig, ported from drawterm's `kern/` and 9front, with what h9 adds to it, and the drawterm C it still builds. [SPEC.md](../SPEC.md) describes h9 as a whole and lists the rest of the spec.

## Contents

- [Process model](#process-model)
  - [Threads](#threads)
  - [Several machines per host process](#several-machines-per-host-process)
  - [Notes on blocked and running processes](#notes-on-blocked-and-running-processes)
  - [vCPU limits](#vcpu-limits)
- [Kernel: h9's Zig and drawterm's C](#kernel-h9s-zig-and-drawterms-c)
  - [drawterm's C](#drawterms-c)
  - [Added by us](#added-by-us)
  - [Errors, calls across the edge, and guest memory](#errors-calls-across-the-edge-and-guest-memory)

## Process model

Each CLI invocation is one machine: one host process with one VM. Each Plan 9 process is a drawterm Proc with a kernel continuation, and a machine's executors run them ([scheduler](../design/scheduler.md); see Executors below). Because every process lives in one VM and one kernel, rfork never has to serialize state across host processes. hyper-linux has to, because it can only use one VM per host process.

| Plan 9 call | Implementation |
| --- | --- |
| `rfork(RFPROC)` | New Proc, queued on an executor, and the address space forked copy-on-write (see Memory below) |
| `rfork(RFMEM)` | Share the text, data and bss, and segattach's `memory` segments; fork only the stack copy-on-write |
| `RFNAMEG` / `RFFDG` / `RFENVG` / `RFNOTEG` / `RFREND` | Share or copy drawterm's Pgrp, Fgrp, Egrp, note group, and rendezvous group |
| `exec` | Map the new a.out into a fresh address space, its text and data filled from the file on first touch, reset registers, keep the fds (honouring close-on-exec) and segattach's segments (except `SG_CEXEC` ones) |
| `exits` / `await` | Wait records queued on the parent Proc; the continuation ends and its executor takes the next process |
| `brk_` | Grow the data segment by an anonymous mapping whose pages come on first touch, up to the stack's floor or the lowest attached segment above it |
| `segattach` / `segdetach` | Attach or detach a `shared` or `memory` segment, up to five per process, with 9front's placement rules; a `memory` segment's pages come on first touch and a `shared` one's are allocated when it's attached, and neither is executable ([segattach](../design/epoch-0/segattach.md)) |
| `segbrk` / `segfree` / `segflush` | Grow or shrink an attached segment's mapping; drop its pages (a `shared` segment's are zeroed in place); check the span and tell the engine the code changed |
| `notify` / `noted` | Push a Ureg and the note string onto the user stack and point the PC at the handler; `noted` restores or kills the process |
| `/proc/n/ctl` `stop` / `start` / `hang` | Park the process on its own thread at its next stop point (syscall entry, note delivery, a breakpoint exit, or before the first instruction after `exec` with `hang`), with its Ureg and Extra copied to its record ([self-host](../design/epoch-0/self-host.md)) |
| `rendezvous` / `semacquire` / `tsemacquire` / `semrelease` | Host kernel primitives built on drawterm's sleep/wakeup (`src/kern/sema.zig`): 9front's `rendezvous` on drawterm's rendezvous group, and 9front's semaphores, with the wait lists in a kernel-wide table keyed by the host address of the guest word; `tsemacquire` waits with `tsleep` ([semaphores](../design/epoch-0/semaphores.md)) |

### Threads

The kernel boots once per host process, on a private thread, because booting turns the calling thread into a Proc for good. Every guest process then runs on a kernel thread made by `h9_kern_spawn` in `src/kern/proc.zig`, which works like drawterm's `kproc` but can be called from a thread that isn't a Proc: it clones from the boot Proc, and the new thread sets up its groups once `up` is set.

On a machine with executors (every native build; the web host keeps a thread per process until it has them), `h9_kern_spawn` and `rfork` don't start a host thread: they hand the new Proc to the machine's scheduler (`Hmach.schedstart`), which runs its exit loop on a continuation. `Machine.run` starts the first process this way and waits for it to exit. A process forked with `RFHOSTTHREAD`, h9's own 9P and pty servers, gets a host thread of its own, as every process does on the web host, and that thread creates its vCPU, which HVF binds to its creating thread.

### Executors

A machine has `--cpus` executors (`src/executor.zig`), each a host thread with one vCPU, and a monitor thread. An executor takes a runnable process from its run queue, the machine's queue, or another executor's (it steals when its own is empty), loads the process's registers, FP state, and address space into its vCPU when another process ran there last, and runs it to its next exit. On sud a process keeps a vCPU of its own, a stub thread, since the stub's FP state is wider than what's saved, and the executor runs that.

A kernel call runs on the process's continuation (`src/kern/sched/`), on the executor's host thread. A call that waits parks: sync.zig's `park` and `unpark` are the one place a process waits and is let go, and qio, devmnt, `tsleep`, `rendezvous`, the semaphores, and qlocks all wait through them, so the executor goes back to its queue and any executor resumes the process when it's readied. A continuation takes a kernel stack from a pool when it parks and gives it back when it resumes; `up` is set again on each switch in, since the host thread may differ. Kprocs and processes on host threads of their own wait in posix.c's `procsleep`, as before.

A process runs for a 10 ms slice. The monitor checks every 2 ms: a run past its slice while others wait is kicked, ends with `interrupted`, and the process yields to the back of the queue. An executor that has been in one kernel call for 20 ms (a host read or a DNS lookup that blocks the thread, or a poll loop with `osmsleep`) is handed off: the monitor starts another executor in its place, and the blocked one retires when its call returns, so blocking host calls never stall the queue. Per-thread CPU time (`getrusage`, `/proc/n/status`) is the process's own, counted across switches.

### Memory

Every process's memory, 9front's and Linux's, is an `Mm` (`src/kern/mm.zig`, [memory-model](../design/memory-model.md)): a sorted list of mappings over 64 KiB chunks that are allocated on first touch, forked copy-on-write, and filled from a file when the mapping has one. Faults, the host's reads and writes of guest memory for a syscall, `--memory` accounting, and the engine's map and unmap calls are its, once for both ABIs; the Linux ABI adds its layout, `mmap`'s flags, and `brk` (see Linux ABI, Memory).

A 9front process's address space (`segment.Space`, `src/segment.zig`) is two Mms in one engine address space: one holding text, data, bss, the heap, and segattach's segments, which `RFMEM` siblings share and which is mapped into each of their address spaces, and the process's own stack. `rfork` without `RFMEM` forks both, so what `RFMEM` siblings share is still copy-on-write for a plain fork child, as on 9front. Text and the initialized part of data are private mappings of the a.out, filled from a copy of its bytes on first touch; bss, the heap, and the stack (its whole 16 MiB) are anonymous; and a `shared` segment is a shared mapping with its own pages, so fork shares them even in a chunk that private mappings also use. Each mapping carries its segment's class and slot as a label, which `/proc/n/segment`, `segbrk`, and `segdetach` go by. `segment.zig` keeps only what's Plan 9's own: segment names and classes, segattach's placement, and the `seg*` calls and `/proc/n/segment` as calls on the Mms.

The boot also starts one kernel thread of its own, the timer kproc (`src/kern/tsleep.zig`), which idles on a host condition variable until the earliest `tsleep` deadline.

### Several machines per host process

An embedder, or the test suite, can run several machines in one host process. Each run of a `Machine` has a kernel of its own, `kern.Kernel` (`src/kern.zig`, [kernel-port](../design/kernel-port.md)), made with `Kernel.init(gpa, host)` from the machine's `Host` and spawned into with `Kernel.spawn`: its process list, pids, note groups, `#s` board, and `/proc` are its processes' alone, and so are the settings #ℓ, #ι, and host streams look up for it (they were tables keyed by machine, of 64 entries). Its C half, `Hmach` (`src/kern/hproc.h`), is counted, so processes and host streams can outlive the `Kernel`, and find no settings once it's gone. Each machine's first Proc starts with a fresh Pgrp, Fgrp, and Egrp, so each has its own namespace, device mask, console, and environment. The host threads, the boot Proc, the device table, and the timer kproc are still the host process's, as are some C devices' tables, which every machine's entries share (`#ℓ`'s, `#ι`'s, and `#ℓ` streams' conversations, `#y`'s consoles, the ptys, and the Linux futex waits). The CLI always runs one.

### Notes on blocked and running processes

A note to a process blocked in a host syscall wakes it through drawterm's sleep/wakeup, and the syscall fails with "interrupted" (`rendezvous` returns `~0` instead, as on 9front). A note to a process running guest code kicks its vCPU, and the note is delivered at the exit.

Pending notes are queued on the process record by `pushnote`: drawterm's `postnote` keeps only `notepending`, which `enderror` clears after every failed syscall, so it serves only as the "interrupt this call" flag.

Because calls clear that flag as they return, a note posted while one call is finishing would be lost to the next call if the guest made one straight away; the exit loop re-arms the flag when it starts a call with a note flagged, and `pushnote` kicks before it interrupts, so a call started before the kick's flag is set still sees the interrupt.

### vCPU limits

Each process runs on one vCPU at a time, and hypervisors cap the live vCPUs per VM (`hv_vm_get_max_vcpu_count` on HVF, `KVM_CAP_MAX_VCPUS` on KVM). On HVF a vCPU is bound to its thread, so a process past the cap can't simply borrow one: it needs pool threads that run the guest on its behalf.

Measured on an M3 Max (macOS 15.8.1, 14 cores): `hv_vm_get_max_vcpu_count` reports 64, and the 65th live `hv_vcpu_create` fails with `HV_NO_RESOURCES`. Destroyed vCPUs free their slots, and a create takes about 120 µs. The emulator's limit is its own, 64 ([jit.md](jit.md#the-hcpu-engine-hcpu)).

So on HVF 64 is a hard cap on *live* processes, not just running ones, and a pipeline of 65 stages or `mk -j` with many jobs reaches it.

KVM in a nested x86\_64 VM (Linux 6.12, Intel VT-x) reports 1024, and recycles its vCPUs (see KVM above), so its limit is on live vCPUs too; with fewer file descriptors it reports less.

With executors a machine uses only `--cpus` vCPUs (one per process on sud, which has no limit), so the cap doesn't apply. On the web host, where each process has a host thread, the answer (`src/cpupool.zig`) is a hybrid. A process creates and owns its vCPU on its own thread, as before, while the machine owns fewer than the limit less a reserve of 8.

Processes beyond that run guest code through a pool of 8 pool threads, each with a vCPU: the process thread hands its Ureg, FP/SIMD registers, and thread pointer to a pool thread, which runs the guest to its next exit and hands them back. Kernel calls stay on the process's own thread, so pool threads never block in the kernel and the pool always makes progress.

A handoff costs two thread wake-ups per syscall, so only the processes past the first 56 pay it.

`--cpus` caps how many vCPUs run guest code at the same moment, owned or pooled, on every engine. Runs take slots in ticket order, so a process that exits for a syscall and runs again queues behind the others, and a run waiting 5 ms with no slot freed kicks the run that has held one longest, which ends with `interrupted` and queues again, so guest code that makes no kernel calls (a spinning goroutine) can't keep the rest out.

The emulator and the sud engine have no vCPU limit, so every process owns an engine or a stub thread there.

## Kernel: h9's Zig and drawterm's C

The kernel is h9's Zig, in `src/kern/` ([kernel-port](../design/kernel-port.md)): the namespace core (channels, mount tables, the device switch, devmnt, queues, pipes, and the file system calls), ported from drawterm's `kern/` as close translations, and h9's own devices and process model. Its file system calls already have Plan 9's semantics, so most syscall handlers are a decode followed by one call.

### drawterm's C

h9 vendors 9front drawterm (`third_party/drawterm`, a squashed subtree), and still builds from its `kern/` the C that isn't ported: devcons (for everything but `cons` itself), devdraw, devkbd, devmouse, devaudio, devtls, devssl, the allocator, error strings, the OS layer (`posix.c` or `win32.c`), and drawterm's libraries (libc, libdraw, libmemdraw, libmemlayer, libsec, libmp, libip, libauthsrv) and GUI backends. It doesn't build `kern/devtab.c` or `kern/devenv.c`, whose own versions are `src/kern/devtab.c` and `src/kern/dev/env.zig`, `kern/procinit.c` (in `src/kern/proc.zig`), or any file the port replaced (see Ported to Zig), and h9 doesn't patch those: they're as upstream has them, for reference and for merges. Nor does it build the host's devices, devfs-posix, devfs-win32, devip, devip-posix, devip-win32, devlfd-posix, and devlfd-win32, which are h9's own in `src/host/` (see The host's devices).

The patches h9 still carries are small and marked: `dat.h` includes h9's `Proc` (`src/kern/h9proc.h`) in place of its own and has `Chan.srvname`; and devcons calls h9's hooks for `pid`, `ppid`, the clock, and `sysstat` (see devcons hooks). `win32.c` is upstream's: the host's C reads a Windows error through `src/host/hostsock.h`'s `oserrstr`, which is `src/host/win32.zig`'s, so a socket error reads as POSIX names it and a system message has no closing period.

#### The host's devices ([host-handles](../design/host-handles.md))

The devices that reach outside the machine are in `src/host/`, native devices the kernel's switch names through the `host_dev` module (`src/host/devices.zig`), which imports the kernel's Zig in turn. They're close ports of drawterm's C, with h9's changes to it:

| Device | File | Does |
|---|---|---|
| `#U` | `src/host/devfs.zig`, with `devfs_posix.zig` (POSIX and the web host) and `devfs_win32.zig` | the host's trees, each file opened beneath the machine's directory handle that holds it (`src/host/dirs.c`), with the policy's checks (`src/host/fscheck.c`), h9's FIFOs, links, attributes, and syncs |
| `#I` | `src/host/devip.zig` | the host's network: drawterm's devip, with the dialer's and listener's checks, nonblocking connects, `shutdown`, socket options, and the Linux layer's calls; its socket layer is `src/host/ipsock-posix.c`, `ipsock-win32.c`, and `ipsock-wasm.c` (drawterm's `so_` calls, which raise), and `hostsock-*.c` (h9's) |
| `#φ` | `src/host/devlfd.zig` | a host descriptor, or a `HANDLE`, read and written as it is: unix socket servers, embedders' descriptors, and drawterm's `oscmd` pipes. drawterm names it `#L`, which the Linux device has |

The rest of the host's code is there too: the GUI backends (`gfx-cocoa.m`, `gfx-headless.c`, and `gfx-web.c`), the Windows glue (`glue-win32.c`), the host interfaces for netlink (`hostif-posix.c`), and the host's C headers (`src/host/glue.h`, which `src/kern/port.h` includes), so nothing under `src/kern/` includes a host OS header.

### Added by us

Each piece below is new in h9, with the reason it's needed.

#### Process model (Proc fields, segments, rfork/exec/await, notes)

drawterm only ever ran its own kprocs. A process is one record, `Proc`, defined by h9 in `src/kern/h9proc.h`, which drawterm's `dat.h` includes in place of its own: drawterm's fields, then what 9front's Proc has and drawterm's lacks (the Egrp, the machine and its list, the machine-local pid, the note queue, the parent and wait records, and debugging state), and a pointer to the ABI's state (`src/machine.zig`'s Proc, with the address space). It's counted: the thread holds a reference until `pexit`, a child holds its parent's, and a lookup by pid takes one. drawterm's `procinit.c` (`newproc`, `kproc`, and `pexit`) is in `src/kern/proc.zig`, and isn't built from drawterm. `proc.zig` is Zig, with error unions; its C names keep the C's contract, and the one C call it makes that can raise (the function `h9_kern_isolated` runs, gfx.c's screen setup) goes through `dev.zig`'s `raising`, as a C device's calls do. A kproc has no machine, and its pid is 0.

#### `src/kern/devtab.c`

The device table, listing drawterm's devices plus ours.

#### Per-machine console device `#y` (`src/kern/dev/hcons.zig`)

drawterm's `#c/cons` reads and writes the host's fds 0 and 1 directly. `#y<id>`, a native device ([kernel-port](../design/kernel-port.md)), serves machine `id`'s `Stdio` through calls into `src/kern.zig` that return -1 rather than fail, and is bound before `#c` on `/dev`, so `/dev/cons` is ours and the rest of `#c` stays visible. It also has `/dev/stderr`, which the guest's fd 2 is opened on, so fd 2 reaches the host's stderr.

#### devenv `#e`, from 9front (`src/kern/dev/env.zig`)

drawterm's has one machine-wide environment and imports the host process's environment on first attach, which breaks `env.scrub`. 9front's keeps one environment per Egrp, which `RFENVG` needs anyway. drawterm's Proc has no `egrp`, so h9's (`src/kern/h9proc.h`) has one. `#ec` isn't supported.

#### devproc `#p`, from 9front (`src/kern/dev/proc.zig`)

rc, kill, and ps need `/proc/n/{note,notepg,noteid,ctl,status,ns,fd,args,ppid,wait}`, and `segment` is served too; acid also needs `mem`, `regs`, `fpregs`, and `text` ([self-host](../design/epoch-0/self-host.md)).

It serves h9's process records (`Proc`, in `src/kern/h9proc.h`, with `src/kern/proc.zig`'s functions declared in `src/kern/hproc.h`), from each machine's list of processes rather than 9front's Proc table: a qid holds the machine-local pid, and every walk, open, read, and write looks it up in the caller's machine, so a machine can't see, signal, or kill another's processes. It's a native device (`dev.Native`); its Devgen raises for a caller that isn't a guest process, as the C's did, so the switch calls that one through `raising`, as a C device's. Its ctl messages are parsed with drawterm's `parsecmd` and a Zig `lookupcmd`.

`status` has the 12 fields `ps` reads: the user is the machine's user (the guest's `$user`), the state is the syscall being served (as 9front's `psstate`, so `Await`, `Sleep`, `Pread`) or `Running`, memory is the bytes of the process's pages that are allocated (shared pages count in each process that maps them), and the user and system times read 0 until there's per-thread CPU accounting.

`segment` lists the stack (its whole 16 MiB), text, data up to the break, and segattach's segments (`Shared`, or `Bss` for `memory`) in 9front's format, with the number of address spaces each is attached to.

`ctl` takes `kill` (the process dies with `Killed` at its next note delivery, handler or not), `hang`/`nohang` (`exec` then stops the process before its first instruction), `close`, `closefiles`, and acid's `stop`, `start`, `waitstop`, and `startstop`; a stopped process reads `Stopped` and a waiting debugger `Stopwait`.

`mem` translates through the target's address space; writes, and `regs` and `fpregs` writes, need the process stopped. `regs` reads while the process is stopped or in a syscall, `fpregs` only while it's stopped, laid out as 9front's `FPsave` (520 bytes on arm64, the 512-byte FXSAVE on x86).

`text` opens the file the process executed (the interpreter, for a `#!` script). Unmapped addresses fail with "bad address" and missing register state with `Enoreg`.

A process may `stop` itself while a debugger waits on it, which 9front refuses with `Einuse`; acid's `new()` doesn't need it, but the integration fixture does.

`ns` prints the mount table as 9front does, so binds of host trees show their host paths; `--print` lists this as a caveat.

A process takes its record's `debug` lock to swap its fd group, namespace, or dot (rfork, chdir) and to mark itself gone at exit, so `fd` and `ns` readers can hold references to them.

#### devdup `#d`

Serves `/fd/N`.

#### The Linux view `#L` (`src/kern/dev/linux.zig`, `#λ` before [mounts](../design/epoch-0/mounts.md)), eventfds `#ε` (`src/kern/dev/eventfd.zig`), and ptys `#τ` (`src/kern/dev/pty.zig`)

A Linux process's `/`, its eventfd, epoll, and signalfd instances, and its pseudoterminals (see Linux ABI).

#### Ported to Zig (`src/kern/port.zig`)

drawterm's `qio.c` and `allocb.c` are `src/kern/qio.zig`, and its `qlock.c`, `rwlock.c`, and `sleep.c` are `src/kern/sync.zig`: close translations, with the same functions in the same order, and error unions (`error.Kernel`, and `error.Interrupted` from a sleep a note broke) in place of drawterm's error labels, with the error string on the process as `error()` leaves it. qio keeps h9's two changes to it: readiness (a queue's `Watchers`, which its wakeups notify, and `qready`; see [Readiness](#readiness)), and reader and writer locks that wait in `tsleep`, so a note interrupts a reader queued behind another. `src/kern/port.zig` is the root of the kernel's Zig, which the kern library and the namespace kernel build: it holds the C kernel's types, translated from `src/kern/port.h` with the kernel's own flags so the layouts agree, `up`, and the error helpers.

drawterm's `dev.c` is `src/kern/dev.zig`: the helpers devices are built from (`devattach`, `devwalk`, `devstat`, `devdirread`, `devopen`, and the rest), and the device switch, through which the Zig calls a device. Devices are still C `Dev`s in the device table (`src/kern/devtab.c`, or `nstab.c` in the namespace kernel), so the switch calls a C device's functions, and a C `Devgen`, through `raising`: it packs the call into a Zig trampoline and runs it under the one error label h9 sets, `h9_catch` in `third_party/drawterm-glue/catch.c`, which returns -1 with the error string on the process, and the switch turns that into an error union (`error.Interrupted` when the string is `Eintr`). `catch.c` is the edge of drawterm's C, kept beside the vendored tree rather than in it: drawterm's devices (devcons, devdraw, devfs, devip, devssl, devtls, and the rest) raise with `error()`, and only C can set the label it jumps to. Every other call from the Zig into C that can raise goes through `raising` too, and nothing in `src/` sets an error label. A device ported to Zig is native: `dev.Native` makes its C `Dev` from its Zig functions, wrapped to raise for the C that calls the table, and the switch calls the Zig functions directly.

drawterm's `pgrp.c` is `src/kern/pgrp.zig` (mount tables, and file descriptor and rendezvous groups), its `chan.c` is `src/kern/chan.zig` (channels, paths, mounts, walks, and `namec`), and its `sysfile.c` is `src/kern/sysfile.zig`, the file system calls. There is no `sys*` wrapper layer in the Zig: `sysfile.zig`'s `open`, `bind`, `pread`, and the rest return error unions, and the C names (`sysopen`, `sysbind`, `syspread`, and the rest) are small exported adapters for the C callers, which return -1 with the error in `syserrstr` as drawterm's did. Inside a call `nerrlab` is 0, so `werrstr` and `%r` in C that the Zig calls see `syserrstr`. `werrstr` stays C (`src/kern/werrstr.c`), since it's variadic. The h9 hooks that `namec` and `walk` call and that can raise (the devfs policy's anchor check) go through `raising` the same way the device switch does. The Zig allocates with `port.malloc`, drawterm's `malloc`, which clears what it returns.

drawterm's `devmnt.c` is `src/kern/devmnt.zig`, the 9P client and the first native device: the switch calls its walk, open, read, and the rest directly, and `mntdevtab`, which the device tables name, holds the C wrappers. `mntversion`, `mntauth`, `mntattach`, and `muxclose` are exported for C, and `dev/overlay.zig` and `glue.zig` (which calls `mntauth`) call them directly. A process waiting for its reply sleeps in `sync.zig`, and a note that interrupts it sends `Tflush` as before. The reply parser (`mntrpcread`) and the check of a directory read from a server (`mntdirsfix`) are fuzzed in `zig build kern-test`.

drawterm's `devpipe.c` and `devroot.c` are `src/kern/dev/pipe.zig` and `src/kern/dev/root.zig`, native devices too. The pipe keeps h9's Linux FIFOs (one queue that every open reads and writes, `fifopipe` and `fiforefs` for `src/kern/fifo.zig`) and `ready` and `watch` on its queues, and a write on a pipe whose reader closed still posts the note through `h9_postnote`, unless the pipe carries a mount's 9P. A native device's own `Devgen` is Zig that doesn't raise, so the switch calls it directly. Of drawterm's `kern/`, the build now compiles no file the proposal ports.

h9's own C is ported the same way, a file at a time. `src/kern/devpty.c` is `src/kern/dev/pty.zig`, a native device, with `h9_ptyq` and the `h9_pty_*` calls the Linux ABI makes exported for their callers. `src/kern/netcheck.c` is `src/kern/netcheck.zig`, and the kernel's half of `src/host/fscheck.c` (FIFOs by path, through overlays and 9P2000.L mounts) is `src/kern/fscheck.zig`; the host's half, the policy checks on host paths, stays C, since it never sets an error label. The C they call that raises (devip's socket calls) goes through `raising`; devfs's FIFOs are Zig calls into `src/host/devfs.zig`. `src/kern/devns.c` is `src/kern/dev/ns.zig`, the namespace kernel's `#N`, native there only, calling `pgrp.zig`'s `pgrpcpy` and `dev/srv.zig`'s `srvpost` directly. `src/kern/linuxnet.c` is two files: `src/kern/linuxnet.zig`, Linux poll (`h9_poll`) and the Linux socket calls; and `src/kern/dev/eventfd.zig`, `#ε`. The devices of `src/kern/gfx.c` (`#i` opening the screen lazily with `/dev/screen`, `#c`'s `/dev/snarf` limit, `#b`'s kbdfs format and `/dev/kbdin`, and `#m`'s `/dev/mousein`) are `src/kern/dev/gfx.zig`, native wrappers around drawterm's C devices, in builds with a screen; the screen interface the backends call and are called by stays C in `gfx.c`, since it never sets an error label, with the two calls that need the screen's image (`h9_gfx_screenshot` and `h9_gfx_mousein`) beside it. Files only one kernel has export their C names only there (`kern_options`, from the build).

The rest of the kernel is C, so each ported file exports drawterm's functions under their C names (`qread`, `qlock`, `ksleep`, which `lib.h` renames `sleep` to, and the rest) with their C semantics: an exported function that gets an error from the Zig raises it with `nexterror()`, from its own frame, which has nothing to undo. A queue's kick and bypass functions are called from the Zig, so they must not raise; nothing in h9 sets them. Every place a process waits in the Zig is `park` in `sync.zig` (posix.c's `procsleep`), and every place one is let go is `unpark`. `zig build kern-test` runs their cases, on the native namespace kernel.

#### Links and attributes ([file-interface](../design/file-interface.md), Part 2)

Besides the nine operations, a device can have six optional ones for links and attributes: `readlink`, `symlink`, `link`, `getattr`, `setattr`, and `rename`. A Zig device has them as optional fields of its `dev.Ops`; a C device would have them as function pointers in a `Devx` (`src/kern/devx.h`), found by the device's character in `devxtab` (`devtab.c`, or `nstab.c`), and called through `raising` like the rest, though none does now. `dev.zig`'s switch calls a device's operation, or the default where it has none:

| Operation | Does | Default |
|---|---|---|
| `readlink(c, buf)` | the target of the link `c` is on | not a link |
| `symlink(dir, name, target)` | makes a link in `dir` | "permission denied" |
| `link(c, dir, name)` | a second name for `c`'s file | a copy, by an exclusive create |
| `getattr(c, mask, Attr)` | the attributes `stat` can't say | from `stat`: mode, size, qid, and times in seconds |
| `setattr(c, mask, Attr)` | sets them | a `wstat`; ids are "permission denied" |
| `rename(c, dir, name)` | moves `c`'s file, replacing what's at `name` | a `wstat` of the name within one directory, after removing the file there; "cross-device link" (Linux's `EXDEV`) across directories |

An `Attr` has a mask of what it holds (`Amode`, `Anlink`, `Auid`, `Agid`, `Ardev`, `Aatime`, `Amtime`, `Actime`, `Aino`, `Asize`, and `Ablocks`, as 9P2000.L's `Tgetattr` numbers them), the qid, the Plan 9 mode, numeric ids, the link count, rdev, size, blocks, and times in seconds and nanoseconds. `link` and `rename` act only within one device instance (the same type and `dev`), and are the default otherwise; `symlink`'s target isn't walked. `namecx` is `namec` with `nofollow`, which stops a Linux process's walk at a link in the last name, so a link's own name is opened, removed, or renamed; a link followed elsewhere is still a fresh walk from the process's root, with the policy checked where it lands. The calls on paths and fds are `src/kern/syswide.zig`'s, exported with `sysfile.zig`'s contract as `h9_readlink`, `h9_symlink`, `h9_link`, `h9_rename`, `h9_getattr`, `h9_fgetattr`, `h9_setattr`, and `h9_fsetattr`, and to devices that call another device's as `devreadlink`, `devsymlink`, `devlink`, `devrename`, and `devgetattr`.

| Device | Has |
|---|---|
| `#U`, POSIX (`src/host/devfs_posix.zig`) | `readlink`, `symlink`, `link` (`linkat`, the new name checked like a create), `getattr` (the host's `stat`, with nanoseconds and the real link count), and `rename` (`rename(2)`) |
| `#U`, Windows (`src/host/devfs_win32.zig`) | `readlink`, `rename`, and `symlink`, which is "permission denied" there; `link` is the default copy |
| `#O` (`dev/overlay.zig`) | `readlink` and `symlink` (its own `Nlink` nodes, or the tree a name is in), `getattr` (its `Dir`, with what the lower tree's `getattr` adds), and `rename` (`h9_overlay_move`); `link` is the default copy |
| devmnt | all six, as 9P2000.L requests, on a mount whose server is a `#ℓ` conversation translating to 9P2000.L (see [spec/ninep.md](ninep.md)); the defaults elsewhere. Its `attrstat` builds a stat's `Dir` from the `Attr` its `getattr` brought, so a Linux `stat` there (`h9_getattr`, which wants both) is one `Tgetattr`, a Linux process on a .L root translating once |

#### Readiness ([file-interface](../design/file-interface.md), Part 1)

A device can have two more optional operations, `ready` and `watch` (`src/kern/ready.zig`, in `dev.Ops` or a `Devx`). `ready(c, ev)` gives which of the events `ev` hold on `c` now: Linux's poll bits (`In`, `Out`, `Pri`, `Err`, `Hup`, and `Rdhup`), so a read or a write wouldn't block, or the channel failed or hung up; the default is `In` and `Out`, always ready, as a file is. `watch(c, ev, Watch, Waker)` hangs the caller's `Watch` on what `c` reads, and calls the `Waker` when that may have changed; `unwatch` takes it off, and the default watches nothing. A changing object has a `Watchers` list, and `notify` calls each waker on it, with the list's lock held, so a waker only marks and `unpark`s its owner (`ready.Sleeper`, a `Rendez` with a flag). A caller registers its watches, asks `ready` again, and only then sleeps, so no change between is lost. Every notify also moves one generation, which edge-triggered epoll and `poll`'s once mode go by. Two more bits ask for something of a device: `Edge`, in a watch, wants the next change rather than readiness again, and `Now`, in `ready`, wants a fresh answer, for a caller about to read or write without waiting.

| Device | Has |
|---|---|
| pipes, ptys, and `#y` | queue readiness (`qio.qready`), the queues' wakeups notifying the device's `Watchers` (`qsetwatch`) |
| `#ε` | the counter's, notified by its reads and writes, which wait on the same list |
| devip (`#I`, `src/host/devip.zig`) | the host socket's, from a zero-timeout `poll`, and a host-socket watcher thread that wakes the watch once it fires (`ipready` and `ipwatch` in `linuxnet.zig`) |
| devmnt | `Tready`, on a mount whose server took `9P2000.ready` (see [spec/ninep.md](ninep.md)); the default elsewhere |

devmnt's `ready` sends a `Tready` that asks for an answer now, unless one waiting for these events is already out (and `Now` isn't asked). Its `watch` sends a `Tready` for the events its watches want that the server hasn't said hold, as an asynchronous request: a reply calls back from `mountmux`, and while only asynchronous requests are outstanding a reader kproc per mount reads the replies. A clunk flushes the channel's waiting `Tready`s. A server that fails a `Tready` is always ready.

#### Locks and fsync ([file-interface](../design/file-interface.md), Part 3)

`fsync(c, datasync)` makes what was written to `c`'s file durable, only its data if `datasync`; the default is the null wstat, which `#U` serves with the host's `fsync`, and devmnt's is a `Tfsync` on a mount that takes the wide requests (the default elsewhere). `src/kern/syswide.zig` exports it on an fd as `h9_fsync`. Locks have no device operation yet: the Linux ABI's table (`src/abi/linux/locks.zig`) serves every device, and a blocked lock waits in `h9_lockwait` (`src/kern/linuxnet.zig`), on a `Watchers` that each change to the table notifies (`h9_lockwake`) while a lock waits, with a count of changes (`h9_lockgen`) read before the try, so a change between the try and the wait isn't missed.

#### `tsleep` (`src/kern/tsleep.zig`)

drawterm's `sleep` has no timeout. `tsleep` has 9front's contract and uses only the kernel's public `sleep` and `wakeup`: it puts a timer on its own stack into a list sorted by host monotonic time, and the timer kproc wakes it at the deadline.

The list is guarded by a host lock (`glue.zig`, `glue-win32.c`) that the kproc holds while it calls `wakeup`, and `tsleep` always takes its timer out under that lock before returning, so no Proc fields are needed. It's Zig, ported from h9's C under [kernel-port](../design/kernel-port.md): `tsleep.zig`'s `tsleep` returns `error.Interrupted` when a note arrives, and the `tsleep` it exports for C raises it.

#### Semaphores and `rendezvous` (`src/kern/sema.zig`)

drawterm has no semaphores. 9front's code is ported closely, with the wait lists in 64 hashed buckets keyed by the host address of the semaphore word rather than in the segment, since h9's segments are Zig objects; the word is changed with host atomics.

`src/abi/plan9/syscall.zig` checks the address first (aligned, mapped, in a writable segment) and pins the word's chunk for the call, writable, so it doesn't move: a fork meanwhile copies the chunk rather than sharing it copy-on-write, and the waiters' key stays the same page.

`rendezvous` is 9front's on drawterm's Rgrp, so `procinterrupt` still pulls a process out of it, but it also checks for a note that arrived before the process was on the list.

#### Sandbox hooks (`src/host/fscheck.c` and `src/kern/fscheck.zig`, `src/kern/netcheck.zig`)

The C side of the policy checks devfs and devip call; see [spec/sandbox.md](sandbox.md), "Device hooks".

#### devsrv `#s`, from 9front (`src/kern/dev/srv.zig`), per machine

Guest file servers post themselves in `/srv` (lib9p's `postsrv`, `srvfs`, factotum, plumber), and clients open the posted channel and mount it. 9front's code is ported closely, but each machine has its own root board, hung off its `Hmach` and made on first attach, with its own lock, so machines in one host process can't see each other's services; `clone` boards hang off the machine's root, so `#s/id` addressing works within a machine.

A write of an fd number goes through `fdtochan`, then the post itself (the in-use and auth checks, holding the reference) is shared with `h9_srvpost`, which posts a host-side channel without a guest fd.

Posting sets the channel's `srvname` to its `/srv` path, which `/proc/n/ns` prints for a mount of it, as 9front does.

The machine's last process to release its groups (`h9_kern_release` in `src/kern/proc.zig`) closes every posted channel, as closing a lease does, while the machine is still there; the boards go with the machine.

#### Host-stream device `#ℏ` (`src/kern/dev/hstream.zig`, `src/hstream.zig`)

WebSockets, for roots, namespace-file mounts, and the guest's `/net/ws` ([websocket-9p](../design/epoch-0/websocket-9p.md)).

It follows #y's pattern, and is a native device too ([kernel-port](../design/kernel-port.md)): Zig does TCP, TLS (`std.crypto.tls`) and the framing (`src/ws.zig`) on a host reader thread per stream, the guest sleeps on a Rendez in the kernel until the stream has data, and a note interrupts it.

A host-made stream has no path: `h9_hstream_fd` makes its channel, which is posted as `#s/root` or mounted at once, so the guest can't reach it by name.

Attached with no spec, the device serves `ws/clone` and `ws/N/{ctl,data,text,remote,status}`, listing only the caller's machine's conversations (at most 32); `bind -a '#ℏ' /net` puts them at `/net/ws`. `data` is the binary stream, `text` one text message per read or write.

On the web host it also serves `port/clone` and `port/N/{ctl,data,remote,status}`, the page's ports ([port-streams](../design/epoch-0/port-streams.md)), sharing the conversation numbers: `open NAME` in `ctl` opens the port by name, `remote` is `port!NAME`, and `data` is the stream. A port stream is a host stream with `port` set: `connect` calls the JS host's `port_open`, which opens it at once with no handshake, and it's read and written through the WebSocket imports (`src/web/h9-web.js`). A `port!NAME` mount (`--url port://NAME[/SPEC]`, a namespace file's `mount port!NAME`) is a host-made port stream, its channel handed to a `#ℓ` conversation with `fd` and no redial, since a port is opened once. A port the page serves the machine on is an accepted stream, from the Suspending `port_accept`, whose first message goes through the dialect slot as a listener's does.

Received data is queued in the machine's pages, up to 16 MiB unread per stream.

A guest `connect` asks the net policy as a TCP dial would, through the same `netLookup`, `netResolved`, and `netCheck` as devip and `cs`. The machine's end closes its streams (`h9_hstream_machend`, from `src/kern/proc.zig`).

#### 9P2000.L device `#ℓ` (`src/kern/dev/dotl.zig`, `src/dotl/`)

devmnt and h9's own 9P server speak only 9P2000, and most 9P servers outside Plan 9 speak 9P2000.L ([dotl](../design/epoch-0/dotl.md)). A `#ℓ` conversation puts a translator between devmnt and a server connection, or between a client connection and the kernel's server (kserve).

Attached with no spec, the device serves `dotl/clone` and `dotl/N/{ctl,data,status}`, which `bind -a '#ℓ' /net` puts at `/net/dotl`. `ctl` takes `fd N` (the caller's fd N is the server connection), `fd R W` (read the server from fd R and write it to fd W, for an embedder's pipe pair), `redial URL[,URL…]` before `fd N` (where a reconnect dials, a `ws://` or `wss://` URL made into a new host stream, with its credential helper, when h9 connects for itself with no plan), `user UID NAME` before `fd N` (the connection's user map, from `9P-Uid` and `9P-User`), `dial ADDR[,ADDR…]` (a `tcp!` address dialed through `#I` under the dialer's plan, or `unix!PATH` when h9 dials a root itself, with no plan), `version 9P2000.L` (don't offer `.L.Z`), and `serve N` (the server side, for a client on fd N); `data` is 9P2000; `status` reads the dialect, `Hungup` and why, and `reconnects N` once the connection has been resumed. A host descriptor through devlfd can't be interrupted in its read, so a conversation whose server is one waits for it to be readable first, in a wait the last close wakes (`h9_hostwait` in `src/kern/rootdial.zig`: `poll` with a pipe beside it on POSIX, and on Windows a `PeekNamedPipe` loop that sleeps up to 8 ms when there's nothing), and its reader ends with the conversation rather than when the server writes or closes.

It follows devhstream's pattern: a kproc per conversation reads the server connection and feeds the translator, which is called through leaves in `src/dotl/kern.zig` that take and return bytes and never raise, under a QLock per conversation; a guest reading `data` sleeps on a Rendez until the translator has bytes for it, so a note interrupts it. The conversation ends when the last of its `ctl` and `data` is closed. The device is Zig, a native device (`dev.Native`), with error unions, and its dials call `rootdial.zig`'s `unixchan` and `dev/hstream.zig`'s `dial` directly.

The translator is `src/dotl/`: `wire.zig` encodes and bounds-checks 9P2000, 9P2000.L, and ZeroFS's 9P2000.L.Z; `attr.zig` maps `Dir` and Linux `stat`, error strings and errno, mode bits, and the user map; `client.zig` and `server.zig` are the two sides, each a state machine over bytes with no I/O of its own, tested against `testserver.zig`, a .L server in memory, and fuzzed. A create with `DMNAMEDPIPE` is a `Tmknod` of a FIFO, and a server's FIFO lists with `DMNAMEDPIPE` and opens without a server open, reading empty. A machine registers its user and `--user-map` with `kern.zig`, keyed by its `Hmach`.

#### 9P2000 server (`src/kern/kserve.zig`)

`--serve` needs a 9P server, and running exportfs as a guest process cost a process per connection and per blocking request, needed an exportfs binary, and can't run where there are no guest processes ([kernel-serve](../design/epoch-0/kernel-serve.md)). kserve serves a channel of 9P2000 messages from kernel channels directly: a fid holds a `Chan`, walks use chan.zig's `walk()`, opens and creates cross mounts as namec does (with chan.zig's `findmount` and `createdir`), and directory reads go through sysfile.zig's `chanread`, kread's work on a channel (and `chanstat`, for `fstat`'s naming). Its reader and worker kprocs act for the process that started serving, through records of their own in its machine (`h9_kprocshare` in `src/kern/proc.zig`) and its thread-local plan and pages (`h9_kern_locals` in `src/kern.zig`), so the sandbox hooks and devices that look up the caller's machine see the server Proc's. It's the kernel's Zig ([kernel-port](../design/kernel-port.md)), with error unions, and a request's error is its `Rerror`; Zig hands it a connection through `kern.Kserve`. See [Serving](ninep.md#serving).

#### Index device `#ι` (`src/kern/dev/hidx.zig`, `src/rootindex/`)

Puts a metadata index between devmnt and a 9P connection ([mount-index](../design/epoch-0/mount-index.md); see [Metadata indexes](ninep.md#metadata-indexes)). It's laid out as `#ℓ` is, `hidx/clone` and `hidx/N/{ctl,data,status}`, but isn't bound anywhere, and it's masked once the namespace file is replayed, since a guest's conversation could read and write the host's index cache. `ctl` takes `server KEY` (use the server's `.fs/index`, cached under KEY, the address and attach spec), `index N` (use the compiled index the machine handed over as number N), neither (pass everything through, counting requests), and then `fd N` (the server connection, which starts the conversation); `data` is the 9P2000 devmnt mounts; `status` reads the index's label, counts, and how long its check took, the requests devmnt sent and how many reached the server, and the notes `-v` prints. h9 reads `status` through a leaf (`h9_hidx_convstatus`) rather than a chan, since `#ι` is masked by the end of the run.

The kproc, the leaves (`src/rootindex/kern.zig`), and the locking follow `#ℓ`, except that a write to `data` holds the server-write lock from queueing its requests to writing them, so they reach `#ℓ` in the writer's process, which tells the translator whether they're a Linux process's. A machine registers its cache directory with `kern.zig`, keyed by its `Hmach`, and hands over an `index=` index it compiled with `give`, which a conversation takes once by number. It's a native device ([kernel-port](../design/kernel-port.md)), and its kproc ends by returning, as a kproc's trampoline then calls `pexit`.

#### devcons hooks (`src/kern/consx.c`, `consx.h`)

drawterm's devcons gives whole-second time, three words of `bintime`, an empty `sysstat`, and no `pid` or `ppid`, and Go reads `#c/pid` by device path, which no bind can redirect ([go-compat](../design/epoch-0/go-compat.md)).

So devcons calls hooks: `#c/pid` and `#c/ppid` (machine-local pids, as `$pid` and `/proc` have them, in 9front's 12-character format); `bintime` (wall nanoseconds, ticks, `fasthz`, and monotonic nanoseconds, big-endian, with a short read getting the leading words that fit); `time` (seconds, nanoseconds, ticks, and `fasthz`, in drawterm's text format); and `sysstat`, a line per CPU the machine may use, in 9front's ten columns with zeros for the counters h9 doesn't keep, so Go's `runtime.NumCPU` counts them.

The CPU count is `--cpus` if given, else the host's, capped by the engine's vCPU limit. The guest's `NPROC` is the same count, so `mk` runs that many jobs ([self-host](../design/epoch-0/self-host.md)).

The clock is the machine's host's ([host-handles](../design/host-handles.md)): `kern.wallNs` and `kern.monoNs` (`src/kern.zig`) read the calling thread's machine's `Host.clock`, and a thread without one, and the clock a plan's host gives, read the OS: wall time from the host's real-time clock, and monotonic time from its monotonic clock, offset to the wall time at the kernel's boot. Entropy for the Linux ABI's `getrandom`, `AT_RANDOM`, and `/proc`'s uuids is the host's `random`, the console is its `console`, and the `--gfx` screen is taken through its `window`. Ticks are the monotonic nanoseconds, so `fasthz` is 10⁹. Writes to `time` and `bintime` still fail.

#### Overlay device `#O` (`src/kern/dev/overlay.zig`)

Copy-on-write trees in memory over a lower directory, for the root's overlay, `--write=ephemeral`, and the private `/tmp` (see Sandbox policy). An instance can report each change to the machine, for the root's discarded-changes notice. A file in memory with `DMEXCL` is open on at most one chan at a time, as on 9front's file servers: another open fails with "file is locked" (ramfs's string) until that chan is closed; host files (`#U`) have no such bit. A FIFO node (`Nfifo`, from the Linux ABI's `mkfifo`) lists with `H9_DMFIFO` and isn't read or written itself, and a host FIFO below opens for writing without a copy-up. A union `bind -c` of a ramfs can't keep writes off the host, since a union sends every operation on an existing name to the member that has it.

It is a native device ([kernel-port](../design/kernel-port.md)): the switch calls its Zig operations directly, including the optional `readlink`, `symlink`, `getattr`, and `rename` of `dev.Ops`. Its errors are error unions, raised as C's `error()` only in the functions the C kernel calls (`overlaydevtab`'s wrappers and the namespace builder's `h9_overlay_*`).

An instance is a copy-on-write tree or a **union** ([mounts](../design/epoch-0/mounts.md)): up to 64 members, each a directory chan rooted at a path in the union (`""` for its top, or a path such as `etc`), merged at every depth. A walk looks in each member from the top down, a directory lists every member's names once, the first member that has a name answers for it, and a create goes to the first `-c` member that has the parent. Removing a name from an upper member uncovers a lower one. A union's qids are its own, mapped from its members' in a table, so two members' files never share one. A `bind -c '#O'` over a union is a copy-on-write overlay of it that copies up and whites out.

- **Whiteouts.** In every union, a member's `.wh.NAME` hides `NAME` in the members below it, and a directory that holds `.wh..wh..opq` isn't merged with the directories below it, as in an OCI image layer. A walk asks a member for the whiteout only when that member misses a name, and only above the bottom member. A directory read leaves out whiteouts and the names they hide. A tree with no `.wh.` names merges as it would without this.
- **Up layers** ([upper-layers](../design/epoch-0/upper-layers.md)). A union can have one up member, always its first (`Member.isup`), which takes every change made through the union, as overlayfs's `upperdir` does, so the member ends up holding an unpacked OCI layer. A write, truncate, or wstat of a file only below copies the whole file into the layer first, with its parent directories, and a wstat of a directory only below makes the directory there. A remove of a name that exists below removes any copy in the layer and makes an empty `.wh.NAME` beside it; a name only in the layer is just removed. A create over a whiteout removes it, and a directory made over a removed one gets `.wh..wh..opq`. A rename copies a file from below up first, renames it in the layer (a wstat within a directory, or `h9_overlay_move` across directories), and whites out the old name if it exists below; a directory that exists below is "cross-device link" (Linux's `EXDEV`). A name that starts with `.wh.` can't be made in a layer, by a create or a rename: it's "permission denied". Links and FIFOs are made in the layer as its tree makes them: `#U` makes host ones, `#O` keeps them in memory, and a 9P2000.L mount makes a link by `Tsymlink`. A union chan whose directory was found before the layer had it looks for it in the layer again before a walk, a read, or a create (`unfresh`), since the instance counts the directories made there, so a working directory from below sees what's changed since.
- **Named unions** are per machine pool: `#Oroot` is the root stack and `#Olinux` the Linux tree's. The namespace builder adds members with `h9_overlay_union` (a guest path) and `h9_overlay_unionmount` (a 9P connection by fd), and a union stays pinned until it's attached.
- **The walk cache.** A union with an up layer keeps what each step of a walk found, for at most a second: the members' chans for the new name, or that it doesn't exist. An entry is keyed by the path, the members the step started from, whether the walk leaves the layer out, whether it's a Linux process's walk (which stops at links), and the calling machine's access rules, so a hit gives what the walk would have. A change through the union drops the entries for its path, and one that removes or renames a directory, or changes the members, drops them all; a step that ran while its path was dropped keeps nothing. Changes made outside the union, such as on the host, show once an entry expires. A step costs a host `stat` per member, and a whiteout and an opaque check besides, so without it a Go untar into a layer made about 200 host stats per file.
- **Unnamed unions** are numbered, attached as `#ON`, and only by the machine pool that made them; another machine's number is "file does not exist".
- **The clone tree.** A bare `#O` attach is a directory holding `clone` (0666). Opening it makes an unnamed, pinned union, and reading it gives the number. It takes `add [-a|-b] [-c] PATH` (a member, on top unless `-a`), `upper PATH` (the up member, on top), `del PATH`, and `cow` (an overlay over the union, whose number replaces the union's for the rest of the open). Closing `clone` drops a union that was never attached. h9's `bind -r` and `bind -u NEW OLD` (`#H/over/bind`, bound before `/bin`) are built on it; `-u` makes a union of OLD with NEW as its up member and binds it over OLD.
- **`ns`.** devproc's `ns` asks `h9_overlay_nsunion` for a mount whose chan is an unnamed union, and prints the union as the `bind -u`, `bind -rb`, `bind -ra`, and `-c` lines that rebuild it from the member at the mount point, a member that's itself a union in turn, so the output replays.

#### h9's guest commands `#H` (`src/kern/devhtools.c`)

Commands that wrap h9's own devices (websocket-9p's `wsmount`, say) can't come from 9front, and h9 never writes into the root ([guest-tools](../design/epoch-0/guest-tools.md)).

`src/guest/` holds them, laid out as the guest sees them, and the build embeds it in the binary as a generated table (`tools/guesttree.zig`): only rc scripts and data, so an executable that doesn't start with `#!/bin/rc` fails the build, and names starting with `.` are left out.

Executables are 0555, other files 0444, directories 0555, all owned by the machine's user; `#H/bin` always exists.

The device gets the table once at reset from one leaf, `h9_tools_table` (`src/kern.zig`), and is plain C over constant memory after that. An entry's index is its qid path, so qids are the same on every run of one build.

Attach takes no spec, or `root` for the built-in root below; writes, creates, removes, `OTRUNC` and `ORCLOSE` opens, and `wstat` fail with "permission denied".

Debug builds also serve `tests/fixtures/guest/` (`-Dguest-test`), for the integration cases.

#### The built-in root `#Hroot` (`src/kern/devhtools.c`)

A root that's in the binary, so h9 runs with no tree to find ([builtin-root](../design/epoch-0/builtin-root.md)). It's a second table in `#H`, served by the same code with the same rules except its modes, a 9front tree's 0775 and 0664 so that an overlay over it can create files (the device itself still refuses every write), and a channel's `dev` says which table it's on, so the two trees' qids never meet in the mount table.

Its contents are the directories h9 binds onto (`bin dev env fd mnt/term/cwd net proc srv tmp usr`) and, for each architecture the build can run, the tree `zig build slim` makes ([multicall](../design/epoch-0/multicall.md)): `$arch/bin/9box`, a name per command, `rc/lib/rcmain`, and `adm/timezone/local`.

The build reads the trees from `-Dbuiltin-root` (default `.local/9front`) by the pinned release's name, `slim-<release>-<arch>`, so a stale tree is never embedded; `h9` embeds all three on arm64 and x86-64 targets, since the emulator runs every architecture, only its target's architecture elsewhere, and the web host `386`.

Entries with the same bytes share them (`tools/guesttree.zig`), so the command names cost a table entry each rather than a copy of `9box`, and the bytes are embedded with `@embedFile`.

A missing architecture gets the skeleton only, with a warning; `-Drelease` fails instead. The device gets the table from `h9_root_table` (`src/kern.zig`).

### Errors, calls across the edge, and guest memory

A kernel function that can fail returns an error union, `port.Error`: `error.Kernel`, with the Plan 9 error string on the process as `error()` leaves it (`up->errstr`), or `error.Interrupted`, from a sleep a note broke (`Eintr`). `defer` and `errdefer` do the cleanup that drawterm's error labels did; nothing in `src/` sets one.

The kernel's functions are exported under drawterm's C names with drawterm's contracts, for the C that calls them and for the rest of h9. The system calls (`sysopen`, `sysbind`, `syspread`, and the rest, in `src/kern/sysfile.zig`) return -1 with the error in `syserrstr`, as drawterm's did, and clear `notepending` on success; `h9_pread`, `h9_pwrite`, `h9_stat`, `h9_fstat`, `h9_wstat`, and `h9_fwstat` are the same calls with `usize` counts and `isize` results, which `src/kern.zig` calls. Inside a call `nerrlab` is 0, so `werrstr` and `%r` in C that the Zig calls see `syserrstr`; `werrstr` stays C (`src/kern/werrstr.c`), since it's variadic. The rest of the exported functions (`qread`, `namec`, `devwalk`, and so on) raise as the C they replace did: one that gets an error from the Zig raises it with `nexterror()` from its own outermost frame (`port.raise`), which has nothing to undo.

drawterm's C raises with `error()`, which is `setjmp` and `longjmp`, and only C can set the label it jumps to. So the Zig calls any of it that can raise (a C device's functions and its own `Devgen`s, devfs's anchored attach, FIFOs, and syncs, devip's socket calls and ctl, and gfx.c's screen setup) through `dev.zig`'s `raising`: the call is packed into a Zig trampoline that does nothing but call it, and run under `h9_catch` (`third_party/drawterm-glue/catch.c`), the one place an error label is set, which returns -1 with the error string on the process; `raising` turns that into an error union. `catch.c` is h9's, beside the vendored tree rather than in it. A queue's kick and bypass functions are called from the Zig and must not raise; nothing in h9 sets them. Calls from drawterm's C into the rest of h9 (the policy, console I/O, the clock) are leaves that return a status and never raise.

drawterm's `up` (`_getproc()`, per host thread) is the current process. Every guest thread is made through `h9_kern_spawn`, so `up` is set before any kernel call, and an executor sets it again each time it switches a continuation in; Zig never uses a bare `std.Thread` for anything that touches the kernel, and never boots the kernel on a caller's thread. The one exception is `--gfx` on macOS, where AppKit needs the main thread: `h9.gfx.main` boots the kernel on it and adopts it as a kernel Proc (`h9_kern_adopt`) before handing it to AppKit.

Guest memory reaches the kernel only through `src/guestmem.zig`, under each ABI's address space (`segment.Space`, and the Linux `Mm`), which checks a buffer against the process's mappings before the kernel reads or writes through it; the kernel never sees a guest address, so drawterm's `validaddr`, a no-op, is never reached. An unmapped byte posts "sys: bad address in syscall" to a 9front process, and is `EFAULT` for a Linux one. A data buffer (`pread`, `pwrite`, `stat`) is passed to the kernel in place when it's contiguous in host memory, its pages pinned for the call, and otherwise goes through a host bounce buffer, so each guest call is one kernel call. Counts are `usize` down to the file system calls; below them, the device switch, qio, and the devices count in C's `int`, drawterm's `long`, since the `Dev` table is shared with drawterm's devices, so a read or write of more than 2 GiB - 1 is short, and the 9front ABI splits a call of 1 GiB or more. Strings (paths, `errstr`) are always copied into a bounded host buffer first, so no other guest thread can change one during the call.

The build uses `zig build`: drawterm's C goes through `addCSourceFiles` with drawterm's flags, the kernel's Zig sees its types through translate-c of `src/kern/port.h` with the same flags, so the layouts agree, and one `build.zig` produces binaries for every host.
