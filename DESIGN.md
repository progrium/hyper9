# Design: Plan 9 executables on host hypervisors

Nov 2, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

This describes h9 as built. Changes to it go through proposals in [design/](design/README.md); the record of how h9 got here before proposals is the [baseline](design/0000-baseline.md).

## Overview

h9 is a small Zig library and CLI that runs native 9front executables directly on macOS, Linux, and Windows, using each host's hypervisor API. Each guest process runs in hardware-isolated user mode, and its syscalls are served by drawterm's Plan 9 kernel running in the host process. Prior art: hyper-linux (the same shape for Linux ELF on macOS) and 9vx (Plan 9 binaries on Linux and OS X x86 through a vx32 sandbox).

**Goals**

- Start and run a 9front binary as fast as a native process: no VM image, no boot, no guest kernel.
- One invocation can hold a whole process tree (rc pipelines, servers posting to /srv, rio, and its clients).
- Run native code only: arm64 9front binaries on arm64 hosts, amd64 binaries on x86\_64 hosts. 386 binaries run on the emulator, and on the browser host, which has no CPU to run natively on, on v86 ([i386](design/0009-i386.md), [browser-host](design/0012-browser-host.md)).
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
| Root filesystem | Direct host tree, or a 9P server over TCP, a unix socket, or a WebSocket | A 9P root is mounted through devmnt ([9p-roots](design/0013-9p-roots.md), [websocket-9p](design/0021-websocket-9p.md)); disk images are proposed ([image-roots](design/0014-image-roots.md)) |
| Toolchain inside | The 9front compilers (7c/6c, 7l/6l, mk) must run | It's a goal ([self-host](design/0010-self-host.md)), and a source of test binaries |
| Language | Zig, latest stable (0.16.x as of writing) | Change versions only when we hit a blocking bug. drawterm's C is compiled with `zig cc`. |
| Terminal | Text mode on the host TTY; with `--gfx`, one host window drawn by drawterm's GUI backends ([gfx](design/0015-gfx.md)) | consctl `rawon`; the interrupt key posts an `interrupt` note |
| Guest exit mechanism | MMIO doorbell (`OUT` on x86) | Works the same on all three hypervisors |
| Emulator | A user-mode emulator backend: Unicorn; a native Zig interpreter is proposed ([zig-interpreter](design/0019-zig-interpreter.md)) | For development and CI on hosts and VMs without a usable hypervisor |
| Browser host | h9 on wasm32-wasi, with coroutines on JSPI, and 386 binaries on v86 | One machine per Web Worker; the same build runs under Node for the tests |

## Architecture

&#91;embedded content: architecture · host process, guest VM, host OS\]

Each Plan 9 process runs in user mode on its own vCPU. A syscall traps into the shim, exits through the doorbell, and is served by drawterm's kernel on the host. The new code is the machine library (highlighted), the vmm backends, and the shims; the CLI is a thin wrapper.

## Hypervisor layer (`vmm`)

A small Zig interface hides the three hypervisor APIs and the emulator. Everything above it is written once.

```zig
// vmm.create picks a backend at run time: .auto tries the host hypervisor, then the emulator.
pub fn create(gpa, io, want: BackendKind, opts: Options) !Backend;   // Options: { arch: Arch }

// One address space per Plan 9 process. Each backend decides how to realize it:
// the hypervisors build 4K page tables, the emulator keeps a virtual-address -> host-memory map.
const AddressSpace = union(Kind) {             // Kind: hvf, kvm, emu (whp is proposed)
    pub fn map(self, va: u64, mem: []align(4096) u8, perms: Perms) !void;
    pub fn unmap(self, va: u64, len: u64) !void;
    pub fn protect(self, va: u64, len: u64, perms: Perms) !void;
    pub fn translate(self, va: u64, len: u64) ?[]u8;      // host view, for syscall arguments
    pub fn copy(self, va: u64, buf: []u8, dir: enum { read, write }) bool;  // /proc/n/mem, from any thread
    pub fn codeChanged(self, va: u64, len: u64) void;     // a write to executable pages: drop cached code
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
    pub fn getExtra(self: *Vcpu, x: *Extra) !void;     // FP/SIMD state and thread pointer
    pub fn setExtra(self: *Vcpu, x: *const Extra) !void;
    pub fn kick(self: *Vcpu) void;             // safe from any thread
};
const Ureg = union(Arch) { arm64: arm64.Ureg, amd64: amd64.Ureg, i386: ia32.Ureg };
// arm64: Q0-Q31, FPCR, FPSR, TPIDR_EL0. x86: the 512-byte FXSAVE image
// (x87, MXCSR, XMM) plus the FS base on amd64.
const Extra = union(Arch) { arm64: Arm64Extra, amd64: X86Extra, i386: X86Extra };
const Exit = union(enum) { syscall, fault: Fault, breakpoint, interrupted, halted, other: u64 };
```

Each backend is a file under `src/vmm/` with the same method set; the unions dispatch to it. Backends not built into a given h9 are replaced by a stub whose `create` fails with `BackendNotBuilt`, so every host builds the same code. A backend that can't run the binary's architecture fails with `WrongArch`; HVF runs arm64 only, KVM the host's architecture (arm64 or amd64), and only the emulator runs 386. `src/arch/i386.zig` holds the 386 Ureg, notify frame, and `noted` sanitizing without backend details, so a hardware backend could add 386 later with a compatibility-mode code segment and an `INT $64` gate in its shim.

The contract is in Plan 9 terms (address spaces, Ureg, syscall exits) rather than hardware terms such as guest-physical memory and page tables. That keeps page-table building inside the hypervisor backends, and lets the emulator implement the contract without emulating kernel mode or an MMU.

The interface was shaped around all three hypervisors, so the table and rules below cover WHP as well. HVF and KVM ([kvm](design/0016-kvm.md)) are built; [whp](design/0017-whp.md) is proposed.

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
- **Memory:** one large guest-physical region is mapped once at VM creation. A host-side page allocator hands out guest-physical pages from it. We never map per segment, because KVM caps the number of memory slots and mapping calls are slow everywhere.
- **Page size:** guest page tables use 4K pages on every host, matching 9front's page size on both architectures. hyper-linux shows HVF guests can use 4K pages. Only the single host memory region has to be aligned to the host page size (16K on Apple Silicon).
- **No hypervisor:** `create` fails cleanly with a clear message, and `auto` falls back to the emulator when it's built in.

**Shared pieces.** The hypervisor backends share `src/vmm/gphys.zig`, the guest-physical page allocator over the one RAM region and the address space type (a list of regions over page tables), and a page-table format: `pt_arm64.zig` (TTBR0 for user, a TTBR1 kernel half with the shim, the doorbell page and the per-vCPU shared pages, and the system register values the host sets) or `pt_amd64.zig` (4-level tables, with the kernel half under PML4 entry 511, which every address space's root shares). `x86.zig` holds the amd64 CPU state the host sets, as plain values. `hvf.zig` and `kvm.zig` hold only their hypervisor's calls.

**KVM** (`src/vmm/kvm.zig`, Linux on arm64, and x86\_64). Its ioctls and structs are declared in `kvm_abi.zig`, so it needs no headers or library and static musl builds keep working. `/dev/kvm` missing, or not accessible, is `HypervisorUnavailable`, and the CLI says which. The VM has one memory slot, the RAM region at 2 GiB, and no in-kernel interrupt controller: h9 never injects interrupts. On arm64 the VM asks for HVF's 36-bit IPA size, and the host sets the same system registers HVF does with `KVM_SET_ONE_REG`, so the shim is unchanged; the doorbell store is an MMIO exit, which KVM completes and steps past itself. On x86\_64 the doorbell is an `OUT`. FP state goes through `KVM_{GET,SET}_XSAVE`, whose first 512 bytes are FXSAVE's image (`KVM_GET_FPU` leaves MXCSR out on recent kernels), and the FS base through `KVM_{GET,SET}_MSRS`.

- **vCPU lifetime.** KVM can't destroy one vCPU, and every vCPU a VM ever created counts against its limit. So `destroy` parks the vCPU on a free list, and `createVcpu` takes a parked one first and resets it: `KVM_ARM_VCPU_INIT` again on arm64, which is a full reset, and on x86 the registers, segment state, MSRs, and FP state all set again. A vCPU isn't bound to a thread, so any thread may take a parked one. The limit `maxVcpus` reports is KVM's (`KVM_CAP_MAX_VCPUS`, capped by `KVM_CAP_MAX_VCPU_ID` and 1024 shared-page slots), capped again by the file descriptors left less 256, since each vCPU holds one; the backend raises the soft `RLIMIT_NOFILE` to the hard limit when it creates the VM.
- **Kicks.** `kick` sets `kvm_run.immediate_exit` and sends the vCPU's thread `SIGRTMIN + 1`. The signal is blocked in each vCPU thread (from `createVcpu`) and unblocked only inside `KVM_RUN` through `KVM_SET_SIGNAL_MASK`, so it never interrupts a host call; after a stop, h9 consumes it with `sigtimedwait`, as it stays pending once blocked again. A kick can stop the vCPU anywhere. In user mode, the host reads the registers into the Ureg and re-enters the shim at its restore path before the next run, so a note delivered at that exit takes effect. In the shim's save path, before the doorbell, the Ureg is half written, so the host runs it on to the doorbell and returns that exit instead; in its restore path, the Ureg is already current.

## Emulator backend (`emu`)

The emulator lets the system run anywhere, including VMs without nested virtualization, at reduced speed. It implements the same Backend, AddressSpace, Vcpu, and Exit contract, so everything above the vmm layer runs unchanged.

**Scope:** user-mode arm64, amd64, and 386 code only. On an `SVC`, `SYSCALL`, or `INT $64`, or on a fault, the emulator fills the Ureg and returns the exit itself, doing the shim's job. There's no guest kernel mode, no system registers, and no MMU. The shim is tested only on real hypervisors.

**How the Unicorn backend works.** Each vCPU is one Unicorn engine, running arm64 at EL0, amd64 in flat 64-bit mode, or 386 in `UC_MODE_32`, whose segments are all based at 0 as 9front's are for user code; the 386 Ureg's selectors are the values 9front gives user mode, kept in the Ureg rather than the engine. An address space is a list of regions of host memory; when a vCPU runs, any regions it hasn't seen yet are mapped into its engine with `uc_mem_map_ptr`, so the host and the guest share the pages and syscall arguments are read in place. Hooks stop the engine: `UC_HOOK_INTR` for `SVC` and 386 `INT $64` (and other exceptions), `UC_HOOK_INSN` for amd64 `SYSCALL`, and `UC_HOOK_MEM_INVALID` for faults. After a syscall stop the PC is already past the instruction, as with a hypervisor; after a fault it's at the faulting instruction. `Ureg.type` (`trap` on 386) holds what the real kernel puts there for a syscall (the ESR on arm64, vector 64 on x86). Unicorn has no FXSAVE register, so `getExtra` and `setExtra` assemble the image on both x86 architectures from the x87 control, status, tag, and opcode registers, `ST0`–`ST7` (in stack order, as FXSAVE has them, with the status word and its TOP written first), MXCSR, and the XMM registers; XMM8–15 stay zero on 386. `kick` sets a flag and calls `uc_emu_stop`, which Unicorn allows from another thread.

**Atomics.** Unicorn generates code for a single-threaded context (its `curr_cflags` never sets `CF_PARALLEL`), so guest atomics (x86 `LOCK` instructions, arm64 exclusives, and LSE atomics) become plain loads and stores, and engines running at once on shared memory would race through them; a Go program's runtime fails with "unlock of unlocked lock". So a backend runs guest code on one engine at a time, through a ticket lock held across each `uc_emu_start`; kernel calls run outside it, so processes still block in the kernel in parallel. The lock passes at exits only, not on a timer: an engine stopped from another thread with `uc_emu_stop` can report the PC of an earlier block than the one it stopped in, so resuming it would run instructions twice. A guest that spins without syscalls holds the others off until it makes one, which Go's runtime and libc do between short bursts of spinning. A kick that arrives while an engine waits for the lock is seen once it has it.

**Memory.** Guest pages come straight from the host's page allocator, which gives zeroed pages that stay unbacked until touched, and rfork's eager copy skips pages that are still zero (`src/segment.zig`), so the several hundred MB of `brk` a Go program reserves at start cost next to nothing until it uses them. They still count against `--memory`.

**Implementation.** The backend uses Unicorn Engine. It's a C library built on QEMU's CPU core, covers arm64 and x86\_64, and has hooks for syscall instructions and invalid memory accesses. It's GPLv2, so it sits behind a build flag (`-Demu=unicorn`) and never goes into the MIT `h9` release build. Releases ship it separately as `h9-emu`, a GPLv2 binary built from source (`-Dunicorn=source`) with its complete corresponding source attached to the same release (`scripts/release.sh`); the two are separate programs side by side, so `h9` stays MIT. We link the prebuilt static `libunicorn.a` from Unicorn's PyPI wheels (pinned in `scripts/pins.sh`, fetched by `scripts/fetch.sh`) rather than building its CMake tree: macOS arm64, and Linux arm64 and x86\_64 with musl, which is Zig's default Linux target. There are no Windows wheels, so emu on Windows (arm64 and x86\_64) is built from source with our own `build.zig` (`-Dunicorn=source`, `build/unicorn.zig`). amd64 binaries are tested on Linux x86\_64 only; there's no amd64 on Darwin.

**What it's for**

- Developing and testing on any host or VM: macOS, Linux, Windows, and hosted CI runners.
- Deterministic debugging: single-stepping, instruction tracing, and record and replay at the syscall boundary.
- Cross-architecture runs, for testing only: amd64 binaries on an arm64 Mac, and the reverse.
- Conformance: one test suite runs against every backend, and each backend must produce the same syscall traces.

**Limits and selection.** Measured with `zig build bench -Demu=unicorn` ([tests/bench.zig](tests/bench.zig)) on an M3 Max (macOS, release build of Unicorn 2.1.4): a 2-instruction loop of 10⁹ iterations takes 0.27 s on HVF, 1.4 s on emu for arm64 (about 1.5 G instructions/s; Unicorn's code generation, not our hooks) and 1.9 s on emu for amd64. A `pwrite` syscall round trip costs about 0.8 µs on emu, a little less than HVF's 1.1 µs: a bare exit and re-entry takes about 0.35 µs on emu, which never leaves the process, and about 0.8 µs on HVF, which goes through the shim, EL2, and the macOS kernel each way. On KVM in a nested x86\_64 VM (an exe.dev VM on Intel VT-x, Linux 6.12), the loop takes 0.35 s for amd64, and a `pwrite` round trip about 28 µs, of which about 19 µs is the bare `OUT` exit and re-entry, each going through both hypervisors; KVM on bare metal is far cheaper. So syscall-heavy work such as rc pipelines runs at close to hypervisor speed, arm64 compute runs about 5× slower, and amd64 compute about 7× slower; that's fine for tests, and tolerable for self-hosted builds. By default `h9` uses the host's hypervisor when it's available, and otherwise falls back to the emulator with a warning. `--backend emu|hvf|kvm|whp` forces a choice.

## Browser host (`web`, `v86`)

`zig build web` builds h9 for wasm32-wasi into `zig-out/web/` ([browser-host](design/0012-browser-host.md)). The kernel, the machine, and the CLI are the same code; what differs is underneath them. Native hosts are unchanged.

| Piece | Web host |
| --- | --- |
| Threads | Coroutines on JavaScript Promise Integration (`src/web/coro.c`): each kernel process, and each of h9's own threads (`web.Thread`), has its own shadow stack and its own suspendable wasm stack, started through the exported, `promising`-wrapped `h9_coro_entry`. Blocking parks through a `Suspending` import whose Promise the JS host resolves, so the event loop is the scheduler. Every Suspending import (park, yield, sleep, the console read, and the signal wait) saves and restores what's per thread natively: `__stack_pointer` (`src/web/stack.S`), `errno`, h9's Zig threadlocals, and drawterm's `up`. |
| OS layer | `src/kern/os-wasm.c` instead of `posix.c`: `procsleep` and `procwakeup` park and unpark, `osyield` yields through a `MessageChannel`, timers park with a timeout, `#C` raises an error, and `devip-wasm.c` stubs the sockets. |
| Stacks | wasm has no guard pages, so each stack has a canary at its low end, and every park and coroutine exit also checks the stack pointer against it; either failing panics the machine with the coroutine's name. Kernel processes and h9's own coroutines get 320 KiB: the integration suite's deepest use at a park (149 KiB, in a guest process's syscall path, Debug build), doubled and rounded up. Stacks go on a free list when their coroutine ends. |
| `std.Io` | `src/web/io.zig`: std's single-threaded implementation over WASI, with futex waits and sleeps that park. 64-bit atomics become plain values (`web.Atomic`), since wasm32 has no 64-bit atomic RMW. |
| Files | WASI. Under Node, `h9-node` preopens `/`, so roots and `--cwd` are real host directories, resolved with readlink one component at a time since WASI has no realpath. In the browser, `src/web/wasi-mem.js` serves a read-only tree from `root.h9a`, which `tools/webroot.zig` packs from the 386 root and `src/web/root.list`. WASI has no permission bits, so `#U` (devfs, wrapped in `src/kern/devtab.c`) gives files and directories `rwxrwxr-x`; the policy, not the mode, decides access. |
| Console | `src/web/cli.zig`: stdin, interrupt, hangup, and raw mode are imports the JS host serves, from Node's process or from the page's messages. |
| Policy | `#C` and `#I` are always masked. `--host-cmd` is a usage error. The network is WebSockets only: `--net=outbound` (the default) and `enable` bind `#ℏ` alone at `/net`, and `disable` masks it. |
| WebSockets | `hstream.zig`'s web branch calls `h9-web.js`'s `h9_ws_*` imports, over the runtime's `WebSocket` ([websocket-9p](design/0021-websocket-9p.md)): `ws_open` and `ws_send` return at once, `ws_opened` and `ws_recv` are Suspending, and a stream's reader is a coroutine parked in `ws_recv`, which hands over as many queued binary messages as fit. The browser does the handshake, TLS, proxies, and pongs, so `--root-header`, `--root-ca`, and `header` in `ctl` are errors, there's no keepalive, and a failed connection says only "connection failed". `--net-allow` checks a connect's name or literal address but can't check what a name resolves to, which the plan lists as a caveat. |

**The v86 backend** (`src/vmm/v86.zig`) runs 386 binaries on v86's CPU, the only backend in web builds. `v86.wasm` (0.5.473, pinned in `scripts/pins.sh` with its register-block offsets, fetched by `scripts/fetch.sh`, checked by `tests/web/v86-layout.mjs`) and `h9.wasm` share one linear memory: v86 owns the low part, h9 is linked with `--import-memory` at a 16 MiB base, and guest RAM is one `allocate_memory` from v86, made after h9 is instantiated. `src/arch/i386/shim.S`, loaded at guest-physical 0x1000, sets up 9front's GDT (kernel and user code and data, a TSS), an IDT whose every vector pushes a 386 Ureg on the kernel stack and halts, and paging with the kernel at `KZERO`. A halt ends `main_loop`, and the backend reads the Ureg from the stack; a resume writes it back, clears `in_hlt`, and jumps to the shim's restore path. An address space is a 386 page directory in guest RAM. A slice that ends without a halt is preemption: `run` builds the Ureg from v86's registers, returns the CPU to ring 0, yields to the event loop, and returns `.interrupted`. Freed pages and executable mappings call `jit_dirty_cache`, so recycled pages never run stale compiled code. `h9-web.js` provides v86's imports: a clock, JIT glue (compile the generated module and set it in the shared table, deferring `codegen_finalize_finished` until `main_loop` returns), and stubs for ports and MMIO, which ring 3 can't reach.

**Hosts.** `h9-node` runs the CLI under Node 24 or later, with the same flags as `h9`; it's how the integration suite tests the web host. In a page, `createMachine({ root, memory, policy, terminal })` from `h9-web.js` starts one machine in its own Worker (`src/web/worker.js`) and `machine.run(argv)` resolves to the exit status. `root` is a root archive's URL, or a `ws://` or `wss://` URL of a 9P server, under which WASI sees an empty tree; the page edits and echoes lines in cooked mode, passes keys in raw mode, and sends the interrupt key as `Machine.Signals.interrupt`. The demo page (`index.html`) runs an interactive rc, over `?root=` when given.

## Guest shims and ABI

Each guest architecture gets a few hundred lines of assembly that run in guest kernel mode. The shim holds no policy: it moves control to the host and back, and the host decides everything.

**What the shim does**

- Bring up the CPU: on arm64, EL1 with the MMU on; on amd64, long mode with a GDT, an IDT, and the SYSCALL MSRs. Every hypervisor h9 uses lets the host set these directly (HVF and KVM on arm64 through their register calls, KVM on amd64 through `KVM_SET_SREGS` and `KVM_SET_MSRS`), so the host does it and the shim is only the entry and exit paths.
- Switch the user page table root when the host asks: the host sets TTBR0 on arm64 and the shim flushes the TLB; on amd64 the host writes the next root into the shared page and the shim loads it into CR3, which flushes too, since setting CR3 from the host would take a full get and set of the segment state.
- On a syscall, fault, or interrupt: save the user registers into the per-vCPU page in Ureg layout, ring the doorbell, then restore registers (possibly changed by the host) and return to user mode.

**Per-vCPU shared page:** the saved Ureg, the exit reason and fault address, and the flush flag (arm64) or next CR3 (amd64). The host reads and writes it directly, so a typical syscall costs one exit and no register get/set calls.

**The amd64 shim** (`src/arch/amd64/shim.S`, used by KVM). The host puts the vCPU in long mode at ring 0: CR0 with paging and write protection, CR4 with PAE, FXSR, and SMEP and SMAP where the CPU has them, EFER with long mode, SYSCALL, and NX; a GDT per vCPU laid out as 9front's `pc64` is, so `UESEL` and `UDSEL` are the user selectors, with a TSS whose IST1 is the top of the vCPU's shared page; one IDT, shared, sending vectors 0–31 through IST1; and `STAR`, `LSTAR`, and `SFMASK`. GS points at the shared page while the shim runs, and `SWAPGS` keeps it in `KERNEL_GS_BASE` in user mode. CPUID hides XSAVE, AVX, and AVX-512, so user code uses only state the FXSAVE image carries across vCPUs. The shim's `SYSCALL` entry and exception stubs save the registers into the Ureg (the vector and error code in `type` and `error`, CR2 for a page fault) and ring the doorbell; the restore path loads the next CR3 if set, then the Ureg, with the user selectors and only the user flags (plus IF), and returns with `IRETQ`, one path for syscalls, faults, and notes. The doorbell sits at a fixed offset, so the host can tell from a stopped vCPU's PC whether the shim was saving a Ureg or loading one.

**Binary ABI (checked against 9front source).** The values below come from `sys/src/9/{arm64,pc64}/mem.h` and `trap.c`, plus `sysexec` in `port/sysproc.c`.

| Item | arm64 (`R_MAGIC`) | amd64 (`S_MAGIC`) | 386 (`I_MAGIC`) |
| --- | --- | --- | --- |
| UTZERO (text start) | 0x10000 | 0x200000 | 0x1000 |
| USTKTOP (stack top) | 0x7FFFF0000 (36-bit user addresses) | 0x7FFFFFFFF000 | 0xDFFFF000 |
| Stack size | 16 MiB | 16 MiB | 16 MiB |
| Page size | 4 KiB | 4 KiB | 4 KiB |
| Data segment alignment | 64 KiB | 2 MiB | 4 KiB |
| Syscall number | R0 | BP (RARG) | AX, with `INT $64` |
| Syscall arguments | user stack, from SP+8 | user stack, from SP+8 | user stack, from SP+4, in 4-byte words; a `vlong` takes two |
| Syscall result | R0 | AX | AX |
| Registers at entry | R0 = Tos pointer; SP points at argc, argv follows | AX = Tos pointer; SP points at argc; R14 and R15 zeroed | AX = Tos pointer; SP points at argc |
| Note handler entry | R0 = Ureg pointer; SP+8 = Ureg, SP+16 = message | BP = Ureg pointer; same stack layout | no register; SP+4 = Ureg, SP+8 = message, in 4-byte words |

Pointers, argv, the words of the note frame, and the Tos's pointers follow the architecture's word size, so 386's Tos is 56 bytes with `pid` at 48. `noted` on 386 keeps the segment selectors and the flags outside 0xCD5 (IF, IOPL, TF) from the kernel's copy, as 9front's `setregisters` does.

**a.out loading (host side)**

1. Read the Exec header: eight big-endian 32-bit words. Both 64-bit magics set HDR\_MAGIC, so a big-endian 64-bit entry address follows, making the header 40 bytes; 386's has none, so its entry is the header's 32-bit `entry` word and the header is 32 bytes.
2. Map file bytes \[0, header + text) read-only at UTZERO. The header is part of the text segment, and the entry point must fall inside it.
3. Map the next `data` bytes of the file at the end of text, rounded up to the data alignment. bss starts at the end of data rounded up to 4 KiB, and is zero-filled.
4. The stack may span \[USTKTOP − 16 MiB, USTKTOP), but as in 9front only its top pages are mapped at first; it grows down on faults below it, and at each syscall to cover the arguments. A zeroed Tos sits at the very top. Below it go the argument strings, then the argv array, then argc at SP.
5. Tos fields: the host fills `pid` and `cyclefreq` and keeps `kcycles`/`pcycles` current; the profiling pointers stay zero.

**Syscall table.** 9front's `libc/9syscall/sys.h` defines numbers 0–53; 48 and 49 are unused. The underscore entries (`_READ`, `_WRITE`, `_STAT`, `_NSEC`, and so on) are old compatibility calls that current libc doesn't use. h9 implements only the current calls, plus `_NSEC` (53), which Go's `syscall.Gettimeofday` uses ([go-compat](design/0007-go-compat.md)): as 9front's `sys_nsec`, it returns the wall time in nanoseconds in the return register on 64-bit machines, and on 386 stores it through its argument and returns 0. The others post "sys: bad sys call", as the real kernel does for unknown calls. `mount`, `unmount`, and `fauth` are served by drawterm's `sysmount` and `sysunmount` and a `fauth` wrapper over devmnt's `mntauth` (`h9_fauth` in `src/kern/glue.c`), so a guest mounts any 9P server it has an fd for: a posted channel, a pipe it serves itself, or a network connection the policy allowed. `mount` blocks until the server answers `Tversion` and `Tattach`, and a note interrupts it as it does any devmnt RPC. Time otherwise comes from `/dev/bintime`, which h9's devcons hooks serve in nanoseconds with all four of 9front's words (see Kernel, "Added by us").

**Reference:** hyper-linux's `src/shim.S` (648 lines, Apache-2.0) already covers EL1 vectors, MMU setup, and W^X page splitting on HVF. Read it before writing ours, and keep its license notice on anything we borrow.

## Process model

Each CLI invocation is one machine: one host process with one VM. Each Plan 9 process is a drawterm Proc plus a host thread that owns a vCPU, and the host OS schedules them, so there is no guest scheduler. Because every process lives in one VM and one kernel, rfork never has to serialize state across host processes. hyper-linux has to, because it can only use one VM per host process.

| Plan 9 call | Implementation |
| --- | --- |
| `rfork(RFPROC)` | New Proc, new thread and vCPU, and an eager copy of the address space (no copy-on-write) |
| `rfork(RFMEM)` | Share the text, data and bss, and segattach's `memory` segments; copy only the stack |
| `RFNAMEG` / `RFFDG` / `RFENVG` / `RFNOTEG` / `RFREND` | Share or copy drawterm's Pgrp, Fgrp, Egrp, note group, and rendezvous group |
| `exec` | Load the new a.out into fresh segments, rebuild page tables, reset registers, keep the fds (honouring close-on-exec) and segattach's segments (except `SG_CEXEC` ones) |
| `exits` / `await` | Wait records queued on the parent Proc; the thread and vCPU are torn down |
| `brk_` | Grow the data segment and map pages from the guest-physical allocator, up to the stack's floor or the lowest attached segment above it |
| `segattach` / `segdetach` | Attach or detach a `shared` or `memory` segment, up to five per process, with 9front's placement rules; pages are allocated up front and never executable ([segattach](design/0004-segattach.md)) |
| `segbrk` / `segfree` / `segflush` | Move an attached segment's top; zero its pages in place; check the span and do nothing else |
| `notify` / `noted` | Push a Ureg and the note string onto the user stack and point the PC at the handler; `noted` restores or kills the process |
| `/proc/n/ctl` `stop` / `start` / `hang` | Park the process on its own thread at its next stop point (syscall entry, note delivery, a breakpoint exit, or before the first instruction after `exec` with `hang`), with its Ureg and Extra copied to its record ([self-host](design/0010-self-host.md)) |
| `rendezvous` / `semacquire` / `tsemacquire` / `semrelease` | Host kernel primitives built on drawterm's sleep/wakeup (`src/kern/sema.c`): 9front's `rendezvous` on drawterm's rendezvous group, and 9front's semaphores, with the wait lists in a kernel-wide table keyed by the host address of the guest word; `tsemacquire` waits with `tsleep` ([semaphores](design/0003-semaphores.md)) |

**Threads.** The kernel boots once per host process, on a private thread, because booting turns the calling thread into a Proc for good. Every guest process then runs on a kernel thread made by `h9_kern_spawn` in `src/kern/proc.c`, which works like drawterm's `kproc` but can be called from a thread that isn't a Proc: it clones from the boot Proc, and the new thread sets up its groups once `up` is set. That thread creates the process's vCPU, which HVF binds to its creating thread, and runs the exit loop. `Machine.run` starts the first process this way and waits for it to exit; `rfork` uses the same path. The boot also starts one kernel thread of its own, the timer kproc (`src/kern/tsleep.c`), which idles on a host condition variable until the earliest `tsleep` deadline.

**Several machines per host process.** An embedder, or the test suite, can run several machines in one host process. They share the one drawterm kernel, but each machine's first Proc starts with a fresh Pgrp, Fgrp, and Egrp, so each has its own namespace, device mask, console, and environment. The CLI always runs one.

**Notes on blocked and running processes.** A note to a process blocked in a host syscall wakes it through drawterm's sleep/wakeup, and the syscall fails with "interrupted" (`rendezvous` returns `~0` instead, as on 9front). A note to a process running guest code kicks its vCPU, and the note is delivered at the exit. Pending notes are queued on h9's process record, not in drawterm's Proc: drawterm's `postnote` keeps only `notepending`, which `enderror` clears after every failed syscall, so it serves only as the "interrupt this call" flag. Because calls clear that flag as they return, a note posted while one call is finishing would be lost to the next call if the guest made one straight away; the exit loop re-arms the flag when it starts a call with a note flagged, and `pushnote` kicks before it interrupts, so a call started before the kick's flag is set still sees the interrupt.

**vCPU limits.** Each process runs on one vCPU at a time, and hypervisors cap the live vCPUs per VM (`hv_vm_get_max_vcpu_count` on HVF, `KVM_CAP_MAX_VCPUS` on KVM). On HVF a vCPU is bound to its thread, so a process past the cap can't simply borrow one: it needs pool threads that run the guest on its behalf.

Measured on an M3 Max (macOS 15.8.1, 14 cores): `hv_vm_get_max_vcpu_count` reports 64, and the 65th live `hv_vcpu_create` fails with `HV_NO_RESOURCES`. Destroyed vCPUs free their slots, and a create takes about 120 µs. A Unicorn engine has no limit but costs about 1.3 MiB of host memory and 0.3 ms to create. So on HVF 64 is a hard cap on *live* processes, not just running ones, and a pipeline of 65 stages or `mk -j` with many jobs reaches it. KVM in a nested x86\_64 VM (Linux 6.12, Intel VT-x) reports 1024, and recycles its vCPUs (see KVM above), so its limit is on live vCPUs too; with fewer file descriptors it reports less.

The answer (`src/cpupool.zig`) is a hybrid. A process creates and owns its vCPU on its own thread, as before, while the machine owns fewer than the limit less a reserve of 8. Processes beyond that run guest code through a pool of 8 pool threads, each with a vCPU: the process thread hands its Ureg, FP/SIMD registers, and thread pointer to a pool thread, which runs the guest to its next exit and hands them back. Kernel calls stay on the process's own thread, so pool threads never block in the kernel and the pool always makes progress. A handoff costs two thread wake-ups per syscall, so only the processes past the first 56 pay it. `--cpus` caps how many vCPUs run guest code at the same moment, owned or pooled, on every backend. The emulator has no vCPU limit, so every process owns an engine there.

## Go programs

Go's `GOOS=plan9 GOARCH=amd64` binaries run unchanged ([go-compat](design/0007-go-compat.md)). Go has no `plan9/arm64` port and HVF runs arm64 only, so they run on the emulator: on an arm64 Mac and on Linux x86\_64 alike, through Unicorn, which isn't in the MIT build. What the runtime and standard library need is served:

- **Startup:** `/dev/sysstat` has a line per CPU, so `runtime.NumCPU` and the default `GOMAXPROCS` follow `--cpus` (or the host's count); `#c/pid` gives the pid; `/dev/bintime` is opened as fd 18 for the clock. `/dev/swap` isn't served, and the runtime's 4 KiB fallback is right.
- **Threads:** each M is a process from `rfork(RFPROC|RFMEM|RFNOWAIT)`, and parks and wakes with `tsemacquire`, `semacquire`, and `semrelease` ([semaphores](design/0003-semaphores.md)).
- **Time:** `nanotime` uses `bintime`'s fourth word, the monotonic clock, and `walltime` its first; `syscall.Gettimeofday` uses `_NSEC`.
- **Processes and notes:** `os/exec` forks with `RFPROC|RFFDG|RFREND`, lists fds in `#d`, writes `/env`, execs, and waits with `await`; `os.Getppid` reads `#c/ppid`; `Process.Kill` and `Signal` write `/proc/n/note`. Fault notes carry `addr=`, so a nil dereference becomes a panic, and `interrupt` reaches `os/signal`.
- **Exit:** `os.Exit(n)` writes `n` as its `exits` string, which the CLI maps to exit code `n`.
- **Not yet:** `os.Executable` (`/proc/n/text`, [self-host](design/0010-self-host.md)), the `mount` syscall, and execs of 9front commands, since the root tree has no `/amd64/bin`. rfork copies the parent's memory eagerly, so a Go program that uses `os/exec` needs `--memory` of about 4 GB.

The go-compat integration cases (tagged `[7]`) run the programs in `tests/fixtures/go` on the emulator, and `zig build go-stdtest` runs Go's own `time`, `syscall`, `os`, and `runtime` tests to find gaps.

## Kernel: drawterm `kern/` and the Zig seam

We vendor 9front drawterm's `kern/`, its libraries (libc, libdraw, libmemdraw, libmemlayer, libsec, libmp, libip, libauthsrv) and its GUI backends. Its `sysfile.c` already implements the file syscalls with Plan 9 semantics, so most syscall handlers are a decode followed by one call. We keep the vendored tree close to upstream so 9front fixes keep merging cleanly.

**Reused as-is:** chan/dev/mount machinery, devroot, devcons (for everything but `cons` itself), devmnt (the 9P client), devfs-posix, and devfs-win32 (the host filesystem, with h9's sandbox hook calls), devpipe, devip (with h9's network hook calls), devtls, devssl, devdraw, devmouse, devaudio, devcmd, qio, and the auth code. We compile drawterm's `.c` files but not its `kern/devtab.c` or `kern/devenv.c`; our own copies live in `src/kern/`. The vendored tree's few changes are small and marked: the sandbox hooks (see Sandbox policy) and `Chan.srvname`, which `kern/chan.c`'s `chanfree` frees, as on 9front.

**Added by us**

| Piece | Why |
| --- | --- |
| Process model (Proc fields, segments, rfork/exec/await, notes) | drawterm only ever ran its own kprocs |
| `src/kern/devtab.c` | The device table, listing drawterm's devices plus ours |
| Per-machine console device `#y` (`src/kern/devhcons.c`) | drawterm's `#c/cons` reads and writes the host's fds 0 and 1 directly. `#y<id>` serves machine `id`'s `Stdio` through leaf calls into Zig, and is bound before `#c` on `/dev`, so `/dev/cons` is ours and the rest of `#c` stays visible. It also has `/dev/stderr`, which the guest's fd 2 is opened on, so fd 2 reaches the host's stderr. |
| devenv `#e`, from 9front (`src/kern/devenv.c`) | drawterm's has one machine-wide environment and imports the host process's environment on first attach, which breaks `env.scrub`. 9front's keeps one environment per Egrp, which `RFENVG` needs anyway. drawterm's Proc has no `egrp` and stays as it is, so each process's group is kept on its h9 process record (`src/kern/proc.c`). `#ec` isn't supported. |
| devproc `#p`, from 9front (`src/kern/devproc.c`) | rc, kill, and ps need `/proc/n/{note,notepg,noteid,ctl,status,ns,fd,args,ppid,wait}`, and `segment` is served too; acid also needs `mem`, `regs`, `fpregs`, and `text` ([self-host](design/0010-self-host.md)). It serves h9's process records (`src/kern/proc.c`, shared through `src/kern/hproc.h`) instead of 9front's Proc table: a qid holds the machine-local pid, and every walk, open, read, and write looks it up in the caller's machine, so a machine can't see, signal, or kill another's processes. `status` has the 12 fields `ps` reads: the user is the machine's user (the guest's `$user`), the state is the syscall being served (as 9front's `psstate`, so `Await`, `Sleep`, `Pread`) or `Running`, memory is the process's mapped segments, and the user and system times read 0 until there's per-thread CPU accounting. `segment` lists the stack (its whole 16 MiB), text, data up to the break, and segattach's segments (`Shared`, or `Bss` for `memory`) in 9front's format, with the number of address spaces each is attached to. `ctl` takes `kill` (the process dies with `Killed` at its next note delivery, handler or not), `hang`/`nohang` (`exec` then stops the process before its first instruction), `close`, `closefiles`, and acid's `stop`, `start`, `waitstop`, and `startstop`; a stopped process reads `Stopped` and a waiting debugger `Stopwait`. `mem` translates through the target's address space; writes, and `regs` and `fpregs` writes, need the process stopped. `regs` reads while the process is stopped or in a syscall, `fpregs` only while it's stopped, laid out as 9front's `FPsave` (520 bytes on arm64, the 512-byte FXSAVE on x86). `text` opens the file the process executed (the interpreter, for a `#!` script). Unmapped addresses fail with "bad address" and missing register state with `Enoreg`. A process may `stop` itself while a debugger waits on it, which 9front refuses with `Einuse`; acid's `new()` doesn't need it, but the integration fixture does. `ns` prints the mount table as 9front does, so binds of host trees show their host paths; `--print` lists this as a caveat. A process takes its record's `debug` lock to swap its fd group, namespace, or dot (rfork, chdir) and to mark itself gone at exit, so `fd` and `ns` readers can hold references to them. |
| devdup `#d` | `/fd/N` |
| `tsleep` (`src/kern/tsleep.c`) | drawterm's `sleep` has no timeout. `tsleep` has 9front's contract and uses only drawterm's public `sleep` and `wakeup`: it puts a timer on its own stack into a list sorted by host monotonic time, and the timer kproc wakes it at the deadline. The list is guarded by a host lock (`glue.c`, `glue-win32.c`) that the kproc holds while it calls `wakeup`, and `tsleep` always takes its timer out under that lock before returning, so no Proc fields are needed. |
| Semaphores and `rendezvous` (`src/kern/sema.c`) | drawterm has no semaphores. 9front's code is ported closely, with the wait lists in 64 hashed buckets keyed by the host address of the semaphore word rather than in the segment, since h9's segments are Zig objects; the word is changed with host atomics. `src/syscall.zig` checks the address first (aligned, mapped, in a writable segment), and the pages it names never move while it's shared. `rendezvous` is 9front's on drawterm's Rgrp, so `procinterrupt` still pulls a process out of it, but it also checks for a note that arrived before the process was on the list. |
| Host command lifetime (`src/kern/hostcmd.c`) | Host commands are built in only with `zig build -Dhost-cmd` (devtab.c lists devcmd under `H9_HOSTCMD`, `hcmd` comes from `src/guest-hostcmd/`, and the policy refuses `host_cmd` otherwise) while [host-cmd](design/host-cmd.md) rethinks them. drawterm's devcmd `#C` (under `--host-cmd`) kills a host command only when the last fd on its conversation closes, and a guest process reading its output waits in a host `read` no note interrupts, so a stopped machine could leave the command running after h9 exits. posix.c and win32.c are built with `oscmd`, `oscmdkill`, and `oscmdfree` renamed, and wrappers keep each running command with the machine that started it, found through the Fgrp that devcmd's kproc shares with the writer of `exec`. When the machine stops its processes, and when its last process is released, its commands are killed (SIGKILL to the process group on POSIX hosts; `TerminateProcess` on Windows), which ends the stuck reads; one started after that is killed at once |
| Sandbox hooks (`src/kern/fscheck.c`, `src/kern/netcheck.c`) | The C side of the policy checks devfs and devip call; see Sandbox policy, "Vendor hooks" |
| devsrv `#s`, from 9front (`src/kern/devsrv.c`), per machine | Guest file servers post themselves in `/srv` (lib9p's `postsrv`, `srvfs`, factotum, plumber), and clients open the posted channel and mount it. 9front's code is ported closely, but each machine has its own root board, hung off its `Hmach` and made on first attach, with its own lock, so machines in one host process can't see each other's services; `clone` boards hang off the machine's root, so `#s/id` addressing works within a machine. A write of an fd number goes through `fdtochan`, then the post itself (the in-use and auth checks, holding the reference) is shared with `h9_srvpost`, which posts a host-side channel without a guest fd. Posting sets the channel's `srvname` to its `/srv` path, which `/proc/n/ns` prints for a mount of it, as 9front does. The machine's last process to release its groups (`h9_kern_release` in `src/kern/proc.c`) closes every posted channel, as closing a lease does, while the machine is still there; the boards go with the machine. |
| Host-stream device `#ℏ` (`src/kern/devhstream.c`, `src/hstream.zig`) | WebSockets, for roots, namespace-file mounts, and the guest's `/net/ws` ([websocket-9p](design/0021-websocket-9p.md)). It follows devhcons's pattern: Zig does TCP, TLS (`std.crypto.tls`) and the framing (`src/ws.zig`) on a host reader thread per stream, the guest sleeps on a Rendez in the kernel until the stream has data, and a note interrupts it. A host-made stream has no path: `h9_hstream_fd` makes its channel, which is posted as `#s/root` or mounted at once, so the guest can't reach it by name. Attached with no spec, the device serves `ws/clone` and `ws/N/{ctl,data,text,remote,status}`, listing only the caller's machine's conversations (at most 32); `bind -a '#ℏ' /net` puts them at `/net/ws`. `data` is the binary stream, `text` one text message per read or write. Received data is queued in the machine's pages, up to 16 MiB unread per stream. A guest `connect` asks the net policy as a TCP dial would, through the same `netLookup`, `netResolved`, and `netCheck` as devip and `cs`. The machine's end closes its streams (`h9_hstream_machend`, from `src/kern/proc.c`) |
| devcons hooks (`src/kern/consx.c`, `consx.h`) | drawterm's devcons gives whole-second time, three words of `bintime`, an empty `sysstat`, and no `pid` or `ppid`, and Go reads `#c/pid` by device path, which no bind can redirect ([go-compat](design/0007-go-compat.md)). So devcons calls hooks: `#c/pid` and `#c/ppid` (machine-local pids, as `$pid` and `/proc` have them, in 9front's 12-character format); `bintime` (wall nanoseconds, ticks, `fasthz`, and monotonic nanoseconds, big-endian, with a short read getting the leading words that fit); `time` (seconds, nanoseconds, ticks, and `fasthz`, in drawterm's text format); and `sysstat`, a line per CPU the machine may use, in 9front's ten columns with zeros for the counters h9 doesn't keep, so Go's `runtime.NumCPU` counts them. The CPU count is `--cpus` if given, else the host's, capped by the backend's vCPU limit. The guest's `NPROC` is the same count, so `mk` runs that many jobs ([self-host](design/0010-self-host.md)). The clock is one per host process (`src/kern.zig`): wall time from the host's real-time clock, and monotonic time from its monotonic clock, offset to the wall time at the kernel's boot; ticks are the monotonic nanoseconds, so `fasthz` is 10⁹. Writes to `time` and `bintime` still fail. |
| Overlay device `#O` (`src/kern/devoverlay.c`) | Copy-on-write trees in memory over a lower directory, for the root's overlay, `--write=ephemeral`, and the private `/tmp` (see Sandbox policy). An instance can report each change to the machine, for the root's discarded-changes notice. A union `bind -c` of a ramfs can't keep writes off the host, since a union sends every operation on an existing name to the member that has it. |
| h9's guest commands `#H` (`src/kern/devhtools.c`) | Commands that wrap h9's own devices (websocket-9p's `wsmount`, say, or `hcmd`, which runs host commands through `#C`) can't come from 9front, and h9 never writes into the root ([guest-tools](design/0032-guest-tools.md)). `src/guest/` holds them, laid out as the guest sees them, and the build embeds it in the binary as a generated table (`tools/guesttree.zig`): only rc scripts and data, so an executable that doesn't start with `#!/bin/rc` fails the build, and names starting with `.` are left out. Executables are 0555, other files 0444, directories 0555, all owned by the machine's user; `#H/bin` always exists. The device gets the table once at reset from one leaf, `h9_tools_table` (`src/kern.zig`), and is plain C over constant memory after that. An entry's index is its qid path, so qids are the same on every run of one build. Attach takes no spec; writes, creates, removes, `OTRUNC` and `ORCLOSE` opens, and `wstat` fail with "permission denied". Debug builds also serve `tests/fixtures/guest/` (`-Dguest-test`), for the integration cases. |

**Zig/C seam rules**

1. drawterm raises errors with `waserror()`/`error()`, built on setjmp/longjmp. A longjmp across a Zig frame skips its `defer` and `errdefer`. So Zig code never sits between a `waserror` and an `error`.
2. drawterm already provides the seam. Each `sysX` wrapper in `kern/sysfile.c` (`sysopen`, `syspread`, `sysbind`, `sysmount`, and so on) runs `waserror`; on error it stores the string for `errstr` and returns -1. Zig calls these directly and turns -1 into an error union. New process and segment calls get wrappers in the same style.
3. C calls Zig only for leaf work that cannot fail into the kernel: the vmm layer, page allocation, the a.out parser, console I/O. A leaf returns a status, and the C side raises any kernel error.
4. drawterm's `up` (`_getproc()`, per host thread) stays authoritative. Every guest thread is created through drawterm's kproc path (`h9_kern_spawn`), so `up` is set before any kernel call. Zig never uses bare `std.Thread` for anything that touches the kernel, and never boots the kernel on a caller's thread. The one exception is `--gfx` on macOS, where AppKit needs the main thread: `h9.gfx.main` boots the kernel on it and adopts it as a kernel Proc (`h9_kern_adopt`, through drawterm's clone path) before handing it to AppKit.
5. drawterm's Proc has no parent, note group, segments, or Egrp. We add these fields, plus a pointer to the Zig-side process record.
6. The build uses `zig build`: C sources go through `addCSourceFiles` with drawterm's flags, and one `build.zig` produces binaries for every host.
7. Guest memory reaches the kernel through `GuestBuf`, because drawterm's `validaddr` is a no-op and h9's translation is the only check. A data buffer (`pread`, `pwrite`, `stat`) is passed to the `sys*` wrapper in place when it is contiguous in host memory, and otherwise goes through a host bounce buffer, so each guest call is one kernel call. Only buffers of 1 GiB or more are split, since drawterm's `long` is 32 bits. Any unmapped byte posts "sys: bad address in syscall". Strings (paths, `errstr`) are always copied into a bounded host buffer first, so no other guest thread can change one during the call.

## Filesystem, boot, and I/O

**Root filesystem.** Either a directory holding an extracted 9front root, served through `#U` (devfs-posix or devfs-win32), which is the fastest path, with no 9P round trips; or a 9P server ([9p-roots](design/0013-9p-roots.md)), named by `--root tcp!host!port` (`tcp!host` means port 564), `unix!path`, or the path of a unix socket. h9 connects to a 9P root before the program runs: a TCP root is dialed through devip by device path (`#I/cs` and `#I/tcp/clone`), outside the network policy, since h9 makes the connection and the guest can't dial anything through it; a unix socket root is connected on the host and wrapped as a channel with devlfd's `lfdchan` (`src/kern/rootdial.c`), on POSIX hosts only; a `ws://` or `wss://` root is connected by `src/hstream.zig` (TCP, TLS, the HTTP proxy if one applies, and the handshake), and its stream's channel comes from devhstream. The connection is posted on the machine's `/srv` board as `root`, which holds it for the machine's life, and `#s/root` is mounted at `/` with no auth fd and `--root-spec` as the attach name. devmnt sends the calling process's user as the attach uname, so the first Proc takes on `--root-user` for the mount when one is given. Everything else is bound over the mount as over a host tree. A refused connection, a failed `Tversion` or `Tattach` (a server that wants authentication, or one that speaks another dialect) is exit 125 with the server's error; a hangup later fails file operations as devmnt does, and h9 doesn't reconnect. Disk images are proposed ([image-roots](design/0014-image-roots.md)).

**Slim roots ([multicall](design/0064-multicall.md)).** `zig build slim` builds 9box, 9front's own commands as one statically linked multi-call binary, and a root tree around it in `.local/9front/slim-<release>-<arch>`; nothing in h9 itself changes. `tools/slim.zig` copies `src/9box/` into a fresh build directory and runs its mkfile inside the just-built h9, against the stock root, with the build directory as the only writable path and `/sys/src` from the root or the fetched checkout bound read-only. For each command in `src/9box/slim` (a name and a directory under `/sys/src/cmd` per line), `mkcmd` builds it as 9front does, with `mk`, behind `bind -bc` layers so `/sys/src` isn't written, reads the objects off the link line from `mk -n -a`, lists the globals they define with `nm`, and compiles them again with a `-Dname=bx_CMD_name` flag for each one libc and libbio don't define. A command's override of a libc function (ed's `mktemp`) is renamed too, unless libc's or libbio's own code calls it; that, initialising a library global other than `argv0`, or being a thread program, fails the build. `9box.c` picks the command from the last element of `argv[0]` (hard links), from `argv[2]` when `argv[1]` is `-!` and `argv[2]` is a `#!/bin/9box -!` file (stubs, so nested interpreters keep the outer script's name), or from its first argument when run as `9box`, and sets `argv0` to nil before running it. The tree is `9box`, a hard link or stub per command, `rcmain`, the time zone, and the mount points h9 binds onto. Its 42 commands are a 749 KB `9box` against 3.4 MB for the same binaries copied. Each exec allocates and copies the box's text and data, so on the emulator rc's exec loop runs 9% slower from the box than from separate binaries; an exec image cache would remove most of that (the proposal's Updates have the measurements).

**Boot sequence**

1. The kernel boots once per host process, on its own thread (see Process model).
2. For each machine, the namespace builder gives the first Proc a fresh Pgrp. For a 9P root it first connects, posts the connection as `#s/root`, and mounts it at `/`; a host root is bound at `/`. Under `--write=overlay` (the default) and `--write=ephemeral` a `#O` overlay goes over `/` next, before every other bind, so everything else is bound onto directories reached through it; a directory the overlay hasn't copied keeps its lower qid, so the mount table matches it. Then it binds the cwd and other allowed host paths from `#U` (or `#O` overlays over them under `--write=ephemeral`), a `#O` overlay over the root tree's `/tmp` (the guest's `/tmp` for a 9P root), and `#c`, `#p`, `#d`, `#e`, `#s` (the machine's own `/srv`, with `-c`) and (unless the network is off) `#I` to their usual places, with `#ℏ` bound after it at `/net`, giving `/net/ws`, and `#H/bin` after the root's `/bin`, so h9's own commands are on the path and a root command of the same name wins. A namespace file's `mount` of a `ws://` or `wss://` URL connects a new stream during the replay, which runs before the device mask. It binds the machine's console over `/dev/cons` and opens fds 0–2 on it; with `--gfx` it then binds `#i`, `#m`, and `#b` after it on `/dev`. Under the root's overlay it makes `/usr/$user` in the overlay if the root lacks it, so `$home` exists. Then it sets the device mask: `#U` and `#C` always (unless `--host-fs` or `--host-cmd`), `#I` and `#ℏ` when the network is off, `#H` under `--no-guest-tools`, which also leaves out its bind, and `#b`, `#i`, and `#m` without `--gfx`. Existing binds keep working, but the guest can't attach a masked device again to reach more of the host.
3. If the binary is given as a host path, it's loaded straight from the host. Otherwise it's looked up through the kernel along `$path`, so lookup works the same over 9P roots.
4. The CLI runs the binary directly with the given argv. `--rc` runs `/bin/rc -c` on the argument instead, and `--ns file` runs `newns` with that file first.

The host's working directory is bound at the guest's `/mnt/term/cwd` and set as the guest's cwd, so that `h9 ls` lists what the user expects.

**Terminal (default):** `/dev/cons` is the machine's console device, which maps to the `Stdio` in `Machine.Options`: the host stdin and stdout for the CLI. A read returns after one host read, as on a terminal, so a typed line reaches the guest when Enter is pressed. That host read happens on a reader thread for the machine run (`src/consin.zig`), never on the guest's thread: the guest sleeps in the kernel (`src/kern/devhcons.c`) until the thread has input, so a note or a teardown interrupts a console read as it does any other blocking call. Nothing is read ahead of a guest's request. At the end of a run the thread is stopped through `Stdio.in_cancel` (the CLI's stdin polls with a wake pipe on POSIX and uses `CancelSynchronousIo` on Windows). Writing `rawon` to `/dev/consctl` switches the host TTY to raw mode (console mode on Windows). Ctrl-C posts an `interrupt` note to the foreground note group (see the CLI section's Signals and TTY for each host). Exit status: an empty `exits` string gives 0, a decimal number from 1 to 255 gives that number, and any other string gives 1 and is printed to stderr; a process killed by a note exits 128+N for a signal (see the CLI's exit codes).

**Graphics (`--gfx`).** A machine with `Machine.Options.gfx` claims the process's one window (`src/gfx.zig`; a second machine gets `GfxInUse`). The window is drawn by drawterm's own GUI backend, chosen at build time with `-Dgfx`: Cocoa on macOS and Win32 on Windows by default, X11 on Linux only with `-Dgfx=x11` (glibc), and `headless`, a screen in memory with hooks to inject keys and mouse events and read pixels, for `tests/backends.zig`. `-Dgfx=none` builds `src/kern/nogfx.c`'s stubs instead. The backend files are compiled unchanged; `src/kern/gfx-gui.h`, force-included before them, renames `screeninit`, `clipread`, `clipwrite`, and `kbdkey` to h9's wrappers in `src/kern/gfx.c`, and turns the backend's `exit` (or `ExitProcess`) on a closed window into `h9_gfx_exit`, which posts `hangup` to the machine with the window (as for a closed terminal) and parks the backend's thread. The window opens lazily, on the first walk below `#i` or open of `/dev/snarf`, so a program that never draws gets no window; the backend's kprocs run in an empty namespace of their own. `/dev/kbd` serves kbdfs's format (`k`/`K` for keys held, `c` for a key typed), which rio reads, and drops keys while it isn't open. `/dev/snarf` is the host clipboard, or under `--gfx=noclip` a buffer in the h9 process; machines without `#i` can't open it. The console stays the host terminal, so `/dev/cons` and kernel prints still go there. On macOS AppKit needs the main thread, so the CLI runs through `h9.gfx.main`, which gives AppKit the main thread and runs the machine on another; an embedder using `--gfx` on macOS does the same.

## Security, debugging, and testing

**Security stance.** The hypervisor isolates guest memory and the CPU, and every guest syscall is served by drawterm's kernel rather than the host's, so the guest never reaches host syscalls, ioctls, or the host environment directly. The namespace decides what a guest can reach on the host. Identity: hostowner is the host user's name; devfs maps the host's file ownership onto Plan 9 user strings.

### Sandbox policy

Sandboxing is a `Policy` in `Machine.Options`: a set of capabilities, host paths, network rules, and limits. The capability model follows [isobox](https://github.com/can1357/isobox): named capabilities, profiles that set defaults, explicit flags that override them, a printable plan with caveats, and `--strict` to refuse anything the build can't enforce. Unlike isobox, enforcement lives in the shared kernel, so the capability set is the same on every vmm backend; there's no per-host intersection to compute.

| Capability | Mechanism |
| --- | --- |
| `env.scrub` | The host environment is never imported |
| `kernel.isolation` | Guest syscalls are served by drawterm's kernel |
| `ipc.restrict` | Host sockets are reachable only through `#U`, `#I`, or `#C`, which the policy controls |
| `fs.read.scope`, `fs.write.scope` | The namespace is an allowlist: only listed host paths are bound from `#U`, each read-only or read-write |
| `fs.write.ephemeral` | Each path `scope` would make writable is a copy-on-write `#O` overlay over its `#U` tree instead; changes live in memory and vanish at exit |
| `fs.write.overlay` | A copy-on-write `#O` overlay over the root, whatever kind of root it is, so writes to it succeed in memory and vanish at exit; under `--write=overlay` (the default) and `--write=ephemeral` |
| `fs.read.deny` | Unbound paths don't exist; denied paths inside a bound tree are filtered in devfs |
| `net.disable` | `#I` and `#ℏ` are masked in the init Pgrp (drawterm's `devmasked`), so the guest can't re-attach them, and `/net/ws` isn't bound |
| `net.outbound` | devip refuses `announce`, TCP and UDP, so the guest can dial out but not serve; `/net/ws` only connects |
| `net.allow` | devip checks each `connect` against dial-string patterns (`tcp!10.0.0.0/8!564`, `tcp!*.example.com!443`), and devip's `cs` refuses to resolve names no pattern covers; an egress allowlist isobox can't offer |
| `res.memory` | A cap on the guest-physical page allocator; exact, not a watchdog |
| `proc.timeout` | A machine deadline: a `hangup` note to every process, then a hard teardown after a 2 s grace period |
| `res.pids`, `res.cpu` | A cap on live processes in `rfork`; a cap on vCPUs running guest code at once |

**Vendor hooks.** The policy lives in Zig. drawterm calls it through leaf functions, following seam rule 3. devfs-posix and devfs-win32 call `h9_fs_check(path, op)` (in `src/kern/fscheck.c`) before each walk, open, create, remove, wstat, and directory entry. It resolves the host path and asks the Zig leaf `h9_policy_check` for a verdict: allowed, hidden (the walk fails, or the entry is left out of the listing) or read-only ("permission denied"). devip calls `h9_net_check(op, proto, addr, port)` (declared in `src/kern/netcheck.h`) when a ctl file's `connect` or `announce` is parsed, before a port is bound or the host is dialed, and raises "permission denied" on a refusal. Its `cs` calls `h9_net_lookup(proto, name, port)` before the host's resolver, raising "no translation for host found" for a name no pattern covers, and `h9_net_resolved` after it. The machine's compiled plan is set per host thread, because each guest process runs on its own thread. The leaves return an int and never raise kernel errors themselves.

**Network rules.** Under `--net=outbound` (the default profile's setting) `announce` is refused; `--net=enable` allows it. Without `--net-allow`, a `connect` to link-local addresses (169.254.0.0/16, fe80::/10) is refused in both modes, which keeps the common cloud metadata endpoint out of reach, and everything else is allowed. With patterns, the patterns are the whole policy: a `connect` must match one, by protocol (`tcp`, `udp`, or `net`/`*`), address (an address, a CIDR range, or `*`) and port (a number, a range, or `*`). IPv4 is matched as IPv4, however devip spelled it. A name pattern (`api.example.com`, or `*.example.com` for one or more labels) can't be checked at `connect`, whose message is numeric, so `cs` resolves only names a pattern covers and records what each returned in the machine's resolved-name table (the 1024 most recent entries). A later `connect` to a recorded address is allowed if its name matches a name pattern with that protocol and port. A `/net/ws` `connect` is checked as a TCP dial to the URL's host and port: a name goes through the same lookup check and resolved-name table, and each address it resolves to through the connect check. Connections h9 makes itself (a root, a namespace-file mount) are outside the policy, and the guest can't reach them by name. `--net-allow` with `--net=disable`, or a bad pattern, is exit 2.

**Access rules.** The plan's rules are the root, the cwd, each `--readable` and `--writable` path, and each `--read-deny` path, all as resolved host paths. Overlaid paths (`eph`) are read-only rules, since the overlay never writes its lower tree. A deny rule covering a path wins. Otherwise the longest allow rule covering the path decides between read-only and read-write. Ancestors of allowed paths can be walked and listed but not changed, so `/mnt/term/<path>` works when the host's `/` is unioned after the tree's `/mnt/term`. Anything else is hidden. Bind-level read-only (no `MCREATE`) is a second, coarser check.

**Path resolution.** devfs-posix follows symlinks with `stat`, so a symlink inside a bound tree can point anywhere on the host. Every devfs path is resolved (`realpath`; on Windows the final path of an opened handle, which follows symlinks and junctions and refuses UNC and device paths) and the resolved path is checked against the access rules, on every host. Create, remove, and rename act on the name rather than a link's target, so an existing entry is checked by its own canonical name without following it. On macOS that's `F_GETPATH` on an `O_SYMLINK` open, and on Windows the final path of a reparse-point open, so another case, an 8.3 short name, or a trailing dot can't dodge a rule on a case-insensitive file system. A new name is appended to its resolved parent. A create over an existing symlink also checks the link's target for writing. Renaming a directory that has any rule strictly beneath it is refused ("permission denied"), because it would move those paths out from under their rules. The check and the host call aren't atomic, so a host process renaming paths at the same time can race it; the plan reports that, and hardlinks under writable paths, as caveats.

**Contained trees.** A bind from `#U!c/path` (design/0034-symlinks-in-root.md) is *contained*: devfs resolves its links itself, inside the tree, as `openat2`'s `RESOLVE_IN_ROOT` does. The tree's top is where namec's walk from the `#U!c` attach ends (`h9_fs_anchor`, called from the vendored `chan.c`), canonicalised. Each later walk looks names up one at a time with `lstat` (`h9_fs_resolvein` in `src/kern/fscheck.c`; on Windows `h9_fs_resolveinw`, which reads symlinks and junctions with `FSCTL_GET_REPARSE_POINT` and refuses other reparse points and UNC targets): a link's target is read, an absolute one starts again at the top (on Windows, with its drive dropped), a relative one from the link's directory, `..` at the top stays there, and more than 40 links in one walk is "too many symbolic links". The resolved path, which holds no links, is checked against the access rules as any other path is, so `--read-deny` and partly allowed trees still apply, and kept on the chan with the link's own path beside it: stat shows the link's name, remove and rename act on the link, and open, read, and wstat on its target. A listing shows each link with its target's `Dir` and leaves out a link whose target is missing or loops, since walking it fails. `h9_fs_readlink` (and `h9_fs_readlinkpath` by guest path, through the root overlay; `kern.readlink`) gives a link's target as written, for the Linux personality; Plan 9 programs never see links. An uncontained `#U` attach is unchanged. `--root-contained` makes the root's bind and the root overlay's lower tree contained; other binds, including writable paths inside the root, stay uncontained. `--print` shows the root as `bind '#U!c/path' /`, which replays with `--ns` where `#U` isn't masked. Any other `#U` attach spec is "bad attach specifier".

**Default profile.** With no sandbox flags the guest can work in the host cwd and nothing else:

| Area | Default |
| --- | --- |
| Root tree (`/`) | Read-only underneath, with an ephemeral overlay: writes succeed in memory, count against `--memory`, and vanish at exit, for a host tree and a 9P root alike. `$home` (`/usr/$user`) is made in the overlay if the root lacks it. Installing into the root needs `--writable "$H9ROOT"`; `--write=scope` makes it read-only, and a 9P root then as writable as its server allows |
| Host cwd (`/mnt/term/cwd`) | Read-write |
| Rest of the host filesystem | Not visible |
| `/tmp` | Private and writable, in memory (an overlay over the root tree's empty `/tmp`); read-only under `--write=none` |
| Network | Outbound: clients can connect anywhere except link-local, servers can't announce |
| Host commands (`#C`) | Masked |
| Environment | Only the default guest variables plus `--env` |
| Memory | The guest-physical region size (1 GiB; `--memory` sets it, up to 32 GiB) |
| Processes, CPU, timeout | Unlimited, so interactive sessions and long builds aren't cut off |
| Terminal | `cons` and `consctl` only; no host ioctls such as `TIOCSTI` |

`--profile=tight` differs in three ways: the cwd is read-only (an overlay under `--write=ephemeral`), `#I` is masked, and a default timeout of 10 minutes applies. Its root is an overlay and its `/tmp` private and writable, as in the default profile, since neither writes the host; `--write=scope` keeps a read-only root in either profile. `--sandbox DIR` is the tight profile with only DIR bound, read-write, as the cwd; the host cwd isn't bound.

**Discarded root changes.** The root overlay reports each create, copy-up, remove, and wstat to the machine once the namespace is built, so the `$home` the builder makes isn't counted. After a run, `Machine.root_changes` (a `RootChanges` value) says whether the guest changed the root outside `$home`, which top-level directories it changed, and whether it changed `$home`. When it changed the root outside `$home` and stderr is a terminal, the CLI prints `h9: changes to the root under /386, /lib were discarded (rerun with --writable "$H9ROOT" to keep them)` (for a 9P root, `--write=scope`). Scripts, whose stderr is rarely a terminal, don't see it.

**The root overlay's cost.** Every walk in the root goes through `#O`: a lookup in its memory tree, then the lower device. A lower directory keeps the mounts made on it before the overlay (`findmount` in `third_party/drawterm/kern/chan.c` asks `#O` for the lower device when a mount hash bucket has an entry for the same qid path), which only a namespace file's overlay over `/` needs. Measured on the emulator (Linux x86_64, 4 cores, best of 7 runs, `--write=overlay` against `--write=scope`): `du -a /sys/src`, twenty `ls -l` of `/bin`, `/lib`, and `/sys/include`, and `mk -n cat.install` in `/sys/src/cmd` all differ by less than 4%, within run-to-run noise, and the `[baseline]` suite passes the same cases either way. On HVF (M-series MacBook Pro), `zig build proposal -Dp=baseline` takes 27.29 s with the overlay against 27.05 s without (median of 3), under 1%, and the `du -a /sys/src` (9747 entries) and `ls -l` loop above takes 0.45 s with it against 0.44 s without (median of 3), within noise. No fast path in `#O` was needed.

**Plan output.** `--print` compiles the policy and exits without running. The namespace is printed in `newns` format, so it can be saved and replayed with `--ns`:

```text
$ h9 --print --profile=tight --writable ./out --memory 512m --timeout 1m mk
profile:  tight
enforces: env.scrub fs.read.scope fs.write.overlay fs.write.scope ipc.restrict kernel.isolation net.disable proc.timeout res.memory
limits:   write=overlay net=disable memory=512M timeout=1m
devmask:  #C #I #U #b #i #m
namespace:
  bind '#U/Users/me/h9root' /                             ro
  bind -c '#O' /                                          eph  # /Users/me/h9root
  bind '#c' /dev
  bind -b '#y<id>' /dev
  bind -c '#e' /env
  bind '#d' /fd
  bind '#p' /proc
  bind -c '#s' /srv
  bind '/arm64/bin' /bin
  bind -a '/rc/bin' /bin
  bind -a '#H/bin' /bin  # h9's commands
  bind -c '#O' /tmp                                       eph  # /Users/me/h9root/tmp
  bind '#U/Users/me/src/proj' /mnt/term/cwd                ro
  bind -c '#U/Users/me/src/proj/out' /mnt/term/cwd/out     rw
access:
  eph  /Users/me/h9root
  ro   /Users/me/src/proj
  rw   /Users/me/src/proj/out
caveats:
  - writes to the root are kept in memory, count against --memory, and are lost when the machine ends; when memory runs out they fail with "file system full"
  - a file opened for writing is copied into memory whole the first time
  - hardlinks under writable paths can modify host files outside them
  - writes to writable paths are not capped (no res.disk)
  - paths are checked after resolving symlinks, so a host process renaming paths concurrently can race the check
  - /proc/n/ns shows the host paths of bound host trees
  - the h9 process itself is not host-sandboxed
```

A 9P root is printed as `mount '#s/root' / '<spec>'` with `9p` in the access column and the dial string (and `--root-user`, as `as NAME`) in a comment. The spec is always written, `''` when empty, so a replay can tell it from the column; the line replays with `--ns` as an ordinary mount of the posted channel, a new attach on the same connection. A 9P root has no access rule. Under the root's overlay, a bare `bind -c '#O' /` after the mount, nothing reaches its server; under `--write=scope` the server decides what can be written, and the plan says so in a caveat. Another caveat covers a TCP root's unencrypted connection. `--write=none` with a 9P root is exit 2, because h9 can't make devmnt read-only. A WebSocket root's comment is its URL with the query elided (`?…`), its headers with their values as `…`, the proxy it goes through (credentials as `…@`) and `--root-ca`, and the unencrypted caveat applies to `ws://` but not `wss://`. `/net/ws`'s bind is printed as `bind -a '#ℏ' /net`, and `ℏ` joins the `devmask:` line under `--net=disable`. `--trace` prints no write data, so a URL written to a `ctl` doesn't appear in a trace.

`--net-allow` patterns are printed in a `net-allow:` section after `devmask:`. Requested capabilities the build can't enforce are listed on an `unenforced:` line, and `--strict` refuses them with exit 2; this build enforces every capability it knows, so the line doesn't appear.

The root's overlay is printed as `bind -c '#O' /` with `eph` and, over a host tree, the root's path in a comment, and the root's access rule as `eph`. Replayed with `--ns`, the line overlays whatever `/` is at that point; binds made before it onto directories of the root (the builder's own, when replaying into a running plan) are hidden under it, and the replay's later lines redo them, except `#U` binds, which the device mask refuses. The guest's cwd stays where the builder put it.

**Ephemeral writes.** `--write=ephemeral` binds each path `scope` would make writable (the cwd, in the tight profile too, and each `--writable` path) as a `#O` overlay over its `#U` tree, printed as `bind -c '#O' <target>` with `eph` and the host path in a comment. Reads come from the host tree; creates, writes, removes, and renames land in memory. The root is an overlay too, `--writable` or not. The overlay device (`src/kern/devoverlay.c`) keeps a tree in memory over a lower chan: a walk looks in memory first and falls through to the lower device, so devfs's checks (`--read-deny`, hidden paths, symlink resolution) apply to every lower lookup. A memory node is a copy (a file or directory with its own data), a whiteout (a removed lower name) or a directory marker (a lower directory with changed children). A lower file is copied up whole the first time it's opened for writing, or not read at all with `OTRUNC`; a process that already has the lower file open keeps reading it. Renaming a lower directory, or a marker, is refused ("permission denied"). Copies' data is page-sized blocks and the nodes, names, and `Dir` strings come from a small allocator on the same pages, all from the machine's guest-physical page allocator through Zig leaves (`h9_overlay_alloc` in `src/kern.zig`), so ephemeral files count against `--memory` and running out fails the operation with "file system full", changing nothing. Instances are made by the namespace builder (`h9_overlay_newpath`) and attached as `#O<n>`; attaching checks the instance belongs to the caller's machine, and the last close of its last chan frees it. In a namespace file, a bind from a bare `#O` makes a fresh instance over what its target is at that point in the replay. Ephemeral changes can't be exported yet.

**Examples**

```sh
h9 --profile=tight ls -l                                  # read-only, no network
h9 --net=disable --writable ./out --rc 'mk install'        # writes only to ./out
h9 --memory 256m --pids 32 --cpus 2 --timeout 30s rc       # resource caps
h9 --readable ~/src/proj --read-deny ~/src/proj/.env \
    --rc 'grep -n TODO /mnt/term/$home/src/proj/*.c'       # read a tree, hide secrets
h9 --rc 'echo hi > /lib/x && cat /lib/x'                  # the root is writable; /lib/x vanishes at exit
h9 --writable "$H9ROOT" --rc 'cd /sys/src/cmd && mk install'  # install into the root tree for real
h9 --net=enable aux/listen1 -t tcp!*!8080 /bin/cat           # a server needs --net=enable
h9 --net-allow 'tcp!*.example.com!443' myclient              # egress by name, through cs
```

Host paths given to `--readable` and `--writable` appear in the guest under `/mnt/term/<host path>`, as in drawterm; the cwd stays at `/mnt/term/cwd`.

### Debugging

- `--trace` logs each syscall with its arguments, result, and error string, prefixed by pid, like 9front's ratrace.
- acid (Plan 9's debugger) attaches to a live process through devproc's `mem`, `regs`, `fpregs`, `text`, and the `ctl` stop messages ([self-host](design/0010-self-host.md)). A process stops only on its own thread, at a stop point: entering a syscall, delivering a note (which a `stop` kick forces for one spinning in guest code), a breakpoint exit, or before its first instruction after `exec` with `hang`. It saves its Ureg and Extra to its record (`Proc.dbg_ureg`, `dbg_extra` in `src/machine.zig`) and sleeps on the record (`h9_kern_stopwait` in `src/kern/proc.c`), holding no vCPU, so readers on other threads never touch a backend. Register writes are kept in the record and loaded, through `arch.sanitize`, when the process resumes. `mem` reads and writes go through `AddressSpace.copy`; a write into text first gives the process its own copy of a shared text segment (`Segs.ownText`, 9front's `txt2data`) and then calls `codeChanged`, which bumps the flush epoch on hvf and kvm (the shim invalidates the I-cache before its next entry) and makes emu flush Unicorn's whole translation cache before its next run. `kill`, `--timeout`, and teardown interrupt a stopped process.
- `BRK` and `INT3` exit as `vmm.Exit.breakpoint`, and the machine posts `sys: breakpoint` with the debug flag, so a process without a handler dies with it and acid's `bpset`, `step`, and `next` work. The PC is left at the `BRK` on arm64 and after the `INT3` on x86, as on 9front.
- `--dump-on-fault` prints the Ureg, the faulting address, and a symbolized PC from the a.out symbol table.
- There's no gdb stub.

### Testing and CI

- Unit tests in Zig for the a.out loader, the page allocator, and the syscall decoders.
- Integration tests run real 9front binaries from a pinned root tree. Each case is tagged with the proposal it proves, and skips while that proposal isn't implemented ([design/README.md](design/README.md#tests)).
- `zig build integration` runs real binaries from the root tree through the `h9` CLI as subprocesses, so each case gets a fresh kernel and checks exit codes end to end; it skips when there's no tree. `zig build proposal -Dp=baseline` runs the baseline's demos and cases. The Lima test VMs get the tree with `scripts/lima/vm push-root`.
- `zig build integration -Dweb` runs the same cases through `h9-node` on v86 with the 386 root; cases that need a host TTY, POSIX signals, TCP, or what a page's WebSocket can't do (headers, a proxy, `--root-ca`, pings) skip there by name or tag. websocket-9p's servers are a native h9 behind `tests/wsrelay.zig`, since the web host can't listen, so those cases need `-Demu=unicorn` as well to run there. `zig build web-test` drives the demo page in Chromium with Playwright (`tests/web/browser.mjs`).
- CI isn't set up yet ([ci](design/ci.md)).

## CLI

The CLI is a thin wrapper: it parses argv into `Machine.Options`, runs one machine, and maps the result to an exit code.

```
h9 [h9-flags] [--] program [args...]
h9 [h9-flags] --rc 'command line'
h9 [h9-flags] rc                    # interactive shell
h9 [h9-flags]                       # no program: prints the usage to stderr, exit 2
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

A guest program follows `#!` as exec does, so rc scripts such as `man` and `lc` run directly. A host program (`./x`) must be an a.out; run a host script with `h9 rc ./x`.
| `--rc 'cmd'` | Runs `/bin/rc -c 'cmd'`; the remaining arguments become `$*` |
| `--ns file` | Runs `newns` with the file before the program |

**Flags**

| Flag | Meaning |
| --- | --- |
| `--backend auto\|hvf\|kvm\|whp\|emu` | `auto` (the default) uses the host hypervisor, and otherwise falls back to the emulator with a warning |
| `--arch arm64\|amd64\|386` | The architecture of the binaries to run, which also picks `/$cputype/bin`. Without it a host program runs as its header says, and a guest one as the host's architecture |
| `--root DIR\|DIAL\|SOCKET\|URL` | The root tree: a host directory, a 9P server's dial string (`tcp!host!port`, `tcp!host` for port 564, or `unix!path`), the path of a unix socket, or a `ws://` or `wss://` URL of a 9P server behind a WebSocket. If omitted, use `$H9ROOT` (same forms), then the default install location (`.local/9front/root` in development builds until there's an installer). With none found, only a host a.out runs; anything else is exit 125. A path that's neither a directory nor a socket, a failed connection or attach, and a unix socket root on Windows are exit 125 |
| `--root-spec NAME` | The attach name sent to a 9P root. Empty by default |
| `--root-user NAME` | The uname sent in h9's attaches to a 9P root. The machine's user by default |
| `--root-header 'NAME: VALUE'\|@FILE` (repeatable) | A header for a WebSocket root's handshake, or one per line from a file (blank lines skipped). Headers that change the handshake (`Host`, `Upgrade`, `Connection`, `Sec-WebSocket-*`, `Content-Length`, `Transfer-Encoding`) are refused. Without a `ws://` or `wss://` root, a bad header or a missing file is exit 2 |
| `--root-ca FILE` | A PEM bundle that a `wss://` root's certificate must chain to, instead of the host's. Without a `wss://` root, or a missing file, is exit 2. `HTTPS_PROXY`, `HTTP_PROXY`, and `NO_PROXY` choose an HTTP `CONNECT` proxy for WebSocket roots and mounts |
| `--root-contained` | The root tree's symlinks resolve inside it: an absolute target starts at the tree's top and `..` stops there, as for a Linux root or a container image ("Contained trees"). With a 9P root, exit 2 |
| `--env name=value` (repeatable) | Sets a guest environment variable. The host environment isn't imported. |
| `--cwd PATH` | The guest cwd. Defaults to `/mnt/term/cwd`, the host cwd bound into the guest |
| `--rc 'cmd'` | See program resolution |
| `--ns file` | Replays a namespace file (newns syntax: `bind`, `mount`, `unmount`, `cd`, `clear`, with `-a -b -c -C`) after the policy's namespace and before the program is looked up. It's a guest path, read as newns reads it, and `--print`'s namespace output replays as is, its `ro`/`rw`/`eph` column included; a bind from a bare `#O` makes a fresh overlay over its target. Failed operations are skipped, as in newns; a syntax error is exit 125. |
| `--profile default\|tight` | Sets the sandbox defaults (see Sandbox policy). Explicit flags override it. |
| `--readable PATH` (repeatable) | Binds a host path read-only at `/mnt/term/PATH` |
| `--writable PATH` (repeatable) | Binds a host path read-write; under the cwd it overrides a read-only cwd |
| `--read-deny PATH` (repeatable) | Hides a host path inside a bound tree |
| `--write none\|scope\|ephemeral\|overlay` | Deny writes; persist only writable paths (`scope`); `scope` plus a copy-on-write overlay over the root, discarded at exit (`overlay`, the default); or make the root and writable paths overlays in memory, discarded at exit (`ephemeral`) |
| `--net disable\|outbound\|enable` | Network policy: mask `#I`, refuse `announce` (the default profile's default), or allow it |
| `--net-allow PATTERN` (repeatable) | Allows `connect` only to matching addresses, and `cs` lookups only of matching names (`proto!host!port`) |
| `--memory SIZE` | Caps guest memory (`512m`, `2g`) |
| `--pids N`, `--cpus N` | Caps processes and concurrently running vCPUs |
| `--timeout DURATION` | Posts `hangup` at a deadline, waits up to 2 s, then tears down the machine |
| `--strict` | Refuses any requested capability this build can't enforce (exit 2) |
| `--print` | Prints the compiled policy and namespace, then exits |
| `--host-fs` | Exposes all of `#U`, not just the root and cwd |
| `--host-cmd` | Enables devcmd. Only in builds with `-Dhost-cmd`; otherwise the policy refuses it (exit 2) |
| `--no-guest-tools` | Leaves out the `#H/bin` bind of h9's own commands and masks `#H` |
| `--sandbox DIR` | The tight profile with only DIR bound, read-write, as the cwd. Can't be combined with `--host-fs` or `--host-cmd` |
| `--trace[=FILE]` | ratrace-style syscall log, to stderr by default |
| `--gfx[=noclip]` | Gives the machine one host window (see Graphics), with `/dev/draw`, `/dev/mouse`, `/dev/cursor`, and `/dev/kbd` in it, and `/dev/snarf` as the host clipboard; `=noclip` keeps `/dev/snarf` in the h9 process instead. Exit 125 if this build has no GUI backend, there's no display, or another machine in the process has the window |
| `--gfx-scale N` | The window's scale, drawterm's `-x` (Cocoa only): 0 draws in backing pixels, 1 (the default) in points, N in backing pixels divided by N. Needs `--gfx` |
| `--dump-on-fault` | Prints the Ureg and a symbolized PC when the guest faults |
| `--check` | Runs a test program on each backend built in, or just `--backend`'s (on HVF this also checks the entitlement), reports the vCPU limit, and runs `/bin/echo` from the root tree. Exits 0, or 125 if h9 can't run programs from the root |
| `--version` | Prints the h9 version (`git describe`, or `-Dversion` in releases), the pinned 9front release and drawterm revision, the backends built in, and the GUI backend (`gfx:`) |
| `--help`, `-h` | Prints the usage to stdout and exits 0 (`-h` only as the only argument) |

**Default guest environment:** `user` is the host user name, `home=/usr/$user`, `path=(. /bin)`, `cputype` and `objtype` come from the machine's architecture (`386` for 386), `sysname=h9`, and `service=terminal`. Everything else has to be passed with `--env`, which keeps host secrets out of the guest by default.

**Exit codes**

| Code | Meaning |
| --- | --- |
| 0 | `exits(nil)` or `exits("")` |
| 1–255 | An `exits` string that's that number in decimal: digits only, no sign, leading zero, or spaces. Nothing is printed, so rc's `exit 3` and Go's `os.Exit(3)` exit 3 ([go-compat](design/0007-go-compat.md)) |
| 1 | Any other `exits` string, including `"0"`, which is also printed to stderr; or the first process was killed by a note that isn't a signal |
| 2 | Usage error |
| 124 | `--timeout` stopped the program (`h9: prog: h9: timeout`), as coreutils `timeout` |
| 125 | h9 itself failed: no hypervisor, VM creation failed, the root wasn't found, a 9P root's connection, handshake, or attach failed, or a namespace file's WebSocket mount failed; or the run ended with `halted`, an unexpected VM exit, or an internal error |
| 126 | The program was found but isn't a runnable a.out (bad magic or wrong architecture) |
| 127 | The program wasn't found |
| 128+N | The first process was killed by a note that's signal N ([exit-status](design/0033-exit-status.md)): see below |

The 125–127 codes follow `env` and `docker run`. A guest can exit with them too, but h9 prints a message whenever it fails itself and a numeric `exits` prints nothing, so scripts can still tell h9 failures from guest failures. The mapping is in `src/cli.zig` and applies to every program; `Machine` returns the `exits` string unchanged, so library callers decide for themselves.

A first process killed by a note exits as a host shell reports a death by signal, 128 plus the host's number for the signal (`cli.killedStatus`):

| Note | Exit code | Printed |
| --- | --- | --- |
| One APE's `sigtab` (`/sys/src/ape/lib/ap/plan9/signal.c`) maps to a signal, by prefix: `interrupt` is SIGINT, `hangup` SIGHUP, `kill` and `die` SIGKILL, `sys: write on closed pipe` SIGPIPE, `sys: fp:` SIGFPE, and so on | 128 + the host's number, so 130 for `interrupt` | Nothing for `interrupt` and a closed pipe; otherwise `h9: prog: note` |
| `linux: signal N` (from the Linux personality) | 128 + the host's number for Linux signal N, matched by name; 1 if the host has no such signal | As above |
| Another `sys: trap: …` or `sys: bad address …` fault | 139 (SIGSEGV) | `h9: prog: note` |
| `h9: timeout` | 124 | `h9: prog: h9: timeout` |
| `h9: machine stopped` | 128 + the host signal that started the teardown (130, 129, or 143), or 125 if none did | `h9: prog: h9: machine stopped` |
| `halted`, `sys: trap: unexpected exit …`, `h9: <error>` | 125 | `h9: prog: note` |
| Anything else | 1 | `h9: prog: note` |

Signal numbers are the host's (`std.posix.SIG`), since a host shell decodes the status, so `usr1` is 138 on Linux and 158 on macOS; Windows uses Linux's numbers, as Git Bash and MSYS expect. A unit test checks the copy of `sigtab` in `src/cli.zig` against the pinned 9front source when it's been fetched. h9 exits with the status rather than re-raising the signal on itself.

**Signals and TTY**

- **Ctrl-C:** posts an `interrupt` note to the foreground note group; a program it kills exits 130. A second Ctrl-C within a second tears down the machine, which exits 130 too.
- **SIGTERM and SIGHUP:** post a `hangup` note to every process, then tear down the machine 2 s later, or sooner if it has exited by then. A program the note kills exits 129; a teardown exits 143 after SIGTERM and 129 after SIGHUP. `src/hostsig.zig` records which host signal started a teardown (the first one wins); on Windows, closing the console counts as SIGHUP, and logoff and shutdown as SIGTERM.
- **Raw mode:** the host TTY goes raw only when the guest writes `rawon` to `/dev/consctl`, and goes back on `rawoff`, on the last close of `/dev/consctl` (as on 9front), at the end of the run, and on a panic.

How each host delivers these:

| | Linux and macOS | Windows |
| --- | --- | --- |
| Ctrl-C | The terminal driver turns it into SIGINT (ISIG) in cooked mode | `CTRL_C_EVENT` to a `SetConsoleCtrlHandler` handler, while `ENABLE_PROCESSED_INPUT` is on |
| Ctrl-C in raw mode | ISIG is off, so 0x03 reaches the guest as a key, as Del does on 9front under rawon | Processed input is off, so the same |
| Hangup | SIGHUP (terminal closed), SIGTERM | `CTRL_CLOSE_EVENT`, `CTRL_LOGOFF_EVENT`, `CTRL_SHUTDOWN_EVENT`; Windows kills the process about 5 s after these, so the grace period has to be shorter. `CTRL_BREAK_EVENT` posts `interrupt` |
| Raw mode | termios: clear ICANON, ECHO, and ISIG | Console mode: clear `ENABLE_LINE_INPUT`, `ENABLE_ECHO_INPUT`, and `ENABLE_PROCESSED_INPUT`; set `ENABLE_VIRTUAL_TERMINAL_INPUT` |
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
    root: ?Root = null,                 // .dir (host directory), .tcp (dial string), .unix (socket path) or .ws (URL)
    root_spec: []const u8 = "",         // attach name for a 9P root
    root_user: ?[]const u8 = null,      // attach uname for a 9P root; null: the machine's user
    root_headers: []const []const u8 = &.{}, // handshake headers for a WebSocket root, checked
    root_ca: ?[]const u8 = null,        // PEM bundle for a wss:// root; null: the host's
    proxy: ?Proxy = null,               // HTTP CONNECT proxies for WebSocket roots and mounts; null: direct
    cwd: ?[]const u8 = null,
    env: []const EnvVar = &.{},
    policy: Policy = .{},               // profile, binds, read-deny, net rules, limits, host_fs, host_cmd
    guest_tools: bool = true,           // bind #H/bin, h9's own commands, after /bin; false masks #H
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
- [isobox](https://github.com/can1357/isobox): capability model, profiles, plan caveats, and `--strict`
