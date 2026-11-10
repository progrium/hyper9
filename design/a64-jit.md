---
slug: a64-jit
title: An arm64 JIT for the emulator
status: draft
created: 2026-11-10
authors: [progrium]
depends: [19]
areas: [vmm, build, tests, linux]
---

# Proposal: an arm64 JIT for the emulator

## Abstract

A dynamic binary translator, written in Zig, that runs user-mode arm64 code for the emulator backend and replaces Unicorn for arm64 guests. It covers all of A64 at EL0 that h9 advertises to programs (Armv8.0 with FP and Advanced SIMD), for 9front and Linux programs alike, and nothing of a full system: no EL1, no MMU, no devices, no interrupts. Its unit is a region of guest code lowered through a small IR, with guest registers in host registers, flags computed only where they're read, and memory reached through an inline software TLB. It emits arm64 and x86-64 code natively, and its IR is shaped so that a wasm emitter for the browser host fits behind it. [zig-interpreter](0019-zig-interpreter.md)'s interpreter is its first tier, its fallback for anything not compiled, and its oracle, and stays the engine where code can't be generated, such as iOS. Unlike Unicorn, it runs guest threads in parallel. The target is the speed class of rv64.js's wasm JIT, which in a browser is on par with v86: natively, at least Unicorn's speed on compute, and faster on mixed and threaded work.

## Background

### Unicorn in h9 today

The emulator backend (`src/vmm/emu.zig`) is Unicorn, which is QEMU's TCG. It's the only way to run arm64 code on a host without a usable hypervisor: Linux arm64 without KVM (containers, CI runners, and cloud VMs without nested virtualization), macOS without HVF (in VMs, and in sandboxes without the entitlement), Windows arm64 without WHP, and any x86-64 host running an arm64 root. [zig-interpreter](0019-zig-interpreter.md) lists what it costs: GPLv2, so it ships only as `h9-emu`; prebuilt only for three targets; three workarounds; 1.3 MiB and 0.3 ms per engine; and a JIT, so no iOS or wasm.

Since then the [linux-personality](0018-linux-personality.md) and [linux-threads](0049-linux-threads.md) work has added two more:

- **Guest threads are serialized.** Unicorn generates code for a single-threaded context, so atomics become plain loads and stores. `emu.zig` runs guest code on one engine at a time, under a ticket lock that's time-sliced every 1 ms (SPEC.md, "Atomics"). A Go, Python, or PostgreSQL program with four busy threads gets one core.
- **Compute now matters.** 0019's rationale held that most of what h9 runs is bound by syscalls. Linux programs changed that: CPython, SQLite, git, ffmpeg, Zig, and Go all ran under the personality in the project's spikes, and they spend their time in compute and memory.

Unicorn's speed is the bar: a 2-instruction loop of 10⁹ iterations runs in 1.4 s on an M3 Max (about 1.5 G instructions/s), 5× slower than HVF, and a syscall round trip costs about 0.8 µs (SPEC.md, "Limits and selection").

### The interpreter

[zig-interpreter](0019-zig-interpreter.md) is a draft for a predecoded interpreter covering what 9front's compilers emit. Its spike (Updates, 2026-11-06) ran 300–500 M instructions/s, took 2.6× Unicorn's time on the bench loop and 0.37–1.9× on calls, qsort, md5, and FP, and exited and re-entered for a syscall in 13 ns against Unicorn's 381 ns. It matched Unicorn's registers over 2.9 M traced instructions, and four host threads doing LDXR/STXR increments lost nothing, so it needs no guest lock.

What it doesn't cover is Linux. h9 tells Linux programs they have FP and Advanced SIMD (`src/linux/exec.zig`, `hwcap`), and musl's and glibc's string functions, CPython, and especially ffmpeg use AdvSIMD heavily. So the interpreter's scope has to grow to all of Armv8.0's EL0 instructions whatever happens here. Its speed is also the floor of what's acceptable only for 9front's syscall-heavy tools.

### The references

**v86** (BSD-2) is an x86 PC emulator whose JIT compiles guest code to wasm, which the browser's own JIT then compiles to machine code. h9's browser host already runs it ([browser-host](0012-browser-host.md)). Its design points that carry over:

- Code is compiled per 4 KiB physical page, after a page's hotness counter crosses a threshold, into one wasm module holding the page's basic blocks. Inside it, a loop over a `br_table` on a block index jumps between blocks without returning to the host.
- Until then, and for anything it doesn't compile, the interpreter runs.
- A write to a page with compiled code (`jit_dirty_cache`) drops that page's code, so self-modifying code is safe.
- Guest registers live in linear memory; the wasm engine keeps them in machine registers within a function.

**rv64.js** (MIT) is a RISC-V RV64 emulator in Rust whose JIT, `rv64-dbt`, compiles RV64 to wasm. It's the closer reference: a 64-bit RISC ISA, a clean-room typed-SSA IR, and both a user-mode and a full-system run loop. Its design and its long performance ledger (`DESIGN.md`, `PERFORMANCE_PROGRESS.md`, `docs/jit-rewrite/`) give the lessons this proposal takes:

- **The interpreter is tier 0 and the oracle** (its decision D003). The JIT never needs a second semantics for uncommon instructions, and every compiled region is differentially tested against the interpreter.
- **The unit is a bounded multi-block region, not an instruction or a basic block** (D004, D011). Forward traces follow fallthrough and direct jumps with guarded side exits, and single-latch loops compile to real loops.
- **Guest exceptions never use host traps** (D008). Every operation whose host behaviour differs, such as an out-of-bounds access or a division by zero, is guarded before it executes, and a guard's exit commits exact architectural state.
- **Exact FP first, native FP with a proof** (D012). Host FP is used only where guards prove the result and flags can't differ.
- **Dispatcher crossings dominate.** Its rewrite emitted smaller code than its predecessor but crossed the runtime dispatcher 1.77× as often on mixed code, and lost by 1.4× there. Linking compiled code directly to compiled code matters more than instruction lowering.
- **Lean code for the host's first tier.** Its ALU loop ran 2× slower than its predecessor's in V8's baseline compiler, because it gave every SSA value its own local. The emitted code must be good without the host optimizing it.

Its numbers set the speed class. On Node 26 and V8 on x86-64 (`docs/jit-rewrite/COMPARISON.md`), a user-mode ALU loop retired 8.0 G instructions in about 1.8–2.0 s once V8's optimizing tier took over (about 4 G instructions/s), and mixed integer and memory code retired 1.64 G instructions in 2.2–3.1 s (0.5–0.75 G instructions/s). Against v86 on a matched Alpine scorecard it was at parity or better on 11 of 13 rows, losing on boot and on a compiler workload. That's from inside wasm: a native emitter, with no wasm engine in between, should do at least as well.

Neither is a source for code here. rv64.js is Rust and RISC-V, v86 is Rust, C, and x86, and both are full systems. What's taken is the structure and the measured lessons.

## Proposal

### Scope

- **All of A64 at EL0 that `hwcap` advertises:** Armv8.0's integer, branch, load and store, exclusive, FP, and Advanced SIMD instructions, plus the EL0 system instructions [zig-interpreter](0019-zig-interpreter.md) lists. That's the definition of "full arm64" here, and it's what Linux programs may use without asking.
- **Optional extensions behind their HWCAP bits,** each advertised only once both tiers implement it and pass the tests: LSE atomics (`HWCAP_ATOMICS`), CRC32, AES, SHA1, SHA2, and PMULL, which many libraries pick at run time when present. Without the bit a program doesn't use them, so they can come later and one at a time.
- **No full system.** No EL1, no MMU or page-table walks, no exceptions taken to a guest kernel, no interrupts, no devices, no AArch32, and no SVE or SME. An SVC, a fault, a BRK, or an undefined instruction is a vmm exit, as on every backend.
- **arm64 guests only.** amd64 and 386 guests stay on Unicorn (`h9-emu`) and v86 here. [x86-jit](x86-jit.md) is drafting a 386 front end on the same shared layer, and an amd64 one would be its own proposal.

### Tiers

| Tier | What | Where |
| --- | --- | --- |
| T0 | The interpreter of [zig-interpreter](0019-zig-interpreter.md), with its scope grown to the Scope above | Everywhere. The only tier on iOS and other hosts that forbid generated code. |
| T1 | This JIT: regions lowered through the IR to host code | arm64 and x86-64 hosts, and wasm once the browser host adopts it |

T0 runs code until T1 has it, runs any instruction T1 doesn't lower (as a helper call from inside compiled code, below), and is the reference every compiled region is tested against. A hardened or iOS build has only T0. A threaded-code tier between the two, for iOS, is in Open issues.

### Layout

The JIT is split into a layer shared by any guest architecture and an arm64 front end, so a 386 or amd64 front end can sit on the same IR, emitters, and code cache ([x86-jit](x86-jit.md) is drafting the 386 one).

| File | Role |
| --- | --- |
| `src/interp/a64/` | T0, as [zig-interpreter](0019-zig-interpreter.md) lays it out: `decode.zig` (now also giving each instruction's register read and write sets), `exec.zig`, `fp.zig`, and a new `simd.zig` for AdvSIMD |
| `src/interp/mem.zig` | The software TLB and the slow path, shared by T0 and T1 |
| `src/jit/ir.zig` | The IR: a region of blocks of typed values |
| `src/jit/opt.zig` | The few passes: flag liveness, constant folding, dead guest-register writes, redundant TLB checks |
| `src/jit/regalloc.zig` | Linear-scan allocation of guest registers and temporaries to host registers |
| `src/jit/emit/arm64.zig` | IR to arm64 |
| `src/jit/emit/x64.zig` | IR to x86-64 |
| `src/jit/emit/wasm.zig` | IR to wasm |
| `src/jit/cache.zig` | The code cache: lookup, chaining, the jump cache, invalidation, and flushing |
| `src/jit/codemem.zig` | Executable memory per host: W^X, dual mapping, and icache maintenance |
| `src/jit/a64/lift.zig` | Decoded arm64 instruction to IR, one function per instruction class |
| `src/jit/a64/flags.zig` | NZCV's lazy forms and their lowering on each host |
| `src/jit/a64/copy.zig` | The arm64 host's verbatim copying of register-only instructions (below) |
| `src/vmm/a64.zig` | The vmm backend: Backend, AddressSpace, and Vcpu over both tiers |

As in 0019, `src/interp/` and `src/jit/` depend on no OS service except through `codemem.zig`, which the backend passes in. A T0-only build doesn't compile `src/jit/`. The guest-specific parts are decode, lifting, flags, FP semantics, and T0; the rest is shared, and its interfaces (the IR, the exit and kick protocol, and the TLB entry) are the contract between this proposal and other front ends.

### The IR

A region is a list of blocks; a block is a straight list of instructions over typed SSA values (`i32`, `i64`, `v128`, and `flags`), ending in a terminator. The operation set is small, on purpose: an emitter is a few thousand lines, not QEMU's TCG.

- **Guest state:** `getreg`, `setreg` (Xn, SP, Vn, NZCV, FPCR, FPSR, TPIDR\_EL0), each a known slot of the `Cpu` struct.
- **Integer:** add, sub, and, or, xor, andn, shifts, rotate, extend, extract, mul, mulh, udiv and sdiv with arm64's division-by-zero and overflow results built in, clz, rbit, rev, select, and compare.
- **Flags:** `nzcv.add`, `nzcv.sub`, `nzcv.logic` (lazy forms, below), `cond` (a condition code over a flags value to an `i1`), and `nzcv.pack`.
- **Memory:** `load` and `store` with a size, sign extension, an alignment requirement, an ordering (plain, acquire, release), and the guest PC to report on a fault; `ldxr`, `stxr`, `clrex`, `cas`, and `rmw` (for LSE); `fence`.
- **Vector:** lane-wise add, sub, mul, logic, shifts, compare, min and max, `dup`, `ins`, `ext`, `zip`, `uzp`, `trn`, `tbl`, narrow and widen, and 128-bit loads and stores. These are what compiled code from musl, glibc, CPython, and ffmpeg spends its SIMD time in. Anything else is a helper.
- **FP:** add, sub, mul, div, sqrt, fma, min, max, compare, convert, and round, each with a flag that says the emitter may use host FP (below).
- **Helpers:** `call.interp(word, pc)` runs T0's handler for one instruction on the `Cpu` struct, after the allocator has written back the registers the instruction reads and before it reloads those it writes. `call.helper` runs a named Zig function, such as an FP routine.
- **Terminators:** `br` and `brcond` within the region, `exit.chain` to a guest PC outside it, `exit.indirect` to a guest PC in a value, and `exit.svc`, `exit.fault`, and `exit.brk`.

`call.interp` is what makes "all of A64" reachable from the first day: an instruction class with no lifting yet becomes a helper call, the region around it stays compiled, and lifting a class later is purely a speedup. The inventory tool ([zig-interpreter](0019-zig-interpreter.md), Inventory), run over Linux binaries as well as the root tree, ranks which classes to lift by how often they occur.

### Regions

- **Discovery.** A region starts at a guest PC the dispatcher was asked for. Lifting follows fallthrough, unconditional direct branches, and calls (`BL` continues at its target, as a trace), and the fallthrough of a conditional branch, whose taken side becomes a side exit. It stops at an indirect branch, an SVC, an exit, two guest pages, or 512 instructions, whichever comes first. Those limits are rv64.js's measured defaults and are a starting point.
- **Loops.** A conditional branch backwards to the region's own start, or to a block already in it, becomes a real loop in the host code, with the exit-request check (below) on its back edge. Guest registers stay in host registers around it, and every side exit writes back the dirty ones (rv64.js's D009).
- **When to compile.** Natively, a region is compiled the first time its start is dispatched, as QEMU does: lifting and emitting cost microseconds, and h9's short-lived processes would spend too long in T0 otherwise. A per-entry counter can raise the threshold if measurements say compile time hurts startup. In wasm, where compiling a module is slow and asynchronous, a region is compiled once its entry is hot and T0 runs it meanwhile, as v86 and rv64.js do.

### Guest state and registers

The `Cpu` struct is 0019's, unchanged: 31 X registers, SP, PC, NZCV, 32 V registers, FPCR, FPSR, TPIDR\_EL0, the exclusive monitor, and `retired`. Compiled code receives a pointer to it in a fixed host register, along with the vCPU's TLB.

Within a region, guest registers are allocated to host registers by linear scan over the region's IR: loaded at first use, kept while live, and written back at exits and before helpers only if dirty. On an arm64 host that leaves about 24 host registers for guest values, and most regions use fewer. On x86-64 there are 12, so more is spilled, which is the main reason that emitter is expected to be the slower of the two.

### Flags

NZCV is computed lazily. A flag-setting operation produces a `flags` value naming its operation and operands. `src/jit/opt.zig` drops the ones nothing reads before they're overwritten, which is most of them, and `cond` on a live one becomes a host compare and branch.

- **arm64 hosts** use the host's NZCV directly: `SUBS` lowers to `SUBS`, and `B.cond` to `B.cond`. Flags are packed into the `Cpu` only at exits and around helpers.
- **x86-64 hosts** map N, Z, and V to SF, ZF, and OF, and C to CF inverted for subtraction (arm64's carry is "no borrow"). `cmp` and `jcc` fuse as they do on arm64. A flags value read after a helper or across a region exit is packed with `setcc` once.
- **wasm** computes only the conditions read, as integer compares.

### Memory

Every guest access goes through a direct-mapped software TLB per vCPU: 256 entries for reads and 256 for writes, each holding a guest page tag and the difference between the guest address and the host address. The inline fast path is a shift, a mask, a load of the tag and difference, a compare, and the access at `guest + difference`: about six instructions on either native host. The tag compare also folds in an alignment check and a page-crossing check, so an access that crosses a page or needs alignment it doesn't have takes the slow path.

The slow path is a call into `src/interp/mem.zig`, shared with T0: it finds the region in the address space, checks permissions, fills the TLB entry, and does the access, or returns a fault. Each slow-path site is a stub out of line that knows the guest PC of its instruction and which allocated registers are dirty, so a fault exits with exact architectural state and the PC at the faulting instruction.

There's no use of host faults for guest exceptions: no guard pages, no signal handlers, no reliance on the host to trap on an out-of-range address. The same inline check works on every host and in wasm, and every access is bounds-checked against host memory the address space owns, as 0019 requires.

A page holding compiled code is never given a write TLB entry. A guest store to it takes the slow path, which drops the translations from that page (below) and, if the running region came from that page, ends the region after the store. That makes self-modifying and run-time generated guest code safe without `IC IVAU`, which stays a no-op. Plan 9 programs never write their text. Linux JITs, such as LuaJIT, or a program that `mprotect`s a page writable and executable, do.

### Control flow and exits

- **Chaining.** `exit.chain` to a PC whose region exists jumps straight into it. At first it calls the dispatcher, which compiles or finds the target and patches the jump, as QEMU's `goto_tb` does. A patched jump is undone when its target is dropped.
- **Indirect branches** (`BR`, `BLR`, and `RET`) look up the target in a per-vCPU direct-mapped jump cache of 1024 entries inline, and call the dispatcher only on a miss.
- **The exit request.** `kick` sets a per-vCPU flag. Compiled code tests it at each region entry and each loop back edge: a load and a conditional branch, which the spike measured at about 6% in the interpreter and should cost less here. A spinning guest sees a kick within one loop iteration, and `run` checks the flag before it enters, so no kick is lost and none needs repeating.
- **SVC** exits with `.syscall`, the PC past the instruction, and `Ureg.type` set to `EC_SVC64 << 26`, as the emulator does today. A fault exits with `.fault` and the syndrome HVF would give, BRK with `.breakpoint`, and an undefined encoding with EC 0. An EL0 `MRS` of an ID register is undefined at T0 and T1 alike, so the Linux layer's `emulateIdRead` sees the same fault it sees on HVF.
- **A syscall round trip** leaves compiled code with a return to `run`, so it costs what the interpreter's did, tens of nanoseconds, against Unicorn's 381 ns.

### Concurrency

Every vCPU runs compiled code at once on the host CPUs. The backend has no guest lock.

- **Plain accesses** of up to 8 bytes, naturally aligned, are single-copy atomic, as on arm64. A host load or store of the same size gives that on both native hosts.
- **Exclusives** work as in 0019: `LDXR` records the address, size, and value; `STXR` is a compare-and-swap against that value, and succeeds only if it matches. Pairs (`LDXP`/`STXP`) use a 128-bit compare-and-swap (`CASP` on arm64, `cmpxchg16b` on x86-64).
- **LSE atomics** map to `LDADD`, `SWP`, and `CAS` on an arm64 host that has them, and to `lock xadd`, `xchg`, and `lock cmpxchg` on x86-64. An arm64 host without LSE uses an exclusive loop.
- **Ordering.** arm64 hosts have the guest's memory model, so barriers and acquire and release accesses map one to one. x86-64 is TSO, stronger than arm64 everywhere but store-to-load, so only `DMB` and `DSB` of loads after stores need an `mfence`, and acquire and release accesses need nothing.
- **Shootdown.** `AddressSpace.shootdown` kicks every vCPU running the space and waits until each has left compiled code and seen the change, which flushes its TLB and jump cache, as the hypervisor backends' runners do (`src/vmm/gphys.zig`). Only then may the host reuse the pages.

### The code cache

- **One cache per backend,** of executable memory reserved at start (64 MiB, shared by every vCPU), filled by a bump pointer.
- **Translations are keyed by guest PC and the arena offset of the guest page,** so two address spaces with the same text at the same address share them, as Plan 9 processes forked from one another do. A lookup checks both, and an address space whose mappings changed can't hit a stale one.
- **Invalidation.** Unmapping or changing an executable mapping, `codeChanged`, and a guest store to a code page drop the translations from that page: they're unlinked from the lookup table, jumps patched into them are reset, and their space is reclaimed at the next flush.
- **Flushing.** When the cache is full, every vCPU is asked to leave compiled code, by the same kick and wait as a shootdown, and the cache is emptied at once. QEMU does the same.

### FP and SIMD

The semantics are 0019's: results are the same bits on every host, with ARM's NaN rules, default NaN, FPCR's rounding mode, FZ, and DN, and FPSR's cumulative flags.

- **On arm64 hosts,** that's what the hardware does. Compiled code loads the guest's FPCR into the host's at region entry, if it differs from the host's, and reads FPSR back at exits. Every FP and AdvSIMD instruction then runs as itself.
- **On x86-64 hosts,** SSE gives the same results for add, sub, mul, div, sqrt, conversion, and FMA (with FMA3) in round-to-nearest with no NaN operands. The emitter uses SSE and checks the result: if it's a NaN, or if FZ or a directed rounding mode is set, a helper recomputes it in software. Cumulative flags come from MXCSR's sticky bits, mapped to FPSR when FPSR is read. Lane-wise integer SIMD maps to SSE2 through SSE4.1 for the IR's vector operations, and everything else in AdvSIMD is `call.interp`.
- **In wasm,** FP goes through helpers unless a guard proves the native result exact, as rv64.js's D012 does, since wasm's NaN bits aren't deterministic. Vector operations map to wasm's SIMD where it's available.

### arm64 hosts: copying instructions

When the host is arm64 too, most guest instructions don't need lowering at all. An instruction that touches only registers (integer, FP, and AdvSIMD data processing, which is most of the instruction stream) runs correctly on the host if its register fields name the host registers the allocator gave those guest registers. So `src/jit/a64/copy.zig` has the arm64 emitter copy such an instruction verbatim with its register fields rewritten. Guest V registers are pinned to the same-numbered host V registers inside compiled code, so AdvSIMD instructions need no rewriting at all.

Only five classes need real translation: loads and stores (the TLB), branches (exits and chaining), PC-relative instructions (`ADR`, `ADRP`, and `LDR` literal, whose PC is the guest's), exclusives and atomics (the monitor), and system instructions (SVC, MRS, MSR, barriers, and cache maintenance). That's what makes full AdvSIMD cheap on arm64 hosts: the long tail of SIMD instructions costs nothing per instruction, and bit-exact FP comes from the hardware.

On arm64 hosts the IR is still built, since allocation, flags, and exits need it, but a copyable instruction appears in it as one opaque `native` operation with its read and write sets. The other emitters lower the same operation through `lift.zig`, or `call.interp`.

### Executable memory

`codemem.zig` hands out code and makes it executable, per host:

- **macOS:** `MAP_JIT` memory, written with `pthread_jit_write_protect_np` switched off on the writing thread only, and `sys_icache_invalidate`. Hardened-runtime builds need the `com.apple.security.cs.allow-jit` entitlement, as Unicorn does.
- **Linux:** a `memfd` mapped twice, writable and executable, at different addresses, so no page is ever both. arm64 needs the cache maintenance `emu.zig`'s `clearCache` does today, including its `dsb ish`.
- **Windows:** a section mapped twice with `MapViewOfFile3`, writable and executable, and `FlushInstructionCache`.
- **wasm:** a module per batch of regions, compiled by the embedder through an import, added to a shared function table, and called through it, as rv64.js and v86 do.
- **iOS and other hosts without a way to make code executable:** none. The backend runs T0 only.

### Build and selection

- `-Demu=zig` from [zig-interpreter](0019-zig-interpreter.md) builds both tiers. `-Demu=zig -Dno-jit` builds T0 alone, which is also what an iOS target gets.
- At run time the backend uses T1 when `codemem.zig` can map executable memory, and otherwise T0 alone with no warning, since the result is the same.
- A test-only `a64.Options.tier` forces `t0` or `t1`, so the backend tests and the integration suite run on each.
- `vmm.Kind` keeps one `emu`. `--backend emu`, the `auto` fallback, `H9_TEST_BACKENDS=emu`, and the CLI are unchanged. `emuVersion`, `--version`, and `--check` report `zig (jit)` or `zig (interpreter)`.
- `-Demu=unicorn` stays for `h9-emu`, for amd64 and 386 guests and as the lockstep reference.

### Deterministic mode

0019's deterministic mode derives `CNTVCT_EL0` from `retired`. Compiled code counts `retired` per region exit, from the number of instructions the region ran to that exit, and side exits know their counts statically. The exit request is checked only at syscalls in this mode, so the instruction stream is the same with T0 and T1.

### Testing

- **T1 against T0, by region.** A test-only check mode runs each compiled region on a copy of the `Cpu` and of the pages it touches, runs T0 over the same instructions from the same state, and compares registers, flags, FPSR, the memory written, and the exit. Under it, `zig build integration` checks every region the suite compiles. rv64.js's interpreter-versus-JIT differentials are the model.
- **The host as oracle on arm64.** On an arm64 host, T0's semantics for each register-only instruction can be checked against the hardware itself, by running the instruction natively in a stub with random register contents. That covers AdvSIMD and FP, where T0 has the most code and Unicorn lockstep is slowest.
- **Unicorn lockstep,** from 0019, for everything else and on x86-64 hosts.
- **Fuzzing.** `zig build fuzz-a64` from 0019 grows a region mode: random sequences of valid instructions, biased toward the inventory's classes, run on T1 and T0 and compared, in an address space with unmapped and read-only pages around the data.
- **Backends and integration.** `tests/backends.zig` and every `[baseline]` and `[linux-personality]` case, on T0 and T1, and with `H9_TEST_BACKENDS=hvf,emu` on macOS so the syscall traces match HVF's.

### Speed targets

Measured with `zig build bench`, extended with 0019's spike bench programs (fib, sieve, md5, qsort, and an FP loop) and three Linux workloads: CPython running a pure-Python benchmark, SQLite's speedtest1, and `git status` on a large tree.

| Measure | Target |
| --- | --- |
| Bench loop, arm64 host | At most Unicorn's 1.4 s on an M3 Max; 0.5 s (2× HVF) is the aim |
| Bench loop, x86-64 host | At most Unicorn's time on the same host |
| Mixed compute (the spike programs and the Linux workloads) | At least 1 G guest instructions/s on an M3 Max, and faster than Unicorn on each |
| Threads | Four busy guest threads on four host cores at least 3× faster than one, where Unicorn gets 1× |
| Syscall round trip | Under 100 ns for a bare exit and re-entry, against Unicorn's 350 ns |
| Startup | The integration suite takes no longer on T1 than on Unicorn |
| wasm, when it lands | rv64.js's class on V8: 0.5 G instructions/s or more on mixed code |

These aren't gates; correctness is. They go in SPEC.md's Limits and selection next to Unicorn's and HVF's.

## Rationale

**Why a JIT now, when 0019 chose an interpreter.** 0019 argued that a JIT's cost (executable memory, W^X, icache maintenance, and no wasm or iOS) wasn't worth it when the emulator mostly ran syscall-bound 9front tools. Two things changed. The Linux personality made the emulator run compute-heavy programs that need all of AdvSIMD, where an interpreter is 5–20× slower than a JIT. And replacing Unicorn for arm64 means matching it on speed, which an interpreter can't. The interpreter is still built, and still first: this proposal makes it the base of the JIT, not an alternative to it.

**Why a region IR, and not a template JIT.** A template JIT that copies one machine-code template per guest instruction is simpler, but keeps every guest register and flag in memory between instructions. That's what made rv64.js's predecessor fast to compile and its later rewrite faster to run on mixed code. Allocation across a region, lazy flags, and chained exits are where the speed is, and they need an IR. The IR here is kept to what those three need: no general optimizer, no instruction scheduling, and no global value numbering.

**Why our own, and not an existing JIT.**

- **QEMU's TCG** is GPLv2, which is the problem being solved.
- **Dynarmic** (0BSD) is an A64 JIT in C++. It's a C++ dependency with its own build, its own allocator and memory model, x86-64 and arm64 hosts only, and no wasm.
- **LLVM ORC** and **Cranelift** generate excellent code, but compile in milliseconds per region, are tens of megabytes of dependency (and Cranelift is Rust), and don't fit wasm.
- **rv64.js's `rv64-dbt`** is MIT, but Rust and RISC-V, and emits only wasm. Its structure is what's taken.

**Why arm64 hosts first.** They're where Unicorn is most needed (Linux arm64 without KVM, and Macs without HVF), and verbatim copying makes them the shortest path to full AdvSIMD at full speed. x86-64 hosts follow with the same IR, needing lowering for what arm64 hosts copy.

**Why regions and not pages, natively.** v86 compiles per page because instantiating a wasm module is expensive, so it batches. Native code has no such cost, so a region follows the control flow, as QEMU's blocks and rv64.js's traces do. The wasm emitter will batch regions into modules for the same reason v86 does.

**Why a software TLB, not host page protection.** Mapping each address space into a reserved host range, so a guest access is one host access and faults come from host signals (Dynarmic's and Ryujinx's "fastmem"), is faster per access. But it needs a host mapping per guest mapping, signal or exception handlers on every host, and a 256 TiB reservation per address space, and it can't work in wasm. The inline TLB check is about six instructions, works everywhere, and keeps all bounds checks in code we control. Fastmem stays an open issue for arm64 hosts.

**Why compile on first run natively.** h9 runs many short processes, and a threshold would leave them in T0. Lifting and emitting a region should take microseconds; if measurements say otherwise, the counter is already there.

**Why parallel threads are safe now.** Unicorn serializes because TCG's single-threaded code turns atomics into plain accesses. Here exclusives, LSE, and barriers are lowered to host atomics and fences by construction, the approach QEMU takes in its multi-threaded mode and 0019's spike tested with four threads.

**Why interpreter helpers instead of complete lowering.** Lowering every AdvSIMD and FP instruction for x86-64 and wasm is thousands of cases, most of which are rare. A helper per instruction keeps one semantics for the rare ones, in T0, where it's tested against Unicorn and the hardware. The inventory says which to lower next.

## Compatibility

- **CLI and exit codes.** Unchanged. `--version` and `--check` name the tier.
- **`Machine.Options` and the vmm interface.** Unchanged. The backend implements Backend, AddressSpace, and Vcpu as `emu.zig` does, with `codeChanged` dropping translations and `shootdown` waiting on vCPUs.
- **Guests.** Linux programs see the same HWCAPs as today until an extension is implemented in both tiers; then its bit is set on the emulator. If HVF, KVM, or WHP advertise fewer, the bits are per backend, through `vmm.Backend.hwcaps`.
- **zig-interpreter.** This proposal depends on it, and asks it to grow its scope from the 9front subset to all of Armv8.0's EL0 instructions, including AdvSIMD, and to give each decoded instruction its register read and write sets. That's an update to a draft, made in its own PR.
- **Build.** `-Dno-jit` is new. `-Demu=zig` grows. `-Demu=unicorn` is unchanged.
- **Releases.** The MIT `h9` gains the JIT once 0019's default switch lands. `h9-emu` stays for amd64 and 386 guests.
- **Root tree and `third_party/`.** Unchanged.

## Security

**What changes.** On the emulator, the isolation boundary is software, as with Unicorn today. With a JIT, guest-controlled input decides what host machine code is generated, so a bug in lifting, allocation, or emitting can produce host code that does something the guest's instructions couldn't. That's the same class of risk QEMU's TCG carries now, in less code.

**How it's contained.**

- **Every guest access goes through the TLB check,** in generated code and in T0, against host memory the address space owns. No generated code computes a host address from guest data except as `guest + difference` after a tag match.
- **No host addresses reach the guest,** and no guest value is used as a host pointer, table index, or jump target. Indirect branches go through the jump cache's tag check or the dispatcher.
- **W^X everywhere.** No page is writable and executable at once on any host; on Linux and Windows the two views are separate mappings.
- **No host faults for guest behaviour.** A host fault inside generated code is a bug, and panics the machine rather than being turned into a guest fault.
- **Immediates.** A guest controls the immediates copied into generated code, which could plant byte sequences that decode as useful host instructions if a host jump ever landed mid-instruction (JIT spraying). The jump targets in generated code are fixed by the emitter, never computed from guest data, so this needs another bug to exploit. Whether to also blind large immediates is an open issue.
- **The checks of 0019 apply,** with the fuzzer's region mode and the T1-versus-T0 check run in CI.

The sandbox policy is unaffected: it's enforced in the kernel, above the vmm layer, the same on every backend.

## Done when

- `zig build integration -Demu=zig` with `H9_TEST_BACKENDS=emu` passes every `[baseline]` and `[linux-personality]` case on T1 on macOS arm64, Linux arm64, Linux x86\_64, and Windows x86\_64, and on T0 on at least Linux x86\_64.
- On macOS arm64, `H9_TEST_BACKENDS=hvf,emu` passes on T1, so its syscall traces match HVF's.
- The integration suite passes under the T1-versus-T0 check mode with no divergence.
- `zig build test -Demu=zig` passes `tests/backends.zig` on T0 and T1.
- New cases in `tests/a64.zig`, tagged `[a64-jit]`:
  - `test "a store to a page with compiled code takes effect before its next instruction [a64-jit]"`
  - `test "a fault in a compiled region reports the faulting PC and registers [a64-jit]"`
  - `test "a kick stops a compiled loop with no syscalls [a64-jit]"`
  - `test "four threads incrementing with LDXR and STXR lose nothing [a64-jit]"`
  - `test "four threads incrementing with LDADD lose nothing [a64-jit]"`
  - `test "unmapping a page another vCPU has cached makes its next access fault [a64-jit]"`
  - `test "a full code cache flushes while other vCPUs run [a64-jit]"`
  - `test "FP results are the same bits on T0, T1, and HVF [a64-jit]"`
  - `test "deterministic mode gives the same instruction count on T0 and T1 [a64-jit]"`
- `zig build fuzz-a64` in region mode runs for an hour on arm64 and x86-64 hosts with no divergence.
- `zig build bench -Demu=zig` reports the targets in Speed targets on an M3 Max and on an x86-64 Linux host, and SPEC.md gives them.
- Demo, on a Linux arm64 host without KVM: `h9 --backend emu --linux alpine python3 -c 'print(sum(range(10**7)))'`, faster than with `h9-emu`.

## Implementation

1. **T0 grows** (zig-interpreter's own steps, with its scope widened): the decode table with read and write sets, the full integer, FP, and AdvSIMD semantics, and the inventory over the root tree and an Alpine arm64 root. That inventory decides the lifting order.
2. **IR, lifting, and the arm64 emitter,** with every instruction class either lifted or copied verbatim, and anything else `call.interp`. TLB, exits, and the exit request. Regions without loops or chaining. T1-versus-T0 check mode from the start.
3. **The backend** (`src/vmm/a64.zig`), with the guest lock gone, the shootdown and flush, and `codemem.zig` for macOS and Linux. `tests/backends.zig` and the `[baseline]` cases pass on arm64 hosts.
4. **Speed on arm64 hosts:** loops, chaining, the jump cache, flag liveness, and allocation across regions. Bench against Unicorn and record it in this proposal's Updates.
5. **The x86-64 emitter** and Windows `codemem.zig`, with SSE lowering for the vector operations the inventory ranks highest.
6. **Linux workloads and extensions:** the `[linux-personality]` cases, the three Linux benchmarks, and LSE, CRC32, AES, SHA, and PMULL with their HWCAP bits, each in both tiers.
7. **Switch the default** where zig-interpreter does, update SPEC.md's emulator section (the JIT, its tiers, its memory, and its atomics, with Unicorn as the reference and the amd64 emulator), and set `status: implemented`.

The wasm emitter is designed for here but built by [x86-jit](x86-jit.md), whose 386 guests are what the browser host runs today. Running arm64 roots in the browser is then a change to [browser-host](0012-browser-host.md), in a proposal of its own.

## Open issues

- **A threaded-code tier for iOS.** Without generated code, iOS gets T0. A TCTI-style tier (UTM SE's QEMU backend, and iSH's "Asbestos") would emit, from the same IR, a list of addresses of handlers compiled into the app, specialized by register and chained directly, keeping the IR's allocation and lazy flags. It's an emitter like the others and could plausibly reach 2–3× T0, but is unmeasured. It belongs with an iOS proposal.
- **The wasm emitter,** which [x86-jit](x86-jit.md) builds first. rv64.js shows the shape: batches of regions per module, a `br_table` dispatch loop inside it, a shared function table with tail calls between modules, asynchronous compilation, and code kept lean for the engine's baseline tier. What this proposal needs from it is only that arm64 regions lower to it too.
- **Fastmem on arm64 hosts.** One host load per guest load, with host faults for guest faults, could be worth 20–40% on memory-heavy code. It conflicts with "no host faults" and needs per-host signal handling, so it would be measured as an option, not the default.
- **Sharing translations across processes.** Translations are keyed by the guest page's arena offset, so a new process running the same binary, with its text freshly loaded into new pages, compiles it again. Keying text pages by file and offset, or by content, would let an rc pipeline's tenth `grep` reuse the first one's code. A persistent cache across runs is a further step.
- **Blinding immediates** against JIT spraying, and what it costs.
- **Return prediction.** A return-address stack per vCPU could turn most `RET`s into direct jumps instead of jump-cache lookups. Whether it's worth it depends on the jump cache's hit rate, measured in step 4.
- **Retiring Unicorn.** With this done, `h9-emu` is needed only for amd64 and 386 guests on hosts without hardware for them. [x86-jit](x86-jit.md) covers 386, and an amd64 front end on the same layer would retire Unicorn entirely, as its own proposal.
