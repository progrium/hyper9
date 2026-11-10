---
slug: x86-jit
title: A 386 JIT for the emulator and the browser
status: draft
created: 2026-11-10
authors: [progrium]
depends: [19]
areas: [vmm, web, build, tests, linux]
---

# Proposal: a 386 JIT for the emulator and the browser

## Abstract

A user-mode 386 CPU in Zig, modeled on v86's interpreter and JIT, that runs 9front's and Linux's 32-bit x86 programs. It replaces Unicorn for 386 guests on native hosts, and it replaces v86 in the [browser host](0012-browser-host.md), where it's built into `h9.wasm` itself. It covers only what a ring-3 process in a flat 32-bit address space can do: no real mode, no paging, no descriptor tables beyond the selectors h9 hands out, no interrupts, and no devices. It has two tiers, an interpreter and a region JIT, and the JIT is the 386 front end on the layer [a64-jit](a64-jit.md) defines: the same IR, software TLB, exits, code cache, and emitters. This proposal builds that layer's wasm emitter first, since 386 is what the browser runs today, then uses the native arm64 and x86-64 emitters.

## Background

### 386 in h9 today

386 binaries ([i386](0009-i386.md)) and 32-bit Linux programs ([linux-i386](0105-linux-i386.md)) run on two CPUs, and neither is ours.

**Unicorn, on native hosts** (`src/vmm/emu.zig`), in `UC_MODE_32`. It carries everything [zig-interpreter](0019-zig-interpreter.md) and [a64-jit](a64-jit.md) list against it (GPLv2 and only in `h9-emu`, three prebuilt targets, a guest lock that serializes threads, 1.3 MiB per engine), plus 386-only workarounds. Each engine has a read-only GDT page at `0xFFFFF000` with flat ring-0 descriptors and the TLS entry, loaded at start because any segment load makes QEMU recompute the 32-bit code and stack flags from segment caches that Unicorn's 32-bit mode leaves empty. The x87 and SSE state is assembled into an FXSAVE image register by register, in stack order.

**v86, in the browser** (`src/vmm/v86.zig`). It's a whole PC, and h9 uses a fraction of it through a guest kernel of its own:

- `src/arch/i386/shim.S` starts in real mode, as a boot sector would, and builds a GDT, an IDT, a TSS, and page tables so that a ring-3 process can run.
- A syscall or fault exits by halting at ring 0, and the backend clears v86's `in_hlt` by writing its register block, since v86 exports nothing that clears a halt. A round trip costs about 3 µs.
- Preemption ends v86's 1 ms slice at ring 3 with no Ureg on the stack, so `run` rebuilds the Ureg from v86's register block and forces the CPU back to ring 0 by writing `cpl`, CS, SS, their cached bases, limits, and access bytes, `is_32`, and `stack_size_32`.
- Those offsets (`segment_access_bytes`, `sreg`, `segment_is_null`, `segment_offsets`, `segment_limits`, `is_32`, `stack_size_32`, and the registers) aren't an ABI. `scripts/pins.sh` records them for v86 0.5.473, and a test checks them against the pinned `v86.wasm`.
- `h9.wasm` and `v86.wasm` share one memory, instantiated in a fixed order so that wasi-libc's heap, v86's allocator, and guest RAM don't overlap, with `h9.wasm` linked at a 16 MiB base.
- Each address space is a two-level page directory, and a CR3 switch on every context change flushes v86's TLB. h9's own writes to guest memory go around v86, so the backend calls `jit_dirty_page` for pages it frees or maps executable.
- `codegen_finalize_finished` panics when called from inside `codegen_finalize`, so the glue queues it.

That's a lot of machinery, and a pinned release, to emulate the parts of a PC that h9 then has to work around.

### What v86 is

v86 (BSD-2) is about 34,000 lines of Rust in `src/rust/` and 2,600 lines of JavaScript generators in `gen/`. `gen/x86_table.js` lists 663 encodings with their properties (ModRM, operand size, immediates, whether the JIT has custom code for it, and whether it ends a block), and the generators turn it into the interpreter's decoder, the JIT's decoder, and the analyzer that finds basic blocks. Its pieces:

| Piece | Files | h9 needs it? |
| --- | --- | --- |
| Instruction semantics: integer, string, x87, MMX, SSE, SSE2 | `cpu/instructions*.rs`, `arith.rs`, `string.rs`, `fpu.rs`, `sse_instr.rs`, `misc_instr.rs`, `softfloat.rs` | Yes, at ring 3 |
| Decoding: the encoding table, ModRM and SIB, prefixes | `gen/`, `modrm.rs`, `prefix.rs` | Yes, 32-bit; 16-bit addressing rarely |
| The JIT: page hotness, block analysis, structured control flow, wasm generation | `jit.rs`, `analysis.rs`, `control_flow.rs`, `codegen.rs`, `jit_instructions.rs`, `wasmgen/` | Its design; the code is wasm-only |
| Lazy flags (`last_op1`, `last_result`, `last_op_size`, `flags_changed`) | `cpu/arith.rs`, `codegen.rs` | Yes |
| The TLB and page walks, CR0, CR3, PAE | `cpu/cpu.rs`, `paging.rs` | Only a flat software TLB |
| Segmentation, task switches, call gates, `iret`, real and virtual-8086 mode, interrupt delivery | `cpu/cpu.rs` | Only FS and GS bases |
| Ports, PIC, APIC, IOAPIC, PIT, VGA, and the rest | `cpu/*.rs`, the JS devices | No |

Its JIT's design, which carries over:

- **Tiers.** Everything starts in the interpreter. Each physical page has a hotness counter and a set of entry points seen. At 200,000 heat a page is analyzed: its basic blocks are found from its entry points, and up to three pages of them are compiled into one wasm module whose function dispatches on an entry index with a `br_table` and turns back edges into wasm loops.
- **Code is keyed by physical address,** with a small state-flags byte (32-bit code, 32-bit stack, CPL 3, flat segments). Compiled code computes EIP by keeping the high bits of the current EIP and setting the low 12 (`gen_set_eip_low_bits`), so it's position-independent within a page, and two mappings of the same page share it.
- **Guest registers live in wasm locals** within a function, and lazy flags are tracked across instructions: a `jcc` after a `cmp` whose operands are still in locals compares them directly.
- **Memory** is an inline TLB lookup with a slow-path call for misses, page crossings, and faults. A TLB entry with `TLB_HAS_CODE` sends writes to the slow path, which dirties compiled code on that page.
- **x87** is 80-bit, through Berkeley SoftFloat 3's `extF80` functions compiled to wasm, so results don't depend on the host.

### What 386 programs use

A spike for this proposal (not in the repo; in the project's `x86-jit-spikes/` folder) ran capstone's 32-bit decoder over every ELF text section in Alpine 3.22's x86 minirootfs plus `python3`, `sqlite`, `git`, `libffi`, `xz-libs`, and `mpdecimal`, and a Go 1.24 `linux/386` program using `net/http`, `crypto/sha256`, and `encoding/json`: 108 files and 5.27 M instructions.

- **523 mnemonics.** The top 100 cover 99.37% of instructions, and the top 200 99.89%.
- **Integer is 98.1%.** SSE2 is 1.19%, SSE 0.28%, x87 0.34%, and MMX 0.06%. Alpine x86 builds with SSE2 floating point, so most of the x87 is `fld`, `fstp`, and `fistp` at the edges and in busybox, and the classic `fnstcw`, `fldcw`, `fistp`, `fldcw` sequence for C's float-to-int conversion (439 `fldcw`).
- **AVX, AVX2, AES-NI, SHA, PCLMUL, SSSE3, and SSE4.1** together are 0.04%, all in `libcrypto` and Go's runtime, and all chosen at run time from CPUID. A CPUID that doesn't report them keeps them unused.
- **Prefixes.** Operand size (`0x66`) is on 1.4% of instructions, GS on 0.6% (TLS and the stack protector's `%gs:0x14`), CS on 0.68% (gcc's multi-byte NOP padding), REP string instructions 0.11%, LOCK 0.012%, and address size (`0x67`) 0.005%.

9front's 386 binaries weren't in the spike, since this container had no 9front checkout. 8c emits x87 for all floating point and no SSE, and 9front's `libc/386` uses `rep movsl` and `rep stosl` for `memmove` and `memset`, so x87 and REP strings matter more there. The inventory tool (Implementation, step 1) covers both trees.

## Proposal

### Scope

- **A ring-3 process in protected mode with flat segments:** CS, DS, ES, and SS have base 0 and a 4 GiB limit, and their override prefixes are no-ops. FS and GS have a base, from the selectors below.
- **Instructions:** every user-level integer instruction through the Pentium Pro (including `CMOVcc`, `CMPXCHG8B`, `BSWAP`, `XADD`, and `CPUID`), x87, MMX, SSE, and SSE2, with both operand sizes and 16-bit addressing. That's what h9's `AT_HWCAP` for i386 already advertises (CPUID 1's `edx`).
- **CPUID** reports a fixed family 6 CPU with FPU, TSC, CX8, CMOV, MMX, FXSR, SSE, and SSE2, and no SSE3 and later, no AVX, no OSXSAVE, and no AES-NI. Later extensions are added one at a time, as [a64-jit](a64-jit.md) adds its HWCAP bits: once both tiers implement them.
- **Selectors.** A small table replaces the GDT: the 9front user selectors that `src/arch/i386.zig` puts in the Ureg, the null selector, and Linux's TLS entry 6 (`0x33`) with the base from `X86Extra.tls`. Loading anything else into a segment register is a general protection fault, as it would be on the real kernel.
- **Exits.** `INT $64` and `INT 0x80` exit with `.syscall` and `Ureg.trap` set to the vector, as on Unicorn and v86 today; each personality faults on the other's vector as now. A fault sets `Ureg.trap` and `ecode` to what 9front's kernel puts there: 14 with the fault address for a page fault, 13 for a protection fault, 6 for an undefined opcode, 0 for a divide error, 16 and 19 for unmasked x87 and SSE exceptions, and 3 for `INT3`.
- **Everything else faults.** Privileged instructions (`HLT`, `CLI`, `STI`, `LGDT`, moves to control registers, and the rest), port I/O, far jumps, calls and returns, `IRET`, `SYSENTER`, and `INT` with other vectors raise a protection fault, as they do at ring 3 with IOPL 0. An encoding neither tier implements raises an undefined-opcode fault, never a wrong result.

### Tiers and layout

| Tier | What |
| --- | --- |
| T0 | An interpreter over decoded instructions, cached per guest page | 
| T1 | The JIT: regions lowered through [a64-jit](a64-jit.md)'s IR to wasm, arm64, or x86-64 |

As in [a64-jit](a64-jit.md), T0 runs code until T1 has it, runs any instruction T1 doesn't lower as a `call.interp` from inside a region, and is the oracle every region is checked against. Hosts that can't generate code run T0 alone.

| File | Role |
| --- | --- |
| `src/interp/x86/table.zig` | The encoding table, a comptime array in the shape of v86's `x86_table.js` |
| `src/interp/x86/decode.zig` | Prefixes, ModRM, SIB, and immediates to a decoded instruction, with its register and flag read and write sets |
| `src/interp/x86/exec.zig` | T0's dispatch and the integer and string semantics |
| `src/interp/x86/flags.zig` | Lazy EFLAGS |
| `src/interp/x86/x87.zig`, `f80.zig` | The x87 stack, control and status words, and 80-bit arithmetic |
| `src/interp/x86/sse.zig` | MMX, SSE, and SSE2 |
| `src/interp/mem.zig` | The software TLB and slow path, shared with arm64 |
| `src/jit/x86/lift.zig` | Decoded instruction to IR |
| `src/jit/x86/flags.zig` | EFLAGS' lazy forms and their lowering on each host |
| `src/jit/` | The shared layer: `ir.zig`, `opt.zig`, `regalloc.zig`, `emit/{wasm,arm64,x64}.zig`, `cache.zig`, and `codemem.zig`, as [a64-jit](a64-jit.md) lays them out |
| `src/vmm/ia32.zig` | The vmm backend for 386 guests: Backend, AddressSpace, and Vcpu over both tiers |
| `tools/x86inv.zig` | The inventory tool |

The table is where Zig earns its keep over v86's setup. v86 generates Rust from JavaScript at build time to get a decoder, a JIT dispatcher, and an analyzer from one table. Here the table is a comptime array, and `decode.zig`, `exec.zig`'s dispatch, and `lift.zig` each `inline for` over it, so there's no generator and no generated file.

`src/interp/x86/` and `src/jit/x86/` are named for the instruction set, not for 386, so a later amd64 front end can share the decoder and most of the semantics.

### State

```zig
pub const Cpu = struct {
    r: [8]u32,             // EAX, ECX, EDX, EBX, ESP, EBP, ESI, EDI, in encoding order
    eip: u32,
    flags: u32,            // the materialized bits: DF, and CF..OF when `lazy` is none
    lazy: Lazy,            // the last flag-setting operation: kind, size, operands, result
    seg: [6]u16,           // selectors, for the Ureg and for segment loads
    fs_base: u32,
    gs_base: u32,
    fpu: X87,              // st[8] as f80, TOP, tag word, control and status words, last IP and opcode
    xmm: [8]u128,
    mxcsr: u32,
    retired: u64,
};
```

`getUreg` and `setUreg` copy the general registers, EIP, EFLAGS (materialized), and selectors to and from `ia32.Ureg`. `getExtra` and `setExtra` copy `X86Extra`'s FXSAVE image field for field, since the image is the native layout of this state, with no per-register conversion as Unicorn needs. MMX registers alias the x87 registers' significands, and an MMX instruction sets TOP to 0 and the tag word to valid, as the hardware does.

### Decoding and T0

`decode.zig` reads up to 15 bytes, the architectural limit, across a page boundary through the TLB if it has to. An instruction that crosses into a page without execute permission, or an unmapped one, faults at the instruction's address with the second page's address as the fault address, as hardware does.

Variable-length code can't be predecoded a page at a time as 0019 does for arm64, since a page has no fixed instruction boundaries and a jump can land anywhere. T0 instead caches decoded blocks: a block starts at a guest address it was asked to run, runs to the next control transfer or the end of its page, and is stored in a per-page table keyed by start offset. A block is a list of decoded instructions with a handler each, and T0's loop is 0019's labeled `switch`. The cache follows [a64-jit](a64-jit.md)'s code cache rules: keyed by the page's arena offset, and dropped by the same invalidation.

### Flags

EFLAGS' arithmetic flags are lazy in both tiers, as in v86 and QEMU: a flag-setting instruction records its operation kind, operand size, operand, and result, and a flag is computed only when it's read. CF, ZF, SF, and OF are a compare or two from those; PF is a table lookup on the result's low byte; AF is `(a ^ b ^ result) & 0x10`. `INC` and `DEC` leave CF alone, so their kind carries the CF from before.

In T1 this is [a64-jit](a64-jit.md)'s `flags` value, with x86's own operations (`eflags.add`, `eflags.sub`, `eflags.logic`, `eflags.inc`, `eflags.dec`, `eflags.shift`, and `eflags.mul`) and a `cond` over x86's sixteen conditions. Flag liveness in `opt.zig` drops a flags value that nothing reads before it's overwritten, which is most of them: in compiled C, a `cmp` or `test` is nearly always followed by the `jcc` that reads it, and every `add` or `sub` between them leaves flags no one reads.

- **x86-64 hosts** keep live flags in the host's EFLAGS when nothing between the setter and the reader clobbers them, so `cmp; jcc` lowers to `cmp; jcc`. Otherwise they're computed from the recorded operands.
- **arm64 hosts** map ZF, SF, CF, and OF to Z, N, C (inverted for subtraction, since arm64's carry is "no borrow"), and V for `cmp` and `sub` followed by a conditional branch or `setcc`. PF and AF are always computed from operands, which is rare.
- **wasm** computes only the conditions read, as integer compares, the way v86's `gen_getzf` and friends do, and keeps the last operation's operands in locals for the next instruction.

At a region exit or around a helper, a live flags value is stored to `lazy`, not materialized; T0 and the Ureg materialize it when they need the bits.

### Memory

Through the shared TLB of [a64-jit](a64-jit.md)'s Memory section, with nothing 386-specific except two points:

- **Addresses are 32 bits.** On 64-bit hosts a guest address is zero-extended before the TLB lookup, and an effective-address computation wraps at 4 GiB, as on the hardware. 16-bit addressing (`0x67`) wraps at 64 KiB, and is handled by T0 alone.
- **FS and GS overrides** add the segment's base to the effective address before the lookup. Other overrides are dropped by the decoder.

x86 allows unaligned access anywhere, so the fast path's alignment check is only the page-crossing check. A crossing access takes the slow path, which does it as two partial accesses, both checked before either writes, so a fault on the second page leaves memory unchanged.

A page with compiled or cached code has no write TLB entry, as [a64-jit](a64-jit.md) specifies, so a store to it drops that page's translations. That covers what's usual on x86 and not on arm64: code and data on the same page (Linux's i386 signal trampolines, a `mprotect`ed page written and executed, or a JIT), with no `IC IVAU` to say when. 9front's text is read-only, so it never takes this path.

### Control flow and regions

Regions, chaining, indirect branches through the jump cache, the exit-request check at region entry and back edges, and exits all follow [a64-jit](a64-jit.md). For 386:

- **Calls** (`CALL rel32`) continue at their target, as a trace, and push the return address. **Returns** are indirect branches. The common 8c and gcc `call next; pop reg` idiom for position-independent code is lifted as a constant load, since the pushed value is known.
- **`REP` string instructions** are a helper loop, not unrolled code: it moves or fills up to a page at a time with the host's memory functions when the direction and overlap allow, checks the exit request between pages, and keeps ECX, ESI, and EDI exact, so a kick or a fault leaves a restartable instruction, as on hardware. `REP CMPS` and `REP SCAS` are a byte, word, or dword loop in the helper.
- **`DIV` and `IDIV`** check for a zero divisor and for overflow (a quotient too large for the destination, such as `INT_MIN / -1`) before they divide, and exit with a divide error instead. No host trap is involved.
- **Self-referencing EIP.** Compiled code is keyed by page arena offset, as in [a64-jit](a64-jit.md). EIP-relative values (the pushed return address, the `call next` idiom, and fault EIPs) are computed from the guest address the region was entered at, so the same text mapped at two addresses, as a Linux shared library can be, compiles twice but never runs with the wrong EIP.

### x87

The x87 unit is an eight-entry stack of 80-bit values with a TOP pointer, a tag word, a control word with precision and rounding control and exception masks, and a status word with exception flags and the condition codes `FCOM` and `FPREM` set. 8c uses it for every `float` and `double`, so 9front's 386 programs depend on it.

- **Arithmetic is software,** in `f80.zig`: a Zig port of the `extF80` subset of Berkeley SoftFloat 3e (BSD-3) that v86 uses, with its rounding modes, precision control, and exception flags. Results are the same bits on every host and in wasm. Zig's own `f80` type isn't enough: it rounds to nearest only, ignores precision control, and reports no exception flags.
- **Precision control** is honoured: with PC set to 53 or 24 bits, results are rounded to that significand, as on hardware.
- **Rounding control** is honoured by every operation, which is what makes the `fldcw; fistp; fldcw` truncation idiom work.
- **Exceptions** are masked by default (FCW `0x037F`). An unmasked exception sets the status word's summary bit and faults with vector 16 at the next waiting x87 instruction, as on hardware.
- **In T1,** x87 operations are `call.helper`s on the `Cpu`'s stack. A region keeps TOP in a register, so `FXCH` and the stack pushes and pops between helpers are register renames, not memory traffic. QEMU's x87 is software too (`floatx80`), so this is Unicorn's speed class, not worse.

### SSE and SSE2

- **Integer SIMD** (`PADD*`, `PSUB*`, `PAND`, `PXOR`, `PCMPEQ*`, `PSHUFD`, `PUNPCK*`, `MOVDQA`, `MOVDQU`, and the rest) lowers to [a64-jit](a64-jit.md)'s vector operations: SSE2 on x86-64 hosts, AdvSIMD on arm64, and wasm SIMD.
- **Scalar and packed FP** have x86's rules, which differ from arm64's: the default NaN is negative (`0xFFC00000`, `0xFFF8000000000000`), NaN propagation takes the first operand's NaN, `MINSS` and `MAXSS` return the second operand when either is a NaN or both are zero, and `CVTTSD2SI` of a NaN or an out-of-range value gives `0x80000000`. MXCSR's DAZ, FTZ, and rounding control apply, and its flags are sticky.
- On **x86-64 hosts** that's the hardware's behaviour, so FP instructions run as themselves under the guest's MXCSR, loaded at region entry when it differs from the host's.
- On **arm64 hosts and wasm**, FP uses host instructions with a guard, as [a64-jit](a64-jit.md) does on x86-64: a NaN result, a non-default rounding mode, or DAZ or FTZ sends the operation to a helper. Flags come from software for the operations whose flags are read.

### Concurrency

[a64-jit](a64-jit.md)'s Concurrency section applies: every vCPU runs compiled code at once, with no guest lock, shootdown by kick and wait, and the same cache flush. What's different is x86's memory model, TSO, which is stronger than arm64's:

- **`LOCK`-prefixed instructions and `XCHG` with memory** are host atomics: `rmw` and `cas` in the IR, `lock`-prefixed on x86-64 hosts and LSE or exclusive loops on arm64. `CMPXCHG8B` is a 64-bit compare-and-swap. An unaligned or page-crossing locked access takes the slow path, which does it under a backend-wide lock (QEMU's "stop the world" for split locks, made cheaper by being rare).
- **x86-64 hosts** are TSO, so plain loads and stores map one to one, and `MFENCE` is an `mfence`.
- **arm64 hosts** aren't TSO. Every guest load becomes a load-acquire (`LDAPR`, or `LDAR` without FEAT\_LRCPC) and every guest store a store-release (`STLR`), which gives TSO. That costs some speed on stores; the spike in Implementation, step 5, measures how much. Where it's too much, an option makes a machine's vCPUs take turns, as today's guest lock does, with plain accesses. Apple's hardware TSO mode, which Rosetta uses, has no public API on macOS, and is in Open issues.
- **wasm** runs one coroutine at a time on one thread, so ordering never arises.

### The browser host

In web builds, `src/vmm/ia32.zig` is compiled into `h9.wasm`, and T1 uses the wasm emitter. v86 goes away:

- **No guest kernel.** The shim, its GDT, IDT, TSS, and page tables, and the real-mode start go. A syscall or fault is a return from `run`, with no halt and no register block to edit, so a round trip costs what T0's does: tens of nanoseconds, against v86's 3 µs.
- **Preemption** is the exit request with a budget: `run` sets an instruction budget that the region entry and back edge checks count down, and returns `.interrupted` when it's spent. The ring-0 rebuild of the Ureg goes, since the Ureg is just the `Cpu`.
- **One module.** `v86.wasm`, its instantiation order, the 16 MiB base, the pinned register-block offsets, `tests/web/v86-layout.mjs`, and the `codegen_finalize_finished` queue all go. Guest pages are `allocPages` from h9's own heap, and the TLB holds their addresses directly.
- **Code generation** follows v86 and rv64.js: a region's entry gets hot in T0 (a counter per entry, threshold measured, starting at v86's 200,000 heat scaled to regions), then regions are batched into a module, compiled through an import (`h9_jit_compile`) in `h9-web.js`, and installed in a function table that `h9.wasm` exports. Generated modules import `h9.wasm`'s memory, its table, and the helper functions it exports, so a helper call is a wasm call, not a crossing into JavaScript. Chaining between modules uses wasm tail calls (`return_call_indirect`), which every engine with JSPI has.
- **JSPI** is unchanged: generated code never parks. A region that needs the kernel exits to `run`, which parks only after returning, as v86's `main_loop` does now.

`vmm.Kind.v86` and `--backend v86` remain as aliases of `emu` in web builds for one release, then go. The browser host's proposal is otherwise unchanged.

### Build and selection

- `-Demu=zig` from [zig-interpreter](0019-zig-interpreter.md) builds this backend for 386 guests as well as arm64, and `-Dno-jit` from [a64-jit](a64-jit.md) builds T0 alone.
- `vmm.Kind` keeps one `emu`. The backend picks `ia32.zig` or `a64.zig` by the binary's architecture, and an amd64 binary still fails with `WrongArch` on a build without Unicorn.
- `zig build web` no longer fetches or installs `v86.wasm`. `scripts/pins.sh` and `scripts/fetch.sh` drop v86.
- `-Demu=unicorn` stays for `h9-emu`, for amd64 guests, and as the lockstep reference.

### Testing

The four checks of [a64-jit](a64-jit.md), with 386 specifics:

- **T1 against T0, by region,** under `zig build integration`, natively and under Node.
- **Unicorn lockstep** for T0, extending 0019's `src/vmm/lockstep.zig` to i386. It compares the general registers, EIP, the materialized EFLAGS, the selectors, the FXSAVE image (x87 stack, control, status, and tag words, XMM, and MXCSR), and the bytes each store wrote.
- **The host as oracle on x86-64.** T0's semantics for each register-only instruction, flags included, are checked against the host CPU: the instruction runs natively in 32-bit compatibility mode in a stub on Linux, from random register contents. That covers flags, x87 corner cases, and SSE, where lockstep is slowest.
- **v86's own tests.** v86's `tests/nasm` suite assembles random sequences of each encoding and compares results with a real CPU. Its generator (BSD-2) is the model for `zig build fuzz-x86`, which runs the sequences on T0 and T1 in an address space with guard pages and compares them with Unicorn and, on x86-64 Linux, the host.

### Speed targets

| Measure | Target |
| --- | --- |
| The bench loop, in a 386 version beside `tests/bench.zig`'s arm64 and amd64 ones, on an arm64 host | At most Unicorn's time for 386 on the same host |
| Mixed compute: 0019's spike programs built with 8c, and Alpine x86's `python3` and `sqlite3` | At least 0.5 G guest instructions/s on an M3 Max, and faster than Unicorn on each |
| x87-heavy code (the FP loop built with 8c) | Within 1.5× of Unicorn's time |
| Threads | Four busy guest threads at least 3× faster than one on an x86-64 host, and at least 2× on arm64 with the TSO lowering |
| Syscall round trip | Under 100 ns natively; under 300 ns in Chromium, against v86's 3 µs |
| Browser compute | At least v86's speed on the same programs under Node and Chromium, as rv64.js measured against v86 |
| Browser size | `h9.wasm` grows by less than the size of the `v86.wasm` it replaces |

They aren't gates; correctness is. They go in SPEC.md's Limits and selection, next to Unicorn's, HVF's, and (until it's retired) v86's.

## Rationale

**Why rewrite v86, rather than keep it in the browser.** v86 is excellent at what it is, a PC, and that's the problem: h9 uses its CPU at ring 3 and spends a guest kernel, a pinned register layout, a forced instantiation order, and a ring-0 rebuild on every preemption to get there. Its JIT can't be reused natively, since it emits only wasm, and its interpreter is coupled to its full-system TLB and segmentation. What's reusable is its design and its semantics, which are BSD-2, and that's what this proposal takes. A user-mode core gets rid of the shim, makes a syscall a function return, and lets one core serve the browser and native hosts.

**Why not v86's code, ported line by line.** v86's instruction semantics are written against its full-system state: every memory access goes through segment checks and the paging TLB, and every instruction knows about CPL and real mode. Removing that is most of the work of porting it. The table, the lazy flags, the x87 and SSE semantics, and the JIT's structure port directly, and the files that take from them keep v86's BSD-2 notice.

**Why a 386 front end on a64-jit's layer, not a second JIT.** The IR, register allocation, the TLB, exits, chaining, the code cache, executable memory, and three emitters are most of a JIT, and none of it depends on the guest. Two front ends on one layer means each emitter is written once and tested by two instruction sets, and the arm64 and 386 work can proceed in either order: whichever lands first builds the shared files.

**Why wasm first.** 386 is the browser host's only architecture, the browser is where v86's costs are paid, and no other proposal needs the wasm emitter as soon. Natively, Unicorn already runs 386, and the native emitters come from [a64-jit](a64-jit.md).

**Why a region JIT, not v86's page modules, natively.** As [a64-jit](a64-jit.md) says: v86 batches by page because instantiating a wasm module is expensive. In wasm this proposal batches too; natively it follows control flow.

**Why software x87.** 80-bit precision, precision control, rounding control, and exception flags have no host equivalent except an x87 unit, which only x86-64 hosts have, and using it there would make results host-dependent. v86 and QEMU both use software. The cost is confined to x87-heavy 9front code, and is Unicorn's cost too.

**Why port SoftFloat, not vendor it.** Vendoring the C into `third_party/` would be the quickest start, and is the fallback. But the core is meant to be dependency-free Zig, as 0019 wants, and the `extF80` subset is about 2,500 lines whose test vectors (TestFloat's) come with it.

**Why TSO by acquire and release on arm64.** The alternatives are worse. Plain accesses break real programs (Go's runtime and any lock-free queue rely on TSO). Barriers around every access cost more than `LDAPR` and `STLR`, which Apple's cores and Graviton 2 and later implement cheaply. Taking turns, as Unicorn does, gives up the parallel threads that are half the reason to replace it, and stays as an option.

**Why not other x86 translators.**

- **QEMU's TCG** (through Unicorn) is GPLv2.
- **Box86 and Box64's 32-bit mode** (MIT) translate x86 to arm64 well, but are built around running Linux userland with host libraries, are Linux-only and arm-only, and have no interpreter tier or wasm. Their handling of flags and memory ordering on arm64 (the "strongmem" options) is worth reading.
- **FEX-Emu** (MIT) is a C++ x86 and x86-64 to arm64 JIT for Linux, with its own IR and a large runtime. Same objections as Dynarmic in [a64-jit](a64-jit.md).
- **Blink** (ISC) emulates x86-64 Linux programs with a small JIT, but not 386 user mode as h9 needs it, and not in wasm with a JIT.

**Why not run 386 natively on x86-64 hosts.** A 64-bit Linux process can run 32-bit code in a compatibility-mode segment, so the [native backend](0095-native-backend.md) and KVM could run 386 programs at full speed on x86-64 hosts. That's worth its own proposal, and [linux-i386](0105-linux-i386.md)'s Open issues already lists it. It doesn't help arm64 hosts, Macs, or the browser, which are where 386 runs today.

## Compatibility

- **CLI and exit codes.** Unchanged. `--backend v86` is an alias of `emu` in web builds for one release, then a usage error, as an unknown backend is. `--version` and `--check` name the tier, as [a64-jit](a64-jit.md) has them.
- **`Machine.Options` and the vmm interface.** Unchanged. `vmm.Kind.v86` goes once the alias does.
- **Guests.** CPUID and `AT_HWCAP` report the same features, which they already do. A 9front 386 process sees the same Ureg, notes, and FP state. The FXSAVE image's last-instruction and last-operand fields, which Unicorn leaves zero, are filled.
- **The browser host.** The page's JavaScript API is unchanged. `zig-out/web/` loses `v86.wasm` and `LICENSE.v86`, and `h9.wasm` grows. JSPI is still required. Generated code needs wasm tail calls and fixed-width SIMD, which every JSPI engine has.
- **Build.** `-Demu=zig` covers 386. The web build no longer needs `scripts/fetch.sh` for v86.
- **Licences.** h9 stays MIT. Files derived from v86 keep its BSD-2 notice, and `f80.zig` keeps SoftFloat's BSD-3 notice; both are listed in the release notices.
- **Root tree and `third_party/`.** Unchanged.

## Security

Everything in [a64-jit](a64-jit.md)'s Security section applies: every access through the TLB check, no host addresses reaching the guest, W^X, no host faults for guest behaviour, and the fuzzer and T1-versus-T0 check in CI.

**386-specific risks.**

- **Instruction length.** A decoder that reads past 15 bytes or past a page it hasn't checked could read host memory. `decode.zig` reads only through the TLB, and stops at 15 bytes with an undefined-opcode fault.
- **Register fields.** ModRM and SIB fields index 8-entry arrays, and the x87 stack index is masked to three bits, so no guest value indexes past them.
- **REP helpers** move at most a page between checks, and check both pages' permissions before they touch either.
- **Segment bases** come only from the selector table, which holds bases the kernel set through `set_thread_area`; the guest can't load an arbitrary descriptor.

**In the browser,** the boundary is better than v86's: there's no guest kernel at ring 0 whose page tables are the only thing between a process and the rest of guest RAM, and every guest access is checked against the address space's own pages. Generated wasm runs in the same Worker with the same memory, as v86's does now.

The sandbox policy is unaffected: it's enforced in the kernel, above the vmm layer, the same on every backend.

## Done when

- `zig build integration -Demu=zig -Darch=386` with `H9_TEST_BACKENDS=emu` passes every `[baseline]`, `[linux-i386]`, `[linux-personality]`, and `[linux-threads]` case on T1 on macOS arm64, Linux arm64, and Linux x86\_64, and on T0 on Linux x86\_64.
- `zig build integration -Dweb` passes every case it passes on v86 today, with `H9_TEST_BACKENDS=emu`, and `zig build web-test`'s Playwright check passes in Chromium.
- The integration suite passes under the T1-versus-T0 check mode, natively and under Node, with no divergence.
- `zig build integration -Demu=lockstep -Darch=386` passes the `[baseline]` cases with no divergence.
- `zig build test -Demu=zig` passes `tests/backends.zig`'s i386 cases on T0 and T1.
- New cases in `tests/x86.zig`, tagged `[x86-jit]`:
  - `test "a divide by zero faults with vector 0 and EIP at the DIV [x86-jit]"`
  - `test "fistp truncates under a control word with RC set to chop [x86-jit]"`
  - `test "x87 results are the same bits on every host [x86-jit]"`
  - `test "a REP MOVSB interrupted by a kick resumes exactly [x86-jit]"`
  - `test "a store into the page being executed takes effect at the next instruction [x86-jit]"`
  - `test "an instruction crossing into an unmapped page faults at its first byte [x86-jit]"`
  - `test "four threads incrementing with LOCK XADD lose nothing [x86-jit]"`
  - `test "a store-buffering litmus test never shows a non-TSO result [x86-jit]"`
  - `test "loading an unknown selector into GS faults with vector 13 [x86-jit]"`
  - `test "CPUID reports SSE2 and no AVX [x86-jit]"`
- `zig build fuzz-x86` runs for an hour on arm64 and x86-64 hosts with no divergence.
- `zig build bench -Demu=zig -Darch=386` and the web bench report the Speed targets, and SPEC.md gives them.
- Demos: `h9 --arch 386 --backend emu --root .local/linux/alpine-386 /bin/busybox sh -c 'echo hello; ls /etc | wc -l'` from a default MIT build on a Mac without Unicorn, and the demo page from `zig build web` running rc with no `v86.wasm` beside it.

## Implementation

1. **Inventory.** `tools/x86inv.zig` over 9front's `/386/bin`, Alpine x86 (minirootfs, `python3`, `sqlite`, and `git`), and the Go `linux/386` fixtures, with the table as its decoder. Its report ranks instruction forms for lifting, and settles 16-bit addressing and MMX's real use. Record the summary in this proposal's Updates.
2. **T0.** The table, decoder, integer and string semantics, lazy flags, and `src/vmm/ia32.zig` with T0 alone. Unicorn lockstep for i386. `tests/backends.zig`'s i386 cases and the `[baseline]` cases without FP pass natively.
3. **x87, MMX, SSE, and SSE2 in T0,** with `f80.zig` and TestFloat's vectors, and the host-as-oracle check on x86-64 Linux. The `[linux-i386]` cases pass.
4. **T0 in the browser.** `ia32.zig` in `h9.wasm`, budget preemption, and `zig build integration -Dweb` on `emu` beside `v86`. This retires the shim and the register-block pins as soon as T0 is fast enough to be the default, which is measured against v86 here.
5. **The shared layer and the wasm emitter,** with [a64-jit](a64-jit.md): the IR with x86's flags operations, `call.interp` taking a decoded-instruction handle rather than a 32-bit word, lifting, regions batched into modules, tail-call chaining, and the T1-versus-T0 check under Node. A spike of the arm64 TSO lowering's cost on an M3 Max. Make `emu` the web default and alias `v86`.
6. **Native T1.** Lifting for the arm64 and x86-64 emitters, whichever [a64-jit](a64-jit.md) has built, with the TSO lowering on arm64, and the `[x86-jit]` cases on every host. Bench against Unicorn and v86 and record it in Updates.
7. **Retire v86 and switch the default.** Remove `src/vmm/v86.zig`, `src/arch/i386/shim.S`, and v86 from `scripts/pins.sh` and `scripts/fetch.sh`, update SPEC.md's backend, emulator, and browser-host sections and the browser host's MANUAL.md section, and set `status: implemented`.

## Open issues

- **The shared layer's contract.** Two additions to [a64-jit](a64-jit.md)'s IR: flags operations defined per front end (x86's `eflags.*` beside arm64's `nzcv.*`), and `call.interp` taking a front-end handle to a decoded instruction, since x86 instructions aren't one word. Both are to be settled between the two drafts before either is accepted.
- **Hardware TSO on Apple silicon.** Rosetta runs x86 code with the cores' TSO mode on. macOS exposes no API for it outside Rosetta. Linux on Apple silicon (Asahi) has `PR_SET_MEM_MODEL`. Where it's available, plain accesses would do.
- **Copying instructions on x86-64 hosts.** As [a64-jit](a64-jit.md) copies register-only instructions on arm64 hosts, most of a 386 instruction stream is valid x86-64 that runs with the same 32-bit results, given remapped registers and re-encoded `INC` and `DEC` (whose one-byte forms are REX prefixes in 64-bit mode). That's flags for free and could approach native speed for integer code. Measure after step 6.
- **Running 386 natively on x86-64 hosts** in a compatibility-mode segment, on the native backend and KVM (Rationale). Its own proposal.
- **Sharing translations across processes,** as in [a64-jit](a64-jit.md): text loaded afresh for each exec compiles again. 9front's rc pipelines would gain the most.
- **A double-precision x87 fast path.** If the inventory shows hot x87 code running with precision control at 53 bits, host `f64` arithmetic gives the same bits under a guard on the control word, and would be much faster than `f80.zig`.
- **SSE3 and later.** Advertising SSSE3 and SSE4.1 would let OpenSSL and Go use faster paths, at the cost of lifting `PSHUFB` and friends on every host. Decide from the inventory and the benchmarks.
- **amd64.** A front end for amd64 guests on the same layer, sharing the decoder and semantics, would retire Unicorn completely. Its own proposal.
