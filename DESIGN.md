# Design: Plan 9 executables on host hypervisors

Nov 2, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

This describes h9 as built. Changes to it go through proposals in [design/](design/README.md); the record of how h9 got here before proposals is the [baseline](design/0000-baseline.md).

## Overview

h9 is a small Zig library and CLI that runs native 9front executables directly on macOS, Linux and Windows, using each host's hypervisor API. Each guest process runs in hardware-isolated user mode, and its syscalls are served by drawterm's Plan 9 kernel running in the host process. Prior art: hyper-linux (the same shape for Linux ELF on macOS) and 9vx (Plan 9 binaries on Linux and OS X x86 through a vx32 sandbox).

**Goals**

- Start and run a 9front binary as fast as a native process: no VM image, no boot, no guest kernel.
- One invocation can hold a whole process tree (rc pipelines, servers posting to /srv, rio and its clients).
- Run native code only: arm64 9front binaries on arm64 hosts, amd64 binaries on x86\_64 hosts.
- One host backend each for Hypervisor.framework (macOS), KVM (Linux) and Windows Hypervisor Platform (Windows).
- Self-hosting: the 9front compilers and mk run inside and can rebuild the 9front userland.

**Non-goals (for now)**

- Running the 9front kernel itself, or drivers for real hardware.
- Translating across architectures (amd64 binaries on arm64 hosts, or the reverse) for users. The emulator can do it, but only for testing.
- Plan 9 4th edition or other forks: their syscall tables differ.
- A long-running daemon. Each invocation is its own machine.

## Decisions

| Area | Decision | Notes |
| --- | --- | --- |
| Product shape | A library plus a thin CLI; each invocation is one machine | One machine can hold a whole process tree. Keep the machine API free of CLI-global state. |
| Plan 9 flavour | 9front only, at a pinned release | One syscall table and one a.out format per architecture |
| Root filesystem | Direct host tree | 9P mounts (remote servers, cwfs or gefs as guests) are proposed ([9p-roots](design/9p-roots.md), [image-roots](design/image-roots.md)); devmnt already exists |
| Toolchain inside | The 9front compilers (7c/6c, 7l/6l, mk) must run | It's a goal ([self-host](design/self-host.md)), and a source of test binaries |
| Language | Zig, latest stable (0.16.x as of writing) | Change versions only when we hit a blocking bug. drawterm's C is compiled with `zig cc`. |
| Terminal | Text mode on the host TTY; graphics behind a flag is proposed ([gfx](design/gfx.md)) | consctl `rawon`; the interrupt key posts an `interrupt` note |
| Guest exit mechanism | MMIO doorbell (`OUT` on x86) | Works the same on all three hypervisors |
| Emulator | A user-mode emulator backend: Unicorn; a native Zig interpreter is proposed ([zig-interpreter](design/zig-interpreter.md)) | For development and CI on hosts and VMs without a usable hypervisor |

## Architecture

&#91;embedded content: architecture · host process, guest VM, host OS\]

Each Plan 9 process runs in user mode on its own vCPU. A syscall traps into the shim, exits through the doorbell, and is served by drawterm's kernel on the host. The new code is the machine library (highlighted), the vmm backends and the shims; the CLI is a thin wrapper.

## Hypervisor layer (`vmm`)

A small Zig interface hides the three hypervisor APIs and the emulator. Everything above it is written once.

```zig
// vmm.create picks a backend at run time: .auto tries the host hypervisor, then the emulator.
pub fn create(gpa, io, want: BackendKind, opts: Options) !Backend;   // Options: { arch: Arch }

// One address space per Plan 9 process. Each backend decides how to realize it:
// the hypervisors build 4K page tables, the emulator keeps a virtual-address -> host-memory map.
const AddressSpace = union(Kind) {             // Kind: hvf, emu (kvm and whp are proposed)
    pub fn map(self, va: u64, mem: []align(4096) u8, perms: Perms) !void;
    pub fn unmap(self, va: u64, len: u64) !void;
    pub fn protect(self, va: u64, len: u64, perms: Perms) !void;
    pub fn translate(self, va: u64, len: u64) ?[]u8;      // host view, for syscall arguments
};
const Backend = union(Kind) {
    pub fn kind(self) Kind;
    pub fn allocPages(self, n: usize) ![]align(4096) u8;  // memory that address spaces can map
    pub fn maxVcpus(self) !u32;
    pub fn newAddressSpace(self) !AddressSpace;
    pub fn createVcpu(self) !Vcpu;             // on the thread that will run it
};
const Vcpu = union(Kind) {
    pub fn setAddressSpace(self: *Vcpu, as: AddressSpace) !void;
    pub fn run(self: *Vcpu) !Exit;             // blocks until the next exit
    pub fn getUreg(self: *Vcpu, u: *Ureg) void;        // Plan 9 Ureg layout
    pub fn setUreg(self: *Vcpu, u: *const Ureg) void;
    pub fn kick(self: *Vcpu) void;             // safe from any thread
};
const Ureg = union(Arch) { arm64: arm64.Ureg, amd64: amd64.Ureg };
const Exit = union(enum) { syscall, fault: Fault, interrupted, halted, other: u64 };
```

Each backend is a file under `src/vmm/` with the same method set; the unions dispatch to it. Backends not built into a given h9 are replaced by a stub whose `create` fails with `BackendNotBuilt`, so every host builds the same code. A backend that can't run the binary's architecture fails with `WrongArch`; HVF runs arm64 only.

The contract is in Plan 9 terms (address spaces, Ureg, syscall exits) rather than hardware terms such as guest-physical memory and page tables. That keeps page-table building inside the hypervisor backends, and lets the emulator implement the contract without emulating kernel mode or an MMU.

The interface was shaped around all three hypervisors, so the table and rules below cover KVM and WHP as well. Only HVF is built; [kvm](design/kvm.md) and [whp](design/whp.md) are proposed.

| Operation | macOS: Hypervisor.framework | Linux: KVM | Windows: WHP |
| --- | --- | --- | --- |
| Create VM | `hv_vm_create` | `KVM_CREATE_VM` | `WHvCreatePartition` + `WHvSetupPartition` |
| Map memory | `hv_vm_map` | `KVM_SET_USER_MEMORY_REGION` | `WHvMapGpaRange` |
| Run vCPU | `hv_vcpu_run` | `KVM_RUN` | `WHvRunVirtualProcessor` |
| Kick vCPU | `hv_vcpus_exit` | `immediate_exit` + signal to the thread | `WHvCancelRunVirtualProcessor` |
| Access needed | `com.apple.security.hypervisor` entitlement | read/write on `/dev/kvm` | the optional Windows Hypervisor Platform feature |

**Rules that keep the interface portable**

- **Exits:** the shim exits to the host by storing to an unmapped doorbell address (MMIO), or with `OUT` on x86. All three hypervisors hand that exit to userspace, so we don't depend on HVC or VMCALL handling, which differs across them. On arm64 KVM in particular, the kernel handles HVC itself unless hypercall filtering is configured.
- **Threads:** a vCPU is created, run and destroyed on one host thread, which is HVF's rule and the strictest of the three. `kick` is the only call allowed from another thread.
- **Memory:** one large guest-physical region is mapped once at VM creation. A host-side page allocator hands out guest-physical pages from it. We never map per segment, because KVM caps the number of memory slots and mapping calls are slow everywhere.
- **Page size:** guest page tables use 4K pages on every host, matching 9front's page size on both architectures. hyper-linux shows HVF guests can use 4K pages. Only the single host memory region has to be aligned to the host page size (16K on Apple Silicon).
- **No hypervisor:** `create` fails cleanly with a clear message, and `auto` falls back to the emulator when it's built in.

## Emulator backend (`emu`)

The emulator lets the system run anywhere, including VMs without nested virtualization, at reduced speed. It implements the same Backend, AddressSpace, Vcpu and Exit contract, so everything above the vmm layer runs unchanged.

**Scope:** user-mode arm64 and amd64 code only. On an `SVC` or `SYSCALL`, or on a fault, the emulator fills the Ureg and returns the exit itself, doing the shim's job. There's no guest kernel mode, no system registers and no MMU. The shim is tested only on real hypervisors.

**How the Unicorn backend works.** Each vCPU is one Unicorn engine, running arm64 at EL0 or amd64 in flat 64-bit mode. An address space is a list of regions of host memory; when a vCPU runs, any regions it hasn't seen yet are mapped into its engine with `uc_mem_map_ptr`, so the host and the guest share the pages and syscall arguments are read in place. Hooks stop the engine: `UC_HOOK_INTR` for `SVC` (and other exceptions), `UC_HOOK_INSN` for amd64 `SYSCALL`, and `UC_HOOK_MEM_INVALID` for faults. After a syscall stop the PC is already past the instruction, as with a hypervisor; after a fault it's at the faulting instruction. `Ureg.type` holds what the real kernel puts there for a syscall (the ESR on arm64, vector 64 on amd64). `kick` sets a flag and calls `uc_emu_stop`, which Unicorn allows from another thread.

**Implementation.** The backend uses Unicorn Engine. It's a C library built on QEMU's CPU core, covers arm64 and x86\_64, and has hooks for syscall instructions and invalid memory accesses. It's GPLv2, so it sits behind a build flag (`-Demu=unicorn`) and never goes into the MIT `h9` release build. Releases ship it separately as `h9-emu`, a GPLv2 binary built from source (`-Dunicorn=source`) with its complete corresponding source attached to the same release (`scripts/release.sh`); the two are separate programs side by side, so `h9` stays MIT. We link the prebuilt static `libunicorn.a` from Unicorn's PyPI wheels (pinned in `scripts/pins.sh`, fetched by `scripts/fetch.sh`) rather than building its CMake tree: macOS arm64, and Linux arm64 and x86\_64 with musl, which is Zig's default Linux target. There's no Windows arm64 wheel, so emu on Windows is built from source with our own `build.zig` (`-Dunicorn=source`, `build/unicorn.zig`). amd64 binaries are tested on Linux x86\_64 only; there's no amd64 on Darwin.

**What it's for**

- Developing and testing on any host or VM: macOS, Linux, Windows and hosted CI runners.
- Deterministic debugging: single-stepping, instruction tracing, and record and replay at the syscall boundary.
- Cross-architecture runs, for testing only: amd64 binaries on an arm64 Mac, and the reverse.
- Conformance: one test suite runs against every backend, and each backend must produce the same syscall traces.

**Limits and selection.** Measured with `zig build bench -Demu=unicorn` ([tests/bench.zig](tests/bench.zig)) on an M3 Max (macOS, release build of Unicorn 2.1.4): a 2-instruction loop of 10⁹ iterations takes 0.27 s on HVF, 1.4 s on emu for arm64 (about 1.5 G instructions/s; Unicorn's code generation, not our hooks) and 1.9 s on emu for amd64. A `pwrite` syscall round trip costs about 0.8 µs on emu, a little less than HVF's 1.1 µs: a bare exit and re-entry takes about 0.35 µs on emu, which never leaves the process, and about 0.8 µs on HVF, which goes through the shim, EL2 and the macOS kernel each way. So syscall-heavy work such as rc pipelines runs at close to hypervisor speed, arm64 compute runs about 5× slower and amd64 compute about 7× slower; that's fine for tests, and tolerable for self-hosted builds. By default `h9` uses the host's hypervisor when it's available, and otherwise falls back to the emulator with a warning. `--backend emu|hvf|kvm|whp` forces a choice.

## Guest shims and ABI

Each guest architecture gets a few hundred lines of assembly that run in guest kernel mode. The shim holds no policy: it moves control to the host and back, and the host decides everything.

**What the shim does**

- Bring up the CPU: on arm64, EL1 with the MMU on; on amd64, long mode with a GDT, an IDT and the SYSCALL MSRs. Where the hypervisor lets the host set system registers directly (HVF on arm64), the host does this and the shim is only the exception vectors.
- Switch the user page table root (TTBR0 on arm64, CR3 on amd64) when the host asks, unless the host can set it directly.
- On a syscall, fault or interrupt: save the user registers into the per-vCPU page in Ureg layout, ring the doorbell, then restore registers (possibly changed by the host) and return to user mode.

**Per-vCPU shared page:** exit reason, fault address and access type, the saved Ureg, the next page table root, and a sequence number. The host reads and writes it directly, so a typical syscall costs one exit and no register get/set calls.

**Binary ABI (checked against 9front source).** The values below come from `sys/src/9/{arm64,pc64}/mem.h` and `trap.c`, plus `sysexec` in `port/sysproc.c`.

| Item | arm64 (`R_MAGIC`) | amd64 (`S_MAGIC`) |
| --- | --- | --- |
| UTZERO (text start) | 0x10000 | 0x200000 |
| USTKTOP (stack top) | 0x7FFFF0000 (36-bit user addresses) | 0x7FFFFFFFF000 |
| Stack size | 16 MiB | 16 MiB |
| Page size | 4 KiB | 4 KiB |
| Data segment alignment | 64 KiB | 2 MiB |
| Syscall number | R0 | BP (RARG) |
| Syscall arguments | user stack, from SP+8 | user stack, from SP+8 |
| Syscall result | R0 | AX |
| Registers at entry | R0 = Tos pointer; SP points at argc, argv follows | AX = Tos pointer; SP points at argc; R14 and R15 zeroed |
| Note handler entry | R0 = Ureg pointer; SP+8 = Ureg, SP+16 = message | BP = Ureg pointer; same stack layout |

**a.out loading (host side)**

1. Read the Exec header: eight big-endian 32-bit words. Both 64-bit magics set HDR\_MAGIC, so a big-endian 64-bit entry address follows, making the header 40 bytes.
2. Map file bytes \[0, header + text) read-only at UTZERO. The header is part of the text segment, and the entry point must fall inside it.
3. Map the next `data` bytes of the file at the end of text, rounded up to the data alignment. bss starts at the end of data rounded up to 4 KiB, and is zero-filled.
4. The stack may span \[USTKTOP − 16 MiB, USTKTOP), but as in 9front only its top pages are mapped at first; it grows down on faults below it, and at each syscall to cover the arguments. A zeroed Tos sits at the very top. Below it go the argument strings, then the argv array, then argc at SP.
5. Tos fields: the host fills `pid` and `cyclefreq` and keeps `kcycles`/`pcycles` current; the profiling pointers stay zero.

**Syscall table.** 9front's `libc/9syscall/sys.h` defines numbers 0–53; 48 and 49 are unused. The underscore entries (`_READ`, `_WRITE`, `_STAT`, `_NSEC` and so on) are old compatibility calls that current libc doesn't use. h9 implements only the current calls; the others post "sys: bad sys call", as the real kernel does for unknown calls. Time comes from `/dev/bintime`, not a syscall; drawterm's devcons serves it, and its clock moves only once a second and returns three of 9front's four words, so `nsec()` sees whole seconds ([go-compat](design/go-compat.md) fixes this). `_NSEC` is proposed as an exception, for Go ([go-compat](design/go-compat.md)).

**Reference:** hyper-linux's `src/shim.S` (648 lines, Apache-2.0) already covers EL1 vectors, MMU setup and W^X page splitting on HVF. Read it before writing ours, and keep its license notice on anything we borrow.

## Process model

Each CLI invocation is one machine: one host process with one VM. Each Plan 9 process is a drawterm Proc plus a host thread that owns a vCPU, and the host OS schedules them, so there is no guest scheduler. Because every process lives in one VM and one kernel, rfork never has to serialize state across host processes. hyper-linux has to, because it can only use one VM per host process.

| Plan 9 call | Implementation |
| --- | --- |
| `rfork(RFPROC)` | New Proc, new thread and vCPU, and an eager copy of the address space (no copy-on-write) |
| `rfork(RFMEM)` | Share the text, data and bss; copy only the stack |
| `RFNAMEG` / `RFFDG` / `RFENVG` / `RFNOTEG` / `RFREND` | Share or copy drawterm's Pgrp, Fgrp, Egrp, note group and rendezvous group |
| `exec` | Load the new a.out into fresh segments, rebuild page tables, reset registers, keep the fds (honouring close-on-exec) |
| `exits` / `await` | Wait records queued on the parent Proc; the thread and vCPU are torn down |
| `brk_` | Grow the data segment and map pages from the guest-physical allocator |
| `notify` / `noted` | Push a Ureg and the note string onto the user stack and point the PC at the handler; `noted` restores or kills the process |

**Threads.** The kernel boots once per host process, on a private thread, because booting turns the calling thread into a Proc for good. Every guest process then runs on a kernel thread made by `h9_kern_spawn` in `src/kern/proc.c`, which works like drawterm's `kproc` but can be called from a thread that isn't a Proc: it clones from the boot Proc, and the new thread sets up its groups once `up` is set. That thread creates the process's vCPU, which HVF binds to its creating thread, and runs the exit loop. `Machine.run` starts the first process this way and waits for it to exit; `rfork` uses the same path.

**Several machines per host process.** An embedder, or the test suite, can run several machines in one host process. They share the one drawterm kernel, but each machine's first Proc starts with a fresh Pgrp, Fgrp and Egrp, so each has its own namespace, device mask, console and environment. The CLI always runs one.

**Notes on blocked and running processes.** A note to a process blocked in a host syscall wakes it through drawterm's sleep/wakeup, and the syscall fails with "interrupted". A note to a process running guest code kicks its vCPU, and the note is delivered at the exit. Pending notes are queued on h9's process record, not in drawterm's Proc: drawterm's `postnote` keeps only `notepending`, which `enderror` clears after every failed syscall, so it serves only as the "interrupt this call" flag.

**vCPU limits.** Each process runs on one vCPU at a time, and hypervisors cap the live vCPUs per VM (`hv_vm_get_max_vcpu_count` on HVF). On HVF a vCPU is bound to its thread, so a process past the cap can't simply borrow one: it needs pool threads that run the guest on its behalf.

Measured on an M3 Max (macOS 15.8.1, 14 cores): `hv_vm_get_max_vcpu_count` reports 64, and the 65th live `hv_vcpu_create` fails with `HV_NO_RESOURCES`. Destroyed vCPUs free their slots, and a create takes about 120 µs. A Unicorn engine has no limit but costs about 1.3 MiB of host memory and 0.3 ms to create. So on HVF 64 is a hard cap on *live* processes, not just running ones, and a pipeline of 65 stages or `mk -j` with many jobs reaches it.

The answer (`src/cpupool.zig`) is a hybrid. A process creates and owns its vCPU on its own thread, as before, while the machine owns fewer than the limit less a reserve of 8. Processes beyond that run guest code through a pool of 8 pool threads, each with a vCPU: the process thread hands its Ureg, FP/SIMD registers and thread pointer to a pool thread, which runs the guest to its next exit and hands them back. Kernel calls stay on the process's own thread, so pool threads never block in the kernel and the pool always makes progress. A handoff costs two thread wake-ups per syscall, so only the processes past the first 56 pay it. `--cpus` caps how many vCPUs run guest code at the same moment, owned or pooled, on every backend. The emulator has no vCPU limit, so every process owns an engine there.

## Kernel: drawterm `kern/` and the Zig seam

We vendor 9front drawterm's `kern/`, its libraries (libc, libdraw, libmemdraw, libmemlayer, libsec, libmp, libip, libauthsrv) and its GUI backends. Its `sysfile.c` already implements the file syscalls with Plan 9 semantics, so most syscall handlers are a decode followed by one call. We keep the vendored tree close to upstream so 9front fixes keep merging cleanly.

**Reused as-is:** chan/dev/mount machinery, devroot, devcons (for everything but `cons` itself), devmnt (the 9P client), devfs-posix and devfs-win32 (the host filesystem), devpipe, devip, devtls, devssl, devdraw, devmouse, devaudio, devcmd, qio, and the auth code. We compile drawterm's `.c` files but not its `kern/devtab.c` or `kern/devenv.c`; our own copies live in `src/kern/`, so the vendored tree stays unmodified.

**Added by us**

| Piece | Why |
| --- | --- |
| Process model (Proc fields, segments, rfork/exec/await, notes) | drawterm only ever ran its own kprocs |
| `src/kern/devtab.c` | The device table, listing drawterm's devices plus ours |
| Per-machine console device `#y` (`src/kern/devhcons.c`) | drawterm's `#c/cons` reads and writes the host's fds 0 and 1 directly. `#y<id>` serves machine `id`'s `Stdio` through leaf calls into Zig, and is bound before `#c` on `/dev`, so `/dev/cons` is ours and the rest of `#c` stays visible. It also has `/dev/stderr`, which the guest's fd 2 is opened on, so fd 2 reaches the host's stderr. |
| devenv `#e`, from 9front (`src/kern/devenv.c`) | drawterm's has one machine-wide environment and imports the host process's environment on first attach, which breaks `env.scrub`. 9front's keeps one environment per Egrp, which `RFENVG` needs anyway. drawterm's Proc has no `egrp` and `kern/dat.h` stays unmodified, so each process's group is kept on its h9 process record (`src/kern/proc.c`). `#ec` isn't supported. |
| devproc `#p`, from 9front (`src/kern/devproc.c`) | rc, kill and ps need `/proc/n/{note,notepg,noteid,ctl,status,ns,fd,args,ppid,wait}`; acid also needs `mem`, `regs`, `fpregs`, `segment` and `text`, which aren't served yet ([self-host](design/self-host.md)). It serves h9's process records (`src/kern/proc.c`, shared through `src/kern/hproc.h`) instead of 9front's Proc table: a qid holds the machine-local pid, and every walk, open, read and write looks it up in the caller's machine, so a machine can't see, signal or kill another's processes. `status` has the 12 fields `ps` reads: the user is the machine's user (the guest's `$user`), the state is the syscall being served (as 9front's `psstate`, so `Await`, `Sleep`, `Pread`) or `Running`, memory is the process's mapped segments, and the user and system times read 0 until there's per-thread CPU accounting. `ctl` takes `kill` (the process dies with `Killed` at its next note delivery, handler or not), `hang`/`nohang` (recorded only, until a debugger can use it), `close` and `closefiles`. `ns` prints the mount table as 9front does, so binds of host trees show their host paths; `--print` lists this as a caveat. A process takes its record's `debug` lock to swap its fd group, namespace or dot (rfork, chdir) and to mark itself gone at exit, so `fd` and `ns` readers can hold references to them. |
| devdup `#d` | `/fd/N` |

**Zig/C seam rules**

1. drawterm raises errors with `waserror()`/`error()`, built on setjmp/longjmp. A longjmp across a Zig frame skips its `defer` and `errdefer`. So Zig code never sits between a `waserror` and an `error`.
2. drawterm already provides the seam. Each `sysX` wrapper in `kern/sysfile.c` (`sysopen`, `syspread`, `sysbind`, `sysmount`, `sysrendezvous` and so on) runs `waserror`; on error it stores the string for `errstr` and returns -1. Zig calls these directly and turns -1 into an error union. New process and segment calls get wrappers in the same style.
3. C calls Zig only for leaf work that cannot fail into the kernel: the vmm layer, page allocation, the a.out parser, console I/O. A leaf returns a status, and the C side raises any kernel error.
4. drawterm's `up` (`_getproc()`, per host thread) stays authoritative. Every guest thread is created through drawterm's kproc path (`h9_kern_spawn`), so `up` is set before any kernel call. Zig never uses bare `std.Thread` for anything that touches the kernel, and never boots the kernel on a caller's thread.
5. drawterm's Proc has no parent, note group, segments or Egrp. We add these fields, plus a pointer to the Zig-side process record.
6. The build uses `zig build`: C sources go through `addCSourceFiles` with drawterm's flags, and one `build.zig` produces binaries for every host.
7. Guest memory reaches the kernel through `GuestBuf`, because drawterm's `validaddr` is a no-op and h9's translation is the only check. A data buffer (`pread`, `pwrite`, `stat`) is passed to the `sys*` wrapper in place when it is contiguous in host memory, and otherwise goes through a host bounce buffer, so each guest call is one kernel call. Only buffers of 1 GiB or more are split, since drawterm's `long` is 32 bits. Any unmapped byte posts "sys: bad address in syscall". Strings (paths, `errstr`) are always copied into a bounded host buffer first, so no other guest thread can change one during the call.

## Filesystem, boot and I/O

**Root filesystem.** A directory holding an extracted 9front root, served through `#U` (devfs-posix or devfs-win32). This is the fastest path: no 9P round trips. Roots served over 9P and from disk images are proposed ([9p-roots](design/9p-roots.md), [image-roots](design/image-roots.md)).

**Boot sequence**

1. The kernel boots once per host process, on its own thread (see Process model).
2. For each machine, the namespace builder gives the first Proc a fresh Pgrp. It binds the root at `/`, the cwd and other allowed host paths from `#U`, and `#c`, `#p`, `#d`, `#e` and (unless the network is off) `#I` to their usual places. It binds the machine's console over `/dev/cons` and opens fds 0–2 on it. Then it sets the device mask: `#U` and `#C` always (unless `--host-fs` or `--host-cmd`), and `#I` when the network is off. Existing binds keep working, but the guest can't attach a masked device again to reach more of the host.
3. If the binary is given as a host path, it's loaded straight from the host. Otherwise it's looked up through the kernel along `$path`, so lookup works the same over 9P roots.
4. The CLI runs the binary directly with the given argv. `--rc` runs `/bin/rc -c` on the argument instead, and `--ns file` runs `newns` with that file first.

The host's working directory is bound at the guest's `/mnt/term/cwd` and set as the guest's cwd, so that `h9 ls` lists what the user expects.

**Terminal (default):** `/dev/cons` is the machine's console device, which maps to the `Stdio` in `Machine.Options`: the host stdin and stdout for the CLI. A read returns after one host read, as on a terminal, so a typed line reaches the guest when Enter is pressed. That host read happens on a reader thread for the machine run (`src/consin.zig`), never on the guest's thread: the guest sleeps in the kernel (`src/kern/devhcons.c`) until the thread has input, so a note or a teardown interrupts a console read as it does any other blocking call. Nothing is read ahead of a guest's request. At the end of a run the thread is stopped through `Stdio.in_cancel` (the CLI's stdin polls with a wake pipe on POSIX and uses `CancelSynchronousIo` on Windows). Writing `rawon` to `/dev/consctl` switches the host TTY to raw mode (console mode on Windows). Ctrl-C posts an `interrupt` note to the foreground note group (see the CLI section's Signals and TTY for each host). Exit status: an empty `exits` string gives 0; any other string gives 1, and the string is printed to stderr.

## Security, debugging and testing

**Security stance.** The hypervisor isolates guest memory and the CPU, and every guest syscall is served by drawterm's kernel rather than the host's, so the guest never reaches host syscalls, ioctls or the host environment directly. The namespace decides what a guest can reach on the host. Identity: hostowner is the host user's name; devfs maps the host's file ownership onto Plan 9 user strings.

### Sandbox policy

Sandboxing is a `Policy` in `Machine.Options`: a set of capabilities, host paths, network rules and limits. The capability model follows [isobox](https://github.com/can1357/isobox): named capabilities, profiles that set defaults, explicit flags that override them, a printable plan with caveats, and `--strict` to refuse anything the build can't enforce. Unlike isobox, enforcement lives in the shared kernel, so the capability set is the same on every vmm backend; there's no per-host intersection to compute.

| Capability | Mechanism |
| --- | --- |
| `env.scrub` | The host environment is never imported |
| `kernel.isolation` | Guest syscalls are served by drawterm's kernel |
| `ipc.restrict` | Host sockets are reachable only through `#U`, `#I` or `#C`, which the policy controls |
| `fs.read.scope`, `fs.write.scope` | The namespace is an allowlist: only listed host paths are bound from `#U`, each read-only or read-write |
| `fs.read.deny` | Unbound paths don't exist; denied paths inside a bound tree are filtered in devfs |
| `net.disable` | `#I` is masked in the init Pgrp (drawterm's `devmasked`), so the guest can't re-attach it |
| `res.memory` | A cap on the guest-physical page allocator; exact, not a watchdog |
| `proc.timeout` | A machine deadline: a `hangup` note to every process, then a hard teardown after a 2 s grace period |
| `res.pids`, `res.cpu` | A cap on live processes in `rfork`; a cap on vCPUs running guest code at once |

**Vendor hooks.** The policy lives in Zig. drawterm calls it through leaf functions, following seam rule 3. devfs-posix and devfs-win32 call `h9_fs_check(path, op)` (in `src/kern/fscheck.c`) before each walk, open, create, remove, wstat and directory entry. It resolves the host path and asks the Zig leaf `h9_policy_check` for a verdict: allowed, hidden (the walk fails, or the entry is left out of the listing) or read-only ("permission denied"). The machine's compiled plan is set per host thread, because each guest process runs on its own thread. The leaves return an int and never raise kernel errors themselves.

**Access rules.** The plan's rules are the root, the cwd, `/tmp`, each `--readable` and `--writable` path and each `--read-deny` path, all as resolved host paths. A deny rule covering a path wins. Otherwise the longest allow rule covering the path decides between read-only and read-write. Ancestors of allowed paths can be walked and listed but not changed, so `/mnt/term/<path>` works when the host's `/` is unioned after the tree's `/mnt/term`. Anything else is hidden. Bind-level read-only (no `MCREATE`) is a second, coarser check.

**Path resolution.** devfs-posix follows symlinks with `stat`, so a symlink inside a bound tree can point anywhere on the host. Every devfs path is resolved (`realpath`; on Windows the final path of an opened handle, which follows symlinks and junctions and refuses UNC and device paths) and the resolved path is checked against the access rules, on every host. Create, remove and rename act on the name rather than a link's target, so an existing entry is checked by its own canonical name without following it. On macOS that's `F_GETPATH` on an `O_SYMLINK` open, and on Windows the final path of a reparse-point open, so another case, an 8.3 short name or a trailing dot can't dodge a rule on a case-insensitive file system. A new name is appended to its resolved parent. A create over an existing symlink also checks the link's target for writing. Renaming a directory that has any rule strictly beneath it is refused ("permission denied"), because it would move those paths out from under their rules. The check and the host call aren't atomic, so a host process renaming paths at the same time can race it; the plan reports that, and hardlinks under writable paths, as caveats.

**Default profile.** With no sandbox flags the guest can work in the host cwd and nothing else:

| Area | Default |
| --- | --- |
| Root tree (`/`) | Read-only. Installing into the root needs `--writable "$H9ROOT"`. |
| Host cwd (`/mnt/term/cwd`) | Read-write |
| Rest of the host filesystem | Not visible |
| `/tmp` | The host temp dir |
| Network | Full |
| Host commands (`#C`) | Masked |
| Environment | Only the default guest variables plus `--env` |
| Memory | The guest-physical region size (1 GiB; `--memory` sets it, up to 32 GiB) |
| Processes, CPU, timeout | Unlimited, so interactive sessions and long builds aren't cut off |
| Terminal | `cons` and `consctl` only; no host ioctls such as `TIOCSTI` |

`--profile=tight` differs in four ways: the cwd is read-only, `#I` is masked, `/tmp` isn't writable, and a default timeout of 10 minutes applies. `--sandbox DIR` is the tight profile with only DIR bound, read-write, as the cwd; the host cwd isn't bound.

**Plan output.** `--print` compiles the policy and exits without running. The namespace is printed in `newns` format, so it can be saved and replayed with `--ns`:

```text
$ h9 --print --profile=tight --writable ./out --memory 512m --timeout 1m mk
profile:  tight
enforces: env.scrub fs.read.scope fs.write.scope ipc.restrict kernel.isolation net.disable proc.timeout res.memory
limits:   write=scope net=disable memory=512M timeout=1m
devmask:  #C #I #U
namespace:
  bind '#U/Users/me/h9root' /                             ro
  bind '#c' /dev
  bind -b '#y<id>' /dev
  bind -c '#e' /env
  bind '#d' /fd
  bind '#p' /proc
  bind '/arm64/bin' /bin
  bind -a '/rc/bin' /bin
  bind '#U/Users/me/src/proj' /mnt/term/cwd                ro
  bind -c '#U/Users/me/src/proj/out' /mnt/term/cwd/out     rw
access:
  ro   /Users/me/h9root
  ro   /Users/me/src/proj
  rw   /Users/me/src/proj/out
caveats:
  - hardlinks under writable paths can modify host files outside them
  - writes to writable paths are not capped (no res.disk)
  - paths are checked after resolving symlinks, so a host process renaming paths concurrently can race the check
  - /proc/n/ns shows the host paths of bound host trees
  - the h9 process itself is not host-sandboxed
```

Requested capabilities the build can't enforce yet are listed on an `unenforced:` line, and the setting falls back to the safer choice: `--write=ephemeral` and `--write=overlay` deny writes, and `--net=outbound` leaves the network as it is. `--strict` refuses them with exit 2 instead.

**Examples**

```sh
h9 --profile=tight ls -l                                  # read-only, no network
h9 --net=disable --writable ./out --rc 'mk install'        # writes only to ./out
h9 --memory 256m --pids 32 --cpus 2 --timeout 30s rc       # resource caps
h9 --readable ~/src/proj --read-deny ~/src/proj/.env \
    --rc 'grep -n TODO /mnt/term/$home/src/proj/*.c'       # read a tree, hide secrets
h9 --strict --write=overlay mk                             # usage error, exit 2: overlay isn't enforced yet
```

Host paths given to `--readable` and `--writable` appear in the guest under `/mnt/term/<host path>`, as in drawterm; the cwd stays at `/mnt/term/cwd`.

### Debugging

- `--trace` logs each syscall with its arguments, result and error string, prefixed by pid, like 9front's ratrace.
- acid (Plan 9's debugger) needs devproc's `mem` and `regs`, which aren't served yet ([self-host](design/self-host.md)).
- `--dump-on-fault` prints the Ureg, the faulting address and a symbolized PC from the a.out symbol table.
- There's no gdb stub.

### Testing and CI

- Unit tests in Zig for the a.out loader, the page allocator and the syscall decoders.
- Integration tests run real 9front binaries from a pinned root tree. Each case is tagged with the proposal it proves, and skips while that proposal isn't implemented ([design/README.md](design/README.md#tests)).
- `zig build integration` runs real binaries from the root tree through the `h9` CLI as subprocesses, so each case gets a fresh kernel and checks exit codes end to end; it skips when there's no tree. `zig build proposal -Dp=baseline` runs the baseline's demos and cases. The Lima test VMs get the tree with `scripts/lima/vm push-root`.
- CI isn't set up yet ([ci](design/ci.md)).

## CLI

The CLI is a thin wrapper: it parses argv into `Machine.Options`, runs one machine and maps the result to an exit code.

```
h9 [h9-flags] [--] program [args...]
h9 [h9-flags] --rc 'command line'
h9 [h9-flags]                       # interactive rc if stdin is a TTY, otherwise a usage error
h9 --version | --check | --help      # tool functions; -h alone is --help
```

**Parsing rules**

- No subcommands. `h9 ls` must run 9front's `ls`, so tool functions such as `--version` and `--check` are flags instead.
- Flag parsing stops at the first non-flag, as with `env` and `nice`, so `h9 ls -l` passes `-l` to `ls`. `--` ends h9's flags explicitly.
- Long flags only, so h9's flags are never confused with Plan 9-style short flags. There are no short aliases. The exception is `-h` as the only argument, which is `--help`: alone it can't be a program's flag, and anywhere else it's a program name or argument.

**Program resolution**

| Argument | Resolution |
| --- | --- |
| Starts with `./` or `../` (`./hello`, `../out/x`) | A host path relative to the host cwd, read on the host. It doesn't need to be in the guest namespace. |
| Absolute (`/bin/cat`) | A guest path, resolved in the guest namespace. To run an absolute host path, use the guest view of it (`/mnt/term/...`) or a relative path. |
| Bare name or other relative path (`ls`, `aux/vga`) | Looked up in the guest namespace through `$path` (default `(. /bin)`) |
| `--rc 'cmd'` | Runs `/bin/rc -c 'cmd'`; the remaining arguments become `$*` |
| `--ns file` | Runs `newns` with the file before the program |

**Flags**

| Flag | Meaning |
| --- | --- |
| `--backend auto\|hvf\|kvm\|whp\|emu` | `auto` (the default) uses the host hypervisor, and otherwise falls back to the emulator with a warning |
| `--root DIR` | The root tree. If omitted, use `$H9ROOT`, then the default install location (`.local/9front/root` in development builds until there's an installer) |
| `--env name=value` (repeatable) | Sets a guest environment variable. The host environment isn't imported. |
| `--cwd PATH` | The guest cwd. Defaults to `/mnt/term/cwd`, the host cwd bound into the guest |
| `--rc 'cmd'` | See program resolution |
| `--ns file` | Replays a namespace file (newns syntax: `bind`, `mount`, `unmount`, `cd`, `clear`, with `-a -b -c -C`) after the policy's namespace and before the program is looked up. It's a guest path, read as newns reads it, and `--print`'s namespace output replays as is. Failed operations are skipped, as in newns; a syntax error is exit 125. |
| `--profile default\|tight` | Sets the sandbox defaults (see Sandbox policy). Explicit flags override it. |
| `--readable PATH` (repeatable) | Binds a host path read-only at `/mnt/term/PATH` |
| `--writable PATH` (repeatable) | Binds a host path read-write; under the cwd it overrides a read-only cwd |
| `--read-deny PATH` (repeatable) | Hides a host path inside a bound tree |
| `--write none\|scope\|ephemeral\|overlay` | Deny writes, or persist only writable paths. `ephemeral` and `overlay` are accepted but not enforced yet, and deny writes ([ephemeral-writes](design/ephemeral-writes.md), [overlay](design/overlay.md)) |
| `--net disable\|outbound\|enable` | Network policy. `outbound` is accepted but not enforced yet, and leaves the network as it is ([net-policy](design/net-policy.md)) |
| `--memory SIZE` | Caps guest memory (`512m`, `2g`) |
| `--pids N`, `--cpus N` | Caps processes and concurrently running vCPUs |
| `--timeout DURATION` | Posts `hangup` at a deadline, waits up to 2 s, then tears down the machine |
| `--strict` | Refuses any requested capability this build can't enforce (exit 2) |
| `--print` | Prints the compiled policy and namespace, then exits |
| `--host-fs` | Exposes all of `#U`, not just the root and cwd |
| `--host-cmd` | Enables devcmd |
| `--sandbox DIR` | The tight profile with only DIR bound, read-write, as the cwd. Can't be combined with `--host-fs` or `--host-cmd` |
| `--trace[=FILE]` | ratrace-style syscall log, to stderr by default |
| `--dump-on-fault` | Prints the Ureg and a symbolized PC when the guest faults |
| `--check` | Runs a test program on each backend built in, or just `--backend`'s (on HVF this also checks the entitlement), reports the vCPU limit, and runs `/bin/echo` from the root tree. Exits 0, or 125 if h9 can't run programs from the root |
| `--version` | Prints the h9 version (`git describe`, or `-Dversion` in releases), the pinned 9front release and drawterm revision, and the backends built in |
| `--help`, `-h` | Prints the usage to stdout and exits 0 (`-h` only as the only argument) |

**Default guest environment:** `user` is the host user name, `home=/usr/$user`, `path=(. /bin)`, `cputype` and `objtype` come from the backend's architecture, `sysname=h9` and `service=terminal`. Everything else has to be passed with `--env`, which keeps host secrets out of the guest by default.

**Exit codes**

| Code | Meaning |
| --- | --- |
| 0 | `exits(nil)` or `exits("")` |
| 1 | Any other `exits` string, which is also printed to stderr |
| 2 | Usage error |
| 125 | h9 itself failed: no hypervisor, VM creation failed, or the root wasn't found |
| 126 | The program was found but isn't a runnable a.out (bad magic or wrong architecture) |
| 127 | The program wasn't found |

The 125–127 codes follow `env` and `docker run`, so scripts can tell h9 failures from guest failures.

**Signals and TTY**

- **Ctrl-C:** posts an `interrupt` note to the foreground note group. A second Ctrl-C within a second tears down the machine.
- **SIGTERM and SIGHUP:** post a `hangup` note to every process, then tear down the machine 2 s later, or sooner if it has exited by then.
- **Raw mode:** the host TTY goes raw only when the guest writes `rawon` to `/dev/consctl`, and goes back on `rawoff`, on the last close of `/dev/consctl` (as on 9front), at the end of the run, and on a panic.

How each host delivers these:

| | Linux and macOS | Windows |
| --- | --- | --- |
| Ctrl-C | The terminal driver turns it into SIGINT (ISIG) in cooked mode | `CTRL_C_EVENT` to a `SetConsoleCtrlHandler` handler, while `ENABLE_PROCESSED_INPUT` is on |
| Ctrl-C in raw mode | ISIG is off, so 0x03 reaches the guest as a key, as Del does on 9front under rawon | Processed input is off, so the same |
| Hangup | SIGHUP (terminal closed), SIGTERM | `CTRL_CLOSE_EVENT`, `CTRL_LOGOFF_EVENT`, `CTRL_SHUTDOWN_EVENT`; Windows kills the process about 5 s after these, so the grace period has to be shorter. `CTRL_BREAK_EVENT` posts `interrupt` |
| Raw mode | termios: clear ICANON, ECHO and ISIG | Console mode: clear `ENABLE_LINE_INPUT`, `ENABLE_ECHO_INPUT` and `ENABLE_PROCESSED_INPUT`; set `ENABLE_VIRTUAL_TERMINAL_INPUT` |
| Line endings | The driver gives `\n` | A console in line mode gives `\r\n`, which the stdin reader turns into `\n` |

The CLI's handlers (`src/hostsig.zig`) only record the event: on POSIX a signal handler writes a byte to a self-pipe that a watcher thread reads, and on Windows the console control handler runs on its own thread already. The watcher calls `Machine.Signals` (`interrupt`, `hangup`, `stop`), which sets a bit and wakes `Machine.run`'s waiting thread, and that thread posts the notes. Posting from a thread that isn't a kernel process is safe because the post (`h9_kern_postmach`) only queues the note and calls drawterm's `procinterrupt`, neither of which uses `up`. Raw mode reaches the CLI through `Machine.Stdio.raw`, a callback the console device calls on `rawon` and `rawoff`; the library itself never touches the host terminal. On Windows the close handler waits out the grace period before returning, since Windows ends the process when it returns.

**Code structure**

| File | Role |
| --- | --- |
| `src/main.zig` | About 50 lines: argv to `cli.parse`, then `Machine.init` and `run`, then the exit code |
| `src/cli.zig` | Pure parsing from `[]const []const u8` to a `Config` or a usage error. No I/O; unit-tested. |
| `src/root.zig` | Exports `Machine` and `Machine.Options`. No CLI types. |

```zig
pub const Options = struct {
    backend: vmm.BackendKind = .auto,
    arch: ?vmm.Arch = null,             // null: the host's
    root: ?[]const u8 = null,           // host directory served as /
    cwd: ?[]const u8 = null,
    env: []const EnvVar = &.{},
    policy: Policy = .{},               // profile, binds, read-deny, net rules, limits, host_fs, host_cmd
    trace: ?*std.Io.Writer = null,
    dump_on_fault: bool = false,
    ns: ?[]const u8 = null,             // newns file to replay
    owned_vcpus: ?u32 = null,           // for tests of the vCPU pool
    signals: ?*Signals = null,          // Ctrl-C and hangup from the embedder
    stdio: Stdio,                       // host fds behind the console
};
pub fn run(m: *Machine, prog: Program, argv: []const []const u8) !ExitStatus;
```

`cli.zig` is the only code that knows flag strings; tests and other embedders build `Options` directly. `stdio` and `trace` are passed in rather than taken from the process. That keeps the machine API free of CLI-global state and lets integration tests capture a machine's output and syscall trace.

## Sources

- [9front source (GitHub mirror)](https://github.com/9front/9front): `sys/src/9/arm64`, `sys/src/9/pc64`, `sys/src/9/port/sysproc.c`, `sys/include/a.out.h`, `sys/include/tos.h`, `sys/src/libc/9syscall/sys.h`
- [9front drawterm (GitHub mirror)](https://github.com/9front/drawterm): `kern/sysfile.c`, `kern/dat.h`, `kern/devtab.c`, `LICENSE`
- [hyper-linux](https://github.com/zw3rk/hyper-linux): `src/shim.S`, `src/thread.h`, `LICENSE`
- [9front release announcement, OSnews](https://www.osnews.com/?p=145669)
- [isobox](https://github.com/can1357/isobox): capability model, profiles, plan caveats and `--strict`
