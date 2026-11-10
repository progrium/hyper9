# src/jit: the emulator's JIT layer

Shared by ha64 (arm64 guests), h86 (386 guests), and hx64 (amd64 guests,
in progress on the `hx64` branch). Built with `-Demu=zig`; tested with
`zig build vcpu`.

The specs describe what's built: [spec/jit.md](../../spec/jit.md) for this
layer, and [spec/h86.md](../../spec/h86.md) and [spec/ha64.md](../../spec/ha64.md)
for the two CPUs.

## Contracts

These are what the parallel work codes against. Each has one owner, and
other work asks the owner for changes rather than editing it.

| File | What it fixes | Owner |
| --- | --- | --- |
| `ir.zig` | The IR: types, ops (append-only, numbered), the builder, the verifier, and the text form | the IR thread |
| `ir_eval.zig` | Every op's reference semantics, and `evalOpC`, the emitters' fallback | the IR thread |
| `ctx.zig` | `Ctx` (all fields 64-bit, so wasm32 shares the layout), exit codes, `EntryFn`, `InterpFn`, `HelperFn`, the context register | the IR thread |
| `../interp/mem.zig` | The TLB entry and table layout, the inline check, and the slow-path signatures (final); `Map` is a stand-in address space | the JIT runtime thread |
| `frontend.zig` | What a front end gives: `lift`, `interp`, its flag group | the IR thread |
| `emitter.zig`, `alloc.zig` | What an emitter takes and gives, and `Allocation` (`spillAll` until linear scan) | the IR thread; `regalloc.zig` belongs to the arm64 emitter thread |

## hx64's contracts

hx64 is h86 in long mode ([hcpu](../../design/hcpu.md), hx64), built in
parallel workstreams on the `hx64` branch
(`/mnt/project-files/hx64/plan.md` in the project). These files fix what
they code against. The contracts thread (S0) owns them: ask it for a
change, in a small commit, rather than editing them.

| File | What it fixes |
| --- | --- |
| `../interp/x86/mode.zig` | `Mode` (`.legacy`, `.long`), the comptime parameter of the table, decoder, T0, Cpu, and lifter |
| `../interp/x86/flags.zig` (`Lazy`), `ir.zig` (`LazyRecord`, `eflags.*` at `i64`) | The lazy flags record: 64-bit operands at record offsets 4, 12, and 20, sizes 1 to 8, with `Flags` 8-aligned |
| `../interp/x86/decode.zig` (`Inst64`, `Rex`, `InstOf`, `decodeIn`) | A long-mode instruction's shape: REX, 64-bit `disp` and `imm`, `rip_rel`, `addr32`, and 4-bit registers |
| `../interp/x86/table.zig` (`Entry.d64`, `inv64`, `rexw`, `slotIn`) | The table's long-mode fields |
| `../interp/x86/cpu.zig` (`Cpu64`, `Exit64`, `CpuOf`, `ExitOf`) | hx64's register file and exits |
| `../interp/x86/exec.zig` (`runIn`, `stepIn`), `../interp/x86/tlb.zig` (`runIn`) | T0's entry points by mode |
| `x86/lift.zig` (`frontendFor`, `liftIn`) | The lifter's entry points by mode |
| `../vmm/zemu.zig` (`Emu` over three Guests) | The Guest interface, with hx64 for amd64 |

Each workstream owns the code behind its entry points:

| Workstream | Owns |
| --- | --- |
| S0, contracts | The files above, `emit/fuzz.zig`'s and `emit/cases.zig`'s lazy-flags cases, and this table |
| A, decoder and table | `../interp/x86/table.zig`'s long-mode rows and lookup, `../interp/x86/decode.zig`'s `decodeIn(.long)` and `effects` |
| B, T0 integer | `../interp/x86/exec.zig`, `../interp/x86/cpu.zig` (but `Cpu64`'s fields), `../interp/x86/flags.zig` (but `Lazy`) |
| C, x87 and SSE | `../interp/x86/sse.zig`, `../interp/x86/x87.zig` |
| D, oracles and tests | `../../tools/x86check/`, `../../tools/x64inv.zig`, `check/gen_x86.zig`, `check/x86.zig`, `check/litmus_x86.zig`, `../vmm/lockstep.zig`, `../../tests/x64.zig` |
| E, the Guest | `../vmm/hx64.zig`, and hx64's part of `../vmm/zemu.zig` |
| F, the lifter | `x86/lift.zig`, `x86/flags.zig`, `x86/helpers.zig`, `x86/t1.zig`, `x86/check.zig` |

## Rules of the IR

- Ops are only added, never renumbered. A new op lands in one change with its
  `ir_eval` semantics, a verifier rule, and a case in `emit/cases.zig`.
  Emitters that don't lower it fall back to `evalOpC` (pure ops) and keep
  working.
- Values are block-local. Guest state crosses blocks and exits through
  `getreg`/`setreg` on the front end's `Cpu`.
- Guest state is exact at every op that can leave: a lifter writes an
  instruction's results before the next load, store, call, or exit.
- `ctx.retired` is exact at every exit, faults included. Every op that can
  leave (`Op.canLeave`: loads, stores, `call.interp`, `poll`, and the exits)
  carries `Inst.retired`, the guest instructions completed since its block's
  last `retire`. Lifters set `Builder.retired` before each guest instruction
  and `emit` stamps it. Emitters add it only on the path out, such as a slow
  path's fault stub, so the fast path costs nothing. A `call.interp` handler
  counts its own instruction when it completes and then leaves. A faulting,
  undefined, or breakpoint instruction isn't retired, and an SVC is.
  Deterministic mode depends on this.
- Faults from IR ops (ir_eval, emitters, and mem.zig's slow paths) set
  only exit_info bits 0..15 (access, fault kind), exit_addr, and exit_pc.
  Guest syndromes such as arm64's ESR are front-end detail, and the vmm
  backend derives them. T1-versus-T0 checks compare only the low 16 bits.
- `cas` goes through `Ctx.slow_cas` on every emitter for now. `MemFlags.rmw`
  makes a load's fault report a write.
- Chaining: `emitter.Code` reports `chain_entry` and its chain sites (one
  per `exit.chain`, up to `max_chains`). An unlinked site falls through to
  the exit, which sets exit_info to the site's executable address
  (cache.zig's contract). `Ctx.jump` points at the vCPU's jump cache
  (`ctx.JumpEntry`, `ctx.jumpIndex`), so `exit.indirect` can look up its
  target inline and jump to the hit's chain entry.
- `Region.tso` says the guest is TSO (h86 sets it). The arm64 emitter then
  uses LDAR and STLR, sends misaligned accesses to the slow path, and fences
  the slow path. ir_eval, x86-64, and wasm ignore it.
- Guest state is exact at every exit, fault stubs included. The one
  deferral is `pending.flags`: packed flags merged into their slot (keeping
  the slot's other bits, such as EFLAGS' DF) only on a way out, or before a
  call. Emitters may write it at once instead, which is always
  correct.
- `pending.flags` with aux2 = 2 writes eflags lazily: an `ir.LazyRecord` of
  the producing op's operands at aux + 4 (h86's flags.Lazy layout and
  kinds: a 4-byte header, then a, b, and res as u64s, narrower operands
  zero-extended), with the bits word left alone. It doesn't mix with
  aux2 = 1 at one offset in a region. Readers of the bits word
  materialize first. `eflags.*` take i8 to i64 operands; an emitter that
  doesn't lower a width falls back to `evalOpC`.
- `call.helper` with `aux2 = ir.helper_no_regs` promises that the helper
  touches none of the Cpu bytes the region names, so emitters may skip the
  write-back and reload around it, and pending flags stay pending.
- `MemFlags.same_page` is only a hint (reuse an earlier access's TLB
  lookup). Emitters still compare the page numbers, so a wrong hint is
  slow, never unsafe. Ignoring it is correct.
- `exit_pc` is the PC to resume at, except for a fault, where it's the
  faulting instruction.
- FP and vectors (`fp.*` at 224, `v.*` at 256; `Op.isExt`) take an
  `ir.ExtAux` in aux: the guest's FP environment as the lifter saw FPCR or
  MXCSR (rounding, DAZ, FZ, the NaN rule, and Arm's or x86's rules), an
  immediate, and a lane size. FP values are i16, i32, and i64 bit patterns,
  or lanes of a v128; ir_eval computes them with softfloat.zig, never the
  host's FPU. An `fp.*` op whose aux2 is nonzero ORs its exceptions, in the
  guest's layout, into the u32 at Cpu offset aux2 - 1, so it writes guest
  state, and passes that move or drop guest writes must treat it as a
  barrier for that word. None of them is `isPure`: an emitter that doesn't
  lower one calls `ir_eval.evalExtC(ctx, fallbackCode(op, ty, ta), io,
  aux, aux2)`, with a, b, and c staged 16 bytes each at `io` and the
  result written back to io[0..16]. `spillAll` gives a v128 two slots.
  `emit/cases.zig`'s `generateExt` has their cases, apart from `generate`'s
  until every emitter takes them.
- Flags are values, per guest: `nzcv.*` and `eflags.*`. `ir_eval` computes them
  eagerly in the guest's packing; emitters may keep them lazy.

## Testing an emitter

`emit/cases.zig` generates IR cases (each op at each width, flags and
conditions, memory with the slow path and faults, loops, polls). An emitter
passes when every case ends in the same exit, exit PC, registers, and memory
as `ir_eval`: natively for arm64 (`emit/arm64.zig`'s test), and under Node
for wasm (`tests/jit/`).

## Testing a front end

Lift, verify, run in `ir_eval`, and compare with T0 from the same state.
`a64/tracer.zig` does that for a counted loop, then runs the same region
natively and in wasm.
