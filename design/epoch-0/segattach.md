---
issue: 4
slug: segattach
title: segattach and shared segments
status: implemented
created: 2026-11-03
authors: [progrium]
depends: []
areas: [kern, vmm, tests]
branch: [main]
---

# Proposal: segattach and shared segments

Nov 3, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

Serve 9front's segment calls: `segattach`, `segdetach`, `segfree`, `segbrk`, and `segflush`. A process can then attach memory segments of the two classes every 9front system has, `shared` and `memory`, beside its text, data, and stack. They follow 9front's rules for placement, fork, and exec. Segments are Zig objects already, so this extends `src/segment.zig` and `syscall.zig`, and serves `/proc/n/segment`. Named global segments (`#g`) and device memory stay out of scope.

## Background

This was part of milestone M5 ("servers") in SPEC.md, before milestones became proposals ([#1](proposals.md)). SPEC.md's process model table had a row for it:

| Plan 9 call | Implementation |
| --- | --- |
| `segattach` / `segdetach` / `segfree` | Named shared segments, backed by one set of guest-physical pages |

The row said "named" segments, which isn't how `segattach` works. Its `class` argument names a kind of segment, not a segment. A `shared` segment is anonymous: whoever attaches it gets a fresh one, and its children share it by inheriting it across `rfork`. Segments with names that unrelated processes can attach are a separate device, `#g` ([segment(3)](https://github.com/9front/9front/blob/602faae9a52f342a40b086d10b23c71c82dd52d7/sys/man/3/segment)), which `segattach` consults first (see Rationale).

### 9front's behaviour

From the pinned revision (`602faae9`), mostly `port/segment.c` and `port/sysproc.c`:

| Call | Number | Behaviour |
| --- | --- | --- |
| `segattach(attr, class, va, len)` | 30 | `va` is rounded down to a page, and `len` up so the segment ends on one. With `va` 0, the kernel picks a hole: it starts at the stack segment's base minus `len` and steps below each overlapping segment until one fits. The segment may not overlap another, may not reach `USTKTOP`, and may not start at 0. `class` is looked up among `shared` (`SG_SHARED`) and `memory` (`SG_BSS`), each at most `SEGMAXSIZE`: 8 GiB on arm64 and 64 GiB on amd64. The attributes keep `SG_RONLY`, `SG_CEXEC`, and the few others a class allows. Returns the base. |
| `segdetach(addr)` | 31 | Detaches the segment containing `addr` (or starting at it, if empty) from the caller. The stack can't be detached. The pages are freed when the last process using them lets go. |
| `segfree(va, len)` | 32 | May free the physical pages in the span while leaving the addresses valid. They read as zeros again for `memory` and `shared` segments, and are reloaded from the file for data and text. "May not free all or even any", says the manual. |
| `segbrk(saddr, addr)` | 12 | Moves the top of the segment containing `saddr` to `addr`, as `brk_` moves the bss. Refused for text, data, and stack. Shrinking a segment others share fails with `Einuse`. |
| `segflush(va, len)` | 33 | Flushes caches for the span. |

- **fork:** `rfork` gives the child the parent's `shared` segments, the same pages. It copies `memory` segments, or shares them with `RFMEM`, exactly as it treats bss.
- **exec:** keeps every attached segment except those with `SG_CEXEC`. segattach(2) says exec also releases a segment that overlaps the new image. The pinned `sysexec` doesn't check, because the image goes at `UTZERO` and segments are placed below the stack, so the two don't meet in practice.
- **Slots:** a process has ten, of which text, data, bss, stack, and exec's temporary stack use five, so five attached segments at most.
- **Errors:**

| Error | String |
| --- | --- |
| `Ebadarg` | "bad arg in system call" |
| `Enovmem` | "virtual memory allocation failed" |
| `Esoverlap` | "segments overlap" |
| `Einuse` | "device or object already in use" |

- **`/proc/n/segment`** prints a line per segment: the type name, an `R` for read-only, a `P` for profiling, base, top, and reference count, as `"%-6s %c%c %8p %8p %4ld\n"`.

### Who uses it

In the pinned userland:

- **APE's `select`.** `_buf.c` attaches a `shared` segment of buffers, then forks one reader process per buffered fd. The forked readers fill buffers that the parent drains. So any APE program that calls `select` needs this.
- **`ip/telnetd`** shares its console state through a `shared` segment.
- **`seg`** (`/bin/seg`) attaches a segment of any class and reads or writes a word in it.
- **`scat`** calls `segfree`.

The rest want hardware: `aux/vga`'s MMIO classes, `reform/pm`'s SoC registers, and `vmx`'s guest memory as a sticky `#g` segment. h9 has none of those.

### h9 today

`src/segment.zig` has text, data (data and bss together, which `brk_` moves) and stack segments. Each is a list of chunks of backend pages, mapped into every address space it's attached to and freed when the last detaches. `rfork` shares text, copies the stack, and shares or copies data by `RFMEM`. Each process has its own address space even with `RFMEM`, so a segment attached later by one process isn't seen by another; 9front's per-process segment tables behave the same. Pages are allocated when a segment is created or grows, never on fault, except the stack's growth down. `brk` stops at `stack_floor`, the lowest address the 16 MiB stack can reach. None of calls 12 or 30 to 33 is served: each posts "sys: bad sys call".

## Proposal

### Segments

`segment.Kind` gains `shared` and `memory`. A `Segment` gains two attributes: `cexec`, and read-only, which is already its `perms`.

`Segs` gains `extra: [max_extra]?*Segment`, with `max_extra = 5` as in 9front, kept in attach order. `/proc/n/segment` lists them in that order.

### `segattach`

1. Copy `class` out of guest memory as other strings are (at most 32 bytes). Anything but `shared` or `memory` is `Ebadarg`.
2. Round `va` and `len` as 9front does. A `len` of 0 after rounding is `Ebadarg`.
3. With `va` 0, find a hole the way 9front does: start at `stack_floor - len` and step below any overlapping segment. The text, the data up to its break rounded up to a page, the stack from `stack_floor` to `USTKTOP`, and the extras all count as overlapping. Running out of address space is `Enovmem`.
4. Check `va != 0`, `va + len <= USTKTOP`, and no overlap, or fail with `Ebadarg` or `Esoverlap`. Check `len <= SEGMAXSIZE` for the architecture, or fail with `Enovmem`. If the segment overlaps only the data segment's headroom, trim the headroom (see `brk_` and the extras).
5. Take a free slot, or fail with `Enovmem`.
6. Create the segment with zeroed pages, all of them now (see Rationale), so `--memory` counts them. Running out is `Enovmem`.
7. Map it read-write, or read-only with `SG_RONLY`, and never executable. Return `va`.

Attribute bits other than `SG_RONLY` and `SG_CEXEC` are ignored, as 9front ignores what a class doesn't use.

### `segdetach`, `segfree`, `segbrk`, `segflush`

- **`segdetach(addr)`:** find the extra containing `addr`, or starting at it. Text, data, and stack are `Ebadarg`; 9front refuses only the stack, but h9's text and data aren't separable from the image (see Open issues). Detach it from the caller's address space, which frees it if the caller was the last user. Free its slot.
- **`segfree(va, len)`:** for spans inside an extra, zero the pages in place. They stay allocated, so `--memory` doesn't change, and every process sharing a `shared` extra sees the zeros, as on 9front. For text, data, and stack it does nothing, which the manual allows. Return 0. A span outside every segment is `Ebadarg`.
- **`segbrk(saddr, addr)`:** for the extra containing `saddr`, move its top to `addr`, rounded up. It can grow only into free address space, below the next segment above it or `USTKTOP`, else `Esoverlap`. It can shrink unless other address spaces share it, else `Einuse`. `addr` 0 returns the base. `saddr` in text, data, or stack is `Ebadarg`; 9front allows its bss here, which `brk_` covers. This is `Segs.brk`'s logic, moved into `Segment` so both use it.
- **`segflush(va, len)`:** check the span is inside a segment, then return 0. Guest code never runs from these segments, and the vmm backends keep the data side coherent across vCPUs.

### `brk_` and the extras

`brk_` stops below the lowest extra above the data segment, not only at `stack_floor`, as 9front's `ibrk` refuses to overlap. `Segs.brk`'s headroom step is clamped to the same limit.

The headroom works the other way too. `brk_` maps up to 4 MiB beyond the break to save mappings, and 9front has no such headroom, so a fixed-`va` `segattach` just above the break must succeed. Overlap is checked against the break, and a segment that overlaps only the headroom trims it before it's mapped:

- Whole chunks above the rounded break are unmapped and freed, as `brk_` shrinks.
- If the last chunk straddles the break, it's split: a new chunk is allocated for `[chunk.va, break)`, the data copied into it, and it replaces the old chunk in every address space before the old one is freed.
- Only an unshared data segment is trimmed. The caller is in the syscall, so nothing else writes it during the copy. With `RFMEM` siblings one could, and a write during the copy would be lost, so a segment overlapping a shared data segment's headroom fails with `Esoverlap`.

Placement with `va` 0 starts just below `stack_floor`, far above the headroom, and meets it only if the hole search steps that far down; the same trim applies then.

### fork and exec

- **`Segs.fork`** gives the child each `shared` extra attached to its new address space, the same pages. It copies `memory` extras, or shares them with `RFMEM`. Each keeps its slot.
- **exec** loads the new image, then attaches every extra without `SG_CEXEC` to the new address space, in its slot, and detaches the rest. An extra that overlaps the new image is detached too, as segattach(2) says. That never happens with segments placed by `va` 0; it can only happen with a fixed `va` low enough to meet the text or data. The old address space then goes as today.

### Memory the guest may write

`Segs.writable`, which checks a note handler's frame before the kernel writes it, also accepts a writable extra. Syscall buffers in an extra work already: `AddressSpace.translate` sees every mapped page.

### `/proc/n/segment`

devproc serves `segment` from h9's process records, as it does `status`, in 9front's format:

| Segment | Line |
| --- | --- |
| Text | `Text`, read-only |
| Data | One `Data` line from its base to the break; h9 doesn't keep 9front's separate bss |
| Stack | `Stack` from `stack_floor` to `USTKTOP`, as 9front's stack segment spans its whole 16 MiB |
| Extras | `Shared` for `shared`, `Bss` for `memory`, with `R` if read-only |

The reference count is the number of address spaces it's attached to. That takes `segment` off [self-host](self-host.md)'s list of devproc files acid needs.

## Rationale

**Pages up front, not on fault.**
- **Why up front:** h9 allocates every segment's pages when it's created or grown. That keeps `--memory` exact, since a segment either fits or fails at `segattach` with `Enovmem` rather than at some later touch. It also keeps a segment a list of whole chunks.
- **What 9front does:** it allocates on fault, so a large `segattach` costs nothing until it's touched.
- **Why that's acceptable here:** the callers in the tree attach what they use. APE's buffers are a few pages, and telnetd's console state is one. The one large, sparse user is `vmx`, which h9 can't run anyway.
- **Faulting in later:** if a sparse user turns up, `Segment` could map chunks on first touch, the way the stack already grows on faults. `--memory` would then fail at a touch, with a note, instead of at `segattach`. The likelier first user is [linux-personality](linux-personality.md), whose anonymous mappings are allocated on fault; if both need it, it's built once in `Segment` and shared.

**No `#g`.** Named global segments need devsegment, a new device with its own namespace semantics and the `sticky` class, which pins pages. In the tree its user is `vmx`, plus anything that shares memory between unrelated processes by name. `segattach` would consult it first, as 9front's does through `_globalsegattach`, so adding it later doesn't change this design. It would be a proposal of its own if something needs it.

**No device classes.** `aux/vga`, `reform/pm`, and `seg`'s hardware uses want physical device memory. A guest has none to offer, and h9 won't map host device memory into one. Those classes fail with `Ebadarg`, as an unknown class does on 9front.

**Never executable.** h9 maps data and stack without execute permission, and these segments the same. Nothing in the tree executes from an attached segment, and keeping writable memory non-executable means a guest can't build code at run time and jump into it on HVF. 9front's default is executable unless `SG_NOEXEC`. A program that relies on that faults with an exec fault and its note, which a backend test checks so the difference is easy to diagnose.
- **If one is ever needed:** executable segments would be a host policy opt-in, not the guest's choice by leaving out `SG_NOEXEC`. Otherwise any guest could turn off W^X.
- **Not linuxemu's route:** linuxemu built Linux's `mmap`, executable mappings included, on `segattach`. h9's [linux-personality](linux-personality.md) has its own VMAs instead, so it won't need executable extras.

**Trimming the headroom.** The headroom is an h9 optimisation 9front doesn't have, so it mustn't make a `segattach` fail that 9front allows. Chunks are mapped whole, so trimming one that straddles the break means copying it. Refusing to copy a shared data segment trades a rare `Esoverlap` for never losing a sibling's write.

**Five slots.** Matching 9front's limit means a program that works on 9front works here, and one that runs out does so at the same point with the same error. h9 has no separate bss, so it could allow six. It doesn't, so behaviour stays the same on both.

**Detaching text and data.** 9front lets a process detach its text or data, and a later fault then kills it. h9 refuses with `Ebadarg`. The only effect of detaching is a crash, and h9's image segments are shared with `RFMEM` siblings in ways a detach would complicate.

## Compatibility

- **Programs:** calls 12 and 30 to 33 stop posting "sys: bad sys call" and behave as on 9front, within the limits above. A program that probed for them and fell back gets the real calls.
- **Large segments:** pages are allocated at `segattach`, so a segment larger than `--memory` allows fails with `Enovmem` up front, where 9front would succeed and fail only when enough of it was touched.
- **Fixed `va` above a shared break:** a segment overlapping the headroom of a data segment shared with `RFMEM` siblings fails with `Esoverlap`, where 9front would place it.
- **Executing from a segment:** faults with an exec fault, where 9front allows it unless `SG_NOEXEC`.
- **`brk_`:** stops below an attached segment as well as at the stack. Programs without extras see no change.
- **`/proc/n/segment`:** a new file, in 9front's format.
- **CLI, `Machine.Options`, the vmm interface, sandbox defaults, the root tree, and `third_party/`:** unchanged. `src/kern/devproc.c` is h9's own copy, not the vendored tree.

## Security

- **No host memory is exposed.** Extras are backend pages from the same allocator as every other guest page, counted against `--memory`, and mapped only into guest address spaces. No class maps host or device memory.
- **Range checks on guest input:** `va`, `len`, `addr`, and `saddr` are guest values, checked for wraparound and against `USTKTOP` and `SEGMAXSIZE` before any arithmetic is used to map or zero. `segfree` and `segflush` spans are checked against the segment they name, so a span can't zero pages outside it. The unit tests cover each wraparound case.
- **Sharing:** a `shared` segment is shared only with the attacher's own descendants, as on 9front, and only within one machine. Machines in one host process never share segments.
- **Teardown:** detaching or exec frees an extra only when its last address space lets go, and unmapping flushes the backend's TLB as it does for other segments today. A test detaches a segment that a sibling still uses, and checks the sibling still reads it while the detacher faults.
- **W^X:** extras are never executable (see Rationale).

## Done criteria

Integration cases, tagged `[segattach]`, using the root tree's `seg`:

- [x] `test "seg attaches a shared segment and reads zero [segattach]"`: `seg -r shared 0x1000 0` prints `0x0`.
- [x] `test "seg attaches a memory segment and writes a word [segattach]"`: `seg -L -w memory 0x1000 8 0x12345678` exits cleanly.
- [x] `test "an unknown class is a bad arg [segattach]"`: `seg -r tmu 0x1000 0` fails with "segattach: bad arg in system call".
- [x] `test "--memory caps segattach [segattach]"`: under `--memory 8m`, `seg -r memory 0x2000000 0` fails with "virtual memory allocation failed".

Backend cases in `tests/backends.zig`, with hand-assembled fixtures as hello is, on every backend built in:

- [x] `test "a shared segment is the same pages in an rfork child [segattach]"`
- [x] `test "a memory segment is copied by rfork and shared with RFMEM [segattach]"`
- [x] `test "segattach at 0 goes below the stack, and an overlap fails [segattach]"`
- [x] `test "a sixth segment fails with virtual memory allocation failed [segattach]"`
- [x] `test "segdetach unmaps, and the stack can't be detached [segattach]"`
- [x] `test "segbrk grows and shrinks, and won't shrink a shared segment [segattach]"`
- [x] `test "segfree zeroes the span [segattach]"`
- [x] `test "a write to an SG_RONLY segment faults [segattach]"`
- [x] `test "executing from an attached segment posts an exec fault [segattach]"`
- [x] `test "segattach just above the break trims the headroom, and the data survives [segattach]"`
- [x] `test "exec keeps segments and drops SG_CEXEC ones [segattach]"`
- [x] `test "brk stops below an attached segment [segattach]"`
- [x] `test "a detached shared segment stays mapped in a sibling [segattach]"`
- [x] `test "/proc/n/segment lists every segment [segattach]"`

Unit tests in `src/segment.zig` for the hole search, the overlap and wraparound checks, `segbrk`'s limits, trimming the headroom (including splitting a chunk that straddles the break, and refusing a shared data segment), and fork and exec carrying the extras.

APE `select` end to end isn't a case here: nothing in the pinned userland calls it, and the shared-segment rfork case covers what it relies on. It's in [self-host](self-host.md)'s Done when, as a compiled fixture.

## Implementation

1. `Kind.shared` and `Kind.memory`, the `cexec` attribute, `Segs.extra`, and the shared break logic moved from `Segs.brk` into `Segment`, with its unit tests.
2. `segattach` and `segdetach` in `syscall.zig`, with the placement rules, trimming the headroom, and errors. The `seg` cases pass.
3. `Segs.fork` and exec carrying extras, `brk_`'s new limit, and `Segs.writable`. The fork, exec, and brk backend cases pass.
4. `segbrk`, `segfree`, and `segflush`.
5. `/proc/n/segment` in devproc, and its case. Remove `segment` from [self-host](self-host.md)'s list.
6. SPEC.md's process model table gets rows for the segment calls, `/proc/n/segment` joins devproc's row, and `status: implemented`.
