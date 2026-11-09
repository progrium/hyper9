---
id: 95
slug: native-backend
title: Native backend
status: implemented
created: 2026-11-08
authors: [progrium]
depends: []
areas: [vmm, cli, sandbox, tests]
---

# Proposal: Native backend

Nov 8, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

A vmm backend, `src/vmm/native.zig`, that runs guest code directly on the host CPU with no hypervisor and no emulator, on Linux (x86\_64 first, then arm64). Each address space is a small stub process whose memory comes from one shared memfd, and each of the stub's threads runs one vCPU. The host kernel turns every guest syscall into a SIGSYS in the stub, through Syscall User Dispatch with a seccomp filter behind it, and the stub hands the registers to h9 over a shared page. Compute runs at native speed, the backend is MIT so it ships in `h9`, and it runs where KVM can't: containers without `/dev/kvm` and cloud VMs without nested virtualization. macOS and Windows aren't covered; Rationale says why.

## Background

Without a hypervisor, h9 today runs only on the emulator, which is in `h9-emu` and not the MIT `h9`, and runs compute about 5–7× slower than hardware (DESIGN.md, Emulator backend). Many Linux hosts h9 should run on have no usable KVM: CI containers, most PaaS and sandbox VMs (Firecracker guests among them), and Docker without `--device /dev/kvm`. Go's `plan9/amd64` binaries run only on the emulator there ([go-compat](0007-go-compat.md)).

The vmm contract is already in Plan 9 terms: address spaces over host memory, a Ureg, and syscall, fault, breakpoint and interrupted exits. The emulator shows the contract can be met without kernel mode or an MMU. A user-mode process on the same architecture meets it too, provided the host kernel hands every guest syscall to h9 instead of executing it.

The standard ways to do that on Linux are those gVisor's platforms use: ptrace (`PTRACE_SYSEMU`, which User-Mode Linux introduced) and seccomp traps ("systrap"). Linux 5.11 added a third, Syscall User Dispatch (`PR_SET_SYSCALL_USER_DISPATCH`), made for Wine: every syscall from outside one allowed address range raises SIGSYS while a selector byte in user memory says to block.

### Spike results

A spike (in the project's `native-backend-spike/` folder, not in the repo) ran hand-written amd64 code using 9front's syscall convention (number in BP, arguments on the stack, `SYSCALL`) at `UTZERO` in a forked stub, on an x86\_64 Firecracker VM with 4 vCPUs and Linux 6.18. The host served `_nsec`, `pwrite` and `exits`, a kick (a signal to the stub) stopped a spinning guest with its registers intact, and a fault on an unmapped page was served by having the stub map a page there and retry. Measured costs per syscall:

| Path | Cost |
| --- | --- |
| Native Linux `getppid`, for scale | 0.10 µs |
| SIGSYS trap answered inside the stub (no handoff): seccomp / Syscall User Dispatch | 1.0 µs / 0.85 µs |
| Seccomp trap, futex handoff, stub and h9 on different CPUs | 27 µs |
| The same, both pinned to one CPU | 3.1 µs |
| The same, spinning up to ~2000 pauses before the futex | 1.4–1.9 µs |
| `PTRACE_SYSEMU`, different CPUs / one CPU | 26 µs / 3.7 µs |

The 27 µs is the cost of waking an idle vCPU inside a VM, the same cost that puts nested KVM's `OUT` exit at 19 µs in DESIGN.md; bare metal wakes a CPU far faster, but it wasn't measured. Spinning briefly before sleeping brings the round trip near HVF's 1.1 µs and the emulator's 0.8 µs. Seccomp beat ptrace, and handles faults without injecting syscalls into the tracee.

Two findings shaped the design:

- **On the spike's kernel, syscall numbers 335 and 336 skip seccomp entirely.** 9front leaves whatever the program had in RAX at `SYSCALL`, so a guest that happened to hold 335 got the host's syscall instead of a trap (here, a SIGILL that killed the stub). Mainline kernels run seccomp for every number; this one is patched. Syscall User Dispatch trapped 335 and 336 correctly, as its check comes earlier, so it's the primary mechanism and seccomp the backstop.
- **A forked stub can't use 9front's address layout.** amd64's `USTKTOP` is `0x7FFFFFFFF000`, the top of the Linux user address space, where Linux puts the stub's own stack, vDSO and vvar. The stub has to be a tiny static program that leaves those ranges free.

## Proposal

### The stub

`h9-stub` is a freestanding static program per architecture, a few hundred lines of Zig and assembly, embedded in `h9` and started with `execveat` on a memfd copy (or `posix_spawn` of `/proc/self/exe` with an argument, if that turns out simpler). It's linked high, at a fixed address above every guest range (above 2^46 on x86\_64), with no libc, and runs on a stack in its own image; the kernel's initial stack, vDSO and vvar are unmapped at startup, so the guest's whole range is free. It inherits two file descriptors: the machine's guest RAM memfd and its control page.

At startup the stub sets an alternate signal stack, installs one handler for SIGSYS, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP and the kick signal (with every signal masked inside it), enables Syscall User Dispatch with its own text as the allowed range, installs its seccomp filter, and waits on its control page for its first run.

The handler copies the signal frame's registers and FP state into the control page with the exit kind (syscall, fault with address and access, breakpoint, interrupted), wakes h9, and waits. When h9 resumes it, the handler first carries out any requests h9 queued (map or unmap a range of the memfd at a guest address with given permissions, flush the I-cache for a range on arm64, fork, exit), then copies the registers back into the frame and returns into the guest. The handoff is a futex on the control page, with a short adaptive spin before sleeping on either side.

### The backend

`src/vmm/native.zig` implements Backend, AddressSpace and Vcpu with the same method set as the others:

- **Backend** owns one memfd sized to the machine's memory cap (sparse), and hands out pages from it with `gphys.zig`'s allocator, as HVF and KVM do from their RAM region. h9 maps the whole memfd once, so `translate` and `copy` read guest memory in place.
- **AddressSpace** is a stub process plus a list of regions. `map` and `unmap` queue requests the stub carries out before it next runs guest code; an address space that isn't running gets them at its next `run`. `codeChanged` queues an I-cache flush (a no-op on x86).
- **Vcpu** is a stub thread as seen from one h9 thread. `setAddressSpace` binds it to a stub, and its first run there takes a thread of the stub, which it keeps while it's free. `run` resumes the stub and waits for its next exit. `getUreg` and `setUreg` convert between the signal frame and `vmm.Ureg`, keeping the selectors and system flags as the shim does today (`arch.sanitize`); `getExtra` and `setExtra` use the frame's FXSAVE/XSAVE area on x86 and its FP/SIMD record on arm64, and the thread pointer is `FS_BASE` or `TPIDR_EL0`, set through the stub. `kick` sends the stub `SIGURG` with `tgkill`; the handler reports `interrupted` with the registers where the guest stopped, which is simpler than KVM's shim cases since there's no shim path to be in.
- **Processes.** One stub per address space, so 9front's fixed layout works and `rfork` without `RFMEM` gets a new stub. `RFMEM` shares data and bss by mapping the same memfd ranges into both stubs, with a private copy of the stack segment, as 9front shares segments. A Plan 9 process has one thread, but a Linux program under the Linux personality has as many as it starts, each on its own vCPU in the same address space (design/0049-linux-threads.md). So a stub has a control thread, which never runs guest code, and starts another thread for each vCPU that runs the space; they run guest code in parallel, as on a hypervisor. `shootdown` has the control thread carry out the queued unmaps: its `munmap` is the host kernel's, which shoots down the other threads' TLBs before it returns.
- **Limits.** There's no hardware vCPU cap, so `maxVcpus` is the stubs the host's `RLIMIT_NPROC` and file descriptors allow, and every process owns its vCPU; `cpupool.zig` isn't needed. `--cpus` still caps how many run at once.

### Selection and CLI

`--backend native` selects it. `.auto` tries KVM, then native, then the emulator: native is faster than the emulator and built into every Linux `h9`, so on hosts without KVM `h9` works out of the box instead of failing with `HypervisorUnavailable`. A host where Syscall User Dispatch is missing (before 5.11, or a kernel without generic entry on arm64) or seccomp is disabled reports `HypervisorUnavailable` for native, with the reason, and auto moves on. `--check` runs its test program on native too, including a guest that makes a syscall with each of a list of unusual numbers in RAX (335, 336, -1, numbers above the table) and must see every one trapped.

## Rationale

**Why stub processes and not threads in the h9 process.** Every 9front process is linked at the same `UTZERO` and has its own stack at the same `USTKTOP`, so two processes can't share one host address space, and h9's own image and heap would sit in the guest's range. Relinking or relocating guests would break the Plan 9 ABI and Go binaries.

**Why Syscall User Dispatch first, then seccomp, and not ptrace.** ptrace costs about the same here and more on bare metal (two context switches through the tracer per stop), needs syscall injection for every `mmap`, and occupies the one tracer slot acid-like debugging of the stub would want. Seccomp alone misses numbers a patched kernel handles before it, as the spike found; Syscall User Dispatch traps by address before the syscall table is consulted. Syscall User Dispatch isn't a security boundary, since the guest could flip the selector byte if it found it, so seccomp stays behind it as one.

**Why not macOS.** XNU reads the syscall number from x16, not 9front's R0, so a guest `SVC` runs some Darwin call; there's no seccomp, and Mach exception ports don't see `SVC`. Guests would have to be rewritten (`SVC #0` to `BRK`, found through the a.out symbol table), which can't cover code a guest generates or jumps into the middle of, so a hostile binary reaches the host. HVF is on every Apple Silicon Mac anyway; the hosts that lack it are VMs, where the emulator is the answer.

**Why not Windows.** The same rewriting would be needed (`SYSCALL` to `UD2`, caught through the debug API), with two more problems: Windows maps views in 64K units, which breaks 4K-granular shared segments, and it reserves the top 64K of user space, where amd64's `USTKTOP` sits. WHP covers Windows hosts with virtualization.

**Why not an "insecure mode" that skips trapping.** The request that started this asked for one. On Linux, trapping is what makes native work at all, and the same filter that catches syscalls keeps the guest off the host's, so isolation comes almost for free; there's no cheaper insecure variant worth having.

**Other architectures.** Native runs only the host's architecture. 386 binaries could run in a 32-bit compatibility-mode stub on x86\_64, as 9front's `INT $64` raises a general protection fault from ring 3, but that's left for later.

## Compatibility

New `--backend native` value and `vmm.BackendKind.native`. `.auto` on Linux without KVM picks native instead of the emulator, so programs that ran slowly there run fast; output and traces must be identical, which the shared backend suite checks. `Machine.Options` is unchanged. Nothing changes in the root tree or `third_party/`. `h9 --version` lists `native` among the built-in backends on Linux.

## Security

Guest code runs in a host process as the user running `h9`, separated from the host only by the kernel's syscall filtering, where the hypervisor backends rely on hardware and the emulator on never executing guest code. The layers are:

- **Syscall User Dispatch** sends every syscall from outside the stub's text to the handler.
- **The seccomp filter** allows only the calls the stub makes (`futex` on the control page, `rt_sigreturn`, `mmap`/`munmap`/`mprotect` on the RAM memfd with fixed addresses below the stub, `tgkill` to itself, `clone` for `rfork`, `exit_group`), checked by arguments where seccomp can, and only from the stub's text; everything else kills the stub. A guest that finds the selector or jumps into the stub's code can at most make those calls, which reach only its own machine's memory.
- **The stub's own pages** are mapped without write permission, so the guest can't change them, and its control page holds nothing the host trusts beyond the register image, which h9 sanitizes as it does for every backend.
- **The stub runs with no privileges:** `PR_SET_NO_NEW_PRIVS`, no file descriptors but the two it needs, and, where unprivileged user namespaces are allowed, empty mount, network, IPC and PID namespaces.

So a guest gets no host filesystem, network or process access that the sandbox `Policy` doesn't already give it through the kernel. The remaining risk is a kernel bug in signal delivery or seccomp, the same surface gVisor's systrap platform accepts. `--check` refuses native (and auto skips it) on a kernel where its probe sees an untrapped syscall.

## Done when

- `tests/backends.zig` runs every backend case on `native` as well, on x86\_64 Linux: hello, exits, faults, kicks and the kick race, timeouts, notes, segments, the memory cap, and FP state carried across exits, with traces identical to the emulator's.
- The `[baseline]` integration cases pass with `H9_TEST_BACKENDS=native` on x86\_64 with an amd64 root, and later on arm64.
- The go-compat cases pass on native on x86\_64.
- Cases tagged `[native-backend]`:
  - `test "--check reports native and runs its trap probe [native-backend]"`
  - `test "auto uses native when KVM is unavailable [native-backend]"`
  - `test "a guest syscall with any value in AX traps to h9 [native-backend]"`
  - `test "a guest that jumps into the stub can't open a host file [native-backend]"`
  - `test "rfork with RFMEM shares data and bss but not the stack [native-backend]"`
- Demo: in a container without `/dev/kvm`, `h9 ls /bin | wc -l` runs on native, and `zig build bench` reports native's loop time and `pwrite` round trip next to the emulator's.

## Implementation

1. The stub for x86\_64: startup, Syscall User Dispatch, seccomp filter, handler, control page protocol, map requests. Test it alone with the spike's hand-written guest.
2. `src/vmm/native.zig` with one address space and one vCPU, until the hello and exits backend cases pass. Add `native` to `vmm.Kind`, `BackendKind` and `--backend`.
3. Faults, kicks, notes, FP state and the thread pointer, until the backend suite passes.
4. Many address spaces: a stub per address space, `RFMEM`, and stub teardown when a process exits or the machine is destroyed.
5. Auto selection, `--check` and its probe, `--version`, README.
6. The `[baseline]` suite and go-compat on native; `zig build bench` numbers.
7. arm64, with I-cache flushes on `codeChanged` and the arm64 signal frame.

## Open issues

- Whether Syscall User Dispatch is usable on arm64 kernels h9 targets, which depends on arm64's move to the generic entry code; if not, arm64 relies on seccomp alone, and `--check`'s probe decides per host.
- How long to spin before sleeping on the futex, and whether h9 should spin at all when the host has fewer CPUs than running guests. Bare-metal numbers are needed.
- Whether auto should prefer native over the emulator from the start, or only after it has run the full suite in CI for a while.
- Whether the empty namespaces are worth their setup cost per stub, given seccomp already confines it.

## Updates

- 2026-11-08: Choices made in the first implementation, on x86\_64:
  - Linux threads ([linux-threads](0049-linux-threads.md)) landed before this, so a stub isn't one guest thread. It has a control thread that never runs guest code, and starts a thread for each vCPU that runs the space, so a Linux program's threads run in parallel. A vCPU goes back to the stub thread it last ran on while that one is free, which keeps the AVX state `Extra` doesn't carry with it. `AddressSpace.shootdown` has the control thread carry out the queued unmaps, and its host `munmap` shoots down the other threads' TLBs.
  - Each stub thread has its own control page, signal stack, and FS base, and the handler finds its thread from the signal stack it runs on. The seccomp filter also lets through `clone` with exactly the thread flags, `gettid`, `sigaltstack`, and `prctl`, still only from the stub's range.
  - The empty namespaces aren't used: the stub runs in its own session (so the terminal's signals go to h9 alone) with no file descriptors but the RAM file and its control pages, behind dispatch and the filter.
  - CPUID can't be hidden, so guests see the host's AVX and AVX-512, unlike under KVM's shim.
  - arm64 isn't built. It's step 7, and the arm64 Open issue still stands.
  - "os/signal receives interrupt on Ctrl-C" fails in about 3% of runs on native, with the program hanging or crashing when the note lands just after a Go M's `rfork(RFMEM)`. It isn't root-caused yet.
- 2026-11-09: A security audit found that the Security section above overstates the backend's containment, and `auto`'s fallback to native was changed in response.
  - The stub's control page is mapped read-write in the stub's address space, which is the guest's own, so guest code can write it directly; h9 then reads `why`, the `ops`/`nops` request queue, fault fields, and `fs_base`/`gs_base` back from it and acts on them. A guest can queue an `mmap` of the RAM memfd, or jump to a `SYSCALL` in the stub's text (both of which the seccomp allow-set must permit, since mapping guest RAM at arbitrary offsets is how guest memory works), and reach the whole machine's memory, which holds the overlay's host pointers. So on the native backend a guest can obtain host code execution in the (un-host-sandboxed) h9 process. This is inherent to running guest code in h9's own address space with address-keyed gates (Syscall User Dispatch and seccomp), which the guest defeats by controlling the instruction pointer; it can't be closed by hardening the gates, only by not treating native as a boundary.
  - Therefore `auto` no longer selects the native backend. A host without a usable hypervisor falls back to the emulator; where the emulator isn't built either, `auto` fails with the hypervisor's reason and the CLI points at `--backend native` as an explicit opt-in for a trusted guest. `--backend native` now prints a warning that it isn't a security boundary. This changes the Compatibility and Selection sections' statement that `auto` picks native on Linux without KVM; the backend itself is unchanged.
  - This note corrects an accepted, signed proposal's security claims; DESIGN.md and the manual were updated to match, and the doc may need re-signing.
