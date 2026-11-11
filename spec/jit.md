# The emulator's CPUs: the shared layer

This describes, as built on the `vcpu` branch, what h9's own CPUs share: the emulator backend they run under (`zemu`), their two tiers, the software TLB, and the JIT layer under `src/jit/`. [h86](h86.md) is the 386 CPU, [hx64](hx64.md) the amd64 one (h86 in long mode), and [ha64](ha64.md) the arm64 one; each of those specs covers what's particular to its architecture. [SPEC.md](../SPEC.md) describes h9 as a whole, and the [hcpu](../design/hcpu.md) proposal says why the CPUs exist and how they replace Unicorn and v86. [src/jit/README.md](../src/jit/README.md) has the rules every front end and emitter codes against.

## Contents

- [Overview](#overview)
- [The emulator backend (`zemu`)](#the-emulator-backend-zemu)
- [Tiers](#tiers)
- [Guest memory and the TLB](#guest-memory-and-the-tlb)
- [The IR](#the-ir)
- [Emitters](#emitters)
- [The code cache](#the-code-cache)
- [Concurrency](#concurrency)
- [The web host](#the-web-host)
- [Build and selection](#build-and-selection)
- [Testing](#testing)
- [Layout](#layout)

## Overview

`-Demu=zig` builds the emulator backend on h9's own CPUs instead of Unicorn: ha64 for arm64 binaries, h86 for 386 binaries, and hx64 for amd64 binaries, picked by the binary's architecture when the backend is created. The web build has the same three CPUs, with T1 on wasm for all of them.

Both CPUs are user mode only. There's no guest kernel, MMU, interrupt delivery, or devices: a system call, a fault, a breakpoint, or an undefined instruction ends `run` with a vmm exit, as the shim does on a hypervisor, and the Ureg's trap fields are what the real kernel would put there.

Each CPU has two tiers. T0 is an interpreter. T1 is a JIT that lifts regions of guest code to a small IR and emits host code from it, on arm64, x86-64, or wasm. T1 sends anything it doesn't lift through T0, one instruction at a time, so T0 is the definition of what each instruction does.

## The emulator backend (`zemu`)

`src/vmm/zemu.zig` implements the vmm Backend, AddressSpace, and Vcpu over two Guests, `src/vmm/ha64.zig` and `src/vmm/h86.zig`. A Guest is the architecture-specific part: its register file, Ureg and Extra conversions, and its `run`. Everything else is shared.

**Memory.** Guest pages come from one arena (`src/vmm/arena.zig`), as Unicorn's do: natively a reserved range of twice the memory cap in address space, whose pages stay unbacked until touched, and on the web real memory grown with `memory.grow`, 256 MiB by default and 2 GiB at most. An address space is a list of regions of the arena. `freePages` drops whatever was decoded or compiled from the pages it frees, so new contents never run stale code.

**Views.** Each vCPU keeps its own copy of its address space's mappings, a `mem.View`, which it brings up to date before it runs guest code whenever the space's generation has moved. The TLB is filled from the View.

**No guest lock.** Every vCPU runs guest code at once. Other threads reach a running vCPU only through its context's exit-request word, which T1 checks at every `poll` and T0 at every block:

- A kick sets `req_kick`, and `run` returns `.interrupted`.
- A shootdown or a code-cache flush sets `req_sync`. The vCPU leaves guest code, catches up with its address space, and carries on without returning.

**Kick and wait.** A vCPU's `seq` is odd while it's in guest code. It makes `seq` odd before it looks at its space's generation, and a shootdown bumps the generation before it looks at `seq`, so either the vCPU sees the change or the shootdown sees the vCPU and waits until its `seq` moves. `AddressSpace.shootdown` waits for every vCPU running the space; a cache flush waits for every vCPU of the backend.

**Limits.** `maxVcpus` is 64, in line with HVF's; there's no hardware limit.

**Exits.** A Guest's `run` returns `.syscall` with the PC past the instruction, `.breakpoint`, `.fault` with the address, the access, and a syndrome (arm64's ESR, or the 386 vector), or `.interrupted`.

## Tiers

| Tier | What | Where |
| --- | --- | --- |
| T0 | An interpreter over decoded instructions, cached per guest page | Everywhere; the only tier where code can't be generated |
| T1 | Regions lifted to the IR and emitted as host code | arm64 and x86-64 hosts, and wasm on the web host |

T1 is the default wherever it can run. `H9_EMU_TIER=t0` or `t1` picks a tier when the backend is created, for tests and comparisons.

**Natively,** T1's run loop is `src/jit/dispatch.zig`: find the translation for the PC in the jump cache or the code cache, or lift, optimize, and emit one the first time a PC is dispatched, run it, and follow its exits. A chained exit links the site to its target, so the next run jumps straight there. The loop returns to the Guest only for a system call, an exit request, or `.t0`.

**`.t0` is how every exception reaches the Guest.** A fault, a breakpoint, an undefined instruction, or a failed fetch leaves guest state exact at the instruction, and the Guest runs that one instruction in T0, which raises the exception again with all its architectural detail (the ESR, the 386 vector and error code). A store to a page holding code ends a region the same way: T0 does the store after the page's translations are dropped.

**`call.interp`.** An instruction a lifter doesn't lower becomes a call to T0's handler for it, from inside compiled code, with guest state written back before the call and reloaded after. So every instruction T0 runs works in T1 too, and lifting a class is only a speedup.

**Counting.** `ctx.retired` is exact at every exit, faults included: every op that can leave a region carries the number of guest instructions completed before it in its block, and leaving through it adds that count. A faulting, undefined, or breakpoint instruction isn't retired; a system call is.

## Guest memory and the TLB

`src/interp/mem.zig` is shared by both tiers. Each vCPU has a direct-mapped software TLB of 256 read entries and 256 write entries, each a guest page tag and the difference between the guest and host addresses. The check, inline in generated code and in T0:

```
e = tlb.read[(va >> 12) & 255]           // tlb.write for stores
if (e.tag == va >> 12 and (va & 0xfff) <= 4096 - size)
    host = va + e.delta
else
    slow path
```

An entry is filled only for a page the access is allowed on, so the tag compare is also the permission check, and an access that crosses a page takes the slow path. The slow path (`mem.slowLoad`, `slowStore`, and `slowCas`) finds the page in the View, checks permissions, fills the entry, and does the access, or returns a fault with its address and kind.

**No host faults.** Guest exceptions never come from host traps: no guard pages, no signal handlers, and no reliance on the host faulting on a bad address. Every access is bounds-checked against arena memory the address space owns.

**Code pages.** `mem.CodePages` marks the arena pages that something was decoded or compiled from. A marked page never gets a write TLB entry, so a guest store to it reaches the slow path, which invalidates the page's translations and decode caches before the store. In T1 the store leaves the region instead (`View.code_stores = .exit`), and T0 does it. That keeps self-modifying code and Linux JITs correct with no instruction-cache maintenance from the guest.

## The IR

`src/jit/ir.zig` is the contract between the front ends (h86's and ha64's lifters) and the emitters. A region is a list of blocks; a block is a straight list of operations over typed SSA values (`i1`, `i8`, `i16`, `i32`, `i64`, `v128`, and `flags`) and ends in a terminator.

- **Guest state** is `getreg` and `setreg` at byte offsets in the front end's `Cpu`.
- **Integer ops** are pure: arithmetic, logic, shifts and rotates, multiply high, division with arm64's results (a front end with other rules, such as x86's #DE, checks first), bit counts, extension, `select`, and `icmp`.
- **Flags are values, per guest.** `nzcv.*` (arm64) and `eflags.*` (x86) give a `flags` value packed as the guest packs it, and `nzcv.cond` and `eflags.cond` read a condition from one. Emitters may keep flags in host flags or lazy.
- **Memory** is `load` and `store` with a `MemFlags` (size, sign extension, alignment, ordering, `rmw` for a read-modify-write's load, and a `same_page` hint), `fence`, and `cas`.
- **FP and vectors** (`fp.*` and `v.*`) take the guest's FP environment (rounding, DAZ, FTZ, and whose NaN rules) in their aux, and compute bit patterns. Their reference semantics use `softfloat.zig`, never the host's FPU.
- **Calls:** `call.interp` (T0 on one decoded instruction), `call.helper` (a numbered runtime helper, such as h86's x87), and `copy` (an arm64 instruction run on an arm64 host as itself, [ha64](ha64.md)).
- **Terminators:** `br`, `brcond`, `exit.chain` to a guest PC, `exit.indirect` to a computed one, `exit.svc`, `exit.brk`, and `exit.undef`. A fault leaves from the load, store, or call that takes it. `poll` checks the exit request and the budget at loop heads, and `retire` counts instructions before a branch to another block.

The rules that keep it stable while two front ends and three emitters build against it:

- **Ops are only added,** never renumbered, each with its reference semantics in `src/jit/ir_eval.zig`. An emitter that hasn't lowered a pure op calls `ir_eval.evalOpC` for it, and an FP or vector op `evalExtC`, so adding an op never breaks an emitter.
- **Values are block-local.** Guest state crosses blocks and exits through `getreg` and `setreg`.
- **Guest state is exact at every op that can leave.** A lifter writes an instruction's results before the next load, store, call, or exit. The one deferral is `pending.flags`: packed flags merged into their Cpu slot only on a way out. With aux2 = 2 it writes h86's lazy-flags record instead (`ir.LazyRecord`).
- **`Region.tso`** says the guest is TSO (h86 sets it), so the arm64 emitter orders its accesses ([Concurrency](#concurrency)).

`src/jit/opt.zig` runs a few passes within each block before emission: forwarding guest-register reads, constant folding, turning a condition on a subtract's flags into an `icmp` of its operands, removing dead `setreg`s and dead pure ops, and marking accesses near an earlier one with `same_page`.

## Emitters

An emitter (`src/jit/emitter.zig`) takes a region and an allocation and gives code with a chain entry and its chain sites. `src/jit/regalloc.zig` is linear-scan allocation for the native emitters: the region's most used guest register-file fields ("chunks") are pinned to host registers for the whole region, written back only where guest state must be exact and only if dirty, and block-local values get the remaining registers or frame slots.

| Emitter | Context register | Notes |
| --- | --- | --- |
| `emit/arm64.zig` | x19; x20 holds the Cpu, and x21 and x22 the TLB's read and write tables | Flags live in the host's NZCV where every use can read them, for arm64's NZCV and for the x86 conditions that map onto it. Guest V registers that only copies touch are pinned to v16 and up. With `Region.tso`, loads are LDAPR (LDAR without FEAT\_LRCPC) and stores STLR. |
| `emit/x64.zig` | rbx | Chunks in r12 to r15. SysV or Win64 calls. |
| `emit/wasm.zig` | local 0 | A batch of regions is one module, a function per region; guest registers live in locals; control flow is structured by Ramsey's algorithm ("Beyond Relooper"), with a `br_table` fallback for irreducible regions; regions reach each other with `return_call_indirect` through chain cells. |

The inline TLB check is 6 instructions on arm64 (7 for an access over a byte), with the slow path in an out-of-line stub that saves what's live and, on a fault, writes back the dirty chunks and leaves. `poll` is 5 instructions inline.

`src/jit/ctx.zig` is the runtime ABI: the `Ctx` every region runs with (every field 64 bits, so wasm32 shares the layout, and generated wasm hard-codes the offsets), the `Exit` codes (`chain`, `indirect`, `svc`, `brk`, `fault`, `undef`, and `interrupted`), and the signatures of entries, `call.interp` handlers, and helpers.

## The code cache

`src/jit/cache.zig`, natively:

- **One cache per backend,** a `codemem.Region` of 64 MiB (`H9_EMU_CACHE` bytes, for tests) filled by a bump pointer and shared by every vCPU.
- **Translations are keyed by guest PC and the arena page** holding it, so two address spaces with the same text at the same address share them, as forked Plan 9 processes do, and a space whose mappings changed can't hit a stale one. A translation that runs onto a second guest page records that page too. Regions span at most two pages and 512 instructions.
- **Chaining.** Each `exit.chain` has a site: one patchable jump (`B` on arm64, `jmp rel32` on x86-64) that falls through to the exit until the dispatcher links it to the target's chain entry. Only targets on a page the source was translated from are linked, since only those are sure to map the same way in every space sharing the source.
- **The jump cache.** Each vCPU has 4096 direct-mapped entries from guest PC to translation, which `exit.indirect` looks up inline and the dispatcher uses first. A change to the vCPU's mappings clears it.
- **Invalidation.** `invalidatePage` drops every translation from an arena page: from the lookup table and every jump cache, with every jump patched into them reset. The code stays until the next flush, since a vCPU may still be in it.
- **Flushing.** When the cache is full, the dispatcher asks for a flush and returns `.interrupted`; `zemu` stops every vCPU by kick and wait and empties the cache.

`src/jit/codemem.zig` gives W^X executable memory on every host:

| Host | How |
| --- | --- |
| macOS | One `MAP_JIT` mapping, with writes switched on per thread by `pthread_jit_write_protect_np`, then `sys_icache_invalidate`. Hardened builds need the allow-jit entitlement. |
| Linux | A memfd mapped twice, writable and executable, so no page is both; arm64 cleans and invalidates the caches by hand. Under a binary translator that misses writes through the other view (Rosetta or QEMU running x86-64 Linux on arm64), and only there, one RWX mapping. |
| Windows | A pagefile-backed section mapped twice, then `FlushInstructionCache`. |

Where none of these works (iOS, a hardened macOS build without the entitlement, SELinux denying execmem, or Windows ACG), the backend has no code cache and runs T0. `H9_EMU_NO_CODEGEN=1` acts as such a host, to test the fallback.

## Concurrency

Guest threads run on host threads at once, so guest atomics have to be host atomics and guest ordering has to hold on the host.

- **T0** does aligned loads as acquires and aligned stores as releases on h86, which keeps x86's ordering on arm64 hosts, and uses host atomics for x86 `LOCK` instructions, arm64 exclusives, and LSE.
- **T1** lowers `cas` through `Ctx.slow_cas` on every emitter, and `fence` to a host barrier.
- **arm64's own ordering** maps one to one on arm64 hosts. On x86-64 hosts, which are TSO, it needs fewer fences.
- **x86's TSO on arm64 hosts** comes from `Region.tso`: every load is a load-acquire and every store a store-release, and misaligned accesses take the slow path, which is fenced. `H9_TSO=off` turns it off, for measuring its cost only.

The litmus tests ([Testing](#testing)) check store buffering, message passing, and atomic counters on every tier.

## The web host

The browser host runs h86 and ha64, each with T1 in `src/jit/wasm_t1.zig` instead of `dispatch.zig`, since compiling wasm is asynchronous and costs a module per batch:

- **Warm-up.** A vCPU compiles nothing until it has retired 2M instructions, so a short program (rc starting up, `echo`) never pays for the first compile.
- **Hot entries.** The dispatcher counts entries to each block, keyed as native translations are. T0 runs cold code to its eighth taken branch and comes back, so block heads get counted; both CPUs' T0s can stop after a given number of taken branches for this. At 50 entries a block is lifted and queued.
- **Batches.** A queue of 64, or one that has waited 2,000 dispatcher visits, becomes one module. `h9-web.js` compiles it off the thread and installs its regions into slots of h9's own function table. T0 keeps running meanwhile; a batch's status word says when its slots are live.
- **Chain cells.** Each batch has a cell per distinct chain target, holding the target's slot once it's live (and on a page its source came from) and 0 otherwise.
- **Invalidation** nulls a page's regions' slots and clears cells pointing at them. **Flushing** happens past 65,536 slots or 131,072 counted blocks.

h9.wasm imports `jit_compile` and `jit_drop`, and exports `jit_eval`, `jit_slow_load`, `jit_slow_store`, `jit_slow_cas`, `jit_interp`, `jit_helper`, `jit_ext`, and `jit_table_base`, which generated modules import or the host calls.

**Preemption** is a budget: a vCPU runs 64K instructions at a time and returns `.interrupted` once 2 ms have passed since it last let the other coroutines run. `poll` and T0 spend `ctx.budget`; natively it's never spent.

## Build and selection

| Option | Does |
| --- | --- |
| `-Demu=zig` | Builds the emulator on ha64 and h86, with both tiers |
| `-Dno-jit` | T0 only, as on hosts that forbid generated code; `src/jit/` is left out |
| `-Djit-check` | Every region checked against T0 as it runs ([Testing](#testing)) |
| `-Djit-verify` | Every region verified after lifting and after `opt` (on by default in Debug and ReleaseSafe builds) |
| `-Dvcpu-debug` | `src/interp` and `src/jit` built Debug too; otherwise they're ReleaseFast in a Debug h9 |

`zig build web` always builds `-Demu=zig` with the wasm JIT. `--backend emu`, and `--backend v86` (the browser host's old backend, an alias), select the emulator; `--version` and `--check` report it as `zig (jit)` or `zig (interpreter)`.

| Variable | Does |
| --- | --- |
| `H9_EMU_TIER` | `t0` or `t1`, at backend create |
| `H9_EMU_NO_CODEGEN=1` | Act as a host that refuses generated code |
| `H9_EMU_CACHE` | The code cache's size in bytes |
| `H9_EMU_DETERMINISTIC=1` | ha64's counter from instructions retired ([ha64](ha64.md)) |
| `H9_TSO=off` | Plain accesses for x86 guests on arm64 hosts; for measuring only |

## Testing

T0 is the oracle for T1, and Unicorn, Berkeley TestFloat, and the host CPU are the oracles for T0.

- **Region check** (`src/jit/check.zig`). A lifted region, run by `ir_eval` or as host code, and T0 start from the same Cpu and memory, each on a copy-on-touch shadow of the pages, and must end with the same exit, exit PC, fault address and access, instructions retired, registers and flags, and memory. `-Djit-check` runs every region of every guest program through it, so `zig build integration -Demu=zig -Djit-check` checks the whole integration suite.
- **Emitters against `ir_eval`.** `src/jit/emit/cases.zig` has a case for each op at each width, flags, memory with the slow path and faults, loops, and polls, and `emit/fuzz.zig` generates random regions. Native emitters run them natively; the wasm emitter runs them under Node and in Chromium (`zig build vcpu-web`).
- **Fuzzers.** `zig build fuzz-a64` and `fuzz-x86` run random valid programs on T0 and T1 a region at a time, and against Unicorn in lockstep with `-Demu=unicorn`; `zig build fuzz-long` runs both for an hour across seeds. `zig build lockstep` runs the lockstep tests.
- **Litmus tests.** `zig build litmus` runs store buffering, message passing, and atomic counters on host threads, on T0, on T1 in `ir_eval`, and on T1 as host code, and tallies the outcomes.
- **Cases.** `zig build vcpu` runs the CPU and JIT unit tests natively and under Node; `zig build a64-jit` and `x86-jit` run each CPU's backend cases on T0 and T1.
- **Benchmarks.** `zig build bench -Demu=zig` times the compute loop, system call round trips, and the compute benchmarks on T0 and T1, with T1's dispatch counts.

## Layout

| Path | What |
| --- | --- |
| `src/vcpu.zig` | The module root for both CPUs and the JIT, built ReleaseFast |
| `src/vmm/zemu.zig` | The vmm backend over the two Guests |
| `src/vmm/h86.zig`, `src/vmm/ha64.zig` | The Guests |
| `src/interp/mem.zig` | The TLB, the slow paths, `View`, and `CodePages` |
| `src/interp/softfloat.zig` | IEEE binary16, 32, and 64 in software, with each architecture's rules as parameters |
| `src/interp/a64/`, `src/interp/x86/` | Each CPU's T0 |
| `src/jit/a64/`, `src/jit/x86/` | Each CPU's front end: lifting, flags, and helpers |
| `src/jit/ir.zig`, `ir_eval.zig`, `opt.zig` | The IR, its reference semantics, and its passes |
| `src/jit/ctx.zig`, `frontend.zig`, `emitter.zig`, `alloc.zig`, `regalloc.zig` | The runtime ABI and the interfaces |
| `src/jit/emit/` | The arm64, x86-64, and wasm emitters, their cases, and their fuzzer |
| `src/jit/dispatch.zig`, `cache.zig`, `codemem.zig` | Native T1: the run loop, the code cache, and executable memory |
| `src/jit/wasm_t1.zig` | T1 on the web host |
| `src/jit/check.zig`, `src/jit/check/` | The region check, the generators, the litmus tests, and `-Djit-check` |
| `tests/a64.zig`, `tests/x86.zig`, `tests/jit/` | Backend cases, fuzz drivers, and the wasm emitter's suite |
