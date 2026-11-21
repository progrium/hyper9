# Engines: the vmm layer, its backends, and the guest shims

This describes, as built, the `vmm` interface, the hypervisor, native, and emulator backends behind it, and the shims that run in guest kernel mode. h9's own CPUs for the emulator are in [jit.md](jit.md), [h86.md](h86.md), [hx64.md](hx64.md), and [ha64.md](ha64.md). [SPEC.md](../SPEC.md) describes h9 as a whole and lists the rest of the spec.

## Contents

- [Hypervisor layer (`vmm`)](#hypervisor-layer-vmm)
  - [Shared pieces](#shared-pieces)
  - [KVM](#kvm)
  - [WHP](#whp)
- [Native backend (`native`)](#native-backend-native)
  - [Stubs](#stubs)
  - [Syscalls and the filter](#syscalls-and-the-filter)
  - [Threads and runs](#threads-and-runs)
  - [Speed](#speed)
- [Emulator backend (`emu`)](#emulator-backend-emu)
  - [Scope](#scope)
  - [How the Unicorn backend works](#how-the-unicorn-backend-works)
  - [Atomics](#atomics)
  - [Memory](#memory)
  - [Implementation](#implementation)
  - [What it's for](#what-its-for)
  - [Limits and selection](#limits-and-selection)
- [Guest shims](#guest-shims)
  - [What the shim does](#what-the-shim-does)
  - [The amd64 shim](#the-amd64-shim)

## Hypervisor layer (`vmm`)

A small Zig interface hides the three hypervisor APIs and the emulator. Everything above it is written once.

```zig
// vmm.create picks a backend at run time: .auto tries the host hypervisor, then the emulator; native is explicit-only (not a security boundary).
pub fn create(gpa, io, want: BackendKind, opts: Options) !Backend;   // Options: { arch: Arch, memory: ?u64 }

// One address space per Plan 9 process. Each backend decides how to realize it:
// the hypervisors build 4K page tables, the emulator keeps a virtual-address -> host-memory map.
const AddressSpace = union(Kind) {             // Kind: hvf, kvm, whp, native, emu
    pub fn destroy(self) void;                 // mapped pages belong to the caller
    pub fn map(self, va: u64, mem: []align(4096) u8, perms: Perms) !void;
    pub fn unmap(self, va: u64) void;          // the mapping map made at va; its pages stay allocated
    pub fn translate(self, va: u64, len: u64) ?[]u8;      // host view, for syscall arguments
    pub fn shootdown(self) void;               // returns once no other vCPU can reach what unmap removed
    pub fn copy(self, va: u64, buf: []u8, dir: enum { read, write }) bool;  // /proc/n/mem, from any thread
    pub fn codeChanged(self, va: u64, len: u64) void;     // a write to executable pages: drop cached code
};
const Backend = union(Kind) {
    pub fn kind(self) Kind;
    pub fn destroy(self) void;
    pub fn allocPages(self, n: usize) ![]align(4096) u8;  // memory that address spaces can map
    pub fn freePages(self, mem: []align(4096) u8) void;   // a whole allocation, no longer mapped
    pub fn maxVcpus(self) !u32;
    pub fn newAddressSpace(self) !AddressSpace;
    pub fn createVcpu(self) !Vcpu;             // on the thread that will run it
};
const Vcpu = union(Kind) {
    pub fn destroy(self: *Vcpu) void;
    pub fn setAddressSpace(self: *Vcpu, as: AddressSpace) !void;
    pub fn run(self: *Vcpu) !Exit;             // blocks until the next exit
    pub fn getUreg(self: *Vcpu, u: *Ureg) void;        // Plan 9 Ureg layout
    pub fn setUreg(self: *Vcpu, u: *const Ureg) void;
    pub fn getExtra(self: *Vcpu, x: *Extra) !void;     // FP/SIMD state and thread pointer
    pub fn setExtra(self: *Vcpu, x: *const Extra) !void;
    pub fn kick(self: *Vcpu) void;             // safe from any thread
};
const Ureg = union(Arch) { arm64: arm64.Ureg, amd64: amd64.Ureg, i386: ia32.Ureg };
// arm64: Q0-Q31, FPCR, FPSR, TPIDR_EL0. x86: the 512-byte FXSAVE image
// (x87, MXCSR, XMM), the thread pointer (the FS base on amd64, the TLS
// segment's base on 386), and on amd64 the GS base (ARCH_SET_GS).
const Extra = union(Arch) { arm64: Arm64Extra, amd64: X86Extra, i386: X86Extra };
const Exit = union(enum) { syscall, fault: Fault, breakpoint, interrupted, halted, other: u64 };
```

Each backend is a file under `src/vmm/` with the same method set; the unions dispatch to it. Backends not built into a given h9 are replaced by a stub whose `create` fails with `BackendNotBuilt`, so every host builds the same code.

A backend that can't run the binary's architecture fails with `WrongArch`; HVF runs arm64 only, KVM the host's architecture (arm64 or amd64), WHP and native amd64 only, and only the emulator runs 386.

`src/arch/i386.zig` holds the 386 Ureg, notify frame, and `noted` sanitizing without backend details, so a hardware backend could add 386 later with a compatibility-mode code segment and an `INT $64` gate in its shim.

The contract is in Plan 9 terms (address spaces, Ureg, syscall exits) rather than hardware terms such as guest-physical memory and page tables. That keeps page-table building inside the hypervisor backends, and lets the emulator implement the contract without emulating kernel mode or an MMU.

The interface was shaped around all three hypervisors, so the table and rules below cover WHP as well. HVF, KVM ([kvm](../design/epoch-0/kvm.md)), and WHP ([whp](../design/epoch-0/whp.md)) on Windows x86\_64 are built; WHP on Windows on ARM isn't yet (see WHP below).

| Operation | macOS: Hypervisor.framework | Linux: KVM | Windows: WHP |
| --- | --- | --- | --- |
| Create VM | `hv_vm_create` | `KVM_CREATE_VM` | `WHvCreatePartition` + `WHvSetupPartition` |
| Map memory | `hv_vm_map` | `KVM_SET_USER_MEMORY_REGION` | `WHvMapGpaRange` |
| Run vCPU | `hv_vcpu_run` | `KVM_RUN` | `WHvRunVirtualProcessor` |
| Kick vCPU | `hv_vcpus_exit` | `immediate_exit` + signal to the thread | `WHvCancelRunVirtualProcessor` |
| Access needed | `com.apple.security.hypervisor` entitlement | read/write on `/dev/kvm` | the optional Windows Hypervisor Platform feature |

**Rules that keep the interface portable**

- **Exits:** the shim exits to the host by storing to an unmapped doorbell address (MMIO), or with `OUT` on x86. All three hypervisors hand that exit to userspace, so we don't depend on HVC or VMCALL handling, which differs across them. On arm64 KVM in particular, the kernel handles HVC itself unless hypercall filtering is configured.
- **Threads:** a vCPU is created, run, and destroyed on one host thread, which is HVF's rule and the strictest of the three. `kick` is the only call allowed from another thread.
- **Memory:** one large guest-physical region is mapped once at VM creation. A host-side page allocator hands out guest-physical pages from it. We never map per segment, because KVM caps the number of memory slots and mapping calls are slow everywhere. The host backs the region's pages only when they're first touched, and freed pages go back to it (`src/vmm/gphys.zig`): each free range keeps the span of it that may be dirty, and once that span reaches 32 MiB it's released (`madvise(MADV_DONTNEED)` on KVM, a hole punched in the RAM file on the native backend, and, with the range taken out of the VM and put back, fresh pages mapped over it on HVF and a decommit and recommit on WHP). A smaller dirty span is zeroed as it's handed out again, so small frees and reallocations cost no syscalls, and never-used or released pages aren't touched when they're handed out.
- **Page size:** guest page tables use 4K pages on every host, matching 9front's page size on both architectures. hyper-linux shows HVF guests can use 4K pages. Only the single host memory region has to be aligned to the host page size (16K on Apple Silicon).
- **No hypervisor:** `create` fails cleanly with a clear message, and `auto` falls back to the emulator when it's built in. The native backend is never chosen automatically, since it shares h9's process and isn't a security boundary; it needs an explicit `--backend native`, and the CLI points at it when nothing else can run.

### Shared pieces

The hypervisor backends share:

- `src/vmm/gphys.zig`: the guest-physical page allocator over the one RAM region, and the address space type (a list of regions over page tables).
- A page-table format: `pt_arm64.zig` (TTBR0 for user, a TTBR1 kernel half with the shim, the doorbell page and the per-vCPU shared pages, and the system register values the host sets) or `pt_amd64.zig` (4-level tables, with the kernel half under PML4 entry 511, which every address space's root shares).
- `x86.zig`: the amd64 CPU state the host sets, as plain values.

`hvf.zig` and `kvm.zig` hold only their hypervisor's calls.

### KVM

The KVM backend (`src/vmm/kvm.zig`) runs on Linux on x86\_64, and on arm64, where it builds but hasn't yet run on a KVM host ([#92](https://github.com/progrium/hyper9/issues/92)). Its ioctls and structs are declared in `kvm_abi.zig`, so it needs no headers or library and static musl builds keep working. `/dev/kvm` missing, or not accessible, is `HypervisorUnavailable`, and the CLI says which.

The VM has one memory slot, the RAM region at 2 GiB, and no in-kernel interrupt controller: h9 never injects interrupts. On arm64 the VM asks for HVF's 36-bit IPA size, and the host sets the same system registers HVF does with `KVM_SET_ONE_REG`, so the shim is unchanged; the doorbell store is an MMIO exit, which KVM completes and steps past itself. On x86\_64 the doorbell is an `OUT`.

FP state goes through `KVM_{GET,SET}_XSAVE`, whose first 512 bytes are FXSAVE's image (`KVM_GET_FPU` leaves MXCSR out on recent kernels), and the FS base and the user GS base (`KERNEL_GS_BASE`, which `SWAPGS` swaps in) through `KVM_{GET,SET}_MSRS`.

- **vCPU lifetime.** KVM can't destroy one vCPU, and every vCPU a VM ever created counts against its limit. So `destroy` parks the vCPU on a free list, and `createVcpu` takes a parked one first and resets it: `KVM_ARM_VCPU_INIT` again on arm64, which is a full reset, and on x86 the registers, segment state, MSRs, and FP state all set again. A vCPU isn't bound to a thread, so any thread may take a parked one. The limit `maxVcpus` reports is KVM's (`KVM_CAP_MAX_VCPUS`, capped by `KVM_CAP_MAX_VCPU_ID` and 1024 shared-page slots), capped again by the file descriptors left less 256, since each vCPU holds one; the backend raises the soft `RLIMIT_NOFILE` to the hard limit when it creates the VM.
- **Kicks.** `kick` sets `kvm_run.immediate_exit` and sends the vCPU's thread `SIGRTMIN + 1`. The signal is blocked in each vCPU thread (from `createVcpu`) and unblocked only inside `KVM_RUN` through `KVM_SET_SIGNAL_MASK`, so it never interrupts a host call; after a stop, h9 consumes it with `sigtimedwait`, as it stays pending once blocked again. A kick can stop the vCPU anywhere. In user mode, the host reads the registers into the Ureg and re-enters the shim at its restore path before the next run, so a note delivered at that exit takes effect. In the shim's save path, before the doorbell, the Ureg is half written, so the host runs it on to the doorbell and returns that exit instead; in its restore path, the Ureg is already current.

### WHP

The WHP backend (`src/vmm/whp.zig`) runs on Windows x86\_64. It runs KVM's amd64 shim, page tables, and CPU state (`x86.zig`, `pt_amd64.zig`), setting the state through `WHvSetVirtualProcessorRegisters` rather than ioctls; its functions and structs are declared in `whp_abi.zig`.

`WinHvPlatform.dll` is loaded at run time, so `h9.exe` starts on machines without the Windows Hypervisor Platform feature, and `auto` falls back to the emulator there.

The doorbell is an `OUT` to an I/O port, whose exit the backend steps past itself, and `kick` is `WHvCancelRunVirtualProcessor` plus a flag that `run` checks first, since a cancel only stops a run already in progress.

As on KVM, destroyed vCPUs are parked and reset for their next user. The partition's processor count, and so the vCPU limit, is fixed at 64, HVF's measured limit, until WHP's own is measured.

The baseline and `[whp]` integration cases pass on a Windows x86\_64 VM, except the emulator fallback case, which hasn't run on a machine without the feature. Windows on ARM has no WHP backend yet: `aarch64-windows` builds keep the stub's `BackendNotBuilt`.

## Native backend (`native`)

The native backend ([native-backend](../design/epoch-0/native-backend.md), `src/vmm/native.zig`) runs amd64 guest code directly on the host CPU on Linux x86\_64, with no hypervisor and no emulator, so it runs where KVM can't: containers without `/dev/kvm` and cloud VMs without nested virtualization. It's MIT and built into every Linux x86\_64 `h9`.

### Stubs

Every 9front process is linked at the same address with its stack at the same top, so guest code can't run in h9's own address space. Each address space is a stub process instead (`src/vmm/native_stub.zig`): a freestanding static program of about 4 KB, embedded in h9, written to a sealed memfd and started with `clone(CLONE_VM|CLONE_VFORK)` and `execveat`, with every signal blocked across the clone.

It's linked at `0x6000_0000_0000` and keeps `[stub_base, stub_base + 4 GiB)` for itself, far above 9front's amd64 layout; at startup it unmaps everything else (the kernel's stack, vDSO, and vvar), so the guest's whole range is free.

It runs in its own session, so the terminal's signals go to h9 alone, with only two file descriptors: the machine's guest RAM, one memfd that h9 maps once and hands out in pages through `gphys.Ram`, and its control pages (`src/vmm/native_abi.zig`).

`map` and `unmap` queue requests, and a stub thread carries them out (an `mmap` of the RAM file at the guest address, or a `munmap`) before it next runs guest code, so `translate` and `copy` read guest memory in place.

### Syscalls and the filter

Each stub thread turns on Syscall User Dispatch for everything outside the stub's range, with a read-only selector, so every guest `SYSCALL` (whatever is in AX) raises SIGSYS instead of reaching the host kernel.

A seccomp filter is the backstop: it kills the stub for any call not made from the stub's range, and allows only the few calls the stub makes (`futex`, `mmap` of the RAM file, `munmap`, `clone` with exactly the thread flags, and a handful more).

Backend creation runs a probe once per h9: a guest that makes syscalls with unusual values in AX (0, 39, 335, 336, x32 numbers, high bits) must trap each time, or `--check` says why and the backend is refused.

### Threads and runs

A stub's first thread is its control thread, which never runs guest code; it starts another thread for each vCPU that runs the space, so a Linux program's threads run in parallel. A vCPU goes back to the stub thread it last ran on while that one is free, which keeps the AVX state `Extra` doesn't carry with it.

One signal handler, on a per-thread alternate stack, is the only way in or out of guest code: SIGSYS, a CPU exception (SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP), or a kick's SIGURG writes the registers, the first 416 bytes of the FXSAVE image, and the FS and GS bases to the thread's control page, tells h9 through a futex (spinning first), and waits.

`run` writes the Ureg back, hands the thread `run`, and waits for the next exit; a page fault's access comes from the error code.

`kick` sets the page's kick flag and sends SIGURG with `tgkill`; the stub reports `interrupted` only while the flag is set, so a signal that arrives after the run it was meant for has ended just resumes the guest.

`AddressSpace.shootdown` has the control thread carry out the queued unmaps, whose host `munmap` shoots down the other threads' TLBs. Unlike KVM's shim, the backend can't hide CPUID, so guests see the host's AVX.

### Speed

On a 4-CPU cloud VM without KVM, an awk loop that takes 10.7 s on emu takes 0.24 s on native, and the amd64 integration suite runs in about 5½ minutes against 7 on emu. arm64 isn't built yet.

## Emulator backend (`emu`)

The emulator lets the system run anywhere, including VMs without nested virtualization, at reduced speed. It implements the same Backend, AddressSpace, Vcpu, and Exit contract, so everything above the vmm layer runs unchanged.

`-Demu=hcpu`, the default on arm64 and x86-64 targets and what releases ship, builds it on h9's own CPUs: ha64 for arm64 binaries, h86 for 386 binaries, and hx64 for amd64 binaries, which [spec/ha64.md](ha64.md), [spec/h86.md](h86.md), [spec/hx64.md](hx64.md), and [spec/jit.md](jit.md) describe ([hcpu](../design/hcpu.md)). `-Demu=unicorn` builds it on Unicorn instead, for lockstep testing against hcpu and for Go's own test suite; it isn't released. The rest of this section describes the Unicorn backend, apart from the hcpu numbers under Limits and selection.

### Scope

User-mode arm64, amd64, and 386 code only. On an `SVC`, `SYSCALL`, or `INT $64`, or on a fault, the emulator fills the Ureg and returns the exit itself, doing the shim's job. There's no guest kernel mode, no system registers, and no MMU. The shim is tested only on real hypervisors.

### How the Unicorn backend works

Each vCPU is one Unicorn engine, running arm64 at EL0, amd64 in flat 64-bit mode, or 386 in `UC_MODE_32`, whose segments are all based at 0 as 9front's are for user code; the 386 Ureg's selectors are the values 9front gives user mode, kept in the Ureg rather than the engine.

Guest pages come from one reserved range of host memory, twice the memory cap in address space (`src/vmm/arena.zig`: first fit below a bump pointer; a freed range is given back to the host, mapped over with fresh zero pages on POSIX and decommitted on Windows, so neither allocation nor free touches the pages), and each engine maps that range once, with `uc_mem_map_ptr`, as its physical memory at 4 GiB. So the host and the guest share the pages and syscall arguments are read in place. An address space is a list of regions of that memory.

Engines run in Unicorn's virtual-TLB mode (`UC_TLB_VIRTUAL`): a `UC_HOOK_TLB_FILL` hook finds a guest page's region by binary search in the engine's sorted copy of the list, taken when the vCPU runs after a change, so a change never touches Unicorn's memory map, whose every change rebuilds it.

A region gone or changed flushes the engine's TLB, and only an executable one drops its translated blocks (`UC_CTL_TB_REMOVE_CACHE` over its range, while the old copy still translates it), since blocks are keyed by physical address.

The fill hook sees only the page, so an access the guest may not make (unmapped, or without the permission) gets a trap entry instead: one of eight physical pages with nothing behind them, recorded with the guest page, which the access then reaches with its offset intact, through `UC_HOOK_MEM_INVALID`; the fault's address is the guest page plus that offset. A run after trap entries flushes the TLB first, so their slots can be reused.

Hooks stop the engine: `UC_HOOK_INTR` for `SVC` and 386 `INT $64` (and other exceptions), `UC_HOOK_INSN` for amd64 `SYSCALL`, and `UC_HOOK_MEM_INVALID` for faults. After a syscall stop the PC is already past the instruction, as with a hypervisor; after a fault it's at the faulting instruction. `Ureg.type` (`trap` on 386) holds what the real kernel puts there for a syscall (the ESR on arm64, vector 64 on x86).

Unicorn has no FXSAVE register, so `getExtra` and `setExtra` assemble the image on both x86 architectures from the x87 control, status, tag, and opcode registers, `ST0`–`ST7` (in stack order, as FXSAVE has them, with the status word and its TOP written first), MXCSR, and the XMM registers; XMM8–15 stay zero on 386.

`kick` sets two flags: one the next run checks before it starts, and a stop request that a `UC_HOOK_BLOCK` hook sees at the engine's next block, on its own thread, where it calls `uc_emu_stop`.

On arm64, `CNTKCTL_EL1` lets EL0 read the counter and its frequency, as Linux does.

### Atomics

Unicorn generates code for a single-threaded context (its `curr_cflags` never sets `CF_PARALLEL`), so guest atomics (x86 `LOCK` instructions, arm64 exclusives, and LSE atomics) become plain loads and stores, and engines running at once on shared memory would race through them; a Go program's runtime fails with "unlock of unlocked lock".

So a backend runs guest code on one engine at a time, through a ticket lock held across each `uc_emu_start`; kernel calls run outside it, so processes still block in the kernel in parallel.

The lock passes at exits, and is time-sliced: a waiter that has waited 1 ms for the same holder sets the holder's stop request, and the holder stops at its next block and returns `interrupted` ([linux-threads](../design/epoch-0/linux-threads.md)), so a guest spinning without syscalls (a spinlock waiting on another thread) doesn't hold the others off.

The stop is made from the block hook, not by `uc_emu_stop` from the waiter's thread, since an engine stopped from another thread can report the PC of an earlier block than the one it stopped in, and resuming it would run instructions twice. A kick that arrives while an engine waits for the lock is seen once it has it.

An engine copies the address space's regions (`sync`) only after taking the lock, mapping and unmapping just the regions that changed and flushing translated blocks only when one went away, so `AddressSpace.shootdown`, which takes and passes on the lock, guarantees no engine still runs with mappings from before a change.

### Memory

Guest pages come from the reserved range above, whose pages are zero and stay unbacked until touched, and rfork's eager copy skips pages that are still zero (`src/segment.zig`), so the several hundred MB of `brk` a Go program reserves at start cost next to nothing until it uses them. They still count against `--memory`.

### Implementation

The backend uses Unicorn Engine. It's a C library built on QEMU's CPU core, covers arm64 and x86\_64, and has hooks for syscall instructions and invalid memory accesses.

It's GPLv2, so it sits behind a build flag (`-Demu=unicorn`) and never goes into a release. Before hcpu, releases shipped it separately as `h9-emu`, a GPLv2 binary with its complete corresponding source; hcpu replaced it, and it isn't released anymore.

We link the prebuilt static `libunicorn.a` from Unicorn's PyPI wheels (pinned in `scripts/pins.sh`, fetched by `scripts/fetch.sh`) rather than building its CMake tree: macOS arm64, and Linux arm64 and x86\_64 with musl, which is Zig's default Linux target.

There are no Windows wheels, so emu on Windows (arm64 and x86\_64) is built from source with our own `build.zig` (`-Dunicorn=source`, `build/unicorn.zig`). amd64 binaries are tested on Linux x86\_64 only; there's no amd64 on Darwin.

### What it's for

- Developing and testing on any host or VM: macOS, Linux, Windows, and hosted CI runners.
- Cross-architecture runs, for testing only: amd64 binaries on an arm64 Mac, and the reverse.
- Conformance: the backend cases in `tests/backends.zig` run against every backend built in.

### Limits and selection

Measured with `zig build bench -Demu=unicorn` ([tests/bench.zig](../tests/bench.zig)) on an M3 Max (macOS, release build of Unicorn 2.1.4): a 2-instruction loop of 10⁹ iterations takes 0.27 s on HVF, 1.4 s on emu for arm64 (about 1.5 G instructions/s; Unicorn's code generation, not our hooks) and 1.9 s on emu for amd64. A `pwrite` syscall round trip costs about 0.8 µs on emu, a little less than HVF's 1.1 µs: a bare exit and re-entry takes about 0.35 µs on emu, which never leaves the process, and about 0.8 µs on HVF, which goes through the shim, EL2, and the macOS kernel each way.

On KVM in a nested x86\_64 VM (an exe.dev VM on Intel VT-x, Linux 6.12), the loop takes 0.35 s for amd64, and a `pwrite` round trip about 28 µs, of which about 19 µs is the bare `OUT` exit and re-entry, each going through both hypervisors; KVM on bare metal is far cheaper.

So syscall-heavy work such as rc pipelines runs at close to hypervisor speed, arm64 compute runs about 5× slower, and amd64 compute about 7× slower; that's fine for tests, and tolerable for self-hosted builds.

By default `h9` uses the host's hypervisor when it's available, and otherwise falls back to the emulator with a warning; it never selects the native backend, which shares h9's process and isn't a security boundary. `--backend emu|hvf|kvm|native|whp|v86` forces a choice, and `--backend native` warns that it isn't a security boundary; `v86`, the browser host's old backend, is an alias of `emu` ([browser-host](../design/epoch-0/browser-host.md)).

## Guest shims

Each guest architecture gets a few hundred lines of assembly that run in guest kernel mode. The shim holds no policy: it moves control to the host and back, and the host decides everything.

### What the shim does

- Bring up the CPU: on arm64, EL1 with the MMU on; on amd64, long mode with a GDT, an IDT, and the SYSCALL MSRs. Every hypervisor h9 uses lets the host set these directly (HVF and KVM on arm64 through their register calls, KVM on amd64 through `KVM_SET_SREGS` and `KVM_SET_MSRS`), so the host does it and the shim is only the entry and exit paths.
- Switch the user page table root when the host asks: the host sets TTBR0 on arm64 and the shim flushes the TLB; on amd64 the host writes the next root into the shared page and the shim loads it into CR3, which flushes too, since setting CR3 from the host would take a full get and set of the segment state.
- On a syscall, fault, or interrupt: save the user registers into the per-vCPU page in Ureg layout, ring the doorbell, then restore registers (possibly changed by the host) and return to user mode.

**Per-vCPU shared page:** the saved Ureg, the exit reason and fault address, and the flush flag (arm64) or next CR3 (amd64). The host reads and writes it directly, so a typical syscall costs one exit and no register get/set calls.

### The amd64 shim

The amd64 shim (`src/arch/amd64/shim.S`) is used by KVM. The host puts the vCPU in long mode at ring 0:

- CR0 with paging and write protection, CR4 with PAE, FXSR, and SMEP and SMAP where the CPU has them, and EFER with long mode, SYSCALL, and NX.
- A GDT per vCPU laid out as 9front's `pc64` is, so `UESEL` and `UDSEL` are the user selectors, with a TSS whose IST1 is the top of the vCPU's shared page.
- One IDT, shared, sending vectors 0–31 through IST1.
- `STAR`, `LSTAR`, and `SFMASK`.

GS points at the shared page while the shim runs, and `SWAPGS` keeps it in `KERNEL_GS_BASE` in user mode. CPUID hides XSAVE, AVX, and AVX-512, so user code uses only state the FXSAVE image carries across vCPUs.

The shim's `SYSCALL` entry and exception stubs save the registers into the Ureg (the vector and error code in `type` and `error`, CR2 for a page fault) and ring the doorbell; the restore path loads the next CR3 if set, then the Ureg, with the user selectors and only the user flags (plus IF), and returns with `IRETQ`, one path for syscalls, faults, and notes. The doorbell sits at a fixed offset, so the host can tell from a stopped vCPU's PC whether the shim was saving a Ureg or loading one.

**Reference:** hyper-linux's `src/shim.S` (648 lines, Apache-2.0) covers EL1 vectors, MMU setup, and W^X page splitting on HVF, and was the reference for ours. Its license notice stays on anything borrowed from it.
