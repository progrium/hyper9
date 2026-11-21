---
slug: memory-model
title: One memory model under both ABIs
status: draft
created: 2026-11-21
authors: [progrium]
depends: [baseline-1, cow-fork]
areas: [kern, linux, engine, tests]
branch: []
---

# Proposal: One memory model under both ABIs

## Abstract

h9 has two models of a process's memory: Plan 9 segments in `src/segment.zig`, and the Linux `Mm` in `src/linux/mm.zig`. [cow-fork](cow-fork.md) gives `Mm` copy-on-write and demand-loaded file pages. This proposal moves 9front processes onto it. A Plan 9 segment becomes a named mapping in an `Mm`, `rfork` shares pages copy-on-write instead of copying them, and an a.out's text is filled from its file when touched. `src/segment.zig` shrinks to the part that's Plan 9's own: segment names, `segattach`, `segbrk`, and `/proc/n/segment`.

## Background

- **`rfork` copies eagerly for 9front processes.** A Go program built for `GOOS=plan9` that uses `os/exec` needs `--memory` of about 4 GB, since each fork copies the runtime's heap, and a 9front `mk` of the userland pays the same for every command it starts.
- **Two of everything.** Fault handling, the walk for a host read or write of guest memory, accounting against `--memory`, `/proc` reporting, and the engine's map and unmap calls each exist twice. A fix to one, such as cow-fork's out-of-memory report, doesn't reach the other.
- **`exec` across ABIs.** A 9front process that execs a Linux binary, or the reverse, tears down one model and builds the other.

9front's own kernel has copy-on-write segments, so this brings h9 closer to it.

## Proposal

- **One `Mm` per address space,** for every process. It moves from `src/linux/` to the kernel, since it's no longer Linux's.
- **Segments are mappings.** Text, data, bss, stack, and each `segattach`ed segment is a mapping with a name and a class. Text and the initialized part of data are private file mappings of the a.out, filled on first touch. Bss and stack are anonymous. A shared segment (`RFMEM`'s data and bss, and `segattach` of a shared class) is a shared mapping.
- **`rfork`.** With `RFMEM`, the child shares data and bss, as now. Without it, private mappings are shared read-only and copied on the first write by either side, by cow-fork's mechanism. The stack is always the child's own.
- **`segbrk`, `segattach`, `segdetach`, `segfree`, and `segflush`** are calls on the `Mm`: grow or shrink a mapping, add one, remove one, drop pages, and drop pages with the engine told to flush code.
- **Granularity.** `Mm`'s chunk size stays what cow-fork leaves it. A 9front binary's segments are rounded to the a.out's page size as now, and to chunks only for sharing.
- **`/proc/n/segment`** is generated from the mappings that have segment names.
- **Accounting.** Shared pages count once against `--memory`, as cow-fork defines.

## Rationale

**Why move 9front onto `Mm`, and not the reverse.** `Mm` is the superset: it has file mappings, protections per range, and after cow-fork, copy-on-write. Segments would need all three added.

**Why not leave 9front alone.** It's the smaller ABI by use, but the eager copy is its largest cost, and two models double every later change. [scheduler](scheduler.md) switches address spaces on executors and wants one kind.

**Why keep `segment.zig` at all.** Segment names and classes are Plan 9's interface, and `/proc/n/segment` and `segattach` speak in them.

## Compatibility

- **Guests.** A 9front program sees the same segments, addresses, and `/proc/n/segment`. A write to a page shared after `rfork` takes a fault it didn't before, which the guest can't observe except in time.
- **`--memory`.** Process trees need less. A machine that fit before still fits.
- **CLI, `Machine.Options`, and exit codes.** Unchanged.

## Security

None new for reach. Copy-on-write across processes is the property to get right: a missed write fault would let one process's write appear in another. cow-fork's cases cover the mechanism, and this proposal adds the same cases for 9front binaries.

## Done criteria

- [ ] `test "rfork shares pages until a write (9front) [memory-model]"` passes on every engine, with the parent and the child each seeing only their own writes.
- [ ] `test "rfork RFMEM still shares data and bss [memory-model]"` passes.
- [ ] `test "a.out text is filled on touch [memory-model]"` passes, with resident memory after exec of a large binary less than its text size.
- [ ] `test "segattach, segbrk, segdetach, and segfree on Mm [memory-model]"` passes, with `/proc/n/segment` unchanged from before.
- [ ] A Go program for `GOOS=plan9` that runs `os/exec` 100 times passes under `--memory 512M`.
- [ ] The self-host cases pass, and `zig build integration` passes on every engine with none newly skipped.
- [ ] `src/segment.zig` has no fault handler, page walker, or engine calls of its own.
- [ ] [spec/kernel.md](../spec/kernel.md) describes one memory model.

## Implementation

1. Move `Mm` into the kernel and take the Linux-specific parts (`mmap` flag decoding, and `brk`) out to the Linux ABI.
2. Build a 9front process's address space as mappings at exec, behind a build option, with both models present.
3. `rfork`, then the `seg*` calls, then `/proc/n/segment`.
4. Text filled from the file.
5. Remove the old model and the option.

## Open issues

- Whether a 9front binary's pages need a smaller chunk than `Mm`'s for copy-on-write to pay off in small processes such as rc.
- Whether the shared text of one binary run many times should be one set of pages across processes, as on 9front. As written it is, through the file mapping.
