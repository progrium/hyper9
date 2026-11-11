---
issue: 19
slug: zig-interpreter
title: A native Zig interpreter for the emulator
status: superseded
created: 2026-11-03
authors: [progrium]
depends: []
areas: [vmm, build, tests]
superseded-by: hcpu
---

# Proposal: a native Zig interpreter for the emulator

## Abstract

A second emulator backend, written in Zig: MIT, dependency-free, and deterministic, covering the instructions 9front's compilers and libc's assembly routines emit, arm64 first. It would let the emulator ship in the MIT `h9` build, which Unicorn's GPLv2 prevents. It implements the existing vmm contract unchanged, is checked instruction by instruction against Unicorn, and keeps its core free of host-specific code, so that it can later run where no JIT can, such as wasm.

## Background

SPEC.md's emulator section listed this as the second step, after Unicorn, before milestones became proposals ([#1](proposals.md)). As it stood there:

2. **A native Zig interpreter later.** It would be MIT, dependency-free, and deterministic. It covers the instruction subset that 9front's compilers and libc's assembly routines emit, arm64 first. Unicorn is the reference: single-step both and compare registers after every instruction.

The emulator's speed was measured against HVF: about 5× slower for arm64 compute and on par for syscalls, so the interpreter wasn't urgent (SPEC.md, Limits and selection).

What Unicorn costs today:

- **Licensing.** It's GPLv2, so the emulator lives behind `-Demu=unicorn` and ships only as the separate `h9-emu` binary with its corresponding source. The MIT `h9` has no fallback: on a host without a supported hypervisor (Linux and Windows until [kvm](kvm.md) and [whp](whp.md)), it exits 125.
- **Build.** Prebuilt `libunicorn.a` exists only for macOS arm64 and linux-musl arm64 and x86\_64; Windows builds QEMU's tree from source through `build/unicorn.zig`.
- **Workarounds.** A 32 MiB TCG buffer per engine, because Windows commits QEMU's default 1 GiB against the pagefile; our own `__clear_cache`, because Zig's compiler-rt one misses a `dsb ish` and Linux arm64 guests ran stale translated code; and a kick that repeats `uc_emu_stop` until the run sees it, because `uc_emu_start` clears a stop that lands just before it.
- **Per-process weight.** About 1.3 MiB and 0.3 ms per engine, and a TB flush whenever an address space changes.
- **Reach.** It's a JIT, so it can't run where code can't be generated at run time.

Its strengths stay: about 1.5 G instructions/s on arm64 (M3 Max), mature A64 and x86-64 coverage, and amd64 support. That's why it stays as the reference and as the amd64 emulator.

## Proposal

### Scope

- **arm64 only**, at EL0: user-mode A64. No AArch32, no SVE, no EL1, no MMU, no system registers beyond those EL0 can reach. amd64 stays on Unicorn; an amd64 interpreter would be its own proposal.
- **The subset 9front emits.** That means the code 7c and 7l generate, the hand-written assembly in `libc/arm64`, and the other `*.s` files in the arm64 userland, and whatever the Go toolchain emits once [go-compat](go-compat.md) lands. The subset is measured, not guessed (Inventory, below).
- **Anything else faults.** An encoding the interpreter doesn't implement exits with a fault whose syndrome is EC 0 (unknown reason), as the hardware reports an undefined instruction. The guest gets `sys: trap: ...` like any other bad instruction, never wrong results.

### Layout

| File | Role |
| --- | --- |
| `src/interp/a64/decode.zig` | Instruction word to micro-op: one table, shared with the inventory tool |
| `src/interp/a64/exec.zig` | The dispatch loop and the semantics of each micro-op |
| `src/interp/a64/fp.zig` | FP and SIMD semantics that can't be left to host float ops (below) |
| `src/interp/mem.zig` | Guest-memory access: a small software TLB over the address space's regions |
| `src/vmm/interp.zig` | The vmm backend: Backend, AddressSpace, and Vcpu, wrapping the core |
| `src/vmm/lockstep.zig` | A test-only backend that runs the interpreter and Unicorn side by side |
| `tools/a64inv.zig` | The inventory tool |

The core (`src/interp/`) depends only on `std.math` and `std.mem` and its caller's memory: no threads, no mmap, no signals, no allocation in the run loop. The backend in `src/vmm/interp.zig` does the allocation, locking, and kicking. That split is what keeps the core portable to targets without OS services.

### State

```zig
pub const Cpu = struct {
    x: [31]u64,          // x30 is the link register; x31 reads as xzr or sp by encoding
    sp: u64,
    pc: u64,
    nzcv: u4,
    v: [32]u128,         // Q0-Q31
    fpcr: u32,
    fpsr: u32,
    tpidr: u64,          // TPIDR_EL0
    monitor: ?Monitor,   // the exclusive monitor: address, size and the value LDXR saw
    retired: u64,        // instructions retired, for deterministic counters and stepping
};
```

`getUreg`/`setUreg` and `getExtra`/`setExtra` copy between this and `vmm.Ureg` and `vmm.Extra` directly, with no engine API in between. `Ureg.psr` carries NZCV in bits 31:28, as the other backends do.

### Execution

- **Predecoded pages.** Text is mapped read-only and executable and never changes while it's mapped: Plan 9 has no JIT and no self-modifying code. So each executable 4 KiB page is decoded once, on first fetch, into 1024 micro-ops (handler, registers, immediate), and the loop never sees an instruction word again. The cache belongs to the address space and is dropped when its `generation` moves, which `map` and `unmap` already bump.
- **Dispatch** is a labeled `switch` with `continue :dispatch`, Zig's threaded-dispatch form. Each handler ends by fetching the next micro-op from the current page, or by looking up the target page on a branch.
- **Memory** goes through `src/interp/mem.zig`. A direct-mapped software TLB of 64 entries maps a guest page to a host slice and its permissions, filled from the address space's regions on a miss and flushed with the decode cache. Every access is checked against the slice and its permissions before it touches host memory. A miss with no region, or a permission failure, is a fault.
- **Exits.**
  - `SVC #0` returns `.syscall` with the PC past the instruction and `Ureg.type` set to `EC_SVC64 << 26`, as the emulator does today.
  - A fault returns `.fault` with the PC at the faulting instruction. `Fault.syndrome` and `Ureg.type` get the ESR the hardware would report: `EC_DABT_LOWER` or `EC_IABT_LOWER` with a translation or permission fault status, EC 0 for undefined instructions, and the alignment fault for a misaligned exclusive. Fault notes then read the same on the interpreter as on HVF.
  - `BRK` and `UDF` fault as on hardware.
- **Kick.** `kick` sets an atomic flag, which the loop checks at every taken branch and every page crossing. Every loop in guest code contains a taken branch, so a spinning guest sees the kick within one iteration. `run` checks the flag before it starts, and a flag set after that is seen at the next check, so there's no window where a kick is lost and no need to repeat it as with Unicorn.
- **`halted`** isn't produced: there's no `WFI` at EL0, and `run` returns only on an exit or a kick.

### Semantics Zig doesn't give for free

Where the architecture defines a result that Zig treats as undefined behaviour or leaves to the host, the interpreter spells it out:

| Case | arm64 result | Zig default |
| --- | --- | --- |
| `SDIV`/`UDIV` by zero | 0, no trap | Undefined behaviour |
| `SDIV` of the most negative value by −1 | The most negative value | Undefined behaviour |
| Shift by a register amount | Amount modulo the width | Undefined behaviour at or past the width |
| `FCVTZS`/`FCVTZU` out of range or NaN | Saturates; NaN gives 0 | `@intFromFloat` is undefined behaviour |
| NaN propagation and default NaN | ARM's rules, FPCR.DN | The host's: x86 differs from arm64 |
| `FMADD` and friends | Fused | `@mulAdd` is fused; `a * b + c` isn't |
| Denormals, FPCR.FZ | Flush-to-zero when set | The host's mode |
| Rounding mode, FPCR.RMode | Per instruction | Round to nearest only |
| FPSR cumulative flags | Set per operation | Not exposed |

FP results must not depend on the host CPU: the same binary gives the same bits on an arm64 Mac and an x86-64 Linux box. So NaN handling, flush-to-zero, and FPSR flags are computed in `fp.zig`. Round to nearest uses host arithmetic, which is correct by IEEE 754. The directed rounding modes are emulated in software, and are expected to be rare.

### Concurrency and the memory model

Processes run on their own host threads, and `RFMEM` processes share their data and bss, so two interpreters can touch the same guest memory at once. The rules:

- Plain loads and stores of up to 8 bytes that are naturally aligned are single-copy atomic, as on arm64. The interpreter does them as `.monotonic` atomic accesses, which compile to plain moves on both host architectures.
- **Exclusives** (`LDXR`/`STXR` and the acquire and release forms) are done the way QEMU does them. `LDXR` records the address, size, and value it loaded. `STXR` succeeds only if the monitor matches, and then as a compare-and-swap of that value. A context switch, a `run` returning, or any other exclusive clears the monitor. This admits ABA, which no Plan 9 lock depends on.
- **LSE atomics** (`LDADD`, `SWP`, `CAS`, and the rest), if the inventory shows any, map to `@atomicRmw` and `@cmpxchgStrong`.
- **Barriers.** `DMB`, `DSB`, and the acquire and release orderings become seq\_cst fences. That's stronger than needed, and simple. `ISB` is a no-op.

### System instructions at EL0

| Instruction | Interpreter |
| --- | --- |
| `MRS`/`MSR` `TPIDR_EL0`, `NZCV`, `FPCR`, `FPSR` | Cpu state |
| `MRS CNTVCT_EL0`, `CNTFRQ_EL0` | The host's monotonic clock at a fixed 24 MHz, matching Apple silicon; in deterministic mode, derived from `retired` |
| `MRS CTR_EL0`, `DCZID_EL0` | Fixed values: 64-byte lines, `DC ZVA` allowed with a 64-byte block |
| `DC ZVA` | Zeroes the block, checked as a store |
| `DC CVAU`, `IC IVAU`, and the other EL0 cache maintenance | No-ops |
| Anything else | Undefined: fault |

### Inventory

`zig build a64-inventory` runs `tools/a64inv.zig` over every a.out under `$H9ROOT/arm64/bin` and the test fixtures. It decodes each text segment with the interpreter's own decode table and reports:

- each micro-op with its count and the binaries that use it
- every word that decodes to nothing implemented, with its binary, offset, and nearest symbol from the a.out symbol table

That report is the spec. The inventory also runs as a test that fails when a root-tree binary contains an unimplemented encoding outside a reviewed allowlist in `tools/a64inv.allow`. The allowlist exists because a text segment may hold data that never runs (see Open issues).

### Deterministic mode

Given the same binary, arguments, and syscall results, the interpreter executes the same instruction stream: there's no translation cache whose timing leaks in, and no host FP state. Two places read time: `CNTVCT_EL0` and the kick check. `Machine.Options` gains nothing here. A test-only `interp.Options.deterministic` derives the counter from `retired` and kicks only at exits, which gives the "record and replay at the syscall boundary" SPEC.md's emulator section promises. A replay CLI would be its own proposal.

### Build and selection

- `-Demu` gains `zig` and `lockstep`: `Emu = enum { none, unicorn, zig, lockstep }`.
- **The default becomes `zig`**, so the MIT `h9` has the emulator built in and `--backend auto` falls back to it, with the existing warning.
- `vmm.Kind` keeps one `emu` member. The build decides which emulator is behind it, so `--backend emu`, `H9_TEST_BACKENDS=emu`, and the integration harness are unchanged.
- `emuVersion` reports `zig` or `unicorn x.y`, and `--version` and `--check` print it.
- With `-Demu=zig`, an amd64 binary on the emulator fails with `WrongArch` (exit 126), as HVF does today.
- `scripts/release.sh` keeps building `h9-emu` with Unicorn for amd64 emulation; the MIT `h9` archives now include the interpreter.

### Lockstep

`-Demu=lockstep`, a development build that links Unicorn, puts `src/vmm/lockstep.zig` behind `emu`. Each vCPU holds an interpreter and a Unicorn engine:

- **Memory.** The interpreter runs on the address space's own pages. Unicorn runs on a mirror copy, made with `uc_mem_map_ptr` over pages the lockstep backend allocates.
- **Each step,** both execute one instruction: Unicorn through a `UC_HOOK_CODE` hook that stops after one, the interpreter through a step entry point. Then the backend compares the general registers, SP, PC, NZCV, and the FP/SIMD registers, FPCR and FPSR. For a store it also compares the bytes written, read back from both memories.
- **At each exit** both must agree on the kind, PC, fault address, and syndrome class. The syscall is served once, on the interpreter's memory. Then the pages the syscall wrote are copied to the mirror, and the Ureg is set on both.
- **On divergence** the backend panics. It prints the instruction word, its disassembly where `tools/a64inv.zig` has one, the PC with its symbol, the register differences, and the last 64 instructions retired.

`zig build integration -Demu=lockstep` then runs the whole integration suite, each case checked one instruction at a time.

## Rationale

**Why an interpreter and not a JIT.** A JIT would be faster on compute, but it needs executable memory: the `com.apple.security.cs.allow-jit` entitlement and `MAP_JIT` on macOS, W^X handling everywhere, and an icache flush that, as the `__clear_cache` workaround shows, is easy to get wrong. It also can't run where code generation isn't allowed. The emulator exists for development, CI, and hosts without a hypervisor, and syscall-heavy work, most of what h9 runs, is already bound by syscall cost rather than compute. The predecoded micro-ops are a basic-block IR, so a later tier can translate hot blocks without changing the backend or the vmm contract.

**Why the 9front subset and not all of A64.** A64 with its SIMD and FP extensions is thousands of encodings. 9front's compilers use a small, stable part of it, because they generate simple code and 9front's assembly is hand-written for clarity. The inventory makes the subset concrete and checkable. An encoding outside it faults visibly instead of misbehaving. When the root tree's pin moves, the inventory test says what's new.

**Why arm64 first.** It's what HVF runs and what the root tree is built for. Its fixed 32-bit encoding decodes from a few bit fields, while amd64's variable-length prefixes and ModRM forms would need much more decoder. Unicorn already covers amd64 for the testing-only cross-architecture runs SPEC.md allows.

**Why keep one `emu` kind.** A new backend kind would add a `--backend` value and a CLI change for something users choose only by build. Behind `emu`, the CLI, `Machine.Options`, and the test harness don't change. The integration harness already runs each case on every backend listed and checks that they agree.

**Alternatives rejected.**

- **Keep Unicorn only.** It leaves the MIT build without a fallback until KVM and WHP exist, and leaves every Unicorn workaround in place. It also leaves the emulator tied to targets with a prebuilt wheel or a QEMU source build.
- **Dynarmic** (0BSD, an A64 JIT in C++). Permissive, but it's a C++ dependency with its own build. It's a JIT, so it has the executable-memory and reach problems above, and its hosts are x86-64 and arm64 only.
- **Blink** (ISC). An x86-64 user-mode emulator; it doesn't do arm64.
- **Unicorn's interpreter mode.** QEMU's TCI exists, but it's still GPLv2 and still QEMU's build.
- **Checking only against HVF.** HVF runs at full speed but can't be single-stepped from the host cheaply, and only exists on macOS. Unicorn can be stepped anywhere. Comparing syscall traces against HVF stays, through the integration harness's backend comparison.

**Performance.** The interpreter will be slower than Unicorn on compute; the target is the bench loop within 4× of Unicorn's time, which is about 20× HVF's. Syscall round trips should be faster than Unicorn's 0.8 µs, since `run` enters no engine and sets no registers through an API. Both go in SPEC.md's Limits and selection from `zig build bench`. The target isn't a gate: correctness is.

## Compatibility

- **CLI.** No new flags or exit codes. `--backend emu` and the `auto` fallback now work in the MIT build. On Linux and Windows hosts without KVM or WHP support, `h9` runs programs on the interpreter with a warning, where it used to exit 125. `--version` and `--check` name the emulator.
- **`Machine.Options` and the vmm interface.** Unchanged. The interpreter implements Backend, AddressSpace, and Vcpu exactly as the Unicorn backend does, including `getExtra`/`setExtra` for the vCPU pool and `maxVcpus` returning 64.
- **Build.** `-Demu` gains two values and its default moves from `none` to `zig`. `-Demu=none` keeps today's MIT build without an emulator.
- **Releases.** The `h9` archives grow by the size of the interpreter. `h9-emu` stays as it is.
- **Root tree and `third_party/`.** Unchanged.

## Security

**What changes.** On the emulator, the isolation boundary is software rather than the hypervisor: guest code never runs on the host CPU, and every guest memory access goes through the interpreter's checks. That's already true of the Unicorn backend. What's new is that the MIT `h9` now falls back to software isolation on hosts without a hypervisor, where it used to refuse to run.

**The boundary is smaller than Unicorn's.** It's a few thousand lines of Zig with one memory-access path, instead of QEMU's code generator, softmmu, and helpers in C. Every access is bounds-checked against a host slice before it's made. Releases are built `ReleaseSafe`, so slice bounds and integer overflow are checked even in the hot loop. Disabling runtime safety is allowed only in handlers whose bounds are already proven by the TLB check, with a comment saying so.

**What could go wrong.**

- **A wrong permission check or a stale TLB entry** after `unmap` could let a guest reach freed host pages. The TLB is flushed on every `generation` change, and `unmap` already bumps it. A unit test unmaps a page while a vCPU has it cached and checks that the next access faults.
- **A guest-controlled index into host arrays,** such as a register number or the decode table: register fields are 5 bits into 32-entry arrays, and handler indices come from the decoder, never from guest data.
- **Concurrency between processes sharing memory:** shared accesses are atomic, and the monitor holds a value, never a host pointer.

**Testing the boundary.** The lockstep backend checks correctness, and a fuzzer checks the boundary. `zig build fuzz-a64` generates random instruction words, biased toward the inventory's classes, and runs them in a small address space with guard pages. It requires that every access outside the mapping faults, and that the interpreter neither crashes nor touches memory outside its slices. Run under `-Demu=lockstep`, the same fuzzer compares results with Unicorn.

The sandbox policy is unaffected: it's enforced in the kernel, above the vmm layer, the same on every backend.

## Done criteria

- [ ] `zig build integration -Demu=zig` passes every `[baseline]` case with `H9_TEST_BACKENDS=emu`, on macOS arm64, Linux arm64, and Linux x86\_64 (running arm64 binaries), and Windows x86\_64.
- [ ] On macOS arm64, `zig build integration -Demu=zig` with `H9_TEST_BACKENDS=hvf,emu` passes, so the interpreter's output and syscall traces match HVF's.
- [ ] `zig build integration -Demu=lockstep` passes every `[baseline]` case with no divergence.
- [ ] `zig build test -Demu=zig` passes `tests/backends.zig`: hello, exits, faults, kicks, and the kick race, timeouts, notes, segments, and the vCPU pool carrying FP state.
- [ ] New cases in `tests/a64.zig`, tagged `[zig-interpreter]`:
  - `test "integer division by zero gives 0 [zig-interpreter]"`
  - `test "fcvtzs saturates and NaN converts to 0 [zig-interpreter]"`
  - `test "FP results are the same on every host [zig-interpreter]"`: fixed inputs, with the expected bits from HVF
  - `test "an unimplemented encoding faults with EC 0 [zig-interpreter]"`
  - `test "a misaligned exclusive faults [zig-interpreter]"`
  - `test "STXR fails after a context switch [zig-interpreter]"`
  - `test "unmapping a cached page makes the next access fault [zig-interpreter]"`
  - `test "deterministic mode gives the same instruction count twice [zig-interpreter]"`
- [ ] `test "every root-tree binary decodes to implemented ops [zig-interpreter]"` passes, against the reviewed allowlist.
- [ ] `zig build bench -Demu=zig` reports the loop and the syscall round trip, and SPEC.md's Limits and selection gives them next to Unicorn's and HVF's.
- [ ] Demo: `h9 --backend emu ls /bin | wc -l` from a default MIT build on a Linux host without KVM support.

## Implementation

1. **Decode table and inventory.** Write `decode.zig` as a table of encoding patterns to micro-ops, and `tools/a64inv.zig` on top of it. Run it on the pinned root tree and commit the report's summary to this proposal's Updates, so the subset is on record before any semantics are written.
2. **Integer core.** `exec.zig` and `mem.zig` for the integer, branch, load/store, and exclusive classes the inventory found. Add unit tests per class in `tests/a64.zig`, with hand-assembled words as `tests/backends.zig` already does.
3. **Backend.** `src/vmm/interp.zig` and `-Demu=zig`. `tests/backends.zig` and the `[baseline]` cases that don't use FP should pass at this point.
4. **Lockstep.** `src/vmm/lockstep.zig` and `-Demu=lockstep`. From here on, every new class is written against lockstep.
5. **FP and SIMD.** `fp.zig` for the classes the inventory found, with the host-independence cases.
6. **Fuzzer.** `zig build fuzz-a64`, standalone and under lockstep.
7. **Default and release.** Switch the `-Demu` default to `zig`, update `scripts/release.sh` and the README, run `zig build bench`, and update SPEC.md's emulator section: the interpreter as the default emulator, Unicorn as the reference, and the amd64 emulator. Set `status: implemented`.

## Open issues

- **Data in text.** Does 7l place literal pools or jump tables in text? If it does, the inventory sees data as instructions, and the allowlist has to be maintained by hand at each pin. Using the symbol table to skip non-code ranges may avoid it.
- **Which rounding modes 9front code really sets.** `setfcr` can change FPCR.RMode, and software directed rounding is slow. If nothing in the root tree uses it, the first version could fault on a non-default mode instead.
- **Lockstep time in CI.** Single-stepping Unicorn costs microseconds per instruction, so the full suite under lockstep may take too long for every push. It may need to run nightly, or only on the `tests/backends.zig` cases and a chosen few integration cases ([checks](README.md#checks)).
- **Whether `h9-emu` survives.** Once the interpreter passes everything, `h9-emu` is only needed for amd64 emulation, which SPEC.md treats as testing-only. Retiring it would drop the GPLv2 release and its source archive. Building Unicorn would stay possible for development and lockstep.
- **An amd64 interpreter.** It would give the MIT build amd64 emulation, and is the last thing needed to retire Unicorn completely. It would be a separate proposal.
- **Hosts beyond the hypervisors.** A core with no OS dependencies would also run on targets h9 doesn't support today, wasm in particular. Each of those is a host platform with its own threading and I/O questions, so it would be its own proposal. The constraint on `src/interp/` here, no OS services, is what keeps that option open.
## Updates

- 2026-11-06: **Spikes, and how much this buys.** Prototypes on an x86\_64 Linux container, with no hypervisor and no 9front.org access. Binaries came from the pinned 9front source, built with 7c/7a/7l compiled for Linux. Unicorn was reached through h9 built with `-Demu=unicorn`. The Unicorn comparisons should be redone on an M-series Mac. Code and steps are outside the repo, in the project's `zig-interpreter-spikes/` folder.
  - **Practical benefit is limited.** For wasm, [browser-host](browser-host.md) runs 386 builds of the same root-tree binaries on v86, which compiles guest code to wasm. That should beat an interpreter running inside wasm, so wasm isn't a reason to do this proposal. Natively, Unicorn is good enough for what the emulator is for (development, CI, hosts without a hypervisor). [kvm](kvm.md) and [whp](whp.md) shrink the remaining gap to hosts where neither is available: containers without nested virtualization, locked-down CI, and Windows without Hyper-V. What's left is the MIT fallback on those hosts, parallel guest execution (below), deterministic replay, and dropping Unicorn for arm64. Go still needs Unicorn: it has no `plan9/arm64` port, so the Scope line about Go doesn't apply, and `h9-emu` stays for Go and amd64. This proposal should wait behind kvm and whp unless one of those becomes pressing.
  - **Inventory.** 115 binaries (libc, 30 libraries, 110 single-file commands, rc, awk, hoc, grep, mk, sam) have 1,466,730 text words. They use 84 mnemonics in 205 operand forms, and the top 100 forms cover 98.4% of instructions. There's no AdvSIMD, no Q registers, no LSE, no LDAXR/STLXR, no CSEL, no FMADD, and no TPIDR\_EL0. The exclusives are LDXR/STXR and DMB ISH, from libc's tas.s and atom.s. FP is scalar, 0.5% of instructions; FRINTM/FRINTP are the only rounding instructions. System registers are FPCR, FPSR, and CNTVCT\_EL0.
  - **Data in text** (2.4% of words) is fully accounted for by three rules: LDR (literal) targets; CASE tables after 7l's `adr; ldrsw; add; br`; and pools 7l branches round, between an unconditional B and its forward target. Some pool entries are unreferenced, so the first rule alone misses them. No undecodable word is left, so `tools/a64inv.allow` isn't needed.
  - **Rounding** (open issue): nothing in the tree sets FPCR.RMode, FZ, or DN. The `setfcr` callers only clear trap enables, which should read as zero and ignore writes, as on Apple cores. Directed rounding needn't be emulated. FPSR is read only by `qi`.
  - **Core.** A prototype of this design (predecoded 16-byte micro-ops, a labeled-switch dispatch with a per-kind `inline else`, a 64-entry TLB, CAS exclusives) ran awk, hoc, sed, sort, md5sum, factor, and echo. Its register state after every instruction matched Unicorn's over 2.9M instructions. A float/double conversion bug got past all of those traces and was caught only by an FP edge-case program. Lockstep needs a case per inventory form as well as the fuzzer.
  - **Speed.** The interpreter took 0.37–0.73× Unicorn's time on calls, qsort, and FP, 1.9× on md5, and 2.6× on the bench loop (target 4×). It runs 300–500 M instructions/s. A syscall exit and re-entry costs 13 ns, against 381 ns through Unicorn's API. The kick check costs about 6% on the bench loop. Counting `retired` per instruction costs about 15%, so deterministic mode should count per block.
  - **Concurrency.** Four host threads doing 2M LDXR/STXR increments each lost nothing, and so did a plain read-modify-write under libc's `_tas` lock. So unlike `emu.zig`, this backend needs no GuestLock and runs processes' guest code in parallel. That was tested only on x86, which is TSO, and still needs an arm64 host. Kicks took 2.6 µs on average, and a kick set before `run` is seen, so no retry loop is needed.
  - **FP.** Default NaNs, NaN propagation with payloads, sNaN quieting, subnormals, and saturating conversions all match Unicorn on x86. FPSR doesn't: the spike sets only IOC and DZC, where Unicorn also sets IXC and UFC. Either compute those with error-free transforms, or leave them out and mask them in lockstep.
  - **Decode cache.** Text is never written today. But brk and stack growth map new chunks, and each bumps `generation`, so the rule in Execution would drop every decoded page on heap growth. Only the TLB needs flushing then. Decoded pages should go only when an executable mapping changes, or live on the text segment, shared across fork. Decoding costs about 10 µs and 16 KiB per text page. [self-host](self-host.md)'s `/proc/n/mem` writes will need to invalidate.
  - **Lockstep cost.** Single-stepping Unicorn from C, with a batch register read, takes about 280 ns per instruction. That fits the backend tests and chosen cases, not every push.
  - **wasm32.** The core compiles once indices are cast to `usize`. Zig 0.16 rejects 64-bit `@atomicLoad`, `@atomicStore`, and `@cmpxchgStrong` with 32-bit pointers, so wasm32 would need a fallback. An optimized wasm32 build of the inlined dispatch didn't finish in 17 minutes; a native build takes about a minute.
- 2026-11-11: **Superseded by [hcpu](hcpu.md).** hcpu's ha64 is this proposal's interpreter, widened to all of Armv8.0's A64 with FP, AdvSIMD, and LSE, as the T0 under a JIT. hcpu also carries over the lockstep check against Unicorn, the inventory tools, deterministic mode, the MIT emulator default, and parallel guest threads, and adds h86, hx64, and the browser host. Its design, not this one's, is what was built.
