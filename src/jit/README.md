# src/jit: the emulator's JIT layer

Shared by ha64 (arm64 guests) and h86 (386 guests). Built with
`-Demu=zig`; tested with `zig build vcpu`.

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
- `exit_pc` is the PC to resume at, except for a fault, where it's the
  faulting instruction.
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
