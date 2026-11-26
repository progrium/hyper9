---
slug: kernel-port
title: Port the kernel core to Zig, as an instance
status: draft
created: 2026-11-21
authors: [progrium]
depends: [baseline-1, namespace-kernel, kernel-serve]
areas: [kern, build, tests]
branch: [dev]
---

# Proposal: Port the kernel core to Zig, as an instance

Nov 25, 2026 · Jeff Lindsay, <abbr title="AI-assisted work substantially directed by the named person, who takes responsibility for the result.">h.d.a.</abbr>

## Abstract

h9's kernel is drawterm's `kern/`, about 7,000 lines of C that h9 vendors, with about 17,000 lines of h9's own C around it. This proposal ports the namespace core (channels, mount tables, the device switch, devmnt, queues, pipes, and the file system calls) to Zig, one file at a time, with the same behaviour. Errors become Zig error unions in place of `waserror` and `longjmp`. drawterm's Proc and h9's own process record become one. And a kernel becomes a value: `Kernel.init` makes one, a machine owns one, and nothing in it is process-global. drawterm stays in `third_party/` for what h9 doesn't port: devdraw, libmemdraw, the GUI backends, libsec, and the auth code. Nothing a guest can observe changes.

## Background

Borrowing drawterm's kernel was the fastest way to get exact Plan 9 namespace semantics, and it still gives them. What h9 has built on it since shows where it no longer fits.

- **`waserror` at the seam.** The kernel's error model is `setjmp` and `longjmp`, which can't unwind through Zig frames. [spec/kernel.md](../spec/kernel.md) has seven rules for the seam between the two, calls into Zig from C are leaves only, and every system call goes through a `sys*` wrapper layer that exists to catch errors on the C side.
- **Two process records.** drawterm's Proc has no parent, notes, segments, or environment group, because drawterm is a terminal. h9 keeps a second record (`src/kern/proc.c`, 1,800 lines) in step with it by hand, and notes live on h9's side because drawterm's `postnote` drops them.
- **One kernel per host process.** Every machine in a process shares one booted kernel. devsrv, the console, the clock, and the locks table each needed a per-machine table hung off `Hmach` to keep machines apart, and [host-cmd](host-cmd.md) found devcmd's conversation table shared between them. [child-machines](child-machines.md) and [namespace-kernel](epoch-0/namespace-kernel.md) each design around it.
- **No address checks, and a 32-bit `long`.** drawterm's `validaddr` does nothing, and offsets and counts pass through `long` in places where a guest's are 64 bits.
- **Patches to vendored code.** h9's changes to `third_party/drawterm/kern/` (policy hooks, the `#λ` exemption in `chan.c`, the readiness hook and the interruptible reader and writer locks in `qio.c`) have to be carried across every merge from upstream.

[namespace-kernel](epoch-0/namespace-kernel.md) and [kernel-serve](epoch-0/kernel-serve.md) come first because they make the kernel stand alone: a build with no engine, loaders, system call tables, or devproc, driven only over 9P. That build is the line this port works behind, and its suite is a second check on it.

## Proposal

### What's ported

| drawterm file | Becomes | Notes |
| --- | --- | --- |
| `chan.c` | `src/kern/chan.zig` | `namec`, `walk`, `cclose`, mount point crossing, and union lookups |
| `pgrp.c` | `src/kern/pgrp.zig` | Pgrp, Fgrp, Rgrp, and the mount table |
| `dev.c`, `devtab.c` | `src/kern/dev.zig` | The device switch and `devgen` helpers |
| `devmnt.c` | `src/kern/devmnt.zig` | The 9P client |
| `qio.c`, `allocb.c` | `src/kern/qio.zig` | Queues and blocks |
| `devpipe.c`, `devroot.c` | `src/kern/dev/` | With h9's own devices, as each is ported |
| `sysfile.c` | `src/kern/sysfile.zig` | The file system calls, with no wrapper layer |
| `qlock.c`, `rwlock.c`, `sleep.c` | `src/kern/sync.zig` | Over the host's primitives, as now |

Each is a close translation: the same functions, in the same order, with the same names where Zig allows, so a diff against 9front's `port/` still reads. h9's own C in `src/kern/` (`proc.c`, `linux.c`, `linuxnet.c`, and the devices) is ported after the core, a file at a time, and isn't required for this proposal to be done.

### Errors

A kernel function that can fail returns an error union. The error set is small (`error.Kernel` and `error.Interrupted`), and the Plan 9 error string is stored on the process, as `up->errstr` is now. `waserror` blocks become `errdefer` and `defer`. The seam rules, the leaf-only restriction, and the `sys*` wrappers go.

C that stays (devdraw and the GUI backends) calls into the kernel through a small exported API that returns an error code, and never runs under a `waserror` of the kernel's.

### One process record

`Proc` is one Zig struct with what both records have now: the Plan 9 fields (Pgrp, Fgrp, Egrp, Rgrp, notes, and wait queue), the parent and children, the segments or `Mm`, and the ABI's state. `src/kern/proc.c`'s bookkeeping to keep two records in step is deleted.

### A kernel is a value

`Kernel.init(gpa, host)` returns a kernel with its own process table, device instances, `#s` board, console, clock, and locks table. `Machine` owns one. Nothing in `src/kern/` is a global, and `Hmach`'s per-machine tables fold into the instance. Two machines in a process share nothing unless one is handed a channel into the other.

### Address checks and widths

Every pointer from a guest is checked against its address space before the kernel reads or writes through it, in one place. Offsets and counts are `u64` and `usize` throughout.

### What stays C

devdraw, libmemdraw, libmemlayer, the GUI backends, libsec, libauthsrv, and devtls and devssl stay drawterm's, built as a library and reached through the device switch. h9 stops patching `third_party/drawterm/kern/` for the files it ports, and stops compiling them.

## Rationale

**Why port and not wrap.** Each seam rule and each `Hmach` table is a wrapper, and each new feature has added more. The core is small, it's stable upstream, and h9 already owns more kernel C than it borrows.

**Why a close translation.** The value of drawterm's kernel is that it's 9front's code, so its behaviour at the edges (union directories, `..` across mounts, `ORCLOSE`, and flush) is right without anyone having to know why. A redesign during the port would lose that. Anything that changes behaviour is a later proposal: [scheduler](scheduler.md), [file-interface](file-interface.md), and [host-handles](host-handles.md) each depend on this one for that reason.

**Why Zig and not cleaner C.** The trouble is the error model, and C has no other. Zig's error unions and `defer` express the same cleanup without `longjmp`, the rest of h9 is Zig, and one language removes the seam instead of moving it.

**Why not track upstream.** 9front's `port/chan.c` and `devmnt.c` change rarely. A close translation keeps those changes portable by hand, and the pinned release in SPEC.md's decisions table already says which 9front h9 matches.

**Why after namespace-kernel.** It gives the port a build with only the core in it, and a client (Wanix) that exercises namespaces without an engine. Porting first would mean drawing that line twice.

## Compatibility

- **CLI, exit codes, sandbox defaults, and the root tree.** Unchanged.
- **`Machine` API.** `Machine.init` makes a kernel; there's no separate boot. Embedders that ran several machines in a process see no change except that they no longer share `#s` through a table.
- **Error strings.** The same strings, from the same places.
- **`third_party/`.** drawterm's ported files are no longer compiled or patched. They stay in the tree for reference and for merges.
- **[namespace-kernel](epoch-0/namespace-kernel.md)'s C API and `h9ns.js`.** Unchanged; the library behind them is Zig.

## Security

No new reach for a guest. Real address checks close a class of bug where a guest pointer was trusted. A kernel per machine removes shared tables that have already leaked state between machines once. The port is new code in the trusted base, so each ported file lands with its tests and with fuzzing of the paths that parse guest or 9P input (devmnt's replies, and `namec`'s paths).

## Done criteria

- [ ] `zig build test`, `zig build integration` on every engine, `zig build integration -Dweb`, and `zig build web-test` pass with no case removed or newly skipped.
- [ ] [namespace-kernel](epoch-0/namespace-kernel.md)'s cases pass against the ported core.
- [x] `zig build conformance` runs a script of namespace operations (binds, unions, mounts, `..` across mounts, creates in unions, `ORCLOSE`, and flush) on h9 and on a 9front kernel under QEMU, and the transcripts match.
- [ ] `git grep -l waserror src/` finds nothing, and the build compiles none of `chan.c`, `pgrp.c`, `dev.c`, `devmnt.c`, `qio.c`, `devpipe.c`, `devroot.c`, or `sysfile.c` from `third_party/drawterm/kern/`.
- [ ] `test "two machines don't share /srv [kernel-port]"` and `test "two machines don't share devcmd conversations [kernel-port]"` pass with two machines in one process.
- [ ] `test "a bad guest pointer is a fault, not a host crash [kernel-port]"` passes for read, write, and stat buffers.
- [ ] `zig build bench` shows system call round trips within 5% of before the port.
- [ ] [spec/kernel.md](../spec/kernel.md) describes the kernel as built, with no seam rules.

## Implementation

1. The conformance script and its 9front oracle, run against today's kernel, so the port has a target before it starts.
2. `qio` and `sync`, which have no dependents among the rest.
3. `dev` and the device switch, with C devices adapted through a shim that catches their errors.
4. `pgrp`, then `chan`, then `sysfile`.
5. `devmnt`, with fuzzing of its reply parser.
6. `devpipe` and `devroot`.
7. One `Proc`, and the removal of the second record.
8. `Kernel` as a value, and the removal of `Hmach`'s tables.
9. Address checks and widths.
10. The spec, and the end of the patches to `third_party/drawterm/kern/`.

## Open issues

- Whether the C devices h9 wrote (devoverlay, devdotl, devlinux, and the rest) are ported under this proposal or after it. As written, they're adapted through the shim in step 3 and ported later without a proposal, as internal refactors.
- Whether the 9front oracle runs in CI or only by hand. It needs QEMU and a 9front image, which `zig build mkroot` already uses.

## Updates

**2026-11-26, the conformance check.** `zig build conformance` runs [tests/conformance/ns.rc](../tests/conformance/ns.rc) on h9 and compares it with a transcript recorded on 9front, [tests/conformance/9front.out](../tests/conformance/9front.out), so it runs in CI and anywhere else with no QEMU, which settles the second open issue. `zig build conformance -- --oracle` records the transcript again: it boots the arm64 image that `zig build mkroot` boots, under QEMU (TCG is fine, and takes under a minute), and runs the script there. The script compiles a small C helper in the guest for `ORCLOSE`, which rc can't ask for, and tests flush by interrupting a read blocked in exportfs, through `srvfs`. Today's C kernel matches 9front's transcript on sud and hcpu, with no differences to note.

**2026-11-26, qio and sync.** `src/kern/qio.zig` (from `qio.c` and `allocb.c`) and `src/kern/sync.zig` (from `qlock.c`, `rwlock.c`, and `sleep.c`) are built in place of the C, under `src/kern/port.zig`, the root of the kernel's Zig, which the kern library and the namespace kernel compile. Some things the port found:

- **The C kernel's types come from translate-c.** `src/kern/port.h` is translated with the kernel's own `-D` flags, so `Lock` (a pthread mutex with `PTHREAD`), `Proc`, and `Label` have the C compiler's layout on every target. It reads `char Eintr[]` as a pointer, so error.c's strings are declared by hand, and on the web it needs `__wasm_exception_handling__` defined for wasi-libc's `setjmp.h`.
- **`lib.h` renames `sleep` and `wakeup`** to `ksleep` and `kwakeup`, which are the symbols C calls, and a `Proc`'s `sleep` field is `ksleep` too.
- **drawterm's `malloc` clears** (`kern/alloc.c`), so a `Queue` starts zeroed, locks included; the port allocates it with `mallocz(n, 1)`.
- **`tsleep` gains a form that returns.** qio's interruptible reader and writer locks wait in `tsleep`, so `src/kern/tsleep.c` has `h9_tsleepintr`, which returns -1 on a note, built on `h9_sleepintr`, the Zig sleep's form for C that returns, and `tsleep` raises from it. That removes a `waserror` from tsleep.c.
- **The `waserror` around `qread`'s and `qwrite`'s copies goes**: in 9front it catches a fault on a user buffer, and h9 copies guest memory outside the kernel.
- **Kick and bypass functions mustn't raise**, since they're called from the Zig. No caller in h9 sets either.
- **The blocking points** are `park` and `unpark` in `sync.zig` (posix.c's `procsleep` and `procwakeup`): qlock's queue, sleep, and so `qwait`, `qflow`, and `qlockintr` in qio, which each wait in one small function. [scheduler](scheduler.md) changes those two.

**2026-11-26, dev and the device switch.** `src/kern/dev.zig` is `dev.c`: the helpers, exported under their C names, and the switch the Zig calls devices through. Devices stay C `Dev`s in h9's own tables (`src/kern/devtab.c` and `nstab.c`, which stand for drawterm's `devtab.c`), so the switch calls a C device, or a C `Devgen` handed to `devwalk` and the rest, through `src/kern/devshim.c`: one small C function per `Dev` member, which runs the call under `waserror` and returns -1 with the error string on the process. Those are the only `waserror`s the Zig runs under. Some things the port found:

- **drawterm's `long` is `int`.** `lib.h` defines it so, and its `ulong` is `unsigned int`, so `qio.zig` had `qread`'s, `qbwrite`'s, and `readblist`'s counts as 64 bits where C passes 32; a C caller's count reached `readblist` with its upper half undefined. They're `c_int` now, and so is every `long` in the Zig.
- **`lib.h` renames `clone`** to `libclone`, so a `Walkqid`'s clone is `libclone` in the Zig.
- **`devwalk` raises only before its walk**: `isdir` comes before its `waserror`, so a walk from a file is an error, and a walk that fails at its first name is nil with the error string set. The Zig returns `Error!?*Walkqid` to say both.
