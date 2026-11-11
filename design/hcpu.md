---
issue: 174
slug: hcpu
title: hcpu, h9's own CPUs for the emulator
status: proposed
created: 2026-11-10
authors: [progrium]
depends: []
areas: [vmm, build, web, tests]
---

# Proposal: hcpu, h9's own CPUs for the emulator

## Abstract

hcpu is h9's family of user-mode CPUs written in Zig: h86 for 386 programs, ha64 for arm64 programs, and hx64 for amd64 programs. Together they make up the emulator backend in place of Unicorn and replace v86 in the browser host. Each has two tiers: an interpreter, T0, which is the fallback and the oracle, and a JIT, T1, which lifts regions of guest code to a small IR shared by every CPU and emits arm64, x86-64, or wasm code from it. Any instruction T1 doesn't lift runs through T0 from inside compiled code, so each CPU runs every instruction it advertises on both tiers. None emulates a system: a system call or a fault is a vmm exit, as on every backend. Guest threads run in parallel, where Unicorn runs one at a time. The code is MIT, so the emulator can ship in `h9` itself, and the browser host becomes one module with no guest kernel. h86 and ha64 were built first, on the `vcpu` branch (#156), and hx64, which is h86 extended to long mode, followed (#168), so with all three, h9 needs no Unicorn for any guest. This proposal records their design; [spec/h86.md](../spec/h86.md), [spec/ha64.md](../spec/ha64.md), [spec/hx64.md](../spec/hx64.md), and [spec/jit.md](../spec/jit.md) describe what was built.

## Background

### Unicorn on native hosts

The emulator backend has been Unicorn, which is QEMU's TCG behind a C API (SPEC.md, Emulator backend). It's how h9 runs where there's no usable hypervisor: Linux without KVM (containers, CI runners, and cloud VMs without nested virtualization), macOS without HVF, Windows without WHP, and any host running another architecture's root, such as an amd64 root on an arm64 Mac. Its costs:

- **GPLv2.** It sits behind `-Demu=unicorn` and ships only as the separate `h9-emu`, so the MIT `h9` has no emulator to fall back on.
- **Prebuilt for three targets.** Windows builds it from source with our own `build.zig`.
- **Serialized threads.** Unicorn generates code for a single-threaded context, so guest atomics become plain accesses, and the backend runs guest code on one engine at a time under a time-sliced lock (SPEC.md, Atomics). A Go, Python, or PostgreSQL program with four busy threads gets one core.
- **Workarounds.** A virtual-TLB fill hook, trap pages for faults, an FXSAVE image assembled register by register, a read-only GDT page so 32-bit segment loads keep their flags, and kicks that must stop the engine from its own block hook.
- **Speed.** 1.4 s for the 10⁹-iteration bench loop on an M3 Max (5× HVF), and about 0.35 µs to exit and re-enter for a system call.

The [linux-personality](linux-personality.md) and [linux-threads](linux-threads.md) work made the last two matter: CPython, SQLite, git, and Go programs spend their time in compute, memory, and threads, and use all of AdvSIMD on arm64.

### v86 in the browser

The browser host ([browser-host](browser-host.md)) ran 386 programs on v86, a whole PC, through a guest kernel of its own: a shim that started in real mode and built a GDT, IDT, TSS, and page tables so a ring-3 process could run; system calls and faults that exited by halting at ring 0, about 3 µs a round trip; a ring-0 Ureg rebuilt by writing v86's private register block on every preemption, at offsets pinned to one v86 release; and `h9.wasm` and `v86.wasm` sharing one memory, instantiated in a fixed order. h9 used a fraction of v86 and spent a lot to reach it.

### The plans

[zig-interpreter](zig-interpreter.md) proposed an arm64 interpreter in Zig for 9front's subset, and its spike ran 300 to 500 M instructions/s, exited for a system call in 13 ns, and needed no guest lock. Two later plans built on it: an arm64 JIT on rv64.js's design, to replace Unicorn for arm64 and reach rv64.js's speed class, and a rewrite of v86's 386 core in Zig as a user-mode CPU, to replace v86 in the browser and Unicorn for 386 on native hosts. They agreed on one JIT layer under both, and a third plan split the work into parallel streams around fixed contracts (the IR, its reference evaluator, the runtime ABI, and the TLB) with an IR evaluator in the middle, so lifters and emitters could each be tested alone. They were posted in project threads, not filed, and the code came first on the `vcpu` branch. This proposal combines them, as built, and adds hx64, which the 386 plan left for later and which was built after them.

## Proposal

### Three CPUs, two tiers, one JIT layer

`-Demu=hcpu` builds the emulator backend (`src/vmm/hcpu.zig`) on three Guests: ha64 (`src/vmm/ha64.zig`) for arm64 binaries, h86 (`src/vmm/h86.zig`) for 386 binaries, and hx64 (`src/vmm/hx64.zig`) for amd64 binaries, picked by the binary's architecture when the backend is created, so no guest architecture needs Unicorn.

The names are "h" and the instruction set's short name: 86 for the 386, A64 (Arm's name for arm64's instruction set), and x64 (the name the JIT's x86-64 emitter already has). hcpu names the family, and the code uses it throughout: `src/hcpu.zig` is the module root for the CPUs and the JIT layer (imported as `hcpu`), `src/vmm/hcpu.zig` is the vmm backend over the Guests, `-Demu=hcpu` builds it in, `zig build hcpu` and `zig build hcpu-web` run its tests, and `-Dhcpu-debug` builds it with `-Doptimize` instead of ReleaseFast. Unicorn's backend is `src/vmm/unicorn.zig`, built with `-Demu=unicorn`, so each backend file is named for what it runs, as `kvm.zig` and `hvf.zig` are. The module and the backend stay separate: the module depends only on the standard library, so it builds ReleaseFast inside a Debug `h9` and builds alone for the tools and fuzzers, while the backend depends on the vmm layer. Source trees stay named by instruction set (`src/{interp,jit}/{x86,a64}/`), and hx64 lives in the `x86` trees with h86, since it's the same decoder and interpreter in another mode.

| Tier | What | Where |
| --- | --- | --- |
| T0 | An interpreter over decoded instructions, cached per guest page | Everywhere; the only tier on hosts that refuse generated code |
| T1 | Regions lifted to the IR, optimized, and emitted | arm64 and x86-64 hosts, and wasm on the web host |

T0 runs code until T1 has it, runs any instruction T1 doesn't lift (`call.interp`), and raises every exception with its architectural detail: a region that faults leaves guest state exact at the instruction, and T0 runs that one instruction again. Every region can be checked against T0 from the same state.

The shared layer under `src/jit/` is guest-independent: the IR and its reference evaluator, the passes, linear-scan allocation, the arm64, x86-64, and wasm emitters, the code cache and dispatcher, and W^X executable memory. A front end per instruction set (`src/jit/a64/`, and `src/jit/x86/` for h86 and hx64) decodes through its T0's decoder, lifts, and keeps its flags, which are IR values per guest (`nzcv.*`, `eflags.*`). [spec/jit.md](../spec/jit.md) gives the details.

### Scope

- **ha64:** all of Armv8.0's A64 at EL0, with FP and Advanced SIMD, which is what h9 advertises to Linux programs, plus LSE atomics, CRC32, AES with PMULL, SHA1, and SHA256, each advertised through `vmm.Backend.hwcaps` once both tiers run it.
- **h86:** a ring-3, flat-segmented 386 through the Pentium Pro, with x87, MMX, SSE, and SSE2, and FS and GS bases from a small selector table instead of a GDT. CPUID reports SSE2 and nothing later.
- **hx64:** a ring-3, flat 64-bit long-mode process: h86's integer, x87, MMX, SSE, and SSE2 at 64-bit widths with REX, plus `CMPXCHG16B` and `LAHF`/`SAHF`, which every amd64 CPU in use has. That's x86-64-v1, the baseline Alpine, Debian, Ubuntu, and Go's `GOAMD64=v1` build for. FS and GS bases are plain values that `arch_prctl` and 9front's TLS set, with no selector table. CPUID reports SSE2 and nothing later.
- **None** emulates a system: no kernel mode, MMU, interrupts, or devices. A system call, fault, breakpoint, or undefined instruction is a vmm exit with the Ureg's trap fields set as the real kernel would set them.

### hx64

hx64 is h86 extended, not a fourth design. amd64's long mode is the 386's encoding with REX prefixes, wider registers, and a few opcodes reassigned, and everything around the decoder (the IR, the emitters, the TLB, the code cache, `hcpu`, SoftFloat, h86's x87 and SSE, and `Region.tso`) already handles 64-bit guests for ha64. The Linux personality already runs amd64 programs on KVM, the native backend, and Unicorn, so its system call arguments, numbers, signal frames, and `arch_prctl` are done, and Unicorn's amd64 code in `src/vmm/unicorn.zig` shows the Ureg and `SYSCALL` exit.

What's new:

- **Decoding.** Long mode is a comptime mode of h86's encoding table and decoder, so the 386 path costs nothing at run time. It adds REX (and the REX.W operand size), operations that default to 64 bits (`PUSH`, `POP`, near branches, and `CALL`), RIP-relative addressing, the 32-bit address size through `67`, `MOVSXD`, `MOV` with a 64-bit immediate, and `CMPXCHG16B`. `40` to `4F` are REX, not `INC` and `DEC`. Opcodes long mode removes (`PUSHA`, `POPA`, the BCD ops, `BOUND`, `LDS`, `LES`, `INTO`, and one-byte segment pushes and pops) raise #UD. `SYSCALL` is the system call exit for 9front and Linux both; `INT $64` and `INT 0x80` raise #GP.
- **State.** 16 general registers of 64 bits, RIP, 16 XMM registers, and the FS and GS bases. 32-bit writes zero the upper half, as the hardware does. `getUreg` and `setUreg` convert to and from 9front's amd64 Ureg, and `getExtra` and `setExtra` copy the FXSAVE image, as h86's do.
- **Flags.** The lazy flags record (`flags.Lazy`, which the JIT writes as `ir.LazyRecord`) holds 32-bit operands, and the emitters, wasm's included, hard-code its layout. It widens to 64-bit operands and an operand size of 8 for h86 and hx64, h86 zero-extending into it, and `eflags.*` accept `i64` operands. That's the one contract change: existing ops gain a width, and none is renumbered.
- **Lifting.** `src/jit/x86/lift.zig` takes the mode as a comptime parameter too: values are `i64` where the operand size is, addresses add RIP, and the extra registers are more chunks for the allocator to pin.
- **Selection.** The backend picks hx64 for amd64 binaries natively and in the web build, which already runs ha64 as well as h86.

Speed on x86-64 hosts matters less than elsewhere, since amd64 programs there run on KVM, WHP, HVF, or the native backend at hardware speed. hx64 is for arm64 hosts, the browser, and x86-64 hosts where none of those works.

### Memory

Every guest access, in T0 and in generated code, goes through a per-vCPU software TLB (256 read and 256 write entries, each a page tag and a host delta) with a slow path that fills it from the vCPU's copy of its address space. Guest exceptions never come from host traps. A page anything was decoded or compiled from never gets a write entry, so a guest store to it drops its translations first, which keeps self-modifying code and Linux JITs correct.

### Threads

There's no guest lock. Every vCPU runs at once, and other threads reach one only through its exit-request word, which T1 checks at region entries and loop heads and T0 at every block. A kick returns `.interrupted`; a shootdown or a code-cache flush makes the vCPU leave guest code, catch up, and carry on, while the thread that asked waits until it has. Guest atomics are host atomics. x86's TSO holds on arm64 hosts because every h86 and hx64 region is marked `tso`, which makes its loads load-acquires and its stores store-releases.

### Code generation

Natively, a region is compiled the first time its entry is dispatched, into a 64 MiB code cache per backend, keyed by guest PC and arena page so forked processes share text. Direct exits are chained by patching, indirect branches look up a per-vCPU jump cache inline, and a full cache is flushed by kick and wait. Where executable memory can't be had, the backend runs T0 with no warning, since the results are the same.

On arm64 hosts, ha64 copies register-only instructions verbatim with their register fields rewritten, so integer, FP, and AdvSIMD data processing cost nothing to translate and FP is the hardware's.

### The browser host

The web build runs h86 inside `h9.wasm`, with T1 compiling hot blocks into batched wasm modules that `h9-web.js` compiles asynchronously into h9's own function table, and T0 running until they're installed. v86, its shim, its pinned offsets, its instantiation order, and `v86.wasm` go. Preemption is an instruction budget, and a system call is a return from `run`. `--backend v86` is an alias of `emu` for one release, then a usage error.

### Build and selection

- `-Demu=hcpu` builds every CPU and both tiers; `-Dno-jit` builds T0 alone, as for iOS; `zig build web` always uses h86 with the wasm JIT.
- Once Done when passes for h86 and ha64, `-Demu=hcpu` becomes the default for the MIT `h9`, so `auto`'s fallback without a hypervisor runs arm64 and 386 programs with no Unicorn. `-Demu=unicorn` stays for `h9-emu` until hx64 passes Done when too, and for lockstep testing after that. Then `h9-emu` is no longer released.
- `vmm.Kind` keeps one `emu`. `--version` and `--check` report `hcpu (jit)` or `hcpu (interpreter)`. `H9_EMU_TIER` picks a tier for tests.

### Testing

T0 is checked against Unicorn in lockstep, Berkeley TestFloat (for the FP libraries), and the host CPU (for ha64 on arm64 Macs, and for hx64 on x86-64 hosts). T1 is checked against T0 a region at a time, in unit tests, in two fuzzers, and, with `-Djit-check`, for every region the integration suite runs. Emitters are checked against the IR's reference evaluator, natively, under Node, and in Chromium. Litmus tests check the memory model on host threads.

## Rationale

**Why our own CPUs, not a better-licensed library.** Dynarmic (0BSD) is a C++ A64 JIT with its own build, allocator, and memory model, x86-64 and arm64 hosts only, and no wasm. Box86, FEX-Emu, and Blink target Linux userland on particular hosts, with no interpreter tier or wasm. LLVM ORC and Cranelift compile in milliseconds per region and are tens of megabytes. QEMU's TCG is the GPLv2 problem being solved. What h9 needs is small and specific: user mode only, one vmm contract, three hosts, and wasm.

**Why a region IR, not a template JIT.** Keeping guest registers in host registers across a region, computing flags only where they're read, and chaining exits directly are where the speed is, and they need an IR. rv64.js's history showed dispatcher crossings and per-value locals cost more than instruction selection, so the IR stays small: no global optimizer and no scheduling.

**Why the interpreter as T0 and `call.interp`.** One semantics per instruction, tested against Unicorn and the hardware, serves the rare instructions, the exceptions, and the oracle. Lifting is then only a speedup, ordered by the inventory tools, and the JIT ran every program from its first day.

**Why one layer for every guest.** The IR, allocation, emitters, TLB, exits, chaining, cache, and executable memory are most of a JIT, and none of it depends on the guest. Each emitter is tested by more than one instruction set.

**Why hx64 extends h86, not a CPU of its own.** Long mode shares the 386's encodings, flags, string operations, x87, and SSE, which are most of h86's code, and real CPUs run both from one decoder. A comptime mode keeps one table and one set of semantics, so a fix to either applies to both, with no run-time cost to the 386 path. A separate amd64 CPU would copy most of h86 and drift from it.

**Why x86-64-v1, not v2 or v3.** v1 is what the distributions h9 roots come from build for, and it's what h86 already implements at 32 bits. v2 (SSE3, SSSE3, SSE4.1, SSE4.2, and `POPCNT`) is a moderate follow-on that RHEL 9 and its rebuilds need. v3 needs VEX encoding and 256-bit vectors, which the IR doesn't have.

**Why rewrite v86 rather than keep it.** v86 is a PC, and h9 used its CPU at ring 3 through a guest kernel, private offsets, and a ring-0 rebuild per preemption. Its JIT emits only wasm and its interpreter is bound to full-system state, so neither could serve native hosts. Its design and semantics, which are BSD-2, carried over: the encoding table, lazy flags, page-keyed code, batched modules, and SoftFloat's x87.

**Why software FP.** x87 extended precision, precision control, and exception flags have no host equivalent outside an x87 unit, and wasm leaves NaN bits unspecified. SoftFloat's `extF80`, ported to Zig, and a shared binary16, 32, and 64 library with each architecture's rules as parameters, give the same bits everywhere. ha64 on arm64 hosts gets the hardware's FP through verbatim copies.

**Why a software TLB, not host page protection.** Mapping each address space into a reserved host range and taking guest faults from host signals ("fastmem") is faster per access, but needs per-host signal handling and a huge reservation per space, and can't work in wasm. The inline check is six instructions on arm64 and keeps every bounds check in code we control.

**Why acquire and release for TSO on arm64.** Plain accesses break Go's runtime and lock-free code, barriers around every access cost more than LDAPR and STLR, and taking turns gives up parallel threads.

**Why compile on first dispatch natively, and on heat in wasm.** h9 runs many short processes, and lifting and emitting a region costs microseconds natively. In wasm a module costs a compile in the engine, asynchronously, so hot blocks are batched, and a vCPU's first 2M instructions compile nothing.

## Compatibility

- **CLI and exit codes.** Unchanged, apart from `--backend v86`, which stays an alias of `emu` for one release and is then a usage error.
- **`Machine.Options` and the vmm interface.** Unchanged. `Backend.hwcaps` reports the emulator's arm64 extensions under `-Demu=hcpu`.
- **Guests.** A 9front process sees the same Ureg, notes, and FP state, on every CPU. The 386 FXSAVE image's last-instruction fields, which Unicorn left zero, are filled. Linux arm64 programs see LSE, CRC32, AES, PMULL, SHA1, and SHA256 in `AT_HWCAP` on the emulator. CPUID on h86 and hx64 reports "GenuineIntel", family 6, and SSE2. amd64 programs that Unicorn ran with its CPU's later extensions see SSE2 only, as h86's 386 programs do.
- **The browser host.** The page's API is unchanged. `zig-out/web/` loses `v86.wasm` and its licence, and the download shrinks from 3.82 MB to 3.68 MB.
- **Build and releases.** `-Demu=hcpu`, `-Dno-jit`, `-Djit-check`, `-Djit-verify`, and `-Dhcpu-debug` are new. The code was built with `-Demu=zig`, `-Dvcpu-debug`, `zig build vcpu`, a `vcpu` module, and a `zemu.zig` backend, all renamed to hcpu before release, with no aliases. The release `h9` gains an emulator once the default switches. `h9-emu` stays until hx64 passes Done when.
- **Licences.** h9 stays MIT. `f80.zig` keeps SoftFloat's BSD-3 notice; nothing is copied from v86's or rv64.js's code.
- **zig-interpreter.** This proposal includes and widens it, so it should be marked superseded by this one once this is filed.
- **Root tree and `third_party/`.** Unchanged.

## Security

On the emulator the isolation boundary is software, as it was with Unicorn. With a JIT, guest-controlled input decides what host code is generated, so a bug in lifting, allocation, or emitting could produce host code that does something the guest's instructions couldn't. That's the class of risk QEMU's TCG carries, in much less code.

- **Every guest access goes through the TLB check** against arena memory the address space owns. No generated code computes a host address from guest data except as guest address plus delta after a tag match.
- **No host addresses reach the guest,** and no guest value is used as a host pointer, table index, or jump target: indirect branches go through the jump cache's tag compare or the dispatcher, and wasm's through table slots the runtime fills.
- **W^X everywhere.** No page is writable and executable at once, except under a binary translator on Linux that misses writes through a second view, where codemem falls back to one RWX mapping.
- **No host faults for guest behaviour.** A host fault inside generated code is a bug, and panics the machine.
- **Decoding** reads only through the TLB, and the x86 decoder stops at 15 bytes in either mode. Register fields index fixed arrays, and the x87 stack index is masked.
- **Checks.** `zig build hcpu` runs the region check, the fuzzers' unit runs, and the emitters' cases against `ir_eval`, and [ci](ci.md) would run them on every push.

In the browser the boundary improves: there's no guest kernel whose page tables are all that stand between a process and the rest of guest RAM. The sandbox policy is unaffected, since it's enforced in the kernel above the vmm layer.

## Done criteria

- [ ] `zig build integration -Demu=hcpu` with `H9_TEST_BACKENDS=emu` passes every `[baseline]`, `[linux-personality]`, and `[linux-threads]` case on T1 on macOS arm64, Linux arm64, Linux x86\_64, and Windows x86\_64, with the arm64 root, with `-Darch=386`, and with the amd64 root, and on T0 on Linux x86\_64.
- [ ] On macOS arm64, `H9_TEST_BACKENDS=hvf,emu` passes on T1, so the syscall traces match HVF's.
- [ ] `zig build integration -Demu=hcpu -Djit-check` passes with no divergence.
- [ ] `zig build integration -Dweb` passes every case it passed on v86, and `zig build web-test` passes in Chromium with no `v86.wasm`.
- [ ] `zig build test -Demu=hcpu` passes `tests/backends.zig` on T0 and T1 for all three architectures.
- [ ] The cases in `tests/a64.zig`, `tests/x86.zig`, and `tests/x64.zig`, tagged `[174]`, pass on T0 and T1:
  - `test "a store to a page of compiled code takes effect at the next instruction [174]"`
  - `test "a fault in a compiled region reports the exact PC and registers [174]"`
  - `test "a kick stops a compiled loop that makes no system calls [174]"`
  - `test "four LDXR/STXR threads lose no increments [174]"`
  - `test "four LDADD threads lose no increments [174]"`
  - `test "unmapping a page another vCPU has cached faults its next access [174]"`
  - `test "a full code cache flushes while other vCPUs run [174]"`
  - `test "FP results and FPSR are the same bits on T0 and T1 [174]"`
  - `test "deterministic mode counts the same instructions on T0 and T1 [174]"`
  - `test "a DIV by zero gives vector 0 at the DIV [174]"`
  - `test "fistp truncates under RC=chop [174]"`
  - `test "x87 results are the same bits on every host [174]"`
  - `test "a REP MOVSB stopped by a fault is exact, and resumes [174]"`
  - `test "a store into the executing page takes effect at the next instruction [174]"`
  - `test "an instruction crossing into an unmapped page faults at its first byte [174]"`
  - `test "an unknown GS selector raises #GP [174]"`
  - `test "CPUID reports SSE2 and no AVX [174]"`
  - `test "a REP stopped between iterations on T0 resumes exactly [174]"`
  - `test "four LOCK XADD threads on T0 lose nothing [174]"`
  - `test "a 32-bit write zeroes the upper half of a 64-bit register [174]"`
  - `test "a RIP-relative load reads past the instruction [174]"`
  - `test "INT 0x80 in long mode raises #GP [174]"`
  - `test "four CMPXCHG16B threads lose no increments [174]"`
  - `test "arch_prctl's FS base reaches FS-relative loads on T0 and T1 [174]"`
- [ ] `zig build fuzz-long` runs an hour on an arm64 and an x86-64 host with no divergence, and `zig build litmus` shows no forbidden outcome on any tier.
- [ ] `zig build bench -Demu=hcpu` reports, on an M3 Max and an x86-64 Linux host, the bench loop at or under Unicorn's time for arm64, 386, and amd64, a system call round trip under 100 ns natively, and four busy threads at least 3× faster than one; SPEC.md gives the numbers.
- [ ] Demos: on a Linux arm64 host without KVM, from a default MIT build, `h9 --backend emu --root .local/linux/alpine-arm64 /bin/busybox sh -c 'i=0; while [ $i -lt 1000000 ]; do i=$((i+1)); done; echo $i'` runs faster than with `h9-emu`; on a Mac without Unicorn, `h9 --arch 386 --backend emu --root .local/linux/alpine-386 /bin/busybox sh -c 'echo hello; ls /etc | wc -l'` runs, and so does the same with `--arch amd64` and an amd64 Alpine root; and the `zig build web` demo page runs rc.

## Implementation

h86 and ha64 were done on the `vcpu` branch, in parallel threads around the contracts, and merged in #156:

1. The contracts and a tracer bullet: the IR, `ir_eval`, the runtime ABI, the TLB entry and slow-path signatures, the front-end and emitter interfaces, and a counted arm64 loop run on T0, in `ir_eval`, natively, and in wasm.
2. SoftFloat's `extF80` ported to Zig, passing TestFloat's level 1 and 2 vectors, and a shared binary16, 32, and 64 library.
3. Both T0s: ha64's integer, FP, AdvSIMD, and extensions, checked against the hardware; h86's integer, string, x87, MMX, SSE, and SSE2, checked against Unicorn.
4. The JIT runtime (the dispatcher, code cache, chaining, jump cache, and invalidation), W^X code memory on macOS, Linux, and Windows, and the backend (`src/vmm/hcpu.zig`) with no guest lock.
5. The arm64 emitter with linear-scan allocation and verbatim copies, the x86-64 emitter, and the wasm emitter with structured control flow and chain cells.
6. Both lifters, with flags as values, h86's lazy flag records, x87 helpers, and SSE and AdvSIMD lifting; the region check, the fuzzers, the litmus tests, and `-Djit-check`.
7. h86 in the browser: T0, then wasm T1, then the default, and v86 retired.

hx64 was done on the `hx64` branch and merged in #168, with hot-block compiling after it:

8. Widen the lazy flags record and `eflags.*` to 64 bits, in the IR, `ir_eval`, and the three emitters, with h86's cases passing unchanged.
9. hx64's T0: long mode as a comptime mode of the encoding table, decoder, and `exec.zig`, the Cpu and its Ureg and FXSAVE conversions, `CMPXCHG16B`, and `SYSCALL`; checked against Unicorn in lockstep and against the host CPU on x86-64.
10. `src/vmm/hx64.zig` as a Guest of `src/vmm/hcpu.zig`, picked for amd64 binaries natively and on the web, with the amd64 root passing `[baseline]` and `[linux-personality]` on T0.
11. The lifter in long mode, `fuzz-x64` and the region check for it, and `x64inv` from `x86inv` to rank what to lift.

Along the way, the code took the hcpu name: the `vcpu` module, steps, and flag, and the `zemu` backend, were renamed (#172), and SPEC.md's Emulator backend section points to the CPUs' specs.

Left:

12. Retag the `[a64-jit]` and `[x86-jit]` cases as `[174]` (at the end of the name, as `check` expects), add the `tests/backends.zig` runs on both tiers, and run Done when for h86 and ha64 on every host, including Windows.
13. Lift LSE atomics to `cas` and a read-modify-write, and the MMX forms, as the inventories rank them.
14. Update MANUAL.md, make `-Demu=hcpu` the release default, and set `status: implemented`.
15. Run Done when for hx64 and stop releasing `h9-emu`.
16. A release later, make `--backend v86` a usage error.

## Open issues

- **x86-64-v2 and v3 for hx64.** v2 is SSE3, SSSE3, SSE4.1, SSE4.2, and `POPCNT` in T0 and the lifter, with CPUID reporting them. v3 is VEX, AVX, AVX2, BMI, and FMA, and needs 256-bit vector values in the IR. Each on demand from the inventories.
- **A threaded-code tier for iOS,** emitted from the same IR as a list of handler addresses, where generated code isn't allowed. Its own proposal, with an iOS host.
- **Hardware TSO on Apple silicon.** Rosetta runs with the cores' TSO mode on, but macOS has no API for it; Linux on Apple silicon has `PR_SET_MEM_MODEL`. Where it's available, h86 regions could use plain accesses.
- **Copying 386 instructions on x86-64 hosts,** as ha64 copies on arm64: most 386 integer code is valid x86-64 with the same 32-bit results, given remapped registers and re-encoded one-byte `INC` and `DEC`.
- **Sharing translations across processes** by file and offset, or by content, so an rc pipeline's tenth `grep` reuses the first one's code; a persistent cache would go further.
- **Fastmem on arm64 hosts,** as an option, if memory-heavy code needs the last 20 to 40%.
- **Blinding large immediates** against JIT spraying, and what it costs.
- **A return-address stack,** if the jump cache's hit rate on returns says it's worth it.
- **Running 386 natively on x86-64 hosts** in a compatibility-mode segment, on the native backend and KVM.
