# Engines: the engine interface, the engines, and the guest shims

This describes, as built, the `engine` interface, the hypervisor, sud, and hcpu engines behind it, and the shims that run in guest kernel mode. h9's own CPUs for the emulator are in [jit.md](jit.md), [h86.md](h86.md), [hx64.md](hx64.md), and [ha64.md](ha64.md). [SPEC.md](../SPEC.md) describes h9 as a whole and lists the rest of the spec.

## Contents

- [The engine interface (`engine`)](#the-engine-interface-engine)
  - [Shared pieces](#shared-pieces)
  - [KVM](#kvm)
  - [WHP](#whp)
- [The sud engine (`sud`)](#the-sud-engine-sud)
  - [Stubs](#stubs)
  - [Syscalls and the filter](#syscalls-and-the-filter)
  - [Threads and runs](#threads-and-runs)
  - [Speed](#speed)
- [The hcpu engine (`hcpu`)](#the-hcpu-engine-hcpu)
  - [Scope](#scope)
  - [Memory](#memory)
  - [What it's for](#what-its-for)
  - [Limits and selection](#limits-and-selection)
- [Guest shims](#guest-shims)
  - [What the shim does](#what-the-shim-does)
  - [The amd64 shim](#the-amd64-shim)

## The engine interface (`engine`)

A small Zig interface hides the three hypervisor APIs, the sud engine, and hcpu. Everything above it is written once.

```zig
// engine.create picks an engine at run time: .auto tries the host hypervisor, then hcpu; sud is explicit-only (not a security boundary).
pub fn create(gpa, io, want: Choice, opts: Options) !Engine;   // Options: { arch: Arch, memory: ?u64 }

// One address space per Plan 9 process. Each engine decides how to realize it:
// the hypervisors build 4K page tables, the emulator keeps a virtual-address -> host-memory map.
const AddressSpace = union(Kind) {             // Kind: hvf, kvm, whp, hcpu, sud
    pub fn destroy(self) void;                 // mapped pages belong to the caller
    pub fn map(self, va: u64, mem: []align(4096) u8, perms: Perms) !void;
    pub fn unmap(self, va: u64) void;          // the mapping map made at va; its pages stay allocated
    pub fn translate(self, va: u64, len: u64) ?[]u8;      // host view, for syscall arguments
    pub fn shootdown(self) void;               // returns once no other vCPU can reach what unmap removed
    pub fn copy(self, va: u64, buf: []u8, dir: enum { read, write }) bool;  // /proc/n/mem, from any thread
    pub fn codeChanged(self, va: u64, len: u64) void;     // a write to executable pages: drop cached code
};
const Engine = union(Kind) {
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

Each engine is a file under `src/engine/` with the same method set; the unions dispatch to it. Engines not built into a given h9 are replaced by a stub whose `create` fails with `EngineNotBuilt`, so every host builds the same code.

An engine that can't run the binary's architecture fails with `WrongArch`; HVF runs arm64 only, KVM the host's architecture (arm64 or amd64), WHP and sud amd64 only, and only the emulator runs 386.

`src/arch/i386.zig` holds the 386 Ureg, notify frame, and `noted` sanitizing without engine details, so a hardware engine could add 386 later with a compatibility-mode code segment and an `INT $64` gate in its shim.

The contract is in Plan 9 terms (address spaces, Ureg, syscall exits) rather than hardware terms such as guest-physical memory and page tables. That keeps page-table building inside the hypervisor engines, and lets the emulator implement the contract without emulating kernel mode or an MMU.

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
- **Memory:** one large guest-physical region is mapped once at VM creation. A host-side page allocator hands out guest-physical pages from it. We never map per segment, because KVM caps the number of memory slots and mapping calls are slow everywhere. The host backs the region's pages only when they're first touched, and freed pages go back to it (`src/engine/gphys.zig`): each free range keeps the span of it that may be dirty, and once that span reaches 32 MiB it's released (`madvise(MADV_DONTNEED)` on KVM, a hole punched in the RAM file on the sud engine, and, with the range taken out of the VM and put back, fresh pages mapped over it on HVF and a decommit and recommit on WHP). A smaller dirty span is zeroed as it's handed out again, so small frees and reallocations cost no syscalls, and never-used or released pages aren't touched when they're handed out.
- **Page size:** guest page tables use 4K pages on every host, matching 9front's page size on both architectures. hyper-linux shows HVF guests can use 4K pages. Only the single host memory region has to be aligned to the host page size (16K on Apple Silicon).
- **No hypervisor:** `create` fails cleanly with a clear message, and `auto` falls back to the emulator when it's built in. The sud engine is never chosen automatically, since it shares h9's process and isn't a security boundary; it needs an explicit `--engine sud`, and the CLI points at it when nothing else can run.

### Shared pieces

The hypervisor engines share:

- `src/engine/gphys.zig`: the guest-physical page allocator over the one RAM region, and the address space type (a list of regions over page tables).
- A page-table format: `pt_arm64.zig` (TTBR0 for user, a TTBR1 kernel half with the shim, the doorbell page and the per-vCPU shared pages, and the system register values the host sets) or `pt_amd64.zig` (4-level tables, with the kernel half under PML4 entry 511, which every address space's root shares).
- `x86.zig`: the amd64 CPU state the host sets, as plain values.

`hvf.zig` and `kvm.zig` hold only their hypervisor's calls.

### KVM

The KVM engine (`src/engine/kvm.zig`) runs on Linux on x86\_64 and arm64. Its ioctls and structs are declared in `kvm_abi.zig`, so it needs no headers or library and static musl builds keep working. `/dev/kvm` missing, or not accessible, is `HypervisorUnavailable`, and the CLI says which.

The VM has one memory slot, the RAM region at 2 GiB, and no in-kernel interrupt controller: h9 never injects interrupts. On arm64 the VM asks for HVF's 36-bit IPA size, and the host sets the same system registers HVF does with `KVM_SET_ONE_REG`, so the shim is unchanged; the doorbell store is an MMIO exit, which KVM completes and steps past itself. On x86\_64 the doorbell is an `OUT`.

FP state goes through `KVM_{GET,SET}_XSAVE`, whose first 512 bytes are FXSAVE's image (`KVM_GET_FPU` leaves MXCSR out on recent kernels), and the FS base and the user GS base (`KERNEL_GS_BASE`, which `SWAPGS` swaps in) through `KVM_{GET,SET}_MSRS`.

- **vCPU lifetime.** KVM can't destroy one vCPU, and every vCPU a VM ever created counts against its limit. So `destroy` parks the vCPU on a free list, and `createVcpu` takes a parked one first and resets it: `KVM_ARM_VCPU_INIT` again on arm64, which is a full reset, and on x86 the registers, segment state, MSRs, and FP state all set again. A vCPU isn't bound to a thread, so any thread may take a parked one. The limit `maxVcpus` reports is KVM's (`KVM_CAP_MAX_VCPUS`, capped by `KVM_CAP_MAX_VCPU_ID` and 1024 shared-page slots), capped again by the file descriptors left less 256, since each vCPU holds one; the engine raises the soft `RLIMIT_NOFILE` to the hard limit when it creates the VM.
- **Kicks.** `kick` sets `kvm_run.immediate_exit` and sends the vCPU's thread `SIGRTMIN + 1`. The signal is blocked in each vCPU thread (from `createVcpu`) and unblocked only inside `KVM_RUN` through `KVM_SET_SIGNAL_MASK`, so it never interrupts a host call; after a stop, h9 consumes it with `sigtimedwait`, as it stays pending once blocked again. A kick can stop the vCPU anywhere. In user mode, the host reads the registers into the Ureg and re-enters the shim at its restore path before the next run, so a note delivered at that exit takes effect. In the shim's save path, before the doorbell, the Ureg is half written, so the host runs it on to the doorbell and returns that exit instead; in its restore path, the Ureg is already current.

### WHP

The WHP engine (`src/engine/whp.zig`) runs on Windows x86\_64. It runs KVM's amd64 shim, page tables, and CPU state (`x86.zig`, `pt_amd64.zig`), setting the state through `WHvSetVirtualProcessorRegisters` rather than ioctls; its functions and structs are declared in `whp_abi.zig`.

`WinHvPlatform.dll` is loaded at run time, so `h9.exe` starts on machines without the Windows Hypervisor Platform feature, and `auto` falls back to the emulator there.

The doorbell is an `OUT` to an I/O port, whose exit the engine steps past itself, and `kick` is `WHvCancelRunVirtualProcessor` plus a flag that `run` checks first, since a cancel only stops a run already in progress.

As on KVM, destroyed vCPUs are parked and reset for their next user. The partition's processor count, and so the vCPU limit, is fixed at 64, HVF's measured limit, until WHP's own is measured.

The baseline and `[whp]` integration cases pass on a Windows x86\_64 VM, except the emulator fallback case, which hasn't run on a machine without the feature. Windows on ARM has no WHP engine yet: `aarch64-windows` builds keep the stub's `EngineNotBuilt`.

## The sud engine (`sud`)

The sud engine ([native-backend](../design/epoch-0/native-backend.md), `src/engine/sud.zig`) runs amd64 guest code directly on the host CPU on Linux x86\_64, with no hypervisor and no emulator, so it runs where KVM can't: containers without `/dev/kvm` and cloud VMs without nested virtualization. It's MIT and built into every Linux x86\_64 `h9`.

### Stubs

Every 9front process is linked at the same address with its stack at the same top, so guest code can't run in h9's own address space. Each address space is a stub process instead (`src/engine/sud_stub.zig`): a freestanding static program of about 4 KB, embedded in h9, written to a sealed memfd and started with `clone(CLONE_VM|CLONE_VFORK)` and `execveat`, with every signal blocked across the clone.

It's linked at `0x6000_0000_0000` and keeps `[stub_base, stub_base + 4 GiB)` for itself, far above 9front's amd64 layout; at startup it unmaps everything else (the kernel's stack, vDSO, and vvar), so the guest's whole range is free.

It runs in its own session, so the terminal's signals go to h9 alone, with only three file descriptors: the machine's guest RAM, one memfd that h9 maps once and hands out in pages through `gphys.Ram`; its control pages (`src/engine/sud_abi.zig`); and the spin budget every stub shares with h9 (see Threads and runs).

`map` and `unmap` queue requests, and a stub thread carries them out (an `mmap` of the RAM file at the guest address, or a `munmap`) before it next runs guest code, so `translate` and `copy` read guest memory in place.

### Syscalls and the filter

Each stub thread turns on Syscall User Dispatch for everything outside the stub's range, with a read-only selector, so every guest `SYSCALL` (whatever is in AX) raises SIGSYS instead of reaching the host kernel.

A seccomp filter is the backstop: it kills the stub for any call not made from the stub's range, and allows only the few calls the stub makes (`futex`, `mmap` of the RAM file, `munmap`, `clone` with exactly the thread flags, and a handful more).

Engine creation runs a probe once per h9: a guest that makes syscalls with unusual values in AX (0, 39, 335, 336, x32 numbers, high bits) must trap each time, or `--check` says why and the engine is refused.

### Threads and runs

A stub's first thread is its control thread, which never runs guest code; it starts another thread for each vCPU that runs the space, so a Linux program's threads run in parallel. A vCPU goes back to the stub thread it last ran on while that one is free, which keeps the AVX state `Extra` doesn't carry with it.

One signal handler, on a per-thread alternate stack, is the only way in or out of guest code: SIGSYS, a CPU exception (SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP), or a kick's SIGURG writes the registers, the first 416 bytes of the FXSAVE image, and the FS and GS bases to the thread's control page, tells h9 through a futex (spinning first), and waits.

`run` writes the Ureg back, hands the thread `run`, and waits for the next exit; a page fault's access comes from the error code.

Each side spins briefly for the other before it sleeps on the futex, which saves a futex round trip per guest syscall, but only while there's a CPU to spare. h9 and every stub share one page (`abi.Sched`) that counts the threads on a CPU for guests: stub threads not asleep (running guest code, or spinning for h9) and h9 threads spinning for a stub. Either side spins only while that count, itself included, leaves one of h9's CPUs (its affinity, capped by a cgroup CPU quota) free for the h9 threads serving syscalls, which it doesn't count, since they may be blocked in the kernel. Otherwise both sleep at once, so a guest with more threads than there are CPUs doesn't have half of them taken by spinners. When h9 reaps a stub, it takes the stub's threads that were still counted back out.

`kick` sets the page's kick flag and sends SIGURG with `tgkill`; the stub reports `interrupted` only while the flag is set, so a signal that arrives after the run it was meant for has ended just resumes the guest.

`AddressSpace.shootdown` has the control thread carry out the queued unmaps, whose host `munmap` shoots down the other threads' TLBs. Unlike KVM's shim, the engine can't hide CPUID, so guests see the host's AVX.

### Speed

On a 4-CPU cloud VM without KVM, an awk loop that takes 10.7 s on hcpu takes 0.24 s on sud, and the amd64 integration suite runs in about 5½ minutes against 7 on hcpu. arm64 isn't built yet.

## The hcpu engine (`hcpu`)

The emulator lets the system run anywhere, including VMs without nested virtualization, at reduced speed. It implements the same Engine, AddressSpace, Vcpu, and Exit contract, so everything above the engine layer runs unchanged.

It's hcpu, h9's own CPUs: ha64 for arm64 binaries, h86 for 386 binaries, and hx64 for amd64 binaries, picked by the binary's architecture when the engine is created ([hcpu](../design/epoch-0/hcpu.md)). [spec/jit.md](jit.md) describes the engine and what the CPUs share, and [spec/ha64.md](ha64.md), [spec/h86.md](h86.md), and [spec/hx64.md](hx64.md) each CPU. It's MIT, and it's built into every `h9` for an arm64 or x86-64 target and into the web host; there's no build option to leave it out or to pick another emulator.

### Scope

User-mode arm64, amd64, and 386 code only. On an `SVC`, `SYSCALL`, or `INT $64`, or on a fault, the emulator fills the Ureg and returns the exit itself, doing the shim's job. There's no guest kernel mode, no system registers, and no MMU. The shim is tested only on real hypervisors.

### Memory

Guest pages come from one reserved range of host memory, twice the memory cap in address space (`src/engine/arena.zig`: first fit below a bump pointer; a freed range is given back to the host, mapped over with fresh zero pages on POSIX and decommitted on Windows, so neither allocation nor free touches the pages), and the host and the guest share the pages, so syscall arguments are read in place. An address space is a list of regions of that memory.

Its pages are zero and stay unbacked until touched, and rfork's eager copy skips pages that are still zero (`src/segment.zig`), so the several hundred MB of `brk` a Go program reserves at start cost next to nothing until it uses them. They still count against `--memory`.

### What it's for

- Running on any host or VM without a usable hypervisor: macOS, Linux, Windows, hosted CI runners, and the browser.
- Cross-architecture runs: amd64 and 386 binaries on an arm64 host, and arm64 binaries on an x86-64 one.
- Conformance: the engine cases in `tests/engines.zig` run against every engine built in.

### Limits and selection

Measured with `zig build bench` ([tests/bench.zig](../tests/bench.zig); [hcpu](../design/epoch-0/hcpu.md#updates) has the table): on GitHub's macOS runner, an Apple silicon VM, a 2-instruction loop of 10⁹ iterations takes 1.09 s for arm64, 2.17 s for amd64, and 2.29 s for 386 on T1; on an x86-64 Linux VM, 0.60, 3.39, and 3.88 s. T0 runs it in about 12 to 28 s. A `pwrite` round trip costs 0.5 to 1 µs, and a bare exit and re-entry 56 to 110 ns, since the emulator never leaves the process. Four busy amd64 threads run 3.3 to 4 times as fast as one on 4-core Linux hosts.

On HVF on an M3 Max, the same loop takes 0.27 s, a `pwrite` round trip about 1.1 µs, and a bare exit and re-entry about 0.8 µs, which goes through the shim, EL2, and the macOS kernel each way. On KVM in a nested x86\_64 VM (an exe.dev VM on Intel VT-x, Linux 6.12), the loop takes 0.35 s for amd64, and a `pwrite` round trip about 28 µs, of which about 19 µs is the bare `OUT` exit and re-entry, each going through both hypervisors; KVM on bare metal is far cheaper.

So syscall-heavy work such as rc pipelines runs at hypervisor speed or better, and compute runs a few times slower; that's fine for tests, and tolerable for self-hosted builds.

By default `h9` uses the host's hypervisor when it's available, and otherwise falls back to hcpu with a warning; it never selects the sud engine, which shares h9's process and isn't a security boundary. `--engine hvf|kvm|whp|sud|hcpu` forces a choice, and `--engine sud` warns on a terminal that it isn't a security boundary. For one release, `--backend` is an alias of `--engine`, and `native`, `emu`, and `v86` (the web host's old backend, [browser-host](../design/epoch-0/browser-host.md)) are aliases of `sud`, `hcpu`, and `hcpu` ([renames](../design/renames.md)).

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

GS points at the shared page while the shim runs, and `SWAPGS` keeps it in `KERNEL_GS_BASE` in user mode. CPUID hides XSAVE, AVX, AVX-512, AMX, and AVX10 (in leaves 1, 7, and 7.1, with leaves 0xD, 0x1D, 0x1E, and 0x24 dropped), so user code uses only state the FXSAVE image carries across vCPUs.

The shim's `SYSCALL` entry and exception stubs save the registers into the Ureg (the vector and error code in `type` and `error`, CR2 for a page fault) and ring the doorbell; the restore path loads the next CR3 if set, then the Ureg, with the user selectors and only the user flags (plus IF), and returns with `IRETQ`, one path for syscalls, faults, and notes. The doorbell sits at a fixed offset, so the host can tell from a stopped vCPU's PC whether the shim was saving a Ureg or loading one.

**Reference:** hyper-linux's `src/shim.S` (648 lines, Apache-2.0) covers EL1 vectors, MMU setup, and W^X page splitting on HVF, and was the reference for ours. Its license notice stays on anything borrowed from it.
